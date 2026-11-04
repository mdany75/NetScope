import Foundation

// DMARC (RFC 7489) : lecture de « _dmarc.<domaine> » (ou du domaine organisationnel), politique
// p/sp, pourcentage, adresses de rapport rua/ruf (et leur autorisation hors domaine), alignements.

public struct DMARCRecord: Hashable, Sendable {
    public var text: String
    public var tags: MailTagList
    public var policy: String?
    public var subdomainPolicy: String?
    public var percent: Int
    public var rua: [String]
    public var ruf: [String]
    /// « r » (souple, par défaut) ou « s » (strict).
    public var adkim: String
    public var aspf: String
    public var failureOptions: String
    public var interval: Int
    /// Fautes qui rendent l'enregistrement invalide ou en partie ignoré.
    public var errors: [String]
    public var warnings: [String]

    public static func isDMARC(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "").hasPrefix("v=dmarc1")
    }

    public static func parse(_ text: String) -> DMARCRecord {
        let tags = MailTagList.parse(text)
        var record = DMARCRecord(text: text, tags: tags, policy: nil, subdomainPolicy: nil, percent: 100, rua: [], ruf: [],
                                 adkim: "r", aspf: "r", failureOptions: "0", interval: 86_400, errors: tags.errors, warnings: [])
        let policies: Set<String> = ["none", "quarantine", "reject"]
        if tags.tags.first?.key != "v" || tags["v"] != "DMARC1" {
            record.errors.append("L’enregistrement doit commencer par « v=DMARC1 » (en majuscules).")
        }
        if let p = tags["p"] {
            if policies.contains(p.lowercased()) { record.policy = p.lowercased() } else {
                record.errors.append("Politique « p=\(p) » inconnue (none, quarantine ou reject).")
            }
        } else {
            record.errors.append("La politique « p= » est obligatoire.")
        }
        if tags.keys.count >= 2, tags.keys[1] != "p", tags["p"] != nil {
            record.warnings.append("« p= » devrait suivre immédiatement « v=DMARC1 ».")
        }
        if let sp = tags["sp"] {
            if policies.contains(sp.lowercased()) { record.subdomainPolicy = sp.lowercased() } else {
                record.errors.append("Politique de sous-domaine « sp=\(sp) » inconnue.")
            }
        }
        if let pct = tags["pct"] {
            if let value = Int(pct), (0...100).contains(value) { record.percent = value } else {
                record.errors.append("« pct=\(pct) » doit être un entier de 0 à 100.")
            }
        }
        for (key, target) in [("rua", \DMARCRecord.rua), ("ruf", \DMARCRecord.ruf)] {
            guard let value = tags[key] else { continue }
            var list: [String] = []
            for uri in MailURI.list(value) {
                if let mailbox = MailURI.mailbox(uri) { list.append(mailbox) } else {
                    record.errors.append("Adresse « \(uri) » invalide dans \(key)= (forme attendue\u{00A0}: mailto:dmarc@exemple.ca).")
                }
            }
            record[keyPath: target] = list
        }
        for key in ["adkim", "aspf"] {
            guard let value = tags[key] else { continue }
            if value == "r" || value == "s" {
                if key == "adkim" { record.adkim = value } else { record.aspf = value }
            } else {
                record.errors.append("« \(key)=\(value) » doit valoir r (souple) ou s (strict).")
            }
        }
        if let fo = tags["fo"] {
            let options = fo.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            if options.allSatisfy({ ["0", "1", "d", "s"].contains($0) }) { record.failureOptions = fo } else {
                record.errors.append("« fo=\(fo) » : options permises 0, 1, d et s.")
            }
        }
        if let ri = tags["ri"] {
            if let value = Int(ri), value > 0 { record.interval = value } else {
                record.errors.append("« ri=\(ri) » doit être un nombre de secondes.")
            }
        }
        if let rf = tags["rf"], rf.lowercased() != "afrf" {
            record.warnings.append("« rf=\(rf) » : seul le format afrf est défini.")
        }
        let known: Set<String> = ["v", "p", "sp", "pct", "rua", "ruf", "adkim", "aspf", "fo", "ri", "rf", "np", "psd", "t"]
        for key in tags.keys where !known.contains(key) {
            record.warnings.append("Étiquette inconnue « \(key)= » (ignorée par les destinataires).")
        }
        return record
    }

    /// La politique protège vraiment (quarantine ou reject sur 100 % des messages).
    public var isEnforced: Bool { (policy == "quarantine" || policy == "reject") && percent == 100 }
}

public struct DMARCReport: Hashable, Sendable {
    public var domain: String
    /// Nom où l'enregistrement a été trouvé (« _dmarc.exemple.ca »).
    public var location: String?
    /// Hérité du domaine organisationnel (sous-domaine sans DMARC propre).
    public var inherited: Bool
    public var record: DMARCRecord?
    public var recordCount: Int
    public var findings: [MailFinding]
    public var queryFailed: Bool

    public var status: MailStatus { findings.worstStatus }

    /// « p=none · pct=100 · rua 1 »
    public var summary: String {
        guard let record else { return queryFailed ? "Recherche impossible" : "Aucun enregistrement DMARC" }
        guard let policy = record.policy else { return "Enregistrement invalide" }
        var parts = ["p=\(policy)"]
        if record.percent != 100 { parts.append("pct=\(record.percent)") }
        parts.append(record.rua.isEmpty ? "sans rua" : "rua \(record.rua.count)")
        if inherited { parts.append("hérité") }
        return parts.joined(separator: " · ")
    }
}

