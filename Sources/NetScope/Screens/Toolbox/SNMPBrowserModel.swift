import AppKit
import Foundation
import NetScopeCore

/// État du Navigateur SNMP (note 59), conservé quand on change d'écran. Les identifiants saisis
/// ici restent en mémoire le temps de la session : jamais écrits sur le disque ; ceux des Réglages
/// restent au Trousseau.
@MainActor
final class SNMPBrowserModel: ObservableObject {
    static let shared = SNMPBrowserModel()

    enum Version: String, CaseIterable, Identifiable {
        case v2c, v3
        var id: String { rawValue }
        var label: String { self == .v2c ? "v2c" : "v3" }
    }

    enum Source: String, CaseIterable, Identifiable {
        case saved, typed
        var id: String { rawValue }
        var label: String { self == .saved ? "Identifiants enregistrés" : "Saisir pour cette session" }
    }

    /// Bilan de la dernière lecture.
    struct RunInfo: Equatable {
        var oid: SNMPOID
        var operation: SNMPBrowserOperation
        var mode: SNMPWalkMode
        var count: Int
        var duration: TimeInterval
        var end: SNMPWalkEnd
        var requests: Int
        var versionLabel: String
        var wasCancelled = false
    }

    static let limits = [100, 500, 1_000, 5_000, 20_000]

    @Published var host = ""
    @Published var version: Version = .v3
    @Published var source: Source = .saved
    @Published var community = ""
    @Published var v3User = ""
    @Published var v3Level: SNMPv3Level = .authPriv
    @Published var v3Auth: SNMPAuthProtocol = .sha256
    @Published var v3AuthPassword = ""
    @Published var v3Priv: SNMPPrivProtocol = .aes128
    @Published var v3PrivPassword = ""
    @Published var v3Context = ""
    @Published var oidText = "system"
    @Published var operation: SNMPBrowserOperation = .walk
    /// Parcours par GETNEXT (agents anciens ou capricieux) au lieu de GETBULK.
    @Published var walkWithGetNext = false
    @Published var limit = 1_000

