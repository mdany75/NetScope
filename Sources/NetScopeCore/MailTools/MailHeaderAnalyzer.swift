import Foundation

// Analyse d'en-têtes de courriel (note 14) : tout se fait en local, rien n'est envoyé.
// Dépliage des lignes, trajet (chaque « Received » avec horodatage et délai), de/par/avec, IP
// d'origine, Authentication-Results (SPF, DKIM, DMARC) tels que lus dans le message,
// Return-Path et From, Reply-To, alertes d'usurpation (domaine sosie, nom affiché trompeur,
// échec DMARC), Message-ID, X-Mailer.

// MARK: - Modèle

/// Un champ d'en-tête déplié.
public struct MailHeaderField: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Une adresse : nom affiché et adresse (« Service PayPal <service@paypal.com> »).
public struct MailAddress: Hashable, Sendable {
    public var displayName: String?
    public var address: String

    public init(displayName: String?, address: String) {
        self.displayName = displayName
        self.address = address
    }

    /// Partie après l'arobase, en minuscules.
    public var domain: String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return address[address.index(after: at)...].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".>"))
    }

    public var text: String {
        guard let displayName, !displayName.isEmpty else { return address }
        return "\(displayName) <\(address)>"
    }
}

/// Un saut du trajet (en-tête « Received »), du plus ancien au plus récent.
public struct MailHop: Identifiable, Hashable, Sendable {
    /// 1 = premier serveur (le plus ancien).
    public var id: Int
    public var from: String?
    public var fromIP: String?
    public var by: String?
    public var with: String?
    public var date: Date?
    public var dateText: String?
    /// Secondes depuis le saut précédent (négatif : horloges décalées).
    public var delay: TimeInterval?
    public var raw: String

    /// Transport chiffré annoncé (ESMTPS, version=TLS…).
    public var isEncrypted: Bool {
        let protocolName = (with ?? "").uppercased()
        return protocolName.contains("ESMTPS") || protocolName.contains("SMTPS") || protocolName.contains("TLS")
            || raw.range(of: "version=TLS", options: .caseInsensitive) != nil
    }

    /// Envoi authentifié (ESMTPA, ESMTPSA) ou webmail (HTTP).
    public var isSubmission: Bool {
        let protocolName = (with ?? "").uppercased()
        return protocolName.hasSuffix("A") && protocolName.contains("SMTP") || protocolName.hasPrefix("HTTP")
    }
}

/// Un résultat d'authentification lu dans Authentication-Results (« dkim=pass header.d=exemple.ca »).
public struct MailAuthResult: Identifiable, Hashable, Sendable {
    public var id: Int
    /// « spf », « dkim », « dmarc », « arc », « compauth »…
    public var method: String
    /// « pass », « fail », « softfail », « none »…
    public var result: String
    /// Propriétés (« smtp.mailfrom », « header.d », « header.from », « header.s »…).
    public var properties: [String: String]
    /// Serveur qui a vérifié (authserv-id).
    public var authority: String?

    public var isPass: Bool { result == "pass" || result == "bestguesspass" }
    public var isFail: Bool { ["fail", "softfail", "permerror", "hardfail"].contains(result) }

    /// « header.d=exemple.ca », « smtp.mailfrom=bounces.exemple.ca ».
    public var detail: String {
        let order = ["header.from", "header.d", "header.i", "header.s", "smtp.mailfrom", "smtp.helo", "policy.dmarc", "action", "reason"]
        let keys = properties.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        return keys.map { "\($0)=\(properties[$0] ?? "")" }.joined(separator: " ")
    }
}

/// Constat de l'analyse (même forme que le diagnostic SMTP).
public typealias MailFinding = SMTPFinding

/// Résultat de l'analyse d'en-têtes.
public struct MailHeaderReport: Sendable {
    public var fields: [MailHeaderField]
    public var hops: [MailHop]
    public var auth: [MailAuthResult]
    public var from: MailAddress?
    public var sender: MailAddress?
    public var replyTo: MailAddress?
    public var returnPath: String?
    public var to: String?
    public var subject: String?
    public var date: Date?
    public var dateText: String?
    public var messageID: String?
    public var mailer: String?
    public var originIP: String?
    /// Domaine et sélecteur des signatures DKIM-Signature (« exemple.ca / s1 »).
    public var dkimSignatures: [(domain: String, selector: String)]
    public var findings: [MailFinding]

