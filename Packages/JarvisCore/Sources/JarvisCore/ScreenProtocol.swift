import Foundation

/// What the owner's phone tells Jarvis about its screen (`screen_state`), and the commands Jarvis sends back (`screen_cmd`).
/// Server: jarvis/screen.py, gateway/protocol.py. The server REJECTS unknown top-level fields of `screen_state`
/// (`extra="forbid"`), so only the documented ones are sent.
public struct ScreenCommand: Equatable, Sendable {
    public var cmdId: String
    public var action: String
    public var target: String?
    public var args: JSONValue
    public init(cmdId: String, action: String, target: String? = nil, args: JSONValue = .object([:])) { self.cmdId = cmdId; self.action = action; self.target = target; self.args = args }
    public func arg(_ k: String) -> JSONValue? { args[k] }
}

public struct ScreenReportBlockState: Equatable, Sendable {
    public var id: String; public var n: Int; public var heading: String; public var type: String
    public init(id: String, n: Int, heading: String, type: String) { self.id = id; self.n = n; self.heading = heading; self.type = type }
}

public struct ScreenReportState: Equatable, Sendable {
    public var id: String, title: String, kind: String, mode: String
    public var focused: String?
    public var lingering: Bool
    public var blocks: [ScreenReportBlockState]
    public init(id: String, title: String, kind: String, mode: String, focused: String?, lingering: Bool, blocks: [ScreenReportBlockState]) {
        self.id = id; self.title = title; self.kind = kind; self.mode = mode; self.focused = focused; self.lingering = lingering; self.blocks = blocks
    }
}

public struct ScreenWindowState: Equatable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var itemType: String?, itemId: String?, itemName: String?
    public var active: Bool, full: Bool, minimised: Bool
    public var rect: [Int]
    public var report: ScreenReportState?

    public init(id: String, kind: String, title: String, itemType: String? = nil, itemId: String? = nil, itemName: String? = nil,
                active: Bool = false, full: Bool = false, minimised: Bool = false, rect: [Int] = [0, 0, 0, 0], report: ScreenReportState? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.itemType = itemType; self.itemId = itemId; self.itemName = itemName
        self.active = active; self.full = full; self.minimised = minimised; self.rect = rect; self.report = report
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        o["id"] = .string(String(id.prefix(80)))
        o["kind"] = .string(String(kind.prefix(30)))
        o["title"] = .string(String(title.prefix(300)))
        o["active"] = .bool(active); o["full"] = .bool(full); o["minimised"] = .bool(minimised)
        o["rect"] = .array(rect.prefix(4).map { JSONValue.number(Double($0)) })
        if let t = itemType {
            var item: [String: JSONValue] = ["type": .string(String(t.prefix(30)))]
            if let i = itemId { item["id"] = .string(String(i.prefix(64))) }
            if let n = itemName { item["name"] = .string(String(n.prefix(300))) }
            o["item"] = .object(item)
        }
        if let r = report {
            var blocks: [JSONValue] = []
            for b in r.blocks.prefix(30) {
                var bo: [String: JSONValue] = [:]
                bo["id"] = .string(String(b.id.prefix(40)))
                bo["n"] = .number(Double(min(99, max(1, b.n))))
                bo["heading"] = .string(String(b.heading.prefix(160)))
                bo["type"] = .string(String(b.type.prefix(20)))
                blocks.append(.object(bo))
            }
            var ro: [String: JSONValue] = [:]
            ro["id"] = .string(String(r.id.prefix(64)))
            ro["title"] = .string(String(r.title.prefix(160)))
            ro["kind"] = .string(String(r.kind.prefix(12)))
            ro["mode"] = .string(String(r.mode.prefix(10)))
            if let f = r.focused { ro["focused"] = .string(String(f.prefix(40))) } else { ro["focused"] = .null }
            ro["lingering"] = .bool(r.lingering)
            ro["blocks"] = .array(blocks)
            o["report"] = .object(ro)
        }
        return .object(o)
    }
}

public struct ScreenSnapshot: Equatable, Sendable {
    public var windows: [ScreenWindowState]
    public var viewport: [Int]
    public var compact: Bool
    public var mode: String
    public var layout: String
    public var pinned: [String]
    public init(windows: [ScreenWindowState], viewport: [Int], compact: Bool = true, mode: String = "stage", layout: String = "orbit", pinned: [String] = []) {
        self.windows = windows; self.viewport = viewport; self.compact = compact; self.mode = mode; self.layout = layout; self.pinned = pinned
    }
    /// The body fields shared by `screen_state` and a `screen_ack`'s `state`.
    var bodyFields: [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        o["windows"] = .array(windows.prefix(40).map { $0.json })
        o["viewport"] = .array(viewport.prefix(2).map { JSONValue.number(Double($0)) })
        o["compact"] = .bool(compact)
        o["mode"] = .string(String(mode.prefix(20)))
        o["layout"] = .string(String(layout.prefix(20)))
        o["pinned"] = .array(pinned.prefix(40).map { JSONValue.string($0) })
        return o
    }
}

public struct BriefingRun: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var priority: String
    public var preview: String
    public var failed: Bool
    public init(id: String, title: String, priority: String = "normal", preview: String = "", failed: Bool = false) {
        self.id = id; self.title = title; self.priority = priority; self.preview = preview; self.failed = failed
    }
}
