import Foundation
import JarvisCore

public enum ConnectionState: Equatable, Sendable {
    case idle                       // not started
    case connecting
    case open                       // socket open, `welcome` received
    case reconnecting(attempt: Int) // lost; retrying
    case unauthorized               // the server no longer knows this device: pair again
}

public enum SessionEvent: Sendable {
    case state(ConnectionState)
    case message(ServerMessage)
    case audio(Data)                // binary frame: 24 kHz Int16 speech
}

/// The `/ws/session` socket that stays up. One socket at a time; reconnects by itself with the web client's
/// backoff; a ping every 15 s with a 20 s answer deadline detects dead sockets that the OS has not noticed.
///
/// Events come out of `events` (an AsyncStream). Everything is serialised inside the actor.
public actor SessionConnection {
    public struct Config: Sendable {
        public var clientName = "ios"
        public var pingEvery: TimeInterval = 15
        public var pongTimeout: TimeInterval = 20
        public var maxQueuedAudio = 50          // 2 s of mic audio; beyond this frames are dropped, never queued
        public var backoffJitterMs: Double = 250
        public init() {}
    }

    public nonisolated let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation

    private let endpoint: Endpoint
    private let token: String
    private let transport: WebSocketTransport
    private let config: Config
    private let api: ApiClient
    private let visible: @Sendable () -> Bool

    private var wanted = false
    private var runTask: Task<Void, Never>?
    private var current: WebSocketConnection?
    private var everOpen = false
    private var lastClose = ""
    private var generation = 0
    private var backoff: Backoff
    private var state: ConnectionState = .idle
    private var wake: CheckedContinuation<Void, Never>?
    private let audioGate = AudioGate()

    public init(endpoint: Endpoint, token: String, transport: WebSocketTransport = URLSessionTransport(), config: Config = Config(), visible: @escaping @Sendable () -> Bool = { true }) {
        self.endpoint = endpoint; self.token = token; self.transport = transport; self.config = config; self.visible = visible
        self.api = ApiClient(endpoint: endpoint, token: token)
        self.backoff = Backoff(jitterMs: config.backoffJitterMs)
        var c: AsyncStream<SessionEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public var connectionState: ConnectionState { state }
    public var isOpen: Bool { state == .open }

    // MARK: control

    public func start() {
        guard !wanted else { return }
        wanted = true
        runTask = Task { [weak self] in await self?.run() }
    }

    /// Ends the connection for good with a normal close (code 1000): the server ends a call at once on it.
    public func stop() {
        wanted = false
        generation += 1
        current?.close(normal: true)
        current = nil
        runTask?.cancel(); runTask = nil
        wakeUp()
        set(.idle)
        continuation.finish()
    }

    /// Something changed that makes a reconnect worth trying now (network back, app foregrounded).
    public func nudge() {
        guard wanted else { return }
        if state != .open { backoff.reset(); wakeUp() }
    }

    @discardableResult
    public func send(_ message: ClientMessage) -> Bool {
        guard let conn = current, state == .open || message.isKeepalive else { return false }
        let text = message.json()
        Task { try? await conn.send(text: text) }
        return true
    }

    /// One 40 ms mic frame. Dropped (not queued) when the socket is not open or has fallen behind.
    @discardableResult
    public func sendAudio(_ frame: Data) -> Bool {
        guard state == .open, let conn = current, audioGate.tryEnter(limit: config.maxQueuedAudio) else { return false }
        let gate = audioGate
        conn.send(binary: frame) { _ in gate.leave() }
        return true
    }

    // MARK: loop

    private func set(_ s: ConnectionState) {
        guard s != state else { return }
        state = s
        continuation.yield(.state(s))
    }

    private func wakeUp() { wake?.resume(); wake = nil }

    private func sleep(_ seconds: TimeInterval) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                wake = c
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    await self?.wakeUp()
                }
            }
        } onCancel: { Task { await self.wakeUp() } }
    }

    private func run() async {
        var failuresBeforeWelcome = 0
        while wanted, !Task.isCancelled {
            set(everOpen || failuresBeforeWelcome > 0 ? .reconnecting(attempt: max(1, backoff.attempt)) : .connecting)
            generation += 1
            let mine = generation
            let welcomed = await runOnce(mine)
            guard wanted, !Task.isCancelled else { return }
            if welcomed { failuresBeforeWelcome = 0; backoff.reset() } else { failuresBeforeWelcome += 1 }
            // never welcomed: the device may have been revoked (the server closes with 4401, which URLSession
            // cannot report), so ask the one endpoint that never answers 401
            if !welcomed, await api.isPaired() == false {
                wanted = false
                set(.unauthorized)
                continuation.finish()
                return
            }
            set(.reconnecting(attempt: max(1, backoff.attempt + 1)))
            await sleep(backoff.nextDelay())
        }
    }

    /// One socket's life. Returns whether the server's `welcome` arrived.
    private func runOnce(_ mine: Int) async -> Bool {
        var query: [(String, String)] = [("r", everOpen ? "1" : "0"), ("v", visible() ? "1" : "0")]
        if !lastClose.isEmpty, let extra = Self.parseQuery(lastClose) { query += extra }
        guard let url = endpoint.wsURL("/ws/session", query: query) else { return false }
        let headers = endpoint.requestHeaders(token: token)
        let conn = transport.open(url: url, headers: headers)
        current = conn
        var welcomed = false
        let watch = Watch()
        let pinger = Task { [weak self] in
            while !Task.isCancelled {
                let tick = min(self?.config.pingEvery ?? 15, (self?.config.pongTimeout ?? 20) / 2)
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard let self = self, !Task.isCancelled else { return }
                if await self.stale(watch) { conn.close(normal: false); return }
            }
        }
        defer { pinger.cancel() }
        do {
            while true {
                let frame = try await conn.receive()
                guard mine == generation, wanted else { conn.close(normal: true); return welcomed }
                watch.heard()
                switch frame {
                case .binary(let d): continuation.yield(.audio(d))
                case .text(let t):
                    guard let m = ServerMessageDecoder.decode(t) else { continue }
                    if case .pong = m { continue }
                    if case .welcome = m {
                        welcomed = true; everOpen = true
                        backoff.reset(); lastClose = ""
                        // greet the server like the web page, then announce ourselves as ready
                        try? await conn.send(text: ClientMessage.hello(client: config.clientName).json())
                        set(.open)
                    }
                    continuation.yield(.message(m))
                }
            }
        } catch {
            if mine == generation, !lastClose.hasPrefix("c=4000") { lastClose = "c=1006&h=\(visible() ? 0 : 1)&o=1" }
            if current === conn { current = nil }
            if wanted { conn.close(normal: false) }
            if mine == generation, welcomed { set(.reconnecting(attempt: 1)) }
            return welcomed
        }
    }

    private func stale(_ watch: Watch) -> Bool {
        guard state == .open, let conn = current else { return false }
        if watch.unanswered(timeout: config.pongTimeout) { lastClose = "c=4000&h=\(visible() ? 0 : 1)&o=1"; return true }
        if watch.shouldPing(every: config.pingEvery) {
            watch.pinged()
            Task { try? await conn.send(text: ClientMessage.ping.json()) }
        }
        return false
    }

    static func parseQuery(_ s: String) -> [(String, String)]? {
        let pairs = s.split(separator: "&").compactMap { part -> (String, String)? in
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }
        return pairs.isEmpty ? nil : pairs
    }
}

/// Last time anything was heard, and the last ping, to spot a socket that stopped answering.
final class Watch: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRx = Date()
    private var lastPing: Date?
    func heard() { lock.lock(); lastRx = Date(); lock.unlock() }
    func pinged() { lock.lock(); lastPing = Date(); lock.unlock() }
    /// A new ping is due when none is outstanding and the interval has passed.
    func shouldPing(every: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = lastPing else { return true }
        return lastRx >= p && Date().timeIntervalSince(p) >= every
    }
    func unanswered(timeout: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = lastPing else { return false }
        return lastRx < p && Date().timeIntervalSince(p) > timeout
    }
}

/// Counts audio frames handed to the socket but not yet written out, so a stalled network cannot build a backlog.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    func tryEnter(limit: Int) -> Bool { lock.lock(); defer { lock.unlock() }; if inFlight >= limit { return false }; inFlight += 1; return true }
    func leave() { lock.lock(); inFlight = max(0, inFlight - 1); lock.unlock() }
}
