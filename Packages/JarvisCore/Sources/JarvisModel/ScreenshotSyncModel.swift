import Foundation
import JarvisCore
import JarvisNet

/// A screenshot copied out of the photo library into a temporary file, ready to upload.
public struct ExportedScreenshot: Sendable {
    public var fileURL: URL
    public var ext: String
    public init(fileURL: URL, ext: String) { self.fileURL = fileURL; self.ext = ext }
}

public enum ScreenshotSourceError: Error, Equatable, LocalizedError {
    /// The photo was deleted (or is no longer visible): never retried.
    case assetMissing
    case exportFailed(String)
    public var errorDescription: String? {
        switch self {
        case .assetMissing: return "The screenshot is no longer in the photo library."
        case .exportFailed(let m): return "Could not read the screenshot: \(m)"
        }
    }
}

public enum ScreenshotUploadError: Error, Equatable, LocalizedError {
    case notConnected
    public var errorDescription: String? { "Not connected to Jarvis." }
}

/// The thin PhotoKit boundary. The iOS app implements it with `PHPhotoLibrary`; tests use a fake.
public protocol ScreenshotSource: AnyObject {
    func access() -> ScreenshotAccess
    /// Asks the system (once; later calls return the current state).
    func requestAccess() async -> ScreenshotAccess
    /// Every image created after `date`, oldest first, with the screenshot flag.
    func candidates(after date: Date) -> [ScreenshotCandidate]
    func export(id: String) async throws -> ExportedScreenshot
    /// Calls `onChange` (any thread) whenever the library changes. Replaces a previous observer.
    func startObserving(_ onChange: @escaping @Sendable () -> Void)
    func stopObserving()
}

/// Used when the platform has no photo library (tests, Linux).
public final class NoScreenshotSource: ScreenshotSource {
    public init() {}
    public func access() -> ScreenshotAccess { .restricted }
    public func requestAccess() async -> ScreenshotAccess { .restricted }
    public func candidates(after date: Date) -> [ScreenshotCandidate] { [] }
    public func export(id: String) async throws -> ExportedScreenshot { throw ScreenshotSourceError.assetMissing }
    public func startObserving(_ onChange: @escaping @Sendable () -> Void) {}
    public func stopObserving() {}
}

/// Uploads every new screenshot to Jarvis (`POST /api/media/upload`, source `iphone-screenshot`) without any manual step.
/// Decisions live in `ScreenshotLedger`; this class connects it to the photo library, the network and the clock.
/// State (switch, queue, uploaded ids) is saved after every change, so it survives relaunches.
@MainActor
public final class ScreenshotSyncModel: ObservableObject {
    static let enabledKey = "screenshotUpload", ledgerKey = "screenshotLedger"
    public static let sourceLabel = "iphone-screenshot"

    @Published public private(set) var enabled: Bool
    @Published public private(set) var access: ScreenshotAccess = .notDetermined
    @Published public private(set) var ledger: ScreenshotLedger
    /// Short text shown for a moment after a successful upload ("Screenshot sent to Jarvis").
    @Published public private(set) var banner: String?
    @Published public private(set) var working = false

    /// Uploads one file: (file, name, mime, source label). Throws `ScreenshotUploadError.notConnected` without a connection.
    public var upload: (URL, String, String, String) async throws -> Void = { _, _, _, _ in throw ScreenshotUploadError.notConnected }
    /// Runs the given work and keeps the app alive for it (the app wraps it in a background task).
    public var runProtected: (@escaping @MainActor () async -> Void) -> Void = { work in Task { await work() } }
    /// One call per uploaded screenshot (the app plays the haptic).
    public var onUploaded: () -> Void = {}
    public var now: () -> Date = { Date() }
    public var sleep: (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }
    public var autoRetry = true
    public var bannerSeconds: TimeInterval = 3

    private let source: ScreenshotSource
    private let defaults: SimpleDefaults
    private var draining = false
    private var again = false
    private var retryTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    @Published public private(set) var connected = true

    public init(source: ScreenshotSource, defaults: SimpleDefaults) {
        self.source = source; self.defaults = defaults
        enabled = defaults.bool(Self.enabledKey) ?? true
        ledger = ScreenshotLedger.decode(defaults.string(Self.ledgerKey))
    }

    public var statusLine: String { ScreenshotStatusText.line(enabled: enabled, access: access, ledger: ledger, now: now(), connected: connected) }
    /// True when the status needs the owner's attention (shows the "Open Settings" button).
    public var needsSettings: Bool { enabled && (access == .denied || access == .limited) }

