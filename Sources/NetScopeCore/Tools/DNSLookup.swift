import Darwin
import Foundation

// Résolution DNS : messages DNS encodés et décodés ici (RFC 1035), envoyés en UDP (TCP si la
// réponse est tronquée) au serveur choisi ; sans serveur, le résolveur du système (res_query de
// libresolv). Repli sur /usr/bin/dig ou /usr/bin/host si nécessaire.

public enum DNSRecordType: String, CaseIterable, Sendable, Identifiable, Codable {
    case a = "A", aaaa = "AAAA", mx = "MX", ptr = "PTR", txt = "TXT", ns = "NS", cname = "CNAME", soa = "SOA"
    case srv = "SRV", caa = "CAA", dnskey = "DNSKEY", ds = "DS"

    public var id: String { rawValue }

    /// Types proposés dans l'interface.
    public static let queryable: [DNSRecordType] = [.a, .aaaa, .mx, .ptr, .txt, .ns, .cname, .soa, .srv, .caa, .dnskey, .ds]

    public var code: UInt16 {
        switch self {
        case .a: return 1
        case .ns: return 2
        case .cname: return 5
        case .soa: return 6
        case .ptr: return 12
        case .mx: return 15
        case .txt: return 16
        case .aaaa: return 28
        case .srv: return 33
        case .ds: return 43
        case .dnskey: return 48
        case .caa: return 257
        }
    }

    public init?(code: UInt16) {
        guard let match = DNSRecordType.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }
}

/// Un enregistrement de réponse.
public struct DNSRecord: Hashable, Sendable {
    public var name: String
    public var typeCode: UInt16
    public var ttl: UInt32
    public var value: String

    public init(name: String, typeCode: UInt16, ttl: UInt32, value: String) {
        self.name = name
        self.typeCode = typeCode
        self.ttl = ttl
        self.value = value
    }

    public var type: DNSRecordType? { DNSRecordType(code: typeCode) }
    public var typeLabel: String { type?.rawValue ?? "TYPE\(typeCode)" }
}

/// Message DNS décodé.
public struct DNSMessage: Sendable {
    public var id: UInt16
    public var isResponse: Bool
    public var isAuthoritative: Bool
    public var isTruncated: Bool
    public var recursionAvailable: Bool
    public var rcode: UInt8
    public var questions: [String]
    public var answers: [DNSRecord]
    public var authority: [DNSRecord]
    public var additional: [DNSRecord]

    public var rcodeLabel: String { DNSMessage.label(rcode: rcode) }

    public static func label(rcode: UInt8) -> String {
        switch rcode {
        case 0: return "NOERROR"
        case 1: return "FORMERR"
        case 2: return "SERVFAIL"
        case 3: return "NXDOMAIN"
        case 4: return "NOTIMP"
        case 5: return "REFUSED"
        default: return "RCODE \(rcode)"
        }
    }
}

public enum DNSError: Error, LocalizedError, Equatable, Sendable {
    case truncatedMessage
    case badPointer
    case invalidLabel
    case invalidName(String)
    case mismatchedID
    case resolver(String)

    public var errorDescription: String? {
        switch self {
        case .truncatedMessage: return "Réponse DNS incomplète."
        case .badPointer: return "Réponse DNS invalide (pointeur de compression incorrect)."
        case .invalidLabel: return "Réponse DNS invalide (étiquette incorrecte)."
        case .invalidName(let name): return "« \(name) » n’est pas un nom DNS valide."
        case .mismatchedID: return "Réponse DNS inattendue (identifiant différent)."
        case .resolver(let text): return text
        }
    }
}

// MARK: - Encodage et décodage

