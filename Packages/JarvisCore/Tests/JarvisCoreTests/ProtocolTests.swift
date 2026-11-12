import XCTest
@testable import JarvisCore

final class ProtocolTests: XCTestCase {
    func decode(_ s: String) -> ServerMessage? { ServerMessageDecoder.decode(s) }

    func testWelcomeDecodesAndToleratesJunk() {
        let json = """
        {"v":1,"type":"welcome","ts":"2026-11-12T15:00:00.000Z","device":"Test iPhone","server":{"version":"1.2.3","redis":true,"uptime_s":5},
         "status":{"spent_usd":0.0123,"budget_usd":5,"queued":0,"busy":false},
         "tasks":[{"id":"t1","owner":"friday","name":"Friday","title":"Fix bug","status":"running","progress":0.4,"elapsed_s":3.2,"started_at":"x","finished_at":null,"summary":null,"error":null,"kind":"worker"},{"nonsense":true}],
         "approvals":[{"id":"a1b2","tool":"shell.run","tier":3,"what":"rm -rf /tmp/x","reasons":["destructive"],"expires_at":"2026-11-12T15:10:00Z"}],
         "files":[{"id":"f1","name":"r.pdf","mime":"application/pdf","size":1234,"owner":"jarvis","kind":"output","created_at":"2026-11-12T14:00:00Z","description":null,"sha256":"abc","task_id":null}],
         "cameras":[{"id":"c1","name":"Door","state":"idle","has_video":true,"future_field":[1,2]}],
         "terminals":[{"id":"ab12","title":"zsh","cwd":"/home","closed":false,"busy":false,"cols":80,"rows":24}],
         "history":[{"id":"e1","seq":1,"ts":"2026-11-12T14:59:00Z","kind":"message","role":"user","name":"You","text":"hi"},{"id":7,"kind":"message","role":"assistant","text":"hello","agent":"jarvis","name":"Jarvis","tools":["a"]}],
         "agents":{"enabled":true,"active":"jarvis","agents":[{"key":"friday","name":"Friday","available":true}]},
         "schedules":{"items":[{"id":"s1","title":"Backup","status":"active","next_text":"in 2h","trigger_text":"daily at 9"}],"scheduler":{"ok":true,"age_s":3,"tz":"Asia/Karachi"},"waiting":[]},
         "session":{"number":4,"since_seq":100},"busy":true}
        """
        guard case .welcome(let w)? = decode(json) else { return XCTFail("not a welcome") }
        XCTAssertEqual(w.device, "Test iPhone")
        XCTAssertEqual(w.serverVersion, "1.2.3")
        XCTAssertEqual(w.tasks.count, 1, "the junk task row is dropped, not fatal")
        XCTAssertEqual(w.tasks[0].status, "running")
        XCTAssertTrue(w.tasks[0].isActive)
        XCTAssertEqual(w.approvals[0].id, "a1b2")
        XCTAssertEqual(w.files[0].isPDF, true)
        XCTAssertEqual(w.cameras[0].name, "Door")
        XCTAssertEqual(w.terminals[0].cols, 80)
        XCTAssertEqual(w.history.count, 2)
        XCTAssertEqual(w.history[1].id, "7", "numeric ids are accepted")
        XCTAssertEqual(w.agents?.agents?.first?.key, "friday")
        XCTAssertEqual(w.schedules?.items.first?.title, "Backup")
        XCTAssertEqual(w.schedules?.scheduler?.tz, "Asia/Karachi")
        XCTAssertEqual(w.sessionNumber, 4)
        XCTAssertTrue(w.busy)
    }

