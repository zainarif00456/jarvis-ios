import Foundation
import JarvisCore
import JarvisNet

public struct UploadItem: Identifiable, Equatable {
    public enum State: Equatable { case queued, uploading, done, failed(String), cancelled }
    public enum Destination: Equatable { case files, media }
    public let id = UUID()
    public var name: String
    public var mime: String
    public var size: Int
    public var destination: Destination
    public var source: String
    public var fileURL: URL
    public var progress: Double = 0
    public var state: State = .queued
    public var attempts = 0
    public var result: UploadResult?
    public var finished: Bool { if case .done = state { return true }; if case .cancelled = state { return true }; return false }
}

/// Uploads from the Files picker, the photo library and the camera, with progress, retries on network trouble and
/// cancellation. Files are copied into the app's temp folder by the UI first, so no security-scoped access is held.
@MainActor
public final class UploadModel: ObservableObject {
    @Published public private(set) var items: [UploadItem] = []
    public var apiProvider: () -> ApiClient? = { nil }
    /// Called after a file upload succeeds (the deck refreshes its list; chat can attach it).
    public var onUploaded: (UploadItem, UploadResult) -> Void = { _, _ in }
    public var maxFileBytes = 100 * 1024 * 1024
    public var maxMediaBytes = 500 * 1024 * 1024
    public var retryDelays: [Double] = [2, 5, 15]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var running = 0
    private let maxParallel = 2

    public init() {}

    public var activeCount: Int { items.filter { !$0.finished && !isFailed($0) }.count }
    private func isFailed(_ i: UploadItem) -> Bool { if case .failed = i.state { return true }; return false }

    /// Returns a message when the file is refused before any upload starts (too big, missing).
    @discardableResult
    public func enqueue(fileURL: URL, name: String, mime: String, destination: UploadItem.Destination, source: String = "") -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? -1
        if size < 0 { return "Could not read \(name)." }
        if size == 0 { return "\(name) is empty." }
        let limit = destination == .media ? maxMediaBytes : maxFileBytes
        if size > limit { return "\(name) is \(Format.bytes(size)); the limit is \(Format.bytes(limit))." }
        items.insert(UploadItem(name: Format.safeFileName(name), mime: mime, size: size, destination: destination, source: source, fileURL: fileURL), at: 0)
        pump()
        return nil
    }

    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        update(id) { if !$0.finished { $0.state = .cancelled } }
    }
    public func retry(_ id: UUID) { update(id) { $0.state = .queued; $0.progress = 0; $0.attempts = 0 }; pump() }
    public func remove(_ id: UUID) {
        tasks[id]?.cancel()
        if let item = items.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: item.fileURL) }
        items.removeAll { $0.id == id }
    }
    public func clearFinished() {
        for i in items where i.finished { try? FileManager.default.removeItem(at: i.fileURL) }
        items.removeAll { $0.finished }
    }

    private func update(_ id: UUID, _ change: (inout UploadItem) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    private func pump() {
        while running < maxParallel, let next = items.last(where: { $0.state == .queued }) {
            start(next)
        }
    }

    private func start(_ item: UploadItem) {
        running += 1
        update(item.id) { $0.state = .uploading; $0.progress = 0 }
        tasks[item.id] = Task { [weak self] in
            guard let self = self else { return }
            await self.perform(item.id)
            self.running -= 1; self.tasks[item.id] = nil
            self.pump()
        }
    }

    private func perform(_ id: UUID) async {
        while true {
            guard let item = items.first(where: { $0.id == id }), item.state == .uploading else { return }
            guard let api = apiProvider() else { update(id) { $0.state = .failed("Not connected to Jarvis.") }; return }
            let path = item.destination == .media ? "/api/media/upload" : "/api/uploads"
            var fields: [String: String] = [:]
            if item.destination == .media { fields = ["origin": "device"]; if !item.source.isEmpty { fields["source"] = item.source } }
            do {
                let res = try await api.upload(fileURL: item.fileURL, fileName: item.name, mime: item.mime, to: path, fields: fields) { p in
                    Task { @MainActor [weak self] in self?.update(id) { if $0.state == .uploading { $0.progress = p } } }
                }
                update(id) { $0.state = .done; $0.progress = 1; $0.result = res }
                try? FileManager.default.removeItem(at: item.fileURL)
                if let done = items.first(where: { $0.id == id }) { onUploaded(done, res) }
                return
            } catch is CancellationError {
                update(id) { $0.state = .cancelled }; return
            } catch let e as ApiError {
                update(id) { $0.attempts += 1 }
                let attempts = items.first(where: { $0.id == id })?.attempts ?? 99
                if e.isTransient, attempts <= retryDelays.count {
                    let delay = retryDelays[attempts - 1]
                    update(id) { $0.progress = 0 }
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                update(id) { $0.state = .failed(Self.explain(e)) }
                return
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
                return
            }
        }
    }

    static func explain(_ e: ApiError) -> String {
        if e.statusCode == 413 { return "Too large for the server." }
        if e.isUnauthorized { return "This phone is no longer paired." }
        return e.localizedDescription
    }
}
