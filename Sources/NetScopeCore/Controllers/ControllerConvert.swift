import Foundation

// Note 77 : conversion de la lecture d'un contrôleur vers les modèles de NetScope, comme pour la
// FortiGate : un relevé de switch (`SNMPSwitchSnapshot`) par switch géré (façade, ports, PoE,
// VLAN, voisins, appareils par port), emplacement switch/port des appareils filaires du scan,
// borne et « Wi-Fi » pour les clients sans fil, noms, table IP → MAC, et clients Wi-Fi au format
// de la reconnaissance Wi-Fi de la note 84 (`FortiWifiOverview`). Fonctions pures, sans réseau.

public enum ControllerConvert {
    // MARK: Relevés de switch

    /// Un relevé par switch géré de chaque lecture, marqué du site (`controllerName`) et de la
    /// marque (`controllerKind`). Un switch sans adresse (ou dont l'adresse est déjà prise) reçoit une
    /// adresse de remplacement 0.c.x.y, jamais interrogée.
    public static func snapshots(_ readings: [ControllerSiteReading], avoiding taken: Set<IPv4Address> = []) -> [SNMPSwitchSnapshot] {
        var used = taken
        var result: [SNMPSwitchSnapshot] = []
        for (readingIndex, reading) in readings.enumerated() {
            for (offset, sw) in reading.report.switches.enumerated() {
                var host = sw.ip ?? IPv4Address(UInt32(0xC0 + readingIndex) << 16 | UInt32(offset + 1))
                if used.contains(host) {
                    host = IPv4Address(UInt32(0xC0 + readingIndex) << 16 | UInt32(offset + 1))
                    while used.contains(host) { host = IPv4Address((host.value &+ 1) & 0x00FF_FFFF) }
                }
                used.insert(host)
                result.append(snapshot(sw, host: host, report: reading.report, label: reading.siteName))
            }
        }
        return result
    }

