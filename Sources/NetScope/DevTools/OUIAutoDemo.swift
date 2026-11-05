import Foundation
import NetScopeCore

/// Note 81 : mise à jour automatique de la base des fabricants en démonstration (`--demo`) :
/// dernière vérification fictive, jamais de téléchargement.
enum OUIAutoDemo {
    static var settings: OUIAutoUpdateSettings {
        guard Launcher.isDemo else { return OUIAutoUpdateSettings() }
        let checked = Date().addingTimeInterval(-(2 * 86_400 + 5 * 3_600))
        return OUIAutoUpdateSettings(isEnabled: true, lastCheck: checked, lastUpdate: checked,
                                     lastOutcome: .updated(added: 312, total: 55_418))
    }
}
