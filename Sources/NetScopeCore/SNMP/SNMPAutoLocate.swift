import Foundation

// Fin de scan automatique : ce que la découverte SNMP et les relevés des switchs apportent aux
// appareils du scan (type, nom, MAC des autres VLAN, switch / port / VLAN). Fonctions pures,
// sans réseau : l'application les appelle après la découverte et les relevés.

public enum SNMPAutoLocate {
    /// Applique la découverte SNMP aux appareils : nature (`snmpKind`), type d'appareil, et
    /// sysName comme nom d'hôte quand l'appareil n'en a pas.
    public static func applyDiscovery(_ discovered: [SNMPDiscovered], to devices: [Device]) -> [Device] {
        let byHost = Dictionary(discovered.map { ($0.host, $0) }, uniquingKeysWith: { first, _ in first })
        return devices.map { device in
            guard let item = byHost[device.ip] else { return device }
            var copy = device
            copy.snmpKind = item.kind
            let name = item.sysName.trimmingCharacters(in: .whitespacesAndNewlines)
            if (copy.hostname ?? "").isEmpty, !name.isEmpty {
                copy.hostname = name
                copy.nameSource = .snmp
            }
            copy.deviceType = ScanDeviceClassifier.guess(copy)
            return copy
        }
    }

    /// Table IP → MAC réunie à partir des routeurs (IP → MAC) et des switchs de niveau 3 (MAC → IP).
    /// Les MAC nulles, de diffusion ou de multidiffusion sont écartées ; la première source l'emporte.
    public static func mergedARP(routers: [[IPv4Address: MACAddress]], snapshots: [SNMPSwitchSnapshot]) -> [IPv4Address: MACAddress] {
        var result: [IPv4Address: MACAddress] = [:]
        func add(_ ip: IPv4Address, _ mac: MACAddress) {
            guard mac.value != 0, !mac.isBroadcast, !mac.isMulticast, result[ip] == nil else { return }
            result[ip] = mac
        }
        for table in routers {
            for (ip, mac) in table.sorted(by: { $0.key < $1.key }) { add(ip, mac) }
        }
        for snapshot in snapshots {
            for (mac, ip) in snapshot.arp.sorted(by: { $0.value < $1.value }) { add(ip, mac) }
        }
        return result
    }

    /// Complète les MAC manquantes (appareils d'autres VLAN, que l'ARP du Mac ne voit pas) et leur fabricant.
    public static func fillMACs(_ devices: [Device], from arp: [IPv4Address: MACAddress],
                                vendors: OUIDatabase = .builtIn) -> (devices: [Device], filled: Int) {
        var filled = 0
        let result = devices.map { device -> Device in
            guard device.mac == nil, let mac = arp[device.ip] else { return device }
            var copy = device
            copy.mac = mac
            if copy.vendor == nil { copy.vendor = vendors.vendor(for: mac) }
            copy.deviceType = ScanDeviceClassifier.guess(copy)
            filled += 1
            return copy
        }
        return (result, filled)
    }

    /// Port d'accès de chaque MAC apprise par les switchs relevés (uplinks écartés), calculé en une passe.
    public static func accessPorts(in snapshots: [SNMPSwitchSnapshot], macThreshold: Int = 8) -> [MACAddress: SNMPLocation] {
        let uplinkMap = SNMPLocator.uplinks(in: snapshots, macThreshold: macThreshold)
        var candidates: [MACAddress: [(location: SNMPLocation, count: Int)]] = [:]
        for snapshot in snapshots {
            let uplinks = uplinkMap[snapshot.host] ?? []
            let counts = snapshot.macCountByInterface
            for entry in snapshot.fdb {
                guard let i = entry.ifIndex, !uplinks.contains(i) else { continue }
                let name = snapshot.interface(i)?.name ?? "port \(entry.bridgePort)"
                let location = SNMPLocation(switchHost: snapshot.host, switchName: snapshot.displayName, ifIndex: i,
                                            portName: name, vlan: entry.vlan ?? snapshot.pvid[i], isUplink: false)
                candidates[entry.mac, default: []].append((location, counts[i] ?? 0))
            }
        }
        // À égalité, le port qui porte le moins d'adresses (même règle que `SNMPLocator.locate`).
        return candidates.mapValues { list in list.min { $0.count < $1.count }!.location }
    }

    /// Reporte switch, port et VLAN sur chaque appareil dont la MAC est apprise sur un port d'accès.
    /// Un appareil introuvable garde son emplacement précédent.
    public static func locate(_ devices: [Device], in snapshots: [SNMPSwitchSnapshot],
                              macThreshold: Int = 8) -> (devices: [Device], located: Int) {
        guard !snapshots.isEmpty else { return (devices, 0) }
        let ports = accessPorts(in: snapshots, macThreshold: macThreshold)
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
        return (result, located)
    }
}
