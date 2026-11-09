import NetScopeCore
import SwiftUI

/// Test RADIUS (note 117) : un essai PAP par clic, résultat en clair et attributs reçus.
struct RADIUSTestView: View {
    @ObservedObject var model: RADIUSTestModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = RADIUSAttributesTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            form
            ToolNotice(tone: .accent, title: "Ce que cet essai prouve",
                       message: "L’essai se fait en PAP\u{00A0}: il prouve que le serveur, le secret partagé et le compte fonctionnent, mais pas EAP ni PEAP du 802.1X. Utiliser un compte de test\u{00A0}: un échec peut compter dans un verrouillage de compte. Chaque clic fait une seule authentification.")
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            if let notice = model.notice { ToolNotice(tone: notice.tone, message: notice.message) }
            if model.isRunning {
                MailProgressLine(text: "Authentification en cours auprès de \(model.server), 3\u{00A0}envois identiques au plus…")
            } else if let result = model.result {
                results(result)
            }
        }
        .onAppear { model.viewAppeared() }
        .onDisappear { model.viewDisappeared() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Serveur") {
                    ToolTextField(placeholder: "10.0.0.20 ou radius.exemple.ca", text: $model.server)
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: .infinity)
                }
                ToolLabeledField(label: "Port UDP") {
                    ToolTextField(placeholder: "1812", text: $model.port, invalid: !model.port.isEmpty && (model.portValue ?? 0) == 0)
                        .frame(width: 76)
                }
                ToolLabeledField(label: "Secret partagé") {
                    RADIUSSecureField(placeholder: model.hasSavedSecret ? "au Trousseau (laisser vide)" : "à saisir", text: $model.sharedSecret)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: .infinity)
                }
            }
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Compte de test") {
                    ToolTextField(placeholder: "compte.test", text: $model.username)
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: .infinity)
                }
                ToolLabeledField(label: "Mot de passe (jamais conservé)") {
                    HStack(spacing: 10) {
                        RADIUSSecureField(placeholder: "à saisir à chaque essai", text: $model.password)
                            .frame(minWidth: 180, idealWidth: 260, maxWidth: .infinity)
                        Button { model.run(store: store) } label: { Label("Tester", systemImage: "play.fill") }
                            .buttonStyle(.primary)
                            .fixedSize()
                            .disabled(!model.canRun)
                    }
                }
            }
            ActionRow(spacing: 12) {
                Toggle("Mémoriser ce secret au Trousseau pour ce serveur (après une réponse authentifiée)", isOn: $model.rememberSecret)
                    .toggleStyle(.checkbox)
                    .font(Theme.small)
                    .disabled(model.sharedSecret.isEmpty)
                if model.hasSavedSecret {
                    Button { model.forgetSavedSecret() } label: { Label("Oublier le secret mémorisé", systemImage: "trash") }
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func results(_ result: RADIUSResult) -> some View {
        ToolNotice(tone: result.outcome.tone, title: "\(result.server):\(result.port) · \(result.outcome.label)", message: RADIUSFormat.explanation(result))
        if result.responseSigned == false {
            ToolNotice(tone: .warning, message: "La réponse est authentifiée, mais le serveur n’y joint pas de Message-Authenticator\u{00A0}: cet échange reste exposé à l’attaque Blast-RADIUS. L’exiger dans sa configuration si possible.")
        }
        ToolCellGrid(cells: cells(result), columns: 4, valueSize: 13, minCellWidth: 150, truncatesLongValues: true)
        if !result.attributes.isEmpty {
            RADIUSAttributesTable(rows: result.attributes, table: table)
        }
        ActionRow {
            Button { ToolActions.copy(RADIUSFormat.report(result)) } label: { Label("Copier le rapport", systemImage: "doc.on.doc") }
                .buttonStyle(.secondary)
        }
    }

    private func cells(_ result: RADIUSResult) -> [ToolCell] {
        let signature: String
        switch result.responseSigned {
        case .some(true): signature = "valide"
        case .some(false): signature = "absent"
        case .none: signature = "—"
        }
        return [
            ToolCell(key: "Compte", value: result.username),
            ToolCell(key: "Durée", value: ToolFormat.seconds(result.duration)),
            ToolCell(key: "Envois", value: "\(result.sent) sur \(RADIUSClient.maxRetransmits + 1)", detail: "copies exactes, une seule authentification"),
            ToolCell(key: "Signature", value: signature, detail: "Message-Authenticator de la réponse"),
        ]
    }
}

/// Champ secret natif, sans validation par Entrée : rien ne part sans un clic sur Tester.
private struct RADIUSSecureField: View {
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

/// Attributs reçus (tableau standard « outils.radius »).
struct RADIUSAttributesTable: View {
    let rows: [RADIUSAttribute]
    @ObservedObject var table: StandardTableModel<RADIUSAttribute>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "attribut", title: "Attribut", isRequired: true),
        StandardColumn(id: "valeur", title: "Valeur"),
    ]

    static let sortKeys: [String: KeyPathComparator<RADIUSAttribute>] = [
        "attribut": KeyPathComparator(\RADIUSAttribute.name),
        "valeur": KeyPathComparator(\RADIUSAttribute.value),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RADIUSAttribute> {
        StandardTableModel(id: "outils.radius", columns: columns, sortKeys: sortKeys, defaultSort: "attribut")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count) {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("ATTRIBUT", sortUsing: table.sort("attribut")) { row in
                    ToolTableText(row.name, mono: false, weight: .medium).help(row.name)
                }
                .width(min: 150, ideal: 200)
                .customizationID("attribut")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("VALEUR", sortUsing: table.sort("valeur")) { row in
                    ToolTableText(row.value, color: Theme.textSecondary).help(row.value)
                }
                .width(min: 180, ideal: 420)
                .customizationID("valeur")
            }
        }
    }
}
