import Foundation

// Note 84 (0.27.1) : appareils Wi-Fi et accès filaire. Un client qui passe d'une borne FortiAP à
// une autre apparaît derrière le port de switch de la nouvelle borne : ce n'est pas un câble
// déplacé. La décision « Wi-Fi ou filaire » est prise ici, par des fonctions pures, à partir de ce
// que NetScope a déjà lu (clients Wi-Fi de la FortiGate, voisins LLDP des switchs, fiches et types
// d'appareils) ; rien ici n'ouvre de connexion.
//
// Ordre des indices (le premier qui répond l'emporte) :
// 1. borne, switch ou routeur, ou adresse d'une borne lue sur la FortiGate (même si son type est
//    resté « inconnu ») : toujours filaire (une borne qui change de port garde son alerte) ;
// 2. client Wi-Fi vu par la FortiGate (par MAC, sinon par IP unique) ;
// 3. ce Mac, quand son interface active est en Wi-Fi ;
// 4. « port » Wi-Fi (appareil rattaché à sa borne, « FortiAP-231F · Wi-Fi ») ;
// 5. nouveau port de switch qui mène à une borne (voisin LLDP point d'accès, borne FortiAP ou
//    appareil de type borne branché sur ce port) ; l'ancien port seul ne suffit pas : une borne
//    peut occuper aujourd'hui le port libéré par un poste filaire déplacé ;
// 6. client Wi-Fi retenu par la fiche depuis moins de 30 jours (preuve directe : FortiGate, ce
//    Mac, port « Wi-Fi »), sauf si la FortiGate, lue, ne compte pas sa MAC parmi ses clients ;
// 7. téléphone mobile, ou adresse MAC privée (aléatoire), propre au Wi-Fi ;
// sinon filaire.
//
// Les indices 1 à 6 sont des preuves (`InvWirelessReason.isEvidence`) : seules elles changent une
// alerte « Changement de port » en itinérance. L'indice 7 vient de données que l'appareil choisit
// lui-même (nom d'hôte, bit « administrée localement » de la MAC) : il colore la carte, mais un
// changement de port reste en alerte.

/// Dernière association Wi-Fi connue d'une fiche (lue sur la FortiGate ou déduite du port).
public struct InvWirelessLink: Codable, Hashable, Sendable {
    /// Borne (« AP-ACCUEIL »), si elle est connue.
    public var apName: String?
    public var ssid: String?
    public var band: WifiBand?
    /// Dernière fois que l'appareil a été vu en Wi-Fi.
    public var seen: Date
    /// Borne d'avant la dernière itinérance et moment de celle-ci : quelques itinérances
    /// rapprochées ne donnent qu'un événement (« passé de la borne A à la borne C »).
    public var roamedFrom: String?
    public var roamedAt: Date?

    public init(apName: String? = nil, ssid: String? = nil, band: WifiBand? = nil, seen: Date,
                roamedFrom: String? = nil, roamedAt: Date? = nil) {
        self.apName = apName
        self.ssid = ssid
        self.band = band
        self.seen = seen
        self.roamedFrom = roamedFrom
        self.roamedAt = roamedAt
    }

