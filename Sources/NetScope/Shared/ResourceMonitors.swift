import AppKit
import Foundation
import NetScopeCore
import UniformTypeIdentifiers

// Relevés des ressources (note 21) partagés par la fiche Appareil, Switchs et ports et la barre de
// menus : ce Mac (lecture locale) et les agents SNMP. Les relevés ne tournent que tant qu'une vue
// les regarde (`retain` / `release`) ; l'historique reste en mémoire (5 minutes), rien sur le disque
// sauf l'intervalle choisi. En démonstration, les données viennent de DevTools/ResourceDemo.swift.

/// Retour d'un export : message et ton (succès ou échec), effacé après quelques secondes.
struct ResourceToast: Equatable {
    var text: String
    var isError: Bool
}

/// Débit d'une interface de ce Mac.
struct LocalInterfaceLoad: Identifiable, Hashable {
    var id: String { name }
    var name: String
    /// « Wi-Fi », « Ethernet », « VPN ».
    var kind: String
    var counters: TrafficCounters
    var rate: TrafficRate?
}

/// Ressources de ce Mac : processeur, mémoire, réseau par interface.
@MainActor
final class LocalResourceMonitor: ObservableObject {
    static let shared = LocalResourceMonitor()

    @Published private(set) var cpu: CPULoad?
    @Published private(set) var memory: MemoryStats?
    @Published private(set) var interfaces: [LocalInterfaceLoad] = []
    /// Volumes montés (disque de démarrage d'abord), relus à chaque relevé.
    @Published private(set) var volumes: [LocalVolume] = []
    @Published private(set) var timeline = ResourceTimeline(window: 300)
    @Published private(set) var isPaused = false
    @Published private(set) var lastSample: Date?
    /// Cœurs de performance et d'efficacité (Apple silicon).
    @Published private(set) var coreKinds: (performance: Int, efficiency: Int)?
    @Published var interval: Double {
        didSet {
            guard interval != oldValue else { return }
            if !isDemo { UserDefaults.standard.set(interval, forKey: Self.intervalKey) }
            restart()
        }
    }
    @Published private(set) var toast: ResourceToast?

    let isDemo: Bool
    private var users = 0
    private var task: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var previousTicks: [CPUTicks] = []
    private var previousInterfaces: [String: TrafficCounters] = [:]
    private var previousDate: Date?
    private var kinds: [String: String] = [:]
    private static let intervalKey = "NetScope.ressources.intervalle.local"

    init(demo: Bool = Launcher.isDemo) {
        isDemo = demo
        let saved = demo ? 0 : UserDefaults.standard.double(forKey: Self.intervalKey)
        interval = ResourceInterval.local.contains(saved) ? saved : 2
        if demo { ResourceDemo.fillLocal(self) }
    }

    /// Une vue commence à regarder : les relevés démarrent au premier regard.
    func retain() {
        users += 1
        if users == 1 { restart() }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 {
            task?.cancel()
            task = nil
        }
    }

    func togglePause() {
        isPaused.toggle()
        restart()
    }

