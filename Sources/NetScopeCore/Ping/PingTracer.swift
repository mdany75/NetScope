import Darwin
import Foundation

/// Réponse d'un saut à une sonde.
public struct PingHopReply: Equatable, Sendable {
    public let address: IPv4Address
    public let rttMs: Double
    /// La réponse vient de la destination (Echo Reply).
    public let reachedDestination: Bool

    public init(address: IPv4Address, rttMs: Double, reachedDestination: Bool) {
        self.address = address
        self.rttMs = rttMs
        self.reachedDestination = reachedDestination
    }
}

/// Résultat d'un cycle : une sonde par TTL, réponses rangées par TTL.
public struct PingTraceCycle: Equatable, Sendable {
    /// TTL sondés (1…probed).
    public let probed: Int
    public let replies: [Int: PingHopReply]

    public init(probed: Int, replies: [Int: PingHopReply]) {
        self.probed = probed
        self.replies = replies
    }

    /// Plus petit TTL qui atteint la destination.
    public var destinationTTL: Int? {
        replies.filter { $0.value.reachedDestination }.keys.min()
    }
}

/// Traceroute ICMP : Echo Request à TTL croissant sur une socket ICMP « datagramme » ;
/// les routeurs répondent « Time Exceeded », la destination « Echo Reply ».
/// Un cycle envoie toutes les sondes d'un coup (comme mtr), puis attend les réponses.
public final class PingTracer: @unchecked Sendable {
    public let destination: IPv4Address
    public let maxHops: Int
    public let timeout: TimeInterval
    public let identifier: UInt16
    private let socket: PingSocket
    private var sequenceBase = 0
    private let lock = NSLock()

    public init(destination: IPv4Address, maxHops: Int = 30, timeout: TimeInterval = 1,
                identifier: UInt16 = PingIdentifiers.next()) throws {
        self.destination = destination
        self.maxHops = min(max(1, maxHops), 64)
        self.timeout = timeout
        self.identifier = identifier
        socket = try PingSocket()
    }

    /// Un cycle complet (bloquant, au plus `timeout` après le dernier envoi).
    /// `limit` : nombre de sauts à sonder (destination déjà connue), sinon `maxHops`.
    public func runCycle(limit: Int? = nil, payloadSize: Int = 56) throws -> PingTraceCycle {
        lock.lock()
        defer { lock.unlock() }
        let count = min(limit ?? maxHops, maxHops)
        // Séquences propres à ce cycle : les réponses tardives d'un cycle précédent sont ignorées.
        let base = sequenceBase
        sequenceBase = (sequenceBase + 100) % 60_000
        var sentAt: [Int: Double] = [:]
        for ttl in 1...count {
            try socket.setTTL(ttl)
            let packet = PingICMP.echoRequestPacket(identifier: identifier, sequence: UInt16(base + ttl), payloadSize: payloadSize)
            let time = PingClock.nowMs()
            if socket.send(packet, to: destination) == 0 { sentAt[ttl] = time }
        }
        var replies: [Int: PingHopReply] = [:]
        let deadline = PingClock.nowMs() + timeout * 1000
        while PingClock.nowMs() < deadline {
            if let known = replies.filter({ $0.value.reachedDestination }).keys.min(),
               (1...known).allSatisfy({ replies[$0] != nil || sentAt[$0] == nil }) {
                break
            }
            guard socket.wait(timeout: (deadline - PingClock.nowMs()) / 1000) else { continue }
            while let packet = socket.receive() {
                let now = PingClock.nowMs()
                guard let (message, header) = PingICMP.parse(packet.bytes), message.identifier == identifier else { continue }
                let ttl = Int(message.sequence) - base
                guard ttl >= 1, ttl <= count, replies[ttl] == nil, let start = sentAt[ttl] else { continue }
                let from = header ?? packet.from
                switch message {
                case .echoReply:
                    guard from == destination || packet.from == destination else { continue }
                    replies[ttl] = PingHopReply(address: destination, rttMs: now - start, reachedDestination: true)
                case let .timeExceeded(_, _, original):
                    guard original == nil || original == destination else { continue }
                    replies[ttl] = PingHopReply(address: from, rttMs: now - start, reachedDestination: false)
                case let .unreachable(_, _, _, original):
                    guard original == nil || original == destination else { continue }
                    replies[ttl] = PingHopReply(address: from, rttMs: now - start, reachedDestination: from == destination)
                }
            }
        }
        // Rétablit un TTL normal pour la socket.
        try? socket.setTTL(64)
        return PingTraceCycle(probed: count, replies: replies)
    }

