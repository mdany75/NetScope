import Foundation
import NetScopeCore

func registerHardwareTests(_ suite: TestSuite) {
    suite.add("MACAddress : formats acceptés et normalisation") {
        let expected = "94:dd:f8:18:15:7d"
        for text in ["94:DD:F8:18:15:7D", "94-dd-f8-18-15-7d", "94dd.f818.157d", "94DDF818157D", " 94:dd:f8:18:15:7d "] {
            try expectEqual(MACAddress(text)?.description, expected, "« \(text) »")
        }
        try expectEqual(MACAddress("0:1a:2b:3:4:5")?.description, "00:1a:2b:03:04:05", "octets sans zéro (arp -a)")
        for bad in ["", "94:dd:f8:18:15", "94:dd:f8:18:15:7d:00", "94:dd:f8:18:15:7g", "94dd.f818.157", "94::f8:18:15:7d", "123:dd:f8:18:15:7d"] {
            try expect(MACAddress(bad) == nil, "« \(bad) » refusée")
        }
        let mac = MACAddress("94:dd:f8:18:15:7d")!
        try expectEqual(mac.formatted(.upperColon), "94:DD:F8:18:15:7D", "majuscules")
        try expectEqual(mac.formatted(.hyphen), "94-dd-f8-18-15-7d", "tirets")
        try expectEqual(mac.formatted(.cisco), "94dd.f818.157d", "Cisco")
        try expectEqual(mac.formatted(.bare), "94ddf818157d", "brut")
        try expectEqual(mac.oui, "94:dd:f8", "OUI")
        try expectEqual(mac.ouiValue, 0x94DDF8, "OUI sur 24 bits")
        try expectEqual(MACAddress(bytes: mac.bytes), mac, "aller-retour par octets")
        let json = try JSONEncoder().encode(mac)
        try expectEqual(try JSONDecoder().decode(MACAddress.self, from: json), mac, "aller-retour JSON")
    }

    suite.add("MACAddress : adresses aléatoires, multidiffusion, broadcast") {
        try expect(MACAddress("3a:1f:c7:02:9b:e4")!.isRandomized, "3a : administrée localement")
        try expect(MACAddress("d6:4e:81:7a:33:c0")!.isRandomized, "d6 : administrée localement")
        try expect(!MACAddress("3c:22:fb:7e:05:b1")!.isRandomized, "Apple : adresse universelle")
        try expect(MACAddress("01:00:5e:00:00:fb")!.isMulticast, "multidiffusion")
        try expect(!MACAddress("01:00:5e:00:00:fb")!.isRandomized, "une multidiffusion n'est pas une adresse aléatoire")
        try expect(MACAddress("ff:ff:ff:ff:ff:ff")!.isBroadcast, "broadcast")
    }

    suite.add("OUIDatabase : fabricants courants et libellés") {
        let db = OUIDatabase.builtIn
        try expect(db.count >= 150, "au moins 150 préfixes (\(db.count))")
        let cases: [(String, String)] = [
            ("3c:22:fb:7e:05:b1", "Apple"), ("94:dd:f8:18:15:7d", "Brother"), ("04:d5:90:3a:7b:11", "Fortinet"),
            ("b0:7b:25:44:a1:6c", "Dell"), ("8c:16:45:2b:9e:03", "Lenovo"), ("bc:ad:28:6f:01:5a", "Hikvision"),
            ("90:ac:3f:0d:18:76", "BrightSign"), ("b8:27:eb:00:00:01", "Raspberry Pi"), ("00:50:56:aa:bb:cc", "VMware"),
            ("00:11:32:01:02:03", "Synology"), ("88:3a:30:5d:e1:40", "HPE Aruba"), ("24:0a:c4:00:11:22", "Espressif"),
        ]
        for (text, vendor) in cases {
            try expectEqual(db.vendor(for: MACAddress(text)!), vendor, text)
        }
        try expectEqual(db.label(for: MACAddress("3a:1f:c7:02:9b:e4")!), "Adresse privée (aléatoire)", "MAC aléatoire")
        try expectEqual(db.label(for: MACAddress("00:00:01:00:00:01")!), "Inconnu", "préfixe absent")
        try expectEqual(db.label(for: MACAddress("52:54:00:12:34:56")!), "QEMU / KVM", "préfixe local connu : la table d'abord")
        let custom = OUIDatabase(entries: ["AA-BB-CC": "Essai", "zz": "ignoré"])
        try expectEqual(custom.count, 1, "préfixe illisible ignoré")
        try expectEqual(custom.vendor(for: MACAddress("aa:bb:cc:00:00:00")!), "Essai", "table fournie")
    }
}
