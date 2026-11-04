import Foundation

// Listes noires DNS (DNSBL, RBL, URIBL) : une adresse IPv4 est cherchée inversée
// (« 4.3.2.1.zen.spamhaus.org »), un domaine tel quel (« exemple.ca.dbl.spamhaus.org »).
// Une réponse 127.0.0.x veut dire « listé » ; NXDOMAIN veut dire « absent ». Certains codes
// signalent un refus (résolveur public, volume) : ils ne sont pas comptés comme inscriptions.
// Les requêtes sont limitées (quelques-unes à la fois, espacées) pour ne pas être bloqué.

public struct DNSBLList: Hashable, Sendable, Identifiable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// Adresses IPv4 (serveurs d'envoi).
        case ip
        /// Noms de domaine (liens et expéditeurs).
        case domain

        public var label: String { self == .ip ? "IP" : "Domaine" }
    }

    public enum Weight: String, Hashable, Sendable, Codable {
        /// Liste très utilisée : une inscription bloque des messages.
        case major
        /// Liste de portée limitée ou très large (blocs entiers, ASN) : à surveiller.
        case minor

        public var label: String { self == .major ? "Majeure" : "Mineure" }
    }

    public var id: String { zone }
    public var name: String
    public var zone: String
    public var kind: Kind
    public var weight: Weight
    /// Page de vérification et de retrait.
    public var removalURL: String?
    /// Explication des codes de retour connus (« 127.0.0.2 » → « SBL : source de pourriel »).
    public var codes: [String: String]
    /// Codes qui signalent un refus de la requête, pas une inscription.
    public var refusalCodes: [String: String]
    /// Liste interrogée par défaut ; false : fermée ou peu fiable (gardée pour mémoire).
    public var isActive: Bool
    public var note: String?

    public init(name: String, zone: String, kind: Kind, weight: Weight = .major, removalURL: String? = nil,
                codes: [String: String] = [:], refusalCodes: [String: String] = [:], isActive: Bool = true, note: String? = nil) {
        self.name = name
        self.zone = zone
        self.kind = kind
        self.weight = weight
        self.removalURL = removalURL
        self.codes = codes
        self.refusalCodes = refusalCodes
        self.isActive = isActive
        self.note = note
    }
}

public enum DNSBLCatalog {
    static let spamhausRefusals = [
        "127.255.255.252": "Requête mal formée (nom de zone incorrect).",
        "127.255.255.254": "Requête refusée\u{00A0}: Spamhaus ne répond pas aux résolveurs publics (8.8.8.8, 1.1.1.1…). Choisir le DNS du FAI ou un résolveur local.",
        "127.255.255.255": "Requête refusée\u{00A0}: trop de requêtes depuis ce résolveur.",
    ]

