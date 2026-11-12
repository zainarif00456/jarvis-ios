import MediaPlayer
import UIKit

/// Lock screen / Control Center / headphone button controls for the call: play-pause toggles the microphone mute.
/// (An active call with an audio session makes the app eligible to show Now Playing.)
@MainActor
final class NowPlayingController {
    var onToggleMute: (() -> Void)?
    var onMute: ((Bool) -> Void)?
    var onEnd: (() -> Void)?
    private var active = false

    func setActive(_ on: Bool, muted: Bool) {
        let center = MPRemoteCommandCenter.shared()
        if on {
            if !active {
                active = true
                center.togglePlayPauseCommand.isEnabled = true
                center.playCommand.isEnabled = true
                center.pauseCommand.isEnabled = true
                center.stopCommand.isEnabled = true
                center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onToggleMute?(); return .success }
                center.playCommand.addTarget { [weak self] _ in self?.onMute?(false); return .success }
                center.pauseCommand.addTarget { [weak self] _ in self?.onMute?(true); return .success }
                center.stopCommand.addTarget { [weak self] _ in self?.onEnd?(); return .success }
            }
            update(muted: muted)
        } else if active {
            active = false
            for c in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand, center.stopCommand] as [MPRemoteCommand] {
                c.removeTarget(nil); c.isEnabled = false
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    func update(muted: Bool) {
        guard active else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: muted ? "Jarvis (microphone muted)" : "Jarvis is listening",
            MPMediaItemPropertyArtist: "Voice call",
            MPNowPlayingInfoPropertyPlaybackRate: muted ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
    }
}
