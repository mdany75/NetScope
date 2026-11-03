import NetScopeCore
import SwiftUI

/// Écran `Screen.wifi`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct WifiScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .wifi,
            summary: "Analyse l’environnement Wi-Fi : connexion actuelle, occupation des canaux, réseaux visibles et recommandations.",
            features: [
                "Connexion actuelle : SSID, BSSID, canal, RSSI, bruit, débit",
                "Occupation des canaux 2,4 GHz, 5 GHz et 6 GHz",
                "Réseaux visibles avec sécurité et signal",
                "Recommandations de canal",
                "RSSI des 2 dernières minutes",
                "Relevé de couverture",
            ]
        )
    }
}
