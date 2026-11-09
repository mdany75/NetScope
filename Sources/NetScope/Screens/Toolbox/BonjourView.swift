import NetScopeCore
import SwiftUI

/// Navigateur Bonjour (note 118) : services annoncés sur le réseau local, par appareil ou par type.
/// Aucun lien vers une fiche Inventaire : Bonjour ne donne pas la MAC, et une IP seule ne prouve
/// pas l'identité d'un appareil.
struct BonjourView: View {
    @ObservedObject var model: BonjourModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = BonjourTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            form
            if model.isDenied {
                ToolNotice(tone: .warning, title: "Autorisation Réseau local manquante",
                           message: "macOS empêche NetScope de fureter le réseau local. Dans Réglages Système, ouvrir Confidentialité et sécurité, puis Réseau local, activer NetScope et relancer la découverte.")
            }
            if model.isRunning {
                MailProgressLine(text: "Découverte\u{00A0}: \(model.elapsed)\u{00A0}s sur \(BonjourModel.duration)\u{00A0}s, \(serviceCount(model.services.count)) pour l’instant…",
                                 fraction: Double(model.elapsed) / Double(BonjourModel.duration))
            }
            if !model.services.isEmpty {
                results
            } else if !model.isRunning, !model.isDenied {
                emptyState
            }
        }
    }

    private var form: some View {
        ToolAdaptiveRow(spacing: 12) {
            ToolLabeledField(label: "Filtrer les services") {
                ToolTextField(placeholder: "imprimante, _ipp, 10.0.0.5, clé TXT", text: $model.filter, mono: false)
                    .frame(minWidth: 240, idealWidth: 320, maxWidth: .infinity)
            }
            ToolLabeledField(label: "Regrouper par") {
                HStack(spacing: 10) {
                    Picker("Regrouper par", selection: $model.grouping) {
                        ForEach(BonjourGrouping.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    runButton
                }
            }
        }
    }

    @ViewBuilder private var runButton: some View {
        if model.isRunning {
            ToolStopButton { model.cancel() }
        } else {
            Button { model.run(store: store) } label: { Label("Découvrir", systemImage: "bonjour") }
                .buttonStyle(.primary)
                .fixedSize()
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.stoppedEarly {
            Text("Découverte arrêtée après \(model.elapsed)\u{00A0}s, avant la fin des \(BonjourModel.duration)\u{00A0}s d’écoute. Relancer pour un résultat complet.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.hasRun {
            ToolNotice(tone: .neutral, title: "Aucun service trouvé en \(BonjourModel.duration)\u{00A0}s",
                       message: "Aucun appareil ne s’est annoncé sur ce réseau. Bonjour ne franchit pas les routeurs\u{00A0}: vérifier que ce Mac est bien sur le VLAN voulu, et que NetScope est activé dans Réglages Système, Confidentialité et sécurité, Réseau local.")
        } else {
            Text("Écoute pendant \(BonjourModel.duration)\u{00A0}s les services annoncés en Bonjour (mDNS) sur le réseau local\u{00A0}: imprimantes, partages, AirPlay, accessoires… Seules des requêtes mDNS sont envoyées, et seulement au clic sur Découvrir.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var results: some View {
        let groups = model.groups
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                summary
                Spacer(minLength: 8)
                ToolColumnsMenu(model: table)
            }
            VStack(alignment: .leading, spacing: 8) {
                summary
                ToolColumnsMenu(model: table)
            }
        }
        BonjourTable(groups: groups, table: table, selection: $model.selection)
        if let service = model.selected { detail(service) }
        ActionRow {
            Button { ToolActions.copy(BonjourFormat.report(groups)) } label: { Label("Copier le rapport", systemImage: "doc.on.doc") }
                .buttonStyle(.secondary)
                .disabled(groups.isEmpty)
        }
    }

    private var summary: some View {
        ToolFlowLayout(spacing: 6, lineSpacing: 6) {
            Chip(text: serviceCount(model.services.count), tone: .accent)
            Chip(text: "\(model.deviceCount) appareil\(model.deviceCount > 1 ? "s" : "")", tone: .neutral)
            Chip(text: "\(model.typeCount) type\(model.typeCount > 1 ? "s" : "")", tone: .neutral)
        }
    }

    private func serviceCount(_ count: Int) -> String { "\(count) service\(count > 1 ? "s" : "")" }

    private func detail(_ service: BonjourService) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolFieldLabel("Détail · \(service.typeLabel)")
            ToolCellGrid(cells: cells(service), columns: 3, valueSize: 13, minCellWidth: 210, truncatesLongValues: true)
            txtBlock(service)
        }
    }

    private func cells(_ service: BonjourService) -> [ToolCell] {
        [
            ToolCell(key: "Instance", value: service.instance, detail: "domaine \(service.domain)"),
            ToolCell(key: "Type", value: service.type, detail: service.typeLabel),
            ToolCell(key: "Hôte", value: service.hostName ?? "non résolu", detail: service.port.map { "port \($0)" } ?? "port inconnu"),
            ToolCell(key: "IPv4", value: service.ipv4.first ?? "—", detail: extra(service.ipv4)),
            ToolCell(key: "IPv6", value: service.ipv6.first ?? "—", detail: extra(service.ipv6)),
            ToolCell(key: "TXT", value: "\(service.txt.count)", detail: service.txt.count > 1 ? "clés" : "clé"),
        ]
    }

    private func extra(_ addresses: [String]) -> String {
        addresses.count > 1 ? addresses.dropFirst().joined(separator: ", ") : addresses.isEmpty ? "aucune" : "une seule adresse"
    }

    @ViewBuilder private func txtBlock(_ service: BonjourService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolFieldLabel("Enregistrement TXT")
            if service.txt.isEmpty {
                Text("Aucune clé TXT annoncée.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(service.sortedTXT, id: \.key) { entry in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(entry.key).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            Text(entry.value.isEmpty ? "(présente, sans valeur)" : entry.value)
                                .font(Theme.mono(12)).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Ligne du tableau : en-tête de groupe (`service` vide) ou service.
struct BonjourRow: Identifiable {
    let id: String
    let group: BonjourGroup?
    let service: BonjourService?

    init(group: BonjourGroup) {
        id = "groupe|\(group.id)"
        self.group = group
        service = nil
    }

    init(service: BonjourService) {
        id = service.id
        group = nil
        self.service = service
    }

    var instance: String { service?.instance ?? "" }
    var typeLabel: String { service?.typeLabel ?? "" }
    var hostText: String { service?.hostName ?? "" }
    var portSort: Int { service?.port ?? -1 }
    var addressSort: UInt32 { service?.ipv4.first.flatMap { IPv4Address($0)?.value } ?? .max }
    var txtCount: Int { service?.txt.count ?? 0 }
}

/// Services groupés (tableau standard « outils.bonjour »). Les en-têtes sont de simples lignes :
/// `Section` dans un `Table` déclenche chez AppKit un avertissement de réentrance appelé à devenir
/// une assertion.
struct BonjourTable: View {
    let groups: [BonjourGroup]
    @ObservedObject var table: StandardTableModel<BonjourRow>
    @Binding var selection: String?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "instance", title: "Instance", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "hote", title: "Hôte"),
        StandardColumn(id: "port", title: "Port"),
        StandardColumn(id: "adresse", title: "Adresse"),
        StandardColumn(id: "txt", title: "TXT", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<BonjourRow>] = [
        "instance": KeyPathComparator(\BonjourRow.instance),
        "type": KeyPathComparator(\BonjourRow.typeLabel),
        "hote": KeyPathComparator(\BonjourRow.hostText),
        "port": KeyPathComparator(\BonjourRow.portSort),
        "adresse": KeyPathComparator(\BonjourRow.addressSort),
        "txt": KeyPathComparator(\BonjourRow.txtCount),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<BonjourRow> {
        StandardTableModel(id: "outils.bonjour", columns: columns, sortKeys: sortKeys, defaultSort: "type")
    }

    /// Le tri s'applique à l'intérieur de chaque groupe, jamais aux en-têtes.
    private var rows: [BonjourRow] {
        groups.flatMap { [BonjourRow(group: $0)] + $0.services.map(BonjourRow.init(service:)).sorted(using: table.sortOrder) }
    }

    var body: some View {
        let rows = self.rows
        ToolStandardTableFrame(rowCount: rows.count, emptyText: "Aucun service ne correspond au filtre.") {
            Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("INSTANCE", sortUsing: table.sort("instance")) { row in
                    if let group = row.group {
                        ToolTableText(group.title, mono: false, weight: .bold).help(group.title)
                    } else {
                        ToolTableText(row.instance, mono: false, weight: .medium).help(row.instance).padding(.leading, 12)
                    }
                }
                .width(min: 130, ideal: 165)
                .customizationID("instance")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                    if let group = row.group {
                        ToolTableText(group.countText, mono: false, color: Theme.textSecondary)
                    } else {
                        ToolTableText(row.typeLabel, mono: false, color: Theme.textSecondary).help(row.service?.type ?? "")
                    }
                }
                .width(min: 100, ideal: 125)
                .customizationID("type")

                TableColumn("HÔTE", sortUsing: table.sort("hote")) { row in
                    if let group = row.group {
                        ToolTableText(group.detail, color: Theme.textSecondary).help(group.detail)
                    } else {
                        ToolTableText(row.service?.hostName ?? "non résolu", color: Theme.textSecondary).help(row.hostText)
                    }
                }
                .width(min: 90, ideal: 120)
                .customizationID("hote")

                TableColumn("PORT", sortUsing: table.sort("port")) { row in
                    ToolTableText(row.group != nil ? "" : row.service?.port.map(String.init) ?? "—", color: Theme.textSecondary)
                }
                .width(min: 44, ideal: 48)
                .customizationID("port")

                TableColumn("ADRESSE", sortUsing: table.sort("adresse")) { row in
                    ToolTableText(row.group != nil ? "" : row.service?.addresses.first ?? "—", color: Theme.textSecondary)
                        .help(row.service?.addresses.joined(separator: "\n") ?? "")
                }
                .width(min: 92, ideal: 100)
                .customizationID("adresse")

                TableColumn("TXT", sortUsing: table.sort("txt")) { row in
                    ToolTableText(row.group != nil ? "" : "\(row.txtCount)", color: Theme.textSecondary)
                }
                .width(min: 40, ideal: 48)
                .customizationID("txt")
                .defaultVisibility(.hidden)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Copier") {
                    let chosen = groups.compactMap { group -> BonjourGroup? in
                        let services = ids.contains(BonjourRow(group: group).id) ? group.services : group.services.filter { ids.contains($0.id) }
                        return services.isEmpty ? nil : BonjourGroup(id: group.id, title: group.title, detail: group.detail, services: services)
                    }
                    ToolActions.copy(BonjourFormat.report(chosen))
                }
                .disabled(ids.isEmpty)
            }
        }
    }
}
