import AppKit
import NetScopeCore
import UniformTypeIdentifiers

/// Journal de l'app et « Exporter un diagnostic » (note 35) : branche `AppLog.shared` sur
/// ~/Library/Logs/NetScope au lancement, suit ses entrées pour Réglages › Journal et diagnostic
/// et la pastille de la barre latérale, repère les plantages récents (bannière) et produit
/// l'archive .zip du diagnostic.
@MainActor
final class RegDiagnosticController: ObservableObject {
    static let shared = RegDiagnosticController()

    enum Key {
        /// Date de la dernière consultation du journal (pastille des erreurs récentes).
        static let journalSeen = "diagnostic.journalVuLe"
        /// Heure du dernier plantage montré (bannière).
        static let crashSeen = "diagnostic.dernierPlantageVu"
    }

    /// Entrées du journal, de la plus ancienne à la plus récente.
    @Published private(set) var entries: [AppLogEntry] = []
    /// Erreurs des dernières 24 h arrivées depuis la dernière consultation du journal.
    @Published private(set) var unseenErrorCount = 0
    /// Plantage plus récent que le dernier vu : bannière au lancement.
    @Published private(set) var pendingCrash: CrashReport?
    /// Rapports de plantage de NetScope des 30 derniers jours (section Journal et diagnostic).
    @Published private(set) var recentCrashes: [CrashReport] = []
    @Published private(set) var isExporting = false
    @Published var message: (text: String, tone: Tone)?
    /// Section affichée : les erreurs qui arrivent sont lues aussitôt.
    var isJournalVisible = false { didSet { if isJournalVisible { markSeen() } } }

