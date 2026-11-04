import Foundation

// DKIM (RFC 6376, RFC 8463) : lecture d'une clé publiée à « <sélecteur>._domainkey.<domaine> »,
// type de clé (rsa, ed25519), clé révoquée (p= vide), taille de la clé RSA lue dans le DER, mode
// test (t=y) ; essai des sélecteurs les plus courants.

public struct DKIMKey: Hashable, Sendable {
    public var text: String
    public var tags: MailTagList
    /// « rsa » (par défaut) ou « ed25519 ».
    public var keyType: String
    /// Clé publique en base64 ; vide quand la clé est révoquée.
    public var publicKey: String
    public var revoked: Bool
    /// Taille de la clé en bits (RSA : longueur du module ; Ed25519 : 256) ; nil si illisible.
    public var bits: Int?
    public var testing: Bool
    public var errors: [String]
    public var warnings: [String]

    /// Un TXT ressemble à une clé DKIM : « v=DKIM1 » au début, ou une étiquette p=.
    public static func looksLikeDKIM(_ text: String) -> Bool {
        let tags = MailTagList.parse(text)
        return tags["v"]?.uppercased() == "DKIM1" || tags["p"] != nil
    }

    public static func parse(_ text: String) -> DKIMKey {
        let tags = MailTagList.parse(text)
        var key = DKIMKey(text: text, tags: tags, keyType: (tags["k"] ?? "rsa").lowercased(), publicKey: "", revoked: false,
                          bits: nil, testing: false, errors: tags.errors, warnings: [])
        if let version = tags["v"] {
            if version != "DKIM1" { key.errors.append("«\u{00A0}v=\(version)\u{00A0}»\u{00A0}: seule la version DKIM1 existe.") }
            if tags.keys.first != "v" { key.errors.append("«\u{00A0}v=DKIM1\u{00A0}» doit être la première étiquette.") }
        }
        if !["rsa", "ed25519"].contains(key.keyType) {
            key.errors.append("Type de clé «\u{00A0}k=\(key.keyType)\u{00A0}» inconnu (rsa ou ed25519).")
        }
        guard let p = tags["p"] else {
            key.errors.append("L’étiquette «\u{00A0}p=\u{00A0}» (clé publique) est obligatoire.")
            return key
        }
        let base64 = p.filter { !$0.isWhitespace }
        key.publicKey = base64
        if base64.isEmpty {
            key.revoked = true
            return key
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
            key.errors.append("La clé publique «\u{00A0}p=\u{00A0}» n’est pas du base64 valide.")
            return key
        }
        let bytes = [UInt8](data)
        if key.keyType == "ed25519" {
            if bytes.count == 32 { key.bits = 256 } else {
                key.errors.append("Clé Ed25519 de \(bytes.count) octets (32 attendus).")
            }
        } else if let bits = rsaModulusBits(bytes) {
            key.bits = bits
        } else {
            key.errors.append("Clé RSA illisible (DER SubjectPublicKeyInfo attendu).")
        }
        let flags = (tags["t"] ?? "").split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        key.testing = flags.contains("y")
        if let hashes = tags["h"], !hashes.lowercased().contains("sha256") {
            key.warnings.append("«\u{00A0}h=\(hashes)\u{00A0}» n’autorise pas SHA-256 (SHA-1 seul est refusé par les destinataires).")
        }
        if let service = tags["s"], !service.split(separator: ":").contains(where: { $0 == "*" || $0 == "email" }) {
            key.errors.append("«\u{00A0}s=\(service)\u{00A0}»\u{00A0}: la clé n’est pas utilisable pour le courriel.")
        }
        return key
    }

    // MARK: DER

