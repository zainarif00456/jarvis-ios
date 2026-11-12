import Foundation

public struct PRect: Equatable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var centerX: Double { x + w / 2 }
    public var centerY: Double { y + h / 2 }
}

/// The browser's layout engine (`js/workspace/layout.js`), ported: pure functions that return a rectangle per portal.
/// Modes: orbit (default; around the docked core), grid, focus (one big + a column), side_by_side, cascade.
public enum PortalLayout {
    public static let gap = 18.0
    public static let modes = ["orbit", "grid", "focus", "side_by_side", "cascade"]

    /// `core` = the orb's centre and radius when it is docked in the area.
    public static func rects(_ mode: String, count n: Int, area a: PRect, core: (x: Double, y: Double, r: Double)? = nil) -> [PRect] {
        guard n > 0 else { return [] }
        let out: [PRect]
        switch mode {
        case "orbit": out = orbit(n, a, core)
        case "focus": out = focus(n, a)
        case "side_by_side": out = sideBySide(n, a)
        case "cascade": out = cascade(n, a)
        default: out = grid(n, a)
        }
        return out.map { PRect(x: $0.x.rounded(), y: $0.y.rounded(), w: max(120, $0.w).rounded(), h: max(100, $0.h).rounded()) }
    }

    static func grid(_ n: Int, _ a: PRect) -> [PRect] {
        let cols = Int(Double(n).squareRoot().rounded(.up)); let rows = Int((Double(n) / Double(cols)).rounded(.up))
        let cw = (a.w - gap * Double(cols - 1)) / Double(cols), ch = (a.h - gap * Double(rows - 1)) / Double(rows)
        return (0..<n).map { i in PRect(x: a.x + Double(i % cols) * (cw + gap), y: a.y + Double(i / cols) * (ch + gap), w: cw, h: ch) }
    }
    static func focus(_ n: Int, _ a: PRect) -> [PRect] {
        guard n >= 2 else { return grid(n, a) }
        let side = max(160, (a.w * 0.28).rounded())
        var out = [PRect(x: a.x, y: a.y, w: a.w - side - gap, h: a.h)]
        let each = (a.h - gap * Double(n - 2)) / Double(n - 1)
        for i in 1..<n { out.append(PRect(x: a.x + a.w - side, y: a.y + Double(i - 1) * (each + gap), w: side, h: each)) }
        return out
    }
    static func sideBySide(_ n: Int, _ a: PRect) -> [PRect] {
        guard n >= 2 else { return grid(n, a) }
        let half = (a.w - gap) / 2
        var out = [PRect(x: a.x, y: a.y, w: half, h: a.h), PRect(x: a.x + half + gap, y: a.y, w: half, h: a.h)]
        if n > 2 { for i in 2..<n { out.append(PRect(x: a.x + 40 * Double(i - 1), y: a.y + 40 * Double(i - 1), w: half, h: a.h * 0.8)) } }
        return out
    }
    static func cascade(_ n: Int, _ a: PRect) -> [PRect] {
        let w = min(a.w * 0.62, 980), h = min(a.h * 0.7, 660)
        return (0..<n).map { PRect(x: a.x + 36 * Double($0), y: a.y + 32 * Double($0), w: w, h: h) }
    }
    static func orbit(_ n: Int, _ a: PRect, _ core: (x: Double, y: Double, r: Double)?) -> [PRect] {
        guard let core = core else { return grid(n, a) }
        let below = min(a.y + a.h, core.y + core.r + gap)
        let under = PRect(x: a.x, y: below, w: a.w, h: a.y + a.h - below)
        let left = PRect(x: a.x, y: a.y, w: core.x - core.r - gap - a.x, h: a.h)
        let rx = core.x + core.r + gap
        let right = PRect(x: rx, y: a.y, w: a.x + a.w - rx, h: a.h)
        let flank = min(left.w, right.w)
        let midX = core.x - core.r, midW = core.r * 2
        if n == 1 { let w = min(a.w * 0.74, 1180); return [PRect(x: a.x + (a.w - w) / 2, y: under.y, w: w, h: under.h)] }
        if flank < 300 || under.h < 220 { return grid(n, under.h >= 220 ? under : a) }
        if n == 2 { return [left, right] }
        if n == 3 { return [left, right, PRect(x: midX, y: under.y, w: midW, h: under.h)] }
        if n == 4 {
            let h = (a.h - gap) / 2
            return [PRect(x: left.x, y: left.y, w: left.w, h: h), PRect(x: right.x, y: right.y, w: right.w, h: h),
                    PRect(x: left.x, y: a.y + h + gap, w: left.w, h: h), PRect(x: right.x, y: a.y + h + gap, w: right.w, h: h)]
        }
        return grid(n, under)
    }

    /// A phone is too narrow for flank columns: the "orbit" there places the portals on a ring around the orb as small
    /// floating cards (scale `s`), centred on `core`. Returns the centre of each portal.
    public static func ring(count n: Int, around core: (x: Double, y: Double), radius: Double, start: Double = -Double.pi / 2) -> [(x: Double, y: Double)] {
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            let a = start + 2 * Double.pi * Double(i) / Double(n)
            return (core.x + radius * cos(a), core.y + radius * sin(a))
        }
    }
}
