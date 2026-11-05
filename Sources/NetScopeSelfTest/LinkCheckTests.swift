import Foundation
import NetScopeCore

// Note 58 : bilan de raccordement. Tout est vérifié sans réseau : sondes simulées (mesures fixes),
// enchaînement des étapes, verdicts, comparaison avant/après, historique, section du rapport.

/// Sondes simulées : mesures fixes, journal des appels.
private final class FakeLinkProbes: LinkCheckProbing, @unchecked Sendable {
    let lock = NSLock()
    var calls: [String] = []
    var linkValue: LinkCheckLink?
    var neighborValue: LinkCheckNeighborMeasure
    var offers: [DHCPOffer]
    var rtts: [Double?]
    var dnsAnswers: [LinkCheckDNSAnswer]
    var internetValue: LinkCheckInternetMeasure?

    init(link: LinkCheckLink?, neighbor: NetworkNeighbor? = linkCheckNeighbor(), offers: [DHCPOffer] = [linkCheckOffer()],
         rtts: [Double?] = Array(repeating: 0.8, count: 10),
         dns: [LinkCheckDNSAnswer] = [LinkCheckDNSAnswer(name: "microsoft.com", milliseconds: 18, addresses: ["20.70.246.20"]),
                                      LinkCheckDNSAnswer(name: "google.com", milliseconds: 12, addresses: ["142.250.65.78"])],
         internet: LinkCheckInternetMeasure? = nil) {
        linkValue = link
        neighborValue = LinkCheckNeighborMeasure(neighbor: neighbor, listenedSeconds: 31)
        self.offers = offers
        self.rtts = rtts
        dnsAnswers = dns
        internetValue = internet
    }

    private func note(_ call: String) { lock.withLock { calls.append(call) } }

    func link(_ name: String) async -> LinkCheckLink? { note("lien:\(name)"); return linkValue }
    func neighbor(on link: LinkCheckLink, seconds: TimeInterval) async -> LinkCheckNeighborMeasure {
        note("lldp:\(Int(seconds))")
        return neighborValue
    }
    func dhcp(on link: LinkCheckLink, seconds: TimeInterval) async -> LinkCheckDHCPMeasure {
        note("dhcp")
        return LinkCheckDHCPMeasure(offers: offers, waitedSeconds: seconds, method: "simulé")
    }
    func gateway(_ address: IPv4Address, count: Int, interval: TimeInterval) async -> LinkCheckGatewayMeasure {
        note("ping:\(address):\(count)")
        return LinkCheckGatewayMeasure(address: address, rtts: rtts)
    }
    func dns(_ names: [String], server: IPv4Address?) async -> LinkCheckDNSMeasure {
        note("dns:\(server?.description ?? "système")")
        return LinkCheckDNSMeasure(server: server, answers: dnsAnswers)
    }
    func internet(_ url: URL, expectedText: String?) async -> LinkCheckInternetMeasure {
        note("http:\(url.host ?? "")")
        return internetValue ?? LinkCheckInternetMeasure(url: url, statusCode: 200, milliseconds: 84, expectedTextFound: true)
    }
}

private func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }

private func wiredLink(speed: UInt64 = 1000, duplex: LinkDuplex = .full, address: String? = "10.182.122.142") -> LinkCheckLink {
    LinkCheckLink(name: "en7", isWireless: false, kindLabel: "Ethernet", isActive: true, address: address.map(ip),
                  netmask: ip("255.255.255.0"), gateway: ip("10.182.122.1"), dnsServers: [ip("10.182.122.1")],
                  speedMbps: speed, duplex: duplex, mediaLabel: "1000baseT")
}

private func linkCheckNeighbor(vlan: Int? = 20, port: String = "1/22") -> NetworkNeighbor {
    let power = PoEPowerInfo(sources: [.lldp8023], role: .pse, supported: true, enabled: true, powerClass: 0, standard: .at,
                             powerType: 2, requestedW: 0, allocatedW: 0)
    return NetworkNeighbor(protocols: [.lldp], chassisID: "88:3A:30:9C:41:00", systemName: "SW-ETG2-01", portID: port,
                           portDescription: "Bureau 214 - prise B", model: "Aruba 2930F-24G", nativeVLAN: vlan, voiceVLAN: 40,
                           managementAddresses: ["10.182.122.3"], link: "1000BASE-T duplex intégral", duplex: "full", power: power)
}

