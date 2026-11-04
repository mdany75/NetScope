import Darwin
import Foundation

/// Filtre d'affichage simple, proche de la syntaxe de Wireshark :
///
///     dns
///     ip.addr == 10.182.122.0/24 && tcp.port == 443
///     tcp.flags.reset || tcp.analysis.retransmission
///     not arp and frame.len > 100
///     tls.sni contains "office"
///     port 53 ou host 10.0.0.5
///
/// Protocoles (eth, vlan, arp, ip, ipv6, icmp, icmpv6, igmp, tcp, udp, dns, mdns, nbns, dhcp,
/// lldp, cdp, stp, http, ssdp, tls), champs (ip.addr, ip.src, ip.dst, eth.addr, tcp.port,
/// udp.port, port, host, tcp.flags.syn…, tcp.seq, tcp.ack, tcp.len, tcp.window_size, frame.len,
/// frame.number, vlan.id, ip.ttl, dns.qry.name, tls.sni, http.host, http.request, http.response.code,
/// arp.opcode, tcp.analysis.*), opérateurs ==, !=, >, <, >=, <=, contains (ou eq, ne, gt, lt, ge,
/// le, contient), et && / and / et, || / or / ou, ! / not / non, parenthèses.
public struct DisplayFilter: Sendable {
    public let text: String
    private let root: Node

    public init(_ text: String) throws {
        self.text = text
        var parser = Parser(tokens: try Self.tokenize(text))
        guard !parser.atEnd else { throw DisplayFilterError("Filtre vide.") }
        root = try parser.expression()
        if let extra = parser.peek { throw DisplayFilterError("Élément inattendu\u{00A0}: « \(extra.text) ».") }
    }

