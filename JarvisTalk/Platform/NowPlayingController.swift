import MediaPlayer
import UIKit

/// Lock screen / Control Center / earbud and headset buttons for the call.
///
/// The microphone mute is mapped onto the media transport: `togglePlayPause` (one press of an earbud stem, a headset
/// hook, the lock-screen button) toggles mute, `pause` mutes, `play` unmutes. "Playing" means the microphone is live,
/// "paused" means muted, and the lock screen shows "Jarvis call" with the state. The handlers are registered once and
/// only answer while a call is on, so a stray press with no call does nothing.
///
/// NOT verified on a real device: whether iOS routes an earbud press to this app depends on this app being the
/// "Now Playing" app. The call keeps an audio session running and a silent loop plays in the engine (see
/// `VoiceAudioEngine`) to earn that; see TROUBLESHOOTING.md for the fallbacks.
final class NowPlayingController: @unchecked Sendable {
    /// Called on the main thread. The call model decides whether there is a call to mute.
    var onToggleMute: (@MainActor () -> Void)?
    var onMute: (@MainActor (Bool) -> Void)?
    private let lock = NSLock()
    private var _active = false
    private var active: Bool { get { lock.lock(); defer { lock.unlock() }; return _active } set { lock.lock(); _active = newValue; lock.unlock() } }
    private var registered = false
    private var tokens: [(MPRemoteCommand, Any)] = []

    private func registerOnce() {
        guard !registered else { return }
        registered = true
        let c = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ run: @escaping @MainActor (NowPlayingController) -> Void) {
            let t = cmd.addTarget { [weak self] _ in
                // the handler may run on any thread: answer at once, act on the main actor
                guard let self = self, self.active else { return .noActionableNowPlayingItem }
                Task { @MainActor in run(self) }
                return .success
            }
            tokens.append((cmd, t))
        }
        add(c.togglePlayPauseCommand) { $0.onToggleMute?() }
        add(c.playCommand) { $0.onMute?(false) }       // play = microphone live
        add(c.pauseCommand) { $0.onMute?(true) }       // pause = muted
        for cmd in [c.nextTrackCommand, c.previousTrackCommand, c.stopCommand, c.skipForwardCommand, c.skipBackwardCommand,
                    c.seekForwardCommand, c.seekBackwardCommand, c.changePlaybackPositionCommand] as [MPRemoteCommand] { cmd.isEnabled = false }
    }

    func setActive(_ on: Bool, muted: Bool) {
        let c = MPRemoteCommandCenter.shared()
        if on {
            registerOnce()
            active = true
            c.togglePlayPauseCommand.isEnabled = true
            c.playCommand.isEnabled = true
            c.pauseCommand.isEnabled = true
            UIApplication.shared.beginReceivingRemoteControlEvents()
            update(muted: muted)
        } else if active {
            active = false
            for cmd in [c.togglePlayPauseCommand, c.playCommand, c.pauseCommand] as [MPRemoteCommand] { cmd.isEnabled = false }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            UIApplication.shared.endReceivingRemoteControlEvents()
        }
    }

    /// Lock screen / Control Center card: "Jarvis call", and whether the microphone is live or muted.
    func update(muted: Bool) {
        guard active else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Jarvis call",
            MPMediaItemPropertyArtist: muted ? "Microphone muted" : "Microphone on",
            MPMediaItemPropertyAlbumTitle: "JarvisTalk",
            MPNowPlayingInfoPropertyPlaybackRate: muted ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().playbackState = muted ? .paused : .playing
    }
}
