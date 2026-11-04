import Foundation

/// Filtre de capture (syntaxe de tcpdump) compilé en programme BPF posé dans le noyau.
///
/// Compilation par le système quand c'est possible : `/usr/sbin/tcpdump -dd -r <fichier vide>`
/// lit un fichier pcap vide (aucun privilège, aucune interface ouverte, rien sur le réseau) et
/// écrit le programme. Sinon, les préréglages simples (host, port, arp, dns, dhcp, icmp, tcp, udp,
/// LLDP/CDP) sont traduits par des programmes écrits à la main.
public struct CompiledCaptureFilter: Sendable, Equatable {
    public enum Source: String, Sendable { case none, tcpdump, handWritten }

    public var text: String
    public var program: [BPFInstruction]
    public var source: Source
}

/// Préréglages du filtre de capture (texte tcpdump, traduit à la main si tcpdump manque).
public enum CapturePreset: String, CaseIterable, Sendable, Identifiable {
    case all, host, port, arp, dns, dhcp, icmp, tcp, udp, neighbors

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "Tout le trafic"
        case .host: return "Un hôte"
        case .port: return "Un port"
        case .arp: return "ARP"
        case .dns: return "DNS"
        case .dhcp: return "DHCP"
        case .icmp: return "ICMP (ping)"
        case .tcp: return "TCP seulement"
        case .udp: return "UDP seulement"
        case .neighbors: return "LLDP et CDP"
        }
    }

    /// Texte tcpdump du préréglage (`host` et `port` prennent la valeur donnée).
    public func text(host: String = "10.0.0.1", port: Int = 443) -> String {
        switch self {
        case .all: return ""
        case .host: return "host \(host)"
        case .port: return "port \(port)"
        case .arp: return "arp"
        case .dns: return "port 53"
        case .dhcp: return "port 67 or port 68"
        case .icmp: return "icmp"
        case .tcp: return "tcp"
        case .udp: return "udp"
        case .neighbors: return "ether proto 0x88cc or ether dst 01:00:0c:cc:cc:cc"
        }
    }
}

public enum CaptureFilterCompiler {
    /// Valeur renvoyée par les programmes : octets gardés par paquet.
    public static let snapLength: UInt32 = 262_144
    public static let maximumLength = 300
    public static let maximumInstructions = 4096

