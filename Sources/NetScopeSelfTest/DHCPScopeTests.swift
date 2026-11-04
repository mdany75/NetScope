import Foundation
import NetScopeCore

// Note 37 : occupation des étendues DHCP. Réponses JSON fixes de cmdb system.dhcp/server et de
// monitor/system/dhcp en variantes de versions, calculs (exclusions, réservations hors plage,
// plusieurs plages, passerelle dans la plage), seuils, estimation sans FortiGate, lecture par un
// faux transport (404, 403), sonde de la Surveillance et section de rapport. Aucun réseau.

enum DHCPScopeFixtures {
    /// FortiOS 7.4 : enveloppe « results », noms en « - », listes d'objets.
    static let servers74 = """
    {"http_method":"GET","results":[
      {"id":1,"q_origin_key":1,"status":"enable","lease-time":604800,"server-type":"regular","interface":"internal",
       "default-gateway":"10.182.122.1","netmask":"255.255.255.0","ip-mode":"range",
       "ip-range":[{"id":1,"q_origin_key":1,"start-ip":"10.182.122.100","end-ip":"10.182.122.199"}],
       "exclude-range":[{"id":1,"start-ip":"10.182.122.120","end-ip":"10.182.122.129"}],
       "reserved-address":[
         {"id":1,"type":"mac","ip":"10.182.122.111","mac":"94:dd:f8:18:15:7d","action":"reserved","description":"Imprimante accueil"},
         {"id":2,"type":"mac","ip":"10.182.122.20","mac":"00:1b:c5:0a:12:f3","action":"reserved","description":"Horloge"},
         {"id":3,"type":"mac","ip":"0.0.0.0","mac":"de:ad:be:ef:00:01","action":"block"}]},
      {"id":2,"q_origin_key":2,"status":"enable","lease-time":86400,"interface":"vlan20","default-gateway":"10.182.120.1",
       "netmask":"255.255.255.0","ip-range":[{"id":1,"start-ip":"10.182.120.100","end-ip":"10.182.120.149"},
                                                {"id":2,"start-ip":"10.182.120.200","end-ip":"10.182.120.249"}],
       "exclude-range":[],"reserved-address":[]},
      {"id":3,"status":"disable","interface":"vlan100","ip-range":[{"start-ip":"10.10.0.100","end-ip":"10.10.0.150"}]}
    ],"vdom":"root","path":"system.dhcp","name":"server","status":"success","http_status":200,"version":"v7.4.4","build":2662}
    """

    /// FortiOS 6.4 : dictionnaire indexé par identifiant, noms en « _ », valeurs en texte.
    static let servers64 = """
    {"results":{"7":{"status":"enable","lease_time":"28800","interface":"vlan30","default_gateway":"10.182.130.1",
                     "netmask":"255.255.255.0","ip_range":[{"start_ip":"10.182.130.50","end_ip":"10.182.130.149"}],
                     "reserved_address":[{"ip":"10.182.130.60","mac":"00-07-4D-11-22-33","action":"assign"}]}},
     "status":"success","version":"v6.4.15"}
    """

    /// Vieille forme sans enveloppe : plage seule sur le serveur, champs absents.
    static let bareServers = """
    [{"interface":"lan","start-ip":"192.168.1.200","end-ip":"192.168.1.100"},{"status":"enable"}]
    """

