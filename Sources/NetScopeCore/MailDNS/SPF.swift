import Darwin
import Foundation

// SPF (RFC 7208) : lecture d'un enregistrement « v=spf1 … », puis analyse récursive des include
// et redirect pour compter les recherches DNS (limite de 10), repérer les boucles, les include
// sans SPF, les recherches vides (limite de 2) et la règle finale (+all, ?all, ~all, -all).

/// Un terme d'un enregistrement SPF : mécanisme (avec qualificatif) ou modificateur.
public struct SPFTerm: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case all, include, a, mx, ptr, ip4, ip6, exists, redirect, exp, modifier, unknown
    }

    public var kind: Kind
    /// « + » (par défaut), « - », « ~ » ou « ? » ; nil pour un modificateur.
    public var qualifier: Character?
    /// Domaine visé (« _spf.google.com »), réseau (« 203.0.113.0/24 »), ou valeur du modificateur.
    public var value: String?
    public var raw: String

    /// Mécanismes et modificateurs qui coûtent une recherche DNS (RFC 7208 §4.6.4).
    public var countsLookup: Bool { [.include, .a, .mx, .ptr, .exists, .redirect].contains(kind) }

    public var isMechanism: Bool { ![.redirect, .exp, .modifier].contains(kind) }

    /// Domaine visé par un mécanisme a/mx/include/exists ou par redirect, sans la longueur de
    /// préfixe ; nil s'il n'y en a pas (a et mx sans domaine visent le domaine évalué).
    public var targetDomain: String? {
        guard var value, [.include, .a, .mx, .exists, .redirect, .ptr].contains(kind) else { return nil }
        if kind == .a || kind == .mx, let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        return value.isEmpty ? nil : value
    }

    /// Le domaine contient une macro (« %{i}._spf.exemple.ca ») : il n'est pas évalué ici.
    public var hasMacro: Bool { value?.contains("%") ?? false }

    public var qualifierLabel: String {
        switch qualifier {
        case "-": return "échec (-)"
        case "~": return "échec léger (~)"
        case "?": return "neutre (?)"
        default: return "réussite (+)"
        }
    }
}

/// Enregistrement SPF lu.
public struct SPFRecord: Hashable, Sendable {
    public var text: String
    public var terms: [SPFTerm]
    /// Fautes qui rendent l'enregistrement invalide (permerror).
    public var errors: [String]
    /// Remarques sans gravité (termes après « all », redirect ignoré, ptr déconseillé).
    public var warnings: [String]

    public var mechanisms: [SPFTerm] { terms.filter(\.isMechanism) }
    public var all: SPFTerm? { terms.first { $0.kind == .all } }
    public var redirect: SPFTerm? { terms.first { $0.kind == .redirect } }
    /// Recherches DNS dues à cet enregistrement seul (sans ses include).
    public var ownLookups: Int { terms.filter(\.countsLookup).count - (all != nil && redirect != nil ? 1 : 0) }

    /// L'enregistrement commence par « v=spf1 » (suivi d'une espace ou de rien).
    public static func isSPF(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        return lower == "v=spf1" || lower.hasPrefix("v=spf1 ")
    }

