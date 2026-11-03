import NetScopeCore
import SwiftUI

/// Écran `Screen.scanner`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct ScannerScreen: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        UnderConstructionView(
            screen: .scanner,
            summary: "Découvre les appareils de plusieurs plages à la fois (CIDR, début-fin, listes), avec un profil de scan au choix, et affiche les résultats en direct avec le détail de l’appareil sélectionné.",
            features: [
                "Plages à scanner : cartes cochables avec VLAN, progression, en ligne et nouveaux",
                "Bouton « Détecter mon réseau » et ajout d’une plage (CIDR, début-fin, liste)",
                "Profils : Rapide, Complet, Ports courants, Personnalisé",
                "Résultats du scan : filtres rapides (tous, en ligne, nouveaux, conflits) et par plage ou VLAN",
                "Tableau : IP, nom personnalisé, hostname, fabricant, MAC, latence, ports, switch et port, VLAN, vu",
                "Panneau de détail : emplacement physique, latence des 30 derniers pings, ports ouverts",
                "Actions rapides : ping continu, traceroute, scan de ports, Wake-on-LAN, SSH, copier IP ou MAC",
                "Export des résultats (CSV, JSON, PDF)",
            ]
        )
        .screenToolbar {
            Button {} label: { Label("Lancer le scan", systemImage: "play.fill") }
                .buttonStyle(.primary)
                .disabled(true)
            Button {} label: { Label("Profil : \(state.scanProfile.label)", systemImage: "slider.horizontal.3") }
                .buttonStyle(.secondary)
                .disabled(true)
            Button {} label: { Label("Exporter", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
                .disabled(true)
        }
    }
}
