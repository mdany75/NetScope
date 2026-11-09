import Foundation
import NetScopeCore

// Note 119 : table de routage. Échantillons au format exact de « netstat -rn » sur macOS,
// adresses et MAC FICTIF.

private let sample = """
Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.0.2.254        UGScg                 en0
default            192.0.2.254        UGScIg                en1
default            link#20            UCSIg               utun3
10.8/16            10.8.0.1           UGSc                utun3
10.8.0.1           10.8.0.2           UH                  utun3
100.64/10          link#20            UCS                 utun3
127                127.0.0.1          UCS                   lo0
127.0.0.1          127.0.0.1          UH                    lo0
169.254            link#8             UCS                   en0      !
169.254.89.223     2:b2:b9:7b:17:d    UHLSW                 en0      !
192.0.2            link#8             UCS                   en0      !
192.0.2.25         2:5e:be:4c:79:67   UHLWIi                en0    682
192.0.2.255        ff:ff:ff:ff:ff:ff  UHLWbI                en0      !
198.51.100.128/25  192.0.2.1          UGSc                  en0
203.0.113.0&0xffff00ff 192.0.2.1      UGSc                  en0
224.0.0/4          link#8             UmCS                  en0      !
224.0.0.251        1:0:5e:0:0:fb      UHmLWI                en0
255.255.255.255/32 link#8             UCS                   en0      !

Internet6:
Destination                             Gateway                                 Flags               Netif Expire
default                                 fe80::d692:5eff:fe7c:5bf3%en0           UGcg                  en0
default                                 fe80::%utun0                            UGcIg               utun0
::1                                     ::1                                     UHL                   lo0
2001:DB8:bd7d:a700::/64                 link#8                                  UC                    en0
2001:db8:bd7d:a700:c97:cdc0:585f:6030   2:bc:66:49:8:34                         UHLWI                 en0    120
fe80::%lo0/64                           fe80::1%lo0                             UcI                   lo0
fe80::aede:48ff:fe00:1122%en5           ac:de:48:0:11:22                        UHLI                  lo0
ff00::/8                                link#8                                  UmCI                  en0
ff02::%en0/32                           link#8                                  UmCI                  en0
"""

