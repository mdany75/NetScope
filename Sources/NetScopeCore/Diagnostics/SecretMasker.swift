import Foundation

/// Masqueur de secrets (note 35) : appliqué à chaque entrée du journal AVANT son écriture, puis
/// une seconde fois à tout ce qui part dans un diagnostic exporté. Il remplace la valeur des
/// jetons, mots de passe, communautés SNMP, clés d'API et en-têtes d'autorisation par
/// `SecretMasker.placeholder`, en gardant le nom du champ pour que le message reste lisible.
///
/// Mieux vaut masquer un peu trop que pas assez : un mot ordinaire placé après « mot de passe : »
/// est masqué lui aussi.
public enum SecretMasker {
    /// Texte mis à la place d'un secret.
    public static let placeholder = "••••••"

    /// Masque tous les secrets reconnus de `text`.
    public static func mask(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            result = rule.apply(result)
        }
        result = maskSNMPCommandLines(result)
        result = maskLongTokens(result)
        return result
    }

    /// Vrai quand le nom d'un champ (clé JSON, préférence, paramètre) désigne un secret.
    public static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return secretKeyFragments.contains { lower.contains($0) }
    }

    /// Fragments de noms de champs secrets (minuscules), communs aux règles JSON et aux préférences.
    static let secretKeyFragments = [
        "password", "passwd", "pwd", "passphrase", "motdepasse", "mot_de_passe", "token", "jeton",
        "secret", "community", "communaute", "communauté", "apikey", "api_key", "api-key",
        "authorization", "privkey", "private_key", "privatekey", "cookie", "credential", "bearer",
    ]

    // MARK: Règles

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            // Motifs écrits ici : une erreur de syntaxe est une faute de programmation.
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.template = template
        }

        func apply(_ text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
    }

    private static let p = NSRegularExpression.escapedTemplate(for: placeholder)

    /// Noms de champs secrets dans du JSON (« "password": … », « "access_token": … »). « topic » :
    /// sujet ntfy, qui sert de clé de lecture sur un serveur public.
    private static let jsonKey = #"[A-Za-z0-9_\-]*(?:password|passwd|pwd|passphrase|token|secret|community|apikey|api_key|api-key|authorization|privkey|private_key|cookie|credential|topic)[A-Za-z0-9_\-]*"#

    /// Noms d'un secret dans du texte libre ou un en-tête (« mot de passe : », « token= »).
    private static let textKey = #"(?:access[_\-]?token|refresh[_\-]?token|id[_\-]?token|auth[_\-]?token|session[_\-]?token|x-auth-token|x-api-key|api[_\-]?key|apikey|api[_\- ]?token|client[_\-]?secret|secret|passphrase|password|passwd|pwd|mot de passe|mot_de_passe|motdepasse|token|jeton|community|communauté|communaute|auth[_\-]?password|priv[_\-]?password|clé d[’']api|cle d[’']api)"#

    /// Valeur d'un champ : entre guillemets, « », ou jusqu'au premier séparateur.
    private static let value = #"(?:"[^"\n]*"|'[^'\n]*'|«[^»\n]*»|[^\s&#,;"'<>»)\]}]+)"#

    private static let rules: [Rule] = [
        // Bloc de clé privée (PEM).
        Rule(#"-----BEGIN ([A-Z ]*)PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
             "-----BEGIN $1PRIVATE KEY-----\(p)-----END $1PRIVATE KEY-----"),
        // JSON échappé dans une chaîne : \"password\":\"…\".
        Rule(#"(\\"\#(jsonKey)\\"\s*:\s*\\")(?:[^"\\]|\\[^"])*(\\")"#, "$1\(p)$2"),
        // JSON : "password": "…" ou "token": 123.
        Rule(#"("\#(jsonKey)"\s*:\s*)(?:"(?:[^"\\\n]|\\.)*"|[^,}\]\s]+)"#, "$1\"\(p)\""),
        // En-tête Authorization (avec ou sans schéma), aussi « "Authorization": » déjà traité plus haut.
        Rule(#"((?:proxy-)?authorization\s*[:=]\s*)((?:bearer|basic|token|digest|negotiate|ntlm|apikey)\s+)?[^\s,;"'}]+"#,
             "$1$2\(p)"),
        // Jeton Bearer isolé.
        Rule(#"\b(bearer\s+)[A-Za-z0-9\-._~+/=]+"#, "$1\(p)"),
        // Identifiants dans une URL : scheme://utilisateur:motdepasse@hôte.
        Rule(#"\b([a-z][a-z0-9+.\-]*://[^/\s:@]+:)[^@\s/]+(@)"#, "$1\(p)$2"),
        // Paramètres d'URL : ?access_token=…, &key=…, &community=…
        Rule(#"([?&;](?:access_token|refresh_token|id_token|token|api_key|apikey|key|password|passwd|pwd|pass|secret|client_secret|community|auth|sig|signature|code)=)[^&#\s"'<>]+"#,
             "$1\(p)"),
        // Texte libre ou en-tête : « mot de passe : abc », « token=abc », « X-API-Key: abc ».
        Rule(#"(\b[A-Za-z0-9_\-]*\#(textKey)\s*[:=]\s*)\#(value)"#, "$1\(p)"),
        // Valeur entre guillemets directement après le nom : « communauté « public » », « jeton 'abc' ».
        Rule(#"(\b\#(textKey)\s+)(?:"[^"\n]*"|'[^'\n]*'|«[^»\n]*»)"#, "$1\(p)"),
        // Configuration Cisco ou HPE : « snmp-server community public RO ».
        Rule(#"(snmp-server\s+community\s+)\S+"#, "$1\(p)"),
        Rule(#"(snmp-server\s+user\s+\S+\s+\S+\s+(?:v3\s+)?(?:auth\s+\S+\s+)?)\S+"#, "$1\(p)"),
    ]

    /// Lignes de commande SNMP (snmpwalk, snmpget…) : valeurs de -c (communauté), -A et -X
    /// (phrases de passe v3).
    private static func maskSNMPCommandLines(_ text: String) -> String {
        guard text.range(of: "snmp", options: .caseInsensitive) != nil else { return text }
        let flag = try! NSRegularExpression(pattern: #"(\s-[cAX]\s*)(?!\#(NSRegularExpression.escapedPattern(for: placeholder)))\S+"#)
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard line.range(of: "snmp", options: .caseInsensitive) != nil else { return line }
            return flag.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1\(p)")
        }
        return lines.joined(separator: "\n")
    }

    /// Jetons d'API isolés (ex. jeton FortiGate de 30 caractères) : longue suite de lettres et de
    /// chiffres mêlés. Les noms de fonctions Swift des rapports de plantage (peu de chiffres) et les
    /// identifiants avec tirets (UUID) sont épargnés.
    private static func maskLongTokens(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_$])[A-Za-z0-9]{28,}(?![A-Za-z0-9_])"#)
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let candidate = ns.substring(with: match.range)
            let digits = candidate.filter(\.isNumber).count
            let letters = candidate.filter(\.isLetter).count
            guard digits >= 6, letters >= 6 else { continue }
            // Empreinte hexadécimale (SHA, UUID sans tiret) : rien de secret, souvent utile.
            if candidate.allSatisfy(\.isHexDigit) && (candidate == candidate.lowercased() || candidate == candidate.uppercased()) { continue }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += placeholder
            cursor = match.range.location + match.range.length
        }
        guard cursor > 0 else { return text }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: Adresses publiques

    /// Remplace les deux derniers octets des adresses IPv4 publiques (« 203.0.x.x ») : les adresses
    /// privées, de bouclage, de lien local et CGNAT restent entières.
    public static func maskPublicIPv4(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?<![0-9.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![0-9]|\.\d)"#)
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let octets = (1...4).compactMap { Int(ns.substring(with: match.range(at: $0))) }
            guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }), isPublic(octets) else { continue }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "\(octets[0]).\(octets[1]).x.x"
            cursor = match.range.location + match.range.length
        }
        guard cursor > 0 else { return text }
        result += ns.substring(from: cursor)
        return result
    }

    static func isPublic(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (255, _): return false
        case (172, 16...31), (100, 64...127): return false
        case (224...239, _): return false
        default: return true
        }
    }
}
