import AppKit
import NetScopeCore
import SwiftUI

// MARK: - Clés de tri (toujours Comparable : les valeurs absentes passent en dernier)

extension InvRecord {
    /// Favoris en premier dans l'ordre croissant.
    var invSortFavorite: Int { annotations.isFavorite ? 0 : 1 }
    var invSortStatus: Int {
        switch status() {
        case .conflit: return 0
        case .enLigne: return 1
        case .horsLigne: return 2
        case .disparu: return 3
        }
    }
    var invSortType: String { type.label }
    var invSortDetectedType: String { detectedType.label }
    var invSortMAC: UInt64 { mac?.value ?? .max }
    var invSortSwitch: String { switchLocation ?? "\u{10FFFF}" }
    var invSortHostname: String { hostname ?? "\u{10FFFF}" }
    var invSortRange: String { rangeLabel ?? "\u{10FFFF}" }
    var invSortVLAN: Int { vlan ?? .max }
    var invSortPorts: Int { openPorts.count }
    var invSortTags: String { annotations.tags.joined(separator: ", ") }
    var invSortLocation: String { annotations.location }
    var invSortWallJack: String { annotations.wallJack }
    var invSortOwner: String { annotations.owner }
    var invSortAsset: String { annotations.assetNumber }
    var invSortNotes: String { annotations.notes }
    var invSortIPHistory: Int { ipHistory.count }
}

