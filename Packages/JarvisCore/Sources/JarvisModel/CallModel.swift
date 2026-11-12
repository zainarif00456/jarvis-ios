import Foundation
import JarvisCore
import JarvisNet

/// Thread-safe state touched on the audio thread (every 40 ms): mute, mic level, ducking, whether frames may be sent.
final class MicPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false
    private var sending = false
    private var playing = false
    private var meter = LevelMeter()
    private var outMeter = LevelMeter()
    private var duck = DuckDetector()
    var continuation: AsyncStream<Data>.Continuation?

    func configure(muted: Bool? = nil, sending: Bool? = nil, playing: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let m = muted { self.muted = m; if m { meter.reset() } }
        if let s = sending { self.sending = s }
        if let p = playing { self.playing = p; if !p { duck.outputIdle(); outMeter.reset() } }
    }
    var micLevel: Float { lock.lock(); defer { lock.unlock() }; return meter.value }
    var outLevel: Float { lock.lock(); defer { lock.unlock() }; return outMeter.value }
    func outputLevel(_ v: Float) { lock.lock(); outMeter.push(v, muted: false); duck.updateOutput(v); lock.unlock() }
    func restoreDuck() { lock.lock(); duck.restore(); lock.unlock() }

    /// Called per mic frame. Returns true when playback should be softened now.
    func frame(_ data: Data, rms: Float) -> Bool {
        lock.lock()
        meter.push(rms, muted: muted)
        let send = sending && !muted
        let startDuck = duck.micFrame(rms: rms, muted: muted, playing: playing)
        lock.unlock()
        if send { continuation?.yield(data) }
        return startDuck
    }
}

/// The voice call: owns the pure `CallStateMachine` and carries out its effects (audio engine, socket messages,
/// timers, permission prompts).
@MainActor
public final class CallModel: ObservableObject {
    @Published public private(set) var phase: CallStateMachine.Phase = .idle
    @Published public private(set) var voiceState = "idle"
    @Published public private(set) var caption = ""
    @Published public private(set) var muted = false
    @Published public private(set) var notice: String?
    @Published public private(set) var route = ""
    @Published public private(set) var micPermission: PermissionState = .undetermined
    /// The call's audio path is really running: the engine started and no interruption has cut it.
    @Published public private(set) var audioRunning = false
    /// Seconds to wait for the server's `call_started` after `call_start` before saying the call failed.
    public var callStartTimeout: TimeInterval = 15
    /// Automatic retries after a call that never started (seconds before each); then the owner taps to retry.
    public var callRetryDelays: [TimeInterval] = [2, 5, 10]
    /// Fires after every state change: the app model recomputes what it shows.
    public var onChange: () -> Void = {}
    /// Fires when the microphone mute state changes, from any trigger (button, earbud press, lock screen, system mute).
    public var onMutedChanged: (Bool) -> Void = { _ in }

    /// Wired by the app model: how to talk to the server.
    public var sendMessage: (ClientMessage) -> Void = { _ in }
    public var sendAudioFrame: (Data) async -> Void = { _ in }
    /// Fired when a call becomes live / ends (the app updates the lock screen and keeps the screen/audio session in step).
    public var onActiveChanged: (Bool) -> Void = { _ in }

    public var inCall: Bool { machine.inCall }
    public var isActive: Bool { phase == .active }
    public var wantsCall: Bool { machine.wantCall }
    public var micLevel: Float { pipe.micLevel }
    public var outLevel: Float { pipe.outLevel }
    /// What the orb shows: the server's voice state while a call is live, otherwise "idle" (dim when offline is applied by the UI).
    public var orbState: String { isActive ? voiceState : (phase == .held ? "idle" : "idle") }

    private var machine = CallStateMachine()
    private let audio: VoiceAudio
    private let permissions: PermissionProvider
    private let pipe = MicPipe()
    private var holdTask: Task<Void, Never>?
    private var duckTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var started = false
    private var startTimer: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var startFailures = 0
    private var lastAudioRestart = Date.distantPast

