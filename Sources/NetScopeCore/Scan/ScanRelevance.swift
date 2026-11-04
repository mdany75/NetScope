import Foundation

// Pertinence des informations liées au réseau (note 18) : un bilan de scan, un emplacement de
// switch ou une capture LLDP/CDP ne valent que pour les plages et le réseau où ils ont été obtenus.
// Logique pure : aucune lecture du système, aucun trafic.

/// Réseau sur lequel une information a été obtenue : interface, sous-réseau et passerelle.
public struct NetworkContext: Codable, Hashable, Sendable {
    /// Nom BSD de l'interface (« en0 »).
    public var interface: String?
    /// Réseau de l'interface (nil : interface sans adresse IPv4).
    public var subnet: Subnet?
    public var gateway: IPv4Address?

    public init(interface: String?, subnet: Subnet? = nil, gateway: IPv4Address? = nil) {
        self.interface = interface
        self.subnet = subnet
        self.gateway = gateway
    }

    /// Contexte d'une interface locale (le sous-réseau seulement si elle a une adresse IPv4).
    public init(_ local: LocalInterface) {
        self.init(interface: local.name, subnet: local.hasIPv4 ? local.subnet : nil, gateway: local.gateway)
    }

    /// Vrai si `current` désigne un autre réseau que celui-ci : interface disparue (nil), autre
    /// interface, autre sous-réseau ou autre passerelle. Ce qu'on ignore d'un côté ou de l'autre
    /// (passerelle pas encore lue, par exemple) ne compte pas comme un changement.
    public func isStale(comparedTo current: NetworkContext?) -> Bool {
        guard let current else { return true }
        if let a = interface, let b = current.interface, a != b { return true }
        if let a = subnet, let b = current.subnet, a != b { return true }
        if let a = gateway, let b = current.gateway, a != b { return true }
        return false
    }

    /// « en0 · 10.182.122.0/24 » (ou « en0 »).
    public var label: String {
        [interface, subnet?.description].compactMap { $0 }.joined(separator: " · ")
    }
}

