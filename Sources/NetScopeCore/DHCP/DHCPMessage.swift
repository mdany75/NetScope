import Foundation

/// Type de message DHCP (option 53).
public enum DHCPMessageType: UInt8, Sendable {
    case discover = 1, offer, request, decline, ack, nak, release, inform

    public var label: String {
        switch self {
        case .discover: return "DHCPDISCOVER"
        case .offer: return "DHCPOFFER"
        case .request: return "DHCPREQUEST"
        case .decline: return "DHCPDECLINE"
        case .ack: return "DHCPACK"
        case .nak: return "DHCPNAK"
        case .release: return "DHCPRELEASE"
        case .inform: return "DHCPINFORM"
        }
    }
}

/// Construction du DHCPDISCOVER (RFC 2131 et 2132). NetScope n'envoie jamais de DHCPREQUEST :
/// aucune offre n'est acceptée, aucun bail n'est pris.
public enum DHCPDiscover {
    public static let magicCookie: [UInt8] = [0x63, 0x82, 0x53, 0x63]
    /// Options demandées (55) : masque, passerelle, DNS, domaine, bail, serveur, T1, T2, broadcast,
    /// NTP, TFTP (66), fichier d'amorçage (67), options du fabricant (43), recherche DNS (119),
    /// routes sans classe (121) et WPAD (252).
    public static let parameterRequestList: [UInt8] = [1, 3, 6, 15, 51, 54, 58, 59, 28, 42, 66, 67, 43, 119, 121, 252]
    /// Taille minimale d'un message BOOTP.
    public static let minimumLength = 300

    /// Message DHCPDISCOVER : op 1, Ethernet, `xid`, drapeau broadcast, chaddr = MAC de l'interface,
    /// options 53 (DISCOVER), 61 (identifiant client), 57 (taille maximale) et 55 (paramètres).
    public static func build(xid: UInt32, mac: MACAddress, broadcast: Bool = true) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 236)
        packet[0] = 1          // BOOTREQUEST
        packet[1] = 1          // Ethernet
        packet[2] = 6          // longueur de l'adresse matérielle
        packet[4] = UInt8(xid >> 24)
        packet[5] = UInt8(xid >> 16 & 0xFF)
        packet[6] = UInt8(xid >> 8 & 0xFF)
        packet[7] = UInt8(xid & 0xFF)
        if broadcast { packet[10] = 0x80 }   // drapeau B : réponse en broadcast (pas encore d'adresse)
        for (index, byte) in mac.bytes.enumerated() { packet[28 + index] = byte }
        packet += magicCookie
        packet += [53, 1, DHCPMessageType.discover.rawValue]
        packet += [61, 7, 1] + mac.bytes
        packet += [57, 2, 0x05, 0xDC]
        packet += [55, UInt8(parameterRequestList.count)] + parameterRequestList
        packet.append(255)
        if packet.count < minimumLength { packet += [UInt8](repeating: 0, count: minimumLength - packet.count) }
        return packet
    }

    /// Identifiant de transaction aléatoire.
    public static func randomXID() -> UInt32 { UInt32.random(in: 1...UInt32.max) }
}

/// Une réponse DHCP décodée (offre ou accusé de réception), avec toutes les options utiles.
public struct DHCPOffer: Equatable, Sendable {
    public var messageType: DHCPMessageType?
    public var xid: UInt32
    public var flagsBroadcast: Bool
    /// yiaddr : adresse proposée au client.
    public var offeredAddress: IPv4Address
    /// siaddr : serveur suivant (amorçage).
    public var nextServer: IPv4Address?
    /// giaddr : relais DHCP (offre passée par un ip helper).
    public var relayAgent: IPv4Address?
    public var clientMAC: MACAddress?
    /// Option 54.
    public var serverIdentifier: IPv4Address?
    public var subnetMask: IPv4Address?
    public var routers: [IPv4Address] = []
    public var dnsServers: [IPv4Address] = []
    public var domainName: String?
    public var leaseTime: UInt32?
    public var renewalTime: UInt32?
    public var rebindingTime: UInt32?
    public var broadcastAddress: IPv4Address?
    public var ntpServers: [IPv4Address] = []
    /// Option 66 (nom ou adresse du serveur TFTP).
    public var tftpServer: String?
    /// Option 67 (fichier d'amorçage).
    public var bootFile: String?
    /// Option 43 (données propres au fabricant), en octets bruts.
    public var vendorSpecific: [UInt8]?
    /// Champs sname et file de l'en-tête BOOTP.
    public var serverName: String?
    public var bootFileHeader: String?
    /// Codes des options présentes, dans l'ordre.
    public var optionCodes: [UInt8] = []
    /// Adresse IP source du paquet (si connue : socket ou capture).
    public var sourceAddress: IPv4Address?
    /// Adresse MAC source de la trame (capture seulement).
    public var sourceMAC: MACAddress?
    /// Délai entre l'envoi du DISCOVER et la réception.
    public var delay: TimeInterval?

