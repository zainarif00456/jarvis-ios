import SwiftUI
import JarvisCore
import JarvisModel

/// How a scene's data is drawn (browser: js/blocks/data.js). One renderer per kind; whichever the block has is shown, in
/// order. `card.litPart` / `litItem` is the item the agent is talking about right now: the others dim.
struct SceneBody: View {
    let card: DebriefModel.Card
    let reportId: String
    @EnvironmentObject var app: AppModel

    private var b: ReportBlock { card.block }
    private func dim(_ part: String, _ i: Int) -> Double { (card.litPart == part && card.litItem != nil && card.litItem != i) ? 0.4 : 1 }
    private func lit(_ part: String, _ i: Int) -> Bool { card.litPart == part && card.litItem == i }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !b.body.isEmpty { Text(b.body).font(.system(size: 14)).foregroundColor(Theme.text.opacity(0.92)) }
            if !b.messages.isEmpty { messages }
            if !b.subjects.isEmpty { subjects }
            if !b.stats.isEmpty { stats }
            if !b.checks.isEmpty { checks }
            if !b.terminal.isEmpty { terminal }
            if let c = b.chart { ChartScene(chart: c) }
            if !b.nodes.isEmpty { DiagramScene(block: b, focus: card.focusNodes, flow: card.flow) }
            if let c = b.change { change(c) }
            if let d = b.draft { draft(d) }
            if !b.events.isEmpty { timeline }
            if !b.bullets.isEmpty { bullets }
            if let t = b.table { table(t) }
            if !b.code.isEmpty { code }
            if !b.media.isEmpty { media }
        }
    }

    // messages
    private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(b.messages.enumerated()), id: \.offset) { i, m in
                let hue = Self.hue(m.who)
                HStack(alignment: .top, spacing: 8) {
                    Text(Self.initials(m.who)).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        .frame(width: 28, height: 28).background(Circle().fill(Color(hue: hue, saturation: 0.55, brightness: 0.7)))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(m.who).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
                            if !m.role.isEmpty { Text(m.role).font(.system(size: 10)).foregroundColor(Theme.dimText) }
                            if !m.when.isEmpty { Text(m.when).font(.system(size: 10)).foregroundColor(Theme.dimText) }
                            Spacer(minLength: 0)
                            Text(m.isQuote ? "EXACT" : "PARAPHRASED").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(m.isQuote ? Theme.ok : Theme.warn)
                        }
                        if let r = m.replyTo, b.messages.indices.contains(r) {
                            Text("↳ to \(b.messages[r].who): \(String(b.messages[r].text.prefix(60)))").font(.system(size: 10)).foregroundColor(Theme.dimText).lineLimit(1)
                        }
                        Text(m.text).font(.system(size: 13)).foregroundColor(Theme.text)
                        if !m.note.isEmpty { Text(m.note).font(.system(size: 11)).foregroundColor(Theme.warn) }
                    }
                    .padding(9).background(RoundedRectangle(cornerRadius: 12).fill(Color(hue: hue, saturation: 0.5, brightness: 0.6).opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accentLight(.jarvis).opacity(lit("messages", i) ? 0.9 : 0), lineWidth: 1.5))
                }
                .opacity(dim("messages", i)).animation(.easeInOut(duration: 0.25), value: card.litItem)
            }
        }
    }
    static func initials(_ n: String) -> String { n.split(separator: " ").prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined() }
    static func hue(_ n: String) -> Double { var h = 0; for u in n.unicodeScalars { h = (h * 31 + Int(u.value)) % 360 }; return Double(h) / 360 }

    // person / dossier
    private var subjects: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(b.subjects.enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        ZStack {
                            if let f = s.mediaPath { ReportImage(reportId: reportId, file: f).clipShape(Circle()) }
                            else { Text(Self.initials(s.name)).font(.system(size: 16, weight: .bold)).foregroundColor(Theme.accentLight(.jarvis)) }
                            Circle().stroke(Theme.accent(.jarvis).opacity(0.7), lineWidth: 1.5)
                            Circle().stroke(Theme.accent(.jarvis).opacity(0.3), lineWidth: 1).scaleEffect(1.18)
                        }.frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.kind == "company" ? "ORGANISATION" : "SUBJECT").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(Theme.accentLight(.jarvis))
                            Text(s.name).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                            let sub = [s.role, s.org].filter { !$0.isEmpty }.joined(separator: " · ")
                            if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundColor(Theme.dimText) }
                            if !s.relation.isEmpty { Text(s.relation).font(.system(size: 11)).foregroundColor(Theme.warn) }
                        }
                    }
                    if !s.summary.isEmpty { Text(s.summary).font(.system(size: 12)).foregroundColor(Theme.text.opacity(0.9)) }
                    ForEach(Array(s.facts.enumerated()), id: \.offset) { _, f in
                        HStack { Text(f.label).font(.system(size: 11)).foregroundColor(Theme.dimText); Spacer(); Text(f.value).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.text) }
                    }
                    ForEach(Array(s.history.enumerated()), id: \.offset) { _, h in
                        HStack(alignment: .top, spacing: 8) { Text(h.label).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dimText).frame(width: 56, alignment: .leading); Text(h.value).font(.system(size: 11)).foregroundColor(Theme.text) }
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accentLight(.jarvis).opacity(lit("subjects", i) ? 0.9 : 0.15), lineWidth: 1))
                .opacity(dim("subjects", i))
                if i < b.subjects.count - 1, let c = b.connections.first(where: { ($0.a == i && $0.b == i + 1) || ($0.b == i && $0.a == i + 1) }) {
                    HStack(spacing: 6) {
                        Rectangle().fill(Theme.accent(.jarvis).opacity(0.7)).frame(width: 2, height: 18)
                        Text(c.label.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5).foregroundColor(Theme.accentLight(.jarvis))
                    }.padding(.leading, 26)
                }
            }
        }
    }

    // stats
    private var stats: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(Array(b.stats.enumerated()), id: \.offset) { i, s in
                VStack(spacing: 2) {
                    Text(s.value).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundColor(Theme.accentLight(.jarvis)).minimumScaleFactor(0.6).lineLimit(1)
                    Text(s.label).font(.system(size: 11)).foregroundColor(Theme.text)
                    if !s.note.isEmpty { Text(s.note).font(.system(size: 10)).foregroundColor(Theme.dimText) }
                }.frame(maxWidth: .infinity).padding(8).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                .opacity(dim("stats", i))
            }
        }
    }

    // checks: a diagnosis as a chain of dials
    private var checks: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(b.checks.enumerated()), id: \.offset) { i, c in
                let col = Self.statusColor(c.status)
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle().strokeBorder(col, lineWidth: 2.5).background(Circle().fill(col.opacity(0.18))).frame(width: 22, height: 22)
                            .overlay(Image(systemName: Self.statusSymbol(c.status)).font(.system(size: 10, weight: .bold)).foregroundColor(col))
                            .shadow(color: col.opacity(lit("checks", i) ? 0.9 : 0.3), radius: lit("checks", i) ? 8 : 3)
                        if i < b.checks.count - 1 { Rectangle().fill(col.opacity(0.4)).frame(width: 2, height: 18) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack { Text(c.label).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text); Spacer(); if !c.value.isEmpty { Text(c.value).font(.system(size: 11, design: .monospaced)).foregroundColor(col) } }
                        if !c.detail.isEmpty { Text(c.detail).font(.system(size: 11)).foregroundColor(Theme.dimText) }
                    }.padding(.top, 2)
                }.opacity(dim("checks", i))
            }
        }
    }
    static func statusColor(_ s: String) -> Color { switch s { case "ok": return Theme.ok; case "warn": return Theme.warn; case "fail": return Theme.bad; case "skip": return Theme.dimText; default: return Theme.accent(.jarvis) } }
    static func statusSymbol(_ s: String) -> String { switch s { case "ok": return "checkmark"; case "warn": return "exclamationmark"; case "fail": return "xmark"; case "skip": return "minus"; default: return "info" } }

    // terminal lines
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let t = b.terminalTitle, !t.isEmpty { Text(t.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(Theme.dimText) }
            ForEach(Array(b.terminal.enumerated()), id: \.offset) { i, l in
                Text((l.tone == "cmd" ? "$ " : "") + l.text).font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Self.termColor(l.tone)).opacity(dim("terminal", i)).frame(maxWidth: .infinity, alignment: .leading)
                    .background(lit("terminal", i) ? Theme.accent(.jarvis).opacity(0.15) : Color.clear)
            }
        }.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.4)))
    }
    static func termColor(_ t: String) -> Color { switch t { case "cmd": return Theme.accentLight(.jarvis); case "error": return Theme.bad; case "warn": return Theme.warn; case "ok": return Theme.ok; case "note": return Theme.dimText; default: return Theme.text } }

    // before / after
    private func change(_ c: ReportChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(c.document)\(c.section.isEmpty ? "" : " › " + c.section)").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
            if !c.asked.isEmpty { Text("“\(c.asked)”" + (c.askedBy.isEmpty ? "" : " — \(c.askedBy)")).font(.system(size: 12)).italic().foregroundColor(Theme.dimText) }
            ForEach(Array(c.before.enumerated()), id: \.offset) { _, l in Text("− " + l).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.bad).frame(maxWidth: .infinity, alignment: .leading).background(Theme.bad.opacity(0.08)) }
            ForEach(Array(c.after.enumerated()), id: \.offset) { _, l in Text("+ " + l).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.ok).frame(maxWidth: .infinity, alignment: .leading).background(Theme.ok.opacity(0.08)) }
        }
    }

    // draft
    private func draft(_ d: ReportDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { PillLabel(text: d.channel.uppercased(), color: Theme.accent(.jarvis)); PillLabel(text: d.status, color: d.status == "sent" ? Theme.ok : Theme.warn); Spacer() }
            Text("To: \(d.to)").font(.system(size: 12)).foregroundColor(Theme.dimText)
            if !d.subject.isEmpty { Text(d.subject).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text) }
            Text(d.body).font(.system(size: 13)).foregroundColor(Theme.text)
        }.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    // timeline, bullets, table, code
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(b.events.enumerated()), id: \.offset) { i, e in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Theme.accent(.jarvis)).frame(width: 7, height: 7).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 0) { Text(e.when).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dimText); Text(e.text).font(.system(size: 13)).foregroundColor(Theme.text) }
                }.opacity(dim("timeline", i))
            }
        }
    }
    private var bullets: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(b.bullets.enumerated()), id: \.offset) { i, t in
                HStack(alignment: .top, spacing: 8) { Text("•").foregroundColor(Theme.accentLight(.jarvis)); Text(t).font(.system(size: 13)).foregroundColor(Theme.text) }.opacity(dim("bullets", i))
            }
        }
    }
    private func table(_ t: ReportTable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !t.columns.isEmpty { HStack { ForEach(Array(t.columns.enumerated()), id: \.offset) { _, c in Text(c).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(Theme.dimText).frame(maxWidth: .infinity, alignment: .leading) } } }
            ForEach(Array(t.rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top) {
                    Text(r.label).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(r.cells.enumerated()), id: \.offset) { _, c in Text(c).font(.system(size: 12)).foregroundColor(Theme.text).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(.vertical, 2)
                Divider().overlay(Color.white.opacity(0.08))
            }
        }
    }
    private var code: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(b.code.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(c.path):\(c.start)\(c.end.map { "-\($0)" } ?? "")").font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.accentLight(.jarvis))
                    if !c.title.isEmpty { Text(c.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text) }
                    if !c.note.isEmpty { Text(c.note).font(.system(size: 12)).foregroundColor(Theme.dimText) }
                }.padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
            }
        }
    }
    private var media: some View {
        VStack(spacing: 6) {
            ForEach(Array(b.media.enumerated()), id: \.offset) { _, m in
                VStack(alignment: .leading, spacing: 3) {
                    if m.file.hasSuffix(".mp4") { Label(m.caption.isEmpty ? "Video" : m.caption, systemImage: "film").font(.caption).foregroundColor(Theme.dimText) }
                    else { ReportImage(reportId: reportId, file: m.file).clipShape(RoundedRectangle(cornerRadius: 10)); if !m.caption.isEmpty { Text(m.caption).font(.system(size: 11)).foregroundColor(Theme.dimText) } }
                }
            }
        }
    }
}

