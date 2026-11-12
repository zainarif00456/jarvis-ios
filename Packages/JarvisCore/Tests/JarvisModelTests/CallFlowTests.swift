import XCTest
import JarvisCore
import JarvisNet
@testable import JarvisModel

@MainActor
final class CallFlowTests: XCTestCase {
    func testOpeningTheAppConnectsAndStartsTheCallByItself() async {
        let rig = Rig(); let app = rig.model()
        app.launch()
        XCTAssertEqual(app.phase, .ready)
        await eventually("audio started right away (before the socket is even up)") { rig.audio.starts == 1 }
        await eventually("socket open") { rig.transport.count == 1 }
        XCTAssertTrue(rig.transport.urls[0].absoluteString.hasPrefix("ws://127.0.0.1:9/ws/session"))
        rig.transport.conn(0).pushJSON(welcomeText)
        await eventually("call_start sent silently after welcome") { rig.transport.conn(0).sent("call_start") }
        XCTAssertTrue(rig.transport.conn(0).texts.contains { $0.contains("call_start") && $0.contains("\"manual\":false") })
        XCTAssertEqual(app.link, .online)
        XCTAssertEqual(app.deck.approvals.first?.id, "ap01"); XCTAssertEqual(app.deck.cameras.first?.name, "Door")
        XCTAssertEqual(app.chat.entries.first?.text, "earlier")
        XCTAssertEqual(app.deck.deviceName, "Test iPhone")
        rig.transport.conn(0).pushJSON(#"{"type":"call_started","voice":"x","stt_rate":16000,"tts_rate":24000}"#)
        await eventually("call active") { app.call.isActive }
    }

    func testMicFramesFlowUpOnlyWhileActiveAndNotMuted() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await eventually("conn") { rig.transport.count == 1 }
        let frame = Data(repeating: 1, count: 1280)
        rig.audio.onMicFrame?(frame, 0.01)             // before the call is live: dropped
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.transport.conn(0).binaries.count, 0)
        rig.transport.conn(0).pushJSON(welcomeText); rig.transport.conn(0).pushJSON(#"{"type":"call_started"}"#)
        await eventually("active") { app.call.isActive }
        for _ in 0..<5 { rig.audio.onMicFrame?(frame, 0.01) }
        await eventually("5 frames up") { rig.transport.conn(0).binaries.count == 5 }
        XCTAssertTrue(rig.transport.conn(0).binaries.allSatisfy { $0.count == 1280 })
        app.call.toggleMute()
        XCTAssertTrue(app.call.muted)
        for _ in 0..<5 { rig.audio.onMicFrame?(frame, 0.5) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(rig.transport.conn(0).binaries.count, 5, "muted: nothing leaves the phone")
        XCTAssertEqual(app.call.micLevel, 0)
        app.call.toggleMute()
        rig.audio.onMicFrame?(frame, 0.01)
        await eventually("unmuted frames flow again") { rig.transport.conn(0).binaries.count == 6 }
    }

    func testSpeechPlaysCutsAndDucks() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await eventually("conn") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText); rig.transport.conn(0).pushJSON(#"{"type":"call_started"}"#)
        await eventually("active") { app.call.isActive }
        rig.transport.conn(0).push(.binary(Data(repeating: 7, count: 4800)))
        await eventually("speech reaches the player") { rig.audio.played.count == 4800 }
        // the owner talks over him: loud frames while playing -> duck
        for _ in 0..<6 { rig.audio.onMicFrame?(Data(count: 1280), 0.3) }
        await eventually("ducked") { rig.audio.duckCalls.contains(true) }
        rig.transport.conn(0).pushJSON(#"{"type":"voice_stop"}"#)
        await eventually("voice_stop cuts playback and un-ducks") { rig.audio.cuts >= 1 && rig.audio.duckCalls.contains(false) }
        rig.transport.conn(0).pushJSON(#"{"type":"voice_state","state":"speaking"}"#)
        rig.transport.conn(0).pushJSON(#"{"type":"voice_partial","text":"what is"}"#)
        await eventually("state and caption") { app.call.voiceState == "speaking" && app.call.caption == "what is" }
        XCTAssertEqual(app.chat.caption, "what is", "captions share the chat timeline")
        rig.audio.onPlaybackActive?(false)
        await eventually("playback idle is reported to the server") { rig.transport.conn(0).sent("voice_playback") }
    }

    func testDroppedSocketHoldsTheCallAndResumes() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await eventually("c0") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText); rig.transport.conn(0).pushJSON(#"{"type":"call_started"}"#)
        await eventually("active") { app.call.isActive }
        rig.transport.conn(0).fail()
        await eventually("held") { app.call.phase == .held }
        XCTAssertEqual(rig.audio.stops, 0, "audio stays ready while reconnecting")
        await eventually("second socket") { rig.transport.count == 2 }
        rig.transport.conn(1).pushJSON(welcomeText)
        await eventually("resume call_start") { rig.transport.conn(1).texts.contains { $0.contains("call_start") && $0.contains("\"manual\":false") } }
        rig.transport.conn(1).pushJSON(#"{"type":"call_started","resumed":true}"#)
        await eventually("active again") { app.call.isActive }
        XCTAssertEqual(rig.audio.starts, 1, "the same audio session carried on")
    }

    func testEndCallIsDeliberateAndStaysEnded() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await eventually("c0") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText); rig.transport.conn(0).pushJSON(#"{"type":"call_started"}"#)
        await eventually("active") { app.call.isActive }
        app.call.endCall()
        await eventually("call_end sent") { rig.transport.conn(0).sent("call_end") }
        XCTAssertEqual(rig.audio.stops, 1); XCTAssertEqual(app.call.phase, .idle)
        app.call.startCall()                                // a tap: manual start
        await eventually("manual call_start") { rig.transport.conn(0).texts.contains { $0.contains("call_start") && $0.contains("\"manual\":true") } }
    }

    func testFirstRunMicrophonePromptThenCall() async {
        let rig = Rig(mic: .undetermined, afterPrompt: .granted); let app = rig.model(); app.launch()
        await eventually("prompted once and audio started") { rig.perms.prompts == 1 && rig.audio.starts == 1 }
        XCTAssertNil(app.call.notice)
    }

    func testDeniedMicrophoneShowsGuidanceAndNeverCrashes() async {
        let rig = Rig(mic: .denied); let app = rig.model(); app.launch()
        await eventually("blocked with a notice") { if case .blocked(.micDenied) = app.call.phase { return app.call.notice != nil }; return false }
        XCTAssertEqual(rig.audio.starts, 0)
        XCTAssertTrue(app.call.notice?.contains("Settings") ?? false)
        // chat and the deck still work without the microphone
        await eventually("conn") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText)
        await eventually("online") { app.link == .online }
        // the owner enables it in Settings and returns to the app
        rig.perms.mic = .granted
        app.sceneBecameActive()
        await eventually("call starts after the permission changed while the app was away") { rig.audio.starts == 1 }
    }

    func testAudioEngineFailureIsReportedNotFatal() async {
        let rig = Rig(); rig.audio.failStart = "no input available"
        let app = rig.model(); app.launch()
        await eventually("audio failure notice") { app.call.notice?.contains("no input available") == true }
        if case .blocked(.audioFailed) = app.call.phase {} else { XCTFail("\(app.call.phase)") }
    }

    func testInterruptionsAndRouteChanges() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await eventually("c0") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText); rig.transport.conn(0).pushJSON(#"{"type":"call_started"}"#)
        await eventually("active") { app.call.isActive }
        rig.audio.onEvent?(.interruptionBegan)
        rig.audio.onEvent?(.interruptionEnded(shouldResume: true))
        await eventually("audio restarted after the interruption") { rig.audio.restarts == 1 }
        rig.audio.onEvent?(.routeChanged("AirPods"))
        await eventually("route name shown") { app.call.route == "AirPods" }
        rig.audio.onEvent?(.mediaServicesReset)
        await eventually("restart after media services reset") { rig.audio.restarts == 2 }
        XCTAssertTrue(app.call.isActive, "the call itself carries on")
    }

