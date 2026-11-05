import Foundation
@testable import NetScopeCore

// Tests de la note 56 : export, import (aperçu, fusion par identifiant) et synchronisation de la
// configuration. Données fixes et dossiers temporaires seulement : jamais le vrai iCloud Drive,
// jamais le vrai Trousseau (faux Trousseau en mémoire), aucun accès réseau.

enum ConfigFixtures {
    static let iterations = BackupCrypto.iterationRange.lowerBound
    static let password = "Phrase-De-Passe-Export-56"
    static let syncPassword = "Synchro-Entre-Mes-Mac-56"
    static let fortiToken = "FICTIF-jeton-fgt-siege-71b2"
    static let snmpValue = "FICTIF-communaute-56"
    static let siegeID = UUID(uuidString: "5E1A0000-0000-4000-8000-000000000001")!
    static let lavalID = UUID(uuidString: "5E1A0000-0000-4000-8000-000000000002")!
    static let jumeauID = UUID(uuidString: "5E1A0000-0000-4000-8000-000000000003")!
    static let fgtID = UUID(uuidString: "F0F0F0F0-0000-4000-8000-000000000001")!
    static let exportDate = Date(timeIntervalSince1970: 1_793_000_000)
    static let fortiService = "com.danymenard.netscope.fortigate"

