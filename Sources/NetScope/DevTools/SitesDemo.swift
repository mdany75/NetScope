import Foundation
import NetScopeCore

/// Démonstration de la note 28 : sites fictifs cohérents avec les FortiGate de démonstration
/// (FortiGateSitesDemo). Aucun accès réseau, aucune vraie donnée de client.
///
/// - Siège : les plages et l'inventaire de démonstration des autres écrans, la FortiGate du Siège,
///   le switch SNMP SW-CORE-01 associé ;
/// - Entrepôt Laval : petit inventaire différent (lecteurs de quai, postes, caméras), sa FortiGate ;
/// - Bureau Québec : jamais scanné, sa FortiGate (jeton manquant) ; plage 192.168.1.0/24 « Invités » ;
/// - Usine Drummondville : jamais scanné, sa FortiGate (accès refusé) ;
/// - Clinique Exemple : client fictif sans FortiGate, sur 192.168.1.0/24 comme Bureau Québec (le
///   site se choisit par la passerelle, jamais par l'IP seule).
///
/// Un switch SNMP sans site (172.16.9.2, hors des plages) est masqué dans « Switchs et ports ».
/// Captures : NETSCOPE_SITE=laval (début du nom) choisit le site actif.
@MainActor
enum SitesDemo {
    static let siegeID = UUID(uuidString: "5A7E0028-0001-4C1E-9A11-00000000A001")!
    static let lavalID = UUID(uuidString: "5A7E0028-0002-4C1E-9A11-00000000A002")!
    static let quebecID = UUID(uuidString: "5A7E0028-0003-4C1E-9A11-00000000A003")!
    static let drummondID = UUID(uuidString: "5A7E0028-0004-4C1E-9A11-00000000A004")!
    static let cliniqueID = UUID(uuidString: "5A7E0028-0005-4C1E-9A11-00000000A005")!

    static var siegeKey: String { SiteFiles.key(for: siegeID) }
    static var lavalKey: String { SiteFiles.key(for: lavalID) }

    /// MAC de la passerelle du Siège (celle de DemoData) : « Détecter mon site » reconnaît le Siège.
    static let observedGatewayMAC = MACAddress("04:D5:90:3A:7B:11")!

    static func list(now: Date = Date()) -> SiteList {
        let created = now.addingTimeInterval(-120 * 86_400)
        let siege = Site(id: siegeID, name: "Siège", notes: "Bureaux, entrepôt et salle des serveurs.",
                         ranges: DemoData.ranges, fortiGateIDs: [FortiGateSitesDemo.siegeID], switchHosts: ["10.182.122.2"],
                         hints: SiteHints(gatewayMACs: [observedGatewayMAC], fortiGateSerials: ["FGT60FTK22004711"],
                                          fortiGateHostnames: ["FGT-SIEGE"], ssid: "Bureau-Corp"),
                         lastScan: now.addingTimeInterval(-60), inventoryCount: nil, created: created)
        let laval = Site(id: lavalID, name: "Entrepôt Laval", notes: "Quais de chargement ; caméras sur le VLAN 40.",
                         ranges: [ScanRangeConfig(text: "10.20.0.0/24", label: "Bureaux", vlan: 1),
                                  ScanRangeConfig(text: "10.20.10.0/24", label: "Quais", vlan: 10),
                                  ScanRangeConfig(text: "10.20.40.0/24", label: "Caméras", vlan: 40)],
                         fortiGateIDs: [FortiGateSitesDemo.lavalID],
                         hints: SiteHints(gatewayMACs: [MACAddress("00:09:0F:AA:10:01")!], fortiGateSerials: ["FGT40FTK23001802"],
                                          fortiGateHostnames: ["FGT-LAVAL"]),
                         lastScan: now.addingTimeInterval(-2 * 86_400 - 3_600), inventoryCount: lavalDevices(now: now).count,
                         created: created.addingTimeInterval(86_400))
        let quebec = Site(id: quebecID, name: "Bureau Québec",
                          ranges: [ScanRangeConfig(text: "10.30.0.0/24", label: "Bureau", vlan: 1),
                                   ScanRangeConfig(text: "192.168.1.0/24", label: "Invités", vlan: 99)],
                          fortiGateIDs: [FortiGateSitesDemo.quebecID], created: created.addingTimeInterval(2 * 86_400))
        let drummond = Site(id: drummondID, name: "Usine Drummondville",
                            ranges: [ScanRangeConfig(text: "10.40.0.0/24", label: "Production", vlan: 1),
                                     ScanRangeConfig(text: "10.40.12.0/24", label: "Automates", vlan: 12)],
                            fortiGateIDs: [FortiGateSitesDemo.drummondID], created: created.addingTimeInterval(3 * 86_400))
        let clinique = Site(id: cliniqueID, name: "Clinique Exemple", notes: "Client fictif de démonstration.",
                            ranges: [ScanRangeConfig(text: "192.168.1.0/24", label: "Postes", vlan: 1),
                                     ScanRangeConfig(text: "192.168.20.0/24", label: "Imagerie", vlan: 20)],
                            hints: SiteHints(ssid: "Clinique-Personnel"), created: created.addingTimeInterval(40 * 86_400))
        return SiteList(sites: [siege, laval, quebec, drummond, clinique], activeID: siegeID)
    }

