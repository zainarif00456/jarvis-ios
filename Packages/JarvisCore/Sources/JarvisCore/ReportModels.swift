import Foundation

/// A report / debrief as the server stores it (`GET /api/reports/{id}` -> {info, report}). Only what the phone draws is
/// modelled; every field is optional so a new server field or a missing one never loses a scene.
public struct ReportInfo: Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: String          // debrief | report | briefing ...
    public var agent: String?
    public init(id: String, title: String, kind: String, agent: String? = nil) { self.id = id; self.title = title; self.kind = kind; self.agent = agent }
}

public struct ReportMessage: Equatable, Sendable {
    public var who: String, role: String, when: String, whereText: String, text: String
    public var isQuote: Bool, tone: String, note: String
    public var replyTo: Int?
}
public struct ReportFact: Equatable, Sendable { public var label: String, value: String }
public struct ReportSubject: Equatable, Sendable {
    public var name: String, kind: String, role: String, org: String, relation: String, summary: String
    public var facts: [ReportFact]
    public var history: [ReportFact]            // when -> text
    public var mediaPath: String?               // "media/<name>" resolved through /api/reports/{id}/media/<name>
}
public struct ReportCheck: Equatable, Sendable { public var label: String, status: String, detail: String, value: String }
public struct ReportTermLine: Equatable, Sendable { public var text: String, tone: String }
public struct ReportSeries: Equatable, Sendable { public var name: String; public var values: [Double?] }
public struct ReportChart: Equatable, Sendable {
    public var type: String, title: String, unit: String
    public var labels: [String]
    public var series: [ReportSeries]
    public var points: [(x: Double, y: Double, label: String)]
    public static func == (a: ReportChart, b: ReportChart) -> Bool {
        a.type == b.type && a.title == b.title && a.unit == b.unit && a.labels == b.labels && a.series == b.series
            && a.points.count == b.points.count
    }
}
public struct ReportChange: Equatable, Sendable { public var document, section, asked, askedBy: String; public var before, after: [String] }
public struct ReportDraft: Equatable, Sendable { public var channel, to, subject, body, status: String }
public struct ReportStat: Equatable, Sendable { public var label, value, note: String }
public struct ReportEvent: Equatable, Sendable { public var when, text: String }
public struct ReportCode: Equatable, Sendable { public var path: String; public var start: Int; public var end: Int?; public var title: String; public var note: String }
public struct ReportNode: Equatable, Sendable { public var id, label, note: String }
public struct ReportEdge: Equatable, Sendable { public var from, to, label: String }
public struct ReportTable: Equatable, Sendable { public var columns: [String]; public var rows: [(label: String, cells: [String])]
    public static func == (a: ReportTable, b: ReportTable) -> Bool {
        a.columns == b.columns && a.rows.count == b.rows.count && zip(a.rows, b.rows).allSatisfy { $0.label == $1.label && $0.cells == $1.cells }
    }
}
public struct ReportBeat: Equatable, Sendable {
    public var say: String
    public var part: String?
    public var item: Int?
    public var focus: [String]
    public var flow: [String]
}
public struct ReportLink: Equatable, Sendable { public var to: String; public var label: String }
public struct ReportMedia: Equatable, Sendable { public var file: String; public var caption: String; public var role: String }

public struct ReportBlock: Identifiable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var heading: String
    public var kicker: String
    public var body: String
    public var short: String
    public var tone: String                      // normal | alert | good
    public var bullets: [String]
    public var messages: [ReportMessage]
    public var subjects: [ReportSubject]         // person (1) or dossier (n)
    public var connections: [(a: Int, b: Int, label: String)]
    public var checks: [ReportCheck]
    public var terminalTitle: String?
    public var terminal: [ReportTermLine]
    public var chart: ReportChart?
    public var change: ReportChange?
    public var draft: ReportDraft?
    public var stats: [ReportStat]
    public var events: [ReportEvent]
    public var code: [ReportCode]
    public var nodes: [ReportNode]
    public var edges: [ReportEdge]
    public var diagramTitle: String?
    public var table: ReportTable?
    public var media: [ReportMedia]
    public var beats: [ReportBeat]
    public var links: [ReportLink]
    public var narration: String

    public static func == (a: ReportBlock, b: ReportBlock) -> Bool {
        a.id == b.id && a.heading == b.heading && a.type == b.type && a.messages == b.messages && a.subjects == b.subjects
            && a.checks == b.checks && a.terminal == b.terminal && a.chart == b.chart && a.change == b.change && a.draft == b.draft
            && a.stats == b.stats && a.events == b.events && a.nodes == b.nodes && a.edges == b.edges && a.beats == b.beats
            && a.links == b.links && a.table == b.table && a.bullets == b.bullets
    }

    /// How many items a part has (what a beat's `show.item` may point at).
    public func count(of part: String) -> Int {
        switch part {
        case "messages": return messages.count
        case "checks": return checks.count
        case "terminal": return terminal.count
        case "bullets": return bullets.count
        case "stats": return stats.count
        case "timeline": return events.count
        case "subjects", "facts": return subjects.count
        case "chart": return chart.map { max($0.labels.count, $0.points.count) } ?? 0
        default: return 0
        }
    }
}

