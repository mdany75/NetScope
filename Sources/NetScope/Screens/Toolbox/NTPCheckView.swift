import NetScopeCore
import SwiftUI

/// Test NTP (note 115) : décalage, délai, strate et référence de chaque serveur, et ce que ça veut dire.
struct NTPCheckView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: NTPCheckModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = NTPResultsTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            form
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            if let notice = model.notice { ToolNotice(tone: .warning, message: notice) }
            if model.isRunning {
                MailProgressLine(text: "\(model.serverCount) serveur\(model.serverCount > 1 ? "s" : "") interrogé\(model.serverCount > 1 ? "s" : ""), 4\u{00A0}échantillons chacun espacés de 2\u{00A0}s…")
            } else if !model.results.isEmpty {
                results
            } else if model.error == nil {
                Text("Compare l’horloge de ce Mac à un ou plusieurs serveurs de temps (SNTP sur UDP). Le meilleur de quatre échantillons est retenu pour chaque serveur. Seules des requêtes NTP sont envoyées, et seulement au clic sur Lancer.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if model.servers.isEmpty, let gateway = state.activeInterface?.gateway?.description { model.servers = gateway }
        }
    }

    private var form: some View {
        ToolAdaptiveRow(spacing: 12) {
            ToolLabeledField(label: "Serveurs (\(NTPProbe.maxServers) au plus, séparés par des virgules ou des espaces)") {
                ToolTextField(placeholder: "10.0.0.1, ntp.exemple.ca", text: $model.servers)
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: .infinity)
            }
            ToolLabeledField(label: "Port UDP") {
                HStack(spacing: 10) {
                    ToolTextField(placeholder: "123", text: $model.port, invalid: !model.port.isEmpty && (model.portValue ?? 0) == 0)
                        .frame(width: 76)
                    runButton
                }
            }
        }
    }

    @ViewBuilder private var runButton: some View {
        if model.isRunning {
            ToolStopButton { model.cancel() }
        } else {
            Button { model.run(store: store) } label: { Label("Lancer", systemImage: "play.fill") }
                .buttonStyle(.primary)
                .fixedSize()
                .disabled(model.serverCount == 0)
        }
    }

    @ViewBuilder private var results: some View {
        summary
        NTPResultsTable(rows: model.results, table: table, selection: $model.selection)
        if let result = model.selected {
            detail(result)
        }
        ActionRow {
            Button { ToolActions.copy(NTPFormat.report(model.results)) } label: { Label("Copier le rapport", systemImage: "doc.on.doc") }
                .buttonStyle(.secondary)
        }
    }

    private var summary: some View {
        let verdicts = model.results.map(\.verdict)
        let good = verdicts.filter { $0 == .synchronized }.count
        let notable = verdicts.filter { $0 == .notableOffset }.count
        let bad = verdicts.count - good - notable
        return ToolFlowLayout(spacing: 6, lineSpacing: 6) {
            Chip(text: "\(good) synchronisé\(good > 1 ? "s" : "")", tone: good > 0 ? .success : .neutral)
            Chip(text: "\(notable) décalage\(notable > 1 ? "s" : "") notable\(notable > 1 ? "s" : "")", tone: notable > 0 ? .warning : .neutral)
            Chip(text: "\(bad) en défaut", tone: bad > 0 ? .critical : .neutral)
        }
    }

    private func detail(_ result: NTPServerResult) -> some View {
        let verdict = result.verdict
        return VStack(alignment: .leading, spacing: 10) {
            ToolNotice(tone: verdict.tone, title: title(result), message: NTPFormat.explanation(result))
            if let sample = result.sample {
                ToolCellGrid(cells: cells(result, sample: sample), columns: 4, valueSize: 13, minCellWidth: 170, truncatesLongValues: true)
            }
        }
    }

    private func title(_ result: NTPServerResult) -> String {
        let address = result.address?.description
        return [result.server, address == result.server ? nil : address, result.verdict.label].compactMap { $0 }.joined(separator: " · ")
    }

    private func cells(_ result: NTPServerResult, sample: NTPSample) -> [ToolCell] {
        var cells: [ToolCell] = []
        if sample.hasClock {
            cells += [
                ToolCell(key: "Décalage", value: NTPFormat.offset(sample.offset),
                         detail: sample.offset >= 0 ? "serveur en avance sur ce Mac" : "serveur en retard sur ce Mac"),
                ToolCell(key: "Délai aller-retour", value: NTPFormat.roundTrip(sample.roundTrip), detail: "meilleur des échantillons"),
                ToolCell(key: "Heure du serveur", value: Self.time(sample.serverTime), detail: Self.day(sample.serverTime)),
            ]
        }
        cells += [
            ToolCell(key: "Réponses", value: "\(result.answered) sur \(result.sent)",
                     detail: result.rejected > 0 ? "\(result.rejected) écartée\(result.rejected > 1 ? "s" : "")" : "aucune écartée"),
            ToolCell(key: "Strate", value: "\(sample.stratum)", detail: sample.stratumText),
            ToolCell(key: "Référence", value: sample.referenceID, detail: sample.stratum <= 1 ? "code de la source" : "serveur amont"),
            ToolCell(key: "Indicateur leap", value: "\(sample.leap)", detail: sample.leapText),
            ToolCell(key: "Version · mode", value: "v\(sample.version) · \(sample.mode)", detail: sample.modeText),
            ToolCell(key: "Intervalle (poll)", value: "\(sample.poll)", detail: sample.pollText),
            ToolCell(key: "Précision", value: "\(sample.precision)", detail: sample.precisionText),
            ToolCell(key: "Délai racine", value: NTPFormat.roundTrip(sample.rootDelay), detail: "jusqu’à la source primaire"),
            ToolCell(key: "Dispersion racine", value: NTPFormat.roundTrip(sample.rootDispersion), detail: "erreur maximale annoncée"),
        ]
        return cells
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date) + " (heure locale)"
    }
}

