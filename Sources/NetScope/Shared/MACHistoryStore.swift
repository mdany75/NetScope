import AppKit
import Foundation
import NetScopeCore

/// Note 99 : historique des adresses MAC, un fichier par site (`sites/<clé>/historique-mac.json`
/// dans Application Support/NetScope). Alimenté par ce que NetScope lit déjà : fusion des scans dans
/// l'Inventaire, relevés des switchs (SNMP et FortiGate), clients Wi-Fi des FortiAP. Rien de plus
/// n'est envoyé sur le réseau. Chaque relevé va dans l'historique du site qui l'a produit ; la clé
/// est la MAC, jamais l'IP. Enregistrement différé (une minute au plus, et à la fermeture) ; en
/// démonstration et pendant les captures, rien n'est lu ni écrit : historique de MACHistoryDemo.
@MainActor
final class MACHistoryStore: ObservableObject {
    static let shared = MACHistoryStore()

    @Published private(set) var revision = 0
    /// Durée de conservation en jours (réglage commun à tous les sites).
    @Published var retentionDays: Int {
        didSet {
            guard retentionDays != oldValue else { return }
            if !isDemo { UserDefaults.standard.set(retentionDays, forKey: Self.retentionKey) }
            for key in histories.keys { prune(key) }
            revision += 1
        }
    }

    let isDemo: Bool
    private let files: SiteFiles
    private var histories: [String: MACHistory] = [:]
    private var dirty: Set<String> = []
    private var saveTask: Task<Void, Never>?
    static let fileName = "historique-mac.json"
    private static let retentionKey = "macHistoryRetentionDays"

    /// Dernière recherche de « Où était cet appareil ? », propre au site (une même IP peut exister
    /// sur deux sites) ; vide : l'outil s'ouvre sur une fiche vierge.
    private static func lastQueryKey(_ site: String) -> String { "macHistoryLastQuery.\(site)" }

    var lastQuery: String {
        guard !Launcher.isDemo, !RegEnvironment.isSnapshot else { return "" }
        return UserDefaults.standard.string(forKey: Self.lastQueryKey(SiteModel.shared.activeKey)) ?? ""
    }

