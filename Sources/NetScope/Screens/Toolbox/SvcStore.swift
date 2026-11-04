import Foundation
import NetScopeCore
import SwiftUI

/// État des grands services en ligne (note 15) : catalogue modifiable, dernières vérifications,
/// historique, rafraîchissement automatique et notifications. Une seule instance, partagée par
/// l'outil de la Boîte à outils, la tuile de Surveillance et la barre de menus.
///
/// Rien ne part sur le réseau avant la première ouverture de l'outil ; ensuite, la vérification
/// reprend à chaque lancement selon l'intervalle choisi (5 min par défaut).
/// Enregistré dans ~/Library/Application Support/NetScope/services-en-ligne.json ; le secret de
/// Microsoft Graph va au Trousseau (com.danymenard.netscope.m365). Démonstration ou capture :
/// données fixes (ServiceStatusDemo), aucune requête, rien d'enregistré.
@MainActor
final class SvcStore: ObservableObject {
    static let shared = SvcStore()

    /// Intervalles proposés (minutes).
    static let intervals = [1, 5, 15, 30, 60]
    static let keychain = UpdKeychain(service: "com.danymenard.netscope.m365")
    static let secretAccount = "secret-application"

    @Published private(set) var services: [SvcService] = SvcCatalog.builtIn
    @Published private(set) var snapshots: [String: SvcSnapshot] = [:]
    @Published private(set) var history = SvcHistory()
    @Published private(set) var checking: Set<String> = []
    @Published private(set) var lastRefresh: Date?
    @Published var selectedServiceID: String?
    @Published var refreshMinutes = 5 { didSet { if oldValue != refreshMinutes { changed() } } }
    @Published var notifyIncidents = true { didSet { if oldValue != notifyIncidents { changed() } } }
    /// Microsoft Graph : locataire et application (le secret est au Trousseau).
    @Published private(set) var graphTenant = ""
    @Published private(set) var graphClient = ""
    @Published private(set) var graphSecretSet = false
    /// Proxy du système (lecture locale), affiché avec les problèmes « chez nous ».
    @Published private(set) var systemProxy: String?

    /// Démonstration ou capture : aucune requête.
    let isSimulated: Bool
    /// Heure figée des captures.
    private(set) var demoNow: Date?
    /// L'outil a déjà été ouvert : le rafraîchissement automatique peut tourner.
    private var hasBeenUsed = false
    private var timer: Timer?
    private var saveScheduled = false
    private let url: URL

    private struct Archive: Codable {
        var services: [SvcService]
        var snapshots: [String: SvcSnapshot]
        var history: SvcHistory
        var lastRefresh: Date?
        var refreshMinutes: Int
        var notifyIncidents: Bool
        var hasBeenUsed: Bool
        var graphTenant: String
        var graphClient: String
    }

    private init() {
        let arguments = CommandLine.arguments
        isSimulated = arguments.contains("--demo") || arguments.contains("--snapshot")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("services-en-ligne.json")
        if arguments.contains("--demo") {
            ServiceStatusDemo.load(into: self)
        } else if !isSimulated {
            load()
        }
    }

    // MARK: Démarrage

    /// Au lancement : reprend la vérification automatique si l'outil a déjà servi.
    func attach() {
        guard !isSimulated, hasBeenUsed else { return }
        startTimer()
    }

