import AppKit
import Foundation
import NetScopeCore

/// Historique du trafic des ports des switchs (note 74), un fichier par site :
/// `sites/<clé>/trafic-ports.json` dans Application Support/NetScope.
///
/// Alimenté par chaque relevé d'un switch : interrogation SNMP (manuelle, fin de scan, relecture
/// automatique), lecture des FortiSwitch par la FortiGate, et panneau « Trafic du port » ouvert.
/// Lu par Switchs et ports (graphe du port, ports les plus chargés) et par l'écran Trafic (secours
/// quand FortiView n'est pas lu, erreurs par heure de l'analyse complète).
///
/// L'enregistrement est différé (deux minutes au plus après un relevé, et à la fermeture de
/// l'app), écrit hors du fil principal. En démonstration et pendant les captures, rien n'est lu ni
/// écrit : l'historique vient de PortHistoryDemo (courbes jour et nuit).
@MainActor
final class PortHistoryStore: ObservableObject {
    static let shared = PortHistoryStore()

    /// Change à chaque nouveau relevé enregistré (les vues se redessinent).
    @Published private(set) var revision = 0

    let isDemo: Bool
    private let files: SiteFiles
    private var histories: [String: PortTrafficHistory] = [:]
    private var dirty: Set<String> = []
    private var saveTask: Task<Void, Never>?
    private var demoHistory: PortTrafficHistory?
    private static let saveDelay: UInt64 = 120_000_000_000

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot, files: SiteFiles = .standard) {
        isDemo = demo
        self.files = files
        if !demo {
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PortHistoryStore.shared.saveNow() }
            }
        }
    }

    // MARK: Lecture

    /// Historique d'un site (lu sur le disque au premier besoin).
    func history(siteKey: String) -> PortTrafficHistory {
        if isDemo { return demo() }
        if let history = histories[siteKey] { return history }
        let url = PortHistoryFile.url(in: files, siteKey: siteKey)
        var history = PortTrafficHistory()
        switch PortHistoryFile.load(from: url) {
        case .loaded(let loaded):
            history = loaded
        case .unreadable:
            let aside = PortHistoryFile.setAside(url)
            AppLog.shared.warning("Historique des ports", "Fichier illisible mis de côté\u{00A0}: \(aside?.lastPathComponent ?? url.lastPathComponent)")
        case .missing:
            break
        }
        histories[siteKey] = history
        return history
    }

    /// Historique d'un switch dans son site.
    func switchHistory(host: String, siteKey: String) -> PortSwitchHistory? {
        history(siteKey: siteKey).history(host)
    }

    /// Historique d'un port.
    func series(host: String, ifIndex: Int, siteKey: String) -> PortTrafficSeries? {
        history(siteKey: siteKey).series(host, ifIndex: ifIndex)
    }

    /// Heure de référence des courbes : l'heure des captures en démonstration, sinon maintenant.
    var now: Date { isDemo ? PortHistoryDemo.now : Date() }

    /// Note 78 : erreurs par heure (historique sur 24 h, sinon suivi des 30 dernières minutes) et
    /// charge moyenne de la dernière heure de chaque port, pour l'analyse complète du réseau.
    func analysisSignals(_ snapshots: [SNMPSwitchSnapshot]) -> (errorRates: [String: [Int: PortErrorRate]], loads: [String: [Int: Double]]) {
        let switches = SwitchStore.shared
        let now = now
        var rates: [String: [Int: PortErrorRate]] = [:]
        var loads: [String: [Int: Double]] = [:]
        for snapshot in snapshots {
            let history = switchHistory(host: snapshot.id, siteKey: switches.historySiteKey(for: snapshot.id))
            var perPort = history.map { PortHistoryRanking.errorRates($0, now: now) } ?? [:]
            // Pas encore assez d'historique : le suivi en mémoire, s'il couvre au moins 5 minutes.
            for delta in switches.recentErrors(snapshot.id).ports.values where perPort[delta.ifIndex] == nil && delta.seconds >= 300 {
                perPort[delta.ifIndex] = PortErrorRate(delta)
            }
            rates[snapshot.id] = perPort
            if let history {
                var perLoad: [Int: Double] = [:]
                for series in history.ports.values {
                    let stats = series.stats(.hour, now: now)
                    if stats.covered >= 900, let percent = stats.averagePercent { perLoad[series.ifIndex] = percent }
                }
                loads[snapshot.id] = perLoad
            }
        }
        return (rates, loads)
    }

    // MARK: Relevés

    /// Relevé complet d'un switch (SNMP ou FortiGate).
    func record(_ snapshot: SNMPSwitchSnapshot, siteKey: String) {
        record(host: snapshot.id, name: snapshot.displayName, at: snapshot.polledAt,
               readings: PortCounterReading.readings(from: snapshot), siteKey: siteKey)
    }

    /// Compteurs du panneau « Trafic du port » (IF-MIB), ports physiques du switch seulement.
    func record(host: String, ports: [SNMPPortCounters], at date: Date, siteKey: String) {
        guard let snapshot = SwitchStore.shared.snapshots[host], !snapshot.isViaController else { return }
        let physical = Set(snapshot.physicalPorts.map(\.index))
        record(host: host, name: snapshot.displayName, at: date,
               readings: PortCounterReading.readings(from: ports, keep: physical), siteKey: siteKey)
    }

    private func record(host: String, name: String, at date: Date, readings: [PortCounterReading], siteKey: String) {
        guard !isDemo, !readings.isEmpty else { return }
        var history = history(siteKey: siteKey)
        history.record(host: host, name: name, at: date, readings: readings)
        histories[siteKey] = history
        dirty.insert(siteKey)
        revision &+= 1
        scheduleSave()
    }

    // MARK: Enregistrement

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDelay)
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            await self.saveDirty()
        }
    }

    /// Écrit les sites modifiés, hors du fil principal (regroupement des points anciens compris).
    private func saveDirty() async {
        let now = Date()
        let jobs = dirty.compactMap { key -> (String, PortTrafficHistory)? in
            guard var history = histories[key] else { return nil }
            history.compact(now: now)
            histories[key] = history
            return (key, history)
        }
        dirty = []
        let files = files
        let failures = await Task.detached(priority: .utility) { () -> [String] in
            var failed: [String] = []
            for (key, history) in jobs {
                do { try PortHistoryFile.save(history, to: PortHistoryFile.url(in: files, siteKey: key), now: now) }
                catch { failed.append("\(key)\u{00A0}: \(error.localizedDescription)") }
            }
            return failed
        }.value
        for failure in failures { AppLog.shared.error("Historique des ports", "Enregistrement impossible (\(failure))") }
    }

    /// Écrit tout de suite (fermeture de l'app).
    func saveNow() {
        guard !isDemo, !dirty.isEmpty else { return }
        saveTask?.cancel()
        saveTask = nil
        let now = Date()
        for key in dirty {
            guard var history = histories[key] else { continue }
            history.compact(now: now)
            try? PortHistoryFile.save(history, to: PortHistoryFile.url(in: files, siteKey: key), now: now)
        }
        dirty = []
    }

    // MARK: Démonstration

    private func demo() -> PortTrafficHistory {
        if let demoHistory { return demoHistory }
        let built = PortHistoryDemo.make(snapshots: Array(SwitchStore.shared.snapshots.values))
        demoHistory = built
        return built
    }
}
