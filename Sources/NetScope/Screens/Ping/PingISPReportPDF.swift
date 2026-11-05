import AppKit
import NetScopeCore
import PDFKit
import SwiftUI

/// Rapport « pour le fournisseur Internet » du ping continu (note 78) en PDF lettre (612 × 792 pt) :
/// une page de résumé (perte, latence, gigue, disponibilité, constats, pannes), puis le détail
/// heure par heure de chaque cible. Couleurs fixes d'impression (papier blanc), comme le rapport
/// de l'écran Rapports : le PDF est le même quelle que soit l'apparence du Mac.
@MainActor
enum PingISPReportPDF {
    static let pageSize = CGSize(width: 612, height: 792)

    static func render(_ report: PingISPReport) -> Data? {
        let pages = report.pages()
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: "Rapport de connectivité pour le fournisseur Internet",
            kCGPDFContextCreator: "NetScope",
        ]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return nil }
        for (index, page) in pages.enumerated() {
            let view = PingISPReportPage(report: report, page: page, number: index + 1, total: pages.count)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    /// Relit le PDF : nombre de pages, format lettre, « Page N de M », nom de chaque cible.
    static func verify(_ data: Data, report: PingISPReport) -> [String] {
        guard let pdf = PDFDocument(data: data) else { return ["PDF illisible"] }
        var problems: [String] = []
        let expected = report.pages().count
        if pdf.pageCount != expected { problems.append("\(pdf.pageCount) pages au lieu de \(expected)") }
        var all = ""
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            if abs(bounds.width - 612) > 0.5 || abs(bounds.height - 792) > 0.5 {
                problems.append("page \(index + 1)\u{00A0}: \(Int(bounds.width)) × \(Int(bounds.height))")
            }
            let text = page.string ?? ""
            if !text.contains("Page \(index + 1) de \(pdf.pageCount)") { problems.append("page \(index + 1)\u{00A0}: pied absent") }
            all += text + "\n"
        }
        for target in report.targets where !all.contains(target.address) {
            problems.append("cible \(target.address) absente du texte")
        }
        if report.targets.contains(where: { !$0.outages.isEmpty }), !all.uppercased().contains("PANNES") {
            problems.append("liste des pannes absente")
        }
        return problems
    }
}

/// Une page du rapport.
struct PingISPReportPage: View {
    let report: PingISPReport
    let page: PingISPReport.Page
    let number: Int
    let total: Int

