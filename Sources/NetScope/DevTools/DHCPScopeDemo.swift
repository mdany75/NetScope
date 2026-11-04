import Foundation
import NetScopeCore

/// Étendues DHCP fictives (note 37), lues « sur » les FortiGate de démonstration. Aucun accès réseau.
///
/// - Siège : Bureau (60 %), VLAN 20 voix pleine à 96 % (4 adresses libres), Quais, Caméras (deux
///   plages), Invités à 85 % (bail de 2 h), Serveurs désactivée ; les baux du Bureau sont ceux des
///   appareils du scan de démonstration (mêmes MAC que DemoData) ;
/// - Entrepôt Laval : deux étendues sous les seuils.
///
/// Captures : NETSCOPE_OUTIL_DEMO=dhcpscopes ouvre l'outil ; NETSCOPE_DHCP_ETENDUE=vlan60 choisit
/// l'étendue détaillée (VLAN 20 par défaut) ; NETSCOPE_RAPPORT_DHCP=1 coche la section du rapport.
@MainActor
enum DHCPScopeDemo {
    /// Étendue détaillée à l'ouverture des captures.
    static var initialScopeInterface: String {
        ProcessInfo.processInfo.environment["NETSCOPE_DHCP_ETENDUE"] ?? "vlan20"
    }

    /// Lectures des FortiGate choisies (Siège et Laval seulement répondent).
    static func sites(for selection: FortiControllerSelection, now: Date = Date()) -> [DHCPScopeSiteReport] {
        selection.picks.compactMap { pick -> DHCPScopeSiteReport? in
            switch pick.controllerID {
            case FortiGateSitesDemo.siegeID: return DHCPScopeSiteReport(controllerID: pick.controllerID, site: pick.site, report: siege(now: now))
            case FortiGateSitesDemo.lavalID: return DHCPScopeSiteReport(controllerID: pick.controllerID, site: pick.site, report: laval(now: now))
            default: return nil
            }
        }
    }

    /// Sélection de la démonstration (comme FortiGateSitesDemo.make).
    static func initialSelection(now: Date = Date()) -> FortiControllerSelection {
        FortiControllerSelector.select(FortiGateSitesDemo.controllers(now: now), scanned: FortiGateSitesDemo.scannedRanges,
                                       macAddress: DemoData.interface.address)
    }

    // MARK: Fabrication

