import Foundation

// Note 58 : mode avant/après (comparaison de deux bilans), historique des bilans par site et texte
// à copier. Fonctions pures ; l'application lit et écrit le fichier du site.

/// Un écart entre deux bilans.
public struct LinkCheckDifference: Hashable, Sendable, Identifiable {
    public enum Change: String, Sendable, CaseIterable {
        case same, improved, degraded, changed, added, removed

        public var label: String {
            switch self {
            case .same: return "Identique"
            case .improved: return "Mieux"
            case .degraded: return "Moins bien"
            case .changed: return "Changé"
            case .added: return "Nouveau"
            case .removed: return "Disparu"
            }
        }

        /// Écart à surligner.
        public var isDifference: Bool { self != .same }
    }

    public var step: LinkCheckStepKind
    public var key: String
    public var label: String
    public var before: String?
    public var after: String?
    public var change: Change

    public var id: String { step.rawValue + "|" + key }

    public init(step: LinkCheckStepKind, key: String, label: String, before: String?, after: String?, change: Change) {
        self.step = step
        self.key = key
        self.label = label
        self.before = before
        self.after = after
        self.change = change
    }
}

public enum LinkCheckComparison {
    /// Compare `after` à `before`, étape par étape : l'état de chaque étape, puis chacun de ses
    /// constats. Un nombre dont le sens est connu (latence, perte, vitesse) est jugé mieux ou moins
    /// bien au-delà de sa tolérance (bruit de mesure) ; un texte différent est un changement.
    public static func compare(_ before: LinkCheckResult, _ after: LinkCheckResult) -> [LinkCheckDifference] {
        var result: [LinkCheckDifference] = []
        for kind in LinkCheckStepKind.allCases {
            let a = before.step(kind), b = after.step(kind)
            guard a != nil || b != nil else { continue }
            result.append(statusDifference(kind, a?.status, b?.status))
            var keys: [String] = []
            for fact in (a?.facts ?? []) + (b?.facts ?? []) where !keys.contains(fact.key) && !fact.isDetail { keys.append(fact.key) }
            for key in keys {
                result.append(factDifference(kind, a?.fact(key), b?.fact(key)))
            }
        }
        return result
    }

    static func statusDifference(_ kind: LinkCheckStepKind, _ a: LinkCheckStatus?, _ b: LinkCheckStatus?) -> LinkCheckDifference {
        let change: LinkCheckDifference.Change
        switch (a, b) {
        case let (a?, b?) where a == b: change = .same
        // Une étape non vérifiée d'un côté : on ne peut pas dire mieux ou moins bien.
        case let (a?, b?) where a == .skipped || b == .skipped: change = .changed
        case let (a?, b?): change = b < a ? .improved : .degraded
        case (nil, _?): change = .added
        default: change = .removed
        }
        return LinkCheckDifference(step: kind, key: "etat", label: "État", before: a?.label, after: b?.label, change: change)
    }

    static func factDifference(_ kind: LinkCheckStepKind, _ a: LinkCheckFact?, _ b: LinkCheckFact?) -> LinkCheckDifference {
        let label = b?.label ?? a?.label ?? ""
        let key = b?.key ?? a?.key ?? ""
        guard let a, let b else {
            return LinkCheckDifference(step: kind, key: key, label: label, before: a?.value, after: b?.value, change: a == nil ? .added : .removed)
        }
        var change: LinkCheckDifference.Change = a.value == b.value ? .same : .changed
        if let x = a.number, let y = b.number, let higher = b.higherIsBetter ?? a.higherIsBetter {
            let tolerance = max(a.tolerance ?? 0, b.tolerance ?? 0)
            if abs(y - x) <= tolerance {
                change = .same
            } else {
                change = (y > x) == higher ? .improved : .degraded
            }
        }
        return LinkCheckDifference(step: kind, key: key, label: label, before: a.value, after: b.value, change: change)
    }

    /// « 3 écarts : 2 améliorations, 1 dégradation » ; « Aucun écart ».
    public static func summary(_ differences: [LinkCheckDifference]) -> String {
        let shown = differences.filter(\.change.isDifference)
        guard !shown.isEmpty else { return "Aucun écart" }
        let improved = shown.filter { $0.change == .improved }.count
        let degraded = shown.filter { $0.change == .degraded }.count
        let other = shown.count - improved - degraded
        var parts: [String] = []
        if improved > 0 { parts.append("\(improved) amélioration\(improved > 1 ? "s" : "")") }
        if degraded > 0 { parts.append("\(degraded) dégradation\(degraded > 1 ? "s" : "")") }
        if other > 0 { parts.append("\(other) changement\(other > 1 ? "s" : "")") }
        return "\(shown.count) écart\(shown.count > 1 ? "s" : "")\u{00A0}: " + parts.joined(separator: ", ")
    }
}

/// Historique des bilans d'un site (sites/<id>/bilans-raccordement.json) : bilans du plus récent au
/// plus ancien, bilan de référence (« avant ») et bilans retenus pour le rapport.
public struct LinkCheckHistory: Codable, Hashable, Sendable {
    public static let fileName = "bilans-raccordement.json"
    public static let keep = 60

