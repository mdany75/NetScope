import Darwin
import Foundation

/// Trame Ethernet capturée (par BPF ou par tcpdump) : octets bruts depuis l'adresse de destination.
public struct CapturedFrame: Equatable, Sendable {
    public var bytes: [UInt8]
    public var date: Date?

    public init(bytes: [UInt8], date: Date? = nil) {
        self.bytes = bytes
        self.date = date
    }
}

/// En-tête Ethernet II ou IEEE 802.3, avec une étiquette 802.1Q (ou 802.1ad) éventuelle.
public struct EthernetHeader: Equatable, Sendable {
    public var destination: MACAddress
    public var source: MACAddress
    /// VLAN de l'étiquette 802.1Q, si la trame en porte une.
    public var vlanTag: Int?
    /// EtherType (0x0600 ou plus) ou longueur 802.3 (moins de 0x0600).
    public var typeOrLength: UInt16
    /// Position de la charge utile dans la trame.
    public var payloadOffset: Int

    /// Trame 802.3 (champ longueur suivi d'un en-tête LLC), comme CDP.
    public var isLLC: Bool { typeOrLength < 0x0600 }

    public static func parse(_ bytes: [UInt8]) -> EthernetHeader? {
        guard bytes.count >= 14 else { return nil }
        let destination = MACAddress(bytes: Array(bytes[0..<6]))
        let source = MACAddress(bytes: Array(bytes[6..<12]))
        var offset = 12
        var type = CaptureBytes.u16(bytes, offset)
        var vlan: Int?
        // Étiquettes 802.1Q (0x8100) et 802.1ad (0x88A8) : on garde le VLAN le plus intérieur.
        while type == 0x8100 || type == 0x88A8 {
            guard bytes.count >= offset + 6 else { return nil }
            vlan = Int(CaptureBytes.u16(bytes, offset + 2) & 0x0FFF)
            offset += 4
            type = CaptureBytes.u16(bytes, offset)
        }
        return EthernetHeader(destination: destination, source: source, vlanTag: vlan, typeOrLength: type, payloadOffset: offset + 2)
    }
}

/// Lecture d'entiers gros-boutistes dans un tableau d'octets (sans débordement : 0 hors limites).
enum CaptureBytes {
    static func u8(_ b: [UInt8], _ i: Int) -> UInt8 { i >= 0 && i < b.count ? b[i] : 0 }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(u8(b, i)) << 8 | UInt16(u8(b, i + 1)) }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(u8(b, i)) << 24 | UInt32(u8(b, i + 1)) << 16 | UInt32(u8(b, i + 2)) << 8 | UInt32(u8(b, i + 3))
    }

    /// Entier petit-boutiste (en-têtes BPF, écrits dans l'ordre de la machine).
    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(u8(b, i)) | UInt32(u8(b, i + 1)) << 8 | UInt32(u8(b, i + 2)) << 16 | UInt32(u8(b, i + 3)) << 24
    }

    static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(u8(b, i)) | UInt16(u8(b, i + 1)) << 8 }

    /// Texte UTF-8 (ou Latin-1 en secours), sans les caractères de contrôle ni les espaces de fin.
    static func text(_ bytes: ArraySlice<UInt8>) -> String {
        let raw = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let cleaned = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) && $0 != "\n" ? " " : String($0) }.joined()
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hex(_ bytes: ArraySlice<UInt8>, separator: String = " ") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }
}

/// Nom d'interface accepté pour une capture : lettres minuscules et chiffres seulement (« en7 »).
/// C'est la seule valeur variable de la commande tcpdump : tout le reste est fixe.
public enum CaptureInterfaceName {
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 15 else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
}

/// Adresse matérielle d'une interface locale (getifaddrs, AF_LINK) : lecture locale, aucun trafic.
public enum LinkLayer {
    public static func macAddress(of interface: String) -> MACAddress? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.ifa_name) == interface else { continue }
            let mac: MACAddress? = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                let nameLength = Int(dl.pointee.sdl_nlen)
                let addressLength = Int(dl.pointee.sdl_alen)
                guard addressLength == 6 else { return nil }
                let base = UnsafeRawPointer(dl).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + nameLength)
                let bytes = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                return MACAddress(bytes: bytes)
            }
            if let mac, mac.value != 0 { return mac }
        }
        return nil
    }
}
