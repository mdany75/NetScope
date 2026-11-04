import Foundation

// Décodeurs d'application : DNS (et mDNS, LLMNR, NetBIOS-NS), DHCP, HTTP en clair (et SSDP),
// TLS (en-têtes, ClientHello et ServerHello : version, SNI, ALPN), LLDP, CDP et STP.
// Le contenu chiffré de TLS n'est jamais déchiffré.

extension PacketDecoding {
    // MARK: DNS, mDNS, NetBIOS-NS

    mutating func dns(_ o: Int, _ end: Int, kind: PacketProtocol, llmnr: Bool = false, lengthPrefix: Int? = nil) {
        let title = kind == .mdns ? "Multicast DNS" : kind == .nbns ? "NetBIOS Name Service" : llmnr ? "LLMNR" : "DNS"
        guard end - o >= 12, b.has(o, 12) else { truncated(title); data(o, end); return }
        let id = b.u16(o), flags = b.u16(o + 2)
        let counts = (0..<4).map { Int(b.u16(o + 4 + 2 * $0)) }
        let isResponse = flags & 0x8000 != 0
        let opcode = Int(flags >> 11 & 0x0F), rcode = Int(flags & 0x0F)
        let isNetBIOS = kind == .nbns
        var fields: [PacketField] = []
        if let lengthPrefix { fields.append(PacketField("Longueur (DNS sur TCP)", "\(b.u16(lengthPrefix))", lengthPrefix, 2)) }
        fields.append(PacketField("Identifiant de transaction", PacketText.hex(UInt32(id)), o, 2))
        fields.append(PacketField("Drapeaux", "\(PacketText.hex(UInt32(flags))) (\(isResponse ? "réponse" : "requête")\(rcode != 0 ? ", \(Self.rcodeName(rcode))" : ""))", o + 2, 2, children: [
            PacketField("Type", isResponse ? "réponse" : "requête", o + 2, 1),
            PacketField("Opcode", Self.opcodeName(opcode, netbios: isNetBIOS), o + 2, 1),
            PacketField("Réponse d’autorité (AA)", flags & 0x0400 != 0 ? "oui" : "non", o + 2, 1),
            PacketField("Tronqué (TC)", flags & 0x0200 != 0 ? "oui" : "non", o + 2, 1),
            PacketField("Récursion demandée (RD)", flags & 0x0100 != 0 ? "oui" : "non", o + 2, 1),
            PacketField("Récursion possible (RA)", flags & 0x0080 != 0 ? "oui" : "non", o + 3, 1),
            PacketField("Code de réponse", Self.rcodeName(rcode), o + 3, 1),
        ]))
        let sectionNames = ["Questions", "Réponses", "Autorité", "Supplémentaires"]
        for (index, name) in ["Nombre de questions", "Nombre de réponses", "Nombre d’autorités", "Nombre de supplémentaires"].enumerated() {
            fields.append(PacketField(name, "\(counts[index])", o + 4 + 2 * index, 2))
        }
        var p = o + 12
        var questions: [String] = []
        var answers: [String] = []
        var questionFields: [PacketField] = []
        for _ in 0..<min(counts[0], 64) {
            guard let (name, next) = readName(p, base: o, end: end, netbios: isNetBIOS), next + 4 <= end else { truncated(title); break }
            let type = b.u16(next), klass = b.u16(next + 2)
            let typeName = Self.typeName(type, netbios: isNetBIOS)
            let unicast = kind == .mdns && klass & 0x8000 != 0
            questionFields.append(PacketField(name, "type \(typeName), classe \(Self.className(klass & 0x7FFF))" + (unicast ? ", réponse unicast demandée" : ""), p, next + 4 - p, children: [
                PacketField("Nom", name, p, next - p),
                PacketField("Type", "\(typeName) (\(type))", next, 2),
                PacketField("Classe", "\(Self.className(klass & 0x7FFF)) (\(PacketText.hex(UInt32(klass))))", next + 2, 2),
            ]))
            questions.append("\(typeName) \(name)")
            packet.dnsNames.append(name)
            p = next + 4
        }
        if !questionFields.isEmpty { fields.append(PacketField("Requêtes", "\(questionFields.count)", questionFields[0].offset, p - questionFields[0].offset, children: questionFields)) }
        for section in 1..<4 {
            var records: [PacketField] = []
            let start = p
            for _ in 0..<min(counts[section], 128) {
                guard let (record, text, next) = resourceRecord(p, base: o, end: end, kind: kind) else { break }
                records.append(record)
                if section == 1 || (kind == .mdns && section == 3 && counts[1] == 0) { if let text { answers.append(text) } }
                p = next
            }
            if !records.isEmpty { fields.append(PacketField(sectionNames[section], "\(records.count)", start, p - start, children: records)) }
        }
        add(kind, title + (isResponse ? " (réponse)" : " (requête)"), lengthPrefix ?? o, end - (lengthPrefix ?? o), fields)
        // Résumé : « Requête 0x1a2b A outlook.office365.com », « Réponse 0x1a2b A … → A 52.96.88.50 ».
        var summary: String
        if isNetBIOS {
            let operation = Self.opcodeName(opcode, netbios: true)
            if isResponse {
                summary = "Réponse (\(operation.lowercased())) " + (answers.first ?? questions.first ?? "")
            } else {
                summary = operation + " " + (questions.first ?? answers.first ?? "")
            }
        } else if kind == .mdns {
            summary = isResponse ? "Annonce mDNS" : "Requête mDNS"
            let items = isResponse ? answers : questions
            if !items.isEmpty { summary += " " + items.prefix(3).joined(separator: ", ") + (items.count > 3 ? "…" : "") }
        } else {
            summary = (isResponse ? "Réponse " : "Requête ") + PacketText.hex(UInt32(id)) + (questions.isEmpty ? "" : " " + questions.joined(separator: ", "))
            if isResponse {
                if rcode != 0 { summary += " · \(Self.rcodeName(rcode))" }
                if !answers.isEmpty { summary += " → " + answers.prefix(4).joined(separator: ", ") + (answers.count > 4 ? "…" : "") }
            }
        }
        packet.summary = summary
    }

