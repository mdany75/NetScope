import Foundation

// Note 46 : clients Wi-Fi par borne (radio puis SSID) et par SSID, filtres de la section Clients,
// rattachement d'un client à l'appareil du Scanner du BON site. Fonctions pures, sans réseau.
//
// Règle des sites (note 48) : un client appartient au site de la FortiGate qui l'a vu ; deux sites
// ne sont jamais fusionnés, même quand ils ont les mêmes plages et la même MAC.

/// Clients d'un SSID (dans un site).
public struct FortiWifiSSIDGroup: Identifiable, Hashable, Sendable {
    public var id: String { site + "|" + ssid }
    public var site: String
    public var ssid: String
    public var clients: [FortiWifiClient]
    /// Bornes qui servent ces clients (noms, triés).
    public var apNames: [String]
    /// Bandes utilisées par ces clients (ordre 2,4 / 5 / 6 GHz).
    public var bands: [WifiBand]
    /// Configuration du SSID sur la FortiGate, si elle a été lue.
    public var config: FortiSSID?

    public init(site: String, ssid: String, clients: [FortiWifiClient], config: FortiSSID? = nil) {
        self.site = site
        self.ssid = ssid
        self.clients = clients
        self.config = config
        apNames = Array(Set(clients.compactMap(\.apName))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        bands = WifiBand.allCases.filter { band in clients.contains { $0.band == band } }
    }

    public var count: Int { clients.count }

    /// « 2,4 et 5 GHz », « 5 GHz », « — ».
    public var bandsLabel: String {
        guard !bands.isEmpty else { return "—" }
        let names = bands.map { $0.label.replacingOccurrences(of: " GHz", with: "") }
        if names.count == 1 { return bands[0].label.replacingOccurrences(of: " ", with: "\u{00A0}") }
        return names.dropLast().joined(separator: ", ") + " et " + (names.last ?? "") + "\u{00A0}GHz"
    }
}

/// Clients d'une radio d'une borne, regroupés par SSID.
public struct FortiWifiRadioGroup: Identifiable, Hashable, Sendable {
    public var id: String { "\(radioID.map(String.init) ?? "?")|\(band?.rawValue ?? "?")" }
    /// Radio de la borne (nil : clients dont la radio n'est pas connue).
    public var radio: FortiAPRadio?
    public var radioID: Int?
    public var band: WifiBand?
    public var ssids: [FortiWifiSSIDGroup]

    public var count: Int { ssids.reduce(0) { $0 + $1.count } }

