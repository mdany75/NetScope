import Foundation
import NetScopeCore

/// Note 63 : scans planifiés par site, quand l'app est ouverte (l'agent de la note 64 s'en charge
/// quand elle est fermée). Toutes les 30 secondes : une échéance passée lance AU PLUS un scan, jamais
/// pendant un autre scan. Le site actif passe par le Scanner (résultats, inventaire, alertes et
/// switchs comme un scan manuel, sans question) ; un autre site est scanné sans interface dans ses
/// fichiers (SiteScanRunner). Enregistré dans scans-planifies.json, avec le journal des exécutions.
/// En démonstration : données fictives, rien ne s'exécute ni ne s'écrit.
@MainActor
final class ScanScheduleStore: ObservableObject {
    static let shared = ScanScheduleStore()

    @Published private(set) var book: ScanScheduleBook
    /// Scan planifié en cours de modification (nouveau compris) ; nil : aucun éditeur ouvert.
    @Published var draft: ScanSchedule?
    /// Scan planifié en cours et son site.
    @Published private(set) var runningID: UUID?
    @Published private(set) var runningSiteName: String?

    let isDemo: Bool
    let demoNow: Date?
    let calendar = ScanScheduler.calendar()
    private let files = AutomationFiles.standard
    private var timer: Timer?
    private weak var state: AppState?
    /// Modification gardée en mémoire faute de verrou (agent occupé) : réécrite au passage suivant.
    private var pendingSave = false

    private init(demo: Bool = RegEnvironment.isSandboxed) {
        isDemo = demo
        if demo {
            demoNow = AutomationDemo.now
            book = AutomationDemo.book
            // Captures : NETSCOPE_SCAN_PLANIF=edition ouvre l'éditeur du premier scan planifié.
            if ProcessInfo.processInfo.environment["NETSCOPE_SCAN_PLANIF"] == "edition" { draft = book.schedules.first }
        } else {
            demoNow = nil
            book = ScanScheduleBook.load(from: AutomationFiles.standard.base)
        }
    }

    var now: Date { demoNow ?? Date() }
    var schedules: [ScanSchedule] { book.schedules }

    // MARK: Lancement

