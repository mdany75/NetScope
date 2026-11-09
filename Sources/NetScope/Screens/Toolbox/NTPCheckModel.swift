import Foundation
import NetScopeCore

extension NTPVerdict {
    var tone: Tone {
        switch self {
        case .synchronized: return .success
        case .notableOffset, .kissOfDeath: return .warning
        case .largeOffset, .unsynchronized, .silent: return .critical
        }
    }

    fileprivate var recentStatus: ToolRecent.Status {
        switch self {
        case .synchronized: return .ok
        case .notableOffset, .kissOfDeath: return .warning
        case .largeOffset, .unsynchronized, .silent: return .failure
        }
    }
}

/// Test NTP de la Boîte à outils (note 115) : jusqu'à 8 serveurs à la fois, sur clic seulement.
@MainActor
final class NTPCheckModel: ObservableObject {
    static let shared = NTPCheckModel()

    @Published var servers = ""
    @Published var port = "\(NTPProbeOptions.defaultPort)"
    @Published private(set) var isRunning = false
    @Published private(set) var results: [NTPServerResult] = []
    @Published var selection: UUID?
    @Published var error: String?
    @Published var notice: String?

    let isDemo = CommandLine.arguments.contains("--demo")
    private var task: Task<Void, Never>?
    private var generation = 0

    private init() {
        if isDemo {
            servers = NTPDemo.servers
            results = NTPDemo.results()
            selection = results.first { $0.verdict == .notableOffset }?.id
        }
    }

    var portValue: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)) }

    var selected: NTPServerResult? { results.first { $0.id == selection } ?? results.first }

    var serverCount: Int { NTPProbe.parseServers(servers).servers.count }

    var command: String {
        let list = NTPProbe.parseServers(servers).servers
        let suffix = portValue.map { $0 == NTPProbeOptions.defaultPort ? "" : " # port UDP \($0)" } ?? ""
        return "sntp \(list.isEmpty ? "<serveur>" : list.joined(separator: " "))" + suffix
    }

    func run(store: ToolStore) {
        guard !isRunning else { return }
        let parsed = NTPProbe.parseServers(servers)
        guard !parsed.servers.isEmpty else {
            error = "Saisir au moins un serveur NTP\u{00A0}: adresse IP ou nom d’hôte."
            return
        }
        guard let port = portValue, port > 0 else {
            error = "Port invalide (1 à 65\u{202F}535)."
            return
        }
        generation += 1
        let run = generation
        error = nil
        notice = parsed.ignored > 0
            ? "\(parsed.ignored) serveur\(parsed.ignored > 1 ? "s" : "") de trop ignoré\(parsed.ignored > 1 ? "s" : "")\u{00A0}: \(NTPProbe.maxServers) au plus par test." : nil
        isRunning = true
        store.record(command: command)
        let demo = isDemo
        task = Task { [weak self] in
            let results: [NTPServerResult]
            if demo {
                try? await Task.sleep(nanoseconds: 600_000_000)
                results = NTPDemo.results()
            } else {
                results = await NTPProbe.run(servers: parsed.servers, options: NTPProbeOptions(port: port))
            }
            guard let self, run == self.generation else { return }
            self.finish(results, store: store)
        }
    }

    private func finish(_ results: [NTPServerResult], store: ToolStore) {
        isRunning = false
        self.results = results
        let worst = results.min { $0.verdict.rank < $1.verdict.rank }
        selection = worst?.id
        guard let worst else { return }
        let summary: String
        if results.count == 1 {
            summary = [worst.verdict.label, worst.sample.flatMap { $0.hasClock ? NTPFormat.offset($0.offset) : nil },
                       worst.sample.flatMap { $0.hasClock ? "strate \($0.stratum)" : nil }].compactMap { $0 }.joined(separator: " · ")
        } else {
            let good = results.filter { $0.verdict == .synchronized }.count
            summary = "\(good) sur \(results.count) synchronisé\(good > 1 ? "s" : "")" + (worst.verdict == .synchronized ? "" : " · pire\u{00A0}: \(worst.server), \(worst.verdict.label)")
        }
        store.record(ToolRecent(tool: .ntp, target: results.map(\.server).joined(separator: ", "), summary: summary, status: worst.verdict.recentStatus))
    }

    func cancel() {
        guard isRunning else { return }
        generation += 1
        task?.cancel()
        task = nil
        isRunning = false
    }
}
