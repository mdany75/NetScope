import AppKit
import NetScopeCore
import PDFKit
import SwiftUI

/// Rendu PDF natif : chaque page de la pagination est une `RapportPageView` dessinée par
/// `ImageRenderer` dans un contexte PDF CoreGraphics, en format lettre (612 × 792 pt). Le texte
/// reste vectoriel (sélectionnable et cherchable dans Aperçu).
@MainActor
enum RapportPDF {
    static func render(_ document: ReportDocument, pages: [ReportPage], logo: NSImage?,
                       metrics: ReportPageMetrics = ReportPageMetrics()) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: metrics.pageWidth, height: metrics.pageHeight)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: document.title,
            kCGPDFContextAuthor: document.technician.isEmpty ? "NetScope" : document.technician,
            kCGPDFContextCreator: document.generator,
            kCGPDFContextSubject: "Client\u{00A0}: \(document.clientLabel) · Réf. \(document.reference)",
        ]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return nil }
        for page in pages {
            let view = RapportPageView(document: document, page: page, totalPages: pages.count, logo: logo,
                                       unit: CGFloat(ReportPageMetrics.scale), metrics: metrics)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: metrics.pageWidth, height: metrics.pageHeight)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    /// Logo en PNG encodé pour l'export HTML (« data:image/png;base64,… »).
    static func dataURL(_ image: NSImage?) -> String? {
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// Logo en PNG (export DOCX, note 78), ou nil.
    static func pngData(_ image: NSImage?) -> Data? {
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Outil de développement (note 78) : écrit le DOCX du rapport de démonstration, section
/// « Disponibilité » comprise, à côté des captures, puis le relit (archive, XML bien formé, titres).
@MainActor
enum RapportDocxCheck {
    static func write(into directory: URL, state: AppState) -> Bool {
        let model = RapportModel.shared
        let saved = model.config
        model.config.sections.insert(.disponibilite)
        // Note 61 : section « Carte du réseau » (image intégrée au DOCX).
        model.config.sections.insert(.carte)
        let document = model.document(state: state)
        model.config = saved
        let data = ReportDocx.make(document, logoPNG: RapportPDF.pngData(model.logo))
        let url = directory.appendingPathComponent("rapport-demo.docx")
        do {
            try data.write(to: url, options: .atomic)
            var problems: [String] = []
            let entries = try BackupZip.entries(of: data)
            let paths = Set(entries.map(\.path))
            for part in ReportDocx.requiredParts where !paths.contains(part) { problems.append("partie absente\u{00A0}: \(part)") }
            let hasMap = document.sections.contains { $0.blocks.contains { if case .image = $0 { return true } else { return false } } }
            if hasMap, !paths.contains("word/media/image-1.png") { problems.append("image de la carte absente") }
            for entry in entries where entry.path.hasSuffix(".xml") || entry.path.hasSuffix(".rels") {
                if !XMLParser(data: entry.data).parse() { problems.append("XML mal formé\u{00A0}: \(entry.path)") }
            }
            let xml = entries.first { $0.path == "word/document.xml" }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
            for section in document.sections {
                let heading = ReportDocx.escape(section.heading)
                if !xml.contains(heading) { problems.append("titre absent\u{00A0}: \(section.heading)") }
            }
            for problem in problems { print("Erreur\u{00A0}: rapport DOCX\u{00A0}: \(problem)") }
            guard problems.isEmpty else { return false }
            print("Rapport DOCX\u{00A0}: \(url.path) (\(document.sections.count) sections, vérifié)")
            return true
        } catch {
            print("Erreur\u{00A0}: \(url.path)\u{00A0}: \(error.localizedDescription)")
            return false
        }
    }
}

/// Outil de développement : écrit le PDF du rapport de démonstration à côté des captures
/// (`--snapshot <dossier> --demo`), pour vérifier l'export sans fenêtre ni réseau.
@MainActor
enum RapportPDFCheck {
    static func write(into directory: URL, state: AppState) -> Bool {
        let model = RapportModel.shared
        let document = model.document(state: state)
        let pages = model.pages(for: document)
        guard let data = RapportPDF.render(document, pages: pages, logo: model.logo) else {
            print("Erreur\u{00A0}: rendu PDF du rapport impossible")
            return false
        }
        let url = directory.appendingPathComponent("rapport-demo.pdf")
        do {
            try data.write(to: url, options: .atomic)
            let problems = verify(data, document: document, pageCount: pages.count)
            for problem in problems { print("Erreur\u{00A0}: rapport PDF\u{00A0}: \(problem)") }
            guard problems.isEmpty else { return false }
            print("Rapport PDF\u{00A0}: \(url.path) (\(pages.count) pages, vérifié)")
            return true
        } catch {
            print("Erreur\u{00A0}: \(url.path)\u{00A0}: \(error.localizedDescription)")
            return false
        }
    }

    /// Relit le PDF avec PDFKit : nombre de pages, format lettre, « Page N de M » sur chaque page,
    /// titre de chaque section et signature (si demandée). Renvoie la liste des écarts.
    static func verify(_ data: Data, document: ReportDocument, pageCount: Int) -> [String] {
        guard let pdf = PDFDocument(data: data) else { return ["PDF illisible"] }
        var problems: [String] = []
        if pdf.pageCount != pageCount { problems.append("\(pdf.pageCount) pages au lieu de \(pageCount)") }
        var all = ""
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            if abs(box.width - 612) > 0.5 || abs(box.height - 792) > 0.5 {
                problems.append("page \(index + 1)\u{00A0}: \(Int(box.width)) × \(Int(box.height)) au lieu de 612 × 792")
            }
            let text = page.string ?? ""
            let footer = "Page \(index + 1) de \(pdf.pageCount)"
            if !text.contains(footer) { problems.append("page \(index + 1)\u{00A0}: «\u{00A0}\(footer)\u{00A0}» absent") }
            all += text + "\n"
        }
        let flat = all.replacingOccurrences(of: "\n", with: " ")
        for section in document.sections where !flat.contains(section.heading) {
            problems.append("section «\u{00A0}\(section.heading)\u{00A0}» absente du texte")
        }
        if document.signature, !document.technician.isEmpty, !flat.contains(document.technician) {
            problems.append("signature du technicien absente")
        }
        return problems
    }
}
