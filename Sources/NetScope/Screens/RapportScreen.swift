import NetScopeCore
import SwiftUI

/// Écran `Screen.rapports` (croquis docs/croquis/Rapport.dc.html) : configuration du rapport à
/// gauche, aperçu page par page au format lettre à droite. Les données viennent du dernier scan
/// (AppState), de l'inventaire, des relevés des switchs et de l'analyse Wi-Fi.
struct RapportScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = RapportModel.shared
    @ObservedObject private var inventory = InvModel.shared
    @ObservedObject private var scope = SiteScopeStore.shared

    var body: some View {
        let inputs = model.siteInputs(state: state)
        let document = model.document(for: inputs)
        let pages = model.pages(for: document)
        let first = inputs.first
        let current = min(max(model.page, 1), pages.count)

        HStack(alignment: .top, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    siteRow
                    RapportConfigPanel(model: model, startPages: ReportPaginator.startPageRuns(pages), totalPages: pages.count,
                                       followUpKey: first?.key ?? SiteModel.shared.activeKey,
                                       followUpSite: first?.site.name ?? SiteModel.shared.activeName,
                                       followUp: first?.site.input.followUp, multisite: inputs.count > 1)
                }
                    .padding(.vertical, 16)
                    .padding(.leading, Theme.contentPadding)
                    .padding(.trailing, 2)
            }
            .frame(width: 340 + Theme.contentPadding + 2)
            RapportPreview(document: document, pages: pages, current: current, logo: model.logo) { model.page = $0 }
                .padding(.vertical, 16)
                .padding(.trailing, Theme.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .screenToolbar { toolbar }
        .feedsInventory(state)
    }

    /// Sites du rapport, en haut de la colonne de réglages : un, plusieurs ou tous les sites ;
    /// plusieurs donnent un rapport multisite (une section par site).
    private var siteRow: some View {
        let count = scope.keys(for: .rapports).count
        return HStack(spacing: 10) {
            SiteScopeMenu(screen: .rapports)
            // Petite colonne : forme courte plutôt qu'une phrase coupée.
            ViewThatFits(in: .horizontal) {
                Text(count > 1 ? "Rapport multisite\u{00A0}: une section par site" : "Rapport d’un seul site").fixedSize()
                Text(count > 1 ? "Une section par site" : "Un seul site").fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            .font(Theme.small).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 6) {
            Text("Source").font(Theme.small).foregroundStyle(Theme.textSecondary)
            Text(sourceLabel)
                .font(Theme.small)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: Theme.controlHeight)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                .fixedSize()
                .help(sourceHelp)
        }
        Button { model.newReport() } label: { Label("Nouveau rapport", systemImage: "plus") }
            .buttonStyle(.secondary)
        Button { model.printReport(state: state) } label: { Label("Imprimer", systemImage: "printer") }
            .buttonStyle(.secondary)
        Button { model.generate(state: state) } label: {
            Label(model.config.format.actionLabel, systemImage: "arrow.down.doc")
        }
        .buttonStyle(.primary)
    }

    /// « Scan du 3 nov. · 16 app. » : court, pour laisser sa place au champ de recherche de la barre d'outils.
    private var sourceLabel: String {
        let keys = SiteScopeStore.shared.keys(for: .rapports)
        if keys != [SiteModel.shared.activeKey] {
            let count = RapportData.inputs(state: state, demo: model.isDemo, keys: keys).reduce(0) { $0 + $1.input.devices.count }
            return keys.count > 1 ? "\(keys.count) sites · \(count) app." : "Dernier scan · \(count) app."
        }
        guard let last = state.devices.map(\.lastSeen).max() else { return "Aucun scan" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return "Scan du \(formatter.string(from: last)) · \(state.devices.count) app."
    }

    /// Infobulle : le libellé complet (« Scan du 2026-11-03 09:12 · 16 appareils »).
    private var sourceHelp: String {
        let keys = SiteScopeStore.shared.keys(for: .rapports)
        if keys != [SiteModel.shared.activeKey] {
            return "Rapport " + (keys.count > 1 ? "multisite\u{00A0}: une section par site (" : "du site ")
                + keys.map { SiteModel.shared.name(forKey: $0) }.joined(separator: ", ") + (keys.count > 1 ? ")" : "")
                + ". Les autres sites que le site actif sont décrits d’après leur dernier scan enregistré et leur inventaire."
        }
        let source: String
        if let last = state.devices.map(\.lastSeen).max() {
            let count = state.devices.count
            source = "Scan du \(InvFormat.stamp(last)) · \(count) appareil\(count > 1 ? "s" : "")"
        } else {
            source = "Aucun scan dans cette session"
        }
        return source + ". Le rapport reprend le dernier scan de cette session et l’inventaire des plages scannées."
    }
}

