import AppKit
import Foundation
import NetScopeCore

/// Note 88 (0.33.1) : actions sur le serveur RustDesk (déconnecter, redémarrer hbbr, mettre à jour
/// RustDesk ou le système). Chaque action passe par une confirmation qui dit ce qui va se passer et
/// montre la commande exacte ; rien n'est envoyé avant « Confirmer ». En démonstration et en capture :
/// action simulée (aucun ssh, aucun Trousseau), notée « Simulée » dans l'historique.
@MainActor
final class RustDeskServerActionModel: ObservableObject {
    static let shared = RustDeskServerActionModel()

    /// Action à confirmer (feuille ouverte).
    @Published var pending: RustDeskServerAction?
    @Published private(set) var running = false
    /// Résultat de la dernière action confirmée (montré dans la feuille).
    @Published private(set) var result: RustDeskActionRecord?
    @Published var refused: String?
    @Published var copied = false

    private init() {
        guard RegEnvironment.isDemo else { return }
        // Captures : NETSCOPE_RUSTDESK_ACTION=maj-rustdesk, maj-systeme, deconnecter ou redemarrer-hbbr
        // ouvre la confirmation ; « …-resultat » montre aussi le résultat simulé.
        guard let value = ProcessInfo.processInfo.environment["NETSCOPE_RUSTDESK_ACTION"] else { return }
        let showResult = value.hasSuffix("-resultat")
        let raw = showResult ? String(value.dropLast("-resultat".count)) : value
        guard let kind = RustDeskActionKind(rawValue: raw) else { return }
        let status = RustDeskServerDemo.status(now: Date())
        switch kind {
        case .disconnect:
            if let session = status.relaySessions.first { pending = try? .disconnect(session, targetID: "263418095", station: "Réception – poste 2") }
        case .restartRelay: pending = .restartRelay(activeSessions: status.relaySessions.count)
        case .updateRustDesk: pending = .updateRustDesk(activeSessions: status.relaySessions.count)
        case .updateSystem: pending = .updateSystem(scope: .security, allowReboot: false, activeSessions: status.relaySessions.count)
        }
        if showResult, let pending { result = Self.simulated(pending, now: Date()) }
    }

    /// Ouvre la confirmation (valeurs déjà validées par la construction de l'action).
    func ask(_ action: RustDeskServerAction) {
        guard !running else { return }
        result = nil
        refused = nil
        pending = action
    }

    /// Déconnexion d'une ligne du tableau : adresse, port et ID validés ; sinon le refus est dit.
    func askDisconnect(_ row: RustDeskRelayRow, status: RustDeskServerStatus) {
        guard let session = status.relaySessions.first(where: { $0.id == row.id }) else { return }
        do {
            ask(try .disconnect(session, targetID: row.targetID, station: row.station))
        } catch {
            refused = (error as? LocalizedError)?.errorDescription ?? "Valeur refusée."
        }
    }

    func dismiss() {
        guard !running else { return }
        pending = nil
        result = nil
    }

    /// Commande exacte (sans aucun secret) : ssh, commande distante fixe et script de l'action.
    func command(for action: RustDeskServerAction) -> String {
        let account = (try? RustDeskServerModel.shared.resolvedAccount().get())
            ?? RustDeskServerAccount(user: "admin", host: "assistance.exemple.ca")
        return RustDeskServerSSH.copyableActionCommand(account, action: action)
    }

