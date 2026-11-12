import XCTest
@testable import JarvisCore

final class NeuralCoreTests: XCTestCase {
    func testGeometryIsDeterministicAndShaped() {
        let a = NeuralGeometry(tier: .standard), b = NeuralGeometry(tier: .standard)
        XCTAssertEqual(a.particles.count, CoreTier.standard.points)
        XCTAssertEqual(a.particles[10].dir, b.particles[10].dir)
        XCTAssertEqual(a.particles[500].r.0, b.particles[500].r.0)
        let shell = a.particles.filter { $0.radius == 1.0 }.count
        XCTAssertEqual(Double(shell) / Double(a.particles.count), 0.7, accuracy: 0.02)
        for p in a.particles { XCTAssertEqual(p.dir.length, 1, accuracy: 1e-3) }
        let hubs = a.particles.filter { $0.isHub }.count
        XCTAssertGreaterThan(hubs, 30); XCTAssertLessThan(hubs, Int(Double(a.particles.count) * 0.12))
        XCTAssertFalse(a.links.isEmpty); XCTAssertTrue(a.links.allSatisfy { a.particles[$0.a].isHub && a.particles[$0.b].isHub })
        XCTAssertTrue(NeuralGeometry(tier: .lite).links.isEmpty, "lite tier draws no synapses")
    }
    func testSeededRandomMatchesMulberry32() {
        var r = SeededRandom(seed: 1)
        // first outputs of mulberry32(1)
        XCTAssertEqual(r.next(), 0.6270739, accuracy: 1e-6)
        XCTAssertEqual(r.next(), 0.0027350, accuracy: 1e-6)
    }
    func testParticlesStayNearTheCoreAndRotationPreservesLength() {
        let g = NeuralGeometry(tier: .lite)
        var u = CoreUniforms(); u.energy = 0.6; u.time = 3.3; u.listen = 1; u.waveR = 1; u.waveA = 0.9
        for sig in [0, 1, 2, 3] {
            u.sigA = Float(sig); u.sigB = Float(sig)
            for p in g.particles {
                let v = NeuralShader.position(p, u)
                XCTAssertLessThan(v.length, 2.0, "signature \(sig)"); XCTAssertFalse(v.x.isNaN || v.y.isNaN || v.z.isNaN)
            }
        }
        let rot = Mat3.rotYX(ay: 1.1, ax: 0.4)
        let v = Vec3(0.3, -0.5, 0.8)
        XCTAssertEqual(rot.apply(v).length, v.length, accuracy: 1e-5)
    }
    func testProjectionDepthAndPlacement() {
        let rot = Mat3.identity
        let near = CoreProjection.project(Vec3(0, 0, -1), rot: rot, origin: (100, 100), radius: 50, focal: 210)
        let far = CoreProjection.project(Vec3(0, 0, 1), rot: rot, origin: (100, 100), radius: 50, focal: 210)
        XCTAssertLessThan(near.depth, far.depth)
        XCTAssertEqual(near.x, 100, accuracy: 1e-4); XCTAssertEqual(near.y, 100, accuracy: 1e-4)
        XCTAssertGreaterThan(near.scale, far.scale)
        let right = CoreProjection.project(Vec3(1, 0, 0), rot: rot, origin: (100, 100), radius: 50, focal: 210)
        XCTAssertGreaterThan(right.x, 100)
        let up = CoreProjection.project(Vec3(0, 1, 0), rot: rot, origin: (100, 100), radius: 50, focal: 210)
        XCTAssertLessThan(up.y, 100, "screen y grows downward")
    }
    func run(_ state: String, muted: Bool = false, mic: Float = 0, out: Float = 0, seconds: Float = 2) -> CoreFrame {
        var a = CoreAnimator(); a.state = state; a.muted = muted
        var f = CoreFrame()
        for _ in 0..<Int(seconds * 60) { f = a.step(dt: 1 / 60, mic: mic, out: out) }
        return f
    }
    func testStatesDriveEnergyLikeTheBrowser() {
        let idle = run("idle"), listening = run("listening", mic: 0.2), thinking = run("thinking"), speaking = run("speaking", out: 0.15), off = run("offline")
        XCTAssertGreaterThan(listening.energy, idle.energy)
        XCTAssertGreaterThan(thinking.energy, idle.energy); XCTAssertEqual(thinking.activity, 1, accuracy: 0.05)
        XCTAssertGreaterThan(speaking.energy, idle.energy)
        XCTAssertLessThan(off.energy, idle.energy); XCTAssertEqual(off.dim, 0.45, accuracy: 1e-6)
        XCTAssertGreaterThan(listening.uniforms.listen, 0.5)
        XCTAssertEqual(run("listening", muted: true).mode, .muted)
        XCTAssertEqual(run("speaking", muted: true, out: 0.1).mode, .speaking, "muted does not hide his speech")
        XCTAssertGreaterThan(run("speaking", out: 0.3).blink, 0.5)
    }
    func testWaveFiresOnLoudSyllable() {
        var a = CoreAnimator(); a.state = "speaking"
        for _ in 0..<30 { a.step(dt: 1 / 60, mic: 0, out: 0.01) }
        let f = a.step(dt: 1 / 60, mic: 0, out: 0.4)
        XCTAssertGreaterThan(f.uniforms.waveA, 0.5)
    }
    func testPersonaMorphAndColour() {
        var a = CoreAnimator(); a.state = "idle"; a.step(dt: 0.016, mic: 0, out: 0)
        a.setPersona(.friday)
        var f = a.step(dt: 0.016, mic: 0, out: 0)
        XCTAssertLessThan(f.uniforms.morph, 1); XCTAssertTrue(a.isBusy)
        for _ in 0..<200 { f = a.step(dt: 0.016, mic: 0, out: 0) }
        XCTAssertEqual(f.uniforms.morph, 1, accuracy: 1e-6); XCTAssertEqual(f.uniforms.sigB, 1)
        XCTAssertEqual(f.color[0], Float(Persona.friday.color[0]), accuracy: 0.02)
        a.reducedMotion = true; a.setPersona(.edith)
        XCTAssertEqual(a.step(dt: 0.016, mic: 0, out: 0).uniforms.morph, 1, "reduced motion snaps")
    }
    func testLargeDtIsClamped() {
        var a = CoreAnimator(); a.state = "thinking"
        let f = a.step(dt: 5, mic: 0, out: 0)
        XCTAssertFalse(f.energy.isNaN); XCTAssertLessThan(f.spin, 1)
    }
    func testPersonas() {
        XCTAssertEqual(Persona.of("FRIDAY").key, "friday"); XCTAssertEqual(Persona.of(nil).key, "jarvis"); XCTAssertEqual(Persona.of("???").key, "jarvis")
        XCTAssertEqual(Persona.jarvis.color[0], 0x4c / 255.0, accuracy: 1e-9)
    }
}
