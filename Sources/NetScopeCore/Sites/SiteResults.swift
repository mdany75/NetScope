import Foundation

// Note 28 : résultats de scan PAR SITE. Device.id est l'adresse IP : la même IP sur deux sites ne
// doit jamais fusionner. Au changement de site, les appareils, le bilan des switchs, l'état du scan
// et les nouveautés du site quitté sont mis de côté (en mémoire et dans sites/<id>/resultats.json),
// puis ceux du site choisi sont rechargés.

/// Emplacement relevé (switch, port) d'une adresse, avec le réseau où il a été relevé.
public struct SiteLocationRecord: Codable, Hashable, Sendable {
    public var ip: IPv4Address
    public var network: NetworkContext

    public init(ip: IPv4Address, network: NetworkContext) {
        self.ip = ip
        self.network = network
    }
}

/// Bilan de la découverte des switchs (`SwitchAutoResult`), sous une forme enregistrable.
public struct SiteSwitchRecord: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var name: String
        public var host: IPv4Address?
        public var located: [IPv4Address]
    }

    public var date: Date
    public var ranges: [String]
    public var network: NetworkContext?
    public var queriedHosts: [IPv4Address]
    public var respondedHosts: [IPv4Address]
    public var discoveredHosts: [IPv4Address]
    public var switches: [Entry]
    public var failed: [Entry]
    public var locatedHosts: [IPv4Address]
    public var filledHosts: [IPv4Address]
    public var noCommunity: Bool
    public var communitiesTried: Int
    public var interrupted: Bool

    public init(_ result: SwitchAutoResult) {
        date = result.date
        ranges = result.ranges.map(\.description)
        network = result.network
        queriedHosts = result.queriedHosts
        respondedHosts = result.respondedHosts
        discoveredHosts = result.discoveredHosts
        switches = result.switches.map { Entry(name: $0.name, host: $0.host, located: $0.located) }
        failed = result.failed.map { Entry(name: $0.name, host: $0.host, located: $0.located) }
        locatedHosts = result.locatedHosts
        filledHosts = result.filledHosts
        noCommunity = result.noCommunity
        communitiesTried = result.communitiesTried
        interrupted = result.interrupted
    }

    public var result: SwitchAutoResult {
        SwitchAutoResult(date: date, ranges: ranges.compactMap { try? IPRange(parsing: $0) }, network: network,
                         queriedHosts: queriedHosts, respondedHosts: respondedHosts, discoveredHosts: discoveredHosts,
                         switches: switches.map { .init(name: $0.name, host: $0.host, located: $0.located) },
                         failed: failed.map { .init(name: $0.name, host: $0.host, located: $0.located) },
                         locatedHosts: locatedHosts, filledHosts: filledHosts, noCommunity: noCommunity,
                         communitiesTried: communitiesTried, interrupted: interrupted)
    }
}

