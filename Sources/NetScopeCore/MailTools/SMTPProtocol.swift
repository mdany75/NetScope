import Foundation

// Diagnostic SMTP (note 14), partie sans réseau : lecture des réponses du serveur (multi-lignes),
// extensions annoncées par EHLO, commandes permises, certificat et bilan de cohérence
// (bannière, DNS inverse, nom du certificat). Rien ici n'ouvre de connexion.

// MARK: - Réponses

/// Une réponse SMTP complète : code à trois chiffres et ses lignes de texte (sans le code).
public struct SMTPReply: Equatable, Sendable {
    public var code: Int
    public var lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    /// 2xx : réussite ; 3xx : suite attendue.
    public var isPositive: Bool { (200..<400).contains(code) }
    public var isTransientFailure: Bool { (400..<500).contains(code) }
    public var isPermanentFailure: Bool { code >= 500 }

    /// Première ligne (« mx.example.com ESMTP Postfix »).
    public var firstLine: String { lines.first ?? "" }

    /// Réponse telle qu'envoyée par le serveur (« 250-… », « 250 … »).
    public var rawLines: [String] {
        lines.enumerated().map { index, text in
            "\(code)\(index == lines.count - 1 ? " " : "-")\(text)".trimmingCharacters(in: .whitespaces)
        }
    }
}

public enum SMTPError: Error, LocalizedError, Equatable, Sendable {
    case malformedReply(String)
    case replyTooLong
    case invalidHostname(String)

    public var errorDescription: String? {
        switch self {
        case .malformedReply(let line): return "Réponse SMTP illisible : « \(line.prefix(80)) »."
        case .replyTooLong: return "Réponse SMTP trop longue."
        case .invalidHostname(let name): return "« \(name) » n’est pas un nom de serveur valide."
        }
    }
}

/// Assemble les réponses à partir des octets reçus, même coupés n'importe où (« 250-… » continue
/// la réponse, « 250 … » la termine). Les lignes finissent par CRLF (LF seul toléré).
public struct SMTPReplyParser: Sendable {
    /// Au-delà, la réponse est jugée anormale (un serveur qui n'arrête pas de parler).
    public static let maxReplyBytes = 64 * 1024

    private var buffer: [UInt8] = []
    private var pendingCode: Int?
    private var pendingLines: [String] = []
    private var pendingBytes = 0

    public init() {}

    /// Vrai quand une réponse multi-lignes est commencée mais pas terminée.
    public var hasPartialReply: Bool { pendingCode != nil || !buffer.isEmpty }

    public mutating func feed(_ bytes: [UInt8]) throws -> [SMTPReply] {
        buffer += bytes
        var replies: [SMTPReply] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineBytes = Array(buffer[..<newline])
            buffer.removeFirst(newline + 1)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            pendingBytes += lineBytes.count + 2
            guard pendingBytes <= Self.maxReplyBytes else { throw SMTPError.replyTooLong }
            let line = String(decoding: lineBytes, as: UTF8.self)
            if let reply = try accept(line) {
                replies.append(reply)
                pendingBytes = 0
            }
        }
        if buffer.count > Self.maxReplyBytes { throw SMTPError.replyTooLong }
        return replies
    }

    public mutating func feed(_ text: String) throws -> [SMTPReply] { try feed(Array(text.utf8)) }

    private mutating func accept(_ line: String) throws -> SMTPReply? {
        let characters = Array(line)
        guard characters.count >= 3, let code = Int(String(characters[0..<3])), (200...599).contains(code) else {
            throw SMTPError.malformedReply(line)
        }
        let separator: Character = characters.count > 3 ? characters[3] : " "
        guard separator == " " || separator == "-" else { throw SMTPError.malformedReply(line) }
        if let pending = pendingCode, pending != code { throw SMTPError.malformedReply(line) }
        let text = characters.count > 4 ? String(characters[4...]) : ""
        pendingCode = code
        pendingLines.append(text)
        guard separator == " " else { return nil }
        let reply = SMTPReply(code: code, lines: pendingLines)
        pendingCode = nil
        pendingLines = []
        return reply
    }
}

// MARK: - Commandes

/// Les seules commandes que NetScope envoie : aucun MAIL FROM, RCPT TO ni DATA, donc aucun
/// courriel envoyé et aucun test de relais ouvert.
public enum SMTPCommand: Equatable, Sendable {
    case ehlo(String)
    case startTLS
    case quit