    /// Résultats gardés des autres sites (le Siège a ceux de DemoData, déjà dans AppState).
    static func results(now: Date = Date()) -> [String: SiteResults] {
        let devices = lavalDevices(now: now)
        let finished = now.addingTimeInterval(-2 * 86_400 - 3_600)
        let laval = SiteResults(devices: devices, newIDs: ["10.20.40.24"],
                                lastScanRanges: ["10.20.0.0/24", "10.20.10.0/24", "10.20.40.0/24"],
                                startedAt: finished.addingTimeInterval(-41), finishedAt: finished, portLabel: "Rapide")
        return [lavalKey: laval]
    }

    /// Inventaire d'un site la première fois qu'on l'ouvre en démonstration (Laval seulement).
    static func inventory(for key: String, now: Date = Date()) -> InventoryStore? {
        guard key == lavalKey else { return nil }
        var store = InventoryStore()
        let devices = lavalDevices(now: now)
        // Premier scan il y a trois semaines (sans la dernière caméra), puis celui d'avant-hier.
        let first = now.addingTimeInterval(-21 * 86_400)
        store.merge(devices.filter { $0.ip.description != "10.20.40.24" }.map { device in
            var copy = device
            copy.firstSeen = first
            copy.lastSeen = first
            return copy
        }, at: first)
        store.merge(devices, at: now.addingTimeInterval(-2 * 86_400 - 3_600))
        return store
    }

    /// Appareils de l'entrepôt de Laval (mêmes MAC et noms que la FortiGate de démonstration).
    static func lavalDevices(now: Date = Date()) -> [Device] {
        let seen = now.addingTimeInterval(-2 * 86_400 - 3_600)
        func mac(_ n: Int) -> MACAddress { MACAddress(bytes: [0x00, 0x07, 0x4D, 0x20, UInt8(n / 256), UInt8(n % 256)]) }
        var list: [Device] = [
            Device(ip: IPv4Address("10.20.0.1")!, mac: MACAddress("00:09:0F:AA:10:01")!, vendor: "Fortinet", hostname: "FGT-LAVAL",
                   latencyMs: 0.9, openPorts: [22, 443], vlan: 1, firstSeen: seen, lastSeen: seen, rangeLabel: "Bureaux",
                   deviceType: .routeur),
        ]
        for n in 1...4 {
            list.append(Device(ip: IPv4Address("10.20.10.\(40 + n)")!, mac: mac(n), vendor: "Zebra Technologies",
                               hostname: "LECTEUR-LAV-0\(n)", latencyMs: 3.2 + Double(n) / 10, switchName: "FSW-LAVAL-01",
                               switchPort: "port\(n)", vlan: 10, firstSeen: seen, lastSeen: seen, rangeLabel: "Quais",
                               deviceType: .inconnu))
        }
        for n in 7...10 {
            list.append(Device(ip: IPv4Address("10.20.0.\(40 + n)")!, mac: mac(n), vendor: "Dell", hostname: "POSTE-LAV-\(n)",
                               latencyMs: 1.8, openPorts: [135, 445], switchName: "FSW-LAVAL-01", switchPort: "port\(n)", vlan: 1,
                               firstSeen: seen, lastSeen: seen, rangeLabel: "Bureaux", deviceType: .poste))
        }
        for n in 1...4 {
            list.append(Device(ip: IPv4Address("10.20.40.\(20 + n)")!, mac: MACAddress(bytes: [0xBC, 0xAD, 0x28, 0x20, 0x40, UInt8(n)]),
                               vendor: "Hikvision", hostname: "CAM-LAV-0\(n)", isOnline: n != 3, latencyMs: n == 3 ? nil : 2.4,
                               openPorts: [80, 554], switchName: "FSW-LAVAL-02", switchPort: "port\(n)", vlan: 40,
                               firstSeen: seen, lastSeen: seen, rangeLabel: "Caméras", deviceType: .camera))
        }
        return list
    }

    /// Ancien switch d'un laboratoire, sans site et hors des plages : masqué dans « Switchs et ports ».
    static func unassignedSwitch(now: Date) -> SNMPSwitchSnapshot {
        let interfaces = (1...8).map { n in
            SNMPInterface(index: n, name: "\(n)", descr: "\(n)", alias: n == 1 ? "Uplink" : "", operStatus: n <= 3 ? .up : .down,
                          speedMbps: 1000)
        }
        return SNMPSwitchSnapshot(
            host: IPv4Address("172.16.9.2")!,
            system: SNMPSystemInfo(name: "SW-LAB-ANCIEN", descr: "HP J9773A 2530-24G-PoEP Switch, revision YA.16.10.0009",
                                   objectID: "1.3.6.1.4.1.11.2.3.7.11.153", location: "Ancien laboratoire"),
            interfaces: interfaces, polledAt: now.addingTimeInterval(-6 * 86_400))
    }
}