private func route(_ entries: [RouteEntry], _ text: String, family: RouteFamily = .ipv4, interface: String? = nil) throws -> RouteEntry {
    guard let entry = entries.first(where: { $0.destinationText == text && $0.family == family && (interface == nil || $0.interface == interface) }) else {
        throw TestFailure(message: "route \(text) introuvable", file: #fileID, line: #line)
    }
    return entry
}

func registerRouteTableTests(_ suite: TestSuite) {
    let entries = RouteTable.parse(netstat: sample)

    suite.add("Routes : chaque ligne des deux sections est lue, en-têtes exclus") {
        try expectEqual(entries.filter { $0.family == .ipv4 }.count, 18, "IPv4")
        try expectEqual(entries.filter { $0.family == .ipv6 }.count, 9, "IPv6")
    }

    suite.add("Routes : default normalisé, route principale distinguée des routes d’interface") {
        let defaults = entries.filter(\.isDefault)
        try expectEqual(defaults.map(\.destinationText), ["0.0.0.0/0", "0.0.0.0/0", "0.0.0.0/0", "::/0", "::/0"], "destinations")
        try expectEqual(defaults.filter(\.isPrimaryDefault).map(\.interface), ["en0", "en0"], "une principale par famille")
        try expectEqual(defaults[0].gateway, .address("192.0.2.254"), "passerelle")
        try expectEqual(defaults[0].scope, .network, "portée")
    }

    suite.add("Routes : réseaux IPv4 raccourcis par netstat complétés") {
        try expectEqual(try route(entries, "127.0.0.0/8").interface, "lo0", "classe A")
        try expectEqual(try route(entries, "192.0.2.0/24").mask, .prefix(24), "classe C")
        try expectEqual(try route(entries, "169.254.0.0/16", interface: "en0").mask, .prefix(16), "classe B")
        try expectEqual(try route(entries, "10.8.0.0/16").gateway, .address("10.8.0.1"), "préfixe écrit")
        try expectEqual(try route(entries, "100.64.0.0/10").mask, .prefix(10), "préfixe hors classe")
        try expectEqual(try route(entries, "198.51.100.128/25").mask, .prefix(25), "adresse complète avec préfixe")
    }

    suite.add("Routes : masque non contigu gardé tel quel") {
        let entry = try route(entries, "203.0.113.0&0xffff00ff")
        try expectEqual(entry.mask, .noncontiguous("0xffff00ff"), "masque")
    }

    suite.add("Routes : un hôte aux derniers octets nuls reste un hôte") {
        let host = RouteTable.parse(netstat: "Internet:\nDestination Gateway Flags Netif Expire\n192.168.1 10.0.0.1 UGH en0\n")
        try expectEqual(host.first?.mask, .prefix(32), "drapeau H")
        try expectEqual(host.first?.destinationText, "192.168.1.0", "adresse complétée")
    }

    suite.add("Routes : passerelles link#N, IP, MAC complétée et zone IPv6") {
        try expectEqual(try route(entries, "192.0.2.0/24").gateway, .link(8), "link#8")
        try expectEqual(try route(entries, "169.254.89.223").gateway.text, "02:b2:b9:7b:17:0d", "MAC sans zéros en tête")
        try expectEqual(try route(entries, "192.0.2.255").gateway.text, "ff:ff:ff:ff:ff:ff", "diffusion")
        let ipv6Default = entries.first { $0.family == .ipv6 && $0.isDefault }
        try expectEqual(ipv6Default?.gateway, .address("fe80::d692:5eff:fe7c:5bf3%en0"), "zone gardée sur la passerelle")
        try expectEqual(entries.first { $0.interface == "utun0" }?.gateway.text, "fe80::%utun0", "utun")
    }

    suite.add("Routes : destinations IPv6 sans zone, en forme canonique") {
        try expectEqual(try route(entries, "2001:db8:bd7d:a700::/64", family: .ipv6).mask, .prefix(64), "minuscules")
        try expectEqual(try route(entries, "fe80::/64", family: .ipv6).interface, "lo0", "zone avant le préfixe")
        try expectEqual(try route(entries, "fe80::aede:48ff:fe00:1122", family: .ipv6).mask, .prefix(128), "hôte à zone")
        try expectEqual(try route(entries, "ff02::/32", family: .ipv6).scope, .multicast, "multicast à zone")
    }

    suite.add("Routes : portées hôte, réseau, multicast et lien local") {
        try expectEqual(try route(entries, "127.0.0.1").scope, .host, "boucle")
        try expectEqual(try route(entries, "255.255.255.255").scope, .host, "diffusion limitée")
        try expectEqual(try route(entries, "192.0.2.0/24").scope, .network, "réseau")
        try expectEqual(try route(entries, "224.0.0.0/4").scope, .multicast, "224.0.0/4")
        try expectEqual(try route(entries, "224.0.0.251").scope, .multicast, "groupe")
        try expectEqual(try route(entries, "169.254.0.0/16", interface: "en0").scope, .linkLocal, "169.254")
        try expectEqual(try route(entries, "169.254.89.223").scope, .linkLocal, "voisin 169.254")
        try expectEqual(try route(entries, "fe80::/64", family: .ipv6).scope, .linkLocal, "fe80")
        try expectEqual(try route(entries, "::1", family: .ipv6).scope, .host, "::1")
    }

    suite.add("Routes : drapeaux bruts conservés et traduits dans l’ordre") {
        let entry = try route(entries, "192.0.2.25")
        try expectEqual(entry.rawFlags, "UHLWIi", "bruts")
        try expectEqual(entry.flags, ["active", "hôte", "adresse de liaison", "clonée", "liée à l’interface", "référence l’interface"], "traduits")
        try expectEqual(entry.flagsText, "hôte · adresse de liaison · clonée · liée à l’interface · référence l’interface", "« active » omis")
        let unknown = RouteTable.parse(netstat: "Internet:\nDestination Gateway Flags Netif\n10.0.0.1 10.0.0.2 UZ en0\n")
        try expectEqual(unknown.first?.flags, ["active", "drapeau Z"], "lettre inconnue")
        let lone = RouteTable.parse(netstat: "Internet:\nDestination Gateway Flags Netif\n10.0.0.1 10.0.0.2 U en0\n")
        try expectEqual(lone.first?.flagsText, "active", "« active » gardé s’il est seul")
    }

    suite.add("Routes : expiration en secondes, écoulée ou absente") {
        try expectEqual(try route(entries, "192.0.2.25").expiry, .seconds(682), "secondes")
        try expectEqual(try route(entries, "192.0.2.255").expiry, .elapsed, "!")
        try expectEqual(try route(entries, "127.0.0.1").expiry, nil, "vide")
    }

    suite.add("Routes : anciennes colonnes Refs et Use, sections et lignes étrangères") {
        let old = """
        Routing tables

        Internet:
        Destination        Gateway            Flags        Refs      Use   Netif Expire
        default            192.0.2.1          UGSc           92        0     en0
        pas-une-adresse    192.0.2.1          UGSc            1        0     en0
        999.1.1.1          192.0.2.1          UGSc            1        0     en0

        AppleTalk:
        Destination        Gateway            Flags        Refs      Use   Netif Expire
        65280/16           link#4             UC              1        0     en0
        """
        let parsed = RouteTable.parse(netstat: old)
        try expectEqual(parsed.count, 1, "seule la route valide d’une section IP")
        try expectEqual(parsed.first?.interface, "en0", "Netif trouvé par l’en-tête")
        try expectEqual(RouteTable.parse(netstat: "").count, 0, "sortie vide")
    }

    suite.add("Routes : recherche par mots sur la destination, la passerelle, l’interface et les drapeaux") {
        let entry = try route(entries, "10.8.0.0/16")
        try expect(entry.matches(""), "vide")
        try expect(entry.matches("10.8 UTUN3"), "deux mots, sans casse")
        try expect(entry.matches("passerelle"), "drapeau traduit")
        try expect(!entry.matches("10.8 en0"), "tous les mots requis")
        let main = try route(entries, "0.0.0.0/0", interface: "en0")
        try expect(main.matches("défaut"), "route par défaut")
    }

    suite.add("Routes : tri numérique des destinations et des familles") {
        let keys = try ["10.8.0.0/16", "100.64.0.0/10", "192.0.2.0/24"].map { try route(entries, $0).sortKey }
        try expectEqual(keys, keys.sorted(), "ordre numérique, pas alphabétique")
        try expectEqual(keys, keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "même ordre dans les tableaux")
        let last = try route(entries, "255.255.255.255")
        let loopback = try route(entries, "::1", family: .ipv6)
        try expect(last.sortKey.localizedStandardCompare(loopback.sortKey) == .orderedAscending, "IPv4 avant IPv6")
    }
}