    public var line: String {
        switch self {
        case .ehlo(let name): return "EHLO \(name)"
        case .startTLS: return "STARTTLS"
        case .quit: return "QUIT"
        }
    }

    public var bytes: [UInt8] { Array((line + "\r\n").utf8) }

    /// Nom annoncé par EHLO : nom de domaine ou adresse entre crochets, sans espace ni saut de ligne.
    public static func validEHLOName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "-._[]:".unicodeScalars.contains(scalar)
        }
    }
}

// MARK: - Extensions EHLO

/// Une extension annoncée dans la réponse à EHLO (« SIZE 35882577 », « AUTH PLAIN LOGIN »).
public struct SMTPExtension: Hashable, Sendable, Identifiable {
    public var keyword: String
    public var parameters: [String]

    public var id: String { keyword }

    public init(keyword: String, parameters: [String] = []) {
        self.keyword = keyword
        self.parameters = parameters
    }

    /// Les extensions d'une réponse EHLO (la première ligne est la salutation du serveur).
    public static func parse(ehlo reply: SMTPReply) -> [SMTPExtension] {
        guard reply.code == 250 else { return [] }
        return reply.lines.dropFirst().compactMap { line in
            let fields = line.split(separator: " ").map(String.init)
            guard let first = fields.first else { return nil }
            // « AUTH=LOGIN PLAIN » (forme ancienne) : même sens que « AUTH LOGIN PLAIN ».
            if first.uppercased().hasPrefix("AUTH=") {
                return SMTPExtension(keyword: "AUTH", parameters: [String(first.dropFirst(5))] + fields.dropFirst())
            }
            return SMTPExtension(keyword: first.uppercased(), parameters: Array(fields.dropFirst()))
        }
    }

    /// Explication en français.
    public var explanation: String {
        switch keyword {
        case "STARTTLS": return "Chiffrement de la session proposé (STARTTLS)"
        case "SIZE":
            if let bytes = parameters.first.flatMap(Int.init), bytes > 0 {
                return "Taille maximale d’un message\u{00A0}: \(Self.megabytes(bytes))"
            }
            return "Taille maximale annoncée (sans limite précise)"
        case "PIPELINING": return "Plusieurs commandes envoyées d’un coup"
        case "8BITMIME": return "Messages en 8 bits acceptés"
        case "BINARYMIME": return "Messages binaires acceptés (avec CHUNKING)"
        case "SMTPUTF8": return "Adresses internationales (UTF-8) acceptées"
        case "ENHANCEDSTATUSCODES": return "Codes d’état détaillés (5.7.1…)"
        case "CHUNKING": return "Envoi par blocs (BDAT)"
        case "DSN": return "Avis de remise sur demande"
        case "AUTH": return "Authentification\u{00A0}: " + (parameters.isEmpty ? "mécanismes non précisés" : parameters.joined(separator: ", "))
        case "REQUIRETLS": return "Exige le chiffrement de bout en bout du trajet (REQUIRETLS)"
        case "DELIVERBY": return "Remise avant une échéance"
        case "ETRN": return "Relance de la file d’attente à distance"
        case "VRFY": return "Vérification d’adresse (VRFY)\u{00A0}: permet de deviner les comptes"
        case "EXPN": return "Développement des listes (EXPN)\u{00A0}: révèle les membres"
        case "HELP": return "Aide en ligne"
        case "MTRK": return "Suivi des messages"
        case "LIMITS": return "Limites annoncées\u{00A0}: " + parameters.joined(separator: " ")
        default:
            return keyword.hasPrefix("X") ? "Extension propre au serveur" : "Extension « \(keyword) »"
        }
    }

    /// Extension à surveiller (ton d'avertissement dans l'interface).
    public var isConcern: Bool { keyword == "VRFY" || keyword == "EXPN" }

    static func megabytes(_ bytes: Int) -> String {
        let value = Double(bytes) / 1_048_576
        return value >= 10 ? "\(Int(value.rounded()))\u{00A0}Mo" : "\(ToolFormat.decimal(value))\u{00A0}Mo"
    }
}

extension Array where Element == SMTPExtension {
    public func contains(_ keyword: String) -> Bool { contains { $0.keyword == keyword } }
    public func first(_ keyword: String) -> SMTPExtension? { first { $0.keyword == keyword } }
}

