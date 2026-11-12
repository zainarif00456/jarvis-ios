import Foundation
import JarvisCore

/// Jarvis's hands on the phone's screen. Reports what is open (`screen_state`, debounced, only when the Settings switch is on),
/// runs `screen_cmd` (open, focus, close, arrange, zoom, report_* ...) and answers `screen_ack` with what happened.
///
/// Why the phone sends `screen_state`: the server only delivers debriefs and briefings to a client that reported a screen
/// (jarvis/screen.py `ScreenBoard.target`: no snapshot = "no screen is connected right now", and `present_report` fails). Without it
/// an agent's debrief is never shown or read to the phone. With it, Jarvis also resolves "close that" against what the phone
/// really shows (`<on_screen>`). The switch is in Settings; off = the phone is only a voice and a chat, as before.
@MainActor
public final class ScreenModel: ObservableObject {
    public let portals: PortalModel
    public let debrief: DebriefModel
    public var send: (ClientMessage) -> Bool = { _ in false }
    public var enabled = true { didSet { if enabled && !oldValue { report(now: true) } } }
    /// How long a change waits before it is reported (the browser: 120 ms).
    public var reportDelay: TimeInterval = 0.12
    private var timer: Task<Void, Never>?
    public private(set) var reportsSent = 0

    public init(portals: PortalModel, debrief: DebriefModel) {
        self.portals = portals; self.debrief = debrief
        portals.onChange = { [weak self] in self?.report() }
        debrief.onChange = { [weak self] in self?.report() }
    }

    public func snapshot() -> ScreenSnapshot {
        var snap = portals.snapshot()
        if let r = debrief.state() {
            // a debrief is popups on the stage, not a portal: it is still a window to Jarvis (`kind: debrief`), the one in front
            if debrief.isDebrief {
                var tops = snap.windows; for i in tops.indices { tops[i].active = false }
                tops.append(ScreenWindowState(id: "report-\(r.id)", kind: "debrief", title: "DEBRIEF · \(r.title)", itemType: "report", itemId: r.id, itemName: r.title,
                                              active: true, rect: [0, 0, Int(portals.viewport.w), Int(portals.viewport.h)], report: r))
                snap.windows = tops
            } else if let i = snap.windows.firstIndex(where: { $0.id == "report-\(r.id)" }) { snap.windows[i].report = r }
        }
        return snap
    }

    public func report(now: Bool = false) {
        guard enabled else { return }
        timer?.cancel()
        if now { push(); return }
        timer = Task { [weak self] in
            guard let d = self?.reportDelay else { return }
            try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.push()
        }
    }
    private func push() { if send(.screenState(snapshot())) { reportsSent += 1 } }

    // MARK: commands