    // Couleurs d'impression (papier blanc) : fixes, comme RapportPageView.
    static let ink = Color(hex: 0x111827)
    static let gray = Color(hex: 0x4B5563)
    static let line = Color(hex: 0xE5E7EB)
    static let soft = Color(hex: 0xF9FAFB)
    static let accent = Color(hex: 0x2563EB)
    static let red = Color(hex: 0xB91C1C)
    static let redSoft = Color(hex: 0xFEE2E2)
    static let amber = Color(hex: 0x92400E)
    static let amberSoft = Color(hex: 0xFEF3C7)
    static let green = Color(hex: 0x166534)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Self.line).frame(height: 1).padding(.vertical, 10)
            Group {
                switch page {
                case .summary(let range):
                    summary(range)
                case .hours(let index, let rows):
                    hours(report.targets[index], rows: rows)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 26)
        .frame(width: PingISPReportPDF.pageSize.width, height: PingISPReportPDF.pageSize.height, alignment: .top)
        .background(Color.white)
        .foregroundStyle(Self.ink)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Rapport de connectivité").font(.system(size: 17, weight: .bold))
                Text("Pour le fournisseur Internet · mesures du ping continu de NetScope")
                    .font(.system(size: 9.5)).foregroundStyle(Self.gray)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Période").font(.system(size: 8, weight: .semibold)).foregroundStyle(Self.gray)
                Text("\(PingISPReport.stamp(report.periodStart)) au \(PingISPReport.stamp(report.periodEnd))")
                    .font(.system(size: 9, design: .monospaced))
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Produit par NetScope le \(PingISPReport.stamp(report.generatedAt))")
            Spacer()
            Text("Page \(number) de \(total)")
        }
        .font(.system(size: 8))
        .foregroundStyle(Self.gray)
    }

    // MARK: Résumé

    @ViewBuilder private func summary(_ range: Range<Int>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if range.lowerBound == 0 {
                Text("Chaque cible a été interrogée en continu (ICMP). Une panne commence au premier de trois paquets perdus de suite et finit à la première réponse. La gigue est l’écart moyen entre deux réponses consécutives.")
                    .font(.system(size: 9)).foregroundStyle(Self.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if report.targets.isEmpty {
                Text("Aucune mesure enregistrée.").font(.system(size: 10)).foregroundStyle(Self.gray)
            }
            ForEach(Array(range), id: \.self) { index in
                targetSummary(report.targets[index])
            }
        }
    }

    private func targetSummary(_ target: PingISPReport.Target) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(target.name).font(.system(size: 13, weight: .semibold))
                Text(target.address).font(.system(size: 10, design: .monospaced)).foregroundStyle(Self.gray)
                if !target.role.isEmpty { Text("· \(target.role)").font(.system(size: 9.5)).foregroundStyle(Self.gray) }
                Spacer()
                Text("seuil \(PingThreshold.label(target.thresholdMs))").font(.system(size: 8.5)).foregroundStyle(Self.gray)
            }
            HStack(spacing: 6) {
                figure("Perte", PingFormat.percent(target.lossPercent), tone: target.lossPercent >= PingISPReport.lossNotice ? .bad : .normal)
                figure("Latence moy.", PingFormat.ms(target.average), tone: .normal)
                figure("Gigue", PingFormat.ms(target.jitter), tone: (target.jitter ?? 0) >= PingISPReport.jitterNotice ? .warn : .normal)
                figure("Disponibilité", PingFormat.decimal(target.availability, digits: 2) + "\u{00A0}%", tone: target.availability < 99.9 ? .warn : .good)
                figure("Pannes", "\(target.outages.count)", tone: target.outages.isEmpty ? .good : .bad)
                figure("Envoyés / reçus", "\(target.sent) / \(target.received)", tone: .normal)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(target.findings, id: \.self) { finding in
                    HStack(alignment: .top, spacing: 5) {
                        Text("•")
                        Text(finding).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 9.5))
                }
            }
            let listed = PingISPReport.listedOutages(target)
            if !listed.shown.isEmpty {
                VStack(spacing: 0) {
                    tableRow(["Pannes · début", "Fin", "Durée", "Paquets perdus"], header: true, widths: [170, 170, 80, 90], leading: 2)
                    ForEach(Array(listed.shown.enumerated()), id: \.offset) { _, outage in
                        tableRow([PingISPReport.stamp(outage.start),
                                  outage.end.map { PingISPReport.stamp($0) } ?? "en cours",
                                  PingFormat.duration(outage.duration(until: target.measuredUntil)),
                                  "\(outage.lostPackets)"], widths: [170, 170, 80, 90], mono: true, leading: 2)
                    }
                    if listed.hidden > 0 {
                        Text("et \(listed.hidden) autre\(listed.hidden > 1 ? "s" : "") panne\(listed.hidden > 1 ? "s" : "") plus ancienne\(listed.hidden > 1 ? "s" : "")")
                            .font(.system(size: 8.5)).foregroundStyle(Self.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Self.line))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Self.line))
    }

    enum FigureTone { case normal, good, warn, bad }

    private func figure(_ label: String, _ value: String, tone: FigureTone) -> some View {
        let color: Color
        let fill: Color
        switch tone {
        case .normal: color = Self.ink; fill = Self.soft
        case .good: color = Self.green; fill = Self.soft
        case .warn: color = Self.amber; fill = Self.amberSoft
        case .bad: color = Self.red; fill = Self.redSoft
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 6.5, weight: .semibold)).foregroundStyle(Self.gray).lineLimit(1)
            Text(value).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(fill))
    }

    // MARK: Détail par heure

    private static let hourWidths: [CGFloat] = [118, 62, 62, 62, 62, 62, 60]

    private func hours(_ target: PingISPReport.Target, rows: Range<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("Détail par heure · ").font(.system(size: 12, weight: .semibold))
                + Text("\(target.name) (\(target.address))").font(.system(size: 12)))
            Text("Perte, latence moyenne et maximale, gigue et réponses au-dessus du seuil de \(PingThreshold.label(target.thresholdMs)), heure par heure.")
                .font(.system(size: 9)).foregroundStyle(Self.gray)
            VStack(spacing: 0) {
                tableRow(["Heure", "Envoyés", "Perte", "Moy.", "Max", "Gigue", "Lents"], header: true, widths: Self.hourWidths)
                ForEach(Array(rows), id: \.self) { index in
                    let row = target.hours[index]
                    let tone: Color? = row.lossPercent >= 5 ? Self.redSoft : row.lossPercent >= PingISPReport.lossNotice ? Self.amberSoft : nil
                    tableRow([PingISPReport.hourLabel(row.hourStart), "\(row.sent)", PingFormat.percent(row.lossPercent),
                              PingFormat.ms(row.average), PingFormat.ms(row.max), PingFormat.ms(row.jitter), "\(row.slow)"],
                             widths: Self.hourWidths, mono: true, fill: tone)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Self.line))
        }
    }

    /// `leading` : nombre de colonnes alignées à gauche (dates) ; les chiffres sont à droite.
    private func tableRow(_ cells: [String], header: Bool = false, widths: [CGFloat], mono: Bool = false, fill: Color? = nil,
                          leading: Int = 1) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(header ? cell.uppercased() : cell)
                    .font(header ? .system(size: 7, weight: .semibold) : .system(size: 8.5, design: mono ? .monospaced : .default))
                    .foregroundStyle(header ? Self.gray : Self.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: index < widths.count ? widths[index] : 60, alignment: index < leading ? .leading : .trailing)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: header ? 18 : 17)
        .background(header ? Self.soft : (fill ?? Color.clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Self.line).frame(height: 0.5) }
    }
}

/// Outil de développement : écrit le PDF de démonstration à côté des captures et le relit.
@MainActor
enum PingISPReportCheck {
    static func write(into directory: URL) -> Bool {
        let report = PingSessionDemo.report(now: Date())
        guard let data = PingISPReportPDF.render(report) else {
            print("Erreur\u{00A0}: rendu PDF du rapport pour le fournisseur Internet impossible")
            return false
        }
        let url = directory.appendingPathComponent("ping-fournisseur-demo.pdf")
        do {
            try data.write(to: url, options: .atomic)
            let problems = PingISPReportPDF.verify(data, report: report)
            for problem in problems { print("Erreur\u{00A0}: rapport pour le fournisseur Internet\u{00A0}: \(problem)") }
            guard problems.isEmpty else { return false }
            print("Rapport pour le fournisseur Internet\u{00A0}: \(url.path) (\(report.pages().count) pages, vérifié)")
            return true
        } catch {
            print("Erreur\u{00A0}: \(url.path)\u{00A0}: \(error.localizedDescription)")
            return false
        }
    }
}
