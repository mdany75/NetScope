import Foundation

// « Super outil » : un seul champ. Il reconnaît une adresse courriel, une adresse IP, un domaine
// ou un nom d'hôte, puis lance les vérifications utiles et rend un bilan coloré.

public enum MailInputKind: String, Codable, Hashable, Sendable {
    case email, domain, hostname, ip, invalid

    public var label: String {
        switch self {
        case .email: return "Adresse courriel"
        case .domain: return "Domaine"
        case .hostname: return "Nom d’hôte"
        case .ip: return "Adresse IP"
        case .invalid: return "Saisie non reconnue"
        }
    }
}

public enum MailInput {
    /// Lecture de la saisie, sans réseau : courriel, IP, nom (domaine ou hôte), ou invalide.
    /// Accepte « mailto: », les chevrons (« Nom <a@b.ca> »), une adresse Web (« https://exemple.ca/x »).
    public static func classify(_ raw: String) -> (kind: MailInputKind, value: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        if text.lowercased().hasPrefix("mailto:") { text = String(text.dropFirst(7)) }
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
            if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { text = String(text[..<slash]) }
            if let colon = text.lastIndex(of: ":"), text[text.index(after: colon)...].allSatisfy(\.isNumber) { text = String(text[..<colon]) }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return (.invalid, "") }
        if let ip = IPv4Address(text) { return (.ip, ip.description) }
        if text.contains("@") {
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, (1...64).contains(parts[0].count), text.count <= 254,
                  !parts[0].contains(" "), MailDNSText.isDomainName(String(parts[1])), parts[1].contains(".") else {
                return (.invalid, text)
            }
            return (.email, String(parts[0]) + "@" + MailDNSText.normalize(String(parts[1])))
        }
        let name = MailDNSText.normalize(text)
        guard MailDNSText.isDomainName(name), name.contains("."), !name.split(separator: ".").last!.allSatisfy(\.isNumber) else {
            return (.invalid, text)
        }
        // Domaine ou hôte : décidé plus tard par le DNS (MX, SPF) ; ici, une seule étiquette sous le
        // domaine organisationnel qui ressemble à un serveur (« mail. », « smtp. ») oriente vers l'hôte.
        return (.domain, name)
    }

    /// Domaine d'une adresse courriel.
    public static func domain(ofEmail email: String) -> String {
        MailDNSText.normalize(String(email.split(separator: "@").last ?? ""))
    }
}

public struct MailSuperResult: Sendable {
    public var input: String
    public var kind: MailInputKind
    /// Valeur vérifiée (domaine, adresse IP, nom d'hôte).
    public var target: String
    public var checks: [MailCheck]
    /// Bilan complet pour un domaine ou une adresse courriel.
    public var health: MailHealthReport?
    public var blacklists: DNSBLReport?
    public var date: Date

    public func count(_ status: MailStatus) -> Int { checks.filter { $0.status == status }.count }
    public var status: MailStatus { MailStatus.worst(checks.map(\.status)) }

    /// « 4 OK · 3 avertissements · 1 erreur »
    public var tally: String {
        var parts: [String] = []
        let ok = count(.ok), info = count(.info), warning = count(.warning), error = count(.error)
        if ok > 0 { parts.append("\(ok) OK") }
        if warning > 0 { parts.append("\(warning) avertissement\(warning > 1 ? "s" : "")") }
        if error > 0 { parts.append("\(error) erreur\(error > 1 ? "s" : "")") }
        if info > 0 { parts.append("\(info) info") }
        return parts.joined(separator: " · ")
    }
}

public enum MailSuperTool {
    /// Lance les vérifications utiles pour la saisie.
    public static func run(_ raw: String, client: MailDNSClient, date: Date = Date(),
                           progress: (@Sendable (String) -> Void)? = nil) async -> MailSuperResult {
        let (kind, value) = MailInput.classify(raw)
        var result = MailSuperResult(input: raw, kind: kind, target: value, checks: [], health: nil, blacklists: nil, date: date)
        switch kind {
        case .invalid:
            result.checks = [MailCheck(.address, status: .error, title: "Saisie", result: "Non reconnue",
                                       detail: "Saisir un domaine (exemple.ca), une adresse courriel, une adresse IPv4 ou un nom d’hôte.")]
        case .ip:
            guard let ip = IPv4Address(value) else { break }
            await runIP(ip, into: &result, client: client, progress: progress)
        case .email:
            let domain = MailInput.domain(ofEmail: value)
            result.target = domain
            result.checks.append(MailCheck(.address, status: .ok, title: "Adresse", result: value,
                                           detail: "Syntaxe valide\u{00A0}; le domaine \(domain) est vérifié ci-dessous."))
            await runDomain(domain, into: &result, client: client, date: date, progress: progress)
            if let mx = result.health?.mx, !mx.queryFailed, mx.hosts.isEmpty, mx.implicitA.isEmpty {
                result.checks[0] = MailCheck(.address, status: .error, title: "Adresse", result: value,
                                             detail: mx.nullMX ? "Le domaine déclare ne recevoir aucun courriel (MX nul)."
                                                               : "Le domaine \(domain) ne peut pas recevoir de courriel\u{00A0}: l’adresse n’est pas livrable.")
            }
        case .domain, .hostname:
            progress?("Recherche de \(value)")
            async let mxAnswer = client.query(value, .mx)
            async let txtAnswer = client.query(value, .txt)
            let (mx, txt) = await (mxAnswer, txtAnswer)
            let isDomain = !mx.values.isEmpty || txt.values.contains(where: SPFRecord.isSPF)
            if mx.outcome == .nxdomain {
                result.checks = [MailCheck(.resolution, status: .error, title: "Nom", result: "Introuvable (NXDOMAIN)",
                                           detail: "\(value) n’existe pas dans le DNS. Vérifier l’orthographe.")]
            } else if isDomain || mx.isFailure {
                await runDomain(value, into: &result, client: client, date: date, progress: progress)
            } else {
                let a = await client.query(value, .a)
                if a.values.isEmpty {
                    await runDomain(value, into: &result, client: client, date: date, progress: progress)
                } else {
                    result.kind = .hostname
                    await runHost(value, addresses: a.values, into: &result, client: client, progress: progress)
                }
            }
        }
        return result
    }

