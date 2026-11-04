import Foundation

/// Un critère de la recherche : un mot, une "phrase exacte" ou « préfixe:valeur », éventuellement
/// exclu par un signe moins (« -mot », « -type:imprimante »).
public struct SearchTerm: Hashable, Sendable, Identifiable {
    /// Rang du critère dans la requête.
    public let id: Int
    /// Champ visé ; nil pour un mot ou une phrase cherchés dans tous les champs.
    public let field: SearchField?
    /// Valeur telle qu'elle a été saisie (sans guillemets ni préfixe).
    public let value: String
    public let isNegated: Bool
    /// Valeur entre guillemets (droits, « », “ ”).
    public let isPhrase: Bool
    /// Texte d'origine du critère (« -switch:"SW ETG2" »), pour reconstruire la requête.
    public let source: String
    /// Valeur normalisée (minuscules, sans accents), calculée une fois.
    let folded: String

    /// Faux tant que la valeur manque (« switch: » en cours de saisie) : le critère ne filtre rien.
    public var isComplete: Bool { !folded.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Texte de l'étiquette : « Switch : SW-ETG2 », « “salle 204” », « brother ».
    public var label: String {
        let shown = isPhrase ? SearchTerm.quoted(value) : value
        guard let field else { return shown }
        return "\(field.label)\u{00A0}: \(shown)"
    }

    /// Bulle d'aide de l'étiquette.
    public var help: String {
        let what: String
        if let field {
            switch field.kind {
            case .ip: what = "\(field.label) commençant par \(SearchTerm.quoted(value)) (ou dans le bloc CIDR)"
            case .mac: what = "\(field.label) contenant \(SearchTerm.quoted(value)) (séparateurs ignorés)"
            case .number:
                what = value.allSatisfy(\.isNumber) ? "\(field.label) égal à \(value)" : "\(field.label) contenant \(SearchTerm.quoted(value))"
            case .text: what = "\(field.label) contenant \(SearchTerm.quoted(value))"
            }
        } else {
            what = isPhrase ? "Expression exacte \(SearchTerm.quoted(value)) dans une colonne" : "\(SearchTerm.quoted(value)) dans n’importe quelle colonne"
        }
        return (isNegated ? "Exclut\u{00A0}: " : "") + what + ". Cliquez sur × pour retirer ce critère."
    }

    static func quoted(_ text: String) -> String { "«\u{00A0}\(text)\u{00A0}»" }
}

/// Requête de recherche analysée selon les champs d'un module.
///
/// - mots séparés par des espaces : tous à la fois (ET) ;
/// - « préfixe:valeur » : la valeur dans ce champ (`switch:SW-ETG2`, `vlan:30`, `ip:10.20.0.0/16`) ;
/// - « -mot » ou « -préfixe:valeur » : exclut ;
/// - "phrase exacte" (guillemets droits, « » ou “ ”), aussi après un préfixe (`site:"Saint-Jean"`) ;
/// - insensible à la casse et aux accents ; un préfixe inconnu du module reste du texte ;
/// - un mot sans préfixe est cherché dans toutes les colonnes, comme avant.
public struct SearchQuery: Sendable {
    public let text: String
    public let schema: SearchSchema
    public let terms: [SearchTerm]

    public init(_ text: String, schema: SearchSchema) {
        self.text = text
        self.schema = schema
        self.terms = SearchQuery.parse(text, schema: schema)
    }

    /// Aucun critère complet : tout correspond.
    public var isEmpty: Bool { !terms.contains(where: \.isComplete) }

    /// Critères qui portent sur un champ (affichés en étiquettes).
    public var fieldTerms: [SearchTerm] { terms.filter { $0.field != nil } }

    // MARK: Correspondance

    public func matches<Record: SearchableRecord>(_ record: Record) -> Bool {
        var freeText: [String]?
        for term in terms where term.isComplete {
            let found: Bool
            if let field = term.field {
                found = SearchQuery.match(term, kind: field.kind, values: record.searchValues(for: field))
            } else {
                if freeText == nil { freeText = record.searchFreeText.map(SearchText.fold) }
                found = freeText!.contains { $0.contains(term.folded) }
            }
            if found == term.isNegated { return false }
        }
        return true
    }

    public func filter<Records: Sequence>(_ records: Records) -> [Records.Element] where Records.Element: SearchableRecord {
        isEmpty ? Array(records) : records.filter { matches($0) }
    }

    static func match(_ term: SearchTerm, kind: SearchMatchKind, values: [String]) -> Bool {
        let needle = term.folded
        switch kind {
        case .text:
            return values.contains { SearchText.fold($0).contains(needle) }
        case .mac:
            let hex = SearchText.hexDigits(needle)
            guard !hex.isEmpty, hex.count == needle.filter({ !":-. ".contains($0) }).count else {
                return values.contains { SearchText.fold($0).contains(needle) }
            }
            return values.contains { SearchText.hexDigits($0).contains(hex) }
        case .number:
            if let number = Int(needle.prefix(9)), needle.allSatisfy(\.isNumber) {
                return values.contains { SearchText.lastNumber($0) == number }
            }
            return values.contains { SearchText.fold($0).contains(needle) }
        case .ip:
            return values.contains { ipMatches($0, needle) }
        }
    }