public enum ScanRelevance {
    /// Intervalles d'adresses couverts par des plages, fusionnés et triés.
    static func intervals(_ ranges: [IPRange]) -> [ClosedRange<UInt32>] {
        let all = ranges.flatMap(\.segments).map { segment -> ClosedRange<UInt32> in
            let bounds = segment.bounds
            return bounds.first.value...bounds.last.value
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<UInt32>] = []
        for interval in all {
            if let last = merged.last, interval.lowerBound <= last.upperBound || interval.lowerBound == last.upperBound &+ 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Vrai si les deux plages ont au moins une adresse en commun.
    public static func overlaps(_ a: IPRange, _ b: IPRange) -> Bool {
        let left = intervals([a])
        return intervals([b]).contains { interval in left.contains { $0.overlaps(interval) } }
    }

    /// Vrai si toutes les adresses de `range` sont dans `ranges`.
    public static func covers(_ ranges: [IPRange], _ range: IPRange) -> Bool {
        let union = intervals(ranges)
        return intervals([range]).allSatisfy { interval in
            union.contains { $0.lowerBound <= interval.lowerBound && $0.upperBound >= interval.upperBound }
        }
    }

    /// Vrai si l'adresse est dans l'une des plages.
    public static func contains(_ ranges: [IPRange], _ address: IPv4Address) -> Bool {
        ranges.contains { $0.contains(address) }
    }

    /// Un emplacement (switch, port, VLAN) d'appareil n'est présenté comme actuel que si l'appareil
    /// est dans les plages cochées et que le réseau n'a pas changé depuis le scan qui l'a relevé.
    public static func isLocationCurrent(_ address: IPv4Address, checked: [IPRange], networkStale: Bool) -> Bool {
        !networkStale && contains(checked, address)
    }

    /// « Plage 10.182.122.0/24 » ou « Plages 10.0.1.0/24, 10.0.2.0/24 » ; vide sans plage.
    public static func rangesLabel(_ ranges: [IPRange]) -> String {
        guard !ranges.isEmpty else { return "" }
        return (ranges.count > 1 ? "Plages " : "Plage ") + ranges.map(\.description).joined(separator: ", ")
    }
}

/// Bilan de la découverte automatique des switchs faite à la fin d'un scan, rattaché aux plages
/// et au réseau de ce scan.
public struct SwitchAutoResult: Equatable, Sendable {
    /// Switch relevé (ou dont le relevé a échoué) et appareils qu'il a permis de localiser.
    public struct SwitchEntry: Equatable, Sendable {
        public var name: String
        public var host: IPv4Address?
        public var located: [IPv4Address]

        public init(name: String, host: IPv4Address?, located: [IPv4Address] = []) {
            self.name = name
            self.host = host
            self.located = located
        }
    }

    public var date: Date
    /// Plages du scan qui a produit ce bilan.
    public var ranges: [IPRange]
    /// Réseau (interface, passerelle) au moment du scan.
    public var network: NetworkContext?
    /// Hôtes interrogés par la découverte (adresses privées, hors switchs écartés).
    public var queriedHosts: [IPv4Address]
    /// Appareils qui ont répondu en SNMP (switchs, routeurs, imprimantes…).
    public var respondedHosts: [IPv4Address]
    /// Switchs découverts dans ce scan (un par équipement, même s'il a plusieurs adresses).
    public var discoveredHosts: [IPv4Address]
    /// Switchs relevés avec succès pendant ce scan.
    public var switches: [SwitchEntry]
    /// Switchs dont le relevé complet a échoué pendant ce scan.
    public var failed: [SwitchEntry]
    /// Appareils des plages du scan dont le switch et le port sont connus.
    public var locatedHosts: [IPv4Address]
    /// Appareils dont la MAC a été complétée par l'ARP SNMP des routeurs et des switchs de niveau 3.
    public var filledHosts: [IPv4Address]
    /// Aucune communauté à essayer (liste vide et rien dans les Identifiants).
    public var noCommunity: Bool
    /// Nombre de communautés essayées (jamais leur valeur).
    public var communitiesTried: Int
    /// Scan arrêté pendant l'étape SNMP : bilan partiel.
    public var interrupted: Bool

    public init(date: Date = Date(), ranges: [IPRange] = [], network: NetworkContext? = nil,
                queriedHosts: [IPv4Address] = [], respondedHosts: [IPv4Address] = [], discoveredHosts: [IPv4Address] = [],
                switches: [SwitchEntry] = [], failed: [SwitchEntry] = [], locatedHosts: [IPv4Address] = [],
                filledHosts: [IPv4Address] = [], noCommunity: Bool = false, communitiesTried: Int = 0, interrupted: Bool = false) {
        self.date = date
        self.ranges = ranges
        self.network = network
        self.queriedHosts = queriedHosts
        self.respondedHosts = respondedHosts
        self.discoveredHosts = discoveredHosts
        self.switches = switches
        self.failed = failed
        self.locatedHosts = locatedHosts
        self.filledHosts = filledHosts
        self.noCommunity = noCommunity
        self.communitiesTried = communitiesTried
        self.interrupted = interrupted
    }

    public var queried: Int { queriedHosts.count }
    public var responded: Int { respondedHosts.count }
    public var discovered: Int { discoveredHosts.count }
    public var located: Int { locatedHosts.count }
    public var filledMACs: Int { filledHosts.count }
    public var switchNames: [String] { switches.map(\.name) }
    public var failedNames: [String] { failed.map(\.name) }
    public var foundSwitch: Bool { !switches.isEmpty }

    /// « Plage 10.182.122.0/24 » : plages concernées par ce bilan.
    public var rangesLabel: String { ScanRelevance.rangesLabel(ranges) }

    /// Échecs de relevé à signaler dans le bilan : seulement les switchs des plages scannées ou
    /// découverts pendant ce scan. Un switch connu d'un autre réseau (scan précédent) qui ne
    /// répond pas n'a rien à voir avec les plages scannées : son erreur reste dans « Switchs et ports ».
    public static func reportedFailures(polled: [SwitchEntry], succeeded: Set<IPv4Address>,
                                        discoveredNow: Set<IPv4Address>, ranges: [IPRange]) -> [SwitchEntry] {
        polled.filter { entry in
            guard let host = entry.host, !succeeded.contains(host) else { return false }
            return discoveredNow.contains(host) || ScanRelevance.contains(ranges, host)
        }
    }

    /// Part du bilan qui concerne les plages cochées : nil si aucune ne recouvre les plages du
    /// bilan ; le bilan entier si elles les couvrent toutes ; sinon seulement les adresses
    /// comprises dans les plages cochées (un switch reste s'il y est, ou s'il y a localisé un appareil).
    /// Un bilan sans plage (ancien format) est gardé tel quel.
    public func relevant(to current: [IPRange]) -> SwitchAutoResult? {
        guard !ranges.isEmpty else { return self }
        let kept = ranges.filter { range in current.contains { ScanRelevance.overlaps($0, range) } }
        guard !kept.isEmpty else { return nil }
        if ranges.allSatisfy({ ScanRelevance.covers(current, $0) }) { return self }
        func inside(_ address: IPv4Address) -> Bool { ScanRelevance.contains(current, address) }
        var result = self
        result.ranges = kept
        result.queriedHosts = queriedHosts.filter(inside)
        result.respondedHosts = respondedHosts.filter(inside)
        result.discoveredHosts = discoveredHosts.filter(inside)
        result.locatedHosts = locatedHosts.filter(inside)
        result.filledHosts = filledHosts.filter(inside)
        result.switches = switches.compactMap { entry in
            var copy = entry
            copy.located = entry.located.filter(inside)
            let hostInside = entry.host.map(inside) ?? false
            return hostInside || !copy.located.isEmpty ? copy : nil
        }
        result.failed = failed.filter { $0.host.map(inside) ?? false }
        return result
    }

    /// Bilan à afficher pour les plages cochées et le réseau actuel (nil : rien à afficher).
    public func presentation(checked: [IPRange], network current: NetworkContext?) -> SwitchAutoPresentation? {
        guard let part = relevant(to: checked) else { return nil }
        let stale = network.map { $0.isStale(comparedTo: current) } ?? false
        return SwitchAutoPresentation(result: part, isStale: stale)
    }
}

/// Bilan prêt à afficher : la partie pertinente et son état (réseau changé depuis le scan).
public struct SwitchAutoPresentation: Equatable, Sendable {
    public var result: SwitchAutoResult
    /// Le réseau (interface, sous-réseau ou passerelle) a changé depuis le scan.
    public var isStale: Bool
}

/// Cycle de vie du bilan : un nouveau scan l'efface toujours, qu'il fasse une découverte SNMP
/// ou non ; il n'est remplacé que par le bilan de ce scan.
public struct SwitchAutoLedger: Equatable, Sendable {
    public private(set) var result: SwitchAutoResult?
    /// Plages et réseau du scan en cours (pour rattacher son bilan).
    public private(set) var scanRanges: [IPRange] = []
    public private(set) var scanNetwork: NetworkContext?

    public init(result: SwitchAutoResult? = nil) {
        self.result = result
    }

    /// Un scan commence : l'ancien bilan disparaît.
    public mutating func scanStarted(ranges: [IPRange], network: NetworkContext?) {
        result = nil
        scanRanges = ranges
        scanNetwork = network
    }

    /// Bilan de la découverte de ce scan, rattaché à ses plages et à son réseau.
    public mutating func record(_ new: SwitchAutoResult) {
        var copy = new
        copy.ranges = scanRanges
        copy.network = scanNetwork
        result = copy
    }

    /// Fin du scan sans bilan de découverte : arrêté pendant une découverte prévue, on note
    /// l'interruption ; sinon (découverte désactivée, SNMP sauté) le bilan reste vide.
    public mutating func scanEnded(interrupted: Bool, planned: Bool, date: Date = Date()) {
        guard planned, interrupted, result == nil else { return }
        record(SwitchAutoResult(date: date, interrupted: true))
    }

    /// « Effacer » du scanner.
    public mutating func clear() {
        result = nil
    }
}
