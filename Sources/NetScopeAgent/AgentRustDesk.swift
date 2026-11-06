import Foundation
import NetScopeCore

/// Note 88 (0.33.1) : mise à jour planifiée du serveur RustDesk, faite par l'agent du seul Mac
/// choisi (réglage synchronisé), que NetScope soit ouvert ou fermé. Compte et réglages lus dans les
/// fichiers de l'app, secrets au Trousseau juste avant la connexion ; résultat noté dans
/// l'historique du suivi (fusion avec le fichier) et alerte en cas d'échec, d'abandon ou d'oubli.
extension AgentService {
    /// Une vérification par minute au plus ; une seule exécution à la fois.
    func rustDeskSchedule(_ now: Date) {
        guard rustDeskTask == nil, now.timeIntervalSince(rustDeskChecked) >= 60 else { return }
        rustDeskChecked = now
        let store = RustDeskWatchStore.standard
        guard let contents = store.load(), contents.schedule.enabled else { return }
        let decision = RustDeskUpdateSchedule.decide(contents.schedule, now: now, calendar: calendar, records: contents.actions,
                                                     machineID: RustDeskUpdateSchedule.thisMachineID())
        let origin = (Host.current().localizedName ?? "Mac") + " (agent, planifiée)"
        switch decision {
        case .idle:
            return
        case .missed(let slot):
            record([RustDeskActionRecord(date: now, kind: contents.schedule.target.kinds[0], target: contents.schedule.target.label,
                                         outcome: .missed, summary: "Échéance manquée (Mac éteint, en veille ou agent arrêté).",
                                         origin: origin, slot: slot)])
        case .expired(let slot):
            record([RustDeskActionRecord(date: now, kind: contents.schedule.target.kinds[0], target: contents.schedule.target.label,
                                         outcome: .skipped, summary: "Session relayée en cours pendant toute la fenêtre\u{00A0}: reportée à la semaine suivante.",
                                         origin: origin, slot: slot)])
        case .run(let slot, _):
            guard let dashboard = RustDeskDashboardStore.standard.load()?.settings,
                  let account = RustDeskServerCredentials.account(dashboard, connections: RemoteConnectionStore.standard.load() ?? []) else {
                record([RustDeskActionRecord(date: now, kind: contents.schedule.target.kinds[0], target: contents.schedule.target.label,
                                             outcome: .failed, summary: "Compte SSH du serveur introuvable (Réglages › RustDesk).",
                                             origin: origin, slot: slot)])
                return
            }
            let secret = RustDeskServerCredentials.secretKey(dashboard).flatMap { UpdKeychain(service: $0.service).string(for: $0.account) }
            let stored = RustDeskServerCredentials.sudoKey(dashboard).flatMap {
                UpdKeychain(service: RustDeskServerCredentials.rustDeskService).string(for: $0)
            }
            let sudo = RustDeskServerCredentials.sudoPassword(stored: stored, sshSecret: secret, account: account)
            let actions = contents.schedule.actions()
            note("Serveur RustDesk\u{00A0}: mise à jour planifiée (\(contents.schedule.target.label)).")
            rustDeskTask = Task {
                var records: [RustDeskActionRecord] = []
                for action in actions {
                    let result = await RustDeskServerSSH.runAction(account, secret: secret, sudoPassword: sudo, action: action)
                    let record: RustDeskActionRecord
                    switch result {
                    case .success(let output):
                        record = RustDeskActionRecord(date: Date(), kind: action.kind, target: action.target, outcome: output.outcome,
                                                      summary: output.summary(for: action.kind), steps: output.steps, origin: origin, slot: slot)
                    case .failure(let error):
                        record = RustDeskActionRecord(date: Date(), kind: action.kind, target: action.target, outcome: .failed,
                                                      summary: error.title + "\u{00A0}: " + error.detail, origin: origin, slot: slot)
                    }
                    records.append(record)
                    // Report ou échec : le reste attend (une échéance reportée est reprise en entier).
                    if record.outcome != .ok { break }
                }
                self.finishRustDesk(records)
            }
        }
    }

    private func finishRustDesk(_ records: [RustDeskActionRecord]) {
        rustDeskTask = nil
        record(records)
    }

    /// Ajoute les actions au fichier du suivi (relu juste avant : rien de ce que l'app a écrit
    /// n'est perdu ; l'app fusionne à son tour avant d'écrire), note et alerte.
    private func record(_ records: [RustDeskActionRecord]) {
        guard !records.isEmpty else { return }
        let store = RustDeskWatchStore.standard
        var contents = store.load() ?? RustDeskWatchStore.Contents()
        contents.actions = RustDeskActionRecord.union(records, contents.actions)
        do {
            try store.save(contents)
        } catch {
            note("Serveur RustDesk\u{00A0}: historique non enregistré (\(error.localizedDescription)).", level: .warning)
        }
        for record in records {
            note("Serveur RustDesk\u{00A0}: \(record.kind.label) — \(record.outcome.label)\u{00A0}: \(record.summary)",
                 level: record.outcome == .ok || record.outcome == .postponed ? .info : .warning)
            if let event = AlertEvent.rustDeskScheduledUpdate(record) { sendAlert(event, defaults: defaults) }
        }
    }
}
