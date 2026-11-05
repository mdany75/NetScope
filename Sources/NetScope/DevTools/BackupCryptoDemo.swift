import Foundation
import NetScopeCore

/// Démonstration de la note 38 (sauvegarde chiffrée) : sauvegardes chiffrées de la liste, contenu
/// « déverrouillé » de la feuille de restauration. Uniquement des secrets fictifs ; rien n'est lu
/// ni écrit au Trousseau ni sur le disque.
extension ReglagesDemo {
    /// Mot de passe accepté par la feuille de restauration en démonstration (fictif).
    static let demoPassword = "demonstration"

    /// Secrets nommés dans une sauvegarde chiffrée de démonstration (valeurs fictives).
    static let encryptedSecrets: [BackupSecret] = {
        let fictive = Data("valeur fictive de démonstration".utf8)
        // Comptes des FortiGate de démonstration (FortiGateSitesDemo : Siège, Laval, Québec, Drummondville).
        let fortigate = "com.danymenard.netscope.fortigate"
        return [
            BackupSecret(service: "com.danymenard.netscope.alertes", account: AlertSecretKey.smtpPassword, value: fictive,
                         usage: "Alertes (mot de passe SMTP, webhooks, ntfy, Pushover)"),
            BackupSecret(service: fortigate, account: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000001", value: fictive, usage: "Jeton de l’API REST de la FortiGate · Siège"),
            BackupSecret(service: fortigate, account: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000002", value: fictive, usage: "Jeton de l’API REST de la FortiGate · Laval"),
            BackupSecret(service: fortigate, account: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000003", value: fictive, usage: "Jeton de l’API REST de la FortiGate · Québec"),
            BackupSecret(service: fortigate, account: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000004", value: fictive,
                         usage: "Jeton de l’API REST de la FortiGate · Drummondville"),
            BackupSecret(service: "com.danymenard.netscope.github", account: "jeton", value: fictive, usage: "Jeton GitHub (mises à jour)"),
            BackupSecret(service: "com.danymenard.netscope.m365", account: "secret", value: fictive, usage: "Microsoft Graph (services en ligne)"),
            BackupSecret(service: "com.danymenard.netscope.snmp", account: "identifiants", value: fictive, usage: "Identifiants SNMP et communautés"),
            BackupSecret(service: "com.danymenard.netscope.ssh", account: "ssh-netadmin", value: fictive, usage: "Identifiants SSH"),
        ]
    }()

    /// Une sauvegarde chiffrée telle que la liste la voit (en-tête en clair).
    static func encryptedBackup(date: Date, kind: BackupKind, fileCount: Int, bytes: Int64) -> BackupInfo {
        let header = BackupEncryptedHeader(keyDerivation: .init(iterations: BackupCrypto.defaultIterations, salt: Data(repeating: 0x5A, count: 16)),
                                           nonce: Data(repeating: 0x01, count: 12), passwordCheck: Data(count: 32), createdAt: date, kind: kind,
                                           appVersion: "0.14.0", appBuild: "140", fileCount: fileCount, preferenceCount: 46,
                                           secretCount: encryptedSecrets.count)
        let manifest = BackupManifest(createdAt: date, kind: kind, appVersion: "0.14.0", appBuild: "140", files: [], preferencesFile: nil,
                                      preferenceCount: 46, excludedPreferenceKeys: [], skippedFiles: [], keychain: [], note: "", encrypted: true)
        return BackupInfo(url: RegBackupController.defaultFolder.appendingPathComponent(BackupEngine.name(for: date, kind: kind, format: .chiffree)),
                          format: .chiffree, manifest: manifest, bytes: bytes, encryption: header)
    }

    /// Contenu « déverrouillé » d'une sauvegarde chiffrée de démonstration.
    static func unlockedContents(_ info: BackupInfo) -> BackupContents {
        let count = info.encryption?.fileCount ?? 8
        let names = ["etat.json", "inventaire.json", "surveillance.json", "outils.json", "services-en-ligne.json",
                     "notes-appareils.json", "disques.json", "identifiants.json", "sites.json"]
        let files = names.prefix(count).map { BackupZip.Entry(path: $0, data: Data()) }
        var manifest = info.manifest
        manifest.files = files.map { BackupManifest.File(path: $0.path, bytes: 0, crc32: 0) }
        manifest.secrets = encryptedSecrets.map(\.item)
        return BackupContents(manifest: manifest, files: files, preferences: nil, secrets: info.includesSecrets ? encryptedSecrets : [],
                              encryption: info.encryption)
    }

    /// Captures : NETSCOPE_SAUVEGARDE_FEUILLE=chiffrer (feuille du mot de passe) ou restaurer
    /// (feuille de restauration, déverrouillée) dessinée dans la page.
    static var snapshotSheet: String? {
        guard RegEnvironment.isSnapshot else { return nil }
        return ProcessInfo.processInfo.environment["NETSCOPE_SAUVEGARDE_FEUILLE"]
    }
}
