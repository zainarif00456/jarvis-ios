import SwiftUI
import UIKit
import JarvisCore
import JarvisModel

/// A terminal drawn with UIKit: the `TerminalBuffer` grid as coloured text runs, scrollback by dragging, the soft
/// keyboard with an accessory row (Esc, Tab, Ctrl, arrows, symbols), hardware keyboard keys, paste.
final class TerminalUIView: UIView, UIKeyInput {
    weak var session: TerminalSession? {
        didSet {
            oldValue?.onUpdate = nil
            session?.onUpdate = { [weak self] in self?.contentChanged() }
            setNeedsLayout(); setNeedsDisplay()
        }
    }
    var fontSize: CGFloat = 12 { didSet { rebuildFonts(); setNeedsLayout(); setNeedsDisplay() } }

    private var font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var cell = CGSize(width: 7, height: 14)
    private var scrollOffset = 0          // lines scrolled back into history (0 = live)
    private var ctrlArmed = false { didSet { ctrlButton?.backgroundColor = ctrlArmed ? UIColor(Theme.accent(.jarvis)) : UIColor(white: 1, alpha: 0.12) } }
    private var ctrlButton: UIButton?
    private var lastSize = CGSize.zero

    // MARK: setup

    override init(frame: CGRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        backgroundColor = UIColor(red: 2 / 255, green: 8 / 255, blue: 13 / 255, alpha: 1)
        isOpaque = true
        contentMode = .redraw
        rebuildFonts()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityTraits = .allowsDirectInteraction
    }

    private func rebuildFonts() {
        font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        cell = CGSize(width: max(4, w.rounded(.up)), height: (font.lineHeight).rounded(.up))
    }