    /// Longueur en bits du module d'une clé RSA : SubjectPublicKeyInfo (forme publiée par DKIM)
    /// ou RSAPublicKey (PKCS #1) nu.
    public static func rsaModulusBits(_ der: [UInt8]) -> Int? {
        var reader = DERReader(der)
        guard let outer = reader.read(tag: 0x30) else { return nil }
        var inner = DERReader(outer)
        // SubjectPublicKeyInfo : SEQUENCE { SEQUENCE { algorithme }, BIT STRING { RSAPublicKey } }
        if inner.peek == 0x30, let _ = inner.read(tag: 0x30), let bitString = inner.read(tag: 0x03), bitString.first == 0 {
            return rsaModulusBits(Array(bitString.dropFirst()))
        }
        // RSAPublicKey : SEQUENCE { INTEGER module, INTEGER exposant }
        inner = DERReader(outer)
        guard let modulus = inner.read(tag: 0x02), inner.read(tag: 0x02) != nil else { return nil }
        let significant = modulus.drop { $0 == 0 }
        guard let first = significant.first else { return nil }
        return (significant.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    struct DERReader {
        let bytes: [UInt8]
        var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { offset < bytes.count ? bytes[offset] : nil }

        /// Lit un élément de l'étiquette donnée ; renvoie son contenu.
        mutating func read(tag: UInt8) -> [UInt8]? {
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { return nil }
            var position = offset + 1
            var length = Int(bytes[position])
            position += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...4).contains(count), position + count <= bytes.count else { return nil }
                length = 0
                for byte in bytes[position..<(position + count)] { length = length << 8 | Int(byte) }
                position += count
            }
            guard length >= 0, position + length <= bytes.count else { return nil }
            offset = position + length
            return Array(bytes[position..<(position + length)])
        }
    }
}

/// Une clé trouvée pour un sélecteur.
public struct DKIMSelectorResult: Hashable, Sendable, Identifiable {
    public var id: String { selector }
    public var selector: String
    public var name: String
    public var key: DKIMKey?
    /// Échec de la requête (indéterminé).
    public var failure: String?
    public var findings: [MailFinding]

    public var status: MailStatus { findings.worstStatus }

    /// « RSA 2048 bits », « révoquée », « Ed25519 »…
    public var summary: String {
        guard let key else { return failure.map { "Échec\u{00A0}: \($0)" } ?? "Absent" }
        if key.revoked { return "Clé révoquée (p= vide)" }
        if !key.errors.isEmpty { return "Clé invalide" }
        let type = key.keyType == "ed25519" ? "Ed25519" : "RSA"
        return type + (key.bits.map { " \($0) bits" } ?? "") + (key.testing ? " · mode test" : "")
    }
}

public struct DKIMReport: Hashable, Sendable {
    public var domain: String
    /// Sélecteurs trouvés (clé publiée, valide ou non).
    public var found: [DKIMSelectorResult]
    /// Nombre de sélecteurs essayés.
    public var tried: Int
    public var failures: Int
    public var findings: [MailFinding]

    public var status: MailStatus { findings.worstStatus }

    public var summary: String {
        guard !found.isEmpty else { return "Aucun sélecteur courant trouvé (\(tried) essayés)" }
        return found.map { "\($0.selector)\u{00A0}: \($0.summary)" }.joined(separator: " · ")
    }
}

public enum DKIMAnalyzer {
    /// Sélecteurs courants, dans l'ordre d'essai (Microsoft 365, Google, Mailchimp, SendGrid,
    /// Mailgun, Zoho, Fastmail, Proton, hébergeurs…).
    public static let commonSelectors = [
        "selector1", "selector2", "google", "default", "k1", "k2", "k3", "s1", "s2", "mail", "dkim", "smtp",
        "mx", "email", "key1", "key2", "sig1", "s1024", "s2048", "mandrill", "mailjet", "zmail", "fm1", "fm2", "fm3",
        "protonmail", "protonmail2", "protonmail3", "everlytickey1", "mxvault", "pm", "cm", "dkim1", "mailo",
    ]

