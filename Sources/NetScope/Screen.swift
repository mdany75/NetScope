import Foundation

/// Les écrans de l'application, dans l'ordre de la barre latérale.
enum Screen: String, CaseIterable, Identifiable, Codable {
    case scanner, carte, inventaire, appareil
    case ping, switchs, wifi, outils
    /// Note 54 : « Trafic » (FortiView et analyse complète), entre Surveillance et Analyse.
    case surveillance, trafic, analyse, rapports
    case acces, speedtest
    case reglages

    var id: String { rawValue }

    /// Libellé de la barre latérale.
    var title: String {
        switch self {
        case .scanner: return "Scanner"
        case .carte: return "Carte du réseau"
        case .inventaire: return "Inventaire"
        case .appareil: return "Appareil"
        case .ping: return "Ping continu"
        case .switchs: return "Switchs et ports"
        case .wifi: return "Wi-Fi"
        case .outils: return "Outils"
        case .surveillance: return "Surveillance"
        case .trafic: return "Trafic"
        case .analyse: return "Analyse"
        case .rapports: return "Rapports"
        case .acces: return "Accès distant"
        case .speedtest: return "Speedtest"
        case .reglages: return "Réglages"
        }
    }

    /// Titre de la barre d'outils de l'écran (parfois plus long que le libellé latéral).
    var pageTitle: String {
        switch self {
        case .wifi: return "Analyseur Wi-Fi"
        case .outils: return "Boîte à outils"
        case .analyse: return "Analyse et alertes"
        case .trafic: return "Trafic et analyse"
        default: return title
        }
    }

    /// Symbole SF Symbols.
    var symbol: String {
        switch self {
        case .scanner: return "magnifyingglass"
        case .carte: return "point.3.connected.trianglepath.dotted"
        case .inventaire: return "list.bullet"
        case .appareil: return "desktopcomputer"
        case .ping: return "waveform.path.ecg"
        case .switchs: return "rectangle.connected.to.line.below"
        case .wifi: return "wifi"
        case .outils: return "wrench.and.screwdriver"
        case .surveillance: return "eye"
        case .trafic: return "arrow.up.arrow.down.circle"
        case .analyse: return "chart.bar.xaxis"
        case .rapports: return "doc.text"
        case .acces: return "terminal"
        case .speedtest: return "gauge.with.dots.needle.67percent"
        case .reglages: return "gearshape"
        }
    }

    /// Groupe de la barre latérale (nil pour Réglages, placé en bas).
    var group: Group? {
        switch self {
        case .scanner, .carte, .inventaire, .appareil: return .decouverte
        case .ping, .switchs, .wifi, .outils: return .diagnostic
        case .surveillance, .trafic, .analyse, .rapports: return .suivi
        case .acces, .speedtest: return .acces
        case .reglages: return nil
        }
    }

    /// Fichier du croquis correspondant, dans docs/croquis/.
    var sketchFile: String {
        switch self {
        case .scanner: return "Main.dc.html"
        case .carte: return "Topologie.dc.html"
        case .inventaire: return "Inventaire.dc.html"
        case .appareil: return "Device.dc.html"
        case .ping: return "Ping.dc.html"
        case .switchs: return "Switch.dc.html"
        case .wifi: return "Wifi.dc.html"
        case .outils: return "Toolbox.dc.html"
        case .surveillance: return "Surveillance.dc.html"
        case .analyse: return "Analyse.dc.html"
        // Pas de croquis propre : disposition de l'Analyse.
        case .trafic: return "Analyse.dc.html"
        case .rapports: return "Rapport.dc.html"
        case .acces: return "Remote.dc.html"
        case .speedtest: return "Speedtest.dc.html"
        case .reglages: return "Reglages.dc.html"
        }
    }

    enum Group: String, CaseIterable {
        case decouverte, diagnostic, suivi, acces

        var title: String {
            switch self {
            case .decouverte: return "Découverte"
            case .diagnostic: return "Diagnostic"
            case .suivi: return "Suivi"
            case .acces: return "Accès"
            }
        }

        var screens: [Screen] { Screen.allCases.filter { $0.group == self } }
    }
}
