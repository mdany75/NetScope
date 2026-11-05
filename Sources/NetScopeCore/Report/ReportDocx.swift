import Foundation

// Note 78 : export DOCX des rapports, écrit à la main (Office Open XML, ECMA-376) : une archive ZIP
// (BackupZip, sans compression) qui contient le document WordprocessingML, ses styles, son pied de
// page et, s'il y en a un, le logo en PNG. Aucune dépendance : lisible par Word, Pages, LibreOffice,
// Google Docs et l'aperçu de macOS. Le contenu est le même ReportDocument que le PDF et le HTML.

public enum ReportDocx {
    /// Largeur utile d'une page lettre avec des marges de 0,75 po, en vingtièmes de point.
    static let contentWidth = 10_800
    static let pageWidth = 12_240
    static let pageHeight = 15_840
    static let margin = 720

    static let font = "Arial"
    static let monoFont = "Menlo"

    /// Archive DOCX complète. `logoPNG` : logo du technicien (PNG), facultatif. `date` : date des
    /// entrées du ZIP et des propriétés du document (fixe dans les tests).
    public static func make(_ document: ReportDocument, logoPNG: Data? = nil, date: Date = Date()) -> Data {
        let logo = logoPNG.flatMap { data in pngSize(data).map { (data: data, size: $0) } }
        var entries = [
            BackupZip.Entry(path: "[Content_Types].xml", data: Data(contentTypes(hasLogo: logo != nil).utf8)),
            BackupZip.Entry(path: "_rels/.rels", data: Data(packageRelationships.utf8)),
            BackupZip.Entry(path: "docProps/core.xml", data: Data(coreProperties(document, date: date).utf8)),
            BackupZip.Entry(path: "docProps/app.xml", data: Data(appProperties(document).utf8)),
            BackupZip.Entry(path: "word/_rels/document.xml.rels", data: Data(documentRelationships(hasLogo: logo != nil).utf8)),
            BackupZip.Entry(path: "word/document.xml", data: Data(documentXML(document, logo: logo?.size).utf8)),
            BackupZip.Entry(path: "word/styles.xml", data: Data(styles.utf8)),
            BackupZip.Entry(path: "word/settings.xml", data: Data(settings.utf8)),
            BackupZip.Entry(path: "word/footer1.xml", data: Data(footer(document).utf8)),
        ]
        if let logo { entries.append(BackupZip.Entry(path: "word/media/logo.png", data: logo.data)) }
        return BackupZip.archive(entries, date: date)
    }

