import NetScopeCore
import SwiftUI

/// Écran `Screen.rapports`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct RapportScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .rapports,
            summary: "Produit un rapport client en PDF (ou autre format) à partir des scans : résumé, plan, switchs, Wi-Fi, sécurité, problèmes, inventaire.",
            features: [
                "Choix du modèle de rapport",
                "Sections à inclure",
                "Format de sortie (PDF, HTML, CSV)",
                "Rapports récents",
                "Aperçu du rapport",
            ]
        )
    }
}