    /// Premier passage 30 secondes après le lancement (site actif et interface prêts), puis toutes les 30 s.
    func attach(to state: AppState) {
        self.state = state
        guard !isDemo, timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in ScanScheduleStore.shared.tick() }
        }
        timer.fireDate = Date().addingTimeInterval(30)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !isDemo, let state else { return }
        if pendingSave { retrySave() }
        // L'agent a pu écrire pendant que l'app était fermée : relu avant chaque décision.
        reload()
        guard ScanScheduler.canStart(scanRunning: ScanController.shared.isRunning, scheduledRunning: runningID != nil) else { return }
        let date = Date()
        guard let first = ScanScheduler.pending(book.schedules, now: date, calendar: calendar).first,
              let schedule = book.schedules.first(where: { $0.id == first.id }) else { return }
        let siteName = SiteModel.shared.site(forKey: schedule.siteKey)?.displayName ?? "Site supprimé"
        switch first.decision {
        case .idle:
            return
        case .missed(let slot):
            finish(schedule.id, slot: slot, entry: ScanRunEntry(date: date, slot: slot, scheduleID: schedule.id, siteKey: schedule.siteKey,
                                                              siteName: siteName, host: .app, outcome: .missed,
                                                              message: "Échéance manquée (Mac éteint ou en veille)."))
        case .run(let slot, let catchUp):
            run(schedule, slot: slot, catchUp: catchUp, siteName: siteName, state: state)
        }
    }

    private func run(_ schedule: ScanSchedule, slot: Date, catchUp: Bool, siteName: String, state: AppState) {
        let site = SiteModel.shared.site(forKey: schedule.siteKey)
        guard let site else {
            finish(schedule.id, slot: slot, entry: ScanRunEntry(date: Date(), slot: slot, scheduleID: schedule.id, siteKey: schedule.siteKey,
                                                              siteName: siteName, host: .app, outcome: .failed, message: "Site introuvable."))
            return
        }
        runningID = schedule.id
        runningSiteName = siteName
        let prefix = catchUp ? "Rattrapé après la veille. " : ""
        AppLog.shared.info("Scans planifiés", "Scan planifié de «\u{00A0}\(siteName)\u{00A0}» (\(schedule.profile.label))")
        // Site actif aux plages non enregistrées : ni le Scanner (plages en cours de modification) ni
        // un scan sans interface (il écrirait les fichiers du site tenu en mémoire par l'app).
        if schedule.siteKey == SiteModel.shared.activeKey, SiteModel.shared.hasUnsavedRanges(state) {
            endRun(schedule, slot: slot, outcome: .failed, siteName: siteName,
                   message: prefix + "Plages du site actif non enregistrées\u{00A0}: scan non lancé.")
            return
        }
        // Site actif : le Scanner fait le scan (interface, switchs, alertes).
        if schedule.siteKey == SiteModel.shared.activeKey {
            let controller = ScanController.shared
            controller.start(state, unattended: true, profile: schedule.profile)
            guard controller.isRunning else {
                endRun(schedule, slot: slot, outcome: .failed, siteName: siteName, message: prefix + "Scan impossible (voir le Scanner).")
                return
            }
            let begin = Date()
            Task { @MainActor in
                while ScanController.shared.isRunning { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                let ranges = ScanController.shared.lastScanRanges
                let online = state.devices.filter { device in device.isOnline && ranges.contains { $0.contains(device.ip) } }.count
                let fresh = ScanController.shared.newIDs.count
                let duration = Date().timeIntervalSince(begin)
                let interrupted = ScanController.shared.lastScanInterrupted
                let summary = ScanScheduler.summary(online: online, new: fresh, duration: duration) + "."
                self.endRun(schedule, slot: slot, outcome: interrupted ? .partial : .ok, siteName: siteName, online: online, new: fresh,
                            duration: duration, message: prefix + (interrupted ? "Interrompu\u{00A0}: " : "") + summary)
            }
            return
        }
        // Autre site : scan sans interface dans ses fichiers (résultats, inventaire).
        let prefs = RegPrefs.shared
        let request = SiteScanRequest(site: site, profile: schedule.profile, methods: prefs.methods(for: schedule.profile),
                                      customPorts: prefs.tuning.ports)
        let pinger = ScanController.shared.sharedPinger
        let siteFiles = SiteFiles(base: files.base)
        Task { @MainActor in
            let report = await SiteScanRunner.run(request, files: siteFiles, pinger: pinger)
            if report.outcome != .failed {
                SiteModel.shared.scheduledScanFinished(key: schedule.siteKey, date: report.finishedAt)
                AlertDispatcher.shared.emit(.newDevices(report.newDevices, at: report.finishedAt))
            }
            self.endRun(schedule, slot: slot, outcome: report.outcome, siteName: siteName, online: report.online,
                        new: report.newDevices.count, duration: report.duration, message: prefix + report.message)
        }
    }

    private func endRun(_ schedule: ScanSchedule, slot: Date, outcome: ScanRunOutcome, siteName: String, online: Int = 0, new: Int = 0,
                        duration: TimeInterval = 0, message: String) {
        runningID = nil
        runningSiteName = nil
        finish(schedule.id, slot: slot, entry: ScanRunEntry(date: Date(), slot: slot, scheduleID: schedule.id, siteKey: schedule.siteKey,
                                                          siteName: siteName, host: .app, outcome: outcome, online: online,
                                                          newCount: new, duration: duration, message: message))
    }

    private func finish(_ id: UUID, slot: Date, entry: ScanRunEntry) {
        mutate { $0.finish(id, slot: slot, entry: entry) }
        AppLog.shared.info("Scans planifiés", "«\u{00A0}\(entry.siteName)\u{00A0}»\u{00A0}: \(entry.outcome.label), \(entry.message)")
    }

    // MARK: Modifications

    /// Modifie le fichier sous le verrou partagé avec l'agent (relu juste avant, écrit juste après).
    private func mutate(_ body: (inout ScanScheduleBook) -> Void) {
        guard !isDemo else {
            body(&book)
            return
        }
        let directory = files.base
        // Fil principal : 2 s au plus (l'agent ne garde le verrou que le temps d'écrire ses fichiers).
        let result = AutomationLock.with(files.lockURL, timeout: 2) { () -> ScanScheduleBook in
            var fresh = ScanScheduleBook.load(from: directory)
            body(&fresh)
            do {
                try fresh.save(to: directory)
            } catch {
                AppLog.shared.error("Scans planifiés", "Enregistrement impossible\u{00A0}: \(error.localizedDescription)")
            }
            return fresh
        }
        if let result {
            book = result
            pendingSave = false
        } else {
            body(&book)
            pendingSave = true
            AppLog.shared.warning("Scans planifiés", "Verrou partagé occupé\u{00A0}: modification enregistrée au prochain passage.")
        }
    }

    private func retrySave() {
        let directory = files.base, current = book
        let saved = AutomationLock.with(files.lockURL, timeout: 2) { () -> Bool in
            (try? current.save(to: directory)) != nil
        }
        if saved == true { pendingSave = false }
    }

    func reload() {
        guard !isDemo, !pendingSave else { return }
        let fresh = ScanScheduleBook.load(from: files.base)
        if fresh != book { book = fresh }
    }

    func newDraft() {
        let key = SiteModel.shared.activeID.map { SiteFiles.key(for: $0) } ?? SiteModel.shared.sites.first.map { SiteFiles.key(for: $0.id) }
        draft = ScanSchedule(siteKey: key ?? SiteFiles.noSiteKey, profile: RegPrefs.shared.defaultProfile, activeSince: now)
    }

    /// Enregistre le brouillon : une modification ne rattrape aucune échéance passée.
    func saveDraft() {
        guard var schedule = draft else { return }
        schedule.activeSince = now
        mutate { book in
            if let index = book.schedules.firstIndex(where: { $0.id == schedule.id }) {
                book.schedules[index] = schedule
            } else {
                book.schedules.append(schedule)
            }
        }
        draft = nil
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        let date = now
        mutate { book in
            guard let index = book.schedules.firstIndex(where: { $0.id == id }) else { return }
            book.schedules[index].isEnabled = enabled
            if enabled { book.schedules[index].activeSince = date }
        }
    }

    func remove(_ id: UUID) {
        mutate { $0.schedules.removeAll { $0.id == id } }
    }

    func clearRuns() {
        mutate { $0.runs = [] }
    }

    // MARK: Textes

    func siteName(_ key: String) -> String {
        SiteModel.shared.site(forKey: key)?.displayName ?? (key == SiteFiles.noSiteKey ? "Plages libres" : "Site supprimé")
    }

    func nextLabel(_ schedule: ScanSchedule) -> String {
        guard schedule.isEnabled else { return "En pause" }
        guard let next = ScanScheduler.nextSlot(after: now, schedule, calendar: calendar) else { return "—" }
        return ScanScheduler.dateLabel(next, now: now, calendar: calendar)
    }
}
