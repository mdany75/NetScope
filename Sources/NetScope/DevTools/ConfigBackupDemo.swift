import Foundation
import NetScopeCore

/// Note 40 (0.31.0) : historique de démonstration de l'onglet « Configurations » (site Siège) :
/// FortiGate, SW-CORE-01 (Cisco, modifié ce matin : VLAN 60 des caméras) et SW-ETG2-01 (Aruba).
/// Configurations plausibles mais sans aucun secret ; rien n'est lu ni écrit sur le disque.
enum ConfigBackupDemo {
    struct Content {
        var settings: ConfigBackupSettings
        var versions: [String: [ConfigVersion]]
        var texts: [String: String]
        var errors: [String: ConfigBackupError]
        var notices: [String: String]
    }

    private static func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 11) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = month; parts.day = day; parts.hour = hour; parts.minute = minute
        return Calendar.current.date(from: parts) ?? Date()
    }

    static func make() -> Content {
        let archive = ConfigBackupArchive(root: URL(fileURLWithPath: "/demo/configurations"))
        var versions: [String: [ConfigVersion]] = [:]
        var texts: [String: String] = [:]
        func add(_ id: String, _ items: [(Date, String)]) {
            let list = items.map { item -> ConfigVersion in
                let url = archive.folder(for: id).appendingPathComponent(archive.fileName(for: item.0))
                texts[url.path] = item.1
                return ConfigVersion(url: url, date: item.0, size: item.1.utf8.count)
            }
            versions[id] = list.sorted { $0.date > $1.date }
        }
        add("FortiGate-Siege", [(date(15, 7, 30, month: 10), fortigate(policies: 1)), (date(22, 7, 30, month: 10), fortigate(policies: 1)),
                                (date(29, 7, 30, month: 10), fortigate(policies: 2)), (date(5, 7, 30), fortigate(policies: 2))])
        add("SW-CORE-01", [(date(22, 7, 31, month: 10), cisco(cameras: false)), (date(29, 7, 31, month: 10), cisco(cameras: false)),
                           (date(5, 9, 12), cisco(cameras: true))])
        add("SW-ETG2-01", [(date(29, 7, 32, month: 10), aruba), (date(1, 7, 32), aruba)])

        var settings = ConfigBackupSettings(keep: 30)
        settings.lastChecked = ["FortiGate-Siege": date(5, 7, 30), "SW-CORE-01": date(5, 9, 12), "SW-ETG2-01": date(5, 7, 32)]
        settings.pendingChanges = ["SW-CORE-01": date(5, 9, 12)]
        let errors = ["SW-LAB-ANCIEN": ConfigBackupError(kind: .unknownHostKey, detail: "Empreinte présentée par 10.182.122.9\u{00A0}: SHA256:q8Vd3kLx0rTzY2mJp4Hn6sWfA1cEbG7uK9oPiR5tNvM",
                                                         fingerprint: "SHA256:q8Vd3kLx0rTzY2mJp4Hn6sWfA1cEbG7uK9oPiR5tNvM")]
        let diff = ConfigDiff.make(old: cisco(cameras: false), new: cisco(cameras: true))
        let notices = ["SW-CORE-01": "Configuration modifiée\u{00A0}: +\(diff.added) −\(diff.removed) lignes."]
        return Content(settings: settings, versions: versions, texts: texts, errors: errors, notices: notices)
    }

    // MARK: Textes (aucun secret)

    static func cisco(cameras: Bool) -> String {
        var lines = [
            "Building configuration...", "", "Current configuration : 18422 bytes", "!",
            "! Last configuration change at 09:10:44 EST Thu Nov 5 2026 by netadmin", "!",
            "version 17.9", "service timestamps debug datetime msec", "service timestamps log datetime msec",
            "service password-encryption", "no platform punt-keepalive disable-kernel-core", "!",
            "hostname SW-CORE-01", "!", "vrf definition Mgmt-vrf", " address-family ipv4", " exit-address-family", "!",
            "logging buffered 64000 informational", "aaa new-model", "aaa authentication login default local", "!",
            "clock timezone EST -5 0", "clock summer-time EDT recurring", "!",
            "ip domain name siege.local", "ip name-server 10.182.122.10", "!",
            "spanning-tree mode rapid-pvst", "spanning-tree extend system-id", "!",
            "vlan 10", " name Serveurs", "!", "vlan 20", " name Postes", "!", "vlan 30", " name Imprimantes", "!",
            "vlan 40", " name Telephonie", "!",
        ]
        if cameras { lines += ["vlan 60", " name Cameras", "!"] }
        lines += [
            "interface GigabitEthernet1/0/1", " description Prise 101", " switchport access vlan 20", " switchport mode access",
            " spanning-tree portfast", "!",
            "interface GigabitEthernet1/0/18",
        ]
        lines += cameras
            ? [" description Camera quai 2", " switchport access vlan 60", " switchport mode access", " power inline auto max 15400"]
            : [" description Prise 118", " switchport access vlan 20", " switchport mode access"]
        lines += [
            " spanning-tree portfast", "!",
            "interface TenGigabitEthernet1/1/1", " description Vers FGT-SIEGE", " switchport mode trunk",
            cameras ? " switchport trunk allowed vlan 1,10,20,30,40,60" : " switchport trunk allowed vlan 1,10,20,30,40", "!",
            "interface Vlan1", " ip address 10.182.122.2 255.255.255.0", "!",
            "ip default-gateway 10.182.122.1", "ip ssh version 2", "!",
            "snmp-server location Siege - salle des serveurs", "snmp-server contact soutien@exemple.ca", "!",
            "ntp server 10.182.122.1", "!", "line vty 0 15", " transport input ssh", "!", "end",
        ]
        if !cameras {
            lines.insert(contentsOf: ["ip access-list standard GESTION", " permit 10.182.122.0 0.0.0.255", "!"], at: lines.count - 1)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static let aruba: String = [
        "; JL261A Configuration Editor; Created on release #WC.16.11.0012", "; Ver #14:41.44.00.04.19.02.13.98.82.34.61.18.28.f3.84.9c.63.ff.37.27:05",
        "hostname \"SW-ETG2-01\"", "module 1 type jl261a", "timesync sntp", "sntp unicast", "sntp server priority 1 10.182.122.1",
        "ip default-gateway 10.182.122.1", "snmp-server contact \"soutien@exemple.ca\"", "snmp-server location \"Etage 2\"",
        "vlan 1", "   name \"DEFAULT_VLAN\"", "   untagged 21-28", "   ip address 10.182.122.3 255.255.255.0", "   exit",
        "vlan 20", "   name \"Postes\"", "   untagged 1-16", "   tagged 25", "   no ip address", "   exit",
        "vlan 40", "   name \"Telephonie\"", "   tagged 1-16,25", "   no ip address", "   voice", "   exit",
        "spanning-tree", "no tftp server", "no autorun", "no dhcp config-file-update", "password manager", "",
    ].joined(separator: "\n")

    static func fortigate(policies: Int) -> String {
        var lines = [
            "#config-version=FGT60F-7.4.4-FW-build2662-240514:opmode=0:vdom=0:user=api-netscope",
            "#conf_file_ver=318027712345", "#buildno=2662", "#global_vdom=1",
            "config system global", "    set admintimeout 30", "    set alias \"FGT-SIEGE\"", "    set hostname \"FGT-SIEGE\"",
            "    set timezone \"America/Toronto\"", "end",
            "config system interface", "    edit \"wan1\"", "        set mode dhcp", "        set allowaccess ping https",
            "    next", "    edit \"internal\"", "        set ip 10.182.122.1 255.255.255.0",
            "        set allowaccess ping https ssh snmp fabric", "    next", "end",
            "config firewall address", "    edit \"LAN-SIEGE\"", "        set subnet 10.182.122.0 255.255.255.0", "    next", "end",
            "config firewall policy", "    edit 1", "        set name \"LAN vers Internet\"", "        set srcintf \"internal\"",
            "        set dstintf \"wan1\"", "        set action accept", "        set srcaddr \"LAN-SIEGE\"", "        set dstaddr \"all\"",
            "        set schedule \"always\"", "        set service \"ALL\"", "        set nat enable", "    next",
        ]
        if policies > 1 {
            lines += ["    edit 2", "        set name \"Cameras vers NVR\"", "        set srcintf \"internal\"", "        set dstintf \"internal\"",
                      "        set action accept", "        set srcaddr \"LAN-SIEGE\"", "        set dstaddr \"NVR\"",
                      "        set schedule \"always\"", "        set service \"HTTPS\" \"RTSP\"", "    next"]
        }
        lines += ["end"]
        return lines.joined(separator: "\n") + "\n"
    }
}
