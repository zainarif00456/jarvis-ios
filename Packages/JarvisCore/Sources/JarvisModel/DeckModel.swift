import Foundation
import JarvisCore
import JarvisNet

/// Everything the browser's deck shows, as observable state: tasks, approvals, files, cameras, media, schedules,
/// terminals, agents, recordings, spend. Fed by the session socket; actions go over REST.
@MainActor
public final class DeckModel: ObservableObject {
    @Published public private(set) var tasks: [TaskInfo] = []
    @Published public private(set) var approvals: [ApprovalInfo] = []
    @Published public private(set) var files: [FileInfo] = []
    @Published public private(set) var uploads: [FileInfo] = []
    @Published public private(set) var cameras: [CameraInfo] = []
    @Published public private(set) var media: [MediaItem] = []
    @Published public private(set) var schedules = ScheduleState(items: [], scheduler: nil, waiting: nil)
    @Published public private(set) var terminals: [TerminalInfo] = []
    @Published public private(set) var focusedTerminal: String?
    @Published public private(set) var agents: AgentsStatus?
    @Published public private(set) var recordings: [RecordingCard] = []
    @Published public private(set) var status: StatusInfo?
    @Published public private(set) var sessionNumber: Int?
    @Published public private(set) var sessions: [SessionSummary] = []
    @Published public private(set) var searchMatches: [SessionMatch] = []
    @Published public private(set) var voices: VoiceCatalog?
    @Published public private(set) var deviceName: String?
    @Published public private(set) var serverVersion: String?
    @Published public private(set) var unseenFiles = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var toast: String?

    public var apiProvider: () -> ApiClient? = { nil }
    public var sendMessage: (ClientMessage) -> Bool = { _ in false }

    public init() {}

    public var activeTasks: [TaskInfo] { tasks.filter { $0.isActive } }
    public var attention: Int { approvals.count }
    public var runningCount: Int { activeTasks.count }

    // MARK: from the server

