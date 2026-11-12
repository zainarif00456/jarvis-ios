import XCTest
import JarvisCore
import JarvisNet
@testable import JarvisModel

@MainActor
final class ExecModelTests: XCTestCase {
    func terminal(_ out: String = "ok") -> ExecResult { .terminal(cwd: "/x", command: "ls", stdout: out, stderr: "", exit: 0, note: nil, entries: []) }

    func testACardFormsRunsAndMeltsBack() async {
        let m = ExecModel(); m.lingerScale = 0.02
        m.start(ExecStart(id: "a", who: "jarvis", kind: "shell", title: "ls"))
        XCTAssertEqual(m.cards.map { $0.id }, ["a"]); XCTAssertEqual(m.cards[0].state, .running); XCTAssertEqual(m.running.count, 1)
        m.end(ExecEnd(id: "a", ok: true, ms: 12, result: terminal()))
        XCTAssertEqual(m.cards[0].state, .ok); XCTAssertEqual(m.cards[0].ms, 12)
        await eventually("melts back into the core") { m.cards.isEmpty }
        XCTAssertEqual(m.chips.map { $0.id }, ["a"], "it leaves a chip")
        XCTAssertTrue(m.running.isEmpty)
    }

    func testOnePhoneCardInFrontOlderBecomeChipsAndRestore() {
        let m = ExecModel()
        m.start(ExecStart(id: "a", title: "one")); m.start(ExecStart(id: "b", title: "two"))
        XCTAssertEqual(m.cards.map { $0.id }, ["b"]); XCTAssertEqual(m.chips.map { $0.id }, ["a"])
        m.end(ExecEnd(id: "a", ok: false, result: terminal("boom")))
        XCTAssertEqual(m.chips[0].state, .failed, "a card that ended behind keeps its result")
        m.restore("a")
        XCTAssertEqual(m.cards.map { $0.id }, ["a"]); XCTAssertEqual(m.chips.map { $0.id }, ["b"])
    }

    func testPinAndHoldKeepACard() async {
        let m = ExecModel(); m.lingerScale = 0.02
        m.start(ExecStart(id: "a", title: "x")); m.pin("a")
        m.end(ExecEnd(id: "a", result: terminal()))
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(m.cards.count, 1, "pinned stays")
        m.pin("a")
        await eventually("unpinned melts") { m.cards.isEmpty }
        m.start(ExecStart(id: "b", title: "y")); m.hold("b", true); m.end(ExecEnd(id: "b", result: terminal()))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(m.cards.count, 1, "held by a finger")
        m.hold("b", false)
        await eventually("released melts") { m.cards.isEmpty }
    }

    func testLevels() {
        let m = ExecModel()
        m.level = .minimal
        m.start(ExecStart(id: "a", title: "reading x")); XCTAssertEqual(m.ticker, "reading x"); XCTAssertTrue(m.cards.isEmpty)
        m.end(ExecEnd(id: "a", result: terminal())); XCTAssertEqual(m.ticker, "ran ls")
        m.level = .off
        m.start(ExecStart(id: "b", title: "z")); XCTAssertTrue(m.cards.isEmpty); XCTAssertNil(m.ticker)
        m.level = .full
        m.start(ExecStart(id: "c", title: "w")); XCTAssertEqual(m.cards.count, 1)
        m.level = .off; XCTAssertTrue(m.cards.isEmpty && m.chips.isEmpty, "switching off clears the screen")
    }

    func testSummaryHookAndHandleActions() {
        let m = ExecModel()
        var seen: [(Int, String?)] = []
        m.onSummary = { n, t, _ in seen.append((n, t)) }
        var sent: [ClientMessage] = []
        m.sendMessage = { sent.append($0); return true }
        m.start(ExecStart(id: "a", title: "build"))
        m.end(ExecEnd(id: "a", result: terminal()))
        XCTAssertEqual(seen.first?.0, 1); XCTAssertEqual(seen.last?.0, 0)
        XCTAssertTrue(m.act(handle: "0123456789abcdef0123", action: "browse"))
        XCTAssertEqual(sent, [.execAction(handle: "0123456789abcdef0123", action: "browse", req: "0123456789ab")])
    }
}

