import Foundation

/// The live work view (`exec_start` / `exec_end`): every action Jarvis or the agent in front takes, as a card.
/// Server: jarvis/activity/feed.py. Results are structured (activity/describe.py); this file reads them tolerantly
/// into a small closed set the UI can draw natively, with a generic key/value fallback for anything new.
public struct ExecStart: Equatable, Sendable {
    public var id: String
    public var who: String          // jarvis | friday | edith | veronica | owner
    public var kind: String         // shell | read | write | edit | list | search | fetch | analyze | agent | tool
    public var title: String
    public var parent: String?
    public var wide: Bool
    public init(id: String, who: String = "jarvis", kind: String = "tool", title: String, parent: String? = nil, wide: Bool = false) {
        self.id = id; self.who = who; self.kind = kind; self.title = title; self.parent = parent; self.wide = wide
    }
}

public struct ExecEntry: Equatable, Sendable {
    public var name: String
    public var kind: String         // dir | file | image | video | audio | doc | code | archive
    public var size: Int?
    public var handle: String?
    public var depth: Int
}

public struct ExecRow: Equatable, Sendable {
    public var depth: Int
    public var key: String
    public var value: String
}

public struct ExecHunk: Equatable, Sendable { public var del: [String]; public var add: [String] }
public struct ExecHit: Equatable, Sendable {
    public var path: String; public var line: Int?; public var text: String
    public init(path: String, line: Int? = nil, text: String) { self.path = path; self.line = line; self.text = text }
}

public enum ExecResult: Equatable, Sendable {
    case terminal(cwd: String, command: String, stdout: String, stderr: String, exit: Int?, note: String?, entries: [ExecEntry])
    case entries(base: String?, items: [ExecEntry], more: Int)
    case lines(path: String, start: Int, text: String, more: Bool)
    case write(path: String, text: String)
    case diff(path: String, hunks: [ExecHunk], files: Int)
    case hits(items: [ExecHit], more: Bool)
    case media(path: String, note: String?)
    case text(url: String?, text: String)
    case data(status: String?, rows: [ExecRow])
    case web(title: String?, items: [ExecHit])

    /// A one-line digest for the ticker / the chat row.
    public var summary: String {
        switch self {
        case .terminal(_, let c, _, _, let e, _, _): return e.map { $0 == 0 ? "ran \(c)" : "\(c) exited \($0)" } ?? c
        case .entries(_, let i, let m): return "\(i.count + m) items"
        case .lines(let p, _, _, _): return "read \(Self.leaf(p))"
        case .write(let p, _): return "wrote \(Self.leaf(p))"
        case .diff(let p, _, let f): return f > 1 ? "edited \(f) files" : "edited \(Self.leaf(p))"
        case .hits(let h, _): return "\(h.count) matches"
        case .media(let p, _): return "looked at \(Self.leaf(p))"
        case .text(_, let t): return String(t.prefix(80))
        case .data(let s, let r): return s ?? "\(r.count) fields"
        case .web(let t, let i): return t ?? "\(i.count) results"
        }
    }
    static func leaf(_ p: String) -> String { p.split(separator: "/").last.map(String.init) ?? p }

    public static let maxRows = 60
    public static let maxText = 6000

