import Foundation

// Note 28 : un dossier par site dans ~/Library/Application Support/NetScope/sites/ :
//
//   sites.json                      liste des sites et site actif
//   sites/<id>/inventory.json       inventaire PROPRE au site (fiches, historique, événements,
//                                   archive, exclusions, conflits, notes, types choisis à la main)
//   sites/<id>/resultats.json       résultats du dernier scan du site (appareils, bilan des switchs)
//   sites/<id>/notes-appareils.json notes du technicien par appareil, propres au site
//   sites/sans-site/…               plages libres (aucun site actif)
//
// Tous ces fichiers sont du JSON sous le dossier de données : la sauvegarde (note 13) les inclut.

public struct SiteFiles: Sendable, Hashable {
    public static let listName = "sites.json"
    public static let folderName = "sites"
    public static let noSiteKey = "sans-site"
    public static let inventoryName = "inventory.json"
    public static let resultsName = "resultats.json"
    public static let notesName = "notes-appareils.json"
    /// Copie de sécurité des notes d'appareils d'avant les sites (notes communes à tous les réseaux).
    public static let legacyNotesBackupName = "notes-appareils.avant-sites.json"
    /// Identifiant retenu pendant la migration : un essai interrompu reprend le même site.
    public static let migrationMarkerName = "sites-migration.id"
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
    public var legacyNotesURL: URL { base.appendingPathComponent(Self.notesName) }
    public var legacyNotesBackupURL: URL { base.appendingPathComponent(Self.legacyNotesBackupName) }
    public var migrationMarkerURL: URL { base.appendingPathComponent(Self.migrationMarkerName) }

