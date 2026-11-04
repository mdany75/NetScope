import Foundation

// Recherche DNS étendue (note 14) : décodage des types SRV, CAA, DNSKEY et DS, explication en
// clair de chaque enregistrement, comparaison de plusieurs serveurs et vue « propagation »
// (même question posée à une liste de résolveurs publics, écarts signalés).

// MARK: - Décodage des nouveaux types

enum DNSExtendedRData {
    /// Forme de présentation (celle de dig) des données d'un enregistrement SRV, CAA, DNSKEY ou DS.
    static func decode(type: UInt16, _ bytes: [UInt8], _ start: Int, _ length: Int) throws -> String {
        let slice = Array(bytes[start..<(start + length)])
        switch DNSRecordType(code: type) {
        case .srv:
            // Priorité, poids, port (16 bits chacun), puis la cible (nom non compressé en principe).
            guard length >= 7 else { throw DNSError.truncatedMessage }
            var position = start + 6
            let target = try DNSMessageCodec.readName(bytes, &position)
            return "\(DNSMessageCodec.u16(bytes, start)) \(DNSMessageCodec.u16(bytes, start + 2)) "
                + "\(DNSMessageCodec.u16(bytes, start + 4)) \(target)"
        case .caa:
            // Drapeaux, longueur de l'étiquette, étiquette (issue, issuewild, iodef…), valeur.
            guard length >= 2 else { throw DNSError.truncatedMessage }
            let tagLength = Int(slice[1])
            guard 2 + tagLength <= slice.count else { throw DNSError.truncatedMessage }
            let tag = String(decoding: slice[2..<(2 + tagLength)], as: UTF8.self)
            let value = String(decoding: slice[(2 + tagLength)...], as: UTF8.self)
            return "\(slice[0]) \(tag) \"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        case .dnskey:
            // Drapeaux (16 bits), protocole (3), algorithme, clé publique (Base64).
            guard length >= 4 else { throw DNSError.truncatedMessage }
            let key = Data(slice[4...]).base64EncodedString()
            return "\(DNSMessageCodec.u16(slice, 0)) \(slice[2]) \(slice[3]) \(key)"
        case .ds:
            // Numéro de clé (16 bits), algorithme, type de condensé, condensé (hexadécimal).
            guard length >= 4 else { throw DNSError.truncatedMessage }
            let digest = slice[4...].map { String(format: "%02X", $0) }.joined()
            return "\(DNSMessageCodec.u16(slice, 0)) \(slice[2]) \(slice[3]) \(digest)"
        default:
            return "\\# \(length) " + slice.map { String(format: "%02x", $0) }.joined()
        }
    }
}

// MARK: - DNSSEC

public enum DNSSEC {
    /// Numéro de clé (« key tag ») d'une clé DNSKEY, calculé sur ses données (RFC 4034, annexe B).
    public static func keyTag(rdata: [UInt8]) -> UInt16 {
        var accumulator: UInt32 = 0
        for (index, byte) in rdata.enumerated() {
            accumulator += index & 1 == 0 ? UInt32(byte) << 8 : UInt32(byte)
        }
        accumulator += (accumulator >> 16) & 0xFFFF
        return UInt16(accumulator & 0xFFFF)
    }

    /// Numéro de clé à partir de la forme de présentation « 257 3 13 <Base64> ».
    public static func keyTag(presentation: String) -> UInt16? {
        let fields = presentation.split(separator: " ", maxSplits: 3).map(String.init)
        guard fields.count == 4, let flags = UInt16(fields[0]), let proto = UInt8(fields[1]), let algorithm = UInt8(fields[2]),
              let key = Data(base64Encoded: fields[3].replacingOccurrences(of: " ", with: "")) else { return nil }
        return keyTag(rdata: [UInt8(flags >> 8), UInt8(flags & 0xFF), proto, algorithm] + [UInt8](key))
    }

    /// Nom de l'algorithme de signature (registre IANA).
    public static func algorithmName(_ code: Int) -> String {
        switch code {
        case 5: return "RSA/SHA-1"
        case 7: return "RSA/SHA-1 (NSEC3)"
        case 8: return "RSA/SHA-256"
        case 10: return "RSA/SHA-512"
        case 13: return "ECDSA P-256/SHA-256"
        case 14: return "ECDSA P-384/SHA-384"
        case 15: return "Ed25519"
        case 16: return "Ed448"
        default: return "algorithme \(code)"
        }
    }

