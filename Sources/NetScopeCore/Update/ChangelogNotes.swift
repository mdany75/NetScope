import Foundation

// Réglages › Mises à jour : historique complet des versions et résumé de leurs notes, lus dans le
// CHANGELOG.md livré avec l'application (copié par build.sh), sans réseau.

/// Une rubrique des notes d'une version (« Ajouté », « Modifié », « Corrigé », « Limites connues »).
public struct ChangelogSection: Hashable, Sendable {
    public var title: String
    /// Une ligne par point : le titre en gras du point s'il y en a un, sinon sa première phrase.
    public var items: [String]

    public init(title: String, items: [String]) {
        self.title = title
        self.items = items
    }
}

/// Notes d'une version publiée.
public struct ChangelogVersion: Hashable, Sendable, Identifiable {
    public var id: String { version }
    public var version: String
    /// Date de publication (« 2026-11-05 »), nil si absente ou illisible.
    public var date: Date?
    /// Paragraphe d'introduction de la version (vide s'il n'y en a pas).
    public var summary: String
    public var sections: [ChangelogSection]

    public init(version: String, date: Date?, summary: String, sections: [ChangelogSection]) {
        self.version = version
        self.date = date
        self.summary = summary
        self.sections = sections
    }

    /// Nombre total de points.
    public var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }

    /// Résumé à afficher en une ou deux lignes : l'introduction, sinon les premiers points.
    public var shortSummary: String {
        if !summary.isEmpty { return summary }
        let firsts = sections.flatMap(\.items).prefix(3)
        return firsts.isEmpty ? "Pas de notes pour cette version." : firsts.joined(separator: " · ")
    }
}

public enum ChangelogNotes {
    /// Lit un CHANGELOG au format du projet : « ## X.Y.Z — AAAA-MM-JJ », un paragraphe, puis des
    /// rubriques « ### Titre » de points « - … » (sur plusieurs lignes). La plus récente d'abord.
    public static func parse(_ text: String) -> [ChangelogVersion] {
        var versions: [ChangelogVersion] = []
        var current: ChangelogVersion?
        var summaryLines: [String] = []
        var sectionTitle: String?
        var items: [String] = []
        var item: String?
        var inSummary = false

        func closeItem() {
            if let text = item?.trimmingCharacters(in: .whitespaces), !text.isEmpty { items.append(headline(text)) }
            item = nil
        }
        func closeSection() {
            closeItem()
            if let title = sectionTitle, !items.isEmpty { current?.sections.append(ChangelogSection(title: title, items: items)) }
            sectionTitle = nil
            items = []
        }
        func closeVersion() {
            closeSection()
            if var version = current {
                version.summary = clean(summaryLines.joined(separator: " "))
                versions.append(version)
            }
            current = nil
            summaryLines = []
            inSummary = false
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                closeVersion()
                guard let parsed = header(String(line.dropFirst(3))) else { continue }
                current = ChangelogVersion(version: parsed.version, date: parsed.date, summary: "", sections: [])
                inSummary = true
            } else if current == nil {
                continue
            } else if line.hasPrefix("### ") {
                closeSection()
                inSummary = false
                sectionTitle = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                inSummary = false
                closeItem()
                if sectionTitle == nil { sectionTitle = "Notes" }
                item = String(line.dropFirst(2))
            } else if line.isEmpty {
                closeItem()
                if inSummary, !summaryLines.isEmpty { inSummary = false }
            } else if item != nil {
                item! += " " + line
            } else if inSummary {
                summaryLines.append(line)
            }
        }
        closeVersion()
        return versions
    }

    /// CHANGELOG livré avec l'application, sinon celui du dépôt (développement, captures).
    public static func bundled() -> [ChangelogVersion] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        for url in [Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"), repository].compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let versions = parse(text)
                if !versions.isEmpty { return versions }
            }
        }
        return []
    }

    /// « 0.23.0 — 2026-11-05 » → version et date.
    static func header(_ text: String) -> (version: String, date: Date?)? {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "—–")).map { $0.trimmingCharacters(in: .whitespaces) }
        var version = parts.first ?? ""
        if version.hasPrefix("v") { version.removeFirst() }
        guard UpdVersion(version) != nil else { return nil }
        var date: Date?
        if parts.count > 1 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            date = formatter.date(from: String(parts[1].prefix(10)))
        }
        return (version, date)
    }

    /// Titre d'un point : sa partie en gras (« **Journal de NetScope** (…) : … » → « Journal de
    /// NetScope »), sinon sa première phrase, raccourcie.
    static func headline(_ text: String) -> String {
        if text.hasPrefix("**"), let end = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
            let bold = clean(String(text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound]))
            if !bold.isEmpty { return bold.trimmingCharacters(in: CharacterSet(charactersIn: " :\u{00A0}")) }
        }
        let plain = clean(text)
        var sentence = plain
        if let stop = plain.range(of: ". ") { sentence = String(plain[..<stop.lowerBound]) }
        if let colon = sentence.range(of: "\u{00A0}:") ?? sentence.range(of: " :"), sentence.distance(from: sentence.startIndex, to: colon.lowerBound) >= 12 {
            sentence = String(sentence[..<colon.lowerBound])
        }
        if sentence.count > 160 { sentence = String(sentence.prefix(157)).trimmingCharacters(in: .whitespaces) + "…" }
        return sentence.trimmingCharacters(in: CharacterSet(charactersIn: " .;"))
    }

    /// Retire le Markdown simple (gras, code) et les espaces en trop.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: { $0 == " " }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Historique affiché