public struct Report: Equatable, Sendable {
    public var info: ReportInfo
    public var title: String
    public var blocks: [ReportBlock]
    public init(info: ReportInfo, title: String, blocks: [ReportBlock]) { self.info = info; self.title = title; self.blocks = blocks }

    public func block(_ id: String) -> ReportBlock? { blocks.first { $0.id == id } }
    public func index(of id: String) -> Int? { blocks.firstIndex { $0.id == id } }

    /// Reads the `GET /api/reports/{id}` body.
    public static func parse(_ root: JSONValue) -> Report? {
        guard let infoV = root["info"], let rep = root["report"], let id = infoV["id"]?.string else { return nil }
        let info = ReportInfo(id: id, title: infoV["title"]?.string ?? rep["title"]?.string ?? "", kind: infoV["kind"]?.string ?? "report", agent: infoV["agent"]?.string)
        let blocks = (rep["blocks"]?.array ?? []).compactMap(parseBlock)
        return Report(info: info, title: rep["title"]?.string ?? info.title, blocks: blocks)
    }

    static func strs(_ v: JSONValue?) -> [String] { (v?.array ?? []).compactMap { $0.string } }

    public static func parseBlock(_ b: JSONValue) -> ReportBlock? {
        guard let id = b["id"]?.string else { return nil }
        func s(_ k: String) -> String { b[k]?.string ?? "" }
        var subjects: [ReportSubject] = []
        func subject(_ p: JSONValue) -> ReportSubject {
            ReportSubject(name: p["name"]?.string ?? "", kind: p["kind"]?.string ?? "person", role: p["role"]?.string ?? "", org: p["org"]?.string ?? "",
                          relation: p["relation"]?.string ?? "", summary: p["summary"]?.string ?? "",
                          facts: (p["facts"]?.array ?? []).map { ReportFact(label: $0["label"]?.string ?? "", value: $0["value"]?.string ?? "") },
                          history: (p["history"]?.array ?? []).map { ReportFact(label: $0["when"]?.string ?? "", value: $0["text"]?.string ?? "") },
                          mediaPath: p["media"]?.int.flatMap { i in b["media"]?[i]?["file"]?.string })
        }
        if let p = b["person"], case .object = p { subjects = [subject(p)] }
        var connections: [(a: Int, b: Int, label: String)] = []
        if let d = b["dossier"], case .object = d {
            subjects = (d["subjects"]?.array ?? []).map(subject)
            connections = (d["connections"]?.array ?? []).compactMap { c in
                guard let a = c["a"]?.int, let z = c["b"]?.int else { return nil }
                return (a, z, c["label"]?.string ?? "")
            }
        }
        var chart: ReportChart?
        if let c = b["chart"], case .object = c {
            chart = ReportChart(type: c["type"]?.string ?? "bar", title: c["title"]?.string ?? "", unit: c["unit"]?.string ?? "", labels: strs(c["labels"]),
                                series: (c["series"]?.array ?? []).map { ReportSeries(name: $0["name"]?.string ?? "", values: ($0["values"]?.array ?? []).map { $0.double }) },
                                points: (c["points"]?.array ?? []).compactMap { p in
                                    guard let x = p["x"]?.double, let y = p["y"]?.double else { return nil }
                                    return (x, y, p["label"]?.string ?? "")
                                })
        }
        var change: ReportChange?
        if let c = b["change"], case .object = c {
            change = ReportChange(document: c["document"]?.string ?? "", section: c["section"]?.string ?? "", asked: c["asked"]?.string ?? "",
                                  askedBy: c["asked_by"]?.string ?? "", before: strs(c["before"]), after: strs(c["after"]))
        }
        var draft: ReportDraft?
        if let d = b["draft"], case .object = d {
            draft = ReportDraft(channel: d["channel"]?.string ?? "other", to: d["to"]?.string ?? "", subject: d["subject"]?.string ?? "", body: d["body"]?.string ?? "", status: d["status"]?.string ?? "drafted")
        }
        var nodes: [ReportNode] = []; var edges: [ReportEdge] = []; var dtitle: String?
        if let d = b["diagram"], case .object = d {
            nodes = (d["nodes"]?.array ?? []).map { ReportNode(id: $0["id"]?.string ?? "", label: $0["label"]?.string ?? ($0["id"]?.string ?? ""), note: $0["note"]?.string ?? "") }
            dtitle = d["title"]?.string
            edges = (d["edges"]?.array ?? []).compactMap { e in
                guard let f = e["from"]?.string, let t = e["to"]?.string else { return nil }
                return ReportEdge(from: f, to: t, label: e["label"]?.string ?? "")
            }
            if edges.isEmpty, let src = d["source"]?.string { (edges, nodes) = MermaidLite.parse(src, known: nodes) }
        }
        var table: ReportTable?
        if let t = b["table"], case .object = t {
            table = ReportTable(columns: strs(t["columns"]), rows: (t["rows"]?.array ?? []).map { ($0["label"]?.string ?? "", strs($0["cells"])) })
        }
        let beats = (b["beats"]?.array ?? []).map { bt -> ReportBeat in
            let show = bt["show"]
            var focus = strs(show?["focus"]); if let n = show?["node"]?.string, !n.isEmpty { focus.append(n) }
            return ReportBeat(say: bt["say"]?.string ?? "", part: show?["part"]?.string, item: show?["item"]?.int, focus: focus, flow: strs(show?["flow"]))
        }
        return ReportBlock(
            id: id, type: s("type"), heading: s("heading"), kicker: s("kicker"), body: s("body"), short: s("short"),
            tone: b["tone"]?.string ?? "normal", bullets: strs(b["bullets"]),
            messages: (b["messages"]?.array ?? []).map {
                ReportMessage(who: $0["who"]?.string ?? "", role: $0["role"]?.string ?? "", when: $0["when"]?.string ?? "", whereText: $0["where"]?.string ?? "",
                              text: $0["text"]?.string ?? "", isQuote: $0["kind"]?.string == "quote", tone: $0["tone"]?.string ?? "normal",
                              note: $0["note"]?.string ?? "", replyTo: $0["reply_to"]?.int)
            },
            subjects: subjects, connections: connections,
            checks: (b["checks"]?.array ?? []).map { ReportCheck(label: $0["label"]?.string ?? "", status: $0["status"]?.string ?? "info", detail: $0["detail"]?.string ?? "", value: $0["value"]?.string ?? "") },
            terminalTitle: b["terminal"]?["title"]?.string,
            terminal: (b["terminal"]?["lines"]?.array ?? []).map { ReportTermLine(text: $0["text"]?.string ?? "", tone: $0["tone"]?.string ?? "out") },
            chart: chart, change: change, draft: draft,
            stats: (b["stats"]?.array ?? []).map { ReportStat(label: $0["label"]?.string ?? "", value: $0["value"]?.string ?? "", note: $0["note"]?.string ?? "") },
            events: (b["events"]?.array ?? []).map { ReportEvent(when: $0["when"]?.string ?? "", text: $0["text"]?.string ?? "") },
            code: (b["code"]?.array ?? []).map { ReportCode(path: $0["path"]?.string ?? "", start: $0["start"]?.int ?? 1, end: $0["end"]?.int, title: $0["title"]?.string ?? "", note: $0["note"]?.string ?? "") },
            nodes: nodes, edges: edges, diagramTitle: dtitle, table: table,
            media: (b["media"]?.array ?? []).map { ReportMedia(file: $0["file"]?.string ?? "", caption: $0["caption"]?.string ?? "", role: $0["role"]?.string ?? "") },
            beats: beats,
            links: (b["links"]?.array ?? []).compactMap { l in l["to"]?.string.map { ReportLink(to: $0, label: l["label"]?.string ?? "") } },
            narration: s("narration"))
    }
}

