import Foundation
import NetScopeCore

/// Vérificateur de certificat TLS de la Boîte à outils (note 70) : un serveur à la fois (chaîne,
/// versions, verdict de macOS), ou tous les HTTPS du dernier scan sur demande. Le seuil d'alerte
/// est retenu dans les préférences (pas en démonstration ni en capture).
@MainActor
final class TLSCheckModel: ObservableObject {
    static let shared = TLSCheckModel()

    @Published var host = ""
    @Published var port = "443" {
        didSet { if !modeChosen, let value = UInt16(port.trimmingCharacters(in: .whitespaces)) { mode = TLSPortPreset.mode(for: value) } }
    }
    @Published var serverName = ""
    @Published var mode: TLSStartMode = .direct
    /// Vrai une fois le mode choisi à la main (le port ne le change plus).
    private var modeChosen = false
    @Published var warningDays: Int {
        didSet { if !isEphemeral { UserDefaults.standard.set(warningDays, forKey: Self.thresholdKey) } }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var inspection: TLSInspection?
    /// Certificat de la chaîne montré en détail (0 : celui du serveur).
    @Published var selectedCertificate = 0
    @Published var error: String?

    // Vérification de tout le site
    @Published private(set) var sweepRunning = false
    @Published private(set) var sweepDone = 0
    @Published private(set) var sweepTotal = 0
    @Published private(set) var sweepResults: [TLSInspection] = []
    @Published private(set) var sweepDate: Date?
    @Published var sweepOnlyProblems = true
    @Published var sweepNotice: String?

    static let thresholds = [7, 14, 30, 60, 90]
    private static let thresholdKey = "outils.tls.seuil"

    let isDemo: Bool
    private let isEphemeral: Bool
    private var task: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?
    private var generation = 0
    /// Numéro du balayage en cours : les sondes d'un balayage arrêté ne touchent pas au suivant.
    private var sweepGeneration = 0

    private init() {
        let arguments = CommandLine.arguments
        isDemo = arguments.contains("--demo")
        isEphemeral = isDemo || arguments.contains("--snapshot")
        let saved = isEphemeral ? 0 : UserDefaults.standard.integer(forKey: Self.thresholdKey)
        warningDays = saved > 0 ? saved : TLSExpiry.defaultWarningDays
        if isDemo { loadDemo() }
    }

    func chooseMode(_ value: TLSStartMode) {
        modeChosen = true
        mode = value
    }

    func choosePreset(_ preset: TLSPortPreset) {
        modeChosen = false
        port = "\(preset.port)"
        mode = preset.mode
    }

    var portValue: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)) }

    /// Commande équivalente (en-tête de l'outil).
    var command: String {
        let target = host.trimmingCharacters(in: .whitespaces)
        let sni = serverName.trimmingCharacters(in: .whitespaces)
        var parts = ["openssl s_client -connect \(target.isEmpty ? "<hôte>" : target):\(portValue.map(String.init) ?? "443")"]
        if !sni.isEmpty { parts.append("-servername \(sni)") }
        switch mode {
        case .direct: break
        case .smtp: parts.append("-starttls smtp")
        case .imap: parts.append("-starttls imap")
        case .pop3: parts.append("-starttls pop3")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Un serveur

    func run(store: ToolStore) {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
            error = "Saisir une adresse IP ou un nom d’hôte."
            return
        }
        guard !target.contains(where: { $0 == "/" || $0 == " " }) else {
            error = "Une seule cible\u{00A0}: adresse IP ou nom d’hôte, sans https://."
            return
        }
        guard let port = portValue, port > 0 else {
            error = "Port invalide (1 à 65\u{202F}535)."
            return
        }
        cancel()
        generation += 1
        let run = generation
        error = nil
        isRunning = true
        selectedCertificate = 0
        let sni = serverName.trimmingCharacters(in: .whitespaces)
        let mode = self.mode
        store.record(command: command)
        task = Task { [weak self] in
            guard let self else { return }
            let result: TLSInspection
            if self.isDemo {
                try? await Task.sleep(nanoseconds: 600_000_000)
                result = TLSDemo.inspection(host: target, port: port, serverName: sni.isEmpty ? nil : sni, mode: mode)
            } else {
                result = await TLSProbe.inspect(host: target, port: port, serverName: sni.isEmpty ? nil : sni, mode: mode)
            }
            guard run == self.generation else { return }
            self.finish(result, store: store)
        }
    }

    private func finish(_ result: TLSInspection, store: ToolStore) {
        isRunning = false
        inspection = result
        let verdict = TLSAnalysis.verdict(result, warningDays: warningDays)
        let expiry = TLSAnalysis.expiry(result, warningDays: warningDays)
        let summary = result.leaf == nil ? (result.error ?? "Aucun certificat")
            : [verdict.label, expiry?.label, result.negotiatedVersion?.label].compactMap { $0 }.joined(separator: " · ")
        store.record(ToolRecent(tool: .tls, target: result.endpoint, summary: summary, status: verdict.level.recentStatus))
    }

    func cancel() {
        guard isRunning else { return }
        generation += 1
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Montre un résultat de la vérification du site dans la partie principale.
    func show(_ result: TLSInspection) {
        cancel()
        host = result.host
        modeChosen = false
        port = "\(result.port)"
        serverName = result.serverName ?? ""
        inspection = result
        selectedCertificate = 0
        error = nil
    }

    // MARK: Tous les HTTPS du site

    func sweep(devices: [Device]) {
        guard !sweepRunning else { return }
        // Plages exclues du site (note 82) : jamais de poignée TLS vers ces adresses, même si
        // le dernier scan les montre encore en ligne (leur dernier état connu reste).
        let site = SiteModel.shared
        let targets = isDemo ? TLSDemo.siteTargets : TLSSiteSweep.targets(from: devices).filter { target in
            IPv4Address(target.host).map { site.exclusionReason($0) == nil } ?? true
        }
        sweepNotice = nil
        guard !targets.isEmpty else {
            sweepNotice = "Aucun appareil du dernier scan n’a le port 443 ou 8443 ouvert. Lancer un scan avec ces ports, puis recommencer."
            return
        }
        sweepRunning = true
        sweepDone = 0
        sweepTotal = targets.count
        sweepResults = []
        sweepGeneration += 1
        let sweep = sweepGeneration
        let demo = isDemo
        sweepTask = Task { [weak self] in
            let results = await TLSSiteSweep.run(targets, probe: { target in
                if demo {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    return TLSDemo.inspection(host: target.host, port: target.port, serverName: nil, mode: .direct)
                }
                return await TLSProbe.inspect(host: target.host, port: target.port, timeout: 6, testVersions: false)
            }, progress: { done, total in
                Task { @MainActor in
                    let model = TLSCheckModel.shared
                    if model.sweepRunning, model.sweepGeneration == sweep { model.sweepDone = max(model.sweepDone, done) }
                }
            })
            guard let self, !Task.isCancelled, sweep == self.sweepGeneration else { return }
            self.sweepResults = results
            self.sweepDate = Date()
            self.sweepRunning = false
        }
    }

    func cancelSweep() {
        sweepTask?.cancel()
        sweepTask = nil
        sweepGeneration += 1
        sweepRunning = false
        sweepNotice = "Vérification du site arrêtée."
    }

    var sweepAttention: [TLSInspection] { TLSSiteSweep.attention(sweepResults, warningDays: warningDays) }

    // MARK: Démonstration

    private func loadDemo() {
        host = TLSDemo.defaultHost
        port = "443"
        // Captures : NETSCOPE_TLS_DEMO=site montre la vérification du site sans résultat au-dessus.
        if ProcessInfo.processInfo.environment["NETSCOPE_TLS_DEMO"] != "site" {
            inspection = TLSDemo.inspection(host: TLSDemo.defaultHost, port: 443, serverName: nil, mode: .direct)
        }
        sweepResults = TLSDemo.siteResults()
        sweepDate = Date().addingTimeInterval(-6 * 60)
    }
}