    static let leases74 = """
    {"http_method":"GET","results":[
      {"ip":"10.182.122.100","mac":"3a:1f:c7:02:9b:e4","hostname":"inconnu","expire_time":1793710000,"interface":"internal","server_mkey":1,"type":"ipv4","status":"leased"},
      {"ip":"10.182.122.111","mac":"94:dd:f8:18:15:7d","hostname":"BRN94DDF818157D","expire_time":1793790000,"interface":"internal","server_mkey":1,"reserved":true,"type":"ipv4"},
      {"ip":"10.182.122.125","mac":"aa:aa:aa:00:00:01","expire_time":1793780000,"interface":"internal","server_mkey":1,"type":"ipv4"},
      {"ip":"10.182.122.146","mac":"b0:7b:25:44:9f:20","hostname":"WKS341","expire_time":1793690000,"interface":"internal","server_mkey":1,"status":"expired"},
      {"ip":"10.182.122.150","mac":"aa:aa:aa:00:00:02","expire_time":1793701200,"interface":"internal","type":"ipv4"},
      {"ip":"10.182.122.150","mac":"aa:aa:aa:00:00:02","expire_time":1793701200,"interface":"internal","type":"ipv4"},
      {"ip":"10.182.120.101","mac":"80:5e:0c:00:00:01","hostname":"Yealink","expire_time":1793780000,"server_mkey":2},
      {"ip":"10.182.120.220","mac":"80:5e:0c:00:00:02","expire_time":1793780000},
      {"ip":"fe80::1","mac":"80:5e:0c:00:00:03","type":"ipv6","server_mkey":2}
    ],"status":"success"}
    """

    /// FortiOS 6.4 : baux regroupés par interface, temps restant en secondes.
    static let leases64 = """
    {"results":{"vlan30":[{"ip":"10.182.130.51","mac":"00:07:4d:aa:bb:01","expire_time":"600"},
                          {"ip":"10.182.130.60","mac":"00:07:4d:11:22:33","expire_time":"86000","reserved":"true"}]}}
    """

    static let interfaces74 = """
    {"results":[{"name":"internal","vlanid":0,"alias":"Bureau"},{"name":"vlan20","vlanid":20,"alias":"Voix","interface":"internal"},
                {"name":"vlan100","vlanid":100}],"status":"success"}
    """
}

func registerDHCPScopeTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_700_000)
    func data(_ s: String) -> Data { Data(s.utf8) }
    func ip(_ s: String) -> IPv4Address { IPv4Address(s)! }
    func range(_ a: String, _ b: String) -> DHCPAddressRange { DHCPAddressRange(start: ip(a), end: ip(b)) }

    suite.add("Étendues DHCP : configuration cmdb system.dhcp/server (7.4, 6.4, forme nue)") {
        let servers = try DHCPScopeParsers.servers(data(DHCPScopeFixtures.servers74)).unwrapDHCP("7.4")
        try expectEqual(servers.count, 3, "trois serveurs")
        let bureau = servers[0]
        try expectEqual(bureau.id, 1, "identifiant")
        try expectEqual(bureau.interface, "internal", "interface")
        try expectEqual(bureau.ranges, [range("10.182.122.100", "10.182.122.199")], "plage")
        try expectEqual(bureau.exclusions, [range("10.182.122.120", "10.182.122.129")], "exclusion")
        try expectEqual(bureau.reservations.count, 2, "la réservation « block » à 0.0.0.0 est ignorée (adresse nulle)")
        try expectEqual(bureau.leaseTime, 604_800, "bail")
        try expectEqual(bureau.gateway, ip("10.182.122.1"), "passerelle")
        try expectEqual(servers[1].ranges.count, 2, "deux plages")
        try expect(!servers[2].enabled, "serveur désactivé")

        let old = try DHCPScopeParsers.servers(data(DHCPScopeFixtures.servers64)).unwrapDHCP("6.4")
        try expectEqual(old.count, 1, "un serveur")
        try expectEqual(old[0].id, 7, "identifiant tiré de la clé du dictionnaire")
        try expectEqual(old[0].leaseTime, 28_800, "bail en texte")
        try expectEqual(old[0].ranges, [range("10.182.130.50", "10.182.130.149")], "ip_range")
        try expectEqual(old[0].reservations.first?.mac, MACAddress("00:07:4D:11:22:33"), "MAC avec tirets")

        let bare = try DHCPScopeParsers.servers(data(DHCPScopeFixtures.bareServers)).unwrapDHCP("nue")
        try expectEqual(bare.count, 1, "serveur sans interface écarté")
        try expectEqual(bare[0].ranges, [range("192.168.1.100", "192.168.1.200")], "plage seule, bornes remises dans l'ordre")
        try expect(DHCPScopeParsers.servers(data("pas du json")) == nil, "corps illisible")

        // Identifiants en double (id explicite et id absent, ou deux VDOM) : rendus uniques, pas de plantage.
        let dup = try DHCPScopeParsers.servers(data("""
        [{"id":2,"interface":"lan","ip-range":[{"start-ip":"10.0.0.10","end-ip":"10.0.0.20"}]},
         {"interface":"dmz","ip-range":[{"start-ip":"10.0.1.10","end-ip":"10.0.1.20"}]},
         {"id":2,"interface":"wan2","ip-range":[{"start-ip":"10.0.2.10","end-ip":"10.0.2.20"}]}]
        """)).unwrapDHCP("doublons")
        try expectEqual(dup.count, 3, "trois serveurs")
        try expectEqual(Set(dup.map(\.id)).count, 3, "identifiants uniques")
        try expectEqual(dup[0].id, 2, "le premier garde son identifiant")
        let same = [DHCPServerConfig(id: 5, interface: "a", ranges: [range("10.0.0.10", "10.0.0.20")]),
                    DHCPServerConfig(id: 5, interface: "b", ranges: [range("10.0.1.10", "10.0.1.20")])]
        let dupScopes = DHCPScopeAnalysis.usages(site: "Site", report: DHCPScopeReadReport(servers: same, leases: [], interfaces: [:], readAt: now), now: now)
        try expectEqual(dupScopes.count, 2, "deux serveurs de même id analysés sans plantage")

        // Réservation hors plage recopiée : une seule ligne, comptée une fois.
        let mac = MACAddress("00:11:22:33:44:55")
        let copied = DHCPServerConfig(id: 1, interface: "lan", ranges: [range("10.0.0.100", "10.0.0.150")],
                                      reservations: [DHCPReservation(ip: ip("10.0.0.20"), mac: mac, description: nil, action: "reserved"),
                                                     DHCPReservation(ip: ip("10.0.0.20"), mac: mac, description: nil, action: "reserved")])
        let copiedUsage = DHCPScopeAnalysis.usage(copied, site: "Site", leases: [], vlan: nil, alias: nil, now: now)
        try expectEqual(copiedUsage.reservationsOutside, 1, "réservation hors plage dédoublonnée")
        try expectEqual(Set(copiedUsage.entries.map(\.id)).count, copiedUsage.entries.count, "identifiants de lignes uniques")
    }

    suite.add("Étendues DHCP : baux (server_mkey, expirés, IPv6, temps restant) et VLAN des interfaces") {
        let leases = try DHCPScopeParsers.leases(data(DHCPScopeFixtures.leases74), now: now).unwrapDHCP("baux 7.4")
        try expectEqual(leases.count, 8, "IPv6 écarté")
        try expectEqual(leases[0].serverID, 1, "server_mkey")
        try expect(leases[1].reserved, "réservé")
        try expect(!leases[3].isActive(at: now), "bail expiré")
        try expect(leases[0].isActive(at: now), "bail actif")
        let old = try DHCPScopeParsers.leases(data(DHCPScopeFixtures.leases64), now: now).unwrapDHCP("baux 6.4")
        try expectEqual(old.count, 2, "baux par interface")
        try expectEqual(old[0].interface, "vlan30", "interface tirée de la clé")
        try expectEqual(old[0].expires, now.addingTimeInterval(600), "temps restant en secondes")
        try expect(old[1].reserved, "« true » en texte")
        let interfaces = try DHCPScopeParsers.interfaces(data(DHCPScopeFixtures.interfaces74)).unwrapDHCP("interfaces")
        try expectEqual(interfaces["vlan20"]?.vlan, 20, "VLAN 20")
        try expectEqual(interfaces["internal"]?.vlan, nil, "vlanid 0 : pas un VLAN")
        try expectEqual(interfaces["internal"]?.alias, "Bureau", "alias")
    }

    suite.add("Étendues DHCP : ensemble d'adresses (fusion, exclusions, passerelle)") {
        var pool = DHCPAddressPool([range("10.0.0.10", "10.0.0.20"), range("10.0.0.15", "10.0.0.30"), range("10.0.0.31", "10.0.0.40"),
                                    range("10.0.0.100", "10.0.0.109")])
        try expectEqual(pool.intervals.count, 2, "plages qui se chevauchent ou se touchent fusionnées")
        try expectEqual(pool.count, 41, "31 + 10 adresses")
        pool.subtract(range("10.0.0.20", "10.0.0.24"))
        try expectEqual(pool.count, 36, "exclusion au milieu")
        try expect(!pool.contains(ip("10.0.0.22")) && pool.contains(ip("10.0.0.25")) && pool.contains(ip("10.0.0.19")), "bornes de l'exclusion")
        pool.subtract(range("10.0.0.0", "10.0.0.12"))
        try expectEqual(pool.count, 33, "exclusion qui déborde au début")
        pool.subtract(range("10.0.0.105", "10.0.0.200"))
        try expectEqual(pool.count, 28, "exclusion qui déborde à la fin")
        let server = DHCPServerConfig(id: 1, interface: "lan", ranges: [range("192.168.1.1", "192.168.1.100")], gateway: ip("192.168.1.1"))
        try expectEqual(DHCPScopeAnalysis.pool(of: server).count, 99, "passerelle dans la plage retirée")
        let wide = DHCPAddressPool([range("10.0.0.0", "10.255.255.255")])
        try expectEqual(wide.count, 16_777_216, "grande plage comptée sans énumération")
    }

    suite.add("Étendues DHCP : occupation (réservations dans et hors plage, exclusions, plusieurs plages, doublons)") {
        let report = DHCPScopeReadReport(servers: try DHCPScopeParsers.servers(data(DHCPScopeFixtures.servers74)).unwrapDHCP("serveurs"),
                                         leases: try DHCPScopeParsers.leases(data(DHCPScopeFixtures.leases74), now: now).unwrapDHCP("baux"),
                                         interfaces: try DHCPScopeParsers.interfaces(data(DHCPScopeFixtures.interfaces74)).unwrapDHCP("intf"),
                                         readAt: now)
        let scopes = DHCPScopeAnalysis.usages(site: "Siège", report: report, now: now)
        try expectEqual(scopes.count, 3, "trois étendues")
        let bureau = try scopes.first { $0.interface == "internal" }.unwrapDHCP("bureau")
        try expectEqual(bureau.poolSize, 90, "100 adresses moins 10 exclues")
        try expectEqual(bureau.reservationsInPool, 1, "la réservation .20 est hors plage")
        try expectEqual(bureau.reservationsOutside, 1, "une réservation hors plage")
        try expectEqual(bureau.reservationsInUse, 1, "imprimante avec un bail")
        // .100 (bail), .111 (réservation), .150 (doublon compté une fois) ; .125 est exclue, .146 expirée.
        try expectEqual(bureau.activeLeases, 2, "baux dynamiques dans la plage")
        try expectEqual(bureau.outsideLeases, 1, "le bail .125 tombe dans l'exclusion")
        try expectEqual(bureau.used, 3, "adresses utilisées")
        try expectEqual(bureau.free, 87, "adresses libres")
        try expectEqual(bureau.expiringSoon, 1, ".150 expire dans 20 min")
        try expectEqual(bureau.alias, "Bureau", "alias de l'interface")
        try expectEqual(bureau.vlan, nil, "pas de VLAN")
        try expect(bureau.entries.contains { $0.kind == .reservationOutside && $0.ip == ip("10.182.122.20") }, "réservation hors plage montrée")
        try expect(!bureau.entries.contains { $0.ip == ip("10.182.122.146") }, "bail expiré absent")
        try expectEqual(bureau.level, .ok, "sous les seuils")

        let voix = try scopes.first { $0.interface == "vlan20" }.unwrapDHCP("voix")
        try expectEqual(voix.poolSize, 100, "deux plages de 50")
        try expectEqual(voix.vlan, 20, "VLAN lu sur l'interface")
        try expectEqual(voix.used, 2, "bail par server_mkey et bail rattaché par son adresse")
        try expectEqual(voix.displayName, "VLAN 20 · Voix", "nom affiché")
        let serveurs = try scopes.first { $0.interface == "vlan100" }.unwrapDHCP("serveurs")
        try expectEqual(serveurs.level, .inactive, "désactivée")
        try expectEqual(serveurs.vlan, 100, "VLAN 100")

        // Baux non lus (403) : seules les réservations comptent, et c'est dit.
        var noLeases = report
        noLeases.leases = []
        noLeases.leasesRead = false
        let partial = DHCPScopeAnalysis.usages(site: "Siège", report: noLeases, now: now).first { $0.interface == "internal" }
        try expectEqual(partial?.used, 1, "la réservation de la plage reste comptée")
        try expect(partial?.leasesUnknown == true && partial?.notes.first?.contains("Baux non lus") == true, "baux non lus signalés")
    }

    suite.add("Étendues DHCP : seuils, niveaux et alerte en clair") {
        func scope(used: Int, pool: Int = 100, enabled: Bool = true) -> DHCPScopeUsage {
            var leases: [DHCPLeaseEntry] = []
            for n in 0..<used {
                leases.append(DHCPLeaseEntry(ip: IPv4Address(ip("10.182.120.100").value + UInt32(n)), expires: now.addingTimeInterval(86_000)))
            }
            let server = DHCPServerConfig(id: 2, interface: "vlan20", enabled: enabled,
                                          ranges: [DHCPAddressRange(start: ip("10.182.120.100"), end: IPv4Address(ip("10.182.120.100").value + UInt32(pool - 1)))])
            return DHCPScopeAnalysis.usage(server, site: "Siège", leases: leases, vlan: 20, alias: "Voix", now: now)
        }
        try expectEqual(scope(used: 79).level, .ok, "79 %")
        try expectEqual(scope(used: 80).level, .warning, "80 % : avertissement")
        try expectEqual(scope(used: 94).level, .warning, "94 %")
        try expectEqual(scope(used: 95).level, .critical, "95 % : critique")
        try expectEqual(scope(used: 100).level, .critical, "pleine")
        try expectEqual(scope(used: 3, pool: 3).level, .critical, "petite étendue sans adresse libre : critique")
        try expectEqual(scope(used: 0, enabled: false).level, .inactive, "désactivée")
        let full96 = scope(used: 96)
        try expectEqual(DHCPScopeAnalysis.alertText(full96),
                        "Étendue VLAN 20 pleine à 96\u{00A0}%\u{00A0}: 4 adresses libres\u{00A0}; des postes risquent de tomber en 169.254", "alerte critique")
        try expectEqual(DHCPScopeAnalysis.alertText(scope(used: 85)), "Étendue VLAN 20 occupée à 85\u{00A0}%\u{00A0}: 15 adresses libres sur 100", "alerte d'avertissement")
        try expect(DHCPScopeAnalysis.alertText(scope(used: 100))?.contains("plus aucune adresse libre") == true, "pleine")
        try expect(DHCPScopeAnalysis.alertText(scope(used: 50)) == nil, "rien sous les seuils")
        try expectEqual(scope(used: 99, pool: 100).percentLabel, "99\u{00A0}%", "jamais « 100 % » s'il reste une adresse")
        try expect(DHCPScopeAnalysis.advice(full96).contains("grandir la plage"), "conseil")

        let strict = DHCPScopeThresholds(warningPercent: 60, criticalPercent: 70)
        try expectEqual(DHCPScopeAnalysis.relevel([scope(used: 65)], thresholds: strict).first?.level, .warning, "seuils réglables")
        let clamped = DHCPScopeThresholds(warningPercent: 90, criticalPercent: 50)
        try expectEqual(clamped.criticalPercent, 90, "critique jamais sous l'avertissement")
        let decoded = try JSONDecoder().decode(DHCPScopeThresholds.self, from: data(#"{"warningPercent":70}"#))
        try expectEqual(decoded, DHCPScopeThresholds(warningPercent: 70, criticalPercent: 95, expiringMinutes: 60), "lecture tolérante")
    }

    suite.add("Étendues DHCP : estimation sans FortiGate (Test DHCP et scan)") {
        var offer = DHCPOffer(messageType: .offer, xid: 1, flagsBroadcast: true, offeredAddress: ip("192.168.1.57"))
        offer.serverIdentifier = ip("192.168.1.1")
        offer.subnetMask = ip("255.255.255.192")
        offer.routers = [ip("192.168.1.1")]
        offer.leaseTime = 86_400
        var devices: [Device] = []
        for n in 2...59 { devices.append(Device(ip: ip("192.168.1.\(n)"), isOnline: n != 59)) }
        devices.append(Device(ip: ip("10.0.0.5"), isOnline: true))
        let scopes = DHCPScopeAnalysis.estimate(offers: [offer, offer], devices: devices, site: "Bureau Québec", now: now)
        try expectEqual(scopes.count, 1, "un sous-réseau, offre en double ignorée")
        let s = scopes[0]
        try expect(s.isEstimate, "marquée estimation")
        try expectEqual(s.poolSize, 61, "62 hôtes du /26 moins la passerelle-serveur")
        try expectEqual(s.used, 57, "appareils en ligne du sous-réseau (le .59 est hors ligne, 10.0.0.5 ailleurs)")
        try expectEqual(s.level, .warning, "93 % : avertissement")
        try expect(DHCPScopeAnalysis.alertText(s)?.contains("(estimation)") == true, "l'alerte dit « estimation »")
        try expect(s.notes.first?.hasPrefix("Estimation sans FortiGate") == true, "remarque d'estimation")
        let overview = DHCPScopeAnalysis.estimatedOverview(offers: [offer], devices: devices, now: now)
        try expect(overview.isEstimate && overview.readAt != nil, "ensemble estimé")
        try expect(DHCPScopeAnalysis.estimate(offers: [], devices: devices).isEmpty, "rien sans Test DHCP")
    }

    suite.add("Étendues DHCP : lecture par l'API (faux transport, 404, 403, baux refusés)") {
        let full = FortiFakeTransport([
            DHCPScopePaths.servers: (200, DHCPScopeFixtures.servers74),
            DHCPScopePaths.leases: (200, DHCPScopeFixtures.leases74),
            DHCPScopePaths.interfaces: (200, DHCPScopeFixtures.interfaces74),
        ])
        let report = try await FortiGateReader(transport: full).readDHCPScopes(now: now)
        try expectEqual(report.servers.count, 3, "serveurs lus")
        try expectEqual(report.leases.count, 8, "baux lus")
        try expectEqual(report.interfaces["vlan20"]?.vlan, 20, "interfaces lues")
        try expectEqual(report.calls.count, 3, "trois appels")
        try expect(full.queries[DHCPScopePaths.interfaces]?.first?.value == DHCPScopePaths.interfaceFields, "seuls nom, VLAN et alias demandés")
        try expect(full.requested.allSatisfy { DHCPScopePaths.all.contains($0) }, "aucune autre adresse")

        let missing = try await FortiGateReader(transport: FortiFakeTransport([:])).readDHCPScopes(now: now)
        try expect(!missing.available && missing.notes.first?.contains("HTTP 404") == true, "404 expliqué")

        let refused = FortiFakeTransport([DHCPScopePaths.servers: (403, #"{"status":"error","http_status":403}"#)])
        do {
            _ = try await FortiGateReader(transport: refused).readDHCPScopes(now: now)
            throw TestFailure(message: "403 attendu", file: #fileID, line: #line)
        } catch let error as FortiGateError {
            try expect(error.dhcpScopeDescription.contains("Network"), "403 expliqué : droit à ajouter")
        }

        let partial = FortiFakeTransport([DHCPScopePaths.servers: (200, DHCPScopeFixtures.servers64),
                                          DHCPScopePaths.leases: (403, #"{"status":"error","http_status":403}"#)])
        let noLeases = try await FortiGateReader(transport: partial).readDHCPScopes(now: now)
        try expect(!noLeases.leasesRead, "baux refusés")
        try expect(noLeases.notes.contains { $0.contains("Baux DHCP") && $0.contains("403") }, "403 des baux expliqué")
        try expect(noLeases.notes.contains { $0.contains("VLAN des interfaces") }, "interfaces absentes notées")
        let scopes = DHCPScopeAnalysis.usages(site: "Siège", report: noLeases, now: now)
        try expectEqual(scopes.first?.vlan, 30, "VLAN déduit du nom de l'interface")
        try expectEqual(scopes.first?.used, 1, "réservation seule comptée")
    }

    suite.add("Étendues DHCP : sonde « Étendue DHCP presque pleine »") {
        func server(_ id: Int, _ intf: String, _ start: String, count: Int) -> DHCPServerConfig {
            DHCPServerConfig(id: id, interface: intf, ranges: [DHCPAddressRange(start: ip(start), end: IPv4Address(ip(start).value + UInt32(count - 1)))])
        }
        func leases(_ id: Int, _ start: String, _ n: Int) -> [DHCPLeaseEntry] {
            (0..<n).map { DHCPLeaseEntry(ip: IPv4Address(ip(start).value + UInt32($0)), serverID: id) }
        }
        let report = DHCPScopeReadReport(servers: [server(1, "internal", "10.0.0.100", count: 100), server(2, "vlan20", "10.0.20.100", count: 100),
                                                   server(3, "vlan60", "10.0.60.20", count: 200)],
                                         leases: leases(1, "10.0.0.100", 40) + leases(2, "10.0.20.100", 96) + leases(3, "10.0.60.20", 170),
                                         interfaces: ["vlan60": DHCPInterfaceInfo(vlan: 60, alias: "Invités")], readAt: now)
        let overview = DHCPScopeAnalysis.overview([DHCPScopeSiteReport(controllerID: UUID(), site: "Siège", report: report)], now: now)
        try expectEqual(MonDHCPScopeChecks.targets("*", in: overview).count, 3, "toutes")
        try expectEqual(MonDHCPScopeChecks.targets("vlan20", in: overview).first?.vlan, 20, "par interface")
        try expectEqual(MonDHCPScopeChecks.targets("VLAN 20", in: overview).count, 1, "par VLAN")
        try expectEqual(MonDHCPScopeChecks.targets("invites", in: overview).first?.interface, "vlan60", "par alias, sans accent")
        try expectEqual(MonDHCPScopeChecks.targets("Siège / vlan60", in: overview).count, 1, "avec le site")
        try expect(MonDHCPScopeChecks.targets("Entrepôt / vlan60", in: overview).isEmpty, "autre site")

        let all = MonDHCPScopeChecks.check(target: "*", overview: overview, thresholds: .standard, now: now)
        try expectEqual(all.result.problem, "Étendue VLAN 20 pleine à 96\u{00A0}%\u{00A0}: 4 adresses libres\u{00A0}; des postes risquent de tomber en 169.254 (et 1 autre)", "la plus pleine d'abord")
        try expect(all.result.reachable && !all.noData, "alerte, pas une panne")
        let one = MonDHCPScopeChecks.check(target: "internal", overview: overview, thresholds: .standard, now: now)
        try expect(one.result.problem == nil && one.result.value == "40\u{00A0}% · 60 libres sur 100", "étendue sous les seuils : \(one.result.value)")
        let strict = MonDHCPScopeChecks.check(target: "internal", overview: overview, thresholds: DHCPScopeThresholds(warningPercent: 30), now: now)
        try expect(strict.result.problem?.contains("occupée à 40") == true, "seuils de la sonde")
        let unknown = MonDHCPScopeChecks.check(target: "vlan99", overview: overview, thresholds: .standard, now: now)
        try expect(unknown.result.problem?.contains("vlan99") == true, "étendue introuvable")
        try expect(MonDHCPScopeChecks.check(target: "*", overview: nil, thresholds: .standard, now: now).noData, "aucune lecture : en attente")
        let failed = MonDHCPScopeChecks.check(target: "*", overview: nil, error: "HTTP 403", thresholds: .standard, now: now)
        try expect(!failed.result.reachable && failed.result.error == "HTTP 403", "erreur de lecture signalée")

        var probe = MonProbe(name: "DHCP", kind: .dhcpScope, target: "*")
        probe.dhcpThresholds = DHCPScopeThresholds(warningPercent: 70, criticalPercent: 90)
        probe.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil)
        let decoded = try JSONDecoder().decode(MonProbe.self, from: try JSONEncoder().encode(probe))
        try expectEqual(decoded.dhcpThresholds, probe.dhcpThresholds, "seuils enregistrés avec la sonde")
        try expect(decoded.conditionSummary.contains("70") && decoded.conditionSummary.contains("90"), "résumé de la condition")
        var context = MonRunContext(pinger: nil, snmpCommunity: nil, devices: [], now: now)
        context.dhcpScopes = overview
        let run = await MonRunner.run(decoded, context: context)
        try expect(run.result.problem?.contains("VLAN 20") == true, "exécutée par MonRunner")
        let step = MonStateMachine.evaluate(probe: decoded, tracker: MonTracker(), result: run.result, dependencyDown: false)
        try expectEqual(step.tracker.state, .warning, "sonde en alerte")
        try expect(step.events.first?.message.contains("169.254") == true, "message de l'alerte")

        let nav = NavResolver.primary(.probe(NavProbeRef(decoded)), in: NavContext(activeSiteKey: "x"))
        try expectEqual(nav.destination, NavDestination(.outils, focus: .tool("dhcpscopes")), "double-clic : l'outil")
    }

    suite.add("Étendues DHCP : section facultative du rapport") {
        let report = DHCPScopeReadReport(servers: try DHCPScopeParsers.servers(data(DHCPScopeFixtures.servers74)).unwrapDHCP("serveurs"),
                                         leases: try DHCPScopeParsers.leases(data(DHCPScopeFixtures.leases74), now: now).unwrapDHCP("baux"),
                                         readAt: now)
        var input = ReportInput(devices: [], now: now)
        input.dhcpScopes = DHCPScopeAnalysis.overview([DHCPScopeSiteReport(controllerID: UUID(), site: "Siège", report: report)], now: now)
        // Seuils bas : le Bureau (3 %) passe en alerte, pour vérifier le tableau des constats.
        input.dhcpThresholds = DHCPScopeThresholds(warningPercent: 2, criticalPercent: 50)
        let config = ReportConfig(template: .audit, sections: [.resume, .dhcp])
        let doc = ReportBuilder.build(config: config, input: input)
        let section = try doc.sections.first { $0.kind == .dhcp }.unwrapDHCP("section présente")
        try expectEqual(section.heading, "2. Étendues DHCP", "après le résumé")
        try expectEqual(section.tables.first?.rows.count, 3, "une ligne par étendue")
        try expect(section.tables.first?.rows.first?.cells.contains { $0.bar != nil } == true, "jauge du taux")
        try expect(section.tables.count == 2 && section.tables[1].rows.first?.cells[1].text.contains("Étendue") == true, "constats et conseils")
        try expect(!ReportTemplate.allCases.contains { $0.defaultSections.contains(.dhcp) }, "facultative : aucun modèle ne la coche")
        let none = ReportBuilder.build(config: config, input: ReportInput(devices: [], now: now)).sections.first { $0.kind == .dhcp }
        if case .note? = none?.blocks.first {} else { throw TestFailure(message: "note sans lecture", file: #fileID, line: #line) }
    }
}

private extension Optional {
    func unwrapDHCP(_ message: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
        return value
    }
}
