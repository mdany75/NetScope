import Foundation
import NetScopeCore

/// Onglet de la source « Flux » de l'écran Trafic.
enum FlowTab: String, CaseIterable, Identifiable {
    case sources, destinations, applications, interfaces, conversations, exporters

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sources: return "Sources"
        case .destinations: return "Destinations"
        case .applications: return "Applications"
        case .interfaces: return "Interfaces"
        case .conversations: return "Conversations"
        case .exporters: return "Exportateurs"
        }
    }

    var symbol: String {
        switch self {
        case .sources: return "desktopcomputer"
        case .destinations: return "globe"
        case .applications: return "app.badge"
        case .interfaces: return "point.3.connected.trianglepath.dotted"
        case .conversations: return "arrow.left.arrow.right"
        case .exporters: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Vue de TrafficOverview qui alimente l'onglet (nil : conversations, exportateurs).
    var view: TrafficView? {
        switch self {
        case .sources: return .sources
        case .destinations: return .destinations
        case .applications: return .applications
        case .interfaces: return .interfaces
        case .conversations, .exporters: return nil
        }
    }
}

/// Collecteur de flux de l'écran Trafic (note 75) : NetFlow v5/v9, IPFIX et sFlow v5 reçus sur ce
/// Mac. L'écoute ne démarre que sur clic (« Démarrer l'écoute ») et s'arrête avec « Arrêter » ou à
/// la fermeture de l'app. Les flux restent en mémoire (24 h au plus, mémoire bornée) ; seuls les
/// ports, la période et les réglages des exportateurs (nom, lien Internet) sont enregistrés dans les
/// préférences (rien de secret).
///
/// Démonstration et captures : rien n'est écouté ; FlowDemo fabrique des datagrammes réalistes,
/// décodés par les vrais décodeurs.
@MainActor
final class FlowStore: ObservableObject {
    static let shared = FlowStore()

    private static let portsKey = "NetScope.flux.ports"
    private static let settingsKey = "NetScope.flux.exportateurs"
    private static let periodKey = "NetScope.flux.periode"

    @Published var ports: FlowCollectorPorts {
        didSet { if !isDemo, ports != oldValue, let data = try? JSONEncoder().encode(ports) { UserDefaults.standard.set(data, forKey: Self.portsKey) } }
    }
    /// Réglages par exportateur (clé : adresse).
    @Published private(set) var settings: [String: FlowExporterSettings]
    @Published var period: TrafficPeriod {
        didSet {
            guard period != oldValue else { return }
            if !isDemo { UserDefaults.standard.set(period.rawValue, forKey: Self.periodKey) }
            refresh()
        }
    }
    @Published var tab: FlowTab = .sources
    /// Exportateur montré (nil : tous, chacun dans ses lignes).
    @Published var exporterFilter: IPv4Address? {
        didSet { if exporterFilter != oldValue { recomputeOverview() } }
    }
    @Published private(set) var isListening = false
    /// Ports qui n'ont pas pu s'ouvrir au dernier démarrage.
    @Published private(set) var startErrors: [String] = []
    @Published private(set) var stopReason: String?
    @Published private(set) var status = FlowCollectorStatus()
    @Published private(set) var summaries: [FlowSummary] = []
    @Published private(set) var overview = TrafficOverview()
    @Published private(set) var listeningSince: Date?
    @Published private(set) var firewall: TFTPFirewallStatus?

    let isDemo: Bool
    private let collector = FlowCollector()
    private var loop: Task<Void, Never>?
    private var computing = false

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        let defaults = UserDefaults.standard
        if demo {
            ports = .standard
            settings = FlowDemo.settings
            period = TrafficDemo.requestedPeriod.flatMap { FlowTrafficBridge.periods.contains($0) ? $0 : nil } ?? .realtime
            tab = FlowDemo.requestedTab ?? .sources
            exporterFilter = FlowDemo.requestedExporter
            let now = Date()
            FlowDemo.feed(collector, now: now)
            isListening = true
            listeningSince = now.addingTimeInterval(-26 * 3600)
            recomputeNow(now: now)
        } else {
            ports = defaults.data(forKey: Self.portsKey).flatMap { try? JSONDecoder().decode(FlowCollectorPorts.self, from: $0) } ?? .standard
            settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode([String: FlowExporterSettings].self, from: $0) } ?? [:]
            period = defaults.string(forKey: Self.periodKey).flatMap(TrafficPeriod.init(rawValue:))
                .flatMap { FlowTrafficBridge.periods.contains($0) ? $0 : nil } ?? .realtime
        }
    }

    // MARK: Écoute

    /// Ouvre les ports choisis (sur clic seulement).
    func start() {
        guard !isListening else { return }
        stopReason = nil
        startErrors = []
        if isDemo {
            isListening = true
            listeningSince = Date()
            return
        }
        let wanted = ports.active
        guard !wanted.isEmpty else {
            startErrors = ["Cochez au moins un format à recevoir."]
            return
        }
        do {
            startErrors = try collector.start(ports: wanted) { [weak self] reason in
                guard let reason else { return }
                Task { @MainActor in self?.stopped(reason) }
            }
            isListening = true
            listeningSince = Date()
            startLoop()
        } catch {
            startErrors = [(error as? FlowDecodeError)?.message ?? error.localizedDescription]
        }
        Task { firewall = await TFTPFirewallStatus.read(appPath: Bundle.main.bundlePath) }
    }

    func stop() {
        guard isListening else { return }
        if !isDemo { collector.stop() }
        isListening = false
        loop?.cancel()
        loop = nil
        stopReason = "Écoute arrêtée\u{00A0}: les flux déjà reçus restent affichés (24\u{00A0}h au plus)."
        refresh()
    }

    private func stopped(_ reason: String) {
        isListening = false
        loop?.cancel()
        loop = nil
        stopReason = reason
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Oublie tout ce qui a été reçu (flux, gabarits, compteurs).
    func clear() {
        if isDemo { return }
        collector.reset()
        refresh()
    }

    // MARK: Lecture

    /// Relit l'état et les synthèses du collecteur (hors du fil principal).
    func refresh() {
        if isDemo {
            recomputeNow(now: Date())
            return
        }
        guard !computing else { return }
        computing = true
        let collector = self.collector
        let window = FlowTrafficBridge.window(period)
        let overrides = wanOverrides
        Task.detached(priority: .utility) {
            let now = Date()
            let status = collector.status()
            let summaries = collector.summaries(window: window, now: now, wanOverrides: overrides)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.computing = false
                self.apply(status: status, summaries: summaries, now: now)
            }
        }
    }

    private func recomputeNow(now: Date) {
        let status = collector.status()
        let summaries = collector.summaries(window: FlowTrafficBridge.window(period), now: now, wanOverrides: wanOverrides)
        apply(status: status, summaries: summaries, now: now)
    }

    private func apply(status: FlowCollectorStatus, summaries: [FlowSummary], now: Date) {
        self.status = status
        self.summaries = summaries
        lastCompute = now
        recomputeOverview()
    }

    private var lastCompute = Date()

    /// Exportateurs montrés : celui choisi, sinon tous.
    var shownSummaries: [FlowSummary] {
        guard let filter = exporterFilter, summaries.contains(where: { $0.exporter == filter }) else { return summaries }
        return summaries.filter { $0.exporter == filter }
    }

    /// Lignes de l'écran : appareils nommés comme dans NetScope (Scanner, inventaire).
    private func recomputeOverview() {
        let raw = FlowTrafficBridge.overview(shownSummaries, settings: settingsByAddress, period: period, now: lastCompute)
        overview = TrafficStore.shared.named(raw)
    }

    private var wanOverrides: [IPv4Address: UInt32] {
        var map: [IPv4Address: UInt32] = [:]
        for (key, value) in settings { if let ip = IPv4Address(key), let wan = value.wanInterface { map[ip] = wan } }
        return map
    }

    private var settingsByAddress: [IPv4Address: FlowExporterSettings] {
        var map: [IPv4Address: FlowExporterSettings] = [:]
        for (key, value) in settings { if let ip = IPv4Address(key) { map[ip] = value } }
        return map
    }

    // MARK: Exportateurs

    func settings(for exporter: IPv4Address) -> FlowExporterSettings {
        settings[exporter.description] ?? FlowExporterSettings()
    }

    func name(of exporter: IPv4Address) -> String {
        settings(for: exporter).label(for: exporter)
    }

    func update(_ exporter: IPv4Address, _ value: FlowExporterSettings) {
        settings[exporter.description] = value
        if !isDemo, let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        if isDemo { recomputeNow(now: Date()) } else { refresh() }
    }

    func forget(_ exporter: IPv4Address) {
        if !isDemo { collector.forget(exporter: exporter) }
        settings[exporter.description] = nil
        if !isDemo, let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        refresh()
    }

    /// Synthèse d'un exportateur (interfaces vues, pour choisir le lien Internet).
    func summary(_ exporter: IPv4Address) -> FlowSummary? {
        summaries.first { $0.exporter == exporter }
    }

    // MARK: Textes

    /// « NetFlow 2055 · IPFIX 4739 · sFlow 6343 ».
    var portsLabel: String {
        ports.active.map { "\($0.label) \($0.port)" }.joined(separator: " · ")
    }

    /// « 3 exportateurs · 12 480 datagrammes · 2 rejetés ».
    var countsLabel: String {
        let exporters = status.exporters.count
        var text = "\(exporters) exportateur\(exporters > 1 ? "s" : "") · " + ToolFormat.integer(status.received)
            + " datagramme\(status.received > 1 ? "s" : "") reçu\(status.received > 1 ? "s" : "")"
        if status.rejected > 0 { text += " · \(ToolFormat.integer(status.rejected)) rejeté\(status.rejected > 1 ? "s" : "")" }
        return text
    }
}
