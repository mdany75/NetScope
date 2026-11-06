import Foundation

/// Sondes UDP propres à chaque protocole (note 69). Fonctions pures : aucun réseau, octets testés
/// dans NetScopeSelfTest.
public enum UDPProbePayload {
    /// Ce qu'il faut savoir pour construire les paquets d'un port.
    public struct Context: Sendable {
        public var target: IPv4Address
        /// Adresse et port locaux de la socket (Via et Contact de SIP).
        public var localAddress: IPv4Address?
        public var localPort: UInt16
        /// Identifiant de transaction (DNS, NetBIOS, mDNS, SNMP).
        public var transactionID: UInt16
        public var snmpCommunity: String?
        public var ntpControlChecks: Bool
        /// Jeton aléatoire (nom du fichier TFTP, branche et étiquette SIP).
        public var nonce: String

        public init(target: IPv4Address, localAddress: IPv4Address? = nil, localPort: UInt16 = 0, transactionID: UInt16 = 0x4E53,
                    snmpCommunity: String? = nil, ntpControlChecks: Bool = true, nonce: String = "4e5331") {
            self.target = target
            self.localAddress = localAddress
            self.localPort = localPort
            self.transactionID = transactionID
            self.snmpCommunity = snmpCommunity
            self.ntpControlChecks = ntpControlChecks
            self.nonce = nonce
        }
    }

    /// Paquets envoyés à un port, dans l'ordre.
    public static func packets(for service: UDPService, context: Context) -> [[UInt8]] {
        let id = context.transactionID
        switch service {
        case .dns:
            return [dnsVersionBind(id: id), dnsLocalhost(id: id &+ 1)]
        case .tftp:
            return [tftpReadRequest(file: "netscope-sonde-\(context.nonce).txt")]
        case .ntp:
            var list = [ntpClientRequest(transmit: ntpTimestamp(Date()))]
            if context.ntpControlChecks { list += [ntpReadVariables(sequence: id), ntpMonlistRequest] }
            return list
        case .netbios:
            return [NamesNetBIOS.nodeStatusQuery(id: id)]
        case .snmp:
            var list = [snmpV3Discovery(messageID: Int32(id))]
            if let community = context.snmpCommunity, !community.isEmpty {
                list.append(snmpGetSysDescr(community: community, requestID: Int32(id) + 1))
            }
            return list
        case .ipmi:
            return [ipmiChannelAuthCapabilities]
        case .ssdp:
            return [ssdpSearch(target: context.target)]
        case .sip:
            return [sipOptions(target: context.target, local: context.localAddress, localPort: context.localPort, nonce: context.nonce)]
        case .mdns:
            return [mdnsServicesQuery(id: id)]
        }
    }

    // MARK: DNS (53)

    /// version.bind, classe CHAOS, type TXT, sans récursion : BIND, Unbound, dnsmasq, PowerDNS
    /// donnent leur version (ou un refus, qui prouve aussi que le port est ouvert).
    public static func dnsVersionBind(id: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [7] + Array("version".utf8) + [4] + Array("bind".utf8) + [0]
        bytes += [0x00, 0x10, 0x00, 0x03]
        return bytes
    }

    /// A de « localhost. » avec récursion : un résolveur répond sans rien demander à l'extérieur (RFC 6761).
    public static func dnsLocalhost(id: UInt16) -> [UInt8] {
        (try? DNSMessageCodec.query(name: "localhost.", type: .a, id: id)) ?? []
    }

    // MARK: NTP (123)

