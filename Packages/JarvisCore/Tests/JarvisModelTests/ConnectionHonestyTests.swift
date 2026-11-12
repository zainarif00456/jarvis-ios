import XCTest
import JarvisCore
import JarvisNet
@testable import JarvisModel

/// The Home screen may only say "Connected" when the session socket is open AND the call is active AND audio runs.
@MainActor
final class ConnectionHonestyTests: XCTestCase {
    func goLive(_ rig: Rig, _ app: AppModel) async {
        await eventually("conn") { rig.transport.count >= 1 }
        let c = rig.transport.conn(rig.transport.count - 1)
        c.pushJSON(welcomeText)
        await eventually("call_start") { c.sent("call_start") }
        c.pushJSON(#"{"type":"call_started"}"#)
        await eventually("connected") { app.display == .connected }
    }

    func testServerUnreachableNeverShowsConnected() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        XCTAssertEqual(app.display, .connecting)
        await eventually("conn") { rig.transport.count == 1 }
        rig.transport.conn(0).fail()
        // 127.0.0.1:9 refuses connections: the address probe turns the retry loop into an honest failure
        await eventually("failed state", timeout: 10) { app.display.canRetry }
        XCTAssertEqual(app.display.statusText, "Not connected, tap to retry")
        XCTAssertNotEqual(app.link, .online)
        XCTAssertEqual(app.display.chipText, "not connected")
    }

    func testSocketOpensButTheCallNeverStarts() async {
        let rig = Rig(); let app = rig.model()
        app.call.callStartTimeout = 0.25; app.call.callRetryDelays = [0.1]
        app.launch()
        await eventually("conn") { rig.transport.count == 1 }
        let c = rig.transport.conn(0)
        c.pushJSON(welcomeText)
        await eventually("link online") { app.link == .online }
        XCTAssertNotEqual(app.display, .connected, "socket open is not enough")
        XCTAssertEqual(app.display, .connecting)
        await eventually("first start unanswered, retried by itself") { c.texts.filter { $0.contains("call_start") }.count == 2 }
        XCTAssertNotEqual(app.display, .connected)
        await eventually("gives up and says so") { app.display.canRetry }
        XCTAssertEqual(app.display.statusText, "Not connected, tap to retry")
        XCTAssertEqual(app.display.chipText, "not connected")
        app.retryConnection()
        await eventually("retry sends call_start again") { c.texts.filter { $0.contains("call_start") }.count == 3 }
        c.pushJSON(#"{"type":"call_started"}"#)
        await eventually("connected for real") { app.display == .connected }
        XCTAssertTrue(app.call.audioRunning)
    }

    func testFatalVoiceErrorFailsTheCallAtOnce() async {
        let rig = Rig(); let app = rig.model()
        app.call.callRetryDelays = []
        app.launch()
        await eventually("conn") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText)
        await eventually("call_start") { rig.transport.conn(0).sent("call_start") }
        rig.transport.conn(0).pushJSON(#"{"type":"voice_error","text":"speech service down","recoverable":false}"#)
        await eventually("failed") { app.display.canRetry }
    }

    func testResumeFromBackgroundVerifiesTheSocket() async {
        let rig = Rig(); let app = rig.model(); app.verifyTimeout = 0.3; app.launch()
        await goLive(rig, app)
        app.sceneBecameInactive(background: true)
        app.sceneBecameActive()
        await eventually("checking") { app.display == .checking }
        await eventually("ping sent") { rig.transport.conn(0).sent("ping") }
        rig.transport.conn(0).pushJSON(#"{"type":"pong"}"#)
        await eventually("verified, connected again") { app.display == .connected }
        XCTAssertEqual(rig.transport.count, 1, "an answering socket is kept")
    }

    func testResumeFromBackgroundWithADeadSocketReconnects() async {
        let rig = Rig(); let app = rig.model(); app.verifyTimeout = 0.3; app.launch()
        await goLive(rig, app)
        app.sceneBecameInactive(background: true)
        app.sceneBecameActive()
        await eventually("checking") { app.display == .checking }
        await eventually("silent socket dropped, new one opened") { rig.transport.count == 2 }
        XCTAssertNotEqual(app.display, .connected)
        let c = rig.transport.conn(1)
        c.pushJSON(welcomeText)
        await eventually("held call resumed") { c.sent("call_start") }
        c.pushJSON(#"{"type":"call_started","resumed":true}"#)
        await eventually("connected") { app.display == .connected }
    }

    func testWifiToMobileDropsTheOldSocketAtOnce() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await goLive(rig, app)
        app.networkChanged(online: true, interfaceChanged: true)
        await eventually("old socket closed, new one opened") { rig.transport.count == 2 }
        XCTAssertNotEqual(app.display, .connected)
        XCTAssertEqual(app.call.phase, .held)
        let c = rig.transport.conn(1)
        c.pushJSON(welcomeText)
        await eventually("resume") { c.sent("call_start") }
        c.pushJSON(#"{"type":"call_started","resumed":true}"#)
        await eventually("connected") { app.display == .connected }
    }

    func testOfflineShowsOfflineAndComesBack() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await goLive(rig, app)
        app.networkChanged(online: false)
        XCTAssertEqual(app.display, .offline)
        app.networkChanged(online: true)
        XCTAssertNotEqual(app.display, .offline)
    }

    func testAddressSwitchRestartsTheCallOnTheNewSocket() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await goLive(rig, app)
        app.activeAddressEdited()
        await eventually("new socket") { rig.transport.count == 2 }
        XCTAssertNotEqual(app.display, .connected, "the old call died with the old socket")
        let c = rig.transport.conn(1)
        c.pushJSON(welcomeText)
        await eventually("a call is started again on the new address") { c.sent("call_start") }
        c.pushJSON(#"{"type":"call_started"}"#)
        await eventually("connected") { app.display == .connected }
    }
}
