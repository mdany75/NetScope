import Darwin
import Foundation

/// Lecture de la table ARP du système (état local : aucun paquet n'est émis).
public protocol ScanARPReading: Sendable {
    func read() -> [IPv4Address: MACAddress]
}

/// Un message de la table de routage (rt_msghdr suivi de ses adresses).
struct ScanRouteMessage {
    var flags: Int32
    var interfaceIndex: UInt16
    /// Adresses présentes, par indice RTAX_* (destination, passerelle, masque…), octets bruts.
    var addresses: [Int: [UInt8]]

    /// Adresse IPv4 d'une sockaddr_in brute.
    static func ipv4(_ raw: [UInt8]?) -> IPv4Address? {
        guard let raw, raw.count >= 8, raw[1] == UInt8(AF_INET) else { return nil }
        return IPv4Address(raw[4], raw[5], raw[6], raw[7])
    }

    /// Adresse matérielle d'une sockaddr_dl brute (6 octets attendus).
    static func link(_ raw: [UInt8]?) -> MACAddress? {
        guard let raw, raw.count >= 8, raw[1] == UInt8(AF_LINK) else { return nil }
        let nameLength = Int(raw[5])
        let addressLength = Int(raw[6])
        let start = 8 + nameLength
        guard addressLength == 6, raw.count >= start + 6 else { return nil }
        return MACAddress(bytes: Array(raw[start..<(start + 6)]))
    }
}

/// Lecture des tampons renvoyés par sysctl(CTL_NET, PF_ROUTE…).
enum ScanRouting {
    /// Taille de rt_msghdr sur macOS.
    static let headerSize = MemoryLayout<rt_msghdr>.size
    static let flagsOffset = MemoryLayout.offset(of: \rt_msghdr.rtm_flags) ?? 8
    static let addrsOffset = MemoryLayout.offset(of: \rt_msghdr.rtm_addrs) ?? 12
    static let indexOffset = MemoryLayout.offset(of: \rt_msghdr.rtm_index) ?? 4

    /// Arrondi des sockaddr dans les messages de routage (multiple de 4, 4 si longueur nulle).
    static func roundUp(_ length: Int) -> Int {
        length > 0 ? 1 + ((length - 1) | (MemoryLayout<UInt32>.size - 1)) : MemoryLayout<UInt32>.size
    }

    /// Découpe un tampon en messages ; ignore tout message tronqué.
    static func messages(_ buffer: [UInt8]) -> [ScanRouteMessage] {
        var result: [ScanRouteMessage] = []
        var offset = 0
        while offset + headerSize <= buffer.count {
            let length = Int(readUInt16(buffer, offset))
            guard length >= headerSize, offset + length <= buffer.count else { break }
            let flags = Int32(bitPattern: readUInt32(buffer, offset + flagsOffset))
            let addrs = Int32(bitPattern: readUInt32(buffer, offset + addrsOffset))
            let index = readUInt16(buffer, offset + indexOffset)
            var addresses: [Int: [UInt8]] = [:]
            var cursor = offset + headerSize
            let end = offset + length
            for bit in 0..<Int(RTAX_MAX) where addrs & (1 << bit) != 0 {
                guard cursor < end else { break }
                let saLength = Int(buffer[cursor])
                let available = min(saLength, end - cursor)
                if available > 0 { addresses[bit] = Array(buffer[cursor..<(cursor + available)]) }
                cursor += roundUp(saLength)
            }
            result.append(ScanRouteMessage(flags: flags, interfaceIndex: index, addresses: addresses))
            offset += length
        }
        return result
    }

    /// Tampon de sysctl(CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, flags) ; nil en cas d'échec.
    static func dump(flags: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, flags]
        // La table peut grossir entre les deux appels : quelques essais.
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return nil }
            if length == 0 { return [] }
            length += length / 4
            var buffer = [UInt8](repeating: 0, count: length)
            let status = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &length, nil, 0)
            }
            if status == 0 { return Array(buffer[0..<length]) }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    static func readUInt16(_ buffer: [UInt8], _ offset: Int) -> UInt16 {
        // Ordre des octets de la machine (petit-boutiste sur les Mac actuels).
        UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8
    }

    static func readUInt32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8 | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
    }
}

/// Table ARP : sysctl (RTF_LLINFO), repli sur « /usr/sbin/arp -an ».
public struct ARPTable: ScanARPReading {
    public init() {}

    public func read() -> [IPv4Address: MACAddress] {
        if let buffer = ScanRouting.dump(flags: RTF_LLINFO) {
            return ARPTable.parse(buffer)
        }
        return ARPTable.readWithCommand()
    }

    /// Lit un tampon sysctl : destination sockaddr_inarp, passerelle sockaddr_dl.
    /// Les entrées incomplètes, de diffusion ou multicast sont ignorées.
    public static func parse(_ buffer: [UInt8]) -> [IPv4Address: MACAddress] {
        var table: [IPv4Address: MACAddress] = [:]
        for message in ScanRouting.messages(buffer) {
            guard let ip = ScanRouteMessage.ipv4(message.addresses[Int(RTAX_DST)]),
                  let mac = ScanRouteMessage.link(message.addresses[Int(RTAX_GATEWAY)]),
                  mac.value != 0, !mac.isBroadcast, !mac.isMulticast else { continue }
            table[ip] = mac
        }
        return table
    }

    /// Repli : sortie de « arp -an » (« ? (10.0.0.1) at 4:d5:90:3a:7b:11 on en0 ifscope [ethernet] »).
    public static func parseCommandOutput(_ text: String) -> [IPv4Address: MACAddress] {
        var table: [IPv4Address: MACAddress] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")"),
                  let ip = IPv4Address(String(line[line.index(after: open)..<close])) else { continue }
            let rest = line[close...]
            guard let atRange = rest.range(of: " at ") else { continue }
            let macText = rest[atRange.upperBound...].prefix { !$0.isWhitespace }
            guard let mac = MACAddress(String(macText)), mac.value != 0, !mac.isBroadcast, !mac.isMulticast else { continue }
            table[ip] = mac
        }
        return table
    }

    static func readWithCommand() -> [IPv4Address: MACAddress] {
        guard let output = ScanShell.run("/usr/sbin/arp", ["-an"]) else { return [:] }
        return parseCommandOutput(output)
    }
}

/// Exécution d'une commande système locale (lecture seule), avec un délai maximal.
enum ScanShell {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
