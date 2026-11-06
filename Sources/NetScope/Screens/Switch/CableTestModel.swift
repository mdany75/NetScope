import Foundation
import NetScopeCore

/// Note 89 : test de câble (TDR) demandé au switch. Réglage « Autoriser le test de câble »
/// DÉSACTIVÉ par défaut (Réglages › Switchs, avec les actions sur les ports), garde-fous de
/// `CableTestGuard` (uplink, port de ce Mac, contrôleur en lecture seule, marque, port strict),
/// confirmation qui dit que le lien peut tomber, trace au journal, résultat gardé dans
/// l'historique du port (tests-cable.json du site) et ajouté au bilan de raccordement.
///
/// En démonstration et pendant les captures, rien n'est envoyé : résultat simulé.
@MainActor
final class CableTestModel: ObservableObject {
    static let shared = CableTestModel()
    static let logModule = "Test de câble"

    struct Request: Identifiable, Equatable {
        let id = UUID()
        var target: PortActionTarget
        var decision: CableTestDecision
    }

    @Published var request: Request?
    @Published private(set) var running: Set<String> = []
    @Published private(set) var histories: [String: CableTestHistory] = [:]

    let isDemo: Bool

    init(demo: Bool = Launcher.isDemo || CommandLine.arguments.contains("--snapshot")) {
        isDemo = demo
    }

    static func key(_ target: PortActionTarget) -> String { "\(target.switchName)|\(target.portName)".lowercased() }

    // MARK: Marque et identifiant SSH (ceux des sauvegardes de configuration)

    private func equipment(_ snapshot: SNMPSwitchSnapshot) -> ConfigEquipment {
        var equipment = ConfigEquipment(name: snapshot.displayName, host: snapshot.host.description,
                                        kind: ConfigDeviceKind.detect(descr: snapshot.system.descr, name: snapshot.displayName))
        if equipment.kind == .fortigate { equipment.kind = .fortiswitch }
        return equipment
    }

    func vendor(_ snapshot: SNMPSwitchSnapshot) -> (vendor: CableTestVendor?, name: String?) {
        let kind = ConfigBackupModel.shared.kind(of: equipment(snapshot))
        return (CableTestVendor.from(kind), kind?.label ?? SwitchText.brand(snapshot))
    }

    func decision(_ target: PortActionTarget, snapshot: SNMPSwitchSnapshot) -> CableTestDecision {
        let (vendor, name) = vendor(snapshot)
        let hasAccount = isDemo || ConfigBackupModel.shared.credentialID(of: equipment(snapshot)) != nil
        var settings = PortActionModel.shared.settings
        if isDemo, ProcessInfo.processInfo.environment["NETSCOPE_TEST_CABLE"] != "0" { settings.cableTestEnabled = true }
        return CableTestGuard.decide(target: target, settings: settings, vendor: vendor, vendorName: name, hasSSHAccount: hasAccount,
                                     fortiGateProblem: PortActionModel.shared.fortiGateProblem(target.fortiGate),
                                     busy: running.contains(Self.key(target)))
    }

    var isEnabled: Bool {
        PortActionModel.shared.settings.cableTestEnabled || (isDemo && ProcessInfo.processInfo.environment["NETSCOPE_TEST_CABLE"] != "0")
    }

    /// Ouvre la confirmation (rien n'est envoyé ici).
    func ask(snapshot: SNMPSwitchSnapshot, iface: SNMPInterface, state: AppState) {
        let target = PortActionModel.shared.target(snapshot: snapshot, iface: iface, state: state)
        let decision = decision(target, snapshot: snapshot)
        guard decision.isAllowed else {
            if let reason = decision.reason { AppLog.shared.info(Self.logModule, "Test refusé sur \(target.portLabel)\u{00A0}: \(reason)") }
            return
        }
        request = Request(target: target, decision: decision)
    }

    // MARK: Historique (par site)

