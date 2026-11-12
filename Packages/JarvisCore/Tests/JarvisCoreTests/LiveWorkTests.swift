import XCTest
@testable import JarvisCore

final class LiveWorkTests: XCTestCase {
    func decode(_ s: String) -> ServerMessage { ServerMessageDecoder.decode(s)! }

    func testExecStartAndEndDecode() {
        guard case .execStart(let s) = decode(#"{"type":"exec_start","id":"c1","who":"friday","kind":"shell","title":"ls -la","detail":{"wide":true},"parent":null}"#) else { return XCTFail() }
        XCTAssertEqual(s.id, "c1"); XCTAssertEqual(s.who, "friday"); XCTAssertEqual(s.kind, "shell"); XCTAssertTrue(s.wide); XCTAssertNil(s.parent)
        let end = decode(#"{"type":"exec_end","id":"c1","ok":true,"ms":412,"result":{"type":"terminal","cwd":"/home/x/proj","command":"ls","stdout":"a\nb\n","stderr":"","exit":0,"entries":{"type":"entries","items":[{"name":"a.py","kind":"code","size":10,"h":"abc"}]}}}"#)
        guard case .execEnd(let e) = end, case .terminal(let cwd, let cmd, let out, _, let exit, _, let ents) = e.result else { return XCTFail() }
        XCTAssertEqual(cwd, "/home/x/proj"); XCTAssertEqual(cmd, "ls"); XCTAssertEqual(out, "a\nb\n"); XCTAssertEqual(exit, 0); XCTAssertEqual(ents.first?.name, "a.py")
        XCTAssertEqual(e.ms, 412)
    }

    func testResultTypes() {
        func result(_ json: String) -> ExecResult { ExecResult.parse(JSONValue.parse(json)) }
        if case .lines(let p, let start, let text, _) = result(#"{"type":"lines","path":"/a/b.py","start":10,"text":"x\ny"}"#) { XCTAssertEqual(p, "/a/b.py"); XCTAssertEqual(start, 10); XCTAssertEqual(text, "x\ny") } else { XCTFail() }
        if case .diff(_, let h, _) = result(#"{"type":"diff","path":"/a","hunks":[{"del":["old"],"add":["new","new2"]}]}"#) { XCTAssertEqual(h.first?.add.count, 2) } else { XCTFail() }
        if case .hits(let i, _) = result(#"{"type":"hits","items":[{"path":"/a","line":3,"text":"foo"}]}"#) { XCTAssertEqual(i.first?.line, 3) } else { XCTFail() }
        if case .entries(_, let items, _) = result(#"{"type":"tree","base":"/b","nodes":[{"name":"d","kind":"dir","children":[{"name":"f","kind":"file"}]}]}"#) { XCTAssertEqual(items.map { $0.depth }, [0, 1]) } else { XCTFail() }
        if case .data(let st, let rows) = result(#"{"type":"data","data":{"status":"ok","total_count":3,"nested":{"a_b":true},"tags":["x","y"],"empty":""}}"#) {
            XCTAssertEqual(st, "ok")
            XCTAssertTrue(rows.contains(ExecRow(depth: 0, key: "Total count", value: "3")))
            XCTAssertTrue(rows.contains(ExecRow(depth: 1, key: "A b", value: "yes")))
            XCTAssertTrue(rows.contains { $0.key == "Tags" && $0.value == "x, y" })
            XCTAssertFalse(rows.contains { $0.key == "Empty" })
        } else { XCTFail() }
        if case .text(_, let t) = result(#"{"type":"something_new","text":"hi"}"#) { XCTAssertEqual(t, "hi") } else { XCTFail("unknown types fall back to text") }
        if case .text = ExecResult.parse(nil) {} else { XCTFail() }
    }

    func testScreenCommandAndBriefingDecode() {
        guard case .screenCmd(let c) = decode(#"{"type":"screen_cmd","cmd_id":"abcd","action":"open","target":null,"args":{"what":"cameras"}}"#) else { return XCTFail() }
        XCTAssertEqual(c.cmdId, "abcd"); XCTAssertEqual(c.action, "open"); XCTAssertEqual(c.arg("what")?.string, "cameras")
        guard case .briefingRequest(let runs) = decode(#"{"type":"briefing_request","runs":[{"id":"r1","title":"Awais","priority":"high","preview":"x","failed":false}]}"#) else { return XCTFail() }
        XCTAssertEqual(runs.first?.priority, "high")
        guard case .toolFinished(_, let call, let name, let ok, let status) = decode(#"{"type":"tool_finished","turn_id":"t","call_id":"k","name":"shell_run","ok":false,"status":"error"}"#) else { return XCTFail() }
        XCTAssertEqual(call, "k"); XCTAssertEqual(name, "shell_run"); XCTAssertFalse(ok); XCTAssertEqual(status, "error")
    }

    func testScreenStateWireShape() throws {
        let win = ScreenWindowState(id: "report-r1", kind: "debrief", title: "DEBRIEF · x", itemType: "report", itemId: "r1", itemName: "x", active: true, rect: [0, 0, 390, 700],
                                    report: ScreenReportState(id: "r1", title: "x", kind: "debrief", mode: "focus", focused: "a", lingering: false, blocks: [ScreenReportBlockState(id: "a", n: 1, heading: "H", type: "story")]))
        let snap = ScreenSnapshot(windows: [win], viewport: [390, 700], compact: true, mode: "stage", layout: "orbit", pinned: [])
        let j = JSONValue.parse(ClientMessage.screenState(snap).json())!
        // top level: only fields the server's `ScreenState` (extra="forbid") knows
        let allowed: Set<String> = ["type", "windows", "viewport", "compact", "mode", "layout", "pinned", "pointing"]
        XCTAssertTrue(Set(j.object!.keys).isSubset(of: allowed), "unexpected top-level keys: \(j.object!.keys)")
        XCTAssertEqual(j["type"]?.string, "screen_state")
        XCTAssertEqual(j["windows"]?[0]?["report"]?["blocks"]?[0]?["n"]?.int, 1)
        XCTAssertEqual(j["windows"]?[0]?["rect"]?.array?.count, 4)
        let ack = JSONValue.parse(ClientMessage.screenAck(cmdId: "abcd", ok: false, error: "no", detail: "", state: snap).json())!
        XCTAssertEqual(ack["type"]?.string, "screen_ack"); XCTAssertEqual(ack["ok"]?.bool, false); XCTAssertNotNil(ack["state"]?["windows"])
        XCTAssertEqual(JSONValue.parse(ClientMessage.briefingAccept(textOnly: true).json())?["text_only"]?.bool, true)
        XCTAssertEqual(JSONValue.parse(ClientMessage.execAction(handle: "0123456789abcdef0123", action: "open", req: "x").json())?["action"]?.string, "open")
    }

    func testPortalLayouts() {
        let area = PRect(x: 12, y: 12, w: 366, h: 600)
        XCTAssertEqual(PortalLayout.rects("grid", count: 4, area: area).count, 4)
        let g = PortalLayout.rects("grid", count: 2, area: area)
        XCTAssertLessThan(g[0].x + g[0].w, g[1].x + 1)
        XCTAssertEqual(PortalLayout.rects("orbit", count: 0, area: area).count, 0)
        let wide = PRect(x: 0, y: 0, w: 1400, h: 900)
        let o = PortalLayout.rects("orbit", count: 3, area: wide, core: (700, 300, 150))
        XCTAssertLessThan(o[0].x + o[0].w, 700 - 150, "first panel left of the core")
        XCTAssertGreaterThan(o[1].x, 700 + 150, "second right of it")
        let ring = PortalLayout.ring(count: 4, around: (0, 0), radius: 100)
        XCTAssertEqual(ring.count, 4); XCTAssertEqual(ring[0].y, -100, accuracy: 0.001)
    }
}