    /// Nom DNS (étiquettes, compression par pointeur). NetBIOS : première étiquette de 32 lettres décodée.
    func readName(_ start: Int, base: Int, end: Int, netbios: Bool) -> (String, Int)? {
        var labels: [String] = []
        var p = start
        var next: Int?
        var jumps = 0
        while true {
            guard p < end, b.has(p, 1) else { return nil }
            let length = Int(b.u8(p))
            if length == 0 { p += 1; break }
            if length & 0xC0 == 0xC0 {
                guard b.has(p, 2), jumps < 32 else { return nil }
                let pointer = base + Int(b.u16(p) & 0x3FFF)
                if next == nil { next = p + 2 }
                p = pointer
                jumps += 1
                continue
            }
            guard length <= 63, p + 1 + length <= end else { return nil }
            let raw = b.array(p + 1, length)
            if netbios, labels.isEmpty, length == 32, let decoded = Self.netbiosName(raw) {
                labels.append(decoded)
            } else {
                labels.append(String(decoding: raw, as: UTF8.self))
            }
            p += 1 + length
            if labels.count > 64 { return nil }
        }
        let name = labels.isEmpty ? "<racine>" : labels.joined(separator: ".")
        return (name, next ?? p)
    }

    /// « WKS341<00> » à partir des 32 lettres A à P du codage NetBIOS.
    static func netbiosName(_ raw: [UInt8]) -> String? {
        guard raw.count == 32, raw.allSatisfy({ (0x41...0x50).contains($0) }) else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: 32, by: 2) { bytes.append((raw[i] - 0x41) << 4 | (raw[i + 1] - 0x41)) }
        let suffix = bytes[15]
        let name = String(decoding: bytes[0..<15], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return "\(name)<\(String(format: "%02x", suffix))>"
    }

    mutating func resourceRecord(_ p: Int, base: Int, end: Int, kind: PacketProtocol) -> (PacketField, String?, Int)? {
        let netbios = kind == .nbns
        guard let (name, afterName) = readName(p, base: base, end: end, netbios: netbios), afterName + 10 <= end else { return nil }
        let type = b.u16(afterName), klass = b.u16(afterName + 2), ttl = b.u32(afterName + 4), length = Int(b.u16(afterName + 8))
        let rdata = afterName + 10
        guard rdata + length <= end else { return nil }
        let typeName = Self.typeName(type, netbios: netbios)
        var value = PacketText.octets(length)
        var summaryValue: String?
        switch (type, netbios) {
        case (1, _) where length == 4:
            value = b.ipv4(rdata).description
        case (28, _) where length == 16:
            value = b.ipv6(rdata)
        case (2, _), (5, _), (12, _):
            value = readName(rdata, base: base, end: end, netbios: false)?.0 ?? value
        case (15, _) where length >= 3:
            value = "\(b.u16(rdata)) " + (readName(rdata + 2, base: base, end: end, netbios: false)?.0 ?? "?")
        case (16, _):
            var strings: [String] = []
            var q = rdata
            while q < rdata + length {
                let count = Int(b.u8(q))
                strings.append(b.text(q + 1, count))
                q += 1 + count
            }
            value = strings.map { "« \($0) »" }.joined(separator: " ")
        case (33, false) where length >= 7:
            value = "priorité \(b.u16(rdata)), poids \(b.u16(rdata + 2)), port \(b.u16(rdata + 4)), " + (readName(rdata + 6, base: base, end: end, netbios: false)?.0 ?? "?")
        case (32, true) where length >= 6:
            var addresses: [String] = []
            var q = rdata
            while q + 6 <= rdata + length { addresses.append(b.ipv4(q + 2).description); q += 6 }
            value = addresses.joined(separator: ", ")
        case (41, _):
            value = "EDNS0, taille UDP \(klass)"
        default:
            break
        }
        let cacheFlush = kind == .mdns && klass & 0x8000 != 0
        let classText = type == 41 ? "\(klass)" : Self.className(klass & 0x7FFF) + (cacheFlush ? " (vider le cache)" : "")
        let field = PacketField(name, "\(typeName) \(value)", p, rdata + length - p, children: [
            PacketField("Nom", name, p, afterName - p),
            PacketField("Type", "\(typeName) (\(type))", afterName, 2),
            PacketField(type == 41 ? "Taille UDP" : "Classe", classText, afterName + 2, 2),
            PacketField("Durée de vie (TTL)", "\(ttl)\u{00A0}s", afterName + 4, 4),
            PacketField("Longueur des données", "\(length)", afterName + 8, 2),
            PacketField(Self.rdataName(type, netbios: netbios), value, rdata, length),
        ])
        if type != 41 { summaryValue = kind == .mdns ? "\(typeName) \(name)" : "\(typeName) \(value)" }
        if netbios { summaryValue = "\(name) \(value)" }
        return (field, summaryValue, rdata + length)
    }

