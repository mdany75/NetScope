import CryptoKit
import Darwin
import Foundation

// Note 56 : exporter, importer et synchroniser la configuration de NetScope.
//
// Registre des PARTIES de la configuration (« Sites et préréglages », « FortiGate et leurs jetons »,
// « Inventaires et historiques »…) : chaque partie dit quels fichiers JSON du dossier de données,
// quelles préférences et quels secrets du Trousseau lui appartiennent (motifs à la fnmatch). La
// première partie qui reconnaît un élément le prend ; ce qu'aucune ne reconnaît va dans la partie
// « fourre-tout » (Réglages), si bien qu'un nouveau fichier ou un nouveau réglage d'une autre
// fonction est exporté même avant d'être rangé ici.
//
// Ajouter une partie (emplacements NAS de la note 55, connexions FTP de la note 50, services
// cochés de la note 53…) : une entrée dans `ConfigPart.builtIn`, avant la partie fourre-tout, ou
// `ConfigPartRegistry.register(_:)`. Une liste dont les éléments ont un identifiant (sites,
// FortiGate) se fusionne élément par élément : la déclarer dans `ConfigCollection.standard`.

/// Nature d'un élément de la configuration.
public enum ConfigItemKind: String, Codable, Sendable, CaseIterable {
    /// Fichier JSON du dossier de données (chemin relatif).
    case fichier
    /// Préférence de l'app (UserDefaults).
    case preference
    /// Secret du Trousseau (service, compte).
    case secret
    /// Élément d'une liste à identifiants (un site de sites.json, une FortiGate).
    case element
}

/// Une partie de la configuration, cochée ou non à l'export comme à l'import.
public struct ConfigPart: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var systemImage: String
    /// Motifs des chemins relatifs des fichiers JSON (« sites.json », « sites/* »).
    public var files: [String]
    /// Motifs des clés de préférences (« reglages.scan.* »).
    public var preferences: [String]
    /// Motifs « service/compte » des secrets, le service sans le préfixe de NetScope
    /// (« fortigate/* », « alertes/webhook.* »).
    public var secrets: [String]
    /// Partie qui prend ce qu'aucune autre ne reconnaît.
    public var catchAll: Bool

    public init(id: String, title: String, detail: String, systemImage: String, files: [String] = [], preferences: [String] = [],
                secrets: [String] = [], catchAll: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.files = files
        self.preferences = preferences
        self.secrets = secrets
        self.catchAll = catchAll
    }

    /// Parties de NetScope, dans l'ordre de l'écran (la partie fourre-tout en dernier).
    public static let builtIn: [ConfigPart] = [
        ConfigPart(id: "sites", title: "Sites et préréglages",
                   detail: "Sites, plages, préréglages de ports du Scanner, plages et noms en cours.",
                   systemImage: "building.2",
                   files: ["sites.json", "etat.json"],
                   preferences: ["scan.*"]),
        ConfigPart(id: "fortigate", title: "FortiGate et leurs jetons",
                   detail: "FortiGate de chaque site (adresse, VDOM, plages, certificat) et leurs jetons d’API.",
                   systemImage: "shield.lefthalf.filled",
                   preferences: ["NetScope.fortigate.*"],
                   secrets: ["fortigate/*"]),
        ConfigPart(id: "switchs", title: "Switchs et communautés SNMP",
                   detail: "Switchs SNMP, découverte automatique, communautés et identifiants SNMP v3.",
                   systemImage: "point.3.connected.trianglepath.dotted",
                   preferences: ["NetScope.switchs.*", "reglages.switchs.*"],
                   secrets: ["snmp/*"]),
        ConfigPart(id: "identifiants", title: "Identifiants SSH et WMI",
                   detail: "Comptes SSH et WMI, clés, phrases secrètes et utilisateurs mémorisés.",
                   systemImage: "person.badge.key",
                   files: ["identifiants.json", "ssh-utilisateurs.json"],
                   preferences: ["reglages.identifiants.*"],
                   secrets: ["ssh/*", "wmi/*"]),
        ConfigPart(id: "alertes", title: "SMTP et webhooks",
                   detail: "Alertes par courriel (serveur SMTP et son mot de passe) et webhooks.",
                   systemImage: "envelope.badge",
                   preferences: ["alertes.*"],
                   secrets: ["alertes/*", "smtp/*", "webhook/*"]),
        ConfigPart(id: "raccourcis", title: "Raccourcis",
                   detail: "Raccourcis clavier personnalisés.",
                   systemImage: "command",
                   preferences: ["reglages.raccourcis*"]),
        ConfigPart(id: "profils", title: "Profils de scan",
                   detail: "Profil par défaut, méthodes de découverte, ports, délais, tentatives et fils.",
                   systemImage: "slider.horizontal.3",
                   preferences: ["reglages.scan.*"]),
        ConfigPart(id: "inventaires", title: "Inventaires et historiques",
                   detail: "Inventaire et résultats de chaque site, notes des appareils, Surveillance, vitesses, disques, Wi-Fi.",
                   systemImage: "archivebox",
                   files: ["sites/*", "inventory*.json", "inventaire*.json", "notes-appareils*.json", "surveillance*.json",
                           "disques.json", "speedtest.json", "diagnostics-wifi.json", "wifi-signal.json", "Rapports/*"]),
        ConfigPart(id: "reglages", title: "Réglages",
                   detail: "Tous les autres réglages\u{00A0}: général, interface, notifications, colonnes, Boîte à outils, services en ligne, mises à jour.",
                   systemImage: "gearshape",
                   secrets: ["*"],
                   catchAll: true),
    ]
}

