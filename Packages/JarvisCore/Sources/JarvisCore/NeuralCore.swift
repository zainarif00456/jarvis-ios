import Foundation

/// The neural core (the orb) as pure maths: the particle sphere, how each particle moves, how the animation
/// state (idle / listening / thinking / speaking) drives energy, colour and spin. A direct port of the web
/// client's js/neural/{geometry,shaders,core}.js, so the iOS app looks and moves the same. The app only
/// draws what `NeuralGeometry` and `CoreAnimator` produce (SwiftUI Canvas), at a frame rate it chooses.

public struct Vec3: Equatable, Sendable {
    public var x: Float, y: Float, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Float) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public var length: Float { (x * x + y * y + z * z).squareRoot() }
    public var normalized: Vec3 { let l = max(length, 1e-6); return Vec3(x / l, y / l, z / l) }
    func mix(_ o: Vec3, _ t: Float) -> Vec3 { self * (1 - t) + o * t }
}

/// Mulberry32, the same generator the web client seeds its core with: the same layout on every launch.
public struct SeededRandom: Sendable {
    private var s: UInt32
    public init(seed: UInt32) { s = seed }
    public mutating func next() -> Float {
        s = s &+ 0x6d2b79f5
        var t = s
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Float((t ^ (t >> 14))) / 4294967296
    }
}

public struct CoreParticle: Sendable {
    public var dir: Vec3        // unit direction
    public var radius: Float    // layer radius (1 = the shell)
    public var r: (Float, Float, Float, Float)   // four random numbers per particle
    public var isHub: Bool { r.1 >= NeuralGeometry.hub }
}

public enum CoreTier: String, Sendable { case lite, standard, cinematic
    var points: Int {
        switch self { case .lite: return 600; case .standard: return 1300; case .cinematic: return 2200 }
    }
    var links: Int { self == .lite ? 0 : 2 }
}

public struct NeuralGeometry: Sendable {
    public static let hub: Float = 0.94
    public let particles: [CoreParticle]
    public let links: [(a: Int, b: Int, phase: Float)]
    public let tier: CoreTier

    /// Three Fibonacci-sphere layers (the shell and two inner layers) and a few percent "neurons", each linked to
    /// its nearest neurons. The web client draws 4200 particles with WebGL; a Canvas draws fewer (see CoreTier).
    public init(tier: CoreTier) {
        self.tier = tier
        var rand = SeededRandom(seed: 0x51a7e)
        let n = tier.points
        var out: [CoreParticle] = []
        let layers: [(Float, Float)] = [(1.0, 0.7), (0.66, 0.19), (0.4, 0.11)]
        let golden = Float.pi * (3 - 5.0.squareRoot().asFloat)
        var used = 0
        for (i, layer) in layers.enumerated() {
            let count = i == layers.count - 1 ? n - used : Int((Float(n) * layer.1).rounded())
            for k in 0..<count {
                let y = 1 - ((Float(k) + 0.5) / Float(count)) * 2
                let r = max(0, 1 - y * y).squareRoot()
                let th = golden * Float(k) + rand.next() * 0.3
                out.append(CoreParticle(dir: Vec3(cos(th) * r, y, sin(th) * r), radius: layer.0, r: (0, 0, 0, 0)))
            }
            used += count
        }
        for i in out.indices { out[i].r = (rand.next(), rand.next(), rand.next(), rand.next()) }
        particles = out

        var links: [(Int, Int, Float)] = []
        if tier.links > 0 {
            let hubs = out.indices.filter { out[$0].isHub }
            let pos = hubs.map { out[$0].dir * out[$0].radius }
            var seen = Set<Int>()
            for a in hubs.indices {
                var best: [(Float, Int)] = []
                for b in hubs.indices where b != a {
                    let d = pos[a] - pos[b]
                    let dist = d.x * d.x + d.y * d.y + d.z * d.z
                    if best.count < tier.links + 1 { best.append((dist, b)); best.sort { $0.0 < $1.0 } }
                    else if dist < best[best.count - 1].0 { best[best.count - 1] = (dist, b); best.sort { $0.0 < $1.0 } }
                }
                for (_, b) in best.prefix(tier.links) {
                    let key = a < b ? a * 100_000 + b : b * 100_000 + a
                    if seen.insert(key).inserted { links.append((hubs[a], hubs[b], rand.next())) }
                }
            }
        }
        self.links = links.map { (a: $0.0, b: $0.1, phase: $0.2) }
    }
}