    /// Lit un enregistrement ; nil si ce n'est pas un SPF.
    public static func parse(_ text: String) -> SPFRecord? {
        guard isSPF(text) else { return nil }
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).dropFirst()
        var record = SPFRecord(text: text, terms: [], errors: [], warnings: [])
        var afterAll = false
        for token in tokens {
            let term = parseTerm(token, errors: &record.errors)
            if afterAll && term.isMechanism {
                record.warnings.append("« \(token) » vient après « all » : il n’est jamais évalué.")
            }
            if term.kind == .all { afterAll = true }
            record.terms.append(term)
        }
        for kind in [SPFTerm.Kind.redirect, .exp] where record.terms.filter({ $0.kind == kind }).count > 1 {
            record.errors.append("Le modificateur « \(kind.rawValue)= » apparaît plusieurs fois.")
        }
        if record.all != nil && record.redirect != nil {
            record.warnings.append("« redirect= » est ignoré parce que l’enregistrement contient « all ».")
        }
        if record.terms.contains(where: { $0.kind == .ptr }) {
            record.warnings.append("Le mécanisme « ptr » est déconseillé (RFC 7208 §5.5) : lent et peu fiable.")
        }
        return record
    }

    static func parseTerm(_ token: String, errors: inout [String]) -> SPFTerm {
        // Modificateur : nom=valeur (le nom ne contient ni « : » ni « / »).
        if let equal = token.firstIndex(of: "="),
           !token[..<equal].contains(":"), !token[..<equal].contains("/"),
           token[..<equal].first?.isLetter == true {
            let name = token[..<equal].lowercased()
            let value = String(token[token.index(after: equal)...])
            let kind: SPFTerm.Kind = name == "redirect" ? .redirect : (name == "exp" ? .exp : .modifier)
            if (kind == .redirect || kind == .exp) && value.isEmpty {
                errors.append("« \(token) » : domaine manquant.")
            }
            return SPFTerm(kind: kind, qualifier: nil, value: value, raw: token)
        }
        var body = Substring(token)
        var qualifier: Character = "+"
        if let first = body.first, "+-~?".contains(first) {
            qualifier = first
            body = body.dropFirst()
        }
        let nameEnd = body.firstIndex(where: { $0 == ":" || $0 == "/" }) ?? body.endIndex
        let name = body[..<nameEnd].lowercased()
        var value: String? = nil
        if nameEnd < body.endIndex {
            value = body[nameEnd] == ":" ? String(body[body.index(after: nameEnd)...]) : String(body[nameEnd...])
        }
        let kind = SPFTerm.Kind(rawValue: name).flatMap { [.redirect, .exp, .modifier, .unknown].contains($0) ? nil : $0 } ?? .unknown
        let term = SPFTerm(kind: kind, qualifier: qualifier, value: value, raw: token)
        switch kind {
        case .unknown:
            errors.append("Mécanisme inconnu « \(token) ».")
        case .all:
            if value != nil { errors.append("« \(token) » : « all » ne prend pas de valeur.") }
        case .include, .exists:
            if (value ?? "").isEmpty { errors.append("« \(token) » : domaine manquant.") }
        case .ip4:
            if !validIP4(value ?? "") { errors.append("« \(token) » : réseau IPv4 invalide.") }
        case .ip6:
            if !validIP6(value ?? "") { errors.append("« \(token) » : réseau IPv6 invalide.") }
        case .a, .mx:
            if let value, !validDomainCIDR(value) { errors.append("« \(token) » : domaine ou préfixe invalide.") }
        default:
            break
        }
        return term
    }

    static func validIP4(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), IPv4Address(String(parts[0])) != nil else { return false }
        if parts.count == 2 { return Int(parts[1]).map { (0...32).contains($0) } ?? false }
        return true
    }

    static func validIP6(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        var storage = in6_addr()
        guard inet_pton(AF_INET6, String(parts[0]), &storage) == 1 else { return false }
        if parts.count == 2 { return Int(parts[1]).map { (0...128).contains($0) } ?? false }
        return true
    }

    /// « exemple.ca », « exemple.ca/24 », « /24 », « exemple.ca/24//64 ».
    static func validDomainCIDR(_ text: String) -> Bool {
        let pieces = text.components(separatedBy: "/")
        let domain = pieces[0]
        if !domain.isEmpty && !domain.contains("%") && !MailDNSText.isDomainName(domain) { return false }
        let numbers = pieces.dropFirst().filter { !$0.isEmpty }
        return numbers.allSatisfy { Int($0) != nil } && pieces.count <= 4
    }
}