/// A picture of a report, fetched with the device token (AsyncImage cannot send it).
struct ReportImage: View {
    let reportId: String
    let file: String
    @EnvironmentObject var app: AppModel
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let i = image { Image(uiImage: i).resizable().scaledToFill() }
            else { Rectangle().fill(Color.white.opacity(0.06)).overlay(Image(systemName: "photo").foregroundColor(Theme.dimText)) }
        }
        .task(id: file) {
            guard image == nil, let api = app.api else { return }
            let name = file.hasPrefix("media/") ? String(file.dropFirst(6)) : file
            if let (data, http) = try? await api.rawGet("/api/reports/\(reportId)/media/\(name)"), http.statusCode == 200, let ui = UIImage(data: data) { image = ui }
        }
    }
}

/// A diagram as a flow of boxes (the server draws SVG for browsers; the phone draws the nodes and arrows itself).
struct DiagramScene: View {
    let block: ReportBlock
    let focus: [String]
    let flow: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = block.diagramTitle, !t.isEmpty { Text(t.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(Theme.dimText) }
            ForEach(Array(order.enumerated()), id: \.offset) { i, n in
                let hot = focus.contains(n.id) || flow.contains(n.id)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(n.label).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
                        Spacer(minLength: 0)
                        if let to = outgoing(n.id).first { Text("→ \(label(to.to))").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.accentLight(.jarvis)).lineLimit(1) }
                    }
                    if !n.note.isEmpty && hot { Text(n.note).font(.system(size: 11)).foregroundColor(Theme.dimText) }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent(.jarvis).opacity(hot ? 0.28 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.accentLight(.jarvis).opacity(hot ? 0.95 : 0.25), lineWidth: hot ? 1.5 : 0.8))
                .shadow(color: Theme.accent(.jarvis).opacity(hot ? 0.6 : 0), radius: 8)
                .opacity((focus.isEmpty && flow.isEmpty) || hot ? 1 : 0.5)
                if i < order.count - 1 { Image(systemName: "arrow.down").font(.system(size: 10)).foregroundColor(Theme.accent(.jarvis).opacity(0.6)).frame(maxWidth: .infinity) }
            }
        }.animation(.easeInOut(duration: 0.3), value: focus + flow)
    }
    private func label(_ id: String) -> String { block.nodes.first { $0.id == id }?.label ?? id }
    private func outgoing(_ id: String) -> [ReportEdge] { block.edges.filter { $0.from == id } }
    /// Nodes in reading order: a walk along the edges from the nodes nothing points at.
    private var order: [ReportNode] {
        var seen: [String] = []
        let targets = Set(block.edges.map { $0.to })
        func visit(_ id: String) { guard !seen.contains(id) else { return }; seen.append(id); for e in block.edges where e.from == id { visit(e.to) } }
        for n in block.nodes where !targets.contains(n.id) { visit(n.id) }
        for n in block.nodes { visit(n.id) }
        return seen.compactMap { id in block.nodes.first { $0.id == id } }
    }
}

