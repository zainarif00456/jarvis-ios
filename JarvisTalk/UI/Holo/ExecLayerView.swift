import SwiftUI
import JarvisCore
import JarvisModel

/// The live work view on the phone (browser: js/exec/layer.js): what Jarvis and the agent in front are DOING, as a small live
/// screen that forms out of the core, plays the result, stays a few seconds and melts back. One card in front (above the call
/// controls); earlier ones are chips in a strip at the top, tap one to bring its card back. Levels (Settings): full / minimal
/// (one ticker line) / off.
struct ExecLayerView: View {
    @EnvironmentObject var exec: ExecModel
    @Environment(\.calmFX) private var calm
    /// Vector from where the card rests to the orb, for the form / melt animation.
    var toCore: CGSize = CGSize(width: 0, height: -260)

    var body: some View {
        VStack(spacing: 8) {
            if exec.level == .full, !exec.chips.isEmpty { chips }
            Spacer(minLength: 0)
            if exec.level == .minimal, let t = exec.ticker { ticker(t) }
            if exec.level == .full {
                ForEach(exec.cards) { card in
                    ExecCardView(card: card)
                        .transition(.fromCore(toCore, calm: calm))
                }
            }
        }
        .padding(.horizontal, 10)
        .animation(calm ? .easeInOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.82), value: exec.cards.map { $0.id })
        .animation(.easeInOut(duration: 0.2), value: exec.ticker)
        .allowsHitTesting(!exec.cards.isEmpty || !exec.chips.isEmpty)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(exec.chips) { c in
                    Button { exec.restore(c.id) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: ExecStyle.symbol(c.kind)).font(.system(size: 10, weight: .bold))
                            Text(c.title).lineLimit(1).font(.system(size: 11, design: .monospaced))
                            Circle().fill(ExecStyle.stateColor(c)).frame(width: 6, height: 6)
                        }
                        .foregroundColor(ExecStyle.color(c.who))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.panel.opacity(0.9)))
                        .overlay(Capsule().stroke(ExecStyle.color(c.who).opacity(0.5), lineWidth: 0.8))
                    }.buttonStyle(.plain).frame(maxWidth: 190)
                    .accessibilityLabel("Earlier work: \(c.title)")
                }
            }.padding(.vertical, 2)
        }
    }

    private func ticker(_ t: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.fill").font(.system(size: 10))
            Text(t).lineLimit(1).font(.system(size: 11, design: .monospaced))
        }
        .foregroundColor(Theme.accentLight(.jarvis))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Theme.panel.opacity(0.9)))
        .overlay(Capsule().stroke(Theme.accent(.jarvis).opacity(0.4), lineWidth: 0.8))
        .transition(.opacity)
        .accessibilityLabel("Working: \(t)")
    }
}

enum ExecStyle {
    static func color(_ who: String) -> Color { who == "owner" ? Theme.persona("you") : Theme.persona(who) }
    static func stateColor(_ c: ExecModel.Card) -> Color { switch c.state { case .running: return Theme.warn; case .ok: return Theme.ok; case .failed: return Theme.bad } }
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "shell": return "terminal.fill"; case "read": return "doc.text.fill"; case "write", "edit": return "pencil.line"
        case "list": return "folder.fill"; case "search": return "magnifyingglass"; case "fetch": return "globe"
        case "analyze": return "eye.fill"; case "agent": return "star.fill"; default: return "wrench.and.screwdriver.fill"
        }
    }
}

struct ExecCardView: View {
    let card: ExecModel.Card
    @EnvironmentObject var exec: ExecModel
    @Environment(\.calmFX) private var calm
    @GestureState private var touching = false

    var body: some View {
        let tint = card.state == .failed ? Theme.bad : ExecStyle.color(card.who)
        VStack(spacing: 0) {
            header(tint)
            Divider().overlay(tint.opacity(0.25))
            ScrollView {
                Group {
                    if let r = card.result { ExecResultView(result: r, tint: tint) }
                    else { Text("WORKING").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(4).foregroundColor(tint.opacity(0.8)).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(10)
            }.frame(maxHeight: 250)
        }
        .overlay(alignment: .top) { if card.state == .running && !calm { RunningScan(tint: tint) } }
        .holoPlate(tint, active: card.state == .running || card.pinned, corner: 12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.text.opacity(card.pinned ? 0.6 : 0), lineWidth: 1))
        // touching a card keeps it on screen, like hovering in the browser
        .simultaneousGesture(DragGesture(minimumDistance: 0).updating($touching) { _, s, _ in s = true })
        .onChange(of: touching) { on in exec.hold(card.id, on) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Persona.of(card.who).name): \(card.title)")
    }

    private func header(_ tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ExecStyle.symbol(card.kind)).font(.system(size: 12, weight: .bold)).foregroundColor(tint)
                .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.16)))
            Text((card.who == "owner" ? "You" : Persona.of(card.who).name).uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(tint)
            Text(card.title).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.text.opacity(0.92)).lineLimit(1)
            Spacer(minLength: 4)
            if card.state == .running { Text(card.startedAt, style: .timer).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dimText).monospacedDigit() }
            else if let ms = card.ms { Text(ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)).font(.system(size: 10, design: .monospaced)).foregroundColor(card.state == .ok ? Theme.ok : Theme.bad) }
            Button { exec.pin(card.id) } label: { Image(systemName: card.pinned ? "pin.fill" : "pin").font(.system(size: 12)).foregroundColor(card.pinned ? tint : Theme.dimText).frame(width: 30, height: 30) }
                .accessibilityLabel(card.pinned ? "Unpin" : "Keep on screen")
            Button { exec.dismiss(card.id) } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.dimText).frame(width: 30, height: 30) }
                .accessibilityLabel("Dismiss")
        }.padding(.leading, 10).padding(.trailing, 2).padding(.vertical, 3)
    }
}

