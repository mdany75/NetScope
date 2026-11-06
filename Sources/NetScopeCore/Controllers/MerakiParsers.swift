import Foundation

// Note 77 : lecture des réponses de l'API Dashboard v1 de Cisco Meraki (organisations, réseaux,
// équipements, états, ports des switchs, état des bornes, clients). Réponses en tableaux JSON ;
// erreurs : { "errors": [ "…" ] }. Fonctions pures, sans réseau.

public enum MerakiParsers {
    /// Messages d'erreur d'une réponse ({ "errors": [ … ] }).
    public static func errors(_ data: Data) -> [String] {
        guard let json = FortiJSON.parse(data) as? [String: Any] else { return [] }
        return (json["errors"] as? [Any] ?? []).compactMap(FortiJSON.string)
    }

    static func array(_ data: Data) -> [FortiObject]? {
        guard let json = FortiJSON.parse(data), let array = json as? [Any] else { return nil }
        return FortiJSON.objects(array)
    }

    /// Organisations ou réseaux : identifiant et nom.
    public static func named(_ data: Data) -> [(id: String, name: String)]? {
        array(data)?.compactMap { item in
            guard let id = item.string("id") else { return nil }
            return (id, item.string("name") ?? id)
        }
    }

    /// Élément voulu (identifiant ou nom, casse ignorée), le premier si rien n'est demandé.
    public static func resolve(_ wanted: String, in list: [(id: String, name: String)]) -> (id: String, name: String)? {
        let key = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { return list.first }
        return list.first { $0.id.lowercased() == key } ?? list.first { $0.name.lowercased() == key }
    }

    /// Famille d'un équipement d'après son modèle ou son type de produit.
    public enum Family: Equatable, Sendable { case switchDevice, accessPoint, other }

    public static func family(model: String, productType: String?) -> Family {
        switch productType?.lowercased() {
        case "switch"?: return .switchDevice
        case "wireless"?: return .accessPoint
        case nil: break
        default: return .other
        }
        let upper = model.uppercased()
        if upper.hasPrefix("MS") || upper.hasPrefix("C9300-M") || upper.hasPrefix("C9300X-M") { return .switchDevice }
        if upper.hasPrefix("MR") || upper.hasPrefix("CW9") { return .accessPoint }
        return .other
    }

    /// Équipement du réseau (GET /networks/{id}/devices).
    public struct Device: Hashable, Sendable {
        public var serial: String
        public var name: String
        public var model: String
        public var mac: MACAddress?
        public var ip: IPv4Address?
        public var firmware: String
        public var family: Family
    }

    public static func devices(_ data: Data) -> [Device]? {
        array(data)?.compactMap { item in
            guard let serial = item.string("serial") else { return nil }
            let model = item.string("model") ?? ""
            return Device(serial: serial, name: item.string("name") ?? (model.isEmpty ? serial : "\(model) \(serial.suffix(4))"),
                          model: model, mac: FortiParse.mac(item.any("mac")), ip: FortiParse.ipv4(item.any("lanIp")),
                          firmware: firmware(item.string("firmware")), family: family(model: model, productType: item.string("productType")))
        }
    }

