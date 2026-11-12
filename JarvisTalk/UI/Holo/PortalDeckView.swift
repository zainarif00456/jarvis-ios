import SwiftUI
import JarvisCore
import JarvisModel

/// The holographic deck of Home: portals float around the orb. A ring of glass buttons around the core opens them (tap),
/// open portals are dragged by their title bar, pinched to zoom, and closed / minimised / maximised with clear controls.
/// More than one open: they arrange by the browser's layouts (orbit, grid, focus, side by side, cascade).

// MARK: the launcher ring around the orb

struct DockItem: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var badge: Int = 0
    var action: () -> Void
}

struct CoreDock: View {
    var items: [DockItem]
    var size: CGSize                // the area around the orb
    @Environment(\.calmFX) private var calm
    @State private var formed = false
    @State private var spin = false

    var body: some View {
        ZStack {
            orbitRings
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let p = position(i, count: items.count)
                // each panel forms out of the core: from its own spot to the centre and back
                DockButton(item: item, index: i, formed: formed)
                    .offset(formed ? .zero : CGSize(width: size.width / 2 - p.x, height: size.height / 2 - p.y))
                    .scaleEffect(formed || calm ? 1 : 0.2)
                    .opacity(formed ? 1 : 0)
                    .animation(calm ? .easeInOut(duration: 0.15) : .spring(response: 0.6, dampingFraction: 0.72).delay(Double(i) * 0.05), value: formed)
                    .position(x: p.x, y: p.y)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { formed = true; if !calm { spin = true } }
        .onDisappear { formed = false; spin = false }
    }

    /// Two faint tilted orbit rings behind the panels: depth, drawn once and spun by the compositor (no per-frame work).
    @ViewBuilder private var orbitRings: some View {
        let rx = min(size.width / 2 - 34, 158), ry = min(size.height / 2 - 36, 128)
        let tint = Theme.accent(.jarvis)
        ZStack {
            Ellipse().stroke(tint.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                .frame(width: rx * 2, height: ry * 2)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(calm ? nil : .linear(duration: 90).repeatForever(autoreverses: false), value: spin)
            Ellipse().stroke(tint.opacity(0.14), lineWidth: 0.7)
                .frame(width: rx * 2 - 26, height: ry * 2 - 22)
            Ellipse().stroke(LinearGradient(colors: [tint.opacity(0.0), tint.opacity(0.35), tint.opacity(0.0)], startPoint: .leading, endPoint: .trailing), lineWidth: 1)
                .frame(width: rx * 2 + 22, height: ry * 2 + 18)
        }
        .opacity(formed ? 1 : 0)
        .animation(.easeOut(duration: 0.6), value: formed)
        .allowsHitTesting(false)
    }

    /// Evenly on an ellipse around the orb.
    private func position(_ i: Int, count: Int) -> CGPoint {
        let rx = min(size.width / 2 - 34, 158), ry = min(size.height / 2 - 36, 128)
        let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(max(count, 1)) + Double.pi / Double(max(count, 1))
        return CGPoint(x: size.width / 2 + CGFloat(cos(a)) * rx, y: size.height / 2 + CGFloat(sin(a)) * ry)
    }
}

/// A small holographic glass panel: tinted glass, feathered edge, corner nodes, a shimmer that crosses it now and then,
/// and a slow float with a touch of perspective. The motion is compositor-driven (repeating animations), not a per-frame redraw.
struct DockButton: View {
    var item: DockItem
    var index: Int = 0
    var formed: Bool = true
    @Environment(\.calmFX) private var calm
    @State private var bob = false
    @State private var shimmer = false
    private let tint = Theme.accent(.jarvis)
    private let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

    var body: some View {
        Button(action: item.action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: item.symbol).font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.accentLight(.jarvis))
                        .shadow(color: tint.opacity(0.8), radius: 5)
                        .frame(width: 30, height: 26)
                    if item.badge > 0 {
                        Text(item.badge > 9 ? "9+" : "\(item.badge)").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15).background(Capsule().fill(Theme.hot)).offset(x: 8, y: -5)
                    }
                }
                Text(item.title).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(Theme.text.opacity(0.9))
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 3)
            }
            .frame(width: 64, height: 56)
            .background(glass)
            .overlay(shimmerBand)
            .overlay(shape.strokeBorder(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.15), tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .overlay(corners)
            .clipShape(shape)
            .shadow(color: tint.opacity(0.45), radius: 9, y: 3)
            .contentShape(shape)
        }
        .buttonStyle(HoloPressStyle())
        .offset(y: calm ? 0 : (bob ? 3 : -3))
        .rotation3DEffect(.degrees(calm ? 0 : (bob ? 5 : -5)), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .animation(calm ? nil : .easeInOut(duration: 2.4 + Double(index % 4) * 0.35).repeatForever(autoreverses: true), value: bob)
        .onAppear { if !calm { bob = true; shimmer = true } }
        .accessibilityLabel(item.badge > 0 ? "\(item.title), \(item.badge) new" : item.title)
    }

    private var glass: some View {
        ZStack {
            shape.fill(LinearGradient(colors: [tint.opacity(0.30), Theme.panel.opacity(0.9), Theme.void.opacity(0.95)], startPoint: .top, endPoint: .bottom))
            shape.fill(.ultraThinMaterial).opacity(0.25)
            RadialGradient(colors: [tint.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 46)
        }
    }

    private var shimmerBand: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Theme.text.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.5).rotationEffect(.degrees(18))
                .offset(x: shimmer ? g.size.width * 1.1 : -g.size.width * 0.8)
                .animation(calm ? nil : .easeInOut(duration: 1.6).delay(Double(index) * 0.45).repeatForever(autoreverses: false), value: shimmer)
        }.allowsHitTesting(false)
    }

    private var corners: some View {
        GeometryReader { g in
            ForEach(0..<2, id: \.self) { i in
                Circle().fill(Theme.text).frame(width: 3, height: 3).shadow(color: tint, radius: 3)
                    .position(x: i == 0 ? 5 : g.size.width - 5, y: i == 0 ? 5 : g.size.height - 5)
            }
        }.allowsHitTesting(false)
    }
}

