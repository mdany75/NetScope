import Foundation
import NetScopeCore

// Ressources (note 21) : débits sur des compteurs fixes (retour à zéro 32 bits compris), charge du
// processeur, mémoire, analyse de réponses SNMP fixes, ports les plus chargés, historique et CSV,
// sondes de Surveillance. Aucun trafic réseau : seule la lecture locale de ce Mac est essayée.

func registerResourceTests(_ suite: TestSuite) {
    suite.add("Ressources : volumes de ce Mac (lecture locale)") {
        let volumes = LocalVolumes.list()
        try expect(!volumes.isEmpty, "au moins le disque de démarrage")
        guard let startup = LocalVolumes.startup(in: volumes) else { throw TestFailure(message: "disque de démarrage introuvable", file: #fileID, line: #line) }
        try expect(startup.totalBytes > 0 && startup.availableBytes <= startup.totalBytes, "capacité cohérente")
        let percent = startup.usedPercent ?? -1
        try expect(percent >= 0 && percent <= 100, "pourcentage entre 0 et 100")
        let odd = LocalVolume(name: "Vide", path: "/x", kind: .externe, totalBytes: 0, availableBytes: 5)
        try expect(odd.usedPercent == nil && odd.availableBytes == 0, "volume de taille nulle")
    }

    suite.add("Ressources : compteur 32 bits revenu à zéro") {
        try expectEqual(ResourceMath.counterDelta(previous: 4_294_967_000, current: 1000, width: .bits32), 1296,
                        "4 294 967 295 − 4 294 967 000 + 1000 + 1")
        try expectEqual(ResourceMath.counterDelta(previous: 10, current: 25, width: .bits32), 15, "différence simple")
        try expect(ResourceMath.counterDelta(previous: 5_000_000_000, current: 10, width: .bits64) == nil,
                   "un compteur 64 bits qui recule a été remis à zéro")
        try expect(ResourceMath.counterDelta(previous: 5_000_000_000, current: 10, width: .bits32) == nil,
                   "valeur hors des 32 bits : pas un retour à zéro")
    }

    suite.add("Ressources : débit et pourcentage du lien") {
        // 625 000 000 octets en 10 s = 500 Mb/s sur un lien de 1 Gb/s.
        let a = TrafficCounters(inOctets: 1_000_000, outOctets: 2_000_000, width: .bits64, speedMbps: 1000)
        let b = TrafficCounters(inOctets: 626_000_000, outOctets: 14_500_000, width: .bits64, speedMbps: 1000)
        let rate = ResourceMath.rate(from: a, to: b, seconds: 10)
        try expectEqual(rate.inBitsPerSecond, 500_000_000, "débit entrant")
        try expectEqual(rate.outBitsPerSecond, 10_000_000, "débit sortant")
        try expectEqual(rate.inPercent, 50, "50 % du lien en entrée")
        try expectEqual(rate.outPercent, 1, "1 % en sortie")
        try expectEqual(rate.peakPercent, 50, "le sens le plus chargé")
        // Sans vitesse connue : débit, mais pas de pourcentage.
        var c = b
        c.speedMbps = nil
        var d = a
        d.speedMbps = nil
        try expect(ResourceMath.rate(from: d, to: c, seconds: 10).inPercent == nil, "pas de % sans vitesse")
    }

    suite.add("Ressources : retour à zéro 32 bits pris en compte, remise à zéro écartée") {
        // ifInOctets (Counter32) d'un port 100 Mb/s : 4 294 960 000 puis 2 500 000 en 5 s.
        let before = TrafficCounters(inOctets: 4_294_960_000, outOctets: 100, width: .bits32, speedMbps: 100)
        let after = TrafficCounters(inOctets: 2_500_000, outOctets: 200, width: .bits32, speedMbps: 100)
        let rate = ResourceMath.rate(from: before, to: after, seconds: 5)
        // (4 294 967 295 − 4 294 960 000 + 2 500 000 + 1) × 8 / 5 = 4 011 673,6 b/s.
        try expectEqual(rate.inBitsPerSecond, 4_011_673.6, "débit après le tour du compteur")
        try expect(abs((rate.inPercent ?? 0) - 4.0116736) < 0.0001, "≈ 4 % du lien")
        // Remise à zéro de l'agent prise pour un tour : débit impossible sur 10 Mb/s → nil.
        let reboot = ResourceMath.rate(from: TrafficCounters(inOctets: 4_000_000_000, outOctets: 0, width: .bits32, speedMbps: 10),
                                       to: TrafficCounters(inOctets: 10, outOctets: 0, width: .bits32, speedMbps: 10), seconds: 10)
        try expect(reboot.inBitsPerSecond == nil, "un « tour » qui dépasse le lien est une remise à zéro")
        // Passage de 32 à 64 bits : rien à comparer.
        let mixed = ResourceMath.rate(from: before, to: TrafficCounters(inOctets: 9, outOctets: 9, width: .bits64), seconds: 5)
        try expect(mixed.inBitsPerSecond == nil && mixed.outBitsPerSecond == nil, "largeurs différentes")
        // Counter32 d'un port 1 Gb/s relevé toutes les 60 s : un deuxième tour est possible → nil.
        let slow = ResourceMath.rate(from: TrafficCounters(inOctets: 1_000, outOctets: 0, width: .bits32, speedMbps: 1000),
                                     to: TrafficCounters(inOctets: 2_000_000_000, outOctets: 0, width: .bits32, speedMbps: 1000), seconds: 60)
        try expect(slow.inBitsPerSecond == nil, "Counter32 ambigu sur 60 s à 1 Gb/s")
        // Même port relevé toutes les 30 s : un seul tour possible, débit fiable.
        let fast = ResourceMath.rate(from: TrafficCounters(inOctets: 1_000, outOctets: 0, width: .bits32, speedMbps: 1000),
                                     to: TrafficCounters(inOctets: 1_000_001_000, outOctets: 0, width: .bits32, speedMbps: 1000), seconds: 30)
        try expect(fast.inBitsPerSecond != nil, "Counter32 fiable sur 30 s à 1 Gb/s")
    }

    suite.add("Ressources : erreurs et rejets nouveaux") {
        let a = TrafficCounters(inOctets: 0, outOctets: 0, inErrors: 10, outErrors: 2, inDiscards: 5, outDiscards: 0)
        let b = TrafficCounters(inOctets: 0, outOctets: 0, inErrors: 13, outErrors: 2, inDiscards: 9, outDiscards: 1)
        let rate = ResourceMath.rate(from: a, to: b, seconds: 1)
        try expectEqual(rate.newErrors, 3, "trois nouvelles erreurs")
        try expectEqual(rate.newDiscards, 5, "cinq nouveaux rejets")
        let reset = ResourceMath.rate(from: b, to: a, seconds: 1)
        try expectEqual(reset.newErrors, 0, "un compteur d'erreurs remis à zéro ne compte rien (sortie inchangée)")
    }

    suite.add("Ressources : charge du processeur par cœur (tics fixes, retour à zéro)") {
        let before = [CPUTicks(user: 100, system: 50, idle: 850), CPUTicks(user: 0, system: 0, idle: 4_294_967_000)]
        let after = [CPUTicks(user: 400, system: 150, idle: 1450), CPUTicks(user: 100, system: 0, idle: 604)]
        guard let load = CPUMath.load(previous: before, current: after) else { throw TestFailure(message: "charge absente", file: #fileID, line: #line) }
        // Cœur 1 : 300 + 100 occupés sur 1000 → 40 %. Cœur 2 : 100 occupés, 900 au repos (après le tour) → 10 %.
        try expectEqual(load.perCore, [40, 10], "charge par cœur")
        try expectEqual(load.total, 25, "moyenne pondérée")
        try expectEqual(load.user, 20, "part utilisateur")
        try expectEqual(load.system, 5, "part système")
        try expect(CPUMath.load(previous: before, current: [after[0]]) == nil, "nombre de cœurs différent")
        try expectEqual(CPULoad.fromPercentages([12, 30, 150])?.perCore, [12, 30, 100], "hrProcessorLoad borné à 100")
    }

    suite.add("Ressources : mémoire de ce Mac comme le Moniteur d'activité") {
        let page: UInt64 = 16_384
        let memory = MemoryStats.mac(pageSize: page, totalBytes: 16 * 1_073_741_824, internalPages: 400_000, purgeablePages: 20_000,
                                     externalPages: 150_000, wiredPages: 120_000, compressorPages: 60_000,
                                     pressureLevel: 2, memorystatusLevel: 38)
        try expectEqual(memory.appBytes, 380_000 * page, "apps = internes − purgeables")
        try expectEqual(memory.usedBytes, (380_000 + 120_000 + 60_000) * page, "utilisée = apps + câblée + compressée")
        try expectEqual(memory.cachedBytes, 170_000 * page, "cache = fichiers + purgeables")
        try expectEqual(memory.pressure, .warning, "niveau 2 : pression élevée")
        try expectEqual(memory.pressurePercent, 62, "100 − memorystatus_level")
        try expect(abs(memory.usedPercent - 53.40576171875) < 0.0001, "pourcentage utilisé")
    }

    suite.add("Ressources : réponses SNMP fixes (HOST-RESOURCES-MIB)") {
        let loads = [SNMPVarBind(oid: SNMPResourceOIDs.hrProcessorLoad.appending(196608), value: .integer(12)),
                     SNMPVarBind(oid: SNMPResourceOIDs.hrProcessorLoad.appending(196609), value: .integer(48)),
                     SNMPVarBind(oid: SNMPResourceOIDs.hrProcessorLoad.appending(196610), value: .noSuchInstance)]
        try expectEqual(SNMPResourceParse.processorLoads(loads), [12, 48], "un pourcentage par processeur")

        // Linux (net-snmp) : Physical memory compte le cache et les tampons, retirés comme `free`.
        let ram: SNMPValue = .oid(SNMPResourceOIDs.hrStorageRam)
        let other: SNMPValue = .oid("1.3.6.1.2.1.25.2.1.1")
        let storages = SNMPResourceParse.storages(
            type: [1: ram, 3: other, 6: other, 7: other, 31: .oid("1.3.6.1.2.1.25.2.1.4")],
            descr: [1: .octetString(Array("Physical memory".utf8)), 3: .octetString(Array("Virtual memory".utf8)),
                    6: .octetString(Array("Memory buffers".utf8)), 7: .octetString(Array("Cached memory".utf8)),
                    31: .octetString(Array("/".utf8))],
            units: [1: .integer(1024), 3: .integer(1024), 6: .integer(1024), 7: .integer(1024), 31: .integer(4096)],
            size: [1: .integer(8_000_000), 3: .integer(10_000_000), 6: .integer(8_000_000), 7: .integer(2_000_000), 31: .integer(-1)],
            used: [1: .integer(6_000_000), 3: .integer(6_500_000), 6: .integer(250_000), 7: .integer(1_750_000), 31: .integer(10)])
        try expectEqual(storages.first { $0.index == 31 }?.size, 4_294_967_295, "Integer32 négatif relu comme non signé")
        guard let memory = SNMPResourceParse.memory(from: storages) else { throw TestFailure(message: "mémoire absente", file: #fileID, line: #line) }
        try expectEqual(memory.totalBytes, 8_000_000 * 1024, "taille × unité")
        try expectEqual(memory.usedBytes, 4_000_000 * 1024, "utilisée sans tampons ni cache")
        try expectEqual(memory.cachedBytes, 2_000_000 * 1024, "cache et tampons")

        // Windows : « Physical Memory », sans cache séparé.
        let windows = SNMPResourceParse.storages(type: [4: ram], descr: [4: .octetString(Array("Physical Memory".utf8))],
                                                 units: [4: .integer(65536)], size: [4: .integer(262_000)], used: [4: .integer(131_000)])
        try expectEqual(SNMPResourceParse.memory(from: windows)?.usedPercent, 50, "Windows : moitié utilisée")
        try expect(SNMPResourceParse.memory(from: []) == nil, "pas de hrStorageRam : rien")

        let cisco = SNMPResourceParse.ciscoMemory(names: [1: .octetString(Array("Processor".utf8)), 2: .octetString(Array("I/O".utf8))],
                                                  used: [1: .gauge32(300_000_000), 2: .gauge32(10)],
                                                  free: [1: .gauge32(700_000_000), 2: .gauge32(90)])
        try expectEqual(cisco?.usedPercent, 30, "pool Processor")
    }

    suite.add("Ressources : compteurs IF-MIB (64 bits préférés, 32 bits, vitesse)") {
        func s(_ text: String) -> SNMPValue { .octetString(Array(text.utf8)) }
        let ports = SNMPResourceParse.portCounters(
            descr: [1: s("GigabitEthernet1/0/1"), 2: s("GigabitEthernet1/0/2"), 3: s("Vlan1"), 4: s("fa0")],
            name: [1: s("Gi1/0/1"), 2: s("Gi1/0/2"), 3: s("Vl1")], alias: [1: s("Uplink cœur")],
            oper: [1: .integer(1), 2: .integer(2), 3: .integer(1), 4: .integer(1)],
            hcIn: [1: .counter64(9_000_000_000), 2: .counter64(0), 3: .counter64(5)],
            hcOut: [1: .counter64(8_000_000_000), 2: .counter64(0), 3: .counter64(6)],
            in32: [4: .counter32(4_000_000_000)], out32: [4: .counter32(12)],
            highSpeed: [1: .gauge32(1000), 2: .gauge32(0), 3: .gauge32(0)],
            speed: [1: .gauge32(1_000_000_000), 2: .gauge32(100_000_000), 3: .gauge32(4_294_967_295), 4: .gauge32(10_000_000)],
            inErrors: [1: .counter32(4)], outErrors: [:], inDiscards: [1: .counter32(1)], outDiscards: [:])
        try expectEqual(ports.map(\.name), ["Gi1/0/1", "Gi1/0/2", "Vl1", "fa0"], "ifName, sinon ifDescr")
        try expectEqual(ports[0].counters.width, .bits64, "ifHCInOctets préféré")
        try expectEqual(ports[0].counters.speedMbps, 1000, "ifHighSpeed")
        try expectEqual(ports[0].alias, "Uplink cœur", "ifAlias")
        try expectEqual(ports[0].counters.inErrors, 4, "ifInErrors")
        try expectEqual(ports[1].counters.speedMbps, 100, "ifHighSpeed nul : ifSpeed")
        try expect(!ports[1].isUp, "ifOperStatus 2 : inactif")
        try expect(ports[2].counters.speedMbps == nil, "ifSpeed plafonné sans ifHighSpeed : inconnue")
        try expectEqual(ports[3].counters.width, .bits32, "sans ifXTable : compteurs 32 bits")
        try expectEqual(ports[3].counters.inOctets, 4_000_000_000, "ifInOctets")
        let list = ports.map { (index: $0.index, name: $0.name, descr: "", alias: $0.alias) }
        try expectEqual(SNMPResourceParse.findPort("gi1/0/2", in: list), 2, "nom sans tenir compte de la casse")
        try expectEqual(SNMPResourceParse.findPort("Uplink cœur", in: list), 1, "par la description")
        try expect(SNMPResourceParse.findPort("Gi9/9/9", in: list) == nil, "port inconnu")
    }

    suite.add("Ressources : réponse SNMP fixe décodée (Counter64 ifHCInOctets)") {
        // GetResponse v2c « public », request-id 42 : ifHCInOctets.3 = Counter64 0x0102030405060708.
        let bytes: [UInt8] = [
            0x30, 0x34, 0x02, 0x01, 0x01, 0x04, 0x06, 0x70, 0x75, 0x62, 0x6C, 0x69, 0x63,
            0xA2, 0x27, 0x02, 0x04, 0x00, 0x00, 0x00, 0x2A, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00,
            0x30, 0x19, 0x30, 0x17, 0x06, 0x0B, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x1F, 0x01, 0x01, 0x01, 0x06, 0x03,
            0x46, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        ]
        let message = try SNMPMessage(decoding: bytes)
        try expectEqual(message.pdu.requestID, 42, "request-id")
        let column = SNMPResourceParse.column(message.pdu.varbinds, under: SNMPResourceOIDs.ifHCInOctets)
        try expectEqual(column[3]?.uint64Value, 0x0102_0304_0506_0708, "Counter64 lu en entier")
        // Aller-retour d'une réponse avec Counter32 et Gauge32 (ifInOctets, ifHighSpeed).
        let pdu = SNMPPDU(type: .response, requestID: 7, varbinds: [
            SNMPVarBind(oid: SNMPResourceOIDs.ifInOctets.appending(5), value: .counter32(4_294_967_295)),
            SNMPVarBind(oid: SNMPResourceOIDs.ifHighSpeed.appending(5), value: .gauge32(10_000)),
        ])
        let decoded = try SNMPMessage(decoding: SNMPMessage(community: "lecture", pdu: pdu).encoded())
        try expectEqual(SNMPResourceParse.column(decoded.pdu.varbinds, under: SNMPResourceOIDs.ifInOctets)[5], .counter32(4_294_967_295),
                        "Counter32 maximal")
        try expectEqual(SNMPResourceParse.linkSpeed(highSpeed: decoded.pdu.varbinds[1].value, speed: nil), 10_000, "10 Gb/s")
    }

    suite.add("Ressources : ports les plus chargés") {
        func port(_ index: Int, _ name: String, inOctets: UInt64, outOctets: UInt64, speed: UInt64?, up: Bool = true) -> SNMPPortCounters {
            SNMPPortCounters(index: index, name: name, isUp: up,
                             counters: TrafficCounters(inOctets: inOctets, outOctets: outOctets, speedMbps: speed))
        }
        let before = [port(1, "Gi1/0/1", inOctets: 0, outOctets: 0, speed: 1000), port(2, "Gi1/0/2", inOctets: 0, outOctets: 0, speed: 100),
                      port(3, "Gi1/0/3", inOctets: 0, outOctets: 0, speed: nil), port(4, "Gi1/0/4", inOctets: 0, outOctets: 0, speed: 1000, up: false)]
        // 10 s : port 1 à 400 Mb/s (40 %), port 2 à 90 Mb/s en sortie (90 %), port 3 à 800 Mb/s sans vitesse.
        let after = [port(1, "Gi1/0/1", inOctets: 500_000_000, outOctets: 0, speed: 1000),
                     port(2, "Gi1/0/2", inOctets: 0, outOctets: 112_500_000, speed: 100),
                     port(3, "Gi1/0/3", inOctets: 1_000_000_000, outOctets: 0, speed: nil),
                     port(4, "Gi1/0/4", inOctets: 0, outOctets: 0, speed: 1000, up: false),
                     port(5, "Gi1/0/5", inOctets: 1, outOctets: 1, speed: 1000)]
        let loads = TopPorts.loads(previous: before, current: after, seconds: 10)
        try expectEqual(loads.count, 4, "un port absent du premier relevé est écarté")
        let top = TopPorts.rank(loads, limit: 3)
        try expectEqual(top.map(\.name), ["Gi1/0/2", "Gi1/0/1", "Gi1/0/3"], "% du lien d'abord, puis débit ; port inactif écarté")
        try expectEqual(top[0].rate.outPercent, 90, "90 % en sortie")
    }

    suite.add("Ressources : historique de quelques minutes et export CSV") {
        var timeline = ResourceTimeline(window: 60, capacity: 100)
        timeline.declare([ResourceColumn(id: "cpu", title: "Processeur (%)"), ResourceColumn(id: "in", title: "Entrée; b/s")])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for step in 0..<10 {
            timeline.append(ResourceSample(date: start.addingTimeInterval(Double(step) * 10),
                                           values: step == 3 ? ["cpu": 12.5] : ["cpu": Double(step), "in": 1000 * Double(step)]))
        }
        try expectEqual(timeline.samples.count, 7, "relevés de la dernière minute seulement (30 à 90 s)")
        try expectEqual(timeline.series("in").first ?? nil, nil, "trou dans la courbe quand la série manque")
        try expectEqual(timeline.maximum(["cpu"]), 12.5, "maximum sur la fenêtre")
        try expect(abs((timeline.average("cpu") ?? 0) - (12.5 + 4 + 5 + 6 + 7 + 8 + 9) / 7) < 1e-9, "moyenne")
        let csv = timeline.csv(timeZone: TimeZone(identifier: "UTC")!)
        let lines = csv.split(separator: "\n").map(String.init)
        try expectEqual(lines.first, "Date;Processeur (%);\"Entrée; b/s\"", "en-tête, champ avec « ; » entre guillemets")
        try expectEqual(lines[1], "2027-01-15 08:00:30;12,50;", "décimale à la virgule, valeur absente vide")
        try expectEqual(lines[2], "2027-01-15 08:00:40;4;4000", "entiers sans décimales")
        var capped = ResourceTimeline(window: 3600, capacity: 3)
        for step in 0..<5 { capped.append(ResourceSample(date: start.addingTimeInterval(Double(step)), values: ["x": 1])) }
        try expectEqual(capped.samples.count, 3, "plafond de relevés")
    }

    suite.add("Ressources : mise en forme française") {
        try expectEqual(ResourceFormat.bitsPerSecond(812_000), "812\u{00A0}kb/s", "kb/s")
        try expectEqual(ResourceFormat.bitsPerSecond(12_400_000), "12,4\u{00A0}Mb/s", "Mb/s")
        try expectEqual(ResourceFormat.bitsPerSecond(1_050_000_000), "1,05\u{00A0}Gb/s", "Gb/s")
        try expectEqual(ResourceFormat.percent(23.4), "23\u{00A0}%", "pourcentage arrondi")
        try expectEqual(ResourceFormat.percent(4.46), "4,5\u{00A0}%", "une décimale sous 10 %")
        try expectEqual(ResourceFormat.memory(17_179_869_184), "16\u{00A0}Go", "mémoire en Go (base 1024)")
        try expectEqual(ResourceFormat.memory(12_025_908_428), "11,2\u{00A0}Go", "décimale")
    }

    suite.add("Ressources : sondes Processeur, Mémoire et Port saturé") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cpu = MonProbe(name: "CPU", kind: .cpu, target: "ce Mac")
        cpu.resourceLimit = 80
        let calm = MonResourceChecks.evaluateCPU(cpu, load: CPULoad(total: 35, perCore: [30, 40]), source: nil, now: now)
        try expect(calm.problem == nil, "35 % sous le seuil")
        try expectEqual(calm.value, "Processeur 35\u{00A0}% · 2 cœurs", "valeur affichée")
        let busy = MonResourceChecks.evaluateCPU(cpu, load: CPULoad(total: 93, perCore: [93]), source: "HOST-RESOURCES-MIB", now: now)
        try expectEqual(busy.problem, "Processeur à 93\u{00A0}% > 80\u{00A0}%", "alerte au-dessus du seuil")

        let memoryProbe = MonProbe(name: "Mém", kind: .memory, target: "10.10.0.10")
        let pressure = MemoryStats(totalBytes: 100, usedBytes: 50, pressure: .critical)
        try expectEqual(MonResourceChecks.evaluateMemory(memoryProbe, memory: pressure, now: now).problem, "Pression mémoire critique",
                        "pression critique même sous le seuil (90 % par défaut)")
        try expect(MonResourceChecks.evaluateMemory(memoryProbe, memory: MemoryStats(totalBytes: 100, usedBytes: 95), now: now).problem != nil,
                   "95 % > 90 %")

        var portProbe = MonProbe(name: "Uplink", kind: .portLoad, target: "10.182.122.2")
        portProbe.resourcePort = "Gi1/0/48"
        let saturated = TrafficRate(inBitsPerSecond: 120_000_000, outBitsPerSecond: 870_000_000, inPercent: 12, outPercent: 87,
                                    newErrors: 2, seconds: 3)
        let result = MonResourceChecks.evaluatePort(portProbe, port: "Gi1/0/48", rate: saturated, speedMbps: 1000, now: now)
        try expectEqual(result.problem, "Gi1/0/48 saturé en sortie\u{00A0}: 87\u{00A0}% du lien > 80\u{00A0}% · 2 nouvelles erreurs sur Gi1/0/48",
                        "saturation et erreurs")
        try expect(result.value.contains("87\u{00A0}% de 1\u{00A0}Gb/s"), "valeur avec la vitesse du lien")
        let down = MonResourceChecks.evaluatePort(portProbe, port: "Gi1/0/48", rate: saturated, speedMbps: 1000, isUp: false, now: now)
        try expect(!down.reachable, "port inactif : échec")
        let reset = MonResourceChecks.evaluatePort(portProbe, port: "Gi1/0/48",
                                                   rate: TrafficRate(inBitsPerSecond: nil, outBitsPerSecond: nil, seconds: 3),
                                                   speedMbps: 1000, now: now)
        try expect(reset.reachable && reset.problem == nil, "remise à zéro : ni alerte ni échec")

        try expect(MonResourceChecks.isLocal("Ce Mac") && MonResourceChecks.isLocal(" localhost "), "ce Mac reconnu")
        try expect(!MonResourceChecks.isLocal("10.182.122.2"), "adresse d'un agent")
        try expect(!MonResourceChecks.isLocal("mac"), "un hôte nommé « mac » n'est pas ce Mac")
        try expectEqual(portProbe.conditionSummary, "Alerte si Gi1/0/48 > 80\u{00A0}% du lien", "résumé de la condition")
    }

    suite.add("Ressources : sonde enregistrée relue (seuil et port)") {
        var probe = MonProbe(name: "Uplink", kind: .portLoad, target: "10.182.122.2")
        probe.resourceLimit = 75
        probe.resourcePort = "Te1/1/1"
        let data = try JSONEncoder().encode(probe)
        let decoded = try JSONDecoder().decode(MonProbe.self, from: data)
        try expectEqual(decoded, probe, "aller-retour JSON")
        try expectEqual(decoded.kind.label, "Port saturé > X\u{00A0}%", "libellé du type")
    }

    suite.add("Ressources : lecture locale de ce Mac (aucun trafic)") {
        let ticks = LocalResources.cpuTicks()
        try expect(!ticks.isEmpty, "au moins un cœur")
        guard let memory = LocalResources.memory() else { throw TestFailure(message: "mémoire illisible", file: #fileID, line: #line) }
        try expect(memory.totalBytes > 0 && memory.usedBytes <= memory.totalBytes, "mémoire cohérente")
        let interfaces = LocalResources.interfaces()
        try expect(interfaces.contains { $0.name == "lo0" }, "lo0 présent dans NET_RT_IFLIST2")
        try expect(!interfaces.contains { $0.name == "lo0" && $0.isRelevant }, "la boucle locale n'est pas montrée")
    }
}
