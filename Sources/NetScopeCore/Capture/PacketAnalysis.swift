import Foundation

// Liste des paquets d'une capture (ou d'un fichier ouvert) : numérotation, temps relatifs, analyse
// TCP (retransmissions, hors ordre, ACK en double, réinitialisations), suivi de flux et statistiques.

/// Ce que l'analyse TCP a repéré sur un segment.
public enum TCPAnalysisFlag: String, CaseIterable, Sendable, Hashable, Codable {
    case retransmission, outOfOrder, duplicateAck, reset, zeroWindow, keepAlive

    public var label: String {
        switch self {
        case .retransmission: return "Retransmission"
        case .outOfOrder: return "Hors ordre"
        case .duplicateAck: return "ACK en double"
        case .reset: return "Réinitialisation (RST)"
        case .zeroWindow: return "Fenêtre nulle"
        case .keepAlive: return "Maintien de connexion"
        }
    }

    /// Préfixe du résumé, comme Wireshark (« [Retransmission TCP] »).
    public var tag: String {
        switch self {
        case .retransmission: return "[Retransmission TCP]"
        case .outOfOrder: return "[TCP hors ordre]"
        case .duplicateAck: return "[ACK en double]"
        case .reset: return ""
        case .zeroWindow: return "[Fenêtre nulle]"
        case .keepAlive: return "[Maintien TCP]"
        }
    }

    /// Nom dans le filtre d'affichage (tcp.analysis.retransmission…).
    public var filterName: String {
        switch self {
        case .retransmission: return "retransmission"
        case .outOfOrder: return "out_of_order"
        case .duplicateAck: return "duplicate_ack"
        case .reset: return "reset"
        case .zeroWindow: return "zero_window"
        case .keepAlive: return "keep_alive"
        }
    }

    /// Problème à signaler (couleur d'alerte dans la liste).
    public var isProblem: Bool { self != .keepAlive }
}

/// Extrémité d'une conversation : adresse (IP ou MAC) et port éventuel.
public struct Endpoint: Hashable, Comparable, Sendable {
    public var address: String
    public var port: UInt16?

    public init(address: String, port: UInt16? = nil) {
        self.address = address
        self.port = port
    }

    /// « 10.0.0.5:52144 », « [fe80::1]:443 », « aa:bb:… ».
    public var label: String {
        guard let port else { return address }
        // Avec un port, l'adresse est une IP : crochets pour IPv6.
        return address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    public static func < (lhs: Endpoint, rhs: Endpoint) -> Bool {
        lhs.address == rhs.address ? (lhs.port ?? 0) < (rhs.port ?? 0) : lhs.address < rhs.address
    }
}

/// Conversation (sans direction) : deux extrémités et le transport.
public struct ConversationKey: Hashable, Sendable {
    public var kind: PacketProtocol
    public var a: Endpoint
    public var b: Endpoint

    public init(kind: PacketProtocol, _ x: Endpoint, _ y: Endpoint) {
        self.kind = kind
        if y < x { a = y; b = x } else { a = x; b = y }
    }

    public var label: String { "\(a.label) ↔ \(b.label)" }

    /// Conversation d'un paquet décodé : TCP/UDP (adresses et ports), autre IP, ou Ethernet.
    public static func of(_ packet: DecodedPacket) -> ConversationKey? {
        if let source = packet.ipSource, let destination = packet.ipDestination {
            if let transport = packet.transport {
                return ConversationKey(kind: transport.kind, Endpoint(address: source, port: transport.sourcePort),
                                       Endpoint(address: destination, port: transport.destinationPort))
            }
            return ConversationKey(kind: packet.ipVersion == 6 ? .ipv6 : .ipv4, Endpoint(address: source), Endpoint(address: destination))
        }
        if let source = packet.ethSource, let destination = packet.ethDestination {
            return ConversationKey(kind: .ethernet, Endpoint(address: source.formatted()), Endpoint(address: destination.formatted()))
        }
        return nil
    }
}

/// Un paquet de la liste : enregistrement, décodage, temps et analyse.
public struct CapturedPacket: Identifiable, Sendable, Equatable {
    /// Numéro dans la capture (1, 2, 3…).
    public var id: Int
    public var record: PacketRecord
    public var decoded: DecodedPacket
    /// Secondes depuis le premier paquet.
    public var relativeTime: Double
    /// Secondes depuis le paquet précédent.
    public var delta: Double
    public var analysis: Set<TCPAnalysisFlag> = []
    public var relativeSequence: UInt32?
    public var relativeAcknowledgment: UInt32?
    public var conversation: ConversationKey?

