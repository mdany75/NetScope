import Foundation

// Note 78 (Capture de paquets) : décodeurs des services de supervision et d'authentification.
// - SNMP v1, v2c et v3 (RFC 3416, 3412) : PDU, request-id, erreurs, varbinds nommés (noms des MIB
//   courantes du navigateur SNMP) ; la communauté est masquée (secret) ; v3 : en-têtes seulement ;
// - Syslog (RFC 3164, RFC 5424, FortiOS) en UDP ou TCP (RFC 6587), par l'analyseur des Journaux ;
// - RADIUS (RFC 2865, 2866, 5176) : code, attributs nommés, attributs propres aux fabricants ; les
//   mots de passe et authentifiants restent masqués ;
// - NTP (RFC 5905) : mode, strate, référence, horodatages.

enum SyslogRecognizer {
    /// « <PRI> » en tête (ou « 123 <PRI> » en TCP cadré par longueur).
    static func looksLikeSyslog(_ b: ByteView, _ o: Int, _ end: Int, allowLength: Bool) -> Bool {
        var p = o
        if allowLength {
            var digits = 0
            while p < end, digits < 6, b.u8(p) >= 0x30, b.u8(p) <= 0x39 { p += 1; digits += 1 }
            if digits > 0 { guard p < end, b.u8(p) == 0x20 else { return false }; p += 1 }
        }
        guard p + 3 <= end, b.u8(p) == 0x3C else { return false }
        var q = p + 1
        var digits = 0
        while q < end, digits < 4, b.u8(q) >= 0x30, b.u8(q) <= 0x39 { q += 1; digits += 1 }
        return digits > 0 && q < end && b.u8(q) == 0x3E
    }
}

extension PacketDecoding {
    // MARK: SNMP

    /// En-tête BER : étiquette, début et longueur du contenu.
    func ber(_ p: Int, _ end: Int) -> (tag: UInt8, content: Int, length: Int)? {
        guard p + 2 <= end else { return nil }
        let tag = b.u8(p)
        let first = Int(b.u8(p + 1))
        if first < 0x80 {
            return p + 2 + first <= end ? (tag, p + 2, first) : nil
        }
        let count = first & 0x7F
        guard count >= 1, count <= 3, p + 2 + count <= end else { return nil }
        var length = 0
        for index in 0..<count { length = length << 8 | Int(b.u8(p + 2 + index)) }
        return p + 2 + count + length <= end ? (tag, p + 2 + count, length) : nil
    }

    func berInteger(_ content: Int, _ length: Int) -> Int64 {
        guard length > 0, length <= 8 else { return 0 }
        var value: Int64 = Int64(Int8(bitPattern: b.u8(content)))
        for index in 1..<length { value = value << 8 | Int64(b.u8(content + index)) }
        return value
    }

    mutating func snmp(_ o: Int, _ end: Int) {
        guard let message = ber(o, end), message.tag == 0x30,
              let version = ber(message.content, end), version.tag == 0x02 else {
            truncated("SNMP")
            data(o, end)
            return
        }
        let messageEnd = message.content + message.length
        let versionValue = berInteger(version.content, version.length)
        let versionLabel = versionValue == 0 ? "v1" : versionValue == 1 ? "v2c" : versionValue == 3 ? "v3" : "version \(versionValue)"
        var fields = [PacketField("Version", "\(versionLabel) (\(versionValue))", version.content - 2, version.length + 2)]
        var p = version.content + version.length
        if versionValue == 3 {
            snmpV3(&fields, p, messageEnd, o: o, end: end)
            return
        }
        guard let community = ber(p, messageEnd), community.tag == 0x04 else { truncated("SNMP"); data(o, end); return }
        let secret = b.text(community.content, community.length)
        fields.append(PacketField("Communauté", Self.maskedSecret(secret), community.content, community.length))
        p = community.content + community.length
        guard let pdu = ber(p, messageEnd) else {
            truncated("SNMP")
            add(.snmp, "SNMP \(versionLabel)", o, end - o, fields)
            return
        }
        let (pduField, summary, transaction) = snmpPDU(pdu, at: p)
        fields.append(pduField)
        add(.snmp, "SNMP \(versionLabel), \(Self.snmpPDUName(pdu.tag))", o, end - o, fields)
        packet.summary = summary
        packet.transaction = transaction
    }

