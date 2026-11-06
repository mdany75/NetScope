import Foundation
@testable import NetScopeCore

// Tests de la note 86 : synchronisation complète des données entre les Mac. Données fixes et
// dossiers temporaires seulement : jamais le vrai dossier iCloud Drive, jamais le vrai Trousseau,
// aucun accès réseau.

enum SyncFullFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_794_000_000)
    static let accesService = "com.danymenard.netscope.acces"
    static let accesPassword = "FICTIF-mot-de-passe-telnet-86"

    static func connections(_ list: [(String, String)]) -> Data {
        let array = list.map { ["id": $0.0, "name": $0.1, "host": "10.0.0.\(abs($0.0.hashValue) % 200 + 1)", "protocol": "ssh"] }
        return try! JSONSerialization.data(withJSONObject: ["version": 1, "connections": array], options: [.sortedKeys])
    }

    static let surveillance: Data = {
        let object: [String: Any] = [
            "version": 3,
            "probes": [["id": "P1", "name": "Passerelle", "target": "10.0.0.1"]],
            "trackers": ["P1": ["etat": "en ligne", "depuis": "propre à ce Mac"]],
            "history": ["P1": [1, 2, 3]],
            "journal": ["entries": []],
            "planning": ["windows": []],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }()

    /// État d'un Mac : carnet d'Accès distant, Surveillance, Boîte à outils, réglages, et des
    /// fichiers ou réglages propres au Mac qui ne doivent jamais partir.
    static func snapshot(connections list: [(String, String)] = [("C1", "Routeur"), ("C2", "NAS")], modified: Date = t0,
                         threads: Int = 64, secrets: [BackupSecret] = [], extraFiles: [ConfigFile] = []) -> ConfigSnapshot {
        var files = [
            ConfigFile(path: "connexions.json", data: connections(list), modified: modified),
            ConfigFile(path: "surveillance.json", data: surveillance, modified: t0),
            ConfigFile(path: "outils.json", data: Data("{\"favoris\":[\"ping\"]}".utf8), modified: t0),
            ConfigFile(path: "etat.json", data: Data("{\"ranges\":[]}".utf8), modified: t0),
            ConfigFile(path: "wifi-signal.json", data: Data("{\"echantillons\":[1,2,3]}".utf8), modified: t0),
            ConfigFile(path: "disques-en-cours.json", data: Data("[]".utf8), modified: t0),
        ]
        files += extraFiles
        var preferences: [String: Data] = [:]
        let values: [String: Any] = [
            "reglages.scan.threads": threads,
            "reglages.raccourcis": ["scanner": "cmd+r"],
            "NetScope.switchs.onglet": "ports",
            "NSWindow Frame main": "0 0 100 100",
            "synchro.appareil": "AAAA",
            "NetScope.fortigate.controleurs": Data("[]".utf8),
        ]
        for (key, value) in values { preferences[key] = ConfigPlist.encode(value) }
        return ConfigSnapshot(files: files, preferences: preferences, secrets: secrets, secretNames: secrets.map(\.item))
    }

    static func engine(_ root: URL, device: String, version: String = "0.29.0", password: String? = ConfigFixtures.syncPassword,
                       disabled: Set<String> = []) -> ConfigSyncEngine {
        var engine = ConfigSyncEngine(root: root, deviceID: device, deviceName: "Mac \(device)", password: password, iterations: ConfigFixtures.iterations)
        engine.appVersion = version
        engine.deviceModel = "Mac Studio"
        engine.disabledCategories = disabled
        return engine
    }

    /// Écrit les fichiers d'un état dans un dossier de données temporaire.
    static func write(_ snapshot: ConfigSnapshot, to folder: URL) throws {
        for file in snapshot.files {
            let url = folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
    }

    static func names(in data: Data) -> [String: String] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let list = object?["connections"] as? [[String: Any]] ?? []
        var result: [String: String] = [:]
        for item in list { if let id = item["id"] as? String { result[id] = item["name"] as? String } }
        return result
    }
}

