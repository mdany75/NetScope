import Foundation

// Autorisation de localisation exigée par macOS pour lire le SSID et le BSSID. Logique pure,
// sans CoreLocation : l'application convertit CLAuthorizationStatus en `WifiLocationStatus`
// et affiche le bouton et le message décrits par `WifiLocationGuidance`.

/// État de l'autorisation, vu par NetScope.
public enum WifiLocationStatus: String, Sendable, CaseIterable {
    /// Service de localisation désactivé pour tout le Mac.
    case servicesDisabled
    /// L'utilisateur n'a encore rien répondu : la fenêtre de macOS peut s'afficher.
    case notDetermined
    /// Refusé par l'utilisateur : macOS n'affiche plus jamais la fenêtre.
    case denied
    /// Interdit par un profil de gestion ou le contrôle parental.
    case restricted
    /// Autorisé.
    case authorized

    /// macOS ne mentionne l'état « désactivé » que si le service est coupé pour tout le Mac.
    public static func from(servicesEnabled: Bool, status: WifiLocationStatus) -> WifiLocationStatus {
        servicesEnabled ? status : .servicesDisabled
    }
}

/// Ce que fait le bouton.
public enum WifiLocationAction: String, Sendable {
    /// Demande l'autorisation (fenêtre de macOS).
    case request
    /// Ouvre Réglages Système › Confidentialité et sécurité › Service de localisation.
    case openSettings
    /// Relit la connexion et relance l'analyse pour obtenir les noms.
    case refresh
}

/// Bouton et message à afficher pour un état donné.
public struct WifiLocationGuidance: Equatable, Sendable {
    public var buttonTitle: String
    public var message: String
    public var action: WifiLocationAction
    /// Le message signale un blocage (couleur d'alerte).
    public var isWarning: Bool

    /// Adresse du volet « Service de localisation » des Réglages Système.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"

    /// Délai après lequel une demande sans réponse est considérée comme sans fenêtre.
    public static let promptTimeout: TimeInterval = 8

    /// - Parameters:
    ///   - status: état actuel.
    ///   - requestPending: une demande vient d'être faite et attend la réponse.
    ///   - requestUnanswered: la demande n'a rien donné après `promptTimeout` (aucune fenêtre).
    public static func make(status: WifiLocationStatus, requestPending: Bool = false,
                            requestUnanswered: Bool = false) -> WifiLocationGuidance {
        let nbsp = "\u{00A0}"
        switch status {
        case .servicesDisabled:
            return WifiLocationGuidance(
                buttonTitle: "Ouvrir les réglages de localisation",
                message: "Le service de localisation est désactivé dans macOS. Activez-le dans Réglages Système › Confidentialité et sécurité › Service de localisation, puis autorisez NetScope.",
                action: .openSettings, isWarning: true)
        case .notDetermined where requestUnanswered:
            return WifiLocationGuidance(
                buttonTitle: "Ouvrir les réglages de localisation",
                message: "Aucune fenêtre de macOS n’est apparue. Autorisez NetScope dans Réglages Système › Confidentialité et sécurité › Service de localisation\(nbsp); NetScope doit être lancé depuis le dossier Applications.",
                action: .openSettings, isWarning: true)
        case .notDetermined where requestPending:
            return WifiLocationGuidance(
                buttonTitle: "Autoriser la localisation",
                message: "Demande envoyée à macOS\(nbsp): répondez « Autoriser » dans la fenêtre qui s’affiche.",
                action: .request, isWarning: false)
        case .notDetermined:
            return WifiLocationGuidance(
                buttonTitle: "Autoriser la localisation",
                message: "macOS affichera une fenêtre d’autorisation. NetScope ne s’en sert que pour lire le nom des réseaux Wi-Fi.",
                action: .request, isWarning: false)
        case .denied:
            return WifiLocationGuidance(
                buttonTitle: "Ouvrir les réglages de localisation",
                message: "Accès refusé. macOS ne redemande plus\(nbsp): cochez NetScope dans Réglages Système › Confidentialité et sécurité › Service de localisation.",
                action: .openSettings, isWarning: true)
        case .restricted:
            return WifiLocationGuidance(
                buttonTitle: "Ouvrir les réglages de localisation",
                message: "Localisation restreinte sur ce Mac (profil de gestion ou contrôle parental). Voyez avec l’administrateur, ou vérifiez Réglages Système › Confidentialité et sécurité › Service de localisation.",
                action: .openSettings, isWarning: true)
        case .authorized:
            return WifiLocationGuidance(
                buttonTitle: "Actualiser les noms",
                message: "Localisation autorisée. Si les noms restent masqués, actualisez la lecture des réseaux.",
                action: .refresh, isWarning: false)
        }
    }
}
