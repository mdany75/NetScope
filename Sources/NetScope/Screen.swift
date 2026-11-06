import Foundation
import NetScopeCore

/// Les écrans de l'application, dans l'ordre de la barre latérale.
enum Screen: String, CaseIterable, Identifiable, Codable {
    case scanner, carte, inventaire, appareil
    case ping, switchs, wifi, outils
    /// Note 54 : « Trafic » (FortiView et bilan de santé), entre Surveillance et Historique et adressage.
    /// Note 79 : `analyse` garde son identifiant (liens, réglages, captures) ; seul le nom change.
    /// Note 43 : « Journaux » (Syslog, traps SNMP, journaux de la FortiGate), après Surveillance.
    case surveillance, journaux, trafic, analyse, rapports
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
        case .journaux: return "Journaux"
        case .analyse: return "Historique et adressage"
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
        case .analyse: return "Historique et adressage"
        case .trafic: return "Trafic et bilan de santé"
        case .journaux: return "Journaux et traps"
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
        case .journaux: return "list.bullet.rectangle.portrait"
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
        case .surveillance, .journaux, .trafic, .analyse, .rapports: return .suivi
        case .acces: return .acces
        // Speedtest est un outil de la Boîte à outils : hors de la barre latérale.
        case .speedtest, .reglages: return nil
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
        // Pas de croquis propre : disposition de la Surveillance (journal des alertes) et du Trafic.
        case .journaux: return "Surveillance.dc.html"
        case .rapports: return "Rapport.dc.html"
        case .acces: return "Remote.dc.html"
        case .speedtest: return "Speedtest.dc.html"
        case .reglages: return "Reglages.dc.html"
        }
    }

    /// Note 79 : anciens noms de l'écran, gardés pour la recherche (on retrouve « Analyse »).
    var formerTitles: [String] { NavModule(rawValue: rawValue)?.formerTitles ?? [] }

    /// Noms de tous les écrans, actuels et anciens, pour la recherche des réglages (Raccourcis).
    static var searchNames: String {
        allCases.flatMap { [$0.title, $0.pageTitle] + $0.formerTitles }.joined(separator: " ")
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

        /// Écrans de la section, en ordre alphabétique (demande de Dany, 5 novembre 2026), sauf le
        /// Scanner, écran principal, gardé en tête de Découverte (Dany, 6 novembre 2026) ; les
        /// sections gardent leur ordre et les raccourcis suivent l'écran, pas sa position.
        var screens: [Screen] {
            Screen.allCases.filter { $0.group == self }.sortedFrench(by: \.title, first: [Screen.scanner.title])
        }
    }
}