    public static func parse(_ v: JSONValue?) -> ExecResult {
        guard let v = v, case .object = v else { return .text(url: nil, text: "") }
        func s(_ k: String) -> String { v[k]?.string ?? "" }
        func clip(_ t: String) -> String { t.count > maxText ? String(t.prefix(maxText)) + "…" : t }
        switch s("type") {
        case "terminal":
            let ents = v["entries"].map(entries) ?? []
            return .terminal(cwd: s("cwd"), command: s("command"), stdout: clip(s("stdout")), stderr: clip(s("stderr")),
                             exit: v["exit"]?.int, note: v["note"]?.string, entries: ents)
        case "entries": return .entries(base: v["base"]?.string, items: entries(v), more: v["more"]?.int ?? 0)
        case "tree": return .entries(base: v["base"]?.string, items: flattenTree(v["nodes"]?.array ?? [], depth: 0), more: v["more"]?.int ?? 0)
        case "lines": return .lines(path: s("path"), start: v["start"]?.int ?? 1, text: clip(s("text")), more: v["more"]?.bool ?? false)
        case "write": return .write(path: s("path"), text: clip(s("text")))
        case "diff":
            let hunks = (v["hunks"]?.array ?? []).map { h in
                ExecHunk(del: (h["del"]?.array ?? []).compactMap { $0.string }, add: (h["add"]?.array ?? []).compactMap { $0.string })
            }
            return .diff(path: s("path"), hunks: Array(hunks.prefix(40)), files: v["files"]?.array?.count ?? 1)
        case "hits":
            let items = (v["items"]?.array ?? []).prefix(40).map { ExecHit(path: $0["path"]?.string ?? "", line: $0["line"]?.int, text: $0["text"]?.string ?? "") }
            return .hits(items: Array(items), more: v["more"] != nil && v["more"]?.isNull == false)
        case "media": return .media(path: s("path").isEmpty ? s("name") : s("path"), note: v["note"]?.string)
        case "web_results", "profile":
            let items = (v["items"]?.array ?? v["results"]?.array ?? []).prefix(20).map {
                ExecHit(path: $0["title"]?.string ?? $0["url"]?.string ?? "", line: nil, text: $0["snippet"]?.string ?? $0["url"]?.string ?? "")
            }
            return .web(title: v["title"]?.string ?? v["name"]?.string ?? v["query"]?.string, items: Array(items))
        case "data":
            var rows: [ExecRow] = []
            flatten(v["data"], key: "", depth: 0, into: &rows)
            var status: String?
            for k in ["status", "state", "decision", "error"] { if let t = v["data"]?[k]?.string { status = t; break } }
            return .data(status: status, rows: rows)
        default:
            return .text(url: v["url"]?.string, text: clip(s("text")))
        }
    }

    static func entries(_ v: JSONValue) -> [ExecEntry] {
        (v["items"]?.array ?? []).prefix(48).map {
            ExecEntry(name: $0["name"]?.string ?? $0["path"]?.string ?? "?", kind: $0["kind"]?.string ?? "file", size: $0["size"]?.int, handle: $0["h"]?.string, depth: 0)
        }
    }
    static func flattenTree(_ nodes: [JSONValue], depth: Int) -> [ExecEntry] {
        var out: [ExecEntry] = []
        for n in nodes {
            if out.count >= 120 { break }
            out.append(ExecEntry(name: n["name"]?.string ?? "?", kind: n["kind"]?.string ?? "file", size: n["size"]?.int, handle: n["h"]?.string, depth: depth))
            if let kids = n["children"]?.array, depth < 3 { out += flattenTree(kids, depth: depth + 1) }
        }
        return out
    }

    /// Any JSON, as readable rows: snake_case keys become "Snake case", nesting indents, empty values vanish.
    static func flatten(_ v: JSONValue?, key: String, depth: Int, into rows: inout [ExecRow]) {
        guard let v = v, rows.count < maxRows, depth < 4 else { return }
        switch v {
        case .null: return
        case .string(let t): if !t.isEmpty { rows.append(ExecRow(depth: depth, key: human(key), value: String(t.prefix(280)))) }
        case .number(let n): rows.append(ExecRow(depth: depth, key: human(key), value: n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)))
        case .bool(let b): rows.append(ExecRow(depth: depth, key: human(key), value: b ? "yes" : "no"))
        case .object(let o):
            if let p = o["$path"]?.string { rows.append(ExecRow(depth: depth, key: human(key), value: p)); return }
            if !key.isEmpty { rows.append(ExecRow(depth: depth, key: human(key), value: "")) }
            for k in o.keys.sorted() { flatten(o[k], key: k, depth: key.isEmpty ? depth : depth + 1, into: &rows) }
        case .array(let a):
            if a.allSatisfy({ if case .object = $0 { return false }; if case .array = $0 { return false }; return true }) {
                let joined = a.compactMap { $0.string ?? $0.double.map { String($0) } }.joined(separator: ", ")
                if !joined.isEmpty { rows.append(ExecRow(depth: depth, key: human(key), value: String(joined.prefix(280)))) }
            } else {
                rows.append(ExecRow(depth: depth, key: human(key), value: "\(a.count) items"))
                for (i, item) in a.prefix(12).enumerated() { flatten(item, key: "#\(i + 1)", depth: depth + 1, into: &rows) }
            }
        }
    }

    public static func human(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces).lowercased()
        return words.isEmpty ? "" : words.prefix(1).uppercased() + words.dropFirst()
    }
}

public struct ExecEnd: Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var ms: Int?
    public var result: ExecResult
    public init(id: String, ok: Bool = true, ms: Int? = nil, result: ExecResult) { self.id = id; self.ok = ok; self.ms = ms; self.result = result }
}

public enum ExecLevel: String, CaseIterable, Sendable { case full, minimal, off }
