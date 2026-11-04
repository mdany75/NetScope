import AppKit
import NetScopeCore
import SwiftUI

// MARK: - Switchs connus et écartés (tableaux standard « reglages.switchs » et
// « reglages.switchsIgnores », note 8)

/// Hauteurs communes des deux tableaux : ils sont dans la page défilante des Réglages et prennent
/// la hauteur de leurs lignes.
enum RegSwitchTableMetrics {
    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 42

    static func height(rows: Int) -> CGFloat {
        headerHeight + rowHeight * CGFloat(rows) + 16
    }
}

extension View {
    /// Cadre arrondi des tableaux des Réglages (comme les autres encadrés de la page).
    func regTableFrame() -> some View {
        clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Ligne du tableau des switchs connus.
struct RegSwitchRowData: Identifiable {
    let host: String
    let ip: IPv4Address
    let name: String
    let model: String
    let polledAt: Date?
    let failed: Bool
    let snmp: String
    let isAuto: Bool
    let location: String
    let firmware: String
    let ports: String

    var id: String { host }
    var sortPolled: Date { failed ? .distantPast : (polledAt ?? .distantPast) }
    var origin: String { isAuto ? "Découverte" : "À la main" }
}

/// Switchs connus de `SwitchStore` : hôte, nom, modèle, dernier relevé, SNMP, origine.
struct RegKnownSwitchTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SwitchStore.shared
    @ObservedObject var table: StandardTableModel<RegSwitchRowData>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "hote", title: "Hôte", isRequired: true),
        StandardColumn(id: "nom", title: "Nom"),
        StandardColumn(id: "modele", title: "Modèle"),
        StandardColumn(id: "releve", title: "Dernier relevé"),
        StandardColumn(id: "snmp", title: "SNMP (version, communauté)"),
        StandardColumn(id: "origine", title: "Origine"),
        StandardColumn(id: "emplacement", title: "Emplacement (sysLocation)", isDefaultVisible: false),
        StandardColumn(id: "logiciel", title: "Logiciel", isDefaultVisible: false),
        StandardColumn(id: "ports", title: "Ports", isDefaultVisible: false),
    ]

    /// Tri par défaut : l’adresse (ordre numérique des IP).
    static let sortKeys: [String: KeyPathComparator<RegSwitchRowData>] = [
        "hote": KeyPathComparator(\RegSwitchRowData.ip),
        "nom": KeyPathComparator(\RegSwitchRowData.name),
        "modele": KeyPathComparator(\RegSwitchRowData.model),
        "releve": KeyPathComparator(\RegSwitchRowData.sortPolled),
        "snmp": KeyPathComparator(\RegSwitchRowData.snmp),
        "origine": KeyPathComparator(\RegSwitchRowData.origin),
        "emplacement": KeyPathComparator(\RegSwitchRowData.location),
        "logiciel": KeyPathComparator(\RegSwitchRowData.firmware),
        "ports": KeyPathComparator(\RegSwitchRowData.ports),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RegSwitchRowData> {
        StandardTableModel(id: "reglages.switchs", columns: columns, sortKeys: sortKeys, defaultSort: "hote")
    }

    /// Lignes affichées, triées.
    @MainActor
    static func rows(store: SwitchStore, sortOrder: [KeyPathComparator<RegSwitchRowData>]) -> [RegSwitchRowData] {
        store.hosts.map { host in
            let snapshot = store.snapshots[host]
            let community = store.community(for: host)
            let snmp: String
            if community.isEmpty {
                snmp = "v2c"
            } else if community != store.community {
                snmp = "v2c · propre au switch"
            } else {
                snmp = "v2c · commune"
            }
            return RegSwitchRowData(
                host: host,
                ip: IPv4Address(host) ?? IPv4Address(0),
                name: snapshot?.displayName ?? "",
                model: snapshot.map(SwitchText.model) ?? "",
                polledAt: snapshot?.polledAt,
                failed: store.errors[host] != nil,
                snmp: snmp,
                isAuto: store.isAutoDiscovered(host),
                location: snapshot?.system.location ?? "",
                firmware: snapshot.map { SwitchText.firmware($0.system.descr) } ?? "",
                ports: snapshot.map(SwitchText.portsSummary) ?? "")
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        let rows = Self.rows(store: store, sortOrder: table.sortOrder)
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("HÔTE", sortUsing: table.sort("hote")) { row in
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.connected.to.line.below")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Text(row.host).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                }
                .frame(height: RegSwitchTableMetrics.rowHeight - 8)
            }
            .width(min: 110, ideal: 120)
            .customizationID("hote")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                RegSwitchCell(row.name, mono: true)
            }
            .width(min: 80, ideal: 100)
            .customizationID("nom")

            TableColumn("MODÈLE", sortUsing: table.sort("modele")) { row in
                RegSwitchCell(row.model, secondary: true)
                    .help(row.model)
            }
            .width(min: 100, ideal: 140)
            .customizationID("modele")

            TableColumn("DERNIER RELEVÉ", sortUsing: table.sort("releve")) { row in
                if row.failed {
                    Chip(text: "Sans réponse", tone: .critical)
                } else if let date = row.polledAt {
                    HStack(spacing: 6) {
                        Chip(text: "Relevé", tone: .success)
                        Text(SwitchText.ago(date)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    .help("Relevé le \(SwitchText.dateTime(date))")
                } else {
                    RegSwitchCell("")
                }
            }
            .width(min: 90, ideal: 135)
            .customizationID("releve")

            TableColumn("SNMP", sortUsing: table.sort("snmp")) { row in
                RegSwitchCell(row.snmp, secondary: true)
                    .help("SNMP v2c en lecture seule. « Propre au switch » : la communauté qui a répondu est retenue au Trousseau ; « commune » : celle des Identifiants. La communauté n’est jamais affichée.")
            }
            .width(min: 80, ideal: 120)
            .customizationID("snmp")

            TableColumn("ORIGINE", sortUsing: table.sort("origine")) { row in
                Chip(text: row.origin, tone: row.isAuto ? .accent : .neutral)
                    .help(row.isAuto ? "Ajouté par la découverte automatique (SNMP)" : "Ajouté à la main dans « Switchs et ports »")
            }
            .width(min: 80, ideal: 100)
            .customizationID("origine")

            TableColumn("EMPLACEMENT (SYSLOCATION)", sortUsing: table.sort("emplacement")) { row in
                RegSwitchCell(row.location, secondary: true)
            }
            .width(min: 90, ideal: 150)
            .customizationID("emplacement")
            .defaultVisibility(.hidden)

            TableColumn("LOGICIEL", sortUsing: table.sort("logiciel")) { row in
                RegSwitchCell(row.firmware == "—" ? "" : row.firmware, mono: true)
            }
            .width(min: 70, ideal: 110)
            .customizationID("logiciel")
            .defaultVisibility(.hidden)

            TableColumn("PORTS", sortUsing: table.sort("ports")) { row in
                RegSwitchCell(row.ports, secondary: true)
            }
            .width(min: 70, ideal: 130)
            .customizationID("ports")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: RegSwitchRowData.ID.self) { hosts in
            if let host = hosts.first {
                Button("Ouvrir dans « Switchs et ports »") {
                    store.select(host: host)
                    state.open(.switchs)
                }
                Button("Copier l’adresse") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(host, forType: .string)
                }
                Divider()
                Button("Écarter ce switch (ne plus l’interroger)", role: .destructive) { store.removeHost(host) }
            }
        } primaryAction: { hosts in
            if let host = hosts.first {
                store.select(host: host)
                state.open(.switchs)
            }
        }
        .frame(height: RegSwitchTableMetrics.height(rows: rows.count))
    }
}

