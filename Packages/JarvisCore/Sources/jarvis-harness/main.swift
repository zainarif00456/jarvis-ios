import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JarvisCore
import JarvisNet

// Drives the app's real networking layer (the same JarvisNet / JarvisCore code the iOS app links) against a real
// Jarvis gateway on a local port. Started by Harness/run_harness.sh. Usage: jarvis-harness <base-url> <pairing-code>

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0
var passes = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passes += 1; print("  PASS  \(name)") } else { failures += 1; print("  FAIL  \(name) \(detail)") }
}
func info(_ s: String) { print("  ....  \(s)") }
func section(_ s: String) { print("\n== \(s)") }

let args = CommandLine.arguments
guard args.count >= 3, let endpoint = try? Endpoint.parse(args[1]) else { print("usage: jarvis-harness <base-url> <code>"); exit(2) }
let code = args[2]

/// Waits (polling) until the condition holds or the time runs out.
func until(_ seconds: Double = 10, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
    return cond()
}

final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [ServerMessage] = []
    private var _audio: [Data] = []
    private var _states: [ConnectionState] = []
    var messages: [ServerMessage] { lock.lock(); defer { lock.unlock() }; return _messages }
    var audio: [Data] { lock.lock(); defer { lock.unlock() }; return _audio }
    var states: [ConnectionState] { lock.lock(); defer { lock.unlock() }; return _states }
    func add(_ e: SessionEvent) {
        lock.lock(); defer { lock.unlock() }
        switch e { case .message(let m): _messages.append(m); case .audio(let d): _audio.append(d); case .state(let s): _states.append(s) }
    }
    func clear() { lock.lock(); _messages.removeAll(); _audio.removeAll(); lock.unlock() }
    func has(_ pred: (ServerMessage) -> Bool) -> Bool { messages.contains(where: pred) }
}

/// Wraps the real transport so the harness can break a socket the way a network drop does.
final class TappedTransport: WebSocketTransport, @unchecked Sendable {
    let inner = URLSessionTransport()
    private let lock = NSLock()
    private(set) var connections: [WebSocketConnection] = []
    func open(url: URL, headers: [String: String]) -> WebSocketConnection {
        let c = inner.open(url: url, headers: headers)
        lock.lock(); connections.append(c); lock.unlock()
        return c
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return connections.count }
    func dropLatest() { lock.lock(); let c = connections.last; lock.unlock(); c?.close(normal: false) }
}

// ------------------------------------------------------------------------------------------------
section("health, pairing")
let anon = ApiClient(endpoint: endpoint, token: nil)
check("GET /health", await anon.health())
check("unpaired device is reported as unpaired", await anon.isPaired() == false)
do {
    _ = try await ApiClient.pair(endpoint: endpoint, code: "WRONG-CODE", name: "Harness")
    check("wrong pairing code is refused", false)
} catch let e as ApiError {
    check("wrong pairing code is refused with the server's reason", e.statusCode == 400 && !(e.errorDescription ?? "").isEmpty, "\(e)")
} catch { check("wrong pairing code is refused", false, "\(error)") }

var token = ""
do {
    token = try await ApiClient.pair(endpoint: endpoint, code: code, name: "Harness iPhone")
    check("pairing with the one-time code returns a device token (cookie parsed from Set-Cookie)", token.count >= 20)
} catch { check("pairing", false, "\(error)"); exit(1) }
do {
    _ = try await ApiClient.pair(endpoint: endpoint, code: code, name: "again")
    check("a pairing code works only once", false)
} catch { check("a pairing code works only once", true) }

let api = ApiClient(endpoint: endpoint, token: token)
check("paired device is recognised", await api.isPaired() == true)
if let me = try? await api.me() { check("GET /api/me names the device", (me.device ?? "").hasPrefix("Harness iPhone"), "\(me)") } else { check("GET /api/me", false) }
let bogus = ApiClient(endpoint: endpoint, token: "not-a-real-token")
check("a bad token is reported unpaired", await bogus.isPaired() == false)
do { let _: HistoryResponse = try await bogus.get("/api/history"); check("bad token gets 401", false) }
catch let e as ApiError { check("bad token gets 401 on REST", e.isUnauthorized, "\(e)") } catch { check("bad token 401", false) }

