import Foundation

/// One row of the chat / activity timeline.
public struct TimelineEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user, assistant, agent, command, task, approval, note, session, file, caption
    }
    public var id: String
    public var kind: Kind
    public var name: String
    public var persona: String          // jarvis | friday | edith | veronica | you
    public var text: String
    public var ts: Date?
    public var turn: String?
    public var seq: Int?
    public var streaming = false
    public var interrupted = false
    public var failed = false
    public var fromVoice = false
    public var tools: [String] = []
    public var detail: String?          // command result, task summary, ...
    public var status: String?
    public var taskId: String?
    public var file: FileInfo?
    public init(id: String, kind: Kind, name: String = "", persona: String = "jarvis", text: String = "", ts: Date? = nil, turn: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.persona = persona; self.text = text; self.ts = ts; self.turn = turn
    }
}

/// Folds history rows and live server messages into the timeline. Pure: the view model owns one of these.
public struct TimelineReducer: Sendable {
    public private(set) var entries: [TimelineEntry] = []
    public private(set) var caption: String = ""
    public private(set) var busy = false
    public private(set) var hasOlder = false
    private var localCounter = 0
    private var lastUserText: (text: String, at: Date)?

    public static let pageSize = 60
    public init() {}

    // MARK: history

    public mutating func setHistory(_ items: [HistoryItem], pageSize: Int = TimelineReducer.pageSize) {
        entries = items.compactMap(Self.entry(from:))
        hasOlder = items.count >= pageSize
        caption = ""
    }

    /// Older rows (from `GET /api/history?before=`) go in front; duplicates are dropped.
    public mutating func prepend(_ items: [HistoryItem], pageSize: Int = TimelineReducer.pageSize) {
        let have = Set(entries.map { $0.id })
        let older = items.compactMap(Self.entry(from:)).filter { !have.contains($0.id) }
        entries.insert(contentsOf: older, at: 0)
        hasOlder = items.count >= pageSize
    }

    public var oldestSeq: Int? { entries.compactMap { $0.seq }.min() }

    public static func entry(from h: HistoryItem) -> TimelineEntry? {
        guard var e = build(from: h) else { return nil }
        e.seq = h.seq
        return e
    }

    private static func build(from h: HistoryItem) -> TimelineEntry? {
        let ts = h.ts.flatMap(Format.parseISO)
        let persona = (h.agent ?? h.persona ?? "jarvis").lowercased()
        switch h.kind {
        case "message":
            switch h.role {
            case "user":
                return TimelineEntry(id: h.id, kind: .user, name: "You", persona: "you", text: h.text ?? "", ts: ts, turn: h.turn)
            case "agent":
                var e = TimelineEntry(id: h.id, kind: .agent, name: h.name ?? persona.capitalized, persona: persona, text: h.text ?? "", ts: ts, turn: h.turn)
                e.taskId = h.taskId
                return e
            default:
                var e = TimelineEntry(id: h.id, kind: .assistant, name: h.name ?? "Jarvis", persona: persona, text: h.text ?? "", ts: ts, turn: h.turn)
                e.interrupted = h.interrupted ?? false; e.failed = h.failed ?? false; e.tools = h.tools ?? []
                if e.interrupted, let heard = h.heard, !heard.isEmpty { e.detail = heard }
                return e
            }
        case "command":
            var e = TimelineEntry(id: h.id, kind: .command, name: "You", persona: "you", text: h.text ?? "", ts: ts)
            e.detail = h.result
            return e
        case "task":
            var e = TimelineEntry(id: h.id, kind: .task, name: h.name ?? "Jarvis", persona: (h.owner ?? persona).lowercased(), text: h.title ?? "", ts: ts)
            e.status = h.event ?? h.status; e.detail = h.summary ?? h.error; e.taskId = h.taskId
            return e
        case "approval":
            var e = TimelineEntry(id: h.id, kind: .approval, name: "Approval", persona: "jarvis", text: h.what ?? h.tool ?? "", ts: ts)
            e.status = h.status; e.detail = h.by
            return e
        case "session":
            return TimelineEntry(id: h.id, kind: .session, name: "Session \(h.number ?? 0)", persona: "jarvis", text: h.text ?? h.reason ?? "", ts: ts)
        case "file":
            var e = TimelineEntry(id: h.id, kind: .file, name: h.file?.owner ?? "Jarvis", persona: "jarvis", text: h.file?.name ?? "file", ts: ts)
            e.file = h.file
            return e
        case "note":
            return TimelineEntry(id: h.id, kind: .note, name: "", persona: "jarvis", text: h.text ?? "", ts: ts)
        default:
            return nil
        }
    }

    // MARK: live messages

