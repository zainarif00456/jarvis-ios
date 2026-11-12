import SwiftUI
import JarvisCore
import JarvisModel

// The browser's visual language (css/holo.css, exec.css, debrief.css), natively: a translucent plate with feathered
// light edges, hairlines that are brightest in the middle, a soft halo, corner nodes, a slow scan sweep on the portal in
// front, and things that FORM out of the core and MELT back into it. Performance rules from the browser apply: motion is
// transform / opacity, only the portal in front animates, and everything goes calm with Reduce Motion, Low Power Mode or the
// Settings choice "calm".

// MARK: effects policy

private struct CalmKey: EnvironmentKey { static let defaultValue = false }
private struct EmbeddedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// true = no animated effects (Reduce Motion, Low Power Mode, or Settings > Effects > Calm).
    var calmFX: Bool { get { self[CalmKey.self] } set { self[CalmKey.self] = newValue } }
    /// true inside a portal on Home: the portal already has a title bar with a close control.
    var embeddedInPortal: Bool { get { self[EmbeddedKey.self] } set { self[EmbeddedKey.self] = newValue } }
}

/// Wraps the app and publishes `calmFX`.
struct FXScope<Content: View>: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ViewBuilder var content: () -> Content

    var body: some View {
        let calm: Bool = {
            switch settings.effects { case "calm": return true; case "full": return false; default: return reduceMotion || lowPower }
        }()
        content()
            .environment(\.calmFX, calm)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

// MARK: the plate

/// A holographic plate: gradient glass, feathered hairlines, halo, corner nodes; a scan sweep when `active`.
struct HoloPlate: ViewModifier {
    var tint: Color
    var active: Bool = true
    var corner: CGFloat = 16
    @Environment(\.calmFX) private var calm

    func body(content: Content) -> some View {
        content
            .background(plate)
            .overlay(edge)
            .overlay(nodes)
            .overlay(sweep)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: tint.opacity(active ? 0.42 : 0.16), radius: active ? 20 : 9, x: 0, y: 6)
    }

    private var plate: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.22), Theme.panel.opacity(0.94), Theme.void.opacity(0.96)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(.ultraThinMaterial).opacity(0.28)
            RadialGradient(colors: [tint.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 220)
            // faint interference lines (static, drawn once)
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(tint.opacity(0.045)))
                    y += 3
                }
            }.allowsHitTesting(false)
        }
    }

    private var edge: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(LinearGradient(colors: [tint.opacity(active ? 0.95 : 0.55), tint.opacity(0.12), tint.opacity(active ? 0.8 : 0.4)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
    }

    private var nodes: some View {
        GeometryReader { g in
            ForEach(0..<4, id: \.self) { i in
                Circle().fill(Theme.text).frame(width: 5, height: 5)
                    .shadow(color: tint, radius: 4).shadow(color: tint.opacity(0.6), radius: 9)
                    .opacity(active ? 1 : 0.4)
                    .position(x: i % 2 == 0 ? 4 : g.size.width - 4, y: i < 2 ? 4 : g.size.height - 4)
            }
        }.allowsHitTesting(false)
    }

    @ViewBuilder private var sweep: some View {
        if active && !calm {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                GeometryReader { g in
                    let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 7.5) / 7.5       // 0...1
                    let y = (min(t / 0.7, 1)) * (g.size.height * 1.4) - g.size.height * 0.3
                    LinearGradient(colors: [.clear, tint.opacity(0.07), tint.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: g.size.height * 0.3).offset(y: y)
                }
            }.allowsHitTesting(false)
        }
    }
}

extension View {
    func holoPlate(_ tint: Color, active: Bool = true, corner: CGFloat = 16) -> some View { modifier(HoloPlate(tint: tint, active: active, corner: corner)) }
}

// MARK: forming out of the core and melting back

