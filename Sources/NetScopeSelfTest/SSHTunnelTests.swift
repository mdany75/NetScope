import Darwin
import Foundation
import NetScopeCore

// Note 66 et note 78 (Accès distant) : tunnels SSH (-L, -D, -J), ~/.ssh/config, port local libre,
// horodatage de la console série, nom d'utilisateur retenu pour SFTP. Données fixes ; aucun accès
// réseau (un seul bind sur 127.0.0.1 pour le choix du port).

func registerSSHTunnelTests(_ suite: TestSuite) {
    let server = SSHTarget(user: "netadmin", host: "10.182.122.2")

    suite.add("Tunnels SSH : arguments de -L, -D et -J en tableau, destination après « -- »") {
        let rdp = SSHTunnelSpec(kind: .local, remoteHost: "10.10.0.12", remotePort: 3389)
        try expectEqual(rdp.use, .rdp, "3389 : RDP proposé")
        try expectEqual(rdp.preferredLocalPort, 3389, "port non privilégié : repris tel quel")
        let args = try SSHTunnelCommand.arguments(target: server, tunnel: rdp, localPort: 13_389, home: "/Users/dany")
        try expect(args.starts(with: ["-N", "-T"]), "aucune commande distante ni terminal")
        try expect(args.contains("ExitOnForwardFailure=yes"), "échec si le port ne s'ouvre pas")
        try expect(args.contains("ControlPath=none"), "pas de multiplexage")
        try expect(args.contains("PermitLocalCommand=no"), "aucune commande locale")
        guard let l = args.firstIndex(of: "-L") else { throw TestFailure(message: "-L absent", file: #fileID, line: #line) }
        try expectEqual(args[l + 1], "127.0.0.1:13389:10.10.0.12:3389", "écoute sur 127.0.0.1 seulement")
        try expectEqual(Array(args.suffix(2)), ["--", "netadmin@10.182.122.2"], "destination en dernier")
        try expectEqual(SSHTunnelCommand.displayCommand(args),
                        "ssh -N -L 127.0.0.1:13389:10.10.0.12:3389 -- netadmin@10.182.122.2", "commande affichée sans -o")

        let socks = SSHTunnelSpec(kind: .dynamic, remoteHost: "ignoré", remotePort: 80)
        try expectEqual(socks.preferredLocalPort, 1080, "SOCKS : 1080")
        var bastion = server
        bastion.jump = "admin@10.182.122.1, ops@[fe80::1]:2222"
        bastion.port = 2222
        bastion.identityFile = "~/.ssh/id_ed25519"
        let d = try SSHTunnelCommand.arguments(target: bastion, tunnel: socks, localPort: 1080, home: "/Users/dany")
        try expect(d.contains("-D") && d.contains("127.0.0.1:1080"), "proxy SOCKS sur 127.0.0.1")
        try expect(!d.contains("-L"), "pas de -L pour SOCKS")
        guard let j = d.firstIndex(of: "-J") else { throw TestFailure(message: "-J absent", file: #fileID, line: #line) }
        try expectEqual(d[j + 1], "admin@10.182.122.1,ops@[fe80::1]:2222", "rebonds normalisés")
        try expect(d.contains("/Users/dany/.ssh/id_ed25519"), "clé développée")
        try expect(d.contains("-p") && d.contains("2222"), "port du serveur")

        let v6 = SSHTunnelSpec(kind: .local, localPort: 8443, remoteHost: "fe80::10", remotePort: 443)
        let a6 = try SSHTunnelCommand.arguments(target: server, tunnel: v6, localPort: 8443)
        try expect(a6.contains("127.0.0.1:8443:[fe80::10]:443"), "IPv6 entre crochets")
        try expectEqual(v6.use, .https, "443 : navigateur https")
        try expectEqual(SSHTunnelCommand.webURL(use: .https, port: 8443)?.absoluteString, "https://127.0.0.1:8443/", "adresse du navigateur")

        // Domaine dans le nom : « -l » plutôt qu'un second « @ ».
        let domain = try SSHTunnelCommand.arguments(target: SSHTarget(user: "admin@corp", host: "srv"), tunnel: rdp, localPort: 20_000)
        try expectEqual(Array(domain.suffix(4)), ["-l", "admin@corp", "--", "srv"], "utilisateur avec @")
    }

    suite.add("Tunnels SSH : valeurs piégées refusées (espaces, guillemets, -o, ProxyCommand)") {
        let tunnel = SSHTunnelSpec(kind: .local, remoteHost: "10.0.0.5", remotePort: 80)
        let traps = ["-oProxyCommand=touch /tmp/x", "10.0.0.1 -oProxyCommand=x", "\"10.0.0.1\"", "10.0.0.1;id",
                     "a b", "$(id)", "10.0.0.1\n-o", "'x'"]
        for host in traps {
            var target = server
            target.host = host
            try expect((try? SSHTunnelCommand.arguments(target: target, tunnel: tunnel, localPort: 20_000)) == nil, "hôte refusé : \(host)")
            var spec = tunnel
            spec.remoteHost = host
            try expect((try? SSHTunnelCommand.arguments(target: server, tunnel: spec, localPort: 20_000)) == nil, "destination refusée : \(host)")
        }
        for jump in ["-oProxyCommand=nc %h %p", "bastion -oProxyCommand=x", "a b", "\"bastion\"", "bastion,", ",bastion",
                     "admin@bastion:99999", "a,b,c,d,e,f", "bastion;id"] {
            var target = server
            target.jump = jump
            try expect((try? SSHTunnelCommand.arguments(target: target, tunnel: tunnel, localPort: 20_000)) == nil, "rebond refusé : \(jump)")
        }
        try expectThrows(SSHTunnelError.tooManyJumps(6), "six rebonds") { _ = try SSHJumpChain.parse("a,b,c,d,e,f") }
        try expectEqual(try SSHJumpChain.normalized(" none "), "", "« none » : aucun saut")
        for user in ["-oProxyCommand=x", "a b", "ad\"min", "root;id"] {
            var target = server
            target.user = user
            try expect((try? target.validated()) == nil, "utilisateur refusé : \(user)")
        }
        var key = server
        key.identityFile = "~/.ssh/../../etc/passwd"
        try expectThrows(SSHTunnelError.invalidIdentityFile("~/.ssh/../../etc/passwd"), "clé hors chemin") { _ = try key.validated() }
        for port in [0, 80, 1023, 70_000] {
            try expect((try? SSHTunnelCommand.arguments(target: server, tunnel: tunnel, localPort: port)) == nil, "port local refusé : \(port)")
        }
        var badLocal = tunnel
        badLocal.localPort = 22
        try expectThrows(SSHTunnelError.invalidLocalPort(22), "port privilégié refusé") { _ = try badLocal.validated() }
        // Le nom libre ne peut pas casser une ligne.
        var named = tunnel
        named.label = "DSM\u{1B}[31m\nsuite"
        let cleanedLabel = try named.validated().label
        try expect(!cleanedLabel.contains("\n") && !cleanedLabel.contains("\u{1B}"), "nom sur une ligne, sans séquence")
        // Aucun argument ne commence par « -o » collé (ex. « -oProxyCommand ») en dehors des options fixes.
        let args = try SSHTunnelCommand.arguments(target: server, tunnel: tunnel, localPort: 20_000)
        try expect(!args.contains { $0.lowercased().contains("proxycommand") }, "aucune ProxyCommand")
    }

    suite.add("Tunnels SSH : port local libre choisi automatiquement") {
        try expectEqual(LocalPortPicker.choose(preferred: 13_389, isFree: { _ in true }), 13_389, "port voulu libre")
        try expectEqual(LocalPortPicker.choose(preferred: 13_389, isFree: { $0 > 13_390 }), 13_391, "ports suivants")
        try expectEqual(LocalPortPicker.choose(preferred: 13_389, reserved: [13_389], isFree: { _ in true }), 13_390,
                        "port réservé par un autre tunnel sauté")
        try expectEqual(LocalPortPicker.choose(preferred: 1080, attempts: 3, isFree: { $0 >= 20_005 }), 20_005,
                        "repli dans la plage 20000-48999")
        try expectEqual(LocalPortPicker.choose(preferred: 0, isFree: { _ in true }), 20_000, "sans préférence")
        try expectEqual(LocalPortPicker.choose(preferred: 13_389, isFree: { _ in false }), nil, "aucun port libre")
        try expectEqual(SSHTunnelSpec.suggestedLocalPort(kind: .local, remotePort: 5001), 5001, "port non privilégié repris")
        try expectEqual(SSHTunnelSpec.suggestedLocalPort(kind: .local, remotePort: 22), 10_022, "22 → 10022")
        try expectEqual(SSHTunnelSpec.suggestedLocalPort(kind: .local, remotePort: 5900), 15_900, "5900 (Partage d'écran du Mac) → 15900")

        // Un vrai port occupé sur 127.0.0.1 (aucun paquet ne quitte le Mac).
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try expectEqual(bound, 0, "bind de test")
        _ = listen(fd, 1)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let busy = Int(UInt16(bigEndian: address.sin_port))
        try expect(!LocalPortPicker.isFree(busy), "port occupé détecté")
        try expect(LocalPortPicker.isListening(busy), "écoute détectée sans connexion")
        let chosen = LocalPortPicker.choose(preferred: busy)
        try expect(chosen != nil && chosen != busy, "un autre port est choisi")
    }

    suite.add("Tunnels SSH : carnet (rebond, clé, tunnels) relu et validé") {
        var connection = RemoteConnection(name: "SW-CORE-01", proto: .ssh, host: "10.182.122.2", username: "netadmin",
                                          proxyJump: "admin@10.182.122.1:22", identityFile: "~/.ssh/id_netscope",
                                          tunnels: [SSHTunnelSpec(kind: .local, localPort: 8443, remoteHost: "10.182.122.111", remotePort: 443),
                                                    SSHTunnelSpec(kind: .dynamic)])
        let valid = try connection.validated()
        try expectEqual(valid.proxyJump, "admin@10.182.122.1", "port 22 du rebond omis")
        try expectEqual(valid.tunnels.count, 2, "deux tunnels")
        try expectEqual(valid.tunnels[0].spec(), "8443 → 10.182.122.111:443", "libellé du croquis")
        try expectEqual(valid.tunnels[1].spec(activePort: 1080), "1080 (proxy SOCKS5)", "SOCKS")
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: encoder.encode(valid))
        try expectEqual(decoded, valid, "aller-retour JSON")
        // Carnet d'avant la 0.26.0 : sans les nouveaux champs.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"x","proto":"ssh","host":"h","port":22,"username":"","folder":"","isFavorite":false,"note":"","createdAt":0}"#
        let legacy = try JSONDecoder().decode(RemoteConnection.self, from: Data(old.utf8))
        try expect(legacy.proxyJump.isEmpty && legacy.identityFile.isEmpty && legacy.tunnels.isEmpty, "ancien carnet lu")
        let copy = valid.duplicated()
        try expect(Set(copy.tunnels.map(\.id)).isDisjoint(with: valid.tunnels.map(\.id)), "copie : nouveaux identifiants")
        connection.proxyJump = "-oProxyCommand=x"
        try expect((try? connection.validated()) == nil, "rebond piégé refusé à l'enregistrement")
        // Les champs SSH sont retirés des autres protocoles.
        var rdp = valid
        rdp.proto = .rdp
        rdp.port = 3389
        let cleaned = try rdp.validated()
        try expect(cleaned.tunnels.isEmpty && cleaned.proxyJump.isEmpty, "RDP sans tunnels")
        // « Ouvrir dans Terminal » : la même commande avec rebond et clé.
        try expectEqual(RemoteLauncher.sshCommand(valid, home: "/Users/dany"),
                        "ssh -J admin@10.182.122.1 -i /Users/dany/.ssh/id_netscope -- netadmin@10.182.122.2", "commande Terminal")
        try expectEqual(SSHTerminalCommand.displayCommand(user: "netadmin", host: "10.182.122.2", port: 22, jump: valid.proxyJump),
                        "ssh -J admin@10.182.122.1 -- netadmin@10.182.122.2", "commande de l'onglet")
        let tabArgs = SSHTerminalCommand.arguments(user: "netadmin", host: "10.182.122.2", port: 22, jump: "admin@10.182.122.1")
        try expect(tabArgs.contains("-J") && tabArgs.last == "netadmin@10.182.122.2", "onglet : -J avant la destination")
        // Connexion RDP passée par le tunnel : 127.0.0.1, utilisateur repris.
        let base = RemoteConnection(name: "SRV-FICHIERS", proto: .rdp, host: "10.10.0.12", username: "CORP\\dmenard")
        let through = SSHTunnelCommand.throughTunnel(.rdp, port: 13_389, name: "SRV-FICHIERS (tunnel)", base: base)
        try expectEqual(through?.host, "127.0.0.1", "hôte local")
        try expectEqual(through?.port, 13_389, "port du tunnel")
        try expectEqual(through?.username, "CORP\\dmenard", "utilisateur repris")
        try expect(RemoteLauncher.rdpFile(for: through!).hasPrefix("full address:s:127.0.0.1:13389"), ".rdp vers le tunnel")
        try expect(SSHTunnelCommand.throughTunnel(.http, port: 1, name: "x") == nil, "navigateur : pas de connexion")
    }

    // MARK: ~/.ssh/config

    let mainConfig = """
    # Configuration de Dany
    Include config.d/*
    Include ~/.ssh/absent

    Host bastion
        HostName 203.0.113.10
        User ops
        Port 2222
        IdentityFile ~/.ssh/id_bastion

    Host sw-core sw-core-alt
        HostName=10.182.122.2
        User = netadmin
        ProxyJump bastion
        IdentityFile "%d/.ssh/id netscope"
        IdentityFile ~/.ssh/id_rsa # deuxième clé

    Match host *.lab exec "test -f /tmp/x"
        User piege

    Host nas
        HostName %h.corp.local
        Include nas.conf

    Host *.corp !secret.corp
        User admin
        ProxyCommand nc -X 5 -x 127.0.0.1:1080 %h %p

    Host 10.10.*
        User administrateur

    Match all
    Host *
        User dany
        ServerAliveInterval 30
    """
    let files: [String: String] = [
        "/Users/dany/.ssh/config.d/fortigate": "Host fgt\n  HostName 10.182.122.1\n  User admin\n  Port 22\n",
        "/Users/dany/.ssh/config.d/vide": "# rien\n",
        "/Users/dany/.ssh/nas.conf": "User admin-nas\nPort 2200\nHost autre\n  User inconnu\n",
    ]
    let loader = SSHConfigLoader(sshDirectory: "/Users/dany/.ssh", home: "/Users/dany",
                                 read: { files[$0] },
                                 glob: { pattern in
                                     files.keys.filter { SSHConfigPattern.glob($0, pattern) }.sorted()
                                 })

    suite.add("~/.ssh/config : Host, HostName, User, Port, ProxyJump, IdentityFile, Include et jokers") {
        let config = SSHConfigFile.parse(mainConfig, loader: loader)
        try expectEqual(config.concreteAliases, ["fgt", "bastion", "sw-core", "sw-core-alt", "nas"],
                        "hôtes nommés, Include compris ; « autre » (hors de la portée de son Include) écarté")
        let core = config.resolve("sw-core")
        try expectEqual(core.hostName, "10.182.122.2", "HostName= sans espace")
        try expectEqual(core.user, "netadmin", "User = valeur")
        try expectEqual(core.proxyJump, "bastion", "ProxyJump")
        try expectEqual(core.identityFiles, ["%d/.ssh/id netscope", "~/.ssh/id_rsa"], "deux clés, guillemets, commentaire retiré")
        try expectEqual(core.port, nil, "port par défaut")
        try expectEqual(config.resolve("sw-core-alt").hostName, "10.182.122.2", "deuxième motif du même bloc")
        let fgt = config.resolve("fgt")
        try expectEqual(fgt.hostName, "10.182.122.1", "fichier inclus par joker")
        try expectEqual(fgt.user, "admin", "le premier User gagne (avant Host *)")
        // Include placé dans « Host nas » : son contenu ne vaut que pour nas.
        let nas = config.resolve("nas")
        try expectEqual(nas.hostName, "nas.corp.local", "%h remplacé")
        try expectEqual(nas.user, "admin-nas", "User de l'Include dans le bloc")
        try expectEqual(nas.port, 2200, "Port de l'Include dans le bloc")
        try expectEqual(config.resolve("autre").user, "dany", "Host d'un Include placé dans « Host nas » : jamais appliqué à autre (comme ssh)")
        try expectEqual(config.resolve("ailleurs").port, nil, "Include dans un bloc : rien pour les autres hôtes")
        // Jokers et négation.
        try expectEqual(config.resolve("imprimante.corp").user, "admin", "*.corp")
        try expect(config.resolve("imprimante.corp").hasProxyCommand, "ProxyCommand signalée")
        try expectEqual(config.resolve("secret.corp").user, "dany", "!secret.corp exclu")
        try expectEqual(config.resolve("10.10.0.20").user, "administrateur", "joker sur une adresse")
        try expectEqual(config.resolve("SW-CORE").hostName, nil, "motifs sensibles à la casse, comme ssh")
        // Match ignoré proprement, « Match all » gardé.
        try expectEqual(config.ignoredMatchBlocks, 1, "un bloc Match ignoré")
        try expectEqual(config.resolve("x.lab").user, "dany", "le User du Match n'est pas appliqué")
        try expect(config.notes.contains { $0.contains("Match host") }, "remarque sur le Match")
        try expect(config.notes.contains { $0.contains("absent") }, "Include introuvable signalé")
        try expect(!config.notes.contains { $0.contains("config.d") }, "joker sans fichier : silencieux")
        try expect(SSHConfigPattern.glob("sw1.corp", "sw?.co*"), "joker ? et *")
        try expect(!SSHConfigPattern.glob("sw10.corp", "sw?.corp"), "? : un seul caractère")
        // Tokenisation.
        try expect(SSHConfigFile.tokenize("   # commentaire") == nil, "commentaire")
        try expect(SSHConfigFile.tokenize("") == nil, "ligne vide")
        let token = SSHConfigFile.tokenize("LocalForward 8080 \"10.0.0.1:80\"")
        try expectEqual(token?.0, "localforward", "mot-clé en minuscules")
        try expectEqual(token?.1 ?? [], ["8080", "10.0.0.1:80"], "valeurs")
    }

    suite.add("~/.ssh/config : import dans le carnet (lecture seule, valeurs validées)") {
        let config = SSHConfigFile.parse("Host piege\n  HostName -oProxyCommand=x\nHost tokens\n  User %u\nHost *\n" + mainConfig, loader: loader)
        let existing = [RemoteConnection(name: "FortiGate-60F", proto: .ssh, host: "10.182.122.1", username: "admin")]
        let candidates = SSHConfigImport.candidates(from: config, existing: existing, home: "/Users/dany")
        func candidate(_ alias: String) throws -> SSHConfigCandidate {
            guard let found = candidates.first(where: { $0.alias == alias }) else {
                throw TestFailure(message: "candidat \(alias) absent", file: #fileID, line: #line)
            }
            return found
        }
        let core = try candidate("sw-core")
        try expectEqual(core.connection?.host, "sw-core", "l'alias reste l'hôte (ssh applique le bloc)")
        try expectEqual(core.connection?.username, "netadmin", "User repris")
        try expectEqual(core.connection?.proxyJump, "bastion", "ProxyJump repris")
        try expectEqual(core.connection?.identityFile, "~/.ssh/id netscope", "IdentityFile : chemin seulement, %d → ~")
        try expectEqual(core.connection?.folder, SSHConfigImport.folder, "dossier d'import")
        try expect(core.connection?.note.contains("HostName 10.182.122.2") == true, "HostName dans la description")
        try expect(core.remarks.contains { $0.contains("2 clés") }, "deuxième clé signalée")
        let bastion = try candidate("bastion")
        try expectEqual(bastion.connection?.port, 2222, "Port repris")
        let fgtCandidate = try candidate("fgt")
        try expect(fgtCandidate.alreadySaved, "déjà au carnet (même HostName et port)")
        try expect(!core.alreadySaved, "nouveau")
        let trap = try candidate("piege")
        try expect(trap.connection != nil, "HostName piégé : l'alias seul est utilisé comme hôte")
        try expect(trap.connection?.note.contains("-oProxyCommand") == true, "HostName montré, jamais passé à ssh par NetScope")
        let tokens = try candidate("tokens")
        try expectEqual(tokens.connection?.username, "", "User avec jetons laissé à ssh")
        try expect(tokens.remarks.contains { $0.contains("%u") }, "remarque")
        try expectEqual(try candidate("fgt").connection?.username, "admin", "hôte d'un fichier inclus")
        try expect(!candidates.contains { $0.alias.contains("*") }, "jokers jamais importés")
        try expect(!candidates.contains { $0.alias == "sw-core-alt" }, "second nom du même bloc : non proposé en double")
        try expect(config.resolve("*.corp").user == "admin", "résolution sur un motif tapé tel quel")
    }

    suite.add("SSH intégré : mot de passe du Trousseau remis quand l'utilisateur vient de ~/.ssh/config") {
        let config = SSHConfigFile.parse(mainConfig, loader: loader)
        // Défaut corrigé : carnet sans utilisateur, User de ~/.ssh/config.
        try expectEqual(config.expectedPrompt(user: "", host: "sw-core", localUser: "dany"), "netadmin@10.182.122.2",
                        "invite nommée par ssh : User et HostName du fichier")
        try expectEqual(config.expectedPrompt(user: "root", host: "sw-core", localUser: "dany"), "root@10.182.122.2",
                        "l'utilisateur du carnet prime")
        try expectEqual(config.expectedPrompt(user: "", host: "10.10.0.20", localUser: "dany"), "administrateur@10.10.0.20",
                        "joker du fichier")
        try expectEqual(config.expectedPrompt(user: "", host: "NAS", localUser: "dany"), "dany@nas",
                        "hôte en minuscules (comme ssh), sans correspondance de casse")
        try expectEqual(SSHConfigFile().expectedPrompt(user: "", host: "nas", localUser: "dany"), "dany@nas", "sans fichier")
        try expectEqual(SSHTerminalCommand.expectedPrompt(user: "", host: "nas", localUser: "dany"), "dany@nas", "ancienne règle inchangée")
    }

    // MARK: Console série et noms retenus

    suite.add("Console série : horodatage des lignes reçues") {
        var stamper = TerminalLineTimestamper(timeZone: TimeZone(identifier: "UTC")!)
        var tick = 0.0
        let base = Date(timeIntervalSince1970: 1_762_340_467.5)
        let clock: () -> Date = {
            defer { tick += 1 }
            return base.addingTimeInterval(tick)
        }
        let out = String(decoding: stamper.feed(Array("Switch>\r\nBoot\r\n\r\nOK".utf8), now: clock), as: UTF8.self)
        let dim = "\u{1B}[2m", normal = "\u{1B}[22m"
        try expectEqual(out, "\(dim)[11:01:07.500]\(normal) Switch>\r\n\(dim)[11:01:08.500]\(normal) Boot\r\n\r\n\(dim)[11:01:09.500]\(normal) OK",
                        "une marque par ligne, aucune pour une ligne vide")
        try expect(!stamper.atLineStart, "ligne en cours")
        let more = String(decoding: stamper.feed(Array(" suite\rréécrite\n".utf8), now: clock), as: UTF8.self)
        try expect(!more.contains("["), "suite de ligne et CR seul : pas de nouvelle marque")
        try expect(stamper.atLineStart, "fin de ligne")
        var filter = TerminalLogFilter()
        let logged = filter.feed(stamper.feed(Array("% Link up\n".utf8), now: clock))
        try expectEqual(logged, "[11:01:10.500] % Link up\n", "journal en texte brut, horodaté")
        stamper.reset()
        try expect(stamper.atLineStart, "réinitialisé")
    }

    suite.add("Noms d'utilisateur retenus : SFTP reprend le compte SSH de l'appareil, RDP par site") {
        let site = UUID()
        var memory = QuickLoginMemory()
        let nas = QuickLoginDevice(host: "10.10.0.20", mac: "00:11:32:AA:BB:CC", siteID: site)
        memory.remember(QuickLoginChoice(proto: .ssh, host: "10.10.0.20", user: "admin-nas", port: 2222), for: nas, skipPrompt: false)
        let sftp = memory.suggestion(for: nas, proto: .sftp)
        try expectEqual(sftp.choice.user, "admin-nas", "compte SSH repris pour SFTP")
        try expectEqual(sftp.choice.port, 2222, "même port sshd")
        try expectEqual(sftp.choice.proto, .sftp, "protocole SFTP")
        memory.remember(QuickLoginChoice(proto: .sftp, host: "10.10.0.20", user: "sauvegarde"), for: nas, skipPrompt: false)
        try expectEqual(memory.suggestion(for: nas, proto: .sftp).choice.user, "sauvegarde", "nom SFTP propre ensuite")
        let wks = QuickLoginDevice(host: "10.182.122.117", siteID: site)
        memory.remember(QuickLoginChoice(proto: .rdp, host: "10.182.122.117", user: "CORP\\dmenard"), for: wks, skipPrompt: false)
        let other = memory.suggestion(for: QuickLoginDevice(host: "10.182.122.146", siteID: site), proto: .rdp)
        try expectEqual(other.choice.user, "CORP\\dmenard", "RDP : nom du site proposé à un autre poste")
        try expectEqual(other.source, .site, "source : le site")
        try expectEqual(memory.suggestion(for: wks, proto: .rdp).choice.user, "CORP\\dmenard", "RDP : nom de l'appareil")
    }
}

func registerSSHTunnelDiagnosisTests(_ suite: TestSuite) {
    suite.add("Tunnels SSH : causes d'échec lues dans la sortie de ssh") {
        try expectEqual(SSHTunnelDiagnosis.scan("bind [127.0.0.1]:8443: Address already in use\r\nchannel_setup_fwd_listener_tcpip: cannot listen to port: 8443\r\nCould not request local forwarding.\r\n"),
                        .localPortInUse, "port local pris")
        try expectEqual(SSHTunnelDiagnosis.scan("channel 2: open failed: administratively prohibited: open failed"), .forwardingRefused, "redirections interdites")
        let unreachable = SSHTunnelDiagnosis.scan("channel 3: open failed: connect failed: No route to host")
        try expectEqual(unreachable, .destinationUnreachable, "destination injoignable")
        try expect(unreachable?.isFatal == false, "le tunnel reste ouvert")
        try expectEqual(SSHTunnelDiagnosis.scan("ops@203.0.113.10: Permission denied (publickey,password)."), .authenticationFailed, "identification")
        try expectEqual(SSHTunnelDiagnosis.scan("ssh: connect to host 10.0.0.9 port 22: Connection refused"), .connectionRefused, "refus")
        try expectEqual(SSHTunnelDiagnosis.scan("ssh: connect to host 10.0.0.9 port 22: Operation timed out"), .timeout, "délai")
        try expectEqual(SSHTunnelDiagnosis.scan("ssh: Could not resolve hostname bastion: nodename nor servname provided"), .hostNotFound, "DNS")
        try expectEqual(SSHTunnelDiagnosis.scan("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"), .hostKeyChanged, "clé changée")
        try expectEqual(SSHTunnelDiagnosis.scan("Authenticated to 10.182.122.2 ([10.182.122.2]:22)."), nil, "rien d'anormal")
        try expectEqual(SSHTunnelDiagnosis.pendingPrompt("ops@203.0.113.10's password: "), "ops@203.0.113.10's password:", "mot de passe demandé")
        try expectEqual(SSHTunnelDiagnosis.pendingPrompt("(admin@10.0.0.2) Password:"), "(admin@10.0.0.2) Password:", "keyboard-interactive")
        try expect(SSHTunnelDiagnosis.pendingPrompt("Enter passphrase for key '/Users/dany/.ssh/id_bastion':") != nil, "phrase secrète")
        try expectEqual(SSHTunnelDiagnosis.pendingPrompt("Last login: Tue"), nil, "pas une demande")
    }
}