// ------------------------------------------------------------------------------------------------
section("origin check")
do {
    let t = URLSessionTransport()
    let url = endpoint.wsURL("/ws/session")!
    let c = t.open(url: url, headers: ["Origin": "https://evil.example", "Cookie": "jarvis_device=\(token)"])
    var refused = false
    do { _ = try await c.receive() } catch { refused = true }
    check("a WebSocket with a foreign Origin is refused", refused)
    c.close(normal: true)
}

// ------------------------------------------------------------------------------------------------
section("dynamic base URL: same server, second address")
// (runs before the big session section: swift-corelibs-foundation on Linux truncates a WebSocket message above ~4 KB, and the welcome grows with history)
do {
    let port = endpoint.port.map(String.init) ?? "80"
    let alt = try Endpoint.parse("http://localhost:\(port)")        // the same server under another Host
    check("the alternative address has its own Origin (= its Host)", alt.origin == "http://localhost:\(port)" && alt.origin != endpoint.origin)
    check("probe: paired token on the first address", await ApiClient(endpoint: endpoint, token: token).probe() == .paired)
    check("probe: the same token is paired on the second address (no re-pairing)", await ApiClient(endpoint: alt, token: token).probe() == .paired)
    check("probe: no token -> unpaired", await ApiClient(endpoint: alt, token: nil).probe() == .unpaired)
    if case .unreachable = await ApiClient(endpoint: try Endpoint.parse("http://127.0.0.1:1"), token: token).probe() { check("probe: closed port -> unreachable", true) } else { check("probe: closed port -> unreachable", false) }
    // REST with Origin of the second address works (state-changing request is checked by the server)
    let altApi = ApiClient(endpoint: alt, token: token)
    let altMe = try? await altApi.me()
    check("GET /api/me works through the second address", (altMe?.device ?? "").hasPrefix("Harness iPhone"))
    // a request whose Origin belongs to the OTHER address must be refused: proves the server compares Origin with Host
    var wrong = URLRequest(url: alt.httpURL("/api/pair")!)
    wrong.httpMethod = "POST"; wrong.setValue(endpoint.origin, forHTTPHeaderField: "Origin"); wrong.setValue("application/json", forHTTPHeaderField: "Content-Type"); wrong.httpBody = Data("{\"code\":\"x\"}".utf8)
    if let (_, resp) = try? await URLSession.shared.data(for: wrong), let h = resp as? HTTPURLResponse { check("POST with an Origin of another address is refused (403)", h.statusCode == 403, "status \(h.statusCode)") }
    else { check("POST with a foreign Origin answered", false) }
    // the session socket on the second address
    let box2 = Inbox()
    let s2 = SessionConnection(endpoint: alt, token: token, config: { var c = SessionConnection.Config(); c.clientName = "ios-harness"; return c }())
    let pump2 = Task { for await e in s2.events { box2.add(e) } }
    await s2.start()
    check("session socket connects through the second address (Origin = its Host) and welcomes", await until(15) { box2.has { if case .welcome = $0 { return true }; return false } })
    await s2.stop(); pump2.cancel()
    // HTML where JSON is expected: the gateway's web page at "/"
    do { let _: JSONValue = try await api.get("/"); check("HTML page where JSON is expected is an error", false) }
    catch let e as ApiError { check("HTML page where JSON is expected -> 'not Jarvis / ngrok page' error", e == .notJarvis || e.statusCode != nil, "\(e)"); info("answer for GET /: \(e.errorDescription ?? "")") }
    catch { check("HTML detection", false, "\(error)") }
} catch { check("dynamic base URL", false, "\(error)") }

