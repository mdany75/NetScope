import Foundation

// BIMI (logo de la marque), MTA-STS (RFC 8461, TLS obligatoire vers les MX) et TLS-RPT
// (RFC 8460, rapports d'échec TLS) : lecture des TXT, du fichier de politique MTA-STS et
// constats.

// MARK: - BIMI

public struct BIMIRecord: Hashable, Sendable {
    public var text: String
    public var tags: MailTagList
    /// Adresse du logo SVG (vide : le domaine refuse BIMI).
    public var logo: String?
    /// Adresse du certificat VMC/CMC (.pem).
    public var authority: String?
    public var errors: [String]

    public static func isBIMI(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "").hasPrefix("v=bimi1")
    }

    public static func parse(_ text: String) -> BIMIRecord {
        let tags = MailTagList.parse(text)
        var record = BIMIRecord(text: text, tags: tags, logo: tags["l"], authority: tags["a"], errors: tags.errors)
        if tags.keys.first != "v" || tags["v"] != "BIMI1" { record.errors.append("L’enregistrement doit commencer par « v=BIMI1 ».") }
        if let logo = record.logo, !logo.isEmpty {
            if !logo.lowercased().hasPrefix("https://") { record.errors.append("Le logo l= doit être servi en HTTPS.") }
            if !logo.lowercased().hasSuffix(".svg") { record.errors.append("Le logo l= doit être un fichier SVG (profil SVG Tiny PS).") }
        }
        if let authority = record.authority, !authority.isEmpty, !authority.lowercased().hasPrefix("https://") {
            record.errors.append("Le certificat a= doit être servi en HTTPS.")
        }
        return record
    }
}

public struct BIMIReport: Hashable, Sendable {
    public var domain: String
    public var record: BIMIRecord?
    public var findings: [MailFinding]
    public var status: MailStatus { findings.worstStatus }

    public var summary: String {
        guard let record else { return "Aucun enregistrement BIMI" }
        if (record.logo ?? "").isEmpty { return "BIMI refusé (l= vide)" }
        return (record.authority ?? "").isEmpty ? "Logo sans certificat VMC" : "Logo et certificat VMC"
    }
}

// MARK: - MTA-STS

/// Fichier de politique « https://mta-sts.<domaine>/.well-known/mta-sts.txt ».
public struct MTASTSPolicy: Hashable, Sendable {
    public var version: String?
    /// « enforce », « testing » ou « none ».
    public var mode: String?
    public var mx: [String]
    public var maxAge: Int?
    public var errors: [String]

    public static func parse(_ text: String) -> MTASTSPolicy {
        var policy = MTASTSPolicy(version: nil, mode: nil, mx: [], maxAge: nil, errors: [])
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else {
                policy.errors.append("Ligne « \(line) » sans « : ».")
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "version": policy.version = value
            case "mode": policy.mode = value.lowercased()
            case "mx": policy.mx.append(MailDNSText.normalize(value))
            case "max_age": policy.maxAge = Int(value)
            default: break
            }
        }
        if policy.version != "STSv1" { policy.errors.append("« version: STSv1 » est obligatoire.") }
        if let mode = policy.mode {
            if !["enforce", "testing", "none"].contains(mode) { policy.errors.append("Mode « \(mode) » inconnu (enforce, testing ou none).") }
        } else {
            policy.errors.append("La ligne « mode: » est obligatoire.")
        }
        if policy.maxAge == nil { policy.errors.append("La ligne « max_age: » (en secondes) est obligatoire.") }
        if let age = policy.maxAge, age > 31_557_600 { policy.errors.append("max_age dépasse un an (31557600 s).") }
        if policy.mx.isEmpty && policy.mode != "none" { policy.errors.append("Au moins une ligne « mx: » est obligatoire.") }
        return policy
    }

    /// « *.mail.protection.outlook.com » couvre « exemple-ca.mail.protection.outlook.com »
    /// (une seule étiquette à gauche), un nom exact se couvre lui-même.
    public static func matches(pattern: String, host: String) -> Bool {
        let pattern = MailDNSText.normalize(pattern)
        let host = MailDNSText.normalize(host)
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(1))
            guard host.hasSuffix(suffix) else { return false }
            let left = host.dropLast(suffix.count)
            return !left.isEmpty && !left.contains(".")
        }
        return pattern == host
    }

    public func covers(_ host: String) -> Bool { mx.contains { Self.matches(pattern: $0, host: host) } }
}

public struct MTASTSReport: Hashable, Sendable {
    public var domain: String
    /// TXT « _mta-sts.<domaine> » (v=STSv1; id=…).
    public var record: String?
    public var id: String?
    public var policyURL: URL?
    public var policyText: String?
    public var policy: MTASTSPolicy?
    public var fetchError: String?
    public var findings: [MailFinding]
    public var status: MailStatus { findings.worstStatus }