    // MARK: layout, size

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize, bounds.width > 20, bounds.height > 20 else { return }
        lastSize = bounds.size
        let cols = max(20, Int(bounds.width / cell.width))
        let rows = max(5, Int(bounds.height / cell.height))
        session?.resize(cols: cols, rows: rows)
        accessibilityValue = nil
    }

    private func contentChanged() {
        if scrollOffset > 0, let s = session { scrollOffset = min(scrollOffset, s.emulator.buffer.scrollback.count) }
        setNeedsDisplay()
        if let b = session?.emulator.buffer { accessibilityValue = b.lines().suffix(6).joined(separator: "\n") }
    }

    // MARK: drawing

    private func color(_ c: (UInt8, UInt8, UInt8)) -> UIColor { UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1) }

    override func draw(_ rect: CGRect) {
        guard let session = session, let ctx = UIGraphicsGetCurrentContext() else { return }
        let buf = session.emulator.buffer
        ctx.setFillColor(color(TermPalette.defaultBackground).cgColor)
        ctx.fill(rect)
        let hist = buf.scrollback
        let total = hist.count + buf.rows
        let firstLine = max(0, hist.count - scrollOffset)       // index of the first visible line in history+grid
        let firstRow = Int(max(0, rect.minY / cell.height)), lastRow = min(buf.rows - 1, Int(rect.maxY / cell.height))
        guard firstRow <= lastRow else { return }
        for row in firstRow...lastRow {
            let idx = firstLine + row
            guard idx < total else { break }
            let line = idx < hist.count ? hist[idx] : buf.grid[idx - hist.count]
            drawRow(line, y: CGFloat(row) * cell.height, ctx: ctx, cols: buf.cols)
        }
        if scrollOffset == 0, buf.cursorVisible, isFirstResponder, buf.cursorY < buf.rows {
            let r = CGRect(x: CGFloat(buf.cursorX) * cell.width, y: CGFloat(buf.cursorY) * cell.height, width: cell.width, height: cell.height)
            ctx.setFillColor(UIColor(Theme.accent(.jarvis)).withAlphaComponent(0.85).cgColor)
            ctx.fill(r)
            let c = buf.grid[buf.cursorY][min(buf.cursorX, buf.cols - 1)]
            if c.scalar > 32 { NSAttributedString(string: String(c.character), attributes: [.font: font, .foregroundColor: UIColor.black]).draw(at: r.origin) }
        }
    }

    private func drawRow(_ line: [Cell], y: CGFloat, ctx: CGContext, cols: Int) {
        var x = 0
        let n = min(line.count, cols)
        while x < n {
            let style = line[x].style
            var end = x + 1
            while end < n, line[end].style == style { end += 1 }
            let (fg, bg) = TermPalette.resolve(style)
            if bg != TermPalette.defaultBackground || style.attrs.contains(.inverse) {
                ctx.setFillColor(color(bg).cgColor)
                ctx.fill(CGRect(x: CGFloat(x) * cell.width, y: y, width: CGFloat(end - x) * cell.width, height: cell.height))
            }
            if !style.attrs.contains(.hidden) {
                // draw character by character so each lands on its grid column (box drawing, wide glyphs)
                for i in x..<end where line[i].scalar > 32 {
                    var attrs: [NSAttributedString.Key: Any] = [.font: style.attrs.contains(.bold) ? boldFont : font, .foregroundColor: color(fg)]
                    if style.attrs.contains(.underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if style.attrs.contains(.strike) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    NSAttributedString(string: String(line[i].character), attributes: attrs).draw(at: CGPoint(x: CGFloat(i) * cell.width, y: y))
                }
            }
            x = end
        }
    }

    // MARK: gestures

    @objc private func tapped() { becomeFirstResponder(); setNeedsDisplay() }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let s = session else { return }
        let dy = g.translation(in: self).y
        let lines = Int(dy / cell.height)
        if lines != 0 {
            scrollOffset = max(0, min(s.emulator.buffer.scrollback.count, scrollOffset + lines))
            g.setTranslation(.zero, in: self)
            setNeedsDisplay()
        }
    }

    func scrollToBottom() { scrollOffset = 0; setNeedsDisplay() }

    // MARK: keyboard input (UIKeyInput + UITextInputTraits)

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    func insertText(_ text: String) {
        scrollToBottom()
        if ctrlArmed, text.count == 1, let c = text.first, let data = TerminalKeys.control(c) { session?.send(data); ctrlArmed = false; return }
        ctrlArmed = false
        session?.send(text.replacingOccurrences(of: "\n", with: "\r"))
    }
    func deleteBackward() { scrollToBottom(); session?.sendKey(.backspace) }

    override func paste(_ sender: Any?) { if let s = UIPasteboard.general.string { session?.paste(s) } }
    override func copy(_ sender: Any?) { UIPasteboard.general.string = session?.emulator.buffer.text }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) ? UIPasteboard.general.hasStrings : action == #selector(copy(_:))
    }

    // hardware keyboard: arrows, escape, tab, ctrl+letter
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for p in presses {
            guard let key = p.key else { unhandled.insert(p); continue }
            switch key.keyCode {
            case .keyboardUpArrow: session?.sendKey(.up)
            case .keyboardDownArrow: session?.sendKey(.down)
            case .keyboardLeftArrow: session?.sendKey(.left)
            case .keyboardRightArrow: session?.sendKey(.right)
            case .keyboardEscape: session?.sendKey(.escape)
            case .keyboardTab: session?.sendKey(key.modifierFlags.contains(.shift) ? .backTab : .tab)
            case .keyboardHome: session?.sendKey(.home)
            case .keyboardEnd: session?.sendKey(.end)
            case .keyboardPageUp: session?.sendKey(.pageUp)
            case .keyboardPageDown: session?.sendKey(.pageDown)
            case .keyboardDeleteForward: session?.sendKey(.delete)
            default:
                if key.modifierFlags.contains(.control), let c = key.charactersIgnoringModifiers.first, let d = TerminalKeys.control(c) { session?.send(d) }
                else { unhandled.insert(p) }
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    // MARK: accessory row

    private lazy var accessory: UIInputView = {
        let v = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        v.allowsSelfSizing = true
        let scroll = UIScrollView(); scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 6; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        func button(_ title: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
            b.setTitleColor(.white, for: .normal)
            b.backgroundColor = UIColor(white: 1, alpha: 0.12)
            b.layer.cornerRadius = 6
            b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 11, bottom: 6, right: 11)
            b.accessibilityLabel = label
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return b
        }
        let ctrl = button("Ctrl", "Control modifier") { [weak self] in self?.ctrlArmed.toggle() }
        ctrlButton = ctrl
        let items: [UIButton] = [
            button("esc", "Escape") { [weak self] in self?.session?.sendKey(.escape) },
            button("tab", "Tab") { [weak self] in self?.session?.sendKey(.tab) },
            ctrl,
            button("↑", "Up") { [weak self] in self?.session?.sendKey(.up) },
            button("↓", "Down") { [weak self] in self?.session?.sendKey(.down) },
            button("←", "Left") { [weak self] in self?.session?.sendKey(.left) },
            button("→", "Right") { [weak self] in self?.session?.sendKey(.right) },
            button("|", "Pipe") { [weak self] in self?.insertText("|") },
            button("~", "Tilde") { [weak self] in self?.insertText("~") },
            button("/", "Slash") { [weak self] in self?.insertText("/") },
            button("-", "Dash") { [weak self] in self?.insertText("-") },
            button("^C", "Interrupt (Control C)") { [weak self] in self?.session?.send(Data([3])) },
            button("^D", "End of input (Control D)") { [weak self] in self?.session?.send(Data([4])) },
            button("Paste", "Paste") { [weak self] in self?.paste(nil) },
            button("Hide", "Hide keyboard") { [weak self] in self?.resignFirstResponder() },
        ]
        items.forEach { stack.addArrangedSubview($0) }
        scroll.addSubview(stack); v.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: v.topAnchor), scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            v.heightAnchor.constraint(equalToConstant: 44),
        ])
        return v
    }()

    override var inputAccessoryView: UIView? { accessory }
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); setNeedsDisplay(); return ok }
    override func resignFirstResponder() -> Bool { let ok = super.resignFirstResponder(); setNeedsDisplay(); return ok }
}

