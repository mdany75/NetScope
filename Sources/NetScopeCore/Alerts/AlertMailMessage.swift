import Foundation

// Construction d'un courriel d'alerte (RFC 5322 et MIME) : en-têtes Date, Message-ID, From, To,
// Subject encodé en UTF-8 (RFC 2047), corps texte et HTML (multipart/alternative) encodés en
// quoted-printable ou en base64, lignes terminées par CRLF. Le point doublé (RFC 5321 §4.5.2)
// est appliqué au moment de DATA par `SMTPDotStuffing`.

/// Un courriel prêt à envoyer.
public struct AlertMailMessage: Sendable, Equatable {
    public var from: String
    public var fromName: String
    public var to: [String]
    public var subject: String
    public var textBody: String
    public var htmlBody: String?
    public var date: Date
    public var messageID: String
    public var encoding: AlertMailEncoding
    /// « NetScope 0.8.0 » (en-tête X-Mailer).
    public var mailer: String

    public init(from: String, fromName: String = "NetScope", to: [String], subject: String, textBody: String,
                htmlBody: String? = nil, date: Date = Date(), messageID: String? = nil,
                encoding: AlertMailEncoding = .quotedPrintable, mailer: String = "NetScope") {
        self.from = from.trimmingCharacters(in: .whitespaces)
        self.fromName = AlertText.singleLine(fromName)
        self.to = to.map { $0.trimmingCharacters(in: .whitespaces) }
        self.subject = AlertText.singleLine(subject)
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.date = date
        self.messageID = messageID ?? AlertMailMessage.makeMessageID(from: from)
        self.encoding = encoding
        self.mailer = AlertText.singleLine(mailer)
    }

    /// « <UUID@exemple.ca> » (domaine de l'expéditeur, sinon « netscope.local »).
    public static func makeMessageID(from address: String, id: UUID = UUID()) -> String {
        "<\(id.uuidString.lowercased())@\(AlertAddress.domain(of: address) ?? "netscope.local")>"
    }

    /// Date au format RFC 5322 (« Wed, 4 Nov 2026 14:03:00 -0500 »).
    public static func rfc5322Date(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// Message complet (en-têtes + corps), lignes terminées par CRLF, 7 bits seulement.
    /// `boundary` et `timeZone` sont réglables pour les tests.
    public func rendered(boundary: String? = nil, timeZone: TimeZone = .current) -> String {
        var headers: [String] = []
        headers.append("Date: " + Self.rfc5322Date(date, timeZone: timeZone))
        headers.append("From: " + MIMEHeader.mailbox(name: fromName, address: from))
        headers.append(MIMEHeader.fold("To: " + to.joined(separator: ", ")))
        headers.append(MIMEHeader.encodedHeader("Subject", subject))
        headers.append("Message-ID: " + messageID)
        headers.append("MIME-Version: 1.0")
        // Message automatique (RFC 3834) : pas de réponse d'absence en retour.
        headers.append("Auto-Submitted: auto-generated")
        headers.append("X-Auto-Response-Suppress: All")
        headers.append("X-Mailer: " + mailer)

        var body: [String] = []
        if let htmlBody {
            let mark = boundary ?? "NetScope-" + UUID().uuidString.lowercased()
            headers.append("Content-Type: multipart/alternative; boundary=\"\(mark)\"")
            body.append("Ceci est un message MIME en plusieurs parties.")
            body.append("")
            body.append("--\(mark)")
            body += part(textBody, type: "text/plain")
            body.append("--\(mark)")
            body += part(htmlBody, type: "text/html")
            body.append("--\(mark)--")
        } else {
            headers.append("Content-Type: text/plain; charset=UTF-8")
            headers.append("Content-Transfer-Encoding: " + transferEncodingName)
            body.append(encodedBody(textBody))
        }
        return (headers + [""] + body).joined(separator: "\r\n") + "\r\n"
    }

    private var transferEncodingName: String {
        encoding == .quotedPrintable ? "quoted-printable" : "base64"
    }

    private func part(_ text: String, type: String) -> [String] {
        ["Content-Type: \(type); charset=UTF-8", "Content-Transfer-Encoding: " + transferEncodingName, "", encodedBody(text)]
    }

    private func encodedBody(_ text: String) -> String {
        switch encoding {
        case .quotedPrintable: return QuotedPrintable.encode(text)
        case .base64: return MIMEHeader.base64Lines(Data(MIMEHeader.normalizeNewlines(text).utf8))
        }
    }
}

// MARK: - Quoted-printable (RFC 2045 §6.7)

public enum QuotedPrintable {
    /// Encode un texte UTF-8 : lignes de 76 caractères au plus (coupure douce « = »), octets non
    /// ASCII et « = » en =XX, espace ou tabulation de fin de ligne encodé, CRLF entre les lignes.
    public static func encode(_ text: String) -> String {
        let lines = MIMEHeader.normalizeNewlines(text).components(separatedBy: "\r\n")
        return lines.map(encodeLine).joined(separator: "\r\n")
    }

