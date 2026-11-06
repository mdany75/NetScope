import Foundation

// Note 40 (0.31.0) : texte des configurations (nettoyage de la sortie SSH, secrets masqués,
// lignes qui changent à chaque lecture) et comparaison avant/après, ligne à ligne (Myers).

/// Texte d'une configuration.
public enum ConfigText {
    /// Lignes sans retour chariot ni espaces de fin.
    public static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                var s = Substring(line)
                while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
                return String(s)
            }
    }

    /// Secrets masqués (affichage et comparaison) : « ENC … » de FortiOS (rechiffré à chaque
    /// sauvegarde), « secret 9 … », « password 7 … » de Cisco, clés et mots de passe d'Aruba et
    /// de MikroTik. Le fichier gardé, lui, reste complet (il doit pouvoir être restauré).
    public static func masked(_ line: String) -> String {
        let patterns: [(String, String)] = [
            (#"(?i)\bENC\s+\S+"#, "ENC •••"),
            (#"(?i)\b(secret|password|key-string|community)\s+(?!ENC\b)(\d\s+)?\S+"#, "$1 $2•••"),
            (#"(?i)\b(password|passphrase|secret|psk|wpa2-pre-shared-key|wpa-pre-shared-key|authentication-password|encryption-password)=("[^"]*"|\S+)"#, "$1=•••"),
        ]
        var result = line
        for (pattern, template) in patterns {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.replacingOccurrences(of: "  •••", with: " •••")
    }

    /// Ligne qui change d'une lecture à l'autre sans que la configuration change (date, compteur).
    public static func isVolatile(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        let prefixes = ["! last configuration change", "! nvram config last updated", "! no configuration change since",
                        "ntp clock-period", "building configuration", "current configuration :", "#conf_file_ver=",
                        "; created on release", "! time:"]
        if prefixes.contains(where: { t.hasPrefix($0) }) { return true }
        // MikroTik : « # nov/05/2026 14:02:11 by RouterOS 7.15 », « # 2026-11-05 14:02:11 by RouterOS 7.16 ».
        if t.hasPrefix("#"), t.contains(" by routeros") { return true }
        return false
    }

    /// Lignes comparées : secrets masqués, lignes volatiles retirées, blancs de fin ignorés.
    public static func comparable(_ text: String) -> [String] {
        var out = lines(text).filter { !isVolatile($0) }.map(masked)
        while out.last?.isEmpty == true { out.removeLast() }
        while out.first?.isEmpty == true { out.removeFirst() }
        return out
    }

    /// Même configuration (au sens de `comparable`).
    public static func sameConfiguration(_ a: String, _ b: String) -> Bool { comparable(a) == comparable(b) }

    /// Sortie SSH nettoyée : séquences ANSI, retours arrière, « --More-- » retirés ; pour Cisco, le
    /// texte de « Building configuration… » (ou « version ») jusqu'à « end », sans les invites.
    public static func cleanOutput(_ raw: String, kind: ConfigDeviceKind) -> String {
        var text = raw.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[^\n]\x{08}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{08}", with: "")
        text = text.replacingOccurrences(of: #" ?--\s?More\s?--\s*"#, with: "", options: .regularExpression)
        var all = lines(text)
        switch kind {
        case .cisco:
            let start = all.firstIndex { $0.hasPrefix("Building configuration") || $0.hasPrefix("Current configuration") }
                ?? all.firstIndex { $0.hasPrefix("version ") }
            if let start {
                all = Array(all[start...])
                if let end = all.lastIndex(of: "end") { all = Array(all[...end]) }
            }
        case .fortiswitch, .fortigate:
            // Invite finale (« S248EPTF18001234 # ») laissée par certains firmwares.
            while let last = all.last, last.isEmpty || last.range(of: #"^\S+ (#|\$) ?$"#, options: .regularExpression) != nil { all.removeLast() }
        case .aruba, .mikrotik:
            break
        }
        while all.first?.isEmpty == true { all.removeFirst() }
        while all.last?.isEmpty == true { all.removeLast() }
        return all.joined(separator: "\n") + (all.isEmpty ? "" : "\n")
    }

    /// Message d'erreur de l'interface en ligne de commande, en tête de sortie.
    public static func cliError(in text: String) -> String? {
        let markers = ["% invalid input", "% incomplete command", "% unknown command", "% ambiguous command",
                       "invalid input:", "unknown action", "bad command name", "command fail", "expected end of command",
                       "permission denied", "% authorization failed", "invalid command"]
        for line in lines(text).prefix(40) {
            let lower = line.lowercased()
            if markers.contains(where: { lower.contains($0) }) {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

/// Ligne d'une comparaison.
public struct ConfigDiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case same, added, removed }
    public var kind: Kind
    public var text: String
    /// Numéros de ligne dans l'ancienne et la nouvelle version (1 = première).
    public var oldNumber: Int?
    public var newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

/// Bloc de différences avec ses lignes de contexte.
public struct ConfigDiffHunk: Hashable, Sendable {
    public var lines: [ConfigDiffLine]
    /// Lignes inchangées sautées avant ce bloc.
    public var skippedBefore: Int

    /// « @@ -12,7 +12,8 @@ ».
    public var header: String {
        let old = lines.compactMap(\.oldNumber), new = lines.compactMap(\.newNumber)
        return "@@ -\(old.first ?? 0),\(old.count) +\(new.first ?? 0),\(new.count) @@"
    }
}

/// Comparaison de deux versions, ligne à ligne.
public struct ConfigDiff: Sendable {
    public var lines: [ConfigDiffLine]
    public var added: Int
    public var removed: Int
    /// Trop de différences pour la recherche fine : le milieu est montré retiré puis ajouté.
    public var approximate: Bool

    public var isIdentical: Bool { added == 0 && removed == 0 }

    /// Compare deux textes. `masked` : secrets masqués et lignes volatiles retirées (comme pour
    /// décider si la configuration a changé) ; sinon, le texte tel quel.
    public static func make(old: String, new: String, masked: Bool = true, maxEdits: Int = 3000) -> ConfigDiff {
        let a = masked ? ConfigText.comparable(old) : ConfigText.lines(old)
        let b = masked ? ConfigText.comparable(new) : ConfigText.lines(new)
        return make(oldLines: a, newLines: b, maxEdits: maxEdits)
    }

    public static func make(oldLines a: [String], newLines b: [String], maxEdits: Int = 3000) -> ConfigDiff {
        // Début et fin communs retirés d'abord : la plupart des changements sont courts.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)]), midB = Array(b[prefix..<(b.count - suffix)])

        var ops: [Op]
        var approximate = false
        if let found = myers(midA, midB, maxEdits: maxEdits) {
            ops = found
        } else {
            ops = midA.indices.map { .delete($0) } + midB.indices.map { .insert($0) }
            approximate = true
        }

        var out: [ConfigDiffLine] = []
        out.reserveCapacity(a.count + midB.count)
        for i in 0..<prefix { out.append(ConfigDiffLine(kind: .same, text: a[i], oldNumber: i + 1, newNumber: i + 1)) }
        var added = 0, removed = 0
        for op in ops {
            switch op {
            case .same(let i, let j):
                out.append(ConfigDiffLine(kind: .same, text: midA[i], oldNumber: prefix + i + 1, newNumber: prefix + j + 1))
            case .delete(let i):
                removed += 1
                out.append(ConfigDiffLine(kind: .removed, text: midA[i], oldNumber: prefix + i + 1, newNumber: nil))
            case .insert(let j):
                added += 1
                out.append(ConfigDiffLine(kind: .added, text: midB[j], oldNumber: nil, newNumber: prefix + j + 1))
            }
        }
        for k in 0..<suffix {
            let i = a.count - suffix + k, j = b.count - suffix + k
            out.append(ConfigDiffLine(kind: .same, text: a[i], oldNumber: i + 1, newNumber: j + 1))
        }
        return ConfigDiff(lines: out, added: added, removed: removed, approximate: approximate)
    }

    /// Blocs de différences, avec `context` lignes inchangées autour de chacun.
    public func hunks(context: Int = 3) -> [ConfigDiffHunk] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let low = max(0, index - context), high = min(lines.count - 1, index + context)
            if let last = ranges.last, low <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, high)
            } else {
                ranges.append(low...high)
            }
        }
        var previousEnd = -1
        return ranges.map { range in
            defer { previousEnd = range.upperBound }
            return ConfigDiffHunk(lines: Array(lines[range]), skippedBefore: range.lowerBound - previousEnd - 1)
        }
    }

    enum Op: Equatable { case same(Int, Int), delete(Int), insert(Int) }

    /// Plus courte suite de modifications (Myers, 1986) ; nil au-delà de `maxEdits`.
    static func myers(_ a: [String], _ b: [String], maxEdits: Int) -> [Op]? {
        let n = a.count, m = b.count
        if n == 0 { return b.indices.map { .insert($0) } }
        if m == 0 { return a.indices.map { .delete($0) } }
        let maxD = min(n + m, maxEdits)
        let offset = n + m + 1
        var v = [Int](repeating: 0, count: 2 * (n + m) + 3)
        // Pour chaque d : valeurs de v sur les diagonales -d…d au début de l'étape (celles de d - 1).
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...maxD {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { found = true; break outer }
            }
        }
        guard found else { return nil }
        var ops: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let row = trace[d]
            func value(_ k: Int) -> Int { row[k + d] }
            let k = x - y
            let prevK: Int, prevX: Int
            if d == 0 {
                prevK = 0
                prevX = 0
            } else {
                prevK = (k == -d || (k != d && value(k - 1) < value(k + 1))) ? k + 1 : k - 1
                prevX = value(prevK)
            }
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                ops.append(.same(x - 1, y - 1))
                x -= 1
                y -= 1
            }
            if d > 0 {
                if x == prevX { ops.append(.insert(y - 1)) } else { ops.append(.delete(x - 1)) }
                x = prevX
                y = prevY
            }
        }
        return ops.reversed()
    }
}
