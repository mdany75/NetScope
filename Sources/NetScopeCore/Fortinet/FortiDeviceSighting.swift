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

    /// Cible d'une recherche : une IP ou une MAC tapée entière, sinon les MAC trouvées par le nom.
    /// nil : trop d'appareils, ou rien de précis.
    public static func of(query: String, found: [MACAddress], limit: Int = 5) -> FortiDeviceTarget? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Une IP entière désigne l'appareil qui l'a maintenant, pas ceux qui l'ont déjà eue.
        if let ip = IPv4Address(text) { return FortiDeviceTarget(ip: ip) }
        if let mac = MACAddress(text) { return FortiDeviceTarget(macs: [mac]) }
        guard found.count <= limit, !found.isEmpty else { return nil }
        return FortiDeviceTarget(macs: Set(found))
    }
}

/// Résultat d'une relecture : ce qui est vu, et ce qu'a donné la CLI quand elle a servi.
public struct FortiDeviceSightingReport: Sendable {
    public var observations: [MACObservation] = []
    /// La CLI a fourni le détenteur ou l'IP retenus.
    public var usedCLI = false
    /// La CLI a répondu, sans rien apporter sur cet appareil.
    public var cliHadNothing = false
    public var cliError: ConfigBackupError?

    public init() {}
}

/// Note 110 : ce que la dernière relecture voit d'une MAC, sans historique ni dates.
public struct MACCurrentView: Hashable, Sendable, Identifiable {
    public var mac: MACAddress
    public var items: [MACObservation]
    public var id: MACAddress { mac }

    public var name: String? { items.first { $0.kind == .name }?.value }

