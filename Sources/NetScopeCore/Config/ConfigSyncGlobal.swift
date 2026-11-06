import Foundation

// Note 86 : données globales de ce Mac (dossier « _global » de la synchronisation), tirées d'un
// `ConfigSnapshot` : fichiers JSON hors des sites (découpés en éléments quand ils ont des listes à
// identifiants), préférences utiles et secrets du Trousseau liés, chacun dans sa catégorie (les
// parties de l'export). Ce qui est propre à ce Mac (`ConfigSyncPolicy`) n'y est jamais.

public enum ConfigSyncGlobal {
    /// Éléments globaux de ce Mac (toutes catégories ; le moteur écarte les catégories décochées).
    public static func make(snapshot: ConfigSnapshot, registry: ConfigPartRegistry = .standard) -> ConfigSyncLocalSite {
        var items: [String: ConfigSyncLocalSite.Item] = [:]
        for file in snapshot.files where ConfigSyncPolicy.isGlobalFile(file.path, registry: registry) {
            if let rule = ConfigSyncPolicy.rule(for: file.path), let parts = ConfigSyncDocument.split(file.data, path: file.path, rule: rule) {
                for part in parts {
                    items[part.key] = ConfigSyncLocalSite.Item(label: part.label, data: part.json, hash: part.hash, modifiedHint: file.modified)
                }
            } else {
                items[ConfigSyncKey.file(file.path)] = ConfigSyncLocalSite.Item(label: ConfigSyncPolicy.label(forFile: file.path), data: file.data,
                                                                                hash: ConfigHash.sha256(file.data), modifiedHint: file.modified)
            }
        }
        for (key, data) in snapshot.preferences where ConfigSyncPolicy.isGlobalPreference(key, registry: registry) {
            items[ConfigSyncKey.preference(key)] = ConfigSyncLocalSite.Item(label: preferenceLabel(key, registry: registry), data: data, hash: ConfigPlist.hash(data),
                                                                            modifiedHint: nil)
        }
        let secrets = snapshot.secrets.filter { ConfigSyncPolicy.isGlobalSecret($0.service) && registry.part(forSecret: $0.service, account: $0.account) != nil }
        return ConfigSyncLocalSite(siteID: ConfigSyncPolicy.globalID, name: "Données globales", exists: true, items: items, secrets: secrets)
    }

    /// Catégorie (`ConfigPart.id`) d'une clé globale ; nil : refusée (propre à un Mac, d'un site, inconnue).
    public static func category(forKey key: String, registry: ConfigPartRegistry = .standard) -> String? {
        if key.hasPrefix("secret:") {
            let name = key.dropFirst("secret:".count)
            guard let bar = name.firstIndex(of: "|") else { return nil }
            let service = String(name[..<bar]), account = String(name[name.index(after: bar)...])
            guard ConfigSyncPolicy.isGlobalSecret(service) else { return nil }
            return registry.part(forSecret: service, account: account)?.id
        }
        switch ConfigSyncKey.parse(key) {
        case .document(let path), .element(let path, _, _), .file(let path):
            guard ConfigSyncPolicy.isGlobalFile(path, registry: registry) else { return nil }
            return registry.part(forFile: path)?.id
        case .preference(let name):
            guard ConfigSyncPolicy.isGlobalPreference(name, registry: registry) else { return nil }
            return registry.part(forPreference: name)?.id
        default:
            return nil
        }
    }

    /// Noms des écrans dans les clés des seuils (« NetScope.wifi.seuils »).
    static let thresholdScreens: [String: String] = [
        "wifi": "Wi-Fi", "trafic": "Trafic", "wan": "Liens WAN", "firmware": "Micrologiciels", "fortiap": "FortiAP",
        "switchs": "Switchs", "surveillance": "Surveillance", "disques": "Disques", "vitesse": "Vitesse",
    ]

