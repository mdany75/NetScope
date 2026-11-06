import Foundation
import NetScopeCore
import ServiceManagement

/// Note 64 : présence de l'app pour l'agent sans fenêtre. Au lancement, AVANT que la Surveillance et
/// les Journaux lisent leurs fichiers : app-ouverte.json est écrit, puis le verrou partagé est pris et
/// rendu (une écriture de l'agent déjà commencée se termine, aucune autre ne suit). Rafraîchie toutes
/// les 30 s, effacée à la fermeture : l'agent reprend la main. Rien en démonstration ni en capture.
enum AppPresenceKeeper {
    private static var timer: DispatchSourceTimer?

    static func launch() {
        guard !RegEnvironment.isSandboxed else { return }
        let files = AutomationFiles.standard
        refresh(files)
        _ = AutomationLock.with(files.lockURL, timeout: 15) { true }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { refresh(files) }
        timer.resume()
        self.timer = timer
    }

    static func quit() {
        guard !RegEnvironment.isSandboxed else { return }
        timer?.cancel()
        AppPresence.clear(.standard, pid: getpid())
    }

    private static func refresh(_ files: AutomationFiles) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        AppPresence(pid: getpid(), date: Date(), version: version).save(files)
    }
}

/// Note 64 : Réglages › Surveillance, agent en arrière-plan. Désactivé par défaut ; l'activer
/// enregistre le LaunchAgent du paquet (SMAppService), le désactiver le retire. L'état et le journal
/// sont ceux que l'agent écrit. En démonstration : état fictif, rien n'est enregistré.
@MainActor
final class AgentController: ObservableObject {
    static let shared = AgentController()

    @Published private(set) var serviceStatus: SMAppService.Status = .notRegistered
    @Published private(set) var status: AgentStatus?
    @Published private(set) var journal = AgentJournal()
    @Published var settings: AgentSettings {
        didSet {
            guard settings != oldValue, !isDemo else { return }
            try? settings.save(files)
        }
    }
    @Published var message: String?

    let isDemo: Bool
    private let files = AutomationFiles.standard
    private let service = SMAppService.agent(plistName: AutomationFiles.agentPlistName)

    private init() {
        isDemo = RegEnvironment.isSandboxed
        if isDemo {
            serviceStatus = .enabled
            status = AutomationDemo.agentStatus
            journal = AutomationDemo.agentJournal
            settings = AgentSettings()
        } else {
            settings = AgentSettings.load(AutomationFiles.standard)
            refresh()
        }
    }

    var now: Date { isDemo ? AutomationDemo.now : Date() }
    var isEnabled: Bool { serviceStatus == .enabled || serviceStatus == .requiresApproval }

    /// Relit l'état du service et les fichiers de l'agent.
    func refresh() {
        guard !isDemo else { return }
        serviceStatus = service.status
        status = AgentStatus.load(files)
        journal = AgentJournal.load(files)
    }

    func setEnabled(_ enabled: Bool) {
        guard !isDemo else { return }
        guard UpdInstaller.runningBundle() != nil else {
            message = "Disponible seulement pour l’application installée (.app), pas avec swift run."
            return
        }
        do {
            if enabled {
                try settings.save(files)
                try service.register()
            } else {
                try service.unregister()
            }
            message = nil
        } catch {
            message = "Modification refusée par macOS\u{00A0}: \(error.localizedDescription)"
        }
        refresh()
        if service.status == .requiresApproval {
            message = "À autoriser dans Réglages Système › Général › Ouverture (« Autoriser en arrière-plan »)."
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// « Actif (NetScope est fermé) », « En attente (NetScope est ouvert) », « Ne répond pas »…
    var stateLabel: (text: String, tone: Tone) {
        switch serviceStatus {
        case .notRegistered, .notFound: return ("Désactivé", .neutral)
        case .requiresApproval: return ("À autoriser dans Réglages Système", .warning)
        default: break
        }
        guard let status else { return ("Démarrage…", .neutral) }
        guard status.isResponding(now: now) else { return ("Ne répond pas", .critical) }
        return (status.mode.label, status.mode == .active ? .success : .neutral)
    }
}
