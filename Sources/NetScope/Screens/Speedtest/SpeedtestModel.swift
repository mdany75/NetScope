import AppKit
import Foundation
import NetScopeCore
import SwiftUI

/// Onglets de l'écran Speedtest.
enum SpeedTab: String, CaseIterable, Identifiable {
    case internet, lan, historique

    var id: String { rawValue }

    var label: String {
        switch self {
        case .internet: return "Internet"
        case .lan: return "Réseau local (iperf3)"
        case .historique: return "Historique"
        }
    }

    var hint: String {
        switch self {
        case .internet: return "Débit du lien Internet, mesuré avec les serveurs de Cloudflare"
        case .lan: return "Débit entre ce Mac et un serveur iperf3 du réseau"
        case .historique: return "Résultats conservés 90 jours sur ce Mac"
        }
    }
}

/// État d'un test Internet.
enum SpeedRunState: Equatable {
    case idle
    case running(SpeedPhase)
    case done
    case stopped
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Point d'une courbe temps réel (secondes, Mb/s).
struct SpeedPoint: Identifiable, Hashable {
    var id: Double { time }
    let time: Double
    let mbps: Double
}

/// État de l'écran Speedtest, conservé quand on change d'écran (instance unique).
@MainActor
final class SpeedtestModel: ObservableObject {
    static let shared = SpeedtestModel()

    // MARK: Internet

    @Published var tab: SpeedTab = .internet
    @Published var streams = 4
    @Published private(set) var runState: SpeedRunState = .idle
    /// Valeur affichée par la jauge (Mb/s, ou ms pendant la latence).
    @Published private(set) var gaugeValue: Double = 0
    @Published private(set) var fraction: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var downSeries: [SpeedPoint] = []
    @Published private(set) var upSeries: [SpeedPoint] = []
    @Published private(set) var idleLatency: Double?
    @Published private(set) var jitter: Double?
    @Published private(set) var downMbps: Double?
    @Published private(set) var upMbps: Double?
    @Published private(set) var summary: SpeedTestSummary?
    @Published private(set) var server: SpeedServerInfo?
    @Published var planDownText = "" { didSet { savePlan() } }
    @Published var planUpText = "" { didSet { savePlan() } }

    // MARK: Historique

    @Published private(set) var history: [SpeedTestRecord] = []
    @Published var historyFilter: SpeedTestKind?
    @Published private(set) var freshRecordID: UUID?
    @Published var toast: String?

    // MARK: Réseau local (iperf3)

    @Published var lanHost = ""
    @Published var lanPort = "5201"
    @Published var lanDuration = 10
    @Published var lanStreams = 4
    @Published var lanTransport: IperfOptions.Transport = .tcp
    @Published var lanDirection: IperfOptions.Direction = .normal
    @Published private(set) var lanRunning = false
    @Published private(set) var lanStartedAt: Date?
    @Published private(set) var lanResult: IperfResult?
    @Published private(set) var lanError: String?
    /// Chemin d'iperf3, nil s'il n'est pas installé.
    @Published private(set) var iperfPath: URL?

    private var internetTask: Task<Void, Never>?
    private var lanTask: Task<Void, Never>?
    private let store: SpeedHistoryStore?
    private var loading = true

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let demo = arguments.contains("--demo")
        // Captures et démonstration : rien n'est lu ni écrit sur le disque.
        store = (demo || arguments.contains("--snapshot")) ? nil : SpeedHistoryStore.standard
        iperfPath = IperfLocator.find()
        if demo {
            SpeedtestDemo.apply(to: self)
        } else if let store {
            let content = store.load()
            history = content.records
            planDownText = content.planDownMbps.map { SpeedFormat.integer($0) } ?? ""
            planUpText = content.planUpMbps.map { SpeedFormat.integer($0) } ?? ""
        }
        if let raw = ProcessInfo.processInfo.environment["NETSCOPE_SPEED_TAB"], let tab = SpeedTab(rawValue: raw) {
            self.tab = tab
        }
        loading = false
    }

