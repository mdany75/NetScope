import Foundation

// Note 28 : un dossier par site dans ~/Library/Application Support/NetScope/sites/ :
//
//   sites.json                      liste des sites et site actif
//   sites/<id>/inventory.json       inventaire PROPRE au site (fiches, historique, événements,
//                                   archive, exclusions, conflits, notes, types choisis à la main)
//   sites/<id>/resultats.json       résultats du dernier scan du site (appareils, bilan des switchs)
//   sites/sans-site/…               plages libres (aucun site actif)
//
// Tous ces fichiers sont du JSON sous le dossier de données : la sauvegarde (note 13) les inclut.

public struct SiteFiles: Sendable, Hashable {
    public static let listName = "sites.json"
    public static let folderName = "sites"
    public static let noSiteKey = "sans-site"
    public static let inventoryName = "inventory.json"
    public static let resultsName = "resultats.json"
    /// Copie de sécurité de l'inventaire d'avant les sites.
    public static let legacyBackupName = "inventory.avant-sites.json"

    /// Dossier de données (~/Library/Application Support/NetScope).
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    public static var standard: SiteFiles {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return SiteFiles(base: support.appendingPathComponent("NetScope", isDirectory: true))
    }

    public static func key(for id: UUID?) -> String { id?.uuidString ?? noSiteKey }

    public var listURL: URL { base.appendingPathComponent(Self.listName) }
    public var legacyInventoryURL: URL { base.appendingPathComponent(Self.inventoryName) }
    public var legacyBackupURL: URL { base.appendingPathComponent(Self.legacyBackupName) }

    public func folder(for key: String) -> URL {
        base.appendingPathComponent(Self.folderName, isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    public func inventoryURL(for key: String) -> URL { folder(for: key).appendingPathComponent(Self.inventoryName) }
    public func resultsURL(for key: String) -> URL { folder(for: key).appendingPathComponent(Self.resultsName) }

    // MARK: Liste

    public func loadList() -> SiteList? {
        guard let data = try? Data(contentsOf: listURL) else { return nil }
        return SiteList.decode(data)
    }

    public func saveList(_ list: SiteList) throws {
        guard let data = list.encoded() else { return }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try data.write(to: listURL, options: .atomic)
    }

    // MARK: Résultats

    public func loadResults(for key: String) -> SiteResults? {
        guard let data = try? Data(contentsOf: resultsURL(for: key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SiteResults.self, from: data)
    }

    public func saveResults(_ results: SiteResults, for key: String) {
        let url = resultsURL(for: key)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(results).write(to: url, options: .atomic)
        } catch {
            NSLog("NetScope : résultats du site non enregistrés (%@) : %@", url.path, error.localizedDescription)
        }
    }

    // MARK: Inventaire

    public func loadInventory(for key: String) throws -> InventoryStore {
        try InventoryStore.load(from: inventoryURL(for: key))
    }

    public func saveInventory(_ store: InventoryStore, for key: String) throws {
        try store.save(to: inventoryURL(for: key))
    }

    /// Nombre de fiches de l'inventaire d'un site (0 si absent ou illisible).
    public func inventoryCount(for key: String) -> Int {
        (try? loadInventory(for: key))?.count ?? 0
    }

    /// Supprime le dossier d'un site (inventaire et résultats) : seulement après confirmation.
    public func removeFolder(for key: String) {
        try? FileManager.default.removeItem(at: folder(for: key))
    }

    /// Déplace le dossier des plages libres vers un site qu'on vient d'enregistrer (ses résultats et
    /// son inventaire le suivent). Rien n'est fait si le site a déjà un dossier.
    public func adoptNoSiteFolder(into key: String) {
        let from = folder(for: Self.noSiteKey), to = folder(for: key)
        let manager = FileManager.default
        guard manager.fileExists(atPath: from.path), !manager.fileExists(atPath: to.path) else { return }
        try? manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.moveItem(at: from, to: to)
    }
}

// MARK: - Migration (avant la 0.12.0)

/// Première ouverture de la 0.12.0 : les plages enregistrées, l'inventaire (inventory.json, avec son
/// historique et les types choisis à la main), les noms personnalisés et la FortiGate qui couvre ces
/// plages deviennent ceux d'un premier site « Site principal ». L'ancien inventory.json est gardé
/// en copie de sécurité (inventory.avant-sites.json) ; rien n'est perdu.
public enum SiteMigration {
    public static let firstSiteName = "Site principal"

    public struct Result: Sendable {
        public var list: SiteList
        public var siteID: UUID
        /// Inventaire repris (fiches), nil s'il n'y en avait pas.
        public var migratedRecords: Int?
        public var backupURL: URL?
    }

    /// Sans effet si sites.json existe déjà (renvoie nil).
    public static func migrateIfNeeded(files: SiteFiles, ranges: [ScanRangeConfig], customNames: [String: String],
                                       controllers: [FortiGateController], newID: UUID = UUID(), now: Date = Date()) throws -> Result? {
        guard files.loadList() == nil else { return nil }
        let parsed = ranges.compactMap { try? $0.parsed() }
        var site = Site(id: newID, name: firstSiteName, ranges: ranges,
                        fortiGateIDs: SiteFortiGate.matching(controllers, ranges: parsed), created: now)
        SiteFortiGate.refreshHints(&site, controllers: controllers)
        let key = SiteFiles.key(for: newID)
        let manager = FileManager.default
        var records: Int?
        var backup: URL?
        if manager.fileExists(atPath: files.legacyInventoryURL.path) {
            let target = files.inventoryURL(for: key)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: files.legacyInventoryURL, to: target)
            records = (try? InventoryStore.load(from: target))?.count
            // Copie de sécurité : l'ancien fichier change de nom (jamais effacé).
            if manager.fileExists(atPath: files.legacyBackupURL.path) { try? manager.removeItem(at: files.legacyBackupURL) }
            try manager.moveItem(at: files.legacyInventoryURL, to: files.legacyBackupURL)
            backup = files.legacyBackupURL
        }
        site.inventoryCount = records
        if !customNames.isEmpty { files.saveResults(SiteResults(customNames: customNames), for: key) }
        let list = SiteList(sites: [site], activeID: newID)
        try files.saveList(list)
        return Result(list: list, siteID: newID, migratedRecords: records, backupURL: backup)
    }
}

// MARK: - Switchs affichés

/// « Switchs et ports » ne montre que les switchs du site actif : ses FortiSwitch (par sa FortiGate)
/// et ses switchs SNMP associés ; un switch sans site n'apparaît que s'il est dans les plages du
/// dernier scan (sinon celles du site). Fonction pure.
public enum SiteSwitchFilter {
    public struct Candidate: Hashable, Sendable {
        public var host: String
        /// FortiGate qui a lu ce FortiSwitch (nil : switch SNMP).
        public var controllerID: UUID?