/// Registre des parties (ordre = priorité).
public struct ConfigPartRegistry: Sendable {
    public private(set) var parts: [ConfigPart]

    /// Préférences jamais exportées ni synchronisées : propres à ce Mac (sauvegarde, synchro,
    /// import en attente) ou à macOS (fenêtres, panneaux).
    public static let excludedPreferences = ["sauvegarde.*", "configuration.*", "synchro.*", "NS*", "Apple*", "com.apple.*", "WebKit*"]
    /// Fichiers jamais exportés : travail en cours propre à ce Mac, copies mises de côté.
    public static let excludedFiles = ["disques-en-cours.json", "sites.illisible-*.json"]

    public init(parts: [ConfigPart]) {
        self.parts = parts
    }

    public static let standard = ConfigPartRegistry(parts: ConfigPart.builtIn)

    /// Ajoute une partie avant `before` (par défaut avant la partie fourre-tout) ; une partie du
    /// même identifiant est remplacée.
    public mutating func register(_ part: ConfigPart, before: String? = nil) {
        parts.removeAll { $0.id == part.id }
        let target = before.flatMap { id in parts.firstIndex { $0.id == id } } ?? parts.firstIndex { $0.catchAll } ?? parts.count
        parts.insert(part, at: target)
    }

    public func part(_ id: String) -> ConfigPart? { parts.first { $0.id == id } }

    public var ids: [String] { parts.map(\.id) }

    /// Partie d'un fichier JSON du dossier de données ; nil s'il n'est jamais exporté.
    public func part(forFile path: String) -> ConfigPart? {
        guard BackupEngine.isSafeRelativePath(path), !Self.excludedFiles.contains(where: { ConfigMatch.glob($0, path) }) else { return nil }
        return parts.first { !$0.catchAll && $0.files.contains { ConfigMatch.glob($0, path) } } ?? parts.first(where: \.catchAll)
    }

    /// Partie d'une préférence ; nil si elle n'est jamais exportée (propre à ce Mac, ou nom qui
    /// évoque un secret : ces préférences ne quittent jamais ce Mac).
    public func part(forPreference key: String) -> ConfigPart? {
        guard !Self.excludedPreferences.contains(where: { ConfigMatch.glob($0, key) }) else { return nil }
        let lower = key.lowercased()
        guard !BackupEngine.secretKeyFragments.contains(where: lower.contains) else { return nil }
        return parts.first { !$0.catchAll && $0.preferences.contains { ConfigMatch.glob($0, key) } } ?? parts.first(where: \.catchAll)
    }

    /// Partie d'un secret du Trousseau ; nil pour un service étranger, le mot de passe des
    /// sauvegardes ou celui de la synchronisation (jamais copiés).
    public func part(forSecret service: String, account: String) -> ConfigPart? {
        guard BackupKeychainScan.isOwnService(service), !ConfigSecrets.neverCopied.contains(service) else { return nil }
        let name = ConfigSecrets.shortService(service) + "/" + account
        return parts.first { !$0.catchAll && $0.secrets.contains { ConfigMatch.glob($0, name) } }
            ?? parts.first { $0.catchAll && $0.secrets.contains { ConfigMatch.glob($0, name) } }
    }
}

/// Secrets jamais copiés et noms courts des services.
public enum ConfigSecrets {
    /// Mot de passe de la synchronisation par iCloud Drive (Trousseau de chaque Mac).
    public static let syncService = BackupKeychainScan.servicePrefix + ".synchro"
    public static let syncAccount = "mot-de-passe"
    /// Ni le mot de passe des sauvegardes ni celui de la synchronisation ne voyagent.
    public static let neverCopied: Set<String> = [BackupPasswordKeychain.service, syncService]

    /// « fortigate » pour « com.danymenard.netscope.fortigate ».
    public static func shortService(_ service: String) -> String {
        let prefix = BackupKeychainScan.servicePrefix + "."
        return service.hasPrefix(prefix) ? String(service.dropFirst(prefix.count)) : service
    }
}

/// Motifs à la fnmatch (« * » traverse aussi les « / »).
public enum ConfigMatch {
    public static func glob(_ pattern: String, _ text: String) -> Bool {
        fnmatch(pattern, text, 0) == 0
    }
}

/// Empreinte SHA-256 en hexadécimal (comparaison des versions, jamais pour un secret en clair
/// hors de la partie chiffrée).
public enum ConfigHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Valeurs de préférences : chaque valeur est gardée en liste de propriétés binaire (Data,
/// donc Sendable) et comparée après relecture (l'ordre des clés d'un dictionnaire n'y compte pas).
public enum ConfigPlist {
    public static func encode(_ value: Any) -> Data? {
        guard PropertyListSerialization.propertyList([value], isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
    }

    public static func decode(_ data: Data) -> Any? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any])?.first
    }

    public static func equal(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard let left = decode(a), let right = decode(b) else { return false }
        return ([left] as NSArray).isEqual([right] as NSArray)
    }

    /// Empreinte stable d'une valeur (relue puis réécrite en XML trié quand c'est possible).
    public static func hash(_ data: Data) -> String {
        if let value = decode(data), let xml = try? PropertyListSerialization.data(fromPropertyList: [value], format: .xml, options: 0) {
            return ConfigHash.sha256(xml)
        }
        return ConfigHash.sha256(data)
    }
}
