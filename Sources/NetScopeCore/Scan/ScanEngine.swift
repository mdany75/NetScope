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
    /// Ports d'un préréglage choisi à part du profil (note 19) ; nil : ports du profil.
    public var portOverride: [UInt16]?
    /// Méthodes de découverte du profil (par défaut : comportement d'avant la 0.8).
    public var methods = ScanMethods()
    /// Délai de chaque sonde de présence TCP ou UDP (adresses muettes au ping).
    public var presenceTimeout: Duration = .milliseconds(500)
    /// Note 82 : adresses exclues du site, jamais sondées (ni ping, ni TCP/UDP, ni noms, ni ports) ;
    /// une entrée de la table ARP à une adresse exclue est ignorée.
    public var exclusions = AddressExclusions.none

    public init(profile: ScanProfile = .rapide, customPorts: [UInt16] = [], concurrency: Int = 128,
                pingTimeout: Duration = .milliseconds(1000), portTimeout: Duration? = nil,
                resolveNames: Bool = true, nameTimeout: Duration = .seconds(2), useARP: Bool = true) {
        self.profile = profile
        self.customPorts = customPorts
        self.concurrency = max(1, concurrency)
        self.pingTimeout = pingTimeout
        // Rapide : 400 ms suffisent sur un réseau local (un port filtré coûte ce délai à chaque hôte).
        self.portTimeout = portTimeout ?? (profile == .rapide ? .milliseconds(400) : .milliseconds(800))
        self.resolveNames = resolveNames
        self.nameTimeout = nameTimeout
        self.useARP = useARP
    }

    /// Ports TCP sondés sur chaque hôte en ligne.
    public var ports: [UInt16] { portOverride ?? profile.ports(custom: customPorts) }
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

/// Étape du scan en cours. Les trois premières sont celles du moteur ; les deux dernières
/// (découverte SNMP des switchs, puis emplacement des appareils) sont menées par l'application.
public enum ScanPhase: String, Sendable, CaseIterable {
    /// Ping de toutes les adresses.
    case ping
    /// Lecture de la table ARP.
    case arp
    /// Noms et ports des hôtes en ligne.
    case details
    /// Découverte SNMP des switchs parmi les hôtes en ligne, puis relevé de leurs tables.
    case switches
    /// Emplacement (switch, port, VLAN) de chaque appareil d'après les tables MAC.
    case locations

