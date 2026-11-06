import Foundation
import NetScopeCore

/// Données de démonstration IPv6 (0.31.0) : préfixes de documentation (2001:db8::/32) et ULA,
/// voisins du réseau de démonstration rattachés par la MAC, état de ce Mac, traceroute.
enum IPv6Demo {
    static let ula = IPv6Address("fd4e:7a21:9c30:10::")!
    static let global = IPv6Address("2001:db8:a00:10::")!
    static let linkLocal = IPv6Address("fe80::")!

    private static func host(_ prefix: IPv6Address, _ suffix: UInt64) -> IPv6Address {
        IPv6Address(high: prefix.high, low: suffix)
    }

    /// Voisins de la table NDP de démonstration (interface en0).
    static let neighbors: [IPv6Neighbor] = {
        var list: [IPv6Neighbor] = []
        func add(_ macText: String, _ addresses: [IPv6Address], router: Bool = false) {
            guard let mac = MACAddress(macText) else { return }
            for address in addresses {
                list.append(IPv6Neighbor(address: address, mac: mac, interfaceIndex: 4, interfaceName: "en0", isRouter: router))
            }
        }
        func eui(_ macText: String, _ prefix: IPv6Address) -> IPv6Address {
            IPv6Address.eui64(mac: MACAddress(macText)!, prefix: prefix)
        }
        // Passerelle FortiGate : annonces RA, adresses ::1 fixes.
        add("04:D5:90:3A:7B:11", [eui("04:D5:90:3A:7B:11", linkLocal), host(global, 1), host(ula, 1)], router: true)
        add("70:0F:6A:91:4C:02", [eui("70:0F:6A:91:4C:02", linkLocal)])
        add("94:DD:F8:18:15:7D", [eui("94:DD:F8:18:15:7D", linkLocal), eui("94:DD:F8:18:15:7D", global)])
        // Portable Windows : identifiant opaque (RFC 7217) et adresse temporaire.
        add("8C:16:45:2B:9E:03", [host(linkLocal, 0xA4C1_7F2E_5B30_9D11), host(global, 0xA4C1_7F2E_5B30_9D11),
                                  host(global, 0x3E61_08B9_D2A4_75C0), host(ula, 0xA4C1_7F2E_5B30_9D11)])
        // Postes fixes : DHCPv6 (adresses courtes).
        add("B0:7B:25:44:A1:6C", [host(linkLocal, 0x51D3_2A90_C4E7_1B08), host(global, 0x117), host(ula, 0x117)])
        add("B0:7B:25:44:B2:26", [host(linkLocal, 0x7F02_E914_3B6D_A5C2), host(global, 0x126), host(ula, 0x126)])
        add("80:5E:C0:3A:61:21", [eui("80:5E:C0:3A:61:21", linkLocal)])
        // Téléphone Android (MAC aléatoire) : adresse temporaire seulement.
        add("D6:4E:81:7A:33:C0", [host(linkLocal, 0x8D2C_51F7_3E09_B6A4), host(global, 0xC3F1_9E27_0A5D_6B18)])
        add("00:11:32:9A:4E:07", [eui("00:11:32:9A:4E:07", linkLocal), eui("00:11:32:9A:4E:07", ula), eui("00:11:32:9A:4E:07", global)])
        // Appareil vu seulement en IPv6 (aucune adresse IPv4 dans les plages scannées).
        add("5C:E9:1E:44:0A:7F", [host(linkLocal, 0x5EE9_1EFF_FE44_0A7F), host(global, 0x5EE9_1EFF_FE44_0A7F)])
        return list
    }()

    /// Adresses de ce Mac (en0).
    static let localAddresses: [LocalIPv6Address] = [
        LocalIPv6Address(interface: "en0", address: host(linkLocal, 0x1C8A_4F2E_9B3D_7A10), prefixLength: 64),
        LocalIPv6Address(interface: "en0", address: host(ula, 0x1C8A_4F2E_9B3D_7A10), prefixLength: 64),
        LocalIPv6Address(interface: "en0", address: host(global, 0x1C8A_4F2E_9B3D_7A10), prefixLength: 64),
        LocalIPv6Address(interface: "en0", address: host(global, 0x5D27_C1E4_88A0_3F62), prefixLength: 64),
    ]

    static var status: IPv6HostStatus { IPv6HostStatus(interface: "en0", addresses: localAddresses) }

    /// Réponses à la sollicitation ff02::1 (lien local de chaque voisin).
    static var solicited: [IPv6Address] { neighbors.map(\.address).filter { $0.scope == .linkLocal } }

    /// Appareils de démonstration complétés de leurs adresses IPv6 (ce Mac compris).
    static func attach(_ devices: [Device]) -> [Device] {
        var list = devices
        IPv6Attachment.attach(neighbors, to: &list)
        if let index = list.firstIndex(where: { $0.mac == MACAddress("3C:22:FB:7E:05:B1") }) {
            list[index].ipv6 = localAddresses.map(\.address).sorted(by: IPv6Address.displayOrder)
        }
        return list
    }

    /// Cible IPv6 de démonstration du ping continu (et du traceroute).
    static let pingTarget = "2001:4860:4860::8888"

    /// Captures : NETSCOPE_PING_IPV6=1 ajoute une cible IPv6 au ping continu de démonstration.
    static var pingInputs: [String] {
        ProcessInfo.processInfo.environment["NETSCOPE_PING_IPV6"] == "1" ? [pingTarget] : []
    }

    /// Traceroute IPv6 de démonstration vers `pingTarget`.
    static let trace: [IPv6TraceHop] = IPv6Trace.parse("""
     1  2001:db8:a00:10::1  0.812 ms  0.640 ms  0.701 ms
     2  2001:db8:ff00:1::1  6.204 ms  5.881 ms  6.410 ms
     3  2001:db8:ff00:40::2  9.775 ms  9.902 ms  10.118 ms
     4  * * *
     5  2001:4860:0:1::5a3  12.391 ms  12.205 ms  12.640 ms
     6  2001:4860:4860::8888  12.912 ms  12.744 ms  13.020 ms
    """)
}
