import Foundation

// Note 58 : mesures brutes du bilan de raccordement, rendues par les sondes (réelles dans
// l'application, simulées dans les tests et la démonstration). Les verdicts sont tirés de ces
// mesures par LinkCheckEvaluator, sans réseau.

/// Réglages d'un bilan.
public struct LinkCheckOptions: Equatable, Sendable {
    /// Adresse neutre de l'étape Internet : page d'Apple qui répond « Success » (un portail captif
    /// répond autre chose).
    public static let defaultInternetURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    public static let defaultDNSNames = ["microsoft.com", "google.com", "cloudflare.com"]

    public var interfaceName: String
    public var location: String
    /// VLAN attendu sur ce port (nil : pas de contrôle).
    public var expectedVLAN: Int?
    /// Serveurs DHCP autorisés (vide : pas de contrôle), comme dans le Test DHCP.
    public var allowedDHCPServers: [IPv4Address]
    public var dnsNames: [String]
    public var internetURL: URL
    /// Texte attendu dans la réponse de l'adresse neutre (nil : pas de contrôle).
    public var expectedInternetText: String?
    public var pingCount: Int
    public var pingInterval: TimeInterval
    /// Écoute des annonces LLDP (30 s) et CDP (60 s).
    public var neighborSeconds: TimeInterval
    /// Attente des offres DHCP.
    public var dhcpSeconds: TimeInterval

    public init(interfaceName: String, location: String = "", expectedVLAN: Int? = nil, allowedDHCPServers: [IPv4Address] = [],
                dnsNames: [String] = LinkCheckOptions.defaultDNSNames, internetURL: URL = LinkCheckOptions.defaultInternetURL,
                expectedInternetText: String? = "Success", pingCount: Int = 10, pingInterval: TimeInterval = 0.2,
                neighborSeconds: TimeInterval = 35, dhcpSeconds: TimeInterval = 4) {
        self.interfaceName = interfaceName
        self.location = location
        self.expectedVLAN = expectedVLAN
        self.allowedDHCPServers = allowedDHCPServers
        self.dnsNames = dnsNames
        self.internetURL = internetURL
        self.expectedInternetText = expectedInternetText
        self.pingCount = max(1, min(pingCount, 100))
        self.pingInterval = max(0.05, pingInterval)
        self.neighborSeconds = max(0, neighborSeconds)
        self.dhcpSeconds = max(1, dhcpSeconds)
    }
}

/// Duplex négocié.
public enum LinkDuplex: String, Codable, Sendable {
    case full, half

    public var label: String { self == .full ? "duplex intégral" : "semi-duplex" }
    /// Valeur seule, après l'étiquette « Duplex » (« intégral », « semi »).
    public var shortLabel: String { self == .full ? "intégral" : "semi" }
}

/// État du lien de l'interface (lecture locale : getifaddrs, SIOCGIFMEDIA).
public struct LinkCheckLink: Equatable, Sendable {
    public var name: String
    public var isWireless: Bool
    /// « Ethernet », « Wi-Fi ».
    public var kindLabel: String
    /// Porteuse présente (nil : l'interface ne le dit pas).
    public var isActive: Bool?
    public var address: IPv4Address?
    public var netmask: IPv4Address?
    public var gateway: IPv4Address?
    public var dnsServers: [IPv4Address]
    public var speedMbps: UInt64?
    public var duplex: LinkDuplex?
    /// « 1000baseT », « 100baseTX »…
    public var mediaLabel: String?

    public init(name: String, isWireless: Bool = false, kindLabel: String = "Ethernet", isActive: Bool? = true,
                address: IPv4Address? = nil, netmask: IPv4Address? = nil, gateway: IPv4Address? = nil,
                dnsServers: [IPv4Address] = [], speedMbps: UInt64? = nil, duplex: LinkDuplex? = nil, mediaLabel: String? = nil) {
        self.name = name
        self.isWireless = isWireless
        self.kindLabel = kindLabel
        self.isActive = isActive
        self.address = address
        self.netmask = netmask
        self.gateway = gateway
        self.dnsServers = dnsServers
        self.speedMbps = speedMbps
        self.duplex = duplex
        self.mediaLabel = mediaLabel
    }

    /// Adresse automatique 169.254.x.x : aucun serveur DHCP n'a répondu à macOS.
    public var isLinkLocal: Bool { address.map { $0.value >> 16 == 0xA9FE } ?? false }
    public var hasUsableAddress: Bool { address != nil && address?.value != 0 && !isLinkLocal }
}

/// Voisin LLDP/CDP entendu pendant le bilan, ou repris de la dernière capture.
public struct LinkCheckNeighborMeasure: Equatable, Sendable {
    public var neighbor: NetworkNeighbor?
    public var listenedSeconds: Double
    /// Voisin repris de la dernière capture LLDP/CDP sur le même lien (pas d'écoute possible).
    public var fromPreviousCapture: Bool
    /// L'écoute n'a pas pu se faire (droits sur /dev/bpf, interface Wi-Fi…).
    public var unavailableReason: String?
    /// PoE du port d'après le dernier relevé du switch (SNMP ou FortiGate), quand l'annonce LLDP/CDP
    /// n'en dit rien.
    public var switchPoE: DevicePoEStatus?

