import SwiftUI
import JarvisCore
import JarvisModel

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var call: CallModel
    @EnvironmentObject var deck: DeckModel
    @EnvironmentObject var alerts: PermissionAlerts
    @EnvironmentObject var pip: PiPControl
    @EnvironmentObject var shots: ScreenshotSyncModel
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
            Section {
                Picker("Live work view", selection: $settings.execLevel) {
                    Text("Full: cards out of the core").tag(ExecLevel.full)
                    Text("Minimal: one line").tag(ExecLevel.minimal)
                    Text("Off").tag(ExecLevel.off)
                }
                .onChange(of: settings.execLevel) { _ in app.settingsChanged() }
                Toggle("Let Jarvis see this screen", isOn: $settings.sendScreenState)
                    .onChange(of: settings.sendScreenState) { _ in app.settingsChanged() }
            } header: { Text("Live work and screen") } footer: {
                Text("The live work view shows what Jarvis and the agents are doing as small cards. \"Let Jarvis see this screen\" tells Jarvis which portals are open (the browser does the same). It is what lets agents' debriefs and short briefings appear on this phone and Jarvis understand \"close that\". Off: the phone is only a voice and a chat, and debriefs are not shown here.")
            }
            Section {
                Toggle("Floating status window (picture-in-picture)", isOn: $settings.liveExecution)
                    .disabled(!pip.supported)
                    .onChange(of: settings.liveExecution) { pip.setEnabled($0) }
                if settings.liveExecution {
                    Button(pip.active ? "Close the floating window" : "Show the floating window now") { pip.toggle() }
                }
            } header: { Text("Outside the app") } footer: {
                Text("Shows what Jarvis is doing in a small window you can drag and resize, over other apps. iOS allows no other overlays. It opens by itself when you leave the app while work runs (iOS may refuse; then press the button before leaving). Not tested on a real device.")
            }
            Section {
                Toggle("Send screenshots to Jarvis", isOn: Binding(get: { shots.enabled }, set: { shots.setEnabled($0) }))
                Text(shots.statusLine).font(.footnote).foregroundColor(Theme.dimText)
                if shots.needsSettings { Button("Open Photos settings") { openSettings() } }
            } header: { Text("Screenshots") } footer: {
                Text("Every new screenshot (for example from a triple-tap on the back of the phone) is sent to your Jarvis media library by itself. Needs Photos access. Screenshots taken while this is off are never sent. While the app is closed they are sent the next time you open it.")
            }
            Section("Display") {
                Toggle("Keep the screen awake", isOn: $settings.keepScreenAwake)
                Picker("Effects", selection: $settings.effects) {
                    Text("Automatic (calm with Reduce Motion or Low Power Mode)").tag("auto")
                    Text("Full").tag("full")
                    Text("Calm: no animated effects").tag("calm")
                }
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
        .toolbar { ToolbarItem(placement: .cancellationAction) { SmartCloseButton() } }
        .sheet(item: $editor) { t in NavigationStack { AddressEditor(target: t, onSwitched: {}) } }
        .confirmationDialog("Forget this phone?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { app.forgetDevice(); dismiss() }
        } message: { Text("The call ends and you will need a new pairing code.") }
        .task { await shots.refresh(); await refresh(); await deck.loadVoices(); speed = deck.voices?.speed ?? 1.15 }
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
