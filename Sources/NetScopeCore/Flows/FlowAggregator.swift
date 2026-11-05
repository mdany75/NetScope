import Foundation

// Note 75 : agrégation des flux par fenêtre d'une minute, par exportateur : appareils du réseau
// local (sources), destinations, conversations, applications (ports de service) et interfaces.
// Mémoire bornée : chaque fenêtre garde un nombre limité de lignes par tableau (le reste est compté
// dans « autres ») ; les fenêtres d'une minute de plus d'une heure sont fondues en fenêtres d'une
// heure, et rien n'est gardé au-delà de 24 heures. Rien n'est écrit sur disque.

/// Volumes d'une ligne (appareil, destination, application, conversation).
public struct FlowVolume: Hashable, Sendable {
    /// Octets envoyés par l'appareil local (ou vers la destination).
    public var sent: UInt64 = 0
    /// Octets reçus par l'appareil local (ou depuis la destination).
    public var received: UInt64 = 0
    public var packets: UInt64 = 0
    /// Enregistrements de flux (ou échantillons sFlow) comptés.
    public var flows: Int = 0

    public init(sent: UInt64 = 0, received: UInt64 = 0, packets: UInt64 = 0, flows: Int = 0) {
        self.sent = sent
        self.received = received
        self.packets = packets
        self.flows = flows
    }

    public var bytes: UInt64 { FlowMath.add(sent, received) }

    mutating func merge(_ other: FlowVolume) {
        sent = FlowMath.add(sent, other.sent)
        received = FlowMath.add(received, other.received)
        packets = FlowMath.add(packets, other.packets)
        flows += other.flows
    }
}

/// Appareil local ou destination, avec ses volumes.
public struct FlowHostTotal: Hashable, Sendable, Identifiable {
    public var ip: IPv4Address
    public var volume: FlowVolume
    public var id: IPv4Address { ip }
}

public struct FlowApplicationTotal: Hashable, Sendable, Identifiable {
    public var application: FlowApplication
    public var volume: FlowVolume
    public var id: String { application.name }
}

/// Conversation : appareil local, destination, protocole et port de service.
public struct FlowConversationTotal: Hashable, Sendable, Identifiable {
    public var local: IPv4Address
    public var remote: IPv4Address
    public var proto: UInt8
    public var port: UInt16
    public var application: FlowApplication
    public var volume: FlowVolume
    /// Plus longue durée vue (ms), si l'exportateur la donne.
    public var durationMs: UInt32?
    public var id: String { "\(local)|\(remote)|\(proto)|\(port)" }
}

/// Interface d'un exportateur (ifIndex) : volumes vus dans les flux et compteurs sFlow.
public struct FlowInterfaceTotal: Hashable, Sendable, Identifiable {
    public var index: UInt32
    /// Octets entrés et sortis par cette interface, d'après les flux.
    public var inBytes: UInt64
    public var outBytes: UInt64
    public var flows: Int
    /// Compteurs sFlow : vitesse (b/s) et débits mesurés (b/s).
    public var speed: UInt64?
    public var counterInBps: Double?
    public var counterOutBps: Double?
    public var isUp: Bool?
    public var errors: UInt64
    public var discards: UInt64
    /// Interface vers Internet (devinée d'après les flux, ou choisie).
    public var isWAN: Bool
    public var id: UInt32 { index }
}

/// Synthèse d'un exportateur sur une fenêtre de temps.
public struct FlowSummary: Hashable, Sendable, Identifiable {
    public var exporter: IPv4Address
    public var kinds: Set<FlowProtocolKind>
    /// Durée réellement couverte (secondes) : sert au calcul des débits.
    public var span: TimeInterval
    public var window: TimeInterval
    public var lastSeen: Date?
    public var hosts: [FlowHostTotal]
    public var remotes: [FlowHostTotal]
    public var applications: [FlowApplicationTotal]
    public var conversations: [FlowConversationTotal]
    public var interfaces: [FlowInterfaceTotal]
    /// Interface vers Internet devinée (la plus empruntée par le trafic vers des adresses publiques).
    public var wanInterface: UInt32?
    public var total: FlowVolume
    /// Octets comptés hors des tableaux (au-delà des lignes gardées par fenêtre).
    public var overflowBytes: UInt64
    public var ipv6Flows: Int
    /// Plus fort échantillonnage vu (1 : aucun).
    public var maxSampling: UInt32

