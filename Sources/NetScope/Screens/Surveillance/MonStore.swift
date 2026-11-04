import AppKit
import Foundation
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Résultat du dernier « Tester maintenant » d'une sonde (affiché dans l'éditeur).
struct MonManualTest: Equatable {
    var date: Date
    var text: String
    var tone: Tone
}

/// Moteur de l'écran Surveillance : sondes, suivi, historique 24 h et journal des alertes.
/// Une seule instance ; elle démarre au lancement de l'app et continue fenêtre fermée.
/// Tout est enregistré dans ~/Library/Application Support/NetScope/surveillance.json.
/// Démonstration ou capture : données du croquis, aucune sonde exécutée, rien d'enregistré.
@MainActor
final class MonStore: ObservableObject {
    static let shared = MonStore()

    @Published private(set) var probes: [MonProbe] = []
    @Published private(set) var trackers: [UUID: MonTracker] = [:]
    @Published private(set) var history = MonHistory()
    @Published private(set) var journal = MonJournal()
    @Published var selectedID: UUID?
    @Published private(set) var manualTests: [UUID: MonManualTest] = [:]
    @Published private(set) var running: Set<UUID> = []
    @Published var toast: String?
    /// Début du cycle de surveillance (lancement ou reprise).
    @Published private(set) var cycleStart = Date()

    /// Démonstration ou capture : aucune sonde ne s'exécute.
    let isSimulated: Bool
    /// Date figée des captures (barres de disponibilité et horodatages stables).
    private(set) var demoNow: Date?

    private var nextRun: [UUID: Date] = [:]
    /// Sonde telle qu'elle était au lancement de la vérification en cours : un résultat qui revient
    /// après un changement de type ou de cible est écarté.
    private var launched: [UUID: MonProbe] = [:]
    private var timer: Timer?
    private weak var appState: AppState?
    private var pinger: ICMPPinger?
    private var pingerFailed = false
    private var saveScheduled = false
    private let url: URL

    private init() {
        let arguments = CommandLine.arguments
        isSimulated = arguments.contains("--demo") || arguments.contains("--snapshot")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("surveillance.json")
        if isSimulated {
            MonDemo.load(into: self)
        } else {
            load()
        }
    }

    // MARK: Démarrage

    /// Relie le moteur à l'état de l'app (badge, appareils) et lance l'ordonnanceur (hors démonstration).
    func attach(to state: AppState) {
        appState = state
        updateBadge()
        guard !isSimulated, timer == nil else { return }
        cycleStart = Date()
        let now = Date()
        for (index, probe) in probes.enumerated() where nextRun[probe.id] == nil {
            nextRun[probe.id] = now.addingTimeInterval(2 + Double(index) * 1.5)
        }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in MonStore.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        for probe in probes where probe.isEnabled && !running.contains(probe.id) {
            if let due = nextRun[probe.id], due > now { continue }
            execute(probe, manual: false)
        }
    }

    // MARK: Lecture

    var now: Date { demoNow ?? Date() }

    func probe(_ id: UUID?) -> MonProbe? {
        guard let id else { return nil }
        return probes.first { $0.id == id }
    }

    var selectedProbe: MonProbe? { probe(selectedID) ?? probes.first }

    /// État affiché : nil pour une sonde inactive.
    func state(of probe: MonProbe) -> MonState? {
        probe.isEnabled ? (trackers[probe.id]?.state ?? .pending) : nil
    }

    var activeCount: Int { probes.filter(\.isEnabled).count }
    var warningCount: Int { probes.filter { state(of: $0) == .warning }.count }
    var downCount: Int { probes.filter { state(of: $0) == .down }.count }
    var pausedCount: Int { probes.filter { !$0.isEnabled }.count }
    var hasActiveProbes: Bool { !isSimulated && activeCount > 0 }

    /// Sondes en alerte ou hors ligne (barre de menus), les pannes d'abord.
    var alertingProbes: [MonProbe] {
        probes.filter { state(of: $0) == .down } + probes.filter { state(of: $0) == .warning }
    }

