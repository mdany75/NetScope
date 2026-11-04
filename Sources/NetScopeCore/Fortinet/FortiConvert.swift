import Foundation

// Conversion de la lecture de la FortiGate vers les modèles de NetScope : un relevé de switch
// (`SNMPSwitchSnapshot`, le même que pour SNMP) par FortiSwitch, emplacement des appareils, noms
// et table ARP. La FortiGate est prioritaire sur SNMP quand elle répond ; SNMP reste la source des
// autres switchs. Fonctions pures, sans réseau.

public enum FortiConvert {
    // MARK: Fusion des réponses

    /// Complète les ports par la configuration (description, VLAN natif, état administratif,
    /// FortiLink et ISL) ; crée les ports absents de l'état.
    public static func merge(_ switches: [FortiManagedSwitch],
                             config: [String: (name: String?, description: String?, ports: [String: FortiParsers.PortConfig])]) -> [FortiManagedSwitch] {
        switches.map { sw in
            guard let entry = sw.keys.lazy.compactMap({ config[$0] }).first else { return sw }
            var copy = sw
            if copy.description == nil { copy.description = entry.description }
            var seen = Set<String>()
            copy.ports = sw.ports.map { port in
                var p = port
                seen.insert(port.name.lowercased())
                guard let c = entry.ports[port.name.lowercased()] else { return p }
                if p.description == nil { p.description = c.description }
                if p.nativeVLAN == nil {
                    p.nativeVLAN = c.nativeVLAN
                    if p.nativeVLANID == nil { p.nativeVLANID = FortiParse.vlanID(fromName: c.nativeVLAN) }
                }
                if p.adminUp == nil { p.adminUp = c.adminUp }
                if p.poeEnabled == nil { p.poeEnabled = c.poeEnabled }
                p.isFortiLink = p.isFortiLink || c.isFortiLink
                p.isISL = p.isISL || c.isISL
                return p
            }
            for (name, c) in entry.ports.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) where !seen.contains(name) {
                copy.ports.append(FortiSwitchPort(name: name, number: FortiParse.portNumber(name) ?? copy.ports.count + 1,
                                                  adminUp: c.adminUp, nativeVLAN: c.nativeVLAN,
                                                  nativeVLANID: FortiParse.vlanID(fromName: c.nativeVLAN), description: c.description,
                                                  poeEnabled: c.poeEnabled, isFortiLink: c.isFortiLink, isISL: c.isISL))
            }
            return copy
        }
    }

    /// Ajoute les compteurs d'octets et d'erreurs.
    public static func merge(_ switches: [FortiManagedSwitch], stats: [String: [String: (rx: UInt64?, tx: UInt64?, errors: UInt64?)]]) -> [FortiManagedSwitch] {
        switches.map { sw in
            guard let ports = sw.keys.lazy.compactMap({ stats[$0] }).first else { return sw }
            var copy = sw
            copy.ports = sw.ports.map { port in
                var p = port
                if let s = ports[port.name.lowercased()] {
                    p.rxBytes = s.rx ?? p.rxBytes
                    p.txBytes = s.tx ?? p.txBytes
                    p.rxErrors = s.errors ?? p.rxErrors
                }
                return p
            }
            return copy
        }
    }

    /// Ajoute le PoE détaillé (puissance, état, classe).
    public static func merge(_ switches: [FortiManagedSwitch], poe: [String: [String: (power: Double?, state: String?, powerClass: Int?)]]) -> [FortiManagedSwitch] {
        switches.map { sw in
            guard let ports = sw.keys.lazy.compactMap({ poe[$0] }).first else { return sw }
            var copy = sw
            copy.ports = sw.ports.map { port in
                var p = port
                if let v = ports[port.name.lowercased()] {
                    p.poePowerW = v.power ?? p.poePowerW
                    if let state = v.state, FortiJSON.bool(state) == nil { p.poeState = state }
                    else if let flag = v.state.flatMap(FortiJSON.bool), p.poeEnabled == nil { p.poeEnabled = flag }
                    p.poeClass = v.powerClass ?? p.poeClass
                    p.poeCapable = p.poeCapable ?? true
                }
                return p
            }
            return copy
        }
    }

    // MARK: Relevés de switch

    /// Numéro d'entreprise de Fortinet (sysObjectID) : la marque est reconnue comme pour SNMP.
    public static let fortinetObjectID = "1.3.6.1.4.1.12356.106"

    /// Un relevé par FortiSwitch, marqué « via FortiGate » (`controllerName`). Un switch sans adresse
    /// FortiLink connue reçoit une adresse de remplacement 0.0.0.n (jamais interrogée).
    public static func snapshots(from report: FortiGateReport) -> [SNMPSwitchSnapshot] {
        let located = report.locatedDevices
        var ipByMAC: [MACAddress: IPv4Address] = [:]
        for lease in report.dhcp { ipByMAC[lease.mac] = lease.ip }
        for entry in report.arp { ipByMAC[entry.mac] = entry.ip }
        for device in located { if let ip = device.ip { ipByMAC[device.mac] = ip } }
        var usedHosts = Set<IPv4Address>()
        return report.switches.enumerated().map { offset, sw in
            var host = sw.fortilinkIP ?? IPv4Address(UInt32(offset + 1))
            if usedHosts.contains(host) { host = IPv4Address(UInt32(offset + 1)) }
            usedHosts.insert(host)
            return snapshot(sw, host: host, devices: located.filter { sw.keys.contains($0.switchID.lowercased()) },
                            ipByMAC: ipByMAC, controller: report.controllerName, polledAt: report.readAt)
        }
    }

    static func snapshot(_ sw: FortiManagedSwitch, host: IPv4Address, devices: [FortiDetectedDevice], ipByMAC: [MACAddress: IPv4Address],
                         controller: String, polledAt: Date) -> SNMPSwitchSnapshot {
        // Index d'interface : le numéro du port, sans doublon.
        var ports = sw.ports.sorted { $0.number < $1.number }
        var indexByName: [String: Int] = [:]
        var used = Set<Int>()
        func index(for number: Int) -> Int {
            var i = max(number, 1)
            while used.contains(i) { i += 1000 }
            used.insert(i)
            return i
        }
        var interfaces: [SNMPInterface] = []
        var pvid: [Int: Int] = [:]
        var neighbors: [SNMPLLDPNeighbor] = []
        var poe: [SNMPPoEPort] = []
        // Ports où un appareil est vu mais que l'état n'a pas listés.
        for device in devices where !ports.contains(where: { $0.name.lowercased() == device.portName.lowercased() }) {
            ports.append(FortiSwitchPort(name: device.portName, number: FortiParse.portNumber(device.portName) ?? 9000 + ports.count, linkUp: true))
        }
        let copper = copperPorts(model: sw.model)
        for port in ports {
            let i = index(for: port.number)
            indexByName[port.name.lowercased()] = i
            let oper: SNMPOperStatus = port.linkUp == true ? .up : (port.linkUp == false ? .down : .unknown)
            // Ports au-delà des ports cuivre (49 à 52 d'un 248E, 25 à 28 d'un 124F) : cages SFP+,
            // vitesse nominale de 10 Gb/s quand le port est sans lien (façade et décompte).
            var speed = port.speedMbps
            if speed == nil, let copper, copper >= 24, port.number > copper { speed = 10_000 }
            interfaces.append(SNMPInterface(index: i, name: port.name, descr: port.name, alias: port.description ?? "", type: 6,
                                            adminUp: port.adminUp ?? true, operStatus: oper, speedMbps: speed,
                                            inErrors: port.rxErrors, inOctets: port.rxBytes, outOctets: port.txBytes))
            if let vlan = port.nativeVLANID { pvid[i] = vlan }
            if port.isUplink {
                let name = port.peerName ?? (port.isFortiLink ? controller : "FortiSwitch")
                neighbors.append(SNMPLLDPNeighbor(localPortNum: i, ifIndex: i, sysName: name, portID: port.isFortiLink ? "FortiLink" : "ISL",
                                                  portDescr: port.isFortiLink ? "FortiLink" : "ISL",
                                                  sysDescr: port.isFortiLink ? "FortiGate \(controller) · FortiLink" : "Lien inter-switch (ISL)",
                                                  capabilities: port.isFortiLink ? [.router, .bridge] : [.bridge]))
            }
            if port.poeCapable == true || port.poePowerW != nil || port.poeState != nil {
                poe.append(SNMPPoEPort(group: 1, port: port.number, ifIndex: i, adminEnabled: port.poeEnabled,
                                       detection: port.poeDetection, powerClass: port.poeClass,
                                       consumptionMW: port.poePowerW.map { Int(($0 * 1000).rounded()) }, wattsSource: "FortiGate"))
            }
        }
        var fdb: [SNMPFDBEntry] = []
        var arp: [MACAddress: IPv4Address] = [:]
        for device in devices {
            guard let i = indexByName[device.portName.lowercased()] else { continue }
            fdb.append(SNMPFDBEntry(mac: device.mac, vlan: device.vlan ?? pvid[i], bridgePort: i, ifIndex: i))
            if let ip = ipByMAC[device.mac] { arp[device.mac] = ip }
        }
        let watts = poe.compactMap(\.consumptionMW)
        let model = sw.model.isEmpty ? "FortiSwitch" : sw.model
        var descr = "FortiSwitch \(model), \(sw.firmware.isEmpty ? "version inconnue" : sw.firmware)"
        if !sw.serial.isEmpty { descr += " · série \(sw.serial)" }
        let system = SNMPSystemInfo(name: sw.name, descr: descr, objectID: fortinetObjectID, location: sw.description)
        return SNMPSwitchSnapshot(host: host, system: system, interfaces: interfaces, fdb: fdb, neighbors: neighbors, pvid: pvid,
                                  poePorts: Set(poe.filter(\.isDelivering).compactMap(\.ifIndex)),
                                  poeBudgetW: sw.poeBudgetW.map { Int($0.rounded()) },
                                  poeUsedW: watts.isEmpty ? nil : Int((Double(watts.reduce(0, +)) / 1000).rounded()),
                                  poeDetails: poe.isEmpty ? [] : poe, arp: arp, polledAt: polledAt, controllerName: controller)
    }

    /// Nombre de ports cuivre d'après le modèle : « FS-248E-POE » → 48, « FS-124F » → 24, « FS-108F » → 8.
    public static func copperPorts(model: String) -> Int? {
        let upper = model.uppercased()
        guard let range = upper.range(of: #"\d{3}"#, options: .regularExpression) else { return nil }
        let digits = upper[range]
        return Int(digits.dropFirst())
    }

    // MARK: Noms et ARP

    /// Nom de chaque MAC connu de la FortiGate : inventaire des appareils, puis baux DHCP, puis
    /// appareils détectés (le premier trouvé l'emporte).
    public static func names(from report: FortiGateReport) -> [MACAddress: String] {
        var result: [MACAddress: String] = [:]
        func add(_ mac: MACAddress, _ name: String?) {
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, result[mac] == nil else { return }
            // Un nom qui n'est qu'une adresse MAC ou IP n'apprend rien.
            if MACAddress(name) != nil || IPv4Address(name) != nil { return }
            result[mac] = name
        }
        for device in report.userDevices { add(device.mac, device.hostname) }
        for lease in report.dhcp { add(lease.mac, lease.hostname) }
        for device in report.detected { add(device.mac, device.name) }
        return result
    }

    /// Table IP → MAC de la FortiGate (ARP, puis baux DHCP).
    public static func arpTable(from report: FortiGateReport) -> [IPv4Address: MACAddress] {
        var result: [IPv4Address: MACAddress] = [:]
        for entry in report.arp where !entry.mac.isMulticast { result[entry.ip] = entry.mac }
        for lease in report.dhcp where result[lease.ip] == nil { result[lease.ip] = lease.mac }
        return result
    }
}

