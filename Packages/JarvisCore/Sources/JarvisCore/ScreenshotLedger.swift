import Foundation

/// One photo-library item as the PhotoKit layer reports it: an opaque asset id, when it was created and whether the
/// library flagged it as a screenshot (`PHAssetMediaSubtype.photoScreenshot`).
public struct ScreenshotCandidate: Equatable, Sendable {
    public var id: String
    public var created: Date
    public var isScreenshot: Bool
    public init(id: String, created: Date, isScreenshot: Bool = true) { self.id = id; self.created = created; self.isScreenshot = isScreenshot }
}

public struct PendingScreenshot: Codable, Equatable, Sendable {
    public var id: String
    public var created: Date
    /// Tries so far (drives the retry delay).
    public var attempts = 0
    /// Tries that failed for a reason that is not "the network is down" (cannot read the asset...). Too many drop the item.
    public var hardFailures = 0
    public var notBefore: Date?
    public var lastError: String?
    public init(id: String, created: Date) { self.id = id; self.created = created }
}

public struct UploadedScreenshot: Codable, Equatable, Sendable {
    public var id: String
    public var created: Date
}

/// The decision logic of "upload every new screenshot exactly once, in order, surviving relaunches", with no
/// PhotoKit and no networking. The PhotoKit layer feeds it candidates; the sync model asks it what to upload next and
/// reports back. Everything is `Codable` so the whole state is one JSON string in UserDefaults.
///
/// Rules:
/// - Nothing older than `enabledAt` is ever queued (first run never uploads old photos). Turning the feature off clears
///   `enabledAt` and the queue, so screenshots taken while it was off are never sent later.
/// - Only candidates flagged as screenshots are queued.
/// - An id that was uploaded, or is queued, is never queued again. The uploaded list is capped; when it is trimmed, the
///   creation date of the oldest forgotten entry becomes `trimFloor`, and nothing at or before it is queued, so a
///   forgotten id can not be re-uploaded.
/// - The queue is ordered by creation date; the head blocks the rest until its retry time (order is preserved), unless
///   it is dropped for good.
public struct ScreenshotLedger: Codable, Equatable, Sendable {
    public static let maxUploadedKept = 1000
    public static let maxHardFailures = 5

    public var enabledAt: Date?
    public var trimFloor: Date?
    public private(set) var uploaded: [UploadedScreenshot] = []
    public private(set) var pending: [PendingScreenshot] = []
    public var lastUploadedAt: Date?
    public var lastError: String?
    public private(set) var totalUploaded = 0

    public init() {}

    public var isActive: Bool { enabledAt != nil }

    /// Starts watching from `now`. A no-op when already active (the original start date stays).
    public mutating func enable(now: Date) { if enabledAt == nil { enabledAt = now; lastError = nil } }

    /// Stops watching and forgets the queue. The uploaded ids stay (they only guard against duplicates).
    public mutating func disable() { enabledAt = nil; pending = []; lastError = nil }

    /// Where a library query should start: never before the start date or the trim floor (trimFloor).
    public var queryStart: Date? {
        guard let e = enabledAt else { return nil }
        if let f = trimFloor { return max(e, f) }
        return e
    }

    private func known(_ id: String) -> Bool { uploaded.contains { $0.id == id } || pending.contains { $0.id == id } }

    /// Queues the new screenshots among `candidates` and returns how many were added.
    @discardableResult
    public mutating func ingest(_ candidates: [ScreenshotCandidate]) -> Int {
        guard let start = queryStart else { return 0 }
        var added = 0
        for c in candidates.sorted(by: { $0.created < $1.created }) {
            guard c.isScreenshot, c.created > start, !known(c.id) else { continue }
            pending.append(PendingScreenshot(id: c.id, created: c.created)); added += 1
        }
        if added > 0 { pending.sort { ($0.created, $0.id) < ($1.created, $1.id) } }
        return added
    }

    /// The next one to upload, or nil when the queue is empty or the head is waiting for its retry time.
    public func next(now: Date) -> PendingScreenshot? {
        guard let head = pending.first else { return nil }
        if let t = head.notBefore, t > now { return nil }
        return head
    }

    /// When the head becomes due again (nil when empty or due now).
    public func nextDue(now: Date) -> Date? {
        guard let t = pending.first?.notBefore, t > now else { return nil }
        return t
    }

