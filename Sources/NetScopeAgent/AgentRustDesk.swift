import Foundation
import NetScopeCore

/// Note 88 (0.33.1) : mise à jour planifiée du serveur RustDesk, faite par l'agent du seul Mac
/// choisi (réglage synchronisé), que NetScope soit ouvert ou fermé. Compte et réglages lus dans les
/// fichiers de l'app, secrets au Trousseau juste avant la connexion ; résultat noté dans
/// l'historique du suivi (sous le verrou partagé avec l'app) et alerte en cas d'échec, d'abandon ou d'oubli.
extension AgentService {
    /// Nom de ce Mac, lu une seule fois (Host.current() peut être lent) et seulement s'il sert.
    private static let originName: String = (Host.current().localizedName ?? "Mac") + " (agent, planifiée)"

    /// Une vérification par minute au plus ; une seule exécution à la fois.
    func rustDeskSchedule(_ now: Date) {
        guard rustDeskTask == nil, now.timeIntervalSince(rustDeskChecked) >= 60 else { return }
        rustDeskChecked = now
        let store = RustDeskWatchStore.standard
        guard let contents = store.load(), contents.schedule.enabled else { return }
        let schedule = contents.schedule
        let decision = RustDeskUpdateSchedule.decide(schedule, now: now, calendar: calendar, records: contents.actions,
                                                     machineID: RustDeskUpdateSchedule.thisMachineID())
        func notes(_ slot: Date, _ outcome: RustDeskActionOutcome, _ summary: String) -> [RustDeskActionRecord] {
            RustDeskUpdateSchedule.openKinds(schedule, slot: slot, records: contents.actions).map {
                RustDeskActionRecord(date: now, kind: $0, target: schedule.target.label, outcome: outcome, summary: summary,
                                     origin: Self.originName, slot: slot)
            }
        }
        switch decision {
        case .idle:
            return
        case .missed(let slot):
            record(notes(slot, .missed, "Échéance manquée (Mac éteint, en veille ou agent arrêté)."))
        case .expired(let slot):
            record(notes(slot, .skipped, "Session relayée en cours pendant toute la fenêtre\u{00A0}: reportée à la semaine suivante."))
        case .run(let slot, _):
            let origin = Self.originName
            guard let dashboard = RustDeskDashboardStore.standard.load()?.settings,
                  let account = RustDeskServerCredentials.account(dashboard, connections: RemoteConnectionStore.standard.load() ?? []) else {
                record(notes(slot, .failed, "Compte SSH du serveur introuvable (Réglages › RustDesk)."))
                return
            }
            let secret = RustDeskServerCredentials.secretKey(dashboard).flatMap { UpdKeychain(service: $0.service).string(for: $0.account) }
            let stored = RustDeskServerCredentials.sudoKey(dashboard).flatMap {
                UpdKeychain(service: RustDeskServerCredentials.rustDeskService).string(for: $0)
            }
            let sudo = RustDeskServerCredentials.sudoPassword(stored: stored, sshSecret: secret, account: account)
            // Seules les actions encore ouvertes : « RustDesk réussie, système reporté » ne refait que le système.
            let open = RustDeskUpdateSchedule.openKinds(schedule, slot: slot, records: contents.actions)
            let actions = schedule.actions().filter { open.contains($0.kind) }
            note("Serveur RustDesk\u{00A0}: mise à jour planifiée (\(open.map(\.label).joined(separator: ", "))).")
            rustDeskTask = Task {
                var records: [RustDeskActionRecord] = []
                for (index, action) in actions.enumerated() {
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
                    if record.outcome == .ok { continue }
                    // Report : le reste est repris avec elle (rien n'est noté pour lui). Échec : le
                    // reste n'est pas fait cette semaine, et c'est noté.
                    if record.outcome == .failed {
                        for rest in actions.dropFirst(index + 1) {
                            records.append(RustDeskActionRecord(date: Date(), kind: rest.kind, target: rest.target, outcome: .skipped,
                                                                summary: "Non faite\u{00A0}: «\u{00A0}\(action.kind.label)\u{00A0}» a échoué juste avant.",
                                                                origin: origin, slot: slot))
                        }
                    }
                    break
                }
                self.finishRustDesk(records)
            }
        }
    }

    private func finishRustDesk(_ records: [RustDeskActionRecord]) {
        rustDeskTask = nil
        record(records)
    }

    /// Ajoute les actions au fichier du suivi : relecture, ajout et écriture sous le verrou partagé
    /// avec l'app (qui fusionne sous le même verrou) ; seules les actions changent. Note et alerte.
    private func record(_ records: [RustDeskActionRecord]) {
        guard !records.isEmpty else { return }
        do {
            try RustDeskWatchStore.standard.update { contents in
                contents.actions = RustDeskActionRecord.union(records, contents.actions)
            }
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
