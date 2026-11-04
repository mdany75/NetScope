import Foundation

// Exports d'un rapport en CSV, JSON et HTML. Le PDF est dessiné par l'application (vues
// SwiftUI rendues page par page) à partir de la même pagination.

public enum ReportExport {
    // MARK: CSV

    /// Tableaux du rapport, l'un après l'autre (titre de section, en-têtes, lignes, ligne vide).
    /// Séparateur « ; » comme Excel en français ; chaque champ passe par `InvCSV.quote`, qui
    /// neutralise les formules (un nom d'hôte « =HYPERLINK(…) » ne s'exécute pas à l'ouverture).
    public static func csv(_ document: ReportDocument, separator: Character = ";") -> String {
        var lines: [[String]] = [
            [document.title],
            ["Client", document.clientLabel],
            ["Technicien", document.technicianLabel],
            ["Date", document.date],
            ["Référence", document.reference],
        ]
        for section in document.sections {
            for table in section.tables {
                lines.append([])
                lines.append([section.heading])
                lines.append(table.columns.map(\.title))
                for row in table.rows { lines.append(row.cells.map(\.text)) }
            }
        }
        return lines.map { $0.map { InvCSV.quote($0, separator) }.joined(separator: String(separator)) }
            .joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-8 avec BOM, pour qu'Excel lise les accents.
    public static func csvData(_ document: ReportDocument) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(csv(document).utf8)
    }

    /// Nombre de lignes de données dans l'export CSV (hors titres et en-têtes).
    public static func csvRowCount(_ document: ReportDocument) -> Int {
        document.sections.flatMap(\.tables).map(\.rows.count).reduce(0, +)
    }

    // MARK: JSON

    struct JSONReport: Codable {
        struct Meta: Codable {
            var titre: String
            var modele: String
            var client: String
            var site: String
            var technicien: String
            var date: String
            var reference: String
            var generateur: String
        }
        struct Table: Codable {
            var colonnes: [String]
            var lignes: [[String: String]]
        }
        struct Indicator: Codable {
            var valeur: String
            var libelle: String
        }
        struct Section: Codable {
            var id: String
            var titre: String
            var textes: [String]
            var indicateurs: [Indicator]?
            var repartition: [Indicator]?
            var tableaux: [Table]
            var brut: [String]?
        }
        struct Problem: Codable {
            var titre: String
            var gravite: String
            var recommandation: String
        }
        var rapport: Meta
        var sections: [Section]
        var problemes: [Problem]
    }

    /// Données structurées : chaque ligne de tableau est un objet dont les clés sont les en-têtes.
    public static func json(_ document: ReportDocument) throws -> Data {
        let sections = document.sections.map { section -> JSONReport.Section in
            var texts: [String] = []
            var kpis: [JSONReport.Indicator]?
            var bars: [JSONReport.Indicator]?
            var tables: [JSONReport.Table] = []
            var raw: [String]?
            for block in section.blocks {
                switch block {
                case .paragraph(let text), .note(let text): texts.append(text)
                case .kpis(let list): kpis = list.map { .init(valeur: $0.value, libelle: $0.label) }
                case .bars(_, let list): bars = list.map { .init(valeur: "\($0.count)", libelle: $0.label) }
                case .table(let table):
                    let names = table.columns.map(\.title)
                    tables.append(.init(colonnes: names, lignes: table.rows.map { row in
                        var object: [String: String] = [:]
                        for (index, cell) in row.cells.enumerated() where index < names.count { object[names[index]] = cell.text }
                        return object
                    }))
                case .code(let lines): raw = lines
                }
            }
            return .init(id: section.id, titre: section.heading, textes: texts, indicateurs: kpis,
                         repartition: bars, tableaux: tables, brut: raw)
        }
        let report = JSONReport(
            rapport: .init(titre: document.title, modele: document.template.rawValue, client: document.client, site: document.site,
                           technicien: document.technician, date: document.date, reference: document.reference,
                           generateur: document.generator),
            sections: sections,
            problemes: document.problems.map { .init(titre: $0.title, gravite: $0.severity.label, recommandation: $0.recommendation) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    // MARK: HTML

    /// Échappe le texte pour HTML (contenu et valeurs d'attribut).
    public static func escapeHTML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(char)
            }
        }
        return result
    }

