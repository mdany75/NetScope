import Foundation

// Note 25 : import et export de la liste des FortiGate en CSV « site;adresse;port;vdom;plages ».
// Jamais de jeton, ni à l'export ni à l'import (une colonne de plus est ignorée et signalée).

public enum FortiControllerCSV {
    public static let header = "site;adresse;port;vdom;plages"

    /// Ligne lue.
    public struct Row: Hashable, Sendable {
        public var line: Int
        public var site: String
        public var host: String
        public var port: Int
        public var vdom: String
        public var ranges: [String]
    }

    /// Ligne refusée, avec la raison en français.
    public struct LineError: Hashable, Sendable {
        public var line: Int
        public var message: String

        public var text: String { "Ligne \(line)\u{00A0}: \(message)" }
    }

    public struct Result: Hashable, Sendable {
        public var rows: [Row]
        public var errors: [LineError]
        /// Remarques sans refus (colonnes de trop ignorées, etc.).
        public var notes: [String]
    }

    // MARK: Lecture

    public static func parse(_ text: String) -> Result {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        // Séparateur : le point-virgule s'il apparaît, sinon la virgule.
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        let separator: Character = content.contains { $0.contains(";") } ? ";" : ","
        var rows: [Row] = []
        var errors: [LineError] = []
        var notes: [String] = []
        var headerSeen = false
        var extraColumns = false
        for (offset, raw) in lines.enumerated() {
            let number = offset + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var fields = split(trimmed, separator: separator).map { unprotect($0.trimmingCharacters(in: .whitespaces)) }
            if !headerSeen, rows.isEmpty, errors.isEmpty, isHeader(fields) {
                headerSeen = true
                continue
            }
            // Virgule comme séparateur : les plages (dernière colonne) peuvent elles-mêmes contenir
            // des virgules ; tout ce qui suit la quatrième colonne leur revient.
            if separator == ",", fields.count > 5 {
                fields = Array(fields.prefix(4)) + [fields.dropFirst(4).joined(separator: " ")]
            } else if fields.count > 5 {
                extraColumns = true
                fields = Array(fields.prefix(5))
            }
            guard fields.count >= 2 else {
                errors.append(LineError(line: number, message: "il faut au moins le site et l’adresse, séparés par «\u{00A0}\(separator)\u{00A0}» (site;adresse;port;vdom;plages)."))
                continue
            }
            while fields.count < 5 { fields.append("") }
            let site = fields[0]
            let host = fields[1]
            guard !site.isEmpty else {
                errors.append(LineError(line: number, message: "nom du site vide."))
                continue
            }
            let config = FortiGateConfig(host: host)
            guard !host.isEmpty, config.isValid else {
                errors.append(LineError(line: number, message: "adresse invalide «\u{00A0}\(host)\u{00A0}» (adresse IP ou nom de la FortiGate, sans «\u{00A0}https://\u{00A0}»)."))
                continue
            }
            var port = config.effectivePort
            if !fields[2].isEmpty {
                guard let value = Int(fields[2]), (1...65_535).contains(value) else {
                    errors.append(LineError(line: number, message: "port invalide «\u{00A0}\(fields[2])\u{00A0}» (de 1 à 65\u{202F}535, 443 par défaut)."))
                    continue
                }
                port = value
            }
            let vdom = fields[3]
            guard vdom.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else {
                errors.append(LineError(line: number, message: "VDOM invalide «\u{00A0}\(vdom)\u{00A0}»."))
                continue
            }
            var ranges: [String] = []
            do {
                ranges = try FortiCoveredRange.parseList(fields[4]).map(\.text)
            } catch {
                errors.append(LineError(line: number, message: (error as? LocalizedError)?.errorDescription ?? "plage illisible."))
                continue
            }
            rows.append(Row(line: number, site: site, host: config.cleanHost, port: port, vdom: vdom, ranges: ranges))
        }
        if extraColumns { notes.append("Colonnes au-delà de «\u{00A0}plages\u{00A0}» ignorées (aucun jeton n’est jamais importé).") }
        return Result(rows: rows, errors: errors, notes: notes)
    }

    static func isHeader(_ fields: [String]) -> Bool {
        guard fields.count >= 2 else { return false }
        let a = fields[0].lowercased(), b = fields[1].lowercased()
        return ["site", "nom", "name"].contains(a) && ["adresse", "address", "hote", "hôte", "host", "ip"].contains(b)
    }

    /// Retire l'apostrophe ajoutée à l'export devant « = », « + », « - » ou « @ » (voir `field`).
    static func unprotect(_ value: String) -> String {
        guard value.hasPrefix("'"), let next = value.dropFirst().first, "=+-@".contains(next) else { return value }
        return String(value.dropFirst())
    }

    /// Découpe une ligne ; les guillemets protègent un séparateur (« "Siège; bureau" »).
    static func split(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        let iterator = Array(line)
        var index = 0
        while index < iterator.count {
            let c = iterator[index]
            if c == "\"" {
                if quoted, index + 1 < iterator.count, iterator[index + 1] == "\"" {
                    current.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if c == separator, !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            index += 1
        }
        fields.append(current)
        return fields
    }

    // MARK: Fusion

    /// Applique les lignes lues à la liste : une FortiGate déjà présente (même adresse et port) est
    /// mise à jour (site, VDOM, plages ; son jeton et son empreinte sont gardés), sinon ajoutée.
    public static func merge(_ rows: [Row], into controllers: [FortiGateController]) -> (controllers: [FortiGateController], added: Int, updated: Int) {
        var list = controllers
        var added = 0, updated = 0
        for row in rows {
            let incoming = FortiGateController(site: row.site, host: row.host, port: row.port, vdom: row.vdom, ranges: row.ranges)
            if let index = list.firstIndex(where: { $0.sameTarget(as: incoming) }) {
                list[index].site = row.site
                list[index].vdom = row.vdom
                list[index].ranges = row.ranges
                updated += 1
            } else {
                list.append(incoming)
                added += 1
            }
        }
        return (list, added, updated)
    }

    // MARK: Écriture

    /// CSV de la liste, en-tête compris, plages séparées par des espaces. Aucun jeton.
    public static func export(_ controllers: [FortiGateController]) -> String {
        var lines = [header]
        for c in controllers {
            let fields = [c.site, c.config.cleanHost, String(c.config.effectivePort), c.vdom, c.ranges.joined(separator: " ")]
            lines.append(fields.map(field).joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Champ protégé : guillemets autour d'un séparateur ou d'un guillemet, et pas de formule de
    /// tableur (« = », « + », « - », « @ » en tête).
    static func field(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if let first = value.first, "=+-@".contains(first) { value = "'" + value }
        if value.contains(";") || value.contains("\"") || value.contains(",") {
            value = "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
