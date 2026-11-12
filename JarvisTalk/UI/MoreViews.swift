import SwiftUI
import PhotosUI
import JarvisCore
import JarvisModel

// MARK: media library

struct MediaView: View {
    @ObservedObject var picker: UploadController
    @EnvironmentObject var deck: DeckModel
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var uploads: UploadModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MediaItem?
    @State private var label = ""
    @State private var note = ""

    var body: some View {
        List {
            if !uploads.items.isEmpty { Section("Uploading") { UploadsList() } }
            Section {
                ForEach(deck.media) { m in
                    Button { editing = m; label = m.source ?? ""; note = m.note ?? "" } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(m)).frame(width: 28).foregroundColor(Theme.accentLight(.jarvis))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name ?? m.id).font(.subheadline).foregroundColor(Theme.text).lineLimit(1)
                                Text([m.kind, m.source, m.size.map(Format.bytes), m.durationS.map { Format.duration($0) }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundColor(Theme.dimText).lineLimit(1)
                                if let n = m.note, !n.isEmpty { Text(n).font(.caption).foregroundColor(Theme.dimText).lineLimit(2) }
                            }
                        }
                    }.listRowBackground(Theme.panel.opacity(0.7))
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.void)
        .overlay { if deck.media.isEmpty { EmptyHint(icon: "photo.on.rectangle", title: "The media library is empty", detail: "Photos and clips from your cameras and this phone show up here.") } }
        .navigationTitle("Media").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { SmartCloseButton() }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { picker.choosePhoto(to: .media) } label: { Label("Photo library…", systemImage: "photo") }
                    Button { picker.takePhoto() } label: { Label("Take a photo…", systemImage: "camera") }
                } label: { Image(systemName: "plus") }.accessibilityLabel("Add to the library")
            }
        }
        .refreshable { await deck.loadMedia() }
        .task { await deck.loadMedia() }
        .sheet(item: $editing) { m in
            NavigationStack {
                Form {
                    Section("Where it came from") { TextField("Label", text: $label) }
                    Section("Note") { TextField("Note", text: $note, axis: .vertical).lineLimit(1...5) }
                    if let p = m.path { Section("Saved on the server") { Text(p).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                }
                .navigationTitle(m.name ?? "Media").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await deck.labelMedia(m, source: label, note: note); editing = nil } } }
                }
            }
        }
    }
    private func icon(_ m: MediaItem) -> String {
        switch m.kind { case "image": return "photo"; case "video": return "film"; case "audio": return "waveform"; default: return "doc" }
    }
}

// MARK: schedules

struct SchedulesView: View {
    @EnvironmentObject var deck: DeckModel
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var editing: ScheduleItem?

