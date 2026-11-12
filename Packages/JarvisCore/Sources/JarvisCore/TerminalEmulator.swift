import Foundation

/// Parses the byte stream of a terminal (UTF-8 text, control characters, ESC / CSI / OSC sequences) into a
/// `TerminalBuffer`. Designed for what shells, `vim`, `less`, `htop` and the agents' CLIs emit; it is a
/// practical xterm subset, not a full VT520.
public final class TerminalEmulator {
    public private(set) var buffer: TerminalBuffer
    /// Bytes the terminal must answer with (cursor position reports, device attributes).
    public var onResponse: ((Data) -> Void)?
    public var onBell: (() -> Void)?

    private enum State { case ground, escape, escapeIntermediate, csi, osc, oscEscape, dcs, dcsEscape, charset }
    private var state: State = .ground
    private var params: [Int] = []
    private var currentParam: Int? = nil
    private var intermediates: [UInt8] = []
    private var privateMarker: UInt8 = 0
    private var oscText: [UInt8] = []
    private var utf8Need = 0
    private var utf8Scalar: UInt32 = 0
    private var lineDrawing = false         // G0 set is the DEC special graphics set
    private var charsetTarget: UInt8 = 0

    public init(cols: Int = 80, rows: Int = 24) { buffer = TerminalBuffer(cols: cols, rows: rows) }

    public func resize(cols: Int, rows: Int) { buffer.resize(cols: cols, rows: rows) }
    public func reset() { buffer.reset(); state = .ground; utf8Need = 0 }

