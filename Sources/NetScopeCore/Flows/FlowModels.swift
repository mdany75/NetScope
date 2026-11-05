import Foundation

// Note 75 : collecteur de flux intégré (NetFlow v5 et v9, IPFIX, sFlow v5). Modèles purs, sans
// réseau : un enregistrement de flux décodé, les compteurs d'interface de sFlow et le résultat du
// décodage d'un datagramme.

/// Format d'un datagramme de flux.
public enum FlowProtocolKind: String, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case netflow5, netflow9, ipfix, sflow

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .netflow5: return "NetFlow\u{00A0}v5"
        case .netflow9: return "NetFlow\u{00A0}v9"
        case .ipfix: return "IPFIX"
        case .sflow: return "sFlow\u{00A0}v5"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Un flux décodé (une conversation dans un sens), tel que l'exportateur l'a vu.
///
/// Les volumes sont ceux du datagramme : `samplingRate` dit par combien les multiplier (1 sans
/// échantillonnage ; sFlow et NetFlow échantillonné donnent 1 paquet sur N).
public struct FlowRecord: Hashable, Sendable {
    public var kind: FlowProtocolKind
    /// Équipement qui a envoyé le datagramme (adresse vue par ce Mac).
    public var exporter: IPv4Address
    /// Source ID (NetFlow v9), domaine d'observation (IPFIX), moteur (v5) ou sous-agent (sFlow).
    public var domain: UInt32
    public var source: IPv4Address?
    public var destination: IPv4Address?
    /// Flux IPv6 : décodé, mais pas compté dans les tableaux (adresses IPv4 seulement).
    public var isIPv6: Bool
    public var sourcePort: UInt16
    public var destinationPort: UInt16
    /// Numéro de protocole IP (6 TCP, 17 UDP, 1 ICMP…).
    public var proto: UInt8
    public var bytes: UInt64
    public var packets: UInt64
    /// Octets dans l'autre sens, quand l'exportateur les donne dans le même enregistrement
    /// (Cisco ASA, champs responderOctets).
    public var reverseBytes: UInt64
    public var inputInterface: UInt32?
    public var outputInterface: UInt32?
    public var tcpFlags: UInt8
    /// Durée du flux en millisecondes, si l'exportateur la donne.
    public var durationMs: UInt32?
    /// 1 paquet sur `samplingRate` a été vu (1 : aucun échantillonnage).
    public var samplingRate: UInt32

    public init(kind: FlowProtocolKind, exporter: IPv4Address, domain: UInt32 = 0, source: IPv4Address?, destination: IPv4Address?,
                isIPv6: Bool = false, sourcePort: UInt16 = 0, destinationPort: UInt16 = 0, proto: UInt8, bytes: UInt64,
                packets: UInt64 = 1, reverseBytes: UInt64 = 0, inputInterface: UInt32? = nil, outputInterface: UInt32? = nil,
                tcpFlags: UInt8 = 0, durationMs: UInt32? = nil, samplingRate: UInt32 = 1) {
        self.kind = kind
        self.exporter = exporter
        self.domain = domain
        self.source = source
        self.destination = destination
        self.isIPv6 = isIPv6
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.proto = proto
        self.bytes = bytes
        self.packets = packets
        self.reverseBytes = reverseBytes
        self.inputInterface = inputInterface
        self.outputInterface = outputInterface
        self.tcpFlags = tcpFlags
        self.durationMs = durationMs
        self.samplingRate = max(1, samplingRate)
    }

    /// Octets estimés (échantillonnage appliqué).
    public var estimatedBytes: UInt64 { FlowMath.multiply(bytes, samplingRate) }
    public var estimatedReverseBytes: UInt64 { FlowMath.multiply(reverseBytes, samplingRate) }
    public var estimatedPackets: UInt64 { FlowMath.multiply(packets, samplingRate) }
}

/// Compteurs d'une interface envoyés par sFlow (échantillon de compteurs, « generic interface »).
public struct FlowInterfaceCounters: Hashable, Sendable {
    public var exporter: IPv4Address
    public var ifIndex: UInt32
    /// Vitesse de l'interface, en bits par seconde (0 : inconnue).
    public var speed: UInt64
    /// ifOperStatus : vrai si l'interface est montée.
    public var isUp: Bool
    public var inOctets: UInt64
    public var outOctets: UInt64
    public var inErrors: UInt32
    public var outErrors: UInt32
    public var inDiscards: UInt32
    public var outDiscards: UInt32

