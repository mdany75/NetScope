import Foundation

// Note 83 : l'écran Switchs et ports divisé en onglets (comme Wi-Fi › FortiAP, note 80). Sous le
// bandeau du site et les tuiles de résumé : Switchs (cartes, façade, interrogation), Ports
// (tableau des ports, erreurs récentes, PoE, détail et actions du port), Trafic (ports les plus
// chargés, trafic et historique du port), Appareils (table MAC, VLAN) et Voisins et liens (LLDP,
// uplinks, topologie, ce Mac). Ce fichier ne contient que les règles, testées sans réseau.

/// Onglet de l'écran Switchs et ports.
public enum SwitchPageTab: String, CaseIterable, Sendable, Codable {
    case switchs, ports, trafic, appareils, voisins
    /// Note 40 (0.31.0) : sauvegarde et historique des configurations du site.
    case configurations

    public var label: String {
        switch self {
        case .switchs: return "Switchs"
        case .ports: return "Ports"
        case .trafic: return "Trafic"
        case .appareils: return "Appareils"
        case .voisins: return "Voisins et liens"
        case .configurations: return "Configurations"
        }
    }

    /// Symbole SF de l'onglet (menu des onglets en petite fenêtre).
    public var symbol: String {
        switch self {
        case .switchs: return "rectangle.connected.to.line.below"
        case .ports: return "square.grid.3x2"
        case .trafic: return "chart.xyaxis.line"
        case .appareils: return "laptopcomputer.and.iphone"
        case .voisins: return "point.3.connected.trianglepath.dotted"
        case .configurations: return "doc.badge.clock"
        }
    }

    /// Phrase d'aide de l'onglet (infobulle).
    public var hint: String {
        switch self {
        case .switchs: return "Cartes des switchs, façade du switch choisi, recherche d’un appareil et interrogation SNMP ou FortiGate"
        case .ports: return "Tous les ports du switch choisi\u{00A0}: état, vitesse, VLAN, PoE, erreurs récentes, détail et actions du port"
        case .trafic: return "Ports les plus chargés, trafic en direct et historique du port choisi"
        case .appareils: return "Table MAC du switch choisi et appareils par VLAN"
        case .voisins: return "Voisins LLDP, liens entre switchs, uplinks et ce Mac"
        case .configurations: return "Sauvegarde des configurations de la FortiGate et des switchs du site, historique et comparaison avant/après"
        }
    }

    /// Onglet qui montre un seul switch : la barre des onglets propose alors le choix du switch.
    public var isPerSwitch: Bool { self == .ports || self == .trafic || self == .appareils }

    /// Libellé de l'onglet avec son compteur (« Ports (2 en erreur) », « Voisins et liens (19) »).
    public func title(badge: Int?) -> String {
        guard let badge, badge > 0 else { return label }
        switch self {
        case .ports: return "\(label) (\(badge) en erreur)"
        case .configurations: return "\(label) (\(badge) modifiée\(badge > 1 ? "s" : ""))"
        default: return "\(label) (\(badge))"
        }
    }

    /// Onglet d'arrivée quand on montre un switch depuis un autre écran (fiche Appareil, Carte,
    /// « Ouvrir dans › », Retour) : le port demandé s'ouvre dans Ports, le switch seul dans Switchs.
    public static func arrival(port: String?) -> SwitchPageTab {
        guard let port, !port.trimmingCharacters(in: .whitespaces).isEmpty else { return .switchs }
        return .ports
    }

    /// Captures (NETSCOPE_SWITCH_ONGLET) et liens : nom de l'onglet, avec quelques synonymes.
    public init?(capture text: String) {
        let folded = text.trimmingCharacters(in: .whitespaces).lowercased()
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
        switch folded {
        case "switchs", "switch", "switches", "cartes", "facade": self = .switchs
        case "ports", "port": self = .ports
        case "trafic", "traffic", "historique", "charge": self = .trafic
        case "appareils", "appareil", "mac", "table-mac", "vlan", "vlans": self = .appareils
        case "voisins", "voisins-et-liens", "liens", "lldp", "topologie", "uplinks": self = .voisins
        case "configurations", "configuration", "config", "configs", "sauvegarde", "sauvegardes": self = .configurations
        default: return nil
        }
    }
}
