import NetScopeCore
import SwiftUI

@MainActor
final class ToolMailSuperModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var isRunning = false
    @Published private(set) var progress = ""
    @Published private(set) var result: MailSuperResult?
    private var generation = 0

    /// Ce que la saisie semble être, avant même de lancer (« Adresse courriel → exemple.ca »).
    var recognized: (kind: MailInputKind, value: String)? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let (kind, value) = MailInput.classify(text)
        return (kind, kind == .email ? MailInput.domain(ofEmail: value) : value)
    }

    var command: String {
        guard let recognized, recognized.kind != .invalid else { return "dig +short MX <domaine>" }
        if recognized.kind == .ip, let ip = IPv4Address(recognized.value) {
            return "dig -x \(ip) +short; dig +short \(DNSBL.reversed(ip)).zen.spamhaus.org"
        }
        return "dig +short MX \(recognized.value); dig +short TXT \(recognized.value)"
    }

    func run(store: ToolStore?) {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isRunning = true
        progress = "Reconnaissance de la saisie…"
        generation += 1
        let run = generation
        store?.record(command: command)
        Task {
            let result = await MailSuperTool.run(text, client: MailTools.client) { step in
                Task { @MainActor in
                    guard run == self.generation else { return }
                    self.progress = step + "…"
                }
            }
            guard run == self.generation else { return }
            self.result = result
            self.isRunning = false
            let status: ToolRecent.Status = result.status == .error ? .failure : (result.status == .warning ? .warning : .ok)
            let score = result.health.map { "\($0.summary.score)/100 · " } ?? ""
            store?.record(ToolRecent(tool: .mailSuper, target: result.target, summary: score + result.tally, status: status))
        }
    }

    func startDemo() {
        input = MailDemo.superInput
        run(store: nil)
    }
}

/// Super outil courriel : un seul champ, toutes les vérifications utiles, bilan coloré.
struct MailSuperToolView: View {
    @ObservedObject var model: ToolMailSuperModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = MailChecksTable.makeModel(id: "outils.courriel.super", points: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                ToolLabeledField(label: "Domaine, adresse courriel, IP ou nom d’hôte") {
                    ToolTextField(placeholder: "exemple.ca, nom@exemple.ca, 203.0.113.25, mail.exemple.ca", text: $model.input) {
                        model.run(store: store)
                    }
                    .frame(minWidth: 180)
                }
                Button(model.isRunning ? "Vérification…" : "Vérifier") { model.run(store: store) }
                    .buttonStyle(.primary)
                    .disabled(model.isRunning || model.input.trimmingCharacters(in: .whitespaces).isEmpty)
                    .fixedSize()
            }
            if let recognized = model.recognized {
                HStack(spacing: 8) {
                    Chip(text: recognized.kind.label, tone: recognized.kind == .invalid ? .critical : .accent,
                         systemImage: symbol(recognized.kind))
                    if recognized.kind != .invalid {
                        Text(plan(recognized.kind, recognized.value))
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            if model.isRunning {
                MailProgressLine(text: model.progress)
            } else if let result = model.result {
                resultView(result)
            } else {
                Text("Le champ devine quoi faire\u{00A0}: un domaine ou une adresse courriel donne le bilan complet (MX, SPF, DKIM, DMARC, listes noires, MTA-STS, DNSSEC)\u{00A0}; une IP, son DNS inverse et les listes noires\u{00A0}; un nom d’hôte, ses adresses, leur DNS inverse et les listes noires.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func symbol(_ kind: MailInputKind) -> String {
        switch kind {
        case .email: return "at"
        case .domain: return "globe"
        case .hostname: return "server.rack"
        case .ip: return "number"
        case .invalid: return "questionmark"
        }
    }

    private func plan(_ kind: MailInputKind, _ value: String) -> String {
        switch kind {
        case .email: return "Bilan courriel du domaine \(value)"
        case .domain: return "Bilan courriel de \(value) (ou vérification de l’hôte s’il n’a ni MX ni SPF)"
        case .hostname: return "Adresses, DNS inverse et listes noires de \(value)"
        case .ip: return "DNS inverse et listes noires de \(value)"
        case .invalid: return ""
        }
    }

    @ViewBuilder private func resultView(_ result: MailSuperResult) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                headline(result)
                Spacer(minLength: 8)
                links(result)
            }
            VStack(alignment: .leading, spacing: 10) {
                headline(result)
                links(result)
            }
        }
        HStack {
            ToolFieldLabel("Bilan (\(result.checks.count) vérification\(result.checks.count > 1 ? "s" : ""))")
            Spacer()
            ToolColumnsMenu(model: table)
        }
        MailChecksTable(rows: MailCheckRow.rows(result.checks), table: table)
        if let health = result.health, !health.summary.recommendations.isEmpty {
            ToolFieldLabel("À corriger en priorité")
            MailFindingList(findings: health.summary.recommendations, limit: 4)
        }
    }

    private func headline(_ result: MailSuperResult) -> some View {
        HStack(spacing: 12) {
            if let health = result.health { MailScoreRing(score: health.summary.score, size: 54) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: result.status.symbol).foregroundStyle(result.status.tone.foreground)
                    Text(result.target).font(Theme.mono(14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(result.kind.label).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                MailTallyChips(statuses: result.checks.map(\.status))
            }
        }
        .fixedSize()
    }

    /// Ouvre l'outil détaillé avec la même cible (le bilan déjà calculé passe à Santé courriel).
    private func links(_ result: MailSuperResult) -> some View {
        HStack(spacing: 6) {
            if let health = result.health {
                Button("Santé courriel") {
                    store.mailHealth.show(health)
                    store.selectedTool = .mailHealth
                }
                Button("SPF, DKIM, DMARC") {
                    store.mailRecords.domain = health.domain
                    store.selectedTool = .mailRecords
                    store.mailRecords.run(store: store)
                }
                Button("MX") {
                    store.mx.domain = health.domain
                    store.mx.show(health.mx)
                    store.selectedTool = .mx
                }
            }
            if let blacklists = result.blacklists, result.kind == .ip || result.kind == .hostname {
                Button("Listes noires") {
                    store.blacklist.target = result.target
                    store.blacklist.show(blacklists)
                    store.selectedTool = .blacklist
                }
            }
        }
        .buttonStyle(.secondary)
        .fixedSize()
    }
}