    static func site(_ id: UUID, _ name: String, ranges: [String], fortiGates: [UUID] = [], notes: String = "") -> Site {
        Site(id: id, name: name, notes: notes, ranges: ranges.map { ScanRangeConfig(id: rangeID($0), text: $0, label: "LAN") }, fortiGateIDs: fortiGates,
             created: Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// Identifiant fixe d'une plage (le même site exporté puis relu garde ses plages).
    static func rangeID(_ text: String) -> UUID {
        let hex = Array(ConfigHash.sha256(Data(text.utf8)).prefix(32))
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }

    static func sitesData(_ sites: [Site], active: UUID? = nil) -> Data { SiteList(sites: sites, activeID: active).encoded()! }

    static func controllersData(_ names: [(UUID, String)]) -> Data {
        let list = names.map { ["id": $0.0.uuidString, "site": $0.1, "host": "10.0.0.1", "port": 443, "vdom": "root", "ranges": ["10.0.0.0/24"],
                                "isEnabled": true, "timeout": 10] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
    }

    /// État d'un Mac de démonstration : deux sites, une FortiGate et son jeton, des réglages.
    static func snapshot(modified: Date = Date(timeIntervalSince1970: 1_792_000_000), inventory: String = "{\"fiches\":3}",
                         sites: [Site]? = nil, secrets: [BackupSecret]? = nil) -> ConfigSnapshot {
        let siteList = sites ?? [site(siegeID, "Siège", ranges: ["10.10.0.0/24"], fortiGates: [fgtID]), site(lavalID, "Laval", ranges: ["10.20.0.0/24"])]
        let files = [
            ConfigFile(path: "sites.json", data: sitesData(siteList, active: siegeID), modified: modified),
            ConfigFile(path: "sites/\(siegeID.uuidString)/inventory.json", data: Data(inventory.utf8), modified: modified),
            ConfigFile(path: "sites/\(siegeID.uuidString)/notes-appareils.json", data: Data("{}".utf8), modified: modified),
            ConfigFile(path: "outils.json", data: Data("{\"favoris\":[]}".utf8), modified: modified),
            ConfigFile(path: "identifiants.json", data: Data("[]".utf8), modified: modified),
            ConfigFile(path: "disques-en-cours.json", data: Data("[]".utf8), modified: modified),
        ]
        var preferences: [String: Data] = [:]
        let values: [String: Any] = [
            "NetScope.fortigate.controleurs": controllersData([(fgtID, "Siège")]),
            "reglages.raccourcis": ["scanner": "cmd+r"],
            "reglages.scan.threads": 64,
            "reglages.general.confirmerPlagePublique": true,
            "sauvegarde.dossier": "/Users/essai/Documents",
            "synchro.appareil": "AAAA",
            "NSWindow Frame main": "0 0 100 100",
            "alertes.reglages": Data("{}".utf8),
            "reglages.jeton.test": "jamais",
        ]
        for (key, value) in values { preferences[key] = ConfigPlist.encode(value) }
        let fictive = secrets ?? [
            BackupSecret(service: fortiService, account: fgtID.uuidString, value: Data(fortiToken.utf8), usage: "Jeton FortiGate · Siège"),
            BackupSecret(service: "com.danymenard.netscope.snmp", account: "identifiants", value: Data(snmpValue.utf8), usage: "SNMP"),
            BackupSecret(service: BackupPasswordKeychain.service, account: BackupPasswordKeychain.account, value: Data("jamais-copie".utf8), usage: "Sauvegardes"),
        ]
        return ConfigSnapshot(files: files, preferences: preferences, secrets: fictive, secretNames: fictive.map(\.item))
    }

    static func temporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func contains(_ data: Data, _ text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil || data.range(of: Data(Data(text.utf8).base64EncodedString().utf8)) != nil
    }

    static func engine(_ root: URL, device: String, password: String? = syncPassword) -> ConfigSyncEngine {
        ConfigSyncEngine(root: root, deviceID: device, deviceName: "Mac \(device)", password: password, iterations: iterations)
    }
}

func registerConfigSyncTests(_ suite: TestSuite) {
    typealias F = ConfigFixtures
    let allParts = Set(ConfigPartRegistry.standard.ids)

    suite.add("Configuration : registre des parties (fichiers, préférences, secrets)") {
        let registry = ConfigPartRegistry.standard
        try expectEqual(registry.part(forFile: "sites.json")?.id, "sites", "sites.json")
        try expectEqual(registry.part(forFile: "sites/\(F.siegeID.uuidString)/inventory.json")?.id, "inventaires", "inventaire d’un site")
        try expectEqual(registry.part(forFile: "outils.json")?.id, "reglages", "fourre-tout")
        try expectEqual(registry.part(forFile: "nouveau-module.json")?.id, "reglages", "un fichier inconnu n’est jamais perdu")
        try expect(registry.part(forFile: "disques-en-cours.json") == nil, "travail en cours propre au Mac exclu")
        try expect(registry.part(forFile: "../evasion.json") == nil, "chemin dangereux exclu")
        try expectEqual(registry.part(forPreference: "reglages.scan.threads")?.id, "profils", "profils")
        try expectEqual(registry.part(forPreference: "scan.prereglagePorts")?.id, "sites", "préréglages")
        try expectEqual(registry.part(forPreference: "reglages.raccourcis")?.id, "raccourcis", "raccourcis")
        try expectEqual(registry.part(forPreference: "NetScope.fortigate.controleurs")?.id, "fortigate", "FortiGate")
        try expectEqual(registry.part(forPreference: "NetScope.switchs.hotes")?.id, "switchs", "switchs")
        try expectEqual(registry.part(forPreference: "alertes.reglages")?.id, "alertes", "alertes")
        try expect(registry.part(forPreference: "sauvegarde.dossier") == nil, "réglage de la sauvegarde propre au Mac")
        try expect(registry.part(forPreference: "synchro.appareil") == nil, "réglage de la synchro propre au Mac")
        try expect(registry.part(forPreference: "NSWindow Frame main") == nil, "réglage de macOS exclu")
        try expect(registry.part(forPreference: "reglages.jeton.test") == nil, "préférence au nom de secret exclue")
        try expectEqual(registry.part(forSecret: F.fortiService, account: "x")?.id, "fortigate", "jeton FortiGate")
        try expectEqual(registry.part(forSecret: "com.danymenard.netscope.snmp", account: "communautes-par-hote")?.id, "switchs", "communautés")
        try expectEqual(registry.part(forSecret: "com.danymenard.netscope.ssh", account: "a")?.id, "identifiants", "SSH")
        try expectEqual(registry.part(forSecret: "com.danymenard.netscope.wmi", account: "a")?.id, "identifiants", "WMI")
        try expectEqual(registry.part(forSecret: "com.danymenard.netscope.alertes", account: AlertSecretKey.smtpPassword)?.id, "alertes", "SMTP")
        try expectEqual(registry.part(forSecret: "com.danymenard.netscope.github", account: "jeton")?.id, "reglages", "GitHub")
        try expect(registry.part(forSecret: BackupPasswordKeychain.service, account: BackupPasswordKeychain.account) == nil, "mot de passe des sauvegardes jamais copié")
        try expect(registry.part(forSecret: ConfigSecrets.syncService, account: ConfigSecrets.syncAccount) == nil, "mot de passe de synchro jamais copié")
        try expect(registry.part(forSecret: "com.autre.app", account: "x") == nil, "service étranger refusé")
        // Extensible : une nouvelle partie prend ses fichiers avant le fourre-tout.
        var extended = registry
        extended.register(ConfigPart(id: "nas", title: "Emplacements NAS", detail: "", systemImage: "externaldrive", files: ["emplacements-nas.json"]))
        try expectEqual(extended.part(forFile: "emplacements-nas.json")?.id, "nas", "partie ajoutée")
        try expectEqual(extended.ids.last, "reglages", "le fourre-tout reste en dernier")
    }

    suite.add("Configuration : export sans secret en clair, chiffrement obligatoire avec secrets") {
        let snapshot = F.snapshot()
        try expectThrows(ConfigError.passwordRequired, "secret sans mot de passe") {
            _ = try ConfigArchive.export(snapshot, parts: allParts, password: nil, deviceName: "Mac A", appVersion: "0.18.0", appBuild: "180")
        }
        try expectThrows(ConfigError.nothingSelected, "rien de coché") {
            _ = try ConfigArchive.export(snapshot, parts: [], password: nil, deviceName: "Mac A", appVersion: "0.18.0", appBuild: "180")
        }
        try expect(ConfigArchive.includesSecrets(snapshot, parts: ["fortigate"]), "FortiGate : secrets")
        try expect(!ConfigArchive.includesSecrets(snapshot, parts: ["sites", "profils"]), "sites et profils : aucun secret")
        // Sans les parties à secrets : fichier en clair permis, sans aucun secret.
        let plain = try ConfigArchive.export(snapshot, parts: ["sites", "profils", "raccourcis", "inventaires"], password: nil,
                                             date: F.exportDate, deviceName: "Mac A", appVersion: "0.18.0", appBuild: "180")
        try expect(!ConfigArchive.isEncrypted(plain), "en clair")
        try expect(!F.contains(plain, F.fortiToken) && !F.contains(plain, F.snmpValue), "aucun secret dans un export en clair")
        let package = try ConfigArchive.read(plain, name: "essai", password: nil)
        try expectEqual(Set(package.manifest.parts.map(\.id)), ["sites", "profils", "raccourcis", "inventaires"], "parties exportées")
        try expect(package.files.contains { $0.path == "sites.json" }, "sites.json exporté")
        try expect(!package.files.contains { $0.path == "outils.json" }, "réglages non cochés absents")
        try expect(package.preferences["reglages.scan.threads"] != nil, "profil exporté")
        try expect(package.preferences["sauvegarde.dossier"] == nil, "réglage propre au Mac jamais exporté")
        try expectEqual(package.manifest.deviceName, "Mac A", "nom du Mac")
    }

    suite.add("Configuration : export chiffré (format de la note 38), mauvais mot de passe, intégrité") {
        let snapshot = F.snapshot()
        let sealed = try ConfigArchive.export(snapshot, parts: allParts, password: F.password, date: F.exportDate, deviceName: "Mac A",
                                              appVersion: "0.18.0", appBuild: "180", iterations: F.iterations)
        try expect(ConfigArchive.isEncrypted(sealed), "chiffré")
        try expect(!F.contains(sealed, F.fortiToken) && !F.contains(sealed, "Siège"), "rien de lisible sans le mot de passe")
        let header = try BackupCrypto.header(of: sealed).header
        try expectEqual(header.secretCount, 2, "deux secrets (ni le mot de passe des sauvegardes ni d’un autre service)")
        try expectThrows(BackupCryptoError.passwordRequired, "mot de passe demandé") { _ = try ConfigArchive.read(sealed, name: "x", password: nil) }
        try expectThrows(BackupCryptoError.wrongPassword, "mauvais mot de passe") { _ = try ConfigArchive.read(sealed, name: "x", password: "autre-mot-de-passe") }
        var damaged = sealed
        damaged[damaged.count - 40] ^= 0x01
        try expectThrows(BackupCryptoError.tampered, "octet modifié") { _ = try ConfigArchive.read(damaged, name: "x", password: F.password) }
        let package = try ConfigArchive.read(sealed, name: "x", password: F.password)
        try expectEqual(package.secrets.count, 2, "secrets relus")
        try expect(package.secrets.contains { $0.value == Data(F.fortiToken.utf8) }, "jeton FortiGate relu")
        try expect(!package.secrets.contains { $0.service == BackupPasswordKeychain.service }, "mot de passe des sauvegardes absent")
    }

    suite.add("Configuration : aperçu d’import (ajouté, remplacé, identique, conflit)") {
        let source = F.snapshot(inventory: "{\"fiches\":5}")
        let data = try ConfigArchive.export(source, parts: allParts, password: F.password, date: F.exportDate, deviceName: "Mac A",
                                            appVersion: "0.18.0", appBuild: "180", iterations: F.iterations)
        let package = try ConfigArchive.read(data, name: "x", password: F.password)
        // Ce Mac : Siège identique, Laval absent, un autre site au même nom et aux mêmes plages que Laval
        // (identifiant différent), inventaire du Siège modifié ici APRÈS l'export, pas de jeton.
        let twin = F.site(F.jumeauID, "Laval", ranges: ["10.20.0.0/24"])
        var local = F.snapshot(modified: F.exportDate.addingTimeInterval(3600), inventory: "{\"fiches\":4}",
                               sites: [F.site(F.siegeID, "Siège", ranges: ["10.10.0.0/24"], fortiGates: [F.fgtID]), twin], secrets: [])
        local.preferences["reglages.scan.threads"] = ConfigPlist.encode(32)
        let plan = ConfigImporter.plan(package, local: local)
        func change(_ id: String) -> ConfigChange? { plan.changes.first { $0.id == id } }
        try expectEqual(change("element:sites.json#\(F.siegeID.uuidString)")?.action, .identique, "Siège identique")
        let laval = change("element:sites.json#\(F.lavalID.uuidString)")
        try expectEqual(laval?.action, .ajout, "Laval ajouté, jamais fusionné avec le site aux mêmes plages")
        try expect(laval?.detail?.contains("Laval (2)") == true, "même nom : ajouté sous un nom distinct")
        try expect(laval?.detail?.contains("mêmes plages") == true, "mêmes plages signalées")
        try expectEqual(change("fichier:sites/\(F.siegeID.uuidString)/inventory.json")?.action, .conflit, "inventaire modifié ici après l’export")
        try expectEqual(change("preference:reglages.scan.threads")?.action, .remplacement, "réglage différent remplacé")
        try expectEqual(change("preference:reglages.raccourcis")?.action, .identique, "raccourcis identiques")
        try expectEqual(change("secret:\(F.fortiService)|\(F.fgtID.uuidString)")?.action, .ajout, "jeton ajouté")
        try expectEqual(change("element:NetScope.fortigate.controleurs#\(F.fgtID.uuidString)")?.action, .identique, "FortiGate identique")
        try expect(!plan.defaultSelection.contains("fichier:sites/\(F.siegeID.uuidString)/inventory.json"), "un conflit n’est jamais coché d’office")
        try expect(plan.defaultSelection.contains("element:sites.json#\(F.lavalID.uuidString)"), "ajout coché d’office")
        try expect(plan.parts.first?.id == "sites", "parties dans l’ordre du registre")
    }

    suite.add("Configuration : import appliqué au dossier, sites jamais fusionnés, changement entre-temps protégé") {
        let folder = try F.temporaryFolder("config-import")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Ce Mac : un site « Laval » (autre identifiant, mêmes plages) et un fichier d'outils.
        let twin = F.site(F.jumeauID, "Laval", ranges: ["10.20.0.0/24"])
        try F.sitesData([twin], active: F.jumeauID).write(to: folder.appendingPathComponent("sites.json"))
        try Data("{\"ancien\":true}".utf8).write(to: folder.appendingPathComponent("outils.json"))
        let localPrefs: [String: Any] = ["reglages.scan.threads": 32]
        let local = ConfigSnapshot.read(dataDirectory: folder, preferences: localPrefs)
        let package = try ConfigArchive.read(try ConfigArchive.export(F.snapshot(), parts: allParts, password: F.password, date: Date(),
                                                                      deviceName: "Mac A", appVersion: "0.18.0", appBuild: "180",
                                                                      iterations: F.iterations), name: "x", password: F.password)
        let plan = ConfigImporter.plan(package, local: local)
        let apply = ConfigImporter.resolve(plan, selected: plan.defaultSelection, parts: allParts, local: local)
        try expectEqual(apply.secrets.count, 2, "secrets à remettre au Trousseau")
        let written = try BackupEngine.encoder().encode(apply.withoutSecrets)
        try expect(!F.contains(written, F.fortiToken), "le plan écrit ne garde aucun secret")
        // Une FortiGate déjà là, modifiée ici entre l'aperçu et l'application : non écrasée.
        var prefs = localPrefs
        prefs["NetScope.fortigate.controleurs"] = F.controllersData([(F.fgtID, "Modifiée entre-temps")])
        let outcome = ConfigImporter.apply(apply, to: folder, preferences: prefs)
        try expect(outcome.skipped.contains { $0.contains("FortiGate") }, "FortiGate changée entre-temps : laissée")
        let sites = SiteList.decode(try Data(contentsOf: folder.appendingPathComponent("sites.json")))!
        try expectEqual(sites.sites.count, 3, "deux sites ajoutés à côté du site local")
        try expect(sites.sites.contains { $0.id == F.jumeauID && $0.name == "Laval" }, "site local intact")
        try expect(sites.sites.contains { $0.id == F.lavalID && $0.name == "Laval (2)" }, "site importé au même nom renommé")
        try expectEqual(sites.activeID, F.jumeauID, "site actif de ce Mac gardé")
        try expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sites/\(F.siegeID.uuidString)/inventory.json").path), "inventaire du site importé")
        try expectEqual(try Data(contentsOf: folder.appendingPathComponent("outils.json")), Data("{\"favoris\":[]}".utf8), "fichier remplacé (\(plan.changes.first { $0.id == "fichier:outils.json" }?.action.rawValue ?? "absent") \(outcome.skipped))")
        try expectEqual(outcome.preferences["reglages.scan.threads"].flatMap(ConfigPlist.decode) as? Int, 64, "réglage remplacé")
        try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("disques-en-cours.json").path), "fichier propre au Mac jamais importé")
        // Secrets remis au faux Trousseau.
        let store = MemorySecretStore()
        try expectEqual(BackupEngine.restoreSecrets(apply.secrets, to: store).count, 0, "aucun échec")
        try expectEqual(store.values["\(F.fortiService)|\(F.fgtID.uuidString)"], Data(F.fortiToken.utf8), "jeton au Trousseau de ce Mac")
    }

    suite.add("Configuration : une sauvegarde de NetScope s’importe partie par partie") {
        let folder = try F.temporaryFolder("config-sauvegarde")
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = folder.appendingPathComponent("donnees", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try F.sitesData([F.site(F.siegeID, "Siège", ranges: ["10.10.0.0/24"])]).write(to: data.appendingPathComponent("sites.json"))
        try Data("{}".utf8).write(to: data.appendingPathComponent("surveillance.json"))
        let prefs = try PropertyListSerialization.data(fromPropertyList: ["reglages.raccourcis": ["a": "b"]], format: .binary, options: 0)
        let source = BackupSource(dataDirectory: data, preferences: prefs, keychain: [], appVersion: "0.17.0", appBuild: "170", secrets: [])
        let info = try BackupEngine.create(source, in: folder.appendingPathComponent("sauvegardes"), format: .zip, kind: .manuelle)
        let package = try ConfigArchive.read(info.url, password: nil)
        try expectEqual(package.manifest.origin, "sauvegarde", "origine")
        try expectEqual(Set(package.manifest.parts.map(\.id)), ["sites", "inventaires", "raccourcis"], "parties reconnues")
    }

    suite.add("Synchronisation : un Mac publie, l’autre reçoit ; jetons chiffrés par le mot de passe de synchro") {
        let root = try F.temporaryFolder("synchro")
        defer { try? FileManager.default.removeItem(at: root) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        let reportA = try a.sync(sites: [F.siegeID], snapshot: F.snapshot(), state: &stateA, now: F.exportDate)
        try expect(!reportA.sent.isEmpty && reportA.received.isEmpty, "A publie")
        let raw = try Data(contentsOf: a.bundleURL(site: F.siegeID, device: "A"))
        try expect(!F.contains(raw, F.fortiToken), "le jeton n’est jamais en clair dans iCloud Drive")
        try expect(!F.contains(raw, "Laval"), "jamais un autre site dans le dossier du Siège")
        // B n'a aucun site : il voit le Siège disponible, puis le reçoit en entier.
        let empty = ConfigSnapshot(files: [], preferences: [:])
        try expectEqual(b.availableSites(excluding: []).map(\.id), [F.siegeID], "site disponible")
        let reportB = try b.sync(sites: [F.siegeID], snapshot: empty, state: &stateB, now: F.exportDate.addingTimeInterval(60))
        try expect(reportB.plan.elements.contains { $0.collection == "sites.json" && $0.id == F.siegeID.uuidString }, "fiche du site reçue")
        try expect(reportB.plan.elements.contains { $0.collection == "NetScope.fortigate.controleurs" }, "FortiGate reçue")
        try expect(reportB.plan.files.contains { $0.path.hasSuffix("inventory.json") }, "inventaire reçu")
        try expectEqual(reportB.plan.secrets.first?.value, Data(F.fortiToken.utf8), "jeton reçu (déchiffré)")
        try expect(!reportB.plan.files.contains { $0.path == "outils.json" }, "seulement ce qui appartient au site")
        // Mauvais mot de passe sur un troisième Mac : signalé, jeton non reçu.
        var stateC = ConfigSyncState()
        let c = F.engine(root, device: "C", password: "pas-le-bon-mot-de-passe")
        let reportC = try c.sync(sites: [F.siegeID], snapshot: empty, state: &stateC, now: F.exportDate.addingTimeInterval(90))
        try expect(reportC.plan.secrets.isEmpty && reportC.errors.contains { $0.contains("différent") }, "mot de passe différent signalé")
        // Sans mot de passe : secrets ignorés, signalé.
        var stateD = ConfigSyncState()
        let reportD = try F.engine(root, device: "D", password: nil).sync(sites: [F.siegeID], snapshot: empty, state: &stateD, now: F.exportDate)
        try expect(reportD.secretsSkipped && reportD.plan.secrets.isEmpty, "sans mot de passe : jetons non synchronisés")
    }

    suite.add("Synchronisation : changement d’un seul côté reçu, conflit gardé et signalé") {
        let root = try F.temporaryFolder("synchro-conflit")
        defer { try? FileManager.default.removeItem(at: root) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        let t0 = F.exportDate
        let base = F.snapshot(modified: t0)
        _ = try a.sync(sites: [F.siegeID], snapshot: base, state: &stateA, now: t0)
        _ = try b.sync(sites: [F.siegeID], snapshot: base, state: &stateB, now: t0.addingTimeInterval(10))
        // A modifie l'inventaire ; B n'a rien changé : B reçoit, sans conflit.
        let changedA = F.snapshot(modified: t0.addingTimeInterval(100), inventory: "{\"fiches\":7}")
        let sentA = try a.sync(sites: [F.siegeID], snapshot: changedA, state: &stateA, now: t0.addingTimeInterval(110))
        try expect(sentA.sent.contains { $0.label.contains("nventaire") }, "A envoie son inventaire")
        let gotB = try b.sync(sites: [F.siegeID], snapshot: base, state: &stateB, now: t0.addingTimeInterval(120))
        try expectEqual(gotB.plan.files.first { $0.path.hasSuffix("inventory.json") }?.data, Data("{\"fiches\":7}".utf8), "B reçoit la version de A")
        try expect(gotB.conflicts.isEmpty, "aucun conflit")
        // Les deux modifient : la plus récente l'emporte, l'autre est gardée et signalée.
        let laterA = F.snapshot(modified: t0.addingTimeInterval(200), inventory: "{\"fiches\":8}")
        _ = try a.sync(sites: [F.siegeID], snapshot: laterA, state: &stateA, now: t0.addingTimeInterval(210))
        let laterB = F.snapshot(modified: t0.addingTimeInterval(300), inventory: "{\"fiches\":9}")
        let conflictB = try b.sync(sites: [F.siegeID], snapshot: laterB, state: &stateB, now: t0.addingTimeInterval(310))
        let conflict = conflictB.conflicts.first { $0.key.hasSuffix("inventory.json") }
        try expect(conflict != nil, "conflit signalé")
        try expectEqual(conflict?.keptRemote, false, "la version de B, plus récente, est gardée")
        try expectEqual(conflict?.otherData, Data("{\"fiches\":8}".utf8), "la version de A est gardée pour la rétablir")
        try expect(!conflictB.plan.files.contains { $0.path.hasSuffix("inventory.json") }, "rien n’est écrasé ici")
        try expectEqual(stateB.conflicts.first?.id, conflict?.id, "conflit retenu dans l’état")
        // A, plus ancien, reçoit la version de B et garde la sienne en conflit.
        let conflictA = try a.sync(sites: [F.siegeID], snapshot: laterA, state: &stateA, now: t0.addingTimeInterval(400))
        try expectEqual(conflictA.plan.files.first { $0.path.hasSuffix("inventory.json") }?.data, Data("{\"fiches\":9}".utf8), "A reçoit la plus récente")
        try expect(conflictA.conflicts.isEmpty, "A n’avait rien changé depuis sa synchro : pas de second conflit")
        // Rétablir l'autre version : un plan pour ce seul fichier.
        let restore = ConfigSyncEngine.restorePlan(conflict!, snapshot: laterB)
        try expectEqual(restore?.files.first?.data, Data("{\"fiches\":8}".utf8), "version écartée rétablie")
    }

    suite.add("Synchronisation : rétablir une version garde les changements reçus en attente") {
        let root = try F.temporaryFolder("synchro-restaurer")
        let folder = try F.temporaryFolder("synchro-restaurer-donnees")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: folder) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        let t0 = F.exportDate
        let base = F.snapshot(modified: t0)
        for file in base.files {
            let url = folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
        _ = try a.sync(sites: [F.siegeID], snapshot: base, state: &stateA, now: t0)
        _ = try b.sync(sites: [F.siegeID], snapshot: base, state: &stateB, now: t0.addingTimeInterval(10))
        // B reçoit l'inventaire modifié par A : il attend le redémarrage.
        let changedA = F.snapshot(modified: t0.addingTimeInterval(100), inventory: "{\"fiches\":7}")
        _ = try a.sync(sites: [F.siegeID], snapshot: changedA, state: &stateA, now: t0.addingTimeInterval(110))
        let received = try b.sync(sites: [F.siegeID], snapshot: base, state: &stateB, now: t0.addingTimeInterval(120)).plan.withoutSecrets
        try expect(received.files.contains { $0.path.hasSuffix("inventory.json") }, "inventaire reçu, en attente")
        // Puis l'utilisateur rétablit une autre version (outils.json) : elle s'ajoute au plan en attente.
        let conflict = ConfigSyncConflict(date: t0, siteID: F.siegeID, siteName: "Siège", key: "fichier:outils.json", label: "Outils",
                                          keptDevice: "Mac B", keptModified: t0, otherDevice: "Mac A", otherModified: t0,
                                          otherData: Data("{\"favoris\":[\"ping\"]}".utf8), keptRemote: false)
        guard let restore = ConfigSyncEngine.restorePlan(conflict, snapshot: base) else { throw TestFailure(message: "plan de restauration absent", file: #fileID, line: #line) }
        let merged = received.merging(restore)
        try expectEqual(merged.operationCount, received.operationCount + 1, "rien de reçu n’est perdu")
        try expectEqual(received.merging(restore).merging(restore).operationCount, merged.operationCount, "même clé : remplacée, pas doublée")
        let outcome = ConfigImporter.apply(merged, to: folder, preferences: [:])
        try expect(outcome.failed.isEmpty, "aucun échec")
        let inventory = try Data(contentsOf: folder.appendingPathComponent("sites/\(F.siegeID.uuidString)/inventory.json"))
        try expectEqual(inventory, Data("{\"fiches\":7}".utf8), "l’élément reçu est appliqué")
        try expectEqual(try Data(contentsOf: folder.appendingPathComponent("outils.json")), Data("{\"favoris\":[\"ping\"]}".utf8), "la version rétablie aussi")
    }

    suite.add("Synchronisation : identifiants des sites, suppression signalée, rien hors du dossier") {
        let root = try F.temporaryFolder("synchro-sites")
        defer { try? FileManager.default.removeItem(at: root) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        // B a un site « Siège » aux mêmes plages mais d'identifiant différent : jamais fusionné.
        let other = F.site(F.jumeauID, "Siège", ranges: ["10.10.0.0/24"])
        let snapshotB = F.snapshot(sites: [other], secrets: [])
        _ = try a.sync(sites: [F.siegeID], snapshot: F.snapshot(), state: &stateA, now: F.exportDate)
        let reportB = try b.sync(sites: [F.jumeauID], snapshot: snapshotB, state: &stateB, now: F.exportDate.addingTimeInterval(5))
        try expect(reportB.received.isEmpty, "rien reçu pour un autre identifiant")
        try expectEqual(b.availableSites(excluding: [F.jumeauID]).map(\.id), [F.siegeID], "le Siège de A reste un site distinct")
        // Un fichier fabriqué qui vise un autre site est refusé.
        var forged = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: a.bundleURL(site: F.siegeID, device: "A")))
        forged.deviceID = "Z"
        forged.updated = F.exportDate.addingTimeInterval(500)
        forged.items.append(ConfigSyncItem(key: "fichier:outils.json", label: "outils", modified: F.exportDate.addingTimeInterval(500),
                                           hash: "x", data: Data("{}".utf8)))
        try BackupEngine.encoder().encode(forged).write(to: a.bundleURL(site: F.siegeID, device: "Z"))
        var stateE = ConfigSyncState()
        let reportE = try F.engine(root, device: "E").sync(sites: [F.siegeID], snapshot: ConfigSnapshot(), state: &stateE, now: F.exportDate.addingTimeInterval(600))
        try expect(!reportE.plan.files.contains { $0.path == "outils.json" }, "fichier hors du dossier du site refusé")
        try expect(reportE.errors.contains { $0.contains("refusé") }, "refus signalé")
        // A supprime le Siège : B (qui l'a reçu) voit la suppression signalée, rien n'est retiré.
        var stateB2 = ConfigSyncState()
        _ = try b.sync(sites: [F.siegeID], snapshot: F.snapshot(), state: &stateB2, now: F.exportDate.addingTimeInterval(700))
        try FileManager.default.removeItem(at: a.bundleURL(site: F.siegeID, device: "Z"))
        let without = F.snapshot(sites: [F.site(F.lavalID, "Laval", ranges: ["10.20.0.0/24"])])
        _ = try a.sync(sites: [F.siegeID], snapshot: without, state: &stateA, now: F.exportDate.addingTimeInterval(800))
        let afterDelete = try b.sync(sites: [F.siegeID], snapshot: F.snapshot(), state: &stateB2, now: F.exportDate.addingTimeInterval(900))
        try expect(afterDelete.deletions.contains { $0.device == "Mac A" }, "suppression sur A signalée")
        try expect(afterDelete.plan.isEmpty, "jamais appliquée d’office")
    }

    suite.add("Synchronisation : rien ne change, rien n’est réécrit ; état relu tel quel") {
        let root = try F.temporaryFolder("synchro-calme")
        defer { try? FileManager.default.removeItem(at: root) }
        var state = ConfigSyncState()
        let a = F.engine(root, device: "A")
        _ = try a.sync(sites: [F.siegeID], snapshot: F.snapshot(), state: &state, now: F.exportDate)
        let url = a.bundleURL(site: F.siegeID, device: "A")
        let first = try Data(contentsOf: url)
        let quiet = try a.sync(sites: [F.siegeID], snapshot: F.snapshot(), state: &state, now: F.exportDate.addingTimeInterval(60))
        try expect(quiet.isQuiet, "rien à faire (\(quiet.sent.map(\.label)) \(quiet.received.map(\.label)) \(quiet.errors))")
        try expectEqual(try Data(contentsOf: url), first, "fichier non réécrit")
        let stateURL = root.appendingPathComponent(".etat/synchro.json")
        try ConfigSyncEngine.saveState(state, to: stateURL)
        try expectEqual(ConfigSyncEngine.loadState(from: stateURL), state, "état relu")
    }
}
