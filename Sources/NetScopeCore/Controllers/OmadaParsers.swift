import Foundation

// Note 77 : lecture des réponses du contrôleur TP-Link Omada (Open API v1 et API web v2 : mêmes
// objets). Enveloppe : { "errorCode": 0, "msg": "Success.", "result": … } ; listes paginées :
// result = { "totalRows", "currentPage", "currentSize", "data": [ … ] }, ou result = [ … ].
// MAC au format « AA-BB-CC-DD-EE-FF ». Fonctions pures, sans réseau.

public enum OmadaParsers {
    /// Code d'erreur, message et contenu « result ».
    public static func envelope(_ data: Data) -> (code: Int, message: String?, result: Any?)? {
        guard let json = FortiJSON.parse(data), let dict = json as? [String: Any] else { return nil }
        let object = FortiObject(dict)
        return (object.int("errorCode") ?? 0, object.string("msg"), object.any("result"))
    }

    /// Objets d'une liste paginée ou d'un tableau.
    public static func list(_ result: Any?) -> [FortiObject] {
        if let array = result as? [Any] { return FortiJSON.objects(array) }
        if let dict = result as? [String: Any] { return FortiObject(dict).list("data") }
        return []
    }

    /// /api/info : identifiant du contrôleur (omadacId) et version.
    public static func info(_ data: Data) -> (omadacID: String?, version: String?)? {
        guard let envelope = envelope(data), let result = envelope.result as? [String: Any] else { return nil }
        let object = FortiObject(result)
        return (object.string("omadacId"), object.string("controllerVer"))
    }

    /// Jeton de l'Open API (accessToken) ou de l'API web (token).
    public static func token(_ data: Data) -> String? {
        guard let envelope = envelope(data), envelope.code == 0, let result = envelope.result as? [String: Any] else { return nil }
        return FortiObject(result).string("accessToken", "token")
    }

    /// Sites : identifiant et nom.
    public static func sites(_ data: Data) -> [(id: String, name: String)]? {
        guard let envelope = envelope(data), envelope.code == 0 else { return nil }
        return list(envelope.result).compactMap { item in
            guard let id = item.string("siteId", "id") else { return nil }
            return (id, item.string("name") ?? id)
        }
    }

    /// Site voulu : par identifiant ou par nom (casse ignorée) ; le premier si rien n'est demandé.
    public static func resolveSite(_ wanted: String, in sites: [(id: String, name: String)]) -> (id: String, name: String)? {
        let key = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { return sites.first }
        return sites.first { $0.id.lowercased() == key } ?? sites.first { $0.name.lowercased() == key }
    }