    /// Relevé d'un switch : index d'interface = numéro du port.
    public static func snapshot(_ sw: ControllerSwitch, host: IPv4Address, report: ControllerReport, label: String) -> SNMPSwitchSnapshot {
        var interfaces: [SNMPInterface] = []
        var pvid: [Int: Int] = [:]
        var neighbors: [SNMPLLDPNeighbor] = []
        var poe: [SNMPPoEPort] = []
        var used = Set<Int>()
        var indexByPort: [Int: Int] = [:]
        for port in sw.ports.sorted(by: { $0.number < $1.number }) {
            var index = max(port.number, 1)
            while used.contains(index) { index += 1000 }
            used.insert(index)
            indexByPort[port.number] = index
            let oper: SNMPOperStatus = port.linkUp == true ? .up : (port.linkUp == false ? .down : .unknown)
            let alias = port.name == "Port \(port.number)" ? "" : port.name
            interfaces.append(SNMPInterface(index: index, name: "Port \(port.number)", descr: port.name, alias: alias, type: 6,
                                            adminUp: port.enabled ?? true, operStatus: oper, speedMbps: port.speedMbps,
                                            inErrors: port.rxErrors, inOctets: port.rxBytes, outOctets: port.txBytes))
            if let vlan = port.nativeVLAN { pvid[index] = vlan }
            if let neighbor = port.neighbor {
                let caps: SNMPLLDPCapabilities = neighbor.isAccessPoint ? [.accessPoint] : (neighbor.isInfrastructure || port.isUplink ? [.bridge] : [])
                neighbors.append(SNMPLLDPNeighbor(localPortNum: index, ifIndex: index, sysName: neighbor.name, portID: neighbor.port ?? "",
                                                  portDescr: neighbor.port,
                                                  sysDescr: neighbor.isAccessPoint ? "Borne \(report.kind.brand) · \(neighbor.name)" : nil,
                                                  capabilities: caps.isEmpty ? nil : caps))
            } else if port.isUplink {
                // Uplink sans voisin connu : marqué comme lien vers l'infrastructure (jamais un poste).
                neighbors.append(SNMPLLDPNeighbor(localPortNum: index, ifIndex: index, sysName: "Uplink", portID: "uplink",
                                                  portDescr: "Uplink", sysDescr: "Lien montant (\(report.kind.label))",
                                                  capabilities: [.bridge, .router]))
            }
            if port.poeCapable == true || port.poePowerW != nil || port.poeEnabled == true {
                let detection: PoEDetectionStatus? = port.poeEnabled == false ? .disabled
                    : (port.deliversPoE ? .deliveringPower : (port.alerts.contains(where: Self.isPoEFault) ? .fault : .searching))
                poe.append(SNMPPoEPort(group: 1, port: port.number, ifIndex: index, adminEnabled: port.poeEnabled, detection: detection,
                                       powerClass: port.poeClass, consumptionMW: port.poePowerW.map { Int(($0 * 1000).rounded()) },
                                       wattsSource: report.kind.shortLabel))
            }
        }
        // Table MAC : clients filaires du contrôleur sur ce switch, puis les bornes branchées.
        var fdb: [SNMPFDBEntry] = []
        var arp: [MACAddress: IPv4Address] = [:]
        var seen = Set<MACAddress>()
        for client in report.wiredClients {
            guard belongs(client, to: sw), let number = client.port, let index = indexByPort[number], seen.insert(client.mac).inserted else { continue }
            fdb.append(SNMPFDBEntry(mac: client.mac, vlan: client.vlan ?? pvid[index], bridgePort: index, ifIndex: index))
            if let ip = client.ip { arp[client.mac] = ip }
        }
        for ap in report.aps {
            guard let mac = ap.mac, let number = ap.uplinkPort, let index = indexByPort[number], seen.insert(mac).inserted,
                  (ap.uplinkSwitchMAC != nil && ap.uplinkSwitchMAC == sw.mac) || (ap.uplinkSwitchName?.lowercased() == sw.name.lowercased()) else { continue }
            fdb.append(SNMPFDBEntry(mac: mac, vlan: pvid[index], bridgePort: index, ifIndex: index))
            if let ip = ap.ip { arp[mac] = ip }
        }
        let model = sw.model.isEmpty ? "switch" : sw.model
        // « version 6.6.61 » : lu par la colonne Firmware comme un sysDescr ; « MS 16.7 » → « 16.7 ».
        let version = sw.firmware.split(separator: " ").last.map(String.init) ?? ""
        var descr = "\(report.kind.brand) \(model), \(version.isEmpty ? "version inconnue" : "version \(version)")"
        if !sw.serial.isEmpty { descr += " · série \(sw.serial)" }
        descr += " · géré par \(report.kind.label)"
        let ticks = sw.uptime.flatMap { $0 >= 0 && $0 < 4.0e7 ? UInt32($0 * 100) : nil }
        let system = SNMPSystemInfo(name: sw.name, descr: descr, objectID: report.kind.objectID, uptimeTicks: ticks)
        let usedW = poe.compactMap(\.consumptionMW)
        var snapshot = SNMPSwitchSnapshot(host: host, system: system, interfaces: interfaces, fdb: fdb, neighbors: neighbors, pvid: pvid,
                                          poePorts: Set(poe.filter(\.isDelivering).compactMap(\.ifIndex)),
                                          poeBudgetW: sw.poeBudgetW.flatMap { $0.isFinite && $0 > 0 && $0 <= 100_000 ? Int($0.rounded()) : nil },
                                          poeUsedW: usedW.isEmpty ? nil : Int((Double(usedW.reduce(0, +)) / 1000).rounded()),
                                          poeDetails: poe.isEmpty ? [] : poe, arp: arp, polledAt: report.readAt, controllerName: label)
        snapshot.controllerKind = report.kind.shortLabel
        snapshot.hardware = SNMPHardwareInfo(model: sw.model.isEmpty ? nil : sw.model, serial: sw.serial.isEmpty ? nil : sw.serial,
                                             firmware: sw.firmware.isEmpty ? nil : sw.firmware, vendor: report.kind.brand,
                                             origin: report.kind.label)
        return snapshot
    }

    /// Alerte de défaut PoE (« PoE overload », « PoE denied ») ; « aucun appareil PoE » n'en est pas une.
    static func isPoEFault(_ alert: String) -> Bool {
        let text = alert.lowercased()
        return text.contains("poe") && ["overload", "fault", "denied", "error", "surcharge", "défaut"].contains { text.contains($0) }
    }

