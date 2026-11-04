import Foundation

// Note 47 : suivi dans le temps (derniers diagnostics de chaque client, gardés dans le dossier du
// site) et texte à copier. Fonctions pures ; l'application lit et écrit le fichier.

/// Résumé d'un diagnostic gardé dans l'historique.
public struct WifiDiagnosisRecord: Codable, Hashable, Sendable {
    public var date: Date
    public var overall: WifiVerdict
    /// Cause la plus probable (nil : rien à signaler).
    public var primary: WifiCause?
    public var problems: [WifiCause]
    public var rssi: Int?

    public init(date: Date, overall: WifiVerdict, primary: WifiCause?, problems: [WifiCause], rssi: Int? = nil) {
        self.date = date
        self.overall = overall
        self.primary = primary
        self.problems = problems
        self.rssi = rssi
    }

    public init(_ result: WifiDiagnosisResult, rssi: Int? = nil) {
        self.init(date: result.date, overall: result.overall, primary: result.primary?.cause,
                  problems: result.problems.map(\.cause), rssi: rssi)
    }
}

/// Historique d'un site : par sujet (« client|MAC »), les derniers résumés ; les diagnostics
/// ajoutés au rapport du site. Taille bornée (résumés par sujet, nombre de sujets).
public struct WifiDiagnosisHistory: Codable, Hashable, Sendable {
    public static let fileName = "diagnostics-wifi.json"
    /// Résumés gardés par sujet.
    public static let keepPerSubject = 40
    /// Sujets gardés (les moins récemment diagnostiqués tombent).
    public static let keepSubjects = 300

    public var records: [String: [WifiDiagnosisRecord]]
    /// Diagnostics retenus pour la section « Diagnostic Wi-Fi » du rapport du site.
    public var reported: [WifiDiagnosisResult]

    private enum CodingKeys: String, CodingKey { case records, reported }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Élément illisible, sauté.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public init(records: [String: [WifiDiagnosisRecord]] = [:], reported: [WifiDiagnosisResult] = []) {
        self.records = records
        self.reported = reported
    }

