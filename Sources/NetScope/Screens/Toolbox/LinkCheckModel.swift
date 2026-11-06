import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Bilan de raccordement (note 58) : lance le bilan sur l'interface choisie, garde les bilans de
/// chaque site (sites/<id>/bilans-raccordement.json), le bilan « avant » et ceux retenus pour le
/// rapport. En démonstration et pendant les captures, rien n'est lu ni écrit et aucun paquet ne
/// part : les mesures viennent de LinkCheckDemo.
@MainActor
final class LinkCheckModel: ObservableObject {
    static let shared = LinkCheckModel()

    enum Phase: Equatable { case idle, running, finished }

    @Published var interfaces: [LocalInterface] = []
    @Published var interfaceName = ""
    @Published var location = ""
    @Published var expectedVLANText = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    /// Étapes terminées du bilan en cours.
    @Published private(set) var partial: [LinkCheckStepKind: LinkCheckStep] = [:]
    /// Étapes commencées et pas encore terminées.
    @Published private(set) var inProgress: Set<LinkCheckStepKind> = []
    /// Bilan affiché (le dernier lancé, ou celui choisi dans l'historique).
    @Published var shownID: UUID?
    /// Bilan de comparaison choisi (nil : la référence « avant », sinon le précédent).
    @Published var compareID: UUID?
    @Published var onlyDifferences = true
    @Published var error: String?
    @Published var toast: String?
    /// Bilan à retirer de l'historique, en attente de confirmation.
    @Published var pendingRemoval: LinkCheckResult?
    /// Historique de chaque site (clé du site) ; `revision` annonce les changements.
    private var histories: [String: LinkCheckHistory] = [:]
    @Published private(set) var revision = 0

    let isDemo: Bool
    /// Démonstration ou capture : rien n'est lu ni écrit sur le disque.
    let isEphemeral: Bool
    private var task: Task<Void, Never>?
    /// Jeton du bilan en cours : les avancements tardifs d'un bilan arrêté sont ignorés.
    private var runToken = UUID()

    init() {
        let arguments = CommandLine.arguments
        isDemo = arguments.contains("--demo")
        isEphemeral = isDemo || arguments.contains("--snapshot")
        if isDemo {
            histories = LinkCheckDemo.histories()
            interfaces = CaptureDemo.interfaces
            interfaceName = "en7"
            location = LinkCheckDemo.location
            phase = .finished
            shownID = histories[SitesDemo.siegeKey]?.latest?.id
        }
    }

    var isRunning: Bool { phase == .running }
    var expectedVLAN: Int? { Int(expectedVLANText.trimmingCharacters(in: .whitespaces)) }
    var vlanInvalid: Bool {
        let text = expectedVLANText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        guard let value = Int(text) else { return true }
        return !(1...4094).contains(value)
    }
    var command: String { "bilan-raccordement -i \(interfaceName.isEmpty ? "en0" : interfaceName)" + (expectedVLAN.map { " --vlan \($0)" } ?? "") }

    func prepare(active: LocalInterface?) async {
        guard !isDemo else { return }
        let list = await LocalInterfaces.linkInterfacesWithKinds()
        interfaces = list
        if interfaceName.isEmpty || !list.contains(where: { $0.name == interfaceName }) {
            interfaceName = LocalInterfaces.preferredLinkInterface(in: list, preferred: active?.name)?.name ?? ""
        }
    }

    // MARK: Historique du site

    var siteKey: String { SiteModel.shared.activeKey }

    private func url(for key: String) -> URL? {
        SiteModel.shared.files?.folder(for: key).appendingPathComponent(LinkCheckHistory.fileName)
    }

    func history(forKey key: String) -> LinkCheckHistory {
        if let loaded = histories[key] { return loaded }
        guard !isEphemeral, let url = url(for: key) else { return LinkCheckHistory() }
        let loaded = LinkCheckHistory.load(from: url)
        histories[key] = loaded
        return loaded
    }

    var history: LinkCheckHistory { history(forKey: siteKey) }

    private func update(_ key: String, _ change: (inout LinkCheckHistory) -> Void) {
        var h = history(forKey: key)
        change(&h)
        histories[key] = h
        revision += 1
        guard !isEphemeral, let url = url(for: key) else { return }
        do {
            try h.save(to: url)
        } catch {
            AppLog.shared.error("Outils", "Historique des bilans de raccordement non enregistré\u{00A0}: \(error.localizedDescription)")
        }
    }

    /// Bilan affiché : celui choisi, sinon le plus récent du site.
    var shown: LinkCheckResult? {
        let h = history
        return shownID.flatMap { h.result($0) } ?? h.latest
    }

    /// Bilan de comparaison du bilan affiché.
    var baseline: LinkCheckResult? {
        guard let shown else { return nil }
        let h = history
        if let compareID, compareID != shown.id, let chosen = h.result(compareID) { return chosen }
        return h.baseline(for: shown)
    }

    func setReference(_ result: LinkCheckResult?) {
        update(siteKey) { $0.setReference(result?.id) }
        compareID = nil
        toast = result == nil ? "Référence «\u{00A0}avant\u{00A0}» retirée." : "Bilan du \(LinkCheckText.dateLabel(result!.date)) retenu comme «\u{00A0}avant\u{00A0}»\u{00A0}: le prochain bilan lui sera comparé."
    }

    func isReported(_ result: LinkCheckResult) -> Bool { history.isReported(result.id) }

    /// « Ajouter au rapport » : retenu pour la section « Bilan de raccordement » (cochée).
    func toggleReport(_ result: LinkCheckResult) {
        if isReported(result) {
            update(siteKey) { $0.unreport(result.id) }
            toast = "Bilan retiré du rapport du site."
        } else {
            update(siteKey) { $0.report(result.id) }
            RapportModel.shared.config.sections.insert(.raccordement)
            toast = "Bilan ajouté au rapport du site (section «\u{00A0}Bilan de raccordement\u{00A0}»)."
        }
    }

