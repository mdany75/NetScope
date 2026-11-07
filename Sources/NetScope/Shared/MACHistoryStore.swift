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

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot, files: SiteFiles = .standard) {
        isDemo = demo
        self.files = files
        let stored = demo ? 0 : UserDefaults.standard.integer(forKey: Self.retentionKey)
        retentionDays = stored > 0 ? stored : MACHistory.defaultRetentionDays
        if demo {
            histories[SiteModel.shared.activeKey] = MACHistoryDemo.history()
        } else {
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MACHistoryStore.shared.saveNow() }
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

    /// Relevé d'un switch (SNMP, ou FortiSwitch lu par la FortiGate).
    func record(snapshot: SNMPSwitchSnapshot, siteKey: String, source: MACSightingSource = .switchTable) {
        record(MACHistory.observations(snapshots: [snapshot], source: source), siteKey: siteKey, at: snapshot.polledAt)
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

    func saveNow() {
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
        Task.detached(priority: .utility) {
            for (url, data) in jobs {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    AppLog.shared.error("Historique MAC", "Enregistrement impossible\u{00A0}: \(error.localizedDescription)")
                }
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

    /// « du 2 juin au 5 nov. », « le 5 nov. » (période d'une observation).
    static func period(_ sighting: MACSighting) -> String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        let calendar = Calendar.current
        if calendar.isDate(sighting.firstSeen, inSameDayAs: sighting.lastSeen) {
            return "le " + sighting.lastSeen.formatted(style)
        }
        return "du \(sighting.firstSeen.formatted(style)) au \(sighting.lastSeen.formatted(style))"
    }
}
