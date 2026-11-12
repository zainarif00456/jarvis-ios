import Foundation

/// Where the Jarvis server is, and the strings that depend on it (REST base, WebSocket URLs, Origin).
///
/// The server refuses state-changing requests and every WebSocket whose `Origin` header does not equal its
/// `Host` header, so the Origin is always `<scheme>://<host[:port]>` of the same address that is connected to.
public struct Endpoint: Equatable, Codable, Sendable {
    public enum ParseError: Error, Equatable, LocalizedError {
        case empty, invalid, unsupportedScheme(String), insecureHost(String)
        public var errorDescription: String? {
            switch self {
            case .empty: return "Enter the address of your Jarvis server."
            case .invalid: return "That address does not look right. Example: my-laptop.tail1234.ts.net"
            case .unsupportedScheme(let s): return "Only https:// or http:// addresses work (not \(s)://)."
            case .insecureHost(let h): return "Plain http:// is only allowed for this phone's own network (LAN, Tailscale, localhost). Use https:// for \(h)."
            }
        }
    }

    public let secure: Bool
    public let host: String
    public let port: Int?

    public init(secure: Bool, host: String, port: Int? = nil) {
        self.secure = secure; self.host = host; self.port = port
    }

    /// THE single place where an address typed by the owner is validated and normalised (pairing screen, settings,
    /// saved addresses). Accepts a bare host, `host:port`, `http(s)://host[:port]` (also ws/wss), any trailing slash /
    /// path / query / fragment (dropped), ngrok https URLs, bracketed IPv6. Plain http is refused for public hosts.
    /// Examples: `name.ts.net`, `https://name.ts.net/`, `http://192.168.1.5:8000`, `name:8443`., `https://name.ts.net/`, `http://192.168.1.5:8000`, `name:8443`.
    /// No scheme means https, except for loopback / private-network addresses typed with a port, which
    /// would never have a certificate: those default to http.
    public static func parse(_ raw: String) throws -> Endpoint {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw ParseError.empty }
        var secure: Bool? = nil
        if let r = text.range(of: "://") {
            let scheme = text[text.startIndex..<r.lowerBound].lowercased()
            switch scheme {
            case "https", "wss": secure = true
            case "http", "ws": secure = false
            default: throw ParseError.unsupportedScheme(scheme)
            }
            text = String(text[r.upperBound...])
        }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { text = String(text[..<slash]) }
        if text.contains("@") || text.contains(" ") { throw ParseError.invalid }
        var host = text
        var port: Int? = nil
        if text.hasPrefix("[") {  // [::1]:8000
            guard let close = text.firstIndex(of: "]") else { throw ParseError.invalid }
            host = String(text[text.startIndex...close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") { port = Int(rest.dropFirst()); if port == nil { throw ParseError.invalid } }
        } else if let colon = text.lastIndex(of: ":") {
            host = String(text[..<colon])
            guard let p = Int(text[text.index(after: colon)...]), (1...65535).contains(p) else { throw ParseError.invalid }
            port = p
        }
        host = host.lowercased()
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || ".-_[]:".contains($0) }) else { throw ParseError.invalid }
        // no scheme: https, except private addresses typed with a port (no certificate there); *.ts.net has Tailscale HTTPS certificates
        let isSecure = secure ?? !(port != nil && Endpoint.isPrivate(host) && !host.hasSuffix(".ts.net"))
        if !isSecure && !Endpoint.isPrivate(host) { throw ParseError.insecureHost(host) }
        return Endpoint(secure: isSecure, host: host, port: port)
    }

    static func isPrivate(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" || host.hasSuffix(".local") { return true }
        if host.hasSuffix(".ts.net") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || host.hasSuffix(".internal") { return true }
        if host.hasPrefix("[") {   // IPv6: loopback, unique-local fc00::/7, link-local fe80::/10
            let h = host.dropFirst().lowercased()
            return h.hasPrefix("::1]") || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80:")
        }
        let strs = host.split(separator: ".", omittingEmptySubsequences: false)
        let parts = strs.compactMap { Int($0) }
        guard strs.count == 4, parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 169 && parts[1] == 254)                      // link-local
            || (parts[0] == 100 && (64...127).contains(parts[1]))        // Tailscale / CGNAT 100.64.0.0/10
    }

    /// An ngrok tunnel (free plans put a warning page in front of browsers; API calls send a skip header).
    public var isNgrok: Bool {
        host.hasSuffix(".ngrok-free.app") || host.hasSuffix(".ngrok-free.dev") || host.hasSuffix(".ngrok.app")
            || host.hasSuffix(".ngrok.io") || host.hasSuffix(".ngrok.dev") || host.hasSuffix(".ngrok-free.io")
    }
    public var isTailscale: Bool {
        if host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
    /// A short default name for a saved address: Tailscale, ngrok, LAN, or the host.
    public var suggestedName: String {
        if isNgrok { return "ngrok" }
        if isTailscale { return "Tailscale" }
        if Endpoint.isPrivate(host) { return host == "localhost" || host.hasPrefix("127.") || host == "[::1]" ? "This computer" : "LAN" }
        return host
    }

    /// The canonical text that goes into storage; `parse(canonicalText)` returns an equal endpoint.
    public var canonicalText: String { origin }

    /// Headers every request and WebSocket to this address must carry. The Origin always equals the Host of THIS
    /// endpoint (the server rejects mismatches); the User-Agent is not a browser's and `ngrok-skip-browser-warning`
    /// keeps ngrok's free-plan interstitial page out of API calls (harmless on every other address).
    public func requestHeaders(token: String?) -> [String: String] {
        var h = ["Origin": origin, "User-Agent": Endpoint.userAgent, "ngrok-skip-browser-warning": "1"]
        if let t = token { h["Cookie"] = "\(Endpoint.cookieName)=\(t)" }
        return h
    }
    public static let userAgent = "JarvisTalk-iOS"

    /// `host[:port]` exactly as the server sees it in the Host header.
    public var authority: String {
        if let port = port, !((secure && port == 443) || (!secure && port == 80)) { return "\(host):\(port)" }
        return host
    }
    public var origin: String { "\(secure ? "https" : "http")://\(authority)" }
    public var display: String { authority }

    public func httpURL(_ path: String, query: [(String, String)] = []) -> URL? {
        build(scheme: secure ? "https" : "http", path: path, query: query)
    }
    public func wsURL(_ path: String, query: [(String, String)] = []) -> URL? {
        build(scheme: secure ? "wss" : "ws", path: path, query: query)
    }
    private func build(scheme: String, path: String, query: [(String, String)]) -> URL? {
        // Built as a string (not URLComponents): IPv6 literals behave differently across platforms there.
        var text = "\(scheme)://\(authority)" + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let parts = query.map { k, v -> String in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }
            text += "?" + parts.joined(separator: "&")
        }
        return URL(string: text)
    }

    public static let cookieName = "jarvis_device"
}
