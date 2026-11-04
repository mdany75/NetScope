import Foundation

/// Archive ZIP minimale, sans compression (méthode « stored ») : lisible par le Finder,
/// Archive Utility et unzip. Sert aux sauvegardes de NetScope (petits fichiers JSON).
public enum BackupZip {
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public enum ZipError: Error, LocalizedError, Equatable {
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let why): return "Archive de sauvegarde illisible : \(why)."
            }
        }
    }

    // MARK: Écriture

    public static func archive(_ entries: [Entry], date: Date = Date()) -> Data {
        let (dosTime, dosDate) = dos(date)
        var output = Data()
        var central = Data()
        for entry in entries {
            let name = Array(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let offset = UInt32(output.count)
            // En-tête local.
            output.append(le32(0x0403_4B50))
            output.append(le16(20))            // version nécessaire
            output.append(le16(0x0800))        // noms en UTF-8
            output.append(le16(0))             // méthode : stored
            output.append(le16(dosTime))
            output.append(le16(dosDate))
            output.append(le32(crc))
            output.append(le32(UInt32(entry.data.count)))
            output.append(le32(UInt32(entry.data.count)))
            output.append(le16(UInt16(name.count)))
            output.append(le16(0))
            output.append(contentsOf: name)
            output.append(entry.data)
            // Entrée du répertoire central.
            central.append(le32(0x0201_4B50))
            central.append(le16(0x031E))       // créé par : Unix, version 3.0
            central.append(le16(20))
            central.append(le16(0x0800))
            central.append(le16(0))
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(UInt32(entry.data.count)))
            central.append(le32(UInt32(entry.data.count)))
            central.append(le16(UInt16(name.count)))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le32(0o100644 << 16))  // attributs : fichier rw-r--r--
            central.append(le32(offset))
            central.append(contentsOf: name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(le32(0x0605_4B50))
        output.append(le16(0))
        output.append(le16(0))
        output.append(le16(UInt16(entries.count)))
        output.append(le16(UInt16(entries.count)))
        output.append(le32(UInt32(central.count)))
        output.append(le32(centralOffset))
        output.append(le16(0))
        return output
    }

    // MARK: Lecture

    /// Entrées d'une archive « stored » (celles que NetScope écrit) ; CRC vérifié.
    public static func entries(of data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.invalid("fichier trop court") }
        // Fin du répertoire central : cherchée depuis la fin (commentaire éventuel).
        var eocd = -1
        var index = bytes.count - 22
        while index >= max(0, bytes.count - 22 - 65_535) {
            if read32(bytes, index) == 0x0605_4B50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalid("fin d’archive introuvable") }
        let count = Int(read16(bytes, eocd + 10))
        var position = Int(read32(bytes, eocd + 16))
        var result: [Entry] = []
        for _ in 0..<count {
            guard position + 46 <= bytes.count, read32(bytes, position) == 0x0201_4B50 else { throw ZipError.invalid("répertoire central") }
            let method = read16(bytes, position + 10)
            let crc = read32(bytes, position + 16)
            let size = Int(read32(bytes, position + 20))
            let nameLength = Int(read16(bytes, position + 28))
            let extraLength = Int(read16(bytes, position + 30))
            let commentLength = Int(read16(bytes, position + 32))
            let localOffset = Int(read32(bytes, position + 42))
            guard position + 46 + nameLength <= bytes.count else { throw ZipError.invalid("nom tronqué") }
            let name = String(decoding: bytes[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
            position += 46 + nameLength + extraLength + commentLength
            guard method == 0 else { throw ZipError.invalid("« \(name) » est compressé (méthode \(method) non prise en charge)") }
            guard localOffset + 30 <= bytes.count, read32(bytes, localOffset) == 0x0403_4B50 else { throw ZipError.invalid("en-tête local") }
            let start = localOffset + 30 + Int(read16(bytes, localOffset + 26)) + Int(read16(bytes, localOffset + 28))
            guard start + size <= bytes.count else { throw ZipError.invalid("« \(name) » tronqué") }
            let content = Data(bytes[start..<(start + size)])
            guard CRC32.checksum(content) == crc else { throw ZipError.invalid("somme de contrôle de « \(name) »") }
            if name.hasSuffix("/") { continue }
            result.append(Entry(path: name, data: content))
        }
        return result
    }

    // MARK: Outils

    static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    static func read16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    static func read32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    /// Date et heure au format MS-DOS (heure locale).
    static func dos(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, parts.year ?? 1980) - 1980
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

/// CRC-32 (IEEE 802.3), celui des archives ZIP.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
