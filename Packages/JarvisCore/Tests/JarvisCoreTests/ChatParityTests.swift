import XCTest
@testable import JarvisCore

final class ChatParityTests: XCTestCase {
    func apply(_ r: inout TimelineReducer, _ json: String) { r.apply(ServerMessageDecoder.decode(json)!) }

    func testTypedMessageAppearsOnceEvenIfTheServerEchoesIt() {
        var r = TimelineReducer()
        r.addLocalUser("hello there")
        apply(&r, #"{"type":"user_message","text":"hello there","device":"iPhone"}"#)
        XCTAssertEqual(r.entries.filter { $0.kind == .user }.count, 1)
        apply(&r, #"{"type":"user_message","text":"from the laptop","device":"Mac"}"#)
        XCTAssertEqual(r.entries.filter { $0.kind == .user }.count, 2, "another screen's message still shows")
    }

    func testTypedReplyStreamsIn() {
        var r = TimelineReducer()
        apply(&r, #"{"type":"turn_started","turn_id":"t1","kind":"message","agent":"jarvis"}"#)
        apply(&r, #"{"type":"text_delta","turn_id":"t1","text":"Hel"}"#)
        apply(&r, #"{"type":"text_delta","turn_id":"t1","text":"lo"}"#)
        XCTAssertEqual(r.entries.last?.text, "Hello"); XCTAssertTrue(r.entries.last?.streaming ?? false)
        apply(&r, #"{"type":"turn_done","turn_id":"t1","text":"Hello!","model":"m","steps":1,"cost_usd":0.01,"tools_used":[]}"#)
        XCTAssertEqual(r.entries.last?.text, "Hello!"); XCTAssertFalse(r.entries.last?.streaming ?? true)
    }

    func testToolChipsGoFromWaitingToDone() {
        var r = TimelineReducer()
        apply(&r, #"{"type":"turn_started","turn_id":"t1","kind":"message"}"#)
        apply(&r, #"{"type":"tool_started","turn_id":"t1","call_id":"k1","name":"shell_run","args":{"command":"ls -la"}}"#)
        XCTAssertEqual(r.entries.last?.toolChips.first?.label, "→ shell.run ls -la"); XCTAssertEqual(r.entries.last?.toolChips.first?.state, .running)
        apply(&r, #"{"type":"tool_finished","turn_id":"t1","call_id":"k1","name":"shell_run","ok":true,"status":"done"}"#)
        XCTAssertEqual(r.entries.last?.toolChips.first?.label, "✓ shell.run · done"); XCTAssertEqual(r.entries.last?.toolChips.first?.state, .ok)
        apply(&r, #"{"type":"tool_started","turn_id":"t1","call_id":"k2","name":"files_read","args":{"path":"/a"}}"#)
        apply(&r, #"{"type":"tool_finished","turn_id":"t1","call_id":"k2","name":"files_read","ok":false,"status":"error"}"#)
        XCTAssertEqual(r.entries.last?.toolChips.last?.state, .failed)
    }

    func testVoiceReplyIsShownSentenceBySentenceAsItIsSpoken() {
        var r = TimelineReducer()
        apply(&r, #"{"type":"turn_started","turn_id":"v1","kind":"message","voice":true}"#)
        apply(&r, #"{"type":"text_delta","turn_id":"v1","text":"First one. Second one."}"#)
        XCTAssertEqual(r.entries.last?.text, "", "the text never runs ahead of the voice")
        apply(&r, #"{"type":"tts_start","turn_id":"v1","text":"First one.","display":"First one."}"#)
        XCTAssertEqual(r.entries.last?.text, "First one.")
        apply(&r, #"{"type":"turn_done","turn_id":"v1","text":"First one. Second one.","model":"m","steps":1,"tools_used":[]}"#)
        XCTAssertEqual(r.entries.last?.text, "First one.", "still being spoken")
        apply(&r, #"{"type":"tts_start","turn_id":"v1","text":"Second one.","display":"Second one."}"#)
        XCTAssertEqual(r.entries.last?.text, "First one. Second one.")
        apply(&r, #"{"type":"tts_end","turn_id":"v1"}"#)
        XCTAssertEqual(r.entries.last?.text, "First one. Second one."); XCTAssertFalse(r.entries.last?.revealing ?? true)
    }

    func testVoiceReplyThatNeverGetsSpeechIsShownWhole() {
        var r = TimelineReducer()
        apply(&r, #"{"type":"turn_started","turn_id":"v1","kind":"message","voice":true}"#)
        apply(&r, #"{"type":"turn_done","turn_id":"v1","text":"All of it.","model":"m","steps":1,"tools_used":[]}"#)
        XCTAssertEqual(r.entries.last?.text, "All of it.")
    }

    func testExecRowsInTheTimeline() {
        var r = TimelineReducer()
        apply(&r, #"{"type":"exec_start","id":"e1","who":"friday","kind":"shell","title":"pytest -q"}"#)
        XCTAssertEqual(r.entries.last?.kind, .exec); XCTAssertEqual(r.entries.last?.status, "running"); XCTAssertEqual(r.entries.last?.name, "Friday")
        apply(&r, #"{"type":"exec_end","id":"e1","ok":false,"ms":900,"result":{"type":"terminal","command":"pytest -q","stdout":"1 failed","exit":1}}"#)
        XCTAssertEqual(r.entries.last?.status, "failed"); XCTAssertEqual(r.entries.last?.detail, "pytest -q exited 1"); XCTAssertEqual(r.entries.last?.execMs, 900)
        apply(&r, #"{"type":"exec_start","id":"e1","who":"friday","kind":"shell","title":"again"}"#)
        XCTAssertEqual(r.entries.filter { $0.kind == .exec }.count, 1, "no duplicate rows")
    }

    func testSlashCommandIsOneCard() {
        var r = TimelineReducer()
        apply(&r, #"{"type":"command_result","line":"/status","ok":true,"text":"all fine"}"#)
        XCTAssertEqual(r.entries.count, 1); XCTAssertEqual(r.entries[0].kind, .command); XCTAssertEqual(r.entries[0].detail, "all fine")
    }
}
