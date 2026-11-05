import Foundation
import Security

/// Secrets dans le Trousseau macOS (éléments « mot de passe générique »), par service et compte.
/// Services utilisés : com.danymenard.netscope.github (jeton GitHub), com.danymenard.netscope.snmp.
public struct UpdKeychain: Sendable {
    public static let github = UpdKeychain(service: "com.danymenard.netscope.github")
    public static let githubAccount = "jeton"

    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Valeur enregistrée, ou nil (absente ou illisible).
    public func string(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Enregistre (ou remplace) la valeur ; une valeur vide efface l'élément.
    public func set(_ value: String?, for account: String) throws {
        guard let value, !value.isEmpty else {
            try delete(account)
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw UpdKeychain.error(update) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "NetScope — \(account)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw UpdKeychain.error(status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UpdKeychain.error(status) }
    }

    private static func error(_ status: OSStatus) -> UpdError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
        return .installation("Trousseau : \(message)")
    }
}

/// Une version installée (historique).
public struct UpdHistoryEntry: Codable, Hashable, Sendable {
    public var version: String
    public var channel: UpdChannel
    public var date: Date

    public init(version: String, channel: UpdChannel, date: Date) {
        self.version = version
        self.channel = channel
        self.date = date
    }
}

/// Préférences de mise à jour (enregistrées par l'application en JSON dans UserDefaults).
public struct UpdPreferences: Codable, Hashable, Sendable {
    public var channel: UpdChannel = .stable
    public var frequency: UpdFrequency = .quotidienne
    public var automaticCheck = true
    public var automaticInstall = false
    public var lastCheck: Date?
    /// Version que l'utilisateur a choisi d'ignorer.
    public var skippedVersion: String?
    /// Versions installées, la plus récente en premier.
    public var history: [UpdHistoryEntry] = []

    public init() {}

    /// Vrai si la vérification automatique doit avoir lieu maintenant.
    public func isCheckDue(now: Date = Date(), atLaunch: Bool) -> Bool {
        automaticCheck && frequency.isDue(lastCheck: lastCheck, now: now, atLaunch: atLaunch)
    }

    /// Note la version en cours si elle diffère de la dernière de l'historique (200 entrées au plus).
    public mutating func recordRunning(version: String, now: Date = Date()) {
        guard history.first?.version != version else { return }
        let isBeta = UpdVersion(version)?.isPrerelease ?? false
        history.insert(UpdHistoryEntry(version: version, channel: isBeta ? .beta : .stable, date: now), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
    }

    /// Vrai si `release` est la version ignorée.
    public func isSkipped(_ release: UpdRelease) -> Bool {
        guard let skippedVersion, let version = release.version else { return false }
        return UpdVersion(skippedVersion) == version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = try container.decodeIfPresent(UpdChannel.self, forKey: .channel) ?? .stable
        frequency = try container.decodeIfPresent(UpdFrequency.self, forKey: .frequency) ?? .quotidienne
        automaticCheck = try container.decodeIfPresent(Bool.self, forKey: .automaticCheck) ?? true
        automaticInstall = try container.decodeIfPresent(Bool.self, forKey: .automaticInstall) ?? false
        lastCheck = try container.decodeIfPresent(Date.self, forKey: .lastCheck)
        skippedVersion = try container.decodeIfPresent(String.self, forKey: .skippedVersion)
        history = try container.decodeIfPresent([UpdHistoryEntry].self, forKey: .history) ?? []
    }
}