    public var id: IPv4Address { exporter }
    public var isEmpty: Bool { total.flows == 0 && interfaces.allSatisfy { $0.counterInBps == nil } }

    /// Débit moyen (b/s) d'un volume sur la durée couverte.
    public func rate(_ bytes: UInt64) -> Double {
        span > 0 ? Double(bytes) * 8 / span : 0
    }
}

public struct FlowAggregator: Sendable {
    public struct Limits: Sendable {
        public var hostsPerWindow = 400
        public var remotesPerWindow = 400
        public var conversationsPerWindow = 600
        public var applicationsPerWindow = 150
        public var interfacesPerWindow = 128
        /// Fenêtres d'une minute gardées (une heure), puis fenêtres d'une heure (24 h).
        public var minuteWindows = 60
        public var hourWindows = 24
        public var maxExporters = 64
        public init() {}
    }

    struct ConversationKey: Hashable, Sendable {
        var local: IPv4Address
        var remote: IPv4Address
        var proto: UInt8
        var port: UInt16
    }

    struct ConversationValue: Sendable {
        var application: FlowApplication
        var volume = FlowVolume()
        var durationMs: UInt32?
    }

    struct InterfaceValue: Sendable {
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var flows = 0
    }

    struct Window: Sendable {
        var start: Date
        var length: TimeInterval
        var hosts: [IPv4Address: FlowVolume] = [:]
        var remotes: [IPv4Address: FlowVolume] = [:]
        var applications: [String: (FlowApplication, FlowVolume)] = [:]
        var conversations: [ConversationKey: ConversationValue] = [:]
        var interfaces: [UInt32: InterfaceValue] = [:]
        var wanVotes: [UInt32: UInt64] = [:]
        var total = FlowVolume()
        var overflow: UInt64 = 0
        var ipv6Flows = 0
        var kinds: Set<FlowProtocolKind> = []
        var maxSampling: UInt32 = 1

        init(start: Date, length: TimeInterval) {
            self.start = start
            self.length = length
        }

        var end: Date { start.addingTimeInterval(length) }
    }

    struct CounterState: Sendable {
        var last: FlowInterfaceCounters
        var date: Date
        var inBps: Double?
        var outBps: Double?
        var errors: UInt64 = 0
        var discards: UInt64 = 0
    }

    struct Exporter: Sendable {
        var firstSeen: Date
        var lastSeen: Date
        var minutes: [Window] = []
        var hours: [Window] = []
        var counters: [UInt32: CounterState] = [:]
    }

    public var limits: Limits
    var exporters: [IPv4Address: Exporter] = [:]

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var exporterAddresses: [IPv4Address] { exporters.keys.sorted() }

    public func lastSeen(_ exporter: IPv4Address) -> Date? { exporters[exporter]?.lastSeen }

    /// Vrai si l'exportateur est déjà suivi, ou s'il reste de la place pour lui.
    public func accepts(_ exporter: IPv4Address) -> Bool {
        exporters[exporter] != nil || exporters.count < limits.maxExporters
    }

    public mutating func forget(exporter: IPv4Address) { exporters[exporter] = nil }

    public mutating func removeAll() { exporters = [:] }

    // MARK: Ajout

    /// Ajoute les flux et les compteurs d'un datagramme décodé. Faux si l'exportateur est refusé
    /// (trop d'exportateurs).
    @discardableResult
    public mutating func add(_ result: FlowDecodeResult, from exporter: IPv4Address, at date: Date) -> Bool {
        guard touch(exporter, at: date) else { return false }
        for record in result.records { add(record, at: date) }
        for counter in result.counters { add(counter, at: date) }
        return true
    }

    private mutating func touch(_ exporter: IPv4Address, at date: Date) -> Bool {
        if var state = exporters[exporter] {
            state.lastSeen = max(state.lastSeen, date)
            state.firstSeen = min(state.firstSeen, date)
            exporters[exporter] = state
            return true
        }
        guard exporters.count < limits.maxExporters else { return false }
        exporters[exporter] = Exporter(firstSeen: date, lastSeen: date)
        return true
    }