private extension NTPServerResult {
    /// Échantillon qui porte une heure exploitable (colonnes chiffrées vides sinon).
    var timed: NTPSample? { sample?.hasClock == true ? sample : nil }
    var addressSort: UInt32 { address?.value ?? .max }
    var offsetSort: Double { timed.map { abs($0.offset) } ?? .infinity }
    var delaySort: Double { timed?.roundTrip ?? .infinity }
    var stratumSort: Int { sample?.stratum ?? .max }
    var referenceText: String { sample?.referenceID ?? "—" }
    var verdictRank: Int { verdict.rank }
}

/// Résultat par serveur (tableau standard « outils.ntp »).
struct NTPResultsTable: View {
    let rows: [NTPServerResult]
    @ObservedObject var table: StandardTableModel<NTPServerResult>
    @Binding var selection: UUID?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "serveur", title: "Serveur", isRequired: true),
        StandardColumn(id: "adresse", title: "Adresse", isDefaultVisible: false),
        StandardColumn(id: "decalage", title: "Décalage"),
        StandardColumn(id: "delai", title: "Délai"),
        StandardColumn(id: "strate", title: "Strate"),
        StandardColumn(id: "reference", title: "Référence"),
        StandardColumn(id: "verdict", title: "Verdict"),
    ]

    static let sortKeys: [String: KeyPathComparator<NTPServerResult>] = [
        "serveur": KeyPathComparator(\NTPServerResult.server),
        "adresse": KeyPathComparator(\NTPServerResult.addressSort),
        "decalage": KeyPathComparator(\NTPServerResult.offsetSort),
        "delai": KeyPathComparator(\NTPServerResult.delaySort),
        "strate": KeyPathComparator(\NTPServerResult.stratumSort),
        "reference": KeyPathComparator(\NTPServerResult.referenceText),
        "verdict": KeyPathComparator(\NTPServerResult.verdictRank),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<NTPServerResult> {
        StandardTableModel(id: "outils.ntp", columns: columns, sortKeys: sortKeys, defaultSort: "verdict")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: NTPProbe.maxServers) {
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("SERVEUR", sortUsing: table.sort("serveur")) { row in
                    ToolTableText(row.server, mono: false, weight: .medium).help(row.server)
                }
                .width(min: 110, ideal: 126)
                .customizationID("serveur")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("ADRESSE", sortUsing: table.sort("adresse")) { row in
                    ToolTableText(row.address?.description ?? "—", color: Theme.textSecondary)
                }
                .width(min: 92, ideal: 112)
                .customizationID("adresse")
                .defaultVisibility(.hidden)

                TableColumn("DÉCALAGE", sortUsing: table.sort("decalage")) { row in
                    ToolTableText(row.timed.map { NTPFormat.offset($0.offset) } ?? "—", weight: .semibold,
                                  color: row.timed == nil ? Theme.textSecondary : Theme.text)
                }
                .width(min: 84, ideal: 90)
                .customizationID("decalage")

                TableColumn("DÉLAI", sortUsing: table.sort("delai")) { row in
                    ToolTableText(row.timed.map { NTPFormat.roundTrip($0.roundTrip) } ?? "—", color: Theme.textSecondary)
                }
                .width(min: 58, ideal: 62)
                .customizationID("delai")

                TableColumn("STRATE", sortUsing: table.sort("strate")) { row in
                    ToolTableText(row.sample.map { "\($0.stratum)" } ?? "—", color: Theme.textSecondary)
                }
                .width(min: 58, ideal: 60)
                .customizationID("strate")

                TableColumn("RÉFÉRENCE", sortUsing: table.sort("reference")) { row in
                    ToolTableText(row.referenceText, color: Theme.textSecondary).help(row.referenceText)
                }
                .width(min: 84, ideal: 92)
                .customizationID("reference")

                TableColumn("VERDICT", sortUsing: table.sort("verdict")) { row in
                    ToolTableText(row.verdict.label, mono: false, weight: .semibold, color: row.verdict.tone.foreground)
                }
                .width(min: 108, ideal: 116)
                .customizationID("verdict")
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Copier") {
                    ToolActions.copy(NTPFormat.report(rows.filter { ids.contains($0.id) }))
                }
                .disabled(ids.isEmpty)
            }
        }
    }
}