/// Un nœud de l'arbre SPF : le domaine racine, puis chaque include ou redirect suivi.
public struct SPFNode: Hashable, Sendable, Identifiable {
    public var id: Int
    public var depth: Int
    public var domain: String
    /// « racine », « include », « redirect ».
    public var via: String
    /// Enregistrement trouvé ; nil si absent.
    public var record: String?
    /// Recherches DNS dues à cet enregistrement seul.
    public var lookups: Int
    /// Recherches cumulées de ce nœud et de ses descendants.
    public var subtreeLookups: Int
    public var problem: String?
}

/// Résultat de l'analyse SPF d'un domaine.
public struct SPFReport: Hashable, Sendable {
    public var domain: String
    /// Enregistrement SPF du domaine (le premier s'il y en a plusieurs).
    public var record: SPFRecord?
    /// Nombre d'enregistrements « v=spf1 » au domaine (plus d'un : permerror).
    public var recordCount: Int
    public var nodes: [SPFNode]
    public var totalLookups: Int
    public var voidLookups: Int
    /// Qualificatif de la règle finale effective (après redirect) ; nil sans « all ».
    public var allQualifier: Character?
    public var findings: [MailFinding]
    public var queryFailed: Bool

    public var status: MailStatus { findings.worstStatus }
    public var isPermError: Bool { findings.contains { $0.status == .error } }

    /// « 11 recherches DNS · ~all »
    public var summary: String {
        guard record != nil else { return queryFailed ? "Recherche impossible" : "Aucun enregistrement SPF" }
        var parts = ["\(totalLookups) recherche\(totalLookups > 1 ? "s" : "") DNS"]
        parts.append(allQualifier.map { "\($0)all" } ?? "sans all")
        return parts.joined(separator: " · ")
    }
}

public enum SPFAnalyzer {
    public static let lookupLimit = 10
    public static let voidLimit = 2
    static let maxDepth = 10
    static let maxNodes = 40

