import Foundation

/// Un paquet enregistré : horodatage, octets capturés, longueur d'origine et type de liaison.
public struct PacketRecord: Sendable, Equatable {
    /// Secondes depuis le 1er janvier 1970 (précision microseconde ou nanoseconde).
    public var timestamp: TimeInterval
    public var data: [UInt8]
    /// Longueur du paquet sur le fil (plus grande que `data` si la capture l'a tronqué).
    public var originalLength: Int
    public var linkType: UInt32

    public init(timestamp: TimeInterval, data: [UInt8], originalLength: Int? = nil, linkType: UInt32 = PcapLinkType.ethernet) {
        self.timestamp = timestamp
        self.data = data
        self.originalLength = originalLength ?? data.count
        self.linkType = linkType
    }
}

/// Erreurs de lecture d'un fichier de capture.
public enum PcapError: Error, LocalizedError, Equatable, Sendable {
    case notACapture
    case unsupportedVersion(String)
    case mixedLinkTypes
    case empty

    public var errorDescription: String? {
        switch self {
        case .notACapture: return "Ce fichier n’est pas une capture pcap ni pcapng."
        case .unsupportedVersion(let text): return "Format de capture non pris en charge\u{00A0}: \(text)."
        case .mixedLinkTypes: return "Ces paquets mélangent plusieurs types de liaison\u{00A0}: le format pcap classique n’en accepte qu’un."
        case .empty: return "Aucun paquet à enregistrer."
        }
    }
}

/// Fichiers de capture : pcap classique de libpcap (lecture et écriture, ouvrable dans Wireshark et
/// tcpdump) et pcapng (lecture : sections, interfaces, blocs de paquets améliorés et simples).
public enum PcapFile {
    public static let magicMicro: UInt32 = 0xA1B2_C3D4
    public static let magicNano: UInt32 = 0xA1B2_3C4D
    public static let pcapngBlock: UInt32 = 0x0A0D_0D0A
    /// Longueur maximale gardée par paquet (comme tcpdump -s 0).
    public static let defaultSnapLength: UInt32 = 262_144

    /// Lit un fichier pcap ou pcapng complet.
    public static func read(_ data: [UInt8]) throws -> [PacketRecord] {
        guard data.count >= 4 else { throw PcapError.notACapture }
        if CaptureBytes.le32(data, 0) == pcapngBlock { return try PcapNG.read(data) }
        var reader = PcapStreamReader()
        let records = try reader.feed(data)
        return records
    }

    /// En-tête global (24 octets, petit-boutiste, microsecondes, version 2.4).
    public static func header(linkType: UInt32, snapLength: UInt32 = defaultSnapLength) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendLE32(magicMicro)
        bytes.appendLE16(2)
        bytes.appendLE16(4)
        bytes.appendLE32(0)              // décalage horaire (toujours 0)
        bytes.appendLE32(0)              // précision des horodatages
        bytes.appendLE32(snapLength)
        bytes.appendLE32(linkType)
        return bytes
    }

    /// Un enregistrement : secondes, microsecondes, longueur capturée, longueur d'origine, octets.
    public static func record(_ record: PacketRecord) -> [UInt8] {
        var bytes: [UInt8] = []
        // Horodatage relu d'un pcapng exotique : borné au champ de 32 bits (jamais infini ni hors limites).
        let timestamp = record.timestamp.isFinite ? min(max(record.timestamp, 0), Double(UInt32.max)) : 0
        let seconds = floor(timestamp)
        var micros = UInt32(((timestamp - seconds) * 1_000_000).rounded())
        var whole = UInt32(seconds)
        if micros >= 1_000_000 { micros -= 1_000_000; whole &+= 1 }
        bytes.appendLE32(whole)
        bytes.appendLE32(micros)
        bytes.appendLE32(UInt32(record.data.count))
        bytes.appendLE32(UInt32(max(record.originalLength, record.data.count)))
        bytes += record.data
        return bytes
    }

    /// Fichier pcap classique : un seul type de liaison pour tous les paquets.
    public static func write(_ records: [PacketRecord]) throws -> [UInt8] {
        guard let linkType = records.first?.linkType else { throw PcapError.empty }
        guard records.allSatisfy({ $0.linkType == linkType }) else { throw PcapError.mixedLinkTypes }
        let snap = max(defaultSnapLength, UInt32(records.map(\.data.count).max() ?? 0))
        var bytes = header(linkType: linkType, snapLength: snap)
        bytes.reserveCapacity(bytes.count + records.reduce(0) { $0 + 16 + $1.data.count })
        for item in records { bytes += record(item) }
        return bytes
    }
}

