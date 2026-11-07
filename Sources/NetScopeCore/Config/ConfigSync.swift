import CryptoKit
import Foundation

// Note 56 : synchronisation de la configuration entre plusieurs Mac par un simple dossier (iCloud
// Drive › NetScope › Sync par défaut, jamais CloudKit). Note 86 : étendue à TOUTES les données.
//
// Forme du dossier :
//   <racine>/<identifiant du site>/<identifiant du Mac>.json   un fichier par Mac et par site
//   <racine>/_global/<identifiant du Mac>.json                 données globales (note 86)
//   <racine>/_appareils/<identifiant du Mac>.json              fiche du Mac (nom, modèle, version)
// Chaque Mac n'écrit que SES fichiers (aucune écriture concurrente du même fichier, donc pas de
// copies « 2 » d'iCloud) ; il lit ceux des autres. Les versions 0.18 à 0.28 de NetScope ne lisent
// que les dossiers nommés par un identifiant de site : « _global » et « _appareils » leur sont
// invisibles, et les fichiers des sites gardent le format 1 (champs nouveaux facultatifs, ignorés
// par elles).
//
// Un fichier (`ConfigSyncBundle`) porte des éléments (`ConfigSyncItem`) : pour un site, sa fiche,
// ses fichiers (inventaire, notes, derniers résultats, relevé Wi-Fi, carte), ses FortiGate ; pour
// le global, une connexion, une sonde, un identifiant, un fichier entier ou une préférence par
// élément (`ConfigSyncPolicy`, `ConfigSyncDocument`). Les secrets du Trousseau liés à ces données
// sont chiffrés par le mot de passe de synchronisation (même chiffrement que la note 38). Avec ce
// mot de passe, chaque fichier est aussi SIGNÉ (HMAC-SHA256, clé tirée par PBKDF2) : un fichier
// non signé ou mal signé, déposé par quiconque peut écrire dans le dossier partagé, est refusé
// (sauf celui d'un site écrit par la 0.28 ou avant, qui ne signe pas).
//
// Fusion : élément par élément, par date de modification. Un élément changé d'un seul côté depuis
// la dernière synchronisation prend la version changée ; changé des deux côtés : CONFLIT, la
// version la plus récente l'emporte et l'autre est gardée (`ConfigSyncConflict`) pour être
// rétablie : rien n'est jamais écrasé sans le dire. Un site est reconnu par son identifiant
// (dossier), jamais par ses plages : deux sites ne sont jamais fusionnés. Une suppression faite
// sur un autre Mac est publiée (pierre tombale `removed`) et SIGNALÉE ici
// (`ConfigSyncDeletion`), jamais appliquée sans confirmation.
//
// Versions : un Mac d'une version plus ancienne est reconnu (`schema`, `appVersion`) et signalé ;
// ce qu'il envoie est superposé aux données d'ici (`preserveUnknown`) : il ne retire jamais un
// champ qu'il ne connaît pas.
//
// Le moteur ne lit et n'écrit que la racine qu'on lui donne (dossier temporaire dans les tests) ;
// les changements reçus sont rendus sous forme de `ConfigApplyPlan`, appliqué par l'app.

/// Un élément synchronisé.
public struct ConfigSyncItem: Codable, Hashable, Sendable {
    /// « site », « fichier:sites/<id>/inventory.json », « fortigate:<id> », « element:… », « doc:… »,
    /// « preference:… ».
    public var key: String
    public var label: String
    public var modified: Date
    public var hash: String
    public var data: Data

    public init(key: String, label: String, modified: Date, hash: String, data: Data) {
        self.key = key
        self.label = label
        self.modified = modified
        self.hash = hash
        self.data = data
    }
}

/// Un secret synchronisé (seulement dans la partie chiffrée d'un `ConfigSyncBundle`).
public struct ConfigSyncSecretItem: Codable, Hashable, Sendable {
    public var service: String
    public var account: String
    public var usage: String
    public var value: Data
    public var modified: Date

    public var key: String { service + "|" + account }
    public var secret: BackupSecret { BackupSecret(service: service, account: account, value: value, usage: usage) }
}

/// Ce qu'un Mac publie pour un site (ou pour le global).
public struct ConfigSyncBundle: Codable, Sendable, Equatable {
    public static let formatName = "netscope-synchro"
    /// Format des fichiers : resté à 1 pour que les versions 0.18 à 0.28 lisent encore les sites.
    public static let currentVersion = 1
    /// Note 86 : schéma des données (2 : synchronisation complète). Absent : 0.18 à 0.28.
    public static let currentSchema = 2

    public var format = ConfigSyncBundle.formatName
    public var version = ConfigSyncBundle.currentVersion
    public var siteID: UUID
    public var siteName: String
    public var deviceID: String
    public var deviceName: String
    public var updated: Date
    public var items: [ConfigSyncItem]
    /// Secrets scellés (BackupCrypto) par le mot de passe de synchronisation ; nil : aucun.
    public var secrets: Data?
    public var secretCount: Int
    /// Site supprimé sur ce Mac (signalé aux autres, jamais appliqué d'office).
    public var deleted: Bool
    // Note 86 (facultatifs : ignorés par les versions précédentes).
    public var schema: Int?
    public var appVersion: String?
    public var deviceModel: String?
    /// Éléments retirés sur ce Mac depuis qu'ils étaient communs (clé → date), signalés aux autres.
    public var removed: [String: Date]?
    /// Signature HMAC-SHA256 du contenu (clé tirée du mot de passe de synchronisation par PBKDF2,
    /// sel tiré de l'identifiant du Mac) ; nil : pas de mot de passe sur ce Mac, ou 0.28 et avant.
    public var signature: String?
    /// Itérations PBKDF2 de la clé de signature.
    public var signatureIterations: Int?

    public init(siteID: UUID, siteName: String, deviceID: String, deviceName: String, updated: Date, items: [ConfigSyncItem],
                secrets: Data? = nil, secretCount: Int = 0, deleted: Bool = false, schema: Int? = ConfigSyncBundle.currentSchema,
                appVersion: String? = nil, deviceModel: String? = nil, removed: [String: Date]? = nil) {
        self.siteID = siteID
        self.siteName = siteName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.updated = updated
        self.items = items
        self.secrets = secrets
        self.secretCount = secretCount
        self.deleted = deleted
        self.schema = schema
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.removed = removed
    }
}

/// Fiche d'un Mac vu dans le dossier de synchronisation.
public struct ConfigSyncDevice: Codable, Identifiable, Hashable, Sendable {
    public static let formatName = "netscope-synchro-appareil"

    public var format = ConfigSyncDevice.formatName
    public var id: String
    public var name: String
    public var model: String
    /// Version de NetScope ; vide : 0.28 ou plus ancienne (pas de fiche de Mac).
    public var appVersion: String
    public var schema: Int?
    public var lastSync: Date
    /// Catégories décochées sur ce Mac.
    public var disabledCategories: [String]

    public init(id: String, name: String, model: String, appVersion: String, schema: Int? = ConfigSyncBundle.currentSchema,
                lastSync: Date, disabledCategories: [String] = []) {
        self.id = id
        self.name = name
        self.model = model
        self.appVersion = appVersion
        self.schema = schema
        self.lastSync = lastSync
        self.disabledCategories = disabledCategories
    }

    /// « 0.28 ou plus ancienne » quand la version n'est pas connue.
    public var versionLabel: String { appVersion.isEmpty ? "0.28 ou plus ancienne" : appVersion }
}