/// Tableau des fiches de l'inventaire : tableau standard (note 8), une ligne par fiche, ligne choisie
/// = fiche affichée dessous ; étoile : favori ; double-clic : fiche complète de l'appareil.
struct InvTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    let rows: [InvRecord]
    let total: Int
    let selectedKey: String?
    @ObservedObject var table: StandardTableModel<InvRecord>
    let now: Date
    let onSelect: (String) -> Void
    let onFavorite: (String) -> Void

    /// Hauteur d'une ligne (contenu 30 pt + marges du tableau) et de l'en-tête, pour donner au
    /// tableau une hauteur fixe dans l'écran qui défile.
    static let rowHeight: CGFloat = 38
    static let headerHeight: CGFloat = 40
    private static let maxVisibleRows = 11
    private static let cellHeight: CGFloat = 30

    // MARK: Colonnes

    static let columns: [StandardColumn] = [
        StandardColumn(id: "favori", title: "Favori"),
        StandardColumn(id: "nom", title: "Nom"),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "ip", title: "IP actuelle", isRequired: true),
        StandardColumn(id: "mac", title: "MAC"),
        StandardColumn(id: "fabricant", title: "Fabricant"),
        StandardColumn(id: "switch", title: "Switch / port"),
        StandardColumn(id: "derniereVue", title: "Dernière vue"),
        StandardColumn(id: "statut", title: "Statut"),
        StandardColumn(id: "local", title: "Local", isDefaultVisible: false),
        StandardColumn(id: "prise", title: "Prise murale", isDefaultVisible: false),
        StandardColumn(id: "responsable", title: "Responsable", isDefaultVisible: false),
        StandardColumn(id: "actif", title: "N° d’actif", isDefaultVisible: false),
        StandardColumn(id: "etiquettes", title: "Étiquettes", isDefaultVisible: false),
        StandardColumn(id: "notes", title: "Notes", isDefaultVisible: false),
        StandardColumn(id: "premiereVue", title: "Première vue", isDefaultVisible: false),
        StandardColumn(id: "plage", title: "Plage", isDefaultVisible: false),
        StandardColumn(id: "vlan", title: "VLAN", isDefaultVisible: false),
        StandardColumn(id: "ports", title: "Ports ouverts", isDefaultVisible: false),
        StandardColumn(id: "typeDetecte", title: "Type détecté", isDefaultVisible: false),
        StandardColumn(id: "hostname", title: "Nom d’hôte", isDefaultVisible: false),
        StandardColumn(id: "historiqueIP", title: "Historique d’IP", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<InvRecord>] = [
        "favori": KeyPathComparator(\InvRecord.invSortFavorite),
        "nom": KeyPathComparator(\InvRecord.displayName, comparator: .localizedStandard),
        "type": KeyPathComparator(\InvRecord.invSortType, comparator: .localizedStandard),
        "ip": KeyPathComparator(\InvRecord.ip),
        "mac": KeyPathComparator(\InvRecord.invSortMAC),
        "fabricant": KeyPathComparator(\InvRecord.vendorLabel, comparator: .localizedStandard),
        "switch": KeyPathComparator(\InvRecord.invSortSwitch, comparator: .localizedStandard),
        // Dates : la plus récente d'abord au premier clic.
        "derniereVue": KeyPathComparator(\InvRecord.lastSeen, order: .reverse),
        "statut": KeyPathComparator(\InvRecord.invSortStatus),
        "local": KeyPathComparator(\InvRecord.invSortLocation, comparator: .localizedStandard),
        "prise": KeyPathComparator(\InvRecord.invSortWallJack, comparator: .localizedStandard),
        "responsable": KeyPathComparator(\InvRecord.invSortOwner, comparator: .localizedStandard),
        "actif": KeyPathComparator(\InvRecord.invSortAsset, comparator: .localizedStandard),
        "etiquettes": KeyPathComparator(\InvRecord.invSortTags, comparator: .localizedStandard),
        "notes": KeyPathComparator(\InvRecord.invSortNotes, comparator: .localizedStandard),
        "premiereVue": KeyPathComparator(\InvRecord.firstSeen, order: .reverse),
        "plage": KeyPathComparator(\InvRecord.invSortRange, comparator: .localizedStandard),
        "vlan": KeyPathComparator(\InvRecord.invSortVLAN),
        "ports": KeyPathComparator(\InvRecord.invSortPorts),
        "typeDetecte": KeyPathComparator(\InvRecord.invSortDetectedType, comparator: .localizedStandard),
        "hostname": KeyPathComparator(\InvRecord.invSortHostname, comparator: .localizedStandard),
        "historiqueIP": KeyPathComparator(\InvRecord.invSortIPHistory),
    ]

    /// Premier lancement : dernière détection, la plus récente d'abord (comme le croquis).
    @MainActor
    static func makeModel() -> StandardTableModel<InvRecord> {
        StandardTableModel(id: "inventaire", columns: columns, sortKeys: sortKeys, defaultSort: "derniereVue")
    }

    /// Lignes triées selon le tableau ; à égalité, par IP.
    static func sorted(_ records: [InvRecord], by order: [KeyPathComparator<InvRecord>]) -> [InvRecord] {
        records.sorted(using: order + [KeyPathComparator(\InvRecord.ip), KeyPathComparator(\InvRecord.key)])
    }

    /// « Dernière détection décroissant » : colonne et sens du tri actuel.
    static func sortLabel(_ order: [KeyPathComparator<InvRecord>]) -> String {
        guard let first = order.first,
              let id = sortKeys.first(where: { $0.value.keyPath == first.keyPath })?.key,
              let column = columns.first(where: { $0.id == id }) else { return "aucun" }
        return "\(column.title) \(first.order == .forward ? "croissant" : "décroissant")"
    }

    // MARK: Vue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("APPAREILS").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
                Text("\(rows.count) affiché\(rows.count > 1 ? "s" : "") · \(total) appareil\(total > 1 ? "s" : "") connu\(total > 1 ? "s" : "")")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Rectangle().fill(Theme.border).frame(height: 1)

            if rows.isEmpty {
                Text("Aucun appareil ne correspond à cette vue ou à la recherche.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                tableView
                    .frame(height: Self.headerHeight + CGFloat(min(rows.count, Self.maxVisibleRows)) * Self.rowHeight)
                    .scrollIndicators(rows.count > Self.maxVisibleRows ? .automatic : .never, axes: .vertical)
            }
            HStack {
                Text("Tri\u{00A0}: \(Self.sortLabel(table.sortOrder))")
                Spacer()
                Text("Cliquez une ligne pour ouvrir sa fiche · double-clic\u{00A0}: fiche complète · étoile\u{00A0}: favori")
                    .lineLimit(1)
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

    private var selection: Binding<String?> {
        Binding(get: { selectedKey }, set: { key in if let key { onSelect(key) } })
    }

    private var tableView: some View {
        Table(rows, selection: selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn("★", sortUsing: table.sort("favori")) { record in
                    favoriteButton(record)
                }
                .width(min: 26, ideal: 26, max: 40)
                .customizationID("favori")

                TableColumn("NOM", sortUsing: table.sort("nom")) { record in
                    nameCell(record)
                }
                .width(min: 110, ideal: 145)
                .customizationID("nom")

                TableColumn("TYPE", sortUsing: table.sort("type")) { record in
                    HStack(spacing: 5) {
                        Image(systemName: InvStyle.symbol(record.type)).font(.system(size: 11)).frame(width: 14)
                        Text(record.type.label).font(Theme.small).lineLimit(1)
                        if record.annotations.customType != nil { ManualTypeMark() }
                    }
                    .foregroundStyle(record.type == .inconnu ? Theme.textTertiary : Theme.neutralText)
                    .help(record.annotations.customType != nil ? "\(record.type.label) · choisi à la main"
                          : "\(record.type.label) · détecté par le scan")
                }
                .width(min: 80, ideal: 135)
                .customizationID("type")

                TableColumn("IP ACTUELLE", sortUsing: table.sort("ip")) { record in
                    Text(record.ip.description).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .width(min: 100, ideal: 112)
                .customizationID("ip")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("MAC", sortUsing: table.sort("mac")) { record in
                    ScanCellText(record.mac?.formatted(.upperColon) ?? "—", mono: true, dimmed: record.mac == nil)
                }
                .width(min: 110, ideal: 128)
                .customizationID("mac")

                TableColumn("FABRICANT", sortUsing: table.sort("fabricant")) { record in
                    ScanCellText(record.vendorLabel)
                }
                .width(min: 70, ideal: 80)
                .customizationID("fabricant")

                TableColumn("SWITCH / PORT", sortUsing: table.sort("switch")) { record in
                    ScanCellText(record.switchLocation ?? "—", mono: true, dimmed: record.switchLocation == nil)
                        .help(record.switchLocation ?? "")
                }
                .width(min: 100, ideal: 155)
                .customizationID("switch")

                TableColumn("DERNIÈRE VUE", sortUsing: table.sort("derniereVue")) { record in
                    ScanCellText(InvFormat.relative(record.lastSeen, now: now), secondary: true)
                        .help(InvFormat.stamp(record.lastSeen))
                }
                .width(min: 80, ideal: 125)
                .customizationID("derniereVue")

                TableColumn("STATUT", sortUsing: table.sort("statut")) { record in
                    let status = record.status(now: now)
                    let colors = InvStyle.status(status)
                    InvPill(text: status.label, foreground: colors.0, background: colors.1)
                }
                .width(min: 70, ideal: 80)
                .customizationID("statut")
            }

            Group {
                TableColumn("LOCAL", sortUsing: table.sort("local")) { record in
                    textCell(record.annotations.location)
                }
                .width(min: 80, ideal: 170)
                .customizationID("local")
                .defaultVisibility(.hidden)

                TableColumn("PRISE MURALE", sortUsing: table.sort("prise")) { record in
                    textCell(record.annotations.wallJack, mono: true)
                }
                .width(min: 60, ideal: 90)
                .customizationID("prise")
                .defaultVisibility(.hidden)

                TableColumn("RESPONSABLE", sortUsing: table.sort("responsable")) { record in
                    textCell(record.annotations.owner)
                }
                .width(min: 70, ideal: 110)
                .customizationID("responsable")
                .defaultVisibility(.hidden)

                TableColumn("N° D’ACTIF", sortUsing: table.sort("actif")) { record in
                    textCell(record.annotations.assetNumber, mono: true)
                }
                .width(min: 60, ideal: 95)
                .customizationID("actif")
                .defaultVisibility(.hidden)

                TableColumn("ÉTIQUETTES", sortUsing: table.sort("etiquettes")) { record in
                    StandardTagList(tags: record.annotations.tags,
                                    help: "Étiquettes\u{00A0}: " + record.annotations.tags.joined(separator: ", "))
                }
                .width(min: 70, ideal: 150)
                .customizationID("etiquettes")
                .defaultVisibility(.hidden)

                TableColumn("NOTES", sortUsing: table.sort("notes")) { record in
                    textCell(record.annotations.notes.replacingOccurrences(of: "\n", with: " "))
                }
                .width(min: 80, ideal: 180)
                .customizationID("notes")
                .defaultVisibility(.hidden)

                TableColumn("PREMIÈRE VUE", sortUsing: table.sort("premiereVue")) { record in
                    ScanCellText(InvFormat.day(record.firstSeen), mono: true, secondary: true)
                }
                .width(min: 80, ideal: 120)
                .customizationID("premiereVue")
                .defaultVisibility(.hidden)

                TableColumn("PLAGE", sortUsing: table.sort("plage")) { record in
                    textCell(record.rangeLabel ?? "")
                }
                .width(min: 60, ideal: 100)
                .customizationID("plage")
                .defaultVisibility(.hidden)

                TableColumn("VLAN", sortUsing: table.sort("vlan")) { record in
                    if let vlan = record.vlan {
                        Chip(text: "\(vlan)", mono: true)
                    } else {
                        ScanCellText("—", dimmed: true)
                    }
                }
                .width(min: 44, ideal: 56)
                .customizationID("vlan")
                .defaultVisibility(.hidden)
            }

            Group {
                TableColumn("PORTS OUVERTS", sortUsing: table.sort("ports")) { record in
                    ScanPortTags(ports: record.openPorts)
                }
                .width(min: 70, ideal: 140)
                .customizationID("ports")
                .defaultVisibility(.hidden)

                TableColumn("TYPE DÉTECTÉ", sortUsing: table.sort("typeDetecte")) { record in
                    ScanTypeCell(type: record.detectedType, isManual: false)
                }
                .width(min: 80, ideal: 140)
                .customizationID("typeDetecte")
                .defaultVisibility(.hidden)

                TableColumn("NOM D’HÔTE", sortUsing: table.sort("hostname")) { record in
                    textCell(record.hostname ?? "")
                }
                .width(min: 80, ideal: 150)
                .customizationID("hostname")
                .defaultVisibility(.hidden)

                TableColumn("HISTORIQUE D’IP", sortUsing: table.sort("historiqueIP")) { record in
                    Text("\(record.ipHistory.count)")
                        .font(Theme.mono(12))
                        .foregroundStyle(record.ipHistory.count > 1 ? Theme.text : Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(record.ipHistory.reversed().map(\.ip.description).joined(separator: ", "))
                }
                .width(min: 60, ideal: 100)
                .customizationID("historiqueIP")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: String.self) { keys in
            if let key = keys.first, let record = model.record(key) {
                menu(record)
            }
        } primaryAction: { keys in
            guard let key = keys.first, let record = model.record(key) else { return }
            onSelect(key)
            if state.device(withID: record.ip.description) != nil { state.showDevice(record.ip.description) }
        }
    }

    // MARK: Cellules

    private func favoriteButton(_ record: InvRecord) -> some View {
        let favorite = record.annotations.isFavorite
        return Button { onFavorite(record.key) } label: {
            Image(systemName: favorite ? "star.fill" : "star")
                .font(.system(size: 12))
                .foregroundStyle(favorite ? Theme.warning : Theme.textTertiary)
                .frame(maxWidth: .infinity, minHeight: Self.cellHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(favorite ? "Retirer \(record.displayName) des favoris" : "Ajouter \(record.displayName) aux favoris")
    }

    private func nameCell(_ record: InvRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(record.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if record.isUnidentified {
                    InvPill(text: "NON IDENTIFIÉ", foreground: Theme.warning, background: Theme.warningSoft, size: 9.5)
                }
            }
            if let host = record.hostname, host != record.displayName {
                Text(host).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .frame(height: Self.cellHeight)
        .help(record.hostname.map { "\(record.displayName) · \($0)" } ?? record.displayName)
    }

    private func textCell(_ text: String, mono: Bool = false) -> some View {
        ScanCellText(text.isEmpty ? "—" : text, mono: mono, dimmed: text.isEmpty)
            .help(text)
    }

    @ViewBuilder
    private func menu(_ record: InvRecord) -> some View {
        Button(record.annotations.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") { onFavorite(record.key) }
        Divider()
        Button("Copier l’IP") { copy(record.ip.description, label: "IP") }
        Button("Copier la MAC") { if let mac = record.mac { copy(mac.formatted(.upperColon), label: "MAC") } }
            .disabled(record.mac == nil)
        Divider()
        Button("Fiche complète") { state.showDevice(record.ip.description) }
            .disabled(state.device(withID: record.ip.description) == nil)
        Button("Ping continu") { state.sendToPing(record.ip.description) }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.show("\(label) copiée\u{00A0}: \(text)")
    }
}
