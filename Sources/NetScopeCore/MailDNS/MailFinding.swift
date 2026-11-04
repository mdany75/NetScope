import Foundation

// Constats et vérifications communs aux outils courriel : un état coloré (OK, information,
// avertissement, erreur), un titre, une explication et, au besoin, la correction à faire.

/// État d'une vérification ; l'ordre va du meilleur au pire.
public enum MailStatus: String, Codable, Hashable, Sendable, Comparable, CaseIterable {
    case ok, info, warning, error

    public var label: String {
        switch self {
        case .ok: return "OK"
        case .info: return "Info"
        case .warning: return "Avertissement"
        case .error: return "Erreur"
        }
    }

    var rank: Int {
        switch self {
        case .ok: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: MailStatus, rhs: MailStatus) -> Bool { lhs.rank < rhs.rank }

    /// Le pire état d'une liste (OK si la liste est vide).
    public static func worst(_ statuses: [MailStatus]) -> MailStatus { statuses.max() ?? .ok }
}

/// Un constat sur un enregistrement (« Plus de 10 recherches DNS », « Politique none »).
public struct MailFinding: Codable, Hashable, Sendable {
    public var status: MailStatus
    public var title: String
    public var detail: String
    /// Ce qu'il faut faire ; nil quand il n'y a rien à corriger.
    public var fix: String?

    public init(_ status: MailStatus, _ title: String, _ detail: String = "", fix: String? = nil) {
        self.status = status
        self.title = title
        self.detail = detail
        self.fix = fix
    }
}

extension Array where Element == MailFinding {
    /// Le pire état des constats (OK sans constat).
    public var worstStatus: MailStatus { MailStatus.worst(map(\.status)) }

    /// Constats triés du plus grave au moins grave, ordre d'origine conservé à gravité égale.
    public var bySeverity: [MailFinding] {
        enumerated().sorted { ($1.element.status.rank, $0.offset) < ($0.element.status.rank, $1.offset) }.map(\.element)
    }
}

/// Catégorie d'une vérification (Super outil, Santé courriel).
public enum MailCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case address, resolution, mx, ptr, spf, dkim, dmarc, bimi, mtasts, tlsrpt, blacklist, dnssec

    public var label: String {
        switch self {
        case .address: return "Adresse"
        case .resolution: return "Résolution"
        case .mx: return "MX"
        case .ptr: return "DNS inverse"
        case .spf: return "SPF"
        case .dkim: return "DKIM"
        case .dmarc: return "DMARC"
        case .bimi: return "BIMI"
        case .mtasts: return "MTA-STS"
        case .tlsrpt: return "TLS-RPT"
        case .blacklist: return "Listes noires"
        case .dnssec: return "DNSSEC"
        }
    }

    /// Points de la catégorie dans la note de santé (BIMI et les autres : aucun).
    public var maxPoints: Int {
        switch self {
        case .mx: return 15
        case .spf: return 20
        case .dkim: return 15
        case .dmarc: return 20
        case .blacklist: return 15
        case .mtasts: return 6
        case .tlsrpt: return 4
        case .dnssec: return 5
        default: return 0
        }
    }
}

/// Une ligne du bilan : catégorie, état, résultat court, détail, points obtenus.
public struct MailCheck: Codable, Hashable, Sendable, Identifiable {
    public var id: String { category.rawValue + "|" + title }
    public var category: MailCategory
    public var status: MailStatus
    /// « SPF », « MX 10 mx1.exemple.ca »…
    public var title: String
    /// « 11 recherches DNS (limite 10) »
    public var result: String
    public var detail: String
    /// Points obtenus et possibles ; nil : la vérification ne compte pas dans la note (ou n'a pas
    /// pu être faite).
    public var points: Int?
    public var maxPoints: Int?

    public init(_ category: MailCategory, status: MailStatus, title: String? = nil, result: String, detail: String = "",
                points: Int? = nil, maxPoints: Int? = nil) {
        self.category = category
        self.status = status
        self.title = title ?? category.label
        self.result = result
        self.detail = detail
        self.points = points
        self.maxPoints = maxPoints
    }