/// The light that sweeps down a card while it is running (browser: `.xc-scanline`).
private struct RunningScan: View {
    var tint: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
            GeometryReader { g in
                let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                LinearGradient(colors: [.clear, tint.opacity(0.14), tint.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    .frame(height: g.size.height * 0.4).offset(y: CGFloat(t) * g.size.height * 1.4 - g.size.height * 0.4)
            }
        }.allowsHitTesting(false)
    }
}

// MARK: results

/// A result, drawn natively by type: terminal, files, a file being read / written, a diff, search hits, data...
struct ExecResultView: View {
    let result: ExecResult
    var tint: Color
    var compact = false
    @EnvironmentObject var exec: ExecModel

    var body: some View {
        switch result {
        case .terminal(let cwd, let command, let out, let err, let code, let note, let entries):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Self.home(cwd)) $").foregroundColor(tint).font(.system(.caption, design: .monospaced))
                    TypeOut(text: command, ms: 420).foregroundColor(Theme.text)
                }
                if !entries.isEmpty { entriesGrid(entries) }
                else if !out.isEmpty { Text(compact ? String(out.prefix(400)) : out).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.text.opacity(0.9)).textSelection(.enabled) }
                if !err.isEmpty { Text(err).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.bad) }
                HStack {
                    Spacer()
                    Text(code.map { "exit \($0)" } ?? (note ?? "").replacingOccurrences(of: "_", with: " ")).font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(code == 0 ? Theme.ok : (code == nil ? Theme.dimText : Theme.bad))
                }
            }
        case .entries(let base, let items, let more):
            VStack(alignment: .leading, spacing: 6) {
                if let b = base { pathTag("\(items.count + more) items", b) }
                entriesGrid(items)
                if more > 0 { Text("+\(more) more").font(.caption2).foregroundColor(Theme.dimText) }
            }
        case .lines(let path, let start, let text, let more):
            VStack(alignment: .leading, spacing: 4) {
                pathTag("read", path)
                codeBlock(text, start: start)
                if more { Text("more below…").font(.caption2).foregroundColor(Theme.dimText) }
            }
        case .write(let path, let text):
            VStack(alignment: .leading, spacing: 4) { pathTag("write", path); codeBlock(text, start: nil) }
        case .diff(let path, let hunks, let files):
            VStack(alignment: .leading, spacing: 4) {
                pathTag("edit", path)
                ForEach(Array(hunks.enumerated()), id: \.offset) { _, h in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(h.del.enumerated()), id: \.offset) { _, l in diffLine("− " + l, Theme.bad) }
                        ForEach(Array(h.add.enumerated()), id: \.offset) { _, l in diffLine("+ " + l, Theme.ok) }
                    }
                }
                if files > 1 { Text("\(files) files changed").font(.caption2).foregroundColor(Theme.dimText) }
            }
        case .hits(let items, let more):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.prefix(compact ? 5 : 30).enumerated()), id: \.offset) { _, h in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.home(h.path) + (h.line.map { ":\($0)" } ?? "")).font(.system(size: 11, design: .monospaced)).foregroundColor(tint)
                        if !h.text.isEmpty { Text(h.text).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.text.opacity(0.85)).lineLimit(2) }
                    }
                }
                if more { Text("more matches…").font(.caption2).foregroundColor(Theme.dimText) }
            }
        case .media(let path, let note):
            VStack(alignment: .leading, spacing: 4) {
                pathTag("look", path)
                Image(systemName: "viewfinder").font(.system(size: 30)).foregroundColor(tint).padding(.vertical, 6)
                if let n = note { Text(n).font(.caption2).foregroundColor(Theme.dimText) }
            }
        case .text(let url, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let u = url { pathTag("web", u) }
                Text(compact ? String(text.prefix(300)) : text).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.text.opacity(0.92)).textSelection(.enabled)
            }
        case .data(let status, let rows):
            VStack(alignment: .leading, spacing: 3) {
                if let s = status { PillLabel(text: s, color: ExecResultView.good(s) ? Theme.ok : (ExecResultView.bad(s) ? Theme.bad : tint)) }
                ForEach(Array(rows.prefix(compact ? 8 : 60).enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 8) {
                        Text(r.key).font(.system(size: 11)).foregroundColor(Theme.dimText).frame(width: 110, alignment: .leading).padding(.leading, CGFloat(r.depth) * 10)
                        Text(r.value).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.text).lineLimit(compact ? 1 : 4)
                    }
                }
            }
        case .web(let title, let items):
            VStack(alignment: .leading, spacing: 6) {
                if let t = title { Text(t).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text) }
                ForEach(Array(items.prefix(compact ? 4 : 12).enumerated()), id: \.offset) { _, i in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.path).font(.system(size: 12, weight: .medium)).foregroundColor(tint).lineLimit(1)
                        if !i.text.isEmpty { Text(i.text).font(.system(size: 11)).foregroundColor(Theme.dimText).lineLimit(2) }
                    }
                }
            }
        }
    }

    static func home(_ p: String) -> String {
        guard p.hasPrefix("/home/") || p.hasPrefix("/Users/") else { return p.isEmpty ? "~" : p }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count <= 2 ? "~" : "~/" + parts.dropFirst(2).joined(separator: "/")
    }
    static func good(_ s: String) -> Bool { ["ok", "done", "success", "allowed", "completed", "sent", "saved"].contains(s.lowercased()) }
    static func bad(_ s: String) -> Bool { s.lowercased().range(of: "fail|error|denied|blocked|timeout", options: .regularExpression) != nil }

    private func pathTag(_ tag: String, _ path: String) -> some View {
        HStack(spacing: 6) {
            Text(tag.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5).foregroundColor(tint)
                .padding(.horizontal, 5).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.15)))
            Text(Self.home(path)).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.text.opacity(0.9)).lineLimit(1).truncationMode(.middle)
        }
    }
    private func codeBlock(_ text: String, start: Int?) -> some View {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(compact ? 8 : 80)
        return HStack(alignment: .top, spacing: 8) {
            if let s = start {
                VStack(alignment: .trailing, spacing: 0) { ForEach(0..<rows.count, id: \.self) { Text("\(s + $0)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dimText) } }
            }
            VStack(alignment: .leading, spacing: 0) {
                if rows.count > 1 || text.count < 24 { ForEach(0..<rows.count, id: \.self) { Text(String(rows[$0])).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.text) } }
                else { TypeOut(text: text, ms: 1200).foregroundColor(Theme.text) }
            }
        }
    }
    private func diffLine(_ t: String, _ c: Color) -> some View {
        Text(t.isEmpty ? " " : t).font(.system(size: 11, design: .monospaced)).foregroundColor(c).frame(maxWidth: .infinity, alignment: .leading).background(c.opacity(0.08))
    }
    private func entriesGrid(_ items: [ExecEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.prefix(compact ? 9 : 48).enumerated()), id: \.offset) { _, e in
                let tile = VStack(spacing: 2) {
                    Image(systemName: Self.fileSymbol(e.kind)).font(.system(size: 18)).foregroundColor(e.kind == "dir" ? tint : Theme.text.opacity(0.85))
                    Text(e.name).font(.system(size: 10)).lineLimit(1).foregroundColor(Theme.text)
                }
                .padding(.leading, CGFloat(e.depth) * 6).frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                if let h = e.handle {
                    tile.contextMenu {
                        Button { exec.act(handle: h, action: "open") } label: { Label("Open on the laptop", systemImage: "arrow.up.forward.app") }
                        Button { exec.act(handle: h, action: "reveal") } label: { Label("Show in folder", systemImage: "folder") }
                        if e.kind == "dir" { Button { exec.act(handle: h, action: "browse") } label: { Label("Browse here", systemImage: "list.bullet.indent") } }
                        Button { exec.act(handle: h, action: "terminal") } label: { Label("Terminal there", systemImage: "terminal") }
                    }.onTapGesture { exec.act(handle: h, action: e.kind == "dir" ? "browse" : "open") }
                } else { tile }
            }
        }
    }
    static func fileSymbol(_ kind: String) -> String {
        switch kind {
        case "dir": return "folder.fill"; case "image": return "photo"; case "video": return "film"; case "audio": return "music.note"
        case "doc": return "doc.text"; case "code": return "chevron.left.forwardslash.chevron.right"; case "archive": return "archivebox"
        default: return "doc"
        }
    }
}