    /// Filtre vide : tout passe ; sinon le filtre compilé, ou l'erreur.
    public static func compile(_ text: String) -> Result<DisplayFilter?, DisplayFilterError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }
        do { return .success(try DisplayFilter(trimmed)) } catch let error as DisplayFilterError { return .failure(error) } catch {
            return .failure(DisplayFilterError(error.localizedDescription))
        }
    }

    public func matches(_ packet: CapturedPacket) -> Bool { root.evaluate(packet) }

    // MARK: Arbre

    indirect enum Node: Sendable {
        case and(Node, Node)
        case or(Node, Node)
        case not(Node)
        case test(Test)

        func evaluate(_ packet: CapturedPacket) -> Bool {
            switch self {
            case .and(let a, let b): return a.evaluate(packet) && b.evaluate(packet)
            case .or(let a, let b): return a.evaluate(packet) || b.evaluate(packet)
            case .not(let a): return !a.evaluate(packet)
            case .test(let test): return test.evaluate(packet)
            }
        }
    }

    enum Operator: Sendable {
        case equal, notEqual, greater, less, greaterOrEqual, lessOrEqual, contains
    }

    enum Value: Sendable, Equatable {
        case number(Double)
        case text(String)
        case ipv4(IPv4Address)
        case ipv4Network(IPv4Address, Int)
        case ipv6(String)
        case mac(MACAddress)

        func equals(_ other: Value) -> Bool {
            switch (self, other) {
            case (.ipv4(let a), .ipv4Network(let network, let prefix)), (.ipv4Network(let network, let prefix), .ipv4(let a)):
                let mask = IPv4Address.mask(prefix: prefix).value
                return a.value & mask == network.value & mask
            case (.text(let a), .text(let b)): return a.caseInsensitiveCompare(b) == .orderedSame
            default: return self == other
            }
        }

        var number: Double? { if case .number(let n) = self { return n }; return nil }

        var textValue: String {
            switch self {
            case .number(let n): return n == n.rounded() ? "\(Int64(n))" : "\(n)"
            case .text(let t): return t
            case .ipv4(let a): return a.description
            case .ipv4Network(let a, let p): return "\(a)/\(p)"
            case .ipv6(let a): return a
            case .mac(let m): return m.formatted()
            }
        }
    }

    /// Nature des valeurs d'un champ (pour lire la valeur saisie).
    enum Kind: Sendable { case address, mac, number, text, boolean, protocolPresence }

    struct Field: Sendable {
        let name: String
        let kind: Kind
        let values: @Sendable (CapturedPacket) -> [Value]
    }

    struct Test: Sendable {
        let field: Field
        let op: Operator?
        let value: Value?

        func evaluate(_ packet: CapturedPacket) -> Bool {
            let values = field.values(packet)
            guard let op, let value else {
                // Champ seul : présent (et non nul pour un nombre ou un drapeau).
                return values.contains { if case .number(let n) = $0 { return n != 0 }; return true }
            }
            switch op {
            case .equal: return values.contains { $0.equals(value) }
            case .notEqual: return !values.isEmpty && !values.contains { $0.equals(value) }
            case .contains:
                let needle = value.textValue
                return values.contains { $0.textValue.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            case .greater, .less, .greaterOrEqual, .lessOrEqual:
                guard let limit = value.number else { return false }
                return values.contains { item in
                    guard let n = item.number else { return false }
                    switch op {
                    case .greater: return n > limit
                    case .less: return n < limit
                    case .greaterOrEqual: return n >= limit
                    default: return n <= limit
                    }
                }
            }
        }
    }

    // MARK: Champs connus

    static func field(named raw: String) -> Field? {
        let name = raw.lowercased()
        func number(_ get: @escaping @Sendable (CapturedPacket) -> Double?) -> Field {
            Field(name: name, kind: .number) { packet in get(packet).map { [.number($0)] } ?? [] }
        }
        func flag(_ bit: UInt16) -> Field {
            Field(name: name, kind: .boolean) { packet in packet.decoded.tcp.map { [.number($0.has(bit) ? 1 : 0)] } ?? [] }
        }
        func text(_ get: @escaping @Sendable (CapturedPacket) -> [String]) -> Field {
            Field(name: name, kind: .text) { packet in get(packet).map { .text($0) } }
        }
        func addresses(_ which: @escaping @Sendable (DecodedPacket) -> [String?]) -> Field {
            Field(name: name, kind: .address) { packet in which(packet.decoded).compactMap { $0 }.map(Self.addressValue) }
        }
        func macs(_ which: @escaping @Sendable (DecodedPacket) -> [MACAddress?]) -> Field {
            Field(name: name, kind: .mac) { packet in which(packet.decoded).compactMap { $0 }.map { .mac($0) } }
        }
        func ports(_ kind: PacketProtocol?, source: Bool, destination: Bool) -> Field {
            Field(name: name, kind: .number) { packet in
                guard let transport = packet.decoded.transport, kind == nil || transport.kind == kind else { return [] }
                var values: [Value] = []
                if source { values.append(.number(Double(transport.sourcePort))) }
                if destination { values.append(.number(Double(transport.destinationPort))) }
                return values
            }
        }
        func analysis(_ flag: TCPAnalysisFlag?) -> Field {
            Field(name: name, kind: .boolean) { packet in
                let on = flag.map { packet.analysis.contains($0) } ?? packet.analysis.contains { $0.isProblem }
                return on ? [.number(1)] : []
            }
        }
        switch name {
        case "frame.number": return number { Double($0.id) }
        case "frame.len": return number { Double($0.length) }
        case "frame.cap_len": return number { Double($0.record.data.count) }
        case "frame.time_relative": return number { $0.relativeTime }
        case "frame.time_delta": return number { $0.delta }
        case "eth.addr": return macs { [$0.ethSource, $0.ethDestination] }
        case "eth.src": return macs { [$0.ethSource] }
        case "eth.dst": return macs { [$0.ethDestination] }
        case "vlan.id": return Field(name: name, kind: .number) { $0.decoded.vlanIDs.map { .number(Double($0)) } }
        case "ip.addr", "ipv6.addr", "addr": return addresses { [$0.ipSource, $0.ipDestination] }
        case "ip.src", "ipv6.src", "src": return addresses { [$0.ipSource] }
        case "ip.dst", "ipv6.dst", "dst": return addresses { [$0.ipDestination] }
        case "host":
            return Field(name: name, kind: .address) { packet in
                let d = packet.decoded
                return [d.ipSource, d.ipDestination].compactMap { $0 }.map(Self.addressValue) + [d.ethSource, d.ethDestination].compactMap { $0 }.map { .mac($0) }
            }
        case "ip.ttl", "ipv6.hlim": return number { $0.decoded.ttl.map(Double.init) }
        case "ip.proto", "ipv6.nxt": return number { $0.decoded.ipProtocol.map(Double.init) }
        case "ip.version": return number { $0.decoded.ipVersion.map(Double.init) }
        case "port": return ports(nil, source: true, destination: true)
        case "tcp.port": return ports(.tcp, source: true, destination: true)
        case "tcp.srcport": return ports(.tcp, source: true, destination: false)
        case "tcp.dstport": return ports(.tcp, source: false, destination: true)
        case "udp.port": return ports(.udp, source: true, destination: true)
        case "udp.srcport": return ports(.udp, source: true, destination: false)
        case "udp.dstport": return ports(.udp, source: false, destination: true)
        case "tcp.flags": return number { $0.decoded.tcp.map { Double($0.flags) } }
        case "tcp.flags.syn": return flag(TCPSegmentInfo.syn)
        case "tcp.flags.ack": return flag(TCPSegmentInfo.ack)
        case "tcp.flags.fin": return flag(TCPSegmentInfo.fin)
        case "tcp.flags.reset", "tcp.flags.rst": return flag(TCPSegmentInfo.rst)
        case "tcp.flags.push", "tcp.flags.psh": return flag(TCPSegmentInfo.psh)
        case "tcp.flags.urg": return flag(TCPSegmentInfo.urg)
        case "tcp.seq": return number { packet in (packet.relativeSequence ?? packet.decoded.tcp?.sequence).map(Double.init) }
        case "tcp.seq_raw": return number { $0.decoded.tcp.map { Double($0.sequence) } }
        case "tcp.ack": return number { packet in (packet.relativeAcknowledgment ?? packet.decoded.tcp?.acknowledgment).map(Double.init) }
        case "tcp.ack_raw": return number { $0.decoded.tcp.map { Double($0.acknowledgment) } }
        case "tcp.len": return number { $0.decoded.tcp.map { Double($0.payloadLength) } }
        case "tcp.window_size", "tcp.window_size_value", "tcp.window": return number { $0.decoded.tcp.map { Double($0.window) } }
        case "udp.length": return number { packet in packet.decoded.transport.flatMap { $0.kind == .udp ? Double($0.payloadLength + 8) : nil } }
        case "tcp.analysis.flags": return analysis(nil)
        case "dns.qry.name", "dns.name", "mdns.name", "nbns.name": return text { $0.decoded.dnsNames }
        case "tls.sni", "tls.handshake.extensions_server_name", "ssl.handshake.extensions_server_name":
            return text { $0.decoded.tlsServerName.map { [$0] } ?? [] }
        case "tls.handshake": return text { $0.decoded.tlsHandshake.map { [$0] } ?? [] }
        case "http.host": return text { $0.decoded.httpHost.map { [$0] } ?? [] }
        case "http.request", "http.request.line": return text { $0.decoded.httpRequest.map { [$0] } ?? [] }
        case "http.response.code": return number { $0.decoded.httpStatus.map(Double.init) }
        case "http.response": return Field(name: name, kind: .boolean) { $0.decoded.httpStatus == nil ? [] : [.number(1)] }
        case "arp.opcode": return number { $0.decoded.arpOperation.map(Double.init) }
        case "info", "frame.info": return text { [$0.summary] }
        default:
            if name.hasPrefix("tcp.analysis."), let flag = TCPAnalysisFlag.allCases.first(where: { "tcp.analysis." + $0.filterName == name }) {
                return analysis(flag)
            }
            if let kind = PacketProtocol.named(name) {
                return Field(name: name, kind: .protocolPresence) { $0.decoded.contains(kind) ? [.number(1)] : [] }
            }
            return nil
        }
    }

    static func addressValue(_ text: String) -> Value {
        if let v4 = IPv4Address(text) { return .ipv4(v4) }
        return .ipv6(text.lowercased())
    }

    /// Lit la valeur saisie selon la nature du champ.
    static func parseValue(_ raw: String, for field: Field) throws -> Value {
        switch field.kind {
        case .address:
            if let mac = MACAddress(raw), field.name == "host" { return .mac(mac) }
            if raw.contains("/"), !raw.contains(":") {
                let parts = raw.split(separator: "/")
                guard parts.count == 2, let base = IPv4Address(String(parts[0])), let prefix = Int(parts[1]), (0...32).contains(prefix) else {
                    throw DisplayFilterError("Réseau invalide\u{00A0}: « \(raw) » (ex. 10.0.0.0/24).")
                }
                return .ipv4Network(base, prefix)
            }
            if let v4 = IPv4Address(raw) { return .ipv4(v4) }
            if let v6 = normalizedIPv6(raw) { return .ipv6(v6) }
            throw DisplayFilterError("Adresse invalide\u{00A0}: « \(raw) ».")
        case .mac:
            guard let mac = MACAddress(raw) else { throw DisplayFilterError("Adresse MAC invalide\u{00A0}: « \(raw) ».") }
            return .mac(mac)
        case .number, .boolean, .protocolPresence:
            let lowered = raw.lowercased()
            if lowered == "true" || lowered == "vrai" || lowered == "oui" { return .number(1) }
            if lowered == "false" || lowered == "faux" || lowered == "non" { return .number(0) }
            if lowered.hasPrefix("0x"), let n = UInt64(lowered.dropFirst(2), radix: 16) { return .number(Double(n)) }
            guard let n = Double(raw.replacingOccurrences(of: ",", with: ".")) else {
                throw DisplayFilterError("Nombre attendu pour \(field.name)\u{00A0}: « \(raw) ».")
            }
            return .number(n)
        case .text:
            return .text(raw)
        }
    }

    static func normalizedIPv6(_ text: String) -> String? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        return PacketText.ipv6(bytes)
    }

    // MARK: Analyse lexicale et syntaxique

    struct Token: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case word, string, op(Operator), and, or, not, open, close }
        let kind: Kind
        let text: String
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        func word(_ w: String) -> Token {
            switch w.lowercased() {
            case "and", "et": return Token(kind: .and, text: w)
            case "or", "ou": return Token(kind: .or, text: w)
            case "not", "non": return Token(kind: .not, text: w)
            case "eq": return Token(kind: .op(.equal), text: w)
            case "ne": return Token(kind: .op(.notEqual), text: w)
            case "gt": return Token(kind: .op(.greater), text: w)
            case "lt": return Token(kind: .op(.less), text: w)
            case "ge": return Token(kind: .op(.greaterOrEqual), text: w)
            case "le": return Token(kind: .op(.lessOrEqual), text: w)
            case "contains", "contient": return Token(kind: .op(.contains), text: w)
            default: return Token(kind: .word, text: w)
            }
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            let two = i + 1 < chars.count ? String(chars[i...i + 1]) : String(c)
            switch two {
            case "&&": tokens.append(Token(kind: .and, text: two)); i += 2; continue
            case "||": tokens.append(Token(kind: .or, text: two)); i += 2; continue
            case "==": tokens.append(Token(kind: .op(.equal), text: two)); i += 2; continue
            case "!=": tokens.append(Token(kind: .op(.notEqual), text: two)); i += 2; continue
            case ">=": tokens.append(Token(kind: .op(.greaterOrEqual), text: two)); i += 2; continue
            case "<=": tokens.append(Token(kind: .op(.lessOrEqual), text: two)); i += 2; continue
            default: break
            }
            switch c {
            case "(": tokens.append(Token(kind: .open, text: "(")); i += 1
            case ")": tokens.append(Token(kind: .close, text: ")")); i += 1
            case "!": tokens.append(Token(kind: .not, text: "!")); i += 1
            case ">": tokens.append(Token(kind: .op(.greater), text: ">")); i += 1
            case "<": tokens.append(Token(kind: .op(.less), text: "<")); i += 1
            case "=": tokens.append(Token(kind: .op(.equal), text: "=")); i += 1
            case "\"", "«":
                let close: Character = c == "«" ? "»" : "\""
                var j = i + 1
                var value = ""
                while j < chars.count, chars[j] != close { value.append(chars[j]); j += 1 }
                guard j < chars.count else { throw DisplayFilterError("Guillemet fermant manquant.") }
                tokens.append(Token(kind: .string, text: value.trimmingCharacters(in: .whitespaces)))
                i = j + 1
            case "&", "|":
                throw DisplayFilterError("Opérateur incomplet\u{00A0}: « \(c) » (écrire « \(c)\(c) »).")
            default:
                var j = i
                var value = ""
                while j < chars.count, !chars[j].isWhitespace, !"()!=<>&|\"«".contains(chars[j]) { value.append(chars[j]); j += 1 }
                tokens.append(word(value))
                i = j
            }
        }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        var index = 0

        var atEnd: Bool { index >= tokens.count }
        var peek: Token? { atEnd ? nil : tokens[index] }

        mutating func next() -> Token? {
            defer { index += 1 }
            return peek
        }

        mutating func expression() throws -> Node {
            var left = try conjunction()
            while peek?.kind == .or {
                index += 1
                left = .or(left, try conjunction())
            }
            return left
        }

        mutating func conjunction() throws -> Node {
            var left = try unary()
            while peek?.kind == .and {
                index += 1
                left = .and(left, try unary())
            }
            return left
        }

        mutating func unary() throws -> Node {
            if peek?.kind == .not {
                index += 1
                return .not(try unary())
            }
            return try primary()
        }

        mutating func primary() throws -> Node {
            guard let token = next() else { throw DisplayFilterError("Filtre incomplet.") }
            switch token.kind {
            case .open:
                let inner = try expression()
                guard next()?.kind == .close else { throw DisplayFilterError("Parenthèse fermante manquante.") }
                return inner
            case .word:
                guard let field = DisplayFilter.field(named: token.text) else {
                    throw DisplayFilterError("Champ ou protocole inconnu\u{00A0}: « \(token.text) ».")
                }
                var op: Operator?
                if case .op(let found)? = peek?.kind {
                    op = found
                    index += 1
                } else if let following = peek, following.kind == .word || following.kind == .string,
                          [.address, .mac, .number].contains(field.kind) {
                    // « port 53 », « host 10.0.0.5 » : égalité implicite, comme tcpdump.
                    op = .equal
                }
                guard let op else { return .test(Test(field: field, op: nil, value: nil)) }
                guard let valueToken = next(), valueToken.kind == .word || valueToken.kind == .string else {
                    throw DisplayFilterError("Valeur attendue après « \(token.text) ».")
                }
                if field.kind == .protocolPresence { throw DisplayFilterError("« \(token.text) » est un protocole\u{00A0}: il s’emploie seul.") }
                let value = try DisplayFilter.parseValue(valueToken.text, for: field)
                return .test(Test(field: field, op: op, value: value))
            default:
                throw DisplayFilterError("Élément inattendu\u{00A0}: « \(token.text) ».")
            }
        }
    }
}

public struct DisplayFilterError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}
