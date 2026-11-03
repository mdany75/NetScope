import Foundation
import NetScopeCore

/// Relevés SNMP fictifs (croquis Switch.dc.html), cohérents avec DemoData : SW-CORE-01 (48 ports
/// + 4 SFP+) et SW-ETG2-01 (24 ports + 4 SFP+). Aucun accès réseau.
@MainActor
enum SwitchDemo {
    struct Result {
        var snapshots: [SNMPSwitchSnapshot]
        var names: [MACAddress: String]
    }

    private static let day: UInt32 = 8_640_000  // centièmes de seconde

    static func make(now: Date = Date()) -> Result {
        let devices = DemoData.devices(now: now)
        func mac(_ ip: String) -> MACAddress { devices.first { $0.id == ip }!.mac! }
        var names: [MACAddress: String] = [:]

        func synth(_ prefix: [UInt8], _ n: Int) -> MACAddress {
            MACAddress(bytes: prefix + [UInt8((n * 5 + 17) % 256), UInt8((n * 11 + 3) % 256), UInt8((n * 17 + 9) % 256)])
        }
        let dell: [UInt8] = [0xB0, 0x7B, 0x25], lenovo: [UInt8] = [0x8C, 0x16, 0x45], hp: [UInt8] = [0x3C, 0xD9, 0x2B]
        let cisco: [UInt8] = [0x00, 0x1B, 0x54], axis: [UInt8] = [0xAC, 0xCC, 0x8E]
        let vendors = [dell, lenovo, hp]

        // ---- SW-CORE-01 ----
        let coreUptime: UInt32 = 142 * day + 6 * 360_000
        var coreIfs: [SNMPInterface] = []
        var coreFDB: [SNMPFDBEntry] = []
        var coreNeighbors: [SNMPLLDPNeighbor] = []
        var corePvid: [Int: Int] = [:]
        var corePoE: Set<Int> = []
        var coreARP: [MACAddress: IPv4Address] = [:]
        let coreDown: Set<Int> = [3, 4, 11, 16, 23, 24, 27, 28, 35, 39, 44, 45, 46]
        let phones: Set<Int> = [13, 14, 15, 25, 26, 29, 31]
        func add(_ list: inout [SNMPFDBEntry], _ mac: MACAddress, _ vlan: Int, _ i: Int) {
            list.append(SNMPFDBEntry(mac: mac, vlan: vlan, bridgePort: i, ifIndex: i))
        }
        for n in 1...48 {
            var iface = SNMPInterface(index: n, name: "Gi1/0/\(n)", descr: "GigabitEthernet1/0/\(n)", alias: "Prise \(100 + n)",
                                      operStatus: .up, speedMbps: 1000, lastChangeTicks: coreUptime - UInt32((n % 9) + 2) * day,
                                      inErrors: 0, inOctets: UInt64((n * 37 % 870) + 35) * 100_000_000,
                                      outOctets: UInt64((n * 53 % 870) + 35) * 100_000_000)
            corePvid[n] = 1
            switch n {
            case 1:
                iface.alias = "Uplink FortiGate-60F (internal1)"
                iface.inOctets = 3_410_000_000_000
                iface.outOctets = 1_960_000_000_000
                add(&coreFDB, mac("10.182.122.1"), 1, n)
                coreNeighbors.append(SNMPLLDPNeighbor(localPortNum: n, ifIndex: n, sysName: "FortiGate-60F", portID: "internal1",
                                                      portDescr: "internal1", sysDescr: "FortiGate-60F v7.2.8", capabilities: [.router, .bridge]))
            case 12:
                iface.alias = "AP plafond · salle de réunion 1"
                corePvid[n] = 20
                corePoE.insert(n)
                add(&coreFDB, mac("10.182.122.102"), 20, n)
                add(&coreFDB, mac("10.182.122.135"), 20, n)
                add(&coreFDB, mac("10.182.122.133"), 20, n)
                coreNeighbors.append(SNMPLLDPNeighbor(localPortNum: n, ifIndex: n, sysName: "FortiAP-231F", portID: "eth0",
                                                      portDescr: "eth0", sysDescr: "FortiAP-231F v7.2.3 · 802.3at", capabilities: [.accessPoint]))
            case 18:
                iface.alias = "Bureau 214 · duplex non concordant probable"
                iface.speedMbps = 100
                iface.inErrors = 1284
                iface.lastChangeTicks = coreUptime - 47 * 6000
                let m = synth(hp, 18)
                add(&coreFDB, m, 1, n)
                names[m] = "IMP-RH-02"
                coreARP[m] = IPv4Address("10.182.122.162")
            case 22:
                iface.alias = "Bureau 122 · poste comptabilité"
                add(&coreFDB, mac("10.182.122.117"), 1, n)
            case 23:
                iface.alias = "Bureau 123 · poste réception"
            case 33, 34:
                iface.alias = n == 33 ? "Caméra quai" : "Caméra cour"
                corePvid[n] = 40
                corePoE.insert(n)
                iface.speedMbps = 100
                add(&coreFDB, mac(n == 33 ? "192.168.50.21" : "192.168.50.22"), 40, n)
            case 40:
                iface.alias = "Salle serveurs · SRV-AD-01"
                corePvid[n] = 100
                add(&coreFDB, mac("10.10.0.10"), 100, n)
            case 47:
                iface.alias = "Uplink vers SW-ETG2-01 (1/25)"
                iface.inOctets = 2_070_000_000_000
                iface.outOctets = 4_820_000_000_000
                coreNeighbors.append(SNMPLLDPNeighbor(localPortNum: n, ifIndex: n, sysName: "SW-ETG2-01", portID: "1/25", portDescr: "1/25",
                                                      sysDescr: "Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch, revision WC.16.11.0012",
                                                      capabilities: [.bridge]))
                add(&coreFDB, mac("10.182.122.3"), 1, n)
                for ip in ["10.182.122.100", "10.182.122.106", "10.182.122.111", "10.182.122.113", "10.182.122.140"] {
                    add(&coreFDB, mac(ip), devices.first { $0.id == ip }?.vlan ?? 1, n)
                }
                for k in [1, 10, 13, 15, 21] { add(&coreFDB, synth(vendors[k % 3], 200 + k), 1, n) }
            default:
                if coreDown.contains(n) {
                    iface.operStatus = .down
                    iface.speedMbps = 1000
                    iface.inOctets = 0
                    iface.outOctets = 0
                    if n == 44 {
                        iface.adminUp = false
                        iface.alias = "Désactivé (shutdown) · ancien poste"
                    } else {
                        iface.alias = "Prise \(100 + n) · libre"
                    }
                } else if phones.contains(n) {
                    iface.alias = "Téléphone IP · bureau \(100 + n)"
                    corePoE.insert(n)
                    let m = synth(cisco, n)
                    let name = "SEP" + m.formatted(.bare).uppercased()
                    names[m] = name
                    coreARP[m] = IPv4Address("10.182.110.\(20 + n)")
                    add(&coreFDB, m, 110, n)
                    coreNeighbors.append(SNMPLLDPNeighbor(localPortNum: n, ifIndex: n, sysName: name, portID: "Port 1",
                                                          sysDescr: "Cisco IP Phone CP-8845", capabilities: [.telephone]))
                } else {
                    iface.alias = "Bureau \(100 + n)"
                    if [30, 37].contains(n) { iface.speedMbps = 100 }
                    let m = synth(vendors[n % 3], n)
                    names[m] = "WKS3\(50 + n)"
                    coreARP[m] = IPv4Address("10.182.122.\(150 + n)")
                    add(&coreFDB, m, 1, n)
                }
            }
            coreIfs.append(iface)
        }
        for (k, n) in (49...52).enumerated() {
            var iface = SNMPInterface(index: n, name: "Te1/1/\(k + 1)", descr: "TenGigabitEthernet1/1/\(k + 1)",
                                      alias: k == 1 ? "Réservé · uplink caméras futur" : "Libre", operStatus: .down, speedMbps: 10_000)
            iface.lastChangeTicks = coreUptime - 87 * day
            coreIfs.append(iface)
        }
        coreIfs.append(SNMPInterface(index: 100, name: "Vlan1", descr: "Vlan1", type: 53, operStatus: .up))
        for device in devices where device.rangeLabel == "Bureau" { coreARP[device.mac!] = device.ip }

        let core = SNMPSwitchSnapshot(
            host: IPv4Address("10.182.122.2")!,
            system: SNMPSystemInfo(name: "SW-CORE-01", descr: "Cisco Catalyst 9300-48P, IOS XE Software, Version 17.9.4a",
                                   objectID: "1.3.6.1.4.1.9.1.2494", uptimeTicks: coreUptime, location: "Salle technique · baie A",
                                   contact: "support@exemple.ca"),
            interfaces: coreIfs, fdb: coreFDB, neighbors: coreNeighbors, pvid: corePvid, poePorts: corePoE,
            poeBudgetW: 740, poeUsedW: 412, arp: coreARP, polledAt: now.addingTimeInterval(-95))

        // ---- SW-ETG2-01 ----
        let etgUptime: UInt32 = 87 * day + 21 * 360_000
        var etgIfs: [SNMPInterface] = []
        var etgFDB: [SNMPFDBEntry] = []
        var etgNeighbors: [SNMPLLDPNeighbor] = []
        var etgPvid: [Int: Int] = [:]
        var etgPoE: Set<Int> = []
        let etgDown: Set<Int> = [2, 8, 11, 12, 17, 19, 22, 23, 24]
        for n in 1...24 {
            var iface = SNMPInterface(index: n, name: "1/\(n)", descr: "\(n)", alias: "Prise 2-" + String(format: "%02d", n),
                                      operStatus: .up, speedMbps: 1000, lastChangeTicks: etgUptime - UInt32((n % 9) + 2) * day,
                                      inErrors: 0, inOctets: UInt64((n * 37 % 870) + 35) * 100_000_000,
                                      outOctets: UInt64((n * 53 % 870) + 35) * 100_000_000)
            etgPvid[n] = 1
            switch n {
            case 3: add(&etgFDB, mac("10.182.122.113"), 1, n); iface.alias = "Bureau 2.03 · portable Marc"
            case 4, 5, 6:
                let m = synth(axis, n)
                names[m] = "CAM-ETG2-0\(n - 3)"
                add(&etgFDB, m, 40, n)
                etgPvid[n] = 40
                etgPoE.insert(n)
                iface.speedMbps = 100
                iface.alias = "Caméra étage 2 · zone \(n - 3)"
            case 7: add(&etgFDB, mac("10.182.122.100"), 1, n); iface.alias = "Bureau 2.07"
            case 9:
                add(&etgFDB, mac("10.182.122.106"), 30, n)
                etgPvid[n] = 30
                etgPoE.insert(n)
                iface.speedMbps = 100
                iface.alias = "Affichage dynamique hall"
            case 14:
                add(&etgFDB, mac("10.182.122.111"), 30, n)
                etgPvid[n] = 30
                iface.alias = "Imprimante étage 2 · corridor"
            case 18:
                add(&etgFDB, mac("10.182.122.140"), 30, n)
                etgPvid[n] = 30
                iface.alias = "Imprimante RH"
            case 20:
                let m = synth(dell, 220)
                names[m] = "WKS430"
                add(&etgFDB, m, 1, n)
                iface.inErrors = 342
                iface.lastChangeTicks = etgUptime - 135 * 6000
                iface.alias = "Salle de conférence 2.08"
            default:
                if etgDown.contains(n) {
                    iface.operStatus = .down
                    iface.inOctets = 0
                    iface.outOctets = 0
                    iface.alias += " · libre"
                } else {
                    let m = synth(vendors[n % 3], 200 + n)
                    names[m] = "WKS4\(10 + n)"
                    add(&etgFDB, m, 1, n)
                }
            }
            etgIfs.append(iface)
        }
        for n in 25...28 {
            var iface = SNMPInterface(index: n, name: "1/\(n)", descr: "\(n)", alias: "Libre", operStatus: .down, speedMbps: 10_000)
            if n == 25 {
                iface.operStatus = .up
                iface.alias = "Uplink vers SW-CORE-01 (Gi1/0/47)"
                iface.inOctets = 4_820_000_000_000
                iface.outOctets = 2_070_000_000_000
                iface.lastChangeTicks = etgUptime - 87 * day
                etgNeighbors.append(SNMPLLDPNeighbor(localPortNum: n, ifIndex: n, sysName: "SW-CORE-01", portID: "Gi1/0/47",
                                                     portDescr: "GigabitEthernet1/0/47",
                                                     sysDescr: "Cisco C9300-48P · IOS XE 17.9.4a", capabilities: [.bridge, .router]))
                for ip in ["10.182.122.1", "10.182.122.2", "10.182.122.102", "10.182.122.117", "10.10.0.10"] {
                    add(&etgFDB, mac(ip), devices.first { $0.id == ip }?.vlan ?? 1, n)
                }
            }
            etgIfs.append(iface)
        }
        let etg = SNMPSwitchSnapshot(
            host: IPv4Address("10.182.122.3")!,
            system: SNMPSystemInfo(name: "SW-ETG2-01", descr: "Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch, revision WC.16.11.0012",
                                   objectID: "1.3.6.1.4.1.11.2.3.7.11.181", uptimeTicks: etgUptime, location: "Étage 2 · local réseau"),
            interfaces: etgIfs, fdb: etgFDB, neighbors: etgNeighbors, pvid: etgPvid, poePorts: etgPoE,
            poeBudgetW: 370, poeUsedW: 96, polledAt: now.addingTimeInterval(-93))
        return Result(snapshots: [core, etg], names: names)
    }
}