/// Scale + offset + fade + blur between "at the core" and "formed".
struct CoreForm: ViewModifier {
    var formed: Bool
    var toCore: CGSize          // vector from the card's resting place to the orb
    var calm: Bool
    func body(content: Content) -> some View {
        if calm {
            content.opacity(formed ? 1 : 0)
        } else {
            content
                .scaleEffect(formed ? 1 : 0.18, anchor: .center)
                .offset(formed ? .zero : toCore)
                .opacity(formed ? 1 : 0)
                .blur(radius: formed ? 0 : 6)
        }
    }
}
extension AnyTransition {
    /// A card that forms out of the core (insertion) and melts back into it (removal).
    static func fromCore(_ toCore: CGSize, calm: Bool) -> AnyTransition {
        .modifier(active: CoreForm(formed: false, toCore: toCore, calm: calm), identity: CoreForm(formed: true, toCore: toCore, calm: calm))
    }
}

/// A short light beam from the core to a point, drawn once when a card forms.
struct CoreBeam: View {
    var from: CGPoint
    var to: CGPoint
    var tint: Color
    @Environment(\.calmFX) private var calm
    @State private var progress: CGFloat = 0
    @State private var fade: Double = 1
    var body: some View {
        if calm { Color.clear.frame(width: 0, height: 0) } else {
            Path { p in p.move(to: from); p.addLine(to: to) }
                .trim(from: max(0, progress - 0.35), to: progress)
                .stroke(LinearGradient(colors: [tint.opacity(0), tint, Theme.text], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .shadow(color: tint, radius: 6)
                .opacity(fade)
                .allowsHitTesting(false)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.55)) { progress = 1.35 }
                    withAnimation(.easeIn(duration: 0.25).delay(0.45)) { fade = 0 }
                }
        }
    }
}

// MARK: small shared pieces

/// Text that types itself in (within `ms`), whole at once when calm or short.
struct TypeOut: View {
    var text: String
    var ms: Double = 900
    var font: Font = .system(.caption, design: .monospaced)
    @Environment(\.calmFX) private var calm
    @State private var start = Date()
    var body: some View {
        if calm || text.count < 24 || text.count > 1200 {
            Text(text).font(font)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                let total = min(ms / 1000, 0.24 + Double(text.count) * 0.002)
                let k = min(1, max(0, tl.date.timeIntervalSince(start) / total))
                Text(String(text.prefix(Int((Double(text.count) * k).rounded(.up))))).font(font)
            }
        }
    }
}

/// "‹ Jarvis" — on every screen reachable from the bottom bar: the way back is always one tap (or an edge swipe) away.
struct BackToJarvisButton: View {
    @Environment(\.goHome) private var goHome
    @Environment(\.embeddedInPortal) private var embedded
    var body: some View {
        if embedded { EmptyView() } else {
            Button { goHome() } label: {
                Label("Jarvis", systemImage: "chevron.left").labelStyle(.titleAndIcon).font(.system(size: 14, weight: .semibold))
            }
            .accessibilityLabel("Back to Jarvis")
        }
    }
}

private struct GoHomeKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues { var goHome: () -> Void { get { self[GoHomeKey.self] } set { self[GoHomeKey.self] = newValue } } }

/// Swipe in from the left edge to go back to Jarvis (screens pushed inside a NavigationStack keep their own back swipe).
struct EdgeSwipeBack: ViewModifier {
    @Environment(\.goHome) private var goHome
    @Environment(\.embeddedInPortal) private var embedded
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if !embedded {
                Color.clear.frame(width: 18).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 24).onEnded { v in
                        if v.translation.width > 70 && abs(v.translation.height) < 90 { goHome() }
                    })
            }
        }
    }
}
extension View {
    func edgeSwipeBack() -> some View { modifier(EdgeSwipeBack()) }
}

private struct ClosePortalKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues { var closePortal: () -> Void { get { self[ClosePortalKey.self] } set { self[ClosePortalKey.self] = newValue } } }

/// "Close": dismisses a sheet, or closes the portal this screen is shown in.
struct SmartCloseButton: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.embeddedInPortal) private var embedded
    @Environment(\.closePortal) private var closePortal
    var body: some View {
        Button("Close") { if embedded { closePortal() } else { dismiss() } }.accessibilityLabel("Close")
    }
}
