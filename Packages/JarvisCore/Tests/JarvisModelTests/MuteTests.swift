import XCTest
import JarvisCore
import JarvisNet
@testable import JarvisModel

/// Mute silences only the microphone sent to Jarvis. Everything else keeps running.
@MainActor
final class MuteTests: XCTestCase {
    let frame = Data(repeating: 1, count: 1280)

    func live(_ rig: Rig, _ app: AppModel, conn: Int = 0) async {
        await eventually("conn") { rig.transport.count > conn }
        let c = rig.transport.conn(conn)
        c.pushJSON(welcomeText)
        await eventually("call_start") { c.sent("call_start") }
        c.pushJSON(#"{"type":"call_started"}"#)
        await eventually("active") { app.call.isActive }
    }

    func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

    func testMutedSendsNoFramesButTheCallAndHisVoiceStayUp() async {
        let rig = Rig(); let app = rig.model(); app.launch(); await live(rig, app)
        var changes: [Bool] = []
        app.call.onMutedChanged = { changes.append($0) }
        XCTAssertTrue(app.call.setMuted(true))
        for _ in 0..<5 { rig.audio.onMicFrame?(frame, 0.2) }
        await settle()
        XCTAssertEqual(rig.transport.conn(0).binaries.count, 0, "muted: no microphone frames leave the phone")
        XCTAssertTrue(app.call.isActive, "the call stays up")
        XCTAssertEqual(app.link, .online, "the socket stays up")
        XCTAssertEqual(app.display, .connected)
        rig.transport.conn(0).push(.binary(Data(repeating: 3, count: 4800)))
        await eventually("his voice still plays while muted") { rig.audio.played.count == 4800 }
        XCTAssertFalse(rig.transport.conn(0).sent("call_end"))
        XCTAssertEqual(rig.audio.stops, 0)
        app.call.setMuted(false)
        rig.audio.onMicFrame?(frame, 0.2)
        await eventually("unmute resumes at once") { rig.transport.conn(0).binaries.count == 1 }
        XCTAssertEqual(changes, [true, false])
    }

    func testToggleAndRepeatedSetAreIdempotent() async {
        let rig = Rig(); let app = rig.model(); app.launch(); await live(rig, app)
        var changes = 0
        app.call.onMutedChanged = { _ in changes += 1 }
        app.call.toggleMute(); XCTAssertTrue(app.call.muted)
        app.call.setMuted(true); app.call.setMuted(true)
        XCTAssertEqual(changes, 1)
        app.call.toggleMute(); XCTAssertFalse(app.call.muted)
    }

    func testNothingToMuteWithoutACall() async {
        let rig = Rig(autoStart: false); let app = rig.model(); app.launch()
        XCTAssertFalse(app.call.canMute)
        XCTAssertFalse(app.call.setMuted(true))
        XCTAssertFalse(app.call.muted)
    }

    func testMuteSurvivesReconnectInterruptionAndRouteChange() async {
        let rig = Rig(); let app = rig.model(); app.launch(); await live(rig, app)
        app.call.setMuted(true)
        // socket drops: the call is held, still muted, and still muted after the resume
        rig.transport.conn(0).fail()
        await eventually("held") { app.call.phase == .held }
        XCTAssertTrue(app.call.muted)
        await eventually("second socket") { rig.transport.count == 2 }
        rig.transport.conn(1).pushJSON(welcomeText)
        await eventually("resume") { rig.transport.conn(1).sent("call_start") }
        rig.transport.conn(1).pushJSON(#"{"type":"call_started","resumed":true}"#)
        await eventually("active") { app.call.isActive }
        XCTAssertTrue(app.call.muted, "still muted after the reconnect")
        // interruption (phone call, Siri) and its end
        rig.audio.onEvent?(.interruptionBegan)
        rig.audio.onEvent?(.interruptionEnded(shouldResume: true))
        await eventually("audio restarted") { rig.audio.restarts == 1 }
        XCTAssertTrue(app.call.muted, "still muted after an interruption")
        // Bluetooth route change and engine rebuild
        rig.audio.onEvent?(.routeChanged("AirPods"))
        rig.audio.onEvent?(.mediaServicesReset)
        await eventually("restart") { rig.audio.restarts == 2 }
        XCTAssertTrue(app.call.muted, "still muted after a route change")
        for _ in 0..<5 { rig.audio.onMicFrame?(frame, 0.3) }
        await settle()
        XCTAssertEqual(rig.transport.conn(1).binaries.count, 0, "no frames leaked at any point")
    }

    func testANewCallStartsUnmuted() async {
        let rig = Rig(); let app = rig.model(); app.launch(); await live(rig, app)
        app.call.setMuted(true)
        app.call.endCall()
        XCTAssertFalse(app.call.muted, "ending the call clears mute")
        app.call.startCall()
        await eventually("call_start again") { rig.transport.conn(0).texts.filter { $0.contains("call_start") }.count == 2 }
        rig.transport.conn(0).pushJSON(#"{"type":"call_started"}"#)
        await eventually("active") { app.call.isActive }
        XCTAssertFalse(app.call.muted)
        rig.audio.onMicFrame?(frame, 0.2)
        await eventually("frames flow in the new call") { rig.transport.conn(0).binaries.count == 1 }
    }

    func testServerEndingTheCallClearsMute() async {
        let rig = Rig(); let app = rig.model(); app.launch(); await live(rig, app)
        app.call.setMuted(true)
        rig.transport.conn(0).pushJSON(#"{"type":"call_ended","reason":"bye"}"#)
        await eventually("ended") { !app.call.inCall }
        XCTAssertFalse(app.call.muted)
    }
}