    /// Applies a server message. `now` is injectable for tests.
    public mutating func apply(_ m: ServerMessage, now: Date = Date()) {
        switch m {
        case .turnStarted(let turn, let kind, let agent, let voice):
            busy = true
            let persona = (agent ?? "jarvis").lowercased()
            var e = TimelineEntry(id: "turn-\(turn)", kind: .assistant, name: persona == "jarvis" ? "Jarvis" : persona.capitalized, persona: persona, ts: now, turn: turn)
            e.streaming = true; e.fromVoice = voice
            e.detail = nil
            if kind == "greeting" { e.status = "greeting" }
            entries.append(e)
        case .textDelta(let turn, let text):
            update(turn: turn) { $0.text += text }
        case .toolStarted(let turn, _, let name, _):
            update(turn: turn) { if !$0.tools.contains(name) { $0.tools.append(name) } }
        case .toolFinished: break
        case .turnDone(let d):
            busy = false
            if indexOf(turn: d.turnId) == nil {
                var e = TimelineEntry(id: "turn-\(d.turnId)", kind: .assistant, name: "Jarvis", ts: now, turn: d.turnId)
                e.text = d.text
                entries.append(e)
            }
            update(turn: d.turnId) {
                if !d.text.isEmpty { $0.text = d.text }
                $0.streaming = false
                if !d.toolsUsed.isEmpty { $0.tools = d.toolsUsed }
            }
        case .turnFailed(let turn, let message):
            busy = false
            if let t = turn, indexOf(turn: t) != nil {
                update(turn: t) { $0.streaming = false; $0.failed = true; if $0.text.isEmpty { $0.text = message } else { $0.detail = message } }
            } else {
                note(message, now: now, failed: true)
            }
        case .turnInterrupted(let turn):
            busy = false
            if let t = turn { update(turn: t) { $0.streaming = false; $0.interrupted = true } }
            for i in entries.indices where entries[i].streaming { entries[i].streaming = false; entries[i].interrupted = true }
        case .turnQueued(let pos): note("Queued (\(pos) ahead).", now: now)
        case .modelSwitched(let model, let reason):
            note("Jarvis escalated to \(model.replacingOccurrences(of: "claude-", with: "")): \(reason ?? "")", now: now)
        case .userMessage(let text, _):
            addUser(text, now: now, fromVoice: false)
        case .announcement(let text):
            var e = TimelineEntry(id: nextLocalId("ann"), kind: .assistant, name: "Jarvis", text: text, ts: now)
            e.fromVoice = true
            entries.append(e)
        case .agentMessage(let a):
            var e = TimelineEntry(id: nextLocalId("agent"), kind: .agent, name: a.name ?? a.persona.capitalized, persona: a.persona.lowercased(), text: a.text, ts: now)
            e.taskId = a.taskId; e.fromVoice = a.spoken
            entries.append(e)
        case .commandResult(let line, let ok, let text):
            if line.trimmingCharacters(in: .whitespaces) == "/clear" { entries.removeAll(); return }
            var e = TimelineEntry(id: nextLocalId("cmd"), kind: .command, name: "You", persona: "you", text: line, ts: now)
            e.detail = text; e.failed = !ok
            entries.append(e)
        case .taskUpdate(let t):
            if t.isFinished {
                let id = "task-\(t.id)-\(t.status)"
                guard !entries.contains(where: { $0.id == id }) else { return }
                var e = TimelineEntry(id: id, kind: .task, name: t.name ?? "Agent", persona: (t.owner ?? "jarvis").lowercased(), text: t.title ?? "", ts: now)
                e.status = t.status; e.detail = t.summary ?? t.error; e.taskId = t.id
                entries.append(e)
            }
        case .fileAdded(let f):
            let id = "file-\(f.id)"
            guard !entries.contains(where: { $0.id == id }) else { return }
            var e = TimelineEntry(id: id, kind: .file, name: f.owner ?? "Jarvis", text: f.name, ts: now)
            e.file = f
            entries.append(e)
        case .sessionReset(let number, let reason):
            entries.removeAll(); hasOlder = false
            entries.append(TimelineEntry(id: nextLocalId("session"), kind: .session, name: "Session \(number ?? 0)", text: reason ?? "", ts: now))
        case .voicePartial(let t): caption = t
        case .voiceFinal(let t):
            caption = ""
            let spoken = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty { addUser(spoken, now: now, fromVoice: true) }
        case .voiceStop:
            // the owner talked over him: the reply being read is no longer streaming
            break
        case .callEnded, .callStarted: caption = ""
        case .notice(_, let text): if !text.isEmpty { note(text, now: now) }
        default: break
        }
    }

    /// Adds the owner's own typed message at once (the server does not echo it back to the sender).
    public mutating func addLocalUser(_ text: String, now: Date = Date()) { addUser(text, now: now, fromVoice: false, force: true) }

    private mutating func addUser(_ text: String, now: Date, fromVoice: Bool, force: Bool = false) {
        // the same words arriving twice (spoken, then echoed as a message) count once
        if !force, let last = lastUserText, last.text == text, now.timeIntervalSince(last.at) < 6 {
            if fromVoice, let i = entries.lastIndex(where: { $0.kind == .user && $0.text == text }) { entries[i].fromVoice = true }
            return
        }
        lastUserText = (text, now)
        var e = TimelineEntry(id: nextLocalId("user"), kind: .user, name: "You", persona: "you", text: text, ts: now)
        e.fromVoice = fromVoice
        entries.append(e)
    }

    private mutating func note(_ text: String, now: Date, failed: Bool = false) {
        var e = TimelineEntry(id: nextLocalId("note"), kind: .note, text: text, ts: now)
        e.failed = failed
        entries.append(e)
    }

    private func indexOf(turn: String) -> Int? { entries.lastIndex(where: { $0.turn == turn && $0.kind == .assistant }) }
    private mutating func update(turn: String, _ change: (inout TimelineEntry) -> Void) {
        if let i = indexOf(turn: turn) { change(&entries[i]) }
    }
    private mutating func nextLocalId(_ p: String) -> String { localCounter += 1; return "\(p)-local-\(localCounter)" }
}