    private static func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }
    private static func range(_ a: String, _ b: String) -> DHCPAddressRange { DHCPAddressRange(start: ip(a), end: ip(b)) }
    private static func mac(_ prefix: [UInt8], _ n: Int) -> MACAddress {
        MACAddress(bytes: prefix + [UInt8((n * 7 + 33) % 256), UInt8((n * 11 + 3) % 256), UInt8((n * 17 + 9) % 256)])
    }
    private static let dell: [UInt8] = [0xB0, 0x7B, 0x25], lenovo: [UInt8] = [0x8C, 0x16, 0x45], yealink: [UInt8] = [0x80, 0x5E, 0x0C]
    private static let cisco: [UInt8] = [0x00, 0x1E, 0x7A], honeywell: [UInt8] = [0x00, 0x10, 0x20], zebra: [UInt8] = [0x00, 0x07, 0x4D]
    private static let hik: [UInt8] = [0xBC, 0xAD, 0x28], apple: [UInt8] = [0xF0, 0x18, 0x98], samsung: [UInt8] = [0x5C, 0x0A, 0x5B]
    private static let random: [UInt8] = [0xDA, 0x4E, 0x91]

    private static func calls(_ report: DHCPScopeReadReport) -> [FortiCallRecord] {
        [FortiCallRecord(path: DHCPScopePaths.servers, status: 200, outcome: .ok, body: "(démonstration)", items: report.servers.count),
         FortiCallRecord(path: DHCPScopePaths.leases, status: 200, outcome: .ok, body: "(démonstration)", items: report.leases.count),
         FortiCallRecord(path: DHCPScopePaths.interfaces + "?format=" + DHCPScopePaths.interfaceFields, status: 200, outcome: .ok,
                         body: "(démonstration)", items: report.interfaces.count)]
    }

    // MARK: Siège

    static func siege(now: Date = Date()) -> DHCPScopeReadReport {
        var leases: [DHCPLeaseEntry] = []
        func lease(_ address: String, _ m: MACAddress, _ name: String?, _ intf: String, server: Int, minutes: Int, reserved: Bool = false,
                   status: String = "leased") {
            leases.append(DHCPLeaseEntry(ip: ip(address), mac: m, hostname: name, interface: intf,
                                         expires: now.addingTimeInterval(TimeInterval(minutes * 60)), reserved: reserved,
                                         serverID: server, status: status))
        }

        // 1. Bureau (internal) : appareils du scan de démonstration, puis des postes.
        let bureau = DHCPServerConfig(
            id: 1, interface: "internal", ranges: [range("10.182.122.100", "10.182.122.199")],
            exclusions: [range("10.182.122.120", "10.182.122.129")],
            reservations: [DHCPReservation(ip: ip("10.182.122.102"), mac: MACAddress("70:4C:A5:1E:22:9A"), description: "Borne Wi-Fi accueil", action: "reserved"),
                           DHCPReservation(ip: ip("10.182.122.106"), mac: MACAddress("90:AC:3F:0D:18:76"), description: "Affichage hall", action: "reserved"),
                           DHCPReservation(ip: ip("10.182.122.111"), mac: MACAddress("94:DD:F8:18:15:7D"), description: "Imprimante accueil", action: "reserved"),
                           DHCPReservation(ip: ip("10.182.122.20"), mac: MACAddress("00:1B:C5:0A:12:F3"), description: "Horloge murale NTP", action: "reserved")],
            leaseTime: 604_800, gateway: ip("10.182.122.1"), netmask: ip("255.255.255.0"), serverType: "regular")
        lease("10.182.122.100", MACAddress("3A:1F:C7:02:9B:E4")!, "ca2032249c778fc96008b9df7aa447c9", "internal", server: 1, minutes: 6 * 1440)
        lease("10.182.122.102", MACAddress("70:4C:A5:1E:22:9A")!, "FortiAP-231F", "internal", server: 1, minutes: 5 * 1440, reserved: true)
        lease("10.182.122.106", MACAddress("90:AC:3F:0D:18:76")!, "BrightSign-D1E876001191", "internal", server: 1, minutes: 4 * 1440, reserved: true)
        lease("10.182.122.111", MACAddress("94:DD:F8:18:15:7D")!, "BRN94DDF818157D", "internal", server: 1, minutes: 3 * 1440, reserved: true)
        lease("10.182.122.113", MACAddress("8C:16:45:2B:9E:03")!, "PF4L8M20", "internal", server: 1, minutes: 2 * 1440)
        lease("10.182.122.117", MACAddress("B0:7B:25:44:A1:6C")!, "WKS346", "internal", server: 1, minutes: 6 * 1440 + 300)
        lease("10.182.122.133", MACAddress("D6:4E:81:7A:33:C0")!, "Android_89UM1WTN", "internal", server: 1, minutes: 42)
        lease("10.182.122.135", MACAddress("3C:22:FB:7E:05:B1")!, "Macmini-de-Dany", "internal", server: 1, minutes: 5 * 1440 + 90)
        // Poste de la réception éteint depuis 3 h : son bail a expiré (adresse libre).
        lease("10.182.122.146", MACAddress("B0:7B:25:44:9F:20")!, "WKS341", "internal", server: 1, minutes: -180, status: "expired")
        for n in 0..<46 {
            let address = "10.182.122.\(150 + n)"
            let portable = n % 3 == 0
            lease(address, mac(portable ? lenovo : dell, n), portable ? "PF4L\(String(format: "%02d", n))M2\(n % 10)" : "WKS\(300 + n)", "internal",
                  server: 1, minutes: 600 + (n * 211) % (7 * 1440))
        }

        // 2. VLAN 20 voix : 100 adresses, 4 réservations, 92 téléphones → 96 %, 4 libres.
        let voix = DHCPServerConfig(
            id: 2, interface: "vlan20", ranges: [range("10.182.120.100", "10.182.120.199")],
            reservations: [DHCPReservation(ip: ip("10.182.120.100"), mac: mac(yealink, 900), description: "Passerelle SIP accueil", action: "reserved"),
                           DHCPReservation(ip: ip("10.182.120.101"), mac: mac(yealink, 901), description: "Console de standard", action: "reserved"),
                           DHCPReservation(ip: ip("10.182.120.102"), mac: mac(cisco, 902), description: "Haut-parleur de pagination", action: "reserved"),
                           DHCPReservation(ip: ip("10.182.120.103"), mac: mac(cisco, 903), description: "Téléphone salle de conférence", action: "reserved")],
            leaseTime: 86_400, gateway: ip("10.182.120.1"), netmask: ip("255.255.255.0"), serverType: "regular")
        lease("10.182.120.100", mac(yealink, 900), "SIP-GW-ACCUEIL", "vlan20", server: 2, minutes: 900, reserved: true)
        lease("10.182.120.101", mac(yealink, 901), "Yealink-T58W-Standard", "vlan20", server: 2, minutes: 1100, reserved: true)
        for n in 0..<92 {
            let address = "10.182.120.\(104 + n)"
            let isCisco = n % 4 == 0
            let m = mac(isCisco ? cisco : yealink, n)
            let name = isCisco ? "SEP" + m.formatted(.upperColon).replacingOccurrences(of: ":", with: "") : "Yealink-T54W-\(String(format: "%03d", 200 + n))"
            lease(address, m, name, "vlan20", server: 2, minutes: 20 + (n * 53) % 1440)
        }

        // 3. VLAN 30 quais : lecteurs et imprimantes d'étiquettes.
        let quais = DHCPServerConfig(id: 3, interface: "vlan30", ranges: [range("10.182.130.50", "10.182.130.149")],
                                     leaseTime: 28_800, gateway: ip("10.182.130.1"), netmask: ip("255.255.255.0"), serverType: "regular")
        for n in 0..<41 {
            let lecteur = n % 3 != 0
            lease("10.182.130.\(50 + n)", mac(lecteur ? honeywell : zebra, n), lecteur ? "LECTEUR-QUAI-\(String(format: "%02d", n))" : "ZT411-\(String(format: "%02d", n))",
                  "vlan30", server: 3, minutes: 60 + (n * 37) % 480)
        }

        // 4. VLAN 40 caméras : deux plages (les caméras fixes sont hors plage).
        let cameras = DHCPServerConfig(id: 4, interface: "vlan40",
                                       ranges: [range("192.168.50.100", "192.168.50.149"), range("192.168.50.200", "192.168.50.229")],
                                       leaseTime: 604_800, gateway: ip("192.168.50.1"), netmask: ip("255.255.255.0"), serverType: "regular")
        for n in 0..<12 {
            let address = n < 8 ? "192.168.50.\(100 + n)" : "192.168.50.\(200 + n - 8)"
            lease(address, mac(hik, n), "DS-2CD2143G2-\(String(format: "%02d", n))", "vlan40", server: 4, minutes: 1440 + (n * 307) % (6 * 1440))
        }

        // 5. VLAN 60 invités : 200 adresses, bail de 2 h, 170 baux → 85 %.
        let invites = DHCPServerConfig(id: 5, interface: "vlan60", ranges: [range("10.182.140.20", "10.182.140.219")],
                                       leaseTime: 7200, gateway: ip("10.182.140.1"), netmask: ip("255.255.255.0"), serverType: "regular")
        lease("10.182.140.31", MACAddress("F2:6A:19:C4:0E:57")!, "iPhone-Reception", "vlan60", server: 5, minutes: 74)
        var guest = 0
        for n in 0..<200 where guest < 169 {
            let octet = 20 + n
            guard octet != 31, n % 7 != 6 || guest > 160 else { continue }
            guest += 1
            let kind = n % 4
            let m = kind == 0 ? mac(apple, n) : (kind == 1 ? mac(samsung, n) : mac(random, n))
            let name: String? = kind == 0 ? "iPhone-\(n)" : (kind == 1 ? "Galaxy-S23-\(n)" : (kind == 2 ? "DESKTOP-\(String(format: "%04X", n * 2_731 % 65_535))" : nil))
            lease("10.182.140.\(octet)", m, name, "vlan60", server: 5, minutes: 2 + (n * 37) % 118)
        }

        // 6. VLAN 100 serveurs : serveur DHCP désactivé (adresses fixes).
        let serveurs = DHCPServerConfig(id: 6, interface: "vlan100", enabled: false, ranges: [range("10.10.0.100", "10.10.0.150")],
                                        leaseTime: 604_800, gateway: ip("10.10.0.1"), netmask: ip("255.255.255.0"), serverType: "regular")

        var report = DHCPScopeReadReport(
            servers: [bureau, voix, quais, cameras, invites, serveurs], leases: leases,
            interfaces: ["internal": DHCPInterfaceInfo(alias: "Bureau"), "vlan20": DHCPInterfaceInfo(vlan: 20, alias: "Voix"),
                         "vlan30": DHCPInterfaceInfo(vlan: 30, alias: "Quais"), "vlan40": DHCPInterfaceInfo(vlan: 40, alias: "Caméras"),
                         "vlan60": DHCPInterfaceInfo(vlan: 60, alias: "Invités"), "vlan100": DHCPInterfaceInfo(vlan: 100, alias: "Serveurs")],
            readAt: now.addingTimeInterval(-2 * 60))
        report.calls = calls(report)
        return report
    }

    // MARK: Entrepôt Laval

    static func laval(now: Date = Date()) -> DHCPScopeReadReport {
        var leases: [DHCPLeaseEntry] = []
        for n in 0..<23 {
            leases.append(DHCPLeaseEntry(ip: ip("10.20.0.\(100 + n)"), mac: mac(dell, 500 + n), hostname: "POSTE-LAV-\(n + 1)", interface: "internal",
                                         expires: now.addingTimeInterval(TimeInterval((300 + n * 173) * 60)), serverID: 1, status: "leased"))
        }
        for n in 0..<104 {
            let octet = 50 + n + (n >= 150 ? 11 : 0)
            leases.append(DHCPLeaseEntry(ip: ip("10.20.10.\(octet)"), mac: mac(n % 2 == 0 ? zebra : honeywell, 600 + n),
                                         hostname: n % 2 == 0 ? "ZQ630-LAV-\(n)" : "LECTEUR-LAV-\(n)", interface: "vlan10",
                                         expires: now.addingTimeInterval(TimeInterval((30 + n * 29 % 480) * 60)), serverID: 2, status: "leased"))
        }
        var report = DHCPScopeReadReport(
            servers: [DHCPServerConfig(id: 1, interface: "internal", ranges: [range("10.20.0.100", "10.20.0.199")], leaseTime: 604_800,
                                       gateway: ip("10.20.0.1"), netmask: ip("255.255.255.0"), serverType: "regular"),
                      DHCPServerConfig(id: 2, interface: "vlan10", ranges: [range("10.20.10.50", "10.20.10.250")],
                                       exclusions: [range("10.20.10.200", "10.20.10.210")], leaseTime: 28_800,
                                       gateway: ip("10.20.10.1"), netmask: ip("255.255.255.0"), serverType: "regular")],
            leases: leases,
            interfaces: ["internal": DHCPInterfaceInfo(alias: "Bureaux"), "vlan10": DHCPInterfaceInfo(vlan: 10, alias: "Entrepôt")],
            readAt: now.addingTimeInterval(-3 * 60))
        report.calls = calls(report)
        return report
    }
}
