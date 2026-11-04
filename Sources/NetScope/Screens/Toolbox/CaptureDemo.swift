import Foundation
import NetScopeCore

/// Données de démonstration du Test DHCP et de la capture LLDP/CDP (renderVals de
/// docs/croquis/Toolbox.dc.html : dhcpRows, lldpFields). Aucun accès réseau.
enum CaptureDemo {
    /// VLAN des postes dans l'astuce de la fiche du voisin (croquis : « les postes sont en VLAN 10 »).
    static let workstationVLAN = 10

    static let interfaces: [LocalInterface] = [
        LocalInterface(name: "en0", address: IPv4Address("10.182.122.135")!, netmask: IPv4Address("255.255.255.0")!,
                       kind: .wifi, gateway: IPv4Address("10.182.122.1")),
        LocalInterface(name: "en7", address: IPv4Address("10.182.122.142")!, netmask: IPv4Address("255.255.255.0")!,
                       kind: .ethernet, gateway: IPv4Address("10.182.122.1")),
    ]

    static let xid: UInt32 = 0x5A1C_93E2

    /// Le FortiGate attendu et un routeur TP-Link branché à l'envers.
    static func offers() -> [DHCPOffer] {
        var legit = DHCPOffer(messageType: .offer, xid: xid, flagsBroadcast: true, offeredAddress: IPv4Address("10.182.122.187")!)
        legit.serverIdentifier = IPv4Address("10.182.122.1")
        legit.sourceAddress = IPv4Address("10.182.122.1")
        legit.sourceMAC = MACAddress("04:D5:90:3A:7C:11")
        legit.subnetMask = IPv4Address("255.255.255.0")
        legit.routers = [IPv4Address("10.182.122.1")!]
        legit.dnsServers = [IPv4Address("10.182.122.1")!]
        legit.domainName = "bureau.local"
        legit.leaseTime = 86_400
        legit.renewalTime = 43_200
        legit.rebindingTime = 75_600
        legit.optionCodes = [53, 54, 51, 58, 59, 1, 3, 6, 15]
        legit.delay = 0.004

        var rogue = DHCPOffer(messageType: .offer, xid: xid, flagsBroadcast: true, offeredAddress: IPv4Address("192.168.0.100")!)
        rogue.serverIdentifier = IPv4Address("10.182.122.250")
        rogue.sourceAddress = IPv4Address("10.182.122.250")
        rogue.sourceMAC = MACAddress("D8:07:B6:62:4E:A0")
        rogue.subnetMask = IPv4Address("255.255.255.0")
        rogue.routers = [IPv4Address("192.168.0.1")!]
        rogue.dnsServers = [IPv4Address("192.168.0.1")!]
        rogue.leaseTime = 7_200
        rogue.renewalTime = 3_600
        rogue.rebindingTime = 6_300
        rogue.optionCodes = [53, 54, 51, 58, 59, 1, 3, 6]
        rogue.delay = 0.020
        return [legit, rogue]
    }

    /// Emplacement connu des serveurs (démonstration : le TP-Link n'est pas dans l'inventaire).
    static let locations: [MACAddress: String] = [MACAddress("D8:07:B6:62:4E:A0")!: "SW-CORE-01 · Gi1/0/37 · VLAN 1"]

    /// Voisin LLDP de la prise du bureau 214.
    static func neighbor(receivedAt: Date) -> NetworkNeighbor {
        NetworkNeighbor(protocols: [.lldp], chassisID: "88:3A:30:9C:41:00", systemName: "SW-ETG2-01", portID: "1/22",
                        portDescription: "Bureau 214 - prise B",
                        systemDescription: "Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch, revision WC.16.11.0012",
                        model: "Aruba 2930F-24G", softwareVersion: "WC.16.11.0012", nativeVLAN: 1,
                        managementAddresses: ["10.182.122.3"], capabilities: ["Bridge", "Router"],
                        poe: "802.3at · non utilisé", link: "1000BASE-T duplex intégral", ttl: 120,
                        sourceMAC: "88:3A:30:9C:41:22", receivedAt: receivedAt, interface: "en7", power: PoEDemo.macPower)
    }
}
