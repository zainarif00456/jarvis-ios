import AVFoundation
import UserNotifications
import JarvisModel

/// Microphone, camera and notification permissions: every state (undetermined, granted, denied, restricted) is
/// reported, nothing is requested except when the app needs it, and asking again after "denied" is a no-op that
/// returns the current state (the app then points the owner to Settings).
final class SystemPermissions: PermissionProvider {
    func microphone() -> PermissionState {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    func requestMicrophone() async -> PermissionState {
        let current = microphone()
        guard current == .undetermined else { return current }
        let granted: Bool = await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        return granted ? .granted : .denied
    }

    func camera() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    func requestCamera() async -> PermissionState {
        let current = camera()
        guard current == .undetermined else { return current }
        let ok = await AVCaptureDevice.requestAccess(for: .video)
        return ok ? .granted : .denied
    }

    func notifications() async -> PermissionState {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Structured for later (task-finished and approval alerts); nothing in the UI asks for it yet.
    func requestNotifications() async -> PermissionState {
        let current = await notifications()
        guard current == .undetermined else { return current }
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        return ok ? .granted : .denied
    }
}