    public init(messageType: DHCPMessageType?, xid: UInt32, flagsBroadcast: Bool, offeredAddress: IPv4Address) {
        self.messageType = messageType
        self.xid = xid
        self.flagsBroadcast = flagsBroadcast
        self.offeredAddress = offeredAddress
    }

    /// Adresse du serveur : option 54, sinon l'adresse source.
    public var server: IPv4Address? { serverIdentifier ?? sourceAddress }

    /// Réseau distribué (adresse proposée et masque).
    public var subnet: Subnet? {
        guard let prefix = subnetMask?.prefixLength else { return nil }
        return Subnet(address: offeredAddress, prefix: prefix)
    }

    /// « 24 h », « 2 h », « 1 h 45 », « 45 min », « 3 j 12 h », « 8 j », « infini ».
    public static func leaseText(_ seconds: UInt32?) -> String {
        guard let seconds else { return "—" }
        if seconds == UInt32.max { return "infini" }
        let s = Int(seconds)
        if s < 120 { return "\(s)\u{00A0}s" }
        if s < 3600 { return "\(s / 60)\u{00A0}min" }
        if s >= 4 * 86_400 && s % 86_400 == 0 { return "\(s / 86_400)\u{00A0}j" }
        let hours = s / 3600, minutes = (s % 3600) / 60
        if hours >= 72 { return "\(hours / 24)\u{00A0}j \(hours % 24)\u{00A0}h" }
        return minutes == 0 ? "\(hours)\u{00A0}h" : "\(hours)\u{00A0}h\u{00A0}" + String(format: "%02d", minutes)
    }

    /// Option 43 en hexadécimal (« 01 04 0A B6 7A 02 »).
    public var vendorSpecificHex: String? { vendorSpecific.map { CaptureBytes.hex($0[...]) } }
}

/// Décodage des messages DHCP (charge UDP) et des trames capturées qui les portent.
public enum DHCPParser {
    /// Décode une réponse du serveur (op 2) ; nil si ce n'est pas un message DHCP valide.
    public static func parse(_ payload: [UInt8]) -> DHCPOffer? {
        guard payload.count >= 240, payload[0] == 2, payload[1] == 1,
              Array(payload[236..<240]) == DHCPDiscover.magicCookie else { return nil }
        let xid = CaptureBytes.u32(payload, 4)
        var offer = DHCPOffer(messageType: nil, xid: xid, flagsBroadcast: payload[10] & 0x80 != 0,
                              offeredAddress: IPv4Address(CaptureBytes.u32(payload, 16)))
        let siaddr = CaptureBytes.u32(payload, 20)
        let giaddr = CaptureBytes.u32(payload, 24)
        offer.nextServer = siaddr == 0 ? nil : IPv4Address(siaddr)
        offer.relayAgent = giaddr == 0 ? nil : IPv4Address(giaddr)
        if payload[2] == 6 { offer.clientMAC = MACAddress(bytes: Array(payload[28..<34])) }

        var overload: UInt8 = 0
        readOptions(payload, from: 240, into: &offer, overload: &overload)
        // Option 52 : les champs file (1) et sname (2) contiennent d'autres options.
        if overload & 1 != 0 { readOptions(Array(payload[108..<236]), from: 0, into: &offer, overload: &overload) }
        else { offer.bootFileHeader = cString(payload[108..<236]) }
        if overload & 2 != 0 { readOptions(Array(payload[44..<108]), from: 0, into: &offer, overload: &overload) }
        else { offer.serverName = cString(payload[44..<108]) }
        guard offer.messageType != nil else { return nil }
        return offer
    }

    private static func readOptions(_ bytes: [UInt8], from start: Int, into offer: inout DHCPOffer, overload: inout UInt8) {
        var i = start
        while i < bytes.count {
            let code = bytes[i]
            if code == 0 { i += 1; continue }
            if code == 255 { break }
            guard i + 1 < bytes.count else { break }
            let length = Int(bytes[i + 1])
            let start = i + 2, end = start + length
            guard end <= bytes.count else { break }
            let value = Array(bytes[start..<end])
            offer.optionCodes.append(code)
            switch code {
            case 1: offer.subnetMask = address(value)
            case 3: offer.routers = addresses(value)
            case 6: offer.dnsServers = addresses(value)
            case 15: offer.domainName = text(value)
            case 28: offer.broadcastAddress = address(value)
            case 42: offer.ntpServers = addresses(value)
            case 43: offer.vendorSpecific = value
            case 51: offer.leaseTime = length == 4 ? CaptureBytes.u32(value, 0) : nil
            case 52: overload = length >= 1 ? value[0] : 0
            case 53: offer.messageType = length >= 1 ? DHCPMessageType(rawValue: value[0]) : nil
            case 54: offer.serverIdentifier = address(value)
            case 58: offer.renewalTime = length == 4 ? CaptureBytes.u32(value, 0) : nil
            case 59: offer.rebindingTime = length == 4 ? CaptureBytes.u32(value, 0) : nil
            case 66: offer.tftpServer = text(value)
            case 67: offer.bootFile = text(value)
            default: break
            }
            i = end
        }
    }

