import Foundation
import Network
import NetScopeCore

// Note 6 : RustDesk. Données fixes (ID, adresses rustdesk://, nom du client portable, TOML du
// client, JSON des VIP) et un mini hbbs sur 127.0.0.1 pour le test du serveur (jamais d'autre
// adresse). Valeurs fictives seulement.

func registerRustDeskTests(_ suite: TestSuite) {
    let key = "TmV0U2NvcGUgZGVtbyA6IGNsZSBmaWN0aXZlIDIwMjY="

    suite.add("RustDesk : ID (validation stricte, affichage groupé)") {
        try expectEqual(RustDeskID.parse("123 456 789"), "123456789", "espaces acceptés")
        try expectEqual(RustDeskID.parse(" 123-456-789\n"), "123456789", "tirets et retour à la ligne")
        try expectEqual(RustDeskID.parse("123\u{00A0}456\u{202F}789"), "123456789", "espaces insécables")
        try expectEqual(RustDeskID.parse("1234567890"), "1234567890", "10 chiffres")
        try expect(RustDeskID.parse("12345678") == nil, "8 chiffres refusés")
        try expect(RustDeskID.parse("12345678901") == nil, "11 chiffres refusés")
        try expect(RustDeskID.parse("12345678a") == nil, "lettre refusée")
        try expect(RustDeskID.parse("١٢٣٤٥٦٧٨٩") == nil, "chiffres non ASCII refusés")
        try expectEqual(RustDeskID.grouped("123456789", separator: " "), "123 456 789", "groupes de trois")
        try expectEqual(RustDeskID.grouped("1234567890", separator: " "), "1 234 567 890", "10 chiffres groupés depuis la droite")
        try expectEqual(RustDeskID.grouped("123456789"), "123\u{00A0}456\u{00A0}789", "insécable par défaut")
    }

    suite.add("RustDesk : destination (ID ou IP directe) et validation") {
        try expectEqual(try RustDeskTarget.parse("184 352 907"), .id("184352907"), "ID")
        try expectEqual(try RustDeskTarget.parse("10.0.0.5"), .direct(host: "10.0.0.5", port: 21118), "IP directe")
        try expectEqual(try RustDeskTarget.parse("poste-12.exemple.ca", port: 21200), .direct(host: "poste-12.exemple.ca", port: 21200), "nom et port")
        try expectThrows(RemoteValidationError.invalidRustDeskID("1234 5678"), "ID trop court") { _ = try RustDeskTarget.parse("1234 5678") }
        try expectThrows(RemoteValidationError.rustDeskIPv6("fe80::1"), "IPv6 refusée") { _ = try RustDeskTarget.parse("fe80::1") }
        try expectThrows(RemoteValidationError.invalidHost("10.0.0.5;open"), "injection refusée") { _ = try RustDeskTarget.parse("10.0.0.5;open") }
        try expectEqual(RustDeskTarget.direct(host: "10.0.0.5", port: 21118).remoteID, "10.0.0.5", "port par défaut omis")
        try expectEqual(RustDeskTarget.direct(host: "10.0.0.5", port: 21200).remoteID, "10.0.0.5:21200", "autre port gardé")
        try expectEqual(RemoteProtocol.forPort(21118), .rustdesk, "port 21118")
        try expectEqual(RemoteProtocol.rustdesk.fullName, "RustDesk (assistance à distance)", "nom complet")
        try expectEqual(RemoteProtocol.rustdesk.externalApp, "RustDesk", "application externe")
    }

    suite.add("RustDesk : connexion du carnet (ID compact, usager, ancien carnet)") {
        var connection = RemoteConnection(name: "WKS-ACCUEIL-02", proto: .rustdesk, host: " 184 352 907 ", username: "ignoré",
                                          createdAt: Date(timeIntervalSince1970: 1_790_000_000), endUser: "Julie\nGagnon")
        connection = try connection.validated()
        try expectEqual(connection.host, "184352907", "ID enregistré en chiffres")
        try expectEqual(connection.username, "", "pas d'utilisateur en RustDesk")
        try expectEqual(connection.endUser, "Julie Gagnon", "usager sur une ligne")
        try expectEqual(connection.port, 21118, "port par défaut")
        try expect(connection.isRustDeskByID, "désigné par son ID")
        try expectEqual(connection.address, "184\u{00A0}352\u{00A0}907", "adresse affichée groupée")
        try expect(connection.matches("184 352 907"), "recherche par l'ID dicté")
        try expect(connection.matches("Gagnon"), "recherche par l'usager")
        let plan = try RemoteLauncher.plan(for: connection)
        try expectEqual(plan, .rustdesk(target: .id("184352907")), "plan RustDesk")
        try expectEqual(plan.preview, "rustdesk://connection/new/184352907", "aperçu sans mot de passe")
        try expectEqual(plan.appName, "RustDesk", "application")
        let pasted = try RemoteConnection.rustDesk("263 418 095")
        try expectEqual(pasted.name, "Poste 263\u{00A0}418\u{00A0}095", "nom par défaut")
        let direct = try RemoteConnection.rustDesk("10.182.122.160", name: "SALLE-CONF-TV")
        try expect(!direct.isRustDeskByID, "IP directe")
        try expectEqual(direct.address, "10.182.122.160 (IP directe)", "adresse IP directe")
        // Ancienne connexion (sans « endUser ») : lue telle quelle.
        let old = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"SW","proto":"ssh","host":"10.0.0.2","port":22,"username":"a",
         "folder":"","isFavorite":false,"note":"","createdAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RemoteConnection.self, from: Data(old.utf8))
        try expectEqual(decoded.endUser, "", "usager vide")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let round = try decoder.decode(RemoteConnection.self, from: try encoder.encode(connection))
        try expectEqual(round, connection, "aller-retour JSON")
    }

    suite.add("RustDesk : adresse rustdesk:// (forme documentée, mot de passe encodé)") {
        try expectEqual(RustDeskLink.connectURL(.id("184352907"))?.absoluteString, "rustdesk://connection/new/184352907", "ID")
        try expectEqual(RustDeskLink.connectURL(.direct(host: "10.0.0.5", port: 21118))?.absoluteString,
                        "rustdesk://connection/new/10.0.0.5", "IP directe")
        try expectEqual(RustDeskLink.connectURL(.id("184352907"), password: "a b&c=d/é")?.absoluteString,
                        "rustdesk://connection/new/184352907?password=a%20b%26c%3Dd%2F%C3%A9", "mot de passe encodé")
        try expectEqual(RustDeskLink.connectURL(.id("184352907"), password: "", forceRelay: true)?.absoluteString,
                        "rustdesk://connection/new/184352907?relay", "relais forcé, mot de passe vide omis")
        let url = try unwrapRD(RustDeskLink.connectURL(.id("184352907"), password: "x&relay"), "adresse")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try expectEqual(items.map(\.name), ["password"], "le mot de passe ne crée pas de paramètre")
        try expectEqual(items.first?.value, "x&relay", "valeur intacte")
        try expectEqual(RustDeskLink.displayURL(.id("184352907"), hasPassword: true), "rustdesk://connection/new/184352907?password=•••", "affichage masqué")
    }

    suite.add("RustDesk : réglages du serveur et nom du client portable") {
        var settings = RustDeskServerSettings(idServer: "assistance.exemple.ca", publicKey: key,
                                              supportPageURL: "https://assistance.exemple.ca/rustdesk")
        try expect(settings.issues().isEmpty, "réglages valides")
        try expectEqual(settings.idEndpoint, RustDeskEndpoint(host: "assistance.exemple.ca", port: 21116), "serveur d'ID")
        try expectEqual(settings.natTestEndpoint?.port, 21115, "test NAT")
        try expectEqual(settings.relayEndpoint, RustDeskEndpoint(host: "assistance.exemple.ca", port: 21117), "relais déduit")
        try expectEqual(settings.portableClientFileName, "rustdesk-host=assistance.exemple.ca,key=\(key),.exe", "nom du client portable")
        try expect(settings.portableNameProblem == nil, "nom valide pour Windows")
        settings.relayServer = "relais.exemple.ca"
        try expectEqual(settings.relayEndpoint, RustDeskEndpoint(host: "relais.exemple.ca", port: 21117), "relais saisi")
        try expectEqual(settings.portableClientFileName, "rustdesk-host=assistance.exemple.ca,key=\(key),relay=relais.exemple.ca,.exe", "avec relay=")
        settings.publicKey = "abc/def"
        try expect(settings.issues().contains { $0.contains("Clé publique invalide") }, "clé invalide signalée")
        try expect(settings.portableNameProblem?.contains("clé publique") == true, "« / » interdit dans un nom Windows")
        settings = RustDeskServerSettings(idServer: "https://Assistance.Exemple.ca:21200/", publicKey: key, supportPageURL: "http://x.ca")
        try expectEqual(settings.idEndpoint, RustDeskEndpoint(host: "assistance.exemple.ca", port: 21200), "schéma retiré, port gardé")
        try expectEqual(settings.natTestEndpoint?.port, 21199, "test NAT au port précédent")
        try expect(settings.issues().contains { $0.contains("https") }, "page d'assistance en http refusée")
        try expect(RustDeskServerSettings(idServer: "a;b").issues().count == 1, "serveur invalide")
    }

    suite.add("RustDesk : importer le nom du client portable") {
        let plain = try unwrapRD(RustDeskPortableConfig.parse("rustdesk-host=assistance.exemple.ca,key=\(key),.exe"), "nom simple")
        try expectEqual(plain, RustDeskPortableConfig(host: "assistance.exemple.ca", key: key), "serveur et clé")
        let full = try unwrapRD(RustDeskPortableConfig.parse("C:\\Users\\julie\\Downloads\\rustdesk-host=assistance.exemple.ca,api=api.exemple.ca,key=\(key),relay=r.exemple.ca,x=\(key),.exe"), "chemin Windows")
        try expectEqual(full, RustDeskPortableConfig(host: "assistance.exemple.ca", key: key, relay: "r.exemple.ca", api: "api.exemple.ca"), "ordre libre, relay et api")
        // Comme le client RustDesk : ce qui précède « host= » est ignoré.
        try expectEqual(RustDeskPortableConfig.parse("rustdesk-relay=r.exemple.ca,host=assistance.exemple.ca,.exe")?.relay, "", "avant host= ignoré")
        let copy = try unwrapRD(RustDeskPortableConfig.parse("rustdesk-host=assistance.exemple.ca,key=\(key) (1).exe"), "copie (1)")
        try expectEqual(copy.key, key, "« (1) » de Windows retiré")
        let doubled = try unwrapRD(RustDeskPortableConfig.parse("RustDesk-HOST=assistance.exemple.ca,KEY=\(key),.exe.exe"), "majuscules")
        try expectEqual(doubled.host, "assistance.exemple.ca", "host= en majuscules")
        try expectEqual(doubled.key, key, "la clé garde sa casse")
        try expect(RustDeskPortableConfig.parse("rustdesk-1.4.2-x86_64.exe") == nil, "client ordinaire refusé")
        let merged = RustDeskServerSettings(supportPageURL: "https://assistance.exemple.ca/rustdesk").merging(full)
        try expectEqual(merged.supportPageURL, "https://assistance.exemple.ca/rustdesk", "page d'assistance gardée")
        try expectEqual(merged.apiServer, "api.exemple.ca", "API reprise")
    }

    suite.add("RustDesk : configuration du client de ce Mac (TOML) et comparaison") {
        let toml = """
        rendezvous_server = 'rs-ny.rustdesk.com:21116'
        nat_type = 1

        [options]
        custom-rendezvous-server = 'assistance.exemple.ca'
        key = '\(key)'
        relay-server = ""
        local-ip-addr = '10.0.0.8'
        """
        let client = RustDeskClientConfig.parse(toml)
        try expectEqual(client, RustDeskClientConfig(rendezvousServer: "assistance.exemple.ca", key: key), "clés de [options]")
        let settings = RustDeskServerSettings(idServer: "assistance.exemple.ca:21116", publicKey: key)
        let ok = RustDeskClientCheck.compare(settings, client: client)
        try expect(ok.allSatisfy { $0.level == .ok }, "même serveur, même clé, relais déduit")
        let publicServers = RustDeskClientCheck.compare(settings, client: RustDeskClientConfig.parse("[options]\nkey = \"\(key)\"\n"))
        try expect(publicServers.first?.title.contains("serveurs publics") == true, "serveurs publics signalés")
        let otherKey = RustDeskClientCheck.compare(settings, client: RustDeskClientConfig(rendezvousServer: "assistance.exemple.ca", key: "AAAA" + key.dropFirst(4)))
        try expect(otherKey.contains { $0.level == .error && $0.title.hasPrefix("Clé différente") }, "clé différente")
        let missing = RustDeskClientCheck.compare(settings, client: nil)
        try expectEqual(missing.first?.level, .warning, "fichier absent")
        let relay = RustDeskClientCheck.compare(settings, client: RustDeskClientConfig(rendezvousServer: "assistance.exemple.ca", relayServer: "autre.exemple.ca", key: key))
        try expect(relay.contains { $0.level == .warning && $0.title.contains("Autre relais") }, "autre relais")
        try expectEqual(RustDeskClientConfig.defaultURL(home: "/Users/dany").path,
                        "/Users/dany/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml", "chemin du client macOS")
    }

    suite.add("RustDesk : messages du protocole rendezvous (trames, protobuf)") {
        try expectEqual(RustDeskWire.testNatRequest, [0x0C, 0xA2, 0x01, 0x00], "TestNatRequest encadré")
        try expectEqual(RustDeskWire.frame(Array(repeating: 1, count: 100)).prefix(2), [0x91, 0x01], "en-tête sur deux octets")
        let long = RustDeskWire.frame(Array(repeating: 7, count: 300))
        try expectEqual(RustDeskWire.unframe(long)?.payload.count, 300, "trame longue relue")
        try expect(RustDeskWire.unframe([0x0C, 0xA2]) == nil, "trame incomplète")
        // RendezvousMessage { test_nat_response: { port: 53122 } } = champ 21, port en varint.
        let response: [UInt8] = [0xAA, 0x01, 0x04, 0x08, 0x82, 0x9F, 0x03]
        try expectEqual(RustDeskWire.testNatResponsePort(response), 53_122, "port vu par le serveur")
        try expectEqual(RustDeskWire.testNatResponsePort([0xAA, 0x01, 0x00]), 0, "port absent")
        try expect(RustDeskWire.testNatResponsePort([0x3A, 0x00]) == nil, "autre message")
        // Varint géant (10 octets) comme longueur d'un champ de type 2 : refus, pas de plantage.
        let huge: [UInt8] = [0xAA, 0x01] + Array(repeating: 0xFF, count: 9) + [0x01]
        try expect(RustDeskWire.testNatResponsePort(huge) == nil, "longueur géante refusée")
        try expect(RustDeskWire.messageField([0x12] + Array(repeating: 0xFF, count: 9) + [0x01]) == nil, "longueur géante (messageField)")
        // Port géant dans un TestNatResponse : borné, sans plantage.
        let bigPort: [UInt8] = [0xAA, 0x01, 0x0B, 0x08] + Array(repeating: 0xFF, count: 9) + [0x01]
        try expectEqual(RustDeskWire.testNatResponsePort(bigPort), 0, "port hors de Int : ignoré")
        try expectEqual(RustDeskWire.testNatResponsePort([0xAA, 0x01, 0x04, 0x08, 0xFF, 0xFF, 0x07]), 65_535, "port borné")
        // Datagrammes d'autres services : pas une réponse rendezvous.
        try expect(RustDeskWire.messageField([0x08, 0x01]) == nil, "champ varint seul")
        try expect(RustDeskWire.messageField([0xFA, 0x03, 0x00]) == nil, "champ inconnu (63)")
        try expect(RustDeskWire.messageField([0x3A, 0x00, 0x3A, 0x00]) == nil, "deux champs")
        try expectEqual(RustDeskWire.messageField([0x3A, 0x00]), 7, "RegisterPeerResponse vide")
        // Trame annonçant une longueur démesurée : jamais complète.
        try expect(RustDeskWire.unframe([0xFF, 0xFF, 0xFF, 0xFF, 0x00]) == nil, "longueur annoncée trop grande")
        let register = RustDeskWire.registerPeer(id: "netscope.sonde.ab12cd34")
        try expectEqual(Array(register.prefix(2)), [0x32, 0x19], "RegisterPeer (champ 6)")
        try expectEqual(RustDeskWire.messageField(register), 6, "champ relu")
        try expect(RustDeskServerTest.probeID().hasPrefix("netscope.sonde."), "ID impossible (point)")
        try expect(RustDeskID.parse(RustDeskServerTest.probeID()) == nil, "jamais un vrai ID")
        let plan = RustDeskServerTest.plan(RustDeskServerSettings(idServer: "assistance.exemple.ca", publicKey: key))
        try expectEqual(plan.map(\.0), [.natTest, .idServer, .udp, .relay], "vérifications")
        try expectEqual(plan.map(\.1.port), [21115, 21116, 21116, 21117], "ports")
    }

    suite.add("RustDesk : résultats du test en clair") {
        let id = RustDeskEndpoint(host: "assistance.exemple.ca", port: 21116)
        try expectEqual(RustDeskProbe(kind: .idServer, endpoint: id, ok: true, millis: 23).summary,
                        "Serveur d’ID joignable en 23\u{00A0}ms", "ID joignable")
        let relay = RustDeskProbe(kind: .relay, endpoint: RustDeskEndpoint(host: "assistance.exemple.ca", port: 21117), ok: false)
        try expectEqual(relay.summary, "Relais injoignable\u{00A0}: vérifier le VIP TCP 21117 sur la FortiGate et le conteneur hbbr", "relais")
        try expectEqual(relay.level, .error, "échec TCP")
        try expectEqual(RustDeskProbe(kind: .udp, endpoint: id, ok: false).level, .warning, "UDP sans réponse : avertissement")
        try expectEqual(RustDeskProbe(kind: .udp, endpoint: id, ok: false).portLabel, "UDP 21116", "étiquette UDP")
    }

    suite.add("RustDesk : VIP de la FortiGate (JSON fixe, piège de l'IP publique)") {
        let json = """
        {"http_method":"GET","results":[
         {"name":"RD-21115-21117","extip":"203.0.113.45","mappedip":[{"range":"192.168.10.20"}],"portforward":"enable","protocol":"tcp","extport":"21115-21117","mappedport":"21115-21117"},
         {"name":"RD-UDP","extip":"203.0.113.45","mappedip":[{"range":"203.0.113.45-203.0.113.45"}],"portforward":"enable","protocol":"udp","extport":"21116","mappedport":"21116"},
         {"name":"Web","extip":"203.0.113.45","mappedip":[{"range":"192.168.10.30"}],"portforward":"enable","protocol":"tcp","extport":"443","mappedport":"443"}
        ],"status":"success"}
        """
        let vips = RustDeskVIPCheck.parse(Data(json.utf8))
        try expectEqual(vips.count, 3, "VIP lus")
        try expectEqual(vips[0].externalPorts, 21115...21117, "plage de ports")
        try expectEqual(vips[1].mappedIP, "203.0.113.45", "première adresse de la plage")
        var settings = RustDeskServerSettings(idServer: "assistance.exemple.ca", publicKey: key)
        var findings = RustDeskVIPCheck.evaluate(vips, settings: settings)
        try expectEqual(findings.map(\.level), [.ok, .ok, .error, .ok], "UDP mappé sur l'IP publique")
        try expect(findings[2].detail.contains("adresse publique"), "piège expliqué")
        settings.internalAddress = "192.168.10.21"
        findings = RustDeskVIPCheck.evaluate(vips, settings: settings)
        try expect(findings[0].title.contains("192.168.10.20") && findings[0].level == .error, "autre adresse interne")
        findings = RustDeskVIPCheck.evaluate(Array(vips.prefix(1)), settings: RustDeskServerSettings(idServer: "a.exemple.ca", publicKey: key))
        try expectEqual(findings[2].level, .error, "UDP sans VIP")
        try expect(findings[2].title.contains("aucun VIP"), "VIP manquant")
        let shifted = RustDeskVIP(name: "Décalé", externalIP: "203.0.113.45", mappedIP: "192.168.10.20", portForward: true,
                                  proto: "tcp", externalPorts: 21116...21116, mappedPorts: 31116...31116)
        try expectEqual(RustDeskVIPCheck.evaluate([shifted], settings: RustDeskServerSettings(idServer: "a.exemple.ca"))[1].level, .warning, "port changé")
        // NAT statique sans rapport avec RustDesk (serveur web) : jamais une preuve.
        let web = RustDeskVIP(name: "NAT-Web", externalIP: "203.0.113.10", mappedIP: "192.168.1.50", portForward: false)
        var bare = RustDeskServerSettings(idServer: "a.exemple.ca", publicKey: key)
        try expectEqual(RustDeskVIPCheck.evaluate([web], settings: bare).map(\.level), [.warning, .warning, .warning, .warning], "NAT statique à confirmer")
        bare.internalAddress = "192.168.10.20"
        let unrelated = RustDeskVIPCheck.evaluate([web], settings: bare)
        try expect(unrelated.allSatisfy { $0.level == .error && $0.title.contains("aucun VIP") }, "NAT statique d'un autre serveur : aucun VIP")
        let natRD = RustDeskVIP(name: "NAT-RD", externalIP: "203.0.113.11", mappedIP: "192.168.10.20", portForward: false)
        try expectEqual(RustDeskVIPCheck.evaluate([web, natRD], settings: bare).map(\.level), [.ok, .ok, .ok, .ok], "NAT statique vers le serveur")
        let transport = RustDeskFixedTransport(body: Data(json.utf8))
        let read = try await RustDeskVIPCheck.read(transport: transport)
        try expectEqual(read.count, 3, "lecture par le transport FortiGate (GET)")
        try expectEqual(transport.paths, ["/api/v2/cmdb/firewall/vip"], "un seul GET")
    }

    suite.add("RustDesk : historique des lancements et fichier") {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var history: [RustDeskLaunch] = []
        for index in 0..<5 {
            history = RustDeskHistory.adding(RustDeskLaunch(date: base.addingTimeInterval(Double(index) * 60), name: "P\(index)", target: "184352907"),
                                             to: history, limit: 3)
        }
        try expectEqual(history.map(\.name), ["P4", "P3", "P2"], "plus récents d'abord, bornés")
        try expectEqual(history[0].targetLabel, "184\u{00A0}352\u{00A0}907", "ID groupé")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-rustdesk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RustDeskStore(url: folder.appendingPathComponent("rustdesk.json"))
        let contents = RustDeskStore.Contents(settings: RustDeskServerSettings(idServer: "assistance.exemple.ca", publicKey: key), history: history)
        try store.save(contents)
        try expectEqual(store.load(), contents, "relu")
        let text = try String(contentsOf: store.url, encoding: .utf8)
        try expect(!text.lowercased().contains("password"), "aucun mot de passe dans le fichier")
    }

    suite.add("RustDesk : fiche d'inventaire (ID RustDesk)") {
        var annotations = InvAnnotations()
        try expect(annotations.validRustDeskID == nil, "aucun")
        let base = annotations
        annotations.rustdeskID = "184 352 907"
        try expectEqual(annotations.validRustDeskID, "184352907", "ID valide")
        try expectEqual(annotations.changedFields(from: base), ["ID RustDesk"], "chronologie")
        let rebased = annotations.rebased(from: base, onto: InvAnnotations(owner: "Réception"))
        try expectEqual(rebased.rustdeskID, "184 352 907", "gardé au rebasage")
        try expectEqual(rebased.owner, "Réception", "autres champs gardés")
        let old = try JSONDecoder().decode(InvAnnotations.self, from: Data(#"{"tags":[],"location":"","wallJack":"","owner":"","assetNumber":"","notes":"","isFavorite":false}"#.utf8))
        try expect(old.rustdeskID == nil, "ancienne fiche lue")
    }

    suite.add("RustDesk : test du serveur contre un mini hbbs sur 127.0.0.1") {
        let server = try LoopbackHBBS()
        let ports = try await server.start()
        defer { server.stop() }
        let nat = await RustDeskServerTest.probe(.natTest, RustDeskEndpoint(host: "127.0.0.1", port: ports.tcp), timeout: 2)
        try expect(nat.ok && nat.protocolAnswer, "TestNatResponse reçu")
        try expect(nat.observedPort != nil, "port source renvoyé")
        try expect(nat.millis != nil, "temps de réponse")
        let udp = await RustDeskServerTest.probe(.udp, RustDeskEndpoint(host: "127.0.0.1", port: ports.udp), timeout: 2)
        try expect(udp.ok, "réponse UDP")
        try expectEqual(server.registeredIDs.first?.hasPrefix("netscope.sonde."), true, "ID de sonde reçu")
        let relay = await RustDeskServerTest.probe(.relay, RustDeskEndpoint(host: "127.0.0.1", port: ports.tcp), timeout: 2)
        try expect(relay.ok, "connexion TCP simple")
        server.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let closed = await RustDeskServerTest.probe(.idServer, RustDeskEndpoint(host: "127.0.0.1", port: ports.tcp), timeout: 1)
        try expect(!closed.ok, "port fermé")
    }
}

private func unwrapRD<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message + " — nil", file: file, line: line) }
    return value
}

