import Foundation
import JarvisCore

public enum PortalKind: String, CaseIterable, Sendable {
    case chat, terminal, cameras, files, file, media, schedule, settings, activity, sessions, report, debrief, newTerminal, briefings
    public var title: String {
        switch self {
        case .chat: return "Chat"; case .terminal: return "Terminal"; case .cameras: return "Cameras"; case .files: return "Files"
        case .file: return "File"; case .media: return "Media"; case .schedule: return "Schedules"; case .settings: return "Settings"
        case .activity: return "Activity"; case .sessions: return "Sessions"; case .report: return "Report"; case .debrief: return "Debrief"
        case .newTerminal: return "New terminal"; case .briefings: return "Briefings"
        }
    }
    public var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"; case .terminal, .newTerminal: return "terminal.fill"; case .cameras: return "video.fill"
        case .files, .file: return "folder.fill"; case .media: return "photo.on.rectangle.angled"; case .schedule: return "calendar.badge.clock"
        case .settings: return "gearshape.fill"; case .activity: return "list.bullet.rectangle"; case .sessions: return "clock.arrow.circlepath"
        case .report: return "doc.richtext.fill"; case .debrief: return "rectangle.3.group.fill"; case .briefings: return "newspaper.fill"
        }
    }
}

/// The deck of holographic portals on Home: which are open, where, how big, which is in front. Pure state (no views), so the
/// layout, the commands Jarvis sends (`screen_cmd`) and the `screen_state` it receives are unit tested.
@MainActor
public final class PortalModel: ObservableObject {
    public struct Portal: Identifiable, Equatable {
        public var id: String
        public var kind: PortalKind
        public var title: String
        public var itemId: String?
        public var itemName: String?
        public var rect: PRect                  // frame on the stage (points)
        public var scale: Double = 1            // pinch zoom (0.5...2.5) applied around the centre
        public var minimised = false
        public var full = false
        public var pinned = false               // placed by hand: auto layout leaves it
        public var z: Int = 0
        public var persona: String?
    }

    @Published public private(set) var portals: [Portal] = [] { didSet { onChange() } }
    @Published public private(set) var layout = "orbit" { didSet { onChange() } }
    /// Fires after every change (the screen controller reports the new `screen_state`).
    public var onChange: () -> Void = {}
    @Published public var viewport = PRect(x: 0, y: 0, w: 390, h: 700)
    /// Where the orb sits on the stage, so portals can float around it.
    public var core: (x: Double, y: Double, r: Double) = (195, 170, 110)
    private var zCounter = 0

    public init() {}

    public var visible: [Portal] { portals.filter { !$0.minimised }.sorted { $0.z < $1.z } }
    public var top: Portal? { visible.last }
    public func portal(_ id: String) -> Portal? { portals.first { $0.id == id } }
    public var isEmpty: Bool { portals.isEmpty }

    /// Opens a portal, or brings the one that is already open to the front (same id = same portal).
    @discardableResult
    public func open(_ kind: PortalKind, id: String? = nil, title: String? = nil, itemId: String? = nil, itemName: String? = nil, persona: String? = nil) -> Portal {
        let pid = id ?? kind.rawValue
        if let i = portals.firstIndex(where: { $0.id == pid }) {
            portals[i].minimised = false
            if let t = title { portals[i].title = t }
            raise(pid)
            return portals[i]
        }
        zCounter += 1
        let p = Portal(id: pid, kind: kind, title: title ?? kind.title, itemId: itemId, itemName: itemName, rect: defaultRect(), z: zCounter, persona: persona)
        portals.append(p)
        arrangeAuto()
        return portal(pid) ?? p
    }

