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
    /// Dernier changement d'état du lien de l'interface (`ifi_lastchange`, valeur opaque) : une
    /// coupure ou un débranchement le modifie, même si l'adresse et la passerelle restent les mêmes.
    /// Seule la capture LLDP/CDP le retient (un câble déplacé change de port de switch).
    public var linkStamp: UInt64?

    public init(interface: String?, subnet: Subnet? = nil, gateway: IPv4Address? = nil, linkStamp: UInt64? = nil) {
        self.interface = interface
        self.subnet = subnet
        self.gateway = gateway
        self.linkStamp = linkStamp
    }

    /// Contexte d'une interface locale (le sous-réseau seulement si elle a une adresse IPv4).
    public init(_ local: LocalInterface) {
        self.init(interface: local.name, subnet: local.hasIPv4 ? local.subnet : nil, gateway: local.gateway)
    }

    /// Vrai si `current` désigne un autre réseau que celui-ci : interface disparue (nil), autre
    /// interface, autre sous-réseau, autre passerelle ou lien coupé depuis. Ce qu'on ignore d'un
    /// côté ou de l'autre (passerelle pas encore lue, par exemple) ne compte pas comme un changement.
    public func isStale(comparedTo current: NetworkContext?) -> Bool {
        guard let current else { return true }
        if let a = interface, let b = current.interface, a != b { return true }
        if let a = subnet, let b = current.subnet, a != b { return true }
        if let a = gateway, let b = current.gateway, a != b { return true }
        if let a = linkStamp, let b = current.linkStamp, a != b { return true }
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

    /// Partie commune des plages `current` et `ranges`, nommée comme on la lit : une plage cochée
    /// entièrement comprise dans `ranges` garde son nom, une plage de `ranges` entièrement cochée
    /// aussi ; sinon, la portion commune (« 10.0.1.10-10.0.1.40 »).
    public static func intersection(_ current: [IPRange], _ ranges: [IPRange]) -> [IPRange] {
        var result: [IPRange] = []
        func add(_ range: IPRange) { if !result.contains(range) { result.append(range) } }
        for checked in current where ranges.contains(where: { overlaps($0, checked) }) {
            if covers(ranges, checked) { add(checked); continue }
            for range in ranges where overlaps(range, checked) {
                if covers([checked], range) { add(range); continue }
                let left = intervals([checked])
                for interval in intervals([range]) {
                    for other in left where other.overlaps(interval) {
                        let low = max(other.lowerBound, interval.lowerBound), high = min(other.upperBound, interval.upperBound)
                        add(IPRange(segments: [low == high ? .single(IPv4Address(low)) : .span(IPv4Address(low), IPv4Address(high))]))
                    }
                }
            }
        }
        return result
    }

    /// Nom d'une plage : le texte saisi s'il est connu (`names`), sinon sa forme lue.
    static func name(_ range: IPRange, names: [IPRange: String]) -> String {
        names[range] ?? range.description
    }

    /// « Plage 10.182.122.0/24 », « Plages 10.0.1.0/24 et 10.0.2.0/24 », « 3 plages » au-delà de
    /// deux (la liste complète est dans `rangesList`) ; vide sans plage. `names` : texte saisi
    /// de chaque plage (« 10.10.0.1-50 » plutôt que « 10.10.0.1-10.10.0.50 »).
    public static func rangesLabel(_ ranges: [IPRange], names: [IPRange: String] = [:]) -> String {
        switch ranges.count {
        case 0: return ""
        case 1: return "Plage " + name(ranges[0], names: names)
        case 2: return "Plages \(name(ranges[0], names: names)) et \(name(ranges[1], names: names))"
        default: return "\(ranges.count) plages"
        }
    }

    /// Liste complète des plages (« 10.0.1.0/24 ; 10.0.2.0/24 ; … »), pour l'aide au survol.
    public static func rangesList(_ ranges: [IPRange], names: [IPRange: String] = [:]) -> String {
        ranges.map { name($0, names: names) }.joined(separator: "\u{00A0}; ")
    }
}

