import SwiftUI
import AVFoundation
import UIKit
import JarvisModel

/// Explains a denied or restricted permission in plain words and offers the way to Settings.
struct PermissionAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var canOpenSettings: Bool
}

@MainActor
final class PermissionAlerts: ObservableObject {
    @Published var alert: PermissionAlert?
    var permissions: PermissionProvider?

    /// Returns true when the camera can be used now. Asks (once) when undetermined; explains when denied.
    func ensureCamera(purpose: String) async -> Bool {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            alert = PermissionAlert(title: "No camera", message: "This device has no camera that apps can use.", canOpenSettings: false)
            return false
        }
        guard let p = permissions else { return false }
        var state = p.camera()
        if state == .undetermined { state = await p.requestCamera() }
        switch state {
        case .granted: return true
        case .denied:
            alert = PermissionAlert(title: "Camera is off for Jarvis",
                                    message: "Jarvis needs the camera to \(purpose). Turn it on in Settings, then come back.", canOpenSettings: true)
        case .restricted:
            alert = PermissionAlert(title: "Camera is restricted",
                                    message: "Screen Time or a device profile does not allow camera access on this iPhone.", canOpenSettings: false)
        case .undetermined: break
        }
        return false
    }

    func explainMicrophone(_ state: PermissionState) {
        switch state {
        case .denied: alert = PermissionAlert(title: "Microphone is off for Jarvis", message: "Jarvis needs the microphone so you can talk to him. Turn it on in Settings, then come back.", canOpenSettings: true)
        case .restricted: alert = PermissionAlert(title: "Microphone is restricted", message: "Screen Time or a device profile does not allow microphone access on this iPhone.", canOpenSettings: false)
        default: break
        }
    }
}

extension View {
    func permissionAlert(_ alerts: PermissionAlerts) -> some View {
        modifier(PermissionAlertModifier(alerts: alerts))
    }
}

private struct PermissionAlertModifier: ViewModifier {
    @ObservedObject var alerts: PermissionAlerts
    func body(content: Content) -> some View {
        content.alert(item: $alerts.alert) { a in
            if a.canOpenSettings {
                return Alert(title: Text(a.title), message: Text(a.message),
                             primaryButton: .default(Text("Open Settings")) { openSettings() }, secondaryButton: .cancel(Text("Not now")))
            }
            return Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }
}

func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}
