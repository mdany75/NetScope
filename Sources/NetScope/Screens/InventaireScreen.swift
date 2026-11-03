import NetScopeCore
import SwiftUI

/// Écran `Screen.inventaire`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct InventaireScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .inventaire,
            summary: "Garde la liste de tous les appareils déjà vus, avec leur historique : changements d’IP, de port de switch, de nom.",
            features: [
                "Tableau des appareils connus, filtrable et triable",
                "Doublons probables (même MAC, même nom)",
                "Chronologie des changements de l’appareil sélectionné",
                "Historique des IP",
                "Historique des ports de switch",
                "Noms personnalisés, notes et étiquettes",
            ]
        )
    }
}
