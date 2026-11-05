import AppKit
import NetScopeCore
import SwiftUI

// Note 57 : vue AppKit du terminal intégré. Dessine l'écran de l'émulateur en police à chasse
// fixe (grille exacte : les caractères hors ASCII sont placés un à un), gère la sélection et le
// copier-coller, le défilement de l'historique, la recherche, le curseur clignotant et tout le
// clavier (flèches, Ctrl, Option comme Méta, touches de fonction, touches mortes par NSTextInputClient).

final class TerminalTextView: NSView, NSTextInputClient {
    weak var session: TerminalSession? {
        didSet { attach() }
    }
    var appearanceSetting: TerminalAppearance = .dark { didSet { needsDisplay = true } }
    var optionAsMeta = false
    var fontSize: CGFloat = 12 {
        didSet {
            guard fontSize != oldValue else { return }
            updateFont()
            updateGrid()
        }
    }
    /// Captures : curseur fixe, pas de minuterie.
    var isStatic = false

    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var cellWidth: CGFloat = 7
    private var cellHeight: CGFloat = 15
    private var baseline: CGFloat = 12
    private let inset = NSSize(width: 10, height: 8)

    /// Lignes remontées dans l'historique (0 : bas de l'écran).
    private var scrollOffset = 0
    private var scrollRemainder: CGFloat = 0
    private var lastAbsoluteEnd = 0
    private var lastDropped = 0
    private var selection: (anchor: TerminalPosition, head: TerminalPosition)?
    private var selectionMode = 0
    private var cursorOn = true
    private var blinkTimer: Timer?
    private var markedText = ""
    private var scrollIndicatorUntil = Date.distantPast

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        updateFont()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) n’est pas utilisé") }

    deinit {
        blinkTimer?.invalidate()
    }

    private var palette: TerminalPalette { appearanceSetting.palette(for: effectiveAppearance) }

    // MARK: Liaison avec la session

    private func attach() {
        guard let session else { return }
        session.onOutput = { [weak self] in self?.sessionChanged() }
        session.onReveal = { [weak self] match in self?.reveal(match) }
        lastAbsoluteEnd = session.emulator.scrollback.count + session.emulator.scrollback.dropped
        lastDropped = session.emulator.scrollback.dropped
        updateGrid()
        needsDisplay = true
    }

    private func sessionChanged() {
        guard let emulator = session?.emulator else { return }
        // Historique consulté : la vue reste sur les mêmes lignes pendant que la sortie arrive.
        let end = emulator.scrollback.count + emulator.scrollback.dropped
        let dropped = emulator.scrollback.dropped
        if scrollOffset > 0 {
            scrollOffset = min(scrollOffset + (end - lastAbsoluteEnd), emulator.scrollback.count)
        }
        if dropped != lastDropped, let current = selection {
            let shift = dropped - lastDropped
            selection = (TerminalPosition(line: current.anchor.line - shift, column: current.anchor.column),
                         TerminalPosition(line: current.head.line - shift, column: current.head.column))
        }
        lastAbsoluteEnd = end
        lastDropped = dropped
        cursorOn = true
        needsDisplay = true
    }

    private func updateFont() {
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        cellHeight = ceil(font.ascender - font.descender + font.leading + 2)
        baseline = font.ascender + 1
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
    }

    private func updateGrid() {
        guard let session, bounds.width > 40, bounds.height > 20 else { return }
        let columns = max(Int((bounds.width - inset.width * 2) / cellWidth), 20)
        let rows = max(Int((bounds.height - inset.height * 2) / cellHeight), 4)
        session.resize(columns: columns, rows: rows)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGrid()
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard window != nil, !isStatic else { return }
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blink() }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
        // Premier clic dans l'onglet : le clavier va au terminal.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !(window.firstResponder is NSTextView) else { return }
            window.makeFirstResponder(self)
        }
    }

    private var hasFocus: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    private func blink() {
        guard let emulator = session?.emulator, emulator.cursorBlinks, hasFocus else {
            if !cursorOn { cursorOn = true; needsDisplay = true }
            return
        }
        cursorOn.toggle()
        setNeedsDisplay(cursorRect())
    }

    override func becomeFirstResponder() -> Bool {
        cursorOn = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: Dessin

    private var firstVisibleLine: Int {
        guard let emulator = session?.emulator else { return 0 }
        return max(emulator.totalLines - emulator.rows - scrollOffset, 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = self.palette
        palette.background.setFill()
        dirtyRect.fill()
        guard let session else { return }
        let emulator = session.emulator
        let first = firstVisibleLine
        let selected = normalizedSelection
        let matches = session.searchVisible ? session.matches : []
        let current = matches.indices.contains(session.matchIndex) ? matches[session.matchIndex] : nil
        let reverse = emulator.reverseVideo

        for row in 0..<emulator.rows {
            let index = first + row
            guard index < emulator.totalLines else { break }
            let y = inset.height + CGFloat(row) * cellHeight
            let lineRect = NSRect(x: 0, y: y, width: bounds.width, height: cellHeight)
            guard lineRect.intersects(dirtyRect) else { continue }
            let line = emulator.line(at: index)
            drawBackgrounds(line, y: y, palette: palette, reverse: reverse)
            for match in matches where match.line == index {
                (match == current ? palette.currentMatch : palette.match).setFill()
                columnRect(match.columns, y: y).fill()
            }
            if let selected, index >= selected.start.line, index <= selected.end.line {
                let from = index == selected.start.line ? selected.start.column : 0
                let to = index == selected.end.line ? selected.end.column : emulator.columns
                if to > from {
                    palette.selection.setFill()
                    columnRect(from..<to, y: y).fill()
                }
            }
            drawText(line, y: y, palette: palette, reverse: reverse)
        }
        drawCursor(palette: palette, first: first)
        if !markedText.isEmpty { drawMarkedText(palette: palette) }
        drawScrollIndicator(palette: palette)
    }

    private func columnRect(_ columns: Range<Int>, y: CGFloat) -> NSRect {
        NSRect(x: inset.width + CGFloat(columns.lowerBound) * cellWidth, y: y,
               width: CGFloat(columns.count) * cellWidth, height: cellHeight)
    }

    private func colors(_ attributes: TerminalAttributes, palette: TerminalPalette, reverse: Bool) -> (NSColor, NSColor) {
        let bold = attributes.flags.contains(.bold)
        var foreground = palette.color(attributes.foreground, isForeground: true, bold: bold)
        var background = palette.color(attributes.background, isForeground: false)
        if attributes.flags.contains(.inverse) != reverse { swap(&foreground, &background) }
        if attributes.flags.contains(.dim) { foreground = foreground.withAlphaComponent(0.62) }
        if attributes.flags.contains(.hidden) { foreground = background }
        return (foreground, background)
    }

    private func drawBackgrounds(_ line: TerminalLine, y: CGFloat, palette: TerminalPalette, reverse: Bool) {
        var start = 0
        while start < line.cells.count {
            let attributes = line.cells[start].attributes
            var end = start + 1
            while end < line.cells.count, line.cells[end].attributes.background == attributes.background,
                  line.cells[end].attributes.flags.contains(.inverse) == attributes.flags.contains(.inverse) {
                end += 1
            }
            let hasBackground = attributes.background != .defaultColor || attributes.flags.contains(.inverse) != reverse
            if hasBackground {
                colors(attributes, palette: palette, reverse: reverse).1.setFill()
                columnRect(start..<end, y: y).fill()
            }
            start = end
        }
    }

    private func drawText(_ line: TerminalLine, y: CGFloat, palette: TerminalPalette, reverse: Bool) {
        var column = 0
        let cells = line.cells
        while column < cells.count {
            let cell = cells[column]
            if cell.isContinuation || cell.scalar == " " && !cell.attributes.flags.contains(.underline) && !cell.attributes.flags.contains(.strikethrough) {
                column += 1
                continue
            }
            // Suite de caractères ASCII de mêmes attributs dessinée d'un bloc ; les autres seuls,
            // chacun dans sa cellule (la grille reste exacte avec les polices de secours).
            var end = column + 1
            var text = String.UnicodeScalarView()
            text.append(cell.scalar)
            if cell.scalar.isASCII {
                while end < cells.count, cells[end].attributes == cell.attributes, cells[end].scalar.isASCII, !cells[end].isContinuation {
                    text.append(cells[end].scalar)
                    end += 1
                }
            }
            let (foreground, _) = colors(cell.attributes, palette: palette, reverse: reverse)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: cell.attributes.flags.contains(.bold) ? boldFont : font,
                .foregroundColor: foreground,
            ]
            if cell.attributes.flags.contains(.italic) { attributes[.obliqueness] = 0.18 }
            if cell.attributes.flags.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if cell.attributes.flags.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let x = inset.width + CGFloat(column) * cellWidth
            NSAttributedString(string: String(text), attributes: attributes)
                .draw(at: NSPoint(x: x, y: y + (cellHeight - (font.ascender - font.descender)) / 2 - 0.5))
            column = end
        }
    }

    private func cursorRect() -> NSRect {
        guard let emulator = session?.emulator else { return .zero }
        let row = emulator.firstScreenLine + emulator.cursorRow - firstVisibleLine
        return NSRect(x: inset.width + CGFloat(emulator.cursorColumn) * cellWidth, y: inset.height + CGFloat(row) * cellHeight,
                      width: cellWidth, height: cellHeight)
    }

    private func drawCursor(palette: TerminalPalette, first: Int) {
        guard let session else { return }
        let emulator = session.emulator
        guard emulator.cursorVisible, session.phase == .connected || session.phase == .connecting || isStatic else { return }
        let row = emulator.firstScreenLine + emulator.cursorRow - first
        guard row >= 0, row < emulator.rows else { return }
        let rect = cursorRect()
        let focused = hasFocus || isStatic
        guard cursorOn || !focused else { return }
        palette.cursor.setFill()
        palette.cursor.setStroke()
        if !focused {
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return
        }
        switch emulator.cursorStyle {
        case .block:
            rect.fill()
            let cell = emulator.screenLine(emulator.cursorRow).cells[emulator.cursorColumn]
            if !cell.isContinuation, cell.scalar != " " {
                NSAttributedString(string: String(Character(cell.scalar)), attributes: [.font: font, .foregroundColor: palette.cursorText])
                    .draw(at: NSPoint(x: rect.minX, y: rect.minY + (cellHeight - (font.ascender - font.descender)) / 2 - 0.5))
            }
        case .underline:
            NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
        case .bar:
            NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
        }
    }

    private func drawMarkedText(palette: TerminalPalette) {
        let rect = cursorRect()
        NSAttributedString(string: markedText, attributes: [
            .font: font, .foregroundColor: palette.foreground, .underlineStyle: NSUnderlineStyle.single.rawValue,
            .backgroundColor: palette.background,
        ]).draw(at: NSPoint(x: rect.minX, y: rect.minY))
    }

    private func drawScrollIndicator(palette: TerminalPalette) {
        guard let emulator = session?.emulator, emulator.scrollback.count > 0,
              scrollOffset > 0 || Date() < scrollIndicatorUntil else { return }
        let total = CGFloat(emulator.totalLines)
        let visible = CGFloat(emulator.rows)
        let track = bounds.height - 8
        let height = max(track * visible / total, 24)
        let position = CGFloat(firstVisibleLine) / max(total - visible, 1)
        let rect = NSRect(x: bounds.width - 7, y: 4 + (track - height) * position, width: 4, height: height)
        (palette.isDark ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.3)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    // MARK: Défilement

    override func scrollWheel(with event: NSEvent) {
        guard let emulator = session?.emulator else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY * 3
        scrollRemainder += delta
        let lines = Int(scrollRemainder)
        guard lines != 0 else { return }
        scrollRemainder -= CGFloat(lines)
        scroll(by: lines, max: emulator.scrollback.count)
    }

    private func scroll(by lines: Int, max maximum: Int) {
        let previous = scrollOffset
        scrollOffset = min(Swift.max(scrollOffset + lines, 0), maximum)
        if scrollOffset != previous {
            scrollIndicatorUntil = Date().addingTimeInterval(1)
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in self?.needsDisplay = true }
        }
    }

    private func reveal(_ match: TerminalMatch) {
        guard let emulator = session?.emulator else { return }
        let bottomFirst = emulator.totalLines - emulator.rows
        if match.line < firstVisibleLine || match.line >= firstVisibleLine + emulator.rows {
            let target = max(min(match.line - emulator.rows / 2, bottomFirst), 0)
            scrollOffset = max(bottomFirst - target, 0)
        }
        needsDisplay = true
    }

    // MARK: Souris et sélection

    private func position(at point: NSPoint) -> TerminalPosition {
        let column = Int(((point.x - inset.width) / cellWidth).rounded(.down))
        let row = Int(((point.y - inset.height) / cellHeight).rounded(.down))
        let columns = session?.emulator.columns ?? 80
        return TerminalPosition(line: firstVisibleLine + max(row, 0), column: min(max(column, 0), columns))
    }

    private var normalizedSelection: (start: TerminalPosition, end: TerminalPosition)? {
        guard let selection, selection.anchor != selection.head else { return nil }
        return selection.anchor < selection.head ? (selection.anchor, selection.head) : (selection.head, selection.anchor)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let emulator = session?.emulator else { return }
        let point = convert(event.locationInWindow, from: nil)
        let at = position(at: point)
        selectionMode = event.clickCount
        switch event.clickCount {
        case 2:
            let word = emulator.wordRange(at: at)
            selection = (word.start, word.end)
        case 3...:
            selection = (TerminalPosition(line: at.line, column: 0), TerminalPosition(line: at.line, column: emulator.columns))
        default:
            selection = (at, at)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = selection, let emulator = session?.emulator else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 0 { scroll(by: 1, max: emulator.scrollback.count) }
        if point.y > bounds.height { scroll(by: -1, max: emulator.scrollback.count) }
        var head = position(at: point)
        if selectionMode == 2 {
            let word = emulator.wordRange(at: head)
            head = head < current.anchor ? word.start : word.end
        } else if selectionMode >= 3 {
            head = TerminalPosition(line: head.line, column: head < current.anchor ? 0 : emulator.columns)
        }
        selection = (current.anchor, head)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if normalizedSelection == nil { selection = nil }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copier", action: #selector(copy(_:)), keyEquivalent: "c").isEnabled = normalizedSelection != nil
        menu.addItem(withTitle: "Coller", action: #selector(paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Tout sélectionner", action: #selector(selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rechercher…", action: #selector(showSearch(_:)), keyEquivalent: "f")
        menu.addItem(withTitle: "Effacer l’historique", action: #selector(clearTerminal(_:)), keyEquivalent: "k")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc func copy(_ sender: Any?) {
        guard let range = normalizedSelection, let emulator = session?.emulator else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(emulator.text(from: range.start, to: range.end), forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        scrollOffset = 0
        session?.paste(text)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let emulator = session?.emulator else { return }
        selection = (TerminalPosition(line: 0, column: 0), TerminalPosition(line: emulator.totalLines - 1, column: emulator.columns))
        needsDisplay = true
    }

    @objc func showSearch(_ sender: Any?) {
        session?.searchVisible = true
    }

    @objc func clearTerminal(_ sender: Any?) {
        selection = nil
        scrollOffset = 0
        session?.clear()
    }

    // MARK: Clavier

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copy(nil); return true
        case "v": paste(nil); return true
        case "a": selectAll(nil); return true
        case "k": clearTerminal(nil); return true
        case "f": showSearch(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: TerminalKeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let emulator = session.emulator

        // Maj + Page/Début/Fin : défilement de l'historique (comme Terminal).
        if flags.contains(.shift), [116, 121, 115, 119].contains(event.keyCode) {
            switch event.keyCode {
            case 116: scroll(by: emulator.rows - 1, max: emulator.scrollback.count)
            case 121: scroll(by: -(emulator.rows - 1), max: emulator.scrollback.count)
            case 115: scroll(by: emulator.scrollback.count, max: emulator.scrollback.count)
            default: scroll(by: -scrollOffset, max: emulator.scrollback.count)
            }
            return
        }
        if markedText.isEmpty, let key = Self.specialKey(event.keyCode) {
            send(TerminalKeyEncoder.encode(key, modifiers: modifiers, applicationCursor: emulator.applicationCursorKeys,
                                           optionAsMeta: optionAsMeta))
            return
        }
        if flags.contains(.control), let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            send(TerminalKeyEncoder.encode(.character(characters), modifiers: modifiers, optionAsMeta: optionAsMeta))
            return
        }
        if flags.contains(.option), optionAsMeta, let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            send(TerminalKeyEncoder.encode(.character(characters), modifiers: [.option], optionAsMeta: true))
            return
        }
        // Texte (accents par touches mortes compris) : méthode de saisie de macOS.
        if inputContext?.handleEvent(event) != true {
            interpretKeyEvents([event])
        }
    }

    private func send(_ bytes: [UInt8]) {
        if scrollOffset != 0 {
            scrollOffset = 0
            needsDisplay = true
        }
        selection = nil
        cursorOn = true
        session?.send(bytes)
    }

    /// Touches spéciales du clavier du Mac (codes virtuels).
    static func specialKey(_ code: UInt16) -> TerminalKey? {
        switch code {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 117: return .forwardDelete
        case 114: return .insert
        case 51: return .backspace
        case 48: return .tab
        case 36, 76: return .enter
        case 53: return .escape
        case 122: return .function(1)
        case 120: return .function(2)
        case 99: return .function(3)
        case 118: return .function(4)
        case 96: return .function(5)
        case 97: return .function(6)
        case 98: return .function(7)
        case 100: return .function(8)
        case 101: return .function(9)
        case 109: return .function(10)
        case 103: return .function(11)
        case 111: return .function(12)
        case 105: return .function(13)
        case 107: return .function(14)
        case 113: return .function(15)
        case 106: return .function(16)
        case 64: return .function(17)
        case 79: return .function(18)
        case 80: return .function(19)
        case 90: return .function(20)
        default: return nil
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        guard !text.isEmpty, let session else { return }
        send(session.encoding.encode(text))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorRect(), to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    override func doCommand(by selector: Selector) {
        // Touches déjà traduites par keyDown ; Entrée et effacement venus de la méthode de saisie.
        switch selector {
        case #selector(insertNewline(_:)): send([0x0D])
        case #selector(deleteBackward(_:)): send([0x7F])
        case #selector(insertTab(_:)): send([0x09])
        case #selector(cancelOperation(_:)): send([0x1B])
        default: break
        }
    }
}

/// Le terminal dans SwiftUI.
struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var preferences = TerminalPreferences.shared

    func makeNSView(context: Context) -> TerminalTextView {
        let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isStatic = RegEnvironment.isSnapshot
        configure(view)
        view.session = session
        return view
    }

    func updateNSView(_ view: TerminalTextView, context: Context) {
        configure(view)
        if view.session !== session { view.session = session }
        view.needsDisplay = true
    }

    private func configure(_ view: TerminalTextView) {
        view.appearanceSetting = preferences.appearance
        view.optionAsMeta = preferences.optionAsMeta
        view.fontSize = CGFloat(preferences.fontSize)
    }
}