    public var number: Int { id }
    public var length: Int { record.originalLength }
    public var date: Date { Date(timeIntervalSince1970: record.timestamp) }

    /// Résumé avec les numéros de séquence relatifs et les étiquettes d'analyse.
    public var summary: String { decoded.summary }

    public var hasProblem: Bool { analysis.contains { $0.isProblem } || !decoded.problems.isEmpty && decoded.transport == nil }
}

/// État de l'analyse TCP d'un sens d'une connexion.
private struct TCPDirection {
    var base: UInt32?
    var nextSequence: UInt32?
    var seen: Set<UInt32> = []
    var lastSegmentTime: Double?
    var lastAck: UInt32?
    var lastWindow: UInt16?
}

/// Comparaisons de numéros de séquence avec bouclage (RFC 1982).
enum SequenceMath {
    static func less(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
    static func lessOrEqual(_ a: UInt32, _ b: UInt32) -> Bool { a == b || less(a, b) }
}

/// Liste des paquets d'une capture, avec analyse au fil de l'eau.
public struct PacketCaptureLog: Sendable {
    public private(set) var packets: [CapturedPacket] = []
    public private(set) var byteCount = 0
    private var directions: [String: TCPDirection] = [:]
    /// Sous ce délai depuis le segment précédent du même sens, un segment « en retard » est dit
    /// hors ordre plutôt que retransmis (même règle que Wireshark sans mesure du RTT).
    public static let outOfOrderWindow: Double = 0.003

    public init() {}

    public init(records: [PacketRecord]) {
        append(records)
    }

    public var isEmpty: Bool { packets.isEmpty }
    public var count: Int { packets.count }
    public var firstTimestamp: TimeInterval? { packets.first?.record.timestamp }
    public var duration: Double { packets.last?.relativeTime ?? 0 }
    public var records: [PacketRecord] { packets.map(\.record) }

    public mutating func removeAll() { self = PacketCaptureLog() }

    /// Ajoute des enregistrements ; renvoie les paquets ajoutés.
    @discardableResult
    public mutating func append(_ records: [PacketRecord]) -> [CapturedPacket] {
        var added: [CapturedPacket] = []
        added.reserveCapacity(records.count)
        for record in records {
            let start = packets.first?.record.timestamp ?? record.timestamp
            let previous = packets.last?.record.timestamp ?? record.timestamp
            var packet = CapturedPacket(id: packets.count + 1, record: record,
                                        decoded: PacketDecoder.decode(record.data, linkType: record.linkType),
                                        relativeTime: record.timestamp - start, delta: record.timestamp - previous)
            packet.conversation = ConversationKey.of(packet.decoded)
            analyzeTCP(&packet)
            packets.append(packet)
            byteCount += record.originalLength
            added.append(packet)
        }
        return added
    }

    public func packet(_ number: Int) -> CapturedPacket? {
        guard number >= 1, number <= packets.count else { return nil }
        return packets[number - 1]
    }

