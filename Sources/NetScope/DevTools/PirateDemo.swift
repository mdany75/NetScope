import Foundation
import NetScopeCore

/// Notes 96 et 97 : données fixes de démonstration (aucun envoi DHCP, ARP ni balayage Wi-Fi).
enum PirateDemo {
    static let accepted: Set<String> = []

    /// Balayage de ce Mac : la FortiAP du site, un sosie ouvert d'« Invités » et des voisines.
    static let localScan: [WifiNetwork] = [
        WifiNetwork(ssid: "Groupe-Interne", bssid: MACAddress("70:4C:A5:1E:22:A1"), channel: 36, band: .ghz5, widthMHz: 80,
                    rssi: -48, security: .wpa2Enterprise, isConnected: true),
        WifiNetwork(ssid: "Invités", bssid: MACAddress("70:4C:A5:1E:22:A2"), channel: 36, band: .ghz5, widthMHz: 80,
                    rssi: -49, security: .open),
        WifiNetwork(ssid: "Invités", bssid: MACAddress("D2:6E:0E:41:9B:07"), channel: 11, band: .ghz24, rssi: -55, security: .open),
        WifiNetwork(ssid: "Cafe-Voisin", bssid: MACAddress("9C:53:22:5D:18:C2"), channel: 6, band: .ghz24, rssi: -76,
                    security: .wpa2Personal),
        WifiNetwork(ssid: "Bell-4417", bssid: MACAddress("44:E9:DD:0A:41:17"), channel: 1, band: .ghz24, rssi: -82,
                    security: .wpa2Personal),
    ]

    /// Borne Ubiquiti branchée sur un port du switch de l'étage (MAC de base voisine du BSSID).
    static func wired(site: String) -> [RogueAPWiredMAC] {
        [RogueAPWiredMAC(site: site, mac: MACAddress("78:8A:20:4E:C3:00")!, place: "SW-ETG2-01 · port 1/22 · VLAN 1")]
    }

    /// ARP de ce Mac et de la FortiGate : la passerelle usurpée par un poste, une IP en double.
    static func observations(site: String, now: Date) -> [IPObservation] {
        let gw = IPv4Address("10.182.122.1")!
        let dup = IPv4Address("10.182.122.145")!
        return [
            IPObservation(site: site, ip: gw, mac: MACAddress("04:D5:90:3A:7B:11")!, source: .arp, date: now.addingTimeInterval(-95)),
            IPObservation(site: site, ip: gw, mac: MACAddress("3C:7C:3F:A1:52:E8")!, source: .arp, date: now.addingTimeInterval(-70)),
            IPObservation(site: site, ip: dup, mac: MACAddress("F8:FF:C2:4A:10:3B")!, source: .scan, date: now.addingTimeInterval(-20 * 60)),
            IPObservation(site: site, ip: dup, mac: MACAddress("B8:27:EB:9E:41:0D")!, source: .fortiGate, date: now.addingTimeInterval(-4 * 60)),
            IPObservation(site: site, ip: dup, mac: MACAddress("F8:FF:C2:4A:10:3B")!, source: .arp, date: now.addingTimeInterval(-60)),
        ]
    }

    /// Un portable qui change d'IP sans arrêt (bail court, MAC fixe).
    static func changes(site: String, now: Date) -> [IPChange] {
        let mac = MACAddress("A4:83:E7:5C:21:9F")!
        let steps: [(String, Double)] = [("10.182.122.161", 9.5), ("10.182.122.174", 7), ("10.182.122.161", 4.2),
                                         ("10.182.122.188", 2.1), ("10.182.122.192", 0.6)]
        return steps.map { IPChange(site: site, mac: mac, ip: IPv4Address($0.0)!, date: now.addingTimeInterval(-$0.1 * 3600)) }
    }
}