    public func folder(for key: String) -> URL {
        base.appendingPathComponent(Self.folderName, isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    public func inventoryURL(for key: String) -> URL { folder(for: key).appendingPathComponent(Self.inventoryName) }
    public func resultsURL(for key: String) -> URL { folder(for: key).appendingPathComponent(Self.resultsName) }
    public func notesURL(for key: String) -> URL { folder(for: key).appendingPathComponent(Self.notesName) }

    // MARK: Liste

    /// État de sites.json : absent (première ouverture), lu, ou présent mais illisible.
    public enum ListState: Sendable {
        case missing
        case loaded(SiteList)
        case unreadable
    }

    public func readList() -> ListState {
        guard FileManager.default.fileExists(atPath: listURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: listURL), let list = SiteList.decode(data) else { return .unreadable }
        return .loaded(list)
    }

    /// Liste lue (nil si absente ou illisible : voir `readList`).
    public func loadList() -> SiteList? {
        if case .loaded(let list) = readList() { return list }
        return nil
    }

    /// sites.json illisible : mis de côté (sites.illisible-<date>.json) plutôt qu'écrasé.
    @discardableResult
    public func setAsideUnreadableList(now: Date = Date()) -> URL? {
        let aside = base.appendingPathComponent("sites.illisible-\(Int(now.timeIntervalSince1970)).json")
        do {
            try FileManager.default.moveItem(at: listURL, to: aside)
            return aside
        } catch {
            return nil
        }
    }

    /// Identifiants des dossiers sites/<UUID>/ présents sur le disque (ordre stable).
    public func siteFolderIDs() -> [UUID] {
        let root = base.appendingPathComponent(Self.folderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap(UUID.init(uuidString:))
    }

    /// Liste reconstruite à partir des dossiers de sites (sites.json perdu ou illisible) : un site
    /// « Site récupéré » par dossier, pour ne perdre aucun inventaire. Les plages sont à refaire.
    public func recoveredList(now: Date = Date()) -> SiteList {
        var list = SiteList()
        for id in siteFolderIDs() {
            var site = Site(id: id, name: list.uniqueName(SiteMigration.recoveredSiteName), created: now)
            site.inventoryCount = inventoryCount(for: SiteFiles.key(for: id))
            list.sites.append(site)
        }
        list.activeID = list.sites.first?.id
        return list
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
            AppLog.shared.error("Sites", "Résultats du site non enregistrés (\(url.path))\u{00A0}: \(error.localizedDescription)")
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
    public static let recoveredSiteName = "Site récupéré"

    public struct Result: Sendable {
        public var list: SiteList
        public var siteID: UUID?
        /// Inventaire repris (fiches), nil s'il n'y en avait pas.
        public var migratedRecords: Int?
        public var backupURL: URL?
        /// Sites reconstruits à partir des dossiers sites/<UUID>/ (sites.json perdu), 0 sinon.
        public var recoveredSites = 0
    }

    /// Sans effet si sites.json existe déjà, même illisible (renvoie nil : l'appelant le met de
    /// côté et reconstruit la liste, jamais une migration qui l'écraserait).
    ///
    /// Ordre sûr : copie de l'inventaire, écriture de sites.json, puis seulement renommage de
    /// l'ancien fichier. Un essai interrompu reprend le même identifiant (fichier marqueur).
    public static func migrateIfNeeded(files: SiteFiles, ranges: [ScanRangeConfig], customNames: [String: String],
                                       controllers: [FortiGateController], newID: UUID? = nil, now: Date = Date()) throws -> Result? {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: files.listURL.path) else { return nil }
        let marker = (try? String(contentsOf: files.migrationMarkerURL, encoding: .utf8))
            .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let hasLegacy = manager.fileExists(atPath: files.legacyInventoryURL.path)
        // sites.json perdu après la migration (ancien inventaire déjà renommé) : on reconstruit la
        // liste à partir des dossiers des sites plutôt que de créer un site vide.
        if !hasLegacy, marker == nil, !files.siteFolderIDs().isEmpty {
            let list = files.recoveredList(now: now)
            try files.saveList(list)
            return Result(list: list, siteID: list.activeID, migratedRecords: nil, backupURL: nil, recoveredSites: list.sites.count)
        }
        let id = newID ?? marker ?? UUID()
        try manager.createDirectory(at: files.base, withIntermediateDirectories: true)
        try id.uuidString.write(to: files.migrationMarkerURL, atomically: true, encoding: .utf8)
        let parsed = ranges.compactMap { try? $0.parsed() }
        var site = Site(id: id, name: firstSiteName, ranges: ranges,
                        fortiGateIDs: SiteFortiGate.matching(controllers, ranges: parsed), created: now)
        SiteFortiGate.refreshHints(&site, controllers: controllers)
        let key = SiteFiles.key(for: id)
        var records: Int?
        if hasLegacy {
            let target = files.inventoryURL(for: key)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: files.legacyInventoryURL, to: target)
            records = (try? InventoryStore.load(from: target))?.count
        }
        site.inventoryCount = records
        if !customNames.isEmpty { files.saveResults(SiteResults(customNames: customNames), for: key) }
        try migrateDeviceNotes(files: files, into: key)
        let list = SiteList(sites: [site], activeID: id)
        // sites.json d'abord : si l'écriture échoue, l'ancien inventaire est encore là.
        try files.saveList(list)
        var backup: URL?
        if hasLegacy {
            // Copie de sécurité : l'ancien fichier change de nom (jamais effacé).
            if manager.fileExists(atPath: files.legacyBackupURL.path) { try? manager.removeItem(at: files.legacyBackupURL) }
            do {
                try manager.moveItem(at: files.legacyInventoryURL, to: files.legacyBackupURL)
                backup = files.legacyBackupURL
            } catch {
                // L'inventaire est déjà copié dans le site : l'ancien fichier reste à sa place, sans perte.
                backup = nil
            }
        }
        try? manager.removeItem(at: files.migrationMarkerURL)
        return Result(list: list, siteID: id, migratedRecords: records, backupURL: backup)
    }

    /// Notes d'appareils d'avant les sites (notes-appareils.json, communes à tous les réseaux) :
    /// elles deviennent celles du site donné, sauf s'il a déjà les siennes ; l'ancien fichier est
    /// gardé en copie de sécurité. Renvoie vrai si des notes ont été reprises.
    @discardableResult
    public static func migrateDeviceNotes(files: SiteFiles, into key: String) throws -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: files.legacyNotesURL.path) else { return false }
        let target = files.notesURL(for: key)
        var copied = false
        if !manager.fileExists(atPath: target.path) {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: files.legacyNotesURL, to: target)
            copied = true
        }
        if manager.fileExists(atPath: files.legacyNotesBackupURL.path) { try? manager.removeItem(at: files.legacyNotesBackupURL) }
        try manager.moveItem(at: files.legacyNotesURL, to: files.legacyNotesBackupURL)
        return copied
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

    /// Switchs SNMP qu'on peut interroger sans action de l'utilisateur (fin de scan) : jamais un
    /// switch associé à un autre site que le site actif. Sa communauté partirait en clair vers
    /// l'appareil qui porte la même adresse chez ce client. Sans site actif, un switch associé à
    /// un site ne l'est que s'il est dans les plages scannées. Un switch sans site n'est pas écarté ici.
    public static func pollable(_ hosts: [String], activeSite: Site?, sites: [Site], scanRanges: [IPRange]) -> [String] {
        hosts.filter { host in
            let owners = sites.filter { $0.switchHosts.contains(host) }
            guard !owners.isEmpty else { return true }
            if let site = activeSite { return owners.contains { $0.id == site.id } }
            guard let ip = IPv4Address(host), !scanRanges.isEmpty else { return false }
            return ScanRelevance.contains(scanRanges, ip)
        }
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
