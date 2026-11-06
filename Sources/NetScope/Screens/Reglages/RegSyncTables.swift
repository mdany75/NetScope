import NetScopeCore
import SwiftUI

// Note 86 : tableaux standard de Réglages › Synchronisation (« reglages.synchro.mac »,
// « reglages.synchro.categories », « reglages.synchro.recus »).

/// Hauteur des tableaux de la synchronisation : en-tête, lignes et place de la barre de défilement
/// horizontale (petite fenêtre : les colonnes défilent au lieu d’être coupées).
enum RegSyncTableMetrics {
    static func height(rows: Int) -> CGFloat { 36 + 26 * CGFloat(max(rows, 1)) + 18 }
}

// MARK: - Mac vus

struct RegSyncDeviceRow: Identifiable {
    let id: String
    let name: String
    let model: String
    let version: String
    let lastSync: Date
    let isThisMac: Bool
    let isOlder: Bool

    var stateSort: Int { isThisMac ? 0 : (isOlder ? 2 : 1) }
}

/// Ce Mac et les autres Mac vus dans le dossier de synchronisation.
struct RegSyncDeviceTable: View {
    @ObservedObject private var sync = RegSyncController.shared
    @StateObject private var table = StandardTableModel<RegSyncDeviceRow>(id: "reglages.synchro.mac", columns: Self.columns,
                                                                          sortKeys: Self.sortKeys, defaultSort: "synchro", defaultAscending: false)

    static let columns: [StandardColumn] = [
        StandardColumn(id: "mac", title: "Mac", isRequired: true),
        StandardColumn(id: "modele", title: "Modèle"),
        StandardColumn(id: "version", title: "Version de NetScope"),
        StandardColumn(id: "synchro", title: "Dernière synchro"),
        StandardColumn(id: "etat", title: "État"),
    ]

    static let sortKeys: [String: KeyPathComparator<RegSyncDeviceRow>] = [
        "mac": KeyPathComparator(\RegSyncDeviceRow.name),
        "modele": KeyPathComparator(\RegSyncDeviceRow.model),
        "version": KeyPathComparator(\RegSyncDeviceRow.version),
        "synchro": KeyPathComparator(\RegSyncDeviceRow.lastSync),
        "etat": KeyPathComparator(\RegSyncDeviceRow.stateSort),
    ]

    private var rows: [RegSyncDeviceRow] {
        let older = Set(sync.olderDevices.map(\.id))
        var list = sync.devices.map { device in
            RegSyncDeviceRow(id: device.id, name: device.name, model: device.model.isEmpty ? "—" : device.model,
                             version: device.versionLabel, lastSync: device.lastSync, isThisMac: device.id == sync.deviceID,
                             isOlder: older.contains(device.id))
        }
        if !list.contains(where: \.isThisMac) {
            list.insert(RegSyncDeviceRow(id: sync.deviceID, name: sync.deviceName, model: sync.deviceModel, version: sync.appVersion,
                                         lastSync: sync.lastSync ?? sync.now, isThisMac: true, isOlder: false), at: 0)
        }
        return list.sorted(using: table.sortOrder)
    }

