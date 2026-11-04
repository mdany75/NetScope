import Foundation
@testable import NetScopeCore

// Tests de la note 52 (nom d'utilisateur à la connexion SSH) : validation, forme user@ip,
// construction de la commande, mémoire par appareil et par site. Données fixes, aucun réseau.

func registerQuickLoginTests(_ suite: TestSuite) {
    suite.add("SSH rapide : validation du nom d'utilisateur") {
        for good in ["admin", "net.admin", "svc_ipscan", "user-01", "admin@corp.local", ""] {
            try expectEqual(try QuickLogin.validateUser(good), good, "accepté : \(good)")
        }
        try expectEqual(try QuickLogin.validateUser("  admin "), "admin", "espaces autour retirés")
        for bad in ["-oProxyCommand=x", "admin;rm -rf ~", "$(whoami)", "ad min", "root'", "a\"b", "`id`", "@root",
                    "admin\nroot", "x|y", "a&b", "CORP\\dany", String(repeating: "a", count: 105)] {
            try expectThrows(RemoteValidationError.invalidUser(bad.trimmingCharacters(in: .whitespaces)), "refusé : \(bad)") {
                _ = try QuickLogin.validateUser(bad)
            }
        }
        try expectEqual(try QuickLogin.validateUser("CORP\\dany", allowDomain: true), "CORP\\dany", "domaine permis en RDP")
    }

    suite.add("SSH rapide : forme user@ip et ssh://") {
        try expectEqual(try QuickLoginAddress.parse("admin@10.0.0.2"), QuickLoginAddress(user: "admin", host: "10.0.0.2"), "user@ip")
        try expectEqual(try QuickLoginAddress.parse("admin@10.0.0.2:2222"), QuickLoginAddress(user: "admin", host: "10.0.0.2", port: 2222), "port")
        try expectEqual(try QuickLoginAddress.parse("ssh://root@sw-core-01/"), QuickLoginAddress(user: "root", host: "sw-core-01"), "URL ssh")
        try expectEqual(try QuickLoginAddress.parse("admin@corp@10.0.0.2"), QuickLoginAddress(user: "admin@corp", host: "10.0.0.2"), "dernier @")
        try expectEqual(try QuickLoginAddress.parse("pi@[fe80::1]:22"), QuickLoginAddress(user: "pi", host: "fe80::1", port: 22), "IPv6 entre crochets")
        try expectEqual(try QuickLoginAddress.parse("fe80::1"), QuickLoginAddress(host: "fe80::1"), "IPv6 nue")
        try expectEqual(try QuickLoginAddress.parse("10.0.0.9"), QuickLoginAddress(host: "10.0.0.9"), "IP seule")
        try expectThrows(RemoteValidationError.invalidUser("a b"), "espace refusé") { _ = try QuickLoginAddress.parse("a b@10.0.0.2") }
        try expectThrows(RemoteValidationError.invalidHost("-oProxyCommand=x"), "hôte en option refusé") { _ = try QuickLoginAddress.parse("root@-oProxyCommand=x") }
        try expectThrows(RemoteValidationError.invalidPort(70000), "port hors limite") { _ = try QuickLoginAddress.parse("root@10.0.0.2:70000") }
        try expectEqual(QuickLoginAddress(user: "admin", host: "10.0.0.2", port: 2222).formatted(), "admin@10.0.0.2:2222", "affichage")
        try expectEqual(QuickLoginAddress(user: "admin", host: "10.0.0.2", port: 22).formatted(), "admin@10.0.0.2", "port standard omis")

        // Champ « Utilisateur » de la feuille.
        try expectEqual(QuickLoginAddress.splitUserField("admin", defaultHost: "10.0.0.2"), QuickLoginAddress(user: "admin", host: "10.0.0.2"), "nom seul")
        try expectEqual(QuickLoginAddress.splitUserField("root@10.0.0.7:2222", defaultHost: "10.0.0.2"),
                        QuickLoginAddress(user: "root", host: "10.0.0.7", port: 2222), "user@ip:port remplace l'hôte")
        try expectEqual(QuickLoginAddress.splitUserField("dany@corp.local", defaultHost: "10.0.0.2"),
                        QuickLoginAddress(user: "dany@corp.local", host: "10.0.0.2"), "compte de domaine gardé")
        try expectEqual(QuickLoginAddress.splitUserField("pi@raspberry", defaultHost: "raspberry"),
                        QuickLoginAddress(user: "pi", host: "raspberry"), "hôte de l'appareil reconnu")
    }

    suite.add("SSH rapide : commande ssh user@ip, échappée") {
        try expectEqual(QuickLogin.sshCommand(user: "admin", host: "10.0.0.2", port: 22), "ssh -- admin@10.0.0.2", "port standard")
        try expectEqual(QuickLogin.sshCommand(user: "admin", host: "10.0.0.2", port: 2222), "ssh -p 2222 -- admin@10.0.0.2", "port non standard")
        try expectEqual(QuickLogin.sshCommand(user: "", host: "10.0.0.2", port: 22), "ssh -- 10.0.0.2", "sans utilisateur")
        try expectEqual(QuickLogin.sshCommand(user: "dany@corp.local", host: "10.0.0.2", port: 22), "ssh -l dany@corp.local -- 10.0.0.2", "nom avec @ : -l")
        try expectEqual(QuickLogin.sshCommand(user: "netadmin", host: "10.0.0.2", port: 22, auth: .key, keyPath: "~/.ssh/id_ed25519", home: "/Users/dany"),
                        "ssh -i /Users/dany/.ssh/id_ed25519 -o IdentitiesOnly=yes -- netadmin@10.0.0.2", "clé, ~ développé")
        try expectEqual(QuickLogin.sshCommand(user: "admin", host: "h", port: 22, auth: .key, keyPath: "/Users/dany/Mes clés/id_rsa", home: "/Users/dany"),
                        "ssh -i '/Users/dany/Mes clés/id_rsa' -o IdentitiesOnly=yes -- admin@h", "chemin avec espace entre apostrophes")
        try expectEqual(QuickLogin.sshCommand(user: "admin", host: "10.0.0.40", port: 2222, auth: .password),
                        "ssh -o PreferredAuthentications=keyboard-interactive,password -o PubkeyAuthentication=no -p 2222 -- admin@10.0.0.40",
                        "mot de passe : clés désactivées, rien d'autre dans la commande")
        try expectEqual(RemoteLauncher.sshCommand(RemoteConnection(name: "x", proto: .ssh, host: "10.0.0.2", port: 2200, username: "root")),
                        "ssh -p 2200 -- root@10.0.0.2", "carnet : même forme")

        // Plan complet : validation avant toute commande.
        let plan = try QuickLogin.plan(for: QuickLoginChoice(host: "10.182.122.2", user: "netadmin"), name: "SW-CORE-01", home: "/Users/dany")
        try expectEqual(plan, .terminal(command: "ssh -- netadmin@10.182.122.2"), "plan SSH")
        try expectThrows(RemoteValidationError.invalidUser("a;b"), "injection refusée avant la commande") {
            _ = try QuickLogin.plan(for: QuickLoginChoice(host: "10.0.0.2", user: "a;b"), name: "x")
        }
        try expectThrows(QuickLoginError.invalidKeyPath("../id"), "clé relative refusée") {
            _ = try QuickLogin.plan(for: QuickLoginChoice(host: "10.0.0.2", user: "a", auth: .key, keyPath: "../id"), name: "x")
        }
        try expectThrows(QuickLoginError.invalidKeyPath("~/.ssh/id'x"), "apostrophe refusée dans la clé") {
            _ = try QuickLogin.plan(for: QuickLoginChoice(host: "10.0.0.2", user: "a", auth: .key, keyPath: "~/.ssh/id'x"), name: "x")
        }
        try expectThrows(QuickLoginError.invalidKeyPath(""), "clé à choisir") {
            _ = try QuickLogin.plan(for: QuickLoginChoice(host: "10.0.0.2", user: "a", auth: .key), name: "x")
        }
        let telnet = try QuickLogin.plan(for: QuickLoginChoice(proto: .telnet, host: "10.182.122.3", user: "manager"), name: "SW", telnetPath: "/opt/homebrew/bin/telnet")
        try expectEqual(telnet, .terminal(command: "/opt/homebrew/bin/telnet -l manager 10.182.122.3 23"), "Telnet avec utilisateur")
        let book = QuickLogin.connection(for: QuickLoginChoice(host: "10.0.0.2", user: "admin", port: 2222), name: "Switch\ncœur", folder: "Siège")
        try expectEqual(book.name, "Switch cœur", "nom du carnet sans retour à la ligne")
        try expectEqual(book.username, "admin", "utilisateur du carnet")
        try expectEqual(book.port, 2222, "port du carnet")
    }

    suite.add("SSH rapide : mémoire par appareil et par site, sans secret") {
        let siege = UUID(uuidString: "5A7E0028-0001-4C1E-9A11-00000000A001")!
        let laval = UUID(uuidString: "5A7E0028-0002-4C1E-9A11-00000000A002")!
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let credential = RemoteCredential(kind: .ssh, name: "ssh-netadmin", user: "netadmin", port: 22, sshMethod: .key,
                                          keyPath: "~/.ssh/id_ed25519", lastHost: "10.182.122.2")
        let nas = RemoteCredential(kind: .ssh, name: "ssh-nas", user: "admin", port: 2222, sshMethod: .password, lastHost: "10.182.122.40")
        var memory = QuickLoginMemory()

        let fresh = memory.suggestion(for: QuickLoginDevice(host: "10.182.122.9", siteID: siege), credentials: [])
        try expectEqual(fresh.source, .none, "rien de connu")
        try expectEqual(fresh.choice.user, "", "champ vide")
        let fromCredential = memory.suggestion(for: QuickLoginDevice(host: "10.182.122.40", siteID: siege), credentials: [credential, nas])
        try expectEqual(fromCredential.source, .credential("ssh-nas"), "identifiant testé sur cette adresse")
        try expectEqual(fromCredential.choice.port, 2222, "port de l'identifiant")
        try expectEqual(fromCredential.choice.auth, .password, "méthode de l'identifiant")

        let switchCore = QuickLoginDevice(host: "10.182.122.2", mac: "70:0f:6a:91:4c:02", siteID: siege)
        memory.remember(QuickLoginChoice(host: "10.182.122.2", user: "netadmin", auth: .key, keyPath: "~/.ssh/id_ed25519"),
                        for: switchCore, skipPrompt: false, now: t0)
        let again = memory.suggestion(for: switchCore)
        try expectEqual(again.source, .device, "nom retenu pour l'appareil")
        try expectEqual(again.choice.user, "netadmin", "même nom")
        try expectEqual(again.choice.keyPath, "~/.ssh/id_ed25519", "même clé")

        // Même MAC, nouvelle IP : le nom suit l'appareil.
        let moved = memory.suggestion(for: QuickLoginDevice(host: "10.182.122.20", mac: "70:0F:6A:91:4C:02", siteID: siege))
        try expectEqual(moved.source, .device, "retrouvé par la MAC")
        try expectEqual(moved.choice.host, "10.182.122.20", "nouvelle IP utilisée")

        // Autre appareil du même site : nom du site, port par défaut.
        let neighbour = memory.suggestion(for: QuickLoginDevice(host: "10.182.122.3", siteID: siege))
        try expectEqual(neighbour.source, .site, "dernier nom du site")
        try expectEqual(neighbour.choice.user, "netadmin", "nom du site")
        try expectEqual(neighbour.skipPrompt, false, "la feuille est montrée")
        // Même IP sur un autre site : un autre appareil.
        let otherSite = memory.suggestion(for: QuickLoginDevice(host: "10.182.122.2", siteID: laval))
        try expectEqual(otherSite.source, .none, "pas de mélange entre sites")

        // Remplacement, « Ne plus demander », oubli.
        memory.remember(QuickLoginChoice(host: "10.182.122.2", user: "admin", port: 2222), for: switchCore, skipPrompt: true, now: t0 + 60)
        try expectEqual(memory.entries.count, 1, "une seule entrée par appareil")
        try expectEqual(memory.suggestion(for: switchCore).skipPrompt, true, "ne plus demander")
        try expectEqual(memory.suggestion(for: switchCore).choice.port, 2222, "port retenu")
        try expectEqual(memory.recentUsers, ["admin", "netadmin"], "noms récents, le plus récent d'abord")
        try expectEqual(memory.knownUsers(credentials: [credential]).prefix(4).map { $0 }, ["admin", "netadmin", "root", "manager"],
                        "liste : récents, identifiants, puis noms courants sans doublon")
        memory.forget(switchCore)
        try expectEqual(memory.entries.count, 0, "appareil oublié")
        try expectEqual(memory.suggestion(for: switchCore).source, .none, "plus rien pour l'appareil")

        // Telnet retenu à part.
        memory.remember(QuickLoginChoice(proto: .telnet, host: "10.182.122.3", user: "manager"), for: QuickLoginDevice(host: "10.182.122.3", siteID: siege), skipPrompt: false)
        try expectEqual(memory.suggestion(for: QuickLoginDevice(host: "10.182.122.3", siteID: siege), proto: .telnet).choice.user, "manager", "Telnet")
        try expectEqual(memory.entry(for: QuickLoginDevice(host: "10.182.122.3", siteID: siege), proto: .ssh), nil, "SSH distinct de Telnet")

        // Limite des noms récents.
        for index in 0..<20 { memory.noteUser("u\(index)") }
        try expectEqual(memory.recentUsers.count, QuickLoginMemory.recentLimit, "noms récents limités")
        try expectEqual(memory.recentUsers.first, "u19", "plus récent en tête")
    }

    suite.add("SSH rapide : fichier ssh-utilisateurs.json sans secret, lecture tolérante") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-quicklogin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(QuickLoginMemory.fileName)
        var memory = QuickLoginMemory()
        memory.remember(QuickLoginChoice(host: "10.0.0.2", user: "admin", auth: .password),
                        for: QuickLoginDevice(host: "10.0.0.2", mac: "AA:BB:CC:00:11:22"), skipPrompt: true,
                        now: Date(timeIntervalSince1970: 1_800_000_000))
        try memory.save(to: url)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let entry = (json?["entries"] as? [[String: Any]])?.first ?? [:]
        let allowed: Set<String> = ["id", "proto", "mac", "host", "siteID", "user", "port", "auth", "keyPath", "credentialID", "skipPrompt", "lastUsed"]
        try expect(!entry.isEmpty && Set(entry.keys).isSubset(of: allowed), "seuls les champs prévus (aucun mot de passe) : \(entry.keys.sorted())")
        let text = try String(contentsOf: url, encoding: .utf8)
        try expect(!text.lowercased().contains("secret"), "aucun secret")
        try expectEqual(QuickLoginMemory.load(from: url), memory, "relu à l'identique")
        // Ancien fichier ou champ inconnu : rien ne casse.
        try #"{"entries":[{"host":"10.0.0.5","user":"root","auth":"inconnu"}],"extra":1}"#.write(to: url, atomically: true, encoding: .utf8)
        let tolerant = QuickLoginMemory.load(from: url)
        try expectEqual(tolerant.entries.first?.user, "root", "entrée lue")
        try expectEqual(tolerant.entries.first?.auth, .automatic, "méthode inconnue : automatique")
        try expectEqual(tolerant.entries.first?.port, 22, "port par défaut")
        try "pas du JSON".write(to: url, atomically: true, encoding: .utf8)
        try expectEqual(QuickLoginMemory.load(from: url), QuickLoginMemory(), "fichier illisible : mémoire vide")
    }

    suite.add("SSH rapide : recherche « admin@10.182.122.2 » dans le carnet") {
        let connection = RemoteConnection(name: "SW-CORE-01", proto: .ssh, host: "10.182.122.2", username: "admin")
        try expect(connection.matches("admin@10.182.122.2"), "forme user@ip trouvée")
        try expect(connection.matches("ip:admin@10.182"), "préfixe ip:")
        try expect(!connection.matches("root@10.182.122.2"), "autre utilisateur : non")
    }
}