    /// Principales listes (22 dont une fermée, gardée pour mémoire).
    public static let all: [DNSBLList] = [
        DNSBLList(name: "Spamhaus ZEN", zone: "zen.spamhaus.org", kind: .ip, removalURL: "https://check.spamhaus.org/",
                  codes: ["127.0.0.2": "SBL\u{00A0}: source de pourriel connue",
                          "127.0.0.3": "SBL CSS\u{00A0}: envois de pourriel à faible réputation",
                          "127.0.0.4": "XBL\u{00A0}: machine infectée ou mandataire ouvert",
                          "127.0.0.5": "XBL\u{00A0}: machine infectée",
                          "127.0.0.6": "XBL\u{00A0}: machine infectée",
                          "127.0.0.7": "XBL\u{00A0}: machine infectée",
                          "127.0.0.9": "DROP\u{00A0}: réseau détourné ou criminel",
                          "127.0.0.10": "PBL (FAI)\u{00A0}: adresse résidentielle qui ne devrait pas envoyer directement",
                          "127.0.0.11": "PBL (Spamhaus)\u{00A0}: adresse résidentielle ou dynamique"],
                  refusalCodes: spamhausRefusals),
        DNSBLList(name: "Barracuda", zone: "b.barracudacentral.org", kind: .ip,
                  removalURL: "https://www.barracudacentral.org/rbl/removal-request",
                  codes: ["127.0.0.2": "Adresse de mauvaise réputation (Barracuda Reputation Block List)"]),
        DNSBLList(name: "SpamCop", zone: "bl.spamcop.net", kind: .ip, removalURL: "https://www.spamcop.net/bl.shtml",
                  codes: ["127.0.0.2": "Signalée par des utilisateurs de SpamCop (retrait automatique après 24 h sans plainte)"]),
        DNSBLList(name: "UCEPROTECT niveau 1", zone: "dnsbl-1.uceprotect.net", kind: .ip,
                  removalURL: "https://www.uceprotect.net/en/rblcheck.php",
                  codes: ["127.0.0.2": "Adresse prise à envoyer vers des pièges à pourriel"]),
        DNSBLList(name: "UCEPROTECT niveau 2", zone: "dnsbl-2.uceprotect.net", kind: .ip, weight: .minor,
                  removalURL: "https://www.uceprotect.net/en/rblcheck.php",
                  codes: ["127.0.0.2": "Bloc d’adresses voisin d’émetteurs listés (niveau 2)"],
                  note: "Liste des blocs entiers\u{00A0}: peu de serveurs la suivent."),
        DNSBLList(name: "UCEPROTECT niveau 3", zone: "dnsbl-3.uceprotect.net", kind: .ip, weight: .minor,
                  removalURL: "https://www.uceprotect.net/en/rblcheck.php",
                  codes: ["127.0.0.2": "Réseau (ASN) du fournisseur listé en entier (niveau 3)"],
                  note: "Liste des ASN entiers (Microsoft, OVH…)\u{00A0}: presque personne ne la suit."),
        DNSBLList(name: "PSBL (Passive Spam Block List)", zone: "psbl.surriel.com", kind: .ip, removalURL: "https://psbl.org/remove",
                  codes: ["127.0.0.2": "Adresse vue envoyer vers des pièges à pourriel"]),
        DNSBLList(name: "Mailspike", zone: "bl.mailspike.net", kind: .ip, removalURL: "https://mailspike.org/iplookup.html",
                  codes: ["127.0.0.2": "Adresse de mauvaise réputation",
                          "127.0.0.10": "Pire réputation", "127.0.0.11": "Très mauvaise réputation",
                          "127.0.0.12": "Mauvaise réputation", "127.0.0.13": "Réputation douteuse", "127.0.0.14": "Réputation légèrement douteuse"]),
        DNSBLList(name: "SpamRATS", zone: "all.spamrats.com", kind: .ip, weight: .minor, removalURL: "https://www.spamrats.com/removal.php",
                  codes: ["127.0.0.36": "RATS-Dyna\u{00A0}: adresse dynamique ou résidentielle",
                          "127.0.0.37": "RATS-NoPtr\u{00A0}: adresse sans DNS inverse",
                          "127.0.0.38": "RATS-Spam\u{00A0}: adresse qui envoie du pourriel",
                          "127.0.0.43": "RATS-Auth\u{00A0}: attaques d’authentification"]),
        DNSBLList(name: "DroneBL", zone: "dnsbl.dronebl.org", kind: .ip, weight: .minor, removalURL: "https://dronebl.org/lookup",
                  codes: ["127.0.0.3": "Serveur IRC piraté", "127.0.0.6": "Machine zombie", "127.0.0.7": "Hôte d’attaques par déni de service",
                          "127.0.0.8": "Mandataire SOCKS ouvert", "127.0.0.9": "Mandataire HTTP ouvert", "127.0.0.10": "Mandataire ouvert",
                          "127.0.0.13": "Attaques par force brute", "127.0.0.14": "Routeur Wingate ouvert", "127.0.0.15": "Routeur piraté",
                          "127.0.0.17": "Botnet", "127.0.0.19": "Mandataire DDoS"]),
        DNSBLList(name: "blocklist.de", zone: "bl.blocklist.de", kind: .ip, weight: .minor, removalURL: "https://www.blocklist.de/en/delist.html",
                  codes: ["127.0.0.2": "Attaques signalées (SSH, courriel, Web…) au cours des 48 dernières heures"]),
        DNSBLList(name: "Backscatterer", zone: "ips.backscatterer.org", kind: .ip, weight: .minor,
                  removalURL: "https://www.backscatterer.org/?target=test",
                  codes: ["127.0.0.2": "Renvoie des avis de non-remise vers de fausses adresses (backscatter)"]),
        DNSBLList(name: "s5h.net", zone: "all.s5h.net", kind: .ip, weight: .minor, removalURL: "https://www.s5h.net/rbl/",
                  codes: ["127.0.0.2": "Adresse vue envoyer du pourriel"]),
        DNSBLList(name: "SEM BLACK (Spam Eating Monkey)", zone: "bl.spameatingmonkey.net", kind: .ip, weight: .minor,
                  removalURL: "https://spameatingmonkey.com/lookup",
                  codes: ["127.0.0.2": "Adresse vue envoyer du pourriel"]),
        DNSBLList(name: "Nordspam", zone: "bl.nordspam.com", kind: .ip, weight: .minor, removalURL: "https://www.nordspam.com/",
                  codes: ["127.0.0.2": "Adresse vue envoyer du pourriel"]),
        DNSBLList(name: "GBUdb Truncate", zone: "truncate.gbudb.net", kind: .ip, weight: .minor, removalURL: "https://www.gbudb.com/truncate/",
                  codes: ["127.0.0.2": "Adresse de très mauvaise réputation (presque tout son courriel est du pourriel)"]),
        DNSBLList(name: "SORBS", zone: "dnsbl.sorbs.net", kind: .ip, isActive: false,
                  note: "Liste fermée en juin 2024\u{00A0}: ses réponses ne sont plus fiables."),
        // Listes de domaines.
        DNSBLList(name: "Spamhaus DBL", zone: "dbl.spamhaus.org", kind: .domain, removalURL: "https://check.spamhaus.org/",
                  codes: ["127.0.1.2": "Domaine de pourriel", "127.0.1.4": "Domaine d’hameçonnage", "127.0.1.5": "Domaine de logiciel malveillant",
                          "127.0.1.6": "Domaine de commande de botnet", "127.0.1.102": "Domaine légitime détourné (pourriel)",
                          "127.0.1.103": "Domaine légitime détourné (redirection)", "127.0.1.104": "Domaine légitime détourné (hameçonnage)",
                          "127.0.1.105": "Domaine légitime détourné (logiciel malveillant)", "127.0.1.106": "Domaine légitime détourné (botnet)"],
                  refusalCodes: spamhausRefusals.merging(["127.0.1.255": "Requête refusée\u{00A0}: la DBL ne répond pas pour une adresse IP."]) { a, _ in a }),
        DNSBLList(name: "SURBL multi", zone: "multi.surbl.org", kind: .domain, removalURL: "https://www.surbl.org/surbl-analysis",
                  codes: ["127.0.0.8": "Hameçonnage (PH)", "127.0.0.16": "Logiciel malveillant (MW)", "127.0.0.64": "Pourriel et abus (ABUSE)",
                          "127.0.0.128": "Site piraté (CR)", "127.0.0.24": "Hameçonnage et logiciel malveillant", "127.0.0.72": "Hameçonnage et abus",
                          "127.0.0.80": "Logiciel malveillant et abus"],
                  refusalCodes: ["127.0.0.1": "Requête refusée\u{00A0}: résolveur public ou volume trop élevé."]),
        DNSBLList(name: "URIBL multi", zone: "multi.uribl.com", kind: .domain, removalURL: "https://admin.uribl.com/",
                  codes: ["127.0.0.2": "URIBL black\u{00A0}: domaine de pourriel", "127.0.0.4": "URIBL grey\u{00A0}: domaine d’envois en masse douteux",
                          "127.0.0.8": "URIBL red\u{00A0}: domaine récent vu dans du pourriel", "127.0.0.14": "Listé dans plusieurs sous-listes URIBL"],
                  refusalCodes: ["127.0.0.1": "Requête refusée\u{00A0}: URIBL bloque les résolveurs publics ou trop sollicités."]),
        DNSBLList(name: "SEM URIBL", zone: "uribl.spameatingmonkey.net", kind: .domain, weight: .minor,
                  removalURL: "https://spameatingmonkey.com/lookup",
                  codes: ["127.0.0.2": "Domaine vu dans du pourriel"]),
        DNSBLList(name: "Nordspam DBL", zone: "dbl.nordspam.com", kind: .domain, weight: .minor, removalURL: "https://www.nordspam.com/",
                  codes: ["127.0.0.2": "Domaine vu dans du pourriel"]),
    ]

