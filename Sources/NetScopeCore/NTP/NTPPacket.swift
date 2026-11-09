import Foundation

/// Horodatage NTP sur 64 bits : secondes depuis 1900 (32 bits) et fraction (32 bits). Le compteur
/// de secondes revient à zéro le 7 février 2036 : la valeur brute ne dit pas son ère.
public struct NTPTimestamp: Equatable, Sendable {
    public var raw: UInt64

    static let secondsFrom1900To1970: Int64 = 2_208_988_800
    private static let fractionScale = 4_294_967_296.0
    private static let eraLength: Int64 = 1 << 32

    public init(raw: UInt64) { self.raw = raw }

    public init(date: Date) {
        let unix = date.timeIntervalSince1970
        let whole = unix.rounded(.down)
        let seconds = UInt32(truncatingIfNeeded: Int64(whole) + Self.secondsFrom1900To1970)
        let fraction = UInt32(min((unix - whole) * Self.fractionScale, Self.fractionScale - 1))
        raw = UInt64(seconds) << 32 | UInt64(fraction)
    }

    public var isZero: Bool { raw == 0 }
    var seconds: UInt32 { UInt32(raw >> 32) }
    var fraction: UInt32 { UInt32(truncatingIfNeeded: raw) }

    /// Écart signé `self - other` en secondes : la soustraction modulo 2^64 reste juste de part
    /// et d'autre d'un changement d'ère, tant que les deux instants sont à moins de 68 ans.
    public func seconds(since other: NTPTimestamp) -> Double {
        Double(Int64(bitPattern: raw &- other.raw)) / Self.fractionScale
    }

    /// Date de cet horodatage, dans l'ère la plus proche de `pivot` (l'horloge de ce Mac).
    public func date(near pivot: Date) -> Date {
        let pivotSeconds = Int64(pivot.timeIntervalSince1970.rounded(.down)) + Self.secondsFrom1900To1970
        let distance = Double(pivotSeconds - Int64(seconds)) / Double(Self.eraLength)
        let era = Int64(distance.rounded())
        let unix = era * Self.eraLength + Int64(seconds) - Self.secondsFrom1900To1970
        return Date(timeIntervalSince1970: Double(unix) + Double(fraction) / Self.fractionScale)
    }
}

/// Paquet SNTP v4 (RFC 5905, 48 octets, sans extension ni authentifiant).
public struct NTPPacket: Equatable, Sendable {
    public static let size = 48
    static let clientMode = 3
    static let serverMode = 4

    public var leap = 0
    public var version = 4
    public var mode = NTPPacket.clientMode
    public var stratum = 0
    public var poll = 0
    public var precision = 0
    /// Virgule fixe 16.16, en secondes.
    public var rootDelay: UInt32 = 0
    public var rootDispersion: UInt32 = 0
    public var referenceID: [UInt8] = [0, 0, 0, 0]
    public var referenceTime = NTPTimestamp(raw: 0)
    public var originTime = NTPTimestamp(raw: 0)
    public var receiveTime = NTPTimestamp(raw: 0)
    public var transmitTime = NTPTimestamp(raw: 0)

    public init() {}

    /// Requête cliente : seul l'horodatage d'émission est renseigné (RFC 9109, rien sur ce Mac).
    public static func request(transmit: NTPTimestamp) -> NTPPacket {
        var packet = NTPPacket()
        packet.transmitTime = transmit
        return packet
    }

