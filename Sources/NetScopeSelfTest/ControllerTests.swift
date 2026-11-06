import Foundation
import NetScopeCore

// Note 77 : contrôleurs UniFi Network, TP-Link Omada et Cisco Meraki. Réponses fixes
// (ControllerFixtures), transport de test : aucune connexion, aucun réseau.

private func ok(_ text: String, headers: [String: String] = [:]) -> ControllerResponse {
    ControllerResponse(status: 200, headers: headers, body: Data(text.utf8))
}

private func status(_ code: Int, _ text: String = "{}") -> ControllerResponse {
    ControllerResponse(status: code, body: Data(text.utf8))
}

private func mac(_ text: String) -> MACAddress { MACAddress(text)! }
private func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }

private let now = Date(timeIntervalSince1970: 1_730_811_700)

private func unifiRoutes(prefix: String, site: String = "ab12cd34") -> [String: ControllerResponse] {
    [prefix + "/api/self/sites": ok(UniFiFixtures.sites),
     prefix + "/api/s/\(site)/stat/sysinfo": ok(UniFiFixtures.sysinfo),
     prefix + "/api/s/\(site)/rest/networkconf": ok(UniFiFixtures.networks),
     prefix + "/api/s/\(site)/stat/device": ok(UniFiFixtures.devices),
     prefix + "/api/s/\(site)/stat/sta": ok(UniFiFixtures.clients)]
}