    /// Version asynchrone, exécutée hors du fil principal.
    public func runCycleAsync(limit: Int? = nil) async throws -> PingTraceCycle {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.runCycle(limit: limit)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// MARK: - MTR

/// Un saut du rapport MTR.
public struct PingMTRHop: Equatable, Sendable {
    public let ttl: Int
    /// Dernière adresse ayant répondu à ce TTL (nil : aucune réponse).
    public var address: IPv4Address?
    public var stats = PingHopStats()
    public var isDestination = false

    public init(ttl: Int) { self.ttl = ttl }
}

/// MTR : cycles de traceroute répétés, statistiques cumulées par saut.
public struct PingMTRReport: Equatable, Sendable {
    public let destination: IPv4Address
    public private(set) var cycles = 0
    public private(set) var hops: [PingMTRHop] = []
    /// Nombre de sauts jusqu'à la destination, une fois atteinte.
    public private(set) var destinationTTL: Int?

    public init(destination: IPv4Address) { self.destination = destination }

    /// Sauts à sonder au prochain cycle (nil tant que la destination n'est pas atteinte).
    public var probeLimit: Int? { destinationTTL }

    public mutating func record(_ cycle: PingTraceCycle) {
        cycles += 1
        if let reached = cycle.destinationTTL {
            destinationTTL = min(destinationTTL ?? reached, reached)
        }
        let highestReply = cycle.replies.keys.max() ?? 0
        let count = destinationTTL ?? max(hops.count, highestReply)
        if hops.count > count { hops.removeLast(hops.count - count) }
        while hops.count < count { hops.append(PingMTRHop(ttl: hops.count + 1)) }
        for index in hops.indices {
            let ttl = index + 1
            guard ttl <= cycle.probed else { continue }
            if let reply = cycle.replies[ttl] {
                hops[index].address = reply.address
                hops[index].stats.record(reply.rttMs)
            } else {
                hops[index].stats.record(nil)
            }
            hops[index].isDestination = ttl == destinationTTL
        }
    }

    /// Rapport texte (« Copier le rapport »), noms des sauts facultatifs.
    public func text(hostnames: [IPv4Address: String] = [:], date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["MTR vers \(destination) · \(cycles) cycles · \(formatter.string(from: date))"]
        lines.append(pad("N°", 4) + pad("Hôte", 34) + pad("IP", 17) + padLeft("Perte", 8) + padLeft("Env.", 6)
                     + padLeft("Dern.", 8) + padLeft("Moy", 8) + padLeft("Meil.", 8) + padLeft("Pire", 8) + padLeft("Éc.-t.", 8))
        for hop in hops {
            let host = hop.address.map { hostnames[$0] ?? "(sans PTR)" } ?? "???"
            lines.append(pad("\(hop.ttl)", 4) + pad(host, 34) + pad(hop.address?.description ?? "—", 17)
                         + padLeft(PingFormat.percent(hop.stats.lossPercent), 8) + padLeft("\(hop.stats.sent)", 6)
                         + padLeft(PingFormat.decimal(hop.stats.last), 8) + padLeft(PingFormat.decimal(hop.stats.average), 8)
                         + padLeft(PingFormat.decimal(hop.stats.best), 8) + padLeft(PingFormat.decimal(hop.stats.worst), 8)
                         + padLeft(PingFormat.decimal(hop.stats.standardDeviation), 8))
        }
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        let cut = text.count > width - 1 ? String(text.prefix(width - 2)) + "…" : text
        return cut + String(repeating: " ", count: max(1, width - cut.count))
    }

    private func padLeft(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(1, width - text.count)) + text
    }
}
