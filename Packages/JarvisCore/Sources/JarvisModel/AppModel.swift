import Foundation
import JarvisCore
import JarvisNet

/// The root of the app's state: pairing, the session socket and what to do with every message it delivers.
@MainActor
public final class AppModel: ObservableObject {
    public enum Phase: Equatable { case needsPairing, ready }
    public enum Link: Equatable { case connecting, online, reconnecting, unauthorized, offline }

    @Published public private(set) var phase: Phase = .needsPairing
    @Published public private(set) var link: Link = .connecting
    @Published public private(set) var isForeground = true
    @Published public var pairingError: String?
    @Published public private(set) var pairing = false
    @Published public private(set) var networkOnline = true
    /// The saved address the pairing screen is for (switching to an address that answered "unpaired"); nil = the active one.
    @Published public private(set) var pairingTarget: SavedServer?
    /// Why the current address does not work (e.g. "ngrok warning page or wrong URL"); set after repeated failures. The UI
    /// then offers "Edit address".
    @Published public private(set) var addressProblem: String?
    @Published public private(set) var switching = false

    public let settings: SettingsStore
    public let call: CallModel
    public let chat = ChatModel()
    public let deck = DeckModel()
    public let uploads = UploadModel()
    public let platform: Platform

    public private(set) var api: ApiClient?
    private var session: SessionConnection?
    private var eventTask: Task<Void, Never>?
    private var streamHub: [String: TerminalSession] = [:]
    private var cameraStreams: [WeakCamera] = []
    private var probing = false
    private let visibility = AtomicFlag(true)     // read by the socket when it (re)connects: `v=0|1` in the query

    public init(platform: Platform) {
        self.platform = platform
        settings = SettingsStore(defaults: platform.defaults, secrets: platform.secrets)
        call = CallModel(audio: platform.makeAudio(), permissions: platform.permissions)
        wire()
    }

    private func wire() {
        let send: (ClientMessage) -> Bool = { [weak self] m in self?.send(m) ?? false }
        chat.sendMessage = send; deck.sendMessage = send
        call.sendMessage = { [weak self] m in _ = self?.send(m) }
        call.sendAudioFrame = { [weak self] d in _ = await self?.session?.sendAudio(d) }
        let provider: () -> ApiClient? = { [weak self] in self?.api }
        chat.apiProvider = provider; deck.apiProvider = provider; uploads.apiProvider = provider
        uploads.onUploaded = { [weak self] item, _ in
            if item.destination == .files { Task { await self?.deck.loadFiles(kind: "upload") } } else { Task { await self?.deck.loadMedia() } }
        }
    }

    // MARK: start

    /// Call once when the app launches. Connects at once when a pairing exists.
    public func launch() {
        if let ep = settings.endpoint, let token = settings.token {
            phase = .ready
            openSession(ep, token)
            call.begin(paired: true, autoStart: settings.autoStartCall)
        } else {
            phase = .needsPairing
            call.begin(paired: false, autoStart: false)
        }
    }

    private func openSession(_ ep: Endpoint, _ token: String) {
        eventTask?.cancel()
        let old = session
        Task { await old?.stop() }
        api = ApiClient(endpoint: ep, token: token)
        let s = SessionConnection(endpoint: ep, token: token, transport: platform.transport.make(), visible: { [visibility] in visibility.value })
        session = s
        link = .connecting
        addressProblem = nil
        eventTask = Task { [weak self] in
            for await event in s.events { guard let self = self else { return }; self.handle(event) }
        }
        Task { await s.start() }
    }

    // MARK: pairing

    public func pair(address: String, code: String, name: String) async {
        pairingError = nil
        let ep: Endpoint
        do { ep = try Endpoint.parse(address) } catch { pairingError = error.localizedDescription; return }
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanCode.count >= 4 else { pairingError = "Enter the pairing code that `jarvis pair` printed."; return }
        let deviceName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "iPhone" : name.trimmingCharacters(in: .whitespaces)
        pairing = true; defer { pairing = false }
        do {
            let token = try await ApiClient.pair(endpoint: ep, code: cleanCode, name: deviceName)
            // the owner fixed the address of a saved entry on the pairing screen: update it instead of duplicating it
            if let t = pairingTarget, t.endpoint != ep, !settings.servers.contains(where: { $0.endpoint == ep }) {
                _ = try? settings.updateServer(id: t.id, name: t.name, address: ep.canonicalText)
            }
            guard settings.savePairing(endpoint: ep, token: token, deviceName: deviceName) else {
                pairingError = "Could not save the device token to the Keychain."; return
            }
            phase = .ready
            pairingTarget = nil
            for (_, t) in streamHub { t.retarget(endpoint: ep, token: token) }
            retargetCameras(ep, token)
            openSession(ep, token)
            call.begin(paired: true, autoStart: settings.autoStartCall)
            call.pairedNow()
        } catch let e as ApiError {
            pairingError = Self.pairingMessage(e)
        } catch { pairingError = error.localizedDescription }
    }

