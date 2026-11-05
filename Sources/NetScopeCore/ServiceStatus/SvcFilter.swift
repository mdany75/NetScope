import Foundation
import Security

// Note 53 : « bloqué ici » plutôt que « en panne ». Un service injoignable d'un site peut être
// bloqué exprès par la FortiGate (filtrage web FortiGuard, filtrage DNS, contrôle des
// applications) ou par un autre filtre. Ces règles pures reconnaissent les traces laissées par
// ces filtres pendant le test depuis ce réseau : portail de blocage DNS, page de blocage,
// certificat de remplacement, redirection vers le portail du pare-feu.

/// Preuve qu'une adresse clé est bloquée par le filtrage de ce réseau.
public struct SvcBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Le DNS répond l'adresse d'un portail de blocage (FortiGuard, Cisco Umbrella) ou 0.0.0.0.
        case dnsSinkhole
        /// Page de blocage reçue à la place du site (filtrage web, contrôle des applications).
        case blockPage
        /// Certificat de remplacement non approuvé présenté par le pare-feu.
        case certificateReplacement
        /// Redirection vers le portail d'authentification ou de dérogation du pare-feu.
        case firewallPortal
    }

    public var kind: Kind
    /// Qui bloque (« FortiGuard (filtrage web de la FortiGate) », « Cisco Umbrella »).
    public var source: String
    /// Catégorie lue sur la page de blocage (« Social Networking »), si elle y figure.
    public var category: String?
    /// Ce qui a été observé (« DNS → 208.91.112.55 »).
    public var evidence: String

    public init(kind: Kind, source: String, category: String? = nil, evidence: String) {
        self.kind = kind
        self.source = source
        self.category = category
        self.evidence = evidence
    }

    public var kindLabel: String {
        switch kind {
        case .dnsSinkhole: return "Filtrage DNS"
        case .blockPage: return "Page de blocage"
        case .certificateReplacement: return "Certificat de remplacement"
        case .firewallPortal: return "Portail du pare-feu"
        }
    }

    /// Le blocage vient d'une FortiGate (FortiGuard, contrôle des applications, portail).
    public var isFortinet: Bool { source.contains("Forti") }

    /// « FortiGuard (filtrage web de la FortiGate) · catégorie Social Networking ».
    public var summary: String {
        source + (category.map { " · catégorie «\u{00A0}\($0)\u{00A0}»" } ?? "")
    }

    /// Ce que le technicien peut faire.
    public var advice: String {
        if isFortinet {
            switch kind {
            case .dnsSinkhole:
                return "Vérifier le profil de filtrage DNS de la FortiGate (Security Profiles › DNS Filter) et ses journaux."
            case .firewallPortal:
                return "Ce poste doit d’abord s’authentifier sur la FortiGate (portail captif ou dérogation FortiGuard)."
            case .blockPage, .certificateReplacement:
                return "Vérifier le profil de filtrage web (catégorie FortiGuard) ou le contrôle des applications de la politique de pare-feu, et les journaux Log & Report › Web Filter."
            }
        }
        return "Vérifier la politique du filtre (\(source)) et ses journaux."
    }
}

/// Règles de reconnaissance des blocages (pures, testées avec des réponses fixes).
public enum SvcFilterDetector {
    /// Portails de blocage DNS connus : adresse → qui bloque.
    public static let knownSinkholes: [String: String] = {
        var table: [String: String] = [
            // Portail de blocage par défaut du filtrage DNS FortiGuard (redirect-portal de la FortiGate).
            "208.91.112.55": "FortiGuard (filtrage DNS de la FortiGate)",
            "0.0.0.0": "filtre DNS (réponse 0.0.0.0)",
            "::": "filtre DNS (réponse ::)",
            "127.0.0.1": "filtre DNS (réponse locale 127.0.0.1)",
            "::1": "filtre DNS (réponse locale ::1)",
        ]
        // Pages de blocage de Cisco Umbrella (OpenDNS).
        for last in 104...110 { table["146.112.61.\(last)"] = "Cisco Umbrella (filtrage DNS)" }
        return table
    }()

