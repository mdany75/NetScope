import Foundation
import NetScopeCore

// Note 39 : état du WAN de chaque FortiGate. Réponses JSON fixes de FortiOS en variantes de
// versions (7.4 : virtual-wan/members et system/sdwan ; 6.4 : sans members, virtual-wan-link ;
// réponses nues), état des liens selon les seuils et les SLA, tunnels (dial-up, partiel), débit
// entre deux lectures, lecture par un faux transport (404, 403, jeton retiré), sondes de la
// Surveillance, vue multisite et section de rapport. Aucun réseau.

enum WANFixtures {
    static let status74 = FortiFixtures.status74

    static let interfaceConfig74 = """
    {"http_method":"GET","results":[
      {"name":"wan1","q_origin_key":"wan1","alias":"Bell Fibre","role":"wan","type":"physical","status":"up","mode":"static",
       "ip":"203.0.113.10 255.255.255.248","estimated-upstream-bandwidth":1000000,"estimated-downstream-bandwidth":1000000},
      {"name":"wan2","alias":"Vidéotron Câble","role":"wan","type":"physical","status":"up","mode":"dhcp","ip":"0.0.0.0 0.0.0.0",
       "estimated-upstream-bandwidth":0,"estimated-downstream-bandwidth":0},
      {"name":"dmz","role":"dmz","type":"physical","status":"down","ip":"10.10.10.1 255.255.255.0"},
      {"name":"internal","role":"lan","type":"hard-switch","status":"up","ip":"10.182.122.1 255.255.255.0"},
      {"name":"VPN-QUEBEC","role":"undefined","type":"tunnel","status":"up","ip":"0.0.0.0 0.0.0.0"},
      {"name":"lte","alias":"Secours LTE","role":"wan","type":"physical","status":"down","mode":"dhcp"}
    ],"vdom":"root","status":"success","version":"v7.4.4"}
    """

    static let interfaceStatus74 = """
    {"http_method":"GET","results":{
      "wan1":{"id":"wan1","name":"wan1","alias":"Bell Fibre","mac":"04:d5:90:aa:bb:01","ip":"203.0.113.10","mask":29,"link":true,
              "speed":1000.0,"duplex":1,"tx_packets":120,"rx_packets":240,"tx_bytes":1000000,"rx_bytes":5000000,"tx_errors":0,"rx_errors":0},
      "wan2":{"id":"wan2","name":"wan2","ip":"198.51.100.73","mask":24,"link":true,"speed":1000.0,"tx_bytes":200000,"rx_bytes":900000,
              "tx_errors":0,"rx_errors":12},
      "internal":{"id":"internal","name":"internal","ip":"10.182.122.1","mask":24,"link":true,"speed":1000.0},
      "lte":{"id":"lte","name":"lte","link":false,"speed":0}
    },"vdom":"root","status":"success"}
    """

    static let health74 = """
    {"http_method":"GET","results":{
      "Google_DNS":{
        "wan1":{"status":"up","latency":6.82,"jitter":0.91,"packet_loss":0,"packet_sent":30412,"packet_received":30412,
                "sla_targets_met":[1],"session":1842,"tx_bandwidth":48700000,"rx_bandwidth":312400000,"state_changed":1791000000},
        "wan2":{"status":"up","latency":38.6,"jitter":12.4,"packet_loss":4,"packet_sent":30410,"packet_received":29194,
                "sla_targets_met":[],"session":611,"tx_bandwidth":9100000,"rx_bandwidth":86300000,"state_changed":1793600000},
        "lte":{"status":"error"}
      },
      "Microsoft_365":{
        "wan1":{"status":"up","latency":11.2,"jitter":1.6,"packet_loss":0,"sla_targets_met":[1]},
        "wan2":{"status":"up","latency":44.1,"jitter":15.8,"packet_loss":3.2,"sla_targets_met":[]}
      }
    },"vdom":"root","status":"success"}
    """

    static let members74 = """
    {"http_method":"GET","results":{
      "wan1":{"status":"up","link":"up","session":1842,"tx_bytes":1000000,"rx_bytes":5000000,"tx_bandwidth":48700000,
              "rx_bandwidth":312400000,"state_changed":1791000000,"zone":"virtual-wan-link","gateway":"203.0.113.9","interface":"wan1"},
      "wan2":{"status":"up","link":"up","session":611,"tx_bandwidth":9100000,"rx_bandwidth":86300000,"zone":"virtual-wan-link",
              "gateway":"198.51.100.1","interface":"wan2"}
    },"status":"success"}
    """

