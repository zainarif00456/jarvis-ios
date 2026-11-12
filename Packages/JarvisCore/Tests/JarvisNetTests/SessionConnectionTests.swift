import XCTest
import JarvisCore
@testable import JarvisNet

final class FakeConnection: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<WebSocketFrame, Error>] = []
    private var waiter: CheckedContinuation<WebSocketFrame, Error>?
    private(set) var sentTexts: [String] = []
    private(set) var sentBinary = 0
    private(set) var closedNormal: Bool?
    var autoWelcome = true

    func push(_ f: WebSocketFrame) { deliver(.success(f)) }
    func fail() { deliver(.failure(WebSocketError.closed(code: 1006))) }
    private func deliver(_ r: Result<WebSocketFrame, Error>) {
        lock.lock()
        if let w = waiter { waiter = nil; lock.unlock(); w.resume(with: r) } else { queue.append(r); lock.unlock() }
    }
    func send(text: String) async throws { lock.lock(); sentTexts.append(text); lock.unlock() }
    func send(binary: Data, completion: @escaping @Sendable (Error?) -> Void) { lock.lock(); sentBinary += 1; lock.unlock(); completion(nil) }
    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !queue.isEmpty { let r = queue.removeFirst(); lock.unlock(); c.resume(with: r) } else { waiter = c; lock.unlock() }
        }
    }
    func close(normal: Bool) {
        lock.lock(); if closedNormal == nil { closedNormal = normal }; let w = waiter; waiter = nil; lock.unlock()
        w?.resume(throwing: WebSocketError.closed(code: normal ? 1000 : 1001))
    }
}

final class FakeTransport: WebSocketTransport, @unchecked Sendable {
    let lock = NSLock()
    private(set) var opened: [(url: URL, headers: [String: String])] = []
    private(set) var conns: [FakeConnection] = []
    var onOpen: (@Sendable (FakeConnection) -> Void)?
    func open(url: URL, headers: [String: String]) -> WebSocketConnection {
        let c = FakeConnection()
        lock.lock(); opened.append((url, headers)); conns.append(c); lock.unlock()
        onOpen?(c)
        return c
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return conns.count }
    func conn(_ i: Int) -> FakeConnection { lock.lock(); defer { lock.unlock() }; return conns[i] }
}

let welcomeJSON = #"{"v":1,"type":"welcome","ts":"x","device":"d","status":{"spent_usd":0,"budget_usd":1,"queued":0,"busy":false},"tasks":[],"approvals":[],"files":[],"history":[],"busy":false}"#

final class SessionConnectionTests: XCTestCase {
    var cfg: SessionConnection.Config { var c = SessionConnection.Config(); c.pingEvery = 0.05; c.pongTimeout = 0.12; c.backoffJitterMs = 0; return c }

