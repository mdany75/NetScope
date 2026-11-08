import Foundation
import NetScopeCore

// Note 109 : relecture d'un seul appareil sur la FortiGate, par un faux transport. Aucun réseau.

func registerDeviceSightingTests(_ suite: TestSuite) {
    let mac = MACAddress("B0:7B:25:44:A1:6C")!
    let arp = #"{"status":"success","results":[{"ip":"10.182.122.117","mac":"b0:7b:25:44:a1:6c","interface":"internal"},{"ip":"10.182.122.100","mac":"3c:22:fb:10:20:30","interface":"internal"}]}"#
    let detected = #"{"status":"success","results":[{"mac":"b0:7b:25:44:a1:6c","switch_id":"S124XYZ","port_name":"port12","vlan_id":10},{"mac":"3c:22:fb:10:20:30","switch_id":"S124XYZ","port_name":"port3","vlan_id":20}]}"#
    let switches = #"{"status":"success","results":[{"serial":"S124XYZ","switch-id":"S124XYZ","name":"SW-ETG2","connecting_from":"10.255.1.2","state":"Authorized","status":"Connected","ports":[]}]}"#

    func reader(_ responses: [String: (Int, String)]) -> (FortiGateReader, FortiFakeTransport) {
        let transport = FortiFakeTransport(responses)
        return (FortiGateReader(transport: transport, tokenForRedaction: FortiFixtures.token), transport)
    }

    suite.add("Où était cet appareil : cible d’une recherche") {
        try expectEqual(FortiDeviceTarget.of(query: "Julie", found: [mac])?.macs, [mac], "MAC trouvée par le nom")
        try expectEqual(FortiDeviceTarget.of(query: "10.182.122.117", found: [])?.ip, IPv4Address("10.182.122.117"), "IP encore inconnue")
        let previous = FortiDeviceTarget.of(query: "10.182.122.117", found: [mac])
        try expect(previous?.macs.isEmpty == true, "une IP tapée ne relit pas ceux qui l’ont déjà eue")
        try expectEqual(FortiDeviceTarget.of(query: "b0:7b:25:44:a1:6c", found: [])?.macs, [mac], "MAC encore inconnue")
        try expect(FortiDeviceTarget.of(query: "Julie", found: []) == nil, "nom inconnu : rien à relire")
        let many = (0..<6).map { MACAddress("00:00:00:00:00:0\($0)")! }
        try expect(FortiDeviceTarget.of(query: "poste", found: many) == nil, "trop d’appareils")
    }

    suite.add("Où était cet appareil : dernière relecture regroupée") {
        let second = MACAddress("3C:22:FB:10:20:30")!
        let views = MACCurrentView.group([
            MACObservation(mac: mac, kind: .vlan, value: "10", source: .fortigate),
            MACObservation(mac: second, kind: .ip, value: "10.0.0.9", source: .fortigate),
            MACObservation(mac: mac, kind: .ip, value: "10.0.0.5", source: .fortigate),
            MACObservation(mac: mac, kind: .ip, value: "10.0.0.6", source: .wifi),
            MACObservation(mac: mac, kind: .name, value: "BDC2", source: .fortigate),
        ])
        try expectEqual(views.map(\.mac), [mac, second], "MAC dans l’ordre de lecture")
        try expectEqual(views[0].items.map(\.kind), [.ip, .name, .vlan], "IP, nom, puis VLAN, une seule valeur chacun")
        try expectEqual(views[0].items[0].value, "10.0.0.5", "première IP lue gardée")
        try expectEqual(views[0].name, "BDC2", "nom de l’appareil")
        try expect(MACCurrentView.group([]).isEmpty, "rien de lu")
    }

    suite.add("Où était cet appareil : seul l’appareil cherché est gardé") {
        let (r, transport) = reader([FortiPaths.arp: (200, arp), FortiPaths.detectedDevice: (200, detected), FortiPaths.switchStatus: (200, switches)])
        let list = try await r.readDeviceSighting(FortiDeviceTarget(ip: IPv4Address("10.182.122.117")))
        try expect(list.allSatisfy { $0.mac == mac }, "aucune autre MAC")
        try expect(list.contains { $0.kind == .ip && $0.value == "10.182.122.117" }, "IP")
        try expect(list.contains { $0.kind == .vlan && $0.value == "10" }, "VLAN")
        try expectEqual(list.first { $0.kind == .switchPort }?.value, "SW-ETG2 · port12", "port écrit comme les relevés complets")
        try expect(transport.requested.count <= 5, "lecture légère")
        try expect(!transport.requested.contains(FortiPaths.portStats) && !transport.requested.contains(FortiPaths.poe), "pas de compteurs ni de PoE")
    }

    suite.add("Où était cet appareil : seulement la dernière valeur") {
        let second = "04:c1:03:ba:93:17"
        let arpOld = #"{"status":"success","results":[{"ip":"10.182.122.130","mac":"b0:7b:25:44:a1:6c"},{"ip":"10.182.122.116","mac":"\#(second)"}]}"#
        let wifi = #"{"status":"success","results":[{"mac":"b0:7b:25:44:a1:6c","ip":"10.182.122.116","wtp_name":"FP231-A","ssid":"Bureau","vlan_id":10}]}"#
        // Fiche d'inventaire d'il y a deux heures, avec son ancienne IP.
        let oldUser = #"{"status":"success","results":[{"mac":"b0:7b:25:44:a1:6c","ipv4_address":"10.182.122.200","hostname":"Ancien nom","last_seen":7200}]}"#
        let responses: [String: (Int, String)] = [FortiPaths.arp: (200, arpOld), FortiWifiPaths.client: (200, wifi), FortiPaths.userDevices: (200, oldUser)]

        let (byIP, _) = reader(responses)
        let list = try await byIP.readDeviceSighting(FortiDeviceTarget(ip: IPv4Address("10.182.122.116")))
        try expect(list.allSatisfy { $0.mac == mac }, "le client Wi-Fi associé a cette IP, pas l’ancienne entrée ARP")
        try expectEqual(list.filter { $0.kind == .ip }.map(\.value), ["10.182.122.116"], "une seule IP : celle du client Wi-Fi")
        try expect(!list.contains { $0.value == "Ancien nom" }, "fiche d’inventaire périmée ignorée")

        let (byMAC, _) = reader([FortiPaths.arp: (200, arpOld)])
        let onlyARP = try await byMAC.readDeviceSighting(FortiDeviceTarget(macs: [mac]))
        try expectEqual(onlyARP.filter { $0.kind == .ip }.map(\.value), ["10.182.122.130"], "sans autre liste : ARP")
    }

    suite.add("Où était cet appareil : appareil absent, listes refusées") {
        let (empty, _) = reader([FortiPaths.arp: (200, arp)])
        let none = try await empty.readDeviceSighting(FortiDeviceTarget(ip: IPv4Address("10.182.122.250")))
        try expect(none.isEmpty, "appareil non vu : aucune observation")
        let denied = [FortiPaths.arp: (403, "{}"), FortiPaths.detectedDevice: (403, "{}"), FortiPaths.userDevices: (403, "{}"), FortiWifiPaths.client: (403, "{}")]
        let (refused, _) = reader(denied)
        do {
            _ = try await refused.readDeviceSighting(FortiDeviceTarget(macs: [mac]))
            try expect(false, "erreur attendue")
        } catch let error as FortiGateError {
            guard case .forbidden = error else { throw TestFailure(message: "403 attendu : \(error)", file: #fileID, line: #line) }
        }
    }
}