    public static var active: [DNSBLList] { all.filter(\.isActive) }
    public static func lists(for kind: DNSBLList.Kind, includeInactive: Bool = false) -> [DNSBLList] {
        all.filter { $0.kind == kind && (includeInactive || $0.isActive) }
    }
}

/// Ce qu'on cherche : une adresse IPv4 ou un domaine.
public enum DNSBLTarget: Hashable, Sendable {
    case ip(IPv4Address)
    case domain(String)

    public var kind: DNSBLList.Kind {
        if case .ip = self { return .ip } else { return .domain }
    }

    public var label: String {
        switch self {
        case .ip(let ip): return ip.description
        case .domain(let name): return name
        }
    }
}

public struct DNSBLResult: Hashable, Sendable, Identifiable {
    public enum State: Hashable, Sendable {
        case clean
        /// Codes de retour (127.0.0.x) et leur explication.
        case listed([String])
        /// Requête refusée par la liste (code de refus).
        case refused(String)
        case failed(String)
        case skipped(String)
    }

    public var id: String { list.zone + "|" + target }
    public var list: DNSBLList
    public var target: String
    public var queryName: String
    public var state: State
    /// Raison donnée par la liste (TXT au même nom), quand elle est listée.
    public var reason: String?
    public var durationMs: Double

