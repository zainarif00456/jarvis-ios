import Foundation
import JarvisCore

/// The live work view, as state: cards that come out of the core when Jarvis (or the agent in front) starts an action,
/// show the result, stay a few seconds (longer for big results; touching one keeps it) and melt back into the core.
/// Mirrors the browser's `js/exec/layer.js`: on a phone ONE card is in front, the rest are chips in a strip; levels
/// full / minimal (one ticker line) / off.
@MainActor
public final class ExecModel: ObservableObject {
    public struct Card: Identifiable, Equatable {
        public enum State: Equatable { case running, ok, failed }
        public var id: String
        public var who: String
        public var kind: String
        public var title: String
        public var parent: String?
        public var state: State = .running
        public var result: ExecResult?
        public var ms: Int?
        public var startedAt: Date
        public var pinned = false
        public var held = false
        public var isDone: Bool { state != .running }
    }

    /// Cards in front, oldest first. A phone shows `maxFront` of them (the newest); older ones go to `chips`.
    @Published public private(set) var cards: [Card] = []
    @Published public private(set) var chips: [Card] = []
    @Published public private(set) var ticker: String?
    @Published public var level: ExecLevel = .full { didSet { if level != .full { dissolveAll() }; if level != .minimal { ticker = nil } } }
    /// How many cards run at once, how long chips are kept.
    public var maxFront = 1
    public static let maxChips = 8
    public static let maxHistory = 40
    /// All linger times are multiplied by this (tests use a tiny value).
    public var lingerScale: Double = 1
    public static let lingerBase = 4.2, lingerPerKB = 0.9, lingerMax = 11.0, failedExtra = 3.0
    /// Everything that happened, newest last (for the chat timeline and the Live Activity): never dissolved.
    @Published public private(set) var recent: [Card] = []

    /// Called with (running count, latest title, latest summary) so a Live Activity / PiP can follow.
    public var onSummary: (_ running: Int, _ title: String?, _ detail: String?) -> Void = { _, _, _ in }
    /// Send `exec_action` (open, browse...) back to the server.
    public var sendMessage: (ClientMessage) -> Bool = { _ in false }

    private var timers: [String: Task<Void, Never>] = [:]

    public init() {}

    public var running: [Card] { recent.filter { $0.state == .running } }

    // MARK: from the server

    public func start(_ e: ExecStart) {
        guard level != .off else { return }
        let card = Card(id: e.id, who: e.who, kind: e.kind, title: e.title, parent: e.parent, startedAt: Date())
        remember(card)
        if level == .minimal { ticker = e.title; publish(); return }
        cards.removeAll { $0.id == e.id }
        cards.append(card)
        while cards.count > maxFront {
            let old = cards.removeFirst()
            timers[old.id]?.cancel(); timers[old.id] = nil
            toChips(old)
        }
        publish()
    }

    public func end(_ e: ExecEnd) {
        update(e.id) { $0.state = e.ok ? .ok : .failed; $0.result = e.result; $0.ms = e.ms }
        if let i = recent.firstIndex(where: { $0.id == e.id }) { _ = recent[i] }
        if level == .minimal { ticker = e.result.summary; publish(); scheduleTickerClear(); return }
        if level == .off { return }
        if cards.contains(where: { $0.id == e.id }) { schedule(e.id) }
        else if let i = chips.firstIndex(where: { $0.id == e.id }) { chips[i].state = e.ok ? .ok : .failed; chips[i].result = e.result; chips[i].ms = e.ms }
        publish()
    }

    // MARK: owner actions

    public func pin(_ id: String) {
        update(id) { $0.pinned.toggle() }
        if cards.first(where: { $0.id == id })?.pinned == true { timers[id]?.cancel(); timers[id] = nil } else { schedule(id) }
    }
    /// A finger on the card: it stays while held.
    public func hold(_ id: String, _ on: Bool) {
        update(id) { $0.held = on }
        if on { timers[id]?.cancel(); timers[id] = nil } else { schedule(id) }
    }
    public func dismiss(_ id: String) {
        timers[id]?.cancel(); timers[id] = nil
        if let i = cards.firstIndex(where: { $0.id == id }) { toChips(cards.remove(at: i)) }
        publish()
    }
    /// Tapping a chip brings its card back in front.
    public func restore(_ id: String) {
        guard let i = chips.firstIndex(where: { $0.id == id }) else { return }
        let c = chips.remove(at: i)
        while cards.count >= maxFront, !cards.isEmpty { let old = cards.removeFirst(); timers[old.id]?.cancel(); toChips(old) }
        cards.append(c)
        if c.isDone { schedule(id) }
    }
    public func dissolveAll() { for c in cards { timers[c.id]?.cancel() }; timers.removeAll(); cards.removeAll(); chips.removeAll() }

    /// Act on a file / folder handle shown on a card (open on the laptop, browse here...).
    @discardableResult
    public func act(handle: String, action: String) -> Bool { sendMessage(.execAction(handle: handle, action: action, req: String(handle.prefix(12)))) }

    // MARK: internals

    private func remember(_ c: Card) {
        recent.removeAll { $0.id == c.id }
        recent.append(c)
        if recent.count > Self.maxHistory { recent.removeFirst(recent.count - Self.maxHistory) }
    }
    private func update(_ id: String, _ change: (inout Card) -> Void) {
        if let i = cards.firstIndex(where: { $0.id == id }) { change(&cards[i]) }
        if let i = chips.firstIndex(where: { $0.id == id }) { change(&chips[i]) }
        if let i = recent.firstIndex(where: { $0.id == id }) { change(&recent[i]) }
    }
    private func toChips(_ c: Card) {
        chips.removeAll { $0.id == c.id }
        chips.append(c)
        if chips.count > Self.maxChips { chips.removeFirst(chips.count - Self.maxChips) }
    }
    private func linger(for c: Card) -> TimeInterval {
        var size = 0
        switch c.result {
        case .terminal(_, _, let o, let e, _, _, let ents)?: size = o.count + e.count + ents.count * 40
        case .lines(_, _, let t, _)?, .write(_, let t)?, .text(_, let t)?: size = t.count
        case .entries(_, let i, _)?: size = i.count * 40
        case .data(_, let r)?: size = r.count * 60
        case .diff(_, let h, _)?: size = h.reduce(0) { $0 + $1.add.count * 40 + $1.del.count * 40 }
        case .hits(let h, _)?, .web(_, let h)?: size = h.count * 60
        case .media?: size = 400
        case nil: size = 0
        }
        let t = min(Self.lingerMax, Self.lingerBase + Double(size) / 1024 * Self.lingerPerKB + (c.state == .failed ? Self.failedExtra : 0))
        return t * lingerScale
    }
    private func schedule(_ id: String) {
        timers[id]?.cancel()
        guard let c = cards.first(where: { $0.id == id }), c.isDone, !c.pinned, !c.held else { return }
        let secs = linger(for: c)
        timers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, secs) * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            self.timers[id] = nil
            self.dismiss(id)
        }
    }
    private func scheduleTickerClear() {
        timers["ticker"]?.cancel()
        timers["ticker"] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(3.5 * max(lingerScale, 0.001) * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            if self.running.isEmpty { self.ticker = nil }
        }
    }
    private func publish() {
        let r = running
        onSummary(r.count, (r.last ?? recent.last)?.title, (r.last ?? recent.last)?.result?.summary)
    }
}