@MainActor
final class DebriefModelTests: XCTestCase {
    func block(_ id: String, links: [(String, String)] = []) -> ReportBlock {
        let l = links.map { #"{"to":"\#($0.0)","label":"\#($0.1)"}"# }.joined(separator: ",")
        return Report.parseBlock(JSONValue.parse(#"{"id":"\#(id)","type":"story","heading":"H \#(id)","links":[\#(l)]}"#)!)!
    }
    func model(kind: String = "debrief") -> DebriefModel {
        let m = DebriefModel()
        let blocks = [block("a", links: [("b", "blocks")]), block("b"), block("c")]
        m.loader = { id in Report(info: ReportInfo(id: id, title: "T", kind: kind, agent: "friday"), title: "T", blocks: blocks) }
        m.lingerScale = 0.02
        return m
    }

    func testWalkGhostsTheToldCardAndLinks() async throws {
        let m = model()
        try await m.open("r1")
        try m.focus("a")
        XCTAssertEqual(m.cards.map { $0.id }, ["a"]); XCTAssertEqual(m.cards[0].side, .right); XCTAssertFalse(m.cards[0].ghost)
        try m.focus("b")
        XCTAssertEqual(m.cards.map { $0.id }, ["a", "b"]); XCTAssertTrue(m.cards[0].ghost, "the one just told fades to a ghost"); XCTAssertFalse(m.cards[1].ghost)
        XCTAssertEqual(m.cards[1].side, .left, "sides alternate")
        XCTAssertEqual(m.link, DebriefModel.Link(from: "a", to: "b", label: "blocks"), "linked cards are joined by a light line")
        try m.focus("c")
        XCTAssertEqual(m.cards.map { $0.id }, ["b", "c"], "the one before the ghost dissolves"); XCTAssertNil(m.link)
        XCTAssertEqual(m.told, ["a", "b", "c"])
        m.bringBack("b")
        XCTAssertEqual(m.current?.id, "b")
    }

    func testUnknownSceneAndNoReportAreSpokenErrors() async throws {
        let m = model()
        XCTAssertThrowsError(try m.focus("a")) { XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "no report is open") }
        try await m.open("r1")
        XCTAssertThrowsError(try m.focus("zzz")) { XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "there is no scene zzz") }
    }

    func testItemsDiagramAndStep() async throws {
        let m = model(); try await m.open("r1")
        try m.item("b", part: "messages", item: 1)
        XCTAssertEqual(m.current?.id, "b", "a cue for another scene opens it first"); XCTAssertEqual(m.current?.litItem, 1)
        try m.diagram("b", focus: ["X"], flow: ["X", "Y"], overview: false)
        XCTAssertEqual(m.current?.focusNodes, ["X"]); XCTAssertEqual(m.current?.flow, ["X", "Y"])
        try m.diagram(nil, focus: [], flow: [], overview: true)
        XCTAssertTrue(m.current?.focusNodes.isEmpty ?? false)
        try m.step(by: 1); XCTAssertEqual(m.current?.id, "c")
        try m.step(by: 5); XCTAssertEqual(m.current?.id, "c", "clamped at the end")
        XCTAssertEqual(m.state()?.blocks.count, 3); XCTAssertEqual(m.state()?.focused, "c"); XCTAssertEqual(m.state()?.kind, "debrief")
    }

    func testLingerClosesAndTheOwnerSpeakingKeepsIt() async throws {
        let m = model(); try await m.open("r1"); try m.focus("a")
        m.lingerThenClose(seconds: 6)
        XCTAssertTrue(m.lingering)
        m.keepAll()
        XCTAssertFalse(m.lingering)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(m.isOpen, "the owner spoke: nothing closes under them")
        m.lingerThenClose(seconds: 6)
        await eventually("melts back into the core") { !m.isOpen }
        XCTAssertTrue(m.cards.isEmpty)
    }
}

@MainActor
final class ScreenFlowTests: XCTestCase {
    func ready(_ rig: Rig, _ app: AppModel) async -> FakeConnection {
        await eventually("conn") { rig.transport.count == 1 }
        let c = rig.transport.conn(0)
        c.pushJSON(welcomeText)
        await eventually("welcome") { app.link == .online }
        return c
    }
    func cmd(_ id: String, _ action: String, target: String? = nil, args: String = "{}") -> String {
        #"{"type":"screen_cmd","cmd_id":"\#(id)","action":"\#(action)","target":\#(target.map { "\"\($0)\"" } ?? "null"),"args":\#(args)}"#
    }
    func acks(_ c: FakeConnection) -> [JSONValue] { c.texts.compactMap { JSONValue.parse($0) }.filter { $0["type"]?.string == "screen_ack" } }