/// État local de la synchronisation (dossier caché de ce Mac, jamais synchronisé ni exporté).
public struct ConfigSyncState: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// Empreinte de la version de ce Mac à la dernière lecture.
        public var hash: String
        /// Date de la dernière modification connue de cette version.
        public var modified: Date
        /// Empreinte commune à la dernière synchronisation (la « base » de la fusion).
        public var synced: String?
    }

    public struct Site: Codable, Sendable, Equatable {
        public var items: [String: Item] = [:]
        public var secrets: [String: Item] = [:]
        public var lastSync: Date?
        /// Empreinte de ce que ce Mac a publié la dernière fois.
        public var published: String?
        /// Note 86 : éléments retirés ici (pierres tombales publiées).
        public var removed: [String: Date] = [:]

        public init() {}

        private enum CodingKeys: String, CodingKey { case items, secrets, lastSync, published, removed }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = try c.decodeIfPresent([String: Item].self, forKey: .items) ?? [:]
            secrets = try c.decodeIfPresent([String: Item].self, forKey: .secrets) ?? [:]
            lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
            published = try c.decodeIfPresent(String.self, forKey: .published)
            removed = try c.decodeIfPresent([String: Date].self, forKey: .removed) ?? [:]
        }
    }

    /// Clé : identifiant du site, ou « _global ».
    public var sites: [String: Site] = [:]
    public var conflicts: [ConfigSyncConflict] = []
    public var lastSync: Date?
    /// Note 86 : suppressions venues d'un autre Mac, à confirmer.
    public var pendingDeletions: [ConfigSyncDeletion] = []
    /// Suppressions refusées (« Garder sur ce Mac ») : identifiant → date de la suppression écartée.
    public var dismissed: [String: Date] = [:]
    /// Changements reçus récents (les plus récents d'abord).
    public var recent: [ConfigSyncChange] = []
    /// Mac vus à la dernière synchronisation.
    public var devices: [ConfigSyncDevice] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case sites, conflicts, lastSync, pendingDeletions, dismissed, recent, devices }

    /// L'état écrit par la 0.18 à la 0.28 se relit tel quel.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sites = try c.decodeIfPresent([String: Site].self, forKey: .sites) ?? [:]
        conflicts = try c.decodeIfPresent([ConfigSyncConflict].self, forKey: .conflicts) ?? []
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        pendingDeletions = try c.decodeIfPresent([ConfigSyncDeletion].self, forKey: .pendingDeletions) ?? []
        dismissed = try c.decodeIfPresent([String: Date].self, forKey: .dismissed) ?? [:]
        recent = try c.decodeIfPresent([ConfigSyncChange].self, forKey: .recent) ?? []
        devices = try c.decodeIfPresent([ConfigSyncDevice].self, forKey: .devices) ?? []
    }

    /// Changements reçus gardés (tableau « Changements reçus récents »).
    public static let recentLimit = 60
}

/// Un conflit : l'élément a changé sur deux Mac depuis la dernière synchronisation. La version
/// la plus récente a été gardée ; l'autre est ici, à rétablir au besoin.
public struct ConfigSyncConflict: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    /// Site ; `ConfigSyncPolicy.globalID` pour les données globales.
    public var siteID: UUID
    /// Nom du site, ou de la catégorie pour les données globales.
    public var siteName: String
    public var key: String
    public var label: String
    public var keptDevice: String
    public var keptModified: Date
    public var otherDevice: String
    public var otherModified: Date
    /// Version écartée (jamais pour un secret : sa valeur n'est pas gardée en clair).
    public var otherData: Data?
    /// Vrai si la version gardée est celle de l'autre Mac.
    public var keptRemote: Bool

    public init(id: UUID = UUID(), date: Date, siteID: UUID, siteName: String, key: String, label: String, keptDevice: String,
                keptModified: Date, otherDevice: String, otherModified: Date, otherData: Data?, keptRemote: Bool) {
        self.id = id
        self.date = date
        self.siteID = siteID
        self.siteName = siteName
        self.key = key
        self.label = label
        self.keptDevice = keptDevice
        self.keptModified = keptModified
        self.otherDevice = otherDevice
        self.otherModified = otherModified
        self.otherData = otherData
        self.keptRemote = keptRemote
    }

    public var isSecret: Bool { key.hasPrefix("secret:") }
    public var isGlobal: Bool { siteID == ConfigSyncPolicy.globalID }
}

/// Une suppression faite sur un autre Mac, à confirmer ici.
public struct ConfigSyncDeletion: Codable, Identifiable, Hashable, Sendable {
    /// « <dossier>|<clé> ».
    public var id: String
    /// Date de la suppression sur l'autre Mac.
    public var date: Date
    /// Identifiant du site, ou « _global ».
    public var scope: String
    public var scopeName: String
    public var key: String
    public var label: String
    public var category: String
    public var device: String

    public init(scope: String, scopeName: String, key: String, label: String, category: String, device: String, date: Date) {
        id = scope + "|" + key
        self.date = date
        self.scope = scope
        self.scopeName = scopeName
        self.key = key
        self.label = label
        self.category = category
        self.device = device
    }

    /// Site visé ; nil pour les données globales.
    public var siteID: UUID? { UUID(uuidString: scope) }
    /// La suppression vise le site entier.
    public var isWholeSite: Bool { key == "site" }
}

/// Un changement reçu d'un autre Mac (tableau des changements récents).
public struct ConfigSyncChange: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var scopeName: String
    public var label: String
    public var category: String
    public var device: String

    public init(id: UUID = UUID(), date: Date, scopeName: String, label: String, category: String, device: String) {
        self.id = id
        self.date = date
        self.scopeName = scopeName
        self.label = label
        self.category = category
        self.device = device
    }
}

/// Un événement de synchronisation (reçu, envoyé, suppression signalée).
public struct ConfigSyncEvent: Hashable, Sendable {
    public var siteID: UUID
    public var siteName: String
    public var label: String
    public var device: String
    /// Catégorie (`ConfigPart.id`) ; nil pour un site supprimé.
    public var category: String?

    public init(siteID: UUID, siteName: String, label: String, device: String, category: String? = nil) {
        self.siteID = siteID
        self.siteName = siteName
        self.label = label
        self.device = device
        self.category = category
    }
}

/// Un site présent dans le dossier de synchronisation mais pas sur ce Mac.
public struct ConfigSyncRemoteSite: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var devices: [String]
    public var updated: Date

    public init(id: UUID, name: String, devices: [String], updated: Date) {
        self.id = id
        self.name = name
        self.devices = devices
        self.updated = updated
    }
}

/// Bilan d'une synchronisation.
public struct ConfigSyncReport: Sendable {
    /// Changements reçus, à appliquer sur ce Mac.
    public var plan: ConfigApplyPlan
    public var received: [ConfigSyncEvent] = []
    public var sent: [ConfigSyncEvent] = []
    public var conflicts: [ConfigSyncConflict] = []
    /// Sites supprimés sur un autre Mac (aussi dans `pendingDeletions`).
    public var deletions: [ConfigSyncEvent] = []
    /// Note 86 : suppressions venues d'un autre Mac, nouvelles à ce passage, à confirmer.
    public var pendingDeletions: [ConfigSyncDeletion] = []
    /// Note 86 : Mac d'une version plus ancienne lus à ce passage.
    public var olderDevices: [ConfigSyncDevice] = []
    public var errors: [String] = []
    /// Secrets non synchronisés (pas de mot de passe de synchronisation sur ce Mac).
    public var secretsSkipped = false

    public var isQuiet: Bool { received.isEmpty && sent.isEmpty && conflicts.isEmpty && deletions.isEmpty && errors.isEmpty }
}

public enum ConfigSyncError: Error, LocalizedError, Equatable {
    case folderUnavailable(String)
    /// Dossier choisi absent (partage non monté, OneDrive déconnecté) : jamais recréé en local.
    case folderMissing(String)

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable(let path): return "Dossier de synchronisation inaccessible\u{00A0}: \(path)."
        case .folderMissing(let path): return "Dossier de synchronisation introuvable\u{00A0}: montez le partage (\(path))."
        }
    }
}

// MARK: - Éléments locaux

/// Ce que ce Mac a pour un site, ou pour le global (pur : tiré d'un `ConfigSnapshot`).
public struct ConfigSyncLocalSite: Sendable {
    public struct Item: Sendable {
        public var label: String
        public var data: Data
        public var hash: String
        /// Date connue de la modification (fichier) ; nil : déduite par l'état.
        public var modifiedHint: Date?

        public init(label: String, data: Data, hash: String, modifiedHint: Date?) {
            self.label = label
            self.data = data
            self.hash = hash
            self.modifiedHint = modifiedHint
        }
    }

    public var siteID: UUID
    public var name: String
    public var exists: Bool
    public var items: [String: Item]
    public var secrets: [BackupSecret]

    /// Fichiers du dossier du site synchronisés (note 86 : derniers résultats, relevé Wi-Fi par
    /// pièce et carte placée à la main compris ; le signal seconde par seconde ne l'est pas).
    public static var siteFiles: [String] { ConfigSyncPolicy.siteFiles }

