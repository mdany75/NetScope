import Foundation

/// Lecture des réponses aux sondes UDP (note 69). Fonctions pures, testées sur des octets recopiés.
public enum UDPProbeReader {
    /// Lit les datagrammes reçus d'un port. nil si aucun ; une réponse non reconnue donne un
    /// résumé générique (le port est quand même ouvert).
    public static func read(_ service: UDPService, datagrams: [[UInt8]], community: String? = nil) -> UDPReading? {
        let list = datagrams.filter { !$0.isEmpty }
        guard !list.isEmpty else { return nil }
        let reading: UDPReading?
        switch service {
        case .dns: reading = dns(list)
        case .tftp: reading = tftp(list)
        case .ntp: reading = ntp(list)
        case .netbios: reading = netbios(list)
        case .snmp: reading = snmp(list, community: community)
        case .ipmi: reading = ipmi(list)
        case .ssdp: reading = ssdp(list)
        case .sip: reading = sip(list)
        case .mdns: reading = mdns(list)
        }
        if let reading { return reading }
        let total = list.reduce(0) { $0 + $1.count }
        return UDPReading(summary: "Réponse de \(total)\u{00A0}octets (format non reconnu)", recognized: false)
    }

    // MARK: DNS

    static func dns(_ datagrams: [[UInt8]]) -> UDPReading? {
        let messages = datagrams.compactMap { try? DNSMessageCodec.parse($0) }.filter(\.isResponse)
        guard !messages.isEmpty else { return nil }
        var details: [String] = []
        var version: String?
        for message in messages {
            let question = message.questions.first?.lowercased() ?? ""
            if question == "version.bind." {
                if let txt = message.answers.first(where: { $0.typeCode == 16 }) {
                    version = unquote(txt.value)
                    details.append("version.bind\u{00A0}: \(version ?? "")")
                } else {
                    details.append("version.bind\u{00A0}: \(message.rcodeLabel) (version masquée)")
                }
            } else if question == "localhost." {
                let recursion = message.recursionAvailable ? "récursion disponible" : "sans récursion"
                details.append("A localhost\u{00A0}: \(message.rcodeLabel), \(recursion)")
            }
        }
        let resolver = messages.contains { $0.recursionAvailable && $0.questions.first?.lowercased() == "localhost." && $0.rcode == 0 }
        let summary = version.map { "Serveur DNS · \($0)" }
            ?? (resolver ? "Résolveur DNS (récursif)" : "Serveur DNS · version masquée")
        return UDPReading(summary: summary, details: details)
    }

    // MARK: TFTP

    static func tftp(_ datagrams: [[UInt8]]) -> UDPReading? {
        for bytes in datagrams {
            guard let packet = try? TFTPPacket.decode(bytes) else { continue }
            switch packet {
            case .error(let code, let message):
                let text = message.isEmpty ? code.label : "«\u{00A0}\(message)\u{00A0}»"
                return UDPReading(summary: "Serveur TFTP · erreur \(code.rawValue) \(text)",
                                  details: ["Le serveur a refusé le fichier de test inexistant, comme prévu."],
                                  findings: [.tftpOpen])
            case .data, .oack:
                return UDPReading(summary: "Serveur TFTP · fichier servi",
                                  details: ["Le serveur a commencé à envoyer un fichier\u{00A0}; transfert interrompu par NetScope."],
                                  findings: [.tftpOpen])
            default:
                continue
            }
        }
        return nil
    }

    // MARK: NTP