/// Lecture progressive d'un pcap classique (fichier que tcpdump écrit encore) : les octets sont
/// donnés par morceaux, les paquets complets sont rendus, le reste attend le morceau suivant.
public struct PcapStreamReader: Sendable {
    private var pending: [UInt8] = []
    private var headerRead = false
    private var bigEndian = false
    private var nanoseconds = false
    public private(set) var linkType: UInt32 = PcapLinkType.ethernet
    /// Octets reçus jusqu'ici (pour lire la suite d'un fichier à partir de là).
    public private(set) var consumed = 0

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) throws -> [PacketRecord] {
        pending += bytes
        consumed += bytes.count
        var offset = 0
        if !headerRead {
            guard pending.count >= 24 else { return [] }
            let le = CaptureBytes.le32(pending, 0), be = CaptureBytes.u32(pending, 0)
            switch (le, be) {
            case (PcapFile.magicMicro, _): bigEndian = false; nanoseconds = false
            case (PcapFile.magicNano, _): bigEndian = false; nanoseconds = true
            case (_, PcapFile.magicMicro): bigEndian = true; nanoseconds = false
            case (_, PcapFile.magicNano): bigEndian = true; nanoseconds = true
            default:
                if le == PcapFile.pcapngBlock { throw PcapError.unsupportedVersion("pcapng (lecture progressive impossible)") }
                throw PcapError.notACapture
            }
            let major = u16(pending, 4)
            guard major == 2 else { throw PcapError.unsupportedVersion("version \(major).\(u16(pending, 6))") }
            linkType = u32(pending, 20) & 0x0FFF_FFFF
            headerRead = true
            offset = 24
        }
        var records: [PacketRecord] = []
        while offset + 16 <= pending.count {
            let seconds = u32(pending, offset), fraction = u32(pending, offset + 4)
            let captured = Int(u32(pending, offset + 8)), original = Int(u32(pending, offset + 12))
            guard captured <= 16 * 1024 * 1024 else { throw PcapError.unsupportedVersion("enregistrement de \(captured) octets") }
            guard offset + 16 + captured <= pending.count else { break }
            let timestamp = TimeInterval(seconds) + TimeInterval(fraction) / (nanoseconds ? 1_000_000_000 : 1_000_000)
            records.append(PacketRecord(timestamp: timestamp, data: Array(pending[(offset + 16)..<(offset + 16 + captured)]),
                                        originalLength: original, linkType: linkType))
            offset += 16 + captured
        }
        if offset > 0 { pending.removeFirst(offset) }
        return records
    }

    private func u16(_ b: [UInt8], _ i: Int) -> UInt16 { bigEndian ? CaptureBytes.u16(b, i) : CaptureBytes.le16(b, i) }
    private func u32(_ b: [UInt8], _ i: Int) -> UInt32 { bigEndian ? CaptureBytes.u32(b, i) : CaptureBytes.le32(b, i) }
}

/// Lecture des fichiers pcapng (format par défaut de Wireshark) : blocs de section (SHB),
/// de description d'interface (IDB, avec la précision des horodatages if_tsresol), de paquet
/// amélioré (EPB), de paquet simple (SPB) et l'ancien bloc de paquet. Les autres blocs (noms,
/// statistiques, journaux de déchiffrement) sont ignorés.
enum PcapNG {
    struct Interface {
        var linkType: UInt32
        var unitsPerSecond: Double
    }