    var body: some View {
        let rows = rows
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("MAC", sortUsing: table.sort("mac")) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.isThisMac ? "laptopcomputer" : "desktopcomputer")
                        .font(.system(size: 11)).foregroundStyle(row.isThisMac ? Theme.accent : Theme.textSecondary)
                    Text(row.name).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                }
            }
            .width(min: 120, ideal: 190)
            .customizationID("mac").disabledCustomizationBehavior(.visibility)
            TableColumn("MODÈLE", sortUsing: table.sort("modele")) { row in
                Text(row.model).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 70, ideal: 170)
            .customizationID("modele")
            TableColumn("VERSION", sortUsing: table.sort("version")) { row in
                Text(row.version).font(Theme.mono(11)).foregroundStyle(row.isOlder ? Theme.warning : Theme.text).lineLimit(1)
            }
            .width(min: 56, ideal: 130)
            .customizationID("version")
            TableColumn("DERNIÈRE SYNCHRO", sortUsing: table.sort("synchro")) { row in
                Text(row.isThisMac && sync.lastSync == nil ? "Jamais" : RegSyncFormat.ago(row.lastSync, now: sync.now))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 70, ideal: 120)
            .customizationID("synchro")
            TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                if row.isThisMac {
                    RegPill(text: "Ce Mac", tone: .accent)
                } else if row.isOlder {
                    RegPill(text: "Version plus ancienne", tone: .warning)
                        .help("Ses changements sont fusionnés sans effacer ce que sa version ne connaît pas. Mettez-le à jour.")
                } else {
                    RegPill(text: "À jour", tone: .success)
                }
            }
            .width(min: 80, ideal: 150)
            .customizationID("etat")
        }
        .standardTableStyle()
        .frame(height: RegSyncTableMetrics.height(rows: rows.count))
        .regTableFrame()
    }
}

// MARK: - Catégories

struct RegSyncCategoryRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let summary: String
    let total: Int
    let isOn: Bool
}

/// Catégories synchronisées (les parties de l'export), avec case à cocher et compteurs.
struct RegSyncCategoryTable: View {
    @ObservedObject private var sync = RegSyncController.shared
    @StateObject private var table = StandardTableModel<RegSyncCategoryRow>(id: "reglages.synchro.categories", columns: Self.columns,
                                                                            sortKeys: Self.sortKeys, defaultSort: "ordre")

    static let columns: [StandardColumn] = [
        StandardColumn(id: "categorie", title: "Catégorie", isRequired: true),
        StandardColumn(id: "contenu", title: "Sur ce Mac"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "detail", title: "Contenu", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RegSyncCategoryRow>] = [
        "ordre": KeyPathComparator(\RegSyncCategoryRow.order),
        "categorie": KeyPathComparator(\RegSyncCategoryRow.title),
        "contenu": KeyPathComparator(\RegSyncCategoryRow.total),
        "etat": KeyPathComparator(\RegSyncCategoryRow.stateSort),
        "detail": KeyPathComparator(\RegSyncCategoryRow.detail),
    ]

    private var rows: [RegSyncCategoryRow] {
        let counts = Dictionary(uniqueKeysWithValues: sync.counts.map { ($0.id, $0) })
        return ConfigPartRegistry.standard.parts.map { part in
            let count = counts[part.id]
            let total = count.map { $0.files + $0.elements + $0.preferences + $0.secrets + $0.siteItems } ?? 0
            return RegSyncCategoryRow(id: part.id, title: part.title, detail: part.detail, systemImage: part.systemImage,
                                      summary: count?.summary ?? "—", total: total, isOn: sync.isCategoryOn(part.id))
        }
        .sorted(using: table.sortOrder)
    }

    var body: some View {
        let rows = rows
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("CATÉGORIE", sortUsing: table.sort("categorie")) { row in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { row.isOn }, set: { sync.setCategory(row.id, $0) }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Image(systemName: row.systemImage).font(.system(size: 11)).foregroundStyle(row.isOn ? Theme.accent : Theme.textTertiary)
                        .frame(width: 16)
                    Text(row.title).font(Theme.bodySemibold).foregroundStyle(row.isOn ? Theme.text : Theme.textSecondary).lineLimit(1)
                }
                .help(row.detail)
            }
            .width(min: 180, ideal: 270)
            .customizationID("categorie").disabledCustomizationBehavior(.visibility)
            TableColumn("SUR CE MAC", sortUsing: table.sort("contenu")) { row in
                Text(row.summary).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                    .help(row.summary)
            }
            .width(min: 90, ideal: 260)
            .customizationID("contenu")
            TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                if row.isOn {
                    RegPill(text: "Synchronisée", tone: .success)
                } else {
                    RegPill(text: "Sur ce Mac seulement", tone: .neutral)
                }
            }
            .width(min: 80, ideal: 150)
            .customizationID("etat")
            TableColumn("CONTENU", sortUsing: table.sort("detail")) { row in
                Text(row.detail).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                    .help(row.detail)
            }
            .width(min: 140, ideal: 320)
            .customizationID("detail")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .frame(height: RegSyncTableMetrics.height(rows: rows.count))
        .regTableFrame()
    }
}

