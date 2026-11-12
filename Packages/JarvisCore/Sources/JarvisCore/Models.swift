import Foundation

// Strict-enough Codable models for what the server sends. Every field the app does not strictly need is
// optional, and unknown fields are ignored, so a server upgrade cannot break decoding.

public struct TaskInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String?
    public var owner: String?
    public var name: String?
    public var title: String?
    public var status: String
    public var progress: Double?
    public var startedAt: String?
    public var finishedAt: String?
    public var elapsedS: Double?
    public var summary: String?
    public var error: String?
    enum CodingKeys: String, CodingKey {
        case id, kind, owner, name, title, status, progress, summary, error
        case startedAt = "started_at", finishedAt = "finished_at", elapsedS = "elapsed_s"
    }
    public var isActive: Bool { ["running", "queued", "waiting_approval", "starting"].contains(status) }
    public var isFinished: Bool { ["done", "failed", "cancelled", "lost"].contains(status) }
}

public struct ApprovalInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var tool: String?
    public var tier: Int?
    public var what: String?
    public var reasons: [String]?
    public var expiresAt: String?
    enum CodingKeys: String, CodingKey { case id, tool, tier, what, reasons, expiresAt = "expires_at" }
}

public struct FileInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var mime: String
    public var size: Int
    public var owner: String?
    public var taskId: String?
    public var kind: String?
    public var createdAt: String?
    enum CodingKeys: String, CodingKey { case id, name, description, mime, size, owner, kind, taskId = "task_id", createdAt = "created_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "file"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        mime = (try? c.decode(String.self, forKey: .mime)) ?? "application/octet-stream"
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        taskId = try? c.decodeIfPresent(String.self, forKey: .taskId)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
    }
    public var isImage: Bool { mime.hasPrefix("image/") }
    public var isPDF: Bool { mime == "application/pdf" }
    public var isVideo: Bool { mime.hasPrefix("video/") }
    public var isTextual: Bool {
        mime.hasPrefix("text/") || ["application/json", "application/xml", "application/x-yaml", "application/toml",
                                    "application/javascript", "application/x-sh"].contains(mime)
    }
}

public struct CameraInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String?
    public var `where`: String?
    public var address: String?
    public var note: String?
    public var recording: Bool?
    public var hasVideo: Bool?
    public var sound: Bool?
    public var state: String?
    public var detail: String?
    public var audio: Bool?
    public var viewers: Int?
    enum CodingKeys: String, CodingKey {
        case id, name, kind, `where`, address, note, recording, sound, state, detail, audio, viewers
        case hasVideo = "has_video"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        `where` = try? c.decodeIfPresent(String.self, forKey: .where)
        address = try? c.decodeIfPresent(String.self, forKey: .address)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        recording = try? c.decodeIfPresent(Bool.self, forKey: .recording)
        hasVideo = try? c.decodeIfPresent(Bool.self, forKey: .hasVideo)
        sound = try? c.decodeIfPresent(Bool.self, forKey: .sound)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        audio = try? c.decodeIfPresent(Bool.self, forKey: .audio)
        viewers = try? c.decodeIfPresent(Int.self, forKey: .viewers)
    }
    public var canShowVideo: Bool { hasVideo ?? true }
}

public struct CamerasResponse: Codable, Sendable {
    public var cameras: [CameraInfo]
    public var ffmpeg: Bool?
}

public struct MediaItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var fullId: String?
    public var kind: String?
    public var name: String?
    public var mime: String?
    public var source: String?
    public var note: String?
    public var origin: String?
    public var path: String?
    public var size: Int?
    public var width: Int?
    public var height: Int?
    public var durationS: Double?
    public var createdAt: String?
    public var artifact: String?
    enum CodingKeys: String, CodingKey {
        case id, kind, name, mime, source, note, origin, path, size, width, height, artifact
        case fullId = "full_id", durationS = "duration_s", createdAt = "created_at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(LooseString.self, forKey: .id).value) ?? ""
        fullId = try? c.decodeIfPresent(String.self, forKey: .fullId)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        mime = try? c.decodeIfPresent(String.self, forKey: .mime)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        origin = try? c.decodeIfPresent(String.self, forKey: .origin)
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        size = try? c.decodeIfPresent(Int.self, forKey: .size)
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        durationS = try? c.decodeIfPresent(Double.self, forKey: .durationS)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        artifact = try? c.decodeIfPresent(String.self, forKey: .artifact)
    }
}

public struct MediaResponse: Codable, Sendable { public var media: [MediaItem] }

public struct TerminalInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var cwd: String?
    public var closed: Bool?
    public var busy: Bool?
    public var password: Bool?
    public var by: String?
    public var running: String?
    public var cols: Int?
    public var rows: Int?
}

