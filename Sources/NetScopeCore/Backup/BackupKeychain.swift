import Foundation
import Security

/// Recense les comptes du Trousseau de NetScope (services « com.danymenard.netscope.* ») pour le
/// manifeste des sauvegardes : seuls les attributs (service, compte) sont lus, jamais les secrets,
/// donc sans fenêtre d'autorisation de macOS.
public enum BackupKeychainScan {
    public static let servicePrefix = "com.danymenard.netscope"

    public static func items() -> [BackupKeychainItem] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let list = result as? [[String: Any]] else { return [] }
        var items: [BackupKeychainItem] = []
        for attributes in list {
            guard let service = attributes[kSecAttrService as String] as? String, service.hasPrefix(servicePrefix) else { continue }
            let account = attributes[kSecAttrAccount as String] as? String ?? ""
            items.append(BackupKeychainItem(service: service, account: account, usage: usage(for: service)))
        }
        return items.sorted { ($0.service, $0.account) < ($1.service, $1.account) }
    }

    /// À quoi sert un service (libellé du manifeste et de l'écran).
    public static func usage(for service: String) -> String {
        let suffix = service.hasPrefix(servicePrefix + ".") ? String(service.dropFirst(servicePrefix.count + 1)) : service
        switch suffix {
        case "snmp": return "Identifiants SNMP et communautés"
        case "github": return "Jeton GitHub (mises à jour)"
        case "m365": return "Microsoft Graph (services en ligne)"
        case "ssh": return "Identifiants SSH"
        case "wmi": return "Identifiants WMI"
        case "smtp": return "Alertes par courriel (SMTP)"
        case "webhook": return "Alertes par webhook"
        case "fortigate": return "Jeton de l’API REST de la FortiGate"
        case "alertes": return "Alertes (mot de passe SMTP, webhooks)"
        case "sauvegarde": return "Mot de passe des sauvegardes chiffrées"
        default: return suffix
        }
    }
}

// MARK: - Secrets des sauvegardes chiffrées (note 38)

/// Mot de passe des sauvegardes chiffrées, mémorisé au Trousseau seulement si l'utilisateur le
/// demande (sauvegarde automatique quotidienne). Jamais rangé dans une sauvegarde.
public enum BackupPasswordKeychain {
    public static let service = BackupKeychainScan.servicePrefix + ".sauvegarde"
    public static let account = "mot-de-passe"
}

/// Le Trousseau de macOS comme source et destination des secrets d'une sauvegarde chiffrée :
/// tous les éléments « mot de passe générique » des services com.danymenard.netscope.*, sauf le
/// mot de passe des sauvegardes. Lire une valeur peut faire demander l'accord de macOS.
public struct BackupKeychainSecrets: BackupSecretStore {
    public init() {}

    public func readSecrets() throws -> [BackupSecret] {
        var secrets: [BackupSecret] = []
        for item in BackupKeychainScan.items() where item.service != BackupPasswordKeychain.service {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: item.service,
                                        kSecAttrAccount as String: item.account,
                                        kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            query.removeAll()
            guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else { continue }
            secrets.append(BackupSecret(service: item.service, account: item.account, value: data, usage: item.usage))
        }
        return secrets
    }

    public func write(_ secret: BackupSecret) throws {
        guard secret.service.hasPrefix(BackupKeychainScan.servicePrefix + "."), secret.service != BackupPasswordKeychain.service else {
            throw BackupError.corrupted("service « \(secret.service) » refusé")
        }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: secret.service,
                                   kSecAttrAccount as String: secret.account]
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: secret.value] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Self.error(update) }
        var add = base
        add[kSecValueData as String] = secret.value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "NetScope — \(secret.account)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    private static func error(_ status: OSStatus) -> BackupError {
        .corrupted("Trousseau\u{00A0}: " + (SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"))
    }
}