    public mutating func add(_ record: FlowRecord, at date: Date) {
        guard touch(record.exporter, at: date), var state = exporters[record.exporter] else { return }
        let minute = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let limits = self.limits
        // Fenêtre d'une minute (ou d'une heure pour un flux de plus d'une heure).
        let newest = state.minutes.last?.start ?? minute
        if minute < newest.addingTimeInterval(-Double(limits.minuteWindows - 1) * 60) {
            let hour = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
            let index = Self.window(in: &state.hours, start: hour, length: 3600)
            Self.add(record, to: &state.hours[index], limits: limits)
        } else {
            let index = Self.window(in: &state.minutes, start: minute, length: 60)
            Self.add(record, to: &state.minutes[index], limits: limits)
        }
        Self.compact(&state, limits: limits)
        exporters[record.exporter] = state
    }

    /// Indice de la fenêtre qui commence à `start` (créée au besoin, liste gardée triée).
    private static func window(in list: inout [Window], start: Date, length: TimeInterval) -> Int {
        if let last = list.last, last.start == start { return list.count - 1 }
        if let index = list.firstIndex(where: { $0.start == start }) { return index }
        let insert = list.firstIndex { $0.start > start } ?? list.count
        list.insert(Window(start: start, length: length), at: insert)
        return insert
    }

    private static func add(_ record: FlowRecord, to window: inout Window, limits: Limits) {
        let bytes = record.estimatedBytes
        let reverse = record.estimatedReverseBytes
        let packets = record.estimatedPackets
        let all = FlowMath.add(bytes, reverse)
        window.kinds.insert(record.kind)
        window.maxSampling = max(window.maxSampling, record.samplingRate)
        // Le volume « hors tableaux » est compté une seule fois par enregistrement, même si
        // plusieurs tableaux sont pleins.
        var overflowed = false
        defer { if overflowed { window.overflow = FlowMath.add(window.overflow, all) } }
        // Interfaces : le flux entre par l'une et sort par l'autre (le sens inverse à l'envers).
        if let input = record.inputInterface, input != 0 {
            bump(&window.interfaces, input, limits.interfacesPerWindow, &overflowed) {
                $0.inBytes = FlowMath.add($0.inBytes, bytes)
                $0.outBytes = FlowMath.add($0.outBytes, reverse)
                $0.flows += 1
            }
        }
        if let output = record.outputInterface, output != 0 {
            bump(&window.interfaces, output, limits.interfacesPerWindow, &overflowed) {
                $0.outBytes = FlowMath.add($0.outBytes, bytes)
                $0.inBytes = FlowMath.add($0.inBytes, reverse)
                $0.flows += 1
            }
        }
        guard !record.isIPv6, let (local, remote, outbound) = FlowApplications.orient(record) else {
            if record.isIPv6 { window.ipv6Flows += 1 }
            window.total.merge(FlowVolume(sent: bytes, received: reverse, packets: packets, flows: 1))
            return
        }
        let volume = outbound
            ? FlowVolume(sent: bytes, received: reverse, packets: packets, flows: 1)
            : FlowVolume(sent: reverse, received: bytes, packets: packets, flows: 1)
        window.total.merge(volume)
        bump(&window.hosts, local, limits.hostsPerWindow, &overflowed) { $0.merge(volume) }
        bump(&window.remotes, remote, limits.remotesPerWindow, &overflowed) { $0.merge(volume) }
        let port = FlowApplications.servicePort(proto: record.proto, sourcePort: record.sourcePort, destinationPort: record.destinationPort)
        let app = FlowApplications.application(proto: record.proto, port: port)
        if window.applications[app.name] != nil || window.applications.count < limits.applicationsPerWindow {
            var entry = window.applications[app.name] ?? (app, FlowVolume())
            entry.1.merge(volume)
            window.applications[app.name] = entry
        } else {
            overflowed = true
        }
        let key = ConversationKey(local: local, remote: remote, proto: record.proto, port: port)
        if window.conversations[key] != nil || window.conversations.count < limits.conversationsPerWindow {
            var value = window.conversations[key] ?? ConversationValue(application: app)
            value.volume.merge(volume)
            if let duration = record.durationMs { value.durationMs = max(value.durationMs ?? 0, duration) }
            window.conversations[key] = value
        } else {
            overflowed = true
        }
        // Interface vers Internet : celle par où sort le trafic vers une adresse publique (ou par
        // où il entre depuis une adresse publique).
        if !FlowApplications.isLocal(remote) {
            let wan = outbound ? record.outputInterface : record.inputInterface
            if let wan, wan != 0 { window.wanVotes[wan, default: 0] = FlowMath.add(window.wanVotes[wan, default: 0], all) }
        }
    }

