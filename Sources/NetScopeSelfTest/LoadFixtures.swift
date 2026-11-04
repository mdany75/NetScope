import Foundation
import NetScopeCore

// Note 36 : générateur de données fictives pour les essais de charge. Tout est calculé ici, de
// façon déterministe (générateur pseudo-aléatoire à graine fixe) : aucun réseau, aucune donnée réelle.
//
// Un parc type : 20 sites ; chaque site a 3 à 6 plages dont une de 65 536 adresses (/16), 2 000 à
// 5 000 appareils, une FortiGate avec 10 FortiSwitch et 30 FortiAP, un inventaire avec historique
// (plusieurs scans fusionnés : événements, IP successives, changements de port) et des résultats
// de scan.

/// Générateur pseudo-aléatoire reproductible (SplitMix64).
struct LoadRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    /// Vrai avec la probabilité donnée (0…1).
    mutating func chance(_ probability: Double) -> Bool {
        Double(next() % 1_000_000) / 1_000_000 < probability
    }

    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
}

/// Un site fictif complet.
struct LoadSite {
    var index: Int
    var name: String
    var key: String
    /// Plages du site (la première fait 65 536 adresses).
    var ranges: [IPRange]
    var rangeTexts: [String]
    /// Appareils du dernier scan.
    var devices: [Device]
    /// Nom des 10 FortiSwitch.
    var switchNames: [String]
}

enum LoadFixtures {
    /// Date fixe des données (aucune dépendance à l'horloge).
    static let now = Date(timeIntervalSince1970: 1_793_800_000)

    static let siteNames = ["Siège", "Entrepôt Laval", "Clinique Longueuil", "Usine Drummondville", "Bureau Québec",
                            "Centre Sherbrooke", "Atelier Trois-Rivières", "Magasin Gatineau", "Dépôt Lévis", "Bureau Rimouski",
                            "Clinique Saguenay", "Usine Granby", "Bureau Joliette", "Entrepôt Terrebonne", "Centre Brossard",
                            "Magasin Blainville", "Atelier Victoriaville", "Dépôt Rouyn", "Bureau Sept-Îles", "Usine Saint-Hyacinthe"]

    /// Préfixes de fabricants réels (OUI), pour que le nom du fabricant soit trouvé.
    static let ouis: [(UInt64, String, DeviceType, [UInt16])] = [
        (0x3C22FB, "Apple", .poste, [22, 5900]),
        (0xF4EE08, "Dell", .poste, [135, 445, 3389]),
        (0x005056, "VMware", .serveur, [22, 443, 445]),
        (0x94DDF8, "Brother", .imprimante, [80, 443, 631, 9100]),
        (0xBCAD28, "Hikvision", .camera, [80, 554]),
        (0xB8A44F, "Axis", .camera, [80, 443, 554]),
        (0x805EC0, "Yealink", .telephoneIP, [80, 5060]),
        (0x5CF938, "Apple", .telephone, []),
        (0x04D590, "Fortinet", .routeur, [22, 443]),
        (0xD8BBC1, "Micro-Star", .poste, [445]),
        (0x001132, "Synology", .serveur, [22, 80, 443, 5000]),
        (0x18B430, "Nest", .domotique, []),
    ]

    // MARK: Sites et appareils

    /// `count` sites, chacun avec `devicesPerSite` appareils (nil : 2 000 à 5 000, au hasard).
    static func sites(_ count: Int = 20, devicesPerSite: Int? = nil, seed: UInt64 = 36) -> [LoadSite] {
        var random = LoadRandom(seed: seed)
        return (0..<count).map { index in
            let wanted = devicesPerSite ?? random.int(2_000...5_000)
            return site(index, devices: wanted, random: &random)
        }
    }

    static func site(_ index: Int, devices wanted: Int, random: inout LoadRandom) -> LoadSite {
        let name = index < siteNames.count ? siteNames[index] : "Site \(index + 1)"
        // Première plage : un /16 de 65 536 adresses ; puis 2 à 5 /24.
        var texts = ["10.\(100 + index).0.0/16"]
        let extra = random.int(2...5)
        for k in 0..<extra { texts.append("172.\(16 + index % 16).\(k * 10 + index / 16).0/24") }
        let ranges = texts.compactMap { try? IPRange(parsing: $0) }
        let switches = (1...10).map { String(format: "FSW-%02d-%02d", index + 1, $0) }
        var list: [Device] = []
        list.reserveCapacity(wanted)
        var used = Set<UInt32>()
        let base16 = UInt32(10) << 24 | UInt32(100 + index) << 16
        for n in 0..<wanted {
            // 80 % dans le /16, le reste dans les /24.
            var ip: UInt32
            repeat {
                if random.chance(0.8) {
                    ip = base16 | UInt32(random.int(0...255)) << 8 | UInt32(random.int(1...254))
                } else {
                    let k = random.int(0...(extra - 1))
                    ip = UInt32(172) << 24 | UInt32(16 + index % 16) << 16 | UInt32(k * 10 + index / 16) << 8 | UInt32(random.int(1...254))
                }
            } while used.contains(ip)
            used.insert(ip)
            let vendor = random.pick(ouis)
            // 5 % d'appareils sans MAC (derrière un routeur).
            let mac: MACAddress? = random.chance(0.05) ? nil
                : MACAddress(value: vendor.0 << 24 | UInt64(index) << 16 | UInt64(n & 0xFFFF))
            let online = random.chance(0.9)
            let sw = switches[n % switches.count]
            let port = "port\(1 + n % 48)"
            let device = Device(ip: IPv4Address(ip), mac: mac, vendor: vendor.1,
                                hostname: random.chance(0.7) ? "\(vendor.2.rawValue)-\(index + 1)-\(n)" : nil,
                                isOnline: online, latencyMs: online ? Double(random.int(1...40)) / 10 : nil,
                                openPorts: vendor.3, switchName: sw, switchPort: port, vlan: 10 * (1 + n % 6),
                                firstSeen: now.addingTimeInterval(-86_400 * 60), lastSeen: now.addingTimeInterval(online ? 0 : -3_600),
                                rangeLabel: ip >> 16 == base16 >> 16 ? "Bureaux" : "Atelier", deviceType: vendor.2)
            list.append(device)
        }
        return LoadSite(index: index, name: name, key: "site-\(index + 1)", ranges: ranges, rangeTexts: texts,
                        devices: list, switchNames: switches)
    }

