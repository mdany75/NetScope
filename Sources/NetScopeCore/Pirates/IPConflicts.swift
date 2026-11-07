import Foundation

// Note 96 : conflits d'adresses IP (inspiré d'arpwatch). Trois signes, toujours site par site
// (plusieurs sites peuvent utiliser les mêmes adresses privées) :
// - même IP vue avec deux MAC (table ARP de ce Mac, scans, FortiGate) ;
// - MAC qui change souvent d'IP (journal de l'Inventaire) ;
// - réponses ARP contradictoires : deux MAC pour la même IP à quelques secondes d'intervalle,
//   par la même source (usurpation possible, surtout pour la passerelle) ; l'application garde un
//   petit historique des lectures ARP de ce Mac pour les voir.
// Une MAC simplement remplacée par une autre (bail réattribué) n'est pas un conflit.
// Moteur pur : l'application fournit les observations déjà relevées, rien n'est envoyé.

/// D'où vient l'association IP-MAC.
public enum IPObservationSource: String, Codable, Sendable, CaseIterable {
    case arp, scan, fortiGate, capture

    public var label: String {
        switch self {
        case .arp: return "Table ARP de ce Mac"
        case .scan: return "Scan"
        case .fortiGate: return "FortiGate"
        case .capture: return "Capture ARP"
        }
    }
}

/// Une association IP-MAC vue à un instant.
public struct IPObservation: Hashable, Sendable {
    public var site: String
    public var ip: IPv4Address
    public var mac: MACAddress
    public var source: IPObservationSource
    public var date: Date

    public init(site: String, ip: IPv4Address, mac: MACAddress, source: IPObservationSource, date: Date) {
        self.site = site
        self.ip = ip
        self.mac = mac
        self.source = source
        self.date = date
    }
}

/// Changement d'IP d'un appareil (clé MAC), tiré du journal de l'Inventaire.
public struct IPChange: Hashable, Sendable {
    public var site: String
    public var mac: MACAddress
    public var ip: IPv4Address
    public var date: Date

    public init(site: String, mac: MACAddress, ip: IPv4Address, date: Date) {
        self.site = site
        self.mac = mac
        self.ip = ip
        self.date = date
    }
}

public enum IPConflictKind: String, Codable, Sendable, CaseIterable {
    /// Même IP, deux MAC (ou plus).
    case ipDeuxMAC
    /// Réponses ARP contradictoires à quelques secondes : usurpation possible.
    case arpContradictoire
    /// Une MAC change souvent d'IP.
    case macInstable

    public var label: String {
        switch self {
        case .ipDeuxMAC: return "Même IP, deux MAC"
        case .arpContradictoire: return "Réponses ARP contradictoires"
        case .macInstable: return "MAC qui change souvent d’IP"
        }
    }

    public var isCritical: Bool { self != .macInstable }
}

public struct IPConflict: Identifiable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue)|\(site)|\(ip?.description ?? "")|\(macs.map(\.description).joined(separator: ","))" }
    public var kind: IPConflictKind
    public var site: String
    /// IP en cause (nil pour une MAC instable : voir `ips`).
    public var ip: IPv4Address?
    public var macs: [MACAddress]
    /// Adresses prises par la MAC instable, dans l'ordre.
    public var ips: [IPv4Address]
    public var sources: [IPObservationSource]
    public var lastSeen: Date
    /// La passerelle du site est en cause (usurpation la plus grave).
    public var involvesGateway: Bool
    public var detail: String
    /// Deux MAC Apple pour la même IP : souvent le proxy de veille Bonjour (Apple TV, borne) qui
    /// répond pour un Mac en veille. Simple alerte.
    public var possibleSleepProxy: Bool = false

    /// Panne pour la sonde : deux MAC ou réponses contradictoires, hors proxy de veille probable.
    public var isCritical: Bool { kind.isCritical && !possibleSleepProxy }
}

public struct IPConflictThresholds: Equatable, Sendable {
    /// Deux MAC vues pour la même IP dans cette fenêtre : conflit (1 h).
    public var window: TimeInterval
    /// Deux MAC pour la même IP, même source, à moins de cet écart : réponses contradictoires (60 s).
    public var contradictionSeconds: TimeInterval
    /// Changements d'IP d'une même MAC sur `instabilityWindow` à partir desquels elle est instable.
    public var instabilityChanges: Int
    public var instabilityWindow: TimeInterval
    /// Une MAC qui répond pour au moins autant d'IP à la fois est un routeur (proxy ARP) : ignorée.
    public var proxyARPLimit: Int
    /// Deux MAC de sources différentes ne font un conflit que si elles sont vues à moins de cet
    /// écart (5 min) ; au-delà, la plus récente a remplacé l'autre (bail DHCP réattribué).
    public var pairSeconds: TimeInterval

    public init(window: TimeInterval = 3600, contradictionSeconds: TimeInterval = 60, instabilityChanges: Int = 4,
                instabilityWindow: TimeInterval = 86_400, proxyARPLimit: Int = 8, pairSeconds: TimeInterval = 300) {
        self.pairSeconds = pairSeconds
        self.window = window
        self.contradictionSeconds = contradictionSeconds
        self.instabilityChanges = instabilityChanges
        self.instabilityWindow = instabilityWindow
        self.proxyARPLimit = proxyARPLimit
    }

    public static let standard = IPConflictThresholds()
}