    public static func make(siteID: UUID, snapshot: ConfigSnapshot) -> ConfigSyncLocalSite {
        let sites = snapshot.collectionData(.sites).flatMap(ConfigCollection.sites.elements) ?? []
        let id = siteID.uuidString
        guard let site = sites.first(where: { $0.id == id }) else {
            return ConfigSyncLocalSite(siteID: siteID, name: "", exists: false, items: [:], secrets: [])
        }
        var items: [String: Item] = [:]
        items["site"] = Item(label: "Fiche du site", data: site.canonical, hash: site.hash, modifiedHint: snapshot.collectionModified(.sites))
        for name in siteFiles {
            let path = SiteFiles.folderName + "/" + id + "/" + name
            if let file = snapshot.file(path) {
                items["fichier:" + path] = Item(label: siteFileLabel(name), data: file.data, hash: ConfigHash.sha256(file.data),
                                                modifiedHint: file.modified)
            }
        }
        // Note 95 : images des plans du relevé Wi-Fi, une par étage (une mesure ne les renvoie pas).
        let imagePrefix = SiteFiles.folderName + "/" + id + "/" + WifiFloorPlans.imageFolder + "/"
        for file in snapshot.files where file.path.hasPrefix(imagePrefix) && WifiFloorPlans.isImagePath(file.path) {
            items["fichier:" + file.path] = Item(label: "Plan du relevé Wi-Fi", data: file.data, hash: ConfigHash.sha256(file.data),
                                                 modifiedHint: file.modified)
        }
        let fortiIDs = Set(((try? JSONSerialization.jsonObject(with: site.json)) as? [String: Any])?["fortiGateIDs"] as? [String] ?? [])
        let controllers = snapshot.collectionData(.fortiGates).flatMap(ConfigCollection.fortiGates.elements) ?? []
        for controller in controllers where fortiIDs.contains(controller.id) {
            items["fortigate:" + controller.id] = Item(label: "FortiGate «\u{00A0}\(controller.name)\u{00A0}»", data: controller.canonical,
                                                       hash: controller.hash, modifiedHint: nil)
        }
        let fortiService = BackupKeychainScan.servicePrefix + ".fortigate"
        let secrets = snapshot.secrets.filter { $0.service == fortiService && fortiIDs.contains($0.account) }
        return ConfigSyncLocalSite(siteID: siteID, name: site.name, exists: true, items: items, secrets: secrets)
    }

    static func siteFileLabel(_ name: String) -> String {
        switch name {
        case SiteFiles.inventoryName: return "Inventaire"
        case SiteFiles.notesName: return "Notes des appareils"
        case SiteFiles.resultsName: return "Derniers résultats du scan"
        case WifiRoomSurvey.fileName: return "Relevé Wi-Fi par pièce"
        case WifiFloorPlans.fileName: return "Relevé Wi-Fi sur plan"
        case TopoManualLayout.fileName: return "Carte placée à la main"
        default: return name
        }
    }

    /// Catégorie d'un élément d'un site.
    public static func category(forSiteKey key: String) -> String {
        if key == "site" || key.hasSuffix("/" + TopoManualLayout.fileName) { return "sites" }
        if key.hasPrefix("fortigate:") || key.hasPrefix("secret:") { return "fortigate" }
        return "inventaires"
    }
}

// MARK: - Moteur

public struct ConfigSyncEngine: Sendable {
    /// Dossier de synchronisation (iCloud Drive › NetScope › Sync, ou un autre), ou un dossier
    /// temporaire dans les tests.
    public var root: URL
    public var deviceID: String
    public var deviceName: String
    /// Mot de passe de synchronisation (Trousseau de ce Mac) ; nil : secrets non synchronisés.
    public var password: String?
    public var iterations: Int
    /// Note 86 : modèle du Mac (« Mac Studio ») et version de NetScope, publiés pour les autres Mac.
    public var deviceModel = ""
    public var appVersion = ""
    public var registry = ConfigPartRegistry.standard
    /// Catégories décochées sur ce Mac (`ConfigPart.id`) : ni envoyées, ni reçues.
    public var disabledCategories: Set<String> = []
    /// Fichiers dont des changements reçus attendent le redémarrage : laissés de côté à ce
    /// passage (ni envoyés, ni reçus), pour que la version d'ici, pas encore remplacée, ne reparte pas.
    public var heldPaths: Set<String> = []
    /// Dossier partagé autre qu'iCloud Drive (OneDrive, NAS, partage) : sans mot de passe de
    /// synchronisation, rien n'y authentifie les fichiers des autres Mac ; les catégories
    /// sensibles (`ConfigSyncPolicy.sensitiveCategories`) n'en sont alors jamais reçues.
    public var untrustedFolder = false
    /// Crée la racine si elle manque (iCloud Drive, tests) ; faux pour un dossier choisi : un
    /// partage non monté ne doit jamais devenir un dossier local du même chemin.
    public var createsRoot = true

    public init(root: URL, deviceID: String, deviceName: String, password: String?, iterations: Int = BackupCrypto.defaultIterations) {
        self.root = root
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.password = password.flatMap { $0.isEmpty ? nil : $0 }
        self.iterations = iterations
    }

    public func folder(for site: UUID) -> URL { root.appendingPathComponent(site.uuidString, isDirectory: true) }
    public var globalFolder: URL { root.appendingPathComponent(ConfigSyncPolicy.globalFolder, isDirectory: true) }

    public func bundleURL(site: UUID, device: String) -> URL {
        folder(for: site).appendingPathComponent(Self.safeName(device) + ".json")
    }

    public func globalBundleURL(device: String) -> URL {
        globalFolder.appendingPathComponent(Self.safeName(device) + ".json")
    }

    /// Nom de fichier d'un Mac dans le dossier de synchronisation (sans extension).
    public static func safeFileName(_ text: String) -> String { safeName(text) }

