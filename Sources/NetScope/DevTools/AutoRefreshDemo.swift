import Foundation
import NetScopeCore

/// Démonstration de la note 29 (relecture automatique). Aucun accès réseau : rien n'est relu,
/// l'indication « Relu il y a 2 min · prochaine dans 3 min » tourne toute seule à partir du
/// lancement (relecture fictive toutes les 5 min pour le Siège).
///
/// Intervalles des sites de démonstration : Siège 5 min, Entrepôt Laval 10 min, Bureau Québec
/// désactivée (son jeton manque), Usine Drummondville 15 min ; les autres prennent la valeur par
/// défaut (5 min).
@MainActor
enum AutoRefreshDemo {
    static let intervalsByName: [String: AutoRefreshInterval] = [
        "Siège": .five,
        "Entrepôt Laval": .ten,
        "Bureau Québec": .off,
        "Usine Drummondville": .fifteen,
    ]

    /// Dernière relecture fictive : 2 min avant le premier affichage.
    private static let origin = Date().addingTimeInterval(-120)

    static func interval(forSiteKey key: String) -> AutoRefreshInterval? {
        guard let name = SiteModel.shared.site(forKey: key)?.displayName else { return nil }
        return intervalsByName[name]
    }

    /// « Relu il y a 2 min · prochaine dans 3 min », puis la même chose à chaque tour fictif.
    static func status(interval: AutoRefreshInterval, now: Date) -> String {
        // `origin` est fixé au premier appel : l'heure reçue peut le précéder de peu.
        let now = max(now, origin.addingTimeInterval(120))
        guard interval.isOn else {
            return AutoRefreshText.status(lastRead: origin, decision: .paused(.disabled), reading: false, now: now)
        }
        let period = interval.seconds
        let turns = max(0, (now.timeIntervalSince(origin) / period).rounded(.down))
        let last = origin.addingTimeInterval(turns * period)
        return AutoRefreshText.status(lastRead: last, decision: .wait(until: last.addingTimeInterval(period), retrying: false, failures: 0),
                                      reading: false, now: now)
    }
}
