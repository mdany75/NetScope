import Foundation

/// Le switch (ou l'équipement) voisin annoncé par LLDP ou CDP : où ce Mac est branché.
public struct NetworkNeighbor: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case lldp = "LLDP"
        case cdp = "CDP"
    }

    /// Protocoles reçus (LLDP, CDP ou les deux, fusionnés).
    public var protocols: [Source]
    public var chassisID: String?
    public var systemName: String?
    public var portID: String?
    public var portDescription: String?
    public var systemDescription: String?
    /// Modèle (LLDP-MED, plateforme CDP ou début de la description du système).
    public var model: String?
    public var softwareVersion: String?
    /// VLAN natif (PVID 802.1 ou Native VLAN CDP).
    public var nativeVLAN: Int?
    /// VLAN voix (LLDP-MED Network Policy ou Appliance VLAN CDP).
    public var voiceVLAN: Int?
    public var vlanNames: [String]
    public var managementAddresses: [String]
    /// Capacités actives (« Bridge », « Router »…).
    public var capabilities: [String]
    /// Résumé PoE (« 802.3at · non utilisé », « 15,4 W alloués »).
    public var poe: String?
    /// Type de lien négocié (MAU 802.3) : « 1000BASE-T duplex intégral ».
    public var link: String?
    public var duplex: String?
    public var maxFrameSize: Int?
    public var vtpDomain: String?
    /// Durée de validité annoncée (TTL), en secondes.
    public var ttl: Int?
    /// MAC source de la trame (port du switch).
    public var sourceMAC: String?
    public var receivedAt: Date?
    /// Interface de ce Mac qui a reçu la trame.
    public var interface: String?

    public init(protocols: [Source], chassisID: String? = nil, systemName: String? = nil, portID: String? = nil,
                portDescription: String? = nil, systemDescription: String? = nil, model: String? = nil,
                softwareVersion: String? = nil, nativeVLAN: Int? = nil, voiceVLAN: Int? = nil, vlanNames: [String] = [],
                managementAddresses: [String] = [], capabilities: [String] = [], poe: String? = nil, link: String? = nil,
                duplex: String? = nil, maxFrameSize: Int? = nil, vtpDomain: String? = nil, ttl: Int? = nil,
                sourceMAC: String? = nil, receivedAt: Date? = nil, interface: String? = nil) {
        self.protocols = protocols
        self.chassisID = chassisID
        self.systemName = systemName
        self.portID = portID
        self.portDescription = portDescription
        self.systemDescription = systemDescription
        self.model = model
        self.softwareVersion = softwareVersion
        self.nativeVLAN = nativeVLAN
        self.voiceVLAN = voiceVLAN
        self.vlanNames = vlanNames
        self.managementAddresses = managementAddresses
        self.capabilities = capabilities
        self.poe = poe
        self.link = link
        self.duplex = duplex
        self.maxFrameSize = maxFrameSize
        self.vtpDomain = vtpDomain
        self.ttl = ttl
        self.sourceMAC = sourceMAC
        self.receivedAt = receivedAt
        self.interface = interface
    }

    /// Nom du switch : nom système, sinon identifiant du châssis.
    public var switchLabel: String { systemName ?? chassisID ?? "Switch sans nom" }

    /// Port : identifiant du port, sinon sa description.
    public var portLabel: String? { portID ?? portDescription }

    /// « SW-ETG2-01 · port 1/22 · VLAN 1 »
    public var headline: String {
        var parts = [switchLabel]
        if let port = portLabel { parts.append("port \(port)") }
        if let vlan = nativeVLAN { parts.append("VLAN \(vlan)") }
        return parts.joined(separator: " · ")
    }

    public var protocolLabel: String { protocols.map(\.rawValue).joined(separator: " et ") }

    /// Fusionne deux annonces du même voisin (LLDP d'abord, CDP pour compléter).
    public func merged(with other: NetworkNeighbor) -> NetworkNeighbor {
        var result = self
        for source in other.protocols where !result.protocols.contains(source) { result.protocols.append(source) }
        result.chassisID = chassisID ?? other.chassisID
        result.systemName = systemName ?? other.systemName
        result.portID = portID ?? other.portID
        result.portDescription = portDescription ?? other.portDescription
        result.systemDescription = systemDescription ?? other.systemDescription
        result.model = model ?? other.model
        result.softwareVersion = softwareVersion ?? other.softwareVersion
        result.nativeVLAN = nativeVLAN ?? other.nativeVLAN
        result.voiceVLAN = voiceVLAN ?? other.voiceVLAN
        result.vlanNames = vlanNames.isEmpty ? other.vlanNames : vlanNames
        for address in other.managementAddresses where !result.managementAddresses.contains(address) {
            result.managementAddresses.append(address)
        }
        result.capabilities = capabilities.isEmpty ? other.capabilities : capabilities
        result.poe = poe ?? other.poe
        result.link = link ?? other.link
        result.duplex = duplex ?? other.duplex
        result.maxFrameSize = maxFrameSize ?? other.maxFrameSize
        result.vtpDomain = vtpDomain ?? other.vtpDomain
        result.ttl = ttl ?? other.ttl
        result.sourceMAC = sourceMAC ?? other.sourceMAC
        result.interface = interface ?? other.interface
        if let a = receivedAt, let b = other.receivedAt { result.receivedAt = max(a, b) } else { result.receivedAt = receivedAt ?? other.receivedAt }
        return result
    }

    /// Même équipement ? (nom système, sinon châssis ou MAC source.)
    public func isSameDevice(as other: NetworkNeighbor) -> Bool {
        func key(_ value: String?) -> String? { value?.lowercased().split(separator: ".").first.map(String.init) }
        if let a = key(systemName), let b = key(other.systemName) { return a == b }
        if let a = sourceMAC, let b = other.sourceMAC, a == b { return true }
        if let a = chassisID, let b = other.chassisID { return a == b }
        return false
    }
}

