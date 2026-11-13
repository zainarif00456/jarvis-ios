import XCTest
@testable import JarvisCore

final class ScreenshotLedgerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func shot(_ id: String, _ s: Double, screenshot: Bool = true) -> ScreenshotCandidate { ScreenshotCandidate(id: id, created: at(s), isScreenshot: screenshot) }

    func testNothingQueuedBeforeEnabled() {
        var l = ScreenshotLedger()
        XCTAssertEqual(l.ingest([shot("a", 10)]), 0)          // not active
        l.enable(now: at(100))
        XCTAssertEqual(l.ingest([shot("old", 50), shot("same", 100), shot("new", 101)]), 1)   // first run: old photos ignored
        XCTAssertEqual(l.pending.map(\.id), ["new"])
    }

    func testOnlyScreenshotsAndNoDuplicates() {
        var l = ScreenshotLedger(); l.enable(now: at(0))
        XCTAssertEqual(l.ingest([shot("photo", 5, screenshot: false), shot("s1", 6)]), 1)
        XCTAssertEqual(l.ingest([shot("s1", 6)]), 0)           // already queued
        l.markUploaded("s1", now: at(20))
        XCTAssertEqual(l.ingest([shot("s1", 6)]), 0)           // already uploaded
        XCTAssertEqual(l.totalUploaded, 1)
        XCTAssertEqual(l.lastUploadedAt, at(20))
    }

    func testOrderedByCreationAndHeadBlocksUntilRetryTime() {
        var l = ScreenshotLedger(); l.enable(now: at(0))
        l.ingest([shot("b", 30), shot("a", 10), shot("c", 20)])
        XCTAssertEqual(l.pending.map(\.id), ["a", "c", "b"])
        XCTAssertEqual(l.next(now: at(40))?.id, "a")
        XCTAssertTrue(l.markRetry("a", now: at(40), message: "offline", hard: false, delay: 5))
        XCTAssertNil(l.next(now: at(42)))                      // head waits, c and b do not jump the queue
        XCTAssertEqual(l.nextDue(now: at(42)), at(45))
        XCTAssertEqual(l.next(now: at(45))?.id, "a")
        l.markUploaded("a", now: at(45))
        XCTAssertEqual(l.next(now: at(45))?.id, "c")
    }

    func testNetworkFailuresNeverDropButHardFailuresDo() {
        var l = ScreenshotLedger(); l.enable(now: at(0)); l.ingest([shot("a", 1)])
        for _ in 0..<50 { XCTAssertTrue(l.markRetry("a", now: at(2), message: "offline", hard: false, delay: 1)) }
        XCTAssertEqual(l.pending.count, 1)
        for i in 1..<ScreenshotLedger.maxHardFailures { XCTAssertTrue(l.markRetry("a", now: at(2), message: "bad", hard: true, delay: 1), "\(i)") }
        XCTAssertFalse(l.markRetry("a", now: at(2), message: "bad", hard: true, delay: 1))
        XCTAssertTrue(l.pending.isEmpty)
        XCTAssertEqual(l.lastError, "bad")
    }

    func testHardFailureDropRemembersTheIdSoItIsNotRequeued() {
        var l = ScreenshotLedger(); l.enable(now: at(0)); l.ingest([shot("a", 1)])
        for _ in 0..<ScreenshotLedger.maxHardFailures { l.markRetry("a", now: at(2), message: "bad", hard: true, delay: 1) }
        XCTAssertTrue(l.pending.isEmpty)
        XCTAssertEqual(l.ingest([shot("a", 1)]), 0)
        XCTAssertTrue(l.pending.isEmpty)
        XCTAssertEqual(l.totalUploaded, 0)
    }

    func testRebaseSkipsScreenshotsTakenWhileAccessWasLost() {
        var l = ScreenshotLedger(); l.enable(now: at(0))
        l.rebase(now: at(100))
        XCTAssertEqual(l.ingest([shot("gap", 50), shot("new", 150)]), 1)
        XCTAssertEqual(l.pending.map { $0.id }, ["new"])
        var off = ScreenshotLedger(); off.rebase(now: at(5)); XCTAssertNil(off.enabledAt)
    }

    func testDropRemembersTheIdSoItIsNotQueuedAgain() {
        var l = ScreenshotLedger(); l.enable(now: at(0)); l.ingest([shot("a", 1)])
        l.drop("a", message: "gone")
        XCTAssertEqual(l.ingest([shot("a", 1)]), 0)
        XCTAssertEqual(l.totalUploaded, 0)
    }

    func testReleaseWaitingMakesEverythingDueNow() {
        var l = ScreenshotLedger(); l.enable(now: at(0)); l.ingest([shot("a", 1)])
        l.markRetry("a", now: at(2), message: "offline", hard: false, delay: 300)
        XCTAssertNil(l.next(now: at(3)))
        l.releaseWaiting()
        XCTAssertEqual(l.next(now: at(3))?.id, "a")
    }

    func testDisableClearsQueueAndRestartsBaseline() {
        var l = ScreenshotLedger(); l.enable(now: at(0)); l.ingest([shot("a", 1)])
        l.disable()
        XCTAssertTrue(l.pending.isEmpty); XCTAssertFalse(l.isActive)
        XCTAssertEqual(l.ingest([shot("b", 5)]), 0)
        l.enable(now: at(100))                                  // screenshots from the off period are never sent
        XCTAssertEqual(l.ingest([shot("b", 5), shot("c", 150)]), 1)
        l.enable(now: at(500))                                  // enabling twice keeps the first date
        XCTAssertEqual(l.enabledAt, at(100))
    }

    func testTrimKeepsDuplicateProtectionThroughTheFloor() {
        var l = ScreenshotLedger(); l.enable(now: at(0))
        let n = ScreenshotLedger.maxUploadedKept + 5
        for i in 1...n { l.ingest([shot("id\(i)", Double(i))]); l.markUploaded("id\(i)", now: at(Double(i))) }
        XCTAssertEqual(l.uploaded.count, ScreenshotLedger.maxUploadedKept)
        XCTAssertNotNil(l.trimFloor)
        XCTAssertEqual(l.ingest([shot("id1", 1), shot("id2", 2)]), 0)   // forgotten ids are still refused
        XCTAssertEqual(l.ingest([shot("fresh", Double(n + 1))]), 1)
    }

    func testPersistenceRoundTripAndGarbage() {
        var l = ScreenshotLedger(); l.enable(now: at(0)); l.ingest([shot("a", 1), shot("b", 2)])
        l.markUploaded("a", now: at(9)); l.markRetry("b", now: at(10), message: "x", hard: false, delay: 5)
        let text = l.encoded()
        XCTAssertNotNil(text)
        XCTAssertEqual(ScreenshotLedger.decode(text), l)
        XCTAssertEqual(ScreenshotLedger.decode("not json"), ScreenshotLedger())
        XCTAssertEqual(ScreenshotLedger.decode(nil), ScreenshotLedger())
    }

    func testRetryDelaysGrowAndCap() {
        XCTAssertEqual(ScreenshotRetry.delay(attempt: 1), 5)
        XCTAssertEqual(ScreenshotRetry.delay(attempt: 3), 45)
        XCTAssertEqual(ScreenshotRetry.delay(attempt: 99), 300)
        XCTAssertEqual(ScreenshotRetry.delay(attempt: 0), 5)
    }

    func testFileNames() {
        let utc = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 1_794_568_865)
        XCTAssertEqual(ScreenshotNaming.fileName(created: d, ext: "PNG", timeZone: utc), "Screenshot 2026-11-13 11.21.05.png")
        XCTAssertEqual(ScreenshotNaming.fileName(created: d, ext: "", timeZone: utc), "Screenshot 2026-11-13 11.21.05.png")
        XCTAssertEqual(ScreenshotNaming.mime(forExtension: "PNG"), "image/png")
        XCTAssertEqual(ScreenshotNaming.mime(forExtension: "heic"), "image/heic")
    }

    func testStatusLines() {
        var l = ScreenshotLedger(); l.enable(now: at(0))
        let now = at(3600)
        XCTAssertTrue(ScreenshotStatusText.line(enabled: false, access: .full, ledger: l, now: now).hasPrefix("Off"))
        XCTAssertTrue(ScreenshotStatusText.line(enabled: true, access: .denied, ledger: l, now: now).contains("Photos access is off"))
        XCTAssertTrue(ScreenshotStatusText.line(enabled: true, access: .limited, ledger: l, now: now).contains("Full Access"))
        XCTAssertTrue(ScreenshotStatusText.line(enabled: true, access: .restricted, ledger: l, now: now).contains("restricted"))
        XCTAssertEqual(ScreenshotStatusText.line(enabled: true, access: .full, ledger: l, now: now), "No screenshot sent yet.")
        l.ingest([shot("a", 10), shot("b", 20)]); l.markUploaded("a", now: at(3000))
        l.markRetry("b", now: at(3001), message: "Offline", hard: false, delay: 5)
        let s = ScreenshotStatusText.line(enabled: true, access: .full, ledger: l, now: now, connected: false)
        XCTAssertEqual(s, "Last sent 10 min ago. 1 waiting. Problem: Offline. will send when Jarvis is reachable.")
    }
}