    public func feed(_ data: Data) { data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in for b in raw { step(b) } } }
    public func feed(_ text: String) { feed(Data(text.utf8)) }

    // MARK: byte state machine

    private func step(_ b: UInt8) {
        // control characters work in every state except inside an OSC / DCS string
        if b == 0x18 || b == 0x1A { state = .ground; return }       // CAN / SUB cancel a sequence
        if b == 0x1B && state != .osc && state != .dcs {
            if state == .ground { state = .escape; intermediates.removeAll(); return }
            state = .escape; intermediates.removeAll(); return
        }
        switch state {
        case .ground: ground(b)
        case .escape: escape(b)
        case .escapeIntermediate:
            if (0x20...0x2F).contains(b) { intermediates.append(b) } else { state = .ground }
        case .charset:
            if charsetTarget == UInt8(ascii: "(") { lineDrawing = (b == UInt8(ascii: "0")) }
            state = .ground
        case .csi: csi(b)
        case .osc:
            if b == 0x07 { finishOSC(); state = .ground }
            else if b == 0x1B { state = .oscEscape }
            else if oscText.count < 4096 { oscText.append(b) }
        case .oscEscape:
            if b == UInt8(ascii: "\\") { finishOSC(); state = .ground } else { state = .ground; escape(b) }
        case .dcs:
            if b == 0x1B { state = .dcsEscape } else if b == 0x07 { state = .ground }
        case .dcsEscape:
            state = .ground
        }
    }

    private func ground(_ b: UInt8) {
        if utf8Need > 0 {
            if b & 0xC0 == 0x80 {
                utf8Scalar = (utf8Scalar << 6) | UInt32(b & 0x3F); utf8Need -= 1
                if utf8Need == 0 { printScalar(utf8Scalar) }
                return
            }
            utf8Need = 0; printScalar(0xFFFD)   // broken sequence: fall through and treat b normally
        }
        switch b {
        case 0x07: onBell?()
        case 0x08: buffer.backspace()
        case 0x09: buffer.tab()
        case 0x0A, 0x0B, 0x0C: buffer.lineFeed()
        case 0x0D: buffer.carriageReturn()
        case 0x00...0x1F, 0x7F: break
        case 0x20...0x7E: printScalar(UInt32(b))
        case 0xC2...0xDF: utf8Need = 1; utf8Scalar = UInt32(b & 0x1F)
        case 0xE0...0xEF: utf8Need = 2; utf8Scalar = UInt32(b & 0x0F)
        case 0xF0...0xF4: utf8Need = 3; utf8Scalar = UInt32(b & 0x07)
        default: printScalar(0xFFFD)
        }
    }

    private static let lineDrawingMap: [UInt8: UInt32] = [
        0x6A: 0x2518, 0x6B: 0x2510, 0x6C: 0x250C, 0x6D: 0x2514, 0x6E: 0x253C, 0x71: 0x2500, 0x74: 0x251C,
        0x75: 0x2524, 0x76: 0x2534, 0x77: 0x252C, 0x78: 0x2502, 0x60: 0x25C6, 0x61: 0x2592, 0x66: 0x00B0, 0x67: 0x00B1, 0x7E: 0x00B7,
    ]

    private func printScalar(_ s: UInt32) {
        if lineDrawing, s < 0x80, let m = Self.lineDrawingMap[UInt8(s)] { buffer.put(m) } else { buffer.put(s) }
    }

    private func escape(_ b: UInt8) {
        switch b {
        case UInt8(ascii: "["):
            state = .csi; params.removeAll(); currentParam = nil; intermediates.removeAll(); privateMarker = 0
        case UInt8(ascii: "]"): state = .osc; oscText.removeAll()
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"): state = .dcs
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"):
            state = .charset; charsetTarget = b
        case 0x20...0x2F: intermediates.append(b); state = .escapeIntermediate
        case UInt8(ascii: "7"): buffer.saveCursor(); state = .ground
        case UInt8(ascii: "8"): buffer.restoreCursor(); state = .ground
        case UInt8(ascii: "D"): buffer.lineFeed(); state = .ground
        case UInt8(ascii: "E"): buffer.carriageReturn(); buffer.lineFeed(); state = .ground
        case UInt8(ascii: "M"): buffer.reverseIndex(); state = .ground
        case UInt8(ascii: "H"): buffer.setTabStop(); state = .ground
        case UInt8(ascii: "c"): reset()
        case UInt8(ascii: "="), UInt8(ascii: ">"): state = .ground
        default: state = .ground
        }
    }

    private func csi(_ b: UInt8) {
        switch b {
        case 0x30...0x39:
            currentParam = (currentParam ?? 0) * 10 + Int(b - 0x30)
            if let c = currentParam, c > 100_000 { currentParam = 100_000 }
        case UInt8(ascii: ";"), UInt8(ascii: ":"):
            params.append(currentParam ?? 0); currentParam = nil
            if params.count > 32 { state = .ground }
        case 0x3C...0x3F: privateMarker = b           // < = > ?
        case 0x20...0x2F: intermediates.append(b)
        case 0x40...0x7E:
            if currentParam != nil || !params.isEmpty { params.append(currentParam ?? 0) }
            dispatchCSI(b)
            state = .ground
        default: state = .ground
        }
    }

    private func p(_ i: Int, _ def: Int) -> Int {
        guard i < params.count, params[i] > 0 else { return def }
        return params[i]
    }

    private func dispatchCSI(_ final: UInt8) {
        let f = Character(Unicode.Scalar(final))
        if privateMarker == UInt8(ascii: "?") {
            if f == "h" || f == "l" { for m in params { setPrivateMode(m, on: f == "h") } }
            return
        }
        if privateMarker == UInt8(ascii: ">") {
            if f == "c" { respond("\u{1B}[>0;276;0c") }
            return
        }
        if privateMarker != 0 { return }
        if !intermediates.isEmpty { return }   // DECSCUSR (cursor shape) and friends: ignored
        switch f {
        case "A": buffer.moveBy(dx: 0, dy: -p(0, 1))
        case "B", "e": buffer.moveBy(dx: 0, dy: p(0, 1))
        case "C", "a": buffer.moveBy(dx: p(0, 1), dy: 0)
        case "D": buffer.moveBy(dx: -p(0, 1), dy: 0)
        case "E": buffer.moveBy(dx: 0, dy: p(0, 1)); buffer.carriageReturn()
        case "F": buffer.moveBy(dx: 0, dy: -p(0, 1)); buffer.carriageReturn()
        case "G", "`": buffer.setCursorColumn(p(0, 1) - 1)
        case "d": buffer.setCursorRow(p(0, 1) - 1)
        case "H", "f": buffer.moveTo(row: p(0, 1) - 1, col: p(1, 1) - 1)
        case "J": buffer.eraseInDisplay(params.first ?? 0)
        case "K": buffer.eraseInLine(params.first ?? 0)
        case "L": buffer.insertLines(p(0, 1))
        case "M": buffer.deleteLines(p(0, 1))
        case "P": buffer.deleteChars(p(0, 1))
        case "@": buffer.insertChars(p(0, 1))
        case "X": buffer.eraseChars(p(0, 1))
        case "S": buffer.scrollUp(p(0, 1))
        case "T": buffer.scrollDown(p(0, 1))
        case "m": sgr()
        case "r": buffer.setScrollRegion(top: p(0, 1) - 1, bottom: p(1, buffer.rows) - 1)
        case "s": buffer.saveCursor()
        case "u": buffer.restoreCursor()
        case "g": buffer.clearTabStops(all: (params.first ?? 0) == 3)
        case "h", "l": break    // ANSI modes (insert mode, LNM): not supported, harmless
        case "n":
            if params.first == 6 { respond("\u{1B}[\(buffer.cursorY + 1);\(buffer.cursorX + 1)R") }
            else if params.first == 5 { respond("\u{1B}[0n") }
        case "c": if (params.first ?? 0) == 0 { respond("\u{1B}[?1;2c") }
        case "t": break         // window manipulation: ignored
        default: break
        }
    }

    private func setPrivateMode(_ mode: Int, on: Bool) {
        switch mode {
        case 1: buffer.applicationCursorKeys = on
        case 6: buffer.originMode = on; buffer.moveTo(row: 0, col: 0)
        case 7: buffer.autowrap = on
        case 25: buffer.cursorVisible = on
        case 47, 1047: if on { buffer.enterAlternate() } else { buffer.leaveAlternate() }
        case 1049:
            if on { buffer.saveCursor(); buffer.enterAlternate() } else { buffer.leaveAlternate(); buffer.restoreCursor() }
        case 2004: buffer.bracketedPaste = on
        default: break          // mouse reporting, focus events, ...: not supported
        }
    }

    private func sgr() {
        if params.isEmpty { buffer.style = TermStyle(); return }
        var i = 0
        while i < params.count {
            let v = params[i]
            switch v {
            case 0: buffer.style = TermStyle()
            case 1: buffer.style.attrs.insert(.bold)
            case 2: buffer.style.attrs.insert(.dim)
            case 3: buffer.style.attrs.insert(.italic)
            case 4: buffer.style.attrs.insert(.underline)
            case 7: buffer.style.attrs.insert(.inverse)
            case 8: buffer.style.attrs.insert(.hidden)
            case 9: buffer.style.attrs.insert(.strike)
            case 22: buffer.style.attrs.remove([.bold, .dim])
            case 23: buffer.style.attrs.remove(.italic)
            case 24: buffer.style.attrs.remove(.underline)
            case 27: buffer.style.attrs.remove(.inverse)
            case 28: buffer.style.attrs.remove(.hidden)
            case 29: buffer.style.attrs.remove(.strike)
            case 30...37: buffer.style.fg = .indexed(UInt8(v - 30))
            case 39: buffer.style.fg = .default
            case 40...47: buffer.style.bg = .indexed(UInt8(v - 40))
            case 49: buffer.style.bg = .default
            case 90...97: buffer.style.fg = .indexed(UInt8(v - 90 + 8))
            case 100...107: buffer.style.bg = .indexed(UInt8(v - 100 + 8))
            case 38, 48:
                let isFg = v == 38
                if i + 2 < params.count, params[i + 1] == 5 {
                    let c = TermColor.indexed(UInt8(max(0, min(255, params[i + 2]))))
                    if isFg { buffer.style.fg = c } else { buffer.style.bg = c }
                    i += 2
                } else if i + 4 < params.count, params[i + 1] == 2 {
                    let c = TermColor.rgb(UInt8(max(0, min(255, params[i + 2]))), UInt8(max(0, min(255, params[i + 3]))), UInt8(max(0, min(255, params[i + 4]))))
                    if isFg { buffer.style.fg = c } else { buffer.style.bg = c }
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    private func finishOSC() {
        let text = String(decoding: oscText, as: UTF8.self)
        if let semi = text.firstIndex(of: ";") {
            let code = text[text.startIndex..<semi]
            if code == "0" || code == "2" { buffer.title = String(text[text.index(after: semi)...]) }
        }
    }

    private func respond(_ s: String) { onResponse?(Data(s.utf8)) }
}

/// What the keys send. The accessory row (Esc, Tab, Ctrl, arrows) and hardware keys go through here.
public enum TerminalKeys {
    public enum Special { case up, down, left, right, home, end, pageUp, pageDown, escape, tab, backTab, enter, backspace, delete }

    public static func bytes(for key: Special, applicationCursor: Bool = false) -> Data {
        let esc = "\u{1B}"
        let arrow: (String) -> String = { applicationCursor ? "\(esc)O\($0)" : "\(esc)[\($0)" }
        switch key {
        case .up: return Data(arrow("A").utf8)
        case .down: return Data(arrow("B").utf8)
        case .right: return Data(arrow("C").utf8)
        case .left: return Data(arrow("D").utf8)
        case .home: return Data(arrow("H").utf8)
        case .end: return Data(arrow("F").utf8)
        case .pageUp: return Data("\(esc)[5~".utf8)
        case .pageDown: return Data("\(esc)[6~".utf8)
        case .delete: return Data("\(esc)[3~".utf8)
        case .escape: return Data([0x1B])
        case .tab: return Data([0x09])
        case .backTab: return Data("\(esc)[Z".utf8)
        case .enter: return Data([0x0D])
        case .backspace: return Data([0x7F])
        }
    }

    /// Ctrl + a letter (or one of `[ \ ] ^ _ @ ?`) -> its control byte; nil for anything else.
    public static func control(_ c: Character) -> Data? {
        guard let a = c.asciiValue else { return nil }
        let up = (a >= 97 && a <= 122) ? a - 32 : a
        switch up {
        case 64...95: return Data([up - 64])
        case 63: return Data([0x7F])
        case 32: return Data([0])
        default: return nil
        }
    }

    /// Wraps pasted text when the program asked for bracketed paste (so editors do not auto-indent it).
    public static func paste(_ text: String, bracketed: Bool) -> Data {
        let t = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        return Data((bracketed ? "\u{1B}[200~\(t)\u{1B}[201~" : t).utf8)
    }
}