public struct AgentsStatus: Codable, Equatable, Sendable {
    public struct Agent: Codable, Equatable, Sendable, Identifiable {
        public var key: String
        public var name: String?
        public var role: String?
        public var available: Bool?
        public var detail: String?
        public var warm: Bool?
        public var active: Bool?
        public var model: String?
        public var id: String { key }
    }
    public var enabled: Bool?
    public var active: String?
    public var agents: [Agent]?
}

public struct StatusInfo: Codable, Equatable, Sendable {
    public var spentUsd: Double?
    public var budgetUsd: Double?
    public var queued: Int?
    public var busy: Bool?
    enum CodingKeys: String, CodingKey { case spentUsd = "spent_usd", budgetUsd = "budget_usd", queued, busy }
}

public struct ScheduleItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String?
    public var status: String?
    public var mode: String?
    public var agent: String?
    public var skill: String?
    public var priority: String?
    public var report: String?
    public var triggerText: String?
    public var nextRunAt: String?
    public var nextText: String?
    public var lastRunAt: String?
    public var secondsUntil: Int?
    public var runCount: Int?
    public var maxRuns: Int?
    public var repeats: Bool?
    public var watchFor: String?
    public var tz: String?
    enum CodingKeys: String, CodingKey {
        case id, title, description, status, mode, agent, skill, priority, report, repeats, tz
        case triggerText = "trigger_text", nextRunAt = "next_run_at", nextText = "next_text", lastRunAt = "last_run_at"
        case secondsUntil = "seconds_until", runCount = "run_count", maxRuns = "max_runs", watchFor = "watch_for"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(LooseString.self, forKey: .id).value) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        agent = try? c.decodeIfPresent(String.self, forKey: .agent)
        skill = try? c.decodeIfPresent(String.self, forKey: .skill)
        priority = try? c.decodeIfPresent(String.self, forKey: .priority)
        report = try? c.decodeIfPresent(String.self, forKey: .report)
        triggerText = try? c.decodeIfPresent(String.self, forKey: .triggerText)
        nextRunAt = try? c.decodeIfPresent(String.self, forKey: .nextRunAt)
        nextText = try? c.decodeIfPresent(String.self, forKey: .nextText)
        lastRunAt = try? c.decodeIfPresent(String.self, forKey: .lastRunAt)
        secondsUntil = try? c.decodeIfPresent(Int.self, forKey: .secondsUntil)
        runCount = try? c.decodeIfPresent(Int.self, forKey: .runCount)
        maxRuns = try? c.decodeIfPresent(Int.self, forKey: .maxRuns)
        repeats = try? c.decodeIfPresent(Bool.self, forKey: .repeats)
        watchFor = try? c.decodeIfPresent(String.self, forKey: .watchFor)
        tz = try? c.decodeIfPresent(String.self, forKey: .tz)
    }
}

public struct ScheduleRun: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var status: String?
    public var dueAt: String?
    public var finishedAt: String?
    public var result: String?
    public var error: String?
    enum CodingKeys: String, CodingKey { case id, title, status, result, error, dueAt = "due_at", finishedAt = "finished_at" }
}

public struct ScheduleState: Codable, Equatable, Sendable {
    public struct Scheduler: Codable, Equatable, Sendable {
        public var ok: Bool?
        public var ageS: Int?
        public var ntfy: Bool?
        public var tz: String?
        enum CodingKeys: String, CodingKey { case ok, ageS = "age_s", ntfy, tz }
    }
    public var items: [ScheduleItem]
    public var scheduler: Scheduler?
    public var waiting: [JSONValue]?
    public init(items: [ScheduleItem], scheduler: Scheduler?, waiting: [JSONValue]?) { self.items = items; self.scheduler = scheduler; self.waiting = waiting }
}

public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public var number: Int
    public var startedAt: String?
    public var endedAt: String?
    public var reason: String?
    public var ownerMessages: Int?
    public var notes: String?
    public var current: Bool?
    public var id: Int { number }
    enum CodingKeys: String, CodingKey { case number, reason, notes, current, startedAt = "started_at", endedAt = "ended_at", ownerMessages = "owner_messages" }
}

public struct SessionMatch: Codable, Equatable, Sendable {
    public var session: Int?
    public var ts: String?
    public var who: String?
    public var text: String?
}

