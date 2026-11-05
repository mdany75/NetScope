import Foundation

/// Analyse d'un datagramme Syslog (note 43), tolérante comme un vrai serveur Syslog :
/// - RFC 5424 : `<PRI>1 TIMESTAMP HOSTNAME APP PROCID MSGID [SD] MSG` ;
/// - RFC 3164 (BSD) : `<PRI>Mmm jj hh:mm:ss HOSTNAME TAG[pid]: MSG`, nom d'hôte parfois absent ;
/// - FortiOS (format par défaut) : `<PRI>date=… time=… devname="…" logid="…" level="…" msg="…"`,
///   aussi dans le MSG d'un message 5424 ou 3164 ;
/// - mnémonique Cisco (`%LINK-3-UPDOWN:`), qui donne aussi la gravité ;
/// - sans PRI : `user.notice` (RFC 3164, section 4.3.3).
/// Fonctions pures : l'heure de réception, le calendrier et le fuseau sont passés en paramètres.
public enum SyslogParser {
    /// Analyse les octets reçus de `host`.
    public static func parse(_ bytes: [UInt8], from host: String, received: Date,
                             calendar: Calendar = .current) -> LogMessage {
        parse(String(decoding: bytes.prefix(65_536), as: UTF8.self), from: host, received: received, calendar: calendar)
    }

    public static func parse(_ text: String, from host: String, received: Date, calendar: Calendar = .current) -> LogMessage {
        var line = text
        while let last = line.last, last == "\n" || last == "\r" || last == "\0" { line.removeLast() }
        var rest = Substring(line)
        var pri: Int?
        if rest.first == "<", let close = rest.prefix(5).firstIndex(of: ">") {
            let digits = rest[rest.index(after: rest.startIndex)..<close]
            if !digits.isEmpty, digits.allSatisfy(\.isASCII), let value = Int(digits), (0...191).contains(value) {
                pri = value
                rest = rest[rest.index(after: close)...]
            }
        }
        let priority = pri ?? 13
        var message = LogMessage(date: received, received: received, source: .syslog,
                                 severity: LogSeverity(rawValue: priority % 8) ?? .notice, facility: priority / 8,
                                 host: host, message: "", raw: LogMessage.clip(line, LogMessage.rawLimit))
        var body: Substring
        if let version = rest.first, version == "1", rest.dropFirst().first == " " {
            body = parse5424(rest.dropFirst(2), into: &message)
        } else {
            body = parse3164(rest, into: &message, received: received, calendar: calendar)
        }
        body = Substring(body.trimmingCharacters(in: .whitespaces))
        // FortiOS (FortiGate, FortiSwitch, FortiAP) : clé=valeur, dans le corps.
        let pairs = keyValues(body)
        if isFortinet(pairs) {
            applyFortinet(pairs, to: &message, calendar: calendar, explicitPRI: pri != nil)
        } else {
            message.message = LogMessage.clip(String(body), LogMessage.messageLimit)
            applyCisco(to: &message, explicitPRI: pri != nil)
            applyAruba(to: &message)
        }
        if message.message.isEmpty { message.message = "(message vide)" }
        return message
    }

    // MARK: RFC 5424

    /// Lit l'en-tête 5424 ; renvoie le MSG.
    static func parse5424(_ text: Substring, into message: inout LogMessage) -> Substring {
        var rest = text
        func token() -> String? {
            rest = rest.drop { $0 == " " }
            guard !rest.isEmpty else { return nil }
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            let value = String(rest[..<end])
            rest = rest[end...]
            return value == "-" ? nil : value
        }
        if let stamp = token(), let date = isoDate(stamp) { message.date = date }
        message.hostname = token()
        message.app = token()
        if let pid = token() { message.fields["procid"] = pid }
        if let msgid = token() { message.eventID = msgid }
        rest = rest.drop { $0 == " " }
        // Données structurées : « - » ou une suite de [id param="valeur" …].
        if rest.first == "-" {
            rest = rest.dropFirst()
        } else {
            while rest.first == "[" {
                guard let (element, after) = structuredElement(rest) else { break }
                for (key, value) in element { message.fields[key] = value }
                rest = after
            }
        }
        rest = rest.drop { $0 == " " }
        // Indicateur d'ordre des octets UTF-8 (BOM) devant le MSG.
        if rest.first == "\u{FEFF}" { rest = rest.dropFirst() }
        return rest
    }