    public var isListed: Bool { if case .listed = state { return true } else { return false } }

    public var status: MailStatus {
        switch state {
        case .clean: return .ok
        case .listed: return list.weight == .major ? .error : .warning
        case .refused, .failed: return .info
        case .skipped: return .info
        }
    }

    /// « Listé : 127.0.0.2 (SBL : source de pourriel connue) », « Absent »…
    public var stateLabel: String {
        switch state {
        case .clean: return "Absent"
        case .listed(let codes): return "Listé (\(codes.joined(separator: ", ")))"
        case .refused: return "Refusé"
        case .failed: return "Indéterminé"
        case .skipped: return "Non interrogé"
        }
    }

    public var explanation: String {
        switch state {
        case .clean: return "Aucune inscription."
        case .listed(let codes):
            let meanings = codes.map { DNSBL.explain(code: $0, list: list).meaning }
            var seen: Set<String> = []
            var text = meanings.filter { seen.insert($0).inserted }.joined(separator: " · ")
            if let reason, !reason.isEmpty { text += " — « \(reason) »" }
            return text
        case .refused(let text), .failed(let text), .skipped(let text): return text
        }
    }
}

public struct DNSBLReport: Hashable, Sendable {
    public var targets: [String]
    public var results: [DNSBLResult]

    public var listed: [DNSBLResult] { results.filter(\.isListed) }
    public var majorListings: [DNSBLResult] { listed.filter { $0.list.weight == .major } }
    public var checkedCount: Int { results.filter { if case .clean = $0.state { return true }; return $0.isListed }.count }
    public var undetermined: Int { results.filter { if case .failed = $0.state { return true }; if case .refused = $0.state { return true }; return false }.count }

    public var status: MailStatus {
        if !majorListings.isEmpty { return .error }
        if !listed.isEmpty { return .warning }
        if checkedCount == 0 && !results.isEmpty { return .warning }
        return .ok
    }

    /// « 1 inscription sur 17 listes · 2 indéterminées »
    public var summary: String {
        var text: String
        let count = listed.count
        text = count == 0 ? "Aucune inscription" : "\(count) inscription\(count > 1 ? "s" : "")"
        text += " sur \(results.count) requête\(results.count > 1 ? "s" : "")"
        if undetermined > 0 { text += " · \(undetermined) indéterminée\(undetermined > 1 ? "s" : "")" }
        return text
    }

    public var findings: [MailFinding] {
        var result: [MailFinding] = []
        // Une inscription par liste (plusieurs adresses d'un même réseau listées ensemble).
        var zones: [String] = []
        for item in listed where !zones.contains(item.list.zone) { zones.append(item.list.zone) }
        for zone in zones {
            let items = listed.filter { $0.list.zone == zone }
            let list = items[0].list
            let who = items.count > 1 ? "\(items.count) adresses" : items[0].target
            let title = "\(who) listé\(items.count > 1 ? "es" : "") dans \(list.name)"
            let detail = (items.count > 1 ? items.map(\.target).joined(separator: ", ") + "\u{00A0}: " : "") + items[0].explanation
            let fix: String
            if list.weight == .minor {
                fix = "Liste peu suivie\u{00A0}: surveiller plutôt qu’agir" + (list.removalURL.map { " (détail\u{00A0}: \($0))" } ?? "") + "."
            } else {
                fix = list.removalURL.map { "Corriger la cause (machine infectée, relais ouvert, envoi en masse), puis demander le retrait\u{00A0}: \($0)" }
                    ?? "Corriger la cause\u{00A0}; l’inscription expire d’elle-même."
            }
            result.append(MailFinding(list.weight == .major ? .error : .warning, title, detail, fix: fix))
        }
        let refused = results.filter { if case .refused = $0.state { return true }; return false }
        if !refused.isEmpty {
            result.append(MailFinding(.info, "\(refused.count) liste\(refused.count > 1 ? "s ont" : " a") refusé la requête",
                                      refused.first?.explanation ?? "", fix: "Interroger par le résolveur du FAI plutôt qu’un résolveur public."))
        }
        if result.isEmpty && checkedCount > 0 {
            result.append(MailFinding(.ok, "Aucune inscription", "\(checkedCount) liste\(checkedCount > 1 ? "s" : "") vérifiée\(checkedCount > 1 ? "s" : "")."))
        }
        return result
    }
}

