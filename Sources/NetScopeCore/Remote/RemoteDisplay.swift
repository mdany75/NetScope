import Foundation

/// Fenêtre ou plein écran, pour RDP et VNC.
public enum RemoteDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case window = "fenetre"
    case fullScreen = "plein-ecran"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .window: return "Fenêtre"
        case .fullScreen: return "Plein écran"
        }
    }
}

/// Taille de la session RDP en fenêtre.
public enum RemoteWindowSize: String, Codable, CaseIterable, Identifiable, Sendable {
    /// La session suit la taille de la fenêtre (résolution dynamique).
    case fit = "ajuster"
    case r1280x800 = "1280x800"
    case r1440x900 = "1440x900"
    case r1920x1080 = "1920x1080"
    case custom = "personnalisee"

    public var id: String { rawValue }

    /// Largeur et hauteur fixes ; nil pour « Ajuster » et « Personnalisée ».
    public var fixedSize: (width: Int, height: Int)? {
        switch self {
        case .r1280x800: return (1280, 800)
        case .r1440x900: return (1440, 900)
        case .r1920x1080: return (1920, 1080)
        case .fit, .custom: return nil
        }
    }

    /// « Ajuster », « 1440 × 900 », « Personnalisée ».
    public var label: String {
        if let size = fixedSize { return RemoteDisplaySettings.sizeLabel(size.width, size.height) }
        return self == .fit ? "Ajuster" : "Personnalisée"
    }
}

/// Mise à l'échelle de Partage d'écran (VNC).
public enum RemoteVNCScale: String, Codable, CaseIterable, Identifiable, Sendable {
    /// NetScope ne touche pas au réglage de Partage d'écran.
    case automatic = "selon-app"
    /// « Ajuster à l'espace disponible ».
    case fit = "ajuster"
    /// « Afficher la taille originale ».
    case actual = "taille-reelle"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "Selon Partage d’écran"
        case .fit: return "Ajuster à la fenêtre"
        case .actual: return "Taille réelle"
        }
    }

    /// Valeur de la préférence `shouldScaleScreen` de Partage d'écran ; nil : ne rien écrire.
    public var shouldScaleScreen: Bool? {
        switch self {
        case .automatic: return nil
        case .fit: return true
        case .actual: return false
        }
    }
}

/// Réglages d'affichage d'une connexion RDP ou VNC (ignorés pour SSH, Telnet et la série).
public struct RemoteDisplaySettings: Codable, Hashable, Sendable {
    /// Bornes de la taille personnalisée (Windows accepte de 200 à 8192 ; en deçà de 640 × 480,
    /// le bureau est inutilisable).
    public static let widthRange = 640...7680
    public static let heightRange = 480...4320

    public var mode: RemoteDisplayMode
    public var windowSize: RemoteWindowSize
    public var customWidth: Int
    public var customHeight: Int
    /// RDP : « use multimon:i:1 », la session occupe tous les écrans du Mac.
    public var allMonitors: Bool
    public var vncScale: RemoteVNCScale

    public init(mode: RemoteDisplayMode, windowSize: RemoteWindowSize = .fit, customWidth: Int = 1600,
                customHeight: Int = 1000, allMonitors: Bool = false, vncScale: RemoteVNCScale = .automatic) {
        self.mode = mode
        self.windowSize = windowSize
        self.customWidth = customWidth
        self.customHeight = customHeight
        self.allMonitors = allMonitors
        self.vncScale = vncScale
    }

    /// Comportement d'avant ces réglages : RDP en plein écran, VNC en fenêtre (Partage d'écran
    /// décide de l'échelle).
    public static func defaults(for proto: RemoteProtocol) -> RemoteDisplaySettings {
        RemoteDisplaySettings(mode: proto == .rdp ? .fullScreen : .window)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, windowSize, customWidth, customHeight, allMonitors, vncScale
    }

