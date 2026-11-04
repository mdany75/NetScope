import Darwin
import Foundation

/// Fabrication de paquets synthétiques (sommes de contrôle comprises) pour la démonstration et les
/// tests : rien n'est jamais envoyé, ces octets ne servent qu'à remplir une capture fictive.
public enum PacketForge {
    // MARK: Liaison et IP

    /// Trame Ethernet II (étiquette 802.1Q facultative), complétée à 60 octets comme sur le fil.
    public static func ethernet(source: MACAddress, destination: MACAddress, type: UInt16, payload: [UInt8], vlan: Int? = nil) -> [UInt8] {
        var frame = destination.bytes + source.bytes
        if let vlan {
            frame.appendBE16(0x8100)
            frame.appendBE16(UInt16(vlan & 0x0FFF))
        }
        frame.appendBE16(type)
        frame += payload
        if frame.count < 60 { frame += [UInt8](repeating: 0, count: 60 - frame.count) }
        return frame
    }

    public static func ipv4(source: IPv4Address, destination: IPv4Address, protocol proto: UInt8, payload: [UInt8],
                            ttl: UInt8 = 64, id: UInt16 = 0, dontFragment: Bool = true) -> [UInt8] {
        var header: [UInt8] = [0x45, 0x00]
        header.appendBE16(UInt16(20 + payload.count))
        header.appendBE16(id)
        header.appendBE16(dontFragment ? 0x4000 : 0)
        header += [ttl, proto, 0, 0]
        header.appendBE32(source.value)
        header.appendBE32(destination.value)
        let checksum = InternetChecksum.checksum(header[...])
        header[10] = UInt8(checksum >> 8)
        header[11] = UInt8(checksum & 0xFF)
        return header + payload
    }

    public static func ipv6(source: [UInt8], destination: [UInt8], next: UInt8, payload: [UInt8], hopLimit: UInt8 = 255) -> [UInt8] {
        var header: [UInt8] = [0x60, 0, 0, 0]
        header.appendBE16(UInt16(payload.count))
        header += [next, hopLimit]
        header += source + destination
        return header + payload
    }

    /// Adresse IPv6 depuis son texte (« fe80::1 »).
    public static func ipv6Address(_ text: String) -> [UInt8] {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return [UInt8](repeating: 0, count: 16) }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func pseudoSum(source: IPv4Address, destination: IPv4Address, proto: UInt8, length: Int) -> UInt32 {
        var bytes: [UInt8] = []
        bytes.appendBE32(source.value)
        bytes.appendBE32(destination.value)
        return InternetChecksum.sum(bytes[...]) + UInt32(proto) + UInt32(length)
    }

    // MARK: Transport

    public static func udp(source: IPv4Address, destination: IPv4Address, sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) -> [UInt8] {
        var segment: [UInt8] = []
        segment.appendBE16(sourcePort)
        segment.appendBE16(destinationPort)
        segment.appendBE16(UInt16(8 + payload.count))
        segment.appendBE16(0)
        segment += payload
        var checksum = InternetChecksum.checksum(segment[...], initial: pseudoSum(source: source, destination: destination, proto: 17, length: segment.count))
        if checksum == 0 { checksum = 0xFFFF }
        segment[6] = UInt8(checksum >> 8)
        segment[7] = UInt8(checksum & 0xFF)
        return segment
    }

    public static func tcp(source: IPv4Address, destination: IPv4Address, sourcePort: UInt16, destinationPort: UInt16,
                           sequence: UInt32, acknowledgment: UInt32, flags: UInt16, window: UInt16 = 65_535,
                           options: [UInt8] = [], payload: [UInt8] = []) -> [UInt8] {
        var opts = options
        while opts.count % 4 != 0 { opts.append(1) }
        var segment: [UInt8] = []
        segment.appendBE16(sourcePort)
        segment.appendBE16(destinationPort)
        segment.appendBE32(sequence)
        segment.appendBE32(acknowledgment)
        let words = UInt16((20 + opts.count) / 4)
        segment.appendBE16(words << 12 | (flags & 0x01FF))
        segment.appendBE16(window)
        segment.appendBE16(0)
        segment.appendBE16(0)
        segment += opts + payload
        let checksum = InternetChecksum.checksum(segment[...], initial: pseudoSum(source: source, destination: destination, proto: 6, length: segment.count))
        segment[16] = UInt8(checksum >> 8)
        segment[17] = UInt8(checksum & 0xFF)
        return segment
    }

    /// Trame UDP complète (Ethernet, IPv4, UDP).
    public static func udpFrame(_ from: (MACAddress, IPv4Address, UInt16), _ to: (MACAddress, IPv4Address, UInt16), payload: [UInt8],
                                ttl: UInt8 = 64, id: UInt16 = 0) -> [UInt8] {
        let segment = udp(source: from.1, destination: to.1, sourcePort: from.2, destinationPort: to.2, payload: payload)
        return ethernet(source: from.0, destination: to.0, type: 0x0800,
                        payload: ipv4(source: from.1, destination: to.1, protocol: 17, payload: segment, ttl: ttl, id: id, dontFragment: false))
    }

