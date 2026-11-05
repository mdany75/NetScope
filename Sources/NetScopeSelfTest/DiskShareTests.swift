import Darwin
import Foundation
import NetScopeCore

// Emplacements ajoutés à « Vitesse des disques » (note 55) : analyse des adresses collées, URL de
// montage (jamais de mot de passe), choix du type d'après les ports, reconnaissance d'un partage
// déjà monté, fusion avec les volumes trouvés, messages des erreurs NetFS, ports et bilan de
// « Tester le serveur », enregistrement par site. Données fixes : aucun montage, aucun trafic réseau.

func registerDiskShareTests(_ suite: TestSuite) {
    let site = "5A7E0028-0001-4C1E-9A11-00000000A001"

    suite.add("Partages : adresses collées (smb, UNC, NFS, AFP, WebDAV, dossier)") {
        let smb = DiskShareAddress.parse("smb://technicien@nas-bureau.local/Projets")!
        try expectEqual(smb.kind, .smb, "smb:// → SMB")
        try expectEqual(smb.server, "nas-bureau.local", "serveur")
        try expectEqual(smb.share, "Projets", "partage")
        try expectEqual(smb.user, "technicien", "utilisateur")
        let unc = DiskShareAddress.parse("\\\\SRV-BACKUP\\Sauvegardes\\Essais")!
        try expectEqual(unc.kind, .smb, "chemin UNC → SMB")
        try expectEqual(unc.server, "SRV-BACKUP", "serveur UNC")
        try expectEqual(unc.share, "Sauvegardes/Essais", "partage et sous-dossier UNC")
        let spaced = DiskShareAddress.parse("smb://nas/Dossiers partagés")!
        try expectEqual(spaced.share, "Dossiers partagés", "espaces et accents gardés")
        let domain = DiskShareAddress.parse("smb://BUREAU;technicien@10.10.0.31/Sauvegardes")!
        try expectEqual(domain.user, "BUREAU;technicien", "domaine SMB dans le compte")
        let nfs = DiskShareAddress.parse("nas:/volume1/projets")!
        try expectEqual(nfs.kind, .nfs, "serveur:/chemin → NFS")
        try expectEqual(nfs.share, "/volume1/projets", "chemin d'export gardé avec sa barre")
        try expectEqual(DiskShareAddress.parse("nfs://nas/volume1/projets/")!.share, "/volume1/projets", "nfs://, barre finale retirée")
        try expectEqual(DiskShareAddress.parse("afp://imac-studio/Media")!.kind, .afp, "afp://")
        let dav = DiskShareAddress.parse("https://cloud.exemple.ca/remote.php/dav/files/dany/")!
        try expectEqual(dav.kind, .webdav, "https:// → WebDAV")
        try expect(dav.secure, "HTTPS")
        try expectEqual(dav.share, "/remote.php/dav/files/dany", "chemin WebDAV")
        let davHTTP = DiskShareAddress.parse("http://nas:5005/home")!
        try expect(!davHTTP.secure, "HTTP")
        try expectEqual(davHTTP.port, 5005, "port non habituel gardé")
        try expectEqual(DiskShareAddress.parse("https://nas:443/dav")!.port, nil, "port habituel omis")
        try expectEqual(DiskShareAddress.parse("sftp://nas/home")!.kind, .sftp, "sftp:// reconnu (grisé dans la feuille)")
        let folder = DiskShareAddress.parse("/Volumes/Archives/Essais")!
        try expectEqual(folder.kind, .dossier, "chemin local → dossier")
        try expectEqual(DiskShareAddress.parse("nas-bureau/Projets")!.kind, .smb, "serveur/partage → SMB")
        try expectEqual(DiskShareAddress.parse("nas-bureau")!.share, "", "serveur seul")
        try expect(DiskShareAddress.parse("gopher://x/y") == nil, "schéma inconnu refusé")
        try expect(DiskShareAddress.parse("pas une adresse !") == nil, "texte libre refusé")
        try expect(DiskShareAddress.parse("   ") == nil, "vide")
    }

    suite.add("Partages : URL de montage sans mot de passe, encodage et IPv6") {
        let share = DiskShareLocation(siteKey: site, kind: .smb, server: "nas-bureau.local", share: "Dossiers partagés",
                                      user: "BUREAU;technicien", hasPassword: true)
        let url = share.mountURL!
        try expectEqual(url.absoluteString, "smb://BUREAU;technicien@nas-bureau.local/Dossiers%20partag%C3%A9s", "URL SMB encodée")
        try expect(!url.absoluteString.contains(":") || url.absoluteString.hasPrefix("smb:"), "aucun « : » de mot de passe")
        try expectEqual(share.address, "smb://nas-bureau.local/Dossiers partagés", "adresse affichée sans compte")
        try expectEqual(DiskShareAddress(kind: .smb, server: "nas", share: "P", user: "a@b.ca").url?.absoluteString,
                        "smb://a%40b.ca@nas/P", "« @ » du compte encodé")
        try expectEqual(DiskShareAddress(kind: .nfs, server: "nas", share: "/volume1/projets").url?.absoluteString,
                        "nfs://nas/volume1/projets", "NFS")
        try expectEqual(DiskShareAddress(kind: .webdav, server: "dav.exemple.ca", share: "/fichiers", port: 8443).url?.absoluteString,
                        "https://dav.exemple.ca:8443/fichiers", "WebDAV avec port")
        try expectEqual(DiskShareAddress(kind: .webdav, server: "nas", share: "", secure: false).url?.absoluteString, "http://nas", "WebDAV HTTP")
        try expectEqual(DiskShareAddress(kind: .smb, server: "fe80::1", share: "P").url?.absoluteString, "smb://[fe80::1]/P", "IPv6 entre crochets")
        try expect(DiskShareAddress(kind: .smb, server: "nas/../x", share: "P").url == nil, "serveur invalide refusé")
        try expect(DiskShareAddress(kind: .dossier, server: "", share: "/Volumes/X").url == nil, "dossier : pas d'URL")
        // Aller-retour : ce qui est construit se relit à l'identique.
        let back = DiskShareAddress.parse(url.absoluteString)!
        try expectEqual(back.share, "Dossiers partagés", "aller-retour du partage")
        try expectEqual(back.user, "BUREAU;technicien", "aller-retour du compte")
    }

    suite.add("Partages : saisie à compléter, nom affiché et type proposé d'après les ports") {
        var draft = DiskShareLocation(siteKey: site, kind: .smb)
        try expectEqual(draft.problems.count, 2, "serveur et partage manquants")
        draft.server = "nas-bureau.local"
        draft.share = "Projets"
        try expect(draft.problems.isEmpty, "SMB complet")
        try expectEqual(draft.displayName, "Projets", "nom tiré du partage")
        draft.name = "NAS Bureau – Projets"
        try expectEqual(draft.displayName, "NAS Bureau – Projets", "nom choisi")
        draft.port = 70_000
        try expectEqual(draft.problems.count, 1, "port hors limites")
        let nfs = DiskShareLocation(siteKey: site, kind: .nfs, server: "nas", share: "/")
        try expectEqual(nfs.problems.count, 1, "chemin d'export NFS vide")
        let folder = DiskShareLocation(siteKey: site, kind: .dossier, share: "Essais")
        try expectEqual(folder.problems, ["Choisissez un dossier."], "dossier relatif refusé")
        try expect(DiskShareKind.suggested(openPorts: [22, 80, 443, 445]).map { $0.kind } == .smb, "445 → SMB")
        try expect(DiskShareKind.suggested(openPorts: [111, 2049]).map { $0.kind } == .nfs, "2049 → NFS")
        try expect(DiskShareKind.suggested(openPorts: [548]).map { $0.kind } == .afp, "548 → AFP")
        let web = DiskShareKind.suggested(openPorts: [80])!
        try expect(web.kind == .webdav && !web.secure, "80 seul → WebDAV en HTTP")
        try expect(DiskShareKind.suggested(openPorts: [22, 3389]) == nil, "aucun port de partage")
        try expect(!DiskShareKind.ftp.isAvailable && !DiskShareKind.sftp.isAvailable && !DiskShareKind.ftps.isAvailable,
                   "FTP, FTPS, SFTP grisés (note 50)")
        try expect(DiskShareKind.smb.isMountable && !DiskShareKind.dossier.isMountable, "montables par NetFS")
        try expect(!DiskShareKind.nfs.usesCredentials && DiskShareKind.smb.usesCredentials, "NFS sans compte")
    }

    suite.add("Partages : partage déjà monté reconnu et fusion avec les volumes") {
        let mounted = DiskLocationCatalog.location(for: DiskVolumeFacts(path: "/Volumes/Projets", name: "Projets", fsType: "smbfs",
                                                                         mountFrom: "//technicien@NAS-Bureau._smb._tcp.local/Projets"),
                                                   home: "/Users/t")
        // Le nom Bonjour du montage n'est pas le nom saisi : seul un nom équivalent est reconnu.
        let byName = DiskShareLocation(siteKey: site, kind: .smb, server: "nas-bureau.local", share: "projets")
        let mountedPlain = DiskLocationCatalog.location(for: DiskVolumeFacts(path: "/Volumes/Projets", name: "Projets", fsType: "smbfs",
                                                                              mountFrom: "//technicien@nas-bureau.local/Projets"),
                                                        home: "/Users/t")!
        try expect(DiskShareCatalog.matches(byName, mounted: mountedPlain), "même serveur, partage sans égard à la casse")
        try expect(!DiskShareCatalog.matches(byName, mounted: mounted!), "nom Bonjour différent : pas reconnu")
        var byIP = DiskShareLocation(siteKey: site, kind: .smb, server: "10.10.0.31", share: "Sauvegardes")
        let backup = DiskLocationCatalog.location(for: DiskVolumeFacts(path: "/Volumes/Sauvegardes", name: "Sauvegardes", fsType: "smbfs",
                                                                        mountFrom: "//BUREAU;technicien@srv-backup/Sauvegardes"),
                                                  home: "/Users/t")!
        try expect(!DiskShareCatalog.matches(byIP, mounted: backup), "IP saisie, monté par nom : inconnu sans l'appareil")
        byIP.deviceHost = "SRV-BACKUP"
        try expect(DiskShareCatalog.matches(byIP, mounted: backup), "nom d'hôte de l'appareil choisi reconnu")
        let nfs = DiskShareLocation(siteKey: site, kind: .nfs, server: "nas-bureau.local", share: "Projets")
        try expect(!DiskShareCatalog.matches(nfs, mounted: mountedPlain), "autre protocole : pas le même partage")
        let sub = DiskShareLocation(siteKey: site, kind: .smb, server: "nas-bureau", share: "Projets/Essais")
        try expect(DiskShareCatalog.matches(sub, mounted: mountedPlain), "sous-dossier d'un partage monté")

        let ssd = DiskLocation(name: "Macintosh HD", path: "/", testParent: "/Users/t/Library/Caches", kind: .interne, fileSystem: "APFS",
                               freeBytes: 400_000_000_000)
        let usb = DiskLocation(name: "T7", path: "/Volumes/T7", kind: .externe, fileSystem: "exFAT", freeBytes: 500_000_000_000)
        let other = "AUTRE-SITE"
        let saved = [
            DiskShareLocation(siteKey: site, name: "NAS Bureau – Projets", kind: .smb, server: "nas-bureau.local", share: "Projets"),
            DiskShareLocation(siteKey: site, kind: .smb, server: "srv-backup", share: "Sauvegardes", user: "technicien"),
            DiskShareLocation(siteKey: site, name: "Essais USB", kind: .dossier, share: "/Volumes/T7/Essais"),
            DiskShareLocation(siteKey: other, kind: .smb, server: "nas-laval", share: "Plans"),
        ]
        let merged = DiskShareCatalog.merge(discovered: [ssd, usb, mountedPlain], saved: saved, siteKey: site,
                                            folderExists: { $0 == "/Volumes/T7/Essais" })
        try expectEqual(merged.count, 5, "le volume Projets est remplacé par l'emplacement ; l'autre site est absent")
        let projets = merged.first { $0.name == "NAS Bureau – Projets" }!
        try expectEqual(projets.path, "/Volumes/Projets", "monté : chemin du volume")
        try expectEqual(projets.id, saved[0].locationID, "clé d'historique de l'emplacement")
        try expect(projets.isMounted, "monté")
        let backupCard = merged.first { $0.name == "Sauvegardes" }!
        try expect(!backupCard.isMounted, "pas monté")
        try expectEqual(backupCard.path, "smb://srv-backup/Sauvegardes", "adresse à la place du chemin")
        try expect(backupCard.detail.hasSuffix("non monté"), "« non monté » dans le détail : \(backupCard.detail)")
        let essais = merged.first { $0.name == "Essais USB" }!
        try expectEqual(essais.kind, .externe, "dossier sur un disque externe")
        try expectEqual(essais.freeBytes, 500_000_000_000, "espace libre du volume")
        try expectEqual(essais.testParent, "/Volumes/T7/Essais", "essai dans le dossier choisi")
        try expect(merged.firstIndex { $0.name == "Macintosh HD" }! < merged.firstIndex { $0.kind == .reseau }!, "ordre habituel")
        let missing = DiskShareCatalog.merge(discovered: [ssd], saved: [saved[2]], siteKey: site, folderExists: { _ in false })
        let gone = missing.first { $0.savedID != nil }!
        try expect(!gone.isMounted && gone.detail.hasSuffix("introuvable"), "dossier absent : introuvable")
        try expectEqual(DiskShareCatalog.containingVolume(of: "/Users/t/Documents", in: [ssd, usb])?.path, "/", "dossier du disque interne")
        try expectEqual(DiskShareCatalog.containingVolume(of: "/Volumes/T7x/a", in: [ssd, usb])?.path, "/", "« /Volumes/T7x » n'est pas dans T7")
    }

    suite.add("Partages : historique par emplacement et CSV") {
        let share = DiskShareLocation(siteKey: site, name: "NAS", kind: .smb, server: "nas", share: "Projets")
        let location = DiskLocation(name: "NAS", path: "/Volumes/Projets", kind: .reseau, fileSystem: "SMB", server: "nas",
                                    share: "Projets", networkProtocol: .smb, savedID: share.locationID)
        let result = DiskBenchmarkResult(sizeBytes: 1 << 30, passes: 1, writePasses: [80], readPasses: [90])
        let verdict = DiskAdvisor.verdict(kind: .reseau, result: result, context: DiskNetworkContext())
        let saved = DiskTestRecord(date: Date(timeIntervalSince1970: 2_000), location: location, result: result, verdict: verdict)
        try expectEqual(saved.locationID, share.locationID, "clé : l'emplacement")
        try expectEqual(saved.locationPath, "/Volumes/Projets", "chemin mesuré gardé")
        let before = DiskTestRecord(date: Date(timeIntervalSince1970: 1_000),
                                    location: DiskLocation(name: "Projets", path: "/Volumes/Projets", kind: .reseau, fileSystem: "SMB"),
                                    result: result, verdict: verdict)
        try expectEqual(before.locationPath, nil, "volume ordinaire : pas de chemin en double")
        let rows = DiskHistoryStore.records([before, saved], for: location)
        try expectEqual(rows.map(\.date.timeIntervalSince1970), [2_000, 1_000], "tests d'avant l'enregistrement repris, plus récents d'abord")
        var unmounted = location
        unmounted.isMounted = false
        unmounted.path = "smb://nas/Projets"
        try expectEqual(DiskHistoryStore.records([before, saved], for: unmounted).count, 1, "non monté : sa clé seulement")
        let csv = DiskHistoryStore.csv([saved])
        try expect(csv.contains(";/Volumes/Projets;"), "le CSV donne le chemin, pas la clé")
    }

    suite.add("Partages : erreurs NetFS et d'écriture expliquées") {
        try expect(DiskShareProblem.mount(code: 0) == nil, "réussi")
        try expect(DiskShareProblem.mount(code: EEXIST) == nil, "déjà monté : réutilisé")
        try expectEqual(DiskShareProblem.mount(code: EAUTH), .wrongPassword, "EAUTH → mot de passe")
        try expectEqual(DiskShareProblem.mount(code: ENOENT), .shareNotFound, "ENOENT → partage introuvable")
        try expectEqual(DiskShareProblem.mount(code: -5996), .protocolVersion, "ENETFSNOPROTOVERSSUPP → SMB1")
        try expectEqual(DiskShareProblem.mount(code: ENOTSUP), .protocolVersion, "ENOTSUP → version")
        try expectEqual(DiskShareProblem.mount(code: -5045), .passwordExpired, "mot de passe à changer")
        try expectEqual(DiskShareProblem.mount(code: -5999), .accountRestricted, "compte restreint")
        try expectEqual(DiskShareProblem.mount(code: -5998), .noShares, "aucun partage")
        try expectEqual(DiskShareProblem.mount(code: -5997), .authMethod, "méthode d'identification")
        try expectEqual(DiskShareProblem.mount(code: EHOSTUNREACH), .unreachable, "injoignable")
        try expectEqual(DiskShareProblem.mount(code: ETIMEDOUT), .timeout, "délai")
        try expectEqual(DiskShareProblem.mount(code: ECONNREFUSED), .refused, "refusé")
        try expectEqual(DiskShareProblem.mount(code: EACCES), .accessDenied, "accès refusé")
        try expectEqual(DiskShareProblem.mount(code: -128), .cancelled, "annulé")
        try expectEqual(DiskShareProblem.mount(code: 9999), .other(9999), "code inconnu gardé")
        try expectEqual(DiskShareProblem.write(errno: EROFS), .readOnly, "lecture seule")
        try expectEqual(DiskShareProblem.write(errno: EACCES), .writeDenied, "écriture refusée")
        try expectEqual(DiskShareProblem.write(errno: EDQUOT), .diskFull, "quota")
        let smb1 = DiskShareProblem.protocolVersion.message(kind: .smb, server: "vieux-nas", share: "Public")
        try expect(smb1.contains("SMB1") && smb1.contains("SMB2"), "SMB1 nommé et la solution donnée")
        let nfs = DiskShareProblem.shareNotFound.detail(kind: .nfs, server: "nas", share: "/volume1/x")
        try expect(nfs.contains("showmount -e nas"), "NFS : commande des exports")
        let write = DiskShareProblem.writeDenied.detail(kind: .smb, server: "nas", share: "Projets")
        try expect(write.contains("«\u{00A0}nas/Projets\u{00A0}»"), "partage nommé, guillemets français")
        try expect(DiskShareProblem.wrongPassword.concernsCredentials && !DiskShareProblem.timeout.concernsCredentials, "mot de passe en cause")
        for problem in [DiskShareProblem.wrongPassword, .shareNotFound, .protocolVersion, .unreachable, .writeDenied, .other(5)] {
            let text = problem.message(kind: .smb, server: "nas", share: "P")
            try expect(!text.contains(" :") && !text.contains(" ?"), "espace insécable avant la ponctuation : \(text)")
        }
    }

    suite.add("Partages : « Tester le serveur », ports et bilan sur des relevés fixes") {
        try expectEqual(DiskServerCheck.ports.map(\.port), [445, 139, 2049, 548, 80, 443], "ports habituels")
        try expectEqual(DiskServerCheck.portsToTest(kind: .smb), [445, 139, 2049, 548, 80, 443], "SMB : rien d'ajouté")
        try expectEqual(DiskServerCheck.portsToTest(kind: .webdav, customPort: 5006).last, 5006, "port WebDAV choisi ajouté")
        try expectEqual(DiskServerCheck.portsToTest(kind: .smb, customPort: 0x1_0000), [445, 139, 2049, 548, 80, 443], "port invalide ignoré")
        func report(_ open: [UInt16], closed: [UInt16] = [], ping: Double? = 0.8, address: String? = "10.10.0.31") -> DiskServerReport {
            let all = DiskServerCheck.ports.map(\.port)
            let ports = all.map { port in
                PortScanResult(port: port, state: open.contains(port) ? .open : (closed.contains(port) ? .closed : .filtered),
                               rttMs: open.contains(port) ? 1.2 : nil)
            }
            return DiskServerReport(host: "srv-backup", address: address, pingMs: ping, ports: ports)
        }
        let ok = report([445, 443]).assessment(kind: .smb)
        try expectEqual(ok.tone, .success, "SMB ouvert")
        try expect(ok.detail.contains("445"), "port nommé")
        let smb1 = report([139], closed: [445]).assessment(kind: .smb)
        try expectEqual(smb1.title, "SMB1 seulement, probablement", "139 sans 445 : SMB1")
        let nfsInstead = report([2049]).assessment(kind: .smb)
        try expectEqual(nfsInstead.suggested, .nfs, "NFS proposé à la place")
        try expectEqual(nfsInstead.tone, .warning, "avertissement")
        let closed = report([], closed: [445]).assessment(kind: .smb)
        try expect(closed.title.contains("fermé") && closed.detail.contains("service arrêté"), "joignable mais fermé : \(closed.detail)")
        let filtered = report([], ping: 1).assessment(kind: .nfs)
        try expect(filtered.detail.contains("filtré"), "filtré par un pare-feu")
        let down = report([], ping: nil).assessment(kind: .smb)
        try expectEqual(down.tone, .critical, "injoignable")
        try expect(!report([], ping: nil).isReachable, "ni ping ni port")
        let unknown = report([], address: nil).assessment(kind: .smb)
        try expectEqual(unknown.title, "Nom introuvable", "nom non résolu")
        let dav = report([80]).assessment(kind: .webdav, secure: false)
        try expectEqual(dav.tone, .success, "WebDAV en HTTP")
        let davCustom = DiskServerReport(host: "nas", address: "10.0.0.5", pingMs: nil,
                                         ports: [PortScanResult(port: 5006, state: .open)]).assessment(kind: .webdav, customPort: 5006)
        try expectEqual(davCustom.tone, .success, "port WebDAV choisi")
    }

    suite.add("Partages : appareils proposés (Scanner et Inventaire), serveurs de fichiers d'abord") {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let devices = [
            Device(ip: IPv4Address("10.182.122.117")!, hostname: "WKS346", isOnline: true, openPorts: [135, 445, 3389], deviceType: .poste),
            Device(ip: IPv4Address("10.10.0.31")!, hostname: "SRV-BACKUP", isOnline: true, openPorts: [22, 443, 445], deviceType: .serveur),
            Device(ip: IPv4Address("10.182.122.135")!, hostname: "Ce-Mac", isOnline: true, openPorts: [445], deviceType: .poste),
            Device(ip: IPv4Address("10.182.122.111")!, hostname: "Brother", isOnline: true, openPorts: [80, 9100], deviceType: .imprimante),
        ]
        let records = [
            InvRecord(key: "ip:10.10.0.40", mac: nil, ip: IPv4Address("10.10.0.40")!, hostname: "NAS-ARCHIVES", detectedType: .serveur,
                      isOnline: false, openPorts: [2049, 5000], firstSeen: now, lastSeen: now),
            InvRecord(key: "ip:10.10.0.31", mac: nil, ip: IPv4Address("10.10.0.31")!, hostname: "SRV-BACKUP", detectedType: .serveur,
                      openPorts: [139], firstSeen: now, lastSeen: now),
        ]
        let list = DiskShareCandidate.list(devices: devices, records: records, excluding: "10.182.122.135")
        try expectEqual(list.map(\.ip), ["10.10.0.31", "10.10.0.40", "10.182.122.117", "10.182.122.111"],
                        "serveur en ligne, serveur hors ligne, poste avec SMB, puis le reste ; ce Mac exclu")
        try expectEqual(list[0].openPorts, [22, 139, 443, 445], "ports du Scanner et de l'Inventaire réunis")
        try expectEqual(list[0].shareServices, ["SMB", "Web"], "services de partage")
        try expectEqual(list[1].shareServices, ["NFS"], "NFS")
    }

    suite.add("Partages : enregistrement par site, doublons, aucun secret dans le fichier") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-partages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiskShareStore(url: dir.appendingPathComponent("disques-emplacements.json"))
        try expect(store.load().isEmpty, "fichier absent : aucun")
        let a = DiskShareLocation(siteKey: site, name: "NAS", kind: .smb, server: "nas-bureau.local", share: "Projets",
                                  user: "technicien", hasPassword: true, created: Date(timeIntervalSince1970: 10))
        let b = DiskShareLocation(siteKey: "AUTRE", kind: .nfs, server: "nas-laval", share: "/volume1/plans",
                                  created: Date(timeIntervalSince1970: 20))
        var list = DiskShareStore.upsert(a, in: [])
        list = DiskShareStore.upsert(b, in: list)
        var renamed = a
        renamed.name = "NAS du bureau"
        list = DiskShareStore.upsert(renamed, in: list)
        try expectEqual(list.count, 2, "remplacé, pas ajouté")
        try store.save(list)
        let loaded = store.load()
        try expectEqual(loaded, list, "relu à l'identique")
        let text = try String(contentsOf: store.url, encoding: .utf8)
        try expect(!text.contains("\"password\"") && !text.contains("\"motDePasse\"") && text.contains("\"hasPassword\" : true"),
                   "seulement l'indication qu'un mot de passe est au Trousseau")
        try expectEqual(DiskShareCatalog.forSite(loaded, siteKey: site).map(\.displayName), ["NAS du bureau"], "par site")
        let twin = DiskShareLocation(siteKey: site, kind: .smb, server: "NAS-Bureau", share: "/projets/", user: "Technicien")
        try expect(DiskShareStore.duplicate(of: twin, in: loaded) != nil, "même partage, même compte : doublon")
        let otherUser = DiskShareLocation(siteKey: site, kind: .smb, server: "nas-bureau", share: "Projets", user: "invite")
        try expect(DiskShareStore.duplicate(of: otherUser, in: loaded) == nil, "autre compte : permis")
        try expectEqual(DiskShareStore.remove(a.id, from: loaded).count, 1, "supprimé")
        try expectEqual(DiskShareLocation.keychainService, "com.danymenard.netscope.partages", "service du Trousseau")
        try expect(BackupKeychainScan.isOwnService(DiskShareLocation.keychainService), "inclus dans les sauvegardes chiffrées")
        try expect(a.locationID.hasPrefix("emplacement:"), "clé d'historique distincte des chemins")
    }
}
