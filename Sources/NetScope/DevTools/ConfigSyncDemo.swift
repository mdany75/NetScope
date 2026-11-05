import Foundation
import NetScopeCore

/// Démonstration de la note 56 (export, import et synchronisation de la configuration) : contenu
/// de ce Mac par partie, aperçu d'un import fictif (calculé par le vrai moteur sur des données
/// fixes) et état de synchronisation fictif. Rien n'est lu ni écrit : ni fichier, ni iCloud Drive,
/// ni Trousseau ; uniquement des valeurs fictives.
@MainActor
enum ConfigSyncDemo {
    static let deviceName = "MacBook Pro (démonstration)"
    static let otherDevice = "MacBook Air de l’atelier"
    static let thirdDevice = "iMac du bureau"
    /// Site publié par un autre Mac, absent de ce Mac.
    static let levisID = UUID(uuidString: "5A7E0028-0006-4C1E-9A11-00000000A006")!

    static var now: Date { Date() }

    /// Captures : NETSCOPE_CONFIG_FEUILLE=exporter|importer|motdepasse dessine la feuille dans la page.
    static var snapshotSheet: String? {
        guard RegEnvironment.isSnapshot else { return nil }
        return ProcessInfo.processInfo.environment["NETSCOPE_CONFIG_FEUILLE"]
    }

    /// Captures : NETSCOPE_REGLAGES_SECTION=configuration place les panneaux de la note 56 en haut.
    static var focusOnConfiguration: Bool {
        RegEnvironment.isSnapshot && ProcessInfo.processInfo.environment["NETSCOPE_REGLAGES_SECTION"] == "configuration"
    }

    // MARK: Données fixes

    private static let fictive = Data("valeur fictive de démonstration".utf8)

    private static func json(_ text: String, size: Int) -> Data {
        var data = Data(text.utf8)
        if data.count < size { data.append(Data(repeating: 0x20, count: size - data.count)) }
        return data
    }

    private static func controllersData(_ controllers: [FortiGateController]) -> Data {
        FortiControllerList.encode(controllers) ?? Data("[]".utf8)
    }

    /// État de ce Mac (démonstration).
    static func localSnapshot() -> ConfigSnapshot {
        let base = baseList()
        let now = Date()
        var local = base
        // Ce Mac n'a pas encore l'usine de Drummondville ; l'inventaire de Laval y a changé il y a une heure.
        local.sites.removeAll { $0.id == SitesDemo.drummondID }
        let old = now.addingTimeInterval(-9 * 86_400)
        var files = commonFiles(modified: old)
        files.append(ConfigFile(path: SiteFiles.listName, data: local.encoded() ?? Data(), modified: old))
        files.append(ConfigFile(path: "sites/\(SitesDemo.lavalID.uuidString)/inventory.json", data: json("{\"fiches\":41}", size: 38_200),
                                modified: now.addingTimeInterval(-3_600)))
        files.append(ConfigFile(path: "surveillance.json", data: json("{\"sondes\":11}", size: 48_000), modified: old))
        var preferences: [String: Data] = [:]
        let controllers = Array(FortiGateSitesDemo.controllers(now: now).prefix(3))
        let values: [String: Any] = ["reglages.scan.threads": 64, "alertes.reglages": Data("{}".utf8),
                                     "NetScope.fortigate.controleurs": controllersData(controllers),
                                     "reglages.general.confirmerPlagePublique": true]
        for (key, value) in values { preferences[key] = ConfigPlist.encode(value) }
        let names = ReglagesDemo.encryptedSecrets.filter { !$0.usage.contains("Drummondville") }.map(\.item)
        return ConfigSnapshot(files: files, preferences: preferences, secrets: [], secretNames: names)
    }

    /// Export reçu d'un autre Mac (démonstration).
    static func exportedSnapshot() -> ConfigSnapshot {
        let now = Date()
        var list = baseList()
        if let index = list.index(of: SitesDemo.siegeID) { list.sites[index].notes = "Bureaux, entrepôt, salle des serveurs et nouvel étage." }
        if let index = list.index(of: SitesDemo.cliniqueID) { list.sites[index].notes = "Client fictif\u{00A0}; deux nouveaux postes." }
        // Même nom et mêmes plages que la clinique, autre identifiant : jamais fusionnée.
        list.sites.append(Site(id: levisID, name: "Clinique Exemple", notes: "Succursale de Lévis.",
                               ranges: list.site(SitesDemo.cliniqueID)?.ranges ?? [], created: now.addingTimeInterval(-20 * 86_400)))
        let exported = now.addingTimeInterval(-2 * 86_400)
        var files = commonFiles(modified: exported)
        files.append(ConfigFile(path: SiteFiles.listName, data: list.encoded() ?? Data(), modified: exported))
        files.append(ConfigFile(path: "sites/\(SitesDemo.lavalID.uuidString)/inventory.json", data: json("{\"fiches\":39}", size: 37_400), modified: exported))
        files.append(ConfigFile(path: "sites/\(SitesDemo.drummondID.uuidString)/inventory.json", data: json("{\"fiches\":64}", size: 52_100), modified: exported))
        files.append(ConfigFile(path: "surveillance.json", data: json("{\"sondes\":14}", size: 51_000), modified: exported))
        var preferences: [String: Data] = [:]
        let values: [String: Any] = ["reglages.scan.threads": 96, "reglages.raccourcis": ["scanner": "⌘R", "ping": "⌘⇧P"],
                                     "alertes.reglages": Data("{}".utf8),
                                     "NetScope.fortigate.controleurs": controllersData(FortiGateSitesDemo.controllers(now: now)),
                                     "reglages.general.confirmerPlagePublique": true]
        for (key, value) in values { preferences[key] = ConfigPlist.encode(value) }
        let secrets = ReglagesDemo.encryptedSecrets.map { secret -> BackupSecret in
            var copy = secret
            copy.value = fictive
            return copy
        }
        return ConfigSnapshot(files: files, preferences: preferences, secrets: secrets, secretNames: secrets.map(\.item))
    }