    var body: some View {
        List {
            if let s = deck.schedules.scheduler, s.ok == false {
                Label("The scheduler has not ticked for a while (\(s.ageS.map { "\($0) s" } ?? "unknown")). Jobs may be late.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundColor(Theme.warn).listRowBackground(Theme.panel.opacity(0.7))
            }
            ForEach(deck.schedules.items) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(s.title).font(.subheadline.weight(.semibold)).foregroundColor(Theme.text)
                        Spacer()
                        PillLabel(text: s.status ?? "active", color: s.status == "active" ? Theme.ok : (s.status == "paused" ? Theme.warn : Theme.dimText))
                    }
                    if let d = s.description, !d.isEmpty { Text(d).font(.caption).foregroundColor(Theme.dimText).lineLimit(3) }
                    Text([s.triggerText, s.nextText.map { "next \($0)" }, s.agent.map { Persona.of($0).name }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundColor(Theme.accentLight(.jarvis))
                }
                .listRowBackground(Theme.panel.opacity(0.7))
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { Task { await deck.deleteSchedule(s) } } label: { Label("Delete", systemImage: "trash") }
                    if s.status == "active" { Button { Task { await deck.scheduleAction(s, "pause") } } label: { Label("Pause", systemImage: "pause") }.tint(Theme.warn) }
                    if s.status == "paused" { Button { Task { await deck.scheduleAction(s, "resume") } } label: { Label("Resume", systemImage: "play") }.tint(Theme.ok) }
                }
                .contextMenu {
                    Button { Task { await deck.scheduleAction(s, "run") } } label: { Label("Run now", systemImage: "play.circle") }
                    Button { Task { await deck.scheduleAction(s, "snooze", minutes: 10) } } label: { Label("Snooze 10 minutes", systemImage: "zzz") }
                    Button { editing = s } label: { Label("Edit", systemImage: "pencil") }
                    Button { Task { await deck.scheduleAction(s, "cancel") } } label: { Label("Cancel", systemImage: "xmark.circle") }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.void)
        .overlay { if deck.schedules.items.isEmpty { EmptyHint(icon: "calendar.badge.clock", title: "Nothing scheduled", detail: "Ask Jarvis to remind you, or add one with +.") } }
        .navigationTitle("Schedules").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { SmartCloseButton() }
            ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New schedule") }
        }
        .refreshable { await deck.loadSchedules() }
        .task { await deck.loadSchedules() }
        .sheet(isPresented: $creating) { NavigationStack { NewScheduleView() } }
        .sheet(item: $editing) { s in NavigationStack { EditScheduleView(item: s) } }
    }
}

struct NewScheduleView: View {
    @EnvironmentObject var deck: DeckModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var mode = "remind"
    @State private var repeating = false
    @State private var minutes = 30.0
    @State private var saving = false

    var body: some View {
        Form {
            Section("What") {
                TextField("Title", text: $title)
                TextField("Details (what Jarvis should do or say)", text: $detail, axis: .vertical).lineLimit(2...6)
                Picker("Kind", selection: $mode) { Text("Remind me").tag("remind"); Text("Jarvis does it").tag("do"); Text("An agent does it").tag("agent") }
            }
            Section("When") {
                Toggle("Repeat every…", isOn: $repeating)
                Stepper(value: $minutes, in: 1...10080, step: minutes < 60 ? 5 : 30) { Text(repeating ? "Every \(Format.duration(minutes * 60))" : "In \(Format.duration(minutes * 60))") }
            }
        }
        .navigationTitle("New schedule").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task { let ok = await deck.createSchedule(title: title, description: detail.isEmpty ? title : detail, mode: mode, inMinutes: repeating ? nil : minutes, everyMinutes: repeating ? minutes : nil); saving = false; if ok { dismiss() } }
                }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
    }
}

struct EditScheduleView: View {
    let item: ScheduleItem
    @EnvironmentObject var deck: DeckModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var detail: String
    init(item: ScheduleItem) { self.item = item; _title = State(initialValue: item.title); _detail = State(initialValue: item.description ?? "") }
    var body: some View {
        Form {
            TextField("Title", text: $title)
            TextField("Details", text: $detail, axis: .vertical).lineLimit(2...6)
        }
        .navigationTitle("Edit").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await deck.editSchedule(item, title: title, description: detail); dismiss() } } }
        }
    }
}

// MARK: activity

