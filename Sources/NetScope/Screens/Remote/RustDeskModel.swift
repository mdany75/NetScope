import AppKit
import Foundation
import NetScopeCore

/// Note 6 : RustDesk (assistance à distance). Réglages du serveur, historique des lancements,
/// mots de passe permanents (Trousseau seulement), lancement par rustdesk:// et vérifications.
/// En démonstration et en capture : aucun fichier, aucun Trousseau, aucun réseau, aucun lancement.
@MainActor
final class RustDeskModel: ObservableObject {
    static let shared = RustDeskModel()

    nonisolated static let keychainService = "com.danymenard.netscope.rustdesk"
    nonisolated static let keychain = UpdKeychain(service: keychainService)

    @Published var settings: RustDeskServerSettings {
        didSet { if settings != oldValue { save() } }
    }
    @Published private(set) var history: [RustDeskLaunch] = []
    @Published private(set) var savedPasswords: Set<UUID> = []
    @Published private(set) var isInstalled = false
    /// RustDesk absent au moment de « Connecter » : l'écran propose le téléchargement.
    @Published var needsInstall = false

    /// « Vérifier le client RustDesk de ce Mac ».
    @Published private(set) var clientFindings: [RustDeskFinding]?
    @Published private(set) var clientCheckedAt: Date?
    /// « Tester le serveur ».
    @Published private(set) var probes: [RustDeskProbe] = []
    @Published private(set) var testing = false
    @Published private(set) var testedAt: Date?
    /// VIP des FortiGate (lecture seule) : un bloc par FortiGate.
    struct VIPReport: Identifiable, Equatable {
        var id: String { site }
        var site: String
        var findings: [RustDeskFinding]
        var error: String?
    }
    @Published private(set) var vipReports: [VIPReport] = []
    @Published private(set) var checkingVIPs = false
    /// Message bref de la section des réglages (import, copie).
    @Published var notice: String?

    private let store: RustDeskStore?
    private let sandboxed: Bool

    private init() {
        sandboxed = RegEnvironment.isSandboxed
        store = sandboxed ? nil : RustDeskStore.standard
        if RegEnvironment.isDemo {
            settings = RustDeskDemo.settings
            history = RustDeskDemo.history(connections: RemoteDemo.connections)
            savedPasswords = Set(RemoteDemo.connections.filter { RustDeskDemo.hasSavedPassword($0) }.map(\.id))
            isInstalled = true
            if ProcessInfo.processInfo.environment["NETSCOPE_RUSTDESK_VIEW"] == "verifie" {
                clientFindings = RustDeskClientCheck.compare(settings, client: RustDeskDemo.clientConfig)
                clientCheckedAt = Date().addingTimeInterval(-120)
                probes = RustDeskDemo.probes(settings)
                testedAt = Date().addingTimeInterval(-90)
                vipReports = [VIPReport(site: "Siège", findings: RustDeskVIPCheck.evaluate(RustDeskDemo.vips, settings: settings))]
            }
        } else {
            let contents = store?.load()
            settings = contents?.settings ?? RustDeskServerSettings()
            history = contents?.history ?? []
            refreshInstalled()
        }
    }

    // MARK: Client installé