    public init(neighbor: NetworkNeighbor?, listenedSeconds: Double = 0, fromPreviousCapture: Bool = false,
                unavailableReason: String? = nil, switchPoE: DevicePoEStatus? = nil) {
        self.switchPoE = switchPoE
        self.neighbor = neighbor
        self.listenedSeconds = listenedSeconds
        self.fromPreviousCapture = fromPreviousCapture
        self.unavailableReason = unavailableReason
    }
}

/// Offres DHCP reçues après un DHCPDISCOVER (Test DHCP : aucun bail n'est pris).
public struct LinkCheckDHCPMeasure: Equatable, Sendable {
    public var offers: [DHCPOffer]
    public var waitedSeconds: Double
    /// « port UDP 68 partagé avec macOS », « BPF ».
    public var method: String?
    public var unavailableReason: String?
    /// Précision ajoutée quand aucune offre n'arrive (macOS a peut-être gardé les réponses).
    public var emptyHint: String?

    public init(offers: [DHCPOffer], waitedSeconds: Double, method: String? = nil, unavailableReason: String? = nil,
                emptyHint: String? = nil) {
        self.offers = offers
        self.waitedSeconds = waitedSeconds
        self.method = method
        self.unavailableReason = unavailableReason
        self.emptyHint = emptyHint
    }
}

/// Pings de la passerelle : un temps par envoi (nil : perdu).
public struct LinkCheckGatewayMeasure: Equatable, Sendable {
    public var address: IPv4Address
    public var rtts: [Double?]
    public var unavailableReason: String?

    public init(address: IPv4Address, rtts: [Double?], unavailableReason: String? = nil) {
        self.address = address
        self.rtts = rtts
        self.unavailableReason = unavailableReason
    }

    public var sent: Int { rtts.count }
    public var received: [Double] { rtts.compactMap { $0 } }
    public var lossPercent: Double { sent == 0 ? 100 : Double(sent - received.count) / Double(sent) * 100 }
    public var average: Double? { received.isEmpty ? nil : received.reduce(0, +) / Double(received.count) }
    public var maximum: Double? { received.max() }
    /// Gigue : écart moyen entre deux réponses successives.
    public var jitter: Double? {
        guard received.count > 1 else { return nil }
        let deltas = zip(received, received.dropFirst()).map { abs($1 - $0) }
        return deltas.reduce(0, +) / Double(deltas.count)
    }
}

/// Résolution d'un nom.
public struct LinkCheckDNSAnswer: Equatable, Sendable {
    public var name: String
    public var milliseconds: Double?
    public var addresses: [String]
    public var error: String?

    public init(name: String, milliseconds: Double?, addresses: [String] = [], error: String? = nil) {
        self.name = name
        self.milliseconds = milliseconds
        self.addresses = addresses
        self.error = error
    }

    public var resolved: Bool { error == nil && !addresses.isEmpty }
}

public struct LinkCheckDNSMeasure: Equatable, Sendable {
    /// Serveur interrogé (nil : résolveur du système).
    public var server: IPv4Address?
    public var answers: [LinkCheckDNSAnswer]

    public init(server: IPv4Address?, answers: [LinkCheckDNSAnswer]) {
        self.server = server
        self.answers = answers
    }
}

/// Requête HTTP vers l'adresse neutre.
public struct LinkCheckInternetMeasure: Equatable, Sendable {
    public var url: URL
    public var statusCode: Int?
    public var milliseconds: Double?
    /// Le texte attendu est-il dans la réponse ? (nil : pas de contrôle).
    public var expectedTextFound: Bool?
    public var finalHost: String?
    public var error: String?

    public init(url: URL, statusCode: Int? = nil, milliseconds: Double? = nil, expectedTextFound: Bool? = nil,
                finalHost: String? = nil, error: String? = nil) {
        self.url = url
        self.statusCode = statusCode
        self.milliseconds = milliseconds
        self.expectedTextFound = expectedTextFound
        self.finalHost = finalHost
        self.error = error
    }
}

/// Sondes du bilan. L'application branche les moteurs existants (lecture des interfaces, capture
/// LLDP/CDP, Test DHCP, ping ICMP, DNS, sonde HTTP) ; les tests et la démonstration donnent des
/// mesures fixes, sans réseau.
public protocol LinkCheckProbing: Sendable {
    /// État du lien (nil : interface introuvable).
    func link(_ name: String) async -> LinkCheckLink?
    func neighbor(on link: LinkCheckLink, seconds: TimeInterval) async -> LinkCheckNeighborMeasure
    func dhcp(on link: LinkCheckLink, seconds: TimeInterval) async -> LinkCheckDHCPMeasure
    func gateway(_ address: IPv4Address, count: Int, interval: TimeInterval) async -> LinkCheckGatewayMeasure
    func dns(_ names: [String], server: IPv4Address?) async -> LinkCheckDNSMeasure
    func internet(_ url: URL, expectedText: String?) async -> LinkCheckInternetMeasure
}

/// Pings de la passerelle par une sonde ICMP existante (`ScanPinging`) : `count` envois espacés de
/// `interval`, un délai d'une seconde chacun.
public enum LinkCheckPing {
    public static func measure(_ address: IPv4Address, pinger: any ScanPinging, count: Int, interval: TimeInterval,
                               timeout: Duration = .seconds(1)) async -> LinkCheckGatewayMeasure {
        var rtts: [Double?] = []
        for index in 0..<max(1, count) {
            if Task.isCancelled { break }
            if index > 0 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            rtts.append(await pinger.ping(address, timeout: timeout))
        }
        return LinkCheckGatewayMeasure(address: address, rtts: rtts)
    }
}
