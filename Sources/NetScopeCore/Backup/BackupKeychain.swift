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
        default: return suffix
        }
    }
}