    func waitFor(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    /// Collects events in the background.
    final class Collector: @unchecked Sendable {
        let lock = NSLock(); var states: [ConnectionState] = []; var messages: [ServerMessage] = []; var audio = 0
        func run(_ s: SessionConnection) -> Task<Void, Never> {
            Task { for await e in s.events {
                lock.lock()
                switch e { case .state(let st): states.append(st); case .message(let m): messages.append(m); case .audio: audio += 1 }
                lock.unlock() } }
        }
        var snapshot: ([ConnectionState], [ServerMessage]) { lock.lock(); defer { lock.unlock() }; return (states, messages) }
    }

    func testConnectsWithOriginCookieAndSaysHello() async throws {
        let t = FakeTransport()
        let ep = try Endpoint.parse("http://127.0.0.1:9")
        let s = SessionConnection(endpoint: ep, token: "tok123", transport: t, config: cfg)
        let col = Collector(); let task = col.run(s)
        await s.start()
        await waitFor("open") { t.count == 1 }
        XCTAssertEqual(t.opened[0].headers["Origin"], "http://127.0.0.1:9")
        XCTAssertEqual(t.opened[0].headers["Cookie"], "jarvis_device=tok123")
        XCTAssertTrue(t.opened[0].url.absoluteString.hasPrefix("ws://127.0.0.1:9/ws/session?r=0&v=1"), t.opened[0].url.absoluteString)
        t.conn(0).push(.text(welcomeJSON))
        await waitFor("open state") { col.snapshot.0.contains(.open) }
        await waitFor("hello") { t.conn(0).sentTexts.contains { $0.contains("\"hello\"") && $0.contains("ios") } }
        let sent = await s.send(.callStart(manual: false))
        XCTAssertTrue(sent)
        await waitFor("call_start") { t.conn(0).sentTexts.contains { $0.contains("call_start") } }
        // audio
        let ok = await s.sendAudio(Data(count: 1280)); XCTAssertTrue(ok)
        await waitFor("audio") { t.conn(0).sentBinary == 1 }
        t.conn(0).push(.binary(Data([1, 2, 3, 4]))); t.conn(0).push(.text(#"{"type":"pong"}"#)); t.conn(0).push(.text(#"{"type":"voice_state","state":"listening"}"#))
        await waitFor("messages") { col.audio == 1 && col.snapshot.1.contains(.voiceState("listening")) }
        XCTAssertFalse(col.snapshot.1.contains(.pong), "pongs are swallowed")
        await s.stop(); task.cancel()
        XCTAssertEqual(t.conn(0).closedNormal, true, "deliberate stop closes with a normal code")
    }

    func testNoSendingBeforeWelcome() async throws {
        let t = FakeTransport()
        let s = SessionConnection(endpoint: try Endpoint.parse("http://127.0.0.1:9"), token: "x", transport: t, config: cfg)
        await s.start()
        await waitFor("conn") { t.count == 1 }
        let a = await s.send(.callStart(manual: true)); let b = await s.sendAudio(Data(count: 1280))
        XCTAssertFalse(a); XCTAssertFalse(b)
        await s.stop()
    }

    func testReconnectsAfterDropWithReconnectFlag() async throws {
        let t = FakeTransport()
        let s = SessionConnection(endpoint: try Endpoint.parse("http://127.0.0.1:9"), token: "x", transport: t, config: cfg)
        let col = Collector(); let task = col.run(s)
        await s.start()
        await waitFor("c0") { t.count == 1 }
        t.conn(0).push(.text(welcomeJSON))
        await waitFor("open") { col.snapshot.0.contains(.open) }
        t.conn(0).fail()
        await waitFor("second socket") { t.count == 2 }
        let u = t.opened[1].url.absoluteString
        XCTAssertTrue(u.contains("r=1"), u); XCTAssertTrue(u.contains("c=1006"), "the previous close is reported like the web client does: \(u)")
        t.conn(1).push(.text(welcomeJSON))
        await waitFor("open again") { col.snapshot.0.filter { $0 == .open }.count == 2 }
        XCTAssertTrue(col.snapshot.0.contains { if case .reconnecting = $0 { return true }; return false })
        await s.stop(); task.cancel()
    }

    func testDeadSocketIsDetectedByMissingPong() async throws {
        let t = FakeTransport()
        let s = SessionConnection(endpoint: try Endpoint.parse("http://127.0.0.1:9"), token: "x", transport: t, config: cfg)
        await s.start()
        await waitFor("c0") { t.count == 1 }
        t.conn(0).push(.text(welcomeJSON))          // then total silence: pings go unanswered
        await waitFor("pings", timeout: 3) { t.conn(0).sentTexts.filter { $0.contains("\"ping\"") }.count >= 1 }
        await waitFor("reconnect after stale", timeout: 5) { t.count >= 2 }
        XCTAssertEqual(t.conn(0).closedNormal, false, "a stale socket is closed as going-away, not a deliberate end")
        XCTAssertTrue(t.opened[1].url.absoluteString.contains("c=4000"))
        await s.stop()
    }

    func testRepliesKeepTheSocketAlive() async throws {
        let t = FakeTransport()
        t.onOpen = { c in Task { // a healthy server: welcome, then answer every ping
            c.push(.text(welcomeJSON))
            for _ in 0..<40 { try? await Task.sleep(nanoseconds: 30_000_000); c.push(.text(#"{"type":"pong"}"#)) } } }
        let s = SessionConnection(endpoint: try Endpoint.parse("http://127.0.0.1:9"), token: "x", transport: t, config: cfg)
        await s.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(t.count, 1, "no needless reconnects while the server answers")
        await s.stop()
    }

    func testStopThenNoReconnect() async throws {
        let t = FakeTransport()
        let s = SessionConnection(endpoint: try Endpoint.parse("http://127.0.0.1:9"), token: "x", transport: t, config: cfg)
        await s.start()
        await waitFor("c0") { t.count == 1 }
        await s.stop()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(t.count, 1)
    }

    func testBackoffGrowsWhenServerIsDown() async throws {
        let t = FakeTransport()
        t.onOpen = { c in c.fail() }
        let s = SessionConnection(endpoint: try Endpoint.parse("http://127.0.0.1:9"), token: "x", transport: t, config: cfg)
        let start = Date()
        await s.start()
        await waitFor("3 attempts", timeout: 8) { t.count >= 3 }
        // delays: 0.25 then 1.0 (isPaired against a closed port returns nil quickly: treated as server down)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 1.0)
        await s.stop()
    }

    func testAudioBackpressureDropsInsteadOfQueueing() async throws {
        let gate = AudioGate()
        for _ in 0..<50 { XCTAssertTrue(gate.tryEnter(limit: 50)) }
        XCTAssertFalse(gate.tryEnter(limit: 50)); gate.leave(); XCTAssertTrue(gate.tryEnter(limit: 50))
    }
}
