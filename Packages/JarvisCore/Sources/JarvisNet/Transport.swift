import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JarvisCore

public enum WebSocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

public enum WebSocketError: Error, Equatable, LocalizedError {
    case closed(code: Int?)
    case notConnected
    public var errorDescription: String? {
        switch self {
        case .closed(let c): return c.map { "The connection closed (\($0))." } ?? "The connection closed."
        case .notConnected: return "Not connected."
        }
    }
}

/// One open WebSocket. Implemented over URLSession; faked in tests.
public protocol WebSocketConnection: AnyObject, Sendable {
    func send(text: String) async throws
    /// Fire-and-forget binary send (audio frames): the completion reports failure; never blocks the caller.
    func send(binary: Data, completion: @escaping @Sendable (Error?) -> Void)
    func receive() async throws -> WebSocketFrame
    /// `normal` = a deliberate close (the server ends a call at once on 1000); otherwise "going away".
    func close(normal: Bool)
}

public protocol WebSocketTransport: Sendable {
    func open(url: URL, headers: [String: String]) -> WebSocketConnection
}

public final class URLSessionTransport: WebSocketTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
                cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    public func open(url: URL, headers: [String: String]) -> WebSocketConnection {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = 16 * 1024 * 1024
        let conn = URLSessionConnection(task: task)
        task.resume()
        return conn
    }
}

final class URLSessionConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(text: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.send(.string(text)) { error in
                if let error = error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
    func send(binary: Data, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.data(binary), completionHandler: completion)
    }
    func receive() async throws -> WebSocketFrame {
        let m = try await task.receive()
        switch m {
        case .string(let s): return .text(s)
        case .data(let d): return .binary(d)
        @unknown default: return .binary(Data())
        }
    }
    func close(normal: Bool) {
        task.cancel(with: normal ? .normalClosure : .goingAway, reason: nil)
    }
}

extension URLSessionConfiguration {
    /// A session configuration without cookie storage, that fails fast when offline (the app owns retrying and
    /// shows the state). `waitsForConnectivity` is off by default and is not settable on Linux.
    static func jarvisEphemeral() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        return cfg
    }
}
