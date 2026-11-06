import Darwin
import Foundation

/// Sonde « l'hôte répond-il ? ». Renvoie le temps aller-retour en millisecondes, ou nil.
public protocol ScanPinging: Sendable {
    func ping(_ ip: IPv4Address, timeout: Duration) async -> Double?
}

/// Note 68 : sonde qui retient le TTL des réponses (indice faible du système : 64, 128 ou 255).
public protocol ScanTTLReporting: Sendable {
    func replyTTL(for ip: IPv4Address) -> Int?
}

public enum ICMPPingerError: Error, LocalizedError, Equatable {
    case socket(Int32)

    public var errorDescription: String? {
        switch self {
        case .socket(let code):
            return "Impossible d’ouvrir le socket ICMP (\(String(cString: strerror(code))))."
        }
    }
}

/// Ping ICMP écho non privilégié (SOCK_DGRAM + IPPROTO_ICMP, autorisé sur macOS sans droits root).
///
/// Un seul socket est partagé par toutes les sondes : chaque requête reçoit un numéro de séquence
/// unique, et les réponses sont distribuées d'après ce numéro, l'adresse source et une signature
/// placée dans la charge utile. Des centaines de pings peuvent donc être en vol en même temps.
public final class ICMPPinger: ScanPinging, ScanTTLReporting, @unchecked Sendable {
    /// Signature de la charge utile : « NSCP ».
    static let magic: [UInt8] = [0x4E, 0x53, 0x43, 0x50]

    private struct Pending {
        let target: IPv4Address
        let sentAt: UInt64
        let continuation: CheckedContinuation<Double?, Never>
    }

    public let identifier: UInt16
    private let fd: Int32
    private let queue = DispatchQueue(label: "netscope.icmp")
    private let lock = NSLock()
    private var nextSequence: UInt16
    private var pending: [UInt16: Pending] = [:]
    /// TTL de la dernière réponse de chaque hôte (note 68), plafonné à 65 536 hôtes.
    private var ttls: [IPv4Address: Int] = [:]
    private var source: DispatchSourceRead?

    public init(identifier: UInt16 = UInt16.random(in: 1...UInt16.max)) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { throw ICMPPingerError.socket(errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // Grand tampon de réception : beaucoup de réponses peuvent arriver d'un coup.
        var size: Int32 = 1 << 20
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        self.fd = fd
        self.identifier = identifier
        nextSequence = UInt16.random(in: 0...UInt16.max)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    deinit {
        source?.cancel()
    }

    /// Nombre de sondes en attente de réponse.
    public var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    public func ping(_ ip: IPv4Address, timeout: Duration = .seconds(1)) async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            lock.lock()
            var sequence = nextSequence
            var tries = 0
            while pending[sequence] != nil, tries < 65_536 {
                sequence &+= 1
                tries += 1
            }
            guard pending[sequence] == nil else {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            nextSequence = sequence &+ 1
            let sentAt = DispatchTime.now().uptimeNanoseconds
            pending[sequence] = Pending(target: ip, sentAt: sentAt, continuation: continuation)
            lock.unlock()

            let packet = ICMPPinger.echoRequest(identifier: identifier, sequence: sequence, timestamp: sentAt)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = ip.value.bigEndian
            let sent = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 {
                // Hôte injoignable, tampon plein… : échec immédiat.
                resolve(sequence, reply: nil)
                return
            }
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(timeout.scanNanoseconds, UInt64(Int.max))))) { [self] in
                resolve(sequence, reply: nil)
            }
        }
    }

    public func replyTTL(for ip: IPv4Address) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return ttls[ip]
    }

    /// TTL de l'en-tête IP fourni par le noyau (nil s'il est absent).
    public static func replyTTL(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { return nil }
        return Int(bytes[8])
    }

    /// Termine une sonde : réponse reçue (`reply`) ou délai écoulé (nil).
    private func resolve(_ sequence: UInt16, reply: (source: IPv4Address, time: UInt64)?) {
        lock.lock()
        guard let entry = pending[sequence] else {
            lock.unlock()
            return
        }
        if let reply, reply.source != entry.target {
            // Réponse d'un autre hôte avec le même numéro : on attend la bonne.
            lock.unlock()
            return
        }
        pending[sequence] = nil
        lock.unlock()
        if let reply {
            let elapsed = reply.time >= entry.sentAt ? reply.time - entry.sentAt : 0
            entry.continuation.resume(returning: Double(elapsed) / 1_000_000)
        } else {
            entry.continuation.resume(returning: nil)
        }
    }

    /// Lit toutes les réponses disponibles sur le socket.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            guard count > 0 else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard let reply = ICMPPinger.parseEchoReply(Array(buffer[0..<count])),
                  reply.payloadIdentifier == identifier else { continue }
            let sourceIP = IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr))
            if let ttl = ICMPPinger.replyTTL(Array(buffer[0..<count])) {
                lock.lock()
                if ttls.count < 65_536 || ttls[sourceIP] != nil { ttls[sourceIP] = ttl }
                lock.unlock()
            }
            resolve(reply.sequence, reply: (sourceIP, now))
        }
    }

    // MARK: Paquets

    /// Requête d'écho ICMP (type 8) : en-tête de 8 octets + charge utile signée de 16 octets.
    static func echoRequest(identifier: UInt16, sequence: UInt16, timestamp: UInt64) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        packet += magic
        packet += [UInt8(identifier >> 8), UInt8(identifier & 0xFF), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        for shift in stride(from: 56, through: 0, by: -8) { packet.append(UInt8((timestamp >> UInt64(shift)) & 0xFF)) }
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// Lit une réponse d'écho (type 0). Le noyau de macOS fournit l'en-tête IP sur un socket
    /// SOCK_DGRAM : il est sauté s'il est présent. Nil si ce n'est pas une de nos réponses.
    static func parseEchoReply(_ bytes: [UInt8]) -> (identifier: UInt16, sequence: UInt16, payloadIdentifier: UInt16)? {
        var offset = 0
        if let first = bytes.first, first >> 4 == 4 {
            offset = Int(first & 0x0F) * 4
        }
        guard bytes.count >= offset + 16 else { return nil }
        guard bytes[offset] == 0, bytes[offset + 1] == 0 else { return nil }
        let identifier = UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5])
        let sequence = UInt16(bytes[offset + 6]) << 8 | UInt16(bytes[offset + 7])
        guard Array(bytes[(offset + 8)..<(offset + 12)]) == magic else { return nil }
        let payloadIdentifier = UInt16(bytes[offset + 12]) << 8 | UInt16(bytes[offset + 13])
        let payloadSequence = UInt16(bytes[offset + 14]) << 8 | UInt16(bytes[offset + 15])
        // La charge utile fait foi, au cas où le noyau aurait réécrit l'en-tête.
        _ = sequence
        return (identifier, payloadSequence, payloadIdentifier)
    }

    /// Somme de contrôle Internet (RFC 1071).
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum &+= UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }
}

/// Sonde qui ne répond jamais (socket ICMP indisponible) : seule la table ARP trouve alors des hôtes.
public struct ScanNullPinger: ScanPinging {
    public init() {}
    public func ping(_ ip: IPv4Address, timeout: Duration) async -> Double? { nil }
}