    func testThePhoneReportsItsScreenAfterWelcome() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        let c = await ready(rig, app)
        await eventually("screen_state sent") { c.sent("screen_state") }
        let j = c.texts.compactMap { JSONValue.parse($0) }.first { $0["type"]?.string == "screen_state" }
        XCTAssertEqual(j?["compact"]?.bool, true); XCTAssertEqual(j?["windows"]?.array?.count, 0)
    }

    func testSwitchOffMeansNoScreenAndNoControl() async {
        let rig = Rig(); let app = rig.model()
        app.settings.sendScreenState = false; app.settingsChanged()
        app.launch()
        let c = await ready(rig, app)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(c.sent("screen_state"), "the switch is off: Jarvis never sees this phone as a screen")
        c.pushJSON(cmd("abcd", "open", args: #"{"what":"cameras"}"#))
        await eventually("ack") { !self.acks(c).isEmpty }
        XCTAssertEqual(acks(c)[0]["ok"]?.bool, false)
        XCTAssertTrue(app.portals.isEmpty)
        app.settings.sendScreenState = true; app.settingsChanged()
        await eventually("turning it on reports at once") { c.sent("screen_state") }
    }

    func testOpenFocusArrangeCloseAndHonestErrors() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        let c = await ready(rig, app)
        c.pushJSON(cmd("c001", "open", args: #"{"what":"cameras"}"#))
        c.pushJSON(cmd("c002", "open", args: #"{"what":"schedule"}"#))
        await eventually("two portals") { app.portals.portals.count == 2 }
        c.pushJSON(cmd("c003", "arrange", args: #"{"layout":"grid"}"#))
        c.pushJSON(cmd("c004", "close", target: "cameras"))
        c.pushJSON(cmd("c005", "close", target: "nothing-here"))
        c.pushJSON(cmd("c006", "open", args: #"{"what":"hologram"}"#))
        c.pushJSON(cmd("c007", "teleport"))
        await eventually("seven acks") { self.acks(c).count == 7 }
        let a = Dictionary(uniqueKeysWithValues: acks(c).map { ($0["cmd_id"]!.string!, $0) })
        XCTAssertEqual(a["c001"]?["ok"]?.bool, true); XCTAssertEqual(a["c004"]?["ok"]?.bool, true)
        XCTAssertEqual(a["c005"]?["ok"]?.bool, false); XCTAssertEqual(a["c005"]?["error"]?.string, "nothing called nothing-here is open")
        XCTAssertEqual(a["c006"]?["error"]?.string, "cannot open hologram on the phone")
        XCTAssertEqual(a["c007"]?["error"]?.string, "unknown screen action teleport")
        XCTAssertEqual(app.portals.portals.map { $0.kind }, [.schedule])
        XCTAssertNotNil(a["c004"]?["state"]?["windows"], "an ack carries the screen afterwards")
    }

    func testADebriefOnThePhoneFromOpenToLinger() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        app.debrief.loader = { id in
            let b = { (i: String) in Report.parseBlock(JSONValue.parse(#"{"id":"\#(i)","type":"messages","heading":"H","messages":[{"who":"A","text":"hi"}]}"#)!)! }
            return Report(info: ReportInfo(id: id, title: "Awais", kind: "debrief", agent: "friday"), title: "Awais", blocks: [b("one"), b("two")])
        }
        app.debrief.lingerScale = 0.02
        let c = await ready(rig, app)
        c.pushJSON(cmd("d001", "report_open", args: #"{"id":"rep1","full":true,"briefing":true}"#))
        await eventually("debrief open") { app.debrief.isOpen }
        c.pushJSON(cmd("d002", "report_focus", args: #"{"id":"rep1","section":"one"}"#))
        c.pushJSON(cmd("d003", "report_item", args: #"{"id":"rep1","section":"one","part":"messages","item":0}"#))
        c.pushJSON(cmd("d004", "report_focus", args: #"{"id":"rep1","section":"two"}"#))
        c.pushJSON(cmd("d005", "report_zoom", args: #"{"id":"rep1","section":"two","label":"x"}"#))
        await eventually("acks") { self.acks(c).count == 5 }
        XCTAssertTrue(acks(c).allSatisfy { $0["ok"]?.bool == true }, "every cue is answered ok so the briefing carries on")
        XCTAssertEqual(app.debrief.cards.map { $0.id }, ["one", "two"]); XCTAssertTrue(app.debrief.cards[0].ghost)
        let last = acks(c).last!
        let win = last["state"]?["windows"]?.array?.first { $0["kind"]?.string == "debrief" }
        XCTAssertEqual(win?["report"]?["focused"]?.string, "two"); XCTAssertEqual(win?["id"]?.string, "report-rep1")
        c.pushJSON(#"{"type":"voice_state","state":"listening"}"#)
        c.pushJSON(cmd("d006", "report_linger", args: #"{"id":"rep1","seconds":8}"#))
        await eventually("linger acked") { self.acks(c).count == 6 }
        c.pushJSON(#"{"type":"voice_state","state":"listening"}"#)       // the owner speaks again before it closes
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(app.debrief.isOpen)
        c.pushJSON(cmd("d007", "report_linger", args: #"{"id":"rep1","seconds":8}"#))
        await eventually("melts back") { !app.debrief.isOpen }
    }

    func testBriefingRequestAndExecThroughTheSocket() async {
        let rig = Rig(); let app = rig.model(); app.launch()
        let c = await ready(rig, app)
        c.pushJSON(#"{"type":"briefing_request","runs":[{"id":"r1","title":"Awais","priority":"critical","preview":"p","failed":false}]}"#)
        await eventually("asked") { app.briefing.asked.count == 1 }
        XCTAssertEqual(app.briefing.priority, "critical")
        app.briefing.accept()
        await eventually("accepted") { c.sent("briefing_accept") }
        c.pushJSON(#"{"type":"briefing_cleared","ids":["r1"]}"#)
        await eventually("cleared") { app.briefing.asked.isEmpty }
        c.pushJSON(#"{"type":"exec_start","id":"e1","who":"jarvis","kind":"shell","title":"ls"}"#)
        c.pushJSON(#"{"type":"exec_end","id":"e1","ok":true,"ms":5,"result":{"type":"terminal","command":"ls","stdout":"x","exit":0}}"#)
        await eventually("card") { app.exec.cards.first?.state == .ok }
        XCTAssertEqual(app.chat.entries.last?.kind, .exec, "the chat timeline gets the same work as a row")
        XCTAssertEqual(app.chat.entries.last?.detail, "ran ls")
    }
}