    public func raise(_ id: String) {
        guard let i = portals.firstIndex(where: { $0.id == id }) else { return }
        zCounter += 1; portals[i].z = zCounter
    }
    public func close(_ id: String) { portals.removeAll { $0.id == id }; arrangeAuto() }
    @discardableResult public func closeAll() -> Int { let n = portals.count; portals.removeAll(); return n }
    public func minimise(_ id: String) { if let i = portals.firstIndex(where: { $0.id == id }) { portals[i].minimised = true; portals[i].full = false } }
    public func restore(_ id: String) { if let i = portals.firstIndex(where: { $0.id == id }) { portals[i].minimised = false; raise(id) } }
    public func setFull(_ id: String, _ on: Bool) {
        guard let i = portals.firstIndex(where: { $0.id == id }) else { return }
        portals[i].full = on; portals[i].minimised = false
        if on { raise(id) }
    }
    public func move(_ id: String, dx: Double, dy: Double) {
        guard let i = portals.firstIndex(where: { $0.id == id }) else { return }
        portals[i].rect.x += dx; portals[i].rect.y += dy; portals[i].pinned = true
    }
    public func setScale(_ id: String, _ s: Double) {
        guard let i = portals.firstIndex(where: { $0.id == id }) else { return }
        portals[i].scale = min(2.5, max(0.5, s))
    }
    public func zoom(_ id: String, by f: Double) { if let p = portal(id) { setScale(id, p.scale * f) } }

    // MARK: layout

    /// A new portal appears in the middle of the free area under the orb, phone-sized.
    func defaultRect() -> PRect {
        let w = min(viewport.w - 24, 420)
        let top = min(viewport.h * 0.35, core.y + core.r + 12)
        return PRect(x: (viewport.w - w) / 2, y: top, w: w, h: max(240, viewport.h - top - 90))
    }

    /// Arranges every unpinned, visible portal by `mode` (`orbit`, `grid`, `focus`, `side_by_side`, `cascade`).
    /// Pinned ones (moved by hand) stay where the owner put them.
    @discardableResult
    public func arrange(_ mode: String, main: String? = nil, order: [String] = []) -> String {
        let m = PortalLayout.modes.contains(mode) ? mode : "grid"
        layout = m
        var ids = visible.map { $0.id }
        if !order.isEmpty { ids = order.filter { ids.contains($0) } + ids.filter { !order.contains($0) } }
        if let main = main, let i = ids.firstIndex(of: main) { ids.remove(at: i); ids.insert(main, at: 0) }
        let free = ids.filter { id in !(portal(id)?.pinned ?? false) }
        let area = PRect(x: 12, y: 12, w: viewport.w - 24, h: viewport.h - 100)
        let rects = PortalLayout.rects(m, count: free.count, area: area, core: core)
        for (id, r) in zip(free, rects) { if let i = portals.firstIndex(where: { $0.id == id }) { portals[i].rect = r; portals[i].scale = 1; portals[i].full = false } }
        return "\(m): \(free.count) portals"
    }
    func arrangeAuto() {
        // a lone portal keeps the phone-sized default; two or more settle by the current layout
        if visible.count >= 2 { arrange(layout == "orbit" ? "orbit" : layout) }
    }

    // MARK: what Jarvis sees

    public func snapshot(mode: String = "stage", extra: [String: ScreenReportState] = [:]) -> ScreenSnapshot {
        let topId = top?.id
        let windows = portals.map { p in
            ScreenWindowState(id: p.id, kind: p.kind.rawValue, title: p.title, itemType: p.itemId != nil || p.itemName != nil ? p.kind.rawValue : nil, itemId: p.itemId, itemName: p.itemName,
                              active: p.id == topId, full: p.full, minimised: p.minimised,
                              rect: [Int(p.rect.x), Int(p.rect.y), Int(p.rect.w * p.scale), Int(p.rect.h * p.scale)], report: extra[p.id])
        }
        return ScreenSnapshot(windows: windows, viewport: [Int(viewport.w), Int(viewport.h)], compact: true, mode: mode, layout: layout, pinned: portals.filter { $0.pinned }.map { $0.id })
    }
}
