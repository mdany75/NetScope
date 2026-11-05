import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Test MTU (notes 78 et 79) : vraie recherche du MTU du chemin par dichotomie avec le bit DF,
/// résultat « MTU du chemin = N octets vers X », diagnostic (PPPoE, tunnel, jumbo), étapes de
/// la recherche et historique des mesures.
struct PathMTUView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: PathMTUModel
    @ObservedObject var store: ToolStore
    @StateObject private var stepsTable = PathMTUStepsTable.makeModel()
    @StateObject private var historyTable = PathMTUHistoryTable.makeModel()
    @State private var historySelection = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            form
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            if model.isRunning {
                MailProgressLine(text: model.progressText)
            }
            if let result = model.result {
                resultBlock(result)
            } else if !model.isRunning, model.error == nil {
                Text("Envoie des échos ICMP de taille variable avec le bit «\u{00A0}ne pas fragmenter\u{00A0}» et cherche par dichotomie la plus grande taille qui passe sans fragmentation jusqu’à la cible. Choisir une adresse sur Internet (1.1.1.1) pour voir le PPPoE du fournisseur, l’autre bout d’un tunnel pour voir sa surcharge.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.steps.isEmpty {
                HStack {
                    ToolFieldLabel("Étapes de la recherche")
                    Spacer(minLength: 8)
                    ToolColumnsMenu(model: stepsTable)
                }
                PathMTUStepsTable(steps: model.steps, table: stepsTable)
            }
            historySection
        }
        .onAppear {
            if model.target.isEmpty { model.target = "1.1.1.1" }
        }
    }

    // MARK: Formulaire

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Cible (IP ou nom d’hôte)") {
                    ToolTextField(placeholder: "1.1.1.1", text: $model.target) { start() }
                        .frame(minWidth: 200)
                }
                VStack(alignment: .leading, spacing: 5) {
                    ToolFieldLabel("Suggestions")
                    HStack(spacing: 6) {
                        if let gateway = state.activeInterface?.gateway?.description {
                            ToolChoiceChip(label: "Passerelle", isSelected: model.target == gateway, mono: false) { model.target = gateway }
                                .help("Passerelle de ce Mac (\(gateway))\u{00A0}: chemin local, 1500 attendu")
                        }
                        ToolChoiceChip(label: "1.1.1.1", isSelected: model.target == "1.1.1.1") { model.target = "1.1.1.1" }
                            .help("Cloudflare\u{00A0}: chemin vers Internet (PPPoE du fournisseur)")
                        ToolChoiceChip(label: "8.8.8.8", isSelected: model.target == "8.8.8.8") { model.target = "8.8.8.8" }
                            .help("Google DNS\u{00A0}: chemin vers Internet")
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    jumboToggle
                    Spacer(minLength: 8)
                    runButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    jumboToggle
                    runButton
                }
            }
        }
    }

    private var jumboToggle: some View {
        ToolCheckbox(label: "Chercher les trames jumbo (jusqu’à 9000\u{00A0}octets)", isOn: $model.jumbo)
            .help("Sans cette case, la recherche s’arrête à 1500\u{00A0}octets (Ethernet standard).")
            .disabled(model.isRunning)
    }

    @ViewBuilder private var runButton: some View {
        if model.isRunning {
            Button { model.cancel() } label: { Label("Arrêter", systemImage: "stop.fill") }
                .buttonStyle(.secondary)
                .fixedSize()
        } else {
            Button { start() } label: { Label("Mesurer le MTU", systemImage: "ruler") }
                .buttonStyle(.primary)
                .fixedSize()
                .disabled(model.target.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func start() {
        model.run(store: store, gateway: state.activeInterface?.gateway, interface: state.activeInterface?.name)
    }

    // MARK: Résultat

    @ViewBuilder private func resultBlock(_ result: PathMTUResult) -> some View {
        switch result.status {
        case .found:
            if let mtu = result.mtu, let diagnosis = result.diagnosis {
                found(result, mtu: mtu, diagnosis: diagnosis)
            }
        case let .unreachable(message):
            ToolNotice(tone: .critical, title: "MTU non mesuré vers \(model.measuredTarget)", message: message)
        case let .interrupted(message):
            ToolNotice(tone: .warning, title: "Mesure interrompue",
                       message: message + (result.mtu.map { " Le chemin laisse passer au moins \($0)\u{00A0}octets." } ?? ""))
        }
    }

    private func tone(_ diagnosis: PathMTUDiagnosis) -> Tone {
        switch diagnosis.severity {
        case .normal: return .success
        case .reduced: return .warning
        case .problem: return .critical
        }
    }

    @ViewBuilder private func found(_ result: PathMTUResult, mtu: Int, diagnosis: PathMTUDiagnosis) -> some View {
        let destination = destinationText
        VStack(alignment: .leading, spacing: 8) {
            ToolFieldLabel("MTU du chemin")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    sentence(mtu: mtu, destination: destination)
                    Chip(text: diagnosis.title, tone: tone(diagnosis))
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    sentence(mtu: mtu, destination: destination)
                    Chip(text: diagnosis.title, tone: tone(diagnosis))
                }
            }
            Text(diagnosis.explanation)
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .contextMenu {
            Button("Copier le résultat") {
                ToolActions.copy("MTU du chemin = \(mtu) octets vers \(destination) · \(diagnosis.title) · MSS conseillé \(mtu - 40)")
            }
        }

        ToolCellGrid(cells: cells(result, mtu: mtu), columns: 4, minCellWidth: 200)

        if result.isBlackHole {
            ToolNotice(tone: .warning, title: "Trou noir ICMP probable",
                       message: "Les paquets trop grands ont été jetés sans message «\u{00A0}fragmentation nécessaire\u{00A0}»\u{00A0}: un pare-feu filtre l’ICMP sur le chemin. La découverte automatique du MTU échoue alors et les connexions TCP peuvent figer (pages qui chargent à moitié, VPN qui décroche). Laissez passer l’ICMP de type 3 code 4, ou réglez le MSS à \(mtu - 40) sur l’équipement du tunnel.")
        } else if result.localLimit, mtu < result.options.maxSize {
            ToolNotice(tone: .accent, title: "Limité par ce Mac",
                       message: "L’interface \(model.interfaceName ?? "de sortie") de ce Mac est à \(model.interfaceMTU.map(String.init) ?? "\(mtu)")\u{00A0}octets\u{00A0}: le chemin pourrait accepter davantage. Pour tester les trames jumbo, réglez d’abord le MTU de l’interface (Réglages Système › Réseau › Détails › Matériel).")
        }
        if let previous = model.previous, let before = previous.mtu, before != mtu {
            ToolNotice(tone: .accent, title: "Le MTU a changé",
                       message: "La mesure précédente vers \(previous.target) (\(ToolText.time(previous.date))) donnait \(before)\u{00A0}octets (\(previous.diagnosis?.title ?? "—")), contre \(mtu) maintenant\u{00A0}: changement de fournisseur, de lien ou de tunnel\u{00A0}?")
        }
    }

    private func sentence(mtu: Int, destination: String) -> some View {
        (Text(verbatim: "\(mtu)\u{00A0}octets").font(Theme.mono(24, weight: .semibold)).foregroundColor(Theme.text)
         + Text(verbatim: "  vers \(destination)").font(Theme.body).foregroundColor(Theme.textSecondary))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .textSelection(.enabled)
    }

    private var destinationText: String {
        let address = model.measuredAddress?.description ?? model.measuredTarget
        return model.measuredTarget == address ? address : "\(model.measuredTarget) (\(address))"
    }

    private func cells(_ result: PathMTUResult, mtu: Int) -> [ToolCell] {
        var cells = [
            ToolCell(key: "Charge ICMP maximale", value: "\(mtu - PathMTUSearch.overhead)\u{00A0}octets",
                     detail: "ping -D -s \(mtu - PathMTUSearch.overhead)"),
            ToolCell(key: "MSS TCP conseillé", value: "\(mtu - 40)\u{00A0}octets", detail: "MTU − 40 (en-têtes IP et TCP)"),
        ]
        if let interfaceMTU = model.interfaceMTU {
            cells.append(ToolCell(key: "Interface \(model.interfaceName ?? "de sortie")", value: "\(interfaceMTU)\u{00A0}octets",
                                  detail: interfaceMTU > mtu ? "\(interfaceMTU - mtu)\u{00A0}octets perdus en route" : "identique au chemin"))
        } else {
            cells.append(ToolCell(key: "Écart avec Ethernet", value: "\(max(0, 1500 - mtu))\u{00A0}octets", detail: "1500 − MTU du chemin"))
        }
        let router = result.limitingRouter.map { " · limite signalée par \($0)" } ?? ""
        let rtt = result.averageRTT.map { " · \(PingFormat.decimal($0))\u{00A0}ms en moyenne" } ?? ""
        cells.append(ToolCell(key: "Sondes", value: "\(result.probesSent) envois · \(result.steps.count) tailles",
                              detail: model.method.label + router + rtt))
        return cells
    }

    // MARK: Historique

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolFieldLabel("Historique des mesures")
                Text("\(model.history.count)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button { exportCSV() } label: { Label("Exporter CSV", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .disabled(model.history.isEmpty)
                ToolColumnsMenu(model: historyTable)
            }
            PathMTUHistoryTable(rows: model.history, table: historyTable, selection: $historySelection,
                                remeasure: remeasure, remove: { model.remove($0) })
        }
    }

    private func remeasure(_ ids: Set<UUID>) {
        guard let item = model.history.first(where: { ids.contains($0.id) }) else { return }
        model.target = item.target
        model.jumbo = item.maxTested > 1500
        start()
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "test-mtu.csv"
        panel.title = "Exporter l’historique du test MTU"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PathMTUHistory.csv(model.history).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Tableau des étapes

/// Étapes de la dichotomie (tableau standard « outils.mtu.etapes »).
struct PathMTUStepsTable: View {
    let steps: [PathMTUStep]
    @ObservedObject var table: StandardTableModel<PathMTUStep>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "numero", title: "N°", isRequired: true),
        StandardColumn(id: "taille", title: "Taille IP"),
        StandardColumn(id: "donnees", title: "Données"),
        StandardColumn(id: "resultat", title: "Résultat"),
        StandardColumn(id: "temps", title: "Temps"),
        StandardColumn(id: "bornes", title: "MTU entre"),
        StandardColumn(id: "envois", title: "Envois", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<PathMTUStep>] = [
        "numero": KeyPathComparator(\PathMTUStep.index),
        "taille": KeyPathComparator(\PathMTUStep.size),
        "donnees": KeyPathComparator(\PathMTUStep.payload),
        "resultat": KeyPathComparator(\PathMTUStep.sortOutcome),
        "temps": KeyPathComparator(\PathMTUStep.sortRTT),
        "bornes": KeyPathComparator(\PathMTUStep.low),
        "envois": KeyPathComparator(\PathMTUStep.attempts),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<PathMTUStep> {
        StandardTableModel(id: "outils.mtu.etapes", columns: columns, sortKeys: sortKeys, defaultSort: "numero")
    }

    var body: some View {
        let sorted = steps.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 10) {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("N°", sortUsing: table.sort("numero")) { step in
                    ToolTableText("\(step.index)", color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 24, ideal: 28, max: 40)
                .customizationID("numero")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("TAILLE IP", sortUsing: table.sort("taille")) { step in
                    ToolTableText("\(step.size)", weight: .semibold, alignment: .trailing)
                }
                .width(min: 56, ideal: 60)
                .customizationID("taille")

                TableColumn("DONNÉES", sortUsing: table.sort("donnees")) { step in
                    ToolTableText("\(step.payload)", color: Theme.textSecondary, alignment: .trailing)
                        .help("Données ICMP (ping -s) : taille − 28 octets d’en-têtes")
                }
                .width(min: 56, ideal: 64)
                .customizationID("donnees")

                TableColumn("RÉSULTAT", sortUsing: table.sort("resultat")) { step in
                    HStack(spacing: 6) {
                        Chip(text: step.outcome.passed ? "Passe" : step.outcome == .lost ? "Perdu" : "Refusé",
                             tone: step.outcome.passed ? .success : step.outcome == .lost ? .neutral : .warning)
                        ToolTableText(step.shortLabel, mono: false, color: Theme.textSecondary)
                    }
                    .help(step.outcome.label)
                }
                .width(min: 120, ideal: 170)
                .customizationID("resultat")

                TableColumn("TEMPS", sortUsing: table.sort("temps")) { step in
                    ToolTableText(step.rttText, alignment: .trailing)
                }
                .width(min: 52, ideal: 60)
                .customizationID("temps")

                TableColumn("MTU ENTRE", sortUsing: table.sort("bornes")) { step in
                    ToolTableText(step.boundsText, color: Theme.textSecondary)
                }
                .width(min: 80, ideal: 90)
                .customizationID("bornes")

                TableColumn("ENVOIS", sortUsing: table.sort("envois")) { step in
                    ToolTableText("\(step.attempts)", alignment: .trailing)
                }
                .width(min: 46, ideal: 56)
                .customizationID("envois")
                .defaultVisibility(.hidden)
            }
        }
    }
}