    public init(exporter: IPv4Address, ifIndex: UInt32, speed: UInt64, isUp: Bool, inOctets: UInt64, outOctets: UInt64,
                inErrors: UInt32 = 0, outErrors: UInt32 = 0, inDiscards: UInt32 = 0, outDiscards: UInt32 = 0) {
        self.exporter = exporter
        self.ifIndex = ifIndex
        self.speed = speed
        self.isUp = isUp
        self.inOctets = inOctets
        self.outOctets = outOctets
        self.inErrors = inErrors
        self.outErrors = outErrors
        self.inDiscards = inDiscards
        self.outDiscards = outDiscards
    }
}

/// Résultat du décodage d'un datagramme.
public struct FlowDecodeResult: Sendable {
    public var kind: FlowProtocolKind
    public var domain: UInt32
    public var records: [FlowRecord]
    public var counters: [FlowInterfaceCounters]
    /// Gabarits appris (ou renouvelés) dans ce datagramme.
    public var templatesLearned: Int
    /// Ensembles de données mis de côté faute de gabarit (décodés à l'arrivée du gabarit).
    public var setsWaiting: Int
    /// Enregistrements décodés depuis des ensembles mis de côté plus tôt.
    public var recoveredRecords: Int
    /// Échantillonnage annoncé par l'exportateur (en-tête v5 ou options v9/IPFIX).
    public var samplingRate: UInt32?

    public init(kind: FlowProtocolKind, domain: UInt32 = 0, records: [FlowRecord] = [], counters: [FlowInterfaceCounters] = [],
                templatesLearned: Int = 0, setsWaiting: Int = 0, recoveredRecords: Int = 0, samplingRate: UInt32? = nil) {
        self.kind = kind
        self.domain = domain
        self.records = records
        self.counters = counters
        self.templatesLearned = templatesLearned
        self.setsWaiting = setsWaiting
        self.recoveredRecords = recoveredRecords
        self.samplingRate = samplingRate
    }
}

/// Datagramme illisible, expliqué en clair.
public struct FlowDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }

    static let truncated = FlowDecodeError("datagramme tronqué")
}

enum FlowMath {
    /// Produit saturé (jamais de débordement).
    static func multiply(_ value: UInt64, _ factor: UInt32) -> UInt64 {
        let (result, overflow) = value.multipliedReportingOverflow(by: UInt64(factor))
        return overflow ? .max : result
    }

    static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : result
    }
}

/// Lecture d'octets en ordre réseau (big-endian), bornée : toute lecture hors limites lève
/// `FlowDecodeError.truncated` au lieu de planter.
struct FlowByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int
    let end: Int

    init(_ bytes: [UInt8], offset: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.offset = offset
        self.end = min(end ?? bytes.count, bytes.count)
    }

    var remaining: Int { max(0, end - offset) }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw FlowDecodeError.truncated }
        offset += count
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw FlowDecodeError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        UInt16(try uint(2))
    }

    mutating func u32() throws -> UInt32 {
        UInt32(try uint(4))
    }

    mutating func u64() throws -> UInt64 {
        try uint(8)
    }

    /// Entier non signé de 1 à 8 octets.
    mutating func uint(_ length: Int) throws -> UInt64 {
        guard length >= 0, length <= 8, remaining >= length else { throw FlowDecodeError.truncated }
        var value: UInt64 = 0
        for i in 0..<length { value = value << 8 | UInt64(bytes[offset + i]) }
        offset += length
        return value
    }

    mutating func take(_ length: Int) throws -> ArraySlice<UInt8> {
        guard length >= 0, length <= remaining else { throw FlowDecodeError.truncated }
        defer { offset += length }
        return bytes[offset..<(offset + length)]
    }

    mutating func ipv4() throws -> IPv4Address {
        IPv4Address(try u32())
    }

    /// Lecteur limité aux `length` octets suivants (avance d'autant).
    mutating func sub(_ length: Int) throws -> FlowByteReader {
        guard length >= 0, length <= remaining else { throw FlowDecodeError.truncated }
        let reader = FlowByteReader(bytes, offset: offset, end: offset + length)
        offset += length
        return reader
    }
}

/// Entier big-endian d'une tranche (1 à 8 octets ; au-delà, les 8 derniers).
func flowUInt<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
    var value: UInt64 = 0
    for byte in bytes.suffix(8) { value = value << 8 | UInt64(byte) }
    return value
}
