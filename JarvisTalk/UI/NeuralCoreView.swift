import SwiftUI
import JarvisCore

/// Draws the neural core with the same maths, colours and motion as the web client (JarvisCore.NeuralCore is a
/// direct port of js/neural/*). SwiftUI Canvas inside a TimelineView: particles are batched into a handful of
/// paths per frame, the frame rate drops to 30 when nothing is happening, and the timeline is paused whenever
/// the view is not visible (other tab, app in the background, screen locked).
final class CoreDriver: ObservableObject {
    private(set) var geometry: NeuralGeometry
    private(set) var animator = CoreAnimator()
    private var lastTime: Date?
    var tier: CoreTier { didSet { if tier != oldValue { geometry = NeuralGeometry(tier: tier) } } }

    init(tier: CoreTier) { self.tier = tier; geometry = NeuralGeometry(tier: tier) }

    func configure(state: String, muted: Bool, persona: Persona, reduced: Bool) {
        animator.state = state; animator.muted = muted; animator.reducedMotion = reduced
        animator.setPersona(persona)
    }

    func resetClock() { lastTime = nil }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, date: Date, mic: Float, out: Float) {
        let dt = lastTime.map { Float(date.timeIntervalSince($0)) } ?? 1.0 / 60
        lastTime = date
        let f = animator.step(dt: dt, mic: mic, out: out)
        paint(&ctx, size: size, f: f)
    }

    private func rgb(_ c: [Float], _ opacity: Double = 1) -> Color { Color(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2])).opacity(opacity) }

    private func paint(_ ctx: inout GraphicsContext, size: CGSize, f: CoreFrame) {
        let w = Float(size.width), h = Float(size.height)
        guard w > 10, h > 10 else { return }
        let R = min(w, h) * 0.2
        let cx = w / 2, cy = h * 0.5
        let focal = R * 4.2
        let col = f.color, col2 = f.color2
        ctx.blendMode = .plusLighter

        // halo
        let hr = CGFloat(R * f.haloRadius)
        ctx.fill(Path(ellipseIn: CGRect(x: CGFloat(cx) - hr, y: CGFloat(cy) - hr, width: hr * 2, height: hr * 2)),
                 with: .radialGradient(Gradient(colors: [rgb(col, Double(f.haloAlpha)), rgb(col, Double(f.haloAlpha) * 0.35), .clear]),
                                       center: CGPoint(x: Double(cx), y: Double(cy)), startRadius: CGFloat(R * 0.3), endRadius: hr))

        // rings
        if geometry.tier != .lite {
            for (i, r) in CoreRings.list.enumerated() {
                let rot = Mat3.rotYX(ay: f.ringTurn * r.turn, ax: r.tilt)
                var path = Path()
                let steps = 72
                let scale = r.scale + f.energy * 0.08 * sin(f.uniforms.time * 3 + Float(i))
                for k in 0...steps {
                    let a = Float(k) / Float(steps) * 2 * .pi
                    let p = CoreProjection.project(Vec3(cos(a) * scale, 0, sin(a) * scale), rot: rot, origin: (cx, cy), radius: R, focal: focal)
                    let pt = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                    if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(rgb(col2, Double(min(1, r.alpha * f.ringAlpha * 0.5)))), lineWidth: CGFloat(r.width))
            }
        }

        // particles: computed once, then drawn as a few batched paths (alpha bucket x hot/normal)
        let u = f.uniforms
        let buckets = 6
        var normal = [Path](repeating: Path(), count: buckets)
        var hot = [Path](repeating: Path(), count: buckets)
        var positions = [CGPoint](repeating: .zero, count: geometry.particles.count)
        var alphas = [Float](repeating: 0, count: geometry.particles.count)
        let sizeBase: Float = geometry.tier == .lite ? 2.6 : 2.3
        for (i, p) in geometry.particles.enumerated() {
            let v = NeuralShader.position(p, u)
            let s = CoreProjection.project(v, rot: f.rotation, origin: (cx, cy), radius: R, focal: focal)
            let hub: Float = p.isHub ? 1 : 0
            let near = 1 - s.depth
            let wave = NeuralShader.wave(v, u)
            let hotness = min(1, hub * 0.5 + wave * 0.8 + (p.r.2 >= 0.985 ? 0.6 : 0))
            let alpha = max(0, min(1, (0.12 + 0.62 * near) * (0.55 + f.energy * 0.5 + hub * 0.5 + wave) * f.dim * (0.85 + 0.25 * f.blink)))
            let dot = sizeBase * s.scale * (0.55 + p.r.2 * 0.9 + hub * 1.4) * (1 + f.energy * 0.25)
            let r = CGFloat(dot) * 0.5
            positions[i] = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y)); alphas[i] = alpha
            let b = min(buckets - 1, Int(alpha * Float(buckets)))
            let rect = CGRect(x: CGFloat(s.x) - r, y: CGFloat(s.y) - r, width: r * 2, height: r * 2)
            if hotness > 0.4 { hot[b].addEllipse(in: rect) } else { normal[b].addEllipse(in: rect) }
        }

        // synapses: faint lines between neurons, and a bright signal travelling along the busy ones
        if !geometry.links.isEmpty {
            var lines = Path()
            var heads: [(CGPoint, Double)] = []
            for l in geometry.links {
                let a = positions[l.a], b = positions[l.b]
                lines.move(to: a); lines.addLine(to: b)
                let live = l.phase <= 0.15 + f.activity * 0.7
                if live {
                    let head = NeuralShader.fract(u.time * (0.35 + l.phase * 0.9) * (0.6 + f.activity * 1.6) + l.phase * 7)
                    let pt = CGPoint(x: a.x + (b.x - a.x) * CGFloat(head), y: a.y + (b.y - a.y) * CGFloat(head))
                    heads.append((pt, Double((0.35 + f.activity) * f.dim * min(1, 0.4 + f.energy))))
                }
            }
            ctx.stroke(lines, with: .color(rgb(col, Double(0.07 + f.energy * 0.12) * Double(f.dim))), lineWidth: 0.6)
            for (pt, a) in heads {
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 1.6, y: pt.y - 1.6, width: 3.2, height: 3.2)), with: .color(rgb(col2, min(1, a))))
            }
        }

        for b in 0..<buckets {
            let alpha = (Double(b) + 0.5) / Double(buckets)
            ctx.fill(normal[b], with: .color(rgb(col, alpha)))
            ctx.fill(hot[b], with: .color(rgb(col2, min(1, alpha + 0.15))))
        }

        // speech wave leaving the core on each loud syllable
        if u.waveA > 0.02 {
            let wr = CGFloat(R * u.waveR)
            ctx.stroke(Path(ellipseIn: CGRect(x: CGFloat(cx) - wr, y: CGFloat(cy) - wr, width: wr * 2, height: wr * 2)),
                       with: .color(rgb(col2, Double(u.waveA) * 0.5)), lineWidth: 1.5)
        }

        // hairline circle and the bright core
        let hair = CGFloat(R * f.hairRadius)
        ctx.stroke(Path(ellipseIn: CGRect(x: CGFloat(cx) - hair, y: CGFloat(cy) - hair, width: hair * 2, height: hair * 2)),
                   with: .color(rgb(col, Double(f.hairAlpha) * 0.5)), lineWidth: 0.8)
        let cr = CGFloat(R * f.coreRadius * 2.4)
        ctx.fill(Path(ellipseIn: CGRect(x: CGFloat(cx) - cr, y: CGFloat(cy) - cr, width: cr * 2, height: cr * 2)),
                 with: .radialGradient(Gradient(colors: [rgb(col2, Double(f.coreAlpha)), rgb(col, Double(f.coreAlpha) * 0.4), .clear]),
                                       center: CGPoint(x: Double(cx), y: Double(cy)), startRadius: 0, endRadius: cr))
    }
}

struct NeuralCoreView: View {
    var state: String
    var muted: Bool
    var persona: Persona = .jarvis
    var active: Bool                       // false pauses the timeline: nothing is drawn, no battery is used
    var micLevel: () -> Float
    var outLevel: () -> Float

    @StateObject private var driver = CoreDriver(tier: NeuralCoreView.initialTier())
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    static func initialTier() -> CoreTier {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? .lite : .standard
    }

    private var busy: Bool { ["listening", "thinking", "speaking"].contains(state) }

    var body: some View {
        let _ = driver.configure(state: state, muted: muted, persona: persona, reduced: reduceMotion)
        let _ = driver.tier = lowPower ? .lite : NeuralCoreView.initialTier()
        TimelineView(.animation(minimumInterval: busy ? 1.0 / 60 : 1.0 / 30, paused: !active)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                driver.draw(&ctx, size: size, date: timeline.date, mic: micLevel(), out: outLevel())
            }
        }
        .onChange(of: active) { _ in driver.resetClock() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .accessibilityElement()
        .accessibilityLabel("Jarvis")
        .accessibilityValue(muted && state != "speaking" ? "microphone muted" : state)
    }
}