    static func rdataName(_ type: UInt16, netbios: Bool) -> String {
        switch (type, netbios) {
        case (1, _), (28, _): return "Adresse"
        case (5, _): return "Nom canonique"
        case (12, _): return "Pointeur"
        case (2, _): return "Serveur de noms"
        case (15, _): return "Serveur de courriel"
        case (16, _): return "Texte"
        case (33, false): return "Service"
        case (32, true): return "Adresses NetBIOS"
        default: return "Données"
        }
    }

    static func typeName(_ type: UInt16, netbios: Bool) -> String {
        if netbios { return type == 0x20 ? "NB" : type == 0x21 ? "NBSTAT" : "\(type)" }
        switch type {
        case 1: return "A"
        case 2: return "NS"
        case 5: return "CNAME"
        case 6: return "SOA"
        case 12: return "PTR"
        case 15: return "MX"
        case 16: return "TXT"
        case 28: return "AAAA"
        case 33: return "SRV"
        case 41: return "OPT"
        case 43: return "DS"
        case 46: return "RRSIG"
        case 47: return "NSEC"
        case 48: return "DNSKEY"
        case 64: return "SVCB"
        case 65: return "HTTPS"
        case 255: return "ANY"
        case 257: return "CAA"
        default: return "TYPE\(type)"
        }
    }

    static func className(_ klass: UInt16) -> String {
        switch klass {
        case 1: return "IN"
        case 3: return "CH"
        case 255: return "ANY"
        default: return "\(klass)"
        }
    }

    static func rcodeName(_ code: Int) -> String {
        switch code {
        case 0: return "aucune erreur"
        case 1: return "requête mal formée"
        case 2: return "échec du serveur"
        case 3: return "nom inexistant"
        case 4: return "non implanté"
        case 5: return "refusée"
        case 6: return "nom existant (NetBIOS\u{00A0}: conflit)"
        default: return "code \(code)"
        }
    }

    static func opcodeName(_ code: Int, netbios: Bool) -> String {
        if netbios {
            switch code {
            case 0: return "Requête de nom"
            case 5: return "Enregistrement de nom"
            case 6: return "Libération de nom"
            case 7: return "Attente (WACK)"
            case 8, 9: return "Rafraîchissement de nom"
            default: return "Opcode \(code)"
            }
        }
        switch code {
        case 0: return "requête standard"
        case 1: return "requête inverse"
        case 2: return "état du serveur"
        case 4: return "notification"
        case 5: return "mise à jour"
        default: return "opcode \(code)"
        }
    }

    // MARK: DHCP

    mutating func dhcp(_ o: Int, _ end: Int) {
        guard end - o >= 240, b.has(o, 240) else { truncated("DHCP"); data(o, end); return }
        let op = b.u8(o), xid = b.u32(o + 4), secs = b.u16(o + 8), flags = b.u16(o + 10)
        let client = b.ipv4(o + 12), yours = b.ipv4(o + 16), next = b.ipv4(o + 20), relay = b.ipv4(o + 24)
        let mac = b.mac(o + 28)
        var fields = [
            PacketField("Type de message", op == 1 ? "requête de démarrage (1)" : op == 2 ? "réponse de démarrage (2)" : "\(op)", o, 1),
            PacketField("Type de matériel", b.u8(o + 1) == 1 ? "Ethernet (1)" : "\(b.u8(o + 1))", o + 1, 1),
            PacketField("Longueur de l’adresse matérielle", "\(b.u8(o + 2))", o + 2, 1),
            PacketField("Sauts", "\(b.u8(o + 3))", o + 3, 1),
            PacketField("Identifiant de transaction", PacketText.hex(xid, digits: 8), o + 4, 4),
            PacketField("Secondes écoulées", "\(secs)", o + 8, 2),
            PacketField("Drapeaux", flags & 0x8000 != 0 ? "\(PacketText.hex(UInt32(flags))) (diffusion)" : "\(PacketText.hex(UInt32(flags))) (unicast)", o + 10, 2),
            PacketField("Adresse du client (ciaddr)", client.description, o + 12, 4),
            PacketField("Adresse proposée (yiaddr)", yours.description, o + 16, 4),
            PacketField("Serveur suivant (siaddr)", next.description, o + 20, 4),
            PacketField("Agent relais (giaddr)", relay.description, o + 24, 4),
            PacketField("Adresse MAC du client", mac.formatted(), o + 28, 6),
        ]
        let serverName = b.text(o + 44, 64), file = b.text(o + 108, 128)
        fields.append(PacketField("Nom du serveur", serverName.isEmpty ? "non indiqué" : serverName, o + 44, 64))
        fields.append(PacketField("Fichier d’amorçage", file.isEmpty ? "non indiqué" : file, o + 108, 128))
        let cookieOK = b.array(o + 236, 4) == DHCPDiscover.magicCookie
        fields.append(PacketField("Cookie magique", cookieOK ? "DHCP" : b.hex(o + 236, 4, separator: ""), o + 236, 4))
        var type: DHCPMessageType?
        var requested: IPv4Address?
        var hostname: String?
        var p = o + 240
        var options: [PacketField] = []
        while cookieOK, p < end {
            let code = b.u8(p)
            if code == 0 { p += 1; continue }
            if code == 255 { options.append(PacketField("Option (255) Fin", "", p, 1)); break }
            guard p + 2 <= end else { break }
            let length = Int(b.u8(p + 1))
            guard p + 2 + length <= end else { truncated("DHCP"); break }
            let v = p + 2
            var value = b.hex(v, length, separator: "")
            switch code {
            case 53 where length >= 1:
                type = DHCPMessageType(rawValue: b.u8(v))
                value = type?.label ?? "\(b.u8(v))"
            case 1, 28, 50, 54:
                if length >= 4 { value = b.ipv4(v).description }
                if code == 50 { requested = b.ipv4(v) }
            case 3, 6, 42, 44:
                value = stride(from: 0, to: length - length % 4, by: 4).map { b.ipv4(v + $0).description }.joined(separator: ", ")
            case 12, 15, 60, 66, 67:
                value = b.text(v, length)
                if code == 12 { hostname = value }
            case 51 where length == 4, 58 where length == 4, 59 where length == 4:
                value = DHCPOffer.leaseText(b.u32(v)) + " (\(b.u32(v))\u{00A0}s)"
            case 57 where length == 2:
                value = "\(b.u16(v))"
            case 55:
                value = b.array(v, length).map { "\($0)" }.joined(separator: ", ")
            case 61 where length == 7 && b.u8(v) == 1:
                value = "Ethernet, " + b.mac(v + 1).formatted()
            default:
                break
            }
            options.append(PacketField("Option (\(code)) \(Self.dhcpOptionName(code))", value, p, length + 2))
            p += 2 + length
        }
        if !options.isEmpty { fields.append(PacketField("Options", "\(options.count)", o + 240, p - o - 240 + 1, children: options)) }
        add(.dhcp, "DHCP, \(type?.label ?? (op == 1 ? "requête" : "réponse"))", o, end - o, fields)
        var summary = type?.label ?? "BOOTP"
        switch type {
        case .offer?, .ack?: summary += " · \(yours) pour \(mac.formatted())"
        case .request?: summary += " · \(requested?.description ?? client.description) demandée"
        case .discover?: summary += " · \(mac.formatted())"
        default: break
        }
        if let hostname { summary += " (\(hostname))" }
        packet.summary = summary + " · xid \(PacketText.hex(xid, digits: 8))"
    }

