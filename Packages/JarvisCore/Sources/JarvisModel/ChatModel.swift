import Foundation
import JarvisCore
import JarvisNet

/// The admin chat: history, streaming replies, user messages, voice captions, in one timeline.
@MainActor
public final class ChatModel: ObservableObject {
    @Published public private(set) var timeline = TimelineReducer()
    @Published public var draft = ""
    @Published public private(set) var loadingOlder = false
    @Published public private(set) var error: String?
    @Published public var attachments: [FileInfo] = []

    public var sendMessage: (ClientMessage) -> Bool = { _ in false }
    public var apiProvider: () -> ApiClient? = { nil }

    public init() {}

    public var entries: [TimelineEntry] { timeline.entries }
    public var busy: Bool { timeline.busy }
    public var caption: String { timeline.caption }

    public func setHistory(_ items: [HistoryItem]) { timeline.setHistory(items) }
    public func apply(_ m: ServerMessage) { timeline.apply(m) }

    /// Sends the draft (and any attached uploads). Slash commands go as they are: the server runs them.
    @discardableResult
    public func submit() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return false }
        let body = text.isEmpty ? "(see attached)" : text
        let ids = attachments.map { $0.id }
        guard sendMessage(.userMessage(text: body, attachments: ids)) else { error = "Not connected yet. Your message was kept."; return false }
        error = nil
        if !(body.hasPrefix("/") && ids.isEmpty) { timeline.addLocalUser(body + (attachments.isEmpty ? "" : "\n📎 " + attachments.map { $0.name }.joined(separator: ", "))) }
        draft = ""; attachments = []
        return true
    }

    public func approve(_ id: String, _ ok: Bool) { _ = sendMessage(.approval(id: id, approve: ok)) }
    public func interrupt() { _ = sendMessage(.interrupt) }
    public func stopAll() { _ = sendMessage(.stopAll) }

    public func loadOlder() async {
        guard !loadingOlder, timeline.hasOlder, let before = timeline.oldestSeq, let api = apiProvider() else { return }
        loadingOlder = true; defer { loadingOlder = false }
        do {
            let r: HistoryResponse = try await api.get("/api/history", query: [("before", String(before)), ("limit", String(TimelineReducer.pageSize))])
            timeline.prepend(r.items)
        } catch { self.error = error.localizedDescription }
    }
}
