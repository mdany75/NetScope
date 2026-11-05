import AppKit
import Foundation
import NetScopeCore
import UniformTypeIdentifiers

/// Note 78 : relevé Wi-Fi par pièce, un par site (sites/<site>/wifi-releve.json). Chaque mesure est
/// lancée par l'utilisateur (« Mesurer ici ») : signal, bruit, borne et débit du lien lus localement
/// (CoreWLAN, par WifiStore), latence par un ping de la passerelle pendant 3 s et, s'il le demande,
/// débit réel par un court téléchargement (Cloudflare, environ 6 s).
///
/// Rien n'est envoyé ni écrit en démonstration ni pendant les captures (WifiSurveyDemo).
@MainActor
final class WifiSurveyStore: ObservableObject {
    static let shared = WifiSurveyStore()

    private static let throughputKey = "NetScope.wifi.releve.debit"
    /// Durée du ping de la passerelle.
    static let pingSeconds: TimeInterval = 3

    @Published private(set) var survey = WifiRoomSurvey()
    /// Site du relevé affiché (clé `SiteFiles.key`).
    @Published private(set) var siteKey: String?
    /// Étape de la mesure en cours (« Latence de la passerelle… »), nil : aucune.
    @Published private(set) var phase: String?
    /// Dernière remarque (mesure faite, erreur d'écriture).
    @Published var message: String?
    /// Mesurer aussi le débit réel (téléchargement) à chaque point.
    @Published var measureThroughput: Bool {
        didSet { if !isDemo { UserDefaults.standard.set(measureThroughput, forKey: Self.throughputKey) } }
    }