    /// SNMPv3 : en-tête global et modèle de sécurité ; les données protégées ne sont pas lues.
    mutating func snmpV3(_ fields: inout [PacketField], _ start: Int, _ messageEnd: Int, o: Int, end: Int) {
        var p = start
        var msgID: Int64?
        if let global = ber(p, messageEnd), global.tag == 0x30 {
            var q = global.content
            var children: [PacketField] = []
            let names = ["Identifiant du message", "Taille maximale", "Drapeaux", "Modèle de sécurité"]
            for name in names {
                guard let item = ber(q, global.content + global.length) else { break }
                if item.tag == 0x02 {
                    let value = berInteger(item.content, item.length)
                    if name == names[0] { msgID = value }
                    let text = name == names[3] ? (value == 3 ? "USM (3)" : "\(value)") : "\(value)"
                    children.append(PacketField(name, text, q, item.content + item.length - q))
                } else if item.tag == 0x04, item.length >= 1 {
                    let flags = b.u8(item.content)
                    var parts: [String] = []
                    parts.append(flags & 0x01 != 0 ? "authentifié" : "non authentifié")
                    parts.append(flags & 0x02 != 0 ? "chiffré" : "en clair")
                    if flags & 0x04 != 0 { parts.append("réponse attendue") }
                    children.append(PacketField(name, "\(PacketText.hex(UInt32(flags), digits: 2)) (\(parts.joined(separator: ", ")))", q, item.content + item.length - q))
                }
                q = item.content + item.length
            }
            fields.append(PacketField("En-tête global", "", global.content - 2, global.length + 2, children: children))
            p = global.content + global.length
        }
        if let security = ber(p, messageEnd) {
            fields.append(PacketField("Paramètres de sécurité (USM)", PacketText.octets(security.length), p, security.content + security.length - p))
            p = security.content + security.length
        }
        if p < messageEnd {
            fields.append(PacketField("Données protégées", PacketText.octets(messageEnd - p), p, messageEnd - p))
        }
        add(.snmp, "SNMP v3", o, end - o, fields)
        packet.summary = "SNMPv3" + (msgID.map { " msgID=\($0)" } ?? "") + " (données protégées)"
    }

