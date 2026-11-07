import Foundation

// Note 97 : bornes Wi-Fi pirates (inspiré de Kismet et de Sparrow-wifi). Les bornes entendues par
// les FortiAP (détection des bornes non autorisées de FortiOS) et par ce Mac (balayage sur clic)
// sont rangées en trois listes :
// - pirates : un SSID du site diffusé par une borne qui n'est pas une FortiAP connue (sosie,
//   « evil twin »), une borne inconnue branchée sur le réseau filaire (signalée « on-wire » par
//   FortiOS, ou BSSID voisin d'une MAC vue sur un port de switch), ou marquée « rogue » dans FortiOS ;
// - voisines : bornes des alentours, et celles qu'on a acceptées ;
// - connues : bornes du site (FortiAP).
// Moteur pur ; l'acceptation se range par site et par BSSID (jamais par l'IP).

public enum RogueAPSource: String, Codable, Sendable {
    case fortiGate, thisMac

    public var label: String {
        switch self {
        case .fortiGate: return "FortiAP"
        case .thisMac: return "Ce Mac"
        }
    }
}

/// Borne entendue (FortiGate ou balayage de ce Mac).
public struct RogueAPSighting: Hashable, Sendable {
    public var site: String
    public var ssid: String?
    public var bssid: MACAddress?
    public var channel: Int?
    public var rssi: Int?
    public var security: String?
    public var source: RogueAPSource
    /// Statut FortiOS (nil pour ce Mac).
    public var fortiStatus: FortiRogueAP.Status?
    /// Signalée sur le réseau câblé par FortiOS.
    public var onWire: Bool
    public var seenBy: [String]

    public init(site: String, ssid: String?, bssid: MACAddress?, channel: Int? = nil, rssi: Int? = nil, security: String? = nil,
                source: RogueAPSource, fortiStatus: FortiRogueAP.Status? = nil, onWire: Bool = false, seenBy: [String] = []) {
        self.site = site
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.rssi = rssi
        self.security = security
        self.source = source
        self.fortiStatus = fortiStatus
        self.onWire = onWire
        self.seenBy = seenBy
    }

    public init(_ rogue: FortiRogueAP) {
        self.init(site: rogue.site, ssid: rogue.ssid, bssid: rogue.bssid, channel: rogue.channel, rssi: rogue.rssi,
                  security: rogue.security, source: .fortiGate, fortiStatus: rogue.status, onWire: rogue.onWire, seenBy: rogue.seenBy)
    }

    public init(_ network: WifiNetwork, site: String) {
        self.init(site: site, ssid: network.isHidden ? nil : network.ssid, bssid: network.bssid, channel: network.channel,
                  rssi: network.rssi, security: network.security.label, source: .thisMac)
    }
}

/// MAC vue sur un port de switch (table d'adresses ou inventaire).
public struct RogueAPWiredMAC: Hashable, Sendable {
    public var site: String
    public var mac: MACAddress
    /// « SW-CORE-01 · port 14 ».
    public var place: String

    public init(site: String, mac: MACAddress, place: String) {
        self.site = site
        self.mac = mac
        self.place = place
    }
}

public enum RogueAPClass: String, Codable, Sendable, CaseIterable {
    case pirate, voisine, connue

    public var label: String {
        switch self {
        case .pirate: return "Pirates"
        case .voisine: return "Voisines"
        case .connue: return "Connues"
        }
    }
}

public enum RogueAPReason: String, Codable, Sendable {
    /// SSID du site sur une borne qui n'est pas une FortiAP connue.
    case sosie
    /// Borne inconnue branchée sur le réseau filaire.
    case filaire
    /// Marquée non autorisée dans FortiOS.
    case nonAutorisee
    case voisine
    /// Voisine acceptée par l'utilisateur (ou « accepted » dans FortiOS).
    case acceptee
    case fortiAP

    public var label: String {
        switch self {
        case .sosie: return "Sosie d’un SSID du site"
        case .filaire: return "Branchée sur le réseau filaire"
        case .nonAutorisee: return "Non autorisée (FortiOS)"
        case .voisine: return "Voisine"
        case .acceptee: return "Voisine acceptée"
        case .fortiAP: return "FortiAP du site"
        }
    }
}

