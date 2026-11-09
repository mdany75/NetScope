import Foundation
import Network
@testable import NetScopeCore

// Note 116 : Testeur HTTP ou API. Le seul réseau touché est un petit serveur sur 127.0.0.1.

/// Reçoit une requête complète (en-têtes et Content-Length), répond d'après son chemin et ferme.
private final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "netscope.selftest.http")
    private let requests = ToolBox<[String]>([])
    private let portValue = ToolBox<UInt16>(0)

    var port: UInt16 { portValue.value }
    var received: [String] { requests.value }

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let box = portValue
        let failed = ToolBox(false)
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: box.mutate { $0 = listener.port?.rawValue ?? 0 }
            case .failed: failed.mutate { $0 = true }
            default: break
            }
        }
        listener.start(queue: queue)
        for _ in 0..<300 where portValue.value == 0 && !failed.value { try await Task.sleep(nanoseconds: 10_000_000) }
        guard portValue.value != 0 else { throw TestSkipped(reason: "écouteur local indisponible") }
    }

    deinit { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] chunk, _, finished, _ in
            let data = buffer + (chunk ?? Data())
            if let text = request(in: data) {
                requests.mutate { $0.append(text) }
                connection.send(content: Data(reply(to: text).utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if finished {
                connection.cancel()
            } else {
                read(connection, buffer: data)
            }
        }

        func request(in data: Data) -> String? {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
            let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            return data.count - end.upperBound >= length ? String(decoding: data, as: UTF8.self) : nil
        }
    }

    private func reply(to request: String) -> String {
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        func response(_ status: String, type: String = "application/json", extra: String = "", body: String) -> String {
            "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n\(extra)Connection: close\r\n\r\n\(body)"
        }
        switch path {
        case "/ok": return response("200 OK", body: #"{"b":1,"a":[1,2]}"#)
        case "/panne": return response("500 Internal Server Error", type: "text/plain", body: "panne FICTIVE")
        case "/saut": return response("302 Found", extra: "Location: /ok\r\n", body: "")
        case "/saut307": return response("307 Temporary Redirect", extra: "Location: /echo\r\n", body: "")
        case "/ailleurs307": return response("307 Temporary Redirect", extra: "Location: http://localhost:\(port)/echo\r\n", body: "")
        case "/vers-https": return response("301 Moved Permanently", extra: "Location: https://127.0.0.1:1/ok\r\n", body: "")
        case "/ailleurs": return response("302 Found", extra: "Location: http://localhost:\(port)/ok\r\n", body: "")
        case "/echo": return response("200 OK", type: "text/plain", body: String(request[request.range(of: "\r\n\r\n")!.upperBound...]))
        case "/morceaux": return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nbonjo\r\n2\r\nur\r\n0\r\n\r\n"
        default: return response("404 Not Found", body: "")
        }
    }
}

func registerHTTPTesterTests(_ suite: TestSuite) {
    suite.add("HTTP : validation de l’URL") {
        func spec(_ url: String) -> HTTPRequestSpec { HTTPRequestSpec(url: url) }
        try expectEqual(try spec("http://10.0.0.1/a?b=1").validatedURL().host, "10.0.0.1", "URL valide")
        try expectThrows(HTTPSpecError.emptyURL, "vide") { _ = try spec("  ").validatedURL() }
        try expectThrows(HTTPSpecError.unsupportedScheme("ftp"), "ftp") { _ = try spec("ftp://hote/").validatedURL() }
        try expectThrows(HTTPSpecError.unsupportedScheme("file"), "fichier local") { _ = try spec("file:///etc/passwd").validatedURL() }
        try expectThrows(HTTPSpecError.unsupportedScheme(""), "sans schéma") { _ = try spec("10.0.0.1/a").validatedURL() }
        try expectThrows(HTTPSpecError.missingHost, "sans hôte") { _ = try spec("http:///a").validatedURL() }
        try expectThrows(HTTPSpecError.invalidURL, "espace") { _ = try spec("http://hote/a b").validatedURL() }
        try expectThrows(HTTPSpecError.invalidURL, "saut de ligne") { _ = try spec("http://hote/a\r\nX: y").validatedURL() }
    }

    suite.add("HTTP : validation des en-têtes, du corps et du délai") {
        func spec(_ name: String, _ value: String = "v") -> HTTPRequestSpec {
            HTTPRequestSpec(url: "http://hote/", headers: [HTTPHeader(name: name, value: value)])
        }
        _ = try spec("X-Essai_1.a", "valeur\tavec tabulation").validatedURL()
        try expectThrows(HTTPSpecError.invalidHeaderName(""), "nom vide") { _ = try spec("").validatedURL() }
        try expectThrows(HTTPSpecError.invalidHeaderName("Mon En-tête"), "espace et accent") { _ = try spec("Mon En-tête").validatedURL() }
        try expectThrows(HTTPSpecError.invalidHeaderName("A:B"), "deux-points") { _ = try spec("A:B").validatedURL() }
        try expectThrows(HTTPSpecError.invalidHeaderValue("X"), "CRLF") { _ = try spec("X", "a\r\nEvil: 1").validatedURL() }
        try expectThrows(HTTPSpecError.invalidHeaderValue("X"), "LF seul") { _ = try spec("X", "a\nb").validatedURL() }
        try expectThrows(HTTPSpecError.bodyNotAllowed(.get), "GET avec corps") { _ = try HTTPRequestSpec(url: "http://h/", body: "x").validatedURL() }
        _ = try HTTPRequestSpec(method: .delete, url: "http://h/", body: "x").validatedURL()
        try expectThrows(HTTPSpecError.invalidTimeout, "délai nul") { _ = try HTTPRequestSpec(url: "http://h/", timeout: 0).validatedURL() }
    }

    suite.add("HTTP : masquage des en-têtes sensibles") {
        for name in ["Authorization", "cookie", "X-API-Key", "Proxy-Authorization", "X-Auth-Token", "X-Secret", "Password", "Set-Cookie"] {
            try expectEqual(HTTPRedaction.masked(HTTPHeader(name: name, value: "FICTIF")).value, HTTPRedaction.mask, name)
        }
        try expectEqual(HTTPRedaction.masked(HTTPHeader(name: "X-Divers", value: "Bearer FICTIF")).value, HTTPRedaction.mask, "valeur porteuse d’un jeton")
        try expectEqual(HTTPRedaction.masked(HTTPHeader(name: "Accept", value: "text/plain")).value, "text/plain", "en-tête ordinaire intact")
    }

    suite.add("HTTP : masquage de l’URL, même incomplète") {
        let m = HTTPRedaction.mask
        try expectEqual(HTTPRedaction.maskedURL("https://u:FICTIF@h.ca:8443/a?x=1"), "https://\(m)@h.ca:8443/a?x=1", "identifiant et mot de passe")
        try expectEqual(HTTPRedaction.maskedURL("https://JETON@h.ca/"), "https://\(m)@h.ca/", "jeton seul")
        try expectEqual(HTTPRedaction.maskedURL("http://h/a?site=r&token=FICTIF&api_key=F&Password=F&sig=F&vlan=2"),
                        "http://h/a?site=r&token=\(m)&api_key=\(m)&Password=\(m)&sig=\(m)&vlan=2", "paramètres")
        try expectEqual(HTTPRedaction.maskedURL("http://h/?pass%77ord=FICTIF"), "http://h/?pass%77ord=\(m)", "nom encodé")
        try expectEqual(HTTPRedaction.maskedURL("http://h/#access_token=FICTIF&etat=1"), "http://h/#access_token=\(m)&etat=1", "fragment")
        try expectEqual(HTTPRedaction.maskedURL("http://h/mail@exemple"), "http://h/mail@exemple", "@ dans le chemin, intact")
        try expectEqual(HTTPRedaction.maskedURL("https://u:FICTIF@"), "https://\(m)@", "saisie en cours")
        try expectEqual(HTTPRedaction.maskedURL("https://10.0.0.1/api?mdp=FICTIF&jeton=FICTIF&cle=FICTIF&cycle=2"),
                        "https://10.0.0.1/api?mdp=\(m)&jeton=\(m)&cle=\(m)&cycle=2", "noms français")
        try expectEqual(HTTPRedaction.maskedURL("http://h/?a=1;token=FICTIF"), "http://h/?a=1;token=\(m)", "paramètres séparés par un point-virgule")
    }

    suite.add("HTTP : le chemin ne garde ni webhook ni jeton") {
        let m = HTTPRedaction.mask
        try expectEqual(HTTPRedaction.maskedURL("https://hooks.exemple.com/services/T0/B0/FICTIF"), "https://hooks.exemple.com/\(m)/\(m)/\(m)/\(m)", "hôte de webhooks")
        try expectEqual(HTTPRedaction.maskedURL("https://h/api/webhooks/123/FICTIF?x=1"), "https://h/api/webhooks/\(m)/\(m)?x=1", "après /webhooks/")
        try expectEqual(HTTPRedaction.maskedURL("https://h/ping/a1b2c3d4e5f6a7b8c9d0e1f2"), "https://h/ping/\(m)", "segment en forme de jeton")
        try expectEqual(HTTPRedaction.maskedURL("https://h/a;jsessionid=FICTIF/b"), "https://h/a;jsessionid=\(m)/b", "paramètre de chemin")
        try expectEqual(HTTPRedaction.maskedURL("https://h/api/v2/etat-des-interfaces/"), "https://h/api/v2/etat-des-interfaces/", "chemin ordinaire intact")
        try expectEqual(HTTPRedaction.historyLine(HTTPRequestSpec(method: .post, url: "https://u:F@hooks.exemple.com/s/FICTIF")),
                        "POST https://\(m)@hooks.exemple.com/\(m)/\(m)", "identifiant et webhook")
    }

    suite.add("HTTP : commande et historique sans secret ni corps") {
        let spec = HTTPRequestSpec(method: .post, url: "https://u:MOTDEPASSE@h.ca/a?token=JETONURL",
                                   headers: [HTTPHeader(name: "Authorization", value: "Bearer JETONENTETE"), HTTPHeader(name: "Accept", value: "*/*")],
                                   body: "CORPSSECRET", acceptsUntrustedCertificate: true)
        let line = HTTPRedaction.commandLine(spec)
        for secret in ["MOTDEPASSE", "JETONURL", "JETONENTETE", "CORPSSECRET"] { try expect(!line.contains(secret), "commande sans \(secret) : \(line)") }
        try expect(line.hasPrefix("curl -X POST -L -k "), "options curl : \(line)")
        try expect(line.contains("-H 'Accept: */*'"), "en-tête ordinaire conservé : \(line)")
        try expectEqual(HTTPRedaction.historyLine(spec), "POST https://\(HTTPRedaction.mask)@h.ca/a?token=\(HTTPRedaction.mask)", "historique")
        try expect(HTTPRedaction.commandLine(HTTPRequestSpec(url: "")).hasSuffix("<url>"), "URL vide")
    }

    suite.add("HTTP : redirection, en-têtes sensibles retirés hors de l’origine") {
        let a = URL(string: "https://a.ca/x")!
        let headers = [HTTPHeader(name: "Authorization", value: "FICTIF"), HTTPHeader(name: "Accept", value: "*/*")]
        try expectEqual(HTTPRedirectPolicy.headers(headers, from: a, to: URL(string: "https://A.ca:443/y")!, keepsBody: true), headers, "même origine")
        for other in ["https://b.ca/x", "http://a.ca/x", "https://a.ca:8443/x"] {
            try expectEqual(HTTPRedirectPolicy.headers(headers, from: a, to: URL(string: other)!, keepsBody: true).map(\.name), ["Accept"], other)
        }
        try expectEqual(HTTPRedirectPolicy.method("POST", after: 302), "GET", "POST puis 302")
        try expectEqual(HTTPRedirectPolicy.method("PUT", after: 303), "GET", "303")
        try expectEqual(HTTPRedirectPolicy.method("HEAD", after: 303), "HEAD", "HEAD garde sa méthode")
        try expectEqual(HTTPRedirectPolicy.method("POST", after: 307), "POST", "307 garde la méthode")

        let framed = [HTTPHeader(name: "Host", value: "a.ca"), HTTPHeader(name: "Content-Length", value: "7")]
        func names(_ to: String, keepsBody: Bool) -> [String] {
            HTTPRedirectPolicy.headers(framed, from: a, to: URL(string: to)!, keepsBody: keepsBody).map(\.name)
        }
        try expectEqual(names("https://b.ca/", keepsBody: true), ["Content-Length"], "Host saisi retiré pour un autre hôte")
        try expectEqual(names("http://a.ca/", keepsBody: true), ["Host", "Content-Length"], "Host gardé sur le même hôte")
        try expectEqual(names("https://a.ca/y", keepsBody: false), ["Host"], "Content-Length retiré avec le corps")
    }

    suite.add("HTTP : le corps suit une redirection dans la même origine, jamais hors de l’origine") {
        let server = try await LocalHTTPServer()
        let base = "http://127.0.0.1:\(server.port)"
        func spec(_ path: String) -> HTTPRequestSpec { HTTPRequestSpec(method: .post, url: base + path, body: "CORPS-FICTIF", timeout: 5) }
        func direct(_ spec: HTTPRequestSpec) async throws -> HTTPResponseResult {
            try await HTTPTester.sendRaw(HTTPTester.PreparedRequest(spec: spec, url: try spec.validatedURL()), spec: spec)
        }
        for (label, send) in [("URLSession", HTTPTester.send), ("connexion directe", direct)] as [(String, (HTTPRequestSpec) async throws -> HTTPResponseResult)] {
            let before = server.received.count
            let held = try await send(spec("/ailleurs307"))
            try expectEqual(held.statusCode, 307, "\(label) : 307 montré")
            try expectEqual(held.unfollowedRedirect, "http://localhost:\(server.port)/echo", "\(label) : adresse signalée")
            try expect(held.redirects.isEmpty, "\(label) : aucun saut")
            try expectEqual(server.received.count, before + 1, "\(label) : rien d’envoyé à l’autre origine")

            let kept = try await send(spec("/saut307"))
            try expectEqual(kept.bodyText, "CORPS-FICTIF", "\(label) : corps reçu après la redirection")
            try expectEqual(kept.unfollowedRedirect, nil, "\(label) : même origine suivie")
        }
    }

    suite.add("HTTP : connexion directe, un POST redirigé en GET n’annonce plus de corps") {
        let server = try await LocalHTTPServer()
        let spec = HTTPRequestSpec(method: .post, url: "http://127.0.0.1:\(server.port)/saut", headers: [HTTPHeader(name: "Content-Length", value: "7")], body: "contenu", timeout: 5)
        let result = try await HTTPTester.sendRaw(HTTPTester.PreparedRequest(spec: spec, url: try spec.validatedURL()), spec: spec)
        try expectEqual(result.statusCode, 200, "arrivée sans attendre le délai")
        try expect(!server.received[1].lowercased().contains("content-length"), "GET sans Content-Length : \(server.received[1])")
    }

    suite.add("HTTP : connexion directe, la durée d’un nom compte la résolution") {
        let server = try await LocalHTTPServer()
        func timings(_ host: String) async throws -> HTTPTimings {
            let spec = HTTPRequestSpec(url: "http://\(host):\(server.port)/ok", timeout: 5)
            return try await HTTPTester.sendRaw(HTTPTester.PreparedRequest(spec: spec, url: try spec.validatedURL()), spec: spec).timings
        }
        let named = try await timings("localhost")
        try expect(named.connectIncludesDNS, "nom : DNS compris dans la connexion")
        try expectEqual(named.dns, nil, "DNS non mesuré à part")
        let literal = try await timings("127.0.0.1")
        try expect(!literal.connectIncludesDNS, "adresse IP : aucune résolution")
    }

    suite.add("HTTP : connexion directe, l’échec après une redirection vers https reste en français") {
        let server = try await LocalHTTPServer()
        let spec = HTTPRequestSpec(url: "http://127.0.0.1:\(server.port)/vers-https", timeout: 5)
        do {
            _ = try await HTTPTester.sendRaw(HTTPTester.PreparedRequest(spec: spec, url: try spec.validatedURL()), spec: spec)
            throw ToolError.processFailed("aucune erreur levée")
        } catch let error as ToolError {
            try expect(error.localizedDescription.contains("Connexion refusée"), "message : \(error.localizedDescription)")
        }
    }

    suite.add("Outils : une cible désigne un appareil par nom entier") {
        try expect(ToolFormat.mentions("10.0.0.2", in: "10.0.0.2"), "identique")
        try expect(ToolFormat.mentions("10.0.0.2", in: "https://10.0.0.2:8443/api"), "dans une URL")
        try expect(ToolFormat.mentions("10.0.0.2", in: "10.0.0.20, 10.0.0.2"), "second de la liste")
        try expect(!ToolFormat.mentions("10.0.0.2", in: "10.0.0.20"), "préfixe d’une autre adresse")
        try expect(!ToolFormat.mentions("10.0.0.2", in: "110.0.0.2"), "suffixe d’une autre adresse")
        try expect(ToolFormat.mentions("nas-1", in: "NAS-1"), "sans casse")
        try expect(!ToolFormat.mentions("nas", in: "nas-1"), "nom plus long")
        try expect(ToolFormat.mentions("AA:BB:CC:DD:EE:FF", in: "aa:bb:cc:dd:ee:ff"), "adresse MAC")
    }

    suite.add("HTTP : JSON réindenté sans changer l’ordre ni les valeurs") {
        let source = #"{ "z" : 12345678901234567890 , "a":[1,{"s":"x{,\"y"}],"v":{},"t":[]}"#
        let pretty = try HTTPBodyFormat.prettyJSON(Data(source.utf8)).unwrap("JSON reconnu")
        let expected = """
        {
          "z": 12345678901234567890,
          "a": [
            1,
            {
              "s": "x{,\\"y"
            }
          ],
          "v": {},
          "t": []
        }
        """
        try expectEqual(pretty, expected, "présentation")
        try expect(HTTPBodyFormat.prettyJSON(Data("texte".utf8)) == nil, "pas du JSON")
        try expect(HTTPBodyFormat.prettyJSON(Data(#"{"coupé":"#.utf8)) == nil, "JSON tronqué")
        try expect(HTTPBodyFormat.prettyJSON(Data("12".utf8)) == nil, "valeur seule laissée telle quelle")
    }

    suite.add("HTTP : réponse brute, en bloc et coupée") {
        let decoded = HTTPRawResponse.decodeChunked(Data("5;ext=1\r\nbonjo\r\n2\r\nur\r\n0\r\n\r\n".utf8))
        try expectEqual(String(decoding: decoded.body, as: UTF8.self), "bonjour", "blocs réunis")
        try expect(decoded.complete, "bloc final vu")
        let cut = HTTPRawResponse.decodeChunked(Data("5\r\nbon".utf8))
        try expectEqual(String(decoding: cut.body, as: UTF8.self), "bon", "début gardé")
        try expect(!cut.complete, "coupure signalée")

        let raw = try HTTPRawResponse(Data("HTTP/1.1 503 Service Unavailable\r\nSet-Cookie: a\r\nSet-Cookie: b\r\nContent-Length: 10\r\n\r\nabc".utf8), complete: false)
        try expectEqual(raw.status, 503, "code")
        try expectEqual(raw.reason, "Service Unavailable", "texte du code")
        try expectEqual(raw.headers.filter { $0.name == "Set-Cookie" }.count, 2, "en-têtes répétés gardés")
        try expectEqual(raw.totalSize, 10, "taille annoncée")
        try expect(raw.isSizeExact, "taille connue malgré la coupure")
        try expectThrows(ToolError.processFailed("Réponse non HTTP."), "sans en-têtes") { _ = try HTTPRawResponse(Data("xx".utf8), complete: true) }
    }

    suite.add("HTTP : aller-retour local, 200 avec JSON et minutages") {
        let server = try await LocalHTTPServer()
        let result = try await HTTPTester.send(HTTPRequestSpec(url: "http://127.0.0.1:\(server.port)/ok", timeout: 5))
        try expectEqual(result.statusCode, 200, "code")
        try expectEqual(result.statusText, "OK", "texte du code")
        try expect(result.version.hasPrefix("HTTP/1."), "version : \(result.version)")
        try expectEqual(result.contentType, "application/json", "type de contenu")
        try expectEqual(result.bodySize, 17, "taille")
        try expect(!result.isTruncated, "corps entier")
        try expectEqual(result.formattedBody?.hasPrefix("{\n  \"b\": 1"), true, "JSON présenté, ordre gardé")
        try expect(result.timings.total > 0, "total mesuré")
        try expect(result.timings.firstByte != nil, "premier octet mesuré")
        try expectEqual(result.timings.tls, nil, "pas de TLS en http")
        try expect(result.remoteAddress?.hasPrefix("127.0.0.1") == true, "IP distante : \(result.remoteAddress ?? "nil")")
    }

    suite.add("HTTP : un 500 est un résultat, pas une erreur") {
        let server = try await LocalHTTPServer()
        let result = try await HTTPTester.send(HTTPRequestSpec(url: "http://127.0.0.1:\(server.port)/panne", timeout: 5))
        try expectEqual(result.statusCode, 500, "code")
        try expectEqual(result.statusText, "Internal Server Error", "texte du code")
        try expectEqual(result.bodyText, "panne FICTIVE", "corps lu")
        try expect(result.formattedBody == nil, "texte simple non présenté en JSON")
    }

    suite.add("HTTP : HEAD annonce une taille sans corps") {
        let server = try await LocalHTTPServer()
        let spec = HTTPRequestSpec(method: .head, url: "http://127.0.0.1:\(server.port)/ok", timeout: 5)
        let viaSession = try await HTTPTester.send(spec)
        try expectEqual(viaSession.bodySize, 0, "URLSession")
        try expect(!viaSession.isTruncated, "pas d’aperçu tronqué")
        let viaRaw = try await HTTPTester.sendRaw(HTTPTester.PreparedRequest(spec: spec, url: try spec.validatedURL()), spec: spec)
        try expectEqual(viaRaw.bodySize, 0, "connexion directe")
        try expect(viaRaw.bodyPreview.isEmpty, "aperçu vide")
    }

    suite.add("HTTP : méthode, en-têtes et corps JSON arrivent au serveur") {
        let server = try await LocalHTTPServer()
        let result = try await HTTPTester.send(HTTPRequestSpec(method: .post, url: "http://u:FICTIF@127.0.0.1:\(server.port)/echo",
                                                               headers: [HTTPHeader(name: "X-Essai", value: "bonjour")], body: #"{"a":1}"#, timeout: 5))
        try expectEqual(result.bodyText, #"{"a":1}"#, "corps renvoyé")
        let request = try server.received.first.unwrap("requête reçue")
        try expect(request.hasPrefix("POST /echo "), "méthode et chemin : \(request)")
        try expect(request.lowercased().contains("accept-encoding: gzip"), "passé par URLSession, pas par le repli : \(request)")
        try expect(request.lowercased().contains("x-essai: bonjour"), "en-tête personnalisé")
        try expect(request.lowercased().contains("content-type: application/json"), "type déduit du corps JSON")
        try expect(request.contains("Basic \(Data("u:FICTIF".utf8).base64EncodedString())"), "identifiant de l’URL en en-tête")
    }

    suite.add("HTTP : redirections suivies ou non") {
        let server = try await LocalHTTPServer()
        let followed = try await HTTPTester.send(HTTPRequestSpec(url: "http://127.0.0.1:\(server.port)/saut", timeout: 5))
        try expectEqual(followed.statusCode, 200, "arrivée")
        try expectEqual(followed.redirects, [HTTPRedirectHop(statusCode: 302, target: "http://127.0.0.1:\(server.port)/ok")], "chaîne")
        let stopped = try await HTTPTester.send(HTTPRequestSpec(url: "http://127.0.0.1:\(server.port)/saut", followRedirects: false, timeout: 5))
        try expectEqual(stopped.statusCode, 302, "3xx montré")
        try expect(stopped.redirects.isEmpty, "aucun saut")
        try expectEqual(stopped.headers.first { $0.name.lowercased() == "location" }?.value, "/ok", "Location visible")
    }

    suite.add("HTTP : l’en-tête d’autorisation ne suit pas une redirection vers un autre hôte") {
        let server = try await LocalHTTPServer()
        _ = try await HTTPTester.send(HTTPRequestSpec(url: "http://127.0.0.1:\(server.port)/ailleurs",
                                                      headers: [HTTPHeader(name: "Authorization", value: "Bearer FICTIF")], timeout: 5))
        try expectEqual(server.received.count, 2, "deux requêtes")
        try expect(server.received[0].contains("FICTIF"), "envoyé au premier hôte")
        try expect(!server.received[1].contains("FICTIF"), "retiré pour localhost : \(server.received[1])")
    }

    suite.add("HTTP : connexion directe (repli ATS), code, corps et redirection") {
        let server = try await LocalHTTPServer()
        func spec(_ path: String, method: HTTPMethod = .get, body: String? = nil) throws -> (HTTPTester.PreparedRequest, HTTPRequestSpec) {
            let spec = HTTPRequestSpec(method: method, url: "http://127.0.0.1:\(server.port)\(path)", body: body, timeout: 5)
            return (HTTPTester.PreparedRequest(spec: spec, url: try spec.validatedURL()), spec)
        }
        let failure = try spec("/panne")
        let failed = try await HTTPTester.sendRaw(failure.0, spec: failure.1)
        try expectEqual(failed.statusCode, 500, "500 lu")
        try expectEqual(failed.statusText, "Internal Server Error", "texte reçu")
        try expectEqual(failed.bodyText, "panne FICTIVE", "corps")

        let chunk = try spec("/morceaux")
        let chunked = try await HTTPTester.sendRaw(chunk.0, spec: chunk.1)
        try expectEqual(chunked.bodyText, "bonjour", "corps en blocs")

        let echo = try spec("/echo", method: .put, body: "contenu")
        let echoed = try await HTTPTester.sendRaw(echo.0, spec: echo.1)
        try expectEqual(echoed.bodyText, "contenu", "corps envoyé")

        let hop = try spec("/saut")
        let redirected = try await HTTPTester.sendRaw(hop.0, spec: hop.1)
        try expectEqual(redirected.statusCode, 200, "redirection suivie")
        try expectEqual(redirected.redirects.count, 1, "un saut")
    }

    suite.add("HTTP : port fermé, erreur de l’outil en français") {
        let port: UInt16
        do {
            let server = try await LocalHTTPServer()
            port = server.port
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        do {
            _ = try await HTTPTester.send(HTTPRequestSpec(url: "http://127.0.0.1:\(port)/ok", timeout: 2))
            throw ToolError.processFailed("aucune erreur levée")
        } catch let error as ToolError {
            try expect(error != .processFailed("aucune erreur levée"), "doit échouer")
            try expect(error.localizedDescription.contains("127.0.0.1") || error.localizedDescription.contains("réseau"), "message : \(error.localizedDescription)")
        }
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw ToolError.processFailed(message) }
        return self
    }
}