    public func encoded() -> [UInt8] {
        func bigEndian32(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func bigEndian64(_ value: NTPTimestamp) -> [UInt8] {
            bigEndian32(value.seconds) + bigEndian32(value.fraction)
        }
        let first = UInt8(leap & 0x03) << 6 | UInt8(version & 0x07) << 3 | UInt8(mode & 0x07)
        var bytes: [UInt8] = [first, UInt8(truncatingIfNeeded: stratum), UInt8(bitPattern: Int8(truncatingIfNeeded: poll)),
                              UInt8(bitPattern: Int8(truncatingIfNeeded: precision))]
        bytes += bigEndian32(rootDelay) + bigEndian32(rootDispersion) + referenceID.prefix(4)
        bytes += bigEndian64(referenceTime) + bigEndian64(originTime) + bigEndian64(receiveTime) + bigEndian64(transmitTime)
        return bytes
    }

    /// Lit un paquet ; nil s'il est trop court. Les octets au-delà de 48 (extensions) sont ignorés.
    public init?(bytes: [UInt8]) {
        guard bytes.count >= Self.size else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        func stamp(_ offset: Int) -> NTPTimestamp { NTPTimestamp(raw: UInt64(u32(offset)) << 32 | UInt64(u32(offset + 4))) }
        leap = Int(bytes[0] >> 6)
        version = Int(bytes[0] >> 3 & 0x07)
        mode = Int(bytes[0] & 0x07)
        stratum = Int(bytes[1])
        poll = Int(Int8(bitPattern: bytes[2]))
        precision = Int(Int8(bitPattern: bytes[3]))
        rootDelay = u32(4)
        rootDispersion = u32(8)
        referenceID = Array(bytes[12..<16])
        referenceTime = stamp(16)
        originTime = stamp(24)
        receiveTime = stamp(32)
        transmitTime = stamp(40)
    }

    /// Code ASCII de 4 lettres au plus ; nil si ces octets n'en sont pas un.
    private var referenceASCII: String? {
        let trimmed = referenceID.reversed().drop { $0 == 0 }.reversed()
        guard !trimmed.isEmpty, trimmed.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: trimmed, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Identifiant de référence lisible : code ASCII en strate 0 ou 1, adresse IPv4 au-delà.
    public var referenceText: String {
        guard stratum <= 1 else { return referenceID.map(String.init).joined(separator: ".") }
        return referenceASCII ?? referenceID.map { String(format: "%02X", $0) }.joined()
    }

    /// Code Kiss-o'-Death (RATE, DENY, RSTR…) d'un paquet de strate 0.
    public var kissCode: String? { stratum == 0 ? referenceASCII : nil }
}

/// Raison du rejet d'un datagramme reçu en réponse.
public enum NTPReplyError: Error, Equatable, Sendable {
    case tooShort(Int)
    case wrongMode(Int)
    case originMismatch
    case emptyTransmit
}

public extension NTPPacket {
    /// Valide une réponse : une réponse dont l'origine n'est pas l'émission envoyée, ou d'un autre
    /// mode que serveur, est forgée ou périmée. L'émission nulle est tolérée en strate 0, où un
    /// serveur qui refuse n'a pas d'heure à donner.
    static func reply(_ bytes: [UInt8], expectedOrigin: NTPTimestamp) throws -> NTPPacket {
        guard let packet = NTPPacket(bytes: bytes) else { throw NTPReplyError.tooShort(bytes.count) }
        guard packet.mode == serverMode else { throw NTPReplyError.wrongMode(packet.mode) }
        guard packet.originTime == expectedOrigin else { throw NTPReplyError.originMismatch }
        guard packet.stratum == 0 || !packet.transmitTime.isZero else { throw NTPReplyError.emptyTransmit }
        return packet
    }
}

/// Les quatre instants d'un échange : t1 émission du client, t2 réception au serveur, t3 émission
/// du serveur, t4 réception au client.
public struct NTPTimes: Equatable, Sendable {
    public var t1, t2, t3, t4: NTPTimestamp

    public init(t1: NTPTimestamp, t2: NTPTimestamp, t3: NTPTimestamp, t4: NTPTimestamp) {
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
        self.t4 = t4
    }

    /// Positif : le serveur est en avance sur ce Mac.
    public var offset: Double { (t2.seconds(since: t1) + t3.seconds(since: t4)) / 2 }
    public var roundTrip: Double { t4.seconds(since: t1) - t3.seconds(since: t2) }
}
