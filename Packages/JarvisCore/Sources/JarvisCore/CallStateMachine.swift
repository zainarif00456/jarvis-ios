import Foundation

/// The voice call as a pure state machine: no sockets, no audio, no timers. The app feeds it events and
/// carries out the effects it returns, so every rule (instant start, resume after a dropped socket, hold
/// timeout, user mute / end, interruptions, permission outcomes) is unit tested on Linux.
///
/// Semantics follow the web page (js/main.js `ensureCall`, `holdCall`, `toggleCall`):
///  - after connecting, a wanted call starts by itself with `call_start {manual:false}` (silent start);
///    a Call tap sends `manual:true` (the server says "I'm listening.");
///  - a dropped socket does not end the call: audio stays ready for `holdSeconds` while the socket
///    reconnects, then `call_start {manual:false}` resumes the server-side call (it keeps it parked 45 s);
///  - ending on purpose sends `call_end` and stops wanting a call until the owner taps Call again.
public struct CallStateMachine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle               // no call, none running
        case needsPermission    // wants a call but the microphone is undetermined / being asked
        case blocked(Blocker)   // wants a call but cannot (see Blocker); waits for the owner
        case startingAudio      // permission ok, audio engine starting
        case waitingServer      // audio ready, waiting for the socket / call_started
        case active             // call_started received, talking
        case held               // socket dropped during a call: audio kept ready, reconnecting
    }
    public enum Blocker: Equatable, Sendable { case micDenied, micRestricted, audioFailed(String) }

    public enum Event: Equatable, Sendable {
        case launched(paired: Bool, autoStart: Bool)
        case paired                       // pairing succeeded (auto start follows)
        case unpaired                     // server forgot this device / owner forgot it
        case socketWelcomed               // welcome received: ready for call_start
        case socketDropped
        case micPermission(MicPermission) // answer to .requestMicPermission (or a changed-in-Settings check)
        case audioStarted
        case audioFailed(String)
        case serverCallStarted(resumed: Bool)
        case serverCallEnded(reason: String?)
        case userStartCall
        case userEndCall
        case holdExpired
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case mediaServicesReset
        case foregrounded                 // app became active: re-check permission / connection
        case setMuted(Bool)
    }
    public enum MicPermission: Equatable, Sendable { case undetermined, granted, denied, restricted }

    public enum Effect: Equatable, Sendable {
        case requestMicPermission
        case startAudio
        case stopAudio
        case restartAudio
        case cutPlayback
        case sendCallStart(manual: Bool)
        case sendCallEnd
        case startHoldTimer(seconds: Double)
        case cancelHoldTimer
        case notice(String)
        case clearNotice
    }

    public static let holdSeconds: Double = 180

    public private(set) var phase: Phase = .idle
    public private(set) var wantCall = false
    public private(set) var muted = false
    public private(set) var paired = false
    public private(set) var welcomed = false
    public private(set) var audioReady = false
    public private(set) var interrupted = false
    public private(set) var nextManual = false      // the pending call_start came from a tap
    private var micKnown: MicPermission = .undetermined

    public init() {}

    public var inCall: Bool { phase == .active || phase == .held }
    public var isBlocked: Bool { if case .blocked = phase { return true }; return false }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        var fx: [Effect] = []
        switch event {
        case .launched(let isPaired, let autoStart):
            paired = isPaired
            wantCall = isPaired && autoStart
            if wantCall { advance(&fx) }

        case .paired:
            paired = true
            wantCall = true
            nextManual = false
            advance(&fx)

        case .unpaired:
            paired = false; welcomed = false
            teardown(&fx, sendEnd: false)
            wantCall = false
            phase = .idle

        case .socketWelcomed:
            welcomed = true
            switch phase {
            case .held:
                fx.append(.cancelHoldTimer)
                fx.append(.sendCallStart(manual: false))      // pick the parked call back up
                phase = .waitingServer
            case .waitingServer:
                fx.append(.sendCallStart(manual: nextManual)); nextManual = false
            case .idle where wantCall && paired:
                advance(&fx)
            default: break
            }

        case .socketDropped:
            welcomed = false
            switch phase {
            case .active:
                phase = .held
                fx.append(.cutPlayback)
                fx.append(.startHoldTimer(seconds: Self.holdSeconds))
            case .waitingServer where audioReady:
                phase = .held
                fx.append(.cutPlayback)
                fx.append(.startHoldTimer(seconds: Self.holdSeconds))
            default: break
            }

        case .micPermission(let p):
            micKnown = p
            guard wantCall else { break }
            switch p {
            case .granted:
                if phase == .needsPermission || phase == .blocked(.micDenied) || phase == .blocked(.micRestricted) { advance(&fx) }
            case .denied:
                phase = .blocked(.micDenied)
                fx.append(.notice("Microphone access is off. Turn it on in Settings to talk to Jarvis."))
            case .restricted:
                phase = .blocked(.micRestricted)
                fx.append(.notice("The microphone is restricted on this iPhone (Screen Time or a profile)."))
            case .undetermined:
                phase = .needsPermission
                fx.append(.requestMicPermission)
            }

        case .audioStarted:
            guard phase == .startingAudio else { break }
            audioReady = true
            phase = .waitingServer
            if welcomed { fx.append(.sendCallStart(manual: nextManual)); nextManual = false }

        case .audioFailed(let why):
            audioReady = false
            if phase == .startingAudio || phase == .waitingServer || phase == .active || phase == .held {
                phase = .blocked(.audioFailed(why))
                fx.append(.notice("Could not start the audio: \(why)"))
            }

        case .serverCallStarted(let resumed):
            _ = resumed
            if phase == .waitingServer || phase == .held || phase == .startingAudio {
                phase = .active
                fx.append(.cancelHoldTimer)
                fx.append(.clearNotice)
            }

        case .serverCallEnded(let reason):
            let was = phase
            teardown(&fx, sendEnd: false)
            wantCall = false
            phase = .idle
            if was != .idle, let r = reason, !r.isEmpty { fx.append(.notice(r)) }

        case .userStartCall:
            wantCall = true
            nextManual = true
            fx.append(.clearNotice)
            switch phase {
            case .active, .held, .startingAudio, .waitingServer: break
            default: advance(&fx)
            }

        case .userEndCall:
            let wasLive = phase != .idle
            teardown(&fx, sendEnd: wasLive)
            wantCall = false
            phase = .idle

        case .holdExpired:
            guard phase == .held else { break }
            teardown(&fx, sendEnd: false)
            phase = .idle                       // wantCall stays true: the next welcome starts a fresh call
            fx.append(.notice("Connection lost. Reconnecting…"))

        case .interruptionBegan:
            interrupted = true
            if phase == .active || phase == .waitingServer { fx.append(.cutPlayback) }

        case .interruptionEnded:
            guard interrupted else { break }
            interrupted = false
            if audioReady, phase != .idle { fx.append(.restartAudio) }

        case .mediaServicesReset:
            if audioReady, phase != .idle { fx.append(.restartAudio) }

        case .foregrounded:
            if wantCall, isBlocked {
                fx.append(.requestMicPermission)      // re-check: the owner may have changed it in Settings
            }

        case .setMuted(let m):
            muted = m
        }
        return fx
    }

    /// Moves a wanted call forward as far as it can go.
    private mutating func advance(_ fx: inout [Effect]) {
        guard wantCall, paired else { return }
        switch micKnown {
        case .granted:
            if phase == .idle || phase == .needsPermission || isBlocked {
                phase = .startingAudio
                fx.append(.startAudio)
            }
        case .undetermined:
            phase = .needsPermission
            fx.append(.requestMicPermission)
        case .denied:
            phase = .blocked(.micDenied)
            fx.append(.requestMicPermission)       // re-checks the live status (it may have been fixed in Settings)
        case .restricted:
            phase = .blocked(.micRestricted)
        }
    }

    private mutating func teardown(_ fx: inout [Effect], sendEnd: Bool) {
        if sendEnd { fx.append(.sendCallEnd) }
        if audioReady || phase == .startingAudio { fx.append(.stopAudio) }
        fx.append(.cancelHoldTimer)
        fx.append(.cutPlayback)
        audioReady = false
        nextManual = false
        interrupted = false
    }
}
