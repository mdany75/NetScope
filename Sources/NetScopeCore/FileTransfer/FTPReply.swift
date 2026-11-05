import Foundation

// Note 50 : analyse des réponses du serveur FTP (RFC 959, 2228, 2389, 2428, 3659, 4217).
// Tout ici est pur : testé avec des réponses fixes, sans réseau.

/// Réponse complète du serveur : code à trois chiffres et texte (une ou plusieurs lignes).
public struct FTPReply: Equatable, Sendable {
    public var code: Int
    /// Lignes de texte, sans le code ni le séparateur (« 230 Login successful. » → « Login successful. »).
    public var lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    public var text: String { lines.joined(separator: "\n") }

    /// 1xx : préliminaire (le transfert commence) ; une autre réponse suivra.
    public var isPreliminary: Bool { (100..<200).contains(code) }
    /// 2xx : réussite.
    public var isSuccess: Bool { (200..<300).contains(code) }
    /// 3xx : la commande attend la suite (PASS après USER, RNTO après RNFR).
    public var isIntermediate: Bool { (300..<400).contains(code) }
    /// 4xx : échec temporaire ; 5xx : échec définitif.
    public var isFailure: Bool { code >= 400 }

    /// Première ligne, pour les messages (« 550 Permission denied. »).
    public var summary: String { "\(code) " + (lines.first ?? "") }
}

/// Assemble les réponses à partir des lignes reçues : « 123-début », lignes libres, « 123 fin ».
public struct FTPReplyParser: Sendable {
    private var pendingCode: Int?
    private var pendingLines: [String] = []

    public init() {}

    /// Ajoute une ligne (sans CRLF) ; renvoie la réponse quand elle est complète.
    public mutating func feed(_ line: String) throws -> FTPReply? {
        if let code = pendingCode {
            // Réponse sur plusieurs lignes : elle se termine par « code<espace> ».
            if line.count >= 4, Int(line.prefix(3)) == code, line[line.index(line.startIndex, offsetBy: 3)] == " " {
                pendingLines.append(String(line.dropFirst(4)))
                let reply = FTPReply(code: code, lines: pendingLines)
                pendingCode = nil
                pendingLines = []
                return reply
            }
            // Les lignes intermédiaires peuvent commencer par une espace ou par « code- ».
            if line.count >= 4, Int(line.prefix(3)) == code, line[line.index(line.startIndex, offsetBy: 3)] == "-" {
                pendingLines.append(String(line.dropFirst(4)))
            } else {
                pendingLines.append(line.hasPrefix(" ") ? String(line.dropFirst()) : line)
            }
            return nil
        }
        guard line.count >= 3, let code = Int(line.prefix(3)), (100...599).contains(code) else {
            throw FileTransferError.protocolViolation("Réponse illisible du serveur\u{00A0}: « \(line.prefix(80)) »")
        }
        let rest = line.dropFirst(3)
        if rest.first == "-" {
            pendingCode = code
            pendingLines = [String(rest.dropFirst())]
            return nil
        }
        // « 230 » seul ou « 230 texte ».
        return FTPReply(code: code, lines: [rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)])
    }

    /// Analyse un bloc entier (réponses fixes des tests).
    public static func parseAll(_ text: String) throws -> [FTPReply] {
        var parser = FTPReplyParser()
        var replies: [FTPReply] = []
        for line in FTPLineSplitter.lines(in: text) {
            if let reply = try parser.feed(line) { replies.append(reply) }
        }
        return replies
    }
}

/// Découpe un flux d'octets en lignes CRLF (LF seul toléré).
public struct FTPLineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<index]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(FTPText.decode(Data(lineData)))
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }

    /// Octets reçus sans fin de ligne (reste).
    public var remainder: Data { buffer }

    public static func lines(in text: String) -> [String] {
        var splitter = FTPLineSplitter()
        var lines = splitter.append(Data(text.utf8))
        if !splitter.remainder.isEmpty { lines.append(FTPText.decode(splitter.remainder)) }
        return lines
    }
}