    private mutating func analyzeTCP(_ packet: inout CapturedPacket) {
        guard let tcp = packet.decoded.tcp, let transport = packet.decoded.transport,
              let source = packet.decoded.ipSource, let destination = packet.decoded.ipDestination else { return }
        let forward = "\(source)|\(transport.sourcePort)>\(destination)|\(transport.destinationPort)"
        let reverse = "\(destination)|\(transport.destinationPort)>\(source)|\(transport.sourcePort)"
        var direction = directions[forward] ?? TCPDirection()
        let other = directions[reverse]
        let time = packet.record.timestamp
        var flags = Set<TCPAnalysisFlag>()
        let isSYN = tcp.has(TCPSegmentInfo.syn), isFIN = tcp.has(TCPSegmentInfo.fin), isRST = tcp.has(TCPSegmentInfo.rst)
        if isSYN { direction = TCPDirection(); direction.base = tcp.sequence }
        if direction.base == nil { direction.base = tcp.sequence &- 1 }
        if isRST { flags.insert(.reset) }
        if tcp.window == 0, !isRST, !isSYN, !isFIN { flags.insert(.zeroWindow) }
        let length = tcp.sequenceLength
        if length > 0 {
            if let next = direction.nextSequence, SequenceMath.less(tcp.sequence, next) {
                if tcp.payloadLength <= 1, !isSYN, !isFIN, tcp.sequence == next &- 1 {
                    flags.insert(.keepAlive)
                } else if direction.seen.contains(tcp.sequence) {
                    flags.insert(.retransmission)
                } else if let last = direction.lastSegmentTime, time - last < Self.outOfOrderWindow {
                    flags.insert(.outOfOrder)
                } else {
                    flags.insert(.retransmission)
                }
            }
            direction.seen.insert(tcp.sequence)
            let end = tcp.sequence &+ length
            if let next = direction.nextSequence { if SequenceMath.less(next, end) { direction.nextSequence = end } } else { direction.nextSequence = end }
            direction.lastSegmentTime = time
        } else if !isSYN, !isFIN, !isRST, tcp.payloadLength == 0, let next = direction.nextSequence, tcp.sequence == next &- 1 {
            // Maintien de connexion sans données (Linux et beaucoup d'équipements) : seq = prochain − 1.
            flags.insert(.keepAlive)
        } else if tcp.has(TCPSegmentInfo.ack), !isSYN, !isFIN, !isRST {
            // ACK sans données, même numéro et même fenêtre que le précédent : ACK en double.
            if direction.lastAck == tcp.acknowledgment, direction.lastWindow == tcp.window,
               let otherNext = other?.nextSequence, SequenceMath.less(tcp.acknowledgment, otherNext) {
                flags.insert(.duplicateAck)
            }
        }
        if tcp.has(TCPSegmentInfo.ack) {
            direction.lastAck = tcp.acknowledgment
            direction.lastWindow = tcp.window
        }
        directions[forward] = direction
        let relativeSeq = direction.base.map { tcp.sequence &- $0 }
        let relativeAck = tcp.has(TCPSegmentInfo.ack) ? other?.base.map { tcp.acknowledgment &- $0 } : nil
        packet.analysis = flags
        packet.relativeSequence = relativeSeq
        packet.relativeAcknowledgment = relativeAck
        // Résumé TCP refait avec les numéros relatifs (sauf si une application l'a remplacé).
        let plain = PacketDecoding.tcpSummary(sourcePort: transport.sourcePort, destinationPort: transport.destinationPort,
                                              info: tcp, relativeSeq: nil, relativeAck: nil)
        var summary = packet.decoded.summary
        if summary == plain {
            summary = PacketDecoding.tcpSummary(sourcePort: transport.sourcePort, destinationPort: transport.destinationPort,
                                                info: tcp, relativeSeq: relativeSeq, relativeAck: relativeAck)
        }
        let tags = TCPAnalysisFlag.allCases.filter { flags.contains($0) && !$0.tag.isEmpty }.map(\.tag)
        if !tags.isEmpty { summary = tags.joined(separator: " ") + " " + summary }
        packet.decoded.summary = summary
    }

    // MARK: Suivi de flux

    /// Données d'une conversation TCP ou UDP, remises dans l'ordre (TCP : par numéro de séquence,
    /// sans les retransmissions ni les doublons).
    public func follow(_ packet: CapturedPacket) -> FlowStream? {
        guard let key = packet.conversation, key.kind == .tcp || key.kind == .udp else { return nil }
        let members = packets.filter { $0.conversation == key }
        guard let first = members.first, let firstTransport = first.decoded.transport, let firstSource = first.decoded.ipSource else { return nil }
        // Client : l'auteur du SYN, sinon celui qui parle en premier.
        let opener = members.first { $0.decoded.tcp.map { $0.has(TCPSegmentInfo.syn) && !$0.has(TCPSegmentInfo.ack) } ?? false }
        let clientAddress = opener?.decoded.ipSource ?? firstSource
        let clientPort = opener?.decoded.transport?.sourcePort ?? firstTransport.sourcePort
        let client = Endpoint(address: clientAddress, port: clientPort)
        let server = key.a == client ? key.b : key.a
        var stream = FlowStream(key: key, client: client, server: server)
        stream.packetNumbers = members.map(\.id)
        var expected: [Bool: UInt32] = [:]
        var buffered: [Bool: [UInt32: (bytes: [UInt8], number: Int)]] = [true: [:], false: [:]]
        func deliver(_ fromClient: Bool, _ bytes: [UInt8], _ number: Int) {
            guard !bytes.isEmpty else { return }
            if fromClient { stream.clientBytes += bytes.count } else { stream.serverBytes += bytes.count }
            if let last = stream.chunks.last, last.fromClient == fromClient {
                stream.chunks[stream.chunks.count - 1].data += bytes
            } else {
                stream.chunks.append(FlowChunk(fromClient: fromClient, data: bytes, firstPacket: number))
            }
        }
        for member in members {
            guard let transport = member.decoded.transport else { continue }
            let fromClient = member.decoded.ipSource == client.address && transport.sourcePort == client.port
            let payload = Array(member.record.data[min(transport.payloadOffset, member.record.data.count)..<min(transport.payloadOffset + transport.payloadLength, member.record.data.count)])
            guard let tcp = member.decoded.tcp else {
                deliver(fromClient, payload, member.id)
                continue
            }
            if tcp.has(TCPSegmentInfo.syn) { expected[fromClient] = tcp.sequence &+ 1; continue }
            guard !payload.isEmpty else { continue }
            var next = expected[fromClient] ?? tcp.sequence
            if SequenceMath.less(next, tcp.sequence) {
                // Trou : le segment attend que les données précédentes arrivent.
                buffered[fromClient]![tcp.sequence] = (payload, member.id)
                expected[fromClient] = next
                continue
            }
            let skip = Int(next &- tcp.sequence)
            if skip < payload.count {
                deliver(fromClient, Array(payload[skip...]), member.id)
                next = tcp.sequence &+ UInt32(payload.count)
            }
            // Segments mis de côté qui suivent maintenant.
            var progressed = true
            while progressed {
                progressed = false
                for (seq, item) in buffered[fromClient]! where SequenceMath.lessOrEqual(seq, next) {
                    buffered[fromClient]![seq] = nil
                    let overlap = Int(next &- seq)
                    if overlap < item.bytes.count {
                        deliver(fromClient, Array(item.bytes[overlap...]), item.number)
                        next = seq &+ UInt32(item.bytes.count)
                    }
                    progressed = true
                    break
                }
            }
            expected[fromClient] = next
        }
        // Ce qui reste en attente : un trou jamais comblé (paquet perdu par la capture).
        for side in [true, false] {
            for (seq, item) in buffered[side]!.sorted(by: { SequenceMath.less($0.key, $1.key) }) {
                if let next = expected[side], SequenceMath.less(next, seq) { stream.missingBytes += Int(seq &- next) }
                deliver(side, item.bytes, item.number)
                expected[side] = seq &+ UInt32(item.bytes.count)
            }
        }
        return stream
    }