    /// Libellé lisible d'une préférence (« Profil de scan · fils ») ; jamais la clé interne.
    static func preferenceLabel(_ key: String, registry: ConfigPartRegistry = .standard) -> String {
        let known: [String: String] = [
            "reglages.raccourcis": "Raccourcis clavier",
            "reglages.notifications": "Notifications",
            "alertes.reglages": "Canaux d’alerte",
            "reglages.scan.threads": "Profil de scan · fils",
            "reglages.scan.delaiMs": "Profil de scan · délai",
            "reglages.scan.tentatives": "Profil de scan · tentatives",
            "reglages.scan.ports": "Profil de scan · ports",
            "reglages.scan.methodes": "Profil de scan · méthodes",
            "reglages.scan.profilParDefaut": "Profil de scan par défaut",
            "NetScope.switchs.hotes": "Switchs SNMP",
            "NetScope.switchs.ignores": "Switchs écartés",
            "NetScope.switchs.decouverts": "Switchs découverts",
            "reglages.switchs.decouverteAuto": "Découverte automatique des switchs",
            "NetScope.fortigate.reglages": "Réglages FortiGate",
            "NetScope.actionsPorts.reglages": "Actions sur les ports",
            "NetScope.relecture.intervalles": "Relecture automatique",
            "smb.utilisateurs": "Utilisateurs SMB",
            "acces.serie.reglages": "Console série",
            "reglages.general.confirmerPlagePublique": "Confirmation des plages publiques",
            "reglages.identifiants.adresseTest": "Adresse de test des identifiants",
            "reglages.switchs.arpPasserelle": "Table ARP de la passerelle",
            "reglages.fortiswitch": "Réglages FortiSwitch",
            "reglages.export.format": "Format d’export",
            "reglages.plages": "Plages enregistrées",
        ]
        if let label = known[key] { return label }
        if key.hasSuffix(".seuils") {
            let screen = key.split(separator: ".").dropFirst().dropLast().joined(separator: " ")
            let name = thresholdScreens[screen] ?? (screen.prefix(1).uppercased() + screen.dropFirst())
            return "Seuils d’alerte · " + name
        }
        if let part = registry.part(forPreference: key) { return "Réglage de la catégorie «\u{00A0}\(part.title)\u{00A0}»" }
        return "Réglage"
    }

    // MARK: Compteurs par catégorie (écran Réglages › Synchronisation)

    /// Ce qu'une catégorie synchronise sur ce Mac.
    public struct CategoryCount: Identifiable, Hashable, Sendable {
        public var part: ConfigPart
        public var files: Int = 0
        public var elements: Int = 0
        public var preferences: Int = 0
        public var secrets: Int = 0
        /// Éléments des sites (fiches, inventaires, FortiGate).
        public var siteItems: Int = 0

        public init(part: ConfigPart, files: Int = 0, elements: Int = 0, preferences: Int = 0, secrets: Int = 0, siteItems: Int = 0) {
            self.part = part
            self.files = files
            self.elements = elements
            self.preferences = preferences
            self.secrets = secrets
            self.siteItems = siteItems
        }

        public var id: String { part.id }
        public var isEmpty: Bool { files + elements + preferences + secrets + siteItems == 0 }

        /// « 3 fichiers · 12 éléments · 4 réglages · 2 secrets ».
        public var summary: String {
            var parts: [String] = []
            func add(_ count: Int, _ one: String, _ many: String) {
                if count > 0 { parts.append("\(count)\u{00A0}\(count > 1 ? many : one)") }
            }
            add(siteItems, "élément de site", "éléments de sites")
            add(files, "fichier", "fichiers")
            add(elements, "élément", "éléments")
            add(preferences, "réglage", "réglages")
            add(secrets, "secret", "secrets")
            return parts.isEmpty ? "Rien sur ce Mac" : parts.joined(separator: " · ")
        }
    }

    /// Compteurs de chaque catégorie, dans l'ordre du registre. `sites` : sites synchronisés.
    public static func counts(snapshot: ConfigSnapshot, sites: [UUID], registry: ConfigPartRegistry = .standard) -> [CategoryCount] {
        var byID: [String: CategoryCount] = [:]
        for part in registry.parts { byID[part.id] = CategoryCount(part: part) }
        let global = make(snapshot: snapshot, registry: registry)
        for key in global.items.keys {
            guard let category = category(forKey: key, registry: registry) else { continue }
            switch ConfigSyncKey.parse(key) {
            case .element: byID[category]?.elements += 1
            case .preference: byID[category]?.preferences += 1
            default: byID[category]?.files += 1
            }
        }
        for secret in global.secrets {
            if let category = category(forKey: ConfigSyncKey.secret(service: secret.service, account: secret.account), registry: registry) {
                byID[category]?.secrets += 1
            }
        }
        let names = snapshot.secretNames.filter { ConfigSyncPolicy.isGlobalSecret($0.service) }
        if global.secrets.isEmpty {
            // Secrets pas lus (pas de mot de passe de synchronisation) : comptés par leur nom.
            for item in names {
                if let category = category(forKey: ConfigSyncKey.secret(service: item.service, account: item.account), registry: registry) {
                    byID[category]?.secrets += 1
                }
            }
        }
        for id in sites {
            let local = ConfigSyncLocalSite.make(siteID: id, snapshot: snapshot)
            for key in local.items.keys { byID[ConfigSyncLocalSite.category(forSiteKey: key)]?.siteItems += 1 }
        }
        return registry.parts.compactMap { byID[$0.id] }
    }
}