    /// `10.20.` : préfixe ; `10.20` : 10.20.x.x (aligné sur les octets) ; adresse complète :
    /// égalité ; `10.20.0.0/16` : dans le bloc. Autre chose : « contient ».
    static func ipMatches(_ value: String, _ needle: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespaces)
        if needle.contains("/") {
            guard let subnet = try? Subnet(parsing: needle) else { return SearchText.fold(candidate).contains(needle) }
            return IPv4Address(candidate).map(subnet.contains) ?? false
        }
        guard needle.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else {
            return SearchText.fold(candidate).contains(needle)
        }
        if needle.hasSuffix(".") { return candidate.hasPrefix(needle) }
        if needle.filter({ $0 == "." }).count == 3, let address = IPv4Address(needle) {
            return IPv4Address(candidate) == address
        }
        return candidate == needle || candidate.hasPrefix(needle + ".")
    }

    // MARK: Édition

    /// Requête sans ce critère (clic sur × d'une étiquette).
    public func removing(_ term: SearchTerm) -> String {
        terms.filter { $0.id != term.id }.map(\.source).joined(separator: " ")
    }

    /// Requête après le choix d'un préfixe dans les suggestions : le mot en cours de saisie est
    /// remplacé s'il commence ce préfixe (« sw » → « switch: »), sinon le préfixe est ajouté.
    public func inserting(_ field: SearchField) -> String {
        let prefix = field.key + ":"
        var kept = terms
        if let last = kept.last, !text.hasSuffix(" "), last.field == nil, !last.isPhrase, !last.isNegated,
           field.aliases.contains(where: { SearchText.fold($0).hasPrefix(last.folded) }) {
            kept.removeLast()
        }
        return (kept.map(\.source) + [prefix]).joined(separator: " ")
    }

    /// Mot en cours de saisie (dernier mot sans préfixe, sans espace après), pour filtrer les suggestions.
    public var pendingWord: String? {
        guard !text.hasSuffix(" "), let last = terms.last, last.field == nil, !last.isPhrase, !last.isNegated else { return nil }
        return last.value
    }

    // MARK: Analyse

    private static let quotePairs: [Character: Character] = ["\"": "\"", "«": "»", "“": "”", "„": "“", "‹": "›"]

    static func parse(_ text: String, schema: SearchSchema) -> [SearchTerm] {
        let chars = Array(text)
        var terms: [SearchTerm] = []
        var i = 0
        func isSpace(_ c: Character) -> Bool { c.isWhitespace }
        func readQuoted(_ open: Int) -> (String, Int) {
            let close = quotePairs[chars[open]] ?? "\""
            var j = open + 1
            var content = ""
            while j < chars.count, chars[j] != close {
                content.append(chars[j])
                j += 1
            }
            if j < chars.count { j += 1 }
            return (content.trimmingCharacters(in: .whitespaces), j)
        }
        func add(_ field: SearchField?, _ value: String, negated: Bool, phrase: Bool, from start: Int, to end: Int) {
            let source = String(chars[start..<end])
            terms.append(SearchTerm(id: terms.count, field: field, value: value, isNegated: negated, isPhrase: phrase,
                                    source: source, folded: SearchText.fold(value)))
        }

        while i < chars.count {
            while i < chars.count, isSpace(chars[i]) { i += 1 }
            guard i < chars.count else { break }
            let start = i
            var negated = false
            if chars[i] == "-", i + 1 < chars.count, !isSpace(chars[i + 1]) {
                negated = true
                i += 1
            }
            // "phrase exacte"
            if quotePairs[chars[i]] != nil {
                let (value, end) = readQuoted(i)
                i = end
                if !value.isEmpty { add(nil, value, negated: negated, phrase: true, from: start, to: end) }
                continue
            }
            // Préfixe éventuel : lettres jusqu'aux deux-points.
            let wordStart = i
            while i < chars.count, !isSpace(chars[i]), chars[i] != ":" { i += 1 }
            let word = String(chars[wordStart..<i])
            if i < chars.count, chars[i] == ":", !word.isEmpty, let field = schema.field(forPrefix: word) {
                i += 1
                if i < chars.count, quotePairs[chars[i]] != nil {
                    let (value, end) = readQuoted(i)
                    i = end
                    add(field, value, negated: negated, phrase: true, from: start, to: end)
                } else {
                    let valueStart = i
                    while i < chars.count, !isSpace(chars[i]) { i += 1 }
                    add(field, String(chars[valueStart..<i]), negated: negated, phrase: false, from: start, to: i)
                }
                continue
            }
            // Mot ordinaire (un préfixe inconnu, une MAC « 94:dd:… » ou une heure restent du texte).
            while i < chars.count, !isSpace(chars[i]) { i += 1 }
            add(nil, String(chars[wordStart..<i]), negated: negated, phrase: false, from: start, to: i)
        }
        return terms
    }
}
