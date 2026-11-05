import Foundation
import NetScopeCore

// Note 83 : Switchs et ports en onglets. Règles vérifiées sur des relevés fixes, sans réseau :
// onglets (captures, arrivée depuis un autre écran, libellés), tableau des ports et ses filtres,
// appareils par VLAN, voisins LLDP, tuiles de résumé et onglet retenu par l'historique Retour.

private func mac(_ text: String) -> MACAddress { MACAddress(text)! }

/// Switch d'accès : 1 et 2 actifs (PoE sur 1), 3 inactif, 4 désactivé, 5 uplink vers SW-CORE-01
/// (LLDP), 6 téléphone (LLDP « Bridge, Telephone »), plus une interface virtuelle Vlan1.
private func accessSwitch(polledAt: Date = Date(timeIntervalSince1970: 1_780_000_000)) -> SNMPSwitchSnapshot {
    let interfaces = [
        SNMPInterface(index: 1, name: "1/1", alias: "Imprimante RH", operStatus: .up, speedMbps: 1000, inErrors: 3),
        SNMPInterface(index: 2, name: "1/2", operStatus: .up, speedMbps: 100, inErrors: 900),
        SNMPInterface(index: 3, name: "1/3", operStatus: .down),
        SNMPInterface(index: 4, name: "1/4", adminUp: false, operStatus: .down),
        SNMPInterface(index: 5, name: "1/5", alias: "Vers le cœur", operStatus: .up, speedMbps: 10_000),
        SNMPInterface(index: 6, name: "1/6", alias: "Accueil", operStatus: .up, speedMbps: 1000),
        SNMPInterface(index: 100, name: "Vlan1", type: 136, operStatus: .up),
    ]
    let fdb = [
        SNMPFDBEntry(mac: mac("00:11:22:33:44:01"), vlan: 30, bridgePort: 1, ifIndex: 1),
        SNMPFDBEntry(mac: mac("00:11:22:33:44:02"), vlan: 20, bridgePort: 2, ifIndex: 2),
        SNMPFDBEntry(mac: mac("00:11:22:33:44:03"), vlan: 20, bridgePort: 2, ifIndex: 2),
        SNMPFDBEntry(mac: mac("00:11:22:33:44:05"), vlan: 30, bridgePort: 5, ifIndex: 5),
        SNMPFDBEntry(mac: mac("00:11:22:33:44:06"), vlan: 10, bridgePort: 5, ifIndex: 5),
        SNMPFDBEntry(mac: mac("00:11:22:33:44:07"), vlan: 40, bridgePort: 6, ifIndex: 6),
    ]
    let neighbors = [
        SNMPLLDPNeighbor(localPortNum: 5, ifIndex: 5, sysName: "SW-CORE-01.siege.local", portID: "Gi1/0/48",
                         portDescr: "Gi1/0/48", sysDescr: "Cisco IOS XE", capabilities: [.bridge, .router]),
        SNMPLLDPNeighbor(localPortNum: 6, ifIndex: 6, sysName: "SEP0011223344", portID: "Port 1",
                         capabilities: [.bridge, .telephone]),
    ]
    let poe = [SNMPPoEPort(group: 1, port: 1, ifIndex: 1, adminEnabled: true, detection: .deliveringPower, consumptionMW: 6_500),
               SNMPPoEPort(group: 1, port: 3, ifIndex: 3, adminEnabled: true, detection: .searching)]
    return SNMPSwitchSnapshot(host: IPv4Address("10.182.122.3")!, system: SNMPSystemInfo(name: "SW-ETG2-01", descr: "Aruba"),
                              interfaces: interfaces, fdb: fdb, neighbors: neighbors, pvid: [1: 30, 2: 20, 3: 20, 5: 1, 6: 40],
                              poeBudgetW: 370, poeUsedW: 96, poeDetails: poe, polledAt: polledAt)
}