extension RegSyncCategoryRow {
    /// Ordre du registre (l'ordre de l'export).
    var order: Int { ConfigPartRegistry.standard.ids.firstIndex(of: id) ?? .max }
    var stateSort: Int { isOn ? 0 : 1 }
}

// MARK: - Changements reçus

struct RegSyncChangeRow: Identifiable {
    let id: UUID
    let date: Date
    let label: String
    let category: String
    let scope: String
    let device: String
}

/// Changements reçus récents (les plus récents d'abord).
struct RegSyncChangeTable: View {
    @ObservedObject private var sync = RegSyncController.shared
    @StateObject private var table = StandardTableModel<RegSyncChangeRow>(id: "reglages.synchro.recus", columns: Self.columns,
                                                                          sortKeys: Self.sortKeys, defaultSort: "quand", defaultAscending: false)
    /// Lignes montrées au plus (le reste se lit en triant autrement).
    static let maxRows = 8

    static let columns: [StandardColumn] = [
        StandardColumn(id: "quand", title: "Quand", isRequired: true),
        StandardColumn(id: "element", title: "Élément"),
        StandardColumn(id: "categorie", title: "Catégorie"),
        StandardColumn(id: "portee", title: "Site ou partie"),
        StandardColumn(id: "de", title: "De"),
    ]

    static let sortKeys: [String: KeyPathComparator<RegSyncChangeRow>] = [
        "quand": KeyPathComparator(\RegSyncChangeRow.date),
        "element": KeyPathComparator(\RegSyncChangeRow.label),
        "categorie": KeyPathComparator(\RegSyncChangeRow.category),
        "portee": KeyPathComparator(\RegSyncChangeRow.scope),
        "de": KeyPathComparator(\RegSyncChangeRow.device),
    ]

    private var rows: [RegSyncChangeRow] {
        let registry = ConfigPartRegistry.standard
        return sync.recent.map { change in
            RegSyncChangeRow(id: change.id, date: change.date, label: change.label,
                             category: registry.part(change.category)?.title ?? change.category, scope: change.scopeName, device: change.device)
        }
        .sorted(using: table.sortOrder)
    }

    var body: some View {
        let rows = rows
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("QUAND", sortUsing: table.sort("quand")) { row in
                Text(RegSyncFormat.ago(row.date, now: sync.now)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 66, ideal: 100)
            .customizationID("quand").disabledCustomizationBehavior(.visibility)
            TableColumn("ÉLÉMENT", sortUsing: table.sort("element")) { row in
                Text(row.label).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail).help(row.label)
            }
            .width(min: 110, ideal: 240)
            .customizationID("element")
            TableColumn("CATÉGORIE", sortUsing: table.sort("categorie")) { row in
                Text(row.category).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 76, ideal: 170)
            .customizationID("categorie")
            TableColumn("SITE OU PARTIE", sortUsing: table.sort("portee")) { row in
                Text(row.scope).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 90, ideal: 170)
            .customizationID("portee")
            .defaultVisibility(.hidden)
            TableColumn("DE", sortUsing: table.sort("de")) { row in
                Text(row.device).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 76, ideal: 150)
            .customizationID("de")
        }
        .standardTableStyle()
        .frame(height: RegSyncTableMetrics.height(rows: min(rows.count, Self.maxRows)))
        .regTableFrame()
    }
}
