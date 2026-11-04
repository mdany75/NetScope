import NetScopeCore
import SwiftUI

/// Diagnostic SMTP : état conservé par la boîte à outils (ToolStore).
@MainActor
final class ToolSMTPModel: ObservableObject {
    @Published var target = ""
    @Published var port: UInt16 = 25
    /// Tester chaque MX du domaine (trois au plus), sinon le premier seulement.
    @Published var allMX = true
    @Published private(set) var isRunning = false
    @Published private(set) var progress: String?
    @Published private(set) var results: [SMTPDiagnosticResult] = []
    @Published var selectedID: String?
    @Published var error: String?
    private var generation = 0

    static let maxServers = 3

    init() {
        // Démonstration (--demo) : résultats fixes (DevTools/MailDNSDemo.swift), aucune connexion.
        if Launcher.isDemo {
            target = MailDNSDemo.smtpTarget
            results = MailDNSDemo.smtpResults()
            selectedID = results.first?.id
        }
    }

    var selected: SMTPDiagnosticResult? { results.first { $0.id == selectedID } ?? results.first }

    /// Commande équivalente (en-tête de l'outil).
    var command: String {
        var host = target.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { host = "<serveur>" }
        if let first = results.first, results.count >= 1, first.host != host { host = first.host }
        return port == 465 ? "openssl s_client -connect \(host):465 -crlf"
                           : "openssl s_client -starttls smtp -connect \(host):\(port) -crlf"
    }

    func run(store: ToolStore) {
        let text = target.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { error = "Saisir un domaine, un serveur ou une adresse IP."; return }
        guard text.range(of: "^[A-Za-z0-9@._-]+$", options: .regularExpression) != nil else {
            error = "« \(text) » n’est pas un domaine, un nom de serveur ou une adresse valide."
            return
        }
        error = nil
        isRunning = true
        results = []
        selectedID = nil
        generation += 1
        let run = generation
        let port = self.port
        let limit = allMX ? Self.maxServers : 1
        Task {
            defer {
                if run == self.generation {
                    self.isRunning = false
                    self.progress = nil
                }
            }
            if Launcher.isDemo {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard run == self.generation else { return }
                self.results = MailDNSDemo.smtpResults()
                self.selectedID = self.results.first?.id
                self.finish(text, store: store)
                return
            }
            do {
                self.progress = "Recherche des serveurs de courriel…"
                let targets = try await SMTPDiagnostic.targets(for: text)
                guard run == self.generation else { return }
                guard !targets.isEmpty else {
                    self.error = "Le domaine publie un MX nul (« 0 . »)\u{00A0}: il refuse tout courriel."
                    store.record(ToolRecent(tool: .smtp, target: text, summary: "MX nul", status: .warning))
                    return
                }
                let chosen = Array(targets.prefix(limit))
                store.record(command: port == 465 ? "openssl s_client -connect \(chosen[0].host):465 -crlf"
                                                  : "openssl s_client -starttls smtp -connect \(chosen[0].host):\(port) -crlf")
                for (index, target) in chosen.enumerated() {
                    self.progress = "Test de \(target.host):\(port)" + (chosen.count > 1 ? " (\(index + 1) sur \(chosen.count))…" : "…")
                    let result = await SMTPDiagnostic.run(host: target.host, port: port, preference: target.preference)
                    guard run == self.generation else { return }
                    self.results.append(result)
                    if self.selectedID == nil { self.selectedID = result.id }
                }
                self.finish(text, store: store)
            } catch {
                guard run == self.generation else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                store.record(ToolRecent(tool: .smtp, target: text, summary: self.error ?? "Échec", status: .failure))
            }
        }
    }

    private func finish(_ text: String, store: ToolStore) {
        guard let worst = results.max(by: { $0.verdict < $1.verdict }) else { return }
        let first = worst.findings.first { $0.level == worst.verdict }?.title ?? "Correct"
        let summary = (results.count > 1 ? "\(results.count) serveurs · " : "") + first
        store.record(ToolRecent(tool: .smtp, target: "\(text):\(port)", summary: summary, status: worst.verdict.recentStatus))
    }
}