    mutating func snmpPDU(_ pdu: (tag: UInt8, content: Int, length: Int), at start: Int) -> (PacketField, String, PacketTransaction?) {
        let name = Self.snmpPDUName(pdu.tag)
        let pduEnd = pdu.content + pdu.length
        var children: [PacketField] = []
        var p = pdu.content
        var requestID: Int64?
        var errorStatus: Int64 = 0
        if pdu.tag == 0xA4 {
            // Trap SNMPv1 : entreprise, agent, générique, spécifique, horodatage.
            let labels = ["Entreprise", "Adresse de l’agent", "Trap générique", "Trap spécifique", "Horodatage"]
            for label in labels {
                guard let item = ber(p, pduEnd) else { break }
                children.append(PacketField(label, snmpValueText(item, oidName: label == labels[0]), p, item.content + item.length - p))
                p = item.content + item.length
            }
        } else {
            let labels = pdu.tag == 0xA5 ? ["Identifiant de requête", "Non répétés", "Répétitions max."] : ["Identifiant de requête", "État d’erreur", "Index d’erreur"]
            for (index, label) in labels.enumerated() {
                guard let item = ber(p, pduEnd), item.tag == 0x02 else { break }
                let value = berInteger(item.content, item.length)
                var text = "\(value)"
                if index == 0 { requestID = value }
                if index == 1, pdu.tag != 0xA5 {
                    errorStatus = value
                    text = "\(value) (\(SNMPErrorStatus(rawValue: Int(value))?.label ?? "erreur \(value)"))"
                }
                children.append(PacketField(label, text, p, item.content + item.length - p))
                p = item.content + item.length
            }
        }
        var bindings: [String] = []
        if let list = ber(p, pduEnd), list.tag == 0x30 {
            var q = list.content
            var items: [PacketField] = []
            let listEnd = list.content + list.length
            while q < listEnd, items.count < 64, let bind = ber(q, listEnd), bind.tag == 0x30 {
                if let oid = ber(bind.content, bind.content + bind.length), oid.tag == 0x06,
                   let decoded = try? SNMPBERReader.decodeOID(b.array(oid.content, oid.length)) {
                    let valueStart = oid.content + oid.length
                    let named = SNMPMIB.name(for: decoded) ?? decoded.description
                    var valueText = "—"
                    var valueChild: PacketField?
                    if let value = ber(valueStart, bind.content + bind.length) {
                        valueText = snmpValueText(value, oidName: false, oid: decoded)
                        valueChild = PacketField("Valeur", valueText, valueStart, value.content + value.length - valueStart)
                    }
                    let shown = valueText == "—" ? named : "\(named) = \(valueText)"
                    bindings.append(shown)
                    items.append(PacketField(named, valueText == "—" ? "" : valueText, q, bind.content + bind.length - q, children: [
                        PacketField("OID", decoded.description, oid.content - 2, oid.length + 2),
                    ] + (valueChild.map { [$0] } ?? [])))
                }
                q = bind.content + bind.length
            }
            children.append(PacketField("Liaisons de variables", "\(items.count)", p, list.content + list.length - p, children: items))
        }
        let field = PacketField(name, requestID.map { "request-id \($0)" } ?? "", start, pduEnd - start, children: children)
        var summary = name + (requestID.map { " id=\($0)" } ?? "")
        if errorStatus != 0 { summary += " · \(SNMPErrorStatus(rawValue: Int(errorStatus))?.label ?? "erreur \(errorStatus)")" }
        if !bindings.isEmpty { summary += " " + bindings.prefix(3).joined(separator: ", ") + (bindings.count > 3 ? "…" : "") }
        var transaction: PacketTransaction?
        if let requestID {
            switch pdu.tag {
            case 0xA0, 0xA1, 0xA3, 0xA5, 0xA6:
                transaction = PacketTransaction(kind: .snmp, key: "snmp|\(requestID)", isRequest: true,
                                                label: name + (bindings.first.map { " " + ($0.components(separatedBy: " = ").first ?? $0) } ?? ""))
            case 0xA2, 0xA8:
                transaction = PacketTransaction(kind: .snmp, key: "snmp|\(requestID)", isRequest: false, label: name,
                                                failure: errorStatus != 0 ? (SNMPErrorStatus(rawValue: Int(errorStatus))?.label ?? "erreur \(errorStatus)") : nil)
            default: break
            }
        }
        return (field, summary, transaction)
    }

    func snmpValueText(_ item: (tag: UInt8, content: Int, length: Int), oidName: Bool, oid: SNMPOID? = nil) -> String {
        let raw = [item.tag] + SNMPBER.encodeLength(item.length) + b.array(item.content, item.length)
        var valueReader = SNMPBERReader(raw)
        guard let value = try? valueReader.readValue() else { return "\(PacketText.octets(item.length)) (type \(PacketText.hex(UInt32(item.tag), digits: 2)))" }
        if case .null = value { return "—" }
        if case .oid(let target) = value, oidName || oid != nil {
            return SNMPMIB.name(for: target).map { "\($0) (\(target))" } ?? target.description
        }
        return SNMPBrowserFormat.display(value, oid: oid)
    }

    static func snmpPDUName(_ tag: UInt8) -> String {
        switch tag {
        case 0xA0: return "get-request"
        case 0xA1: return "get-next-request"
        case 0xA2: return "get-response"
        case 0xA3: return "set-request"
        case 0xA4: return "trap (v1)"
        case 0xA5: return "get-bulk-request"
        case 0xA6: return "inform-request"
        case 0xA7: return "trap (v2)"
        case 0xA8: return "report"
        default: return "PDU \(PacketText.hex(UInt32(tag), digits: 2))"
        }
    }

    /// Secret masqué : première lettre, points, nombre de caractères (« p••••• (6 caractères) »).
    static func maskedSecret(_ text: String) -> String {
        guard let first = text.first else { return "(vide)" }
        return "\(first)" + String(repeating: "•", count: min(8, max(3, text.count - 1))) + " (\(text.count)\u{00A0}caractère\(text.count > 1 ? "s" : ""), masquée)"
    }