    /// Scan suivant : 4 % changent d'IP, 3 % de port, 5 % passent hors ligne, quelques nouveaux.
    static func nextScan(_ devices: [Device], step: Int, random: inout LoadRandom) -> [Device] {
        var used = Set(devices.map(\.ip.value))
        var result: [Device] = []
        result.reserveCapacity(devices.count + 50)
        let date = now.addingTimeInterval(Double(step) * 3_600)
        for var device in devices {
            if random.chance(0.04) {
                var ip = device.ip.value
                repeat { ip = (ip & 0xFFFF_FF00) | UInt32(random.int(1...254)) } while used.contains(ip)
                used.remove(device.ip.value)
                used.insert(ip)
                device.ip = IPv4Address(ip)
            }
            if random.chance(0.03) { device.switchPort = "port\(random.int(1...48))" }
            device.isOnline = !random.chance(0.05)
            device.lastSeen = device.isOnline ? date : device.lastSeen
            result.append(device)
        }
        for n in 0..<random.int(10...50) {
            var ip: UInt32
            repeat { ip = (devices[n].ip.value & 0xFFFF_0000) | UInt32(random.int(0...255)) << 8 | UInt32(random.int(1...254)) }
            while used.contains(ip)
            used.insert(ip)
            result.append(Device(ip: IPv4Address(ip), mac: MACAddress(value: 0x3C22FB << 24 | UInt64(step) << 16 | UInt64(n)),
                                 hostname: "nouveau-\(step)-\(n)", firstSeen: date, lastSeen: date, deviceType: .poste))
        }
        return result
    }

    /// Inventaire avec historique : `scans` fusions successives (la première fait la référence).
    static func inventory(for site: LoadSite, scans: Int = 4, seed: UInt64 = 7) -> (store: InventoryStore, lastScan: [Device]) {
        var random = LoadRandom(seed: seed &+ UInt64(site.index))
        var store = InventoryStore()
        var devices = site.devices
        store.merge(devices, at: now, coverage: .ranges(site.ranges))
        for step in 1..<max(scans, 1) {
            devices = nextScan(devices, step: step, random: &random)
            store.merge(devices, at: now.addingTimeInterval(Double(step) * 3_600), coverage: .ranges(site.ranges))
        }
        // Quelques fiches annotées (noms, étiquettes, locaux) comme un vrai parc.
        for record in store.sortedRecords.prefix(300) {
            var notes = record.annotations
            notes.customName = "Poste \(record.ip.value & 0xFFFF)"
            notes.tags = ["compta", "étage \(record.ip.value % 4)"]
            notes.location = "Local \(100 + record.ip.value % 40)"
            store.setAnnotations(notes, for: record.key, at: now, recordEvent: false)
        }
        return (store, devices)
    }

    // MARK: FortiGate