    /// Ouverture de l'outil : active la vérification automatique et vérifie si c'est le moment.
    func activate() {
        guard !isSimulated else { return }
        if !hasBeenUsed {
            hasBeenUsed = true
            changed()
        }
        startTimer()
        if isDue(Date()) { refresh() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { _ in
            Task { @MainActor in
                let store = SvcStore.shared
                if store.isDue(Date()) { store.refresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func isDue(_ date: Date) -> Bool {
        guard checking.isEmpty else { return false }
        guard let lastRefresh else { return true }
        return date.timeIntervalSince(lastRefresh) >= TimeInterval(refreshMinutes * 60)
    }

    // MARK: Lecture

    var now: Date { demoNow ?? Date() }
    var enabledServices: [SvcService] { services.filter(\.isEnabled) }
    var isChecking: Bool { !checking.isEmpty }

    func snapshot(_ id: String) -> SvcSnapshot? { snapshots[id] }

    func service(_ id: String?) -> SvcService? {
        guard let id else { return nil }
        return services.first { $0.id == id }
    }

    /// Vérifications des services actifs, dans l'ordre du catalogue.
    var currentSnapshots: [SvcSnapshot] { enabledServices.compactMap { snapshots[$0.id] } }

    func count(_ health: SvcHealth) -> Int {
        currentSnapshots.filter { $0.verdict.health == health }.count
    }

    /// Services en difficulté, les plus graves d'abord.
    var problemServices: [SvcService] {
        enabledServices.filter { snapshots[$0.id]?.verdict.health.isProblem == true }
            .sorted { (snapshots[$0.id]?.verdict.health ?? .unknown) > (snapshots[$1.id]?.verdict.health ?? .unknown) }
    }

    /// Incidents en cours de tous les services actifs, les plus graves puis les plus récents d'abord.
    var activeIncidents: [(service: SvcService, incident: SvcIncident)] {
        enabledServices.flatMap { service in
            (snapshots[service.id]?.activeIncidents ?? []).map { (service: service, incident: $0) }
        }
        .sorted {
            if $0.incident.impact != $1.incident.impact { return $0.incident.impact > $1.incident.impact }
            return ($0.incident.updated ?? .distantPast) > ($1.incident.updated ?? .distantPast)
        }
    }

    var globalProblem: String? { SvcVerdictRules.globalProblem(currentSnapshots) }

    /// Phrase de bilan (« 12 OK · 1 dégradé · 1 injoignable d’ici »).
    var summaryLine: String {
        guard !currentSnapshots.isEmpty else { return isChecking ? "Vérification en cours…" : "Pas encore vérifié" }
        var parts = ["\(count(.operational)) OK"]
        let degraded = count(.degraded) + count(.maintenance)
        if degraded > 0 { parts.append("\(degraded) dégradé\(degraded > 1 ? "s" : "")") }
        if count(.outage) > 0 { parts.append("\(count(.outage)) en panne") }
        if count(.unreachable) > 0 { parts.append("\(count(.unreachable)) injoignable\(count(.unreachable) > 1 ? "s" : "") d’ici") }
        return parts.joined(separator: " · ")
    }

    /// Ton global (barre de menus, tuile).
    var overallTone: Tone {
        if count(.outage) > 0 || count(.unreachable) > 0 { return .critical }
        if count(.degraded) > 0 { return .warning }
        if count(.maintenance) > 0 { return .accent }
        return currentSnapshots.isEmpty ? .neutral : .success
    }

    /// Commande équivalente (en-tête de l'outil).
    var command: String {
        let service = service(selectedServiceID) ?? enabledServices.first
        if let feed = service?.feedURL { return "curl -s \(feed)" }
        if let endpoint = service?.endpoints.first { return "curl -sI \(endpoint)" }
        return "curl -s <page d’état>"
    }

    // MARK: Vérification

    /// Vérifie tous les services actifs (en parallèle, six à la fois).
    func refresh(manual: Bool = false) {
        guard !isSimulated else { return }
        let targets = enabledServices.filter { !checking.contains($0.id) }
        guard !targets.isEmpty else { return }
        systemProxy = SvcReachability.systemProxy()
        checking.formUnion(targets.map(\.id))
        lastRefresh = Date()
        let checker = SvcChecker(fetcher: SvcNetworkFetcher(), prober: SvcNetworkProber(), graph: graphCredentials())
        if manual {
            ToolStore.shared.record(command: "netscope services --verifier (\(targets.count) services)")
        }
        Task {
            await withTaskGroup(of: (SvcService, SvcSnapshot).self) { group in
                var pending = targets[...]
                func next() {
                    guard let service = pending.popFirst() else { return }
                    group.addTask { (service, await checker.check(service)) }
                }
                for _ in 0..<6 { next() }
                for await (service, snapshot) in group {
                    SvcStore.shared.finish(service, snapshot: snapshot)
                    next()
                }
            }
            SvcStore.shared.finishedAll(manual: manual)
        }
    }

    /// Vérifie un seul service (bouton du détail).
    func refresh(_ id: String) {
        guard !isSimulated, let service = service(id), !checking.contains(id) else { return }
        checking.insert(id)
        let checker = SvcChecker(fetcher: SvcNetworkFetcher(), prober: SvcNetworkProber(), graph: graphCredentials())
        Task {
            let snapshot = await checker.check(service)
            SvcStore.shared.finish(service, snapshot: snapshot)
        }
    }

    private func finish(_ service: SvcService, snapshot: SvcSnapshot) {
        checking.remove(service.id)
        // Service retiré ou désactivé pendant la vérification : résultat écarté.
        guard let current = self.service(service.id), current.isEnabled else { return }
        let known = history.lastHealth[service.id] != nil
        let previousHealth = history.lastHealth[service.id]
        let fresh = history.record(snapshot, service: current)
        snapshots[service.id] = snapshot
        // Pas de notification à la toute première vérification d'un service : ses incidents
        // existaient déjà, ils sont seulement listés.
        if notifyIncidents, known {
            for incident in fresh {
                MonNotifier.shared.postService(
                    title: "\(current.name)\u{00A0}: " + (incident.impact == .outage ? "panne" : incident.impact == .maintenance ? "maintenance" : "incident"),
                    body: incident.title + (incident.affected.isEmpty ? "" : " (\(incident.affected.joined(separator: ", ")))"),
                    serviceID: current.id, identifier: "service-\(current.id)-\(incident.id)")
            }
            if snapshot.verdict.health == .unreachable, previousHealth != .unreachable {
                MonNotifier.shared.postService(title: "\(current.name) injoignable d’ici", body: snapshot.verdict.headline,
                                               serviceID: current.id, identifier: "service-\(current.id)-injoignable-\(Int(snapshot.date.timeIntervalSince1970))")
            }
        }
        changed()
    }

    private func finishedAll(manual: Bool) {
        guard manual else { return }
        let status: ToolRecent.Status = count(.outage) + count(.unreachable) > 0 ? .failure
            : count(.degraded) > 0 ? .warning : .ok
        ToolStore.shared.record(ToolRecent(tool: .cloud, target: "\(currentSnapshots.count) services", summary: summaryLine, status: status))
    }

    // MARK: Catalogue

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return }
        services[index].isEnabled = enabled
        if !enabled { snapshots[id] = nil }
        changed()
        if enabled { refresh(id) }
    }

    /// Ajoute un service personnalisé ; renvoie une erreur lisible si la saisie est incomplète.
    func addCustom(name: String, format: SvcFeedFormat, feedURL: String, pageURL: String, endpoints: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Donner un nom au service." }
        let hosts = endpoints.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline }).map(String.init)
        let parsed = hosts.compactMap(SvcCatalog.endpoint(from:))
        guard parsed.count == hosts.count else { return "Adresses clés\u{00A0}: noms d’hôte ou adresses https:// séparés par des virgules." }
        let feed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if format != .none {
            guard let url = URL(string: feed), url.scheme?.lowercased() == "https" else {
                return "Adresse de la page d’état\u{00A0}: adresse https:// attendue pour ce format."
            }
        }
        guard !parsed.isEmpty || format != .none else { return "Indiquer au moins une adresse clé ou une page d’état lisible." }
        let page = pageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = SvcService(id: SvcCatalog.customID(for: trimmed, existing: services), name: trimmed, category: "Personnalisé",
                                 format: format, feedURL: format == .none ? nil : feed,
                                 pageURL: page.isEmpty ? (feed.isEmpty ? parsed.first ?? "" : feed) : page,
                                 endpoints: parsed, isCustom: true)
        services.append(service)
        changed()
        refresh(service.id)
        return nil
    }

    func remove(_ id: String) {
        guard let service = service(id), service.isCustom else { return }
        services.removeAll { $0.id == id }
        snapshots[id] = nil
        history.forget(serviceID: id)
        if selectedServiceID == id { selectedServiceID = nil }
        changed()
    }

    /// Liste intégrée d'origine (les services personnalisés sont gardés).
    func resetCatalog() {
        let custom = services.filter(\.isCustom)
        services = SvcCatalog.builtIn + custom
        changed()
    }

    // MARK: Microsoft Graph

    /// Identifiants complets (secret lu au Trousseau), ou nil sans configuration.
    func graphCredentials() -> SvcGraphCredentials? {
        guard !isSimulated, !graphTenant.isEmpty, !graphClient.isEmpty,
              let secret = Self.keychain.string(for: Self.secretAccount) else { return nil }
        let credentials = SvcGraphCredentials(tenantID: graphTenant, clientID: graphClient, clientSecret: secret)
        return credentials.isComplete ? credentials : nil
    }

    /// Enregistre l'accès Graph ; un secret vide garde celui du Trousseau.
    func saveGraph(tenant: String, client: String, secret: String) -> String? {
        let tenant = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = client.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SvcGraph.isValidTenant(tenant) else { return "Locataire\u{00A0}: GUID ou domaine (contoso.onmicrosoft.com)." }
        guard !client.isEmpty else { return "Indiquer l’identifiant de l’application (client)." }
        guard !isSimulated else { return nil }
        if !secret.isEmpty {
            do {
                try Self.keychain.set(secret, for: Self.secretAccount)
            } catch {
                return error.localizedDescription
            }
        }
        graphTenant = tenant
        graphClient = client
        graphSecretSet = Self.keychain.string(for: Self.secretAccount) != nil
        changed()
        refresh("microsoft365")
        return nil
    }

    /// Retire l'accès Graph (secret effacé du Trousseau).
    func clearGraph() {
        if !isSimulated { try? Self.keychain.delete(Self.secretAccount) }
        graphTenant = ""
        graphClient = ""
        graphSecretSet = false
        changed()
    }

    // MARK: Enregistrement

    private func changed() {
        guard !isSimulated, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                SvcStore.shared.saveScheduled = false
                SvcStore.shared.save()
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(Archive.self, from: data) else {
            NSLog("NetScope\u{00A0}: lecture impossible de %@", url.path)
            return
        }
        services = SvcCatalog.merged(saved: archive.services)
        snapshots = archive.snapshots
        history = archive.history
        lastRefresh = archive.lastRefresh
        refreshMinutes = Self.intervals.contains(archive.refreshMinutes) ? archive.refreshMinutes : 5
        notifyIncidents = archive.notifyIncidents
        hasBeenUsed = archive.hasBeenUsed
        graphTenant = archive.graphTenant
        graphClient = archive.graphClient
        graphSecretSet = !graphTenant.isEmpty && Self.keychain.string(for: Self.secretAccount) != nil
    }

    func save() {
        guard !isSimulated else { return }
        let archive = Archive(services: services, snapshots: snapshots, history: history, lastRefresh: lastRefresh,
                              refreshMinutes: refreshMinutes, notifyIncidents: notifyIncidents, hasBeenUsed: hasBeenUsed,
                              graphTenant: graphTenant, graphClient: graphClient)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(archive).write(to: url, options: .atomic)
        } catch {
            NSLog("NetScope\u{00A0}: enregistrement impossible de %@\u{00A0}: %@", url.path, error.localizedDescription)
        }
    }

    // MARK: Démonstration

    func loadDemo(services: [SvcService], snapshots: [String: SvcSnapshot], history: SvcHistory, now: Date,
                  selected: String?, proxy: String?) {
        self.services = services
        self.snapshots = snapshots
        self.history = history
        lastRefresh = now.addingTimeInterval(-2 * 60)
        selectedServiceID = selected
        systemProxy = proxy
        graphTenant = "contoso.onmicrosoft.com"
        graphClient = "3f2b8c1e-…"
        graphSecretSet = true
        demoNow = CommandLine.arguments.contains("--snapshot") ? now : nil
    }
}
