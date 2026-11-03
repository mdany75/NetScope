import Foundation

/// Une plage à scanner, prête : identifiant de la plage enregistrée, libellé, VLAN, adresses.
public struct ScanTarget: Sendable, Hashable {
    public var id: UUID
    public var label: String
    public var vlan: Int?
    public var range: IPRange

    public init(id: UUID = UUID(), label: String, vlan: Int? = nil, range: IPRange) {
        self.id = id
        self.label = label
        self.vlan = vlan
        self.range = range
    }

    /// Plage enregistrée lue ; lève `IPRangeError` si son texte est invalide.
    public init(config: ScanRangeConfig) throws {
        self.init(id: config.id, label: config.label, vlan: config.vlan, range: try config.parsed())
    }
}

/// Réglages d'un scan.
public struct ScanOptions: Sendable {
    public var profile: ScanProfile
    /// Ports du profil personnalisé.
    public var customPorts: [UInt16]
    /// Nombre maximal de sondes simultanées (pings, puis connexions TCP).
    public var concurrency: Int
    public var pingTimeout: Duration
    public var portTimeout: Duration
    public var resolveNames: Bool
    public var nameTimeout: Duration
    /// Lit la table ARP après les pings (hôtes qui ignorent le ping, adresses MAC).
    public var useARP: Bool

    public init(profile: ScanProfile = .rapide, customPorts: [UInt16] = [], concurrency: Int = 128,
                pingTimeout: Duration = .milliseconds(1000), portTimeout: Duration = .milliseconds(800),
                resolveNames: Bool = true, nameTimeout: Duration = .seconds(2), useARP: Bool = true) {
        self.profile = profile
        self.customPorts = customPorts
        self.concurrency = max(1, concurrency)
        self.pingTimeout = pingTimeout
        self.portTimeout = portTimeout
        self.resolveNames = resolveNames
        self.nameTimeout = nameTimeout
        self.useARP = useARP
    }

    /// Ports TCP sondés sur chaque hôte en ligne.
    public var ports: [UInt16] { profile.ports(custom: customPorts) }
}

/// Avancement d'une plage : adresses sondées sur le total, hôtes en ligne.
public struct ScanRangeProgress: Sendable, Equatable {
    public var rangeID: UUID
    public var done: Int
    public var total: Int
    public var online: Int

    public init(rangeID: UUID, done: Int = 0, total: Int, online: Int = 0) {
        self.rangeID = rangeID
        self.done = done
        self.total = total
        self.online = online
    }

    public var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
    public var isComplete: Bool { done >= total }
}

/// Étape du scan en cours.
public enum ScanPhase: String, Sendable {
    /// Ping de toutes les adresses.
    case ping
    /// Lecture de la table ARP.
    case arp
    /// Noms et ports des hôtes en ligne.
    case details

    public var label: String {
        switch self {
        case .ping: return "Ping ICMP"
        case .arp: return "Table ARP"
        case .details: return "Noms et ports"
        }
    }
}

/// Bilan d'un scan.
public struct ScanSummary: Sendable {
    public var scannedAddresses: Int
    public var devices: [Device]
    public var duration: TimeInterval
    public var cancelled: Bool
}

/// Événements publiés pendant un scan, dans l'ordre.
public enum ScanEvent: Sendable {
    case started([ScanRangeProgress])
    case phase(ScanPhase)
    case deviceFound(Device, rangeID: UUID)
    case deviceUpdated(Device, rangeID: UUID)
    case rangeProgress(ScanRangeProgress)
    case finished(ScanSummary)
}

