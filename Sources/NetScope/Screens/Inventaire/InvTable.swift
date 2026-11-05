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
    var invSortWarranty: Date { annotations.hardware?.warrantyEnd ?? .distantFuture }
    var invSortSerial: String { annotations.hardware?.serialNumber ?? "" }
    var invSortSupplier: String { annotations.hardware?.supplier ?? "" }
    var invSortAttachments: Int { attachmentList.count }
    /// Note 60 : modèle et firmware détectés ; sans valeur, en dernier.
    var invSortModel: String { detectedHardware?.model ?? "\u{10FFFF}" }
    var invSortFirmware: String { detectedHardware?.firmware ?? "\u{10FFFF}" }
    /// Dernière vue ; une fiche ajoutée à la main jamais scannée vient en dernier (aucune vue).
    var invSortLastSeen: Date { isAwaitingScan ? .distantPast : lastSeen }
    var invOrigin: String { isManual ? "À la main" : (isImported ? "Import CSV" : "Scan") }
}

/// Note 10 : actions des lignes de l'Inventaire (menu contextuel, ⌫, panneau de sélection).
struct InvRowActions {
    var favorite: (SiteScopedRecord) -> Void = { _ in }
    /// Retirer (archiver ou supprimer) : confirmation d'abord.
    var delete: ([String]) -> Void = { _ in }
    /// Vue « Archivés » : restaurer, supprimer définitivement.
    var restore: ([String]) -> Void = { _ in }
    var purge: ([String]) -> Void = { _ in }
    /// Déplacer vers un autre site (identifiants, site d'arrivée).
    var move: ([String], String) -> Void = { _, _ in }
    var edit: (SiteScopedRecord) -> Void = { _ in }
    var duplicate: (SiteScopedRecord) -> Void = { _ in }
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
    /// Sites affichés dont l'inventaire est illisible (affichés vides).
    var unreadableNames: [String] = []
    /// Appareils qu'on ne suit plus, dans les sites affichés.
    var excluded: [InvExcludedRow] = []
    var actions = InvRowActions()
    /// Vue « Archivés » (note 10) : date d'archivage de chaque ligne.
    var archiveMode = false
    var archiveDates: [String: Date] = [:]
    /// Menu « Filtrer » actif (étiquettes, garantie, origine…) et de quoi le retirer.
    var filterActive = false
    var clearFilters: () -> Void = {}
    /// MAC vues dans plusieurs sites → noms des sites (signalées, jamais fusionnées).
    var sharedSites: [MACAddress: [String]] = [:]
    /// Accessoire de l'en-tête (menu « Filtrer », ajout automatique désactivé).
    var accessory = AnyView(EmptyView())

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
        StandardColumn(id: "garantie", title: "Fin de garantie", isDefaultVisible: false),
        StandardColumn(id: "serie", title: "N° de série", isDefaultVisible: false),
        StandardColumn(id: "fournisseur", title: "Fournisseur", isDefaultVisible: false),
        StandardColumn(id: "modele", title: "Modèle", isDefaultVisible: false),
        StandardColumn(id: "firmware", title: "Firmware", isDefaultVisible: false),
        StandardColumn(id: "piecesJointes", title: "Pièces jointes", isDefaultVisible: false),
        StandardColumn(id: "origine", title: "Origine", isDefaultVisible: false),
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
        "derniereVue": KeyPathComparator(\SiteScopedRecord.record.invSortLastSeen, order: .reverse),
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
        "garantie": KeyPathComparator(\SiteScopedRecord.record.invSortWarranty),
        "serie": KeyPathComparator(\SiteScopedRecord.record.invSortSerial, comparator: .localizedStandard),
        "fournisseur": KeyPathComparator(\SiteScopedRecord.record.invSortSupplier, comparator: .localizedStandard),
        "modele": KeyPathComparator(\SiteScopedRecord.record.invSortModel, comparator: .localizedStandard),
        "firmware": KeyPathComparator(\SiteScopedRecord.record.invSortFirmware, comparator: .localizedStandard),
        "piecesJointes": KeyPathComparator(\SiteScopedRecord.record.invSortAttachments, order: .reverse),
        "origine": KeyPathComparator(\SiteScopedRecord.record.invOrigin, comparator: .localizedStandard),
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
                Text(archiveMode ? "APPAREILS ARCHIVÉS" : "APPAREILS").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
                Text(archiveMode ? "\(rows.count) affiché\(rows.count > 1 ? "s" : "") · \(total) archivé\(total > 1 ? "s" : "") · restaurables à tout moment"
                     : "\(rows.count) affiché\(rows.count > 1 ? "s" : "") · \(total) appareil\(total > 1 ? "s" : "") connu\(total > 1 ? "s" : "")")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if selection.count > 1 {
                    Text("· \(selection.count) sélectionnés").font(Theme.small).fontWeight(.semibold)
                        .foregroundStyle(Theme.accentStrong).fixedSize()
                }
                Spacer(minLength: 8)
                accessory
                if !excluded.isEmpty, !archiveMode { InvExcludedButton(rows: excluded) }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Rectangle().fill(Theme.border).frame(height: 1)

