import Foundation

public enum TermColor: Equatable, Sendable {
    case `default`
    case indexed(UInt8)          // 0-255 xterm palette
    case rgb(UInt8, UInt8, UInt8)
}

public struct CellAttrs: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let bold = CellAttrs(rawValue: 1)
    public static let dim = CellAttrs(rawValue: 2)
    public static let italic = CellAttrs(rawValue: 4)
    public static let underline = CellAttrs(rawValue: 8)
    public static let inverse = CellAttrs(rawValue: 16)
    public static let strike = CellAttrs(rawValue: 32)
    public static let hidden = CellAttrs(rawValue: 64)
}

public struct TermStyle: Equatable, Sendable {
    public var fg: TermColor = .default
    public var bg: TermColor = .default
    public var attrs: CellAttrs = []
    public init() {}
}

public struct Cell: Equatable, Sendable {
    public var scalar: UInt32 = 32      // 0 marks the right half of a wide character
    public var style = TermStyle()
    public init() {}
    public init(scalar: UInt32, style: TermStyle) { self.scalar = scalar; self.style = style }
    public var character: Character { scalar == 0 ? " " : Character(Unicode.Scalar(scalar) ?? " ") }
}

/// The screen of a terminal: a grid, scrollback, a cursor and the modes programs switch on and off.
/// It is fed by `TerminalEmulator` (the byte parser) and read by the view.
public struct TerminalBuffer: Sendable {
    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var grid: [[Cell]]
    public private(set) var scrollback: [[Cell]] = []
    public var maxScrollback = 2000

    public var cursorX = 0
    public var cursorY = 0
    public var cursorVisible = true
    public var wrapPending = false
    public var autowrap = true
    public var style = TermStyle()
    public var scrollTop = 0
    public var scrollBottom: Int          // inclusive
    public var applicationCursorKeys = false
    public var bracketedPaste = false
    public var originMode = false
    public var title = ""
    public private(set) var usingAlternate = false
    /// Bumped on every change so a view knows when to redraw.
    public private(set) var revision = 0

    private var savedCursor = (x: 0, y: 0, style: TermStyle())
    private var mainSaved: (grid: [[Cell]], cx: Int, cy: Int)?
    private var tabStops: Set<Int>

    public init(cols: Int = 80, rows: Int = 24) {
        let c = max(2, cols), r = max(1, rows)
        self.cols = c; self.rows = r
        grid = Array(repeating: Array(repeating: Cell(), count: c), count: r)
        scrollBottom = r - 1
        tabStops = Set(stride(from: 8, to: c, by: 8))
    }

    // MARK: size

    public mutating func resize(cols newCols: Int, rows newRows: Int) {
        let c = max(2, newCols), r = max(1, newRows)
        guard c != cols || r != rows else { return }
        // keep the bottom of the screen: when it shrinks, push top lines into scrollback
        if r < rows && !usingAlternate {
            let drop = max(0, min(rows - r, cursorY + 1 - r > 0 ? cursorY + 1 - r : 0))
            for _ in 0..<drop { scrollback.append(grid.removeFirst()); cursorY -= 1 }
            trimScrollback()
        }
        for i in grid.indices {
            if grid[i].count < c { grid[i].append(contentsOf: Array(repeating: Cell(), count: c - grid[i].count)) }
            else if grid[i].count > c { grid[i].removeLast(grid[i].count - c) }
        }
        while grid.count < r { grid.append(Array(repeating: Cell(), count: c)) }
        if grid.count > r { grid.removeLast(grid.count - r) }
        cols = c; rows = r
        scrollTop = 0; scrollBottom = r - 1
        cursorX = min(cursorX, c - 1); cursorY = max(0, min(cursorY, r - 1)); wrapPending = false
        tabStops = Set(stride(from: 8, to: c, by: 8))
        touch()
    }

    private mutating func touch() { revision &+= 1 }
    private mutating func trimScrollback() { if scrollback.count > maxScrollback { scrollback.removeFirst(scrollback.count - maxScrollback) } }

    // MARK: printing

