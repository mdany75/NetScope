import Foundation
import NetScopeCore

// Vitesse des disques (note 22) : débits, IOPS et percentiles sur des durées fixes, classement des
// emplacements à partir de faits fixes, suivi de l'envoi nuage sur des relevés fixes, règles du
// bilan disque/réseau/serveur, historique et CSV, section du rapport, nettoyage du dossier
// « NetScope-test ». Les seuls fichiers écrits sont de tout petits fichiers (1 Mio au plus) dans
// un dossier temporaire : jamais de vrai dossier nuage ni de partage réseau, aucun trafic réseau.

func registerDiskTests(_ suite: TestSuite) {
    let nbsp = "\u{00A0}"

    suite.add("Disques : débit, IOPS et débit instantané sur des durées fixes") {
        try expectEqual(DiskMath.megabytesPerSecond(bytes: 1_000_000_000, seconds: 0.5), 2000, "1 Go en 0,5 s = 2 000 Mo/s")
        try expectEqual(DiskMath.megabytesPerSecond(bytes: 268_435_456, seconds: 2), 134.217728, "256 Mio en 2 s")
        try expect(DiskMath.megabytesPerSecond(bytes: 10, seconds: 0) == nil, "durée nulle : pas de débit")
        try expectEqual(DiskMath.iops(operations: 30_000, seconds: 3), 10_000, "30 000 accès en 3 s")
        try expect(DiskMath.iops(operations: 5, seconds: 0) == nil, "durée nulle : pas d'IOPS")
        try expectEqual(DiskMath.instantRate(previousBytes: 100_000_000, previousTime: 1, bytes: 150_000_000, time: 1.1)!.rounded(), 500,
                        "50 Mo en 0,1 s = 500 Mo/s")
        try expectEqual(DiskMath.megabits(fromMegabytes: 37.5), 300, "37,5 Mo/s = 300 Mbit/s")
    }

    suite.add("Disques : moyenne et percentiles des latences") {
        let values = (1...100).map(Double.init)
        try expectEqual(DiskMath.percentile(values, 0.95), 95, "p95 de 1…100")
        try expectEqual(DiskMath.percentile(values, 0.5), 50, "médiane (rang le plus proche)")
        try expectEqual(DiskMath.percentile(values.reversed(), 0.95), 95, "l'ordre des mesures ne compte pas")
        try expectEqual(DiskMath.percentile([0.08], 0.95), 0.08, "une seule mesure")
        try expect(DiskMath.percentile([], 0.95) == nil, "aucune mesure")
        try expectEqual(DiskMath.mean([1, 2, 3, 6]), 3, "moyenne")
        // 20 accès : 19 à 0,1 ms et un à 5 ms ; fsync compris, 0,004 s au total.
        let latencies = Array(repeating: 0.1, count: 19) + [5]
        let result = DiskRandomResult.make(latenciesMs: latencies, totalSeconds: 0.004)!
        try expectEqual(result.operations, 20, "nombre d'accès")
        try expectEqual(result.iops, 5000, "20 accès en 4 ms")
        try expectEqual((result.meanMs * 1000).rounded() / 1000, 0.345, "latence moyenne")
        try expectEqual(result.p95Ms, 0.1, "p95 : la valeur isolée n'y entre pas")
        try expect(DiskRandomResult.make(latenciesMs: [], totalSeconds: 1) == nil, "aucun accès")
    }

    suite.add("Disques : échelle des jauges, espace libre et confirmation nuage") {
        try expectEqual(DiskMath.gaugeScale(for: 80), 100, "80 Mo/s → 100")
        try expectEqual(DiskMath.gaugeScale(for: 480), 1000, "480 Mo/s → 1 000 (marge de 5 %)")
        try expectEqual(DiskMath.gaugeScale(for: 2850), 3000, "2 850 Mo/s → 3 000")
        try expectEqual(DiskMath.gaugeScale(for: 6900), 8000, "6 900 Mo/s → 8 000")
        let gib: Int64 = 1 << 30
        try expectEqual(DiskMath.requiredFreeSpace(forTestSize: 10 * gib), 11 * gib, "10 Gio + 10 %")
        try expect(DiskMath.hasRoom(freeBytes: 11 * gib, testSize: 10 * gib), "juste assez")
        try expect(!DiskMath.hasRoom(freeBytes: 11 * gib - 1, testSize: 10 * gib), "un octet de moins : refusé")
        try expect(DiskMath.hasRoom(freeBytes: nil, testSize: 10 * gib), "espace inconnu (certains partages) : on tente")
        try expect(!DiskMath.needsCloudConfirmation(kind: .nuage, testSize: gib), "1 Gio dans le nuage : sans confirmation")
        try expect(DiskMath.needsCloudConfirmation(kind: .nuage, testSize: 5 * gib), "5 Gio dans le nuage : confirmation")
        try expect(!DiskMath.needsCloudConfirmation(kind: .externe, testSize: 10 * gib), "disque externe : jamais")
    }

    suite.add("Disques : plan des étapes et avancement global") {
        let config = DiskBenchmarkConfig(sizeBytes: 1 << 30, passes: 2, random: true)
        let plan = DiskPlan(config: config, kind: .interne)
        try expectEqual(plan.steps.map(\.phase), [.ecriture, .lecture, .ecriture, .lecture, .aleatoireLecture, .aleatoireEcriture],
                        "deux passes puis les accès aléatoires")
        try expectEqual(plan.fraction(phase: .ecriture, pass: 1, stepFraction: 0.5), 0.5 / 5, "moitié de la première écriture")
        try expectEqual(plan.fraction(phase: .aleatoireLecture, pass: 1, stepFraction: 1), 4.5 / 5, "lecture aléatoire faite")
        try expectEqual(plan.fraction(phase: .aleatoireEcriture, pass: 1, stepFraction: 1), 1, "tout est fait")
        // Dossier nuage : une passe d'écriture, l'envoi, ni lecture ni accès aléatoires.
        let cloud = config.effective(for: .nuage)
        try expectEqual(cloud.passes, 1, "une seule passe dans le nuage")
        try expect(!cloud.random, "pas d'accès aléatoires dans le nuage")
        try expectEqual(DiskPlan(config: config, kind: .nuage).steps.map(\.phase), [.ecriture, .envoi], "écriture puis envoi")
        try expectEqual(DiskBenchmarkConfig(sizeBytes: 10, passes: 0).passes, 1, "au moins une passe")
        try expectEqual(DiskBenchmarkConfig(sizeBytes: 10).sizeBytes, 1 << 20, "au moins un bloc de 1 Mio")
    }

    suite.add("Disques : classement des volumes à partir de faits fixes") {
        let home = "/Users/essai"
        let root = DiskLocationCatalog.location(for: DiskVolumeFacts(path: "/", name: "Macintosh HD", fsType: "apfs", isInternal: true,
                                                                     isLocal: true, isReadOnly: true, isRoot: true,
                                                                     totalBytes: 994_000_000_000, freeBytes: 412_000_000_000), home: home)!
        try expectEqual(root.kind, .interne, "volume de démarrage : interne")
        try expectEqual(root.testParent, "/Users/essai/Library/Caches", "essai dans ~/Library/Caches (système scellé)")
        try expectEqual(root.fileSystem, "APFS", "système de fichiers en clair")
        try expectEqual(root.detail, "APFS · 412\(nbsp)Go libres sur 994\(nbsp)Go", "ligne de détail")
        try expect(!root.isReadOnly, "le volume scellé n'empêche pas l'essai")

        try expect(DiskLocationCatalog.location(for: DiskVolumeFacts(path: "/System/Volumes/Data", name: "Data", fsType: "apfs")) == nil,
                   "volumes système écartés")
        try expect(DiskLocationCatalog.location(for: DiskVolumeFacts(path: "/Volumes/Installer", name: "Installer", fsType: "hfs",
                                                                     isInternal: false, isEjectable: true, isReadOnly: true)) == nil,
                   "image disque en lecture seule écartée")

        let usb = DiskLocationCatalog.location(for: DiskVolumeFacts(path: "/Volumes/T7", name: "T7", fsType: "exfat", isInternal: false,
                                                                    isLocal: true, isRemovable: true, isEjectable: true))!
        try expectEqual(usb.kind, .externe, "disque USB : externe")
        try expectEqual(usb.fileSystem, "exFAT", "exFAT")
        try expectEqual(usb.testFolder.path, "/Volumes/T7/NetScope-test", "dossier d'essai à la racine du volume")

        let smb = DiskLocationCatalog.location(for: DiskVolumeFacts(path: "/Volumes/Projets", name: "Projets", fsType: "smbfs",
                                                                    mountFrom: "//dany;BUREAU@nas.bureau.local/Projets%20clients",
                                                                    isLocal: false))!
        try expectEqual(smb.kind, .reseau, "SMB : partage réseau")
        try expectEqual(smb.networkProtocol, .smb, "protocole SMB")
        try expectEqual(smb.server, "nas.bureau.local", "serveur sans le compte")
        try expectEqual(smb.share, "Projets clients", "partage décodé")
        try expectEqual(smb.detail, "SMB · nas.bureau.local/Projets clients", "détail du partage")

        let nfs = DiskLocationCatalog.serverAndShare(mountFrom: "nas.local:/export/data")
        try expectEqual(nfs.server, "nas.local", "NFS : serveur")
        try expectEqual(nfs.share, "export/data", "NFS : chemin")
        let afp = DiskLocationCatalog.serverAndShare(mountFrom: "afp://dany@10.0.0.5:548/Archives")
        try expectEqual(afp.server, "10.0.0.5", "AFP : adresse sans le port")
        try expectEqual(afp.share, "Archives", "AFP : partage")
        let dav = DiskLocationCatalog.serverAndShare(mountFrom: "https://dav.exemple.ca/fichiers")
        try expectEqual(dav.server, "dav.exemple.ca", "WebDAV : serveur")
        try expect(DiskLocationCatalog.serverAndShare(mountFrom: "/dev/disk4s1").server == nil, "disque local : pas de serveur")
    }

    suite.add("Disques : dossiers nuage, ordre de la liste et choix par défaut") {
        let parent = "/Users/essai/Library/CloudStorage"
        let onedrive = DiskLocationCatalog.cloudLocation(folderName: "OneDrive-Personal", parent: parent)!
        try expectEqual(onedrive.provider, .onedrive, "OneDrive reconnu")
        try expectEqual(onedrive.name, "OneDrive – Personnel", "compte personnel traduit")
        let work = DiskLocationCatalog.cloudLocation(folderName: "OneDrive-GroupeCouture", parent: parent)!
        try expectEqual(work.name, "OneDrive – GroupeCouture", "compte professionnel")
        let google = DiskLocationCatalog.cloudLocation(folderName: "GoogleDrive-dany@exemple.ca", parent: parent)!
        try expectEqual(google.provider, .googleDrive, "Google Drive reconnu")
        try expectEqual(google.account, "dany@exemple.ca", "compte Google")
        try expectEqual(google.testParent, parent + "/GoogleDrive-dany@exemple.ca/My Drive", "Google Drive écrit dans « My Drive »")
        try expectEqual(DiskLocationCatalog.cloudLocation(folderName: "Dropbox", parent: parent)?.name, "Dropbox", "Dropbox")
        try expectEqual(DiskLocationCatalog.cloudLocation(folderName: "Box-Box", parent: parent)?.name, "Box", "Box")
        try expect(DiskLocationCatalog.cloudLocation(folderName: ".DS_Store", parent: parent) == nil, "fichier caché écarté")

        let internalDisk = DiskLocation(name: "Macintosh HD", path: "/", kind: .interne, fileSystem: "APFS")
        let usb = DiskLocation(name: "T7", path: "/Volumes/T7", kind: .externe, fileSystem: "exFAT")
        let archive = DiskLocation(name: "Archives", path: "/Volumes/Archives", kind: .externe, fileSystem: "APFS")
        let nas = DiskLocation(name: "Projets", path: "/Volumes/Projets", kind: .reseau, fileSystem: "SMB")
        let sorted = DiskLocationCatalog.sorted([onedrive, nas, usb, internalDisk, archive])
        try expectEqual(sorted.map(\.name), ["Macintosh HD", "Archives", "T7", "Projets", "OneDrive – Personnel"],
                        "interne, externes par nom, partages, nuage")
        try expectEqual(DiskLocationCatalog.preferred(in: sorted, lastUsed: "/Volumes/Projets")?.name, "Projets", "dernier utilisé")
        try expectEqual(DiskLocationCatalog.preferred(in: sorted, lastUsed: "/Volumes/Absent")?.name, "Archives",
                        "sinon le premier disque externe")
        try expectEqual(DiskLocationCatalog.preferred(in: [internalDisk, nas], lastUsed: nil)?.name, "Macintosh HD", "sinon le premier")
    }

    suite.add("Disques : suivi de l'envoi nuage sur des relevés fixes") {
        // iCloud : en attente, puis en cours, puis envoyé 12,5 s après la fin de l'écriture.
        var icloud = DiskCloudTracker(grace: 8, timeout: 600)
        try expectEqual(icloud.add(DiskCloudSample(time: 0, isUbiquitous: true, isUploading: false, isUploaded: false)), .attente, "attente")
        try expectEqual(icloud.add(DiskCloudSample(time: 2, isUbiquitous: true, isUploading: true, isUploaded: false)), .envoi, "envoi")
        try expectEqual(icloud.add(DiskCloudSample(time: 12.5, isUbiquitous: true, isUploading: false, isUploaded: true)), .envoye, "envoyé")
        try expectEqual(icloud.uploadedAfter, 12.5, "temps jusqu'à « envoyé »")
        try expectEqual(icloud.firstUploadingAt, 2, "début de l'envoi")
        try expectEqual(icloud.add(DiskCloudSample(time: 13, isUbiquitous: true, isUploading: true)), .envoye, "l'état final ne bouge plus")

        // Service muet : aucun attribut pendant le délai de grâce.
        var silent = DiskCloudTracker(grace: 8, timeout: 600)
        try expectEqual(silent.add(DiskCloudSample(time: 4, isUbiquitous: false)), .attente, "encore dans le délai de grâce")
        try expectEqual(silent.add(DiskCloudSample(time: 8.2, isUbiquitous: nil)), .nonFourni, "état non fourni")

        // Envoi interminable : délai dépassé.
        var slow = DiskCloudTracker(grace: 8, timeout: 120)
        slow.add(DiskCloudSample(time: 1, isUbiquitous: true, isUploading: true, isUploaded: false))
        try expectEqual(slow.add(DiskCloudSample(time: 120.4, isUbiquitous: true, isUploading: true, isUploaded: false)), .delaiDepasse,
                        "délai maximal")
        var failing = DiskCloudTracker()
        try expectEqual(failing.add(DiskCloudSample(time: 1, isUbiquitous: true, uploadError: "Quota dépassé")), .erreur, "erreur")
        try expectEqual(failing.error, "Quota dépassé", "message du service")
        var stopped = DiskCloudTracker()
        stopped.add(DiskCloudSample(time: 1, isUbiquitous: true, isUploading: true))
        stopped.stop()
        try expectEqual(stopped.status, .arrete, "arrêté pendant l'envoi")
        // 256 Mio en 20 s ≈ 107 Mbit/s.
        try expectEqual(DiskCloudTracker.uploadMbps(bytes: 256 << 20, seconds: 20)!.rounded(), 107, "débit d'envoi effectif")
        try expect(DiskCloudTracker.uploadMbps(bytes: 1, seconds: nil) == nil, "pas d'envoi mesuré")
    }

    suite.add("Disques : bilan disque, réseau, latence et serveur") {
        let gib: Int64 = 1 << 30
        let nvme = DiskBenchmarkResult(sizeBytes: gib, passes: 1, writePasses: [2850], readPasses: [3120])
        let local = DiskAdvisor.verdict(kind: .interne, result: nvme)
        try expectEqual(local.limit, .disque, "disque local : limité par le disque")
        try expect(local.detail.contains("SSD NVMe rapide"), "classe du disque : \(local.detail)")
        let usb3 = DiskAdvisor.verdict(kind: .externe, result: DiskBenchmarkResult(sizeBytes: gib, passes: 1, writePasses: [380], readPasses: [420]))
        try expect(usb3.detail.contains("USB 3.0"), "plafond USB 3.0 signalé")

        // Wi-Fi à 300 Mbit/s, 33 Mo/s lus (264 Mbit/s, 88 % du lien) : le réseau limite.
        let share = DiskBenchmarkResult(sizeBytes: gib, passes: 1, writePasses: [28], readPasses: [33])
        let wifi = DiskAdvisor.verdict(kind: .reseau, result: share,
                                       context: DiskNetworkContext(linkMbps: 300, linkKind: "Wi-Fi", serverLatencyMs: 3.2))
        try expectEqual(wifi.limit, .reseau, "lien saturé")
        try expectEqual(wifi.title, "Limité par le réseau Wi-Fi à 300\(nbsp)Mbit/s", "titre du bilan")
        try expect(wifi.detail.contains("Ethernet"), "conseil : passer en Ethernet")

        // Ethernet 1 Gbit/s, 40 Mo/s (320 Mbit/s), latence faible : le serveur limite.
        let slowServer = DiskBenchmarkResult(sizeBytes: gib, passes: 1, writePasses: [35], readPasses: [40])
        let ethernet = DiskAdvisor.verdict(kind: .reseau, result: slowServer,
                                           context: DiskNetworkContext(linkMbps: 1000, linkKind: "Ethernet", serverLatencyMs: 0.6))
        try expectEqual(ethernet.limit, .serveur, "serveur lent")
        try expect(ethernet.detail.contains("700\(nbsp)Mbit/s"), "débit utile du lien : \(ethernet.detail)")

        // Même débit, mais 32 ms vers le serveur (VPN) : la latence limite.
        let vpn = DiskAdvisor.verdict(kind: .reseau, result: slowServer,
                                      context: DiskNetworkContext(linkMbps: 1000, linkKind: "Ethernet", serverLatencyMs: 32))
        try expectEqual(vpn.limit, .latence, "latence élevée")
        // Lien inconnu.
        try expectEqual(DiskAdvisor.verdict(kind: .reseau, result: slowServer).limit, .inconnu, "lien inconnu : indéterminé")
        // Mesure incomplète (test arrêté avant la lecture).
        try expectEqual(DiskAdvisor.verdict(kind: .reseau, result: DiskBenchmarkResult(sizeBytes: gib, passes: 1, writePasses: [30])).limit,
                        .inconnu, "sans lecture : pas de bilan")
    }

    suite.add("Disques : bilan des dossiers nuage") {
        let size: Int64 = 256 << 20
        // 256 Mio envoyés en 50 s ≈ 43 Mbit/s, montée Internet 50 Mbit/s : Internet limite.
        let sent = DiskBenchmarkResult(sizeBytes: size, passes: 1, writePasses: [1450], cloudStatus: .envoye, uploadSeconds: 50)
        let internet = DiskAdvisor.verdict(kind: .nuage, result: sent, context: DiskNetworkContext(internetUpMbps: 50))
        try expectEqual(internet.limit, .internet, "lien montant saturé")
        // Montée Internet de 500 Mbit/s : le service limite.
        let service = DiskAdvisor.verdict(kind: .nuage, result: sent, context: DiskNetworkContext(internetUpMbps: 500))
        try expectEqual(service.limit, .service, "le service ralentit l'envoi")
        try expect(service.detail.contains("Copie locale écrite à 1\u{202F}450\(nbsp)Mo/s"), "écriture locale rappelée : \(service.detail)")
        let unknown = DiskAdvisor.verdict(kind: .nuage, result: sent)
        try expect(unknown.detail.contains("Speedtest"), "sans Speedtest : on propose d'en lancer un")
        let silent = DiskAdvisor.verdict(kind: .nuage, result: DiskBenchmarkResult(sizeBytes: size, passes: 1, writePasses: [900],
                                                                                   cloudStatus: .nonFourni))
        try expectEqual(silent.title, "Ce service ne fournit pas l’état d’envoi", "dit clairement que l'état manque")
        let late = DiskAdvisor.verdict(kind: .nuage, result: DiskBenchmarkResult(sizeBytes: size, passes: 1, writePasses: [900],
                                                                                 cloudStatus: .delaiDepasse))
        try expectEqual(late.limit, .service, "délai dépassé")
    }

    suite.add("Disques : historique par emplacement et export CSV") {
        let usb = DiskLocation(name: "T7; USB", path: "/Volumes/T7", kind: .externe, fileSystem: "exFAT")
        let nas = DiskLocation(name: "Projets", path: "/Volumes/Projets", kind: .reseau, fileSystem: "SMB", server: "nas.local",
                               share: "Projets", networkProtocol: .smb)
        let result = DiskBenchmarkResult(sizeBytes: 1 << 30, passes: 2, writePasses: [900, 1000], readPasses: [1000, 1100],
                                         randomRead: DiskRandomResult(operations: 30_000, seconds: 3, iops: 10_000, meanMs: 0.1, p95Ms: 0.14))
        let verdict = DiskAdvisor.verdict(kind: .externe, result: result)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let old = DiskTestRecord(date: base, location: usb, result: result, verdict: verdict)
        let recent = DiskTestRecord(date: base.addingTimeInterval(3600), location: usb, result: result, verdict: verdict)
        let share = DiskTestRecord(date: base.addingTimeInterval(1800), location: nas, result: result,
                                   network: DiskNetworkContext(linkMbps: 1000, linkKind: "Ethernet", serverLatencyMs: 0.8),
                                   verdict: DiskAdvisor.verdict(kind: .reseau, result: result))
        try expectEqual(old.writeMBps, 950, "moyenne des passes d'écriture")
        try expectEqual(share.detail, "SMB · nas.local/Projets", "détail du partage conservé")
        try expectEqual(DiskHistoryStore.records([old, share, recent], for: "/Volumes/T7").map(\.id), [recent.id, old.id],
                        "tests d'un emplacement, récents d'abord")
        try expectEqual(DiskHistoryStore.latestPerLocation([old, share, recent]).map(\.id), [recent.id, share.id],
                        "dernier test de chaque emplacement")
        let csv = DiskHistoryStore.csv([recent])
        let lines = csv.split(separator: "\n").map(String.init)
        try expectEqual(lines.count, 2, "en-tête et une ligne")
        try expect(lines[0].hasPrefix("Date;Emplacement;Type;"), "en-tête")
        try expect(lines[1].contains(";\"T7; USB\";Disque externe;"), "nom protégé par des guillemets : \(lines[1])")
        try expect(lines[1].contains(";1024;2;950,0;1050,0;10000;"), "taille, passes, débits à virgule : \(lines[1])")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-disques-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskHistoryStore(url: directory.appendingPathComponent("disques.json"))
        try store.save(DiskHistoryStore.Content(records: [old, share, recent], lastLocation: "/Volumes/T7",
                                                config: DiskBenchmarkConfig(sizeBytes: 5 << 30, passes: 3)))
        let loaded = store.load()
        try expectEqual(loaded.records.map(\.id), [recent.id, share.id, old.id], "relu dans l'ordre")
        try expectEqual(loaded.lastLocation, "/Volumes/T7", "dernier emplacement")
        try expectEqual(loaded.config?.passes, 3, "réglages retenus")
        try expectEqual(loaded.records.first?.randomReadIOPS, 10_000, "IOPS conservées")
        try expectEqual(DiskHistoryStore.pruned(Array(repeating: old, count: 310)).count, DiskHistoryStore.maxRecords, "historique borné")
    }

    suite.add("Disques : section « Vitesse des disques » du rapport") {
        try expect(!ReportTemplate.allCases.contains { $0.defaultSections.contains(.disques) }, "facultative : aucun modèle ne la coche")
        let nas = DiskLocation(name: "NAS Projets", path: "/Volumes/Projets", kind: .reseau, fileSystem: "SMB", server: "nas.local",
                               networkProtocol: .smb)
        let result = DiskBenchmarkResult(sizeBytes: 1 << 30, passes: 1, writePasses: [96], readPasses: [104])
        let context = DiskNetworkContext(linkMbps: 1000, linkKind: "Ethernet", serverLatencyMs: 0.7)
        let record = DiskTestRecord(location: nas, result: result, network: context,
                                    verdict: DiskAdvisor.verdict(kind: .reseau, result: result, context: context))
        var config = ReportConfig(template: .audit, sections: [.resume, .disques], site: "Siège", date: "2026-11-04")
        config.signature = false
        var input = ReportInput(devices: [])
        input.diskTests = [record]
        let document = ReportBuilder.build(config: config, input: input)
        let section = document.section(.disques)
        try expect(section != nil, "section présente")
        try expectEqual(section?.heading, "2. Vitesse des disques", "numérotée après le résumé")
        try expectEqual(section?.tables.first?.rows.count, 1, "une ligne par emplacement")
        try expectEqual(section?.tables.first?.rows.first?.cells.last?.text, "Réseau", "limite : le réseau (832 Mbit/s sur 1 Gbit/s)")
        var empty = ReportInput(devices: [])
        empty.diskTests = []
        if case .note(let text) = ReportBuilder.build(config: config, input: empty).section(.disques)?.blocks.first {
            try expect(text.contains("Vitesse des disques"), "invitation à lancer l'outil")
        } else {
            throw TestFailure(message: "note attendue sans test", file: #fileID, line: #line)
        }
    }

    suite.add("Disques : nettoyage de « NetScope-test » sans toucher aux autres fichiers") {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("netscope-nettoyage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        let folder = DiskTestFolder.url(in: parent)
        try expectEqual(folder.lastPathComponent, "NetScope-test", "nom du dossier")
        try expect(DiskTestFolder.isTestFile(DiskTestFolder.fileName()), "nom des fichiers d'essai")
        try expect(!DiskTestFolder.isTestFile("netscope-essai-.bin"), "nom vide refusé")
        try expect(!DiskTestFolder.isTestFile("rapport.bin"), "autre fichier refusé")

        // Deux fichiers d'essai, un fichier de l'utilisateur et un sous-dossier : seuls les essais partent.
        _ = try DiskTestFolder.prepare(in: parent)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent(DiskTestFolder.fileName()))
        try Data([4]).write(to: folder.appendingPathComponent(DiskTestFolder.fileName()))
        try Data("à garder".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try fm.createDirectory(at: folder.appendingPathComponent("netscope-essai-dossier.bin"), withIntermediateDirectories: false)
        let first = DiskTestFolder.cleanup(in: parent)
        try expectEqual(first.removedFiles, 2, "deux fichiers d'essai supprimés")
        try expect(!first.removedFolder, "dossier gardé : il n'est pas vide")
        try expectEqual(first.keptItems.sorted(), ["netscope-essai-dossier.bin", "notes.txt"], "le reste est laissé en place")
        try expect(fm.fileExists(atPath: folder.appendingPathComponent("notes.txt").path), "fichier de l'utilisateur intact")

        // Seulement des essais : le dossier disparaît aussi.
        try fm.removeItem(at: folder)
        _ = try DiskTestFolder.prepare(in: parent)
        try Data([1]).write(to: folder.appendingPathComponent(DiskTestFolder.fileName()))
        let second = DiskTestFolder.cleanup(in: parent)
        try expect(second.removedFiles == 1 && second.removedFolder, "dossier supprimé une fois vide")
        try expect(!fm.fileExists(atPath: folder.path), "plus de NetScope-test")
        try expectEqual(DiskTestFolder.cleanup(in: parent), DiskTestFolder.Cleanup(), "rien à nettoyer")

        // « NetScope-test » qui est un lien symbolique : jamais suivi.
        let elsewhere = parent.appendingPathComponent("ailleurs", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        let precious = elsewhere.appendingPathComponent(DiskTestFolder.fileName())
        try Data([9]).write(to: precious)
        try fm.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
        let linked = DiskTestFolder.cleanup(in: parent)
        try expectEqual(linked.removedFiles, 0, "rien supprimé à travers un lien")
        try expect(fm.fileExists(atPath: precious.path), "fichier derrière le lien intact")
        try expectThrows(DiskBenchmarkError.unsafeFolder(folder.path), "un lien n'est pas un dossier d'essai") {
            _ = try DiskTestFolder.prepare(in: parent)
        }
        try fm.removeItem(at: folder)

        // Nettoyage au lancement suivant : le dossier noté est vidé, puis oublié.
        let pending = DiskPendingCleanup(url: parent.appendingPathComponent("en-cours.json"))
        let volume = parent.appendingPathComponent("volume", isDirectory: true)
        try fm.createDirectory(at: volume, withIntermediateDirectories: false)
        _ = try DiskTestFolder.prepare(in: volume)
        try Data([7]).write(to: DiskTestFolder.url(in: volume).appendingPathComponent(DiskTestFolder.fileName()))
        pending.add(volume.path)
        pending.add("/Volumes/Absent-\(UUID().uuidString)")
        let cleaned = pending.cleanAll()
        try expectEqual(cleaned[volume.path]?.removedFiles, 1, "reste d'un essai interrompu supprimé")
        try expect(!fm.fileExists(atPath: DiskTestFolder.url(in: volume).path), "dossier d'essai supprimé")
        try expectEqual(pending.entries().count, 1, "un volume absent reste noté pour plus tard")
    }

    suite.add("Disques : mini-test réel de 1 Mio dans un dossier temporaire, puis arrêt") {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("netscope-minitest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        let location = DiskLocation(name: "Essai", path: parent.path, kind: .externe, fileSystem: "APFS")
        let pending = DiskPendingCleanup(url: parent.appendingPathComponent("en-cours.json"))
        let config = DiskBenchmarkConfig(sizeBytes: 1 << 20, passes: 2, random: true, randomSeconds: 0.05, randomMaxOperations: 200)
        var result: DiskBenchmarkResult?
        var phases: [DiskPhase] = []
        for await event in DiskBenchmark(location: location, config: config, pending: pending).run() {
            switch event {
            case .phase(let phase, _): if phases.last != phase { phases.append(phase) }
            case .finished(let value): result = value
            case .failed(let message): throw TestFailure(message: message, file: #fileID, line: #line)
            default: break
            }
        }
        guard let result else { throw TestFailure(message: "aucun résultat", file: #fileID, line: #line) }
        try expectEqual(result.writePasses.count, 2, "deux passes d'écriture")
        try expectEqual(result.readPasses.count, 2, "deux passes de lecture")
        try expect((result.writeMBps ?? 0) > 0 && (result.readMBps ?? 0) > 0, "débits mesurés")
        try expect((result.randomRead?.operations ?? 0) > 0 && (result.randomWrite?.operations ?? 0) > 0, "accès aléatoires faits")
        try expect((result.randomRead?.operations ?? 0) <= 200, "borne du nombre d'accès respectée")
        try expectEqual(phases.first, .preparation, "commence par la préparation")
        try expectEqual(phases.last, .nettoyage, "finit par le nettoyage")
        try expect(!fm.fileExists(atPath: location.testFolder.path), "fichier et dossier d'essai supprimés")
        try expect(pending.entries().isEmpty, "plus rien à nettoyer au prochain lancement")

        // Arrêt : la tâche qui lit le flux est annulée ; le dossier d'essai disparaît quand même.
        let long = DiskBenchmarkConfig(sizeBytes: 1 << 20, passes: 10, random: true, randomSeconds: 30)
        let task = Task { () -> Bool in
            var stoppedOrDone = false
            for await event in DiskBenchmark(location: location, config: long, pending: pending).run() {
                if case .phase(.aleatoireLecture, _) = event { withUnsafeCurrentTask { $0?.cancel() } }
                if case .stopped = event { stoppedOrDone = true }
            }
            return stoppedOrDone
        }
        _ = await task.value
        // Le fil de mesure finit son nettoyage juste après l'arrêt : on lui laisse un instant.
        var waited = 0
        while fm.fileExists(atPath: location.testFolder.path) && waited < 50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        try expect(!fm.fileExists(atPath: location.testFolder.path), "arrêt : dossier d'essai supprimé")

        // Espace insuffisant : refusé avant d'écrire quoi que ce soit.
        let huge = DiskBenchmarkConfig(sizeBytes: Int64(1) << 60)
        var refused: String?
        for await event in DiskBenchmark(location: location, config: huge).run() {
            if case .failed(let message) = event { refused = message }
        }
        try expect(refused?.hasPrefix("Espace insuffisant") == true, "espace vérifié avant : \(refused ?? "—")")
        try expect(!fm.fileExists(atPath: location.testFolder.path), "rien n'a été créé")
    }

    suite.add("Disques : mise en forme française") {
        try expectEqual(DiskFormat.rate(2850), "2\u{202F}850", "milliers séparés")
        try expectEqual(DiskFormat.rate(98.44), "98,4", "une décimale sous 100")
        try expectEqual(DiskFormat.bits(300), "300\(nbsp)Mbit/s", "Mbit/s")
        try expectEqual(DiskFormat.bits(2500), "2,5\(nbsp)Gbit/s", "Gbit/s")
        try expectEqual(DiskFormat.latency(0.084), "0,08\(nbsp)ms", "latence sous la milliseconde")
        try expectEqual(DiskFormat.duration(185), "3\(nbsp)min 05\(nbsp)s", "durée")
        try expectEqual(DiskFormat.testSize(256 << 20), "256\(nbsp)Mio", "256 Mio")
        try expectEqual(DiskFormat.testSize(10 << 30), "10\(nbsp)Gio", "10 Gio")
        try expectEqual(DiskFormat.size(1_900_000_000_000), "1,9\(nbsp)To", "taille d'un volume")
    }
}
