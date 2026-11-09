import AppKit
import NetScopeCore
import SwiftUI

/// Testeur HTTP ou API (note 116) : la requête est composée ici et ne part que sur clic.
struct HTTPTesterView: View {
    @ObservedObject var model: HTTPTesterModel
    @ObservedObject var store: ToolStore
    @StateObject private var headersTable = HTTPResponseHeadersTable.makeModel()
    @State private var headerSelection = Set<Int>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            requestLine
            options
            requestHeaders
            requestBody
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            if model.isRunning { MailProgressLine(text: "Requête \(model.method.rawValue) en cours…") }
            if let result = model.result, !model.isRunning {
                Divider()
                response(result)
            } else if !model.isRunning, model.error == nil {
                Text("Rien ne part avant le clic sur «\u{00A0}Envoyer\u{00A0}». Un code 4xx ou 5xx est une réponse du serveur, affichée comme les autres. Les en-têtes et le corps saisis ne sont pas enregistrés\u{00A0}; l’historique ne garde que la méthode et l’URL, secrets masqués.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Requête

    private var requestLine: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ToolLabeledField(label: "Méthode") {
                Picker("Méthode", selection: $model.method) {
                    ForEach(HTTPMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .fixedSize()
                // Même hauteur que le champ voisin : les deux étiquettes restent alignées.
                .frame(height: 30)
            }
            ToolLabeledField(label: "URL") {
                ToolTextField(placeholder: "https://10.0.0.1/api/v2/etat", text: $model.url)
            }
            sendButton
        }
    }

    @ViewBuilder private var sendButton: some View {
        if model.isRunning {
            ToolStopButton { model.cancel() }
        } else {
            Button { model.send(store: store) } label: { Label("Envoyer", systemImage: "paperplane") }
                .buttonStyle(.primary)
                .fixedSize()
                .disabled(model.url.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var options: some View {
        ToolFlowLayout(spacing: 16, lineSpacing: 8) {
            ToolCheckbox(label: "Suivre les redirections", isOn: $model.followRedirects)
            ToolCheckbox(label: "Accepter un certificat non vérifié", isOn: $model.acceptsUntrustedCertificate)
                .help("Pour un appareil au certificat auto-signé. L’échange reste chiffré, mais l’identité du serveur n’est pas vérifiée.")
            HStack(spacing: 6) {
                Text("Délai").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Picker("Délai", selection: $model.timeout) {
                    ForEach(HTTPTesterModel.timeouts, id: \.self) { Text("\(Int($0))\u{00A0}s").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private var requestHeaders: some View {
        DisclosureGroup(isExpanded: $model.showsHeaders) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($model.headers) { $header in
                    HStack(spacing: 8) {
                        ToolTextField(placeholder: "Nom", text: $header.name, height: 26).frame(width: 200)
                        ToolTextField(placeholder: "Valeur", text: $header.value, height: 26)
                        Button { model.removeHeader(header.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Retirer cet en-tête")
                    }
                }
                ActionRow {
                    Button { model.addHeader() } label: { Label("Ajouter un en-tête", systemImage: "plus") }
                        .buttonStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            sectionTitle("En-têtes de la requête" + (model.headerCount > 0 ? " (\(model.headerCount))" : ""))
        }
    }

    private var requestBody: some View {
        DisclosureGroup(isExpanded: $model.showsBody) {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $model.body)
                    .font(Theme.mono(12))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .padding(6)
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
                Text(model.method.allowsBody
                     ? "Un corps JSON part en application/json si aucun en-tête Content-Type n’est indiqué."
                     : "\(model.method.rawValue) n’envoie pas de corps\u{00A0}: choisir POST, PUT, PATCH, DELETE ou OPTIONS.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 8)
        } label: {
            sectionTitle("Corps de la requête" + (model.body.isEmpty ? "" : " (\(HTTPFormat.size(model.body.utf8.count)))"))
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(Theme.bodySemibold).foregroundStyle(Theme.text)
    }

    // MARK: Réponse

    @ViewBuilder private func response(_ result: HTTPResponseResult) -> some View {
        headline(result)
        if let target = result.unfollowedRedirect {
            ToolNotice(tone: .warning, title: "Redirection non suivie",
                       message: "Le corps de la requête aurait quitté l’adresse saisie pour \(HTTPRedaction.maskedURL(target)). Si c’est voulu, envoyer la requête directement à cette adresse.")
        }
        // 4 ou 2 colonnes : à 3, une case resterait seule sur sa rangée.
        ViewThatFits(in: .horizontal) {
            ToolCellGrid(cells: cells(result), columns: 4, valueSize: 13, minCellWidth: 170, truncatesLongValues: true).frame(minWidth: 680)
            ToolCellGrid(cells: cells(result), columns: 2, valueSize: 13, minCellWidth: 170, truncatesLongValues: true)
        }
        if !result.redirects.isEmpty { redirects(result) }
        HStack(spacing: 12) {
            Picker("Partie de la réponse", selection: $model.responseTab) {
                ForEach(HTTPTesterModel.ResponseTab.allCases) { tab in
                    Text(tab == .headers ? "\(tab.rawValue) (\(result.headers.count))" : tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer(minLength: 0)
            if model.responseTab == .body, result.formattedBody != nil {
                Picker("Présentation", selection: $model.showsFormattedBody) {
                    Text("JSON présenté").tag(true)
                    Text("Brut").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        switch model.responseTab {
        case .body: bodyTab(result)
        case .headers: headersTab(result)
        case .timings: timingsTab(result)
        }
    }

    private func headline(_ result: HTTPResponseResult) -> some View {
        let tone = Self.tone(result.statusCode)
        return VStack(alignment: .leading, spacing: 6) {
            ToolFieldLabel("Réponse")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(result.statusCode) \(result.statusText)")
                    .font(Theme.mono(20, weight: .semibold))
                    .foregroundStyle(tone == .success ? Theme.text : tone.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                Chip(text: Self.category(result.statusCode), tone: tone)
                Spacer(minLength: 0)
            }
            Text(HTTPRedaction.maskedURL(result.finalURL.absoluteString))
                .font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .help(HTTPRedaction.maskedURL(result.finalURL.absoluteString))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func cells(_ result: HTTPResponseResult) -> [ToolCell] {
        [
            ToolCell(key: "Temps total", value: PingFormat.ms(result.timings.total),
                     detail: "premier octet\u{00A0}: \(PingFormat.ms(result.timings.firstByte))"),
            ToolCell(key: "Taille du corps", value: HTTPFormat.bodySize(result), detail: result.isTruncated ? "aperçu de \(HTTPFormat.size(result.bodyPreview.count))" : "reçu en entier"),
            ToolCell(key: "Type de contenu", value: result.contentType.map { String($0.prefix { $0 != ";" }) } ?? "—", detail: result.version),
            ToolCell(key: "IP distante", value: result.remoteAddress ?? "—", detail: result.redirects.isEmpty ? "aucune redirection" : "après \(result.redirects.count) redirection\(result.redirects.count > 1 ? "s" : "")"),
        ]
    }

    private func redirects(_ result: HTTPResponseResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolFieldLabel("Redirections suivies")
            ForEach(Array(result.redirects.enumerated()), id: \.offset) { _, hop in
                HStack(spacing: 8) {
                    Chip(text: "\(hop.statusCode)", tone: .accent, mono: true)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    Text(HTTPRedaction.maskedURL(hop.target))
                        .font(Theme.mono(12)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private func bodyTab(_ result: HTTPResponseResult) -> some View {
        if result.bodySize == 0 {
            ToolNotice(tone: .neutral, message: "Aucun corps dans cette réponse.")
        } else if result.isBinary {
            ToolNotice(tone: .neutral, message: "Corps binaire (\(result.contentType ?? "type inconnu"), \(HTTPFormat.bodySize(result)))\u{00A0}: pas d’aperçu texte.")
        } else {
            let text = shownBody(result)
            VStack(alignment: .leading, spacing: 8) {
                HTTPBodyTextView(text: text)
                    .frame(height: 300)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
                if result.isTruncated {
                    Text("Aperçu limité à \(HTTPFormat.size(result.bodyPreview.count)) sur \(HTTPFormat.bodySize(result)).")
                        .font(Theme.caption).foregroundStyle(Theme.warning)
                }
                ActionRow {
                    Button { ToolActions.copy(text) } label: { Label("Copier le corps", systemImage: "doc.on.doc") }
                        .buttonStyle(.secondary)
                }
            }
        }
    }

    private func shownBody(_ result: HTTPResponseResult) -> String {
        model.showsFormattedBody ? (result.formattedBody ?? result.bodyText) : result.bodyText
    }

    private func headersTab(_ result: HTTPResponseResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HTTPResponseHeadersTable(rows: result.headers.enumerated().map { HTTPHeaderRow(index: $0.offset, header: $0.element) },
                                     table: headersTable, selection: $headerSelection)
            ActionRow {
                Button { ToolActions.copy(result.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")) } label: {
                    Label("Copier les en-têtes", systemImage: "doc.on.doc")
                }
                .buttonStyle(.secondary)
            }
        }
    }

    private func timingsTab(_ result: HTTPResponseResult) -> some View {
        let timings = result.timings
        let rows: [(String, Double?, String)] = [
            ("DNS", timings.dns, timings.connectIncludesDNS ? "non mesuré, compté dans la ligne suivante" : "aucune résolution (adresse IP ou connexion réutilisée)"),
            (timings.connectIncludesDNS ? "DNS + TCP" : "Connexion TCP", timings.connect, "connexion réutilisée"),
            ("TLS", timings.tls, "sans TLS"),
            ("Premier octet", timings.firstByte, "non mesuré"),
            ("Total", timings.total, ""),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 10) {
                        Text(row.0).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 96, alignment: .leading)
                        Text(PingFormat.ms(row.1)).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).frame(width: 84, alignment: .trailing)
                        if let value = row.1 {
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                                    .frame(width: max(2, geometry.size.width * min(value / max(timings.total, 0.001), 1)), height: 8)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                        } else {
                            Text(row.2).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            Text("DNS, TCP et TLS\u{00A0}: durée de l’étape. Premier octet\u{00A0}: compté depuis le début de la requête" + (result.redirects.isEmpty ? "." : " finale. Total\u{00A0}: redirections comprises."))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private static func tone(_ code: Int) -> Tone {
        switch code {
        case 200..<300: return .success
        case 300..<400: return .accent
        case 400..<500: return .warning
        case 500...: return .critical
        default: return .neutral
        }
    }

    private static func category(_ code: Int) -> String {
        switch code {
        case 200..<300: return "Succès"
        case 300..<400: return "Redirection"
        case 400..<500: return "Erreur côté client"
        case 500...: return "Erreur du serveur"
        default: return "Information"
        }
    }
}

enum HTTPFormat {
    static func size(_ bytes: Int) -> String { TFTPFormat.bytes(Int64(bytes)) }

    static func bodySize(_ result: HTTPResponseResult) -> String {
        (result.isSizeExact ? "" : "au moins ") + size(result.bodySize)
    }
}

/// `Text` et `TextEditor` peinent sur 2 Mio : une vue texte de macOS en lecture seule, à mise en page partielle.
private struct HTTPBodyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textColor = .labelColor
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.textContainerInset = NSSize(width: 6, height: 8)
            view.layoutManager?.allowsNonContiguousLayout = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        // Après la mise en page : sinon le premier élargissement laisse la vue en bas du corps.
        DispatchQueue.main.async { view.scroll(.zero) }
    }
}

struct HTTPHeaderRow: Identifiable {
    let index: Int
    let header: HTTPHeader

    var id: Int { index }
    var name: String { header.name }
    var value: String { header.value }
}

/// En-têtes de la réponse (tableau standard « outils.http.entetes »).
struct HTTPResponseHeadersTable: View {
    let rows: [HTTPHeaderRow]
    @ObservedObject var table: StandardTableModel<HTTPHeaderRow>
    @Binding var selection: Set<Int>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "valeur", title: "Valeur"),
    ]

    static let sortKeys: [String: KeyPathComparator<HTTPHeaderRow>] = [
        "nom": KeyPathComparator(\HTTPHeaderRow.name),
        "valeur": KeyPathComparator(\HTTPHeaderRow.value),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<HTTPHeaderRow> {
        StandardTableModel(id: "outils.http.entetes", columns: columns, sortKeys: sortKeys, defaultSort: "nom")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 12) {
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                    ToolTableText(row.name, weight: .semibold)
                }
                .width(min: 120, ideal: 210, max: 320)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("VALEUR", sortUsing: table.sort("valeur")) { row in
                    ToolTableText(row.value, color: Theme.textSecondary).help(row.value)
                }
                .width(min: 160, ideal: 520)
                .customizationID("valeur")
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Copier") {
                    ToolActions.copy(rows.filter { ids.contains($0.index) }.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                }
                .disabled(ids.isEmpty)
            }
        }
    }
}