/// Press feedback: the panel sinks and brightens.
struct HoloPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? 0.15 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: portals

/// All open portals over the Home screen. Empty = nothing here takes touches.
struct PortalStage: View {
    @EnvironmentObject var portals: PortalModel
    @Environment(\.calmFX) private var calm
    var picker: UploadController
    var bottomInset: CGFloat = 88

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if portals.visible.contains(where: { $0.full }) {
                    Color.black.opacity(0.5).overlay(RadialGradient(colors: [Theme.accent(.jarvis).opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 420))
                        .ignoresSafeArea().transition(.opacity)
                }
                ForEach(portals.portals) { p in
                    if !p.minimised {
                        PortalWindow(portal: p, stage: geo.size, picker: picker)
                            .transition(.fromCore(CGSize(width: 0, height: -geo.size.height * 0.35), calm: calm, laser: true))
                            .zIndex(Double(p.z))
                    }
                }
                tray(geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { sync(geo.size) }
            .onChange(of: geo.size) { sync($0) }
            .animation(calm ? .easeInOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.82), value: portals.portals.map { "\($0.id)\($0.minimised)\($0.full)" })
        }
        .padding(.bottom, bottomInset)
    }

    private func sync(_ s: CGSize) {
        portals.viewport = PRect(x: 0, y: 0, w: Double(s.width), h: Double(s.height))
        portals.core = (Double(s.width / 2), 150, 100)
    }

    /// Minimised portals sit on a small shelf at the bottom: tap to bring one back.
    @ViewBuilder private func tray(_ size: CGSize) -> some View {
        let hidden = portals.portals.filter { $0.minimised }
        if !hidden.isEmpty {
            HStack(spacing: 8) {
                ForEach(hidden) { p in
                    Button { portals.restore(p.id) } label: {
                        Label(p.title, systemImage: p.kind.symbol).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 7).foregroundColor(Theme.accentLight(.jarvis))
                            .background(Capsule().fill(Theme.panel.opacity(0.95))).overlay(Capsule().stroke(Theme.accent(.jarvis).opacity(0.5)))
                    }.accessibilityLabel("Restore \(p.title)")
                }
            }
            .position(x: size.width / 2, y: size.height - 18)
        }
    }
}