    static func safeName(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    // MARK: Lecture

    /// Fichiers des AUTRES Mac pour un site (le plus récent par Mac ; copies de conflit d'iCloud
    /// comprises, illisibles ignorés, jamais un fichier d'un autre site).
    public func remoteBundles(for site: UUID) -> [ConfigSyncBundle] {
        remoteBundles(in: folder(for: site), id: site)
    }

    public func remoteGlobalBundles() -> [ConfigSyncBundle] {
        remoteBundles(in: globalFolder, id: ConfigSyncPolicy.globalID)
    }

    func remoteBundles(in folder: URL, id: UUID) -> [ConfigSyncBundle] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        Self.requestDownloads(names, in: folder)
        var byDevice: [String: ConfigSyncBundle] = [:]
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let bundle = try? BackupEngine.decoder().decode(ConfigSyncBundle.self, from: data),
                  bundle.format == ConfigSyncBundle.formatName, bundle.version <= ConfigSyncBundle.currentVersion,
                  bundle.siteID == id, bundle.deviceID != deviceID else { continue }
            if let current = byDevice[bundle.deviceID], current.updated >= bundle.updated { continue }
            byDevice[bundle.deviceID] = bundle
        }
        return byDevice.values.sorted { $0.deviceID < $1.deviceID }
    }

    /// iCloud Drive remplace un fichier pas encore téléchargé par « .nom.json.icloud » : on en
    /// demande le téléchargement (lu au passage suivant).
    static func requestDownloads(_ names: [String], in folder: URL) {
        for name in names where name.hasPrefix(".") && name.hasSuffix(".json.icloud") {
            let real = String(name.dropFirst().dropLast(".icloud".count))
            try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
        }
    }

    /// Sites publiés par d'autres Mac et absents de `local`.
    public func availableSites(excluding local: Set<UUID>) -> [ConfigSyncRemoteSite] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var result: [ConfigSyncRemoteSite] = []
        for name in names.sorted() {
            guard let id = UUID(uuidString: name), !local.contains(id) else { continue }
            let bundles = remoteBundles(for: id).filter { !$0.deleted }
            guard let newest = bundles.max(by: { $0.updated < $1.updated }) else { continue }
            result.append(ConfigSyncRemoteSite(id: id, name: newest.siteName, devices: bundles.map(\.deviceName).sorted(), updated: newest.updated))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Mac

    public var deviceURL: URL {
        root.appendingPathComponent(ConfigSyncPolicy.devicesFolder, isDirectory: true).appendingPathComponent(Self.safeName(deviceID) + ".json")
    }

    /// Fiche de ce Mac (écrite à chaque synchronisation qui change quelque chose, et au plus
    /// toutes les dix minutes sinon).
    func publishPresence(now: Date) {
        let device = ConfigSyncDevice(id: deviceID, name: deviceName, model: deviceModel, appVersion: appVersion, lastSync: now,
                                      disabledCategories: disabledCategories.sorted())
        if let data = try? Data(contentsOf: deviceURL), let current = try? BackupEngine.decoder().decode(ConfigSyncDevice.self, from: data),
           current.name == device.name, current.model == device.model, current.appVersion == device.appVersion,
           current.disabledCategories == device.disabledCategories, now.timeIntervalSince(current.lastSync) < 600 {
            return
        }
        try? FileManager.default.createDirectory(at: deviceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? BackupEngine.encoder().encode(device).write(to: deviceURL, options: .atomic)
    }

    /// Tous les Mac vus : fiches des Mac, complétées par les auteurs des fichiers des sites (un
    /// Mac en 0.28 ou plus ancienne n'a pas de fiche). Ce Mac en premier.
    public func devices(now: Date = Date()) -> [ConfigSyncDevice] {
        let manager = FileManager.default
        var byID: [String: ConfigSyncDevice] = [:]
        let deviceFolder = root.appendingPathComponent(ConfigSyncPolicy.devicesFolder, isDirectory: true)
        let names = (try? manager.contentsOfDirectory(atPath: deviceFolder.path)) ?? []
        Self.requestDownloads(names, in: deviceFolder)
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let data = try? Data(contentsOf: deviceFolder.appendingPathComponent(name)),
                  let device = try? BackupEngine.decoder().decode(ConfigSyncDevice.self, from: data),
                  device.format == ConfigSyncDevice.formatName else { continue }
            byID[device.id] = device
        }
        let folders = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? []).filter { UUID(uuidString: $0) != nil }
        var bundles = remoteGlobalBundles()
        for name in folders { bundles += remoteBundles(for: UUID(uuidString: name)!) }
        for bundle in bundles {
            if var known = byID[bundle.deviceID] {
                if bundle.updated > known.lastSync { known.lastSync = bundle.updated; byID[bundle.deviceID] = known }
            } else {
                byID[bundle.deviceID] = ConfigSyncDevice(id: bundle.deviceID, name: bundle.deviceName, model: bundle.deviceModel ?? "",
                                                         appVersion: bundle.appVersion ?? "", schema: bundle.schema, lastSync: bundle.updated)
            }
        }
        byID[deviceID] = ConfigSyncDevice(id: deviceID, name: deviceName, model: deviceModel, appVersion: appVersion, lastSync: now,
                                          disabledCategories: disabledCategories.sorted())
        return byID.values.sorted { a, b in
            if a.id == deviceID { return true }
            if b.id == deviceID { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Vrai si ce Mac publie avec une version plus ancienne que celle-ci.
    public func isOlder(schema: Int?, appVersion version: String?) -> Bool {
        if (schema ?? 0) < ConfigSyncBundle.currentSchema { return true }
        guard let mine = UpdVersion(appVersion), let theirs = version.flatMap(UpdVersion.init) else { return false }
        return theirs < mine
    }

    public func isOlder(_ device: ConfigSyncDevice) -> Bool {
        device.id != deviceID && isOlder(schema: device.schema, appVersion: device.appVersion.isEmpty ? nil : device.appVersion)
    }

    // MARK: Secrets

    /// Empreinte d'un secret, liée au mot de passe de synchronisation (jamais un simple SHA-256
    /// d'une communauté devinable).
    func secretHash(_ secret: BackupSecret) -> String {
        let key = SymmetricKey(data: SHA256.hash(data: Data((password ?? "").utf8)))
        var message = Data((secret.service + "|" + secret.account + "|").utf8)
        message.append(secret.value)
        return HMAC<SHA256>.authenticationCode(for: message, using: key).map { String(format: "%02x", $0) }.joined()
    }

    func sealSecrets(_ items: [ConfigSyncSecretItem], now: Date) throws -> Data? {
        guard let password, !items.isEmpty else { return nil }
        let plaintext = try BackupEngine.encoder().encode(items)
        return try BackupCrypto.seal(plaintext, password: password, iterations: iterations, createdAt: now, kind: .automatique,
                                     appVersion: "", appBuild: "", fileCount: 0, preferenceCount: 0, secretCount: items.count)
    }

    func openSecrets(_ bundle: ConfigSyncBundle, allowed: (String, String) -> Bool) throws -> [ConfigSyncSecretItem] {
        guard let sealed = bundle.secrets else { return [] }
        guard let password else { throw BackupCryptoError.passwordRequired }
        let opened = try BackupCrypto.open(sealed, password: password)
        guard let items = try? BackupEngine.decoder().decode([ConfigSyncSecretItem].self, from: opened.plaintext),
              items.count == opened.header.secretCount else { throw BackupCryptoError.tampered }
        // Jamais un secret hors de ce que le dossier peut porter (un jeton FortiGate pour un site).
        guard items.allSatisfy({ allowed($0.service, $0.account) }) else { throw BackupCryptoError.tampered }
        return items
    }

    // MARK: Signature des fichiers

    /// Message de « ce Mac n'a pas de mot de passe ici » (dossier partagé non authentifié).
    static let untrustedMessage = "Dossier partagé sans mot de passe de synchronisation\u{00A0}: Accès distant, alertes, identifiants, Surveillance et FortiGate venus d’un autre Mac sont ignorés. Définissez le même mot de passe de synchronisation sur chaque Mac."

    /// Clés de signature tirées pendant un passage (une dérivation PBKDF2 par Mac et par nombre
    /// d'itérations, jamais une par fichier).
    final class SignatureKeys {
        var keys: [String: SymmetricKey] = [:]
    }

    /// Bornes des itérations acceptées d'un autre Mac (jamais un calcul démesuré imposé).
    static let signatureIterationRange = 1...5_000_000

    func signatureKey(device: String, iterations: Int, keys: SignatureKeys) -> SymmetricKey? {
        guard let password, Self.signatureIterationRange.contains(iterations) else { return nil }
        let id = device + "|" + String(iterations)
        if let key = keys.keys[id] { return key }
        let salt = Data(SHA256.hash(data: Data(("netscope-synchro-signature|" + device).utf8)).prefix(16))
        guard let material = try? BackupCrypto.pbkdf2(password: password, salt: salt, iterations: iterations) else { return nil }
        let key = SymmetricKey(data: material)
        keys.keys[id] = key
        return key
    }

    /// Contenu signé d'un fichier, tel que relu (dates comprises) : tout sauf la signature.
    static func signedMessage(_ bundle: ConfigSyncBundle) -> Data {
        func time(_ date: Date) -> String { String(date.timeIntervalSince1970) }
        var lines = [bundle.format, String(bundle.version), bundle.siteID.uuidString, bundle.siteName, bundle.deviceID, bundle.deviceName,
                     time(bundle.updated), bundle.deleted ? "1" : "0", String(bundle.schema ?? 0), bundle.appVersion ?? "",
                     bundle.deviceModel ?? "", String(bundle.secretCount), bundle.secrets.map(ConfigHash.sha256) ?? "-",
                     String(bundle.signatureIterations ?? 0)]
        for item in bundle.items {
            lines.append([item.key, item.label, time(item.modified), item.hash, ConfigHash.sha256(item.data)].joined(separator: "\u{1F}"))
        }
        for (key, date) in (bundle.removed ?? [:]).sorted(by: { $0.key < $1.key }) {
            lines.append("-" + key + "\u{1F}" + time(date))
        }
        return Data(lines.joined(separator: "\u{1E}").utf8)
    }

    static func hex(_ code: HashedAuthenticationCode<SHA256>) -> String { code.map { String(format: "%02x", $0) }.joined() }

    /// Fichier signé avec la clé de ce Mac (inchangé sans mot de passe de synchronisation).
    func signed(_ bundle: ConfigSyncBundle, keys: SignatureKeys) throws -> ConfigSyncBundle {
        guard password != nil, let key = signatureKey(device: deviceID, iterations: iterations, keys: keys) else { return bundle }
        var copy = bundle
        copy.signature = nil
        copy.signatureIterations = iterations
        // Signé tel que les autres Mac le reliront (dates arrondies par l'encodage).
        let reread = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: BackupEngine.encoder().encode(copy))
        copy.signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Self.signedMessage(reread), using: key))
        return copy
    }

    func hasValidSignature(_ bundle: ConfigSyncBundle, keys: SignatureKeys) -> Bool {
        guard let signature = bundle.signature, let iterations = bundle.signatureIterations,
              let key = signatureKey(device: bundle.deviceID, iterations: iterations, keys: keys) else { return false }
        return Self.hex(HMAC<SHA256>.authenticationCode(for: Self.signedMessage(bundle), using: key)) == signature
    }

    /// Avec un mot de passe de synchronisation, seuls les fichiers signés par le même mot de passe
    /// sont lus ; exception : le fichier d'un site écrit par la 0.28 ou une version plus ancienne
    /// (sans schéma ni signature), toujours accepté pour garder ces Mac dans la boucle.
    func authenticated(_ bundles: [ConfigSyncBundle], isSite: Bool, keys: SignatureKeys, report: inout ConfigSyncReport) -> [ConfigSyncBundle] {
        guard password != nil else { return bundles }
        return bundles.filter { bundle in
            if bundle.signature == nil, isSite, bundle.schema == nil { return true }
            if hasValidSignature(bundle, keys: keys) { return true }
            let text = "Fichiers de «\u{00A0}\(bundle.deviceName)\u{00A0}» refusés\u{00A0}: signature absente ou invalide (pas de mot de passe de synchronisation sur ce Mac-là, ou un mot de passe différent)."
            if !report.errors.contains(text) { report.errors.append(text) }
            return false
        }
    }

    // MARK: Portées

    /// Un site ou le global, prêt à fusionner.
    struct Scope {
        var folder: String
        var id: UUID
        var name: String
        var exists: Bool
        var isSite: Bool
        var local: ConfigSyncLocalSite
        /// Catégorie d'une clé (locale ou reçue) ; nil : refusée dans ce dossier.
        var category: (String) -> String?
        /// Secret admis (service, compte), d'ici (fichier nil) ou d'un fichier reçu.
        var secretAllowed: (String, String, ConfigSyncBundle?) -> Bool
    }

    func siteScope(_ id: UUID, snapshot: ConfigSnapshot) -> Scope {
        let local = ConfigSyncLocalSite.make(siteID: id, snapshot: snapshot)
        let fortiService = BackupKeychainScan.servicePrefix + ".fortigate"
        // Seulement les jetons des FortiGate de CE site : d'ici, ou publiées dans le même fichier.
        let localIDs = Set(local.items.keys.filter { $0.hasPrefix("fortigate:") }.map { String($0.dropFirst("fortigate:".count)) })
        return Scope(folder: id.uuidString, id: id, name: local.name, exists: local.exists, isSite: true, local: local,
                     category: { ConfigSyncLocalSite.category(forSiteKey: $0) },
                     secretAllowed: { service, account, bundle in
                         guard service == fortiService else { return false }
                         return localIDs.contains(account) || (bundle?.items.contains { $0.key == "fortigate:" + account } ?? false)
                     })
    }

    func globalScope(snapshot: ConfigSnapshot) -> Scope {
        let local = ConfigSyncGlobal.make(snapshot: snapshot, registry: registry)
        let registry = self.registry
        return Scope(folder: ConfigSyncPolicy.globalFolder, id: ConfigSyncPolicy.globalID, name: "Données globales", exists: true,
                     isSite: false, local: local, category: { ConfigSyncGlobal.category(forKey: $0, registry: registry) },
                     secretAllowed: { service, _, _ in ConfigSyncPolicy.isGlobalSecret(service) })
    }

    // MARK: Synchronisation

    /// Synchronise les sites choisis (comme la 0.18).
    public func sync(sites ids: [UUID], snapshot: ConfigSnapshot, state: inout ConfigSyncState, now: Date = Date()) throws -> ConfigSyncReport {
        try sync(sites: ids, global: false, snapshot: snapshot, state: &state, now: now)
    }

    /// Synchronise les sites choisis et, avec `global`, les données globales (note 86) : publie la
    /// version de ce Mac, lit celles des autres, fusionne par date de modification et rend les
    /// changements reçus (`report.plan`) à appliquer ici.
    public func sync(sites ids: [UUID], global: Bool, snapshot: ConfigSnapshot, state: inout ConfigSyncState,
                     now: Date = Date()) throws -> ConfigSyncReport {
        let manager = FileManager.default
        if createsRoot {
            do {
                try manager.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw ConfigSyncError.folderUnavailable(root.path)
            }
        } else {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConfigSyncError.folderMissing(root.path)
            }
        }
        var report = ConfigSyncReport(plan: ConfigApplyPlan(origin: "synchro", createdAt: now))
        let keys = SignatureKeys()
        // Les dossiers des sites portent aussi les inventaires et les FortiGate : parcourus dès
        // qu'une de leurs catégories est cochée (la fiche du site suit la case « Sites »).
        let sitesOn = !ConfigSyncPolicy.siteCategories.isSubset(of: disabledCategories)
        if sitesOn {
            for id in ids {
                try sync(siteScope(id, snapshot: snapshot), snapshot: snapshot, state: &state, report: &report, signing: keys, now: now)
            }
        }
        if global {
            try sync(globalScope(snapshot: snapshot), snapshot: snapshot, state: &state, report: &report, signing: keys, now: now)
        }
        state.conflicts = Array((report.conflicts + state.conflicts).prefix(50))
        // Suppressions signalées : les nouvelles en tête, une seule fois par élément.
        for deletion in report.pendingDeletions {
            state.pendingDeletions.removeAll { $0.id == deletion.id }
            state.pendingDeletions.insert(deletion, at: 0)
        }
        let changes = report.received.map { event in
            ConfigSyncChange(date: now, scopeName: event.siteName, label: event.label, category: event.category ?? "sites", device: event.device)
        }
        state.recent = Array((changes + state.recent).prefix(ConfigSyncState.recentLimit))
        state.lastSync = now
        publishPresence(now: now)
        state.devices = devices(now: now)
        return report
    }

    private func sync(_ scope: Scope, snapshot: ConfigSnapshot, state: inout ConfigSyncState, report: inout ConfigSyncReport,
                      signing: SignatureKeys, now: Date) throws {
        let id = scope.id
        let local = scope.local
        var siteState = state.sites[scope.folder] ?? ConfigSyncState.Site()
        let folderURL = scope.isSite ? folder(for: id) : globalFolder
        let all = authenticated(remoteBundles(in: folderURL, id: id), isSite: scope.isSite, keys: signing, report: &report)
        let remotes = all.filter { !$0.deleted }
        let siteName = scope.exists && !scope.name.isEmpty ? scope.name : (remotes.max(by: { $0.updated < $1.updated })?.siteName ?? id.uuidString)
        let older = Set(remotes.filter { isOlder(schema: $0.schema, appVersion: $0.appVersion) }.map(\.deviceID))
        for bundle in remotes where older.contains(bundle.deviceID) && !report.olderDevices.contains(where: { $0.id == bundle.deviceID }) {
            report.olderDevices.append(ConfigSyncDevice(id: bundle.deviceID, name: bundle.deviceName, model: bundle.deviceModel ?? "",
                                                        appVersion: bundle.appVersion ?? "", schema: bundle.schema, lastSync: bundle.updated))
        }
        /// Clés retenues : catégorie connue et cochée.
        func included(_ key: String) -> Bool {
            guard let category = scope.category(key) else { return false }
            if !heldPaths.isEmpty {
                switch ConfigSyncKey.parse(key) {
                case .file(let path), .document(let path), .element(let path, _, _):
                    if heldPaths.contains(path) { return false }
                default:
                    break
                }
            }
            return !disabledCategories.contains(category)
        }
        func scopeLabel(_ key: String) -> String {
            guard !scope.isSite else { return siteName }
            return scope.category(key).flatMap { registry.part($0)?.title } ?? "Réglages"
        }

        // Site supprimé ici après avoir été synchronisé : on le dit aux autres, sans rien recevoir.
        if scope.isSite, !scope.exists, siteState.lastSync != nil {
            if siteState.published != "supprime" || !FileManager.default.fileExists(atPath: bundleURL(site: id, device: deviceID).path) {
                let bundle = ConfigSyncBundle(siteID: id, siteName: siteName, deviceID: deviceID, deviceName: deviceName, updated: now,
                                              items: [], deleted: true, appVersion: appVersion, deviceModel: deviceModel)
                try write(signed(bundle, keys: signing), to: bundleURL(site: id, device: deviceID))
            }
            siteState.published = "supprime"
            state.sites[scope.folder] = siteState
            // Plus rien de ce site ici : ses suppressions en attente sont caduques.
            state.pendingDeletions.removeAll { $0.scope == scope.folder }
            return
        }
        // Site d'un autre Mac jamais reçu ici, « Sites » décochée : ni ses fichiers ni ses FortiGate.
        if scope.isSite, !scope.exists, !included("site") { return }
        // Site supprimé sur un autre Mac : signalé, jamais appliqué.
        if scope.isSite {
            for bundle in all where bundle.deleted && scope.exists {
                report.deletions.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: "Site supprimé", device: bundle.deviceName))
                let deletion = ConfigSyncDeletion(scope: scope.folder, scopeName: siteName, key: "site", label: "Site «\u{00A0}\(siteName)\u{00A0}»",
                                                  category: "sites", device: bundle.deviceName, date: bundle.updated)
                if let dismissed = state.dismissed[deletion.id], dismissed >= bundle.updated { continue }
                if !state.pendingDeletions.contains(where: { $0.id == deletion.id }),
                   !report.pendingDeletions.contains(where: { $0.id == deletion.id }) {
                    report.pendingDeletions.append(deletion)
                }
            }
        }

        // 1. Dates locales : une empreinte nouvelle date la modification.
        var localItems: [String: (item: ConfigSyncLocalSite.Item, modified: Date)] = [:]
        for (key, item) in local.items where included(key) {
            var known = siteState.items[key]
            if known?.hash != item.hash {
                let modified = known == nil ? (item.modifiedHint ?? .distantPast) : (item.modifiedHint.map { max($0, known!.modified) } ?? now)
                known = ConfigSyncState.Item(hash: item.hash, modified: modified, synced: known?.synced)
                siteState.items[key] = known
            }
            localItems[key] = (item, known!.modified)
        }
        // Un élément revenu ici n'est plus une suppression.
        for key in localItems.keys { siteState.removed.removeValue(forKey: key) }
        let firstJoin = siteState.lastSync == nil

        // 2. Fusion élément par élément.
        var final: [String: ConfigSyncItem] = [:]
        let keys = Set(localItems.keys).union(remotes.flatMap { $0.items.map(\.key) }.filter(included))
        func mineItem(_ key: String, _ mine: (item: ConfigSyncLocalSite.Item, modified: Date)) -> ConfigSyncItem {
            ConfigSyncItem(key: key, label: mine.item.label, modified: mine.modified, hash: mine.item.hash, data: mine.item.data)
        }
        func take(_ remote: ConfigSyncItem, from bundle: ConfigSyncBundle) -> Bool {
            let category = scope.category(remote.key) ?? "reglages"
            if password == nil, untrustedFolder, ConfigSyncPolicy.sensitiveCategories.contains(category) {
                if !report.errors.contains(Self.untrustedMessage) { report.errors.append(Self.untrustedMessage) }
                return false
            }
            return accept(remote, from: bundle, scope: scope, siteName: siteName, category: category,
                          fromOlder: older.contains(bundle.deviceID), snapshot: snapshot, into: &report)
        }
        for key in keys.sorted() {
            let mine = localItems[key]
            let candidates = remotes.compactMap { bundle in bundle.items.first { $0.key == key }.map { (bundle, $0) } }
            let newest = candidates.max { a, b in a.1.modified == b.1.modified ? a.0.deviceID < b.0.deviceID : a.1.modified < b.1.modified }
            let base = siteState.items[key]?.synced
            let category = scope.category(key) ?? "reglages"
            guard let (remoteBundle, remote) = newest else {
                guard let mine else { continue }
                final[key] = mineItem(key, mine)
                // Retiré sur un autre Mac (pierre tombale) et inchangé ici depuis : à confirmer.
                if base != nil, mine.item.hash == base {
                    signalRemoval(key: key, label: mine.item.label, scope: scope, scopeName: scopeLabel(key), category: category,
                                  bundles: all, state: state, report: &report)
                }
                if mine.item.hash != base {
                    report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: mine.item.label, device: deviceName, category: category))
                }
                continue
            }
            guard let mine else {
                // Absent ici : reçu, sauf s'il a été retiré ici depuis (base inchangée ailleurs).
                if base != nil, remote.hash == base, scope.exists {
                    if siteState.removed[key] == nil, ConfigSyncPolicy.signalsRemoval(ofKey: key) { siteState.removed[key] = now }
                    continue
                }
                if take(remote, from: remoteBundle) { final[key] = remote }
                continue
            }
            // Trois Mac ou plus : retiré sur l'un, inchangé ici et chez tous ceux qui le publient
            // encore. La pierre tombale, plus récente que la dernière version connue, est signalée.
            if base != nil, mine.item.hash == base, candidates.allSatisfy({ $0.1.hash == base }) {
                signalRemoval(key: key, label: mine.item.label, scope: scope, scopeName: scopeLabel(key), category: category,
                              bundles: all, state: state, after: siteState.items[key]?.modified, report: &report)
            }
            if mine.item.hash == remote.hash {
                final[key] = ConfigSyncItem(key: key, label: mine.item.label, modified: max(mine.modified, remote.modified),
                                            hash: mine.item.hash, data: mine.item.data)
                continue
            }
            let localChanged = mine.item.hash != base
            let remoteChanged = remote.hash != base
            // Première synchronisation de ce Mac, rien de daté de part et d'autre : il adopte la
            // version des autres (la sienne reste rétablissable, sauf pour une simple préférence).
            if base == nil, firstJoin, mine.modified == .distantPast, remote.modified == .distantPast {
                guard take(remote, from: remoteBundle) else { final[key] = mineItem(key, mine); continue }
                final[key] = remote
                if !key.hasPrefix("preference:") {
                    report.conflicts.append(ConfigSyncConflict(date: now, siteID: id, siteName: scopeLabel(key), key: key, label: remote.label,
                                                               keptDevice: remoteBundle.deviceName, keptModified: remote.modified,
                                                               otherDevice: deviceName, otherModified: mine.modified,
                                                               otherData: mine.item.data, keptRemote: true))
                }
                continue
            }
            if !localChanged {
                final[key] = take(remote, from: remoteBundle) ? remote : mineItem(key, mine)
            } else if !remoteChanged {
                final[key] = mineItem(key, mine)
                report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: mine.item.label, device: deviceName, category: category))
            } else if remote.modified > mine.modified {
                guard take(remote, from: remoteBundle) else {
                    final[key] = mineItem(key, mine)
                    continue
                }
                final[key] = remote
                report.conflicts.append(ConfigSyncConflict(date: now, siteID: id, siteName: scopeLabel(key), key: key, label: remote.label,
                                                           keptDevice: remoteBundle.deviceName, keptModified: remote.modified,
                                                           otherDevice: deviceName, otherModified: mine.modified,
                                                           otherData: mine.item.data, keptRemote: true))
            } else {
                final[key] = mineItem(key, mine)
                report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: mine.item.label, device: deviceName, category: category))
                report.conflicts.append(ConfigSyncConflict(date: now, siteID: id, siteName: scopeLabel(key), key: key, label: mine.item.label,
                                                           keptDevice: deviceName, keptModified: mine.modified,
                                                           otherDevice: remoteBundle.deviceName, otherModified: remote.modified,
                                                           otherData: remote.data, keptRemote: false))
            }
        }

        // Pierres tombales : éléments communs retirés ici (catégories cochées seulement).
        for (key, item) in siteState.items where item.synced != nil && localItems[key] == nil && final[key] == nil && included(key) && scope.exists {
            if siteState.removed[key] == nil, ConfigSyncPolicy.signalsRemoval(ofKey: key) { siteState.removed[key] = now }
        }
        // Pierres tombales éteintes après 180 jours : l'élément est aussi oublié de l'état, sinon
        // il recréerait une pierre tombale neuve (et la suppression serait redemandée partout).
        let horizon = now.addingTimeInterval(-180 * 86_400)
        for (key, date) in siteState.removed where date <= horizon && final[key] == nil {
            siteState.items.removeValue(forKey: key)
        }
        siteState.removed = siteState.removed.filter { $0.value > horizon && final[$0.key] == nil }

        // 3. Secrets, seulement avec le mot de passe de synchronisation.
        let localSecrets = local.secrets.filter { scope.secretAllowed($0.service, $0.account, nil) && included("secret:" + $0.service + "|" + $0.account) }
        var finalSecrets: [ConfigSyncSecretItem] = []
        if password == nil {
            if !localSecrets.isEmpty || remotes.contains(where: { $0.secrets != nil }) { report.secretsSkipped = true }
        } else {
            var remoteSecrets: [(bundle: ConfigSyncBundle, item: ConfigSyncSecretItem)] = []
            let what = scope.isSite ? "jetons de «\u{00A0}\(siteName)\u{00A0}»" : "secrets des données globales"
            for bundle in remotes where bundle.secrets != nil {
                do {
                    remoteSecrets += try openSecrets(bundle, allowed: { scope.secretAllowed($0, $1, bundle) })
                        .filter { included("secret:" + $0.service + "|" + $0.account) }.map { (bundle, $0) }
                } catch BackupCryptoError.wrongPassword {
                    report.errors.append("Mot de passe de synchronisation différent sur «\u{00A0}\(bundle.deviceName)\u{00A0}»\u{00A0}: \(what) non reçus.")
                } catch {
                    report.errors.append("\(what.prefix(1).uppercased() + what.dropFirst()) illisibles sur «\u{00A0}\(bundle.deviceName)\u{00A0}»\u{00A0}: \(error.localizedDescription)")
                }
            }
            var mineByKey: [String: (secret: BackupSecret, hash: String, modified: Date)] = [:]
            for secret in localSecrets {
                let key = secret.service + "|" + secret.account
                let hash = secretHash(secret)
                var known = siteState.secrets[key]
                if known?.hash != hash {
                    known = ConfigSyncState.Item(hash: hash, modified: known == nil ? .distantPast : now, synced: known?.synced)
                    siteState.secrets[key] = known
                }
                mineByKey[key] = (secret, hash, known!.modified)
            }
            let secretKeys = Set(mineByKey.keys).union(remoteSecrets.map(\.item.key))
            for key in secretKeys.sorted() {
                let mine = mineByKey[key]
                let newest = remoteSecrets.filter { $0.item.key == key }
                    .max { a, b in a.item.modified == b.item.modified ? a.bundle.deviceID < b.bundle.deviceID : a.item.modified < b.item.modified }
                let base = siteState.secrets[key]?.synced
                let label = mine?.secret.usage ?? newest?.item.usage ?? "Jeton"
                let category = scope.category("secret:" + key) ?? "reglages"
                guard let newest else {
                    if let mine {
                        finalSecrets.append(ConfigSyncSecretItem(service: mine.secret.service, account: mine.secret.account, usage: mine.secret.usage,
                                                                 value: mine.secret.value, modified: mine.modified))
                        if mine.hash != base {
                            report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: label, device: deviceName, category: category))
                        }
                    }
                    continue
                }
                let remoteHash = secretHash(newest.item.secret)
                func takeRemote() {
                    finalSecrets.append(newest.item)
                    report.plan.secrets.append(newest.item.secret)
                    report.received.append(ConfigSyncEvent(siteID: id, siteName: scopeLabel("secret:" + key), label: label,
                                                           device: newest.bundle.deviceName, category: category))
                    siteState.secrets[key] = ConfigSyncState.Item(hash: remoteHash, modified: newest.item.modified, synced: remoteHash)
                }
                guard let mine else {
                    if base != nil, remoteHash == base, scope.exists { continue }
                    takeRemote()
                    continue
                }
                if mine.hash == remoteHash {
                    finalSecrets.append(ConfigSyncSecretItem(service: mine.secret.service, account: mine.secret.account, usage: mine.secret.usage,
                                                             value: mine.secret.value, modified: max(mine.modified, newest.item.modified)))
                    siteState.secrets[key]?.synced = mine.hash
                    continue
                }
                let localChanged = mine.hash != base, remoteChanged = remoteHash != base
                if !localChanged || (remoteChanged && newest.item.modified > mine.modified) || (base == nil && firstJoin && mine.modified == .distantPast) {
                    if localChanged {
                        report.conflicts.append(ConfigSyncConflict(date: now, siteID: id, siteName: scopeLabel("secret:" + key), key: "secret:" + key, label: label,
                                                                   keptDevice: newest.bundle.deviceName, keptModified: newest.item.modified,
                                                                   otherDevice: deviceName, otherModified: mine.modified, otherData: nil, keptRemote: true))
                    }
                    takeRemote()
                } else {
                    finalSecrets.append(ConfigSyncSecretItem(service: mine.secret.service, account: mine.secret.account, usage: mine.secret.usage,
                                                             value: mine.secret.value, modified: mine.modified))
                    report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: label, device: deviceName, category: category))
                    if remoteChanged {
                        report.conflicts.append(ConfigSyncConflict(date: now, siteID: id, siteName: scopeLabel("secret:" + key), key: "secret:" + key, label: label,
                                                                   keptDevice: deviceName, keptModified: mine.modified,
                                                                   otherDevice: newest.bundle.deviceName, otherModified: newest.item.modified,
                                                                   otherData: nil, keptRemote: false))
                    }
                    siteState.secrets[key]?.synced = mine.hash
                }
            }
            for item in finalSecrets {
                let key = item.key
                if let mine = mineByKey[key], mine.secret.value == item.value { siteState.secrets[key]?.synced = mine.hash }
            }
        }

        // 4. État : la version finale devient la base commune.
        for (key, item) in final {
            siteState.items[key] = ConfigSyncState.Item(hash: item.hash, modified: item.modified, synced: item.hash)
        }

        // 5. Publication de la version de ce Mac (seulement si elle a changé).
        let items = final.values.sorted { $0.key < $1.key }
        let removed = siteState.removed
        let signature = ConfigHash.sha256(Data((items.map { "\($0.key)=\($0.hash)@\($0.modified.timeIntervalSince1970)" }
            + finalSecrets.sorted { $0.key < $1.key }.map { "\($0.key)=\(secretHash($0.secret))@\($0.modified.timeIntervalSince1970)" }
            + removed.keys.sorted().map { "-\($0)" }
            + [siteName, appVersion, deviceName])
            .joined(separator: "\n").utf8))
        let url = scope.isSite ? bundleURL(site: id, device: deviceID) : globalBundleURL(device: deviceID)
        if siteState.published != signature || !FileManager.default.fileExists(atPath: url.path) {
            let sealed = try sealSecrets(finalSecrets, now: now)
            let bundle = ConfigSyncBundle(siteID: id, siteName: siteName, deviceID: deviceID, deviceName: deviceName, updated: now,
                                          items: items, secrets: sealed, secretCount: sealed == nil ? 0 : finalSecrets.count,
                                          appVersion: appVersion, deviceModel: deviceModel, removed: removed.isEmpty ? nil : removed)
            try write(signed(bundle, keys: signing), to: url)
            siteState.published = signature
        }
        siteState.lastSync = now
        state.sites[scope.folder] = siteState

        // 6. Suppressions en attente devenues caduques : plus aucune pierre tombale ailleurs,
        // élément déjà absent ici, ou élément changé depuis (version d'un autre Mac reçue, ou
        // modifiée ici) : la confirmer retirerait une version que personne n'a supprimée.
        state.pendingDeletions.removeAll { deletion in
            guard deletion.scope == scope.folder else { return false }
            if deletion.isWholeSite { return !scope.exists || !all.contains(where: \.deleted) }
            guard all.contains(where: { $0.removed?[deletion.key] != nil }), let mine = local.items[deletion.key],
                  ConfigSyncPolicy.signalsRemoval(ofKey: deletion.key) else { return true }
            return mine.hash != siteState.items[deletion.key]?.synced
        }
    }

    /// Un élément retiré sur un autre Mac (pierre tombale plus récente qu'un refus) : à confirmer ici.
    private func signalRemoval(key: String, label: String, scope: Scope, scopeName: String, category: String,
                               bundles: [ConfigSyncBundle], state: ConfigSyncState, after: Date? = nil, report: inout ConfigSyncReport) {
        guard ConfigSyncPolicy.signalsRemoval(ofKey: key),
              let (bundle, date) = bundles.compactMap({ bundle in bundle.removed?[key].map { (bundle, $0) } }).max(by: { $0.1 < $1.1 }) else { return }
        if let after, date <= after { return }
        let deletion = ConfigSyncDeletion(scope: scope.folder, scopeName: scopeName, key: key, label: label, category: category,
                                          device: bundle.deviceName, date: date)
        if let dismissed = state.dismissed[deletion.id], dismissed >= date { return }
        guard !state.pendingDeletions.contains(where: { $0.id == deletion.id }),
              !report.pendingDeletions.contains(where: { $0.id == deletion.id }) else { return }
        report.pendingDeletions.append(deletion)
    }

    /// Élément reçu d'un autre Mac → opération du plan à appliquer ici.
    /// Vrai si l'élément est accepté (sinon refusé et signalé, jamais publié de nouveau).
    private func accept(_ item: ConfigSyncItem, from bundle: ConfigSyncBundle, scope: Scope, siteName: String, category: String,
                        fromOlder: Bool, snapshot: ConfigSnapshot, into report: inout ConfigSyncReport) -> Bool {
        let siteID = scope.id
        let expected = scope.local.items[item.key]?.hash
        let preserve: Bool? = fromOlder ? true : nil
        switch ConfigSyncKey.parse(item.key) {
        case .site where scope.isSite:
            // Jamais un autre site : la fiche reçue doit porter l'identifiant du dossier.
            let localSites = snapshot.collectionData(.sites).flatMap(ConfigCollection.sites.elements) ?? []
            guard let element = (try? JSONSerialization.jsonObject(with: item.data)).flatMap(ConfigCollection.sites.element),
                  element.id == siteID.uuidString else {
                report.errors.append("Fiche de «\u{00A0}\(siteName)\u{00A0}» refusée (identifiant différent).")
                return false
            }
            report.plan.elements.append(.init(collection: ConfigCollection.sites.key, id: element.id, json: element.json,
                                              expected: localSites.first { $0.id == element.id }?.hash, label: "Site «\u{00A0}\(siteName)\u{00A0}»",
                                              preserveUnknown: preserve))
        case .fortiGate(let id) where scope.isSite:
            let localControllers = snapshot.collectionData(.fortiGates).flatMap(ConfigCollection.fortiGates.elements) ?? []
            guard let element = (try? JSONSerialization.jsonObject(with: item.data)).flatMap(ConfigCollection.fortiGates.element), element.id == id else {
                report.errors.append("FortiGate de «\u{00A0}\(siteName)\u{00A0}» refusée (illisible).")
                return false
            }
            report.plan.elements.append(.init(collection: ConfigCollection.fortiGates.key, id: id, json: element.json,
                                              expected: localControllers.first { $0.id == id }?.hash, label: item.label,
                                              preserveUnknown: preserve))
        case .file(let path) where scope.isSite:
            // Seulement les fichiers du dossier de CE site.
            guard path.hasPrefix(SiteFiles.folderName + "/" + siteID.uuidString + "/"), BackupEngine.isSafeRelativePath(path) else {
                report.errors.append("Fichier «\u{00A0}\(path)\u{00A0}» refusé pour «\u{00A0}\(siteName)\u{00A0}».")
                return false
            }
            report.plan.files.append(.init(path: path, data: item.data, expected: snapshot.file(path).map { ConfigHash.sha256($0.data) },
                                           label: "\(item.label) · \(siteName)"))
        case .file(let path) where !scope.isSite:
            guard ConfigSyncPolicy.isGlobalFile(path, registry: registry), BackupEngine.isSafeRelativePath(path) else {
                report.errors.append("Fichier «\u{00A0}\(path)\u{00A0}» refusé dans les données globales.")
                return false
            }
            report.plan.files.append(.init(path: path, data: item.data, expected: expected, label: item.label))
        case .document(let path) where !scope.isSite:
            guard ConfigSyncPolicy.isGlobalFile(path, registry: registry), BackupEngine.isSafeRelativePath(path),
                  let rule = ConfigSyncPolicy.rule(for: path), (try? JSONSerialization.jsonObject(with: item.data)) is [String: Any] else {
                report.errors.append("«\u{00A0}\(item.label)\u{00A0}» refusé dans les données globales.")
                return false
            }
            report.plan.documents.append(.init(path: path, json: item.data, expected: expected, label: item.label,
                                               preserve: rule.preservedKeys, preserveUnknown: preserve))
        case .element(let path, let arrayKey, let elementID) where !scope.isSite:
            guard ConfigSyncPolicy.isGlobalFile(path, registry: registry), BackupEngine.isSafeRelativePath(path),
                  let list = ConfigSyncPolicy.rule(for: path)?.lists.first(where: { $0.arrayKey == arrayKey }),
                  let object = (try? JSONSerialization.jsonObject(with: item.data)) as? [String: Any],
                  ConfigSyncDocument.identifier(object[list.idField]) == elementID else {
                report.errors.append("«\u{00A0}\(item.label)\u{00A0}» refusé dans les données globales.")
                return false
            }
            report.plan.documents.append(.init(path: path, arrayKey: arrayKey, idField: list.idField, id: elementID, json: item.data,
                                               expected: expected, label: item.label, preserveUnknown: preserve))
        case .preference(let key) where !scope.isSite:
            guard ConfigSyncPolicy.isGlobalPreference(key, registry: registry), ConfigPlist.decode(item.data) != nil else {
                report.errors.append("Réglage «\u{00A0}\(key)\u{00A0}» refusé.")
                return false
            }
            report.plan.preferences.append(.init(key: key, data: item.data, expected: expected, label: item.label))
        default:
            return false
        }
        report.received.append(ConfigSyncEvent(siteID: siteID, siteName: scope.isSite ? siteName : (registry.part(category)?.title ?? "Réglages"),
                                               label: item.label, device: bundle.deviceName, category: category))
        return true
    }

    private func write(_ bundle: ConfigSyncBundle, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BackupEngine.encoder().encode(bundle).write(to: url, options: .atomic)
    }

    // MARK: Conflits et suppressions

    /// Plan qui rétablit la version écartée d'un conflit (jamais un secret).
    public static func restorePlan(_ conflict: ConfigSyncConflict, snapshot: ConfigSnapshot, now: Date = Date()) -> ConfigApplyPlan? {
        guard let data = conflict.otherData, !conflict.isSecret else { return nil }
        var plan = ConfigApplyPlan(origin: "synchro", createdAt: now)
        let global = ConfigSyncGlobal.make(snapshot: snapshot)
        switch ConfigSyncKey.parse(conflict.key) {
        case .site:
            guard let element = (try? JSONSerialization.jsonObject(with: data)).flatMap(ConfigCollection.sites.element) else { return nil }
            let current = snapshot.collectionData(.sites).flatMap(ConfigCollection.sites.elements)?.first { $0.id == element.id }
            plan.elements.append(.init(collection: ConfigCollection.sites.key, id: element.id, json: element.json, expected: current?.hash, label: conflict.label))
        case .fortiGate:
            guard let element = (try? JSONSerialization.jsonObject(with: data)).flatMap(ConfigCollection.fortiGates.element) else { return nil }
            let current = snapshot.collectionData(.fortiGates).flatMap(ConfigCollection.fortiGates.elements)?.first { $0.id == element.id }
            plan.elements.append(.init(collection: ConfigCollection.fortiGates.key, id: element.id, json: element.json, expected: current?.hash, label: conflict.label))
        case .file(let path):
            guard BackupEngine.isSafeRelativePath(path) else { return nil }
            plan.files.append(.init(path: path, data: data, expected: snapshot.file(path).map { ConfigHash.sha256($0.data) }, label: conflict.label))
        case .document(let path):
            guard BackupEngine.isSafeRelativePath(path), let rule = ConfigSyncPolicy.rule(for: path) else { return nil }
            plan.documents.append(.init(path: path, json: data, expected: global.items[conflict.key]?.hash, label: conflict.label,
                                        preserve: rule.preservedKeys))
        case .element(let path, let arrayKey, let id):
            guard BackupEngine.isSafeRelativePath(path), let list = ConfigSyncPolicy.rule(for: path)?.lists.first(where: { $0.arrayKey == arrayKey }) else { return nil }
            plan.documents.append(.init(path: path, arrayKey: arrayKey, idField: list.idField, id: id, json: data,
                                        expected: global.items[conflict.key]?.hash, label: conflict.label))
        case .preference(let key):
            guard ConfigPlist.decode(data) != nil else { return nil }
            plan.preferences.append(.init(key: key, data: data, expected: snapshot.preferences[key].map(ConfigPlist.hash), label: conflict.label))
        case .other:
            return nil
        }
        return plan
    }

    /// Plan qui applique ici une suppression confirmée ; nil pour un site entier (retiré par
    /// l'app, avec son dossier) ou un élément qu'on ne retire pas ainsi (FortiGate, préférence) ;
    /// vide si l'élément n'est déjà plus ici. `base` : empreinte commune à la dernière
    /// synchronisation (état de la synchro) : un élément changé depuis n'est jamais retiré.
    public static func deletionPlan(_ deletion: ConfigSyncDeletion, snapshot: ConfigSnapshot, base: String? = nil,
                                    now: Date = Date()) -> ConfigApplyPlan? {
        var plan = ConfigApplyPlan(origin: "synchro", createdAt: now)
        switch ConfigSyncKey.parse(deletion.key) {
        case .element(let path, let arrayKey, let id):
            guard let list = ConfigSyncPolicy.rule(for: path)?.lists.first(where: { $0.arrayKey == arrayKey }) else { return nil }
            guard let current = ConfigSyncGlobal.make(snapshot: snapshot).items[deletion.key] else { return plan }
            plan.documents.append(.init(path: path, arrayKey: arrayKey, idField: list.idField, id: id, json: nil,
                                        expected: base ?? current.hash, label: deletion.label))
        case .file(let path):
            guard BackupEngine.isSafeRelativePath(path) else { return nil }
            guard let file = snapshot.file(path) else { return plan }
            plan.documents.append(.init(path: path, json: nil, expected: base ?? ConfigHash.sha256(file.data), label: deletion.label))
        case .document(let path):
            // L'empreinte de base est celle du « reste » du fichier : comparée ici, le fichier
            // entier est retiré seulement s'il n'a pas changé depuis.
            guard BackupEngine.isSafeRelativePath(path) else { return nil }
            guard let file = snapshot.file(path) else { return plan }
            if let base, ConfigSyncGlobal.make(snapshot: snapshot).items[deletion.key]?.hash != base { return plan }
            plan.documents.append(.init(path: path, json: nil, expected: ConfigHash.sha256(file.data), label: deletion.label))
        default:
            return nil
        }
        return plan
    }

    // MARK: État local

    public static func loadState(from url: URL) -> ConfigSyncState {
        guard let data = try? Data(contentsOf: url), let state = try? BackupEngine.decoder().decode(ConfigSyncState.self, from: data) else {
            return ConfigSyncState()
        }
        return state
    }

    public static func saveState(_ state: ConfigSyncState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BackupEngine.encoder().encode(state).write(to: url, options: .atomic)
    }
}
