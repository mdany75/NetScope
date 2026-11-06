import Foundation
import NetScopeCore

/// Datagrammes Syslog reçus entre deux passages (fil du récepteur → acteur).
final class AgentInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var datagrams: [LogDatagram] = []

    func add(_ datagram: LogDatagram) {
        lock.lock()
        defer { lock.unlock() }
        if datagrams.count < 20_000 { datagrams.append(datagram) }
    }

    func take() -> [LogDatagram] {
        lock.lock()
        defer { lock.unlock() }
        let taken = datagrams
        datagrams = []
        return taken
    }
}

/// Cœur de l'agent : un passage toutes les 5 secondes. L'app ouverte → l'agent attend sans rien
/// écrire ; l'app fermée → sondes, Syslog et scans planifiés, chaque écriture sous le verrou partagé.
actor AgentService {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let tick: UInt64 = 5_000_000_000

    let files: AutomationFiles
    let siteFiles: SiteFiles
    /// Réglages de l'app (alertes, Syslog, profils de scan) : mêmes préférences, en lecture seule.
    let defaults = UserDefaults(suiteName: AutomationFiles.appBundleID)
    let startedAt = Date()
    let calendar = ScanScheduler.calendar()

    private var mode: AgentMode = .standby
    private var journal: AgentJournal
    private var journalDirty = false

    private var archive: MonArchive?
    private var monitorDirty = false
    private var nextRun: [UUID: Date] = [:]
    private var running: Set<UUID> = []
    private var pinger: ICMPPinger?
    private var pingerFailed = false

    private var logs: LogJournal?
    private var logsDirty = false
    private var listener: LogUDPListener?
    private var syslogPort: UInt16?
    private var syslogError: String?
    private let inbox = AgentInbox()

    private var scanTask: Task<Void, Never>?
    private var scanning: String?
    private var alerts = AgentAlerts()

    init(files: AutomationFiles) {
        self.files = files
        siteFiles = SiteFiles(base: files.base)
        journal = AgentJournal.load(files)
    }

    // MARK: Boucle

    func run() async {
        note("Agent démarré (version \(Self.version)).")
        while !Task.isCancelled {
            await pass()
            try? await Task.sleep(nanoseconds: Self.tick)
        }
    }

    /// Arrêt (SIGTERM) : ce qui reste est écrit si l'app est fermée, puis l'état est noté.
    func stop() {
        if mode == .active { saveShared() }
        stopSyslog()
        scanTask?.cancel()
        note("Agent arrêté.")
        saveJournal(force: true)
        writeStatus(heartbeat: Date.distantPast)
    }

    private func pass() async {
        let now = Date()
        let settings = AgentSettings.load(files)
        if appIsOpen(now) {
            if mode == .active { handOver() }
        } else {
            if mode == .standby { takeOver(settings, now: now) }
            work(settings, now: now)
            saveShared()
        }
        saveJournal()
        writeStatus(heartbeat: now)
    }

    private func appIsOpen(_ now: Date) -> Bool {
        AppPresence.isActive(AppPresence.load(files), now: now)
    }

    /// Écriture partagée avec l'app : sous le verrou, et seulement si l'app est toujours fermée.
    /// Faux si l'app vient de s'ouvrir (elle reprend la main) ou si le verrou est pris trop longtemps.
    @discardableResult
    private func locked(_ body: () -> Void) -> Bool {
        let done = AutomationLock.with(files.lockURL, timeout: 4) { () -> Bool in
            guard !AppPresence.isActive(AppPresence.load(files), now: Date()) else { return false }
            body()
            return true
        }
        return done ?? false
    }

    // MARK: Relais

    private func takeOver(_ settings: AgentSettings, now: Date) {
        mode = .active
        if settings.monitor, let data = try? Data(contentsOf: files.monitorURL), let loaded = try? MonArchive.decode(data) {
            archive = loaded
            let supported = loaded.probes.filter(MonBackground.supports)
            for (index, probe) in supported.enumerated() { nextRun[probe.id] = now.addingTimeInterval(2 + Double(index)) }
        } else {
            archive = nil
        }
        if settings.syslog { startSyslog() }
        let probes = archive?.probes.filter(MonBackground.supports).count ?? 0
        var parts = ["\(probes) sonde\(probes > 1 ? "s" : "")"]
        if let syslogPort { parts.append("Syslog sur le port \(syslogPort)") }
        if settings.scans { parts.append("scans planifiés") }
        note("NetScope est fermé\u{00A0}: l’agent prend le relais (" + parts.joined(separator: ", ") + ").")
    }

    /// L'app s'est ouverte : l'agent rend la main sans rien écrire de plus.
    private func handOver() {
        mode = .standby
        stopSyslog()
        archive = nil
        nextRun = [:]
        logs = nil
        monitorDirty = false
        logsDirty = false
        if scanTask != nil {
            scanTask?.cancel()
            note("NetScope s’est ouvert pendant un scan planifié\u{00A0}: scan abandonné, l’app le relancera.", level: .warning)
        }
        note("NetScope est ouvert\u{00A0}: l’agent attend.")
    }

    // MARK: Travail

    private func work(_ settings: AgentSettings, now: Date) {
        if settings.monitor { runProbes(now) }
        if settings.syslog { drainSyslog(now) } else if listener != nil { stopSyslog() }
        if settings.scans { runSchedules(now) }
    }

    private func runProbes(_ now: Date) {
        guard let archive else { return }
        for probe in archive.probes where MonBackground.supports(probe) && !running.contains(probe.id) {
            if let due = nextRun[probe.id], due > now { continue }
            nextRun[probe.id] = now.addingTimeInterval(TimeInterval(max(probe.interval, 10)))
            if probe.kind == .ping, pinger == nil, !pingerFailed {
                do { pinger = try ICMPPinger() } catch { pingerFailed = true }
            }
            running.insert(probe.id)
            let context = MonRunContext(pinger: pinger, snmpCommunity: nil, devices: [], now: now)
            Task {
                let outcome = await MonRunner.run(probe, context: context)
                self.finishProbe(probe, outcome: outcome)
            }
        }
    }

    private func finishProbe(_ probe: MonProbe, outcome: MonRunOutcome) {
        running.remove(probe.id)
        guard mode == .active, var current = archive,
              let live = current.probes.first(where: { $0.id == probe.id }),
              live.kind == probe.kind, live.target == probe.target else { return }
        let list = siteFiles.loadList()
        let site = MonSiteResolver.site(for: live, sites: list?.sites ?? [], active: list?.activeID)
        let applied = MonBackground.apply(outcome, probe: probe.id, archive: &current, site: site)
        archive = current
        monitorDirty = true
        let updated = current.probes.first { $0.id == probe.id } ?? live
        for alert in applied.alerts {
            note("Sonde «\u{00A0}\(updated.name)\u{00A0}»\u{00A0}: \(alert.message)", level: alert.severity == .critical ? .error : .warning)
            if let event = AlertEvent.probe(alert, probe: updated) { alerts.submit(event, defaults: defaults) }
        }
        if applied.recovered {
            note("Sonde «\u{00A0}\(updated.name)\u{00A0}»\u{00A0}: retour à la normale (\(outcome.result.value)).")
            alerts.submit(.probeRecovery(probe: updated, value: outcome.result.value, at: outcome.result.date), defaults: defaults)
        }
    }

    // MARK: Syslog

    private func startSyslog() {
        guard listener == nil else { return }
        let enabled = defaults?.object(forKey: "journaux.syslog") as? Bool ?? true
        guard enabled else { return }
        let port = UInt16(clamping: defaults?.object(forKey: "journaux.port.syslog") as? Int ?? 5514)
        if logs == nil {
            if let data = try? Data(contentsOf: files.logsURL) {
                logs = try? JSONDecoder().decode(LogJournal.self, from: data)
            }
            // Journal illisible : on ne le remplace pas (l'app le mettra de côté elle-même).
            if logs == nil, FileManager.default.fileExists(atPath: files.logsURL.path) {
                syslogError = "journal des messages illisible, rien n’est reçu"
                return
            }
            if logs == nil { logs = LogJournal() }
        }
        let inbox = self.inbox
        let receiver = LogUDPListener(port: port, name: "Syslog (agent)", handler: { datagram in inbox.add(datagram) })
        do {
            try receiver.start()
            listener = receiver
            syslogPort = port
            syslogError = nil
        } catch {
            syslogError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            note("Syslog\u{00A0}: écoute impossible sur le port \(port) (\(syslogError ?? "erreur")).", level: .warning)
        }
    }

    private func stopSyslog() {
        listener?.stop()
        listener = nil
        syslogPort = nil
        _ = inbox.take()
    }

    private func drainSyslog(_ now: Date) {
        if listener == nil, syslogError == nil { startSyslog() }
        let datagrams = inbox.take()
        guard !datagrams.isEmpty, var current = logs else { return }
        let list = siteFiles.loadList()
        let siteKey = SiteFiles.key(for: list?.activeID)
        let siteName = list?.active?.displayName ?? "Plages libres"
        var messages: [LogMessage] = []
        for datagram in datagrams {
            if case .message(let message, _) = LogDecoder.syslog(datagram) {
                messages.append(message.attached(siteKey: siteKey, siteName: siteName))
            }
        }
        let retention = defaults?.data(forKey: "journaux.conservation").flatMap { try? JSONDecoder().decode(LogRetention.self, from: $0) } ?? .standard
        if current.append(messages, retention: retention, now: now) > 0 {
            logs = current
            logsDirty = true
        }
    }

    // MARK: Scans planifiés

    private func runSchedules(_ now: Date) {
        guard scanTask == nil else { return }
        let book = ScanScheduleBook.load(from: files.base)
        guard let first = ScanScheduler.pending(book.schedules, now: now, calendar: calendar).first,
              let schedule = book.schedules.first(where: { $0.id == first.id }) else { return }
        let list = siteFiles.loadList()
        let site = list?.sites.first { SiteFiles.key(for: $0.id) == schedule.siteKey }
        let siteName = site?.displayName ?? "Site supprimé"
        switch first.decision {
        case .idle:
            return
        case .missed(let slot):
            let entry = ScanRunEntry(date: now, slot: slot, scheduleID: schedule.id, siteKey: schedule.siteKey, siteName: siteName,
                                     host: .agent, outcome: .missed, message: "Échéance manquée (Mac éteint ou en veille).")
            finishSchedule(schedule.id, slot: slot, entry: entry)
        case .run(let slot, let catchUp):
            guard let site else {
                let entry = ScanRunEntry(date: now, slot: slot, scheduleID: schedule.id, siteKey: schedule.siteKey, siteName: siteName,
                                         host: .agent, outcome: .failed, message: "Site introuvable.")
                finishSchedule(schedule.id, slot: slot, entry: entry)
                return
            }
            if pinger == nil, !pingerFailed {
                do { pinger = try ICMPPinger() } catch { pingerFailed = true }
            }
            let methods = ScanProfileMethods.decode(defaults?.data(forKey: "reglages.scan.methodes")).methods(for: schedule.profile)
            let ports = Self.customPorts(defaults?.string(forKey: "reglages.scan.ports"))
            let request = SiteScanRequest(site: site, profile: schedule.profile, methods: methods, customPorts: ports)
            let pinger = self.pinger
            scanning = siteName
            note("Scan planifié de «\u{00A0}\(siteName)\u{00A0}» (\(schedule.profile.label))" + (catchUp ? ", rattrapé après la veille." : "."))
            let id = schedule.id
            let key = schedule.siteKey
            scanTask = Task {
                let capture = await SiteScanRunner.scan(request, pinger: pinger)
                self.commitScan(capture, id: id, slot: slot, key: key, siteName: siteName, siteID: site.id, catchUp: catchUp)
            }
        }
    }

    private func commitScan(_ capture: SiteScanCapture, id: UUID, slot: Date, key: String, siteName: String, siteID: UUID, catchUp: Bool) {
        scanTask = nil
        scanning = nil
        guard mode == .active, !capture.cancelled else { return }
        var report: SiteScanReport?
        let written = locked {
            let result = SiteScanRunner.commit(capture, files: siteFiles)
            if result.outcome != .failed { SiteScanRunner.noteLastScan(result.finishedAt, siteID: siteID, files: siteFiles) }
            var book = ScanScheduleBook.load(from: files.base)
            let entry = ScanRunEntry(date: result.finishedAt, slot: slot, scheduleID: id, siteKey: key, siteName: siteName, host: .agent,
                                     outcome: result.outcome, online: result.online, newCount: result.newDevices.count,
                                     duration: result.duration, message: (catchUp ? "Rattrapé après la veille. " : "") + result.message)
            book.finish(id, slot: slot, entry: entry)
            try? book.save(to: files.base)
            report = result
        }
        guard written, let report else {
            note("Scan de «\u{00A0}\(siteName)\u{00A0}» non enregistré\u{00A0}: NetScope s’est ouvert.", level: .warning)
            return
        }
        note("Scan de «\u{00A0}\(siteName)\u{00A0}»\u{00A0}: \(report.message)", level: report.outcome == .ok ? .info : .warning)
        if let event = AlertEvent.newDevices(report.newDevices, at: report.finishedAt) {
            alerts.submit(event, defaults: defaults)
        }
    }

    private func finishSchedule(_ id: UUID, slot: Date, entry: ScanRunEntry) {
        locked {
            var book = ScanScheduleBook.load(from: files.base)
            book.finish(id, slot: slot, entry: entry)
            try? book.save(to: files.base)
        }
        note("Scan planifié de «\u{00A0}\(entry.siteName)\u{00A0}»\u{00A0}: \(entry.message)", level: .warning)
    }

    static func customPorts(_ text: String?) -> [UInt16] {
        guard let text else { return [] }
        let tokens = ScanProfile.migratedCustomPorts(text).split { $0 == "," || $0 == " " || $0 == ";" }.map(String.init)
        return Array(Set(tokens.compactMap { ScanProfile.parsePorts($0) }.flatMap { $0 })).sorted()
    }

    // MARK: Écritures

    private func saveShared() {
        guard monitorDirty || logsDirty else { return }
        let archive = self.archive
        let logs = self.logs
        let monitor = monitorDirty
        let logsChanged = logsDirty
        let written = locked {
            if monitor, let archive, let data = try? archive.encoded() { try? data.write(to: files.monitorURL, options: .atomic) }
            if logsChanged, let logs, let data = try? JSONEncoder().encode(logs) { try? data.write(to: files.logsURL, options: .atomic) }
        }
        if written {
            monitorDirty = false
            logsDirty = false
        }
    }

    private func note(_ text: String, level: AgentJournalEntry.Level = .info) {
        journal.add(AgentJournalEntry(date: Date(), level: level, text: text))
        journalDirty = true
    }

    private func saveJournal(force: Bool = false) {
        guard journalDirty || force else { return }
        journal.save(files)
        journalDirty = false
    }

    private func writeStatus(heartbeat: Date) {
        let book = ScanScheduleBook.load(from: files.base)
        let next = ScanScheduler.nextRun(book.schedules, after: Date(), calendar: calendar)?.date
        AgentStatus(pid: getpid(), version: Self.version, startedAt: startedAt, heartbeat: heartbeat, mode: mode,
                    probes: archive?.probes.filter(MonBackground.supports).count ?? 0, syslogPort: syslogPort,
                    syslogError: syslogError, nextScan: next, scanning: scanning).save(files)
    }
}