    /// Nom du condensé d'un enregistrement DS.
    public static func digestName(_ code: Int) -> String {
        switch code {
        case 1: return "SHA-1"
        case 2: return "SHA-256"
        case 4: return "SHA-384"
        default: return "condensé \(code)"
        }
    }
}

// MARK: - Explication en clair

public enum DNSRecordNote {
    /// Une phrase qui explique l'enregistrement (colonne « Explication »), ou nil.
    public static func describe(_ record: DNSRecord) -> String? {
        let fields = record.value.split(separator: " ").map(String.init)
        switch record.type {
        case .mx:
            guard fields.count == 2 else { return nil }
            return "Priorité \(fields[0]) (le plus petit nombre est essayé en premier)"
        case .soa:
            guard fields.count == 7, let serial = UInt32(fields[2]) else { return nil }
            let numbers = fields[3...6].compactMap { UInt32($0) }
            guard numbers.count == 4 else { return nil }
            return "Maître \(fields[0]) · responsable \(mailbox(fields[1])) · série \(serial) · rafraîchir \(duration(numbers[0]))"
                + " · réessayer \(duration(numbers[1])) · expiration \(duration(numbers[2])) · cache négatif \(duration(numbers[3]))"
        case .srv:
            guard fields.count == 4 else { return nil }
            return "Service sur \(fields[3]) port \(fields[2]) · priorité \(fields[0]), poids \(fields[1])"
        case .caa:
            guard fields.count >= 3 else { return nil }
            let value = fields[2...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let critical = fields[0] == "128" ? " (drapeau critique)" : ""
            switch fields[1].lowercased() {
            case "issue":
                return (value.isEmpty || value == ";" ? "Aucune autorité ne peut émettre de certificat"
                        : "Autorise « \(value) » à émettre des certificats") + critical
            case "issuewild":
                return (value.isEmpty || value == ";" ? "Aucun certificat générique (*) permis"
                        : "Autorise « \(value) » à émettre des certificats génériques (*)") + critical
            case "iodef":
                return "Signaler les demandes refusées à \(value)" + critical
            default:
                return "Propriété « \(fields[1]) »" + critical
            }
        case .dnskey:
            guard fields.count >= 4, let flags = Int(fields[0]), let algorithm = Int(fields[2]) else { return nil }
            let role = flags & 0x0001 != 0 ? "KSK (clé de signature des clés)" : (flags & 0x0100 != 0 ? "ZSK (clé de signature de la zone)" : "clé")
            let tag = DNSSEC.keyTag(presentation: record.value).map { " · clé n°\u{00A0}\($0)" } ?? ""
            return "\(role) · \(DNSSEC.algorithmName(algorithm))" + tag
        case .ds:
            guard fields.count == 4, let algorithm = Int(fields[1]), let digest = Int(fields[2]) else { return nil }
            return "Empreinte de la clé n°\u{00A0}\(fields[0]) · \(DNSSEC.algorithmName(algorithm)) · \(DNSSEC.digestName(digest))"
        case .cname:
            return "Alias de \(record.value)"
        case .ptr:
            return "Nom associé à l’adresse"
        default:
            return nil
        }
    }

    /// « admin.example.com. » → « admin@example.com » (le premier point remplace l'arobase).
    static func mailbox(_ name: String) -> String {
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard let dot = trimmed.firstIndex(of: ".") else { return trimmed }
        return trimmed[..<dot] + "@" + trimmed[trimmed.index(after: dot)...]
    }

    /// « 2 h », « 14 j », « 5 min », « 1 h 30 min », « 45 s ».
    public static func duration(_ seconds: UInt32) -> String {
        let nbsp = "\u{00A0}"
        if seconds < 60 { return "\(seconds)\(nbsp)s" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)\(nbsp)j" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60)\(nbsp)min" : "\(seconds)\(nbsp)s" }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours >= 48 && minutes == 0 && seconds % 3600 == 0 { return "\(hours / 24)\(nbsp)j \(hours % 24)\(nbsp)h" }
        return minutes == 0 ? "\(hours)\(nbsp)h" : "\(hours)\(nbsp)h \(minutes)\(nbsp)min"
    }
}

