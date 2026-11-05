import AppKit
import Foundation
import NetScopeCore

/// Note 29 : relecture automatique, sans relancer de scan, de la FortiGate du site actif
/// (FortiSwitch, emplacements des appareils, ARP et DHCP), de ses bornes FortiAP et de ses switchs
/// SNMP. L'intervalle se règle par site (5 min par défaut) ; seul le site actif est relu.
///
/// Le planificateur (`AutoRefreshPlanner`, NetScopeCore) décide ; ce modèle observe l'app (site
/// actif, scan, veille, réseau, lectures faites ailleurs) toutes les 5 s et lance les lectures par
/// les mêmes chemins que les boutons (« Relire la FortiGate », « Interroger les switchs ») :
/// lecture seule, une seule à la fois par FortiGate, partagée avec la Surveillance (une lecture
/// récente des bornes par une sonde repousse la relecture, et inversement).
///
/// Rien n'est lu en démonstration ni pendant les captures : l'état affiché vient de
/// `AutoRefreshDemo`.
@MainActor
final class AutoRefreshStore: ObservableObject {
    static let shared = AutoRefreshStore()

    private static let settingsKey = "NetScope.relecture.intervalles"
    /// Réévaluation sans événement : l'horloge, la veille et le réseau changent sans prévenir.
    private static let tick: TimeInterval = 5

    @Published private(set) var settings: AutoRefreshSettings
    @Published private(set) var decision: AutoRefreshDecision = .paused(.nothingToRead)
    @Published private(set) var tracks: [AutoRefreshPart: AutoRefreshTrack] = [:]
    /// Parties en cours de relecture automatique.
    @Published private(set) var reading: Set<AutoRefreshPart> = []
    /// Dernière lecture réussie connue pour le site actif (affichage), toutes origines confondues.
    @Published private(set) var lastRead: Date?