    /// Éditeurs de pare-feu et de proxy reconnus dans l'émetteur d'un certificat.
    static let inspectionVendors: [(marker: String, name: String)] = [
        ("fortinet", "FortiGate"), ("fortigate", "FortiGate"), ("sophos", "Sophos"), ("palo alto", "Palo Alto"),
        ("watchguard", "WatchGuard"), ("sonicwall", "SonicWall"), ("zscaler", "Zscaler"), ("umbrella", "Cisco Umbrella"),
        ("netskope", "Netskope"), ("check point", "Check Point"), ("barracuda", "Barracuda"),
    ]

    /// Réponse DNS qui pointe vers un portail de blocage : toutes les adresses IPv4 (ou, sans IPv4,
    /// toutes les adresses) sont des portails connus ou ajoutés (`extraPortals`, ex. le
    /// « redirect-portal » propre à une FortiGate).
    public static func dnsBlock(host: String, addresses: [String], extraPortals: [String] = []) -> SvcBlock? {
        guard !addresses.isEmpty else { return nil }
        func source(_ address: String) -> String? {
            if extraPortals.contains(address) { return "portail de blocage du pare-feu" }
            return knownSinkholes[address]
        }
        let ipv4 = addresses.filter { !$0.contains(":") }
        let considered = ipv4.isEmpty ? addresses : ipv4
        guard considered.allSatisfy({ source($0) != nil }), let first = considered.first, let who = source(first) else { return nil }
        return SvcBlock(kind: .dnsSinkhole, source: who, evidence: "DNS\u{00A0}: \(host) → \(first)")
    }

    /// Éditeur du pare-feu ou du proxy qui a signé le certificat, ou nil (certificat public).
    public static func inspectionVendor(issuer: String?) -> String? {
        guard let lowered = issuer?.lowercased(), !lowered.isEmpty else { return nil }
        return inspectionVendors.first { lowered.contains($0.marker) }?.name
    }

    /// Certificat de remplacement : la poignée de main TLS a échoué sur un certificat signé par le
    /// pare-feu. Une page de blocage HTTPS en « inspection de certificat » se présente ainsi ; une
    /// inspection SSL complète sans l'autorité installée sur ce Mac aussi (le bilan le précise).
    public static func certificateBlock(issuer: String?, tlsFailed: Bool) -> SvcBlock? {
        guard tlsFailed, let issuer, let vendor = inspectionVendor(issuer: issuer) else { return nil }
        let source = vendor == "FortiGate" ? "FortiGate (certificat de remplacement)" : "\(vendor) (certificat de remplacement)"
        return SvcBlock(kind: .certificateReplacement, source: source,
                        evidence: "certificat «\u{00A0}\(issuer)\u{00A0}» non approuvé par ce Mac\u{00A0}: page de blocage HTTPS, ou inspection SSL sans l’autorité du pare-feu installée")
    }

    /// Page de blocage ou redirection vers le pare-feu, d'après la première réponse HTTPS.
    public static func pageBlock(status: Int?, location: String?, body: String) -> SvcBlock? {
        if let location, !location.isEmpty {
            let lowered = location.lowercased()
            if lowered.contains("fgtauth") || lowered.contains("/fgtauth") {
                return SvcBlock(kind: .firewallPortal, source: "FortiGate (portail d’authentification)",
                                evidence: "redirection vers \(shortURL(location))")
            }
            let fortiPorts = [":8008/", ":8010/", ":8015/", ":8020/"]
            if lowered.contains("fortiguard") || fortiPorts.contains(where: { lowered.contains($0) }) {
                return SvcBlock(kind: .firewallPortal, source: "FortiGuard (dérogation de la FortiGate)",
                                evidence: "redirection vers \(shortURL(location))")
            }
            if lowered.contains("block.opendns.com") || lowered.contains("umbrella.com") {
                return SvcBlock(kind: .blockPage, source: "Cisco Umbrella (page de blocage)",
                                evidence: "redirection vers \(shortURL(location))")
            }
        }
        let text = lines(String(body.prefix(16_384)))
        let lowered = text.lowercased() + " " + body.prefix(16_384).lowercased()
        let phrases = ["web page blocked", "web filter violation", "application blocked", "page web bloquée",
                       "violation of your internet usage policy", "violation de votre politique", "this site is blocked",
                       "site bloqué", "access to this site is blocked", "fortiguard web filtering", "url blocked",
                       "application control violation", "blocked by your administrator", "bloqué par votre administrateur"]
        guard phrases.contains(where: { lowered.contains($0) }) else { return nil }
        let fortinet = ["fortiguard", "fortinet", "fortigate", "%%ftgd", "ftgd_re_eval"].contains { lowered.contains($0) }
            || lowered.contains("web filter violation")
        let source: String
        if lowered.contains("application blocked") || lowered.contains("application control") {
            source = fortinet || lowered.contains("application control violation") ? "Contrôle des applications (FortiGate)" : "Contrôle des applications"
        } else if fortinet {
            source = "FortiGuard (filtrage web de la FortiGate)"
        } else if lowered.contains("umbrella") || lowered.contains("opendns") {
            source = "Cisco Umbrella (page de blocage)"
        } else {
            source = "pare-feu ou proxy de filtrage"
        }
        let code = status.map { "HTTP \($0)" } ?? "réponse"
        return SvcBlock(kind: .blockPage, source: source, category: category(in: text),
                        evidence: "\(code) avec une page de blocage au lieu du site")
    }

