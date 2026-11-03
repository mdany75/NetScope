import NetScopeCore
import SwiftUI

/// Écran `Screen.ping`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct PingScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .ping,
            summary: "Ping continu de plusieurs cibles en parallèle, avec graphique de latence, pertes, et MTR / traceroute de la cible choisie.",
            features: [
                "Liste des cibles avec état, latence moyenne et pertes",
                "Graphique de latence de la cible sélectionnée",
                "MTR / traceroute : sauts, latence et pertes par saut",
                "Journal des événements (perte, retour, pic de latence)",
                "Cibles reçues des autres écrans (« Ping continu » sur un appareil)",
            ]
        )
    }
}
