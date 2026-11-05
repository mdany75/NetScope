import Foundation

/// Touche du clavier, indépendante d'AppKit (la vue traduit les événements du Mac).
public enum TerminalKey: Hashable, Sendable {
    case character(String)
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, forwardDelete
    case backspace, tab, enter, escape
    case function(Int)
}

/// Touches de modification.
public struct TerminalKeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = TerminalKeyModifiers(rawValue: 1)
    public static let option = TerminalKeyModifiers(rawValue: 2)
    public static let control = TerminalKeyModifiers(rawValue: 4)

    /// Valeur xterm des modificateurs (« 1 + Maj + 2×Alt + 4×Ctrl »), pour « ESC [ 1 ; m A ».
    var xtermValue: Int {
        1 + (contains(.shift) ? 1 : 0) + (contains(.option) ? 2 : 0) + (contains(.control) ? 4 : 0)
    }
}

/// Octets envoyés pour une touche (séquences de xterm).
public enum TerminalKeyEncoder {
    /// - `applicationCursor` : mode DECCKM (flèches « ESC O A » au lieu de « ESC [ A »).
    /// - `optionAsMeta` : Option envoie ESC devant la touche (Méta d'Emacs, mots de bash) ; sinon
    ///   Option compose les caractères du clavier (« @ », « | », « [ » sur un clavier français).
    public static func encode(_ key: TerminalKey, modifiers: TerminalKeyModifiers = [], applicationCursor: Bool = false,
                              optionAsMeta: Bool = false) -> [UInt8] {
        let esc: UInt8 = 0x1B
        let meta = optionAsMeta && modifiers.contains(.option)
        // Modificateurs transmis aux touches spéciales : Option seulement s'il sert de Méta.
        var special = modifiers
        if !optionAsMeta { special.remove(.option) }

        func csi(_ final: String) -> [UInt8] {
            if special.isEmpty { return [esc] + Array(((applicationCursor ? "O" : "[") + final).utf8) }
            return [esc] + Array("[1;\(special.xtermValue)\(final)".utf8)
        }
        func tilde(_ code: Int) -> [UInt8] {
            special.isEmpty ? [esc] + Array("[\(code)~".utf8) : [esc] + Array("[\(code);\(special.xtermValue)~".utf8)
        }

        switch key {
        case .up: return csi("A")
        case .down: return csi("B")
        case .right: return csi("C")
        case .left: return csi("D")
        case .home: return csi("H")
        case .end: return csi("F")
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .insert: return tilde(2)
        case .forwardDelete: return tilde(3)
        case .function(let n):
            switch n {
            case 1...4:
                let final = ["P", "Q", "R", "S"][n - 1]
                return special.isEmpty ? [esc, UInt8(ascii: "O")] + Array(final.utf8) : [esc] + Array("[1;\(special.xtermValue)\(final)".utf8)
            case 5...12:
                let codes = [15, 17, 18, 19, 20, 21, 23, 24]
                return tilde(codes[n - 5])
            case 13...20:
                // F13 à F20 : codes xterm de Maj+F1…F8 sur les claviers Mac étendus.
                let codes = [25, 26, 28, 29, 31, 32, 33, 34]
                return tilde(codes[n - 13])
            default: return []
            }
        case .backspace:
            let byte: [UInt8] = modifiers.contains(.control) ? [0x08] : [0x7F]
            return meta ? [esc] + byte : byte
        case .tab:
            return modifiers.contains(.shift) ? [esc] + Array("[Z".utf8) : [0x09]
        case .enter:
            return meta ? [esc, 0x0D] : [0x0D]
        case .escape:
            return [esc]
        case .character(let text):
            var bytes: [UInt8]
            if modifiers.contains(.control), let control = controlCode(text) {
                bytes = [control]
            } else {
                bytes = Array(text.utf8)
            }
            return meta ? [esc] + bytes : bytes
        }
    }