    static func pairingMessage(_ e: ApiError) -> String {
        switch e {
        case .http(let status, let detail):
            if status == 429 { return "Too many attempts. Wait a minute and try again." }
            if status == 403 { return "The server refused the request (origin check). Check the address." }
            return detail.isEmpty ? "Pairing failed (HTTP \(status))." : detail.prefix(1).uppercased() + detail.dropFirst()
        case .offline(let why):
            return "Cannot reach the server: \(why)"
        case .notJarvis:
            return "That address answered with a web page: an ngrok warning page or the wrong URL. Check the address."
        default: return e.localizedDescription
        }
    }

    /// Forget this phone: stop everything, delete the token.
    public func forgetDevice() {
        call.endCall()
        call.unpaired()
        let closing = session
        Task { await closing?.stop() }
        session = nil; api = nil
        eventTask?.cancel()
        for (_, t) in streamHub { t.disconnect() }
        streamHub.removeAll()
        settings.forgetDevice()
        pairingTarget = nil; addressProblem = nil
        phase = .needsPairing
        link = .connecting
    }

    // MARK: addresses

    public enum SwitchOutcome: Equatable { case switched, needsPairing, failed(String) }

    /// One-tap switch to a saved address. The device token belongs to the Jarvis server, not the URL: the target's own
    /// token is tried first, then the current one; the first that `GET /api/session` calls paired is kept for the target and
    /// the session, terminals, cameras and uploads move to the new address with no re-pairing. If the new address answers
    /// "unpaired" the pairing screen opens for it (the old address stays as it was until pairing succeeds).
    @discardableResult
    public func switchTo(_ id: String) async -> SwitchOutcome {
        guard let target = settings.servers.first(where: { $0.id == id }), let ep = target.endpoint else { return .failed(ServerListError.notFound.localizedDescription) }
        if id == settings.activeID, phase == .ready { reconnectNow(); return .switched }
        var candidates: [String] = []
        for t in [settings.token(for: id), settings.token] { if let t = t, !candidates.contains(t) { candidates.append(t) } }
        if candidates.isEmpty { beginPairing(target); return .needsPairing }
        switching = true; defer { switching = false }
        var lastWhy = ""
        for t in candidates {
            switch await ApiClient(endpoint: ep, token: t).probe() {
            case .paired:
                guard settings.setToken(t, for: id) else { return .failed(ServerListError.saveFailed.localizedDescription) }
                settings.setActive(id)
                moveEverything(to: ep, token: t)
                return .switched
            case .unpaired: continue
            case .unreachable(let why): lastWhy = why
            }
            if !lastWhy.isEmpty { break }
        }
        if !lastWhy.isEmpty { return .failed(lastWhy) }
        beginPairing(target)
        return .needsPairing
    }

    /// `GET /api/session` against any address (saved, or being typed). Uses that address's token, else the current one.
    public func testConnection(address: String, serverID: String? = nil) async -> ApiClient.Probe {
        let ep: Endpoint
        do { ep = try Endpoint.parse(address) } catch { return .unreachable(error.localizedDescription) }
        let t = serverID.flatMap { settings.token(for: $0) } ?? settings.token
        return await ApiClient(endpoint: ep, token: t).probe()
    }

    /// The active address was edited (same server at a new URL, e.g. after an ngrok restart): reconnect to it.
    public func activeAddressEdited() {
        guard let ep = settings.endpoint, let token = settings.token else { return }
        moveEverything(to: ep, token: token)
    }

    public func reconnectNow() {
        guard let ep = settings.endpoint, let token = settings.token else { return }
        moveEverything(to: ep, token: token)
    }

    private func moveEverything(to ep: Endpoint, token: String) {
        phase = .ready; pairingTarget = nil; pairingError = nil
        for (_, t) in streamHub { t.retarget(endpoint: ep, token: token) }
        retargetCameras(ep, token)
        openSession(ep, token)       // uploads and REST follow `api`, which openSession replaces
    }