    static func read(_ data: [UInt8]) throws -> [PacketRecord] {
        var offset = 0
        var bigEndian = false
        var interfaces: [Interface] = []
        var records: [PacketRecord] = []
        func u16(_ i: Int) -> UInt16 { bigEndian ? CaptureBytes.u16(data, i) : CaptureBytes.le16(data, i) }
        func u32(_ i: Int) -> UInt32 { bigEndian ? CaptureBytes.u32(data, i) : CaptureBytes.le32(data, i) }
        while offset + 12 <= data.count {
            let type = CaptureBytes.le32(data, offset)
            if type == PcapFile.pcapngBlock {
                // L'ordre des octets de la section se lit dans le « byte-order magic ».
                let magic = CaptureBytes.le32(data, offset + 8)
                if magic == 0x1A2B_3C4D { bigEndian = false } else if CaptureBytes.u32(data, offset + 8) == 0x1A2B_3C4D { bigEndian = true } else { throw PcapError.notACapture }
                interfaces = []
            }
            let blockType = u32(offset)
            let length = Int(u32(offset + 4))
            guard length >= 12, length % 4 == 0, offset + length <= data.count else {
                if records.isEmpty, interfaces.isEmpty { throw PcapError.notACapture }
                break   // fin tronquée : on garde ce qui a été lu
            }
            let body = offset + 8
            switch blockType {
            case 0x0000_0001 where length >= 20:
                var resolution = 1_000_000.0
                var o = body + 8
                while o + 4 <= offset + length - 4 {
                    let code = u16(o), optionLength = Int(u16(o + 2))
                    if code == 0 { break }
                    if code == 9, optionLength >= 1 {
                        let raw = data[o + 4]
                        resolution = raw & 0x80 != 0 ? pow(2, Double(raw & 0x7F)) : pow(10, Double(raw))
                    }
                    o += 4 + ((optionLength + 3) & ~3)
                }
                interfaces.append(Interface(linkType: UInt32(u16(body)), unitsPerSecond: resolution))
            case 0x0000_0006 where length >= 32:
                let interfaceID = Int(u32(body))
                let stamp = UInt64(u32(body + 4)) << 32 | UInt64(u32(body + 8))
                let captured = Int(u32(body + 12)), original = Int(u32(body + 16))
                guard interfaceID < interfaces.count, body + 20 + captured <= offset + length else { break }
                let interface = interfaces[interfaceID]
                records.append(PacketRecord(timestamp: Double(stamp) / interface.unitsPerSecond,
                                            data: Array(data[(body + 20)..<(body + 20 + captured)]),
                                            originalLength: original, linkType: interface.linkType))
            case 0x0000_0003 where length >= 16:
                guard let interface = interfaces.first else { break }
                let original = Int(u32(body))
                let captured = min(original, length - 16)
                records.append(PacketRecord(timestamp: 0, data: Array(data[(body + 4)..<(body + 4 + captured)]),
                                            originalLength: original, linkType: interface.linkType))
            case 0x0000_0002 where length >= 32:
                let interfaceID = Int(u16(body))
                let stamp = UInt64(u32(body + 4)) << 32 | UInt64(u32(body + 8))
                let captured = Int(u32(body + 12)), original = Int(u32(body + 16))
                guard interfaceID < interfaces.count, body + 20 + captured <= offset + length else { break }
                let interface = interfaces[interfaceID]
                records.append(PacketRecord(timestamp: Double(stamp) / interface.unitsPerSecond,
                                            data: Array(data[(body + 20)..<(body + 20 + captured)]),
                                            originalLength: original, linkType: interface.linkType))
            default:
                break
            }
            offset += length
        }
        return records
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    mutating func appendBE16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}
