import Foundation

// Navigation entre les modules (notes 31, 33 et 34) : où mène un double-clic, ce que propose
// « Ouvrir dans › », et l'historique Retour / Avancer. Le moteur ne connaît ni SwiftUI ni les
// écrans : il parle de modules (mêmes identifiants que `Screen` dans l'app), d'objets et de
// destinations ; l'app applique la destination (écran, sélection, filtre, sites).

/// Modules de NetScope, dans l'ordre de la barre latérale (mêmes identifiants que `Screen`).
public enum NavModule: String, CaseIterable, Codable, Hashable, Sendable {
    case scanner, carte, inventaire, appareil
    case ping, switchs, wifi, outils
    case surveillance, analyse, rapports
    case acces, speedtest
    case reglages

    /// Libellé du module (barre latérale, menu « Ouvrir dans › »).
    public var title: String {
        switch self {
        case .scanner: return "Scanner"
        case .carte: return "Carte du réseau"
        case .inventaire: return "Inventaire"
        case .appareil: return "Fiche de l’appareil"
        case .ping: return "Ping continu"
        case .switchs: return "Switchs et ports"
        case .wifi: return "Wi-Fi"
        case .outils: return "Outils"
        case .surveillance: return "Surveillance"
        case .analyse: return "Analyse"
        case .rapports: return "Rapports"
        case .acces: return "Accès distant"
        case .speedtest: return "Speedtest"
        case .reglages: return "Réglages"
        }
    }

    /// Chiffre du raccourci ⌥⌘ du menu « Ouvrir dans › » (rang dans la barre latérale, comme ⌘1 à
    /// ⌘9 pour les écrans) ; nil au-delà du neuvième (Analyse : ⌥⌘0).
    public var shortcutDigit: String? {
        if self == .analyse { return "0" }
        guard let index = NavModule.allCases.firstIndex(of: self), index < 9 else { return nil }
        return String(index + 1)
    }
}

/// Ce qui est montré dans l'écran d'arrivée : l'appareil, le port, la borne, la sonde…
public enum NavFocus: Hashable, Sendable {
    /// Appareil du Scanner (Device.id, son IP) : fiche Appareil, ligne du Scanner, nœud de la Carte.
    case device(String)
    /// Fiche d'inventaire d'un site (clé `InventoryStore.key`) : fiche et chronologie.
    case record(site: String, key: String)
    /// Switch (adresse de gestion) et, si connu, un port (nom d'interface, « 1/14 », « port3 »).
    case switchPort(host: String, port: String?)
    /// Borne FortiAP (`FortiManagedAP.id`).
    case accessPoint(String)
    /// Note 46 : client Wi-Fi (`FortiWifiClient.id`, « site|mac ») : sa fiche dans Wi-Fi › FortiAP.
    case wifiClient(String)
    /// Note 46 : SSID d'un site (`FortiWifiSSIDGroup.id`, « site|SSID ») : clients par SSID, ce SSID déplié.
    case wifiSSID(String)
    /// Sonde de surveillance (UUID en texte).
    case probe(String)
    /// Connexion enregistrée de l'Accès distant (UUID en texte).
    case remote(String)
    /// Outil de la boîte à outils (`ToolKind.rawValue`).
    case tool(String)
    /// Service en ligne surveillé (identifiant du catalogue).
    case service(String)
    /// Sauvegarde de Réglages › Export et sauvegarde (nom du fichier).
    case backup(String)
    /// Nœud de la Carte (identifiant `TopoNode.id`).
    case node(String)
    /// Cible ajoutée au ping continu.
    case pingTarget(String)
}

/// Un appareil dans un filtre transmis : par sa MAC quand on la connaît (l'appareil reste le même
/// si son IP change), sinon par son adresse IP.
public struct NavMember: Hashable, Sendable, Codable {
    public var ip: String
    /// MAC normalisée (« 94:DD:F8:18:15:7D ») ; nil : appareil connu par son IP seulement.
    public var mac: String?

    public init(ip: String, mac: String? = nil) {
        self.ip = ip
        self.mac = mac.flatMap(MACAddress.init).map { $0.formatted(.upperColon) } ?? mac?.uppercased()
    }
}

/// Filtre transmis d'un écran à l'autre (Carte → Inventaire, port → Inventaire) : un ensemble
/// EXACT d'appareils, affiché comme une étiquette retirable de la recherche multiple (« Carte :
/// Téléphones ×11 · SW-ETG2-01 »). Ce n'est pas une recherche textuelle : « ip:10.0.0.1 » trouverait
/// 10.0.0.10, et un groupe de la Carte n'a pas de critère commun qu'une recherche saurait écrire.
public struct NavFilter: Hashable, Sendable, Codable {
    public enum Origin: String, Codable, Sendable {
        /// Groupe ou branche de la Carte.
        case carte
        /// Port d'un switch (plusieurs appareils derrière un même port).
        case port
    }

    public var origin: Origin
    /// Texte de l'étiquette : « Carte : Téléphones ×11 · SW-ETG2-01 », « Port : SW-ETG2-01 · 1/14 ».
    public var label: String
    public var members: [NavMember]
    /// Site des appareils (clé `SiteFiles.key`) : une ligne d'un autre site ne correspond jamais,
    /// même à IP égale. nil : n'importe quel site.
    public var siteKey: String?

    public init(origin: Origin, label: String, members: [NavMember], siteKey: String? = nil) {
        self.origin = origin
        self.label = label
        self.members = members
        self.siteKey = siteKey
    }

    /// Préfixe de l'étiquette (« Carte », « Port ») et sa valeur, pour l'afficher comme les autres critères.
    public var prefix: String {
        switch origin {
        case .carte: return "Carte"
        case .port: return "Port"
        }
    }

