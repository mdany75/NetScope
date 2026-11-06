import Darwin
import Foundation

// IPv6 (0.31.0) : ping ICMPv6 (Echo Request 128 / Echo Reply 129, RFC 4443) par une socket non
// privilégiée, sollicitation de tous les nœuds du lien (ff02::1) sur demande, et traceroute IPv6
// par l'outil du système (/usr/sbin/traceroute6), dont la sortie est lue ici.

public enum PingICMPv6 {
    public static let echoRequest: UInt8 = 128
    public static let echoReply: UInt8 = 129
    public static let destinationUnreachable: UInt8 = 1
    public static let timeExceeded: UInt8 = 3
    public static let headerSize = 8

    /// Echo Request : type 128, somme de contrôle laissée à zéro (le noyau la calcule sur
    /// l'en-tête virtuel IPv6, RFC 3542), identifiant et séquence en ordre réseau.
    public static func echoRequestPacket(identifier: UInt16, sequence: UInt16, payloadSize: Int) -> [UInt8] {
        var packet = PingICMP.echoRequestPacket(identifier: identifier, sequence: sequence, payloadSize: payloadSize)
        packet[0] = echoRequest
        packet[2] = 0
        packet[3] = 0
        return packet
    }

    /// Réponse lue sur la socket (sans en-tête IPv6, que le noyau retire toujours).
    public enum Reply: Equatable, Sendable {
        case echoReply(identifier: UInt16, sequence: UInt16)
        case unreachable(code: UInt8, identifier: UInt16, sequence: UInt16)
        case timeExceeded(identifier: UInt16, sequence: UInt16)
    }

    public static func parse(_ bytes: [UInt8]) -> Reply? {
        guard bytes.count >= headerSize else { return nil }
        func word(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        switch bytes[0] {
        case echoReply:
            return .echoReply(identifier: word(4), sequence: word(6))
        case destinationUnreachable, timeExceeded:
            // Paquet d'origine : en-tête IPv6 (40 octets) puis notre Echo Request.
            let inner = headerSize + 40
            guard bytes.count >= inner + headerSize, bytes[inner] == echoRequest else { return nil }
            let id = word(inner + 4), seq = word(inner + 6)
            return bytes[0] == timeExceeded ? .timeExceeded(identifier: id, sequence: seq)
                : .unreachable(code: bytes[1], identifier: id, sequence: seq)
        default:
            return nil
        }
    }

    /// Libellé d'un code « destination inaccessible » ICMPv6.
    public static func unreachableLabel(_ code: UInt8) -> String {
        switch code {
        case 0: return "aucune route"
        case 1: return "interdit par un filtre"
        case 3: return "adresse inaccessible"
        case 4: return "port inaccessible"
        default: return "inaccessible (code \(code))"
        }
    }

    /// Index d'interface d'une zone (« en0 »), 0 si inconnue.
    public static func scopeID(_ zone: String?) -> UInt32 {
        guard let zone, !zone.isEmpty else { return 0 }
        return if_nametoindex(zone)
    }

    static func socketAddress(_ address: IPv6Address, scopeID: UInt32) -> sockaddr_in6 {
        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_scope_id = scopeID
        let bytes = address.bytes
        withUnsafeMutableBytes(of: &destination.sin6_addr) { raw in
            for index in 0..<16 { raw[index] = bytes[index] }
        }
        return destination
    }

    /// Un ping ICMPv6 (bloquant, au plus `timeout` secondes). Une socket par sonde : les réponses
    /// des autres cibles ne s'y mélangent pas.
    public static func probe(_ address: IPv6Address, zone: String?, timeout: TimeInterval,
                             payloadSize: Int = 56, sequence: UInt16 = 1) -> PingProbeResult {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return .lost(.failed("socket ICMPv6 refusée (errno \(errno))")) }
        defer { Darwin.close(fd) }
        let identifier = PingIdentifiers.next()
        let packet = echoRequestPacket(identifier: identifier, sequence: sequence, payloadSize: payloadSize)
        var destination = socketAddress(address, scopeID: scopeID(zone))
        let start = PingClock.nowMs()
        let sent = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard sent >= 0 else { return .lost(.sendFailed(errno: errno)) }
        let deadline = start + timeout * 1000
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let remaining = deadline - PingClock.nowMs()
            guard remaining > 0 else { return .lost(.timeout) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(remaining)) > 0 else { return .lost(.timeout) }
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0, let reply = parse(Array(buffer[0..<count])) else { continue }
            switch reply {
            case let .echoReply(id, seq) where id == identifier && seq == sequence:
                return PingProbeResult(rttMs: max(0, PingClock.nowMs() - start))
            case let .unreachable(code, id, seq) where id == identifier && seq == sequence:
                return .lost(.failed(unreachableLabel(code)))
            default:
                continue
            }
        }
    }

    /// Sollicite tous les nœuds du lien (ff02::1 sur `interface`) et rend les adresses qui ont
    /// répondu. Envoyé seulement sur un clic : les réponses remplissent aussi la table NDP.
    public static func solicitAllNodes(interface: String, timeout: TimeInterval = 2) -> [IPv6Address] {
        let index = scopeID(interface)
        guard index > 0 else { return [] }
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }
        var hops: Int32 = 1
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, socklen_t(MemoryLayout<Int32>.size))
        var interfaceIndex = index
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &interfaceIndex, socklen_t(MemoryLayout<UInt32>.size))
        let identifier = PingIdentifiers.next()
        var destination = socketAddress(.allNodes, scopeID: index)
        for sequence in UInt16(1)...2 {
            let packet = echoRequestPacket(identifier: identifier, sequence: sequence, payloadSize: 16)
            _ = packet.withUnsafeBytes { buffer in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
        }
        var found = Set<IPv6Address>()
        let deadline = PingClock.nowMs() + timeout * 1000
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let remaining = deadline - PingClock.nowMs()
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(remaining)) > 0 else { break }
            var source = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            guard count > 0, case let .echoReply(id, _)? = parse(Array(buffer[0..<count])), id == identifier else { continue }
            let raw = withUnsafeBytes(of: &source) { Array($0) }
            if let address = NDPTable.ipv6(raw) { found.insert(address) }
        }
        return found.sorted(by: IPv6Address.displayOrder)
    }
}

