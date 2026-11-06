import Foundation

// Note 77 : lecture des réponses de l'API UniFi Network (contrôleur classique, ou UniFi OS par le
// préfixe /proxy/network) : stat/sysinfo, self/sites, stat/device, stat/sta, rest/networkconf.
// Enveloppe : { "meta": { "rc": "ok" | "error", "msg": "…" }, "data": [ … ] }. Lecture tolérante
// (champs absents ou d'un autre type acceptés), fonctions pures, sans réseau.

public enum UniFiParsers {
    /// Contenu « data » et erreur éventuelle de l'enveloppe (« api.err.NoSiteContext »…).
    public static func envelope(_ data: Data) -> (items: [FortiObject], error: String?)? {
        guard let json = FortiJSON.parse(data) else { return nil }
        if let array = json as? [Any] { return (FortiJSON.objects(array), nil) }
        guard let dict = json as? [String: Any] else { return nil }
        let object = FortiObject(dict)
        let meta = object.object("meta")
        let rc = meta?.string("rc")?.lowercased()
        let message = meta?.string("msg")
        // UniFi OS sans session : { "error": { "code": 401, "message": "Unauthorized" } }.
        if let error = object.object("error") { return ([], error.string("message") ?? "erreur") }
        if rc == "error" { return ([], message ?? "erreur") }
        return (object.list("data"), nil)
    }

    /// Version et nom du contrôleur (stat/sysinfo).
    public static func sysinfo(_ data: Data) -> (version: String?, name: String?)? {
        guard let first = envelope(data)?.items.first else { return nil }
        return (first.string("version"), first.string("name", "hostname"))
    }

    /// Sites du contrôleur (self/sites) : nom court et description.
    public static func sites(_ data: Data) -> [(name: String, desc: String)] {
        (envelope(data)?.items ?? []).compactMap { item in
            guard let name = item.string("name") else { return nil }
            return (name, item.string("desc") ?? name)
        }
    }

    /// Nom court du site voulu : par nom court ou par description, casse ignorée ; nil si absent.
    public static func resolveSite(_ wanted: String, in sites: [(name: String, desc: String)]) -> String? {
        let key = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { return sites.first { $0.name == "default" }?.name ?? sites.first?.name }
        return sites.first { $0.name.lowercased() == key }?.name ?? sites.first { $0.desc.lowercased() == key }?.name
    }

    /// Réseaux (rest/networkconf) : identifiant → VLAN (1 pour le réseau sans VLAN).
    public static func networks(_ data: Data) -> [String: Int] {
        var result: [String: Int] = [:]
        for item in envelope(data)?.items ?? [] {
            guard let id = item.string("_id") else { continue }
            let tagged = item.bool("vlan_enabled") ?? (item.int("vlan") != nil)
            if tagged, let vlan = item.int("vlan"), (1...4094).contains(vlan) {
                result[id] = vlan
            } else if item.string("purpose") != "wan" {
                result[id] = 1
            }
        }
        return result
    }

    /// Bande d'un code de radio UniFi : « ng » 2,4 GHz, « na » 5 GHz, « 6e » 6 GHz.
    public static func band(_ code: String?) -> WifiBand? {
        switch code?.lowercased() ?? "" {
        case "ng", "g", "b", "ng-he": return .ghz24
        case "na", "a", "na-he": return .ghz5
        case "6e", "6g": return .ghz6
        default: return nil
        }
    }

    /// Modèles courants : code interne → nom commercial (les autres gardent leur code).
    static let modelNames: [String: String] = [
        "US8P60": "US-8-60W", "US8P150": "US-8-150W", "US16P150": "US-16-150W", "US24P250": "US-24-250W",
        "US24P500": "US-24-500W", "US48P500": "US-48-500W", "US48P750": "US-48-750W",
        "USL8LP": "USW-Lite-8-PoE", "USL16LP": "USW-Lite-16-PoE", "USL16P": "USW-16-PoE", "USL24P": "USW-24-PoE",
        "USL24": "USW-24", "USL48P": "USW-48-PoE", "US24PRO": "USW-Pro-24-PoE", "US24PRO2": "USW-Pro-24",
        "US48PRO": "USW-Pro-48-PoE", "US48PRO2": "USW-Pro-48", "USMINI": "USW-Flex-Mini", "USF5P": "USW-Flex",
        "U7PG2": "UAP-AC-Pro", "U7LT": "UAP-AC-Lite", "U7LR": "UAP-AC-LR", "U7NHD": "UAP-nanoHD",
        "UAL6": "U6-Lite", "UALR6": "U6-LR", "UALR6v2": "U6-LR", "UAP6MP": "U6-Pro", "U6M": "U6-Mesh",
        "U6ENT": "U6-Enterprise", "UDMPRO": "UDM-Pro", "UDMPROSE": "UDM-SE", "UDM": "UDM", "UDR": "UDR",
    ]