        public init(host: String, controllerID: UUID? = nil) {
            self.host = host
            self.controllerID = controllerID
        }
    }

    public static func visible(_ candidates: [Candidate], activeSite: Site?, sites: [Site], scanRanges: [IPRange]) -> [String] {
        let ranges = scanRanges.isEmpty ? (activeSite?.parsedRanges ?? []) : scanRanges
        func inRanges(_ host: String) -> Bool {
            // Ni scan ni plages : rien ne permet d'écarter le switch.
            guard !ranges.isEmpty else { return true }
            guard let ip = IPv4Address(host) else { return false }
            return ScanRelevance.contains(ranges, ip)
        }
        return candidates.filter { candidate in
            if let controller = candidate.controllerID {
                // FortiSwitch : celui de la FortiGate du site actif ; sans site actif, tous.
                guard let site = activeSite else { return true }
                return site.fortiGateIDs.contains(controller)
            }
            let owners = sites.filter { $0.switchHosts.contains(candidate.host) }
            if let site = activeSite {
                if owners.contains(where: { $0.id == site.id }) { return true }
                if !owners.isEmpty { return false } // switch d'un autre site
                return inRanges(candidate.host)
            }
            // Aucun site actif : un switch sans site ou d'un site n'est montré que dans les plages scannées.
            return inRanges(candidate.host)
        }.map(\.host)
    }

    /// Propriétaire de chaque FortiSwitch affiché (adresse du relevé → FortiGate), dans l'ordre de
    /// `FortiMulti.snapshots` (mêmes adresses de remplacement).
    public static func controllerOwners(_ sites: [FortiSiteReport]) -> [String: UUID] {
        let snapshots = FortiMulti.snapshots(sites)
        var owners: [String: UUID] = [:]
        var index = 0
        for site in sites {
            let count = FortiConvert.snapshots(from: site.report).count
            for _ in 0..<count where index < snapshots.count {
                owners[snapshots[index].host.description] = site.controllerID
                index += 1
            }
        }
        return owners
    }
}