    var planDown: Double? { SpeedFormat.parse(planDownText) }
    var planUp: Double? { SpeedFormat.parse(planUpText) }

    /// Graduation de la jauge, selon le forfait et le plus haut débit vu.
    var gaugeScale: Double {
        let peak = max(downSeries.map(\.mbps).max() ?? 0, upSeries.map(\.mbps).max() ?? 0, downMbps ?? 0, planDown ?? 0)
        return SpeedMath.gaugeScale(for: peak)
    }

    var currentPhase: SpeedPhase? {
        if case .running(let phase) = runState { return phase }
        return nil
    }

    // MARK: Test Internet

    func startInternet(interface: LocalInterface?) {
        internetTask?.cancel()
        resetResults()
        runState = .running(.latency)
        toast = nil
        let config = SpeedTestConfig(streams: streams)
        let tester = SpeedTester(config: config)
        internetTask = Task { [weak self] in
            for await event in tester.run() {
                guard let self, !Task.isCancelled else { return }
                self.handle(event, config: config, interface: interface)
            }
        }
    }

    func stopInternet() {
        guard runState.isRunning else { return }
        internetTask?.cancel()
        internetTask = nil
        runState = .stopped
        gaugeValue = 0
    }

    private func resetResults() {
        gaugeValue = 0
        fraction = 0
        elapsed = 0
        downSeries = []
        upSeries = []
        idleLatency = nil
        jitter = nil
        downMbps = nil
        upMbps = nil
        summary = nil
        freshRecordID = nil
    }

    private func handle(_ event: SpeedEvent, config: SpeedTestConfig, interface: LocalInterface?) {
        switch event {
        case .update(let update):
            runState = .running(update.phase)
            fraction = update.fraction
            switch update.phase {
            case .latency:
                elapsed = update.elapsed
                if let latency = update.latencyMs { gaugeValue = latency }
            case .download:
                elapsed = latencyDuration + update.elapsed
                gaugeValue = update.mbps ?? 0
                downSeries.append(SpeedPoint(time: update.elapsed, mbps: update.mbps ?? 0))
            case .upload:
                elapsed = latencyDuration + config.downloadDuration + update.elapsed
                gaugeValue = update.mbps ?? 0
                upSeries.append(SpeedPoint(time: update.elapsed, mbps: update.mbps ?? 0))
            }
        case .server(let info):
            server = info
        case .latencyMeasured(let idle, let jitter):
            latencyDuration = elapsed
            idleLatency = idle
            self.jitter = jitter
            gaugeValue = 0
        case .downloadMeasured(let value):
            downMbps = value
            gaugeValue = 0
        case .uploadMeasured(let value):
            upMbps = value
        case .finished(let result):
            summary = result
            downMbps = result.downMbps
            upMbps = result.upMbps
            gaugeValue = result.downMbps
            fraction = 1
            runState = .done
            let record = SpeedTestRecord(
                kind: .internet, server: result.server?.label ?? "Cloudflare",
                interfaceName: interface?.name ?? "—", interfaceKind: interface?.kind.label ?? "",
                downMbps: result.downMbps, upMbps: result.upMbps, latencyMs: result.idleLatencyMs,
                loadedLatencyMs: result.loadedLatencyMs, jitterMs: result.jitterMs, streams: result.streams)
            addToHistory(record)
            toast = "Test terminé et ajouté à l’historique"
        case .failed(let message):
            runState = .failed(message)
            gaugeValue = 0
        }
    }

    private var latencyDuration: Double = 0

    // MARK: Test iperf3

    var lanOptions: IperfOptions {
        IperfOptions(host: lanHost.trimmingCharacters(in: .whitespaces), port: Int(lanPort) ?? 5201,
                     duration: lanDuration, streams: lanStreams, transport: lanTransport, direction: lanDirection)
    }

