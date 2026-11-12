import Foundation
import XCTest
import JarvisCore
import JarvisNet
@testable import JarvisModel

final class FakeAudio: VoiceAudio, @unchecked Sendable {
    var onMicFrame: (@Sendable (Data, Float) -> Void)?
    var onOutputLevel: (@Sendable (Float) -> Void)?
    var onPlaybackActive: (@Sendable (Bool) -> Void)?
    var onEvent: (@Sendable (VoiceAudioEvent) -> Void)?
    var routeName: String { "Speaker" }
    private let lock = NSLock()
    private(set) var starts = 0, stops = 0, restarts = 0, cuts = 0
    private(set) var played = Data()
    private(set) var duckCalls: [Bool] = []
    var failStart: String?
    func start() throws { if let f = failStart { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: f]) }; lock.lock(); starts += 1; lock.unlock() }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    func restart() throws { lock.lock(); restarts += 1; lock.unlock() }
    func play(_ pcm: Data) { lock.lock(); played.append(pcm); lock.unlock(); onPlaybackActive?(true) }
    func cutPlayback() { lock.lock(); cuts += 1; lock.unlock() }
    func setDucked(_ on: Bool) { lock.lock(); duckCalls.append(on); lock.unlock() }
}

final class FakePermissions: PermissionProvider, @unchecked Sendable {
    var mic: PermissionState
    var micAfterPrompt: PermissionState
    private(set) var prompts = 0
    init(mic: PermissionState = .granted, afterPrompt: PermissionState = .granted) { self.mic = mic; micAfterPrompt = afterPrompt }
    func microphone() -> PermissionState { mic }
    func requestMicrophone() async -> PermissionState { if mic == .undetermined { prompts += 1; mic = micAfterPrompt }; return mic }
    func camera() -> PermissionState { .granted }
    func requestCamera() async -> PermissionState { .granted }
    func notifications() async -> PermissionState { .undetermined }
    func requestNotifications() async -> PermissionState { .undetermined }
}

final class FakeConnection: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<WebSocketFrame, Error>] = []
    private var waiter: CheckedContinuation<WebSocketFrame, Error>?
    private(set) var sentTexts: [String] = []
    private(set) var sentBinary: [Data] = []
    private(set) var closedNormal: Bool?
    func push(_ f: WebSocketFrame) { deliver(.success(f)) }
    func pushJSON(_ s: String) { push(.text(s)) }
    func fail() { deliver(.failure(WebSocketError.closed(code: 1006))) }
    private func deliver(_ r: Result<WebSocketFrame, Error>) {
        lock.lock()
        if let w = waiter { waiter = nil; lock.unlock(); w.resume(with: r) } else { queue.append(r); lock.unlock() }
    }
    func send(text: String) async throws { lock.lock(); sentTexts.append(text); lock.unlock() }
    func send(binary: Data, completion: @escaping @Sendable (Error?) -> Void) { lock.lock(); sentBinary.append(binary); lock.unlock(); completion(nil) }
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
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return sentTexts }
    var binaries: [Data] { lock.lock(); defer { lock.unlock() }; return sentBinary }
    func sent(_ type: String) -> Bool { texts.contains { $0.contains("\"type\":\"\(type)\"") } }
}

final class FakeTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var conns: [FakeConnection] = []
    private(set) var urls: [URL] = []
    func open(url: URL, headers: [String: String]) -> WebSocketConnection {
        let c = FakeConnection(); lock.lock(); conns.append(c); urls.append(url); lock.unlock(); return c
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return conns.count }
    func conn(_ i: Int) -> FakeConnection { lock.lock(); defer { lock.unlock() }; return conns[i] }
}

let welcomeText = #"{"v":1,"type":"welcome","ts":"x","device":"Test iPhone","server":{"version":"9.9"},"status":{"spent_usd":0.5,"budget_usd":5,"queued":0,"busy":false},"tasks":[],"approvals":[{"id":"ap01","tool":"shell.run","what":"ls"}],"files":[],"cameras":[{"id":"c1","name":"Door"}],"terminals":[],"history":[{"id":"h1","seq":1,"ts":"2026-11-12T10:00:00Z","kind":"message","role":"user","text":"earlier"}],"busy":false}"#

@MainActor
func eventually(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ cond: @MainActor () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(cond(), "timed out waiting for \(what)", file: file, line: line)
}

struct Rig {
    let transport = FakeTransport()
    let audio = FakeAudio()
    let perms: FakePermissions
    let secrets = MemorySecretStore()
    let defaults = MemoryDefaults()
    init(mic: PermissionState = .granted, afterPrompt: PermissionState = .granted, paired: Bool = true, autoStart: Bool = true) {
        perms = FakePermissions(mic: mic, afterPrompt: afterPrompt)
        if paired { _ = secrets.write("tok", for: "device-token"); defaults.set("http://127.0.0.1:9", for: "endpoint") }
        defaults.set(autoStart, for: "autoStartCall")
    }
    @MainActor func model() -> AppModel {
        let t = transport, a = audio
        return AppModel(platform: Platform(secrets: secrets, defaults: defaults, permissions: perms, makeAudio: { a },
                                           transport: WebSocketTransportProvider(make: { t })))
    }
}
