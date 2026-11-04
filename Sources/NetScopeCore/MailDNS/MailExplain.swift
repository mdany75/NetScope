import Foundation

// Explication en français de chaque terme d'un enregistrement (SPF, DMARC, DKIM, BIMI, MTA-STS,
// TLS-RPT), pour le tableau « étiquette / valeur / signification » de l'outil.

public enum MailRecordKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case spf, dmarc, dkim, bimi, mtasts, tlsrpt

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .spf: return "SPF"
        case .dmarc: return "DMARC"
        case .dkim: return "DKIM"
        case .bimi: return "BIMI"
        case .mtasts: return "MTA-STS"
        case .tlsrpt: return "TLS-RPT"
        }
    }

    /// Nom interrogé pour ce domaine (DKIM : avec le sélecteur).
    public func recordName(domain: String, selector: String = "selector1") -> String {
        let name = MailDNSText.normalize(domain)
        switch self {
        case .spf: return name
        case .dmarc: return "_dmarc.\(name)"
        case .dkim: return "\(selector)._domainkey.\(name)"
        case .bimi: return "default._bimi.\(name)"
        case .mtasts: return "_mta-sts.\(name)"
        case .tlsrpt: return "_smtp._tls.\(name)"
        }
    }
}

public struct MailTagExplanation: Hashable, Sendable, Identifiable {
    public var id: Int
    public var tag: String
    public var value: String
    public var meaning: String
    public var status: MailStatus
}

public enum MailExplain {
    // MARK: SPF

    public static func spf(_ record: SPFRecord) -> [MailTagExplanation] {
        var rows = [MailTagExplanation(id: 0, tag: "v", value: "spf1", meaning: "Version\u{00A0}: enregistrement SPF.", status: .ok)]
        for (index, term) in record.terms.enumerated() {
            rows.append(MailTagExplanation(id: index + 1, tag: term.kind == .modifier ? "modificateur" : term.kind.rawValue,
                                           value: term.raw, meaning: meaning(of: term), status: status(of: term)))
        }
        return rows
    }

    static func status(of term: SPFTerm) -> MailStatus {
        switch term.kind {
        case .unknown: return .error
        case .all: return term.qualifier == "+" ? .error : (term.qualifier == "?" ? .warning : .ok)
        case .ptr: return .warning
        default: return .ok
        }
    }

    static func meaning(of term: SPFTerm) -> String {
        let action: String
        switch term.qualifier {
        case "-": action = "Refuse"
        case "~": action = "Marque comme suspects"
        case "?": action = "Ne se prononce pas sur"
        default: action = "Autorise"
        }
        let target = term.targetDomain ?? "ce domaine"
        let cost = " (1 recherche DNS)"
        switch term.kind {
        case .all:
            switch term.qualifier {
            case "-": return "Tous les autres serveurs échouent (refus)."
            case "~": return "Tous les autres serveurs échouent légèrement (marqués suspects)."
            case "?": return "Résultat neutre pour les autres serveurs\u{00A0}: presque aucune protection."
            default: return "Tous les serveurs d’Internet réussissent\u{00A0}: à corriger."
            }
        case .include: return "\(action) les serveurs listés par le SPF de \(target)" + cost + " et ses propres recherches."
        case .a: return "\(action) les adresses A et AAAA de \(target)" + cost + "."
        case .mx: return "\(action) les serveurs MX de \(target)" + cost + ", plus une recherche par MX."
        case .ip4: return "\(action) le réseau IPv4 \(term.value ?? "")."
        case .ip6: return "\(action) le réseau IPv6 \(term.value ?? "")."
        case .exists: return "\(action) l’expéditeur si le nom \(term.value ?? "") existe" + cost + "."
        case .ptr: return "\(action) les serveurs dont le DNS inverse est dans \(target)" + cost + "\u{00A0}; déconseillé."
        case .redirect: return "Si rien ne correspond, utilise le SPF de \(term.value ?? "")" + cost + "."
        case .exp: return "Texte d’explication renvoyé en cas d’échec (\(term.value ?? ""))."
        case .modifier: return "Modificateur inconnu, ignoré."
        case .unknown: return "Mécanisme inconnu\u{00A0}: tout l’enregistrement est invalide (permerror)."
        }
    }

