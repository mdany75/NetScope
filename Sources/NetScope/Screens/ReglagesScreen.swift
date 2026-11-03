import NetScopeCore
import SwiftUI

/// Écran `Screen.reglages`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct ReglagesScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .reglages,
            summary: "Règle NetScope : sites et plages, profils de scan, identifiants SNMP/SSH/WMI, switchs interrogés, notifications, mises à jour.",
            features: [
                "Général",
                "Sites et plages, plages exclues, détection au branchement",
                "Profils de scan et profil personnalisé",
                "Identifiants (SNMP, SSH, WMI) dans le trousseau",
                "Switchs interrogés",
                "Notifications : canaux, seuils et plages horaires",
                "Interface réseau",
                "Export et sauvegarde",
                "Mises à jour",
                "Raccourcis clavier",
                "À propos et composants tiers",
            ]
        )
    }
}
