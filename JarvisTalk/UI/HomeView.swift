import SwiftUI
import AVKit
import JarvisCore
import JarvisModel

/// The main screen: the orb, the call controls, and the deck's quick actions (terminal, cameras, files, upload,
/// media, schedules), approvals, running work and recent files: the browser dashboard, natively.
struct HomeView: View {
    var goTo: (MainTabs.Tab) -> Void
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var call: CallModel
    @EnvironmentObject var deck: DeckModel
    @EnvironmentObject var uploads: UploadModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var alerts: PermissionAlerts
    @StateObject private var picker = UploadController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.currentTab) private var currentTab
    @State private var sheet: MoreSheet?

    enum MoreSheet: Identifiable { case media, schedules, activity, sessions, settings, addresses; var id: Int { hashValue } }

    private var persona: Persona { Persona.of(deck.agents?.active) }
    private var orbActive: Bool { scenePhase == .active && currentTab == .home }

    var body: some View {
        NavigationStack {
            ZStack {
                StageBackground(accent: Theme.accent(persona))
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        orb
                        noticeBanner
                        approvals
                        quickActions
                        agentPicker
                        runningWork
                        recordingsRow
                        uploadsList
                        recentFiles
                        Color.clear.frame(height: 90)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) { callBar }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .media: NavigationStack { MediaView(picker: picker) }
            case .schedules: NavigationStack { SchedulesView() }
            case .activity: NavigationStack { ActivityView() }
            case .sessions: NavigationStack { SessionsView() }
            case .settings: NavigationStack { SettingsView() }
            case .addresses: NavigationStack { ServerAddressesView() }
            }
        }
        .uploadPickers(picker)
        .onAppear { picker.configure(uploads: uploads, settings: settings, alerts: alerts) }
        .overlay(alignment: .top) { ToastView() }
        .environmentObject(picker)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            ConnectionPill()
            if let s = deck.status, let spent = s.spentUsd, let budget = s.budgetUsd {
                Text("\(Format.usd(spent)) / $\(String(format: "%.2f", budget))")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.dimText)
                    .accessibilityLabel("Spent \(Format.usd(spent)) of \(String(format: "%.2f", budget)) dollars")
            }
            Spacer()
            Menu {
                Button { sheet = .activity } label: { Label("Activity and tasks", systemImage: "list.bullet.rectangle") }
                Button { sheet = .media } label: { Label("Media library", systemImage: "photo.on.rectangle") }
                Button { sheet = .schedules } label: { Label("Schedules", systemImage: "calendar.badge.clock") }
                Button { sheet = .sessions } label: { Label("Sessions", systemImage: "clock.arrow.circlepath") }
                Divider()
                Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2).foregroundColor(Theme.text).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .padding(.top, 6)
    }

    // MARK: orb and state

    private var orbState: String {
        // the orb only shows a live call when the connection is really up; otherwise it is dim
        if app.display != .connected { return app.display == .online ? "idle" : "offline" }
        return call.voiceState
    }

    private var orb: some View {
        VStack(spacing: 6) {
            NeuralCoreView(state: orbState, muted: call.muted, persona: persona, active: orbActive,
                           micLevel: { call.micLevel }, outLevel: { call.outLevel })
                .frame(height: 300)
                .opacity(call.muted ? 0.4 : 1)                       // muted: the orb dims
                .saturation(call.muted ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.25), value: call.muted)
                .overlay(alignment: .bottom) {
                    if call.muted {
                        Label("Microphone muted", systemImage: "mic.slash.fill").font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.warn).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.5))).overlay(Capsule().stroke(Theme.warn.opacity(0.7)))
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if app.display.canRetry { app.retryConnection() }
                    else if call.isActive { call.toggleMute() } else if !call.wantsCall { call.startCall() }
                }
            Text(statusLine).font(.system(size: 13, weight: .semibold, design: .monospaced)).tracking(2)
                .foregroundColor(Theme.accentLight(persona)).textCase(.uppercase)
                .accessibilityLabel("Status: \(statusLine)")
                .onTapGesture { if app.display.canRetry { app.retryConnection() } }
            if !call.caption.isEmpty {
                Text(call.caption).font(.callout).foregroundColor(Theme.text).multilineTextAlignment(.center).padding(.horizontal, 8)
                    .transition(.opacity)
            } else if app.display == .connected || app.display == .online, let last = lastReply {
                Text(last).font(.footnote).foregroundColor(Theme.dimText).multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 8)
            }
        }
    }

    @EnvironmentObject private var chat: ChatModel
    private var lastReply: String? { chat.entries.last(where: { $0.kind == .assistant && !$0.text.isEmpty })?.text }

    private var statusLine: String {
        switch app.display {
        case .connected:
            if call.muted && call.voiceState != "speaking" { return "Muted" }
            switch call.voiceState { case "listening": return "Listening"; case "thinking": return "Thinking"; case "speaking": return "Speaking"; default: return "Connected" }
        case .callBlocked:
            switch call.phase {
            case .blocked(.micDenied): return "Microphone is off"
            case .blocked(.micRestricted): return "Microphone restricted"
            case .blocked(.audioFailed): return "Audio problem"
            default: return app.display.statusText
            }
        default: return app.display.statusText
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if case .blocked(let why) = call.phase {
            VStack(alignment: .leading, spacing: 8) {
                Label(call.notice ?? "The call could not start.", systemImage: "mic.slash.fill").font(.footnote).foregroundColor(Theme.warn)
                HStack {
                    if why == .micDenied { Button("Open Settings") { openSettings() }.buttonStyle(.borderedProminent) }
                    if why != .micRestricted { Button("Try again") { call.startCall() }.buttonStyle(.bordered) }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(Theme.warn)
        } else if let n = call.notice, !n.isEmpty {
            Label(n, systemImage: "info.circle").font(.footnote).foregroundColor(Theme.dimText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).glass()
        }
        if let why = app.addressProblem, app.link != .online {
            VStack(alignment: .leading, spacing: 8) {
                Label(why, systemImage: "wifi.exclamationmark").font(.footnote).foregroundColor(Theme.warn)
                Text("ngrok free addresses change when the tunnel restarts.").font(.caption).foregroundColor(Theme.dimText)
                Button("Edit address") { sheet = .addresses }.buttonStyle(.borderedProminent)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(Theme.warn)
        }
        if app.link == .unauthorized { Text("This phone is no longer paired.").foregroundColor(Theme.bad) }
    }

    // MARK: approvals, work

    @ViewBuilder private var approvals: some View {
        ForEach(deck.approvals) { a in
            VStack(alignment: .leading, spacing: 8) {
                Label("Approval needed", systemImage: "hand.raised.fill").font(.caption.weight(.semibold)).foregroundColor(Theme.warn)
                Text(a.tool ?? "action").font(.subheadline.weight(.semibold)).foregroundColor(Theme.text)
                if let w = a.what, !w.isEmpty { Text(w).font(.system(.footnote, design: .monospaced)).foregroundColor(Theme.dimText).lineLimit(4) }
                ForEach(a.reasons ?? [], id: \.self) { Text("• \($0)").font(.caption).foregroundColor(Theme.dimText) }
                HStack {
                    Button { deck.approve(a.id, true) } label: { Label("Approve", systemImage: "checkmark") }.buttonStyle(.borderedProminent).tint(Theme.ok)
                    Button { deck.approve(a.id, false) } label: { Label("Deny", systemImage: "xmark") }.buttonStyle(.bordered).tint(Theme.bad)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(Theme.warn)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private var runningWork: some View {
        if !deck.activeTasks.isEmpty {
            section("Working now") {
                ForEach(deck.activeTasks) { t in
                    HStack {
                        Circle().fill(Theme.persona(t.owner)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(t.name ?? "Agent") — \(t.title ?? "")").font(.footnote).foregroundColor(Theme.text).lineLimit(2)
                            if let p = t.progress { ProgressView(value: p).tint(Theme.persona(t.owner)) }
                        }
                        Spacer()
                        Button { deck.cancelTask(t.id) } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Cancel \(t.title ?? "task")")
                    }
                }
            }
        }
    }

    @ViewBuilder private var recordingsRow: some View {
        let live = deck.recordings.filter { $0.isLive }
        if !live.isEmpty {
            section("Recording") {
                ForEach(live) { r in
                    HStack {
                        Image(systemName: "record.circle").foregroundColor(Theme.hot)
                        Text("\(r.name ?? r.kind ?? "Recording") · \(r.state ?? "")").font(.footnote).foregroundColor(Theme.text)
                        Spacer()
                        Button("Stop") { Task { await deck.recordingAction(r, "stop") } }.buttonStyle(.bordered).tint(Theme.hot)
                    }
                }
            }
        }
    }

    @ViewBuilder private var agentPicker: some View {
        if let a = deck.agents, a.enabled != false, let list = a.agents, !list.isEmpty {
            section("Who answers the call") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        agentChip(key: "jarvis", name: "Jarvis", active: (a.active ?? "jarvis") == "jarvis", available: true)
                        ForEach(list) { ag in agentChip(key: ag.key, name: ag.name ?? ag.key.capitalized, active: ag.active == true, available: ag.available != false) }
                    }
                }
            }
        }
    }
    private func agentChip(key: String, name: String, active: Bool, available: Bool) -> some View {
        Button { deck.selectAgent(key) } label: {
            Text(name).font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(active ? Theme.persona(key).opacity(0.3) : Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(Theme.persona(key).opacity(active ? 0.9 : 0.3)))
                .foregroundColor(available ? Theme.text : Theme.dimText)
        }.disabled(!available).accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: quick actions

    private var quickActions: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            action("New terminal", "terminal.fill") { deck.openTerminal(); goTo(.terminal) }
            action("Cameras", "video.fill") { goTo(.cameras) }
            action("Files", "folder.fill") { goTo(.files) }
            action("Upload file", "arrow.up.doc.fill") { picker.chooseFile() }
            action("Upload photo", "photo.fill") { picker.choosePhoto() }
            action("Take photo", "camera.fill") { picker.takePhoto() }
            action("Media", "photo.on.rectangle.angled") { sheet = .media }
            action("Schedules", "calendar.badge.clock") { sheet = .schedules }
            action("Chat", "bubble.left.fill") { goTo(.chat) }
        }
    }
    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22)).foregroundColor(Theme.accentLight(persona))
                Text(title).font(.caption).foregroundColor(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, minHeight: 66).glass(Theme.accent(persona))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    // MARK: uploads and files

    @ViewBuilder private var uploadsList: some View {
        if !uploads.items.isEmpty { section("Uploads") { UploadsList() } }
    }

    @ViewBuilder private var recentFiles: some View {
        if !deck.files.isEmpty {
            section("Shared with you") {
                ForEach(deck.files.prefix(4)) { f in FileRow(file: f, compact: true) }
                Button("All files") { goTo(.files) }.font(.footnote)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2).foregroundColor(Theme.dimText)
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(Theme.accent(persona))
    }

    // MARK: call bar

    private var callBar: some View {
        HStack(spacing: 18) {
            muteButton
            Button {
                if call.phase.isBlocked { alertFor(call.phase) } else { call.toggleCall() }
            } label: {
                Image(systemName: (call.wantsCall || call.inCall) ? "phone.down.fill" : "phone.fill")
                    .font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                    .frame(width: 70, height: 70)
                    .background(Circle().fill((call.wantsCall || call.inCall) ? Theme.hot : Theme.ok))
                    .shadow(color: ((call.wantsCall || call.inCall) ? Theme.hot : Theme.ok).opacity(0.5), radius: 14)
            }
            .accessibilityLabel((call.wantsCall || call.inCall) ? "End the call" : "Start the call")
            roundButton("stop.fill", label: "Stop Jarvis talking", tint: Theme.text, enabled: call.isActive && call.voiceState == "speaking") { call.interrupt() }
            RoutePicker().frame(width: 52, height: 52).accessibilityLabel("Audio output")
        }
        .padding(.vertical, 10).padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    /// The mic button: unmistakably different when muted (red-orange filled disc, slashed mic, "MUTED" caption).
    private var muteButton: some View {
        let on = call.muted
        return Button { call.toggleMute() } label: {
            VStack(spacing: 3) {
                Image(systemName: on ? "mic.slash.fill" : "mic.fill").font(.system(size: 20, weight: .semibold))
                    .foregroundColor(on ? .white : Theme.text)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(on ? Theme.warn : Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(on ? Theme.warn : Color.clear, lineWidth: 2).scaleEffect(1.12).opacity(on ? 0.5 : 0))
                Text(on ? "MUTED" : "MIC").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5)
                    .foregroundColor(on ? Theme.warn : Theme.dimText)
            }
        }
        .disabled(!call.canMute).opacity(call.canMute ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.18), value: on)
        .accessibilityLabel(on ? "Unmute microphone" : "Mute microphone")
        .accessibilityValue(on ? "Muted" : "Microphone on")
    }

    private func alertFor(_ phase: CallStateMachine.Phase) {
        if case .blocked(.micDenied) = phase { alerts.explainMicrophone(.denied) }
        else if case .blocked(.micRestricted) = phase { alerts.explainMicrophone(.restricted) }
        else { call.startCall() }
    }

    private func roundButton(_ icon: String, label: String, tint: Color, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 20)).foregroundColor(tint)
                .frame(width: 52, height: 52).background(Circle().fill(Color.white.opacity(0.08)))
        }.disabled(!enabled).opacity(enabled ? 1 : 0.4).accessibilityLabel(label)
    }
}