    // MARK: Syslog

    mutating func syslog(_ o: Int, _ end: Int, overTCP: Bool) {
        var start = o
        var fields: [PacketField] = []
        if overTCP {
            var p = o
            var length = 0
            while p < end, b.u8(p) >= 0x30, b.u8(p) <= 0x39 { length = length * 10 + Int(b.u8(p) - 0x30); p += 1 }
            if p > o, p < end, b.u8(p) == 0x20 {
                fields.append(PacketField("Longueur (RFC\u{00A0}6587)", "\(length)", o, p - o))
                start = p + 1
            }
        }
        var bodyEnd = end
        while bodyEnd > start, [0x0A, 0x0D, 0x00].contains(b.u8(bodyEnd - 1)) { bodyEnd -= 1 }
        let bytes = b.array(start, bodyEnd - start)
        let message = SyslogParser.parse(bytes, from: packet.ipSource ?? "", received: Date(timeIntervalSince1970: 0))
        var priEnd = start
        while priEnd < bodyEnd, b.u8(priEnd) != 0x3E { priEnd += 1 }
        let facilityName = message.facility.flatMap { LogFacility.name($0) } ?? "?"
        let pri = (message.facility ?? 1) * 8 + message.severity.rawValue
        fields.append(PacketField("Priorité", "<\(pri)> (\(facilityName).\(message.severity.keyword))", start, priEnd + 1 - start, children: [
            PacketField("Facilité", "\(facilityName) (\(message.facility ?? 1))", start, priEnd + 1 - start),
            PacketField("Gravité", "\(message.severity.label) (\(message.severity.rawValue))", start, priEnd + 1 - start),
        ]))
        func locate(_ text: String?) -> (Int, Int) {
            guard let text, !text.isEmpty else { return (priEnd + 1, bodyEnd - priEnd - 1) }
            let needle = Array(text.utf8.prefix(48))
            if needle.count <= bytes.count {
                for index in 0...(bytes.count - needle.count) where bytes[index] == needle[0] && Array(bytes[index..<(index + needle.count)]) == needle {
                    return (start + index, min(text.utf8.count, bodyEnd - start - index))
                }
            }
            return (priEnd + 1, bodyEnd - priEnd - 1)
        }
        if let hostname = message.hostname, hostname != "-" {
            let (offset, length) = locate(hostname)
            fields.append(PacketField("Hôte", hostname, offset, length))
        }
        if let app = message.app {
            let (offset, length) = locate(app.components(separatedBy: " · ").first)
            fields.append(PacketField("Application", app, offset, length))
        }
        if let event = message.eventID {
            let (offset, length) = locate(event)
            fields.append(PacketField("Événement", event, offset, length))
        }
        let (offset, length) = locate(message.message.count > 4 ? String(message.message.prefix(32)) : nil)
        fields.append(PacketField("Message", message.message, offset, message.message.utf8.count >= length ? bodyEnd - offset : length))
        if !message.fields.isEmpty {
            let pairs = message.fields.sorted { $0.key < $1.key }.prefix(40)
            fields.append(PacketField("Champs", "\(message.fields.count)", priEnd + 1, bodyEnd - priEnd - 1,
                                      children: pairs.map { pair in
                                          let (o2, l2) = locate(pair.key + "=")
                                          return PacketField(pair.key, pair.value, o2, l2)
                                      }))
        }
        add(.syslog, "Syslog, \(facilityName).\(message.severity.keyword)", o, end - o, fields)
        packet.syslogSeverity = message.severity.rawValue
        let host = message.hostname.map { $0 == "-" ? "" : $0 + "\u{00A0}: " } ?? ""
        let text = message.message.count > 140 ? String(message.message.prefix(140)) + "…" : message.message
        packet.summary = "\(facilityName).\(message.severity.keyword) \(host)\(text)"
    }

    // MARK: RADIUS