/// Cœur : voit SW-ETG2-01 sur Gi1/0/48 et la FortiGate (routeur) sur Gi1/0/1.
private func coreSwitch() -> SNMPSwitchSnapshot {
    let interfaces = [
        SNMPInterface(index: 1, name: "Gi1/0/1", operStatus: .up, speedMbps: 1000),
        SNMPInterface(index: 48, name: "Gi1/0/48", operStatus: .up, speedMbps: 10_000),
    ]
    let neighbors = [
        SNMPLLDPNeighbor(localPortNum: 1, ifIndex: 1, sysName: "FGT-SIEGE", portID: "port1", capabilities: [.router]),
        SNMPLLDPNeighbor(localPortNum: 48, ifIndex: 48, sysName: "sw-etg2-01", portID: "1/5", capabilities: [.bridge]),
    ]
    return SNMPSwitchSnapshot(host: IPv4Address("10.182.122.2")!, system: SNMPSystemInfo(name: "SW-CORE-01", descr: "Cisco"),
                              interfaces: interfaces, neighbors: neighbors, poeBudgetW: 740, poeUsedW: 412)
}

/// Erreurs récentes : 1/2 gagne 40 erreurs en 10 min (alerte), 1/1 en gagne 2 (sous le seuil).
private let recentErrors = SwitchRecentErrors(hasBaseline: true, seconds: 600, ports: [
    1: PortErrorDelta(ifIndex: 1, newErrors: 2, seconds: 600),
    2: PortErrorDelta(ifIndex: 2, newErrors: 40, seconds: 600),
])

