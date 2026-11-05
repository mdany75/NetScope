import AppKit
import NetScopeCore
import SwiftUI

// Note 57 : couleurs et réglages d'affichage du terminal intégré. Le terminal est sombre par
// défaut (comme le croquis Remote.dc.html et Terminal) ; « Clair » et « Suivre le système » donnent
// des couleurs lisibles sur fond blanc. Chaque palette est complète (16 couleurs ANSI, curseur,
// sélection, résultats de recherche) : aucune couleur ne dépend d'un fond qu'elle ne connaît pas.

/// Apparence du terminal.
enum TerminalAppearance: String, CaseIterable, Identifiable {
    case dark, light, system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: return "Sombre"
        case .light: return "Clair"
        case .system: return "Suivre le système"
        }
    }

    func palette(for appearance: NSAppearance) -> TerminalPalette {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return appearance.isDark ? .dark : .light
        }
    }
}

/// Préférences du terminal, communes à tous les onglets.
@MainActor
final class TerminalPreferences: ObservableObject {
    static let shared = TerminalPreferences()

    private let defaults: UserDefaults?

    @Published var appearance: TerminalAppearance { didSet { defaults?.set(appearance.rawValue, forKey: "acces.terminal.apparence") } }
    @Published var fontSize: Double { didSet { defaults?.set(fontSize, forKey: "acces.terminal.taille") } }
    /// Option envoie ESC devant la touche (Méta) au lieu de composer « @ », « | », « [ »…
    @Published var optionAsMeta: Bool { didSet { defaults?.set(optionAsMeta, forKey: "acces.terminal.optionMeta") } }
    /// Journal .log de chaque nouvelle session dans ~/Library/Logs/NetScope.
    @Published var logSessions: Bool { didSet { defaults?.set(logSessions, forKey: "acces.terminal.journal") } }

    static let fontSizes: [Double] = [11, 12, 13, 14, 16]

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        appearance = defaults?.string(forKey: "acces.terminal.apparence").flatMap(TerminalAppearance.init(rawValue:)) ?? .dark
        let size = defaults?.double(forKey: "acces.terminal.taille") ?? 0
        fontSize = size > 0 ? size : 12
        optionAsMeta = defaults?.bool(forKey: "acces.terminal.optionMeta") ?? false
        // Démonstration : journal activé, comme dans le croquis.
        logSessions = defaults?.bool(forKey: "acces.terminal.journal") ?? RegEnvironment.isDemo
    }
}

/// Couleurs d'un terminal.
struct TerminalPalette {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let cursorText: NSColor
    let selection: NSColor
    let match: NSColor
    let currentMatch: NSColor
    let dimText: NSColor
    /// 16 couleurs ANSI (0 à 7, puis les vives 8 à 15).
    let ansi: [NSColor]

    var isDark: Bool { background.brightness < 0.5 }

    static let dark = TerminalPalette(
        background: NSColor(hex: 0x0B1220), foreground: NSColor(hex: 0xE2E8F0),
        cursor: NSColor(hex: 0x4ADE80), cursorText: NSColor(hex: 0x0B1220),
        selection: NSColor(hex: 0x3B82F6, alpha: 0.42), match: NSColor(hex: 0xFACC15, alpha: 0.32),
        currentMatch: NSColor(hex: 0xF97316, alpha: 0.65), dimText: NSColor(hex: 0x94A3B8),
        ansi: [0x334155, 0xF87171, 0x4ADE80, 0xFACC15, 0x60A5FA, 0xE879F9, 0x22D3EE, 0xCBD5E1,
               0x64748B, 0xFCA5A5, 0x86EFAC, 0xFDE68A, 0x93C5FD, 0xF0ABFC, 0x67E8F9, 0xF8FAFC].map { NSColor(hex: $0) })

    static let light = TerminalPalette(
        background: NSColor(hex: 0xFFFFFF), foreground: NSColor(hex: 0x1F2937),
        cursor: NSColor(hex: 0x2563EB), cursorText: NSColor(hex: 0xFFFFFF),
        selection: NSColor(hex: 0x2563EB, alpha: 0.22), match: NSColor(hex: 0xFACC15, alpha: 0.45),
        currentMatch: NSColor(hex: 0xF97316, alpha: 0.55), dimText: NSColor(hex: 0x6B7280),
        ansi: [0x1F2937, 0xB91C1C, 0x15803D, 0x92400E, 0x1D4ED8, 0xA21CAF, 0x0E7490, 0x6B7280,
               0x4B5563, 0xDC2626, 0x16A34A, 0xB45309, 0x2563EB, 0xC026D3, 0x0891B2, 0x111827].map { NSColor(hex: $0) })

    /// Couleur d'une cellule (gras : couleurs 0 à 7 rendues vives, comme xterm).
    func color(_ color: TerminalColor, isForeground: Bool, bold: Bool = false) -> NSColor {
        switch color {
        case .defaultColor:
            return isForeground ? foreground : background
        case .indexed(let index):
            var value = Int(index)
            if bold, isForeground, value < 8 { value += 8 }
            return Self.xterm(value, ansi: ansi)
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// Couleur xterm 0 à 255 : 16 couleurs du thème, cube 6×6×6, puis 24 gris.
    static func xterm(_ index: Int, ansi: [NSColor]) -> NSColor {
        if index < 16 { return ansi[index] }
        if index < 232 {
            let n = index - 16
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: levels[n / 36] / 255, green: levels[(n / 6) % 6] / 255, blue: levels[n % 6] / 255, alpha: 1)
        }
        let gray = CGFloat(8 + (index - 232) * 10) / 255
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    }
}

private extension NSColor {
    var brightness: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }
}
