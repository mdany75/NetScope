import Foundation
import NetScopeCore

/// Test MTU de la Boîte à outils (notes 78 et 79) : recherche réelle du MTU du chemin par
/// dichotomie avec le bit DF, diagnostic et historique des mesures. L'historique est enregistré
/// dans ~/Library/Application Support/NetScope/mtu.json (en mémoire seulement en démonstration).
@MainActor
final class PathMTUModel: ObservableObject {
    static let shared = PathMTUModel()

    @Published var target = ""
    /// Chercher au-delà de 1500 octets (trames jumbo, jusqu'à 9000).
    @Published var jumbo = false
    @Published private(set) var isRunning = false
    /// Étapes de la mesure en cours ou de la dernière mesure.
    @Published private(set) var steps: [PathMTUStep] = []
    @Published private(set) var result: PathMTUResult?
    /// Cible et adresse de la dernière mesure.
    @Published private(set) var measuredTarget = ""
    @Published private(set) var measuredAddress: IPv4Address?
    @Published private(set) var method: PathMTUMeasurement.Method = .socket
    /// Interface de sortie et son MTU, lus sans requête réseau.
    @Published private(set) var interfaceName: String?
    @Published private(set) var interfaceMTU: Int?
    @Published private(set) var history: [PathMTUMeasurement] = []
    /// Mesure précédente vers la même adresse (pour signaler un changement).
    @Published private(set) var previous: PathMTUMeasurement?
    @Published var error: String?
    /// Information neutre : mesure arrêtée par l'utilisateur, export réussi, mesures retirées.
    @Published var notice: String?
    /// Mesures retirées en dernier (bouton « Annuler » du bandeau).
    @Published private(set) var removed: [PathMTUMeasurement] = []

    let isDemo: Bool
    private let isEphemeral: Bool
    private var task: Task<Void, Never>?
    private var generation = 0
    private let url: URL

