import Foundation
import JarvisCore
import JarvisNet

/// Shared reconnect policy for the terminal and camera sockets: retry with backoff, give up after several
/// consecutive failures that never delivered anything (an unknown id closes the socket at once).
@MainActor
public final class StreamRunner {
    public enum Status: Equatable { case connecting, live, retrying(Int), failed(String), stopped }
    public private(set) var status: Status = .stopped { didSet { if status != oldValue { onStatus?(status) } } }
    public var onStatus: ((Status) -> Void)?
    private var task: Task<Void, Never>?
    private var socket: StreamSocket?
    private let maxFailures: Int
    private let open: () throws -> StreamSocket
    private let onFrame: (WebSocketFrame) -> Void
    private let onConnected: (StreamSocket) -> Void
    private let onReset: () -> Void

    public init(maxFailures: Int = 6, open: @escaping () throws -> StreamSocket, onConnected: @escaping (StreamSocket) -> Void = { _ in },
                onReset: @escaping () -> Void = {}, onFrame: @escaping (WebSocketFrame) -> Void) {
        self.maxFailures = maxFailures; self.open = open; self.onFrame = onFrame; self.onConnected = onConnected; self.onReset = onReset
    }

    public var currentSocket: StreamSocket? { socket }

    public func start() {
        guard task == nil else { return }
        status = .connecting
        task = Task { [weak self] in await self?.loop() }
    }

    public func stop() {
        task?.cancel(); task = nil
        socket?.close(); socket = nil
        status = .stopped
    }

    private func loop() async {
        var backoff = Backoff(jitterMs: 200)
        var failures = 0
        while !Task.isCancelled {
            var gotData = false
            do {
                let s = try open()
                socket = s
                onReset()
                onConnected(s)
                for try await frame in s.frames {
                    if Task.isCancelled { return }
                    if !gotData { gotData = true; failures = 0; backoff.reset(); status = .live }
                    onFrame(frame)
                }
            } catch is CancellationError { return } catch { /* closed or failed: fall through to the retry */ }
            socket?.close(); socket = nil
            if Task.isCancelled { return }
            failures += gotData ? 0 : 1
            if failures >= maxFailures { status = .failed("Could not stay connected."); task = nil; return }
            status = .retrying(max(1, failures))
            try? await Task.sleep(nanoseconds: UInt64(backoff.nextDelay() * 1_000_000_000))
        }
    }
}

/// One live terminal: the socket, the emulator, and what the keyboard sends.
@MainActor
public final class TerminalSession: ObservableObject {
    public let id: String
    @Published public private(set) var status: StreamRunner.Status = .stopped
    @Published public private(set) var title: String
    public let emulator: TerminalEmulator
    /// The view redraws from this (called on the main thread after output was parsed).
    public var onUpdate: (() -> Void)?

    private var runner: StreamRunner?
    private var cols = 80, rows = 24
    private var endpoint: Endpoint
    private var token: String
    private let transport: WebSocketTransport

    public init(info: TerminalInfo, endpoint: Endpoint, token: String, transport: WebSocketTransport = URLSessionTransport()) {
        id = info.id; title = info.title ?? "Terminal"
        self.endpoint = endpoint; self.token = token; self.transport = transport
        cols = info.cols ?? 80; rows = info.rows ?? 24
        emulator = TerminalEmulator(cols: cols, rows: rows)
        emulator.onResponse = { [weak self] data in Task { @MainActor in self?.send(data) } }
    }

    public func connect() {
        guard runner == nil else { return }
        let r = StreamRunner(open: { [endpoint, token, transport, id] in try StreamSocket(endpoint: endpoint, token: token, path: "/ws/terminal/\(id)", transport: transport) },
                             onConnected: { [weak self] s in Task { @MainActor in self?.afterConnect(s) } },
                             onReset: { [weak self] in Task { @MainActor in self?.emulator.reset() } },   // the server replays the screen
                             onFrame: { [weak self] f in Task { @MainActor in self?.handle(f) } })
        r.onStatus = { [weak self] s in self?.status = s }
        runner = r
        r.start()
    }
    public func disconnect() { runner?.stop(); runner = nil }
    /// The server moved to another address (or token): reconnect there; the server replays the screen.
    public func retarget(endpoint: Endpoint, token: String) {
        self.endpoint = endpoint; self.token = token
        guard runner != nil else { return }
        runner?.stop(); runner = nil
        connect()
    }

