import Foundation
import NetScopeCore

// Note 24 : FortiGate et FortiSwitch gérés par FortiLink. Aucun réseau : les réponses de l'API
// REST viennent de FortinetFixtures.

func registerFortinetTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_700_000)

    suite.add("FortiGate : petites conversions (vitesse, VLAN, port, modèle, dernière vue)") {
        try expectEqual(FortiParse.speedMbps(1000), 1000, "nombre")
        try expectEqual(FortiParse.speedMbps("1000full"), 1000, "1000full")
        try expectEqual(FortiParse.speedMbps("10G"), 10_000, "10G")
        try expectEqual(FortiParse.speedMbps("2.5G"), 2500, "2.5G")
        try expectEqual(FortiParse.speedMbps("auto"), nil, "auto")
        try expectEqual(FortiParse.speedMbps(1_000_000_000), 1000, "valeur en b/s")
        try expectEqual(FortiParse.duplex("100half", nil), "half", "duplex dans la vitesse")
        try expectEqual(FortiParse.vlanID(fromName: "vlan40"), 40, "vlan40")
        try expectEqual(FortiParse.vlanID(fromName: "_default"), 1, "_default")
        try expectEqual(FortiParse.vlanID(fromName: "quarantine"), 4093, "quarantine")
        try expectEqual(FortiParse.vlanID(fromName: "voix-siege"), nil, "nom libre")
        try expectEqual(FortiParse.portNumber("port12"), 12, "port12")
        try expectEqual(FortiParse.portNumber("internal"), nil, "sans chiffre")
        try expectEqual(FortiParse.fortiSwitchModel(serial: "S248EPTF21000123"), "FS-248E-POE", "S248EP")
        try expectEqual(FortiParse.fortiSwitchModel(serial: "S124FPTF22000456"), "FS-124F-POE", "S124FP")
        try expectEqual(FortiParse.fortiSwitchModel(serial: "S108FFTV21000789"), "FS-108F", "S108F")
        try expectEqual(FortiConvert.copperPorts(model: "FS-248E-POE"), 48, "248E : 48 ports cuivre")
        try expectEqual(FortiConvert.copperPorts(model: "FS-108F"), 8, "108F : 8 ports cuivre")
        try expectEqual(FortiConvert.copperPorts(model: "FortiSwitch"), nil, "modèle inconnu")
        try expectEqual(FortiParse.lastSeen(12, now: now), now.addingTimeInterval(-12), "secondes écoulées")
        try expectEqual(FortiParse.lastSeen(1_793_699_000, now: now), Date(timeIntervalSince1970: 1_793_699_000), "horodatage Unix")
        try expectEqual(FortiParse.lastSeen("1793699000000", now: now), Date(timeIntervalSince1970: 1_793_699_000), "millisecondes en texte")
        try expectEqual(FortiParse.mac("F4-EE-08-3C-72-A1"), MACAddress("f4:ee:08:3c:72:a1"), "MAC à tirets")
        try expectEqual(FortiParse.ipv4("10.255.1.2/24"), IPv4Address("10.255.1.2"), "IP avec masque")
    }

    suite.add("FortiGate : réglages de connexion et adresse sans jeton") {
        var config = FortiGateConfig(host: " https://10.182.122.1:8443/ng ", port: 443, vdom: "root")
        try expectEqual(config.cleanHost, "10.182.122.1", "schéma, port et chemin retirés")
        try expectEqual(config.effectivePort, 8443, "port saisi avec l'adresse")
        try expect(config.isValid, "adresse valide")
        let url = FortiURLSessionTransport.url(config: config, path: FortiPaths.systemStatus, query: [])
        try expectEqual(url?.absoluteString, "https://10.182.122.1:8443/api/v2/monitor/system/status?vdom=root", "adresse HTTPS avec vdom")
        config.vdom = ""
        config.host = "fgt.siege.local"
        try expectEqual(FortiURLSessionTransport.url(config: config, path: FortiPaths.arp, query: [])?.absoluteString,
                        "https://fgt.siege.local:443/api/v2/monitor/network/arp", "sans vdom")
        config.host = "10.0.0.1; rm"
        try expect(!config.isValid, "caractères interdits refusés")
        try expect(!FortiGateConfig(host: "").isValid, "adresse vide")
        // Le jeton ne fait jamais partie de l'adresse.
        let transport = FortiURLSessionTransport(config: FortiGateConfig(host: "10.182.122.1"), token: FortiFixtures.token)
        let shown = FortiURLSessionTransport.url(config: transport.config, path: FortiPaths.dhcp, query: [URLQueryItem(name: "poe", value: "true")])
        try expect(!(shown?.absoluteString ?? "").contains(FortiFixtures.token), "jeton absent de l'adresse")
    }

    suite.add("FortiGate : état du système (7.4, 6.4, sans enveloppe)") {
        let s74 = FortiParsers.system(Data(FortiFixtures.status74.utf8))
        try expectEqual(s74?.hostname, "FGT-SIEGE", "nom d'hôte 7.4")
        try expectEqual(s74?.model, "FortiGate-100F", "modèle 7.4")
        try expectEqual(s74?.version, "v7.4.4", "version dans l'enveloppe")
        try expectEqual(s74?.serial, "FG100FTK22004711", "série")
        try expectEqual(s74?.build, 2662, "build")
        try expectEqual(s74?.versionLabel, "FortiOS v7.4.4 (build 2662)", "libellé")
        try expect(s74?.majorMinor.map { $0.0 == 7 && $0.1 == 4 } == true, "version majeure et mineure")
        let s64 = FortiParsers.system(Data(FortiFixtures.status64.utf8))
        try expectEqual(s64?.model, "FortiGate-60F", "modèle 6.4")
        try expectEqual(s64?.version, "v6.4.12", "version 6.4")
        let bare = FortiParsers.system(Data(FortiFixtures.bareStatus.utf8))
        try expectEqual(bare?.model, "FortiGate-40F", "« FGT40F » sans enveloppe")
        try expectEqual(bare?.hostname, "FGT-NU", "nom sans enveloppe")
        try expect(FortiParsers.system(Data("<html>login</html>".utf8)) == nil, "page HTML : illisible")
    }

    suite.add("FortiGate : FortiSwitch gérés, trois formes de réponse") {
        let list = FortiParsers.managedSwitches(Data(FortiFixtures.switches74.utf8)) ?? []
        try expectEqual(list.count, 2, "deux switchs (7.4)")
        let entrepot = list[0]
        try expectEqual(entrepot.name, "FSW-ENTREPOT", "nom")
        try expectEqual(entrepot.model, "FS-248E-POE", "modèle déduit de la série")
        try expectEqual(entrepot.firmware, "v7.2.5", "version du logiciel")
        try expectEqual(entrepot.fortilinkIP, IPv4Address("10.255.1.2"), "adresse FortiLink")
        try expectEqual(entrepot.connected, true, "connecté")
        try expectEqual(entrepot.poeBudgetW, 370, "budget PoE")
        try expectEqual(entrepot.port(named: "port1")?.poeDetection, .deliveringPower, "PoE délivré")
        try expectEqual(entrepot.port(named: "port1")?.nativeVLANID, 40, "VLAN natif déduit")
        try expect(entrepot.port(named: "port49")?.isFortiLink == true, "port FortiLink")
        try expect(entrepot.port(named: "port47")?.isISL == true, "lien inter-switch")
        try expectEqual(entrepot.port(named: "port47")?.peerName, "FSW-QUAI", "voisin ISL")
        try expectEqual(entrepot.port(named: "port2")?.linkUp, false, "port sans lien")
        try expectEqual(entrepot.port(named: "port2")?.speedMbps, nil, "pas de vitesse sans lien")

        let legacy = FortiParsers.managedSwitches(Data(FortiFixtures.legacy64.utf8)) ?? []
        try expectEqual(legacy.count, 1, "dictionnaire indexé par série (6.4)")
        try expectEqual(legacy[0].model, "FS-108F", "modèle 6.4")
        try expectEqual(legacy[0].fortilinkIP, IPv4Address("10.255.1.4"), "« fsw_ip »")
        try expectEqual(legacy[0].port(named: "port2")?.speedMbps, 100, "« 100half »")
        try expectEqual(legacy[0].port(named: "port2")?.duplex, "half", "duplex")
        try expectEqual(legacy[0].firmware, "v6.4.11", "version 6.4")

        let bare = FortiParsers.managedSwitches(Data(FortiFixtures.bareSwitches.utf8)) ?? []
        try expectEqual(bare.count, 1, "tableau nu")
        try expectEqual(bare[0].switchID, "S124FFTF23000999", "identifiant = série quand le nom manque")
        try expectEqual(bare[0].ports.count, 2, "ports « name »")
        try expectEqual(bare[0].ports[1].linkUp, nil, "état absent accepté")
        try expectEqual(FortiParsers.managedSwitches(Data(#"{"results":[]}"#.utf8))?.count, 0, "aucun switch")
    }

    suite.add("FortiGate : appareils détectés, ARP, DHCP et inventaire, variantes") {
        let d74 = FortiParsers.detectedDevices(Data(FortiFixtures.detected74.utf8), now: now) ?? []
        try expectEqual(d74.count, 4, "quatre appareils (7.4)")
        try expectEqual(d74[0].switchID, "FSW-QUAI", "switch")
        try expectEqual(d74[0].portName, "port3", "port")
        try expectEqual(d74[0].vlan, 40, "VLAN")
        try expectEqual(d74[0].lastSeen, now.addingTimeInterval(-12), "dernière vue relative")
        let d64 = FortiParsers.detectedDevices(Data(FortiFixtures.detected64.utf8), now: now) ?? []
        try expectEqual(d64.count, 2, "6.4 : « switch-id », « port », « vlan »")
        try expectEqual(d64[0].mac, MACAddress("f4:ee:08:3c:72:a1"), "MAC à tirets")
        try expectEqual(d64[1].lastSeen, nil, "dernière vue absente")
        let arp = FortiParsers.arp(Data(FortiFixtures.arp74.utf8)) ?? []
        try expectEqual(arp.count, 4, "ARP")
        let dhcp = FortiParsers.dhcpLeases(Data(FortiFixtures.dhcp74.utf8)) ?? []
        try expectEqual(dhcp.count, 2, "DHCP liste")
        try expect(dhcp[1].reserved, "réservation")
        let dhcp64 = FortiParsers.dhcpLeases(Data(FortiFixtures.dhcp64.utf8)) ?? []
        try expectEqual(dhcp64.count, 2, "DHCP en dictionnaire par interface")
        try expectEqual(dhcp64.first { $0.ip == IPv4Address("10.10.0.10") }?.interface, "vlan100", "interface = clé")
        let users = FortiParsers.userDevices(Data(FortiFixtures.users74.utf8)) ?? []
        try expectEqual(users.count, 2, "inventaire")
        try expectEqual(users[0].hostname, "CAM-QUAI-01", "nom")
        try expectEqual(users[0].portName, "port3", "port de l'inventaire")
        try expectEqual(FortiParsers.detectedDevices(Data("pas du json".utf8), now: now) == nil, true, "illisible")
    }

    suite.add("FortiGate : lecture complète en 7.4 (repli PoE absent noté)") {
        let transport = FortiFakeTransport(FortiFixtures.v74())
        let report = try await FortiGateReader(transport: transport, tokenForRedaction: FortiFixtures.token).read(now: now)
        try expectEqual(report.system.hostname, "FGT-SIEGE", "système")
        try expectEqual(report.switches.count, 2, "switchs")
        try expectEqual(report.detected.count, 4, "détectés")
        try expectEqual(report.arp.count, 4, "ARP")
        try expectEqual(report.dhcp.count, 2, "DHCP")
        try expectEqual(report.userDevices.count, 2, "inventaire")
        try expect(!transport.requested.contains(FortiPaths.switchLegacy), "pas de repli quand managed-switch/status répond")
        try expectEqual(report.calls.first { $0.path == FortiPaths.poe }?.outcome, .absent, "PoE à part : absent (404)")
        // Configuration et compteurs fusionnés.
        let port1 = report.switches[0].port(named: "port1")
        try expectEqual(port1?.description, "Caméra quai", "description de la configuration")
        try expectEqual(port1?.rxBytes, 3_400_000, "compteurs")
        try expectEqual(report.switches[0].port(named: "port3")?.rxErrors, 15, "erreurs + CRC")
        try expectEqual(report.switches[0].port(named: "port3")?.poeEnabled, false, "PoE désactivé en configuration")
        try expectEqual(report.switches[0].description, "Entrepôt · baie A", "description du switch")
        try expect(Set(transport.requested).isSubset(of: Set(FortiPaths.all)), "seulement les adresses prévues (lecture)")
    }

    suite.add("FortiGate : lecture 6.4 (ancienne adresse, ARP refusé, inventaire absent)") {
        let transport = FortiFakeTransport(FortiFixtures.v64())
        let report = try await FortiGateReader(transport: transport).read(now: now)
        try expect(transport.requested.contains(FortiPaths.switchLegacy), "repli sur managed-switch")
        try expectEqual(report.switches.count, 1, "un FortiSwitch")
        try expectEqual(report.detected.count, 2, "détectés")
        try expectEqual(report.arp.count, 0, "ARP refusé : vide")
        try expectEqual(report.calls.first { $0.path == FortiPaths.arp }?.outcome, .refused, "ARP noté refusé")
        try expect(report.calls.first { $0.path == FortiPaths.arp }?.message.contains("hôtes de confiance") == true, "403 expliqué")
        try expectEqual(report.calls.first { $0.path == FortiPaths.userDevices }?.outcome, .absent, "inventaire absent")
        let snaps = FortiConvert.snapshots(from: report)
        try expectEqual(snaps.first?.host, IPv4Address("10.255.1.4"), "adresse FortiLink")
        let names = FortiConvert.names(from: report)
        try expectEqual(names[MACAddress("f4:ee:08:3c:72:a1")!], "SRV-AD-01", "nom tiré du bail DHCP")
    }

    suite.add("FortiGate : conversion en relevés de switch (ports, VLAN, PoE, uplinks)") {
        let report = try await FortiGateReader(transport: FortiFakeTransport(FortiFixtures.v74())).read(now: now)
        let snaps = FortiConvert.snapshots(from: report)
        try expectEqual(snaps.count, 2, "un relevé par FortiSwitch")
        let entrepot = snaps[0]
        try expectEqual(entrepot.host, IPv4Address("10.255.1.2"), "hôte = adresse FortiLink")
        try expectEqual(entrepot.controllerName, "FGT-SIEGE", "via la FortiGate")
        try expect(entrepot.isViaController, "marqué « via FortiGate »")
        try expectEqual(entrepot.system.brand, "Fortinet", "marque")
        try expect(entrepot.system.descr.contains("FS-248E-POE") && entrepot.system.descr.contains("v7.2.5"), "modèle et version")
        try expectEqual(entrepot.system.location, "Entrepôt · baie A", "emplacement")
        try expectEqual(entrepot.physicalPorts.map(\.name), ["port1", "port2", "port3", "port47", "port49"], "ports physiques")
        try expectEqual(entrepot.interface(1)?.alias, "Caméra quai", "alias = description")
        try expectEqual(entrepot.interface(2)?.operStatus, .down, "port sans lien")
        try expectEqual(entrepot.pvid[3], 100, "VLAN natif")
        try expectEqual(entrepot.poeBudgetW, 370, "budget PoE")
        try expectEqual(entrepot.poeUsedW, 6, "consommation PoE")
        try expectEqual(entrepot.poePorts, [1], "PoE délivré sur port1")
        try expectEqual(entrepot.poeDetails?.first { $0.ifIndex == 1 }?.consumptionMW, 6400, "watts du port")
        try expectEqual(entrepot.uplinkInterfaces(), [47, 49], "ISL et FortiLink = uplinks")
        try expectEqual(entrepot.neighbor(on: 49)?.sysName, "FGT-SIEGE", "voisin FortiLink")
        try expectEqual(entrepot.arp[MACAddress("f4:ee:08:3c:72:a1")!], IPv4Address("10.10.0.10"), "IP depuis l'ARP de la FortiGate")
        let quai = snaps[1]
        try expectEqual(quai.fdb.count, 2, "deux caméras détectées")
        try expectEqual(quai.fdb.first { $0.ifIndex == 3 }?.vlan, 40, "VLAN de l'appareil")
        try expectEqual(quai.interface(4)?.speedMbps, 100, "vitesse")
        // Switch sans adresse FortiLink : remplacement 0.0.0.n, jamais interrogé.
        var noIP = report
        noIP.switches[1].fortilinkIP = nil
        try expectEqual(FortiConvert.snapshots(from: noIP)[1].host, IPv4Address(2), "adresse de remplacement")
    }

    suite.add("FortiGate : FortiSwitch sans PoE, « Non » plutôt que « Inconnu »") {
        let report = try await FortiGateReader(transport: FortiFakeTransport(FortiFixtures.v74())).read(now: now)
        var bare = FortiConvert.snapshots(from: report)[0]
        bare.poeDetails = []
        bare.poePorts = []
        bare.poeBudgetW = nil
        bare.poeUsedW = nil
        let status = SNMPPoELookup.status(switchName: bare.displayName, portName: "port1", in: [bare])
        try expectEqual(status?.shortLabel, "Non (sans PoE)", "colonne")
        try expectEqual(status?.isPowered, false, "pas alimenté")
        try expect(status?.detailLabel.contains("aucun port PoE") == true, "fiche : \(status?.detailLabel ?? "nil")")
        // Même relevé venu de SNMP (sans contrôleur) : impossible à dire.
        bare.controllerName = nil
        let snmp = SNMPPoELookup.status(switchName: bare.displayName, portName: "port1", in: [bare])
        try expectEqual(snmp?.shortLabel, "Inconnu", "SNMP sans POWER-ETHERNET-MIB")
    }

    suite.add("FortiGate : priorité sur SNMP pour l'emplacement, SNMP pour les autres switchs") {
        let report = try await FortiGateReader(transport: FortiFakeTransport(FortiFixtures.v74())).read(now: now)
        let cam = MACAddress("bc:ad:28:6f:01:5a")!
        let printer = MACAddress("94:dd:f8:18:15:7d")!
        let other = MACAddress("8c:16:45:2b:9e:03")!
        // SNMP voit la caméra sur un autre switch et l'imprimante et le portable sur leur port d'accès.
        let snmp = SNMPSwitchSnapshot(host: IPv4Address("10.182.122.2")!, system: SNMPSystemInfo(name: "SW-CORE-01", descr: "Cisco"),
                                      interfaces: [SNMPInterface(index: 33, name: "Gi1/0/33", operStatus: .up),
                                                   SNMPInterface(index: 14, name: "Gi1/0/14", operStatus: .up),
                                                   SNMPInterface(index: 3, name: "Gi1/0/3", operStatus: .up)],
                                      fdb: [SNMPFDBEntry(mac: cam, vlan: 40, bridgePort: 33, ifIndex: 33),
                                            SNMPFDBEntry(mac: printer, vlan: 30, bridgePort: 14, ifIndex: 14),
                                            SNMPFDBEntry(mac: other, vlan: 1, bridgePort: 3, ifIndex: 3)])
        let devices = [Device(ip: IPv4Address("192.168.50.21")!, mac: cam, switchName: "SW-CORE-01", switchPort: "Gi1/0/33"),
                       Device(ip: IPv4Address("10.182.122.111")!, mac: printer),
                       Device(ip: IPv4Address("10.182.122.113")!, mac: other),
                       Device(ip: IPv4Address("10.10.0.31")!)]
        let result = FortiLocate.apply(report, to: devices, snmp: [snmp])
        let byIP = Dictionary(uniqueKeysWithValues: result.devices.map { ($0.id, $0) })
        try expectEqual(byIP["192.168.50.21"]?.switchName, "FSW-QUAI", "FortiGate avant SNMP")
        try expectEqual(byIP["192.168.50.21"]?.switchPort, "port3", "port FortiSwitch")
        try expectEqual(byIP["192.168.50.21"]?.vlan, 40, "VLAN")
        // L'imprimante n'est vue par la FortiGate que sur le lien FortiLink : SNMP garde son port d'accès.
        try expectEqual(byIP["10.182.122.111"]?.switchName, "SW-CORE-01", "uplink FortiLink ignoré, SNMP retenu")
        try expectEqual(byIP["10.182.122.113"]?.switchPort, "Gi1/0/3", "autre switch : SNMP")
        // MAC complétée par l'ARP de la FortiGate, nom tiré de l'inventaire.
        try expectEqual(byIP["10.10.0.31"]?.mac, MACAddress("00:50:56:aa:10:31"), "MAC par l'ARP de la FortiGate")
        try expectEqual(byIP["10.10.0.31"]?.hostname, "SRV-BACKUP", "nom tiré de la FortiGate")
        try expectEqual(byIP["10.10.0.31"]?.nameSource, .fortigate, "origine FortiGate")
        try expectEqual(result.filled, 1, "une MAC complétée")
        // Un nom déjà connu n'est pas remplacé.
        var named = devices[0]
        named.hostname = "DS-2CD2143G2-I"
        let renamed = FortiLocate.applyNames(FortiConvert.names(from: report), to: [named]).devices[0]
        try expectEqual(renamed.hostname, "DS-2CD2143G2-I", "nom existant gardé")
        // Un FortiSwitch aussi relevé en SNMP (même nom) n'est compté qu'une fois.
        let controller = FortiConvert.snapshots(from: report)
        var dup = snmp
        dup.system.name = "FSW-QUAI"
        try expectEqual(FortiLocate.withoutDuplicates(snmp: [snmp, dup], controller: controller).count, 1, "doublon SNMP écarté")
    }

    suite.add("FortiGate : erreurs HTTP expliquées en français") {
        try expectEqual(FortiGateError.from(status: 401, path: "/x"), .tokenRejected, "401")
        try expectEqual(FortiGateError.from(status: 403, path: "/x"), .forbidden(path: "/x"), "403")
        try expectEqual(FortiGateError.from(status: 404, path: "/x"), .notFound(path: "/x"), "404")
        try expectEqual(FortiGateError.from(status: 200, path: "/x"), nil, "200")
        try expect(FortiGateError.tokenRejected.errorDescription!.contains("Jeton refusé"), "401 expliqué")
        let forbidden = FortiGateError.forbidden(path: FortiPaths.switchStatus).errorDescription!
        try expect(forbidden.contains("hôtes de confiance") && forbidden.contains("WiFi & Switch Controller"), "403 : hôtes de confiance et droit")
        try expect(FortiGateError.notFound(path: "/x").errorDescription!.contains("version de FortiOS"), "404 expliqué")
        try expectEqual(FortiGateError.from(urlError: URLError(.timedOut)), .timeout, "délai")
        try expect(FortiGateError.timeout.errorDescription!.contains("délai"), "délai expliqué")
        try expect(FortiGateError.http(status: 424, path: "/x").errorDescription!.contains("VDOM"), "424 : VDOM")
        try expect(FortiGateError.certificateChanged(expected: "AA", presented: "BB").errorDescription!.contains("a changé"), "certificat changé")
        // Jeton refusé : la lecture s'arrête.
        do {
            _ = try await FortiGateReader(transport: FortiFakeTransport([FortiPaths.systemStatus: (401, "")])).read(now: now)
            try expect(false, "401 doit arrêter la lecture")
        } catch let error as FortiGateError {
            try expectEqual(error, .tokenRejected, "401 levée")
        }
        // Profil sans droit sur le contrôleur de switchs : 403 sur la liste des switchs.
        var forbiddenSwitches = FortiFixtures.v74()
        forbiddenSwitches[FortiPaths.switchStatus] = (403, #"{"status":"error","http_status":403}"#)
        do {
            _ = try await FortiGateReader(transport: FortiFakeTransport(forbiddenSwitches)).read(now: now)
            try expect(false, "403 sur les switchs doit arrêter la lecture")
        } catch let error as FortiGateError {
            try expectEqual(error, .forbidden(path: FortiPaths.switchStatus), "403 levée")
        }
        // 200 avec « status: error » et http_status 403 dans le corps.
        var embedded = FortiFixtures.v74()
        embedded[FortiPaths.dhcp] = (200, #"{"http_method":"GET","status":"error","http_status":403,"vdom":"root"}"#)
        let report = try await FortiGateReader(transport: FortiFakeTransport(embedded)).read(now: now)
        try expectEqual(report.calls.first { $0.path == FortiPaths.dhcp }?.outcome, .refused, "erreur dans un corps 200")
        try expectEqual(report.dhcp.count, 0, "rien retenu")
    }

    suite.add("FortiGate : empreinte du certificat (premier contact, acceptée, changement refusé)") {
        // SHA-256("abc"), valeur de référence.
        let fp = FortiCertificatePin.fingerprint(der: Data("abc".utf8))
        try expectEqual(fp, "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD", "SHA-256")
        try expect(FortiCertificatePin.isValid(fp), "64 chiffres hexadécimaux")
        try expect(!FortiCertificatePin.isValid("AB:CD"), "trop court")
        try expectEqual(FortiCertificatePin.evaluate(presented: fp, pinned: nil), .unknown(presented: fp), "premier contact : à accepter")
        try expectEqual(FortiCertificatePin.evaluate(presented: fp, pinned: fp.lowercased().replacingOccurrences(of: ":", with: " ")), .accept,
                        "empreinte acceptée (casse et séparateurs ignorés)")
        let other = FortiCertificatePin.fingerprint(der: Data("abd".utf8))
        try expectEqual(FortiCertificatePin.evaluate(presented: other, pinned: fp), .changed(expected: fp, presented: other), "changement refusé")
        try expectEqual(FortiCertificatePin.display("ba7816bf"), "BA:78:16:BF", "forme affichée")
    }

    suite.add("FortiGate : jeton absent des réponses brutes, du diagnostic et des erreurs") {
        let token = FortiFixtures.token
        var responses = FortiFixtures.v74()
        // Réponse qui recopierait le jeton (proxy, page d'erreur) : il doit être masqué.
        responses[FortiPaths.dhcp] = (500, "erreur Bearer \(token) access_token=\(token) {\"api_key\":\"\(token)\"}")
        let report = try await FortiGateReader(transport: FortiFakeTransport(responses), tokenForRedaction: token).read(now: now)
        for call in report.calls {
            try expect(!call.body.contains(token) && !call.message.contains(token), "jeton absent de \(call.path)")
        }
        let text = FortiDiagnostic.text(calls: report.calls, config: FortiGateConfig(host: "10.182.122.1"), system: report.system,
                                        token: token, date: now)
        try expect(!text.contains(token), "jeton absent du diagnostic")
        try expect(text.contains("GET /api/v2/monitor/system/status") && text.contains("FGT-SIEGE"), "diagnostic utile")
        try expect(text.contains("jeton retiré"), "diagnostic annoncé sans jeton")
        // Même sans connaître le jeton, les formes reconnaissables sont masquées.
        let generic = FortiRedact.clean("Authorization: Bearer abcdef123456 ?access_token=zzz9", token: nil)
        try expect(!generic.contains("abcdef123456") && !generic.contains("zzz9"), "Bearer et access_token masqués")
        for error: FortiGateError in [.tokenRejected, .forbidden(path: "/x"), .notFound(path: "/x"), .timeout, .missingToken,
                                      .certificateUnknown(fingerprint: "AA", subject: "FGT"), .cannotConnect("x")] {
            try expect(!(error.errorDescription ?? "").contains(token), "jeton absent des erreurs")
        }
        // Le modèle encodé (enregistré dans les préférences) ne contient pas de jeton.
        let encoded = String(decoding: try JSONEncoder().encode(FortiGateConfig(host: "10.182.122.1", pinnedFingerprint: "AA")), as: UTF8.self)
        try expect(!encoded.lowercased().contains("token") && !encoded.lowercased().contains("jeton"), "réglages sans jeton")
    }

    suite.add("FortiGate : relecture (diagnostic d'un échec, trunks, valeurs aberrantes, appareils périmés)") {
        // Lecture échouée : les appels déjà faits restent pour le diagnostic.
        var forbidden = FortiFixtures.v74()
        forbidden[FortiPaths.switchStatus] = (403, #"{"status":"error","http_status":403}"#)
        do {
            _ = try await FortiGateReader(transport: FortiFakeTransport(forbidden)).readKeepingCalls(now: now)
            try expect(false, "403 sur les switchs doit arrêter la lecture")
        } catch let failure as FortiReadFailure {
            try expectEqual(failure.error, .forbidden(path: FortiPaths.switchStatus), "erreur portée")
            try expectEqual(failure.calls.map(\.path), [FortiPaths.systemStatus, FortiPaths.switchStatus], "appels gardés")
            try expectEqual(failure.calls.last?.outcome, .refused, "403 noté")
        }
        // Trunks de la configuration (FortiLink, ISL) : jamais des ports physiques.
        let trunkConfig = #"""
        {"results":[{"switch-id":"FSW-ENTREPOT","ports":[
          {"port-name":"port1","description":"Caméra quai"},
          {"port-name":"port50","description":"Libre"},
          {"port-name":"__FoRtI1LiNk0__","type":"trunk","members":[{"member-name":"port49"}]},
          {"port-name":"8DN4K16000000-0","type":"trunk","members":[{"member-name":"port47"}]},
          {"port-name":"port47"},{"port-name":"port49"}]}]}
        """#
        let map = FortiParsers.switchConfig(Data(trunkConfig.utf8)) ?? [:]
        let ports = map["fsw-entrepot"]?.ports ?? [:]
        try expect(ports["__forti1link0__"] == nil && ports["8dn4k16000000-0"] == nil, "trunks écartés")
        try expectEqual(ports["port49"]?.isFortiLink, true, "membre du trunk FortiLink marqué")
        try expectEqual(ports["port47"]?.isISL, true, "membre du trunk ISL marqué")
        let base = try await FortiGateReader(transport: FortiFakeTransport(FortiFixtures.v74())).read(now: now)
        let merged = FortiConvert.merge(base.switches, config: map)
        try expect(!merged[0].ports.contains { !FortiParse.isPhysicalPortName($0.name) }, "aucun faux port créé")
        try expect(merged[0].ports.contains { $0.name == "port50" }, "port physique absent de l'état créé")
        try expect(FortiParse.isPhysicalPortName("port1.2") && !FortiParse.isPhysicalPortName("__FoRtI1LiNk0__"), "nom de port physique")
        // Modèles à quatre chiffres.
        try expectEqual(FortiConvert.copperPorts(model: "FS-1048E"), 48, "1048E : 48")
        try expectEqual(FortiConvert.copperPorts(model: "FS-1024E"), 24, "1024E : 24")
        try expectEqual(FortiConvert.copperPorts(model: "FS-3032E"), 32, "3032E : 32")
        // Valeurs aberrantes : rien ne s'arrête net.
        try expectEqual(FortiParse.speedMbps("99999999999999999999999"), nil, "vitesse aberrante (texte)")
        try expectEqual(FortiParse.speedMbps(NSNumber(value: 1e30)), nil, "vitesse aberrante (nombre)")
        try expectEqual(FortiParse.speedMbps("999999999999G"), nil, "vitesse aberrante en Gb/s")
        try expectEqual(FortiParse.speedMbps("100G"), 100_000, "100G accepté")
        var hot = base
        hot.switches[0].ports[0].poePowerW = 1e20
        hot.switches[0].poeBudgetW = 1e30
        let hotSnap = FortiConvert.snapshots(from: hot)[0]
        try expectEqual(hotSnap.poeDetails?.first { $0.ifIndex == 1 }?.consumptionMW, nil, "puissance PoE aberrante ignorée")
        try expectEqual(hotSnap.poeBudgetW, nil, "budget aberrant ignoré")
        // Appareils périmés : ni situés, ni port fantôme actif.
        let cam = MACAddress("bc:ad:28:6f:01:5a")!
        let laptop = MACAddress("8c:16:45:2b:9e:77")!
        var stale = base
        stale.detected = [FortiDetectedDevice(mac: cam, switchID: "FSW-QUAI", portName: "port3", lastSeen: now.addingTimeInterval(-86_400))]
        stale.userDevices = [FortiUserDevice(mac: laptop, switchID: "FSW-QUAI", portName: "port7", lastSeen: now.addingTimeInterval(-86_400)),
                             FortiUserDevice(mac: cam, switchID: "FSW-QUAI", portName: "port9", lastSeen: now)]
        try expect(stale.locatedDevices.isEmpty, "détecté hier et inventaire seul pour une MAC détectée : non situés")
        stale.userDevices.append(FortiUserDevice(mac: laptop, switchID: "FSW-QUAI", portName: "port7", lastSeen: now.addingTimeInterval(-60)))
        stale.userDevices.removeFirst()
        try expectEqual(stale.locatedDevices.map(\.portName), ["port7"], "inventaire récent : situé")
        let quai = FortiConvert.snapshots(from: stale)[1]
        try expect(quai.interfaces.first { $0.name == "port7" }?.operStatus != .up, "pas de port actif tiré de l'inventaire")
        // Même règle d'uplink pour l'affichage et la localisation.
        try expectEqual(quai.uplinkThreshold, FortiLocate.controllerMacThreshold, "FortiSwitch : pas de seuil de MAC")
        try expectEqual(quai.locatedUplinks, quai.uplinkInterfaces(macThreshold: FortiLocate.controllerMacThreshold), "uplinks affichés")
    }
}