extension PathMTUStep {
    var sortOutcome: Int { outcome.passed ? 0 : outcome == .lost ? 2 : 1 }
    var sortRTT: Double {
        if case let .reply(rtt) = outcome { return rtt }
        return .greatestFiniteMagnitude
    }
    /// Détail court du résultat (le libellé complet est dans l'info-bulle).
    var shortLabel: String {
        switch outcome {
        case .reply: return ""
        case let .tooBig(reported, from, local):
            if local { return "trop grand pour l’interface" }
            return (reported.map { "MTU \($0) annoncé" } ?? "fragmentation nécessaire") + (from.map { " par \($0)" } ?? "")
        case .lost: return attempts > 1 ? "aucune réponse (\(attempts) envois)" : "aucune réponse"
        case let .unreachable(code, _): return "inaccessible (code \(code))"
        case let .failed(message): return message
        }
    }
    var rttText: String {
        if case let .reply(rtt) = outcome { return "\(PingFormat.decimal(rtt))\u{00A0}ms" }
        return "—"
    }
    /// « 1492 – 1499 » : bornes du MTU connues après l'étape.
    var boundsText: String {
        guard let high else { return "≥\u{00A0}\(low)" }
        return high - 1 == low ? "= \(low)" : "\(low) – \(high - 1)"
    }
}