    /// Caractères permis : lettres, chiffres, espace et « . : / ( ) ! & | = < > [ ] _ + * - ».
    /// Ni guillemet, ni apostrophe, ni barre oblique inverse, ni $, ni ; : le texte peut être passé
    /// entre apostrophes à tcpdump lancé en administrateur sans rien pouvoir y injecter.
    public static func isSafe(_ text: String) -> Bool {
        guard text.count <= maximumLength else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || " .:/()!&|=<>[]_+*-".unicodeScalars.contains(scalar)
        }
    }

    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Compile le filtre : tcpdump d'abord (si présent), sinon les préréglages écrits à la main.
    public static func compile(_ text: String, linkType: UInt32 = PcapLinkType.ethernet,
                               tcpdump: String? = PrivilegedCapture.tcpdumpPath) -> Result<CompiledCaptureFilter, ToolError> {
        let clean = normalized(text)
        if clean.isEmpty { return .success(CompiledCaptureFilter(text: "", program: acceptAll, source: .none)) }
        guard isSafe(clean) else {
            return .failure(.invalidInput("Caractère refusé dans le filtre de capture (ni guillemets, ni apostrophe, ni « ; », « $ », « \\ »)."))
        }
        if let tcpdump, FileManager.default.isExecutableFile(atPath: tcpdump) {
            switch compileWithTcpdump(clean, linkType: linkType, tcpdump: tcpdump) {
            case .success(let program): return .success(CompiledCaptureFilter(text: clean, program: program, source: .tcpdump))
            case .failure(let error):
                // Syntaxe refusée par tcpdump : c'est la bonne réponse, même si un préréglage existe.
                if case .invalidInput = error { return .failure(error) }
            }
        }
        if let program = handWritten(clean) { return .success(CompiledCaptureFilter(text: clean, program: program, source: .handWritten)) }
        return .failure(.invalidInput("Sans tcpdump, seuls les préréglages sont compris (host, port, arp, dns, dhcp, icmp, tcp, udp, LLDP/CDP)."))
    }

    /// Lance `tcpdump -dd -r <pcap vide> <filtre>` (arguments passés sans shell).
    static func compileWithTcpdump(_ text: String, linkType: UInt32, tcpdump: String) -> Result<[BPFInstruction], ToolError> {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("netscope-filtre-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.processFailed("dossier temporaire\u{00A0}: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("vide.pcap")
        guard FileManager.default.createFile(atPath: empty.path, contents: Data(PcapFile.header(linkType: linkType))) else {
            return .failure(.processFailed("fichier pcap vide"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tcpdump)
        process.arguments = ["-dd", "-r", empty.path, text]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failure(.processFailed(error.localizedDescription)) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, let program = parseDD(stdout), !program.isEmpty else {
            let message = stderr.split(separator: "\n").map(String.init).first { $0.hasPrefix("tcpdump:") }?
                .replacingOccurrences(of: "tcpdump: ", with: "") ?? "syntaxe refusée"
            return .failure(.invalidInput("Filtre de capture refusé par tcpdump\u{00A0}: \(message)."))
        }
        guard program.count <= maximumInstructions else { return .failure(.invalidInput("Filtre de capture trop long.")) }
        return .success(program)
    }

    /// Programme au format C de `tcpdump -dd` : `{ 0x28, 0, 0, 0x0000000c },` par ligne.
    public static func parseDD(_ text: String) -> [BPFInstruction]? {
        var program: [BPFInstruction] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{") else { continue }
            let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "{},; "))
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 4, let code = number(parts[0]), let jt = number(parts[1]), let jf = number(parts[2]), let k = number(parts[3]),
                  code <= 0xFFFF, jt <= 0xFF, jf <= 0xFF, k <= 0xFFFF_FFFF else { return nil }
            program.append(BPFInstruction(UInt16(code), UInt8(jt), UInt8(jf), UInt32(k)))
        }
        return program
    }

    private static func number(_ text: String) -> UInt64? {
        text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }

    // MARK: Préréglages écrits à la main

    static let acceptAll = [BPFInstruction(0x06, 0, 0, snapLength)]

    /// Programme d'un préréglage reconnu dans `text` (forme exacte de `CapturePreset.text`), ou nil.
    public static func handWritten(_ text: String) -> [BPFInstruction]? {
        let words = normalized(text).lowercased().split(separator: " ").map(String.init)
        switch words.count {
        case 0: return acceptAll
        case 1:
            switch words[0] {
            case "arp": return arpProgram
            case "icmp": return protocolProgram(ipv4: 1, ipv6: nil)
            case "tcp": return protocolProgram(ipv4: 6, ipv6: 6)
            case "udp": return protocolProgram(ipv4: 17, ipv6: 17)
            case "dns": return portProgram([53])
            case "dhcp": return dhcpProgram
            case "lldp", "cdp": return neighborsProgram
            default: return nil
            }
        case 2:
            if words[0] == "host", let address = IPv4Address(words[1]) { return hostProgram(address) }
            if words[0] == "port", let port = UInt16(words[1]) { return portProgram([port]) }
            return nil
        default:
            if words == ["port", "67", "or", "port", "68"] || words == ["udp", "port", "67", "or", "udp", "port", "68"] { return dhcpProgram }
            if words == ["ether", "proto", "0x88cc", "or", "ether", "dst", "01:00:0c:cc:cc:cc"] { return neighborsProgram }
            if words.count == 3, words[1] == "port", ["tcp", "udp"].contains(words[0]), let port = UInt16(words[2]) {
                return portProgram([port], transports: words[0] == "tcp" ? [6] : [17])
            }
            return nil
        }
    }

    static var neighborsProgram: [BPFInstruction] {
        var asm = BPFAssembler()
        asm.load(.half, 12)
        asm.jumpEqual(0x88CC, true: "ok")
        asm.load(.word, 0)
        asm.jumpEqual(0x0100_0CCC, false: "non")
        asm.load(.half, 4)
        asm.jumpEqual(0xCCCC, true: "ok", false: "non")
        asm.label("ok"); asm.accept()
        asm.label("non"); asm.reject()
        return asm.assemble()
    }

    static var arpProgram: [BPFInstruction] {
        var asm = BPFAssembler()
        asm.load(.half, 12)
        asm.jumpEqual(0x0806, true: "ok", false: "non")
        asm.label("ok"); asm.accept()
        asm.label("non"); asm.reject()
        return asm.assemble()
    }

    /// IPv4 (champ protocole) et IPv6 (en-tête suivant, sans en-têtes d'extension).
    static func protocolProgram(ipv4: UInt32, ipv6: UInt32?) -> [BPFInstruction] {
        var asm = BPFAssembler()
        asm.load(.half, 12)
        if ipv6 != nil { asm.jumpEqual(0x86DD, true: "v6") }
        asm.jumpEqual(0x0800, false: "non")
        asm.load(.byte, 23)
        asm.jumpEqual(ipv4, true: "ok", false: "non")
        if let ipv6 {
            asm.label("v6")
            asm.load(.byte, 20)
            asm.jumpEqual(ipv6, true: "ok", false: "non")
        }
        asm.label("ok"); asm.accept()
        asm.label("non"); asm.reject()
        return asm.assemble()
    }

    /// IPv4 source ou destination, et ARP/RARP émetteur ou cible (comme `host` de tcpdump).
    static func hostProgram(_ address: IPv4Address) -> [BPFInstruction] {
        var asm = BPFAssembler()
        asm.load(.half, 12)
        asm.jumpEqual(0x0800, true: "ip")
        asm.jumpEqual(0x0806, true: "arp")
        asm.jumpEqual(0x8035, true: "arp", false: "non")
        asm.label("ip")
        asm.load(.word, 26)
        asm.jumpEqual(address.value, true: "ok")
        asm.load(.word, 30)
        asm.jumpEqual(address.value, true: "ok", false: "non")
        asm.label("arp")
        asm.load(.word, 28)
        asm.jumpEqual(address.value, true: "ok")
        asm.load(.word, 38)
        asm.jumpEqual(address.value, true: "ok", false: "non")
        asm.label("ok"); asm.accept()
        asm.label("non"); asm.reject()
        return asm.assemble()
    }

    /// Port source ou destination TCP/UDP, IPv4 (non fragmenté, options IP comprises) et IPv6.
    static func portProgram(_ ports: [UInt16], transports: [UInt32] = [6, 17]) -> [BPFInstruction] {
        var asm = BPFAssembler()
        asm.load(.half, 12)
        asm.jumpEqual(0x86DD, true: "v6")
        asm.jumpEqual(0x0800, false: "non")
        asm.load(.byte, 23)
        for (index, transport) in transports.enumerated() {
            asm.jumpEqual(transport, true: "v4", false: index == transports.count - 1 ? "non" : nil)
        }
        asm.label("v4")
        asm.load(.half, 20)
        asm.jumpSet(0x1FFF, true: "non")
        asm.loadIPHeaderLength(14)
        for offset: UInt32 in [14, 16] {
            asm.loadIndexed(.half, offset)
            for port in ports { asm.jumpEqual(UInt32(port), true: "ok") }
        }
        asm.jump("non")
        asm.label("v6")
        asm.load(.byte, 20)
        for (index, transport) in transports.enumerated() {
            asm.jumpEqual(transport, true: "v6ports", false: index == transports.count - 1 ? "non" : nil)
        }
        asm.label("v6ports")
        for offset: UInt32 in [54, 56] {
            asm.load(.half, offset)
            for port in ports { asm.jumpEqual(UInt32(port), true: "ok") }
        }
        asm.jump("non")
        asm.label("ok"); asm.accept()
        asm.label("non"); asm.reject()
        return asm.assemble()
    }

    /// UDP 67 ou 68 en IPv4 (source ou destination).
    static var dhcpProgram: [BPFInstruction] {
        var asm = BPFAssembler()
        asm.load(.half, 12)
        asm.jumpEqual(0x0800, false: "non")
        asm.load(.byte, 23)
        asm.jumpEqual(17, false: "non")
        asm.load(.half, 20)
        asm.jumpSet(0x1FFF, true: "non")
        asm.loadIPHeaderLength(14)
        for offset: UInt32 in [14, 16] {
            asm.loadIndexed(.half, offset)
            asm.jumpEqual(67, true: "ok")
            asm.jumpEqual(68, true: "ok")
        }
        asm.jump("non")
        asm.label("ok"); asm.accept()
        asm.label("non"); asm.reject()
        return asm.assemble()
    }
}

