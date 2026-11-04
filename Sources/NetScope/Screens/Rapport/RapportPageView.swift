import AppKit
import NetScopeCore
import SwiftUI

/// Une page lettre du rapport (croquis Rapport.dc.html, « article ») : en-tête avec logo, titre,
/// client, date et technicien ; sections de la page ; signature sur la dernière page ; pied
/// « Page N de M ». La même vue sert à l'aperçu (`unit` 1 : 680 × 880 px comme le croquis) et au
/// PDF (`unit` 0,9 : 612 × 792 pt). Chaque élément est dessiné à la hauteur que la pagination du
/// moteur (`ReportPageMetrics`) lui a comptée.
struct RapportPageView: View {
    /// Bleu fixe du rapport remis au client : jamais la couleur d'accent du Mac du technicien
    /// (Graphite, Rouge…), pour que le même rapport ait les mêmes couleurs partout.
    static let reportAccent = Color(hex: 0x2563EB)

    let document: ReportDocument
    let page: ReportPage
    let totalPages: Int
    var logo: NSImage?
    /// Points par pixel du croquis.
    var unit: CGFloat = 1
    var metrics = ReportPageMetrics()

    /// Taille d'une valeur du croquis (en pixels).
    private func px(_ value: Double) -> CGFloat { CGFloat(value) * unit }
    /// Taille d'une valeur de `ReportPageMetrics` (en points PDF).
    private func pt(_ value: Double) -> CGFloat { CGFloat(value / ReportPageMetrics.scale) * unit }

    private func font(_ size: Double, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        .system(size: px(size), weight: weight, design: mono ? .monospaced : .default)
    }

