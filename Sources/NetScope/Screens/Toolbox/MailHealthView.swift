import NetScopeCore
import SwiftUI

@MainActor
final class ToolMailHealthModel: ObservableObject {
    @Published var domain = ""
    /// Sélecteur DKIM propre au domaine (facultatif), essayé avant les sélecteurs courants.
    @Published var selector = ""
    @Published private(set) var isRunning = false
    @Published private(set) var stepIndex = 0
    @Published private(set) var stepName = ""
    @Published private(set) var report: MailHealthReport?
    @Published var error: String?
    /// Bilans ajoutés aux Rapports (section « Santé courriel ») : le plus récent par domaine.
    @Published private(set) var exported: [MailHealthSummary] = []
    @Published var notice: String?
    private var generation = 0

    var command: String {
        let name = MailTools.domain(from: domain) ?? "<domaine>"
        return "dig +short MX \(name); dig +short TXT _dmarc.\(name)"
    }

    func run(store: ToolStore?) {
        guard let name = MailTools.domain(from: domain) else {
            error = "Saisir un domaine (exemple.ca) ou une adresse courriel."
            return
        }
        domain = name
        error = nil
        notice = nil
        isRunning = true
        stepIndex = 0
        stepName = MailHealth.steps[0]
        generation += 1
        let run = generation
        let selectors = selector.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        store?.record(command: command)
        Task {
            let report = await MailHealth.run(name, extraSelectors: selectors, client: MailTools.client) { index, step in
                Task { @MainActor in
                    guard run == self.generation else { return }
                    self.stepIndex = index
                    self.stepName = step
                }
            }
            guard run == self.generation else { return }
            self.report = report
            self.isRunning = false
            let summary = report.summary
            store?.record(ToolRecent(tool: .mailHealth, target: name,
                                     summary: "\(summary.score)/100 · \(summary.grade.label) · " + Self.headline(summary),
                                     status: summary.grade == .good ? .ok : (summary.grade == .fair ? .warning : .failure)))
        }
    }

    /// Affiche un bilan déjà calculé (par le Super outil).
    func show(_ report: MailHealthReport) {
        generation += 1
        isRunning = false
        error = nil
        notice = nil
        domain = report.domain
        self.report = report
    }

    /// « SPF 11 recherches · DMARC p=none »
    static func headline(_ summary: MailHealthSummary) -> String {
        let worst = summary.checks.filter { $0.status >= .warning }.prefix(2)
        guard !worst.isEmpty else { return "aucun point bloquant" }
        return worst.map { "\($0.title) \($0.result.components(separatedBy: " · ").first ?? "")" }.joined(separator: " · ")
    }

    func export(_ summary: MailHealthSummary) {
        exported.removeAll { $0.domain == summary.domain }
        exported.insert(summary, at: 0)
        if exported.count > 5 { exported.removeLast(exported.count - 5) }
    }

    func addToReport() {
        guard let summary = report?.summary else { return }
        export(summary)
        RapportModel.shared.config.sections.insert(.courriel)
        notice = "Bilan de \(summary.domain) ajouté à la section «\u{00A0}Santé courriel\u{00A0}» des Rapports."
    }

    var isExported: Bool {
        guard let summary = report?.summary else { return false }
        return exported.contains { $0.domain == summary.domain && $0.date == summary.date }
    }

    func copyText() -> String {
        guard let summary = report?.summary else { return "" }
        var lines = ["Santé courriel — \(summary.domain) — \(summary.score)/100 (\(summary.grade.label))", ""]
        for check in summary.checks {
            lines.append("[\(check.status.label)] \(check.title)\u{00A0}: \(check.result)" + (check.points == nil ? "" : " (\(check.pointsLabel))"))
        }
        if !summary.recommendations.isEmpty {
            lines += ["", "Recommandations\u{00A0}:"]
            lines += summary.recommendations.map { "- \($0.title)\u{00A0}: \($0.fix ?? "")" }
        }
        return lines.joined(separator: "\n")
    }