func registerSwitchPageTests(_ suite: TestSuite) {
    suite.add("Switchs en onglets : noms des captures, arrivée et libellés") {
        try expectEqual(SwitchPageTab(capture: "ports"), .ports, "ports")
        try expectEqual(SwitchPageTab(capture: " Trafic "), .trafic, "espaces et majuscule")
        try expectEqual(SwitchPageTab(capture: "façade"), .switchs, "accent plié")
        try expectEqual(SwitchPageTab(capture: "vlan"), .appareils, "VLAN → Appareils")
        try expectEqual(SwitchPageTab(capture: "lldp"), .voisins, "LLDP → Voisins et liens")
        try expectEqual(SwitchPageTab(capture: "inconnu"), nil, "nom inconnu")
        try expectEqual(SwitchPageTab.arrival(port: "1/14"), .ports, "un port demandé : onglet Ports")
        try expectEqual(SwitchPageTab.arrival(port: nil), .switchs, "un switch seul : onglet Switchs")
        try expectEqual(SwitchPageTab.arrival(port: "  "), .switchs, "port vide : onglet Switchs")
        try expectEqual(SwitchPageTab.ports.title(badge: 2), "Ports (2 en erreur)", "compteur d'erreurs")
        try expectEqual(SwitchPageTab.voisins.title(badge: 19), "Voisins et liens (19)", "compteur des voisins")
        try expectEqual(SwitchPageTab.switchs.title(badge: 0), "Switchs", "aucun compteur à zéro")
        try expect(SwitchPageTab.ports.isPerSwitch && SwitchPageTab.trafic.isPerSwitch && SwitchPageTab.appareils.isPerSwitch,
                   "Ports, Trafic et Appareils montrent un switch")
        try expect(!SwitchPageTab.switchs.isPerSwitch && !SwitchPageTab.voisins.isPerSwitch, "Switchs et Voisins : tous les switchs")
        for tab in SwitchPageTab.allCases {
            try expectEqual(SwitchPageTab(capture: tab.rawValue), tab, "nom brut \(tab.rawValue)")
        }
    }

    suite.add("Switchs en onglets : lignes du tableau des ports") {
        let rows = SwitchPortRows.make(accessSwitch(), recent: recentErrors)
        try expectEqual(rows.map(\.name), ["1/1", "1/2", "1/3", "1/4", "1/5", "1/6"], "ports physiques seulement, ordre des ifIndex")
        try expectEqual(rows.map(\.status), [.active, .errors, .inactive, .disabled, .uplink, .active], "états")
        let first = rows[0]
        try expect(first.poeDelivering, "PoE délivré sur 1/1")
        try expectEqual(first.poeWatts, 6.5, "watts du PoE")
        try expectEqual(first.vlanText, "Accès 30", "VLAN d'accès")
        try expectEqual(first.newErrors, 2, "erreurs récentes sous le seuil")
        try expect(!first.hasRecentErrors, "2 nouvelles erreurs : pas d'alerte")
        try expectEqual(rows[1].macCount, 2, "deux MAC sur 1/2")
        try expect(rows[1].hasRecentErrors, "40 nouvelles erreurs : alerte")
        try expectEqual(rows[1].totalErrors, 900, "total depuis le démarrage gardé à part")
        try expectEqual(rows[2].newErrors, 0, "port sans delta mais base présente : 0")
        try expectEqual(rows[4].vlanText, "Trunk · natif 1 · 10,30", "trunk : VLAN natif et VLAN vus")
        try expectEqual(rows[4].neighborName, "SW-CORE-01.siege.local", "voisin LLDP de l'uplink")
        try expect(!rows[5].isUplink, "téléphone (Bridge, Telephone) : pas un uplink")
        let noBaseline = SwitchPortRows.make(accessSwitch())
        try expectEqual(noBaseline[1].newErrors, nil, "premier relevé : erreurs récentes inconnues")
        try expectEqual(noBaseline[1].status, .active, "sans base, aucun port en erreur")
    }

    suite.add("Switchs en onglets : filtres et recherche des ports") {
        let rows = SwitchPortRows.make(accessSwitch(), recent: recentErrors)
        let counts = SwitchPortRows.counts(rows)
        try expectEqual(counts[.all], 6, "tous")
        try expectEqual(counts[.active], 4, "actifs (uplink et port en erreur compris)")
        try expectEqual(counts[.inactive], 2, "inactifs (désactivé compris)")
        try expectEqual(counts[.poe], 1, "PoE")
        try expectEqual(counts[.uplinks], 1, "uplinks")
        try expectEqual(counts[.errors], 1, "erreurs")
        try expectEqual(SwitchPortRows.filter(rows, by: .errors).map(\.name), ["1/2"], "filtre Erreurs")
        try expectEqual(SwitchPortRows.filter(rows, by: .all, text: "imprimante").map(\.name), ["1/1"], "description")
        try expectEqual(SwitchPortRows.filter(rows, by: .all, text: "accès 20").map(\.name), ["1/2", "1/3"], "VLAN, mots combinés")
        try expectEqual(SwitchPortRows.filter(rows, by: .active, text: "accès 20").map(\.name), ["1/2"], "filtre et texte ensemble")
        try expectEqual(SwitchPortRows.filter(rows, by: .all, text: "CŒUR").map(\.name), ["1/5"], "majuscules pliées")
        try expectEqual(SwitchPortRows.filter(rows, by: .active, text: "ACCES 40").map(\.name), ["1/6"], "accents pliés")
        try expectEqual(SwitchPortRows.filter(rows, by: .all, text: "sw-core").map(\.name), ["1/5"], "nom du voisin")
        try expectEqual(SwitchPortRows.filter(rows, by: .poe, keep: 4).map(\.name), ["1/1", "1/4"],
                        "le port choisi depuis un autre onglet reste visible")
        try expectEqual(SwitchPortFilter(capture: "Erreurs"), .errors, "capture : erreurs")
        try expectEqual(SwitchPortFilter(capture: "trunk"), .uplinks, "capture : trunk")
        try expectEqual(SwitchPortRows.errorPorts(rows).map(\.name), ["1/2"], "ports en erreur")
    }

    suite.add("Switchs en onglets : appareils par VLAN") {
        let vlans = SwitchVLANSummary.make(accessSwitch())
        try expectEqual(vlans.map(\.vlan), [20, 30, 40, 10], "du plus peuplé au moins peuplé, puis par numéro")
        let v20 = vlans[0]
        try expectEqual(v20.devices, 2, "deux appareils en VLAN 20")
        try expectEqual(v20.accessPorts, ["1/2"], "1/3 inactif : pas compté sans appareil")
        let v30 = vlans[1]
        try expectEqual(v30.accessPorts, ["1/1"], "port d'accès du VLAN 30")
        try expectEqual(v30.trunkPorts, ["1/5"], "le trunk porte aussi le VLAN 30")
        try expectEqual(vlans.first { $0.vlan == 10 }?.devices, 0, "VLAN 10 seulement sur le trunk")
        try expect(!vlans.contains { $0.vlan == 1 }, "VLAN natif de l'uplink sans appareil : absent")
    }

    suite.add("Switchs en onglets : voisins LLDP et liens entre switchs") {
        let rows = SwitchNeighborRows.make([accessSwitch(), coreSwitch()])
        try expectEqual(rows.count, 4, "deux voisins par switch")
        try expectEqual(rows.map(\.localPort), ["1/5", "1/6", "Gi1/0/1", "Gi1/0/48"], "par switch puis par port")
        try expectEqual(rows[0].kind, .interSwitch, "SW-CORE-01 (avec domaine) est un switch relevé")
        try expectEqual(rows[0].neighborHost, "10.182.122.2", "adresse du switch voisin")
        try expect(rows[0].isUplink, "port 1/5 : uplink")
        try expectEqual(rows[0].neighborPortDescr, nil, "description identique au port : pas répétée")
        try expectEqual(rows[1].kind, .phone, "téléphone IP")
        try expect(!rows[1].isUplink, "téléphone : pas un uplink")
        try expectEqual(rows[2].kind, .router, "FortiGate : routeur ou pare-feu")
        try expectEqual(rows[3].kind, .interSwitch, "nom en minuscules reconnu")
        try expectEqual(rows[3].speedMbps, 10_000, "vitesse du lien")
        try expectEqual(SwitchNeighborRows.interSwitchLinks(rows), 1, "le lien vu des deux côtés compte une fois")
        let forti = SNMPLLDPNeighbor(localPortNum: 52, sysName: "FGT-SIEGE", portID: "FortiLink")
        try expectEqual(SwitchNeighborRows.kind(forti, knownSwitch: false), .fortiLink, "lien FortiLink")
        let ap = SNMPLLDPNeighbor(localPortNum: 3, sysName: "FAP-231F", portID: "eth0", capabilities: [.bridge, .accessPoint])
        try expectEqual(SwitchNeighborRows.kind(ap, knownSwitch: false), .accessPoint, "borne Wi-Fi")
        let bare = SNMPLLDPNeighbor(localPortNum: 3, sysName: "inconnu", portID: "eth0")
        try expectEqual(SwitchNeighborRows.kind(bare, knownSwitch: false), .other, "capacités inconnues")
    }

    suite.add("Switchs en onglets : tuiles de résumé") {
        let summary = SwitchPageSummary.make([accessSwitch(), coreSwitch()], hosts: 3,
                                             recent: ["10.182.122.3": recentErrors])
        try expectEqual(summary.switches, 3, "trois switchs dans le site")
        try expectEqual(summary.answered, 2, "deux relevés")
        try expectEqual(summary.ports, 8, "ports physiques")
        try expectEqual(summary.activePorts, 6, "ports actifs")
        try expectEqual(summary.errorPorts, ["SW-ETG2-01 · 1/2"], "port en erreur nommé avec son switch")
        try expectEqual(summary.poeUsedW, 508, "PoE utilisé additionné")
        try expectEqual(summary.poeBudgetW, 1_110, "budgets additionnés")
        try expectEqual(summary.poePorts, 1, "ports alimentés")
        try expectEqual(summary.devices, 4, "MAC des ports d'accès (uplink exclu)")
        try expectEqual(summary.vlans, 3, "VLAN 20, 30, 40")
        try expectEqual(summary.neighbors, 4, "voisins LLDP")
        try expectEqual(summary.interSwitchLinks, 1, "un lien entre switchs")
        let empty = SwitchPageSummary.make([], hosts: 0)
        try expectEqual(empty.poeFraction, nil, "aucun budget : pas de fraction")
        try expectEqual(empty.switches, 0, "aucun switch")
    }

    suite.add("Switchs en onglets : l'historique Retour garde l'onglet") {
        var history = NavHistory()
        let ports = NavLocation(.switchs, focus: .switchPort(host: "10.182.122.3", port: "1/2"), tab: SwitchPageTab.ports.rawValue)
        let trafic = NavLocation(.switchs, focus: .switchPort(host: "10.182.122.3", port: "1/2"), tab: SwitchPageTab.trafic.rawValue)
        try expect(ports != trafic, "même port, autre onglet : autre endroit")
        history.leave(trafic, to: ports)
        try expectEqual(history.goBack(from: ports)?.tab, "trafic", "Retour rend l'onglet Trafic")
        try expectEqual(history.goForward(from: trafic)?.tab, "ports", "Avancer rend l'onglet Ports")
        try expectEqual(NavLocation(.scanner).tab, nil, "écran sans onglet retenu")
    }
}
