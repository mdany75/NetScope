import NetScopeCore
import SwiftUI

/// Outil « Navigateur SNMP » (note 59) : hôte, version et identifiants (enregistrés ou saisis),
/// GET, GETNEXT ou parcours d'un OID, raccourcis vers les tables courantes, résultats dans le
/// tableau standard (OID, nom connu, type, valeur), arrêt, limite de lignes, copie et export CSV.
struct SNMPBrowserView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: SNMPBrowserModel
    @ObservedObject var store: ToolStore
    @ObservedObject private var vault = SNMPAccessVault.shared
    @StateObject private var table = SNMPBrowserTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            connectionRow
            credentialsBlock
            requestRow
            presets
            if let error = model.error {
                ToolNotice(tone: .critical, title: "Lecture impossible", message: error)
            }
            results
        }
        .onAppear {
            if model.host.isEmpty {
                model.host = SwitchStore.shared.selectedHost ?? state.selectedDevice?.ip.description ?? ""
            }
        }
        .task { await vault.load() }
    }

    // MARK: Agent et identifiants

    private var connectionRow: some View {
        ToolAdaptiveRow(spacing: 12) {
            ToolLabeledField(label: "Hôte (IP ou nom)") {
                ToolTextField(placeholder: "10.182.122.2", text: $model.host,
                              invalid: !model.host.isEmpty && !model.hostIsValid) { model.run(store: store) }
                    .frame(minWidth: 170, maxWidth: 240)
            }
            ToolLabeledField(label: "Version") {
                Picker("", selection: $model.version) {
                    ForEach(SNMPBrowserModel.Version.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .fixedSize()
            }
            ToolLabeledField(label: "Identifiants") {
                Picker("", selection: $model.source) {
                    ForEach(SNMPBrowserModel.Source.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .controlSize(.large)
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var credentialsBlock: some View {
        if model.source == .saved {
            let summary = model.credentialSummary
            HStack(spacing: 8) {
                Image(systemName: summary.tone == .warning ? "exclamationmark.triangle" : "lock.shield")
                    .font(.system(size: 12, weight: .semibold))
                Text(summary.text).font(Theme.small)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(summary.tone.foreground)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(summary.tone.background))
        } else if model.version == .v2c {
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Communauté (lecture seule)") {
                    SNMPSecureField(placeholder: "communauté", text: $model.community).frame(minWidth: 200, maxWidth: 260)
                }
                Text("Gardée en mémoire le temps de la session, jamais enregistrée. v2c l’envoie en clair\u{00A0}: préférez v3.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                Spacer(minLength: 0)
            }
        } else {
            typedV3
        }
    }

    private var typedV3: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Utilisateur") {
                    ToolTextField(placeholder: "netscope-ro", text: $model.v3User).frame(minWidth: 150, maxWidth: 200)
                }
                ToolLabeledField(label: "Niveau") {
                    Picker("", selection: $model.v3Level) {
                        ForEach(SNMPv3Level.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().controlSize(.large).frame(width: 150)
                }
                ToolLabeledField(label: "Contexte (facultatif)") {
                    ToolTextField(placeholder: "vide", text: $model.v3Context).frame(minWidth: 110, maxWidth: 150)
                }
                Spacer(minLength: 0)
            }
            if model.v3Level != .noAuthNoPriv {
                ToolAdaptiveRow(spacing: 12) {
                    ToolLabeledField(label: "Authentification") {
                        Picker("", selection: $model.v3Auth) {
                            ForEach(SNMPAuthProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().controlSize(.large).frame(width: 120)
                    }
                    ToolLabeledField(label: "Mot de passe auth.") {
                        SNMPSecureField(placeholder: "8 caractères au moins", text: $model.v3AuthPassword).frame(minWidth: 170, maxWidth: 220)
                    }
                    if model.v3Level == .authPriv {
                        ToolLabeledField(label: "Confidentialité") {
                            Picker("", selection: $model.v3Priv) {
                                ForEach(SNMPPrivProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden().controlSize(.large).frame(width: 120)
                        }
                        ToolLabeledField(label: "Mot de passe priv.") {
                            SNMPSecureField(placeholder: "8 caractères au moins", text: $model.v3PrivPassword).frame(minWidth: 170, maxWidth: 220)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            Text("Saisi pour cette session seulement, jamais enregistré. Pour l’enregistrer au Trousseau (par site ou pour tous)\u{00A0}: Réglages › Identifiants.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Requête

    private var requestRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                oidField.frame(minWidth: 260, maxWidth: .infinity)
                operationPicker
                limitPicker
                launch
            }
            VStack(alignment: .leading, spacing: 10) {
                oidField
                HStack(alignment: .bottom, spacing: 12) {
                    operationPicker
                    limitPicker
                    Spacer(minLength: 0)
                    launch
                }
            }
        }
    }

    private var oidField: some View {
        ToolLabeledField(label: "OID ou nom") {
            HStack(spacing: 6) {
                ToolTextField(placeholder: "1.3.6.1.2.1.1 · sysName.0 · ifXTable", text: $model.oidText,
                              invalid: !model.oidText.isEmpty && model.parsedOID == nil) { model.run(store: store) }
                presetMenu
            }
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(SNMPMIB.presets) { preset in
                Button("\(preset.name) — \(preset.summary)") { model.choose(preset) }
            }
            Divider()
            Button("sysName.0 (GET)") { model.oidText = "sysName.0"; model.operation = .get }
            Button("sysUpTime.0 (GET)") { model.oidText = "sysUpTime.0"; model.operation = .get }
        } label: {
            Label("OID courants", systemImage: "list.bullet")
        }
        .menuStyle(.button)
        .controlSize(.large)
        .fixedSize()
        .help("Tables et groupes courants")
    }

    private var operationPicker: some View {
        ToolLabeledField(label: "Opération") {
            Picker("", selection: $model.operation) {
                ForEach(SNMPBrowserOperation.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .fixedSize()
        }
    }

    private var limitPicker: some View {
        ToolLabeledField(label: "Limite") {
            Picker("", selection: $model.limit) {
                ForEach(SNMPBrowserModel.limits, id: \.self) { Text("\(ToolFormat.integer($0)) lignes").tag($0) }
            }
            .labelsHidden()
            .controlSize(.large)
            .fixedSize()
            .disabled(model.operation != .walk)
            .help("Nombre de lignes au plus pour un parcours")
        }
    }

    private var launch: some View {
        HStack(spacing: 10) {
            if model.operation == .walk {
                ToolCheckbox(label: "GETNEXT", isOn: $model.walkWithGetNext)
                    .fixedSize()
                    .help("Parcourir une ligne à la fois (agents anciens) au lieu de GETBULK")
            }
            Group {
                if model.isRunning {
                    Button("Arrêter") { model.stop() }.buttonStyle(.secondary)
                } else {
                    Button(model.operation == .walk ? "Parcourir" : "Lire") { model.run(store: store) }
                        .buttonStyle(.primary)
                        .disabled(!model.hostIsValid || model.parsedOID == nil)
                }
            }
            .fixedSize()
        }
        .padding(.bottom, 4)
    }

    private var presets: some View {
        ToolFlowLayout(spacing: 6) {
            Text("Raccourcis\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(height: 24)
            ForEach(SNMPMIB.presets) { preset in
                ToolChoiceChip(label: preset.name, isSelected: model.parsedOID == preset.oid && model.operation == .walk, mono: false) {
                    model.choose(preset)
                }
                .help("\(preset.summary) · \(preset.oid.description)")
            }
        }
    }

    // MARK: Résultats

    @ViewBuilder private var results: some View {
        let rows = model.rows.sorted(using: table.sortOrder)
        if model.isRunning || model.lastRun != nil || !model.rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        statusLine
                        Spacer(minLength: 8)
                        resultButtons(rows)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        statusLine
                        HStack(spacing: 8) { resultButtons(rows) }
                    }
                }
                if model.isRunning {
                    ProgressBar(fraction: min(1, Double(model.rows.count) / Double(max(1, model.limit))), color: Theme.accent)
                }
                SNMPBrowserTable(rows: rows, table: table, model: model, store: store)
                if let notice = model.notice {
                    Text(notice.text).font(Theme.small).foregroundStyle(notice.tone.foreground)
                }
            }
        } else {
            Text("Choisissez un raccourci ou saisissez un OID (1.3.6.1.2.1.1, sysName.0, IF-MIB::ifDescr), puis lancez la lecture. Le parcours lit toute la sous-arborescence par GETBULK, en v2c comme en v3\u{00A0}; GET et GETNEXT lisent une seule valeur.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if model.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Lecture en cours · \(ToolFormat.integer(model.rows.count)) ligne\(model.rows.count > 1 ? "s" : "") reçue\(model.rows.count > 1 ? "s" : "")")
            }
            .font(Theme.small).foregroundStyle(Theme.textSecondary)
        } else if let run = model.lastRun {
            HStack(spacing: 8) {
                Chip(text: run.wasCancelled ? "Interrompu" : (run.truncated ? "Limite atteinte" : "Terminé"),
                     tone: run.wasCancelled || run.truncated ? .warning : .success)
                Text(runText(run)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runText(_ run: SNMPBrowserModel.RunInfo) -> String {
        let name = SNMPMIB.name(for: run.oid).map { "\($0) (\(run.oid))" } ?? run.oid.description
        var parts = ["\(run.operation.label) de \(name)",
                     "\(ToolFormat.integer(run.count)) ligne\(run.count > 1 ? "s" : "")"]
        if run.duration > 0 { parts.append(ToolFormat.seconds(run.duration)) }
        if run.operation == .walk, run.requests > 0 {
            parts.append("\(run.requests) requête\(run.requests > 1 ? "s" : "") \(run.mode.label)")
        }
        if !run.versionLabel.isEmpty { parts.append("SNMP \(run.versionLabel)") }
        if run.operation == .walk, !run.wasCancelled { parts.append(run.end.label) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func resultButtons(_ rows: [SNMPBrowserRow]) -> some View {
        ToolColumnsMenu(model: table)
        Button { model.copy(rows) } label: { Label("Copier", systemImage: "doc.on.doc") }
            .buttonStyle(.secondary).controlSize(.small)
            .disabled(rows.isEmpty)
        Button { model.exportCSV(rows) } label: { Label("Exporter CSV", systemImage: "square.and.arrow.up") }
            .buttonStyle(.secondary).controlSize(.small)
            .disabled(rows.isEmpty)
    }
}

extension SNMPBrowserModel.RunInfo {
    var truncated: Bool { end == .limit && !wasCancelled }
}

/// Texte de cellule tronqué au milieu : la fin d'un OID (l'index de la ligne) reste visible.
private struct SNMPMiddleText: View {
    let text: String
    var weight: Font.Weight
    var color: Color

    var body: some View {
        Text(text)
            .font(Theme.mono(11, weight: weight))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Champ secret natif (masqué), même hauteur que les champs des outils.
private struct SNMPSecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .font(Theme.mono(13, weight: .medium))
            .accessibilityLabel(placeholder)
    }
}

/// Tableau des résultats (tableau standard « outils.snmp », note 8) : OID, nom connu, type, valeur ;
/// facultatives : rang, MIB, hexadécimal.
struct SNMPBrowserTable: View {
    let rows: [SNMPBrowserRow]
    @ObservedObject var table: StandardTableModel<SNMPBrowserRow>
    @ObservedObject var model: SNMPBrowserModel
    @ObservedObject var store: ToolStore
    @State private var selection = Set<SNMPBrowserRow.ID>()

    static let columns: [StandardColumn] = [
        StandardColumn(id: "rang", title: "Rang", isDefaultVisible: false),
        StandardColumn(id: "oid", title: "OID", isRequired: true),
        StandardColumn(id: "nom", title: "Nom"),
        StandardColumn(id: "mib", title: "MIB", isDefaultVisible: false),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "valeur", title: "Valeur"),
        StandardColumn(id: "hex", title: "Hexadécimal", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<SNMPBrowserRow>] = [
        "rang": KeyPathComparator(\SNMPBrowserRow.position),
        "oid": KeyPathComparator(\SNMPBrowserRow.oidSort),
        "nom": KeyPathComparator(\SNMPBrowserRow.name),
        "mib": KeyPathComparator(\SNMPBrowserRow.mib),
        "type": KeyPathComparator(\SNMPBrowserRow.typeLabel),
        "valeur": KeyPathComparator(\SNMPBrowserRow.valueText),
        "hex": KeyPathComparator(\SNMPBrowserRow.hexText),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<SNMPBrowserRow> {
        StandardTableModel(id: "outils.snmp", columns: columns, sortKeys: sortKeys, defaultSort: "oid")
    }

    var body: some View {
        ToolStandardTableFrame(rowCount: rows.count, maxRows: 16,
                               emptyText: model.isRunning ? "En attente de la réponse de l’agent…" : "Aucune ligne sous cet OID.") {
            Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("#", sortUsing: table.sort("rang")) { row in
                    ToolTableText(String(row.position + 1), size: 11, color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 32, ideal: 44)
                .customizationID("rang")
                .defaultVisibility(.hidden)

                TableColumn("OID", sortUsing: table.sort("oid")) { row in
                    SNMPMiddleText(text: row.oidText, weight: .regular, color: Theme.textSecondary).help(row.oidText)
                }
                .width(min: 120, ideal: 190)
                .customizationID("oid")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                    SNMPMiddleText(text: row.name.isEmpty ? "—" : row.name, weight: .semibold,
                                   color: row.name.isEmpty ? Theme.textTertiary : Theme.text)
                        .help(row.mib.isEmpty ? row.name : "\(row.mib)::\(row.name)")
                }
                .width(min: 120, ideal: 230)
                .customizationID("nom")

                TableColumn("MIB", sortUsing: table.sort("mib")) { row in
                    ToolTableText(row.mib, size: 11, mono: false, color: Theme.textSecondary)
                }
                .width(min: 80, ideal: 130)
                .customizationID("mib")
                .defaultVisibility(.hidden)

                TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                    ToolTableText(row.typeLabel, size: 11, mono: false,
                                  color: row.isException ? Theme.warning : Theme.textSecondary)
                }
                .width(min: 74, ideal: 100)
                .customizationID("type")

                TableColumn("VALEUR", sortUsing: table.sort("valeur")) { row in
                    ToolTableText(row.valueText, size: 11, mono: !row.isException,
                                  color: row.isException ? Theme.warning : Theme.text)
                        .help(row.valueText)
                }
                .width(min: 160, ideal: 360)
                .customizationID("valeur")

                TableColumn("HEXADÉCIMAL", sortUsing: table.sort("hex")) { row in
                    ToolTableText(row.hexText, size: 11, color: Theme.textSecondary)
                }
                .width(min: 100, ideal: 220)
                .customizationID("hex")
                .defaultVisibility(.hidden)
            }
            .contextMenu(forSelectionType: SNMPBrowserRow.ID.self) { ids in
                let chosen = rows.filter { ids.contains($0.id) }
                if !chosen.isEmpty {
                    Button("Copier \(chosen.count > 1 ? "les lignes" : "la ligne")") { model.copy(chosen) }
                    Button("Copier l’OID") { ToolActions.copy(chosen.map(\.oidText).joined(separator: "\n")) }
                    Button("Copier la valeur") { ToolActions.copy(chosen.map(\.valueText).joined(separator: "\n")) }
                    if let row = chosen.first, chosen.count == 1 {
                        Divider()
                        Button("Lire cet OID (GET)") {
                            model.oidText = row.oidText
                            model.operation = .get
                            model.run(store: store)
                        }
                        Button("Parcourir à partir de cet objet") {
                            let object = SNMPMIB.lookup(row.oid)?.object.oid ?? row.oid
                            model.oidText = object.description
                            model.operation = .walk
                            model.run(store: store)
                        }
                    }
                }
            }
        }
    }
}
