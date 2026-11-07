import Foundation

/// Note 100 (1.3.0) : sonde « Serveur WireGuard » de Surveillance, aussi exécutée par l'agent.
/// Une lecture SSH en lecture seule (le script du tableau de bord, sans mot de passe sudo : sudo
/// sans mot de passe ou groupe docker) ; panne si le conteneur wg-easy est arrêté ou si la clé
/// publique du serveur change (la première clé lue est retenue dans `knownThreats`, « cle:<clé> »).
/// Les clients importants et les expirations sont suivis par le tableau de bord (réglages de l'onglet).
public enum MonWireGuardChecks {
    public static let keyPrefix = "cle:"

    public static func run(_ probe: MonProbe, target: String,
                           read: (@Sendable (String) async -> Result<WireGuardServerStatus, RustDeskServerReadError>)?,
                           now: Date) async -> MonRunOutcome {
        let result: Result<WireGuardServerStatus, RustDeskServerReadError>
        if let read {
            result = await read(target)
        } else {
            guard let account = try? MonRustDeskChecks.account(for: probe, target: target) else {
                return MonRunOutcome(result: .failure(now, error: "Compte attendu\u{00A0}: utilisateur@hôte"))
            }
            let secret: String?
            if let connection = probe.sshConnection {
                secret = UpdKeychain(service: MonRustDeskChecks.connectionKeychainService).lookup(connection.uuidString).value
            } else {
                secret = UpdKeychain(service: MonRustDeskChecks.keychainService)
                    .lookup(MonRustDeskChecks.passwordPrefix + account.label.lowercased()).value
            }
            result = await RustDeskServerSSH.readWireGuard(account, secret: secret, sudoPassword: nil,
                                                           container: WireGuardServerScript.defaultContainer, now: now)
        }
        return evaluate(result, probe: probe, now: now)
    }

    /// Règles, sur une lecture déjà faite (testées sur des états fixes).
    public static func evaluate(_ result: Result<WireGuardServerStatus, RustDeskServerReadError>, probe: MonProbe, now: Date) -> MonRunOutcome {
        switch result {
        case .failure(let error):
            return MonRunOutcome(result: .failure(now, error: error.title))
        case .success(let status):
            let known = probe.knownThreats?.first { $0.hasPrefix(keyPrefix) }.map { String($0.dropFirst(keyPrefix.count)) }
            let rows = WireGuardClientRow.rows(status: status, api: nil)
            let findings = WireGuardServerAlerts.findings(status, rows: rows, settings: WireGuardWatchSettings(), knownKey: known, now: now)
            let problems = WireGuardServerAlerts.problems(findings)
            let connected = rows.filter { $0.isConnected(now: now) }.count
            let value = problems.isEmpty ? "wg-easy en marche · \(connected) client\(connected > 1 ? "s" : "") connecté\(connected > 1 ? "s" : "")"
                : problems.joined(separator: " · ")
            var outcome = MonRunOutcome(result: MonResult(date: now, reachable: true, value: value,
                                                          problem: problems.isEmpty ? nil : problems.joined(separator: ", ")))
            if known == nil, let key = status.serverKey { outcome.knownThreats = [keyPrefix + key] }
            return outcome
        }
    }
}