public enum IPConflictAnalyzer {
    /// `gateways` : passerelle de chaque site (nom du site → IP) ; `isApple` : fabricant Apple
    /// (proxy de veille Bonjour probable quand toutes les MAC en cause le sont).
    public static func analyze(_ observations: [IPObservation], changes: [IPChange] = [], gateways: [String: IPv4Address] = [:],
                               now: Date, thresholds t: IPConflictThresholds = .standard,
                               isApple: (MACAddress) -> Bool = { _ in false }) -> [IPConflict] {
        let recent = observations.filter { now.timeIntervalSince($0.date) <= t.window && !$0.mac.isBroadcast && $0.mac.value != 0 }
        var result: [IPConflict] = []
        for (site, list) in Dictionary(grouping: recent, by: \.site) {
            // Proxy ARP : une MAC qui tient beaucoup d'IP (routeur, pare-feu) n'est pas un conflit.
            let ipsByMAC = Dictionary(grouping: list, by: \.mac).mapValues { Set($0.map(\.ip)).count }
            let proxies = Set(ipsByMAC.filter { $0.value >= t.proxyARPLimit }.keys)
            for (ip, seen) in Dictionary(grouping: list.filter { !proxies.contains($0.mac) }, by: \.ip) {
                let macs = Set(seen.map(\.mac)).sorted()
                guard macs.count > 1 else { continue }
                let gateway = gateways[site] == ip
                let sorted = seen.sorted { $0.date < $1.date }
                // Même source, deux MAC rapprochées : réponses contradictoires.
                var contradictory = false
                for (a, b) in zip(sorted, sorted.dropFirst()) where a.mac != b.mac && a.source == b.source
                    && b.date.timeIntervalSince(a.date) <= t.contradictionSeconds {
                    contradictory = true
                }
                // Une MAC réapparaît après une autre (va-et-vient), ou deux sources différentes la
                // voient à peu d'intervalle : vrai conflit. Sinon la plus récente a remplacé l'autre.
                var order: [MACAddress] = []
                for o in sorted where order.last != o.mac { order.append(o.mac) }
                let flipFlop = order.count > Set(order).count
                let close = seen.contains { a in
                    seen.contains { b in a.mac != b.mac && a.source != b.source && abs(a.date.timeIntervalSince(b.date)) <= t.pairSeconds }
                }
                guard contradictory || flipFlop || close else { continue }
                let sleepProxy = !gateway && macs.allSatisfy(isApple)
                let kind: IPConflictKind = contradictory ? .arpContradictoire : .ipDeuxMAC
                let sources = Array(Set(seen.map(\.source))).sorted { $0.rawValue < $1.rawValue }
                var detail = "\(ip) répond avec " + macs.map { $0.formatted(.upperColon) }.joined(separator: " et ")
                detail += " (" + sources.map(\.label).joined(separator: ", ") + ")"
                if contradictory { detail += "\u{00A0}; réponses contradictoires, usurpation possible" }
                if gateway { detail += "\u{00A0}; c’est la passerelle du site" }
                if sleepProxy { detail += "\u{00A0}; appareils Apple\u{00A0}: proxy de veille Bonjour probable" }
                result.append(IPConflict(kind: kind, site: site, ip: ip, macs: macs, ips: [ip], sources: sources,
                                         lastSeen: sorted.last?.date ?? now, involvesGateway: gateway, detail: detail + ".",
                                         possibleSleepProxy: sleepProxy))
            }
        }
        // MAC instable : changements d'IP récents par site et par MAC.
        let recentChanges = changes.filter { now.timeIntervalSince($0.date) <= t.instabilityWindow }
        for (_, list) in Dictionary(grouping: recentChanges, by: { $0.site + "|" + $0.mac.description }) {
            guard list.count >= t.instabilityChanges, let first = list.first else { continue }
            let sorted = list.sorted { $0.date < $1.date }
            var ips: [IPv4Address] = []
            for change in sorted where ips.last != change.ip { ips.append(change.ip) }
            let hours = Int((t.instabilityWindow / 3600).rounded())
            let detail = "\(first.mac.formatted(.upperColon)) a changé \(list.count)\u{00A0}fois d’IP en \(hours)\u{00A0}h\u{00A0}: "
                + ips.suffix(6).map(\.description).joined(separator: " → ") + "."
            result.append(IPConflict(kind: .macInstable, site: first.site, ip: nil, macs: [first.mac], ips: ips, sources: [],
                                     lastSeen: sorted.last?.date ?? now, involvesGateway: false, detail: detail))
        }
        return result.sorted(by: order)
    }

    /// Les plus graves d'abord (passerelle, usurpation, deux MAC, instable), puis par site et IP.
    static func order(_ a: IPConflict, _ b: IPConflict) -> Bool {
        func rank(_ c: IPConflict) -> Int {
            (c.involvesGateway ? 0 : 3) + (IPConflictKind.allCases.firstIndex(of: c.kind) ?? 0) + (c.possibleSleepProxy ? 3 : 0)
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        if a.site != b.site { return FrenchOrder.precedes(a.site, b.site) }
        return (a.ip?.value ?? a.ips.first?.value ?? 0) < (b.ip?.value ?? b.ips.first?.value ?? 0)
    }

    /// Observations d'un scan (appareils avec IP et MAC) pour un site.
    public static func observations(devices: [Device], site: String, source: IPObservationSource = .scan) -> [IPObservation] {
        devices.compactMap { device in
            device.mac.map { IPObservation(site: site, ip: device.ip, mac: $0, source: source, date: device.lastSeen) }
        }
    }
}
