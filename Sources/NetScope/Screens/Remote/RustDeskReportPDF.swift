import AppKit
import NetScopeCore

/// Note 87 : rapport mensuel des demandes RustDesk en PDF (lettre US, texte seulement, couleurs
/// fixes d'impression, indépendantes du mode sombre).
enum RustDeskReportPDF {
    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let margin: CGFloat = 48

    static func render(_ report: RustDeskMonthlyReport) -> Data {
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let ink = NSColor(calibratedWhite: 0.07, alpha: 1), gray = NSColor(calibratedWhite: 0.35, alpha: 1)
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: ink]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: ink]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ink]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: gray]
        let day = DateFormatter()
        day.locale = Locale(identifier: "fr_CA")
        day.dateFormat = "d MMM HH:mm"

        var y: CGFloat = 0
        func newPage() {
            if y != 0 { context.endPDFPage() }
            context.beginPDFPage(nil)
            y = page.height - margin
        }
        func draw(_ text: String, _ attributes: [NSAttributedString.Key: Any], x: CGFloat = margin, height: CGFloat = 15) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: text, attributes: attributes).draw(at: CGPoint(x: x, y: y - height))
            NSGraphicsContext.restoreGraphicsState()
        }
        func row(_ cells: [(String, CGFloat)], _ attributes: [NSAttributedString.Key: Any]) {
            if y < margin + 20 { newPage() }
            for (text, x) in cells { draw(text, attributes, x: margin + x) }
            y -= 15
        }

        newPage()
        draw("Rapport RustDesk · \(report.title)", title, height: 22)
        y -= 26
        draw("\(report.total) demande\(report.total > 1 ? "s" : "") de connexion lues par NetScope sur le serveur (lecture seule).", small)
        y -= 26
        draw("Par poste", heading)
        y -= 18
        row([("Poste", 0), ("ID", 210), ("Demandes", 310), ("Techniciens", 380), ("Dernière", 450)], small)
        for station in report.stations {
            row([(station.name.isEmpty ? "Hors carnet" : String(station.name.prefix(36)), 0), (RustDeskID.grouped(station.targetID, separator: " "), 210),
                 (String(station.count), 310), (String(station.technicians), 380), (day.string(from: station.last), 450)], body)
        }
        y -= 14
        if y < margin + 60 { newPage() }
        draw("Par technicien", heading)
        y -= 18
        row([("Technicien", 0), ("IP", 210), ("Demandes", 310), ("Postes", 380), ("Dernière", 450)], small)
        for tech in report.technicians {
            row([(String(tech.label.prefix(36)), 0), (tech.ip, 210), (String(tech.count), 310), (String(tech.stations), 380),
                 (day.string(from: tech.last), 450)], body)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