// ------------------------------------------------------------------------------------------------
section("session socket: welcome, text round trip")
let tap = TappedTransport()
let inbox = Inbox()
var cfg = SessionConnection.Config(); cfg.clientName = "ios-harness"
let session = SessionConnection(endpoint: endpoint, token: token, transport: tap, config: cfg)
let pump = Task { for await e in session.events { inbox.add(e) } }
await session.start()
check("welcome arrives and the connection reports open", await until(15) { inbox.has { if case .welcome = $0 { return true }; return false } } && inbox.states.contains(.open))
if case .welcome(let w)? = inbox.messages.first(where: { if case .welcome = $0 { return true }; return false }) {
    check("welcome names this device", (w.device ?? "").hasPrefix("Harness iPhone"), "\(String(describing: w.device))")
    check("welcome carries status/budget", w.status?.budgetUsd != nil)
    info("welcome: server \(w.serverVersion ?? "?"), \(w.history.count) history rows, \(w.files.count) files, \(w.terminals.count) terminals")
}
_ = await until(4) { inbox.has { if case .turnDone = $0 { return true }; return false } }   // the greeting turn, if any
inbox.clear()
_ = await session.send(.userMessage(text: "hello from the harness", attachments: []))
let gotReply = await until(15) { inbox.has { if case .turnDone = $0 { return true }; return false } }
check("typed message gets a streamed reply (turn_started, text_delta, turn_done)", gotReply)
var timeline = TimelineReducer()
timeline.addLocalUser("hello from the harness")
for m in inbox.messages { timeline.apply(m) }
check("timeline reducer folds the turn into user + assistant rows", timeline.entries.count == 2 && timeline.entries[1].text.contains("Fake reply") && !timeline.entries[1].streaming, "\(timeline.entries.map { "\($0.kind):\($0.text)" })")
let hist: HistoryResponse? = try? await api.get("/api/history", query: [("limit", "20")])
check("GET /api/history returns the exchange", (hist?.items.contains { $0.text == "hello from the harness" }) ?? false, "\(String(describing: hist?.items.count))")

// ------------------------------------------------------------------------------------------------
section("voice call with silent audio frames")
inbox.clear()
_ = await session.send(.callStart(manual: true))
check("call_start is answered with call_started", await until(10) { inbox.has { if case .callStarted = $0 { return true }; return false } })
let silent = Data(count: PCM.frameBytes)
var framesSent = 0
for _ in 0..<50 { if await session.sendAudio(silent) { framesSent += 1 }; try? await Task.sleep(nanoseconds: 40_000_000) }
check("50 silent 40 ms frames (1280 bytes, 16 kHz Int16) were accepted by the socket", framesSent == 50, "sent \(framesSent)")
check("manual call speaks its greeting: binary 24 kHz PCM arrives", await until(10) { !inbox.audio.isEmpty })
check("downlink audio frames are whole Int16 samples", inbox.audio.allSatisfy { $0.count % 2 == 0 && !$0.isEmpty })
var sa = SampleAligner(); let decoded = inbox.audio.flatMap { sa.push($0) }
info("received \(inbox.audio.count) audio chunks = \(String(format: "%.2f", Double(decoded.count) / 24000)) s of speech")
check("voice_state messages arrive", inbox.has { if case .voiceState = $0 { return true }; return false })

// drop the socket mid call: the app must reconnect and resume the parked call
let before = tap.count
inbox.clear()
tap.dropLatest()
check("socket drop is noticed and a new socket opens by itself", await until(10) { tap.count > before })
check("a fresh welcome arrives after reconnecting", await until(10) { inbox.has { if case .welcome = $0 { return true }; return false } })
_ = await session.send(.callStart(manual: false))
check("call_start after the drop resumes the same call (call_started resumed=true)", await until(10) { inbox.has { if case .callStarted(let r) = $0 { return r }; return false } })
_ = await session.send(.callEnd)
check("call_end ends the call", await until(10) { inbox.has { if case .callEnded = $0 { return true }; return false } })