            if !unreadableNames.isEmpty {
                // Fichier illisible : jamais présenté comme un inventaire vide.
                Label("Inventaire illisible\u{00A0}: " + unreadableNames.joined(separator: ", ")
                      + ". Ses fiches ne sont pas affichées et rien n’y est modifié.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.small).foregroundStyle(Theme.warning)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            if rows.isEmpty, archiveMode, total > 0 {
                VStack(spacing: 8) {
                    Text("Aucun appareil archivé ne correspond à la recherche ou aux filtres.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    if filterActive {
                        Button("Retirer les filtres", action: clearFilters).buttonStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else if rows.isEmpty, archiveMode {
                EmptyState(systemImage: "archivebox", title: "Aucun appareil archivé",
                           message: "Un appareil retiré avec «\u{00A0}Archiver\u{00A0}» garde ici sa fiche, ses notes, sa garantie et son historique\u{00A0}; «\u{00A0}Restaurer\u{00A0}» le remet dans l’inventaire.") {
                    EmptyView()
                }
                .frame(minHeight: 160)
            } else if rows.isEmpty, inventoryEmpty, !siteNames.isEmpty, unreadableNames.count < siteNames.count, SiteModel.shared.activeSite != nil || siteNames.count > 1 {
                // Inventaire propre au site : vide tant que ce site n'a pas été scanné.
                EmptyState(systemImage: "tray",
                           title: siteNames.count > 1 ? "Inventaires de ces \(siteNames.count) sites vides"
                               : "Inventaire de «\u{00A0}\(siteNames[0])\u{00A0}» vide",
                           message: "Lancez un scan de ce site pour le remplir. Les autres sites gardent leur propre inventaire.") {
                    Button("Ouvrir le Scanner") { state.open(.scanner) }
                        .buttonStyle(.secondary)
                }
                .frame(minHeight: 160)
            } else if rows.isEmpty, let navFilter = state.navFilters[.inventaire] {
                // Filtre transmis (groupe de la Carte, port de switch) : le nommer et pouvoir le retirer.
                VStack(spacing: 8) {
                    Text("Aucune fiche du filtre «\u{00A0}\(navFilter.label)\u{00A0}» dans cette vue.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Retirer le filtre") { state.navFilters[.inventaire] = nil }
                        .buttonStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(filterActive ? "Aucun appareil ne correspond à cette vue, à la recherche ou aux filtres (étiquettes, garantie, origine, sites)."
                                      : "Aucun appareil ne correspond à cette vue ou à la recherche.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    if filterActive {
                        Button("Retirer les filtres", action: clearFilters).buttonStyle(.secondary)
                    }
                }
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
                if archiveMode {
                    ViewThatFits(in: .horizontal) {
                        Text("Clic droit\u{00A0}: restaurer ou supprimer définitivement · ⌘-clic\u{00A0}: plusieurs · ⌫\u{00A0}: supprimer définitivement")
                            .fixedSize()
                        Text("Clic droit\u{00A0}: restaurer · ⌫\u{00A0}: supprimer définitivement").fixedSize()
                        Text("Clic droit\u{00A0}: restaurer").fixedSize()
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        Text("Cliquez une ligne pour ouvrir sa fiche · ⌘-clic\u{00A0}: plusieurs · ⌫\u{00A0}: retirer · double-clic\u{00A0}: fiche complète")
                            .fixedSize()
                        Text("⌘-clic\u{00A0}: plusieurs · ⌫\u{00A0}: retirer · double-clic\u{00A0}: fiche complète").fixedSize()
                        Text("⌫\u{00A0}: retirer").fixedSize()
                    }
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
                    // Texte secondaire : la cellule ne fait rien au clic (pas d'allure de lien).
                    Text(row.siteName).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).help("Inventaire du site «\u{00A0}\(row.siteName)\u{00A0}»")
                }
                // Étroite : l'IP, colonne obligatoire, n'est jamais coupée par la colonne des sites.
                .width(min: 60, ideal: 76)
                .customizationID("site")
                .defaultVisibility(.hidden)

                TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                    nameCell(row)
                }
                .width(min: 110, ideal: 175)
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
                    Text(record.addressLabel).font(Theme.mono(12, weight: .semibold))
                        .foregroundStyle(record.hasAddress ? Theme.text : Theme.textTertiary).lineLimit(1)
                        .help(record.hasAddress ? record.ip.description : "Ajouté à la main sans adresse IP")
                }
                // Largeur d'une adresse complète (255.255.255.255) : jamais tronquée.
                .width(min: 116, ideal: 116)
                .customizationID("ip")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("MAC", sortUsing: table.sort("mac")) { row in
                    let record = row.record
                    ScanCellText(record.mac?.formatted(.upperColon) ?? "—", mono: true, dimmed: record.mac == nil)
                }
                // Une MAC entière (17 caractères à chasse fixe) tient sans être coupée.
                .width(min: 134, ideal: 136)
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
                .width(min: 90, ideal: 142)
                .customizationID("switch")

                TableColumn("DERNIÈRE VUE", sortUsing: table.sort("derniereVue")) { row in
                    let record = row.record
                    if record.isAwaitingScan {
                        ScanCellText("—", dimmed: true)
                            .help("Jamais vu par un scan")
                    } else {
                        ScanCellText(InvFormat.relative(record.lastSeen, now: now), secondary: true)
                            .help(InvFormat.stamp(record.lastSeen))
                    }
                }
                .width(min: 80, ideal: 120)
                .customizationID("derniereVue")

                TableColumn("STATUT", sortUsing: table.sort("statut")) { row in
                    statusCell(row)
                }
                .width(min: 70, ideal: 86)
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

                TableColumn("FIN DE GARANTIE", sortUsing: table.sort("garantie")) { row in
                    warrantyCell(row.record)
                }
                .width(min: 90, ideal: 150)
                .customizationID("garantie")
                .defaultVisibility(.hidden)

                TableColumn("N° DE SÉRIE", sortUsing: table.sort("serie")) { row in
                    textCell(row.record.annotations.hardware?.serialNumber ?? "", mono: true)
                }
                .width(min: 70, ideal: 110)
                .customizationID("serie")
                .defaultVisibility(.hidden)

                TableColumn("FOURNISSEUR", sortUsing: table.sort("fournisseur")) { row in
                    textCell(row.record.annotations.hardware?.supplier ?? "")
                }
                .width(min: 70, ideal: 130)
                .customizationID("fournisseur")
                .defaultVisibility(.hidden)
            }

            Group {
                // Note 60 : lus par SNMP ou par la FortiGate (infobulle : source et date).
                TableColumn("MODÈLE", sortUsing: table.sort("modele")) { row in
                    detectedCell(row.record, row.record.detectedModelLabel)
                }
                .width(min: 80, ideal: 150)
                .customizationID("modele")
                .defaultVisibility(.hidden)

                TableColumn("FIRMWARE", sortUsing: table.sort("firmware")) { row in
                    detectedCell(row.record, row.record.detectedFirmwareLabel)
                }
                .width(min: 70, ideal: 120)
                .customizationID("firmware")
                .defaultVisibility(.hidden)

                TableColumn("PIÈCES JOINTES", sortUsing: table.sort("piecesJointes")) { row in
                    let count = row.record.attachmentList.count
                    Label("\(count)", systemImage: "paperclip")
                        .font(Theme.small)
                        .foregroundStyle(count > 0 ? Theme.text : Theme.textTertiary)
                        .help(row.record.attachmentList.map(\.fileName).joined(separator: ", "))
                }
                .width(min: 50, ideal: 70)
                .customizationID("piecesJointes")
                .defaultVisibility(.hidden)

                TableColumn("ORIGINE", sortUsing: table.sort("origine")) { row in
                    textCell(row.record.invOrigin)
                }
                .width(min: 60, ideal: 90)
                .customizationID("origine")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        // Note 34 : double-clic ou ↩︎ → fiche Appareil (site actif, appareil du dernier scan) ;
        // clic droit → « Ouvrir dans › » les autres modules.
        .standardRowActions(selection: rows.map(\.id).filter(selection.contains), object: { id in
            rows.first { $0.id == id }.map { .device(NavDeviceRef($0.record, siteKey: $0.siteKey)) }
        }, primary: { ids in
            // Ligne d'un autre site, ou appareil absent du dernier scan : sa fiche est déjà ci-dessous.
            guard let row = rows.first(where: { ids.contains($0.id) }) else { return true }
            return !(isActive(row) && state.device(withID: row.record.ip.description) != nil)
        }) { ids in
            let chosen = rows.filter { ids.contains($0.id) }
            if !chosen.isEmpty { menu(chosen) }
        }
        // Touche Suppr (⌫) et Édition › Supprimer : retirer (archives : supprimer définitivement).
        .onDeleteCommand {
            let chosen = rows.filter { selection.contains($0.id) }.map(\.id)
            guard !chosen.isEmpty else { return }
            if archiveMode { actions.purge(chosen) } else { actions.delete(chosen) }
        }
        // Note 45 : au retour, la ligne choisie est ramenée en vue (même position dans la liste).
        .revealRow(id: rows.first { selection.contains($0.id) }?.id) { rows.firstIndex { selection.contains($0.id) } }
    }

    /// Ligne du site actif : celle dont les appareils sont dans le Scanner (fiche complète, ping).
    private func isActive(_ row: SiteScopedRecord) -> Bool { row.siteKey == model.siteKey }

    // MARK: Cellules

    @ViewBuilder
    private func statusCell(_ row: SiteScopedRecord) -> some View {
        let record = row.record
        if archiveMode {
            let date = archiveDates[row.id]
            InvPill(text: "Archivé", foreground: Theme.textSecondary, background: Theme.neutralSoft)
                .help(date.map { "Archivé le \(InvFormat.stamp($0))" } ?? "Archivé")
        } else if record.isAwaitingScan {
            // Libellé court dans le tableau ; « Jamais scanné » dans l'infobulle et la fiche.
            InvPill(text: "Non scanné", foreground: Theme.textSecondary, background: Theme.neutralSoft)
                .help("Jamais scanné. Ajouté à la main\u{00A0}: rapproché dès qu’un scan de ce site le verra (même MAC, sinon même IP)")
        } else {
            let status = record.status(now: now)
            let colors = InvStyle.status(status)
            InvPill(text: status.label, foreground: colors.0, background: colors.1)
        }
    }

    @ViewBuilder
    private func warrantyCell(_ record: InvRecord) -> some View {
        if let hardware = record.annotations.hardware, let end = hardware.warrantyEnd {
            let state = hardware.warranty(now: now)
            HStack(spacing: 6) {
                Text(InvFormat.day(end)).font(Theme.mono(11.5)).foregroundStyle(Theme.neutralText).lineLimit(1)
                if state.isAlert || { if case .expired = state { return true } else { return false } }() {
                    InvWarrantyPill(state: state, short: true)
                }
            }
            .help(state.label)
        } else {
            ScanCellText("—", dimmed: true)
        }
    }

    private func favoriteButton(_ row: SiteScopedRecord) -> some View {
        let record = row.record
        let favorite = record.annotations.isFavorite
        return Button { actions.favorite(row) } label: {
            Image(systemName: favorite ? "star.fill" : "star")
                .font(.system(size: 12))
                .foregroundStyle(favorite ? Theme.warning : Theme.textTertiary)
                .frame(maxWidth: .infinity, minHeight: Self.cellHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(archiveMode)
        .help(favorite ? "Retirer \(record.displayName) des favoris" : "Ajouter \(record.displayName) aux favoris")
    }

    private func nameCell(_ row: SiteScopedRecord) -> some View {
        let record = row.record
        let others = record.mac.flatMap { sharedSites[$0] }?.filter { $0 != row.siteName } ?? []
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(record.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    .layoutPriority(1)
                if record.isUnidentified {
                    InvPill(text: "NON IDENTIFIÉ", foreground: Theme.warning, background: Theme.warningSoft, size: 9.5)
                }
                if record.isManual {
                    InvPill(text: "À LA MAIN", foreground: Theme.accentStrong, background: InvStyle.infoSoft, size: 9.5)
                        .help(record.isAwaitingScan ? "Ajouté à la main, pas encore vu par un scan" : "Ajouté à la main, rapproché d’un appareil scanné")
                }
                if !others.isEmpty {
                    InvPill(text: "\(others.count + 1) SITES", foreground: Theme.warning, background: Theme.warningSoft, size: 9.5)
                        .help("Même MAC aussi dans l’inventaire de «\u{00A0}\(others.joined(separator: "\u{00A0}», «\u{00A0}"))\u{00A0}»\u{00A0}: fiches distinctes, jamais fusionnées")
                }
            }
            if let host = record.hostname, host != record.displayName {
                Text(host).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .frame(height: Self.cellHeight)
        .help(record.hostname.map { "\(record.displayName) · \($0)" } ?? record.displayName)
    }

    private func detectedCell(_ record: InvRecord, _ text: String) -> some View {
        ScanCellText(text.isEmpty ? "—" : text, mono: true, dimmed: text.isEmpty)
            .help(record.detectedHardware.map { hardware in
                let when = "par \(hardware.sourceLabel) le \(InvFormat.stamp(hardware.readAt))"
                return text.isEmpty ? "Non lu · fiche matériel lue \(when)" : "\(text) · lu \(when)"
            } ?? "Rien de lu")
    }

    private func textCell(_ text: String, mono: Bool = false) -> some View {
        ScanCellText(text.isEmpty ? "—" : text, mono: mono, dimmed: text.isEmpty)
            .help(text)
    }

    @ViewBuilder
    private func menu(_ chosen: [SiteScopedRecord]) -> some View {
        if archiveMode {
            archiveMenu(chosen)
        } else {
            recordMenu(chosen)
        }
    }

    /// Vue « Archivés » : restaurer ou supprimer définitivement.
    @ViewBuilder
    private func archiveMenu(_ chosen: [SiteScopedRecord]) -> some View {
        if chosen.count > 1 { Text("\(chosen.count) appareils archivés sélectionnés") }
        Button(chosen.count > 1 ? "Restaurer ces \(chosen.count) appareils" : "Restaurer dans l’inventaire") { actions.restore(chosen.map(\.id)) }
        Divider()
        if chosen.count == 1, let record = chosen.first?.record {
            Button("Copier l’IP") { copy(record.ip.description, label: "IP") }.disabled(!record.hasAddress)
            Button("Copier la MAC") { if let mac = record.mac { copy(mac.formatted(.upperColon), label: "MAC") } }
                .disabled(record.mac == nil)
            Divider()
        }
        Button(chosen.count > 1 ? "Supprimer définitivement ces \(chosen.count) appareils…" : "Supprimer définitivement…",
               role: .destructive) { actions.purge(chosen.map(\.id)) }
    }

    @ViewBuilder
    private func recordMenu(_ chosen: [SiteScopedRecord]) -> some View {
        if chosen.count == 1, let row = chosen.first {
            let record = row.record
            Button(record.annotations.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") { actions.favorite(row) }
            Divider()
            Button("Copier l’IP") { copy(record.ip.description, label: "IP") }
                .disabled(!record.hasAddress)
            Button("Copier la MAC") { if let mac = record.mac { copy(mac.formatted(.upperColon), label: "MAC") } }
                .disabled(record.mac == nil)
            Divider()
            if record.isManual {
                Button("Modifier l’appareil…") { actions.edit(row) }
            }
            Button("Dupliquer") { actions.duplicate(row) }
            Divider()
            Button("Fiche complète") { state.showDevice(record.ip.description) }
                .disabled(!isActive(row) || !record.hasAddress || state.device(withID: record.ip.description) == nil)
            // Autre site : la même IP sur le réseau du site actif serait un autre appareil.
            Button("Ping continu") { state.sendToPing(record.ip.description) }
                .disabled(!isActive(row) || !record.hasAddress)
            // Note 52 : utilisateur demandé (ou retenu pour cet appareil) avant ssh user@ip.
            Button("Se connecter en SSH…") {
                QuickLoginModel.shared.ask(QuickLoginTarget(name: record.displayName,
                                                            device: QuickLoginDevice(host: record.ip.description, mac: record.mac?.formatted(.upperColon),
                                                                                     siteID: SiteModel.shared.list.activeID)))
            }
            .disabled(!isActive(row) || !record.hasAddress)
            // Note 50 : ports du dernier relevé de cet appareil ; autre site : grisé (autre réseau).
            FileTransferOpenMenu(host: record.ip.description, name: record.displayName,
                                 openPorts: isActive(row) ? record.openPorts : [],
                                 deviceID: state.device(withID: record.ip.description)?.id)
                .disabled(!isActive(row) || !record.hasAddress)
        } else {
            Text("\(chosen.count) appareils sélectionnés")
            Button("Copier les IP") {
                copy(chosen.map(\.record).filter(\.hasAddress).map(\.ip.description).joined(separator: "\n"), label: "Liste d’IP")
            }
        }
        Divider()
        InvMoveMenu(rows: chosen) { site in actions.move(chosen.map(\.id), site) }
        Divider()
        Button(chosen.count > 1 ? "Retirer ces \(chosen.count) appareils de l’inventaire…" : "Retirer de l’inventaire…",
               role: .destructive) { actions.delete(chosen.map(\.id)) }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.show("\(label) copiée\u{00A0}: \(text)")
    }
}