public enum DNSMessageCodec {
    /// Requête standard (une question, classe IN, récursion demandée).
    public static func query(name: String, type: DNSRecordType, id: UInt16, recursion: Bool = true) throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += be16(id)
        bytes += be16(recursion ? 0x0100 : 0)
        bytes += be16(1) + be16(0) + be16(0) + be16(0)
        bytes += try encodeName(name)
        bytes += be16(type.code) + be16(1)
        return bytes
    }

    static func encodeName(_ name: String) throws -> [UInt8] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "." || trimmed.isEmpty { return [0] }
        var result: [UInt8] = []
        let labels = trimmed.hasSuffix(".") ? String(trimmed.dropLast()).split(separator: ".", omittingEmptySubsequences: false)
                                            : trimmed.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            let utf8 = Array(label.utf8)
            guard (1...63).contains(utf8.count), utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
                throw DNSError.invalidName(trimmed)
            }
            result.append(UInt8(utf8.count))
            result += utf8
        }
        result.append(0)
        guard result.count <= 255 else { throw DNSError.invalidName(trimmed) }
        return result
    }

    /// Décode un message complet (en-tête, questions, réponses, autorité, additionnels).
    public static func parse(_ bytes: [UInt8]) throws -> DNSMessage {
        guard bytes.count >= 12 else { throw DNSError.truncatedMessage }
        let flags = u16(bytes, 2)
        let qd = Int(u16(bytes, 4)), an = Int(u16(bytes, 6)), ns = Int(u16(bytes, 8)), ar = Int(u16(bytes, 10))
        var offset = 12
        var questions: [String] = []
        for _ in 0..<qd {
            let name = try readName(bytes, &offset)
            guard offset + 4 <= bytes.count else { throw DNSError.truncatedMessage }
            offset += 4
            questions.append(name)
        }
        func records(_ count: Int) throws -> [DNSRecord] {
            var list: [DNSRecord] = []
            for _ in 0..<count { list.append(try readRecord(bytes, &offset)) }
            return list
        }
        let answers = try records(an)
        let authority = try records(ns)
        // Les additionnels mal formés (EDNS exotique) ne doivent pas faire échouer toute la réponse.
        let additional = (try? records(ar)) ?? []
        return DNSMessage(id: u16(bytes, 0), isResponse: flags & 0x8000 != 0, isAuthoritative: flags & 0x0400 != 0,
                          isTruncated: flags & 0x0200 != 0, recursionAvailable: flags & 0x0080 != 0,
                          rcode: UInt8(flags & 0x000F), questions: questions, answers: answers,
                          authority: authority, additional: additional)
    }

    /// Lit un nom (avec compression par pointeurs) ; « example.com. ».
    static func readName(_ bytes: [UInt8], _ offset: inout Int) throws -> String {
        var labels: [String] = []
        var position = offset
        var jumped = false
        var jumps = 0
        while true {
            guard position < bytes.count else { throw DNSError.truncatedMessage }
            let length = Int(bytes[position])
            if length == 0 {
                position += 1
                break
            }
            switch length & 0xC0 {
            case 0xC0:
                guard position + 1 < bytes.count else { throw DNSError.truncatedMessage }
                let pointer = (length & 0x3F) << 8 | Int(bytes[position + 1])
                guard pointer < bytes.count else { throw DNSError.badPointer }
                if !jumped { offset = position + 2 }
                jumped = true
                jumps += 1
                guard jumps <= 64 else { throw DNSError.badPointer }
                position = pointer
            case 0x00:
                let start = position + 1
                guard start + length <= bytes.count else { throw DNSError.truncatedMessage }
                labels.append(String(decoding: bytes[start..<(start + length)], as: UTF8.self))
                position = start + length
            default:
                throw DNSError.invalidLabel
            }
        }
        if !jumped { offset = position }
        return labels.isEmpty ? "." : labels.joined(separator: ".") + "."
    }

    static func readRecord(_ bytes: [UInt8], _ offset: inout Int) throws -> DNSRecord {
        let name = try readName(bytes, &offset)
        guard offset + 10 <= bytes.count else { throw DNSError.truncatedMessage }
        let type = u16(bytes, offset)
        let ttl = UInt32(u16(bytes, offset + 4)) << 16 | UInt32(u16(bytes, offset + 6))
        let length = Int(u16(bytes, offset + 8))
        let start = offset + 10
        guard start + length <= bytes.count else { throw DNSError.truncatedMessage }
        offset = start + length
        let value = try rdata(type: type, bytes, start, length)
        return DNSRecord(name: name, typeCode: type, ttl: ttl, value: value)
    }

    static func rdata(type: UInt16, _ bytes: [UInt8], _ start: Int, _ length: Int) throws -> String {
        let slice = Array(bytes[start..<(start + length)])
        switch DNSRecordType(code: type) {
        case .a:
            guard length == 4 else { throw DNSError.truncatedMessage }
            return IPv4Address(slice[0], slice[1], slice[2], slice[3]).description
        case .aaaa:
            guard length == 16 else { throw DNSError.truncatedMessage }
            return ipv6String(slice)
        case .ns, .cname, .ptr:
            var position = start
            return try readName(bytes, &position)
        case .mx:
            guard length >= 3 else { throw DNSError.truncatedMessage }
            var position = start + 2
            return "\(u16(bytes, start)) \(try readName(bytes, &position))"
        case .txt:
            var parts: [String] = []
            var position = 0
            while position < slice.count {
                let count = Int(slice[position])
                guard position + 1 + count <= slice.count else { throw DNSError.truncatedMessage }
                parts.append("\"" + String(decoding: slice[(position + 1)..<(position + 1 + count)], as: UTF8.self) + "\"")
                position += 1 + count
            }
            return parts.joined(separator: " ")
        case .soa:
            var position = start
            let mname = try readName(bytes, &position)
            let rname = try readName(bytes, &position)
            guard position + 20 <= start + length else { throw DNSError.truncatedMessage }
            let numbers = (0..<5).map { UInt32(u16(bytes, position + $0 * 4)) << 16 | UInt32(u16(bytes, position + $0 * 4 + 2)) }
            return "\(mname) \(rname) " + numbers.map(String.init).joined(separator: " ")
        case .srv, .caa, .dnskey, .ds:
            return try DNSExtendedRData.decode(type: type, bytes, start, length)
        case nil:
            return "\\# \(length) " + slice.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func ipv6String(_ bytes: [UInt8]) -> String {
        var storage = in6_addr()
        withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &storage, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(cString: buffer)
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
}

// MARK: - Résolution

/// Résultat d'une recherche DNS, prêt à afficher.
public struct DNSLookupResult: Sendable {
    public var query: String
    public var type: DNSRecordType
    public var rcode: String
    /// Réponses ; à défaut, la section d'autorité (SOA d'une réponse vide).
    public var records: [DNSRecord]
    public var answerCount: Int
    public var isAuthoritative: Bool
    /// « 10.182.122.1#53 (UDP) », « résolveur du système », « dig ».
    public var serverLabel: String
    public var durationMs: Double

    public init(query: String, type: DNSRecordType, rcode: String, records: [DNSRecord], answerCount: Int,
                isAuthoritative: Bool, serverLabel: String, durationMs: Double) {
        self.query = query
        self.type = type
        self.rcode = rcode
        self.records = records
        self.answerCount = answerCount
        self.isAuthoritative = isAuthoritative
        self.serverLabel = serverLabel
        self.durationMs = durationMs
    }

    /// « NOERROR · 1 réponse · 3 ms · serveur 10.182.122.1#53 (UDP) ».
    public var summary: String {
        var parts = [rcode]
        switch answerCount {
        case 0: parts.append("aucun enregistrement \(type.rawValue)")
        case 1: parts.append("1 réponse")
        default: parts.append("\(answerCount) réponses")
        }
        parts.append(ToolFormat.milliseconds(durationMs))
        parts.append("serveur \(serverLabel)")
        if isAuthoritative { parts.append("réponse autoritaire") }
        return parts.joined(separator: " · ")
    }
}

public enum DNSLookup {
    /// « 10.182.122.111 » → « 111.122.182.10.in-addr.arpa ».
    public static func reverseName(for ip: IPv4Address) -> String {
        let o = ip.octets
        return "\(o.3).\(o.2).\(o.1).\(o.0).in-addr.arpa"
    }

    /// Nom réellement interrogé : une adresse IP en PTR devient son nom in-addr.arpa.
    public static func queryName(for text: String, type: DNSRecordType) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if type == .ptr, let ip = IPv4Address(trimmed) { return reverseName(for: ip) }
        return trimmed
    }

    /// Commande équivalente (historique) : « dig PTR 10.182.122.111 @10.182.122.1 ».
    public static func command(for text: String, type: DNSRecordType, server: IPv4Address?) -> String {
        let target = text.trimmingCharacters(in: .whitespaces)
        let reverse = type == .ptr && IPv4Address(target) != nil
        return "dig " + (reverse ? "-x \(target)" : "\(type.rawValue) \(target)") + (server.map { " @\($0)" } ?? "")
    }

    /// Résout `text` : serveur choisi en UDP/TCP, sinon résolveur du système ; repli sur dig/host.
    public static func resolve(_ text: String, type: DNSRecordType, server: IPv4Address? = nil, port: UInt16 = 53,
                               timeout: TimeInterval = 3) async throws -> DNSLookupResult {
        let name = queryName(for: text, type: type)
        // Le nom est repassé à dig/host en repli : jamais d'option déguisée (« -f… », « @serveur »,
        // « +option ») ; les noms viennent parfois des réponses DNS d'un domaine tiers (SPF, MX).
        guard let first = name.first, !"-@+".contains(first) else { throw DNSError.invalidName(name) }
        _ = try DNSMessageCodec.encodeName(name)
        do {
            return try await Task.detached(priority: .userInitiated) {
                try resolveNative(name: name, type: type, server: server, port: port, timeout: timeout)
            }.value
        } catch let error as DNSError {
            throw error
        } catch {
            if let fallback = try? await resolveWithTool(name: name, type: type, server: server, timeout: timeout + 5) {
                return fallback
            }
            throw error
        }
    }

    static func resolveNative(name: String, type: DNSRecordType, server: IPv4Address?, port: UInt16,
                              timeout: TimeInterval) throws -> DNSLookupResult {
        let start = Date()
        let id = UInt16.random(in: 1...UInt16.max)
        let query = try DNSMessageCodec.query(name: name, type: type, id: id)
        let response: [UInt8]
        let label: String
        if let server {
            var bytes = try exchangeUDP(query, server: server, port: port, timeout: timeout)
            var transport = "UDP"
            if let message = try? DNSMessageCodec.parse(bytes), message.isTruncated {
                bytes = try exchangeTCP(query, server: server, port: port, timeout: timeout)
                transport = "TCP"
            }
            response = bytes
            label = "\(server)#\(port) (\(transport))"
        } else if let bytes = SystemResolver.query(name: name, type: type) {
            response = bytes
            label = "résolveur du système"
        } else if let fallback = SystemResolver.configuredServers().first {
            // res_query renvoie -1 pour NXDOMAIN : on interroge directement le serveur configuré.
            response = try exchangeUDP(query, server: fallback, port: 53, timeout: timeout)
            label = "\(fallback)#53 (UDP)"
        } else {
            throw ToolError.socket("aucun serveur DNS configuré")
        }
        let message = try DNSMessageCodec.parse(response)
        if server != nil, message.id != id { throw DNSError.mismatchedID }
        let duration = Date().timeIntervalSince(start) * 1000
        return DNSLookupResult(query: name, type: type, rcode: message.rcodeLabel,
                               records: message.answers.isEmpty ? message.authority : message.answers,
                               answerCount: message.answers.count, isAuthoritative: message.isAuthoritative,
                               serverLabel: label, durationMs: duration)
    }

    static func exchangeUDP(_ query: [UInt8], server: IPv4Address, port: UInt16, timeout: TimeInterval) throws -> [UInt8] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ToolSocket.lastError("socket UDP") }
        defer { close(fd) }
        ToolSocket.setTimeouts(fd, timeout)
        guard ToolSocket.connect(fd, to: ToolSocket.address(server, port: port)) == 0 else {
            throw ToolSocket.lastError("connexion UDP à \(server)")
        }
        guard send(fd, query, query.count, 0) == query.count else { throw ToolSocket.lastError("envoi de la requête") }
        let expected = DNSMessageCodec.u16(query, 0)
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                throw ToolSocket.lastError("réception")
            }
            guard n >= 12 else { continue }
            let bytes = Array(buffer[0..<n])
            if DNSMessageCodec.u16(bytes, 0) == expected { return bytes }
        }
        throw ToolError.timeout(timeout)
    }

    static func exchangeTCP(_ query: [UInt8], server: IPv4Address, port: UInt16, timeout: TimeInterval) throws -> [UInt8] {
        let fd = try ToolSocket.connectTCP(server, port: port, timeout: timeout)
        defer { close(fd) }
        try ToolSocket.sendAll(fd, DNSMessageCodec.be16(UInt16(query.count)) + query)
        let header = try ToolSocket.readExactly(fd, 2)
        let length = Int(DNSMessageCodec.u16(header, 0))
        return try ToolSocket.readExactly(fd, length)
    }

    // MARK: Repli sur dig / host

    /// Le repli ne reçoit que des noms faits d'étiquettes [A-Za-z0-9_-] (et « * ») : rien qui
    /// puisse passer pour une option de dig ou de host.
    static func isSafeToolName(_ name: String) -> Bool {
        guard let first = name.first, first != "-" else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "-", ".", "*": return true
            default: return false
            }
        }
    }

    /// État de la réponse dans la sortie de `dig +comments` (« status: NXDOMAIN »), nil sans réponse.
    public static func digStatus(_ output: String) -> String? {
        guard let range = output.range(of: "status: ") else { return nil }
        let status = output[range.upperBound...].prefix { $0 != "," && !$0.isWhitespace }
        return status.isEmpty ? nil : String(status)
    }

    static func resolveWithTool(name: String, type: DNSRecordType, server: IPv4Address?, timeout: TimeInterval) async throws -> DNSLookupResult {
        guard isSafeToolName(name) else { throw DNSError.invalidName(name) }
        let start = Date()
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/dig") {
            var arguments = ["+noall", "+answer", "+comments", "+time=3", "+tries=1"]
            if let server { arguments.append("@\(server)") }
            arguments += [name, type.rawValue]
            let output = try await ToolProcess.run("/usr/bin/dig", arguments, timeout: timeout)
            // Sans « status: », dig n'a reçu aucune réponse (délai dépassé, aucun serveur joignable) :
            // c'est un échec, pas une réponse vide.
            guard let status = digStatus(output) else {
                let reason = output.split(separator: "\n").first { $0.hasPrefix(";;") }
                    .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) } ?? "aucune réponse"
                throw ToolError.processFailed("dig\u{00A0}: \(reason)")
            }
            let records = parseDigAnswer(output)
            return DNSLookupResult(query: name, type: type, rcode: status, records: records, answerCount: records.count,
                                   isAuthoritative: false, serverLabel: (server.map { "\($0)" } ?? "système") + " (dig)",
                                   durationMs: Date().timeIntervalSince(start) * 1000)
        }
        var arguments = ["-t", type.rawValue, name]
        if let server { arguments.append(server.description) }
        let output = try await ToolProcess.run("/usr/bin/host", arguments, timeout: timeout)
        let records = output.split(separator: "\n").compactMap { line -> DNSRecord? in
            let text = String(line)
            for marker in [" has address ", " has IPv6 address ", " mail is handled by ", " domain name pointer ",
                           " descriptive text ", " name server ", " is an alias for "] {
                if let range = text.range(of: marker) {
                    return DNSRecord(name: String(text[..<range.lowerBound]), typeCode: type.code, ttl: 0,
                                     value: String(text[range.upperBound...]))
                }
            }
            return nil
        }
        let rcode: String
        if !records.isEmpty || output.contains(" has no ") {
            rcode = "NOERROR"
        } else if output.contains("NXDOMAIN") {
            rcode = "NXDOMAIN"
        } else if output.contains("timed out") || output.contains("no servers could be reached") {
            throw ToolError.processFailed("host\u{00A0}: aucune réponse")
        } else {
            rcode = "—"
        }
        return DNSLookupResult(query: name, type: type, rcode: rcode, records: records,
                               answerCount: records.count, isAuthoritative: false,
                               serverLabel: (server.map { "\($0)" } ?? "système") + " (host)",
                               durationMs: Date().timeIntervalSince(start) * 1000)
    }

    /// Lignes « nom TTL IN TYPE valeur » de `dig +answer`.
    public static func parseDigAnswer(_ output: String) -> [DNSRecord] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(";") else { return nil }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 5, let ttl = UInt32(fields[1]), fields[2] == "IN" else { return nil }
            let code = DNSRecordType(rawValue: fields[3])?.code ?? 0
            return DNSRecord(name: fields[0], typeCode: code, ttl: ttl, value: fields[4...].joined(separator: " "))
        }
    }
}