// ------------------------------------------------------------------------------------------------
section("terminal")
inbox.clear()
_ = await session.send(.terminalOpen(cwd: nil))
var termId = ""
let opened = await until(10) { inbox.has { if case .terminalOpened = $0 { return true }; return false } }
for m in inbox.messages { if case .terminalOpened(let t) = m { termId = t.id } }
check("terminal_open is answered with terminal_opened", opened && !termId.isEmpty)
if !termId.isEmpty {
    let term = try StreamSocket(endpoint: endpoint, token: token, path: "/ws/terminal/\(termId)")
    let emu = TerminalEmulator(cols: 80, rows: 24)
    let screen = NSLock(); var got = Data(); var sawInfo = false
    let reader = Task {
        do { for try await f in term.frames {
            screen.lock()
            switch f { case .binary(let d): got.append(d); emu.feed(d); case .text(let t): if t.contains("\"info\"") { sawInfo = true } }
            screen.unlock()
        } } catch {}
    }
    term.resize(cols: 80, rows: 24)
    try? await Task.sleep(nanoseconds: 600_000_000)
    term.send(binary: Data("echo jarvis-harness-$((6*7))\r".utf8))
    let echoed = await until(10) { screen.lock(); defer { screen.unlock() }; return emu.buffer.text.contains("jarvis-harness-42") }
    screen.lock(); let screenText = emu.buffer.text; let info1 = sawInfo; screen.unlock()
    check("typed command runs in the live terminal and its output renders in the emulator", echoed, screenText.suffix(200).description)
    check("terminal socket sends the info frame", info1)
    term.resize(cols: 60, rows: 20)
    term.send(binary: Data("stty size\r".utf8))
    let resized = await until(8) { screen.lock(); defer { screen.unlock() }; return emu.buffer.text.contains("20 60") }
    check("resize message reaches the pty (stty size reports 20 60)", resized)
    // reconnecting replays the screen so far
    term.close(); reader.cancel()
    let again = try StreamSocket(endpoint: endpoint, token: token, path: "/ws/terminal/\(termId)")
    let emu2 = TerminalEmulator(cols: 60, rows: 20); let l2 = NSLock()
    let r2 = Task { do { for try await f in again.frames { if case .binary(let d) = f { l2.lock(); emu2.feed(d); l2.unlock() } } } catch {} }
    let replayed = await until(8) { l2.lock(); defer { l2.unlock() }; return emu2.buffer.text.contains("jarvis-harness-42") }
    check("reconnecting to the terminal replays the screen", replayed)
    again.close(); r2.cancel()
    _ = await session.send(.terminalClose(id: termId))
    check("terminal_close is answered with terminal_closed", await until(8) { inbox.has { if case .terminalClosed = $0 { return true }; return false } })
    let missing = try StreamSocket(endpoint: endpoint, token: token, path: "/ws/terminal/doesnotexist")
    var failed = false
    do { for try await _ in missing.frames { } ; failed = true } catch { failed = true }
    check("an unknown terminal id closes the socket", failed)
}