    /// Durée totale du trajet (premier au dernier saut daté).
    public var transit: TimeInterval? {
        let dates = hops.compactMap(\.date)
        guard let first = dates.first, let last = dates.last, dates.count >= 2 else { return nil }
        return last.timeIntervalSince(first)
    }

    public var verdict: MailFinding.Level { findings.map(\.level).max() ?? .ok }

    public func result(_ method: String) -> MailAuthResult? { auth.first { $0.method == method } }

    /// Domaine de l'enveloppe (Return-Path), sans chevrons.
    public var envelopeDomain: String? {
        guard let returnPath else { return nil }
        let address = MailAddress(displayName: nil, address: returnPath)
        return address.domain.isEmpty ? nil : address.domain
    }
}

// MARK: - Analyse

public enum MailHeaderAnalyzer {
    public static func analyze(_ text: String, now: Date = Date()) -> MailHeaderReport {
        let fields = unfold(text)
        func values(_ name: String) -> [String] { fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value) }
        func value(_ name: String) -> String? { values(name).first }

        // Trajet : les « Received » sont ajoutés en tête, le plus ancien est donc le dernier.
        var hops = values("Received").reversed().enumerated().map { index, raw in parseReceived(raw, index: index + 1) }
        for index in hops.indices.dropFirst() {
            if let date = hops[index].date, let previous = hops[index - 1].date {
                hops[index].delay = date.timeIntervalSince(previous)
            }
        }

