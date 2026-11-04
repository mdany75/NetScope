import Foundation
import NetScopeCore

// Note 47 : diagnostic Wi-Fi d'un client, d'une borne et d'un SSID. Chaque cause sur des données
// fixes, ordre des causes, actions, client sain tout OK, cas sans mesures, suivi dans le temps et
// section de rapport. Aucun réseau.

enum WifiDiagFixtures {
    static let mac = MACAddress("D6:4E:81:7A:33:C0")!

    static func radio(_ id: Int, _ band: WifiBand, _ channel: Int, _ width: Int = 20, util: Double? = 20, noise: Int? = -95,
                      clients: Int? = nil, power: Int? = 17, interfering: Int? = nil) -> FortiAPRadio {
        FortiAPRadio(radioID: id, band: band, channel: channel, widthMHz: width, txPowerDBm: power, clientCount: clients,
                     channelUtilization: util, noiseDBm: noise, interferingAPs: interfering, mode: "AP")
    }

    static func ap(_ name: String, _ radios: [FortiAPRadio], site: String = "Siège", connected: Bool = true) -> FortiManagedAP {
        FortiManagedAP(site: site, name: name, wtpID: name, serial: name, model: "FAP-231F", ip: IPv4Address("10.0.0.\(name.count + 100)"),
                       connected: connected, radios: radios)
    }

    /// Client sain : bon signal en 5 GHz, borne seule et calme, mesures normales.
    static func healthyClient() -> FortiWifiClient {
        FortiWifiClient(site: "Siège", mac: mac, ip: IPv4Address("10.0.20.33"), hostname: "Poste-Sain", ssid: "Interne", apName: "AP-A",
                        radioID: 2, band: .ghz5, channel: 149, rssi: -52, noise: -95, rateMbps: 866.7, associatedFor: 3600, vlan: 20)
    }

    static func healthyAP() -> FortiManagedAP {
        ap("AP-A", [radio(1, .ghz24, 1, util: 15, clients: 1), radio(2, .ghz5, 149, 80, util: 20, clients: 3)])
    }

    static func goodMeasures() -> WifiDiagnosisMeasures {
        WifiDiagnosisMeasures(paths: [WifiPathMeasure(target: .gateway, address: "10.0.20.1", sent: 10, received: 10, averageMs: 2.1, maxMs: 4, jitterMs: 0.6),
                                      WifiPathMeasure(target: .dns, address: "10.0.0.53", sent: 10, received: 10, averageMs: 3.4, maxMs: 6, jitterMs: 0.8),
                                      WifiPathMeasure(target: .internet, address: "1.1.1.1", sent: 10, received: 10, averageMs: 12, maxMs: 15, jitterMs: 1.2)],
                              uplink: WifiUplinkStatus(switchName: "SW-1", portName: "port7", linkUp: true, speedMbps: 1000, duplex: "full", rxErrors: 0,
                                                       poeLabel: "Délivre du courant", poePowerW: 11.5),
                              dhcp: WifiDHCPStatus(scopeName: "VLAN 20", percent: 40, free: 120, poolSize: 200),
                              wan: [WifiWANStatus(name: "wan1", up: true, latencyMs: 9, lossPercent: 0)],
                              dfsChannelChanges: 0)
    }

    static func healthyInput() -> WifiDiagnosisInput {
        let c = healthyClient()
        let a = healthyAP()
        let peers = (0..<2).map { n in
            FortiWifiClient(site: "Siège", mac: MACAddress(bytes: [2, 0, 0, 0, 0, UInt8(n)]), ip: IPv4Address("10.0.20.\(50 + n)"), ssid: "Interne",
                            apName: "AP-A", radioID: 2, band: .ghz5, channel: 149, rssi: -58, rateMbps: 600)
        }
        return WifiDiagnosisInput(client: c,
                                  details: WifiClientDetails(standard: .wifi6, spatialStreams: 2, txRateMbps: 866.7, rxRateMbps: 720, powerSave: false,
                                                             supports5GHz: true, authMethod: "802.1X", authFailures: 0, disconnects: 0, roams: 1,
                                                             windowMinutes: 60, dhcpDelayMs: 180),
                                  ap: a, siteAPs: [a], neighbors: [], apClients: [c] + peers,
                                  ssid: FortiSSID(site: "Siège", name: "wifi-interne", ssid: "Interne", security: "wpa2-only-enterprise", vlan: 20, maxClients: 100),
                                  ssidClientCount: 3, measures: goodMeasures())
    }
}

private extension Optional {
    func unwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}