    static let sdwan74 = """
    {"http_method":"GET","results":{"status":"enable","load-balance-mode":"source-ip-based",
      "zone":[{"name":"virtual-wan-link"}],
      "members":[{"seq-num":1,"interface":"wan1","zone":"virtual-wan-link","gateway":"203.0.113.9","status":"enable"},
                 {"seq-num":2,"interface":"wan2","zone":"virtual-wan-link","gateway":"0.0.0.0","status":"enable"}],
      "health-check":[
        {"name":"Google_DNS","server":"\\"8.8.8.8\\" \\"8.8.4.4\\"","protocol":"ping","members":[{"seq-num":1},{"seq-num":2}],
         "sla":[{"id":1,"latency-threshold":100,"jitter-threshold":30,"packetloss-threshold":2}]},
        {"name":"Microsoft_365","server":"www.office.com","protocol":"http","members":[{"seq-num":1},{"seq-num":2}],
         "sla":[{"id":1,"latency-threshold":150,"jitter-threshold":40,"packetloss-threshold":3}]}
      ]},"vdom":"root","status":"success"}
    """

    static let ipsec74 = """
    {"http_method":"GET","results":[
      {"proxyid":[{"proxy_src":[{"subnet":"10.182.0.0/255.255.0.0","port":0,"protocol":0}],
                   "proxy_dst":[{"subnet":"10.20.0.0/255.255.0.0","port":0,"protocol":0}],
                   "status":"up","p2name":"VPN-LAVAL-LAN","p2serial":1,"expire":21604,"incoming_bytes":48204117830,"outgoing_bytes":61993402118}],
       "name":"VPN-LAVAL","comments":"Vers Entrepôt Laval","wizard-type":"site-to-site","connection_count":1,"creation_time":533000,
       "username":"","type":"automatic","incoming_bytes":48204117830,"outgoing_bytes":61993402118,"rgwy":"192.0.2.44","tun_id":"192.0.2.44"},
      {"proxyid":[{"proxy_src":[{"subnet":"10.182.0.0/255.255.0.0"}],"proxy_dst":[{"subnet":"10.30.0.0/255.255.0.0"}],
                   "status":"down","p2name":"VPN-QUEBEC-LAN","incoming_bytes":0,"outgoing_bytes":0},
                  {"proxy_src":[{"subnet":"10.182.0.0/255.255.0.0"}],"proxy_dst":[{"subnet":"10.40.12.0/255.255.255.0"}],
                   "status":"down","p2name":"VPN-QUEBEC-VOIX"}],
       "name":"VPN-QUEBEC","comments":"Vers Bureau Québec","connection_count":0,"type":"automatic","rgwy":"203.0.113.30",
       "incoming_bytes":0,"outgoing_bytes":0},
      {"proxyid":[{"status":"up","p2name":"VPN-DRUMMOND-LAN"},{"status":"down","p2name":"VPN-DRUMMOND-VOIX"}],
       "name":"VPN-DRUMMOND","type":"automatic","rgwy":"192.0.2.130","creation_time":7200},
      {"proxyid":[],"name":"Nomades","type":"dialup","comments":"FortiClient","connection_count":0,"rgwy":"0.0.0.0"},
      {"proxyid":[{"status":"up","p2name":"Nomades"}],"name":"Nomades_0","parent":"Nomades","type":"dialup","rgwy":"70.52.18.144"}
    ],"vdom":"root","status":"success"}
    """

    static let ssl74 = """
    {"http_method":"GET","results":[
      {"index":0,"user_name":"mgagnon","remote_host":"70.52.18.144","last_login_time":1793690000,"subsessions":[]},
      {"index":1,"user_name":"jtremblay","remote_host":"184.161.40.9","last_login_time":1793700000}
    ],"status":"success"}
    """

    // MARK: FortiOS 6.4 : sans virtual-wan/members, configuration virtual-wan-link, valeurs en texte.

    static let health64 = """
    {"results":{"ping_8.8.8.8":{"wan1":{"status":"up","latency":"12.5","jitter":"2.1","packet_loss":"0.000"},
                                 "wan2":{"status":"down","packet_loss":"100.000","latency":"0","jitter":"0"}}},
     "status":"success","version":"v6.4.15"}
    """

    static let virtualWANLink64 = """
    {"results":[{"status":"enable",
      "members":[{"seq-num":1,"interface":"wan1"},{"seq-num":2,"interface":"wan2"}],
      "health-check":[{"name":"ping_8.8.8.8","server":"8.8.8.8","protocol":"ping","members":[{"seq-num":1},{"seq-num":2}],"sla":[]}]
    }],"status":"success"}
    """

    static let interfaceStatus64 = """
    {"results":{"wan1":{"name":"wan1","link":"up","speed":"1000full","rx_bytes":"100","tx_bytes":"50"},
                "wan2":{"name":"wan2","link":"down"}}}
    """

    /// Réponse nue (sans enveloppe) : liste d'interfaces sans configuration lisible.
    static let bareStatus = """
    [{"name":"wan","link":true,"speed":1000},{"name":"lan","link":true},{"name":"internet2","link":false}]
    """