    private static func encodeLine(_ line: String) -> String {
        let bytes = Array(line.utf8)
        var tokens: [String] = []
        for (index, byte) in bytes.enumerated() {
            let isLast = index == bytes.count - 1
            let printable = (byte >= 33 && byte <= 126 && byte != 61)
            let space = byte == 32 || byte == 9
            // Un point en début de ligne est encodé aussi : certains relais tronquent sinon.
            if index == 0 && byte == 46 {
                tokens.append("=2E")
            } else if printable || (space && !isLast) {
                tokens.append(String(UnicodeScalar(byte)))
            } else {
                tokens.append(String(format: "=%02X", byte))
            }
        }
        // Coupures douces : au plus 75 caractères + « = », sans couper un « =XX ».
        var output: [String] = []
        var current = ""
        for token in tokens {
            if current.count + token.count > 75 {
                output.append(current + "=")
                current = ""
            }
            current += token
        }
        output.append(current)
        return output.joined(separator: "\r\n")
    }

    /// Décode (pour les tests et la vérification).
    public static func decode(_ text: String) -> String {
        var bytes: [UInt8] = []
        let source = text.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
        let raw = Array(source.utf8)
        var index = 0
        while index < raw.count {
            if raw[index] == 61, index + 2 < raw.count,
               let value = UInt8(String(decoding: raw[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                bytes.append(value)
                index += 3
            } else {
                bytes.append(raw[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - En-têtes

public enum MIMEHeader {
    /// Fins de ligne uniformisées en CRLF.
    public static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Base64 en lignes de 76 caractères (corps MIME).
    public static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    /// Vrai si le texte ne demande aucun encodage (ASCII imprimable).
    static func isPlainASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII && ($0.value >= 32 && $0.value < 127) }
    }

    /// Mots encodés RFC 2047 (« =?UTF-8?B?…?= »), sans couper un caractère : au plus 39 octets
    /// par mot (52 caractères base64), pour que « Subject: » et le mot tiennent en 76 caractères.
    public static func encodedWords(_ text: String) -> [String] {
        var words: [String] = []
        var chunk: [UInt8] = []
        for character in text {
            let bytes = Array(String(character).utf8)
            if chunk.count + bytes.count > 39, !chunk.isEmpty {
                words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=")
                chunk = []
            }
            chunk += bytes
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=") }
        return words
    }

    /// « Subject: … » : tel quel en ASCII (plié au besoin), sinon en mots encodés pliés.
    public static func encodedHeader(_ name: String, _ value: String) -> String {
        let clean = AlertText.singleLine(value)
        if isPlainASCII(clean) { return fold("\(name): \(clean)") }
        return "\(name): " + encodedWords(clean).joined(separator: "\r\n ")
    }

    /// « NetScope <alertes@exemple.ca> », nom encodé s'il contient des accents ou des caractères spéciaux.
    public static func mailbox(name: String, address: String) -> String {
        let clean = AlertText.singleLine(name)
        guard !clean.isEmpty else { return "<\(address)>" }
        if isPlainASCII(clean) {
            let needsQuotes = clean.contains { "()<>[]:;@\\,.\"".contains($0) }
            let escaped = clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return (needsQuotes ? "\"\(escaped)\"" : clean) + " <\(address)>"
        }
        return encodedWords(clean).joined(separator: " ") + " <\(address)>"
    }

    /// Pliage d'un en-tête ASCII à 78 caractères, aux espaces (RFC 5322 §2.2.3).
    public static func fold(_ line: String, limit: Int = 78) -> String {
        guard line.count > limit else { return line }
        var lines: [String] = []
        var current = ""
        var first = true
        for word in line.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            if first {
                current = word
                first = false
            } else if current.count + 1 + word.count > limit, !current.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(current)
                current = word
            } else {
                current += " " + word
            }
        }
        lines.append(current)
        return lines.joined(separator: "\r\n ")
    }
}

// MARK: - Point doublé

public enum SMTPDotStuffing {
    /// Corps prêt pour DATA : CRLF partout, « . » doublé en début de ligne, fin « CRLF.CRLF ».
    public static func dataPayload(_ message: String) -> [UInt8] {
        var text = MIMEHeader.normalizeNewlines(message)
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        let stuffed = text.components(separatedBy: "\r\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
        return Array((stuffed + ".\r\n").utf8)
    }
}
