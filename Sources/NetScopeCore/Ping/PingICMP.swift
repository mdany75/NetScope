import Darwin
import Foundation

// Paquets ICMP (RFC 792) : construction de l'« Echo Request » et lecture des réponses
// (« Echo Reply », « Time Exceeded », « Destination Unreachable »).

public enum PingICMP {
    public static let echoReply: UInt8 = 0
    public static let destinationUnreachable: UInt8 = 3
    public static let echoRequest: UInt8 = 8
    public static let timeExceeded: UInt8 = 11
    public static let headerSize = 8
    /// En-têtes IP (20) + ICMP (8) : 1472 octets de données donnent 1500 octets.
    public static let ipAndICMPOverhead = 28

    /// Message ICMP qui concerne un de nos paquets.
    public enum Message: Equatable, Sendable {
        case echoReply(identifier: UInt16, sequence: UInt16)
        /// TTL épuisé chez un routeur intermédiaire (traceroute).
        case timeExceeded(identifier: UInt16, sequence: UInt16, originalDestination: IPv4Address?)
        case unreachable(code: UInt8, identifier: UInt16, sequence: UInt16, originalDestination: IPv4Address?)

        public var identifier: UInt16 {
            switch self {
            case let .echoReply(id, _), let .timeExceeded(id, _, _), let .unreachable(_, id, _, _): return id
            }
        }

        public var sequence: UInt16 {
            switch self {
            case let .echoReply(_, seq), let .timeExceeded(_, seq, _), let .unreachable(_, _, seq, _): return seq
            }
        }
    }

    /// Echo Request : type 8, identifiant et séquence en ordre réseau, données de `payloadSize` octets.
    public static func echoRequestPacket(identifier: UInt16, sequence: UInt16, payloadSize: Int) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: headerSize + max(0, payloadSize))
        packet[0] = echoRequest
        packet[1] = 0
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xFF)
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        // Motif reconnaissable dans les captures : « NetScope » puis octets croissants.
        let marker = Array("NetScope".utf8)
        for index in 0..<max(0, payloadSize) {
            packet[headerSize + index] = index < marker.count ? marker[index] : UInt8(truncatingIfNeeded: index)
        }
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// Somme de contrôle Internet (RFC 1071) sur des mots de 16 bits en ordre réseau.
    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// Lit un paquet reçu. Sur macOS, une socket ICMP « datagramme » reçoit l'en-tête IP : il est
    /// reconnu (version 4) et sauté. Renvoie le message et l'adresse source lue dans l'en-tête IP.
    public static func parse(_ bytes: [UInt8]) -> (message: Message, source: IPv4Address?)? {
        var offset = 0
        var source: IPv4Address?
        if let ip = ipHeader(bytes, at: 0) {
            offset = ip.length
            source = ip.source
        }
        guard bytes.count >= offset + headerSize else { return nil }
        let type = bytes[offset]
        let code = bytes[offset + 1]
        switch type {
        case echoReply:
            return (.echoReply(identifier: word(bytes, offset + 4), sequence: word(bytes, offset + 6)), source)
        case timeExceeded, destinationUnreachable:
            // Données : en-tête IP d'origine, puis les 8 premiers octets de notre Echo Request.
            let innerStart = offset + headerSize
            guard let inner = ipHeader(bytes, at: innerStart) else { return nil }
            let icmpStart = innerStart + inner.length
            guard bytes.count >= icmpStart + headerSize, bytes[icmpStart] == echoRequest else { return nil }
            let id = word(bytes, icmpStart + 4)
            let seq = word(bytes, icmpStart + 6)
            if type == timeExceeded {
                return (.timeExceeded(identifier: id, sequence: seq, originalDestination: inner.destination), source)
            }
            return (.unreachable(code: code, identifier: id, sequence: seq, originalDestination: inner.destination), source)
        default:
            return nil
        }
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func ipHeader(_ bytes: [UInt8], at offset: Int) -> (length: Int, source: IPv4Address, destination: IPv4Address)? {
        guard bytes.count >= offset + 20, bytes[offset] >> 4 == 4 else { return nil }
        let length = Int(bytes[offset] & 0x0F) * 4
        guard length >= 20, bytes.count >= offset + length else { return nil }
        let source = IPv4Address(bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15])
        let destination = IPv4Address(bytes[offset + 16], bytes[offset + 17], bytes[offset + 18], bytes[offset + 19])
        return (length, source, destination)
    }
}

/// Identifiants ICMP distincts pour chaque socket ouverte par le processus.
public enum PingIdentifiers {
    private static let lock = NSLock()
    private static var counter = UInt16.random(in: 0...UInt16.max)

    public static func next() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        counter &+= 1
        return counter
    }
}

// MARK: - Socket

public enum PingError: Error, Equatable, LocalizedError {
    case socket(errno: Int32)
    case option(name: String, errno: Int32)
    case resolution(host: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .socket(code):
            return "Socket ICMP indisponible : \(String(cString: strerror(code)))."
        case let .option(name, code):
            return "Option \(name) refusée : \(String(cString: strerror(code)))."
        case let .resolution(host, message):
            return "« \(host) » introuvable : \(message)."
        }
    }
}

/// Socket ICMP non privilégiée (SOCK_DGRAM, IPPROTO_ICMP) : aucun droit administrateur nécessaire.
public final class PingSocket {
    public let descriptor: Int32
    private var closed = false

    public init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { throw PingError.socket(errno: errno) }
        descriptor = fd
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var size: Int32 = 256 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    public func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }

    public func setTTL(_ ttl: Int) throws {
        var value = Int32(ttl)
        guard setsockopt(descriptor, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw PingError.option(name: "IP_TTL", errno: errno)
        }
    }

    /// Bit DF (« ne pas fragmenter ») ; false si le système le refuse.
    @discardableResult
    public func setDontFragment(_ enabled: Bool) -> Bool {
        var value: Int32 = enabled ? 1 : 0
        return setsockopt(descriptor, IPPROTO_IP, IP_DONTFRAG, &value, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    /// Envoie un paquet ; renvoie 0 ou le code errno.
    public func send(_ packet: [UInt8], to address: IPv4Address) -> Int32 {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_addr = in_addr(s_addr: address.value.bigEndian)
        let sent = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent < 0 ? errno : 0
    }

    /// Lit un paquet en attente (socket non bloquante) ; nil s'il n'y a rien.
    public func receive() -> (bytes: [UInt8], from: IPv4Address)? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var source = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, raw.baseAddress, raw.count, 0, $0, &length)
                }
            }
        }
        guard count > 0 else { return nil }
        return (Array(buffer[0..<count]), IPv4Address(UInt32(bigEndian: source.sin_addr.s_addr)))
    }

    /// Attend un paquet au plus `timeout` secondes ; true si quelque chose est lisible.
    public func wait(timeout: TimeInterval) -> Bool {
        var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(0, min(timeout, 60)) * 1000)
        return poll(&descriptorSet, 1, milliseconds) > 0
    }
}

/// Horloge monotone en millisecondes (insensible aux changements d'heure).
public enum PingClock {
    public static func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }
}
