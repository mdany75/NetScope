import Foundation

// Recherche MX : serveurs par priorité, leurs adresses IPv4/IPv6, le DNS inverse (PTR) de chaque
// adresse et sa cohérence (le nom du PTR revient à la même adresse, et correspond ou non au MX).

/// Une adresse d'un serveur MX et son DNS inverse.
public struct MXAddress: Hashable, Sendable, Identifiable {
    public var id: String { ip }
    public var ip: String
    /// Nom du PTR ; nil s'il n'y en a pas.
    public var ptr: String?
    /// Le nom du PTR résout vers cette même adresse (FCrDNS).
    public var forwardConfirmed: Bool
    /// Le PTR est le nom du MX lui-même.
    public var matchesHost: Bool
    public var lookupFailed: Bool

    public var ptrStatus: MailStatus {
        if lookupFailed { return .info }
        guard ptr != nil else { return .warning }
        return forwardConfirmed ? .ok : .warning
    }

    /// « PTR mx1.exemple.ca · confirmé », « aucun PTR »…
    public var ptrSummary: String {
        if lookupFailed { return "PTR non vérifié" }
        guard let ptr else { return "aucun PTR" }
        var text = ptr
        text += forwardConfirmed ? (matchesHost ? " · identique au MX" : " · confirmé") : " · ne revient pas à l’adresse"
        return text
    }
}

public struct MXHost: Hashable, Sendable, Identifiable {
    public var id: String { "\(priority)|\(host)" }
    public var priority: Int
    public var host: String
    public var addresses: [MXAddress]
    public var ipv6: [String]
    /// Le nom du MX ne résout pas (ni A ni AAAA).
    public var unresolved: Bool
    public var findings: [MailFinding]

    public var status: MailStatus { findings.worstStatus }
    public var ipv4: [String] { addresses.map(\.ip) }
}

public struct MXReport: Hashable, Sendable {
    public var domain: String
    public var hosts: [MXHost]
    /// MX nul (« 0 . », RFC 7505) : le domaine ne reçoit pas de courriel.
    public var nullMX: Bool
    /// Aucun MX, mais une adresse A : les expéditeurs livrent au domaine lui-même.
    public var implicitA: [String]
    public var queryFailed: Bool
    public var findings: [MailFinding]

    public var status: MailStatus { MailStatus.worst(findings.map(\.status) + hosts.map(\.status)) }

    /// Toutes les adresses IPv4 des MX, dans l'ordre des priorités, sans doublon.
    public var allIPv4: [String] {
        var seen: Set<String> = []
        return hosts.flatMap(\.ipv4).filter { seen.insert($0).inserted }
    }

    public var summary: String {
        if queryFailed { return "Recherche impossible" }
        if nullMX { return "MX nul\u{00A0}: ne reçoit pas de courriel" }
        if hosts.isEmpty { return implicitA.isEmpty ? "Aucun MX" : "Aucun MX (A implicite)" }
        return hosts.map { "\($0.priority) \($0.host)" }.joined(separator: " · ")
    }
}

public enum MXLookup {
    static let maxHosts = 10
    static let maxAddresses = 4

    /// Grands hébergeurs de courriel : leur PTR ne porte jamais le nom du MX (cela n'a rien d'anormal).
    static let providerSuffixes = ["protection.outlook.com", "google.com", "googlemail.com", "pphosted.com", "mimecast.com",
                                   "messagelabs.com", "barracudanetworks.com", "ppe-hosted.com", "amazonaws.com", "zoho.com"]