    /// Client filaire branché sur ce switch (MAC du switch, sinon son nom).
    static func belongs(_ client: ControllerClient, to sw: ControllerSwitch) -> Bool {
        if let mac = client.switchMAC, let swMAC = sw.mac { return mac == swMAC }
        if let name = client.switchName { return name.lowercased() == sw.name.lowercased() }
        return false
    }

    // MARK: Noms et adresses

    /// Nom de chaque MAC connu des contrôleurs (clients, switchs, bornes) ; le premier l'emporte.
    public static func names(_ readings: [ControllerSiteReading]) -> [MACAddress: String] {
        var result: [MACAddress: String] = [:]
        func add(_ mac: MACAddress?, _ name: String?) {
            guard let mac, let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, result[mac] == nil else { return }
            if MACAddress(name) != nil || IPv4Address(name) != nil { return }
            result[mac] = name
        }
        for reading in readings {
            for sw in reading.report.switches { add(sw.mac, sw.name) }
            for ap in reading.report.aps { add(ap.mac, ap.name) }
            for client in reading.report.clients { add(client.mac, client.hostname) }
        }
        return result
    }

    /// Table IP → MAC (clients et équipements) : complète les MAC des appareils d'autres VLAN.
    public static func arpTable(_ readings: [ControllerSiteReading]) -> [IPv4Address: MACAddress] {
        var result: [IPv4Address: MACAddress] = [:]
        for reading in readings {
            for client in reading.report.clients { if let ip = client.ip, result[ip] == nil { result[ip] = client.mac } }
            for sw in reading.report.switches { if let ip = sw.ip, let mac = sw.mac, result[ip] == nil { result[ip] = mac } }
            for ap in reading.report.aps { if let ip = ap.ip, let mac = ap.mac, result[ip] == nil { result[ip] = mac } }
        }
        return result
    }

    /// Port « Wi-Fi » d'un client sans fil, comme les appareils rattachés à leur borne (note 84).
    public static let wifiPort = "Wi-Fi"

    /// Tout ce que les lectures apportent aux appareils du scan : MAC manquantes, noms, emplacement
    /// des appareils filaires (switchs des contrôleurs, puis SNMP) et borne des clients Wi-Fi.
    /// `controller` : tous les relevés de contrôleurs affichés (FortiGate comprises).
    public static func apply(_ readings: [ControllerSiteReading], to devices: [Device], controller: [SNMPSwitchSnapshot],
                             snmp: [SNMPSwitchSnapshot], vendors: OUIDatabase = .builtIn)
        -> (devices: [Device], located: Int, wireless: Int, named: Int, filled: Int) {
        let filled = SNMPAutoLocate.fillMACs(devices, from: arpTable(readings), vendors: vendors)
        var named = 0
        let names = names(readings)
        let withNames = filled.devices.map { device -> Device in
            guard (device.hostname ?? "").isEmpty, let mac = device.mac, let name = names[mac] else { return device }
            var copy = device
            copy.hostname = name
            copy.nameSource = .controller
            named += 1
            return copy
        }
        let placed = FortiLocate.locate(withNames, controller: controller, snmp: snmp)
        // Clients Wi-Fi : la borne et « Wi-Fi » (un client sans fil n'a pas de port de switch).
        var wifi: [MACAddress: (ap: String, vlan: Int?)] = [:]
        for reading in readings {
            for client in reading.report.wirelessClients where wifi[client.mac] == nil {
                guard let ap = client.apName ?? reading.report.ap(for: client)?.name else { continue }
                wifi[client.mac] = (ap, client.vlan)
            }
        }
        var wireless = 0
        let result = placed.devices.map { device -> Device in
            guard let mac = device.mac, let entry = wifi[mac], placed.ports[mac] == nil else { return device }
            var copy = device
            copy.switchName = entry.ap
            copy.switchPort = wifiPort
            if let vlan = entry.vlan { copy.vlan = vlan }
            wireless += 1
            return copy
        }
        return (result, placed.located, wireless, named, filled.filled)
    }

    // MARK: Wi-Fi au format commun (note 84)