    let isDemo: Bool
    private weak var state: AppState?
    private var siteKey: String
    /// Début du suivi du site actif : une lecture plus ancienne ne déclenche pas de rafale.
    private var anchor = Date()
    private var asleep = false
    private var resumeAfter: Date?
    private var wasOnline = true
    /// Aucun switch SNMP du site n'a de communauté (constaté par une relecture) : plus d'essai
    /// jusqu'au prochain changement de site, d'hôtes ou de communauté.
    private var snmpUnusable = false
    /// Switchs à relire au moment où aucun n'avait de communauté.
    private var snmpUnusableHosts: [String] = []
    private var loop: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        siteKey = SiteFiles.noSiteKey
        settings = demo ? AutoRefreshSettings(includeSNMP: true) : AutoRefreshSettings.decode(UserDefaults.standard.data(forKey: Self.settingsKey))
        if demo { applyDemo() }
    }

    // MARK: Démarrage

    /// Lancé une fois au démarrage (hors démonstration) : suit le site actif jusqu'à la fermeture.
    func attach(to state: AppState) {
        guard !isDemo, loop == nil else { return }
        self.state = state
        siteKey = SiteModel.shared.activeKey
        anchor = Date()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AutoRefreshStore.shared.sleepChanged(asleep: true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AutoRefreshStore.shared.sleepChanged(asleep: false) }
        })
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.evaluate()
                let wake = AutoRefreshPlanner.wakeUp(after: self.decision, now: Date(), maxSleep: Self.tick)
                let seconds = max(1, wake.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    private func sleepChanged(asleep value: Bool) {
        asleep = value
        if value {
            // Une lecture en cours au moment de la veille n'aboutira pas : elle ne compte pas.
            cancelJob()
        } else {
            resumeAfter = Date().addingTimeInterval(AutoRefreshPlanner.resumeDelay)
        }
        evaluate()
    }

    // MARK: Réglage par site

    func interval(forSiteKey key: String) -> AutoRefreshInterval {
        if isDemo, !settings.isCustom(key), let interval = AutoRefreshDemo.interval(forSiteKey: key) { return interval }
        return settings.interval(forSiteKey: key)
    }

    /// Vrai si le site a son propre réglage (sinon : 5 min par défaut).
    func isCustom(_ key: String) -> Bool {
        settings.isCustom(key) || (isDemo && AutoRefreshDemo.interval(forSiteKey: key) != nil)
    }
    var activeInterval: AutoRefreshInterval { interval(forSiteKey: SiteModel.shared.activeKey) }

    func setInterval(_ interval: AutoRefreshInterval, forSiteKey key: String) {
        guard self.interval(forSiteKey: key) != interval || !settings.isCustom(key) else { return }
        settings.set(interval, forSiteKey: key)
        save()
        evaluate()
    }

    /// Relire aussi les switchs SNMP (communauté envoyée à chaque relecture) : choix explicite.
    var includeSNMP: Bool { settings.includeSNMP }

    func setIncludeSNMP(_ include: Bool) {
        guard settings.includeSNMP != include else { return }
        settings.includeSNMP = include
        save()
        evaluate()
    }

    func setActiveInterval(_ interval: AutoRefreshInterval) {
        setInterval(interval, forSiteKey: SiteModel.shared.activeKey)
    }

    private func save() {
        guard !isDemo, let data = settings.encoded() else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    /// Oublie le réglage des sites supprimés.
    private func pruneSettings() {
        let keys = Set(SiteModel.shared.sites.map { SiteFiles.key(for: $0.id) })
        var next = settings
        next.prune(keeping: keys)
        if next != settings {
            settings = next
            save()
        }
    }

    // MARK: État affiché

    /// « Relu il y a 2 min · prochaine dans 3 min » pour le site actif.
    func statusText(now: Date = Date()) -> String {
        // L'heure d'une TimelineView peut précéder l'instant présent (début de sa période).
        let now = max(now, Date())
        let busy = !reading.isEmpty || tracks.values.contains(where: \.inFlight)
        if isDemo { return AutoRefreshDemo.status(interval: activeInterval, now: now) }
        return AutoRefreshText.status(lastRead: lastRead, decision: decision, reading: busy, now: now)
    }

    /// État d'un site dans Réglages : celui du site actif, sinon « en pause » ou « désactivée ».
    func statusText(forSiteKey key: String, now: Date = Date()) -> String {
        if key == SiteModel.shared.activeKey { return statusText(now: now) }
        return interval(forSiteKey: key).isOn ? "En pause\u{00A0}: ce site n’est pas le site actif" : "Relecture automatique désactivée"
    }

    /// Vrai si la relecture du site actif est en erreur (délai croissant) ou bloquée.
    var isTroubled: Bool {
        if isDemo { return false }
        switch decision {
        case .wait(_, let retrying, _): return retrying
        case .paused(.needsAttention): return true
        default: return false
        }
    }

    /// Infobulle : ce qui est relu, et pourquoi c'est en pause.
    var helpText: String {
        let parts = AutoRefreshPart.allCases.filter { tracks[$0]?.available == true || isDemo }.map(\.label)
        let what = parts.isEmpty ? "rien pour l’instant" : parts.joined(separator: ", ")
        return "Relecture automatique du site actif, sans relancer de scan (lecture seule)\u{00A0}: \(what). En pause pendant un scan, Mac en veille ou hors réseau\u{00A0}; après une erreur, les essais s’espacent (jusqu’à 1\u{00A0}h). L’intervalle se règle par site."
    }

    // MARK: Évaluation

    private func evaluate() {
        guard !isDemo, let state else { return }
        let sites = SiteModel.shared
        let now = Date()
        if sites.activeKey != siteKey {
            // Nouveau site : un nouveau suivi, rien de l'ancien site ne s'applique ici.
            cancelJob()
            siteKey = sites.activeKey
            anchor = now
            tracks = [:]
            snmpUnusable = false
            pruneSettings()
        }
        let online = state.activeInterface != nil
        if online, !wasOnline { resumeAfter = now.addingTimeInterval(AutoRefreshPlanner.resumeDelay) }
        wasOnline = online
        let scanning = ScanController.shared.isBusy
        if scanning, job != nil {
            // Jamais de relecture pendant un scan : la fin du scan relit elle-même.
            cancelJob()
        }

        let fortigate = FortiGateStore.shared
        let wifiStore = FortiAPStore.shared
        let switchStore = SwitchStore.shared
        let ids = fortigate.autoRefreshIDs(state: state)
        let blocked = fortigate.autoRefreshBlockReason(ids)
        let fortiBusy = fortigate.isReading(ids) || fortigate.isTestingAll

        var next = tracks
        func update(_ part: AutoRefreshPart, available: Bool, blockedReason: String?, inFlight: Bool, read: Date?) {
            var track = next[part] ?? AutoRefreshTrack()
            track.available = available
            track.blockedReason = blockedReason
            track.inFlight = inFlight || reading.contains(part)
            // Lecture faite ailleurs pendant ce suivi (bouton, fin de scan, Surveillance) : la
            // suivante part de là.
            if let read, read >= anchor { track.observeRead(at: read) }
            next[part] = track
        }
        update(.fortiGate, available: !ids.isEmpty, blockedReason: blocked, inFlight: fortiBusy,
               read: fortigate.lastSuccess(ids))
        let wifiRead = wifiStore.sites.filter { ids.contains($0.controllerID) }.map(\.report.readAt).max()
        update(.wifi, available: !ids.isEmpty, blockedReason: blocked, inFlight: wifiStore.busy, read: wifiRead)
        let snmpHosts = switchStore.autoRefreshHosts()
        // Autres switchs, ou une communauté saisie depuis (Réglages, Switchs) : on réessaie.
        if snmpUnusable, snmpHosts != snmpUnusableHosts || snmpHosts.contains(where: { switchStore.hasSNMPAccess($0) }) {
            snmpUnusable = false
        }
        let snmpRead = snmpHosts.compactMap { switchStore.snapshots[$0]?.polledAt }.max()
        update(.snmp, available: settings.includeSNMP && !snmpHosts.isEmpty && !snmpUnusable, blockedReason: nil,
               inFlight: switchStore.isPolling || switchStore.isDiscovering, read: snmpRead)
        if next != tracks { tracks = next }

        let shown = [fortigate.lastSuccess(ids), wifiRead, snmpRead].compactMap { $0 }.max()
        if shown != lastRead { lastRead = shown }

        let conditions = AutoRefreshConditions(siteIsActive: true, scanning: scanning, asleep: asleep, online: online,
                                               resumeAfter: resumeAfter)
        let interval = settings.interval(forSiteKey: siteKey)
        var result = AutoRefreshPlanner.decide(now: now, interval: interval, anchor: anchor, conditions: conditions, tracks: next)
        if case .read(let parts) = result {
            if job == nil {
                run(parts, state: state, interval: interval)
            }
            result = .wait(until: now.addingTimeInterval(AutoRefreshPlanner.inFlightRetry), retrying: false, failures: 0)
        }
        if result != decision { decision = result }
    }

    // MARK: Lecture

    private func run(_ parts: Set<AutoRefreshPart>, state: AppState, interval: AutoRefreshInterval) {
        let key = siteKey
        let started = Date()
        for part in parts { tracks[part]?.begin(at: started) }
        reading = parts
        job = Task { @MainActor [weak self] in
            var outcomes: [AutoRefreshPart: Bool?] = [:]
            let fortigate = FortiGateStore.shared
            let ids = fortigate.autoRefreshIDs(state: state)
            if parts.contains(.fortiGate) {
                switch await fortigate.autoRefresh(state: state, includeWifi: parts.contains(.wifi)) {
                case .success: outcomes[.fortiGate] = true
                case .failure: outcomes[.fortiGate] = false
                case .skipped: outcomes[.fortiGate] = .some(nil)
                }
                if parts.contains(.wifi) {
                    // Les bornes sont lues à part, juste après les switchs (FortiAPStore).
                    await Self.waitForWifi()
                    outcomes[.wifi] = Self.wifiOutcome(ids: ids, since: started)
                }
            } else if parts.contains(.wifi) {
                // Bornes seules : par le même chemin que les sondes de la Surveillance (une lecture
                // récente ou en cours n'est pas doublée).
                await FortiAPStore.shared.refreshForMonitoring(maxAge: max(30, interval.seconds / 2), state: state)
                outcomes[.wifi] = Self.wifiOutcome(ids: ids, since: started)
            }
            if parts.contains(.snmp), !Task.isCancelled {
                switch await SwitchStore.shared.autoPoll(state: state) {
                case .success: outcomes[.snmp] = true
                case .failure: outcomes[.snmp] = false
                case .skipped: outcomes[.snmp] = .some(nil)
                case .nothing:
                    outcomes[.snmp] = .some(nil)
                    self?.snmpUnusable = true
                    self?.snmpUnusableHosts = SwitchStore.shared.autoRefreshHosts()
                }
            }
            guard let self, self.siteKey == key, !Task.isCancelled else { return }
            let end = Date()
            for (part, outcome) in outcomes {
                switch outcome {
                case true?: self.tracks[part]?.succeed(at: end)
                case false?: self.tracks[part]?.fail(at: end)
                default: self.tracks[part]?.cancel()
                }
            }
            self.reading = []
            self.job = nil
            self.evaluate()
        }
    }

    private func cancelJob() {
        job?.cancel()
        job = nil
        for part in reading { tracks[part]?.cancel() }
        reading = []
    }

    /// Attend la fin de la lecture des bornes lancée par la FortiGate (60 s au plus).
    private static func waitForWifi() async {
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled || !FortiAPStore.shared.busy { return }
        }
    }

    /// true : au moins une borne lue depuis `since` ; false : lue, mais en erreur ; nil : pas lue.
    private static func wifiOutcome(ids: [UUID], since: Date) -> Bool? {
        let store = FortiAPStore.shared
        guard let last = store.lastRefresh, last >= since else { return nil }
        if store.sites.contains(where: { ids.contains($0.controllerID) && $0.report.readAt >= since }) { return true }
        return ids.contains { store.errors[$0] != nil } ? false : nil
    }

    // MARK: Démonstration

    /// Démonstration : les trois parties sont « relisibles » ; les intervalles viennent
    /// d'`AutoRefreshDemo` (par nom de site).
    private func applyDemo() {
        var all: [AutoRefreshPart: AutoRefreshTrack] = [:]
        for part in AutoRefreshPart.allCases { all[part] = AutoRefreshTrack() }
        tracks = all
    }
}
