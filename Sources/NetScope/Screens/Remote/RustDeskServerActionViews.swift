import NetScopeCore
import SwiftUI

// Note 88 (0.33.1) : panneau « Actions et mise à jour planifiée » du tableau de bord du serveur
// RustDesk (boutons, réglage de la fenêtre, historique des actions) et feuille de confirmation
// (ce qui va se passer, commande exacte, « Copier la commande », résultat).

// MARK: - Panneau

struct RustDeskActionsPanel: View {
    let status: RustDeskServerStatus
    @ObservedObject var watch: RustDeskServerWatchModel
    @ObservedObject var actions = RustDeskServerActionModel.shared

    /// Sessions relayées en cours ; nil : inconnues (console de hbbr illisible), dit comme tel.
    private var sessions: Int? { status.relayConsole == .ok ? status.relaySessions.count : nil }

    static var machineID: String {
        RegEnvironment.isDemo ? RustDeskServerDemo.demoMachineID : RustDeskUpdateSchedule.thisMachineID()
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Actions sur le serveur", subtitle: RegEnvironment.isDemo ? "démonstration\u{00A0}: actions simulées" : "confirmation avant chaque action")
                HStack(spacing: 6) {
                    Button("Mettre à jour RustDesk…") { actions.ask(.updateRustDesk(activeSessions: sessions)) }
                    Button("Mettre à jour le système…") {
                        actions.ask(.updateSystem(scope: watch.contents.schedule.scope, allowReboot: false, activeSessions: sessions))
                    }
                    Button("Redémarrer hbbr…") { actions.ask(.restartRelay(activeSessions: sessions)) }
                }
                .buttonStyle(RemoteSmallButtonStyle())
                .disabled(actions.running)
                if let refused = actions.refused {
                    Text(refused).font(Theme.caption).foregroundStyle(Theme.warning)
                }
                RustDeskScheduleEditor(watch: watch, machineID: Self.machineID)
                Divider()
                Text("HISTORIQUE DES ACTIONS").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                if watch.contents.actions.isEmpty {
                    Text("Aucune action encore\u{00A0}: chaque déconnexion, redémarrage et mise à jour (à la main ou planifiée) est notée ici.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(watch.contents.actions.prefix(8)) { record in
                        RustDeskActionRecordRow(record: record)
                    }
                }
            }
        }
    }
}

struct RustDeskActionRecordRow: View {
    let record: RustDeskActionRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RustDeskOutcomeIcon(outcome: record.outcome).font(.system(size: 12)).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(record.kind.label).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Text(record.outcome.label).font(Theme.captionSemibold).foregroundStyle(RustDeskOutcomeIcon.color(record.outcome))
                    Spacer(minLength: 4)
                    Text(RustDeskRequestRow.moment(record.date)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                }
                Text(record.summary).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text("\(record.target) · \(record.origin)").font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
    }
}

struct RustDeskOutcomeIcon: View {
    let outcome: RustDeskActionOutcome

    static func color(_ outcome: RustDeskActionOutcome) -> Color {
        switch outcome {
        case .ok: return Theme.success
        case .failed: return Theme.critical
        case .postponed, .skipped, .missed: return Theme.warning
        case .simulated: return Theme.textSecondary
        }
    }

    var body: some View {
        let name: String
        switch outcome {
        case .ok: name = "checkmark.circle.fill"
        case .failed: name = "xmark.octagon.fill"
        case .postponed: name = "clock.arrow.circlepath"
        case .skipped, .missed: name = "exclamationmark.triangle.fill"
        case .simulated: name = "play.circle"
        }
        return Image(systemName: name).foregroundStyle(Self.color(outcome))
    }
}

// MARK: - Mise à jour planifiée

struct RustDeskScheduleEditor: View {
    @ObservedObject var watch: RustDeskServerWatchModel
    let machineID: String
    @ObservedObject private var agent = AgentController.shared
    @EnvironmentObject private var state: AppState

    /// L'agent (note 64) est inscrit et son battement de cœur est récent.
    private var agentActive: Bool {
        agent.isEnabled && (agent.status?.isResponding(now: agent.now) ?? false)
    }

    private var schedule: RustDeskUpdateSchedule { watch.contents.schedule }

    private func binding<V>(_ path: WritableKeyPath<RustDeskUpdateSchedule, V>) -> Binding<V> {
        Binding(get: { watch.contents.schedule[keyPath: path] },
                set: { value in
                    var updated = watch.contents.schedule
                    updated[keyPath: path] = value
                    watch.setSchedule(updated)
                })
    }

