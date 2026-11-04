import Foundation
import NetScopeCore

// Note 46 : clients Wi-Fi par borne et par SSID, fiche complète, historique du signal. Données
// fixes, aucun réseau.

private enum ClientFixtures {
    /// FortiOS 7.4 avec les champs de la fiche complète.
    static let detailed74 = """
    {"results":[
      {"mac":"d6:4e:81:7a:33:c0","ip":"10.182.122.133","hostname":"Android_89UM1WTN","ssid":"Groupe-Interne","vap_name":"wifi-interne",
       "wtp_name":"AP-ETG2","wtp_id":"FP231FTF22004187","radio_id":1,"radio_type":"802.11n-2G","channel":11,"signal":-77,"noise":-93,
       "data_rate_bps":26000000,"data_txrate_bps":26000000,"data_rxrate_bps":18000000,"sta_maxrate":144.4,
       "security_str":"WPA2 Enterprise","authentication":"802.1X","user":"GROUPE\\\\marc","channel_bandwidth":"20MHz",
       "11k_capable":true,"11v_capable":false,"11r_capable":"disable","tx_retry_percentage":22,"idle_time":4,
       "tx_bytes":123456789,"rx_bytes":2345678,"association_time":720},
      {"mac":"3c:22:fb:7e:05:b1","ip":"10.182.122.135","hostname":"Macmini-de-Dany","ssid":"Groupe-Interne","wtp_name":"AP-ACCUEIL",
       "radio_id":2,"radio_type":"802.11ax-5G","channel":44,"signal":-52,"noise":-95,"sta_txrate":866,"sta_rxrate":"600","security":2}
    ],"status":"success"}
    """

    static func ap(_ name: String, site: String = "Siège", serial: String, radios: [FortiAPRadio]) -> FortiManagedAP {
        FortiManagedAP(site: site, name: name, wtpID: serial, serial: serial, model: "FAP-231F", connected: true, radios: radios)
    }

    static let etg2 = ap("AP-ETG2", serial: "FP231FTF22004187", radios: [
        FortiAPRadio(radioID: 1, band: .ghz24, channel: 11, widthMHz: 20, clientCount: 2, channelUtilization: 38),
        FortiAPRadio(radioID: 2, band: .ghz5, channel: 36, widthMHz: 80, clientCount: 3, channelUtilization: 82),
        FortiAPRadio(radioID: 3, band: .ghz5, channel: 100, widthMHz: 40, clientCount: 0),
    ])

    static func client(_ last: UInt8, site: String = "Siège", ssid: String = "Groupe-Interne", ap: String = "AP-ETG2", radio: Int? = 2,
                       band: WifiBand? = .ghz5, rssi: Int? = -60, ip: String? = nil, host: String? = nil) -> FortiWifiClient {
        FortiWifiClient(site: site, mac: MACAddress(bytes: [0x5C, 0xE9, 0x1E, 0x40, 0x00, last]), ip: ip.flatMap(IPv4Address.init),
                        hostname: host ?? "client-\(last)", ssid: ssid, apName: ap, apKey: nil, radioID: radio, band: band,
                        channel: band == .ghz24 ? 11 : 36, rssi: rssi, noise: -95)
    }
}

func registerFortiWifiClientTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_700_000)
    func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Fiche complète

    suite.add("Wi-Fi clients : fiche complète lue dans la même réponse (débits, standard, sécurité, octets)") {
        let clients = try FortiWifiParsers.clients(data(ClientFixtures.detailed74), now: now).unwrapWifi("clients détaillés")
        let android = clients[0]
        try expectEqual(android.rateMbps, 26, "débit négocié inchangé")
        try expectEqual(android.info.txRateMbps, 26, "descendant en b/s")
        try expectEqual(android.info.rxRateMbps, 18, "montant en b/s")
        try expectEqual(android.info.maxRateMbps, 144.4, "débit maximal")
        try expectEqual(android.standard, .wifi4, "802.11n-2G : Wi-Fi 4")
        try expectEqual(android.info.security, "WPA2 Enterprise", "sécurité")
        try expectEqual(android.info.authenticationLabel, "802.1X", "authentification donnée")
        try expectEqual(android.info.user, "GROUPE\\marc", "utilisateur")
        try expectEqual(android.info.widthMHz, 20, "largeur")
        try expectEqual(android.info.roamingCapabilities, "802.11k", "capacités d'itinérance")
        try expectEqual(android.info.txRetryPercent, 22, "retransmissions")
        try expectEqual(android.info.bytesToClient, 123_456_789, "octets vers le client")
        try expectEqual(android.info.bytesFromClient, 2_345_678, "octets du client")
        try expectEqual(android.info.vapName, "wifi-interne", "VAP")
        let mac = clients[1]
        try expectEqual(mac.info.txRateMbps, 866, "sta_txrate en Mb/s")
        try expectEqual(mac.info.rxRateMbps, 600, "sta_rxrate en texte")
        try expectEqual(mac.standard, .wifi6, "802.11ax-5G : Wi-Fi 6")
        try expect(mac.info.security == nil, "« security » numérique ignoré")
        try expect(mac.info.bytesToClient == nil, "octets absents : nil (« — » dans la fiche)")

        // Réponse 7.4 habituelle (sans les champs de la fiche) : rien ne change pour les champs déjà lus.
        let plain = try FortiWifiParsers.clients(data(FortiWifiFixtures.client74), now: now).unwrapWifi("clients 7.4")
        try expectEqual(plain[0].rateMbps, 866.7, "débit inchangé")
        try expectEqual(plain[0].snr, 43, "SNR inchangé")
        let missing = FortiWifiClientFields.missing(plain)
        try expect(missing.contains { $0.hasPrefix("octets échangés") }, "octets notés absents : \(missing)")
        try expect(missing.contains { $0.hasPrefix("débit montant") }, "débit montant noté absent")
        try expect(!missing.contains { $0.hasPrefix("signal") }, "signal présent")
        try expect(FortiWifiClientFields.diagnosticLine(plain)?.contains("absents de la réponse") == true, "ligne du diagnostic brut")
        try expect(FortiWifiClientFields.missing([]).isEmpty, "aucun client : rien à noter")
    }

    suite.add("Wi-Fi clients : standard Wi-Fi 4 à 7 d'après la norme et la bande") {
        try expectEqual(WifiStandard.parse("802.11ax-5G"), .wifi6, "ax 5G")
        try expectEqual(WifiStandard.parse("802.11ax-6G"), .wifi6E, "ax 6G")
        try expectEqual(WifiStandard.parse("11ax", band: .ghz6), .wifi6E, "ax en 6 GHz")
        try expectEqual(WifiStandard.parse("802.11be"), .wifi7, "be")
        try expectEqual(WifiStandard.parse("802.11ac"), .wifi5, "ac")
        try expectEqual(WifiStandard.parse("802.11ac-2G"), .wifi5, "ac 2G")
        try expectEqual(WifiStandard.parse("802.11n,g"), .wifi4, "n")
        try expectEqual(WifiStandard.parse("802.11g"), .legacy, "g")
        try expectEqual(WifiStandard.parse("VHT80"), .wifi5, "VHT")
        try expectEqual(WifiStandard.parse(""), nil, "vide")
        try expect(WifiStandard.wifi4 < .wifi6, "ordre")
        let six = FortiWifiClient(mac: MACAddress("AA:BB:CC:00:00:01")!, band: .ghz6)
        try expectEqual(six.standard, .wifi6E, "6 GHz sans norme : Wi-Fi 6E")
    }

    // MARK: Regroupements

    suite.add("Wi-Fi clients : clients d'une borne par radio puis par SSID, avec leur nombre") {
        let clients = [
            ClientFixtures.client(1, radio: 2), ClientFixtures.client(2, radio: 2, rssi: -75),
            ClientFixtures.client(3, ssid: "Invités", radio: 2),
            ClientFixtures.client(4, radio: 1, band: .ghz24), ClientFixtures.client(5, ssid: "Invités", radio: nil, band: .ghz24),
            ClientFixtures.client(6, ap: "AP-ACCUEIL"),
            ClientFixtures.client(7, site: "Laval"),
        ]
        let groups = FortiWifiClientGroups.byRadio(ap: ClientFixtures.etg2, clients: clients)
        try expectEqual(groups.map(\.radioID), [1, 2, 3], "trois radios en service, dans l'ordre")
        try expectEqual(groups.map(\.count), [2, 3, 0], "radio inconnue rangée d'après la bande ; autre borne et autre site exclus")
        try expectEqual(groups[1].ssids.map(\.ssid), ["Groupe-Interne", "Invités"], "le plus de clients d'abord")
        try expectEqual(groups[1].ssids.map(\.count), [2, 1], "nombre par SSID")
        try expectEqual(groups[1].ssids[0].clients.first?.rssi, -75, "le plus faible en tête")
        try expect(groups[1].title.contains("Radio 2") && groups[1].title.contains("canal 36"), "titre de la radio : \(groups[1].title)")
        let counts = FortiWifiClientGroups.ssidCounts(ap: ClientFixtures.etg2, clients: clients)
        try expectEqual(counts.map(\.ssid), ["Groupe-Interne", "Invités"], "SSID de la borne")
        try expectEqual(counts.map(\.count), [3, 2], "toutes radios confondues")
    }

    suite.add("Wi-Fi clients : vue par SSID, site par site, sans fusion entre deux sites") {
        let overview = FortiWifiOverview(
            aps: [ClientFixtures.etg2],
            clients: [ClientFixtures.client(1), ClientFixtures.client(2, ap: "AP-ACCUEIL", radio: 1, band: .ghz24),
                      ClientFixtures.client(3, ssid: "Invités"), ClientFixtures.client(1, site: "Laval", ap: "AP-LAV-QUAI")],
            ssids: [FortiSSID(site: "Siège", name: "wifi-interne", ssid: "Groupe-Interne", security: "wpa2-only-enterprise", vlan: 20),
                    FortiSSID(site: "Siège", name: "wifi-invites", ssid: "Invités", security: "open", vlan: 60),
                    FortiSSID(site: "Siège", name: "wifi-iot", ssid: "IoT", security: "wpa2-only-personal", vlan: 70),
                    FortiSSID(site: "Laval", name: "wifi-interne", ssid: "Groupe-Interne", vlan: 10)],
            sites: ["Siège", "Laval"])
        let groups = FortiWifiClientGroups.bySSID(overview)
        try expectEqual(groups.map(\.id), ["Siège|Groupe-Interne", "Siège|Invités", "Siège|IoT", "Laval|Groupe-Interne"], "ordre et identifiants")
        try expectEqual(groups.map(\.count), [2, 1, 0, 1], "même SSID et même MAC sur deux sites : deux groupes")
        try expectEqual(groups[0].apNames, ["AP-ACCUEIL", "AP-ETG2"], "bornes du SSID")
        try expectEqual(groups[0].bands, [.ghz24, .ghz5], "bandes du SSID")
        try expectEqual(groups[0].bandsLabel, "2,4 et 5\u{00A0}GHz", "libellé des bandes")
        try expectEqual(groups[0].config?.vlan, 20, "configuration du SSID")
        try expectEqual(groups[3].config?.vlan, 10, "configuration du SSID de Laval, pas celle du Siège")
    }

    suite.add("Wi-Fi clients : filtres SSID, borne, bande, signal faible et recherche") {
        let weak = ClientFixtures.client(1, rssi: -78, ip: "10.0.0.5", host: "Galaxy-S23-Marc")
        let strong = ClientFixtures.client(2, ssid: "Invités", ap: "AP-ACCUEIL", radio: 1, band: .ghz24, rssi: -50)
        try expect(FortiWifiClientFilter(weakOnly: true).matches(weak) && !FortiWifiClientFilter(weakOnly: true).matches(strong), "signal faible")
        try expect(FortiWifiClientFilter(ssid: "Invités").matches(strong) && !FortiWifiClientFilter(ssid: "Invités").matches(weak), "SSID")
        try expect(FortiWifiClientFilter(apName: "ap-etg2").matches(weak), "borne sans casse")
        try expect(FortiWifiClientFilter(band: .ghz24).matches(strong) && !FortiWifiClientFilter(band: .ghz24).matches(weak), "bande")
        try expect(!FortiWifiClientFilter().isActive && FortiWifiClientFilter(band: .ghz5).isActive, "filtre actif")
        try expect(FortiWifiClientGroups.matches(weak, text: "galaxy"), "par nom")
        try expect(FortiWifiClientGroups.matches(weak, text: "10.0.0.5"), "par IP")
        try expect(FortiWifiClientGroups.matches(weak, text: "5c:e9:1e:40:00:01"), "par MAC")
        try expect(FortiWifiClientGroups.matches(weak, text: "5ce91e400001"), "MAC sans séparateur")
        try expect(!FortiWifiClientGroups.matches(weak, text: "iphone"), "aucun mot")
    }

    // MARK: Rattachement au Scanner

    suite.add("Wi-Fi clients : rattachement à l'appareil du Scanner par MAC, dans le site actif seulement") {
        let mac = MACAddress(bytes: [0x5C, 0xE9, 0x1E, 0x40, 0x00, 1])
        let device = Device(ip: IPv4Address("10.182.120.40")!, mac: mac, isOnline: true)
        let noMAC = Device(ip: IPv4Address("10.182.120.77")!, isOnline: true)
        let siege = ClientFixtures.client(1, ip: "10.182.120.40")
        let laval = ClientFixtures.client(1, site: "Laval", ip: "10.182.120.40")
        let byIP = ClientFixtures.client(9, ip: "10.182.120.77")
        let links = FortiWifiClientLink.devices(for: [siege, laval, byIP], devices: [device, noMAC], activeSites: ["Siège"])
        try expectEqual(links[siege.id], device.id, "même MAC, site actif")
        try expect(links[laval.id] == nil, "même MAC sur un autre site : jamais rattaché")
        try expectEqual(links[byIP.id], noMAC.id, "appareil sans MAC : par IP unique")
        let twice = FortiWifiClientLink.devices(for: [byIP, ClientFixtures.client(10, ip: "10.182.120.77")], devices: [noMAC], activeSites: ["Siège"])
        try expect(twice.isEmpty, "IP partagée par deux clients : aucun rattachement")
        try expectEqual(FortiWifiClientLink.client(for: device, clients: [laval, siege], activeSites: ["Siège"])?.site, "Siège", "client de l'appareil")
        try expect(FortiWifiClientLink.client(for: device, clients: [laval], activeSites: ["Siège"]) == nil, "client d'un autre site ignoré")
    }

    // MARK: Historique du signal

    suite.add("Wi-Fi clients : historique du signal borné (nombre, âge, clients, lectures rapprochées)") {
        let limits = FortiWifiSignalHistory.Limits(samplesPerClient: 5, maxAge: 3600, clients: 2, minInterval: 30)
        var history = FortiWifiSignalHistory()
        let a = ClientFixtures.client(1, rssi: -60), b = ClientFixtures.client(2), c = ClientFixtures.client(3)
        for k in 0..<8 { history.record([a], at: now.addingTimeInterval(Double(k) * 60), limits: limits) }
        try expectEqual(history.samples(for: a.mac).count, 5, "série bornée au nombre de relevés")
        try expectEqual(history.samples(for: a.mac).first?.date, now.addingTimeInterval(180), "les plus anciens tombent")
        try expect(!history.record([a], at: now.addingTimeInterval(7 * 60 + 10), limits: limits), "lecture trop rapprochée ignorée")
        let later = now.addingTimeInterval(7 * 60 + 2 * 3600)
        history.record([b, c], at: later, limits: limits)
        try expect(history.samples(for: a.mac).isEmpty, "relevés trop vieux retirés")
        history.record([a], at: later.addingTimeInterval(60), limits: limits)
        try expectEqual(history.series.count, 2, "nombre de clients borné : \(history.series.keys.sorted())")
        try expect(!history.samples(for: a.mac).isEmpty, "le plus récent reste")
        try expect(history.readings.allSatisfy { $0 >= later.addingTimeInterval(60 - 3600) }, "lectures bornées par l'âge")
        let decoded = try FortiWifiSignalHistory.decode(history.encoded().unwrapWifi("encodé")).unwrapWifi("relu")
        try expectEqual(decoded, history, "fichier relu à l'identique")
        try expect(FortiWifiSignalHistory.decode(Data(#"{"version":99,"series":{},"readings":[]}"#.utf8)) == nil, "version future refusée")
        try expect(FortiWifiSignalHistory.decode(Data("pas du json".utf8)) == nil, "fichier illisible")
    }

    suite.add("Wi-Fi clients : itinérances, déconnexions et tendance d'après l'historique") {
        var history = FortiWifiSignalHistory()
        let limits = FortiWifiSignalHistory.Limits(minInterval: 0)
        let other = ClientFixtures.client(9)
        let steps: [(String?, WifiBand, Int, Bool)] = [("AP-ACCUEIL", .ghz5, -55, true), ("AP-ACCUEIL", .ghz5, -56, true),
                                                        ("AP-ETG2", .ghz5, -63, true), ("AP-ETG2", .ghz5, -65, true),
                                                        (nil, .ghz5, 0, false), ("AP-ETG2", .ghz24, -72, true),
                                                        ("AP-ETG2", .ghz24, -76, true), (nil, .ghz5, 0, false), ("AP-ETG2", .ghz24, -77, true)]
        for (k, step) in steps.enumerated() {
            var list = [other]
            if step.3, let ap = step.0 {
                var c = ClientFixtures.client(1, ap: ap, band: step.1, rssi: step.2)
                c.channel = step.1 == .ghz24 ? 11 : 36
                list.append(c)
            }
            history.record(list, at: now.addingTimeInterval(Double(k) * 300), limits: limits)
        }
        let mac = ClientFixtures.client(1).mac
        let roams = history.roams(for: mac)
        try expectEqual(roams.count, 2, "deux itinérances")
        try expectEqual(roams[0].label, "AP-ACCUEIL → AP-ETG2", "changement de borne")
        try expectEqual(roams[1].label, "AP-ETG2 (5 GHz → 2,4 GHz)", "changement de bande")
        try expectEqual(history.disconnections(for: mac).count, 2, "deux lectures manquées")
        try expectEqual(history.disconnections(for: other.mac).count, 0, "client toujours présent")
        try expectEqual(history.trend(for: mac), .falling, "signal en baisse")
        try expectEqual(history.trend(for: other.mac), .stable, "signal stable")
        try expectEqual(history.range(for: mac)?.min, -77, "plus faible")
        let issues = FortiWifiClientIssues.issues(ClientFixtures.client(1, ap: "AP-ETG2", radio: 1, band: .ghz24, rssi: -77),
                                                  ap: ClientFixtures.etg2, history: history, now: now.addingTimeInterval(8 * 300))
        let kinds = issues.map(\.kind)
        try expect(kinds.contains(.weakSignal) && kinds.contains(.band24) && kinds.contains(.disconnects) && kinds.contains(.falling),
                   "problèmes repérés : \(kinds)")
        try expectEqual(issues.first?.severity, .alerte, "le plus grave d'abord")
        let healthy = FortiWifiClientIssues.issues(ClientFixtures.client(2, radio: 3, rssi: -50), ap: ClientFixtures.etg2)
        try expectEqual(healthy.map(\.kind), [.healthy], "aucun problème")
        let busy = FortiWifiClientIssues.issues(ClientFixtures.client(3, radio: 2, rssi: -50), ap: ClientFixtures.etg2)
        try expectEqual(busy.map(\.kind), [.busyChannel], "canal occupé de la radio du client")
    }

    suite.add("Wi-Fi clients : un historique par site, jamais fusionné (même MAC sur deux sites)") {
        var book = FortiWifiSignalBook()
        let siege = ClientFixtures.client(1, rssi: -50), laval = ClientFixtures.client(1, site: "Laval", rssi: -80)
        let changed = book.record(["siege-key": [siege], "laval-key": [laval]], at: now)
        try expectEqual(changed, ["laval-key", "siege-key"], "deux sites modifiés")
        book.record(["siege-key": [siege]], at: now.addingTimeInterval(120))
        try expectEqual(book.history(site: "siege-key").samples(for: siege.mac).map(\.rssi), [-50, -50], "historique du Siège")
        try expectEqual(book.history(site: "laval-key").samples(for: laval.mac).map(\.rssi), [-80], "historique de Laval, à part")
        try expect(book.history(site: "autre").isEmpty, "site inconnu : vide")
        try expect(FortiWifiSignalHistory.url(in: SiteFiles(base: URL(fileURLWithPath: "/tmp/x")), siteKey: "abc").path
                    .hasSuffix("sites/abc/wifi-signal.json"), "un fichier par site")
    }

    // MARK: Navigation

    suite.add("Wi-Fi clients : « Ouvrir dans › » d'un client propose sa fiche Wi-Fi dans le site de sa borne") {
        let context = NavContext(activeSiteKey: "siege", accessPoints: [(id: "Siège|FP231F0001", name: "AP-ACCUEIL", ip: nil)])
        let items = NavResolver.openIn(.wifiClient(mac: "5C:E9:1E:40:00:01", ip: nil, name: "client", apID: "Siège|FP231F0001"), in: context)
        let fiche = items.first { $0.title == "Wi-Fi (fiche du client)" }
        try expectEqual(fiche?.destination.focus, .wifiClient("Siège|5c:e9:1e:40:00:01"), "identifiant site|mac du client")
        try expectEqual(items.map(\.title).count, Set(items.map(\.title)).count, "titres uniques")
        var history = NavHistory()
        history.leave(NavLocation(.wifi, focus: .accessPoint("Siège|FP231F0001")), to: NavLocation(.wifi, focus: .wifiClient("Siège|x")))
        try expectEqual(history.previous?.focus, .accessPoint("Siège|FP231F0001"), "Retour vers la borne d'origine")
    }
}

private extension Optional {
    func unwrapWifi(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}