    private let defaults: UserDefaults?
    private var refreshScheduled = false
    private var started = false

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        if RegEnvironment.isDemo {
            DiagnosticDemo.seed(AppLog.shared)
            recentCrashes = DiagnosticDemo.crashes()
            if DiagnosticDemo.showsCrashBanner { pendingCrash = recentCrashes.first }
        }
        AppLog.shared.addObserver { _ in
            Task { @MainActor in RegDiagnosticController.shared.scheduleRefresh() }
        }
        refresh()
    }

    // MARK: Lancement

    /// Branche le fichier du journal (avant tout autre module) ; jamais en démonstration ni en capture.
    static func installLogFile() {
        guard !RegEnvironment.isSandboxed else { return }
        AppLog.shared.configure(file: AppLogFile(directory: AppLogFile.standardDirectory))
        AppLog.shared.info("NetScope", "Lancement de NetScope \(UpdController.currentVersionText) (build \(RegEnvironment.build)), \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    /// Au lancement : rapports de plantage récents ; bannière si l'un est plus récent que le dernier vu.
    func start() {
        guard !started else { return }
        started = true
        guard !RegEnvironment.isSandboxed else { return }
        Task {
            let since = Date().addingTimeInterval(-CrashReports.defaultWindow)
            let reports = await Task.detached(priority: .utility) { CrashReports.find(since: since) }.value
            recentCrashes = reports
            let seen = defaults?.object(forKey: Key.crashSeen) as? Date ?? .distantPast
            if let latest = reports.first, latest.date > seen {
                pendingCrash = latest
                AppLog.shared.warning("NetScope", "Plantage précédent détecté (\(latest.fileName)\(latest.exception.map { ", \($0)" } ?? ""))")
            }
        }
    }

    /// Relit la liste des plantages (ouverture de la section).
    func reloadCrashes() {
        guard !RegEnvironment.isSandboxed else { return }
        Task {
            let since = Date().addingTimeInterval(-CrashReports.defaultWindow)
            recentCrashes = await Task.detached(priority: .utility) { CrashReports.find(since: since) }.value
        }
    }

    /// « Ignorer » : la bannière ne revient que pour un plantage plus récent.
    func dismissCrash() {
        if let date = pendingCrash?.date { defaults?.set(date, forKey: Key.crashSeen) }
        pendingCrash = nil
    }

    // MARK: Journal

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Rafale d'entrées (scan, relevés) : une seule mise à jour de l'interface toutes les 0,3 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        entries = AppLog.shared.entries
        if isJournalVisible { markSeen() } else { updateBadge() }
    }

    private var journalSeen: Date {
        if RegEnvironment.isSandboxed { return DiagnosticDemo.journalSeen }
        return defaults?.object(forKey: Key.journalSeen) as? Date ?? .distantPast
    }

    private func updateBadge() {
        let since = max(journalSeen, Date().addingTimeInterval(-86_400))
        let count = entries.reversed().prefix { $0.date > since }.filter { $0.level == .error }.count
        if count != unseenErrorCount { unseenErrorCount = count }
    }

    func markSeen() {
        defaults?.set(Date(), forKey: Key.journalSeen)
        if unseenErrorCount != 0 { unseenErrorCount = 0 }
    }

    /// Modules présents dans le journal, triés.
    var modules: [String] {
        Array(Set(entries.map(\.module))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func copy(_ list: [AppLogEntry]) {
        ToolActions.copy(AppLog.shared.exportText(list))
        message = ("\(list.count) entrée\(list.count > 1 ? "s" : "") copiée\(list.count > 1 ? "s" : "") (secrets masqués).", .success)
    }

    func clear() {
        AppLog.shared.clear()
        message = ("Journal effacé.", .neutral)
    }

    // MARK: Export

    /// « Exporter un diagnostic… » : choisit l'emplacement, puis écrit l'archive.
    func export() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Exporter un diagnostic"
        panel.prompt = "Exporter"
        panel.message = "Journal masqué, résumé du système, sites et réglages sans identifiants, plantages récents."
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = DiagnosticBundle.suggestedFileName(Date())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        let input = makeInput()
        Task {
            let crashes = await Task.detached(priority: .userInitiated) { () -> [DiagnosticInput.CrashFile] in
                guard !RegEnvironment.isSandboxed else { return DiagnosticDemo.crashFiles() }
                let since = Date().addingTimeInterval(-CrashReports.defaultWindow)
                return CrashReports.find(since: since).prefix(DiagnosticBundle.maxCrashReports).compactMap { report in
                    (try? Data(contentsOf: report.url)).map { DiagnosticInput.CrashFile(name: report.fileName, data: $0) }
                }
            }.value
            var full = input
            full.crashReports = crashes
            let data = await Task.detached(priority: .userInitiated) { DiagnosticBundle.archive(full) }.value
            do {
                try data.write(to: url, options: .atomic)
                message = ("Diagnostic exporté dans «\u{00A0}\(url.lastPathComponent)\u{00A0}» (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))). Aucun secret n’y figure.", .success)
                AppLog.shared.info("Diagnostic", "Diagnostic exporté (\(full.logEntries.count) entrées, \(crashes.count) plantage\(crashes.count > 1 ? "s" : ""))")
                NSWorkspace.shared.activateFileViewerSelecting([url])
                dismissCrash()
            } catch {
                message = ("Export impossible\u{00A0}: \(error.localizedDescription)", .critical)
                AppLog.shared.error("Diagnostic", "Export du diagnostic impossible : \(error.localizedDescription)")
            }
            isExporting = false
        }
    }

    /// Contenu du diagnostic, sans aucun identifiant (les sites ne donnent que noms et plages).
    private func makeInput() -> DiagnosticInput {
        let process = ProcessInfo.processInfo
        let sites = SiteModel.shared.sites.map { site in
            DiagnosticInput.SiteSummary(name: site.displayName, ranges: site.ranges.map(\.text),
                                        fortiGateCount: site.fortiGateIDs.count, switchCount: site.switchHosts.count,
                                        lastScan: site.lastScan, inventoryCount: site.inventoryCount,
                                        isActive: site.id == SiteModel.shared.activeID)
        }
        let interfaces: [DiagnosticInput.Interface] = (RegEnvironment.isSandboxed ? [DemoData.interface] : LocalInterfaces.list()).map {
            DiagnosticInput.Interface(name: $0.name, kind: $0.kind.label, address: "\($0.address)", netmask: "\($0.netmask)",
                                      gateway: $0.gateway.map { "\($0)" })
        }
        return DiagnosticInput(
            appVersion: UpdController.currentVersionText, build: RegEnvironment.build,
            macOSVersion: "macOS " + process.operatingSystemVersionString, macModel: Self.macModel(),
            processorCount: process.processorCount, memoryBytes: process.physicalMemory, uptime: process.systemUptime,
            interfaces: interfaces, sites: sites, settings: Self.settings(), logEntries: AppLog.shared.entries,
            isDemo: RegEnvironment.isDemo)
    }

    /// Identifiant du modèle (« Mac16,10 »).
    static func macModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "inconnu" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "inconnu" }
        return String(cString: buffer)
    }

    /// Préférences de NetScope, en texte ; les clés secrètes sont retirées par `DiagnosticBundle`,
    /// les données binaires résumées par leur taille.
    static func settings() -> [String: String] {
        guard !RegEnvironment.isSandboxed else { return DiagnosticDemo.settings }
        let domain = UserDefaults.standard.persistentDomain(forName: RegBackupController.preferencesDomain) ?? [:]
        var result: [String: String] = [:]
        for (key, value) in domain {
            switch value {
            case let data as Data: result[key] = "<données, \(data.count) octets>"
            case let date as Date: result[key] = ISO8601DateFormatter().string(from: date)
            case let array as [Any]: result[key] = "<liste de \(array.count) élément\(array.count > 1 ? "s" : "")>"
            case let dictionary as [String: Any]: result[key] = "<\(dictionary.count) clé\(dictionary.count > 1 ? "s" : "")>"
            default: result[key] = "\(value)"
            }
        }
        return result
    }

    // MARK: Messages des autres modules

    /// Message d'état d'un module (sauvegarde, synchronisation…) : les échecs et avertissements
    /// vont aussi au journal.
    static func note(_ message: (text: String, tone: Tone)?, module: String) {
        guard let message else { return }
        switch message.tone {
        case .critical: AppLog.shared.error(module, message.text)
        case .warning: AppLog.shared.warning(module, message.text)
        default: break
        }
    }
}