    mutating func radius(_ o: Int, _ end: Int) {
        let code = Int(b.u8(o)), identifier = Int(b.u8(o + 1)), length = Int(b.u16(o + 2))
        let stop = length >= 20 && o + length <= end ? o + length : end
        if length < 20 || o + length > end { packet.problems.append("RADIUS\u{00A0}: longueur annoncée \(length) incohérente") }
        let name = Self.radiusCodeName(code)
        var fields = [
            PacketField("Code", "\(name) (\(code))", o, 1),
            PacketField("Identifiant", "\(identifier)", o + 1, 1),
            PacketField("Longueur", "\(length)", o + 2, 2),
            PacketField("Authentifiant", b.hex(o + 4, 16, separator: ""), o + 4, 16),
        ]
        var p = o + 20
        var attributes: [PacketField] = []
        var userName: String?
        var statusType: String?
        var replyMessage: String?
        while p + 2 <= stop, attributes.count < 80 {
            let type = b.u8(p), size = Int(b.u8(p + 1))
            guard size >= 2, p + size <= stop else { packet.problems.append("RADIUS\u{00A0}: attribut \(type) tronqué"); break }
            let valueStart = p + 2, valueLength = size - 2
            let (label, text, children) = radiusAttribute(type, valueStart, valueLength)
            if type == 1 { userName = text }
            if type == 40 { statusType = text }
            if type == 18 { replyMessage = text }
            attributes.append(PacketField(label, text, p, size, children: children))
            p += size
        }
        if !attributes.isEmpty { fields.append(PacketField("Attributs", "\(attributes.count)", o + 20, p - o - 20, children: attributes)) }
        add(.radius, "RADIUS, \(name)", o, stop - o, fields)
        packet.radiusCode = code
        var summary = "\(name) id=\(identifier)"
        if let statusType { summary += " (\(statusType))" }
        if let userName { summary += " · utilisateur «\u{00A0}\(userName)\u{00A0}»" }
        if let replyMessage, [3, 42, 45].contains(code) { summary += " · \(replyMessage)" }
        packet.summary = summary
        let key = "radius|\(identifier)"
        switch code {
        case 1, 4, 12, 40, 43:
            packet.transaction = PacketTransaction(kind: .radius, key: key, isRequest: true, label: name + (userName.map { " \($0)" } ?? ""))
        case 2, 3, 5, 11, 41, 42, 44, 45:
            let failure: String? = code == 3 ? "accès refusé" + (replyMessage.map { " (\($0))" } ?? "") : (code == 42 || code == 45) ? "demande refusée (NAK)" : nil
            packet.transaction = PacketTransaction(kind: .radius, key: key, isRequest: false, label: name, failure: failure)
        default: break
        }
    }