    private static func address(_ value: [UInt8]) -> IPv4Address? {
        value.count >= 4 ? IPv4Address(CaptureBytes.u32(value, 0)) : nil
    }

    private static func addresses(_ value: [UInt8]) -> [IPv4Address] {
        stride(from: 0, to: value.count - value.count % 4, by: 4).map { IPv4Address(CaptureBytes.u32(value, $0)) }
    }

    private static func text(_ value: [UInt8]) -> String? {
        let cleaned = CaptureBytes.text(value.prefix { $0 != 0 }[...])
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cString(_ slice: ArraySlice<UInt8>) -> String? {
        text(Array(slice))
    }

    /// Décode une trame Ethernet capturée : IPv4, UDP 67 → 68, puis le message DHCP.
    /// L'adresse MAC et l'adresse IP sources sont reprises de la trame.
    public static func parseFrame(_ frame: [UInt8]) -> DHCPOffer? {
        guard let ethernet = EthernetHeader.parse(frame), ethernet.typeOrLength == 0x0800 else { return nil }
        let ip = ethernet.payloadOffset
        guard frame.count >= ip + 20, frame[ip] >> 4 == 4, frame[ip + 9] == 17 else { return nil }
        let headerLength = Int(frame[ip] & 0x0F) * 4
        guard CaptureBytes.u16(frame, ip + 6) & 0x1FFF == 0, frame[ip + 6] & 0x20 == 0 else { return nil } // fragment
        let udp = ip + headerLength
        guard frame.count >= udp + 8, CaptureBytes.u16(frame, udp) == 67, CaptureBytes.u16(frame, udp + 2) == 68 else { return nil }
        let udpLength = Int(CaptureBytes.u16(frame, udp + 4))
        let end = min(frame.count, udp + max(udpLength, 8))
        guard var offer = parse(Array(frame[(udp + 8)..<end])) else { return nil }
        offer.sourceAddress = IPv4Address(CaptureBytes.u32(frame, ip + 12))
        offer.sourceMAC = ethernet.source
        return offer
    }
}

/// Serveurs DHCP attendus sur le segment, réglés par l'utilisateur.
public struct DHCPServerPolicy: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Dans la liste des serveurs autorisés.
        case expected
        /// Hors de la liste : serveur non autorisé (routeur domestique, mauvaise configuration…).
        case unauthorized
        /// Aucune liste réglée : impossible de juger.
        case unchecked
    }

    public var allowed: [IPv4Address]
    /// Entrées illisibles de la saisie.
    public var invalid: [String]

    /// Liste séparée par des virgules, des points-virgules ou des espaces.
    public init(text: String) {
        var allowed: [IPv4Address] = []
        var invalid: [String] = []
        for token in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" }) {
            let entry = token.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            if let ip = IPv4Address(entry) {
                if !allowed.contains(ip) { allowed.append(ip) }
            } else {
                invalid.append(entry)
            }
        }
        self.allowed = allowed
        self.invalid = invalid
    }

    public func status(of offer: DHCPOffer) -> Status {
        guard !allowed.isEmpty else { return .unchecked }
        let candidates = [offer.serverIdentifier, offer.sourceAddress].compactMap { $0 }
        return candidates.contains(where: allowed.contains) ? .expected : .unauthorized
    }

    /// Une offre par serveur (la première reçue), dans l'ordre d'arrivée, pour le `xid` attendu.
    public static func uniqueServers(_ offers: [DHCPOffer], xid: UInt32) -> [DHCPOffer] {
        var seen: Set<UInt32> = []
        var result: [DHCPOffer] = []
        for offer in offers where offer.xid == xid && (offer.messageType == .offer || offer.messageType == .ack) {
            let key = offer.server?.value ?? 0
            if seen.insert(key).inserted {
                result.append(offer)
            } else if let index = result.firstIndex(where: { ($0.server?.value ?? 0) == key }) {
                // Même serveur reçu deux fois (socket et capture) : on complète la MAC source.
                if result[index].sourceMAC == nil { result[index].sourceMAC = offer.sourceMAC }
            }
        }
        return result
    }
}