/// Just enough Mermaid flowchart to draw "A --> B" edges and node labels ("A[Label]", "A(Label)", "A{Label}").
public enum MermaidLite {
    public static func parse(_ source: String, known: [ReportNode]) -> ([ReportEdge], [ReportNode]) {
        var labels: [String: String] = Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0.label) })
        var order: [String] = known.map { $0.id }
        var edges: [ReportEdge] = []
        func node(_ raw: String) -> String? {
            var t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            var label: String?
            if let open = t.firstIndex(where: { "[({>".contains($0) }) {
                var l = String(t[open...]).trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<>\"'/\\ "))
                if l.isEmpty { l = "" }
                label = l.isEmpty ? nil : l
                t = String(t[..<open]).trimmingCharacters(in: .whitespaces)
            }
            guard !t.isEmpty, t.range(of: "^[A-Za-z0-9_\\-]+$", options: .regularExpression) != nil else { return nil }
            if labels[t] == nil { labels[t] = label ?? t; order.append(t) } else if let l = label, labels[t] == t { labels[t] = l }
            return t
        }
        for line in source.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let l = String(line)
            guard let arrow = l.range(of: "-->|-.->|==>|---|--[>o]", options: .regularExpression) else { continue }
            var left = String(l[..<arrow.lowerBound])
            var right = String(l[arrow.upperBound...])
            var edgeLabel = ""
            if right.hasPrefix("|"), let end = right.dropFirst().firstIndex(of: "|") {
                edgeLabel = String(right[right.index(after: right.startIndex)..<end]); right = String(right[right.index(after: end)...])
            }
            left = left.trimmingCharacters(in: .whitespaces)
            if let a = node(left), let b = node(right) { edges.append(ReportEdge(from: a, to: b, label: edgeLabel)) }
        }
        let notes = Dictionary(known.map { ($0.id, $0.note) }, uniquingKeysWith: { a, _ in a })
        return (edges, order.map { id in ReportNode(id: id, label: labels[id] ?? id, note: notes[id] ?? "") })
    }
}
