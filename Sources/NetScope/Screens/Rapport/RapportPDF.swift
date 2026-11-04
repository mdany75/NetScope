import AppKit
import NetScopeCore
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
            print("Rapport PDF\u{00A0}: \(url.path) (\(pages.count) pages)")
            return true
        } catch {
            print("Erreur\u{00A0}: \(url.path)\u{00A0}: \(error.localizedDescription)")
            return false
        }
    }
}