    static func dhcpOptionName(_ code: UInt8) -> String {
        switch code {
        case 1: return "Masque de sous-réseau"
        case 3: return "Routeur"
        case 6: return "Serveurs DNS"
        case 12: return "Nom d’hôte"
        case 15: return "Nom de domaine"
        case 28: return "Adresse de diffusion"
        case 42: return "Serveurs NTP"
        case 43: return "Propre au fabricant"
        case 44: return "Serveurs WINS"
        case 50: return "Adresse demandée"
        case 51: return "Durée du bail"
        case 53: return "Type de message DHCP"
        case 54: return "Identifiant du serveur"
        case 55: return "Liste des paramètres demandés"
        case 57: return "Taille maximale du message"
        case 58: return "Délai de renouvellement (T1)"
        case 59: return "Délai de réassociation (T2)"
        case 60: return "Classe du fabricant"
        case 61: return "Identifiant du client"
        case 66: return "Serveur TFTP"
        case 67: return "Fichier d’amorçage"
        case 81: return "FQDN du client"
        case 82: return "Informations de l’agent relais"
        case 108: return "IPv6 seulement préféré"
        case 119: return "Domaines de recherche"
        case 121: return "Routes sans classe"
        case 252: return "WPAD"
        default: return "Option inconnue"
        }
    }

    // MARK: HTTP et SSDP

