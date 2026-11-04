import AppKit
import SwiftUI

// Système visuel de NetScope : disposition, densité et libellés des croquis (docs/croquis/),
// habillage de macOS. Toutes les couleurs suivent l'apparence du système (clair ou sombre) et la
// couleur d'accent choisie dans Réglages Système.

extension Color {
    /// Couleur fixe à partir d'une valeur hexadécimale 0xRRGGBB (même teinte en clair et en sombre).
    /// Hors de Theme, préférer les jetons du thème ou `Color(light:dark:)`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Couleur qui suit l'apparence : `light` en mode clair, `dark` en mode sombre.
    init(light: UInt32, dark: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDark ? dark : light, alpha: opacity)
        })
    }

    /// Couleur dynamique calculée à partir de couleurs système, recalculée pour chaque apparence.
    static func system(_ make: @escaping (_ dark: Bool) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var result = NSColor.clear
            appearance.performAsCurrentDrawingAppearance { result = make(appearance.isDark) }
            return result
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: CGFloat(alpha))
    }
}

extension NSAppearance {
    /// Vrai pour les apparences sombres (contraste élevé compris).
    var isDark: Bool {
        guard let match = bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                           .accessibilityHighContrastDarkAqua]) else { return false }
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    }
}

enum Theme {
    // MARK: Couleurs (dynamiques, clair et sombre)

    /// Fond du contenu, derrière les panneaux.
    static let appBackground = Color(nsColor: .windowBackgroundColor)
    /// Fond d'un panneau, d'un tableau, d'un champ.
    static let panel = Color(nsColor: .controlBackgroundColor)
    /// Fond légèrement teinté (en-têtes de tableau, encadrés, zones secondaires).
    static let panelMuted = Color(light: 0xF6F6F7, dark: 0x2A2A2D)
    static let border = Color(light: 0xE3E4E8, dark: 0x3A3A3E)
    static let borderStrong = Color(light: 0xC9CBD0, dark: 0x505055)
    static let text = Color(nsColor: .labelColor)
    static let textSecondary = Color(light: 0x4B5563, dark: 0xB4B4BA)
    static let textTertiary = Color(light: 0x6B7280, dark: 0x8E8E93)
    /// Texte posé sur un fond accent ou une couleur vive (bouton principal, compteur).
    static let onAccent = Color.white
    /// Voile d'un fond (survol, sélection discrète) : noir en clair, blanc en sombre.
    static let hover = Color(light: 0x000000, dark: 0xFFFFFF, opacity: 0.06)

    /// Bloc de console (commande, résultat brut) : sombre dans les deux apparences, comme Terminal.
    static let console = Color(light: 0x1E1F22, dark: 0x111113)
    static let consoleText = Color(hex: 0xE6E6E8)
    static let consoleMuted = Color(hex: 0x9C9CA3)
    static let consolePrompt = Color(hex: 0x8FBFFF)

    /// Couleur d'accent de macOS (Réglages Système › Apparence).
    static let accent = Color(nsColor: .controlAccentColor)
    /// Accent pour du texte sur fond pâle : un peu plus foncé en clair, plus clair en sombre.
    static let accentStrong = Color.system { dark in
        let base = NSColor.controlAccentColor
        return (dark ? base.blended(withFraction: 0.3, of: .white) : base.blended(withFraction: 0.2, of: .black)) ?? base
    }
    static let accentSoft = Color.system { dark in NSColor.controlAccentColor.withAlphaComponent(dark ? 0.24 : 0.12) }

    static let success = Color(light: 0x15803D, dark: 0x4ADE80)
    static let successSoft = Color(light: 0xDCFCE7, dark: 0x173C26)
    static let successDot = Color(nsColor: .systemGreen)
    static let warning = Color(light: 0xC2410C, dark: 0xFB923C)
    static let warningSoft = Color(light: 0xFFEDD5, dark: 0x45280F)
    static let warningDot = Color(nsColor: .systemOrange)
    static let critical = Color(light: 0xB91C1C, dark: 0xF87171)
    static let criticalSoft = Color(light: 0xFEE2E2, dark: 0x481B1B)
    static let criticalBadge = Color(nsColor: .systemRed)
    static let neutralSoft = Color(light: 0xF0F1F3, dark: 0x333336)
    static let neutralText = Color(light: 0x374151, dark: 0xD4D4D8)
    static let neutralDot = Color(light: 0x9CA3AF, dark: 0x7C7C82)

    // MARK: Polices

    /// Texte de l'interface (SF Pro), 13 pt.
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let captionSemibold = Font.system(size: 11, weight: .semibold)
    static let screenTitle = Font.system(size: 17, weight: .bold)
    static let panelTitle = Font.system(size: 15, weight: .bold)

    /// Valeurs techniques (IP, MAC, ports) en SF Mono.
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Rayons et espacements

    static let panelRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 6
    static let chipRadius: CGFloat = 4
    static let controlHeight: CGFloat = 28
    static let contentPadding: CGFloat = 16
    static let sidebarWidth: CGFloat = 220
    /// Largeur sous laquelle le panneau de droite d'un écran se replie (bouton pour l'afficher).
    static let compactWidth: CGFloat = 980
}

// MARK: - Styles de boutons (contrôles natifs de macOS)

/// Bouton principal : bouton proéminent du système, à la couleur d'accent.
/// Taille normale : « grande » taille de macOS (hauteur des croquis) ; une taille demandée par
/// l'appelant (`.controlSize(.small)`…) est respectée.
struct PrimaryButtonStyle: PrimitiveButtonStyle {
    var tint: Color? = nil
    @Environment(\.controlSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.borderedProminent)
            .controlSize(size == .regular ? .large : size)
            .tint(tint)
    }
}

/// Bouton secondaire : bouton à bordure du système.
struct SecondaryButtonStyle: PrimitiveButtonStyle {
    @Environment(\.controlSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .controlSize(size == .regular ? .large : size)
    }
}

/// Bouton discret : sans fond ni bordure, texte accent (lien d'action).
struct GhostButtonStyle: ButtonStyle {
    var color: Color = Theme.accentStrong

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyMedium)
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.7 : 1))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(configuration.isPressed ? Theme.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }
}

extension PrimitiveButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension PrimitiveButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
}
