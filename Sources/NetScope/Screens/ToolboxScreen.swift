import NetScopeCore
import SwiftUI

/// Écran `Screen.outils`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct ToolboxScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .outils,
            summary: "Boîte à outils du technicien : calculateur de sous-réseaux, DNS, Whois, Wake-on-LAN, recherche de fabricant et autres utilitaires.",
            features: [
                "Calculateur de sous-réseaux et découpage",
                "Recherche DNS et DNS inverse",
                "Recherche de fabricant par adresse MAC (OUI)",
                "Wake-on-LAN",
                "Scan de ports d’un hôte",
                "Traceroute, Whois, certificats TLS",
            ]
        )
    }
}