    /// Nom commercial du modèle : « model_name » ou « shortname » s'ils existent, sinon la table, sinon le code.
    public static func modelName(_ item: FortiObject) -> String {
        if let name = item.string("model_name", "shortname") { return name }
        guard let code = item.string("model") else { return "" }
        return modelNames[code] ?? code
    }

    /// « Class 4 » → 4.
    static func poeClass(_ value: Any?) -> Int? {
        if let n = FortiJSON.int(value), (0...8).contains(n) { return n }
        guard let text = FortiJSON.string(value), let digit = text.first(where: \.isNumber), let n = Int(String(digit)) else { return nil }
        return n
    }

    /// Switchs et bornes de stat/device. `networks` : identifiant de réseau → VLAN.
    public static func devices(_ data: Data, networks: [String: Int] = [:]) -> (switches: [ControllerSwitch], aps: [ControllerAP])? {
        guard let items = envelope(data)?.items else { return nil }
        var switches: [ControllerSwitch] = []
        var aps: [ControllerAP] = []
        // Rattachement de chaque équipement (uplink : switch et port) pour marquer les ports.
        var uplinks: [(device: MACAddress?, name: String, isAP: Bool, switchMAC: MACAddress?, port: Int?)] = []
        for item in items {
            let type = item.string("type")?.lowercased() ?? ""
            let mac = FortiParse.mac(item.any("mac"))
            let model = modelName(item)
            let name = item.string("name") ?? (model.isEmpty ? (mac?.formatted(.upperColon) ?? "Équipement UniFi") : model)
            let online = item.int("state").map { $0 == 1 } ?? item.bool("adopted")
            let uptime = item.double("uptime")
            let ip = FortiParse.ipv4(item.any("ip"))
            let firmware = item.string("version", "displayable_version") ?? ""
            let serial = item.string("serial") ?? ""
            let portTable = item.list("port_table")
            let radioTable = item.list("radio_table")
            if let uplink = item.object("uplink"), let upMAC = FortiParse.mac(uplink.any("uplink_mac")) {
                uplinks.append((mac, name, type == "uap", upMAC, uplink.int("uplink_remote_port")))
            }
            let isSwitch = type == "usw" || (["udm", "ugw", "uxg", "udr"].contains(type) && portTable.count >= 4)
            if isSwitch {
                let lldp = Dictionary(item.list("lldp_table").compactMap { entry -> (Int, ControllerNeighbor)? in
                    guard let local = entry.int("local_port_idx") else { return nil }
                    let chassis = FortiParse.mac(entry.any("chassis_id"))
                    let label = entry.string("chassis_name", "system_name") ?? chassis?.formatted(.upperColon) ?? "Voisin LLDP"
                    return (local, ControllerNeighbor(name: label, port: entry.string("port_id"), mac: chassis))
                }, uniquingKeysWith: { first, _ in first })
                let ports: [ControllerPort] = portTable.compactMap { p in
                    guard let number = p.int("port_idx") else { return nil }
                    let native = p.string("native_networkconf_id").flatMap { networks[$0] }
                    let tagged = (p.any("tagged_networkconf_ids") as? [Any] ?? []).compactMap { FortiJSON.string($0).flatMap { networks[$0] } }
                    let power = p.double("poe_power")
                    let poeMode = p.string("poe_mode")?.lowercased()
                    return ControllerPort(number: number, name: p.string("name"), linkUp: p.bool("up"), enabled: p.bool("enable"),
                                          speedMbps: p.int("speed").flatMap { $0 > 0 ? UInt64($0) : nil },
                                          fullDuplex: p.bool("full_duplex"), poeCapable: p.bool("port_poe"),
                                          poeEnabled: p.bool("poe_enable") ?? poeMode.map { $0 != "off" },
                                          poePowerW: power.flatMap { $0 >= 0 && $0 <= 1000 ? $0 : nil }, poeClass: poeClass(p.any("poe_class")),
                                          nativeVLAN: native, taggedVLANs: Array(Set(tagged)).sorted(), isUplink: p.bool("is_uplink") ?? false,
                                          neighbor: lldp[number],
                                          rxBytes: p.int("rx_bytes").flatMap { $0 >= 0 ? UInt64($0) : nil },
                                          txBytes: p.int("tx_bytes").flatMap { $0 >= 0 ? UInt64($0) : nil },
                                          rxErrors: p.int("rx_errors").flatMap { $0 >= 0 ? UInt64($0) : nil })
                }.sorted { $0.number < $1.number }
                switches.append(ControllerSwitch(mac: mac, name: name, model: model, firmware: firmware, serial: serial, ip: ip,
                                                 online: online, uptime: uptime, poeBudgetW: item.double("total_max_power"),
                                                 ports: ports))
            }
            if type == "uap" || (!radioTable.isEmpty && type != "usw") {
                let stats = item.list("radio_table_stats")
                let radios: [ControllerRadio] = radioTable.map { radio in
                    let key = radio.string("name")
                    let stat = stats.first { $0.string("name") == key } ?? stats.first { $0.string("radio") == radio.string("radio") }
                    let width = radio.string("ht").flatMap { Int($0.filter(\.isNumber)) }
                    return ControllerRadio(band: band(radio.string("radio")), channel: stat?.int("channel") ?? radio.int("channel"),
                                           widthMHz: width, txPowerDBm: stat?.int("tx_power") ?? radio.int("tx_power"),
                                           clientCount: stat?.int("num_sta"), utilization: stat?.double("cu_total"))
                }
                let ssids = Array(Set(item.list("vap_table").compactMap { $0.string("essid") })).sorted()
                aps.append(ControllerAP(mac: mac, name: name, model: model, firmware: firmware, serial: serial, ip: ip, online: online,
                                        uptime: uptime, radios: radios, clientCount: item.int("num_sta"), ssids: ssids))
            }
        }
        // Uplinks : la borne connaît son switch et son port ; le port du switch reçoit la borne en voisin.
        for link in uplinks {
            guard let switchIndex = switches.firstIndex(where: { $0.mac == link.switchMAC }) else { continue }
            if link.isAP, let apIndex = aps.firstIndex(where: { $0.mac == link.device }) {
                aps[apIndex].uplinkSwitchMAC = link.switchMAC
                aps[apIndex].uplinkSwitchName = switches[switchIndex].name
                aps[apIndex].uplinkPort = link.port
            }
            guard let port = link.port, let portIndex = switches[switchIndex].ports.firstIndex(where: { $0.number == port }) else { continue }
            var neighbor = switches[switchIndex].ports[portIndex].neighbor ?? ControllerNeighbor(name: link.name)
            neighbor.name = link.name
            neighbor.mac = neighbor.mac ?? link.device
            neighbor.isAccessPoint = link.isAP
            neighbor.isInfrastructure = !link.isAP
            switches[switchIndex].ports[portIndex].neighbor = neighbor
        }
        return (switches, aps)
    }

