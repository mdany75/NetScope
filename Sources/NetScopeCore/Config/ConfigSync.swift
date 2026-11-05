import CryptoKit
import Foundation

// Note 56 : synchronisation de la configuration entre plusieurs Mac par iCloud Drive (un simple
// dossier, NetScope/Sync, jamais CloudKit), désactivée par défaut et choisie SITE PAR SITE.
//
// Forme du dossier : <racine>/<identifiant du site>/<identifiant du Mac>.json. Chaque Mac n'écrit
// que SON fichier (aucune écriture concurrente du même fichier, donc pas de copies « 2 »
// d'iCloud) ; il lit ceux des autres. Un fichier (`ConfigSyncBundle`) porte, pour un site : la
// fiche du site (sans ce qui est propre à chaque Mac : dernier scan, nombre de fiches), son
// inventaire, les notes de ses appareils, ses FortiGate et, chiffrés par le mot de passe de
// synchronisation (même chiffrement que la note 38), les jetons de ces FortiGate.
//
// Fusion : élément par élément, par date de modification. Un élément changé d'un seul côté depuis
// la dernière synchronisation prend la version changée ; changé des deux côtés : CONFLIT, la
// version la plus récente l'emporte et l'autre est gardée (`ConfigSyncConflict`) pour être
// rétablie : rien n'est jamais écrasé sans le dire. Un site est reconnu par son identifiant
// (dossier), jamais par ses plages : deux sites ne sont jamais fusionnés. Une suppression faite
// sur un autre Mac est signalée, jamais appliquée d'office.
//
// Le moteur ne lit et n'écrit que la racine qu'on lui donne (dossier temporaire dans les tests) ;
// les changements reçus sont rendus sous forme de `ConfigApplyPlan`, appliqué par l'app.

/// Un élément synchronisé d'un site.
public struct ConfigSyncItem: Codable, Hashable, Sendable {
    /// « site », « fichier:sites/<id>/inventory.json », « fortigate:<id> ».
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

/// Ce qu'un Mac publie pour un site.
public struct ConfigSyncBundle: Codable, Sendable, Equatable {
    public static let formatName = "netscope-synchro"
    public static let currentVersion = 1

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

    public init(siteID: UUID, siteName: String, deviceID: String, deviceName: String, updated: Date, items: [ConfigSyncItem],
                secrets: Data? = nil, secretCount: Int = 0, deleted: Bool = false) {
        self.siteID = siteID
        self.siteName = siteName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.updated = updated
        self.items = items
        self.secrets = secrets
        self.secretCount = secretCount
        self.deleted = deleted
    }
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
    }

    public var sites: [String: Site] = [:]
    public var conflicts: [ConfigSyncConflict] = []
    public var lastSync: Date?

    public init() {}
}

/// Un conflit : l'élément a changé sur deux Mac depuis la dernière synchronisation. La version
/// la plus récente a été gardée ; l'autre est ici, à rétablir au besoin.
public struct ConfigSyncConflict: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var siteID: UUID
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
}

/// Un événement de synchronisation (reçu, envoyé, suppression signalée).
public struct ConfigSyncEvent: Hashable, Sendable {
    public var siteID: UUID
    public var siteName: String
    public var label: String
    public var device: String
}

/// Un site présent dans iCloud Drive mais pas sur ce Mac.
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
    public var deletions: [ConfigSyncEvent] = []
    public var errors: [String] = []
    /// Secrets non synchronisés (pas de mot de passe de synchronisation sur ce Mac).
    public var secretsSkipped = false

    public var isQuiet: Bool { received.isEmpty && sent.isEmpty && conflicts.isEmpty && deletions.isEmpty && errors.isEmpty }
}

public enum ConfigSyncError: Error, LocalizedError, Equatable {
    case folderUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable(let path): return "Dossier de synchronisation inaccessible\u{00A0}: \(path)."
        }
    }
}

// MARK: - Éléments locaux d'un site

/// Ce que ce Mac a pour un site (pur : tiré d'un `ConfigSnapshot`).
public struct ConfigSyncLocalSite: Sendable {
    public struct Item: Sendable {
        public var label: String
        public var data: Data
        public var hash: String
        /// Date connue de la modification (fichier) ; nil : déduite par l'état.
        public var modifiedHint: Date?
    }

    public var siteID: UUID
    public var name: String
    public var exists: Bool
    public var items: [String: Item]
    public var secrets: [BackupSecret]