    // MARK: Étiquettes

    public static func tags(_ kind: MailRecordKind, text: String) -> [MailTagExplanation] {
        let list = MailTagList.parse(text)
        return list.tags.enumerated().map { index, tag in
            let (meaning, status) = explain(kind, key: tag.key, value: tag.value)
            return MailTagExplanation(id: index, tag: tag.key, value: tag.value, meaning: meaning, status: status)
        }
    }

    /// Lignes « clé: valeur » du fichier de politique MTA-STS.
    public static func mtaSTSPolicy(_ text: String) -> [MailTagExplanation] {
        var rows: [MailTagExplanation] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let meaning: String
            var status = MailStatus.ok
            switch key {
            case "version": meaning = "Version de la politique (STSv1)."
            case "mode":
                switch value.lowercased() {
                case "enforce": meaning = "Appliquée\u{00A0}: TLS et certificat valide exigés vers les MX listés."
                case "testing": meaning = "Essai\u{00A0}: les échecs sont signalés (TLS-RPT), les messages passent."; status = .warning
                case "none": meaning = "Désactivée."; status = .warning
                default: meaning = "Mode inconnu."; status = .error
                }
            case "mx": meaning = "Serveur MX autorisé (un « * » remplace une seule étiquette)."
            case "max_age":
                let seconds = Int(value) ?? 0
                meaning = "Durée de mise en cache\u{00A0}: \(duration(seconds))."
                if seconds < 86_400 { status = .warning }
            default: meaning = "Ligne inconnue, ignorée."; status = .info
            }
            rows.append(MailTagExplanation(id: rows.count, tag: key, value: value, meaning: meaning, status: status))
        }
        return rows
    }

    static func duration(_ seconds: Int) -> String {
        if seconds >= 86_400 { return "\(seconds / 86_400)\u{00A0}j" }
        if seconds >= 3600 { return "\(seconds / 3600)\u{00A0}h" }
        return "\(seconds)\u{00A0}s"
    }

    static func policy(_ value: String) -> (String, MailStatus) {
        switch value.lowercased() {
        case "none": return ("aucune action (surveillance seulement)", .warning)
        case "quarantine": return ("aux indésirables (quarantaine)", .ok)
        case "reject": return ("refus à la réception", .ok)
        default: return ("valeur inconnue", .error)
        }
    }

    static func explain(_ kind: MailRecordKind, key: String, value: String) -> (String, MailStatus) {
        switch (kind, key) {
        case (.dmarc, "v"): return value == "DMARC1" ? ("Version\u{00A0}: DMARC1.", .ok) : ("Version invalide (DMARC1 attendu).", .error)
        case (.dmarc, "p"):
            let (text, status) = policy(value)
            return ("Politique du domaine\u{00A0}: " + text + ".", status)
        case (.dmarc, "sp"):
            let (text, status) = policy(value)
            return ("Politique des sous-domaines\u{00A0}: " + text + ".", status)
        case (.dmarc, "np"):
            let (text, status) = policy(value)
            return ("Politique des sous-domaines inexistants\u{00A0}: " + text + ".", status)
        case (.dmarc, "pct"):
            let pct = Int(value) ?? -1
            return ("Part des messages en échec à qui la politique s’applique\u{00A0}: \(value)\u{00A0}%.", pct == 100 ? .ok : (pct < 0 || pct > 100 ? .error : .warning))
        case (.dmarc, "rua"): return ("Adresses des rapports agrégés quotidiens.", MailURI.list(value).allSatisfy { MailURI.mailbox($0) != nil } ? .ok : .error)
        case (.dmarc, "ruf"): return ("Adresses des rapports d’échec détaillés (peu de destinataires en envoient).", MailURI.list(value).allSatisfy { MailURI.mailbox($0) != nil } ? .ok : .error)
        case (.dmarc, "adkim"): return (value == "s" ? "Alignement DKIM strict (même nom exact)." : (value == "r" ? "Alignement DKIM souple (même domaine organisationnel)." : "Valeur invalide (r ou s)."), value == "r" || value == "s" ? .ok : .error)
        case (.dmarc, "aspf"): return (value == "s" ? "Alignement SPF strict (même nom exact)." : (value == "r" ? "Alignement SPF souple (même domaine organisationnel)." : "Valeur invalide (r ou s)."), value == "r" || value == "s" ? .ok : .error)
        case (.dmarc, "fo"): return ("Quand envoyer un rapport d’échec\u{00A0}: 0 = SPF et DKIM échouent, 1 = l’un des deux, d = DKIM, s = SPF.", .ok)
        case (.dmarc, "ri"): return ("Intervalle des rapports agrégés\u{00A0}: \(duration(Int(value) ?? 0)).", Int(value) == nil ? .error : .ok)
        case (.dmarc, "rf"): return ("Format des rapports d’échec (afrf).", .ok)
        case (.dmarc, "psd"), (.dmarc, "t"): return ("Étiquette de DMARCbis (projet), ignorée par la plupart des destinataires.", .info)

        case (.dkim, "v"): return ("Version\u{00A0}: DKIM1.", value == "DKIM1" ? .ok : .error)
        case (.dkim, "k"): return ("Type de clé\u{00A0}: \(value == "ed25519" ? "Ed25519" : "RSA").", ["rsa", "ed25519"].contains(value.lowercased()) ? .ok : .error)
        case (.dkim, "p"):
            if value.isEmpty { return ("Clé vide\u{00A0}: sélecteur révoqué.", .info) }
            let key = DKIMKey.parse("p=" + value)
            if let bits = key.bits { return ("Clé publique de \(bits) bits.", bits >= 2048 ? .ok : (bits >= 1024 ? .warning : .error)) }
            return ("Clé publique illisible.", .error)
        case (.dkim, "t"): return (value.contains("y") ? "Mode test\u{00A0}: les échecs peuvent être ignorés." : "Options (s\u{00A0}: le domaine doit correspondre exactement).", value.contains("y") ? .warning : .ok)
        case (.dkim, "h"): return ("Algorithmes de hachage acceptés.", value.lowercased().contains("sha256") ? .ok : .warning)
        case (.dkim, "s"): return ("Services autorisés (* ou email).", .ok)
        case (.dkim, "n"): return ("Note pour les administrateurs.", .info)
        case (.dkim, "g"): return ("Restriction de l’identité (ancienne étiquette).", .info)

        case (.bimi, "v"): return ("Version\u{00A0}: BIMI1.", value == "BIMI1" ? .ok : .error)
        case (.bimi, "l"): return (value.isEmpty ? "Aucun logo (le domaine refuse BIMI)." : "Adresse du logo SVG.", value.isEmpty || value.lowercased().hasPrefix("https://") ? .ok : .error)
        case (.bimi, "a"): return (value.isEmpty ? "Aucun certificat VMC." : "Certificat VMC/CMC qui prouve la marque.", value.isEmpty ? .warning : .ok)

        case (.mtasts, "v"): return ("Version\u{00A0}: STSv1.", value == "STSv1" ? .ok : .error)
        case (.mtasts, "id"): return ("Identifiant de la politique\u{00A0}: le changer à chaque modification du fichier.", .ok)

        case (.tlsrpt, "v"): return ("Version\u{00A0}: TLSRPTv1.", value == "TLSRPTv1" ? .ok : .error)
        case (.tlsrpt, "rua"): return ("Où envoyer les rapports quotidiens d’échec TLS (mailto: ou https:).", .ok)

        default: return ("Étiquette inconnue, ignorée.", .info)
        }
    }
}