    /// Dernière valeur à afficher.
    func lastValue(of probe: MonProbe) -> String {
        guard let tracker = trackers[probe.id], let result = tracker.lastResult else {
            return probe.isEnabled ? "En attente du premier test" : "—"
        }
        if tracker.state == .down, let since = tracker.since {
            return "Hors ligne depuis " + MonStore.duration(now.timeIntervalSince(since))
        }
        if !result.reachable, let error = result.error { return error.prefix(1).uppercased() + error.dropFirst() }
        return result.value
    }

    /// Prochaine vérification d'une sonde active.
    func nextCheck(of probe: MonProbe, at date: Date) -> TimeInterval? {
        guard probe.isEnabled else { return nil }
        if let due = nextRun[probe.id] { return max(0, due.timeIntervalSince(date)) }
        // Démonstration : cycle régulier depuis le début.
        let elapsed = Int(date.timeIntervalSince(cycleStart))
        return TimeInterval(probe.interval - elapsed % probe.interval)
    }

    /// Latence de la passerelle : sonde Ping qui vise la passerelle de l'interface active.
    var gatewayLatency: Double? {
        guard let gateway = appState?.activeInterface?.gateway?.description else { return nil }
        let probe = probes.first { $0.kind == .ping && $0.target.trimmingCharacters(in: .whitespaces) == gateway && $0.isEnabled }
        return probe.flatMap { trackers[$0.id]?.lastResult?.latencyMs }
    }

    var gatewayAddress: String? { appState?.activeInterface?.gateway?.description }
    var interfaceSummary: String? {
        appState?.activeInterface.map { "\($0.name) · \($0.address)" }
    }

    // MARK: Sondes

    /// Nouvelle sonde Ping, sur la passerelle si elle est connue ; renvoie son identifiant.
    @discardableResult
    func addProbe() -> UUID {
        var probe = MonProbe(name: "Nouvelle sonde", kind: .ping, target: "", interval: 60)
        if let gateway = gatewayAddress, !probes.contains(where: { $0.target == gateway }) {
            probe.name = "Ping passerelle"
            probe.target = gateway
        }
        probes.append(probe)
        trackers[probe.id] = MonTracker()
        selectedID = probe.id
        nextRun[probe.id] = Date().addingTimeInterval(2)
        toast = nil
        changed()
        return probe.id
    }

    /// Enregistre une sonde modifiée dans l'éditeur.
    func save(_ probe: MonProbe) {
        guard let index = probes.firstIndex(where: { $0.id == probe.id }) else { return }
        let old = probes[index]
        var probe = probe
        // Une sonde ne peut pas dépendre d'elle-même.
        if probe.dependsOn == probe.id { probe.dependsOn = nil }
        probes[index] = probe
        // Cible ou type changé : on repart de zéro (l'historique précédent ne veut plus rien dire).
        if old.kind != probe.kind || old.target != probe.target {
            journal.resolveOpen(probe: probe.id, reason: "sonde modifiée", date: Date())
            trackers[probe.id] = MonTracker()
            history.buckets[probe.id.uuidString] = nil
            nextRun[probe.id] = Date().addingTimeInterval(1)
        } else if old.interval != probe.interval {
            nextRun[probe.id] = Date().addingTimeInterval(TimeInterval(min(probe.interval, 5)))
        }
        toast = "Sonde «\u{00A0}\(probe.name)\u{00A0}» enregistrée."
        changed()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = probes.firstIndex(where: { $0.id == id }) else { return }
        probes[index].isEnabled = enabled
        if enabled {
            nextRun[id] = Date().addingTimeInterval(1)
        } else {
            suspend(id)
        }
        changed()
    }

    /// Sonde suspendue : ses alertes ouvertes sont closes (aucun retour à la normale ne viendra) et
    /// une panne toujours présente à la reprise créera une nouvelle alerte.
    private func suspend(_ id: UUID) {
        journal.resolveOpen(probe: id, reason: "surveillance suspendue", date: Date())
        trackers[id]?.alerted = nil
    }

    /// « Tout suspendre » / « Tout reprendre ».
    func toggleAll() {
        let enable = activeCount == 0
        for index in probes.indices { probes[index].isEnabled = enable }
        if !enable { probes.forEach { suspend($0.id) } }
        if enable {
            cycleStart = Date()
            let now = Date()
            for (index, probe) in probes.enumerated() { nextRun[probe.id] = now.addingTimeInterval(1 + Double(index)) }
        }
        changed()
    }