/// Petit assembleur BPF à étiquettes : les sauts sont calculés au montage (aucun décalage écrit à la main).
struct BPFAssembler {
    enum Size { case word, half, byte }

    private enum Item {
        case instruction(UInt16, UInt32)
        case conditional(UInt16, UInt32, String?, String?)
        case always(String)
        case label(String)
    }

    private var items: [Item] = []

    mutating func load(_ size: Size, _ offset: UInt32) {
        items.append(.instruction(size == .word ? 0x20 : size == .half ? 0x28 : 0x30, offset))
    }

    mutating func loadIndexed(_ size: Size, _ offset: UInt32) {
        items.append(.instruction(size == .word ? 0x40 : size == .half ? 0x48 : 0x50, offset))
    }

    /// X = 4 × (octet[offset] & 0x0F) : longueur de l'en-tête IPv4.
    mutating func loadIPHeaderLength(_ offset: UInt32) { items.append(.instruction(0xB1, offset)) }

    mutating func jumpEqual(_ value: UInt32, true onTrue: String? = nil, false onFalse: String? = nil) {
        items.append(.conditional(0x15, value, onTrue, onFalse))
    }

    mutating func jumpSet(_ mask: UInt32, true onTrue: String? = nil, false onFalse: String? = nil) {
        items.append(.conditional(0x45, mask, onTrue, onFalse))
    }