    /// Constats sur une clé.
    public static func findings(for key: DKIMKey, selector: String) -> [MailFinding] {
        var result: [MailFinding] = []
        for error in key.errors {
            result.append(MailFinding(.error, "Clé «\u{00A0}\(selector)\u{00A0}» invalide", error, fix: "Republier la clé fournie par le service d’envoi."))
        }
        for warning in key.warnings { result.append(MailFinding(.warning, "Clé «\u{00A0}\(selector)\u{00A0}»", warning)) }
        if key.revoked {
            result.append(MailFinding(.info, "Clé «\u{00A0}\(selector)\u{00A0}» révoquée",
                "p= est vide\u{00A0}: les signatures faites avec ce sélecteur échouent (normal après une rotation)."))
            return result
        }
        if key.testing {
            result.append(MailFinding(.warning, "Clé «\u{00A0}\(selector)\u{00A0}» en mode test (t=y)",
                "Les destinataires peuvent traiter les signatures en échec comme absentes.", fix: "Retirer t=y une fois la signature vérifiée."))
        }
        if let bits = key.bits, key.keyType == "rsa" {
            if bits < 1024 {
                result.append(MailFinding(.error, "Clé «\u{00A0}\(selector)\u{00A0}» de \(bits) bits",
                    "Une clé RSA de moins de 1024 bits est refusée (RFC 8301) et peut être cassée.", fix: "Générer une clé de 2048 bits."))
            } else if bits < 2048 {
                result.append(MailFinding(.warning, "Clé «\u{00A0}\(selector)\u{00A0}» de \(bits) bits",
                    "1024 bits reste accepté, mais 2048 bits est la taille recommandée.", fix: "Passer à une clé de 2048 bits à la prochaine rotation."))
            } else {
                result.append(MailFinding(.ok, "Clé «\u{00A0}\(selector)\u{00A0}» de \(bits) bits", "Taille recommandée."))
            }
        } else if key.keyType == "ed25519", key.bits != nil {
            result.append(MailFinding(.ok, "Clé «\u{00A0}\(selector)\u{00A0}» Ed25519", "Clé moderne (RFC 8463)\u{00A0}; garder aussi une clé RSA pour les anciens destinataires."))
        }
        return result
    }

    /// Lit la clé d'un sélecteur.
    public static func lookup(_ domain: String, selector: String, client: MailDNSClient) async -> DKIMSelectorResult {
        let name = "\(selector)._domainkey.\(MailDNSText.normalize(domain))"
        let answer = await client.query(name, .txt)
        var result = DKIMSelectorResult(selector: selector, name: name, key: nil, failure: answer.failureText, findings: [])
        guard let text = answer.values.first(where: DKIMKey.looksLikeDKIM) else { return result }
        let key = DKIMKey.parse(text)
        result.key = key
        result.findings = findings(for: key, selector: selector)
        return result
    }

    /// Essaie les sélecteurs donnés (les courants par défaut, plus ceux de l'utilisateur), quatre à la fois.
    public static func scan(_ domain: String, selectors: [String] = commonSelectors, client: MailDNSClient) async -> DKIMReport {
        var unique: [String] = []
        for selector in selectors.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
        where !selector.isEmpty && !unique.contains(selector) && MailDNSText.isDomainName(selector) {
            unique.append(selector)
        }
        let results = await mailConcurrentMap(unique, limit: 4, spacing: client.pacing / 2) { selector in
            await lookup(domain, selector: selector, client: client)
        }
        let found = results.filter { $0.key != nil }
        let failures = results.filter { $0.failure != nil }.count
        var report = DKIMReport(domain: MailDNSText.normalize(domain), found: found, tried: unique.count, failures: failures, findings: [])
        report.findings = found.flatMap(\.findings)
        let usable = found.filter { $0.key.map { !$0.revoked && $0.errors.isEmpty } ?? false }
        if found.isEmpty {
            if failures == unique.count {
                report.findings.append(MailFinding(.warning, "DKIM non vérifié", "Aucune requête n’a abouti."))
            } else {
                report.findings.append(MailFinding(.warning, "Aucun sélecteur DKIM courant",
                    "\(unique.count) sélecteurs courants essayés sans clé. Le domaine peut signer avec un sélecteur propre (visible dans l’en-tête DKIM-Signature, s=).",
                    fix: "Activer la signature DKIM chez le fournisseur de courriel, ou saisir le sélecteur utilisé."))
            }
        } else if usable.isEmpty {
            report.findings.append(MailFinding(.error, "Aucune clé DKIM utilisable", "Les clés trouvées sont révoquées ou invalides.",
                                               fix: "Publier une clé valide et activer la signature."))
        }
        return report
    }
}