    func delete(_ id: UUID) {
        guard let probe = probe(id) else { return }
        probes.removeAll { $0.id == id }
        trackers[id] = nil
        nextRun[id] = nil
        manualTests[id] = nil
        history.buckets[id.uuidString] = nil
        launched[id] = nil
        journal.resolveOpen(probe: id, reason: "sonde supprimée", date: Date())
        journal.detach(probe: id)
        AlertDispatcher.shared.setExcluded(false, probe: id)
        for index in probes.indices where probes[index].dependsOn == id { probes[index].dependsOn = nil }
        selectedID = probes.first?.id
        toast = "Sonde «\u{00A0}\(probe.name)\u{00A0}» supprimée."
        changed()
    }

    /// « Tester maintenant » : une vérification immédiate (simulée en démonstration).
    func testNow(_ id: UUID) {
        guard let probe = probe(id) else { return }
        toast = nil
        if isSimulated {
            simulateTest(probe)
        } else if !running.contains(id) {
            execute(probe, manual: true)
        }
    }

    // MARK: Journal

    func acknowledge(_ id: MonAlert.ID) {
        journal.acknowledge(id, by: MonStore.userName, at: Date())
        changed()
    }

    func acknowledgeAll() {
        journal.acknowledgeAll(by: MonStore.userName, at: Date())
        changed()
    }

