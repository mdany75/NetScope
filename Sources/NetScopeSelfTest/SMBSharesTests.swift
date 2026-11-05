import Foundation
import NetScopeCore

// Note 72 : partages SMB d'un hôte. Sorties de smbutil recopiées (aucun smbutil lancé, aucun
// réseau) ; le lancement est remplacé par un faux exécutant.

private let synologyOutput = """
Share                                           Type    Comments
-------------------------------
IPC$                                            Pipe    IPC Service (DS920-BUREAU)
Comptabilité                                    Disk    Dossiers de la comptabilité
home                                            Disk    Home directory of marc
homes                                           Disk    user home
photo                                           Disk    System default shared folder
Time Machine                                    Disk    Sauvegardes des Mac
usbshare1                                       Disk
HP_LaserJet_M404                                Printer HP LaserJet Pro M404dn

8 shares listed
"""

private let windowsOutput = "Share                                           Type    Comments\r\n-------------------------------\r\nADMIN$                                          Disk    Remote Admin\r\nC$                                              Disk    Default share\r\nIPC$                                            Pipe    Remote IPC\r\nScans                                           Disk    \r\nprint$                                          Disk    Printer Drivers\r\nBrother DCP-L2640DW                             Printer Brother DCP-L2640DW\r\n\r\n6 shares listed\r\n"

private let frenchOutput = """
Partage                                         Type        Commentaires
-------------------------------
Public                                          Disque      Dossier public
Archives 2024                                   Disque
IPC$                                            IPC         Service IPC
Imprimante RDC                                  Imprimante  Accueil

4 partages listés
"""

private struct FakeRunner: SMBCommandRunner {
    let answers: [String: SMBRunResult]
    let calls: CallLog