/// Ligne du tableau des switchs écartés.
struct RegIgnoredSwitchRowData: Identifiable {
    let host: String
    let ip: IPv4Address
    /// Nom connu par le scan (nom personnalisé ou hostname), sinon vide.
    let name: String
    let vendor: String

    var id: String { host }
}

/// Switchs écartés : jamais interrogés par la découverte automatique, « Ne plus ignorer ».
struct RegIgnoredSwitchTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SwitchStore.shared
    @ObservedObject var table: StandardTableModel<RegIgnoredSwitchRowData>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "hote", title: "Hôte", isRequired: true),
        StandardColumn(id: "nom", title: "Nom (scan)"),
        StandardColumn(id: "fabricant", title: "Fabricant", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RegIgnoredSwitchRowData>] = [
        "hote": KeyPathComparator(\RegIgnoredSwitchRowData.ip),
        "nom": KeyPathComparator(\RegIgnoredSwitchRowData.name),
        "fabricant": KeyPathComparator(\RegIgnoredSwitchRowData.vendor),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RegIgnoredSwitchRowData> {
        StandardTableModel(id: "reglages.switchsIgnores", columns: columns, sortKeys: sortKeys, defaultSort: "hote")
    }

    private var rows: [RegIgnoredSwitchRowData] {
        store.ignoredHosts.map { host in
            let device = state.device(withID: host)
            return RegIgnoredSwitchRowData(host: host, ip: IPv4Address(host) ?? IPv4Address(0),
                                           name: device?.customName ?? device?.hostname ?? "",
                                           vendor: device?.vendor ?? "")
        }
        .sorted(using: table.sortOrder)
    }

    var body: some View {
        let rows = rows
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("HÔTE", sortUsing: table.sort("hote")) { row in
                HStack(spacing: 8) {
                    Image(systemName: "nosign").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Text(row.host).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                }
                .frame(height: RegSwitchTableMetrics.rowHeight - 8)
            }
            .width(min: 110, ideal: 140)
            .customizationID("hote")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("NOM (SCAN)", sortUsing: table.sort("nom")) { row in
                RegSwitchCell(row.name, secondary: true)
            }
            .width(min: 80, ideal: 220)
            .customizationID("nom")

            TableColumn("FABRICANT", sortUsing: table.sort("fabricant")) { row in
                RegSwitchCell(row.vendor, secondary: true)
            }
            .width(min: 80, ideal: 150)
            .customizationID("fabricant")
            .defaultVisibility(.hidden)

            TableColumn("") { row in
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        store.unignore(row.host)
                    } label: {
                        Label("Ne plus ignorer", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accentStrong)
                    }
                    .buttonStyle(.plain)
                    .help("La découverte automatique interrogera de nouveau \(row.host)")
                }
            }
            .width(min: 130, ideal: 140)
            .customizationID("actions")
            .disabledCustomizationBehavior(.all)
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: RegIgnoredSwitchRowData.ID.self) { hosts in
            if let host = hosts.first {
                Button("Ne plus ignorer \(host)") { store.unignore(host) }
            }
        }
        .frame(height: RegSwitchTableMetrics.height(rows: rows.count))
    }
}

/// Texte d'une cellule ; « — » grisé quand il est vide.
private struct RegSwitchCell: View {
    let text: String
    var mono = false
    var secondary = false

    init(_ text: String, mono: Bool = false, secondary: Bool = false) {
        self.text = text
        self.mono = mono
        self.secondary = secondary
    }

    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .font(mono ? Theme.mono(12) : Theme.small)
            .foregroundStyle(text.isEmpty ? Theme.textTertiary : (secondary ? Theme.textSecondary : Theme.text))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