// MARK: - Résolveur du système (libresolv)

enum SystemResolver {
    private typealias ResQuery = @convention(c) (UnsafePointer<CChar>, Int32, Int32, UnsafeMutablePointer<UInt8>, Int32) -> Int32

    /// res_query n'est pas réentrant : un appel à la fois.
    private static let lock = NSLock()

    private static let function: ResQuery? = {
        // libresolv est liée par Package.swift ; dlopen sert de filet si le symbole n'est pas visible.
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        var symbol = dlsym(defaultHandle, "res_9_query")
        if symbol == nil, let handle = dlopen("/usr/lib/libresolv.9.dylib", RTLD_LAZY) {
            symbol = dlsym(handle, "res_9_query")
        }
        guard let symbol else { return nil }
        return unsafeBitCast(symbol, to: ResQuery.self)
    }()

    /// Réponse brute du résolveur du système ; nil si la requête échoue (NXDOMAIN compris).
    static func query(name: String, type: DNSRecordType) -> [UInt8]? {
        guard let function else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var buffer = [UInt8](repeating: 0, count: 65_535)
        let length = name.withCString { function($0, 1, Int32(type.code), &buffer, Int32(buffer.count)) }
        guard length > 0 else { return nil }
        return Array(buffer[0..<min(Int(length), buffer.count)])
    }

    /// Serveurs de /etc/resolv.conf (lecture locale).
    static func configuredServers() -> [IPv4Address] {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 2, fields[0] == "nameserver" else { return nil }
            return IPv4Address(String(fields[1]))
        }
    }
}