    mutating func http(_ o: Int, _ end: Int, kind: PacketProtocol) {
        var lines: [(String, Int, Int)] = []
        var p = o
        var headerEnd: Int?
        while p < end, lines.count < 100 {
            var q = p
            while q < end, b.u8(q) != 0x0A { q += 1 }
            guard q < end else { break }
            let lineEnd = q > p && b.u8(q - 1) == 0x0D ? q - 1 : q
            let line = String(decoding: b.slice(p, lineEnd - p), as: UTF8.self)
            if line.isEmpty { headerEnd = q + 1; break }
            lines.append((line, p, q + 1 - p))
            p = q + 1
        }
        guard let first = lines.first else { data(o, end); return }
        let isResponse = first.0.hasPrefix("HTTP/")
        var fields = [PacketField(isResponse ? "Ligne d’état" : "Ligne de requête", first.0, first.1, first.2)]
        if isResponse {
            let parts = first.0.split(separator: " ", maxSplits: 2)
            if parts.count >= 2, let status = Int(parts[1]) { packet.httpStatus = status }
        } else {
            packet.httpRequest = first.0
        }
        for (line, offset, length) in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { fields.append(PacketField("En-tête", line, offset, length)); continue }
            let name = String(line[..<colon]), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields.append(PacketField(name, value, offset, length))
            if name.lowercased() == "host" { packet.httpHost = value }
        }
        if let headerEnd {
            if headerEnd < end { fields.append(PacketField("Corps", PacketText.octets(end - headerEnd), headerEnd, end - headerEnd)) }
        } else {
            packet.problems.append("HTTP\u{00A0}: en-têtes incomplets (suite dans le segment suivant)")
        }
        let label = kind == .ssdp ? "SSDP" : "HTTP"
        add(kind, "\(label), \(isResponse ? "réponse" : "requête")", o, end - o, fields)
        var summary = first.0.count > 120 ? String(first.0.prefix(120)) + "…" : first.0
        if kind == .ssdp, let st = fields.first(where: { ["st", "nt"].contains($0.name.lowercased()) }) { summary += " · \(st.value)" }
        packet.summary = summary
    }

    // MARK: TLS

    mutating func tls(_ o: Int, _ end: Int) {
        var p = o
        var records: [PacketField] = []
        var messages: [String] = []
        var lastVersion: UInt16 = 0
        while p + 5 <= end, TLSRecognizer.looksLikeTLS(b, p, end), records.count < 32 {
            let type = b.u8(p), version = b.u16(p + 1), length = Int(b.u16(p + 3))
            lastVersion = version
            let recordEnd = min(end, p + 5 + length)
            var children = [
                PacketField("Type de contenu", "\(Self.tlsContentName(type)) (\(type))", p, 1),
                PacketField("Version", Self.tlsVersionName(version), p + 1, 2),
                PacketField("Longueur", "\(length)", p + 3, 2),
            ]
            if p + 5 + length > end { packet.problems.append("TLS\u{00A0}: enregistrement incomplet (suite dans le segment suivant)") }
            switch type {
            case 22:
                var q = p + 5
                var parsed = false
                while q + 4 <= recordEnd {
                    let handshakeType = b.u8(q), handshakeLength = Int(b.u24(q + 1))
                    guard let name = Self.handshakeName(handshakeType), q + 4 + handshakeLength <= recordEnd || handshakeType == 1 || handshakeType == 2 else { break }
                    let bodyEnd = min(recordEnd, q + 4 + handshakeLength)
                    var hello: [PacketField] = [
                        PacketField("Type de négociation", "\(name) (\(handshakeType))", q, 1),
                        PacketField("Longueur", "\(handshakeLength)", q + 1, 3),
                    ]
                    var message = name
                    if handshakeType == 1 { message = clientHello(q + 4, bodyEnd, into: &hello) }
                    if handshakeType == 2 { message = serverHello(q + 4, bodyEnd, into: &hello) }
                    children.append(PacketField("Négociation", name, q, bodyEnd - q, children: hello))
                    messages.append(message)
                    parsed = true
                    q = bodyEnd
                }
                if !parsed {
                    // Négociation chiffrée (TLS 1.3 après le Server Hello) : rien à lire.
                    children.append(PacketField("Message de négociation chiffré", PacketText.octets(length), p + 5, recordEnd - p - 5))
                    messages.append("Négociation chiffrée")
                }
            case 23:
                children.append(PacketField("Données applicatives chiffrées", PacketText.octets(length), p + 5, recordEnd - p - 5))
                messages.append("Données applicatives")
            case 21:
                if length == 2, recordEnd - p >= 7 {
                    children.append(PacketField("Niveau", b.u8(p + 5) == 2 ? "fatal" : "avertissement", p + 5, 1))
                    children.append(PacketField("Description", Self.alertName(b.u8(p + 6)), p + 6, 1))
                    messages.append("Alerte (\(Self.alertName(b.u8(p + 6))))")
                } else {
                    children.append(PacketField("Alerte chiffrée", PacketText.octets(length), p + 5, recordEnd - p - 5))
                    messages.append("Alerte chiffrée")
                }
            case 20:
                messages.append("Change Cipher Spec")
            default:
                break
            }
            records.append(PacketField("Enregistrement TLS", "\(Self.tlsContentName(type)), \(Self.tlsVersionName(version)), \(PacketText.octets(length))", p, recordEnd - p, children: children))
            p = recordEnd
        }
        if p < end { records.append(PacketField("Suite d’un enregistrement précédent", PacketText.octets(end - p), p, end - p)) }
        add(.tls, "TLS (\(Self.tlsVersionName(lastVersion)))", o, end - o, records)
        packet.summary = messages.isEmpty ? "Suite d’un enregistrement TLS" : messages.joined(separator: ", ")
    }

    mutating func clientHello(_ o: Int, _ end: Int, into fields: inout [PacketField]) -> String {
        guard o + 38 <= end else { truncated("TLS Client Hello"); return "Client Hello" }
        packet.tlsHandshake = "Client Hello"
        fields.append(PacketField("Version annoncée", Self.tlsVersionName(b.u16(o)), o, 2))
        fields.append(PacketField("Aléa", b.hex(o + 2, 32, separator: ""), o + 2, 32))
        var p = o + 34
        let sessionLength = Int(b.u8(p))
        fields.append(PacketField("Identifiant de session", sessionLength == 0 ? "vide" : b.hex(p + 1, sessionLength, separator: ""), p, 1 + sessionLength))
        p += 1 + sessionLength
        guard p + 2 <= end else { return "Client Hello" }
        let suitesLength = Int(b.u16(p))
        var suites: [PacketField] = []
        var q = p + 2
        while q + 2 <= min(end, p + 2 + suitesLength) {
            suites.append(PacketField("Suite", Self.cipherName(b.u16(q)), q, 2))
            q += 2
        }
        fields.append(PacketField("Suites de chiffrement", "\(suitesLength / 2)", p, 2 + suitesLength, children: suites))
        p += 2 + suitesLength
        guard p + 1 <= end else { return "Client Hello" }
        let compressionLength = Int(b.u8(p))
        fields.append(PacketField("Méthodes de compression", "\(compressionLength)", p, 1 + compressionLength))
        p += 1 + compressionLength
        var versions: [UInt16] = []
        var alpn: [String] = []
        if p + 2 <= end {
            let extensionsEnd = min(end, p + 2 + Int(b.u16(p)))
            var extensions: [PacketField] = []
            var e = p + 2
            while e + 4 <= extensionsEnd {
                let type = b.u16(e), length = Int(b.u16(e + 2))
                let v = e + 4
                guard v + length <= extensionsEnd else { break }
                var children: [PacketField] = []
                var value = PacketText.octets(length)
                switch type {
                case 0 where length >= 5:
                    // server_name : liste, type 0 (nom d'hôte), longueur, nom.
                    var s = v + 2
                    while s + 3 <= v + length {
                        let nameLength = Int(b.u16(s + 1))
                        let name = b.text(s + 3, nameLength)
                        if b.u8(s) == 0 {
                            packet.tlsServerName = name
                            value = name
                            children.append(PacketField("Nom du serveur (SNI)", name, s + 3, nameLength))
                        }
                        s += 3 + nameLength
                    }
                case 43 where length >= 1:
                    var s = v + 1
                    while s + 2 <= v + 1 + Int(b.u8(v)) { versions.append(b.u16(s)); s += 2 }
                    value = versions.filter { !Self.isGREASE($0) }.map(Self.tlsVersionName).joined(separator: ", ")
                case 16 where length >= 2:
                    var s = v + 2
                    while s < v + length {
                        let count = Int(b.u8(s))
                        alpn.append(b.text(s + 1, count))
                        s += 1 + count
                    }
                    value = alpn.joined(separator: ", ")
                default:
                    break
                }
                extensions.append(PacketField("Extension \(Self.extensionName(type))", value, e, 4 + length, children: children))
                e = v + length
            }
            fields.append(PacketField("Extensions", "\(extensions.count)", p, extensionsEnd - p, children: extensions))
        }
        var text = "Client Hello"
        var parts: [String] = []
        if let sni = packet.tlsServerName { parts.append("SNI=\(sni)") }
        if versions.contains(0x0304) { parts.append("TLS 1.3 proposé") }
        if !alpn.isEmpty { parts.append("ALPN=\(alpn.joined(separator: ","))") }
        if !parts.isEmpty { text += " (\(parts.joined(separator: ", ")))" }
        return text
    }

    mutating func serverHello(_ o: Int, _ end: Int, into fields: inout [PacketField]) -> String {
        guard o + 38 <= end else { truncated("TLS Server Hello"); return "Server Hello" }
        packet.tlsHandshake = "Server Hello"
        var version = b.u16(o)
        fields.append(PacketField("Version", Self.tlsVersionName(version), o, 2))
        fields.append(PacketField("Aléa", b.hex(o + 2, 32, separator: ""), o + 2, 32))
        var p = o + 34
        let sessionLength = Int(b.u8(p))
        fields.append(PacketField("Identifiant de session", sessionLength == 0 ? "vide" : b.hex(p + 1, sessionLength, separator: ""), p, 1 + sessionLength))
        p += 1 + sessionLength
        guard p + 3 <= end else { return "Server Hello" }
        let cipher = b.u16(p)
        fields.append(PacketField("Suite de chiffrement choisie", Self.cipherName(cipher), p, 2))
        fields.append(PacketField("Compression", "\(b.u8(p + 2))", p + 2, 1))
        p += 3
        if p + 2 <= end {
            let extensionsEnd = min(end, p + 2 + Int(b.u16(p)))
            var extensions: [PacketField] = []
            var e = p + 2
            while e + 4 <= extensionsEnd {
                let type = b.u16(e), length = Int(b.u16(e + 2))
                guard e + 4 + length <= extensionsEnd else { break }
                var value = PacketText.octets(length)
                if type == 43, length == 2 { version = b.u16(e + 4); value = Self.tlsVersionName(version) }
                if type == 16, length >= 3 { value = b.text(e + 7, Int(b.u8(e + 6))) }
                extensions.append(PacketField("Extension \(Self.extensionName(type))", value, e, 4 + length))
                e += 4 + length
            }
            fields.append(PacketField("Extensions", "\(extensions.count)", p, extensionsEnd - p, children: extensions))
        }
        return "Server Hello (\(Self.tlsVersionName(version)), \(Self.cipherName(cipher)))"
    }

    static func isGREASE(_ value: UInt16) -> Bool { value & 0x0F0F == 0x0A0A && value >> 8 == value & 0xFF }

    static func tlsVersionName(_ version: UInt16) -> String {
        switch version {
        case 0x0300: return "SSL 3.0"
        case 0x0301: return "TLS 1.0"
        case 0x0302: return "TLS 1.1"
        case 0x0303: return "TLS 1.2"
        case 0x0304: return "TLS 1.3"
        default: return isGREASE(version) ? "GREASE" : PacketText.hex(UInt32(version))
        }
    }

    static func tlsContentName(_ type: UInt8) -> String {
        switch type {
        case 20: return "Change Cipher Spec"
        case 21: return "Alerte"
        case 22: return "Négociation"
        case 23: return "Données applicatives"
        default: return "\(type)"
        }
    }

    static func handshakeName(_ type: UInt8) -> String? {
        switch type {
        case 0: return "Hello Request"
        case 1: return "Client Hello"
        case 2: return "Server Hello"
        case 4: return "New Session Ticket"
        case 8: return "Encrypted Extensions"
        case 11: return "Certificat"
        case 12: return "Échange de clé du serveur"
        case 13: return "Demande de certificat"
        case 14: return "Server Hello Done"
        case 15: return "Vérification du certificat"
        case 16: return "Échange de clé du client"
        case 20: return "Finished"
        default: return nil
        }
    }

    static func alertName(_ code: UInt8) -> String {
        switch code {
        case 0: return "fermeture"
        case 10: return "message inattendu"
        case 20: return "MAC incorrect"
        case 40: return "échec de la négociation"
        case 42: return "certificat incorrect"
        case 45: return "certificat expiré"
        case 46: return "certificat inconnu"
        case 48: return "autorité inconnue"
        case 70: return "version de protocole"
        case 80: return "erreur interne"
        case 112: return "nom de serveur non reconnu"
        default: return "code \(code)"
        }
    }

    static func extensionName(_ type: UInt16) -> String {
        if isGREASE(type) { return "GREASE" }
        switch type {
        case 0: return "server_name"
        case 5: return "status_request"
        case 10: return "supported_groups"
        case 11: return "ec_point_formats"
        case 13: return "signature_algorithms"
        case 16: return "ALPN"
        case 18: return "signed_certificate_timestamp"
        case 21: return "padding"
        case 23: return "extended_master_secret"
        case 27: return "compress_certificate"
        case 35: return "session_ticket"
        case 41: return "pre_shared_key"
        case 43: return "supported_versions"
        case 45: return "psk_key_exchange_modes"
        case 51: return "key_share"
        case 17513: return "application_settings"
        case 65037: return "encrypted_client_hello"
        case 65281: return "renegotiation_info"
        default: return "\(type)"
        }
    }

    static func cipherName(_ suite: UInt16) -> String {
        switch suite {
        case 0x1301: return "TLS_AES_128_GCM_SHA256"
        case 0x1302: return "TLS_AES_256_GCM_SHA384"
        case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
        case 0xC02B: return "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
        case 0xC02C: return "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
        case 0xC02F: return "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
        case 0xC030: return "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
        case 0xCCA8: return "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
        case 0xCCA9: return "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
        case 0xC013: return "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA"
        case 0xC014: return "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA"
        case 0x009C: return "TLS_RSA_WITH_AES_128_GCM_SHA256"
        case 0x009D: return "TLS_RSA_WITH_AES_256_GCM_SHA384"
        case 0x002F: return "TLS_RSA_WITH_AES_128_CBC_SHA"
        case 0x0035: return "TLS_RSA_WITH_AES_256_CBC_SHA"
        case 0x00FF: return "TLS_EMPTY_RENEGOTIATION_INFO_SCSV"
        default: return isGREASE(suite) ? "GREASE" : PacketText.hex(UInt32(suite))
        }
    }

    // MARK: LLDP, CDP, STP (résumés par les décodeurs de la note 2)

    mutating func lldp(_ o: Int, _ end: Int) {
        var p = o
        var fields: [PacketField] = []
        while p + 2 <= end {
            let header = b.u16(p)
            let type = Int(header >> 9), length = Int(header & 0x01FF)
            let v = p + 2
            guard v + length <= end else { truncated("LLDP"); break }
            var value = length == 0 ? "" : b.text(v, length)
            var name: String
            switch type {
            case 0: name = "Fin de LLDPDU"; value = ""
            case 1, 2:
                name = type == 1 ? "Châssis ID" : "Port ID"
                let subtype = b.u8(v)
                let macSubtype: UInt8 = type == 1 ? 4 : 3, addressSubtype: UInt8 = type == 1 ? 5 : 4
                if subtype == macSubtype, length == 7 { value = b.mac(v + 1).formatted() }
                else if subtype == addressSubtype, length >= 6, b.u8(v + 1) == 1 { value = b.ipv4(v + 2).description }
                else { value = b.text(v + 1, length - 1) }
            case 3: name = "Durée de vie (TTL)"; value = "\(b.u16(v))\u{00A0}s"
            case 4: name = "Description du port"
            case 5: name = "Nom du système"
            case 6: name = "Description du système"
            case 7:
                name = "Capacités"
                let enabled = b.u16(v + 2)
                value = LLDPDecoder.capabilityNames.enumerated().filter { enabled & (1 << $0.offset) != 0 }.map(\.element).joined(separator: ", ")
            case 8:
                name = "Adresse de gestion"
                value = length >= 6 && b.u8(v + 1) == 1 ? b.ipv4(v + 2).description : b.hex(v, length, separator: "")
            case 127:
                let oui = b.u24(v)
                let ouiName = oui == 0x0080C2 ? "IEEE 802.1" : oui == 0x00120F ? "IEEE 802.3" : oui == 0x0012BB ? "LLDP-MED" : oui == 0x00000C ? "Cisco" : b.hex(v, 3, separator: ":")
                name = "Propre à une organisation (\(ouiName))"
                value = "sous-type \(b.u8(v + 3))"
                if oui == 0x0080C2, b.u8(v + 3) == 1, length >= 6 { value = "VLAN natif (PVID) \(b.u16(v + 4))" }
            default: name = "TLV \(type)"; value = b.hex(v, length, separator: "")
            }
            fields.append(PacketField(name, value, p, 2 + length, children: [
                PacketField("Type", "\(type)", p, 2),
                PacketField("Longueur", "\(length)", p, 2),
            ]))
            p = v + length
            if type == 0 { break }
        }
        add(.lldp, "LLDP (Link Layer Discovery Protocol)", o, p - o, fields)
        if let neighbor = LLDPDecoder.decode(b.array(o, end - o)) {
            packet.summary = "LLDP · " + neighbor.headline
        } else {
            packet.summary = "LLDP"
        }
    }

    mutating func cdp(_ o: Int, _ end: Int) {
        guard end - o >= 4 else { truncated("CDP"); return }
        var fields = [
            PacketField("Version", "\(b.u8(o))", o, 1),
            PacketField("Durée de vie (TTL)", "\(b.u8(o + 1))\u{00A0}s", o + 1, 1),
            PacketField("Somme de contrôle", PacketText.hex(UInt32(b.u16(o + 2))), o + 2, 2),
        ]
        var p = o + 4
        while p + 4 <= end {
            let type = b.u16(p), length = Int(b.u16(p + 2))
            guard length >= 4, p + length <= end else { break }
            let v = p + 4, count = length - 4
            let name: String
            var value = b.hex(v, min(count, 24), separator: "")
            switch type {
            case 0x0001: name = "Device ID"; value = b.text(v, count)
            case 0x0002: name = "Adresses"
            case 0x0003: name = "Port ID"; value = b.text(v, count)
            case 0x0004: name = "Capacités"
            case 0x0005: name = "Version logicielle"; value = b.text(v, count).split(separator: "\n").first.map(String.init) ?? ""
            case 0x0006: name = "Plateforme"; value = b.text(v, count)
            case 0x0009: name = "Domaine VTP"; value = b.text(v, count)
            case 0x000A: name = "VLAN natif"; value = "\(b.u16(v))"
            case 0x000B: name = "Duplex"; value = b.u8(v) == 1 ? "intégral" : "semi"
            case 0x000E: name = "VLAN voix"; value = count >= 3 ? "\(b.u16(v + 1))" : value
            case 0x0010: name = "Puissance"; value = "\(b.u16(v))\u{00A0}mW"
            case 0x0016: name = "Adresse de gestion"
            default: name = "TLV \(PacketText.hex(UInt32(type)))"
            }
            fields.append(PacketField(name, value, p, length))
            p += length
        }
        add(.cdp, "CDP (Cisco Discovery Protocol)", o, p - o, fields)
        if let neighbor = CDPDecoder.decode(b.array(o, end - o)) {
            packet.summary = "CDP · " + neighbor.headline
        } else {
            packet.summary = "CDP"
        }
    }

    mutating func stp(_ o: Int, _ end: Int) {
        guard end - o >= 4, b.has(o, 4) else { truncated("STP"); return }
        let version = b.u8(o + 2), type = b.u8(o + 3)
        let typeName = type == 0x80 ? "notification de changement (TCN)" : type == 2 ? (version >= 3 ? "MST" : "RST") : "configuration"
        var fields = [
            PacketField("Protocole", PacketText.hex(UInt32(b.u16(o))), o, 2),
            PacketField("Version", version == 0 ? "STP (0)" : version == 2 ? "RSTP (2)" : version == 3 ? "MSTP (3)" : "\(version)", o + 2, 1),
            PacketField("Type de BPDU", typeName, o + 3, 1),
        ]
        var summary = "STP, \(typeName)"
        if type != 0x80, b.has(o, 35), end - o >= 35 {
            let rootPriority = b.u16(o + 5), rootMAC = b.mac(o + 7)
            let cost = b.u32(o + 13)
            let bridgePriority = b.u16(o + 17), bridgeMAC = b.mac(o + 19)
            let port = b.u16(o + 25)
            fields += [
                PacketField("Drapeaux", PacketText.hex(UInt32(b.u8(o + 4)), digits: 2), o + 4, 1),
                PacketField("Pont racine", "\(rootPriority) / \(rootMAC.formatted())", o + 5, 8),
                PacketField("Coût du chemin vers la racine", "\(cost)", o + 13, 4),
                PacketField("Pont émetteur", "\(bridgePriority) / \(bridgeMAC.formatted())", o + 17, 8),
                PacketField("Port", PacketText.hex(UInt32(port)), o + 25, 2),
                PacketField("Âge du message", "\(b.u16(o + 27) / 256)\u{00A0}s", o + 27, 2),
                PacketField("Âge maximal", "\(b.u16(o + 29) / 256)\u{00A0}s", o + 29, 2),
                PacketField("Intervalle Hello", "\(b.u16(o + 31) / 256)\u{00A0}s", o + 31, 2),
                PacketField("Délai de transmission", "\(b.u16(o + 33) / 256)\u{00A0}s", o + 33, 2),
            ]
            summary += " · racine \(rootPriority)/\(rootMAC.formatted()) · coût \(cost) · port \(PacketText.hex(UInt32(port)))"
        }
        add(.stp, "Spanning Tree (\(typeName))", o, min(end - o, 36), fields)
        packet.summary = summary
    }
}
