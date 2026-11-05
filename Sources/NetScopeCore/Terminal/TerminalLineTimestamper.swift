import Foundation

/// Note 78 (Accès distant) : horodatage des lignes reçues en console série (option de l'onglet).
/// « [10:41:07.123] » est inséré, grisé (SGR 2, puis 22 : seule l'intensité est rétablie, la
/// couleur de l'appareil reste), devant le premier octet de chaque ligne ; une ligne vide (CR ou LF
/// seuls) n'en reçoit pas, et un CR seul (ligne réécrite) ne commence pas de nouvelle ligne. Le
/// journal de session garde l'horodatage (texte brut).
public struct TerminalLineTimestamper: Sendable {
    /// Le prochain octet commence une ligne.
    public private(set) var atLineStart = true
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    /// Octets reçus, horodatés ; `now` est appelé une fois par ligne commencée.
    public mutating func feed(_ bytes: [UInt8], now: () -> Date) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 24)
        for byte in bytes {
            switch byte {
            case 0x0A:
                output.append(byte)
                atLineStart = true
            case 0x0D:
                output.append(byte)
            default:
                if atLineStart {
                    output += Array(("\u{1B}[2m[" + Self.stamp(now(), timeZone: timeZone) + "]\u{1B}[22m ").utf8)
                    atLineStart = false
                }
                output.append(byte)
            }
        }
        return output
    }

    /// Recommence (port rouvert).
    public mutating func reset() {
        atLineStart = true
    }

    /// « 10:41:07.123 ».
    public static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let millis = min(999, (parts.nanosecond ?? 0) / 1_000_000)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(two(parts.hour)):\(two(parts.minute)):\(two(parts.second)).\(String(format: "%03d", millis))"
    }
}