    /// Un élément `[id clé="valeur" …]` (guillemets, `\"`, `\\` et `\]` échappés).
    static func structuredElement(_ text: Substring) -> ([String: String], Substring)? {
        guard text.first == "[" else { return nil }
        var index = text.index(after: text.startIndex)
        var fields: [String: String] = [:]
        var sdID = ""
        while index < text.endIndex, text[index] != " ", text[index] != "]" {
            sdID.append(text[index])
            index = text.index(after: index)
        }
        while index < text.endIndex {
            let ch = text[index]
            if ch == "]" { return (fields, text[text.index(after: index)...]) }
            if ch == " " {
                index = text.index(after: index)
                continue
            }
            var name = ""
            while index < text.endIndex, text[index] != "=", text[index] != "]", text[index] != " " {
                name.append(text[index])
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index] == "=" else { continue }
            index = text.index(after: index)
            guard index < text.endIndex, text[index] == "\"" else { return nil }
            index = text.index(after: index)
            var value = ""
            while index < text.endIndex, text[index] != "\"" {
                if text[index] == "\\", text.index(after: index) < text.endIndex {
                    index = text.index(after: index)
                }
                value.append(text[index])
                index = text.index(after: index)
            }
            guard index < text.endIndex else { return nil }
            index = text.index(after: index)
            fields[sdID.isEmpty ? name : "\(sdID).\(name)"] = value
        }
        return nil
    }

    static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    // MARK: RFC 3164

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Lit « Mmm jj hh:mm:ss HOSTNAME TAG: » s'il est là ; renvoie le reste.
    static func parse3164(_ text: Substring, into message: inout LogMessage, received: Date, calendar: Calendar) -> Substring {
        var rest = text.drop { $0 == " " }
        // Horodatage BSD (15 caractères : « Nov  4 14:02:07 »), parfois avec millisecondes.
        if rest.count >= 15, let month = months.firstIndex(of: rest.prefix(3).lowercased()) {
            let afterMonth = rest.dropFirst(3).drop { $0 == " " }
            let dayText = afterMonth.prefix { $0.isNumber }
            let afterDay = afterMonth.dropFirst(dayText.count).drop { $0 == " " }
            let clock = afterDay.prefix { $0.isNumber || $0 == ":" || $0 == "." }
            let parts = clock.split(separator: ".")[0].split(separator: ":").compactMap { Int($0) }
            if let day = Int(dayText), parts.count == 3 {
                var c = calendar.dateComponents([.year], from: received)
                c.month = month + 1
                c.day = day
                c.hour = parts[0]
                c.minute = parts[1]
                c.second = parts[2]
                if var date = calendar.date(from: c) {
                    // Pas d'année dans 3164 : un message « du 31 déc. » reçu le 1er janv. est de l'an passé.
                    if date.timeIntervalSince(received) > 86_400, let earlier = calendar.date(byAdding: .year, value: -1, to: date) {
                        date = earlier
                    }
                    message.date = date
                }
                rest = afterDay.dropFirst(clock.count).drop { $0 == " " }
                // Nom d'hôte : premier mot, sauf s'il est déjà l'étiquette (« sshd[42]: ») ou une paire clé=valeur.
                if let space = rest.firstIndex(of: " ") {
                    let word = rest[..<space]
                    if !word.hasSuffix(":"), !word.contains("["), !word.contains("=") {
                        message.hostname = String(word)
                        rest = rest[space...].drop { $0 == " " }
                    }
                }
            }
        }
        // Étiquette « sshd[812]: » ou « CRON: » (au plus 48 caractères, sans espace).
        if let colon = rest.prefix(49).firstIndex(of: ":"), !rest[..<colon].contains(" "), !rest[..<colon].contains("="),
           rest.index(after: colon) == rest.endIndex || rest[rest.index(after: colon)] == " " {
            var tag = String(rest[..<colon])
            if let open = tag.firstIndex(of: "["), tag.hasSuffix("]") {
                message.fields["procid"] = String(tag[tag.index(after: open)..<tag.index(before: tag.endIndex)])
                tag = String(tag[..<open])
            }
            if !tag.isEmpty, tag.allSatisfy(\.isNumber) {
                // Numéro de séquence (Cisco « 123: ») : ni étiquette ni message.
                message.fields["seq"] = tag
                rest = rest[rest.index(after: colon)...].drop { $0 == " " }
            } else if !tag.isEmpty, !tag.hasPrefix("%") {
                message.app = tag
                rest = rest[rest.index(after: colon)...]
            }
        }
        return rest
    }

    // MARK: Cisco