    public mutating func put(_ scalar: UInt32) {
        let width = Self.width(of: scalar)
        if width == 0 {  // combining mark: joins the previous cell, which a cell grid cannot show; drop it
            return
        }
        if wrapPending && autowrap {
            wrapPending = false
            cursorX = 0
            lineFeed()
        }
        if width == 2 && cursorX == cols - 1 {
            if autowrap { cursorX = 0; lineFeed() } else { return }
        }
        if cursorX >= cols { cursorX = cols - 1 }
        clearWideOverlap(row: cursorY, col: cursorX)
        grid[cursorY][cursorX] = Cell(scalar: scalar, style: style)
        if width == 2, cursorX + 1 < cols {
            clearWideOverlap(row: cursorY, col: cursorX + 1)
            grid[cursorY][cursorX + 1] = Cell(scalar: 0, style: style)
        }
        let next = cursorX + width
        if next >= cols { cursorX = cols - 1; wrapPending = true } else { cursorX = next }
        touch()
    }

    private mutating func clearWideOverlap(row: Int, col: Int) {
        if grid[row][col].scalar == 0, col > 0 { grid[row][col - 1] = blank() }
        if col + 1 < cols, grid[row][col + 1].scalar == 0, Self.width(of: grid[row][col].scalar) == 2 { grid[row][col + 1] = blank() }
    }

    private func blank() -> Cell {
        var c = Cell(); c.style.bg = style.bg   // erased cells take the current background colour
        return c
    }

    // MARK: movement

    public mutating func lineFeed() {
        if cursorY == scrollBottom { scrollUp(1) }
        else if cursorY < rows - 1 { cursorY += 1 }
        touch()
    }
    public mutating func reverseIndex() {
        if cursorY == scrollTop { scrollDown(1) } else if cursorY > 0 { cursorY -= 1 }
        touch()
    }
    public mutating func carriageReturn() { cursorX = 0; wrapPending = false }
    public mutating func backspace() { if cursorX > 0 { cursorX -= 1 }; wrapPending = false }
    public mutating func tab() {
        wrapPending = false
        var x = cursorX + 1
        while x < cols - 1 && !tabStops.contains(x) { x += 1 }
        cursorX = min(x, cols - 1)
    }
    public mutating func setTabStop() { tabStops.insert(cursorX) }
    public mutating func clearTabStops(all: Bool) { if all { tabStops.removeAll() } else { tabStops.remove(cursorX) } }

    public mutating func moveTo(row: Int, col: Int) {
        let top = originMode ? scrollTop : 0
        let bottom = originMode ? scrollBottom : rows - 1
        cursorY = max(top, min(bottom, top + row)); cursorX = max(0, min(cols - 1, col)); wrapPending = false
    }
    public mutating func moveBy(dx: Int, dy: Int) {
        cursorX = max(0, min(cols - 1, cursorX + dx))
        cursorY = max(0, min(rows - 1, cursorY + dy)); wrapPending = false
    }
    public mutating func setCursorColumn(_ c: Int) { cursorX = max(0, min(cols - 1, c)); wrapPending = false }
    public mutating func setCursorRow(_ r: Int) { cursorY = max(0, min(rows - 1, r)); wrapPending = false }

    public mutating func saveCursor() { savedCursor = (cursorX, cursorY, style) }
    public mutating func restoreCursor() { cursorX = min(savedCursor.x, cols - 1); cursorY = min(savedCursor.y, rows - 1); style = savedCursor.style; wrapPending = false }

    // MARK: scrolling and erasing

    public mutating func scrollUp(_ n: Int) {
        let count = max(1, min(n, scrollBottom - scrollTop + 1))
        for _ in 0..<count {
            let line = grid.remove(at: scrollTop)
            if scrollTop == 0 && !usingAlternate { scrollback.append(line) }
            grid.insert(Array(repeating: blank(), count: cols), at: scrollBottom)
        }
        trimScrollback(); touch()
    }
    public mutating func scrollDown(_ n: Int) {
        let count = max(1, min(n, scrollBottom - scrollTop + 1))
        for _ in 0..<count {
            grid.remove(at: scrollBottom)
            grid.insert(Array(repeating: blank(), count: cols), at: scrollTop)
        }
        touch()
    }
    public mutating func setScrollRegion(top: Int, bottom: Int) {
        let t = max(0, min(top, rows - 1)), b = max(0, min(bottom, rows - 1))
        guard t < b else { scrollTop = 0; scrollBottom = rows - 1; moveTo(row: 0, col: 0); return }
        scrollTop = t; scrollBottom = b
        moveTo(row: 0, col: 0)
    }

