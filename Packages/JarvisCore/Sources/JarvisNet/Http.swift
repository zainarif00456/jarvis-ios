import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JarvisCore

public enum ApiError: Error, LocalizedError, Equatable {
    case notConfigured
    case badURL
    case offline(String)
    case http(status: Int, detail: String)
    case decoding(String)
    case noToken
    /// An HTML page came back where JSON was expected (ngrok warning page, wrong URL, captive portal).
    case notJarvis

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Jarvis server is set up yet."
        case .badURL: return "That address does not look right."
        case .offline(let m): return "Cannot reach Jarvis: \(m)"
        case .http(let s, let d): return d.isEmpty ? "The server answered HTTP \(s)." : d
        case .decoding(let m): return "The server's answer was not understood (\(m))."
        case .notJarvis: return ResponseSniffer.htmlMessage
        case .noToken: return "The server accepted the code but sent no device token."
        }
    }
    public var isUnauthorized: Bool { if case .http(let s, _) = self { return s == 401 }; return false }
    public var statusCode: Int? { if case .http(let s, _) = self { return s }; return nil }
    /// Worth retrying later (network trouble, server restarting), as opposed to a refusal.
    public var isTransient: Bool {
        switch self {
        case .offline: return true
        case .http(let s, _): return s >= 500 || s == 429 || s == 408
        default: return false
        }
    }
}

/// REST client for the Jarvis gateway. Every request carries the device cookie and an Origin equal to the
/// Host (the server refuses mismatching origins on state-changing requests).
public final class ApiClient: @unchecked Sendable {
    public let endpoint: Endpoint
    public let token: String?
    private let session: URLSession
    private let transfers: TransferSession

    public init(endpoint: Endpoint, token: String?) {
        self.endpoint = endpoint
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
                cfg.timeoutIntervalForRequest = 25
        session = URLSession(configuration: cfg)
        transfers = TransferSession()
    }

    // MARK: building

    func request(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, contentType: String? = nil, timeout: TimeInterval? = nil) throws -> URLRequest {
        guard let url = endpoint.httpURL(path, query: query) else { throw ApiError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in endpoint.requestHeaders(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        if let body = body { req.httpBody = body }
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        if let timeout = timeout { req.timeoutInterval = timeout }
        return req
    }

    private func perform(_ req: URLRequest, expectJSON: Bool = false) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw ApiError.offline("no HTTP response") }
            if expectJSON, ResponseSniffer.looksLikeHTML(contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data) { throw ApiError.notJarvis }
            guard (200..<300).contains(http.statusCode) else { throw ApiError.http(status: http.statusCode, detail: Self.detail(from: data)) }
            return (data, http)
        } catch let e as ApiError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ApiError.offline(Self.describe(error))
        }
    }

    static func detail(from data: Data) -> String {
        guard let v = JSONValue.parse(data) else { return "" }
        if let s = v["detail"]?.string { return s }
        if let arr = v["detail"]?.array { return arr.compactMap { $0["msg"]?.string }.joined(separator: "; ") }
        return v["error"]?.string ?? ""
    }
    static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet: return "no internet connection"
            case .timedOut: return "the server did not answer in time"
            case .cannotFindHost, .dnsLookupFailed: return "the server name was not found (is Tailscale on?)"
            case .cannotConnectToHost, .networkConnectionLost: return "the server is not reachable"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot: return "the secure connection failed (certificate)"
            default: return u.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: JSON helpers

    public func get<T: Decodable>(_ path: String, query: [(String, String)] = [], as: T.Type = T.self) async throws -> T {
        let (data, _) = try await perform(try request("GET", path, query: query), expectJSON: true)
        return try decode(data)
    }
    public func send<T: Decodable>(_ method: String, _ path: String, query: [(String, String)] = [], json: JSONValue? = nil, as: T.Type = T.self) async throws -> T {
        let body = try json.map { try JSONEncoder().encode($0) }
        let (data, _) = try await perform(try request(method, path, query: query, body: body ?? (json == nil ? Data("{}".utf8) : nil), contentType: "application/json"), expectJSON: true)
        return try decode(data)
    }
    public func rawGet(_ path: String, query: [(String, String)] = [], timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        try await perform(try request("GET", path, query: query, timeout: timeout))
    }
    func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ApiError.decoding(String(describing: error).prefix(160).description) }
    }

    // MARK: pairing and identity

    /// Redeems a one-time code for the device token. The returned token goes to the Keychain.
    public static func pair(endpoint: Endpoint, code: String, name: String) async throws -> String {
        let client = ApiClient(endpoint: endpoint, token: nil)
        let body = try JSONEncoder().encode(["code": code, "name": name])
        let req = try client.request("POST", "/api/pair", body: body, contentType: "application/json", timeout: 15)
        let (_, http) = try await client.perform(req, expectJSON: true)
        let header = http.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        guard let token = SetCookie.value(named: Endpoint.cookieName, in: header) else { throw ApiError.noToken }
        return token
    }

    /// `GET /api/session` never answers 401: `true`/`false` when the server says, `nil` when it cannot be reached.
    public func isPaired() async -> Bool? {
        struct S: Decodable { let paired: Bool }
        guard let s: S = try? await get("/api/session") else { return nil }
        return s.paired
    }
    /// What `GET /api/session` says about this address and token. Never throws.
    public enum Probe: Equatable, Sendable {
        case paired, unpaired
        case unreachable(String)
        public var summary: String {
            switch self {
            case .paired: return "Reachable and paired."
            case .unpaired: return "Reachable, but this phone is not paired on this address."
            case .unreachable(let why): return "Not reachable: \(why)"
            }
        }
    }
    public func probe() async -> Probe {
        struct S: Decodable { let paired: Bool }
        do {
            let s: S = try await get("/api/session")
            return s.paired ? .paired : .unpaired
        } catch let e as ApiError {
            return .unreachable(e.errorDescription ?? "unknown error")
        } catch { return .unreachable(error.localizedDescription) }
    }
    public func health() async -> Bool {
        (try? await rawGet("/health", timeout: 6)) != nil
    }
    public func me() async throws -> DeviceInfoResponse { try await get("/api/me") }

    // MARK: transfers

    /// Uploads a file as multipart form data with progress (0...1). Used for `/api/uploads` and `/api/media/upload`.
    public func upload(fileURL: URL, fileName: String, mime: String, to path: String, fields: [String: String] = [:], progress: @escaping @Sendable (Double) -> Void) async throws -> UploadResult {
        let multipart = try Multipart.write(fileURL: fileURL, fieldName: "file", fileName: Format.safeFileName(fileName), mime: mime, fields: fields)
        defer { try? FileManager.default.removeItem(at: multipart.bodyURL) }
        var req = try request("POST", path, contentType: multipart.contentType, timeout: 600)
        req.setValue(String(multipart.length), forHTTPHeaderField: "Content-Length")
        let (data, http) = try await transfers.upload(req, fromFile: multipart.bodyURL, progress: progress)
        guard (200..<300).contains(http.statusCode) else { throw ApiError.http(status: http.statusCode, detail: Self.detail(from: data)) }
        return try decode(data)
    }

    /// Downloads a file to a temporary location, with progress.
    public func download(path: String, query: [(String, String)] = [], suggestedName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let req = try request("GET", path, query: query, timeout: 600)
        let (tmp, http) = try await transfers.download(req, suggestedName: Format.safeFileName(suggestedName), progress: progress)
        guard (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            throw ApiError.http(status: http.statusCode, detail: Self.detail(from: data))
        }
        return tmp
    }
}
