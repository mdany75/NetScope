import AppKit
import Foundation
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Une cible du ping continu.
struct PingTarget: Identifiable {
    let id = UUID()
    /// Texte saisi ou reçu d'un autre écran (sert à éviter les doublons).
    var input: String
    var name: String
    var role: String
    var address: IPv4Address?
    /// Erreur de résolution ou de socket.
    var error: String?
    var history = PingHistory()
    var thresholdMs: Double
    /// Pause propre à la cible (0.21.0) : plus aucun envoi, statistiques figées.
    var pauses = PingPausePeriods()

    var isPaused: Bool { pauses.isPaused }
    var status: PingTargetStatus { PingTargetStatus.of(history, isPaused: isPaused) }
    var addressLabel: String { address?.description ?? input }
}

/// Moteur de l'écran Ping continu : cibles, mesures, journal et MTR. Une seule instance, qui
/// survit aux changements d'écran : le ping continue en arrière-plan une fois démarré.
/// L'écran s'ouvre vide (0.21.0) : aucune cible d'office ; elles viennent du champ, du Scanner,
/// de la fiche Appareil et des autres écrans (AppState.pingTargets).
@MainActor
final class PingController: ObservableObject {
    static let shared = PingController()

    static let maxTargets = 9
    static let cardWindow = 60
    static let chartWindow = 120
    static let maxEvents = 200

    @Published private(set) var targets: [PingTarget] = []
    @Published var selectedID: PingTarget.ID? {
        didSet { if oldValue != selectedID { selectionChanged() } }
    }
    @Published private(set) var events: [PingEvent] = []
    @Published private(set) var interval: TimeInterval = 1
    @Published private(set) var payloadSize = 56
    @Published var soundOnLoss = true
    @Published private(set) var isPaused = false
    @Published private(set) var hasStarted = false
    @Published private(set) var sessionStart = Date()
    /// Le système a refusé le bit DF : le test MTU n'est pas fiable.
    @Published private(set) var dontFragmentRefused = false

    // MTR
    @Published private(set) var mtrReport: PingMTRReport?
    @Published private(set) var isMTRRunning = false
    @Published private(set) var mtrError: String?
    @Published var resolveHopNames = true {
        didSet { if resolveHopNames, let report = mtrReport { resolveNames(in: report) } }
    }
    @Published private(set) var hostnames: [IPv4Address: String] = [:]

    /// Démonstration ou capture : mesures simulées, aucun accès réseau.
    let isSimulated: Bool
    private let isSnapshot: Bool

    private var monitors: [PingTarget.ID: PingMonitor] = [:]
    private var pendingSamples: [(PingTarget.ID, PingSample)] = []
    private var flushScheduled = false
    private var mtrTask: Task<Void, Never>?
    private var simulationTimer: Timer?
    private weak var appState: AppState?
    private var lastSound = Date.distantPast
    private var resolvingNames: Set<IPv4Address> = []

    private init() {
        let arguments = CommandLine.arguments
        isSnapshot = arguments.contains("--snapshot")
        isSimulated = isSnapshot || arguments.contains("--demo")
    }

    var selectedTarget: PingTarget? {
        targets.first { $0.id == selectedID } ?? targets.first
    }

    var options: PingOptions {
        PingOptions(interval: interval, payloadSize: payloadSize, dontFragment: payloadSize > 1000)
    }

    var totalSent: Int { targets.reduce(0) { $0 + $1.history.totalSent } }
    var pausedCount: Int { targets.filter(\.isPaused).count }
    var totalLost: Int { targets.reduce(0) { $0 + $1.history.totalSent - $1.history.totalReceived } }

    // MARK: Démarrage

    /// Captures : NETSCOPE_PING_VIDE=1 montre l'écran tel qu'à la première ouverture (vide).
    private var demoEmpty: Bool {
        isSimulated && ProcessInfo.processInfo.environment["NETSCOPE_PING_VIDE"] == "1"
    }

