import NetScopeCore
import SwiftUI

/// Écran `Screen.analyse`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct AnalyseScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .analyse,
            summary: "Analyse les scans dans le temps : occupation des plages, appareils en ligne, répartition par fabricant et par type, alertes et comparaison.",
            features: [
                "Carte d’occupation des adresses",
                "Appareils en ligne sur la période",
                "Répartition par fabricant",
                "Répartition par type d’appareil",
                "Alertes et changements (nouveaux appareils, conflits IP)",
                "Comparer deux scans",
            ]
        )
    }
}