    func rememberQuery(_ text: String) {
        guard !Launcher.isDemo, !RegEnvironment.isSnapshot else { return }
        let clean = text.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(clean, forKey: Self.lastQueryKey(SiteModel.shared.activeKey))
    }

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot, files: SiteFiles = .standard) {
        isDemo = demo
        self.files = files
        let stored = demo ? 0 : UserDefaults.standard.integer(forKey: Self.retentionKey)
        retentionDays = stored > 0 ? stored : MACHistory.defaultRetentionDays
        if demo {
            histories[SiteModel.shared.activeKey] = MACHistoryDemo.history()
        } else {
            // À la fermeture, écriture immédiate sur le fil principal : une tâche détachée n'aurait
            // pas le temps de finir avant la fin de l'application.
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MACHistoryStore.shared.saveNow(synchronously: true) }
            }
        }
    }

    private func url(_ siteKey: String) -> URL { files.folder(for: siteKey).appendingPathComponent(Self.fileName) }

    func history(siteKey: String) -> MACHistory {
        if let cached = histories[siteKey] { return cached }
        guard !isDemo else { return MACHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url(siteKey))).flatMap { try? decoder.decode(MACHistory.self, from: $0) } ?? MACHistory()
        histories[siteKey] = loaded
        prune(siteKey)
        return histories[siteKey] ?? loaded
    }

    var activeHistory: MACHistory { history(siteKey: SiteModel.shared.activeKey) }

    /// Chronologie d'un appareil du site actif (par sa MAC).
    func timeline(for device: Device) -> [MACSighting] {
        guard let mac = device.mac else { return [] }
        return activeHistory.timeline(for: mac)
    }

    // MARK: Alimentation

    /// Fusion d'un scan dans l'Inventaire du site.
    func record(devices: [Device], siteKey: String, at date: Date = Date()) {
        record(MACHistory.observations(devices: devices), siteKey: siteKey, at: date)
    }

    /// Relevés des switchs d'un site (SNMP, ou FortiSwitch lus par la FortiGate). Les uplinks sont
    /// reconnus avec tous les relevés du site (`context`), pas relevé par relevé : sinon, sur un petit
    /// site sans LLDP, les MAC vues par l'uplink seraient rangées sur ce port.
    func record(snapshots: [SNMPSwitchSnapshot], siteKey: String, source: MACSightingSource = .switchTable,
                context: [SNMPSwitchSnapshot]) {
        guard !isDemo, !snapshots.isEmpty else { return }
        let hosts = Set(snapshots.map(\.host))
        let uplinks = SNMPLocator.uplinks(in: snapshots + context.filter { !hosts.contains($0.host) })
        var history = history(siteKey: siteKey)
        for snapshot in snapshots {
            let observations = MACHistory.observations(snapshots: [snapshot], source: source, uplinks: uplinks)
            if !observations.isEmpty { history.record(observations, at: snapshot.polledAt) }
        }
        histories[siteKey] = history
        dirty.insert(siteKey)
        revision += 1
        scheduleSave()
    }

    /// Clients Wi-Fi lus sur la FortiGate du site.
    func record(wifiClients: [FortiWifiClient], siteKey: String, at date: Date) {
        record(MACHistory.observations(wifiClients: wifiClients), siteKey: siteKey, at: date)
    }

    private func record(_ observations: [MACObservation], siteKey: String, at date: Date) {
        guard !isDemo, !observations.isEmpty else { return }
        var history = history(siteKey: siteKey)
        history.record(observations, at: date)
        histories[siteKey] = history
        dirty.insert(siteKey)
        revision += 1
        scheduleSave()
    }

    // MARK: Relecture d'un appareil (note 109)

    /// Appareil en cours de relecture, ou dernière relecture et son résultat.
    @Published private(set) var isReadingDevice = false
    @Published private(set) var deviceReadAt: Date?
    @Published private(set) var deviceReadMessage: String?
    /// Note 110 : ce que la dernière relecture a vu, avec la recherche et le site qu'elle concerne.
    @Published private(set) var deviceReadResult: [MACCurrentView] = []
    private var deviceReadScope: (query: String, site: String)?

    /// Résultat de la dernière relecture, s'il concerne cette recherche sur le site actif.
    func currentDeviceRead(for query: String) -> [MACCurrentView] {
        guard let scope = deviceReadScope, scope.site == SiteModel.shared.activeKey,
              scope.query == query.trimmingCharacters(in: .whitespaces) else { return [] }
        return deviceReadResult
    }

    /// La relecture montrée porte-t-elle sur cette recherche ?
    func hasDeviceRead(for query: String) -> Bool {
        guard let scope = deviceReadScope else { return false }
        return scope.site == SiteModel.shared.activeKey && scope.query == query.trimmingCharacters(in: .whitespaces)
    }

    /// Démonstration et captures : la valeur la plus récente de chaque nature, rien n'est lu.
    func loadDemoDeviceRead(query: String) {
        guard isDemo else { return }
        let observations = activeHistory.search(query, on: nil).flatMap { match in
            MACSightingKind.allCases.compactMap { kind -> MACObservation? in
                match.sightings.filter { $0.kind == kind }.max { $0.lastSeen < $1.lastSeen }.map {
                    MACObservation(mac: $0.mac, kind: $0.kind, value: $0.value, source: $0.sources.first ?? .fortigate)
                }
            }
        }
        deviceReadResult = MACCurrentView.group(observations)
        deviceReadScope = (query.trimmingCharacters(in: .whitespaces), SiteModel.shared.activeKey)
        deviceReadAt = Date()
    }

    /// FortiGate du site actif prêtes à être lues (seul ce site : une IP ne vaut que chez lui).
    private var readyControllerIDs: [UUID] {
        let fortigate = FortiGateStore.shared
        guard fortigate.isEnabled else { return [] }
        return TrafficStore.shared.controllerIDs(forKey: SiteModel.shared.activeKey).filter { id in
            fortigate.controller(id).map { $0.isEnabled && fortigate.isReady($0) } ?? false
        }
    }

    var canReadDevice: Bool { !isDemo && !isReadingDevice && !readyControllerIDs.isEmpty }

    /// Pourquoi aucune FortiGate du site actif ne peut être lue ; nil si au moins une est prête.
    var deviceReadBlocker: String? {
        guard !isDemo else { return nil }
        let fortigate = FortiGateStore.shared
        let ids = TrafficStore.shared.controllerIDs(forKey: SiteModel.shared.activeKey)
        guard !ids.isEmpty else { return "Aucune FortiGate sur ce site\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate." }
        let enabled = ids.compactMap(fortigate.controller).filter(\.isEnabled)
        guard fortigate.isEnabled, let first = enabled.first else {
            return "La FortiGate de ce site est désactivée\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate."
        }
        if enabled.contains(where: fortigate.isReady) { return nil }
        return fortigate.notReadyReason(first) ?? "La FortiGate de ce site n’est pas prête\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate."
    }

    /// Relit cet appareil sur les FortiGate du site actif et range ce qui est vu dans son historique.
    func readDevice(_ target: FortiDeviceTarget, query: String) {
        guard canReadDevice, !target.isEmpty else { return }
        deviceReadResult = []
        deviceReadScope = (query.trimmingCharacters(in: .whitespaces), SiteModel.shared.activeKey)
        let siteKey = SiteModel.shared.activeKey
        let fortigate = FortiGateStore.shared
        let ids = readyControllerIDs
        isReadingDevice = true
        deviceReadMessage = nil
        Task { [weak self] in
            let picks = ids.map { id in
                FortiControllerSelection.Pick(controllerID: id, site: fortigate.controller(id)?.displayName ?? "FortiGate", reason: .activeSite)
            }
            let targets = await fortigate.wifiTargets(for: FortiControllerSelection(picks: picks))
            let jobs = targets.ready.map { (config: $0.0.config, token: $0.1) }
            let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { job -> Result<[MACObservation], FortiGateError> in
                let reader = FortiGateReader(transport: FortiURLSessionTransport(config: job.config, token: job.token), tokenForRedaction: job.token)
                do { return .success(try await reader.readDeviceSighting(target)) } catch let error as FortiGateError {
                    return .failure(error)
                } catch { return .failure(.cannotConnect("")) }
            }
            guard let self else { return }
            let now = Date()
            var found: [MACObservation] = []
            var failed: String?
            for result in results {
                switch result {
                case .success(let list): found += list
                case .failure(let error): failed = error.errorDescription ?? "Lecture impossible."
                }
            }
            self.record(found, siteKey: siteKey, at: now)
            self.deviceReadResult = MACCurrentView.group(found)
            self.isReadingDevice = false
            self.deviceReadAt = now
            if found.isEmpty {
                self.deviceReadMessage = failed ?? targets.blocked.values.first ?? "La FortiGate ne voit pas cet appareil pour l’instant."
            }
        }
    }

    private func prune(_ siteKey: String) {
        guard var history = histories[siteKey] else { return }
        if history.prune(retentionDays: retentionDays, now: Date()) > 0 {
            histories[siteKey] = history
            if !isDemo { dirty.insert(siteKey); scheduleSave() }
        }
    }

    // MARK: Enregistrement

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            self?.saveNow()
        }
    }

    func saveNow(synchronously: Bool = false) {
        saveTask?.cancel()
        saveTask = nil
        guard !isDemo else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jobs = dirty.compactMap { key -> (URL, Data)? in
            guard let history = histories[key], let data = try? encoder.encode(history) else { return nil }
            return (url(key), data)
        }
        dirty.removeAll()
        guard !jobs.isEmpty else { return }
        if synchronously {
            Self.write(jobs)
        } else {
            Task.detached(priority: .utility) { Self.write(jobs) }
        }
    }

    nonisolated private static func write(_ jobs: [(URL, Data)]) {
        for (url, data) in jobs {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLog.shared.error("Historique MAC", "Enregistrement impossible\u{00A0}: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Export

    /// Enregistre des observations en CSV (fenêtre d'enregistrement, BOM UTF-8 pour Excel).
    func exportCSV(_ sightings: [MACSighting], suggestedName: String) -> String? {
        let panel = NSSavePanel()
        panel.title = "Exporter l’historique des adresses MAC"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "\(suggestedName)-\(formatter.string(from: Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try (Data([0xEF, 0xBB, 0xBF]) + Data(MACHistory.csv(sightings).utf8)).write(to: url, options: .atomic)
            return "Historique exporté\u{00A0}: \(url.lastPathComponent)"
        } catch {
            return "Export impossible\u{00A0}: \(error.localizedDescription)"
        }
    }

    /// « du 2 juin au 5 nov. », « le 5 nov. » ; plusieurs périodes : les deux plus récentes
    /// (« du 1 juin au 3 juil., le 5 nov. »), précédées du nombre des plus anciennes.
    static func period(_ sighting: MACSighting) -> String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        let calendar = Calendar.current
        func label(_ period: DateInterval) -> String {
            if calendar.isDate(period.start, inSameDayAs: period.end) { return "le " + period.end.formatted(style) }
            return "du \(period.start.formatted(style)) au \(period.end.formatted(style))"
        }
        let recent = sighting.periods.suffix(2).map(label).joined(separator: ", ")
        let older = sighting.periods.count - 2
        return older > 0 ? "\(older) période\(older > 1 ? "s" : "") avant, puis \(recent)" : recent
    }
}
