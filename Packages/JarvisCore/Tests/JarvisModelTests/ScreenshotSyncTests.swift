import Foundation
import XCTest
import JarvisCore
import JarvisNet
@testable import JarvisModel

final class FakeShots: ScreenshotSource, @unchecked Sendable {
    var state: ScreenshotAccess = .full
    var afterPrompt: ScreenshotAccess = .full
    var library: [ScreenshotCandidate] = []
    var exportError: Error?
    private(set) var prompts = 0, observing = 0, stops = 0, exports: [String] = []
    private(set) var onChange: (@Sendable () -> Void)?
    func access() -> ScreenshotAccess { state }
    func requestAccess() async -> ScreenshotAccess { if state == .notDetermined { prompts += 1; state = afterPrompt }; return state }
    func candidates(after date: Date) -> [ScreenshotCandidate] { library.filter { $0.created > date }.sorted { $0.created < $1.created } }
    func export(id: String) async throws -> ExportedScreenshot {
        exports.append(id)
        if let e = exportError { throw e }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: url)
        return ExportedScreenshot(fileURL: url, ext: "png")
    }
    func startObserving(_ onChange: @escaping @Sendable () -> Void) { observing += 1; self.onChange = onChange }
    func stopObserving() { stops += 1 }
}

@MainActor
final class ScreenshotSyncTests: XCTestCase {
    struct Sent { var name: String; var mime: String; var source: String }
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }

    func make(_ src: FakeShots, defaults: SimpleDefaults = MemoryDefaults(), failing: @escaping () -> Error? = { nil }) -> (ScreenshotSyncModel, () -> [Sent]) {
        var sent: [Sent] = []
        let m = ScreenshotSyncModel(source: src, defaults: defaults)
        m.now = { [unowned self] in self.clock }
        m.sleep = { _ in }
        m.autoRetry = false
        m.runProtected = { work in Task { await work() } }
        m.upload = { _, name, mime, source in
            if let e = failing() { throw e }
            sent.append(Sent(name: name, mime: mime, source: source))
        }
        return (m, { sent })
    }

    func testFirstRunNeverUploadsOldPhotosThenUploadsNewOnesOnceInOrder() async {
        let src = FakeShots(); src.library = [.init(id: "old", created: at(-100))]
        let (m, sent) = make(src)
        await m.refresh()
        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(src.observing, 1)
        src.library += [.init(id: "s2", created: at(20)), .init(id: "s1", created: at(10)), .init(id: "p", created: at(15), isScreenshot: false)]
        clock = at(30)
        await m.sync(); await m.sync()
        XCTAssertEqual(src.exports, ["s1", "s2"])
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent()[0].source, "iphone-screenshot")
        XCTAssertEqual(sent()[0].mime, "image/png")
        XCTAssertTrue(sent()[0].name.hasPrefix("Screenshot "))
        XCTAssertEqual(m.ledger.totalUploaded, 2)
        XCTAssertEqual(m.banner, "Screenshot sent to Jarvis")
    }

    func testStateSurvivesRelaunchNoReupload() async {
        let defaults = MemoryDefaults(); let src = FakeShots()
        let (m, sent) = make(src, defaults: defaults)
        await m.refresh()
        src.library = [.init(id: "s1", created: at(10))]; clock = at(20)
        await m.sync()
        XCTAssertEqual(sent().count, 1)
        let (m2, sent2) = make(src, defaults: defaults)          // relaunch with the same storage
        clock = at(40)
        await m2.refresh()
        XCTAssertTrue(sent2().isEmpty)
        XCTAssertEqual(m2.ledger.totalUploaded, 1)
    }

    func testMissedWhileClosedAreCaughtUpInOrderOnNextLaunch() async {
        let defaults = MemoryDefaults(); let src = FakeShots()
        let (m, _) = make(src, defaults: defaults)
        await m.refresh()                                         // enabled at t0
        src.library = [.init(id: "b", created: at(200)), .init(id: "a", created: at(100))]   // taken while the app was not running
        clock = at(500)
        let (m2, sent2) = make(src, defaults: defaults)
        await m2.refresh()
        XCTAssertEqual(src.exports, ["a", "b"])
        XCTAssertEqual(sent2().count, 2)
    }

    func testNetworkFailureKeepsOrderQueuesAndRetriesAfterDelay() async {
        let src = FakeShots(); var down = true
        let (m, sent) = make(src, failing: { down ? URLError(.notConnectedToInternet) : nil })
        await m.refresh()
        src.library = [.init(id: "a", created: at(10)), .init(id: "b", created: at(11))]; clock = at(20)
        await m.sync()
        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(m.ledger.pending.map(\.id), ["a", "b"])
        XCTAssertEqual(src.exports, ["a"])                        // b did not jump ahead
        XCTAssertFalse(m.connected)
        XCTAssertTrue(m.statusLine.contains("2 waiting"))
        clock = at(22); await m.sync()                            // not due yet (5 s backoff)
        XCTAssertEqual(src.exports, ["a"])
        down = false; clock = at(30); await m.sync()
        XCTAssertEqual(src.exports, ["a", "a", "b"])
        XCTAssertEqual(sent().count, 2)
        XCTAssertTrue(m.connected)
        XCTAssertTrue(m.ledger.pending.isEmpty)
    }

    func testConnectivityBackReleasesWaitingItems() async {
        let src = FakeShots(); var down = true
        let (m, sent) = make(src, failing: { down ? ApiError.offline("x") : nil })
        await m.refresh()
        src.library = [.init(id: "a", created: at(10))]; clock = at(20); await m.sync()
        XCTAssertEqual(m.ledger.pending.count, 1)
        down = false; clock = at(21)
        m.connectivityChanged()
        for _ in 0..<50 where sent().isEmpty { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(sent().count, 1)
    }

    func testPairingLostIsRetriedNotDropped_AndNotConnectedToo() async {
        let src = FakeShots(); var err: Error? = ApiError.http(status: 401, detail: "no")
        let (m, sent) = make(src, failing: { err })
        await m.refresh()
        src.library = [.init(id: "a", created: at(10))]; clock = at(20); await m.sync()
        XCTAssertEqual(m.ledger.pending.count, 1)
        XCTAssertEqual(m.ledger.lastError, "This phone is no longer paired.")
        err = ScreenshotUploadError.notConnected; clock = at(100); await m.sync()
        XCTAssertEqual(m.ledger.pending.count, 1)
        err = nil; clock = at(1000); await m.sync()
        XCTAssertEqual(sent().count, 1)
    }

    func testServerRefusalDropsOnlyThatItem() async {
        let src = FakeShots(); var first = true
        let (m, sent) = make(src, failing: { if first { first = false; return ApiError.http(status: 413, detail: "big") }; return nil })
        await m.refresh()
        src.library = [.init(id: "a", created: at(10)), .init(id: "b", created: at(11))]; clock = at(20); await m.sync()
        XCTAssertEqual(sent().count, 1)                           // b went through
        XCTAssertTrue(m.ledger.pending.isEmpty)
        XCTAssertNil(m.ledger.lastError)                          // cleared by b's success
        await m.sync()
        XCTAssertEqual(src.exports, ["a", "b"])                   // a is not retried
    }

    func testDeletedAssetIsDroppedAndUnreadableOneEventuallyToo() async {
        let src = FakeShots(); let (m, sent) = make(src)
        await m.refresh()
        src.library = [.init(id: "a", created: at(10)), .init(id: "b", created: at(11))]; clock = at(20)
        src.exportError = ScreenshotSourceError.assetMissing
        await m.sync()
        XCTAssertTrue(m.ledger.pending.isEmpty); XCTAssertTrue(sent().isEmpty)
        src.library = [.init(id: "c", created: at(30))]; src.exportError = ScreenshotSourceError.exportFailed("disk")
        for i in 0..<ScreenshotLedger.maxHardFailures { clock = at(40 + Double(i) * 1000); await m.sync() }
        XCTAssertTrue(m.ledger.pending.isEmpty)
    }

    func testPermissionDeniedLimitedAndPrompt() async {
        let src = FakeShots(); src.state = .denied
        let (m, _) = make(src)
        await m.refresh()
        XCTAssertEqual(m.access, .denied); XCTAssertTrue(m.needsSettings)
        XCTAssertEqual(src.observing, 0)
        XCTAssertNil(m.ledger.enabledAt)
        src.state = .limited; await m.refresh()
        XCTAssertTrue(m.statusLine.contains("Full Access")); XCTAssertTrue(m.needsSettings)
        XCTAssertNil(m.ledger.enabledAt)
        src.state = .notDetermined; src.afterPrompt = .full; clock = at(50); await m.refresh()
        XCTAssertEqual(src.prompts, 1); XCTAssertEqual(m.access, .full)
        XCTAssertEqual(m.ledger.enabledAt, at(50))                // baseline starts when access was granted
        XCTAssertFalse(m.needsSettings)
    }

    func testSwitchOffStopsAndClearsQueueAndOnRestartsBaseline() async {
        let src = FakeShots(); let defaults = MemoryDefaults()
        let (m, sent) = make(src, defaults: defaults, failing: { URLError(.timedOut) })
        await m.refresh()
        src.library = [.init(id: "a", created: at(10))]; clock = at(20); await m.sync()
        XCTAssertEqual(m.ledger.pending.count, 1)
        m.setEnabled(false)
        XCTAssertTrue(m.ledger.pending.isEmpty); XCTAssertFalse(m.ledger.isActive)
        XCTAssertGreaterThan(src.stops, 0)
        XCTAssertEqual(defaults.bool("screenshotUpload"), false)
        await m.sync()
        XCTAssertTrue(sent().isEmpty)
        XCTAssertTrue(m.statusLine.hasPrefix("Off"))
        XCTAssertFalse(ScreenshotSyncModel(source: src, defaults: defaults).enabled)   // persisted
        clock = at(500); m.setEnabled(true)
        for _ in 0..<50 where m.ledger.enabledAt == nil { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(m.ledger.enabledAt, at(500))
        XCTAssertTrue(m.ledger.pending.isEmpty)                   // the one from the off period is not resurrected
    }

    func testDefaultsToOnAndLibraryChangeTriggersUpload() async {
        let src = FakeShots()
        let (m, sent) = make(src)
        XCTAssertTrue(m.enabled)
        await m.refresh()
        src.library = [.init(id: "x", created: at(10))]; clock = at(11)
        src.onChange?()                                           // what PHPhotoLibraryChangeObserver does
        for _ in 0..<100 where sent().isEmpty { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(sent().count, 1)
    }

    func testOverlappingSyncCallsDoNotDoubleUpload() async {
        let src = FakeShots(); let (m, sent) = make(src)
        await m.refresh()
        src.library = [.init(id: "a", created: at(10))]; clock = at(20)
        async let one: Void = m.sync(); async let two: Void = m.sync()
        _ = await (one, two)
        XCTAssertEqual(sent().count, 1)
    }
}