    func radiusAttribute(_ type: UInt8, _ o: Int, _ length: Int) -> (String, String, [PacketField]) {
        let name = Self.radiusAttributeName(type)
        func integer() -> Int { length == 4 ? Int(b.u32(o)) : 0 }
        switch type {
        case 1, 11, 18, 30, 31, 32, 44, 87, 22, 34, 35, 77:
            return (name, b.text(o, length), [])
        case 2, 3, 69:
            return (name, "masqué (\(PacketText.octets(length)), chiffré)", [])
        case 80:
            return (name, "masqué (\(PacketText.octets(length)))", [])
        case 4, 8, 9, 14:
            return (name, length == 4 ? b.ipv4(o).description : b.hex(o, length), [])
        case 6:
            let value = integer()
            return (name, "\(Self.radiusServiceType(value)) (\(value))", [])
        case 40:
            let value = integer()
            let label = [1: "Start", 2: "Stop", 3: "Interim-Update", 7: "Accounting-On", 8: "Accounting-Off"][value] ?? "\(value)"
            return (name, label, [])
        case 61:
            let value = integer()
            let label = [0: "Async", 5: "Virtual", 15: "Ethernet", 19: "Wireless-802.11"][value] ?? "\(value)"
            return (name, "\(label) (\(value))", [])
        case 64, 65:
            // Attributs de tunnel : une étiquette d'un octet, puis la valeur sur trois.
            let value = length == 4 ? Int(b.u24(o + 1)) : integer()
            let label = type == 64 ? ([13: "VLAN", 3: "L2TP", 1: "PPTP"][value] ?? "\(value)") : ([6: "802 (Ethernet)", 1: "IPv4"][value] ?? "\(value)")
            return (name, "\(label) (\(value))", [])
        case 81:
            // Tunnel-Private-Group-Id : étiquette facultative (moins de 0x20), puis le VLAN en texte.
            let skip = length > 0 && b.u8(o) < 0x20 ? 1 : 0
            return (name, "VLAN " + b.text(o + skip, length - skip), [])
        case 5, 7, 12, 27, 28, 46, 85:
            let value = integer()
            if type == 27 || type == 28 || type == 46 || type == 85 { return (name, "\(value)\u{00A0}s", []) }
            return (name, "\(value)", [])
        case 79:
            let eapCode = length >= 1 ? Int(b.u8(o)) : 0
            let eapType = length >= 5 ? Int(b.u8(o + 4)) : 0
            let codes = [1: "requête", 2: "réponse", 3: "réussite", 4: "échec"]
            let types = [1: "identité", 3: "Nak", 4: "MD5", 13: "TLS", 21: "TTLS", 25: "PEAP", 26: "MSCHAPv2"]
            var text = "EAP \(codes[eapCode] ?? "\(eapCode)")"
            if eapCode <= 2, length >= 5 { text += ", \(types[eapType] ?? "type \(eapType)")" }
            return (name, text + " (\(PacketText.octets(length)))", [])
        case 26:
            guard length >= 6 else { return (name, PacketText.octets(length), []) }
            let vendor = Int(b.u32(o))
            let vendorType = Int(b.u8(o + 4)), vendorLength = Int(b.u8(o + 5))
            let vendorName = Self.radiusVendorName(vendor)
            var children = [PacketField("Fabricant", "\(vendorName) (\(vendor))", o, 4)]
            var text = vendorName
            if vendorLength >= 2, 4 + vendorLength <= length {
                let valueLength = vendorLength - 2
                let raw = b.array(o + 6, valueLength)
                let printable = !raw.isEmpty && raw.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
                let shown = printable ? String(decoding: raw, as: UTF8.self) : (valueLength == 4 ? "\(b.u32(o + 6))" : b.hex(o + 6, valueLength))
                let attribute = Self.radiusVendorAttributeName(vendor, vendorType)
                children.append(PacketField(attribute, shown, o + 4, vendorLength))
                text += " · \(attribute) = \(shown)"
            }
            return (name, text, children)
        default:
            return (name, length <= 16 ? b.hex(o, length, separator: "") : PacketText.octets(length), [])
        }
    }

    static func radiusCodeName(_ code: Int) -> String {
        switch code {
        case 1: return "Access-Request"
        case 2: return "Access-Accept"
        case 3: return "Access-Reject"
        case 4: return "Accounting-Request"
        case 5: return "Accounting-Response"
        case 11: return "Access-Challenge"
        case 12: return "Status-Server"
        case 13: return "Status-Client"
        case 40: return "Disconnect-Request"
        case 41: return "Disconnect-ACK"
        case 42: return "Disconnect-NAK"
        case 43: return "CoA-Request"
        case 44: return "CoA-ACK"
        case 45: return "CoA-NAK"
        default: return "Code \(code)"
        }
    }