    /// Chaque champ est facultatif : un fichier plus ancien ou plus récent se lit toujours.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = RemoteDisplaySettings(mode: .window)
        mode = (try? c.decodeIfPresent(RemoteDisplayMode.self, forKey: .mode)) ?? base.mode
        windowSize = (try? c.decodeIfPresent(RemoteWindowSize.self, forKey: .windowSize)) ?? base.windowSize
        customWidth = (try? c.decodeIfPresent(Int.self, forKey: .customWidth)) ?? base.customWidth
        customHeight = (try? c.decodeIfPresent(Int.self, forKey: .customHeight)) ?? base.customHeight
        allMonitors = (try? c.decodeIfPresent(Bool.self, forKey: .allMonitors)) ?? base.allMonitors
        vncScale = (try? c.decodeIfPresent(RemoteVNCScale.self, forKey: .vncScale)) ?? base.vncScale
    }

    /// Taille fixe de la session en fenêtre, bornée ; nil : ajustée à la fenêtre.
    public var resolvedWindowSize: (width: Int, height: Int)? {
        if let size = windowSize.fixedSize { return size }
        guard windowSize == .custom else { return nil }
        return (Self.clamp(customWidth, Self.widthRange), Self.clamp(customHeight, Self.heightRange))
    }

    /// Copie avec un autre mode (choix rapide au moment de « Connecter »).
    public func with(mode: RemoteDisplayMode) -> RemoteDisplaySettings {
        var copy = self
        copy.mode = mode
        return copy
    }

    /// Résumé du panneau de détails : « Fenêtre · 1440 × 900 », « Plein écran · tous les écrans ».
    public func summary(for proto: RemoteProtocol) -> String {
        var parts = [mode.label]
        switch proto {
        case .rdp:
            if mode == .window {
                if let size = resolvedWindowSize {
                    parts.append(Self.sizeLabel(size.width, size.height))
                } else {
                    parts.append("ajustée à la fenêtre")
                }
            }
            if allMonitors { parts.append("tous les écrans") }
        case .vnc:
            if vncScale == .fit { parts.append("ajustée à la fenêtre") }
            if vncScale == .actual { parts.append("taille réelle") }
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// « 1440 × 900 » (espaces insécables autour du signe de multiplication).
    public static func sizeLabel(_ width: Int, _ height: Int) -> String {
        "\(width)\u{00A0}×\u{00A0}\(height)"
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Préférence de Partage d'écran (com.apple.ScreenSharing) qui règle la mise à l'échelle :
/// c'est la clé liée à « Ajuster à l'espace disponible » / « Afficher la taille originale » de
/// ses Réglages › Affichage. Elle est commune à toutes les sessions de Partage d'écran.
public enum RemoteScreenSharingPreferences {
    public static let domain = "com.apple.ScreenSharing"
    public static let scaleKey = "shouldScaleScreen"
}

/// Partage d'écran n'a ni paramètre d'URL ni préférence pour le plein écran : NetScope passe la
/// fenêtre de session en plein écran par l'accessibilité (attribut AXFullScreen), après
/// l'authentification. Cette fonction choisit la fenêtre à partir d'un relevé de ses fenêtres.
public enum RemoteFullScreenTarget {
    public struct Window: Equatable, Sendable {
        public var title: String
        public var subrole: String
        /// Absente avant l'ouverture de la connexion.
        public var isNew: Bool
        public var canFullScreen: Bool
        public var isFullScreen: Bool

        public init(title: String, subrole: String, isNew: Bool, canFullScreen: Bool, isFullScreen: Bool = false) {
            self.title = title
            self.subrole = subrole
            self.isNew = isNew
            self.canFullScreen = canFullScreen
            self.isFullScreen = isFullScreen
        }
    }

    /// Fenêtre de session à passer en plein écran : une fenêtre standard apparue depuis
    /// l'ouverture (ni dialogue d'identification ni fenêtre « Connexions »), de préférence celle
    /// dont le titre contient l'hôte. nil : pas encore là (on réessaie plus tard).
    public static func pick(_ windows: [Window], host: String) -> Int? {
        let candidates = windows.indices.filter {
            let w = windows[$0]
            return w.isNew && w.canFullScreen && !w.isFullScreen && w.subrole == "AXStandardWindow"
        }
        let needle = host.lowercased()
        if !needle.isEmpty, let match = candidates.first(where: { windows[$0].title.lowercased().contains(needle) }) {
            return match
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
