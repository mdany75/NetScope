import Foundation
import NetScopeCore

/// Lecture fictive d'une FortiGate (note 24) : FortiGate-60F en FortiOS 7.2.8 (la passerelle des autres écrans) et trois FortiSwitch
/// gérés par FortiLink (S248E, S124F-POE, S108F) en 10.255.1.x, avec leurs ports, le PoE et les
/// appareils détectés. Les appareils du scan de démonstration branchés sur ces switchs ont les
/// mêmes MAC que dans DemoData. Aucun accès réseau.
@MainActor
enum FortiGateDemo {
    static let config = FortiGateConfig(host: "10.182.122.1", port: 443, vdom: "",
                                        pinnedFingerprint: "3F:A9:51:C2:08:7E:B4:16:D2:9C:45:E0:7B:13:A8:6F:C1:52:90:3D:E7:48:0B:F6:A2:19:5C:D8:74:3E:61:B0")

    /// MAC des appareils de DemoData branchés sur les FortiSwitch.
    static let backupMAC = MACAddress("00:50:56:AA:10:31")!
    static let warehouseCamMAC = MACAddress("BC:AD:28:6F:22:31")!

    static func report(now: Date = Date()) -> FortiGateReport {
        let system = FortiGateSystem(hostname: "FGT-SIEGE", model: "FortiGate-60F", serial: "FGT60FTK22004711",
                                     version: "v7.2.8", build: 1639, vdom: "root")
        func synth(_ prefix: [UInt8], _ n: Int) -> MACAddress {
            MACAddress(bytes: prefix + [UInt8((n * 7 + 21) % 256), UInt8((n * 13 + 5) % 256), UInt8((n * 19 + 11) % 256)])
        }
        let zebra: [UInt8] = [0x00, 0x07, 0x4D], honeywell: [UInt8] = [0x00, 0x10, 0x20], dell: [UInt8] = [0xB0, 0x7B, 0x25]
        let hik: [UInt8] = [0xBC, 0xAD, 0x28], hid: [UInt8] = [0x00, 0x06, 0x8E], fortiAP: [UInt8] = [0x70, 0x4C, 0xA5]
        var detected: [FortiDetectedDevice] = []
        var dhcp: [FortiDHCPLease] = []
        var users: [FortiUserDevice] = []
        func place(_ mac: MACAddress, _ sw: String, _ port: Int, vlan: Int, ip: String?, name: String?, vendor: String? = nil,
                   seen: TimeInterval = 20) {
            detected.append(FortiDetectedDevice(mac: mac, switchID: sw, portName: "port\(port)", vlan: vlan,
                                                lastSeen: now.addingTimeInterval(-seen)))
            if let ip = ip.flatMap(IPv4Address.init) {
                dhcp.append(FortiDHCPLease(ip: ip, mac: mac, hostname: name, interface: "vlan\(vlan)",
                                           expires: now.addingTimeInterval(6 * 3600)))
                users.append(FortiUserDevice(mac: mac, ip: ip, hostname: name, vendor: vendor, switchID: sw, portName: "port\(port)", vlan: vlan))
            }
        }

        // ---- FSW-ENTREPOT : FS-248E-POE, cœur de l'entrepôt ----
        var entrepot: [FortiSwitchPort] = []
        let entrepotDown: Set<Int> = [6, 9, 15, 22, 23, 30, 31, 36, 41, 42, 43, 44, 45, 46, 47, 48]
        for n in 1...48 {
            var port = FortiSwitchPort(name: "port\(n)", number: n, linkUp: !entrepotDown.contains(n), adminUp: n != 44,
                                       speedMbps: entrepotDown.contains(n) ? nil : 1000, duplex: "full",
                                       nativeVLAN: "_default", nativeVLANID: 1, description: "Prise E-\(String(format: "%02d", n))",
                                       poeCapable: true, poeEnabled: true, poeState: "Searching", poePowerW: 0,
                                       rxBytes: UInt64((n * 41 % 700) + 20) * 90_000_000, txBytes: UInt64((n * 29 % 700) + 20) * 90_000_000,
                                       rxErrors: 0)
            switch n {
            case 1...5:
                // Lecteurs de codes-barres et imprimantes d'étiquettes des quais.
                let m = synth(n <= 3 ? honeywell : zebra, n)
                port.description = n <= 3 ? "Poste de quai \(n) · lecteur" : "Imprimante d’étiquettes \(n - 3)"
                port.nativeVLAN = "vlan30"
                port.nativeVLANID = 30
                if n <= 3 {
                    port.poeState = "Delivering Power"
                    port.poePowerW = 3.9 + Double(n) * 0.4
                    port.poeClass = 2
                }
                place(m, "FSW-ENTREPOT", n, vlan: 30, ip: "10.182.130.\(20 + n)",
                      name: n <= 3 ? "LECTEUR-QUAI-0\(n)" : "ZEBRA-ETIQ-0\(n - 3)", vendor: n <= 3 ? "Honeywell" : "Zebra")
            case 7, 8:
                port.description = "Point d’accès entrepôt \(n - 6)"
                port.nativeVLAN = "vlan20"
                port.nativeVLANID = 20
                port.poeState = "Delivering Power"
                port.poePowerW = n == 7 ? 13.6 : 12.8
                port.poeClass = 4
                place(synth(fortiAP, n), "FSW-ENTREPOT", n, vlan: 20, ip: "10.182.120.\(10 + n)", name: "FAP-ENTREPOT-0\(n - 6)", vendor: "Fortinet")
            case 10...14, 16...21:
                let m = synth(dell, 300 + n)
                port.description = "Bureau entrepôt \(n)"
                port.poeCapable = true
                place(m, "FSW-ENTREPOT", n, vlan: 1, ip: "10.182.122.\(170 + n)", name: "WKS-ENT\(String(format: "%02d", n))", vendor: "Dell")
            case 24:
                port.description = "Badgeuse entrée"
                port.nativeVLAN = "vlan30"
                port.nativeVLANID = 30
                port.poeState = "Delivering Power"
                port.poePowerW = 4.6
                port.poeClass = 1
                place(synth(hid, 24), "FSW-ENTREPOT", n, vlan: 30, ip: "10.182.130.40", name: "BADGE-ENTREE", vendor: "HID Global")
            case 44:
                port.description = "Désactivé · ancien poste"
            default:
                if !entrepotDown.contains(n) {
                    let m = synth(dell, 400 + n)
                    port.description = "Poste entrepôt \(n)"
                    place(m, "FSW-ENTREPOT", n, vlan: 1, ip: nil, name: nil)
                }
            }
            if !port.linkUp! {
                port.rxBytes = 0
                port.txBytes = 0
                port.poeState = "Searching"
            }
            entrepot.append(port)
        }
        entrepot.append(FortiSwitchPort(name: "port49", number: 49, linkUp: true, adminUp: true, speedMbps: 10_000, duplex: "full",
                                        nativeVLAN: "_default", nativeVLANID: 1, description: "FortiLink · FGT-SIEGE port1",
                                        isFortiLink: true, peerName: "FGT-SIEGE", rxBytes: 2_640_000_000_000, txBytes: 1_870_000_000_000, rxErrors: 0))
        entrepot.append(FortiSwitchPort(name: "port50", number: 50, linkUp: false, adminUp: true, nativeVLAN: "_default", nativeVLANID: 1,
                                        description: "FortiLink · lien de secours"))
        entrepot.append(FortiSwitchPort(name: "port51", number: 51, linkUp: true, adminUp: true, speedMbps: 10_000, duplex: "full",
                                        nativeVLAN: "_default", nativeVLANID: 1, description: "ISL vers FSW-QUAI (port25)",
                                        isISL: true, peerName: "FSW-QUAI", rxBytes: 640_000_000_000, txBytes: 910_000_000_000, rxErrors: 0))
        entrepot.append(FortiSwitchPort(name: "port52", number: 52, linkUp: true, adminUp: true, speedMbps: 10_000, duplex: "full",
                                        nativeVLAN: "_default", nativeVLANID: 1, description: "ISL vers FSW-SERVEURS (port10)",
                                        isISL: true, peerName: "FSW-SERVEURS", rxBytes: 1_210_000_000_000, txBytes: 530_000_000_000, rxErrors: 0))

        // ---- FSW-QUAI : FS-124F-POE, caméras et quais ----
        var quai: [FortiSwitchPort] = []
        let quaiDown: Set<Int> = [10, 13, 14, 17, 18, 19, 20, 21, 22, 23, 24]
        for n in 1...24 {
            var port = FortiSwitchPort(name: "port\(n)", number: n, linkUp: !quaiDown.contains(n), adminUp: true,
                                       speedMbps: quaiDown.contains(n) ? nil : 1000, duplex: "full",
                                       nativeVLAN: "vlan40", nativeVLANID: 40, description: "Prise Q-\(String(format: "%02d", n))",
                                       poeCapable: true, poeEnabled: true, poeState: "Searching", poePowerW: 0,
                                       rxBytes: UInt64((n * 37 % 500) + 15) * 70_000_000, txBytes: UInt64((n * 23 % 500) + 15) * 70_000_000,
                                       rxErrors: n == 9 ? 214 : 0)
            switch n {
            case 1...8:
                // Caméras : la première est celle du scan de démonstration (192.168.50.31).
                let mac = n == 1 ? warehouseCamMAC : synth(hik, 500 + n)
                port.description = n == 1 ? "Caméra entrepôt · allée A" : "Caméra quai \(n)"
                port.speedMbps = 100
                port.poeState = "Delivering Power"
                port.poePowerW = 5.2 + Double(n % 4) * 0.6
                port.poeClass = 3
                place(mac, "FSW-QUAI", n, vlan: 40, ip: n == 1 ? "192.168.50.31" : "192.168.50.\(40 + n)",
                      name: n == 1 ? "CAM-ENTREPOT-01" : "CAM-QUAI-0\(n)", vendor: "Hikvision")
            case 9:
                port.description = "Barrière levante · erreurs CRC"
                port.nativeVLAN = "vlan30"
                port.nativeVLANID = 30
                port.speedMbps = 100
                port.duplex = "half"
                place(synth(hid, 9), "FSW-QUAI", n, vlan: 30, ip: "10.182.130.41", name: "BARRIERE-QUAI", vendor: "HID Global")
            case 11, 12:
                port.description = "Point d’accès quai \(n - 10)"
                port.nativeVLAN = "vlan20"
                port.nativeVLANID = 20
                port.poeState = "Delivering Power"
                port.poePowerW = 12.1
                port.poeClass = 4
                place(synth(fortiAP, 600 + n), "FSW-QUAI", n, vlan: 20, ip: "10.182.120.\(20 + n)", name: "FAP-QUAI-0\(n - 10)", vendor: "Fortinet")
            case 15, 16:
                port.description = "Interphone quai \(n - 14)"
                port.nativeVLAN = "vlan30"
                port.nativeVLANID = 30
                port.poeState = "Delivering Power"
                port.poePowerW = 3.4
                port.poeClass = 1
                place(synth(hid, 600 + n), "FSW-QUAI", n, vlan: 30, ip: nil, name: nil)
            default:
                break
            }
            if !port.linkUp! {
                port.rxBytes = 0
                port.txBytes = 0
                port.description = (port.description ?? "") + " · libre"
            }
            quai.append(port)
        }
        quai.append(FortiSwitchPort(name: "port25", number: 25, linkUp: true, adminUp: true, speedMbps: 10_000, duplex: "full",
                                    nativeVLAN: "_default", nativeVLANID: 1, description: "ISL vers FSW-ENTREPOT (port51)",
                                    isISL: true, peerName: "FSW-ENTREPOT", rxBytes: 910_000_000_000, txBytes: 640_000_000_000, rxErrors: 0))
        for n in 26...28 {
            quai.append(FortiSwitchPort(name: "port\(n)", number: n, linkUp: false, adminUp: true, nativeVLAN: "_default", nativeVLANID: 1,
                                        description: "SFP+ libre"))
        }

        // ---- FSW-SERVEURS : FS-108F, salle des serveurs ----
        var serveurs: [FortiSwitchPort] = []
        for n in 1...8 {
            var port = FortiSwitchPort(name: "port\(n)", number: n, linkUp: n <= 5, adminUp: true, speedMbps: n <= 5 ? 1000 : nil, duplex: "full",
                                       nativeVLAN: "vlan100", nativeVLANID: 100, description: "Baie B · U\(String(format: "%02d", 2 * n + 10))",
                                       rxBytes: UInt64(n * 310 + 90) * 1_000_000_000, txBytes: UInt64(n * 270 + 60) * 1_000_000_000, rxErrors: 0)
            switch n {
            case 1:
                port.description = "SRV-BACKUP · sauvegardes"
                place(backupMAC, "FSW-SERVEURS", n, vlan: 100, ip: "10.10.0.31", name: "SRV-BACKUP", vendor: "VMware")
            case 2:
                port.description = "Hyperviseur ESX-02 · vmnic0"
                place(synth(dell, 700), "FSW-SERVEURS", n, vlan: 100, ip: "10.10.0.21", name: "ESX-02", vendor: "Dell")
            case 3:
                port.description = "NAS stockage"
                place(synth(dell, 701), "FSW-SERVEURS", n, vlan: 100, ip: "10.10.0.40", name: "NAS-01", vendor: "Synology")
            case 4:
                port.description = "iDRAC ESX-02"
                place(synth(dell, 702), "FSW-SERVEURS", n, vlan: 100, ip: nil, name: nil)
            case 5:
                port.description = "Onduleur baie B"
                place(synth(dell, 703), "FSW-SERVEURS", n, vlan: 100, ip: "10.10.0.45", name: "UPS-BAIE-B", vendor: "APC")
            default:
                port.rxBytes = 0
                port.txBytes = 0
                port.description = "Libre"
            }
            serveurs.append(port)
        }
        serveurs.append(FortiSwitchPort(name: "port9", number: 9, linkUp: false, adminUp: true, nativeVLAN: "_default", nativeVLANID: 1,
                                        description: "SFP libre"))
        serveurs.append(FortiSwitchPort(name: "port10", number: 10, linkUp: true, adminUp: true, speedMbps: 1000, duplex: "full",
                                        nativeVLAN: "_default", nativeVLANID: 1, description: "ISL vers FSW-ENTREPOT (port52)",
                                        isISL: true, peerName: "FSW-ENTREPOT", rxBytes: 530_000_000_000, txBytes: 1_210_000_000_000, rxErrors: 0))

        let switches = [
            FortiManagedSwitch(switchID: "FSW-ENTREPOT", serial: "S248EPTF21000123", name: "FSW-ENTREPOT", model: "FS-248E-POE",
                               osVersion: "S248EP-v7.2.5-build0453,230920 (GA)", connected: true, state: "Authorized",
                               fortilinkIP: IPv4Address("10.255.1.2"), description: "Entrepôt · baie A", poeBudgetW: 370, ports: entrepot),
            FortiManagedSwitch(switchID: "FSW-QUAI", serial: "S124FPTF22000456", name: "FSW-QUAI", model: "FS-124F-POE",
                               osVersion: "S124FP-v7.2.5-build0453,230920 (GA)", connected: true, state: "Authorized",
                               fortilinkIP: IPv4Address("10.255.1.3"), description: "Quai de chargement", poeBudgetW: 185, ports: quai),
            FortiManagedSwitch(switchID: "FSW-SERVEURS", serial: "S108FFTV21000789", name: "FSW-SERVEURS", model: "FS-108F",
                               osVersion: "S108FF-v7.2.5-build0453,230920 (GA)", connected: true, state: "Authorized",
                               fortilinkIP: IPv4Address("10.255.1.4"), description: "Salle serveurs · baie B", ports: serveurs),
        ]
        let arp = dhcp.map { FortiARPEntry(ip: $0.ip, mac: $0.mac, interface: $0.interface) }
        var report = FortiGateReport(system: system, switches: switches, detected: detected, arp: arp, dhcp: dhcp, userDevices: users,
                                     readAt: now.addingTimeInterval(-40))
        report.calls = demoCalls(report)
        return report
    }

