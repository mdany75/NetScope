import NetScopeCore
import SwiftUI

/// Écran `Screen.carte`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct TopologieScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .carte,
            summary: "Dessine la carte du réseau à partir des voisins LLDP/CDP et des tables MAC des switchs : qui est branché où, et par quel uplink.",
            features: [
                "Canevas de la topologie : passerelle, switchs, points d’accès et appareils",
                "Fiche du nœud sélectionné et de ses voisins",
                "Charge des uplinks et des liens (moyenne sur 5 minutes)",
                "Vue d’ensemble pour se repérer dans une grande carte",
                "Problèmes sur la carte : boucles, liens saturés, ports en erreur",
            ]
        )
    }
}