    private func restart() {
        task?.cancel()
        task = nil
        guard users > 0, !isPaused else {
            // Relevés arrêtés : le premier relevé à la reprise sert de nouvelle référence
            // (pas de moyenne sur toute la pause présentée comme valeur instantanée).
            previousTicks = []
            previousInterfaces = [:]
            previousDate = nil
            return
        }
        // Captures : données figées, aucune boucle.
        if isDemo, CommandLine.arguments.contains("--snapshot") { return }
        let seconds = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    private func sample() async {
        if isDemo {
            ResourceDemo.advanceLocal(self)
            return
        }
        if kinds.isEmpty {
            kinds = Dictionary(uniqueKeysWithValues: await LocalInterfaces.kinds().map { ($0.key, $0.value.label) })
            coreKinds = LocalResources.coreKinds()
        }
        let reading = await Task.detached(priority: .utility) {
            (LocalResources.cpuTicks(), LocalResources.memory(), LocalResources.interfaces(), LocalVolumes.list())
        }.value
        if reading.3 != volumes { volumes = reading.3 }
        let now = Date()
        let seconds = previousDate.map { now.timeIntervalSince($0) } ?? 0
        var values: [String: Double] = [:]
        var titles: [String: String] = [:]
        if let load = CPUMath.load(previous: previousTicks, current: reading.0) {
            cpu = load
            values["cpu"] = load.total
        }
        previousTicks = reading.0
        if let memory = reading.1 {
            self.memory = memory
            values["mem"] = memory.usedPercent
            if let pressure = memory.pressurePercent { values["pression"] = pressure }
        }
        var loads: [LocalInterfaceLoad] = []
        for item in reading.2 where item.isRelevant {
            let kind = kinds[item.name] ?? (item.name.hasPrefix("utun") ? "VPN" : item.name.hasPrefix("bridge") ? "Pont" : "Autre")
            var rate: TrafficRate?
            if let old = previousInterfaces[item.name], seconds > 0 {
                rate = ResourceMath.rate(from: old, to: item.counters, seconds: seconds)
                values["\(item.name).in"] = rate?.inBitsPerSecond
                values["\(item.name).out"] = rate?.outBitsPerSecond
                titles["\(item.name).in"] = "\(item.name) entrée (b/s)"
                titles["\(item.name).out"] = "\(item.name) sortie (b/s)"
            }
            loads.append(LocalInterfaceLoad(name: item.name, kind: kind, counters: item.counters, rate: rate))
        }
        previousInterfaces = Dictionary(reading.2.map { ($0.name, $0.counters) }, uniquingKeysWith: { a, _ in a })
        previousDate = now
        interfaces = Self.ordered(loads)
        record(ResourceSample(date: now, values: values), titles: titles)
    }

    /// Wi-Fi et Ethernet d'abord (en0, en1…), puis les ponts et les tunnels.
    static func ordered(_ loads: [LocalInterfaceLoad]) -> [LocalInterfaceLoad] {
        loads.sorted { a, b in
            func rank(_ l: LocalInterfaceLoad) -> Int { l.name.hasPrefix("en") ? 0 : l.name.hasPrefix("bridge") ? 1 : 2 }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Données (aussi pour la démonstration)

    func record(_ sample: ResourceSample, titles: [String: String] = [:]) {
        if timeline.columns.isEmpty {
            timeline.declare([ResourceColumn(id: "cpu", title: "Processeur (%)"),
                              ResourceColumn(id: "mem", title: "Mémoire utilisée (%)"),
                              ResourceColumn(id: "pression", title: "Pression mémoire (%)")])
        }
        timeline.window = max(300, interval * 60)
        timeline.append(sample, titles: titles)
        lastSample = sample.date
    }

    func set(cpu: CPULoad?, memory: MemoryStats?, interfaces: [LocalInterfaceLoad], coreKinds: (Int, Int)?,
             volumes: [LocalVolume]? = nil) {
        if let volumes { self.volumes = volumes }
        self.cpu = cpu
        self.memory = memory
        self.interfaces = interfaces
        self.coreKinds = coreKinds.map { (performance: $0.0, efficiency: $0.1) }
    }

    /// Interface principale : la plus chargée, sinon la première.
    var mainInterface: LocalInterfaceLoad? {
        interfaces.max { ($0.rate?.peakBitsPerSecond ?? -1) < ($1.rate?.peakBitsPerSecond ?? -1) } ?? interfaces.first
    }

    /// Débit total de toutes les interfaces (hors tunnels, déjà comptés dans l'interface physique).
    var totalRate: (inBps: Double, outBps: Double)? {
        let physical = interfaces.filter { !$0.name.hasPrefix("utun") }.compactMap(\.rate)
        guard !physical.isEmpty else { return nil }
        return (physical.compactMap(\.inBitsPerSecond).reduce(0, +), physical.compactMap(\.outBitsPerSecond).reduce(0, +))
    }

    func exportCSV() {
        ResourceCSVExport.save(timeline.csv(), suggestedName: "ressources-ce-mac") { self.show($0) }
    }

    private func show(_ toast: ResourceToast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

// MARK: - Agent SNMP

/// Ressources d'un appareil par SNMP v2c : processeur, mémoire, trafic par port.
@MainActor
final class SNMPResourceMonitor: ObservableObject {
    let host: String
    @Published private(set) var processor: SNMPProcessorReading?
    @Published private(set) var memory: SNMPMemoryReading?
    /// Débits de chaque port entre les deux derniers relevés.
    @Published private(set) var loads: [PortLoad] = []
    /// Compteurs du dernier relevé (avant le premier débit).
    @Published private(set) var ports: [SNMPPortCounters] = []
    @Published private(set) var timeline = ResourceTimeline(window: 300)
    @Published private(set) var error: String?
    @Published private(set) var isPolling = false
    @Published private(set) var isPaused = false
    @Published private(set) var lastPoll: Date?
    /// Vrai une fois qu'un relevé a été demandé (automatiquement ou par « Interroger »).
    @Published private(set) var started = false
    @Published var interval: Double {
        didSet {
            guard interval != oldValue else { return }
            if !isDemo { UserDefaults.standard.set(interval, forKey: Self.intervalKey) }
            restart()
        }
    }
    @Published private(set) var toast: ResourceToast?

    let isDemo: Bool
    private var users = 0
    private var task: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var previous: (date: Date, ports: [SNMPPortCounters])?
    private static let intervalKey = "NetScope.ressources.intervalle.snmp"

    init(host: String, demo: Bool = Launcher.isDemo) {
        self.host = host
        isDemo = demo
        let saved = demo ? 0 : UserDefaults.standard.double(forKey: Self.intervalKey)
        interval = ResourceInterval.snmp.contains(saved) ? saved : 10
        if demo { started = ResourceDemo.fillSNMP(self) }
    }

    /// Une vue regarde ; `autoStart` : interroger sans attendre un clic (agent SNMP connu).
    func retain(autoStart: Bool) {
        users += 1
        let wasStarted = started
        if autoStart { started = true }
        // Aussi quand une vue précédente regardait sans lancer les relevés (autoStart faux).
        if users == 1 || (!wasStarted && started) { restart() }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 {
            task?.cancel()
            task = nil
            isPolling = false
        }
    }

    /// « Interroger » : premier relevé demandé par l'utilisateur.
    func start() {
        started = true
        isPaused = false
        restart()
    }

    func togglePause() {
        isPaused.toggle()
        restart()
    }

    private func restart() {
        task?.cancel()
        task = nil
        guard users > 0, started, !isPaused else {
            // Relevés arrêtés : le premier relevé à la reprise sert de nouvelle référence.
            if !isDemo { previous = nil }
            return
        }
        if isDemo, CommandLine.arguments.contains("--snapshot") { return }
        let seconds = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    private func poll() async {
        if isDemo {
            ResourceDemo.advanceSNMP(self)
            return
        }
        guard let address = IPv4Address(host) else {
            error = "Adresse IPv4 invalide."
            return
        }
        await SwitchStore.shared.loadVault()
        let community = SwitchStore.shared.community(for: host)
        guard !community.isEmpty else {
            error = "Saisissez la communauté SNMP (lecture seule) dans Réglages › Identifiants ou dans Switchs et ports."
            return
        }
        isPolling = true
        defer { isPolling = false }
        let poller = SNMPResourcePoller(target: SNMPTarget(host: address, community: community, timeout: 2, retries: 1))
        do {
            // Ports d'abord : sans réponse, inutile d'insister sur le reste.
            let ports = try await poller.ports()
            let now = Date()
            let processor = try await poller.processor()
            let memory = try await poller.memory()
            apply(ports: ports, processor: processor, memory: memory, at: now)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Nouveau relevé : débits par rapport au précédent, historique.
    func apply(ports: [SNMPPortCounters], processor: SNMPProcessorReading?, memory: SNMPMemoryReading?, at date: Date) {
        var values: [String: Double] = [:]
        var titles: [String: String] = [:]
        if let previous, date > previous.date {
            let seconds = date.timeIntervalSince(previous.date)
            loads = TopPorts.loads(previous: previous.ports, current: ports, seconds: seconds)
            for load in loads where load.isUp {
                values["if\(load.index).in"] = load.rate.inBitsPerSecond
                values["if\(load.index).out"] = load.rate.outBitsPerSecond
                titles["if\(load.index).in"] = "\(load.name) entrée (b/s)"
                titles["if\(load.index).out"] = "\(load.name) sortie (b/s)"
            }
        }
        self.ports = ports
        previous = (date, ports)
        if let processor {
            self.processor = processor
            values["cpu"] = processor.load.total
        }
        if let memory {
            self.memory = memory
            values["mem"] = memory.memory.usedPercent
        }
        if timeline.columns.isEmpty {
            timeline.declare([ResourceColumn(id: "cpu", title: "Processeur (%)"), ResourceColumn(id: "mem", title: "Mémoire utilisée (%)")])
        }
        timeline.window = max(300, interval * 30)
        timeline.append(ResourceSample(date: date, values: values), titles: titles)
        lastPoll = date
    }

    /// Démonstration : état complet d'un coup.
    func setDemo(processor: SNMPProcessorReading?, memory: SNMPMemoryReading?, ports: [SNMPPortCounters], loads: [PortLoad],
                 timeline: ResourceTimeline, lastPoll: Date) {
        self.processor = processor
        self.memory = memory
        self.ports = ports
        self.loads = loads
        self.timeline = timeline
        self.lastPoll = lastPoll
        previous = (lastPoll, ports)
    }

    func load(of index: Int) -> PortLoad? {
        loads.first { $0.index == index }
    }

    func topPorts(limit: Int = 5) -> [PortLoad] {
        TopPorts.rank(loads, limit: limit)
    }

    /// Export de l'historique : tout, ou les séries d'un port.
    func exportCSV(port: Int? = nil, name: String) {
        let keys = port.map { ["if\($0).in", "if\($0).out"] }
        ResourceCSVExport.save(timeline.csv(keys: keys), suggestedName: name) { self.show($0) }
    }

    private func show(_ toast: ResourceToast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

/// Un relevé SNMP par appareil, partagé entre les écrans (fiche Appareil, Switchs et ports).
@MainActor
enum ResourceMonitors {
    private static var monitors: [String: SNMPResourceMonitor] = [:]

    static func snmp(_ host: String) -> SNMPResourceMonitor {
        if let monitor = monitors[host] { return monitor }
        let monitor = SNMPResourceMonitor(host: host)
        monitors[host] = monitor
        return monitor
    }
}

/// Enregistrement d'un historique en CSV (fenêtre d'enregistrement, BOM UTF-8 pour Excel).
@MainActor
enum ResourceCSVExport {
    static func save(_ csv: String, suggestedName: String, report: (ResourceToast) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Exporter l’historique des ressources"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "\(suggestedName)-\(formatter.string(from: Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8)).write(to: url, options: .atomic)
            report(ResourceToast(text: "Historique exporté\u{00A0}: \(url.lastPathComponent)", isError: false))
        } catch {
            report(ResourceToast(text: "Export impossible\u{00A0}: \(error.localizedDescription)", isError: true))
        }
    }
}