    private static let weekdays = ["Dimanche", "Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: binding(\.enabled)) {
                Text("Mise à jour planifiée").font(Theme.bodySemibold)
            }
            .toggleStyle(.switch).controlSize(.small)
            if schedule.enabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Fenêtre").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 92, alignment: .leading)
                        Picker("", selection: binding(\.weekday)) {
                            ForEach(1...7, id: \.self) { Text(Self.weekdays[$0 - 1]).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Picker("", selection: binding(\.hour)) {
                            ForEach(0..<24, id: \.self) { Text("\($0)\u{00A0}h").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Picker("", selection: binding(\.minute)) {
                            ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    HStack(spacing: 6) {
                        Text("Quoi").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 92, alignment: .leading)
                        Picker("", selection: binding(\.target)) {
                            ForEach(RustDeskUpdateTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Picker("", selection: binding(\.scope)) {
                            ForEach(RustDeskUpdateScope.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .disabled(schedule.target == .rustdesk)
                    }
                    Toggle("Redémarrage du serveur permis", isOn: binding(\.allowReboot)).controlSize(.small)
                    Toggle("Reporter si une session relayée est en cours", isOn: binding(\.postponeIfSession)).controlSize(.small)
                }
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer").foregroundStyle(Theme.textSecondary)
                    Text(runnerText).font(Theme.small).foregroundStyle(schedule.runnerID == machineID ? Theme.text : Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if schedule.runnerID != machineID {
                        Button("Exécuter sur ce Mac") {
                            var updated = schedule
                            updated.runnerID = machineID
                            updated.runnerName = RustDeskServerActionModel.origin
                            watch.setSchedule(updated)
                        }
                        .buttonStyle(RemoteSmallButtonStyle())
                        .disabled(machineID.isEmpty)
                    }
                }
                if !agentActive {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text("Agent NetScope non actif sur ce Mac\u{00A0}: la mise à jour planifiée ne sera pas faite ici, et une échéance manquée ne sera pas notée.")
                            .font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Réglages de l’agent…") {
                            RegNavigation.shared.section = .surveillance
                            state.open(.reglages)
                        }
                        .buttonStyle(RemoteSmallButtonStyle())
                    }
                }
            }
        }
        .onAppear { agent.refresh() }
    }

    private var runnerText: String {
        let next = schedule.nextSlot(after: Date(), calendar: .current).map { "Prochaine\u{00A0}: \(RustDeskRequestRow.moment($0)) (\(schedule.label(calendar: .current)))" } ?? ""
        if schedule.runnerID.isEmpty { return "Aucun Mac choisi\u{00A0}: rien ne sera fait. " + next }
        if schedule.runnerID == machineID {
            return "Faite par l’agent NetScopeAgent de ce Mac (s’il est actif), même NetScope fermé\u{00A0}; un seul Mac l’exécute. Report de 15\u{00A0}min en 15\u{00A0}min pendant 3\u{00A0}h si une session est en cours, alerte en cas d’échec. " + next
        }
        return "Faite par «\u{00A0}\(schedule.runnerName.isEmpty ? "un autre Mac" : schedule.runnerName)\u{00A0}» (un autre Mac). " + next
    }
}

// MARK: - Confirmation

struct RustDeskActionSheet: View {
    /// Action ouverte ; ses options (portée, redémarrage) se changent ici, dans `pending`.
    let opened: RustDeskServerAction
    @ObservedObject var actions = RustDeskServerActionModel.shared

    init(action: RustDeskServerAction) {
        opened = action
    }

    private var action: RustDeskServerAction {
        if let pending = actions.pending, pending.id == opened.id { return pending }
        return opened
    }

    private var destructive: Bool { action.kind != .disconnect }

    private func option<V>(_ path: WritableKeyPath<RustDeskServerAction, V>) -> Binding<V> {
        Binding(get: { action[keyPath: path] },
                set: { value in
                    guard var pending = actions.pending, pending.id == opened.id else { return }
                    pending[keyPath: path] = value
                    actions.pending = pending
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(action.title).font(Theme.panelTitle)
            if RegEnvironment.isDemo {
                Text("Démonstration\u{00A0}: l’action est simulée, rien n’est envoyé au serveur.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            if action.kind == .updateSystem {
                HStack(spacing: 12) {
                    Picker("Mises à jour", selection: option(\.scope)) {
                        ForEach(RustDeskUpdateScope.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    Toggle("Redémarrage permis", isOn: option(\.allowReboot)).controlSize(.small)
                }
                .disabled(actions.running || actions.result != nil)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(action.consequences.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: index == 0 && action.warnsSessions ? "exclamationmark.triangle.fill" : "circle.fill")
                            .font(.system(size: index == 0 && action.warnsSessions ? 11 : 5))
                            .foregroundStyle(index == 0 && action.warnsSessions ? Theme.warning : Theme.textSecondary)
                            .frame(width: 12, height: 14)
                        Text(line).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Text("COMMANDE EXACTE (SANS SECRET)").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(actions.copied ? "Commande copiée" : "Copier la commande") { actions.copyCommand(action) }
                    .buttonStyle(RemoteSmallButtonStyle())
            }
            ScrollView {
                Text(actions.command(for: action)).font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            Text("Le mot de passe sudo (Trousseau) passe en première ligne de l’entrée standard, jamais dans la commande\u{00A0}; collée dans Terminal, cette ligne est vide (sudo sans mot de passe ou compte root).")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            if let result = actions.result {
                Divider()
                RustDeskActionRecordRow(record: result)
                ForEach(Array(result.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: step.level == "ok" ? "checkmark" : step.level == "echec" ? "xmark" : step.level == "attention" ? "exclamationmark.triangle" : "info.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(step.level == "ok" ? Theme.success : step.level == "echec" ? Theme.critical : step.level == "attention" ? Theme.warning : Theme.textSecondary)
                            .frame(width: 12)
                        Text(step.text).font(Theme.small).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            if let refused = actions.refused {
                Text(refused).font(Theme.caption).foregroundStyle(Theme.warning)
            }
            HStack {
                if actions.running {
                    ProgressView().controlSize(.small)
                    Text(action.kind == .updateSystem || action.kind == .updateRustDesk ? "Mise à jour en cours (plusieurs minutes possibles)…" : "Action en cours…")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if actions.result != nil {
                    Button("Fermer") { actions.dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Annuler") { actions.dismiss() }.keyboardShortcut(.cancelAction).disabled(actions.running)
                    Button(action.confirmLabel, role: destructive ? .destructive : nil) { actions.confirm() }
                        .disabled(actions.running)
                }
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}