extension PingProbeMonitor {
    /// Ping continu ICMPv6 d'une adresse IPv6 (zone pour le lien local).
    public static func icmpv6(address: IPv6Address, zone: String?, options: PingOptions,
                              handler: @escaping PingMonitor.Handler) -> PingProbeMonitor {
        let payload = options.payloadSize
        let counter = PingIPv6Sequence()
        return PingProbeMonitor(kind: .icmpv6, options: options, probe: { timeout in
            let sequence = counter.next()
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: PingICMPv6.probe(address, zone: zone, timeout: timeout,
                                                                    payloadSize: payload, sequence: sequence))
                }
            }
        }, handler: handler)
    }
}

/// Numéros de séquence ICMPv6 du ping continu (partagés entre les sondes en vol).
final class PingIPv6Sequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16 = 0

    func next() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

// MARK: - Traceroute IPv6

/// Un saut de traceroute IPv6.
public struct IPv6TraceHop: Equatable, Sendable, Identifiable {
    public var ttl: Int
    /// Adresse qui a répondu (la première, s'il y en a plusieurs) ; nil : aucune réponse.
    public var address: IPv6Address?
    public var rttsMs: [Double]
    /// Sondes sans réponse (« * »).
    public var lost: Int

    public var id: Int { ttl }

    public init(ttl: Int, address: IPv6Address?, rttsMs: [Double], lost: Int) {
        self.ttl = ttl
        self.address = address
        self.rttsMs = rttsMs
        self.lost = lost
    }

    public var bestMs: Double? { rttsMs.min() }
    public var averageMs: Double? { rttsMs.isEmpty ? nil : rttsMs.reduce(0, +) / Double(rttsMs.count) }
}

public enum IPv6Trace {
    public static let path = "/usr/sbin/traceroute6"

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// Arguments : sans résolution, trois sondes ICMPv6 par saut, attente de 2 s.
    public static func arguments(destination: IPv6Address, zone: String?, maxHops: Int = 30) -> [String] {
        ["-n", "-I", "-q", "3", "-w", "2", "-m", String(min(max(maxHops, 1), 64)),
         destination.description + (zone.map { "%\($0)" } ?? "")]
    }

    /// Lit la sortie de traceroute6 (« 1  fe80::1%en0  0.812 ms  0.640 ms * »).
    public static func parse(_ text: String) -> [IPv6TraceHop] {
        var hops: [IPv6TraceHop] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first, let ttl = Int(first) else { continue }
            var hop = IPv6TraceHop(ttl: ttl, address: nil, rttsMs: [], lost: 0)
            var index = 1
            while index < tokens.count {
                let token = tokens[index]
                if token == "*" {
                    hop.lost += 1
                } else if let value = Double(token), index + 1 < tokens.count, tokens[index + 1] == "ms" {
                    hop.rttsMs.append(value)
                    index += 1
                } else if hop.address == nil, let (address, _) = IPv6Address.parseZoned(token.trimmingCharacters(in: CharacterSet(charactersIn: "()"))) {
                    hop.address = address
                }
                index += 1
            }
            hops.append(hop)
        }
        return hops
    }

    /// Lance traceroute6 (processus local, lecture de sa sortie) ; nil si l'outil manque.
    public static func run(destination: IPv6Address, zone: String?, maxHops: Int = 30) async -> [IPv6TraceHop]? {
        guard isAvailable else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments(destination: destination, zone: zone, maxHops: maxHops)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: parse(String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