    /// Lecture élément par élément : une entrée illisible (cause d'une version future…) est
    /// ignorée sans faire tomber le reste. L'ancien champ « latest » n'est plus lu.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var records: [String: [WifiDiagnosisRecord]] = [:]
        if let byKey = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .records) {
            for key in byKey.allKeys {
                guard var list = try? byKey.nestedUnkeyedContainer(forKey: key) else { continue }
                let kept: [WifiDiagnosisRecord] = Self.lossy(&list)
                if !kept.isEmpty { records[key.stringValue] = kept }
            }
        }
        self.records = records
        if var list = try? c.nestedUnkeyedContainer(forKey: .reported) {
            reported = Self.lossy(&list)
        } else {
            reported = []
        }
    }

    private static func lossy<T: Decodable>(_ list: inout UnkeyedDecodingContainer) -> [T] {
        var result: [T] = []
        while !list.isAtEnd {
            if let value = try? list.decode(T.self) {
                result.append(value)
            } else if (try? list.decode(Skip.self)) == nil {
                break
            }
        }
        return result
    }

    /// Ajoute un diagnostic ; au-delà de `keepSubjects`, les sujets les moins récemment
    /// diagnostiqués tombent (ceux retenus pour le rapport restent).
    public mutating func add(_ result: WifiDiagnosisResult, rssi: Int? = nil) {
        let key = result.subject.key
        var list = records[key] ?? []
        list.append(WifiDiagnosisRecord(result, rssi: rssi))
        list.sort { $0.date < $1.date }
        if list.count > Self.keepPerSubject { list.removeFirst(list.count - Self.keepPerSubject) }
        records[key] = list
        guard records.count > Self.keepSubjects else { return }
        let kept = Set(reported.map(\.subject.key))
        var candidates: [(key: String, date: Date)] = []
        for (subject, list) in records where !kept.contains(subject) {
            candidates.append((subject, list.last?.date ?? Date.distantPast))
        }
        candidates.sort { a, b in a.date != b.date ? a.date < b.date : a.key < b.key }
        let excess = records.count - Self.keepSubjects
        for item in candidates.prefix(excess) { records[item.key] = nil }
    }

    /// Retient un diagnostic pour le rapport (un seul par sujet : le plus récent remplace l'ancien).
    public mutating func report(_ result: WifiDiagnosisResult) {
        reported.removeAll { $0.subject.key == result.subject.key }
        reported.append(result)
        reported.sort { $0.date > $1.date }
    }

    public mutating func unreport(_ key: String) { reported.removeAll { $0.subject.key == key } }
    public func isReported(_ result: WifiDiagnosisResult) -> Bool { reported.contains { $0.id == result.id } }

    /// Diagnostic précédent d'un sujet, avant `date`.
    public func previous(_ key: String, before date: Date) -> WifiDiagnosisRecord? {
        records[key]?.last { $0.date < date }
    }

    /// Le problème revient-il à certaines heures ? Phrase en clair, ou nil s'il n'y a pas assez de
    /// diagnostics (au moins 3, dont 2 avec un problème) ou pas d'heure qui se dégage.
    public func recurrence(_ key: String, calendar: Calendar = .current) -> String? {
        WifiDiagnosisHistory.recurrence(records[key] ?? [], calendar: calendar)
    }

    public static func recurrence(_ list: [WifiDiagnosisRecord], calendar: Calendar = .current) -> String? {
        let nb = "\u{00A0}"
        guard list.count >= 3 else { return nil }
        let bad = list.filter { $0.overall == .problem }
        guard bad.count >= 2 else {
            return bad.isEmpty ? "Aucun problème sur les \(list.count) derniers diagnostics." : nil
        }
        // Tranches de deux heures : la plus fréquente parmi les diagnostics en problème.
        var slots: [Int: Int] = [:]
        for r in bad { slots[calendar.component(.hour, from: r.date) / 2, default: 0] += 1 }
        let causes = Dictionary(grouping: bad.compactMap(\.primary), by: { $0 }).mapValues(\.count)
        let topCause = causes.max { ($0.value, -$0.key.rank) < ($1.value, -$1.key.rank) }?.key
        var text = "\(bad.count) diagnostic\(bad.count > 1 ? "s" : "") sur \(list.count) en problème"
        if let topCause { text += ", surtout\(nb): " + topCause.title.prefix(1).lowercased() + topCause.title.dropFirst() }
        if let (slot, count) = slots.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }), count >= 2, Double(count) / Double(bad.count) >= 0.6 {
            text += "\(nb); le problème revient entre \(slot * 2)\(nb)h et \(slot * 2 + 2)\(nb)h (\(count) fois sur \(bad.count))"
        }
        let okAfter = list.last.map { $0.overall != .problem } ?? false
        if okAfter { text += "\(nb); le dernier diagnostic est revenu à la normale" }
        return text + "."
    }

    // MARK: Fichier

    public static func load(from url: URL) -> WifiDiagnosisHistory {
        guard let data = try? Data(contentsOf: url) else { return WifiDiagnosisHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WifiDiagnosisHistory.self, from: data)) ?? WifiDiagnosisHistory()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Texte du diagnostic (bouton « Copier »).
public enum WifiDiagnosisText {
    public static func plain(_ r: WifiDiagnosisResult, dateFormatter: DateFormatter? = nil) -> String {
        let f = dateFormatter ?? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_CA")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()
        var lines: [String] = []
        lines.append("Diagnostic Wi-Fi — \(r.subject.kindLabel.lowercased()) \(r.subject.name)" + (r.site.isEmpty ? "" : " (\(r.site))"))
        lines.append(f.string(from: r.date) + (r.context.isEmpty ? "" : " · " + r.context))
        lines.append("")
        lines.append("Verdict\u{00A0}: \(r.overall.label). \(r.headline)")
        if !r.actions.isEmpty {
            lines.append("")
            lines.append("Actions suggérées\u{00A0}:")
            for (i, a) in r.actions.enumerated() { lines.append("\(i + 1). \(a)") }
        }
        lines.append("")
        lines.append("Causes vérifiées\u{00A0}:")
        for c in r.causes where c.verdict != .notMeasured {
            lines.append("- [\(c.verdict.label)] \(c.title)\u{00A0}: \(c.summary)")
            for e in c.evidence { lines.append("    · \(e)") }
        }
        let unchecked = r.unchecked
        if !unchecked.isEmpty {
            lines.append("")
            lines.append("Non vérifié\u{00A0}: " + unchecked.map(\.title).joined(separator: ", ") + ".")
        }
        for n in r.notes { lines.append("Remarque\u{00A0}: \(n)") }
        lines.append("")
        lines.append("Lecture seule\u{00A0}: NetScope n’a rien modifié sur la FortiGate.")
        return lines.joined(separator: "\n")
    }
}