    private init() {
        let arguments = CommandLine.arguments
        isDemo = arguments.contains("--demo")
        isEphemeral = isDemo || arguments.contains("--snapshot")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("mtu.json")
        if isEphemeral {
            if isDemo { loadDemo() }
        } else if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            history = (try? decoder.decode([PathMTUMeasurement].self, from: data)) ?? []
        }
    }

    /// Commande équivalente (en-tête de l'outil).
    var command: String {
        let size = (result?.mtu ?? (jumbo ? PathMTUOptions.jumboSize : 1500)) - PathMTUSearch.overhead
        let host = target.trimmingCharacters(in: .whitespaces)
        return "ping -D -s \(size) \(host.isEmpty ? "<cible>" : host)"
    }

    /// Étape en cours : bornes connues pendant la recherche.
    var progressText: String {
        guard let last = steps.last else { return "Vérification que la cible répond (écho de 84\u{00A0}octets)…" }
        let high = last.high.map { "\($0 - 1)" } ?? "\(jumbo ? PathMTUOptions.jumboSize : 1500)"
        return "Étape \(steps.count + 1)\u{00A0}: le MTU est entre \(last.low) et \(high)\u{00A0}octets…"
    }

    // MARK: Mesure

    func run(store: ToolStore, gateway: IPv4Address?, interface: String?) {
        let input = target.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else {
            error = "Saisir une adresse IP ou un nom d’hôte."
            return
        }
        guard !input.contains(where: { $0 == "/" || $0 == " " }) else {
            error = "Une seule cible\u{00A0}: adresse IP ou nom d’hôte."
            return
        }
        cancel()
        generation += 1
        let run = generation
        error = nil
        notice = nil
        removed = []
        steps = []
        result = nil
        previous = nil
        measuredTarget = input
        measuredAddress = nil
        isRunning = true
        interfaceName = interface
        interfaceMTU = isDemo ? nil : interface.flatMap { PathMTULocal.interfaceMTU($0) }
        let wantsJumbo = jumbo
        store.record(command: "ping -D -s \((wantsJumbo ? PathMTUOptions.jumboSize : 1500) - PathMTUSearch.overhead) \(input)  # recherche du MTU")
        task = Task { [weak self] in
            guard let self else { return }
            let address: IPv4Address
            if let literal = IPv4Address(input) {
                address = literal
            } else if self.isDemo {
                address = IPv4Address(142, 112, 48, 20)
            } else {
                do {
                    address = try await PingResolver.resolveAsync(input)
                } catch {
                    guard run == self.generation else { return }
                    self.error = error.localizedDescription
                    self.isRunning = false
                    return
                }
            }
            guard run == self.generation else { return }
            self.measuredAddress = address
            if self.isDemo { self.interfaceMTU = PathMTUDemo.scenario(for: input, address: address).interfaceMTU }
            let progress: @Sendable (PathMTUStep) -> Void = { step in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let model = PathMTUModel.shared
                        if run == model.generation { model.steps.append(step) }
                    }
                }
            }
            let outcome: (PathMTUResult, PathMTUMeasurement.Method)
            if self.isDemo {
                outcome = (await Self.demoSearch(input: input, address: address, jumbo: wantsJumbo, progress: progress), .socket)
            } else {
                outcome = await Self.realSearch(address: address, jumbo: wantsJumbo, interfaceMTU: self.interfaceMTU, progress: progress)
            }
            // Les dernières étapes arrivent par la file principale : les laisser passer avant le résultat.
            await Task.yield()
            guard run == self.generation else { return }
            self.finish(outcome.0, method: outcome.1, input: input, address: address, store: store)
        }
    }

    func cancel() {
        guard isRunning else { return }
        generation += 1
        task?.cancel()
        task = nil
        isRunning = false
        // Arrêt voulu : une information, pas une erreur.
        if result == nil, !steps.isEmpty { notice = "Mesure arrêtée." }
    }

    /// Sonde réelle par la socket ICMP de NetScope ; /sbin/ping -D en dernier recours.
    private nonisolated static func realSearch(address: IPv4Address, jumbo: Bool, interfaceMTU: Int?,
                                               progress: @escaping @Sendable (PathMTUStep) -> Void) async -> (PathMTUResult, PathMTUMeasurement.Method) {
        let options = PathMTUOptions(maxSize: jumbo ? PathMTUOptions.jumboSize : 1500, attempts: 2, timeout: 1.5, interfaceMTU: interfaceMTU)
        if let prober = try? PathMTUProber(destination: address, timeout: options.timeout) {
            let result = await PathMTUSearch.run(options: options, probe: { size in await prober.probeAsync(size: size) }, progress: progress)
            return (result, .socket)
        }
        let result = await PathMTUSearch.run(options: options, probe: { size in
            await PathMTUPingCommand.probe(size: size, destination: address, timeout: options.timeout)
        }, progress: progress)
        return (result, .pingCommand)
    }

    /// Démonstration : chemin simulé, une étape toutes les 0,18 s (aucun paquet envoyé).
    private nonisolated static func demoSearch(input: String, address: IPv4Address, jumbo: Bool,
                                               progress: @escaping @Sendable (PathMTUStep) -> Void) async -> PathMTUResult {
        let base = PathMTUDemo.scenario(for: input, address: address)
        let scenario = PathMTUDemo.Scenario(target: input, address: address, mtu: base.mtu, interfaceMTU: base.interfaceMTU,
                                            sendsICMP: base.sendsICMP, router: base.router, baseRTT: base.baseRTT, jumbo: jumbo)
        return await PathMTUSearch.run(options: PathMTUDemo.options(scenario), probe: { size in
            try? await Task.sleep(nanoseconds: 180_000_000)
            return PathMTUDemo.probe(scenario, size: size)
        }, progress: progress)
    }

    private func finish(_ result: PathMTUResult, method: PathMTUMeasurement.Method, input: String, address: IPv4Address, store: ToolStore) {
        self.result = result
        steps = result.steps
        self.method = method
        isRunning = false
        let measurement = PathMTUMeasurement(result: result, target: input, address: address, method: method)
        previous = PathMTUHistory.previous(of: measurement, in: history)
        history = PathMTUHistory.inserting(measurement, into: history)
        save()
        let status: ToolRecent.Status
        let summary: String
        if let mtu = measurement.mtu, let diagnosis = measurement.diagnosis {
            summary = "\(mtu)\u{00A0}octets · \(diagnosis.title)" + (result.isBlackHole ? " · trou noir ICMP" : "")
            status = diagnosis.severity == .normal && !result.isBlackHole ? .ok : .warning
        } else {
            summary = measurement.note ?? "MTU non mesuré"
            status = .failure
        }
        store.record(ToolRecent(tool: .mtu, target: input, summary: summary, status: status))
    }

    // MARK: Historique

    func clearHistory() {
        history = []
        save()
    }

    func remove(_ ids: Set<UUID>) {
        let gone = history.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        history.removeAll { ids.contains($0.id) }
        removed = gone
        notice = gone.count > 1 ? "\(gone.count) mesures retirées de l’historique." : "Mesure retirée de l’historique."
        save()
    }

    /// Remet les mesures retirées en dernier.
    func undoRemove() {
        guard !removed.isEmpty else { return }
        history = Array((history + removed).sorted { $0.date > $1.date }.prefix(PathMTUHistory.capacity))
        removed = []
        notice = nil
        save()
    }

    private func save() {
        guard !isEphemeral else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(history).write(to: url, options: .atomic)
        } catch {
            AppLog.shared.error("Test MTU", "Enregistrement impossible de \(url.path)\u{00A0}: \(error.localizedDescription)")
        }
    }

    // MARK: Démonstration

    private func loadDemo() {
        let scenario = PathMTUDemo.initial
        target = scenario.target
        jumbo = scenario.jumbo
        measuredTarget = scenario.target
        measuredAddress = scenario.address
        interfaceName = "en0"
        interfaceMTU = scenario.interfaceMTU
        history = PathMTUDemo.history()
        Task {
            let result = await PathMTUSearch.run(options: PathMTUDemo.options(scenario)) { size in
                PathMTUDemo.probe(scenario, size: size)
            }
            self.result = result
            self.steps = result.steps
            // Mesure précédente vers la même cible (l'historique de démonstration commence par celle-ci).
            if let current = self.history.first(where: { $0.address == scenario.address.description }) {
                self.previous = PathMTUHistory.previous(of: current, in: self.history)
            }
        }
    }
}