    // MARK: Statistiques

    public func statistics(of subset: [CapturedPacket]? = nil) -> CaptureStatistics {
        let list = subset ?? packets
        var stats = CaptureStatistics()
        stats.packetCount = list.count
        stats.byteCount = list.reduce(0) { $0 + $1.length }
        if let first = list.first, let last = list.last { stats.duration = last.record.timestamp - first.record.timestamp }
        var protocols: [PacketProtocol: ProtocolStatistic] = [:]
        var conversations: [ConversationKey: ConversationStatistic] = [:]
        var talkers: [String: TalkerStatistic] = [:]
        for packet in list {
            for kind in Set(packet.decoded.protocols) {
                protocols[kind, default: ProtocolStatistic(kind: kind)].packets += 1
                protocols[kind]!.bytes += packet.length
            }
            if let key = packet.conversation {
                var entry = conversations[key] ?? ConversationStatistic(key: key, start: packet.relativeTime)
                entry.packets += 1
                entry.bytes += packet.length
                let fromA = packet.decoded.ipSource.map { $0 == key.a.address && (key.a.port == nil || key.a.port == packet.decoded.transport?.sourcePort) }
                    ?? (packet.decoded.ethSource?.formatted() == key.a.address)
                if fromA { entry.packetsAToB += 1; entry.bytesAToB += packet.length } else { entry.packetsBToA += 1; entry.bytesBToA += packet.length }
                entry.end = packet.relativeTime
                conversations[key] = entry
            }
            let source = packet.decoded.ipSource ?? packet.decoded.ethSource?.formatted()
            let destination = packet.decoded.ipDestination ?? packet.decoded.ethDestination?.formatted()
            if let source {
                talkers[source, default: TalkerStatistic(address: source)].packetsSent += 1
                talkers[source]!.bytesSent += packet.length
            }
            if let destination {
                talkers[destination, default: TalkerStatistic(address: destination)].packetsReceived += 1
                talkers[destination]!.bytesReceived += packet.length
            }
            for flag in packet.analysis { stats.analysis[flag, default: 0] += 1 }
        }
        stats.protocols = protocols.values.sorted { $0.packets == $1.packets ? $0.kind.label < $1.kind.label : $0.packets > $1.packets }
        stats.conversations = conversations.values.sorted { $0.bytes == $1.bytes ? $0.key.label < $1.key.label : $0.bytes > $1.bytes }
        stats.talkers = talkers.values.sorted { $0.bytesSent == $1.bytesSent ? $0.address < $1.address : $0.bytesSent > $1.bytesSent }
        return stats
    }
}

/// Morceau d'un flux suivi : données envoyées d'un côté sans interruption.
public struct FlowChunk: Sendable, Equatable {
    public var fromClient: Bool
    public var data: [UInt8]
    /// Numéro du premier paquet du morceau.
    public var firstPacket: Int
}

/// Flux TCP ou UDP reconstitué (« Suivre le flux »).
public struct FlowStream: Sendable, Equatable {
    public var key: ConversationKey
    public var client: Endpoint
    public var server: Endpoint
    public var chunks: [FlowChunk] = []
    public var clientBytes = 0
    public var serverBytes = 0
    /// Octets manquants (segments jamais capturés).
    public var missingBytes = 0
    public var packetNumbers: [Int] = []