struct PortalWindow: View {
    let portal: PortalModel.Portal
    let stage: CGSize
    var picker: UploadController
    @EnvironmentObject var portals: PortalModel
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @Environment(\.calmFX) private var calm
    @State private var float = false

    private var frame: PRect {
        portal.full ? PRect(x: 8, y: 8, w: Double(stage.width) - 16, h: Double(stage.height) - 16) : portal.rect
    }

    var body: some View {
        let r = frame
        let active = portals.top?.id == portal.id
        let tint = portal.persona.map { Theme.persona($0) } ?? Theme.accent(.jarvis)
        VStack(spacing: 0) {
            titleBar(tint)
            Divider().overlay(tint.opacity(0.3))
            PortalContent(portal: portal, picker: picker)
                .environment(\.embeddedInPortal, true)
                .environment(\.closePortal, { portals.close(portal.id) })
                .clipped()
        }
        .frame(width: CGFloat(r.w), height: CGFloat(r.h))
        .holoPlate(tint, active: active, corner: 18)
        .scaleEffect(CGFloat(portal.scale) * pinch)
        // depth: the plate leans a little toward the finger while dragged, and the one in front floats gently
        .rotation3DEffect(.degrees(calm ? 0 : Double(drag.width) / 28), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(calm ? 0 : Double(-drag.height) / 40), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .offset(y: (calm || portal.full || !active) ? 0 : (float ? 2.5 : -2.5))
        .animation(calm ? nil : .easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: float)
        .onAppear { if !calm { float = true } }
        .position(x: CGFloat(r.centerX) + drag.width, y: CGFloat(r.centerY) + drag.height)
        .simultaneousGesture(MagnificationGesture().updating($pinch) { v, s, _ in s = v }.onEnded { portals.zoom(portal.id, by: Double($0)) })
        .simultaneousGesture(TapGesture().onEnded { if !active { portals.raise(portal.id) } })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(portal.title) portal")
    }

    private func titleBar(_ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: portal.kind.symbol).font(.system(size: 13, weight: .semibold)).foregroundColor(tint)
            Text(portal.title.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            if portal.scale != 1 {
                Button { portals.setScale(portal.id, 1) } label: { Text("\(Int(portal.scale * 100))%").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dimText).padding(.horizontal, 6) }
                    .accessibilityLabel("Reset zoom")
            }
            barButton("minus", "Minimise \(portal.title)") { portals.minimise(portal.id) }
            barButton(portal.full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", portal.full ? "Shrink" : "Maximise") { portals.setFull(portal.id, !portal.full) }
            Button { portals.close(portal.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundColor(Theme.text.opacity(0.9)).frame(width: 44, height: 40)
            }.accessibilityLabel("Close \(portal.title)")
        }
        .padding(.leading, 12)
        .frame(height: 42)
        .contentShape(Rectangle())
        .gesture(DragGesture().updating($drag) { v, s, _ in if !portal.full { s = v.translation } }
            .onEnded { v in if !portal.full { portals.move(portal.id, dx: Double(v.translation.width), dy: Double(v.translation.height)) } })
    }

    private func barButton(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundColor(Theme.dimText).frame(width: 34, height: 40) }.accessibilityLabel(label)
    }
}

/// What a portal shows: the same screens as the bottom bar, inside the glass.
struct PortalContent: View {
    let portal: PortalModel.Portal
    var picker: UploadController
    @EnvironmentObject var deck: DeckModel