// ------------------------------------------------------------------------------------------------
section("files: upload, list, download, media upload")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("harness-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let payload = Data((0..<1_500_000).map { UInt8(($0 * 7) % 256) })
let src = tmp.appendingPathComponent("upload me.bin"); try payload.write(to: src)
final class Prog: @unchecked Sendable { let l = NSLock(); var vals: [Double] = []; func add(_ v: Double) { l.lock(); vals.append(v); l.unlock() } }
let prog = Prog()
var uploaded: UploadResult?
do {
    uploaded = try await api.upload(fileURL: src, fileName: "upload me.bin", mime: "application/octet-stream", to: "/api/uploads") { prog.add($0) }
    check("POST /api/uploads accepts a 1.5 MB multipart upload", uploaded?.size == payload.count && uploaded?.id != nil, "\(String(describing: uploaded))")
    check("upload progress is reported and ends at 100%", prog.vals.last == 1.0 && prog.vals.count >= 2, "\(prog.vals.suffix(3))")
} catch { check("upload", false, "\(error)") }
struct FilesResp: Decodable { let files: [FileInfo] }
let listed: FilesResp? = try? await api.get("/api/files", query: [("kind", "upload")])
let mine = listed?.files.first { $0.id == uploaded?.id }
check("GET /api/files?kind=upload lists the uploaded file", mine != nil && mine?.size == payload.count && mine?.name == "upload me.bin", "\(String(describing: listed?.files.map { $0.name }))")
if let id = uploaded?.id {
    do {
        let dl = try await api.download(path: "/api/files/\(id)/download", suggestedName: "upload me.bin") { _ in }
        let back = try Data(contentsOf: dl)
        check("download returns the same bytes", back == payload)
        try? FileManager.default.removeItem(at: dl.deletingLastPathComponent())
    } catch { check("download", false, "\(error)") }
    let dup = try? await api.upload(fileURL: src, fileName: "upload me.bin", mime: "application/octet-stream", to: "/api/uploads") { _ in }
    check("identical content is deduplicated by the server", dup?.duplicate == true, "\(String(describing: dup))")
}
// a tiny PNG to the media library, like a photo from the phone
let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
let pngURL = tmp.appendingPathComponent("photo.png"); try png.write(to: pngURL)
do {
    let up = try await api.upload(fileURL: pngURL, fileName: "photo.png", mime: "image/png", to: "/api/media/upload", fields: ["source": "Harness iPhone camera", "origin": "device"]) { _ in }
    check("POST /api/media/upload accepts a photo", up.name != nil || up.id != nil, "\(up)")
    let media: MediaResponse? = try? await api.get("/api/media", query: [("limit", "10")])
    check("GET /api/media lists it", (media?.media.count ?? 0) >= 1, "\(String(describing: media?.media.count))")
} catch { check("media upload", false, "\(error)") }
try? FileManager.default.removeItem(at: tmp)
do {
    _ = try await api.upload(fileURL: URL(fileURLWithPath: "/nonexistent/file"), fileName: "x", mime: "text/plain", to: "/api/uploads") { _ in }
    check("uploading a missing file fails cleanly", false)
} catch { check("uploading a missing file fails cleanly (no crash)", true) }

// ------------------------------------------------------------------------------------------------
section("other REST the deck uses")
let cams: CamerasResponse? = try? await api.get("/api/cameras")
check("GET /api/cameras decodes", cams != nil)
let sched: ScheduleState? = try? await api.get("/api/schedules")
check("GET /api/schedules decodes", sched != nil)
struct SessionsResp: Decodable { let sessions: [SessionSummary] }
let sessions: SessionsResp? = try? await api.get("/api/sessions")
check("GET /api/sessions decodes and has a current session", sessions?.sessions.contains { $0.current == true } ?? false, "\(String(describing: sessions?.sessions.count))")
struct Created: Decodable { let id: String }
do {
    let body: JSONValue = .object(["title": .string("Harness reminder"), "description": .string("check the app"), "mode": .string("remind"),
                                   "when": .object(["kind": .string("in"), "in_minutes": .number(60)])])
    let made: Created = try await api.send("POST", "/api/schedules", json: body)
    let after: ScheduleState = try await api.get("/api/schedules")
    check("POST /api/schedules creates a reminder that GET lists", after.items.contains { $0.id == made.id && $0.title == "Harness reminder" }, "\(after.items.map { $0.title })")
    let _: JSONValue = try await api.send("PATCH", "/api/schedules/\(made.id)", json: .object(["title": .string("Harness reminder 2")]))
    let _: JSONValue = try await api.send("POST", "/api/schedules/\(made.id)/pause")
    let paused: ScheduleState = try await api.get("/api/schedules")
    check("PATCH and pause work", paused.items.first { $0.id == made.id }?.status == "paused" && paused.items.first { $0.id == made.id }?.title == "Harness reminder 2", "\(String(describing: paused.items.first { $0.id == made.id }))")
    let _: JSONValue = try await api.send("DELETE", "/api/schedules/\(made.id)")
    let gone: ScheduleState = try await api.get("/api/schedules")
    check("DELETE removes it", !gone.items.contains { $0.id == made.id })
} catch { check("schedules round trip", false, "\(error)") }

// ------------------------------------------------------------------------------------------------
section("revoked / unknown device")
let bogusSession = SessionConnection(endpoint: endpoint, token: "definitely-not-valid", config: cfg)
let bogusBox = Inbox()
let bogusPump = Task { for await e in bogusSession.events { bogusBox.add(e) } }
await bogusSession.start()
check("a socket with an unknown device cookie ends in .unauthorized (no retry storm)", await until(15) { bogusBox.states.contains(.unauthorized) })
bogusPump.cancel()

await session.stop()
pump.cancel()
print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