/// Résultats d'un site : appareils, noms personnalisés, état du dernier scan, nouveautés, bilan des
/// switchs et emplacements relevés.
public struct SiteResults: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version = SiteResults.currentVersion
    public var devices: [Device]
    public var customNames: [String: String]
    public var newIDs: [String]
    public var lastScanRanges: [String]
    public var startedAt: Date?
    public var finishedAt: Date?
    public var portLabel: String?
    public var portLabels: [String: String]
    public var latency: [String: [Double?]]
    public var switchResult: SiteSwitchRecord?
    public var locations: [SiteLocationRecord]

    public init(devices: [Device] = [], customNames: [String: String] = [:], newIDs: [String] = [], lastScanRanges: [String] = [],
                startedAt: Date? = nil, finishedAt: Date? = nil, portLabel: String? = nil, portLabels: [String: String] = [:],
                latency: [String: [Double?]] = [:], switchResult: SiteSwitchRecord? = nil, locations: [SiteLocationRecord] = []) {
        self.devices = devices
        self.customNames = customNames
        self.newIDs = newIDs
        self.lastScanRanges = lastScanRanges
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.portLabel = portLabel
        self.portLabels = portLabels
        self.latency = latency
        self.switchResult = switchResult
        self.locations = locations
    }

    public var isEmpty: Bool { devices.isEmpty && customNames.isEmpty && finishedAt == nil && switchResult == nil }

    public var parsedScanRanges: [IPRange] { lastScanRanges.compactMap { try? IPRange(parsing: $0) } }

    /// Emplacements regroupés par réseau (pour `LocationLedger.record`).
    public var locationsByNetwork: [(network: NetworkContext, hosts: [IPv4Address])] {
        var groups: [NetworkContext: [IPv4Address]] = [:]
        var order: [NetworkContext] = []
        for item in locations {
            if groups[item.network] == nil { order.append(item.network) }
            groups[item.network, default: []].append(item.ip)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    public static func locations(of ledger: LocationLedger) -> [SiteLocationRecord] {
        ledger.located.map { SiteLocationRecord(ip: $0.key, network: $0.value) }.sorted { $0.ip < $1.ip }
    }

    enum CodingKeys: String, CodingKey {
        case version, devices, customNames, newIDs, lastScanRanges, startedAt, finishedAt, portLabel, portLabels, latency,
             switchResult, locations
    }

    /// Lecture tolérante : un appareil illisible est ignoré, un champ absent prend sa valeur par défaut.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? SiteResults.currentVersion
        devices = ((try? c.decodeIfPresent([SiteLenient<Device>].self, forKey: .devices)) ?? nil)?.compactMap(\.value) ?? []
        customNames = ((try? c.decodeIfPresent([String: String].self, forKey: .customNames)) ?? nil) ?? [:]
        newIDs = ((try? c.decodeIfPresent([String].self, forKey: .newIDs)) ?? nil) ?? []
        lastScanRanges = ((try? c.decodeIfPresent([String].self, forKey: .lastScanRanges)) ?? nil) ?? []
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)) ?? nil
        finishedAt = (try? c.decodeIfPresent(Date.self, forKey: .finishedAt)) ?? nil
        portLabel = (try? c.decodeIfPresent(String.self, forKey: .portLabel)) ?? nil
        portLabels = ((try? c.decodeIfPresent([String: String].self, forKey: .portLabels)) ?? nil) ?? [:]
        latency = ((try? c.decodeIfPresent([String: [Double?]].self, forKey: .latency)) ?? nil) ?? [:]
        switchResult = (try? c.decodeIfPresent(SiteSwitchRecord.self, forKey: .switchResult)) ?? nil
        locations = ((try? c.decodeIfPresent([SiteLenient<SiteLocationRecord>].self, forKey: .locations)) ?? nil)?.compactMap(\.value) ?? []
    }
}

// MARK: - Mise de côté

/// Résultats des sites quittés, gardés en mémoire et (hors démonstration) sur le disque. La clé est
/// l'identifiant du site, ou `SiteFiles.noSiteKey` pour les plages libres.
public struct SiteResultsShelf: Sendable {
    public private(set) var memory: [String: SiteResults] = [:]
    public let files: SiteFiles?

    public init(files: SiteFiles?) {
        self.files = files
    }

    /// Met de côté les résultats du site quitté.
    public mutating func shelve(_ results: SiteResults, for key: String) {
        memory[key] = results
        files?.saveResults(results, for: key)
    }

    /// Résultats du site choisi : ceux de la mémoire, sinon ceux du disque, sinon vides.
    public mutating func take(_ key: String) -> SiteResults {
        if let kept = memory[key] { return kept }
        let loaded = files?.loadResults(for: key) ?? SiteResults()
        memory[key] = loaded
        return loaded
    }

    /// Oublie les résultats d'un site supprimé.
    public mutating func forget(_ key: String) {
        memory[key] = nil
    }

    /// Remplace les résultats gardés en mémoire (démonstration).
    public mutating func preload(_ results: SiteResults, for key: String) {
        memory[key] = results
    }
}
