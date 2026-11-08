import Foundation
@testable import NetScopeCore

// Tests des corrections de la relecture de la synchronisation (0.29.0) : préférences des mises à
// jour propres au Mac, suppressions à trois Mac, suppressions caduques, historiques élagués,
// pierres tombales éteintes, signature des fichiers, dossier partagé sans mot de passe, jetons
// FortiGate d'un autre site, dossier choisi absent. Dossiers temporaires seulement, aucun réseau.

func registerConfigSyncReviewTests(_ suite: TestSuite) {
    typealias F = SyncFullFixtures
    typealias C = ConfigFixtures
    let c2 = "element:connexions.json#connections#C2"

    suite.add("Synchronisation (relecture) : l’autre Mac en retard n’annule pas une modification déjà publiée") {
        let root = try C.temporaryFolder("synchro-retard")
        defer { try? FileManager.default.removeItem(at: root) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        let key = "NetScope.switchs.ignores"
        var old = F.snapshot()
        old.preferences[key] = ConfigPlist.encode(["10.0.0.9"])
        var new = F.snapshot()
        new.preferences[key] = ConfigPlist.encode([String]())
        func item(_ state: ConfigSyncState) -> ConfigSyncState.Item? { state.sites[ConfigSyncPolicy.globalFolder]?.items["preference:" + key] }
        _ = try a.sync(sites: [], global: true, snapshot: old, state: &stateA, now: F.t0)
        _ = try b.sync(sites: [], global: true, snapshot: old, state: &stateB, now: F.t0.addingTimeInterval(10))
        let oldHash = item(stateA)?.hash

        // A modifie : deux passages de suite, B n'ayant toujours pas republié entre les deux.
        let t1 = F.t0.addingTimeInterval(100)
        _ = try a.sync(sites: [], global: true, snapshot: new, state: &stateA, now: t1)
        let second = try a.sync(sites: [], global: true, snapshot: new, state: &stateA, now: t1.addingTimeInterval(8))
        try expect(!second.plan.preferences.contains { $0.key == key }, "la version périmée de B n’est pas appliquée")
        try expect(item(stateA)?.hash != oldHash, "A garde sa modification")

        // B finit par la recevoir, et le changement suivant de B repart bien vers A.
        let got = try b.sync(sites: [], global: true, snapshot: old, state: &stateB, now: t1.addingTimeInterval(20))
        try expect(got.plan.preferences.contains { $0.key == key }, "B reçoit la modification de A")
        _ = try b.sync(sites: [], global: true, snapshot: new, state: &stateB, now: t1.addingTimeInterval(25))
        let t2 = t1.addingTimeInterval(100)
        var later = F.snapshot()
        later.preferences[key] = ConfigPlist.encode(["10.0.0.7"])
        _ = try b.sync(sites: [], global: true, snapshot: later, state: &stateB, now: t2)
        let back = try a.sync(sites: [], global: true, snapshot: new, state: &stateA, now: t2.addingTimeInterval(10))
        try expect(back.plan.preferences.contains { $0.key == key }, "une vraie modification ultérieure de B arrive bien sur A")

        // Même règle pour les jetons.
        let siteRoot = try C.temporaryFolder("synchro-retard-jeton")
        defer { try? FileManager.default.removeItem(at: siteRoot) }
        var jetonA = ConfigSyncState(), jetonB = ConfigSyncState()
        let ja = C.engine(siteRoot, device: "A"), jb = C.engine(siteRoot, device: "B")
        let secret = { (value: String) in [BackupSecret(service: C.fortiService, account: C.fgtID.uuidString, value: Data(value.utf8), usage: "Jeton FortiGate · Siège")] }
        _ = try ja.sync(sites: [C.siegeID], snapshot: C.snapshot(secrets: secret("FICTIF-ancien")), state: &jetonA, now: F.t0)
        _ = try jb.sync(sites: [C.siegeID], snapshot: C.snapshot(secrets: secret("FICTIF-ancien")), state: &jetonB, now: F.t0.addingTimeInterval(10))
        _ = try ja.sync(sites: [C.siegeID], snapshot: C.snapshot(secrets: secret("FICTIF-nouveau")), state: &jetonA, now: t1)
        let jeton = try ja.sync(sites: [C.siegeID], snapshot: C.snapshot(secrets: secret("FICTIF-nouveau")), state: &jetonA, now: t1.addingTimeInterval(8))
        try expect(jeton.plan.secrets.isEmpty, "l’ancien jeton de B n’écrase pas le nouveau")
        try expect(jeton.conflicts.isEmpty, "aucun conflit annoncé à tort")
        let recu = try jb.sync(sites: [C.siegeID], snapshot: C.snapshot(secrets: secret("FICTIF-ancien")), state: &jetonB, now: t1.addingTimeInterval(20))
        try expect(recu.plan.secrets.contains { $0.value == Data("FICTIF-nouveau".utf8) }, "B reçoit le nouveau jeton")
    }

    suite.add("Synchronisation (relecture) : préférences des mises à jour propres à ce Mac") {
        try expect(!ConfigSyncPolicy.isGlobalPreference("reglages.majs.preferences"), "dernière vérification et versions installées : jamais envoyées")
        try expect(!ConfigSyncPolicy.isGlobalPreference("reglages.majs.versionSignalee"), "version signalée : propre à ce Mac")
        try expect(ConfigSyncPolicy.isGlobalPreference("reglages.raccourcis"), "les autres réglages voyagent encore")
    }

    suite.add("Synchronisation (relecture) : trois Mac, une suppression se propage, puis devient caduque") {
        let root = try C.temporaryFolder("synchro-trois-mac")
        defer { try? FileManager.default.removeItem(at: root) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState(), stateC = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B"), c = F.engine(root, device: "C")
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA, now: F.t0)
        _ = try b.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(10))
        _ = try c.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateC, now: F.t0.addingTimeInterval(20))
        // B retire C2.
        let t1 = F.t0.addingTimeInterval(100)
        _ = try b.sync(sites: [], global: true, snapshot: F.snapshot(connections: [("C1", "Routeur")], modified: t1), state: &stateB, now: t1)
        let gotA = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA, now: t1.addingTimeInterval(10))
        try expect(gotA.pendingDeletions.contains { $0.key == c2 }, "A voit la suppression de B, même si C publie encore C2")
        let gotC = try c.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateC, now: t1.addingTimeInterval(20))
        try expect(gotC.pendingDeletions.contains { $0.key == c2 }, "C aussi")
        try expectEqual(gotA.pendingDeletions.filter { $0.key == c2 }.count, 1, "une seule fois dans le bilan")
        // C change C2 : la suppression en attente sur A devient caduque.
        let t2 = t1.addingTimeInterval(100)
        _ = try c.sync(sites: [], global: true, snapshot: F.snapshot(connections: [("C1", "Routeur"), ("C2", "NAS renommé")], modified: t2),
                       state: &stateC, now: t2)
        let again = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA, now: t2.addingTimeInterval(10))
        try expect(again.plan.documents.contains { $0.id == "C2" }, "A reçoit la version de C")
        try expect(!stateA.pendingDeletions.contains { $0.key == c2 }, "suppression oubliée : l’élément a changé depuis")
        // Plan de suppression : l'empreinte attendue est la base, jamais la version courante.
        let deletion = ConfigSyncDeletion(scope: ConfigSyncPolicy.globalFolder, scopeName: "Accès distant", key: c2, label: "C2",
                                          category: "acces", device: "Mac B", date: t1)
        let plan = ConfigSyncEngine.deletionPlan(deletion, snapshot: F.snapshot(), base: "empreinte-de-base")
        try expectEqual(plan?.documents.first?.expected, "empreinte-de-base", "retrait seulement si rien n’a changé depuis")
        let gone = ConfigSyncEngine.deletionPlan(deletion, snapshot: F.snapshot(connections: [("C1", "Routeur")]))
        try expect(gone != nil && gone!.isEmpty, "déjà absent ici : rien à faire, la demande s’efface")
    }

    suite.add("Synchronisation (relecture) : historiques élagués et réglages retirés jamais signalés") {
        let root = try C.temporaryFolder("synchro-elagage")
        defer { try? FileManager.default.removeItem(at: root) }
        func speed(_ ids: [String]) -> ConfigFile {
            let records = ids.map { ["id": $0, "server": "Montréal"] }
            return ConfigFile(path: "speedtest.json", data: try! JSONSerialization.data(withJSONObject: ["records": records], options: [.sortedKeys]),
                              modified: F.t0)
        }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(extraFiles: [speed(["R1", "R2"])]), state: &stateA, now: F.t0)
        _ = try b.sync(sites: [], global: true, snapshot: F.snapshot(extraFiles: [speed(["R1", "R2"])]), state: &stateB, now: F.t0.addingTimeInterval(10))
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(extraFiles: [speed(["R2"])]), state: &stateA, now: F.t0.addingTimeInterval(20))
        let raw = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: a.globalBundleURL(device: "A")))
        try expect(raw.removed?["element:speedtest.json#records#R1"] == nil, "mesure élaguée : aucune pierre tombale")
        let gotB = try b.sync(sites: [], global: true, snapshot: F.snapshot(extraFiles: [speed(["R1", "R2"])]), state: &stateB, now: F.t0.addingTimeInterval(30))
        try expect(gotB.pendingDeletions.isEmpty, "rien à confirmer sur B")
        try expect(!ConfigSyncPolicy.signalsRemoval(ofKey: "preference:reglages.raccourcis"), "réglage retiré : jamais signalé")
        try expect(!ConfigSyncPolicy.signalsRemoval(ofKey: "fortigate:x"), "FortiGate : suit la fiche de son site")
        try expect(!ConfigSyncPolicy.signalsRemoval(ofKey: "element:rustdesk.json#history#L1"), "historique RustDesk borné")
        try expect(ConfigSyncPolicy.signalsRemoval(ofKey: c2), "une connexion retirée l’est toujours")
    }

    suite.add("Synchronisation (relecture) : une pierre tombale s’éteint après 180 jours, sans renaître") {
        let root = try C.temporaryFolder("synchro-pierre-tombale")
        defer { try? FileManager.default.removeItem(at: root) }
        var state = ConfigSyncState()
        let a = F.engine(root, device: "A")
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &state, now: F.t0)
        let without = F.snapshot(connections: [("C1", "Routeur")])
        _ = try a.sync(sites: [], global: true, snapshot: without, state: &state, now: F.t0.addingTimeInterval(10))
        try expect(state.sites[ConfigSyncPolicy.globalFolder]?.removed[c2] != nil, "pierre tombale publiée")
        let later = F.t0.addingTimeInterval(181 * 86_400)
        _ = try a.sync(sites: [], global: true, snapshot: without, state: &state, now: later)
        _ = try a.sync(sites: [], global: true, snapshot: without, state: &state, now: later.addingTimeInterval(10))
        try expect(state.sites[ConfigSyncPolicy.globalFolder]?.removed[c2] == nil, "éteinte")
        try expect(state.sites[ConfigSyncPolicy.globalFolder]?.items[c2] == nil, "élément oublié de l’état : pas de pierre tombale neuve")
    }

    suite.add("Synchronisation (relecture) : fichiers signés, faux fichier refusé, dossier partagé sans mot de passe") {
        let root = try C.temporaryFolder("synchro-signature")
        defer { try? FileManager.default.removeItem(at: root) }
        var stateA = ConfigSyncState(), stateB = ConfigSyncState()
        let a = F.engine(root, device: "A"), b = F.engine(root, device: "B")
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA, now: F.t0)
        let signed = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: a.globalBundleURL(device: "A")))
        try expect(signed.signature != nil, "fichier signé avec le mot de passe de synchronisation")
        // Écrit avant le mot de passe et sans changement depuis : signé au passage suivant.
        var unsigned = signed
        unsigned.signature = nil
        unsigned.signatureIterations = nil
        try BackupEngine.encoder().encode(unsigned).write(to: a.globalBundleURL(device: "A"), options: .atomic)
        _ = try a.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateA, now: F.t0)
        let resigned = try BackupEngine.decoder().decode(ConfigSyncBundle.self, from: Data(contentsOf: a.globalBundleURL(device: "A")))
        try expect(resigned.signature != nil, "fichier resté sans signature : réécrit même sans changement")
        // Un fichier déposé par un tiers (sans le mot de passe) : refusé, signalé.
        var forged = signed
        forged.deviceID = "Z"
        forged.deviceName = "Intrus"
        forged.signature = nil
        forged.updated = F.t0.addingTimeInterval(50)
        let hostile = F.connections([("C1", "Routeur"), ("C2", "NAS"), ("C66", "Hôte piégé")])
        forged.items = ConfigSyncGlobal.make(snapshot: ConfigSnapshot(files: [ConfigFile(path: "connexions.json", data: hostile, modified: F.t0.addingTimeInterval(50))],
                                                                      preferences: [:])).items.map { key, item in
            ConfigSyncItem(key: key, label: item.label, modified: F.t0.addingTimeInterval(50), hash: item.hash, data: item.data)
        }
        try BackupEngine.encoder().encode(forged).write(to: a.globalBundleURL(device: "Z"))
        let gotB = try b.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(60))
        try expect(!gotB.plan.documents.contains { $0.id == "C66" }, "connexion du faux fichier jamais reçue")
        try expect(gotB.errors.contains { $0.contains("Intrus") && $0.contains("refusés") }, "refus signalé")
        // Signature altérée (contenu changé après coup) : refusée aussi.
        var altered = signed
        altered.deviceID = "Y"
        altered.deviceName = "Copie altérée"
        try BackupEngine.encoder().encode(altered).write(to: a.globalBundleURL(device: "Y"))
        let gotB2 = try b.sync(sites: [], global: true, snapshot: F.snapshot(), state: &stateB, now: F.t0.addingTimeInterval(70))
        try expect(gotB2.errors.contains { $0.contains("Copie altérée") }, "signature d’un autre Mac : refusée")
        // Sans mot de passe, dans un dossier partagé autre qu'iCloud Drive : catégories sensibles ignorées.
        let shared = try C.temporaryFolder("synchro-partage")
        defer { try? FileManager.default.removeItem(at: shared) }
        var stateN1 = ConfigSyncState(), stateN2 = ConfigSyncState()
        let n1 = F.engine(shared, device: "N1", password: nil)
        var n2 = F.engine(shared, device: "N2", password: nil)
        n2.untrustedFolder = true
        var tools = F.snapshot(connections: [("C7", "Poste")])
        tools.files = tools.files.map { $0.path == "outils.json" ? ConfigFile(path: "outils.json", data: Data("{\"favoris\":[\"mtr\"]}".utf8), modified: F.t0) : $0 }
        _ = try n1.sync(sites: [], global: true, snapshot: tools, state: &stateN1, now: F.t0)
        var withoutTools = F.snapshot()
        withoutTools.files.removeAll { $0.path == "outils.json" }
        let gotN2 = try n2.sync(sites: [], global: true, snapshot: withoutTools, state: &stateN2, now: F.t0.addingTimeInterval(10))
        try expect(!gotN2.plan.documents.contains { $0.path == "connexions.json" }, "carnet d’Accès distant jamais reçu")
        try expect(gotN2.plan.files.contains { $0.path == "outils.json" }, "les autres catégories, oui")
        try expect(gotN2.errors.contains(ConfigSyncEngine.untrustedMessage), "dit dans l’interface")
    }

    suite.add("Synchronisation (relecture) : un rapport planifié est produit par un seul Mac") {
        var schedule = ReportSchedule(name: "Suivi", siteKeys: ["k"])
        try expect(schedule.runsHere(device: "A") && schedule.runsHere(device: "B"), "rapport d’avant : réclamé par le premier qui le produit")
        schedule.runOn = "A"
        try expect(schedule.runsHere(device: "A") && !schedule.runsHere(device: "B"), "produit par A seulement")
        let data = try JSONEncoder().encode(schedule)
        try expectEqual(try JSONDecoder().decode(ReportSchedule.self, from: data).runOn, "A", "relu")
        let list = ConfigSyncPolicy.rule(for: "rapports/planifies.json")?.lists.first
        try expect(list?.volatileFields.contains("lastFiles") ?? false, "fichiers produits : propres au Mac qui les a produits")
    }

    suite.add("Synchronisation (relecture) : jeton FortiGate d’un autre site refusé, dossier choisi absent jamais créé") {
        let engine = F.engine(URL(fileURLWithPath: "/"), device: "A")
        let scope = engine.siteScope(C.siegeID, snapshot: C.snapshot())
        try expect(scope.secretAllowed(C.fortiService, C.fgtID.uuidString, nil), "jeton de la FortiGate du site")
        try expect(!scope.secretAllowed(C.fortiService, "FortiGate-d-un-autre-site", nil), "jeton d’une autre FortiGate : refusé")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-partage-absent-\(UUID().uuidString)")
        var chosen = F.engine(missing, device: "A")
        chosen.createsRoot = false
        var state = ConfigSyncState()
        do {
            _ = try chosen.sync(sites: [], global: true, snapshot: F.snapshot(), state: &state, now: F.t0)
            try expect(false, "synchronisation refusée")
        } catch let error as ConfigSyncError {
            try expectEqual(error, .folderMissing(missing.path), "dossier introuvable signalé")
        }
        try expect(!FileManager.default.fileExists(atPath: missing.path), "aucun dossier local créé à sa place")
    }
}