public struct RogueAPFinding: Identifiable, Hashable, Sendable {
    public var id: String { RogueAPAnalyzer.key(site: site, bssid: bssid, ssid: ssid) }
    public var site: String
    public var ssid: String?
    public var bssid: MACAddress?
    public var channel: Int?
    public var rssi: Int?
    public var security: String?
    public var vendor: String?
    public var sources: [RogueAPSource]
    public var seenBy: [String]
    public var classification: RogueAPClass
    public var reasons: [RogueAPReason]
    /// Port de switch où la borne est branchée (MAC filaire voisine du BSSID).
    public var wiredPlace: String?

    public var displaySSID: String { ssid.map { $0.isEmpty ? "(SSID caché)" : $0 } ?? "(SSID caché)" }
    public var reasonLabel: String { reasons.map(\.label).joined(separator: ", ") }
}

public enum RogueAPAnalyzer {
    /// Écart maximal entre le BSSID et la MAC filaire d'une même borne (MAC de base + n).
    public static let wiredOffset: UInt64 = 16

    /// Clé d'acceptation : site et BSSID (ou SSID pour une borne sans BSSID).
    public static func key(site: String, bssid: MACAddress?, ssid: String?) -> String {
        site + "|" + (bssid?.formatted(.upperColon) ?? "ssid:" + (ssid ?? "?"))
    }

    /// `siteSSIDs` : SSID diffusés par les FortiAP de chaque site ; `knownBSSIDs` : BSSID des
    /// bornes du site (relevés de ce Mac connectés, FortiAP) ; `isFortinet` : fabricant de la MAC.
    public static func classify(_ sightings: [RogueAPSighting], siteSSIDs: [String: Set<String>],
                                knownBSSIDs: Set<MACAddress> = [], wired: [RogueAPWiredMAC] = [], accepted: Set<String> = [],
                                vendor: (MACAddress) -> String? = { _ in nil }) -> [RogueAPFinding] {
        // Fusion par site et BSSID : la FortiGate et ce Mac peuvent entendre la même borne.
        var merged: [String: RogueAPFinding] = [:]
        var order: [String] = []
        var flags: [String: (rogue: Bool, onWire: Bool, accepted: Bool)] = [:]
        for s in sightings {
            let k = key(site: s.site, bssid: s.bssid, ssid: s.ssid)
            if var f = merged[k] {
                if !f.sources.contains(s.source) { f.sources.append(s.source) }
                f.seenBy = Array(Set(f.seenBy + s.seenBy)).sortedFrench(by: { $0 })
                if let r = s.rssi, r > (f.rssi ?? Int.min) { f.rssi = r }
                f.ssid = f.ssid ?? s.ssid
                f.channel = f.channel ?? s.channel
                f.security = f.security ?? s.security
                merged[k] = f
            } else {
                order.append(k)
                merged[k] = RogueAPFinding(site: s.site, ssid: s.ssid, bssid: s.bssid, channel: s.channel, rssi: s.rssi,
                                           security: s.security, vendor: s.bssid.flatMap(vendor), sources: [s.source],
                                           seenBy: s.seenBy, classification: .voisine, reasons: [])
            }
            var flag = flags[k] ?? (false, false, false)
            flag.rogue = flag.rogue || s.fortiStatus == .rogue
            flag.onWire = flag.onWire || s.onWire
            flag.accepted = flag.accepted || s.fortiStatus == .accepted || s.fortiStatus == .suppressed
            flags[k] = flag
        }
        var result: [RogueAPFinding] = []
        for k in order {
            guard var f = merged[k], let flag = flags[k] else { continue }
            // FortiOS ne liste jamais ses propres bornes ; pour ce Mac, une borne Fortinet qui
            // diffuse un SSID du site est une FortiAP (sauf si la FortiGate la signale elle-même).
            let siteSSID = f.ssid.map { siteSSIDs[f.site]?.contains($0) == true } ?? false
            let isKnown = f.bssid.map { bssid in
                knownBSSIDs.contains(bssid)
                    || (f.sources == [.thisMac] && siteSSID && (vendor(bssid) ?? "").lowercased().contains("fortinet"))
            } ?? false
            if isKnown {
                f.classification = .connue
                f.reasons = [.fortiAP]
                result.append(f)
                continue
            }
            var reasons: [RogueAPReason] = []
            if let ssid = f.ssid, !ssid.isEmpty, siteSSIDs[f.site]?.contains(ssid) == true { reasons.append(.sosie) }
            let place = f.bssid.flatMap { wiredPlace($0, site: f.site, wired: wired) }
            if flag.onWire || place != nil {
                reasons.append(.filaire)
                f.wiredPlace = place
            }
            if flag.rogue { reasons.append(.nonAutorisee) }
            let isAccepted = accepted.contains(k) || flag.accepted
            // Un sosie reste pirate même accepté : il imite le réseau du site.
            if !reasons.isEmpty && !(isAccepted && !reasons.contains(.sosie)) {
                f.classification = .pirate
                f.reasons = reasons
            } else {
                f.classification = .voisine
                f.reasons = [isAccepted ? .acceptee : .voisine]
            }
            result.append(f)
        }
        return result.sorted { a, b in
            let ra = RogueAPClass.allCases.firstIndex(of: a.classification) ?? 0
            let rb = RogueAPClass.allCases.firstIndex(of: b.classification) ?? 0
            if ra != rb { return ra < rb }
            if (a.rssi ?? Int.min) != (b.rssi ?? Int.min) { return (a.rssi ?? Int.min) > (b.rssi ?? Int.min) }
            return FrenchOrder.precedes(a.displaySSID, b.displaySSID)
        }
    }