struct TerminalScreen: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    var fontSize: CGFloat
    func makeUIView(context: Context) -> TerminalUIView {
        let v = TerminalUIView()
        v.fontSize = fontSize
        v.session = session
        return v
    }
    func updateUIView(_ v: TerminalUIView, context: Context) {
        if v.session !== session { v.session = session }
        if v.fontSize != fontSize { v.fontSize = fontSize }
    }
}

/// The Terminal tab: the live terminals (the ones Jarvis and his agents opened, and yours), one at a time.
struct TerminalsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var deck: DeckModel
    @State private var selected: String?
    @AppStorage("terminalFontSize") private var fontSize = 12.0

    private var current: TerminalInfo? { deck.terminals.first { $0.id == selected } ?? deck.terminals.first { $0.id == deck.focusedTerminal } ?? deck.terminals.first }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.void.ignoresSafeArea()
                VStack(spacing: 0) {
                    tabs
                    if let t = current, let session = app.terminalSession(for: t) {
                        TerminalHost(session: session, fontSize: fontSize).id(t.id)
                    } else {
                        Spacer()
                        EmptyHint(icon: "terminal", title: "No terminals open", detail: "Open one here, or ask Jarvis or Friday to open one — it appears on this screen live.")
                        Button { deck.openTerminal() } label: { Label("New terminal", systemImage: "plus") }.buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Terminal").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) { BackToJarvisButton(); ConnectionPill() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Menu {
                            Button { fontSize = max(9, fontSize - 1) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                            Button { fontSize = min(20, fontSize + 1) } label: { Label("Larger text", systemImage: "textformat.size.larger") }
                            if let t = current {
                                Button(role: .destructive) { deck.closeTerminal(t.id); app.dropTerminalSession(t.id) } label: { Label("Close this terminal", systemImage: "xmark.circle") }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        Button { deck.openTerminal() } label: { Image(systemName: "plus") }.accessibilityLabel("New terminal")
                    }
                }
            }
            .toolbarBackground(Theme.void, for: .navigationBar)
        }
        .onChange(of: deck.focusedTerminal) { id in if let id = id { selected = id } }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(deck.terminals) { t in
                    Button { selected = t.id } label: {
                        HStack(spacing: 6) {
                            Circle().fill(t.busy == true ? Theme.warn : Theme.ok).frame(width: 7, height: 7)
                            Text(t.title ?? "zsh").lineLimit(1)
                            if let by = t.by, by != "owner" { PillLabel(text: Persona.of(by).name, color: Theme.persona(by)) }
                        }
                        .font(.footnote).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(current?.id == t.id ? Theme.accent(.jarvis).opacity(0.25) : Color.white.opacity(0.07)))
                        .foregroundColor(Theme.text)
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// Connects the terminal while it is on screen and shows its state.
struct TerminalHost: View {
    @ObservedObject var session: TerminalSession
    var fontSize: CGFloat
    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalScreen(session: session, fontSize: fontSize)
            statusBadge.padding(8)
        }
        .onAppear { session.connect() }
        .onDisappear { /* kept connected so output keeps arriving while another tab is open */ }
    }
    @ViewBuilder private var statusBadge: some View {
        switch session.status {
        case .live: EmptyView()
        case .connecting: PillLabel(text: "connecting…", color: Theme.warn)
        case .retrying: PillLabel(text: "reconnecting…", color: Theme.warn)
        case .failed(let why): PillLabel(text: why, color: Theme.bad).onTapGesture { session.disconnect(); session.connect() }
        case .stopped: PillLabel(text: "disconnected", color: Theme.dimText)
        }
    }
}
