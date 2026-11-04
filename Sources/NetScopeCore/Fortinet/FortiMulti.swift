import Foundation

// Note 25 : relevés de plusieurs FortiGate fusionnés. Chaque FortiSwitch est marqué du site de sa
// FortiGate ; deux sites dont les FortiSwitch ont la même adresse FortiLink (10.255.1.2 partout par
// défaut) gardent chacun leur switch ; la FortiGate reste prioritaire sur SNMP.

/// Lecture réussie d'une FortiGate d'un site.
public struct FortiSiteReport: Hashable, Sendable {
    public var controllerID: UUID
    public var site: String
    public var report: FortiGateReport
    /// Plages couvertes par cette FortiGate : sa table ARP et ses baux DHCP ne servent qu'à leurs
    /// adresses (deux sites peuvent utiliser les mêmes adresses privées). Vide : aucune restriction.
    public var coveredRanges: [FortiCoveredRange]

    public init(controllerID: UUID, site: String, report: FortiGateReport, coveredRanges: [FortiCoveredRange] = []) {
        self.controllerID = controllerID
        self.site = site
        self.report = report
        self.coveredRanges = coveredRanges
    }

    /// Nom marqué sur les relevés : le site, sinon le nom d'hôte de la FortiGate.
    public var label: String {
        let name = site.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? report.controllerName : name
    }

    /// Vrai si l'adresse relève de ce site.
    public func owns(_ ip: IPv4Address) -> Bool {
        coveredRanges.isEmpty || coveredRanges.contains { $0.contains(ip) }
    }
}

public enum FortiMulti {
    /// Relevés de tous les sites, dans l'ordre donné. Le relevé porte le site (`controllerName`) ;
    /// une adresse déjà prise par un autre site est remplacée par 0.s.x.y (jamais interrogée) et
    /// l'adresse FortiLink réelle est gardée dans `fortiLinkIP`.
    public static func snapshots(_ sites: [FortiSiteReport]) -> [SNMPSwitchSnapshot] {
        var used = Set<IPv4Address>()
        var result: [SNMPSwitchSnapshot] = []
        for (siteIndex, site) in sites.enumerated() {
            for var snapshot in FortiConvert.snapshots(from: site.report) {
                snapshot.controllerName = site.label
                // Adresse de remplacement 0.0.0.n (FortiLink inconnue) : propre à chaque site aussi.
                let real: IPv4Address? = snapshot.host.value < 256 ? nil : snapshot.host
                snapshot.fortiLinkIP = real
                if used.contains(snapshot.host) {
                    let low = snapshot.host.value & 0xFFFF
                    var candidate = IPv4Address(UInt32((siteIndex + 1) & 0xFF) << 16 | low)
                    while used.contains(candidate) { candidate = IPv4Address((candidate.value &+ 1) & 0x00FF_FFFF) }
                    snapshot.host = candidate
                }
                used.insert(snapshot.host)
                result.append(snapshot)
            }
        }
        return result
    }

    /// Noms des appareils : le premier site qui en connaît un l'emporte.
    public static func names(_ sites: [FortiSiteReport]) -> [MACAddress: String] {
        var result: [MACAddress: String] = [:]
        for site in sites {
            for (mac, name) in FortiConvert.names(from: site.report) where result[mac] == nil { result[mac] = name }
        }
        return result
    }

    /// Table IP → MAC fusionnée : chaque site seulement pour ses plages couvertes.
    public static func arpTable(_ sites: [FortiSiteReport]) -> [IPv4Address: MACAddress] {
        var result: [IPv4Address: MACAddress] = [:]
        for site in sites {
            for (ip, mac) in FortiConvert.arpTable(from: site.report) where result[ip] == nil && site.owns(ip) { result[ip] = mac }
        }
        return result
    }

    /// Ce que les lectures apportent aux appareils du scan : MAC manquantes, noms, puis emplacement
    /// (FortiGate > SNMP), comme `FortiLocate.apply` pour un seul site.
    public static func apply(_ sites: [FortiSiteReport], to devices: [Device], snmp: [SNMPSwitchSnapshot],
                             vendors: OUIDatabase = .builtIn) -> (devices: [Device], located: Int, named: Int, filled: Int) {
        let controller = snapshots(sites)
        let filled = SNMPAutoLocate.fillMACs(devices, from: arpTable(sites), vendors: vendors)
        let named = FortiLocate.applyNames(names(sites), to: filled.devices)
        let placed = FortiLocate.locate(named.devices, controller: controller, snmp: snmp)
        return (placed.devices, placed.located, named.named, filled.filled)
    }

    /// Exécute `work` pour chaque élément, au plus `limit` à la fois, et rend les résultats dans
    /// l'ordre des éléments.
    public static func parallel<Item: Sendable, Output: Sendable>(_ items: [Item], limit: Int,
                                                                    _ work: @escaping @Sendable (Item) async -> Output) async -> [Output] {
        guard !items.isEmpty else { return [] }
        var results = [Output?](repeating: nil, count: items.count)
        var next = 0
        await withTaskGroup(of: (Int, Output).self) { group in
            func launch() {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask { (index, await work(item)) }
            }
            for _ in 0..<max(1, min(limit, items.count)) { launch() }
            while let (index, output) = await group.next() {
                results[index] = output
                launch()
            }
        }
        return results.compactMap { $0 }
    }

    /// Plafond des lectures simultanées (20 sites : cinq vagues de quatre).
    public static let concurrentReads = 4
}
