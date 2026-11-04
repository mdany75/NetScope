import NetScopeCore
import SwiftUI

/// Écran `Screen.rapports` (croquis docs/croquis/Rapport.dc.html) : configuration du rapport à
/// gauche, aperçu page par page au format lettre à droite. Les données viennent du dernier scan
/// (AppState), de l'inventaire, des relevés des switchs et de l'analyse Wi-Fi.
struct RapportScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = RapportModel.shared
    @ObservedObject private var inventory = InvModel.shared

    var body: some View {
        let document = model.document(state: state)
        let pages = model.pages(for: document)
        let current = min(max(model.page, 1), pages.count)

        HStack(alignment: .top, spacing: 14) {
            ScrollView {
                RapportConfigPanel(model: model, startPages: ReportPaginator.startPages(pages), totalPages: pages.count)
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
                .help("Le rapport reprend le dernier scan de cette session et l’inventaire des plages scannées.")
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

    /// « Scan du 2026-11-03 09:12 · 16 appareils »
    private var sourceLabel: String {
        guard let last = state.devices.map(\.lastSeen).max() else { return "Aucun scan dans cette session" }
        let count = state.devices.count
        return "Scan du \(InvFormat.stamp(last)) · \(count) appareil\(count > 1 ? "s" : "")"
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
                Text("Format lettre · 8,5 × 11 po · \(pages.count) page\(pages.count > 1 ? "s" : "")")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                pager
            }
            .padding(.horizontal, 12)
            .frame(height: 49)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            ScrollView([.vertical, .horizontal]) {
                if let page = pages.first(where: { $0.number == current }) ?? pages.first {
                    RapportPageView(document: document, page: page, totalPages: pages.count, logo: logo)
                        .shadow(color: Color(hex: 0x0F172A, opacity: 0.08), radius: 12, y: 8)
                        .shadow(color: Color(hex: 0x0F172A, opacity: 0.12), radius: 1.5, y: 1)
                        .padding(.vertical, 24)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Aperçu du rapport, page \(page.number) de \(pages.count)")
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

    private var visiblePages: [Int] {
        let count = pages.count
        guard count > 5 else { return Array(1...max(count, 1)) }
        let start = min(max(1, current - 2), count - 4)
        return Array(start...(start + 4))
    }
}
