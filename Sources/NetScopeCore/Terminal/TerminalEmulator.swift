import Foundation

/// Émulateur de terminal VT100/xterm (TERM=xterm-256color), sans interface et sans dépendance :
/// il lit les octets reçus (UTF-8, ISO-8859-1 ou CP437), interprète les séquences de contrôle
/// (CSI, SGR 16/256/24 bits, curseur, effacements, régions de défilement, écran alternatif, modes
/// DEC courants, titres OSC) et tient l'écran et l'historique (10 000 lignes).
///
/// Les réponses attendues par le serveur (position du curseur, identification) s'accumulent dans
/// `takeResponses()`, que la session renvoie au serveur. Non sûr entre fils : un seul fil l'utilise.
public final class TerminalEmulator {
    public static let defaultScrollbackLimit = 10_000

    // MARK: État public

    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var scrollback: TerminalScrollback
    public private(set) var isAlternateScreen = false
    /// Ligne et colonne du curseur à l'écran (0 = haut gauche).
    public private(set) var cursorRow = 0
    public private(set) var cursorColumn = 0
    public private(set) var cursorVisible = true
    public private(set) var cursorStyle: TerminalCursorStyle = .block
    public private(set) var cursorBlinks = true
    /// Attributs appliqués aux prochains caractères.
    public private(set) var attributes = TerminalAttributes.plain
    public private(set) var scrollTop = 0
    public private(set) var scrollBottom: Int
    /// Titre de la fenêtre (OSC 0 ou 2).
    public private(set) var title = ""
    public private(set) var bellCount = 0
    /// Augmente à chaque changement (la vue se redessine).
    public private(set) var revision = 0

    // Modes
    public private(set) var applicationCursorKeys = false
    public private(set) var applicationKeypad = false
    public private(set) var bracketedPaste = false
    public private(set) var autowrap = true
    public private(set) var originMode = false
    public private(set) var insertMode = false
    public private(set) var newLineMode = false
    public private(set) var reverseVideo = false
    /// Suivi de la souris demandé (1000, 1002, 1003) : la sélection garde la priorité dans NetScope.
    public private(set) var mouseTracking = 0
    public private(set) var focusReporting = false

    public var encoding: TerminalEncoding = .utf8

    // MARK: État interne

    private var screen: [TerminalLine]
    private var savedMainScreen: [TerminalLine]?
    private var pendingWrap = false
    private var tabStops: Set<Int> = []
    private var g0 = TerminalCharset.ascii
    private var g1 = TerminalCharset.ascii
    private var shiftOut = false
    private var lastPrinted: Unicode.Scalar?
    private var responses: [UInt8] = []

    private struct SavedCursor {
        var row = 0, column = 0
        var attributes = TerminalAttributes.plain
        var originMode = false
        var autowrap = true
        var g0 = TerminalCharset.ascii, g1 = TerminalCharset.ascii, shiftOut = false
        var pendingWrap = false
    }
    private var savedCursor = SavedCursor()
    private var savedCursorAlternate = SavedCursor()

    // Analyseur
    private enum ParserState {
        case ground, escape, escapeIntermediate, csi, csiIgnore, osc, oscEscape, string, stringEscape
    }
    private var state = ParserState.ground
    private var intermediates: [UInt8] = []
    private var privateMarker: UInt8?
    private var params: [[Int]] = []
    private var paramGroup: [Int] = []
    private var paramValue: Int?
    private var oscBuffer = String.UnicodeScalarView()
    // Décodage UTF-8 incrémental (une séquence peut être coupée entre deux paquets).
    private var utf8Need = 0
    private var utf8Value: UInt32 = 0
    private var utf8Min: UInt32 = 0

