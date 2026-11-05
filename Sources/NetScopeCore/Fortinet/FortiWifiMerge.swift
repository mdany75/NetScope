import Foundation

// Note 27 : fusion des lectures Wi-Fi de plusieurs FortiGate (une par site) et rattachement des
// clients Wi-Fi aux appareils du Scanner. Fonctions pures.

/// Wi-Fi de tous les sites lus, chaque élément marqué de son site.
public struct FortiWifiOverview: Hashable, Sendable {
    public var aps: [FortiManagedAP]
    public var clients: [FortiWifiClient]
    public var ssids: [FortiSSID]
    public var rogues: [FortiRogueAP]
    /// Sites lus, dans l'ordre.
    public var sites: [String]
    /// Explications par site (« Siège · Clients Wi-Fi : accès refusé… »).
    public var notes: [String]
    public var readAt: Date?

    public init(aps: [FortiManagedAP] = [], clients: [FortiWifiClient] = [], ssids: [FortiSSID] = [], rogues: [FortiRogueAP] = [],
                sites: [String] = [], notes: [String] = [], readAt: Date? = nil) {
        self.aps = aps
        self.clients = clients
        self.ssids = ssids
        self.rogues = rogues
        self.sites = sites
        self.notes = notes
        self.readAt = readAt
    }

    public var isEmpty: Bool { aps.isEmpty && clients.isEmpty }
    public var onlineAPs: [FortiManagedAP] { aps.filter { !$0.isOffline } }
    public var offlineAPs: [FortiManagedAP] { aps.filter(\.isOffline) }
    /// Plusieurs sites : les tableaux montrent la colonne « Site ».
    public var isMultiSite: Bool { sites.count > 1 }

    /// Client Wi-Fi de cette MAC (le plus récent site d'abord, dans l'ordre des sites).
    public func client(mac: MACAddress) -> FortiWifiClient? { clients.first { $0.mac == mac } }

    /// Borne d'un client (même site, par nom, identifiant ou série).
    public func ap(for client: FortiWifiClient) -> FortiManagedAP? {
        let keys = [client.apName, client.apKey].compactMap { $0?.lowercased() }
        return aps.first { $0.site == client.site && !$0.keys.isDisjoint(with: keys) }
    }

    /// Clients d'une borne.
    public func clients(of ap: FortiManagedAP) -> [FortiWifiClient] {
        clients.filter { $0.site == ap.site && !ap.keys.isDisjoint(with: [$0.apName, $0.apKey].compactMap { $0?.lowercased() }) }
    }

    /// SSID diffusés (distincts par nom, tous sites confondus).
    public var distinctSSIDs: [String] {
        var seen = Set<String>()
        return ssids.map(\.ssid).filter { seen.insert($0).inserted }
    }
}

/// Remarques de lecture : anomalies (réponse illisible, droit refusé, erreur, clients annoncés
/// absents de la liste) à mettre en avant, ou simples absences d'une adresse selon la version.
public enum FortiWifiNotes {
    public static func isAnomaly(_ note: String) -> Bool {
        !["adresse absente", "Contrôleur Wi-Fi absent", "aucun contrôleur Wi-Fi"].contains { note.contains($0) }
    }

    /// Sans doublon, dans l'ordre (un site à deux FortiGate peut donner deux fois la même).
    public static func unique(_ notes: [String]) -> [String] {
        var seen = Set<String>()
        return notes.filter { seen.insert($0).inserted }
    }
}

public enum FortiWifiMerge {
    /// Remplace l'identifiant WTP d'un client par le nom de sa borne quand il est connu.
    public static func resolveAPNames(_ clients: [FortiWifiClient], aps: [FortiManagedAP]) -> [FortiWifiClient] {
        clients.map { client in
            var c = client
            let keys = [client.apName, client.apKey].compactMap { $0?.lowercased() }
            if let ap = aps.first(where: { !$0.keys.isDisjoint(with: keys) }) {
                c.apName = ap.name
                if c.apKey == nil { c.apKey = ap.wtpID }
                // Bande et canal manquants : ceux de la radio de la borne.
                if c.channel == nil || c.band == nil, let id = c.radioID, let radio = ap.radios.first(where: { $0.radioID == id }) {
                    if c.channel == nil { c.channel = radio.channel }
                    if c.band == nil { c.band = radio.band }
                }
            }
            return c
        }
    }

    /// Lectures de plusieurs sites fusionnées : chaque élément porte son site. Une MAC cliente
    /// vue sur deux sites (impossible en pratique, sauf relevé périmé) garde la première.
    public static func overview(_ sites: [FortiWifiSiteReport]) -> FortiWifiOverview {
        var result = FortiWifiOverview()
        var macs = Set<MACAddress>()
        for site in sites {
            let label = site.site.trimmingCharacters(in: .whitespacesAndNewlines)
            result.sites.append(label)
            let r = site.report
            result.aps += r.aps.map { var a = $0; a.site = label; return a }
            for client in r.clients where macs.insert(client.mac).inserted {
                var c = client
                c.site = label
                result.clients.append(c)
            }
            result.ssids += r.ssids.map { var s = $0; s.site = label; return s }
            result.rogues += r.rogues.map { var x = $0; x.site = label; return x }
            result.notes += r.notes.map { "\(label) · \($0)" }
            // La note 404 du relecteur le dit déjà : pas de seconde phrase identique.
            if !r.available, r.notes.isEmpty { result.notes.append("\(label) · aucun contrôleur Wi-Fi sur cette FortiGate.") }
            result.readAt = max(result.readAt ?? r.readAt, r.readAt)
        }
        return result
    }

    /// Client Wi-Fi de chaque appareil du Scanner : par MAC, sinon par adresse IP quand un seul
    /// client a cette adresse (appareil sans MAC connue, derrière un routeur).
    public static func match(_ devices: [Device], overview: FortiWifiOverview) -> [Device.ID: FortiWifiClient] {
        var byMAC: [MACAddress: FortiWifiClient] = [:]
        for client in overview.clients where byMAC[client.mac] == nil { byMAC[client.mac] = client }
        var byIP: [IPv4Address: [FortiWifiClient]] = [:]
        for client in overview.clients { if let ip = client.ip { byIP[ip, default: []].append(client) } }
        var result: [Device.ID: FortiWifiClient] = [:]
        for device in devices {
            if let mac = device.mac {
                if let client = byMAC[mac] { result[device.id] = client }
            } else if let list = byIP[device.ip], list.count == 1 {
                result[device.id] = list[0]
            }
        }
        return result
    }
}