    public var summary: String {
        guard record != nil else { return "Aucune politique MTA-STS" }
        guard let policy else { return "Politique illisible" }
        return "mode \(policy.mode ?? "?")" + (policy.maxAge.map { " · max_age \($0)" } ?? "")
    }
}

// MARK: - TLS-RPT

public struct TLSRPTRecord: Hashable, Sendable {
    public var text: String
    public var tags: MailTagList
    public var rua: [String]
    public var errors: [String]

    public static func isTLSRPT(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "").hasPrefix("v=tlsrptv1")
    }

    public static func parse(_ text: String) -> TLSRPTRecord {
        let tags = MailTagList.parse(text)
        var record = TLSRPTRecord(text: text, tags: tags, rua: [], errors: tags.errors)
        if tags.keys.first != "v" || tags["v"] != "TLSRPTv1" { record.errors.append("L’enregistrement doit commencer par « v=TLSRPTv1 ».") }
        guard let rua = tags["rua"] else {
            record.errors.append("L’étiquette « rua= » (adresse des rapports) est obligatoire.")
            return record
        }
        for uri in MailURI.list(rua) {
            let lower = uri.lowercased()
            if lower.hasPrefix("https://") || MailURI.mailbox(uri) != nil {
                record.rua.append(uri)
            } else {
                record.errors.append("Adresse « \(uri) » invalide (mailto: ou https: attendu).")
            }
        }
        return record
    }
}

public struct TLSRPTReport: Hashable, Sendable {
    public var domain: String
    public var record: TLSRPTRecord?
    public var findings: [MailFinding]
    public var status: MailStatus { findings.worstStatus }

    public var summary: String {
        guard let record else { return "Aucun enregistrement TLS-RPT" }
        return record.errors.isEmpty ? "Rapports vers \(record.rua.joined(separator: ", "))" : "Enregistrement invalide"
    }
}

// MARK: - Analyses

public enum MailPolicyAnalyzer {
    /// BIMI au sélecteur « default » ; `dmarc` sert à vérifier la politique exigée (quarantine ou reject à 100 %).
    public static func bimi(_ domain: String, dmarc: DMARCRecord?, client: MailDNSClient) async -> BIMIReport {
        let name = MailDNSText.normalize(domain)
        let answer = await client.query("default._bimi.\(name)", .txt)
        var report = BIMIReport(domain: name, record: nil, findings: [])
        if let failure = answer.failureText {
            report.findings.append(MailFinding(.info, "BIMI non vérifié", failure))
            return report
        }
        guard let text = answer.values.first(where: BIMIRecord.isBIMI) else {
            report.findings.append(MailFinding(.info, "Aucun BIMI",
                "Facultatif\u{00A0}: BIMI affiche le logo de la marque dans Gmail, Apple Mail et Yahoo, une fois DMARC appliqué."))
            return report
        }
        let record = BIMIRecord.parse(text)
        report.record = record
        for error in record.errors { report.findings.append(MailFinding(.error, "Syntaxe BIMI", error)) }
        if (record.logo ?? "").isEmpty {
            report.findings.append(MailFinding(.info, "BIMI refusé", "l= est vide\u{00A0}: le domaine demande de n’afficher aucun logo."))
        } else {
            if (record.authority ?? "").isEmpty {
                report.findings.append(MailFinding(.warning, "Pas de certificat VMC (a=)",
                    "Gmail et Apple Mail n’affichent le logo qu’avec un certificat VMC ou CMC.", fix: "Obtenir un certificat VMC/CMC et l’indiquer dans a=."))
            }
            if !(dmarc?.isEnforced ?? false) {
                report.findings.append(MailFinding(.warning, "DMARC pas assez strict pour BIMI",
                    "BIMI exige DMARC en quarantine ou reject sur 100\u{00A0}% des messages.", fix: "Durcir la politique DMARC."))
            }
            if record.errors.isEmpty && !report.findings.contains(where: { $0.status >= .warning }) {
                report.findings.append(MailFinding(.ok, "BIMI publié", "Logo et certificat déclarés."))
            }
        }
        return report
    }

