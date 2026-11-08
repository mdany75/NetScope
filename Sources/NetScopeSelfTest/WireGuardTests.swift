import Foundation
import NetScopeCore

// Note 100 (1.3.0) : serveur WireGuard (wg-easy) — wg show all dump, réponses JSON fixes de l'API
// de wg-easy 15, sortie du script SSH, fusion des clients, règles d'alerte. Valeurs fictives
// seulement (clés fabriquées, adresses de documentation) ; aucun ssh, aucune requête.

private struct WGMissing: Error { let what: String }
private func wgUnwrap<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw WGMissing(what: what) }
    return value
}

/// Clé fictive de 44 caractères (base64 de 32 octets).
private func fakeKey(_ seed: String) -> String {
    var bytes = Array(("essai-" + seed).utf8.prefix(32))
    while bytes.count < 32 { bytes.append(0x2E) }
    return Data(bytes).base64EncodedString()
}

func registerWireGuardTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_794_000_000)
    let server = fakeKey("serveur"), julie = fakeKey("julie"), marc = fakeKey("marc"), inconnu = fakeKey("inconnu")
    let secret = fakeKey("secret-a-ne-jamais-garder")

    suite.add("WireGuard : wg show all dump analysé, colonnes secrètes ignorées") {
        let text = [
            "wg0\t\(secret)\t\(server)\t51820\toff",
            "wg0\t\(julie)\t\(secret)\t198.51.100.37:51820\t10.8.0.2/32,fdcc::2/128\t\(Int(now.timeIntervalSince1970) - 42)\t1284\t6920\t25",
            "wg0\t\(marc)\t(none)\t[2001:db8::5]:40213\t10.8.0.3/32\t0\t0\t0\toff",
            "ligne invalide",
        ].joined(separator: "\n")
        let dump = WireGuardDump.parse(text)
        try expectEqual(dump.interfaces, [WireGuardInterfaceInfo(name: "wg0", publicKey: server, listenPort: 51820)], "interface")
        try expectEqual(dump.peers.count, 2, "deux pairs")
        let first = dump.peers[0]
        try expectEqual(first.publicKey, julie, "clé publique")
        try expectEqual(first.endpointAddress, "198.51.100.37", "IP d'origine")
        try expectEqual(first.allowedIPs, ["10.8.0.2/32", "fdcc::2/128"], "adresses permises")
        try expectEqual(first.receivedBytes, 1284, "octets reçus")
        try expectEqual(first.latestHandshake, Date(timeIntervalSince1970: TimeInterval(Int(now.timeIntervalSince1970) - 42)), "poignée de main")
        try expectEqual(dump.peers[1].latestHandshake, nil, "jamais connecté")
        try expectEqual(dump.peers[1].endpointAddress, "2001:db8::5", "IPv6 sans crochets")
        let encoded = String(decoding: try JSONEncoder().encode(dump), as: UTF8.self)
        try expect(!encoded.contains(secret), "aucune clé privée ni partagée gardée")
    }

    suite.add("WireGuard : clients de l'API de wg-easy 15 décodés sans clé privée") {
        let json = """
        [{"id":2,"userId":1,"interfaceId":"wg0","name":"Marc","ipv4Address":"10.8.0.3","ipv6Address":"fdcc::3",
          "privateKey":"\(secret)","publicKey":"\(marc)","preSharedKey":"\(secret)","expiresAt":"2026-12-31T00:00:00.000Z",
          "enabled":false,"createdAt":"2026-11-01 10:00:00","oneTimeLink":{"oneTimeLink":"abc-123","expiresAt":"2026-11-08"},
          "latestHandshakeAt":null,"endpoint":null,"transferRx":10,"transferTx":20,"dns":["10.20.0.1"]},
         {"id":"1","name":"Julie","enabled":true,"publicKey":"\(julie)","privateKey":"\(secret)","expiresAt":null}]
        """
        let clients = try WGEasyAPI.decodeClients(Data(json.utf8))
        try expectEqual(clients.map(\.name), ["Julie", "Marc"], "triés par nom")
        let m = clients[1]
        try expectEqual(m.id, 2, "id")
        try expectEqual(m.enabled, false, "désactivé")
        try expectEqual(m.oneTimeLink, "abc-123", "lien à usage unique (objet)")
        try expectEqual(m.dns, ["10.20.0.1"], "DNS")
        try expect(m.expiresAt != nil && m.createdAt != nil, "dates ISO et SQLite")
        try expectEqual(clients[0].id, 1, "id en texte")
        let kept = String(decoding: try JSONEncoder().encode(clients), as: UTF8.self)
        try expect(!kept.contains(secret) && !kept.contains("privateKey") && !kept.contains("preSharedKey"), "aucune clé secrète gardée")
        try expectThrows(WGEasyAPIError(.decoding, "Liste des clients attendue."), "liste attendue") { _ = try WGEasyAPI.decodeClients(Data("{}".utf8)) }
    }

    suite.add("WireGuard : routes de l'API, fiche de modification et retour arrière") {
        try expectEqual(WGEasyAPI.route(for: .setEnabled(id: 4, false))?.path, "/api/client/4/disable", "désactiver")
        try expectEqual(WGEasyAPI.route(for: .setEnabled(id: 4, true))?.path, "/api/client/4/enable", "activer")
        try expectEqual(WGEasyAPI.route(for: .delete(id: 4))?.method, "DELETE", "supprimer")
        let create = try wgUnwrap(WGEasyAPI.route(for: .create(name: "Tablette", expiresAt: nil)), "ajout")
        try expectEqual(create.path, "/api/client", "ajout : chemin")
        try expectEqual(String(decoding: try wgUnwrap(create.body, "corps"), as: UTF8.self), #"{"expiresAt":null,"name":"Tablette"}"#, "ajout : corps")
        try expect(WGEasyAPI.route(for: .rename(id: 1, to: "x")) == nil, "renommer passe par la fiche")
        try expectEqual(WGEasyAPI.configuration(3).path, "/api/client/3/configuration", "fichier .conf")
        try expectEqual(WGEasyAPI.oneTimeLink(3).path, "/api/client/3/generateOneTimeLink", "lien à usage unique")

        let fetched = """
        {"id":1,"userId":1,"interfaceId":"wg0","name":"Julie","enabled":true,"privateKey":"\(secret)","publicKey":"\(julie)",
         "preSharedKey":"\(secret)","ipv4Address":"10.8.0.2","ipv6Address":"fdcc::2","allowedIps":null,"dns":null,"mtu":1420,
         "createdAt":"x","updatedAt":"y","oneTimeLink":null,"endpoint":"198.51.100.37:1","transferRx":1,"transferTx":2}
        """
        let body = try WGEasyAPI.updateBody(from: Data(fetched.utf8), applying: .rename(id: 1, to: "Julie (siège)"))
        let object = try wgUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any], "fiche")
        try expectEqual(object["name"] as? String, "Julie (siège)", "nouveau nom")
        try expectEqual(object["mtu"] as? Int, 1420, "autres réglages gardés")
        for key in ["privateKey", "preSharedKey", "publicKey", "id", "createdAt", "transferRx", "endpoint"] {
            try expect(object[key] == nil, "champ retiré\u{00A0}: \(key)")
        }
        let expiry = try WGEasyAPI.updateBody(from: Data(fetched.utf8), applying: .setExpiry(id: 1, nil))
        try expect(String(decoding: expiry, as: UTF8.self).contains(#""expiresAt":null"#), "expiration retirée")

        let before = WGEasyClient(id: 1, name: "Julie", enabled: true, dns: ["1.1.1.1"])
        try expectEqual(WGEasyAPI.inverse(of: .setEnabled(id: 1, false), before: before), .setEnabled(id: 1, true), "réactiver")
        try expectEqual(WGEasyAPI.inverse(of: .rename(id: 1, to: "x"), before: before), .rename(id: 1, to: "Julie"), "ancien nom")
        try expectEqual(WGEasyAPI.inverse(of: .delete(id: 1), before: before), nil, "suppression : pas de retour")
    }

    suite.add("WireGuard : refus de l'API (401, 2FA, 404), adresse et authentification") {
        try expectEqual(WGEasyAPI.classify(status: 200, body: Data(), path: "/api/client"), nil, "réussite")
        try expectEqual(WGEasyAPI.classify(status: 401, body: Data(#"{"message":"Invalid TOTP code"}"#.utf8), path: "/api/client")?.kind, .twoFactor, "2FA détecté")
        try expectEqual(WGEasyAPI.classify(status: 401, body: Data(#"{"message":"Unauthorized"}"#.utf8), path: "/api/client")?.kind, .unauthorized, "refus")
        try expectEqual(WGEasyAPI.classify(status: 404, body: Data(), path: "/api/client")?.kind, .notVersion15, "pas une 15")
        let gone = try wgUnwrap(WGEasyAPI.classify(status: 404, body: Data(), path: "/api/client/7"), "404 sur un client")
        try expectEqual(gone.kind, .clientNotFound, "client supprimé ailleurs")
        try expect(!gone.readOnly, "un client disparu ne coupe pas la gestion")
        try expectEqual(WGEasyAPI.classify(status: 404, body: Data(), path: "/api/client/7/enable")?.kind, .clientNotFound, "404 sur une action")
        for (address, blocked) in [("http://wg.exemple.ca:51821", true), ("http://wg-easy.local:51821", false), ("http://192.0.2.10:51821", false),
                                   ("http://serveur:51821", false), ("https://wg.exemple.ca", false), ("http://[2001:db8::1]:51821", false)] {
            try expectEqual(WGEasyAPI.plainHTTPBlocked(try WGEasyAPI.baseURL(address)), blocked, "ATS\u{00A0}: \(address)")
        }
        try expect(WGEasyAPIError(.plainHTTPRefused).readOnly, "HTTP refusé : lecture seule")
        let failure = try wgUnwrap(WGEasyAPI.classify(status: 500, body: Data(#"{"statusMessage":"boom"}"#.utf8), path: "/api/client/2"), "500")
        try expectEqual(failure.detail, "HTTP 500\u{00A0}: boom", "message du serveur")
        try expect(WGEasyAPIError(.twoFactor).readOnly && WGEasyAPIError(.unauthorized).readOnly && !WGEasyAPIError(.unreachable).readOnly,
                   "lecture seule après un refus")

        let base = try WGEasyAPI.baseURL(" http://wg.exemple.ca:51821/ ")
        try expectEqual(base.absoluteString, "http://wg.exemple.ca:51821", "adresse nettoyée")
        try expect(WGEasyAPI.isInsecure(base), "HTTP simple signalé")
        let secure = try WGEasyAPI.baseURL("https://wg.exemple.ca")
        try expect(!WGEasyAPI.isInsecure(secure), "HTTPS")
        for bad in ["ftp://wg.exemple.ca", "http://admin:x@wg.exemple.ca", "http://wg.exemple.ca/api", "wg.exemple.ca", ""] {
            try expect((try? WGEasyAPI.baseURL(bad)) == nil, "adresse refusée\u{00A0}: \(bad)")
        }
        try expectEqual(WGEasyAPI.basicAuthorization(user: "admin", password: "essai"), "Basic YWRtaW46ZXNzYWk=", "Basic")
        let request = WGEasyAPI.request(WGEasyAPI.clients, base: base, user: "admin", password: "essai")
        try expectEqual(request.url?.absoluteString, "http://wg.exemple.ca:51821/api/client", "URL de la liste")
        try expect(!request.httpShouldHandleCookies, "aucun témoin")
        try expectEqual(WGEasyAPI.oneTimeURL(base: base, token: "abc-123")?.absoluteString, "http://wg.exemple.ca:51821/cnf/abc-123", "lien")
        try expectEqual(WGEasyAPI.oneTimeURL(base: base, token: "../x"), nil, "jeton refusé")
        let info = try WGEasyAPI.decodeInformation(Data(#"{"currentRelease":"15.1.0","latestRelease":{"version":"15.1.2","changelog":"…"},"updateAvailable":true,"insecure":true}"#.utf8))
        try expectEqual(info, WGEasyInformation(currentRelease: "15.1.0", latestRelease: "15.1.2", updateAvailable: true, insecure: true), "informations")
    }

    let output = """
    @@NETSCOPE ACCES@@
    SUDO ok
    @@NETSCOPE CONTENEUR@@
    nom=/wg-easy
    etat=running
    demarre=2026-11-01T08:00:00.123456789Z
    redemarrages=1
    image=ghcr.io/wg-easy/wg-easy:15
    imageid=sha256:7c1e
    version=15.1.0
    env INSECURE=true
    env PASSWORD_HASH=$2a$12$neDoitJamaisApparaitre
    env WG_PORT=51820
    @@NETSCOPE EDITION@@
    15
    @@NETSCOPE DUMP@@
    wg0\t(masquee)\t\(server)\t51820\toff
    wg0\t\(julie)\t(masquee)\t198.51.100.37:51820\t10.8.0.2/32\t\(Int(now.timeIntervalSince1970) - 30)\t100\t200\t25
    wg0\t\(inconnu)\t(masquee)\t(none)\t10.8.0.9/32\t0\t0\t0\toff
    @@NETSCOPE CLIENTS14@@
    @@NETSCOPE BASE@@
    client|1|Julie|10.8.0.2|fdcc::2|\(julie)|1|
    client|2|Marc|10.8.0.3||\(marc)|1|2026-11-10 00:00:00
    client|3|Mauvaise ligne|x
    @@NETSCOPE JOURNAUX@@
    Listening on http://0.0.0.0:51821
    @@NETSCOPE FIN@@
    """

    suite.add("WireGuard : sortie du script SSH (conteneur, base, environnement filtré)") {
        let status = WireGuardServerOutput.parse(output, readAt: now)
        try expect(status.complete, "sortie complète")
        try expectEqual(status.access, "ok", "sudo")
        let container = try wgUnwrap(status.container, "conteneur")
        try expectEqual(container.name, "wg-easy", "nom sans « / »")
        try expect(container.isRunning, "en marche")
        try expectEqual(container.restarts, 1, "redémarrages")
        try expect(container.startedAt != nil, "démarrage (nanosecondes)")
        try expectEqual(status.edition, .v15, "édition 15")
        try expectEqual(status.environment, ["INSECURE": "true", "WG_PORT": "51820"], "environnement sans secret")
        try expectEqual(status.insecure, true, "HTTP simple")
        try expectEqual(status.serverKey, server, "clé du serveur")
        try expectEqual(status.listenPort, 51820, "port")
        try expectEqual(status.databaseClients?.map(\.name), ["Julie", "Marc"], "clients de la base (ligne invalide écartée)")
        try expect(status.databaseClients?[1].expiresAt != nil, "expiration SQLite")
        try expectEqual(status.logs, ["Listening on http://0.0.0.0:51821"], "journaux")

        let missing = WireGuardServerOutput.parse("@@NETSCOPE ACCES@@\nSUDO docker\n@@NETSCOPE CONTENEUR@@\nconteneur=absent\n@@NETSCOPE FIN@@\n", readAt: now)
        try expectEqual(missing.container, nil, "conteneur absent")
        let findings = WireGuardServerAlerts.findings(missing, rows: [], settings: WireGuardWatchSettings(), knownKey: nil, now: now)
        try expectEqual(findings.map(\.id), ["conteneur"], "conteneur introuvable signalé")
        let noSQLite = WireGuardServerOutput.parse("@@NETSCOPE BASE@@\nSQLITE absent\n@@NETSCOPE FIN@@\n", readAt: now)
        try expect(noSQLite.sqliteMissing && noSQLite.databaseClients == nil, "sqlite3 absent")
    }

    suite.add("WireGuard : wg-easy 14 reconnue, wg0.json lu sans clé privée") {
        let json = """
        {"server":{"privateKey":"","publicKey":"\(server)","address":"10.8.0.1"},
         "clients":{"b1":{"id":"b1","name":"Portable","address":"10.8.0.2","privateKey":"","publicKey":"\(julie)","preSharedKey":"","enabled":true},
                    "b2":{"id":"b2","name":"Ancien","address":"10.8.0.3","publicKey":"\(marc)","enabled":false,"expiredAt":"2026-10-01T00:00:00.000Z"},
                    "b3":{"id":"b3","name":"Sans clé","publicKey":"pas-une-cle"}}}
        """
        let text = "@@NETSCOPE EDITION@@\n14\n@@NETSCOPE CLIENTS14@@\n" + json + "\n@@NETSCOPE FIN@@\n"
        let status = WireGuardServerOutput.parse(text, readAt: now)
        try expectEqual(status.edition, .v14, "édition 14")
        try expectEqual(status.legacyClients.map(\.name), ["Ancien", "Portable"], "clients de wg0.json")
        try expectEqual(status.legacyClients[0].enabled, false, "désactivé")
        try expect(status.legacyClients[0].expiresAt != nil, "expiration de la 14")
    }

    suite.add("WireGuard : fusion des clients (API, base, pair inconnu) et règles d'alerte") {
        let status = WireGuardServerOutput.parse(output, readAt: now)
        let base = WireGuardClientRow.rows(status: status, api: nil)
        try expectEqual(base.map(\.name), ["Julie", "Marc", "Client sans nom · clé " + String(inconnu.prefix(8)) + "…"], "base, puis pair sans fiche")
        try expectEqual(base[2].unnamedKey, "clé " + String(inconnu.prefix(8)) + "…", "pair sans fiche : clé courte")
        try expectEqual(base[0].unnamedKey, nil, "client nommé : pas de clé courte")
        try expectEqual(WGEasyAPI.webInterfaceURL(host: "192.0.2.10", port: nil)?.absoluteString, "http://192.0.2.10:51821", "interface web : port par défaut")
        try expectEqual(WGEasyAPI.webInterfaceURL(host: "192.0.2.10", port: "8080")?.absoluteString, "http://192.0.2.10:8080", "interface web : variable PORT")
        try expectEqual(WGEasyAPI.webInterfaceURL(host: "192.0.2.10", port: "abc")?.absoluteString, "http://192.0.2.10:51821", "interface web : PORT invalide")
        try expectEqual(WGEasyAPI.webInterfaceURL(host: "2001:db8::1", port: nil)?.absoluteString, "http://[2001:db8::1]:51821", "interface web : IPv6")
        try expectEqual(WGEasyAPI.webInterfaceURL(host: " ", port: nil), nil, "interface web : hôte vide")
        try expect(base[0].isConnected(now: now), "Julie connectée (30 s)")
        try expect(!base[1].isConnected(now: now), "Marc déconnecté")
        try expectEqual(base[0].endpointAddress, "198.51.100.37", "IP d'origine")
        let api = [WGEasyClient(id: 7, name: "Julie (API)", publicKey: julie), WGEasyClient(id: 8, name: "Marc", enabled: false, publicKey: marc)]
        let merged = WireGuardClientRow.rows(status: status, api: api)
        try expectEqual(merged.first { $0.publicKey == julie }?.name, "Julie (API)", "l'API l'emporte")
        try expectEqual(merged.first { $0.publicKey == julie }?.apiID, 7, "gestion possible")
        try expectEqual(merged.first { $0.publicKey == julie }?.receivedBytes, 100, "activité de wg show")
        try expectEqual(merged.count, 3, "aucun doublon")

        let settings = WireGuardWatchSettings(importantKeys: [marc], disconnectedHours: 4, expiryDays: 7)
        let findings = WireGuardServerAlerts.findings(status, rows: base, settings: settings, knownKey: fakeKey("ancienne"), now: now)
        let ids = Set(findings.map(\.id))
        try expect(ids.contains("cle"), "clé du serveur changée")
        try expect(ids.contains("deconnecte-" + marc), "client surveillé jamais connecté")
        try expect(ids.contains("expire-" + marc), "expiration proche")
        try expect(ids.contains("http"), "HTTP simple signalé")
        let problems = WireGuardServerAlerts.problems(findings)
        try expect(!problems.contains { $0.contains("HTTP") }, "HTTP simple : avis, pas une panne")
        try expect(problems.contains("Clé publique du serveur changée"), "clé changée : panne")

        var stopped = status
        stopped.container?.state = "exited"
        let stoppedIDs = WireGuardServerAlerts.findings(stopped, rows: [], settings: WireGuardWatchSettings(), knownKey: server, now: now).map(\.id)
        try expect(stoppedIDs.contains("arret") && !stoppedIDs.contains("cle"), "conteneur arrêté, clé inchangée")
    }

    suite.add("WireGuard : sonde de Surveillance et échantillons du graphe") {
        let status = WireGuardServerOutput.parse(output, readAt: now)
        var probe = MonProbe(name: "Serveur WireGuard", kind: .wireguardServer, target: "admin@assistance.exemple.ca", interval: 300)
        let first = MonWireGuardChecks.evaluate(.success(status), probe: probe, now: now)
        try expectEqual(first.result.problem, "Marc expire bientôt", "première lecture : expiration proche seulement")
        try expectEqual(first.knownThreats, [MonWireGuardChecks.keyPrefix + server], "clé retenue")
        probe.knownThreats = [MonWireGuardChecks.keyPrefix + fakeKey("autre")]
        let second = MonWireGuardChecks.evaluate(.success(status), probe: probe, now: now)
        try expect(second.result.problem?.contains("Clé publique") == true, "clé changée : panne")
        let failed = MonWireGuardChecks.evaluate(.failure(RustDeskServerReadError(kind: .timeout, detail: "")), probe: probe, now: now)
        try expect(!failed.result.reachable, "SSH injoignable")

        let sample = try wgUnwrap(WireGuardSamples.sample(from: status), "échantillon")
        try expectEqual(sample.connected, 1, "un client connecté")
        try expectEqual(sample.receivedBytes, 100, "octets cumulés")
        let later = WireGuardSample(date: now.addingTimeInterval(10), connected: 1, receivedBytes: 1_100, sentBytes: 2_200)
        let rate = try wgUnwrap(WireGuardSamples.rate(from: sample, to: later), "débit")
        try expectEqual(rate.down, 100, "↓ octets/s")
        let reset = WireGuardSample(date: now.addingTimeInterval(20), connected: 0, receivedBytes: 5, sentBytes: 5)
        try expect(WireGuardSamples.rate(from: later, to: reset) == nil, "compteurs remis à zéro")
        let old = WireGuardSample(date: now.addingTimeInterval(-4 * 86_400), connected: 0, receivedBytes: 0, sentBytes: 0)
        try expectEqual(WireGuardSamples.adding(sample, to: [old], now: now).count, 1, "trois jours gardés")
    }

    suite.add("WireGuard : scripts SSH (lecture seule, clés masquées, retour arrière)") {
        let read = try WireGuardServerScript.read(container: "wg-easy")
        try expect(read.contains("$2 = \"(masquee)\"") && read.contains("$3 = \"(masquee)\""), "clé privée et clés partagées masquées")
        try expect(read.contains("sqlite3 -readonly"), "base lue en lecture seule")
        try expect(read.contains("command -v sqlite3"), "sqlite3 seulement s'il existe")
        try expect(!read.contains("PASSWORD"), "aucune variable secrète demandée")
        try expect(!read.contains("compose") && !read.contains(" rm ") || read.contains("rm -rf \"$T\""), "seul le dossier temporaire est effacé")
        try expect((try? WireGuardServerScript.read(container: "wg;reboot")) == nil, "nom de conteneur refusé")
        let update = try WireGuardServerActionScript.updateImage(container: "wg-easy")
        try expect(update.contains("netscope-avant-$STAMP"), "image d'avant étiquetée")
        try expect(update.contains("/var/backups/netscope-wgeasy-"), "configuration sauvegardée")
        try expect(update.contains("retour à l’image précédente"), "retour arrière")
        try expect(update.contains("umask 077"), "sauvegarde lisible par root seulement")
        try expect(read.contains("trap '") && read.contains(" EXIT"), "copie de la base effacée même si ssh est coupé")
        try expect(read.contains("timeout 15 sqlite3"), "sqlite3 borné dans le temps")
        try expect(read.contains("[ -n \"$T\" ] && [ -d \"$T\" ]"), "aucune copie sans dossier temporaire")
        try expect(update.contains("SVC=$(lab com.docker.compose.service)"), "service compose de wg-easy lu")
        try expect(update.contains("dc pull \"$SVC\""), "seule l'image de wg-easy est tirée")
        try expect(update.components(separatedBy: "dc up -d --no-deps \"$SVC\"").count == 3, "seul wg-easy est recréé (mise à jour et retour)")
        try expect(!update.contains("dc up -d >") && !update.contains("dc pull >"), "jamais tout le projet compose")
    }
}