    /// Requête client NTPv4 (LI 0, VN 4, mode 3), 48 octets, heure d'envoi dans « transmit ».
    public static func ntpClientRequest(transmit: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 48)
        bytes[0] = 0x23
        for index in 0..<8 { bytes[40 + index] = UInt8((transmit >> (56 - 8 * UInt64(index))) & 0xFF) }
        return bytes
    }

    /// Horodatage NTP (secondes depuis 1900 et fraction sur 32 bits).
    public static func ntpTimestamp(_ date: Date) -> UInt64 {
        let seconds = date.timeIntervalSince1970 + 2_208_988_800
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let whole = UInt64(seconds)
        let fraction = UInt64((seconds - Double(whole)) * 4_294_967_296)
        return (whole << 32) | (fraction & 0xFFFF_FFFF)
    }

    /// Mode 6 (contrôle, ntpq) READVAR de l'association 0 : version, système, strate.
    public static func ntpReadVariables(sequence: UInt16) -> [UInt8] {
        [0x16, 0x02, UInt8(sequence >> 8), UInt8(sequence & 0xFF), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    }

    /// Mode 7 (privé, ntpdc) MON_GETLIST_1, la requête « monlist » des attaques par amplification
    /// (même charge que nmap ntp-monlist) : implémentation XNTPD (3), requête 42.
    public static let ntpMonlistRequest: [UInt8] = [0x17, 0x00, 0x03, 0x2A] + [UInt8](repeating: 0, count: 4)

    // MARK: SNMP (161)

    /// Découverte SNMP v3 (RFC 3414 4) : GetRequest vide, sans utilisateur ni secret. Tout agent v3
    /// répond par un rapport qui porte son engineID.
    public static func snmpV3Discovery(messageID: Int32) -> [UInt8] {
        let pdu = SNMPPDU(type: .getRequest, requestID: messageID, varbinds: [])
        return (try? SNMPv3Codec.encode(msgID: messageID, pdu: pdu, usm: SNMPUSMParameters(), level: .noAuthNoPriv,
                                         contextEngineID: [], contextName: "")) ?? []
    }

    /// GetRequest v2c de sysDescr.0 avec la communauté choisie.
    public static func snmpGetSysDescr(community: String, requestID: Int32) -> [UInt8] {
        let pdu = SNMPPDU(type: .getRequest, requestID: requestID, varbinds: [SNMPVarBind(oid: sysDescrOID)])
        return SNMPMessage(community: community, pdu: pdu).encoded()
    }

    public static let sysDescrOID: SNMPOID = "1.3.6.1.2.1.1.1.0"

    // MARK: TFTP (69)

    /// Lecture d'un fichier qui n'existe pas : le serveur répond par une erreur (code 1), d'un
    /// nouveau port. Rien n'est écrit sur le serveur.
    public static func tftpReadRequest(file: String) -> [UInt8] {
        TFTPPacket.request(TFTPRequest(kind: .read, filename: file, mode: .octet)).encoded()
    }

    /// Erreur envoyée au serveur pour arrêter un transfert si le fichier existait par hasard.
    public static let tftpAbort: [UInt8] = TFTPPacket.error(code: .notDefined, message: "NetScope : sonde terminee").encoded()

    // MARK: IPMI (623)

    /// RMCP + IPMI 1.5 sans session : Get Channel Authentication Capabilities (NetFn App, 0x38),
    /// canal courant (0x0E) avec le bit IPMI 2.0, niveau administrateur. Somme de contrôle comprise.
    public static let ipmiChannelAuthCapabilities: [UInt8] = [
        0x06, 0x00, 0xFF, 0x07,                         // RMCP v1.0, séquence 0xFF (pas d'accusé), classe IPMI
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // authentification aucune, séquence 0, session 0
        0x09,                                           // longueur du message
        0x20, 0x18, 0xC8, 0x81, 0x00, 0x38, 0x8E, 0x04, 0xB5,
    ]

    /// Somme de contrôle IPMI (complément à deux de la somme des octets).
    public static func ipmiChecksum(_ bytes: [UInt8]) -> UInt8 {
        UInt8((0x100 - bytes.reduce(0) { ($0 + Int($1)) & 0xFF }) & 0xFF)
    }

    // MARK: SSDP (1900)

    /// M-SEARCH en envoi direct (RFC UPnP 1.1, « unicast M-SEARCH ») : une seule réponse attendue.
    public static func ssdpSearch(target: IPv4Address) -> [UInt8] {
        let text = "M-SEARCH * HTTP/1.1\r\nHOST: \(target):1900\r\nMAN: \"ssdp:discover\"\r\nST: upnp:rootdevice\r\n"
            + "USER-AGENT: macOS/1 UPnP/1.1 NetScope/1\r\n\r\n"
        return Array(text.utf8)
    }

    // MARK: SIP (5060)

    /// OPTIONS (RFC 3261 11) : un téléphone ou un PBX répond 200 (ou 401/403/404) avec son
    /// User-Agent. Aucun appel n'est passé.
    public static func sipOptions(target: IPv4Address, local: IPv4Address?, localPort: UInt16, nonce: String) -> [UInt8] {
        let host = local?.description ?? "0.0.0.0"
        let text = [
            "OPTIONS sip:\(target) SIP/2.0",
            "Via: SIP/2.0/UDP \(host):\(localPort);branch=z9hG4bK-ns\(nonce);rport",
            "Max-Forwards: 70",
            "From: <sip:netscope@\(host)>;tag=ns\(nonce)",
            "To: <sip:\(target)>",
            "Call-ID: \(nonce)@netscope",
            "CSeq: 1 OPTIONS",
            "Contact: <sip:netscope@\(host):\(localPort)>",
            "Accept: application/sdp",
            "User-Agent: NetScope",
            "Content-Length: 0",
            "", "",
        ].joined(separator: "\r\n")
        return Array(text.utf8)
    }

    // MARK: mDNS (5353)

    /// Requête directe (« legacy unicast », RFC 6762 6.7) : liste des types de services annoncés.
    /// Envoyée d'un port autre que 5353, la réponse revient en envoi direct.
    public static func mdnsServicesQuery(id: UInt16) -> [UInt8] {
        (try? DNSMessageCodec.query(name: "_services._dns-sd._udp.local.", type: .ptr, id: id, recursion: false)) ?? []
    }
}
