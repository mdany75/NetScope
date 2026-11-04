import Foundation
@testable import NetScopeCore

// Scanner automatique (0.2.0) : profil Rapide avec ports, noms avec leur source, type d'après la
// découverte SNMP, MAC complétées par l'ARP SNMP puis emplacement. Aucun accès réseau.

func registerAutoScanTests(_ suite: TestSuite) {
    suite.add("Scanner auto : profil Rapide par défaut, ports sondés sans clic droit") {
        let bureau = ScanTarget(label: "Bureau", vlan: 1, range: try IPRange(parsing: "10.0.0.1-4"))
        let pinger = ScanFakePinger(replies: [IPv4Address("10.0.0.2")!: 1.2, IPv4Address("10.0.0.3")!: 2.0])
        let ports = ScanFakePorts(open: [IPv4Address("10.0.0.2")!: [22, 443, 9100, 12345],
                                         IPv4Address("10.0.0.3")!: [445, 3389]])
        let names = ScanFakeDetails(details: [
            IPv4Address("10.0.0.2")!: NameDetails(hostname: "Brother-DCP.local", source: .mdns, mdnsName: "Brother-DCP.local"),
            IPv4Address("10.0.0.3")!: NameDetails(hostname: "WKS346", source: .netbios, netbiosName: "WKS346",
                                                  netbiosDomain: "BUREAU", netbiosMAC: MACAddress("b0:7b:25:44:a1:6c")),
        ])
        let engine = ScanEngine(pinger: pinger, arp: ScanFakeARP(table: [:]), ports: ports, names: names)
        let options = ScanOptions()
        try expectEqual(options.profile, .rapide, "profil par défaut")
        try expectEqual(options.ports.count, 22, "Rapide : 22 ports essentiels (SIP 5060 et 5061 compris)")
        var found: [IPv4Address: Device] = [:]
        for await event in engine.scan([bureau], options: options) {
            switch event {
            case .deviceFound(let device, _), .deviceUpdated(let device, _): found[device.ip] = device
            default: break
            }
        }
        let printer = found[IPv4Address("10.0.0.2")!]
        try expectEqual(printer?.openPorts, [22, 443, 9100], "ports essentiels ouverts (12345 hors profil)")
        try expectEqual(printer?.deviceType, .imprimante, "9100 : imprimante")
        try expectEqual(printer?.hostnameLabel, "Brother-DCP", "nom affiché sans « .local »")
        try expectEqual(printer?.displayName, "Brother-DCP", "displayName sans « .local »")
        try expectEqual(printer?.nameSourceLabel, "mDNS (Bonjour)", "source mDNS")
        let pc = found[IPv4Address("10.0.0.3")!]
        try expectEqual(pc?.mac, MACAddress("b0:7b:25:44:a1:6c"), "MAC annoncée par NetBIOS (absente de l'ARP)")
        try expectEqual(pc?.vendor, "Dell", "fabricant d'après la MAC NetBIOS")
        try expectEqual(pc?.nameSourceLabel, "NetBIOS · groupe BUREAU", "source NetBIOS et groupe")
        try expectEqual(pc?.deviceType, .poste, "RDP : poste")
    }

    suite.add("Types Console de jeu et Domotique : détection, libellés, import CSV") {
        let g = { (ports: [UInt16], vendor: String?, host: String?) in
            ScanDeviceClassifier.guess(ports: ports, vendor: vendor, hostname: host, mac: nil)
        }
        try expectEqual(g([], "Nintendo Co.,Ltd", nil), .console, "fabricant Nintendo")
        try expectEqual(g([], "Sony Interactive Entertainment Inc.", nil), .console, "fabricant Sony Interactive")
        try expectEqual(g([], "Microsoft Corporation", "XboxOne"), .console, "nom Xbox")
        try expectEqual(g([], "Sony Corporation", "PS5-123"), .console, "nom PS5")
        try expectEqual(g([], "Sony Corporation", nil), .inconnu, "Sony seul : pas forcément une console")
        try expectEqual(g([80], "Signify Netherlands B.V.", nil), .domotique, "pont Philips Hue (Signify)")
        try expectEqual(g([8123], nil, "homeassistant"), .domotique, "Home Assistant (port 8123)")
        try expectEqual(g([80], "Espressif Inc.", "shelly1-ABCDEF"), .domotique, "module Shelly nommé")
        try expectEqual(g([80], "Espressif Inc.", nil), .iot, "Espressif sans autre indice : objet connecté")
        try expectEqual(g([1400], "Sonos, Inc.", nil), .iot, "Sonos reste un objet connecté")
        try expectEqual(g([62078], "Apple, Inc.", "iPhone-de-Dany"), .telephone, "un iPhone n'est pas une console")
        try expectEqual(DeviceType.console.label, "Console de jeu", "libellé")
        try expectEqual(DeviceType.domotique.label, "Domotique", "libellé")
        try expectEqual(InvCSV.parseType("Console de jeu"), .console, "import CSV par libellé")
        try expectEqual(InvCSV.parseType("domotique"), .domotique, "import CSV par identifiant")
    }

    suite.add("Scanner auto : type d'après la découverte SNMP, plus de « 161 TCP »") {
        try expectEqual(ScanDeviceClassifier.guess(ports: [161], vendor: nil, hostname: nil, mac: nil), .inconnu,
                        "161 TCP ne veut rien dire (SNMP = UDP)")
        try expectEqual(ScanDeviceClassifier.guess(ports: [22, 161], vendor: "Cisco", hostname: "core", mac: nil), .routeur,
                        "Cisco sans SNMP ni nom de switch : routeur")
        try expectEqual(ScanDeviceClassifier.guess(ports: [22], vendor: "Cisco", hostname: "SW-CORE-01", mac: nil), .switch,
                        "Cisco nommé SW… : switch")
        try expectEqual(ScanDeviceClassifier.guess(ports: [22, 443], vendor: "HPE Aruba", hostname: nil, mac: nil, snmpKind: .switch),
                        .switch, "découverte SNMP : switch")
        try expectEqual(ScanDeviceClassifier.guess(ports: [443], vendor: "Dell", hostname: nil, mac: nil, snmpKind: .routeur),
                        .routeur, "découverte SNMP : routeur")
        try expectEqual(ScanDeviceClassifier.guess(ports: [80], vendor: "HP", hostname: nil, mac: nil, snmpKind: .imprimante),
                        .imprimante, "découverte SNMP : imprimante")
        try expectEqual(ScanDeviceClassifier.guess(ports: [3389], vendor: "Dell", hostname: nil, mac: nil, snmpKind: .autre),
                        .poste, "SNMP « autre » : on garde les autres indices")

        let devices = [
            Device(ip: IPv4Address("10.0.0.2")!, vendor: "Cisco"),
            Device(ip: IPv4Address("10.0.0.3")!, hostname: "deja-nomme", nameSource: .dns),
            Device(ip: IPv4Address("10.0.0.4")!),
        ]
        let discovered = [
            SNMPDiscovered(host: IPv4Address("10.0.0.2")!, community: "public", sysName: "SW-CORE-01",
                           sysDescr: "Cisco IOS Software, C2960X", sysObjectID: "1.3.6.1.4.1.9.1.1208", bridgePorts: 52),
            SNMPDiscovered(host: IPv4Address("10.0.0.3")!, community: "public", sysName: "NPI7A4410",
                           sysDescr: "HP ETHERNET MULTI-ENVIRONMENT", sysObjectID: "1.3.6.1.4.1.11.2.3.9.1", bridgePorts: nil,
                           hasPrinterMIB: true),
        ]
        let applied = SNMPAutoLocate.applyDiscovery(discovered, to: devices)
        try expectEqual(applied[0].snmpKind, .switch, "nature SNMP retenue")
        try expectEqual(applied[0].deviceType, .switch, "type switch")
        try expectEqual(applied[0].hostname, "SW-CORE-01", "sysName comme nom d'hôte")
        try expectEqual(applied[0].nameSource, .snmp, "source SNMP")
        try expectEqual(applied[1].hostname, "deja-nomme", "nom existant gardé")
        try expectEqual(applied[1].nameSource, .dns, "source existante gardée")
        try expectEqual(applied[1].deviceType, .imprimante, "Printer-MIB : imprimante")
        try expect(applied[2].snmpKind == nil && applied[2].hostname == nil, "appareil muet inchangé")
    }

    suite.add("Scanner auto : MAC complétées par l'ARP SNMP, puis switch, port et VLAN") {
        let pcMAC = MACAddress("b0:7b:25:44:a1:6c")!
        let camMAC = MACAddress("bc:ad:28:6f:01:5a")!
        let edgeMAC = MACAddress("88:3a:30:5d:e1:40")!
        // Switch cœur : Gi1/0/22 (accès, VLAN 1), Gi1/0/33 (accès, VLAN 40), Gi1/0/47 (uplink vers SW-ETG2-01).
        let interfaces = [22, 33, 47].map { SNMPInterface(index: $0, name: "Gi1/0/\($0)", operStatus: .up, speedMbps: 1000) }
        var fdb = [
            SNMPFDBEntry(mac: pcMAC, vlan: nil, bridgePort: 22, ifIndex: 22),
            SNMPFDBEntry(mac: camMAC, vlan: 40, bridgePort: 33, ifIndex: 33),
            SNMPFDBEntry(mac: edgeMAC, vlan: 1, bridgePort: 47, ifIndex: 47),
        ]
        // Beaucoup de MAC derrière l'uplink : le port 47 n'est pas un port d'accès.
        for n in 0..<12 { fdb.append(SNMPFDBEntry(mac: MACAddress(value: UInt64(0x02_00_00_00_00_10 + n)), vlan: 1, bridgePort: 47, ifIndex: 47)) }
        let core = SNMPSwitchSnapshot(host: IPv4Address("10.0.0.2")!,
                                      system: SNMPSystemInfo(name: "SW-CORE-01", descr: "Cisco IOS"),
                                      interfaces: interfaces, fdb: fdb, pvid: [22: 1, 33: 40, 47: 1],
                                      arp: [camMAC: IPv4Address("192.168.50.21")!, MACAddress(value: 0xFFFF_FFFF_FFFF): IPv4Address("192.168.50.255")!])

        let devices = [
            Device(ip: IPv4Address("10.0.0.50")!),                            // MAC connue seulement du routeur
            Device(ip: IPv4Address("192.168.50.21")!),                        // autre VLAN : MAC par l'ARP du switch L3
            Device(ip: IPv4Address("10.0.0.3")!, mac: edgeMAC),               // vue seulement sur l'uplink
            Device(ip: IPv4Address("10.0.0.60")!),                            // inconnue partout
        ]
        let routerARP: [IPv4Address: MACAddress] = [IPv4Address("10.0.0.50")!: pcMAC,
                                                    IPv4Address("10.0.0.61")!: MACAddress(value: 0)]
        let arp = SNMPAutoLocate.mergedARP(routers: [routerARP], snapshots: [core])
        try expectEqual(arp[IPv4Address("10.0.0.50")!], pcMAC, "ARP du routeur")
        try expectEqual(arp[IPv4Address("192.168.50.21")!], camMAC, "ARP du switch de niveau 3")
        try expect(arp[IPv4Address("10.0.0.61")!] == nil, "MAC nulle écartée")
        try expect(arp[IPv4Address("192.168.50.255")!] == nil, "diffusion écartée")

        let filled = SNMPAutoLocate.fillMACs(devices, from: arp)
        try expectEqual(filled.filled, 2, "deux MAC complétées")
        try expectEqual(filled.devices[0].vendor, "Dell", "fabricant d'après la MAC complétée")
        try expectEqual(filled.devices[1].mac, camMAC, "caméra d'un autre VLAN")

        let located = SNMPAutoLocate.locate(filled.devices, in: [core])
        try expectEqual(located.located, 2, "deux appareils localisés")
        try expectEqual(located.devices[0].switchLocation, "SW-CORE-01 · Gi1/0/22", "poste localisé")
        try expectEqual(located.devices[0].vlan, 1, "VLAN natif du port (PVID)")
        try expectEqual(located.devices[1].switchLocation, "SW-CORE-01 · Gi1/0/33", "caméra localisée")
        try expectEqual(located.devices[1].vlan, 40, "VLAN de la table MAC")
        try expect(located.devices[2].switchName == nil, "uplink ignoré")
        try expect(located.devices[3].switchName == nil, "MAC inconnue : pas d'emplacement")
        // Même résultat que la recherche d'une seule MAC.
        try expectEqual(SNMPAutoLocate.accessPorts(in: [core])[pcMAC]?.ifIndex, SNMPLocator.locate(pcMAC, in: [core])?.ifIndex,
                        "index en une passe = SNMPLocator.locate")
    }
}

