import Foundation

// Note 78 (Capture de paquets) : décodeurs de la téléphonie sur IP.
// - SIP (RFC 3261) en UDP ou TCP : ligne de requête ou d'état, en-têtes (formes courtes comprises),
//   corps SDP (RFC 4566) détaillé ligne par ligne ;
// - RTP (RFC 3550) : en-tête, type de charge (codec) ; reconnu par son contenu (version 2, type de
//   charge connu, ports au-dessus de 1024), faute de signalisation dans le même paquet ;
// - RTCP : rapports d'émetteur et de récepteur (perte, gigue), SDES, BYE.
// Aucun son n'est reconstitué : seule la qualité du transport est lue.

enum SIPRecognizer {
    static let methods = ["INVITE", "ACK", "BYE", "CANCEL", "REGISTER", "OPTIONS", "PRACK", "SUBSCRIBE", "NOTIFY",
                          "PUBLISH", "INFO", "REFER", "MESSAGE", "UPDATE"]

    /// « SIP/2.0 200 OK » ou « INVITE sip:… SIP/2.0 ».
    static func looksLikeSIP(_ b: ByteView, _ o: Int, _ end: Int) -> Bool {
        guard end - o >= 12 else { return false }
        let head = String(decoding: b.slice(o, min(24, end - o)), as: UTF8.self)
        if head.hasPrefix("SIP/2.0 ") { return true }
        return methods.contains { head.hasPrefix($0 + " sip:") || head.hasPrefix($0 + " sips:") || head.hasPrefix($0 + " tel:") }
    }
}

enum RTPRecognizer {
    enum Kind { case rtp, rtcp }

    /// Types de charge RTP reconnus : statiques (RFC 3551) et dynamiques (96 à 127).
    static func isKnownPayloadType(_ type: UInt8) -> Bool {
        [0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 25, 26, 28, 31, 32, 33, 34].contains(type) || (96...127).contains(type)
    }

    /// RTP ou RTCP d'après le contenu (version 2, longueurs cohérentes) ; nil sinon.
    static func kind(_ b: ByteView, _ o: Int, _ end: Int) -> Kind? {
        let length = end - o
        guard length >= 8, b.has(o, 8), b.u8(o) >> 6 == 2 else { return nil }
        let second = b.u8(o + 1)
        if (200...204).contains(second) {
            // RTCP : la longueur (mots de 32 bits moins un) tient dans le datagramme.
            let size = (Int(b.u16(o + 2)) + 1) * 4
            return size <= length ? .rtcp : nil
        }
        guard length >= 12, isKnownPayloadType(second & 0x7F) else { return nil }
        var header = 12 + Int(b.u8(o) & 0x0F) * 4
        guard header <= length else { return nil }
        if b.u8(o) & 0x10 != 0 {
            guard header + 4 <= length else { return nil }
            header += 4 + Int(b.u16(o + header + 2)) * 4
            guard header <= length else { return nil }
        }
        if b.u8(o) & 0x20 != 0 {
            let padding = Int(b.u8(end - 1))
            guard padding > 0, header + padding <= length else { return nil }
        }
        return .rtp
    }

    /// Nom du codec d'un type de charge statique ; « dynamique » pour 96 à 127.
    static func codecName(_ type: UInt8) -> String {
        switch type {
        case 0: return "PCMU (G.711 µ-loi)"
        case 3: return "GSM"
        case 4: return "G.723"
        case 5, 6: return "DVI4"
        case 7: return "LPC"
        case 8: return "PCMA (G.711 A-loi)"
        case 9: return "G.722"
        case 10, 11: return "L16"
        case 12: return "QCELP"
        case 13: return "Bruit de confort (CN)"
        case 14: return "MPA"
        case 15: return "G.728"
        case 16, 17: return "DVI4"
        case 18: return "G.729"
        case 25: return "CelB"
        case 26: return "JPEG"
        case 28: return "nv"
        case 31: return "H.261"
        case 32: return "MPV"
        case 33: return "MP2T"
        case 34: return "H.263"
        case 96...127: return "dynamique (\(type))"
        default: return "type \(type)"
        }
    }