/// Aperçu (croquis : « Aperçu », format lettre, pagination) : une page à la fois, 680 × 880 px.
struct RapportPreview: View {
    let document: ReportDocument
    let pages: [ReportPage]
    let current: Int
    let logo: NSImage?
    let select: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SectionHeader("Aperçu").fixedSize()
                // Libellé complet quand la place le permet, sinon une forme courte jamais tronquée.
                let pageCount = "\(pages.count) page\(pages.count > 1 ? "s" : "")"
                ViewThatFits(in: .horizontal) {
                    Text("Format lettre · 8,5 × 11 po · \(pageCount)").fixedSize()
                    Text("Lettre · \(pageCount)").fixedSize()
                    Text(pageCount).fixedSize()
                }
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                .help("Format lettre · 8,5 × 11 po · \(pageCount)")
                Spacer(minLength: 8)
                // Petite fenêtre : « ‹ 1 / 6 › » plutôt que cinq boutons, pour que l'écran ne
                // défile jamais horizontalement.
                ViewThatFits(in: .horizontal) {
                    pager
                    compactPager
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 49)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            // En petite fenêtre, la page est réduite pour tenir dans la largeur du panneau (jamais
            // agrandie) : pas de défilement horizontal.
            GeometryReader { geometry in
                let metrics = ReportPageMetrics()
                let pageWidth = CGFloat(metrics.pageWidth / ReportPageMetrics.scale)
                let pageHeight = CGFloat(metrics.pageHeight / ReportPageMetrics.scale)
                let scale = min(1, max(0.4, (geometry.size.width - 32) / pageWidth))
                ScrollView(.vertical) {
                    if let page = pages.first(where: { $0.number == current }) ?? pages.first {
                        RapportPageView(document: document, page: page, totalPages: pages.count, logo: logo)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: pageWidth * scale, height: pageHeight * scale, alignment: .topLeading)
                            .shadow(color: Color(hex: 0x0F172A, opacity: 0.08), radius: 12, y: 8)
                            .shadow(color: Color(hex: 0x0F172A, opacity: 0.12), radius: 1.5, y: 1)
                            .padding(.vertical, 24)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Aperçu du rapport, page \(page.number) de \(pages.count)")
                    }
                }
            }
            .background(Theme.border)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: Theme.panelRadius, bottomTrailingRadius: Theme.panelRadius))
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    /// « ‹ Page 1 Page 2 … › » : au plus cinq boutons autour de la page affichée.
    private var pager: some View {
        let numbers = visiblePages
        return HStack(spacing: 4) {
            Button { select(max(1, current - 1)) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(RapportSmallButtonStyle(width: 28))
                .disabled(current <= 1)
                .help("Page précédente")
            ForEach(numbers, id: \.self) { number in
                let on = number == current
                Button { select(number) } label: {
                    Text(numbers.count > 3 ? "\(number)" : "Page \(number)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? Theme.accentStrong : Theme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(on ? Theme.accentSoft : Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(on ? Theme.accent : Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { select(min(pages.count, current + 1)) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(RapportSmallButtonStyle(width: 28))
                .disabled(current >= pages.count)
                .help("Page suivante")
        }
        .fixedSize()
    }

    /// Forme courte du sélecteur de pages : « ‹ 2 / 6 › ».
    private var compactPager: some View {
        HStack(spacing: 4) {
            Button { select(max(1, current - 1)) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(RapportSmallButtonStyle(width: 28))
                .disabled(current <= 1)
                .help("Page précédente")
            Text("\(current) / \(max(pages.count, 1))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 6)
                .help("Page \(current) de \(max(pages.count, 1))")
            Button { select(min(pages.count, current + 1)) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(RapportSmallButtonStyle(width: 28))
                .disabled(current >= pages.count)
                .help("Page suivante")
        }
        .fixedSize()
    }

    private var visiblePages: [Int] {
        let count = pages.count
        guard count > 5 else { return Array(1...max(count, 1)) }
        let start = min(max(1, current - 2), count - 4)
        return Array(start...(start + 4))
    }
}