/// Décodage d'une trame capturée : LLDP, CDP, ou rien.
public enum NeighborFrameDecoder {
    public static let lldpMulticast = MACAddress(value: 0x0180_C200_000E)
    public static let cdpMulticast = MACAddress(value: 0x0100_0CCC_CCCC)

    public static func decode(_ frame: [UInt8], date: Date? = nil, interface: String? = nil) -> NetworkNeighbor? {
        guard let ethernet = EthernetHeader.parse(frame) else { return nil }
        var neighbor: NetworkNeighbor?
        if ethernet.typeOrLength == 0x88CC {
            neighbor = LLDPDecoder.decode(Array(frame[ethernet.payloadOffset...]))
        } else if ethernet.isLLC, ethernet.destination == cdpMulticast {
            neighbor = CDPDecoder.decodeLLC(Array(frame[ethernet.payloadOffset...]))
        }
        guard var result = neighbor else { return nil }
        result.sourceMAC = ethernet.source.formatted(.upperColon)
        result.receivedAt = date
        result.interface = interface
        return result
    }

    /// Voisins distincts d'une liste de trames, les annonces d'un même équipement fusionnées.
    public static func neighbors(in frames: [CapturedFrame], interface: String? = nil, now: Date = Date()) -> [NetworkNeighbor] {
        var result: [NetworkNeighbor] = []
        for frame in frames {
            guard let neighbor = decode(frame.bytes, date: frame.date ?? now, interface: interface) else { continue }
            if let index = result.firstIndex(where: { $0.isSameDevice(as: neighbor) }) {
                // L'annonce LLDP reste la base ; la plus récente du même protocole la remplace.
                let existing = result[index]
                if existing.protocols.first == neighbor.protocols.first {
                    result[index] = neighbor.merged(with: existing)
                } else if neighbor.protocols.first == .lldp {
                    result[index] = neighbor.merged(with: existing)
                } else {
                    result[index] = existing.merged(with: neighbor)
                }
            } else {
                result.append(neighbor)
            }
        }
        return result
    }
}