    /// Réponses JSON d'une FortiGate fictive : 10 FortiSwitch de 48 ports, 30 FortiAP, tables ARP,
    /// DHCP, appareils détectés et clients Wi-Fi pour les appareils du site.
    static func fortiResponses(for site: LoadSite) -> [String: (Int, String)] {
        let fgt = String(format: "FGT-%02d", site.index + 1)
        let tail = #","vdom":"root","status":"success","serial":"FG100FTK22004711","version":"v7.4.4","build":2662}"#
        func envelope(_ items: [String]) -> String { #"{"http_method":"GET","results":["# + items.joined(separator: ",") + "]" + tail }

        let status = #"{"http_method":"GET","results":{"model_name":"FortiGate","model_number":"100F","model":"FGT100F","hostname":""#
            + fgt + #""}"# + tail
        var switches: [String] = []
        var config: [String] = []
        for (n, name) in site.switchNames.enumerated() {
            let serial = String(format: "S248EPTF2%07d", site.index * 100 + n)
            let ports = (1...48).map { p in
                #"{"interface":"port\#(p)","status":"\#(p % 7 == 0 ? "down" : "up")","duplex":"full","speed":1000,"vlan":"vlan\#(10 * (1 + p % 6))","poe_capable":true,"port_power":\#(Double(p % 9)),"power_status":"Delivering Power","poe_class":2}"#
            } + [#"{"interface":"port49","status":"up","speed":10000,"vlan":"_default","fortilink_port":true,"fgt_peer_port_name":"port1","fgt_peer_device_name":"\#(fgt)"}"#]
            switches.append(#"{"name":"\#(name)","serial":"\#(serial)","switch-id":"\#(name)","status":"Connected","state":"Authorized","os_version":"S248EP-v7.2.5-build0453,230920 (GA)","connecting_from":"10.255.1.\#(n + 2)","max_poe_budget":370,"ports":["# + ports.joined(separator: ",") + "]}")
            let portConfig = (1...48).map { p in #"{"port-name":"port\#(p)","description":"Prise \#(name)-\#(p)","vlan":"vlan\#(10 * (1 + p % 6))","status":"up","poe-status":"enable"}"# }
            config.append(#"{"switch-id":"\#(name)","sn":"\#(serial)","name":"\#(name)","ports":["# + portConfig.joined(separator: ",") + "]}")
        }
        var detected: [String] = []
        var arp: [String] = []
        var dhcp: [String] = []
        var users: [String] = []
        var clients: [String] = []
        for (n, device) in site.devices.enumerated() {
            guard let mac = device.mac?.formatted(.colon) else { continue }
            let ip = device.ip.description
            arp.append(#"{"ip":"\#(ip)","age":\#(n % 60),"mac":"\#(mac)","interface":"vlan\#(device.vlan ?? 10)"}"#)
            if device.deviceType == .telephone || device.deviceType == .domotique {
                clients.append(#"{"mac":"\#(mac)","ip":"\#(ip)","hostname":"\#(device.hostname ?? "")","ssid":"Groupe-Interne","wtp_id":"FP231FTF2\#(String(format: "%07d", site.index * 100 + n % 30))","radio_id":2,"channel":44,"signal":-\#(50 + n % 35),"noise":-95,"data_rate_bps":866700000,"vlan_id":20}"#)
            } else {
                detected.append(#"{"mac":"\#(mac)","switch_id":"\#(device.switchName ?? "")","port_name":"\#(device.switchPort ?? "")","port_id":\#(1 + n % 48),"vlan_id":\#(device.vlan ?? 10),"last_seen":\#(n % 300),"vdom":"root"}"#)
            }
            if n % 2 == 0 {
                dhcp.append(#"{"ip":"\#(ip)","reserved":false,"mac":"\#(mac)","hostname":"\#(device.hostname ?? "")","expire_time":1793890000,"status":"leased","interface":"vlan\#(device.vlan ?? 10)","type":"ipv4"}"#)
            }
            users.append(#"{"ipv4_address":"\#(ip)","mac":"\#(mac)","hardware_vendor":"\#(device.vendor ?? "")","hostname":"\#(device.hostname ?? "")","last_seen":1793790000,"is_online":\#(device.isOnline),"detected_interface":"vlan\#(device.vlan ?? 10)"}"#)
        }
        let aps = (0..<30).map { n -> String in
            let serial = "FP231FTF2" + String(format: "%07d", site.index * 100 + n)
            return #"{"name":"AP-\#(site.index + 1)-\#(n + 1)","serial":"\#(serial)","wtp_id":"\#(serial)","status":"\#(n % 13 == 12 ? "disconnected" : "connected")","state":"authorized","connecting_from":"10.\#(100 + site.index).250.\#(n + 10)","os_version":"FP231F-v7.2.8-build0436","join_time_raw":1793690000,"clients":\#(n % 25),"radio":[{"radio_id":1,"radio_type":"802.11ax,n,g-only","oper_chan":\#([1, 6, 11][n % 3]),"channel_bandwidth":"20MHz","oper_txpower":14,"client_count":\#(n % 7),"channel_utilization_percent":\#(20 + n * 2),"noise_floor":-94},{"radio_id":2,"radio_type":"802.11ax-5G","oper_chan":\#([36, 44, 149, 157][n % 4]),"channel_bandwidth":"80MHz","oper_txpower":17,"client_count":\#(n % 18),"channel_utilization_percent":\#(10 + n),"noise_floor":-96}]}"#
        }
        return [
            FortiPaths.systemStatus: (200, status),
            FortiPaths.switchStatus: (200, envelope(switches)),
            FortiPaths.switchConfig: (200, envelope(config)),
            FortiPaths.detectedDevice: (200, envelope(detected)),
            FortiPaths.arp: (200, envelope(arp)),
            FortiPaths.dhcp: (200, envelope(dhcp)),
            FortiPaths.userDevices: (200, envelope(users)),
            FortiWifiPaths.managedAP: (200, envelope(aps)),
            FortiWifiPaths.client: (200, envelope(clients)),
        ]
    }
}