/// Décodage du texte : UTF-8, sinon ISO Latin 1 (vieux serveurs Windows et appareils).
public enum FTPText {
    public static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

/// Lecture des réponses particulières : PASV, EPSV, PWD, FEAT ; construction de PORT et EPRT.
public enum FTPResponse {
    /// « 227 Entering Passive Mode (192,168,1,10,195,149). » → 192.168.1.10, port 50069.
    public static func passiveEndpoint(_ reply: FTPReply) throws -> (host: String, port: Int) {
        guard reply.code == 227 else { throw FileTransferError.server(reply.summary) }
        let text = reply.text
        // Six nombres séparés par des virgules, avec ou sans parenthèses.
        let pattern = #"(\d{1,3}),\s*(\d{1,3}),\s*(\d{1,3}),\s*(\d{1,3}),\s*(\d{1,3}),\s*(\d{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            throw FileTransferError.protocolViolation("Réponse PASV illisible\u{00A0}: « \(reply.summary) »")
        }
        var numbers: [Int] = []
        for group in 1...6 {
            guard let range = Range(match.range(at: group), in: text), let value = Int(text[range]), (0...255).contains(value) else {
                throw FileTransferError.protocolViolation("Réponse PASV hors limites\u{00A0}: « \(reply.summary) »")
            }
            numbers.append(value)
        }
        let port = numbers[4] * 256 + numbers[5]
        guard port > 0 else { throw FileTransferError.protocolViolation("Port passif nul\u{00A0}: « \(reply.summary) »") }
        return (numbers[0...3].map(String.init).joined(separator: "."), port)
    }

    /// « 229 Entering Extended Passive Mode (|||50069|) » → 50069 (l'hôte est celui du contrôle).
    public static func extendedPassivePort(_ reply: FTPReply) throws -> Int {
        guard reply.code == 229 else { throw FileTransferError.server(reply.summary) }
        let text = reply.text
        guard let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") else {
            throw FileTransferError.protocolViolation("Réponse EPSV illisible\u{00A0}: « \(reply.summary) »")
        }
        let inner = text[text.index(after: open)..<close]
        // Le délimiteur est le premier caractère (souvent « | »), répété quatre fois.
        guard let delimiter = inner.first else {
            throw FileTransferError.protocolViolation("Réponse EPSV vide\u{00A0}: « \(reply.summary) »")
        }
        let parts = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        guard parts.count == 5, let port = Int(parts[3]), (1...65_535).contains(port) else {
            throw FileTransferError.protocolViolation("Réponse EPSV illisible\u{00A0}: « \(reply.summary) »")
        }
        return port
    }

    /// « 257 "/home/ftp/Mon ""dossier""" is current directory » → /home/ftp/Mon "dossier".
    public static func quotedPath(_ reply: FTPReply) throws -> String {
        let text = reply.lines.first ?? ""
        guard let start = text.firstIndex(of: "\"") else {
            // Quelques serveurs répondent sans guillemets : « 257 /home/ftp ».
            let bare = text.split(separator: " ").first.map(String.init) ?? ""
            guard bare.hasPrefix("/") else { throw FileTransferError.protocolViolation("Réponse PWD illisible\u{00A0}: « \(reply.summary) »") }
            return bare
        }
        var result = ""
        var index = text.index(after: start)
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\"" {
                    result.append("\"")
                    index = text.index(after: next)
                    continue
                }
                return result
            }
            result.append(character)
            index = text.index(after: index)
        }
        throw FileTransferError.protocolViolation("Réponse PWD sans guillemet de fin\u{00A0}: « \(reply.summary) »")
    }

    /// Extensions annoncées par FEAT (« MLST type*;size*;modify*; », « UTF8 », « EPSV ») :
    /// nom en majuscules → paramètres.
    public static func features(_ reply: FTPReply) -> [String: String] {
        guard reply.code == 211 else { return [:] }
        var result: [String: String] = [:]
        // Première et dernière lignes : « Features: » et « End ».
        for line in reply.lines.dropFirst().dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            result[parts[0].uppercased()] = parts.count > 1 ? String(parts[1]) : ""
        }
        return result
    }

    /// « PORT 10,0,0,5,195,149 » (mode actif IPv4).
    public static func portCommand(host: String, port: Int) throws -> String {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }), (1...65_535).contains(port) else {
            throw FileTransferError.protocolViolation("Adresse locale inutilisable pour le mode actif\u{00A0}: \(host)")
        }
        return "PORT " + (parts.map(String.init) + [String(port / 256), String(port % 256)]).joined(separator: ",")
    }

    /// « EPRT |1|10.0.0.5|50069| » ou « EPRT |2|fe80::1|50069| ».
    public static func extendedPortCommand(host: String, port: Int) -> String {
        "EPRT |\(host.contains(":") ? 2 : 1)|\(host)|\(port)|"
    }

    /// « 213 20261104153012 » (MDTM) → date UTC.
    public static func modificationDate(_ reply: FTPReply) -> Date? {
        guard reply.code == 213 else { return nil }
        return FTPListing.mlsdDate(reply.text.trimmingCharacters(in: .whitespaces))
    }

    /// « 213 1048576 » (SIZE) → 1048576.
    public static func size(_ reply: FTPReply) -> Int64? {
        guard reply.code == 213 else { return nil }
        return Int64(reply.text.trimmingCharacters(in: .whitespaces))
    }
}