private extension Double { var asFloat: Float { Float(self) } }

/// Per-frame values the particle placement needs (the shader's uniforms).
public struct CoreUniforms: Sendable {
    public var time: Float = 0
    public var energy: Float = 0.14
    public var listen: Float = 0
    public var waveR: Float = 0
    public var waveA: Float = 0
    public var sigA: Float = 0
    public var sigB: Float = 0
    public var morph: Float = 1
    public init() {}
}

public enum NeuralShader {
    static let tau: Float = 6.2831853

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
    public static func fract(_ x: Float) -> Float { x - floor(x) }

    static func knot(_ t: Float) -> Vec3 {
        let r = cos(3 * t) + 2
        return Vec3(r * cos(2 * t), -sin(3 * t), r * sin(2 * t)) * 0.24
    }

    static func innerShape(_ sig: Float, _ base: Vec3, _ p: CoreParticle, _ u: CoreUniforms) -> Vec3 {
        if sig < 0.5 { return base }
        let (r0, r1, r2, r3) = p.r
        if sig < 1.5 {                                   // Friday: knotted heart
            let t = r0 * tau
            return knot(t) + Vec3(r1 - 0.5, r2 - 0.5, r3 - 0.5) * 0.11
        }
        if sig < 2.5 {                                   // EDITH: lattice on an octahedron
            let s = abs(base.x) + abs(base.y) + abs(base.z) + 1e-4
            let d = Vec3(base.x / s, base.y / s, base.z / s)
            func q(_ v: Float) -> Float { floor(v * 6 + 0.5) / 6 * 0.95 }
            return Vec3(q(d.x) + (r1 - 0.5) * 0.02, q(d.y) + (r2 - 0.5) * 0.02, q(d.z) + (r3 - 0.5) * 0.02)
        }
        let rad = pow(r0, 0.6) * 0.92                    // Veronica: three spiral arms
        let ang = rad * 5.2 + floor(fract(r0 * 7) * 3) * 2.0944 + u.time * 0.35
        let k = 0.16 - rad * 0.08
        return Vec3(cos(ang) * rad + (r3 - 0.5) * k, (r2 - 0.5) * 0.08 + (r2 - 0.5) * k, sin(ang) * rad + (r1 - 0.5) * k)
    }

    static func shapeOf(_ sig: Float, _ p: CoreParticle, _ u: CoreUniforms) -> Vec3 {
        let base = p.dir * p.radius
        if p.radius < 0.99 { return innerShape(sig, base, p, u) }
        if sig > 1.5 && sig < 2.5 {                      // EDITH: the shell becomes faceted too
            let s = abs(p.dir.x) + abs(p.dir.y) + abs(p.dir.z)
            let d = Vec3(p.dir.x / s, p.dir.y / s, p.dir.z / s)
            let mixed = p.dir.mix(d, 0.55).normalized
            return mixed * (1 * (1 - 0.5) + d.length * 1.45 * 0.5)
        }
        return base
    }

    /// Where a particle is this frame, in core units (the shell has radius about 1).
    public static func position(_ p: CoreParticle, _ u: CoreUniforms) -> Vec3 {
        let to = shapeOf(u.sigB, p, u)
        var v = to
        if u.morph < 1 {                                              // mid-morph only: blend from the previous shape
            let from = shapeOf(u.sigA, p, u)
            let f = smoothstep(0, 1, max(0, min(1, u.morph * 1.5 - p.r.3 * 0.5)))
            v = from.mix(to, f)
            let arc = Vec3(p.r.0 - 0.5, p.r.1 - 0.5, p.r.2 - 0.5).normalized
            v = v + arc * (sin(f * 3.14159) * 0.22)                   // particles arc while they morph
        }
        let n = sin(v.x * 3 + u.time) * sin(v.y * 3.2 + u.time * 1.3) * sin(v.z * 2.8 + u.time * 0.7)
        v = v * (1 + n * (0.05 + u.energy * 0.07))                    // living surface
        let ripple = sin((p.dir.x * 0.6 + p.dir.y * 0.8) * 7 - u.time * 9)
        v = v * (1 + u.listen * 0.07 * ripple)                        // listening ripples
        let w = wave(v, u)
        return v * (1 + w * 0.06)                                     // speech wave
    }

