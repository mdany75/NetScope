import Foundation

// Modèles de la lecture d'une FortiGate (contrôleur des FortiSwitch gérés par FortiLink).
// NetScope ne parle qu'à la FortiGate : les FortiSwitch (10.255.1.0/24 par défaut) ne sont pas
// joignables depuis le LAN et ne sont jamais interrogés directement.

/// Réglages de connexion (le jeton est à part, au Trousseau).
public struct FortiGateConfig: Codable, Hashable, Sendable {
    /// Adresse IP ou nom de la FortiGate (sans « https:// »).
    public var host: String
    public var port: Int
    /// Domaine virtuel (VDOM) ; vide : celui de l'administrateur API.
    public var vdom: String
    /// Empreinte SHA-256 du certificat acceptée par l'utilisateur (« AB:CD:… »), nil avant le
    /// premier contact.
    public var pinnedFingerprint: String?
    /// Délai par requête, en secondes.
    public var timeout: Double

    public init(host: String = "", port: Int = 443, vdom: String = "", pinnedFingerprint: String? = nil, timeout: Double = 8) {
        self.host = host
        self.port = port
        self.vdom = vdom
        self.pinnedFingerprint = pinnedFingerprint
        self.timeout = timeout
    }

    /// Adresse nettoyée : sans schéma, sans chemin, sans espaces.
    public var cleanHost: String {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        // « 10.0.0.1:8443 » saisi dans le champ adresse : le port est lu à part.
        if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text
    }

    /// Port saisi avec l'adresse (« 10.0.0.1:8443 »), sinon `port`.
    public var effectivePort: Int {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":"),
           let p = Int(text[text.index(after: colon)...]), (1...65_535).contains(p) {
            return p
        }
        return (1...65_535).contains(port) ? port : 443
    }

    /// Adresse et port valides (nom d'hôte ou IPv4, sans caractère interdit).
    public var isValid: Bool {
        let h = cleanHost
        guard !h.isEmpty, h.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return h.unicodeScalars.allSatisfy { allowed.contains($0) } && (1...65_535).contains(effectivePort)
    }
}

/// /api/v2/monitor/system/status
public struct FortiGateSystem: Codable, Hashable, Sendable {
    public var hostname: String
    /// « FortiGate-100F ».
    public var model: String
    public var serial: String
    /// « v7.4.4 ».
    public var version: String
    public var build: Int?
    public var vdom: String?

    public init(hostname: String, model: String, serial: String, version: String, build: Int? = nil, vdom: String? = nil) {
        self.hostname = hostname
        self.model = model
        self.serial = serial
        self.version = version
        self.build = build
        self.vdom = vdom
    }

    /// « FortiOS v7.4.4 (build 2662) ».
    public var versionLabel: String {
        let v = version.isEmpty ? "version inconnue" : version
        return "FortiOS \(v)" + (build.map { " (build \($0))" } ?? "")
    }

    /// Version majeure et mineure (7, 4), si lisible.
    public var majorMinor: (Int, Int)? {
        let parts = version.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v ")).split(separator: ".")
        guard parts.count >= 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }
}

/// Port d'un FortiSwitch géré.
public struct FortiSwitchPort: Codable, Hashable, Sendable {
    public var name: String
    /// Numéro du port (« port12 » → 12), sert d'index d'interface.
    public var number: Int
    /// Lien actif (état opérationnel) ; nil si inconnu.
    public var linkUp: Bool?
    /// Port activé par l'administrateur (configuration) ; nil si inconnu.
    public var adminUp: Bool?
    public var speedMbps: UInt64?
    public var duplex: String?
    /// VLAN natif : nom de l'interface VLAN de la FortiGate (« vlan40 », « _default »).
    public var nativeVLAN: String?
    /// Identifiant du VLAN natif s'il est connu ou déductible du nom.
    public var nativeVLANID: Int?
    public var description: String?
    public var poeCapable: Bool?
    public var poeEnabled: Bool?
    /// État PoE tel que donné par FortiOS (« Delivering Power », « Searching »…).
    public var poeState: String?
    public var poePowerW: Double?
    public var poeClass: Int?
    /// Port FortiLink (vers la FortiGate) ou lien inter-switch (ISL).
    public var isFortiLink: Bool
    public var isISL: Bool
    /// Équipement en face d'un lien FortiLink ou ISL.
    public var peerName: String?
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public var rxErrors: UInt64?