    public init(key: ConversationKey, client: Endpoint, server: Endpoint) {
        self.key = key
        self.client = client
        self.server = server
    }

    /// Données d'un côté, bout à bout.
    public func data(fromClient: Bool) -> [UInt8] { chunks.filter { $0.fromClient == fromClient }.flatMap(\.data) }

    /// Texte lisible : caractères imprimables, « . » pour le reste, retours à la ligne gardés.
    public static func printable(_ bytes: [UInt8]) -> String {
        var text = ""
        text.reserveCapacity(bytes.count)
        for byte in bytes where byte != 0x0D {
            text.append(byte == 0x0A || byte == 0x09 ? Character(UnicodeScalar(byte)) : PacketText.ascii(byte))
        }
        return text
    }
}

public struct ProtocolStatistic: Sendable, Equatable, Identifiable {
    public var kind: PacketProtocol
    public var packets = 0
    public var bytes = 0
    public var id: String { kind.rawValue }
}

public struct ConversationStatistic: Sendable, Equatable, Identifiable {
    public var key: ConversationKey
    public var packets = 0
    public var bytes = 0
    public var packetsAToB = 0
    public var bytesAToB = 0
    public var packetsBToA = 0
    public var bytesBToA = 0
    public var start: Double
    public var end: Double = 0
    public var id: String { "\(key.kind.rawValue) \(key.label)" }
    public var duration: Double { max(0, end - start) }

    public init(key: ConversationKey, start: Double) {
        self.key = key
        self.start = start
        end = start
    }
}

public struct TalkerStatistic: Sendable, Equatable, Identifiable {
    public var address: String
    public var packetsSent = 0
    public var bytesSent = 0
    public var packetsReceived = 0
    public var bytesReceived = 0
    public var id: String { address }
}

/// Statistiques d'une capture : protocoles, conversations, plus gros émetteurs, analyse TCP.
public struct CaptureStatistics: Sendable, Equatable {
    public var packetCount = 0
    public var byteCount = 0
    public var duration: Double = 0
    public var protocols: [ProtocolStatistic] = []
    public var conversations: [ConversationStatistic] = []
    public var talkers: [TalkerStatistic] = []
    public var analysis: [TCPAnalysisFlag: Int] = [:]

    public init() {}

    public func count(_ flag: TCPAnalysisFlag) -> Int { analysis[flag] ?? 0 }
}

/// Limites d'une capture : durée, nombre de paquets, taille totale. nil : sans limite.
public struct CaptureLimits: Sendable, Equatable {
    public var seconds: Int?
    public var packets: Int?
    public var bytes: Int?

    public init(seconds: Int? = nil, packets: Int? = nil, bytes: Int? = nil) {
        self.seconds = seconds
        self.packets = packets
        self.bytes = bytes
    }

    public enum Reason: String, Sendable, Equatable {
        case duration, packets, size

        public var label: String {
            switch self {
            case .duration: return "durée atteinte"
            case .packets: return "nombre de paquets atteint"
            case .size: return "taille atteinte"
            }
        }
    }

    /// Première limite atteinte, ou nil.
    public func reached(packets count: Int, bytes total: Int, elapsed: TimeInterval) -> Reason? {
        if let packets, count >= packets { return .packets }
        if let bytes, total >= bytes { return .size }
        if let seconds, elapsed >= TimeInterval(seconds) { return .duration }
        return nil
    }

    /// Enregistrements gardés quand un lot dépasse la limite de paquets ou de taille.
    public func admissible(_ records: [PacketRecord], alreadyPackets: Int, alreadyBytes: Int) -> [PacketRecord] {
        var kept: [PacketRecord] = []
        var count = alreadyPackets, total = alreadyBytes
        for record in records {
            if let packets, count >= packets { break }
            if let bytes, total >= bytes { break }
            kept.append(record)
            count += 1
            total += record.originalLength
        }
        return kept
    }
}