        let from = value("From").flatMap(parseAddress)
        let sender = value("Sender").flatMap(parseAddress)
        let replyTo = value("Reply-To").flatMap(parseAddress)
        let returnPath = value("Return-Path").map { raw -> String in
            raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        let auth = authenticationResults(fields)
        let dkimSignatures: [(domain: String, selector: String)] = values("DKIM-Signature").compactMap { raw in
            let tags = tagList(raw)
            guard let domain = tags["d"] else { return nil }
            return (domain.lowercased(), tags["s"] ?? "")
        }
        let originIP = hops.first { $0.fromIP.map(isPublicIP) ?? false }?.fromIP
            ?? (value("X-Originating-IP") ?? value("X-Sender-IP")).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) }
        let dateText = value("Date")
        var report = MailHeaderReport(
            fields: fields, hops: hops, auth: auth, from: from, sender: sender, replyTo: replyTo, returnPath: returnPath,
            to: value("To").map(decodeEncodedWords), subject: value("Subject").map(decodeEncodedWords),
            date: dateText.flatMap(parseDate), dateText: dateText, messageID: value("Message-ID") ?? value("Message-Id"),
            mailer: value("X-Mailer") ?? value("User-Agent"), originIP: originIP, dkimSignatures: dkimSignatures, findings: [])
        report.findings = findings(report, now: now)
        return report
    }

    // MARK: Dépliage

    /// Champs dépliés (RFC 5322 § 2.2.3) jusqu'à la première ligne vide (début du corps).
    public static func unfold(_ text: String) -> [MailHeaderField] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        // Première ligne « From exp@… date » d'une boîte mbox.
        if let first = lines.first, first.hasPrefix("From "), !first.hasPrefix("From:") { lines.removeFirst() }
        // Lignes vides en tête (copier-coller) ignorées.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        var fields: [MailHeaderField] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if let first = line.first, first == " " || first == "\t" {
                guard !fields.isEmpty else { continue }
                let piece = line.trimmingCharacters(in: .whitespaces)
                fields[fields.count - 1].value += fields[fields.count - 1].value.isEmpty ? piece : " " + piece
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(" ") else { continue }
            fields.append(MailHeaderField(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return fields
    }

    // MARK: Received

    static func parseReceived(_ raw: String, index: Int) -> MailHop {
        var body = raw
        var dateText: String?
        if let semicolon = raw.lastIndex(of: ";") {
            body = String(raw[..<semicolon])
            dateText = raw[raw.index(after: semicolon)...].trimmingCharacters(in: .whitespaces)
        }
        var clauses: [String: String] = [:]
        var current: String?
        var depth = 0
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let lowered = word.lowercased()
            if depth == 0, ["from", "by", "via", "with", "id", "for"].contains(lowered), clauses[lowered] == nil {
                current = lowered
                clauses[lowered] = ""
            } else if let current {
                clauses[current, default: ""] += (clauses[current]?.isEmpty ?? true ? "" : " ") + word
            }
            word = ""
        }
        for character in body {
            switch character {
            case "(":
                if depth == 0 { flush() }
                depth += 1
                word.append(character)
            case ")":
                depth = max(0, depth - 1)
                word.append(character)
                if depth == 0 { flush() }
            case " ", "\t":
                if depth == 0 { flush() } else { word.append(character) }
            default:
                word.append(character)
            }
        }
        flush()
        func head(_ key: String) -> String? {
            guard let text = clauses[key], let first = text.split(separator: " ").first else { return nil }
            let value = String(first).trimmingCharacters(in: CharacterSet(charactersIn: "<>;"))
            return value.hasPrefix("(") ? nil : value
        }
        let fromText = clauses["from"] ?? ""
        return MailHop(id: index, from: head("from"), fromIP: firstIP(in: fromText), by: head("by"), with: head("with"),
                       date: dateText.flatMap(parseDate), dateText: dateText, delay: nil, raw: raw)
    }

    /// Adresse IP de la clause « from » : celle vue par le serveur (entre parenthèses) prime sur
    /// celle annoncée par HELO ; entre crochets (« [203.0.113.5] », « [IPv6:2001:db8::1] »),
    /// sinon une IPv4 nue.
    static func firstIP(in text: String) -> String? {
        if let range = text.range(of: #"\([^()]*\)"#, options: .regularExpression), let ip = bracketIP(in: String(text[range])) {
            return ip
        }
        if let ip = bracketIP(in: text) { return ip }
        if let range = text.range(of: #"\b(\d{1,3}\.){3}\d{1,3}\b"#, options: .regularExpression),
           IPv4Address(String(text[range])) != nil {
            return String(text[range])
        }
        return nil
    }

    static func bracketIP(in text: String) -> String? {
        guard let range = text.range(of: #"\[(IPv6:)?[0-9A-Fa-f:.]+\]"#, options: .regularExpression) else { return nil }
        var ip = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ip.lowercased().hasPrefix("ipv6:") { ip = String(ip.dropFirst(5)) }
        return IPv4Address(ip) != nil || ip.contains(":") ? ip : nil
    }

    static func isPublicIP(_ text: String) -> Bool {
        if let ip = IPv4Address(text) {
            let o = ip.octets
            if o.0 == 10 || o.0 == 127 || o.0 == 0 { return false }
            if o.0 == 172 && (16...31).contains(o.1) { return false }
            if o.0 == 192 && o.1 == 168 { return false }
            if o.0 == 169 && o.1 == 254 { return false }
            if o.0 == 100 && (64...127).contains(o.1) { return false }
            return true
        }
        let lowered = text.lowercased()
        return lowered.contains(":") && lowered != "::1" && !lowered.hasPrefix("fe80") && !lowered.hasPrefix("fc") && !lowered.hasPrefix("fd")
    }

    // MARK: Dates

    private static let dateFormatters: [DateFormatter] = {
        ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz",
         "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yy HH:mm:ss Z", "EEE d MMM yyyy HH:mm:ss Z"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            return formatter
        }
    }()
    private static let dateLock = NSLock()

    /// Date RFC 5322 (« Tue, 3 Nov 2026 14:02:11 -0500 (EST) »).
    public static func parseDate(_ text: String) -> Date? {
        var cleaned = text.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        cleaned = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        cleaned = cleaned.replacingOccurrences(of: " -0000", with: " +0000")
        guard !cleaned.isEmpty else { return nil }
        dateLock.lock()
        defer { dateLock.unlock() }
        for formatter in dateFormatters {
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    // MARK: Adresses

    /// « "Nom" <a@b.c> », « Nom <a@b.c> », « a@b.c (Nom) », « a@b.c ».
    public static func parseAddress(_ raw: String) -> MailAddress? {
        let text = decodeEncodedWords(raw).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            let address = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = text[..<open].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            name = name.replacingOccurrences(of: "\\\"", with: "\"")
            return MailAddress(displayName: name.isEmpty ? nil : name, address: address)
        }
        var address = text
        var name: String?
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            name = String(text[text.index(after: open)..<close])
            address = text[..<open].trimmingCharacters(in: .whitespaces)
        }
        return MailAddress(displayName: name, address: address)
    }

    /// Mots encodés RFC 2047 (« =?UTF-8?B?…?= », « =?iso-8859-1?Q?…?= »).
    public static func decodeEncodedWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        var previousWasEncoded = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: last, length: match.range.location - last))
            // Les blancs entre deux mots encodés sont ignorés (RFC 2047 § 6.2).
            if !(previousWasEncoded && between.trimmingCharacters(in: .whitespaces).isEmpty) { result += between }
            let charset = ns.substring(with: match.range(at: 1)).lowercased()
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            var data: Data?
            if mode == "B" {
                var padded = payload
                while padded.count % 4 != 0 { padded += "=" }
                data = Data(base64Encoded: padded)
            } else {
                var bytes: [UInt8] = []
                var chars = Array(payload.utf8)[...]
                while let c = chars.popFirst() {
                    if c == UInt8(ascii: "_") { bytes.append(0x20) }
                    else if c == UInt8(ascii: "="), chars.count >= 2,
                            let v = UInt8(String(decoding: chars.prefix(2), as: UTF8.self), radix: 16) {
                        bytes.append(v)
                        chars = chars.dropFirst(2)
                    } else { bytes.append(c) }
                }
                data = Data(bytes)
            }
            let encoding: String.Encoding = charset.hasPrefix("utf-8") || charset == "utf8" ? .utf8
                : (charset.contains("8859-1") || charset.contains("1252") || charset.contains("latin1") ? .isoLatin1 : .utf8)
            if let data, let decoded = String(data: data, encoding: encoding) {
                result += decoded
            } else {
                result += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
            previousWasEncoded = true
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: Authentication-Results

    static let knownMethods: Set<String> = ["spf", "dkim", "dmarc", "arc", "compauth", "bimi", "iprev", "auth", "dkim-atps", "x-dkim"]

    /// Résultats du premier serveur vérificateur (l'en-tête le plus haut : celui ajouté par le
    /// destinataire). Les en-têtes plus bas peuvent venir de l'expéditeur et ne sont pas crus.
    /// À défaut, Received-SPF donne au moins le résultat SPF.
    public static func authenticationResults(_ fields: [MailHeaderField]) -> [MailAuthResult] {
        let headers = fields.filter { $0.name.caseInsensitiveCompare("Authentication-Results") == .orderedSame }.map(\.value)
        var results: [MailAuthResult] = []
        var trusted: (authority: String?, set: Bool) = (nil, false)
        for header in headers {
            let parsed = parseAuthenticationResults(header)
            if !trusted.set { trusted = (parsed.authority, true) }
            guard parsed.authority == trusted.authority else { continue }
            for item in parsed.results where !results.contains(where: { $0.method == item.method && $0.properties == item.properties }) {
                var copy = item
                copy.id = results.count
                results.append(copy)
            }
        }
        if !results.contains(where: { $0.method == "spf" }),
           let received = fields.first(where: { $0.name.caseInsensitiveCompare("Received-SPF") == .orderedSame })?.value,
           let word = received.split(separator: " ").first {
            var properties: [String: String] = [:]
            let tags = tagList(received.replacingOccurrences(of: " ", with: ";"))
            if let mailfrom = tags["envelope-from"] { properties["smtp.mailfrom"] = mailfrom }
            results.append(MailAuthResult(id: results.count, method: "spf", result: word.lowercased(), properties: properties,
                                          authority: "Received-SPF"))
        }
        return results
    }

    static func parseAuthenticationResults(_ value: String) -> (authority: String?, results: [MailAuthResult]) {
        // Commentaires entre parenthèses retirés ; découpage au point-virgule hors guillemets.
        let withoutComments = value.replacingOccurrences(of: #"\([^()]*\)"#, with: " ", options: .regularExpression)
        var segments: [String] = []
        var current = ""
        var quoted = false
        for character in withoutComments {
            if character == "\"" { quoted.toggle() }
            if character == ";" && !quoted {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)
        segments = segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var authority: String?
        if let first = segments.first {
            let token = first.split(separator: " ").first.map(String.init) ?? ""
            let method = token.split(separator: "=").first.map { $0.lowercased() } ?? ""
            if !(token.contains("=") && knownMethods.contains(method)) {
                // Premier segment : authserv-id (et éventuellement une version).
                authority = token.lowercased()
                let rest = first.split(separator: " ").dropFirst().joined(separator: " ")
                segments[0] = rest
            }
        }
        var results: [MailAuthResult] = []
        for segment in segments {
            let tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = tokens.first, let equal = head.firstIndex(of: "=") else { continue }
            let method = head[..<equal].lowercased()
            guard knownMethods.contains(method) || method.hasPrefix("x-") else { continue }
            var result = head[head.index(after: equal)...].lowercased()
            if result.hasSuffix(",") { result.removeLast() }
            var properties: [String: String] = [:]
            for token in tokens.dropFirst() {
                guard let eq = token.firstIndex(of: "=") else { continue }
                let key = token[..<eq].lowercased()
                let value = token[token.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\";,"))
                if properties[key] == nil { properties[key] = value }
            }
            results.append(MailAuthResult(id: results.count, method: method, result: result, properties: properties, authority: authority))
        }
        return (authority, results)
    }

    /// Liste « clé=valeur; » (DKIM-Signature, Received-SPF).
    static func tagList(_ text: String) -> [String: String] {
        var tags: [String: String] = [:]
        for part in text.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if tags[key] == nil { tags[key] = value }
        }
        return tags
    }

    // MARK: Domaines

    /// Suffixes à deux étiquettes : le domaine « organisationnel » en garde trois.
    static let twoLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "com.br", "com.mx", "co.za",
        "com.cn", "com.tr", "co.in", "gc.ca", "qc.ca", "on.ca", "bc.ca", "ab.ca", "mb.ca", "sk.ca", "ns.ca", "nb.ca",
        "nl.ca", "pe.ca", "yk.ca", "nt.ca", "nu.ca", "gouv.fr",
    ]

    /// « bounces.mail.exemple.ca » → « exemple.ca » (approximation sans la liste publique complète).
    public static func organizationalDomain(_ domain: String) -> String {
        let labels = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return twoLevelSuffixes.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    /// Marques souvent imitées : (nom normalisé, domaines officiels).
    static let brands: [(name: String, domains: [String])] = [
        ("paypal", ["paypal.com", "paypal.ca"]), ("apple", ["apple.com", "icloud.com"]), ("microsoft", ["microsoft.com", "outlook.com", "office.com", "live.com"]),
        ("office365", ["microsoft.com", "office.com"]), ("outlook", ["outlook.com", "microsoft.com"]), ("google", ["google.com", "gmail.com"]),
        ("gmail", ["gmail.com", "google.com"]), ("amazon", ["amazon.com", "amazon.ca"]), ("netflix", ["netflix.com"]),
        ("facebook", ["facebook.com", "facebookmail.com", "meta.com"]), ("instagram", ["instagram.com"]), ("linkedin", ["linkedin.com"]),
        ("desjardins", ["desjardins.com"]), ("scotiabank", ["scotiabank.com"]), ("hydroquebec", ["hydroquebec.com"]),
        ("postescanada", ["postescanada.ca", "canadapost.ca"]), ("canadapost", ["canadapost.ca", "postescanada.ca"]),
        ("purolator", ["purolator.com"]), ("fedex", ["fedex.com"]), ("interac", ["interac.ca"]), ("revenuquebec", ["revenuquebec.ca"]),
        ("docusign", ["docusign.com", "docusign.net"]), ("dropbox", ["dropbox.com"]), ("adobe", ["adobe.com"]),
        ("wetransfer", ["wetransfer.com"]), ("rbc", ["rbc.com", "rbcroyalbank.com"]), ("bmo", ["bmo.com"]), ("cibc", ["cibc.com"]),
        ("td", ["td.com", "tdbank.com"]), ("bnc", ["bnc.ca"]), ("dhl", ["dhl.com"]), ("ups", ["ups.com"]),
    ]

    /// Remplace les caractères souvent substitués (0→o, 1→l, rn→m, vv→w…).
    public static func normalizeLookalike(_ text: String) -> String {
        var value = text.lowercased()
        for (from, to) in [("rn", "m"), ("vv", "w"), ("0", "o"), ("1", "l"), ("3", "e"), ("4", "a"), ("5", "s"), ("7", "t"), ("8", "b"), ("|", "l")] {
            value = value.replacingOccurrences(of: from, with: to)
        }
        return value
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }

    /// Marque imitée par `domain` (« paypa1-secure.com » → « paypal »), ou nil.
    public static func imitatedBrand(_ domain: String) -> (name: String, official: String)? {
        let organizational = organizationalDomain(domain)
        let label = organizational.split(separator: ".").first.map(String.init) ?? ""
        guard !label.isEmpty else { return nil }
        let tokens = [label.replacingOccurrences(of: "-", with: "")] + label.split(separator: "-").map(String.init)
        for brand in brands {
            if brand.domains.contains(where: { organizational == $0 || domain.hasSuffix("." + $0) }) { return nil }
        }
        // Les sigles courts (TD, RBC, UPS…) donneraient trop de fausses alertes.
        for brand in brands where brand.name.count >= 4 {
            for token in tokens {
                let normalized = normalizeLookalike(token)
                let looksLike = normalized == brand.name
                    || (brand.name.count >= 5 && token != brand.name && distance(normalized, brand.name) == 1)
                    || (brand.name.count >= 5 && label.split(separator: "-").count > 1 && token == brand.name)
                if looksLike { return (brand.name, brand.domains[0]) }
            }
        }
        return nil
    }

    /// Deux domaines différents mais presque identiques (« exemple.ca » et « exernple.ca »).
    public static func areLookalikes(_ a: String, _ b: String) -> Bool {
        let oa = organizationalDomain(a), ob = organizationalDomain(b)
        guard oa != ob, !oa.isEmpty, !ob.isEmpty else { return false }
        let la = oa.split(separator: ".").first.map(String.init) ?? "", lb = ob.split(separator: ".").first.map(String.init) ?? ""
        if normalizeLookalike(la) == normalizeLookalike(lb) { return true }
        return min(la.count, lb.count) >= 5 && distance(normalizeLookalike(la), normalizeLookalike(lb)) <= 1
    }

    // MARK: Constats

    static func findings(_ report: MailHeaderReport, now: Date) -> [MailFinding] {
        var list: [MailFinding] = []
        let fromDomain = report.from?.domain ?? ""
        let fromOrg = organizationalDomain(fromDomain)

        if report.from == nil {
            list.append(MailFinding(.warning, "Aucun champ From", "Le message n’indique pas d’expéditeur."))
        }
        if report.hops.isEmpty {
            list.append(MailFinding(.info, "Aucun en-tête Received",
                                    "Coller les en-têtes complets (dans Mail\u{00A0}: Présentation › Message › Toutes les en-têtes)."))
        }

        // Authentification lue dans le message
        let dmarc = report.result("dmarc"), spf = report.result("spf"), dkim = report.result("dkim")
        if let dmarc {
            if dmarc.isPass {
                list.append(MailFinding(.ok, "DMARC réussi", "Le domaine « \(dmarc.properties["header.from"] ?? fromDomain) » reconnaît ce message."))
            } else if dmarc.isFail {
                list.append(MailFinding(.critical, "DMARC en échec",
                                        "Le domaine de l’expéditeur (« \(dmarc.properties["header.from"] ?? fromDomain) ») ne reconnaît pas ce message\u{00A0}: usurpation probable."))
            } else {
                list.append(MailFinding(.info, "DMARC\u{00A0}: \(dmarc.result)", "Aucune politique DMARC n’a pu confirmer l’expéditeur."))
            }
        } else if report.auth.isEmpty {
            list.append(MailFinding(.info, "Aucun résultat d’authentification",
                                    "Pas d’en-tête Authentication-Results\u{00A0}: SPF, DKIM et DMARC n’ont pas été notés par le destinataire."))
        }
        if let spf {
            if spf.result == "fail" {
                list.append(MailFinding(.warning, "SPF en échec", "Le serveur d’envoi n’est pas autorisé par le domaine de l’enveloppe."))
            } else if spf.result == "softfail" {
                list.append(MailFinding(.warning, "SPF douteux (softfail)", "Le domaine de l’enveloppe ne garantit pas ce serveur d’envoi."))
            } else if spf.isPass {
                list.append(MailFinding(.ok, "SPF réussi", spf.properties["smtp.mailfrom"].map { "Enveloppe\u{00A0}: \($0)" } ?? ""))
            }
        }
        if let dkim {
            if dkim.isPass {
                let signer = dkim.properties["header.d"] ?? dkim.properties["header.i"] ?? ""
                list.append(MailFinding(.ok, "Signature DKIM valide", signer.isEmpty ? "" : "Signé par « \(signer) »."))
                if !signer.isEmpty, !fromOrg.isEmpty, organizationalDomain(signer.replacingOccurrences(of: "@", with: "")) != fromOrg {
                    list.append(MailFinding(.info, "Signé par un autre domaine que l’expéditeur", "Signature\u{00A0}: « \(signer) » · From\u{00A0}: « \(fromDomain) »."))
                }
            } else if dkim.isFail || dkim.result == "neutral" {
                list.append(MailFinding(.warning, "Signature DKIM invalide", "Le message a pu être modifié en route, ou la signature est fausse."))
            }
        }

        // Enveloppe et réponses
        if let envelope = report.envelopeDomain, !fromOrg.isEmpty, organizationalDomain(envelope) != fromOrg {
            let dmarcPass = dmarc?.isPass ?? false
            list.append(MailFinding(dmarcPass ? .info : .warning, "Enveloppe (Return-Path) ≠ From",
                                    "Return-Path\u{00A0}: « \(envelope) » · From\u{00A0}: « \(fromDomain) »."
                                    + (dmarcPass ? " Courant pour les envois de masse (DMARC réussi)." : "")))
        }
        if let replyTo = report.replyTo, !replyTo.domain.isEmpty, !fromOrg.isEmpty, organizationalDomain(replyTo.domain) != fromOrg {
            list.append(MailFinding(.warning, "Reply-To vers un autre domaine",
                                    "Les réponses iront à « \(replyTo.address) », pas à « \(report.from?.address ?? "") »."))
        }
        if let sender = report.sender, !sender.domain.isEmpty, !fromOrg.isEmpty, organizationalDomain(sender.domain) != fromOrg {
            list.append(MailFinding(.info, "Sender différent de From", "Envoyé par « \(sender.address) » au nom de « \(report.from?.address ?? "") »."))
        }

        // Usurpation : domaine sosie, nom affiché trompeur
        if !fromDomain.isEmpty {
            if let brand = imitatedBrand(fromDomain) {
                list.append(MailFinding(.critical, "Domaine sosie", "« \(fromDomain) » imite « \(brand.official) »."))
            }
            if fromDomain.contains("xn--") {
                list.append(MailFinding(.warning, "Domaine internationalisé (punycode)",
                                        "« \(fromDomain) » peut contenir des lettres d’un autre alphabet qui imitent un domaine connu."))
            }
            var others: [(String, String)] = []
            if let envelope = report.envelopeDomain { others.append(("Return-Path", envelope)) }
            if let replyTo = report.replyTo?.domain, !replyTo.isEmpty { others.append(("Reply-To", replyTo)) }
            for signature in report.dkimSignatures { others.append(("signature DKIM", signature.domain)) }
            for address in (report.to ?? "").split(separator: ",").compactMap({ parseAddress(String($0)) }) where !address.domain.isEmpty {
                others.append(("destinataire", address.domain))
            }
            if let match = others.first(where: { areLookalikes(fromDomain, $0.1) }) {
                list.append(MailFinding(.critical, "Domaines presque identiques",
                                        "From\u{00A0}: « \(fromDomain) » et \(match.0)\u{00A0}: « \(match.1) »."))
            }
            if let name = report.from?.displayName {
                if let embedded = name.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) {
                    let address = MailAddress(displayName: nil, address: String(name[embedded]))
                    if organizationalDomain(address.domain) != fromOrg {
                        list.append(MailFinding(.critical, "Nom affiché trompeur",
                                                "Le nom affiché montre « \(address.address) », mais le message vient de « \(report.from?.address ?? "") »."))
                    }
                } else {
                    let compact = normalizeLookalike(name.lowercased().filter { $0.isLetter || $0.isNumber })
                    if let brand = brands.first(where: { $0.name.count >= 5 && compact.contains($0.name) }),
                       !brand.domains.contains(where: { organizationalDomain($0) == fromOrg }) {
                        list.append(MailFinding(.warning, "Nom affiché d’une marque, autre domaine",
                                                "« \(name) » écrit depuis « \(fromDomain) »."))
                    }
                }
            }
        }

        // Message-ID, logiciel, dates
        if let messageID = report.messageID {
            let domain = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).split(separator: "@").last.map(String.init) ?? ""
            if !domain.isEmpty, !fromOrg.isEmpty, domain.contains("."), organizationalDomain(domain) != fromOrg {
                list.append(MailFinding(.info, "Message-ID d’un autre domaine", "« \(domain) » (souvent le service d’envoi)."))
            }
        } else {
            list.append(MailFinding(.info, "Aucun Message-ID", "Les messages légitimes en ont presque toujours un."))
        }
        if let mailer = report.mailer, mailer.range(of: "phpmailer|swiftmailer|mass mailer|sendblaster|atomic mail", options: [.regularExpression, .caseInsensitive]) != nil {
            list.append(MailFinding(.info, "Envoyé par un script (\(mailer.split(separator: " ").first ?? ""))",
                                    "Logiciel d’envoi automatique, fréquent dans les campagnes d’hameçonnage."))
        }
        if report.hops.contains(where: { ($0.delay ?? 0) < -60 }) {
            list.append(MailFinding(.info, "Horloges décalées", "Un saut est daté avant le précédent."))
        }
        if let transit = report.transit, transit > 3600 {
            list.append(MailFinding(.info, "Long délai de transit", "Le message a mis \(Self.duration(transit)) à arriver."))
        }
        if let date = report.date {
            let reference = report.hops.last?.date ?? now
            if date.timeIntervalSince(reference) > 3600 {
                list.append(MailFinding(.warning, "Date dans le futur", "Le champ Date est postérieur à la réception."))
            }
        }
        return list.sorted { $0.level > $1.level }
    }

    /// « 2 s », « 4 min 12 s », « 3 h 05 ».
    public static func duration(_ seconds: TimeInterval) -> String {
        let value = Int(abs(seconds).rounded())
        let sign = seconds < 0 ? "−" : ""
        if value < 60 { return "\(sign)\(value)\u{00A0}s" }
        if value < 3600 { return "\(sign)\(value / 60)\u{00A0}min" + (value % 60 == 0 ? "" : " \(value % 60)\u{00A0}s") }
        return "\(sign)\(value / 3600)\u{00A0}h\u{00A0}" + String(format: "%02d", (value % 3600) / 60)
    }
}
