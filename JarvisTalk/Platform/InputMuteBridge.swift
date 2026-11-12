import AVFoundation
import Foundation

/// iOS 17+: the system's own microphone mute (AirPods stem press "Mute / Unmute", the Control Center mic mode) is
/// reported to an app that uses voice processing through `AVAudioApplication`. This keeps our mute and the system's in step.
///
/// NOT verified on a device. Everything is behind `#available(iOS 17.0, *)`; on iOS 16 this class does nothing.
final class InputMuteBridge: @unchecked Sendable {
    /// The system asked to mute / unmute the microphone. Called on the main actor.
    var onSystemChange: (@MainActor (Bool) -> Void)?
    private let lock = NSLock()
    private var _callOn = false
    private var _pushing = false
    private var observer: NSObjectProtocol?
    private var installed = false

    private var callOn: Bool { get { lock.lock(); defer { lock.unlock() }; return _callOn } set { lock.lock(); _callOn = newValue; lock.unlock() } }
    private var pushing: Bool { get { lock.lock(); defer { lock.unlock() }; return _pushing } set { lock.lock(); _pushing = newValue; lock.unlock() } }

    func install() {
        guard !installed else { return }
        installed = true
        if #available(iOS 17.0, *) {
            // the handler is the supported way to be told about (and to accept or refuse) a system-initiated change
            try? AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] muted in
                guard let self = self, self.callOn else { return false }      // no call: nothing to mute
                Task { @MainActor in self.onSystemChange?(muted) }
                return true
            }
            // belt and braces: the notification also fires for changes we made ourselves (ignored while `pushing`)
            observer = NotificationCenter.default.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main) { [weak self] n in
                guard let self = self, self.callOn, !self.pushing,
                      let muted = n.userInfo?[AVAudioApplication.muteStateKey] as? Bool else { return }
                Task { @MainActor in self.onSystemChange?(muted) }
            }
        }
    }

    func setCall(_ on: Bool) {
        callOn = on
        if !on { release() }
    }

    /// Our mute changed (button, lock screen): tell the system so AirPods and Control Center show the same state.
    func push(_ muted: Bool) {
        guard installed, callOn else { return }
        if #available(iOS 17.0, *) {
            guard AVAudioApplication.shared.isInputMuted != muted else { return }
            pushing = true
            try? AVAudioApplication.shared.setInputMuted(muted)
            pushing = false
        }
    }

    /// The call ended: never leave the system microphone muted.
    private func release() {
        guard installed else { return }
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.isInputMuted { pushing = true; try? AVAudioApplication.shared.setInputMuted(false); pushing = false }
        }
    }
}
