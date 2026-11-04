import Foundation
import NetScopeCore

// Note 27 : Wi-Fi géré par la FortiGate (FortiAP). Réponses JSON fixes en variantes de versions,
// diagnostic (canaux, signal faible, surcharge, hors ligne), rattachement aux appareils du
// Scanner, fusion multisite, sondes et section de rapport. Aucun réseau.

enum FortiWifiFixtures {
    // MARK: FortiOS 7.4 : enveloppe « results », noms en « _ »

    static let managedAP74 = """
    {"http_method":"GET","results":[
      {"name":"AP-ACCUEIL","vdom":"root","serial":"FP231FTF22004101","wtp_id":"FP231FTF22004101","ap_profile":"FAP231F-default",
       "status":"connected","state":"authorized","connecting_from":"10.182.122.102","os_version":"FP231F-v7.2.8-build0436",
       "join_time_raw":1793690000,"clients":9,
       "radio":[{"radio_id":1,"radio_type":"802.11ax,n,g-only","oper_chan":6,"channel_bandwidth":"20MHz","oper_txpower":14,"client_count":2,
                 "channel_utilization_percent":41,"noise_floor":-94,"interfering_aps":5},
                {"radio_id":2,"radio_type":"802.11ax-5G","oper_chan":44,"channel_bandwidth":"80MHz","oper_txpower":17,"client_count":7,
                 "channel_utilization_percent":36,"noise_floor":-96}]},
      {"name":"AP-ETG2","serial":"FP231FTF22004187","wtp_id":"FP231FTF22004187","status":"connected","connecting_from":"10.182.122.104",
       "os_version":"FP231F-v7.2.8-build0436",
       "radio":[{"radio_id":1,"radio_type":"802.11ax,n,g-only","oper_chan":11,"channel_bandwidth":"20MHz","client_count":1},
                {"radio_id":2,"radio_type":"802.11ax-5G","oper_chan":36,"channel_bandwidth":"80MHz","client_count":6,"channel_utilization_percent":82}]},
      {"name":"AP-QUAI","serial":"FP231FTF22004290","wtp_id":"FP231FTF22004290","status":"disconnected","connecting_from":"10.182.130.14",
       "radio":[{"radio_id":1,"oper_chan":0},{"radio_id":2}]}
    ],"vdom":"root","path":"wifi","name":"managed_ap","status":"success","serial":"FG100FTK22004711","version":"v7.4.4","build":2662}
    """

    static let client74 = """
    {"http_method":"GET","results":[
      {"mac":"3c:22:fb:7e:05:b1","ip":"10.182.122.135","hostname":"Macmini-de-Dany","ssid":"Groupe-Interne","wtp_name":"AP-ACCUEIL",
       "wtp_id":"FP231FTF22004101","radio_id":2,"channel":44,"signal":-52,"noise":-95,"data_rate_bps":866700000,"association_time":5640,
       "os":"macOS","vlan_id":20},
      {"mac":"d6:4e:81:7a:33:c0","ip":"10.182.122.133","hostname":"Android_89UM1WTN","ssid":"Groupe-Interne","wtp_id":"FP231FTF22004187",
       "radio_type":"802.11n-2G","channel":11,"signal":-77,"noise":-93,"data_rate":26},
      {"mac":"f2:6a:19:c4:0e:57","ip":"10.182.140.31","ssid":"Invités","wtp_name":"AP-ETG2","channel":36,"signal":-63,"snr":18}
    ],"vdom":"root","path":"wifi","name":"client","status":"success","version":"v7.4.4","build":2662}
    """

    static let vap74 = """
    {"http_method":"GET","results":[
      {"name":"wifi-interne","ssid":"Groupe-Interne","security":"wpa2-only-enterprise","vlanid":20,"broadcast-ssid":"enable","local-bridging":"disable"},
      {"name":"wifi-invites","ssid":"Invités","security":"open","portal-type":"auth","vlanid":60,"broadcast-ssid":"enable","max-clients":60}
    ],"vdom":"root","path":"wireless-controller","name":"vap","status":"success","http_status":200}
    """

    static let rogue74 = """
    {"http_method":"GET","results":[
      {"ssid":"Bureau-Corp","bssid":"02:1f:6b:a0:44:93","channel":6,"signal_strength":-58,"status":"rogue","is_on_wire":true,
       "detected_by":"AP-ACCUEIL","security_mode":"WPA2 Personal","manufacturer":"Unknown"},
      {"ssid":"Bureau-Corp","bssid":"02:1f:6b:a0:44:93","channel":6,"signal_strength":-66,"status":"rogue","detected_by":"AP-ETG2"},
      {"ssid":"Cafe-Voisin","bssid":"9c:53:22:5d:18:c2","channel":6,"signal_strength":-78,"status":"unclassified","detected_by":"AP-ACCUEIL"},
      {"ssid":"DIRECT-7D","bssid":"96:dd:f8:18:15:7d","channel":1,"signal_strength":-61,"status":"accepted"}
    ],"status":"success"}
    """