    static func ntp(_ datagrams: [[UInt8]]) -> UDPReading? {
        var summary: String?
        var details: [String] = []
        var findings: [UDPFinding] = []
        for bytes in datagrams {
            guard bytes.count >= 4 else { continue }
            let mode = bytes[0] & 0x07
            switch mode {
            case 4 where bytes.count >= 48:
                let version = (bytes[0] >> 3) & 0x07
                let stratum = bytes[1]
                let refID = Array(bytes[12..<16])
                let reference: String
                if stratum <= 1 {
                    let text = String(decoding: refID.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
                    reference = text.isEmpty ? "—" : text
                } else {
                    reference = IPv4Address(refID[0], refID[1], refID[2], refID[3]).description
                }
                let leap = bytes[0] >> 6
                if stratum == 0 || stratum >= 16 || leap == 3 {
                    summary = "NTPv\(version) · non synchronisé"
                    details.append("Strate \(stratum), indicateur de saut \(leap)\u{00A0}: le serveur ne donne pas l’heure.")
                } else {
                    summary = "NTPv\(version) · strate \(stratum) · réf. \(reference)"
                    details.append("Strate \(stratum), source de référence \(reference).")
                }
            case 6 where bytes[1] & 0x80 != 0:
                findings.append(.ntpMode6)
                let count = bytes.count >= 12 ? Int(UInt16(bytes[10]) << 8 | UInt16(bytes[11])) : 0
                let data = bytes.count > 12 ? Array(bytes[12..<min(bytes.count, 12 + count)]) : []
                let text = String(decoding: data, as: UTF8.self)
                if let version = ntpVariable("version", in: text) {
                    details.append("Mode 6\u{00A0}: \(version)")
                    if summary == nil { summary = version }
                } else {
                    details.append("Mode 6 (ntpq)\u{00A0}: le serveur répond aux requêtes de contrôle.")
                }
            case 7 where bytes[0] & 0x80 != 0:
                let error = bytes.count >= 6 ? bytes[4] >> 4 : 0
                let items = bytes.count >= 6 ? Int(UInt16(bytes[4] & 0x0F) << 8 | UInt16(bytes[5])) : 0
                if !findings.contains(where: { $0.kind == .ntpMode7 }) { findings.append(.ntpMode7) }
                details.append(error == 0
                    ? "Mode 7\u{00A0}: monlist renvoie \(items) client\(items > 1 ? "s" : "") récent\(items > 1 ? "s" : "")."
                    : "Mode 7 (ntpdc)\u{00A0}: le serveur répond (erreur \(error)).")
            default:
                continue
            }
        }
        guard summary != nil || !findings.isEmpty else { return nil }
        return UDPReading(summary: summary ?? "Serveur NTP", details: details, findings: findings)
    }

    /// Valeur d'une variable de « ntpq -c rv » (« version="ntpd 4.2.8p15" »).
    public static func ntpVariable(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: name + "=") else { return nil }
        var rest = text[range.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        let end = rest.firstIndex { $0 == "," || $0 == "\r" || $0 == "\n" } ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: NetBIOS

    static func netbios(_ datagrams: [[UInt8]]) -> UDPReading? {
        for bytes in datagrams {
            guard let status = NamesNetBIOS.parseNodeStatus(bytes) else { continue }
            var parts = [status.hostname ?? status.entries.first?.name ?? "nom inconnu"]
            if let domain = status.domain { parts.append("groupe \(domain)") }
            var details = status.entries.map { "\($0.name) <\(String(format: "%02X", $0.suffix))>" + ($0.isGroup ? " (groupe)" : "") }
            if let mac = status.mac { details.append("Adresse MAC annoncée\u{00A0}: \(mac.formatted(.upperColon))") }
            return UDPReading(summary: "NetBIOS · " + parts.joined(separator: " · "), details: details)
        }
        return nil
    }

    // MARK: SNMP

    static func snmp(_ datagrams: [[UInt8]], community: String?) -> UDPReading? {
        var v2Summary: String?
        var v3Summary: String?
        var details: [String] = []
        var findings: [UDPFinding] = []
        for bytes in datagrams {
            if let message = try? SNMPMessage(decoding: bytes), message.pdu.type == .response {
                let used = message.community
                if message.pdu.errorStatus == 0, let bind = message.pdu.varbinds.first,
                   case .octetString(let raw) = bind.value {
                    let descr = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let firstLine = descr.split(whereSeparator: \.isNewline).first.map(String.init) ?? descr
                    v2Summary = "SNMP v2c · " + String(firstLine.prefix(90))
                    details.append("sysDescr\u{00A0}: \(descr)")
                } else {
                    v2Summary = "SNMP v2c · communauté acceptée"
                    details.append("Réponse v2c\u{00A0}: \(SNMPErrorStatus(rawValue: message.pdu.errorStatus)?.label ?? "erreur \(message.pdu.errorStatus)").")
                }
                findings.append(used == "public" ? .snmpPublic : .snmpV2c)
            } else if let message = try? SNMPv3Codec.decode(bytes) {
                let engine = message.usm.engineID
                let vendor = snmpEngineVendor(engine)
                v3Summary = "SNMP v3" + (vendor.map { " · moteur \($0)" } ?? "")
                details.append("engineID\u{00A0}: " + (engine.isEmpty ? "vide" : engine.map { String(format: "%02x", $0) }.joined()))
                if message.usm.boots > 0 || message.usm.time > 0 {
                    details.append("Redémarrages du moteur\u{00A0}: \(message.usm.boots) · en marche depuis \(duration(Int(message.usm.time)))")
                }
            }
        }
        if v2Summary == nil, let community, !community.isEmpty, v3Summary != nil {
            details.append("Aucune réponse en v2c avec la communauté choisie.")
        }
        guard let summary = v2Summary ?? v3Summary else { return nil }
        let both = v2Summary != nil && v3Summary != nil ? [v3Summary ?? ""] : []
        return UDPReading(summary: summary, details: both + details, findings: findings)
    }

    /// Fabricant d'après le numéro d'entreprise IANA de l'engineID (RFC 3411, premier bit à 1).
    public static func snmpEngineVendor(_ engineID: [UInt8]) -> String? {
        guard engineID.count >= 5, engineID[0] & 0x80 != 0 else { return nil }
        let number = (UInt32(engineID[0] & 0x7F) << 24) | (UInt32(engineID[1]) << 16) | (UInt32(engineID[2]) << 8) | UInt32(engineID[3])
        return enterpriseNames[number] ?? "entreprise \(number)"
    }

    static let enterpriseNames: [UInt32: String] = [
        9: "Cisco", 11: "HP", 43: "3Com", 311: "Microsoft", 674: "Dell", 1916: "Extreme", 2011: "Huawei",
        2435: "Brother", 2636: "Juniper", 4413: "Broadcom", 4526: "Netgear", 6574: "Synology", 6876: "VMware",
        8072: "Net-SNMP", 11863: "TP-Link", 12356: "Fortinet", 14823: "Aruba", 14988: "MikroTik", 25506: "H3C",
        25053: "Ruckus", 41112: "Ubiquiti", 47196: "HPE Aruba",
    ]

    static func duration(_ seconds: Int) -> String {
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)\u{00A0}j \(hours)\u{00A0}h" }
        if hours > 0 { return "\(hours)\u{00A0}h \(minutes)\u{00A0}min" }
        return "\(minutes)\u{00A0}min"
    }

    // MARK: IPMI

    /// Capacités d'authentification du canal (IPMI 2.0, 22.13).
    public struct IPMICapabilities: Hashable, Sendable {
        public var channel: UInt8
        public var authTypes: [String]
        public var supportsV2: Bool
        public var supportsV15: Bool
        public var anonymousLogin: Bool
        public var nullUsernames: Bool
        public var perMessageAuthDisabled: Bool
        public var oemID: UInt32
    }

    public static func ipmiCapabilities(_ bytes: [UInt8]) -> IPMICapabilities? {
        guard bytes.count >= 14, bytes[0] == 0x06, bytes[3] == 0x07 else { return nil }
        let authType = bytes[4]
        let lengthIndex = 4 + 1 + 4 + 4 + (authType == 0 ? 0 : 16)
        guard lengthIndex < bytes.count else { return nil }
        let start = lengthIndex + 1
        let length = Int(bytes[lengthIndex])
        guard length >= 15, start + length <= bytes.count else { return nil }
        let message = Array(bytes[start..<(start + length)])
        // rqAddr, NetFn/LUN (réponse App = 0x1C), somme, rsAddr, séquence, commande, code d'achèvement.
        guard message[1] >> 2 == 0x07, message[5] == 0x38, message[6] == 0x00 else { return nil }
        let data = Array(message[7...])
        guard data.count >= 8 else { return nil }
        var types: [String] = []
        let support = data[1]
        if support & 0x01 != 0 { types.append("aucune") }
        if support & 0x02 != 0 { types.append("MD2") }
        if support & 0x04 != 0 { types.append("MD5") }
        if support & 0x10 != 0 { types.append("mot de passe") }
        if support & 0x20 != 0 { types.append("OEM") }
        let status = data[2]
        let extended = support & 0x80 != 0 ? data[3] : 0
        return IPMICapabilities(channel: data[0] & 0x0F, authTypes: types,
                                supportsV2: extended & 0x02 != 0, supportsV15: support & 0x80 == 0 || extended & 0x01 != 0,
                                anonymousLogin: status & 0x01 != 0, nullUsernames: status & 0x02 != 0,
                                perMessageAuthDisabled: status & 0x10 != 0,
                                oemID: UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16)
    }

    static func ipmi(_ datagrams: [[UInt8]]) -> UDPReading? {
        for bytes in datagrams {
            guard let caps = ipmiCapabilities(bytes) else { continue }
            let version = caps.supportsV2 ? (caps.supportsV15 ? "IPMI 2.0 et 1.5" : "IPMI 2.0") : "IPMI 1.5"
            var details = ["Canal \(caps.channel) · authentification\u{00A0}: " + (caps.authTypes.isEmpty ? "—" : caps.authTypes.joined(separator: ", "))]
            details.append("Connexion anonyme\u{00A0}: " + (caps.anonymousLogin ? "permise" : "non") + " · utilisateur vide\u{00A0}: " + (caps.nullUsernames ? "permis" : "non"))
            if caps.oemID != 0 { details.append("Identifiant OEM\u{00A0}: \(caps.oemID)") }
            var findings: [UDPFinding] = [.ipmiExposed]
            if caps.anonymousLogin || caps.nullUsernames { findings.append(.ipmiAnonymous) }
            return UDPReading(summary: "BMC · \(version)", details: details, findings: findings)
        }
        return nil
    }

    // MARK: SSDP

    static func ssdp(_ datagrams: [[UInt8]]) -> UDPReading? {
        for bytes in datagrams {
            let headers = httpHeaders(bytes)
            guard let status = headers.status, status.uppercased().hasPrefix("HTTP/1.") else { continue }
            let server = headers.fields["server"]
            var details: [String] = []
            if let location = headers.fields["location"] { details.append("Description\u{00A0}: \(location)") }
            if let st = headers.fields["st"] { details.append("Type annoncé\u{00A0}: \(st)") }
            if let usn = headers.fields["usn"] { details.append("USN\u{00A0}: \(usn)") }
            return UDPReading(summary: "UPnP · " + (server ?? status), details: details)
        }
        return nil
    }

    // MARK: SIP

    static func sip(_ datagrams: [[UInt8]]) -> UDPReading? {
        for bytes in datagrams {
            let headers = httpHeaders(bytes)
            guard let status = headers.status, status.hasPrefix("SIP/2.0 ") else { continue }
            let code = String(status.dropFirst("SIP/2.0 ".count))
            let agent = headers.fields["user-agent"] ?? headers.fields["server"]
            var details = ["Réponse à OPTIONS\u{00A0}: \(code)"]
            if let allow = headers.fields["allow"] { details.append("Méthodes\u{00A0}: \(allow)") }
            return UDPReading(summary: "SIP " + code + (agent.map { " · \($0)" } ?? ""), details: details, findings: [.sipExposed])
        }
        return nil
    }

    // MARK: mDNS

    static func mdns(_ datagrams: [[UInt8]]) -> UDPReading? {
        for bytes in datagrams {
            guard let message = try? DNSMessageCodec.parse(bytes), message.isResponse else { continue }
            let services = (message.answers + message.additional).filter { $0.typeCode == 12 }
                .map(\.value).filter { $0.lowercased().hasSuffix(".local.") }
            var seen = Set<String>()
            let names = services.map { name -> String in
                let first = name.split(separator: ".").first.map(String.init) ?? name
                return first.hasPrefix("_") ? String(first.dropFirst()) : first
            }.filter { seen.insert($0).inserted }
            guard !names.isEmpty else {
                return UDPReading(summary: "mDNS · répond (aucun service annoncé)")
            }
            let shown = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? "…" : "")
            return UDPReading(summary: "mDNS · \(names.count) service\(names.count > 1 ? "s" : "")\u{00A0}: \(shown)",
                              details: services)
        }
        return nil
    }

    // MARK: Outils

    /// Ligne d'état et en-têtes (noms en minuscules) d'une réponse texte HTTP ou SIP.
    static func httpHeaders(_ bytes: [UInt8]) -> (status: String?, fields: [String: String]) {
        let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty else { return (nil, [:]) }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = clean(String(line[line.index(after: colon)...]))
            if fields[name] == nil, !value.isEmpty { fields[name] = value }
        }
        return (clean(first), fields)
    }

    /// Texte affichable : caractères imprimables, 160 au plus.
    static func clean(_ text: String) -> String {
        String(String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }).trimmingCharacters(in: .whitespaces).prefix(160))
    }

    static func unquote(_ text: String) -> String {
        clean(text.replacingOccurrences(of: "\" \"", with: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }
}