    private var siteKey: String { SiteModel.shared.activeKey }

    private func historyURL(_ key: String) -> URL? {
        SiteModel.shared.files.map { CableTestHistory.url(in: $0, siteKey: key) }
    }

    func history(switchName: String, port: String) -> [CableTestResult] {
        if isDemo { return CableTestDemo.history(switchName: switchName, port: port) }
        let key = siteKey
        if histories[key] == nil, let url = historyURL(key) { histories[key] = CableTestHistory.load(from: url) }
        return histories[key]?.results(switchName: switchName, port: port) ?? []
    }

    /// Dernier test de ce port depuis `since` (bilan de raccordement).
    func latest(switchName: String, port: String, since: Date) -> CableTestResult? {
        history(switchName: switchName, port: port).first { $0.date >= since }
    }

    private func store(_ result: CableTestResult) {
        guard !isDemo else { return }
        let key = siteKey
        var history = histories[key] ?? historyURL(key).map(CableTestHistory.load) ?? CableTestHistory()
        history.add(result)
        histories[key] = history
        if !RegEnvironment.isSandboxed, let url = historyURL(key) {
            do { try history.save(to: url) } catch {
                AppLog.shared.error(Self.logModule, "Historique non enregistré\u{00A0}: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Exécution

    func perform(_ request: Request, acknowledged: Bool, snapshot: SNMPSwitchSnapshot?) {
        self.request = nil
        let target = request.target
        let decision = snapshot.map { self.decision(target, snapshot: $0) } ?? request.decision
        guard decision.isAllowed, let channel = decision.channel, decision.warnings.isEmpty || acknowledged else {
            AppLog.shared.warning(Self.logModule, "Test refusé sur \(target.portLabel)\u{00A0}: \(decision.reason ?? "confirmation manquante")")
            return
        }
        let key = Self.key(target)
        running.insert(key)
        AppLog.shared.warning(Self.logModule, "Test de câble demandé sur \(target.portLabel) · \(target.deviceLabel) · par \(channel.label)")
        let equipment = snapshot.map(self.equipment)
        Task { [weak self] in
            guard let self else { return }
            let result: CableTestResult
            if self.isDemo || RegEnvironment.isSandboxed {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                result = CableTestDemo.result(target: target, channel: channel)
            } else {
                result = await self.execute(target: target, channel: channel, equipment: equipment)
            }
            self.running.remove(key)
            self.store(result)
            if result.error == nil {
                AppLog.shared.info(Self.logModule, "\(target.portLabel)\u{00A0}: \(result.headline)")
            } else {
                AppLog.shared.error(Self.logModule, "\(target.portLabel)\u{00A0}: \(result.headline)")
            }
        }
    }

    private func execute(target: PortActionTarget, channel: CableTestChannel, equipment: ConfigEquipment?) async -> CableTestResult {
        let start = Date()
        func make(_ pairs: [CablePairResult], vendor: CableTestVendor, error: String? = nil) -> CableTestResult {
            CableTestResult(date: start, switchName: target.switchName, switchHost: target.switchHost?.description ?? "",
                            portName: target.portName, vendor: vendor, channel: channel.label, pairs: pairs, error: error)
        }
        switch channel {
        case .ssh(let host, let vendor):
            guard let equipment, let id = ConfigBackupModel.shared.credentialID(of: equipment),
                  let credential = RegRemoteCredentialStore.shared.credentials.first(where: { $0.id == id }) else {
                return make([], vendor: vendor, error: CableTestRefusal.noSSHAccount.message)
            }
            let sshTarget = ConfigSSHTarget(credential: credential, host: host)
            let service = RemoteCredential.keychainService(.ssh), account = credential.keychainAccount
            let port = target.portName
            let output = await Task.detached(priority: .userInitiated) {
                let secret = UpdKeychain(service: service).string(for: account)
                return await CableTestSSH.run(sshTarget, vendor: vendor, port: port, secret: secret) { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                }
            }.value
            switch output {
            case .failure(let error): return make([], vendor: vendor, error: "\(error.title) · \(error.detail)")
            case .success(let text):
                switch CableTestParser.parse(text, vendor: vendor, port: port) {
                case .success(let pairs): return make(pairs, vendor: vendor)
                case .failure(let error): return make([], vendor: vendor, error: error.message)
                }
            }
        case .fortiGate(let id, _, let switchID):
            let store = FortiGateStore.shared
            await store.loadTokens()
            guard let controller = store.controller(id) else { return make([], vendor: .fortiSwitch, error: "FortiGate absente des Réglages.") }
            let pick = FortiControllerSelection.Pick(controllerID: id, site: controller.displayName, reason: .activeSite)
            guard let token = await store.wifiTargets(for: FortiControllerSelection(picks: [pick])).ready.first?.1 else {
                return make([], vendor: .fortiSwitch, error: store.notReadyReason(controller) ?? "Jeton de la FortiGate absent.")
            }
            let writer = FortiURLSessionWriter(config: controller.config, token: token)
            let request = FortiWriteRequest(method: "GET", path: CableTestCommands.fortiGatePath,
                                            query: CableTestCommands.fortiGateQuery(switchID: switchID, port: target.portName, vdom: controller.config.vdom),
                                            body: Data())
            do {
                let response = try await writer.send(request)
                if let error = FortiPortActions.interpret(response, path: request.path) {
                    return make([], vendor: .fortiSwitch, error: error.errorDescription ?? "Réponse inattendue de la FortiGate.")
                }
                switch CableTestParser.fortiGate(response.body) {
                case .success(let pairs): return make(pairs, vendor: .fortiSwitch)
                case .failure(let error): return make([], vendor: .fortiSwitch, error: error.message)
                }
            } catch {
                return make([], vendor: .fortiSwitch, error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

/// Démonstration : résultats fictifs (aucune commande envoyée).
enum CableTestDemo {
    /// Port qui montre un défaut (« Gi1/0/12 », « port12 », « 12 »…) : un sur cinq environ.
    static func isFaulty(_ port: String) -> Bool {
        let digits = port.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) } ?? 0
        return digits % 5 == 2
    }

    static func pairs(port: String) -> [CablePairResult] {
        let length = 18 + (port.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 40)
        if isFaulty(port) {
            return [1, 2, 3, 4].map { CablePairResult(pair: $0, status: $0 == 3 ? .open : .ok, meters: $0 == 3 ? 27 : length) }
        }
        return [1, 2, 3, 4].map { CablePairResult(pair: $0, status: .ok, meters: length) }
    }

    static func result(target: PortActionTarget, channel: CableTestChannel) -> CableTestResult {
        let vendor: CableTestVendor
        switch channel {
        case .ssh(_, let v): vendor = v
        case .fortiGate: vendor = .fortiSwitch
        }
        return CableTestResult(date: Date(), switchName: target.switchName, switchHost: target.switchHost?.description ?? "",
                               portName: target.portName, vendor: vendor, channel: channel.label, pairs: pairs(port: target.portName))
    }

    /// Historique fictif : un test il y a deux heures et un plus ancien.
    static func history(switchName: String, port: String) -> [CableTestResult] {
        let now = Date()
        let latest = CableTestResult(date: now.addingTimeInterval(-7_200), switchName: switchName, switchHost: "", portName: port,
                                     vendor: .cisco, channel: "SSH (Cisco)", pairs: pairs(port: port))
        let older = CableTestResult(date: now.addingTimeInterval(-86_400 * 12), switchName: switchName, switchHost: "", portName: port,
                                    vendor: .cisco, channel: "SSH (Cisco)",
                                    pairs: [1, 2, 3, 4].map { CablePairResult(pair: $0, status: .ok, meters: 31) })
        return [latest, older]
    }
}
