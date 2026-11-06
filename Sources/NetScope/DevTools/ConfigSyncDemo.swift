import Foundation
import NetScopeCore

/// Démonstration de la note 56 (export, import et synchronisation de la configuration) : contenu
/// de ce Mac par partie, aperçu d'un import fictif (calculé par le vrai moteur sur des données
/// fixes) et état de synchronisation fictif. Rien n'est lu ni écrit : ni fichier, ni iCloud Drive,
/// ni Trousseau ; uniquement des valeurs fictives.
@MainActor
enum ConfigSyncDemo {
    static let deviceName = "MacBook Pro de Dany"
    static let deviceModel = "MacBook Pro (14 pouces, 2023)"
    /// Note 86 : les deux autres Mac de la démonstration de la synchronisation.
    static let studioDevice = "Mac Studio de Dany"
    static let officeDevice = "Mac du bureau"
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

    // MARK: Synchronisation (notes 56 et 86)

    /// Captures : NETSCOPE_REGLAGES_SECTION=synchronisation ouvre Réglages › Synchronisation.
    struct SyncState {
        var enabled: Bool
        var excludedSites: Set<UUID>
        var disabledCategories: Set<String>
        var lastSync: Date
        var conflicts: [ConfigSyncConflict]
        var deletions: [ConfigSyncDeletion]
        var recent: [ConfigSyncChange]
        var devices: [ConfigSyncDevice]
        var counts: [ConfigSyncGlobal.CategoryCount]
        var remoteSites: [ConfigSyncRemoteSite]
        var pendingCount: Int
        var summary: String
    }

    /// Version mineure précédant celle de l'app (« 0.29.0 » → « 0.28.0 ») : le Mac du bureau reste
    /// toujours une version derrière, quelle que soit la version construite.
    static func previousVersion(_ version: String) -> String {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2, parts[1] > 0 else { return "0.28.0" }
        return "\(parts[0]).\(parts[1] - 1).0"
    }

    /// Trois Mac (ce MacBook Pro, le Mac Studio et le Mac du bureau resté une version derrière), un conflit
    /// sur une connexion du carnet, une sonde supprimée sur le Mac Studio à confirmer.
    static func state() -> SyncState {
        let now = Date()
        let version = UpdController.currentVersionText
        let devices = [
            ConfigSyncDevice(id: "demo-macbook", name: deviceName, model: deviceModel, appVersion: version, lastSync: now.addingTimeInterval(-40)),
            ConfigSyncDevice(id: "demo-studio", name: studioDevice, model: "Mac Studio (2023)", appVersion: version,
                             lastSync: now.addingTimeInterval(-3 * 60)),
            ConfigSyncDevice(id: "demo-bureau", name: officeDevice, model: "iMac (24 pouces, 2021)", appVersion: previousVersion(version), schema: nil,
                             lastSync: now.addingTimeInterval(-2 * 3_600 - 14 * 60)),
        ]
        let routeur = Data(#"{"host":"10.182.122.1","id":"9C1A0000-0000-4000-8000-000000000001","name":"Routeur du Siège","port":22,"protocol":"ssh","user":"admin"}"#.utf8)
        let conflict = ConfigSyncConflict(id: UUID(uuidString: "C0F1C700-0000-4000-8000-000000000086")!, date: now.addingTimeInterval(-6 * 60),
                                          siteID: ConfigSyncPolicy.globalID, siteName: "Accès distant et RustDesk",
                                          key: "element:connexions.json#connections#9C1A0000-0000-4000-8000-000000000001",
                                          label: "Connexion «\u{00A0}Routeur du Siège\u{00A0}»", keptDevice: studioDevice,
                                          keptModified: now.addingTimeInterval(-12 * 60), otherDevice: deviceName,
                                          otherModified: now.addingTimeInterval(-18 * 60), otherData: routeur, keptRemote: true)
        let deletion = ConfigSyncDeletion(scope: ConfigSyncPolicy.globalFolder, scopeName: "Surveillance et rapports planifiés",
                                          key: "element:surveillance.json#probes#5D0E0000-0000-4000-8000-000000000007",
                                          label: "Sonde «\u{00A0}Imprimante de l’accueil\u{00A0}»", category: "surveillance",
                                          device: studioDevice, date: now.addingTimeInterval(-25 * 60))
        func change(_ minutes: Double, _ scope: String, _ label: String, _ category: String, _ device: String) -> ConfigSyncChange {
            ConfigSyncChange(date: now.addingTimeInterval(-minutes * 60), scopeName: scope, label: label, category: category, device: device)
        }
        let recent = [
            change(4, "Accès distant et RustDesk", "Connexion «\u{00A0}NAS Synology\u{00A0}»", "acces", studioDevice),
            change(4, "Accès distant et RustDesk", "Mot de passe Telnet · SW-ETG2-01", "acces", studioDevice),
            change(9, "Surveillance et rapports planifiés", "Sonde «\u{00A0}Passerelle Laval\u{00A0}»", "surveillance", studioDevice),
            change(22, "Entrepôt Laval", "Inventaire", "inventaires", studioDevice),
            change(31, "Profils de scan", "Profil de scan · fils", "profils", studioDevice),
            change(134, "Clinique Exemple", "Fiche du site", "sites", officeDevice),
            change(186, "Surveillance et rapports planifiés", "Rapport planifié «\u{00A0}Bilan mensuel\u{00A0}»", "surveillance", officeDevice),
        ]
        let registry = ConfigPartRegistry.standard
        func count(_ id: String, files: Int = 0, elements: Int = 0, preferences: Int = 0, secrets: Int = 0, sites: Int = 0) -> ConfigSyncGlobal.CategoryCount? {
            registry.part(id).map { ConfigSyncGlobal.CategoryCount(part: $0, files: files, elements: elements, preferences: preferences, secrets: secrets, siteItems: sites) }
        }
        let counts = [
            count("sites", preferences: 4, sites: 6),
            count("fortigate", preferences: 2, secrets: 4, sites: 4),
            count("switchs", preferences: 5, secrets: 3),
            count("identifiants", files: 2, elements: 6, secrets: 6),
            count("acces", files: 3, elements: 38, preferences: 2, secrets: 14),
            count("alertes", preferences: 2, secrets: 5),
            count("surveillance", files: 2, elements: 21, preferences: 6),
            count("raccourcis", preferences: 1),
            count("profils", preferences: 6),
            count("inventaires", files: 3, elements: 64, sites: 14),
            count("reglages", files: 5, preferences: 27, secrets: 2),
        ].compactMap { $0 }
        let remote = ConfigSyncRemoteSite(id: levisID, name: "Clinique Exemple · Lévis", devices: [officeDevice], updated: now.addingTimeInterval(-3 * 3_600))
        return SyncState(enabled: true, excludedSites: [SitesDemo.drummondID], disabledCategories: ["raccourcis"],
                         lastSync: now.addingTimeInterval(-40), conflicts: [conflict], deletions: [deletion], recent: recent,
                         devices: devices, counts: counts, remoteSites: [remote], pendingCount: 0,
                         summary: "3 reçus de \(studioDevice) · 2 envoyés · 1 conflit · 1 suppression à confirmer")
    }
}