    /// « 8 / 20 », ou « — ».
    public var pointsLabel: String {
        guard let points, let maxPoints else { return "—" }
        return "\(points)\u{00A0}/\u{00A0}\(maxPoints)"
    }
}

// MARK: - Étiquettes « clé=valeur »

/// Liste « clé=valeur » séparée par des points-virgules (DMARC, DKIM, BIMI, MTA-STS, TLS-RPT).
public struct MailTagList: Hashable, Sendable {
    public var tags: [(key: String, value: String)]
    /// Fautes de syntaxe : étiquette sans « = », clé vide, clé en double.
    public var errors: [String]

    public static func == (lhs: MailTagList, rhs: MailTagList) -> Bool {
        lhs.tags.map { "\($0.key)=\($0.value)" } == rhs.tags.map { "\($0.key)=\($0.value)" } && lhs.errors == rhs.errors
    }

    public func hash(into hasher: inout Hasher) {
        for tag in tags { hasher.combine(tag.key); hasher.combine(tag.value) }
        hasher.combine(errors)
    }

    /// « v=DMARC1; p=none; rua=mailto:x@y » ; les clés sont mises en minuscules, les espaces
    /// autour des valeurs retirés. Un point-virgule final est permis.
    public static func parse(_ text: String) -> MailTagList {
        var tags: [(String, String)] = []
        var errors: [String] = []
        var seen: Set<String> = []
        for piece in text.split(separator: ";", omittingEmptySubsequences: false) {
            let item = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { continue }
            guard let equal = item.firstIndex(of: "=") else {
                errors.append("« \(item) » n’a pas la forme clé=valeur.")
                continue
            }
            let key = item[..<equal].trimmingCharacters(in: .whitespaces).lowercased()
            let value = item[item.index(after: equal)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                errors.append("Clé invalide dans « \(item) ».")
                continue
            }
            if seen.contains(key) {
                errors.append("La clé « \(key) » apparaît deux fois.")
                continue
            }
            seen.insert(key)
            tags.append((key, value))
        }
        return MailTagList(tags: tags, errors: errors)
    }

    public subscript(_ key: String) -> String? { tags.first { $0.key == key }?.value }
    public var keys: [String] { tags.map(\.key) }
}

/// Une adresse de rapport (« mailto:dmarc@exemple.ca!10m ») réduite à son domaine.
public enum MailURI {
    /// « mailto:dmarc@exemple.ca!10m » → « dmarc@exemple.ca » ; nil si ce n'est pas un mailto valide.
    public static func mailbox(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("mailto:") else { return nil }
        var address = String(trimmed.dropFirst(7))
        if let bang = address.firstIndex(of: "!") { address = String(address[..<bang]) }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, MailDNSText.isDomainName(String(parts[1])) else { return nil }
        return address
    }

    public static func domain(ofMailbox mailbox: String) -> String? {
        mailbox.split(separator: "@").last.map { MailDNSText.normalize(String($0)) }
    }

    /// Liste d'adresses séparées par des virgules.
    public static func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Exécute `body` sur chaque élément avec au plus `limit` tâches à la fois, en espaçant les
/// départs de `spacing` secondes ; résultats dans l'ordre des éléments.
func mailConcurrentMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, spacing: TimeInterval = 0,
                                                  _ body: @escaping @Sendable (T) async -> R) async -> [R] {
    guard !items.isEmpty else { return [] }
    var results = [R?](repeating: nil, count: items.count)
    await withTaskGroup(of: (Int, R).self) { group in
        var next = 0
        func start() {
            let index = next
            let item = items[index]
            next += 1
            group.addTask { (index, await body(item)) }
        }
        for _ in 0..<min(max(limit, 1), items.count) {
            start()
            if spacing > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
        }
        while let (index, result) = await group.next() {
            results[index] = result
            if next < items.count {
                if spacing > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
                start()
            }
        }
    }
    return results.compactMap { $0 }
}