    /// « Retirer de l'historique » : confirmation quand le bilan est la référence « avant » ou
    /// qu'il est retenu pour le rapport du site.
    func requestRemove(_ result: LinkCheckResult) {
        if history.referenceID == result.id || isReported(result) {
            pendingRemoval = result
        } else {
            remove(result)
        }
    }

    func remove(_ result: LinkCheckResult) {
        pendingRemoval = nil
        update(siteKey) { $0.remove(result.id) }
        if shownID == result.id { shownID = nil }
        if compareID == result.id { compareID = nil }
    }

    /// Bilans retenus pour le rapport d'un site, avec leur bilan de comparaison.
    func reportEntries(forKey key: String) -> [LinkCheckReportEntry] {
        let h = history(forKey: key)
        return h.reported.map { LinkCheckReportEntry(result: $0, before: h.baseline(for: $0)) }
    }

    // MARK: Bilan

    func run(store: ToolStore) {
        guard !isRunning else { return }
        error = nil
        toast = nil
        let name = interfaceName
        guard CaptureInterfaceName.isValid(name) else {
            error = "Choisissez une interface réseau."
            return
        }
        guard !vlanInvalid else {
            error = "VLAN attendu illisible\u{00A0}: un nombre de 1 à 4094."
            return
        }
        let options = LinkCheckOptions(interfaceName: name, location: location, expectedVLAN: expectedVLAN,
                                       allowedDHCPServers: store.dhcp.policy.allowed)
        let probes: any LinkCheckProbing
        if isDemo {
            probes = LinkCheckDemo.probes()
        } else {
            let neighbors = store.neighbors
            probes = LiveLinkCheckProbes(previousNeighbor: neighbors.lastNeighbor, previousContext: neighbors.lastContext,
                                         pinger: try? ICMPPinger())
        }
        store.record(command: command)
        let token = UUID()
        runToken = token
        partial = [:]
        inProgress = []
        phase = .running
        startedAt = Date()
        compareID = nil
        let key = siteKey
        let siteName = SiteModel.shared.activeName
        task = Task { [weak self] in
            let result = await LinkCheckRunner.run(options, probes: probes, siteKey: key, siteName: siteName,
                                                    progress: { progress in
                Task { @MainActor in self?.apply(progress, token: token) }
            })
            guard !Task.isCancelled else { return }
            self?.finish(result, key: key, token: token, store: store)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        runToken = UUID()
        phase = shown == nil ? .idle : .finished
        partial = [:]
        inProgress = []
        startedAt = nil
    }

    private func apply(_ progress: LinkCheckProgress, token: UUID) {
        guard token == runToken, isRunning else { return }
        if let step = progress.step {
            partial[step.kind] = step
            inProgress.remove(step.kind)
        } else if partial[progress.kind] == nil {
            inProgress.insert(progress.kind)
        }
    }

    private func finish(_ result: LinkCheckResult, key: String, token: UUID, store: ToolStore) {
        guard token == runToken else { return }
        // Note 89 : test de câble de ce port fait dans les dernières 24 h, ajouté au bilan.
        var result = result
        if result.cableTest == nil, let step = result.step(.switchPort), let name = step.fact("switch")?.value,
           let port = step.fact("port")?.value {
            result.cableTest = CableTestModel.shared.latest(switchName: name, port: port, since: Date().addingTimeInterval(-86_400))
        }
        update(key) { $0.add(result) }
        shownID = result.id
        phase = .finished
        partial = [:]
        inProgress = []
        startedAt = nil
        let status: ToolRecent.Status
        switch result.overall {
        case .ok: status = .ok
        case .warning, .failure: status = .warning
        case .skipped: status = .info
        }
        let target = result.interfaceName + (result.location.isEmpty ? "" : " · \(result.location)")
        store.record(ToolRecent(tool: .bilan, target: target, summary: result.headline + " · " + result.oneLine, status: status))
    }

    // MARK: Export

    func copyText(_ result: LinkCheckResult) {
        ToolActions.copy(LinkCheckText.plain(result, comparedTo: comparisonBase(for: result)))
        toast = "Bilan copié."
    }

    private func comparisonBase(for result: LinkCheckResult) -> LinkCheckResult? {
        result.id == shown?.id ? baseline : history.baseline(for: result)
    }

    /// Document PDF d'un bilan (et de sa comparaison), mis en page comme les rapports.
    func pdfData(_ result: LinkCheckResult) -> Data? {
        let rapport = RapportModel.shared
        let document = ReportBuilder.linkCheckDocument(LinkCheckReportEntry(result: result, before: comparisonBase(for: result)),
                                                       client: rapport.config.client, technician: rapport.config.technician)
        return RapportPDF.render(document, pages: ReportPaginator.paginate(document), logo: rapport.logo)
    }

    static func fileName(_ result: LinkCheckResult) -> String {
        let place = result.location.isEmpty ? result.siteName : result.location
        let slug = ReportText.slug(place.isEmpty ? result.interfaceName : place)
        return "bilan-raccordement-\(slug)-\(ReportText.isoDay(result.date)).pdf"
    }

    func exportPDF(_ result: LinkCheckResult) {
        guard let data = pdfData(result) else {
            error = "Rendu PDF impossible."
            return
        }
        guard !isEphemeral else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(result)
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            self.error = nil
            toast = "PDF enregistré\u{00A0}: \(url.lastPathComponent)."
        } catch {
            toast = nil
            self.error = "Export impossible\u{00A0}: \(error.localizedDescription)"
        }
    }
}