    // MARK: FortiOS 6.4 : dictionnaire indexé, noms en « - », valeurs en texte

    static let managedAP64 = """
    {"http_method":"GET","results":{
      "FP221E3X17001234":{"wtp-name":"AP-ENTREPOT","wtp-id":"FP221E3X17001234","connection-state":"Connected","local_ipv4_addr":"10.20.10.20",
        "os-version":"FP221E-v6.4.9-build0478","uptime":"3d 4h 12m",
        "radio":[{"radio-id":"1","band":"2.4GHz","oper-chan":"1","bandwidth":"HT20","client_count":"4"},
                 {"radio-id":"2","band":"5GHz","oper-chan":"149","bandwidth":"VHT80","client_count":"35","chan_util":"55"}]},
      "FP221E3X17005678":{"wtp-name":"AP-BUREAU","connection-state":"Disconnected","radio":[]}
    },"vdom":"root","status":"success","version":"v6.4.15"}
    """

    static let client64 = """
    {"results":{"a4:83:e7:11:22:33":{"ip":"10.20.10.81","host":"Zebra-LAV-01","vap_name":"wifi-interne","wtp":"FP221E3X17001234",
      "radio":1,"rssi":"62","noise":"-94","tx_rate":"86700"}},"status":"success"}
    """

    /// Réponse nue (sans enveloppe), champs absents.
    static let bareAPs = """
    [{"serial":"FP23JFTF23001044","status":"online","radios":[{"id":2,"channel":116,"width":80}]}]
    """

    /// Forme regroupée par borne (interfering_ap de certaines versions).
    static let interfering = """
    {"results":[{"wtp_name":"AP-ACCUEIL","interfering_ap":[{"ssid":"UBNT-Logistik","bssid":"78:8a:20:4e:c3:05","channel":11,"rssi":-69},
                                                          {"ssid":"Cafe-Voisin","bssid":"9c:53:22:5d:18:c2","channel":6,"rssi":-78}]},
                {"wtp_name":"AP-ETG2","interfering_ap":[{"ssid":"UBNT-Logistik","bssid":"78:8a:20:4e:c3:05","channel":11,"rssi":-64}]}],
     "status":"success"}
    """