    /// Bornes et clients Wi-Fi au format des FortiAP, pour la reconnaissance Wi-Fi des appareils
    /// (`InvWirelessContext`) et la fusion avec le Wi-Fi des FortiGate.
    public static func wifiOverview(_ readings: [ControllerSiteReading]) -> FortiWifiOverview {
        var aps: [FortiManagedAP] = []
        var clients: [FortiWifiClient] = []
        var sites: [String] = []
        for reading in readings {
            let site = reading.siteName
            if !sites.contains(site) { sites.append(site) }
            for ap in reading.report.aps {
                let radios = ap.radios.enumerated().map { index, radio in
                    FortiAPRadio(radioID: index + 1, band: radio.band, channel: radio.channel, widthMHz: radio.widthMHz,
                                 txPowerDBm: radio.txPowerDBm, clientCount: radio.clientCount, channelUtilization: radio.utilization)
                }
                aps.append(FortiManagedAP(site: site, name: ap.name, wtpID: ap.mac?.formatted(.upperColon) ?? ap.name, serial: ap.serial,
                                          model: ap.model, firmware: ap.firmware, ip: ap.ip, connected: ap.online, uptime: ap.uptime,
                                          clientCount: reading.report.clientCount(of: ap), radios: radios))
            }
            for client in reading.report.wirelessClients {
                let ap = reading.report.ap(for: client)
                clients.append(FortiWifiClient(site: site, mac: client.mac, ip: client.ip, hostname: client.hostname, ssid: client.ssid,
                                               apName: client.apName ?? ap?.name, apKey: ap?.mac?.formatted(.upperColon),
                                               band: client.band, channel: client.channel, rssi: client.rssi,
                                               rateMbps: client.rateMbps, vlan: client.vlan, manufacturer: client.manufacturer))
            }
        }
        let readAt = readings.map(\.report.readAt).max()
        return FortiWifiOverview(aps: aps, clients: clients, sites: sites, readAt: readAt)
    }

    /// Wi-Fi des FortiGate et des contrôleurs réunis (FortiGate d'abord).
    public static func merged(_ forti: FortiWifiOverview, _ controllers: FortiWifiOverview) -> FortiWifiOverview {
        guard !controllers.isEmpty else { return forti }
        guard !forti.isEmpty else { return controllers }
        var sites = forti.sites
        for site in controllers.sites where !sites.contains(site) { sites.append(site) }
        let readAt = [forti.readAt, controllers.readAt].compactMap { $0 }.max()
        return FortiWifiOverview(aps: forti.aps + controllers.aps, clients: forti.clients + controllers.clients, ssids: forti.ssids,
                                 rogues: forti.rogues, sites: sites, notes: forti.notes + controllers.notes, readAt: readAt)
    }
}

// MARK: - Résumé affiché

/// Chiffres d'une ou plusieurs lectures (tuiles du Wi-Fi et bandeau des switchs).
public struct ControllerSummary: Hashable, Sendable {
    public var switches: Int
    public var switchesOnline: Int
    public var aps: Int
    public var apsOnline: Int
    public var wirelessClients: Int
    public var wiredClients: Int
    /// Clients Wi-Fi au signal faible (sous −70 dBm).
    public var weakClients: Int
    /// Clients par bande.
    public var byBand: [WifiBand: Int]
    public var ssids: [String]

    public static let weakThreshold = -70

    public init(_ readings: [ControllerSiteReading]) {
        let reports = readings.map(\.report)
        let switches = reports.flatMap(\.switches)
        let aps = reports.flatMap(\.aps)
        let wifi = reports.flatMap(\.wirelessClients)
        self.switches = switches.count
        switchesOnline = switches.filter { $0.online != false }.count
        self.aps = aps.count
        apsOnline = aps.filter { $0.online != false }.count
        wirelessClients = wifi.count
        wiredClients = reports.flatMap(\.wiredClients).count
        weakClients = wifi.filter { ($0.rssi ?? 0) < Self.weakThreshold && $0.rssi != nil }.count
        var bands: [WifiBand: Int] = [:]
        for client in wifi { if let band = client.band { bands[band, default: 0] += 1 } }
        byBand = bands
        var names = Set<String>()
        for client in wifi { if let ssid = client.ssid { names.insert(ssid) } }
        for ap in aps { for ssid in ap.ssids { names.insert(ssid) } }
        ssids = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