    public init(audio: VoiceAudio, permissions: PermissionProvider) {
        self.audio = audio; self.permissions = permissions
        wireAudio()
        var cont: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(60)) { cont = $0 }
        pipe.continuation = cont
        frameTask = Task { [weak self] in
            for await frame in stream { guard let self = self else { return }; await self.sendAudioFrame(frame) }
        }
    }

    deinit { frameTask?.cancel() }

    private func wireAudio() {
        let pipe = self.pipe
        let audio = self.audio
        audio.onMicFrame = { [weak self] data, rms in
            if pipe.frame(data, rms: rms) {
                audio.setDucked(true)
                Task { @MainActor in self?.scheduleUnduck() }
            }
        }
        audio.onOutputLevel = { level in pipe.outputLevel(level) }
        audio.onPlaybackActive = { [weak self] active in
            pipe.configure(playing: active)
            if !active { Task { @MainActor in self?.sendMessage(.voicePlayback(event: "idle", underruns: 0, gapMs: 0)) } }
        }
        audio.onEvent = { [weak self] event in Task { @MainActor in self?.audioEvent(event) } }
    }

    private func scheduleUnduck() {
        duckTask?.cancel()
        duckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DuckDetector.restoreSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            self.audio.setDucked(false); self.pipe.restoreDuck()
        }
    }

    // MARK: lifecycle

    /// Called once the app has an address and a token. Starts the call by itself when the setting says so.
    public func begin(paired: Bool, autoStart: Bool) {
        micPermission = permissions.microphone()
        route = audio.routeName
        run(machine.handle(.micPermission(map(micPermission))))
        run(machine.handle(.launched(paired: paired, autoStart: autoStart)))
        publish()
        started = true
    }

    public func pairedNow() { run(machine.handle(.paired)); publish() }
    public func unpaired() { run(machine.handle(.unpaired)); publish() }
    public func socketWelcomed() { run(machine.handle(.socketWelcomed)); publish() }
    public func socketDropped() { run(machine.handle(.socketDropped)); publish() }
    public func appBecameActive() {
        micPermission = permissions.microphone()
        run(machine.handle(.foregrounded)); publish()
    }

    // MARK: user actions

    public func startCall() { run(machine.handle(.userStartCall)); publish() }
    public func endCall() { run(machine.handle(.userEndCall)); publish() }
    /// Retry a call that never started ("Not connected, tap to retry").
    public func retryCall() {
        retryTask?.cancel(); retryTask = nil
        startFailures = 0
        run(machine.handle(.retryCall))
        if machine.phase == .idle, machine.wantCall == false { startCall() }
        publish()
    }
    public func toggleCall() { if machine.wantCall || machine.inCall { endCall() } else { startCall() } }
    public func toggleMute() { setMuted(!muted) }
    /// Mutes only the microphone that goes to Jarvis. The socket, the call and his voice stay up; nothing else changes.
    /// Returns the state in effect afterwards (false when there is no call to mute).
    @discardableResult
    public func setMuted(_ m: Bool) -> Bool {
        run(machine.handle(.setMuted(m)))
        publish()
        return muted
    }
    /// Earbud press / lock screen: only while a call is on.
    public var canMute: Bool { machine.phase != .idle && !machine.isBlocked }
    /// Stop Jarvis talking (the web page's interrupt button).
    public func interrupt() { audio.cutPlayback(); sendMessage(.interrupt) }

    // MARK: from the server

    public func receive(_ m: ServerMessage) {
        switch m {
        case .callStarted(let resumed):
            run(machine.handle(.serverCallStarted(resumed: resumed)))
        case .callEnded(let reason):
            run(machine.handle(.serverCallEnded(reason: reason)))
        case .voiceState(let s): voiceState = s
        case .voicePartial(let t): caption = t
        case .voiceFinal: caption = ""
        case .voiceStop: audio.cutPlayback(); audio.setDucked(false); pipe.restoreDuck(); duckTask?.cancel()
        case .voiceError(let text, let recoverable):
            notice = recoverable ? "Voice hiccup: \(text)" : text
            if !recoverable { callDidNotStart(text) }
        default: break
        }
        publish()
    }

    public func receiveSpeech(_ pcm: Data) { if machine.inCall { audio.play(pcm) } }

    // MARK: effects

    private func map(_ p: PermissionState) -> CallStateMachine.MicPermission {
        switch p { case .undetermined: return .undetermined; case .granted: return .granted; case .denied: return .denied; case .restricted: return .restricted }
    }

    private func run(_ effects: [CallStateMachine.Effect]) {
        for fx in effects {
            switch fx {
            case .requestMicPermission:
                Task { [weak self] in
                    guard let self = self else { return }
                    let s = await self.permissions.requestMicrophone()
                    self.micPermission = s
                    self.run(self.machine.handle(.micPermission(self.map(s)))); self.publish()
                }
            case .startAudio:
                lastAudioRestart = Date()
                do { try audio.start(); route = audio.routeName; run(machine.handle(.audioStarted)) }
                catch { run(machine.handle(.audioFailed(error.localizedDescription))) }
            case .stopAudio: audio.stop(); onActiveChanged(false)
            case .restartAudio:
                lastAudioRestart = Date()
                do { try audio.restart(); route = audio.routeName } catch { run(machine.handle(.audioFailed(error.localizedDescription))) }
            case .cutPlayback: audio.cutPlayback()
            case .sendCallStart(let manual): sendMessage(.callStart(manual: manual))
            case .sendCallEnd: sendMessage(.callEnd)
            case .startHoldTimer(let secs):
                holdTask?.cancel()
                holdTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                    guard !Task.isCancelled, let self = self else { return }
                    self.run(self.machine.handle(.holdExpired)); self.publish()
                }
            case .cancelHoldTimer: holdTask?.cancel(); holdTask = nil
            case .notice(let t): notice = t
            case .clearNotice: notice = nil
            }
        }
    }

    private func audioEvent(_ e: VoiceAudioEvent) {
        switch e {
        case .interruptionBegan: run(machine.handle(.interruptionBegan))
        case .interruptionEnded(let should): run(machine.handle(.interruptionEnded(shouldResume: should)))
        case .mediaServicesReset: run(machine.handle(.mediaServicesReset))
        case .routeChanged(let name): route = name
        case .engineStopped:
            // the system changed the audio hardware configuration under us; rebuild once (not in a loop)
            if (machine.inCall || machine.audioReady), Date().timeIntervalSince(lastAudioRestart) > 1.5 { run([.restartAudio]) }
        }
        publish()
    }

    /// The server never confirmed the call (timeout or a fatal `voice_error`): say so, then retry by itself a few times.
    private func callDidNotStart(_ why: String) {
        let before = machine.phase
        run(machine.handle(.callStartFailed(why)))
        guard before != machine.phase else { return }
        guard startFailures < callRetryDelays.count else { return }
        let delay = callRetryDelays[startFailures]
        startFailures += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            self.retryTask = nil
            self.run(self.machine.handle(.retryCall)); self.publish()
        }
    }

    /// While `call_start` is out (socket welcomed, audio ready) the server has to answer in time.
    private func watchCallStart() {
        let waiting = machine.phase == .waitingServer && machine.welcomed
        if waiting {
            guard startTimer == nil else { return }
            startTimer = Task { [weak self] in
                guard let timeout = self?.callStartTimeout else { return }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self = self else { return }
                self.startTimer = nil
                self.callDidNotStart("Jarvis did not answer the call.")
                self.publish()
            }
        } else {
            startTimer?.cancel(); startTimer = nil
            if machine.phase == .active { startFailures = 0; retryTask?.cancel(); retryTask = nil }
        }
    }

    private func publish() {
        let was = phase
        phase = machine.phase
        audioRunning = machine.audioReady && !machine.interrupted
        defer { watchCallStart(); onChange() }
        pipe.configure(sending: machine.phase == .active)
        if machine.phase != was {
            if machine.phase == .active { onActiveChanged(true) }
            else if was == .active, machine.phase == .idle || machine.phase.isBlockedPhase { onActiveChanged(false) }
            if machine.phase == .idle || machine.phase == .held { caption = "" }
            if machine.phase == .idle { voiceState = "idle" }
        }
        if muted != machine.muted {
            muted = machine.muted
            onMutedChanged(muted)
        }
        pipe.configure(muted: machine.muted)    // one source of truth: the machine (a new call starts unmuted)
    }
}

extension CallStateMachine.Phase {
    var isBlockedPhase: Bool { if case .blocked = self { return true }; return false }
}