    static func transport74(managedAP: (Int, String)? = nil, client: (Int, String)? = nil, rogue: (Int, String)? = nil) -> FortiFakeTransport {
        var responses: [String: (Int, String)] = [
            FortiWifiPaths.managedAP: managedAP ?? (200, managedAP74),
            FortiWifiPaths.client: client ?? (200, client74),
            FortiWifiPaths.vap: (200, vap74),
            FortiWifiPaths.rogueAP: rogue ?? (200, rogue74),
            FortiWifiPaths.interferingAP: (200, interfering),
        ]
        responses[FortiWifiPaths.apStatus] = (200, #"{"results":{"connected":2,"disconnected":1},"status":"success"}"#)
        return FortiFakeTransport(responses)
    }
}

func registerFortiWifiTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_700_000)
    func data(_ s: String) -> Data { Data(s.utf8) }

    suite.add("FortiAP : petites conversions (bande, largeur, dBm, modèle, durée)") {
        try expectEqual(FortiWifiParsers.band("802.11ax-5G", channel: nil), .ghz5, "5G")
        try expectEqual(FortiWifiParsers.band("802.11ax-6G", channel: 37), .ghz6, "6G malgré le canal")
        try expectEqual(FortiWifiParsers.band("802.11ax,n,g-only", channel: nil), .ghz24, "2,4 par la norme")
        try expectEqual(FortiWifiParsers.band(nil, channel: 11), .ghz24, "2,4 par le canal")
        try expectEqual(FortiWifiParsers.band(nil, channel: 149), .ghz5, "5 par le canal")
        try expectEqual(FortiWifiParsers.width("80MHz"), 80, "80MHz")
        try expectEqual(FortiWifiParsers.width("VHT160"), 160, "VHT160")
        try expectEqual(FortiWifiParsers.width(40), 40, "nombre")
        try expectEqual(FortiWifiParsers.width("auto"), nil, "auto")
        try expectEqual(FortiWifiParsers.dbm("62"), -62, "force sans signe ramenée en négatif")
        try expectEqual(FortiWifiParsers.dbm(0), nil, "0 : inconnu")
        try expectEqual(FortiWifiParsers.apModel(nil, serial: "FP231FTF22004101"), "FAP-231F", "série 231F")
        try expectEqual(FortiWifiParsers.apModel(nil, serial: "FP23JFTF23001044"), "FAP-23JF", "série 23JF")
        try expectEqual(FortiWifiParsers.apModel("FP431F", serial: ""), "FAP-431F", "modèle court")
        try expectEqual(FortiWifiParsers.apModel("FortiAP-221E", serial: ""), "FAP-221E", "modèle long")
    }

    suite.add("FortiAP : bornes en 7.4 (liste), 6.4 (dictionnaire, texte) et sans enveloppe") {
        let aps = try FortiWifiParsers.managedAPs(data(FortiWifiFixtures.managedAP74), now: now).unwrap("7.4 lisible")
        try expectEqual(aps.count, 3, "trois bornes")
        let accueil = aps[0]
        try expectEqual(accueil.name, "AP-ACCUEIL", "nom")
        try expectEqual(accueil.model, "FAP-231F", "modèle tiré de la série")
        try expectEqual(accueil.firmwareShort, "v7.2.8", "firmware court")
        try expectEqual(accueil.ip, IPv4Address("10.182.122.102"), "adresse")
        try expectEqual(accueil.connected, true, "en ligne")
        try expectEqual(accueil.totalClients, 9, "clients de la borne")
        try expectEqual(accueil.uptime, 10_000, "durée depuis join_time_raw")
        try expectEqual(accueil.radios.map(\.band), [.ghz24, .ghz5], "bandes")
        try expectEqual(accueil.radios[1].channel, 44, "canal 5 GHz")
        try expectEqual(accueil.radios[1].widthMHz, 80, "largeur")
        try expectEqual(accueil.radios[0].channelUtilization, 41, "utilisation")
        try expectEqual(accueil.radios[0].noiseDBm, -94, "bruit")
        try expectEqual(accueil.radios[0].txPowerDBm, 14, "puissance")
        try expect(aps[2].isOffline, "AP-QUAI déconnectée")
        try expect(aps[2].radios.allSatisfy { !$0.isServing }, "radios d'une borne hors ligne sans canal")

        let old = try FortiWifiParsers.managedAPs(data(FortiWifiFixtures.managedAP64), now: now).unwrap("6.4 lisible")
        try expectEqual(old.map(\.name), ["AP-ENTREPOT", "AP-BUREAU"], "dictionnaire indexé par série")
        try expectEqual(old[0].serial, "", "série absente : lue depuis la clé")
        try expectEqual(old[0].wtpID, "FP221E3X17001234", "identifiant")
        try expectEqual(old[0].model, "FAP-221E", "modèle depuis l'identifiant")
        try expectEqual(old[0].uptime, 3 * 86_400 + 4 * 3600 + 12 * 60, "durée en texte")
        try expectEqual(old[0].radios[1].channel, 149, "canal en texte")
        try expectEqual(old[0].radios[1].widthMHz, 80, "VHT80")
        try expectEqual(old[0].radios[1].clientCount, 35, "clients en texte")
        try expectEqual(old[1].connected, false, "Disconnected")

        let bare = try FortiWifiParsers.managedAPs(data(FortiWifiFixtures.bareAPs), now: now).unwrap("sans enveloppe")
        try expectEqual(bare.first?.name, "FP23JFTF23001044", "sans nom : la série")
        try expectEqual(bare.first?.model, "FAP-23JF", "modèle")
        try expectEqual(bare.first?.radios.first?.band, .ghz5, "bande déduite du canal")
        try expectEqual(FortiWifiParsers.managedAPs(data(#"{"results":[],"status":"success"}"#))?.count, 0, "aucune borne")
        try expect(FortiWifiParsers.managedAPs(data("pas du json")) == nil, "illisible")
    }

    suite.add("FortiAP : clients, SSID et AP voisins (variantes)") {
        let clients = try FortiWifiParsers.clients(data(FortiWifiFixtures.client74)).unwrap("clients")
        try expectEqual(clients.count, 3, "trois clients")
        try expectEqual(clients[0].mac, MACAddress("3C:22:FB:7E:05:B1"), "MAC")
        try expectEqual(clients[0].rateMbps, 866.7, "débit en b/s converti")
        try expectEqual(clients[0].snr, 43, "SNR calculé avec le bruit")
        try expectEqual(clients[0].associatedFor, 5640, "durée")
        try expectEqual(clients[1].band, .ghz24, "bande 2G")
        try expectEqual(clients[1].apKey, "FP231FTF22004187", "borne par identifiant")
        try expectEqual(clients[2].snr, 18, "SNR donné")
        let old = try FortiWifiParsers.clients(data(FortiWifiFixtures.client64)).unwrap("clients 6.4")
        try expectEqual(old.first?.rssi, -62, "rssi sans signe")
        try expectEqual(old.first?.rateMbps, 86.7, "débit en kb/s")
        try expectEqual(old.first?.ssid, "wifi-interne", "VAP à défaut de SSID")
        try expectEqual(old.first?.hostname, "Zebra-LAV-01", "host")

        let ssids = try FortiWifiParsers.ssids(data(FortiWifiFixtures.vap74)).unwrap("SSID")
        try expectEqual(ssids.map(\.ssid), ["Groupe-Interne", "Invités"], "SSID")
        try expectEqual(ssids[0].securityLabel, "WPA2 Entreprise", "sécurité en clair")
        try expectEqual(ssids[0].vlan, 20, "VLAN")
        try expect(ssids[1].isOpen && ssids[1].captivePortal == true, "invités ouvert avec portail")
        try expectEqual(ssids[1].maxClients, 60, "clients max")

        let rogues = try FortiWifiParsers.rogues(data(FortiWifiFixtures.rogue74)).unwrap("rogue_ap")
        try expectEqual(rogues.count, 3, "même BSSID regroupé")
        try expect(rogues[0].isUnauthorized && rogues[0].onWire, "non autorisé, sur le réseau")
        try expectEqual(rogues[0].seenBy, ["AP-ACCUEIL", "AP-ETG2"], "vu par deux bornes")
        try expectEqual(rogues[0].rssi, -58, "signal le plus fort")
        try expectEqual(rogues[2].status, .accepted, "accepté")
        let nested = try FortiWifiParsers.rogues(data(FortiWifiFixtures.interfering)).unwrap("interfering_ap")
        try expectEqual(nested.count, 2, "deux BSSID")
        try expectEqual(nested[0].seenBy, ["AP-ACCUEIL", "AP-ETG2"], "borne qui l'entend, regroupée")
        try expectEqual(nested[0].rssi, -64, "plus fort des deux")
    }

    suite.add("FortiAP : lecture complète en lecture seule (GET), noms des bornes résolus") {
        let transport = FortiWifiFixtures.transport74()
        let reader = FortiGateReader(transport: transport, tokenForRedaction: FortiFixtures.token)
        let report = try await reader.readWifi(now: now)
        try expect(report.available, "contrôleur présent")
        try expectEqual(report.aps.count, 3, "bornes")
        try expectEqual(report.clients.count, 3, "clients")
        try expectEqual(report.clients[1].apName, "AP-ETG2", "identifiant WTP remplacé par le nom")
        try expectEqual(report.ssids.count, 2, "SSID")
        try expectEqual(report.rogues.count, 3, "voisins")
        try expect(report.notes.isEmpty, "rien d'absent")
        try expectEqual(transport.requested, [FortiWifiPaths.managedAP, FortiWifiPaths.client, FortiWifiPaths.vap, FortiWifiPaths.rogueAP,
                                              FortiWifiPaths.apStatus], "adresses lues, rogue_ap suffit")
        let text = FortiDiagnostic.text(calls: report.calls, config: FortiGateConfig(host: "10.182.122.1"), system: nil,
                                        token: FortiFixtures.token, date: now)
        try expect(text.contains("/api/v2/monitor/wifi/managed_ap"), "appels Wi-Fi dans les réponses brutes")
        try expect(!text.contains(FortiFixtures.token), "jamais le jeton")
    }

    suite.add("FortiAP : 403 sur les bornes expliqué, 404 = absent, parties facultatives notées") {
        let refused = FortiWifiFixtures.transport74(managedAP: (403, #"{"status":"error","http_status":403}"#))
        do {
            _ = try await FortiGateReader(transport: refused).readWifi(now: now)
            throw TestFailure(message: "403 aurait dû lever une erreur", file: #fileID, line: #line)
        } catch let error as FortiGateError {
            try expectEqual(error, .forbidden(path: FortiWifiPaths.managedAP), "403")
            try expect(error.wifiDescription.contains("WiFi & Switch Controller"), "droit à ajouter nommé")
        }
        let absent = FortiWifiFixtures.transport74(managedAP: (404, ""))
        let none = try await FortiGateReader(transport: absent).readWifi(now: now)
        try expect(!none.available && none.aps.isEmpty, "contrôleur Wi-Fi absent")
        try expectEqual(absent.requested.count, 1, "rien d'autre n'est lu")

        let partial = FortiWifiFixtures.transport74(client: (403, #"{"status":"error","http_status":403}"#), rogue: (404, ""))
        let report = try await FortiGateReader(transport: partial).readWifi(now: now)
        try expectEqual(report.aps.count, 3, "bornes lues")
        try expect(report.clients.isEmpty, "clients refusés")
        try expect(report.notes.contains { $0.hasPrefix("Clients Wi-Fi") && $0.contains("403") }, "403 des clients expliqué")
        try expectEqual(report.rogues.count, 2, "repli sur interfering_ap")
        try expect(partial.requested.contains(FortiWifiPaths.interferingAP), "interfering_ap essayé")

        let rejected = FortiWifiFixtures.transport74(managedAP: (401, ""))
        do {
            _ = try await FortiGateReader(transport: rejected).readWifiKeepingCalls(now: now)
            throw TestFailure(message: "401 aurait dû lever une erreur", file: #fileID, line: #line)
        } catch let failure as FortiReadFailure {
            try expectEqual(failure.error, .tokenRejected, "jeton refusé")
        }
    }

    // MARK: Diagnostic

    func ap(_ name: String, site: String = "Siège", connected: Bool? = true, _ radios: [FortiAPRadio]) -> FortiManagedAP {
        FortiManagedAP(site: site, name: name, serial: "S-" + name, connected: connected, radios: radios)
    }
    func radio(_ id: Int, _ band: WifiBand, _ ch: Int?, _ w: Int = 20, clients: Int? = nil, util: Double? = nil, mode: String? = nil) -> FortiAPRadio {
        FortiAPRadio(radioID: id, band: band, channel: ch, widthMHz: w, clientCount: clients, channelUtilization: util, mode: mode)
    }

    suite.add("FortiAP : chevauchement des canaux (2,4 GHz, 5 GHz par largeur, 6 GHz, sites séparés)") {
        try expect(!FortiWifiAnalysis.overlaps(band: .ghz24, 1, 20, 6, 20), "1 et 6 propres")
        try expect(FortiWifiAnalysis.overlaps(band: .ghz24, 1, 20, 3, 20), "1 et 3 se recouvrent")
        try expect(FortiWifiAnalysis.overlaps(band: .ghz24, 6, 40, 11, 20), "40 MHz en 2,4 recouvre 11")
        try expect(FortiWifiAnalysis.overlaps(band: .ghz5, 36, 80, 44, 80), "36 et 44 dans le même bloc de 80")
        try expect(!FortiWifiAnalysis.overlaps(band: .ghz5, 36, 40, 44, 40), "36 et 44 en 40 : blocs différents")
        try expect(!FortiWifiAnalysis.overlaps(band: .ghz5, 36, 80, 52, 80), "blocs de 80 voisins")
        try expect(FortiWifiAnalysis.overlaps(band: .ghz5, 36, 160, 60, 20), "160 MHz couvre 60")
        try expect(FortiWifiAnalysis.overlaps(band: .ghz6, 37, 160, 57, 20), "6 GHz : 37/160 (bloc 33–61) couvre 57")
        try expect(!FortiWifiAnalysis.overlaps(band: .ghz6, 37, 160, 69, 20), "6 GHz : 69 hors du bloc 33–61")
        try expect(!FortiWifiAnalysis.overlaps(band: .ghz6, 37, 80, 53, 80), "6 GHz : blocs de 80 voisins")

        let aps = [ap("A", [radio(1, .ghz24, 1), radio(2, .ghz5, 44, 80)]),
                   ap("B", [radio(1, .ghz24, 3), radio(2, .ghz5, 36, 80)]),
                   ap("C", [radio(1, .ghz24, 6), radio(2, .ghz5, 149, 80)]),
                   ap("D", [radio(1, .ghz24, 6), radio(2, .ghz5, 52, 80)]),
                   ap("E", connected: false, [radio(1, .ghz24, 1)]),
                   ap("F", site: "Laval", [radio(1, .ghz24, 1), radio(2, .ghz5, 36, 80)])]
        let overlaps = FortiWifiAnalysis.channelOverlaps(aps)
        let kinds = Dictionary(overlaps.map { ("\($0.first)-\($0.second)-\($0.band.rawValue)", $0.kind) }, uniquingKeysWith: { a, _ in a })
        try expectEqual(kinds["A-B-ghz24"], .adjacent, "1 et 3 : se recouvrent")
        try expectEqual(kinds["A-B-ghz5"], .sharedWidth, "44 et 36 en 80 : même bloc")
        try expectEqual(kinds["C-D-ghz24"], .sameChannel, "6 et 6 : même canal")
        try expectEqual(kinds["B-C-ghz24"], .adjacent, "3 et 6 se recouvrent")
        try expect(!overlaps.contains { $0.first == "E" || $0.second == "E" }, "borne hors ligne ignorée")
        try expect(!overlaps.contains { $0.first == "F" || $0.second == "F" }, "autre site ignoré")
        try expectEqual(overlaps.count, 5, "A-B (2,4 et 5), B-C, B-D, C-D")
    }

    suite.add("FortiAP : signal faible, surcharge, hors ligne et conseils (seuils réglables)") {
        let clients = [
            FortiWifiClient(site: "Siège", mac: MACAddress("00:00:00:00:00:01")!, hostname: "fort", apName: "A", radioID: 2, band: .ghz5, rssi: -55, noise: -95),
            FortiWifiClient(site: "Siège", mac: MACAddress("00:00:00:00:00:02")!, hostname: "loin", apName: "A", radioID: 1, band: .ghz24, rssi: -76, noise: -92),
            FortiWifiClient(site: "Siège", mac: MACAddress("00:00:00:00:00:03")!, hostname: "bruit", apName: "B", rssi: -64, snr: 15),
        ]
        try expectEqual(FortiWifiAnalysis.weakClients(clients).map(\.hostname), ["loin", "bruit"], "RSSI < -70 ou SNR < 20")
        try expectEqual(FortiWifiAnalysis.weakClients(clients, thresholds: FortiWifiThresholds(weakRSSI: -80, weakSNR: 10)).count, 0, "seuils réglés")

        let aps = [ap("A", [radio(1, .ghz24, 1, clients: 12), radio(2, .ghz5, 36, 80, clients: 31, util: 40)]),
                   ap("B", [radio(1, .ghz24, 6, util: 72), radio(2, .ghz5, 149, 80)]),
                   ap("Q", connected: false, [radio(1, .ghz24, nil)])]
        let overloaded = FortiWifiAnalysis.overloaded(aps, clients: clients)
        try expectEqual(overloaded.map(\.id), ["Siège|A|2", "Siège|B|1"], "31 clients, canal à 72 %")
        try expect(overloaded[0].tooManyClients && !overloaded[0].busyChannel, "trop de clients")
        try expect(overloaded[1].busyChannel, "canal occupé")
        try expectEqual(FortiWifiAnalysis.overloaded(aps, thresholds: FortiWifiThresholds(maxClientsPerRadio: 40, maxChannelUtilization: 80)).count,
                        0, "seuils relevés")

        let overview = FortiWifiOverview(aps: aps, clients: clients,
                                         ssids: [FortiSSID(site: "Siège", name: "inv", ssid: "Invités", security: "open")],
                                         rogues: [FortiRogueAP(site: "Siège", ssid: "Faux", bssid: MACAddress("02:00:00:00:00:09"), channel: 6, status: .rogue)],
                                         sites: ["Siège"], readAt: now)
        let d = FortiWifiAnalysis.diagnose(overview)
        try expectEqual(d.offline.map(\.name), ["Q"], "hors ligne")
        try expectEqual(d.unauthorized.count, 1, "non autorisé")
        let kinds = d.advice.map(\.kind)
        try expectEqual(Array(kinds.prefix(2)), [.offline, .rogue], "critiques en premier")
        try expect(kinds.contains(.weakSignal) && kinds.contains(.overload) && kinds.contains(.openSSID), "conseils attendus")
        try expect(!kinds.contains(.overlap), "1 et 6 : aucun chevauchement")
        try expectEqual(d.alertCount, d.advice.filter { $0.severity <= .alerte }.count, "alertes")
        let weak = try d.advice.first { $0.kind == .weakSignal }.unwrap("conseil signal faible")
        try expect(weak.detail.contains("loin sur A (-76\u{00A0}dBm)"), "client nommé avec sa borne : \(weak.detail)")
        try expect(d.advice.allSatisfy { !$0.title.contains(" :") && !$0.detail.contains(" :") }, "espace insécable avant « : »")

        let healthy = FortiWifiAnalysis.diagnose(FortiWifiOverview(aps: [ap("A", [radio(1, .ghz24, 1)])], sites: ["Siège"]))
        try expectEqual(healthy.advice.map(\.kind), [.healthy], "rien à signaler")
    }

    // MARK: Rattachement et multisite

    suite.add("FortiAP : rattachement client → appareil du Scanner (MAC, sinon IP unique)") {
        var mac = Device(ip: IPv4Address("10.182.122.135")!, mac: MACAddress("3C:22:FB:7E:05:B1"), isOnline: true)
        mac.hostname = "Macmini"
        let noMAC = Device(ip: IPv4Address("10.182.140.31")!, isOnline: true)
        let wired = Device(ip: IPv4Address("10.182.122.111")!, mac: MACAddress("94:DD:F8:18:15:7D"), isOnline: true)
        let other = Device(ip: IPv4Address("10.182.122.133")!, mac: MACAddress("AA:BB:CC:00:00:01"), isOnline: true)
        let clients = try FortiWifiParsers.clients(data(FortiWifiFixtures.client74)).unwrap("clients")
        let overview = FortiWifiMerge.overview([FortiWifiSiteReport(controllerID: UUID(), site: "Siège",
                                                                    report: FortiWifiReport(clients: clients, readAt: now))])
        let match = FortiWifiMerge.match([mac, noMAC, wired, other], overview: overview)
        try expectEqual(match[mac.id]?.apName, "AP-ACCUEIL", "par MAC")
        try expectEqual(match[noMAC.id]?.ssid, "Invités", "sans MAC : par IP")
        try expect(match[wired.id] == nil, "filaire : aucun client")
        try expect(match[other.id] == nil, "MAC connue différente : pas de rattachement par IP")
        try expectEqual(match[mac.id]?.site, "Siège", "client marqué de son site")
    }

    suite.add("FortiAP : fusion de plusieurs sites (bornes marquées, analyse par site)") {
        let siegeAPs = try FortiWifiParsers.managedAPs(data(FortiWifiFixtures.managedAP74), now: now).unwrap("7.4")
        let lavalAPs = try FortiWifiParsers.managedAPs(data(FortiWifiFixtures.managedAP64), now: now).unwrap("6.4")
        // Laval : même canal 36/80 qu'au Siège, mais sur un autre site.
        var laval = lavalAPs
        laval[0].radios[1].channel = 36
        let clients = try FortiWifiParsers.clients(data(FortiWifiFixtures.client74)).unwrap("clients")
        var lavalClients = try FortiWifiParsers.clients(data(FortiWifiFixtures.client64)).unwrap("clients 6.4")
        lavalClients.append(clients[0]) // même MAC sur deux sites (relevé périmé) : la première gagne
        let sites = [
            FortiWifiSiteReport(controllerID: UUID(), site: "Siège", report: FortiWifiReport(aps: siegeAPs, clients: FortiWifiMerge.resolveAPNames(clients, aps: siegeAPs), readAt: now)),
            FortiWifiSiteReport(controllerID: UUID(), site: "Entrepôt Laval",
                                report: FortiWifiReport(aps: laval, clients: FortiWifiMerge.resolveAPNames(lavalClients, aps: laval),
                                                        readAt: now.addingTimeInterval(60), notes: ["SSID\u{00A0}: absent"])),
        ]
        let o = FortiWifiMerge.overview(sites)
        try expectEqual(o.sites, ["Siège", "Entrepôt Laval"], "sites")
        try expect(o.isMultiSite, "plusieurs sites")
        try expectEqual(o.aps.count, 5, "toutes les bornes")
        try expectEqual(Set(o.aps.filter { $0.site == "Entrepôt Laval" }.map(\.name)), ["AP-ENTREPOT", "AP-BUREAU"], "bornes marquées")
        try expectEqual(o.clients.count, 4, "MAC en double gardée une fois")
        try expectEqual(o.client(mac: clients[0].mac)?.site, "Siège", "premier site gagne")
        try expectEqual(o.clients.first { $0.hostname == "Zebra-LAV-01" }?.apName, "AP-ENTREPOT", "borne du client 6.4 résolue")
        try expectEqual(o.readAt, now.addingTimeInterval(60), "lecture la plus récente")
        try expect(o.notes.contains("Entrepôt Laval · SSID\u{00A0}: absent"), "note marquée du site")
        let overlaps = FortiWifiAnalysis.channelOverlaps(o.aps)
        try expect(overlaps.allSatisfy { $0.site == "Siège" }, "aucun chevauchement entre sites")
        let d = FortiWifiAnalysis.diagnose(o)
        try expect(d.advice.contains { $0.kind == .offline && $0.title.contains("(Siège)") }, "site nommé dans les conseils")
        try expect(d.overloaded.contains { $0.site == "Entrepôt Laval" && $0.apName == "AP-ENTREPOT" }, "35 clients à Laval")
        let ap = try o.ap(for: o.clients.first { $0.hostname == "Zebra-LAV-01" }!).unwrap("borne du client")
        try expectEqual(ap.site, "Entrepôt Laval", "borne du même site")
    }

    // MARK: Surveillance et rapport

    suite.add("FortiAP : sondes « FortiAP hors ligne » et « Borne surchargée »") {
        let aps = [ap("AP-A", [radio(1, .ghz24, 1, clients: 3), radio(2, .ghz5, 36, 80, clients: 34, util: 50)]),
                   ap("AP-Q", connected: false, [radio(1, .ghz24, nil)]),
                   ap("AP-L", site: "Laval", [radio(1, .ghz24, 6, clients: 2)])]
        let o = FortiWifiOverview(aps: aps, sites: ["Siège", "Laval"], readAt: now)
        let down = MonFortiAPChecks.offline(target: "AP-Q", overview: o, now: now)
        try expect(!down.result.reachable, "borne hors ligne : panne")
        let up = MonFortiAPChecks.offline(target: "siège / ap-a", overview: o, now: now)
        try expect(up.result.reachable && up.result.value.contains("37 clients"), "site / nom, insensible à la casse : \(up.result.value)")
        let all = MonFortiAPChecks.offline(target: "*", overview: o, now: now)
        try expectEqual(all.result.value, "1 hors ligne sur 3", "toutes les bornes")
        try expect(MonFortiAPChecks.offline(target: "AP-A", overview: nil, now: now).noData, "aucune lecture : rien à évaluer")
        try expect(MonFortiAPChecks.offline(target: "AP-Z", overview: o, now: now).result.problem != nil, "borne introuvable signalée")

        let load = MonFortiAPChecks.overload(target: "AP-A", overview: o, thresholds: .standard, now: now)
        try expect(load.result.reachable && load.result.problem?.contains("34 clients") == true, "surchargée : \(load.result.problem ?? "")")
        let fine = MonFortiAPChecks.overload(target: "AP-A", overview: o, thresholds: FortiWifiThresholds(maxClientsPerRadio: 50), now: now)
        try expect(fine.result.problem == nil, "seuil de la sonde")
        try expect(MonFortiAPChecks.overload(target: "AP-Q", overview: o, thresholds: .standard, now: now).noData, "hors ligne : rien à évaluer")
        var probe = MonProbe(name: "Charge", kind: .fortiAPOverload, target: "AP-A")
        probe.wifiThresholds = FortiWifiThresholds(maxClientsPerRadio: 25, maxChannelUtilization: 60)
        let decoded = try JSONDecoder().decode(MonProbe.self, from: try JSONEncoder().encode(probe))
        try expectEqual(decoded.wifiThresholds, probe.wifiThresholds, "seuils enregistrés avec la sonde")
        try expect(decoded.conditionSummary.contains("25 clients"), "résumé de la condition")
        var context = MonRunContext(pinger: nil, snmpCommunity: nil, devices: [], now: now)
        context.fortiWifi = o
        let run = await MonRunner.run(decoded, context: context)
        try expect(run.result.problem?.contains("AP-A") == true, "exécutée par MonRunner")
    }

    suite.add("FortiAP : section « Wi-Fi FortiAP » du rapport") {
        let siegeAPs = try FortiWifiParsers.managedAPs(data(FortiWifiFixtures.managedAP74), now: now).unwrap("7.4")
        let clients = FortiWifiMerge.resolveAPNames(try FortiWifiParsers.clients(data(FortiWifiFixtures.client74)).unwrap("clients"), aps: siegeAPs)
        let o = FortiWifiMerge.overview([FortiWifiSiteReport(controllerID: UUID(), site: "Siège",
                                                             report: FortiWifiReport(aps: siegeAPs, clients: clients,
                                                                                     ssids: try FortiWifiParsers.ssids(data(FortiWifiFixtures.vap74)).unwrap("vap"),
                                                                                     readAt: now))])
        var input = ReportInput(devices: [], now: now)
        input.fortiWifi = o
        let config = ReportConfig(template: .audit, sections: [.resume, .fortiap], maskMAC: true)
        let doc = ReportBuilder.build(config: config, input: input)
        let section = try doc.sections.first { $0.kind == .fortiap }.unwrap("section présente")
        try expectEqual(section.heading, "2. Wi-Fi FortiAP", "après le résumé")
        try expect(section.tables.count >= 3, "bornes, SSID, signal faible, conseils")
        try expect(section.tables[0].rows.contains { $0.cells[0].text == "AP-QUAI" && $0.cells[3].text == "Hors ligne" }, "borne hors ligne")
        try expect(section.tables.contains { $0.columns.first?.title == "Client à signal faible" }, "clients faibles")
        try expect(!ReportSectionKind.audit_default.contains(.fortiap), "facultative")
        var empty = ReportInput(devices: [], now: now)
        empty.fortiWifi = nil
        let none = ReportBuilder.build(config: config, input: empty).sections.first { $0.kind == .fortiap }
        if case .note? = none?.blocks.first {} else { throw TestFailure(message: "note sans lecture", file: #fileID, line: #line) }
    }
}

private extension ReportSectionKind {
    static var audit_default: Set<ReportSectionKind> { ReportTemplate.audit.defaultSections }
}

private extension Optional {
    func unwrap(_ message: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
        return value
    }
}