public struct RecordingCard: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var kind: String?
    public var state: String?
    public var sounds: [String]?
    public var capturedS: Double?
    public var doneS: Double?
    public var runningSince: Double?
    public var file: String?
    public var mediaId: String?
    public var note: String?
    public var line: String?
    enum CodingKeys: String, CodingKey { case id, name, kind, state, sounds, file, note, line
        case capturedS = "captured_s", doneS = "done_s", runningSince = "running_since", mediaId = "media_id" }
    public var isLive: Bool { ["starting", "recording", "paused", "stopping", "saving"].contains(state ?? "") }
}

public struct VoiceCatalog: Codable, Equatable, Sendable {
    public struct Voice: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String?
        public var accent: String?
        public var gender: String?
    }
    public var voice: String?
    public var speed: Double?
    public var voices: [Voice]?
}

public struct UploadResult: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var size: Int?
    public var mime: String?
    public var duplicate: Bool?
}

public struct DeviceInfoResponse: Codable, Equatable, Sendable {
    public var device: String?
    public var kind: String?
    public var version: String?
}

public struct WelcomeInfo: Equatable, Sendable {
    public var device: String?
    public var serverVersion: String?
    public var status: StatusInfo?
    public var tasks: [TaskInfo] = []
    public var approvals: [ApprovalInfo] = []
    public var files: [FileInfo] = []
    public var cameras: [CameraInfo] = []
    public var terminals: [TerminalInfo] = []
    public var schedules: ScheduleState?
    public var agents: AgentsStatus?
    public var history: [HistoryItem] = []
    public var busy: Bool = false
    public var sessionNumber: Int?
}

/// One row of the conversation as the server stores it (`GET /api/history`, `welcome.history`).
public struct HistoryItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var seq: Int?
    public var ts: String?
    public var turn: String?
    public var kind: String          // message | command | task | approval | note | session | file
    public var role: String?         // user | assistant | agent
    public var name: String?
    public var agent: String?
    public var persona: String?
    public var text: String?
    public var interrupted: Bool?
    public var failed: Bool?
    public var greeting: Bool?
    public var heard: String?
    public var tools: [String]?
    public var result: String?
    public var event: String?
    public var taskId: String?
    public var owner: String?
    public var title: String?
    public var status: String?
    public var summary: String?
    public var error: String?
    public var tool: String?
    public var what: String?
    public var by: String?
    public var number: Int?
    public var reason: String?
    public var file: FileInfo?
    public var final: Bool?
    enum CodingKeys: String, CodingKey {
        case id, seq, ts, turn, kind, role, name, agent, persona, text, interrupted, failed, greeting, heard, tools
        case result, event, title, status, summary, error, tool, what, by, number, reason, file, final, owner
        case taskId = "task_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? c.decode(LooseString.self, forKey: .id).value
        seq = try? c.decodeIfPresent(Int.self, forKey: .seq)
        id = rawId ?? (seq.map { "seq-\($0)" } ?? UUID().uuidString)
        ts = try? c.decodeIfPresent(String.self, forKey: .ts)
        turn = try? c.decodeIfPresent(String.self, forKey: .turn)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "note"
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        agent = try? c.decodeIfPresent(String.self, forKey: .agent)
        persona = try? c.decodeIfPresent(String.self, forKey: .persona)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        interrupted = try? c.decodeIfPresent(Bool.self, forKey: .interrupted)
        failed = try? c.decodeIfPresent(Bool.self, forKey: .failed)
        greeting = try? c.decodeIfPresent(Bool.self, forKey: .greeting)
        heard = try? c.decodeIfPresent(String.self, forKey: .heard)
        tools = try? c.decodeIfPresent([String].self, forKey: .tools)
        result = try? c.decodeIfPresent(String.self, forKey: .result)
        event = try? c.decodeIfPresent(String.self, forKey: .event)
        taskId = try? c.decodeIfPresent(String.self, forKey: .taskId)
        owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        tool = try? c.decodeIfPresent(String.self, forKey: .tool)
        what = try? c.decodeIfPresent(String.self, forKey: .what)
        by = try? c.decodeIfPresent(String.self, forKey: .by)
        number = try? c.decodeIfPresent(Int.self, forKey: .number)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        file = try? c.decodeIfPresent(FileInfo.self, forKey: .file)
        final = try? c.decodeIfPresent(Bool.self, forKey: .final)
    }
}

public struct HistoryResponse: Codable, Sendable {
    public var items: [HistoryItem]
    public init(items: [HistoryItem]) { self.items = items }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = LossyArray<HistoryItem>.decode(c, .items)
    }
    enum CodingKeys: String, CodingKey { case items }
}

/// Decodes an array and drops elements that fail, instead of failing the whole array.
enum LossyArray<T: Decodable> {
    struct Box: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [T] {
        ((try? c.decodeIfPresent([Box].self, forKey: key)) ?? nil)?.compactMap { $0.value } ?? []
    }
}