    /// Démonstration : bilan de groupecouture.ca (réponses fixes).
    func startDemo() {
        domain = MailDemo.domain
        run(store: nil)
    }
}

/// Santé courriel d'un domaine : note sur 100, vérifications et recommandations.
struct MailHealthView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolMailHealthModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = MailChecksTable.makeModel(id: "outils.courriel.sante", points: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolAdaptiveRow {
                ToolLabeledField(label: "Domaine") {
                    ToolTextField(placeholder: "exemple.ca ou nom@exemple.ca", text: $model.domain) { model.run(store: store) }
                        .frame(minWidth: 200)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    ToolLabeledField(label: "Sélecteur DKIM (facultatif)") {
                        ToolTextField(placeholder: "ex. s2024", text: $model.selector) { model.run(store: store) }
                            .frame(width: 170)
                    }
                    Button(model.isRunning ? "Analyse…" : "Analyser") { model.run(store: store) }
                        .buttonStyle(.primary)
                        .disabled(model.isRunning)
                        .fixedSize()
                }
            }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            if model.isRunning {
                MailProgressLine(text: "Étape \(model.stepIndex + 1) sur \(MailHealth.steps.count)\u{00A0}: \(model.stepName)…",
                                 fraction: Double(model.stepIndex) / Double(MailHealth.steps.count))
            } else if let report = model.report {
                result(report)
            } else if model.error == nil {
                Text("Vérifie MX, SPF, DKIM (sélecteurs courants), DMARC, listes noires, MTA-STS, TLS-RPT, DNSSEC et BIMI, puis donne une note sur 100. Les requêtes partent du résolveur DNS de ce Mac\u{00A0}; aucun courriel n’est envoyé.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func result(_ report: MailHealthReport) -> some View {
        let summary = report.summary
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                scoreBlock(summary)
                Spacer(minLength: 8)
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                scoreBlock(summary)
                actions
            }
        }
        if let notice = model.notice {
            ToolNotice(tone: .success, message: notice) {
                Button("Ouvrir les Rapports") { state.open(.rapports) }.buttonStyle(.secondary).fixedSize()
            }
        }
        HStack {
            ToolFieldLabel("Vérifications")
            Spacer()
            ToolColumnsMenu(model: table)
        }
        MailChecksTable(rows: MailCheckRow.rows(summary.checks), table: table, showPoints: true)
        if !summary.recommendations.isEmpty {
            ToolFieldLabel("Recommandations (\(summary.recommendations.count))")
            MailFindingList(findings: summary.recommendations)
        }
        Text("Note ramenée aux vérifications qui ont abouti\u{00A0}; DKIM\u{00A0}: \(report.dkim.tried) sélecteurs courants essayés (un sélecteur propre au domaine se saisit plus haut).")
            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scoreBlock(_ summary: MailHealthSummary) -> some View {
        HStack(spacing: 14) {
            MailScoreRing(score: summary.score)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(summary.grade.label).font(.system(size: 17, weight: .bold)).foregroundStyle(summary.grade.status.tone.foreground)
                    Text(summary.domain).font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                Text("Vérifié à \(ToolText.time(summary.date))").font(Theme.small).foregroundStyle(Theme.textSecondary)
                MailTallyChips(statuses: summary.checks.map(\.status))
            }
        }
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                ToolActions.copy(model.copyText())
            } label: {
                Label("Copier le bilan", systemImage: "doc.on.doc")
            }
            .buttonStyle(.secondary)
            Button {
                model.addToReport()
            } label: {
                Label(model.isExported ? "Dans le rapport" : "Ajouter au rapport", systemImage: model.isExported ? "checkmark" : "doc.richtext")
            }
            .buttonStyle(.secondary)
            .disabled(model.isExported)
        }
        .fixedSize()
    }
}
