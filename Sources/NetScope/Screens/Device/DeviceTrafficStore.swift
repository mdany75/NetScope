import AppKit
import Foundation
import NetScopeCore

/// Note 105 : trafic en direct de l'appareil ouvert, lu sur les FortiGate du site actif (GET
/// seulement, jeton au Trousseau par FortiGateStore). Une seule fiche à la fois : la lecture tourne
/// tant que l'onglet Trafic ou l'Aperçu est affiché et qu'une fenêtre est visible.
///
/// Rien n'est envoyé en démonstration ni pendant les captures : les lectures viennent de TrafficDemo.
@MainActor
final class DeviceTrafficStore: ObservableObject {
    static let shared = DeviceTrafficStore()

    /// Onglet Trafic : même rythme que le temps réel de l'écran Trafic.
    static let tabSeconds: UInt64 = 5
    /// Aperçu : ouvert à chaque fiche, donc relu plus doucement.
    static let overviewSeconds: UInt64 = 15
    /// Une FortiGate en erreur n'est retentée qu'à ce rythme, pour ne pas insister.
    private static let retrySeconds: UInt64 = 30
    /// Au-delà, un ancien relevé n'est plus montré au retour sur la fiche.
    private static let staleSeconds: TimeInterval = 60

    @Published private(set) var overview: DeviceTrafficOverview?
    @Published private(set) var error: String?
    /// Compteur : l'onglet et la carte peuvent lire en même temps le temps d'une transition.
    @Published private var readsInFlight = 0
    var isReading: Bool { readsInFlight > 0 }

    private var target: String?
    private var counters: DeviceTrafficCounters?
    /// Dernière erreur de chaque FortiGate du site.
    private var failures: [UUID: String] = [:]
    private var tick = 0

