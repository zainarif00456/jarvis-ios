import SwiftUI
import QuickLook
import JarvisCore
import JarvisModel

func fileIcon(_ f: FileInfo) -> String {
    if f.isImage { return "photo" }
    if f.isPDF { return "doc.richtext" }
    if f.isVideo { return "film" }
    if f.mime.hasPrefix("audio/") { return "waveform" }
    if f.isTextual { return "doc.text" }
    if f.mime.contains("zip") || f.mime.contains("tar") { return "doc.zipper" }
    return "doc"
}

struct FileRowLabel: View {
    let file: FileInfo
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: fileIcon(file)).font(.title3).foregroundColor(Theme.accentLight(.jarvis)).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline).foregroundColor(Theme.text).lineLimit(1)
                Text([Format.bytes(file.size), file.owner.map { $0 == "you" ? "from you" : "by \(Persona.of($0).name)" }, file.createdAt.flatMap(Format.parseISO).map { $0.formatted(date: .abbreviated, time: .shortened) }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundColor(Theme.dimText).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One file: tap to preview, long-press / menu to share, hide or delete.
struct FileRow: View {
    let file: FileInfo
    var compact = false
    @EnvironmentObject var deck: DeckModel
    @State private var preview: FileInfo?
    @State private var shareURL: URL?
    @State private var showShare = false

    var body: some View {
        HStack {
            Button { preview = file } label: { FileRowLabel(file: file) }.buttonStyle(.plain)
            Menu {
                Button { preview = file } label: { Label("Open", systemImage: "eye") }
                ShareFileButton(file: file) { shareURL = $0; showShare = true }
                Divider()
                Button { Task { await deck.removeFile(file) } } label: { Label("Hide from the list", systemImage: "eye.slash") }
                Button(role: .destructive) { Task { await deck.removeFile(file, purge: true) } } label: { Label("Delete from the server", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36).foregroundColor(Theme.dimText) }
            .accessibilityLabel("Actions for \(file.name)")
        }
        .sheet(item: $preview) { f in NavigationStack { FilePreviewView(file: f) } }
        .background(ShareSheetPresenter(isPresented: $showShare, url: shareURL))
    }
}

/// Downloads the file, then hands the local URL to `onReady` (the host presents the share sheet: a sheet cannot be
/// presented from inside a Menu, which disappears as soon as an item is tapped).
struct ShareFileButton: View {
    let file: FileInfo
    var onReady: (URL) -> Void
    @EnvironmentObject var app: AppModel
    var body: some View {
        Button {
            Task {
                guard let api = app.api else { return }
                do { onReady(try await api.download(path: "/api/files/\(file.id)/download", suggestedName: file.name) { _ in }) }
                catch { app.deck.report(error) }
            }
        } label: { Label("Share…", systemImage: "square.and.arrow.up") }
    }
}

/// Presents UIActivityViewController for a file URL (works from inside a Menu, where ShareLink cannot).
struct ShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var url: URL?
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard isPresented, let url = url, vc.presentedViewController == nil else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in isPresented = false; try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        if let pop = sheet.popoverPresentationController { pop.sourceView = vc.view; pop.sourceRect = vc.view.bounds }
        DispatchQueue.main.async { vc.present(sheet, animated: true) }
    }
}

struct FilesView: View {
    enum Kind: String, CaseIterable { case output = "Shared with you", upload = "Your uploads" }
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var deck: DeckModel
    @EnvironmentObject var uploads: UploadModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var alerts: PermissionAlerts
    @StateObject private var picker = UploadController()
    @State private var kind: Kind = .output
    @State private var confirmClear = false

    private var list: [FileInfo] { kind == .output ? deck.files : deck.uploads }

    var body: some View {
        NavigationStack {
            ZStack {
                StageBackground(accent: Theme.accent(.jarvis))
                VStack(spacing: 0) {
                    Picker("List", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).padding(12)
                    if !uploads.items.isEmpty { UploadsList().padding(.horizontal, 12).padding(.bottom, 8) }
                    List {
                        ForEach(list) { f in FileRow(file: f).listRowBackground(Theme.panel.opacity(0.7)) }
                            .onDelete { idx in for i in idx { let f = list[i]; Task { await deck.removeFile(f) } } }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .overlay { if list.isEmpty { EmptyHint(icon: "folder", title: kind == .output ? "Nothing shared yet" : "No uploads yet", detail: kind == .output ? "Files Jarvis and his agents share appear here at once." : "Use + to upload a file or a photo.") } }
                    .refreshable { await deck.loadFiles(kind: kind == .output ? "output" : "upload") }
                }
            }
            .navigationTitle("Files").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) { BackToJarvisButton(); ConnectionPill() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Menu {
                            Button { picker.chooseFile() } label: { Label("Choose a file…", systemImage: "doc") }
                            Button { picker.choosePhoto(to: .files) } label: { Label("Photo library…", systemImage: "photo") }
                            Button { picker.takePhoto() } label: { Label("Take a photo…", systemImage: "camera") }
                        } label: { Image(systemName: "plus") }.accessibilityLabel("Upload")
                        Menu {
                            Button(role: .destructive) { confirmClear = true } label: { Label("Clear this list", systemImage: "xmark.bin") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .toolbarBackground(Theme.void, for: .navigationBar)
            .confirmationDialog("Clear the list? Files are only hidden, not deleted.", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { Task { await deck.clearFiles(kind: kind == .output ? "output" : "upload") } }
            }
        }
        .uploadPickers(picker)
        .overlay(alignment: .top) { ToastView().environmentObject(picker) }
        .onAppear { picker.configure(uploads: uploads, settings: settings, alerts: alerts); deck.markFilesSeen() }
        .task(id: kind) { await deck.loadFiles(kind: kind == .output ? "output" : "upload") }
    }
}

/// The upload queue: progress, cancel, retry.
struct UploadsList: View {
    @EnvironmentObject var uploads: UploadModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(uploads.items) { u in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: u.destination == .media ? "photo" : "doc").foregroundColor(Theme.dimText)
                        Text(u.name).font(.footnote).foregroundColor(Theme.text).lineLimit(1)
                        Spacer()
                        stateView(u)
                    }
                    if u.state == .uploading || u.state == .queued { ProgressView(value: u.progress).tint(Theme.accent(.jarvis)) }
                    if case .failed(let why) = u.state { Text(why).font(.caption).foregroundColor(Theme.bad) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(u.name), \(label(u))")
            }
            if uploads.items.contains(where: { $0.finished }) { Button("Clear finished") { uploads.clearFinished() }.font(.caption) }
        }
    }
    private func label(_ u: UploadItem) -> String {
        switch u.state { case .queued: return "waiting"; case .uploading: return "uploading \(Format.percent(u.progress))"; case .done: return "uploaded"; case .failed(let w): return "failed: \(w)"; case .cancelled: return "cancelled" }
    }
    @ViewBuilder private func stateView(_ u: UploadItem) -> some View {
        switch u.state {
        case .queued, .uploading:
            HStack(spacing: 6) { Text(Format.percent(u.progress)).font(.caption).foregroundColor(Theme.dimText)
                Button { uploads.cancel(u.id) } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Cancel upload") }
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.ok)
        case .failed: Button { uploads.retry(u.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }.font(.caption)
        case .cancelled: Button { uploads.remove(u.id) } label: { Image(systemName: "trash") }
        }
    }
}

// MARK: preview

@MainActor
final class FilePreviewModel: ObservableObject {
    enum State { case loading(Double), image(UIImage), text(String, truncated: Bool), pdf(pages: Int), local(URL), failed(String) }
    @Published var state: State = .loading(0)
    let file: FileInfo
    init(file: FileInfo) { self.file = file }

    func load(api: ApiClient?) async {
        guard let api = api else { state = .failed("Not connected."); return }
        do {
            if file.isPDF {
                struct R: Decodable { let pages: Int }
                let r: R = try await api.get("/api/files/\(file.id)/pages")
                state = .pdf(pages: r.pages)
            } else if file.isTextual && file.size <= 400_000 {
                struct R: Decodable { let text: String; let truncated: Bool? }
                let r: R = try await api.get("/api/files/\(file.id)/preview")
                state = .text(r.text, truncated: r.truncated ?? false)
            } else {
                let url = try await api.download(path: "/api/files/\(file.id)/download", suggestedName: file.name) { [weak self] p in Task { @MainActor in self?.state = .loading(p) } }
                if file.isImage, let img = UIImage(contentsOfFile: url.path) { state = .image(img) } else { state = .local(url) }
            }
        } catch is CancellationError { return }
        catch { state = .failed(error.localizedDescription) }
    }
}

struct FilePreviewView: View {
    let file: FileInfo
    @StateObject private var model: FilePreviewModel
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var showShare = false
    init(file: FileInfo) { self.file = file; _model = StateObject(wrappedValue: FilePreviewModel(file: file)) }

    var body: some View {
        Group {
            switch model.state {
            case .loading(let p): VStack(spacing: 12) { ProgressView(value: p > 0 ? p : nil); Text("Loading \(file.name)…").font(.footnote).foregroundColor(Theme.dimText) }.padding(40)
            case .image(let img): ScrollView([.horizontal, .vertical]) { Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity) }.accessibilityLabel(file.name)
            case .text(let t, let truncated): ScrollView { VStack(alignment: .leading) {
                Text(t).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                if truncated { Text("(preview truncated — share the file for the rest)").font(.caption).foregroundColor(Theme.dimText) } }.padding() }
            case .pdf(let pages): PDFPagesView(file: file, pages: pages)
            case .local(let url): QuickLookView(url: url)
            case .failed(let why): EmptyHint(icon: "exclamationmark.triangle", title: "Could not open this file", detail: why)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.void)
        .navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { SmartCloseButton() }
            ToolbarItem(placement: .primaryAction) { ShareFileButton(file: file) { shareURL = $0; showShare = true } }
        }
        .background(ShareSheetPresenter(isPresented: $showShare, url: shareURL))
        .task { await model.load(api: app.api) }
    }
}

/// PDF pages are drawn by the server (PNG per page), fetched as they scroll into view.
struct PDFPagesView: View {
    let file: FileInfo
    let pages: Int
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) { ForEach(1...max(1, pages), id: \.self) { n in PDFPage(file: file, number: n) } }.padding(8)
        }
    }
}

struct PDFPage: View {
    let file: FileInfo
    let number: Int
    @EnvironmentObject var app: AppModel
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image = image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Page \(number)") }
            else if failed { Text("Page \(number) could not load").font(.caption).foregroundColor(Theme.bad).frame(height: 120) }
            else { ProgressView().frame(height: 300) }
        }
        .frame(maxWidth: .infinity).background(Color.white.opacity(image == nil ? 0.05 : 0))
        .task {
            guard image == nil, let api = app.api else { return }
            do {
                let (data, _) = try await api.rawGet("/api/files/\(file.id)/pages/\(number)", query: [("width", "1024")], timeout: 60)
                image = UIImage(data: data); failed = image == nil
            } catch { failed = true }
        }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController(); c.dataSource = context.coordinator; return c
    }
    func updateUIViewController(_ vc: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ u: URL) { url = u }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
