import Foundation
import JarvisCore

/// A debrief (an agent walks the owner through what she found): 1-6 scenes, one popup card each, on the stage beside the core.
/// The card just told is ghosted (faint, still tappable), the one before it dissolves, the next pops in; scenes that the agent
/// linked ("this blocks that") are joined by a light line while both are up; the owner speaking pauses the walk (nothing
/// closes under them); at the end everything melts back into the core. Mirrors `js/debrief/stage.js`.
///
/// Server side: the agent's report arrives as `screen_cmd report_open`, then voice-clocked `report_focus` / `report_item` /
/// `report_diagram` cues (jarvis/gateway/hub.py `present_report`). Long-form reports use the same sections.
@MainActor
public final class DebriefModel: ObservableObject {
    public enum Side: String { case left, right }
    public struct Card: Identifiable, Equatable {
        public var id: String
        public var block: ReportBlock
        public var side: Side
        public var ghost = false
        public var litPart: String?
        public var litItem: Int?
        public var focusNodes: [String] = []
        public var flow: [String] = []
    }
    public struct Link: Equatable { public var from: String, to: String, label: String }

    @Published public private(set) var report: Report? { didSet { onChange() } }
    @Published public private(set) var cards: [Card] = [] { didSet { onChange() } }
    @Published public private(set) var link: Link?
    @Published public private(set) var lingering = false { didSet { onChange() } }
    @Published public private(set) var mode = "overview"
    @Published public private(set) var told: [String] = []
    @Published public private(set) var error: String?
    public var onChange: () -> Void = {}
    /// `GET /api/reports/{id}`; injected so tests need no server.
    public var loader: (String) async throws -> Report = { _ in throw DebriefError.noLoader }
    /// Seconds are multiplied by this (tests).
    public var lingerScale: Double = 1
    public static let maxGhosts = 1

    private var lingerTask: Task<Void, Never>?

    public init() {}

    public enum DebriefError: Error, LocalizedError {
        case noLoader, noReport, noScene(String)
        public var errorDescription: String? {
            switch self { case .noLoader: return "this phone cannot load reports"; case .noReport: return "no report is open"; case .noScene(let s): return "there is no scene \(s)" }
        }
    }

    public var isOpen: Bool { report != nil }
    public var isDebrief: Bool { report?.info.kind == "debrief" }
    public var current: Card? { cards.last { !$0.ghost } }
    public var focusedId: String? { current?.id }

    // MARK: commands (the names follow `screen_cmd`)

    @discardableResult
    public func open(_ id: String) async throws -> String {
        if let r = report, r.info.id == id { keepAll(); return r.title }
        let loaded = try await loader(id)
        close()
        report = loaded
        cards = []; told = []; mode = "overview"; link = nil
        return loaded.title
    }

    @discardableResult
    public func focus(_ id: String?) throws -> String {
        guard let r = report else { throw DebriefError.noReport }
        guard let id = id, let b = r.block(id) else { throw DebriefError.noScene(id ?? "") }
        keepAll()
        if current?.id == id { return b.heading }
        let prev = current
        // older ghosts and any card of this same scene dissolve; the card just told fades to a ghost
        cards.removeAll { $0.id == id }
        if cards.count > 0 { cards.removeAll { $0.ghost } }
        if var p = prev, let i = cards.firstIndex(where: { $0.id == p.id }) { p.ghost = true; cards[i] = p }
        let side: Side = prev.map { $0.side == .right ? .left : .right } ?? .right
        cards.append(Card(id: id, block: b, side: side))
        if !told.contains(id) { told.append(id) }
        mode = "focus"
        if let p = prev, let l = b.links.first(where: { $0.to == p.id }) ?? p.block.links.first(where: { $0.to == id }) {
            link = Link(from: p.id, to: id, label: l.label)
        } else { link = nil }
        return b.heading
    }

    @discardableResult
    public func step(by: Int) throws -> String {
        guard let r = report else { throw DebriefError.noReport }
        let ids = r.blocks.map { $0.id }
        let at = focusedId.flatMap { ids.firstIndex(of: $0) } ?? (by > 0 ? -1 : ids.count)
        return try focus(ids[max(0, min(ids.count - 1, at + by))])
    }

    public func overview() -> String { mode = "overview"; link = nil; for i in cards.indices { cards[i].ghost = true }; return "overview" }

    @discardableResult
    public func item(_ section: String?, part: String, item: Int) throws -> String {
        try ensure(section)
        update(section) { $0.litPart = part; $0.litItem = item }
        return ""
    }
    @discardableResult
    public func flag(_ section: String?, part: String?) throws -> String {
        try ensure(section)
        update(section) { $0.litPart = part; $0.litItem = nil }
        return ""
    }
    @discardableResult
    public func diagram(_ section: String?, focus: [String], flow: [String], overview: Bool) throws -> String {
        try ensure(section)
        update(section) { $0.focusNodes = overview ? [] : focus; $0.flow = overview ? [] : flow }
        return ""
    }

    private func ensure(_ section: String?) throws {
        guard report != nil else { throw DebriefError.noReport }
        if let s = section, s != focusedId { try focus(s) }
        if current == nil { throw DebriefError.noScene(section ?? "") }
    }
    private func update(_ section: String?, _ change: (inout Card) -> Void) {
        guard let i = cards.lastIndex(where: { !$0.ghost && (section == nil || $0.id == section) }) else { return }
        change(&cards[i])
    }

    /// The owner is talking: nothing closes under them.
    public func keepAll() {
        guard lingering || lingerTask != nil else { return }
        lingerTask?.cancel(); lingerTask = nil; lingering = false
    }

    /// After the walk-through: stay a moment (at most 4 s), then melt back into the core.
    public func lingerThenClose(seconds: Double) {
        guard isOpen else { return }
        lingering = true
        lingerTask?.cancel()
        let t = min(seconds, 4) * lingerScale
        lingerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, t) * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            self.lingerTask = nil; self.lingering = false; self.close()
        }
    }

    public func close() {
        lingerTask?.cancel(); lingerTask = nil
        lingering = false
        report = nil; cards = []; link = nil; told = []; mode = "overview"
    }

    /// The tap on a ghost brings it back.
    public func bringBack(_ id: String) { _ = try? focus(id) }

    // MARK: what Jarvis sees

    public func state() -> ScreenReportState? {
        guard let r = report else { return nil }
        return ScreenReportState(id: r.info.id, title: r.title, kind: isDebrief ? "debrief" : r.info.kind, mode: mode, focused: focusedId, lingering: lingering,
                                 blocks: r.blocks.enumerated().map { ScreenReportBlockState(id: $1.id, n: $0 + 1, heading: $1.heading, type: $1.type) })
    }
}