    static let bareIPsec = """
    [{"name":"vers-siege","status":"up","rgwy":"203.0.113.10"},{"name":"vers-labo","status":"down"}]
    """
}

func registerWANTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_700_000)
    func data(_ s: String) -> Data { Data(s.utf8) }

    func full74() -> FortiFakeTransport {
        FortiFakeTransport([
            WANPaths.system: (200, WANFixtures.status74),
            WANPaths.interfaceConfig: (200, WANFixtures.interfaceConfig74),
            WANPaths.interfaceStatus: (200, WANFixtures.interfaceStatus74),
            WANPaths.healthCheck: (200, WANFixtures.health74),
            WANPaths.members: (200, WANFixtures.members74),
            WANPaths.sdwanConfig: (200, WANFixtures.sdwan74),
            WANPaths.ipsec: (200, WANFixtures.ipsec74),
            WANPaths.ssl: (200, WANFixtures.ssl74),
        ])
    }

    suite.add("WAN : analyseurs tolérants (7.4, 6.4, réponses nues)") {
        let config = try WANParsers.interfaceConfig(data(WANFixtures.interfaceConfig74)).unwrapWAN("configuration")
        try expectEqual(config["wan1"]?.role, "wan", "rôle lu")
        try expectEqual(config["wan1"]?.prefix, 29, "masque converti")
        try expectEqual(config["wan1"]?.estimatedDownKbps, 1_000_000, "bande passante estimée")
        try expect(config["wan2"]?.ip == nil && config["wan2"]?.estimatedDownKbps == nil, "0.0.0.0 et 0 : inconnus")
        try expectEqual(config["dmz"]?.adminUp, false, "état administratif")

        let states = try WANParsers.interfaceStatus(data(WANFixtures.interfaceStatus74)).unwrapWAN("état")
        try expectEqual(states["wan2"]?.rxErrors, 12, "erreurs")
        try expectEqual(states["wan1"]?.speedMbps, 1000, "vitesse")
        try expectEqual(states["lte"]?.linkUp, false, "lien tombé")
        let old = try WANParsers.interfaceStatus(data(WANFixtures.interfaceStatus64)).unwrapWAN("état 6.4")
        try expect(old["wan1"]?.linkUp == true && old["wan1"]?.speedMbps == 1000 && old["wan1"]?.rxBytes == 100, "6.4 : texte « up », « 1000full »")
        try expectEqual(old["wan2"]?.linkUp, false, "6.4 : « down »")

        let health = try WANParsers.health(data(WANFixtures.health74), now: now).unwrapWAN("sondes")
        try expectEqual(health.count, 5, "trois membres pour Google_DNS, deux pour Microsoft_365")
        let wan2 = try health.first { $0.checkName == "Google_DNS" && $0.interface == "wan2" }.unwrapWAN("wan2")
        try expect(wan2.lossPercent == 4 && wan2.latencyMs == 38.6 && wan2.slaTargetsMet == [], "mesures lues")
        try expectEqual(wan2.rxBps, 86_300_000, "débit en b/s")
        try expect(health.first { $0.interface == "lte" }?.participates == false, "« error » : ne participe pas")
        let h64 = try WANParsers.health(data(WANFixtures.health64), now: now).unwrapWAN("sondes 6.4")
        try expect(h64.first { $0.interface == "wan1" }?.latencyMs == 12.5, "6.4 : nombres en texte")
        try expect(h64.first { $0.interface == "wan2" }?.isUp == false, "6.4 : sonde tombée")
        try expect(WANParsers.health(data(#"{"results":{},"status":"success"}"#))?.isEmpty == true, "sans SD-WAN : aucune mesure")
        try expect(WANParsers.health(data("pas du JSON")) == nil, "illisible")

        let members = try WANParsers.members(data(WANFixtures.members74)).unwrapWAN("membres")
        try expect(members.first { $0.name == "wan1" }?.gateway?.description == "203.0.113.9", "passerelle")
        try expect(members.allSatisfy(\.isSDWANMember), "membres SD-WAN")

        let sdwan = try WANParsers.sdwanConfig(data(WANFixtures.sdwan74)).unwrapWAN("sdwan")
        try expectEqual(sdwan.checks.first?.servers, ["8.8.8.8", "8.8.4.4"], "serveurs entre guillemets")
        try expectEqual(sdwan.checks.first?.members, ["wan1", "wan2"], "membres par numéro de séquence")
        try expectEqual(sdwan.checks.first?.sla.first?.lossPercent, 2, "seuil de perte du SLA")
        let legacy = try WANParsers.sdwanConfig(data(WANFixtures.virtualWANLink64)).unwrapWAN("virtual-wan-link")
        try expect(legacy.checks.count == 1 && legacy.members.count == 2, "6.4 : virtual-wan-link")

        let tunnels = try WANParsers.tunnels(data(WANFixtures.ipsec74), now: now).unwrapWAN("tunnels")
        try expectEqual(tunnels.count, 5, "tunnels lus")
        let laval = try tunnels.first { $0.name == "VPN-LAVAL" }.unwrapWAN("laval")
        try expectEqual(laval.phase2.first?.source, "10.182.0.0/16", "sélecteur converti en préfixe")
        try expectEqual(laval.upSince, now.addingTimeInterval(-533_000), "creation_time : secondes depuis la montée")
        try expectEqual(laval.state, .up, "monté")
        try expectEqual(tunnels.first { $0.name == "VPN-QUEBEC" }?.state, .down, "tombé")
        try expectEqual(tunnels.first { $0.name == "VPN-DRUMMOND" }?.state, .partial, "une phase 2 sur deux")
        let dialup = try tunnels.first { $0.name == "Nomades" }.unwrapWAN("dialup")
        try expect(dialup.state == .idle && dialup.remoteGateway == nil, "serveur d'accès distant sans client : en attente")
        try expectEqual(tunnels.first { $0.name == "Nomades_0" }?.state, .up, "instance d'un client nomade")
        let bare = try WANParsers.tunnels(data(WANFixtures.bareIPsec), now: now).unwrapWAN("tunnels nus")
        try expect(bare.map(\.state) == [.up, .down], "sans phase 2 : état donné par « status »")

        let ssl = try WANParsers.sslUsers(data(WANFixtures.ssl74), now: now).unwrapWAN("ssl")
        try expect(ssl.count == 2 && ssl[0].user == "mgagnon" && ssl[0].loginAt != nil, "utilisateurs VPN SSL")

        // Horodatages aberrants (1e30) : ignorés à la lecture, et jamais de plantage à l'affichage.
        let absurd = """
        {"results":[{"user_name":"x","last_login_time":1e30}]}
        """
        let odd = try WANParsers.sslUsers(data(absurd), now: now).unwrapWAN("ssl aberrant")
        try expect(odd.first?.loginAt == nil, "horodatage de 1e30 ignoré")
        let farTunnel = """
        [{"name":"t","status":"up","creation_time":1e30}]
        """
        let far = try WANParsers.tunnels(data(farTunnel), now: now).unwrapWAN("tunnel aberrant")
        try expect(far.first?.upSince == nil, "date de création dans le futur ignorée")
        try expectEqual(WANFormat.duration(since: Date(timeIntervalSince1970: 1e30), now: now), "—", "durée d’une date lointaine")
        try expectEqual(WANFormat.duration(since: Date(timeIntervalSince1970: -1e30), now: now), "—", "durée d’une date très ancienne")

        // Une FortiGate en erreur parmi d'autres : les sondes qui la visent le disent.
        let failing = ["Entrepôt Laval": "FortiGate injoignable"]
        let all = MonWANChecks.tunnelDown(target: "*", overview: WANOverview(), siteErrors: failing, now: now)
        try expect(!all.result.reachable && all.result.value == "Lecture impossible" && all.result.error?.contains("Entrepôt Laval") == true,
                   "« * » : lecture impossible d’un site signalée")
        let other = MonWANChecks.wanDegraded(target: "Siège / wan1", overview: WANOverview(), siteErrors: failing,
                                             thresholds: .standard, now: now)
        try expect(other.result.value != "Lecture impossible", "autre site visé : l’erreur de Laval ne compte pas")
        let lavalProbe = MonWANChecks.wanDegraded(target: "Entrepôt Laval / wan1", overview: WANOverview(), siteErrors: failing,
                                             thresholds: .standard, now: now)
        try expectEqual(lavalProbe.result.value, "Lecture impossible", "site visé en erreur : lecture impossible, pas « introuvable »")
    }

    suite.add("WAN : interfaces WAN, état des liens, SLA et débit") {
        let config = WANParsers.interfaceConfig(data(WANFixtures.interfaceConfig74))
        let states = WANParsers.interfaceStatus(data(WANFixtures.interfaceStatus74)) ?? [:]
        let health = WANParsers.health(data(WANFixtures.health74), now: now) ?? []
        let members = WANParsers.members(data(WANFixtures.members74)) ?? []
        let sdwan = WANParsers.sdwanConfig(data(WANFixtures.sdwan74))
        let links = WANAnalysis.wanInterfaces(config: config, states: states, members: members, configMembers: sdwan?.members ?? [], health: health)
        try expectEqual(links.map(\.name), ["lte", "wan1", "wan2"], "rôle « wan » ; ni LAN, ni DMZ, ni tunnel")
        let wan2 = try links.first { $0.name == "wan2" }.unwrapWAN("wan2")
        try expect(wan2.ip?.description == "198.51.100.73" && wan2.prefix == 24, "adresse DHCP prise dans l'état")
        try expect(wan2.isSDWANMember && wan2.rxBps == 86_300_000 && wan2.gateway?.description == "198.51.100.1", "membre SD-WAN fusionné")

        let guessed = WANAnalysis.wanInterfaces(config: nil, states: WANParsers.interfaceStatus(data(WANFixtures.bareStatus)) ?? [:],
                                                members: [], configMembers: [], health: [])
        try expectEqual(guessed.map(\.name), ["internet2", "wan"], "sans configuration : noms « wanN », « internetN »")

        let checks = sdwan?.checks ?? []
        let t = WANThresholds.standard
        let e1 = WANAnalysis.evaluate(links[1], health: health, config: checks, thresholds: t)
        try expect(e1.state == .up && e1.slaMet == 2 && e1.slaTotal == 2, "wan1 : bon, SLA 2/2")
        let e2 = WANAnalysis.evaluate(wan2, health: health, config: checks, thresholds: t)
        try expectEqual(e2.state, .degraded, "wan2 dégradé")
        try expect(e2.reasons.first == "perte 4\u{00A0}% (seuil 2\u{00A0}%) vers Google_DNS", "raison : \(e2.reasons)")
        try expect(e2.reasons.contains("SLA «\u{00A0}Google_DNS\u{00A0}» non respecté"), "SLA non respecté")
        let loose = WANAnalysis.evaluate(wan2, health: health, config: [], thresholds: WANThresholds(latencyMs: 500, jitterMs: 100, lossPercent: 10))
        try expectEqual(loose.state, .up, "seuils larges, sans SLA connus : bon")
        let lte = WANAnalysis.evaluate(links[0], health: health, config: checks, thresholds: t)
        try expectEqual(lte.state, .disabled, "lien désactivé : ni panne ni alerte")
        var unplugged = wan2
        unplugged.linkUp = false
        try expectEqual(WANAnalysis.evaluate(unplugged, health: health, config: checks, thresholds: t).state, .down, "câble débranché")
        let dead = WANParsers.health(data(WANFixtures.health64), now: now) ?? []
        let e64 = WANAnalysis.evaluate(WANInterfaceStatus(name: "wan2", linkUp: true), health: dead, config: [], thresholds: t)
        try expect(e64.state == .down && e64.reasons.first?.contains("aucune réponse") == true, "toutes les sondes muettes : tombé")
        try expectEqual(WANAnalysis.evaluate(WANInterfaceStatus(name: "x"), health: [], config: [], thresholds: t).state, .unknown, "état illisible")

        // Débit entre deux lectures (lien sans SD-WAN).
        let first = WANReadReport(interfaces: [WANInterfaceStatus(name: "wan", rxBytes: 1_000_000, txBytes: 500_000)], readAt: now)
        let second = WANReadReport(interfaces: [WANInterfaceStatus(name: "wan", rxBytes: 26_000_000, txBytes: 3_000_000)], readAt: now.addingTimeInterval(10))
        let rated = WANAnalysis.withRates(second, previous: first)
        try expectEqual(rated.interfaces[0].rxBps, 20_000_000, "25 Mo en 10 s : 20 Mb/s")
        try expectEqual(rated.interfaces[0].txBps, 2_000_000, "montant")
        let reset = WANReadReport(interfaces: [WANInterfaceStatus(name: "wan", rxBytes: 10, txBytes: 10)], readAt: now.addingTimeInterval(20))
        try expect(WANAnalysis.withRates(reset, previous: second).interfaces[0].rxBps == nil, "compteur remis à zéro : rien")
        try expect(WANAnalysis.withRates(second, previous: nil).interfaces[0].rxBps == nil, "première lecture : rien")
        try expectEqual(WANFormat.throughput(rx: 312_400_000, tx: 48_700_000), "↓\u{00A0}312\u{00A0}Mb/s · ↑\u{00A0}48,7\u{00A0}Mb/s", "débit affiché")
        try expectEqual(WANFormat.bytes(48_204_117_830), "48,2\u{00A0}Go", "octets")
        try expectEqual(WANFormat.duration(since: now.addingTimeInterval(-(6 * 86_400 + 4 * 3600)), now: now), "6\u{00A0}j 4\u{00A0}h", "durée")
    }

    suite.add("WAN : lecture par l'API (faux transport, 6.4, 404, 403, jeton retiré)") {
        let transport = full74()
        let report = try await FortiGateReader(transport: transport, tokenForRedaction: FortiFixtures.token).readWAN(now: now)
        try expectEqual(report.system?.hostname, "FGT-SIEGE", "système")
        try expectEqual(report.interfaces.map(\.name), ["lte", "wan1", "wan2"], "liens WAN")
        try expect(report.health.count == 5 && report.healthConfig.count == 2, "SD-WAN lu")
        try expect(report.tunnels.count == 5 && report.sslUsers?.count == 2, "VPN lus")
        try expect(report.notes.isEmpty, "rien à signaler : \(report.notes)")
        try expectEqual(report.calls.count, 8, "huit appels")
        try expect(transport.requested.allSatisfy { WANPaths.all.contains($0) }, "seulement les adresses du WAN")
        try expect(transport.queries[WANPaths.interfaceConfig]?.first?.value == WANPaths.interfaceFields, "seuls les champs utiles de la configuration")

        // FortiOS 6.4 : members absent, system/sdwan absent → virtual-wan-link.
        let old = FortiFakeTransport([
            WANPaths.system: (200, WANFixtures.status74),
            WANPaths.interfaceStatus: (200, WANFixtures.interfaceStatus64),
            WANPaths.healthCheck: (200, WANFixtures.health64),
            WANPaths.sdwanConfigLegacy: (200, WANFixtures.virtualWANLink64),
            WANPaths.ipsec: (200, WANFixtures.bareIPsec),
        ])
        let r64 = try await FortiGateReader(transport: old).readWAN(now: now)
        try expect(old.requested.contains(WANPaths.sdwanConfigLegacy), "repli sur virtual-wan-link")
        try expectEqual(r64.interfaces.map(\.name), ["wan1", "wan2"], "membres SD-WAN")
        try expect(r64.notes.contains { $0.hasPrefix("Rôle des interfaces") }, "configuration absente notée")
        let ov64 = WANAnalysis.overview([WANSiteReport(controllerID: UUID(), site: "Labo", report: r64)])
        try expectEqual(ov64.links.first { $0.interface.name == "wan2" }?.state, .down, "6.4 : wan2 tombé")
        try expectEqual(ov64.sites.first?.level, .critical, "site en panne")

        // Sans SD-WAN ni VPN SSL : notes claires.
        let noSDWAN = FortiFakeTransport([
            WANPaths.system: (200, WANFixtures.status74),
            WANPaths.interfaceConfig: (200, WANFixtures.interfaceConfig74),
            WANPaths.interfaceStatus: (200, WANFixtures.interfaceStatus74),
            WANPaths.healthCheck: (200, #"{"results":{},"status":"success"}"#),
            WANPaths.ipsec: (403, #"{"status":"error","http_status":403}"#),
        ])
        let plain = try await FortiGateReader(transport: noSDWAN).readWAN(now: now)
        try expect(plain.notes.contains { $0.hasPrefix("SD-WAN non configuré") }, "SD-WAN absent expliqué")
        try expect(plain.notes.contains { $0.contains("Tunnels VPN IPsec") && $0.contains("VPN") && $0.contains("403") }, "403 des tunnels expliqué")
        try expect(!plain.tunnelsRead && plain.sslUsers == nil, "tunnels non lus, VPN SSL absent")

        // Tout refusé : l'erreur explique les droits à ajouter.
        let refused = FortiFakeTransport([
            WANPaths.system: (200, WANFixtures.status74),
            WANPaths.interfaceStatus: (403, #"{"status":"error","http_status":403}"#),
            WANPaths.healthCheck: (403, #"{"status":"error","http_status":403}"#),
            WANPaths.ipsec: (403, #"{"status":"error","http_status":403}"#),
        ])
        do {
            _ = try await FortiGateReader(transport: refused).readWAN(now: now)
            throw TestFailure(message: "403 attendu", file: #fileID, line: #line)
        } catch let error as FortiGateError {
            try expect(error.wanDescription.contains("VPN") && error.wanDescription.contains("Network"), "403 expliqué")
        }
        do {
            _ = try await FortiGateReader(transport: FortiFakeTransport([WANPaths.system: (401, "{}")])).readWAN(now: now)
            throw TestFailure(message: "401 attendu", file: #fileID, line: #line)
        } catch let error as FortiGateError {
            try expectEqual(error, .tokenRejected, "jeton refusé")
        }

        // Le jeton ne sort jamais dans les réponses brutes.
        let leaky = FortiFakeTransport([
            WANPaths.system: (200, WANFixtures.status74),
            WANPaths.interfaceStatus: (200, WANFixtures.interfaceStatus74),
            WANPaths.sdwanConfig: (200, #"{"results":{"members":[],"health-check":[{"name":"x","password":"secret123"}],"echo":"\#(FortiFixtures.token)"}}"#),
        ])
        let redacted = try await FortiGateReader(transport: leaky, tokenForRedaction: FortiFixtures.token).readWAN(now: now)
        let raw = redacted.calls.map(\.body).joined()
        try expect(!raw.contains(FortiFixtures.token) && !raw.contains("secret123"), "jeton et secret retirés")
    }

    suite.add("WAN : sondes « Tunnel VPN tombé » et « Lien WAN dégradé »") {
        let siege = try await FortiGateReader(transport: full74()).readWAN(now: now)
        let lavalReport = WANReadReport(interfaces: [WANInterfaceStatus(name: "wan", role: "wan", linkUp: true)],
                                        tunnels: [WANTunnel(name: "VPN-SIEGE", remoteGateway: "203.0.113.10", status: "up")], readAt: now)
        let siegeID = UUID(), lavalID = UUID()
        let overview = WANAnalysis.overview([WANSiteReport(controllerID: siegeID, site: "Siège", report: siege),
                                             WANSiteReport(controllerID: lavalID, site: "Entrepôt Laval", report: lavalReport)])
        try expect(overview.isMultiSite && overview.sites.count == 2, "deux sites")

        try expectEqual(MonWANChecks.tunnels("*", in: overview).count, 4, "« * » : sans le serveur d'accès distant ni ses clients")
        try expectEqual(MonWANChecks.tunnels("Siège / *", in: overview).count, 3, "« Siège / * »")
        try expectEqual(MonWANChecks.tunnels("vpn-quebec", in: overview).first?.tunnel.name, "VPN-QUEBEC", "par nom, sans casse")
        try expectEqual(MonWANChecks.tunnels("Vers Bureau Quebec", in: overview).count, 1, "par commentaire, sans accent")
        try expect(MonWANChecks.tunnels("Entrepôt Laval / VPN-QUEBEC", in: overview).isEmpty, "autre site")

        let all = MonWANChecks.tunnelDown(target: "*", overview: overview, now: now)
        try expect(!all.result.reachable && all.result.error?.hasPrefix("Tunnel VPN-QUEBEC tombé (Vers Bureau Québec, 203.0.113.30) (Siège)") == true,
                   "tunnel tombé : panne (\(all.result.error ?? ""))")
        try expectEqual(all.result.value, "2 montés sur 4", "valeur")
        let partial = MonWANChecks.tunnelDown(target: "VPN-DRUMMOND", overview: overview, now: now)
        try expect(partial.result.reachable && partial.result.problem?.contains("partiel") == true, "phase 2 manquante : alerte")
        let ok = MonWANChecks.tunnelDown(target: "VPN-LAVAL", overview: overview, now: now)
        try expect(ok.result.reachable && ok.result.problem == nil && ok.result.value == "Monté", "tunnel monté")
        let missing = MonWANChecks.tunnelDown(target: "VPN-X", overview: overview, now: now)
        try expect(missing.result.problem?.contains("VPN-X") == true, "tunnel introuvable")
        try expect(MonWANChecks.tunnelDown(target: "*", overview: nil, now: now).noData, "aucune lecture : en attente")
        let failed = MonWANChecks.tunnelDown(target: "*", overview: nil, error: "HTTP 403", now: now)
        try expect(!failed.result.reachable && failed.result.error == "HTTP 403", "erreur de lecture")

        let links = MonWANChecks.wanDegraded(target: "Siège / *", overview: overview, thresholds: .standard, now: now)
        try expect(links.result.reachable && links.result.problem?.hasPrefix("Lien WAN Vidéotron Câble (wan2) dégradé") == true,
                   "lien dégradé : alerte (\(links.result.problem ?? ""))")
        try expectEqual(links.result.value, "2 actifs sur 2 · 44\u{00A0}ms · perte 4\u{00A0}%", "valeur")
        let one = MonWANChecks.wanDegraded(target: "Bell Fibre", overview: overview, thresholds: .standard, now: now)
        try expect(one.result.problem == nil && one.result.value.hasPrefix("Actif"), "par alias : wan1 bon")
        let wide = MonWANChecks.wanDegraded(target: "wan2", overview: WANAnalysis.overview([WANSiteReport(controllerID: siegeID, site: "Siège",
            report: WANReadReport(interfaces: siege.interfaces, health: siege.health, readAt: now))]),
                                            thresholds: WANThresholds(latencyMs: 500, jitterMs: 100, lossPercent: 10), now: now)
        try expect(wide.result.problem == nil, "seuils de la sonde appliqués")
        var down = siege
        down.interfaces = down.interfaces.map { var i = $0; if i.name == "wan1" { i.linkUp = false }; return i }
        let fallen = MonWANChecks.wanDegraded(target: "*", overview: WANAnalysis.overview([WANSiteReport(controllerID: siegeID, site: "Siège", report: down)]),
                                              thresholds: .standard, now: now)
        try expect(!fallen.result.reachable && fallen.result.error?.contains("Bell Fibre (wan1) tombé") == true, "lien tombé : panne")

        var probe = MonProbe(name: "WAN", kind: .wanLink, target: "*")
        probe.wanThresholds = WANThresholds(latencyMs: 80, jitterMs: 20, lossPercent: 1)
        probe.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil)
        let decoded = try JSONDecoder().decode(MonProbe.self, from: try JSONEncoder().encode(probe))
        try expectEqual(decoded.wanThresholds, probe.wanThresholds, "seuils enregistrés avec la sonde")
        try expect(decoded.conditionSummary.contains("80\u{00A0}ms") && decoded.conditionSummary.contains("1\u{00A0}%"), "résumé : \(decoded.conditionSummary)")
        var context = MonRunContext(pinger: nil, snmpCommunity: nil, devices: [], now: now)
        context.wan = overview
        let run = await MonRunner.run(decoded, context: context)
        try expect(run.result.problem?.contains("wan2") == true, "exécutée par MonRunner")
        let step = MonStateMachine.evaluate(probe: decoded, tracker: MonTracker(), result: run.result, dependencyDown: false)
        try expectEqual(step.tracker.state, .warning, "sonde en alerte")
        let tunnelProbe = MonProbe(name: "VPN", kind: .vpnTunnel, target: "*")
        let tunnelRun = await MonRunner.run(tunnelProbe, context: context)
        try expect(!tunnelRun.result.reachable, "tunnel tombé : échec compté vers la panne")
        let nav = NavResolver.primary(.probe(NavProbeRef(tunnelProbe)), in: NavContext(activeSiteKey: "x"))
        try expectEqual(nav.destination, NavDestination(.outils, focus: .tool("wan")), "double-clic : l'outil WAN et VPN")
        let legacyProbe = try JSONDecoder().decode(MonProbe.self, from: Data(#"{"id":"\#(UUID().uuidString)","kind":"wanLink","wanThresholds":{"lossPercent":5}}"#.utf8))
        try expectEqual(legacyProbe.wanThresholds?.lossPercent, 5, "seuil partiel lu")
        try expectEqual(legacyProbe.wanThresholds?.latencyMs, 150, "seuil manquant : valeur par défaut")
    }

    suite.add("WAN : vue de tous les sites et section facultative du rapport") {
        let siege = try await FortiGateReader(transport: full74()).readWAN(now: now)
        var laval = WANReadReport(interfaces: [WANInterfaceStatus(name: "wan", role: "wan", linkUp: true)],
                                  tunnels: [WANTunnel(name: "VPN-SIEGE", status: "up")], readAt: now)
        laval.notes = ["SD-WAN non configuré."]
        let overview = WANAnalysis.overview([WANSiteReport(controllerID: UUID(), site: "Siège", report: siege),
                                             WANSiteReport(controllerID: UUID(), site: "Entrepôt Laval", report: laval)])
        let s = try overview.sites.first { $0.site == "Siège" }.unwrapWAN("Siège")
        try expect(s.linksUp == 2 && s.linksTotal == 2, "lien désactivé non compté : \(s.linksUp)/\(s.linksTotal)")
        try expect(s.tunnelsUp == 2 && s.tunnelsTotal == 4, "tunnels : \(s.tunnelsUp)/\(s.tunnelsTotal)")
        try expectEqual(s.level, .critical, "Siège en panne (tunnel tombé)")
        try expectEqual(overview.sites.first { $0.site == "Entrepôt Laval" }?.level, .ok, "Laval bon")
        try expect(overview.notes == ["Entrepôt Laval\u{00A0}: SD-WAN non configuré."], "remarques préfixées du site")
        try expectEqual(overview.alertingTunnels.first?.tunnel.name, "VPN-QUEBEC", "le tunnel tombé d'abord")
        try expectEqual(overview.alertingLinks.first?.interface.name, "wan2", "lien dégradé")

        var input = ReportInput(devices: [], now: now)
        input.wan = overview
        let config = ReportConfig(template: .audit, sections: [.resume, .wan])
        let doc = ReportBuilder.build(config: config, input: input)
        let section = try doc.sections.first { $0.kind == .wan }.unwrapWAN("section présente")
        try expectEqual(section.heading, "2. WAN et VPN", "après le résumé")
        try expectEqual(section.tables.count, 3, "liens, tunnels, constats")
        try expectEqual(section.tables.first?.rows.count, 4, "une ligne par lien WAN (lte désactivé compris)")
        try expect(section.tables.first?.columns.contains { $0.title == "Site" } == true, "colonne Site en multisite")
        try expect(section.tables[2].rows.first?.cells[1].text.hasPrefix("Tunnel VPN-QUEBEC tombé") == true, "constat du tunnel d'abord")
        try expect(!ReportTemplate.allCases.contains { $0.defaultSections.contains(.wan) }, "facultative : aucun modèle ne la coche")
        let none = ReportBuilder.build(config: config, input: ReportInput(devices: [], now: now)).sections.first { $0.kind == .wan }
        if case .note? = none?.blocks.first {} else { throw TestFailure(message: "note sans lecture", file: #fileID, line: #line) }
    }
}

private extension Optional {
    func unwrapWAN(_ message: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
        return value
    }
}