    public init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = TerminalEmulator.defaultScrollbackLimit) {
        self.columns = max(columns, 2)
        self.rows = max(rows, 1)
        scrollback = TerminalScrollback(capacity: scrollbackLimit)
        scrollBottom = self.rows - 1
        screen = Array(repeating: TerminalLine(columns: self.columns), count: self.rows)
        resetTabStops(from: 0)
    }

    // MARK: Lecture (vue, copie, recherche)

    /// Nombre de lignes affichables : historique (écran principal seulement) puis écran.
    public var totalLines: Int { (isAlternateScreen ? 0 : scrollback.count) + rows }

    /// Indice absolu de la première ligne de l'écran.
    public var firstScreenLine: Int { isAlternateScreen ? 0 : scrollback.count }

    /// Ligne absolue : historique, puis écran.
    public func line(at index: Int) -> TerminalLine {
        let first = firstScreenLine
        if index < first { return scrollback[index] }
        let row = index - first
        return screen.indices.contains(row) ? screen[row] : TerminalLine(columns: columns)
    }

    /// Ligne de l'écran (0 = haut).
    public func screenLine(_ row: Int) -> TerminalLine { screen[row] }

    /// Texte de l'écran (lignes séparées par « \n », espaces de fin retirés) : tests et copie.
    public var screenText: String {
        screen.map(\.text).joined(separator: "\n")
    }

    /// Tout le texte : historique puis écran, lignes vides de la fin retirées.
    public var allText: String {
        var lines = (0..<totalLines).map { line(at: $0).text }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Réponses à renvoyer au serveur (puis vidées).
    public func takeResponses() -> [UInt8] {
        defer { responses.removeAll() }
        return responses
    }

    /// Texte entre deux positions (fin exclue) ; les lignes coupées par le retour automatique sont recollées.
    public func text(from start: TerminalPosition, to end: TerminalPosition) -> String {
        let (a, b) = start <= end ? (start, end) : (end, start)
        guard totalLines > 0 else { return "" }
        var result = ""
        let last = min(b.line, totalLines - 1)
        guard a.line <= last else { return "" }
        for index in max(a.line, 0)...last {
            let line = line(at: index)
            let from = index == a.line ? max(a.column, 0) : 0
            let to = index == b.line ? min(b.column, line.cells.count) : line.cells.count
            var scalars = String.UnicodeScalarView()
            if from < to {
                for cell in line.cells[from..<to] where !cell.isContinuation { scalars.append(cell.scalar) }
            }
            var piece = String(scalars)
            let wrapsIntoNext = line.wrapped && index != last
            if !wrapsIntoNext { while piece.last == " " { piece.removeLast() } }
            result += piece
            if index != last && !wrapsIntoNext { result += "\n" }
        }
        return result
    }

    /// Mot autour d'une position (double-clic) : adresses IP, MAC, chemins et noms d'interface
    /// restent entiers.
    public func wordRange(at position: TerminalPosition) -> (start: TerminalPosition, end: TerminalPosition) {
        let line = line(at: position.line)
        let separators = Set(" \t()[]{}<>\"'`|,;=".unicodeScalars)
        func isWord(_ column: Int) -> Bool {
            guard line.cells.indices.contains(column) else { return false }
            let cell = line.cells[column]
            return cell.isContinuation || !separators.contains(cell.scalar)
        }
        var start = min(max(position.column, 0), max(line.cells.count - 1, 0))
        guard isWord(start) else {
            return (TerminalPosition(line: position.line, column: start), TerminalPosition(line: position.line, column: start + 1))
        }
        var end = start
        while start > 0, isWord(start - 1) { start -= 1 }
        while isWord(end + 1) { end += 1 }
        return (TerminalPosition(line: position.line, column: start), TerminalPosition(line: position.line, column: end + 1))
    }

    /// Recherche (sans tenir compte de la casse ni des accents) dans l'historique et l'écran.
    public func search(_ query: String) -> [TerminalMatch] {
        let needle = query.trimmingCharacters(in: .newlines)
        guard !needle.isEmpty else { return [] }
        var matches: [TerminalMatch] = []
        for index in 0..<totalLines {
            let line = line(at: index)
            var columnsOfScalars: [Int] = []
            var scalars = String.UnicodeScalarView()
            for (column, cell) in line.cells.enumerated() where !cell.isContinuation {
                scalars.append(cell.scalar)
                columnsOfScalars.append(column)
            }
            let text = String(scalars)
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                let lower = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound)
                let upper = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.upperBound)
                if lower < columnsOfScalars.count {
                    let startColumn = columnsOfScalars[lower]
                    let endColumn = upper < columnsOfScalars.count ? columnsOfScalars[upper] : line.cells.count
                    matches.append(TerminalMatch(line: index, columns: startColumn..<max(endColumn, startColumn + 1)))
                }
                searchStart = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            }
        }
        return matches
    }

    // MARK: Commandes de l'utilisateur

    /// Efface l'historique (⌘K garde la ligne du curseur en haut de l'écran).
    public func clearScrollback(keepCursorLine: Bool = true) {
        scrollback.removeAll()
        guard keepCursorLine, !isAlternateScreen else { revision += 1; return }
        let current = screen[cursorRow]
        for row in screen.indices { screen[row] = TerminalLine(columns: columns) }
        screen[0] = current
        cursorRow = 0
        pendingWrap = false
        revision += 1
    }

    /// Remise à zéro complète (comme « ESC c »), l'historique compris.
    public func reset() {
        fullReset()
        scrollback.removeAll()
        revision += 1
    }

    // MARK: Entrée

    /// Lit des octets reçus du serveur.
    public func feed(_ bytes: [UInt8]) {
        switch encoding {
        case .utf8:
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if utf8Need == 0 {
                    if byte < 0x80 {
                        process(Unicode.Scalar(byte))
                    } else if byte & 0xE0 == 0xC0 {
                        utf8Value = UInt32(byte & 0x1F); utf8Need = 1; utf8Min = 0x80
                    } else if byte & 0xF0 == 0xE0 {
                        utf8Value = UInt32(byte & 0x0F); utf8Need = 2; utf8Min = 0x800
                    } else if byte & 0xF8 == 0xF0 {
                        utf8Value = UInt32(byte & 0x07); utf8Need = 3; utf8Min = 0x10000
                    } else {
                        process("\u{FFFD}")
                    }
                    index += 1
                } else if byte & 0xC0 == 0x80 {
                    utf8Value = (utf8Value << 6) | UInt32(byte & 0x3F)
                    utf8Need -= 1
                    if utf8Need == 0 {
                        if utf8Value >= utf8Min, let scalar = Unicode.Scalar(utf8Value) {
                            process(scalar)
                        } else {
                            process("\u{FFFD}")
                        }
                    }
                    index += 1
                } else {
                    // Séquence interrompue : caractère de remplacement, puis l'octet est relu seul.
                    utf8Need = 0
                    process("\u{FFFD}")
                }
            }
        case .latin1:
            for byte in bytes { process(Unicode.Scalar(byte)) }
        case .cp437:
            for byte in bytes {
                process(byte < 0x80 ? Unicode.Scalar(byte) : TerminalCodePage.cp437[Int(byte) - 0x80])
            }
        }
        revision += 1
    }

    public func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    // MARK: Taille

    /// Nouvelle taille ; sans réagencement des lignes : elles sont coupées ou complétées.
    /// En rétrécissant, les lignes du haut passent dans l'historique ; en agrandissant, elles en reviennent.
    public func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(newColumns, 2), newRows = max(newRows, 1)
        guard newColumns != columns || newRows != rows else { return }
        if isAlternateScreen {
            var altRow = cursorRow
            resizeLines(&screen, cursorRow: &altRow, columns: newColumns, rows: newRows, useScrollback: false)
            cursorRow = altRow
            if var main = savedMainScreen {
                var mainRow = savedCursorAlternate.row
                resizeLines(&main, cursorRow: &mainRow, columns: newColumns, rows: newRows, useScrollback: true)
                savedCursorAlternate.row = mainRow
                savedMainScreen = main
            }
        } else {
            var row = cursorRow
            resizeLines(&screen, cursorRow: &row, columns: newColumns, rows: newRows, useScrollback: true)
            cursorRow = row
        }
        let oldColumns = columns
        columns = newColumns
        rows = newRows
        scrollTop = 0
        scrollBottom = rows - 1
        cursorRow = min(max(cursorRow, 0), rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
        savedCursor.row = min(savedCursor.row, rows - 1)
        savedCursor.column = min(savedCursor.column, columns - 1)
        pendingWrap = false
        tabStops = tabStops.filter { $0 < columns }
        if columns > oldColumns { resetTabStops(from: oldColumns) }
        revision += 1
    }

    private func resizeLines(_ lines: inout [TerminalLine], cursorRow row: inout Int, columns newColumns: Int, rows newRows: Int,
                             useScrollback: Bool) {
        for index in lines.indices { lines[index].resize(to: newColumns) }
        if newRows < lines.count {
            var excess = lines.count - newRows
            // D'abord les lignes vides sous le curseur, puis le haut de l'écran (vers l'historique).
            while excess > 0, lines.count - 1 > row, lines.last?.text.isEmpty == true {
                lines.removeLast()
                excess -= 1
            }
            while excess > 0 {
                let removed = lines.removeFirst()
                if useScrollback { scrollback.append(removed.trimmed()) }
                row -= 1
                excess -= 1
            }
        } else if newRows > lines.count {
            var extra = newRows - lines.count
            while extra > 0, useScrollback, var restored = scrollback.removeLast() {
                restored.resize(to: newColumns)
                lines.insert(restored, at: 0)
                row += 1
                extra -= 1
            }
            lines += Array(repeating: TerminalLine(columns: newColumns), count: extra)
        }
        row = min(max(row, 0), newRows - 1)
    }

    // MARK: Analyse

    private func process(_ scalar: Unicode.Scalar) {
        let value = scalar.value
        // Contrôles valables dans tous les états.
        if value == 0x18 || value == 0x1A {
            state = .ground
            return
        }
        if value == 0x1B {
            switch state {
            case .osc, .oscEscape: state = .oscEscape
            case .string, .stringEscape: state = .stringEscape
            default:
                state = .escape
                intermediates.removeAll()
            }
            return
        }
        switch state {
        case .ground:
            if value < 0x20 { control(value) } else if value != 0x7F { print(scalar) }
        case .escape:
            if value < 0x20 { control(value); return }
            switch value {
            case 0x20...0x2F:
                intermediates.append(UInt8(value))
                state = .escapeIntermediate
            case 0x5B: // [
                beginCSI()
            case 0x5D: // ]
                oscBuffer = String.UnicodeScalarView()
                state = .osc
            case 0x50, 0x58, 0x5E, 0x5F: // P X ^ _ : chaînes ignorées jusqu'à ST
                state = .string
            default:
                state = .ground
                escapeDispatch(UInt8(truncatingIfNeeded: value))
            }
        case .escapeIntermediate:
            if value < 0x20 { control(value); return }
            if (0x20...0x2F).contains(value) {
                intermediates.append(UInt8(value))
            } else {
                state = .ground
                escapeDispatch(UInt8(truncatingIfNeeded: value))
            }
        case .csi:
            csiByte(value)
        case .csiIgnore:
            if value < 0x20 { control(value) } else if (0x40...0x7E).contains(value) { state = .ground }
        case .osc:
            if value == 0x07 {
                state = .ground
                oscDispatch()
            } else if value >= 0x20, oscBuffer.count < 4_096 {
                oscBuffer.append(scalar)
            }
        case .oscEscape:
            // ESC \ (ST) termine le titre ; une autre séquence d'échappement le termine aussi.
            oscDispatch()
            state = .escape
            intermediates.removeAll()
            if value == 0x5C { state = .ground } else { process(scalar) }
        case .string:
            if value == 0x07 { state = .ground }
        case .stringEscape:
            state = .escape
            intermediates.removeAll()
            if value == 0x5C { state = .ground } else { process(scalar) }
        }
    }

    static let maxParameters = 32
    static let maxSubParameters = 16

    private func beginCSI() {
        state = .csi
        params.removeAll()
        paramGroup.removeAll()
        paramValue = nil
        privateMarker = nil
        intermediates.removeAll()
    }

    private func csiByte(_ value: UInt32) {
        switch value {
        case 0x00..<0x20:
            control(value)
        case 0x30...0x39:
            guard intermediates.isEmpty else { state = .csiIgnore; return }
            paramValue = min((paramValue ?? 0) * 10 + Int(value - 0x30), 65_535)
        case 0x3A: // :
            // Sous-paramètres bornés comme les paramètres (une suite sans fin est ignorée).
            guard paramGroup.count < Self.maxSubParameters else { state = .csiIgnore; return }
            paramGroup.append(paramValue ?? -1)
            paramValue = nil
        case 0x3B: // ;
            // Au plus 32 paramètres (xterm en garde 30) : au-delà, la séquence est ignorée.
            guard params.count < Self.maxParameters else { state = .csiIgnore; return }
            paramGroup.append(paramValue ?? -1)
            params.append(paramGroup)
            paramGroup.removeAll()
            paramValue = nil
        case 0x3C...0x3F: // < = > ?
            if params.isEmpty, paramGroup.isEmpty, paramValue == nil, privateMarker == nil {
                privateMarker = UInt8(value)
            } else {
                state = .csiIgnore
            }
        case 0x20...0x2F:
            guard intermediates.count < 4 else { state = .csiIgnore; return }
            intermediates.append(UInt8(value))
        case 0x40...0x7E:
            if paramValue != nil || !paramGroup.isEmpty || !params.isEmpty {
                paramGroup.append(paramValue ?? -1)
                params.append(paramGroup)
            }
            state = .ground
            csiDispatch(UInt8(value))
        default:
            state = .csiIgnore
        }
    }

    /// Paramètre `index` (0 ou absent : `defaultValue`).
    private func param(_ index: Int, _ defaultValue: Int = 1) -> Int {
        guard params.indices.contains(index), let value = params[index].first, value > 0 else { return defaultValue }
        return value
    }

    /// Paramètre brut (absent : 0).
    private func rawParam(_ index: Int) -> Int {
        guard params.indices.contains(index), let value = params[index].first, value >= 0 else { return 0 }
        return value
    }

    // MARK: Contrôles C0

    private func control(_ value: UInt32) {
        switch value {
        case 0x07: bellCount += 1
        case 0x08:
            if pendingWrap { pendingWrap = false } else if cursorColumn > 0 { cursorColumn -= 1 }
        case 0x09: tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
        case 0x0D:
            cursorColumn = 0
            pendingWrap = false
        case 0x0E: shiftOut = true
        case 0x0F: shiftOut = false
        default: break
        }
    }

    // MARK: Échappements

    private func escapeDispatch(_ final: UInt8) {
        if let first = intermediates.first {
            switch (first, final) {
            case (UInt8(ascii: "("), _): g0 = final == UInt8(ascii: "0") ? .decGraphics : .ascii
            case (UInt8(ascii: ")"), _): g1 = final == UInt8(ascii: "0") ? .decGraphics : .ascii
            case (UInt8(ascii: "#"), UInt8(ascii: "8")): alignmentTest()
            default: break
            }
            intermediates.removeAll()
            return
        }
        switch final {
        case UInt8(ascii: "7"): saveCursor()
        case UInt8(ascii: "8"): restoreCursor()
        case UInt8(ascii: "D"): index()
        case UInt8(ascii: "E"):
            cursorColumn = 0
            index()
        case UInt8(ascii: "H"): tabStops.insert(cursorColumn)
        case UInt8(ascii: "M"): reverseIndex()
        case UInt8(ascii: "c"): fullReset()
        case UInt8(ascii: "="): applicationKeypad = true
        case UInt8(ascii: ">"): applicationKeypad = false
        default: break
        }
    }

    private func oscDispatch() {
        let text = String(oscBuffer)
        guard let separator = text.firstIndex(of: ";") else { return }
        let code = text[..<separator]
        let value = String(text[text.index(after: separator)...])
        if code == "0" || code == "2" {
            // Titre affiché dans l'onglet : caractères de contrôle retirés, longueur bornée.
            title = String(value.unicodeScalars.filter { $0.value >= 0x20 }.prefix(200).map(Character.init))
        }
    }

    // MARK: CSI

    private func csiDispatch(_ final: UInt8) {
        if privateMarker == UInt8(ascii: "?") {
            switch final {
            case UInt8(ascii: "h"): setPrivateModes(true)
            case UInt8(ascii: "l"): setPrivateModes(false)
            case UInt8(ascii: "n"):
                if rawParam(0) == 6 { respond("\u{1B}[?\(reportedRow);\(cursorColumn + 1)R") }
            case UInt8(ascii: "J"): eraseInDisplay(rawParam(0))
            case UInt8(ascii: "K"): eraseInLine(rawParam(0))
            default: break
            }
            return
        }
        if privateMarker == UInt8(ascii: ">") {
            if final == UInt8(ascii: "c") { respond("\u{1B}[>0;276;0c") }
            return
        }
        guard privateMarker == nil else { return }
        if let intermediate = intermediates.first {
            if intermediate == UInt8(ascii: " "), final == UInt8(ascii: "q") { setCursorStyle(rawParam(0)) }
            if intermediate == UInt8(ascii: "!"), final == UInt8(ascii: "p") { softReset() }
            return
        }
        switch final {
        case UInt8(ascii: "@"): insertCharacters(param(0))
        case UInt8(ascii: "A"): moveCursor(rows: -param(0))
        case UInt8(ascii: "B"), UInt8(ascii: "e"): moveCursor(rows: param(0))
        case UInt8(ascii: "C"), UInt8(ascii: "a"): setColumn(cursorColumn + param(0))
        case UInt8(ascii: "D"): setColumn(cursorColumn - param(0))
        case UInt8(ascii: "E"):
            moveCursor(rows: param(0))
            cursorColumn = 0
        case UInt8(ascii: "F"):
            moveCursor(rows: -param(0))
            cursorColumn = 0
        case UInt8(ascii: "G"), UInt8(ascii: "`"): setColumn(param(0) - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"): cursorPosition(row: param(0), column: param(1))
        case UInt8(ascii: "I"): tabForward(param(0))
        case UInt8(ascii: "J"): eraseInDisplay(rawParam(0))
        case UInt8(ascii: "K"): eraseInLine(rawParam(0))
        case UInt8(ascii: "L"): insertLines(param(0))
        case UInt8(ascii: "M"): deleteLines(param(0))
        case UInt8(ascii: "P"): deleteCharacters(param(0))
        case UInt8(ascii: "S"): scrollUp(param(0))
        case UInt8(ascii: "T"): scrollDown(param(0))
        case UInt8(ascii: "X"): eraseCharacters(param(0))
        case UInt8(ascii: "Z"): tabBackward(param(0))
        case UInt8(ascii: "b"):
            if let lastPrinted { for _ in 0..<min(param(0), columns * rows) { print(lastPrinted) } }
        case UInt8(ascii: "c"):
            if rawParam(0) == 0 { respond("\u{1B}[?62;22c") }
        case UInt8(ascii: "d"):
            cursorPosition(row: param(0), column: cursorColumn + 1)
        case UInt8(ascii: "g"):
            if rawParam(0) == 0 { tabStops.remove(cursorColumn) } else if rawParam(0) == 3 { tabStops.removeAll() }
        case UInt8(ascii: "h"): setANSIModes(true)
        case UInt8(ascii: "l"): setANSIModes(false)
        case UInt8(ascii: "m"): selectGraphicRendition()
        case UInt8(ascii: "n"):
            if rawParam(0) == 5 { respond("\u{1B}[0n") }
            if rawParam(0) == 6 { respond("\u{1B}[\(reportedRow);\(cursorColumn + 1)R") }
        case UInt8(ascii: "r"): setScrollRegion(top: param(0), bottom: param(1, rows))
        case UInt8(ascii: "s"): saveCursor()
        case UInt8(ascii: "u"): restoreCursor()
        case UInt8(ascii: "t"):
            if rawParam(0) == 18 { respond("\u{1B}[8;\(rows);\(columns)t") }
        default: break
        }
    }

    private var reportedRow: Int { originMode ? cursorRow - scrollTop + 1 : cursorRow + 1 }

    private func respond(_ text: String) {
        responses += Array(text.utf8)
    }

    // MARK: Modes

    private func setPrivateModes(_ on: Bool) {
        for index in params.indices {
            switch rawParam(index) {
            case 1: applicationCursorKeys = on
            case 5: reverseVideo = on
            case 6:
                originMode = on
                cursorPosition(row: 1, column: 1)
            case 7: autowrap = on
            case 12: cursorBlinks = on
            case 25: cursorVisible = on
            case 47, 1047: switchScreen(alternate: on, clear: rawParam(index) == 1047)
            case 1048: if on { saveCursor() } else { restoreCursor() }
            case 1049:
                if on {
                    savedCursorAlternate = currentCursor()
                    switchScreen(alternate: true, clear: true)
                } else {
                    switchScreen(alternate: false, clear: false)
                    apply(savedCursorAlternate)
                }
            case 1000, 1002, 1003: mouseTracking = on ? rawParam(index) : 0
            case 1004: focusReporting = on
            case 2004: bracketedPaste = on
            default: break
            }
        }
    }

    private func setANSIModes(_ on: Bool) {
        for index in params.indices {
            switch rawParam(index) {
            case 4: insertMode = on
            case 20: newLineMode = on
            default: break
            }
        }
    }

    private func switchScreen(alternate: Bool, clear: Bool) {
        if alternate, !isAlternateScreen {
            savedMainScreen = screen
            screen = Array(repeating: TerminalLine(columns: columns), count: rows)
            isAlternateScreen = true
        } else if !alternate, isAlternateScreen {
            screen = savedMainScreen ?? Array(repeating: TerminalLine(columns: columns), count: rows)
            savedMainScreen = nil
            isAlternateScreen = false
        } else if alternate, clear {
            screen = Array(repeating: TerminalLine(columns: columns), count: rows)
        }
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
    }

    private func setCursorStyle(_ value: Int) {
        switch value {
        case 0, 1: cursorStyle = .block; cursorBlinks = true
        case 2: cursorStyle = .block; cursorBlinks = false
        case 3: cursorStyle = .underline; cursorBlinks = true
        case 4: cursorStyle = .underline; cursorBlinks = false
        case 5: cursorStyle = .bar; cursorBlinks = true
        case 6: cursorStyle = .bar; cursorBlinks = false
        default: break
        }
    }

    private func softReset() {
        cursorVisible = true
        originMode = false
        autowrap = true
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        attributes = .plain
        scrollTop = 0
        scrollBottom = rows - 1
        g0 = .ascii; g1 = .ascii; shiftOut = false
        savedCursor = SavedCursor()
    }

    private func fullReset() {
        softReset()
        if isAlternateScreen { switchScreen(alternate: false, clear: false) }
        screen = Array(repeating: TerminalLine(columns: columns), count: rows)
        cursorRow = 0
        cursorColumn = 0
        pendingWrap = false
        bracketedPaste = false
        newLineMode = false
        reverseVideo = false
        mouseTracking = 0
        focusReporting = false
        cursorStyle = .block
        cursorBlinks = true
        title = ""
        tabStops.removeAll()
        resetTabStops(from: 0)
    }

    private func resetTabStops(from start: Int) {
        var column = ((start + 7) / 8) * 8
        while column < columns {
            tabStops.insert(column)
            column += 8
        }
    }

    // MARK: Curseur

    private func currentCursor() -> SavedCursor {
        SavedCursor(row: cursorRow, column: cursorColumn, attributes: attributes, originMode: originMode, autowrap: autowrap,
                    g0: g0, g1: g1, shiftOut: shiftOut, pendingWrap: pendingWrap)
    }

    private func apply(_ saved: SavedCursor) {
        cursorRow = min(saved.row, rows - 1)
        cursorColumn = min(saved.column, columns - 1)
        attributes = saved.attributes
        originMode = saved.originMode
        autowrap = saved.autowrap
        g0 = saved.g0; g1 = saved.g1; shiftOut = saved.shiftOut
        pendingWrap = saved.pendingWrap
    }

    private func saveCursor() { savedCursor = currentCursor() }
    private func restoreCursor() { apply(savedCursor) }

    private func cursorPosition(row: Int, column: Int) {
        var target = row - 1
        if originMode {
            target = min(target + scrollTop, scrollBottom)
        }
        cursorRow = min(max(target, 0), rows - 1)
        cursorColumn = min(max(column - 1, 0), columns - 1)
        pendingWrap = false
    }

    private func moveCursor(rows delta: Int) {
        let top = cursorRow >= scrollTop ? scrollTop : 0
        let bottom = cursorRow <= scrollBottom ? scrollBottom : rows - 1
        cursorRow = min(max(cursorRow + delta, top), bottom)
        pendingWrap = false
    }

    private func setColumn(_ column: Int) {
        cursorColumn = min(max(column, 0), columns - 1)
        pendingWrap = false
    }

    private func tabForward(_ count: Int) {
        for _ in 0..<count {
            let next = tabStops.filter { $0 > cursorColumn }.min() ?? columns - 1
            cursorColumn = min(next, columns - 1)
        }
        pendingWrap = false
    }

    private func tabBackward(_ count: Int) {
        for _ in 0..<count {
            cursorColumn = tabStops.filter { $0 < cursorColumn }.max() ?? 0
        }
        pendingWrap = false
    }

    private func setScrollRegion(top: Int, bottom: Int) {
        let t = top - 1, b = min(bottom, rows) - 1
        guard t < b else { return }
        scrollTop = t
        scrollBottom = b
        cursorPosition(row: 1, column: 1)
    }

    // MARK: Écriture

    private func print(_ input: Unicode.Scalar) {
        let scalar = (shiftOut ? g1 : g0).map(input)
        var width = TerminalCharWidth.width(of: scalar)
        if width == 0 {
            combine(scalar)
            return
        }
        if width == 2, columns < 2 { width = 1 }
        if pendingWrap {
            if autowrap {
                screen[cursorRow].wrapped = true
                cursorColumn = 0
                index()
            }
            pendingWrap = false
        }
        if width == 2, cursorColumn == columns - 1 {
            if autowrap {
                screen[cursorRow].cells[cursorColumn] = .erased(attributes)
                screen[cursorRow].wrapped = true
                cursorColumn = 0
                index()
            } else {
                width = 1
            }
        }
        if insertMode { insertCharacters(width) }
        clearWideCharacter(at: cursorColumn)
        if width == 2 { clearWideCharacter(at: cursorColumn + 1) }
        screen[cursorRow].cells[cursorColumn] = TerminalCell(scalar, attributes: attributes, width: UInt8(width))
        if width == 2 {
            screen[cursorRow].cells[cursorColumn + 1] = TerminalCell(" ", attributes: attributes, width: 0)
        }
        lastPrinted = scalar
        let next = cursorColumn + width
        if next >= columns {
            cursorColumn = columns - 1
            pendingWrap = autowrap
        } else {
            cursorColumn = next
        }
    }

    /// Marque combinante (accent) : composée avec le caractère précédent quand Unicode le permet.
    private func combine(_ mark: Unicode.Scalar) {
        var column = pendingWrap ? cursorColumn : cursorColumn - 1
        guard column >= 0 else { return }
        if screen[cursorRow].cells[column].isContinuation, column > 0 { column -= 1 }
        let base = screen[cursorRow].cells[column].scalar
        var text = String.UnicodeScalarView()
        text.append(base)
        text.append(mark)
        let composed = String(text).precomposedStringWithCanonicalMapping.unicodeScalars
        if composed.count == 1, let scalar = composed.first {
            screen[cursorRow].cells[column].scalar = scalar
        }
    }

    /// Écrire sur une moitié de caractère large efface l'autre moitié.
    private func clearWideCharacter(at column: Int) {
        guard column < columns else { return }
        let cell = screen[cursorRow].cells[column]
        if cell.isContinuation, column > 0 {
            screen[cursorRow].cells[column - 1] = .erased(attributes)
        } else if cell.width == 2, column + 1 < columns {
            screen[cursorRow].cells[column + 1] = .erased(attributes)
        }
    }

    private func lineFeed() {
        index()
        if newLineMode { cursorColumn = 0 }
    }

    private func index() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private var blankLine: TerminalLine { TerminalLine(columns: columns, attributes: attributes) }

    private func scrollUp(_ count: Int) {
        let n = min(count, scrollBottom - scrollTop + 1)
        for _ in 0..<n {
            let removed = screen.remove(at: scrollTop)
            if scrollTop == 0, !isAlternateScreen { scrollback.append(removed.trimmed()) }
            screen.insert(blankLine, at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        let n = min(count, scrollBottom - scrollTop + 1)
        for _ in 0..<n {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine, at: scrollTop)
        }
    }

    private func insertLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        let n = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<n {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine, at: cursorRow)
        }
        cursorColumn = 0
        pendingWrap = false
    }

    private func deleteLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        let n = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<n {
            screen.remove(at: cursorRow)
            screen.insert(blankLine, at: scrollBottom)
        }
        cursorColumn = 0
        pendingWrap = false
    }

    private func insertCharacters(_ count: Int) {
        let n = min(count, columns - cursorColumn)
        guard n > 0 else { return }
        var cells = screen[cursorRow].cells
        cells.insert(contentsOf: Array(repeating: TerminalCell.erased(attributes), count: n), at: cursorColumn)
        cells.removeLast(n)
        screen[cursorRow].cells = cells
        pendingWrap = false
    }

    private func deleteCharacters(_ count: Int) {
        let n = min(count, columns - cursorColumn)
        guard n > 0 else { return }
        var cells = screen[cursorRow].cells
        cells.removeSubrange(cursorColumn..<(cursorColumn + n))
        cells += Array(repeating: TerminalCell.erased(attributes), count: n)
        screen[cursorRow].cells = cells
        pendingWrap = false
    }

    private func eraseCharacters(_ count: Int) {
        let end = min(cursorColumn + count, columns)
        for column in cursorColumn..<end { screen[cursorRow].cells[column] = .erased(attributes) }
        pendingWrap = false
    }

    private func eraseInLine(_ mode: Int) {
        let range: Range<Int>
        switch mode {
        case 0: range = cursorColumn..<columns
        case 1: range = 0..<(cursorColumn + 1)
        case 2: range = 0..<columns
        default: return
        }
        for column in range { screen[cursorRow].cells[column] = .erased(attributes) }
        if mode != 1 { screen[cursorRow].wrapped = false }
        pendingWrap = false
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorRow + 1 < rows { for row in (cursorRow + 1)..<rows { screen[row] = blankLine } }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow { screen[row] = blankLine }
        case 2:
            for row in 0..<rows { screen[row] = blankLine }
        case 3:
            scrollback.removeAll()
        default:
            break
        }
        pendingWrap = false
    }

    private func alignmentTest() {
        for row in 0..<rows {
            screen[row] = TerminalLine(cells: Array(repeating: TerminalCell("E"), count: columns))
        }
        cursorRow = 0
        cursorColumn = 0
    }

    // MARK: SGR

    private func selectGraphicRendition() {
        if params.isEmpty {
            attributes = .plain
            return
        }
        var index = 0
        while index < params.count {
            let group = params[index]
            let code = max(group.first ?? 0, 0)
            switch code {
            case 0: attributes = .plain
            case 1: attributes.flags.insert(.bold)
            case 2: attributes.flags.insert(.dim)
            case 3: attributes.flags.insert(.italic)
            case 4:
                if group.count > 1, group[1] == 0 { attributes.flags.remove(.underline) } else { attributes.flags.insert(.underline) }
            case 5, 6: attributes.flags.insert(.blink)
            case 7: attributes.flags.insert(.inverse)
            case 8: attributes.flags.insert(.hidden)
            case 9: attributes.flags.insert(.strikethrough)
            case 21: attributes.flags.insert(.underline)
            case 22: attributes.flags.subtract([.bold, .dim])
            case 23: attributes.flags.remove(.italic)
            case 24: attributes.flags.remove(.underline)
            case 25: attributes.flags.remove(.blink)
            case 27: attributes.flags.remove(.inverse)
            case 28: attributes.flags.remove(.hidden)
            case 29: attributes.flags.remove(.strikethrough)
            case 30...37: attributes.foreground = .indexed(UInt8(code - 30))
            case 39: attributes.foreground = .defaultColor
            case 40...47: attributes.background = .indexed(UInt8(code - 40))
            case 49: attributes.background = .defaultColor
            case 90...97: attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: attributes.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48, 58:
                let (color, consumed) = extendedColor(at: index)
                if let color {
                    if code == 38 { attributes.foreground = color } else if code == 48 { attributes.background = color }
                }
                index += consumed
            default: break
            }
            index += 1
        }
    }

    /// Couleur étendue « 38;5;n », « 38;2;r;g;b » ou leurs formes à deux-points ; renvoie aussi le
    /// nombre de paramètres supplémentaires lus (forme à points-virgules).
    private func extendedColor(at index: Int) -> (TerminalColor?, Int) {
        func clamp(_ value: Int) -> UInt8 { UInt8(min(max(value, 0), 255)) }
        let group = params[index]
        if group.count > 1 {
            switch group[1] {
            case 5 where group.count >= 3: return (.indexed(clamp(group[2])), 0)
            case 2 where group.count >= 6: return (.rgb(clamp(group[3]), clamp(group[4]), clamp(group[5])), 0)
            case 2 where group.count >= 5: return (.rgb(clamp(group[2]), clamp(group[3]), clamp(group[4])), 0)
            default: return (nil, 0)
            }
        }
        func value(_ offset: Int) -> Int? {
            params.indices.contains(index + offset) ? params[index + offset].first : nil
        }
        switch value(1) {
        case 5:
            guard let n = value(2) else { return (nil, 1) }
            return (.indexed(clamp(n)), 2)
        case 2:
            guard let r = value(2), let g = value(3), let b = value(4) else { return (nil, params.count - index - 1) }
            return (.rgb(clamp(r), clamp(g), clamp(b)), 4)
        default:
            return (nil, 0)
        }
    }
}

/// Résultat de recherche : ligne absolue et colonnes.
public struct TerminalMatch: Hashable, Sendable {
    public var line: Int
    public var columns: Range<Int>

    public init(line: Int, columns: Range<Int>) {
        self.line = line
        self.columns = columns
    }
}
