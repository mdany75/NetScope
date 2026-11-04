import Foundation

// Note 28 : « Détecter mon site ». La passerelle observée (MAC lue dans la table ARP locale,
// numéro de série et nom d'hôte de la FortiGate déjà lus, SSID) désigne le site ; l'adresse IP
// seule ne choisit JAMAIS : deux clients peuvent avoir tous les deux 192.168.1.0/24. Si plusieurs
// sites partagent ces plages et qu'aucun indice ne tranche, on demande. Fonctions pures.

/// Ce qu'on observe du réseau où le Mac est branché (lecture locale, aucun trafic).
public struct SiteObservation: Hashable, Sendable {
    public var address: IPv4Address?
    public var gateway: IPv4Address?
    public var gatewayMAC: MACAddress?
    public var fortiGateSerial: String?
    public var fortiGateHostname: String?
    public var ssid: String?

    public init(address: IPv4Address? = nil, gateway: IPv4Address? = nil, gatewayMAC: MACAddress? = nil,
                fortiGateSerial: String? = nil, fortiGateHostname: String? = nil, ssid: String? = nil) {
        self.address = address
        self.gateway = gateway
        self.gatewayMAC = gatewayMAC
        self.fortiGateSerial = fortiGateSerial
        self.fortiGateHostname = fortiGateHostname
        self.ssid = ssid
    }
}

/// Indice qui a désigné le site.
public enum SiteHintKind: String, Hashable, Sendable {
    case gatewayMAC, fortiGateSerial, fortiGateHostname, ssid

    public var label: String {
        switch self {
        case .gatewayMAC: return "MAC de la passerelle"
        case .fortiGateSerial: return "numéro de série de la FortiGate"
        case .fortiGateHostname: return "nom de la FortiGate"
        case .ssid: return "SSID"
        }
    }

    /// Libellé avec son article : « la MAC de la passerelle », « le SSID »…
    public var labelWithArticle: String {
        switch self {
        case .gatewayMAC: return "la MAC de la passerelle"
        case .fortiGateSerial: return "le numéro de série de la FortiGate"
        case .fortiGateHostname: return "le nom de la FortiGate"
        case .ssid: return "le SSID"
        }
    }

    /// Un indice fort désigne le site à lui seul ; le SSID ne fait que départager.
    var isStrong: Bool { self != .ssid }
}

public enum SiteDetection: Hashable, Sendable {
    /// Un site reconnu par un indice (jamais par l'IP seule).
    case matched(UUID, by: SiteHintKind)
    /// Plusieurs sites possibles (mêmes plages, indices absents ou contradictoires) : demander.
    case ask([UUID], reason: String)
    /// Aucun site ne correspond.
    case none

    public var matchedID: UUID? {
        if case .matched(let id, _) = self { return id }
        return nil
    }

    public var candidates: [UUID] {
        switch self {
        case .matched(let id, _): return [id]
        case .ask(let ids, _): return ids
        case .none: return []
        }
    }
}

public enum SiteDetector {
    public static func detect(_ observation: SiteObservation, in sites: [Site]) -> SiteDetection {
        // 1. Indices forts : MAC de la passerelle, puis série et nom d'hôte de la FortiGate.
        var strong: [(UUID, SiteHintKind)] = []
        for site in sites {
            if let mac = observation.gatewayMAC, site.hints.gatewayMACs.contains(mac) {
                strong.append((site.id, .gatewayMAC))
            } else if let serial = SiteHints.clean(observation.fortiGateSerial),
                      site.hints.fortiGateSerials.contains(where: { $0.caseInsensitiveCompare(serial) == .orderedSame }) {
                strong.append((site.id, .fortiGateSerial))
            } else if let host = SiteHints.clean(observation.fortiGateHostname),
                      site.hints.fortiGateHostnames.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
                strong.append((site.id, .fortiGateHostname))
            }
        }
        // Plages qui contiennent l'adresse du Mac ou la passerelle : candidats, jamais une preuve.
        let byAddress = sites.filter { site in
            [observation.address, observation.gateway].compactMap { $0 }.contains { site.contains($0) }
        }.map(\.id)

        if strong.count == 1 { return .matched(strong[0].0, by: strong[0].1) }
        if strong.count > 1 {
            // Même MAC enregistrée pour deux sites (site dupliqué à la main, par exemple) : le SSID
            // peut départager, sinon on demande.
            let ids = strong.map(\.0)
            if let pick = bySSID(observation, among: sites.filter { ids.contains($0.id) }) { return .matched(pick, by: .ssid) }
            return .ask(ids, reason: "Plusieurs sites ont les mêmes indices de passerelle.")
        }

