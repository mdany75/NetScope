import Foundation
import NetScopeCore

// 0.14.0, note 32 : recherche dans la Carte du réseau. Résultat → nœud ou groupe qui contient
// l'appareil, ordre des résultats, parcours suivant / précédent, chemin de la branche, borne
// Wi-Fi, autres sites. Données fixes, aucun réseau.

func registerTopoSearchTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)

    func device(_ ip: String, _ mac: String?, _ host: String, name: String? = nil, _ type: DeviceType,
                sw: String? = nil, port: String? = nil, vlan: Int? = nil, online: Bool = true) -> Device {
        Device(ip: IPv4Address(ip)!, mac: mac.flatMap(MACAddress.init), hostname: host, customName: name, isOnline: online,
               switchName: sw, switchPort: port, vlan: vlan, firstSeen: now, lastSeen: now, deviceType: type)
    }

    // Siège : passerelle, deux switchs, une borne, deux imprimantes et onze téléphones sur l'étage 2,
    // un poste seul sur le cœur, un client Wi-Fi.
    func siege() -> [Device] {
        var list = [
            device("10.182.122.1", "04:D5:90:3A:7B:11", "FortiGate-60F", name: "Passerelle", .routeur, sw: "SW-CORE-01", port: "Gi1/0/1"),
            device("10.182.122.2", "70:0F:6A:91:4C:02", "SW-CORE-01", name: "Switch cœur", .switch, sw: "SW-CORE-01", port: "Vlan1 (SVI)"),
            device("10.182.122.3", "88:3A:30:5D:E1:40", "SW-ETG2-01", name: "Switch étage 2", .switch, sw: "SW-CORE-01", port: "Gi1/0/47"),
            device("10.182.122.102", "70:4C:A5:1E:22:9A", "FortiAP-231F", name: "Borne Wi-Fi accueil", .pointAcces, sw: "SW-CORE-01", port: "Gi1/0/12"),
            device("10.182.122.111", "94:DD:F8:18:15:7D", "Brother DCP-L2640DW", name: "Imprimante accueil", .imprimante, sw: "SW-ETG2-01", port: "1/14", vlan: 30),
            device("10.182.122.140", "00:1A:2B:44:10:EE", "NPI7A4410", .imprimante, sw: "SW-ETG2-01", port: "1/18", vlan: 30),
            device("10.182.122.117", "B0:7B:25:44:A1:6C", "WKS346", name: "Poste comptabilité", .poste, sw: "SW-CORE-01", port: "Gi1/0/22"),
            device("10.182.122.135", "3C:22:FB:7E:05:B1", "Macmini-de-Dany.local", name: "Ce Mac", .poste, sw: "FortiAP-231F", port: "Wi-Fi", vlan: 20),
        ]
        for n in 0..<11 {
            list.append(device("10.182.122.\(150 + n)", String(format: "00:04:F2:AA:01:%02X", 0x50 + n), "SEP-\(150 + n)", .telephone,
                               sw: "SW-ETG2-01", port: "1/\(30 + n)", vlan: 50))
        }
        return list
    }

    func graph(_ devices: [Device]) -> TopoGraph {
        TopoGraph.build(devices: devices, gateway: IPv4Address("10.182.122.1"))
    }

    func hits(_ text: String, _ devices: [Device]) -> (TopoGraph, [TopoSearchHit]) {
        let map = graph(devices)
        let found = TopoSearch.hits(SearchQuery(text, schema: .carte), graph: map, items: TopoSearch.items(devices, graph: map))
        return (map, found)
    }

    suite.add("Carte, recherche : une IP d'imprimante désigne son groupe « Imprimantes ×2 »") {
        let (map, found) = hits("10.182.122.140", siege())
        try expectEqual(found.count, 1, "une seule imprimante à cette IP")
        let hit = try requireFirst(found)
        try expectEqual(hit.deviceID, "10.182.122.140", "appareil désigné")
        try expect(hit.isInGroup, "l'imprimante est dans un groupe")
        try expect(hit.isExact, "IP complète : résultat exact")
        let node = map.node(hit.nodeID)
        try expectEqual(node?.title, "Imprimantes ×2", "groupe qui contient l'imprimante")
        try expectEqual(TopoSearch.location(of: hit, in: map), "Imprimantes ×2 · Switch étage 2", "emplacement en mots")
    }

    suite.add("Carte, recherche : un téléphone parmi onze, un switch par son nom, la passerelle") {
        let (map, phone) = hits("00:04:f2:aa:01:55", siege())
        try expectEqual(phone.map(\.deviceID), ["10.182.122.155"], "MAC complète")
        try expectEqual(map.node(phone[0].nodeID)?.title, "Téléphones ×11", "groupe des onze téléphones")
        let (_, sw) = hits("SW-ETG2-01", siege())
        try expectEqual(sw.first?.nodeID, "dev:10.182.122.3", "le switch lui-même passe avant ce qui y est branché")
        try expect(sw.first?.isExact == true, "nom complet du switch : exact")
        try expect(sw.count > 1, "les appareils branchés sur ce switch suivent (champ switch)")
        let (_, gateway) = hits("ip:10.182.122.1", siege())
        try expectEqual(gateway.map(\.nodeID), ["passerelle"], "ip: complète : la passerelle seulement, pas .1xx")
        let (_, alone) = hits("comptabilite", siege())
        try expectEqual(alone.map(\.nodeID), ["dev:10.182.122.117"], "un appareil seul : son propre nœud, sans accent")
        try expect(alone.first?.isInGroup == false, "nœud seul")
    }

    suite.add("Carte, recherche : ordre des résultats (exact d'abord, puis la carte, puis l'IP)") {
        // « 10.182.122.15 » sans préfixe : .15x contient le texte ; l'IP exacte n'existe pas.
        let (map, prefix) = hits("10.182.122.15", siege())
        try expectEqual(prefix.map(\.deviceID), (150...159).map { "10.182.122.\($0)" }, "par IP dans le groupe")
        try expect(prefix.allSatisfy { !$0.isExact }, "aucune adresse exacte")
        // type:imprimante : les deux imprimantes, dans le groupe, par IP.
        let (_, printers) = hits("type:imprimante", siege())
        try expectEqual(printers.map(\.deviceID), ["10.182.122.111", "10.182.122.140"], "imprimantes par IP")
        // vlan:30 OU nom exact : l'exact d'abord même s'il vient plus loin sur la carte.
        let (_, exactFirst) = hits("10.182.122.111", siege())
        try expectEqual(exactFirst.first?.deviceID, "10.182.122.111", "l'IP exacte en premier")
        // Ordre de la carte : branche du switch cœur (relevé) avant le poste seul sous le cœur, etc.
        let (_, office) = hits("switch:SW-CORE-01", siege())
        let order = office.map(\.nodeID)
        try expect(order.firstIndex(of: "dev:10.182.122.3")! < order.firstIndex(of: "dev:10.182.122.117")!,
                   "le switch d'étage (une branche) avant le poste branché sur le cœur (une feuille)")
        try expect(Set(order).isSubset(of: Set(map.nodes.map(\.id))), "chaque résultat a son nœud")
        // Requête vide ou négative seule.
        try expect(hits("", siege()).1.isEmpty, "requête vide : aucun résultat")
        try expect(hits("   ", siege()).1.isEmpty, "espaces : aucun résultat")
        try expect(hits("type:imprimante -nom:accueil", siege()).1.map(\.deviceID) == ["10.182.122.140"], "exclusion")
        try expect(hits("introuvable-xyz", siege()).1.isEmpty, "aucun appareil : liste vide")
    }

    suite.add("Carte, recherche : borne Wi-Fi, port, VLAN") {
        let (_, wifi) = hits("borne:accueil", siege())
        try expectEqual(wifi.map(\.deviceID), ["10.182.122.135"], "borne: par le titre du nœud de la borne")
        let (_, byAP) = hits("borne:FortiAP-231F", siege())
        try expectEqual(byAP.map(\.deviceID), ["10.182.122.135"], "borne: par le nom relevé")
        let (map, mac) = hits("Ce Mac", siege())
        try expectEqual(mac.first.map { TopoSearch.location(of: $0, in: map) }, "Wi-Fi · Borne Wi-Fi accueil", "client sans fil")
        let (_, port) = hits("switch:SW-ETG2 port:14", siege())
        try expectEqual(port.map(\.deviceID), ["10.182.122.111"], "switch: et port:")
        let (_, vlan) = hits("vlan:50", siege())
        try expectEqual(vlan.count, 11, "vlan:50 : les onze téléphones")
        let ap = TopoSearch.accessPoints(of: siege()[0], graph: graph(siege()))
        try expect(ap.isEmpty, "appareil filaire : aucune borne")
    }

    suite.add("Carte, recherche : chemin de la branche, compteurs, suivant et précédent en boucle") {
        let (map, phones) = hits("type:telephone", siege())
        let hit = try requireFirst(phones)
        let path = TopoSearch.path(to: hit.nodeID, in: map)
        try expectEqual(path.first, "internet", "le chemin part d'Internet")
        try expectEqual(path.last, hit.nodeID, "et finit sur le groupe")
        try expect(path.contains("dev:10.182.122.3"), "en passant par le switch d'étage")
        try expectEqual(TopoSearch.countsByNode(phones)[hit.nodeID], 11, "onze trouvés dans le groupe")
        try expectEqual(TopoSearch.matchedNodeIDs(phones).count, 1, "un seul nœud surligné")
        try expectEqual(TopoSearch.step(0, by: 1, count: 5), 1, "suivant")
        try expectEqual(TopoSearch.step(4, by: 1, count: 5), 0, "suivant après le dernier : le premier")
        try expectEqual(TopoSearch.step(0, by: -1, count: 5), 4, "précédent avant le premier : le dernier")
        try expectEqual(TopoSearch.step(3, by: 1, count: 0), 0, "aucun résultat")
        try expectEqual(TopoSearch.position(1, count: 5), "2 sur 5", "compteur")
        try expectEqual(TopoSearch.position(9, count: 5), "5 sur 5", "compteur ramené dans la liste")
        try expectEqual(TopoSearch.path(to: "absent", in: map), [], "nœud absent : aucun chemin")
    }

    suite.add("Carte, recherche : autres sites où la recherche trouve aussi des appareils") {
        let laval = [
            device("10.20.0.1", "00:09:0F:AA:10:01", "FGT-LAVAL", .routeur),
            device("10.20.40.21", "BC:AD:28:20:40:01", "CAM-LAV-01", .camera, sw: "FSW-LAVAL-02", port: "port1", vlan: 40),
            device("10.20.40.22", "BC:AD:28:20:40:02", "CAM-LAV-02", .camera, sw: "FSW-LAVAL-02", port: "port2", vlan: 40),
            // Même IP qu'une imprimante du siège, autre appareil.
            device("10.182.122.140", "00:11:22:33:44:55", "imprimante-laval", .imprimante),
        ]
        let quebec = [device("10.30.0.1", nil, "FGT-QC", .routeur)]
        let sites = [
            TopoSiteDevices(key: "siege", name: "Siège", devices: siege()),
            TopoSiteDevices(key: "laval", name: "Entrepôt Laval", devices: laval),
            TopoSiteDevices(key: "quebec", name: "Bureau Québec", devices: quebec),
        ]
        let ip = TopoSearch.otherSites(SearchQuery("10.182.122.140", schema: .carte), sites: sites, excluding: "siege")
        try expectEqual(ip, [TopoSiteMatch(key: "laval", name: "Entrepôt Laval", count: 1)], "la même IP à Laval")
        try expectEqual(ip.first?.label, "Entrepôt Laval", "un appareil : le nom seul")
        let cameras = TopoSearch.otherSites(SearchQuery("type:camera", schema: .carte), sites: sites, excluding: "siege")
        try expectEqual(cameras.map(\.label), ["Entrepôt Laval (2)"], "deux caméras à Laval, aucune à Québec")
        let fromLaval = TopoSearch.otherSites(SearchQuery("10.182.122.140", schema: .carte), sites: sites, excluding: "laval")
        try expectEqual(fromLaval.map(\.key), ["siege"], "dessin de Laval : le siège est proposé")
        try expect(TopoSearch.otherSites(SearchQuery("", schema: .carte), sites: sites, excluding: "siege").isEmpty,
                   "requête vide : aucun site")
        // Le site dessiné n'est jamais proposé, même s'il a des résultats.
        try expect(!cameras.contains { $0.key == "siege" }, "jamais le site dessiné")
    }

    suite.add("Carte, recherche : appareils en double et appareils hors du dessin") {
        var devices = siege()
        devices.append(devices[4])   // même Device.id deux fois
        let (map, found) = hits("10.182.122.111", devices)
        try expectEqual(found.count, 1, "un résultat par appareil")
        // Un élément dont l'appareil n'est pas dessiné est ignoré.
        let stranger = TopoSearchItem(device("10.99.0.9", nil, "ailleurs", .poste))
        let none = TopoSearch.hits(SearchQuery("ailleurs", schema: .carte), graph: map, items: [stranger])
        try expect(none.isEmpty, "appareil absent de la carte : ignoré")
        // Le préfixe « borne: » est reconnu sur la carte, avec ses synonymes.
        try expectEqual(SearchSchema.carte.field(forPrefix: "ap")?.key, "borne", "ap: = borne:")
        try expectEqual(SearchSchema.carte.field(forPrefix: "sw")?.key, "switch", "sw: = switch:")
    }
}

private func requireFirst<T>(_ list: [T], file: String = #fileID, line: Int = #line) throws -> T {
    guard let first = list.first else { throw TestFailure(message: "liste vide", file: file, line: line) }
    return first
}
