import Foundation
import NetScopeCore

/// Note 84 : appareils Wi-Fi de la démonstration (mode --demo, captures). Une deuxième borne FortiAP
/// (AP-ETG2, branchée sur SW-ETG2-01 1/20) et deux portables Lenovo en Wi-Fi, avec leur bail DHCP de
/// la démonstration (10.182.122.153 et .162, mêmes MAC que DHCPScopeDemo). Le premier est passé de la
/// borne AP-ETG2 à la borne AP-ACCUEIL : une itinérance dans son historique, sans alerte. Aucun accès
/// réseau : les clients Wi-Fi viennent de FortiAPDemo.
@MainActor
enum WirelessDemo {
    /// Portable qui change de borne (itinérance de la démonstration).
    static let roamingIP = "10.182.122.153"
    /// Port de la borne AP-ACCUEIL (10.182.122.102) et de la borne AP-ETG2 (10.182.122.104).
    static let accueilPort = (switchName: "SW-CORE-01", port: "Gi1/0/12")
    static let etage2Port = (switchName: "SW-ETG2-01", port: "1/20")

    /// Borne et portables ajoutés à l'historique de démonstration (`InvDemo`).
    static func devices(firstSeen: Date) -> [Device] {
        func device(_ ip: String, _ mac: String, _ host: String, _ vendor: String, _ place: (switchName: String, port: String),
                    _ vlan: Int, _ type: DeviceType, name: String? = nil, ports: [UInt16] = []) -> Device {
            Device(ip: IPv4Address(ip)!, mac: MACAddress(mac), vendor: vendor, hostname: host, customName: name,
                   isOnline: true, latencyMs: type == .pointAcces ? 2.6 : 11.4, openPorts: ports,
                   switchName: place.switchName, switchPort: place.port, vlan: vlan,
                   firstSeen: firstSeen, lastSeen: firstSeen, rangeLabel: "Bureau", deviceType: type)
        }
        return [
            device("10.182.122.104", "70:4C:A5:1E:31:04", "FortiAP-231F-ETG2", "Fortinet", etage2Port, 20, .pointAcces,
                   name: "Borne Wi-Fi étage 2", ports: [22, 443]),
            // Bail DHCP de la démonstration : PF4L03M23 (8C:16:45:36:24:3C) et PF4L12M22 (8C:16:45:75:87:D5).
            device(roamingIP, "8C:16:45:36:24:3C", "PF4L03M23", "Lenovo", etage2Port, 1, .poste, ports: [135, 445]),
            device("10.182.122.162", "8C:16:45:75:87:D5", "PF4L12M22", "Lenovo", accueilPort, 1, .poste, ports: [135, 445]),
        ]
    }

    /// Clients Wi-Fi des bornes FortiAP de la démonstration et ports des bornes, pour la fusion des
    /// scans de démonstration.
    static func context(devices: [Device], now: Date) -> InvWirelessContext {
        let overview = FortiWifiMerge.overview(FortiAPDemo.initialSites(now: now))
        return InvWirelessContext(overview: overview, devices: devices, localWifiIPs: [DemoData.interface.address])
    }
}