    public func handle(_ cmd: ScreenCommand) async {
        var ok = true, message = "", detail = ""
        if !enabled {
            ok = false; message = "screen control is switched off in this phone's Settings"
        } else {
            do { detail = try await run(cmd) } catch let e {
                ok = false; message = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
        }
        _ = send(.screenAck(cmdId: cmd.cmdId, ok: ok, error: message, detail: detail, state: enabled ? snapshot() : nil))
    }

    enum ScreenError: Error, LocalizedError {
        case msg(String)
        var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
    }
    private func win(_ id: String?) throws -> PortalModel.Portal {
        let key = id ?? portals.top?.id
        guard let key = key, let p = portals.portal(key) else { throw ScreenError.msg("nothing called \(id ?? "that") is open") }
        return p
    }

    func run(_ c: ScreenCommand) async throws -> String {
        let a = c.args
        switch c.action {
        case "open": return try await open(a)
        case "focus", "flag": let p = try win(c.target); portals.restore(p.id); return ""
        case "close":
            if let t = c.target, t.hasPrefix("report-"), debrief.report.map({ "report-\($0.info.id)" == t }) == true { debrief.close() }
            let p = try? win(c.target)
            if let p = p { portals.close(p.id) } else if debrief.isOpen { debrief.close() } else { throw ScreenError.msg("nothing called \(c.target ?? "that") is open") }
            return ""
        case "close_all": let n = portals.closeAll() + (debrief.isOpen ? 1 : 0); debrief.close(); return "\(n) closed"
        case "minimise": portals.minimise(try win(c.target).id); return ""
        case "restore": portals.restore(try win(c.target).id); return ""
        case "maximise": portals.setFull(try win(c.target).id, true); return ""
        case "unmaximise": portals.setFull(try win(c.target).id, false); return ""
        case "arrange": return portals.arrange(a["layout"]?.string ?? "grid", main: a["main"]?.string ?? c.target, order: a["order"]?.array?.compactMap { $0.string } ?? [])
        case "zoom":
            let p = try win(c.target ?? "file")
            guard p.kind == .file else { throw ScreenError.msg("only pictures can be zoomed") }
            let level = a["level"]?.string ?? "in"
            portals.zoom(p.id, by: level == "out" ? 0.8 : level == "reset" ? 1 / p.scale : 1.4)
            return ""
        case "next", "previous": throw ScreenError.msg("the phone's viewer does not move between items yet")
        case "report_open":
            guard let id = a["id"]?.string else { throw ScreenError.msg("which report?") }
            let title = try await debrief.open(id)
            if debrief.isDebrief { return "debrief on the stage: \(title)" }
            portals.open(.report, id: "report-\(id)", title: title, itemId: id, itemName: title)
            return "opened \(title)"
        case "report_focus": return try debrief.focus(a["section"]?.string)
        case "report_step": return try debrief.step(by: a["by"]?.int ?? 1)
        case "report_overview": return debrief.overview()
        case "report_item": return try debrief.item(a["section"]?.string, part: a["part"]?.string ?? "", item: a["item"]?.int ?? 0)
        case "report_flag": return try debrief.flag(a["section"]?.string, part: a["part"]?.string)
        case "report_diagram":
            return try debrief.diagram(a["section"]?.string, focus: a["focus"]?.array?.compactMap { $0.string } ?? [],
                                       flow: a["flow"]?.array?.compactMap { $0.string } ?? [], overview: a["overview"]?.bool ?? false)
        case "report_keep": debrief.keepAll(); return "kept open"
        case "report_linger": debrief.lingerThenClose(seconds: a["seconds"]?.double ?? 6); return "closing soon"
        case "report_close":
            if let id = a["id"]?.string { portals.close("report-\(id)") }
            debrief.close(); return "closed"
        // presentation-only cues the phone does not draw yet: acknowledged (so the briefing carries on), said plainly
        case "report_zoom", "report_code", "report_row", "report_build", "report_media", "report_cite", "report_pop", "report_aside", "report_changes":
            guard debrief.isOpen else { throw ScreenError.msg("no report is open") }
            return "the phone does not draw \(c.action.replacingOccurrences(of: "report_", with: "")) yet"
        default: throw ScreenError.msg("unknown screen action \(c.action)")
        }
    }

    /// Opens a registered view: file(s), cameras, schedule (the browser's panels) plus the phone's own.
    func open(_ a: JSONValue) async throws -> String {
        let what = a["what"]?.string ?? ""
        switch what {
        case "file":
            let id = a["id"]?.string
            let p = portals.open(.file, id: "file-\(id ?? "x")", title: a["name"]?.string ?? "File", itemId: id, itemName: a["name"]?.string)
            return "opened \(p.title)"
        case "files": portals.open(.files); return ""
        case "cameras": portals.open(.cameras); return ""
        case "schedule", "schedules": portals.open(.schedule); return ""
        case "chat": portals.open(.chat); return ""
        case "media": portals.open(.media); return ""
        case "terminal", "terminals": portals.open(.terminal); return ""
        case "settings": portals.open(.settings); return ""
        case "activity": portals.open(.activity); return ""
        case "sessions": portals.open(.sessions); return ""
        default: throw ScreenError.msg("cannot open \(what.isEmpty ? "that" : what) on the phone")
        }
    }
}

/// "Jarvis wants to talk": a briefing waiting for the owner (`briefing_request`).
@MainActor
public final class BriefingModel: ObservableObject {
    @Published public private(set) var asked: [BriefingRun] = []
    public var sendMessage: (ClientMessage) -> Bool = { _ in false }
    public init() {}
    public var priority: String { asked.contains { $0.priority == "critical" } ? "critical" : asked.contains { $0.priority == "high" } ? "high" : "normal" }

    public func set(_ runs: [BriefingRun]) { for r in runs where !asked.contains(where: { $0.id == r.id }) { asked.append(r) } }
    public func clear(_ ids: [String]) { asked.removeAll { ids.contains($0.id) } }
    public func reset() { asked = [] }
    /// "Talk now": the server briefs by voice (the call is up) or, with no microphone, on screen.
    public func accept(textOnly: Bool = false) { _ = sendMessage(.briefingAccept(textOnly: textOnly)) }
    public func dismiss() { _ = sendMessage(.briefingDismiss(ids: asked.map { $0.id })); asked = [] }
    public func later() { asked = [] }
}
