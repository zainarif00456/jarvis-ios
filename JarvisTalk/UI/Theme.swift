import SwiftUI
import JarvisCore

/// The look of the web deck: near-black void, the present AI's colour for lines and glows, glass plates.
enum Theme {
    static let void = Color(red: 0.004, green: 0.02, blue: 0.035)
    static let panel = Color(red: 0.02, green: 0.05, blue: 0.075)
    static let ok = Color(red: 0.204, green: 0.827, blue: 0.6)
    static let warn = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let bad = Color(red: 0.97, green: 0.44, blue: 0.44)
    static let hot = Color(red: 1.0, green: 0.3, blue: 0.37)
    static let text = Color(red: 0.89, green: 0.97, blue: 1.0)
    static let dimText = Color(red: 0.58, green: 0.66, blue: 0.74)

    static func accent(_ p: Persona) -> Color { Color(red: p.color[0], green: p.color[1], blue: p.color[2]) }
    static func accentLight(_ p: Persona) -> Color { Color(red: p.color2[0], green: p.color2[1], blue: p.color2[2]) }
    static func persona(_ key: String?) -> Color { accent(Persona.of(key)) }
    static let mono = Font.system(.footnote, design: .monospaced)
}

struct GlassCard: ViewModifier {
    var accent: Color = Theme.accent(.jarvis)
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
    }
}
extension View {
    func glass(_ accent: Color = Theme.accent(.jarvis)) -> some View { modifier(GlassCard(accent: accent)) }
}

/// A screen background: the void with a faint glow of the present AI's colour.
struct StageBackground: View {
    var accent: Color
    var body: some View {
        ZStack {
            Theme.void
            RadialGradient(colors: [accent.opacity(0.14), .clear], center: .init(x: 0.5, y: 0.25), startRadius: 0, endRadius: 420)
            // a faint hologram floor grid, drawn once (no animation, no per-frame cost)
            Canvas { ctx, size in
                var x: CGFloat = 0
                while x <= size.width { ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(accent.opacity(0.035))); x += 36 }
                var y: CGFloat = 0
                while y <= size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)), with: .color(accent.opacity(0.035))); y += 36 }
            }
            .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
        }.ignoresSafeArea()
    }
}

struct PillLabel: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 0.5))
            .foregroundColor(color)
    }
}

struct EmptyHint: View {
    var icon: String
    var title: String
    var detail: String = ""
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 34)).foregroundColor(Theme.dimText)
            Text(title).font(.headline).foregroundColor(Theme.text)
            if !detail.isEmpty { Text(detail).font(.footnote).foregroundColor(Theme.dimText).multilineTextAlignment(.center) }
        }
        .padding(32).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