    /// Fichiers du dossier du site synchronisés (le dernier scan, propre à chaque Mac, ne l'est pas).
    public static let siteFiles = [SiteFiles.inventoryName, SiteFiles.notesName]

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
                let label = BackupEngine.label(for: path).replacingOccurrences(of: " (site)", with: "")
                items["fichier:" + path] = Item(label: label.prefix(1).uppercased() + label.dropFirst(),
                                                data: file.data, hash: ConfigHash.sha256(file.data), modifiedHint: file.modified)
            }
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
}

// MARK: - Moteur

public struct ConfigSyncEngine: Sendable {
    /// Dossier NetScope/Sync (iCloud Drive), ou un dossier temporaire dans les tests.
    public var root: URL
    public var deviceID: String
    public var deviceName: String
    /// Mot de passe de synchronisation (Trousseau de ce Mac) ; nil : secrets non synchronisés.
    public var password: String?
    public var iterations: Int

    public init(root: URL, deviceID: String, deviceName: String, password: String?, iterations: Int = BackupCrypto.defaultIterations) {
        self.root = root
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.password = password.flatMap { $0.isEmpty ? nil : $0 }
        self.iterations = iterations
    }

    public func folder(for site: UUID) -> URL { root.appendingPathComponent(site.uuidString, isDirectory: true) }

    public func bundleURL(site: UUID, device: String) -> URL {
        folder(for: site).appendingPathComponent(Self.safeName(device) + ".json")
    }

