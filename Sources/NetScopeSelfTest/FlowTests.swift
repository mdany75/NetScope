import Foundation
import NetScopeCore

// Note 75 : collecteur NetFlow, sFlow et IPFIX. Paquets fixes (octets écrits à la main d'après les
// formats publiés, et paquets construits par FlowPacketBuilder), gabarits par exportateur et
// domaine, enregistrements arrivés avant leur gabarit, échantillonnage, compteurs d'interface,
// agrégation par minute à mémoire bornée, pont vers l'écran Trafic (« Qui sature le lien ? »),
// guide par marque et un aller-retour UDP sur 127.0.0.1 seulement.

private func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }

private func hex(_ text: String) -> [UInt8] {
    let digits = text.filter { $0.isHexDigit }
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        bytes.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

func registerFlowTests(_ suite: TestSuite) {
    let router = ip("10.0.0.1")

    suite.add("Flux : NetFlow v5 écrit à la main (en-tête et enregistrement de 48 octets)") {
        let packet = hex("""
        0005 0001 0036EE80 6AB0C100 00000000 0000002A 00 00 0000
        0A000005 08080808 00000000 0003 0001 0000000A 000005DC 0036E6B0 0036EE80 C350 0035 00 00 11 00 0000 0000 18 18 0000
        """)
        try expectEqual(packet.count, 72, "taille du paquet v5")
        var decoder = FlowDecoder()
        let result = try decoder.decode(packet, from: router)
        try expectEqual(result.kind, .netflow5, "format reconnu")
        try expectEqual(result.records.count, 1, "un enregistrement")
        let r = result.records[0]
        try expectEqual(r.source, ip("10.0.0.5"), "source")
        try expectEqual(r.destination, ip("8.8.8.8"), "destination")
        try expectEqual(r.sourcePort, 50000, "port source")
        try expectEqual(r.destinationPort, 53, "port destination")
        try expectEqual(r.proto, 17, "UDP")
        try expectEqual(r.bytes, 1500, "octets")
        try expectEqual(r.packets, 10, "paquets")
        try expectEqual(r.inputInterface, 3, "interface d'entrée")
        try expectEqual(r.outputInterface, 1, "interface de sortie")
        try expectEqual(r.durationMs, 2000, "durée d'après FIRST et LAST")
        try expectEqual(r.samplingRate, 1, "pas d'échantillonnage")
    }

    suite.add("Flux : NetFlow v5 échantillonné, tronqué ou faux") {
        let flow = FlowPacketBuilder.Flow(source: ip("10.1.1.10"), destination: ip("1.1.1.1"), sourcePort: 40000, destinationPort: 443,
                                          bytes: 1000, packets: 2, input: 2, output: 1)
        var decoder = FlowDecoder()
        let sampled = try decoder.decode(FlowPacketBuilder.netflowV5([flow, flow], sampling: 100), from: router)
        try expectEqual(sampled.records.count, 2, "deux flux")
        try expectEqual(sampled.samplingRate, 100, "intervalle annoncé")
        try expectEqual(sampled.records[0].estimatedBytes, 100_000, "volume estimé = octets × 100")
        var truncated = FlowPacketBuilder.netflowV5([flow, flow])
        truncated.removeLast(10)
        do {
            _ = try decoder.decode(truncated, from: router)
            throw TestFailure(message: "un v5 tronqué doit être refusé", file: #fileID, line: #line)
        } catch let error as FlowDecodeError {
            try expect(error.message.contains("2 enregistrements annoncés"), "raison claire : \(error.message)")
        }
        do {
            _ = try decoder.decode([0x47, 0x45, 0x54, 0x20, 0x2F], from: router)
            throw TestFailure(message: "« GET / » n'est pas un flux", file: #fileID, line: #line)
        } catch let error as FlowDecodeError {
            try expect(error.message.contains("format inconnu"), "format inconnu : \(error.message)")
        }
        try expectThrows(FlowDecodeError("datagramme trop court (2 octets)"), "deux octets") {
            _ = try decoder.decode([0, 9], from: router)
        }
    }

    suite.add("Flux : NetFlow v9 écrit à la main (gabarit puis données avec bourrage)") {
        let packet = hex("""
        0009 0002 0036EE80 6AB0C100 00000007 00000064
        0000 001C 0100 0005 0008 0004 000C 0004 0004 0001 0001 0004 000B 0002
        0100 0014 C0A8010A 8EFA412E 06 00001000 01BB 00
        """)
        var decoder = FlowDecoder()
        let result = try decoder.decode(packet, from: router)
        try expectEqual(result.kind, .netflow9, "format")
        try expectEqual(result.domain, 100, "source ID")
        try expectEqual(result.templatesLearned, 1, "gabarit appris")
        try expectEqual(result.records.count, 1, "un enregistrement (le bourrage n'en fait pas un second)")
        let r = result.records[0]
        try expectEqual(r.source, ip("192.168.1.10"), "IPV4_SRC_ADDR")
        try expectEqual(r.destination, ip("142.250.65.46"), "IPV4_DST_ADDR")
        try expectEqual(r.proto, 6, "PROTOCOL")
        try expectEqual(r.bytes, 4096, "IN_BYTES")
        try expectEqual(r.destinationPort, 443, "L4_DST_PORT")
        try expectEqual(decoder.templateCount(exporter: router), 1, "gabarit gardé pour cet exportateur")
    }

    suite.add("Flux : NetFlow v9, données avant le gabarit, gabarits par exportateur et domaine") {
        let flows = (0..<3).map { i in
            FlowPacketBuilder.Flow(source: ip("10.0.0.\(10 + i)"), destination: ip("52.96.0.\(i + 1)"), sourcePort: 50_000, destinationPort: 443,
                                   bytes: 2000, packets: 4, input: 5, output: 1, durationMs: 4000)
        }
        var decoder = FlowDecoder()
        // Données seules : mises de côté.
        let early = try decoder.decode(FlowPacketBuilder.netflowV9(flows, sourceID: 7, withTemplate: false), from: router)
        try expectEqual(early.records.count, 0, "rien de décodé sans gabarit")
        try expectEqual(early.setsWaiting, 1, "ensemble mis de côté")
        try expectEqual(decoder.waitingCount(exporter: router), 1, "un ensemble en attente")
        // Le même gabarit d'un autre exportateur ou d'un autre domaine ne sert pas.
        _ = try decoder.decode(FlowPacketBuilder.netflowV9([], sourceID: 7, withData: false), from: ip("10.0.0.2"))
        _ = try decoder.decode(FlowPacketBuilder.netflowV9([], sourceID: 8, withData: false), from: router)
        try expectEqual(decoder.waitingCount(exporter: router), 1, "toujours en attente")
        // Le bon gabarit arrive : les données mises de côté sont décodées.
        let late = try decoder.decode(FlowPacketBuilder.netflowV9([], sourceID: 7, withData: false), from: router)
        try expectEqual(late.recoveredRecords, 3, "trois enregistrements retrouvés")
        try expectEqual(late.records.count, 3, "rendus avec le gabarit")
        try expectEqual(late.records[0].durationMs, 4000, "FIRST_SWITCHED et LAST_SWITCHED")
        try expectEqual(decoder.waitingCount(), 0, "plus rien en attente")
        // Options : échantillonnage 1 sur 64 appliqué aux données suivantes.
        let sampled = try decoder.decode(FlowPacketBuilder.netflowV9(flows, sourceID: 7, sampling: 64), from: router)
        try expectEqual(sampled.samplingRate, 64, "SAMPLING_INTERVAL des options")
        try expect(sampled.records.allSatisfy { $0.samplingRate == 64 }, "échantillonnage appliqué")
        try expectEqual(decoder.announcedSampling(exporter: router), 64, "retenu pour l'exportateur")
    }

    suite.add("Flux : mise de côté bornée") {
        var limits = FlowDecoder.Limits()
        limits.maxWaitingSets = 5
        limits.maxWaitingPerTemplate = 3
        var decoder = FlowDecoder(limits: limits)
        let flow = FlowPacketBuilder.Flow(source: ip("10.0.0.10"), destination: ip("1.1.1.1"), bytes: 100)
        for id in 0..<4 {
            for _ in 0..<4 {
                _ = try decoder.decode(FlowPacketBuilder.netflowV9([flow], templateID: UInt16(300 + id), withTemplate: false), from: router)
            }
        }
        try expect(decoder.waitingCount() <= 5, "au plus 5 ensembles en attente (\(decoder.waitingCount()))")
    }

    suite.add("Flux : IPFIX (champ d'entreprise, longueur variable, millisecondes, retrait du gabarit)") {
        let flows = [FlowPacketBuilder.Flow(source: ip("172.16.4.20"), destination: ip("13.107.42.14"), sourcePort: 51_000, destinationPort: 443,
                                            bytes: 9000, packets: 9, input: 4, output: 2, durationMs: 1500),
                     FlowPacketBuilder.Flow(source: ip("13.107.42.14"), destination: ip("172.16.4.20"), sourcePort: 443, destinationPort: 51_000,
                                            bytes: 120_000, packets: 90, input: 2, output: 4, durationMs: 1500)]
        var decoder = FlowDecoder()
        let result = try decoder.decode(FlowPacketBuilder.ipfix(flows, domain: 3), from: router)
        try expectEqual(result.kind, .ipfix, "format")
        try expectEqual(result.domain, 3, "domaine d'observation")
        try expectEqual(result.records.count, 2, "deux enregistrements malgré le champ variable")
        try expectEqual(result.records[1].bytes, 120_000, "octetDeltaCount")
        try expectEqual(result.records[0].durationMs, 1500, "flowStart/EndMilliseconds")
        try expectEqual(result.records[1].inputInterface, 2, "ingressInterface")
        // Longueur d'en-tête fausse : refus clair.
        var broken = FlowPacketBuilder.ipfix(flows)
        broken[3] = 0xFF
        do {
            _ = try decoder.decode(broken, from: router)
            throw TestFailure(message: "longueur IPFIX fausse acceptée", file: #fileID, line: #line)
        } catch let error as FlowDecodeError {
            try expect(error.message.contains("longueur annoncée"), "raison : \(error.message)")
        }
        // Retrait du gabarit (nombre de champs 0) : les données suivantes attendent.
        let withdrawal = hex("000A 0018 6AB0C100 00000001 00000003 0002 0008 012C 0000")
        _ = try decoder.decode(withdrawal, from: router)
        let after = try decoder.decode(FlowPacketBuilder.ipfix(flows, domain: 3, withTemplate: false), from: router)
        try expectEqual(after.records.count, 0, "gabarit retiré")
        try expectEqual(after.setsWaiting, 1, "données mises de côté")
    }

    suite.add("Flux : sFlow v5 (en-tête Ethernet avec VLAN, taux, compteurs d'interface)") {
        let flows = [FlowPacketBuilder.Flow(source: ip("192.168.10.40"), destination: ip("151.101.1.140"), sourcePort: 60_000, destinationPort: 443,
                                            bytes: 1514, input: 12, output: 49),
                     FlowPacketBuilder.Flow(source: ip("192.168.10.41"), destination: ip("192.168.10.5"), sourcePort: 5353, destinationPort: 53,
                                            proto: 17, bytes: 90, input: 13, output: 12)]
        let counters = [FlowPacketBuilder.Counters(ifIndex: 49, speed: 1_000_000_000, inOctets: 1_000_000, outOctets: 2_000_000, inErrors: 3)]
        var decoder = FlowDecoder()
        let packet = FlowPacketBuilder.sflow(agent: ip("192.168.10.2"), flows: flows, samplingRate: 512, counters: counters, vlan: 20)
        let result = try decoder.decode(packet, from: ip("192.168.10.2"))
        try expectEqual(result.kind, .sflow, "format")
        try expectEqual(result.records.count, 2, "deux échantillons de flux")
        let first = result.records[0]
        try expectEqual(first.source, ip("192.168.10.40"), "adresse lue après l'étiquette VLAN")
        try expectEqual(first.destinationPort, 443, "port TCP")
        try expectEqual(first.samplingRate, 512, "taux d'échantillonnage")
        try expectEqual(first.estimatedBytes, 1514 * 512, "volume estimé")
        try expectEqual(first.outputInterface, 49, "interface de sortie")
        try expectEqual(result.records[1].proto, 17, "UDP")
        try expectEqual(result.counters.count, 1, "un échantillon de compteurs")
        try expectEqual(result.counters[0].speed, 1_000_000_000, "ifSpeed")
        try expectEqual(result.counters[0].outOctets, 2_000_000, "ifOutOctets")
        try expectEqual(result.counters[0].inErrors, 3, "ifInErrors")
        try expect(result.counters[0].isUp, "ifOperStatus")
        // Datagramme tronqué au milieu d'un échantillon : refus, pas de plantage.
        do {
            _ = try decoder.decode(Array(packet.prefix(packet.count - 30)), from: router)
            throw TestFailure(message: "sFlow tronqué accepté", file: #fileID, line: #line)
        } catch is FlowDecodeError {}
    }

    suite.add("Flux : agrégation (sens, applications, conversations, lien Internet)") {
        var aggregator = FlowAggregator()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let pc = ip("10.20.0.117")
        let torrent = ip("10.20.0.100")
        let cloud = ip("20.190.128.12")
        // Envoi du poste vers le nuage par l'interface 1 (WAN), réponse plus petite.
        aggregator.add(FlowRecord(kind: .netflow9, exporter: router, source: pc, destination: cloud, sourcePort: 52_000, destinationPort: 443,
                                  proto: 6, bytes: 300_000_000, packets: 200_000, inputInterface: 5, outputInterface: 1), at: now.addingTimeInterval(-30))
        aggregator.add(FlowRecord(kind: .netflow9, exporter: router, source: cloud, destination: pc, sourcePort: 443, destinationPort: 52_000,
                                  proto: 6, bytes: 4_000_000, packets: 40_000, inputInterface: 1, outputInterface: 5), at: now.addingTimeInterval(-30))
        // BitTorrent : réception.
        aggregator.add(FlowRecord(kind: .netflow9, exporter: router, source: ip("81.2.3.4"), destination: torrent, sourcePort: 6881, destinationPort: 40_123,
                                  proto: 6, bytes: 90_000_000, inputInterface: 1, outputInterface: 5), at: now.addingTimeInterval(-20))
        // Trafic interne : poste vers le serveur de fichiers (SMB), le serveur est la « destination ».
        aggregator.add(FlowRecord(kind: .netflow9, exporter: router, source: ip("10.10.0.31"), destination: pc, sourcePort: 445, destinationPort: 50_500,
                                  proto: 6, bytes: 5_000_000, inputInterface: 6, outputInterface: 5), at: now.addingTimeInterval(-10))
        let summary = try XTUnwrap(aggregator.summary(exporter: router, window: 60, now: now), "synthèse")
        try expectEqual(summary.hosts.first?.ip, pc, "premier appareil local : le poste")
        try expectEqual(summary.hosts.first?.volume.sent, 300_000_000, "envoyé par le poste")
        try expectEqual(summary.hosts.first?.volume.received, 9_000_000, "reçu (nuage + SMB)")
        try expect(summary.remotes.contains { $0.ip == ip("10.10.0.31") }, "le serveur SMB est une destination")
        try expect(!summary.hosts.contains { $0.ip == ip("10.10.0.31") }, "le serveur SMB n'est pas une source")
        try expectEqual(summary.applications.first?.application.name, "HTTPS", "application principale")
        let bt = try XTUnwrap(summary.applications.first { $0.application.name == "BitTorrent" }, "BitTorrent reconnu")
        try expectEqual(bt.application.risk, 5, "BitTorrent à risque")
        try expectEqual(summary.wanInterface, 1, "lien Internet deviné : interface 1")
        try expect(summary.conversations.contains { $0.local == pc && $0.remote == cloud && $0.port == 443 }, "conversation poste ↔ nuage")
        try expect(summary.interfaces.first?.isWAN == true, "WAN en tête des interfaces")
        // Pont vers l'écran Trafic : lien déclaré 500/50 Mb/s, « Qui sature le lien ? ».
        let settings = [router: FlowExporterSettings(name: "Routeur du siège", downMbps: 500, upMbps: 50)]
        let overview = FlowTrafficBridge.overview([summary], settings: settings, period: .realtime, now: now)
        try expectEqual(overview.sites, ["Routeur du siège"], "l'exportateur tient lieu de site")
        try expectEqual(overview.wanLinks.count, 1, "un lien WAN")
        try expect((overview.wanLinks[0].utilization ?? 0) > 80, "envoi saturé (40 Mb/s sur 50) : \(overview.wanLinks[0].utilization ?? -1)")
        let verdict = TrafficAnalysis.whoSaturates(overview)
        try expect(verdict.isSaturated, "lien saturé")
        try expectEqual(verdict.consumers.first?.entry.ip, pc, "le poste est la première cause")
        try expectEqual(verdict.consumers.first?.mainApplication, "HTTPS", "application principale tirée des conversations")
        try expect(TrafficAnalysis.unexpectedApplications(overview).contains { $0.name == "BitTorrent" }, "application inattendue")
    }

    suite.add("Flux : compteurs sFlow → débit mesuré et charge du lien") {
        var aggregator = FlowAggregator()
        let agent = ip("10.0.0.2")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        aggregator.add(FlowInterfaceCounters(exporter: agent, ifIndex: 49, speed: 100_000_000, isUp: true, inOctets: 0, outOctets: 0), at: t0)
        aggregator.add(FlowInterfaceCounters(exporter: agent, ifIndex: 49, speed: 100_000_000, isUp: true, inOctets: 600_000_000, outOctets: 75_000_000,
                                             inErrors: 4), at: t0.addingTimeInterval(60))
        let summary = try XTUnwrap(aggregator.summary(exporter: agent, window: 60, now: t0.addingTimeInterval(61), wanOverride: 49), "synthèse")
        let interface = try XTUnwrap(summary.interfaces.first { $0.index == 49 }, "interface 49")
        try expectEqual(interface.counterInBps, 80_000_000, "600 Mo en 60 s = 80 Mb/s")
        try expectEqual(interface.counterOutBps, 10_000_000, "10 Mb/s")
        try expectEqual(interface.errors, 4, "erreurs depuis la lecture précédente")
        let overview = FlowTrafficBridge.overview([summary], settings: [agent: FlowExporterSettings(wanInterface: 49)], period: .realtime,
                                                  now: t0.addingTimeInterval(61))
        try expect(abs((overview.wanLinks.first?.utilization ?? 0) - 80) < 0.01, "charge d'après la vitesse du port : 80 %")
    }

    suite.add("Flux : mémoire bornée et fenêtres (1 min, 1 h, 24 h)") {
        var limits = FlowAggregator.Limits()
        limits.hostsPerWindow = 50
        limits.remotesPerWindow = 50
        limits.conversationsPerWindow = 50
        var aggregator = FlowAggregator(limits: limits)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        // 2000 appareils en une minute : 50 gardés, le reste compté dans « autres ».
        for i in 0..<2000 {
            let host = IPv4Address(ip("10.1.0.0").value + UInt32(i))
            aggregator.add(FlowRecord(kind: .netflow5, exporter: router, source: host, destination: ip("8.8.4.4"), sourcePort: 50_000,
                                      destinationPort: 53, proto: 17, bytes: 100), at: start)
        }
        let minute = try XTUnwrap(aggregator.summary(exporter: router, window: 60, now: start.addingTimeInterval(30)), "minute")
        try expectEqual(minute.hosts.count, 50, "50 appareils gardés")
        try expectEqual(minute.total.bytes, 200_000, "total exact malgré la borne")
        try expect(minute.overflowBytes > 0, "le reste est compté")
        // Une heure et demie de trafic, une minute sur deux : fenêtres d'une minute fondues en heures.
        for m in stride(from: 0, to: 90, by: 2) {
            aggregator.add(FlowRecord(kind: .netflow5, exporter: router, source: ip("10.2.0.1"), destination: ip("1.1.1.1"), sourcePort: 50_000,
                                      destinationPort: 443, proto: 6, bytes: 1000), at: start.addingTimeInterval(Double(m) * 60))
        }
        try expect(aggregator.windowCount <= 60 + 3, "au plus 60 fenêtres d'une minute et quelques heures (\(aggregator.windowCount))")
        let later = start.addingTimeInterval(90 * 60)
        let fiveMinutes = try XTUnwrap(aggregator.summary(exporter: router, window: 300, now: later), "5 min")
        try expectEqual(fiveMinutes.total.bytes, 2000, "5 dernières minutes : 2 flux de 1000 octets")
        let day = try XTUnwrap(aggregator.summary(exporter: router, window: 86_400, now: later), "24 h")
        try expectEqual(day.total.bytes, 200_000 + 45 * 1000, "24 h : tout")
        try expect(aggregator.storedRows < 400, "lignes bornées (\(aggregator.storedRows))")
        // Un jour plus tard, il ne reste rien de plus de 24 h.
        aggregator.prune(now: later.addingTimeInterval(26 * 3600))
        try expect(aggregator.summary(exporter: router, window: 86_400, now: later.addingTimeInterval(26 * 3600))?.total.flows ?? 0 == 0,
                   "rien au-delà de 24 h")
        try expectEqual(aggregator.storedRows, 0, "tout est oublié")
    }

    suite.add("Flux : exportateurs bornés et état du collecteur") {
        var limits = FlowAggregator.Limits()
        limits.maxExporters = 2
        let collector = FlowCollector(limits: limits)
        let flow = FlowPacketBuilder.Flow(source: ip("10.0.0.5"), destination: ip("1.1.1.1"), bytes: 100)
        for last in 1...3 {
            collector.ingest(FlowPacketBuilder.netflowV5([flow]), from: ip("10.9.9.\(last)"), port: 2055)
        }
        collector.ingest([1, 2, 3, 4, 5], from: ip("10.9.9.1"), port: 2055)
        let status = collector.status()
        try expectEqual(status.received, 4, "datagrammes reçus")
        try expectEqual(status.rejected, 2, "trop d'exportateurs + format inconnu")
        try expectEqual(collector.summaries(window: 60).count, 2, "deux exportateurs gardés")
        try expect(status.exporters.first?.kinds == [.netflow5], "format retenu")
        try expect(status.lastRejection?.contains("format inconnu") == true, "dernière raison")
    }

    suite.add("Flux : ports et guide de configuration par marque") {
        let ports = FlowCollectorPorts.standard
        try expectEqual(ports.active.map(\.port), [2055, 4739, 6343], "trois ports par défaut")
        var same = ports
        same.ipfix = 2055
        try expectEqual(same.active.map(\.label), ["NetFlow et IPFIX", "sFlow"], "même port partagé")
        for brand in FlowDeviceGuide.Brand.allCases {
            let step = FlowDeviceGuide.step(brand, mac: "10.182.122.135", ports: ports)
            try expect(step.commands.contains("10.182.122.135"), "\(brand.label) : adresse du Mac")
            try expect(step.commands.contains(String(step.port)), "\(brand.label) : port")
            try expect(Brand.familiesContain(brand), "\(brand.label) : famille connue")
        }
        try expectEqual(FlowDeviceGuide.step(.fortigate, mac: "1.2.3.4", ports: ports).port, 2055, "FortiGate en NetFlow v9")
        try expectEqual(FlowDeviceGuide.step(.ciscoIPFIX, mac: "1.2.3.4", ports: ports).port, 4739, "Cisco IPFIX")
        try expectEqual(FlowDeviceGuide.step(.arubaOS, mac: "1.2.3.4", ports: ports).port, 6343, "Aruba sFlow")
    }

    suite.add("Flux : aller-retour UDP sur 127.0.0.1 (aucun autre réseau)") {
        let collector = FlowCollector(address: IPv4Address(127, 0, 0, 1))
        let errors = try collector.start(ports: [("NetFlow", 0), ("sFlow", 0)])
        defer { collector.stop() }
        try expect(errors.isEmpty, "ports ouverts : \(errors)")
        let ports = collector.boundPorts
        try expectEqual(ports.count, 2, "deux écoutes")
        let flow = FlowPacketBuilder.Flow(source: ip("10.0.0.5"), destination: ip("1.1.1.1"), sourcePort: 50_000, destinationPort: 443, bytes: 1234)
        try expect(FlowCollector.sendToSelf(FlowPacketBuilder.netflowV9([flow]), port: ports[0]), "envoi NetFlow v9")
        try expect(FlowCollector.sendToSelf(FlowPacketBuilder.sflow(agent: ip("10.0.0.2"), flows: [flow], samplingRate: 10), port: ports[1]), "envoi sFlow")
        var status = collector.status()
        for _ in 0..<40 where status.received < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
            status = collector.status()
        }
        try expectEqual(status.received, 2, "deux datagrammes reçus")
        try expectEqual(status.rejected, 0, "aucun rejet")
        try expectEqual(status.exporters.first?.address, IPv4Address(127, 0, 0, 1), "exportateur vu : 127.0.0.1")
        try expectEqual(status.exporters.first?.kinds, [.netflow9, .sflow], "les deux formats")
        collector.stop()
        try expect(!collector.isListening, "écoute arrêtée")
    }
}

private enum Brand {
    static func familiesContain(_ brand: FlowDeviceGuide.Brand) -> Bool {
        FlowDeviceGuide.Brand.families.contains(brand.family)
    }
}

/// Valeur obligatoire d'un test.
private func XTUnwrap<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message + " — valeur absente", file: file, line: line) }
    return value
}
