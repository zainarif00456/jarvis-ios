import Foundation

/// What the app may honestly tell the owner about the connection. Pure: every input is a real fact (the session
/// socket's state, the network path, whether a liveness check is running, the call state machine, whether the
/// audio engine is running). Nothing here is optimistic: `.connected` needs the socket open AND the call active AND
/// the call audio path running AND no liveness check pending.
public struct ConnectionInputs: Equatable, Sendable {
    public enum Socket: Equatable, Sendable {
        case connecting
        case open
        case reconnecting(attempt: Int)
        case unauthorized
    }
    public var socket: Socket
    public var networkOnline: Bool
    /// A liveness check (ping / pong) of an open socket is running, e.g. right after the app came back to the front.
    public var verifying: Bool
    /// Why the current address does not work (HTML page instead of JSON, refused, ...), if known.
    public var addressProblem: String?
    public var callPhase: CallStateMachine.Phase
    public var wantsCall: Bool
    public var audioRunning: Bool

    public init(socket: Socket = .connecting, networkOnline: Bool = true, verifying: Bool = false, addressProblem: String? = nil,
                callPhase: CallStateMachine.Phase = .idle, wantsCall: Bool = false, audioRunning: Bool = false) {
        self.socket = socket; self.networkOnline = networkOnline; self.verifying = verifying; self.addressProblem = addressProblem
        self.callPhase = callPhase; self.wantsCall = wantsCall; self.audioRunning = audioRunning
    }
}

public enum ConnectionDisplay: Equatable, Sendable {
    case connecting             // first connection / starting the call
    case checking               // socket looked open, being verified
    case connected              // socket open + call active + audio running
    case reconnecting           // lost, retrying by itself
    case offline                // the phone has no network
    case failed(String)         // retries are not getting anywhere: tap to retry
    case notPaired
    case online                 // socket open, no call wanted (the owner ended it): tap to talk
    case callBlocked            // socket fine, the call itself is blocked (microphone, audio): the call banner explains

    /// After this many failed attempts in a row the UI stops saying "Reconnecting" and says it is not connected.
    public static let failureAttempts = 4

    public static func resolve(_ i: ConnectionInputs) -> ConnectionDisplay {
        if i.socket == .unauthorized { return .notPaired }
        if !i.networkOnline { return .offline }
        switch i.socket {
        case .unauthorized: return .notPaired
        case .connecting:
            if let p = i.addressProblem { return .failed(p) }
            return .connecting
        case .reconnecting(let attempt):
            if let p = i.addressProblem { return .failed(p) }
            return attempt >= failureAttempts ? .failed("Not connected to Jarvis.") : .reconnecting
        case .open:
            if i.verifying { return .checking }
            switch i.callPhase {
            case .active: return i.audioRunning ? .connected : .connecting
            case .held: return .reconnecting
            case .startingAudio, .waitingServer, .needsPermission: return .connecting
            case .idle: return i.wantsCall ? .connecting : .online
            case .blocked(.serverUnresponsive(let why)): return .failed(why)
            case .blocked: return .callBlocked
            }
        }
    }

    public var isConnected: Bool { self == .connected }
    public var canRetry: Bool { if case .failed = self { return true }; return false }

    /// The big status line under the orb.
    public var statusText: String {
        switch self {
        case .connecting: return "Connecting…"
        case .checking: return "Checking connection…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .offline: return "Offline"
        case .failed: return "Not connected, tap to retry"
        case .notPaired: return "Not paired"
        case .online: return "Tap to talk"
        case .callBlocked: return "Call blocked"
        }
    }

    /// The small chip in the header: "online" only when the connection is really up.
    public var chipText: String {
        switch self {
        case .connected, .online: return "online"
        case .connecting: return "connecting…"
        case .checking: return "checking…"
        case .reconnecting: return "reconnecting…"
        case .offline: return "offline"
        case .failed: return "not connected"
        case .notPaired: return "not paired"
        case .callBlocked: return "online"
        }
    }
}