/// Diagnostic SMTP d'un serveur ou des MX d'un domaine : bannière, EHLO, STARTTLS, certificat,
/// temps de chaque étape. Aucun courriel envoyé.
struct SMTPDiagnosticView: View {
    @ObservedObject var model: ToolSMTPModel
    @ObservedObject var store: ToolStore
    @StateObject private var serversTable = SMTPServerTable.makeModel()
    @StateObject private var stepsTable = SMTPStepTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolAdaptiveRow {
                ToolLabeledField(label: "Domaine, serveur ou adresse IP") {
                    ToolTextField(placeholder: "exemple.ca, mx1.exemple.ca, 203.0.113.25", text: $model.target) { model.run(store: store) }
                        .frame(minWidth: 200)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    ToolLabeledField(label: "Port") {
                        Picker("Port", selection: $model.port) {
                            Text("25 · réception").tag(UInt16(25))
                            Text("587 · envoi").tag(UInt16(587))
                            Text("465 · TLS").tag(UInt16(465))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.large)
                        .fixedSize()
                    }
                    Button(model.isRunning ? "Diagnostic…" : "Diagnostiquer") { model.run(store: store) }
                        .buttonStyle(.primary)
                        .disabled(model.isRunning)
                        .fixedSize()
                }
            }
            HStack(spacing: 12) {
                ToolCheckbox(label: "Tester chaque MX du domaine (\(ToolSMTPModel.maxServers) au plus)", isOn: $model.allMX)
                Spacer(minLength: 8)
                if let progress = model.progress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            if model.results.count > 1 {
                ToolSectionHeader(title: "Serveurs de courriel") { ToolColumnsMenu(model: serversTable) }
                SMTPServerTable(rows: model.results, selection: $model.selectedID, table: serversTable)
            }
            if let result = model.selected {
                detail(result)
            } else if model.error == nil && !model.isRunning {
                Text("Un domaine est testé par ses serveurs MX (par ordre de préférence) ; un nom de serveur ou une adresse IP est testé directement. Seules les commandes EHLO, STARTTLS et QUIT sont envoyées\u{00A0}: aucun courriel n’est envoyé et aucun test de relais ouvert n’est fait.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func detail(_ result: SMTPDiagnosticResult) -> some View {
        ToolNotice(tone: result.verdict.tone, title: "\(result.host):\(result.port) · \(verdictTitle(result))",
                   message: verdictMessage(result))
        ToolCellGrid(cells: cells(result), columns: 3, valueSize: 13, minCellWidth: 180, truncatesLongValues: true)
        ToolSectionHeader("Constats")
        ToolFindingList(findings: result.findings)
        ToolSectionHeader(title: "Étapes") {
            Text("Total\u{00A0}: \(ToolFormat.milliseconds(result.totalMs))").font(Theme.small).foregroundStyle(Theme.textSecondary)
            ToolColumnsMenu(model: stepsTable)
        }
        SMTPStepTable(rows: SMTPStepRow.rows(of: result), table: stepsTable)
        if !result.allExtensions.isEmpty {
            ToolSectionHeader(title: "Extensions annoncées") {
                if result.mode == .startTLS && !result.extensionsAfterTLS.isEmpty {
                    Text("en clair puis après STARTTLS").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            extensions(result)
        }
        if !result.transcript.isEmpty {
            ToolSectionHeader(title: "Échange avec le serveur") {
                Button("Copier l’échange") { ToolActions.copy(result.transcriptText) }.buttonStyle(.ghost)
            }
            SMTPTranscriptView(lines: result.transcript)
        }
    }

    private func verdictTitle(_ result: SMTPDiagnosticResult) -> String {
        switch result.verdict {
        case .critical: return "problème à corriger"
        case .warning: return "à améliorer"
        case .info, .ok: return "correct"
        }
    }

    private func verdictMessage(_ result: SMTPDiagnosticResult) -> String {
        var parts: [String] = []
        if let software = result.software { parts.append(software) }
        switch result.tls {
        case .succeeded: parts.append("chiffré" + (result.tlsVersion.map { " (\($0))" } ?? ""))
        case .notOffered: parts.append("sans chiffrement")
        case .failed: parts.append("échec du chiffrement")
        case .notReached: break
        }
        let problems = result.findings.filter { $0.level >= .warning }.count
        parts.append(problems == 0 ? "aucun problème" : "\(problems) point\(problems > 1 ? "s" : "") à voir")
        parts.append("\(ToolFormat.milliseconds(result.totalMs)) au total")
        return parts.joined(separator: " · ")
    }

    private func cells(_ result: SMTPDiagnosticResult) -> [ToolCell] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd"
        var cells = [
            ToolCell(key: "Adresse IP", value: result.address ?? "—", detail: result.preference.map { "MX, préférence \($0)" }),
            ToolCell(key: "DNS inverse", value: result.ptrNames.first ?? "aucun",
                     detail: result.ptrConfirmed.map { $0 ? "confirmé (⇄ même adresse)" : "non confirmé" }),
            ToolCell(key: "Bannière", value: result.banner.map { "\($0.code) \($0.firstLine)" } ?? "—", detail: result.software),
            ToolCell(key: "Chiffrement", value: result.tls == .succeeded ? (result.tlsVersion ?? "TLS") : result.tls.label,
                     detail: result.cipher ?? (result.mode == .implicit ? "TLS direct (port 465)" : "STARTTLS")),
        ]
        if let certificate = result.certificate {
            let days = certificate.daysLeft()
            cells += [
                ToolCell(key: "Certificat", value: certificate.subject, detail: certificate.isSelfSigned ? "auto-signé" : (certificate.isTrusted ? "approuvé par macOS" : "non approuvé")),
                ToolCell(key: "Émetteur", value: certificate.issuer.isEmpty ? "—" : certificate.issuer),
                ToolCell(key: "Valide jusqu’au", value: certificate.notAfter.map(formatter.string(from:)) ?? "—",
                         detail: days.map { $0 < 0 ? "expiré depuis \(-$0)\u{00A0}j" : "encore \($0)\u{00A0}j" }),
                ToolCell(key: "Noms couverts", value: certificate.dnsNames.prefix(3).joined(separator: ", "),
                         detail: certificate.dnsNames.count > 3 ? "et \(certificate.dnsNames.count - 3) autres" : nil),
            ]
        }
        return cells
    }

    private func extensions(_ result: SMTPDiagnosticResult) -> some View {
        let afterTLS = Set(result.extensionsAfterTLS.map(\.keyword))
        let clear = Set(result.extensions.map(\.keyword))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10, alignment: .topLeading)], alignment: .leading, spacing: 6) {
            ForEach(result.allExtensions) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Chip(text: item.keyword, tone: item.isConcern ? .warning : .neutral, mono: true)
                    Text(item.explanation + (result.mode == .startTLS && afterTLS.contains(item.keyword) && !clear.contains(item.keyword) ? " (après STARTTLS)" : ""))
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Tableau des serveurs

/// Serveurs testés (tableau standard « outils.smtp.serveurs ») : un MX par ligne.
struct SMTPServerTable: View {
    let rows: [SMTPDiagnosticResult]
    @Binding var selection: String?
    @ObservedObject var table: StandardTableModel<SMTPDiagnosticResult>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "preference", title: "Préférence"),
        StandardColumn(id: "serveur", title: "Serveur", isRequired: true),
        StandardColumn(id: "ip", title: "IP"),
        StandardColumn(id: "logiciel", title: "Logiciel", isDefaultVisible: false),
        StandardColumn(id: "tls", title: "Chiffrement"),
        StandardColumn(id: "temps", title: "Temps"),
        StandardColumn(id: "bilan", title: "Bilan"),
        StandardColumn(id: "ptr", title: "DNS inverse", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<SMTPDiagnosticResult>] = [
        "preference": KeyPathComparator(\SMTPDiagnosticResult.sortPreference),
        "serveur": KeyPathComparator(\SMTPDiagnosticResult.host),
        "ip": KeyPathComparator(\SMTPDiagnosticResult.sortAddress),
        "logiciel": KeyPathComparator(\SMTPDiagnosticResult.sortSoftware),
        "tls": KeyPathComparator(\SMTPDiagnosticResult.sortTLS),
        "temps": KeyPathComparator(\SMTPDiagnosticResult.totalMs),
        "bilan": KeyPathComparator(\SMTPDiagnosticResult.sortVerdict),
        "ptr": KeyPathComparator(\SMTPDiagnosticResult.sortPTR),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<SMTPDiagnosticResult> {
        StandardTableModel(id: "outils.smtp.serveurs", columns: columns, sortKeys: sortKeys, defaultSort: "preference")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count) {
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("MX", sortUsing: table.sort("preference")) { row in
                    ToolTableText(row.preference.map(String.init) ?? "—", color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 30, ideal: 36)
                .customizationID("preference")

                TableColumn("SERVEUR", sortUsing: table.sort("serveur")) { row in
                    ToolTableText(row.host, weight: .medium).help(row.host)
                }
                .width(min: 110, ideal: 130)
                .customizationID("serveur")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("IP", sortUsing: table.sort("ip")) { row in
                    ToolTableText(row.address ?? "—", color: Theme.textSecondary)
                }
                .width(min: 86, ideal: 96)
                .customizationID("ip")

                TableColumn("LOGICIEL", sortUsing: table.sort("logiciel")) { row in
                    ToolTableText(row.software ?? "—", mono: false, color: Theme.textSecondary)
                }
                .width(min: 70, ideal: 100)
                .customizationID("logiciel")
                .defaultVisibility(.hidden)

                TableColumn("CHIFFREMENT", sortUsing: table.sort("tls")) { row in
                    Chip(text: row.tls == .succeeded ? (row.tlsVersion ?? "TLS") : row.tls.label,
                         tone: row.tls == .succeeded ? .success : (row.tls == .notReached ? .neutral : .warning))
                }
                .width(min: 76, ideal: 84)
                .customizationID("tls")

                TableColumn("TEMPS", sortUsing: table.sort("temps")) { row in
                    ToolTableText(ToolFormat.milliseconds(row.totalMs), color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 48, ideal: 52)
                .customizationID("temps")

                TableColumn("BILAN", sortUsing: table.sort("bilan")) { row in
                    Chip(text: row.verdictLabel, tone: row.verdict.tone)
                }
                .width(min: 70, ideal: 80)
                .customizationID("bilan")

                TableColumn("DNS INVERSE", sortUsing: table.sort("ptr")) { row in
                    ToolTableText(row.ptrNames.first ?? "aucun", color: Theme.textSecondary)
                }
                .width(min: 90, ideal: 160)
                .customizationID("ptr")
                .defaultVisibility(.hidden)
            }
        }
    }
}

extension SMTPDiagnosticResult {
    var sortPreference: Int { preference ?? 0 }
    var sortAddress: String { address ?? "" }
    var sortSoftware: String { software ?? "" }
    var sortTLS: String { tls == .succeeded ? (tlsVersion ?? "TLS") : tls.label }
    var sortVerdict: Int { verdict.rawValue }
    var sortPTR: String { ptrNames.first ?? "" }

    var verdictLabel: String {
        switch verdict {
        case .critical: return "Problème"
        case .warning: return "À améliorer"
        case .info, .ok: return "Correct"
        }
    }
}

// MARK: - Tableau des étapes

struct SMTPStepRow: Identifiable {
    let id: Int
    let step: SMTPStep

    var sortName: String { step.name }
    var sortDuration: Double { step.durationMs ?? -1 }
    var sortStatus: String { step.status.rawValue }

    static func rows(of result: SMTPDiagnosticResult) -> [SMTPStepRow] {
        result.steps.enumerated().map { SMTPStepRow(id: $0.offset, step: $0.element) }
    }
}

/// Étapes du diagnostic (tableau standard « outils.smtp.etapes ») : étape, durée, état, détail.
struct SMTPStepTable: View {
    let rows: [SMTPStepRow]
    @ObservedObject var table: StandardTableModel<SMTPStepRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "etape", title: "Étape", isRequired: true),
        StandardColumn(id: "duree", title: "Durée"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "detail", title: "Détail"),
    ]

    static let sortKeys: [String: KeyPathComparator<SMTPStepRow>] = [
        "ordre": KeyPathComparator(\SMTPStepRow.id),
        "etape": KeyPathComparator(\SMTPStepRow.sortName),
        "duree": KeyPathComparator(\SMTPStepRow.sortDuration),
        "etat": KeyPathComparator(\SMTPStepRow.sortStatus),
        "detail": KeyPathComparator(\SMTPStepRow.step.detail),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<SMTPStepRow> {
        StandardTableModel(id: "outils.smtp.etapes", columns: columns, sortKeys: sortKeys, defaultSort: "ordre")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, emptyText: "Aucune étape.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("ÉTAPE", sortUsing: table.sort("etape")) { row in
                    ToolTableText(row.step.name, mono: false, weight: .medium)
                }
                .width(min: 100, ideal: 120)
                .customizationID("etape")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("DURÉE", sortUsing: table.sort("duree")) { row in
                    ToolTableText(row.step.durationMs.map(ToolFormat.milliseconds) ?? "—", alignment: .trailing)
                }
                .width(min: 50, ideal: 60)
                .customizationID("duree")

                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                    Chip(text: label(row.step.status), tone: tone(row.step.status))
                }
                .width(min: 70, ideal: 76)
                .customizationID("etat")

                TableColumn("DÉTAIL", sortUsing: table.sort("detail")) { row in
                    ToolTableText(row.step.detail, color: Theme.textSecondary).help(row.step.detail)
                }
                .width(min: 120, ideal: 220)
                .customizationID("detail")
            }
        }
    }

    private func label(_ status: SMTPStep.Status) -> String {
        switch status {
        case .ok: return "OK"
        case .warning: return "Attention"
        case .failed: return "Échec"
        case .skipped: return "Sauté"
        }
    }

    private func tone(_ status: SMTPStep.Status) -> Tone {
        switch status {
        case .ok: return .success
        case .warning: return .warning
        case .failed: return .critical
        case .skipped: return .neutral
        }
    }
}