public enum DMARCAnalyzer {
    public static func analyze(_ domain: String, client: MailDNSClient) async -> DMARCReport {
        let name = MailDNSText.normalize(domain)
        var report = DMARCReport(domain: name, location: nil, inherited: false, record: nil, recordCount: 0, findings: [], queryFailed: false)
        var location = "_dmarc.\(name)"
        var answer = await client.query(location, .txt)
        var found = answer.values.filter(DMARCRecord.isDMARC)
        let organization = MailDNSText.organizationalDomain(name)
        if found.isEmpty, !answer.isFailure, organization != name {
            location = "_dmarc.\(organization)"
            answer = await client.query(location, .txt)
            found = answer.values.filter(DMARCRecord.isDMARC)
            report.inherited = !found.isEmpty
        }
        if let failure = answer.failureText {
            report.queryFailed = true
            report.findings.append(MailFinding(.warning, "DMARC non vérifié", "La recherche TXT de \(location) a échoué\u{00A0}: \(failure)."))
            return report
        }
        report.recordCount = found.count
        guard let text = found.first else {
            report.findings.append(MailFinding(.error, "Aucun enregistrement DMARC",
                "Rien à _dmarc.\(name)\u{00A0}: les destinataires n’ont aucune consigne pour les messages usurpés, et Gmail et Yahoo exigent DMARC des expéditeurs en volume.",
                fix: "Publier « v=DMARC1; p=none; rua=mailto:dmarc@\(organization) » pour observer, puis passer à quarantine et reject."))
            return report
        }
        report.location = location
        let record = DMARCRecord.parse(text)
        report.record = record
        if found.count > 1 {
            report.findings.append(MailFinding(.error, "\(found.count) enregistrements DMARC",
                "Plusieurs TXT « v=DMARC1 »\u{00A0}: les destinataires ignorent alors DMARC.", fix: "N’en garder qu’un."))
        }
        for error in record.errors {
            report.findings.append(MailFinding(.error, "Syntaxe DMARC", error, fix: "Corriger l’enregistrement _dmarc."))
        }
        for warning in record.warnings {
            report.findings.append(MailFinding(.warning, "DMARC", warning))
        }
        if report.inherited {
            report.findings.append(MailFinding(.info, "Hérité de \(organization)", "Le sous-domaine suit la politique de \(location) (sp= si présent)."))
        }
        let effective = report.inherited ? (record.subdomainPolicy ?? record.policy) : record.policy
        switch effective {
        case "none":
            report.findings.append(MailFinding(.warning, "Politique « none » (surveillance)",
                "Les messages qui échouent DMARC sont livrés comme les autres\u{00A0}: le domaine reste usurpable.",
                fix: "Après lecture des rapports rua, passer à « p=quarantine », puis à « p=reject »."))
        case "quarantine":
            if record.percent < 100 {
                report.findings.append(MailFinding(.warning, "Quarantaine sur \(record.percent)\u{00A0}% des messages",
                    "Le reste des messages en échec est traité comme « none ».", fix: "Monter pct à 100, puis passer à reject."))
            } else {
                report.findings.append(MailFinding(.ok, "Politique « quarantine »", "Les messages en échec vont aux indésirables.",
                                                   fix: "Étape suivante\u{00A0}: « p=reject »."))
            }
        case "reject":
            if record.percent < 100 {
                report.findings.append(MailFinding(.warning, "Rejet sur \(record.percent)\u{00A0}% des messages",
                    "Le reste des messages en échec est mis en quarantaine.", fix: "Monter pct à 100."))
            } else {
                report.findings.append(MailFinding(.ok, "Politique « reject »", "Les messages usurpés sont refusés."))
            }
        default:
            break
        }
        if !report.inherited, let sp = record.subdomainPolicy, sp == "none", record.policy != "none" {
            report.findings.append(MailFinding(.warning, "Sous-domaines en « sp=none »",
                "Les sous-domaines (qui n’ont pas leur propre DMARC) restent usurpables.", fix: "Retirer sp= ou le mettre au niveau de p=."))
        }
        if record.rua.isEmpty {
            report.findings.append(MailFinding(.warning, "Aucune adresse rua",
                "Sans rapports agrégés, impossible de savoir qui envoie au nom du domaine avant de durcir la politique.",
                fix: "Ajouter « rua=mailto:dmarc@\(organization) » (ou l’adresse d’un service d’analyse DMARC)."))
        }
        // Adresses de rapport hors domaine : le domaine qui reçoit doit l'autoriser (RFC 7489 §7.1).
        let external = Set((record.rua + record.ruf).compactMap(MailURI.domain(ofMailbox:)))
            .filter { MailDNSText.organizationalDomain($0) != organization }
            .sorted()
        for target in external.prefix(4) {
            let check = await client.query("\(organization)._report._dmarc.\(target)", .txt)
            if check.isFailure { continue }
            if check.values.contains(where: DMARCRecord.isDMARC) {
                report.findings.append(MailFinding(.ok, "Rapports vers \(target) autorisés", "\(organization)._report._dmarc.\(target) existe."))
            } else {
                report.findings.append(MailFinding(.warning, "Rapports vers \(target) non autorisés",
                    "\(target) ne publie pas « \(organization)._report._dmarc.\(target) »\u{00A0}: les rapports risquent de ne pas être envoyés.",
                    fix: "Demander au service qui reçoit les rapports d’ajouter cette autorisation (ou utiliser une adresse du domaine)."))
            }
        }
        if record.adkim == "s" || record.aspf == "s" {
            report.findings.append(MailFinding(.info, "Alignement strict", "adkim=\(record.adkim), aspf=\(record.aspf)\u{00A0}: les sous-domaines d’envoi ne s’alignent pas."))
        }
        return report
    }
}
