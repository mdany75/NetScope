import Foundation
import NetScopeCore

func registerAddressingTests(_ suite: TestSuite) {
    suite.add("IPv4Address : lecture, écriture, comparaison") {
        let a = IPv4Address("10.182.122.135")
        try expect(a != nil, "adresse valide lue")
        try expectEqual(a!.description, "10.182.122.135", "écriture")
        try expectEqual(a!.value, 0x0AB6_7A87, "valeur sur 32 bits")
        try expectEqual(IPv4Address(192, 168, 1, 1).description, "192.168.1.1", "constructeur par octets")
        for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.-4", "a.b.c.d", "01.2.3.4", "1..2.3", " 1.2.3.4x"] {
            try expect(IPv4Address(bad) == nil, "« \(bad) » refusée")
        }
        try expect(IPv4Address("10.0.0.2")! < IPv4Address("10.0.0.10")!, "ordre numérique, pas alphabétique")
        try expectEqual(IPv4Address("255.255.255.255")!.next, nil, "pas de suivante après 255.255.255.255")
        try expectEqual(IPv4Address.mask(prefix: 24).description, "255.255.255.0", "masque /24")
        try expectEqual(IPv4Address.mask(prefix: 0).description, "0.0.0.0", "masque /0")
        try expectEqual(IPv4Address("255.255.255.192")!.prefixLength, 26, "longueur d'un masque")
        try expectEqual(IPv4Address("255.0.255.0")!.prefixLength, nil, "masque non contigu")
        let json = try JSONEncoder().encode([a!])
        try expectEqual(String(data: json, encoding: .utf8)!, "[\"10.182.122.135\"]", "JSON en texte")
        try expectEqual(try JSONDecoder().decode([IPv4Address].self, from: json), [a!], "aller-retour JSON")
    }

    suite.add("IPRange : CIDR sans réseau ni broadcast") {
        let range = try IPRange(parsing: "10.182.122.0/24")
        let hosts = range.addresses()
        try expectEqual(hosts.count, 254, "254 hôtes dans un /24")
        try expectEqual(hosts.first?.description, "10.182.122.1", "premier hôte")
        try expectEqual(hosts.last?.description, "10.182.122.254", "dernier hôte")
        try expectEqual(try IPRange(parsing: "10.0.0.0/31").count, 2, "/31 : deux adresses (RFC 3021)")
        try expectEqual(try IPRange(parsing: "10.0.0.7/32").addresses().map(\.description), ["10.0.0.7"], "/32")
        try expectEqual(try IPRange(parsing: "10.0.0.77/30").addresses().map(\.description),
                        ["10.0.0.77", "10.0.0.78"], "adresse ramenée au réseau, puis hôtes du /30")
        try expectEqual(try IPRange(parsing: "172.16.0.0/16").count, 65_534, "/16 accepté (sous la limite)")
    }

    suite.add("IPRange : début-fin, forme courte, adresse seule, listes") {
        let short = try IPRange(parsing: "192.168.1.1-254")
        try expectEqual(short.count, 254, "forme courte")
        try expectEqual(short.addresses().last?.description, "192.168.1.254", "fin de la forme courte")
        let full = try IPRange(parsing: "10.10.0.1-10.10.0.50")
        try expectEqual(full.count, 50, "forme complète")
        let crossing = try IPRange(parsing: "10.0.0.250-10.0.1.5")
        try expectEqual(crossing.count, 12, "plage à cheval sur deux /24")
        try expectEqual(try IPRange(parsing: "10.0.0.5").addresses().map(\.description), ["10.0.0.5"], "adresse seule")
        let list = try IPRange(parsing: "10.0.0.5, 10.0.0.6 10.0.0.10-12;10.0.0.5\n10.0.0.0/30")
        try expectEqual(list.addresses().map(\.description),
                        ["10.0.0.5", "10.0.0.6", "10.0.0.10", "10.0.0.11", "10.0.0.12", "10.0.0.1", "10.0.0.2"],
                        "liste mêlée, doublons retirés, ordre conservé")
        try expect(list.contains(IPv4Address("10.0.0.11")!), "contains")
        try expect(!list.contains(IPv4Address("10.0.0.9")!), "contains (absent)")
    }

    suite.add("IPRange : erreurs en français et limite de sécurité") {
        try expectThrows(IPRangeError.empty, "texte vide") { _ = try IPRange(parsing: "  , ") }
        try expectThrows(IPRangeError.invalidAddress("10.0.0.300"), "octet trop grand") { _ = try IPRange(parsing: "10.0.0.300") }
        try expectThrows(IPRangeError.invalidPrefix("10.0.0.0/33"), "préfixe trop grand") { _ = try IPRange(parsing: "10.0.0.0/33") }
        try expectThrows(IPRangeError.reversedSpan("10.0.0.50-10"), "fin avant début") { _ = try IPRange(parsing: "10.0.0.50-10") }
        try expectThrows(IPRangeError.invalidSpan("10.0.0.1-abc"), "fin illisible") { _ = try IPRange(parsing: "10.0.0.1-abc") }
        try expectThrows(IPRangeError.tooLarge(count: 131_068), "deux /16") {
            _ = try IPRange(parsing: "10.0.0.0/16, 10.1.0.0/16")
        }
        try expectThrows(IPRangeError.tooLarge(count: 16_777_214), "un /8") { _ = try IPRange(parsing: "10.0.0.0/8") }
        let message = IPRangeError.invalidAddress("x").errorDescription ?? ""
        try expect(message.contains("« x »") && message.contains("n’est pas"), "message lisible en français : \(message)")
    }

    suite.add("Subnet : calculs d'un /24 et d'un /26") {
        let s = try Subnet(parsing: "10.182.122.135/24")
        try expectEqual(s.network.description, "10.182.122.0", "réseau")
        try expectEqual(s.mask.description, "255.255.255.0", "masque")
        try expectEqual(s.wildcard.description, "0.0.0.255", "masque inverse")
        try expectEqual(s.broadcast.description, "10.182.122.255", "broadcast")
        try expectEqual(s.firstHost.description, "10.182.122.1", "premier hôte")
        try expectEqual(s.lastHost.description, "10.182.122.254", "dernier hôte")
        try expectEqual(s.hostCount, 254, "hôtes")
        try expectEqual(s.totalAddresses, 256, "adresses")
        try expectEqual(s.addressClass, "A", "classe")
        try expect(s.isPrivate, "privé")
        try expectEqual(s.binaryMask, "11111111.11111111.11111111.00000000", "masque en binaire")

        let t = try Subnet(parsing: "192.168.50.77 255.255.255.192")
        try expectEqual(t.description, "192.168.50.64/26", "masque en notation pointée")
        try expectEqual(t.broadcast.description, "192.168.50.127", "broadcast /26")
        try expectEqual(t.hostCount, 62, "hôtes /26")
        try expectEqual(t.addressClass, "C", "classe C")
        try expectEqual(try Subnet(parsing: "10.0.0.0/255.255.0.0").prefix, 16, "masque après la barre")
    }

    suite.add("Subnet : /31, /32, /0, portées et erreurs") {
        let p31 = try Subnet(parsing: "10.0.0.0/31")
        try expectEqual(p31.hostCount, 2, "/31")
        try expectEqual(p31.firstHost.description, "10.0.0.0", "premier hôte /31")
        try expectEqual(p31.lastHost.description, "10.0.0.1", "dernier hôte /31")
        let p32 = try Subnet(parsing: "10.0.0.9/32")
        try expectEqual(p32.hostCount, 1, "/32")
        try expectEqual(p32.firstHost, p32.lastHost, "/32 : une seule adresse")
        try expectEqual(try Subnet(parsing: "0.0.0.0/0").totalAddresses, 4_294_967_296, "/0")
        try expectEqual(AddressScope.of(IPv4Address("8.8.8.8")!), .publique, "public")
        try expectEqual(AddressScope.of(IPv4Address("172.31.255.1")!), .privee, "172.16/12")
        try expectEqual(AddressScope.of(IPv4Address("172.32.0.1")!), .publique, "hors 172.16/12")
        try expectEqual(AddressScope.of(IPv4Address("169.254.10.1")!), .liaisonLocale, "APIPA")
        try expectEqual(AddressScope.of(IPv4Address("100.72.0.1")!), .cgnat, "CGNAT")
        try expectEqual(AddressScope.of(IPv4Address("127.0.0.1")!), .bouclage, "bouclage")
        try expectEqual(try Subnet(parsing: "224.0.0.0/4").addressClass, "D", "classe D")
        try expectThrows(SubnetError.invalidNotation("10.0.0.0"), "sans préfixe") { _ = try Subnet(parsing: "10.0.0.0") }
        try expectThrows(SubnetError.invalidPrefix("40"), "préfixe 40") { _ = try Subnet(parsing: "10.0.0.0/40") }
        try expectThrows(SubnetError.nonContiguousMask("255.0.255.0"), "masque troué") {
            _ = try Subnet(parsing: "10.0.0.0 255.0.255.0")
        }
    }

    suite.add("Subnet : découpage en sous-réseaux") {
        let s = try Subnet(parsing: "10.182.122.0/24")
        let parts = try s.split(into: 26)
        try expectEqual(parts.map(\.description),
                        ["10.182.122.0/26", "10.182.122.64/26", "10.182.122.128/26", "10.182.122.192/26"], "/24 en /26")
        try expectEqual(try s.split(into: 24), [s], "même préfixe : le réseau lui-même")
        try expectEqual(try Subnet(parsing: "10.0.0.0/8").split(into: 24).count, 65_536, "/8 en /24 : à la limite")
        try expectThrows(SubnetError.splitPrefixTooShort(current: 24, requested: 23), "préfixe plus court") {
            _ = try s.split(into: 23)
        }
        try expectThrows(SubnetError.tooManySubnets(131_072), "trop de sous-réseaux") {
            _ = try Subnet(parsing: "10.0.0.0/8").split(into: 25)
        }
        try expect(s.contains(IPv4Address("10.182.122.200")!), "contains")
        try expect(!s.contains(IPv4Address("10.182.123.1")!), "contains (hors réseau)")
    }

    suite.add("Interfaces locales : lecture sans trafic réseau") {
        // getifaddrs ne fait que lire l'état local ; le résultat dépend de la machine.
        for interface in LocalInterfaces.list() {
            try expect(interface.name.hasPrefix("en") || interface.name.hasPrefix("bridge"), "nom d'interface : \(interface.name)")
            try expect(interface.subnet.contains(interface.address), "l'adresse appartient à son réseau")
        }
    }
}