    /// Nom court (résumé) : « PCMU », « G.729 », « dyn. 101 ».
    static func shortCodec(_ type: UInt8) -> String {
        switch type {
        case 0: return "PCMU"
        case 8: return "PCMA"
        case 9: return "G.722"
        case 13: return "CN"
        case 18: return "G.729"
        case 96...127: return "dyn.\u{00A0}\(type)"
        default: return codecName(type)
        }
    }

    /// Fréquence d'horloge des types statiques (Hz) ; nil pour un type dynamique (estimée par l'analyse).
    static func clockRate(_ type: UInt8) -> Double? {
        switch type {
        case 0, 3, 4, 5, 7, 8, 9, 12, 13, 15, 18: return 8_000
        case 6: return 16_000
        case 10, 11: return 44_100
        case 16: return 11_025
        case 17: return 22_050
        case 25, 26, 28, 31, 32, 33, 34: return 90_000
        default: return nil
        }
    }
}

extension PacketDecoding {
    // MARK: SIP

    mutating func sip(_ o: Int, _ end: Int) {
        var lines: [(String, Int, Int)] = []
        var p = o
        var bodyStart: Int?
        while p < end, lines.count < 120 {
            var q = p
            while q < end, b.u8(q) != 0x0A { q += 1 }
            guard q < end else {
                if q > p { lines.append((String(decoding: b.slice(p, q - p), as: UTF8.self), p, q - p)) }
                break
            }
            let lineEnd = q > p && b.u8(q - 1) == 0x0D ? q - 1 : q
            let line = String(decoding: b.slice(p, lineEnd - p), as: UTF8.self)
            if line.isEmpty { bodyStart = q + 1; break }
            lines.append((line, p, q + 1 - p))
            p = q + 1
        }
        guard let first = lines.first else { data(o, end); return }
        let isResponse = first.0.hasPrefix("SIP/2.0")
        var fields: [PacketField] = []
        var method: String?
        var status: Int?
        var reason = ""
        if isResponse {
            let parts = first.0.split(separator: " ", maxSplits: 2).map(String.init)
            status = parts.count > 1 ? Int(parts[1]) : nil
            reason = parts.count > 2 ? parts[2] : ""
            fields.append(PacketField("Ligne d’état", first.0, first.1, first.2, children: [
                PacketField("Code", status.map { "\($0) (\(Self.sipStatusFamily($0)))" } ?? "?", first.1 + 8, 3),
                PacketField("Raison", reason, first.1, first.2),
            ]))
        } else {
            let parts = first.0.split(separator: " ", maxSplits: 2).map(String.init)
            method = parts.first
            fields.append(PacketField("Ligne de requête", first.0, first.1, first.2, children: [
                PacketField("Méthode", method ?? "?", first.1, method?.utf8.count ?? 0),
                PacketField("URI demandée", parts.count > 1 ? parts[1] : "", first.1, first.2),
            ]))
        }
        var headers: [String: String] = [:]
        var headerFields: [PacketField] = []
        for (line, offset, length) in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { headerFields.append(PacketField("En-tête", line, offset, length)); continue }
            let raw = line[..<colon].trimmingCharacters(in: .whitespaces)
            let name = Self.sipHeaderName(raw)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name.lowercased()] == nil { headers[name.lowercased()] = value }
            headerFields.append(PacketField(name, value, offset, length))
        }
        if !headerFields.isEmpty {
            let start = headerFields[0].offset
            let stop = headerFields.last.map { $0.offset + $0.length } ?? start
            fields.append(PacketField("En-têtes", "\(headerFields.count)", start, stop - start, children: headerFields))
        }
        let callID = headers["call-id"]
        let cseq = headers["cseq"] ?? ""
        let cseqMethod = cseq.split(separator: " ").last.map(String.init) ?? ""
        if let bodyStart, bodyStart < end {
            let type = (headers["content-type"] ?? "").lowercased()
            if type.contains("application/sdp") {
                fields.append(sdp(bodyStart, end))
            } else {
                fields.append(PacketField("Corps", "\(type.isEmpty ? "" : type + ", ")\(PacketText.octets(end - bodyStart))", bodyStart, end - bodyStart))
            }
        } else if bodyStart == nil {
            packet.problems.append("SIP\u{00A0}: en-têtes incomplets (suite dans le segment suivant)")
        }
        add(.sip, isResponse ? "SIP, réponse \(status.map(String.init) ?? "?")" : "SIP, requête \(method ?? "?")", o, end - o, fields)
        packet.sipMethod = method ?? (cseqMethod.isEmpty ? nil : cseqMethod)
        packet.sipStatus = status
        packet.sipCallID = callID
        if isResponse {
            packet.summary = "Réponse\u{00A0}: \(status.map(String.init) ?? "?") \(reason)" + (cseqMethod.isEmpty ? "" : " (\(cseqMethod))")
        } else {
            let uri = first.0.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            packet.summary = "Requête\u{00A0}: \(method ?? "?") \(uri)"
        }
        if let callID {
            packet.summary += " · Call-ID " + (callID.count > 12 ? String(callID.prefix(12)) + "…" : callID)
            // ACK n'a pas de réponse : pas de transaction.
            let requestMethod = method ?? cseqMethod
            if requestMethod != "ACK" {
                let key = "sip|\(callID)|\(cseq)"
                if let status {
                    // 401 et 407 : défi d'authentification, réponse normale qui clôt la requête.
                    let failed = status >= 400 && status != 401 && status != 407
                    packet.transaction = PacketTransaction(kind: .sip, key: key, isRequest: false, label: cseqMethod,
                                                           failure: failed ? "\(status) \(reason)" : nil,
                                                           provisional: status < 200, global: true)
                } else {
                    packet.transaction = PacketTransaction(kind: .sip, key: key, isRequest: true, label: requestMethod, global: true)
                }
            }
        }
    }

    /// Corps SDP : une ligne par champ (« m=audio 16384 RTP/AVP 0 8 101 »).
    func sdp(_ o: Int, _ end: Int) -> PacketField {
        var children: [PacketField] = []
        var media: [String] = []
        var p = o
        while p < end, children.count < 80 {
            var q = p
            while q < end, b.u8(q) != 0x0A { q += 1 }
            let lineEnd = q > p && q <= end && b.u8(q - 1) == 0x0D ? q - 1 : q
            let line = String(decoding: b.slice(p, lineEnd - p), as: UTF8.self)
            if line.count >= 2, line.dropFirst().first == "=" {
                let key = line.first!
                let value = String(line.dropFirst(2))
                children.append(PacketField(Self.sdpName(key, value: value), value, p, min(q + 1, end) - p))
                if key == "m" { media.append(value) }
            }
            p = q + 1
        }
        let summary = media.isEmpty ? PacketText.octets(end - o) : media.joined(separator: " · ")
        return PacketField("Description de session (SDP)", summary, o, end - o, children: children)
    }

    static func sdpName(_ key: Character, value: String) -> String {
        switch key {
        case "v": return "Version"
        case "o": return "Origine"
        case "s": return "Nom de la session"
        case "i": return "Information"
        case "c": return "Connexion"
        case "b": return "Bande passante"
        case "t": return "Durée"
        case "m": return "Média"
        case "a":
            if value.hasPrefix("rtpmap:") { return "Codec (rtpmap)" }
            if value.hasPrefix("fmtp:") { return "Paramètres du codec (fmtp)" }
            if ["sendrecv", "sendonly", "recvonly", "inactive"].contains(value) { return "Sens" }
            if value.hasPrefix("ptime:") { return "Durée de paquet (ptime)" }
            return "Attribut"
        default: return "Champ \(key)"
        }
    }

    /// Nom complet d'un en-tête SIP (formes courtes de RFC 3261, section 7.3.3).
    static func sipHeaderName(_ name: String) -> String {
        switch name.lowercased() {
        case "i": return "Call-ID"
        case "m": return "Contact"
        case "e": return "Content-Encoding"
        case "l": return "Content-Length"
        case "c": return "Content-Type"
        case "f": return "From"
        case "s": return "Subject"
        case "k": return "Supported"
        case "t": return "To"
        case "v": return "Via"
        default: return name
        }
    }

    static func sipStatusFamily(_ code: Int) -> String {
        switch code {
        case 100..<200: return "provisoire"
        case 200..<300: return "succès"
        case 300..<400: return "redirection"
        case 401, 407: return "authentification demandée"
        case 400..<500: return "erreur du client"
        case 500..<600: return "erreur du serveur"
        case 600..<700: return "échec global"
        default: return "inconnu"
        }
    }

    // MARK: RTP

    mutating func rtp(_ o: Int, _ end: Int) {
        let first = b.u8(o), second = b.u8(o + 1)
        let padding = first & 0x20 != 0, hasExtension = first & 0x10 != 0
        let csrcCount = Int(first & 0x0F)
        let marker = second & 0x80 != 0, type = second & 0x7F
        let sequence = b.u16(o + 2), timestamp = b.u32(o + 4), ssrc = b.u32(o + 8)
        var fields = [
            PacketField("Version", "2", o, 1),
            PacketField("Remplissage", padding ? "oui" : "non", o, 1),
            PacketField("Extension", hasExtension ? "oui" : "non", o, 1),
            PacketField("Nombre de CSRC", "\(csrcCount)", o, 1),
            PacketField("Marqueur", marker ? "oui (début d’un mot ou d’une image)" : "non", o + 1, 1),
            PacketField("Type de charge", "\(RTPRecognizer.codecName(type)) (\(type))", o + 1, 1),
            PacketField("Numéro de séquence", "\(sequence)", o + 2, 2),
            PacketField("Horodatage", "\(timestamp)", o + 4, 4),
            PacketField("Source de synchronisation (SSRC)", PacketText.hex(ssrc, digits: 8), o + 8, 4),
        ]
        var p = o + 12
        if csrcCount > 0 {
            var list: [PacketField] = []
            for index in 0..<csrcCount { list.append(PacketField("CSRC \(index + 1)", PacketText.hex(b.u32(p + 4 * index), digits: 8), p + 4 * index, 4)) }
            fields.append(PacketField("Sources contributrices", "\(csrcCount)", p, 4 * csrcCount, children: list))
            p += 4 * csrcCount
        }
        if hasExtension {
            let words = Int(b.u16(p + 2))
            fields.append(PacketField("Extension d’en-tête", "profil \(PacketText.hex(UInt32(b.u16(p)))), \(PacketText.octets(4 + words * 4))", p, 4 + words * 4))
            p += 4 + words * 4
        }
        let padCount = padding ? Int(b.u8(end - 1)) : 0
        let payload = max(0, end - p - padCount)
        if payload > 0 { fields.append(PacketField("Charge utile (\(RTPRecognizer.shortCodec(type)))", PacketText.octets(payload), p, payload)) }
        if padCount > 0 { fields.append(PacketField("Remplissage", PacketText.octets(padCount), end - padCount, padCount)) }
        add(.rtp, "RTP, \(RTPRecognizer.shortCodec(type)), séq. \(sequence)", o, end - o, fields)
        packet.rtp = RTPHeaderInfo(ssrc: ssrc, sequence: sequence, timestamp: timestamp, payloadType: type, marker: marker, payloadLength: payload)
        packet.summary = "PT=\(RTPRecognizer.shortCodec(type)), SSRC=\(PacketText.hex(ssrc, digits: 8)), Séq=\(sequence), Horo=\(timestamp)" + (marker ? ", marqueur" : "")
    }

    // MARK: RTCP

    mutating func rtcp(_ o: Int, _ end: Int) {
        var p = o
        var packets: [PacketField] = []
        var names: [String] = []
        while p + 8 <= end, b.u8(p) >> 6 == 2, packets.count < 8 {
            let count = Int(b.u8(p) & 0x1F), type = b.u8(p + 1)
            let size = (Int(b.u16(p + 2)) + 1) * 4
            let stop = min(end, p + size)
            let name = Self.rtcpTypeName(type)
            names.append(name.short)
            var children = [
                PacketField("Version", "2", p, 1),
                PacketField(type == 202 ? "Nombre de sources" : "Nombre de rapports", "\(count)", p, 1),
                PacketField("Type", "\(name.long) (\(type))", p + 1, 1),
                PacketField("Longueur", "\(b.u16(p + 2)) (\(PacketText.octets(size)))", p + 2, 2),
                PacketField("SSRC de l’émetteur", PacketText.hex(b.u32(p + 4), digits: 8), p + 4, 4),
            ]
            var q = p + 8
            if type == 200, q + 20 <= stop {
                let ntp = PacketDecoding.ntpTime(b.u32(q), b.u32(q + 4))
                children.append(PacketField("Horodatage NTP", PacketDecoding.ntpText(ntp), q, 8))
                children.append(PacketField("Horodatage RTP", "\(b.u32(q + 8))", q + 8, 4))
                children.append(PacketField("Paquets envoyés", "\(b.u32(q + 12))", q + 12, 4))
                children.append(PacketField("Octets envoyés", "\(b.u32(q + 16))", q + 16, 4))
                q += 20
            }
            if type == 200 || type == 201 {
                for index in 0..<count where q + 24 <= stop {
                    let fraction = Double(b.u8(q + 4)) / 256
                    var lost = Int(b.u24(q + 5))
                    if lost & 0x80_0000 != 0 { lost -= 0x100_0000 }
                    let jitter = b.u32(q + 12)
                    packet.rtcpReports.append(RTCPReportBlock(ssrc: b.u32(q), fractionLost: fraction, cumulativeLost: lost, jitter: jitter))
                    children.append(PacketField("Rapport \(index + 1)", "SSRC \(PacketText.hex(b.u32(q), digits: 8)), perte \(Self.percent(fraction))", q, 24, children: [
                        PacketField("SSRC décrit", PacketText.hex(b.u32(q), digits: 8), q, 4),
                        PacketField("Part perdue", Self.percent(fraction), q + 4, 1),
                        PacketField("Paquets perdus (cumul)", "\(lost)", q + 5, 3),
                        PacketField("Plus haut numéro reçu", "\(b.u32(q + 8))", q + 8, 4),
                        PacketField("Gigue d’arrivée", "\(jitter) (unités d’horodatage)", q + 12, 4),
                        PacketField("Dernier SR (LSR)", PacketText.hex(b.u32(q + 16), digits: 8), q + 16, 4),
                        PacketField("Délai depuis le dernier SR (DLSR)", "\(PacketText.seconds(Double(b.u32(q + 20)) / 65_536, decimals: 3))\u{00A0}s", q + 20, 4),
                    ]))
                    q += 24
                }
            } else if type == 202 {
                // SDES : premier élément CNAME lisible.
                var r = p + 8
                while r + 2 <= stop {
                    let item = b.u8(r)
                    if item == 0 { break }
                    let length = Int(b.u8(r + 1))
                    guard r + 2 + length <= stop else { break }
                    children.append(PacketField(Self.sdesName(item), b.text(r + 2, length), r, 2 + length))
                    r += 2 + length
                }
            }
            packets.append(PacketField(name.long, PacketText.octets(size), p, stop - p, children: children))
            if size <= 0 { break }
            p += size
        }
        add(.rtcp, "RTCP, " + names.joined(separator: " + "), o, end - o, packets)
        var summary = names.joined(separator: " + ")
        if let report = packet.rtcpReports.first {
            summary += " · perte \(Self.percent(report.fractionLost)), gigue \(report.jitter)"
        }
        packet.summary = summary
    }

    static func rtcpTypeName(_ type: UInt8) -> (short: String, long: String) {
        switch type {
        case 200: return ("SR", "Rapport d’émetteur (SR)")
        case 201: return ("RR", "Rapport de récepteur (RR)")
        case 202: return ("SDES", "Description de source (SDES)")
        case 203: return ("BYE", "Fin de participation (BYE)")
        case 204: return ("APP", "Application (APP)")
        default: return ("RTCP \(type)", "Type \(type)")
        }
    }

    static func sdesName(_ item: UInt8) -> String {
        switch item {
        case 1: return "CNAME"
        case 2: return "Nom"
        case 3: return "Courriel"
        case 4: return "Téléphone"
        case 5: return "Lieu"
        case 6: return "Outil"
        case 7: return "Note"
        default: return "Élément \(item)"
        }
    }

    /// « 1,6 % ».
    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f", fraction * 100).replacingOccurrences(of: ".", with: ",") + "\u{00A0}%"
    }
}
