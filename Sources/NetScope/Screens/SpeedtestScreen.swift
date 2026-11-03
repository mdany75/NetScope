import NetScopeCore
import SwiftUI

/// Écran `Screen.speedtest`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct SpeedtestScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .speedtest,
            summary: "Mesure le débit Internet et le débit local (iperf3), compare au forfait et garde l’historique.",
            features: [
                "Débit Internet : descendant, montant, latence, gigue",
                "Serveur de test",
                "Votre connexion et comparaison au forfait",
                "Test iperf3 vers un serveur local",
                "Filaire contre Wi-Fi",
                "Chemin mesuré",
                "Évolution sur 30 jours et tests enregistrés",
            ]
        )
    }
}