    /// Trame TCP complète (Ethernet, IPv4, TCP).
    public static func tcpFrame(_ from: (MACAddress, IPv4Address, UInt16), _ to: (MACAddress, IPv4Address, UInt16),
                                sequence: UInt32, acknowledgment: UInt32, flags: UInt16, window: UInt16 = 65_535,
                                options: [UInt8] = [], payload: [UInt8] = [], ttl: UInt8 = 64, id: UInt16 = 0) -> [UInt8] {
        let segment = tcp(source: from.1, destination: to.1, sourcePort: from.2, destinationPort: to.2, sequence: sequence,
                          acknowledgment: acknowledgment, flags: flags, window: window, options: options, payload: payload)
        return ethernet(source: from.0, destination: to.0, type: 0x0800,
                        payload: ipv4(source: from.1, destination: to.1, protocol: 6, payload: segment, ttl: ttl, id: id))
    }

    /// Options d'un SYN : MSS 1460, NOP, échelle de fenêtre 6, NOP, NOP, horodatage, SACK permis.
    public static let synOptions: [UInt8] = [0x02, 0x04, 0x05, 0xB4, 0x01, 0x03, 0x03, 0x06, 0x01, 0x01,
                                             0x08, 0x0A, 0x3A, 0x1C, 0x00, 0x11, 0x00, 0x00, 0x00, 0x00, 0x04, 0x02]

    // MARK: ARP

    public static func arp(operation: UInt16, senderMAC: MACAddress, senderIP: IPv4Address, targetMAC: MACAddress, targetIP: IPv4Address) -> [UInt8] {
        var body: [UInt8] = [0x00, 0x01, 0x08, 0x00, 6, 4]
        body.appendBE16(operation)
        body += senderMAC.bytes
        body.appendBE32(senderIP.value)
        body += targetMAC.bytes
        body.appendBE32(targetIP.value)
        let destination = operation == 1 ? MACAddress(value: 0xFFFF_FFFF_FFFF) : targetMAC
        return ethernet(source: senderMAC, destination: destination, type: 0x0806, payload: body)
    }

    // MARK: DNS, mDNS, NetBIOS-NS