extension CallStateMachine.Phase {
    var isBlocked: Bool { if case .blocked = self { return true }; return false }
}

/// The header chip. Driven by `AppModel.display`: "online" only when the connection is really up; tap it when it says
/// "not connected" to retry.
struct ConnectionPill: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        let d = app.display
        let color: Color = {
            switch d {
            case .connected, .online, .callBlocked: return Theme.ok
            case .connecting, .checking, .reconnecting: return Theme.warn
            case .offline, .failed, .notPaired: return Theme.bad
            }
        }()
        Button { if d.canRetry { app.retryConnection() } } label: {
            PillLabel(text: d.chipText, color: color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection: \(d.chipText)")
        .accessibilityHint(d.canRetry ? "Double tap to retry" : "")
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(Theme.text); v.activeTintColor = UIColor(Theme.accent(.jarvis))
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct ToastView: View {
    @EnvironmentObject var deck: DeckModel
    @EnvironmentObject var picker: UploadController
    var body: some View {
        let text = picker.message ?? deck.toast ?? deck.lastError
        Group {
            if let t = text {
                Text(t).font(.footnote).foregroundColor(Theme.text).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(Theme.panel)).overlay(Capsule().stroke(Theme.accent(.jarvis).opacity(0.5)))
                    .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { clear() }
                    .task(id: t) { try? await Task.sleep(nanoseconds: 3_500_000_000); clear() }
                    .accessibilityLabel(t)
            }
        }.animation(.easeInOut(duration: 0.25), value: text)
    }
    private func clear() { picker.message = nil; deck.clearToast(); deck.clearError() }
}