/// État de l'emplacement (switch, port, VLAN) affiché pour un appareil.
public enum LocationStatus: Equatable, Sendable {
    /// Relevé sur le réseau actuel, appareil dans une plage cochée.
    case current
    /// Relevé sur le réseau actuel, mais la plage de l'appareil est décochée.
    case rangeUnchecked
    /// Relevé sur un autre réseau (interface, sous-réseau ou passerelle différents).
    case networkChanged
    /// Pas relevé (ou plus confirmé) depuis le dernier scan : emplacement d'un ancien relevé.
    case unconfirmed

    public var isCurrent: Bool { self == .current }

    /// Explication affichée sous l'emplacement (nil quand il est actuel).
    public var explanation: String? {
        switch self {
        case .current:
            return nil
        case .rangeUnchecked:
            return "Plage décochée\u{00A0}: emplacement relevé par le dernier scan, mais cette plage n’est pas comprise dans le prochain."
        case .networkChanged:
            return "Réseau changé depuis ce relevé\u{00A0}: relancez le scan sur ce réseau pour confirmer l’emplacement."
        case .unconfirmed:
            return "Relevé lors d’un scan précédent, non confirmé depuis\u{00A0}: relancez le scan avec la découverte des switchs pour le confirmer."
        }
    }
}

/// Réseau sur lequel l'emplacement de chaque appareil a été relevé. Un emplacement n'est présenté
/// comme actuel que s'il a été relevé (ou confirmé) sur le réseau actuel ; une découverte qui ne
/// relocalise pas un appareil de ses plages lui retire cette confirmation.
public struct LocationLedger: Equatable, Sendable {
    public private(set) var located: [IPv4Address: NetworkContext] = [:]

    public init() {}

    /// Appareils localisés par un relevé (découverte de fin de scan ou interrogation manuelle).
    public mutating func record(_ hosts: [IPv4Address], network: NetworkContext?) {
        let context = network ?? NetworkContext(interface: nil)
        for host in hosts { located[host] = context }
    }

    /// Fin d'une découverte sur `ranges` : les appareils de ces plages qu'elle n'a pas localisés
    /// perdent leur confirmation (switch muet, appareil déplacé, autre site sur la même plage).
    public mutating func discoveryFinished(ranges: [IPRange], located hosts: [IPv4Address], network: NetworkContext?) {
        located = located.filter { !ScanRelevance.contains(ranges, $0.key) }
        record(hosts, network: network)
    }

    public mutating func clear() {
        located = [:]
    }

    /// État de l'emplacement de l'appareil pour les plages cochées et le réseau actuel.
    public func status(of address: IPv4Address, checked: [IPRange], network current: NetworkContext?) -> LocationStatus {
        guard let context = located[address] else { return .unconfirmed }
        if context.isStale(comparedTo: current) { return .networkChanged }
        return ScanRelevance.contains(checked, address) ? .current : .rangeUnchecked
    }