    static func toneColor(_ tone: ReportTone) -> String {
        switch tone {
        case .normal: return "#111827"
        case .muted: return "#374151"
        case .neutral: return "#4B5563"
        case .success: return "#15803D"
        case .caution: return "#92400E"
        case .warning: return "#C2410C"
        case .critical: return "#B91C1C"
        }
    }

    static func badgeBackground(_ tone: ReportTone) -> String {
        switch tone {
        case .success: return "#DCFCE7"
        case .caution: return "#FEF3C7"
        case .warning: return "#FFEDD5"
        case .critical: return "#FEE2E2"
        default: return "#F3F4F6"
        }
    }

    /// Page HTML autonome (styles intégrés, aucune ressource externe), imprimable en format lettre.
    /// `logoDataURL` : image du logo déjà encodée (« data:image/png;base64,… »), facultative.
    public static func html(_ document: ReportDocument, logoDataURL: String? = nil) -> String {
        let e = escapeHTML
        var out = """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(e(document.title))</title>
        <style>
        body{margin:0;background:#F3F4F6;font:13px -apple-system,system-ui,sans-serif;color:#111827}
        article{max-width:760px;margin:24px auto;background:#fff;padding:40px 44px;box-shadow:0 1px 3px rgba(15,23,42,.12)}
        header{display:flex;gap:16px;align-items:flex-start;padding-bottom:14px;border-bottom:2px solid #111827}
        header .logo{width:120px;height:44px;display:flex;align-items:center;justify-content:center}
        header .logo img{max-width:120px;max-height:44px}
        header h1{margin:0;font-size:20px}
        header .meta{margin-left:auto;text-align:right;font-size:12px;color:#4B5563;line-height:1.6}
        h2{font-size:14px;margin:22px 0 8px}
        p{line-height:1.5;color:#374151;margin:0 0 10px}
        .note{font-size:12px;color:#4B5563;margin:6px 0}
        table{width:100%;border-collapse:collapse;font-size:12px}
        th{background:#F9FAFB;text-align:left;font-size:11px;text-transform:uppercase;color:#4B5563;padding:5px 6px;border-bottom:1px solid #E5E7EB}
        td{padding:5px 6px;border-bottom:1px solid #E5E7EB;vertical-align:top}
        td.r,th.r{text-align:right}
        td.m{font-family:ui-monospace,Menlo,monospace}
        tr.total td{background:#F9FAFB;font-weight:700}
        .badge{display:inline-block;font-size:10px;font-weight:700;padding:1px 6px;border-radius:4px;white-space:nowrap}
        .kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:6px}
        .kpi{border:1px solid #E5E7EB;border-radius:6px;padding:8px}
        .kpi b{display:block;font:700 18px ui-monospace,Menlo,monospace}
        .kpi span{font-size:11px;color:#4B5563}
        .bar{display:flex;align-items:center;gap:8px;font-size:11px;height:16px}
        .bar span:first-child{width:160px}
        .bar .track{flex:1;height:9px;background:#F3F4F6;border-radius:2px}
        .bar .fill{height:9px;border-radius:2px;background:#2563EB}
        pre{background:#F9FAFB;border:1px solid #E5E7EB;border-radius:4px;padding:8px 10px;font-size:11px;overflow-x:auto}
        .sign{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:32px;font-size:12px}
        .sign div div:first-child{height:30px;border-bottom:1px solid #111827}
        footer{display:flex;justify-content:space-between;border-top:1px solid #E5E7EB;margin-top:24px;padding-top:8px;font-size:11px;color:#4B5563}
        @media print{body{background:#fff}article{box-shadow:none;margin:0;max-width:none}}
        </style>
        </head>
        <body>
        <article>
        <header>
        """
        if let logoDataURL, logoDataURL.hasPrefix("data:image/") {
            out += "<div class=\"logo\"><img src=\"\(e(logoDataURL))\" alt=\"Logo\"></div>\n"
        }
        out += """
        <div><h1>\(e(document.title))</h1><div class="note">Client\u{00A0}: \(e(document.clientLabel))</div></div>
        <div class="meta"><div>\(e(document.dateLabel))</div><div>Technicien\u{00A0}: <b>\(e(document.technicianLabel))</b></div><div>Réf. \(e(document.reference))</div></div>
        </header>

        """
        for section in document.sections {
            out += "<section id=\"\(e(section.id.replacingOccurrences(of: " ", with: "-")))\">\n<h2>\(e(section.heading))</h2>\n"
            for block in section.blocks { out += html(block) }
            out += "</section>\n"
        }
        if document.signature {
            out += """
            <div class="sign"><div><div></div><div><b>\(e(document.technicianLabel))</b>, technicien</div><div>\(e(document.dateLabel))</div></div>
            <div><div></div><div><b>Signature du client</b></div><div>Nom\u{00A0}: \(e(ReportText.missing))</div></div></div>

            """
        }
        out += """
        <footer><span>\(e(document.title)) · Confidentiel</span><span>Généré par \(e(document.generator))</span></footer>
        </article>
        </body>
        </html>

        """
        return out
    }