    private func afterConnect(_ s: StreamSocket) { s.resize(cols: cols, rows: rows) }

    private func handle(_ f: WebSocketFrame) {
        switch f {
        case .binary(let d): emulator.feed(d); onUpdate?()
        case .text(let t):
            if let v = JSONValue.parse(t), v["type"]?.string == "info", let name = v["terminal"]?["title"]?.string, !name.isEmpty { title = name }
        }
    }

    public func send(_ data: Data) { runner?.currentSocket?.send(binary: data) }
    public func send(_ text: String) { send(Data(text.utf8)) }
    public func sendKey(_ key: TerminalKeys.Special) { send(TerminalKeys.bytes(for: key, applicationCursor: emulator.buffer.applicationCursorKeys)) }
    public func paste(_ text: String) { send(TerminalKeys.paste(text, bracketed: emulator.buffer.bracketedPaste)) }

    /// The view measured a new size in character cells.
    public func resize(cols c: Int, rows r: Int) {
        guard c >= 2, r >= 1, (c != cols || r != rows) else { return }
        cols = c; rows = r
        emulator.resize(cols: c, rows: r)
        runner?.currentSocket?.resize(cols: c, rows: r)
        onUpdate?()
    }
}

/// One live camera view: fMP4 in, H.264 frames out to the display layer.
@MainActor
public final class CameraStream: ObservableObject {
    public let camera: CameraInfo
    @Published public private(set) var status: StreamRunner.Status = .stopped
    @Published public private(set) var detail = ""
    @Published public private(set) var size: (Int, Int) = (0, 0)
    @Published public private(set) var framesShown = 0
    @Published public private(set) var unsupported: String?

    /// Wired by the video view: a (new) track description, then frames. Called on the main thread.
    public var onTrack: ((VideoTrack) -> Void)?
    public var onSamples: (([VideoSample]) -> Void)?

    private var runner: StreamRunner?
    private let demuxer = FMP4Demuxer()
    private var endpoint: Endpoint, token: String
    private let transport: WebSocketTransport

    public init(camera: CameraInfo, endpoint: Endpoint, token: String, transport: WebSocketTransport = URLSessionTransport()) {
        self.camera = camera; self.endpoint = endpoint; self.token = token; self.transport = transport
    }

    public func start() {
        guard runner == nil else { return }
        let r = StreamRunner(open: { [endpoint, token, transport, camera] in try StreamSocket(endpoint: endpoint, token: token, path: "/ws/camera/\(camera.id)", transport: transport) },
                             onReset: { [weak self] in Task { @MainActor in self?.demuxer.reset() } },
                             onFrame: { [weak self] f in Task { @MainActor in self?.handle(f) } })
        r.onStatus = { [weak self] s in self?.status = s }
        runner = r
        r.start()
    }
    public func stop() { runner?.stop(); runner = nil }
    public func retarget(endpoint: Endpoint, token: String) {
        self.endpoint = endpoint; self.token = token
        guard runner != nil else { return }
        runner?.stop(); runner = nil
        demuxer.reset()
        start()
    }

    private func handle(_ f: WebSocketFrame) {
        switch f {
        case .text(let t):
            guard let v = JSONValue.parse(t) else { return }
            if v["type"]?.string == "status" { detail = v["detail"]?.string ?? v["state"]?.string ?? "" }
            if v["type"]?.string == "init" { demuxer.reset() }     // the camera restarted: a new init segment follows
        case .binary(let d):
            do {
                for e in try demuxer.push(d) {
                    switch e {
                    case .initSegment(let t): size = (t.width, t.height); unsupported = nil; onTrack?(t)
                    case .samples(let s): framesShown += s.count; onSamples?(s)
                    }
                }
            } catch FMP4Error.unsupported(let why) {
                unsupported = why; runner?.stop(); runner = nil
            } catch { demuxer.reset() }     // a corrupt fragment: wait for the next init segment
        }
    }
}