    /// « wireless-29-7 » → « MR 29.7 » ; « switch-16-4 » → « MS 16.4 ».
    public static func firmware(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let parts = text.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return text }
        let numbers = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }
        guard !numbers.isEmpty else { return text }
        let prefix = ["wireless": "MR", "switch": "MS", "appliance": "MX"][parts[0].lowercased()] ?? parts[0]
        return "\(prefix) \(numbers.joined(separator: "."))"
    }

    /// États (GET /organizations/{id}/devices/statuses) : numéro de série → en ligne.
    public static func statuses(_ data: Data) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for item in array(data) ?? [] {
            guard let serial = item.string("serial"), let status = item.string("status")?.lowercased() else { continue }
            result[serial] = status == "online" || status == "alerting"
        }
        return result
    }

    /// « 1 Gbps » → 1000 ; « 100 Mbps » → 100 ; « 2.5 Gbps » → 2500.
    static func speed(_ text: String?) -> UInt64? {
        guard let text = text?.lowercased(), let value = Double(text.prefix { $0.isNumber || $0 == "." }), value > 0 else { return nil }
        if text.contains("gbps") || text.contains("gb") { return UInt64((value * 1000).rounded()) }
        return UInt64(value.rounded())
    }

    /// Configuration d'un port (GET /devices/{serial}/switch/ports).
    public struct PortConfig: Hashable, Sendable {
        public var name: String?
        public var enabled: Bool?
        public var poeEnabled: Bool?
        public var vlan: Int?
        public var allowedVLANs: [Int]
        public var isTrunk: Bool
    }

    /// « 1,3,5-7 » → [1, 3, 5, 6, 7] ; « all » → [] (trop pour une liste).
    static func vlanList(_ text: String?) -> [Int] {
        guard let text, text.lowercased() != "all" else { return [] }
        var result: [Int] = []
        for token in text.split(separator: ",") {
            let bounds = token.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 1, (1...4094).contains(bounds[0]) { result.append(bounds[0]) }
            if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] < 512 {
                result.append(contentsOf: (bounds[0]...bounds[1]).filter { (1...4094).contains($0) })
            }
        }
        return Array(Set(result)).sorted()
    }

    public static func portConfigs(_ data: Data) -> [String: PortConfig] {
        var result: [String: PortConfig] = [:]
        for item in array(data) ?? [] {
            guard let id = item.string("portId") else { continue }
            let trunk = item.string("type")?.lowercased() == "trunk"
            result[id] = PortConfig(name: item.string("name"), enabled: item.bool("enabled"), poeEnabled: item.bool("poeEnabled"),
                                    vlan: item.int("vlan"), allowedVLANs: trunk ? vlanList(item.string("allowedVlans")) : [],
                                    isTrunk: trunk)
        }
        return result
    }

    /// Ports d'un switch : états (GET …/switch/ports/statuses?timespan=…) et configuration.
    /// La puissance PoE vient de l'énergie livrée pendant `timespan` secondes.
    public static func ports(_ data: Data, configs: [String: PortConfig] = [:], timespan: Double = 300) -> [ControllerPort]? {
        guard let items = array(data) else { return nil }
        var used = Set<Int>()
        return items.enumerated().compactMap { offset, item -> ControllerPort? in
            guard let id = item.string("portId") else { return nil }
            var number = Int(id) ?? Int(id.split(whereSeparator: { !$0.isNumber }).last.map(String.init) ?? "") ?? 1000 + offset
            while used.contains(number) { number += 1000 }
            used.insert(number)
            let config = configs[id]
            let status = item.string("status")?.lowercased()
            let lldp = item.object("lldp")
            let cdp = item.object("cdp")
            var neighbor: ControllerNeighbor?
            if let lldp, let name = lldp.string("systemName", "chassisId") {
                let description = (lldp.string("systemDescription") ?? "").lowercased()
                neighbor = ControllerNeighbor(name: name, port: lldp.string("portId"), mac: FortiParse.mac(lldp.any("chassisId")),
                                              ip: FortiParse.ipv4(lldp.any("managementAddress")),
                                              isAccessPoint: description.contains(" ap") || description.contains("access point")
                                                  || description.contains("meraki mr"),
                                              isInfrastructure: description.contains("switch") || description.contains("meraki ms"))
            } else if let cdp, let name = cdp.string("deviceId", "systemName") {
                let platform = (cdp.string("platform") ?? "").lowercased()
                neighbor = ControllerNeighbor(name: name, port: cdp.string("portId"), ip: FortiParse.ipv4(cdp.any("address", "managementAddress")),
                                              isAccessPoint: platform.contains("mr") || platform.contains("air-"),
                                              isInfrastructure: platform.contains("ms") || platform.contains("ws-c") || platform.contains("c9"))
            }
            let energy = item.double("powerUsageInWh")
            let watts = energy.flatMap { timespan > 0 ? $0 * 3600 / timespan : nil }
            let alerts = ((item.any("errors") as? [Any] ?? []) + (item.any("warnings") as? [Any] ?? [])).compactMap(FortiJSON.string)
            let poeAllocated = item.object("poe")?.bool("isAllocated")
            return ControllerPort(number: number, name: config?.name ?? "Port \(id)", linkUp: status.map { $0 == "connected" },
                                  enabled: item.bool("enabled") ?? config?.enabled, speedMbps: speed(item.string("speed")),
                                  fullDuplex: item.string("duplex").map { $0.lowercased() == "full" },
                                  poeCapable: config?.poeEnabled != nil ? true : nil,
                                  poeEnabled: config?.poeEnabled ?? poeAllocated,
                                  poePowerW: watts.flatMap { $0 >= 0 && $0 <= 1000 ? ($0 * 10).rounded() / 10 : nil },
                                  nativeVLAN: config?.vlan, taggedVLANs: config?.allowedVLANs ?? [],
                                  isUplink: item.bool("isUplink") ?? false, neighbor: neighbor, alerts: alerts)
        }.sorted { $0.number < $1.number }
    }

    /// Radios et SSID d'une borne (GET /devices/{serial}/wireless/status).
    public static func wirelessStatus(_ data: Data) -> (radios: [ControllerRadio], ssids: [String])? {
        guard let json = FortiJSON.parse(data) as? [String: Any] else { return nil }
        let sets = FortiObject(json).list("basicServiceSets")
        var radios: [WifiBand: ControllerRadio] = [:]
        var ssids = Set<String>()
        for set in sets where set.bool("enabled") ?? true {
            if let name = set.string("ssidName"), set.bool("broadcasting") ?? true { ssids.insert(name) }
            let text = (set.string("band") ?? "").lowercased()
            let band: WifiBand? = text.hasPrefix("2.4") ? .ghz24 : (text.hasPrefix("5") ? .ghz5 : (text.hasPrefix("6") ? .ghz6 : nil))
            guard let band, radios[band] == nil else { continue }
            radios[band] = ControllerRadio(band: band, channel: set.int("channel"),
                                           widthMHz: set.string("channelWidth").flatMap { Int($0.prefix { $0.isNumber }) },
                                           txPowerDBm: set.string("power").flatMap { Int($0.prefix { $0.isNumber || $0 == "-" }) })
        }
        return (radios.values.sorted { $0.band!.rawValue < $1.band!.rawValue }, ssids.sorted())
    }

    /// Clients du réseau (GET /networks/{id}/clients). Les équipements servent à nommer la borne
    /// ou le switch de chaque client (recentDeviceSerial).
    public static func clients(_ data: Data, devices: [Device], now: Date = Date()) -> [ControllerClient]? {
        guard let items = array(data) else { return nil }
        let bySerial = Dictionary(devices.map { ($0.serial, $0) }, uniquingKeysWith: { first, _ in first })
        return items.compactMap { item in
            guard let mac = FortiParse.mac(item.any("mac")) else { return nil }
            let connection = item.string("recentDeviceConnection")?.lowercased()
            let device = item.string("recentDeviceSerial").flatMap { bySerial[$0] }
            let wired = connection.map { $0 == "wired" } ?? (item.string("ssid") == nil)
            let caps = (item.string("wirelessCapabilities") ?? "").lowercased()
            let band: WifiBand? = wired ? nil : (caps.contains("6 ghz") ? .ghz6 : (caps.contains("5 ghz") ? .ghz5 : (caps.contains("2.4") ? .ghz24 : nil)))
            let deviceName = item.string("recentDeviceName") ?? device?.name
            let deviceMAC = FortiParse.mac(item.any("recentDeviceMac")) ?? device?.mac
            return ControllerClient(mac: mac, ip: FortiParse.ipv4(item.any("ip")),
                                    hostname: item.string("description", "dhcpHostname", "mdnsName"), isWired: wired,
                                    ssid: wired ? nil : item.string("ssid"), apMAC: wired ? nil : deviceMAC, apName: wired ? nil : deviceName,
                                    band: band, switchMAC: wired ? deviceMAC : nil, switchName: wired ? deviceName : nil,
                                    port: wired ? item.string("switchport").flatMap { Int($0) } : nil,
                                    vlan: item.int("vlan"), lastSeen: FortiParse.lastSeen(item.any("lastSeen"), now: now),
                                    manufacturer: item.string("manufacturer"), os: item.string("os"))
        }
    }

    /// Page suivante d'après l'en-tête Link (« <https://…?startingAfter=…>; rel=next »).
    public static func nextPage(link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard text.lowercased().contains("rel=next") || text.lowercased().contains("rel=\"next\""),
                  let start = text.firstIndex(of: "<"), let end = text.firstIndex(of: ">"), start < end else { continue }
            return URL(string: String(text[text.index(after: start)..<end]))
        }
        return nil
    }
}
