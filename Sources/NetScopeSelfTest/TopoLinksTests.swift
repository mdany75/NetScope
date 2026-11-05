import Foundation
import NetScopeCore

// 0.27.0, note 78 (Carte du réseau) : liens entre switchs d'après les voisins LLDP relus par SNMP
// et la FortiGate (FortiLink, ISL), hiérarchie qui en découle, liens redondants, filtre par VLAN
// et nœuds déplacés à la main. Données fixes, aucun réseau.

func registerTopoLinksTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)
    let gatewayIP = IPv4Address("10.182.122.1")

    func device(_ ip: String, _ host: String, name: String? = nil, _ type: DeviceType,
                sw: String? = nil, port: String? = nil, vlan: Int? = nil) -> Device {
        Device(ip: IPv4Address(ip)!, mac: nil, hostname: host, customName: name, isOnline: true,
               switchName: sw, switchPort: port, vlan: vlan, firstSeen: now, lastSeen: now, deviceType: type)
    }

    func port(_ index: Int, _ name: String, speed: UInt64 = 1000, up: Bool = true) -> SNMPInterface {
        SNMPInterface(index: index, name: name, operStatus: up ? .up : .down, speedMbps: speed)
    }

    func neighbor(_ index: Int, _ name: String, _ remote: String, descr: String? = nil,
                  _ caps: SNMPLLDPCapabilities = [.bridge]) -> SNMPLLDPNeighbor {
        SNMPLLDPNeighbor(localPortNum: index, ifIndex: index, sysName: name, portID: remote, portDescr: descr, capabilities: caps)
    }

    func snapshot(_ host: String, _ name: String, _ interfaces: [SNMPInterface], _ neighbors: [SNMPLLDPNeighbor],
                  pvid: [Int: Int] = [:], fdb: [SNMPFDBEntry] = [], controller: String? = nil) -> SNMPSwitchSnapshot {
        SNMPSwitchSnapshot(host: IPv4Address(host)!, system: SNMPSystemInfo(name: name, descr: ""), interfaces: interfaces,
                           fdb: fdb, neighbors: neighbors, pvid: pvid, polledAt: now, controllerName: controller)
    }

    // Siège : FortiGate, cœur Cisco, étage Aruba, borne ; FortiSwitch derrière FortiLink (hors scan).
    func devices() -> [Device] {
        [
            device("10.182.122.1", "FortiGate-60F", name: "Passerelle", .routeur),
            device("10.182.122.2", "SW-CORE-01", .switch),
            // Nom d'hôte avec domaine ; champ « switch » faux (relevé périmé) : LLDP corrige.
            device("10.182.122.3", "sw-etg2-01.siege.local", .switch, sw: "SW-ETG2-01", port: "1/1"),
            device("10.182.122.102", "FortiAP-231F", .pointAcces, sw: "SW-CORE-01", port: "Gi1/0/12"),
            device("10.182.122.117", "WKS346", .poste, sw: "SW-CORE-01", port: "Gi1/0/22", vlan: 1),
            device("10.182.122.111", "Brother", .imprimante, sw: "SW-ETG2-01", port: "1/14", vlan: 30),
            device("10.182.122.140", "NPI7A4410", .imprimante, sw: "SW-ETG2-01", port: "1/18", vlan: 30),
            device("192.168.50.31", "CAM-ENTREPOT-01", .camera, sw: "FSW-QUAI", port: "port1", vlan: 40),
            device("10.182.122.160", "Inconnu", .inconnu),
        ]
    }

    func switches(redundant: Bool = false) -> [SNMPSwitchSnapshot] {
        var coreIfs = [port(1, "Gi1/0/1"), port(12, "Gi1/0/12"), port(13, "Gi1/0/13"), port(47, "Gi1/0/47", speed: 10_000)]
        var coreNb = [
            neighbor(1, "FortiGate-60F", "internal1", [.router, .bridge]),
            neighbor(12, "FortiAP-231F", "eth0", [.accessPoint]),
            neighbor(13, "SEP001B54AABB13", "Port 1", [.bridge, .telephone]),   // téléphone : pas un nœud
            neighbor(47, "SW-ETG2-01", "1/25"),
        ]
        var etgIfs = [port(25, "1/25", speed: 10_000), port(20, "1/20")]
        var etgNb = [
            // Identifiant de port = MAC : la description sert à sa place.
            neighbor(25, "sw-core-01.siege.local", "70:0f:6a:91:4c:2f", descr: "Gi1/0/47"),
            neighbor(20, "SW-LOCAL-TECH", "24"),   // switch annoncé, absent du scan
        ]
        if redundant {
            coreIfs.append(port(48, "Gi1/0/48"))
            coreNb.append(neighbor(48, "SW-ETG2-01", "1/26"))
            etgIfs.append(port(26, "1/26"))
            etgNb.append(neighbor(26, "SW-CORE-01", "Gi1/0/48"))
        }
        let core = snapshot("10.182.122.2", "SW-CORE-01", coreIfs, coreNb, pvid: [47: 1, 12: 20],
                            fdb: [SNMPFDBEntry(mac: MACAddress("00:1a:2b:44:10:ee")!, vlan: 30, bridgePort: 47, ifIndex: 47)])
        let etg = snapshot("10.182.122.3", "SW-ETG2-01", etgIfs, etgNb, pvid: [25: 1])
        // FortiSwitch lus par la FortiGate (FortiConvert : portID « FortiLink » / « ISL »).
        let entrepot = snapshot("10.255.1.2", "FSW-ENTREPOT", [port(49, "port49", speed: 10_000), port(51, "port51", speed: 10_000)],
                                [neighbor(49, "FGT-SIEGE", "FortiLink", [.router, .bridge]), neighbor(51, "FSW-QUAI", "ISL")],
                                pvid: [51: 1], fdb: [SNMPFDBEntry(mac: MACAddress("bc:ad:28:6f:22:31")!, vlan: 40, bridgePort: 51, ifIndex: 51)],
                                controller: "FGT-SIEGE")
        let quai = snapshot("10.255.1.3", "FSW-QUAI", [port(25, "port25", speed: 10_000)], [neighbor(25, "FSW-ENTREPOT", "ISL")],
                            controller: "FGT-SIEGE")
        return [core, etg, entrepot, quai]
    }

    func graph(_ list: [Device] = devices(), redundant: Bool = false) -> TopoGraph {
        TopoGraph.build(devices: list, gateway: gatewayIP, switches: switches(redundant: redundant))
    }

    suite.add("Carte, LLDP : le cœur sous la passerelle, l'étage sous le cœur avec les ports des deux bouts") {
        let map = graph()
        let core = map.node("dev:10.182.122.2")
        try expectEqual(core?.parentID, "passerelle", "cœur relié à la FortiGate par LLDP")
        try expectEqual(core?.uplinkLabel, "internal1 ↔ Gi1/0/1", "ports passerelle ↔ cœur")
        try expectEqual(core?.uplinkKind, .uplink, "lien vers la passerelle")
        let etg = map.node("dev:10.182.122.3")
        try expectEqual(etg?.parentID, "dev:10.182.122.2", "LLDP corrige le champ « switch » périmé")
        try expectEqual(etg?.uplinkLabel, "Gi1/0/47 ↔ 1/25", "ports des deux bouts, du parent à l'enfant")
        try expectEqual(etg?.uplinkKind, .isl, "lien inter-switch")
        let ap = map.node("dev:10.182.122.102")
        try expectEqual(ap?.uplinkKind, .accessPoint, "borne branchée sur le cœur")
        try expectEqual(ap?.uplinkLabel, "Gi1/0/12 ↔ eth0", "port de la borne")
        try expect(!map.nodes.contains { $0.title.hasPrefix("SEP") }, "un téléphone annoncé par LLDP n'est pas un switch")
    }

    suite.add("Carte, FortiGate : FortiSwitch hors scan rattachés par FortiLink et ISL") {
        let map = graph()
        let entrepot = map.node("sw:fsw-entrepot")
        try expect(entrepot != nil, "FSW-ENTREPOT appris par le relevé de la FortiGate")
        try expectEqual(entrepot?.parentID, "passerelle", "FortiLink vers la passerelle (nom du contrôleur)")
        try expectEqual(entrepot?.uplinkLabel, "FortiLink ↔ port49", "port FortiLink")
        try expectEqual(entrepot?.uplinkKind, .fortiLink, "nature du lien")
        try expectEqual(entrepot?.subtitle, "FortiSwitch · FGT-SIEGE", "décrit par le relevé")
        try expect(entrepot?.note?.contains("FortiLink") == true, "note du détail")
        let quai = map.node("sw:fsw-quai")
        try expectEqual(quai?.parentID, "sw:fsw-entrepot", "FSW-QUAI derrière FSW-ENTREPOT (ISL)")
        try expectEqual(quai?.uplinkLabel, "port51 ↔ port25", "ports ISL des deux FortiSwitch")
        try expectEqual(quai?.subtitle, "FortiSwitch · FGT-SIEGE", "switch nommé par un appareil, décrit par le relevé")
        let camera = map.nodes.first { $0.deviceIDs.contains("192.168.50.31") }
        try expectEqual(camera?.parentID, "sw:fsw-quai", "la caméra reste sous son FortiSwitch")
    }

    suite.add("Carte, LLDP : switch annoncé mais absent du scan, nom avec domaine, port MAC remplacé") {
        let map = graph()
        let local = map.node("sw:sw-local-tech")
        try expectEqual(local?.parentID, "dev:10.182.122.3", "sous le switch qui l'annonce")
        try expectEqual(local?.subtitle, "Annoncé par LLDP", "sous-titre")
        try expectEqual(local?.uplinkLabel, "1/20 ↔ 24", "ports")
        let link = map.infraLink("dev:10.182.122.2", "dev:10.182.122.3")
        try expectEqual(link?.port(at: "dev:10.182.122.2"), "Gi1/0/47", "port du cœur donné par son propre relevé")
        try expectEqual(link?.port(at: "dev:10.182.122.3"), "1/25", "port de l'étage")
        try expectEqual(link?.speedLabel, "10 Gb/s", "vitesse")
        try expectEqual(link?.vlans, [1, 30], "VLAN natif et VLAN appris sur le port")
        try expectEqual(link?.sourceLabel, "LLDP (SNMP)", "source")
        // Passerelle-cœur, cœur-borne, cœur-étage, étage-local, FortiLink, ISL (vu des deux bouts : un seul lien).
        try expectEqual(map.infraLinks.count, 6, "un lien par paire d'équipements")
        try expect(map.redundantLinks.isEmpty, "aucun lien redondant")
    }

    suite.add("Carte, LLDP : deuxième lien entre deux switchs gardé comme lien redondant") {
        let map = graph(redundant: true)
        try expectEqual(map.redundantLinks.count, 1, "un lien redondant")
        let extra = try required78(map.redundantLinks.first, "lien redondant")
        try expectEqual(extra.portsLabel, "Gi1/0/48 ↔ 1/26", "ports du lien redondant")
        try expect(!extra.isTree, "hors hiérarchie")
        try expectEqual(map.node("dev:10.182.122.3")?.uplinkLabel, "Gi1/0/47 ↔ 1/25", "le lien le plus rapide porte la hiérarchie")
        try expectEqual(map.links.filter { $0.child.id == "dev:10.182.122.3" }.count, 1, "un seul parent")
    }

    suite.add("Carte, LLDP : groupe isolé de la passerelle et carte sans relevé inchangée") {
        let list = [
            device("10.0.0.1", "gw", .routeur),
            device("10.0.0.2", "SW-A", .switch),
            device("10.0.0.3", "SW-B", .switch, sw: "SW-A", port: "9"),
        ]
        let a = snapshot("10.0.0.2", "SW-A", [port(5, "5")], [neighbor(5, "SW-B", "7")])
        let map = TopoGraph.build(devices: list, gateway: IPv4Address("10.0.0.1"), switches: [a])
        try expectEqual(map.node("dev:10.0.0.2")?.parentID, "passerelle", "SW-A garde son parent par nom")
        try expectEqual(map.node("dev:10.0.0.3")?.parentID, "dev:10.0.0.2", "SW-B sous SW-A")
        try expectEqual(map.node("dev:10.0.0.3")?.uplinkLabel, "5 ↔ 7", "ports LLDP")
        let plain = TopoGraph.build(devices: list, gateway: IPv4Address("10.0.0.1"))
        try expect(plain.infraLinks.isEmpty, "sans relevé, aucun lien LLDP")
        try expectEqual(plain.node("dev:10.0.0.3")?.uplinkLabel, "9", "port du champ « switch »")
        try expectEqual(plain.node("dev:10.0.0.3")?.uplinkKind, nil, "rattachement par nom")
    }

    suite.add("Carte, VLAN : appareils filtrés, infrastructure gardée, branches qui portent le VLAN") {
        let all = devices()
        let kept = TopoVLAN.filter(all, .vlan(40), gateway: gatewayIP)
        try expectEqual(Set(kept.filter { $0.deviceType == .camera }.map(\.id)), ["192.168.50.31"], "la caméra du VLAN 40")
        try expect(!kept.contains { $0.deviceType == .imprimante || $0.deviceType == .poste }, "les autres appareils finaux sont retirés")
        try expectEqual(kept.filter { $0.deviceType == .switch || $0.deviceType == .pointAcces }.count, 3, "switchs et borne gardés")
        let map = graph(kept)
        let carrying = map.nodesCarrying(.vlan(40), devices: kept)
        try expect(carrying.contains("sw:fsw-quai") && carrying.contains("sw:fsw-entrepot"), "branche FortiSwitch")
        try expect(carrying.contains("passerelle"), "passerelle toujours")
        try expect(!carrying.contains("dev:10.182.122.3"), "l'étage ne porte pas le VLAN 40")
        try expect(!carrying.contains("dev:10.182.122.102"), "la borne non plus")
        let printers = map.nodesCarrying(.vlan(30), devices: TopoVLAN.filter(all, .vlan(30), gateway: gatewayIP))
        try expect(printers.contains("dev:10.182.122.2"), "le cœur porte le VLAN 30 (vu sur son lien vers l'étage)")
        try expectEqual(map.nodesCarrying(.all, devices: kept).count, map.nodes.count, "sans filtre, tout est porté")

        let choices = TopoVLAN.choices(all, links: graph().infraLinks, gateway: gatewayIP)
        try expectEqual(choices.map(\.id), ["1", "20", "30", "40", "inconnu"], "VLAN proposés, inconnu à la fin")
        try expectEqual(choices.first { $0.id == "30" }?.deviceCount, 2, "deux imprimantes")
        try expectEqual(choices.first { $0.id == "20" }?.deviceCount, 0, "VLAN vu seulement sur un lien")
        try expectEqual(TopoVLAN.filter(all, .unknown, gateway: gatewayIP).filter { !TopoVLAN.isInfrastructure($0, gateway: gatewayIP) }.map(\.id),
                        ["10.182.122.160"], "VLAN inconnu")
        try expectEqual(TopoVLANFilter(captureValue: "40"), .vlan(40), "valeur de capture")
        try expectEqual(TopoVLANFilter(captureValue: "inconnu"), .unknown, "valeur de capture « inconnu »")
        try expect(TopoVLANFilter(captureValue: "5000") == nil, "VLAN hors limites")
    }

    suite.add("Carte, disposition : nœud déplacé retenu, gardé dans le dessin, rendu, fichier par site") {
        let map = graph()
        let auto = map.layout(nodeWidth: 178, nodeHeight: 54, maxStack: 4, margin: 22)
        var manual = TopoManualLayout()
        try expect(auto.applying(manual).moved.isEmpty, "rien de déplacé")
        let stackedID = try required78(auto.stacked.first, "une feuille empilée")
        manual.move(stackedID, to: TopoGraph.Point(x: 2000.4, y: 1500.6), nodeWidth: 178, nodeHeight: 54, at: now)
        manual.move("dev:10.182.122.2", to: TopoGraph.Point(x: -50, y: 3), nodeWidth: 178, nodeHeight: 54, at: now)
        try expectEqual(manual.positions[stackedID], TopoGraph.Point(x: 2000, y: 1501), "position arrondie")
        try expectEqual(manual.positions["dev:10.182.122.2"], TopoGraph.Point(x: 111, y: 49), "jamais hors de la marge")
        manual.positions["absent"] = TopoGraph.Point(x: 10, y: 10)
        let applied = auto.applying(manual)
        try expectEqual(applied.moved, [stackedID, "dev:10.182.122.2"], "nœuds déplacés présents seulement")
        try expect(!applied.stacked.contains(stackedID), "un nœud déplacé n'est plus empilé")
        try expectEqual(applied.width, 2000 + 89 + 22, "dessin agrandi en largeur")
        try expectEqual(applied.height, 1501 + 27 + 22, "dessin agrandi en hauteur")
        try expectEqual(manual.movedCount(in: applied), 2, "compte du dessin")
        let other = auto.positions.keys.first { $0 != stackedID && $0 != "dev:10.182.122.2" }!
        try expectEqual(applied.positions[other], auto.positions[other], "les autres nœuds ne bougent pas")

        // Fichier : aller-retour, illisible, version future, effacement quand tout est rendu.
        let decoded = TopoManualLayout.decode(try manual.encoded())
        try expectEqual(decoded, manual, "aller-retour JSON")
        try expect(TopoManualLayout.decode(Data("pas du json".utf8)) == nil, "fichier illisible")
        try expect(TopoManualLayout.decode(Data(#"{"version":9,"positions":{}}"#.utf8)) == nil, "version future")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-carte-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = TopoManualLayout.url(in: folder)
        try manual.save(to: url)
        try expectEqual(TopoManualLayout.load(from: url), manual, "relu du dossier du site")
        manual.restore(stackedID)
        manual.restore("dev:10.182.122.2")
        manual.restore("absent")
        try expect(manual.isEmpty, "tout est rendu")
        try manual.save(to: url)
        try expect(!FileManager.default.fileExists(atPath: url.path), "disposition vide : fichier effacé")
        try expect(TopoManualLayout.load(from: url).isEmpty, "absent : disposition automatique")
    }
}
