import AppKit
import NetScopeCore
import SwiftUI

// Note 78 (0.26.0) : tableau compact du ping continu, automatique au-delà de 9 cibles (ou imposé
// par le bouton de disposition). Une ligne par cible : état, nom, adresse, dernière mesure,
// statistiques des 60 dernières mesures, petite courbe et seuil de lenteur (tableau standard).

/// Une ligne du tableau compact, avec les clés de tri (valeur absente : après les autres).
struct PingCompactRow: Identifiable {
    let target: PingTarget
    let stats: PingStatistics
    let values: [Double?]

    @MainActor init(_ target: PingTarget) {
        self.target = target
        values = target.history.values(last: PingController.cardWindow)
        stats = PingStatistics(values: values)
    }

    var id: PingTarget.ID { target.id }
    var last: Double? { target.history.last?.rttMs }

    var sortStatus: Int {
        switch target.status {
        case .horsLigne: return 0
        case .perte: return 1
        case .enLigne: return 2
        case .attente: return 3
        case .enPause: return 4
        }
    }
    var sortName: String { target.name.lowercased() }
    var sortAddress: IPv4Address { target.address ?? IPv4Address(UInt32.max) }
    var sortRole: String { target.role.lowercased() }
    var sortLast: Double { last ?? .greatestFiniteMagnitude }
    var sortMin: Double { stats.min ?? .greatestFiniteMagnitude }
    var sortAverage: Double { stats.average ?? .greatestFiniteMagnitude }
    var sortMax: Double { stats.max ?? .greatestFiniteMagnitude }
    var sortJitter: Double { stats.jitter ?? .greatestFiniteMagnitude }
    var sortLoss: Double { stats.lossPercent }
    var sortThreshold: Double { target.thresholdMs }
    var sortSent: Int { target.history.totalSent }
}

struct PingCompactTable: View {
    @ObservedObject var controller: PingController
    @ObservedObject var table: StandardTableModel<PingCompactRow>
    /// Cible dont la carte est retournée en Terminal (double-clic) : la même que l'écran à cartes.
    let onOpen: (PingTarget.ID) -> Void

    static let rowHeight: CGFloat = 28