    @Published private(set) var rows: [SNMPBrowserRow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: RunInfo?
    @Published var error: String?
    /// Message passager (copie, export).
    @Published var notice: (text: String, tone: Tone)?

    let isDemo: Bool
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Lots du parcours en cours (ordre garanti).
    private var collector: SNMPBrowserCollector?
    private var startedAt = Date()

    private init() {
        isDemo = Launcher.isDemo
        guard isDemo else { return }
        host = SNMPBrowserDemo.host
        oidText = SNMPBrowserDemo.initialOID
        if let root = SNMPMIB.parse(oidText) {
            let walked = SNMPBrowserDemo.walk(root, limit: limit)
            rows = walked.binds.enumerated().map { SNMPBrowserRow(position: $0.offset, bind: $0.element) }
            lastRun = RunInfo(oid: root, operation: .walk, mode: .defaultBulk, count: rows.count, duration: 0.184,
                              end: walked.end, requests: max(1, rows.count / 25 + 1), versionLabel: "v3 authPriv")
        }
    }

    // MARK: Saisie

    var parsedOID: SNMPOID? { SNMPMIB.parse(oidText) }

    var walkMode: SNMPWalkMode { walkWithGetNext ? .getNext : .defaultBulk }

    var cleanHost: String { host.trimmingCharacters(in: .whitespaces) }

    var hostIsValid: Bool {
        !cleanHost.isEmpty && cleanHost.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// Identifiant v3 saisi.
    var typedV3: SNMPv3Credentials {
        SNMPv3Credentials(user: v3User.trimmingCharacters(in: .whitespaces), level: v3Level, auth: v3Auth, authPassword: v3AuthPassword,
                          priv: v3Priv, privPassword: v3PrivPassword, context: v3Context)
    }

    /// Identifiant v3 enregistré pour cet hôte (site, sinon tous les sites).
    var savedV3: SNMPv3Credentials? {
        IPv4Address(cleanHost).flatMap { SNMPAccessVault.shared.v3(for: $0) } ?? SNMPAccessVault.shared.global
    }

    /// Communauté enregistrée pour cet hôte (celle du switch, sinon celle des Identifiants).
    var savedCommunity: String { SwitchStore.shared.community(for: cleanHost) }

    /// Ce que la lecture utilisera, sans aucun secret (« v3 · netscope-ro · authPriv · SHA-256/AES-128 »).
    var credentialSummary: (text: String, tone: Tone) {
        switch (source, version) {
        case (.saved, .v3):
            guard let credentials = savedV3 else {
                return ("Aucun utilisateur SNMP v3 enregistré\u{00A0}: ajoutez-le dans Réglages › Identifiants, ou saisissez-le ici.", .warning)
            }
            let site = IPv4Address(cleanHost).flatMap { SNMPAccessVault.shared.site(for: $0) }
            let origin = site.map { "utilisateur propre au site «\u{00A0}\($0.displayName)\u{00A0}»" } ?? "utilisateur de tous les sites"
            return ("v3 · \(credentials.summary) — \(origin), Trousseau", .success)
        case (.saved, .v2c):
            guard !savedCommunity.isEmpty else {
                return ("Aucune communauté enregistrée\u{00A0}: ajoutez-la dans Réglages › Identifiants, ou saisissez-la ici.", .warning)
            }
            let ownCommunity = SwitchStore.shared.community != savedCommunity
            return ("v2c · communauté \(ownCommunity ? "retenue pour ce switch" : "des Identifiants") (masquée), Trousseau — en clair sur le réseau", .neutral)
        case (.typed, .v3):
            return ("v3 · \(typedV3.summary) — saisi pour cette session, jamais enregistré", .accent)
        case (.typed, .v2c):
            return ("v2c · communauté saisie pour cette session, jamais enregistrée — en clair sur le réseau", .neutral)
        }
    }

    /// Cible de la lecture ; nil avec l'erreur à afficher.
    func target(_ address: IPv4Address) -> (SNMPTarget?, String?) {
        let timeout: TimeInterval = 2
        switch (source, version) {
        case (.saved, .v3):
            guard let credentials = savedV3 else { return (nil, "Aucun utilisateur SNMP v3 enregistré pour cet hôte.") }
            return (SNMPTarget(host: address, community: "", v3: credentials, timeout: timeout, retries: 1), nil)
        case (.saved, .v2c):
            guard !savedCommunity.isEmpty else { return (nil, "Aucune communauté SNMP enregistrée.") }
            return (SNMPTarget(host: address, community: savedCommunity, timeout: timeout, retries: 1), nil)
        case (.typed, .v3):
            do { try typedV3.validate() } catch { return (nil, (error as? LocalizedError)?.errorDescription ?? "Identifiant v3 incomplet.") }
            return (SNMPTarget(host: address, community: "", v3: typedV3, timeout: timeout, retries: 1), nil)
        case (.typed, .v2c):
            guard !community.isEmpty else { return (nil, "Saisissez la communauté (lecture seule).") }
            return (SNMPTarget(host: address, community: community, timeout: timeout, retries: 1), nil)
        }
    }

    /// Commande net-snmp équivalente (sans aucun secret).
    var command: String {
        let oid = parsedOID?.description ?? (oidText.isEmpty ? "<oid>" : oidText)
        let tool = operation == .walk && walkWithGetNext ? "snmpwalk" : operation.netSNMPCommand
        let options: String
        switch (source, version) {
        case (.saved, .v3): options = savedV3?.netSNMPOptions ?? "-v3 -l authPriv -u <utilisateur>"
        case (.typed, .v3): options = typedV3.netSNMPOptions
        case (_, .v2c): options = "-v2c -c ••••"
        }
        let host = cleanHost.isEmpty ? "<hôte>" : cleanHost
        return "\(tool) \(options) \(host) \(oid)"
    }

    func choose(_ preset: SNMPBrowserPreset) {
        oidText = preset.name
        operation = .walk
    }

    // MARK: Lecture

    func run(store: ToolStore) {
        guard hostIsValid else { error = "Saisissez une adresse IP ou un nom d’hôte."; return }
        guard let oid = parsedOID else {
            error = "OID invalide\u{00A0}: saisissez par exemple 1.3.6.1.2.1.1, sysName.0 ou ifXTable."
            return
        }
        error = nil
        notice = nil
        task?.cancel()
        generation += 1
        let run = generation
        let operation = self.operation
        let mode = walkMode
        let limit = self.limit
        let host = cleanHost
        // Lots reçus, dans l'ordre du parcours (le rappel est synchrone) : les tâches qui les
        // remettent à l'écran peuvent s'exécuter dans le désordre, les lignes non.
        let collector = SNMPBrowserCollector()
        self.collector = collector
        isRunning = true
        rows = []
        lastRun = nil
        startedAt = Date()
        store.record(command: command)

        if isDemo {
            let label = version == .v3 ? "v3 \((source == .saved ? savedV3?.level : v3Level)?.rawValue ?? "authPriv")" : "v2c"
            task = Task { [weak self] in
                let agent = SNMPBrowserDemo.agent
                let result = try? await SNMPBrowse.run(oid, operation: operation, mode: mode, limit: limit,
                                                       onBatch: { batch in
                                                           collector.add(batch)
                                                           Task { @MainActor in self?.sync(collector, run: run) }
                                                       }) { pdu in
                    try await Task.sleep(nanoseconds: 35_000_000)
                    return agent.answer(pdu)
                }
                await MainActor.run { self?.finish(result: result, error: nil, oid: oid, operation: operation, mode: mode, host: host,
                                                   versionLabel: label, run: run, store: store) }
            }
            return
        }

        task = Task { [weak self] in
            guard let self else { return }
            await SNMPAccessVault.shared.load()
            let address: IPv4Address
            if let ip = IPv4Address(host) {
                address = ip
            } else if let resolved = try? await PingResolver.resolveAsync(host) {
                address = resolved
            } else {
                self.finish(result: nil, error: "Nom introuvable\u{00A0}: \(host)", oid: oid, operation: operation, mode: mode, host: host,
                            versionLabel: "", run: run, store: store)
                return
            }
            let (target, problem) = self.target(address)
            guard let target else {
                self.finish(result: nil, error: problem, oid: oid, operation: operation, mode: mode, host: host, versionLabel: "",
                            run: run, store: store)
                return
            }
            let label = target.versionLabel
            do {
                let result = try await SNMPClient(target: target).browse(oid, operation: operation, mode: mode, limit: limit,
                                                                         onBatch: { batch in
                                                                             collector.add(batch)
                                                                             Task { @MainActor in self.sync(collector, run: run) }
                                                                         })
                self.finish(result: result, error: nil, oid: oid, operation: operation, mode: mode, host: host, versionLabel: label,
                            run: run, store: store)
            } catch is CancellationError {
                self.finish(result: nil, error: nil, oid: oid, operation: operation, mode: mode, host: host, versionLabel: label,
                            run: run, store: store)
            } catch {
                let text = SNMPCredentialTest.explain(error, version3: target.v3 != nil, host: address.description).1
                self.finish(result: nil, error: text.replacingOccurrences(of: "Échec · ", with: ""), oid: oid, operation: operation,
                            mode: mode, host: host, versionLabel: label, run: run, store: store)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Ajoute à l'écran les lignes reçues depuis la dernière mise à jour, dans l'ordre du parcours.
    private func sync(_ collector: SNMPBrowserCollector, run: Int) {
        guard run == generation, isRunning else { return }
        let start = rows.count
        rows += collector.binds(from: start).enumerated().map { SNMPBrowserRow(position: start + $0.offset, bind: $0.element) }
    }

    private func finish(result: SNMPWalkResult?, error: String?, oid: SNMPOID, operation: SNMPBrowserOperation, mode: SNMPWalkMode,
                        host: String, versionLabel: String, run: Int, store: ToolStore) {
        guard run == generation else { return }
        isRunning = false
        let duration = Date().timeIntervalSince(startedAt)
        let name = SNMPMIB.name(for: oid) ?? oid.description
        if let result {
            rows = result.binds.enumerated().map { SNMPBrowserRow(position: $0.offset, bind: $0.element) }
            lastRun = RunInfo(oid: oid, operation: operation, mode: mode, count: rows.count, duration: duration, end: result.end,
                              requests: result.requests, versionLabel: versionLabel)
            let summary = "\(operation.label) \(name) · \(rows.count) ligne\(rows.count > 1 ? "s" : "")"
                + (result.truncated ? " (limite atteinte)" : "")
            let empty = rows.isEmpty || rows.allSatisfy(\.isException)
            store.record(ToolRecent(tool: .snmp, target: host, summary: summary, status: empty ? .warning : .ok))
        } else if let error {
            self.error = error
            lastRun = nil
            store.record(ToolRecent(tool: .snmp, target: host, summary: "\(operation.label) \(name) · \(error)", status: .failure))
        } else {
            // Arrêt demandé : toutes les lignes reçues restent, même celles pas encore affichées.
            if let collector {
                let start = rows.count
                rows += collector.binds(from: start).enumerated().map { SNMPBrowserRow(position: start + $0.offset, bind: $0.element) }
            }
            lastRun = RunInfo(oid: oid, operation: operation, mode: mode, count: rows.count, duration: duration, end: .limit,
                              requests: 0, versionLabel: versionLabel, wasCancelled: true)
            store.record(ToolRecent(tool: .snmp, target: host, summary: "Interrompu · \(name) · \(rows.count) ligne\(rows.count > 1 ? "s" : "")", status: .info))
        }
    }

    // MARK: Copie et export

    func copy(_ rows: [SNMPBrowserRow]) {
        ToolActions.copy(SNMPBrowserFormat.text(rows))
        notice = ("\(rows.count) ligne\(rows.count > 1 ? "s" : "") copiée\(rows.count > 1 ? "s" : "").", .success)
    }

    func exportCSV(_ rows: [SNMPBrowserRow]) {
        let panel = NSSavePanel()
        panel.title = "Exporter la lecture SNMP"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = lastRun.flatMap { SNMPMIB.name(for: $0.oid) } ?? "snmp"
        panel.nameFieldStringValue = "snmp-\(cleanHost)-\(name)-\(formatter.string(from: Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (Data([0xEF, 0xBB, 0xBF]) + Data(SNMPBrowserFormat.csv(rows).utf8)).write(to: url, options: .atomic)
            notice = ("Exporté\u{00A0}: \(url.lastPathComponent)", .success)
        } catch {
            notice = ("Export impossible\u{00A0}: \(error.localizedDescription)", .critical)
        }
    }
}

/// Lots d'un parcours, gardés dans l'ordre où le moteur les remet (rappel synchrone, verrou).
final class SNMPBrowserCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [SNMPVarBind] = []

    func add(_ batch: [SNMPVarBind]) {
        lock.lock()
        defer { lock.unlock() }
        all += batch
    }

    /// Lignes reçues à partir de la position `start`.
    func binds(from start: Int) -> [SNMPVarBind] {
        lock.lock()
        defer { lock.unlock() }
        return start < all.count ? Array(all[start...]) : []
    }
}