/// Charts drawn from the real numbers: bars, lines, areas, donut, scatter (no chart library, so no iOS-version risk).
struct ChartScene: View {
    let chart: ReportChart
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chart.title.isEmpty { Text(chart.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text) }
            Canvas { ctx, size in draw(&ctx, size) }.frame(height: chart.type == "donut" ? 150 : 140)
            if chart.type != "scatter" && !chart.labels.isEmpty {
                HStack(spacing: 0) { ForEach(Array(chart.labels.enumerated()), id: \.offset) { _, l in Text(l).font(.system(size: 9)).foregroundColor(Theme.dimText).lineLimit(1).frame(maxWidth: .infinity) } }
            }
            if chart.series.count > 1 {
                HStack { ForEach(Array(chart.series.enumerated()), id: \.offset) { i, s in HStack(spacing: 4) { Circle().fill(Self.color(i)).frame(width: 7, height: 7); Text(s.name).font(.system(size: 10)).foregroundColor(Theme.dimText) } } }
            }
            if !chart.unit.isEmpty { Text("unit: \(chart.unit)").font(.system(size: 9)).foregroundColor(Theme.dimText) }
        }
    }
    static func color(_ i: Int) -> Color { [Theme.accent(.jarvis), Theme.warn, Theme.ok, Theme.persona("veronica")][i % 4] }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let pad: CGFloat = 6
        let area = CGRect(x: pad, y: pad, width: size.width - 2 * pad, height: size.height - 2 * pad)
        switch chart.type {
        case "donut":
            let vals = (chart.series.first?.values ?? []).map { max(0, $0 ?? 0) }
            let total = vals.reduce(0, +); guard total > 0 else { return }
            let c = CGPoint(x: area.midX, y: area.midY); let r = min(area.width, area.height) / 2
            var start = -Double.pi / 2
            for (i, v) in vals.enumerated() {
                let end = start + 2 * Double.pi * v / total
                var p = Path(); p.addArc(center: c, radius: r - 8, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
                ctx.stroke(p, with: .color(Self.color(i)), style: StrokeStyle(lineWidth: 16))
                start = end
            }
        case "scatter":
            guard !chart.points.isEmpty else { return }
            let xs = chart.points.map { $0.x }, ys = chart.points.map { $0.y }
            let (x0, x1, y0, y1) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
            for p in chart.points {
                let x = area.minX + CGFloat((p.x - x0) / max(x1 - x0, 1e-9)) * area.width
                let y = area.maxY - CGFloat((p.y - y0) / max(y1 - y0, 1e-9)) * area.height
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(Theme.accentLight(.jarvis)))
            }
        default:
            let all = chart.series.flatMap { $0.values.compactMap { $0 } }
            guard let hi = all.max() else { return }
            let lo = min(0, all.min() ?? 0); let span = max(hi - lo, 1e-9)
            let n = max(chart.labels.count, chart.series.map { $0.values.count }.max() ?? 0); guard n > 0 else { return }
            let step = area.width / CGFloat(n)
            func y(_ v: Double) -> CGFloat { area.maxY - CGFloat((v - lo) / span) * area.height }
            for (si, s) in chart.series.enumerated() {
                let col = Self.color(si)
                if chart.type == "bar" {
                    let bw = step / CGFloat(chart.series.count) * 0.7
                    for (i, v) in s.values.enumerated() {
                        guard let v = v else { continue }
                        let x = area.minX + CGFloat(i) * step + step * 0.15 + CGFloat(si) * bw
                        ctx.fill(Path(roundedRect: CGRect(x: x, y: y(v), width: bw, height: max(1, y(0) - y(v))), cornerRadius: 2), with: .color(col))
                    }
                } else {
                    var line = Path(); var first = true
                    var pts: [CGPoint] = []
                    for (i, v) in s.values.enumerated() { if let v = v { pts.append(CGPoint(x: area.minX + step * (CGFloat(i) + 0.5), y: y(v))) } }
                    for p in pts { if first { line.move(to: p); first = false } else { line.addLine(to: p) } }
                    if chart.type == "area", let f = pts.first, let l = pts.last {
                        var fill = line; fill.addLine(to: CGPoint(x: l.x, y: area.maxY)); fill.addLine(to: CGPoint(x: f.x, y: area.maxY)); fill.closeSubpath()
                        ctx.fill(fill, with: .color(col.opacity(0.22)))
                    }
                    ctx.stroke(line, with: .color(col), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    for p in pts { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(col)) }
                }
            }
        }
    }
}