    /// Clients (stat/sta), filaires et Wi-Fi.
    public static func clients(_ data: Data, now: Date = Date()) -> [ControllerClient]? {
        guard let items = envelope(data)?.items else { return nil }
        return items.compactMap { item in
            guard let mac = FortiParse.mac(item.any("mac")) else { return nil }
            let wired = item.bool("is_wired") ?? (item.string("essid") == nil)
            // « signal » est en dBm (négatif) ; « rssi » d'UniFi est un rapport au bruit (positif).
            let signal = item.int("signal").flatMap { $0 < 0 && $0 > -120 ? $0 : nil }
            let rate = item.double("rx_rate", "tx_rate").map { $0 / 1000 }
            return ControllerClient(mac: mac, ip: FortiParse.ipv4(item.any("ip", "last_ip", "fixed_ip")),
                                    hostname: item.string("name", "hostname"), isWired: wired,
                                    ssid: wired ? nil : item.string("essid"), apMAC: wired ? nil : FortiParse.mac(item.any("ap_mac")),
                                    band: wired ? nil : band(item.string("radio")), channel: wired ? nil : item.int("channel"),
                                    rssi: wired ? nil : signal,
                                    switchMAC: wired ? FortiParse.mac(item.any("sw_mac")) : nil, port: wired ? item.int("sw_port") : nil,
                                    vlan: item.int("vlan"), lastSeen: FortiParse.lastSeen(item.any("last_seen"), now: now),
                                    manufacturer: item.string("oui"), rateMbps: wired ? nil : rate)
        }
    }
}