    /// Liste des sites commune aux deux Mac (plages aux mêmes identifiants).
    private static let baseListValue: SiteList = SitesDemo.list(now: Date(timeIntervalSince1970: 1_793_000_000))
    private static func baseList() -> SiteList { baseListValue }

    private static func commonFiles(modified: Date) -> [ConfigFile] {
        [ConfigFile(path: "outils.json", data: json("{\"favoris\":[]}", size: 6_310), modified: modified),
         ConfigFile(path: "identifiants.json", data: json("[]", size: 1_128), modified: modified),
         ConfigFile(path: "services-en-ligne.json", data: json("{}", size: 3_877), modified: modified)]
    }

    /// Aperçu de l'import fictif, calculé par le vrai moteur.
    static func importPlan() -> ConfigImportPlan {
        let exported = exportedSnapshot()
        let date = Date().addingTimeInterval(-2 * 86_400)
        let parts = ConfigArchive.contents(of: exported).filter { !$0.isEmpty }.map { contents in
            ConfigManifest.Part(id: contents.part.id, title: contents.part.title, files: [], preferences: contents.preferences, secrets: contents.secrets)
        }
        let manifest = ConfigManifest(createdAt: date, deviceName: otherDevice, appVersion: "0.18.0", appBuild: "180", parts: parts, encrypted: true)
        let package = ConfigPackage(manifest: manifest, files: exported.files, preferences: exported.preferences, secrets: exported.secrets)
        return ConfigImporter.plan(package, local: localSnapshot())
    }

    /// Contenu de ce Mac, partie par partie (feuille d'export).
    static func exportContents() -> [ConfigPartContents] {
        var snapshot = exportedSnapshot()
        snapshot.preferences["reglages.scan.delaiMs"] = ConfigPlist.encode(250)
        snapshot.preferences["NetScope.switchs.hotes"] = ConfigPlist.encode(["10.182.122.2", "10.182.122.3"])
        snapshot.preferences["reglages.notifications"] = ConfigPlist.encode(Data("{}".utf8))
        snapshot.files.append(ConfigFile(path: "sites/\(SitesDemo.siegeID.uuidString)/notes-appareils.json", data: json("{}", size: 1_942)))
        snapshot.files.append(ConfigFile(path: "disques.json", data: json("[]", size: 4_506)))
        return ConfigArchive.contents(of: snapshot)
    }

    // MARK: Synchronisation

    struct SyncState {
        var enabled: Bool
        var siteIDs: Set<UUID>
        var lastSync: Date
        var conflicts: [ConfigSyncConflict]
        var remoteSites: [ConfigSyncRemoteSite]
        var pendingCount: Int
        var summary: String
    }

    static func state() -> SyncState {
        let now = Date()
        let conflict = ConfigSyncConflict(id: UUID(uuidString: "C0F1C700-0000-4000-8000-000000000001")!, date: now.addingTimeInterval(-4 * 60),
                                          siteID: SitesDemo.lavalID, siteName: "Entrepôt Laval", key: "fichier:sites/\(SitesDemo.lavalID.uuidString)/inventory.json",
                                          label: "Inventaire", keptDevice: otherDevice, keptModified: now.addingTimeInterval(-38 * 60),
                                          otherDevice: deviceName, otherModified: now.addingTimeInterval(-52 * 60),
                                          otherData: Data("{}".utf8), keptRemote: true)
        let remote = ConfigSyncRemoteSite(id: levisID, name: "Clinique Exemple · Lévis", devices: [thirdDevice], updated: now.addingTimeInterval(-3 * 3_600))
        return SyncState(enabled: true, siteIDs: [SitesDemo.siegeID, SitesDemo.lavalID, SitesDemo.quebecID],
                         lastSync: now.addingTimeInterval(-4 * 60), conflicts: [conflict], remoteSites: [remote], pendingCount: 0,
                         summary: "3 reçus de \(otherDevice) · 2 envoyés · 1 conflit")
    }
}
