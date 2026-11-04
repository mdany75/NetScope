import Foundation

// Analyse des réponses de chaque appel. Chaque analyseur accepte l'enveloppe { results: … } ou
// la réponse nue, plusieurs noms de champ (selon la version de FortiOS) et des champs absents.
// Noms relevés dans la documentation publique de FortiOS (FNDN), les modules Ansible fortios,
// hfortix et les exemples de la communauté Fortinet ; ce qui n'est pas documenté est lu de façon
// défensive et gardé dans la réponse brute pour ajuster après l'essai réel.

public enum FortiParsers {
    // MARK: Système

    /// /api/v2/monitor/system/status : « results » (model_name, model_number, model, hostname) et
    /// enveloppe (version, build, serial, vdom). Certaines versions mettent tout dans « results ».
    public static func system(_ data: Data) -> FortiGateSystem? {
        guard let json = FortiJSON.parse(data) else { return nil }
        let envelope = FortiJSON.envelope(json)
        let results = FortiJSON.objects(FortiJSON.results(json)).first
        guard envelope != nil || results != nil else { return nil }
        func pick(_ names: String...) -> String? {
            results.flatMap { FortiJSON.string($0.value(names)) } ?? envelope.flatMap { FortiJSON.string($0.value(names)) }
        }
        let hostname = pick("hostname", "host_name", "name") ?? ""
        var model = ""
        let modelName = pick("model_name") ?? ""
        let modelNumber = pick("model_number") ?? ""
        if !modelName.isEmpty, !modelNumber.isEmpty {
            model = "\(modelName)-\(modelNumber)"
        } else if let code = pick("model", "platform", "platform_type") {
            // « FGT100F » → « FortiGate-100F ».
            model = code.uppercased().hasPrefix("FGT") ? "FortiGate-" + code.dropFirst(3) : code
        } else {
            model = modelName
        }
        let version = pick("version", "firmware_version", "os_version") ?? ""
        let serial = pick("serial", "serial_number", "sn") ?? ""
        let build = (results?.int("build")) ?? envelope?.int("build")
        guard !hostname.isEmpty || !model.isEmpty || !serial.isEmpty || !version.isEmpty else { return nil }
        return FortiGateSystem(hostname: hostname, model: model, serial: serial, version: version.isEmpty ? "" : version,
                               build: build, vdom: envelope?.string("vdom"))
    }

    // MARK: FortiSwitch gérés (état)