    private func beginPairing(_ target: SavedServer) {
        pairingTarget = target
        pairingError = "This phone is not paired on \(target.address). Enter a pairing code from `jarvis pair`."
        phase = .needsPairing
    }

    /// Leave the pairing screen opened by a switch and stay on the address that works.
    public func cancelPairing() {
        guard settings.isPaired, session != nil else { return }
        pairingTarget = nil; pairingError = nil; phase = .ready
    }
    public var canCancelPairing: Bool { session != nil && settings.isPaired }

    private func retargetCameras(_ ep: Endpoint, _ token: String) {
        cameraStreams.removeAll { $0.stream == nil }
        for w in cameraStreams { w.stream?.retarget(endpoint: ep, token: token) }
    }

    private func checkAddress(attempt: Int) {
        guard attempt >= 2, !probing, addressProblem == nil, let ep = settings.endpoint else { return }
        probing = true
        let token = settings.token
        Task { [weak self] in
            let p = await ApiClient(endpoint: ep, token: token).probe()
            guard let self = self else { return }
            self.probing = false
            if case .unreachable(let why) = p, self.link != .online { self.addressProblem = why }
        }
    }

    // MARK: sending

    @discardableResult
    public func send(_ m: ClientMessage) -> Bool {
        guard let s = session else { return false }
        Task { _ = await s.send(m) }
        return link == .online
    }

    // MARK: events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .state(let st):
            switch st {
            case .idle: break
            case .connecting: link = .connecting
            case .open: link = .online; addressProblem = nil
            case .reconnecting(let attempt):
                link = networkOnline ? .reconnecting : .offline; call.socketDropped()
                if networkOnline { checkAddress(attempt: attempt) }
            case .unauthorized:
                link = .unauthorized
                call.unpaired()
                settings.forgetActiveToken()
                pairingTarget = settings.activeServer
                pairingError = "This phone is not paired on this address (or was removed from Jarvis). Pair it with a new code."
                phase = .needsPairing
            }
        case .audio(let d): call.receiveSpeech(d)
        case .message(let m): route(m)
        }
    }

    func route(_ m: ServerMessage) {
        switch m {
        case .welcome(let w):
            deck.apply(m)
            chat.setHistory(w.history)
            call.socketWelcomed()
            send(.presence(visible: isForeground))
            Task { await deck.loadMedia(); await deck.loadSessions() }
        case .callStarted, .callEnded, .voiceState, .voicePartial, .voiceStop, .voiceError:
            call.receive(m); chat.apply(m)
        case .voiceFinal: call.receive(m); chat.apply(m)
        case .unknown, .malformed, .pong: break
        default:
            deck.apply(m); chat.apply(m)
        }
    }

    // MARK: lifecycle

    public func sceneBecameActive() {
        isForeground = true; visibility.value = true
        send(.presence(visible: true))
        call.appBecameActive()
        Task { await session?.nudge() }
    }
    public func sceneBecameInactive(background: Bool) {
        isForeground = false; visibility.value = false
        send(.presence(visible: false))
    }
    public func networkChanged(online: Bool) {
        networkOnline = online
        if online { Task { await session?.nudge() } } else if link != .online { link = .offline }
    }

    // MARK: terminals (kept alive while the app runs so switching tabs does not drop them)

    public func terminalSession(for info: TerminalInfo) -> TerminalSession? {
        if let t = streamHub[info.id] { return t }
        guard let ep = settings.endpoint, let token = settings.token else { return nil }
        let t = TerminalSession(info: info, endpoint: ep, token: token, transport: platform.transport.make())
        streamHub[info.id] = t
        return t
    }
    public func dropTerminalSession(_ id: String) { streamHub[id]?.disconnect(); streamHub[id] = nil }

    public func cameraStream(for cam: CameraInfo) -> CameraStream? {
        guard let ep = settings.endpoint, let token = settings.token else { return nil }
        let s = CameraStream(camera: cam, endpoint: ep, token: token, transport: platform.transport.make())
        cameraStreams.removeAll { $0.stream == nil }
        cameraStreams.append(WeakCamera(s))
        return s
    }
}

private final class WeakCamera { weak var stream: CameraStream?; init(_ s: CameraStream) { stream = s } }

/// A Bool that can be read from any thread.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}