    public var results: [LinkCheckResult]
    /// Bilan « avant » choisi par le technicien.
    public var referenceID: UUID?
    /// Bilans retenus pour la section « Bilan de raccordement » du rapport.
    public var reportedIDs: [UUID]

    private enum CodingKeys: String, CodingKey { case results, referenceID, reportedIDs }

    /// Élément illisible, sauté.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public init(results: [LinkCheckResult] = [], referenceID: UUID? = nil, reportedIDs: [UUID] = []) {
        self.results = results.sorted { $0.date > $1.date }
        self.referenceID = referenceID
        self.reportedIDs = reportedIDs
    }

    /// Lecture élément par élément : un bilan illisible (version future) est ignoré sans faire
    /// tomber les autres.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var kept: [LinkCheckResult] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .results) {
            while !list.isAtEnd {
                if let value = try? list.decode(LinkCheckResult.self) {
                    kept.append(value)
                } else if (try? list.decode(Skip.self)) == nil {
                    break
                }
            }
        }
        results = kept.sorted { $0.date > $1.date }
        referenceID = try? c.decodeIfPresent(UUID.self, forKey: .referenceID)
        reportedIDs = ((try? c.decodeIfPresent([UUID].self, forKey: .reportedIDs)) ?? nil) ?? []
        let ids = Set(results.map(\.id))
        if let id = referenceID, !ids.contains(id) { referenceID = nil }
        reportedIDs.removeAll { !ids.contains($0) }
    }

    public var latest: LinkCheckResult? { results.first }
    public var reference: LinkCheckResult? { referenceID.flatMap { id in results.first { $0.id == id } } }
    public var reported: [LinkCheckResult] { results.filter { reportedIDs.contains($0.id) } }

    public func result(_ id: UUID) -> LinkCheckResult? { results.first { $0.id == id } }
    public func isReported(_ id: UUID) -> Bool { reportedIDs.contains(id) }

    /// Ajoute un bilan ; au-delà de `keep`, les plus anciens tombent (sauf la référence et ceux du rapport).
    public mutating func add(_ result: LinkCheckResult) {
        results.removeAll { $0.id == result.id }
        results.append(result)
        results.sort { $0.date > $1.date }
        while results.count > Self.keep {
            guard let index = results.lastIndex(where: { $0.id != referenceID && !reportedIDs.contains($0.id) }) else { break }
            results.remove(at: index)
        }
    }

    public mutating func remove(_ id: UUID) {
        results.removeAll { $0.id == id }
        if referenceID == id { referenceID = nil }
        reportedIDs.removeAll { $0 == id }
    }

    /// Choisit (ou retire, avec nil) le bilan « avant ».
    public mutating func setReference(_ id: UUID?) {
        referenceID = id.flatMap { id in results.contains { $0.id == id } ? id : nil }
    }

    public mutating func report(_ id: UUID) {
        guard results.contains(where: { $0.id == id }), !reportedIDs.contains(id) else { return }
        reportedIDs.append(id)
    }

    public mutating func unreport(_ id: UUID) { reportedIDs.removeAll { $0 == id } }

    /// Bilan précédent (plus ancien que `result`).
    public func previous(before result: LinkCheckResult) -> LinkCheckResult? {
        results.first { $0.date < result.date && $0.id != result.id }
    }

    /// Bilan de comparaison par défaut : la référence « avant » si elle est plus ancienne, sinon le
    /// bilan précédent.
    public func baseline(for result: LinkCheckResult) -> LinkCheckResult? {
        if let reference, reference.id != result.id, reference.date < result.date { return reference }
        return previous(before: result)
    }

    // MARK: Fichier

    public static func load(from url: URL) -> LinkCheckHistory {
        guard let data = try? Data(contentsOf: url) else { return LinkCheckHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LinkCheckHistory.self, from: data)) ?? LinkCheckHistory()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Texte d'un bilan (bouton « Copier »).
public enum LinkCheckText {
    public static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_CA")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    public static func plain(_ r: LinkCheckResult, comparedTo before: LinkCheckResult? = nil) -> String {
        let nb = "\u{00A0}"
        var lines: [String] = []
        var title = "Bilan de raccordement — \(r.interfaceName)"
        if !r.location.isEmpty { title += " · \(r.location)" }
        if !r.siteName.isEmpty { title += " (\(r.siteName))" }
        lines.append(title)
        lines.append(dateLabel(r.date) + " · " + r.headline + " · " + r.countsLabel)
        lines.append("")
        for step in r.steps {
            lines.append("[\(step.status.label)] \(step.kind.title)\(nb): \(step.summary)")
            lines.append("    " + step.explanation)
        }
        if let before {
            let diffs = LinkCheckComparison.compare(before, r).filter(\.change.isDifference)
            lines.append("")
            lines.append("Comparaison avec le bilan du \(dateLabel(before.date))\(nb): " + LinkCheckComparison.summary(diffs))
            for d in diffs {
                lines.append("  \(d.step.title) · \(d.label)\(nb): \(d.before ?? "—") → \(d.after ?? "—") (\(d.change.label.lowercased()))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