    /// Valeur de l'étiquette, sans le préfixe : « Téléphones ×11 · SW-ETG2-01 ».
    public var value: String {
        let head = prefix + "\u{00A0}: "
        return label.hasPrefix(head) ? String(label.dropFirst(head.count)) : label
    }

    public var count: Int { members.count }

    private var macs: Set<String> { Set(members.compactMap(\.mac)) }
    private var ipsWithoutMAC: Set<String> { Set(members.filter { $0.mac == nil }.map(\.ip)) }

    /// Vrai si l'appareil fait partie du filtre : même MAC qu'un membre connu par sa MAC, ou même
    /// IP qu'un membre connu par son IP seulement ; jamais une ligne d'un autre site.
    public func matches(ip: String, mac: MACAddress?, site: String? = nil) -> Bool {
        if let siteKey, let site, site != siteKey { return false }
        if let mac, macs.contains(mac.formatted(.upperColon)) { return true }
        return ipsWithoutMAC.contains(ip)
    }

    public func matches(_ device: Device, site: String? = nil) -> Bool {
        matches(ip: device.ip.description, mac: device.mac, site: site)
    }

    public func matches(_ record: InvRecord, site: String? = nil) -> Bool {
        matches(ip: record.ip.description, mac: record.mac, site: site)
    }

    /// Bulle d'aide de l'étiquette.
    public var help: String {
        let what: String
        switch origin {
        case .carte: what = "Appareils du groupe choisi sur la Carte du réseau"
        case .port: what = "Appareils vus derrière ce port de switch"
        }
        return "\(what) (\(count) appareil\(count > 1 ? "s" : "")). Cliquez sur × pour retirer ce filtre."
    }
}

/// Sites affichés par l'écran d'arrivée (Inventaire, Carte, Analyse, Rapports).
public enum NavSites: Hashable, Sendable {
    /// Ajoute ce site à ceux déjà affichés (pour cette session) : l'objet vient de ce site.
    case include(String)
    /// N'affiche que ces sites (ex. double-clic sur un site).
    case only([String])

    /// Site ajouté par `.include`, s'il y en a un.
    public var includedKey: String? {
        if case .include(let key) = self { return key }
        return nil
    }

    /// Site de l'objet : celui ajouté par `.include`, sinon le seul site de `.only` (note 48).
    public var siteKey: String? {
        switch self {
        case .include(let key): return key
        case .only(let keys): return keys.count == 1 ? keys[0] : nil
        }
    }
}

/// Où mène une action : un module, ce qui y est montré, un filtre transmis, une recherche et les sites.
public struct NavDestination: Hashable, Sendable {
    public var module: NavModule
    public var focus: NavFocus?
    /// Filtre transmis (ensemble exact d'appareils) ; remplace celui de l'écran d'arrivée.
    public var filter: NavFilter?
    /// Recherche posée sur l'écran d'arrivée (« vlan:30 ») ; nil : celle de l'écran ne change pas.
    public var search: String?
    public var sites: NavSites?

    public init(_ module: NavModule, focus: NavFocus? = nil, filter: NavFilter? = nil, search: String? = nil,
                sites: NavSites? = nil) {
        self.module = module
        self.focus = focus
        self.filter = filter
        self.search = search
        self.sites = sites
    }
}

/// Un choix proposé quand un double-clic a plusieurs suites (plusieurs appareils sur un port).
public struct NavOption: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    /// nil : élément montré pour information (appareil pas encore vu), non cliquable.
    public var destination: NavDestination?

    public init(id: String, title: String, detail: String, destination: NavDestination?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.destination = destination
    }
}

/// Résultat d'un double-clic (ou de ↩︎).
public enum NavOutcome: Hashable, Sendable {
    /// Une seule suite logique : y aller.
    case go(NavDestination)
    /// Plusieurs suites : petite liste à choisir, et une suite commune (Inventaire filtré).
    case choose(title: String, message: String, options: [NavOption], all: NavOption?)
    /// Rien à ouvrir : message clair, avec éventuellement une suite proposée.
    case message(title: String, text: String, suggestion: NavOption?)

    /// Destination directe, s'il y en a une.
    public var destination: NavDestination? {
        if case .go(let destination) = self { return destination }
        return nil
    }
}

/// Entrée du menu « Ouvrir dans › » : un module et ce qu'il montrera de l'objet.
public struct NavMenuItem: Hashable, Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var destination: NavDestination
    /// Chiffre du raccourci ⌥⌘ (celui du module).
    public var shortcutDigit: String? { destination.module.shortcutDigit }

    public init(_ title: String, _ destination: NavDestination) {
        self.title = title
        self.destination = destination
    }
}

/// Un endroit de l'app, pour Retour / Avancer : écran, recherche, filtre transmis, sélection et sites.
public struct NavLocation: Hashable, Sendable {
    public var module: NavModule
    public var search: String
    public var filter: NavFilter?
    /// Appareil choisi (Scanner, fiche Appareil).
    public var deviceID: String?
    /// Sites affichés par l'écran (Inventaire, Carte, Analyse, Rapports) ; nil pour les autres.
    public var sites: SiteSelection?
    /// Ce qui était montré (port du switch, fiche d'inventaire, borne…).
    public var focus: NavFocus?

    public init(_ module: NavModule, search: String = "", filter: NavFilter? = nil, deviceID: String? = nil,
                sites: SiteSelection? = nil, focus: NavFocus? = nil) {
        self.module = module
        self.search = search
        self.filter = filter
        self.deviceID = deviceID
        self.sites = sites
        self.focus = focus
    }
}