    public static func run(_ domain: String, client: MailDNSClient) async -> MXReport {
        let name = MailDNSText.normalize(domain)
        var report = MXReport(domain: name, hosts: [], nullMX: false, implicitA: [], queryFailed: false, findings: [])
        let answer = await client.query(name, .mx)
        if let failure = answer.failureText {
            report.queryFailed = true
            report.findings.append(MailFinding(.warning, "MX non vérifié", "La recherche MX de \(name) a échoué\u{00A0}: \(failure)."))
            return report
        }
        if answer.outcome == .nxdomain {
            report.findings.append(MailFinding(.error, "Domaine inexistant", "\(name) n’existe pas dans le DNS (NXDOMAIN)."))
            return report
        }
        let entries = answer.values.compactMap(MailDNSText.parseMX).sorted { ($0.priority, $0.host) < ($1.priority, $1.host) }
        if entries.count == 1, entries[0].host.isEmpty || entries[0].host == "." {
            report.nullMX = true
            report.findings.append(MailFinding(.info, "MX nul (RFC 7505)", "\(name) déclare ne recevoir aucun courriel."))
            return report
        }
        if entries.isEmpty {
            let a = await client.query(name, .a)
            report.implicitA = a.values
            if a.values.isEmpty {
                report.findings.append(MailFinding(.error, "Aucun MX", "\(name) ne publie aucun serveur de réception\u{00A0}: les messages qui lui sont adressés sont refusés.",
                                                   fix: "Publier les MX du fournisseur de courriel (ou un MX nul « 0 . » si le domaine ne reçoit rien)."))
            } else {
                report.findings.append(MailFinding(.warning, "Aucun MX (A implicite)",
                    "Les expéditeurs livreront à \(name) lui-même (\(a.values.joined(separator: ", "))).",
                    fix: "Publier un MX explicite, ou un MX nul si le domaine ne reçoit pas de courriel."))
            }
            return report
        }
        let selected = Array(entries.prefix(maxHosts))
        if entries.count > maxHosts {
            report.findings.append(MailFinding(.info, "\(entries.count) MX", "Seuls les \(maxHosts) premiers sont vérifiés."))
        }
        report.hosts = await mailConcurrentMap(selected, limit: 3) { entry in
            await host(entry.host, priority: entry.priority, client: client)
        }
        if report.hosts.count == 1 && !isProvider(report.hosts[0].host) {
            report.findings.append(MailFinding(.info, "Un seul MX", "Pas de serveur de secours\u{00A0}: les expéditeurs réessaient pendant quelques jours en cas de panne."))
        }
        if report.hosts.allSatisfy(\.unresolved) {
            report.findings.append(MailFinding(.error, "Aucun MX joignable", "Aucun nom MX ne résout vers une adresse.", fix: "Corriger les noms MX."))
        } else if !report.hosts.contains(where: { $0.status > .info }) {
            report.findings.insert(MailFinding(.ok, "\(report.hosts.count) MX", "Tous les serveurs résolvent et leur DNS inverse est cohérent."), at: 0)
        }
        return report
    }

    static func isProvider(_ host: String) -> Bool {
        providerSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Adresses d'un serveur MX, et PTR de chacune.
    public static func host(_ host: String, priority: Int, client: MailDNSClient) async -> MXHost {
        var result = MXHost(priority: priority, host: host, addresses: [], ipv6: [], unresolved: false, findings: [])
        if IPv4Address(host) != nil {
            result.findings.append(MailFinding(.error, "MX \(host) est une adresse IP", "Un MX doit être un nom d’hôte, pas une adresse (RFC 5321).",
                                               fix: "Remplacer l’adresse par un nom qui la résout."))
        }
        async let v4 = client.query(host, .a)
        async let v6 = client.query(host, .aaaa)
        let (a, aaaa) = await (v4, v6)
        result.ipv6 = aaaa.values
        if a.values.isEmpty && aaaa.values.isEmpty {
            result.unresolved = true
            result.findings.append(MailFinding(a.isFailure ? .warning : .error, "\(host) ne résout pas",
                a.failureText.map { "Recherche impossible\u{00A0}: \($0)." } ?? "Ni A ni AAAA\u{00A0}: ce MX est inutilisable.",
                fix: a.isFailure ? nil : "Corriger ou retirer ce MX."))
            return result
        }
        let ips = Array(a.values.prefix(maxAddresses))
        result.addresses = await mailConcurrentMap(ips, limit: 2) { ip in await address(ip, host: host, client: client) }
        let provider = isProvider(host)
        for address in result.addresses where !address.lookupFailed {
            if address.ptr == nil {
                result.findings.append(MailFinding(.warning, "\(address.ip) sans PTR",
                    "Beaucoup de serveurs refusent les messages d’une adresse sans DNS inverse (si ce MX envoie aussi).",
                    fix: "Demander au fournisseur de l’adresse de publier un PTR vers \(host)."))
            } else if !address.forwardConfirmed {
                result.findings.append(MailFinding(.warning, "PTR de \(address.ip) incohérent",
                    "\(address.ptr ?? "") ne résout pas vers \(address.ip).", fix: "Aligner le PTR et l’enregistrement A."))
            } else if !address.matchesHost && !provider {
                result.findings.append(MailFinding(.info, "PTR différent du MX", "\(address.ip) → \(address.ptr ?? "") (confirmé, mais autre nom que \(host))."))
            }
        }
        return result
    }

    /// PTR d'une adresse, puis vérification qu'il revient à la même adresse.
    public static func address(_ ip: String, host: String, client: MailDNSClient) async -> MXAddress {
        var result = MXAddress(ip: ip, ptr: nil, forwardConfirmed: false, matchesHost: false, lookupFailed: false)
        let ptr = await client.query(ip, .ptr)
        if ptr.isFailure {
            result.lookupFailed = true
            return result
        }
        guard let name = ptr.values.first.map(MailDNSText.normalize), !name.isEmpty else { return result }
        result.ptr = name
        result.matchesHost = name == MailDNSText.normalize(host)
        let forward = name == MailDNSText.normalize(host) ? MailDNSAnswer(outcome: .answer, values: [ip]) : await client.query(name, .a)
        result.forwardConfirmed = forward.values.contains(ip)
        return result
    }
}