private func linkCheckOffer(server: String = "10.182.122.1", delay: Double = 0.012, router: String = "10.182.122.1") -> DHCPOffer {
    var offer = DHCPOffer(messageType: .offer, xid: 1, flagsBroadcast: true, offeredAddress: ip("10.182.122.187"))
    offer.serverIdentifier = ip(server)
    offer.subnetMask = ip("255.255.255.0")
    offer.routers = [ip(router)]
    offer.dnsServers = [ip("10.182.122.1")]
    offer.leaseTime = 86_400
    offer.delay = delay
    return offer
}

func registerLinkCheckTests(_ suite: TestSuite) {
    suite.add("Bilan de raccordement : enchaînement complet sur un bon lien") {
        let probes = FakeLinkProbes(link: wiredLink())
        let log = ProgressLog()
        let options = LinkCheckOptions(interfaceName: "en7", location: " Bureau 214 · prise B ", expectedVLAN: 20,
                                       allowedDHCPServers: [ip("10.182.122.1")], neighborSeconds: 31)
        let result = await LinkCheckRunner.run(options, probes: probes, siteKey: "siege", siteName: "Siège",
                                               progress: { log.add($0) })
        try expectEqual(result.steps.map(\.kind), LinkCheckStepKind.allCases, "huit étapes, dans l'ordre")
        try expectEqual(result.overall, .ok, "tout est conforme")
        try expectEqual(result.headline, "Raccordement conforme", "titre")
        try expectEqual(result.location, "Bureau 214 · prise B", "emplacement nettoyé")
        try expectEqual(result.siteKey, "siege", "site")
        try expectEqual(result.switchPort, "SW-ETG2-01 · port 1/22", "switch et port")
        try expectEqual(result.vlan, "20", "VLAN")
        try expectEqual(result.step(.lien)?.fact("vitesse")?.value, "1\u{00A0}Gb/s", "vitesse")
        try expectEqual(result.step(.passerelle)?.fact("perte")?.value, "0\u{00A0}%", "perte, espace insécable")
        try expect(probes.calls.contains("lldp:31"), "écoute LLDP de la durée demandée")
        try expect(probes.calls.contains("ping:10.182.122.1:10"), "ping de la passerelle, 10 envois")
        try expect(probes.calls.contains("dns:10.182.122.1"), "DNS interrogé : celui du réseau")
        try expect(probes.calls.contains("http:captive.apple.com"), "adresse neutre")
        // Chaque étape annoncée avant d'être terminée, une seule fin par étape.
        let finished = log.items.compactMap { $0.step?.kind }
        try expectEqual(Set(finished), Set(LinkCheckStepKind.allCases), "chaque étape terminée")
        try expectEqual(finished.count, 8, "une seule fin par étape")
        try expect(log.items.first.map { $0.kind == .lien && $0.step == nil } ?? false, "le lien commence")
    }

    suite.add("Bilan de raccordement : pas de lien, le reste est sauté") {
        var link = wiredLink()
        link.isActive = false
        let probes = FakeLinkProbes(link: link)
        let result = await LinkCheckRunner.run(LinkCheckOptions(interfaceName: "en7"), probes: probes)
        try expectEqual(result.step(.lien)?.status, .failure, "lien en échec")
        try expect(result.steps.filter { $0.kind != .lien }.allSatisfy { $0.status == .skipped }, "le reste non vérifié")
        try expectEqual(probes.calls, ["lien:en7"], "aucune autre sonde")
        let missing = await LinkCheckRunner.run(LinkCheckOptions(interfaceName: "en9"), probes: FakeLinkProbes(link: nil))
        try expectEqual(missing.step(.lien)?.summary, "Interface introuvable", "interface disparue")
    }

    suite.add("Bilan de raccordement : sans adresse, DHCP mesuré mais pas la suite") {
        let probes = FakeLinkProbes(link: wiredLink(address: "169.254.12.4"), offers: [])
        let result = await LinkCheckRunner.run(LinkCheckOptions(interfaceName: "en7"), probes: probes)
        try expectEqual(result.step(.lien)?.status, .failure, "169.254 : échec du lien")
        try expect(result.step(.lien)?.explanation.contains("169.254") ?? false, "explication de l'adresse automatique")
        try expectEqual(result.step(.dhcp)?.status, .failure, "aucune offre")
        try expect(probes.calls.contains("dhcp"), "DHCP mesuré quand même")
        try expect(!probes.calls.contains { $0.hasPrefix("ping") || $0.hasPrefix("dns") || $0.hasPrefix("http") }, "pas de ping, DNS ni HTTP")
        try expectEqual(result.step(.internet)?.status, .skipped, "Internet non vérifié")
        try expectEqual(result.headline, "2 échecs\u{00A0}: Lien, DHCP", "titre des échecs")
    }

    suite.add("Bilan de raccordement : Wi-Fi, switch, VLAN et PoE sans objet") {
        var link = wiredLink()
        link.isWireless = true
        link.kindLabel = "Wi-Fi"
        link.duplex = nil
        link.speedMbps = 866
        let probes = FakeLinkProbes(link: link)
        let result = await LinkCheckRunner.run(LinkCheckOptions(interfaceName: "en0"), probes: probes)
        try expect(!probes.calls.contains { $0.hasPrefix("lldp") }, "pas d'écoute LLDP en Wi-Fi")
        try expectEqual(result.step(.switchPort)?.status, .skipped, "switch sans objet")
        try expectEqual(result.step(.lien)?.status, .ok, "866 Mb/s en Wi-Fi : pas d'avertissement de vitesse")
        try expectEqual(result.overall, .ok, "verdict OK, les étapes sautées ne comptent pas")
    }

    suite.add("Bilan de raccordement : verdicts du lien") {
        let half = LinkCheckEvaluator.link(wiredLink(speed: 100, duplex: .half), requested: "en7")
        try expectEqual(half.status, .warning, "semi-duplex")
        try expect(half.explanation.contains("Semi-duplex"), "explication du semi-duplex")
        let slow = LinkCheckEvaluator.link(wiredLink(speed: 100), requested: "en7")
        try expectEqual(slow.status, .warning, "100 Mb/s en filaire")
        try expect(slow.explanation.contains("100\u{00A0}Mb/s"), "vitesse dans l'explication")
        try expectEqual(LinkCheckEvaluator.link(wiredLink(speed: 2500), requested: "en7").summary, "2,5\u{00A0}Gb/s · duplex intégral", "2,5 Gb/s")
        try expectEqual(LinkMedia.speedLabel(10_000), "10\u{00A0}Gb/s", "10 Gb/s")
    }

    suite.add("Bilan de raccordement : décodage SIOCGIFMEDIA") {
        // IFM_ETHER | IFM_1000_T | IFM_FDX, porteuse valide et active.
        let gigabit = LinkMedia.decode(active: 0x20 | 16 | 0x0010_0000, status: 0x3)
        try expectEqual(gigabit, LinkMedia(isActive: true, speedMbps: 1000, duplex: .full, label: "1000baseT"), "1000baseT duplex intégral")
        let fast = LinkMedia.decode(active: 0x20 | 6 | 0x0020_0000, status: 0x1)
        try expectEqual(fast.speedMbps, 100, "100baseTX")
        try expectEqual(fast.duplex, .half, "semi-duplex")
        try expectEqual(fast.isActive, false, "pas de porteuse")
        let unknown = LinkMedia.decode(active: 0x80 | 3, status: 0)
        try expectEqual(unknown.speedMbps, nil, "Wi-Fi : pas de vitesse par le média")
        try expectEqual(unknown.isActive, nil, "état inconnu")
        try expectEqual(LinkMedia.decode(active: 0x20 | 22 | 0x0010_0000, status: 3).speedMbps, 2500, "2500baseT")
    }

    suite.add("Bilan de raccordement : verdicts DHCP") {
        let link = wiredLink()
        let none = LinkCheckEvaluator.dhcp(LinkCheckDHCPMeasure(offers: [], waitedSeconds: 4), link: link, allowed: [])
        try expectEqual(none.status, .failure, "aucune offre")
        try expect(none.explanation.contains("peut-être fixe"), "adresse peut-être fixe")
        let rogue = linkCheckOffer(server: "10.182.122.250", delay: 0.02, router: "192.168.0.1")
        let two = LinkCheckEvaluator.dhcp(LinkCheckDHCPMeasure(offers: [linkCheckOffer(), rogue], waitedSeconds: 4), link: link, allowed: [])
        try expectEqual(two.status, .warning, "deux serveurs sans liste : avertissement")
        let unauthorized = LinkCheckEvaluator.dhcp(LinkCheckDHCPMeasure(offers: [linkCheckOffer(), rogue], waitedSeconds: 4), link: link,
                                                   allowed: [ip("10.182.122.1")])
        try expectEqual(unauthorized.status, .failure, "serveur non autorisé")
        try expect(unauthorized.summary.contains("10.182.122.250"), "serveur nommé")
        let slow = LinkCheckEvaluator.dhcp(LinkCheckDHCPMeasure(offers: [linkCheckOffer(delay: 3.2)], waitedSeconds: 4), link: link, allowed: [])
        try expectEqual(slow.status, .warning, "offre lente")
        let otherGateway = LinkCheckEvaluator.dhcp(LinkCheckDHCPMeasure(offers: [linkCheckOffer(router: "10.182.122.254")], waitedSeconds: 4),
                                                   link: link, allowed: [])
        try expectEqual(otherGateway.status, .warning, "passerelle offerte différente")
        let good = LinkCheckEvaluator.dhcp(LinkCheckDHCPMeasure(offers: [linkCheckOffer()], waitedSeconds: 4), link: link, allowed: [ip("10.182.122.1")])
        try expectEqual(good.status, .ok, "un serveur autorisé, rapide")
        try expectEqual(good.fact("temps")?.value, "12\u{00A0}ms", "temps d'obtention")
        try expectEqual(good.fact("bail")?.value, "24\u{00A0}h", "bail")
        let refused = LinkCheckEvaluator.dhcp(LinkCheckDHCPMeasure(offers: [], waitedSeconds: 0, unavailableReason: "Droits requis."), link: link, allowed: [])
        try expectEqual(refused.status, .skipped, "droits manquants : non vérifié")
    }

    suite.add("Bilan de raccordement : verdicts passerelle, DNS et Internet") {
        let link = wiredLink()
        let gw = ip("10.182.122.1")
        try expectEqual(LinkCheckEvaluator.gateway(LinkCheckGatewayMeasure(address: gw, rtts: [nil, nil, nil]), link: link).status,
                        .failure, "aucune réponse")
        let lossy = LinkCheckEvaluator.gateway(LinkCheckGatewayMeasure(address: gw, rtts: [1, 1, nil, 1, 1, 1, 1, 1, 1, 1]), link: link)
        try expectEqual(lossy.status, .warning, "10 % de perte")
        try expectEqual(lossy.fact("perte")?.value, "10\u{00A0}%", "perte")
        try expectEqual(LinkCheckEvaluator.gateway(LinkCheckGatewayMeasure(address: gw, rtts: [1, nil, nil, 1, 1]), link: link).status,
                        .failure, "40 % de perte")
        try expectEqual(LinkCheckEvaluator.gateway(LinkCheckGatewayMeasure(address: gw, rtts: [25, 25]), link: link).status, .warning, "25 ms en filaire")
        var wifi = link
        wifi.isWireless = true
        try expectEqual(LinkCheckEvaluator.gateway(LinkCheckGatewayMeasure(address: gw, rtts: [25, 25]), link: wifi).status, .ok, "25 ms en Wi-Fi")
        try expectEqual(LinkCheckGatewayMeasure(address: gw, rtts: [1, 3, 2]).jitter, 1.5, "gigue")

        let allFail = LinkCheckEvaluator.dns(LinkCheckDNSMeasure(server: gw, answers: [LinkCheckDNSAnswer(name: "a.com", milliseconds: nil, error: "délai dépassé")]), link: link)
        try expectEqual(allFail.status, .failure, "aucun nom résolu")
        let partial = LinkCheckEvaluator.dns(LinkCheckDNSMeasure(server: gw, answers: [
            LinkCheckDNSAnswer(name: "a.com", milliseconds: 10, addresses: ["1.2.3.4"]),
            LinkCheckDNSAnswer(name: "b.com", milliseconds: nil, error: "NXDOMAIN")]), link: link)
        try expectEqual(partial.status, .warning, "un nom sur deux")
        try expectEqual(partial.summary, "1/2 noms · 10\u{00A0}ms", "résumé")
        let slowDNS = LinkCheckEvaluator.dns(LinkCheckDNSMeasure(server: nil, answers: [LinkCheckDNSAnswer(name: "a.com", milliseconds: 400, addresses: ["1.2.3.4"])]), link: link)
        try expectEqual(slowDNS.status, .warning, "DNS lent")

        let url = LinkCheckOptions.defaultInternetURL
        try expectEqual(LinkCheckEvaluator.internet(LinkCheckInternetMeasure(url: url, error: "délai dépassé"), link: link).status, .failure, "injoignable")
        let captive = LinkCheckEvaluator.internet(LinkCheckInternetMeasure(url: url, statusCode: 200, milliseconds: 90, expectedTextFound: false,
                                                                         finalHost: "portail.hotel.example"), link: link)
        try expectEqual(captive.status, .warning, "portail captif")
        try expect(captive.explanation.contains("portail.hotel.example"), "redirection nommée")
        try expectEqual(LinkCheckEvaluator.internet(LinkCheckInternetMeasure(url: url, statusCode: 200, milliseconds: 1800, expectedTextFound: true), link: link).status,
                        .warning, "Internet lent")
        try expectEqual(LinkCheckEvaluator.internet(nil, link: link).status, .skipped, "non mesuré")
    }

    suite.add("Bilan de raccordement : switch, VLAN attendu et PoE") {
        let link = wiredLink()
        let measure = LinkCheckNeighborMeasure(neighbor: linkCheckNeighbor(vlan: 1), listenedSeconds: 31)
        try expectEqual(LinkCheckEvaluator.vlan(measure, link: link, expected: 20).status, .failure, "VLAN 1 au lieu de 20")
        try expectEqual(LinkCheckEvaluator.vlan(measure, link: link, expected: 1).status, .ok, "VLAN conforme")
        try expectEqual(LinkCheckEvaluator.vlan(measure, link: link, expected: nil).summary, "VLAN 1 · voix 40", "VLAN natif et voix")
        let silent = LinkCheckNeighborMeasure(neighbor: nil, listenedSeconds: 35)
        let none = LinkCheckEvaluator.switchPort(silent, link: link)
        try expectEqual(none.status, .warning, "aucune annonce en 35 s")
        try expect(none.explanation.contains("35\u{00A0}s"), "durée d'écoute")
        let blocked = LinkCheckEvaluator.switchPort(LinkCheckNeighborMeasure(neighbor: nil, unavailableReason: "Accès BPF refusé."), link: link)
        try expectEqual(blocked.status, .skipped, "écoute impossible : non vérifié")
        let previous = LinkCheckEvaluator.switchPort(LinkCheckNeighborMeasure(neighbor: linkCheckNeighbor(), fromPreviousCapture: true,
                                                                              unavailableReason: "Accès BPF refusé."), link: link)
        try expectEqual(previous.status, .ok, "voisin repris de la dernière capture")
        try expect(previous.explanation.contains("dernière capture"), "origine dite")
        var mismatch = linkCheckNeighbor()
        mismatch.duplex = "half"
        try expectEqual(LinkCheckEvaluator.switchPort(LinkCheckNeighborMeasure(neighbor: mismatch), link: link).status, .warning,
                        "désaccord de duplex")
        let poe = LinkCheckEvaluator.poe(measure, link: link)
        try expectEqual(poe.status, .ok, "port PoE disponible")
        try expect(poe.explanation.contains("normal"), "le Mac n'en consomme pas")
        var off = linkCheckNeighbor()
        off.power?.enabled = false
        try expectEqual(LinkCheckEvaluator.poe(LinkCheckNeighborMeasure(neighbor: off), link: link).status, .warning, "PoE désactivé")
    }

    suite.add("Bilan de raccordement : comparaison avant/après") {
        let beforeProbes = FakeLinkProbes(link: wiredLink(speed: 100, duplex: .half),
                                          offers: [linkCheckOffer(), linkCheckOffer(server: "10.182.122.250", router: "192.168.0.1")],
                                          rtts: [1.4, nil, 1.2, 1.5, nil, 1.1, 1.3, 1.2, 1.6, 1.4])
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let before = await LinkCheckRunner.run(LinkCheckOptions(interfaceName: "en7"), probes: beforeProbes, now: { clock })
        let afterProbes = FakeLinkProbes(link: wiredLink(), neighbor: linkCheckNeighbor(port: "1/23"))
        let after = await LinkCheckRunner.run(LinkCheckOptions(interfaceName: "en7"), probes: afterProbes, now: { clock.addingTimeInterval(3600) })
        try expectEqual(before.overall, .failure, "avant : perte de 20 % (échec)")
        try expectEqual(after.overall, .ok, "après : conforme")
        let diffs = LinkCheckComparison.compare(before, after)
        func change(_ step: LinkCheckStepKind, _ key: String) -> LinkCheckDifference.Change? {
            diffs.first { $0.step == step && $0.key == key }?.change
        }
        try expectEqual(change(.lien, "etat"), .improved, "lien : avertissement → OK")
        try expectEqual(change(.lien, "vitesse"), .improved, "100 Mb/s → 1 Gb/s")
        try expectEqual(change(.lien, "duplex"), .changed, "duplex changé")
        try expectEqual(change(.passerelle, "perte"), .improved, "perte 20 % → 0 %")
        try expectEqual(change(.passerelle, "latence"), .same, "1,3 ms ≈ 0,8 ms : sous la tolérance")
        try expectEqual(change(.switchPort, "port"), .changed, "port 1/22 → 1/23")
        try expectEqual(change(.switchPort, "switch"), .same, "même switch")
        try expectEqual(change(.dhcp, "serveurs"), .changed, "2 serveurs → 1 (sans sens)")
        let shown = diffs.filter(\.change.isDifference)
        try expect(LinkCheckComparison.summary(shown).hasPrefix("\(shown.count) écarts\u{00A0}: "), "résumé des écarts")
        try expectEqual(LinkCheckComparison.summary([]), "Aucun écart", "aucun écart")
        // Sens inverse : tout ce qui s'améliorait se dégrade.
        let reverse = LinkCheckComparison.compare(after, before)
        try expectEqual(reverse.first { $0.step == .lien && $0.key == "vitesse" }?.change, .degraded, "1 Gb/s → 100 Mb/s")
        try expectEqual(reverse.first { $0.step == .passerelle && $0.key == "etat" }?.change, .degraded, "OK → échec")
        // Texte à copier : comparaison incluse.
        let text = LinkCheckText.plain(after, comparedTo: before)
        try expect(text.contains("Comparaison avec le bilan du"), "comparaison dans le texte")
        try expect(text.contains("[OK] Lien"), "étapes dans le texte")
    }

    suite.add("Bilan de raccordement : historique du site, référence et rapport") {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func make(_ hours: Double) -> LinkCheckResult {
            LinkCheckResult(date: base.addingTimeInterval(hours * 3600), siteKey: "siege", siteName: "Siège", interfaceName: "en7",
                            steps: [LinkCheckStep(kind: .lien, status: .ok, summary: "1 Gb/s", explanation: "")])
        }
        var history = LinkCheckHistory()
        let a = make(0), b = make(1), c = make(2)
        history.add(b)
        history.add(a)
        history.add(c)
        try expectEqual(history.results.map(\.id), [c.id, b.id, a.id], "du plus récent au plus ancien")
        try expectEqual(history.baseline(for: c)?.id, b.id, "sans référence : le bilan précédent")
        history.setReference(a.id)
        try expectEqual(history.baseline(for: c)?.id, a.id, "la référence « avant »")
        try expectEqual(history.baseline(for: a)?.id, nil, "la référence n'a rien avant elle")
        history.report(c.id)
        history.report(c.id)
        try expectEqual(history.reportedIDs, [c.id], "retenu une seule fois")
        // Encodage, puis bilan illisible ignoré.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: encoder.encode(history)) as! [String: Any]
        var list = json["results"] as! [Any]
        list.append(["id": "pas-un-uuid"])
        json["results"] = list
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reread = try decoder.decode(LinkCheckHistory.self, from: JSONSerialization.data(withJSONObject: json))
        try expectEqual(reread.results.count, 3, "bilan illisible sauté")
        try expectEqual(reread.referenceID, a.id, "référence relue")
        history.remove(a.id)
        try expectEqual(history.referenceID, nil, "référence retirée avec son bilan")
        // Taille bornée : la référence et les bilans du rapport restent.
        var big = LinkCheckHistory()
        let first = make(-100)
        big.add(first)
        big.setReference(first.id)
        for i in 0..<(LinkCheckHistory.keep + 5) { big.add(make(Double(i))) }
        try expectEqual(big.results.count, LinkCheckHistory.keep, "bornée")
        try expect(big.results.contains { $0.id == first.id }, "la référence reste")
    }

    suite.add("Bilan de raccordement : section du rapport et document PDF") {
        let probes = FakeLinkProbes(link: wiredLink(speed: 100))
        let before = await LinkCheckRunner.run(LinkCheckOptions(interfaceName: "en7", location: "Bureau 214"), probes: probes,
                                               siteName: "Siège", now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let after = await LinkCheckRunner.run(LinkCheckOptions(interfaceName: "en7", location: "Bureau 214"), probes: FakeLinkProbes(link: wiredLink()),
                                              siteName: "Siège", now: { Date(timeIntervalSince1970: 1_800_003_600) })
        var input = ReportInput(devices: [])
        input.linkChecks = [LinkCheckReportEntry(result: after, before: before)]
        let config = ReportConfig(template: .intervention, sections: [.resume, .raccordement], maskMAC: true)
        let document = ReportBuilder.build(config: config, input: input)
        let section = try document.sections.first { $0.kind == .raccordement }.linkCheckUnwrap("section présente")
        try expectEqual(section.heading, "2. Bilan de raccordement", "rang de la section")
        let tables = section.blocks.compactMap { block -> ReportTable? in if case .table(let t) = block { return t } else { return nil } }
        try expectEqual(tables.count, 2, "étapes et comparaison (un seul bilan : pas de tableau récapitulatif)")
        try expectEqual(tables.first?.rows.count, 8, "huit étapes")
        try expect(tables.last?.rows.contains { $0.cells.last?.text == "Mieux" } ?? false, "amélioration dans la comparaison")
        try expect(!ReportTemplate.allCases.contains { $0.defaultSections.contains(.raccordement) }, "section facultative")
        input.linkChecks = []
        if case .note(let text)? = ReportBuilder.build(config: config, input: input).sections.first(where: { $0.kind == .raccordement })?.blocks.first {
            try expect(text.contains("Ajouter au rapport"), "note quand aucun bilan n'est retenu")
        } else {
            throw TestFailure(message: "note attendue", file: #fileID, line: #line)
        }
        let pdf = ReportBuilder.linkCheckDocument(LinkCheckReportEntry(result: before), client: "Client", technician: "Dany")
        try expectEqual(pdf.sections.count, 1, "document d'une section")
        try expectEqual(pdf.title, "Bilan de raccordement — Bureau 214", "titre du document")
        try expect(pdf.problems.contains { $0.title.hasPrefix("Lien") }, "avertissement du lien dans les problèmes")
        try expect(!ReportPaginator.paginate(pdf).isEmpty, "pagination")
    }
}

/// Journal d'avancement (appelé depuis le moteur).
private final class ProgressLog: @unchecked Sendable {
    let lock = NSLock()
    var items: [LinkCheckProgress] = []
    func add(_ item: LinkCheckProgress) { lock.withLock { items.append(item) } }
}

private extension Optional {
    func linkCheckUnwrap(_ message: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
        return value
    }
}