    let isDemo: Bool

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
    }

    /// Une IP ne vaut que dans son site : la lecture est liée au site actif et à l'adresse.
    static func key(_ device: Device) -> String {
        "\(SiteModel.shared.activeKey)|\(device.ip)"
    }

    private var controllerIDs: [UUID] {
        TrafficStore.shared.controllerIDs(forKey: SiteModel.shared.activeKey)
    }

    /// Erreur à montrer, avec l'âge des chiffres encore affichés.
    var errorWithAge: String? {
        guard let error else { return nil }
        guard let overview else { return error }
        return error + " Dernier relevé\u{00A0}: \(ToolText.relative(overview.readAt))."
    }

    /// Pourquoi le trafic de cette fiche ne peut pas être lu ; nil si la lecture est possible. Seules
    /// les FortiGate de ce site comptent : une autre, prête ailleurs, ne dit rien de celui-ci.
    func blocker(manual: ManualDeviceEntry?) -> String? {
        if case .otherSite(let site)? = manual?.source {
            return "Cet appareil vient du site «\u{00A0}\(site)\u{00A0}»\u{00A0}: choisissez ce site pour lire son trafic sur la bonne FortiGate."
        }
        let ids = controllerIDs
        if ids.isEmpty {
            return "Aucune FortiGate pour ce site\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate."
        }
        guard !isDemo else { return nil }
        let fortigate = FortiGateStore.shared
        let enabled = ids.compactMap(fortigate.controller).filter(\.isEnabled)
        guard fortigate.isEnabled, let first = enabled.first else {
            return "La FortiGate de ce site est désactivée\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate."
        }
        if enabled.contains(where: fortigate.isReady) { return nil }
        return fortigate.notReadyReason(first) ?? "La FortiGate de ce site n’est pas prête\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate."
    }

    /// Autre appareil ou autre site : rien de l'ancien ne doit rester affiché.
    private func prepare(_ key: String) {
        guard key != target else { return }
        target = key
        overview = nil
        error = nil
        counters = nil
        failures = [:]
        tick = 0
    }

    /// Relit tant que la tâche vit, en pause si aucune fenêtre n'est visible. Les lectures se
    /// suivent : jamais deux à la fois pour une même tâche.
    func runLive(_ device: Device, every seconds: UInt64) async {
        guard !isDemo else {
            loadDemoNow(device)
            return
        }
        let key = Self.key(device)
        prepare(key)
        if let shown = overview, Date().timeIntervalSince(shown.readAt) > Self.staleSeconds {
            overview = nil
            counters = nil
        }
        let retryEvery = max(1, Int(Self.retrySeconds / max(seconds, 1)))
        while !Task.isCancelled {
            if TrafficStore.isMainWindowVisible {
                await read(device, key: key, retryEvery: retryEvery)
            }
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    }

    private func read(_ device: Device, key: String, retryEvery: Int) async {
        let fortigate = FortiGateStore.shared
        let due = tick % retryEvery == 0
        tick += 1
        let ids = controllerIDs.filter { failures[$0] == nil || due }
        guard !ids.isEmpty, fortigate.isEnabled else { return }
        readsInFlight += 1
        defer { readsInFlight -= 1 }
        let picks = ids.map { id in
            FortiControllerSelection.Pick(controllerID: id, site: fortigate.controller(id)?.displayName ?? "FortiGate", reason: .activeSite)
        }
        let targets = await fortigate.wifiTargets(for: FortiControllerSelection(picks: picks))
        let ip = device.ip
        let jobs = targets.ready.map { Job(id: $0.0.id, site: $0.0.displayName, config: $0.0.config, token: $0.1, ip: ip) }
        let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job in
            await DeviceTrafficStore.perform(job)
        }
        // La fiche a changé pendant la lecture : ce résultat ne la concerne plus.
        guard !Task.isCancelled, key == target else { return }

        var reads: [DeviceTrafficRead] = []
        for (id, reason) in targets.blocked { failures[id] = reason }
        for (job, result) in zip(jobs, results) {
            switch result {
            case .success(let read):
                reads.append(read)
                failures[job.id] = nil
            case .failure(let message):
                failures[job.id] = message
            case .cancelled:
                break
            }
        }
        error = failures.isEmpty ? nil : Array(Set(failures.values)).sorted().joined(separator: " ")
        guard !reads.isEmpty else { return }
        let now = Date()
        let built = DeviceTrafficAnalysis.build(reads: reads, ip: ip, known: known(ids), previous: counters, now: now)
        overview = built
        // Sessions illisibles à ce relevé : les compteurs précédents restent bons pour le suivant.
        if built.sessionsKnown { counters = DeviceTrafficAnalysis.counters(built.sessions, at: now) }
    }

    /// Noms, pays, catégories et risques déjà lus par l'écran Trafic pour ce site.
    private func known(_ ids: [UUID]) -> [TrafficEntry] {
        ids.flatMap { TrafficStore.shared.cache[$0]?.report.entries ?? [] }
    }

    private struct Job: Sendable {
        var id: UUID
        var site: String
        var config: FortiGateConfig
        var token: String
        var ip: IPv4Address
    }

    private enum Outcome: Sendable {
        case success(DeviceTrafficRead)
        case failure(String)
        case cancelled
    }

    /// Lecture réseau, hors du fil principal.
    private nonisolated static func perform(_ job: Job) async -> Outcome {
        let transport = FortiURLSessionTransport(config: job.config, token: job.token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: job.token)
        do {
            return .success(try await reader.readDeviceTraffic(ip: job.ip).relabeled(site: job.site))
        } catch is CancellationError {
            return .cancelled
        } catch let error as FortiGateError {
            return .failure(FortiRedact.clean(error.trafficDescription, token: job.token))
        } catch {
            return .failure("Lecture du trafic impossible.")
        }
    }

    // MARK: Démonstration

    /// Démonstration et captures : relevé fictif du site actif, avec les débits d'un second relevé.
    func loadDemoNow(_ device: Device) {
        guard isDemo else { return }
        prepare(Self.key(device))
        let now = Date()
        var reports: [TrafficReadReport] = []
        var reads: [DeviceTrafficRead] = []
        for id in controllerIDs {
            let name = FortiGateStore.shared.controller(id)?.displayName ?? "FortiGate"
            if let report = TrafficDemo.report(controllerID: id, period: .realtime, now: now) {
                reports.append(report)
                reads.append(DeviceTrafficRead(report: report, ip: device.ip).relabeled(site: name))
            } else if let message = TrafficDemo.error(controllerID: id) {
                error = message
            }
        }
        // Les sessions cinq secondes plus tôt : leur part du débit donné par la ligne Sources.
        let seconds = 5.0
        let earlier = reads.flatMap { read -> [TrafficSession] in
            let total = read.sessions.reduce(0.0) { $0 + Double($1.bytes) }
            let share = total > 0 ? min(1, (read.source?.bandwidth ?? 0) * seconds / 8 / total) : 0
            return read.sessions.map { session in
                var copy = session
                copy.sentBytes = UInt64(Double(session.sentBytes) * (1 - share))
                copy.receivedBytes = UInt64(Double(session.receivedBytes) * (1 - share))
                return copy
            }
        }
        overview = DeviceTrafficAnalysis.build(reads: reads, ip: device.ip, known: reports.flatMap(\.entries),
                                               previous: DeviceTrafficAnalysis.counters(earlier, at: now.addingTimeInterval(-seconds)), now: now)
    }
}