    public static func dnsName(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8)
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        bytes.append(0)
        return bytes
    }

    /// Nom NetBIOS codé (16 octets complétés d'espaces, suffixe, puis 32 lettres A à P).
    public static func netbiosName(_ name: String, suffix: UInt8 = 0x00) -> [UInt8] {
        var raw = Array(name.uppercased().utf8.prefix(15))
        raw += [UInt8](repeating: 0x20, count: 15 - raw.count)
        raw.append(suffix)
        var encoded: [UInt8] = [32]
        for byte in raw { encoded += [0x41 + (byte >> 4), 0x41 + (byte & 0x0F)] }
        encoded.append(0)
        return encoded
    }

    /// Enregistrement de ressource : nom (déjà codé), type, classe, TTL, données.
    public struct Record {
        public var name: [UInt8]
        public var type: UInt16
        public var klass: UInt16 = 1
        public var ttl: UInt32
        public var data: [UInt8]

        public init(name: [UInt8], type: UInt16, klass: UInt16 = 1, ttl: UInt32, data: [UInt8]) {
            self.name = name
            self.type = type
            self.klass = klass
            self.ttl = ttl
            self.data = data
        }
    }

    /// Message DNS : questions (nom codé, type, classe) et enregistrements des trois sections.
    public static func dnsMessage(id: UInt16, flags: UInt16, questions: [([UInt8], UInt16, UInt16)],
                                  answers: [Record] = [], authority: [Record] = [], additional: [Record] = []) -> [UInt8] {
        var message: [UInt8] = []
        message.appendBE16(id)
        message.appendBE16(flags)
        for count in [questions.count, answers.count, authority.count, additional.count] { message.appendBE16(UInt16(count)) }
        for (name, type, klass) in questions {
            message += name
            message.appendBE16(type)
            message.appendBE16(klass)
        }
        for record in answers + authority + additional {
            message += record.name
            message.appendBE16(record.type)
            message.appendBE16(record.klass)
            message.appendBE32(record.ttl)
            message.appendBE16(UInt16(record.data.count))
            message += record.data
        }
        return message
    }

    /// Pointeur de compression vers le nom de la première question (décalage 12).
    public static let questionPointer: [UInt8] = [0xC0, 0x0C]

    public static func ipv4Bytes(_ address: IPv4Address) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendBE32(address.value)
        return bytes
    }

    // MARK: DHCP

    /// Message DHCP : op 1 (client) ou 2 (serveur), options codées (code, valeur).
    public static func dhcp(op: UInt8, xid: UInt32, client: MACAddress, yourAddress: IPv4Address = IPv4Address(0),
                            serverAddress: IPv4Address = IPv4Address(0), broadcast: Bool = true, options: [(UInt8, [UInt8])]) -> [UInt8] {
        var message = [UInt8](repeating: 0, count: 236)
        message[0] = op
        message[1] = 1
        message[2] = 6
        message[4] = UInt8(xid >> 24); message[5] = UInt8(xid >> 16 & 0xFF); message[6] = UInt8(xid >> 8 & 0xFF); message[7] = UInt8(xid & 0xFF)
        if broadcast { message[10] = 0x80 }
        for (index, byte) in ipv4Bytes(yourAddress).enumerated() { message[16 + index] = byte }
        for (index, byte) in ipv4Bytes(serverAddress).enumerated() { message[20 + index] = byte }
        for (index, byte) in client.bytes.enumerated() { message[28 + index] = byte }
        message += DHCPDiscover.magicCookie
        for (code, value) in options { message += [code, UInt8(value.count)] + value }
        message.append(255)
        if message.count < 300 { message += [UInt8](repeating: 0, count: 300 - message.count) }
        return message
    }

    // MARK: TLS

    static func handshake(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type, UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    static func record(_ type: UInt8, version: UInt16, _ body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [type]
        bytes.appendBE16(version)
        bytes.appendBE16(UInt16(body.count))
        return bytes + body
    }

    static func tlsExtension(_ type: UInt16, _ data: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendBE16(type)
        bytes.appendBE16(UInt16(data.count))
        return bytes + data
    }

    /// Client Hello TLS 1.3 typique d'un navigateur : SNI, groupes, ALPN, versions, partage de clé.
    public static func tlsClientHello(serverName: String, alpn: [String] = ["h2", "http/1.1"], seed: UInt8 = 0x5A) -> [UInt8] {
        var body: [UInt8] = [0x03, 0x03]
        body += (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &* 7 &+ $0 &* 13) }
        body.append(32)
        body += (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 29) }
        let suites: [UInt16] = [0x1301, 0x1302, 0x1303, 0xC02B, 0xC02F, 0xC02C, 0xC030, 0xCCA9, 0xCCA8]
        body.appendBE16(UInt16(suites.count * 2))
        for suite in suites { body.appendBE16(suite) }
        body += [0x01, 0x00]
        var extensions: [UInt8] = []
        let name = Array(serverName.utf8)
        var sni: [UInt8] = []
        sni.appendBE16(UInt16(name.count + 3))
        sni.append(0)
        sni.appendBE16(UInt16(name.count))
        sni += name
        extensions += tlsExtension(0, sni)
        extensions += tlsExtension(23, [])
        extensions += tlsExtension(65281, [0x00])
        extensions += tlsExtension(10, [0x00, 0x06, 0x00, 0x1D, 0x00, 0x17, 0x00, 0x18])
        extensions += tlsExtension(11, [0x01, 0x00])
        var protocols: [UInt8] = []
        for item in alpn { protocols += [UInt8(item.utf8.count)] + Array(item.utf8) }
        var alpnData: [UInt8] = []
        alpnData.appendBE16(UInt16(protocols.count))
        extensions += tlsExtension(16, alpnData + protocols)
        extensions += tlsExtension(13, [0x00, 0x08, 0x04, 0x03, 0x08, 0x04, 0x04, 0x01, 0x05, 0x03])
        var keyShare: [UInt8] = [0x00, 0x24, 0x00, 0x1D, 0x00, 0x20]
        keyShare += (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &* 3 &+ $0 &* 17) }
        extensions += tlsExtension(51, keyShare)
        extensions += tlsExtension(45, [0x01, 0x01])
        extensions += tlsExtension(43, [0x04, 0x03, 0x04, 0x03, 0x03])
        body.appendBE16(UInt16(extensions.count))
        body += extensions
        return record(22, version: 0x0301, handshake(1, body))
    }

    /// Server Hello TLS 1.3, Change Cipher Spec et premier enregistrement chiffré.
    public static func tlsServerHello(seed: UInt8 = 0x33, encryptedLength: Int = 2_870) -> [UInt8] {
        var body: [UInt8] = [0x03, 0x03]
        body += (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &* 11 &+ $0 &* 7) }
        body.append(32)
        body += (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 3) }
        body.appendBE16(0x1301)
        body.append(0)
        var extensions = tlsExtension(43, [0x03, 0x04])
        var keyShare: [UInt8] = [0x00, 0x1D, 0x00, 0x20]
        keyShare += (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &* 5 &+ $0) }
        extensions += tlsExtension(51, keyShare)
        body.appendBE16(UInt16(extensions.count))
        body += extensions
        let encrypted = (0..<encryptedLength).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 31) }
        return record(22, version: 0x0303, handshake(2, body)) + record(20, version: 0x0303, [0x01]) + record(23, version: 0x0303, encrypted)
    }

    /// Enregistrement de données applicatives chiffrées (contenu illisible, comme sur le fil).
    public static func tlsApplicationData(length: Int, seed: UInt8 = 0x77) -> [UInt8] {
        record(23, version: 0x0303, (0..<length).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 37) })
    }
}