    var body: some View {
        switch portal.kind {
        case .chat: ChatView()
        case .terminal, .newTerminal: TerminalsView()
        case .cameras: CamerasView(isVisible: true)
        case .files: FilesView()
        case .file: FilePortal(fileId: portal.itemId)
        case .media: NavigationStack { MediaView(picker: picker) }
        case .schedule: NavigationStack { SchedulesView() }
        case .settings: NavigationStack { SettingsView() }
        case .activity: NavigationStack { ActivityView() }
        case .sessions: NavigationStack { SessionsView() }
        case .report: ReportPortal(reportId: portal.itemId ?? "")
        case .debrief, .briefings: EmptyHint(icon: "rectangle.3.group", title: portal.title)
        }
    }
}

struct FilePortal: View {
    var fileId: String?
    @EnvironmentObject var deck: DeckModel
    var body: some View {
        if let id = fileId, let f = (deck.files + deck.uploads).first(where: { $0.id == id }) {
            NavigationStack { FilePreviewView(file: f) }
        } else { EmptyHint(icon: "doc", title: "That file is not in the list", detail: "It may have been removed.") }
    }
}

/// A long-form report as a portal: every section in order, scrollable. (Full briefings with voice-clocked zoom, code and
/// citations are not drawn on the phone yet; see STATUS.md.)
struct ReportPortal: View {
    var reportId: String
    @EnvironmentObject var debrief: DebriefModel
    var body: some View {
        ScrollView {
            if let r = debrief.report, r.info.id == reportId {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text(r.title).font(.title3.weight(.semibold)).foregroundColor(Theme.text)
                    ForEach(Array(r.blocks.enumerated()), id: \.offset) { i, b in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(format: "%02d  ", i + 1) + b.heading).font(.system(size: 15, weight: .semibold)).foregroundColor(SceneStyle.tone(b.tone))
                            SceneBody(card: DebriefModel.Card(id: b.id, block: b, side: .right), reportId: r.info.id)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(SceneStyle.tone(b.tone))
                    }
                }.padding(12)
            } else { EmptyHint(icon: "doc.richtext", title: "This report is closed") }
        }
    }
}

// MARK: "Jarvis wants to talk"

struct BriefingBanner: View {
    @EnvironmentObject var briefing: BriefingModel
    @EnvironmentObject var call: CallModel
    /// Like the browser: on a call the server briefs by voice at once; otherwise the call starts first and he briefs the moment it is up
    /// (no microphone: ask for the text version instead).
    private func talkNow() {
        if call.isActive { briefing.accept(textOnly: false) }
        else { call.startCall(); if call.phase.isBlocked { briefing.accept(textOnly: true) } }
    }

    var body: some View {
        if !briefing.asked.isEmpty {
            let tint = briefing.priority == "critical" ? Theme.hot : (briefing.priority == "high" ? Theme.warn : Theme.accent(.jarvis))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint, radius: 5)
                    Text("JARVIS WANTS TO TALK").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(tint)
                    Spacer()
                    PillLabel(text: briefing.priority, color: tint)
                }
                ForEach(briefing.asked.prefix(3)) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
                        Text(r.failed ? "Something went wrong" : r.preview).font(.system(size: 11)).foregroundColor(Theme.dimText).lineLimit(2)
                    }
                }
                if briefing.asked.count > 3 { Text("+\(briefing.asked.count - 3) more").font(.caption2).foregroundColor(Theme.dimText) }
                HStack {
                    Button("Later") { briefing.later() }.buttonStyle(.bordered)
                    Button("Dismiss") { briefing.dismiss() }.buttonStyle(.bordered).tint(Theme.bad)
                    Spacer()
                    Button { talkNow() } label: { Label("Talk now", systemImage: "waveform") }.buttonStyle(.borderedProminent).tint(tint)
                }
            }
            .padding(12).holoPlate(tint, active: true, corner: 14)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }
}
