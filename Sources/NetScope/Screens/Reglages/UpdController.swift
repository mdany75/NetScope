import AppKit
import NetScopeCore
import SwiftUI

/// Étape de la mise à jour, affichée dans Réglages › Mises à jour.
enum UpdPhase: Equatable {
    case idle
    case checking
    case upToDate
    case available
    case downloading(received: Int64, expected: Int64)
    case verifying
    case ready
    case installing
    case later
    case ignored
    case failed(String)
}

/// Pilote la mise à jour depuis les Releases GitHub : vérification (automatique ou sur demande),
/// téléchargement, vérification de la signature, installation et relancement. Met à jour
/// `AppState.updateAvailable` (pastille de la barre latérale).
@MainActor
final class UpdController: ObservableObject {
    static let shared = UpdController()

    @Published private(set) var phase: UpdPhase = .idle {
        didSet {
            // Note 35 : les échecs de vérification, de téléchargement ou d'installation vont au journal.
            // Un même échec répété (vérification automatique hors ligne) n'est écrit qu'une fois.
            guard !RegEnvironment.isSandboxed else { return }
            switch phase {
            case .failed(let why): RegDiagnosticController.noteFailure(why, module: "Mises à jour")
            case .checking, .downloading, .verifying, .installing: break
            default: RegDiagnosticController.noteFailure(nil, module: "Mises à jour")
            }
        }
    }
    @Published private(set) var release: UpdRelease?
    /// Dernière version connue du canal (même quand NetScope est à jour).
    @Published private(set) var latestKnown: UpdRelease?
    @Published private(set) var checks: [UpdSignature.Check] = []
    @Published private(set) var prepared: UpdPrepared?
    @Published var prefs: UpdPreferences { didSet { savePrefs() } }
    /// Un jeton GitHub est enregistré dans le Trousseau.
    @Published private(set) var hasToken = false
    @Published private(set) var tokenMessage: String?

    private weak var app: AppState?
    private var downloader: UpdDownloader?
    private var downloadTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var launched = false

