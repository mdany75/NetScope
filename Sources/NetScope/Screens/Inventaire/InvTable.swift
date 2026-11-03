import NetScopeCore
import SwiftUI

enum InvSortKey: String {
    case nom, ip, premiere, derniere

    var label: String {
        switch self {
        case .nom: return "Nom"
        case .ip: return "IP actuelle"
        case .premiere: return "Première détection"
        case .derniere: return "Dernière détection"
        }
    }

    /// Sens proposé au premier clic.
    var defaultAscending: Bool { self == .nom || self == .ip }
}

/// Colonnes du tableau d'inventaire ; les moins utiles disparaissent quand la fenêtre est étroite.
enum InvColumn: CaseIterable {
    case favori, nom, type, ip, mac, fabricant, etiquettes, local, switchPort, responsable, premiere, derniere, statut

    var title: String {
        switch self {
        case .favori: return ""
        case .nom: return "Nom"
        case .type: return "Type"
        case .ip: return "IP actuelle"
        case .mac: return "MAC"
        case .fabricant: return "Fabricant"
        case .etiquettes: return "Étiquettes"
        case .local: return "Local / prise murale"
        case .switchPort: return "Switch / port"
        case .responsable: return "Responsable"
        case .premiere: return "Première détection"
        case .derniere: return "Dernière détection"
        case .statut: return "Statut"
        }
    }

    /// Largeur fixe ; nil pour la colonne Nom, qui prend le reste.
    var width: CGFloat? {
        switch self {
        case .favori: return 30
        case .nom: return nil
        case .type: return 136
        case .ip: return 124
        case .mac: return 140
        case .fabricant: return 90
        case .etiquettes: return 150
        case .local: return 150
        case .switchPort: return 170
        case .responsable: return 110
        case .premiere: return 100
        case .derniere: return 128
        case .statut: return 90
        }
    }

    var sortKey: InvSortKey? {
        switch self {
        case .nom: return .nom
        case .ip: return .ip
        case .premiere: return .premiere
        case .derniere: return .derniere
        default: return nil
        }
    }

    /// Ordre de retrait quand la place manque.
    static let dropOrder: [InvColumn] = [.responsable, .premiere, .fabricant, .type, .etiquettes]

    static func visible(for width: CGFloat) -> [InvColumn] {
        var columns = allCases
        let minimumName: CGFloat = 160
        for column in dropOrder {
            let used = columns.compactMap(\.width).reduce(0, +) + minimumName
            if used <= width { break }
            columns.removeAll { $0 == column }
        }
        return columns
    }
}

/// Tableau triable des fiches (lignes de 38 pt, en-tête gris, ligne choisie en bleu pâle).
struct InvTable: View {
    let rows: [InvRecord]
    let total: Int
    let width: CGFloat
    let selectedKey: String?
    @Binding var sort: InvSortKey
    @Binding var ascending: Bool
    let now: Date
    let onSelect: (String) -> Void
    let onFavorite: (String) -> Void

    private static let rowHeight: CGFloat = 38
    private static let maxVisibleRows = 11