// MARK: - Résolveurs publics

/// Un résolveur DNS public (comparaison, propagation).
public struct DNSPublicResolver: Hashable, Sendable, Identifiable {
    public var name: String
    public var address: IPv4Address
    /// « Mondial (anycast) », « Canada »…
    public var region: String

    public var id: String { address.description }

    public init(name: String, address: IPv4Address, region: String) {
        self.name = name
        self.address = address
        self.region = region
    }

    /// Les trois serveurs proposés dans le choix du serveur (en plus du système et d'une adresse libre).
    public static let presets: [DNSPublicResolver] = [
        DNSPublicResolver(name: "Cloudflare", address: IPv4Address(1, 1, 1, 1), region: "Mondial (anycast)"),
        DNSPublicResolver(name: "Google", address: IPv4Address(8, 8, 8, 8), region: "Mondial (anycast)"),
        DNSPublicResolver(name: "Quad9", address: IPv4Address(9, 9, 9, 9), region: "Mondial (anycast)"),
    ]

    /// Résolveurs de la vue « propagation » : des exploitants différents, donc des caches différents.
    public static let propagation: [DNSPublicResolver] = presets + [
        DNSPublicResolver(name: "OpenDNS (Cisco)", address: IPv4Address(208, 67, 222, 222), region: "États-Unis"),
        DNSPublicResolver(name: "CIRA Canadian Shield", address: IPv4Address(149, 112, 121, 10), region: "Canada"),
        DNSPublicResolver(name: "Lumen (Level 3)", address: IPv4Address(4, 2, 2, 2), region: "États-Unis"),
        DNSPublicResolver(name: "AdGuard", address: IPv4Address(94, 140, 14, 14), region: "Europe"),
        DNSPublicResolver(name: "DNS.WATCH", address: IPv4Address(84, 200, 69, 80), region: "Allemagne"),
        DNSPublicResolver(name: "Comodo Secure", address: IPv4Address(8, 26, 56, 26), region: "États-Unis"),
        DNSPublicResolver(name: "Control D", address: IPv4Address(76, 76, 2, 0), region: "Canada"),
    ]
}

// MARK: - Comparaison entre serveurs

/// Réponse d'un serveur dans une comparaison.
public struct DNSServerAnswer: Sendable, Identifiable {
    /// « Cloudflare », « Résolveur du système », « 10.182.122.1 (passerelle) ».
    public var name: String
    /// Adresse interrogée ; nil = résolveur du système.
    public var address: IPv4Address?
    public var region: String?
    public var result: DNSLookupResult?
    public var error: String?

    public var id: String { address?.description ?? "système" }

    public init(name: String, address: IPv4Address?, region: String? = nil, result: DNSLookupResult?, error: String?) {
        self.name = name
        self.address = address
        self.region = region
        self.result = result
        self.error = error
    }

    /// Plus petit TTL des réponses (ce qui reste en cache sur ce serveur).
    public var minTTL: UInt32? { result.flatMap { $0.answerCount > 0 ? $0.records.map(\.ttl).min() : nil } }
}

/// Accord d'un serveur avec la réponse majoritaire.
public enum DNSAgreement: String, Sendable {
    case agrees, differs, failed

    public var label: String {
        switch self {
        case .agrees: return "Identique"
        case .differs: return "Différent"
        case .failed: return "Sans réponse"
        }
    }
}

/// Comparaison des réponses de plusieurs serveurs à la même question.
public struct DNSComparison: Sendable {
    public var query: String
    public var type: DNSRecordType
    public var answers: [DNSServerAnswer]
    /// Réponse la plus fréquente (signature) parmi les serveurs qui ont répondu.
    public var majority: [String]?