// MARK: - Bannière

public enum SMTPBanner {
    /// Nom annoncé au début de la bannière ou de la salutation EHLO (« mx.example.com ESMTP… »).
    public static func hostname(in line: String) -> String? {
        guard let first = line.split(separator: " ").first.map(String.init) else { return nil }
        let name = first.hasSuffix(".") ? String(first.dropLast()) : first
        guard name.contains("."), name.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$", options: .regularExpression) != nil,
              Double(name.replacingOccurrences(of: ".", with: "")) == nil else { return nil }
        return name.lowercased()
    }

    /// Logiciel reconnu dans la bannière (Postfix, Exim, Exchange, Google…).
    public static func software(in line: String) -> String? {
        let lowered = line.lowercased()
        let known: [(String, String)] = [
            ("postfix", "Postfix"), ("exim", "Exim"), ("sendmail", "Sendmail"), ("microsoft esmtp", "Microsoft Exchange"),
            ("exchange", "Microsoft Exchange"), ("mx.google.com", "Google"), ("gsmtp", "Google"),
            ("outlook.com", "Microsoft 365"), ("protection.outlook", "Microsoft 365"), ("haraka", "Haraka"),
            ("opensmtpd", "OpenSMTPD"), ("zimbra", "Zimbra"), ("mailgun", "Mailgun"), ("proofpoint", "Proofpoint"),
            ("pphosted", "Proofpoint"), ("mimecast", "Mimecast"), ("barracuda", "Barracuda"), ("sophos", "Sophos"),
            ("zoho", "Zoho"), ("icewarp", "IceWarp"), ("mdaemon", "MDaemon"), ("kerio", "Kerio"),
        ]
        return known.first { lowered.contains($0.0) }?.1
    }
}

// MARK: - Certificat

/// Certificat présenté par le serveur après STARTTLS (ou au port 465).
public struct SMTPCertificate: Sendable, Hashable {
    public var subject: String
    public var issuer: String
    public var notBefore: Date?
    public var notAfter: Date?
    /// Noms couverts (extension subjectAltName, sinon le nom commun).
    public var dnsNames: [String]
    public var isTrusted: Bool
    public var isSelfSigned: Bool
    public var trustError: String?

    public init(subject: String, issuer: String, notBefore: Date?, notAfter: Date?, dnsNames: [String],
                isTrusted: Bool, isSelfSigned: Bool, trustError: String? = nil) {
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.dnsNames = dnsNames
        self.isTrusted = isTrusted
        self.isSelfSigned = isSelfSigned
        self.trustError = trustError
    }

    /// Jours restants avant l'expiration (négatif si expiré).
    public func daysLeft(now: Date = Date()) -> Int? {
        notAfter.map { Int(floor($0.timeIntervalSince(now) / 86_400)) }
    }

    /// Vrai si le certificat couvre `host` (nom exact, ou joker « *.example.com » sur une seule étiquette).
    public func covers(_ host: String) -> Bool {
        Self.matches(names: dnsNames, host: host)
    }

    public static func matches(names: [String], host: String) -> Bool {
        let target = normalize(host)
        guard !target.isEmpty else { return false }
        return names.contains { raw in
            let name = normalize(raw)
            if name == target { return true }
            guard name.hasPrefix("*.") else { return false }
            let suffix = String(name.dropFirst(1))   // « .example.com »
            guard target.hasSuffix(suffix) else { return false }
            let head = target.dropLast(suffix.count)
            return !head.isEmpty && !head.contains(".")
        }
    }