    static func runDomain(_ domain: String, into result: inout MailSuperResult, client: MailDNSClient, date: Date,
                          progress: (@Sendable (String) -> Void)?) async {
        if result.kind != .email { result.kind = .domain }
        result.target = domain
        let health = await MailHealth.run(domain, client: client, date: date) { _, step in progress?("Vérification\u{00A0}: \(step)") }
        result.health = health
        result.blacklists = health.blacklists
        result.checks += health.summary.checks
    }

    static func runHost(_ host: String, addresses: [String], into result: inout MailSuperResult, client: MailDNSClient,
                        progress: (@Sendable (String) -> Void)?) async {
        let aaaa = await client.query(host, .aaaa)
        result.checks.append(MailCheck(.resolution, status: .ok, title: "Adresses", result: (addresses + aaaa.values).joined(separator: ", "),
                                       detail: "\(host) est un nom d’hôte (ni MX ni SPF)\u{00A0}: vérification du serveur lui-même."))
        progress?("DNS inverse")
        let ips = Array(addresses.prefix(4))
        let ptrs = await mailConcurrentMap(ips, limit: 2) { ip in await MXLookup.address(ip, host: host, client: client) }
        for address in ptrs {
            result.checks.append(ptrCheck(address, title: "PTR \(address.ip)", expected: host))
        }
        progress?("Listes noires")
        let targets = ips.compactMap(IPv4Address.init).map(DNSBLTarget.ip) + [.domain(MailDNSText.organizationalDomain(host))]
        let blacklists = await DNSBL.check(targets, client: client)
        result.blacklists = blacklists
        result.checks.append(blacklistCheck(blacklists))
        let organization = MailDNSText.organizationalDomain(host)
        if organization != host {
            result.checks.append(MailCheck(.resolution, status: .info, title: "Domaine", result: organization,
                                           detail: "Saisir \(organization) pour le bilan courriel du domaine (MX, SPF, DMARC…)."))
        }
    }

    static func runIP(_ ip: IPv4Address, into result: inout MailSuperResult, client: MailDNSClient,
                      progress: (@Sendable (String) -> Void)?) async {
        if MailDNSText.isReserved(ip) {
            result.checks.append(MailCheck(.resolution, status: .info, title: "Adresse", result: "Privée ou réservée",
                                           detail: "\(ip) n’est pas routable sur Internet\u{00A0}: ni DNS inverse public ni listes noires."))
        }
        progress?("DNS inverse")
        let address = await MXLookup.address(ip.description, host: "", client: client)
        result.checks.append(ptrCheck(address, title: "DNS inverse", expected: nil))
        guard !MailDNSText.isReserved(ip) else { return }
        progress?("Listes noires")
        let blacklists = await DNSBL.check([.ip(ip)], client: client)
        result.blacklists = blacklists
        result.checks.append(blacklistCheck(blacklists))
    }

    static func ptrCheck(_ address: MXAddress, title: String, expected: String?) -> MailCheck {
        if address.lookupFailed {
            return MailCheck(.ptr, status: .info, title: title, result: "Non vérifié", detail: "La requête PTR n’a pas abouti.")
        }
        guard let ptr = address.ptr else {
            return MailCheck(.ptr, status: .warning, title: title, result: "Aucun PTR",
                             detail: "Un serveur qui envoie du courriel sans DNS inverse est souvent refusé.")
        }
        if !address.forwardConfirmed {
            return MailCheck(.ptr, status: .warning, title: title, result: ptr,
                             detail: "Le nom \(ptr) ne revient pas à \(address.ip) (DNS inverse non confirmé).")
        }
        if let expected, !address.matchesHost {
            return MailCheck(.ptr, status: .info, title: title, result: ptr,
                             detail: "Confirmé, mais différent de \(expected)\u{00A0}: le serveur se présente sous un autre nom.")
        }
        return MailCheck(.ptr, status: .ok, title: title, result: ptr, detail: "Le nom revient bien à \(address.ip).")
    }

    static func blacklistCheck(_ report: DNSBLReport) -> MailCheck {
        let worst = report.findings.bySeverity.first
        return MailCheck(.blacklist, status: report.checkedCount == 0 ? .info : report.status, result: report.summary,
                         detail: worst.map { $0.detail.isEmpty ? $0.title : "\($0.title)\u{00A0}: \($0.detail)" } ?? "")
    }
}