    public static func wave(_ v: Vec3, _ u: CoreUniforms) -> Float {
        let d = (v.length - u.waveR) * 5
        return exp(-d * d) * u.waveA
    }
}

/// 3x3 rotation, row-major.
public struct Mat3: Sendable {
    public var m: [Float]
    public static let identity = Mat3(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])
    /// Rx(ax) * Ry(ay), as the web client's rotYX.
    public static func rotYX(ay: Float, ax: Float) -> Mat3 {
        let cy = cos(ay), sy = sin(ay), cx = cos(ax), sx = sin(ax)
        // column-major in JS; transposed here into row-major
        return Mat3(m: [cy, 0, sy,
                        sx * sy, cx, -sx * cy,
                        -cx * sy, sx, cx * cy])
    }
    public func apply(_ v: Vec3) -> Vec3 {
        Vec3(m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z, m[6] * v.x + m[7] * v.y + m[8] * v.z)
    }
}

public struct ProjectedPoint: Sendable { public var x: Float, y: Float, depth: Float, scale: Float }

public enum CoreProjection {
    /// -> (x px, y px, depth 0 near .. 1 far, perspective scale), the shader's `project`.
    public static func project(_ p: Vec3, rot: Mat3, origin: (Float, Float), radius: Float, focal: Float) -> ProjectedPoint {
        let q = rot.apply(p)
        let k = focal / (focal + q.z * radius)
        return ProjectedPoint(x: origin.0 + q.x * radius * k, y: origin.1 - q.y * radius * k,
                              depth: max(0, min(1, (q.z + 1.2) / 2.4)), scale: k)
    }
}

public enum CoreMode: String, Sendable { case offline, muted, idle, listening, thinking, speaking }

/// Everything the painter needs for one frame, as the web client's `frame()` computes it.
public struct CoreFrame: Sendable {
    public var uniforms = CoreUniforms()
    public var rotation = Mat3.identity
    public var color: [Float] = [0.3, 0.79, 0.94]
    public var color2: [Float] = [0.61, 0.91, 1.0]
    public var energy: Float = 0.14
    public var activity: Float = 0.12
    public var blink: Float = 0
    public var dim: Float = 1
    public var haloRadius: Float = 2.1      // in core radii
    public var haloAlpha: Float = 0.16
    public var coreRadius: Float = 0.2
    public var coreAlpha: Float = 0.75
    public var hairRadius: Float = 1.95
    public var hairAlpha: Float = 0.16
    public var ringAlpha: Float = 0.55
    public var ringTurn: Float = 0
    public var spin: Float = 0
    public var mode: CoreMode = .idle
}

/// Drives the core's animation from the call state and the mic / speaker levels. Call `step` once per frame.
public struct CoreAnimator: Sendable {
    public var state = "offline"
    public var muted = false
    public var reducedMotion = false
    public private(set) var frame = CoreFrame()

    private var t: Float = 0
    private var spin: Float = 0
    private var energy: Float = 0
    private var activity: Float = 0
    private var listen: Float = 0
    private var blink: Float = 0
    private var lastOut: Float = 0
    private var waveT: Float = -10
    private var morph: Float = 1
    private var sigA: Float = 0
    private var sigB: Float = 0
    private var goal = Persona.jarvis
    private var color: [Float] = Persona.jarvis.color.map { Float($0) }
    private var color2: [Float] = Persona.jarvis.color2.map { Float($0) }

    public init() {}

    static func ease(_ rate: Float, _ dt: Float) -> Float { 1 - exp(-rate * dt) }
    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    public var mode: CoreMode {
        if state == "offline" { return .offline }
        if muted && state != "speaking" && state != "thinking" { return .muted }
        switch state { case "listening": return .listening; case "thinking": return .thinking; case "speaking": return .speaking; default: return .idle }
    }

    /// True when the core is busy and deserves the full frame rate (otherwise 30 fps is plenty).
    public var isBusy: Bool { [.listening, .thinking, .speaking].contains(mode) || morph < 1 }