    public init(query: String, type: DNSRecordType, answers: [DNSServerAnswer]) {
        self.query = query
        self.type = type
        self.answers = answers
        var counts: [[String]: Int] = [:]
        var order: [[String]] = []
        for answer in answers {
            guard let result = answer.result else { continue }
            let signature = Self.signature(of: result)
            if counts[signature] == nil { order.append(signature) }
            counts[signature, default: 0] += 1
        }
        // À égalité, la première réponse rencontrée (ordre de la liste) l'emporte.
        var best: [String]?
        for signature in order where (counts[signature] ?? 0) > (best.flatMap { counts[$0] } ?? 0) { best = signature }
        majority = best
    }

    /// Signature d'une réponse : code de réponse et valeurs triées, sans TTL ni casse (un TTL qui
    /// décroît dans un cache n'est pas un écart).
    public static func signature(of result: DNSLookupResult) -> [String] {
        let values = result.answerCount == 0 ? [] : result.records.map { "\($0.typeLabel) \($0.value.lowercased())" }.sorted()
        return [result.rcode] + values
    }

    public func agreement(of answer: DNSServerAnswer) -> DNSAgreement {
        guard let result = answer.result else { return .failed }
        return Self.signature(of: result) == majority ? .agrees : .differs
    }

    public var agreeingCount: Int { answers.filter { agreement(of: $0) == .agrees }.count }
    public var differingCount: Int { answers.filter { agreement(of: $0) == .differs }.count }
    public var failedCount: Int { answers.filter { agreement(of: $0) == .failed }.count }

    /// Vrai quand tous les serveurs qui ont répondu donnent la même réponse.
    public var isConsistent: Bool { differingCount == 0 && agreeingCount > 0 }

    /// « 9 serveurs sur 10 donnent la même réponse · 1 différent ».
    public var summary: String {
        let total = answers.count
        if agreeingCount == 0 { return "Aucun serveur n’a répondu." }
        var text = agreeingCount == total ? "Les \(total) serveurs donnent la même réponse"
                                          : "\(agreeingCount) serveur\(agreeingCount > 1 ? "s" : "") sur \(total) donnent la même réponse"
        if agreeingCount == 1 && total > 1 { text = "1 serveur sur \(total) donne cette réponse" }
        if differingCount > 0 { text += " · \(differingCount) différent\(differingCount > 1 ? "s" : "")" }
        if failedCount > 0 { text += " · \(failedCount) sans réponse" }
        return text
    }

    /// Valeurs présentes chez ce serveur mais absentes de la réponse majoritaire, et inversement.
    public func differences(of answer: DNSServerAnswer) -> (extra: [String], missing: [String]) {
        guard let result = answer.result, let majority else { return ([], []) }
        let mine = Set(Self.signature(of: result).dropFirst())
        let reference = Set(majority.dropFirst())
        return (mine.subtracting(reference).sorted(), reference.subtracting(mine).sorted())
    }
}

extension DNSLookup {
    /// Pose la même question à plusieurs serveurs en parallèle (nil = résolveur du système).
    /// Les réponses gardent l'ordre de `servers`.
    public static func compare(_ text: String, type: DNSRecordType,
                               servers: [(name: String, address: IPv4Address?, region: String?)],
                               timeout: TimeInterval = 3) async -> DNSComparison {
        let answers = await withTaskGroup(of: (Int, DNSServerAnswer).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    do {
                        let result = try await resolve(text, type: type, server: server.address, timeout: timeout)
                        return (index, DNSServerAnswer(name: server.name, address: server.address, region: server.region,
                                                       result: result, error: nil))
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        return (index, DNSServerAnswer(name: server.name, address: server.address, region: server.region,
                                                       result: nil, error: message))
                    }
                }
            }
            var list: [(Int, DNSServerAnswer)] = []
            for await item in group { list.append(item) }
            return list.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return DNSComparison(query: queryName(for: text, type: type), type: type, answers: answers)
    }

    /// Vue « propagation » : la question posée aux résolveurs publics de `DNSPublicResolver.propagation`.
    public static func propagation(_ text: String, type: DNSRecordType, timeout: TimeInterval = 3) async -> DNSComparison {
        await compare(text, type: type, servers: DNSPublicResolver.propagation.map { ($0.name, $0.address, $0.region) },
                      timeout: timeout)
    }
}