    /// Catégorie publiée sur la page de blocage (« Category: Social Networking »).
    /// `text` : une ligne par bloc de la page (voir `lines`).
    static func category(in text: String) -> String? {
        let pattern = "(?:Category|Catégorie|Categorie)[ \\t]*[:：][ \\t]*([^\\n]{2,80})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), let found = Range(match.range(at: 1), in: text) else { return nil }
        var value = String(text[found])
        // Page sur une seule ligne : la catégorie s'arrête au champ suivant.
        for stop in [" URL", " Adresse", " User", " Utilisateur", " Group", " Groupe", " To have", " Pour faire", " Powered by"] {
            if let cut = value.range(of: stop, options: .caseInsensitive) { value = String(value[..<cut.lowerBound]) }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".;,")))
        return value.isEmpty || value.hasPrefix("%%") || value.count > 60 ? nil : value
    }

    /// Texte de la page, une ligne par paragraphe, titre ou cellule (balises retirées).
    static func lines(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?s)<(script|style)[^>]*>.*?</\\1>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br\\s*/?>|</(p|div|li|h[1-6]|td|tr|title)>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&rsquo;": "’"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "[ \\t\\r\\u{00A0}]+", with: " ", options: .regularExpression)
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Coupure sans page de blocage, juste après une résolution DNS réussie : souvent le contrôle des
    /// applications ou le filtrage web d'un pare-feu (FortiGate en mode flux, inspection de
    /// certificat) ; nil si rien ne le suggère.
    public static func silentBlockHint(_ endpoints: [SvcEndpointResult]) -> String? {
        let failed = endpoints.filter { !$0.isReachable }
        guard !failed.isEmpty, failed.count == endpoints.count,
              failed.allSatisfy({ !$0.addresses.isEmpty && [.connect, .tls, .timeout].contains($0.failure) }) else { return nil }
        let resets = failed.filter { ($0.detail ?? "").contains("coupée") || $0.failure == .tls || $0.failure == .timeout }
        guard !resets.isEmpty else { return nil }
        return "Le nom se résout mais la connexion est coupée\u{00A0}: c’est souvent le contrôle des applications ou le filtrage web du pare-feu, sans page de blocage. Vérifier les journaux de la FortiGate (Log & Report › Application Control et Web Filter)."
    }

    private static func shortURL(_ text: String) -> String {
        text.count > 80 ? String(text.prefix(79)) + "…" : text
    }
}

/// Lecture de l'émetteur d'un certificat (poignée de main TLS du test depuis ce réseau).
public enum SvcCertificate {
    /// « Fortinet_CA_SSL · Fortinet » : nom commun et organisation de l'émetteur du certificat du
    /// serveur, ou le résumé du certificat suivant de la chaîne.
    public static func issuer(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        if let name = issuerName(leaf) { return name }
        if chain.count > 1, let summary = SecCertificateCopySubjectSummary(chain[1]) as String? { return summary }
        return nil
    }

    static func issuerName(_ certificate: SecCertificate) -> String? {
        let keys = [kSecOIDX509V1IssuerName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let issuer = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
              let parts = issuer[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        func value(_ oid: String) -> String? {
            parts.first { ($0[kSecPropertyKeyLabel as String] as? String) == oid }?[kSecPropertyKeyValue as String] as? String
        }
        let names = [value("2.5.4.3"), value("2.5.4.10")].compactMap { $0 }.filter { !$0.isEmpty }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }
}