/// Emplacement des appareils avec deux sources : la FortiGate (prioritaire) et SNMP.
public enum FortiLocate {
    /// Les ports d'accès d'un FortiSwitch viennent des appareils détectés par la FortiGate : seuls
    /// les liens FortiLink et ISL sont des uplinks (pas de seuil de nombre de MAC).
    static let controllerMacThreshold = 1_000_000

    /// Relevés SNMP d'un switch déjà lu par la FortiGate (même nom ou même adresse) écartés.
    public static func withoutDuplicates(snmp: [SNMPSwitchSnapshot], controller: [SNMPSwitchSnapshot]) -> [SNMPSwitchSnapshot] {
        let names = Set(controller.map { $0.system.name.lowercased() }.filter { !$0.isEmpty })
        let hosts = Set(controller.map(\.host))
        return snmp.filter { !hosts.contains($0.host) && !names.contains($0.system.name.lowercased()) }
    }

    /// Port d'accès de chaque MAC : la FortiGate d'abord, SNMP pour les autres.
    public static func accessPorts(controller: [SNMPSwitchSnapshot], snmp: [SNMPSwitchSnapshot]) -> [MACAddress: SNMPLocation] {
        let others = withoutDuplicates(snmp: snmp, controller: controller)
        var result = others.isEmpty ? [:] : SNMPAutoLocate.accessPorts(in: others)
        if !controller.isEmpty {
            for (mac, location) in SNMPAutoLocate.accessPorts(in: controller, macThreshold: controllerMacThreshold) {
                result[mac] = location
            }
        }
        return result
    }