    static func normalize(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

// MARK: - Bilan

/// Constat du diagnostic, du plus grave au plus rassurant.
public struct SMTPFinding: Hashable, Sendable, Identifiable {
    public enum Level: Int, Comparable, Sendable {
        case ok = 0, info = 1, warning = 2, critical = 3
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var level: Level
    public var title: String
    public var detail: String

    public var id: String { title }

    public init(_ level: Level, _ title: String, _ detail: String = "") {
        self.level = level
        self.title = title
        self.detail = detail
    }
}

/// Résultat d'une tentative de connexion TCP (port 25 bloqué ou non).
public enum SMTPConnectOutcome: Equatable, Sendable {
    case connected
    case refused
    case timedOut
    case failed(String)

    public var label: String {
        switch self {
        case .connected: return "joignable"
        case .refused: return "refusé"
        case .timedOut: return "délai dépassé"
        case .failed(let text): return text
        }
    }
}

/// Mode de chiffrement d'une session.
public enum SMTPTLSMode: String, Sendable {
    /// Ports 25 et 587 : session en clair, puis STARTTLS si le serveur le propose.
    case startTLS
    /// Port 465 : TLS dès la connexion.
    case implicit

    public static func forPort(_ port: UInt16) -> SMTPTLSMode { port == 465 ? .implicit : .startTLS }
}

/// État du chiffrement après le diagnostic.
public enum SMTPTLSState: Equatable, Sendable {
    case notOffered
    case notReached
    case succeeded
    case failed(String)

    public var label: String {
        switch self {
        case .notOffered: return "STARTTLS non proposé"
        case .notReached: return "—"
        case .succeeded: return "Chiffré"
        case .failed: return "Échec du chiffrement"
        }
    }
}

/// Règles de bilan : tout ce qui se décide à partir des données recueillies, sans réseau.
public enum SMTPAssessment {
    /// Le port 25 ne répond pas (délai dépassé) alors qu'un autre port du même serveur répond :
    /// signe classique d'un fournisseur d'accès qui bloque le port 25 sortant.
    public static func port25Block(port25: SMTPConnectOutcome, alternatives: [(port: UInt16, outcome: SMTPConnectOutcome)]) -> SMTPFinding? {
        guard port25 == .timedOut else { return nil }
        let open = alternatives.filter { $0.outcome == .connected || $0.outcome == .refused }.map(\.port)
        if open.isEmpty {
            return SMTPFinding(.critical, "Aucune réponse sur les ports 25, 587 ni 465",
                               "Le serveur est injoignable depuis ce réseau, ou un pare-feu filtre tout le trafic courriel.")
        }
        let ports = open.map(String.init).joined(separator: " et ")
        return SMTPFinding(.critical, "Le port 25 sortant semble bloqué par votre fournisseur",
                           "Délai dépassé sur le port 25 alors que le port \(ports) du même serveur répond. Beaucoup de "
                           + "fournisseurs résidentiels bloquent le port 25 sortant : refaire le test depuis un autre réseau, "
                           + "ou utiliser le port 587 pour envoyer.")
    }

    /// Bilan de la session : bannière, DNS inverse, chiffrement, certificat, extensions.
    public static func findings(host: String, port: UInt16, banner: SMTPReply?, bannerDelayMs: Double?,
                                ehloGreeting: String?, extensions: [SMTPExtension], extensionsAfterTLS: [SMTPExtension],
                                tls: SMTPTLSState, tlsVersion: String?, certificate: SMTPCertificate?,
                                ptrNames: [String]?, ptrConfirmed: Bool?, now: Date = Date()) -> [SMTPFinding] {
        var list: [SMTPFinding] = []
        let target = SMTPCertificate.normalize(host)
        let isIP = IPv4Address(target) != nil

        // Bannière
        if let banner {
            if banner.code == 220 {
                if let delay = bannerDelayMs, delay > 5_000 {
                    list.append(SMTPFinding(.info, "Bannière lente (\(ToolFormat.seconds(delay / 1000)))",
                                            "Certains serveurs retardent volontairement la bannière pour décourager les robots."))
                }
            } else {
                list.append(SMTPFinding(.critical, "Le serveur refuse la session (code \(banner.code))",
                                        "Bannière\u{00A0}: « \(banner.firstLine) ». L’adresse de ce réseau est peut-être sur une liste noire."))
            }
        }

        // DNS inverse (nil : non vérifié)
        let bannerHost = banner.flatMap { SMTPBanner.hostname(in: $0.firstLine) }
        if let ptrNames, ptrNames.isEmpty {
            list.append(SMTPFinding(.warning, "Aucun DNS inverse (PTR) pour l’adresse du serveur",
                                    "Un serveur qui envoie du courriel sans PTR est souvent refusé par les destinataires."))
        } else if let ptrNames {
            let ptr = SMTPCertificate.normalize(ptrNames[0])
            if ptrConfirmed == false {
                list.append(SMTPFinding(.warning, "DNS inverse non confirmé",
                                        "Le PTR « \(ptr) » ne renvoie pas à l’adresse du serveur (FCrDNS)."))
            } else if ptrConfirmed == true {
                list.append(SMTPFinding(.ok, "DNS inverse confirmé", "PTR « \(ptr) » ⇄ même adresse."))
            }
            if let bannerHost {
                if ptrNames.contains(where: { SMTPCertificate.normalize($0) == bannerHost }) {
                    list.append(SMTPFinding(.ok, "Bannière cohérente avec le DNS inverse", "Les deux annoncent « \(bannerHost) »."))
                } else {
                    list.append(SMTPFinding(.info, "La bannière n’annonce pas le nom du DNS inverse",
                                            "Bannière\u{00A0}: « \(bannerHost) » · PTR\u{00A0}: « \(ptr) »."))
                }
            }
        }

        // Chiffrement
        switch tls {
        case .notOffered:
            if port == 587 {
                list.append(SMTPFinding(.critical, "STARTTLS absent sur le port de soumission",
                                        "Les mots de passe et les messages passeraient en clair."))
            } else {
                list.append(SMTPFinding(.warning, "STARTTLS non proposé", "Les messages reçus par ce serveur voyagent en clair."))
            }
        case .failed(let reason):
            list.append(SMTPFinding(.critical, "Échec du chiffrement", reason))
        case .succeeded:
            if let tlsVersion, tlsVersion == "TLS 1.0" || tlsVersion == "TLS 1.1" {
                list.append(SMTPFinding(.warning, "Version de TLS dépassée (\(tlsVersion))", "TLS 1.2 ou 1.3 est attendu aujourd’hui."))
            } else {
                list.append(SMTPFinding(.ok, "Session chiffrée" + (tlsVersion.map { " (\($0))" } ?? "")))
            }
        case .notReached:
            break
        }

        // Certificat
        if let certificate {
            if let days = certificate.daysLeft(now: now) {
                if days < 0 {
                    list.append(SMTPFinding(.critical, "Certificat expiré", "Expiré depuis \(-days)\u{00A0}j."))
                } else if days < 14 {
                    list.append(SMTPFinding(.warning, "Certificat bientôt expiré", "Il reste \(days)\u{00A0}j."))
                }
            }
            if !isIP {
                if certificate.covers(target) {
                    list.append(SMTPFinding(.ok, "Le certificat couvre « \(target) »"))
                } else {
                    let names = certificate.dnsNames.prefix(4).joined(separator: ", ")
                    list.append(SMTPFinding(.warning, "Le certificat ne couvre pas « \(target) »",
                                            names.isEmpty ? "Aucun nom dans le certificat." : "Noms du certificat\u{00A0}: \(names)."))
                }
            }
            if let bannerHost, bannerHost != target, !certificate.covers(bannerHost) {
                list.append(SMTPFinding(.info, "Le certificat ne couvre pas le nom de la bannière", "« \(bannerHost) »."))
            }
            if certificate.isSelfSigned {
                list.append(SMTPFinding(.warning, "Certificat auto-signé",
                                        "La plupart des serveurs l’acceptent quand même pour STARTTLS, mais MTA-STS et DANE le refusent."))
            } else if !certificate.isTrusted {
                list.append(SMTPFinding(.warning, "Certificat non approuvé par macOS", certificate.trustError ?? ""))
            }
        }

        // Extensions
        if let auth = extensions.first("AUTH"), port != 465 {
            let plainText = auth.parameters.contains { ["PLAIN", "LOGIN"].contains($0.uppercased()) }
            if plainText {
                list.append(SMTPFinding(.warning, "Authentification proposée avant le chiffrement",
                                        "AUTH \(auth.parameters.joined(separator: " ")) est annoncé en clair, avant STARTTLS."))
            }
        }
        if port == 25, extensionsAfterTLS.contains("AUTH") || extensions.contains("AUTH") {
            list.append(SMTPFinding(.info, "Authentification ouverte sur le port 25",
                                    "Le port 25 sert à la réception entre serveurs ; l’envoi authentifié passe d’habitude par 587."))
        }
        let all = extensions + extensionsAfterTLS
        if all.contains("VRFY") || all.contains("EXPN") {
            list.append(SMTPFinding(.info, "VRFY ou EXPN activé", "Ces commandes permettent de deviner des adresses valides."))
        }
        if let ehloGreeting, ehloGreeting.isEmpty {
            list.append(SMTPFinding(.info, "Salutation EHLO vide"))
        }
        return list.sorted { $0.level > $1.level }
    }
}