    /// Appelé à l'ouverture de l'écran : ouvre la session la première fois, sans aucune cible
    /// d'office ni journal, puis reprend les cibles envoyées par les autres écrans
    /// (AppState.pingTargets).
    func activate(with state: AppState) {
        appState = state
        if !hasStarted {
            hasStarted = true
            sessionStart = Date()
            if demoEmpty { return }
            if isSimulated { loadDemo(state: state) }
        }
        guard !demoEmpty else { return }
        sync(with: state.pingTargets)
    }

    /// Ajoute les cibles reçues des autres écrans.
    func sync(with inputs: [String], log shouldLog: Bool = true) {
        for input in inputs where !contains(input) { add(input, log: shouldLog) }
    }

    private func contains(_ input: String) -> Bool {
        let key = input.trimmingCharacters(in: .whitespaces).lowercased()
        return targets.contains { $0.input.lowercased() == key || $0.address?.description == key }
    }

    // MARK: Cibles

    /// Ajoute une ou plusieurs cibles saisies : adresse, nom d'hôte ou plage (« 10.0.0.1-5 », « 10.0.0.0/29 »).
    func addFromField(_ text: String) {
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init)
        for token in tokens {
            if (token.contains("/") || token.contains("-")), let range = try? IPRange(parsing: token), range.count > 1 {
                for address in range.addresses().prefix(Self.maxTargets) where !contains(address.description) {
                    guard add(address.description) else { break }
                }
            } else if !contains(token) {
                add(token)
            }
        }
    }

    @discardableResult
    func add(_ rawInput: String, name: String? = nil, role: String? = nil, log shouldLog: Bool = true) -> Bool {
        let input = rawInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty, !contains(input) else { return false }
        guard targets.count < Self.maxTargets else {
            log(.alerte, "Session", "limite de \(Self.maxTargets) cibles atteinte")
            return false
        }
        let address = IPv4Address(input)
        var target = PingTarget(input: input, name: name ?? input, role: role ?? "", address: address,
                                thresholdMs: PingEventDetector.defaultThreshold(for: address))
        describe(&target)
        if let name { target.name = name }
        if let role { target.role = role }
        // Première cible : la session commence au premier ping, pas à l'ouverture de l'écran.
        if targets.isEmpty { sessionStart = Date() }
        targets.append(target)
        if selectedID == nil { selectedID = target.id }
        if shouldLog { log(.info, input, "cible ajoutée à la surveillance") }
        if address != nil {
            startMonitor(target.id)
        } else if !isSimulated {
            let id = target.id
            Task {
                do {
                    let resolved = try await PingResolver.resolveAsync(input)
                    update(id) {
                        $0.address = resolved
                        $0.role = $0.role.isEmpty || $0.role == "Nom d’hôte" ? resolved.description : $0.role
                        $0.thresholdMs = PingEventDetector.defaultThreshold(for: resolved)
                    }
                    startMonitor(id)
                } catch {
                    update(id) { $0.error = error.localizedDescription }
                    log(.alerte, input, error.localizedDescription)
                }
            }
        }
        return true
    }

    /// Nom et rôle d'après l'inventaire (appareil connu), sinon d'après l'adresse.
    private func describe(_ target: inout PingTarget) {
        if let address = target.address, let device = appState?.device(withID: address.description) {
            target.name = device.displayName
            target.role = device.switchLocation ?? device.deviceType.label
            return
        }
        let wellKnown = ["1.1.1.1": "Cloudflare", "1.0.0.1": "Cloudflare", "8.8.8.8": "Google DNS",
                         "8.8.4.4": "Google DNS", "9.9.9.9": "Quad9"]
        if let known = wellKnown[target.input] {
            target.name = known
            target.role = "Internet"
            return
        }
        guard let address = target.address else {
            target.role = "Nom d’hôte"
            return
        }
        switch AddressScope.of(address) {
        case .privee: target.role = "Réseau local"
        case .publique: target.role = "Internet"
        case let scope: target.role = scope.label
        }
    }

    func remove(_ id: PingTarget.ID) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        let target = targets.remove(at: index)
        monitors.removeValue(forKey: id)?.stop()
        appState?.pingTargets.removeAll { $0.caseInsensitiveCompare(target.input) == .orderedSame }
        log(.info, target.addressLabel, "cible retirée")
        if selectedID == id { selectedID = targets.first?.id }
    }

    private func update(_ id: PingTarget.ID, _ change: (inout PingTarget) -> Void) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        change(&targets[index])
    }

    // MARK: Moniteurs

    private func startMonitor(_ id: PingTarget.ID) {
        guard !isSimulated, !isPaused, monitors[id] == nil,
              let target = targets.first(where: { $0.id == id }), !target.isPaused,
              let address = target.address else { return }
        let monitor = PingMonitor(address: address, options: options) { sample in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PingController.shared.enqueue(id, sample) }
            }
        }
        do {
            try monitor.start()
            monitors[id] = monitor
            update(id) { $0.error = nil }
        } catch {
            update(id) { $0.error = error.localizedDescription }
            log(.alerte, address.description, error.localizedDescription)
        }
    }

    /// Les mesures sont regroupées et appliquées au plus 8 fois par seconde.
    private func enqueue(_ id: PingTarget.ID, _ sample: PingSample) {
        pendingSamples.append((id, sample))
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated { PingController.shared.flushSamples() }
        }
    }

    private func flushSamples() {
        flushScheduled = false
        let batch = pendingSamples
        pendingSamples.removeAll()
        for (id, sample) in batch { apply(sample, to: id) }
    }

    private func apply(_ sample: PingSample, to id: PingTarget.ID) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        // Mesure envoyée pendant une pause (arrivée en retard) : ignorée, les statistiques restent figées.
        guard !targets[index].pauses.covers(sample.date) else { return }
        let previous = targets[index].history.consecutiveLosses
        let wasAbove = (targets[index].history.last?.rttMs).map { $0 > targets[index].thresholdMs } ?? false
        targets[index].history.append(sample)
        let target = targets[index]
        let found = PingEventDetector.events(for: sample, previousLosses: previous, interval: interval,
                                             thresholdMs: target.thresholdMs, subject: target.addressLabel,
                                             previousAboveThreshold: wasAbove)
        for event in found {
            let suffix = event.level == .coupure && soundOnLoss ? " · alerte sonore" : ""
            insert(PingEvent(date: event.date, level: event.level, subject: event.subject, message: event.message + suffix))
        }
        if sample.isLost, soundOnLoss, previous == 0 || previous + 1 == PingTargetStatus.offlineThreshold {
            playLossSound()
        }
    }

    private func playLossSound() {
        guard !isSimulated, Date().timeIntervalSince(lastSound) > 1 else { return }
        lastSound = Date()
        NSSound(named: NSSound.Name("Basso"))?.play()
    }

    // MARK: Réglages

    func setInterval(_ value: TimeInterval) {
        guard value != interval else { return }
        interval = value
        monitors.values.forEach { $0.update(options) }
        restartSimulation()
        log(.info, "Session", "intervalle changé à \(PingFormat.duration(value))")
    }

    func setPayloadSize(_ value: Int) {
        guard value != payloadSize else { return }
        payloadSize = value
        dontFragmentRefused = false
        monitors.values.forEach { $0.update(options) }
        log(.info, "Session", "taille de paquet : \(value) octets" + (value > 1000 ? " (test MTU, DF)" : ""))
        if value > 1000, !isSimulated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    let controller = PingController.shared
                    controller.dontFragmentRefused = controller.monitors.values.contains { !$0.dontFragmentApplied }
                }
            }
        }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            // Les moniteurs sont gardés : la séquence reprend là où elle s'était arrêtée.
            monitors.values.forEach { $0.stop() }
            simulationTimer?.invalidate()
            simulationTimer = nil
        } else {
            // Les cibles mises en pause une à une restent en pause.
            for (id, monitor) in monitors where targets.first(where: { $0.id == id })?.isPaused == false {
                do {
                    monitor.update(options)
                    try monitor.start()
                } catch {
                    update(id) { $0.error = error.localizedDescription }
                }
            }
            targets.map(\.id).forEach(startMonitor)
            restartSimulation()
        }
        log(.info, "Session", isPaused ? "surveillance en pause" : "surveillance reprise")
    }

    /// Pause ou reprise d'une seule cible : les autres continuent. La pause globale reste
    /// prioritaire (une cible reprise pendant la pause globale repart avec elle).
    func togglePause(_ id: PingTarget.ID) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        let since = targets[index].pauses.pausedSince
        let paused = targets[index].pauses.toggle(at: now)
        let target = targets[index]
        if paused {
            monitors[id]?.stop()
        } else if PingPausePeriods.isSending(globalPaused: isPaused, targetPaused: false) {
            if let monitor = monitors[id] {
                do {
                    monitor.update(options)
                    try monitor.start()
                } catch {
                    update(id) { $0.error = error.localizedDescription }
                }
            } else {
                startMonitor(id)
            }
        }
        log(.info, target.addressLabel,
            PingPausePeriods.journalMessage(paused: paused, duration: since.map { now.timeIntervalSince($0) }))
    }

    /// Toutes les cibles en pause une à une : les reprend toutes.
    func resumeAllTargets() {
        for id in targets.filter(\.isPaused).map(\.id) { togglePause(id) }
    }

    func reset() {
        let now = Date()
        for index in targets.indices {
            targets[index].history.reset()
            targets[index].pauses.reset(at: now)
        }
        sessionStart = Date()
        events = [PingEvent(level: .info, subject: "Session", message: "statistiques réinitialisées")]
        if let report = mtrReport { mtrReport = PingMTRReport(destination: report.destination) }
    }

    func clearEvents() { events.removeAll() }

    private func log(_ level: PingEvent.Level, _ subject: String, _ message: String) {
        insert(PingEvent(level: level, subject: subject, message: message))
    }

    private func insert(_ event: PingEvent) {
        events.insert(event, at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
    }

    // MARK: Export

    /// Toutes les mesures en CSV (séparateur « ; », virgule décimale, comme Excel en français).
    /// Aucune mesure n'est comptée pendant la pause d'une cible (NetScopeCore.PingCSV).
    private var csvTargets: [PingCSV.Target] {
        targets.map { PingCSV.Target(name: $0.name, address: $0.addressLabel, samples: $0.history.samples, pauses: $0.pauses) }
    }

    func csv() -> String { PingCSV.make(csvTargets) }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "ping-continu-\(stamp.string(from: Date())).csv"
        panel.title = "Exporter les mesures"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv().write(to: url, atomically: true, encoding: .utf8)
            let count = PingCSV.count(csvTargets)
            log(.info, "Export", "CSV enregistré : \(targets.count) cibles, \(count) mesures (\(url.lastPathComponent))")
        } catch {
            log(.alerte, "Export", "échec de l’enregistrement : \(error.localizedDescription)")
        }
    }

    // MARK: MTR

    private func selectionChanged() {
        stopMTR()
        mtrError = nil
        guard let target = selectedTarget, let address = target.address else {
            mtrReport = nil
            return
        }
        if isSimulated {
            let profile = PingDemo.profile(for: target.input)
            mtrReport = PingDemo.report(to: address, profile: profile, cycles: 30)
            hostnames.merge(PingDemo.hostnames) { current, _ in current }
        } else {
            mtrReport = nil
        }
    }

    func startMTR() {
        guard !isMTRRunning, let target = selectedTarget, let address = target.address else { return }
        mtrError = nil
        isMTRRunning = true
        if mtrReport?.destination != address || isSimulated { mtrReport = PingMTRReport(destination: address) }
        if isSimulated {
            let hops = PingDemo.hops(to: address, profile: PingDemo.profile(for: target.input))
            mtrTask = Task {
                while !Task.isCancelled {
                    mtrReport?.record(PingDemo.cycle(hops: hops))
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            return
        }
        log(.info, address.description, "MTR lancé")
        mtrTask = Task {
            do {
                let tracer = try PingTracer(destination: address, maxHops: 30, timeout: 1)
                while !Task.isCancelled {
                    let cycle = try await tracer.runCycleAsync(limit: mtrReport?.probeLimit)
                    guard !Task.isCancelled, mtrReport?.destination == address else { break }
                    mtrReport?.record(cycle)
                    if resolveHopNames, let report = mtrReport { resolveNames(in: report) }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch is CancellationError {
            } catch {
                mtrError = error.localizedDescription
                isMTRRunning = false
            }
        }
    }

    func stopMTR() {
        mtrTask?.cancel()
        mtrTask = nil
        isMTRRunning = false
    }

    private func resolveNames(in report: PingMTRReport) {
        guard !isSimulated else { return }
        for address in report.hops.compactMap(\.address) where hostnames[address] == nil && !resolvingNames.contains(address) {
            resolvingNames.insert(address)
            Task {
                if let name = await PingResolver.reverseAsync(address) { hostnames[address] = name }
            }
        }
    }

    /// Rapport texte du MTR, copié dans le presse-papiers.
    func copyMTRReport() {
        guard let report = mtrReport else { return }
        let text = report.text(hostnames: resolveHopNames ? hostnames : [:])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        log(.info, "MTR", "rapport copié dans le presse-papiers")
    }

    // MARK: Démonstration

    private func loadDemo(state: AppState) {
        let now = Date()
        var inputs = PingDemo.profiles.map(\.input)
        for extra in state.pingTargets where !inputs.contains(extra) { inputs.append(extra) }
        for input in inputs.prefix(Self.maxTargets) {
            let profile = PingDemo.profile(for: input)
            let address = IPv4Address(input)
            var target = PingTarget(input: input, name: profile?.name ?? input, role: profile?.role ?? "", address: address,
                                    thresholdMs: profile?.threshold ?? PingEventDetector.defaultThreshold(for: address))
            if profile == nil { describe(&target) }
            if let profile { target.history = PingDemo.prefill(profile, now: now) }
            if input == PingDemo.pausedInput {
                // Cible en pause : plus aucune mesure depuis la mise en pause.
                let start = PingDemo.date(of: PingDemo.pausedIndex, now: now)
                target.pauses.pause(at: start)
                var history = PingHistory()
                for sample in target.history.samples where sample.date < start { history.append(sample) }
                target.history = history
            }
            targets.append(target)
        }
        sessionStart = now.addingTimeInterval(-121)
        events = PingDemo.events(now: now)
        selectedID = targets.first { $0.input == "8.8.8.8" }?.id ?? targets.first?.id
        if let target = selectedTarget, let address = target.address {
            mtrReport = PingDemo.report(to: address, profile: PingDemo.profile(for: target.input), cycles: 60)
        }
        hostnames = PingDemo.hostnames
        restartSimulation()
    }

    /// Mesures simulées en continu (démonstration interactive seulement, pas en capture).
    private func restartSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        guard isSimulated, !isSnapshot, !isPaused else { return }
        simulationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { PingController.shared.simulateTick() }
        }
    }

    private func simulateTick() {
        let now = Date()
        for target in targets where !target.isPaused {
            let profile = PingDemo.profile(for: target.input) ?? PingDemo.genericProfile(for: target.input, address: target.address)
            let sequence = (target.history.last?.sequence ?? 0) + 1
            apply(PingSample(sequence: sequence, date: now, rttMs: PingDemo.sample(for: profile, payloadSize: payloadSize)), to: target.id)
        }
    }
}