    /// Reporte switch, port et VLAN sur chaque appareil localisé (FortiGate > SNMP).
    public static func locate(_ devices: [Device], controller: [SNMPSwitchSnapshot], snmp: [SNMPSwitchSnapshot])
        -> (devices: [Device], located: Int, ports: [MACAddress: SNMPLocation]) {
        let ports = accessPorts(controller: controller, snmp: snmp)
        guard !ports.isEmpty else { return (devices, 0, ports) }
        var located = 0
        let result = devices.map { device -> Device in
            guard let mac = device.mac, let location = ports[mac] else { return device }
            var copy = device
            copy.switchName = location.switchName
            copy.switchPort = location.portName
            if let vlan = location.vlan { copy.vlan = vlan }
            located += 1
            return copy
        }
        return (result, located, ports)
    }

    /// Donne le nom connu de la FortiGate aux appareils qui n'en ont pas.
    public static func applyNames(_ names: [MACAddress: String], to devices: [Device]) -> (devices: [Device], named: Int) {
        var named = 0
        let result = devices.map { device -> Device in
            guard (device.hostname ?? "").isEmpty, let mac = device.mac, let name = names[mac] else { return device }
            var copy = device
            copy.hostname = name
            copy.nameSource = .fortigate
            named += 1
            return copy
        }
        return (result, named)
    }

    /// Tout ce que la lecture apporte aux appareils du scan : MAC manquantes (ARP de la FortiGate),
    /// noms, puis emplacement (FortiGate > SNMP).
    public static func apply(_ report: FortiGateReport, to devices: [Device], snmp: [SNMPSwitchSnapshot],
                             vendors: OUIDatabase = .builtIn) -> (devices: [Device], located: Int, named: Int, filled: Int) {
        let controller = FortiConvert.snapshots(from: report)
        let filled = SNMPAutoLocate.fillMACs(devices, from: FortiConvert.arpTable(from: report), vendors: vendors)
        let named = applyNames(FortiConvert.names(from: report), to: filled.devices)
        let placed = locate(named.devices, controller: controller, snmp: snmp)
        return (placed.devices, placed.located, named.named, filled.filled)
    }
}