    func testEngineConfigurationChangesRestartOnceNotInALoop() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await eventually("c0") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText); rig.transport.conn(0).pushJSON(#"{"type":"call_started"}"#)
        await eventually("active") { app.call.isActive }
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        rig.audio.onEvent?(.engineStopped)
        await eventually("one restart") { rig.audio.restarts == 1 }
        rig.audio.onEvent?(.engineStopped); rig.audio.onEvent?(.engineStopped)   // the echo of our own restart
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rig.audio.restarts, 1)
    }

    func testNotPairedShowsPairingAndStartsNothing() async {
        let rig = Rig(paired: false); let app = rig.model(); app.launch()
        XCTAssertEqual(app.phase, .needsPairing)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.transport.count, 0); XCTAssertEqual(rig.audio.starts, 0)
    }

    func testForgetDeviceWipesTokenAndStopsEverything() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        await eventually("c0") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText); rig.transport.conn(0).pushJSON(#"{"type":"call_started"}"#)
        await eventually("active") { app.call.isActive }
        app.forgetDevice()
        XCTAssertNil(rig.secrets.read("device-token")); XCTAssertEqual(app.phase, .needsPairing)
        await eventually("audio stopped") { rig.audio.stops >= 1 }
        await eventually("socket closed normally") { rig.transport.conn(0).closedNormal == true }
    }

    func testChatSendAndStream() async {
        let rig = Rig(autoStart: false); let app = rig.model(); app.launch()
        await eventually("c0") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText)
        await eventually("online") { app.link == .online }
        app.chat.draft = "  what's up  "
        XCTAssertTrue(app.chat.submit())
        await eventually("sent") { rig.transport.conn(0).texts.contains { $0.contains("user_message") && $0.contains("what's up") } }
        XCTAssertEqual(app.chat.entries.last?.text, "what's up"); XCTAssertEqual(app.chat.draft, "")
        rig.transport.conn(0).pushJSON(#"{"type":"turn_started","turn_id":"t1","kind":"message"}"#)
        rig.transport.conn(0).pushJSON(#"{"type":"text_delta","turn_id":"t1","text":"All "}"#)
        rig.transport.conn(0).pushJSON(#"{"type":"text_delta","turn_id":"t1","text":"good."}"#)
        await eventually("streaming text") { app.chat.entries.last?.text == "All good." && app.chat.entries.last?.streaming == true }
        rig.transport.conn(0).pushJSON(#"{"type":"turn_done","turn_id":"t1","text":"All good.","tools_used":[]}"#)
        await eventually("done") { app.chat.entries.last?.streaming == false && !app.chat.busy }
        app.chat.draft = "/status"; XCTAssertTrue(app.chat.submit())
        XCTAssertFalse(app.chat.entries.contains { $0.kind == .user && $0.text == "/status" }, "slash commands show their result, not an echo")
        rig.transport.conn(0).pushJSON(#"{"type":"approval_request","approval":{"id":"ap02","tool":"x","what":"rm"}}"#)
        await eventually("approval card") { app.deck.approvals.count == 2 }
        app.chat.approve("ap02", true)
        await eventually("approval sent") { rig.transport.conn(0).texts.contains { $0.contains("\"approval\"") && $0.contains("ap02") && $0.contains("true") } }
        rig.transport.conn(0).pushJSON(#"{"type":"approval_resolved","id":"ap02","status":"approved"}"#)
        await eventually("approval cleared") { app.deck.approvals.count == 1 }
    }

    func testChatRefusesWhenOffline() async {
        let rig = Rig(autoStart: false); let app = rig.model(); app.launch()
        app.chat.draft = "hello"
        XCTAssertFalse(app.chat.submit(), "not online yet: the text is kept")
        XCTAssertEqual(app.chat.draft, "hello"); XCTAssertNotNil(app.chat.error)
    }

    func testDeckReactsToLiveMessages() async {
        let rig = Rig(autoStart: false); let app = rig.model(); app.launch()
        await eventually("c0") { rig.transport.count == 1 }
        let c = rig.transport.conn(0)
        c.pushJSON(welcomeText)
        c.pushJSON(#"{"type":"task_update","task":{"id":"t1","owner":"friday","name":"Friday","title":"Fix","status":"running","progress":0.2}}"#)
        c.pushJSON(#"{"type":"file_added","file":{"id":"f1","name":"r.pdf","mime":"application/pdf","size":10,"owner":"friday"}}"#)
        c.pushJSON(#"{"type":"terminal_opened","terminal":{"id":"ab12","title":"zsh","by":"friday"}}"#)
        c.pushJSON(#"{"type":"camera_status","id":"c1","state":"live","detail":"","viewers":2}"#)
        c.pushJSON(#"{"type":"recording_update","recordings":[{"id":"r1","name":"Screen","kind":"screen","state":"recording"}]}"#)
        c.pushJSON(#"{"type":"some_future_message","x":1}"#)
        await eventually("deck updated") { app.deck.runningCount == 1 && app.deck.files.count == 1 && app.deck.terminals.count == 1 && app.deck.recordings.count == 1 }
        XCTAssertEqual(app.deck.cameras.first?.state, "live"); XCTAssertEqual(app.deck.unseenFiles, 1)
        XCTAssertEqual(app.deck.focusedTerminal, "ab12")
        c.pushJSON(#"{"type":"task_update","task":{"id":"t1","owner":"friday","name":"Friday","title":"Fix","status":"done"}}"#)
        await eventually("task finished") { app.deck.runningCount == 0 && app.deck.toast != nil }
        c.pushJSON(#"{"type":"terminal_closed","id":"ab12"}"#); c.pushJSON(#"{"type":"file_removed","ids":["f1"]}"#)
        await eventually("closed and removed") { app.deck.terminals.isEmpty && app.deck.files.isEmpty }
    }

    func testPresenceFollowsTheScene() async {
        let rig = Rig(autoStart: false); let app = rig.model(); app.launch()
        await eventually("c0") { rig.transport.count == 1 }
        rig.transport.conn(0).pushJSON(welcomeText)
        await eventually("online") { app.link == .online }
        app.sceneBecameInactive(background: true)
        await eventually("presence hidden") { rig.transport.conn(0).texts.contains { $0.contains("\"presence\"") && $0.contains("\"visible\":false") } }
        app.sceneBecameActive()
        await eventually("presence visible") { rig.transport.conn(0).texts.filter { $0.contains("\"presence\"") && $0.contains("\"visible\":true") }.count >= 1 }
    }
}

@MainActor
final class UploadModelTests: XCTestCase {
    func testRejectsEmptyHugeAndMissingFilesBeforeUploading() throws {
        let m = UploadModel(); m.maxFileBytes = 100
        let dir = FileManager.default.temporaryDirectory
        let empty = dir.appendingPathComponent("e-\(UUID().uuidString)"); try Data().write(to: empty)
        let big = dir.appendingPathComponent("b-\(UUID().uuidString)"); try Data(count: 500).write(to: big)
        defer { try? FileManager.default.removeItem(at: empty); try? FileManager.default.removeItem(at: big) }
        XCTAssertNotNil(m.enqueue(fileURL: empty, name: "e", mime: "text/plain", destination: .files))
        XCTAssertTrue(m.enqueue(fileURL: big, name: "b", mime: "text/plain", destination: .files)?.contains("limit") ?? false)
        XCTAssertNotNil(m.enqueue(fileURL: dir.appendingPathComponent("nope-\(UUID())"), name: "n", mime: "x/y", destination: .files))
        XCTAssertTrue(m.items.isEmpty)
    }
    func testNotConnectedFailsCleanly() async throws {
        let m = UploadModel()
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString)"); try Data(count: 10).write(to: f)
        XCTAssertNil(m.enqueue(fileURL: f, name: "u.bin", mime: "application/octet-stream", destination: .files))
        await eventually("failed with a reason") { if case .failed = m.items.first?.state { return true }; return false }
        try? FileManager.default.removeItem(at: f)
    }
}