    /// Regroupe par MAC, dans l'ordre de lecture : une seule valeur par nature (la dernière lecture,
    /// pas un historique) ; IP, nom, port, VLAN, puis borne.
    public static func group(_ observations: [MACObservation]) -> [MACCurrentView] {
        let order = Dictionary(uniqueKeysWithValues: MACSightingKind.allCases.enumerated().map { ($0.element, $0.offset) })
        var macs: [MACAddress] = []
        var byMAC: [MACAddress: [MACObservation]] = [:]
        for item in observations {
            if byMAC[item.mac] == nil { macs.append(item.mac) }
            if byMAC[item.mac]?.contains(where: { $0.kind == item.kind }) != true {
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
    /// Au-delà (secondes), une fiche des listes d'appareils ne dit plus où l'appareil est maintenant.
    static let sightingFreshness: TimeInterval = 900

    /// Observations de cet appareil, ou vide si la FortiGate ne le voit pas. Erreur levée si le
    /// jeton est refusé, si la FortiGate est injoignable ou si aucune liste n'a pu être lue.
    public func readDeviceSighting(_ target: FortiDeviceTarget, now: Date = Date()) async throws -> [MACObservation] {
        try await readDeviceSightingReport(target, now: now).observations
    }

    /// Note 111 : `cli` n'est appelée que si l'API laisse un doute sur l'IP (aucun client Wi-Fi associé
    /// à l'adresse cherchée, ou plusieurs adresses pour la MAC).
    public func readDeviceSightingReport(_ target: FortiDeviceTarget, now: Date = Date(),
                                         cli: (@Sendable () async -> Result<FortiCLISnapshot, ConfigBackupError>)? = nil) async throws -> FortiDeviceSightingReport {
        var failures: [FortiGateError] = []

        func body(_ path: String) async throws -> Data? {
            let fetched = try await fetch(path)
            if let error = fetched.error {
                failures.append(error)
                return nil
            }
            return fetched.response?.body
        }

        let arp = try await body(FortiPaths.arp).flatMap { FortiParsers.arp($0) } ?? []
        // Listes qui gardent d'anciennes fiches : seules les entrées récentes disent l'état actuel.
        func isFresh(_ date: Date?) -> Bool { date.map { now.timeIntervalSince($0) <= Self.sightingFreshness } ?? true }
        let detected = (try await body(FortiPaths.detectedDevice).flatMap { FortiParsers.detectedDevices($0, now: now) } ?? []).filter { isFresh($0.lastSeen) }
        let users = (try await body(FortiPaths.userDevices).flatMap { FortiParsers.userDevices($0, now: now) } ?? []).filter { isFresh($0.lastSeen) }
        let clients = try await body(FortiWifiPaths.client).flatMap { FortiWifiParsers.clients($0, now: now) } ?? []
        if failures.count == 4, let failure = failures.first { throw failure }

        func latest<T>(_ items: [T], _ date: (T) -> Date?) -> T? {
            items.max { (date($0) ?? .distantPast) < (date($1) ?? .distantPast) }
        }

        // La CLI tranche seulement quand l'API ne le peut pas.
        var report = FortiDeviceSightingReport()
        var snapshot: FortiCLISnapshot?
        if let cli, Self.needsCLI(target, arp: arp, detected: detected, users: users, clients: clients) {
            switch await cli() {
            case .success(let value):
                snapshot = value
                report.cliError = value.partialError
            case .failure(let error):
                report.cliError = error
            }
        }

        var macs = target.macs
        if let ip = target.ip {
            // Une seule machine a cette IP : client Wi-Fi associé, bail DHCP, vu le plus récemment, puis ARP.
            let seen: [(mac: MACAddress, at: Date?)] = detected.filter { $0.ip == ip }.map { ($0.mac, $0.lastSeen) }
                + users.filter { $0.ip == ip }.map { ($0.mac, $0.lastSeen) }
            let wifiHolder = clients.first { $0.ip == ip }?.mac
            let cliHolder = wifiHolder == nil ? snapshot?.holder(of: ip) : nil
            if cliHolder != nil { report.usedCLI = true }
            if let holder = wifiHolder ?? cliHolder ?? latest(seen, { $0.at })?.mac ?? arp.first(where: { $0.ip == ip })?.mac {
                macs.insert(holder)
            }
        }
        guard !macs.isEmpty else {
            report.cliHadNothing = snapshot != nil
            return report
        }

        // Une seule valeur par nature et par MAC : la plus récente.
        struct Current {
            var mac: MACAddress
            var client: FortiWifiClient?
            var detected: FortiDetectedDevice?
            var user: FortiUserDevice?
            var arp: FortiARPEntry?
        }
        let current = macs.sorted { $0.description < $1.description }.map { mac in
            let entries = arp.filter { $0.mac == mac }
            return Current(mac: mac, client: clients.first { $0.mac == mac },
                           detected: latest(detected.filter { $0.mac == mac }, { $0.lastSeen }),
                           user: latest(users.filter { $0.mac == mac }, { $0.lastSeen }),
                           arp: entries.first { $0.ip == target.ip } ?? entries.first)
        }
        let hasPort = current.contains { $0.detected != nil || ($0.user?.switchID != nil && $0.user?.portName != nil) }
        let names = hasPort ? try await switchNames() : [:]
        func portValue(_ id: String, _ port: String) -> String { "\(names[id] ?? id) · \(port)" }

        var list: [MACObservation] = []
        for item in current {
            func add(_ kind: MACSightingKind, _ value: String?, _ source: MACSightingSource = .fortigate) {
                guard let value, !value.isEmpty else { return }
                list.append(MACObservation(mac: item.mac, kind: kind, value: value, source: source))
            }
            let detectedIsNewer = (item.detected?.lastSeen ?? .distantPast) >= (item.user?.lastSeen ?? .distantPast)
            let listed = detectedIsNewer ? (item.detected?.ip ?? item.user?.ip) : (item.user?.ip ?? item.detected?.ip)
            let cliIP = item.client?.ip == nil ? snapshot?.currentIP(of: item.mac, preferring: target.ip) : nil
            if cliIP != nil { report.usedCLI = true }
            add(.ip, (item.client?.ip ?? cliIP ?? listed ?? item.arp?.ip)?.description)
            add(.name, item.user?.hostname ?? item.detected?.name ?? item.client?.hostname)
            if let device = item.detected {
                add(.switchPort, portValue(device.switchID, device.portName))
            } else if let id = item.user?.switchID, let port = item.user?.portName {
                add(.switchPort, portValue(id, port))
            }
            add(.vlan, (item.client?.vlan ?? item.detected?.vlan ?? item.user?.vlan).map(String.init))
            if let client = item.client {
                list += MACHistory.observations(wifiClients: [client]).filter { $0.kind == .accessPoint }
            }
        }
        report.observations = list
        report.cliHadNothing = snapshot != nil && !report.usedCLI
        return report
    }

    /// Doute : les sources de l'API ne désignent pas exactement un appareil pour cette IP (et aucun
    /// client Wi-Fi ne la porte), ou la MAC cherchée a plusieurs adresses.
    private static func needsCLI(_ target: FortiDeviceTarget, arp: [FortiARPEntry], detected: [FortiDetectedDevice],
                                 users: [FortiUserDevice], clients: [FortiWifiClient]) -> Bool {
        if let ip = target.ip {
            if clients.contains(where: { $0.ip == ip }) { return false }
            let holders = Set(arp.filter { $0.ip == ip }.map(\.mac) + detected.filter { $0.ip == ip }.map(\.mac) + users.filter { $0.ip == ip }.map(\.mac))
            return holders.count != 1
        }
        return target.macs.contains { mac in
            if clients.first(where: { $0.mac == mac })?.ip != nil { return false }
            let ips = Set(arp.filter { $0.mac == mac }.map(\.ip)
                          + detected.filter { $0.mac == mac }.compactMap(\.ip)
                          + users.filter { $0.mac == mac }.compactMap(\.ip))
            return ips.count > 1
        }
    }

    /// Noms des FortiSwitch, pour écrire le port comme les relevés complets.
    private func switchNames() async throws -> [String: String] {
        var status = try await fetch(FortiPaths.switchStatus)
        if case .notFound? = status.error { status = try await fetch(FortiPaths.switchLegacy) }
        guard status.error == nil, let body = status.response?.body, let switches = FortiParsers.managedSwitches(body) else { return [:] }
        return Dictionary(switches.map { ($0.id, $0.name) }) { first, _ in first }
    }
}