    /// « Exporter le journal » : CSV choisi par l'utilisateur.
    func exportJournal() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "alertes-\(day).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try Data(journal.csv().utf8).write(to: target, options: .atomic)
            toast = "Journal exporté\u{00A0}: \(target.lastPathComponent) (\(journal.alerts.count) entrées)"
        } catch {
            toast = "Export impossible\u{00A0}: \(error.localizedDescription)"
        }
    }

    /// Prénom affiché dans « Accusé par Dany · 11:49 ».
    static var userName: String {
        let full = NSFullUserName()
        return full.split(separator: " ").first.map(String.init) ?? (full.isEmpty ? NSUserName() : full)
    }

    // MARK: Exécution

    private func execute(_ probe: MonProbe, manual: Bool) {
        guard !isSimulated else { return }
        running.insert(probe.id)
        nextRun[probe.id] = Date().addingTimeInterval(TimeInterval(probe.interval))
        if probe.kind == .ping, pinger == nil, !pingerFailed {
            do { pinger = try ICMPPinger() } catch { pingerFailed = true }
        }
        // Communauté lue au Trousseau seulement quand la sonde interroge un agent SNMP.
        let resourceKinds: [MonProbeKind] = [.cpu, .memory, .portLoad]
        let needsSNMP = probe.kind == .snmp || (resourceKinds.contains(probe.kind) && !MonResourceChecks.isLocal(probe.target))
        // Sondes de ressources : même communauté que les écrans (propre à l'hôte dans Switchs et
        // ports, sinon celle des Identifiants).
        let perHost = needsSNMP && resourceKinds.contains(probe.kind)
        var community = needsSNMP && !perHost ? RegSNMPCredentials.load()?.community : nil
        launched[probe.id] = probe
        let pinger = self.pinger
        let devices = appState?.devices ?? []
        let inventoryReady = !ScanController.shared.isRunning
        // Sonde « Service en ligne » : catalogue de l'outil et accès Graph (secret lu au Trousseau).
        let onlineServices = probe.kind == .onlineService ? SvcStore.shared.services : []
        let onlineGraph = probe.kind == .onlineService ? SvcStore.shared.graphCredentials() : nil
        // Sondes FortiAP (note 27) : lecture Wi-Fi des FortiGate, relue si plus vieille que l'intervalle.
        let isFortiAP = probe.kind == .fortiAPOffline || probe.kind == .fortiAPOverload
        let appState = self.appState
        Task {
            var fortiWifi: FortiWifiOverview?
            var fortiWifiError: String?
            if isFortiAP {
                await FortiAPStore.shared.refreshForMonitoring(maxAge: TimeInterval(probe.interval), state: appState)
                fortiWifi = FortiAPStore.shared.overview
                fortiWifiError = FortiAPStore.shared.readError
            }
            // Étendue DHCP (note 37) : étendues de la FortiGate relues si plus vieilles que
            // l'intervalle, sinon l'estimation du Test DHCP et du scan.
            var dhcpScopes: DHCPScopeOverview?
            var dhcpScopesError: String?
            if probe.kind == .dhcpScope {
                let store = DHCPScopeStore.shared
                await store.refreshForMonitoring(maxAge: TimeInterval(probe.interval), state: appState)
                dhcpScopes = store.overview(devices: appState?.devices ?? devices)
                dhcpScopesError = store.readError
            }
            if perHost {
                await SwitchStore.shared.loadVault()
                let host = SwitchStore.shared.community(for: probe.target)
                community = host.isEmpty ? RegSNMPCredentials.load()?.community : host
            }
            var context = MonRunContext(pinger: pinger, snmpCommunity: community, devices: devices,
                                        inventoryReady: inventoryReady, now: Date())
            context.onlineServices = onlineServices
            context.onlineServiceGraph = onlineGraph
            context.fortiWifi = fortiWifi
            context.fortiWifiError = fortiWifiError
            context.dhcpScopes = dhcpScopes
            context.dhcpScopesError = dhcpScopesError
            let outcome = await MonRunner.run(probe, context: context)
            MonStore.shared.finish(probe.id, outcome: outcome, manual: manual)
        }
    }

    private func finish(_ id: UUID, outcome: MonRunOutcome, manual: Bool) {
        running.remove(id)
        let started = launched.removeValue(forKey: id)
        guard let index = probes.firstIndex(where: { $0.id == id }) else { return }
        // Type ou cible changé pendant la vérification : ce résultat concerne l'ancienne cible.
        if let started, started.kind != probes[index].kind || started.target != probes[index].target { return }
        if outcome.noData {
            if manual {
                let text = "Test manuel\u{00A0}: rien à évaluer (\(outcome.result.value))."
                manualTests[id] = MonManualTest(date: outcome.result.date, text: text, tone: .neutral)
            }
            changed()
            return
        }
        if let location = outcome.learnedLocation, probes[index].expectedLocation == nil {
            probes[index].expectedLocation = location
        }
        if let macs = outcome.knownMACs { probes[index].knownMACs = macs }
        let probe = probes[index]
        let dependencyDown = self.probe(probe.dependsOn).map { state(of: $0) == .down } ?? false
        guard let step = MonStateMachine.step(probe: probe, tracker: trackers[id] ?? MonTracker(),
                                              outcome: outcome, dependencyDown: dependencyDown) else { return }
        trackers[id] = step.tracker
        history.record(probe: id, result: outcome.result, state: step.tracker.state)
        let openBefore = journal.openCount(probe: id)
        let created = journal.record(step.events, probe: probe, date: outcome.result.date)
        for alert in created { MonNotifier.shared.post(alert, probe: probe) }
        for alert in created { AlertDispatcher.shared.emit(.probe(alert, probe: probe)) }
        // Retour à la normale notifié seulement s'il a fermé une alerte (pas pour une simple information).
        if step.events.contains(where: { $0.kind == .recovered }), journal.openCount(probe: id) < openBefore {
            MonNotifier.shared.postRecovery(probe: probe, value: outcome.result.value)
            AlertDispatcher.shared.emit(.probeRecovery(probe: probe, value: outcome.result.value, at: outcome.result.date))
        }
        if manual {
            let result = outcome.result
            let text: String
            let tone: Tone
            if !result.reachable {
                text = "Test manuel\u{00A0}: échec, \(result.error ?? "aucune réponse")."
                tone = .critical
            } else if let problem = MonStateMachine.warnings(probe: probe, result: result).first {
                text = "Test manuel\u{00A0}: \(problem) (\(result.value))."
                tone = .warning
            } else {
                text = "Test manuel réussi\u{00A0}: \(result.value)."
                tone = .success
            }
            manualTests[id] = MonManualTest(date: result.date, text: text, tone: tone)
            addManualEntry(probe, text: text, tone: tone, date: result.date)
        }
        changed()
    }

    /// Démonstration : le test reprend l'état de la sonde, comme le croquis.
    private func simulateTest(_ probe: MonProbe) {
        let value = lastValue(of: probe)
        let date = Date()
        let test: MonManualTest
        switch state(of: probe) {
        case .down:
            test = MonManualTest(date: date, text: "Test manuel\u{00A0}: échec, aucune réponse après \(probe.thresholds.failures) tentatives (délai 1\u{00A0}000\u{00A0}ms).", tone: .critical)
        case .warning:
            test = MonManualTest(date: date, text: "Test manuel\u{00A0}: condition toujours présente (\(value)).", tone: .warning)
        default:
            test = MonManualTest(date: date, text: "Test manuel réussi\u{00A0}: \(value).", tone: .success)
        }
        manualTests[probe.id] = test
        addManualEntry(probe, text: test.text, tone: test.tone, date: date)
    }

    /// Entrée du journal pour un test manuel ; une réussite n'appelle aucune action.
    private func addManualEntry(_ probe: MonProbe, text: String, tone: Tone, date: Date) {
        let severity: MonSeverity = tone == .critical ? .critical : tone == .warning ? .warning : .success
        journal.add(MonAlert(date: date, probeID: probe.id, probeName: probe.name, severity: severity, message: text,
                             acknowledgedAt: severity == .success ? date : nil))
        changed()
    }

    // MARK: Enregistrement

    private func changed() {
        updateBadge()
        guard !isSimulated, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                MonStore.shared.saveScheduled = false
                MonStore.shared.save()
            }
        }
    }

    private func updateBadge() {
        guard let appState else { return }
        let count = journal.unreadCount
        if appState.sidebarBadges[.surveillance] != count { appState.sidebarBadges[.surveillance] = count }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let archive = try MonArchive.decode(data)
            if archive.skipped > 0 || archive.version > MonArchive.currentVersion {
                // Écrit par une autre version (valeurs inconnues écartées) : copie intacte gardée de côté.
                NSLog("NetScope : %d élément(s) illisible(s) écarté(s) de %@", archive.skipped, url.path)
                try? FileManager.default.copyItem(at: url, to: backupURL("autre-version"))
            }
            probes = archive.probes
            var map: [UUID: MonTracker] = [:]
            for (key, tracker) in archive.trackers {
                if let id = UUID(uuidString: key) { map[id] = tracker }
            }
            trackers = map
            history = archive.history
            history.prune(keeping: Set(probes.map(\.id)), now: Date())
            journal = archive.journal
            selectedID = probes.first?.id
        } catch {
            NSLog("NetScope : lecture impossible de %@ : %@", url.path, error.localizedDescription)
            // Fichier illisible : on le garde de côté plutôt que de l'écraser.
            try? FileManager.default.moveItem(at: url, to: backupURL("illisible"))
        }
    }

    /// « surveillance.illisible-20261103-143010.json » : horodaté, une copie n'en écrase jamais une autre.
    private func backupURL(_ label: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "surveillance.\(label)-\(formatter.string(from: Date()))"
        var candidate = url.deletingLastPathComponent().appendingPathComponent(name + ".json")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(name)-\(counter).json")
            counter += 1
        }
        return candidate
    }

    func save() {
        guard !isSimulated else { return }
        var map: [String: MonTracker] = [:]
        for (id, tracker) in trackers { map[id.uuidString] = tracker }
        let archive = MonArchive(probes: probes, trackers: map, history: history, journal: journal)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try archive.encoded().write(to: url, options: .atomic)
        } catch {
            NSLog("NetScope : enregistrement impossible de %@ : %@", url.path, error.localizedDescription)
        }
    }

    // MARK: Démonstration

    /// Remplace tout par les données du croquis (MonDemo).
    func loadDemo(probes: [MonProbe], trackers: [UUID: MonTracker], history: MonHistory, journal: MonJournal,
                  selected: UUID?, now: Date, cycleStart: Date) {
        self.probes = probes
        self.trackers = trackers
        self.history = history
        self.journal = journal
        selectedID = selected
        demoNow = CommandLine.arguments.contains("--snapshot") ? now : nil
        self.cycleStart = cycleStart
    }

    // MARK: Format

    /// « 2 h 04 », « 12 min », « 40 s ».
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds.rounded(.towardZero).clampedInt)
        if total < 60 { return "\(total)\u{00A0}s" }
        if total < 3600 { return "\(total / 60)\u{00A0}min" }
        if total < 86_400 { return String(format: "%d\u{00A0}h\u{00A0}%02d", total / 3600, total / 60 % 60) }
        return "\(total / 86_400)\u{00A0}j"
    }
}
