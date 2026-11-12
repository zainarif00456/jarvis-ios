import SwiftUI
import JarvisCore
import JarvisModel

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var call: CallModel
    @EnvironmentObject var deck: DeckModel
    @EnvironmentObject var alerts: PermissionAlerts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var mic: PermissionState = .undetermined
    @State private var camera: PermissionState = .undetermined
    @State private var notifications: PermissionState = .undetermined
    @State private var confirmForget = false
    @State private var speed = 1.15
    @State private var editor: AddressEditor.Target?

    var body: some View {
        Form {
            Section("Server") {
                row("Base URL", settings.endpointText.isEmpty ? "not set" : settings.endpointText)
                if let a = settings.activeServer {
                    row("Address name", a.name)
                    Button("Edit current address") { editor = .edit(a) }
                }
                NavigationLink { ServerAddressesView() } label: {
                    HStack { Text("Saved addresses"); Spacer(); Text("\(settings.servers.count)").foregroundColor(Theme.dimText) }
                }
                if let why = app.addressProblem {
                    Label(why, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundColor(Theme.warn)
                }
                row("This phone", deck.deviceName ?? settings.deviceName)
                row("Connection", linkText)
                if let v = deck.serverVersion { row("Server version", v) }
                Button("Reconnect now") { app.reconnectNow() }
            }
            Section("Voice call") {
                Toggle("Start the call when the app opens", isOn: $settings.autoStartCall)
                if let list = deck.voices?.voices, !list.isEmpty {
                    Picker("Jarvis's voice", selection: Binding(get: { deck.voices?.voice ?? "" }, set: { v in Task { await deck.setVoice(v, speed: nil) } })) {
                        ForEach(list) { v in Text("\(v.name ?? v.id)\(v.accent.map { " · \($0)" } ?? "")").tag(v.id) }
                    }
                    VStack(alignment: .leading) {
                        Text("Speed \(String(format: "%.2f", speed))×").font(.footnote)
                        Slider(value: $speed, in: 0.8...1.4, step: 0.05) { editing in if !editing { Task { await deck.setVoice(nil, speed: speed) } } }
                    }
                } else { Text("Voices load once the server answers.").font(.footnote).foregroundColor(Theme.dimText) }
                row("Audio output", call.route.isEmpty ? "—" : call.route)
                Text("The call keeps running with the phone locked. Use the lock-screen controls or the headphone button to mute.").font(.footnote).foregroundColor(Theme.dimText)
            }
            Section("Permissions") {
                permissionRow("Microphone", mic, why: "needed to talk to Jarvis")
                permissionRow("Camera", camera, why: "to take photos and clips for Jarvis")
                permissionRow("Notifications", notifications, why: "not used yet — alerts for finished tasks come later")
                Text("Photos you pick from your library are shared with the app only for the items you choose; no library permission is needed.").font(.footnote).foregroundColor(Theme.dimText)
            }
            Section("Display") {
                Toggle("Keep the screen awake", isOn: $settings.keepScreenAwake)
            }
            Section {
                Button("Forget this phone", role: .destructive) { confirmForget = true }
            } footer: { Text("Removes the device token from this iPhone. Pair again with a new code from `jarvis pair`.") }
            Section("About") {
                row("App version", app.platform.appVersion)
                row("Protocol", "Jarvis gateway v1")
            }
        }
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .sheet(item: $editor) { t in NavigationStack { AddressEditor(target: t, onSwitched: {}) } }
        .confirmationDialog("Forget this phone?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { app.forgetDevice(); dismiss() }
        } message: { Text("The call ends and you will need a new pairing code.") }
        .task { await refresh(); await deck.loadVoices(); speed = deck.voices?.speed ?? 1.15 }
        .onChange(of: scenePhase) { p in if p == .active { Task { await refresh() } } }
    }

    private func refresh() async {
        guard let p = alerts.permissions else { return }
        mic = p.microphone(); camera = p.camera(); notifications = await p.notifications()
    }

    private var linkText: String {
        return app.display.chipText
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundColor(Theme.dimText).lineLimit(1).truncationMode(.middle) }
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func permissionRow(_ name: String, _ state: PermissionState, why: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name); Spacer()
                switch state {
                case .granted: PillLabel(text: "allowed", color: Theme.ok)
                case .denied: PillLabel(text: "off", color: Theme.bad)
                case .restricted: PillLabel(text: "restricted", color: Theme.warn)
                case .undetermined: PillLabel(text: "not asked", color: Theme.dimText)
                }
            }
            Text(why).font(.caption).foregroundColor(Theme.dimText)
            if state == .denied { Button("Open Settings") { openSettings() }.font(.caption) }
            if state == .restricted { Text("Restricted by Screen Time or a device profile.").font(.caption).foregroundColor(Theme.warn) }
        }
        .accessibilityElement(children: .combine)
    }
}
