import Foundation
@testable import NetScopeCore

// Note 30 : type « Téléphone IP » (fabricant, ports SIP, nom, LLDP / CDP, VLAN voix), distinct des
// cellulaires ; libellés, import CSV, Carte et Rapports. Données fixes, aucun accès réseau.

private func phoneGuess(_ ports: [UInt16], _ vendor: String?, _ host: String?, mac: String? = nil,
                        voip: VoIPSignals = [], snmp: SNMPDeviceKind? = nil) -> DeviceType {
    ScanDeviceClassifier.guess(ports: ports, vendor: vendor, hostname: host, mac: mac.flatMap(MACAddress.init),
                               snmpKind: snmp, voip: voip)
}

private func vdev(_ ip: String, _ mac: String, host: String?, vendor: String? = nil, ports: [UInt16] = [],
                  sw: String? = nil, port: String? = nil, vlan: Int? = nil, type: DeviceType = .inconnu) -> Device {
    Device(ip: IPv4Address(ip)!, mac: MACAddress(mac), vendor: vendor, hostname: host, openPorts: ports,
           switchName: sw, switchPort: port, vlan: vlan, rangeLabel: "Bureau", deviceType: type)
}

func registerVoIPTests(_ suite: TestSuite) {
    suite.add("Téléphone IP : libellés, symbole de la Carte, rapport, recherche") {
        try expectEqual(DeviceType.telephoneIP.label, "Téléphone IP", "libellé")
        try expectEqual(DeviceType.telephone.label, "Téléphone", "les cellulaires gardent leur libellé")
        try expectEqual(TopoGraph.pluralLabel(.telephoneIP), "Téléphones IP", "pluriel de la Carte")
        try expectEqual(DeviceType(rawValue: "telephone"), .telephone, "ancien identifiant toujours lu")
        try expectEqual(DeviceType(rawValue: "telephoneIP"), .telephoneIP, "nouvel identifiant")
        let yealink = vdev("10.0.0.21", "80:5E:C0:3A:61:21", host: "SIP-T54W", vendor: "Yealink", type: .telephoneIP)
        try expectEqual(ReportBuilder.shortType(yealink), "Tél. IP Yealink", "type court du rapport")
        var anonymous = yealink
        anonymous.vendor = nil
        try expectEqual(ReportBuilder.shortType(anonymous), "Tél. IP", "type court sans fabricant")
        try expect(yealink.matches("type:voip"), "type:voip trouve les téléphones IP")
        try expect(yealink.matches("type:\"téléphone ip\""), "type:« téléphone ip »")
        let android = vdev("10.0.0.33", "D6:4E:81:7A:33:C0", host: "Android_1", type: .telephone)
        try expect(!android.matches("type:voip"), "un cellulaire n'est pas un téléphone VoIP")
    }

    suite.add("Téléphone IP : détection par fabricant") {
        try expectEqual(phoneGuess([80, 443], "Yealink", nil), .telephoneIP, "Yealink")
        try expectEqual(phoneGuess([80], "Xiamen Yealink Network", nil), .telephoneIP, "nom IEEE long de Yealink")
        try expectEqual(phoneGuess([80], "Poly", nil), .telephoneIP, "Poly (ex-Polycom)")
        try expectEqual(phoneGuess([], "Mitel", nil), .telephoneIP, "Mitel")
        try expectEqual(phoneGuess([80], "Aastra Telecom", nil), .telephoneIP, "Aastra")
        try expectEqual(phoneGuess([80], "Grandstream", nil), .telephoneIP, "Grandstream")
        try expectEqual(phoneGuess([80], "Fanvil", nil), .telephoneIP, "Fanvil")
        try expectEqual(phoneGuess([80], "snom technology", nil), .telephoneIP, "Snom")
        try expectEqual(phoneGuess([443], "Avaya", nil), .telephoneIP, "Avaya")
        try expectEqual(phoneGuess([], "Gigaset Communications", nil), .telephoneIP, "Gigaset")
        try expectEqual(phoneGuess([80], "Obihai Technology", nil), .telephoneIP, "Obihai")
        try expectEqual(phoneGuess([80], "Audiocodes USA", nil), .telephoneIP, "AudioCodes")
        try expectEqual(phoneGuess([], "Polytech", nil), .inconnu, "Polytech n'est pas Poly (mot entier)")
        try expect(phoneGuess([80, 443], "Grandstream", "GWN7605") != .telephoneIP, "borne Grandstream GWN : pas un téléphone")
        try expectEqual(phoneGuess([135, 445], "Yealink", nil), .poste, "ports d'ordinateur : pas un téléphone")
        // Fabricants à indice : le fabricant seul ne suffit pas.
        try expectEqual(phoneGuess([80], "Panasonic Corporation AVC Networks", nil), .inconnu, "Panasonic sans indice")
        try expectEqual(phoneGuess([80, 5060], "Panasonic Corporation AVC Networks", nil), .telephoneIP, "Panasonic + SIP")
        try expectEqual(phoneGuess([80], "Alcatel-Lucent Enterprise", nil, voip: .voiceVLAN), .telephoneIP, "Alcatel-Lucent + VLAN voix")
        try expectEqual(phoneGuess([80], "Alcatel-Lucent Enterprise", nil), .inconnu, "Alcatel-Lucent sans indice")
        try expectEqual(phoneGuess([80], "Unify Software and Solutions", nil, voip: .announcedPhone), .telephoneIP, "Unify + LLDP")
        try expectEqual(phoneGuess([80, 5060], "HP", nil), .telephoneIP, "HP Poly + SIP")
        try expectEqual(phoneGuess([80, 9100], "HP", nil), .imprimante, "HP qui imprime reste une imprimante")
    }

    suite.add("Téléphone IP : Cisco seulement avec un indice VoIP") {
        try expectEqual(phoneGuess([80], "Cisco", "SEP001B54A1B2C3"), .telephoneIP, "nom Cisco SEP + MAC")
        try expectEqual(phoneGuess([80], "Cisco", nil, voip: .announcedPhone), .telephoneIP, "Cisco annoncé téléphone par CDP")
        try expectEqual(phoneGuess([80, 5060], "Cisco", nil), .telephoneIP, "Cisco + SIP, sans port d'administration")
        try expectEqual(phoneGuess([80], "Cisco", nil, voip: .voiceVLAN), .telephoneIP, "Cisco dans le VLAN voix")
        // Faux positifs : switch et routeur Cisco.
        try expectEqual(phoneGuess([22, 23, 443], "Cisco", "SW-CORE-01"), .switch, "switch Cisco")
        try expectEqual(phoneGuess([22, 23, 443, 5060], "Cisco", "SW-ACCES-03"), .switch, "switch Cisco même avec 5060")
        try expectEqual(phoneGuess([22, 443, 5060], "Cisco", "RTR-CUBE-01"), .routeur, "routeur Cisco CUBE (SIP + SSH)")
        try expectEqual(phoneGuess([22, 23], "Cisco", nil, voip: .voiceVLAN), .routeur, "équipement Cisco administrable dans le VLAN voix")
        try expectEqual(phoneGuess([22, 443], "Cisco", nil, voip: .voiceVLAN, snmp: .switch), .switch, "SNMP fait foi")
        try expectEqual(phoneGuess([80], "Cisco", nil), .routeur, "Cisco sans indice : règle d'avant")
        try expectEqual(phoneGuess([80], "Cisco", "sep001b54"), .routeur, "« sep » trop court : pas un nom de téléphone")
    }

    suite.add("Téléphone IP : ports SIP et noms d'hôte") {
        try expectEqual(phoneGuess([80, 5060], nil, nil), .telephoneIP, "SIP 5060")
        try expectEqual(phoneGuess([5061], nil, nil), .telephoneIP, "SIP TLS 5061")
        try expectEqual(phoneGuess([22, 80, 443, 5060], nil, "pbx"), .inconnu, "IPBX (SIP + SSH) : pas un téléphone")
        try expectEqual(phoneGuess([445, 5060], "Dell", "WKS346"), .poste, "softphone sur un PC")
        try expectEqual(phoneGuess([5060], "VMware", "FREEPBX"), .inconnu, "IPBX virtuel")
        try expectEqual(phoneGuess([443, 541, 5060], "Fortinet", "FortiGate-60F"), .routeur, "FortiGate avec SIP : pare-feu")
        try expectEqual(phoneGuess([80], nil, "SIP-T46U"), .telephoneIP, "nom Yealink par défaut")
        try expectEqual(phoneGuess([], nil, "yealink-t54w"), .telephoneIP, "nom contenant yealink")
        try expectEqual(phoneGuess([], nil, "polycom-0004f2aabbcc"), .telephoneIP, "nom polycom")
        try expectEqual(phoneGuess([], nil, "SPIP650-RECEPTION"), .telephoneIP, "SoundPoint IP")
        try expectEqual(phoneGuess([], nil, "VVX450"), .telephoneIP, "Poly VVX")
        try expectEqual(phoneGuess([], nil, "GXP2170"), .telephoneIP, "Grandstream GXP")
        try expectEqual(phoneGuess([], nil, "ThinkPad-T480"), .inconnu, "T480 n'est pas un Yealink")
        try expectEqual(phoneGuess([], nil, "T46"), .inconnu, "modèle seul, sans « SIP- » : trop vague")
        try expectEqual(VoIPClassifier.hostLooksLikePhone("SEP001B54A1B2C3.bureau.local"), true, "SEP avec domaine")
        try expectEqual(VoIPClassifier.hostLooksLikePhone("SEPTEMBRE-RAPPORT"), false, "« sep » d'un mot ordinaire")
    }

    suite.add("Téléphone IP : jamais un smartphone") {
        try expectEqual(phoneGuess([62078], "Apple, Inc.", "iPhone-de-Dany"), .telephone, "iPhone")
        try expectEqual(phoneGuess([5060], "Apple", "iPhone-de-Dany"), .telephone, "iPhone avec softphone SIP")
        try expectEqual(phoneGuess([5060], "Samsung Electronics", "Galaxy-S24"), .telephone, "Samsung avec SIP")
        try expectEqual(phoneGuess([], nil, "Android_89UM1WTN", voip: .voiceVLAN), .telephone, "Android dans le VLAN voix")
        try expectEqual(phoneGuess([], nil, nil, mac: "D6:4E:81:7A:33:C0", voip: .voiceVLAN), .inconnu, "MAC aléatoire dans le VLAN voix")
        try expectEqual(phoneGuess([], "Apple", "Macmini-de-Dany", voip: .voiceVLAN), .poste, "Mac dans le VLAN voix")
        try expectEqual(phoneGuess([], "Samsung Electronics", nil, voip: .announcedPhone), .inconnu,
                        "Samsung même annoncé : jamais un téléphone IP")
    }

    suite.add("Téléphone IP : annonces LLDP / CDP et VLAN voix") {
        // Voisins LLDP d'un switch relevé : téléphone sur le port 10 (poste branché derrière), PC seul
        // sur le port 3, switch en uplink sur le port 25.
        let phoneMAC = MACAddress("80:5E:C0:3A:61:21")!, pcMAC = MACAddress("B0:7B:25:44:A1:10")!
        let soloMAC = MACAddress("00:04:F2:AA:01:50")!, ciscoMAC = MACAddress("00:1B:54:A1:B2:C3")!
        let switchMAC = MACAddress("70:0F:6A:91:4C:02")!
        let fdb = [SNMPFDBEntry(mac: phoneMAC, vlan: 20, bridgePort: 10, ifIndex: 10),
                   SNMPFDBEntry(mac: pcMAC, vlan: 1, bridgePort: 10, ifIndex: 10),
                   SNMPFDBEntry(mac: soloMAC, vlan: 20, bridgePort: 11, ifIndex: 11),
                   SNMPFDBEntry(mac: ciscoMAC, vlan: 20, bridgePort: 12, ifIndex: 12),
                   SNMPFDBEntry(mac: pcMAC, vlan: 1, bridgePort: 12, ifIndex: 12),
                   SNMPFDBEntry(mac: switchMAC, vlan: 1, bridgePort: 25, ifIndex: 25)]
        let neighbors = [
            SNMPLLDPNeighbor(localPortNum: 10, ifIndex: 10, sysName: "SIP-T54W", portID: "80:5E:C0:3A:61:21",
                             capabilities: [.bridge, .telephone]),
            SNMPLLDPNeighbor(localPortNum: 11, ifIndex: 11, sysName: "", portID: "Port 1", capabilities: [.telephone]),
            SNMPLLDPNeighbor(localPortNum: 12, ifIndex: 12, sysName: "SEP001B54A1B2C3", portID: "Port 1",
                             capabilities: [.bridge, .telephone]),
            SNMPLLDPNeighbor(localPortNum: 25, ifIndex: 25, sysName: "SW-CORE-01", portID: "Gi1/0/47", capabilities: [.bridge, .router]),
        ]
        let interfaces = [10, 11, 12, 25].map { SNMPInterface(index: $0, name: "1/\($0)", descr: "\($0)", operStatus: .up) }
        let snapshot = SNMPSwitchSnapshot(host: IPv4Address("10.0.0.3")!, system: SNMPSystemInfo(name: "SW-ETG2-01", descr: "Aruba 2930F"),
                                          interfaces: interfaces, fdb: fdb, neighbors: neighbors,
                                          pvid: [10: 1, 11: 20, 12: 1, 25: 1])
        // Un téléphone « Bridge, Telephone » n'est pas un uplink : le poste derrière garde son port.
        try expect(!SNMPLLDPCapabilities([.bridge, .telephone]).isInfrastructure, "Bridge + Telephone : pas d'infrastructure")
        try expect(SNMPLLDPCapabilities([.bridge, .router]).isInfrastructure, "switch routeur : infrastructure")
        try expectEqual(snapshot.uplinkInterfaces(), [25], "seul le port 25 est un uplink")
        let devices = [
            vdev("10.0.0.21", "80:5E:C0:3A:61:21", host: nil, ports: [80], vlan: 20),
            vdev("10.0.0.50", "00:04:F2:AA:01:50", host: nil, vlan: 20),
            vdev("10.0.0.60", "00:1B:54:A1:B2:C3", host: nil, vendor: "Cisco", ports: [80], vlan: 20),
            vdev("10.0.0.10", "B0:7B:25:44:A1:10", host: "WKS410", vendor: "Dell", ports: [135, 445], vlan: 1, type: .poste),
            vdev("10.0.0.2", "70:0F:6A:91:4C:02", host: "SW-CORE-01", vendor: "Cisco", ports: [22, 23], vlan: 1, type: .switch),
        ]
        let hints = VoIPDetector.hints(snapshots: [snapshot], devices: devices)
        try expectEqual(hints.phoneMACs, [phoneMAC, soloMAC, ciscoMAC], "téléphones : par identifiant de port, seule MAC, nom SEP")
        try expectEqual(hints.voiceVLANs, [20], "VLAN voix : VLAN étiqueté des téléphones (le port 11 a 20 en natif)")
        let applied = VoIPDetector.apply(hints, to: devices)
        let byIP = Dictionary(uniqueKeysWithValues: applied.devices.map { ($0.id, $0) })
        try expectEqual(byIP["10.0.0.21"]?.deviceType, .telephoneIP, "Yealink annoncé par LLDP")
        try expectEqual(byIP["10.0.0.50"]?.deviceType, .telephoneIP, "Poly seul sur son port")
        try expectEqual(byIP["10.0.0.60"]?.deviceType, .telephoneIP, "Cisco SEP annoncé")
        try expectEqual(byIP["10.0.0.10"]?.deviceType, .poste, "le poste derrière le téléphone reste un poste")
        try expectEqual(byIP["10.0.0.2"]?.deviceType, .switch, "le switch Cisco reste un switch")
        try expectEqual(byIP["10.0.0.21"]?.voipSignals, [.announcedPhone, .voiceVLAN], "indices retenus")
        try expectEqual(applied.changed, 3, "trois appareils changés")
        try expectEqual(VoIPDetector.apply(hints, to: applied.devices).changed, 0, "deuxième passage : rien ne change")
        let evidence = VoIPClassifier.evidence(byIP["10.0.0.21"]!)
        try expect(evidence.contains("VLAN voix 20") && evidence.contains("Fabricant Yealink"), "indices de la fiche : \(evidence)")

        // Port à deux MAC sans identifiant utile : on ne devine pas.
        let ambiguous = SNMPLLDPNeighbor(localPortNum: 10, ifIndex: 10, sysName: "", portID: "Port 1", capabilities: [.telephone])
        try expectEqual(VoIPDetector.phoneMAC(for: ambiguous, among: [pcMAC, MACAddress("B0:7B:25:44:A1:11")!], devices: [:]), nil,
                        "deux postes Dell : aucun téléphone désigné")
        try expectEqual(VoIPDetector.phoneMAC(for: ambiguous, among: [pcMAC, phoneMAC], devices: [:]), phoneMAC,
                        "seule MAC d'un fabricant VoIP du port")

        // Voisins LLDP / CDP entendus par ce Mac (capture) et plages nommées « Voix ».
        let heard = [
            NetworkNeighbor(protocols: [.cdp], systemName: "SW-ETG2-01", voiceVLAN: 120, capabilities: ["Router", "Switch", "IGMP"]),
            NetworkNeighbor(protocols: [.lldp], chassisID: "00:04:F2:BB:02:60", managementAddresses: ["10.0.0.70"],
                            capabilities: ["Bridge", "Téléphone"]),
            NetworkNeighbor(protocols: [.cdp], systemName: "RTR-01", managementAddresses: ["10.0.0.1"], capabilities: ["Router", "Téléphone"]),
        ]
        let ranges = [ScanRangeConfig(text: "10.0.30.0/24", label: "Téléphonie IP", vlan: 30),
                      ScanRangeConfig(text: "10.0.0.0/24", label: "Bureau", vlan: 1)]
        let other = VoIPDetector.hints(snapshots: [], neighbors: heard, ranges: ranges)
        try expectEqual(other.voiceVLANs, [120, 30], "VLAN voix annoncé par CDP et plage « Téléphonie IP »")
        try expectEqual(other.phoneMACs, [MACAddress("00:04:F2:BB:02:60")!], "châssis du téléphone LLDP")
        try expectEqual(other.phoneIPs, [IPv4Address("10.0.0.70")!], "adresse de gestion du téléphone, pas celle du routeur")
        try expect(VoIPDetector.isVoiceLabel("VLAN Voix"), "« VLAN Voix »")
        try expect(VoIPDetector.isVoiceLabel("VoIP"), "« VoIP »")
        try expect(!VoIPDetector.isVoiceLabel("Serveurs"), "« Serveurs »")
        // Le VLAN voix ne s'applique plus quand l'appareil en sort.
        var moved = byIP["10.0.0.50"]!
        moved.vlan = 1
        let after = VoIPDetector.apply(VoIPHints(voiceVLANs: [20]), to: [moved]).devices[0]
        try expectEqual(after.voipSignals, [.announcedPhone], "hors du VLAN voix : l'annonce LLDP reste")
        // Plus aucun VLAN voix connu : l'indice est retiré et le classement refait.
        let stale = Device(ip: IPv4Address("10.0.0.90")!, vlan: 20, deviceType: .telephoneIP, voipSignals: [.voiceVLAN])
        let cleared = VoIPDetector.apply(VoIPHints(), to: [stale])
        try expectEqual(cleared.changed, 1, "appareil changé")
        try expectEqual(cleared.devices[0].voipSignals, nil, "indice « VLAN voix » retiré")
        try expect(cleared.devices[0].deviceType != .telephoneIP, "plus classé téléphone IP")
    }

    suite.add("Téléphone IP : import CSV et anciens fichiers") {
        try expectEqual(InvCSV.parseType("Téléphone IP"), .telephoneIP, "libellé")
        try expectEqual(InvCSV.parseType("telephoneIP"), .telephoneIP, "identifiant")
        try expectEqual(InvCSV.parseType("Tél. IP"), .telephoneIP, "libellé court")
        try expectEqual(InvCSV.parseType("Téléphonie IP"), .telephoneIP, "téléphonie IP")
        try expectEqual(InvCSV.parseType("VoIP"), .telephoneIP, "VoIP")
        try expectEqual(InvCSV.parseType("Téléphone"), .telephone, "« Téléphone » reste un cellulaire")
        // Un appareil enregistré avant la 0.14.0 (sans « voipSignals ») se relit tel quel.
        let old = #"{"ip":"10.0.0.5","isOnline":true,"openPorts":[80],"firstSeen":0,"lastSeen":0,"deviceType":"telephone"}"#
        let device = try JSONDecoder().decode(Device.self, from: Data(old.utf8))
        try expectEqual(device.deviceType, .telephone, "ancien type lu")
        try expectEqual(device.voipSignals, nil, "aucun indice VoIP")
        var phone = device
        phone.deviceType = .telephoneIP
        phone.voipSignals = [.announcedPhone]
        let back = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(phone))
        try expectEqual(back.deviceType, .telephoneIP, "aller-retour du type")
        try expectEqual(back.voipSignals, [.announcedPhone], "aller-retour des indices")
    }

    suite.add("Téléphone IP : groupe de la Carte et VLAN voix du rapport") {
        let devices = [
            vdev("10.0.0.3", "88:3A:30:5D:E1:40", host: "SW-ETG2-01", vlan: 1, type: .switch),
            vdev("10.0.0.21", "80:5E:C0:3A:61:21", host: "SIP-T54W", vendor: "Yealink", sw: "SW-ETG2-01", port: "1/10", vlan: 20, type: .telephoneIP),
            vdev("10.0.0.22", "80:5E:C0:3A:61:22", host: "SIP-T46U", vendor: "Yealink", sw: "SW-ETG2-01", port: "1/15", vlan: 20, type: .telephoneIP),
            vdev("10.0.0.23", "80:5E:C0:3A:61:23", host: "SIP-T33G", vendor: "Yealink", sw: "SW-ETG2-01", port: "1/16", vlan: 20, type: .telephoneIP),
            vdev("10.0.0.33", "D6:4E:81:7A:33:C0", host: "Android", sw: "SW-ETG2-01", port: "1/3", vlan: 1, type: .telephone),
        ]
        let graph = TopoGraph.build(devices: devices, gateway: nil)
        let group = graph.nodes.first { $0.kind == .groupe && $0.deviceType == .telephoneIP }
        try expectEqual(group?.title, "Téléphones IP ×3", "groupe de la Carte")
        try expectEqual(group?.subtitle, "VLAN 20 · 3 en ligne", "VLAN voix du groupe")
        try expect(graph.nodes.contains { $0.kind == .appareil && $0.deviceType == .telephone }, "le cellulaire reste à part")
        try expectEqual(ReportBuilder.vlanName(20, devices: Array(devices[1...3])), "Voix (téléphonie IP)", "VLAN voix nommé")
        let withAP = Array(devices[1...3]) + [vdev("10.0.0.102", "70:4C:A5:1E:22:9A", host: "FortiAP", vlan: 20, type: .pointAcces)]
        try expectEqual(ReportBuilder.vlanName(20, devices: withAP), "Voix et Wi-Fi", "VLAN partagé avec une borne")
    }
}