    var body: some View {
        let columns = InvColumn.visible(for: width - 2)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("APPAREILS").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
                Text("\(rows.count) affiché\(rows.count > 1 ? "s" : "") · \(total) appareil\(total > 1 ? "s" : "") connu\(total > 1 ? "s" : "")")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            header(columns)
            if rows.isEmpty {
                Text("Aucun appareil ne correspond à cette vue ou à la recherche.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { record in
                            row(record, columns)
                        }
                    }
                }
                .frame(height: CGFloat(min(rows.count, Self.maxVisibleRows)) * Self.rowHeight)
            }
            HStack {
                Text("Tri : \(sort.label) \(ascending ? "croissant" : "décroissant")")
                Spacer()
                Text("Cliquez une ligne pour ouvrir sa fiche · étoile : favori")
            }
            .font(Theme.small)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.panelMuted)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func header(_ columns: [InvColumn]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                cell(column) {
                    if let key = column.sortKey {
                        Button {
                            if sort == key { ascending.toggle() } else { sort = key; ascending = key.defaultAscending }
                        } label: {
                            HStack(spacing: 3) {
                                headerText(column.title)
                                Text(sort == key ? (ascending ? "↑" : "↓") : "↕")
                                    .font(.system(size: sort == key ? 12 : 11))
                                    .foregroundStyle(sort == key ? Theme.accentStrong : Theme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        headerText(column.title)
                    }
                }
            }
        }
        .frame(height: 32)
        .background(Theme.panelMuted)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func headerText(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.captionSemibold)
            .kerning(0.3)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func cell<Content: View>(_ column: InvColumn, @ViewBuilder _ content: () -> Content) -> some View {
        let inner = content().padding(.horizontal, 8)
        if let width = column.width {
            inner.frame(width: width, alignment: .leading)
        } else {
            inner.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ record: InvRecord, _ columns: [InvColumn]) -> some View {
        let selected = record.key == selectedKey
        return HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                cell(column) { content(column, record, typeHidden: !columns.contains(.type)) }
            }
        }
        .frame(height: Self.rowHeight)
        .background(selected ? Theme.accentSoft : Theme.panel)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(record.key) }
    }

    @ViewBuilder
    private func content(_ column: InvColumn, _ record: InvRecord, typeHidden: Bool) -> some View {
        let notes = record.annotations
        switch column {
        case .favori:
            Button { onFavorite(record.key) } label: {
                Image(systemName: notes.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(notes.isFavorite ? Theme.warning : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(notes.isFavorite ? "Retirer \(record.displayName) des favoris" : "Ajouter \(record.displayName) aux favoris")
        case .nom:
            HStack(spacing: 8) {
            if typeHidden {
                Image(systemName: InvStyle.symbol(record.type)).font(.system(size: 12))
                    .foregroundStyle(Theme.neutralText).frame(width: 16)
                    .help(record.type.label)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(record.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if record.isUnidentified {
                        InvPill(text: "NON IDENTIFIÉ", foreground: Theme.warning, background: Theme.warningSoft, size: 9.5)
                    }
                }
                if let host = record.hostname, host != record.displayName {
                    Text(host).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            }
        case .type:
            HStack(spacing: 5) {
                Image(systemName: InvStyle.symbol(record.type)).font(.system(size: 11)).frame(width: 14)
                Text(record.type.label).font(Theme.small).lineLimit(1)
            }
            .foregroundStyle(Theme.neutralText)
        case .ip:
            Text(record.ip.description).font(Theme.mono(12, weight: .semibold)).lineLimit(1)
        case .mac:
            Text(record.mac?.formatted(.upperColon) ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.neutralText).lineLimit(1)
        case .fabricant:
            Text(record.vendorLabel).font(Theme.small).foregroundStyle(Theme.neutralText).lineLimit(1)
        case .etiquettes:
            if notes.tags.isEmpty {
                Text("—").foregroundStyle(Theme.textTertiary)
            } else {
                HStack(spacing: 4) {
                    ForEach(notes.tags.prefix(2), id: \.self) { tag in
                        let colors = InvStyle.tag(tag)
                        InvPill(text: tag, foreground: colors.0, background: colors.1)
                    }
                    if notes.tags.count > 2 {
                        Text("+\(notes.tags.count - 2)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        case .local:
            Text(locationLabel(notes)).font(Theme.small).foregroundStyle(Theme.neutralText).lineLimit(1)
                .help(locationLabel(notes))
        case .switchPort:
            Text(record.switchLocation ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.neutralText).lineLimit(1)
                .help(record.switchLocation ?? "")
        case .responsable:
            Text(notes.owner.isEmpty ? "—" : notes.owner).font(Theme.small).foregroundStyle(Theme.neutralText).lineLimit(1)
        case .premiere:
            Text(InvFormat.day(record.firstSeen)).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
        case .derniere:
            Text(InvFormat.relative(record.lastSeen, now: now))
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        case .statut:
            let status = record.status(now: now)
            let colors = InvStyle.status(status)
            InvPill(text: status.label, foreground: colors.0, background: colors.1)
        }
    }

    private func locationLabel(_ notes: InvAnnotations) -> String {
        switch (notes.location.isEmpty, notes.wallJack.isEmpty) {
        case (true, true): return "—"
        case (false, true): return notes.location
        case (true, false): return "Prise \(notes.wallJack)"
        case (false, false): return "\(notes.location) · Prise \(notes.wallJack)"
        }
    }
}