/// Résolveur de noms détaillé, pour les tests.
struct ScanFakeDetails: ScanNameDetailResolving {
    let details: [IPv4Address: NameDetails]
    func name(for ip: IPv4Address, timeout: Duration) async -> String? { details[ip]?.hostname }
    func details(for ip: IPv4Address, timeout: Duration) async -> NameDetails { details[ip] ?? NameDetails() }
}

// Corrections de relecture : ports sondés signalés à part, délai Rapide, annulation des noms.
func registerAutoScanReviewTests(_ suite: TestSuite) {
    suite.add("Scanner auto : résultat des ports signalé par « portsProbed », délai Rapide de 400 ms") {
        try expectEqual(ScanOptions().portTimeout, .milliseconds(400), "Rapide : 400 ms par port")
        try expectEqual(ScanOptions(profile: .complet).portTimeout, .milliseconds(800), "Complet : 800 ms")
        let bureau = ScanTarget(label: "Bureau", range: try IPRange(parsing: "10.0.0.1-3"))
        let pinger = ScanFakePinger(replies: [IPv4Address("10.0.0.2")!: 1.0, IPv4Address("10.0.0.3")!: 1.0])
        let ports = ScanFakePorts(open: [IPv4Address("10.0.0.2")!: [22, 9100]])
        let engine = ScanEngine(pinger: pinger, arp: ScanFakeARP(table: [:]), ports: ports, names: ScanNoNames())
        var probed: [IPv4Address: [UInt16]] = [:]
        var lastUpdate: [IPv4Address: [UInt16]] = [:]
        for await event in engine.scan([bureau], options: ScanOptions()) {
            switch event {
            case .deviceFound(let device, _), .deviceUpdated(let device, _): lastUpdate[device.ip] = device.openPorts
            case .portsProbed(let ip, let open, _):
                try expectEqual(lastUpdate[ip], open, "portsProbed suit le deviceUpdated qui porte les mêmes ports")
                probed[ip] = open
            default: break
            }
        }
        try expectEqual(probed[IPv4Address("10.0.0.2")!], [22, 9100], "ports ouverts signalés")
        try expectEqual(probed[IPv4Address("10.0.0.3")!], [], "aucun port ouvert : signalé quand même (liste vide)")
        try expectEqual(probed.count, 2, "un seul signalement par hôte en ligne")
    }

    suite.add("Noms : « Arrêter » rend la main tout de suite") {
        let silent = try NamesResponder { _ in nil }
        defer { silent.stop() }
        let chain = NameResolverChain(reverseDNS: nil, mdns: NamesMDNS(unicastPort: silent.port, multicast: nil),
                                      netbios: NamesNetBIOS(port: silent.port), maxTimeout: .seconds(3))
        let start = Date()
        let task = Task { await chain.details(for: IPv4Address(127, 0, 0, 1), timeout: .seconds(3)) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let details = await task.value
        let elapsed = Date().timeIntervalSince(start)
        try expect(details.hostname == nil, "aucun nom")
        try expect(elapsed < 1.0, "rendu en \(elapsed) s au lieu d'attendre le délai de 3 s")
    }
}
