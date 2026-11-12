import SwiftUI
import JarvisCore
import JarvisModel

func markdownText(_ s: String) -> Text {
    if let a = try? AttributedString(markdown: s, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
    return Text(s)
}

/// The admin chat: history, streaming replies, tools, tasks, approvals and voice captions in one timeline.
struct ChatView: View {
    @EnvironmentObject var chat: ChatModel
    @EnvironmentObject var deck: DeckModel
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var call: CallModel
    @StateObject private var picker = UploadController()
    @EnvironmentObject var uploads: UploadModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var alerts: PermissionAlerts
    @FocusState private var focused: Bool
    @State private var showAttachments = false

    private let commands = ["/help", "/status", "/tasks", "/files", "/stop", "/new"]

    var body: some View {
        NavigationStack {
            ZStack {
                StageBackground(accent: Theme.accent(.jarvis))
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if chat.timeline.hasOlder {
                                    Button { Task { await chat.loadOlder() } } label: {
                                        if chat.loadingOlder { ProgressView() } else { Text("Load earlier messages").font(.footnote) }
                                    }.frame(maxWidth: .infinity)
                                }
                                if chat.entries.isEmpty {
                                    EmptyHint(icon: "bubble.left.and.bubble.right", title: "Say something", detail: "Type a message or a /command, or just talk — the voice call is on the Jarvis tab.")
                                }
                                ForEach(chat.entries) { e in TimelineRow(entry: e).id(e.id) }
                                if !chat.caption.isEmpty {
                                    Label(chat.caption, systemImage: "waveform").font(.callout).foregroundColor(Theme.accentLight(.jarvis)).italic()
                                        .id("caption")
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(.horizontal, 14).padding(.top, 8)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: chat.entries.count) { _ in withAnimation { proxy.scrollTo("bottom") } }
                        .onChange(of: chat.entries.last?.text) { _ in proxy.scrollTo("bottom") }
                        .onChange(of: chat.caption) { _ in proxy.scrollTo("bottom") }
                        .onAppear { proxy.scrollTo("bottom") }
                    }
                    if !deck.approvals.isEmpty { approvalBar }
                    composer
                }
            }
            .navigationTitle("Chat").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) { BackToJarvisButton(); ConnectionPill() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if chat.busy { Button { chat.interrupt() } label: { Image(systemName: "stop.circle.fill") }.accessibilityLabel("Interrupt Jarvis") }
                        Menu {
                            Button(role: .destructive) { chat.stopAll() } label: { Label("Emergency stop (/stop)", systemImage: "exclamationmark.octagon") }
                            Button { Task { _ = await deck.newSession() } } label: { Label("New session", systemImage: "plus.bubble") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .toolbarBackground(Theme.void, for: .navigationBar)
        }
        .uploadPickers(picker)
        .onAppear { picker.configure(uploads: uploads, settings: settings, alerts: alerts) }
        .overlay(alignment: .top) { ToastView().environmentObject(picker) }
    }

    private var approvalBar: some View {
        VStack(spacing: 6) {
            ForEach(deck.approvals) { a in
                HStack {
                    VStack(alignment: .leading) {
                        Text("Approve \(a.tool ?? "action")?").font(.footnote.weight(.semibold)).foregroundColor(Theme.warn)
                        if let w = a.what, !w.isEmpty { Text(w).font(.system(.caption, design: .monospaced)).foregroundColor(Theme.dimText).lineLimit(2) }
                    }
                    Spacer()
                    Button { chat.approve(a.id, true) } label: { Image(systemName: "checkmark.circle.fill").font(.title2) }.tint(Theme.ok).accessibilityLabel("Approve")
                    Button { chat.approve(a.id, false) } label: { Image(systemName: "xmark.circle.fill").font(.title2) }.tint(Theme.bad).accessibilityLabel("Deny")
                }.padding(10).glass(Theme.warn)
            }
        }.padding(.horizontal, 12).padding(.bottom, 4)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if focused || chat.draft.hasPrefix("/") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(commands, id: \.self) { c in Button(c) { chat.draft = c + " " }.font(.system(.caption, design: .monospaced)).buttonStyle(.bordered) } }
                }.padding(.horizontal, 12)
            }
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(chat.attachments) { f in
                        HStack(spacing: 4) { Image(systemName: "paperclip"); Text(f.name).lineLimit(1)
                            Button { chat.attachments.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove \(f.name)")
                        }.font(.caption).padding(6).background(Capsule().fill(Color.white.opacity(0.1)))
                    } }
                }.padding(.horizontal, 12)
            }
            if let err = chat.error { Text(err).font(.caption).foregroundColor(Theme.warn) }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { picker.chooseFile() } label: { Label("Upload a file", systemImage: "doc") }
                    Button { picker.choosePhoto(to: .files) } label: { Label("Photo library", systemImage: "photo") }
                    Button { picker.takePhoto() } label: { Label("Take a photo", systemImage: "camera") }
                    Button { showAttachments = true } label: { Label("Attach an uploaded file", systemImage: "paperclip") }
                } label: { Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundColor(Theme.dimText) }
                .accessibilityLabel("Attach")
                TextField("Message Jarvis… (/ for commands)", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...5).focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
                    .submitLabel(.send).onSubmit { chat.submit() }
                Button { chat.submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundColor(Theme.accent(.jarvis)) }
                    .disabled(chat.draft.trimmingCharacters(in: .whitespaces).isEmpty && chat.attachments.isEmpty)
                    .accessibilityLabel("Send")
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
        .padding(.top, 6).background(Theme.void.opacity(0.9))
        .sheet(isPresented: $showAttachments) { NavigationStack { AttachPicker(isPresented: $showAttachments) } }
    }
}

