import SwiftUI

// Système visuel de NetScope, d'après les croquis (docs/croquis/). Interface claire pour l'instant.

extension Color {
    /// Couleur à partir d'une valeur hexadécimale 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Theme {
    // MARK: Couleurs

    static let appBackground = Color(hex: 0xF3F4F6)
    static let panel = Color(hex: 0xFFFFFF)
    static let panelMuted = Color(hex: 0xF9FAFB)
    static let border = Color(hex: 0xE5E7EB)
    static let borderStrong = Color(hex: 0xD1D5DB)
    static let text = Color(hex: 0x111827)
    static let textSecondary = Color(hex: 0x4B5563)
    static let textTertiary = Color(hex: 0x6B7280)

    static let sidebar = Color(hex: 0x0F172A)
    static let sidebarText = Color(hex: 0xE2E8F0)
    static let sidebarActive = Color(hex: 0x1E293B)
    static let sidebarHeading = Color(hex: 0x94A3B8)

    static let accent = Color(hex: 0x2563EB)
    static let accentStrong = Color(hex: 0x1D4ED8)
    static let accentSoft = Color(hex: 0xEFF6FF)

    static let success = Color(hex: 0x15803D)
    static let successSoft = Color(hex: 0xDCFCE7)
    static let successDot = Color(hex: 0x22C55E)
    static let warning = Color(hex: 0xC2410C)
    static let warningSoft = Color(hex: 0xFFEDD5)
    static let critical = Color(hex: 0xB91C1C)
    static let criticalSoft = Color(hex: 0xFEE2E2)
    static let criticalBadge = Color(hex: 0xDC2626)
    static let neutralSoft = Color(hex: 0xF3F4F6)
    static let neutralText = Color(hex: 0x374151)

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

    static let panelRadius: CGFloat = 8
    static let buttonRadius: CGFloat = 6
    static let chipRadius: CGFloat = 4
    static let controlHeight: CGFloat = 32
    static let contentPadding: CGFloat = 20
    static let sidebarWidth: CGFloat = 220
}

// MARK: - Styles de boutons

/// Bouton principal : fond accent, texte blanc.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyMedium)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(configuration.isPressed ? Theme.accentStrong : tint))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }
}

/// Bouton secondaire : fond blanc, bordure grise.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyMedium)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(configuration.isPressed ? Theme.panelMuted : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .strokeBorder(configuration.isPressed ? Theme.borderStrong : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }
}

/// Bouton discret : sans fond ni bordure, texte accent.
struct GhostButtonStyle: ButtonStyle {
    var color: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyMedium)
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.7 : 1))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(configuration.isPressed ? Theme.neutralSoft : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
}
