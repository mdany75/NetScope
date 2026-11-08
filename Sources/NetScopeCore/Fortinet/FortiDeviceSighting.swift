import Foundation

// Note 109 : relecture d'un seul appareil pour « Où était cet appareil ? ». FortiOS rend des listes :
// on interroge seulement les quatre qui situent un appareil (GET), et on ne garde que lui. Une
// adresse IP ne vaut que sur la FortiGate de son site : l'appelant n'interroge que celles-là.

/// Ce qui désigne l'appareil cherché : ses MAC connues, ou l'IP tapée.
public struct FortiDeviceTarget: Hashable, Sendable {
    public var macs: Set<MACAddress>
    public var ip: IPv4Address?

    public init(macs: Set<MACAddress> = [], ip: IPv4Address? = nil) {
        self.macs = macs
        self.ip = ip
    }

    public var isEmpty: Bool { macs.isEmpty && ip == nil }

    /// Cible d'une recherche : les MAC trouvées, ou une MAC ou une IP tapée entière (appareil pas
    /// encore dans l'historique). nil : trop d'appareils, ou rien de précis.
    public static func of(query: String, found: [MACAddress], limit: Int = 5) -> FortiDeviceTarget? {
        guard found.count <= limit else { return nil }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var target = FortiDeviceTarget(macs: Set(found), ip: IPv4Address(text))
        if found.isEmpty, target.ip == nil, let mac = MACAddress(text) { target.macs = [mac] }
        return target.isEmpty ? nil : target
    }
}

/// Note 110 : ce que la dernière relecture voit d'une MAC, sans historique ni dates.
public struct MACCurrentView: Hashable, Sendable, Identifiable {
    public var mac: MACAddress
    public var items: [MACObservation]
    public var id: MACAddress { mac }

    public var name: String? { items.first { $0.kind == .name }?.value }

    /// Regroupe par MAC, dans l'ordre de lecture. Une même valeur vue par plusieurs listes n'apparaît
    /// qu'une fois ; IP, nom, port, VLAN, puis borne.
    public static func group(_ observations: [MACObservation]) -> [MACCurrentView] {
        let order = Dictionary(uniqueKeysWithValues: MACSightingKind.allCases.enumerated().map { ($0.element, $0.offset) })
        var macs: [MACAddress] = []
        var byMAC: [MACAddress: [MACObservation]] = [:]
        for item in observations {
            if byMAC[item.mac] == nil { macs.append(item.mac) }
            if byMAC[item.mac]?.contains(where: { $0.kind == item.kind && $0.value == item.value }) != true {
                byMAC[item.mac, default: []].append(item)
            }
        }
        return macs.map { mac in
            let items = (byMAC[mac] ?? []).enumerated()
                .sorted { (order[$0.element.kind] ?? 0, $0.offset) < (order[$1.element.kind] ?? 0, $1.offset) }
                .map(\.element)
            return MACCurrentView(mac: mac, items: items)
        }
    }
}

extension FortiGateReader {
    /// Observations de cet appareil, ou vide si la FortiGate ne le voit pas. Erreur levée si le
    /// jeton est refusé, si la FortiGate est injoignable ou si aucune liste n'a pu être lue.
    public func readDeviceSighting(_ target: FortiDeviceTarget, now: Date = Date()) async throws -> [MACObservation] {
        var failures: [FortiGateError] = []

        func body(_ path: String) async throws -> Data? {
            let fetched = try await fetch(path)
            if let error = fetched.error {
                failures.append(error)
                return nil
            }
            return fetched.response?.body
        }

        // ARP en premier : c'est lui qui relie l'IP tapée à sa MAC.
        let arp = try await body(FortiPaths.arp).flatMap { FortiParsers.arp($0) } ?? []
        var macs = target.macs
        if let ip = target.ip { macs.formUnion(arp.filter { $0.ip == ip }.map(\.mac)) }

        let detected = try await body(FortiPaths.detectedDevice).flatMap { FortiParsers.detectedDevices($0, now: now) } ?? []
        let users = try await body(FortiPaths.userDevices).flatMap { FortiParsers.userDevices($0, now: now) } ?? []
        let clients = try await body(FortiWifiPaths.client).flatMap { FortiWifiParsers.clients($0, now: now) } ?? []
        if let ip = target.ip {
            macs.formUnion(users.filter { $0.ip == ip }.map(\.mac))
            macs.formUnion(detected.filter { $0.ip == ip }.map(\.mac))
            macs.formUnion(clients.filter { $0.ip == ip }.map(\.mac))
        }
        if failures.count == 4, let failure = failures.first { throw failure }
        guard !macs.isEmpty else { return [] }

        let wantedDetected = detected.filter { macs.contains($0.mac) }
        let wantedUsers = users.filter { macs.contains($0.mac) }
        let hasPort = !wantedDetected.isEmpty || wantedUsers.contains { $0.switchID != nil && $0.portName != nil }
        let names = hasPort ? try await switchNames() : [:]
        func portValue(_ id: String, _ port: String) -> String { "\(names[id] ?? id) · \(port)" }

        var list: [MACObservation] = []
        var seen = Set<MACObservation>()
        func add(_ mac: MACAddress, _ kind: MACSightingKind, _ value: String, _ source: MACSightingSource) {
            let item = MACObservation(mac: mac, kind: kind, value: value, source: source)
            if seen.insert(item).inserted { list.append(item) }
        }
        for entry in arp where macs.contains(entry.mac) { add(entry.mac, .ip, entry.ip.description, .fortigate) }
        for device in wantedDetected {
            add(device.mac, .switchPort, portValue(device.switchID, device.portName), .fortigate)
            if let vlan = device.vlan { add(device.mac, .vlan, String(vlan), .fortigate) }
            if let ip = device.ip { add(device.mac, .ip, ip.description, .fortigate) }
            if let name = device.name, !name.isEmpty { add(device.mac, .name, name, .fortigate) }
        }
        for user in wantedUsers {
            if let ip = user.ip { add(user.mac, .ip, ip.description, .fortigate) }
            if let name = user.hostname, !name.isEmpty { add(user.mac, .name, name, .fortigate) }
            if let id = user.switchID, let port = user.portName { add(user.mac, .switchPort, portValue(id, port), .fortigate) }
            if let vlan = user.vlan { add(user.mac, .vlan, String(vlan), .fortigate) }
        }
        for item in MACHistory.observations(wifiClients: clients.filter { macs.contains($0.mac) }) where seen.insert(item).inserted {
            list.append(item)
        }
        return list
    }

    /// Noms des FortiSwitch, pour écrire le port comme les relevés complets.
    private func switchNames() async throws -> [String: String] {
        var status = try await fetch(FortiPaths.switchStatus)
        if case .notFound? = status.error { status = try await fetch(FortiPaths.switchLegacy) }
        guard status.error == nil, let body = status.response?.body, let switches = FortiParsers.managedSwitches(body) else { return [:] }
        return Dictionary(switches.map { ($0.id, $0.name) }) { first, _ in first }
    }
}