/// Moteur de scan : ping de toutes les adresses de plusieurs plages à la fois (entrelacées,
/// concurrence plafonnée), lecture de la table ARP, puis noms et ports des hôtes en ligne.
///
/// Un moteur sert à un scan à la fois : en créer un par scan. L'annulation se fait en
/// abandonnant le flux d'événements (ou en annulant la tâche qui le lit).
public actor ScanEngine {
    private let pinger: any ScanPinging
    private let arp: any ScanARPReading
    private let portProber: any ScanPortProbing
    private let names: any ScanNameResolving
    private let vendors: OUIDatabase
    private let now: @Sendable () -> Date

    private var targets: [UUID: ScanTarget] = [:]
    private var rangeOf: [IPv4Address: UUID] = [:]
    private var found: [IPv4Address: Device] = [:]
    private var progress: [UUID: ScanRangeProgress] = [:]
    private var progressStep: [UUID: Int] = [:]

    public init(pinger: any ScanPinging, arp: any ScanARPReading = ARPTable(),
                ports: any ScanPortProbing = PortProber(), names: any ScanNameResolving = ScanReverseDNS(),
                vendors: OUIDatabase = .builtIn, now: @escaping @Sendable () -> Date = { Date() }) {
        self.pinger = pinger
        self.arp = arp
        self.portProber = ports
        self.names = names
        self.vendors = vendors
        self.now = now
    }

    /// Lance le scan ; le flux se termine après `.finished`, ou dès qu'il est abandonné.
    public nonisolated func scan(_ targets: [ScanTarget], options: ScanOptions) -> AsyncStream<ScanEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await self.run(targets, options: options, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Job: Sendable {
        let ip: IPv4Address
        let rangeID: UUID
    }

    private func run(_ list: [ScanTarget], options: ScanOptions, continuation: AsyncStream<ScanEvent>.Continuation) async {
        let start = Date()
        targets = [:]
        rangeOf = [:]
        found = [:]
        progress = [:]

        // Adresses dédoublonnées (une adresse de deux plages compte pour la première), puis entrelacées
        // pour que toutes les plages avancent ensemble.
        var lists: [[Job]] = []
        for target in list {
            targets[target.id] = target
            var jobs: [Job] = []
            for ip in target.range.addresses() where rangeOf[ip] == nil {
                rangeOf[ip] = target.id
                jobs.append(Job(ip: ip, rangeID: target.id))
            }
            progress[target.id] = ScanRangeProgress(rangeID: target.id, total: jobs.count)
            progressStep[target.id] = max(1, jobs.count / 200)
            lists.append(jobs)
        }
        let jobs = ScanEngine.interleave(lists)
        continuation.yield(.started(list.compactMap { progress[$0.id] }))

        // 1. Ping
        continuation.yield(.phase(.ping))
        let pinger = self.pinger
        let timeout = options.pingTimeout
        await ScanConcurrency.forEach(jobs, limit: options.concurrency) { job in
            let rtt = await pinger.ping(job.ip, timeout: timeout)
            await self.recordPing(job, rtt: rtt, continuation: continuation)
        }

        // 2. Table ARP : adresses MAC, et hôtes qui ne répondent pas au ping.
        if options.useARP, !Task.isCancelled {
            continuation.yield(.phase(.arp))
            recordARP(arp.read(), continuation: continuation)
        }

        // 3. Noms et ports des hôtes en ligne.
        let ports = options.ports
        if !Task.isCancelled, options.resolveNames || !ports.isEmpty {
            continuation.yield(.phase(.details))
            let perHost = ports.isEmpty ? 1 : min(32, options.concurrency)
            let hostLimit = max(1, options.concurrency / perHost)
            let addresses = found.keys.sorted()
            let prober = portProber
            let names = self.names
            await ScanConcurrency.forEach(addresses, limit: hostLimit) { ip in
                async let name: String? = options.resolveNames ? names.name(for: ip, timeout: options.nameTimeout) : nil
                async let open: [UInt16] = ports.isEmpty
                    ? [] : prober.openPorts(ip, ports: ports, timeout: options.portTimeout, concurrency: perHost)
                let (hostname, openPorts) = await (name, open)
                await self.recordDetails(ip, hostname: hostname, openPorts: ports.isEmpty ? nil : openPorts,
                                         continuation: continuation)
            }
        }

        let devices = found.values.sorted { $0.ip < $1.ip }
        continuation.yield(.finished(ScanSummary(scannedAddresses: jobs.count, devices: devices,
                                                 duration: Date().timeIntervalSince(start),
                                                 cancelled: Task.isCancelled)))
    }

    // MARK: Enregistrement des résultats

    private func recordPing(_ job: Job, rtt: Double?, continuation: AsyncStream<ScanEvent>.Continuation) {
        guard var entry = progress[job.rangeID] else { return }
        entry.done += 1
        if let rtt {
            entry.online += 1
            let device = makeDevice(job.ip, rangeID: job.rangeID, latency: rtt, mac: nil)
            found[job.ip] = device
            continuation.yield(.deviceFound(device, rangeID: job.rangeID))
        }
        progress[job.rangeID] = entry
        let step = progressStep[job.rangeID] ?? 1
        if rtt != nil || entry.done % step == 0 || entry.isComplete {
            continuation.yield(.rangeProgress(entry))
        }
    }

    private func recordARP(_ table: [IPv4Address: MACAddress], continuation: AsyncStream<ScanEvent>.Continuation) {
        var touched = Set<UUID>()
        for (ip, mac) in table.sorted(by: { $0.key < $1.key }) {
            guard let rangeID = rangeOf[ip] else { continue }
            if var device = found[ip] {
                guard device.mac == nil else { continue }
                device.mac = mac
                device.vendor = vendors.vendor(for: mac)
                device.deviceType = ScanDeviceClassifier.guess(ports: device.openPorts, vendor: device.vendor,
                                                               hostname: device.hostname, mac: mac)
                found[ip] = device
                continuation.yield(.deviceUpdated(device, rangeID: rangeID))
            } else {
                // Présent dans la table ARP sans répondre au ping : en ligne (pare-feu qui bloque l'ICMP).
                let device = makeDevice(ip, rangeID: rangeID, latency: nil, mac: mac)
                found[ip] = device
                progress[rangeID]?.online += 1
                touched.insert(rangeID)
                continuation.yield(.deviceFound(device, rangeID: rangeID))
            }
        }
        for id in touched {
            if let entry = progress[id] { continuation.yield(.rangeProgress(entry)) }
        }
    }

    private func recordDetails(_ ip: IPv4Address, hostname: String?, openPorts: [UInt16]?,
                               continuation: AsyncStream<ScanEvent>.Continuation) {
        guard var device = found[ip], let rangeID = rangeOf[ip] else { return }
        if let hostname { device.hostname = hostname }
        if let openPorts { device.openPorts = openPorts }
        device.lastSeen = now()
        device.deviceType = ScanDeviceClassifier.guess(ports: device.openPorts, vendor: device.vendor,
                                                       hostname: device.hostname, mac: device.mac)
        found[ip] = device
        continuation.yield(.deviceUpdated(device, rangeID: rangeID))
    }

    private func makeDevice(_ ip: IPv4Address, rangeID: UUID, latency: Double?, mac: MACAddress?) -> Device {
        let target = targets[rangeID]
        let date = now()
        let vendor = mac.flatMap { vendors.vendor(for: $0) }
        return Device(ip: ip, mac: mac, vendor: vendor, isOnline: true, latencyMs: latency,
                      vlan: target?.vlan, firstSeen: date, lastSeen: date, rangeLabel: target?.label,
                      deviceType: ScanDeviceClassifier.guess(ports: [], vendor: vendor, hostname: nil, mac: mac))
    }

    /// Entrelace plusieurs listes : a1, b1, c1, a2, b2…
    static func interleave<T>(_ lists: [[T]]) -> [T] {
        var result: [T] = []
        result.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count { result.append(list[index]) }
        }
        return result
    }
}