    static let ink = Color(hex: 0x111827)
    static let gray = Color(hex: 0x4B5563)
    static let body = Color(hex: 0x374151)
    static let line = Color(hex: 0xE5E7EB)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: pt(metrics.headerHeight), alignment: .top)
            content
                .frame(height: pt(metrics.contentHeight), alignment: .top)
                .clipped()
            footer
                .frame(height: pt(metrics.footerHeight), alignment: .bottom)
        }
        .padding(.top, pt(metrics.marginTop))
        .padding(.bottom, pt(metrics.marginBottom))
        .padding(.horizontal, pt(metrics.marginX))
        .frame(width: pt(metrics.pageWidth), height: pt(metrics.pageHeight), alignment: .top)
        .background(Color.white)
        .foregroundStyle(Self.ink)
        .environment(\.colorScheme, .light)
    }

    // MARK: En-tête et pied

    private var header: some View {
        HStack(alignment: .top, spacing: px(16)) {
            RapportLogoBox(logo: logo, width: px(120), height: px(44), fontSize: px(10), radius: px(4))
            VStack(alignment: .leading, spacing: px(3)) {
                // Une seule ligne : l'en-tête a une hauteur fixe (deux lignes chevauchaient « Client »).
                Text(document.title)
                    .font(font(18, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text("Client\u{00A0}: \(document.clientLabel)")
                    .font(font(12))
                    .foregroundStyle(Self.gray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: px(1.6)) {
                Text(document.dateLabel)
                (Text("Technicien\u{00A0}: ") + Text(document.technicianLabel).fontWeight(.semibold).foregroundColor(Self.ink))
                Text("Réf. \(document.reference)").font(font(11, mono: true))
            }
            .font(font(11))
            .foregroundStyle(Self.gray)
            .lineLimit(1)
            .fixedSize()
        }
        .frame(height: px(46), alignment: .top)
        .padding(.bottom, px(12))
        .overlay(alignment: .bottom) { Rectangle().fill(Self.ink).frame(height: px(2)) }
    }

    private var footer: some View {
        HStack(spacing: px(10)) {
            Text("\(document.title) · Confidentiel").lineLimit(1)
            Spacer(minLength: px(10))
            Text("Généré par \(document.generator)").lineLimit(1)
            Spacer(minLength: px(10))
            Text("Page \(page.number) de \(totalPages)").fontWeight(.semibold).foregroundStyle(Self.ink).fixedSize()
        }
        .font(font(10))
        .foregroundStyle(Self.gray)
        .padding(.top, px(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Self.line).frame(height: 1) }
    }

    // MARK: Contenu

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if document.sections.isEmpty {
                Text("Aucune section cochée\u{00A0}: cochez au moins une section à gauche.")
                    .font(font(12))
                    .foregroundStyle(Self.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, px(40))
            }
            ForEach(Array(page.items.enumerated()), id: \.offset) { index, item in
                itemView(item)
                    .padding(.top, spacing(before: index))
            }
            if page.hasSignature {
                Spacer(minLength: 0)
                signature
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Espace avant l'élément : entre deux sections, entre deux blocs, rien sous un titre.
    private func spacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        switch (page.items[index - 1], page.items[index]) {
        case (_, .heading): return pt(metrics.sectionGap)
        case (.heading, _): return 0
        default: return pt(metrics.blockGap)
        }
    }

    @ViewBuilder private func itemView(_ item: ReportPageItem) -> some View {
        switch item {
        case .heading(let title, let continued):
            Text(continued ? "\(title) (suite)" : title)
                .font(font(13, .bold))
                .lineLimit(1)
                .frame(height: pt(metrics.headingHeight), alignment: .topLeading)
        case .block(let block):
            blockView(block)
        }
    }

    @ViewBuilder private func blockView(_ block: ReportBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(font(12))
                .lineSpacing(px(12 * 0.5 - 2))
                .foregroundStyle(Self.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: pt(metrics.height(of: block)), alignment: .topLeading)
        case .note(let text):
            Text(text)
                .font(font(11))
                .lineSpacing(px(11 * 0.5 - 2))
                .foregroundStyle(Self.gray)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: pt(metrics.height(of: block)), alignment: .topLeading)
        case .kpis(let kpis):
            HStack(alignment: .top, spacing: px(6)) {
                ForEach(Array(kpis.enumerated()), id: \.offset) { _, kpi in
                    VStack(alignment: .leading, spacing: px(2)) {
                        Text(kpi.value)
                            .font(font(18, .bold, mono: true))
                            .foregroundStyle(color(kpi.tone))
                            .lineLimit(1)
                        Text(kpi.label)
                            .font(font(11))
                            .foregroundStyle(Self.gray)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(px(8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(RoundedRectangle(cornerRadius: px(6)).strokeBorder(Self.line))
                }
            }
            .frame(height: pt(metrics.kpiHeight - 4))
            .frame(height: pt(metrics.kpiHeight), alignment: .top)
        case .bars(let title, let bars):
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(font(11, .semibold))
                    .kerning(px(0.4))
                    .foregroundStyle(Self.gray)
                    .frame(height: pt(metrics.barTitleHeight), alignment: .topLeading)
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    HStack(spacing: px(8)) {
                        Text(bar.label)
                            .font(font(11))
                            .foregroundStyle(Self.body)
                            .lineLimit(1)
                            .frame(width: px(150), alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: px(2)).fill(Color(hex: 0xF3F4F6))
                                RoundedRectangle(cornerRadius: px(2))
                                    .fill(bar.muted ? Color(hex: 0x6B7280) : Self.reportAccent)
                                    .frame(width: max(px(2), geometry.size.width * bar.fraction))
                            }
                        }
                        .frame(height: px(9))
                        Text("\(bar.count) · \(bar.share)")
                            .font(font(11, mono: true))
                            .lineLimit(1)
                            .frame(width: px(70), alignment: .trailing)
                    }
                    .frame(height: pt(metrics.barHeight))
                }
            }
        case .table(let table):
            tableView(table)
        case .code(let lines):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(font(11, mono: true))
                        .lineLimit(1)
                        .frame(height: pt(metrics.codeLineHeight), alignment: .leading)
                }
            }
            .padding(.vertical, pt(metrics.codePadding / 2))
            .padding(.horizontal, px(10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: px(4)).fill(Color(hex: 0xF9FAFB)))
            .overlay(RoundedRectangle(cornerRadius: px(4)).strokeBorder(Self.line))
        }
    }

    // MARK: Tableaux

    private func tableView(_ table: ReportTable) -> some View {
        let widths = metrics.columnWidths(table).map { pt($0) }
        let side = pt(metrics.cellPadding(table) / 2)
        let vertical = pt(metrics.cellVerticalPadding(table) / 2)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                    Text(column.title.uppercased())
                        .font(.system(size: pt(metrics.headerSize(table)), weight: .semibold))
                        .foregroundStyle(Self.gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, side)
                        .frame(width: widths[index], alignment: column.trailing ? .trailing : .leading)
                }
            }
            .frame(height: pt(metrics.tableHeaderHeight))
            .background(Color(hex: 0xF9FAFB))
            .overlay(alignment: .bottom) { Rectangle().fill(Self.line).frame(height: 1) }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                let height = metrics.rowHeight(row, in: table)
                // Ligne sur plusieurs lignes de texte : alignée en haut ; sinon centrée.
                let topAligned = height > (table.dense ? metrics.denseRowHeight : metrics.rowHeight) + 0.5
                HStack(alignment: topAligned ? .top : .center, spacing: 0) {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                        if index < widths.count {
                            cellView(cell, column: table.columns[index], wraps: table.wraps)
                                .padding(.horizontal, side)
                                .padding(.vertical, topAligned ? vertical : 0)
                                .frame(width: widths[index], alignment: table.columns[index].trailing ? .trailing : .leading)
                        }
                    }
                }
                .frame(height: pt(height), alignment: topAligned ? .top : .center)
                .background(row.isTotal ? Color(hex: 0xF9FAFB) : Color.clear)
                // Sous-total : il ferme le groupe des lignes au-dessus (même réseau) ; un trait plus
                // foncé le sépare du groupe suivant pour qu'il ne se lise pas comme un segment de plus.
                .overlay(alignment: .top) {
                    if row.isTotal { Rectangle().fill(Self.gray.opacity(0.45)).frame(height: 1) }
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(row.isTotal ? Self.gray : Self.line).frame(height: row.isTotal ? px(1.5) : 1)
                }
            }
        }
    }

    @ViewBuilder private func cellView(_ cell: ReportCell, column: ReportColumn, wraps: Bool) -> some View {
        if let badge = cell.badge {
            Text(cell.text)
                .font(.system(size: pt(metrics.badgeSize), weight: .bold))
                .foregroundStyle(color(badge))
                .lineLimit(1)
                .padding(.horizontal, px(6))
                .padding(.vertical, px(1))
                .background(RoundedRectangle(cornerRadius: px(4)).fill(soft(badge)))
                .fixedSize()
        } else if let bar = cell.bar {
            HStack(spacing: px(6)) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: px(2)).fill(Color(hex: 0xF3F4F6))
                        RoundedRectangle(cornerRadius: px(2))
                            .fill(bar >= 0.7 ? Theme.warning : Self.reportAccent)
                            .frame(width: max(px(2), geometry.size.width * min(1, bar)))
                    }
                }
                .frame(height: px(7))
                Text(cell.text)
                    .font(font(11, mono: true))
                    .lineLimit(1)
                    .frame(width: px(36), alignment: .trailing)
            }
        } else {
            let size = pt(column.size ?? metrics.bodySize)
            Text(cell.text)
                .font(.system(size: size, weight: cell.bold ? .semibold : .regular, design: column.mono ? .monospaced : .default))
                .foregroundStyle(color(cell.tone))
                .lineLimit(wraps ? nil : 1)
                // Interligne de 1,45 (la hauteur naturelle d'une ligne est d'environ 1,2 fois la taille).
                .lineSpacing(wraps ? size * 0.25 : 0)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: wraps)
        }
    }

    // MARK: Signature

    private var signature: some View {
        HStack(alignment: .top, spacing: px(24)) {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Color.clear).frame(height: px(30))
                    .overlay(alignment: .bottom) { Rectangle().fill(Self.ink).frame(height: 1) }
                (Text(document.technicianLabel).fontWeight(.semibold) + Text(", technicien"))
                    .font(font(11)).padding(.top, px(4)).frame(height: px(18), alignment: .bottom)
                Text(document.dateLabel).font(font(11)).foregroundStyle(Self.gray).frame(height: px(14))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Color.clear).frame(height: px(30))
                    .overlay(alignment: .bottom) { Rectangle().fill(Self.ink).frame(height: 1) }
                Text("Signature du client").font(font(11, .semibold)).padding(.top, px(4)).frame(height: px(18), alignment: .bottom)
                Text("Nom\u{00A0}: \(ReportText.missing)").font(font(11)).foregroundStyle(Self.gray).frame(height: px(14))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
        .frame(height: pt(metrics.signatureHeight), alignment: .bottom)
    }

    // MARK: Couleurs

    private func color(_ tone: ReportTone) -> Color {
        switch tone {
        case .normal: return Self.ink
        case .muted: return Self.body
        case .neutral: return Self.gray
        case .success: return Theme.success
        case .caution: return Color(hex: 0x92400E)
        case .warning: return Theme.warning
        case .critical: return Theme.critical
        }
    }

    private func soft(_ tone: ReportTone) -> Color {
        switch tone {
        case .success: return Theme.successSoft
        case .caution: return Color(hex: 0xFEF3C7)
        case .warning: return Theme.warningSoft
        case .critical: return Theme.criticalSoft
        default: return Theme.neutralSoft
        }
    }
}

/// Emplacement du logo : l'image choisie, sinon un cadre pointillé « [VOTRE LOGO] ».
struct RapportLogoBox: View {
    let logo: NSImage?
    let width: CGFloat
    let height: CGFloat
    var fontSize: CGFloat = 11
    var radius: CGFloat = 6
    var filled = false

    var body: some View {
        Group {
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
            } else {
                Text("[VOTRE LOGO]")
                    .font(.system(size: fontSize, weight: .bold))
                    .kerning(0.4)
                    .foregroundStyle(RapportPageView.gray)
                    .frame(width: width, height: height)
                    .background(RoundedRectangle(cornerRadius: radius).fill(filled ? Theme.panelMuted : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color(hex: 0x9CA3AF), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
        }
        .frame(width: width, height: height)
    }
}
