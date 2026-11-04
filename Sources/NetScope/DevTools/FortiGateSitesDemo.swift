import Foundation
import NetScopeCore

/// Démonstration de la note 25 : quatre sites fictifs, chacun avec sa FortiGate. Aucun accès réseau.
///
/// - Siège (10.182.122.1) : la FortiGate des autres écrans (FortiGateDemo), couvre les plages du
///   scan de démonstration ;
/// - Entrepôt Laval (10.20.0.1) : lue, deux FortiSwitch (dont un à la même adresse FortiLink que
///   le Siège) ;
/// - Bureau Québec (10.30.0.1) : jeton manquant ;
/// - Usine Drummondville (10.40.0.1) : refusée (HTTP 403, hôte de confiance).
///
/// Captures : NETSCOPE_FORTIGATE_MULTI=1 ajoute une plage de Laval aux plages scannées (deux
/// FortiGate choisies) ; NETSCOPE_FORTIGATE_FEUILLE=siege|nouveau montre la feuille d'édition.
@MainActor
enum FortiGateSitesDemo {
    static let siegeID = UUID(uuidString: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000001")!
    static let lavalID = UUID(uuidString: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000002")!
    static let quebecID = UUID(uuidString: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000003")!
    static let drummondID = UUID(uuidString: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000004")!

    struct Content {
        var controllers: [FortiGateController]
        var tokenIDs: Set<UUID>
        var runtime: [UUID: FortiGateStore.Runtime]
        var selection: FortiControllerSelection
        var sites: [FortiSiteReport]
    }

    /// Capture avec deux sites scannés.
    static var multiSite: Bool {
        CommandLine.arguments.contains("--snapshot") && ProcessInfo.processInfo.environment["NETSCOPE_FORTIGATE_MULTI"] == "1"
    }

    /// Plages scannées de la démonstration (et celle de Laval pour la capture à deux sites).
    static var scannedRanges: [IPRange] {
        DemoData.ranges.compactMap { try? $0.parsed() }
    }

    static func controllers(now: Date = Date()) -> [FortiGateController] {
        let siegeReport = FortiGateDemo.report(now: now)
        let lavalReport = laval(now: now)
        return [
            FortiGateController(id: siegeID, site: "Siège", host: "10.182.122.1", vdom: "",
                                ranges: ["10.182.0.0/16", "192.168.50.0/24", "10.10.0.0/24"],
                                pinnedFingerprint: FortiGateDemo.config.pinnedFingerprint,
                                lastStatus: .success(siegeReport, date: now.addingTimeInterval(-40))),
            FortiGateController(id: lavalID, site: "Entrepôt Laval", host: "10.20.0.1", vdom: "root",
                                ranges: ["10.20.0.0/16"],
                                pinnedFingerprint: "8C:21:6F:0A:93:D4:57:B2:1E:C8:44:9A:70:3B:E5:12:D6:08:AF:61:2C:95:7E:43:B1:0D:F2:68:9E:35:C7:14",
                                lastStatus: .success(lavalReport, date: now.addingTimeInterval(-3 * 60))),
            FortiGateController(id: quebecID, site: "Bureau Québec", host: "10.30.0.1", port: 10443,
                                ranges: ["10.30.0.0/16", "10.40.12.0/24"],
                                lastStatus: FortiControllerStatus(kind: .missingToken, message: "Jeton absent.", date: now.addingTimeInterval(-26 * 60))),
            FortiGateController(id: drummondID, site: "Usine Drummondville", host: "10.40.0.1", vdom: "usine",
                                ranges: ["10.40.0.0/16"],
                                pinnedFingerprint: "51:E7:0C:A8:3D:96:F2:4B:18:C3:7A:05:E9:62:BD:30:4F:A1:86:D7:2E:59:0B:C4:93:6A:F8:17:5D:E2:08:BC",
                                lastStatus: FortiControllerStatus(kind: .error, message: drummondError, date: now.addingTimeInterval(-12 * 60))),
        ]
    }

    static var drummondError: String {
        FortiGateError.forbidden(path: FortiPaths.switchStatus).errorDescription ?? "Accès refusé (HTTP 403)."
    }

    static func make(now: Date = Date()) -> Content {
        let list = controllers(now: now)
        let siege = FortiGateDemo.report(now: now)
        var lavalReport = laval(now: now)
        lavalReport.readAt = now.addingTimeInterval(-3 * 60)
        var runtime: [UUID: FortiGateStore.Runtime] = [:]
        runtime[siegeID] = FortiGateStore.Runtime(report: siege, calls: siege.calls, lastAttempt: siege.readAt)
        runtime[lavalID] = FortiGateStore.Runtime(report: lavalReport, calls: lavalReport.calls, lastAttempt: lavalReport.readAt)
        runtime[quebecID] = FortiGateStore.Runtime(error: "Jeton absent\u{00A0}: enregistrez-le dans Réglages › Switchs › Contrôleurs FortiGate.")
        runtime[drummondID] = FortiGateStore.Runtime(
            error: drummondError,
            calls: [FortiCallRecord(path: FortiPaths.systemStatus, status: 200, outcome: .ok, body: "(démonstration)", items: 1),
                    FortiCallRecord(path: FortiPaths.switchStatus, status: 403, outcome: .refused, message: drummondError,
                                    body: #"{"status":"error","http_status":403}"#)],
            lastAttempt: now.addingTimeInterval(-12 * 60))
        let selection = FortiControllerSelector.select(list, scanned: scannedRanges, macAddress: DemoData.interface.address)
        return Content(controllers: list, tokenIDs: [siegeID, lavalID, drummondID], runtime: runtime, selection: selection,
                       sites: sites(for: selection, now: now))
    }

    /// Lectures réussies des FortiGate choisies (Siège et Laval seulement : les deux autres ne
    /// répondent pas dans la démonstration).
    static func sites(for selection: FortiControllerSelection, now: Date = Date()) -> [FortiSiteReport] {
        let list = controllers(now: now)
        return selection.controllerIDs.compactMap { id -> FortiSiteReport? in
            guard let c = list.first(where: { $0.id == id }) else { return nil }
            switch id {
            case siegeID: return FortiSiteReport(controllerID: id, site: c.displayName, report: FortiGateDemo.report(now: now), coveredRanges: c.coveredRanges)
            case lavalID: return FortiSiteReport(controllerID: id, site: c.displayName, report: laval(now: now), coveredRanges: c.coveredRanges)
            default: return nil
            }
        }
    }

    /// Sites de la démonstration pour « Switchs et ports » (sans passer par FortiGateStore).
    static func selectedSites() -> [FortiSiteReport] {
        sites(for: FortiControllerSelector.select(controllers(), scanned: scannedRanges, macAddress: DemoData.interface.address))
    }

    /// « Tester » de la feuille d'édition en démonstration.
    static func testOutcome(for draft: FortiGateController) -> FortiGateStore.TestOutcome {
        let now = Date()
        switch draft.id {
        case siegeID:
            return FortiGateStore.TestOutcome(report: FortiGateDemo.report(now: now), interfaces: siegeInterfaces, calls: FortiGateDemo.report(now: now).calls, date: now)
        case lavalID:
            return FortiGateStore.TestOutcome(report: laval(now: now), interfaces: lavalInterfaces, calls: laval(now: now).calls, date: now)
        case quebecID:
            return FortiGateStore.TestOutcome(error: FortiGateError.missingToken.errorDescription, date: now)
        case drummondID:
            return FortiGateStore.TestOutcome(error: drummondError, date: now)
        default:
            return FortiGateStore.TestOutcome(error: "Démonstration\u{00A0}: aucune connexion n’est faite à cette adresse.", date: now)
        }
    }

    static var siegeInterfaces: [FortiInterfaceSubnet] {
        func s(_ name: String, _ alias: String?, _ ip: String, _ prefix: Int, fortilink: Bool = false, role: String? = "lan") -> FortiInterfaceSubnet {
            let address = IPv4Address(ip)!
            return FortiInterfaceSubnet(name: name, alias: alias, address: address, subnet: Subnet(address: address, prefix: prefix),
                                        isFortiLink: fortilink, role: role, type: "vlan")
        }
        return [s("wan1", nil, "198.51.100.18", 29, role: "wan"),
                s("internal", "Bureau", "10.182.122.1", 24),
                s("vlan20", "Wi-Fi", "10.182.120.1", 24),
                s("vlan30", "Quais", "10.182.130.1", 24),
                s("vlan40", "Caméras", "192.168.50.1", 24),
                s("vlan100", "Serveurs", "10.10.0.1", 24),
                s("fortilink", nil, "10.255.1.1", 24, fortilink: true, role: nil)]
    }

    static var lavalInterfaces: [FortiInterfaceSubnet] {
        let pairs: [(String, String?, String, Int, Bool)] = [("internal", "Bureaux", "10.20.0.1", 24, false), ("vlan10", "Entrepôt", "10.20.10.1", 24, false),
                                                             ("vlan40", "Caméras", "10.20.40.1", 24, false), ("fortilink", nil, "10.255.1.1", 24, true)]
        return pairs.map { name, alias, ip, prefix, fortilink in
            let address = IPv4Address(ip)!
            return FortiInterfaceSubnet(name: name, alias: alias, address: address, subnet: Subnet(address: address, prefix: prefix),
                                        isFortiLink: fortilink, role: fortilink ? nil : "lan", type: "vlan")
        }
    }

    /// FortiGate-40F de l'entrepôt de Laval : deux FortiSwitch, quelques appareils.
    static func laval(now: Date = Date()) -> FortiGateReport {
        let system = FortiGateSystem(hostname: "FGT-LAVAL", model: "FortiGate-40F", serial: "FGT40FTK23001802", version: "v7.2.8", build: 1639, vdom: "root")
        var detected: [FortiDetectedDevice] = []
        var dhcp: [FortiDHCPLease] = []
        func mac(_ n: Int) -> MACAddress { MACAddress(bytes: [0x00, 0x07, 0x4D, 0x20, UInt8(n / 256), UInt8(n % 256)]) }
        var main: [FortiSwitchPort] = []
        for n in 1...28 {
            let up = n <= 14 || n == 25
            var port = FortiSwitchPort(name: "port\(n)", number: n, linkUp: up, adminUp: true, speedMbps: up ? 1000 : nil, duplex: "full",
                                       nativeVLAN: n <= 6 ? "vlan10" : "_default", nativeVLANID: n <= 6 ? 10 : 1,
                                       description: n <= 6 ? "Quai L-\(n)" : nil, poeCapable: n <= 24, poeEnabled: n <= 24,
                                       poeState: n <= 6 ? "Delivering Power" : "Searching", poePowerW: n <= 6 ? 4.2 : 0)
            if n == 25 {
                port.isFortiLink = true
                port.peerName = "FGT-LAVAL"
                port.speedMbps = 10_000
            }
            if up, n != 25 {
                let m = mac(n)
                detected.append(FortiDetectedDevice(mac: m, switchID: "FSW-LAVAL-01", portName: "port\(n)", vlan: n <= 6 ? 10 : 1,
                                                    lastSeen: now.addingTimeInterval(-30)))
                if let ip = IPv4Address("10.20.\(n <= 6 ? 10 : 0).\(40 + n)") {
                    dhcp.append(FortiDHCPLease(ip: ip, mac: m, hostname: n <= 6 ? "LECTEUR-LAV-0\(n)" : "POSTE-LAV-\(n)",
                                               interface: n <= 6 ? "vlan10" : "internal", expires: now.addingTimeInterval(4 * 3600)))
                }
            }
            main.append(port)
        }
        var small: [FortiSwitchPort] = []
        for n in 1...10 {
            let up = n <= 4 || n == 9
            var port = FortiSwitchPort(name: "port\(n)", number: n, linkUp: up, adminUp: true, speedMbps: up ? 1000 : nil, duplex: "full",
                                       nativeVLAN: n <= 4 ? "vlan40" : "_default", nativeVLANID: n <= 4 ? 40 : 1,
                                       description: n <= 4 ? "Caméra quai \(n)" : nil)
            if n == 9 {
                port.isISL = true
                port.peerName = "FSW-LAVAL-01"
            }
            if n <= 4 {
                let m = MACAddress(bytes: [0xBC, 0xAD, 0x28, 0x20, 0x40, UInt8(n)])
                detected.append(FortiDetectedDevice(mac: m, switchID: "FSW-LAVAL-02", portName: "port\(n)", vlan: 40, lastSeen: now.addingTimeInterval(-50)))
                if let ip = IPv4Address("10.20.40.\(20 + n)") {
                    dhcp.append(FortiDHCPLease(ip: ip, mac: m, hostname: "CAM-LAV-0\(n)", interface: "vlan40", expires: now.addingTimeInterval(4 * 3600)))
                }
            }
            small.append(port)
        }
        let switches = [
            FortiManagedSwitch(switchID: "FSW-LAVAL-01", serial: "S124FPTF23001190", name: "FSW-LAVAL-01", model: "FS-124F-POE",
                               osVersion: "S124FP-v7.2.5-build0453,230920 (GA)", connected: true, state: "Authorized",
                               fortilinkIP: IPv4Address("10.255.1.2"), description: "Entrepôt Laval · baie principale", poeBudgetW: 185, ports: main),
            FortiManagedSwitch(switchID: "FSW-LAVAL-02", serial: "S108FFTV23000417", name: "FSW-LAVAL-02", model: "FS-108F",
                               osVersion: "S108FF-v7.2.5-build0453,230920 (GA)", connected: true, state: "Authorized",
                               fortilinkIP: IPv4Address("10.255.1.3"), description: "Quai de Laval", ports: small),
        ]
        let arp = dhcp.map { FortiARPEntry(ip: $0.ip, mac: $0.mac, interface: $0.interface) }
        var report = FortiGateReport(system: system, switches: switches, detected: detected, arp: arp, dhcp: dhcp, readAt: now.addingTimeInterval(-3 * 60))
        report.calls = [FortiCallRecord(path: FortiPaths.systemStatus, status: 200, outcome: .ok, body: "(démonstration)", items: 1),
                        FortiCallRecord(path: FortiPaths.switchStatus, status: 200, outcome: .ok, body: "(démonstration)", items: switches.count),
                        FortiCallRecord(path: FortiPaths.detectedDevice, status: 200, outcome: .ok, body: "(démonstration)", items: detected.count)]
        return report
    }
}