// MARK: - Tableau de l'historique

/// Historique des mesures (tableau standard « outils.mtu.historique »).
struct PathMTUHistoryTable: View {
    let rows: [PathMTUMeasurement]
    @ObservedObject var table: StandardTableModel<PathMTUMeasurement>
    @Binding var selection: Set<UUID>
    let remeasure: (Set<UUID>) -> Void
    let remove: (Set<UUID>) -> Void

    static let columns: [StandardColumn] = [
        StandardColumn(id: "date", title: "Date"),
        StandardColumn(id: "cible", title: "Cible", isRequired: true),
        StandardColumn(id: "mtu", title: "MTU"),
        StandardColumn(id: "diagnostic", title: "Diagnostic"),
        StandardColumn(id: "sondes", title: "Sondes"),
        StandardColumn(id: "methode", title: "Méthode", isDefaultVisible: false),
        StandardColumn(id: "adresse", title: "Adresse", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<PathMTUMeasurement>] = [
        "date": KeyPathComparator(\PathMTUMeasurement.date, order: .reverse),
        "cible": KeyPathComparator(\PathMTUMeasurement.target),
        "mtu": KeyPathComparator(\PathMTUMeasurement.sortMTU),
        "diagnostic": KeyPathComparator(\PathMTUMeasurement.diagnosisText),
        "sondes": KeyPathComparator(\PathMTUMeasurement.probes),
        "methode": KeyPathComparator(\PathMTUMeasurement.methodText),
        "adresse": KeyPathComparator(\PathMTUMeasurement.address),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<PathMTUMeasurement> {
        StandardTableModel(id: "outils.mtu.historique", columns: columns, sortKeys: sortKeys, defaultSort: "date")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 8, emptyText: "Aucune mesure pour l’instant.") {
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("DATE", sortUsing: table.sort("date")) { row in
                    ToolTableText(ToolText.day(row.date), mono: false, color: Theme.textSecondary)
                }
                .width(min: 80, ideal: 110)
                .customizationID("date")

                TableColumn("CIBLE", sortUsing: table.sort("cible")) { row in
                    ToolTableText(row.target, weight: .medium).help(row.target == row.address ? row.address : "\(row.target) (\(row.address))")
                }
                .width(min: 90, ideal: 130)
                .customizationID("cible")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("MTU", sortUsing: table.sort("mtu")) { row in
                    ToolTableText(row.mtu.map(String.init) ?? "—", weight: .semibold, alignment: .trailing)
                }
                .width(min: 44, ideal: 52)
                .customizationID("mtu")

                TableColumn("DIAGNOSTIC", sortUsing: table.sort("diagnostic")) { row in
                    HStack(spacing: 6) {
                        if let diagnosis = row.diagnosis {
                            Chip(text: diagnosis.title, tone: diagnosis.severity == .normal ? .success : diagnosis.severity == .reduced ? .warning : .critical)
                        } else {
                            Chip(text: "Non mesuré", tone: .critical)
                        }
                        if row.blackHole { Chip(text: "Trou noir", tone: .warning) }
                    }
                    .help(row.diagnosis?.explanation ?? row.note ?? "")
                }
                .width(min: 120, ideal: 220)
                .customizationID("diagnostic")

                TableColumn("SONDES", sortUsing: table.sort("sondes")) { row in
                    ToolTableText("\(row.probes)", color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 50, ideal: 56)
                .customizationID("sondes")

                TableColumn("MÉTHODE", sortUsing: table.sort("methode")) { row in
                    ToolTableText(row.methodText, mono: false, color: Theme.textSecondary)
                }
                .width(min: 60, ideal: 80)
                .customizationID("methode")
                .defaultVisibility(.hidden)

                TableColumn("ADRESSE", sortUsing: table.sort("adresse")) { row in
                    ToolTableText(row.address, color: Theme.textSecondary)
                }
                .width(min: 80, ideal: 110)
                .customizationID("adresse")
                .defaultVisibility(.hidden)
            }
            .standardRowActions(selection: Array(selection), object: { _ in nil }, primary: { ids in
                remeasure(ids)
                return true
            }) { ids in
                Button("Mesurer à nouveau") { remeasure(ids) }.disabled(ids.isEmpty)
                Button("Copier") {
                    ToolActions.copy(rows.filter { ids.contains($0.id) }.map(\.sentence).joined(separator: "\n"))
                }
                .disabled(ids.isEmpty)
                Divider()
                Button("Retirer de l’historique", role: .destructive) { remove(ids) }.disabled(ids.isEmpty)
            }
        }
    }
}

extension PathMTUMeasurement {
    var sortMTU: Int { mtu ?? -1 }
    var diagnosisText: String { diagnosis?.title ?? "Non mesuré" }
    var methodText: String { method.label }
}