    static func html(_ block: ReportBlock) -> String {
        let e = escapeHTML
        switch block {
        case .paragraph(let text):
            return "<p>\(e(text))</p>\n"
        case .note(let text):
            return "<div class=\"note\">\(e(text))</div>\n"
        case .kpis(let kpis):
            let items = kpis.map { "<div class=\"kpi\"><b style=\"color:\(toneColor($0.tone))\">\(e($0.value))</b><span>\(e($0.label))</span></div>" }
            return "<div class=\"kpis\">" + items.joined() + "</div>\n"
        case .bars(let title, let bars):
            var out = "<div class=\"note\"><b>\(e(title))</b></div>\n"
            for bar in bars {
                let width = max(2, Int((bar.fraction * 100).rounded()))
                out += "<div class=\"bar\"><span>\(e(bar.label))</span><div class=\"track\"><div class=\"fill\" style=\"width:\(width)%\(bar.muted ? ";background:#6B7280" : "")\"></div></div><span>\(bar.count) · \(e(bar.share))</span></div>\n"
            }
            return out
        case .table(let table):
            var out = "<table>\n<thead><tr>"
            for column in table.columns { out += "<th\(column.trailing ? " class=\"r\"" : "")>\(e(column.title))</th>" }
            out += "</tr></thead>\n<tbody>\n"
            for row in table.rows {
                out += row.isTotal ? "<tr class=\"total\">" : "<tr>"
                for (index, cell) in row.cells.enumerated() {
                    let column = index < table.columns.count ? table.columns[index] : ReportColumn("")
                    var classes: [String] = []
                    if column.trailing { classes.append("r") }
                    if column.mono { classes.append("m") }
                    let attr = classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\""
                    var content = e(cell.text)
                    if let badge = cell.badge {
                        content = "<span class=\"badge\" style=\"background:\(badgeBackground(badge));color:\(toneColor(badge))\">\(content)</span>"
                    } else if cell.bold {
                        content = "<b>\(content)</b>"
                    }
                    let style = cell.badge == nil && cell.tone != .normal ? " style=\"color:\(toneColor(cell.tone))\"" : ""
                    out += "<td\(attr)\(style)>\(content)</td>"
                }
                out += "</tr>\n"
            }
            return out + "</tbody>\n</table>\n"
        case .code(let lines):
            return "<pre>" + lines.map(e).joined(separator: "\n") + "</pre>\n"
        }
    }
}
