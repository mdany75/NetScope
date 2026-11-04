import Foundation
import NetScopeCore

/// Données de démonstration, reprises des croquis (docs/croquis/Main.dc.html) :
/// réseau 10.182.122.0/24 « Bureau », caméras, serveurs. Aucun accès réseau.
@MainActor
enum DemoData {
    static func apply(to state: AppState) {
        state.ranges = ranges
        state.devices = devices()
        state.selectedDeviceID = "10.182.122.111"
        state.activeInterface = LocalInterface(name: "en0", address: IPv4Address("10.182.122.135")!,
                                               netmask: IPv4Address("255.255.255.0")!, kind: .wifi,
                                               gateway: IPv4Address("10.182.122.1")!)
        state.dnsServers = [IPv4Address("10.182.122.1")!]
        state.updateAvailable = "1.1.0"
        state.pingTargets = ["10.182.122.1", "10.182.122.111", "8.8.8.8"]
        state.sidebarBadges = [.surveillance: 3, .analyse: 1]
        MonStore.shared.attach(to: state) // badge Surveillance = alertes non lues de la démonstration
    }

    static let ranges = [
        ScanRangeConfig(text: "10.182.122.0/24", label: "Bureau", vlan: 1),
        ScanRangeConfig(text: "192.168.50.0/24", label: "Caméras", vlan: 40),
        ScanRangeConfig(text: "10.10.0.1-50", label: "Serveurs", vlan: 100),
    ]

    private struct Row {
        let ip: String, name: String?, host: String, vendor: String?, mac: String, latency: Double?
        let ports: [UInt16], sw: String, port: String, vlan: Int, minutesAgo: Double
        let type: DeviceType, online: Bool, range: String
    }

    private static let rows: [Row] = [
        Row(ip: "10.182.122.1", name: "Passerelle", host: "FortiGate-60F", vendor: "Fortinet", mac: "04:D5:90:3A:7B:11", latency: 0.8, ports: [22, 443, 541], sw: "SW-CORE-01", port: "Gi1/0/1", vlan: 1, minutesAgo: 0, type: .routeur, online: true, range: "Bureau"),
        Row(ip: "10.182.122.2", name: "Switch cœur", host: "SW-CORE-01", vendor: "Cisco", mac: "70:0F:6A:91:4C:02", latency: 1.1, ports: [22, 23, 443], sw: "SW-CORE-01", port: "Vlan1 (SVI)", vlan: 1, minutesAgo: 0, type: .switch, online: true, range: "Bureau"),
        Row(ip: "10.182.122.3", name: "Switch étage 2", host: "SW-ETG2-01", vendor: "HPE Aruba", mac: "88:3A:30:5D:E1:40", latency: 1.6, ports: [22, 80, 443], sw: "SW-CORE-01", port: "Gi1/0/47", vlan: 1, minutesAgo: 0, type: .switch, online: true, range: "Bureau"),
        Row(ip: "10.182.122.100", name: nil, host: "ca2032249c778fc96008b9df7aa447c9", vendor: nil, mac: "3A:1F:C7:02:9B:E4", latency: 6.4, ports: [], sw: "SW-ETG2-01", port: "1/7", vlan: 1, minutesAgo: 2, type: .inconnu, online: true, range: "Bureau"),
        Row(ip: "10.182.122.102", name: "Borne Wi-Fi accueil", host: "FortiAP-231F", vendor: "Fortinet", mac: "70:4C:A5:1E:22:9A", latency: 2.3, ports: [22, 443], sw: "SW-CORE-01", port: "Gi1/0/12", vlan: 20, minutesAgo: 0, type: .pointAcces, online: true, range: "Bureau"),
        Row(ip: "10.182.122.106", name: "Affichage hall", host: "BrightSign-D1E876001191", vendor: "BrightSign", mac: "90:AC:3F:0D:18:76", latency: 3.4, ports: [80, 8080], sw: "SW-ETG2-01", port: "1/9", vlan: 30, minutesAgo: 0, type: .iot, online: true, range: "Bureau"),
        Row(ip: "10.182.122.111", name: "Imprimante accueil", host: "Brother DCP-L2640DW", vendor: "Brother", mac: "94:DD:F8:18:15:7D", latency: 4.1, ports: [80, 443, 9100, 631], sw: "SW-ETG2-01", port: "1/14", vlan: 30, minutesAgo: 0, type: .imprimante, online: true, range: "Bureau"),
        Row(ip: "10.182.122.113", name: "Portable Marc", host: "PF4L8M20", vendor: "Lenovo", mac: "8C:16:45:2B:9E:03", latency: 5.2, ports: [135, 445], sw: "SW-ETG2-01", port: "1/3", vlan: 1, minutesAgo: 1, type: .poste, online: true, range: "Bureau"),
        Row(ip: "10.182.122.117", name: "Poste comptabilité", host: "WKS346", vendor: "Dell", mac: "B0:7B:25:44:A1:6C", latency: 1.9, ports: [135, 445, 3389], sw: "SW-CORE-01", port: "Gi1/0/22", vlan: 1, minutesAgo: 0, type: .poste, online: true, range: "Bureau"),
        Row(ip: "10.182.122.133", name: nil, host: "Android_89UM1WTN", vendor: nil, mac: "D6:4E:81:7A:33:C0", latency: 18.6, ports: [], sw: "FortiAP-231F", port: "Wi-Fi", vlan: 20, minutesAgo: 4, type: .telephone, online: true, range: "Bureau"),
        Row(ip: "10.182.122.135", name: "Ce Mac", host: "Macmini-de-Dany.local", vendor: "Apple", mac: "3C:22:FB:7E:05:B1", latency: 0.1, ports: [22, 5900], sw: "FortiAP-231F", port: "Wi-Fi", vlan: 20, minutesAgo: 0, type: .poste, online: true, range: "Bureau"),
        Row(ip: "10.182.122.140", name: nil, host: "NPI7A4410", vendor: "HP", mac: "00:1A:2B:44:10:EE", latency: 7.8, ports: [80, 9100], sw: "SW-ETG2-01", port: "1/18", vlan: 30, minutesAgo: 3, type: .imprimante, online: true, range: "Bureau"),
        Row(ip: "10.182.122.146", name: "Poste réception", host: "WKS341", vendor: "Dell", mac: "B0:7B:25:44:9F:20", latency: nil, ports: [], sw: "SW-CORE-01", port: "Gi1/0/23", vlan: 1, minutesAgo: 180, type: .poste, online: false, range: "Bureau"),
        Row(ip: "192.168.50.21", name: "Caméra quai", host: "DS-2CD2143G2-I", vendor: "Hikvision", mac: "BC:AD:28:6F:01:5A", latency: 3.0, ports: [80, 443, 554], sw: "SW-CORE-01", port: "Gi1/0/33", vlan: 40, minutesAgo: 0, type: .camera, online: true, range: "Caméras"),
        Row(ip: "192.168.50.22", name: nil, host: "axis-b8a44f2c19e0", vendor: "Axis", mac: "B8:A4:4F:2C:19:E0", latency: 2.7, ports: [80, 443, 554], sw: "SW-CORE-01", port: "Gi1/0/34", vlan: 40, minutesAgo: 0, type: .camera, online: true, range: "Caméras"),
        Row(ip: "10.10.0.10", name: "Contrôleur de domaine", host: "SRV-AD-01", vendor: "Dell", mac: "F4:EE:08:3C:72:A1", latency: 0.9, ports: [53, 88, 389, 445], sw: "SW-CORE-01", port: "Gi1/0/40", vlan: 100, minutesAgo: 0, type: .serveur, online: true, range: "Serveurs"),
    ]