    static let columns: [StandardColumn] = [
        StandardColumn(id: "etat", title: "État", isRequired: true),
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "adresse", title: "Adresse"),
        StandardColumn(id: "role", title: "Rôle", isDefaultVisible: false),
        StandardColumn(id: "dernier", title: "Dernière"),
        StandardColumn(id: "courbe", title: "Courbe"),
        StandardColumn(id: "min", title: "Min", isDefaultVisible: false),
        StandardColumn(id: "moyenne", title: "Moy"),
        StandardColumn(id: "max", title: "Max"),
        StandardColumn(id: "gigue", title: "Gigue"),
        StandardColumn(id: "perte", title: "Perte"),
        StandardColumn(id: "seuil", title: "Seuil"),
        StandardColumn(id: "envoyes", title: "Envoyés / reçus", isDefaultVisible: false),
    ]

    /// Largeurs idéales (défilement horizontal en petite fenêtre).
    static let widths: [String: CGFloat] = [
        "etat": 96, "nom": 150, "adresse": 104, "role": 140, "dernier": 60, "courbe": 130, "min": 46, "moyenne": 46,
        "max": 46, "gigue": 48, "perte": 56, "seuil": 72, "envoyes": 96,
    ]

    static let sortKeys: [String: KeyPathComparator<PingCompactRow>] = [
        "etat": KeyPathComparator(\PingCompactRow.sortStatus),
        "nom": KeyPathComparator(\PingCompactRow.sortName),
        "adresse": KeyPathComparator(\PingCompactRow.sortAddress),
        "role": KeyPathComparator(\PingCompactRow.sortRole),
        "dernier": KeyPathComparator(\PingCompactRow.sortLast),
        "courbe": KeyPathComparator(\PingCompactRow.sortAverage),
        "min": KeyPathComparator(\PingCompactRow.sortMin),
        "moyenne": KeyPathComparator(\PingCompactRow.sortAverage),
        "max": KeyPathComparator(\PingCompactRow.sortMax),
        "gigue": KeyPathComparator(\PingCompactRow.sortJitter),
        "perte": KeyPathComparator(\PingCompactRow.sortLoss),
        "seuil": KeyPathComparator(\PingCompactRow.sortThreshold),
        "envoyes": KeyPathComparator(\PingCompactRow.sortSent),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<PingCompactRow> {
        // Tri d'origine : l'ordre d'ajout n'est pas une colonne ; l'état met les cibles tombées en haut.
        StandardTableModel(id: "ping.compact", columns: columns, sortKeys: sortKeys, defaultSort: "etat")
    }

    var body: some View {
        let rows = controller.targets.map(PingCompactRow.init).sorted(using: table.sortOrder)
        let selection = Binding<Set<PingTarget.ID>>(
            get: { controller.selectedID.map { [$0] } ?? [] },
            set: { ids in if let id = ids.first { controller.selectedID = id } })
        Table(rows, selection: selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(StandardTableHeading("ÉTAT"), sortUsing: table.sort("etat")) { row in
                    statusCell(row)
                }
                .width(min: 84, ideal: 96, max: 120)
                .customizationID("etat")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("NOM"), sortUsing: table.sort("nom")) { row in
                    Text(row.target.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(row.target.isPaused ? Theme.textSecondary : Theme.text)
                        .lineLimit(1)
                        .help(row.target.role.isEmpty ? row.target.name : "\(row.target.name) · \(row.target.role)")
                }
                .width(min: 100, ideal: 150)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("ADRESSE"), sortUsing: table.sort("adresse")) { row in
                    PingCell(row.target.addressLabel, mono: true, size: 11)
                }
                .width(min: 90, ideal: 110)
                .customizationID("adresse")

                TableColumn(StandardTableHeading("RÔLE"), sortUsing: table.sort("role")) { row in
                    PingCell(row.target.role, color: Theme.textSecondary, size: 11)
                }
                .width(min: 80, ideal: 140)
                .customizationID("role")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("DERNIÈRE"), sortUsing: table.sort("dernier")) { row in
                    let over = (row.last ?? 0) > row.target.thresholdMs
                    PingCell(lastText(row), mono: true, color: row.target.history.last?.isLost == true ? Theme.critical : over ? Theme.warning : Theme.text,
                             bold: true, trailing: true)
                }
                .width(min: 56, ideal: 66)
                .customizationID("dernier")

                TableColumn(StandardTableHeading("COURBE"), sortUsing: table.sort("courbe")) { row in
                    PingSparkline(values: row.values, color: sparkColor(row.target.status))
                        .frame(height: 18)
                        .opacity(row.target.isPaused ? 0.45 : 1)
                }
                .width(min: 80, ideal: 130)
                .customizationID("courbe")

                TableColumn(StandardTableHeading("MIN"), sortUsing: table.sort("min")) { row in
                    PingCell(PingFormat.decimal(row.stats.min), mono: true, trailing: true)
                }
                .width(min: 40, ideal: 48)
                .customizationID("min")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("MOY"), sortUsing: table.sort("moyenne")) { row in
                    PingCell(PingFormat.decimal(row.stats.average), mono: true, trailing: true)
                }
                .width(min: 40, ideal: 50)
                .customizationID("moyenne")

                TableColumn(StandardTableHeading("MAX"), sortUsing: table.sort("max")) { row in
                    let over = (row.stats.max ?? 0) > row.target.thresholdMs
                    PingCell(PingFormat.decimal(row.stats.max), mono: true, color: over ? Theme.warning : Theme.text, trailing: true)
                }
                .width(min: 40, ideal: 50)
                .customizationID("max")
            }
            Group {
                TableColumn(StandardTableHeading("GIGUE"), sortUsing: table.sort("gigue")) { row in
                    PingCell(PingFormat.decimal(row.stats.jitter), mono: true, trailing: true)
                }
                .width(min: 44, ideal: 52)
                .customizationID("gigue")

                TableColumn(StandardTableHeading("PERTE"), sortUsing: table.sort("perte")) { row in
                    let loss = row.stats.lossPercent
                    PingCell(PingFormat.percent(loss), mono: true, color: pingLossColor(loss), bold: loss > 0, trailing: true)
                }
                .width(min: 48, ideal: 58)
                .customizationID("perte")

                TableColumn(StandardTableHeading("SEUIL"), sortUsing: table.sort("seuil")) { row in
                    PingThresholdMenu(target: row.target, controller: controller, compact: true)
                }
                .width(min: 64, ideal: 76)
                .customizationID("seuil")

                TableColumn(StandardTableHeading("ENVOYÉS / REÇUS"), sortUsing: table.sort("envoyes")) { row in
                    PingCell("\(row.target.history.totalSent) / \(row.target.history.totalReceived)", mono: true, size: 11, trailing: true)
                }
                .width(min: 80, ideal: 100)
                .customizationID("envoyes")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: PingTarget.ID.self) { ids in
            if let id = ids.first, let target = controller.targets.first(where: { $0.id == id }) {
                PingTargetMenu(target: target, onTogglePause: { controller.togglePause(id) }, onRemove: { controller.remove(id) })
                Divider()
                Button("Voir les réponses façon Terminal") { onOpen(id) }
                Button("Retirer la cible", role: .destructive) { controller.remove(id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { onOpen(id) }
        }
    }

    private func statusCell(_ row: PingCompactRow) -> some View {
        let target = row.target
        return HStack(spacing: 6) {
            PingPauseButton(isPaused: target.isPaused) { controller.togglePause(target.id) }
            if target.error != nil, !target.isPaused {
                PingStatusPill(text: "Erreur", tone: .critical)
            } else {
                PingStatusPill(text: target.status.label, tone: target.status.tone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lastText(_ row: PingCompactRow) -> String {
        if row.target.isPaused { return "—" }
        guard let last = row.target.history.last else { return "—" }
        return last.rttMs.map { PingFormat.decimal($0) } ?? "perdu"
    }

    private func sparkColor(_ status: PingTargetStatus) -> Color {
        switch status {
        case .horsLigne: return Theme.critical
        case .perte: return Theme.warning
        default: return Theme.accent
        }
    }
}

/// Menu du seuil de lenteur d'une cible (carte, tableau compact) : seuils proposés, coche sur le
/// seuil en vigueur, retour au seuil d'origine.
struct PingThresholdMenu: View {
    let target: PingTarget
    @ObservedObject var controller: PingController
    var compact = false

    var body: some View {
        Menu {
            PingThresholdChoices(target: target, controller: controller)
        } label: {
            Text(PingThreshold.label(target.thresholdMs))
                .font(Theme.mono(compact ? 11 : 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Seuil de lenteur\u{00A0}: une réponse plus lente est signalée au journal")
        .accessibilityLabel("Seuil de lenteur \(PingThreshold.label(target.thresholdMs))")
    }
}

/// Entrées du menu de seuil (aussi dans le clic droit des cartes).
struct PingThresholdChoices: View {
    let target: PingTarget
    @ObservedObject var controller: PingController

    var body: some View {
        let original = controller.defaultThreshold(for: target)
        ForEach(PingThreshold.choices, id: \.self) { value in
            Toggle(isOn: Binding(get: { target.thresholdMs == value },
                                 set: { if $0 { controller.setThreshold(value, for: target.id) } })) {
                Text(PingThreshold.label(value) + (value == original ? " (d’origine)" : ""))
            }
        }
        if !PingThreshold.choices.contains(original), target.thresholdMs != original {
            Divider()
            Button("Seuil d’origine (\(PingThreshold.label(original)))") { controller.setThreshold(original, for: target.id) }
        }
    }
}
