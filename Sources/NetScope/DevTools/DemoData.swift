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
        // Captures : NETSCOPE_DEVICE=10.182.122.135 ouvre la fiche d'un autre appareil (ex. ce Mac).
        if CommandLine.arguments.contains("--snapshot"), let ip = ProcessInfo.processInfo.environment["NETSCOPE_DEVICE"] {
            state.selectedDeviceID = ip
        }
        // Captures (note 26) : NETSCOPE_RECHERCHE="switch:SW-ETG2 type:imprimante" applique cette
        // recherche au Scanner (ou à l'écran NETSCOPE_RECHERCHE_ECRAN=inventaire, switchs…).
        if CommandLine.arguments.contains("--snapshot"), let text = ProcessInfo.processInfo.environment["NETSCOPE_RECHERCHE"] {
            let screen = ProcessInfo.processInfo.environment["NETSCOPE_RECHERCHE_ECRAN"].flatMap(Screen.init(rawValue:)) ?? .scanner
            state.searchTexts[screen] = text
        }
        state.activeInterface = interface
        state.dnsServers = [IPv4Address("10.182.122.1")!]
        // Pastille « Mise à jour disponible » : seulement sur demande (NETSCOPE_MAJ_DEMO=1), pour que
        // les captures publiées sur GitHub n'annoncent pas une version qui n'existe pas.
        if ProcessInfo.processInfo.environment["NETSCOPE_MAJ_DEMO"] == "1" { state.updateAvailable = "0.23.0" }
        state.pingTargets = ["10.182.122.1", "10.182.122.111", "8.8.8.8"]
        state.sidebarBadges = [.surveillance: 3]
        MonStore.shared.attach(to: state) // badge Surveillance = alertes non lues de la démonstration
        // Inventaire de démonstration et pastille Analyse calculés dès le départ, comme sur les autres écrans.
        InvModel.shared.appState = state   // note 84 : interface Wi-Fi de ce Mac
        InvModel.shared.observe(state.devices, immediately: true)
        InvModel.shared.updateBadge(state)
        // Note 28 : sites de démonstration (NETSCOPE_SITE choisit le site actif des captures).
        SiteModel.shared.attachDemo(to: state)
        // Notes 31, 33 et 34 : NETSCOPE_NAV="carte:imprimantes>inventaire" capture un écran ouvert
        // par la navigation (étiquette du filtre transmis, bouton Retour actif).
        NavDemo.apply(to: state)
        // Note 73 : NETSCOPE_PORT choisit le port affiché dans Switchs et ports (actions sur le port).
        PortActionDemo.apply(to: state)
        // Écran Appareil : « Ouvrir une fiche », appareil saisi à la main (NETSCOPE_APPAREIL_*).
        DeviceLookupDemo.apply(to: state)
    }

    /// Interface active fictive (Wi-Fi du bureau).
    static let interface = LocalInterface(name: "en0", address: IPv4Address("10.182.122.135")!,
                                          netmask: IPv4Address("255.255.255.0")!, kind: .wifi,
                                          gateway: IPv4Address("10.182.122.1")!)

    /// Plages de la démonstration ; la capture à deux sites (NETSCOPE_FORTIGATE_MULTI=1) y ajoute
    /// celle de l'entrepôt de Laval, pour que le Scanner montre la plage dont la FortiGate est lue.
    static var ranges: [ScanRangeConfig] {
        var ranges = [
            ScanRangeConfig(text: "10.182.122.0/24", label: "Bureau", vlan: 1),
            ScanRangeConfig(text: "192.168.50.0/24", label: "Caméras", vlan: 40),
            ScanRangeConfig(text: "10.10.0.1-50", label: "Serveurs", vlan: 100),
        ]
        if FortiGateSitesDemo.multiSite { ranges.append(ScanRangeConfig(text: "10.20.10.0/24", label: "Entrepôt Laval", vlan: 10)) }
        return ranges
    }

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
        // Note 6 : poste Windows avec l'accès IP direct de RustDesk (21118).
        Row(ip: "10.182.122.126", name: "Poste direction", host: "WKS355", vendor: "Dell", mac: "B0:7B:25:44:B2:26", latency: 2.2, ports: [135, 445, 21118], sw: "SW-ETG2-01", port: "1/5", vlan: 1, minutesAgo: 0, type: .poste, online: true, range: "Bureau"),
        // Note 30 : téléphones IP Yealink sur SW-ETG2-01, VLAN voix 20 (annoncés « téléphone » par LLDP-MED).
        Row(ip: "10.182.122.121", name: "Téléphone accueil", host: "SIP-T54W", vendor: "Yealink", mac: "80:5E:C0:3A:61:21", latency: 2.1, ports: [80, 443, 5060], sw: "SW-ETG2-01", port: "1/10", vlan: 20, minutesAgo: 0, type: .telephoneIP, online: true, range: "Bureau"),
        Row(ip: "10.182.122.122", name: nil, host: "SIP-T46U", vendor: "Yealink", mac: "80:5E:C0:3A:61:22", latency: 2.4, ports: [80, 443, 5060], sw: "SW-ETG2-01", port: "1/15", vlan: 20, minutesAgo: 0, type: .telephoneIP, online: true, range: "Bureau"),
        Row(ip: "10.182.122.123", name: "Téléphone conférence 2.08", host: "SIP-T33G", vendor: "Yealink", mac: "80:5E:C0:3A:61:23", latency: 2.9, ports: [80, 5060], sw: "SW-ETG2-01", port: "1/16", vlan: 20, minutesAgo: 1, type: .telephoneIP, online: true, range: "Bureau"),
        Row(ip: "10.182.122.133", name: nil, host: "Android_89UM1WTN", vendor: nil, mac: "D6:4E:81:7A:33:C0", latency: 18.6, ports: [], sw: "FortiAP-231F", port: "Wi-Fi", vlan: 20, minutesAgo: 4, type: .telephone, online: true, range: "Bureau"),
        Row(ip: "10.182.122.135", name: "Ce Mac", host: "Macmini-de-Dany.local", vendor: "Apple", mac: "3C:22:FB:7E:05:B1", latency: 0.1, ports: [22, 5900], sw: "FortiAP-231F", port: "Wi-Fi", vlan: 20, minutesAgo: 0, type: .poste, online: true, range: "Bureau"),
        Row(ip: "10.182.122.140", name: nil, host: "NPI7A4410", vendor: "HP", mac: "00:1A:2B:44:10:EE", latency: 7.8, ports: [80, 9100], sw: "SW-ETG2-01", port: "1/18", vlan: 30, minutesAgo: 3, type: .imprimante, online: true, range: "Bureau"),
        Row(ip: "10.182.122.146", name: "Poste réception", host: "WKS341", vendor: "Dell", mac: "B0:7B:25:44:9F:20", latency: nil, ports: [], sw: "SW-CORE-01", port: "Gi1/0/23", vlan: 1, minutesAgo: 180, type: .poste, online: false, range: "Bureau"),
        // Note 72 : NAS Synology qui remplace NAS-ANCIEN (InventairePhase3Demo), partages SMB lus
        // en invité (SMBSharesDemo) ; après l'imprimante choisie dans le Scanner : le tableau des
        // captures ne se décale pas.
        Row(ip: "10.182.122.154", name: "NAS salle B01", host: "DS920-B01", vendor: "Synology", mac: "00:11:32:9A:4E:07", latency: 1.4, ports: [80, 139, 443, 445, 5000, 5001], sw: "SW-CORE-01", port: "Gi1/0/24", vlan: 1, minutesAgo: 0, type: .serveur, online: true, range: "Bureau"),
        // Note 98 : onduleur APC de la baie réseau (carte AP9641), après le NAS : le tableau ne se décale pas.
        Row(ip: "10.182.122.160", name: "Onduleur baie réseau", host: "UPS-BAIE-RESEAU", vendor: "American Power Conversion", mac: "00:C0:B7:5E:21:A0", latency: 2.0, ports: [80, 443], sw: "SW-CORE-01", port: "Gi1/0/46", vlan: 1, minutesAgo: 0, type: .onduleur, online: true, range: "Bureau"),
        Row(ip: "192.168.50.21", name: "Caméra quai", host: "DS-2CD2143G2-I", vendor: "Hikvision", mac: "BC:AD:28:6F:01:5A", latency: 3.0, ports: [80, 443, 554], sw: "SW-CORE-01", port: "Gi1/0/33", vlan: 40, minutesAgo: 0, type: .camera, online: true, range: "Caméras"),
        Row(ip: "192.168.50.22", name: nil, host: "axis-b8a44f2c19e0", vendor: "Axis", mac: "B8:A4:4F:2C:19:E0", latency: 2.7, ports: [80, 443, 554], sw: "SW-CORE-01", port: "Gi1/0/34", vlan: 40, minutesAgo: 0, type: .camera, online: true, range: "Caméras"),
        Row(ip: "10.10.0.10", name: "Contrôleur de domaine", host: "SRV-AD-01", vendor: "Dell", mac: "F4:EE:08:3C:72:A1", latency: 0.9, ports: [53, 88, 389, 445], sw: "SW-CORE-01", port: "Gi1/0/40", vlan: 100, minutesAgo: 0, type: .serveur, online: true, range: "Serveurs"),
        // Note 6 : serveur RustDesk auto-hébergé (Ubuntu, hbbs et hbbr), ports 21115 à 21117 ouverts.
        Row(ip: "10.10.0.20", name: "Assistance à distance", host: "srv-assistance", vendor: "VMware", mac: "00:50:56:AA:10:20", latency: 1.0, ports: [22, 21115, 21116, 21117, 21118], sw: "SW-CORE-01", port: "Gi1/0/41", vlan: 100, minutesAgo: 0, type: .serveur, online: true, range: "Serveurs"),
        // Note 24 : branchés sur des FortiSwitch gérés par la FortiGate (FortiGateDemo, mêmes MAC).
        Row(ip: "10.10.0.31", name: "Serveur de sauvegarde", host: "SRV-BACKUP", vendor: "VMware", mac: "00:50:56:AA:10:31", latency: 1.2, ports: [22, 443, 445], sw: "FSW-SERVEURS", port: "port1", vlan: 100, minutesAgo: 0, type: .serveur, online: true, range: "Serveurs"),
        Row(ip: "192.168.50.31", name: nil, host: "CAM-ENTREPOT-01", vendor: "Hikvision", mac: "BC:AD:28:6F:22:31", latency: 3.6, ports: [80, 443, 554], sw: "FSW-QUAI", port: "port1", vlan: 40, minutesAgo: 1, type: .camera, online: true, range: "Caméras"),
    ]

    /// Origine du nom (et groupe NetBIOS) de chaque appareil fictif, comme la résolution automatique
    /// les donnerait : SNMP pour les équipements réseau, mDNS pour Apple et l'IoT, NetBIOS pour Windows.
    private static let names: [String: (NameDetails.Source, String?)] = [
        "10.182.122.1": (.snmp, nil), "10.182.122.2": (.snmp, nil), "10.182.122.3": (.snmp, nil),
        "10.182.122.100": (.mdns, nil), "10.182.122.102": (.dns, nil), "10.182.122.106": (.mdns, nil),
        "10.182.122.111": (.mdns, nil), "10.182.122.113": (.netbios, "BUREAU"), "10.182.122.117": (.netbios, "BUREAU"),
        "10.182.122.121": (.dns, nil), "10.182.122.122": (.dns, nil), "10.182.122.123": (.dns, nil),
        "10.182.122.133": (.dns, nil), "10.182.122.135": (.mdns, nil), "10.182.122.140": (.netbios, "WORKGROUP"),
        "10.182.122.146": (.netbios, "BUREAU"), "192.168.50.21": (.dns, nil), "192.168.50.22": (.mdns, nil),
        "10.10.0.10": (.dns, nil), "10.10.0.31": (.fortigate, nil), "192.168.50.31": (.fortigate, nil),
        "10.182.122.126": (.netbios, "BUREAU"), "10.10.0.20": (.dns, nil), "10.182.122.154": (.netbios, "BUREAU"),
        "10.182.122.160": (.snmp, nil),
    ]

    /// Nature SNMP des appareils qui ont répondu à la découverte automatique (démonstration).
    private static let snmpKinds: [String: SNMPDeviceKind] = [
        "10.182.122.1": .routeur, "10.182.122.2": .switch, "10.182.122.3": .switch, "10.182.122.111": .imprimante,
        "10.182.122.160": .onduleur,
    ]

    /// Indices de téléphonie IP (note 30) : annonce LLDP-MED « téléphone » relevée sur SW-ETG2-01, VLAN voix 20.
    private static let voipSignals: [String: VoIPSignals] = [
        "10.182.122.121": [.announcedPhone, .voiceVLAN], "10.182.122.122": [.announcedPhone, .voiceVLAN],
        "10.182.122.123": [.announcedPhone, .voiceVLAN],
    ]

    /// Appareils datés par rapport à `now` (« à l'instant », « il y a 3 h »).
    static func devices(now: Date = Date()) -> [Device] {
        // IPv6 (0.31.0) : adresses IPv6 rattachées par la MAC, comme après la lecture de la table NDP.
        IPv6Demo.attach(rows.map { row in
            let seen = now.addingTimeInterval(-row.minutesAgo * 60)
            return Device(ip: IPv4Address(row.ip)!, mac: MACAddress(row.mac), vendor: row.vendor,
                          hostname: row.host, customName: row.name, isOnline: row.online,
                          latencyMs: row.latency, openPorts: row.ports, switchName: row.sw,
                          switchPort: row.port, vlan: row.vlan,
                          firstSeen: now.addingTimeInterval(-14 * 86_400), lastSeen: seen,
                          rangeLabel: row.range, deviceType: row.type,
                          nameSource: names[row.ip]?.0, nameDomain: names[row.ip]?.1, snmpKind: snmpKinds[row.ip],
                          voipSignals: voipSignals[row.ip], fingerprint: FingerprintDemo.evidence[row.ip])
        }
        .sorted { $0.ip < $1.ip })
    }
}