    /// Met à jour une ligne existante, ou en crée une si le tableau n'est pas plein (sinon le volume
    /// va dans « autres »).
    private static func bump<K: Hashable, V: Sendable>(_ map: inout [K: V], _ key: K, _ cap: Int, _ overflowed: inout Bool,
                                                       _ update: (inout V) -> Void) where V: DefaultInit {
        if map[key] == nil {
            guard map.count < cap else {
                overflowed = true
                return
            }
            map[key] = V.empty
        }
        update(&map[key]!)
    }

    // MARK: Compteurs sFlow

    /// Débit au-delà duquel un compteur d'interface est jugé faux (1 Tb/s).
    static let maxCounterBps: Double = 1e12

    public mutating func add(_ counters: FlowInterfaceCounters, at date: Date) {
        guard touch(counters.exporter, at: date), var state = exporters[counters.exporter] else { return }
        var entry = state.counters[counters.ifIndex] ?? CounterState(last: counters, date: date)
        if entry.date < date {
            let dt = date.timeIntervalSince(entry.date)
            // Compteur remis à zéro (redémarrage) : pas de débit cette fois.
            if dt >= 1, counters.inOctets >= entry.last.inOctets, counters.outOctets >= entry.last.outOctets {
                // Un débit absurde (compteur forgé ou saut de 0 à une valeur énorme) est ignoré :
                // plus de 8 fois la vitesse annoncée, ou plus de 1 Tb/s.
                let ceiling = min(Self.maxCounterBps, counters.speed > 0 ? Double(counters.speed) * 8 : Self.maxCounterBps)
                let inBps = Double(counters.inOctets - entry.last.inOctets) * 8 / dt
                let outBps = Double(counters.outOctets - entry.last.outOctets) * 8 / dt
                entry.inBps = inBps.isFinite && inBps <= ceiling ? inBps : nil
                entry.outBps = outBps.isFinite && outBps <= ceiling ? outBps : nil
            }
            let errors = UInt64(counters.inErrors) + UInt64(counters.outErrors)
            let previousErrors = UInt64(entry.last.inErrors) + UInt64(entry.last.outErrors)
            if errors >= previousErrors { entry.errors = FlowMath.add(entry.errors, errors - previousErrors) }
            let discards = UInt64(counters.inDiscards) + UInt64(counters.outDiscards)
            let previousDiscards = UInt64(entry.last.inDiscards) + UInt64(entry.last.outDiscards)
            if discards >= previousDiscards { entry.discards = FlowMath.add(entry.discards, discards - previousDiscards) }
            entry.last = counters
            entry.date = date
        }
        if state.counters[counters.ifIndex] != nil || state.counters.count < limits.interfacesPerWindow {
            state.counters[counters.ifIndex] = entry
        }
        exporters[counters.exporter] = state
    }

    // MARK: Mémoire bornée

    /// Fond les fenêtres d'une minute de plus d'une heure en fenêtres d'une heure et oublie ce qui
    /// date de plus de 24 h (appelé à chaque ajout et régulièrement par le collecteur).
    public mutating func prune(now: Date) {
        for address in exporters.keys {
            guard var state = exporters[address] else { continue }
            Self.compact(&state, limits: limits, now: now)
            if state.minutes.isEmpty, state.hours.isEmpty, now.timeIntervalSince(state.lastSeen) > Double(limits.hourWindows) * 3600 {
                exporters[address] = nil
            } else {
                exporters[address] = state
            }
        }
    }