        // 2. Aucun indice fort : le SSID départage les sites candidats par leurs plages (ou tous
        //    les sites si aucune plage ne contient l'adresse).
        let pool = byAddress.isEmpty ? sites : sites.filter { byAddress.contains($0.id) }
        if let pick = bySSID(observation, among: pool) {
            // Un SSID seul ne suffit pas si les plages du site ne contiennent pas l'adresse observée
            // alors que d'autres la contiennent (même nom de réseau Wi-Fi chez deux clients).
            if byAddress.isEmpty || byAddress.contains(pick) { return .matched(pick, by: .ssid) }
        }
        if byAddress.isEmpty { return .none }
        let reason = byAddress.count > 1
            ? "\(byAddress.count) sites ont des plages qui contiennent cette adresse, et la passerelle ne correspond à aucun indice enregistré."
            : "Les plages de ce site contiennent cette adresse, mais la passerelle ne correspond à aucun indice enregistré (l’adresse seule ne suffit pas)."
        return .ask(byAddress, reason: reason)
    }

    private static func bySSID(_ observation: SiteObservation, among sites: [Site]) -> UUID? {
        guard let ssid = SiteHints.clean(observation.ssid) else { return nil }
        let matching = sites.filter { ($0.hints.ssid ?? "").caseInsensitiveCompare(ssid) == .orderedSame }
        return matching.count == 1 ? matching[0].id : nil
    }
}

// MARK: - FortiGate du site

public enum SiteFortiGate {
    /// FortiGate à lire : celles du site actif ; sans site actif seulement, le choix par plage
    /// (`FortiControllerSelector`). Un site sans FortiGate associée n'en lit aucune : jamais celle
    /// d'un autre client qui aurait les mêmes plages.
    public static func select(site: Site?, controllers: [FortiGateController], scanned: [IPRange],
                              macAddress: IPv4Address?) -> FortiControllerSelection {
        guard let site else {
            return FortiControllerSelector.select(controllers, scanned: scanned, macAddress: macAddress)
        }
        let picks = controllers.filter { $0.isEnabled && site.fortiGateIDs.contains($0.id) }.map { controller in
            FortiControllerSelection.Pick(controllerID: controller.id, site: controller.displayName, reason: .activeSite,
                                          coveredRanges: controller.coveredRanges.map(\.text),
                                          scannedRanges: scanned.map(\.description))
        }
        return FortiControllerSelection(picks: picks, conflicts: [], uncovered: [])
    }

    /// FortiGate qui correspondent à ces plages (pour l'enregistrement d'un site et la migration) :
    /// celles choisies par plage scannée seulement, ou l'unique FortiGate s'il n'y en a qu'une.
    public static func matching(_ controllers: [FortiGateController], ranges: [IPRange]) -> [UUID] {
        if controllers.count == 1 { return [controllers[0].id] }
        guard !ranges.isEmpty else { return [] }
        return FortiControllerSelector.select(controllers, scanned: ranges, macAddress: nil).picks
            .filter { $0.reason == .scannedRange }.map(\.controllerID)
    }

    /// Plages du Scanner tirées des plages couvertes d'une FortiGate : celles qu'on peut scanner
    /// (au plus `IPRange.maxAddresses` adresses) ; un /16 trop grand donne son premier /24, décoché.
    public static func scanRanges(for controller: FortiGateController) -> [ScanRangeConfig] {
        controller.coveredRanges.map { covered in
            if (try? IPRange(parsing: covered.text)) != nil, covered.size <= IPRange.maxAddresses {
                return ScanRangeConfig(text: covered.text, label: controller.displayName)
            }
            let first = Subnet(address: covered.first, prefix: 24)
            return ScanRangeConfig(text: first.description, label: "\(controller.displayName) (extrait de \(covered.text))", isEnabled: false)
        }
    }

    /// « Créer depuis les FortiGate » : un site par FortiGate qui n'est encore associée à aucun
    /// site (nom de site de la FortiGate, plages couvertes, série et nom d'hôte relus).
    public static func sitesToCreate(from controllers: [FortiGateController], existing: SiteList, now: Date = Date()) -> [Site] {
        let linked = Set(existing.sites.flatMap(\.fortiGateIDs))
        var names = existing
        var result: [Site] = []
        for controller in controllers where !linked.contains(controller.id) {
            var hints = SiteHints()
            hints.learn(serial: controller.lastStatus?.serial, hostname: controller.lastStatus?.hostname)
            let site = Site(name: names.uniqueName(controller.displayName), ranges: scanRanges(for: controller),
                            fortiGateIDs: [controller.id], hints: hints, created: now)
            names.sites.append(site)
            result.append(site)
        }
        return result
    }

    /// Indices relus des FortiGate d'un site (série, nom d'hôte), ajoutés sans doublon.
    public static func refreshHints(_ site: inout Site, controllers: [FortiGateController]) {
        for controller in controllers where site.fortiGateIDs.contains(controller.id) {
            site.hints.learn(serial: controller.lastStatus?.serial, hostname: controller.lastStatus?.hostname)
        }
    }
}