    static func radiusAttributeName(_ type: UInt8) -> String {
        switch type {
        case 1: return "User-Name"
        case 2: return "User-Password"
        case 3: return "CHAP-Password"
        case 4: return "NAS-IP-Address"
        case 5: return "NAS-Port"
        case 6: return "Service-Type"
        case 7: return "Framed-Protocol"
        case 8: return "Framed-IP-Address"
        case 9: return "Framed-IP-Netmask"
        case 11: return "Filter-Id"
        case 12: return "Framed-MTU"
        case 14: return "Login-IP-Host"
        case 18: return "Reply-Message"
        case 22: return "Framed-Route"
        case 24: return "State"
        case 25: return "Class"
        case 26: return "Vendor-Specific"
        case 27: return "Session-Timeout"
        case 28: return "Idle-Timeout"
        case 30: return "Called-Station-Id"
        case 31: return "Calling-Station-Id"
        case 32: return "NAS-Identifier"
        case 33: return "Proxy-State"
        case 34: return "Login-LAT-Service"
        case 35: return "Login-LAT-Node"
        case 40: return "Acct-Status-Type"
        case 41: return "Acct-Delay-Time"
        case 42: return "Acct-Input-Octets"
        case 43: return "Acct-Output-Octets"
        case 44: return "Acct-Session-Id"
        case 45: return "Acct-Authentic"
        case 46: return "Acct-Session-Time"
        case 47: return "Acct-Input-Packets"
        case 48: return "Acct-Output-Packets"
        case 49: return "Acct-Terminate-Cause"
        case 55: return "Event-Timestamp"
        case 61: return "NAS-Port-Type"
        case 64: return "Tunnel-Type"
        case 65: return "Tunnel-Medium-Type"
        case 69: return "Tunnel-Password"
        case 77: return "Connect-Info"
        case 79: return "EAP-Message"
        case 80: return "Message-Authenticator"
        case 81: return "Tunnel-Private-Group-Id"
        case 85: return "Acct-Interim-Interval"
        case 87: return "NAS-Port-Id"
        case 95: return "NAS-IPv6-Address"
        default: return "Attribut \(type)"
        }
    }

    static func radiusServiceType(_ value: Int) -> String {
        switch value {
        case 1: return "Login"
        case 2: return "Framed"
        case 5: return "Outbound"
        case 6: return "Administrative"
        case 8: return "Authenticate-Only"
        case 10: return "Call-Check"
        default: return "type \(value)"
        }
    }

    static func radiusVendorName(_ vendor: Int) -> String {
        switch vendor {
        case 9: return "Cisco"
        case 311: return "Microsoft"
        case 11: return "HP"
        case 14823: return "Aruba"
        case 12356: return "Fortinet"
        case 41112: return "Ubiquiti"
        case 25506: return "H3C"
        case 14122: return "WISPr"
        default: return "fabricant"
        }
    }

    static func radiusVendorAttributeName(_ vendor: Int, _ type: Int) -> String {
        switch (vendor, type) {
        case (12356, 1): return "Fortinet-Group-Name"
        case (12356, 6): return "Fortinet-Access-Profile"
        case (12356, 7): return "Fortinet-Vdom-Name"
        case (9, 1): return "Cisco-AVPair"
        case (14823, 1): return "Aruba-User-Role"
        case (311, 16): return "MS-MPPE-Send-Key"
        case (311, 17): return "MS-MPPE-Recv-Key"
        default: return "attribut \(type)"
        }
    }

    // MARK: NTP

    /// Horodatage NTP (secondes depuis 1900, fraction sur 32 bits) en secondes depuis 1970 ; 0 si absent.
    static func ntpTime(_ seconds: UInt32, _ fraction: UInt32) -> Double {
        guard seconds != 0 || fraction != 0 else { return 0 }
        return Double(seconds) - 2_208_988_800 + Double(fraction) / 4_294_967_296
    }

    /// « 2026-11-04 15:21:35,123456 UTC » ; « non renseigné » pour 0.
    static func ntpText(_ value: Double) -> String {
        guard value != 0 else { return "0 (non renseigné)" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: value)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let micro = Int(((value - value.rounded(.down)) * 1_000_000).rounded(.down))
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d,%06d UTC", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, micro)
    }