    public mutating func eraseInLine(_ mode: Int) {
        let b = blank()
        switch mode {
        case 0: for x in cursorX..<cols { grid[cursorY][x] = b }
        case 1: for x in 0...min(cursorX, cols - 1) { grid[cursorY][x] = b }
        default: for x in 0..<cols { grid[cursorY][x] = b }
        }
        touch()
    }
    public mutating func eraseInDisplay(_ mode: Int) {
        let b = blank()
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorY + 1 < rows { for y in (cursorY + 1)..<rows { grid[y] = Array(repeating: b, count: cols) } }
        case 1:
            eraseInLine(1)
            if cursorY > 0 { for y in 0..<cursorY { grid[y] = Array(repeating: b, count: cols) } }
        case 3:
            scrollback.removeAll()
            for y in 0..<rows { grid[y] = Array(repeating: b, count: cols) }
        default:
            for y in 0..<rows { grid[y] = Array(repeating: b, count: cols) }
        }
        touch()
    }
    public mutating func eraseChars(_ n: Int) {
        let b = blank()
        for x in cursorX..<min(cols, cursorX + max(1, n)) { grid[cursorY][x] = b }
        touch()
    }
    public mutating func deleteChars(_ n: Int) {
        let k = min(max(1, n), cols - cursorX)
        grid[cursorY].removeSubrange(cursorX..<(cursorX + k))
        grid[cursorY].append(contentsOf: Array(repeating: blank(), count: k))
        touch()
    }
    public mutating func insertChars(_ n: Int) {
        let k = min(max(1, n), cols - cursorX)
        grid[cursorY].insert(contentsOf: Array(repeating: blank(), count: k), at: cursorX)
        grid[cursorY].removeLast(k)
        touch()
    }
    public mutating func insertLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let k = min(max(1, n), scrollBottom - cursorY + 1)
        for _ in 0..<k {
            grid.remove(at: scrollBottom)
            grid.insert(Array(repeating: blank(), count: cols), at: cursorY)
        }
        cursorX = 0; touch()
    }
    public mutating func deleteLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let k = min(max(1, n), scrollBottom - cursorY + 1)
        for _ in 0..<k {
            grid.remove(at: cursorY)
            grid.insert(Array(repeating: blank(), count: cols), at: scrollBottom)
        }
        cursorX = 0; touch()
    }

    // MARK: alternate screen (vim, less, htop)

    public mutating func enterAlternate(clear: Bool = true) {
        guard !usingAlternate else { return }
        mainSaved = (grid, cursorX, cursorY)
        usingAlternate = true
        if clear { grid = Array(repeating: Array(repeating: Cell(), count: cols), count: rows) }
        scrollTop = 0; scrollBottom = rows - 1
        touch()
    }
    public mutating func leaveAlternate() {
        guard usingAlternate else { return }
        usingAlternate = false
        if let s = mainSaved {
            grid = s.grid
            // the window may have been resized while in the alternate screen
            for i in grid.indices {
                if grid[i].count < cols { grid[i].append(contentsOf: Array(repeating: Cell(), count: cols - grid[i].count)) }
                else if grid[i].count > cols { grid[i].removeLast(grid[i].count - cols) }
            }
            while grid.count < rows { grid.append(Array(repeating: Cell(), count: cols)) }
            if grid.count > rows { grid.removeFirst(grid.count - rows) }
            cursorX = min(s.cx, cols - 1); cursorY = min(s.cy, rows - 1)
        }
        mainSaved = nil
        scrollTop = 0; scrollBottom = rows - 1
        touch()
    }

    public mutating func reset() {
        let c = cols, r = rows
        self = TerminalBuffer(cols: c, rows: r)
    }

    // MARK: reading

    /// The visible text, one string per row, trailing blanks trimmed (used by tests and accessibility).
    public func lines() -> [String] {
        grid.map { row in
            var s = String(row.map { $0.scalar == 0 ? "" : String($0.character) }.joined())
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }
    }
    public var text: String { lines().joined(separator: "\n") }

    // MARK: character width

    /// Terminal cell width of a scalar: 0 (combining), 1, or 2 (East Asian wide, emoji).
    public static func width(of s: UInt32) -> Int {
        if s < 0x300 { return 1 }
        if (0x0300...0x036F).contains(s) || (0x200B...0x200F).contains(s) || (0xFE00...0xFE0F).contains(s) || s == 0x20E3 { return 0 }
        if (0x1100...0x115F).contains(s) || (0x2E80...0x303E).contains(s) || (0x3041...0x33FF).contains(s) ||
            (0x3400...0x4DBF).contains(s) || (0x4E00...0x9FFF).contains(s) || (0xA000...0xA4CF).contains(s) ||
            (0xAC00...0xD7A3).contains(s) || (0xF900...0xFAFF).contains(s) || (0xFE30...0xFE6F).contains(s) ||
            (0xFF00...0xFF60).contains(s) || (0xFFE0...0xFFE6).contains(s) || (0x1F300...0x1F64F).contains(s) ||
            (0x1F900...0x1F9FF).contains(s) || (0x20000...0x3FFFD).contains(s) { return 2 }
        return 1
    }
}

