import Foundation

// Santé courriel d'un domaine : MX, SPF, DKIM, DMARC, listes noires, MTA-STS, TLS-RPT, DNSSEC
// (et BIMI, sans points). Chaque catégorie rapporte des points ; la note sur 100 est ramenée
// aux catégories réellement vérifiées (une recherche qui échoue ne pénalise pas le domaine).

public enum MailHealthGrade: String, Codable, Hashable, Sendable {
    case good, fair, poor

    public init(score: Int) {
        self = score >= 85 ? .good : (score >= 60 ? .fair : .poor)
    }

    public var label: String {
        switch self {
        case .good: return "Bon"
        case .fair: return "À améliorer"
        case .poor: return "À corriger"
        }
    }

    public var status: MailStatus {
        switch self {
        case .good: return .ok
        case .fair: return .warning
        case .poor: return .error
        }
    }
}

/// Bilan à garder et à exporter (Rapports) : note, vérifications et recommandations.
public struct MailHealthSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String { domain + "|" + String(date.timeIntervalSince1970) }
    public var domain: String
    public var date: Date
    public var score: Int
    public var checks: [MailCheck]
    /// Corrections à faire, de la plus grave à la moins grave.
    public var recommendations: [MailFinding]

    public init(domain: String, date: Date, score: Int, checks: [MailCheck], recommendations: [MailFinding]) {
        self.domain = domain
        self.date = date
        self.score = score
        self.checks = checks
        self.recommendations = recommendations
    }

    public var grade: MailHealthGrade { MailHealthGrade(score: score) }

    public func count(_ status: MailStatus) -> Int { checks.filter { $0.status == status }.count }
}

/// Tout le détail d'un bilan (outil Santé courriel).
public struct MailHealthReport: Sendable {
    public var domain: String
    public var mx: MXReport
    public var spf: SPFReport
    public var dmarc: DMARCReport
    public var dkim: DKIMReport
    public var bimi: BIMIReport
    public var mtaSTS: MTASTSReport
    public var tlsRPT: TLSRPTReport
    public var blacklists: DNSBLReport
    public var dnssec: MailDNSSECState
    public var summary: MailHealthSummary
}

public enum MailHealth {
    /// Étapes, pour la barre de progression.
    public static let steps = ["MX", "SPF", "DMARC", "DKIM", "MTA-STS et TLS-RPT", "BIMI", "Listes noires", "DNSSEC"]

    /// Bilan complet d'un domaine. `progress` reçoit le numéro (0…) et le nom de l'étape en cours.
    public static func run(_ domain: String, extraSelectors: [String] = [], client: MailDNSClient, date: Date = Date(),
                           progress: (@Sendable (Int, String) -> Void)? = nil) async -> MailHealthReport {
        let name = MailDNSText.normalize(domain)
        progress?(0, steps[0])
        let mx = await MXLookup.run(name, client: client)
        progress?(1, steps[1])
        let spf = await SPFAnalyzer.analyze(name, client: client)
        progress?(2, steps[2])
        let dmarc = await DMARCAnalyzer.analyze(name, client: client)
        progress?(3, steps[3])
        let dkim = await DKIMAnalyzer.scan(name, selectors: extraSelectors + DKIMAnalyzer.commonSelectors, client: client)
        progress?(4, steps[4])
        let mtaSTS = await MailPolicyAnalyzer.mtaSTS(name, mxHosts: mx.hosts.map(\.host), client: client)
        let tlsRPT = await MailPolicyAnalyzer.tlsRPT(name, client: client)
        progress?(5, steps[5])
        let bimi = await MailPolicyAnalyzer.bimi(name, dmarc: dmarc.record, client: client)
        progress?(6, steps[6])
        let blacklists = await DNSBL.check(blacklistTargets(name, mx: mx, spf: spf), client: client)
        progress?(7, steps[7])
        let dnssec = await client.dnssec(name)
        let summary = evaluate(domain: name, mx: mx, spf: spf, dmarc: dmarc, dkim: dkim, bimi: bimi, mtaSTS: mtaSTS,
                               tlsRPT: tlsRPT, blacklists: blacklists, dnssec: dnssec, date: date)
        return MailHealthReport(domain: name, mx: mx, spf: spf, dmarc: dmarc, dkim: dkim, bimi: bimi, mtaSTS: mtaSTS,
                                tlsRPT: tlsRPT, blacklists: blacklists, dnssec: dnssec, summary: summary)
    }

