import Darwin
import Foundation
@testable import NetScopeCore

// IPv6 (0.31.0) : adresses, RFC 5952, préfixes, EUI-64, table NDP sur octets fixes, ping ICMPv6
// (paquets construits et lus, rien n'est envoyé), traceroute6 sur une sortie recopiée.

func registerIPv6Tests(_ suite: TestSuite) {
    suite.add("IPv6 : analyse et forme canonique RFC 5952") {
        let cases: [(String, String)] = [
            ("2001:0db8:0000:0000:0000:0000:0000:0001", "2001:db8::1"),
            ("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"),
            ("2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1"),
            ("2001:DB8::AbCd", "2001:db8::abcd"),
            ("::", "::"),
            ("::1", "::1"),
            ("fe80::", "fe80::"),
            ("1:0:0:2:0:0:0:3", "1:0:0:2::3"),
            ("::ffff:192.0.2.1", "::ffff:192.0.2.1"),
            ("64:ff9b::192.0.2.33", "64:ff9b::c000:221"),
        ]
        for (input, expected) in cases {
            try expectEqual(IPv6Address(input)?.description, expected, "forme courte de \(input)")
        }
        for bad in ["", "1:2:3:4:5:6:7:8:9", "2001:db8:::1", "1::2::3", "12345::", "g::1", "1:2:3:4:5:6:7::8",
                    "1:2:3:4:5:6:7", "::1.2.3", "1.2.3.4::", "fe80::1%en0", ":1::"] {
            try expect(IPv6Address(bad) == nil, "refusée : \(bad)")
        }
        try expectEqual(IPv6Address("2001:db8::1")?.expanded, "2001:0db8:0000:0000:0000:0000:0000:0001", "forme complète")
        let a = IPv6Address("2001:db8::1")!
        try expectEqual(IPv6Address(bytes: a.bytes), a, "aller-retour en octets")
        try expectEqual(IPv6Address(groups: a.groups), a, "aller-retour en groupes")
        try expect(IPv6Address("2001:db8::1")! < IPv6Address("2001:db8::2")!, "ordre")
        let zoned = IPv6Address.parseZoned("fe80::1%en0")
        try expectEqual(zoned?.address.description, "fe80::1", "adresse avec zone")
        try expectEqual(zoned?.zone, "en0", "zone")
        try expectEqual(IPv6Address.parseZoned("[2001:db8::1]")?.address.description, "2001:db8::1", "crochets")
        try expect(IPv6Address.parseZoned("fe80::1%") == nil, "zone vide refusée")
        let data = try JSONEncoder().encode([a])
        try expectEqual(String(decoding: data, as: UTF8.self), "[\"2001:db8::1\"]", "JSON en texte canonique")
        try expectEqual(try JSONDecoder().decode([IPv6Address].self, from: data), [a], "JSON relu")
    }

    suite.add("IPv6 : portées et ordre d'affichage") {
        let scopes: [(String, IPv6Scope)] = [
            ("fe80::1", .linkLocal), ("febf::1", .linkLocal), ("fec0::1", .reserved),
            ("fd4e:7a21:9c30:10::1", .uniqueLocal), ("fc00::1", .uniqueLocal),
            ("2607:f8b0::1", .global), ("3fff::1", .global), ("2001:db8::5", .documentation),
            ("ff02::1", .multicast), ("::1", .loopback), ("::", .unspecified), ("::ffff:10.0.0.1", .ipv4Mapped),
        ]
        for (text, scope) in scopes { try expectEqual(IPv6Address(text)?.scope, scope, "portée de \(text)") }
        let list = ["2607:f8b0::1", "fd00::1", "fe80::1"].compactMap(IPv6Address.init).sorted(by: IPv6Address.displayOrder)
        try expectEqual(list.map(\.description), ["fe80::1", "fd00::1", "2607:f8b0::1"], "lien local, ULA, globale")
    }

    suite.add("IPv6 : EUI-64 dans les deux sens") {
        let mac = MACAddress("00:11:32:9A:4E:07")!
        try expectEqual(IPv6Address.eui64(mac: mac).description, "fe80::211:32ff:fe9a:4e07", "lien local EUI-64")
        try expectEqual(IPv6Address.eui64(mac: mac, prefix: IPv6Address("2001:db8:a00:10::")!).description,
                        "2001:db8:a00:10:211:32ff:fe9a:4e07", "adresse globale EUI-64")
        try expectEqual(IPv6Address("fe80::211:32ff:fe9a:4e07")?.embeddedMAC, mac, "MAC retrouvée")
        try expectEqual(IPv6Address("fe80::6d5:90ff:fe3a:7b11")?.embeddedMAC, MACAddress("04:d5:90:3a:7b:11"), "bit U/L remis")
        try expect(IPv6Address("fe80::a4c1:7f2e:5b30:9d11")?.embeddedMAC == nil, "identifiant opaque : pas de MAC")
        try expectEqual(IPv6Address.interfaceIdentifier(mac: MACAddress("02:00:00:00:00:01")!), 0x0000_00FF_FE00_0001, "bit inversé à zéro")
    }

    suite.add("IPv6 : préfixes, plage, nombre d'adresses et découpage") {
        let prefix = try IPv6Prefix(parsing: "2001:db8:a00:10::5/48")
        try expectEqual(prefix.description, "2001:db8:a00::/48", "réseau")
        try expectEqual(prefix.network.description, "2001:db8:a00::", "première adresse")
        try expectEqual(prefix.last.description, "2001:db8:a00:ffff:ffff:ffff:ffff:ffff", "dernière adresse")
        try expect(prefix.contains(IPv6Address("2001:db8:a00:ff::1")!), "contient")
        try expect(!prefix.contains(IPv6Address("2001:db8:a01::1")!), "ne contient pas")
        try expectEqual(prefix.addressCountText, "2⁸⁰", "nombre en puissance")
        try expectEqual(IPv6Prefix(address: .unspecified, length: 120).addressCountText, "256", "nombre exact")
        try expectEqual(IPv6Prefix(address: .unspecified, length: 112).addressCountText, "65\u{202F}536", "chiffres groupés")
        try expectEqual(prefix.subnetCountText(newLength: 64), "65\u{202F}536", "sous-réseaux /64 d'un /48")
        try expectEqual(prefix.subnets(newLength: 64, limit: 3).map(\.description),
                        ["2001:db8:a00::/64", "2001:db8:a00:1::/64", "2001:db8:a00:2::/64"], "premiers /64")
        try expectEqual(IPv6Prefix(address: IPv6Address("2001:db8:a00:10::")!, length: 60).subnets(newLength: 64, limit: 99).count,
                        16, "un /60 donne seize /64")
        try expectEqual(IPv6Prefix(address: .unspecified, length: 0).subnets(newLength: 1).map(\.description),
                        ["::/1", "8000::/1"], "moitiés de ::/0")
        let low = IPv6Prefix(address: IPv6Address("2001:db8::")!, length: 63).subnets(newLength: 65, limit: 4)
        try expectEqual(low.map(\.description), ["2001:db8::/65", "2001:db8:0:0:8000::/65", "2001:db8:0:1::/65",
                                                  "2001:db8:0:1:8000::/65"], "découpage à cheval sur les deux moitiés")
        try expectEqual(IPv6Prefix(address: IPv6Address("2001:db8::1")!, length: 128).subnets(newLength: 128).count, 1, "/128")
        try expectThrows(IPv6Prefix.ParseError.missingLength, "longueur manquante") { _ = try IPv6Prefix(parsing: "2001:db8::") }
        try expectThrows(IPv6Prefix.ParseError.invalidLength, "longueur trop grande") { _ = try IPv6Prefix(parsing: "2001:db8::/129") }
        try expectThrows(IPv6Prefix.ParseError.invalidAddress, "adresse illisible") { _ = try IPv6Prefix(parsing: "2001:zz::/64") }
    }

    suite.add("IPv6 : table NDP lue sur un tampon sysctl construit à la main") {
        var buffer: [UInt8] = []
        let gatewayMAC: [UInt8] = [0x04, 0xD5, 0x90, 0x3A, 0x7B, 0x11]
        // Lien local avec l'index d'interface rangé dans les octets 2 et 3 (fe80:4::…).
        buffer += ScanTestBuffers.message(flags: RTF_LLINFO | RTF_ROUTER, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            IPv6TestBuffers.inet6("fe80:4::6d5:90ff:fe3a:7b11"), ScanTestBuffers.link(name: "en0", mac: gatewayMAC),
        ])
        buffer += ScanTestBuffers.message(flags: RTF_LLINFO, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            IPv6TestBuffers.inet6("2001:db8:a00:10::1"), ScanTestBuffers.link(name: "en0", mac: gatewayMAC),
        ])
        // Incomplète (aucune adresse matérielle) : ignorée.
        buffer += ScanTestBuffers.message(flags: RTF_LLINFO, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            IPv6TestBuffers.inet6("2001:db8:a00:10::99"), ScanTestBuffers.link(name: "en0", mac: []),
        ])
        // Multidiffusion : ignorée.
        buffer += ScanTestBuffers.message(flags: RTF_LLINFO, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            IPv6TestBuffers.inet6("ff02::1"), ScanTestBuffers.link(name: "en0", mac: [0x33, 0x33, 0, 0, 0, 1]),
        ])
        buffer += ScanTestBuffers.message(flags: RTF_LLINFO, addrs: RTA_DST | RTA_GATEWAY, sockaddrs: [
            IPv6TestBuffers.inet6("fd4e:7a21:9c30:10::117"), ScanTestBuffers.link(name: "en0", mac: [0xB0, 0x7B, 0x25, 0x44, 0xA1, 0x6C]),
        ])
        let neighbors = NDPTable.parse(buffer)
        try expectEqual(neighbors.count, 3, "trois voisins complets")
        let gateway = neighbors.filter { $0.mac == MACAddress(bytes: gatewayMAC) }
        try expectEqual(gateway.map(\.address.description), ["fe80::6d5:90ff:fe3a:7b11", "2001:db8:a00:10::1"],
                        "index d'interface retiré du lien local, ordre lien local puis globale")
        try expect(gateway.first?.isRouter == true, "drapeau routeur")
        try expectEqual(gateway.first?.interfaceIndex, 4, "index d'interface")
        try expectEqual(NDPTable.parse(Array(buffer.prefix(buffer.count - 10))).count, 2, "dernier message (tronqué) ignoré")
        try expectEqual(NDPTable.parse([]).count, 0, "tampon vide")

        let output = """
        Neighbor                        Linklayer Address  Netif Expire    St Flgs Prbs
        fe80::6d5:90ff:fe3a:7b11%en0    4:d5:90:3a:7b:11   en0   23h59m58s S  R
        2001:db8:a00:10::117            b0:7b:25:44:a1:6c  en0   permanent R
        ff02::fb%en0                    33:33:0:0:0:fb     en0   permanent R
        fe80::99%en0                    (incomplete)       en0   expired   N
        """
        let parsed = NDPTable.parseCommandOutput(output)
        try expectEqual(parsed.map(\.address.description), ["fe80::6d5:90ff:fe3a:7b11", "2001:db8:a00:10::117"], "repli « ndp -an »")
        try expect(parsed.first?.isRouter == true, "routeur lu dans les drapeaux")
    }

    suite.add("IPv6 : rattachement aux appareils par la MAC et état de ce Mac") {
        let mac = MACAddress("b0:7b:25:44:a1:6c")!
        var devices = [Device(ip: IPv4Address(10, 0, 0, 117), mac: mac), Device(ip: IPv4Address(10, 0, 0, 5))]
        let neighbors = [
            IPv6Neighbor(address: IPv6Address("2001:db8::117")!, mac: mac),
            IPv6Neighbor(address: IPv6Address("fe80::1")!, mac: mac),
            IPv6Neighbor(address: IPv6Address("fe80::9")!, mac: MACAddress("5c:e9:1e:44:0a:7f")!),
        ]
        try expectEqual(IPv6Attachment.attach(neighbors, to: &devices), 1, "un appareil complété")
        try expectEqual(devices[0].ipv6?.map(\.description), ["fe80::1", "2001:db8::117"], "adresses triées")
        try expect(devices[1].ipv6 == nil, "sans MAC : rien")
        try expectEqual(IPv6Attachment.attach(neighbors, to: &devices), 0, "deuxième passage : rien de neuf")
        try expectEqual(IPv6Attachment.unmatched(neighbors, devices: devices).map(\.address.description), ["fe80::9"],
                        "appareil IPv6 seulement")
        // Fichier antérieur à la 0.31.0 : pas de champ ipv6.
        let old = try JSONEncoder().encode(Device(ip: IPv4Address(10, 0, 0, 1)))
        try expect(String(decoding: old, as: UTF8.self).contains("ipv6") == false, "champ absent si vide")
        let decodedOld = try JSONDecoder().decode(Device.self, from: old)
        try expect(decodedOld.ipv6 == nil, "lu sans changement")
        let saved = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(devices[0]))
        try expectEqual(saved.ipv6, devices[0].ipv6, "adresses enregistrées")

        let status = IPv6HostStatus(interface: "en0", addresses: [
            LocalIPv6Address(interface: "en0", address: IPv6Address("2001:db8:a00:10::5")!, prefixLength: 64),
            LocalIPv6Address(interface: "en0", address: IPv6Address("fe80::5")!, prefixLength: 64),
            LocalIPv6Address(interface: "en7", address: IPv6Address("fd00::7")!, prefixLength: 64),
        ])
        try expectEqual(status.addresses.count, 2, "seulement l'interface choisie")
        try expectEqual(status.level, .global, "globale")
        try expectEqual(status.mainAddress?.description, "2001:db8:a00:10::5", "adresse principale")
        try expectEqual(status.routedPrefix?.description, "2001:db8:a00:10::/64", "préfixe annoncé")
        try expectEqual(status.summary, "IPv6 globale · 2 adresses", "résumé")
        try expectEqual(IPv6HostStatus(interface: "en0", addresses: [
            LocalIPv6Address(interface: "en0", address: IPv6Address("fe80::5")!, prefixLength: 64)]).level, .linkOnly, "lien local seulement")
        try expectEqual(IPv6HostStatus(interface: "en0", addresses: []).summary, "IPv6 absente", "absente")
    }

    suite.add("IPv6 : paquets ICMPv6 (construits et lus, rien n'est envoyé)") {
        let packet = PingICMPv6.echoRequestPacket(identifier: 0x1234, sequence: 7, payloadSize: 16)
        try expectEqual(packet.count, 24, "en-tête et données")
        try expectEqual(Array(packet[0..<8]), [128, 0, 0, 0, 0x12, 0x34, 0, 7], "type 128, somme laissée au noyau")
        var reply = packet
        reply[0] = 129
        try expectEqual(PingICMPv6.parse(reply), .echoReply(identifier: 0x1234, sequence: 7), "Echo Reply")
        let exceeded = [UInt8]([3, 0, 0, 0, 0, 0, 0, 0]) + [UInt8](repeating: 0, count: 40) + packet
        try expectEqual(PingICMPv6.parse(exceeded), .timeExceeded(identifier: 0x1234, sequence: 7), "Time Exceeded")
        let unreachable = [UInt8]([1, 3, 0, 0, 0, 0, 0, 0]) + [UInt8](repeating: 0, count: 40) + packet
        try expectEqual(PingICMPv6.parse(unreachable), .unreachable(code: 3, identifier: 0x1234, sequence: 7), "inaccessible")
        try expect(PingICMPv6.parse([135, 0, 0, 0, 0, 0, 0, 0]) == nil, "sollicitation de voisin ignorée")
        try expect(PingICMPv6.parse([129, 0]) == nil, "trop court")
        try expectEqual(PingICMPv6.unreachableLabel(0), "aucune route", "libellé")
    }

    suite.add("IPv6 : cibles du ping continu") {
        let spec = PingTargetSpec.parse("2001:DB8:0::1")
        try expectEqual(spec?.kind, .icmpv6, "adresse IPv6 → ICMPv6")
        try expectEqual(spec?.canonical, "2001:db8::1", "forme canonique")
        try expectEqual(PingTargetSpec.parse("fe80::1%en0")?.host, "fe80::1%en0", "zone gardée")
        try expectEqual(PingTargetSpec.parse("[2001:db8::1]", mode: .tcp)?.kind, .icmpv6, "crochets, quel que soit le mode")
        try expectEqual(PingTargetSpec.parse("10.0.0.5:443")?.kind, .tcp(port: 443), "IPv4:port inchangé")
        try expectEqual(PingTargetSpec.parse("10.0.0.5")?.kind, .icmp, "IPv4 inchangé")
        try expect(PingTargetSpec.parse("2001:db8::zz") == nil, "illisible")
        try expectEqual(PingProbeKind.icmpv6.label, "ICMPv6", "libellé")
        try expectEqual(PingTargetSpec.endpoint(kind: .icmpv6, address: "2001:db8::1"), "2001:db8::1", "libellé de la cible")
    }

    suite.add("IPv6 : sortie de traceroute6 recopiée") {
        let text = """
        traceroute6 to 2001:4860:4860::8888 (2001:4860:4860::8888) from 2001:db8:a00:10::5, 30 hops max, 20 byte packets
         1  fe80::6d5:90ff:fe3a:7b11%en0  0.812 ms  0.640 ms  0.701 ms
         2  2001:db8:ff00:1::1  6.204 ms *  6.410 ms
         3  * * *
         4  2001:4860:4860::8888  12.912 ms  12.744 ms  13.020 ms
        """
        let hops = IPv6Trace.parse(text)
        try expectEqual(hops.map(\.ttl), [1, 2, 3, 4], "quatre sauts, en-tête ignoré")
        try expectEqual(hops[0].address?.description, "fe80::6d5:90ff:fe3a:7b11", "zone retirée")
        try expectEqual(hops[1].rttsMs, [6.204, 6.410], "temps")
        try expectEqual(hops[1].lost, 1, "une sonde perdue")
        try expect(hops[2].address == nil && hops[2].lost == 3, "saut muet")
        try expectEqual(hops[3].bestMs, 12.744, "meilleur temps")
        try expectEqual(IPv6Trace.arguments(destination: IPv6Address("fe80::1")!, zone: "en0", maxHops: 99).suffix(3),
                        ["-m", "64", "fe80::1%en0"], "arguments bornés, zone ajoutée")
    }
}

enum IPv6TestBuffers {
    /// sockaddr_in6 (28 octets) d'une adresse écrite en entier (index KAME permis : « fe80:4:: »).
    static func inet6(_ text: String) -> [UInt8] {
        let bytes = IPv6Address(text)!.bytes
        return [28, UInt8(AF_INET6), 0, 0, 0, 0, 0, 0] + bytes + [0, 0, 0, 0]
    }
}