    /// Parties obligatoires de l'archive (vérification et tests).
    public static let requiredParts = ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels",
                                       "word/styles.xml"]

    // MARK: Emballage

    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let wNS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let rNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func contentTypes(hasLogo: Bool) -> String {
        xmlHeader + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + (hasLogo ? "<Default Extension=\"png\" ContentType=\"image/png\"/>" : "")
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "<Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>"
            + "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"
            + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
            + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
            + "</Types>"
    }

    static let packageRelationships = xmlHeader
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        + "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
        + "</Relationships>"

    static func documentRelationships(hasLogo: Bool) -> String {
        xmlHeader + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/>"
            + "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>"
            + (hasLogo ? "<Relationship Id=\"rId4\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/logo.png\"/>" : "")
            + "</Relationships>"
    }

    static func coreProperties(_ document: ReportDocument, date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)
        return xmlHeader + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" "
            + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dc:title>\(escape(document.title))</dc:title>"
            + "<dc:subject>\(escape(document.site))</dc:subject>"
            + "<dc:creator>\(escape(document.technician.isEmpty ? document.generator : document.technician))</dc:creator>"
            + "<dc:language>fr-CA</dc:language>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>"
            + "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:modified>"
            + "</cp:coreProperties>"
    }

    static func appProperties(_ document: ReportDocument) -> String {
        xmlHeader + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">"
            + "<Application>\(escape(document.generator))</Application></Properties>"
    }

    static let settings = xmlHeader + "<w:settings xmlns:w=\"\(wNS)\"><w:defaultTabStop w:val=\"708\"/>"
        + "<w:characterSpacingControl w:val=\"doNotCompress\"/>"
        + "<w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat>"
        + "</w:settings>"

    static let styles: String = {
        func style(_ id: String, _ name: String, paragraph: String = "", run: String, basedOn: String? = "Normal") -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/>"
                + (basedOn.map { "<w:basedOn w:val=\"\($0)\"/>" } ?? "") + "<w:qFormat/>"
                + (paragraph.isEmpty ? "" : "<w:pPr>\(paragraph)</w:pPr>") + "<w:rPr>\(run)</w:rPr></w:style>"
        }
        return xmlHeader + "<w:styles xmlns:w=\"\(wNS)\">"
            + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"\(font)\" w:hAnsi=\"\(font)\" w:eastAsia=\"\(font)\" w:cs=\"\(font)\"/>"
            + "<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/><w:lang w:val=\"fr-CA\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/>"
            + "<w:rPr><w:rFonts w:ascii=\"\(font)\" w:hAnsi=\"\(font)\" w:cs=\"\(font)\"/><w:color w:val=\"374151\"/></w:rPr></w:style>"
            + style("Title", "Title", paragraph: "<w:spacing w:after=\"60\"/>", run: "<w:b/><w:color w:val=\"111827\"/><w:sz w:val=\"36\"/><w:szCs w:val=\"36\"/>")
            + style("Heading1", "heading 1", paragraph: "<w:keepNext/><w:spacing w:before=\"320\" w:after=\"120\"/><w:outlineLvl w:val=\"0\"/>",
                    run: "<w:b/><w:color w:val=\"111827\"/><w:sz w:val=\"26\"/><w:szCs w:val=\"26\"/>")
            + style("Caption", "caption", paragraph: "<w:keepNext/><w:spacing w:before=\"120\" w:after=\"60\"/>",
                    run: "<w:b/><w:caps/><w:color w:val=\"4B5563\"/><w:sz w:val=\"16\"/><w:szCs w:val=\"16\"/>")
            + style("Note", "Note", paragraph: "<w:spacing w:after=\"80\"/>", run: "<w:color w:val=\"4B5563\"/><w:sz w:val=\"18\"/><w:szCs w:val=\"18\"/>")
            + style("Code", "Code", paragraph: "<w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F9FAFB\"/>",
                    run: "<w:rFonts w:ascii=\"\(monoFont)\" w:hAnsi=\"\(monoFont)\" w:cs=\"\(monoFont)\"/><w:color w:val=\"111827\"/><w:sz w:val=\"16\"/><w:szCs w:val=\"16\"/>")
            + style("Cell", "Cellule", paragraph: "<w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>",
                    run: "<w:sz w:val=\"18\"/><w:szCs w:val=\"18\"/>")
            + style("Footer", "footer", paragraph: "<w:tabs><w:tab w:val=\"right\" w:pos=\"\(contentWidth)\"/></w:tabs><w:spacing w:after=\"0\"/>",
                    run: "<w:color w:val=\"4B5563\"/><w:sz w:val=\"16\"/><w:szCs w:val=\"16\"/>")
            + "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/>"
            + "<w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/>"
            + "<w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
            + "</w:styles>"
    }()

    static func footer(_ document: ReportDocument) -> String {
        xmlHeader + "<w:ftr xmlns:w=\"\(wNS)\"><w:p><w:pPr><w:pStyle w:val=\"Footer\"/>"
            + "<w:pBdr><w:top w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"E5E7EB\"/></w:pBdr></w:pPr>"
            + run(document.title + " · Confidentiel · Généré par " + document.generator)
            + "<w:r><w:tab/><w:t xml:space=\"preserve\">Page </w:t></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> PAGE </w:instrText></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
            + "<w:r><w:t xml:space=\"preserve\"> sur </w:t></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> NUMPAGES </w:instrText></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
            + "</w:p></w:ftr>"
    }

    // MARK: Document

    static func documentXML(_ document: ReportDocument, logo: (width: Int, height: Int)?) -> String {
        var body = ""
        // En-tête : logo, titre, client ; date, technicien et référence ; filet.
        if let logo { body += "<w:p><w:pPr><w:spacing w:after=\"120\"/></w:pPr>" + drawing(logo) + "</w:p>" }
        body += paragraph(style: "Title", runs: run(document.title))
        body += paragraph(style: "Note", runs: run("Client\u{00A0}: ") + run(document.clientLabel, bold: true, color: "111827"))
        body += "<w:p><w:pPr><w:pStyle w:val=\"Note\"/><w:pBdr><w:bottom w:val=\"single\" w:sz=\"12\" w:space=\"6\" w:color=\"111827\"/></w:pBdr>"
            + "<w:spacing w:after=\"240\"/></w:pPr>"
            + run(document.dateLabel + " · Technicien\u{00A0}: ") + run(document.technicianLabel, bold: true, color: "111827")
            + run(" · Réf. " + document.reference) + "</w:p>"
        for section in document.sections {
            body += paragraph(style: "Heading1", runs: run(section.heading))
            for block in section.blocks { body += xml(block) }
        }
        if document.signature { body += signature(document) }
        body += "<w:sectPr><w:footerReference w:type=\"default\" r:id=\"rId3\"/>"
            + "<w:pgSz w:w=\"\(pageWidth)\" w:h=\"\(pageHeight)\"/>"
            + "<w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\" w:header=\"360\" w:footer=\"360\" w:gutter=\"0\"/>"
            + "</w:sectPr>"
        return xmlHeader + "<w:document xmlns:w=\"\(wNS)\" xmlns:r=\"\(rNS)\" "
            + "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" "
            + "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            + "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            + "<w:body>" + body + "</w:body></w:document>"
    }

    static func xml(_ block: ReportBlock) -> String {
        switch block {
        case .paragraph(let text):
            return paragraph(style: nil, runs: run(text))
        case .note(let text):
            return paragraph(style: "Note", runs: run(text))
        case .kpis(let kpis):
            guard !kpis.isEmpty else { return "" }
            let width = contentWidth / kpis.count
            let cells = kpis.map { kpi in
                cell(width: width, borders: true, padding: true,
                     content: "<w:p><w:pPr><w:pStyle w:val=\"Cell\"/></w:pPr>"
                        + run(kpi.value, bold: true, color: color(kpi.tone), size: 30, mono: true) + "</w:p>"
                        + "<w:p><w:pPr><w:pStyle w:val=\"Cell\"/></w:pPr>" + run(kpi.label, color: "4B5563", size: 16) + "</w:p>")
            }.joined()
            return table(widths: Array(repeating: width, count: kpis.count), rows: "<w:tr>" + cells + "</w:tr>", borders: false)
                + spacer
        case .bars(let title, let bars):
            var out = paragraph(style: "Caption", runs: run(title))
            let widths = [3_000, 6_000, 1_800]
            var rows = ""
            for bar in bars {
                let blocks = max(1, Int((bar.fraction * 48).rounded()))
                rows += "<w:tr>" + cell(width: widths[0], content: cellParagraph(run(bar.label, size: 16)))
                    + cell(width: widths[1], content: cellParagraph(run(String(repeating: "█", count: blocks),
                                                                       color: bar.muted ? "6B7280" : "2563EB", size: 12)))
                    + cell(width: widths[2], content: cellParagraph(run("\(bar.count) · \(bar.share)", size: 16, mono: true), right: true))
                    + "</w:tr>"
            }
            out += table(widths: widths, rows: rows, borders: false) + spacer
            return out
        case .table(let table):
            return xml(table) + spacer
        case .code(let lines):
            return lines.map { paragraph(style: "Code", runs: run($0.isEmpty ? " " : $0)) }.joined() + spacer
        case .uptime(let chart):
            return uptime(chart) + spacer
        }
    }

    /// Petit espace après un tableau (Word colle sinon le paragraphe suivant au tableau).
    static let spacer = "<w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"120\" w:lineRule=\"exact\"/></w:pPr></w:p>"

    static func xml(_ table: ReportTable) -> String {
        let fractions = table.fractions
        var widths = fractions.map { max(400, Int(($0 * Double(contentWidth)).rounded())) }
        if let last = widths.indices.last { widths[last] += contentWidth - widths.reduce(0, +) }
        let size = table.dense ? 15 : 17
        var rows = "<w:tr><w:trPr><w:tblHeader/></w:trPr>"
        for (index, column) in table.columns.enumerated() {
            rows += cell(width: widths[index], fill: "F9FAFB", bottom: "D1D5DB",
                         content: cellParagraph(run(column.title.uppercased(), bold: true, color: "4B5563", size: 14), right: column.trailing))
        }
        rows += "</w:tr>"
        for row in table.rows {
            rows += "<w:tr><w:trPr><w:cantSplit/></w:trPr>"
            for (index, value) in row.cells.enumerated() where index < table.columns.count {
                let column = table.columns[index]
                let cellSize = column.size.map { Int(($0 * 2 * 0.86).rounded()) } ?? size
                var runs: String
                if let badge = value.badge {
                    runs = run(" \(value.text) ", bold: true, color: color(badge), size: 14, fill: badgeFill(badge))
                } else if let bar = value.bar {
                    let blocks = max(1, Int((min(1, bar) * 14).rounded()))
                    runs = run(String(repeating: "█", count: blocks), color: bar >= 0.7 ? "C2410C" : "2563EB", size: 10)
                        + run(" " + value.text, size: cellSize, mono: true)
                } else {
                    runs = run(value.text, bold: value.bold || row.isTotal, color: color(value.tone), size: cellSize, mono: column.mono)
                }
                rows += cell(width: widths[index], fill: row.isTotal ? "F9FAFB" : nil, bottom: "E5E7EB",
                             content: cellParagraph(runs, right: column.trailing))
            }
            rows += "</w:tr>"
        }
        return self.table(widths: widths, rows: rows, borders: false)
    }

    /// Graphe de disponibilité : une ligne par sonde, une case colorée par jour.
    static func uptime(_ chart: ReportUptimeChart) -> String {
        let label = 2_600, total = 1_200
        let days = max(1, chart.columns)
        let day = max(40, (contentWidth - label - total) / days)
        let widths = [label] + Array(repeating: day, count: days) + [total]
        var rows = ""
        for row in chart.rows {
            rows += "<w:tr><w:trPr><w:cantSplit/><w:trHeight w:val=\"300\" w:hRule=\"exact\"/></w:trPr>"
            rows += cell(width: label, content: cellParagraph(run(row.label, size: 16)))
            for index in 0..<days {
                let value = index < row.values.count ? row.values[index] : nil
                let fill = ReportUptimeRow.cellColor(value)
                rows += cell(width: day, fill: fill, sides: "FFFFFF",
                             content: "<w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/></w:pPr></w:p>")
            }
            rows += cell(width: total, content: cellParagraph(run(row.total, bold: true, color: color(row.tone), size: 16, mono: true), right: true))
            rows += "</w:tr>"
        }
        // Légende sous les cases : premier jour à gauche, dernier à droite.
        var axis = "<w:p><w:pPr><w:spacing w:before=\"40\" w:after=\"0\"/><w:ind w:left=\"\(label)\"/>"
            + "<w:tabs><w:tab w:val=\"center\" w:pos=\"\((days * day) / 2)\"/><w:tab w:val=\"right\" w:pos=\"\(days * day)\"/></w:tabs></w:pPr>"
        for (index, text) in chart.axis.enumerated() {
            if index > 0 { axis += "<w:r><w:tab/></w:r>" }
            axis += run(text, color: "4B5563", size: 14)
        }
        axis += "</w:p>"
        return paragraph(style: "Caption", runs: run(chart.title)) + table(widths: widths, rows: rows, borders: false) + axis
    }

    static func signature(_ document: ReportDocument) -> String {
        let width = contentWidth / 2
        func block(_ who: String, _ line: String) -> String {
            cell(width: width, padding: true,
                 content: "<w:p><w:pPr><w:pStyle w:val=\"Cell\"/><w:spacing w:before=\"480\"/>"
                    + "<w:pBdr><w:top w:val=\"single\" w:sz=\"8\" w:space=\"4\" w:color=\"111827\"/></w:pBdr></w:pPr>"
                    + run(who, bold: true, color: "111827") + "</w:p>"
                    + "<w:p><w:pPr><w:pStyle w:val=\"Cell\"/></w:pPr>" + run(line, color: "4B5563", size: 16) + "</w:p>")
        }
        return "<w:p><w:pPr><w:spacing w:before=\"360\" w:after=\"0\"/></w:pPr></w:p>"
            + table(widths: [width, width], rows: "<w:tr><w:trPr><w:cantSplit/></w:trPr>"
                    + block(document.technicianLabel + ", technicien", document.dateLabel)
                    + block("Signature du client", "Nom\u{00A0}: " + ReportText.missing) + "</w:tr>", borders: false)
    }

    // MARK: Briques

    static func paragraph(style: String?, runs: String) -> String {
        "<w:p>" + (style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? "") + runs + "</w:p>"
    }

    static func cellParagraph(_ runs: String, right: Bool = false) -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"Cell\"/>" + (right ? "<w:jc w:val=\"right\"/>" : "") + "</w:pPr>" + runs + "</w:p>"
    }

    /// Un morceau de texte. `size` en demi-points ; `fill` : fond (pastille).
    static func run(_ text: String, bold: Bool = false, color: String? = nil, size: Int? = nil, mono: Bool = false,
                    fill: String? = nil) -> String {
        var properties = ""
        if mono { properties += "<w:rFonts w:ascii=\"\(monoFont)\" w:hAnsi=\"\(monoFont)\" w:cs=\"\(monoFont)\"/>" }
        if bold { properties += "<w:b/><w:bCs/>" }
        if let color { properties += "<w:color w:val=\"\(color)\"/>" }
        if let size { properties += "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>" }
        if let fill { properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>" }
        let head = "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>")
        // Retours à la ligne gardés : un <w:br/> entre les lignes.
        let lines = text.components(separatedBy: "\n")
        return head + lines.map { "<w:t xml:space=\"preserve\">\(escape($0))</w:t>" }.joined(separator: "<w:br/>") + "</w:r>"
    }

    static func cell(width: Int, fill: String? = nil, bottom: String? = nil, sides: String? = nil, borders: Bool = false,
                     padding: Bool = false, content: String) -> String {
        var properties = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
        if borders {
            properties += "<w:tcBorders>" + ["top", "left", "bottom", "right"].map {
                "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"E5E7EB\"/>"
            }.joined() + "</w:tcBorders>"
        } else if let sides {
            properties += "<w:tcBorders><w:top w:val=\"single\" w:sz=\"18\" w:space=\"0\" w:color=\"\(sides)\"/>"
                + "<w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"\(sides)\"/>"
                + "<w:bottom w:val=\"single\" w:sz=\"18\" w:space=\"0\" w:color=\"\(sides)\"/>"
                + "<w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"\(sides)\"/></w:tcBorders>"
        } else if let bottom {
            properties += "<w:tcBorders><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"\(bottom)\"/></w:tcBorders>"
        }
        if let fill { properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>" }
        if padding {
            properties += "<w:tcMar><w:top w:w=\"100\" w:type=\"dxa\"/><w:bottom w:w=\"100\" w:type=\"dxa\"/></w:tcMar>"
        } else if sides == nil {
            properties += "<w:tcMar><w:top w:w=\"50\" w:type=\"dxa\"/><w:bottom w:w=\"50\" w:type=\"dxa\"/></w:tcMar>"
        } else {
            properties += "<w:tcMar><w:left w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"0\" w:type=\"dxa\"/></w:tcMar>"
        }
        properties += "<w:vAlign w:val=\"center\"/>"
        return "<w:tc><w:tcPr>\(properties)</w:tcPr>\(content)</w:tc>"
    }

    static func table(widths: [Int], rows: String, borders: Bool) -> String {
        let total = widths.reduce(0, +)
        let width = total >= contentWidth - 60 ? "<w:tblW w:w=\"5000\" w:type=\"pct\"/>" : "<w:tblW w:w=\"\(total)\" w:type=\"dxa\"/>"
        return "<w:tbl><w:tblPr>" + width + "<w:tblLayout w:type=\"fixed\"/>"
            + (borders ? "" : "<w:tblBorders><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:bottom w:val=\"nil\"/><w:right w:val=\"nil\"/><w:insideH w:val=\"nil\"/><w:insideV w:val=\"nil\"/></w:tblBorders>")
            + "<w:tblLook w:val=\"0000\" w:firstRow=\"0\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"1\" w:noVBand=\"1\"/>"
            + "</w:tblPr><w:tblGrid>" + widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>" + rows + "</w:tbl>"
    }

    /// Logo inséré dans le texte, ramené à 160 × 56 px au plus (proportions gardées).
    static func drawing(_ size: (width: Int, height: Int)) -> String {
        let scale = min(1, min(160 / Double(max(1, size.width)), 56 / Double(max(1, size.height))))
        let cx = Int(Double(size.width) * scale * 9_525), cy = Int(Double(size.height) * scale * 9_525)
        return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:docPr id=\"1\" name=\"Logo\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
            + "<pic:nvPicPr><pic:cNvPr id=\"0\" name=\"logo.png\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"rId4\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    // MARK: Outils

    /// Couleur d'un ton, sans « # » (comme l'export HTML).
    static func color(_ tone: ReportTone) -> String { String(ReportExport.toneColor(tone).dropFirst()) }
    static func badgeFill(_ tone: ReportTone) -> String { String(ReportExport.badgeBackground(tone).dropFirst()) }

    /// Texte sûr pour XML : caractères spéciaux échappés, caractères de contrôle interdits retirés.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t": result += " "
            default:
                // XML 1.0 : seuls tabulation, retour et saut de ligne sont permis sous 0x20 ; ni FFFE ni FFFF.
                if scalar.value < 0x20 && scalar != "\n" && scalar != "\r" { continue }
                if scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Largeur et hauteur d'une image PNG (en-tête IHDR), ou nil si ce n'est pas un PNG.
    public static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, bytes[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        func be32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        let width = be32(16), height = be32(20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