    func startLan(interface: LocalInterface?) {
        guard !lanRunning else { return }
        iperfPath = IperfLocator.find()
        let options = lanOptions
        lanError = nil
        guard let path = iperfPath else {
            lanError = IperfLocator.missingMessage
            return
        }
        do {
            _ = try options.arguments()
        } catch {
            lanError = error.localizedDescription
            return
        }
        lanRunning = true
        lanStartedAt = Date()
        lanResult = nil
        lanTask = Task { [weak self] in
            do {
                let result = try await IperfRunner.run(options, executable: path)
                guard let self else { return }
                self.lanResult = result
                self.lanRunning = false
                let record = SpeedTestRecord(
                    kind: .lan, server: "\(options.host):\(options.port)",
                    interfaceName: interface?.name ?? "—", interfaceKind: interface?.kind.label ?? "",
                    downMbps: result.megabitsPerSecond, upMbps: result.reverseMegabitsPerSecond,
                    jitterMs: result.jitterMs, streams: options.streams)
                self.addToHistory(record)
                self.toast = "Test iperf3 terminé et ajouté à l’historique"
            } catch {
                guard let self else { return }
                self.lanRunning = false
                if !Task.isCancelled { self.lanError = error.localizedDescription }
            }
        }
    }

    func stopLan() {
        lanTask?.cancel()
        lanTask = nil
        lanRunning = false
    }

    // MARK: Historique

    private func addToHistory(_ record: SpeedTestRecord) {
        history = SpeedHistoryStore.pruned([record] + history)
        freshRecordID = record.id
        persist()
    }

    var filteredHistory: [SpeedTestRecord] {
        guard let historyFilter else { return history }
        return history.filter { $0.kind == historyFilter }
    }

    func setHistory(_ records: [SpeedTestRecord]) {
        history = SpeedHistoryStore.pruned(records)
    }

    /// Enregistre l'historique au format CSV (fenêtre d'enregistrement).
    func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Exporter l’historique"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "speedtest-historique-\(formatter.string(from: Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // BOM UTF-8 : Excel reconnaît les accents.
            let data = Data([0xEF, 0xBB, 0xBF]) + Data(SpeedHistoryStore.csv(filteredHistory).utf8)
            try data.write(to: url, options: .atomic)
            toast = "Historique exporté : \(url.lastPathComponent)"
        } catch {
            toast = "Export impossible : \(error.localizedDescription)"
        }
    }

    private func savePlan() {
        guard !loading else { return }
        persist()
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(SpeedHistoryStore.Content(records: history, planDownMbps: planDown, planUpMbps: planUp))
        } catch {
            NSLog("NetScope : enregistrement de l’historique Speedtest impossible : %@", error.localizedDescription)
        }
    }

    // MARK: Démonstration

    /// Remplit l'écran avec les valeurs du croquis (captures --demo).
    func loadDemo(result: SpeedTestSummary, down: [SpeedPoint], up: [SpeedPoint], history: [SpeedTestRecord],
                  lan: IperfResult?, lanHost: String) {
        summary = result
        server = result.server
        idleLatency = result.idleLatencyMs
        jitter = result.jitterMs
        downMbps = result.downMbps
        upMbps = result.upMbps
        gaugeValue = result.downMbps
        fraction = 1
        elapsed = 21.5
        downSeries = down
        upSeries = up
        runState = .done
        streams = result.streams
        self.history = history
        lanResult = lan
        self.lanHost = lanHost
        planDownText = "1000"
        planUpText = "500"
    }
}

/// Mise en forme des nombres à la française (virgule décimale, pas de séparateur de milliers).
enum SpeedFormat {
    static func number(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    static func integer(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// Débit : entier au-delà de 100 Mb/s, une décimale en dessous.
    static func rate(_ value: Double) -> String {
        value >= 100 ? integer(value) : number(value, digits: 1)
    }

    /// Latence : une décimale sous 10 ms, entier au-delà.
    static func latency(_ value: Double) -> String {
        value < 10 ? number(value, digits: 1) : integer(value)
    }

    static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    static func bytes(_ value: Int64) -> String {
        let megabytes = Double(value) / 1_000_000
        return megabytes >= 1000 ? number(megabytes / 1000, digits: 2) + " Go" : number(megabytes, digits: 1) + " Mo"
    }

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMM yyyy · HH:mm"
        return formatter
    }()

    static let shortDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}
