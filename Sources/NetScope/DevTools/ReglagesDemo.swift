import Foundation
import NetScopeCore

/// Données de démonstration des Réglages (note 13) : sauvegardes, comptes du Trousseau,
/// identifiants SSH et WMI, résultats de tests. Rien n'est lu ni écrit sur le disque ni envoyé.
enum ReglagesDemo {
    /// Date fixe de la démonstration (3 nov. 2026, 08:00), comme le croquis.
    static let reference: Date = {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 3; parts.hour = 8; parts.minute = 0
        return Calendar.current.date(from: parts) ?? Date()
    }()

    static let keychainItems: [BackupKeychainItem] = [
        BackupKeychainItem(service: "com.danymenard.netscope.github", account: "jeton", usage: "Jeton GitHub (mises à jour)"),
        BackupKeychainItem(service: "com.danymenard.netscope.snmp", account: "identifiants", usage: "Identifiants SNMP et communautés"),
        BackupKeychainItem(service: "com.danymenard.netscope.ssh", account: "ssh-netadmin", usage: "Identifiants SSH"),
        BackupKeychainItem(service: "com.danymenard.netscope.wmi", account: "wmi-domaine", usage: "Identifiants WMI"),
    ]

    /// Tailles à la plus récente sauvegarde ; les plus anciennes sont un peu plus petites (inventaire qui grossit).
    private static let files: [(String, Int)] = [
        ("etat.json", 2_184), ("inventaire.json", 182_406), ("surveillance.json", 48_912), ("outils.json", 6_310),
        ("services-en-ligne.json", 3_877), ("notes-appareils.json", 1_942), ("disques.json", 4_506), ("identifiants.json", 1_128),
    ]

    static func backups() -> [BackupInfo] {
        let folder = RegBackupController.defaultFolder
        let plan: [(TimeInterval, BackupKind, BackupFormat, Int)] = [
            (0, .automatique, .chiffree, 8), (-86_400, .automatique, .chiffree, 8), (-86_400 - 3 * 3600 - 1080, .securite, .zip, 8),
            (-2 * 86_400, .automatique, .zip, 7), (-3 * 86_400 + 5 * 3600, .manuelle, .dossier, 7), (-4 * 86_400, .automatique, .zip, 7),
        ]
        return plan.map { offset, kind, format, count in
            let date = reference.addingTimeInterval(offset)
            let manifestFiles = files.prefix(count).map { BackupManifest.File(path: $0.0, bytes: $0.1 + Int(offset / 3600) * 37, crc32: 0) }
            let manifest = BackupManifest(createdAt: date, kind: kind, appVersion: "0.8.0", appBuild: "80", files: Array(manifestFiles),
                                          preferencesFile: BackupEngine.preferencesName, preferenceCount: 46,
                                          excludedPreferenceKeys: [], skippedFiles: ["oui.tsv"], keychain: keychainItems,
                                          note: "")
            let bytes = Int64(manifestFiles.reduce(0) { $0 + $1.bytes } + 9_800)
            if format == .chiffree {
                // Note 38 : sauvegarde chiffrée, avec les secrets du Trousseau (en-tête en clair seulement).
                return encryptedBackup(date: date, kind: kind, fileCount: count, bytes: bytes + 1_240)
            }
            return BackupInfo(url: folder.appendingPathComponent(BackupEngine.name(for: date, kind: kind, format: format)),
                              format: format, manifest: manifest, bytes: bytes)
        }
    }

    static func remoteCredentials() -> [RemoteCredential] {
        [
            RemoteCredential(kind: .ssh, name: "ssh-netadmin", user: "netadmin", port: 22, sshMethod: .key, keyPath: "~/.ssh/id_ed25519",
                             scope: "Switchs SW-CORE-01, SW-ETG2-01", lastHost: "10.182.122.2",
                             lastTestAt: reference.addingTimeInterval(-6 * 86_400 + 4 * 3600), lastTestStatus: .success,
                             lastTestMessage: "Réussi · 10.182.122.2 · session ouverte · Linux sw-core-01 5.10.120 · 212\u{00A0}ms"),
            RemoteCredential(kind: .ssh, name: "ssh-nas-admin", user: "admin", port: 2222, sshMethod: .password,
                             scope: "NAS Synology", lastHost: "10.182.122.40"),
            RemoteCredential(kind: .wmi, name: "wmi-domaine", user: "svc-ipscan", domain: "BUREAU", scope: "Plage 10.10.0.1-10.10.0.50",
                             lastHost: "10.10.0.10", lastTestAt: reference.addingTimeInterval(-3600), lastTestStatus: .partial,
                             lastTestMessage: "Joignable · 10.10.0.10 répond sur 135 (DCOM/RPC (WMI)), 5985 (WinRM HTTP). Authentification non vérifiée (pas de client WMI sous macOS)."),
        ]
    }

    /// Résultats affichés sous les identifiants SNMP en démonstration.
    static let snmpV2Result = SNMPCredentialTest.Outcome(
        success: SNMPCredentialTest.Success(sysName: "SW-ETG2-01", sysDescr: "Aruba JL259A 2930F-24G-4SFP Switch, revision WC.16.11.0012",
                                            uptimeTicks: 120_864_000, milliseconds: 38),
        failure: nil, message: "")
    static let snmpV3Result = SNMPCredentialTest.Outcome(
        success: SNMPCredentialTest.Success(sysName: "SW-CORE-01", sysDescr: "Cisco IOS XE Software, Catalyst 9300-48P, Version 17.9.4a",
                                            uptimeTicks: 361_512_300, milliseconds: 41),
        failure: nil, message: "")
}
