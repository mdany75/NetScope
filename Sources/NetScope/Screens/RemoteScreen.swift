import NetScopeCore
import SwiftUI

/// Écran `Screen.acces`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct RemoteScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .acces,
            summary: "Ouvre des connexions vers les appareils : Terminal, SSH, Telnet, RDP, VNC, avec connexions enregistrées et import depuis le scan.",
            features: [
                "Connexions enregistrées",
                "Nouvelle connexion (protocole, hôte, port, identifiant)",
                "Authentification et empreinte de la clé d’hôte",
                "Tunnels et redirections de ports",
                "Importer des hôtes depuis le scan",
            ]
        )
    }
}
