import NetScopeCore
import SwiftUI

/// Bilan de raccordement (note 58) : un bouton enchaîne lien, switch et port, VLAN, PoE, DHCP,
/// passerelle, DNS et Internet sur la prise où ce Mac est branché ; chaque étape a son état et son
/// explication. Dessous : comparaison avec le bilan « avant » (écarts surlignés) et historique des
/// bilans du site. Mise en page des outils (croquis Toolbox.dc.html : étiquettes en majuscules,
/// encadrés, tableaux standard).
struct LinkCheckView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: LinkCheckModel
    @ObservedObject var store: ToolStore
    @ObservedObject private var sites = SiteModel.shared
    @StateObject private var compareTable = LinkCheckDiffRow.makeModel()
    @StateObject private var historyTable = LinkCheckHistoryRow.makeModel()
    @State private var historySelection: UUID?

    var body: some View {
        let _ = model.revision
        let shown = model.isRunning ? nil : model.shown
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            if model.isRunning {
                runningNotice
            } else if let shown {
                verdict(shown)
            }
            if let toast = model.toast { ToolNotice(tone: .accent, message: toast) }
            if model.isRunning || shown != nil {
                stepsGrid(shown)
            }
            if let shown, !model.isRunning {
                comparison(shown)
            }
            history
            if shown == nil && !model.isRunning {
                Text("Le bilan lit l’état du lien, écoute les annonces LLDP et CDP du switch (35\u{00A0}s au plus), envoie un DHCPDISCOVER (aucun bail n’est pris), pingue la passerelle, résout quelques noms et interroge une adresse neutre (captive.apple.com). Rien n’est modifié sur le Mac ni sur le réseau.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            await model.prepare(active: state.activeInterface)
            // Captures (--snapshot --demo) : NETSCOPE_BILAN_EN_COURS=1 montre un bilan en cours.
            if model.isDemo, !model.isRunning, ProcessInfo.processInfo.environment["NETSCOPE_BILAN_EN_COURS"] == "1" {
                model.run(store: store)
            }
        }
    }

    // MARK: Contrôles

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                interfacePicker
                locationField.frame(minWidth: 200)
                vlanField
                runButton
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    interfacePicker
                    locationField.frame(minWidth: 180)
                    vlanField
                }
                runButton
            }
            VStack(alignment: .leading, spacing: 10) {
                interfacePicker
                locationField
                HStack(alignment: .bottom, spacing: 10) {
                    vlanField
                    runButton
                }
            }
        }
    }

    private var interfacePicker: some View {
        ToolLabeledField(label: "Interface") {
            Picker("", selection: $model.interfaceName) {
                if model.interfaces.isEmpty { Text("aucune interface").tag("") }
                ForEach(model.interfaces, id: \.name) { iface in
                    Text(iface.linkSummary).tag(iface.name)
                }
            }
            .labelsHidden()
            .controlSize(.large)
            .frame(minWidth: 150)
        }
        .fixedSize()
        .disabled(model.isRunning)
    }

    private var locationField: some View {
        ToolLabeledField(label: "Emplacement · site\u{00A0}: \(sites.activeName)") {
            ToolTextField(placeholder: "ex. Bureau 214 · prise B", text: $model.location, mono: false)
        }
        .disabled(model.isRunning)
    }

    private var vlanField: some View {
        ToolLabeledField(label: "VLAN attendu") {
            ToolTextField(placeholder: "facultatif", text: $model.expectedVLANText, invalid: model.vlanInvalid)
                .frame(width: 96)
        }
        .disabled(model.isRunning)
    }

    @ViewBuilder private var runButton: some View {
        if model.isRunning {
            Button("Arrêter") { model.stop() }
                .buttonStyle(.secondary)
                .fixedSize()
        } else {
            Button { model.run(store: store) } label: {
                Label("Lancer le bilan", systemImage: "checklist")
            }
            .buttonStyle(.primary)
            .fixedSize()
            .disabled(model.interfaceName.isEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    // MARK: Bandeau

    private var runningNotice: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bilan en cours sur \(model.interfaceName)… \(model.partial.count)/\(LinkCheckStepKind.allCases.count) étapes")
                        .font(Theme.bodySemibold)
                    Text(model.inProgress.contains(.switchPort)
                         ? "Écoute des annonces LLDP et CDP du switch (35\u{00A0}s au plus) pendant les autres étapes."
                         : "Lecture du lien, DHCP, passerelle, DNS et Internet.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if let start = model.startedAt {
                    Text("\(max(0, Int(context.date.timeIntervalSince(start))))\u{00A0}s")
                        .font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Color(light: 0xBFDBFE, dark: 0x2B5282)))
        }
    }

    private func verdict(_ result: LinkCheckResult) -> some View {
        var details = [ToolText.day(result.date), result.interfaceName + (result.interfaceKind.isEmpty ? "" : " (\(result.interfaceKind))")]
        if !result.location.isEmpty { details.append(result.location) }
        if !result.siteName.isEmpty { details.append(result.siteName) }
        details.append(result.countsLabel)
        details.append("en \(ToolFormat.seconds(result.duration))")
        let isReference = model.history.referenceID == result.id
        return ToolNotice(tone: result.overall.tone, title: result.headline + (isReference ? " · bilan «\u{00A0}avant\u{00A0}»" : ""),
                          message: details.joined(separator: " · ")) {
            HStack(spacing: 8) {
                Button(isReference ? "Retirer «\u{00A0}avant\u{00A0}»" : "Définir comme «\u{00A0}avant\u{00A0}»") {
                    model.setReference(isReference ? nil : result)
                }
                .help("Le bilan «\u{00A0}avant\u{00A0}» sert de référence\u{00A0}: les bilans suivants lui sont comparés.")
                Button(model.isReported(result) ? "Retirer du rapport" : "Ajouter au rapport") { model.toggleReport(result) }
                Menu {
                    Button("Exporter en PDF…") { model.exportPDF(result) }
                    Button("Copier le texte") { model.copyText(result) }
                } label: {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .fixedSize()
        }
    }

    // MARK: Étapes

    private func stepsGrid(_ result: LinkCheckResult?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            ForEach(LinkCheckStepKind.allCases) { kind in
                if let result {
                    stepCard(kind, step: result.step(kind), running: false)
                } else {
                    stepCard(kind, step: model.partial[kind], running: model.inProgress.contains(kind))
                }
            }
        }
    }

    private func stepCard(_ kind: LinkCheckStepKind, step: LinkCheckStep?, running: Bool) -> some View {
        let tone = step?.status.tone ?? .neutral
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(kind.title).font(Theme.bodySemibold)
                Spacer(minLength: 6)
                if let step {
                    Chip(text: step.status.label, tone: tone, systemImage: step.status.symbol)
                } else if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Chip(text: "En attente", tone: .neutral)
                }
            }
            if let step {
                Text(step.summary)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(step.status == .skipped ? Theme.textSecondary : Theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(step.explanation)
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                let facts = step.mainFacts.filter { $0.key != "interface" }.prefix(6)
                if !facts.isEmpty {
                    ToolFlowLayout(spacing: 10, lineSpacing: 3) {
                        ForEach(Array(facts), id: \.key) { fact in
                            (Text(fact.label + " ").foregroundColor(Theme.textTertiary)
                             + Text(fact.value).foregroundColor(Theme.text))
                                .font(Theme.caption)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 1)
                }
            } else {
                Text(running ? "Mesure en cours…" : kind.purpose)
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(alignment: .leading) {
            // Filet de couleur à gauche : l'état de l'étape d'un coup d'œil.
            UnevenRoundedRectangle(topLeadingRadius: Theme.panelRadius, bottomLeadingRadius: Theme.panelRadius)
                .fill(step == nil ? Theme.border : tone.foreground)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .help(kind.purpose)
    }

    // MARK: Avant / après

    @ViewBuilder private func comparison(_ result: LinkCheckResult) -> some View {
        let history = model.history
        let candidates = history.results.filter { $0.id != result.id && $0.date < result.date }
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ToolFieldLabel("Avant / après")
                    Spacer(minLength: 8)
                    comparisonControls(result, candidates: candidates)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ToolFieldLabel("Avant / après")
                    comparisonControls(result, candidates: candidates)
                }
            }
            if let before = model.baseline {
                let all = LinkCheckComparison.compare(before, result)
                let differences = all.filter(\.change.isDifference)
                let rows = LinkCheckDiffRow.rows(model.onlyDifferences ? differences : all).sorted(using: compareTable.sortOrder)
                let improved = differences.filter { $0.change == .improved }.count
                let degraded = differences.filter { $0.change == .degraded }.count
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    (Text("Comparé au bilan du \(LinkCheckText.dateLabel(before.date))" + (before.location.isEmpty ? "" : " (\(before.location))") + "\u{00A0}: ")
                        .foregroundColor(Theme.textSecondary)
                     + Text(LinkCheckComparison.summary(differences)).fontWeight(.semibold))
                        .font(Theme.small)
                        .fixedSize(horizontal: false, vertical: true)
                    if improved > 0 { Chip(text: "\(improved) mieux", tone: .success, systemImage: "arrow.up") }
                    if degraded > 0 { Chip(text: "\(degraded) moins bien", tone: .critical, systemImage: "arrow.down") }
                    Spacer(minLength: 0)
                }
                ToolStandardTableFrame(rowCount: rows.count, maxRows: 16,
                                       emptyText: "Aucun écart\u{00A0}: les deux bilans donnent les mêmes résultats.") {
                    Table(rows, sortOrder: $compareTable.sortOrder, columnCustomization: $compareTable.customization) {
                        TableColumn("ÉTAPE", sortUsing: compareTable.sort("etape")) { row in
                            ToolTableText(row.difference.step.title, mono: false, weight: .semibold)
                        }
                        .width(min: 70, ideal: 90)
                        .customizationID("etape")
                        .disabledCustomizationBehavior(.visibility)

                        TableColumn("ÉLÉMENT", sortUsing: compareTable.sort("element")) { row in
                            ToolTableText(row.difference.label, mono: false)
                        }
                        .width(min: 70, ideal: 120)
                        .customizationID("element")

                        TableColumn("AVANT", sortUsing: compareTable.sort("avant")) { row in
                            ToolTableText(row.difference.before ?? "—", color: Theme.textSecondary)
                                .help(row.difference.before ?? "")
                        }
                        .width(min: 80, ideal: 150)
                        .customizationID("avant")

                        TableColumn("APRÈS", sortUsing: compareTable.sort("apres")) { row in
                            ToolTableText(row.difference.after ?? "—", weight: row.difference.change.isDifference ? .semibold : .regular,
                                          color: row.difference.change.tone == .neutral ? Theme.text : row.difference.change.tone.foreground)
                                .help(row.difference.after ?? "")
                        }
                        .width(min: 80, ideal: 150)
                        .customizationID("apres")

                        TableColumn("ÉCART", sortUsing: compareTable.sort("ecart")) { row in
                            Chip(text: row.difference.change.label, tone: row.difference.change.tone, systemImage: row.difference.change.symbol)
                        }
                        .width(min: 80, ideal: 92)
                        .customizationID("ecart")
                    }
                }
            } else {
                ToolNotice(tone: .accent, title: "Rien à comparer pour l’instant",
                           message: "Avant d’intervenir, lancez un bilan et «\u{00A0}Définissez-le comme «\u{00A0}avant\u{00A0}»\u{00A0}»\u{00A0}; relancez-le après l’intervention\u{00A0}: les écarts (vitesse, port, VLAN, DHCP, pertes, temps de réponse) apparaissent ici, surlignés.")
            }
        }
    }

    private func comparisonControls(_ result: LinkCheckResult, candidates: [LinkCheckResult]) -> some View {
        let referenceID = model.history.referenceID
        return HStack(spacing: 10) {
            if !candidates.isEmpty {
                Text("Comparer avec").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Picker("", selection: Binding(get: { model.compareID ?? model.baseline?.id }, set: { model.compareID = $0 })) {
                    ForEach(candidates) { candidate in
                        Text(LinkCheckText.dateLabel(candidate.date) + (candidate.location.isEmpty ? "" : " · \(candidate.location)")
                             + (candidate.id == referenceID ? " · «\u{00A0}avant\u{00A0}»" : ""))
                            .tag(Optional(candidate.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 300)
                ToolCheckbox(label: "Écarts seulement", isOn: $model.onlyDifferences)
                ToolColumnsMenu(model: compareTable)
            }
        }
        .fixedSize()
    }

    // MARK: Historique

    private var history: some View {
        let results = model.history.results
        let referenceID = model.history.referenceID
        let reported = Set(model.history.reportedIDs)
        let rows = results.map { LinkCheckHistoryRow(result: $0, isReference: $0.id == referenceID, isReported: reported.contains($0.id)) }
            .sorted(using: historyTable.sortOrder)
        let shownID = model.isRunning ? nil : model.shown?.id
        let selection = Binding<UUID?>(get: { shownID }, set: { id in
            if let id { model.shownID = id; model.compareID = nil }
        })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Bilans du site · \(sites.activeName) · \(results.count)")
                Spacer(minLength: 8)
                ToolColumnsMenu(model: historyTable)
            }
            ToolStandardTableFrame(rowCount: rows.count, maxRows: 8,
                                   emptyText: "Aucun bilan sur ce site pour l’instant.") {
                Table(rows, selection: selection, sortOrder: $historyTable.sortOrder, columnCustomization: $historyTable.customization) {
                    TableColumn("DATE", sortUsing: historyTable.sort("date")) { row in
                        HStack(spacing: 5) {
                            ToolTableText(LinkCheckText.dateLabel(row.result.date))
                            if row.isReference { Chip(text: "AVANT", tone: .accent) }
                        }
                    }
                    .width(min: 140, ideal: 180)
                    .customizationID("date")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("EMPLACEMENT", sortUsing: historyTable.sort("emplacement")) { row in
                        ToolTableText(row.result.location.isEmpty ? "—" : row.result.location, mono: false)
                    }
                    .width(min: 80, ideal: 150)
                    .customizationID("emplacement")

                    TableColumn("VERDICT", sortUsing: historyTable.sort("verdict")) { row in
                        Chip(text: row.result.overall.label, tone: row.result.overall.tone)
                    }
                    .width(min: 70, ideal: 92)
                    .customizationID("verdict")

                    TableColumn("SWITCH · PORT · VLAN", sortUsing: historyTable.sort("switch")) { row in
                        ToolTableText(row.switchText).help(row.switchText)
                    }
                    .width(min: 90, ideal: 190)
                    .customizationID("switch")

                    TableColumn("RÉSUMÉ", sortUsing: historyTable.sort("resume")) { row in
                        ToolTableText(row.result.headline, mono: false, color: Theme.textSecondary).help(row.result.headline)
                    }
                    .width(min: 90, ideal: 220)
                    .customizationID("resume")
                    .defaultVisibility(.hidden)

                    TableColumn("INTERFACE", sortUsing: historyTable.sort("interface")) { row in
                        ToolTableText(row.result.interfaceName)
                    }
                    .width(min: 50, ideal: 70)
                    .customizationID("interface")
                    .defaultVisibility(.hidden)

                    TableColumn("RAPPORT", sortUsing: historyTable.sort("rapport")) { row in
                        ToolTableText(row.isReported ? "Oui" : "—", mono: false)
                    }
                    .width(min: 50, ideal: 64)
                    .customizationID("rapport")
                    .defaultVisibility(.hidden)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let result = results.first(where: { $0.id == id }) {
                        Button("Afficher") { model.shownID = id; model.compareID = nil }
                        if let shown = model.shown, shown.id != id, result.date < shown.date {
                            Button("Comparer le bilan affiché à celui-ci") { model.compareID = id }
                        }
                        Divider()
                        Button(id == referenceID ? "Retirer «\u{00A0}avant\u{00A0}»" : "Définir comme «\u{00A0}avant\u{00A0}»") {
                            model.setReference(id == referenceID ? nil : result)
                        }
                        Button(reported.contains(id) ? "Retirer du rapport" : "Ajouter au rapport") { model.toggleReport(result) }
                        Button("Exporter en PDF…") { model.exportPDF(result) }
                        Button("Copier le texte") { model.copyText(result) }
                        Divider()
                        Button("Retirer de l’historique") { model.remove(result) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { model.shownID = id; model.compareID = nil }
                }
            }
        }
    }
}

// MARK: - Lignes des tableaux

struct LinkCheckDiffRow: Identifiable {
    let id: String
    let order: Int
    let difference: LinkCheckDifference

    var sortStep: Int { order }
    var sortElement: String { difference.label.lowercased() }
    var sortBefore: String { difference.before?.lowercased() ?? "~" }
    var sortAfter: String { difference.after?.lowercased() ?? "~" }
    /// Moins bien d'abord, puis mieux, puis les changements.
    var sortChange: Int {
        switch difference.change {
        case .degraded: return 0
        case .improved: return 1
        case .changed, .added, .removed: return 2
        case .same: return 3
        }
    }

    static func rows(_ differences: [LinkCheckDifference]) -> [LinkCheckDiffRow] {
        differences.enumerated().map { LinkCheckDiffRow(id: $0.element.id, order: $0.offset, difference: $0.element) }
    }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "etape", title: "Étape", isRequired: true),
        StandardColumn(id: "element", title: "Élément"),
        StandardColumn(id: "avant", title: "Avant"),
        StandardColumn(id: "apres", title: "Après"),
        StandardColumn(id: "ecart", title: "Écart"),
    ]

    static let sortKeys: [String: KeyPathComparator<LinkCheckDiffRow>] = [
        "etape": KeyPathComparator(\LinkCheckDiffRow.sortStep),
        "element": KeyPathComparator(\LinkCheckDiffRow.sortElement),
        "avant": KeyPathComparator(\LinkCheckDiffRow.sortBefore),
        "apres": KeyPathComparator(\LinkCheckDiffRow.sortAfter),
        "ecart": KeyPathComparator(\LinkCheckDiffRow.sortChange),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<LinkCheckDiffRow> {
        StandardTableModel(id: "outils.bilan.comparaison", columns: columns, sortKeys: sortKeys, defaultSort: "etape")
    }
}

struct LinkCheckHistoryRow: Identifiable {
    let result: LinkCheckResult
    let isReference: Bool
    let isReported: Bool

    var id: UUID { result.id }
    var switchText: String {
        var parts: [String] = []
        if let sp = result.switchPort { parts.append(sp) }
        if let vlan = result.vlan { parts.append("VLAN \(vlan)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    var sortDate: Date { result.date }
    var sortLocation: String { result.location.isEmpty ? "~" : result.location.lowercased() }
    var sortVerdict: Int { -result.overall.rank }
    var sortSwitch: String { switchText.lowercased() }
    var sortSummary: String { result.headline.lowercased() }
    var sortInterface: String { result.interfaceName }
    var sortReported: Int { isReported ? 0 : 1 }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "date", title: "Date", isRequired: true),
        StandardColumn(id: "emplacement", title: "Emplacement"),
        StandardColumn(id: "verdict", title: "Verdict"),
        StandardColumn(id: "switch", title: "Switch · port · VLAN"),
        StandardColumn(id: "resume", title: "Résumé", isDefaultVisible: false),
        StandardColumn(id: "interface", title: "Interface", isDefaultVisible: false),
        StandardColumn(id: "rapport", title: "Rapport", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<LinkCheckHistoryRow>] = [
        "date": KeyPathComparator(\LinkCheckHistoryRow.sortDate),
        "emplacement": KeyPathComparator(\LinkCheckHistoryRow.sortLocation),
        "verdict": KeyPathComparator(\LinkCheckHistoryRow.sortVerdict),
        "switch": KeyPathComparator(\LinkCheckHistoryRow.sortSwitch),
        "resume": KeyPathComparator(\LinkCheckHistoryRow.sortSummary),
        "interface": KeyPathComparator(\LinkCheckHistoryRow.sortInterface),
        "rapport": KeyPathComparator(\LinkCheckHistoryRow.sortReported),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<LinkCheckHistoryRow> {
        StandardTableModel(id: "outils.bilan.historique", columns: columns, sortKeys: sortKeys, defaultSort: "date", defaultAscending: false)
    }
}

// MARK: - Apparence

extension LinkCheckStatus {
    var tone: Tone {
        switch self {
        case .ok: return .success
        case .warning: return .warning
        case .failure: return .critical
        case .skipped: return .neutral
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark"
        case .skipped: return "minus"
        }
    }
}

extension LinkCheckDifference.Change {
    var tone: Tone {
        switch self {
        case .improved: return .success
        case .degraded: return .critical
        case .changed, .added, .removed: return .warning
        case .same: return .neutral
        }
    }

    var symbol: String? {
        switch self {
        case .improved: return "arrow.up"
        case .degraded: return "arrow.down"
        case .changed, .added, .removed: return "arrow.left.arrow.right"
        case .same: return nil
        }
    }
}

extension LinkCheckStepKind {
    var symbol: String {
        switch self {
        case .lien: return "cable.connector.horizontal"
        case .switchPort: return "rectangle.connected.to.line.below"
        case .vlan: return "square.stack.3d.up"
        case .poe: return "bolt"
        case .dhcp: return "shield.lefthalf.filled"
        case .passerelle: return "arrow.triangle.branch"
        case .dns: return "globe"
        case .internet: return "network"
        }
    }
}