    /// The AI in front: colour and inner shape follow, morphing over 1.6 s.
    public mutating func setPersona(_ p: Persona) {
        guard p.key != goal.key else { return }
        sigA = morph >= 0.5 ? sigB : sigA
        sigB = Float(p.signature)
        morph = reducedMotion ? 1 : 0
        goal = p
    }

    @discardableResult
    public mutating func step(dt rawDt: Float, mic: Float, out: Float) -> CoreFrame {
        let dt = max(0, min(rawDt, 0.1))
        let slow: Float = reducedMotion ? 0.3 : 1
        t = (t + dt * slow).truncatingRemainder(dividingBy: 2000)
        let mode = self.mode
        var e: Float = 0.14 + 0.05 * sin(t * 1.4) + min(0.4, mic * 3)
        var a: Float = 0.12, l: Float = 0
        switch mode {
        case .listening: e = min(1, 0.28 + mic * 5); a = 0.3; l = min(1, mic * 7)
        case .thinking: e = 0.5 + 0.12 * sin(t * 5); a = 1
        case .speaking: e = min(1, 0.3 + out * 4.5); a = 0.45
        case .muted, .offline: e = 0.05; a = 0
        case .idle: break
        }
        energy = Self.lerp(energy, e, Self.ease(e > energy ? 16 : 5, dt))
        activity = Self.lerp(activity, a, Self.ease(3, dt))
        listen = Self.lerp(listen, l, Self.ease(l > listen ? 14 : 4, dt))

        let env: Float = mode == .speaking ? min(1, out * 5) : 0
        blink = Self.lerp(blink, env, Self.ease(env > blink ? 30 : 7, dt))
        if mode == .speaking && out > 0.07 && out > lastOut * 1.35 && t - waveT > 0.16 { waveT = t }
        lastOut = Self.lerp(lastOut, out, Self.ease(12, dt))
        let age = t - waveT
        let waveR = 0.25 + age * 1.9
        let waveA: Float = age >= 0 && age < 0.9 ? (1 - age / 0.9) * 0.9 : 0

        let k = Self.ease(3.2, dt)
        for i in 0..<3 {
            color[i] = Self.lerp(color[i], Float(goal.color[i]), k)
            color2[i] = Self.lerp(color2[i], Float(goal.color2[i]), k)
        }
        if morph < 1 { morph = min(1, morph + dt / 1.6) }

        let speed: Float = (mode == .thinking ? 1.9 : mode == .speaking ? 0.8 : mode == .listening ? 0.6 : 0.28) * slow
        spin += dt * speed

        let dim: Float = (mode == .muted || mode == .offline) ? 0.45 : 1
        let flash: Float = reducedMotion ? 0 : blink
        var f = CoreFrame()
        f.mode = mode
        f.uniforms.time = t; f.uniforms.energy = energy; f.uniforms.listen = listen
        f.uniforms.waveR = waveR; f.uniforms.waveA = reducedMotion ? 0 : waveA * dim
        f.uniforms.sigA = sigA; f.uniforms.sigB = sigB; f.uniforms.morph = morph
        f.rotation = Mat3.rotYX(ay: spin, ax: 0.42 + 0.1 * sin(t * 0.37))
        f.color = color; f.color2 = color2
        f.energy = energy; f.activity = activity; f.blink = flash; f.dim = dim
        f.haloRadius = 2.1 + energy * 0.8
        f.haloAlpha = min(1, (0.16 + flash * 0.16) * dim)
        f.coreRadius = 0.2 + energy * 0.12 + flash * 0.08
        f.coreAlpha = min(1, (0.75 + flash * 0.25 + 0.1 * sin(t * 2.2)) * dim)
        f.hairRadius = 1.95 + energy * 0.3
        f.hairAlpha = min(1, (0.16 + energy * 0.45) * dim)
        f.ringAlpha = (0.55 + energy * 0.5) * dim
        f.ringTurn = spin * 1.3
        f.spin = spin
        frame = f
        return f
    }
}

/// The three rings around the core (tilt, turn rate, scale, line width, alpha), from js/neural/core.js.
public enum CoreRings {
    public static let list: [(tilt: Float, turn: Float, scale: Float, width: Float, alpha: Float)] = [
        (0.0, 1.0, 1.36, 1.1, 0.55), (1.15, -0.7, 1.56, 0.9, 0.38), (-0.75, 0.45, 1.76, 0.8, 0.3),
    ]
}