    public var label: String {
        switch self {
        case .ping: return "Ping"
        case .arp: return "Table ARP"
        case .details: return "Noms et ports"
        case .switches: return "Switchs (SNMP)"
        case .locations: return "Emplacements"
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
    /// Résultat du sondage des ports d'un hôte (émis juste après le `deviceUpdated` qui le porte) :
    /// seul cet événement dit que `ports` est une réponse fraîche, les autres reprennent ce qu'on savait.
    case portsProbed(IPv4Address, open: [UInt16], rangeID: UUID)
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
    private let presence: any ScanPresenceProbing
    private let vendors: OUIDatabase
    private let now: @Sendable () -> Date

    private var targets: [UUID: ScanTarget] = [:]
    private var rangeOf: [IPv4Address: UUID] = [:]
    private var found: [IPv4Address: Device] = [:]
    private var progress: [UUID: ScanRangeProgress] = [:]
    private var progressStep: [UUID: Int] = [:]

    public init(pinger: any ScanPinging, arp: any ScanARPReading = ARPTable(),
                ports: any ScanPortProbing = PortProber(), names: any ScanNameResolving = NameResolverChain(),
                presence: any ScanPresenceProbing = ScanPresenceProber(),
                vendors: OUIDatabase = .builtIn, now: @escaping @Sendable () -> Date = { Date() }) {
        self.pinger = pinger
        self.arp = arp
        self.portProber = ports
        self.names = names
        self.presence = presence
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
        progressStep = [:]

        // Adresses dédoublonnées (une adresse de deux plages compte pour la première), puis entrelacées
        // pour que toutes les plages avancent ensemble.
        var lists: [[Job]] = []
        for target in list {
            targets[target.id] = target
            var jobs: [Job] = []
            for ip in options.exclusions.addresses(in: target.range) where rangeOf[ip] == nil {
                rangeOf[ip] = target.id
                jobs.append(Job(ip: ip, rangeID: target.id))
            }
            progress[target.id] = ScanRangeProgress(rangeID: target.id, total: jobs.count)
            progressStep[target.id] = max(1, jobs.count / 200)
            lists.append(jobs)
        }
        let jobs = ScanEngine.interleave(lists)
        continuation.yield(.started(list.compactMap { progress[$0.id] }))

        // 1. Présence : ping ICMP, puis (méthodes cochées) TCP et UDP pour les adresses muettes.
        let plan = ScanPlan(options: options, autoDiscoverSwitches: false)
        if plan.ping || plan.probesPresence {
            continuation.yield(.phase(.ping))
            let pinger = self.pinger
            let presence = self.presence
            let timeout = options.pingTimeout
            let presenceTimeout = options.presenceTimeout
            await ScanConcurrency.forEach(jobs, limit: options.concurrency) { job in
                var rtt = plan.ping ? await pinger.ping(job.ip, timeout: timeout) : nil
                if rtt == nil, plan.probesPresence, !Task.isCancelled {
                    let hit = await presence.probe(job.ip, tcpPorts: plan.presenceTCPPorts, udpPorts: plan.presenceUDPPorts,
                                                   timeout: presenceTimeout)
                    // Hôte trouvé par TCP ou UDP : en ligne, sans latence ICMP mesurée.
                    if hit != nil { rtt = -1 }
                }
                await self.recordPing(job, rtt: rtt, continuation: continuation)
            }
        } else {
            // Ni ICMP, ni TCP, ni UDP : seules les adresses de la table ARP seront trouvées.
            markAllProbed(continuation: continuation)
        }

        // 2. Table ARP : adresses MAC, et hôtes qui ne répondent pas au ping.
        if plan.arp, !Task.isCancelled {
            continuation.yield(.phase(.arp))
            recordARP(arp.read(), continuation: continuation)
        }

        // 3. Noms et ports des hôtes en ligne, en parallèle : les noms (DNS inverse, mDNS, NetBIOS)
        // passent par deux sockets partagés, les ports par des connexions TCP plafonnées.
        let ports = options.ports
        let resolveNames = plan.resolvesNames
        if !Task.isCancelled, resolveNames || !ports.isEmpty {
            continuation.yield(.phase(.details))
            let addresses = found.keys.sorted()
            let prober = portProber
            let names = self.names
            let nameLimit = max(1, min(64, options.concurrency))
            let perHost = max(1, min(ports.count, 32, options.concurrency))
            let hostLimit = max(1, options.concurrency / perHost)
            async let namesDone: Void = {
                guard resolveNames else { return }
                await ScanConcurrency.forEach(addresses, limit: nameLimit) { ip in
                    let details: NameDetails
                    if let rich = names as? any ScanNameDetailResolving {
                        details = await rich.details(for: ip, timeout: options.nameTimeout)
                    } else {
                        let name = await names.name(for: ip, timeout: options.nameTimeout)
                        details = NameDetails(hostname: name)
                    }
                    await self.recordName(ip, details: details, continuation: continuation)
                }
            }()
            async let portsDone: Void = {
                guard !ports.isEmpty else { return }
                await ScanConcurrency.forEach(addresses, limit: hostLimit) { ip in
                    let open = await prober.openPorts(ip, ports: ports, timeout: options.portTimeout, concurrency: perHost)
                    await self.recordPorts(ip, openPorts: open, continuation: continuation)
                }
            }()
            _ = await (namesDone, portsDone)
        }

        let devices = found.values.sorted { $0.ip < $1.ip }
        continuation.yield(.finished(ScanSummary(scannedAddresses: jobs.count, devices: devices,
                                                 duration: Date().timeIntervalSince(start),
                                                 cancelled: Task.isCancelled)))
    }

    // MARK: Enregistrement des résultats

    /// Toutes les adresses comptées comme sondées (aucune méthode de présence active).
    private func markAllProbed(continuation: AsyncStream<ScanEvent>.Continuation) {
        for id in progress.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var entry = progress[id] else { continue }
            entry.done = entry.total
            progress[id] = entry
            continuation.yield(.rangeProgress(entry))
        }
    }

    /// `rtt` : latence ICMP ; négative pour un hôte trouvé par TCP ou UDP (pas de latence ICMP).
    private func recordPing(_ job: Job, rtt: Double?, continuation: AsyncStream<ScanEvent>.Continuation) {
        guard var entry = progress[job.rangeID] else { return }
        entry.done += 1
        if let rtt {
            entry.online += 1
            var device = makeDevice(job.ip, rangeID: job.rangeID, latency: rtt >= 0 ? rtt : nil, mac: nil)
            // Note 68 : TTL de la réponse au ping (aucun envoi de plus).
            if rtt >= 0, let ttl = (pinger as? any ScanTTLReporting)?.replyTTL(for: job.ip) {
                device.fingerprint = FPEvidence(ttl: ttl)
            }
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
                device.deviceType = ScanDeviceClassifier.guess(device)
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

    private func recordName(_ ip: IPv4Address, details: NameDetails, continuation: AsyncStream<ScanEvent>.Continuation) {
        guard var device = found[ip], let rangeID = rangeOf[ip] else { return }
        if let hostname = details.hostname {
            device.hostname = hostname
            device.nameSource = details.source
        }
        if let domain = details.netbiosDomain { device.nameDomain = domain }
        // NetBIOS annonce la MAC : utile quand l'ARP ne l'a pas (hôte d'un autre réseau).
        if device.mac == nil, let mac = details.netbiosMAC, mac.value != 0, !mac.isMulticast {
            device.mac = mac
            device.vendor = vendors.vendor(for: mac)
        }
        device.lastSeen = now()
        device.deviceType = ScanDeviceClassifier.guess(device)
        found[ip] = device
        continuation.yield(.deviceUpdated(device, rangeID: rangeID))
    }

    private func recordPorts(_ ip: IPv4Address, openPorts: [UInt16], continuation: AsyncStream<ScanEvent>.Continuation) {
        guard var device = found[ip], let rangeID = rangeOf[ip] else { return }
        device.openPorts = openPorts
        device.lastSeen = now()
        device.deviceType = ScanDeviceClassifier.guess(device)
        found[ip] = device
        continuation.yield(.deviceUpdated(device, rangeID: rangeID))
        continuation.yield(.portsProbed(ip, open: openPorts, rangeID: rangeID))
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
    /// Note 98 : fabricants de cartes réseau d’onduleurs.
    static let upsVendors = ["eaton", "powerware", "cyberpower", "cyber-power", "tripp", "riello", "socomec"]
    static let printerVendors = ["brother", "epson", "canon", "xerox", "lexmark", "kyocera", "ricoh", "konica"]
    static let networkVendors = ["cisco", "aruba", "juniper", "netgear", "tp-link", "d-link", "mikrotik", "ubiquiti", "meraki"]
    static let iotVendors = ["espressif", "sonos", "brightsign", "amazon", "google", "roku", "raspberry"]
    static let consoleVendors = ["nintendo", "valve"]
    static let consoleHints = ["xbox", "playstation", "ps4", "ps5", "nintendo", "steamdeck", "steam-deck"]
    static let homeVendors = ["signify", "lutron", "ecobee", "tuya", "shelly", "itead", "hubitat", "philips-hue"]
    static let homeHints = ["homeassistant", "home-assistant", "hue-bridge", "philips-hue", "ecobee", "nest-",
                            "shelly", "tasmota", "zigbee", "hubitat", "smartthings", "lutron", "sonoff"]
    static let phoneHints = ["android", "iphone", "ipad", "galaxy", "pixel", "redmi", "oneplus"]

    /// Type d'un appareil d'après tout ce qu'on en sait (ports, fabricant, nom, découverte SNMP).
    public static func guess(_ device: Device) -> DeviceType {
        // Note 68 : une empreinte forte (certificat Fortinet, sysDescr, en-tête d'imprimante…) passe
        // avant les ports et le fabricant, mais pas avant la découverte SNMP. Le type choisi à la main
        // reste prioritaire à l'affichage (fiche d'inventaire).
        if device.snmpKind == nil || device.snmpKind == .autre, device.fingerprint != nil,
           let type = device.fingerprintReport.strongType {
            return type
        }
        return guess(ports: device.openPorts, vendor: device.vendor, hostname: device.hostname, mac: device.mac,
              snmpKind: device.snmpKind, voip: device.voipSignals ?? [])
    }

    /// La découverte SNMP fait foi quand elle a répondu (switch, routeur, imprimante) ; sinon
    /// ports, fabricant et nom. SNMP passe par UDP : aucun port TCP ne le révèle. `voip` : annonce
    /// LLDP / CDP « téléphone » et VLAN voix, quand NetScope les connaît (note 30).
    public static func guess(ports: [UInt16], vendor: String?, hostname: String?, mac: MACAddress?,
                             snmpKind: SNMPDeviceKind? = nil, voip: VoIPSignals = []) -> DeviceType {
        switch snmpKind {
        case .switch?: return .switch
        case .routeur?: return .routeur
        case .imprimante?: return .imprimante
        case .onduleur?: return .onduleur
        case .autre?, nil: break
        }
        let open = Set(ports)
        let vendor = (vendor ?? "").lowercased()
        let host = (hostname ?? "").lowercased()
        // Mots entiers du fabricant : la base IEEE complète contient « Intelbras », « Amazonia »,
        // « Stereotaxis »… qui ne sont ni Intel, ni Amazon, ni Axis.
        let vendorWords = Set(vendor.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }).map(String.init))
        let vendorIs: ([String]) -> Bool = { names in names.contains(where: vendorWords.contains) }
        let switchName = host.hasPrefix("sw") || host.contains("switch")

        if !open.isDisjoint(with: printerPorts) || vendorIs(printerVendors) { return .imprimante }
        if !open.isDisjoint(with: cameraPorts) || vendorIs(cameraVendors) { return .camera }
        // Note 98 : cartes réseau d'onduleurs (APC, Eaton, CyberPower) ; le nom IEEE d'APC est
        // « American Power Conversion ».
        if vendor.contains("american power conversion") || vendorIs(upsVendors) || host.hasPrefix("ups-") || host.hasPrefix("ups_") { return .onduleur }
        if open.contains(88) && open.contains(389) || open.contains(53) && open.contains(389) { return .serveur }
        // Note 6 : serveur RustDesk (hbbs 21116, relais hbbr 21117).
        if RustDeskPorts.role(openPorts: ports)?.isServer == true { return .serveur }
        // Téléphones IP de bureau (note 30), avant les équipements réseau des mêmes fabricants
        // (FortiFone, Cisco) et avant les cellulaires, qui n'en sont jamais.
        if VoIPClassifier.isIPPhone(open: open, vendorWords: vendorWords, vendor: vendor, host: host, mac: mac, signals: voip) {
            return .telephoneIP
        }
        if host.hasPrefix("fortiap") || host.contains("-ap-") || host.hasPrefix("uap") { return .pointAcces }
        if open.contains(541) || vendorIs(["fortinet"]) || host.hasPrefix("fortigate") { return .routeur }
        if open.contains(8291) { return .routeur }
        if vendorIs(networkVendors) && switchName { return .switch }
        if open.contains(3389) { return .poste }
        if phoneHints.contains(where: { host.contains($0) }) { return .telephone }
        if vendorIs(consoleVendors) || vendor.contains("sony interactive")
            || consoleHints.contains(where: { host.contains($0) }) { return .console }
        // 8123 : Home Assistant ; 1400 n'est pas pris (Sonos est un objet connecté).
        if open.contains(8123) || vendorIs(homeVendors) || homeHints.contains(where: { host.contains($0) }) {
            return .domotique
        }
        if open.contains(1883) || open.contains(8883) || vendorIs(iotVendors) { return .iot }
        if open.contains(445) || open.contains(135) || open.contains(5900) { return .poste }
        // Note 6 : accès IP direct de RustDesk (21118 seul) : un poste qu'on dépanne.
        if RustDeskPorts.role(openPorts: ports) == .client { return .poste }
        if vendorIs(["apple", "dell", "lenovo", "intel"]) {
            return .poste
        }
        if vendorIs(networkVendors) { return .routeur }
        _ = mac
        return .inconnu
    }
}