    mutating func ntp(_ o: Int, _ end: Int) {
        let first = b.u8(o)
        let leap = Int(first >> 6), version = Int(first >> 3 & 0x07), mode = Int(first & 0x07)
        let stratum = Int(b.u8(o + 1)), poll = Int(Int8(bitPattern: b.u8(o + 2))), precision = Int(Int8(bitPattern: b.u8(o + 3)))
        let rootDelay = Double(b.u32(o + 4)) / 65_536, rootDispersion = Double(b.u32(o + 8)) / 65_536
        let reference: String
        if stratum <= 1 {
            let text = b.text(o + 12, 4).trimmingCharacters(in: CharacterSet(charactersIn: "\0. "))
            reference = text.isEmpty ? b.hex(o + 12, 4, separator: "") : text
        } else {
            reference = b.ipv4(o + 12).description
        }
        let times = (0..<4).map { PacketDecoding.ntpTime(b.u32(o + 16 + $0 * 8), b.u32(o + 20 + $0 * 8)) }
        let modeName = Self.ntpModeName(mode)
        let leapName = ["aucune", "dernière minute de 61 s", "dernière minute de 59 s", "horloge non synchronisée"][leap]
        let fields = [
            PacketField("Drapeaux", "\(PacketText.hex(UInt32(first), digits: 2))", o, 1, children: [
                PacketField("Indicateur de seconde intercalaire", "\(leapName) (\(leap))", o, 1),
                PacketField("Version", "\(version)", o, 1),
                PacketField("Mode", "\(modeName) (\(mode))", o, 1),
            ]),
            PacketField("Strate", "\(stratum) (\(Self.ntpStratumName(stratum)))", o + 1, 1),
            PacketField("Intervalle d’interrogation", "\(poll) (\(1 << max(0, min(poll, 17)))\u{00A0}s)", o + 2, 1),
            PacketField("Précision", "\(precision) (\(Self.ntpPrecision(precision)))", o + 3, 1),
            PacketField("Délai jusqu’à la référence", PacketText.seconds(rootDelay, decimals: 6) + "\u{00A0}s", o + 4, 4),
            PacketField("Dispersion jusqu’à la référence", PacketText.seconds(rootDispersion, decimals: 6) + "\u{00A0}s", o + 8, 4),
            PacketField("Identifiant de référence", reference, o + 12, 4),
            PacketField("Horodatage de référence", Self.ntpText(times[0]), o + 16, 8),
            PacketField("Horodatage d’origine", Self.ntpText(times[1]), o + 24, 8),
            PacketField("Horodatage de réception", Self.ntpText(times[2]), o + 32, 8),
            PacketField("Horodatage d’émission", Self.ntpText(times[3]), o + 40, 8),
        ]
        add(.ntp, "NTP v\(version), \(modeName)", o, min(end - o, 48), fields)
        if end - o > 48 { data(o + 48, end, title: "Extension ou authentifiant NTP") }
        packet.ntp = NTPInfo(mode: mode, stratum: stratum, origin: times[1], receive: times[2], transmit: times[3])
        var summary = "NTP v\(version), \(modeName)"
        if mode == 4 || mode == 5 { summary += ", strate \(stratum)" + (stratum >= 1 && stratum <= 15 ? ", référence \(reference)" : "") }
        packet.summary = summary
        let key = { (value: Double) in "ntp|" + String(format: "%.6f", value) }
        if mode == 3, times[3] != 0 {
            packet.transaction = PacketTransaction(kind: .ntp, key: key(times[3]), isRequest: true, label: "client")
        } else if mode == 4, times[1] != 0 {
            let kiss = stratum == 0 ? "refus du serveur (Kiss-o’-Death «\u{00A0}\(reference)\u{00A0}»)" : leap == 3 ? "serveur non synchronisé" : nil
            packet.transaction = PacketTransaction(kind: .ntp, key: key(times[1]), isRequest: false, label: "serveur", failure: kiss)
        }
    }

    static func ntpModeName(_ mode: Int) -> String {
        switch mode {
        case 1: return "symétrique actif"
        case 2: return "symétrique passif"
        case 3: return "client"
        case 4: return "serveur"
        case 5: return "diffusion"
        case 6: return "contrôle"
        case 7: return "privé"
        default: return "réservé"
        }
    }

    static func ntpStratumName(_ stratum: Int) -> String {
        switch stratum {
        case 0: return "non précisée ou refus"
        case 1: return "référence primaire"
        case 2...15: return "référence secondaire"
        case 16: return "non synchronisé"
        default: return "réservée"
        }
    }

    /// « 2^-20 ≈ 0,95 µs ».
    static func ntpPrecision(_ exponent: Int) -> String {
        let seconds = pow(2.0, Double(exponent))
        if seconds >= 1e-3 { return String(format: "%.3f", seconds * 1000).replacingOccurrences(of: ".", with: ",") + "\u{00A0}ms" }
        return String(format: "%.2f", seconds * 1_000_000).replacingOccurrences(of: ".", with: ",") + "\u{00A0}µs"
    }
}