    private static let prefsKey = "reglages.majs.preferences"
    private let defaults: UserDefaults?

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        if let data = defaults?.data(forKey: UpdController.prefsKey),
           let saved = try? JSONDecoder().decode(UpdPreferences.self, from: data) {
            prefs = saved
        } else {
            prefs = UpdPreferences()
        }
        hasToken = !RegEnvironment.isSandboxed && UpdKeychain.github.string(for: UpdKeychain.githubAccount) != nil
        if RegEnvironment.isDemo { applyDemo() }
    }

    // MARK: Infos

    static var currentVersionText: String { AppInfo.version }

    /// Notes de toutes les versions publiées, lues une fois dans le CHANGELOG livré avec l’app.
    static let changelog: [ChangelogVersion] = ChangelogNotes.bundled()
    static var currentVersion: UpdVersion { UpdVersion(AppInfo.version) ?? UpdVersion(major: 0, minor: 1) }

    /// Raison pour laquelle l'installation automatique est impossible (swift run…), ou nil.
    var installBlocker: String? {
        RegEnvironment.isSandboxed ? nil : UpdInstaller.installBlocker()
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    // MARK: Démarrage

    /// À appeler au démarrage de l'application (voir `reglagesAuLancement`) : rattache l'état,
    /// note la version en cours dans l'historique, puis vérifie si la fréquence choisie le demande.
    /// Ensuite, une vérification est retentée toutes les heures si elle est due.
    func applicationDidLaunch(_ app: AppState) async {
        attach(app)
        guard !launched else { return }
        launched = true
        app.scanProfile = RegPrefs.shared.defaultProfile
        guard !RegEnvironment.isSandboxed else { return }
        prefs.recordRunning(version: UpdController.currentVersionText)
        if prefs.isCheckDue(atLaunch: true) { await check(userInitiated: false) }
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                // Une mise à jour déjà téléchargée et vérifiée (.ready) n'est pas écrasée.
                if self.prefs.isCheckDue(atLaunch: false), !self.isBusy, self.phase != .ready {
                    await self.check(userInitiated: false)
                }
            }
        }
    }

    /// Rattache l'état de l'application (pastille de la barre latérale).
    func attach(_ app: AppState) {
        self.app = app
        syncBadge()
    }

    // MARK: Vérification

    /// Interroge GitHub. `userInitiated` : « Rechercher maintenant » (une version ignorée est
    /// tout de même affichée, comme ignorée).
    func check(userInitiated: Bool = true) async {
        guard !isBusy else { return }
        if RegEnvironment.isSandboxed {
            phase = .checking
            try? await Task.sleep(nanoseconds: 600_000_000)
            if RegEnvironment.isDemo {
                applyDemo()
            } else {
                phase = .failed("Capture hors écran : aucune vérification réseau.")
            }
            return
        }
        phase = .checking
        let checker = UpdateChecker(token: UpdKeychain.github.string(for: UpdKeychain.githubAccount))
        do {
            let result = try await checker.check(current: UpdController.currentVersion, channel: prefs.channel)
            prefs.lastCheck = Date()
            latestKnown = result.latest
            if let update = result.update {
                release = update
                checks = []
                prepared = nil
                if prefs.isSkipped(update) {
                    phase = .ignored
                } else {
                    phase = .available
                    if !userInitiated { announce(update) }
                    if prefs.automaticInstall && !userInitiated && installBlocker == nil { download() }
                }
            } else {
                release = nil
                phase = .upToDate
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        syncBadge()
    }

    // MARK: Téléchargement et vérification

    func download() {
        guard let release, let asset = release.diskImage else {
            phase = .failed(UpdError.missingAsset(version: self.release?.tagName ?? "?").localizedDescription)
            return
        }
        if RegEnvironment.isSandboxed {
            phase = .failed("Mode démonstration : aucun téléchargement réel.")
            return
        }
        let downloader = UpdDownloader()
        self.downloader = downloader
        checks = []
        prepared = nil
        phase = .downloading(received: 0, expected: asset.size)
        let token = UpdKeychain.github.string(for: UpdKeychain.githubAccount)
        let expectedVersion = release.version
        downloadTask = Task { [weak self] in
            do {
                let file = try await downloader.download(asset, token: token) { received, expected in
                    Task { @MainActor in
                        let controller = UpdController.shared
                        // Les tâches peuvent arriver dans le désordre : la progression ne recule jamais.
                        guard case .downloading(let shown, _) = controller.phase, received >= shown else { return }
                        controller.phase = .downloading(received: received, expected: expected)
                    }
                }
                guard let self else { return }
                self.phase = .verifying
                let result = await Task.detached(priority: .userInitiated) { () -> Result<UpdPrepared, Error> in
                    Result { try UpdInstaller.prepare(diskImage: file, expectedVersion: expectedVersion) }
                }.value
                switch result {
                case .success(let prepared):
                    self.prepared = prepared
                    self.checks = prepared.checks
                    self.phase = .ready
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                }
            } catch UpdError.cancelled {
                // « Plus tard » et « Ignorer » annulent aussi : leur état est conservé.
                if case .downloading = self?.phase { self?.phase = .available }
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
            self?.downloader = nil
        }
    }

    func cancelDownload() {
        downloader?.cancel()
        downloadTask?.cancel()
        phase = .available
    }

    // MARK: Installation

    /// Lance le script de remplacement puis quitte NetScope ; il sera relancé par le script.
    func installAndRelaunch() {
        guard let prepared, let destination = UpdInstaller.runningBundle() else {
            phase = .failed(installBlocker ?? "Aucune mise à jour prête.")
            return
        }
        if let blocker = installBlocker {
            phase = .failed(blocker)
            return
        }
        phase = .installing
        do {
            try UpdInstaller.launchReplacement(prepared: prepared, destination: destination)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func later() {
        downloader?.cancel()
        phase = .later
    }

    func skip() {
        guard let version = release?.version else { return }
        downloader?.cancel()
        prefs.skippedVersion = version.description
        phase = .ignored
        syncBadge()
    }

    func unskip() {
        prefs.skippedVersion = nil
        phase = release == nil ? .idle : .available
        syncBadge()
    }

    func openReleasePage() {
        let url = release?.htmlURL ?? UpdateChecker().releasesPage
        NSWorkspace.shared.open(url)
    }

    // MARK: Jeton GitHub

    func saveToken(_ token: String) {
        guard !RegEnvironment.isSandboxed else { return }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try UpdKeychain.github.set(trimmed, for: UpdKeychain.githubAccount)
            hasToken = !trimmed.isEmpty
            tokenMessage = trimmed.isEmpty ? "Jeton supprimé du Trousseau." : "Jeton enregistré dans le Trousseau."
        } catch {
            tokenMessage = error.localizedDescription
        }
    }

    func deleteToken() {
        saveToken("")
    }

    // MARK: Interne

    /// Mise à jour trouvée par la vérification automatique : événement commun, une seule fois par
    /// version (retenue dans les préférences).
    private func announce(_ release: UpdRelease) {
        let key = "reglages.majs.versionSignalee"
        let version = release.version?.description ?? release.tagName
        guard let defaults, defaults.string(forKey: key) != version else { return }
        defaults.set(version, forKey: key)
        NetScopeEventCenter.shared.publish(NetScopeEvent(
            id: "maj-\(version)", kind: .updateAvailable, title: "NetScope \(version) est disponible",
            detail: "Version installée\u{00A0}: \(UpdController.currentVersionText). Ouvrez Réglages › Mises à jour pour l’installer.",
            link: .updates, source: "mises-a-jour"))
    }

    private func syncBadge() {
        guard let app else { return }
        // Démonstration : la pastille de la barre latérale seulement sur demande (NETSCOPE_MAJ_DEMO=1),
        // pour que les captures ne montrent pas une fausse version disponible.
        if RegEnvironment.isDemo, ProcessInfo.processInfo.environment["NETSCOPE_MAJ_DEMO"] != "1" { return }
        if let release, let version = release.version, !prefs.isSkipped(release), phase != .upToDate {
            app.updateAvailable = version.description
        } else {
            app.updateAvailable = nil
        }
    }

    private func savePrefs() {
        guard let defaults, let data = try? JSONEncoder().encode(prefs) else { return }
        defaults.set(data, forKey: UpdController.prefsKey)
    }

    /// Démonstration (croquis) : version 1.1.0 disponible, historique fictif, aucun réseau.
    private func applyDemo() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 28; components.hour = 14
        let published = Calendar(identifier: .gregorian).date(from: components)
        let asset = UpdAsset(name: UpdateChecker.assetName, size: 18_400_000,
                             browserDownloadURL: URL(string: "https://github.com/mdany75/NetScope/releases/download/v1.1.0/NetScope.dmg")!)
        release = UpdRelease(tagName: "v1.1.0", name: "NetScope 1.1.0",
                             body: "- Détection du port de switch par SNMP v3\n- Analyseur Wi-Fi 6 GHz\n- Corrections du ping continu",
                             publishedAt: published, htmlURL: URL(string: "https://github.com/mdany75/NetScope/releases/tag/v1.1.0"),
                             assets: [asset])
        latestKnown = release
        phase = .available
        var history = UpdPreferences()
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: 9, minute: 2)) ?? Date()
        }
        // Historique réaliste : les versions installées sur ce Mac au fil des mises à jour.
        history.history = [
            UpdHistoryEntry(version: UpdController.currentVersionText, channel: .stable, date: day(2026, 11, 5)),
            UpdHistoryEntry(version: "0.22.0", channel: .stable, date: day(2026, 11, 5)),
            UpdHistoryEntry(version: "0.21.0", channel: .stable, date: day(2026, 11, 4)),
            UpdHistoryEntry(version: "0.20.3", channel: .stable, date: day(2026, 11, 4)),
            UpdHistoryEntry(version: "0.20.1", channel: .stable, date: day(2026, 11, 4)),
            UpdHistoryEntry(version: "0.18.0", channel: .stable, date: day(2026, 11, 4)),
            UpdHistoryEntry(version: "0.17.0", channel: .stable, date: day(2026, 11, 3)),
            UpdHistoryEntry(version: "0.15.0", channel: .stable, date: day(2026, 11, 3)),
            UpdHistoryEntry(version: "0.12.0", channel: .stable, date: day(2026, 11, 3)),
            UpdHistoryEntry(version: "0.9.0", channel: .stable, date: day(2026, 11, 3)),
        ]
        history.lastCheck = Calendar.current.date(bySettingHour: 9, minute: 2, second: 0, of: Date())
        prefs = history
    }
}

// MARK: - Intégration dans l'application

extension View {
    /// À placer sur la vue racine de la fenêtre, avec l'état de l'application :
    /// vérification automatique des mises à jour selon la fréquence choisie et profil de scan
    /// par défaut enregistré.
    func reglagesAuLancement(_ state: AppState) -> some View {
        task { await UpdController.shared.applicationDidLaunch(state) }
    }
}

/// Commande « Rechercher les mises à jour… » du menu de l'application.
struct UpdCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Rechercher les mises à jour…") {
                RegNavigation.shared.section = .majs
                state.open(.reglages)
                UpdController.shared.attach(state)
                Task { await UpdController.shared.check(userInitiated: true) }
            }
        }
    }
}

/// Section affichée dans Réglages (gardée d'une ouverture à l'autre de l'écran).
@MainActor
final class RegNavigation: ObservableObject {
    static let shared = RegNavigation()
    @Published var section: RegSection
    /// La section Mises à jour a déjà été proposée d'office pendant cette session.
    var didPromoteUpdates = false

    private init() {
        section = RegEnvironment.initialSection ?? .sites
        if RegEnvironment.initialSection != nil { didPromoteUpdates = true }
    }
}