    /// Analyse le SPF de `domain` et de tous ses include/redirect.
    public static func analyze(_ domain: String, client: MailDNSClient) async -> SPFReport {
        let root = MailDNSText.normalize(domain)
        var state = State()
        let answer = await client.query(root, .txt)
        let spf = answer.values.filter(SPFRecord.isSPF)
        var report = SPFReport(domain: root, record: nil, recordCount: spf.count, nodes: [], totalLookups: 0, voidLookups: 0,
                               allQualifier: nil, findings: [], queryFailed: answer.isFailure)
        if let failure = answer.failureText {
            report.findings.append(MailFinding(.warning, "SPF non vérifié", "La recherche TXT de \(root) a échoué\u{00A0}: \(failure)."))
            return report
        }
        guard let first = spf.first, let record = SPFRecord.parse(first) else {
            report.findings.append(MailFinding(.error, "Aucun enregistrement SPF",
                "\(root) ne publie pas de TXT « v=spf1 »\u{00A0}: n’importe quel serveur peut envoyer en son nom.",
                fix: "Publier un TXT « v=spf1 » qui liste les serveurs d’envoi (ex. « v=spf1 include:spf.protection.outlook.com -all »)."))
            return report
        }
        report.record = record
        if spf.count > 1 {
            report.findings.append(MailFinding(.error, "\(spf.count) enregistrements SPF",
                "Un domaine ne doit publier qu’un seul TXT « v=spf1 »\u{00A0}: les destinataires rendent permerror.",
                fix: "Fusionner les enregistrements SPF en un seul."))
        }
        await visit(root, record: record, via: "racine", depth: 0, chain: [root], client: client, state: &state)
        report.nodes = state.nodes
        report.totalLookups = state.lookups
        report.voidLookups = state.voids
        report.allQualifier = state.rootAll
        report.findings += state.findings

        if state.lookups > lookupLimit {
            report.findings.append(MailFinding(.error, "\(state.lookups) recherches DNS (limite \(lookupLimit))",
                "Au-delà de \(lookupLimit) recherches, les destinataires rendent permerror\u{00A0}: le SPF ne protège plus et peut faire échouer DMARC.",
                fix: "Retirer les include inutiles, remplacer a et mx par des ip4/ip6, ou déléguer un service d’envoi à un sous-domaine."))
        } else if state.lookups >= lookupLimit - 1 {
            report.findings.append(MailFinding(.warning, "\(state.lookups) recherches DNS sur \(lookupLimit)",
                "Proche de la limite\u{00A0}: un fournisseur qui ajoute un include à son SPF suffira à la dépasser.",
                fix: "Garder une marge en retirant un include ou un mécanisme a/mx."))
        }
        if state.voids > voidLimit {
            report.findings.append(MailFinding(.warning, "\(state.voids) recherches vides (limite \(voidLimit))",
                "Des mécanismes visent des noms sans réponse\u{00A0}; au-delà de \(voidLimit), certains destinataires rendent permerror.",
                fix: "Retirer les mécanismes qui visent des noms inexistants."))
        }
        switch state.rootAll {
        case "+":
            report.findings.append(MailFinding(.error, "« +all » autorise tout le monde",
                "N’importe quel serveur d’Internet passe le SPF de ce domaine.",
                fix: "Remplacer « +all » par « -all » (ou « ~all » le temps de vérifier les envois)."))
        case "?":
            report.findings.append(MailFinding(.warning, "« ?all » est neutre",
                "Les serveurs non listés ne sont ni acceptés ni refusés\u{00A0}: le SPF ne protège presque pas.",
                fix: "Passer à « ~all », puis à « -all »."))
        case "~":
            report.findings.append(MailFinding(.ok, "« ~all » (échec léger)",
                "Les serveurs non listés sont marqués suspects\u{00A0}; avec DMARC, c’est une configuration courante."))
        case "-":
            report.findings.append(MailFinding(.ok, "« -all » (échec)", "Les serveurs non listés sont refusés."))
        default:
            report.findings.append(MailFinding(.warning, "Pas de règle « all »",
                "Sans « all », le résultat par défaut est neutre\u{00A0}: les serveurs non listés ne sont pas refusés.",
                fix: "Terminer l’enregistrement par « ~all » ou « -all »."))
        }
        if !report.findings.contains(where: { $0.status > .info }) {
            report.findings.insert(MailFinding(.ok, "SPF valide",
                "\(state.lookups) recherche\(state.lookups > 1 ? "s" : "") DNS sur \(lookupLimit) au plus."), at: 0)
        }
        return report
    }

    struct State {
        var nodes: [SPFNode] = []
        var lookups = 0
        var voids = 0
        var rootAll: Character?
        var findings: [MailFinding] = []
    }

