import Foundation

// Note 61 : couleurs de la Carte du réseau (croquis Topologie), communes à l'écran (TopoStyle, en
// clair et en sombre) et aux exports SVG et draw.io (toujours en clair, sur fond blanc).

/// Couleur en clair et en sombre (« 0x1D4ED8 »).
public struct TopoColor: Hashable, Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(_ light: UInt32, dark: UInt32? = nil) {
        self.light = light
        self.dark = dark ?? light
    }

    /// « #1D4ED8 » (couleur en clair), pour SVG et draw.io.
    public var hex: String { Self.hex(light) }

    public static func hex(_ value: UInt32) -> String { String(format: "#%06X", value & 0xFF_FFFF) }
}

public enum TopoPalette {
    public static let wire = TopoColor(0x94A3B8)
    public static let wifi = TopoColor(0x7C3AED)
    /// Liens vus par LLDP ou la FortiGate (ISL, uplinks, FortiLink).
    public static let lldp = TopoColor(0x0F766E, dark: 0x4FC3B5)
    /// Fond du nœud Internet.
    public static let internetFill = TopoColor(0xF8FAFC, dark: 0x20364B)
    /// Bordure en tirets des nœuds déduits et d'Internet.
    public static let inferredBorder = TopoColor(0x94A3B8)
    /// Deuxième carte d'un groupe (pile).
    public static let groupBack = TopoColor(0xCBD5E1, dark: 0x3F556E)

    // Couleurs fixes des exports (fond blanc), d'après Theme en clair.
    public static let exportText: UInt32 = 0x111827
    public static let exportSecondary: UInt32 = 0x4B5563
    public static let exportBorder: UInt32 = 0xC9CBD0
    public static let exportPanel: UInt32 = 0xFFFFFF
    public static let exportBackground: UInt32 = 0xF6F6F7
    public static let exportAccent: UInt32 = 0x2563EB
    public static let exportCritical: UInt32 = 0xB91C1C

    /// Couleur du symbole (fg) et de sa pastille (bg) d'un nœud.
    public static func node(kind: TopoNodeKind, type: DeviceType?) -> (fg: TopoColor, bg: TopoColor) {
        switch kind {
        case .internet: return (TopoColor(0x475569, dark: 0xB6C0CE), TopoColor(0xF1F5F9, dark: 0x20364B))
        case .passerelle: return (TopoColor(0x4338CA, dark: 0xA49EE5), TopoColor(0xE0E7FF, dark: 0x1B2750))
        case .switch: return (TopoColor(0x1D4ED8, dark: 0x93ACF1), TopoColor(0xDBEAFE, dark: 0x1B3250))
        case .pointAcces: return (TopoColor(0x6D28D9, dark: 0xB897ED), TopoColor(0xEDE9FE, dark: 0x251B50))
        case .groupe, .appareil:
            switch type {
            case .imprimante: return (TopoColor(0x0E7490, dark: 0x8FDEF4), TopoColor(0xCFFAFE, dark: 0x1B4C50))
            case .camera: return (TopoColor(0x92400E, dark: 0xF4B68F), TopoColor(0xFEF3C7, dark: 0x50461B))
            case .serveur: return (TopoColor(0x1E3A8A, dark: 0x9AAFE9), TopoColor(0xE0E7FF, dark: 0x1B2750))
            case .telephone: return (TopoColor(0x6D28D9, dark: 0xB897ED), TopoColor(0xF5F3FF, dark: 0x241B50))
            case .telephoneIP: return (TopoColor(0xBE185D, dark: 0xF29BC4), TopoColor(0xFCE7F3, dark: 0x50203A))
            default: return (TopoColor(0x374151, dark: 0xB6BFCE), TopoColor(0xF3F4F6, dark: 0x2E333D))
            }
        }
    }

    /// Point d'état d'un nœud, en clair (exports) : vert, gris ou rouge.
    public static func status(_ status: TopoStatus) -> UInt32 {
        switch status {
        case .ok: return 0x15803D
        case .horsLigne: return 0x9CA3AF
        case .critique: return 0xB91C1C
        }
    }
}
