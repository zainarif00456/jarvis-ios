import SwiftUI
import os
import JarvisCore
import JarvisModel

@main
struct JarvisTalkApp: App {
    @StateObject private var holder = AppHolder()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(holder.model)
                .environmentObject(holder.model.call)
                .environmentObject(holder.model.chat)
                .environmentObject(holder.model.deck)
                .environmentObject(holder.model.uploads)
                .environmentObject(holder.model.settings)
                .environmentObject(holder.model.exec)
                .environmentObject(holder.model.portals)
                .environmentObject(holder.model.debrief)
                .environmentObject(holder.model.briefing)
                .environmentObject(holder.model.screen)
                .environmentObject(holder.alerts)
                .preferredColorScheme(.dark)
                .tint(Theme.accent(.jarvis))
                .onAppear { holder.start() }
                .onChange(of: scenePhase) { phase in holder.scene(phase) }
        }
    }
}

/// Builds the real platform pieces once, owns the app model and the small system helpers.
@MainActor
final class AppHolder: ObservableObject {
    let model: AppModel
    let alerts = PermissionAlerts()
    private let nowPlaying = NowPlayingController()
    private let inputMute = InputMuteBridge()
    private let network = NetworkMonitor()
    private let permissions = SystemPermissions()
    private var started = false
    private let log = Logger(subsystem: "com.jarvis.talk", category: "app")

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let permissions = self.permissions
        model = AppModel(platform: Platform(secrets: KeychainStore(), defaults: UserDefaultsStore(), permissions: permissions,
                                            makeAudio: { VoiceAudioEngine() }, appVersion: version))
        alerts.permissions = permissions
    }

    func start() {
        guard !started else { return }
        started = true
        let call = model.call
        // every mute trigger ends in the call model, the single source of truth: button, earbud / headset press,
        // lock screen, system (AirPods / Control Center) mute
        nowPlaying.onToggleMute = { call.toggleMute() }
        nowPlaying.onMute = { call.setMuted($0) }
        inputMute.onSystemChange = { call.setMuted($0) }
        inputMute.install()
        call.onMutedChanged = { [weak self] muted in
            self?.nowPlaying.update(muted: muted)
            self?.inputMute.push(muted)
        }
        call.onActiveChanged = { [weak self] on in
            guard let self = self else { return }
            self.nowPlaying.setActive(on, muted: call.muted)
            self.inputMute.setCall(on)
        }
        network.onChange = { [weak self] online, changed in self?.model.networkChanged(online: online, interfaceChanged: changed) }
        network.start()
        model.launch()
        log.info("app started, paired: \(self.model.phase == .ready)")
    }

    func scene(_ phase: ScenePhase) {
        switch phase {
        case .active: model.sceneBecameActive()
        case .inactive: model.sceneBecameInactive(background: false)
        case .background: model.sceneBecameInactive(background: true)
        @unknown default: break
        }
        nowPlaying.update(muted: model.call.muted)
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var alerts: PermissionAlerts

    var body: some View {
        FXScope {
            Group {
                switch app.phase {
                case .needsPairing: PairingView()
                case .ready: MainTabs()
                }
            }
        }
        .permissionAlert(alerts)
        .onChange(of: settings.keepScreenAwake) { on in UIApplication.shared.isIdleTimerDisabled = on }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake }
    }
}

struct MainTabs: View {
    enum Tab: Hashable { case home, chat, terminal, cameras, files }
    @State private var tab: Tab = .home
    @EnvironmentObject var deck: DeckModel
    @EnvironmentObject var chat: ChatModel

    var body: some View {
        TabView(selection: $tab) {
            HomeView(goTo: { tab = $0 }).tag(Tab.home)
                .tabItem { Label("Jarvis", systemImage: "waveform.circle.fill") }
            ChatView().edgeSwipeBack().tag(Tab.chat)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(deck.attention)
            TerminalsView().edgeSwipeBack().tag(Tab.terminal)
                .tabItem { Label("Terminal", systemImage: "terminal.fill") }
                .badge(deck.terminals.count)
            CamerasView(isVisible: tab == .cameras).edgeSwipeBack().tag(Tab.cameras)
                .tabItem { Label("Cameras", systemImage: "video.fill") }
            FilesView().edgeSwipeBack().tag(Tab.files)
                .tabItem { Label("Files", systemImage: "folder.fill") }
                .badge(deck.unseenFiles)
        }
        .environment(\.currentTab, tab)
        .environment(\.goHome, { tab = .home })
    }
}

private struct TabKey: EnvironmentKey { static let defaultValue: MainTabs.Tab = .home }
extension EnvironmentValues {
    var currentTab: MainTabs.Tab { get { self[TabKey.self] } set { self[TabKey.self] = newValue } }
}
