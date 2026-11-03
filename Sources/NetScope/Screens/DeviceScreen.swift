import NetScopeCore
import SwiftUI

/// Écran `Screen.appareil`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct DeviceScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .appareil,
            summary: "Fiche complète d’un appareil : identité réseau, matériel, emplacement physique, ports, données SNMP et chronologie.",
            features: [
                "Réseau : IP, MAC, fabricant, nom d’hôte, VLAN",
                "Matériel et détection du système ou du type",
                "Emplacement physique : switch et port",
                "Disponibilité et latence",
                "Ports ouverts et services",
                "Système (MIB-II), consommables (Printer-MIB), ifTable",
                "Chronologie de l’appareil",
            ]
        )
    }
}