    var applicationURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RustDeskLink.bundleIdentifier) { return url }
        let path = RustDeskLink.applicationPath
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func refreshInstalled() {
        guard !sandboxed else { return }
        isInstalled = applicationURL != nil
    }

    func openDownloadPage() {
        guard !sandboxed else { return }
        NSWorkspace.shared.open(RustDeskLink.downloadURL)
    }

    // MARK: Trousseau

    func hasPassword(_ id: UUID) -> Bool { savedPasswords.contains(id) }

    /// Relit au Trousseau quelles connexions RustDesk ont un mot de passe permanent (hors du rendu).
    func loadSavedPasswords(for ids: [UUID]) {
        guard !sandboxed else { return }
        let found = Set(ids.filter { Self.keychain.string(for: $0.uuidString) != nil })
        if found != savedPasswords { savedPasswords = found }
    }

    /// Enregistre (ou efface, si vide) le mot de passe permanent du poste.
    func setPassword(_ value: String, for id: UUID) throws {
        if value.isEmpty { savedPasswords.remove(id) } else { savedPasswords.insert(id) }
        guard !sandboxed else { return }
        try Self.keychain.set(value.isEmpty ? nil : value, for: id.uuidString)
    }

    func forget(_ id: UUID) {
        try? setPassword("", for: id)
    }

    private func password(for id: UUID) -> String? {
        guard !sandboxed else { return nil }
        return Self.keychain.string(for: id.uuidString)
    }

    // MARK: Lancement

    /// Ouvre RustDesk sur ce poste ; renvoie le message à afficher. `connection` nil : ID collé.
    @discardableResult
    func launch(_ target: RustDeskTarget, name: String, connection: RemoteConnection? = nil) -> String {
        refreshInstalled()
        guard isInstalled else {
            needsInstall = true
            return "RustDesk n’est pas installé sur ce Mac."
        }
        let launch = RustDeskLaunch(connectionID: connection?.id, name: name, target: target.hostValue,
                                    endUser: connection?.endUser ?? "", site: connection?.folder ?? "")
        history = RustDeskHistory.adding(launch, to: history)
        save()
        if sandboxed {
            return "Démonstration\u{00A0}: RustDesk non lancé (\(RustDeskLink.displayURL(target)))."
        }
        // Mot de passe permanent : dans l'adresse remise par macOS à RustDesk (événement Apple),
        // jamais dans une ligne de commande ni dans le journal.
        let secret = connection.flatMap { password(for: $0.id) }
        guard let url = RustDeskLink.connectURL(target, password: secret) else { return "Adresse RustDesk invalide." }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let app = applicationURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
        return "Ouverture dans RustDesk\u{00A0}: \(name) (\(target.label))" + (secret == nil ? ", mot de passe demandé par RustDesk." : ".")
    }

    func launches(of id: UUID) -> [RustDeskLaunch] {
        RustDeskHistory.launches(of: id, in: history)
    }

    func clearHistory() {
        history = []
        save()
    }

    // MARK: Copies

    /// Message prêt à envoyer à l'usager (courriel, clavardage) ; nil sans lien d'assistance.
    var supportMessage: String? {
        let link = settings.supportPageURL.trimmingCharacters(in: .whitespaces)
        guard RustDeskServerSettings.validSupportURL(link) != nil else { return nil }
        return "Pour que je puisse vous aider à distance, ouvrez cette page et lancez l’outil d’assistance\u{00A0}: \(link)\n"
            + "Rien à installer. Donnez-moi ensuite le numéro (ID) et le mot de passe à usage unique affichés."
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Réglages

    /// « Importer depuis le nom du client portable » ; renvoie vrai si le nom a été compris.
    @discardableResult
    func importPortable(_ text: String) -> Bool {
        guard let portable = RustDeskPortableConfig.parse(text) else {
            notice = "Nom non reconnu\u{00A0}: attendu «\u{00A0}rustdesk-host=<serveur>,key=<clé>,.exe\u{00A0}»."
            return false
        }
        settings = settings.merging(portable)
        notice = "Réglages importés du nom du client portable\u{00A0}: serveur «\u{00A0}\(portable.host)\u{00A0}»"
            + (portable.key.isEmpty ? ", sans clé." : ", clé \(RustDeskKey.short(portable.key)).")
        return true
    }

    /// Lecture seule de ~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml.
    func checkClient() {
        refreshInstalled()
        let client: RustDeskClientConfig?
        if RegEnvironment.isDemo {
            client = RustDeskDemo.clientConfig
        } else if sandboxed {
            client = nil
        } else {
            client = (try? String(contentsOf: RustDeskClientConfig.defaultURL(), encoding: .utf8)).map(RustDeskClientConfig.parse)
        }
        var findings = RustDeskClientCheck.compare(settings, client: client)
        if !isInstalled {
            findings.insert(RustDeskFinding(.error, "RustDesk n’est pas installé sur ce Mac", "Téléchargez le client de bureau pour macOS (fichier .dmg)."), at: 0)
        }
        clientFindings = findings
        clientCheckedAt = Date()
    }

    /// « Tester le serveur » : seulement sur clic ; données fixes en démonstration et en capture.
    func testServer() {
        guard !testing, settings.idEndpoint != nil else { return }
        testing = true
        probes = []
        if sandboxed {
            let demo = RustDeskDemo.probes(settings)
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.probes = demo
                self.testing = false
                self.testedAt = Date()
            }
            return
        }
        let current = settings
        Task {
            let results = await RustDeskServerTest.run(current, timeout: 3)
            self.probes = results
            self.testing = false
            self.testedAt = Date()
            AppLog.shared.info("RustDesk", "Test du serveur \(current.idServer)\u{00A0}: " + results.map { "\($0.portLabel) \($0.ok ? "ok" : "échec")" }.joined(separator: ", "))
        }
    }

    /// VIP des FortiGate activées (GET /api/v2/cmdb/firewall/vip, aucune écriture).
    func checkVIPs() {
        guard !checkingVIPs else { return }
        checkingVIPs = true
        vipReports = []
        if sandboxed {
            let report = VIPReport(site: "Siège", findings: RustDeskVIPCheck.evaluate(RustDeskDemo.vips, settings: settings))
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.vipReports = [report]
                self.checkingVIPs = false
            }
            return
        }
        let fortigate = FortiGateStore.shared
        let current = settings
        Task {
            let picks = fortigate.enabledControllers.map {
                FortiControllerSelection.Pick(controllerID: $0.id, site: $0.displayName, reason: .activeSite)
            }
            let targets = await fortigate.wifiTargets(for: FortiControllerSelection(picks: picks))
            var reports: [VIPReport] = []
            for (id, message) in targets.blocked {
                reports.append(VIPReport(site: fortigate.controller(id)?.displayName ?? "FortiGate", findings: [], error: message))
            }
            for (controller, token) in targets.ready {
                let transport = FortiURLSessionTransport(config: controller.config, token: token)
                do {
                    let vips = try await RustDeskVIPCheck.read(transport: transport)
                    reports.append(VIPReport(site: controller.displayName, findings: RustDeskVIPCheck.evaluate(vips, settings: current)))
                } catch {
                    let text = (error as? LocalizedError)?.errorDescription ?? "Lecture des VIP impossible."
                    reports.append(VIPReport(site: controller.displayName, findings: [], error: FortiRedact.clean(text, token: token)))
                }
            }
            self.vipReports = reports.sorted { $0.site.localizedStandardCompare($1.site) == .orderedAscending }
            self.checkingVIPs = false
        }
    }

    var hasFortiGate: Bool { RegEnvironment.isDemo || !FortiGateStore.shared.enabledControllers.isEmpty }

    private func save() {
        guard let store else { return }
        do {
            try store.save(RustDeskStore.Contents(settings: settings, history: history))
        } catch {
            AppLog.shared.error("RustDesk", "Enregistrement impossible\u{00A0}: \(error.localizedDescription)")
        }
    }
}
