import Foundation
import NetScopeCore

// 0.13.0, notes 31, 33 et 34 : suite logique du double-clic (destination de chaque type d'objet),
// menu « Ouvrir dans › », historique Retour / Avancer, filtres transmis (groupe de la Carte →
// ensemble exact d'appareils, port → appareils, plusieurs sites), ports vides et uplinks.
// Données fixes, aucun réseau.

func registerNavigationTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)
    let siege = "siege"
    let laval = "laval"

    func device(_ ip: String, _ mac: String?, _ name: String, sw: String? = nil, port: String? = nil) -> NavDeviceRef {
        NavDeviceRef(ip: ip, mac: mac, name: name, switchName: sw, switchPort: port)
    }
    func record(_ ip: String, _ mac: String?, host: String) -> InvRecord {
        let address = IPv4Address(ip)!
        let hardware = mac.flatMap(MACAddress.init)
        let key = hardware.map { InventoryStore.key(mac: $0) } ?? InventoryStore.key(ip: address)
        return InvRecord(key: key, mac: hardware, ip: address, hostname: host, firstSeen: now, lastSeen: now)
    }

    // Scanner du siège : imprimante, poste, téléphone, et le switch d'étage.
    let printer = device("10.182.122.111", "94:DD:F8:18:15:7D", "Imprimante accueil", sw: "SW-ETG2-01", port: "1/14")
    let desk = device("10.182.122.113", "8C:16:45:2B:9E:03", "Portable Marc", sw: "SW-ETG2-01", port: "1/3")
    let phone = device("10.182.122.150", "00:04:F2:AA:01:50", "Téléphone 150", sw: "SW-ETG2-01", port: "1/3")
    let switchDevice = device("10.182.122.3", "88:3A:30:5D:E1:40", "Switch étage 2", sw: "SW-CORE-01", port: "Gi1/0/47")
    // Inventaire du siège : le poste de la réception, absent du dernier scan.
    let reception = record("10.182.122.146", "B0:7B:25:44:9F:20", host: "WKS341")
    // Inventaire de Laval : même IP que l'imprimante du siège, autre appareil.
    let lavalTwin = record("10.182.122.111", "00:11:22:33:44:55", host: "imprimante-laval")

    func snapshot() -> SNMPSwitchSnapshot {
        let interfaces = [
            SNMPInterface(index: 3, name: "1/3", operStatus: .up, speedMbps: 1000),
            SNMPInterface(index: 7, name: "1/7", operStatus: .down),
            SNMPInterface(index: 9, name: "1/9", operStatus: .up, speedMbps: 1000),
            SNMPInterface(index: 14, name: "1/14", operStatus: .up, speedMbps: 1000),
            SNMPInterface(index: 20, name: "1/20", operStatus: .up, speedMbps: 1000),
            SNMPInterface(index: 24, name: "1/24", operStatus: .up, speedMbps: 10000),
            SNMPInterface(index: 25, name: "1/25", operStatus: .up, speedMbps: 1000),
        ]
        var fdb = [
            SNMPFDBEntry(mac: MACAddress("94:DD:F8:18:15:7D")!, vlan: 30, bridgePort: 14, ifIndex: 14),
            SNMPFDBEntry(mac: MACAddress("8C:16:45:2B:9E:03")!, vlan: 1, bridgePort: 3, ifIndex: 3),
            SNMPFDBEntry(mac: MACAddress("00:04:F2:AA:01:50")!, vlan: 1, bridgePort: 3, ifIndex: 3),
            // Port 20 : une MAC que personne ne connaît encore.
            SNMPFDBEntry(mac: MACAddress("DE:AD:BE:EF:00:20")!, vlan: 1, bridgePort: 20, ifIndex: 20),
            // Port 25 : le poste de la réception (seulement dans l'inventaire).
            SNMPFDBEntry(mac: MACAddress("B0:7B:25:44:9F:20")!, vlan: 1, bridgePort: 25, ifIndex: 25),
        ]
        // Port 24 : uplink (dix MAC, voisin LLDP pont).
        for n in 0..<10 {
            fdb.append(SNMPFDBEntry(mac: MACAddress(String(format: "02:00:00:00:00:%02X", n))!, vlan: 1, bridgePort: 24, ifIndex: 24))
        }
        let neighbors = [SNMPLLDPNeighbor(localPortNum: 24, ifIndex: 24, sysName: "SW-CORE-01", portID: "Gi1/0/47",
                                          capabilities: .bridge)]
        return SNMPSwitchSnapshot(host: IPv4Address("10.182.122.3")!, system: SNMPSystemInfo(name: "SW-ETG2-01", descr: "Aruba"),
                                  interfaces: interfaces, fdb: fdb, neighbors: neighbors, polledAt: now)
    }
    func core() -> SNMPSwitchSnapshot {
        SNMPSwitchSnapshot(host: IPv4Address("10.182.122.2")!, system: SNMPSystemInfo(name: "SW-CORE-01", descr: "Cisco"),
                           interfaces: [SNMPInterface(index: 47, name: "Gi1/0/47", operStatus: .up)], polledAt: now)
    }
    let probeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!.uuidString
    let remoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!.uuidString
    func context() -> NavContext {
        NavContext(activeSiteKey: siege, scanner: [printer, desk, phone, switchDevice],
                   inventories: [siege: [reception, record(printer.ip, printer.mac, host: "imprimante")], laval: [lavalTwin]],
                   switches: [snapshot(), core()],
                   accessPoints: [(id: "siege|FP231F0001", name: "AP-ACCUEIL", ip: "10.182.122.102")],
                   wifiClients: ["8C:16:45:2B:9E:03": "siege|FP231F0001"],
                   probes: [NavProbeRef(id: probeID, name: "Imprimante", kind: .tcp, target: "10.182.122.111:9100")],
                   remoteHosts: ["10.182.122.113": remoteID])
    }

    // MARK: Destination de chaque type d'objet

    suite.add("Navigation : un appareil du Scanner ouvre sa fiche Appareil") {
        try expectEqual(NavResolver.primary(.device(printer), in: context()).destination,
                        NavDestination(.appareil, focus: .device(printer.ip)), "fiche de l'imprimante")
    }

    suite.add("Navigation : un appareil absent du scan ouvre sa fiche d'inventaire, un inconnu un message") {
        let ref = NavDeviceRef(reception, siteKey: nil)
        try expectEqual(NavResolver.primary(.device(ref), in: context()).destination,
                        NavDestination(.inventaire, focus: .record(site: siege, key: reception.key)), "fiche d'inventaire du site actif")
        guard case .message(let title, _, _) = NavResolver.primary(.device(device("10.9.9.9", nil, "Inconnu")), in: context()) else {
            throw TestFailure(message: "un appareil inconnu donne un message", file: #fileID, line: #line)
        }
        try expectEqual(title, "Appareil pas encore vu", "titre du message")
    }

    suite.add("Navigation : appareil d'un autre site → son inventaire, jamais l'appareil du siège à la même IP") {
        let ref = NavDeviceRef(lavalTwin, siteKey: laval)
        try expectEqual(NavResolver.primary(.device(ref), in: context()).destination,
                        NavDestination(.inventaire, focus: .record(site: laval, key: lavalTwin.key), sites: .include(laval)),
                        "fiche de Laval, site inclus")
        // Même IP que l'imprimante du siège, mais autre MAC : pas la fiche Appareil du siège.
        let stranger = device(printer.ip, "00:11:22:33:44:55", "Autre")
        try expect(NavResolver.primary(.device(stranger), in: context()).destination?.module != .appareil,
                   "une autre MAC à la même IP n'ouvre pas la fiche de l'imprimante")
    }

    suite.add("Navigation : switch, borne, client Wi-Fi, plage, VLAN, site") {
        let ctx = context()
        try expectEqual(NavResolver.primary(.switchUnit(host: nil, name: "sw-etg2-01"), in: ctx).destination,
                        NavDestination(.switchs, focus: .switchPort(host: "10.182.122.3", port: nil)), "switch par son nom")
        guard case .message = NavResolver.primary(.switchUnit(host: nil, name: "SW-INCONNU"), in: ctx) else {
            throw TestFailure(message: "switch non relevé : message", file: #fileID, line: #line)
        }
        try expectEqual(NavResolver.primary(.accessPoint(id: "siege|FP231F0001", name: "AP-ACCUEIL", ip: nil), in: ctx).destination,
                        NavDestination(.wifi, focus: .accessPoint("siege|FP231F0001")), "borne → Wi-Fi › FortiAP")
        try expectEqual(NavResolver.primary(.wifiClient(mac: desk.mac, ip: nil, name: "Portable", apID: "siege|FP231F0001"), in: ctx).destination,
                        NavDestination(.appareil, focus: .device(desk.ip)), "client Wi-Fi → sa fiche")
        try expectEqual(NavResolver.primary(.range(text: "10.182.122.0/24", label: "Bureau"), in: ctx).destination,
                        NavDestination(.scanner, search: "plage:Bureau"), "plage → Scanner filtré")
        try expectEqual(NavResolver.primary(.range(text: "10.10.0.1-50", label: "Salle serveurs"), in: ctx).destination?.search,
                        "plage:\"Salle serveurs\"", "nom à espaces entre guillemets")
        try expectEqual(NavResolver.primary(.range(text: "10.10.0.0/24", label: nil), in: ctx).destination?.search,
                        "ip:10.10.0.0/24", "plage sans nom : bloc CIDR")
        try expectEqual(NavResolver.primary(.vlan(30), in: ctx).destination, NavDestination(.scanner, search: "vlan:30"), "VLAN")
        try expectEqual(NavResolver.primary(.site(key: laval, name: "Laval"), in: ctx).destination,
                        NavDestination(.inventaire, sites: .only([laval])), "site → Inventaire de ce site")
    }

    suite.add("Navigation : sonde → sa cible ; alerte → la sonde ; événement d'Analyse → fiche et chronologie") {
        let ctx = context()
        let probe = ctx.probes[0]
        try expectEqual(probe.host, "10.182.122.111", "hôte d'une sonde TCP")
        try expectEqual(NavResolver.primary(.probe(probe), in: ctx).destination,
                        NavDestination(.appareil, focus: .device(printer.ip)), "sonde → appareil surveillé")
        try expectEqual(NavResolver.primary(.alert(probeID: probeID), in: ctx).destination,
                        NavDestination(.surveillance, focus: .probe(probeID)), "alerte → sa sonde")
        guard case .message = NavResolver.primary(.alert(probeID: "disparue"), in: ctx) else {
            throw TestFailure(message: "alerte d'une sonde supprimée : message", file: #fileID, line: #line)
        }
        let service = NavProbeRef(id: "s", name: "M365", kind: .onlineService, target: "microsoft365")
        try expectEqual(NavResolver.primary(.probe(service), in: ctx).destination,
                        NavDestination(.outils, focus: .service("microsoft365")), "sonde de service → le service")
        let http = NavProbeRef(id: "h", name: "Intranet", kind: .http, target: "https://10.182.122.113/sante")
        try expectEqual(http.host, "10.182.122.113", "hôte d'une URL")
        let ap = NavProbeRef(id: "a", name: "Borne", kind: .fortiAPOffline, target: "AP-ACCUEIL")
        try expectEqual(NavResolver.primary(.probe(ap), in: ctx).destination,
                        NavDestination(.wifi, focus: .accessPoint("siege|FP231F0001")), "sonde FortiAP → la borne")
        guard case .message(_, _, let suggestion) = NavResolver.primary(.probe(NavProbeRef(id: "x", name: "X", kind: .ping, target: "10.1.1.1")), in: ctx) else {
            throw TestFailure(message: "cible inconnue : message", file: #fileID, line: #line)
        }
        try expectEqual(suggestion?.destination, NavDestination(.surveillance, focus: .probe("x")), "repli : la sonde")
        try expectEqual(NavResolver.primary(.analysisEvent(siteKey: laval, recordKey: lavalTwin.key, ip: lavalTwin.ip.description), in: ctx).destination,
                        NavDestination(.inventaire, focus: .record(site: laval, key: lavalTwin.key), sites: .include(laval)),
                        "événement → fiche d'inventaire de son site")
        try expectEqual(NavResolver.primary(.service(id: "github", name: "GitHub"), in: ctx).destination?.focus, .service("github"), "service")
        try expectEqual(NavResolver.primary(.toolResult(tool: "dns"), in: ctx).destination?.focus, .tool("dns"), "résultat d'outil")
        try expectEqual(NavResolver.primary(.backup(name: "a.zip"), in: ctx).destination?.module, .reglages, "sauvegarde")
        try expectEqual(NavResolver.primary(.remoteConnection(id: remoteID, host: desk.ip), in: ctx).destination?.focus,
                        .remote(remoteID), "connexion")
    }

    // MARK: Ouvrir dans ›

    suite.add("Navigation : « Ouvrir dans › » d'un appareil propose les modules pertinents, dans l'ordre") {
        let items = NavResolver.openIn(.device(desk), in: context())
        let modules = items.map(\.destination.module)
        try expectEqual(modules, [.scanner, .carte, .appareil, .ping, .switchs, .wifi, .analyse, .acces],
                        "modules du portable (pas de fiche d’inventaire ni de sonde)")
        try expectEqual(items.first { $0.destination.module == .switchs }?.destination.focus,
                        .switchPort(host: "10.182.122.3", port: "1/3"), "port du switch")
        try expectEqual(items.first { $0.destination.module == .wifi }?.destination.focus, .accessPoint("siege|FP231F0001"), "borne du client")
        try expectEqual(items.first { $0.destination.module == .appareil }?.shortcutDigit, "4", "⌥⌘4 : fiche")
        try expectEqual(NavModule.analyse.shortcutDigit, "0", "⌥⌘0 : Analyse")
        let printerModules = NavResolver.openIn(.device(printer), in: context()).map(\.destination.module)
        try expect(printerModules.contains(.surveillance), "l'imprimante a une sonde")
        try expect(!printerModules.contains(.acces), "pas de connexion enregistrée pour l'imprimante")
    }

    // MARK: Historique

    suite.add("Navigation : Retour et Avancer restaurent l'écran, la recherche, le filtre et la sélection") {
        var history = NavHistory(limit: 50)
        let scanner = NavLocation(.scanner, search: "type:imprimante", deviceID: printer.ip)
        let carte = NavLocation(.carte, sites: .active, focus: .node("grp:x"))
        let filter = NavFilter(origin: .carte, label: "Carte\u{00A0}: Téléphones ×2 · SW-ETG2-01",
                               members: [phone.member, desk.member], siteKey: siege)
        let inventaire = NavLocation(.inventaire, filter: filter, sites: .sites([siege]))
        history.leave(scanner, to: carte)
        history.leave(carte, to: inventaire)
        try expect(history.canGoBack && !history.canGoForward, "Retour seulement")
        try expectEqual(history.goBack(from: inventaire), carte, "Retour → la Carte")
        try expectEqual(history.goBack(from: carte), scanner, "Retour → le Scanner, recherche et sélection comprises")
        try expect(!history.canGoBack && history.canGoForward, "Avancer seulement")
        try expectEqual(history.goForward(from: scanner), carte, "Avancer → la Carte")
        try expectEqual(history.goForward(from: carte), inventaire, "Avancer → l'Inventaire filtré")
        try expectEqual(history.goForward(from: inventaire), nil, "rien après")
    }

    suite.add("Navigation : aller ailleurs efface Avancer ; pile bornée ; pas de doublon") {
        var history = NavHistory(limit: 3)
        let places = NavModule.allCases.prefix(6).map { NavLocation($0) }
        for (from, to) in zip(places, places.dropFirst()) { history.leave(from, to: to) }
        try expectEqual(history.back.map(\.module), [.inventaire, .appareil, .ping], "les trois plus récents seulement")
        _ = history.goBack(from: places[5])
        try expect(history.canGoForward, "Avancer possible")
        history.leave(places[4], to: NavLocation(.reglages))
        try expect(!history.canGoForward, "une nouvelle destination efface Avancer")
        let count = history.back.count
        history.leave(places[4], to: NavLocation(.reglages))
        try expectEqual(history.back.count, count, "même endroit deux fois de suite : une seule entrée")
        history.leave(NavLocation(.outils), to: NavLocation(.outils))
        try expectEqual(history.back.count, count, "rester au même endroit n'empile rien")
    }

    // MARK: Filtres transmis

    suite.add("Navigation : groupe de la Carte → Inventaire filtré sur exactement ces appareils, dans le site dessiné") {
        let group = NavGroupRef(title: "Téléphones ×2", parentTitle: "SW-ETG2-01", members: [phone, desk], siteKey: siege)
        guard let destination = NavResolver.primary(.group(group), in: context()).destination,
              let filter = destination.filter else {
            throw TestFailure(message: "le groupe mène à un filtre", file: #fileID, line: #line)
        }
        try expectEqual(destination.module, .inventaire, "Inventaire")
        try expectEqual(destination.sites, .include(siege), "site dessiné affiché")
        try expectEqual(destination.search, "", "recherche de l'Inventaire remise à zéro")
        try expectEqual(filter.label, "Carte\u{00A0}: Téléphones ×2 · SW-ETG2-01", "étiquette")
        try expectEqual(filter.prefix, "Carte", "préfixe de l'étiquette")
        try expectEqual(filter.value, "Téléphones ×2 · SW-ETG2-01", "valeur de l'étiquette")
        let records = [
            record(phone.ip, phone.mac, host: "tel"), record(desk.ip, desk.mac, host: "pc"),
            record(printer.ip, printer.mac, host: "imp"), reception,
            // Ancienne IP du téléphone reprise par un autre appareil : exclu (autre MAC).
            record("10.182.122.150", "AA:AA:AA:AA:AA:AA", host: "autre"),
        ]
        let kept = records.filter { filter.matches($0, site: siege) }.map(\.hostname)
        try expectEqual(kept, ["tel", "pc"], "exactement les deux membres")
        // Le téléphone change d'IP : il reste dans le filtre (même MAC).
        var moved = record(phone.ip, phone.mac, host: "tel")
        moved.ip = IPv4Address("10.182.122.199")!
        try expect(filter.matches(moved, site: siege), "un membre qui a changé d'IP reste dans le filtre")
        try expect(!filter.matches(records[0], site: laval), "jamais une ligne d'un autre site")
        // Membre sans MAC : par son IP.
        let noMAC = NavFilter(origin: .carte, label: "x", members: [NavMember(ip: "10.0.0.40")])
        try expect(noMAC.matches(ip: "10.0.0.40", mac: MACAddress("AA:BB:CC:DD:EE:FF")), "membre sans MAC : par IP")
        try expect(!noMAC.matches(ip: "10.0.0.4", mac: nil), "IP exacte (10.0.0.4 ≠ 10.0.0.40)")
        // Scanner : seulement depuis le site actif.
        let fromLaval = NavGroupRef(title: "Postes ×1", members: [NavDeviceRef(lavalTwin, siteKey: laval)], siteKey: laval)
        let modules = NavResolver.openIn(.group(fromLaval), in: context()).map(\.destination.module)
        try expect(modules.contains(.inventaire) && !modules.contains(.scanner), "autre site : Inventaire, pas le Scanner")
        let local = NavResolver.openIn(.group(group), in: context())
        try expect(local.contains { $0.destination.module == .scanner }, "site actif : Scanner aussi")
        try expectEqual(local.first { $0.destination.module == .switchs }?.destination.focus,
                        .switchPort(host: "10.182.122.3", port: nil), "le switch au-dessus du groupe")
    }

    // MARK: Ports (note 33)

    suite.add("Navigation : port → l'appareil branché ; plusieurs → liste et Inventaire filtré") {
        let ctx = context()
        try expectEqual(NavPortResolver.resolve(NavPortRef(host: "10.182.122.3", ifIndex: 14), in: ctx).destination,
                        NavDestination(.appareil, focus: .device(printer.ip)), "port 1/14 → l'imprimante")
        try expectEqual(NavPortResolver.resolve(NavPortRef(host: "10.182.122.3", ifIndex: 25), in: ctx).destination,
                        NavDestination(.inventaire, focus: .record(site: siege, key: reception.key)),
                        "appareil absent du scan → sa fiche d'inventaire")
        guard case .choose(let title, _, let options, let all) = NavPortResolver.resolve(NavPortRef(host: "10.182.122.3", ifIndex: 3), in: ctx) else {
            throw TestFailure(message: "deux appareils : liste à choisir", file: #fileID, line: #line)
        }
        try expectEqual(title, "Plusieurs appareils sur SW-ETG2-01 · 1/3", "titre")
        try expectEqual(Set(options.compactMap { $0.destination?.focus }), [.device(desk.ip), .device(phone.ip)], "les deux fiches")
        try expectEqual(all?.destination?.filter?.label, "Port\u{00A0}: SW-ETG2-01 · 1/3", "étiquette du filtre de port")
        try expectEqual(all?.destination?.filter?.members.count, 2, "deux membres")
        try expectEqual(all?.destination?.module, .inventaire, "Inventaire filtré")
    }

    suite.add("Navigation : port vide, actif sans MAC, uplink et appareil pas encore vu → message clair") {
        var ctx = context()
        func message(_ index: Int) throws -> (String, String, NavOption?) {
            guard case .message(let title, let text, let suggestion) = NavPortResolver.resolve(NavPortRef(host: "10.182.122.3", ifIndex: index), in: ctx) else {
                throw TestFailure(message: "port \(index) : message attendu", file: #fileID, line: #line)
            }
            return (title, text, suggestion)
        }
        try expectEqual(try message(7).0, "Port vide", "port inactif sans MAC")
        try expectEqual(try message(9).0, "Aucun appareil appris", "port actif sans MAC")
        let uplink = try message(24)
        try expectEqual(uplink.0, "Uplink / trunk", "dix MAC et un voisin pont")
        try expect(uplink.1.contains("SW-CORE-01"), "le voisin est nommé")
        try expectEqual(uplink.2?.destination, NavDestination(.switchs, focus: .switchPort(host: "10.182.122.2", port: nil)),
                        "suite proposée : le switch voisin")
        let unknown = try message(20)
        try expectEqual(unknown.0, "Appareil pas encore vu", "MAC inconnue")
        try expect(unknown.1.contains("DE:AD:BE:EF:00:20"), "la MAC est citée")
        try expectEqual(NavPortResolver.filter(NavPortRef(host: "10.182.122.3", ifIndex: 24), in: ctx), nil, "pas de filtre sur un uplink")
        // FortiSwitch : lien FortiLink, même sans capacités LLDP ni beaucoup de MAC.
        let forti = SNMPSwitchSnapshot(host: IPv4Address("10.255.1.2")!, system: SNMPSystemInfo(name: "FSW-QUAI", descr: ""),
                                       interfaces: [SNMPInterface(index: 1, name: "port1", operStatus: .up)],
                                       fdb: [SNMPFDBEntry(mac: MACAddress("04:D5:90:3A:7B:11")!, vlan: 1, bridgePort: 1, ifIndex: 1)],
                                       neighbors: [SNMPLLDPNeighbor(localPortNum: 1, ifIndex: 1, sysName: "FortiGate-60F", portID: "FortiLink",
                                                                    capabilities: .station)],
                                       polledAt: now, controllerName: "Siège")
        ctx = NavContext(activeSiteKey: siege, scanner: [printer], switches: [forti])
        guard case .message(let title, _, _) = NavPortResolver.resolve(NavPortRef(host: "10.255.1.2", ifIndex: 1), in: ctx) else {
            throw TestFailure(message: "FortiLink : message", file: #fileID, line: #line)
        }
        try expectEqual(title, "Uplink / trunk", "FortiLink = uplink")
        guard case .message(let absent, _, _) = NavPortResolver.resolve(NavPortRef(host: "10.9.9.9", ifIndex: 1), in: ctx) else {
            throw TestFailure(message: "switch absent : message", file: #fileID, line: #line)
        }
        try expectEqual(absent, "Relevé du switch absent", "switch non relevé")
    }

    suite.add("Navigation : téléphone et poste sur un port, dont un pas encore vu → liste avec l'inconnu non cliquable") {
        var snap = snapshot()
        snap.fdb.append(SNMPFDBEntry(mac: MACAddress("DE:AD:BE:EF:00:14")!, vlan: 30, bridgePort: 14, ifIndex: 14))
        let ctx = NavContext(activeSiteKey: siege, scanner: [printer], switches: [snap])
        guard case .choose(_, _, let options, let all) = NavPortResolver.resolve(NavPortRef(host: "10.182.122.3", ifIndex: 14), in: ctx) else {
            throw TestFailure(message: "un connu et un inconnu : liste", file: #fileID, line: #line)
        }
        try expectEqual(options.count, 2, "deux lignes")
        try expectEqual(options.filter { $0.destination == nil }.map(\.detail), ["DE:AD:BE:EF:00:14"], "l'inconnu sans destination")
        try expectEqual(all?.destination?.filter?.members, [printer.member], "filtre : les appareils connus")
    }
}