    /// /api/v2/monitor/switch-controller/managed-switch/status (7.x) ou
    /// /api/v2/monitor/switch-controller/managed-switch (6.4) : liste des switchs, ou dictionnaire
    /// indexé par le numéro de série.
    public static func managedSwitches(_ data: Data) -> [FortiManagedSwitch]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        let items = FortiJSON.objects(FortiJSON.results(json))
        if items.isEmpty { return (json is [String: Any] || json is [Any]) ? [] : nil }
        return items.compactMap(managedSwitch)
    }

    static func managedSwitch(_ item: FortiObject) -> FortiManagedSwitch? {
        let serial = item.string("serial", "sn", "serial_number", "fsw_serial") ?? ""
        let id = item.string("switch-id", "switch_id", "switchid", "name", "_key") ?? serial
        guard !id.isEmpty else { return nil }
        let name = item.string("name", "switch-id", "switch_id", "_key") ?? id
        let os = item.string("os_version", "os-version", "version", "firmware", "fsw_version") ?? ""
        let modelText = item.string("model", "model_name", "platform", "switch_model")
        let model = modelText.map(normalizedModel) ?? FortiParse.fortiSwitchModel(serial: serial.isEmpty ? id : serial)
            ?? modelFromOS(os) ?? ""
        let statusText = item.string("status", "connection_status", "state_connection")?.lowercased()
        var connected: Bool?
        if let s = statusText {
            if s.contains("disconn") || s == "down" || s.contains("offline") { connected = false }
            else if s.contains("conn") || s == "up" || s.contains("online") { connected = true }
        }
        if connected == nil { connected = item.bool("is_connected", "connected", "up") }
        let ip = FortiParse.ipv4(item.any("connecting_from", "connecting-from", "fsw_ip", "ip", "mgmt_ip", "ip_address", "ipv4_address"))
        let ports = item.list("ports", "port", "interfaces").enumerated().compactMap { offset, port in
            switchPort(port, fallbackNumber: offset + 1)
        }
        let budget = item.double("max_poe_budget", "poe_budget", "max-poe-budget", "total_poe_budget", "poe_power_budget")
        return FortiManagedSwitch(switchID: id, serial: serial, name: name, model: model, osVersion: os, connected: connected,
                                  state: item.string("state", "authorization", "authorized"),
                                  fortilinkIP: ip, description: item.string("description"), poeBudgetW: budget, ports: ports)
    }

    /// « FS248EP », « FortiSwitch-248E-POE », « S248EP » → « FS-248E-POE ».
    static func normalizedModel(_ text: String) -> String {
        let upper = text.uppercased()
        if upper.hasPrefix("FS-") { return upper }
        if upper.hasPrefix("FORTISWITCH-") { return "FS-" + upper.dropFirst("FORTISWITCH-".count) }
        if upper.hasPrefix("FS"), let m = FortiParse.fortiSwitchModel(serial: "S" + upper.dropFirst(2)) { return m }
        if let m = FortiParse.fortiSwitchModel(serial: upper) { return m }
        return text
    }

    /// « S248EP-v7.2.5-build0453 » → « FS-248E-POE ».
    static func modelFromOS(_ os: String) -> String? {
        let head = os.split(separator: "-").first.map(String.init) ?? ""
        return FortiParse.fortiSwitchModel(serial: head)
    }

    static func switchPort(_ port: FortiObject, fallbackNumber: Int) -> FortiSwitchPort? {
        guard let name = port.string("interface", "port-name", "port_name", "name", "port", "_key") else { return nil }
        let number = FortiParse.portNumber(name) ?? fallbackNumber
        let statusText = port.string("status", "link_status", "link", "oper_status")?.lowercased()
        var link: Bool?
        if let s = statusText { link = s.hasPrefix("up") ? true : (s.hasPrefix("down") ? false : nil) }
        let speedValue = port.any("speed", "link_speed", "speed_mbps", "actual_speed")
        let vlanName = port.string("vlan", "native_vlan", "native-vlan", "vlan_name", "access_vlan")
        let poeState = port.string("poe_status_text", "power_status", "poe_state", "poe-status-text", "poe_detection", "poe_status")
        // « poe_status » vaut « enable »/« disable » en configuration, un état en surveillance.
        let poeFlag = port.bool("poe_enabled", "poe-status", "poe_status", "poe_admin")
        let fortilink = port.bool("fortilink_port", "fortilink-port", "is_fortilink", "fgt_peer") == true
            || port.string("fgt_peer_port_name", "fgt_peer_device_name", "fgt-peer-port-name") != nil
        let peer = port.string("isl_peer_device_name", "isl-peer-device-name", "isl_peer_device", "fgt_peer_device_name",
                               "peer_device_name", "lldp_neighbor")
        let isl = port.string("isl_peer_device_name", "isl-peer-device-name", "isl_peer_port_name", "isl-local-trunk-name",
                              "isl_local_trunk_name") != nil
            || (port.string("type", "port_type")?.lowercased() == "trunk" && peer != nil)
        let power = port.double("port_power", "poe_power", "power", "power_consumption", "poe_power_consumption", "consumed_power")
        return FortiSwitchPort(
            name: name, number: number, linkUp: link,
            adminUp: port.bool("admin_status", "admin-status", "admin", "enabled"),
            speedMbps: link == false ? nil : FortiParse.speedMbps(speedValue),
            duplex: FortiParse.duplex(speedValue, port.any("duplex")),
            nativeVLAN: vlanName, nativeVLANID: port.int("vlan_id", "vlanid", "native_vlan_id") ?? FortiParse.vlanID(fromName: vlanName),
            description: port.string("description", "alias"),
            poeCapable: port.bool("poe_capable", "poe-capable", "poe_supported") ?? (power != nil ? true : nil),
            poeEnabled: poeFlag, poeState: poeState.flatMap { FortiJSON.bool($0) == nil ? $0 : nil },
            poePowerW: power, poeClass: port.int("poe_class", "class", "power_class", "poe-class"),
            isFortiLink: fortilink, isISL: isl, peerName: peer,
            rxBytes: port.int("rx_bytes", "rx-bytes", "in_bytes").flatMap(nonNegative),
            txBytes: port.int("tx_bytes", "tx-bytes", "out_bytes").flatMap(nonNegative),
            rxErrors: port.int("rx_errors", "rx-errors", "in_errors", "crc_alignments").flatMap(nonNegative))
    }

    static func nonNegative(_ value: Int) -> UInt64? { value >= 0 ? UInt64(value) : nil }

    // MARK: Configuration (cmdb)

    /// Configuration d'un port (/api/v2/cmdb/switch-controller/managed-switch).
    public struct PortConfig: Hashable, Sendable {
        public var description: String?
        public var nativeVLAN: String?
        public var adminUp: Bool?
        public var poeEnabled: Bool?
        public var isFortiLink: Bool
        public var isISL: Bool
    }

    /// Ports configurés, par switch (clé : switch-id en minuscules) puis par nom de port (minuscules).
    public static func switchConfig(_ data: Data) -> [String: (name: String?, description: String?, ports: [String: PortConfig])]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [String: (name: String?, description: String?, ports: [String: PortConfig])] = [:]
        for item in FortiJSON.objects(FortiJSON.results(json)) {
            guard let id = item.string("switch-id", "switch_id", "name", "sn", "_key") else { continue }
            var ports: [String: PortConfig] = [:]
            for port in item.list("ports") {
                guard let name = port.string("port-name", "port_name", "name", "interface") else { continue }
                let fortilink = port.bool("fortilink-port", "fortilink_port") == true
                let isl = port.string("isl-local-trunk-name", "isl_local_trunk_name", "isl-peer-device-name") != nil
                ports[name.lowercased()] = PortConfig(description: port.string("description"),
                                                      nativeVLAN: port.string("vlan", "native-vlan"),
                                                      adminUp: port.bool("status", "admin-status"),
                                                      poeEnabled: port.bool("poe-status", "poe_status"),
                                                      isFortiLink: fortilink, isISL: isl)
            }
            let entry = (name: item.string("name"), description: item.string("description"), ports: ports)
            for key in [id, item.string("sn"), item.string("name")].compactMap({ $0?.lowercased() }) { result[key] = entry }
        }
        return result
    }

    // MARK: Statistiques et PoE des ports

    /// Compteurs par switch puis par port : /monitor/switch-controller/managed-switch/port-stats.
    /// Formes acceptées : [{ serial, ports: { port1: {…} } }], { S248…: { port1: {…} } },
    /// [{ switch_id, port, rx_bytes… }].
    public static func portStats(_ data: Data) -> [String: [String: (rx: UInt64?, tx: UInt64?, errors: UInt64?)]]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [String: [String: (rx: UInt64?, tx: UInt64?, errors: UInt64?)]] = [:]
        func counters(_ o: FortiObject) -> (rx: UInt64?, tx: UInt64?, errors: UInt64?) {
            let rxErr = o.int("rx-errors", "rx_errors", "in_errors").flatMap(nonNegative)
            let crc = o.int("crc-alignments", "crc_alignments").flatMap(nonNegative)
            let errors: UInt64? = (rxErr == nil && crc == nil) ? nil : (rxErr ?? 0) + (crc ?? 0)
            return (o.int("rx-bytes", "rx_bytes", "in_bytes").flatMap(nonNegative), o.int("tx-bytes", "tx_bytes", "out_bytes").flatMap(nonNegative), errors)
        }
        for item in FortiJSON.objects(FortiJSON.results(json)) {
            if let id = item.string("switch-id", "switch_id", "serial", "sn", "_key"), let ports = item.object("ports", "port_stats", "stats") {
                for port in FortiJSON.objects(ports.raw) {
                    guard let name = port.string("_key", "interface", "name") else { continue }
                    result[id.lowercased(), default: [:]][name.lowercased()] = counters(port)
                }
            } else if let id = item.string("switch-id", "switch_id", "serial"), let name = item.string("port", "interface", "port_name") {
                result[id.lowercased(), default: [:]][name.lowercased()] = counters(item)
            } else if let id = item.string("_key") {
                // { S248…: { port1: {…}, port2: {…} } }
                for port in FortiJSON.objects(item.raw.filter { $0.key != "_key" }) {
                    guard let name = port.string("_key") else { continue }
                    result[id.lowercased(), default: [:]][name.lowercased()] = counters(port)
                }
            }
        }
        return result
    }

    /// PoE par switch puis par port (même formes que les statistiques) : puissance (W), état, classe.
    public static func poe(_ data: Data) -> [String: [String: (power: Double?, state: String?, powerClass: Int?)]]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [String: [String: (power: Double?, state: String?, powerClass: Int?)]] = [:]
        func values(_ o: FortiObject) -> (power: Double?, state: String?, powerClass: Int?) {
            (o.double("power_consumption", "port_power", "power", "poe_power", "consumed_power"),
             o.string("status", "power_status", "poe_status", "state", "detection"),
             o.int("class", "poe_class", "power_class"))
        }
        for item in FortiJSON.objects(FortiJSON.results(json)) {
            let id = item.string("switch-id", "switch_id", "serial", "sn", "_key")
            if let id, let ports = item.value(["ports", "poe", "port_poe"]) {
                for port in FortiJSON.objects(ports) {
                    guard let name = port.string("interface", "port", "name", "port_name", "_key") else { continue }
                    result[id.lowercased(), default: [:]][name.lowercased()] = values(port)
                }
            } else if let id, let name = item.string("interface", "port", "port_name") {
                result[id.lowercased(), default: [:]][name.lowercased()] = values(item)
            }
        }
        return result
    }

    // MARK: Appareils détectés, ARP, DHCP, inventaire

    /// /api/v2/monitor/switch-controller/detected-device : MAC → switch, port, VLAN, dernière vue.
    public static func detectedDevices(_ data: Data, now: Date) -> [FortiDetectedDevice]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        return FortiJSON.objects(FortiJSON.results(json)).compactMap { item in
            guard let mac = FortiParse.mac(item.any("mac", "mac_address", "macaddr", "mac-address")),
                  let sw = item.string("switch_id", "switch-id", "switchid", "switch_serial", "serial", "switch", "fortiswitch_id", "switch_name"),
                  let port = item.string("port_name", "port-name", "port", "interface", "port_id", "switch_port") else { return nil }
            // « port_id » numérique seul : « port5 ».
            let portName = Int(port) != nil ? "port\(port)" : port
            return FortiDetectedDevice(mac: mac, switchID: sw, portName: portName,
                                       vlan: item.int("vlan_id", "vlan-id", "vlanid", "vlan") ?? FortiParse.vlanID(fromName: item.string("vlan", "vlan_name")),
                                       lastSeen: FortiParse.lastSeen(item.any("last_seen", "last-seen", "lastseen", "age", "update_time"), now: now),
                                       ip: FortiParse.ipv4(item.any("ip", "ipv4_address", "ip_address")),
                                       name: item.string("device_name", "hostname", "host", "name"))
        }
    }

    /// /api/v2/monitor/network/arp : [{ ip, mac, interface, age }].
    public static func arp(_ data: Data) -> [FortiARPEntry]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        return FortiJSON.objects(FortiJSON.results(json)).compactMap { item in
            guard let ip = FortiParse.ipv4(item.any("ip", "address", "ipv4", "ip_address")),
                  let mac = FortiParse.mac(item.any("mac", "mac_address", "hwaddr")), !mac.isMulticast else { return nil }
            return FortiARPEntry(ip: ip, mac: mac, interface: item.string("interface", "intf", "_key"))
        }
    }

    /// /api/v2/monitor/system/dhcp : baux (liste, ou dictionnaire de listes par interface).
    public static func dhcpLeases(_ data: Data) -> [FortiDHCPLease]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        return FortiJSON.objects(FortiJSON.results(json)).compactMap { item in
            guard let ip = FortiParse.ipv4(item.any("ip", "address", "ipv4")),
                  let mac = FortiParse.mac(item.any("mac", "mac_address", "hwaddr")) else { return nil }
            var expires: Date?
            if let t = item.double("expire_time", "expire", "expiry", "lease_expires"), t > 1_000_000_000 {
                expires = Date(timeIntervalSince1970: t)
            }
            return FortiDHCPLease(ip: ip, mac: mac, hostname: item.string("hostname", "host", "client_name", "name"),
                                  interface: item.string("interface", "intf", "_key"), expires: expires,
                                  reserved: item.bool("reserved", "is_reserved") ?? false)
        }
    }

    /// /api/v2/monitor/user/device/query : inventaire des appareils (nom, fabricant, système, port).
    public static func userDevices(_ data: Data) -> [FortiUserDevice]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        return FortiJSON.objects(FortiJSON.results(json)).compactMap { item in
            guard let mac = FortiParse.mac(item.any("mac", "master_mac", "mac_address")) else { return nil }
            let port = item.string("fortiswitch_port_name", "fortiswitch_port", "switch_port", "port_name", "detected_port")
            return FortiUserDevice(mac: mac, ip: FortiParse.ipv4(item.any("ipv4_address", "ip", "ip_address", "ipv4")),
                                   hostname: item.string("hostname", "host", "device_name", "user_name_alias", "alias"),
                                   vendor: item.string("hardware_vendor", "vendor", "manufacturer"),
                                   os: item.string("os_name", "os"),
                                   switchID: item.string("fortiswitch_id", "fortiswitch", "switch_id", "fortiswitch_serial"),
                                   portName: port.map { Int($0) != nil ? "port\($0)" : $0 },
                                   vlan: item.int("fortiswitch_vlan_id", "vlan_id", "vlan"))
        }
    }

    // MARK: Erreur dans un corps 200

    /// FortiOS répond parfois 200 avec { "status": "error", "http_status": 403, … }.
    public static func embeddedError(_ data: Data) -> (status: Int?, message: String)? {
        guard let envelope = FortiJSON.envelope(FortiJSON.parse(data)),
              envelope.string("status")?.lowercased() == "error" else { return nil }
        let message = envelope.string("error", "message", "cli_error") ?? "erreur sans détail"
        return (envelope.int("http_status", "status_code"), message)
    }

    /// Nombre d'éléments de la réponse (pour le diagnostic).
    public static func itemCount(_ data: Data) -> Int? {
        guard let json = FortiJSON.parse(data) else { return nil }
        let inner = FortiJSON.results(json)
        if let list = inner as? [Any] { return list.count }
        if inner is [String: Any] { return FortiJSON.objects(inner).count }
        return nil
    }
}
