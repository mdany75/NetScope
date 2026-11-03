import NetScopeCore
import SwiftUI

/// Écran `Screen.switchs`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct SwitchScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .switchs,
            summary: "Interroge les switchs (SNMP, LLDP/CDP) pour voir l’état de chaque port, le VLAN, la PoE et l’appareil branché.",
            features: [
                "Liste des switchs interrogés",
                "Façade du switch : ports colorés selon l’état",
                "Détail d’un port : vitesse, VLAN, PoE, erreurs, adresses MAC apprises",
                "Voisins LLDP/CDP",
                "Recherche « sur quel port est cet appareil ? »",
            ]
        )
    }
}