public enum DNSBL {
    /// « 203.0.113.25 » → « 25.113.0.203 ».
    public static func reversed(_ ip: IPv4Address) -> String {
        let o = ip.octets
        return "\(o.3).\(o.2).\(o.1).\(o.0)"
    }

    /// Nom interrogé : « 25.113.0.203.zen.spamhaus.org » ou « exemple.ca.dbl.spamhaus.org ».
    public static func queryName(_ target: DNSBLTarget, list: DNSBLList) -> String {
        switch target {
        case .ip(let ip): return reversed(ip) + "." + list.zone
        case .domain(let name): return MailDNSText.normalize(name) + "." + list.zone
        }
    }

    /// Sens d'un code de retour, et s'il s'agit d'un refus.
    public static func explain(code: String, list: DNSBLList) -> (meaning: String, isRefusal: Bool) {
        if let refusal = list.refusalCodes[code] { return (refusal, true) }
        if let meaning = list.codes[code] { return (meaning, false) }
        guard let ip = IPv4Address(code), ip.octets.0 == 127 else {
            return ("Réponse inattendue hors de 127.0.0.0/8 (le DNS du FAI remplace peut-être les noms inexistants)", true)
        }
        return ("Inscrit (code \(code))", false)
    }

    /// Classe la réponse d'une liste.
    public static func classify(_ answer: MailDNSAnswer, list: DNSBLList) -> DNSBLResult.State {
        switch answer.outcome {
        case .nxdomain: return .clean
        case .failure(let text): return .failed("Requête sans réponse\u{00A0}: \(text)")
        case .answer:
            if answer.values.isEmpty { return .clean }
            var listed: [String] = []
            var refusals: [String] = []
            for code in answer.values {
                let explained = explain(code: code, list: list)
                if explained.isRefusal { refusals.append(explained.meaning) } else { listed.append(code) }
            }
            if !listed.isEmpty { return .listed(listed.sorted()) }
            return .refused(refusals.first ?? "Requête refusée.")
        }
    }

    /// Vérifie les cibles dans les listes de leur type. Au plus `concurrency` requêtes à la fois,
    /// espacées de `spacing` secondes (par défaut, le rythme du client). Une adresse réservée (privée, boucle locale) n'est pas interrogée.
    public static func check(_ targets: [DNSBLTarget], lists: [DNSBLList] = DNSBLCatalog.active, client: MailDNSClient,
                             concurrency: Int = 3, spacing: TimeInterval? = nil) async -> DNSBLReport {
        struct Job: Sendable { var target: DNSBLTarget; var list: DNSBLList }
        var jobs: [Job] = []
        var skipped: [DNSBLResult] = []
        for target in targets {
            for list in lists where list.kind == target.kind {
                if case .ip(let ip) = target, MailDNSText.isReserved(ip) {
                    skipped.append(DNSBLResult(list: list, target: target.label, queryName: queryName(target, list: list),
                                               state: .skipped("Adresse privée ou réservée\u{00A0}: absente des listes publiques."),
                                               reason: nil, durationMs: 0))
                    continue
                }
                jobs.append(Job(target: target, list: list))
            }
        }
        let results = await mailConcurrentMap(jobs, limit: concurrency, spacing: spacing ?? client.pacing) { job -> DNSBLResult in
            let name = queryName(job.target, list: job.list)
            let start = Date()
            let answer = await client.query(name, .a)
            let state = classify(answer, list: job.list)
            var reason: String?
            if case .listed = state {
                let txt = await client.query(name, .txt)
                reason = txt.values.first
            }
            return DNSBLResult(list: job.list, target: job.target.label, queryName: name, state: state, reason: reason,
                               durationMs: Date().timeIntervalSince(start) * 1000)
        }
        return DNSBLReport(targets: targets.map(\.label), results: results + skipped)
    }
}