    mutating func jump(_ target: String) { items.append(.always(target)) }
    mutating func label(_ name: String) { items.append(.label(name)) }
    mutating func accept() { items.append(.instruction(0x06, CaptureFilterCompiler.snapLength)) }
    mutating func reject() { items.append(.instruction(0x06, 0)) }

    func assemble() -> [BPFInstruction] {
        var positions: [String: Int] = [:]
        var index = 0
        for item in items {
            if case .label(let name) = item { positions[name] = index } else { index += 1 }
        }
        var program: [BPFInstruction] = []
        for item in items {
            let here = program.count
            func offset(_ label: String?) -> UInt8 {
                guard let label else { return 0 }
                guard let target = positions[label], target > here, target - here - 1 <= 255 else {
                    preconditionFailure("Saut BPF impossible vers « \(label) »")
                }
                return UInt8(target - here - 1)
            }
            switch item {
            case .instruction(let code, let k): program.append(BPFInstruction(code, 0, 0, k))
            case .conditional(let code, let k, let t, let f): program.append(BPFInstruction(code, offset(t), offset(f), k))
            case .always(let label):
                guard let target = positions[label], target > here else { preconditionFailure("Saut BPF impossible vers « \(label) »") }
                program.append(BPFInstruction(0x05, 0, 0, UInt32(target - here - 1)))
            case .label: break
            }
        }
        return program
    }
}