    /// Visite un enregistrement : compte ses recherches, puis suit ses include et son redirect.
    /// Renvoie le nombre de recherches du sous-arbre.
    @discardableResult
    static func visit(_ domain: String, record: SPFRecord, via: String, depth: Int, chain: [String],
                      client: MailDNSClient, state: inout State) async -> Int {
        let index = state.nodes.count
        state.nodes.append(SPFNode(id: index, depth: depth, domain: domain, via: via, record: record.text,
                                   lookups: record.ownLookups, subtreeLookups: 0, problem: nil))
        let before = state.lookups
        state.lookups += record.ownLookups
        for error in record.errors {
            state.findings.append(MailFinding(.error, "Syntaxe SPF (\(domain))", error,
                                              fix: "Corriger l’enregistrement\u{00A0}: une faute de syntaxe rend tout le SPF invalide (permerror)."))
        }
        for warning in record.warnings {
            state.findings.append(MailFinding(.warning, "SPF de \(domain)", warning))
        }
        if depth == 0 { state.rootAll = record.all?.qualifier }

        for term in record.terms {
            switch term.kind {
            case .a, .mx:
                guard !term.hasMacro else { continue }
                let target = term.targetDomain.map(MailDNSText.normalize) ?? domain
                let answer = await client.query(target, term.kind == .a ? .a : .mx)
                if answer.isEmpty {
                    state.voids += 1
                    if term.kind == .mx || term.targetDomain != nil {
                        state.findings.append(MailFinding(.warning, "Recherche vide\u{00A0}: \(term.raw)",
                            "\(target) n’a pas d’enregistrement \(term.kind == .a ? "A" : "MX") (\(domain))."))
                    }
                } else if term.kind == .mx && answer.values.count > 10 {
                    state.findings.append(MailFinding(.error, "Trop de MX pour « \(term.raw) »",
                        "\(answer.values.count) serveurs MX\u{00A0}: un mécanisme mx ne peut pas en évaluer plus de 10."))
                }
            case .include:
                guard let target = term.targetDomain.map(MailDNSText.normalize) else { continue }
                if term.hasMacro {
                    state.findings.append(MailFinding(.info, "Include avec macro", "« \(term.raw) » dépend de l’expéditeur\u{00A0}: il n’est pas évalué ici."))
                    continue
                }
                await follow(target, via: "include", from: domain, depth: depth, chain: chain, client: client, state: &state)
            case .redirect:
                guard record.all == nil, let target = term.targetDomain.map(MailDNSText.normalize), !term.hasMacro else { continue }
                await follow(target, via: "redirect", from: domain, depth: depth, chain: chain, client: client, state: &state)
            default:
                break
            }
        }
        let subtree = state.lookups - before
        state.nodes[index].subtreeLookups = subtree
        return subtree
    }

    static func follow(_ target: String, via: String, from domain: String, depth: Int, chain: [String],
                       client: MailDNSClient, state: inout State) async {
        func node(_ problem: String) {
            state.nodes.append(SPFNode(id: state.nodes.count, depth: depth + 1, domain: target, via: via, record: nil,
                                       lookups: 0, subtreeLookups: 0, problem: problem))
        }
        if chain.contains(target) {
            node("boucle")
            state.findings.append(MailFinding(.error, "Boucle d’include",
                "\(domain) inclut \(target), déjà présent plus haut (\(chain.joined(separator: " → ")) → \(target)).",
                fix: "Retirer l’include qui revient vers un domaine déjà évalué."))
            return
        }
        guard depth + 1 <= maxDepth, state.nodes.count < maxNodes else {
            node("non suivi (profondeur)")
            return
        }
        let answer = await client.query(target, .txt)
        let spf = answer.values.filter(SPFRecord.isSPF)
        if let failure = answer.failureText {
            node("recherche impossible")
            state.findings.append(MailFinding(.warning, "\(via) \(target) non vérifié", "La recherche TXT a échoué\u{00A0}: \(failure)."))
            return
        }
        guard let first = spf.first, let record = SPFRecord.parse(first) else {
            if answer.isEmpty { state.voids += 1 }
            node("aucun SPF")
            state.findings.append(MailFinding(.error, "\(via == "include" ? "include" : "redirect")\u{00A0}: \(target) sans SPF",
                "\(domain) renvoie vers \(target), qui ne publie pas de « v=spf1 »\u{00A0}: permerror chez les destinataires.",
                fix: "Corriger le nom (faute de frappe\u{00A0}?) ou retirer ce \(via)."))
            return
        }
        if spf.count > 1 {
            state.findings.append(MailFinding(.error, "\(target)\u{00A0}: plusieurs SPF", "Le domaine inclus publie \(spf.count) enregistrements « v=spf1 »."))
        }
        let saved = state.rootAll
        await visit(target, record: record, via: via, depth: depth + 1, chain: chain + [target], client: client, state: &state)
        // Un redirect à la racine remplace la règle finale par celle du domaine visé.
        state.rootAll = (via == "redirect" && depth == 0) ? record.all?.qualifier : saved
    }
}