    /// « 1.0.10 Build 20230309 Rel. 64312 » → « 1.0.10 ».
    public static func shortFirmware(_ text: String?) -> String {
        guard let text else { return "" }
        if let range = text.range(of: #"\d+\.\d+(\.\d+)*"#, options: .regularExpression) { return String(text[range]) }
        return text
    }

    /// « EAP650(US) v1.0 » → « EAP650 ».
    public static func shortModel(_ text: String?) -> String {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return "" }
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        if let space = text.range(of: " v", options: .backwards) { text = String(text[..<space.lowerBound]) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// En ligne : statusCategory 1 (connecté) ; 0 déconnecté, 2 en attente, 3 battement manqué, 4 isolé.
    static func online(_ item: FortiObject) -> Bool? {
        if let category = item.int("statusCategory") { return category == 1 }
        if let status = item.int("status") { return status == 1 || (14...15).contains(status) }
        return nil
    }

    /// Équipements du site : switchs (sans leurs ports, lus à part) et bornes.
    public static func devices(_ data: Data) -> (switches: [ControllerSwitch], aps: [ControllerAP], gateways: Int)? {
        guard let envelope = envelope(data), envelope.code == 0 else { return nil }
        var switches: [ControllerSwitch] = []
        var aps: [ControllerAP] = []
        var gateways = 0
        for item in list(envelope.result) {
            let type = item.string("type")?.lowercased() ?? ""
            let mac = FortiParse.mac(item.any("mac"))
            let model = shortModel(item.string("model", "showModel"))
            let name = item.string("name") ?? (model.isEmpty ? (mac?.formatted(.upperColon) ?? "Équipement Omada") : model)
            let firmware = shortFirmware(item.string("firmwareVersion", "version"))
            let uptime = item.double("uptimeLong")
            switch type {
            case "switch":
                switches.append(ControllerSwitch(mac: mac, name: name, model: model, firmware: firmware, serial: item.string("sn", "serialNumber") ?? "",
                                                 ip: FortiParse.ipv4(item.any("ip")), online: online(item), uptime: uptime,
                                                 poeBudgetW: item.double("totalPower", "poeTotalPower")))
            case "ap":
                var radios: [ControllerRadio] = []
                if let n = item.int("clientNum2g") { radios.append(ControllerRadio(band: .ghz24, clientCount: n)) }
                if let n = item.int("clientNum5g") { radios.append(ControllerRadio(band: .ghz5, clientCount: n)) }
                if let n = item.int("clientNum6g") { radios.append(ControllerRadio(band: .ghz6, clientCount: n)) }
                aps.append(ControllerAP(mac: mac, name: name, model: model, firmware: firmware, serial: item.string("sn", "serialNumber") ?? "",
                                        ip: FortiParse.ipv4(item.any("ip")), online: online(item), uptime: uptime, radios: radios,
                                        clientCount: item.int("clientNum")))
            case "gateway":
                gateways += 1
            default:
                break
            }
        }
        return (switches, aps, gateways)
    }

    /// Canal d'un champ « 44 / 5220MHz » ou d'un nombre.
    static func channel(_ value: Any?) -> Int? {
        if let n = FortiJSON.int(value), n > 0, n < 300 { return n }
        guard let text = FortiJSON.string(value) else { return nil }
        let head = text.prefix { $0.isNumber }
        return Int(head).flatMap { $0 > 0 && $0 < 300 ? $0 : nil }
    }

    /// Détail d'une borne : radios (wp2g, wp5g, wp5g2, wp6g), SSID, rattachement au switch.
    public static func apDetail(_ data: Data, into ap: ControllerAP) -> ControllerAP {
        guard let envelope = envelope(data), envelope.code == 0, let result = envelope.result as? [String: Any] else { return ap }
        let object = FortiObject(result)
        var copy = ap
        var radios: [ControllerRadio] = []
        for (key, band) in [("wp2g", WifiBand.ghz24), ("wp5g", .ghz5), ("wp5g2", .ghz5), ("wp6g", .ghz6)] {
            guard let radio = object.object(key) else { continue }
            let width = radio.string("bandWidth", "channelWidth").flatMap { Int($0.filter(\.isNumber)) }
            let count = radio.int("clientNum") ?? ap.radios.first { $0.band == band }?.clientCount
            radios.append(ControllerRadio(band: band, channel: channel(radio.any("actualChannel", "channel")), widthMHz: width,
                                          txPowerDBm: radio.int("txPower"), clientCount: count,
                                          utilization: radio.double("channelUtil", "chUtil")))
        }
        if !radios.isEmpty { copy.radios = radios }
        let ssids = object.list("ssidOverrides", "ssids").compactMap { $0.string("ssid", "name") }
        if !ssids.isEmpty { copy.ssids = Array(Set(ssids)).sorted() }
        if let uplink = object.object("wiredUplink", "uplink") {
            copy.uplinkSwitchMAC = FortiParse.mac(uplink.any("uplinkMac", "switchMac", "mac"))
            copy.uplinkSwitchName = uplink.string("uplinkDeviceName", "switchName", "name")
            copy.uplinkPort = uplink.int("uplinkPort", "port")
        }
        return copy
    }

    /// Vitesse d'un port : code de l'API (1 : 10 Mb/s, 2 : 100, 3 : 1 000, 4 : 2 500, 5 : 10 000,
    /// 6 : 5 000) ou texte (« 1000M », « 10G »).
    static func speed(_ value: Any?) -> UInt64? {
        if let code = FortiJSON.int(value), code < 10 {
            return [1: 10, 2: 100, 3: 1000, 4: 2500, 5: 10_000, 6: 5000][code]
        }
        return FortiParse.speedMbps(value)
    }

    /// Ports d'un switch.
    public static func ports(_ data: Data) -> [ControllerPort]? {
        guard let envelope = envelope(data), envelope.code == 0 else { return nil }
        return list(envelope.result).compactMap { item in
            guard let number = item.int("port", "portId", "id") else { return nil }
            let status = item.object("portStatus") ?? item
            let linkUp = status.int("linkStatus").map { $0 == 1 } ?? status.bool("linkStatus", "link")
            let disabled = item.bool("disable")
            let power = status.double("poePower", "power")
            let neighbor = item.object("neighbor", "lldpNeighbor").map { n in
                ControllerNeighbor(name: n.string("systemName", "deviceName", "name") ?? "Voisin LLDP", port: n.string("portId", "port"),
                                   mac: FortiParse.mac(n.any("chassisId", "mac")), ip: FortiParse.ipv4(n.any("managementAddress", "ip")))
            }
            return ControllerPort(number: number, name: item.string("name"), linkUp: linkUp, enabled: disabled.map { !$0 },
                                  speedMbps: speed(status.any("linkSpeed", "speed")),
                                  fullDuplex: status.int("duplex").map { $0 == 2 } ?? status.string("duplex").map { $0.lowercased().contains("full") },
                                  poeCapable: item.bool("supportPoe", "poeSupport"), poeEnabled: item.bool("poe", "poeEnable"),
                                  poePowerW: power.flatMap { $0 >= 0 && $0 <= 1000 ? $0 : nil },
                                  nativeVLAN: item.int("nativeVlanId", "pvid", "nativeVlan"),
                                  isUplink: item.bool("uplink", "isUplink") ?? false, neighbor: neighbor,
                                  rxBytes: status.int("rx").flatMap { $0 >= 0 ? UInt64($0) : nil },
                                  txBytes: status.int("tx").flatMap { $0 >= 0 ? UInt64($0) : nil },
                                  rxErrors: status.int("rxErrors", "rxErr").flatMap { $0 >= 0 ? UInt64($0) : nil })
        }.sorted { $0.number < $1.number }
    }

    /// Bande d'un numéro de radio Omada (0 : 2,4 GHz, 1 et 2 : 5 GHz, 3 : 6 GHz).
    static func band(radioID: Int?) -> WifiBand? {
        switch radioID {
        case 0?: return .ghz24
        case 1?, 2?: return .ghz5
        case 3?: return .ghz6
        default: return nil
        }
    }

    /// Clients du site.
    public static func clients(_ data: Data, now: Date = Date()) -> [ControllerClient]? {
        guard let envelope = envelope(data), envelope.code == 0 else { return nil }
        return list(envelope.result).compactMap { item in
            guard let mac = FortiParse.mac(item.any("mac")) else { return nil }
            let wireless = item.bool("wireless") ?? (item.string("ssid") != nil)
            let rssi = item.int("rssi").flatMap { $0 < 0 && $0 > -120 ? $0 : nil }
            let channel = item.int("channel")
            let band = band(radioID: item.int("radioId")) ?? channel.map { WifiBand.guess(channel: $0) }
            return ControllerClient(mac: mac, ip: FortiParse.ipv4(item.any("ip")), hostname: item.string("name", "hostName"),
                                    isWired: !wireless, ssid: wireless ? item.string("ssid") : nil,
                                    apMAC: wireless ? FortiParse.mac(item.any("apMac")) : nil,
                                    apName: wireless ? item.string("apName") : nil, band: wireless ? band : nil,
                                    channel: wireless ? channel : nil, rssi: wireless ? rssi : nil,
                                    signalPercent: wireless ? item.int("signalLevel") : nil,
                                    switchMAC: wireless ? nil : FortiParse.mac(item.any("switchMac")),
                                    switchName: wireless ? nil : item.string("switchName"), port: wireless ? nil : item.int("port"),
                                    vlan: item.int("vid", "vlan"), lastSeen: FortiParse.lastSeen(item.any("lastSeen"), now: now),
                                    manufacturer: item.string("vendor", "manufacturer"), os: item.string("osName", "os"),
                                    rateMbps: wireless ? item.double("rxRate").map { $0 / 1000 } : nil)  // kb/s
        }
    }
}