private func omadaRoutes(openAPI: Bool) -> [String: ControllerResponse] {
    let cid = "c4b2f1e0a9d84c7b8e2d1f0a9b8c7d6e"
    let base = openAPI ? "/openapi/v1/\(cid)" : "/\(cid)/api/v2"
    let site = base + "/sites/6450a1b2c3d4e5f600000002"
    var routes: [String: ControllerResponse] = [
        "/api/info": ok(OmadaFixtures.info),
        base + "/sites": ok(OmadaFixtures.sites),
        site + "/devices": ok(OmadaFixtures.devices),
        site + "/switches/50-91-E3-00-10-01/ports": ok(OmadaFixtures.ports),
        site + (openAPI ? "/aps/" : "/eaps/") + "50-91-E3-00-20-01": ok(OmadaFixtures.apDetail),
        site + "/clients": ok(OmadaFixtures.clients),
    ]
    if openAPI {
        routes["POST /openapi/authorize/token"] = ok(OmadaFixtures.token)
    } else {
        routes["POST /\(cid)/api/v2/login"] = ok(#"{"errorCode":0,"msg":"Log in successfully.","result":{"roleType":1,"token":"8f2a1c0e9b7d4e6fa1b2c3d4e5f60718"}}"#)
        routes["POST /\(cid)/api/v2/logout"] = ok(#"{"errorCode":0,"msg":"Success."}"#)
    }
    return routes
}

private func merakiRoutes() -> [String: ControllerResponse] {
    let net = "L_646829496481105433"
    let next = "<https://n149.meraki.com/api/v1/networks/\(net)/clients?perPage=1000&startingAfter=k74272e>; rel=next"
    return [
        "/api/v1/organizations": ok(MerakiFixtures.organizations),
        "/api/v1/organizations/549236/networks": ok(MerakiFixtures.networks),
        "/api/v1/networks/\(net)/devices": ok(MerakiFixtures.devices),
        "/api/v1/organizations/549236/devices/statuses": ok(MerakiFixtures.statuses),
        "/api/v1/devices/Q2HP-AAAA-0001/switch/ports": ok(MerakiFixtures.portConfigs),
        "/api/v1/devices/Q2HP-AAAA-0001/switch/ports/statuses": ok(MerakiFixtures.portStatuses),
        "/api/v1/devices/Q2KD-BBBB-0002/wireless/status": ok(MerakiFixtures.wirelessStatus),
        "/api/v1/networks/\(net)/clients": ok(MerakiFixtures.clientsPage1, headers: ["Link": next]),
    ]
}

/// Transport Meraki : la seconde page des clients répond à la requête qui porte startingAfter.
private final class MerakiPagedTransport: ControllerTransport, @unchecked Sendable {
    let base = ControllerFixedTransport(merakiRoutes())
    func send(_ request: ControllerRequest) async throws -> ControllerResponse {
        if request.path.hasSuffix("/clients"), request.query.contains(where: { $0.name == "startingAfter" }) {
            _ = try await base.send(request)
            return ok(MerakiFixtures.clientsPage2)
        }
        return try await base.send(request)
    }
}

private func readFailure(_ reader: ControllerReader) async -> ControllerReadFailure? {
    do {
        _ = try await reader.read(now: now)
        return nil
    } catch let failure as ControllerReadFailure {
        return failure
    } catch {
        return nil
    }
}

func registerControllerTests(_ suite: TestSuite) {
    suite.add("Contrôleurs : réglages d’un contrôleur (adresse, port, marque, aucun secret)") {
        var c = SiteController(kind: .unifi, host: " https://10.1.0.1:8443/manage ", port: 443)
        try expectEqual(c.cleanHost, "10.1.0.1", "adresse nettoyée")
        try expect(c.hasValidAddress, "adresse valide")
        try expectEqual(c.authMode, .unifiAPIKey, "clé d’API par défaut pour UniFi")
        c.host = "pas une adresse!"
        try expect(!c.hasValidAddress, "adresse invalide refusée")
        let meraki = SiteController(kind: .meraki, host: "")
        try expectEqual(meraki.cleanHost, "api.meraki.com", "Meraki : adresse fixe")
        try expect(meraki.hasValidAddress && !meraki.usesPinning, "Meraki : certificat public, sans empreinte")
        let omada = SiteController(kind: .omada, host: "10.30.0.5", authMode: .unifiAPIKey)
        try expectEqual(omada.authMode, .omadaOpenAPI, "mode d’une autre marque remplacé")
        try expectEqual(omada.effectivePort, 8043, "port Omada par défaut")
        try expect(!SiteController(kind: .omada, host: "10.30.0.5", authMode: .omadaWebAccount).isComplete, "identifiant requis")
        // Aucun secret dans le JSON (le secret est au Trousseau).
        let data = try JSONEncoder().encode(SiteController(kind: .omada, host: "10.30.0.5", account: "client-id-123"))
        let text = String(decoding: data, as: UTF8.self)
        try expect(!text.lowercased().contains("secret") && !text.lowercased().contains("password"), "aucun champ secret encodé")
        let back = try JSONDecoder().decode(SiteController.self, from: data)
        try expectEqual(back.account, "client-id-123", "relu")
    }

    suite.add("Contrôleurs : sites.json garde les contrôleurs, ignore une marque inconnue, reste identique sans eux") {
        let plain = Site(name: "Clinique")
        let encoder = JSONEncoder()
        let plainText = String(decoding: try encoder.encode(plain), as: UTF8.self)
        try expect(!plainText.contains("controllers"), "aucune clé « controllers » sans contrôleur")
        var site = plain
        site.controllers = [SiteController(kind: .unifi, host: "192.168.1.1", siteRef: "default")]
        let data = try encoder.encode(site)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var list = object["controllers"] as! [[String: Any]]
        list.append(["id": UUID().uuidString, "kind": "aruba-central", "host": "x"])
        object["controllers"] = list
        let decoded = try JSONDecoder().decode(Site.self, from: try JSONSerialization.data(withJSONObject: object))
        try expectEqual(decoded.controllers.count, 1, "marque inconnue ignorée")
        try expectEqual(decoded.controllers.first?.siteRef, "default", "contrôleur relu")
        // Filtre des switchs : un switch lu par le contrôleur du site actif est montré.
        let candidate = SiteSwitchFilter.Candidate(host: "192.168.1.2", controllerID: site.controllers[0].id)
        try expectEqual(SiteSwitchFilter.visible([candidate], activeSite: site, sites: [site], scanRanges: []), ["192.168.1.2"], "switch du contrôleur visible")
        try expect(SiteSwitchFilter.visible([candidate], activeSite: Site(name: "Autre"), sites: [site], scanRanges: []).isEmpty,
                   "masqué dans un autre site")
    }

    suite.add("UniFi : clé d’API, UniFi OS, site par sa description, switchs, bornes, clients") {
        let transport = ControllerFixedTransport(unifiRoutes(prefix: "/proxy/network"))
        let controller = SiteController(kind: .unifi, host: "192.168.1.1", siteRef: "Clinique")
        let report = try await ControllerReader(controller: controller, secret: "cle-api-unifi-secrete", transport: transport).read(now: now)
        try expect(transport.requests.allSatisfy { $0.method == "GET" }, "lecture seule avec une clé d’API")
        try expect(transport.requests.allSatisfy { $0.headers["X-API-KEY"] == "cle-api-unifi-secrete" }, "clé dans l’en-tête X-API-KEY")
        try expect(transport.requests.allSatisfy { $0.path.hasPrefix("/proxy/network/") }, "préfixe UniFi OS")
        try expectEqual(report.siteName, "Clinique", "site lu")
        try expectEqual(report.version, "9.0.114", "version")
        try expectEqual(report.controllerName, "UDM-Pro-Clinique", "nom")
        try expectEqual(report.switches.count, 1, "un switch (l’UDM sans ports LAN n’en est pas un)")
        let sw = report.switches[0]
        try expectEqual(sw.model, "USW-Pro-24-PoE", "modèle lisible")
        try expectEqual(sw.ports.count, 5, "ports")
        try expectEqual(sw.port(2)?.nativeVLAN, 20, "VLAN natif par networkconf")
        try expectEqual(sw.port(3)?.poePowerW, 8.42, "puissance PoE")
        try expectEqual(sw.port(3)?.poeClass, 4, "classe PoE")
        try expectEqual(sw.port(4)?.linkUp, false, "port sans lien")
        try expect(sw.port(1)?.isUplink == true, "uplink")
        try expect(sw.port(3)?.neighbor?.isAccessPoint == true, "borne sur le port 3")
        try expectEqual(sw.port(3)?.neighbor?.name, "U6-Accueil", "nom de la borne voisine")
        try expectEqual(report.aps.count, 1, "une borne")
        let ap = report.aps[0]
        try expectEqual(ap.model, "U6-Lite", "modèle de la borne")
        try expectEqual(ap.uplinkPort, 3, "port de la borne")
        try expectEqual(ap.radios.compactMap(\.channel), [6, 44], "canaux")
        try expectEqual(ap.radios.last?.widthMHz, 80, "largeur")
        try expectEqual(ap.ssids, ["Clinique-Invites", "Clinique-Personnel"], "SSID")
        try expectEqual(report.wiredClients.count, 2, "clients filaires")
        let printer = report.clients.first { $0.mac == mac("00:1b:a9:5e:70:01") }
        try expectEqual(printer?.switchName, "USW-Pro-Clinique", "switch du client filaire")
        try expectEqual(printer?.port, 2, "port")
        try expectEqual(printer?.hostname, "Imprimante accueil", "alias du contrôleur")
        let phone = report.clients.first { $0.mac == mac("f2:6a:19:c4:0e:58") }
        try expectEqual(phone?.rssi, -58, "signal en dBm (champ signal)")
        try expectEqual(phone?.band, .ghz5, "bande")
        try expectEqual(phone?.apName, "U6-Accueil", "borne du client")
        try expectEqual(phone?.ssid, "Clinique-Personnel", "SSID du client")
        // Diagnostic sans secret.
        let text = ControllerDiagnostic.text(calls: report.calls, controller: controller, report: report, secrets: ["cle-api-unifi-secrete"], date: now)
        try expect(!text.contains("cle-api-unifi-secrete"), "clé absente du diagnostic")
        try expect(text.contains("stat/device"), "appels listés")
    }

    suite.add("UniFi : compte local d’un contrôleur classique (session ouverte puis fermée)") {
        var routes = unifiRoutes(prefix: "", site: "default")
        routes["POST /api/login"] = ok(#"{"meta":{"rc":"ok"},"data":[]}"#, headers: ["X-CSRF-Token": "jeton-csrf-1234"])
        routes["POST /api/logout"] = ok(#"{"meta":{"rc":"ok"},"data":[]}"#)
        let transport = ControllerFixedTransport(routes)
        let controller = SiteController(kind: .unifi, host: "unifi.exemple.ca", port: 8443, unifiOS: false, authMode: .unifiLocalAccount,
                                        account: "netscope-lecture", siteRef: "")
        let report = try await ControllerReader(controller: controller, secret: "MotDePasse!2026", transport: transport).read(now: now)
        let requests = transport.requests
        try expectEqual(requests.first?.path, "/api/login", "session ouverte d’abord")
        try expect(String(decoding: requests.first?.body ?? Data(), as: UTF8.self).contains("netscope-lecture"), "identifiant envoyé dans le corps")
        try expectEqual(requests.last?.path, "/api/logout", "session fermée à la fin")
        try expect(requests.dropFirst().filter { $0.method == "GET" }.allSatisfy { $0.headers["X-CSRF-Token"] == "jeton-csrf-1234" }, "jeton CSRF repris")
        try expect(requests.filter { $0.method == "GET" }.allSatisfy { !$0.path.hasPrefix("/proxy") }, "sans préfixe UniFi OS")
        try expectEqual(report.siteName, "Default", "site par défaut")
        try expect(!report.calls.contains { $0.body.contains("MotDePasse!2026") }, "mot de passe jamais gardé")
    }

    suite.add("UniFi : site introuvable (sites proposés), clé refusée (appels gardés)") {
        let transport = ControllerFixedTransport(unifiRoutes(prefix: "/proxy/network"))
        let reader = ControllerReader(controller: SiteController(kind: .unifi, host: "192.168.1.1", siteRef: "Laval"), secret: "cle-api", transport: transport)
        let failure = await readFailure(reader)
        guard case .scopeNotFound(let wanted, let available)? = failure?.error else { throw TestFailure(message: "site introuvable attendu", file: #fileID, line: #line) }
        try expectEqual(wanted, "Laval", "site demandé")
        try expect(available.contains("Clinique (ab12cd34)"), "sites proposés")
        let refused = ControllerFixedTransport(["/proxy/network/api/self/sites": status(401, #"{"error":{"code":401,"message":"Unauthorized"}}"#)])
        let rejected = await readFailure(ControllerReader(controller: SiteController(kind: .unifi, host: "192.168.1.1"), secret: "mauvaise", transport: refused))
        try expectEqual(rejected?.error, .authRejected(.unifi), "clé refusée")
        try expectEqual(rejected?.calls.count, 1, "appel gardé pour le diagnostic")
        try expect(rejected?.error.errorDescription?.contains("401") == true, "message en français avec le code")
        let missing = await readFailure(ControllerReader(controller: SiteController(kind: .unifi, host: "192.168.1.1"), secret: "", transport: refused))
        try expectEqual(missing?.error, .missingSecret, "secret absent")
    }

    suite.add("Omada : Open API (omadacId lu sur /api/info, jeton d’accès, ports, radios, clients)") {
        let transport = ControllerFixedTransport(omadaRoutes(openAPI: true))
        let controller = SiteController(kind: .omada, host: "10.30.0.5", account: "f3a9c1d2e4b5", siteRef: "bureau québec")
        let report = try await ControllerReader(controller: controller, secret: "secret-client-omada", transport: transport).read(now: now)
        let tokenRequest = transport.requests.first { $0.path == "/openapi/authorize/token" }
        try expectEqual(tokenRequest?.method, "POST", "demande du jeton")
        let body = String(decoding: tokenRequest?.body ?? Data(), as: UTF8.self)
        try expect(body.contains("c4b2f1e0a9d84c7b8e2d1f0a9b8c7d6e") && body.contains("f3a9c1d2e4b5"), "omadacId et client_id envoyés")
        try expect(transport.requests.filter { $0.method == "GET" && $0.path != "/api/info" }
                    .allSatisfy { $0.headers["Authorization"] == "AccessToken=AT-RCio7GffTkt4sJDpNZkeeKF7ow7MnYv0" }, "jeton dans l’en-tête")
        try expectEqual(report.version, "5.14.26.1", "version")
        try expectEqual(report.siteName, "Bureau Québec", "site par son nom, casse ignorée")
        try expectEqual(report.switches.count, 1, "un switch (la passerelle n’en est pas un)")
        let sw = report.switches[0]
        try expectEqual(sw.model, "TL-SG3428MP", "modèle court")
        try expectEqual(sw.firmware, "2.0.12", "firmware court")
        try expectEqual(sw.port(1)?.speedMbps, 1000, "code de vitesse 3")
        try expectEqual(sw.port(2)?.speedMbps, 100, "code de vitesse 2")
        try expectEqual(sw.port(28)?.speedMbps, 10_000, "code de vitesse 5")
        try expectEqual(sw.port(1)?.poePowerW, 12.6, "PoE")
        try expectEqual(sw.port(2)?.nativeVLAN, 10, "VLAN natif")
        try expectEqual(sw.port(3)?.enabled, false, "port désactivé")
        try expect(sw.port(1)?.neighbor?.isAccessPoint == true, "borne rattachée au port 1")
        let ap = report.aps[0]
        try expectEqual(ap.radios.compactMap(\.channel), [6, 44], "canaux lus dans le détail")
        try expectEqual(ap.radios.first { $0.band == .ghz5 }?.widthMHz, 80, "largeur")
        try expectEqual(ap.uplinkSwitchName, "SW-QC-01", "switch de la borne")
        let wired = report.clients.first { $0.mac == mac("3C-22-FB-7E-05-C1") }
        try expect(wired?.isWired == true && wired?.port == 2 && wired?.vlan == 10, "client filaire, port et VLAN")
        let phone = report.clients.first { $0.mac == mac("F2-6A-19-C4-0E-77") }
        try expectEqual(phone?.rssi, -61, "signal")
        try expectEqual(phone?.signalPercent, 72, "signal en %")
        try expectEqual(phone?.band, .ghz5, "bande d’après radioId")
        try expectEqual(phone?.rateMbps, 866, "débit en Mb/s")
        let laptop = report.clients.first { $0.mac == mac("A4-83-E7-44-55-66") }
        try expectEqual(laptop?.apName, "EAP-QC-Accueil", "borne nommée d’après sa MAC")
        let text = ControllerDiagnostic.text(calls: report.calls, controller: controller, report: report, secrets: ["secret-client-omada"], date: now)
        try expect(!text.contains("AT-RCio7GffTkt4sJDpNZkeeKF7ow7MnYv0") && !text.contains("secret-client-omada"), "jeton et secret retirés")
    }

    suite.add("Omada : API web (compte), secret refusé, site introuvable") {
        let transport = ControllerFixedTransport(omadaRoutes(openAPI: false))
        let controller = SiteController(kind: .omada, host: "10.30.0.5", port: 443, authMode: .omadaWebAccount, account: "lecture",
                                        siteRef: "6450a1b2c3d4e5f600000002")
        let report = try await ControllerReader(controller: controller, secret: "motdepasse", transport: transport).read(now: now)
        try expect(transport.requests.contains { $0.path.hasSuffix("/api/v2/login") }, "session ouverte")
        try expect(transport.requests.last?.path.hasSuffix("/api/v2/logout") == true, "session fermée")
        try expect(transport.requests.filter { $0.method == "GET" && $0.path != "/api/info" }
                    .allSatisfy { $0.headers["Csrf-Token"] == "8f2a1c0e9b7d4e6fa1b2c3d4e5f60718" }, "jeton Csrf-Token")
        try expectEqual(report.aps.first?.radios.count, 2, "radios lues par /eaps/")
        var refused = omadaRoutes(openAPI: true)
        refused["POST /openapi/authorize/token"] = ok(OmadaFixtures.badToken)
        let failure = await readFailure(ControllerReader(controller: SiteController(kind: .omada, host: "10.30.0.5", account: "x"), secret: "y",
                                                         transport: ControllerFixedTransport(refused)))
        try expectEqual(failure?.error, .authRejected(.omada), "client refusé")
        let lost = await readFailure(ControllerReader(controller: SiteController(kind: .omada, host: "10.30.0.5", account: "x", siteRef: "Montréal"),
                                                      secret: "y", transport: ControllerFixedTransport(omadaRoutes(openAPI: true))))
        guard case .scopeNotFound(_, let available)? = lost?.error else { throw TestFailure(message: "site introuvable attendu", file: #fileID, line: #line) }
        try expectEqual(available, ["Siège social", "Bureau Québec"], "sites proposés")
    }

    suite.add("Meraki : organisation et réseau par nom, ports (PoE en W, LLDP), bornes, clients sur deux pages") {
        let transport = MerakiPagedTransport()
        let controller = SiteController(kind: .meraki, siteRef: "usine drummondville", orgRef: "Groupe Exemple")
        let report = try await ControllerReader(controller: controller, secret: "6bec40cf957de430a6f1f2baa056b99a4fac9ea0", transport: transport).read(now: now)
        let requests = transport.base.requests
        try expect(requests.allSatisfy { $0.method == "GET" && $0.headers["Authorization"] == "Bearer 6bec40cf957de430a6f1f2baa056b99a4fac9ea0" },
                   "GET seulement, clé dans Authorization")
        try expectEqual(report.siteName, "Usine Drummondville", "réseau")
        try expectEqual(report.switches.count, 1, "switch MS")
        try expectEqual(report.aps.count, 1, "borne MR (le MX n’est ni l’un ni l’autre)")
        let sw = report.switches[0]
        try expectEqual(sw.online, true, "en ligne")
        try expectEqual(sw.firmware, "MS 16.7", "firmware lisible")
        try expectEqual(sw.port(1)?.poePowerW, 12.6, "1,05 Wh en 5 min = 12,6 W")
        try expectEqual(sw.port(1)?.taggedVLANs, [1, 12, 20, 21], "VLAN permis du trunk")
        try expectEqual(sw.port(2)?.nativeVLAN, 12, "VLAN d’accès")
        try expectEqual(sw.port(2)?.speedMbps, 100, "vitesse")
        try expectEqual(sw.port(2)?.alerts, ["CRC align errors"], "erreurs signalées")
        try expectEqual(sw.port(3)?.enabled, false, "port désactivé")
        try expect(sw.port(1)?.neighbor?.isAccessPoint == true, "borne voisine par LLDP")
        try expect(sw.port(9)?.isUplink == true, "uplink")
        let ap = report.aps[0]
        try expectEqual(ap.online, true, "« alerting » compte comme en ligne")
        try expectEqual(ap.uplinkPort, 1, "borne rattachée au port 1")
        try expectEqual(ap.radios.compactMap(\.channel), [11, 36], "canaux")
        try expectEqual(ap.ssids, ["Usine-Interne"], "SSID diffusés seulement")
        try expectEqual(report.clients.count, 2, "deux pages de clients")
        let plc = report.clients.first { $0.mac == mac("00:30:de:40:12:01") }
        try expect(plc?.isWired == true && plc?.port == 2 && plc?.switchName == "MS120-Production" && plc?.vlan == 12, "client filaire")
        let tablet = report.clients.first { $0.mac == mac("f2:6a:19:c4:0e:99") }
        try expect(tablet?.isWired == false && tablet?.apName == "MR46-Atelier" && tablet?.ssid == "Usine-Interne", "client Wi-Fi")
        try expect(report.notes.contains { $0.contains("Signal") }, "limite du signal expliquée")
        let wrongOrg = await readFailure(ControllerReader(controller: SiteController(kind: .meraki, orgRef: "Autre"), secret: "cle",
                                                          transport: ControllerFixedTransport(merakiRoutes())))
        guard case .scopeNotFound? = wrongOrg?.error else { throw TestFailure(message: "organisation introuvable attendue", file: #fileID, line: #line) }
    }

    suite.add("Contrôleurs : relevés de switch, emplacement des appareils filaires et Wi-Fi, noms, MAC complétées") {
        let transport = ControllerFixedTransport(unifiRoutes(prefix: "/proxy/network"))
        let report = try await ControllerReader(controller: SiteController(kind: .unifi, host: "192.168.1.1", siteRef: "ab12cd34"),
                                                secret: "cle", transport: transport).read(now: now)
        let siteID = UUID()
        let reading = ControllerSiteReading(controllerID: UUID(), siteID: siteID, siteName: "Clinique Exemple", report: report)
        let snapshots = ControllerConvert.snapshots([reading])
        try expectEqual(snapshots.count, 1, "un relevé")
        let snapshot = snapshots[0]
        try expectEqual(snapshot.host, ip("192.168.1.2"), "adresse de gestion du switch")
        try expectEqual(snapshot.controllerName, "Clinique Exemple", "site marqué")
        try expectEqual(snapshot.controllerSourceLabel, "UniFi", "source « via UniFi »")
        try expectEqual(snapshot.system.brand, "Ubiquiti", "marque par sysObjectID")
        try expectEqual(snapshot.physicalPorts.count, 5, "ports physiques")
        try expectEqual(snapshot.pvid[2], 20, "VLAN natif")
        try expect(snapshot.poePorts.contains(3), "PoE délivré sur le port 3")
        try expectEqual(snapshot.neighbor(on: 3)?.capabilities, [.accessPoint], "borne voisine")
        try expectEqual(snapshot.hardware?.model, "USW-Pro-24-PoE", "fiche matériel")
        // Accès aux bornes : le port 3 mène à U6-Accueil (note 84).
        try expectEqual(InvWirelessContext.accessPointPorts(in: snapshots)["USW-Pro-Clinique · Port 3"], "U6-Accueil", "port de borne")
        // Appareils du scan : la MAC manquante de l'imprimante (autre VLAN) vient du contrôleur.
        let devices = [Device(ip: ip("192.168.20.30")),
                       Device(ip: ip("192.168.1.50"), mac: mac("3c:22:fb:7e:05:b2")),
                       Device(ip: ip("192.168.1.61"), mac: mac("f2:6a:19:c4:0e:58")),
                       Device(ip: ip("192.168.1.21"), mac: mac("d8:b3:70:aa:bb:01"))]
        let applied = ControllerConvert.apply([reading], to: devices, controller: snapshots, snmp: [])
        try expectEqual(applied.filled, 1, "MAC complétée")
        let printer = applied.devices[0]
        try expectEqual(printer.switchName, "USW-Pro-Clinique", "switch de l’imprimante")
        try expectEqual(printer.switchPort, "Port 2", "port")
        try expectEqual(printer.vlan, 20, "VLAN")
        try expectEqual(printer.hostname, "Imprimante accueil", "nom du contrôleur")
        try expectEqual(printer.nameSource, .controller, "source du nom")
        try expectEqual(applied.devices[1].switchPort, "Port 5", "poste filaire situé")
        try expectEqual(applied.devices[2].switchName, "U6-Accueil", "client Wi-Fi rattaché à sa borne")
        try expectEqual(applied.devices[2].switchPort, "Wi-Fi", "port « Wi-Fi »")
        try expectEqual(applied.devices[3].switchPort, "Port 3", "la borne elle-même sur son port")
        try expectEqual(applied.wireless, 1, "un client Wi-Fi")
        // Reconnaissance Wi-Fi (note 84) : le client du contrôleur est une preuve du Wi-Fi.
        let overview = ControllerConvert.wifiOverview([reading])
        try expectEqual(overview.aps.count, 1, "borne au format commun")
        try expectEqual(overview.clients.count, 2, "clients Wi-Fi au format commun")
        let context = InvWirelessContext(overview: overview, devices: applied.devices, neighborPorts: InvWirelessContext.accessPointPorts(in: snapshots))
        try expectEqual(context.client(mac: mac("f2:6a:19:c4:0e:58"), ip: ip("192.168.1.61"))?.apName, "U6-Accueil", "client reconnu")
        try expect(context.isAccessPoint(ip: ip("192.168.1.21"), mac: nil), "la borne est filaire")
        // Fusion avec le Wi-Fi des FortiGate.
        let merged = ControllerConvert.merged(FortiWifiOverview(aps: [FortiManagedAP(site: "Siège", name: "FAP-1")], sites: ["Siège"]), overview)
        try expectEqual(merged.sites, ["Siège", "Clinique Exemple"], "deux sources")
        try expectEqual(merged.aps.count, 2, "bornes réunies")
        // Résumé.
        let summary = ControllerSummary([reading])
        try expectEqual(summary.weakClients, 1, "un client sous −70 dBm")
        try expectEqual(summary.byBand[.ghz5], 2, "clients en 5 GHz")
    }

    suite.add("Contrôleurs : deux switchs sans adresse ou à la même adresse restent distincts") {
        let a = ControllerReport(kind: .omada, controllerName: "A", switches: [ControllerSwitch(name: "SW-A", ip: ip("10.0.0.2"))])
        let b = ControllerReport(kind: .meraki, controllerName: "B", switches: [ControllerSwitch(name: "SW-B", ip: ip("10.0.0.2")),
                                                                               ControllerSwitch(name: "SW-C")])
        let snapshots = ControllerConvert.snapshots([ControllerSiteReading(controllerID: UUID(), siteID: UUID(), siteName: "A", report: a),
                                                     ControllerSiteReading(controllerID: UUID(), siteID: UUID(), siteName: "B", report: b)],
                                                    avoiding: [ip("10.255.1.2")])
        try expectEqual(Set(snapshots.map(\.host)).count, 3, "adresses distinctes")
        try expectEqual(snapshots[0].host, ip("10.0.0.2"), "la première garde son adresse")
        try expect(snapshots[1].host.value < (1 << 24), "adresse de remplacement jamais interrogée")
        try expectEqual(snapshots[1].controllerSourceLabel, "Meraki", "marque")
    }

    suite.add("Contrôleurs : aucune action sur les ports d’un switch UniFi, Omada ou Meraki") {
        let target = PortActionTarget(switchName: "MS120-Production", switchHost: ip("10.40.0.2"), portName: "Port 3", ifIndex: 3,
                                      poe: SNMPPoEPort(group: 1, port: 3, ifIndex: 3, adminEnabled: true, detection: .deliveringPower),
                                      viaFortiGate: true, readOnlyController: "Meraki")
        var settings = PortActionSettings()
        settings.enabled = true
        let decision = PortActionGuard.decide(.poeCycle, target: target, settings: settings,
                                               hasWriteCredentials: true, fortiGateProblem: nil)
        try expectEqual(decision.refusals, [.readOnlyController("Meraki")], "lecture seule, jamais de repli SNMP")
        try expect(decision.channel == nil, "aucun moyen d’action")
    }

    suite.add("Contrôleurs : secrets retirés, redirections limitées") {
        let text = #"{"x_passphrase":"WifiSecret1","accessToken":"AT-123456","ok":"oui"} cle=ABCDEFGH AccessToken=AT-XYZ"#
        let clean = ControllerRedact.clean(text, secrets: ["ABCDEFGH"])
        try expect(!clean.contains("WifiSecret1") && !clean.contains("AT-123456") && !clean.contains("ABCDEFGH") && !clean.contains("AT-XYZ"),
                   "valeurs secrètes retirées")
        try expect(clean.contains("\"ok\":\"oui\""), "le reste est gardé")
        try expect(ControllerURLSessionTransport.redirectAllowed(from: "api.meraki.com", to: "n149.meraki.com", kind: .meraki), "nœud Meraki permis")
        try expect(!ControllerURLSessionTransport.redirectAllowed(from: "api.meraki.com", to: "meraki.com.exemple.net", kind: .meraki), "autre domaine refusé")
        try expect(!ControllerURLSessionTransport.redirectAllowed(from: "10.1.0.1", to: "10.1.0.2", kind: .unifi), "autre hôte refusé")
        try expectEqual(MerakiParsers.nextPage(link: #"<https://n1.meraki.com/api/v1/x?startingAfter=a>; rel=first, <https://n1.meraki.com/api/v1/x?startingAfter=b>; rel=next"#)?
                            .absoluteString, "https://n1.meraki.com/api/v1/x?startingAfter=b", "page suivante")
        let url = ControllerURLSessionTransport.url(host: "10.1.0.1", port: 8443, request: ControllerRequest(path: "/api/s/default/stat/device"))
        try expectEqual(url?.absoluteString, "https://10.1.0.1:8443/api/s/default/stat/device", "adresse sans secret")
    }
}
