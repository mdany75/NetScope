import Foundation

/// Une ligne de la table des noms NetBIOS d'un hôte.
public struct NetBIOSNameEntry: Hashable, Sendable {
    /// Nom sans les espaces de remplissage (15 caractères au plus).
    public var name: String
    /// 16ᵉ octet : 0x00 poste ou groupe de travail, 0x20 serveur de fichiers, 0x1D/0x1E navigateur…
    public var suffix: UInt8
    public var isGroup: Bool

    public init(name: String, suffix: UInt8, isGroup: Bool) {
        self.name = name
        self.suffix = suffix
        self.isGroup = isGroup
    }
}

/// Réponse NBSTAT (Node Status) d'un hôte.
public struct NetBIOSNodeStatus: Hashable, Sendable {
    public var entries: [NetBIOSNameEntry]
    /// Adresse MAC annoncée (`nil` si absente ou nulle, comme chez Samba).
    public var mac: MACAddress?

    public init(entries: [NetBIOSNameEntry], mac: MACAddress?) {
        self.entries = entries
        self.mac = mac
    }

    /// Nom de machine : nom unique de suffixe 0x00, sinon nom unique de suffixe 0x20.
    public var hostname: String? {
        let usable = entries.filter { !$0.isGroup && !$0.name.isEmpty && !$0.name.hasPrefix("__") }
        return (usable.first(where: { $0.suffix == 0x00 }) ?? usable.first(where: { $0.suffix == 0x20 }))?.name
    }

    /// Groupe de travail ou domaine : nom de groupe de suffixe 0x00.
    public var domain: String? {
        entries.first(where: { $0.isGroup && $0.suffix == 0x00 && !$0.name.isEmpty && !$0.name.hasPrefix("__") })?.name
    }
}

/// Nom NetBIOS d'un hôte (Windows, Samba, NAS) par une requête NBSTAT sur UDP 137.
public final class NamesNetBIOS: ScanNameResolving, @unchecked Sendable {
    public static let defaultPort: UInt16 = 137

    /// Port de destination (137 ; injectable pour les tests).
    public let port: UInt16

    private let provider: NamesChannelProvider

    public init(port: UInt16 = NamesNetBIOS.defaultPort) {
        self.port = port
        provider = NamesChannelProvider()
    }

    public func name(for ip: IPv4Address, timeout: Duration = .milliseconds(1500)) async -> String? {
        await status(for: ip, timeout: timeout)?.hostname
    }

    /// Table des noms et adresse MAC de l'hôte, ou `nil` sans réponse dans le délai.
    public func status(for ip: IPv4Address, timeout: Duration = .milliseconds(1500)) async -> NetBIOSNodeStatus? {
        guard let channel = provider.get() else { return nil }
        let id = channel.makeTransactionID()
        let send = NamesUDPChannel.Send(delay: .zero, bytes: Self.nodeStatusQuery(id: id), destination: NamesEndpoint(ip, port: port))
        let packet = await channel.request([send], timeout: timeout) { packet, source in
            source == ip && packet.count >= 2 && UInt16(packet[0]) << 8 | UInt16(packet[1]) == id
                && Self.parseNodeStatus(packet) != nil
        }
        return packet.flatMap(Self.parseNodeStatus)
    }

    /// Requête NBSTAT : nom « * » complété de 15 octets nuls, encodé en demi-octets (« CKAAAA… »),
    /// type 0x0021, classe IN.
    public static func nodeStatusQuery(id: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x00, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        bytes += encodeName([0x2A] + [UInt8](repeating: 0, count: 15))
        bytes += [0x00, 0x21, 0x00, 0x01]
        return bytes
    }

    /// Encodage de premier niveau (RFC 1001) : chaque demi-octet devient « A » + valeur.
    static func encodeName(_ raw: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x20]
        for byte in raw {
            bytes.append(0x41 + (byte >> 4))
            bytes.append(0x41 + (byte & 0x0F))
        }
        bytes.append(0)
        return bytes
    }

    /// Décode une réponse NBSTAT ; `nil` si ce n'en est pas une.
    public static func parseNodeStatus(_ bytes: [UInt8]) -> NetBIOSNodeStatus? {
        guard bytes.count >= 12 else { return nil }
        let flags = u16(bytes, 2)
        guard flags & 0x8000 != 0, flags & 0x000F == 0 else { return nil }
        let questions = Int(u16(bytes, 4)), answers = Int(u16(bytes, 6))
        guard answers >= 1 else { return nil }
        var offset = 12
        do {
            for _ in 0..<questions {
                _ = try DNSMessageCodec.readName(bytes, &offset)
                offset += 4
            }
            _ = try DNSMessageCodec.readName(bytes, &offset)
        } catch {
            return nil
        }
        guard offset + 10 <= bytes.count, u16(bytes, offset) == 0x0021 else { return nil }
        let length = Int(u16(bytes, offset + 8))
        let start = offset + 10
        guard length >= 1, start + length <= bytes.count else { return nil }
        let rdata = Array(bytes[start..<(start + length)])
        let count = Int(rdata[0])
        guard 1 + count * 18 <= rdata.count else { return nil }
        var entries: [NetBIOSNameEntry] = []
        for index in 0..<count {
            let base = 1 + index * 18
            let raw = Array(rdata[base..<(base + 15)])
            let name = (String(bytes: raw, encoding: .windowsCP1252) ?? String(decoding: raw, as: UTF8.self))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \u{0}"))
            let nameFlags = UInt16(rdata[base + 16]) << 8 | UInt16(rdata[base + 17])
            entries.append(NetBIOSNameEntry(name: name, suffix: rdata[base + 15], isGroup: nameFlags & 0x8000 != 0))
        }
        var mac: MACAddress?
        let macStart = 1 + count * 18
        if macStart + 6 <= rdata.count {
            let candidate = MACAddress(bytes: Array(rdata[macStart..<(macStart + 6)]))
            if candidate.value != 0 { mac = candidate }
        }
        return NetBIOSNodeStatus(entries: entries, mac: mac)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}