/// État d'une version dans l'historique de ce Mac.
public enum UpdTimelineState: Hashable, Sendable {
    /// Version qui tourne maintenant.
    case running
    /// Installée sur ce Mac auparavant (date retenue).
    case previous
    /// Publiée avant la version actuelle, jamais vue sur ce Mac (ou avant que l'historique existe).
    case notInstalled
    /// Publiée après la version actuelle (connue par le CHANGELOG d'une version plus récente).
    case newer
}

/// Une ligne de l'historique : une version publiée, avec ses notes et sa date d'installation.
public struct UpdTimelineRow: Hashable, Sendable, Identifiable {
    public var id: String { version }
    public var version: String
    public var notes: ChangelogVersion?
    public var installedAt: Date?
    public var channel: UpdChannel
    public var state: UpdTimelineState

    public init(version: String, notes: ChangelogVersion?, installedAt: Date?, channel: UpdChannel, state: UpdTimelineState) {
        self.version = version
        self.notes = notes
        self.installedAt = installedAt
        self.channel = channel
        self.state = state
    }
}

public enum UpdTimeline {
    /// Toutes les versions connues (CHANGELOG et historique d'installation), la plus récente
    /// d'abord, chacune avec sa date d'installation sur ce Mac quand elle est connue.
    public static func rows(changelog: [ChangelogVersion], history: [UpdHistoryEntry], running: String) -> [UpdTimelineRow] {
        let runningVersion = UpdVersion(running)
        // Première installation retenue de chaque version (l'historique est du plus récent au plus ancien).
        var installed: [String: UpdHistoryEntry] = [:]
        for entry in history.reversed() where installed[normalized(entry.version)] == nil {
            installed[normalized(entry.version)] = entry
        }
        var byVersion: [String: ChangelogVersion] = [:]
        for notes in changelog where byVersion[normalized(notes.version)] == nil { byVersion[normalized(notes.version)] = notes }

        var keys = Set(byVersion.keys).union(installed.keys)
        keys.insert(normalized(running))
        let sorted = keys.sorted { lhs, rhs in
            switch (UpdVersion(lhs), UpdVersion(rhs)) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs > rhs
            }
        }
        return sorted.map { key in
            let entry = installed[key]
            let version = byVersion[key]?.version ?? entry?.version ?? key
            let state: UpdTimelineState
            if key == normalized(running) {
                state = .running
            } else if let runningVersion, let other = UpdVersion(key), other > runningVersion {
                state = .newer
            } else {
                state = entry == nil ? .notInstalled : .previous
            }
            let channel = entry?.channel ?? ((UpdVersion(key)?.isPrerelease ?? false) ? .beta : .stable)
            return UpdTimelineRow(version: version, notes: byVersion[key], installedAt: entry?.date, channel: channel, state: state)
        }
    }

    static func normalized(_ version: String) -> String {
        UpdVersion(version)?.description ?? version.trimmingCharacters(in: .whitespaces)
    }
}