    public func apply(_ m: ServerMessage) {
        switch m {
        case .welcome(let w):
            deviceName = w.device; serverVersion = w.serverVersion
            tasks = w.tasks.sorted { ($0.startedAt ?? "") > ($1.startedAt ?? "") }
            approvals = w.approvals
            files = w.files
            cameras = w.cameras
            terminals = w.terminals.filter { $0.closed != true }
            if let s = w.schedules { schedules = s }
            agents = w.agents
            status = w.status
            sessionNumber = w.sessionNumber
        case .status(let s): status = s
        case .taskUpdate(let t):
            if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.insert(t, at: 0) }
            if t.isFinished { toast = "\(t.name ?? "Agent"): \(t.status) — \((t.title ?? "").prefix(50))" }
        case .approvalRequest(let a): if !approvals.contains(where: { $0.id == a.id }) { approvals.append(a) }
        case .approvalResolved(let id, _, _): approvals.removeAll { $0.id == id }
        case .fileAdded(let f):
            files.removeAll { $0.id == f.id }; files.insert(f, at: 0); unseenFiles += 1
            if f.owner != "you" { toast = "\(Persona.of(f.owner).name) shared \(f.name)" }
        case .fileRemoved(let ids): let gone = Set(ids); files.removeAll { gone.contains($0.id) }; uploads.removeAll { gone.contains($0.id) }
        case .schedules(let s): schedules = s
        case .cameras(let list): cameras = list
        case .cameraStatus(let id, let state, let detail, let viewers):
            if let i = cameras.firstIndex(where: { $0.id == id }) { cameras[i].state = state ?? cameras[i].state; cameras[i].detail = detail ?? cameras[i].detail; cameras[i].viewers = viewers ?? cameras[i].viewers }
        case .mediaAdded(let item): media.removeAll { $0.id == item.id }; media.insert(item, at: 0)
        case .mediaChanged(let item): if let i = media.firstIndex(where: { $0.id == item.id }) { media[i] = item }
        case .recordingUpdate(let cards): recordings = cards
        case .terminalOpened(let t): terminals.removeAll { $0.id == t.id }; terminals.append(t); focusedTerminal = t.id
        case .terminalFocus(let id): focusedTerminal = id
        case .terminalClosed(let id): terminals.removeAll { $0.id == id }; if focusedTerminal == id { focusedTerminal = nil }
        case .agents(let a): agents = a
        case .sessionReset(let n, _): sessionNumber = n; Task { await loadSessions() }
        default: break
        }
    }

    public func clearToast() { toast = nil }
    public func markFilesSeen() { unseenFiles = 0 }
    public func report(_ error: Error) { lastError = error.localizedDescription }
    public func clearError() { lastError = nil }

    // MARK: files

    public func loadFiles(kind: String = "output") async {
        guard let api = apiProvider() else { return }
        struct R: Decodable { let files: [FileInfo] }
        do {
            let r: R = try await api.get("/api/files", query: [("kind", kind)])
            if kind == "upload" { uploads = r.files } else { files = r.files }
        } catch { report(error) }
    }
    public func removeFile(_ f: FileInfo, purge: Bool = false) async {
        guard let api = apiProvider() else { return }
        struct R: Decodable { let removed: [String] }
        do {
            let _: R = try await api.send("DELETE", "/api/files/\(f.id)", query: purge ? [("purge", "true")] : [])
            files.removeAll { $0.id == f.id }; uploads.removeAll { $0.id == f.id }
        } catch { report(error) }
    }
    public func clearFiles(kind: String = "output", purge: Bool = false) async {
        guard let api = apiProvider() else { return }
        struct R: Decodable { let removed: [String] }
        do {
            let _: R = try await api.send("POST", "/api/files/clear", query: [("kind", kind)] + (purge ? [("purge", "true")] : []))
            if kind == "upload" { uploads = [] } else { files = [] }
        } catch { report(error) }
    }

    // MARK: media and cameras

    public func loadMedia(kind: String? = nil) async {
        guard let api = apiProvider() else { return }
        do {
            let r: MediaResponse = try await api.get("/api/media", query: [("limit", "50")] + (kind.map { [("kind", $0)] } ?? []))
            media = r.media
        } catch { report(error) }
    }
    public func labelMedia(_ item: MediaItem, source: String?, note: String?) async {
        guard let api = apiProvider() else { return }
        var body: [String: JSONValue] = [:]
        if let s = source { body["source"] = .string(s) }
        if let n = note { body["note"] = .string(n) }
        do { let _: JSONValue = try await api.send("POST", "/api/media/\(item.fullId ?? item.id)/label", json: .object(body)); await loadMedia() }
        catch { report(error) }
    }
    public func loadCameras() async {
        guard let api = apiProvider() else { return }
        do { let r: CamerasResponse = try await api.get("/api/cameras"); cameras = r.cameras } catch { report(error) }
    }
    /// Scans the network for cameras (the browser's Discover); returns the raw answer for display.
    public func discoverCameras() async -> JSONValue? {
        guard let api = apiProvider() else { return nil }
        do { let r: JSONValue = try await api.send("POST", "/api/cameras/discover"); await loadCameras(); return r }
        catch { report(error); return nil }
    }
    public func snapshot(_ cam: CameraInfo, save: Bool) async -> Data? {
        guard let api = apiProvider() else { return nil }
        do { return try await api.rawGet("/api/cameras/\(cam.id)/snapshot", query: save ? [("save", "true")] : [], timeout: 30).0 }
        catch { report(error); return nil }
    }
    public func record(_ cam: CameraInfo, seconds: Int, stop: Bool) async {
        guard let api = apiProvider() else { return }
        do {
            let _: JSONValue = stop ? try await api.send("POST", "/api/cameras/\(cam.id)/record/stop")
                                    : try await api.send("POST", "/api/cameras/\(cam.id)/record", json: .object(["seconds": .number(Double(seconds))]))
            toast = stop ? "Recording stopped" : "Recording \(seconds) s"
            await loadCameras()
        } catch { report(error) }
    }

    // MARK: schedules

    public func loadSchedules() async {
        guard let api = apiProvider() else { return }
        do { schedules = try await api.get("/api/schedules") } catch { report(error) }
    }
    public func scheduleAction(_ s: ScheduleItem, _ action: String, minutes: Int? = nil) async {
        guard let api = apiProvider() else { return }
        do {
            let _: JSONValue = try await api.send("POST", "/api/schedules/\(s.id)/\(action)", query: minutes.map { [("minutes", String($0))] } ?? [])
            await loadSchedules()
        } catch { report(error) }
    }
    public func deleteSchedule(_ s: ScheduleItem) async {
        guard let api = apiProvider() else { return }
        do { let _: JSONValue = try await api.send("DELETE", "/api/schedules/\(s.id)"); await loadSchedules() } catch { report(error) }
    }
    public func createSchedule(title: String, description: String, mode: String, inMinutes: Double?, everyMinutes: Double?) async -> Bool {
        guard let api = apiProvider() else { return false }
        var when: [String: JSONValue] = [:]
        if let e = everyMinutes { when = ["kind": .string("every"), "every_minutes": .number(e)] }
        else { when = ["kind": .string("in"), "in_minutes": .number(inMinutes ?? 10)] }
        let body: JSONValue = .object(["title": .string(title), "description": .string(description), "mode": .string(mode), "when": .object(when)])
        do { let _: JSONValue = try await api.send("POST", "/api/schedules", json: body); await loadSchedules(); return true }
        catch { report(error); return false }
    }
    public func editSchedule(_ s: ScheduleItem, title: String?, description: String?) async {
        guard let api = apiProvider() else { return }
        var body: [String: JSONValue] = [:]
        if let t = title { body["title"] = .string(t) }
        if let d = description { body["description"] = .string(d) }
        do { let _: JSONValue = try await api.send("PATCH", "/api/schedules/\(s.id)", json: .object(body)); await loadSchedules() } catch { report(error) }
    }

    // MARK: sessions, recordings, voice

    public func loadSessions() async {
        guard let api = apiProvider() else { return }
        struct R: Decodable { let sessions: [SessionSummary] }
        do { let r: R = try await api.get("/api/sessions"); sessions = r.sessions } catch { report(error) }
    }
    public func newSession() async -> String {
        guard let api = apiProvider() else { return "Not connected." }
        struct R: Decodable { let started: Bool; let number: Int?; let note: String? }
        do {
            let r: R = try await api.send("POST", "/api/sessions/new")
            return r.started ? "New session started." : "Already fresh — \(r.note ?? "nothing to summarise")."
        } catch { return error.localizedDescription }
    }
    public func searchSessions(_ q: String) async {
        guard let api = apiProvider(), q.count >= 2 else { searchMatches = []; return }
        struct R: Decodable { let matches: [SessionMatch] }
        do { let r: R = try await api.get("/api/sessions/search", query: [("q", q)]); searchMatches = r.matches } catch { report(error) }
    }
    public func loadRecordings() async {
        guard let api = apiProvider() else { return }
        struct R: Decodable { let recordings: [RecordingCard] }
        do { let r: R = try await api.get("/api/recordings"); recordings = r.recordings } catch { report(error) }
    }
    public func recordingAction(_ card: RecordingCard, _ action: String) async {
        guard let api = apiProvider() else { return }
        struct R: Decodable { let recordings: [RecordingCard] }
        do { let r: R = try await api.send("POST", "/api/recordings/\(card.id)/\(action)"); recordings = r.recordings } catch { report(error) }
    }
    public func loadVoices() async {
        guard let api = apiProvider() else { return }
        do { voices = try await api.get("/api/voice") } catch { report(error) }
    }
    public func setVoice(_ id: String?, speed: Double?) async {
        guard let api = apiProvider() else { return }
        var body: [String: JSONValue] = [:]
        if let id = id { body["voice"] = .string(id) }
        if let s = speed { body["speed"] = .number((s * 100).rounded() / 100) }
        do { let _: JSONValue = try await api.send("POST", "/api/voice", json: .object(body)); await loadVoices() } catch { report(error) }
    }
    public func selectAgent(_ key: String) { _ = sendMessage(.agentSelect(key)) }
    public func openTerminal(cwd: String? = nil) { if !sendMessage(.terminalOpen(cwd: cwd)) { lastError = "Not connected." } }
    public func closeTerminal(_ id: String) { _ = sendMessage(.terminalClose(id: id)) }
    public func cancelTask(_ id: String) { _ = sendMessage(.cancelTask(id: id)) }
    public func approve(_ id: String, _ ok: Bool) { _ = sendMessage(.approval(id: id, approve: ok)) }
}