    /// Cibles des listes noires : le domaine organisationnel, les adresses des MX (A implicite
    /// compris) et les adresses d'envoi déclarées en ip4 dans le SPF du domaine ; quatre adresses au plus.
    public static func blacklistTargets(_ domain: String, mx: MXReport, spf: SPFReport) -> [DNSBLTarget] {
        let targets: [DNSBLTarget] = [.domain(MailDNSText.organizationalDomain(domain))]
        var ips: [IPv4Address] = []
        func add(_ text: String) {
            guard let ip = IPv4Address(text), !MailDNSText.isReserved(ip), !ips.contains(ip), ips.count < 4 else { return }
            ips.append(ip)
        }
        for ip in mx.allIPv4.prefix(2) { add(ip) }
        for ip in mx.implicitA.prefix(2) { add(ip) }
        // Adresses d'envoi (ip4 seules ou /32) du SPF du domaine et de ses propres include.
        let organization = MailDNSText.organizationalDomain(domain)
        for node in spf.nodes where MailDNSText.organizationalDomain(node.domain) == organization {
            for term in node.record.flatMap(SPFRecord.parse)?.terms ?? [] where term.kind == .ip4 {
                let value = term.value ?? ""
                if !value.contains("/") || value.hasSuffix("/32") { add(String(value.split(separator: "/")[0])) }
            }
        }
        for ip in mx.allIPv4.dropFirst(2) { add(ip) }
        return targets + ips.map { .ip($0) }
    }

    // MARK: Note