    func copyCommand(_ action: RustDeskServerAction) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command(for: action), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self.copied = false
        }
    }

    /// Nom de ce Mac (« Mac du siège » en démonstration : aucun nom réel dans les captures).
    static var origin: String { RegEnvironment.isDemo ? "Mac du siège" : (Host.current().localizedName ?? "Ce Mac") }

    /// Résultat simulé (démonstration) : les étapes que le serveur aurait renvoyées.
    static func simulated(_ action: RustDeskServerAction, now: Date) -> RustDeskActionRecord {
        let steps: [RustDeskActionStep]
        switch action.kind {
        case .disconnect:
            steps = [RustDeskActionStep(level: "ok", text: "Connexion relayée de \(action.peerLabel) fermée (1 connexion(s)). Le poste peut se reconnecter.")]
        case .restartRelay:
            steps = [RustDeskActionStep(level: "ok", text: "Conteneur hbbr redémarré."),
                     RustDeskActionStep(level: "ok", text: "hbbr écoute de nouveau sur le port 21117.")]
        case .updateRustDesk:
            steps = [RustDeskActionStep(level: "ok", text: "Compose relu sans erreur (/srv/exemple/rustdesk)."),
                     RustDeskActionStep(level: "ok", text: "Clé et base sauvegardées\u{00A0}: /var/backups/netscope-rustdesk-20261106-1405.tar.gz"),
                     RustDeskActionStep(level: "ok", text: "Image actuelle étiquetée rustdesk/rustdesk-server:netscope-avant-20261106-1405."),
                     RustDeskActionStep(level: "ok", text: "docker compose pull terminé."),
                     RustDeskActionStep(level: "ok", text: "docker compose up -d terminé."),
                     RustDeskActionStep(level: "ok", text: "hbbs et hbbr tournent, ports 21115 à 21117 à l’écoute."),
                     RustDeskActionStep(level: "ok", text: "Clé publique inchangée.")]
        case .updateSystem:
            steps = [RustDeskActionStep(level: "ok", text: "Listes de paquets rafraîchies (apt-get update)."),
                     RustDeskActionStep(level: "ok", text: "Mises à jour de sécurité installées (unattended-upgrade)."),
                     RustDeskActionStep(level: "info", text: "Paquets à mettre à jour\u{00A0}: 7 avant, 3 après."),
                     RustDeskActionStep(level: "attention", text: "Redémarrage requis, non permis\u{00A0}: à faire plus tard.")]
        }
        let summary = action.kind == .updateRustDesk ? "RustDesk Server 1.1.14 → 1.1.15." : (steps.last?.text ?? "Terminée.")
        return RustDeskActionRecord(date: now, kind: action.kind, target: action.target, outcome: .simulated,
                                    summary: "Démonstration, rien n’est envoyé\u{00A0}: " + summary, steps: steps, origin: origin)
    }

    /// « Confirmer » : seule porte vers le serveur. Démonstration : simulée.
    func confirm() {
        guard let action = pending, !running else { return }
        if RegEnvironment.isDemo {
            running = true
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let record = Self.simulated(action, now: Date())
                self.running = false
                self.result = record
                RustDeskServerWatchModel.shared.addActions([record])
            }
            return
        }
        guard !RegEnvironment.isSandboxed else { return }
        let server = RustDeskServerModel.shared
        guard let account = try? server.resolvedAccount().get() else {
            refused = "Aucun compte SSH n’est choisi pour le serveur."
            return
        }
        let secret = server.secret()
        let sudo = RustDeskServerWatchModel.shared.actionSudoPassword()
        running = true
        AppLog.shared.info("RustDesk", "Action confirmée sur le serveur\u{00A0}: \(action.kind.label) (\(action.target)).")
        Task {
            let outcome = await RustDeskServerSSH.runAction(account, secret: secret, sudoPassword: sudo, action: action)
            let record: RustDeskActionRecord
            switch outcome {
            case .success(let output):
                record = RustDeskActionRecord(date: Date(), kind: action.kind, target: action.target, outcome: output.outcome,
                                              summary: output.summary(for: action.kind), steps: output.steps, origin: Self.origin)
            case .failure(let error):
                record = RustDeskActionRecord(date: Date(), kind: action.kind, target: action.target, outcome: .failed,
                                              summary: error.title + "\u{00A0}: " + error.detail, origin: Self.origin)
            }
            self.running = false
            self.result = record
            RustDeskServerWatchModel.shared.addActions([record])
            if record.outcome == .ok {
                AppLog.shared.info("RustDesk", "\(action.kind.label)\u{00A0}: \(record.summary)")
            } else {
                AppLog.shared.warning("RustDesk", "\(action.kind.label)\u{00A0}: \(record.summary)")
            }
            // État relu après l'action (sessions, versions).
            server.refresh()
            if action.kind == .updateRustDesk || action.kind == .updateSystem { RustDeskServerWatchModel.shared.readDetails() }
        }
    }
}