    /// MTA-STS : TXT, puis fichier de politique (et couverture des MX donnés).
    public static func mtaSTS(_ domain: String, mxHosts: [String], client: MailDNSClient) async -> MTASTSReport {
        let name = MailDNSText.normalize(domain)
        var report = MTASTSReport(domain: name, record: nil, id: nil, policyURL: nil, policyText: nil, policy: nil, fetchError: nil, findings: [])
        let answer = await client.query("_mta-sts.\(name)", .txt)
        if let failure = answer.failureText {
            report.findings.append(MailFinding(.warning, "MTA-STS non vérifié", failure))
            return report
        }
        let records = answer.values.filter { $0.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix("v=stsv1") }
        guard let text = records.first else {
            report.findings.append(MailFinding(.warning, "Aucune politique MTA-STS",
                "Sans MTA-STS, un attaquant sur le chemin peut forcer l’envoi en clair vers vos MX (STARTTLS retiré).",
                fix: "Publier _mta-sts.\(name) (v=STSv1; id=…) et le fichier https://mta-sts.\(name)/.well-known/mta-sts.txt, d’abord en mode testing."))
            return report
        }
        report.record = text
        let tags = MailTagList.parse(text)
        report.id = tags["id"]
        if records.count > 1 { report.findings.append(MailFinding(.error, "Plusieurs TXT MTA-STS", "Un seul « v=STSv1 » est permis.")) }
        if tags["v"] != "STSv1" { report.findings.append(MailFinding(.error, "Syntaxe MTA-STS", "« v=STSv1 » attendu au début.")) }
        if let id = tags["id"] {
            if !(1...32).contains(id.count) || !id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                report.findings.append(MailFinding(.error, "Identifiant « id=\(id) » invalide", "1 à 32 lettres ou chiffres."))
            }
        } else {
            report.findings.append(MailFinding(.error, "Identifiant id= manquant", "Le TXT doit porter un id= qui change à chaque modification de la politique."))
        }
        guard let url = URL(string: "https://mta-sts.\(name)/.well-known/mta-sts.txt") else { return report }
        report.policyURL = url
        do {
            let body = try await client.fetchText(url)
            report.policyText = body
            let policy = MTASTSPolicy.parse(body)
            report.policy = policy
            for error in policy.errors { report.findings.append(MailFinding(.error, "Fichier de politique", error)) }
            switch policy.mode {
            case "enforce":
                report.findings.append(MailFinding(.ok, "MTA-STS appliqué (enforce)", "Les expéditeurs compatibles exigent TLS et un certificat valide."))
            case "testing":
                report.findings.append(MailFinding(.warning, "MTA-STS en mode testing",
                    "Les échecs TLS sont signalés (TLS-RPT) mais les messages passent quand même.", fix: "Passer en « mode: enforce » après quelques semaines de rapports propres."))
            case "none":
                report.findings.append(MailFinding(.warning, "MTA-STS désactivé (mode none)", "La politique est publiée mais ne s’applique pas."))
            default: break
            }
            if let age = policy.maxAge, age < 86_400 {
                report.findings.append(MailFinding(.warning, "max_age court (\(age) s)", "Une politique gardée moins d’un jour protège mal.",
                                                   fix: "Viser 604800 s (une semaine) ou plus."))
            }
            if policy.mode != "none" {
                for host in mxHosts where !policy.covers(host) {
                    report.findings.append(MailFinding(.error, "MX \(host) hors politique",
                        "Aucune ligne mx: ne couvre ce serveur\u{00A0}: en mode enforce, les messages vers lui seraient refusés.",
                        fix: "Ajouter « mx: \(host) » (ou un motif *.) au fichier de politique."))
                }
            }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            report.fetchError = text
            report.findings.append(MailFinding(.error, "Fichier de politique inaccessible",
                "\(url.absoluteString)\u{00A0}: \(text)", fix: "Servir le fichier en HTTPS avec un certificat valide pour mta-sts.\(name), sans redirection."))
        }
        return report
    }

    /// TLS-RPT : TXT « _smtp._tls.<domaine> ».
    public static func tlsRPT(_ domain: String, client: MailDNSClient) async -> TLSRPTReport {
        let name = MailDNSText.normalize(domain)
        var report = TLSRPTReport(domain: name, record: nil, findings: [])
        let answer = await client.query("_smtp._tls.\(name)", .txt)
        if let failure = answer.failureText {
            report.findings.append(MailFinding(.info, "TLS-RPT non vérifié", failure))
            return report
        }
        let records = answer.values.filter(TLSRPTRecord.isTLSRPT)
        guard let text = records.first else {
            report.findings.append(MailFinding(.info, "Aucun TLS-RPT",
                "Sans TLS-RPT, les échecs de chiffrement vers vos MX restent invisibles.",
                fix: "Publier « _smtp._tls.\(name) TXT \"v=TLSRPTv1; rua=mailto:tlsrpt@\(name)\" »."))
            return report
        }
        let record = TLSRPTRecord.parse(text)
        report.record = record
        if records.count > 1 { report.findings.append(MailFinding(.error, "Plusieurs TXT TLS-RPT", "Un seul « v=TLSRPTv1 » est permis.")) }
        for error in record.errors { report.findings.append(MailFinding(.error, "Syntaxe TLS-RPT", error)) }
        if record.errors.isEmpty { report.findings.append(MailFinding(.ok, "TLS-RPT publié", "Rapports vers " + record.rua.joined(separator: ", ") + ".")) }
        return report
    }
}