    /// Appels de la lecture fictive (réponses brutes courtes, sans jeton).
    private static func demoCalls(_ report: FortiGateReport) -> [FortiCallRecord] {
        [FortiCallRecord(path: FortiPaths.systemStatus, status: 200, outcome: .ok,
                         body: #"{"results":{"model_name":"FortiGate","model_number":"60F","hostname":"FGT-SIEGE"},"version":"v7.2.8","build":1639,"status":"success"}"#, items: 1),
         FortiCallRecord(path: FortiPaths.switchStatus, status: 200, outcome: .ok, body: "(démonstration)", items: report.switches.count),
         FortiCallRecord(path: FortiPaths.switchConfig, status: 200, outcome: .ok, body: "(démonstration)", items: report.switches.count),
         FortiCallRecord(path: FortiPaths.portStats, status: 200, outcome: .ok, body: "(démonstration)", items: report.switches.count),
         FortiCallRecord(path: FortiPaths.poe, status: 404, outcome: .absent,
                         message: FortiGateError.notFound(path: FortiPaths.poe).errorDescription ?? "", body: #"{"status":"error","http_status":404}"#),
         FortiCallRecord(path: FortiPaths.detectedDevice, status: 200, outcome: .ok, body: "(démonstration)", items: report.detected.count),
         FortiCallRecord(path: FortiPaths.arp, status: 200, outcome: .ok, body: "(démonstration)", items: report.arp.count),
         FortiCallRecord(path: FortiPaths.dhcp, status: 200, outcome: .ok, body: "(démonstration)", items: report.dhcp.count),
         FortiCallRecord(path: FortiPaths.userDevices, status: 200, outcome: .ok, body: "(démonstration)", items: report.userDevices.count)]
    }
}