    func run(arguments: [String], password: String?, timeout: TimeInterval) async -> SMBRunResult {
        calls.append(arguments.joined(separator: " ") + (password.map { " [mdp:\($0.count)]" } ?? ""))
        return answers[arguments[1]] ?? SMBRunResult(output: "", succeeded: false)
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

func registerSMBSharesTests(_ suite: TestSuite) {
    suite.add("Partages SMB : demande de mot de passe reconnue seulement sur la vraie ligne de smbutil") {
        try expect(SMBPrompt.isPasswordPrompt("Password for 10.0.0.5: "), "Password for … :")
        try expect(SMBPrompt.isPasswordPrompt("x\nPassword:"), "Password: seul")
        try expect(SMBPrompt.isPasswordPrompt("Mot de passe pour nas: "), "en français")
        try expect(!SMBPrompt.isPasswordPrompt("Docs  Disk  Mettre le password:"), "commentaire de partage")
        try expect(!SMBPrompt.isPasswordPrompt("Password for x: ok\n"), "ligne terminée")
        try expect(SMBPrompt.containsListingHeader("Share                 Type    Comments\n-----"), "en-tête vu")
        try expect(!SMBPrompt.containsListingHeader("Password for nas:"), "pas d'en-tête")
    }

    suite.add("Partages SMB : sortie de smbutil d'un NAS (noms avec espaces, accents, imprimante)") {
        let parsed = try SMBShareParser.parse(synologyOutput).unwrap("tableau reconnu")
        try expectEqual(parsed.shares.count, 8, "huit partages")
        try expectEqual(parsed.reportedCount, 8, "« 8 shares listed »")
        try expectEqual(parsed.shares[0], SMBShare(name: "IPC$", kind: .ipc, comment: "IPC Service (DS920-BUREAU)"), "IPC$ en Pipe")
        try expectEqual(parsed.shares[1].name, "Comptabilité", "accent gardé")
        try expectEqual(parsed.shares[5], SMBShare(name: "Time Machine", kind: .disk, comment: "Sauvegardes des Mac"), "nom avec espace")
        try expectEqual(parsed.shares[6].comment, "", "commentaire vide")
        try expectEqual(parsed.shares[7].kind, .printer, "imprimante")
        try expectEqual(parsed.shares[7].comment, "HP LaserJet Pro M404dn", "commentaire de l'imprimante")
    }

    suite.add("Partages SMB : poste Windows (retours chariot, partages cachés en $)") {
        let parsed = try SMBShareParser.parse(windowsOutput).unwrap("tableau reconnu")
        let listing = SMBShareListing(host: "10.182.122.117", shares: parsed.shares, reportedCount: parsed.reportedCount, access: .guest)
        try expectEqual(parsed.shares.map(\.name), ["ADMIN$", "C$", "IPC$", "Scans", "print$", "Brother DCP-L2640DW"], "noms")
        try expectEqual(listing.hiddenCount, 4, "ADMIN$, C$, IPC$, print$")
        try expectEqual(listing.visible(showHidden: false).map(\.name), ["Scans", "Brother DCP-L2640DW"], "cachés masqués")
        try expectEqual(listing.summary, "6 partages (4 cachés)", "résumé")
        try expect(parsed.shares[1].isAdministrative && parsed.shares[0].isAdministrative && parsed.shares[4].isAdministrative,
                   "C$, ADMIN$ et print$ administratifs")
        try expect(!SMBShare(name: "Compta$", kind: .disk).isAdministrative, "partage caché ordinaire")
        try expect(SMBShare(name: "Compta$", kind: .disk).isHidden, "caché")
        try expect(!parsed.shares[2].opensInFinder && parsed.shares[3].opensInFinder && !parsed.shares[5].opensInFinder,
                   "seuls les disques s'ouvrent dans le Finder")
    }

    suite.add("Partages SMB : sortie en français et sortie de smbclient") {
        let french = try SMBShareParser.parse(frenchOutput).unwrap("tableau français")
        try expectEqual(french.shares.map(\.name), ["Public", "Archives 2024", "IPC$", "Imprimante RDC"], "noms")
        try expectEqual(french.shares.map(\.kind), [.disk, .disk, .ipc, .printer], "types")
        try expectEqual(french.reportedCount, 4, "« 4 partages listés »")
        try expectEqual(french.shares[3].comment, "Accueil", "commentaire")

        let smbclient = """
        \tSharename       Type      Comment
        \t---------       ----      -------
        \tdocuments       Disk      Documents partagés
        \tIPC$            IPC       IPC Service (Samba 4.19)
        Reconnecting with SMB1 for workgroup listing.

        \tServer               Comment
        \t---------            -------
        """
        let samba = try SMBShareParser.parse(smbclient).unwrap("tableau de smbclient")
        try expectEqual(samba.shares, [SMBShare(name: "documents", kind: .disk, comment: "Documents partagés"),
                                       SMBShare(name: "IPC$", kind: .ipc, comment: "IPC Service (Samba 4.19)")], "smbclient")
    }

    suite.add("Partages SMB : nom plus long que sa colonne, liste vide, sortie sans tableau") {
        let long = String(repeating: "x", count: 52)
        let output = "Share                                           Type    Comments\n-------------------------------\n\(long) Disk    Long\nUSB Disk 1                                      Disk    Clé\n\n2 shares listed\n"
        let parsed = try SMBShareParser.parse(output).unwrap("tableau")
        try expectEqual(parsed.shares, [SMBShare(name: long, kind: .disk, comment: "Long"),
                                        SMBShare(name: "USB Disk 1", kind: .disk, comment: "Clé")], "colonnes débordées")
        let empty = try SMBShareParser.parse("Share                                           Type    Comments\n-------------------------------\n\n0 shares listed\n").unwrap("vide")
        try expectEqual(empty.shares.count, 0, "aucun partage")
        try expectEqual(empty.reportedCount, 0, "« 0 shares listed »")
        try expect(SMBShareParser.parse("smbutil: server connection failed: Operation timed out\n") == nil, "message d'erreur")
        try expectEqual(SMBShareListing(host: "h", shares: [], access: .guest).summary, "Aucun partage", "résumé vide")
    }

    suite.add("Partages SMB : messages d'erreur clairs") {
        try expectEqual(SMBShareParser.failure(from: "smbutil: server rejected the connection: Authentication error\n", guest: true),
                        .accessDenied(guest: true), "authentification")
        try expectEqual(SMBShareParser.failure(from: "smbutil: server rejected the connection: Permission denied\r\n", guest: false),
                        .accessDenied(guest: false), "permission")
        try expectEqual(SMBShareParser.failure(from: "smbutil: server connection failed: Operation timed out\n", guest: true), .timeout, "délai")
        try expectEqual(SMBShareParser.failure(from: "smbutil: server connection failed: Connection refused\n", guest: true), .refused, "refus")
        try expectEqual(SMBShareParser.failure(from: "smbutil: server connection failed: No route to host\n", guest: true), .unreachable, "route")
        try expectEqual(SMBShareParser.failure(from: "smbutil: server connection failed: Host is down\n", guest: true), .unreachable, "éteint")
        try expectEqual(SMBShareParser.failure(from: "smbutil: server connection failed: Protocol not supported\n", guest: true), .smb1Only, "SMB1")
        try expectEqual(SMBShareParser.failure(from: "smbutil: can't get server address: nodename nor servname provided, or not known\n", guest: true),
                        .hostNotFound, "nom inconnu")
        try expectEqual(SMBShareParser.failure(from: "smbutil: server connection failed: Broken pipe\n", guest: true), .connectionReset, "coupure")
        try expectEqual(SMBShareParser.failure(from: "smbutil: something odd\n", guest: true), .other("something odd"), "autre")
        try expect(SMBShareError.accessDenied(guest: true).suggestsCredentials, "accès refusé : saisir un utilisateur")
        try expect(!SMBShareError.timeout.suggestsCredentials, "délai : pas d'utilisateur")
        try expect(SMBShareError.smb1Only.errorDescription?.contains("SMB1") == true, "message SMB1")
    }

    suite.add("Partages SMB : arguments de smbutil sans mot de passe, adresses smb:// et UNC") {
        try expectEqual(try SMBPaths.arguments(host: "10.0.0.5", mode: .guest), ["view", "-g", "//10.0.0.5"], "invité")
        try expectEqual(try SMBPaths.arguments(host: "10.0.0.5", mode: .anonymous), ["view", "-a", "//10.0.0.5"], "anonyme")
        try expectEqual(try SMBPaths.arguments(host: "nas.local", mode: .user(SMBLogin(field: "BUREAU\\marc"))),
                        ["view", "//BUREAU;marc@nas.local"], "domaine et utilisateur")
        try expectEqual(try SMBPaths.arguments(host: "10.0.0.5", mode: .user(SMBLogin(user: "marc@bureau.local"))),
                        ["view", "//marc%40bureau.local@10.0.0.5"], "« @ » encodé")
        try expectEqual(try SMBPaths.arguments(host: "10.0.0.5", mode: .user(SMBLogin(user: "Jean Tremblay"))),
                        ["view", "//Jean%20Tremblay@10.0.0.5"], "espace encodé")
        try expectThrows(SMBShareError.invalidHost, "hôte avec « / »") { _ = try SMBPaths.arguments(host: "10.0.0.5/x", mode: .guest) }
        try expectThrows(SMBShareError.invalidHost, "option déguisée") { _ = try SMBPaths.arguments(host: "-N", mode: .guest) }
        try expectThrows(SMBShareError.invalidHost, "utilisateur dans l'hôte") { _ = try SMBPaths.arguments(host: "a@b", mode: .guest) }
        try expectThrows(SMBShareError.invalidUser, "deux-points") {
            _ = try SMBPaths.arguments(host: "10.0.0.5", mode: .user(SMBLogin(user: "marc:secret")))
        }
        try expectThrows(SMBShareError.invalidUser, "utilisateur vide") {
            _ = try SMBPaths.arguments(host: "10.0.0.5", mode: .user(SMBLogin(user: " ")))
        }
        try expectEqual(SMBPaths.url(host: "10.0.0.5", share: "Time Machine")?.absoluteString, "smb://10.0.0.5/Time%20Machine", "URL encodée")
        try expectEqual(SMBPaths.url(host: "10.0.0.5", share: "Comptabilité")?.absoluteString, "smb://10.0.0.5/Comptabilit%C3%A9", "accent")
        try expectEqual(SMBPaths.url(host: "10.0.0.5", share: "a/b#c")?.absoluteString, "smb://10.0.0.5/a%2Fb%23c", "« / » et « # » encodés")
        try expectEqual(SMBPaths.readable(host: "10.0.0.5", share: "Time Machine"), "smb://10.0.0.5/Time Machine", "lisible")
        try expectEqual(SMBPaths.unc(host: "10.0.0.5", share: "Scans"), "\\\\10.0.0.5\\Scans", "UNC")
        try expectEqual(SMBLogin(field: "BUREAU\\marc").display, "BUREAU\\marc", "affichage")
    }

    suite.add("Partages SMB : invité refusé, puis anonyme ; mot de passe redemandé = refusé") {
        let calls = CallLog()
        let denied = SMBRunResult(output: "smbutil: server rejected the connection: Authentication error\n", succeeded: false)
        let runner = FakeRunner(answers: ["-g": denied, "-a": SMBRunResult(output: windowsOutput, succeeded: true)], calls: calls)
        let listing = try await SMBShareLister(runner: runner).list(host: "10.182.122.117")
        try expectEqual(listing.access, .anonymous, "liste obtenue en anonyme")
        try expectEqual(listing.shares.count, 6, "partages")
        try expectEqual(calls.all, ["view -g //10.182.122.117", "view -a //10.182.122.117"], "invité puis anonyme, sans mot de passe")

        let both = FakeRunner(answers: ["-g": denied, "-a": denied], calls: CallLog())
        do {
            _ = try await SMBShareLister(runner: both).list(host: "10.182.122.117")
            try expect(false, "erreur attendue")
        } catch let error as SMBShareError {
            try expectEqual(error, .accessDenied(guest: true), "invité et anonyme refusés")
        }

        let userCalls = CallLog()
        let target = "//BUREAU;marc@10.182.122.117"
        let ok = FakeRunner(answers: [target: SMBRunResult(output: windowsOutput, succeeded: true, passwordPrompts: 1)], calls: userCalls)
        let user = try await SMBShareLister(runner: ok).list(host: "10.182.122.117", login: SMBLogin(field: "BUREAU\\marc"), password: "s3cret")
        try expectEqual(user.access, .user("BUREAU\\marc"), "accès utilisateur")
        try expectEqual(userCalls.all, ["view //BUREAU;marc@10.182.122.117 [mdp:6]"], "mot de passe transmis à part, jamais dans les arguments")

        let reprompt = FakeRunner(answers: [target: SMBRunResult(output: "", succeeded: true, passwordPrompts: 2)], calls: CallLog())
        do {
            _ = try await SMBShareLister(runner: reprompt).list(host: "10.182.122.117", login: SMBLogin(field: "BUREAU\\marc"), password: "x")
            try expect(false, "erreur attendue")
        } catch let error as SMBShareError {
            try expectEqual(error, .accessDenied(guest: false), "mot de passe redemandé")
        }

        let slow = FakeRunner(answers: ["-g": SMBRunResult(output: "", succeeded: false, timedOut: true)], calls: CallLog())
        do {
            _ = try await SMBShareLister(runner: slow).list(host: "10.0.0.9")
            try expect(false, "erreur attendue")
        } catch let error as SMBShareError {
            try expectEqual(error, .timeout, "délai de NetScope dépassé")
        }
    }

    suite.add("Partages SMB : section utile pour un port 445 ou 139 ouvert, ou un NAS") {
        try expect(SMBRelevance.isRelevant(openPorts: [135, 445], vendor: "Dell"), "poste Windows")
        try expect(SMBRelevance.isRelevant(openPorts: [139], vendor: nil), "NetBIOS")
        try expect(SMBRelevance.isRelevant(openPorts: [80, 5000], vendor: "Synology Incorporated"), "NAS Synology")
        try expect(!SMBRelevance.isRelevant(openPorts: [80, 443], vendor: "Cisco"), "switch")
    }
}

private extension Optional {
    func unwrap(_ message: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
        return value
    }
}