    /// Ctrl+touche : A…Z → 1…26, @ et espace → 0, [ \ ] ^ _ → 27…31, ? → 127, chiffres de xterm.
    public static func controlCode(_ text: String) -> UInt8? {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, scalar.isASCII else { return nil }
        let value = UInt8(scalar.value)
        switch value {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return value - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return value - UInt8(ascii: "A") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "), UInt8(ascii: "2"): return 0
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 27
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 28
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 29
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 30
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "7"): return 31
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 127
        default: return nil
        }
    }

    /// Texte collé : fins de ligne en CR (comme Entrée) et, si l'application l'a demandé, entouré
    /// des marqueurs du collage encadré (le shell ne lance alors rien tout seul).
    public static func paste(_ text: String, bracketed: Bool, encoding: TerminalEncoding = .utf8) -> [UInt8] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if bracketed {
            // Un marqueur de fin dans le texte collé ne doit pas sortir du collage encadré.
            normalized = normalized.replacingOccurrences(of: "\u{1B}[201~", with: "")
            return Array("\u{1B}[200~".utf8) + encoding.encode(normalized) + Array("\u{1B}[201~".utf8)
        }
        return encoding.encode(normalized)
    }
}

/// Journal de session en texte brut : séquences d'échappement retirées, retours chariot et
/// effacements arrière appliqués à la ligne en cours. Lit le flux par morceaux.
public struct TerminalLogFilter: Sendable {
    private enum State: Sendable { case text, escape, csi, osc, oscEscape, string, stringEscape }
    private var state = State.text
    private var line: [Unicode.Scalar] = []
    private var column = 0
    private var utf8 = [UInt8]()

    public init() {}

    /// Lignes terminées par ce morceau (chacune suivie de « \n »).
    public mutating func feed(_ bytes: [UInt8]) -> String {
        var output = ""
        var input = utf8 + bytes
        utf8.removeAll()
        // Fin de séquence UTF-8 incomplète gardée pour le prochain morceau.
        var cut = input.count
        var back = 0
        while back < 3, cut - back - 1 >= 0 {
            let byte = input[cut - back - 1]
            if byte & 0xC0 == 0x80 { back += 1; continue }
            if byte & 0xC0 == 0xC0 {
                let needed = byte & 0xE0 == 0xC0 ? 2 : (byte & 0xF0 == 0xE0 ? 3 : 4)
                if back + 1 < needed { cut -= back + 1 }
            }
            break
        }
        if cut < input.count {
            utf8 = Array(input[cut...])
            input.removeLast(input.count - cut)
        }
        for scalar in String(decoding: input, as: UTF8.self).unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                switch value {
                case 0x1B: state = .escape
                case 0x0A:
                    output += String(String.UnicodeScalarView(line)).trimmingTrailingSpaces() + "\n"
                    line.removeAll()
                    column = 0
                case 0x0D: column = 0
                case 0x08: column = max(column - 1, 0)
                case 0x09: put(" ")
                case 0x00..<0x20, 0x7F: break
                default: put(scalar)
                }
            case .escape:
                switch value {
                case 0x5B: state = .csi
                case 0x5D: state = .osc
                case 0x50, 0x58, 0x5E, 0x5F: state = .string
                case 0x20...0x2F: break
                default: state = .text
                }
            case .csi:
                if (0x40...0x7E).contains(value) {
                    // Effacement de la fin de ligne (« ESC [ K ») : appliqué au texte.
                    if value == 0x4B, column < line.count { line.removeLast(line.count - column) }
                    state = .text
                }
            case .osc:
                if value == 0x07 { state = .text } else if value == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = value == 0x5C ? .text : .osc
            case .string:
                if value == 0x1B { state = .stringEscape }
            case .stringEscape:
                state = value == 0x5C ? .text : .string
            }
        }
        return output
    }

    /// Ligne en cours, pas encore terminée (fin du journal).
    public var pendingLine: String { String(String.UnicodeScalarView(line)).trimmingTrailingSpaces() }

    private mutating func put(_ scalar: Unicode.Scalar) {
        if column < line.count {
            line[column] = scalar
        } else {
            line.append(scalar)
        }
        column += 1
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        var copy = self
        while copy.last == " " { copy.removeLast() }
        return copy
    }
}