// MARK: - Type d'appareil

/// Devine la famille d'un appareil d'après ses ports ouverts, son fabricant et son nom.
public enum ScanDeviceClassifier {
    static let printerPorts: Set<UInt16> = [9100, 631, 515]
    static let cameraPorts: Set<UInt16> = [554, 8554, 37777]
    static let cameraVendors = ["hikvision", "axis", "dahua", "hanwha", "vivotek", "uniview", "reolink"]
    static let printerVendors = ["brother", "epson", "canon", "xerox", "lexmark", "kyocera", "ricoh", "konica"]
    static let networkVendors = ["cisco", "aruba", "juniper", "netgear", "tp-link", "d-link", "mikrotik", "ubiquiti", "meraki"]
    static let iotVendors = ["espressif", "tuya", "sonos", "shelly", "brightsign", "amazon", "google", "roku", "raspberry"]
    static let phoneHints = ["android", "iphone", "ipad", "galaxy", "pixel", "redmi", "oneplus"]

    public static func guess(ports: [UInt16], vendor: String?, hostname: String?, mac: MACAddress?) -> DeviceType {
        let open = Set(ports)
        let vendor = (vendor ?? "").lowercased()
        let host = (hostname ?? "").lowercased()
        let vendorIs: ([String]) -> Bool = { names in names.contains { vendor.contains($0) } }

        if !open.isDisjoint(with: printerPorts) || vendorIs(printerVendors) { return .imprimante }
        if !open.isDisjoint(with: cameraPorts) || vendorIs(cameraVendors) { return .camera }
        if open.contains(88) && open.contains(389) || open.contains(53) && open.contains(389) { return .serveur }
        if host.hasPrefix("fortiap") || host.contains("-ap-") || host.hasPrefix("uap") { return .pointAcces }
        if open.contains(541) || vendor.contains("fortinet") || host.hasPrefix("fortigate") { return .routeur }
        if open.contains(8291) { return .routeur }
        if open.contains(161) && (vendorIs(networkVendors) || host.hasPrefix("sw")) { return .switch }
        if open.contains(3389) { return .poste }
        if phoneHints.contains(where: { host.contains($0) }) { return .telephone }
        if open.contains(1883) || open.contains(8883) || vendorIs(iotVendors) { return .iot }
        if open.contains(445) || open.contains(135) || open.contains(5900) { return .poste }
        if vendor.contains("apple") || vendor.contains("dell") || vendor.contains("lenovo") || vendor.contains("intel") {
            return .poste
        }
        if vendorIs(networkVendors) { return open.contains(161) ? .switch : .routeur }
        _ = mac
        return .inconnu
    }
}