    public init(name: String, number: Int, linkUp: Bool? = nil, adminUp: Bool? = nil, speedMbps: UInt64? = nil, duplex: String? = nil,
                nativeVLAN: String? = nil, nativeVLANID: Int? = nil, description: String? = nil, poeCapable: Bool? = nil,
                poeEnabled: Bool? = nil, poeState: String? = nil, poePowerW: Double? = nil, poeClass: Int? = nil,
                isFortiLink: Bool = false, isISL: Bool = false, peerName: String? = nil,
                rxBytes: UInt64? = nil, txBytes: UInt64? = nil, rxErrors: UInt64? = nil) {
        self.name = name
        self.number = number
        self.linkUp = linkUp
        self.adminUp = adminUp
        self.speedMbps = speedMbps
        self.duplex = duplex
        self.nativeVLAN = nativeVLAN
        self.nativeVLANID = nativeVLANID
        self.description = description
        self.poeCapable = poeCapable
        self.poeEnabled = poeEnabled
        self.poeState = poeState
        self.poePowerW = poePowerW
        self.poeClass = poeClass
        self.isFortiLink = isFortiLink
        self.isISL = isISL
        self.peerName = peerName
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxErrors = rxErrors
    }

    /// Lien vers la FortiGate ou un autre FortiSwitch : jamais un port d'accès.
    public var isUplink: Bool { isFortiLink || isISL }

    /// État PoE ramené à POWER-ETHERNET-MIB.
    public var poeDetection: PoEDetectionStatus? {
        if poeEnabled == false { return .disabled }
        if let state = poeState?.lowercased() {
            if state.contains("deliver") || state.contains("power on") || state == "on" { return .deliveringPower }
            if state.contains("search") || state.contains("detect") || state.contains("no device") { return .searching }
            if state.contains("disable") || state == "off" { return .disabled }
            if state.contains("fault") || state.contains("error") || state.contains("overload") { return .fault }
        }
        if let w = poePowerW { return w > 0.05 ? .deliveringPower : (poeCapable == true ? .searching : nil) }
        return poeCapable == true ? .searching : nil
    }
}

/// FortiSwitch géré par la FortiGate.
public struct FortiManagedSwitch: Codable, Hashable, Sendable, Identifiable {
    public var id: String { switchID }
    /// Identifiant du switch sur la FortiGate (« switch-id », souvent le numéro de série ou un nom).
    public var switchID: String
    public var serial: String
    /// Nom donné sur la FortiGate (« name » ou description courte), sinon l'identifiant.
    public var name: String
    /// « FS-248E-POE ».
    public var model: String
    /// « S248EP-v7.2.5-build0453,230920 (GA) ».
    public var osVersion: String
    /// Connecté à la FortiGate (« Connected », « Up »).
    public var connected: Bool?
    /// État d'autorisation (« Authorized », « Discovered »).
    public var state: String?
    /// Adresse FortiLink (10.255.1.x par défaut), non joignable depuis le Mac.
    public var fortilinkIP: IPv4Address?
    public var description: String?
    public var poeBudgetW: Double?
    public var ports: [FortiSwitchPort]

    public init(switchID: String, serial: String = "", name: String = "", model: String = "", osVersion: String = "",
                connected: Bool? = nil, state: String? = nil, fortilinkIP: IPv4Address? = nil, description: String? = nil,
                poeBudgetW: Double? = nil, ports: [FortiSwitchPort] = []) {
        self.switchID = switchID
        self.serial = serial
        self.name = name.isEmpty ? switchID : name
        self.model = model
        self.osVersion = osVersion
        self.connected = connected
        self.state = state
        self.fortilinkIP = fortilinkIP
        self.description = description
        self.poeBudgetW = poeBudgetW
        self.ports = ports
    }

