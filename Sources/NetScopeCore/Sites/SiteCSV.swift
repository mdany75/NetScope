import Foundation

// Note 28 : import et export des sites en CSV « site;plages;fortigate », sans aucun secret.
//
//   site;plages;fortigate
//   Siège;10.182.122.0/24 (Bureau, VLAN 1) | 192.168.50.0/24 (Caméras, VLAN 40);Siège
//   Clinique Exemple;192.168.1.0/24 (Postes);10.50.0.1
//
// - plages : séparées par « | » ; chacune « texte » ou « texte (libellé, VLAN n) » ; « décochée »
//   dans la parenthèse importe la plage sans la cocher ;
// - fortigate : site ou adresse d'une FortiGate des Réglages (plusieurs séparées par « | »).

public enum SiteCSV {
    public static let header = "site;plages;fortigate"

    public struct Row: Hashable, Sendable {
        public var line: Int
        public var name: String
        public var ranges: [ScanRangeConfig]
        /// Noms ou adresses de FortiGate tels qu'écrits.
        public var fortiGates: [String]
    }

    public struct LineError: Hashable, Sendable {
        public var line: Int
        public var message: String
        public var text: String { "Ligne \(line)\u{00A0}: \(message)" }
    }

    public struct Result: Hashable, Sendable {
        public var rows: [Row]
        public var errors: [LineError]
    }

    // MARK: Lecture

    public static func parse(_ text: String) -> Result {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var rows: [Row] = []
        var errors: [LineError] = []
        for (offset, raw) in lines.enumerated() {
            let number = offset + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var fields = FortiControllerCSV.split(trimmed, separator: ";")
                .map { FortiControllerCSV.unprotect($0.trimmingCharacters(in: .whitespaces)) }
            if rows.isEmpty, errors.isEmpty, ["site", "nom", "name"].contains(fields[0].lowercased()) { continue }
            while fields.count < 3 { fields.append("") }
            let name = fields[0]
            guard !name.isEmpty else {
                errors.append(LineError(line: number, message: "nom du site vide (site;plages;fortigate)."))
                continue
            }
            switch parseRanges(fields[1]) {
            case .failure(let message):
                errors.append(LineError(line: number, message: message))
            case .success(let ranges):
                let fortiGates = fields[2].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                rows.append(Row(line: number, name: name, ranges: ranges, fortiGates: fortiGates))
            }
        }
        return Result(rows: rows, errors: errors)
    }

    enum RangesResult { case success([ScanRangeConfig]), failure(String) }

    static func parseRanges(_ text: String) -> RangesResult {
        var result: [ScanRangeConfig] = []
        for item in text.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            var rangeText = item
            var label = ""
            var vlan: Int?
            var enabled = true
            if item.hasSuffix(")"), let open = item.range(of: " (", options: .backwards) {
                rangeText = String(item[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
                let inside = item[open.upperBound..<item.index(before: item.endIndex)]
                var labels: [String] = []
                for part in inside.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                    let lower = part.lowercased()
                    if lower.hasPrefix("vlan"), let number = Int(lower.dropFirst(4).trimmingCharacters(in: .whitespaces)) {
                        guard (1...4094).contains(number) else { return .failure("VLAN invalide «\u{00A0}\(part)\u{00A0}» (de 1 à 4094).") }
                        vlan = number
                    } else if ["décochée", "decochee", "off", "non scannée"].contains(lower) {
                        enabled = false
                    } else {
                        labels.append(part)
                    }
                }
                label = labels.joined(separator: ", ")
            }
            do {
                _ = try IPRange(parsing: rangeText)
            } catch {
                return .failure("plage illisible «\u{00A0}\(rangeText)\u{00A0}» (\((error as? LocalizedError)?.errorDescription ?? "format inconnu")).")
            }
            result.append(ScanRangeConfig(text: rangeText, label: label.isEmpty ? "Plage" : label, vlan: vlan, isEnabled: enabled))
        }
        return .success(result)
    }

    // MARK: Fusion

    public struct MergeResult: Hashable, Sendable {
        public var list: SiteList
        public var added: Int
        public var updated: Int
        /// FortiGate écrites dans le CSV mais absentes des Réglages.
        public var unknownFortiGates: [String]
    }

    /// Applique les lignes : un site du même nom (casse ignorée) reçoit les plages et les FortiGate
    /// de la ligne ; sinon il est créé. L'inventaire, les indices et les switchs ne changent pas.
    public static func merge(_ rows: [Row], into list: SiteList, controllers: [FortiGateController], now: Date = Date()) -> MergeResult {
        var result = list
        var added = 0, updated = 0
        var unknown: [String] = []
        for row in rows {
            var ids: [UUID] = []
            for wanted in row.fortiGates {
                let match = controllers.first { $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame }
                    ?? controllers.first { $0.addressLabel.caseInsensitiveCompare(wanted) == .orderedSame || $0.config.cleanHost.caseInsensitiveCompare(wanted) == .orderedSame }
                if let match {
                    if !ids.contains(match.id) { ids.append(match.id) }
                } else if !unknown.contains(wanted) {
                    unknown.append(wanted)
                }
            }
            if let index = result.sites.firstIndex(where: { $0.displayName.caseInsensitiveCompare(row.name) == .orderedSame }) {
                result.sites[index].ranges = row.ranges
                if !row.fortiGates.isEmpty { result.sites[index].fortiGateIDs = ids }
                SiteFortiGate.refreshHints(&result.sites[index], controllers: controllers)
                updated += 1
            } else {
                var site = Site(name: row.name, ranges: row.ranges, fortiGateIDs: ids, created: now)
                SiteFortiGate.refreshHints(&site, controllers: controllers)
                result.add(site)
                added += 1
            }
        }
        return MergeResult(list: result, added: added, updated: updated, unknownFortiGates: unknown)
    }

    // MARK: Écriture

    /// CSV des sites, en-tête compris. Ni jeton, ni communauté, ni inventaire.
    public static func export(_ sites: [Site], controllers: [FortiGateController]) -> String {
        var lines = [header]
        for site in sites {
            let ranges = site.ranges.map(rangeField).joined(separator: " | ")
            let fortiGates = site.fortiGateIDs.compactMap { id in controllers.first { $0.id == id }?.displayName }.joined(separator: " | ")
            lines.append([site.displayName, ranges, fortiGates].map(FortiControllerCSV.field).joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func rangeField(_ range: ScanRangeConfig) -> String {
        var details: [String] = []
        let label = range.label.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        if !label.isEmpty { details.append(label) }
        if let vlan = range.vlan { details.append("VLAN \(vlan)") }
        if !range.isEnabled { details.append("décochée") }
        return details.isEmpty ? range.text : "\(range.text) (\(details.joined(separator: ", ")))"
    }
}