struct ActivityView: View {
    @EnvironmentObject var deck: DeckModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if !deck.approvals.isEmpty {
                Section("Approvals") {
                    ForEach(deck.approvals) { a in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(a.tool ?? "action").font(.subheadline.weight(.semibold))
                            if let w = a.what { Text(w).font(.system(.caption, design: .monospaced)).foregroundColor(Theme.dimText) }
                            HStack { Button("Approve") { deck.approve(a.id, true) }.buttonStyle(.borderedProminent).tint(Theme.ok); Button("Deny") { deck.approve(a.id, false) }.buttonStyle(.bordered).tint(Theme.bad) }
                        }
                    }
                }
            }
            Section("Tasks") {
                ForEach(deck.tasks) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Circle().fill(Theme.persona(t.owner)).frame(width: 8, height: 8)
                            Text("\(t.name ?? "Agent") — \(t.title ?? "")").font(.subheadline).lineLimit(2); Spacer(); PillLabel(text: t.status, color: color(t)) }
                        if let p = t.progress, t.isActive { ProgressView(value: p) }
                        if let s = t.summary ?? t.error, !s.isEmpty { Text(s).font(.caption).foregroundColor(Theme.dimText).lineLimit(5) }
                        if let e = t.elapsedS { Text(Format.duration(e)).font(.caption2).foregroundColor(Theme.dimText) }
                        if t.isActive { Button("Cancel", role: .destructive) { deck.cancelTask(t.id) }.font(.caption) }
                    }
                }
            }
            if let team = deck.agents?.agents, !team.isEmpty {
                Section("Team") {
                    ForEach(team) { a in
                        HStack { Circle().fill(Theme.persona(a.key)).frame(width: 8, height: 8)
                            VStack(alignment: .leading) { Text(a.name ?? a.key.capitalized); Text(a.role ?? a.detail ?? "").font(.caption).foregroundColor(Theme.dimText) }
                            Spacer(); PillLabel(text: a.available == false ? "unavailable" : (a.warm == true ? "warm" : "ready"), color: a.available == false ? Theme.bad : Theme.ok) }
                    }
                }
            }
            if !deck.recordings.isEmpty {
                Section("Recordings") {
                    ForEach(deck.recordings) { r in
                        HStack { Image(systemName: "record.circle").foregroundColor(r.isLive ? Theme.hot : Theme.dimText)
                            VStack(alignment: .leading) { Text(r.name ?? r.kind ?? "Recording"); Text(r.line ?? r.note ?? r.state ?? "").font(.caption).foregroundColor(Theme.dimText) }
                            Spacer()
                            if r.isLive { Button("Stop") { Task { await deck.recordingAction(r, "stop") } }.buttonStyle(.bordered) } }
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.void)
        .navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { SmartCloseButton() } }
        .task { await deck.loadRecordings() }
    }
    private func color(_ t: TaskInfo) -> Color { t.status == "done" ? Theme.ok : (t.isActive ? Theme.warn : Theme.bad) }
}

// MARK: sessions

struct SessionsView: View {
    @EnvironmentObject var deck: DeckModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var message: String?
    var body: some View {
        List {
            if let m = message { Text(m).font(.footnote).foregroundColor(Theme.dimText) }
            if query.count >= 2 {
                Section("Matches") {
                    ForEach(Array(deck.searchMatches.enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Session \(m.session ?? 0) · \(m.who ?? "")").font(.caption).foregroundColor(Theme.accentLight(.jarvis))
                            Text(m.text ?? "").font(.footnote).lineLimit(4)
                        }
                    }
                }
            } else {
                Section("Sessions") {
                    ForEach(deck.sessions) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text("Session \(s.number)").font(.subheadline.weight(.semibold)); if s.current == true { PillLabel(text: "current", color: Theme.ok) }; Spacer()
                                Text("\(s.ownerMessages ?? 0) messages").font(.caption).foregroundColor(Theme.dimText) }
                            if let n = s.notes, !n.isEmpty { Text(n).font(.caption).foregroundColor(Theme.dimText).lineLimit(4) }
                            if let t = s.startedAt.flatMap(Format.parseISO) { Text(t.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundColor(Theme.dimText) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.void)
        .searchable(text: $query, prompt: "Search every session")
        .onChange(of: query) { q in Task { await deck.searchSessions(q) } }
        .navigationTitle("Sessions").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { SmartCloseButton() }
            ToolbarItem(placement: .primaryAction) { Button { Task { message = await deck.newSession(); await deck.loadSessions() } } label: { Label("New session", systemImage: "plus.bubble") } }
        }
        .task { await deck.loadSessions() }
    }
}