    /// Version du logiciel : « v7.2.5 » tiré de « S248EP-v7.2.5-build0453 ».
    public var firmware: String {
        if let range = osVersion.range(of: #"v\d+\.\d+(\.\d+)?"#, options: .regularExpression) { return String(osVersion[range]) }
        return osVersion
    }

    /// Clés par lesquelles les autres réponses désignent ce switch (identifiant, série, nom).
    public var keys: Set<String> {
        Set([switchID, serial, name].map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    public func port(named name: String) -> FortiSwitchPort? {
        let key = name.lowercased()
        return ports.first { $0.name.lowercased() == key }
    }
}

/// Appareil vu sur un port de FortiSwitch (/monitor/switch-controller/detected-device).
public struct FortiDetectedDevice: Codable, Hashable, Sendable {
    public var mac: MACAddress
    public var switchID: String
    public var portName: String
    public var vlan: Int?
    public var lastSeen: Date?
    public var ip: IPv4Address?
    public var name: String?

    public init(mac: MACAddress, switchID: String, portName: String, vlan: Int? = nil, lastSeen: Date? = nil,
                ip: IPv4Address? = nil, name: String? = nil) {
        self.mac = mac
        self.switchID = switchID
        self.portName = portName
        self.vlan = vlan
        self.lastSeen = lastSeen
        self.ip = ip
        self.name = name
    }
}

/// Ligne de la table ARP de la FortiGate.
public struct FortiARPEntry: Codable, Hashable, Sendable {
    public var ip: IPv4Address
    public var mac: MACAddress
    public var interface: String?

    public init(ip: IPv4Address, mac: MACAddress, interface: String? = nil) {
        self.ip = ip
        self.mac = mac
        self.interface = interface
    }
}

/// Bail DHCP distribué par la FortiGate.
public struct FortiDHCPLease: Codable, Hashable, Sendable {
    public var ip: IPv4Address
    public var mac: MACAddress
    public var hostname: String?
    public var interface: String?
    public var expires: Date?
    public var reserved: Bool

    public init(ip: IPv4Address, mac: MACAddress, hostname: String? = nil, interface: String? = nil, expires: Date? = nil,
                reserved: Bool = false) {
        self.ip = ip
        self.mac = mac
        self.hostname = hostname
        self.interface = interface
        self.expires = expires
        self.reserved = reserved
    }
}

/// Appareil de l'inventaire de la FortiGate (/monitor/user/device/query).
public struct FortiUserDevice: Codable, Hashable, Sendable {
    public var mac: MACAddress
    public var ip: IPv4Address?
    public var hostname: String?
    public var vendor: String?
    public var os: String?
    public var switchID: String?
    public var portName: String?
    public var vlan: Int?

    public init(mac: MACAddress, ip: IPv4Address? = nil, hostname: String? = nil, vendor: String? = nil, os: String? = nil,
                switchID: String? = nil, portName: String? = nil, vlan: Int? = nil) {
        self.mac = mac
        self.ip = ip
        self.hostname = hostname
        self.vendor = vendor
        self.os = os
        self.switchID = switchID
        self.portName = portName
        self.vlan = vlan
    }
}

/// Un appel de l'API et son résultat (pour le diagnostic et la réponse brute copiable).
public struct FortiCallRecord: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case ok, absent, refused, failed, skipped
    }

    public var path: String
    public var status: Int?
    public var outcome: Outcome
    /// Explication en français (vide si tout va bien).
    public var message: String
    /// Corps de la réponse, tronqué et sans le jeton.
    public var body: String
    public var items: Int?

    public init(path: String, status: Int?, outcome: Outcome, message: String = "", body: String = "", items: Int? = nil) {
        self.path = path
        self.status = status
        self.outcome = outcome
        self.message = message
        self.body = body
        self.items = items
    }
}

/// Tout ce que la FortiGate a renvoyé lors d'une lecture.
public struct FortiGateReport: Codable, Hashable, Sendable {
    public var system: FortiGateSystem
    public var switches: [FortiManagedSwitch]
    public var detected: [FortiDetectedDevice]
    public var arp: [FortiARPEntry]
    public var dhcp: [FortiDHCPLease]
    public var userDevices: [FortiUserDevice]
    public var calls: [FortiCallRecord]
    public var readAt: Date

    public init(system: FortiGateSystem, switches: [FortiManagedSwitch] = [], detected: [FortiDetectedDevice] = [],
                arp: [FortiARPEntry] = [], dhcp: [FortiDHCPLease] = [], userDevices: [FortiUserDevice] = [],
                calls: [FortiCallRecord] = [], readAt: Date = Date()) {
        self.system = system
        self.switches = switches
        self.detected = detected
        self.arp = arp
        self.dhcp = dhcp
        self.userDevices = userDevices
        self.calls = calls
        self.readAt = readAt
    }

    /// Nom à afficher pour le contrôleur (« FGT-SIEGE »).
    public var controllerName: String {
        system.hostname.isEmpty ? (system.model.isEmpty ? "FortiGate" : system.model) : system.hostname
    }

    /// Appareils localisés sur un port (détectés, sinon inventaire de la FortiGate).
    public var locatedDevices: [FortiDetectedDevice] {
        var byMAC: [MACAddress: FortiDetectedDevice] = [:]
        for device in userDevices {
            guard let id = device.switchID, let port = device.portName else { continue }
            byMAC[device.mac] = FortiDetectedDevice(mac: device.mac, switchID: id, portName: port, vlan: device.vlan, ip: device.ip,
                                                    name: device.hostname)
        }
        // detected-device fait foi (table MAC des switchs) ; l'inventaire complète.
        for device in detected { byMAC[device.mac] = device }
        return byMAC.values.sorted { ($0.switchID, $0.portName, $0.mac.value) < ($1.switchID, $1.portName, $1.mac.value) }
    }
}