    /// « %LINK-3-UPDOWN: Interface Gi1/0/14, changed state to down » : mnémonique et gravité.
    static func applyCisco(to message: inout LogMessage, explicitPRI: Bool) {
        let text = message.message
        guard let percent = text.firstIndex(of: "%") else { return }
        let after = text[text.index(after: percent)...]
        guard let colon = after.firstIndex(of: ":") else { return }
        let mnemonic = after[..<colon]
        let parts = mnemonic.split(separator: "-")
        guard parts.count >= 3, mnemonic.count <= 64, !mnemonic.contains(" "),
              let level = Int(parts[parts.count - 2]), let severity = LogSeverity(rawValue: level) else { return }
        message.eventID = String(mnemonic)
        if message.app == nil { message.app = String(parts[0]) }
        if !explicitPRI { message.severity = severity }
        let detail = after[after.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if !detail.isEmpty { message.message = LogMessage.clip(detail, LogMessage.messageLimit) }
    }

    // MARK: HPE Aruba

    /// « 00076 ports: port 14 is now off-line » (AOS-S) : numéro d'événement et sous-système.
    static func applyAruba(to message: inout LogMessage) {
        let text = message.message
        let number = text.prefix { $0.isASCII && $0.isNumber }
        guard number.count == 5, message.eventID == nil else { return }
        let after = text.dropFirst(5)
        guard after.first == " ", let colon = after.firstIndex(of: ":") else { return }
        let subsystem = after.dropFirst()[..<colon]
        guard !subsystem.isEmpty, subsystem.count <= 24,
              subsystem.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return }
        message.eventID = String(number)
        if message.app == nil { message.app = String(subsystem) }
        let detail = after[after.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if !detail.isEmpty { message.message = detail }
    }

    // MARK: FortiOS clé=valeur

    /// Paires `clé=valeur` (valeur entre guillemets avec `\"`, ou jusqu'à l'espace). Ordre gardé.
    public static func keyValues(_ text: Substring) -> [(String, String)] {
        var pairs: [(String, String)] = []
        var index = text.startIndex
        func isKeyChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-" || c == ".") }
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            let keyStart = index
            while index < text.endIndex, isKeyChar(text[index]) { index = text.index(after: index) }
            guard index > keyStart, index < text.endIndex, text[index] == "=" else {
                // Mot qui n'est pas une paire : on passe au mot suivant.
                while index < text.endIndex, text[index] != " " { index = text.index(after: index) }
                continue
            }
            let key = String(text[keyStart..<index])
            index = text.index(after: index)
            var value = ""
            if index < text.endIndex, text[index] == "\"" {
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\", text.index(after: index) < text.endIndex { index = text.index(after: index) }
                    value.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                while index < text.endIndex, text[index] != " " {
                    value.append(text[index])
                    index = text.index(after: index)
                }
            }
            pairs.append((key, value))
        }
        return pairs
    }

    static func isFortinet(_ pairs: [(String, String)]) -> Bool {
        let keys = Set(pairs.map { $0.0.lowercased() })
        return keys.contains("logid") || (keys.contains("devname") && (keys.contains("level") || keys.contains("msg")))
    }

    static func applyFortinet(_ pairs: [(String, String)], to message: inout LogMessage, calendar: Calendar, explicitPRI: Bool) {
        var fields: [String: String] = message.fields
        for (key, value) in pairs where fields[key] == nil { fields[key] = value }
        let level = fields["level"].flatMap(LogSeverity.init(text:))
        if let level { message.severity = level }
        if let name = fields["devname"], !name.isEmpty { message.hostname = name }
        let type = [fields["type"], fields["subtype"]].compactMap { $0 }.filter { !$0.isEmpty }
        message.app = "FortiOS" + (type.isEmpty ? "" : " · " + type.joined(separator: " · "))
        if let logid = fields["logid"], !logid.isEmpty { message.eventID = logid }
        let text = [fields["msg"], fields["logdesc"], fields["action"]].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        var detail = text
        if let desc = fields["logdesc"], !desc.isEmpty, let msg = fields["msg"], !msg.isEmpty, !msg.localizedCaseInsensitiveContains(desc) {
            detail = desc + "\u{00A0}: " + msg
        }
        message.message = LogMessage.clip(detail, LogMessage.messageLimit)
        if let date = fortinetDate(fields, calendar: calendar) { message.date = date }
        message.fields = fields
    }

    /// Heure FortiOS : `eventtime` (secondes, millisecondes, microsecondes ou nanosecondes selon la
    /// version), sinon `date` + `time` (+ `tz` « -0500 »).
    public static func fortinetDate(_ fields: [String: String], calendar: Calendar) -> Date? {
        if let text = fields["eventtime"], let value = Double(text), value > 0 {
            var seconds = value
            while seconds > 1e11 { seconds /= 1000 }
            if seconds > 946_684_800 { return Date(timeIntervalSince1970: seconds) }
        }
        guard let day = fields["date"], let clock = fields["time"] else { return nil }
        let d = day.split(separator: "-").compactMap { Int($0) }
        let t = clock.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count >= 2 else { return nil }
        var c = DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1], second: t.count > 2 ? t[2] : 0)
        var cal = calendar
        if let tz = fields["tz"].flatMap(timeZone) { cal.timeZone = tz }
        c.calendar = cal
        return cal.date(from: c)
    }

    /// « -0500 », « +01:00 », « UTC ».
    static func timeZone(_ text: String) -> TimeZone? {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if t.uppercased() == "UTC" || t.uppercased() == "GMT" { return TimeZone(secondsFromGMT: 0) }
        guard let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let digits = t.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    // MARK: Encodage (message d'essai envoyé à soi-même)

    /// Message 5424 d'essai : `<PRI>1 TIMESTAMP HOSTNAME APP - MSGID - MSG`.
    public static func encode5424(severity: LogSeverity, facility: Int = 16, date: Date, hostname: String, app: String,
                                  msgID: String? = nil, message: String) -> [UInt8] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let pri = facility * 8 + severity.rawValue
        let head = "<\(pri)>1 \(formatter.string(from: date)) \(hostname) \(app) - \(msgID ?? "-") - "
        return Array(head.utf8) + [0xEF, 0xBB, 0xBF] + Array(message.utf8)
    }
}