    /// Calcule la note et les recommandations (fonction pure : testée sans réseau).
    public static func evaluate(domain: String, mx: MXReport, spf: SPFReport, dmarc: DMARCReport, dkim: DKIMReport,
                                bimi: BIMIReport, mtaSTS: MTASTSReport, tlsRPT: TLSRPTReport, blacklists: DNSBLReport,
                                dnssec: MailDNSSECState, date: Date = Date()) -> MailHealthSummary {
        var checks: [MailCheck] = []
        func add(_ category: MailCategory, _ status: MailStatus, _ points: Int?, _ result: String, _ detail: String) {
            checks.append(MailCheck(category, status: status, result: result, detail: detail,
                                    points: points, maxPoints: points == nil ? nil : category.maxPoints))
        }
        func detail(_ findings: [MailFinding]) -> String {
            let worst = findings.bySeverity.first
            return worst.map { $0.detail.isEmpty ? $0.title : "\($0.title)\u{00A0}: \($0.detail)" } ?? ""
        }

        // MX
        let mxStatus = mx.status
        let mxPoints: Int? = mx.queryFailed ? nil
            : mx.nullMX ? 15
            : mx.hosts.isEmpty ? (mx.implicitA.isEmpty ? 0 : 5)
            : mxStatus == .error ? (mx.hosts.contains { !$0.unresolved } ? 6 : 0)
            : mxStatus == .warning ? 10 : 15
        add(.mx, mx.queryFailed ? .info : mxStatus, mxPoints, mx.summary,
            detail(mx.findings + mx.hosts.flatMap(\.findings)))

        // SPF
        let spfPoints: Int?
        if spf.queryFailed { spfPoints = nil }
        else if spf.record == nil || spf.isPermError || spf.allQualifier == "+" { spfPoints = 0 }
        else if spf.allQualifier == "?" || spf.allQualifier == nil { spfPoints = 8 }
        else if spf.status == .warning { spfPoints = spf.voidLookups > SPFAnalyzer.voidLimit ? 12 : 15 }
        else { spfPoints = 20 }
        add(.spf, spf.queryFailed ? .info : spf.status, spfPoints, spf.summary, detail(spf.findings))

        // DMARC
        let dmarcPoints: Int?
        if dmarc.queryFailed { dmarcPoints = nil }
        else if let record = dmarc.record, record.errors.isEmpty, dmarc.recordCount == 1 {
            let policy = dmarc.inherited ? (record.subdomainPolicy ?? record.policy) : record.policy
            var points: Int
            switch policy {
            case "reject": points = record.percent == 100 ? 20 : 16
            case "quarantine": points = record.percent == 100 ? 17 : 14
            default: points = 8
            }
            if record.rua.isEmpty { points -= 2 }
            dmarcPoints = max(points, 0)
        } else { dmarcPoints = 0 }
        add(.dmarc, dmarc.queryFailed ? .info : dmarc.status, dmarcPoints, dmarc.summary, detail(dmarc.findings))

        // DKIM
        let usable = dkim.found.compactMap(\.key).filter { !$0.revoked && $0.errors.isEmpty }
        let dkimPoints: Int?
        if dkim.found.isEmpty && dkim.failures == dkim.tried { dkimPoints = nil }
        else if dkim.found.isEmpty { dkimPoints = 5 }
        else if usable.isEmpty { dkimPoints = 0 }
        else if usable.contains(where: { ($0.bits ?? 0) < 1024 && $0.keyType == "rsa" }) { dkimPoints = 4 }
        else if usable.contains(where: { $0.testing || (($0.bits ?? 2048) < 2048 && $0.keyType == "rsa") }) { dkimPoints = 10 }
        else { dkimPoints = 15 }
        add(.dkim, dkimPoints == nil ? .info : dkim.status, dkimPoints, dkim.summary, detail(dkim.findings))

        // Listes noires
        let blacklistPoints: Int?
        if blacklists.checkedCount == 0 { blacklistPoints = nil }
        else if !blacklists.majorListings.isEmpty { blacklistPoints = 0 }
        else if !blacklists.listed.isEmpty { blacklistPoints = 11 }
        else { blacklistPoints = 15 }
        add(.blacklist, blacklistPoints == nil ? .info : blacklists.status, blacklistPoints, blacklists.summary,
            detail(blacklists.findings))

        // MTA-STS
        let mtaPoints: Int?
        if mtaSTS.findings.contains(where: { $0.title == "MTA-STS non vérifié" }) { mtaPoints = nil }
        else if mtaSTS.record == nil { mtaPoints = 0 }
        else if mtaSTS.status == .error { mtaPoints = 0 }
        else if mtaSTS.policy?.mode == "enforce" { mtaPoints = mtaSTS.status == .ok ? 6 : 5 }
        else if mtaSTS.policy?.mode == "testing" { mtaPoints = 4 }
        else { mtaPoints = 1 }
        add(.mtasts, mtaPoints == nil ? .info : mtaSTS.status, mtaPoints, mtaSTS.summary, detail(mtaSTS.findings))

        // TLS-RPT
        let tlsPoints: Int? = tlsRPT.findings.contains { $0.title == "TLS-RPT non vérifié" } ? nil
            : tlsRPT.record == nil ? 0 : (tlsRPT.status == .error ? 1 : 4)
        add(.tlsrpt, tlsRPT.status, tlsPoints, tlsRPT.summary, detail(tlsRPT.findings))

        // DNSSEC
        switch dnssec {
        case .signed: add(.dnssec, .ok, 5, "Zone signée (DS publié)", "La délégation du domaine est signée\u{00A0}: les réponses DNS ne peuvent pas être falsifiées.")
        case .unsigned: add(.dnssec, .info, 0, "Zone non signée", "Aucun DS chez le parent\u{00A0}: DNSSEC n’est pas activé (facultatif, mais il renforce MTA-STS et DANE).")
        case .unknown: add(.dnssec, .info, nil, "Non vérifié", "La requête DS n’a pas abouti.")
        }

        // BIMI (sans points)
        checks.append(MailCheck(.bimi, status: bimi.status, result: bimi.summary, detail: detail(bimi.findings)))

        let earned = checks.compactMap(\.points).reduce(0, +)
        let possible = checks.compactMap(\.maxPoints).reduce(0, +)
        let score = possible > 0 ? Int((Double(earned) / Double(possible) * 100).rounded()) : 0

        var recommendations = (mx.findings + mx.hosts.flatMap(\.findings) + spf.findings + dmarc.findings + dkim.findings
                               + blacklists.findings + mtaSTS.findings + tlsRPT.findings + bimi.findings)
            .filter { $0.fix != nil && $0.status >= .info }
        if dnssec == .unsigned {
            recommendations.append(MailFinding(.info, "DNSSEC non activé", "", fix: "Activer DNSSEC chez l’hébergeur DNS et publier le DS chez le registraire."))
        }
        var seen: Set<String> = []
        recommendations = recommendations.bySeverity.filter { seen.insert($0.title).inserted }
        return MailHealthSummary(domain: domain, date: date, score: score, checks: checks, recommendations: recommendations)
    }
}