    /// « Radio 2 · 5 GHz · canal 44 · 80 MHz », « Radio inconnue ».
    public var title: String {
        var parts: [String] = []
        parts.append(radioID.map { "Radio \($0)" } ?? "Radio inconnue")
        if let radio { parts.append(radio.isServing ? radio.label : (band?.label ?? "") + " · éteinte") }
        else if let band { parts.append(band.label) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Filtres de la section Wi-Fi › Clients (en plus de la recherche par nom, IP ou MAC).
public struct FortiWifiClientFilter: Hashable, Sendable {
    public enum BandChoice: String, CaseIterable, Hashable, Sendable {
        case all, ghz24, ghz5, ghz6
        public var label: String {
            switch self {
            case .all: return "Toutes les bandes"
            case .ghz24: return "2,4\u{00A0}GHz"
            case .ghz5: return "5\u{00A0}GHz"
            case .ghz6: return "6\u{00A0}GHz"
            }
        }
        public var band: WifiBand? {
            switch self {
            case .all: return nil
            case .ghz24: return .ghz24
            case .ghz5: return .ghz5
            case .ghz6: return .ghz6
            }
        }
    }

    /// SSID choisi (nil : tous).
    public var ssid: String?
    /// Borne choisie, par son nom (nil : toutes).
    public var apName: String?
    public var band: BandChoice
    public var weakOnly: Bool

    public init(ssid: String? = nil, apName: String? = nil, band: BandChoice = .all, weakOnly: Bool = false) {
        self.ssid = ssid
        self.apName = apName
        self.band = band
        self.weakOnly = weakOnly
    }

    public var isActive: Bool { ssid != nil || apName != nil || band != .all || weakOnly }

    public func matches(_ client: FortiWifiClient, thresholds: FortiWifiThresholds = .standard) -> Bool {
        if let ssid, client.ssid != ssid { return false }
        if let apName, client.apName?.caseInsensitiveCompare(apName) != .orderedSame { return false }
        if let wanted = band.band, client.band != wanted { return false }
        if weakOnly, !FortiWifiAnalysis.isWeak(client, thresholds: thresholds) { return false }
        return true
    }
}

public enum FortiWifiClientGroups {
    /// Ordre des SSID dans un groupe : le plus de clients d'abord, puis par nom.
    static func ordered(_ groups: [FortiWifiSSIDGroup]) -> [FortiWifiSSIDGroup] {
        groups.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending
        }
    }

    /// Clients d'une borne par radio (2,4 / 5 / 6 GHz) puis par SSID, avec le nombre de clients de
    /// chaque SSID. Les radios qui servent sans client apparaissent (« 0 client ») ; les clients
    /// dont la radio est inconnue sont rangés d'après leur bande, sinon dans « Radio inconnue ».
    public static func byRadio(ap: FortiManagedAP, clients: [FortiWifiClient]) -> [FortiWifiRadioGroup] {
        let mine = clients.filter { c in
            c.site == ap.site && !ap.keys.isDisjoint(with: [c.apName, c.apKey].compactMap { $0?.lowercased() })
        }
        var buckets: [String: (radio: FortiAPRadio?, id: Int?, band: WifiBand?, clients: [FortiWifiClient])] = [:]
        var order: [String] = []
        func key(_ id: Int?, _ band: WifiBand?) -> String { "\(id.map(String.init) ?? "?")|\(band?.rawValue ?? "?")" }
        for radio in ap.radios.sorted(by: { $0.radioID < $1.radioID }) where radio.isServing || (radio.clientCount ?? 0) > 0 {
            let k = key(radio.radioID, radio.band)
            buckets[k] = (radio, radio.radioID, radio.band, [])
            order.append(k)
        }
        for client in mine {
            var radio = client.radioID.flatMap { id in ap.radios.first { $0.radioID == id } }
            if radio == nil, let band = client.band { radio = ap.radios.first { $0.band == band && $0.isServing } }
            let k = radio.map { key($0.radioID, $0.band) } ?? key(nil, client.band)
            if buckets[k] == nil {
                buckets[k] = (radio, radio?.radioID, radio?.band ?? client.band, [])
                order.append(k)
            }
            buckets[k]?.clients.append(client)
        }
        return order.compactMap { k in
            guard let b = buckets[k] else { return nil }
            var bySSID: [String: [FortiWifiClient]] = [:]
            for c in b.clients { bySSID[c.ssid ?? "(SSID inconnu)", default: []].append(c) }
            let groups = bySSID.map { FortiWifiSSIDGroup(site: ap.site, ssid: $0.key, clients: sortedBySignal($0.value)) }
            return FortiWifiRadioGroup(radio: b.radio, radioID: b.id, band: b.band, ssids: ordered(groups))
        }
    }

    /// SSID d'une borne et leur nombre de clients, toutes radios confondues (« Groupe-Interne · 7 »).
    public static func ssidCounts(ap: FortiManagedAP, clients: [FortiWifiClient]) -> [(ssid: String, count: Int)] {
        var counts: [String: Int] = [:]
        for radio in byRadio(ap: ap, clients: clients) {
            for group in radio.ssids { counts[group.ssid, default: 0] += group.count }
        }
        return counts.map { (ssid: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending }
    }

    /// Clients par SSID, site par site (jamais de fusion entre deux sites) : chaque SSID diffusé
    /// apparaît, même sans client ; un SSID vu chez un client mais absent de la configuration lue
    /// apparaît aussi. Ordre : sites dans l'ordre de la vue, puis le plus de clients d'abord.
    public static func bySSID(_ overview: FortiWifiOverview, clients: [FortiWifiClient]? = nil) -> [FortiWifiSSIDGroup] {
        let list = clients ?? overview.clients
        var siteOrder = overview.sites
        for site in list.map(\.site) + overview.ssids.map(\.site) where !siteOrder.contains(site) { siteOrder.append(site) }
        var result: [FortiWifiSSIDGroup] = []
        for site in siteOrder {
            let mine = list.filter { $0.site == site }
            var names: [String] = []
            for s in overview.ssids where s.site == site && !names.contains(s.ssid) { names.append(s.ssid) }
            for c in mine { let n = c.ssid ?? "(SSID inconnu)"; if !names.contains(n) { names.append(n) } }
            let groups = names.map { name in
                FortiWifiSSIDGroup(site: site, ssid: name,
                                   clients: sortedBySignal(mine.filter { ($0.ssid ?? "(SSID inconnu)") == name }),
                                   config: overview.ssids.first { $0.site == site && $0.ssid == name })
            }
            result += ordered(groups)
        }
        return result
    }

    /// Le plus faible d'abord (ce qu'on vient chercher), signal inconnu à la fin.
    static func sortedBySignal(_ clients: [FortiWifiClient]) -> [FortiWifiClient] {
        clients.sorted { a, b in
            switch (a.rssi, b.rssi) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.mac.value < b.mac.value
            }
        }
    }

    /// Recherche de la section Clients : chaque mot dans le nom, l'IP, la MAC (avec ou sans « : »),
    /// le SSID ou la borne (sans accents ni majuscules). Vide : tout.
    public static func matches(_ client: FortiWifiClient, text: String, deviceName: String? = nil) -> Bool {
        let words = SearchText.fold(text).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        let mac = client.mac.formatted(.colon)
        let haystack = SearchText.foldedJoined([client.hostname ?? "", client.ip?.description ?? "", mac,
                                                mac.replacingOccurrences(of: ":", with: ""), client.ssid ?? "",
                                                client.apName ?? "", deviceName ?? "", client.os ?? ""])
        return words.allSatisfy { haystack.contains($0.replacingOccurrences(of: "-", with: ":")) || haystack.contains($0) }
    }
}

// MARK: - Client ↔ appareil du Scanner

public enum FortiWifiClientLink {
    /// Appareil du Scanner de chaque client Wi-Fi, par MAC (sinon par IP quand un seul client du
    /// site a cette adresse et que l'appareil n'a pas de MAC connue). Les appareils du Scanner sont
    /// ceux du site actif : seuls les clients vus par les FortiGate de ce site (`activeSites`,
    /// libellés de site des clients) leur sont rattachés ; un client d'un autre site aux mêmes
    /// plages ou à la même MAC ne l'est jamais.
    public static func devices(for clients: [FortiWifiClient], devices: [Device], activeSites: Set<String>) -> [FortiWifiClient.ID: Device.ID] {
        let mine = clients.filter { activeSites.contains($0.site) }
        var byMAC: [MACAddress: Device.ID] = [:]
        for device in devices { if let mac = device.mac, byMAC[mac] == nil { byMAC[mac] = device.id } }
        var noMACByIP: [IPv4Address: Device.ID] = [:]
        for device in devices where device.mac == nil { noMACByIP[device.ip] = device.id }
        var ipCount: [IPv4Address: Int] = [:]
        for c in mine { if let ip = c.ip { ipCount[ip, default: 0] += 1 } }
        var result: [FortiWifiClient.ID: Device.ID] = [:]
        for client in mine {
            if let id = byMAC[client.mac] {
                result[client.id] = id
            } else if let ip = client.ip, ipCount[ip] == 1, let id = noMACByIP[ip] {
                result[client.id] = id
            }
        }
        return result
    }

    /// Client Wi-Fi d'un appareil du Scanner (site actif seulement), même règle.
    public static func client(for device: Device, clients: [FortiWifiClient], activeSites: Set<String>) -> FortiWifiClient? {
        let mine = clients.filter { activeSites.contains($0.site) }
        if let mac = device.mac { return mine.first { $0.mac == mac } }
        let same = mine.filter { $0.ip == device.ip }
        return same.count == 1 ? same[0] : nil
    }
}
