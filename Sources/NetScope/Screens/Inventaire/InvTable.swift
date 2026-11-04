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

/// Tableau des fiches de l'inventaire : tableau standard (note 8), une ligne par fiche ET par site
/// (identifiant « site|fiche » : deux sites ne fusionnent jamais) ; ligne choisie = fiche affichée
/// dessous ; ⌘-clic, ⇧-clic, ⌘A : plusieurs lignes ; ⌫ ou clic droit : supprimer de
/// l'inventaire ; étoile : favori ; double-clic : fiche complète de l'appareil.
struct InvTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    let rows: [SiteScopedRecord]
    let total: Int
    /// Lignes choisies (identifiants composés).
    @Binding var selection: Set<String>
    @ObservedObject var table: StandardTableModel<SiteScopedRecord>
    let now: Date
    /// Inventaire vide pour tous les sites affichés (message « lancez un scan »).
    var inventoryEmpty = false
    /// Sites affichés (titre du message d'inventaire vide).
    var siteNames: [String] = []
    /// Appareils qu'on ne suit plus, dans les sites affichés.
    var excluded: [InvExcludedRow] = []
    let onFavorite: (SiteScopedRecord) -> Void
    let onDelete: ([String]) -> Void

    /// Hauteur d'une ligne (contenu 30 pt + marges du tableau) et de l'en-tête, pour donner au
    /// tableau une hauteur fixe dans l'écran qui défile.
    static let rowHeight: CGFloat = 38
    static let headerHeight: CGFloat = 40
    private static let maxVisibleRows = 11
    private static let cellHeight: CGFloat = 30

    // MARK: Colonnes

    static let columns: [StandardColumn] = [
        StandardColumn(id: "favori", title: "Favori"),
        StandardColumn.site,
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

    static let sortKeys: [String: KeyPathComparator<SiteScopedRecord>] = [
        "favori": KeyPathComparator(\SiteScopedRecord.record.invSortFavorite),
        "site": KeyPathComparator(\SiteScopedRecord.siteName, comparator: .localizedStandard),
        "nom": KeyPathComparator(\SiteScopedRecord.record.displayName, comparator: .localizedStandard),
        "type": KeyPathComparator(\SiteScopedRecord.record.invSortType, comparator: .localizedStandard),
        "ip": KeyPathComparator(\SiteScopedRecord.record.ip),
        "mac": KeyPathComparator(\SiteScopedRecord.record.invSortMAC),
        "fabricant": KeyPathComparator(\SiteScopedRecord.record.vendorLabel, comparator: .localizedStandard),
        "switch": KeyPathComparator(\SiteScopedRecord.record.invSortSwitch, comparator: .localizedStandard),
        // Dates : la plus récente d'abord au premier clic.
        "derniereVue": KeyPathComparator(\SiteScopedRecord.record.lastSeen, order: .reverse),
        "statut": KeyPathComparator(\SiteScopedRecord.record.invSortStatus),
        "local": KeyPathComparator(\SiteScopedRecord.record.invSortLocation, comparator: .localizedStandard),
        "prise": KeyPathComparator(\SiteScopedRecord.record.invSortWallJack, comparator: .localizedStandard),
        "responsable": KeyPathComparator(\SiteScopedRecord.record.invSortOwner, comparator: .localizedStandard),
        "actif": KeyPathComparator(\SiteScopedRecord.record.invSortAsset, comparator: .localizedStandard),
        "etiquettes": KeyPathComparator(\SiteScopedRecord.record.invSortTags, comparator: .localizedStandard),
        "notes": KeyPathComparator(\SiteScopedRecord.record.invSortNotes, comparator: .localizedStandard),
        "premiereVue": KeyPathComparator(\SiteScopedRecord.record.firstSeen, order: .reverse),
        "plage": KeyPathComparator(\SiteScopedRecord.record.invSortRange, comparator: .localizedStandard),
        "vlan": KeyPathComparator(\SiteScopedRecord.record.invSortVLAN),
        "ports": KeyPathComparator(\SiteScopedRecord.record.invSortPorts),
        "typeDetecte": KeyPathComparator(\SiteScopedRecord.record.invSortDetectedType, comparator: .localizedStandard),
        "hostname": KeyPathComparator(\SiteScopedRecord.record.invSortHostname, comparator: .localizedStandard),
        "historiqueIP": KeyPathComparator(\SiteScopedRecord.record.invSortIPHistory),
    ]

    /// Premier lancement : dernière détection, la plus récente d'abord (comme le croquis).
    @MainActor
    static func makeModel() -> StandardTableModel<SiteScopedRecord> {
        StandardTableModel(id: "inventaire", columns: columns, sortKeys: sortKeys, defaultSort: "derniereVue")
    }

    /// Lignes triées selon le tableau ; à égalité, par IP.
    static func sorted(_ rows: [SiteScopedRecord], by order: [KeyPathComparator<SiteScopedRecord>]) -> [SiteScopedRecord] {
        rows.sorted(using: order + [KeyPathComparator(\SiteScopedRecord.record.ip), KeyPathComparator(\SiteScopedRecord.id)])
    }

    /// « Dernière détection décroissant » : colonne et sens du tri actuel.
    static func sortLabel(_ order: [KeyPathComparator<SiteScopedRecord>]) -> String {
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
                    .lineLimit(1)
                if selection.count > 1 {
                    Text("· \(selection.count) sélectionnés").font(Theme.small).fontWeight(.semibold)
                        .foregroundStyle(Theme.accentStrong).fixedSize()
                }
                Spacer(minLength: 8)
                if !excluded.isEmpty { InvExcludedButton(rows: excluded) }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Rectangle().fill(Theme.border).frame(height: 1)

            if rows.isEmpty, inventoryEmpty, !siteNames.isEmpty, SiteModel.shared.activeSite != nil || siteNames.count > 1 {
                // Inventaire propre au site : vide tant que ce site n'a pas été scanné.
                EmptyState(systemImage: "tray",
                           title: siteNames.count > 1 ? "Inventaires de ces \(siteNames.count) sites vides"
                               : "Inventaire de «\u{00A0}\(siteNames[0])\u{00A0}» vide",
                           message: "Lancez un scan de ce site pour le remplir. Les autres sites gardent leur propre inventaire.") {
                    Button("Ouvrir le Scanner") { state.open(.scanner) }
                        .buttonStyle(.secondary)
                }
                .frame(minHeight: 160)
            } else if rows.isEmpty {
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
                // Petite fenêtre : version courte plutôt qu'une phrase coupée.
                ViewThatFits(in: .horizontal) {
                    Text("Cliquez une ligne pour ouvrir sa fiche · ⌘-clic\u{00A0}: plusieurs · ⌫\u{00A0}: supprimer · double-clic\u{00A0}: fiche complète")
                        .fixedSize()
                    Text("⌘-clic\u{00A0}: plusieurs · ⌫\u{00A0}: supprimer · double-clic\u{00A0}: fiche complète").fixedSize()
                    Text("⌫\u{00A0}: supprimer").fixedSize()
                }
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

    private var tableView: some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn("★", sortUsing: table.sort("favori")) { row in
                    favoriteButton(row)
                }
                .width(min: 26, ideal: 26, max: 40)
                .customizationID("favori")

                // Plusieurs sites : colonne affichée d'office (InventaireScreen, `standardSiteColumn`).
                TableColumn("SITE", sortUsing: table.sort("site")) { row in
                    Text(row.siteName).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accentStrong)
                        .lineLimit(1).help("Inventaire du site «\u{00A0}\(row.siteName)\u{00A0}»")
                }
                .width(min: 70, ideal: 110)
                .customizationID("site")
                .defaultVisibility(.hidden)

                TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                    let record = row.record
                    nameCell(record)
                }
                .width(min: 110, ideal: 145)
                .customizationID("nom")

                TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                    let record = row.record
                    HStack(spacing: 5) {
                        Image(systemName: InvStyle.symbol(record.type)).font(.system(size: 11)).frame(width: 14)
                        Text(record.type.label).font(Theme.small).lineLimit(1)
                        if record.annotations.customType != nil { ManualTypeMark() }
                    }
                    .foregroundStyle(record.type == .inconnu ? Theme.textTertiary : Theme.neutralText)
                    .help(record.annotations.customType != nil ? "\(record.type.label) · choisi à la main"
                          : "\(record.type.label) · détecté par le scan")
                }
                .width(min: 80, ideal: 128)
                .customizationID("type")

                TableColumn("IP ACTUELLE", sortUsing: table.sort("ip")) { row in
                    let record = row.record
                    Text(record.ip.description).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .width(min: 100, ideal: 112)
                .customizationID("ip")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("MAC", sortUsing: table.sort("mac")) { row in
                    let record = row.record
                    ScanCellText(record.mac?.formatted(.upperColon) ?? "—", mono: true, dimmed: record.mac == nil)
                }
                .width(min: 110, ideal: 128)
                .customizationID("mac")

                TableColumn("FABRICANT", sortUsing: table.sort("fabricant")) { row in
                    let record = row.record
                    ScanCellText(record.vendorLabel)
                }
                .width(min: 70, ideal: 79)
                .customizationID("fabricant")

                TableColumn("SWITCH / PORT", sortUsing: table.sort("switch")) { row in
                    let record = row.record
                    // Le port reste lisible : switch au-dessus du port quand la colonne est étroite.
                    SwitchPortCell(name: record.switchName, port: record.switchPort)
                }
                .width(min: 90, ideal: 172)
                .customizationID("switch")

                TableColumn("DERNIÈRE VUE", sortUsing: table.sort("derniereVue")) { row in
                    let record = row.record
                    ScanCellText(InvFormat.relative(record.lastSeen, now: now), secondary: true)
                        .help(InvFormat.stamp(record.lastSeen))
                }
                .width(min: 80, ideal: 120)
                .customizationID("derniereVue")

                TableColumn("STATUT", sortUsing: table.sort("statut")) { row in
                    let record = row.record
                    let status = record.status(now: now)
                    let colors = InvStyle.status(status)
                    InvPill(text: status.label, foreground: colors.0, background: colors.1)
                }
                .width(min: 70, ideal: 76)
                .customizationID("statut")
            }

            Group {
                TableColumn("LOCAL", sortUsing: table.sort("local")) { row in
                    let record = row.record
                    textCell(record.annotations.location)
                }
                .width(min: 80, ideal: 170)
                .customizationID("local")
                .defaultVisibility(.hidden)

                TableColumn("PRISE MURALE", sortUsing: table.sort("prise")) { row in
                    let record = row.record
                    textCell(record.annotations.wallJack, mono: true)
                }
                .width(min: 60, ideal: 90)
                .customizationID("prise")
                .defaultVisibility(.hidden)

                TableColumn("RESPONSABLE", sortUsing: table.sort("responsable")) { row in
                    let record = row.record
                    textCell(record.annotations.owner)
                }
                .width(min: 70, ideal: 110)
                .customizationID("responsable")
                .defaultVisibility(.hidden)

                TableColumn("N° D’ACTIF", sortUsing: table.sort("actif")) { row in
                    let record = row.record
                    textCell(record.annotations.assetNumber, mono: true)
                }
                .width(min: 60, ideal: 95)
                .customizationID("actif")
                .defaultVisibility(.hidden)

                TableColumn("ÉTIQUETTES", sortUsing: table.sort("etiquettes")) { row in
                    let record = row.record
                    StandardTagList(tags: record.annotations.tags, colors: { InvStyle.tag($0) },
                                    help: "Étiquettes\u{00A0}: " + record.annotations.tags.joined(separator: ", "))
                }
                .width(min: 70, ideal: 150)
                .customizationID("etiquettes")
                .defaultVisibility(.hidden)

                TableColumn("NOTES", sortUsing: table.sort("notes")) { row in
                    let record = row.record
                    textCell(record.annotations.notes.replacingOccurrences(of: "\n", with: " "))
                }
                .width(min: 80, ideal: 180)
                .customizationID("notes")
                .defaultVisibility(.hidden)

                TableColumn("PREMIÈRE VUE", sortUsing: table.sort("premiereVue")) { row in
                    let record = row.record
                    ScanCellText(InvFormat.day(record.firstSeen), mono: true, secondary: true)
                }
                .width(min: 80, ideal: 120)
                .customizationID("premiereVue")
                .defaultVisibility(.hidden)

                TableColumn("PLAGE", sortUsing: table.sort("plage")) { row in
                    let record = row.record
                    textCell(record.rangeLabel ?? "")
                }
                .width(min: 60, ideal: 100)
                .customizationID("plage")
                .defaultVisibility(.hidden)

                TableColumn("VLAN", sortUsing: table.sort("vlan")) { row in
                    let record = row.record
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
                TableColumn("PORTS OUVERTS", sortUsing: table.sort("ports")) { row in
                    let record = row.record
                    ScanPortTags(ports: record.openPorts)
                }
                .width(min: 70, ideal: 140)
                .customizationID("ports")
                .defaultVisibility(.hidden)

                TableColumn("TYPE DÉTECTÉ", sortUsing: table.sort("typeDetecte")) { row in
                    let record = row.record
                    ScanTypeCell(type: record.detectedType, isManual: false)
                }
                .width(min: 80, ideal: 140)
                .customizationID("typeDetecte")
                .defaultVisibility(.hidden)

                TableColumn("NOM D’HÔTE", sortUsing: table.sort("hostname")) { row in
                    let record = row.record
                    textCell(record.hostname ?? "")
                }
                .width(min: 80, ideal: 150)
                .customizationID("hostname")
                .defaultVisibility(.hidden)

                TableColumn("HISTORIQUE D’IP", sortUsing: table.sort("historiqueIP")) { row in
                    let record = row.record
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
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = rows.filter { ids.contains($0.id) }
            if !chosen.isEmpty { menu(chosen) }
        } primaryAction: { ids in
            guard let row = rows.first(where: { ids.contains($0.id) }) else { return }
            if isActive(row), state.device(withID: row.record.ip.description) != nil { state.showDevice(row.record.ip.description) }
        }
        // Touche Suppr (⌫) et Édition › Supprimer.
        .onDeleteCommand {
            let chosen = rows.filter { selection.contains($0.id) }.map(\.id)
            if !chosen.isEmpty { onDelete(chosen) }
        }
    }

    /// Ligne du site actif : celle dont les appareils sont dans le Scanner (fiche complète, ping).
    private func isActive(_ row: SiteScopedRecord) -> Bool { row.siteKey == model.siteKey }

    // MARK: Cellules

    private func favoriteButton(_ row: SiteScopedRecord) -> some View {
        let record = row.record
        let favorite = record.annotations.isFavorite
        return Button { onFavorite(row) } label: {
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
    private func menu(_ chosen: [SiteScopedRecord]) -> some View {
        if chosen.count == 1, let row = chosen.first {
            let record = row.record
            Button(record.annotations.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") { onFavorite(row) }
            Divider()
            Button("Copier l’IP") { copy(record.ip.description, label: "IP") }
            Button("Copier la MAC") { if let mac = record.mac { copy(mac.formatted(.upperColon), label: "MAC") } }
                .disabled(record.mac == nil)
            Divider()
            Button("Fiche complète") { state.showDevice(record.ip.description) }
                .disabled(!isActive(row) || state.device(withID: record.ip.description) == nil)
            Button("Ping continu") { state.sendToPing(record.ip.description) }
        } else {
            Text("\(chosen.count) appareils sélectionnés")
            Button("Copier les IP") {
                copy(chosen.map(\.record.ip.description).joined(separator: "\n"), label: "Liste d’IP")
            }
        }
        Divider()
        Button(chosen.count > 1 ? "Supprimer ces \(chosen.count) appareils de l’inventaire…" : "Supprimer de l’inventaire…",
               role: .destructive) { onDelete(chosen.map(\.id)) }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.show("\(label) copiée\u{00A0}: \(text)")
    }
}
