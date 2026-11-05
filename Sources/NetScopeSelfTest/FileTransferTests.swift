import Foundation
import NetScopeCore

// Note 50 : FTP, FTPS et SFTP. Réponses fixes pour l'analyse ; un mini serveur FTP sur 127.0.0.1
// (jamais d'autre adresse) pour le client de bout en bout. Aucun autre accès réseau.

func registerFileTransferTests(_ suite: TestSuite) {
    let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15))!
    }()
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!

    // MARK: Réponses

    suite.add("FTP : réponses sur une et plusieurs lignes") {
        let replies = try FTPReplyParser.parseAll("""
        220-Bienvenue sur le NAS
        220-Deuxième ligne
         ligne libre
        220 Prêt
        331 Please specify the password.
        230 Login successful.
        150 Here comes the directory listing.
        226 Directory send OK.

        """.replacingOccurrences(of: "\n", with: "\r\n"))
        try expectEqual(replies.map(\.code), [220, 331, 230, 150, 226], "codes")
        try expectEqual(replies[0].lines, ["Bienvenue sur le NAS", "Deuxième ligne", "ligne libre", "Prêt"], "lignes")
        try expect(replies[1].isIntermediate, "331 intermédiaire")
        try expect(replies[3].isPreliminary, "150 préliminaire")
        try expect(replies[4].isSuccess, "226 réussite")
        try expectEqual(replies[0].summary, "220 Bienvenue sur le NAS", "résumé")
        var parser = FTPReplyParser()
        do {
            _ = try parser.feed("SSH-2.0-OpenSSH_9.6")
            throw TestFailure(message: "une bannière SSH n'est pas une réponse FTP", file: #fileID, line: #line)
        } catch is FileTransferError {}
        try expectEqual(try parser.feed("230"), FTPReply(code: 230, lines: [""]), "code seul")
    }

    suite.add("FTP : PASV, EPSV, PWD, FEAT, PORT et EPRT") {
        let pasv = FTPReply(code: 227, lines: ["Entering Passive Mode (192,168,1,10,195,149)."])
        let endpoint = try FTPResponse.passiveEndpoint(pasv)
        try expectEqual(endpoint.host, "192.168.1.10", "hôte PASV")
        try expectEqual(endpoint.port, 50_069, "port PASV")
        // Variante sans parenthèses (vieux serveurs).
        try expectEqual(try FTPResponse.passiveEndpoint(FTPReply(code: 227, lines: ["=10,0,0,5,4,1"])).port, 1025, "PASV sans parenthèses")
        do {
            _ = try FTPResponse.passiveEndpoint(FTPReply(code: 227, lines: ["(300,1,1,1,1,1)"]))
            throw TestFailure(message: "octet hors limites accepté", file: #fileID, line: #line)
        } catch is FileTransferError {}
        try expectEqual(try FTPResponse.extendedPassivePort(FTPReply(code: 229, lines: ["Entering Extended Passive Mode (|||50069|)"])), 50_069, "EPSV")
        try expectEqual(try FTPResponse.extendedPassivePort(FTPReply(code: 229, lines: ["EPSV ok (!!!6446!)"])), 6446, "délimiteur « ! »")
        try expectEqual(try FTPResponse.quotedPath(FTPReply(code: 257, lines: ["\"/home/ftp/Mon \"\"dossier\"\"\" is current directory"])),
                        "/home/ftp/Mon \"dossier\"", "guillemets doublés")
        try expectEqual(try FTPResponse.quotedPath(FTPReply(code: 257, lines: ["/pub"])), "/pub", "PWD sans guillemets")
        let feat = try FTPReplyParser.parseAll("211-Features:\r\n MLST type*;size*;modify*;\r\n UTF8\r\n EPSV\r\n REST STREAM\r\n211 End\r\n")[0]
        let features = FTPResponse.features(feat)
        try expectEqual(features["MLST"], "type*;size*;modify*;", "MLST")
        try expect(features["UTF8"] != nil && features["EPSV"] != nil, "UTF8 et EPSV")
        try expectEqual(features["REST"], "STREAM", "REST STREAM")
        try expectEqual(try FTPResponse.portCommand(host: "10.0.0.5", port: 50_069), "PORT 10,0,0,5,195,149", "PORT")
        try expectEqual(FTPResponse.extendedPortCommand(host: "10.0.0.5", port: 50_069), "EPRT |1|10.0.0.5|50069|", "EPRT IPv4")
        try expectEqual(FTPResponse.extendedPortCommand(host: "fe80::1", port: 21), "EPRT |2|fe80::1|21|", "EPRT IPv6")
        try expectEqual(FTPResponse.size(FTPReply(code: 213, lines: ["1048576"])), 1_048_576, "SIZE")
        try expect(FTPResponse.modificationDate(FTPReply(code: 213, lines: ["20261104153012"])) != nil, "MDTM")
    }

    // MARK: Listes

    suite.add("FTP : liste MLSD") {
        let text = "type=cdir;modify=20261104101500; .\r\ntype=pdir; ..\r\n"
            + "type=dir;modify=20261104101500;unix.mode=0755; firmware\r\n"
            + "type=file;size=1048576;modify=20251231235959.123;unix.mode=0644;unix.owner=ftp; config; backup.cfg\r\n"
            + "type=OS.unix=slink:/pub/v7;modify=20260101000000; latest\r\n"
        let entries = FTPListing.parseMLSD(text, directory: "/pub")
        try expectEqual(entries.map(\.name), ["firmware", "config; backup.cfg", "latest"], "noms (« ; » permis dans le nom)")
        try expectEqual(entries[0].kind, .directory, "dossier")
        try expectEqual(entries[0].permissions, "rwxr-xr-x", "droits")
        try expectEqual(entries[1].size, 1_048_576, "taille")
        try expectEqual(entries[1].path, "/pub/config; backup.cfg", "chemin")
        try expectEqual(entries[1].owner, "ftp", "propriétaire")
        try expectEqual(entries[2].kind, .link, "lien")
        try expectEqual(entries[1].modified.map { utc.component(.year, from: $0) }, 2025, "date MLSD")
    }

    suite.add("FTP : liste Unix (ls -l), année devinée, liens, espaces") {
        let text = """
        total 12
        drwxr-xr-x    2 ftp      ftp          4096 Nov  4 10:15 firmware
        -rw-r--r--    1 1000     1000      1048576 Mar 12  2025 config backup.cfg
        lrwxrwxrwx    1 root     root            7 Jan  1  2024 latest -> v7.4.4
        -rw-r--r--    1 ftp      ftp           220 Dec 24 08:00 vieux.txt
        drwxr-xr-x    3 ftp      ftp          4096 Nov  1 09:00 .
        -rwsr-xr-T    1 ftp      ftp             0 Feb  2  2020   deux espaces.txt
        """
        let entries = FTPListing.parseLIST(text, directory: "/")
        try expectEqual(entries.map(\.name), ["firmware", "config backup.cfg", "latest", "vieux.txt", "  deux espaces.txt"], "noms")
        try expectEqual(entries[0].kind, .directory, "dossier")
        try expectEqual(entries[0].size, nil, "pas de taille pour un dossier")
        try expectEqual(entries[1].size, 1_048_576, "taille")
        try expectEqual(entries[1].owner, "1000", "propriétaire")
        try expectEqual(entries[2].linkTarget, "v7.4.4", "cible du lien")
        try expectEqual(entries[2].name, "latest", "nom du lien")
        // « Nov  4 10:15 » : cette année ; « Dec 24 08:00 » : l'an dernier (pas dans le futur).
        let lines = FTPLineSplitter.lines(in: text)
        let nov = FTPListing.parseLISTLine(lines[1], directory: "/", now: now)
        let dec = FTPListing.parseLISTLine(lines[4], directory: "/", now: now)
        try expectEqual(nov?.modified.map { utc.component(.year, from: $0) }, 2026, "année en cours")
        try expectEqual(dec?.modified.map { utc.component(.year, from: $0) }, 2025, "année précédente")
        try expectEqual(entries.last?.octalPermissions, "754", "droits spéciaux (s, T)")
        try expectEqual(entries[1].octalPermissions, "644", "644")
    }

    suite.add("FTP : liste DOS / IIS") {
        let text = "11-04-26  10:15AM       <DIR>          firmware\r\n03-12-2025  02:30PM              1048576 config backup.cfg\r\n"
        let entries = FTPListing.parseLIST(text, directory: "/data")
        try expectEqual(entries.count, 2, "deux éléments")
        try expectEqual(entries[0].kind, .directory, "dossier")
        try expectEqual(entries[1].name, "config backup.cfg", "nom avec espace")
        try expectEqual(entries[1].size, 1_048_576, "taille")
        try expectEqual(entries[1].modified.map { utc.component(.hour, from: $0) }, 14, "14 h (PM)")
        try expectEqual(entries[0].modified.map { utc.component(.year, from: $0) }, 2026, "année sur deux chiffres")
    }

    suite.add("Transferts : noms piégés d’une liste distante ignorés (« ../ »)") {
        try expect(FTPListing.parseMLSDLine("type=file;size=1; ../../Library/LaunchAgents/x.plist", directory: "/") == nil, "MLSD : « ../ » refusé")
        try expect(FTPListing.parseMLSDLine("type=file;size=1; a/b", directory: "/") == nil, "MLSD : « / » refusé")
        try expect(FTPListing.parseLISTLine("-rw-r--r--    1 ftp      ftp   1 Nov  4 10:15 ../x.plist", directory: "/") == nil, "LIST : « ../ » refusé")
        try expect(FTPListing.parseLIST("11-04-26  10:15AM   1 ..\\x.plist\r\n", directory: "/").isEmpty, "DOS : « \\ » refusé")
        try expect(RemotePath.isSafeEntryName("config; backup.cfg") && !RemotePath.isSafeEntryName(".."), "noms ordinaires gardés")
        // Un serveur qui contourne les analyseurs (SFTP, faux client) : walk ignore l'entrée.
        let trapped = TrappedListing()
        let walked = try await trapped.walk("/pub")
        try expectEqual(walked.map(\.relative), ["sain", "sain/ok.txt"], "seuls les noms sûrs sont parcourus")
    }

    // MARK: Chemins

    suite.add("Transferts : chemins, noms et guillemets sftp") {
        try expectEqual(RemotePath.join("/", "pub"), "/pub", "racine")
        try expectEqual(RemotePath.join("/pub/", "a b"), "/pub/a b", "barre finale")
        try expectEqual(RemotePath.join("/pub", "../../etc"), "/etc", "« .. » jamais au-dessus de la racine")
        try expectEqual(RemotePath.parent("/pub/firmware"), "/pub", "parent")
        try expectEqual(RemotePath.parent("/pub"), "/", "parent de /pub")
        try expectEqual(RemotePath.parent("/"), "/", "parent de /")
        try expectEqual(RemotePath.name("/pub/a.bin"), "a.bin", "nom")
        try expectEqual(RemotePath.normalize("//pub/./x//y/.."), "/pub/x", "normalisation")
        try expectEqual(RemotePath.breadcrumbs("/pub/fw").map(\.path), ["/", "/pub", "/pub/fw"], "fil d'Ariane")
        try expectThrows(FileTransferError.invalidName("a\r\nDELE x"), "retour à la ligne refusé") { _ = try RemotePath.validate("a\r\nDELE x") }
        try expectThrows(FileTransferError.invalidName("a/b"), "« / » refusé dans un nom") { _ = try RemotePath.validateName("a/b") }
        try expectThrows(FileTransferError.invalidName(".."), "« .. » refusé") { _ = try RemotePath.validateName("..") }
        try expectEqual(try RemotePath.validateName("  Nouveau dossier "), "Nouveau dossier", "espaces retirés")
        try expectEqual(RemotePath.safeLocalName("../../etc/passwd"), "passwd", "nom local sans « ../ »")
        try expectEqual(RemotePath.safeLocalName("a:b"), "a-b", "deux-points du Finder")
        try expectEqual(try RemotePath.sftpQuoted("/pub/a \"b\" *.cfg"), "\"/pub/a \\\"b\\\" \\*.cfg\"", "guillemets et motifs échappés")
        try expectEqual(FileTransferFormat.size(845), "845\u{00A0}o", "octets")
        try expectEqual(FileTransferFormat.size(1_200_000), "1,2\u{00A0}Mo", "Mo")
        try expectEqual(FileTransferFormat.remaining(185), "3\u{00A0}min 05\u{00A0}s", "temps restant")
    }

    // MARK: SFTP

    suite.add("SFTP : ligne de commande, BatchMode, clé, port") {
        var settings = FileTransferSettings(sftpAuth: .key, keyPath: "~/.ssh/id_ed25519")
        var endpoint = FileTransferEndpoint(proto: .sftp, host: "10.10.0.20", port: 2222, user: "admin-nas", settings: settings)
        let args = SFTPCommand.arguments(endpoint, controlDirectory: "/tmp/x")
        let batchMode = args.firstIndex(of: "BatchMode=no")
        let dashB = args.firstIndex(of: "-b")
        try expect(batchMode != nil && dashB != nil && batchMode! < dashB!, "BatchMode=no avant -b (première valeur gagnante)")
        try expectEqual(args.last, "admin-nas@10.10.0.20", "destination en dernier")
        try expect(args.contains("-P") && args.contains("2222"), "port")
        try expect(args.contains("IdentitiesOnly=yes"), "clé seule")
        try expect(args.contains(NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath), "~ développé")
        try expect(args.contains("StrictHostKeyChecking=ask"), "serveur inconnu refusé par défaut")
        endpoint.acceptNewHostKey = true
        try expect(SFTPCommand.arguments(endpoint, controlDirectory: "/tmp/x").contains("StrictHostKeyChecking=accept-new"), "après accord")
        settings.sftpAuth = .password
        endpoint = FileTransferEndpoint(proto: .sftp, host: "fe80::1", user: "", secret: "s3cret", settings: settings)
        let passwordArgs = SFTPCommand.arguments(endpoint, controlDirectory: "/tmp/x")
        try expect(passwordArgs.contains("PubkeyAuthentication=no"), "mot de passe seulement")
        try expect(!passwordArgs.contains("-P"), "port 22 par défaut")
        try expect(!passwordArgs.joined().contains("s3cret"), "le secret n'est jamais dans les arguments")
        try expectEqual(passwordArgs.last, "[fe80::1]", "IPv6 entre crochets")
        let env = SFTPCommand.environment(endpoint, askpass: "/tmp/x/askpass.sh")
        try expectEqual(env["SSH_ASKPASS_REQUIRE"], "force", "askpass forcé")
        try expectEqual(env["NETSCOPE_SFTP_SECRET"], "s3cret", "secret par l'environnement")
        try expect(!SFTPCommand.askpassScript.contains("s3cret"), "script sans secret")
    }

    suite.add("SFTP : sortie de ls, pwd et erreurs expliquées") {
        let output = """
        sftp> cd "/volume1/backup"
        sftp> ls -lan
        drwxr-xr-x    5 1026     100          4096 Nov  4 10:15 .
        drwxr-xr-x    9 0        0            4096 Oct  1  2025 ..
        -rw-r--r--    1 1026     100       2048000 Nov  3 22:00 sw-core-01.cfg
        drwxr-xr-x    2 1026     100          4096 Nov  4 10:15 logs
        sftp> bye
        """
        let entries = SFTPOutput.listing(output, directory: "/volume1/backup", now: now)
        try expectEqual(entries.map(\.name), ["sw-core-01.cfg", "logs"], "écho et . .. ignorés")
        try expectEqual(entries[0].path, "/volume1/backup/sw-core-01.cfg", "chemin")
        try expectEqual(SFTPOutput.workingDirectory("sftp> pwd\nRemote working directory: /home/admin\n"), "/home/admin", "pwd")
        let unknown = """
        The authenticity of host '10.10.0.20 (10.10.0.20)' can't be established.
        ED25519 key fingerprint is SHA256:AbCdEf0123456789+/xyzXYZ.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        Host key verification failed.
        Connection closed
        """
        try expectEqual(SFTPOutput.error(stderr: unknown, status: 255, host: "10.10.0.20"),
                        .unknownHostKey(fingerprint: "SHA256:AbCdEf0123456789+/xyzXYZ"), "serveur inconnu et son empreinte")
        try expectEqual(SFTPOutput.error(stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.", status: 255, host: "x"),
                        .hostKeyChanged, "clé changée")
        try expectEqual(SFTPOutput.error(stderr: "admin@10.0.0.2: Permission denied (publickey,password).\r\nConnection closed", status: 255, host: "x"),
                        .loginFailed("le serveur SSH refuse l’identification"), "identification refusée")
        try expectEqual(SFTPOutput.error(stderr: "ssh: connect to host 10.0.0.9 port 22: Connection refused\r\nConnection closed", status: 255, host: "10.0.0.9"),
                        .connectionFailed("le serveur refuse la connexion (port fermé\u{00A0}?)"), "port fermé")
        try expectEqual(SFTPOutput.error(stderr: "remote open(\"/etc/shadow\"): Permission denied", status: 1, host: "x"),
                        .permissionDenied("/etc/shadow"), "droits")
        try expectEqual(SFTPOutput.error(stderr: "File \"/nope\" not found.", status: 1, host: "x"), .notFound("/nope"), "introuvable")
    }

    // MARK: File des transferts

    suite.add("Transferts : débit, avancement, reprises, noms libres") {
        var meter = TransferRateMeter(window: 4)
        let start = Date(timeIntervalSince1970: 1_000)
        try expect(meter.record(bytes: 0, at: start) == nil, "pas de débit sans recul")
        _ = meter.record(bytes: 1_000_000, at: start.addingTimeInterval(1))
        let rate = meter.record(bytes: 2_000_000, at: start.addingTimeInterval(2))
        try expectEqual(rate.map { Int($0) }, 1_000_000, "1 Mo/s")
        var job = TransferJob(direction: .download, localURL: URL(fileURLWithPath: "/tmp/a.bin"), remotePath: "/pub/a.bin", totalBytes: 4_000_000)
        job.transferredBytes = 1_000_000
        job.bytesPerSecond = 1_000_000
        try expectEqual(job.fraction, 0.25, "25 %")
        try expectEqual(job.remainingSeconds, 3, "3 s restantes")
        try expectEqual(job.progressLabel, "1\u{00A0}Mo sur 4\u{00A0}Mo", "libellé")
        try expectEqual(job.name, "a.bin", "nom")
        try expect(TransferRetryPolicy.shouldRetry(FileTransferError.timeout, attempts: 0), "délai dépassé : reprise")
        try expect(!TransferRetryPolicy.shouldRetry(FileTransferError.loginFailed("x"), attempts: 0), "mot de passe : pas de reprise")
        try expect(!TransferRetryPolicy.shouldRetry(FileTransferError.timeout, attempts: 3), "trois essais au plus")
        try expectEqual(TransferRetryPolicy.delay(forAttempt: 2), 5, "délai du 2e essai")
        try expectEqual(TransferPlanner.uniqueName("config.cfg", taken: ["config.cfg", "config (2).cfg"]), "config (3).cfg", "nom libre")
        try expectEqual(TransferPlanner.uniqueName("logs", taken: ["logs"]), "logs (2)", "dossier")
        // Dossier à envoyer : fichiers cachés ignorés, sous-dossiers créés.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ns-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sous"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("sous/b.txt"))
        try Data("x".utf8).write(to: folder.appendingPathComponent(".cache"))
        let items = TransferPlanner.uploadItems(folder, into: "/up")
        let root = "/up/" + folder.lastPathComponent
        try expectEqual(Set(items.map(\.remotePath)), [root, root + "/a.txt", root + "/sous", root + "/sous/b.txt"], "chemins distants")
        try expectEqual(items.first?.isDirectory, true, "le dossier d'abord")
    }

    // MARK: Connexions du carnet

    suite.add("Accès : connexions FTP, FTPS et SFTP du carnet") {
        try expectEqual(RemoteProtocol.forPort(21), .ftp, "port 21")
        try expectEqual(RemoteProtocol.forPort(990), .ftps, "port 990")
        try expectEqual(RemoteProtocol.forPort(22), .ssh, "le 22 reste SSH")
        try expect(RemoteProtocol.ftp.isInsecure && !RemoteProtocol.ftps.isInsecure && !RemoteProtocol.sftp.isInsecure, "FTP non chiffré")
        // Ancienne connexion sans « transfer » : réglages par défaut.
        let old = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"SW","proto":"ssh","host":"10.0.0.2","port":22,"username":"a",
         "folder":"","isFavorite":false,"note":"","createdAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RemoteConnection.self, from: Data(old.utf8))
        try expectEqual(decoded.transfer, FileTransferSettings(), "réglages par défaut")
        var ftps = RemoteConnection(name: "NAS", proto: .ftps, host: "10.10.0.20", port: 21, username: "admin",
                                    transfer: FileTransferSettings(tlsMode: .explicit))
        try expectEqual(try RemoteLauncher.plan(for: ftps), .fileBrowser(address: "ftpes://admin@10.10.0.20/"), "FTPS explicite sur 21")
        ftps.transfer.tlsMode = .implicit
        ftps.port = 990
        try expectEqual(RemoteLauncher.fileTransferURL(for: ftps), "ftps://admin@10.10.0.20/", "FTPS implicite")
        let sftp = RemoteConnection(name: "NAS", proto: .sftp, host: "10.10.0.20", port: 2222)
        try expectEqual(RemoteLauncher.fileTransferURL(for: sftp), "sftp://10.10.0.20:2222/", "port non standard")
        // Aller-retour JSON : les réglages sont conservés, sans secret.
        var withSettings = sftp
        withSettings.transfer = FileTransferSettings(dataMode: .active, sftpAuth: .key, keyPath: "~/.ssh/id_ed25519", remoteDirectory: "/volume1")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try decoder.decode(RemoteConnection.self, from: encoder.encode(withSettings))
        try expectEqual(again.transfer, withSettings.transfer, "aller-retour")
        try expectThrows(QuickLoginError.unsupportedProtocol(.sftp), "pas de connexion rapide en Terminal pour SFTP") {
            _ = try QuickLogin.plan(for: QuickLoginChoice(proto: .sftp, host: "10.0.0.2"), name: "x")
        }
    }

    // MARK: Bout en bout (127.0.0.1)

    /// Dossier temporaire, serveur sur 127.0.0.1 (port choisi par le système) et client.
    func withServer(allowWrite: Bool = true, mlsd: Bool = true, epsv: Bool = true, dataMode: FTPDataMode = .passive,
                    password: String = "essai", _ body: (FTPClient, URL, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ns-ftp-\(UUID().uuidString)")
        let root = base.appendingPathComponent("racine")
        let local = base.appendingPathComponent("mac")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("firmware"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("secret hors racine".utf8).write(to: base.appendingPathComponent("hors.txt"))
        defer { try? FileManager.default.removeItem(at: base) }
        let server = FTPMiniServer(configuration: .init(root: root, port: 0, bindHost: "127.0.0.1", user: "netscope", password: "essai",
                                                        allowWrite: allowWrite, offerMLSD: mlsd, offerEPSV: epsv))
        let port = try await server.start()
        defer { server.stop() }
        let client = FTPClient(endpoint: FileTransferEndpoint(proto: .ftp, host: "127.0.0.1", port: Int(port), user: "netscope",
                                                              secret: password, settings: FileTransferSettings(dataMode: dataMode), timeout: 5))
        do {
            try await body(client, root, local)
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    suite.add("FTP (127.0.0.1) : connexion, liste, envoi, réception, reprise") {
        try await withServer { client, root, local in
            let home = try await client.connect()
            try expectEqual(home, "/", "dossier de départ")
            try expect(client.serverFeatures["MLST"] != nil, "MLSD annoncé")
            let payload = Data((0..<300_000).map { UInt8($0 % 251) })
            try payload.write(to: root.appendingPathComponent("firmware/fw.bin"))
            let listing = try await client.list("/firmware")
            try expectEqual(listing.map(\.name), ["fw.bin"], "liste MLSD")
            try expectEqual(listing.first?.size, 300_000, "taille")
            // Réception complète.
            let target = local.appendingPathComponent("fw.bin")
            try await client.download("/firmware/fw.bin", to: target, resume: false) { _ in }
            try expectEqual(try Data(contentsOf: target), payload, "fichier reçu identique")
            // Reprise : un fichier local partiel est complété (REST).
            try payload.prefix(100_000).write(to: target)
            let progress = ProgressBox()
            try await client.download("/firmware/fw.bin", to: target, resume: true) { progress.set($0) }
            try expectEqual(try Data(contentsOf: target), payload, "reprise de la réception")
            try expectEqual(progress.value, 300_000, "avancement final, reprise comprise")
            // Envoi, puis reprise d'un envoi interrompu (APPE).
            let upload = local.appendingPathComponent("config.cfg")
            let config = Data(String(repeating: "hostname SW-CORE-01\n", count: 5_000).utf8)
            try config.write(to: upload)
            try await client.upload(upload, to: "/config.cfg", resume: false) { _ in }
            try expectEqual(try Data(contentsOf: root.appendingPathComponent("config.cfg")), config, "fichier envoyé identique")
            try config.prefix(30_000).write(to: root.appendingPathComponent("config.cfg"))
            try await client.upload(upload, to: "/config.cfg", resume: true) { _ in }
            try expectEqual(try Data(contentsOf: root.appendingPathComponent("config.cfg")), config, "reprise de l'envoi")
            try expectEqual(try await client.size(of: "/config.cfg"), Int64(config.count), "SIZE")
        }
    }

    suite.add("FTP (127.0.0.1) : dossiers, renommer, supprimer, confinement") {
        try await withServer { client, root, _ in
            _ = try await client.connect()
            try await client.makeDirectory("/Nouveau dossier")
            try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Nouveau dossier").path), "dossier créé")
            try Data("x".utf8).write(to: root.appendingPathComponent("Nouveau dossier/a.txt"))
            try await client.rename("/Nouveau dossier", to: "/Journaux")
            try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Journaux/a.txt").path), "renommé")
            let entry = try await client.list("/").first { $0.name == "Journaux" }
            try expect(entry != nil, "dossier listé")
            let removed = try await client.deleteRecursively(entry!)
            try expectEqual(removed, 2, "fichier puis dossier supprimés")
            try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Journaux").path), "plus de dossier")
            // « ../ » ne sort jamais du dossier partagé.
            let escaped = try await client.list("/../..")
            try expect(!escaped.contains { $0.name == "hors.txt" }, "rien au-dessus de la racine")
            do {
                try await client.download("/../hors.txt", to: root.deletingLastPathComponent().appendingPathComponent("mac/h.txt"), resume: false) { _ in }
                throw TestFailure(message: "fichier hors racine reçu", file: #fileID, line: #line)
            } catch let error as FileTransferError {
                try expectEqual(error, .notFound("/../hors.txt"), "hors racine : introuvable")
            }
            // Une erreur du serveur ne ferme pas la session.
            try expectEqual(try await client.list("/").map(\.name), ["firmware"], "session toujours ouverte")
        }
    }

    suite.add("FTP (127.0.0.1) : repli sur LIST et PASV, mode actif") {
        try await withServer(mlsd: false, epsv: false) { client, root, _ in
            _ = try await client.connect()
            try Data("abc".utf8).write(to: root.appendingPathComponent("firmware/a.txt"))
            let listing = try await client.list("/firmware")
            try expectEqual(listing.map(\.name), ["a.txt"], "LIST par PASV")
            try expectEqual(listing.first?.size, 3, "taille LIST")
        }
        try await withServer(dataMode: .active) { client, root, local in
            _ = try await client.connect()
            try Data("actif".utf8).write(to: root.appendingPathComponent("firmware/b.txt"))
            try expectEqual(try await client.list("/firmware").map(\.name), ["b.txt"], "liste en mode actif (EPRT)")
            try await client.download("/firmware/b.txt", to: local.appendingPathComponent("b.txt"), resume: false) { _ in }
            try expectEqual(try String(contentsOf: local.appendingPathComponent("b.txt"), encoding: .utf8), "actif", "réception en mode actif")
        }
    }

    suite.add("FTP (127.0.0.1) : mauvais mot de passe, serveur en lecture seule") {
        try await withServer(password: "faux") { client, _, _ in
            do {
                _ = try await client.connect()
                throw TestFailure(message: "connexion acceptée avec un faux mot de passe", file: #fileID, line: #line)
            } catch let error as FileTransferError {
                guard case .loginFailed = error else { throw TestFailure(message: "erreur inattendue : \(error)", file: #fileID, line: #line) }
            }
        }
        try await withServer(allowWrite: false) { client, root, local in
            _ = try await client.connect()
            let file = local.appendingPathComponent("x.txt")
            try Data("x".utf8).write(to: file)
            do {
                try await client.upload(file, to: "/x.txt", resume: false) { _ in }
                throw TestFailure(message: "envoi accepté en lecture seule", file: #fileID, line: #line)
            } catch let error as FileTransferError {
                guard case .permissionDenied = error else { throw TestFailure(message: "erreur inattendue : \(error)", file: #fileID, line: #line) }
            }
            try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("x.txt").path), "rien d'écrit")
        }
    }
}

/// Faux serveur dont la liste contient un nom piégé (aucun réseau).
final class TrappedListing: RemoteFileTransfer, @unchecked Sendable {
    func connect() async throws -> String { "/" }
    func list(_ path: String) async throws -> [RemoteFileEntry] {
        if path == "/pub" {
            return [RemoteFileEntry(name: "../../Library/LaunchAgents/x.plist", path: "/x.plist", kind: .file, size: 1, modified: nil),
                    RemoteFileEntry(name: "sain", path: "/pub/sain", kind: .directory, size: nil, modified: nil)]
        }
        return [RemoteFileEntry(name: "ok.txt", path: path + "/ok.txt", kind: .file, size: 1, modified: nil),
                RemoteFileEntry(name: "..", path: "/", kind: .directory, size: nil, modified: nil)]
    }
    func size(of path: String) async throws -> Int64? { nil }
    func download(_ remotePath: String, to localURL: URL, resume: Bool, progress: @escaping FileTransferProgress) async throws {}
    func upload(_ localURL: URL, to remotePath: String, resume: Bool, progress: @escaping FileTransferProgress) async throws {}
    func makeDirectory(_ path: String) async throws {}
    func rename(_ from: String, to: String) async throws {}
    func deleteFile(_ path: String) async throws {}
    func removeDirectory(_ path: String) async throws {}
    func close() async {}
}

/// Dernière valeur d'avancement reçue (fermetures @Sendable).
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int64 = 0
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ newValue: Int64) { lock.lock(); _value = newValue; lock.unlock() }
}