/// Terminal colours as RGB bytes: the 16 ANSI colours (a dark theme), the 6x6x6 cube and the grey ramp of xterm-256.
public enum TermPalette {
    public static let ansi: [(UInt8, UInt8, UInt8)] = [
        (0x1e, 0x25, 0x2b), (0xf8, 0x71, 0x71), (0x34, 0xd3, 0x99), (0xf5, 0x9e, 0x0b), (0x60, 0xa5, 0xfa), (0xc0, 0x84, 0xfc), (0x4c, 0xc9, 0xf0), (0xcb, 0xd5, 0xe1),
        (0x47, 0x55, 0x69), (0xfc, 0xa5, 0xa5), (0x6e, 0xe7, 0xb7), (0xfc, 0xd3, 0x4d), (0x93, 0xc5, 0xfd), (0xd8, 0xb4, 0xfe), (0x9b, 0xe8, 0xff), (0xf8, 0xfa, 0xfc),
    ]
    public static let defaultForeground: (UInt8, UInt8, UInt8) = (0xd7, 0xe3, 0xee)
    public static let defaultBackground: (UInt8, UInt8, UInt8) = (0x02, 0x08, 0x0d)

    public static func rgb(_ index: UInt8) -> (UInt8, UInt8, UInt8) {
        let i = Int(index)
        if i < 16 { return ansi[i] }
        if i < 232 {
            let n = i - 16
            func level(_ v: Int) -> UInt8 { v == 0 ? 0 : UInt8(55 + v * 40) }
            return (level(n / 36), level((n / 6) % 6), level(n % 6))
        }
        let g = UInt8(8 + (i - 232) * 10)
        return (g, g, g)
    }

    /// Resolves a cell's colours, applying bold-as-bright for the first 8 colours, dim and inverse.
    public static func resolve(_ style: TermStyle) -> (fg: (UInt8, UInt8, UInt8), bg: (UInt8, UInt8, UInt8)) {
        func pick(_ c: TermColor, _ fallback: (UInt8, UInt8, UInt8), bright: Bool) -> (UInt8, UInt8, UInt8) {
            switch c {
            case .default: return fallback
            case .indexed(let i): return rgb(bright && i < 8 ? i + 8 : i)
            case .rgb(let r, let g, let b): return (r, g, b)
            }
        }
        var fg = pick(style.fg, defaultForeground, bright: style.attrs.contains(.bold))
        var bg = pick(style.bg, defaultBackground, bright: false)
        if style.attrs.contains(.inverse) { swap(&fg, &bg) }
        if style.attrs.contains(.dim) { fg = (fg.0 / 2 + bg.0 / 2, fg.1 / 2 + bg.1 / 2, fg.2 / 2 + bg.2 / 2) }
        return (fg, bg)
    }
}