struct AttachPicker: View {
    @EnvironmentObject var deck: DeckModel
    @EnvironmentObject var chat: ChatModel
    @Binding var isPresented: Bool
    var body: some View {
        List(deck.uploads) { f in
            Button { if !chat.attachments.contains(where: { $0.id == f.id }) { chat.attachments.append(f) }; isPresented = false } label: { FileRowLabel(file: f) }
        }
        .overlay { if deck.uploads.isEmpty { EmptyHint(icon: "paperclip", title: "No uploads yet", detail: "Upload a file first (the + button).") } }
        .navigationTitle("Attach").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } } }
        .task { await deck.loadFiles(kind: "upload") }
    }
}

struct TimelineRow: View {
    let entry: TimelineEntry
    var body: some View {
        switch entry.kind {
        case .user:
            HStack { Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 2) {
                    markdownText(entry.text).foregroundColor(Theme.text).textSelection(.enabled)
                        .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(Theme.persona("you").opacity(0.22)))
                    if entry.fromVoice { Label("voice", systemImage: "mic.fill").font(.caption2).foregroundColor(Theme.dimText) }
                }
            }
        case .assistant, .agent:
            let color = Theme.persona(entry.persona)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(entry.name).font(.caption.weight(.semibold)).foregroundColor(color)
                    if entry.streaming { ProgressView().scaleEffect(0.6) }
                    if entry.fromVoice { Image(systemName: "waveform").font(.caption2).foregroundColor(Theme.dimText) }
                }
                if !entry.text.isEmpty { markdownText(entry.text).foregroundColor(Theme.text).textSelection(.enabled) }
                else if entry.streaming { Text("…").foregroundColor(Theme.dimText) }
                if !entry.toolChips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(entry.toolChips) { c in PillLabel(text: c.label, color: c.state == .ok ? Theme.ok : (c.state == .failed ? Theme.bad : Theme.warn)) } }
                    }
                } else if !entry.tools.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(entry.tools, id: \.self) { PillLabel(text: $0, color: Theme.dimText) } } }
                }
                if entry.interrupted { Label(entry.detail.map { "Interrupted — heard: \($0)" } ?? "Interrupted", systemImage: "hand.raised").font(.caption).foregroundColor(Theme.warn) }
                if entry.failed, let d = entry.detail { Text(d).font(.caption).foregroundColor(Theme.bad) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.08)))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 8) }
        case .command:
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).font(.system(.footnote, design: .monospaced)).foregroundColor(Theme.accentLight(.jarvis))
                if let d = entry.detail, !d.isEmpty { Text(d).font(.system(.caption, design: .monospaced)).foregroundColor(entry.failed ? Theme.bad : Theme.dimText).textSelection(.enabled) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).glass()
        case .task:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.status == "done" ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundColor(entry.status == "done" ? Theme.ok : Theme.bad)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.name): \(entry.text)").font(.footnote.weight(.semibold)).foregroundColor(Theme.text)
                    if let d = entry.detail, !d.isEmpty { Text(d).font(.caption).foregroundColor(Theme.dimText).lineLimit(6) }
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).glass(Theme.persona(entry.persona))
        case .approval:
            Label("\(entry.status ?? "decided"): \(entry.text)", systemImage: "hand.raised").font(.caption).foregroundColor(Theme.dimText)
        case .note:
            Text(entry.text).font(.caption).foregroundColor(entry.failed ? Theme.bad : Theme.dimText).frame(maxWidth: .infinity, alignment: .center)
        case .session:
            VStack(spacing: 2) {
                Text(entry.name.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(Theme.dimText)
                if !entry.text.isEmpty { Text(entry.text).font(.caption).foregroundColor(Theme.dimText).lineLimit(4) }
            }.frame(maxWidth: .infinity).padding(.vertical, 6)
        case .file:
            if let f = entry.file { FileRow(file: f, compact: true) } else { Text(entry.text).font(.caption).foregroundColor(Theme.dimText) }
        case .caption:
            Text(entry.text).italic().foregroundColor(Theme.dimText)
        case .exec:
            ExecTimelineRow(entry: entry)
        }
    }
}

/// The live work in the chat timeline: who did what, how it went, the result on a tap.
struct ExecTimelineRow: View {
    let entry: TimelineEntry
    @State private var open = false
    var body: some View {
        let tint = entry.failed ? Theme.bad : Theme.persona(entry.persona)
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: ExecStyle.symbol(entry.execKind ?? "tool")).font(.system(size: 12, weight: .bold)).foregroundColor(tint)
                        .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(entry.name) · \(entry.text)").font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.text).lineLimit(2)
                        if let d = entry.detail, !d.isEmpty { Text(d).font(.system(size: 11)).foregroundColor(Theme.dimText).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if entry.status == "running" { ProgressView().scaleEffect(0.6) }
                    else if let ms = entry.execMs { Text(ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)).font(.system(size: 10, design: .monospaced)).foregroundColor(entry.failed ? Theme.bad : Theme.ok) }
                    if entry.execResult != nil { Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundColor(Theme.dimText) }
                }
            }.buttonStyle(.plain)
            if open, let r = entry.execResult { ExecResultView(result: r, tint: tint) }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading).glass(tint)
        .accessibilityElement(children: .contain)
    }
}