    func testUnknownAndMalformedNeverThrow() {
        XCTAssertEqual(decode(#"{"type":"brand_new_thing","x":1}"#), .unknown(type: "brand_new_thing"))
        XCTAssertEqual(decode(#"{"type":"text_delta","turn_id":5}"#), .malformed(type: "text_delta"))
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode(#"{"no_type":1}"#))
        XCTAssertNil(decode("[1,2,3]"))
    }

    func testTurnLifecycleMessages() {
        XCTAssertEqual(decode(#"{"type":"turn_started","turn_id":"t1","kind":"message","agent":"friday","voice":true}"#), .turnStarted(turnId: "t1", kind: "message", agent: "friday", voice: true))
        XCTAssertEqual(decode(#"{"type":"text_delta","turn_id":"t1","text":"Hel"}"#), .textDelta(turnId: "t1", text: "Hel"))
        if case .turnDone(let d)? = decode(#"{"type":"turn_done","turn_id":"t1","text":"Hello","steps":2,"model":"claude-x","cost_usd":0.01,"tools_used":["fs.read"]}"#) {
            XCTAssertEqual(d.text, "Hello"); XCTAssertEqual(d.toolsUsed, ["fs.read"]); XCTAssertEqual(d.costUsd, 0.01)
        } else { XCTFail() }
        XCTAssertEqual(decode(#"{"type":"call_started","resumed":true}"#), .callStarted(resumed: true))
        XCTAssertEqual(decode(#"{"type":"call_ended","reason":"The call moved to a new connection."}"#), .callEnded(reason: "The call moved to a new connection."))
        XCTAssertEqual(decode(#"{"type":"voice_state","state":"speaking"}"#), .voiceState("speaking"))
        XCTAssertEqual(decode(#"{"type":"voice_stop"}"#), .voiceStop)
        XCTAssertEqual(decode(#"{"type":"voice_error","text":"STT down","recoverable":true}"#), .voiceError(text: "STT down", recoverable: true))
        XCTAssertEqual(decode(#"{"type":"error","message":"bad"}"#), .error(text: "bad"))
        XCTAssertEqual(decode(#"{"type":"pong"}"#), .pong)
        XCTAssertEqual(decode(#"{"type":"file_removed","ids":["a","b"]}"#), .fileRemoved(ids: ["a", "b"]))
    }

    func testClientMessagesUseServerFieldNames() throws {
        func obj(_ m: ClientMessage) -> [String: JSONValue] { JSONValue.parse(m.json())!.object! }
        XCTAssertEqual(obj(.callStart(manual: true)), ["type": .string("call_start"), "manual": .bool(true)])
        XCTAssertEqual(obj(.callEnd), ["type": .string("call_end")])
        XCTAssertEqual(obj(.approval(id: "abcd", approve: false)), ["type": .string("approval"), "id": .string("abcd"), "approve": .bool(false)])
        XCTAssertEqual(obj(.cancelTask(id: "t9")), ["type": .string("cancel_task"), "task_id": .string("t9")])
        XCTAssertEqual(obj(.presence(visible: false)), ["type": .string("presence"), "visible": .bool(false)])
        XCTAssertEqual(obj(.userMessage(text: "hi", attachments: [])), ["type": .string("user_message"), "text": .string("hi")])
        XCTAssertEqual(obj(.userMessage(text: "hi", attachments: ["f1"]))["attachments"], .array([.string("f1")]))
        XCTAssertEqual(obj(.terminalOpen(cwd: nil)), ["type": .string("terminal_open")])
        XCTAssertEqual(obj(.hello(client: "ios"))["client"], .string("ios"))
        XCTAssertEqual(obj(.voicePlayback(event: "underrun", underruns: 1, gapMs: 80))["event"], .string("underrun"))
    }

    func testHistoryRowsBecomeTimelineEntries() {
        let rows = """
        {"items":[
          {"id":"1","seq":1,"ts":"2026-11-12T10:00:00.500Z","kind":"message","role":"user","name":"You","text":"hello"},
          {"id":"2","seq":2,"ts":"2026-11-12T10:00:01Z","kind":"message","role":"assistant","name":"Jarvis","agent":"jarvis","text":"Good evening","interrupted":true,"heard":"Good","tools":[]},
          {"id":"3","seq":3,"kind":"task","event":"done","task_id":"t1","owner":"friday","name":"Friday","title":"Fix","status":"done","summary":"ok"},
          {"id":"4","seq":4,"kind":"mystery"},
          {"id":"5","seq":5,"kind":"approval","tool":"shell","status":"approved","by":"voice","what":"ls"}
        ]}
        """
        let resp = try! JSONDecoder().decode(HistoryResponse.self, from: Data(rows.utf8))
        var tl = TimelineReducer()
        tl.setHistory(resp.items)
        XCTAssertEqual(tl.entries.map { $0.kind }, [.user, .assistant, .task, .approval])
        XCTAssertTrue(tl.entries[1].interrupted)
        XCTAssertEqual(tl.entries[1].detail, "Good")
        XCTAssertEqual(tl.entries[2].persona, "friday")
        XCTAssertNotNil(tl.entries[0].ts)
        XCTAssertEqual(tl.oldestSeq, 1)
    }
}

final class EndpointTests: XCTestCase {
    func testParsing() throws {
        let a = try Endpoint.parse("my-laptop.tail1234.ts.net")
        XCTAssertTrue(a.secure); XCTAssertEqual(a.origin, "https://my-laptop.tail1234.ts.net")
        XCTAssertEqual(a.wsURL("/ws/session", query: [("r", "1")])?.absoluteString, "wss://my-laptop.tail1234.ts.net/ws/session?r=1")
        let b = try Endpoint.parse("  HTTPS://Box.Example:8443/some/path?x=1 ")
        XCTAssertEqual(b.authority, "box.example:8443"); XCTAssertEqual(b.origin, "https://box.example:8443")
        let c = try Endpoint.parse("http://127.0.0.1:8000")
        XCTAssertFalse(c.secure); XCTAssertEqual(c.origin, "http://127.0.0.1:8000")
        XCTAssertEqual(c.wsURL("/ws/session")?.absoluteString, "ws://127.0.0.1:8000/ws/session")
        XCTAssertFalse(try Endpoint.parse("192.168.1.5:8000").secure, "private address with a port defaults to http")
        XCTAssertTrue(try Endpoint.parse("example.com:8443").secure)
        XCTAssertEqual(try Endpoint.parse("https://x.ts.net:443").authority, "x.ts.net", "default port is not part of Host")
        XCTAssertEqual(try Endpoint.parse("[::1]:8000").httpURL("/health")?.absoluteString, "http://[::1]:8000/health")
    }
    func testRejects() {
        XCTAssertThrowsError(try Endpoint.parse("   "))
        XCTAssertThrowsError(try Endpoint.parse("ftp://x.com"))
        XCTAssertThrowsError(try Endpoint.parse("a b.com"))
        XCTAssertThrowsError(try Endpoint.parse("host:notaport"))
        XCTAssertThrowsError(try Endpoint.parse("user@host.com"))
    }
    func testSetCookie() {
        XCTAssertEqual(SetCookie.value(named: "jarvis_device", in: "jarvis_device=abc123; HttpOnly; Max-Age=31536000; Path=/; SameSite=strict"), "abc123")
        XCTAssertEqual(SetCookie.value(named: "jarvis_device", in: "other=1; Path=/, jarvis_device=tok_en-9; Expires=Wed, 21 Oct 2027 07:28:00 GMT; Path=/"), "tok_en-9")
        XCTAssertNil(SetCookie.value(named: "jarvis_device", in: "other=1"))
        XCTAssertNil(SetCookie.value(named: "jarvis_device", in: "jarvis_device=; Max-Age=0"))
    }
    func testBackoff() {
        var b = Backoff(jitterMs: 0)
        XCTAssertEqual(b.nextDelay(random: 0), 0.25, accuracy: 1e-9)
        XCTAssertEqual(b.nextDelay(random: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(b.nextDelay(random: 0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(b.nextDelay(random: 0), 4.0, accuracy: 1e-9)
        XCTAssertEqual(b.nextDelay(random: 0), 8.0, accuracy: 1e-9)
        XCTAssertEqual(b.nextDelay(random: 0), 15.0, accuracy: 1e-9)
        XCTAssertEqual(b.nextDelay(random: 0), 15.0, accuracy: 1e-9)
        b.reset()
        XCTAssertEqual(b.nextDelay(random: 0.5), 0.25, accuracy: 1e-9, "jitter 0 ignores random")
        var j = Backoff(jitterMs: 250)
        XCTAssertEqual(j.nextDelay(random: 1), 0.5, accuracy: 1e-9)
    }
    func testFormat() {
        XCTAssertEqual(Format.bytes(512), "512 B"); XCTAssertEqual(Format.bytes(2048), "2 KB"); XCTAssertEqual(Format.bytes(5_242_880), "5.0 MB")
        XCTAssertEqual(Format.duration(75), "1m 15s"); XCTAssertEqual(Format.duration(3725), "1h 2m")
        XCTAssertEqual(Format.safeFileName("../../etc/passwd"), "_.._etc_passwd".replacingOccurrences(of: "_.._", with: "_.._"))
        XCTAssertEqual(Format.safeFileName(""), "file")
        XCTAssertNotNil(Format.parseISO("2026-11-12T15:25:21.123Z")); XCTAssertNotNil(Format.parseISO("2026-11-12T15:25:21+00:00")); XCTAssertNotNil(Format.parseISO("2026-11-12T15:25:21"))
        XCTAssertNil(Format.parseISO("yesterday"))
    }
}