    /// MAC filaire du même site à moins de `wiredOffset` du BSSID, mêmes trois premiers octets
    /// (ou BSSID administré localement dérivé de la MAC de base : premier octet sans le bit 0x02).
    static func wiredPlace(_ bssid: MACAddress, site: String, wired: [RogueAPWiredMAC]) -> String? {
        let base = MACAddress(value: bssid.value & ~(UInt64(0x02) << 40))
        for entry in wired where entry.site == site && entry.mac != bssid {
            for candidate in [bssid, base] where candidate.ouiValue == entry.mac.ouiValue {
                let diff = candidate.value > entry.mac.value ? candidate.value - entry.mac.value : entry.mac.value - candidate.value
                if diff <= wiredOffset { return entry.place }
            }
        }
        return nil
    }

    /// Résultat de la sonde « Borne Wi-Fi pirate » : panne s'il y a un sosie ou une borne branchée
    /// sur le réseau, alerte pour une borne seulement non autorisée.
    public static func monitorResult(_ findings: [RogueAPFinding], now: Date) -> MonResult {
        let pirates = findings.filter { $0.classification == .pirate }
        let neighbors = findings.filter { $0.classification == .voisine }.count
        guard !pirates.isEmpty else {
            return MonResult(date: now, reachable: true, value: "Aucune pirate · \(neighbors) voisine\(neighbors > 1 ? "s" : "")")
        }
        let names = pirates.prefix(3).map { "\($0.displaySSID) (\($0.reasonLabel.lowercased()))" }.joined(separator: ", ")
        let value = "\(pirates.count) pirate\(pirates.count > 1 ? "s" : "") · \(neighbors) voisine\(neighbors > 1 ? "s" : "")"
        let serious = pirates.contains { $0.reasons.contains(.sosie) || $0.reasons.contains(.filaire) }
        return serious
            ? MonResult(date: now, reachable: false, value: value, error: "Borne pirate\u{00A0}: \(names)")
            : MonResult(date: now, reachable: true, value: value, problem: "Borne non autorisée\u{00A0}: \(names)")
    }

    /// Bornes visées par une sonde : « * » pour tous les sites, sinon le nom du site.
    public static func filter(_ findings: [RogueAPFinding], target: String) -> [RogueAPFinding] {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard t != "*", !t.isEmpty, t.lowercased() != "tous" else { return findings }
        return findings.filter { $0.site.compare(t, options: FrenchOrder.options, range: nil, locale: FrenchOrder.locale) == .orderedSame }
    }
}