    public mutating func markUploaded(_ id: String, now: Date) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: i)
        if !uploaded.contains(where: { $0.id == id }) { uploaded.append(UploadedScreenshot(id: id, created: item.created)) }
        totalUploaded += 1
        lastUploadedAt = now
        lastError = nil
        trim()
    }

    /// The upload will be tried again later. `hard` is true for failures that are not network trouble.
    /// Returns false when the item was dropped (too many hard failures).
    @discardableResult
    public mutating func markRetry(_ id: String, now: Date, message: String, hard: Bool, delay: TimeInterval) -> Bool {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return true }
        pending[i].attempts += 1
        if hard { pending[i].hardFailures += 1 }
        pending[i].lastError = message
        lastError = message
        if pending[i].hardFailures >= Self.maxHardFailures {
            pending.remove(at: i)
            return false
        }
        pending[i].notBefore = now.addingTimeInterval(delay)
        return true
    }

    /// The asset is gone or can never be sent: forget it (and remember it so a later scan does not queue it again).
    public mutating func drop(_ id: String, message: String) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: i)
        if !uploaded.contains(where: { $0.id == id }) { uploaded.append(UploadedScreenshot(id: id, created: item.created)) }
        lastError = message
        trim()
    }

    /// Makes every waiting item due now (network came back, app returned to the foreground).
    public mutating func releaseWaiting() { for i in pending.indices { pending[i].notBefore = nil } }

    private mutating func trim() {
        guard uploaded.count > Self.maxUploadedKept else { return }
        uploaded.sort { $0.created < $1.created }
        let cut = uploaded.count - Self.maxUploadedKept
        let newFloor = uploaded[cut - 1].created
        trimFloor = max(trimFloor ?? newFloor, newFloor)
        uploaded.removeFirst(cut)
    }

    // MARK: persistence

    public func encoded() -> String? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func decode(_ text: String?) -> ScreenshotLedger {
        guard let text = text, let data = text.data(using: .utf8) else { return ScreenshotLedger() }
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(ScreenshotLedger.self, from: data)) ?? ScreenshotLedger()
    }
}

/// Retry delay for the nth failed try of one screenshot (1-based): 5 s, 15 s, 45 s, 2 min, then 5 min.
public enum ScreenshotRetry {
    public static func delay(attempt: Int) -> TimeInterval {
        let table: [TimeInterval] = [5, 15, 45, 120, 300]
        return table[max(0, min(attempt - 1, table.count - 1))]
    }
}

public enum ScreenshotNaming {
    /// `Screenshot 2026-11-13 11.21.05.png`, from the capture time (fixed format so the media library sorts by name too).
    public static func fileName(created: Date, ext: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let clean = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        return "Screenshot \(f.string(from: created)).\(clean.isEmpty ? "png" : clean)"
    }
    public static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        default: return "application/octet-stream"
        }
    }
}

public enum ScreenshotAccess: Equatable, Sendable { case notDetermined, full, limited, denied, restricted
    /// Can new screenshots be seen? Limited access shows only photos the owner picked, so new screenshots are not visible.
    public var canWatch: Bool { self == .full }
}

/// The one status line under the Settings switch.
public enum ScreenshotStatusText {
    public static func line(enabled: Bool, access: ScreenshotAccess, ledger: ScreenshotLedger, now: Date, connected: Bool = true) -> String {
        guard enabled else { return "Off. Screenshots stay on the phone." }
        switch access {
        case .denied: return "Photos access is off for Jarvis. Turn it on in Settings > Jarvis > Photos so screenshots can be sent."
        case .restricted: return "Photos access is restricted on this iPhone (Screen Time or a profile), so screenshots cannot be sent."
        case .limited: return "Photos access is limited to the photos you picked. Choose \"Full Access\" in Settings > Jarvis > Photos so new screenshots can be seen."
        case .notDetermined: return "Waiting for your answer to the Photos permission question."
        case .full: break
        }
        var parts: [String] = []
        if let t = ledger.lastUploadedAt { parts.append("Last sent \(relative(t, now: now))") } else { parts.append("No screenshot sent yet") }
        let queued = ledger.pending.count
        if queued > 0 { parts.append("\(queued) waiting") }
        if let e = ledger.lastError, queued > 0 || ledger.lastUploadedAt == nil { parts.append("Problem: \(e)") }
        else if let e = ledger.lastError { parts.append("Last problem: \(e)") }
        if !connected && queued > 0 { parts.append("will send when Jarvis is reachable") }
        return parts.joined(separator: ". ") + "."
    }

    static func relative(_ t: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(t))
        if s < 10 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }
}