    private static func compact(_ state: inout Exporter, limits: Limits, now: Date? = nil) {
        let reference = max(now ?? .distantPast, state.minutes.last?.start ?? .distantPast)
        let minuteLimit = reference.addingTimeInterval(-Double(limits.minuteWindows - 1) * 60)
        while let first = state.minutes.first, first.start < minuteLimit {
            state.minutes.removeFirst()
            let hour = Date(timeIntervalSince1970: (first.start.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
            let index = window(in: &state.hours, start: hour, length: 3600)
            merge(first, into: &state.hours[index], limits: limits)
        }
        let hourLimit = reference.addingTimeInterval(-Double(limits.hourWindows) * 3600)
        state.hours.removeAll { $0.end <= hourLimit }
    }

    /// Fond une fenêtre dans une autre en gardant les plus grosses lignes (le reste va dans « autres »).
    static func merge(_ source: Window, into target: inout Window, limits: Limits) {
        target.total.merge(source.total)
        target.overflow = FlowMath.add(target.overflow, source.overflow)
        target.ipv6Flows += source.ipv6Flows
        target.kinds.formUnion(source.kinds)
        target.maxSampling = max(target.maxSampling, source.maxSampling)
        for (key, value) in source.hosts { target.hosts[key, default: FlowVolume()].merge(value) }
        for (key, value) in source.remotes { target.remotes[key, default: FlowVolume()].merge(value) }
        for (key, value) in source.applications {
            var entry = target.applications[key] ?? (value.0, FlowVolume())
            entry.1.merge(value.1)
            target.applications[key] = entry
        }
        for (key, value) in source.conversations {
            var entry = target.conversations[key] ?? ConversationValue(application: value.application)
            entry.volume.merge(value.volume)
            if let d = value.durationMs { entry.durationMs = max(entry.durationMs ?? 0, d) }
            target.conversations[key] = entry
        }
        for (key, value) in source.interfaces {
            var entry = target.interfaces[key] ?? InterfaceValue()
            entry.inBytes = FlowMath.add(entry.inBytes, value.inBytes)
            entry.outBytes = FlowMath.add(entry.outBytes, value.outBytes)
            entry.flows += value.flows
            target.interfaces[key] = entry
        }
        for (key, value) in source.wanVotes { target.wanVotes[key] = FlowMath.add(target.wanVotes[key] ?? 0, value) }
        // Un même volume peut sortir de plusieurs tableaux : on ne compte que le plus gros des
        // débordements, pour ne pas le compter plusieurs fois.
        let dropped = [
            trim(&target.hosts, limits.hostsPerWindow, bytes: { $0.bytes }),
            trim(&target.remotes, limits.remotesPerWindow, bytes: { $0.bytes }),
            trim(&target.applications, limits.applicationsPerWindow, bytes: { $0.1.bytes }),
            trim(&target.conversations, limits.conversationsPerWindow, bytes: { $0.volume.bytes }),
        ].max() ?? 0
        target.overflow = FlowMath.add(target.overflow, dropped)
    }

    /// Garde les `cap` plus grosses lignes et renvoie le volume des lignes retirées.
    private static func trim<K: Hashable, V>(_ map: inout [K: V], _ cap: Int, bytes: (V) -> UInt64) -> UInt64 {
        guard map.count > cap else { return 0 }
        let sorted = map.sorted { bytes($0.value) > bytes($1.value) }
        var dropped: UInt64 = 0
        for (key, value) in sorted.dropFirst(cap) {
            dropped = FlowMath.add(dropped, bytes(value))
            map[key] = nil
        }
        return dropped
    }

    /// Nombre de lignes gardées en mémoire (tous exportateurs, toutes fenêtres) : sert aux tests
    /// de la mémoire bornée.
    public var storedRows: Int {
        exporters.values.reduce(0) { sum, state in
            (state.minutes + state.hours).reduce(sum) { $0 + $1.hosts.count + $1.remotes.count + $1.applications.count + $1.conversations.count + $1.interfaces.count }
        }
    }

    public var windowCount: Int { exporters.values.reduce(0) { $0 + $1.minutes.count + $1.hours.count } }

    // MARK: Lecture

    /// Synthèse d'un exportateur sur les `window` dernières secondes.
    public func summary(exporter: IPv4Address, window: TimeInterval, now: Date, wanOverride: UInt32? = nil,
                        top: Int = 200) -> FlowSummary? {
        guard let state = exporters[exporter] else { return nil }
        let from = now.addingTimeInterval(-window)
        var merged = Window(start: from, length: window)
        var unlimited = limits
        unlimited.hostsPerWindow = .max
        unlimited.remotesPerWindow = .max
        unlimited.applicationsPerWindow = .max
        unlimited.conversationsPerWindow = .max
        for item in state.hours + state.minutes where item.end > from && item.start <= now {
            Self.merge(item, into: &merged, limits: unlimited)
        }
        // Débits sur la durée réellement couverte : des fenêtres entières (une minute ou une heure
        // commencée avant `from` compte en entier), mais pas avant le premier datagramme reçu.
        let earliest = (state.hours + state.minutes).filter { $0.end > from && $0.start <= now }.map(\.start).min() ?? from
        let span = max(now.timeIntervalSince(max(earliest, state.firstSeen)), 10)
        let wan = wanOverride ?? merged.wanVotes.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        func hosts(_ map: [IPv4Address: FlowVolume]) -> [FlowHostTotal] {
            map.map { FlowHostTotal(ip: $0.key, volume: $0.value) }
                .sorted { $0.volume.bytes == $1.volume.bytes ? $0.ip < $1.ip : $0.volume.bytes > $1.volume.bytes }
                .prefix(top).map { $0 }
        }
        let applications: [FlowApplicationTotal] = merged.applications.values
            .map { (pair: (FlowApplication, FlowVolume)) -> FlowApplicationTotal in FlowApplicationTotal(application: pair.0, volume: pair.1) }
            .sorted { (a: FlowApplicationTotal, b: FlowApplicationTotal) -> Bool in
                a.volume.bytes == b.volume.bytes ? a.application.name < b.application.name : a.volume.bytes > b.volume.bytes
            }
        var conversations: [FlowConversationTotal] = []
        conversations.reserveCapacity(merged.conversations.count)
        for (key, value) in merged.conversations {
            conversations.append(FlowConversationTotal(local: key.local, remote: key.remote, proto: key.proto, port: key.port,
                                                       application: value.application, volume: value.volume, durationMs: value.durationMs))
        }
        conversations.sort { (a: FlowConversationTotal, b: FlowConversationTotal) -> Bool in
            a.volume.bytes == b.volume.bytes ? a.id < b.id : a.volume.bytes > b.volume.bytes
        }
        if conversations.count > top { conversations.removeLast(conversations.count - top) }
        // Interfaces vues dans les flux ou dans les compteurs sFlow.
        let fresh = state.counters.filter { now.timeIntervalSince($0.value.date) < max(window, 300) + 120 }
        let indexes = Set(merged.interfaces.keys).union(fresh.keys)
        let interfaces = indexes.map { index -> FlowInterfaceTotal in
            let value = merged.interfaces[index] ?? InterfaceValue()
            let counter = fresh[index]
            return FlowInterfaceTotal(index: index, inBytes: value.inBytes, outBytes: value.outBytes, flows: value.flows,
                                      speed: counter.flatMap { $0.last.speed > 0 ? $0.last.speed : nil },
                                      counterInBps: counter?.inBps, counterOutBps: counter?.outBps, isUp: counter?.last.isUp,
                                      errors: counter?.errors ?? 0, discards: counter?.discards ?? 0, isWAN: index == wan)
        }
        .sorted { a, b in
            if a.isWAN != b.isWAN { return a.isWAN }
            let (ab, bb) = (FlowMath.add(a.inBytes, a.outBytes), FlowMath.add(b.inBytes, b.outBytes))
            return ab == bb ? a.index < b.index : ab > bb
        }
        return FlowSummary(exporter: exporter, kinds: merged.kinds, span: span, window: window, lastSeen: state.lastSeen,
                           hosts: hosts(merged.hosts), remotes: hosts(merged.remotes), applications: applications,
                           conversations: conversations, interfaces: interfaces, wanInterface: wan, total: merged.total,
                           overflowBytes: merged.overflow, ipv6Flows: merged.ipv6Flows, maxSampling: merged.maxSampling)
    }
}

/// Valeur créée vide (lignes des tableaux de l'agrégation).
protocol DefaultInit {
    static var empty: Self { get }
}

extension FlowVolume: DefaultInit {
    static var empty: FlowVolume { FlowVolume() }
}

extension FlowAggregator.InterfaceValue: DefaultInit {
    static var empty: Self { Self() }
}