    let isDemo: Bool
    private var readOnly = Set<String>()
    private var task: Task<Void, Never>?
    private var write: Task<Void, Never>?

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        measureThroughput = demo ? true : (UserDefaults.standard.object(forKey: Self.throughputKey) as? Bool ?? true)
        if demo {
            survey = WifiSurveyDemo.survey(now: Date())
            siteKey = SiteModel.shared.activeKey
        }
    }

    var isMeasuring: Bool { phase != nil }

    // MARK: Site

    /// Relevé du site actif (relu à chaque changement de site).
    func load(siteKey key: String) {
        guard key != siteKey else { return }
        cancel()
        siteKey = key
        guard !isDemo else { return }
        survey = WifiRoomSurvey()
        guard let files = SiteModel.shared.files else { return }
        let url = WifiRoomSurvey.url(in: files, siteKey: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let data = try? Data(contentsOf: url), let saved = WifiRoomSurvey.decode(data) {
            survey = saved
        } else {
            // Fichier illisible ou d'une version future : jamais écrasé.
            readOnly.insert(key)
            message = "Relevé de ce site illisible (version plus récente de NetScope\u{00A0}?)\u{00A0}: les nouvelles mesures ne seront pas enregistrées."
        }
    }

    private func save() {
        guard !isDemo, !RegEnvironment.isSnapshot, let key = siteKey, !readOnly.contains(key),
              let files = SiteModel.shared.files, let data = survey.encoded() else { return }
        let url = WifiRoomSurvey.url(in: files, siteKey: key)
        let previous = write
        write = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Mesure

    /// Mesure du point (pièce nommée par l'utilisateur), sur sa demande seulement.
    func measure(room: String, wifi: WifiStore, state: AppState) {
        guard !isMeasuring else { return }
        let name = WifiRoomSurvey.roomName(room, index: survey.rooms.count + 1)
        if !isDemo { wifi.refresh() }
        guard let connection = wifi.connection, let network = connection.network else {
            message = "Mesure impossible\u{00A0}: ce Mac n’est connecté à aucun réseau Wi-Fi."
            return
        }
        let base = WifiRoomMeasure(room: name, time: Date(), ssid: network.ssid, bssid: network.bssid?.formatted(.upperColon),
                                   band: network.band, channel: network.channel, rssi: network.rssi, noise: network.noise,
                                   linkRateMbps: connection.transmitRate)
        let gateway = state.activeInterface?.gateway
        let withThroughput = measureThroughput
        message = nil
        phase = "Latence de la passerelle…"
        task = Task { [weak self] in
            guard let self else { return }
            var measure = base
            if self.isDemo {
                try? await Task.sleep(nanoseconds: 700_000_000)
                measure = WifiSurveyDemo.complete(base, throughput: withThroughput)
            } else {
                await self.measureLatency(&measure, gateway: gateway)
                if withThroughput, !Task.isCancelled {
                    self.phase = "Débit (téléchargement)…"
                    await self.measureDownload(&measure)
                }
            }
            guard !Task.isCancelled else { return }
            self.survey.add(measure)
            self.phase = nil
            self.task = nil
            self.message = "«\u{00A0}\(measure.room)\u{00A0}» mesurée\u{00A0}: \(WifiQuality.dbm(measure.rssi))"
                + (measure.latencyMs.map { ", \(WifiRoomSurvey.number($0))\u{00A0}ms" } ?? "")
                + (measure.downloadMbps.map { ", \(WifiRoomSurvey.number($0))\u{00A0}Mb/s" } ?? "") + "."
            self.save()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = nil
    }

    private func measureLatency(_ measure: inout WifiRoomMeasure, gateway: IPv4Address?) async {
        guard let gateway else {
            measure.note = "latence non mesurée\u{00A0}: aucune passerelle"
            return
        }
        let samples = await Self.ping(gateway, seconds: Self.pingSeconds)
        guard !samples.isEmpty else {
            measure.note = "latence non mesurée\u{00A0}: ping impossible"
            return
        }
        let stats = PingStatistics(values: samples)
        measure.latencyMs = stats.average
        measure.jitterMs = stats.jitter
        measure.lossPercent = stats.lossPercent
        measure.latencyTarget = "passerelle \(gateway)"
    }

    /// Court téléchargement (Cloudflare) : débit en réception seulement, arrêté dès qu'il est mesuré.
    private func measureDownload(_ measure: inout WifiRoomMeasure) async {
        let tester = SpeedTester(config: SpeedTestConfig(streams: 4, downloadDuration: 5, uploadDuration: 1, latencyProbes: 2))
        let reader = Task { () -> (mbps: Double?, failure: String?) in
            for await event in tester.run() {
                switch event {
                case .downloadMeasured(let mbps): return (mbps, nil)
                case .failed(let reason): return (nil, reason)
                default: continue
                }
            }
            return (nil, nil)
        }
        // 20 s au plus (serveur lent ou injoignable).
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            reader.cancel()
        }
        let result = await reader.value
        watchdog.cancel()
        if let mbps = result.mbps {
            measure.downloadMbps = mbps
        } else {
            let reason = result.failure ?? "délai dépassé"
            measure.note = [measure.note, "débit non mesuré\u{00A0}: \(reason)"].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Ping de `seconds` secondes (une demande toutes les 0,5 s) : temps de réponse, nil pour une perte.
    nonisolated private static func ping(_ address: IPv4Address, seconds: TimeInterval) async -> [Double?] {
        let box = WifiSurveyPingBox()
        let monitor = PingMonitor(address: address, options: PingOptions(interval: 0.5, timeout: 1)) { sample in box.append(sample.rttMs) }
        do {
            try monitor.start()
        } catch {
            return []
        }
        try? await Task.sleep(nanoseconds: UInt64((seconds + 1.1) * 1_000_000_000))
        monitor.stop()
        return box.values
    }

    // MARK: Modification et export

    func remove(_ ids: Set<UUID>) {
        survey.remove(ids)
        save()
    }

    func exportCSV(siteName: String) {
        guard !survey.isEmpty else { return }
        let panel = NSSavePanel()
        let slug = siteName.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        panel.nameFieldStringValue = "releve-wifi-\(slug.isEmpty ? "site" : slug).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try survey.csv(site: siteName).write(to: url, atomically: true, encoding: .utf8)
            message = "Relevé exporté\u{00A0}: \(url.lastPathComponent) (\(survey.measures.count) mesure\(survey.measures.count > 1 ? "s" : ""))."
        } catch {
            message = "Export impossible\u{00A0}: \(error.localizedDescription)"
        }
    }
}

/// Temps de réponse reçus sur la file du moniteur de ping.
private final class WifiSurveyPingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double?] = []

    func append(_ value: Double?) {
        lock.lock()
        list.append(value)
        lock.unlock()
    }

    var values: [Double?] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}