    /// Origine du nom (et groupe NetBIOS) de chaque appareil fictif, comme la résolution automatique
    /// les donnerait : SNMP pour les équipements réseau, mDNS pour Apple et l'IoT, NetBIOS pour Windows.
    private static let names: [String: (NameDetails.Source, String?)] = [
        "10.182.122.1": (.snmp, nil), "10.182.122.2": (.snmp, nil), "10.182.122.3": (.snmp, nil),
        "10.182.122.100": (.mdns, nil), "10.182.122.102": (.dns, nil), "10.182.122.106": (.mdns, nil),
        "10.182.122.111": (.mdns, nil), "10.182.122.113": (.netbios, "BUREAU"), "10.182.122.117": (.netbios, "BUREAU"),
        "10.182.122.133": (.dns, nil), "10.182.122.135": (.mdns, nil), "10.182.122.140": (.netbios, "WORKGROUP"),
        "10.182.122.146": (.netbios, "BUREAU"), "192.168.50.21": (.dns, nil), "192.168.50.22": (.mdns, nil),
        "10.10.0.10": (.dns, nil),
    ]

    /// Nature SNMP des appareils qui ont répondu à la découverte automatique (démonstration).
    private static let snmpKinds: [String: SNMPDeviceKind] = [
        "10.182.122.1": .routeur, "10.182.122.2": .switch, "10.182.122.3": .switch, "10.182.122.111": .imprimante,
    ]

    /// Appareils datés par rapport à `now` (« à l'instant », « il y a 3 h »).
    static func devices(now: Date = Date()) -> [Device] {
        rows.map { row in
            let seen = now.addingTimeInterval(-row.minutesAgo * 60)
            return Device(ip: IPv4Address(row.ip)!, mac: MACAddress(row.mac), vendor: row.vendor,
                          hostname: row.host, customName: row.name, isOnline: row.online,
                          latencyMs: row.latency, openPorts: row.ports, switchName: row.sw,
                          switchPort: row.port, vlan: row.vlan,
                          firstSeen: now.addingTimeInterval(-14 * 86_400), lastSeen: seen,
                          rangeLabel: row.range, deviceType: row.type,
                          nameSource: names[row.ip]?.0, nameDomain: names[row.ip]?.1, snmpKind: snmpKinds[row.ip])
        }
        .sorted { $0.ip < $1.ip }
    }
}