    static func safeName(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    // MARK: Lecture

    /// Fichiers des AUTRES Mac pour un site (le plus récent par Mac ; copies de conflit d'iCloud
    /// comprises, illisibles ignorés, jamais un fichier d'un autre site).
    public func remoteBundles(for site: UUID) -> [ConfigSyncBundle] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder(for: site).path) else { return [] }
        var byDevice: [String: ConfigSyncBundle] = [:]
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let data = try? Data(contentsOf: folder(for: site).appendingPathComponent(name)),
                  let bundle = try? BackupEngine.decoder().decode(ConfigSyncBundle.self, from: data),
                  bundle.format == ConfigSyncBundle.formatName, bundle.version <= ConfigSyncBundle.currentVersion,
                  bundle.siteID == site, bundle.deviceID != deviceID else { continue }
            if let current = byDevice[bundle.deviceID], current.updated >= bundle.updated { continue }
            byDevice[bundle.deviceID] = bundle
        }
        return byDevice.values.sorted { $0.deviceID < $1.deviceID }
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

    func openSecrets(_ bundle: ConfigSyncBundle) throws -> [ConfigSyncSecretItem] {
        guard let sealed = bundle.secrets else { return [] }
        guard let password else { throw BackupCryptoError.passwordRequired }
        let opened = try BackupCrypto.open(sealed, password: password)
        guard let items = try? BackupEngine.decoder().decode([ConfigSyncSecretItem].self, from: opened.plaintext),
              items.count == opened.header.secretCount else { throw BackupCryptoError.tampered }
        let fortiService = BackupKeychainScan.servicePrefix + ".fortigate"
        guard items.allSatisfy({ $0.service == fortiService }) else { throw BackupCryptoError.tampered }
        return items
    }

    // MARK: Synchronisation

    /// Synchronise les sites choisis : publie la version de ce Mac, lit celles des autres, fusionne
    /// par date de modification et rend les changements reçus (`report.plan`) à appliquer ici.
    public func sync(sites ids: [UUID], snapshot: ConfigSnapshot, state: inout ConfigSyncState, now: Date = Date()) throws -> ConfigSyncReport {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw ConfigSyncError.folderUnavailable(root.path)
        }
        var report = ConfigSyncReport(plan: ConfigApplyPlan(origin: "synchro", createdAt: now))
        let localSites = snapshot.collectionData(.sites).flatMap(ConfigCollection.sites.elements) ?? []
        let localControllers = snapshot.collectionData(.fortiGates).flatMap(ConfigCollection.fortiGates.elements) ?? []

        for id in ids {
            let local = ConfigSyncLocalSite.make(siteID: id, snapshot: snapshot)
            var siteState = state.sites[id.uuidString] ?? ConfigSyncState.Site()
            let all = remoteBundles(for: id)
            let remotes = all.filter { !$0.deleted }
            let siteName = local.exists ? local.name : (remotes.max(by: { $0.updated < $1.updated })?.siteName ?? id.uuidString)

            // Site supprimé ici après avoir été synchronisé : on le dit aux autres, sans rien recevoir.
            if !local.exists, siteState.lastSync != nil {
                let bundle = ConfigSyncBundle(siteID: id, siteName: siteName, deviceID: deviceID, deviceName: deviceName, updated: now,
                                              items: [], deleted: true)
                try write(bundle)
                siteState.published = "supprime"
                state.sites[id.uuidString] = siteState
                continue
            }
            // Supprimé sur un autre Mac : signalé, jamais appliqué.
            for bundle in all where bundle.deleted && local.exists {
                report.deletions.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: "Site supprimé", device: bundle.deviceName))
            }

            // 1. Dates locales : une empreinte nouvelle date la modification.
            var localItems: [String: (item: ConfigSyncLocalSite.Item, modified: Date)] = [:]
            for (key, item) in local.items {
                var known = siteState.items[key]
                if known?.hash != item.hash {
                    let modified = known == nil ? (item.modifiedHint ?? .distantPast) : (item.modifiedHint.map { max($0, known!.modified) } ?? now)
                    known = ConfigSyncState.Item(hash: item.hash, modified: modified, synced: known?.synced)
                    siteState.items[key] = known
                }
                localItems[key] = (item, known!.modified)
            }

            // 2. Fusion élément par élément.
            var final: [String: ConfigSyncItem] = [:]
            let keys = Set(localItems.keys).union(remotes.flatMap { $0.items.map(\.key) })
            for key in keys.sorted() {
                let mine = localItems[key]
                let candidates = remotes.compactMap { bundle in bundle.items.first { $0.key == key }.map { (bundle, $0) } }
                let newest = candidates.max { a, b in a.1.modified == b.1.modified ? a.0.deviceID < b.0.deviceID : a.1.modified < b.1.modified }
                let base = siteState.items[key]?.synced
                guard let (remoteBundle, remote) = newest else {
                    guard let mine else { continue }
                    final[key] = ConfigSyncItem(key: key, label: mine.item.label, modified: mine.modified, hash: mine.item.hash, data: mine.item.data)
                    if mine.item.hash != base { report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: mine.item.label, device: deviceName)) }
                    continue
                }
                guard let mine else {
                    // Absent ici : reçu, sauf s'il a été retiré ici depuis (base inchangée ailleurs).
                    if base != nil, remote.hash == base, local.exists { continue }
                    if accept(remote, from: remoteBundle, siteID: id, siteName: siteName, localSites: localSites,
                            localControllers: localControllers, snapshot: snapshot, into: &report) { final[key] = remote }
                    continue
                }
                if mine.item.hash == remote.hash {
                    final[key] = ConfigSyncItem(key: key, label: mine.item.label, modified: max(mine.modified, remote.modified),
                                                hash: mine.item.hash, data: mine.item.data)
                    continue
                }
                let localChanged = mine.item.hash != base
                let remoteChanged = remote.hash != base
                if !localChanged {
                    final[key] = accept(remote, from: remoteBundle, siteID: id, siteName: siteName, localSites: localSites,
                                        localControllers: localControllers, snapshot: snapshot, into: &report) ? remote : ConfigSyncItem(key: key, label: mine.item.label, modified: mine.modified, hash: mine.item.hash, data: mine.item.data)
                } else if !remoteChanged {
                    final[key] = ConfigSyncItem(key: key, label: mine.item.label, modified: mine.modified, hash: mine.item.hash, data: mine.item.data)
                    report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: mine.item.label, device: deviceName))
                } else if remote.modified > mine.modified {
                    guard accept(remote, from: remoteBundle, siteID: id, siteName: siteName, localSites: localSites,
                                 localControllers: localControllers, snapshot: snapshot, into: &report) else {
                        final[key] = ConfigSyncItem(key: key, label: mine.item.label, modified: mine.modified, hash: mine.item.hash, data: mine.item.data)
                        continue
                    }
                    final[key] = remote
                    report.conflicts.append(ConfigSyncConflict(date: now, siteID: id, siteName: siteName, key: key, label: remote.label,
                                                               keptDevice: remoteBundle.deviceName, keptModified: remote.modified,
                                                               otherDevice: deviceName, otherModified: mine.modified,
                                                               otherData: mine.item.data, keptRemote: true))
                } else {
                    final[key] = ConfigSyncItem(key: key, label: mine.item.label, modified: mine.modified, hash: mine.item.hash, data: mine.item.data)
                    report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: mine.item.label, device: deviceName))
                    report.conflicts.append(ConfigSyncConflict(date: now, siteID: id, siteName: siteName, key: key, label: mine.item.label,
                                                               keptDevice: deviceName, keptModified: mine.modified,
                                                               otherDevice: remoteBundle.deviceName, otherModified: remote.modified,
                                                               otherData: remote.data, keptRemote: false))
                }
            }

            // 3. Secrets (jetons des FortiGate du site), seulement avec le mot de passe de synchronisation.
            var finalSecrets: [ConfigSyncSecretItem] = []
            if password == nil {
                if !local.secrets.isEmpty || remotes.contains(where: { $0.secrets != nil }) { report.secretsSkipped = true }
            } else {
                var remoteSecrets: [(bundle: ConfigSyncBundle, item: ConfigSyncSecretItem)] = []
                for bundle in remotes where bundle.secrets != nil {
                    do {
                        remoteSecrets += try openSecrets(bundle).map { (bundle, $0) }
                    } catch BackupCryptoError.wrongPassword {
                        report.errors.append("Mot de passe de synchronisation différent sur «\u{00A0}\(bundle.deviceName)\u{00A0}»\u{00A0}: jetons de «\u{00A0}\(siteName)\u{00A0}» non reçus.")
                    } catch {
                        report.errors.append("Jetons de «\u{00A0}\(siteName)\u{00A0}» illisibles sur «\u{00A0}\(bundle.deviceName)\u{00A0}»\u{00A0}: \(error.localizedDescription)")
                    }
                }
                var mineByKey: [String: (secret: BackupSecret, hash: String, modified: Date)] = [:]
                for secret in local.secrets {
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
                    guard let newest else {
                        if let mine {
                            finalSecrets.append(ConfigSyncSecretItem(service: mine.secret.service, account: mine.secret.account, usage: mine.secret.usage,
                                                                     value: mine.secret.value, modified: mine.modified))
                            if mine.hash != base { report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: label, device: deviceName)) }
                        }
                        continue
                    }
                    let remoteHash = secretHash(newest.item.secret)
                    func takeRemote() {
                        finalSecrets.append(newest.item)
                        report.plan.secrets.append(newest.item.secret)
                        report.received.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: label, device: newest.bundle.deviceName))
                        siteState.secrets[key] = ConfigSyncState.Item(hash: remoteHash, modified: newest.item.modified, synced: remoteHash)
                    }
                    guard let mine else {
                        if base != nil, remoteHash == base, local.exists { continue }
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
                    if !localChanged || (remoteChanged && newest.item.modified > mine.modified) {
                        if localChanged {
                            report.conflicts.append(ConfigSyncConflict(date: now, siteID: id, siteName: siteName, key: "secret:" + key, label: label,
                                                                       keptDevice: newest.bundle.deviceName, keptModified: newest.item.modified,
                                                                       otherDevice: deviceName, otherModified: mine.modified, otherData: nil, keptRemote: true))
                        }
                        takeRemote()
                    } else {
                        finalSecrets.append(ConfigSyncSecretItem(service: mine.secret.service, account: mine.secret.account, usage: mine.secret.usage,
                                                                 value: mine.secret.value, modified: mine.modified))
                        report.sent.append(ConfigSyncEvent(siteID: id, siteName: siteName, label: label, device: deviceName))
                        if remoteChanged {
                            report.conflicts.append(ConfigSyncConflict(date: now, siteID: id, siteName: siteName, key: "secret:" + key, label: label,
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

            // 4. État : la version finale devient la base commune (reçue : appliquée au prochain lancement).
            for (key, item) in final {
                siteState.items[key] = ConfigSyncState.Item(hash: item.hash, modified: item.modified, synced: item.hash)
            }

            // 5. Publication de la version de ce Mac (seulement si elle a changé).
            let items = final.values.sorted { $0.key < $1.key }
            let signature = ConfigHash.sha256(Data((items.map { "\($0.key)=\($0.hash)@\($0.modified.timeIntervalSince1970)" }
                + finalSecrets.sorted { $0.key < $1.key }.map { "\($0.key)=\(secretHash($0.secret))@\($0.modified.timeIntervalSince1970)" } + [siteName])
                .joined(separator: "\n").utf8))
            if siteState.published != signature || !manager.fileExists(atPath: bundleURL(site: id, device: deviceID).path) {
                let sealed = try sealSecrets(finalSecrets, now: now)
                let bundle = ConfigSyncBundle(siteID: id, siteName: siteName, deviceID: deviceID, deviceName: deviceName, updated: now,
                                              items: items, secrets: sealed, secretCount: sealed == nil ? 0 : finalSecrets.count)
                try write(bundle)
                siteState.published = signature
            }
            siteState.lastSync = now
            state.sites[id.uuidString] = siteState
        }
        state.conflicts = Array((report.conflicts + state.conflicts).prefix(50))
        state.lastSync = now
        return report
    }

    /// Élément reçu d'un autre Mac → opération du plan à appliquer ici.
    /// Vrai si l'élément est accepté (sinon refusé et signalé, jamais publié de nouveau).
    @discardableResult
    private func accept(_ item: ConfigSyncItem, from bundle: ConfigSyncBundle, siteID: UUID, siteName: String,
                        localSites: [ConfigCollection.Element], localControllers: [ConfigCollection.Element],
                        snapshot: ConfigSnapshot, into report: inout ConfigSyncReport) -> Bool {
        let event = ConfigSyncEvent(siteID: siteID, siteName: siteName, label: item.label, device: bundle.deviceName)
        if item.key == "site" {
            // Jamais un autre site : la fiche reçue doit porter l'identifiant du dossier.
            guard let element = (try? JSONSerialization.jsonObject(with: item.data)).flatMap(ConfigCollection.sites.element),
                  element.id == siteID.uuidString else {
                report.errors.append("Fiche de «\u{00A0}\(siteName)\u{00A0}» refusée (identifiant différent).")
                return false
            }
            report.plan.elements.append(.init(collection: ConfigCollection.sites.key, id: element.id, json: element.json,
                                              expected: localSites.first { $0.id == element.id }?.hash, label: "Site «\u{00A0}\(siteName)\u{00A0}»"))
        } else if item.key.hasPrefix("fortigate:") {
            let id = String(item.key.dropFirst("fortigate:".count))
            guard let element = (try? JSONSerialization.jsonObject(with: item.data)).flatMap(ConfigCollection.fortiGates.element), element.id == id else {
                report.errors.append("FortiGate de «\u{00A0}\(siteName)\u{00A0}» refusée (illisible).")
                return false
            }
            report.plan.elements.append(.init(collection: ConfigCollection.fortiGates.key, id: id, json: element.json,
                                              expected: localControllers.first { $0.id == id }?.hash, label: item.label))
        } else if item.key.hasPrefix("fichier:") {
            let path = String(item.key.dropFirst("fichier:".count))
            // Seulement les fichiers du dossier de CE site.
            guard path.hasPrefix(SiteFiles.folderName + "/" + siteID.uuidString + "/"), BackupEngine.isSafeRelativePath(path) else {
                report.errors.append("Fichier «\u{00A0}\(path)\u{00A0}» refusé pour «\u{00A0}\(siteName)\u{00A0}».")
                return false
            }
            report.plan.files.append(.init(path: path, data: item.data, expected: snapshot.file(path).map { ConfigHash.sha256($0.data) },
                                           label: "\(item.label) · \(siteName)"))
        } else {
            return false
        }
        report.received.append(event)
        return true
    }

    private func write(_ bundle: ConfigSyncBundle) throws {
        let url = bundleURL(site: bundle.siteID, device: bundle.deviceID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BackupEngine.encoder().encode(bundle).write(to: url, options: .atomic)
    }

    // MARK: Conflits

    /// Plan qui rétablit la version écartée d'un conflit (jamais un secret).
    public static func restorePlan(_ conflict: ConfigSyncConflict, snapshot: ConfigSnapshot, now: Date = Date()) -> ConfigApplyPlan? {
        guard let data = conflict.otherData, !conflict.isSecret else { return nil }
        var plan = ConfigApplyPlan(origin: "synchro", createdAt: now)
        if conflict.key == "site" {
            guard let element = (try? JSONSerialization.jsonObject(with: data)).flatMap(ConfigCollection.sites.element) else { return nil }
            let current = snapshot.collectionData(.sites).flatMap(ConfigCollection.sites.elements)?.first { $0.id == element.id }
            plan.elements.append(.init(collection: ConfigCollection.sites.key, id: element.id, json: element.json, expected: current?.hash, label: conflict.label))
        } else if conflict.key.hasPrefix("fortigate:") {
            guard let element = (try? JSONSerialization.jsonObject(with: data)).flatMap(ConfigCollection.fortiGates.element) else { return nil }
            let current = snapshot.collectionData(.fortiGates).flatMap(ConfigCollection.fortiGates.elements)?.first { $0.id == element.id }
            plan.elements.append(.init(collection: ConfigCollection.fortiGates.key, id: element.id, json: element.json, expected: current?.hash, label: conflict.label))
        } else if conflict.key.hasPrefix("fichier:") {
            let path = String(conflict.key.dropFirst("fichier:".count))
            guard BackupEngine.isSafeRelativePath(path) else { return nil }
            plan.files.append(.init(path: path, data: data, expected: snapshot.file(path).map { ConfigHash.sha256($0.data) }, label: conflict.label))
        } else {
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
