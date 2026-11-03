import Foundation
import NetScopeCore

func registerModelTests(_ suite: TestSuite) {
    suite.add("Device : nom affiché, fabricant, recherche, JSON") {
        var device = Device(ip: IPv4Address("10.182.122.111")!, mac: MACAddress("94:DD:F8:18:15:7D"),
                            hostname: "Brother DCP-L2640DW", openPorts: [80, 443, 9100, 631],
                            switchName: "SW-ETG2-01", switchPort: "1/14", vlan: 30, deviceType: .imprimante)
        try expectEqual(device.id, "10.182.122.111", "identifiant = IP")
        try expectEqual(device.displayName, "Brother DCP-L2640DW", "nom d'hôte")
        device.customName = "Imprimante accueil"
        try expectEqual(device.displayName, "Imprimante accueil", "nom personnalisé prioritaire")
        try expectEqual(device.vendorLabel, "Brother", "fabricant par la table OUI")
        try expectEqual(device.switchLocation, "SW-ETG2-01 · 1/14", "emplacement")
        try expect(device.matches("brother"), "recherche : fabricant")
        try expect(device.matches("94dd.f818"), "recherche : MAC au format Cisco")
        try expect(device.matches("9100"), "recherche : port")
        try expect(device.matches("imprimante acc"), "recherche : nom personnalisé")
        try expect(device.matches("1/14"), "recherche : port de switch")
        try expect(!device.matches("hikvision"), "recherche : absent")
        let json = try JSONEncoder().encode(device)
        try expectEqual(try JSONDecoder().decode(Device.self, from: json), device, "aller-retour JSON")
        let anonymous = Device(ip: IPv4Address("10.0.0.9")!, mac: MACAddress("3a:1f:c7:02:9b:e4"))
        try expectEqual(anonymous.displayName, "10.0.0.9", "sans nom : l'IP")
        try expectEqual(anonymous.vendorLabel, "Adresse privée (aléatoire)", "MAC aléatoire")
    }

    suite.add("ScanRangeConfig et ScanProfile") {
        try expectEqual(ScanRangeConfig(text: "10.182.122.0/24", label: "Bureau").kindLabel, "CIDR", "CIDR")
        try expectEqual(ScanRangeConfig(text: "10.10.0.1-50", label: "Serveurs").kindLabel, "Début-fin", "début-fin")
        try expectEqual(ScanRangeConfig(text: "10.0.0.1, 10.0.0.2", label: "x").kindLabel, "Liste", "liste")
        try expectEqual(ScanRangeConfig(text: "n'importe quoi", label: "x").kindLabel, "Invalide", "invalide")
        try expectEqual(try ScanRangeConfig(text: "10.10.0.1-50", label: "Serveurs").parsed().count, 50, "plage lue")
        // Profil Rapide (défaut) : sonde maintenant les ports essentiels, sans clic droit.
        let rapide = ScanProfile.rapide.ports()
        try expectEqual(rapide, ScanProfile.essentialPorts.sorted(), "rapide : ports essentiels, triés")
        for port: UInt16 in [22, 23, 80, 443, 445, 3389, 5900, 8080, 8443, 9100, 631, 554, 515, 139, 135, 53, 21, 1883, 5000, 5001] {
            try expect(rapide.contains(port), "rapide : port \(port)")
        }
        try expectEqual(rapide.count, 20, "rapide : 20 ports")
        try expectEqual(ScanProfile(rawValue: "rapide"), .rapide, "ancien réglage enregistré « rapide » relu")
        try expect(!ScanProfile.commonPorts.contains(161), "161 n'est pas un port TCP à sonder (SNMP = UDP)")
        try expect(ScanProfile.complet.alwaysDiscoversSwitches && !ScanProfile.rapide.alwaysDiscoversSwitches, "SNMP forcé en Complet")
        try expect(Set(rapide).isSubset(of: Set(ScanProfile.complet.ports())), "complet contient les essentiels")
        try expect(ScanProfile.portsCourants.ports().contains(9100), "ports courants : 9100")
        let extended = ScanProfile.complet.ports()
        try expect(extended.count >= 1000 && extended.count <= 1200, "complet : environ 1000 ports (\(extended.count))")
        try expectEqual(extended, extended.sorted(), "ports triés")
        try expectEqual(ScanProfile.personnalise.ports(custom: [443, 22, 443]), [22, 443], "personnalisé : triés, uniques")
        try expectEqual(ScanProfile.parsePorts("22, 80 8000-8002"), [22, 80, 8000, 8001, 8002], "lecture de ports")
        try expectEqual(ScanProfile.parsePorts("22, 0"), nil, "port 0 refusé")
        try expectEqual(ScanProfile.parsePorts("90-80"), nil, "intervalle inversé refusé")
    }
}