    /// « AP-ACCUEIL · Groupe-Interne · 5 GHz ».
    public var label: String {
        [apName, ssid, band?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Accès d'un appareil au réseau.
public enum InvLinkMedium: String, Hashable, Sendable, CaseIterable {
    case filaire, wifi

    public var label: String {
        switch self {
        case .filaire: return "Filaire"
        case .wifi: return "Wi-Fi"
        }
    }
}

/// Ce qui fait dire qu'un appareil est en Wi-Fi.
public enum InvWirelessReason: Hashable, Sendable {
    case fortiGateClient
    case thisMac
    case wifiPort
    case accessPointPort(String)
    case remembered
    case mobilePhone
    case privateMAC

    public var label: String {
        switch self {
        case .fortiGateClient: return "client vu par la FortiGate"
        case .thisMac: return "interface de ce Mac"
        case .wifiPort: return "rattaché à sa borne"
        case .accessPointPort(let ap): return "port de switch de la borne \(ap)"
        case .remembered: return "déjà vu en Wi-Fi"
        case .mobilePhone: return "téléphone mobile"
        case .privateMAC: return "adresse MAC privée"
        }
    }

    /// Preuve du Wi-Fi (lecture de la FortiGate, de ce Mac, d'un port de borne) : elle seule
    /// change un changement de port en itinérance. Téléphone et MAC privée ne sont que des indices.
    public var isEvidence: Bool {
        switch self {
        case .mobilePhone, .privateMAC: return false
        default: return true
        }
    }

    /// Lecture directe (et non déduction) : elle seule rafraîchit l'association Wi-Fi d'une fiche.
    public var isDirect: Bool {
        switch self {
        case .fortiGateClient, .thisMac, .wifiPort: return true
        default: return false
        }
    }
}

/// Résultat du classement d'un appareil (ou d'un changement de port).
public struct InvMediumVerdict: Hashable, Sendable {
    public var medium: InvLinkMedium
    /// Raison du Wi-Fi (nil pour un appareil filaire).
    public var reason: InvWirelessReason?
    /// Borne avant et après le changement (nil : inconnue).
    public var apBefore: String?
    public var apAfter: String?
    public var ssid: String?
    public var band: WifiBand?

    public init(medium: InvLinkMedium, reason: InvWirelessReason? = nil, apBefore: String? = nil, apAfter: String? = nil,
                ssid: String? = nil, band: WifiBand? = nil) {
        self.medium = medium
        self.reason = reason
        self.apBefore = apBefore
        self.apAfter = apAfter
        self.ssid = ssid
        self.band = band
    }

    public static let wired = InvMediumVerdict(medium: .filaire)

    public var isWireless: Bool { medium == .wifi }

    /// Wi-Fi prouvé : un changement de port est une itinérance, sans alerte.
    public var isProvenWireless: Bool { isWireless && (reason?.isEvidence ?? false) }
}

/// Ce que NetScope sait déjà du Wi-Fi d'un site, pour classer les appareils (aucun réseau).
public struct InvWirelessContext: Sendable {
    /// Client Wi-Fi tel que la FortiGate le voit.
    public struct Client: Hashable, Sendable {
        public var apName: String?
        public var ssid: String?
        public var band: WifiBand?

        public init(apName: String? = nil, ssid: String? = nil, band: WifiBand? = nil) {
            self.apName = apName
            self.ssid = ssid
            self.band = band
        }
    }

    public var clientsByMAC: [MACAddress: Client]
    /// Clients par adresse IP (seulement les adresses portées par un seul client).
    public var clientsByIP: [IPv4Address: Client]
    /// Emplacement de switch (« SW-CORE-01 · Gi1/0/12 ») → nom de la borne branchée sur ce port.
    public var accessPointPorts: [String: String]
    /// Adresses de ce Mac sur une interface Wi-Fi.
    public var localWifiIPs: Set<IPv4Address>
    /// Clients Wi-Fi lus sur une FortiGate (un appareil absent de la liste n'est alors pas un
    /// client Wi-Fi de ces bornes au moment de la lecture).
    public var hasFortiGateClients: Bool
    /// Adresses IP et MAC des bornes elles-mêmes (lues sur la FortiGate) : toujours filaires.
    public var accessPointIPs: Set<IPv4Address>
    public var accessPointMACs: Set<MACAddress>
    /// Type choisi à la main sur la fiche d'inventaire, par MAC (sonde « Port de switch »).
    public var manualTypes: [MACAddress: DeviceType]

    public init(clientsByMAC: [MACAddress: Client] = [:], clientsByIP: [IPv4Address: Client] = [:],
                accessPointPorts: [String: String] = [:], localWifiIPs: Set<IPv4Address> = [], hasFortiGateClients: Bool = false,
                accessPointIPs: Set<IPv4Address> = [], accessPointMACs: Set<MACAddress> = [], manualTypes: [MACAddress: DeviceType] = [:]) {
        self.clientsByMAC = clientsByMAC
        self.clientsByIP = clientsByIP
        self.accessPointPorts = accessPointPorts
        self.localWifiIPs = localWifiIPs
        self.hasFortiGateClients = hasFortiGateClients
        self.accessPointIPs = accessPointIPs
        self.accessPointMACs = accessPointMACs
        self.manualTypes = manualTypes
    }

    /// Appareil qui est l'une des bornes lues sur la FortiGate.
    public func isAccessPoint(ip: IPv4Address, mac: MACAddress?) -> Bool {
        if accessPointIPs.contains(ip) { return true }
        if let mac { return accessPointMACs.contains(mac) }
        return false
    }

    public static let none = InvWirelessContext()

    /// Contexte d'une lecture Wi-Fi de la FortiGate, des appareils du scan et des fiches :
    /// - clients par MAC et par IP unique ;
    /// - ports des bornes : appareil ou fiche de type borne, ou à l'adresse d'une borne FortiAP
    ///   (nom de la borne lu sur la FortiGate), et `neighborPorts` (voisins LLDP point d'accès,
    ///   voir `accessPointPorts(in:)`).
    public init(overview: FortiWifiOverview?, devices: [Device], records: [InvRecord] = [],
                neighborPorts: [String: String] = [:], localWifiIPs: Set<IPv4Address> = []) {
        var byMAC: [MACAddress: Client] = [:]
        var ipCount: [IPv4Address: Int] = [:]
        var byIP: [IPv4Address: Client] = [:]
        let clients = overview?.clients ?? []
        let aps = overview?.aps ?? []
        for client in clients {
            let ap = client.apName ?? client.apKey.flatMap { key in aps.first { $0.keys.contains(key.lowercased()) }?.name }
            let entry = Client(apName: ap, ssid: client.ssid, band: client.band)
            if byMAC[client.mac] == nil { byMAC[client.mac] = entry }
            if let ip = client.ip {
                ipCount[ip, default: 0] += 1
                byIP[ip] = entry
            }
        }
        for (ip, count) in ipCount where count > 1 { byIP[ip] = nil }
        var ports = neighborPorts
        let apByIP = Dictionary(aps.compactMap { ap in ap.ip.map { ($0, ap.name) } }, uniquingKeysWith: { first, _ in first })
        var apMACs: Set<MACAddress> = []
        var manual: [MACAddress: DeviceType] = [:]
        func addPort(switchName: String?, port: String?, ip: IPv4Address, mac: MACAddress?, type: DeviceType, name: String) {
            if let mac, apByIP[ip] != nil { apMACs.insert(mac) }
            guard let location = Self.location(switchName: switchName, port: port), !Self.isWifiPort(port) else { return }
            if let ap = apByIP[ip] {
                ports[location] = ap
            } else if type == .pointAcces, ports[location] == nil {
                ports[location] = name
            }
        }
        for record in records {
            addPort(switchName: record.switchName, port: record.switchPort, ip: record.ip, mac: record.mac, type: record.type,
                    name: record.displayName)
            if let mac = record.mac, let type = record.annotations.customType { manual[mac] = type }
        }
        // Le scan en cours l'emporte sur les fiches (même emplacement, borne déplacée).
        for device in devices {
            addPort(switchName: device.switchName, port: device.switchPort, ip: device.ip, mac: device.mac, type: device.deviceType,
                    name: device.displayName)
        }
        self.init(clientsByMAC: byMAC, clientsByIP: byIP, accessPointPorts: ports, localWifiIPs: localWifiIPs,
                  hasFortiGateClients: !clients.isEmpty, accessPointIPs: Set(apByIP.keys), accessPointMACs: apMACs,
                  manualTypes: manual)
    }

    /// Client Wi-Fi par MAC, sinon par IP (quand un seul client la porte et que l'appareil n'a pas de MAC).
    public func client(mac: MACAddress?, ip: IPv4Address) -> Client? {
        if let mac, let client = clientsByMAC[mac] { return client }
        if mac == nil || !hasFortiGateClients { return clientsByIP[ip] }
        return nil
    }

    /// Borne branchée sur cet emplacement (nil : aucune connue).
    public func accessPoint(at location: String?) -> String? {
        guard let location else { return nil }
        return accessPointPorts[location]
    }

    // MARK: Emplacements

    /// « SW-CORE-01 · Gi1/0/12 » (même forme que `Device.switchLocation`), nil sans switch ni port.
    public static func location(switchName: String?, port: String?) -> String? {
        switch (switchName, port) {
        case let (name?, port?): return "\(name) · \(port)"
        case let (name?, nil): return name
        case let (nil, port?): return port
        default: return nil
        }
    }

    /// Faux port « Wi-Fi » d'un appareil rattaché à sa borne.
    public static func isWifiPort(_ port: String?) -> Bool {
        guard let port = port?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return port == "wi-fi" || port == "wifi" || port == "wlan"
    }

    /// Sépare « SW · port » ; « FortiAP-231F · Wi-Fi » donne la borne en nom de switch.
    static func split(_ location: String?) -> (switchName: String?, port: String?) {
        guard let location, !location.isEmpty else { return (nil, nil) }
        guard let range = location.range(of: " · ", options: .backwards) else { return (location, nil) }
        return (String(location[..<range.lowerBound]), String(location[range.upperBound...]))
    }

    /// Ports des switchs relevés qui mènent à une borne : voisin LLDP qui annonce la capacité
    /// « point d'accès », ou dont le nom ou la description est celle d'une FortiAP.
    public static func accessPointPorts(in snapshots: [SNMPSwitchSnapshot]) -> [String: String] {
        var result: [String: String] = [:]
        for snapshot in snapshots {
            for neighbor in snapshot.neighbors where isAccessPoint(neighbor) {
                guard let index = neighbor.ifIndex, let name = snapshot.interface(index)?.name else { continue }
                let location = "\(snapshot.displayName) · \(name)"
                if result[location] == nil { result[location] = neighbor.sysName.isEmpty ? "borne Wi-Fi" : neighbor.sysName }
            }
        }
        return result
    }

    /// Voisin LLDP qui est une borne Wi-Fi.
    public static func isAccessPoint(_ neighbor: SNMPLLDPNeighbor) -> Bool {
        if let capabilities = neighbor.capabilities, capabilities.contains(.accessPoint), !capabilities.contains(.router) { return true }
        let name = neighbor.sysName.lowercased()
        let descr = (neighbor.sysDescr ?? "").lowercased()
        return descr.contains("fortiap") || name.hasPrefix("fortiap") || name.hasPrefix("fap-") || name.hasPrefix("fp2") || name.hasPrefix("fp4")
    }
}

/// Classement Wi-Fi / filaire (fonctions pures).
public enum InvWireless {
    /// Durée pendant laquelle une fiche reste « déjà vue en Wi-Fi ».
    public static let memory: TimeInterval = 30 * 86_400
    /// Itinérances rapprochées regroupées en un seul événement.
    public static let roamingWindow: TimeInterval = 3600

    /// Wi-Fi ou filaire, pour un appareil vu à `to` (et auparavant à `from`, s'il a changé de port).
    /// `from` et `to` sont des emplacements « switch · port ».
    public static func classify(type: DeviceType, mac: MACAddress?, ip: IPv4Address, from: String?, to: String?,
                                remembered: InvWirelessLink?, context: InvWirelessContext, now: Date) -> InvMediumVerdict {
        // 1. Équipement d'infrastructure : son changement de port est un vrai déplacement de câble.
        if [.pointAcces, .switch, .routeur].contains(type) || context.isAccessPoint(ip: ip, mac: mac) { return .wired }
        let old = InvWirelessContext.split(from)
        let new = InvWirelessContext.split(to)
        let oldWifiAP = InvWirelessContext.isWifiPort(old.port) ? old.switchName : nil
        let newWifiAP = InvWirelessContext.isWifiPort(new.port) ? new.switchName : nil
        let recent = remembered.flatMap { now.timeIntervalSince($0.seen) <= memory ? $0 : nil }
        let apBefore = oldWifiAP ?? context.accessPoint(at: from) ?? (from == nil ? nil : recent?.apName)
        func verdict(_ reason: InvWirelessReason, client: InvWirelessContext.Client? = nil) -> InvMediumVerdict {
            InvMediumVerdict(medium: .wifi, reason: reason, apBefore: apBefore,
                             apAfter: client?.apName ?? newWifiAP ?? context.accessPoint(at: to) ?? (to == nil ? recent?.apName : nil),
                             ssid: client?.ssid ?? recent?.ssid, band: client?.band ?? recent?.band)
        }
        // 2. Client vu par la FortiGate.
        if let client = context.client(mac: mac, ip: ip) { return verdict(.fortiGateClient, client: client) }
        // 3. Ce Mac en Wi-Fi.
        if context.localWifiIPs.contains(ip) { return verdict(.thisMac) }
        // 4. Rattaché à sa borne (port « Wi-Fi »).
        if newWifiAP != nil || oldWifiAP != nil { return verdict(.wifiPort) }
        // 5. Nouveau port qui mène à une borne.
        if let ap = context.accessPoint(at: to) { return verdict(.accessPointPort(ap)) }
        // 6. Déjà vu en Wi-Fi récemment, sauf si la FortiGate, lue, ne le compte pas parmi ses clients.
        let absentFromFortiGate = context.hasFortiGateClients && mac.map { context.clientsByMAC[$0] == nil } == true
        if recent != nil, !absentFromFortiGate { return verdict(.remembered) }
        // 7. Téléphone mobile, MAC privée.
        if type == .telephone { return verdict(.mobilePhone) }
        if let mac, mac.isRandomized { return verdict(.privateMAC) }
        return .wired
    }

    /// Accès d'une fiche, à l'emplacement où elle est vue maintenant.
    public static func medium(of record: InvRecord, context: InvWirelessContext, now: Date) -> InvMediumVerdict {
        classify(type: record.type, mac: record.mac, ip: record.ip, from: nil, to: record.switchLocation,
                 remembered: record.wireless, context: context, now: now)
    }

    /// Titre de l'événement d'itinérance (« Itinérance Wi-Fi : Android passé de la borne AP-ETG2 à
    /// la borne AP-ACCUEIL »).
    public static func roamingTitle(name: String, from: String?, to: String?, apBefore: String?, apAfter: String?) -> String {
        if let apBefore, let apAfter {
            if apBefore == apAfter { return "Itinérance Wi-Fi\u{00A0}: \(name) revenu sur la borne \(apAfter)" }
            return "Itinérance Wi-Fi\u{00A0}: \(name) passé de la borne \(apBefore) à la borne \(apAfter)"
        }
        if let apAfter { return "Itinérance Wi-Fi\u{00A0}: \(name) passé sur la borne \(apAfter)" }
        let b = to.map(flat) ?? "emplacement inconnu"
        guard let from else { return "Itinérance Wi-Fi\u{00A0}: \(name) vu derrière \(b)" }
        return "Itinérance Wi-Fi\u{00A0}: \(name) vu derrière \(b) (avant\u{00A0}: \(flat(from)))"
    }

    private static func flat(_ location: String) -> String { location.replacingOccurrences(of: " · ", with: " ") }

    /// Ancien changement de port (alerte enregistrée avant la 0.27.1, sans classement Wi-Fi) d'un
    /// appareil vu en Wi-Fi, par une lecture directe, à moins de 30 jours de l'alerte : il ne compte
    /// plus dans les alertes à traiter (l'événement n'est pas réécrit). Un changement de port émis
    /// depuis a déjà été classé filaire : il compte toujours.
    public static func isWirelessMove(_ event: InvEvent, record: InvRecord?) -> Bool {
        guard event.kind == .changementPort, event.mediumChecked != true, let record else { return false }
        if [.pointAcces, .switch, .routeur].contains(record.type) { return false }
        guard let link = record.wireless else { return false }
        return abs(event.date.timeIntervalSince(link.seen)) <= memory
    }

    /// Alerte à traiter (compteur de la barre latérale et des tuiles) : critique ou alerte, pas
    /// encore traitée, hors déplacement d'un appareil Wi-Fi.
    public static func isPending(_ event: InvEvent, record: InvRecord?) -> Bool {
        event.isAlert && event.status == .aTraiter && event.severity != .info && !isWirelessMove(event, record: record)
    }
}

extension SiteScopedEvent {
    /// Alerte à traiter (hors ancien déplacement d'un appareil Wi-Fi, note 84).
    public var isPending: Bool { InvWireless.isPending(event, record: record) }
    /// Ancien changement de port d'un appareil reconnu depuis comme Wi-Fi.
    public var isWirelessMove: Bool { InvWireless.isWirelessMove(event, record: record) }
}