func registerConfigSyncFullTests(_ suite: TestSuite) {
    typealias F = SyncFullFixtures
    typealias C = ConfigFixtures

    suite.add("Synchronisation complète : classement des fichiers et réglages (synchronisés ou propres au Mac)") {
        let global = ConfigSyncGlobal.make(snapshot: F.snapshot())
        let keys = Set(global.items.keys)
        try expect(keys.contains("element:connexions.json#connections#C1"), "une connexion par élément")
        try expect(keys.contains("doc:connexions.json"), "reste du carnet")
        try expect(keys.contains("element:surveillance.json#probes#P1"), "une sonde par élément")
        try expect(keys.contains("fichier:outils.json"), "fichier entier")
        try expect(keys.contains("preference:reglages.scan.threads"), "profil de scan")
        try expect(keys.contains("preference:reglages.raccourcis"), "raccourcis")
        for local in ["fichier:etat.json", "fichier:wifi-signal.json", "fichier:disques-en-cours.json", "preference:NetScope.switchs.onglet",
                      "preference:NSWindow Frame main", "preference:synchro.appareil", "preference:NetScope.fortigate.controleurs"] {
            try expect(!keys.contains(local), "\(local) reste sur ce Mac")
        }
        let rest = try JSONSerialization.jsonObject(with: global.items["doc:surveillance.json"]!.data) as? [String: Any]
        try expect(rest?["trackers"] == nil && rest?["history"] == nil && rest?["journal"] == nil, "états, historique et journal de ce Mac jamais envoyés")
        try expect(rest?["planning"] != nil, "fenêtres de maintenance synchronisées")
        try expectEqual(ConfigSyncGlobal.category(forKey: "element:connexions.json#connections#C1"), "acces", "catégorie Accès distant")
        try expectEqual(ConfigSyncGlobal.category(forKey: "element:surveillance.json#probes#P1"), "surveillance", "catégorie Surveillance")
        try expectEqual(ConfigSyncGlobal.category(forKey: "secret:\(F.accesService)|C1"), "acces", "mot de passe d’Accès distant")
        try expect(ConfigSyncGlobal.category(forKey: "secret:\(C.fortiService)|x") == nil, "jeton FortiGate : avec son site, jamais global")
        try expect(ConfigSyncGlobal.category(forKey: "secret:\(ConfigSecrets.syncService)|\(ConfigSecrets.syncAccount)") == nil, "mot de passe de synchro jamais copié")
        try expect(ConfigSyncPolicy.localReason(forFile: "sites/\(C.siegeID.uuidString)/wifi-signal.json") != nil, "signal par seconde d’un site : propre au Mac")
        try expect(ConfigSyncPolicy.siteFiles.contains(SiteFiles.resultsName), "derniers résultats synchronisés avec le site")
    }

    suite.add("Synchronisation complète : deux Mac changent deux connexions différentes, fusion sans conflit") {
        let root = try C.temporaryFolder("synchro-global")
        let dataB = try C.temporaryFolder("synchro-global-b")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: dataB) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA, now: F.t0)
        let first = try b.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(10))
        try expect(first.conflicts.isEmpty && first.plan.isEmpty, "mêmes données : rien à faire")
        try expect(FileManager.default.fileExists(atPath: a.globalBundleURL(device: "A").path), "dossier _global")
        // A renomme C1, B renomme C2.
        let t1 = F.t0.addingTimeInterval(100)
        let snapA = F.snapshot(connections: [("C1", "Routeur du Siège"), ("C2", "NAS")], modified: t1)
        let snapB = F.snapshot(connections: [("C1", "Routeur"), ("C2", "NAS de sauvegarde")], modified: t1)
        try F.write(snapB, to: dataB)
        _ = try a.sync(sites: [], global: true, snapshot: snapA, state: &stateA, now: t1.addingTimeInterval(5))
        let gotB = try b.sync(sites: [], global: true, snapshot: snapB, state: &stateB, now: t1.addingTimeInterval(10))
        try expect(gotB.conflicts.isEmpty, "deux éléments différents : aucun conflit")
        try expectEqual(gotB.plan.documents.map(\.id), ["C1"], "B reçoit seulement C1")
        try expect(gotB.received.allSatisfy { $0.category == "acces" }, "catégorie du changement reçu")
        let outcome = ConfigImporter.apply(gotB.plan, to: dataB, preferences: [:])
        try expect(outcome.failed.isEmpty && outcome.skipped.isEmpty, "appliqué (\(outcome.failed) \(outcome.skipped))")
        let merged = F.names(in: try Data(contentsOf: dataB.appendingPathComponent("connexions.json")))
        try expectEqual(merged, ["C1": "Routeur du Siège", "C2": "NAS de sauvegarde"], "les deux changements réunis sur B")
        let gotA = try a.sync(sites: [], global: true, snapshot: snapA, state: &stateA, now: t1.addingTimeInterval(20))
        try expectEqual(gotA.plan.documents.map(\.id), ["C2"], "A reçoit C2")
        try expect(gotA.conflicts.isEmpty, "toujours aucun conflit")
        try expect(stateB.recent.contains { $0.device == "Mac A" }, "changement reçu retenu pour le tableau")
    }

    suite.add("Synchronisation complète : même élément changé sur deux Mac = conflit, la version écartée se rétablit") {
        let root = try C.temporaryFolder("synchro-global-conflit")
        defer { try? FileManager.default.removeItem(at: root) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA, now: F.t0)
        _ = try b.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(10))
        let snapA = F.snapshot(connections: [("C1", "Version A"), ("C2", "NAS")], modified: F.t0.addingTimeInterval(200))
        let snapB = F.snapshot(connections: [("C1", "Version B"), ("C2", "NAS")], modified: F.t0.addingTimeInterval(300))
        _ = try a.sync(sites: [], global: true, snapshot: snapA, state: &stateA, now: F.t0.addingTimeInterval(210))
        let report = try b.sync(sites: [], global: true, snapshot: snapB, state: &stateB, now: F.t0.addingTimeInterval(310))
        let conflict = report.conflicts.first { $0.key == "element:connexions.json#connections#C1" }
        try expect(conflict != nil, "conflit signalé")
        try expectEqual(conflict?.keptRemote, false, "la plus récente (B) est gardée")
        try expect(conflict?.isGlobal == true && conflict?.siteName == "Accès distant et RustDesk", "conflit rangé dans sa catégorie")
        try expect(report.plan.documents.isEmpty, "rien n’est écrasé ici")
        let restore = ConfigSyncEngine.restorePlan(conflict!, snapshot: snapB)
        try expectEqual(restore?.documents.first?.id, "C1", "la version de A peut être rétablie")
        let folder = try C.temporaryFolder("synchro-global-conflit-donnees")
        defer { try? FileManager.default.removeItem(at: folder) }
        try F.write(snapB, to: folder)
        _ = ConfigImporter.apply(restore!, to: folder, preferences: [:])
        try expectEqual(F.names(in: try Data(contentsOf: folder.appendingPathComponent("connexions.json")))["C1"], "Version A", "version de A rétablie")
        // Réglage changé des deux côtés : même règle.
        let prefsA = F.snapshot(connections: [("C1", "Version A"), ("C2", "NAS")], modified: F.t0.addingTimeInterval(200), threads: 32)
        _ = try a.sync(sites: [], global: true, snapshot: prefsA, state: &stateA, now: F.t0.addingTimeInterval(400))
        let prefReport = try b.sync(sites: [], global: true, snapshot: snapB, state: &stateB, now: F.t0.addingTimeInterval(410))
        try expect(prefReport.plan.preferences.contains { $0.key == "reglages.scan.threads" }, "réglage changé sur A reçu par B")
    }

    suite.add("Synchronisation complète : suppression faite sur un autre Mac signalée, appliquée seulement si confirmée") {
        let root = try C.temporaryFolder("synchro-suppression")
        let dataB = try C.temporaryFolder("synchro-suppression-b")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: dataB) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA, now: F.t0)
        _ = try b.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(10))
        // A retire le NAS de son carnet.
        let withoutNAS = F.snapshot(connections: [("C1", "Routeur")], modified: F.t0.addingTimeInterval(100))
        _ = try a.sync(sites: [], global: true, snapshot: withoutNAS, state: &stateA, now: F.t0.addingTimeInterval(110))
        let raw = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: a.globalBundleURL(device: "A")))
        try expect(raw.removed?["element:connexions.json#connections#C2"] != nil, "pierre tombale publiée")
        let report = try b.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(120))
        let deletion = report.pendingDeletions.first
        try expectEqual(deletion?.device, "Mac A", "suppression signalée")
        try expectEqual(deletion?.label, "Connexion «\u{00A0}NAS\u{00A0}»", "libellé de l’élément")
        try expect(report.plan.isEmpty, "jamais appliquée d’office")
        try expectEqual(stateB.pendingDeletions.map(\.id), [deletion!.id], "retenue jusqu’à la réponse")
        // Seconde lecture : pas signalée deux fois.
        let again = try b.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(130))
        try expect(again.pendingDeletions.isEmpty, "une seule fois")
        // Confirmée : le NAS est retiré du fichier de B, puis rien ne revient.
        try F.write(F.snapshot(), to: dataB)
        let plan = ConfigSyncEngine.deletionPlan(deletion!, snapshot: F.snapshot())
        try expect(plan != nil, "plan de suppression")
        let outcome = ConfigImporter.apply(plan!, to: dataB, preferences: [:])
        try expect(outcome.failed.isEmpty && outcome.skipped.isEmpty, "suppression appliquée")
        try expectEqual(F.names(in: try Data(contentsOf: dataB.appendingPathComponent("connexions.json"))), ["C1": "Routeur"], "NAS retiré sur B")
        stateB.pendingDeletions.removeAll()
        let after = try b.sync(sites: [], global: true, snapshot: withoutNAS, state: &stateB, now: F.t0.addingTimeInterval(140))
        try expect(after.plan.isEmpty && after.pendingDeletions.isEmpty, "rien ne revient")
        let backA = try a.sync(sites: [], global: true, snapshot: withoutNAS, state: &stateA, now: F.t0.addingTimeInterval(150))
        try expect(!backA.plan.documents.contains { $0.id == "C2" }, "le NAS ne revient pas sur A")
        // Refusée sur un troisième Mac (« Garder sur ce Mac ») : plus signalée.
        var stateC = ConfigSyncState()
        let c = F.engine(root, device: "C")
        _ = try c.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateC, now: F.t0.addingTimeInterval(5))
        let seenC = try c.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateC, now: F.t0.addingTimeInterval(160))
        guard let pending = seenC.pendingDeletions.first else { throw TestFailure(message: "suppression non signalée sur C", file: #fileID, line: #line) }
        stateC.pendingDeletions.removeAll()
        stateC.dismissed[pending.id] = pending.date
        let quietC = try c.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateC, now: F.t0.addingTimeInterval(170))
        try expect(quietC.pendingDeletions.isEmpty, "refus retenu")
    }

    suite.add("Synchronisation complète : secrets chiffrés aller-retour, jamais en clair dans le dossier") {
        let root = try C.temporaryFolder("synchro-secrets")
        defer { try? FileManager.default.removeItem(at: root) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let secrets = [
            BackupSecret(service: F.accesService, account: "C1", value: Data(F.accesPassword.utf8), usage: "Telnet · Routeur"),
            BackupSecret(service: C.fortiService, account: "fgt", value: Data(C.fortiToken.utf8), usage: "Jeton FortiGate"),
            BackupSecret(service: ConfigSecrets.syncService, account: ConfigSecrets.syncAccount, value: Data("jamais".utf8), usage: "Synchro"),
        ]
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(secrets: secrets), state: &stateA, now: F.t0)
        let raw = try Data(contentsOf: a.globalBundleURL(device: "A"))
        try expect(!C.contains(raw, F.accesPassword), "mot de passe jamais en clair")
        let bundle = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: raw)
        try expectEqual(bundle.secretCount, 1, "seul le mot de passe d’Accès distant va dans le global")
        let report = try b.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(10))
        try expectEqual(report.plan.secrets.map(\.value), [Data(F.accesPassword.utf8)], "déchiffré sur l’autre Mac")
        let store = MemorySecretStore()
        try expectEqual(BackupEngine.restoreSecrets(report.plan.secrets, to: store).count, 0, "remis au Trousseau")
        try expectEqual(store.values["\(F.accesService)|C1"], Data(F.accesPassword.utf8), "valeur au Trousseau de l’autre Mac")
        try expect(!report.plan.withoutSecrets.documents.isEmpty || report.plan.withoutSecrets.secrets.isEmpty, "le plan écrit sur le disque n’a aucun secret")
        // Mot de passe différent : signalé, rien reçu.
        var stateD = ConfigSyncState()
        let d = F.engine(root, device: "D", password: "un-autre-mot-de-passe-86")
        let wrong = try d.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateD, now: F.t0.addingTimeInterval(20))
        try expect(wrong.plan.secrets.isEmpty && wrong.errors.contains { $0.contains("différent") }, "mot de passe différent signalé")
    }

    suite.add("Synchronisation complète : catégories décochées ni écrites ni reçues") {
        let root = try C.temporaryFolder("synchro-categories")
        defer { try? FileManager.default.removeItem(at: root) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B", disabled: ["acces"])
        _ = try b.sync(sites: [], global: true, snapshot: F.snapshot(connections: [("C9", "Poste de B")]), state: &stateB, now: F.t0)
        let rawB = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: b.globalBundleURL(device: "B")))
        try expect(!rawB.items.contains { $0.key.contains("connexions.json") }, "carnet de B jamais écrit")
        try expect(rawB.items.contains { $0.key == "fichier:outils.json" }, "les autres catégories le sont")
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA, now: F.t0.addingTimeInterval(10))
        let gotB = try b.sync(sites: [], global: true, snapshot: F.snapshot(connections: [("C9", "Poste de B")]), state: &stateB, now: F.t0.addingTimeInterval(20))
        try expect(!gotB.plan.documents.contains { $0.path == "connexions.json" }, "carnet de A jamais reçu par B")
        try expect(gotB.pendingDeletions.isEmpty && (stateB.sites[ConfigSyncPolicy.globalFolder]?.removed.isEmpty ?? true), "aucune suppression inventée")
        // Une catégorie décochée après coup ne publie pas de suppression.
        var stateA2 = stateA
        let a2 = F.engine(root, device: "A", disabled: ["acces"])
        _ = try a2.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA2, now: F.t0.addingTimeInterval(30))
        let rawA = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: a.globalBundleURL(device: "A")))
        try expect(rawA.removed == nil, "décocher n’est pas supprimer")
        // Toutes les catégories des sites décochées : aucun dossier de site écrit.
        var stateS = ConfigSyncState()
        let s = F.engine(root, device: "S", disabled: ConfigSyncPolicy.siteCategories)
        _ = try s.sync(sites: [C.siegeID], global: true, snapshot: C.snapshot(), state: &stateS, now: F.t0)
        try expect(!FileManager.default.fileExists(atPath: s.bundleURL(site: C.siegeID, device: "S").path), "sites décochés")
        // « Sites » seule décochée : inventaires et FortiGate voyagent encore, sans la fiche du site.
        var stateT = ConfigSyncState()
        let t = F.engine(root, device: "T", disabled: ["sites"])
        _ = try t.sync(sites: [C.siegeID], global: true, snapshot: C.snapshot(), state: &stateT, now: F.t0)
        let rawT = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: t.bundleURL(site: C.siegeID, device: "T")))
        try expect(!rawT.items.contains { $0.key == "site" }, "fiche du site jamais écrite")
        try expect(rawT.items.contains { $0.key.hasPrefix("fortigate:") || $0.key.hasPrefix("fichier:") }, "inventaires et FortiGate écrits")
    }

    suite.add("Synchronisation complète : ancien format relu (état, plan en attente, fichiers de la 0.28)") {
        let oldState = Data("""
        {"conflicts":[],"lastSync":"2026-11-01T10:00:00Z","sites":{"\(C.siegeID.uuidString)":{"items":{"site":{"hash":"abc","modified":"2026-11-01T10:00:00Z","synced":"abc"}},"secrets":{},"lastSync":"2026-11-01T10:00:00Z","published":"x"}}}
        """.utf8)
        let state = try BackupEngine.decoder().decode(ConfigSyncState.self, from: oldState)
        try expectEqual(state.sites[C.siegeID.uuidString]?.items["site"]?.synced, "abc", "état de la 0.28 relu")
        try expect(state.pendingDeletions.isEmpty && state.recent.isEmpty, "champs nouveaux vides")
        let oldPlan = Data("""
        {"origin":"synchro","createdAt":"2026-11-01T10:00:00Z","files":[],"preferences":[],"elements":[],"secrets":[]}
        """.utf8)
        let plan = try BackupEngine.decoder().decode(ConfigApplyPlan.self, from: oldPlan)
        try expect(plan.documents.isEmpty && plan.isEmpty, "plan en attente de la 0.28 relu")
        // Fichier d'un site publié par la 0.28 (sans schéma) : lu et reçu.
        let root = try C.temporaryFolder("synchro-ancien")
        defer { try? FileManager.default.removeItem(at: root) }
        var oldA = ConfigSyncState()
        let legacy = C.engine(root, device: "A")
        _ = try legacy.sync(sites: [C.siegeID], snapshot: C.snapshot(), state: &oldA, now: F.t0)
        var bundle = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: legacy.bundleURL(site: C.siegeID, device: "A")))
        bundle.schema = nil
        bundle.appVersion = nil
        bundle.deviceModel = nil
        bundle.signature = nil
        bundle.signatureIterations = nil
        try BackupEngine.encoder().encode(bundle).write(to: legacy.bundleURL(site: C.siegeID, device: "A"))
        var stateB = ConfigSyncState()
        let report = try F.engine(root, device: "B").sync(sites: [C.siegeID], global: true, snapshot: ConfigSnapshot(), state: &stateB, now: F.t0.addingTimeInterval(10))
        try expect(report.plan.elements.contains { $0.collection == "sites.json" }, "site de la 0.28 reçu")
        try expectEqual(report.olderDevices.map(\.name), ["Mac A"], "Mac plus ancien signalé")
        try expectEqual(stateB.devices.first { $0.id == "A" }?.versionLabel, "0.28 ou plus ancienne", "version inconnue affichée")
        // Les fichiers nouveaux restent lisibles par la 0.28 : format 1, dossiers _global et _appareils ignorés.
        let fresh = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: F.engine(root, device: "B").bundleURL(site: C.siegeID, device: "B")))
        try expectEqual(fresh.version, 1, "format des sites inchangé")
        try expectEqual(legacy.availableSites(excluding: [C.siegeID]).count, 0, "_global et _appareils ne sont pas des sites")
    }

    suite.add("Synchronisation complète : un Mac plus ancien n’efface jamais un champ qu’il ne connaît pas") {
        let root = try C.temporaryFolder("synchro-plus-ancien")
        let folder = try C.temporaryFolder("synchro-plus-ancien-donnees")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: folder) }
        var stateB = ConfigSyncState()
        let b = F.engine(root, device: "B")
        let mine = C.snapshot()
        try F.write(mine, to: folder)
        _ = try b.sync(sites: [C.siegeID], global: true, snapshot: mine, state: &stateB, now: F.t0)
        // Le Mac « O » (0.28) renvoie la fiche du Siège sans le champ « fortiGateIDs » qu'il ne connaît pas.
        let element = ConfigCollection.sites.elements(of: mine.collectionData(.sites)!)!.first { $0.id == C.siegeID.uuidString }!
        var object = try JSONSerialization.jsonObject(with: element.canonical) as! [String: Any]
        object.removeValue(forKey: "fortiGateIDs")
        object["name"] = "Siège social"
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let old = ConfigSyncBundle(siteID: C.siegeID, siteName: "Siège social", deviceID: "O", deviceName: "Mac du bureau", updated: F.t0.addingTimeInterval(50),
                                   items: [ConfigSyncItem(key: "site", label: "Fiche du site", modified: F.t0.addingTimeInterval(50),
                                                          hash: ConfigHash.sha256(data), data: data)], schema: nil)
        try BackupEngine.encoder().encode(old).write(to: b.bundleURL(site: C.siegeID, device: "O"))
        let report = try b.sync(sites: [C.siegeID], global: true, snapshot: mine, state: &stateB, now: F.t0.addingTimeInterval(60))
        try expectEqual(report.olderDevices.map(\.name), ["Mac du bureau"], "« Mac du bureau utilise une version plus ancienne »")
        let op = report.plan.elements.first { $0.collection == "sites.json" }
        try expectEqual(op?.preserveUnknown, true, "reçu d’un Mac plus ancien : superposé")
        _ = ConfigImporter.apply(report.plan, to: folder, preferences: [:])
        let list = SiteList.decode(try Data(contentsOf: folder.appendingPathComponent("sites.json")))
        let site = list?.site(C.siegeID)
        try expectEqual(site?.name, "Siège social", "le nom changé arrive")
        try expectEqual(site?.fortiGateIDs, [C.fgtID], "la FortiGate du site n’est pas perdue")
        // Fichier découpé : un élément d'un Mac plus ancien garde les champs d'ici.
        let local = Data("{\"connections\":[{\"id\":\"C1\",\"name\":\"Routeur\",\"jumpHost\":\"bastion\"}]}".utf8)
        let op2 = ConfigApplyPlan.DocumentOp(path: "connexions.json", arrayKey: "connections", idField: "id", id: "C1",
                                             json: Data("{\"id\":\"C1\",\"name\":\"Routeur 2\"}".utf8), expected: nil, label: "C1", preserveUnknown: true)
        let composed = ConfigSyncDocument.apply([op2], to: local, rule: ConfigSyncPolicy.rule(for: "connexions.json")).data!
        let first = ((try JSONSerialization.jsonObject(with: composed) as? [String: Any])?["connections"] as? [[String: Any]])?.first
        try expect(first?["name"] as? String == "Routeur 2" && first?["jumpHost"] as? String == "bastion", "champ inconnu de l’autre version gardé")
    }

    suite.add("Synchronisation complète : réception d’un fichier découpé, clés propres au Mac gardées") {
        let rule = ConfigSyncPolicy.rule(for: "surveillance.json")!
        let parts = ConfigSyncDocument.split(F.surveillance, path: "surveillance.json", rule: rule)!
        try expectEqual(Set(parts.map(\.key)), ["doc:surveillance.json", "element:surveillance.json#probes#P1"], "reste et une sonde")
        let remote = Data("{\"planning\":{\"windows\":[\"nuit\"]},\"version\":3}".utf8)
        let ops = [
            ConfigApplyPlan.DocumentOp(path: "surveillance.json", json: remote, expected: nil, label: "Surveillance", preserve: rule.preservedKeys),
            ConfigApplyPlan.DocumentOp(path: "surveillance.json", arrayKey: "probes", idField: "id", id: "P2",
                                       json: Data("{\"id\":\"P2\",\"name\":\"DNS\"}".utf8), expected: nil, label: "Sonde DNS"),
        ]
        let result = ConfigSyncDocument.apply(ops, to: F.surveillance, rule: rule)
        let object = try JSONSerialization.jsonObject(with: result.data!) as? [String: Any]
        try expect((object?["trackers"] as? [String: Any])?["P1"] != nil, "états des sondes de ce Mac gardés")
        try expect(object?["history"] != nil && object?["journal"] != nil, "historique et journal gardés")
        try expectEqual(((object?["planning"] as? [String: Any])?["windows"] as? [String]) ?? [], ["nuit"], "fenêtres reçues")
        try expectEqual((object?["probes"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? [], ["P1", "P2"], "sonde ajoutée")
        // Fiches des Mac : nom, modèle, version.
        let root = try C.temporaryFolder("synchro-appareils")
        defer { try? FileManager.default.removeItem(at: root) }
        var state = ConfigSyncState()
        _ = try F.engine(root, device: "A").sync(sites: [], global: true, snapshot: F.snapshot(), state: &state, now: F.t0)
        var stateB = ConfigSyncState()
        _ = try F.engine(root, device: "B", version: "0.29.0").sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(5))
        let devices = F.engine(root, device: "A").devices(now: F.t0.addingTimeInterval(10))
        try expectEqual(devices.map(\.name), ["Mac A", "Mac B"], "ce Mac d’abord, puis les autres")
        try expectEqual(devices.last?.model, "Mac Studio", "modèle publié")
        try expect(!F.engine(root, device: "A").isOlder(devices.last!), "même version : pas d’avertissement")
    }
}
