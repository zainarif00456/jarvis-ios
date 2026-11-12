import Foundation
import JarvisCore

/// A WebSocket for one terminal or one camera (`/ws/terminal/{id}`, `/ws/camera/{id}`): same pairing cookie and
/// Origin as the session socket. Frames come out of `frames`; the stream ends (throwing) when the socket closes.
public final class StreamSocket: @unchecked Sendable {
    private let conn: WebSocketConnection
    public let frames: AsyncThrowingStream<WebSocketFrame, Error>

    public init(endpoint: Endpoint, token: String, path: String, transport: WebSocketTransport = URLSessionTransport()) throws {
        guard let url = endpoint.wsURL(path) else { throw ApiError.badURL }
        let headers = endpoint.requestHeaders(token: token)
        let conn = transport.open(url: url, headers: headers)
        self.conn = conn
        frames = AsyncThrowingStream { continuation in
            let task = Task {
                do { while !Task.isCancelled { continuation.yield(try await conn.receive()) } }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel(); conn.close(normal: true) }
        }
    }

    public func send(binary: Data) { conn.send(binary: binary) { _ in } }
    public func send(json: JSONValue) { Task { try? await conn.send(text: json.serialized()) } }
    public func resize(cols: Int, rows: Int) { send(json: .object(["type": .string("resize"), "cols": .number(Double(cols)), "rows": .number(Double(rows))])) }
    public func focus() { send(json: .object(["type": .string("focus")])) }
    public func close() { conn.close(normal: true) }
}