func registerWifiDiagnosisTests(_ suite: TestSuite) {
    typealias F = WifiDiagFixtures

    suite.add("Diagnostic Wi-Fi : client sain, tout est OK") {
        let r = WifiDiagnosis.diagnose(F.healthyInput())
        try expectEqual(r.overall, .ok, "verdict d'ensemble")
        try expect(r.problems.isEmpty && r.watches.isEmpty, "aucun problème ni point à surveiller : \(r.causes.filter { $0.verdict > .ok }.map(\.cause))")
        try expect(r.unchecked.isEmpty, "toutes les causes vérifiées : \(r.unchecked.map(\.cause))")
        try expect(r.actions.isEmpty, "aucune action")
        try expectEqual(r.causes.count, WifiCause.allCases.count, "chaque cause évaluée une fois")
        try expect(r.headline.hasPrefix("Aucun problème"), "titre : \(r.headline)")
        try expect(r.primary == nil, "pas de cause principale")
        try expect(r.context.contains("AP-A") && r.context.contains("SSID Interne"), "contexte : \(r.context)")
    }

    suite.add("Diagnostic Wi-Fi : sans aucune mesure ni détail") {
        var input = F.healthyInput()
        input.measures = .none
        input.details = WifiClientDetails()
        let r = WifiDiagnosis.diagnose(input)
        for cause in [WifiCause.network, .uplink, .wan] {
            try expectEqual(r.cause(cause)?.verdict, .notMeasured, "\(cause) non vérifié")
        }
        try expectEqual(r.overall, .ok, "le reste est sain")
        try expect(!r.measured, "pas de mesure")
        try expect(r.notes.contains { $0.contains("non faites") }, "remarque sur les pings")
        try expect(r.notes.contains { $0.contains("non lus") }, "remarque sur les détails du client")
        try expect(r.causes.suffix(3).allSatisfy { $0.verdict == .notMeasured }, "non vérifiées en dernier")
        // Client sans borne connue : les causes de la borne ne sont pas vérifiées.
        var lone = WifiDiagnosisInput(client: F.healthyClient())
        lone.client.apName = nil
        let r2 = WifiDiagnosis.diagnose(lone)
        for cause in [WifiCause.channel, .interference, .width, .dfs, .load, .slowClients] {
            try expectEqual(r2.cause(cause)?.verdict, .notMeasured, "\(cause) sans borne")
        }
        try expectEqual(r2.cause(.signal)?.verdict, .ok, "le signal reste jugé")
    }

    suite.add("Diagnostic Wi-Fi : signal faible et SNR") {
        var input = F.healthyInput()
        input.client.rssi = -74
        input.client.snr = 21
        var r = WifiDiagnosis.diagnose(input)
        try expectEqual(r.cause(.signal)?.verdict, .watch, "à surveiller sous −70")
        input.client.rssi = -83
        input.client.snr = 12
        r = WifiDiagnosis.diagnose(input)
        let s = try r.cause(.signal).unwrap("signal")
        try expectEqual(s.verdict, .problem, "problème sous −78")
        try expect(s.evidence.contains { $0.contains("\u{2212}83\u{00A0}dBm") }, "preuve chiffrée : \(s.evidence)")
        try expect(s.actions.first?.contains("Rapprocher") == true, "action : rapprocher")
        try expectEqual(r.primary?.cause, .signal, "cause la plus probable")
        try expect(r.headline.contains("signal"), "titre : \(r.headline)")
        // Seuils réglables : à −83 dBm et un seuil plus bas, plus de problème.
        let lax = WifiDiagnosisThresholds(weakRSSI: -85, badRSSI: -90, weakSNR: 10, badSNR: 5)
        try expectEqual(WifiDiagnosis.diagnose(input, thresholds: lax).cause(.signal)?.verdict, .ok, "seuils réglables")
        // Historique du signal en preuve.
        input.details.signalHistory = [-70, -78, -85, -83]
        try expect(WifiDiagnosis.diagnose(input).cause(.signal)?.evidence.contains { $0.contains("Historique") } == true, "historique")
    }

    suite.add("Diagnostic Wi-Fi : client collant") {
        var input = F.healthyInput()
        input.client.rssi = -79
        input.details.heardAPs = [WifiHeardAP(apName: "AP-B", rssi: -60), WifiHeardAP(apName: "AP-A", rssi: -79)]
        var r = WifiDiagnosis.diagnose(input)
        let s = try r.cause(.sticky).unwrap("collant")
        try expectEqual(s.verdict, .problem, "une borne entendue 19 dB plus fort")
        try expect(s.evidence.contains { $0.contains("AP-B") }, "preuve : la borne plus forte")
        try expect(s.actions.contains { $0.contains("802.11k") }, "action : 802.11k/v")
        // Sans bornes entendues : à surveiller si d'autres bornes sont en ligne et le client reste longtemps.
        input.details.heardAPs = []
        input.siteAPs = [input.ap!, F.ap("AP-B", [F.radio(1, .ghz24, 6), F.radio(2, .ghz5, 36, 40)])]
        input.client.associatedFor = 45 * 60
        r = WifiDiagnosis.diagnose(input)
        try expectEqual(r.cause(.sticky)?.verdict, .watch, "indice sans preuve formelle")
        input.client.associatedFor = 60
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.sticky)?.verdict, .ok, "vient d'arriver")
    }

    suite.add("Diagnostic Wi-Fi : canal chargé et chevauchements") {
        var input = F.healthyInput()
        input.ap = F.ap("AP-A", [F.radio(1, .ghz24, 1, util: 20), F.radio(2, .ghz5, 149, 80, util: 82)])
        input.siteAPs = [input.ap!]
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.channel)?.verdict, .problem, "canal saturé à 82 %")
        input.ap = F.ap("AP-A", [F.radio(1, .ghz24, 1, util: 20), F.radio(2, .ghz5, 149, 80, util: 58)])
        input.siteAPs = [input.ap!]
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.channel)?.verdict, .watch, "canal chargé à 58 %")
        // 2,4 GHz : canaux 1 et 3 qui se recouvrent.
        input.client.band = .ghz24
        input.client.radioID = 1
        input.client.channel = 1
        input.ap = F.ap("AP-A", [F.radio(1, .ghz24, 1, util: 20), F.radio(2, .ghz5, 149, 80, util: 20)])
        input.siteAPs = [input.ap!, F.ap("AP-B", [F.radio(1, .ghz24, 3, util: 20)]), F.ap("AP-C", [F.radio(1, .ghz24, 6, util: 20)])]
        let c = try WifiDiagnosis.diagnose(input).cause(.channel).unwrap("canal")
        try expectEqual(c.verdict, .problem, "recouvrement partiel en 2,4 GHz")
        try expect(c.evidence.contains { $0.contains("AP-B") }, "preuve : AP-B")
        try expect(c.actions.contains { $0.contains("canal 11") }, "canal conseillé 11 : \(c.actions)")
        // 5 GHz : même bloc de 80 MHz (36 et 44).
        input.client.band = .ghz5
        input.client.radioID = 2
        input.client.channel = 36
        input.ap = F.ap("AP-A", [F.radio(2, .ghz5, 36, 80, util: 20)])
        input.siteAPs = [input.ap!, F.ap("AP-B", [F.radio(2, .ghz5, 44, 80, util: 20)])]
        let five = try WifiDiagnosis.diagnose(input).cause(.channel).unwrap("canal 5 GHz")
        try expectEqual(five.verdict, .watch, "largeurs qui se recouvrent")
        try expect(five.actions.first?.contains("canal 149") == true, "bloc libre conseillé, sans DFS à égalité : \(five.actions)")
    }

    suite.add("Diagnostic Wi-Fi : interférences, voisins et bruit") {
        var input = F.healthyInput()
        input.neighbors = [FortiRogueAP(site: "Siège", ssid: "Voisin", channel: 149, band: .ghz5, rssi: -76, seenBy: ["AP-A"], vendor: "TP-Link")]
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.interference)?.verdict, .watch, "voisin entendu")
        input.neighbors.append(FortiRogueAP(site: "Siège", ssid: "Bureau-Corp", channel: 153, band: .ghz5, rssi: -58, status: .rogue, onWire: true, seenBy: ["AP-A"]))
        let i = try WifiDiagnosis.diagnose(input).cause(.interference).unwrap("interférences")
        try expectEqual(i.verdict, .problem, "AP non autorisé sur le même bloc")
        try expect(i.actions.contains { $0.contains("débrancher") && $0.contains("Bureau-Corp") }, "action : retirer l'AP : \(i.actions)")
        try expect(i.evidence.first?.contains("Bureau-Corp") == true, "le non autorisé d'abord")
        // Voisin vu par une autre borne seulement : ne compte pas.
        input.neighbors = [FortiRogueAP(site: "Siège", ssid: "Loin", channel: 149, band: .ghz5, rssi: -60, seenBy: ["AP-Z"])]
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.interference)?.verdict, .ok, "vu par une autre borne")
        // Bruit de fond élevé.
        input.neighbors = []
        input.ap = F.ap("AP-A", [F.radio(2, .ghz5, 149, 80, util: 20, noise: -76)])
        let n = try WifiDiagnosis.diagnose(input).cause(.interference).unwrap("bruit")
        try expectEqual(n.verdict, .problem, "bruit à −76 dBm")
        try expect(n.actions.contains { $0.contains("micro-ondes") }, "action : source de bruit")
    }

    suite.add("Diagnostic Wi-Fi : largeur et DFS") {
        var input = F.healthyInput()
        input.client.band = .ghz24
        input.client.radioID = 1
        input.client.channel = 6
        input.ap = F.ap("AP-A", [F.radio(1, .ghz24, 6, 40), F.radio(2, .ghz5, 149, 80)])
        input.siteAPs = [input.ap!]
        let w = try WifiDiagnosis.diagnose(input).cause(.width).unwrap("largeur")
        try expectEqual(w.verdict, .problem, "40 MHz en 2,4 GHz")
        try expect(w.actions.first?.contains("20\u{00A0}MHz") == true, "action : 20 MHz")
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.dfs)?.verdict, .ok, "DFS sans objet en 2,4 GHz")
        // DFS : canal 100 avec trois changements radar.
        input = F.healthyInput()
        input.client.channel = 100
        input.ap = F.ap("AP-A", [F.radio(2, .ghz5, 100, 40)])
        input.siteAPs = [input.ap!]
        input.measures.dfsChannelChanges = 3
        let d = try WifiDiagnosis.diagnose(input).cause(.dfs).unwrap("DFS")
        try expectEqual(d.verdict, .problem, "radar")
        try expect(d.actions.first?.contains("36 à 48") == true, "action : sortir du DFS")
        input.measures.dfsChannelChanges = nil
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.dfs)?.verdict, .ok, "DFS sans radar lu : OK")
        try expect(WifiDiagnosis.isDFS(channel: 52, band: .ghz5) && !WifiDiagnosis.isDFS(channel: 149, band: .ghz5), "canaux DFS")
    }

    suite.add("Diagnostic Wi-Fi : charge et clients lents") {
        var input = F.healthyInput()
        input.ap = F.ap("AP-A", [F.radio(2, .ghz5, 149, 80, util: 40, clients: 36)])
        let l = try WifiDiagnosis.diagnose(input).cause(.load).unwrap("charge")
        try expectEqual(l.verdict, .problem, "36 clients sur 30")
        try expect(l.evidence.first?.contains("36 clients") == true, "preuve : \(l.evidence)")
        input.ap = F.ap("AP-A", [F.radio(2, .ghz5, 149, 80, util: 40, clients: 24)])
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.load)?.verdict, .watch, "24 clients : à surveiller")
        // Clients lents sur un canal chargé.
        input.ap = F.ap("AP-A", [F.radio(2, .ghz5, 149, 80, util: 62)])
        input.apClients = (0..<6).map { n in
            FortiWifiClient(site: "Siège", mac: MACAddress(bytes: [2, 0, 0, 0, 1, UInt8(n)]), hostname: "Lent-\(n)", apName: "AP-A", radioID: 2,
                            band: .ghz5, rssi: -60, rateMbps: n < 3 ? 6.5 : 400)
        }
        let s = try WifiDiagnosis.diagnose(input).cause(.slowClients).unwrap("lents")
        try expectEqual(s.verdict, .problem, "3 sur 6 lents, canal à 62 %")
        try expect(s.actions.first?.contains("débits de base") == true, "action : débits de base")
        try expect(s.evidence.contains { $0.contains("Lent-0") }, "les plus lents nommés")
    }

    suite.add("Diagnostic Wi-Fi : capacités du client et bande 2,4 GHz") {
        var input = F.healthyInput()
        input.details.standard = .legacy
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.client)?.verdict, .problem, "802.11g")
        input.details.standard = .wifi4
        input.details.spatialStreams = 1
        input.details.powerSave = true
        let c = try WifiDiagnosis.diagnose(input).cause(.client).unwrap("client")
        try expectEqual(c.verdict, .watch, "Wi-Fi 4, une antenne, économie d'énergie")
        try expect(c.actions.contains { $0.contains("économie d’énergie") }, "action : économie d'énergie")
        // Débit bas avec un bon signal : problème du poste.
        input.details = WifiClientDetails(txRateMbps: 13, rxRateMbps: 6.5)
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.client)?.verdict, .problem, "débit bas, bon signal")
        // Même débit avec un signal faible : surtout la faute du signal.
        input.client.rssi = -80
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.client)?.verdict, .watch, "débit bas, signal faible")
        // Bande : 2,4 GHz alors que la borne et le poste font le 5 GHz.
        input = F.healthyInput()
        input.client.band = .ghz24
        input.client.radioID = 1
        input.client.channel = 1
        let b = try WifiDiagnosis.diagnose(input).cause(.band).unwrap("bande")
        try expectEqual(b.verdict, .problem, "5 GHz possible")
        try expect(b.actions.first?.contains("pilotage de bande") == true, "action : band steering")
        input.details.supports5GHz = nil
        input.details.standard = nil
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.band)?.verdict, .watch, "capacité inconnue")
        input.details.supports5GHz = false
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.band)?.verdict, .ok, "poste 2,4 GHz seulement")
        try expectEqual(WifiStandard.parse("802.11ax"), .wifi6, "ax")
        try expectEqual(WifiStandard.parse("11ac"), .wifi5, "ac")
        try expectEqual(WifiStandard.parse("Wi-Fi 6E"), .wifi6E, "6E")
        try expectEqual(WifiStandard.parse("be"), .wifi7, "be")
        try expectEqual(WifiStandard.parse("802.11g"), .legacy, "g")
    }

    suite.add("Diagnostic Wi-Fi : connexion, authentification et déconnexions") {
        var input = F.healthyInput()
        input.details.authFailures = 4
        input.details.lastFailureReason = "RADIUS refusé (Access-Reject)"
        let a = try WifiDiagnosis.diagnose(input).cause(.connection).unwrap("authentification")
        try expectEqual(a.verdict, .problem, "4 échecs")
        try expect(a.actions.contains { $0.contains("RADIUS") }, "action RADIUS")
        input.details.authFailures = 0
        input.details.lastFailureReason = "mauvais mot de passe (4-way handshake)"
        input.details.disconnects = 12
        let d = try WifiDiagnosis.diagnose(input).cause(.connection).unwrap("déconnexions")
        try expectEqual(d.verdict, .problem, "12 déconnexions")
        try expect(d.actions.contains { $0.contains("clé du SSID") }, "action mot de passe")
        input.details.lastFailureReason = nil
        input.details.disconnects = 4
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.connection)?.verdict, .watch, "4 déconnexions")
        input.details.disconnects = 0
        input.details.roams = 9
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.connection)?.verdict, .watch, "9 itinérances en une heure")
    }

    suite.add("Diagnostic Wi-Fi : DHCP, pas d'adresse et 169.254") {
        var input = F.healthyInput()
        input.client.ip = IPv4Address("169.254.12.7")
        let a = try WifiDiagnosis.diagnose(input).cause(.dhcp).unwrap("dhcp")
        try expectEqual(a.verdict, .problem, "169.254")
        try expect(a.summary.contains("169.254"), "en clair")
        input.client.ip = nil
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.dhcp)?.verdict, .problem, "pas d'adresse")
        input.ipFieldPresent = false
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.dhcp)?.verdict, .notMeasured, "adresse IP non donnée par la FortiGate")
        input.ipFieldPresent = true
        input.client.ip = IPv4Address("10.0.20.33")
        input.measures.dhcp = WifiDHCPStatus(scopeName: "VLAN 20", percent: 98, free: 2, poolSize: 100, critical: true)
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.dhcp)?.verdict, .problem, "étendue pleine")
        input.measures.dhcp = WifiDHCPStatus(scopeName: "VLAN 20", percent: 86, free: 14, poolSize: 100, warning: true)
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.dhcp)?.verdict, .watch, "étendue presque pleine")
        input.measures.dhcp = nil
        input.details.dhcpDelayMs = 7000
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.dhcp)?.verdict, .problem, "DHCP lent")
    }

    suite.add("Diagnostic Wi-Fi : au-delà du Wi-Fi, port du switch et WAN") {
        var input = F.healthyInput()
        input.measures.paths[0] = WifiPathMeasure(target: .gateway, address: "10.0.20.1", sent: 10, received: 8, averageMs: 4)
        let n = try WifiDiagnosis.diagnose(input).cause(.network).unwrap("réseau")
        try expectEqual(n.verdict, .problem, "20 % de perte vers la passerelle")
        try expect(n.actions.first?.contains("pas que Wi-Fi") == true, "action : pas que le Wi-Fi")
        try expect(n.summary.contains("depuis ce Mac"), "mesure de ce Mac")
        input = F.healthyInput()
        input.measures.paths[2] = WifiPathMeasure(target: .internet, address: "1.1.1.1", sent: 10, received: 10, averageMs: 210)
        let i = try WifiDiagnosis.diagnose(input).cause(.network).unwrap("internet")
        try expectEqual(i.verdict, .problem, "Internet à 210 ms")
        try expect(i.actions.first?.contains("lien Internet") == true, "action Internet")
        input.measures.paths[2] = WifiPathMeasure(target: .internet, address: "1.1.1.1", sent: 10, received: 0)
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.network)?.verdict, .problem, "aucune réponse")
        // Port à 100 Mb/s, défaut PoE.
        input = F.healthyInput()
        input.measures.uplink?.speedMbps = 100
        let u = try WifiDiagnosis.diagnose(input).cause(.uplink).unwrap("lien")
        try expectEqual(u.verdict, .problem, "100 Mb/s")
        try expect(u.actions.first?.contains("câble") == true, "action câble")
        let port = FortiSwitchPort(name: "port7", number: 7, linkUp: true, speedMbps: 1000, duplex: "full", poeEnabled: true, poeState: "fault", rxErrors: 42)
        input.measures.uplink = WifiUplinkStatus(switchName: "SW-1", port: port)
        let p = try WifiDiagnosis.diagnose(input).cause(.uplink).unwrap("PoE")
        try expectEqual(p.verdict, .problem, "défaut PoE")
        try expect(p.evidence.contains { $0.contains("42 erreurs") }, "erreurs comptées")
        // WAN tombé.
        input = F.healthyInput()
        input.measures.wan = [WifiWANStatus(name: "wan1", up: false)]
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.wan)?.verdict, .problem, "WAN tombé")
        // SSID plein.
        input = F.healthyInput()
        input.ssidClientCount = 100
        try expectEqual(WifiDiagnosis.diagnose(input).cause(.ssid)?.verdict, .problem, "SSID plein")
    }

    suite.add("Diagnostic Wi-Fi : ordre des causes et actions") {
        var input = F.healthyInput()
        input.client.rssi = -84
        input.client.snr = 10
        input.client.band = .ghz24
        input.client.radioID = 1
        input.client.channel = 1
        input.details.disconnects = 4
        let r = WifiDiagnosis.diagnose(input)
        try expectEqual(r.primary?.cause, .signal, "signal le plus probable")
        let verdicts = r.causes.map(\.verdict)
        try expect(zip(verdicts, verdicts.dropFirst()).allSatisfy { $0 >= $1 }, "problèmes, puis à surveiller, OK, non vérifiées")
        try expect(r.problems.map(\.cause).contains(.band), "bande en problème aussi")
        try expectEqual(r.overall, .problem, "verdict d'ensemble")
        try expectEqual(Set(r.actions).count, r.actions.count, "actions sans doublon")
        let firstSignal = try r.actions.firstIndex { $0.contains("Rapprocher") }.unwrap("action du signal")
        let watchAction = try r.actions.firstIndex { $0.contains("Déconnexions répétées") }.unwrap("action de la connexion")
        try expect(firstSignal == 0, "l'action de la cause principale en tête")
        try expect(watchAction > firstSignal, "actions des points à surveiller après celles des problèmes")
        try expect(r.actions.count <= 10, "dix actions au plus")
        let text = WifiDiagnosisText.plain(r)
        try expect(text.contains("1. ") && text.contains("[Problème] Signal"), "texte à copier")
        try expect(text.contains("Lecture seule"), "rappel lecture seule")
        try expect(text.contains("Verdict\u{00A0}:") && !text.contains(" :"), "espace insécable avant « : »")
    }

    suite.add("Diagnostic Wi-Fi : entrée tirée d'une lecture") {
        let a = F.ap("AP-A", [F.radio(1, .ghz24, 6, util: 30), F.radio(2, .ghz5, 36, 80, util: 30)])
        let b = F.ap("AP-B", [F.radio(1, .ghz24, 11, util: 30), F.radio(2, .ghz5, 44, 80, util: 30)])
        var client = FortiWifiClient(site: "Siège", mac: F.mac, ip: IPv4Address("10.0.20.9"), hostname: "Android", ssid: "Interne", apName: "AP-B",
                                     radioID: 1, band: .ghz24, channel: 11, rssi: -77, noise: -93, rateMbps: 26, associatedFor: 30 * 60)
        let other = FortiWifiClient(site: "Siège", mac: MACAddress(bytes: [2, 1, 1, 1, 1, 1]), ssid: "Interne", apName: "AP-A", radioID: 2, band: .ghz5, rssi: -50)
        let overview = FortiWifiOverview(aps: [a, b], clients: [client, other],
                                         ssids: [FortiSSID(site: "Siège", name: "wifi", ssid: "Interne", security: "wpa2-only-enterprise", vlan: 20)],
                                         rogues: [FortiRogueAP(site: "Siège", ssid: "UBNT", channel: 11, band: .ghz24, rssi: -69, seenBy: ["AP-B"], vendor: "Ubiquiti")],
                                         sites: ["Siège"])
        let input = WifiDiagnosisInput.from(overview: overview, client: client)
        try expectEqual(input.ap?.name, "AP-B", "borne retrouvée")
        try expectEqual(input.radio?.radioID, 1, "radio retrouvée")
        try expectEqual(input.ssidClientCount, 2, "clients du SSID")
        try expectEqual(input.apClients.count, 1, "clients de la borne")
        let r = WifiDiagnosis.diagnose(input)
        try expectEqual(r.cause(.signal)?.verdict, .watch, "−77 dBm")
        try expectEqual(r.cause(.interference)?.verdict, .problem, "voisin UBNT fort (−69 dBm) sur le canal 11")
        try expectEqual(r.cause(.band)?.verdict, .watch, "2,4 GHz, 5 GHz disponible")
        try expectEqual(r.cause(.sticky)?.verdict, .watch, "AP-A en ligne, 30 min sur AP-B")
        client.site = "Autre"
        try expect(WifiDiagnosisInput.from(overview: overview, client: client).ap == nil, "pas de borne d'un autre site")
    }

    suite.add("Diagnostic Wi-Fi : canal conseillé") {
        let a = F.ap("AP-A", [F.radio(1, .ghz24, 6)])
        let b = F.ap("AP-B", [F.radio(1, .ghz24, 1)])
        let neighbors = [FortiRogueAP(site: "Siège", ssid: "Voisin", channel: 6, band: .ghz24, rssi: -60, seenBy: ["AP-A"])]
        try expectEqual(WifiDiagnosis.suggestedChannel(radio: a.radios[0], ap: a, siteAPs: [a, b], neighbors: neighbors), 11, "11 : ni borne ni voisin")
        let c = F.ap("AP-C", [F.radio(1, .ghz24, 11)])
        try expect(WifiDiagnosis.suggestedChannel(radio: c.radios[0], ap: c, siteAPs: [a, b, c], neighbors: []) == nil, "11 déjà le meilleur")
    }

    suite.add("Diagnostic Wi-Fi : borne entière") {
        let busy = F.ap("AP-A", [F.radio(1, .ghz24, 1, util: 30), F.radio(2, .ghz5, 36, 80, util: 85)])
        let other = F.ap("AP-B", [F.radio(2, .ghz5, 44, 80, util: 20)])
        let off = F.ap("AP-QUAI", [F.radio(1, .ghz24, 6)], connected: false)
        let clients: [FortiWifiClient] = (0..<5).map { (n: Int) -> FortiWifiClient in
            let on24 = n < 4
            let band: WifiBand = on24 ? .ghz24 : .ghz5
            let rssi = n < 3 ? -80 : -55
            return FortiWifiClient(site: "Siège", mac: MACAddress(bytes: [2, 0, 0, 0, 2, UInt8(n)]), hostname: "C\(n)", apName: "AP-A",
                                   radioID: on24 ? 1 : 2, band: band, rssi: rssi, rateMbps: 50)
        }
        let overview = FortiWifiOverview(aps: [busy, other, off], clients: clients, sites: ["Siège"])
        let r = WifiDiagnosis.diagnose(ap: busy, overview: overview)
        try expectEqual(r.subject, .ap(name: "AP-A"), "sujet")
        try expectEqual(r.cause(.channel)?.verdict, .problem, "canal 5 GHz saturé")
        try expect(r.cause(.channel)?.evidence.contains { $0.contains("AP-B") } == true, "chevauchement avec AP-B")
        try expectEqual(r.cause(.signal)?.verdict, .problem, "3 clients sur 5 faibles")
        try expectEqual(r.cause(.band)?.verdict, .watch, "4 clients sur 5 en 2,4 GHz")
        try expectEqual(r.cause(.uplink)?.verdict, .notMeasured, "port inconnu")
        let o = WifiDiagnosis.diagnose(ap: off, overview: overview)
        try expectEqual(o.primary?.cause, .uplink, "borne hors ligne en tête")
        try expect(o.actions.first?.contains("PoE") == true, "action PoE : \(o.actions)")
        try expect(o.cause(.channel) == nil, "pas de radio à juger hors ligne")
    }

    suite.add("Diagnostic Wi-Fi : SSID entier") {
        let a = F.ap("AP-A", [F.radio(2, .ghz5, 36, 80)])
        let ssid = FortiSSID(site: "Siège", name: "wifi-invites", ssid: "Invités", security: "open", vlan: 60, maxClients: 10, captivePortal: true)
        let clients = (0..<10).map { n in
            FortiWifiClient(site: "Siège", mac: MACAddress(bytes: [2, 0, 0, 0, 3, UInt8(n)]), ssid: "Invités", apName: "AP-A", radioID: 2, band: .ghz5, rssi: -60, rateMbps: 300)
        }
        let twin = FortiRogueAP(site: "Siège", ssid: "Invités", bssid: MACAddress("02:00:00:00:00:99"), channel: 6, band: .ghz24, rssi: -62, vendor: "Inconnu")
        let overview = FortiWifiOverview(aps: [a], clients: clients, ssids: [ssid], rogues: [twin], sites: ["Siège"])
        let measures = WifiDiagnosisMeasures(dhcp: WifiDHCPStatus(scopeName: "VLAN 60", percent: 97, free: 3, poolSize: 100, critical: true))
        let r = WifiDiagnosis.diagnose(ssid: ssid, overview: overview, measures: measures)
        try expectEqual(r.subject, .ssid(name: "Invités"), "sujet")
        try expectEqual(r.cause(.interference)?.verdict, .problem, "jumeau malveillant")
        try expectEqual(r.cause(.ssid)?.verdict, .problem, "10 clients sur 10")
        try expectEqual(r.cause(.dhcp)?.verdict, .problem, "étendue des invités pleine")
        try expect(r.context.contains("VLAN 60") && r.context.contains("10 clients"), "contexte : \(r.context)")
        // SSID ouvert sans autre souci : à surveiller (sécurité).
        let calm = FortiWifiOverview(aps: [a], clients: Array(clients.prefix(2)), ssids: [ssid], sites: ["Siège"])
        try expectEqual(WifiDiagnosis.diagnose(ssid: ssid, overview: calm).cause(.ssid)?.verdict, .watch, "réseau ouvert")
    }

    suite.add("Diagnostic Wi-Fi : MAC masquées dans les preuves du rapport") {
        let text = ReportBuilder.maskMACs("Jumeau 5C:E9:1E:40:00:01 et 02-aa-bb-cc-dd-ee, pas 10.0.20.33")
        try expectEqual(text, "Jumeau 5C:E9:1E:xx:xx:xx et 02-aa-bb:xx:xx:xx, pas 10.0.20.33", "MAC masquées : \(text)")
    }

    suite.add("Diagnostic Wi-Fi : suivi dans le temps") {
        var history = WifiDiagnosisHistory()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Toronto")!
        func at(_ day: Int, _ hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: 10))! }
        var input = F.healthyInput()
        input.client.rssi = -84
        for (day, hour) in [(2, 9), (3, 10), (4, 9)] { history.add(WifiDiagnosis.diagnose(input, now: at(day, hour)), rssi: -84) }
        input.client.rssi = -52
        history.add(WifiDiagnosis.diagnose(input, now: at(4, 15)), rssi: -52)
        let key = WifiDiagnosisSubject.client(mac: F.mac.formatted(.upperColon), name: "x").key
        try expectEqual(history.records[key]?.count, 4, "quatre résumés")
        try expectEqual(history.records[key]?.last?.overall, .ok, "le dernier diagnostic")
        let text = try history.recurrence(key, calendar: cal).unwrap("récurrence")
        try expect(text.contains("3 diagnostics sur 4"), "compte : \(text)")
        try expect(text.contains("entre 8\u{00A0}h et 10\u{00A0}h"), "heures : \(text)")
        try expect(text.contains("signal"), "cause : \(text)")
        try expect(text.contains("revenu à la normale"), "dernier OK : \(text)")
        try expect(history.previous(key, before: at(4, 15))?.overall == .problem, "diagnostic précédent")
        // Limite de taille.
        for n in 0..<50 { history.add(WifiDiagnosis.diagnose(input, now: at(5, 0).addingTimeInterval(Double(n) * 60))) }
        try expectEqual(history.records[key]?.count, WifiDiagnosisHistory.keepPerSubject, "historique borné")
        // Rapport : un seul par sujet.
        let r1 = WifiDiagnosis.diagnose(input, now: at(6, 8))
        history.report(r1)
        history.report(WifiDiagnosis.diagnose(input, now: at(6, 9)))
        try expectEqual(history.reported.count, 1, "le plus récent remplace l'ancien")
        // Fichier.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-diag-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try history.save(to: url)
        let back = WifiDiagnosisHistory.load(from: url)
        try expectEqual(back.records[key]?.count, history.records[key]?.count, "relu")
        try expectEqual(back.reported.first?.subject, history.reported.first?.subject, "rapport relu")
        try expect(WifiDiagnosisHistory.load(from: url.appendingPathExtension("absent")).records.isEmpty, "fichier absent : vide")
        try expect(WifiDiagnosisHistory.recurrence([]) == nil, "trop peu de diagnostics")
        // Une entrée illisible (cause d'une version future) n'efface pas les autres.
        let odd = Data(#"{"records":{"a":[{"date":"2026-11-04T10:00:00Z","overall":9,"problems":[]},{"date":"2026-11-04T11:00:00Z","overall":1,"problems":[]}],"b":[]},"reported":[{"x":1}]}"#.utf8)
        let oddURL = url.appendingPathExtension("lossy")
        defer { try? FileManager.default.removeItem(at: oddURL) }
        try odd.write(to: oddURL)
        let lossy = WifiDiagnosisHistory.load(from: oddURL)
        try expectEqual(lossy.records["a"]?.count, 1, "entrée illisible ignorée, l'autre gardée")
        try expect(lossy.reported.isEmpty, "rapport illisible ignoré")
        // Nombre de sujets borné.
        var many = WifiDiagnosisHistory()
        for n in 0..<(WifiDiagnosisHistory.keepSubjects + 5) {
            var r = WifiDiagnosis.diagnose(input, now: at(7, 0).addingTimeInterval(Double(n) * 60))
            r.subject = .client(mac: String(format: "02:00:00:00:%02X:%02X", n / 256, n % 256), name: "c\(n)")
            many.add(r)
        }
        try expectEqual(many.records.count, WifiDiagnosisHistory.keepSubjects, "sujets bornés")
        try expect(many.records[WifiDiagnosisSubject.client(mac: "02:00:00:00:00:00", name: "").key] == nil, "le plus ancien tombe")
    }

    suite.add("Diagnostic Wi-Fi : seuils réglables et relus") {
        let forti = FortiWifiThresholds(weakRSSI: -72, weakSNR: 18, maxClientsPerRadio: 40, maxChannelUtilization: 80)
        let t = WifiDiagnosisThresholds(forti: forti)
        try expectEqual(t.weakRSSI, -72, "seuil du signal repris")
        try expectEqual(t.badRSSI, -80, "problème 8 dB plus bas")
        try expectEqual(t.maxClientsPerRadio, 40, "surcharge reprise")
        try expectEqual(t.saturatedUtilization, 80, "saturation reprise")
        let partial = try JSONDecoder().decode(WifiDiagnosisThresholds.self, from: Data(#"{"weakRSSI":-65}"#.utf8))
        try expectEqual(partial.weakRSSI, -65, "valeur lue")
        try expectEqual(partial.lossProblem, WifiDiagnosisThresholds.standard.lossProblem, "valeur par défaut pour le reste")
        let odd = WifiDiagnosisThresholds(weakRSSI: -70, badRSSI: -60)
        try expect(odd.badRSSI <= odd.weakRSSI, "seuils cohérents")
    }

    suite.add("Diagnostic Wi-Fi : section de rapport") {
        var input = F.healthyInput()
        input.client.rssi = -84
        let bad = WifiDiagnosis.diagnose(input)
        let good = WifiDiagnosis.diagnose(F.healthyInput())
        var report = ReportInput(devices: [])
        report.wifiDiagnoses = [good, bad]
        let config = ReportConfig(template: .audit, sections: [.resume, .wifiDiag], maskMAC: true)
        let doc = ReportBuilder.build(config: config, input: report)
        let section = try doc.sections.first { $0.kind == .wifiDiag }.unwrap("section présente")
        try expect(section.heading.contains("Diagnostic Wi-Fi"), "titre : \(section.heading)")
        let tables = section.tables
        try expect(tables.count >= 2, "tableau de synthèse et causes")
        try expectEqual(tables[0].rows.first?.cells[3].text, "Problème", "le problème en tête")
        try expect(!ReportTemplate.allCases.contains { $0.defaultSections.contains(.wifiDiag) }, "facultative")
        report.wifiDiagnoses = []
        if case .note(let text)? = ReportBuilder.build(config: config, input: report).sections.first(where: { $0.kind == .wifiDiag })?.blocks.first {
            try expect(text.contains("Ajouter au rapport du site"), "explication : \(text)")
        } else {
            throw TestFailure(message: "note attendue sans diagnostic", file: #fileID, line: #line)
        }
    }
}