    /// État du VLAN affiché : celui d'un emplacement relevé suit l'emplacement ; sans switch, le
    /// VLAN vient de la plage (Réglages) et ne dépend que de la plage cochée.
    public func vlanStatus(of address: IPv4Address, hasSwitchLocation: Bool, checked: [IPRange],
                           network current: NetworkContext?) -> LocationStatus {
        if hasSwitchLocation { return status(of: address, checked: checked, network: current) }
        return ScanRelevance.contains(checked, address) ? .current : .rangeUnchecked
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

    /// Même libellé avec le texte saisi de chaque plage.
    public func rangesLabel(names: [IPRange: String]) -> String { ScanRelevance.rangesLabel(ranges, names: names) }

    /// Switchs connus à relever à la fin d'un scan : ceux des plages scannées ou du sous-réseau
    /// de l'interface, ceux découverts à l'instant et ceux ajoutés à la main (VLAN de gestion
    /// routé). Un switch découvert sur un autre réseau n'est pas interrogé (ni sa communauté
    /// envoyée) : il reste relevable depuis « Switchs et ports ».
    public static func hostsToPoll(known: [IPv4Address], manual: Set<IPv4Address>, discoveredNow: Set<IPv4Address>,
                                   ranges: [IPRange], localSubnet: Subnet?) -> [IPv4Address] {
        known.filter { host in
            manual.contains(host) || discoveredNow.contains(host) || ScanRelevance.contains(ranges, host)
                || (localSubnet?.contains(host) ?? false)
        }
    }

    /// Part du bilan qui concerne les plages cochées : nil si aucune ne recouvre les plages du
    /// bilan ; le bilan entier si elles les couvrent toutes ; sinon seulement les adresses
    /// comprises dans les plages cochées (un switch reste s'il y est, s'il y a localisé un appareil
    /// ou s'il est hors des plages du bilan, sur un VLAN de gestion). Les plages gardées sont la
    /// partie commune, pour que le libellé corresponde aux compteurs.
    /// Un bilan sans plage (ancien format) est gardé tel quel.
    public func relevant(to current: [IPRange]) -> SwitchAutoResult? {
        guard !ranges.isEmpty else { return self }
        let kept = ranges.filter { range in current.contains { ScanRelevance.overlaps($0, range) } }
        guard !kept.isEmpty else { return nil }
        if ranges.allSatisfy({ ScanRelevance.covers(current, $0) }) { return self }
        func inside(_ address: IPv4Address) -> Bool { ScanRelevance.contains(current, address) }
        // Switch hors des plages du bilan (VLAN de gestion) : il vaut pour toutes ses plages.
        func outside(_ address: IPv4Address?) -> Bool { address.map { !ScanRelevance.contains(ranges, $0) } ?? false }
        var result = self
        result.ranges = ScanRelevance.intersection(current, ranges)
        result.queriedHosts = queriedHosts.filter(inside)
        result.respondedHosts = respondedHosts.filter(inside)
        result.discoveredHosts = discoveredHosts.filter(inside)
        result.locatedHosts = locatedHosts.filter(inside)
        result.filledHosts = filledHosts.filter(inside)
        result.switches = switches.compactMap { entry in
            var copy = entry
            copy.located = entry.located.filter(inside)
            let hostInside = entry.host.map(inside) ?? false
            return hostInside || outside(entry.host) || !copy.located.isEmpty ? copy : nil
        }
        result.failed = failed.filter { ($0.host.map(inside) ?? false) || outside($0.host) }
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

/// Relecture périodique de l'interface active (getifaddrs, table de routage) : que garder ?
public enum InterfaceRefresh: Equatable, Sendable {
    /// L'interface retenue, mise à jour (adresse, masque, passerelle) ; son type est gardé.
    case keep(LocalInterface)
    /// Interface disparue, ou choix de l'utilisateur revenu : il faut en choisir une (avec les types).
    case choose

    /// `active` : interface actuelle ; `preferred` : nom choisi dans Réglages › Interface ;
    /// `listed` : interfaces lues ; `defaultGateway` : route par défaut lue.
    /// L'interface active est gardée tant qu'elle existe, même si une autre est listée avant elle.
    /// La passerelle est celle de la route par défaut si elle est dans son sous-réseau (changement
    /// de passerelle à adresse égale), sinon l'ancienne tant que le sous-réseau ne change pas.
    public static func decide(active: LocalInterface?, preferred: String?, listed: [LocalInterface],
                              defaultGateway: IPv4Address?) -> InterfaceRefresh {
        if let preferred, preferred != active?.name, listed.contains(where: { $0.name == preferred }) { return .choose }
        guard let active, let fresh = listed.first(where: { $0.name == active.name }) else { return .choose }
        var updated = active
        updated.address = fresh.address
        updated.netmask = fresh.netmask
        if let defaultGateway, updated.subnet.contains(defaultGateway) {
            updated.gateway = defaultGateway
        } else if updated.subnet != active.subnet {
            updated.gateway = nil
        }
        return .keep(updated)
    }

    /// Interface à retenir quand il faut choisir : celle de l'utilisateur, sinon la première Wi-Fi
    /// ou Ethernet ; passerelle de la route par défaut si elle est dans son sous-réseau.
    public static func pick(from listed: [LocalInterface], preferred: String?, defaultGateway: IPv4Address?) -> LocalInterface? {
        var choice = listed.first { $0.name == preferred }
            ?? listed.first { $0.kind == .wifi || $0.kind == .ethernet } ?? listed.first
        if let gateway = defaultGateway, let current = choice, current.subnet.contains(gateway) { choice?.gateway = gateway }
        return choice
    }
}
