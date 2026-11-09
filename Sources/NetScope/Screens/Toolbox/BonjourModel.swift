import Foundation
import NetScopeCore

/// Navigateur Bonjour de la Boîte à outils (note 118) : une découverte de 30 s, sur clic seulement.
@MainActor
final class BonjourModel: ObservableObject {
    static let shared = BonjourModel()
    static let duration = 30
    static let command = "dns-sd -B \(BonjourCatalog.enumerationType) local."

    @Published var filter = ""
    @Published var grouping = BonjourGrouping.device
    @Published var selection: String?
    @Published private(set) var isRunning = false
    @Published private(set) var elapsed = 0
    @Published private(set) var services: [BonjourService] = []
    @Published private(set) var isDenied = false
    /// Vrai une fois une découverte terminée : distingue « rien trouvé » de « pas encore lancé ».
    @Published private(set) var hasRun = false
    @Published private(set) var stoppedEarly = false

    let isDemo: Bool
    private var browser: BonjourBrowser?
    private var task: Task<Void, Never>?
    private var store: ToolStore?

    private init() {
        let arguments = CommandLine.arguments
        isDemo = arguments.contains("--demo") || arguments.contains("--snapshot")
        guard arguments.contains("--demo") else { return }
        switch ProcessInfo.processInfo.environment["NETSCOPE_BONJOUR_DEMO"] {
        case "vide": break
        case "aucun": hasRun = true
        case "arret":
            hasRun = true
            stoppedEarly = true
            elapsed = 2
        case "refus":
            hasRun = true
            isDenied = true
        case let demo:
            if demo == "type" { grouping = .type }
            services = BonjourDemo.services
            selection = BonjourDemo.selectedID
            hasRun = true
        }
    }

    var groups: [BonjourGroup] { grouping.groups(BonjourFilter.apply(services, query: filter)) }
    var selected: BonjourService? { services.first { $0.id == selection } }
    var deviceCount: Int { Set(services.compactMap { $0.hostName?.lowercased() }).count }
    var typeCount: Int { Set(services.map(\.type)).count }

    func run(store: ToolStore) {
        guard !isRunning else { return }
        self.store = store
        services = []
        selection = nil
        isDenied = false
        stoppedEarly = false
        elapsed = 0
        isRunning = true
        store.record(command: Self.command)
        if !isDemo { startBrowser() }
        task = Task { [weak self] in
            for second in 1 ... Self.duration {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.elapsed = second
                if self.isDemo, second == 1 { self.services = BonjourDemo.services }
            }
            self?.finish()
        }
    }

    private func startBrowser() {
        let browser = BonjourBrowser()
        browser.onChange = { [weak self] found in self?.services = found }
        browser.onDenied = { [weak self] in self?.isDenied = true }
        self.browser = browser
        browser.start()
    }

    /// Arrêter garde ce qui a déjà été trouvé.
    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        stoppedEarly = true
        finish()
    }

    private func finish() {
        task = nil
        browser?.stop()
        browser = nil
        isRunning = false
        hasRun = true
        // Une écoute interrompue sans résultat ne dit rien du réseau.
        guard !(stoppedEarly && services.isEmpty) else { return }
        let status: ToolRecent.Status = isDenied ? .failure : services.isEmpty ? .warning : .ok
        let summary = isDenied ? "Autorisation Réseau local manquante"
            : "\(services.count) service\(services.count > 1 ? "s" : "") sur \(deviceCount) appareil\(deviceCount > 1 ? "s" : "")"
        store?.record(ToolRecent(tool: .bonjour, target: "local.", summary: summary, status: status))
    }
}
