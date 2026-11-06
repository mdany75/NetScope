import Foundation

/// Note 87 (0.33.0) : sonde « Serveur RustDesk » de Surveillance, aussi exécutée par l'agent.
/// Une lecture SSH en lecture seule (le même script que le tableau de bord) ; panne si hbbs ou
/// hbbr est arrêté, si le disque dépasse le seuil ou si la clé publique change (la première clé lue
/// est retenue dans `knownThreats`, sous la forme « cle:<clé> »).
public enum MonRustDeskChecks {
    public static let keyPrefix = "cle:"
    /// Trousseau du mot de passe d'un compte saisi (même nom que le tableau de bord).
    public static let keychainService = "com.danymenard.netscope.rustdesk"
    public static let passwordPrefix = "tableau-serveur-ssh:"
    /// Trousseau des connexions du carnet d'Accès distant (mot de passe sous l'UUID de la connexion).
    public static let connectionKeychainService = "com.danymenard.netscope.acces"

    /// Compte lu par l'agent : cible « utilisateur@hôte[:port] » et paramètres non secrets de la sonde.
    public static func account(for probe: MonProbe, target: String) throws -> RustDeskServerAccount {
        var account = try RustDeskServerAccount.parse(target)
        account.keyPath = probe.sshKeyPath ?? ""
        account.jump = probe.sshJump ?? ""
        return try account.validated()
    }

    public static func run(_ probe: MonProbe, target: String,
                           read: (@Sendable (String) async -> Result<RustDeskServerStatus, RustDeskServerReadError>)?,
                           now: Date) async -> MonRunOutcome {
        let result: Result<RustDeskServerStatus, RustDeskServerReadError>
        if let read {
            result = await read(target)
        } else {
            guard let account = try? account(for: probe, target: target) else {
                return MonRunOutcome(result: .failure(now, error: "Compte attendu\u{00A0}: utilisateur@hôte"))
            }
            let secret: String?
            if let connection = probe.sshConnection {
                secret = UpdKeychain(service: connectionKeychainService).lookup(connection.uuidString).value
            } else {
                secret = UpdKeychain(service: keychainService).lookup(passwordPrefix + account.label.lowercased()).value
            }
            result = await RustDeskServerSSH.run(account, secret: secret)
        }
        return evaluate(result, probe: probe, now: now)
    }

    /// Règles, sur une lecture déjà faite (testées sur des états fixes).
    public static func evaluate(_ result: Result<RustDeskServerStatus, RustDeskServerReadError>, probe: MonProbe, now: Date) -> MonRunOutcome {
        switch result {
        case .failure(let error):
            return MonRunOutcome(result: .failure(now, error: error.title))
        case .success(let status):
            let known = probe.knownThreats?.first { $0.hasPrefix(keyPrefix) }.map { String($0.dropFirst(keyPrefix.count)) }
            let limit = probe.resourceLimit ?? MonProbe.defaultResourceLimit(.rustdeskServer)
            let problems = RustDeskServerAlerts.problems(status, knownKey: known, diskLimitPercent: limit)
            let disk = status.disk.map { "disque \(Int(($0.usedFraction * 100).rounded()))\u{00A0}%" } ?? "disque inconnu"
            let value = problems.isEmpty ? "hbbs et hbbr en marche · \(disk)" : problems.joined(separator: " · ")
            var outcome = MonRunOutcome(result: MonResult(date: now, reachable: true, value: value,
                                                          problem: problems.isEmpty ? nil : problems.joined(separator: ", ")))
            if known == nil, let key = status.publicKey.value { outcome.knownThreats = [keyPrefix + key] }
            return outcome
        }
    }
}
