import Foundation

// Note 57 : terminal intégré d'Accès distant. Modèle de l'écran du terminal (cellules, couleurs,
// attributs), sans aucune interface : la vue de l'application le dessine.

/// Couleur d'une cellule : celle du thème, une des 256 couleurs xterm, ou une couleur 24 bits.
public enum TerminalColor: Hashable, Sendable {
    case defaultColor
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// Attributs graphiques (SGR) d'une cellule.
public struct TerminalAttributes: Hashable, Sendable {
    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let bold = Flags(rawValue: 1 << 0)
        public static let dim = Flags(rawValue: 1 << 1)
        public static let italic = Flags(rawValue: 1 << 2)
        public static let underline = Flags(rawValue: 1 << 3)
        public static let blink = Flags(rawValue: 1 << 4)
        public static let inverse = Flags(rawValue: 1 << 5)
        public static let hidden = Flags(rawValue: 1 << 6)
        public static let strikethrough = Flags(rawValue: 1 << 7)
    }

    public var foreground: TerminalColor
    public var background: TerminalColor
    public var flags: Flags

    public init(foreground: TerminalColor = .defaultColor, background: TerminalColor = .defaultColor, flags: Flags = []) {
        self.foreground = foreground
        self.background = background
        self.flags = flags
    }

    public static let plain = TerminalAttributes()
}

/// Une cellule de l'écran : un caractère (scalaire Unicode) et ses attributs.
/// `width` vaut 1, 2 (caractère large, suivi d'une cellule de continuation) ou 0 (continuation).
public struct TerminalCell: Hashable, Sendable {
    public var scalar: Unicode.Scalar
    public var attributes: TerminalAttributes
    public var width: UInt8

    public init(_ scalar: Unicode.Scalar = " ", attributes: TerminalAttributes = .plain, width: UInt8 = 1) {
        self.scalar = scalar
        self.attributes = attributes
        self.width = width
    }

    public static let blank = TerminalCell()

    /// Cellule vide qui garde la couleur de fond courante (effacement « BCE » de xterm-256color).
    public static func erased(_ attributes: TerminalAttributes) -> TerminalCell {
        TerminalCell(" ", attributes: TerminalAttributes(background: attributes.background), width: 1)
    }

    public var isContinuation: Bool { width == 0 }
}

/// Une ligne : ses cellules et, si elle a débordé sur la suivante, l'indicateur `wrapped`
/// (la copie et la recherche la recollent alors à la ligne suivante).
public struct TerminalLine: Hashable, Sendable {
    public var cells: [TerminalCell]
    public var wrapped: Bool

    public init(columns: Int, attributes: TerminalAttributes = .plain) {
        cells = Array(repeating: .erased(attributes), count: max(columns, 0))
        wrapped = false
    }

    public init(cells: [TerminalCell], wrapped: Bool = false) {
        self.cells = cells
        self.wrapped = wrapped
    }

    /// Texte de la ligne (cellules de continuation sautées), espaces de fin retirés.
    public var text: String {
        var scalars = String.UnicodeScalarView()
        for cell in cells where !cell.isContinuation { scalars.append(cell.scalar) }
        var result = String(scalars)
        while result.last == " " { result.removeLast() }
        return result
    }

    /// Ligne raccourcie aux cellules utiles (historique : moins de mémoire).
    func trimmed() -> TerminalLine {
        var end = cells.count
        while end > 0, cells[end - 1].scalar == " ", cells[end - 1].attributes.background == .defaultColor,
              !cells[end - 1].attributes.flags.contains(.inverse) {
            end -= 1
        }
        return TerminalLine(cells: Array(cells[..<end]), wrapped: wrapped)
    }

    mutating func resize(to columns: Int) {
        if cells.count < columns {
            cells += Array(repeating: .blank, count: columns - cells.count)
        } else if cells.count > columns {
            cells.removeLast(cells.count - columns)
            // Caractère large coupé en deux : remplacé par un espace.
            if let last = cells.last, last.width == 2 { cells[cells.count - 1] = .blank }
        }
    }
}

/// Position dans le tampon : ligne absolue (0 = plus ancienne ligne de l'historique) et colonne.
public struct TerminalPosition: Hashable, Comparable, Sendable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (lhs: TerminalPosition, rhs: TerminalPosition) -> Bool {
        lhs.line != rhs.line ? lhs.line < rhs.line : lhs.column < rhs.column
    }
}

/// Forme du curseur (DECSCUSR).
public enum TerminalCursorStyle: Hashable, Sendable {
    case block, underline, bar
}

/// Encodage des octets reçus et envoyés.
public enum TerminalEncoding: String, CaseIterable, Identifiable, Sendable {
    case utf8 = "UTF-8"
    case latin1 = "ISO-8859-1"
    case cp437 = "CP437"

    public var id: String { rawValue }
    public var label: String { rawValue }

    /// Octets d'un texte saisi (caractère absent de l'encodage : « ? »).
    public func encode(_ text: String) -> [UInt8] {
        switch self {
        case .utf8:
            return Array(text.utf8)
        case .latin1:
            return text.unicodeScalars.map { $0.value < 0x100 ? UInt8($0.value) : UInt8(ascii: "?") }
        case .cp437:
            return text.unicodeScalars.map { scalar in
                if scalar.value < 0x80 { return UInt8(scalar.value) }
                if let index = TerminalCodePage.cp437.firstIndex(of: scalar) { return UInt8(0x80 + index) }
                return UInt8(ascii: "?")
            }
        }
    }
}

/// Table CP437 (IBM PC) des octets 0x80 à 0xFF.
public enum TerminalCodePage {
    public static let cp437: [Unicode.Scalar] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
            .unicodeScalars)
}

/// Largeur d'affichage d'un caractère : 0 (marque combinante), 1, ou 2 (idéogrammes, émojis).
public enum TerminalCharWidth {
    public static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x300 { return 1 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return 0
        case .format: return value == 0x00AD ? 1 : 0
        default: break
        }
        if isWide(value) { return 2 }
        if scalar.properties.isEmojiPresentation { return 2 }
        return 1
    }

    private static func isWide(_ v: UInt32) -> Bool {
        (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) || (0x3041...0x33FF).contains(v)
            || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v)
            || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v)
            || (0x1F900...0x1F9FF).contains(v) || (0x20000...0x3FFFD).contains(v)
    }
}

/// Jeu de caractères G0/G1 : ASCII ou graphismes DEC (traits des cadres de menus).
enum TerminalCharset: Hashable, Sendable {
    case ascii, decGraphics

    static let decGraphicsMap: [UInt32: Unicode.Scalar] = [
        0x5F: "\u{00A0}", 0x60: "◆", 0x61: "▒", 0x62: "␉", 0x63: "␌", 0x64: "␍", 0x65: "␊", 0x66: "°", 0x67: "±",
        0x68: "␤", 0x69: "␋", 0x6A: "┘", 0x6B: "┐", 0x6C: "┌", 0x6D: "└", 0x6E: "┼", 0x6F: "⎺", 0x70: "⎻",
        0x71: "─", 0x72: "⎼", 0x73: "⎽", 0x74: "├", 0x75: "┤", 0x76: "┴", 0x77: "┬", 0x78: "│", 0x79: "≤",
        0x7A: "≥", 0x7B: "π", 0x7C: "≠", 0x7D: "£", 0x7E: "·",
    ]

    func map(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard self == .decGraphics else { return scalar }
        return Self.decGraphicsMap[scalar.value] ?? scalar
    }
}