/// Transport FortiGate à réponse fixe (aucun réseau), qui note les chemins demandés.
private final class RustDeskFixedTransport: FortiTransport, @unchecked Sendable {
    private let body: Data
    private let lock = NSLock()
    private var requested: [String] = []

    init(body: Data) {
        self.body = body
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    func get(_ path: String, query: [URLQueryItem]) async throws -> FortiHTTPResponse {
        record(path)
        return FortiHTTPResponse(status: 200, body: body)
    }

    private func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        requested.append(path)
    }
}

/// Mini hbbs sur 127.0.0.1 : TestNatRequest → TestNatResponse (TCP), RegisterPeer →
/// RegisterPeerResponse (UDP). N'écoute jamais ailleurs que sur la boucle locale.
private final class LoopbackHBBS: @unchecked Sendable {
    private let tcp: NWListener
    private let udp: NWListener
    private let queue = DispatchQueue(label: "netscope.test.hbbs")
    private let lock = NSLock()
    private var ids: [String] = []
    private var connections: [NWConnection] = []

    var registeredIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return ids
    }

    init() throws {
        let tcpParameters = NWParameters.tcp
        tcpParameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        tcp = try NWListener(using: tcpParameters)
        let udpParameters = NWParameters.udp
        udpParameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        udp = try NWListener(using: udpParameters)
    }

    func start() async throws -> (tcp: Int, udp: Int) {
        tcp.newConnectionHandler = { [weak self] connection in self?.serveTCP(connection) }
        udp.newConnectionHandler = { [weak self] connection in self?.serveUDP(connection) }
        let tcpPort = try await ready(tcp)
        let udpPort = try await ready(udp)
        return (tcpPort, udpPort)
    }

    private func ready(_ listener: NWListener) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let once = HBBSOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                if once.claim() { continuation.resume(throwing: TestSkipped(reason: "écouteur local non prêt")) }
            }
        }
    }

    private func keep(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }

    private func serveTCP(_ connection: NWConnection) {
        keep(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
            guard let data, let frame = RustDeskWire.unframe([UInt8](data)),
                  RustDeskWire.messageField(frame.payload) == RustDeskWire.testNatRequestField else { return }
            // TestNatResponse { port: 4242 }
            let reply = RustDeskWire.frame([0xAA, 0x01, 0x03, 0x08, 0x92, 0x21])
            connection.send(content: Data(reply), completion: .contentProcessed { _ in })
        }
    }

    private func serveUDP(_ connection: NWConnection) {
        keep(connection)
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data else { return }
            let bytes = [UInt8](data)
            guard RustDeskWire.messageField(bytes) == RustDeskWire.registerPeerField else { return }
            // ID : premier champ du RegisterPeer (après l'en-tête 0x32 <longueur> 0x0A <longueur>).
            if bytes.count > 4 {
                let id = String(decoding: bytes[4...], as: UTF8.self)
                self.lock.lock()
                self.ids.append(id)
                self.lock.unlock()
            }
            // RegisterPeerResponse { request_pk: true }
            connection.send(content: Data([0x3A, 0x02, 0x10, 0x01]), completion: .contentProcessed { _ in })
        }
    }

    func stop() {
        tcp.cancel()
        udp.cancel()
        lock.lock()
        let all = connections
        connections = []
        lock.unlock()
        all.forEach { $0.cancel() }
    }
}

private final class HBBSOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