    // MARK: switch

    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, for: Self.enabledKey)
        if on { Task { await self.refresh() } } else { shutDown() }
    }

    private func shutDown() {
        retryTask?.cancel(); retryTask = nil
        source.stopObserving()
        ledger.disable(); save()
    }

    // MARK: entry points (launch, foreground, network back, library change)

    /// Checks permission (asking the first time), starts watching, queues what was missed and uploads. Safe to call often.
    public func refresh() async {
        guard enabled else { access = source.access(); return }
        var a = source.access()
        if a == .notDetermined { a = await source.requestAccess() }
        access = a
        guard a.canWatch else {
            source.stopObserving()
            if ledger.isActive { ledger.rebase(now: now()); save() }
            return
        }
        ledger.enable(now: now())
        source.startObserving { [weak self] in
            Task { @MainActor [weak self] in self?.libraryChanged() }
        }
        ledger.releaseWaiting()
        save()
        await sync()
    }

    /// The photo library changed (a new screenshot, usually): scan and upload, kept alive in the background.
    public func libraryChanged() {
        guard enabled, access.canWatch else { return }
        runProtected { [weak self] in await self?.sync() }
    }

    /// The network or the Jarvis connection came back.
    public func connectivityChanged() {
        guard enabled, access.canWatch else { return }
        ledger.releaseWaiting(); save()
        runProtected { [weak self] in await self?.sync() }
    }

    // MARK: the work

    /// Scans for new screenshots and uploads the queue in order. Calls overlap safely: a second call asks the running
    /// one to go around again once.
    public func sync() async {
        guard enabled, access.canWatch, let start = ledger.queryStart else { return }
        if draining { again = true; return }
        draining = true; working = true
        defer { draining = false; working = false }
        repeat {
            again = false
            if ledger.ingest(source.candidates(after: start)) > 0 { save() }
            await drain()
        } while again && enabled
        scheduleRetry()
    }

    private func drain() async {
        while enabled, let item = ledger.next(now: now()) {
            if !(await send(item)) { break }
        }
    }

    /// Returns true when the item is finished (uploaded or dropped) so the next may go; false stops the pass.
    private func send(_ item: PendingScreenshot) async -> Bool {
        let exported: ExportedScreenshot
        do { exported = try await source.export(id: item.id) }
        catch ScreenshotSourceError.assetMissing {
            ledger.drop(item.id, message: ScreenshotSourceError.assetMissing.localizedDescription); save(); return true
        } catch {
            return fail(item, error.localizedDescription, hard: true)
        }
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }
        let name = ScreenshotNaming.fileName(created: item.created, ext: exported.ext)
        do {
            try await upload(exported.fileURL, name, ScreenshotNaming.mime(forExtension: exported.ext), Self.sourceLabel)
        } catch is CancellationError {
            return false
        } catch let e as ApiError {
            connected = true
            if e.isTransient { connected = false; return fail(item, e.localizedDescription, hard: false) }
            if e.isUnauthorized { return fail(item, "This phone is no longer paired.", hard: false) }
            if e.statusCode == 413 || e.statusCode == 415 || e.statusCode == 400 {
                ledger.drop(item.id, message: "Jarvis refused the screenshot (\(e.localizedDescription))."); save(); return true
            }
            return fail(item, e.localizedDescription, hard: true)
        } catch ScreenshotUploadError.notConnected {
            connected = false
            return fail(item, "Not connected to Jarvis.", hard: false)
        } catch {
            connected = false           // URLError and friends: network trouble
            return fail(item, error.localizedDescription, hard: false)
        }
        connected = true
        ledger.markUploaded(item.id, now: now()); save()
        onUploaded()
        showBanner("Screenshot sent to Jarvis")
        return true
    }

    private func fail(_ item: PendingScreenshot, _ message: String, hard: Bool) -> Bool {
        let kept = ledger.markRetry(item.id, now: now(), message: message, hard: hard, delay: ScreenshotRetry.delay(attempt: item.attempts + 1))
        save()
        return !kept       // dropped: carry on with the next one; kept: stop here so order is preserved
    }

    private func scheduleRetry() {
        retryTask?.cancel(); retryTask = nil
        guard autoRetry, enabled, let due = ledger.nextDue(now: now()) else { return }
        let wait = due.timeIntervalSince(now())
        retryTask = Task { [weak self] in
            guard let self = self else { return }
            await self.sleep(wait + 0.2)
            if Task.isCancelled { return }
            self.runProtected { [weak self] in await self?.sync() }
        }
    }

    private func showBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            guard let self = self else { return }
            await self.sleep(self.bannerSeconds)
            if !Task.isCancelled { self.banner = nil }
        }
    }

    private func save() {
        if let s = ledger.encoded() { defaults.set(s, for: Self.ledgerKey) }
    }
}
