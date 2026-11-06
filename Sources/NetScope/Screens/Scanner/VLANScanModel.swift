import Foundation
import NetScopeCore

/// Note 90 : scanner un VLAN tagué depuis le Mac, branché sur un port en trunk. Interface 802.1Q
/// temporaire (networksetup, droits administrateur demandés par macOS), adresse par DHCP ou IP
/// fixe, scan du sous-réseau, puis retrait GARANTI : fin, erreur, annulation, fermeture de l'app,
/// et restes retirés au lancement suivant (trace dans Application Support).
///
/// En démonstration et pendant les captures, rien n'est créé ni scanné : déroulement simulé.
@MainActor
final class VLANScanModel: ObservableObject {
    static let shared = VLANScanModel()

    enum Phase: Equatable {
        case idle, creating, waitingAddress, scanning, removing
        case finished(String)
        case failed(String)

        var isRunning: Bool { [.creating, .waitingAddress, .scanning, .removing].contains(self) }

        var label: String {
            switch self {
            case .idle: return "Prêt"
            case .creating: return "Création de l’interface (autorisation de macOS)…"
            case .waitingAddress: return "Obtention d’une adresse…"
            case .scanning: return "Scan du VLAN…"
            case .removing: return "Retrait de l’interface…"
            case .finished(let text), .failed(let text): return text
            }
        }
    }

    @Published var isPresented = false
    @Published var vlanText = ""
    @Published var useDHCP = true
    @Published var fixedAddress = ""
    @Published var fixedPrefix = 24
    @Published var fixedRouter = ""
    @Published var parent = "en0"
    @Published private(set) var phase: Phase = .idle
    /// Adresse obtenue et sous-réseau scanné (« 10.0.20.57 · 10.0.20.0/24 »).
    @Published private(set) var obtained: String?

    let isDemo: Bool
    private var task: Task<Void, Never>?
    /// Interface créée et pas encore retirée.
    private var created: VLANEntry?

    init(demo: Bool = Launcher.isDemo || CommandLine.arguments.contains("--snapshot")) {
        isDemo = demo
        if demo {
            vlanText = "20"
            parent = "en0"
            if ProcessInfo.processInfo.environment["NETSCOPE_VLAN_FEUILLE"] == "scan" {
                phase = .scanning
                obtained = "10.182.20.57 · 10.182.20.0/24"
            }
        }
    }

    static var ledgerURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent(VLANScanLedger.fileName)
    }

    // MARK: Ethernet et VLAN proposés

    /// Interfaces Ethernet (en0, en7…) avec une adresse ou un lien.
    var ethernetChoices: [String] {
        if isDemo { return ["en0", "en7"] }
        let names = LocalInterfaces.linkInterfaces().map(\.name).filter(VLANScanRequest.isValidParent)
        let unique = Array(Set(names + [parent])).filter(VLANScanRequest.isValidParent)
        return unique.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// VLAN vus par LLDP/CDP, sur la FortiGate et sur les switchs relevés.
    func proposals() -> [VLANProposal] {
        if isDemo {
            return VLANProposal.merge([(10, "LLDP"), (20, "LLDP (voix)"), (20, "FortiGate Siège"), (30, "SW-CORE-01"), (99, "SW-CORE-01")])
        }
        var seen: [(vlan: Int, source: String)] = []
        if let neighbor = ToolStore.shared.neighbors.lastNeighbor {
            if let v = neighbor.nativeVLAN { seen.append((v, "LLDP/CDP")) }
            if let v = neighbor.voiceVLAN { seen.append((v, "LLDP/CDP (voix)")) }
        }
        for site in FortiGateStore.shared.sites {
            for v in Set(site.report.detected.compactMap(\.vlan)) { seen.append((v, "FortiGate \(site.site)")) }
        }
        for snapshot in SwitchStore.shared.orderedSnapshots.prefix(20) {
            for v in Set(snapshot.fdb.compactMap(\.vlan)) { seen.append((v, snapshot.displayName)) }
        }
        return VLANProposal.merge(seen)
    }

    // MARK: Demande

    /// Demande validée (nil et message si la saisie est refusée).
    func validatedRequest() -> Result<VLANScanRequest, VLANScanInputError> {
        guard let vlan = VLANScanRequest.parseID(vlanText) else {
            return .failure(VLANScanInputError(message: "Numéro de VLAN de 1 à 4094."))
        }
        let addressing: VLANAddressing
        if useDHCP {
            addressing = .dhcp
        } else {
            guard let address = IPv4Address(fixedAddress.trimmingCharacters(in: .whitespaces)),
                  let router = IPv4Address(fixedRouter.trimmingCharacters(in: .whitespaces)) else {
                return .failure(VLANScanInputError(message: "Adresse fixe et passerelle à saisir (ex. 10.0.20.250 et 10.0.20.1)."))
            }
            addressing = .manual(address: address, prefix: fixedPrefix, router: router)
        }
        do { return .success(try VLANScanRequest(vlan: vlan, parent: parent, addressing: addressing)) } catch let error as VLANScanInputError {
            return .failure(error)
        } catch { return .failure(VLANScanInputError(message: error.localizedDescription)) }
    }

    func start(_ state: AppState) {
        guard !phase.isRunning, case .success(let request) = validatedRequest() else { return }
        obtained = nil
        if isDemo {
            AppLog.shared.info("VLAN", "Démonstration\u{00A0}: VLAN \(request.vlan) simulé, aucune interface créée.")
            task = Task { [weak self] in await self?.simulate(request) }
            return
        }
        guard !ScanController.shared.isRunning else {
            phase = .failed("Un scan est déjà en cours\u{00A0}: attendez sa fin.")
            return
        }
        task = Task { [weak self] in await self?.run(request, state: state) }
    }

    /// Annuler : le scan s'arrête, l'interface est retirée quand même.
    func cancel() {
        task?.cancel()
        if ScanController.shared.isRunning { ScanController.shared.stop() }
    }

    // MARK: Déroulement réel

    private func run(_ request: VLANScanRequest, state: AppState) async {
        AppLog.shared.warning("VLAN", "Scan du VLAN tagué \(request.vlan) sur \(request.parent)\u{00A0}: création de \(request.name).")
        // Trace AVANT la création : un arrêt brutal pendant le scan laisse de quoi nettoyer.
        let entry = VLANEntry(name: request.name, parent: request.parent, tag: request.vlan)
        remember(entry)
        phase = .creating
        if let error = await VLANScanRunner.runPrivileged(VLANScanCommands.createScript(request),
                                                         prompt: VLANScanCommands.prompt(creating: request)) {
            // Rien de créé si l'autorisation est refusée ; sinon (création faite, adressage en échec) on retire.
            let existing = await VLANScanRunner.listVLANs().filter { $0.name == request.name && $0.isNetScope }
            if !existing.isEmpty { created = existing.first; await remove() } else { forget() }
            phase = .failed("Création impossible\u{00A0}: \(error)")
            AppLog.shared.error("VLAN", "Création de \(request.name) impossible\u{00A0}: \(error)")
            return
        }
        let listed = await VLANScanRunner.listVLANs().first { $0.name == request.name }
        created = listed ?? entry
        var message: String
        do {
            phase = .waitingAddress
            let iface = try await waitAddress(device: listed?.device ?? "")
            guard let cidr = VLANScanPlan.range(address: iface.address, netmask: iface.netmask) else {
                throw VLANScanInputError(message: "Masque reçu inutilisable.")
            }
            obtained = "\(iface.address) · \(cidr)"
            try Task.checkCancellation()
            phase = .scanning
            let range = ScanRangeConfig(text: cidr, label: "VLAN \(request.vlan) (tagué)", vlan: request.vlan)
            ScanController.shared.start(state, onlyRanges: [range])
            while ScanController.shared.isRunning {
                if Task.isCancelled { ScanController.shared.stop() }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            message = Task.isCancelled ? "Scan du VLAN \(request.vlan) annulé" : "VLAN \(request.vlan) scanné (\(cidr))"
        } catch is CancellationError {
            message = "Scan du VLAN \(request.vlan) annulé"
        } catch {
            message = "VLAN \(request.vlan)\u{00A0}: \((error as? VLANScanInputError)?.message ?? error.localizedDescription)"
        }
        let removalError = await remove()
        if let removalError {
            phase = .failed("\(message) · interface NON retirée\u{00A0}: \(removalError) (nouvel essai au prochain lancement)")
        } else {
            phase = message.contains("scanné") ? .finished(message + " · interface retirée") : .failed(message + " · interface retirée")
        }
    }

    /// Attend une adresse IPv4 utilisable sur l'interface VLAN (30 s au plus).
    private func waitAddress(device: String) async throws -> LocalInterface {
        for _ in 0..<60 {
            try Task.checkCancellation()
            if !device.isEmpty, let iface = LocalInterfaces.list().first(where: { $0.name == device && $0.hasIPv4 }),
               !VLANScanPlan.isSelfAssigned(iface.address) {
                return iface
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw VLANScanInputError(message: "aucune adresse reçue en 30\u{00A0}s (DHCP muet sur ce VLAN, ou port qui ne le transporte pas).")
    }

    /// Retire l'interface créée ; nil si c'est fait.
    @discardableResult
    private func remove() async -> String? {
        guard let entry = created, let script = VLANScanCommands.deleteScript([entry]) else { forget(); return nil }
        phase = .removing
        let error = await VLANScanRunner.runPrivileged(script, prompt: VLANScanCommands.removalPrompt)
        if let error {
            AppLog.shared.error("VLAN", "Retrait de \(entry.name) impossible\u{00A0}: \(error)")
            return error
        }
        created = nil
        forget()
        AppLog.shared.info("VLAN", "Interface \(entry.name) retirée.")
        return nil
    }

    private func remember(_ entry: VLANEntry) {
        guard let url = Self.ledgerURL else { return }
        var list = VLANScanLedger.load(from: url).filter { $0 != entry }
        list.append(entry)
        VLANScanLedger.save(list, to: url)
    }

    private func forget() {
        guard let url = Self.ledgerURL else { return }
        VLANScanLedger.save([], to: url)
    }

    // MARK: Fermeture de l'app et lancement suivant

    /// Fermeture de l'app : l'interface encore présente est retirée avant de quitter.
    func removeOnQuit() {
        guard !isDemo, let entry = created, let script = VLANScanCommands.deleteScript([entry]) else { return }
        task?.cancel()
        if VLANScanRunner.runPrivilegedNow(script, prompt: VLANScanCommands.removalPrompt) == nil {
            created = nil
            forget()
        }
    }

    /// Lancement : restes d'un arrêt brutal (trace présente) retirés.
    func cleanupLeftovers() {
        guard !isDemo, !RegEnvironment.isSandboxed, let url = Self.ledgerURL, !VLANScanLedger.load(from: url).isEmpty else { return }
        Task {
            let leftovers = await VLANScanRunner.listVLANs().filter(\.isNetScope)
            guard let script = VLANScanCommands.deleteScript(leftovers) else { forget(); return }
            AppLog.shared.warning("VLAN", "Interface VLAN temporaire restée d’une session précédente\u{00A0}: retrait.")
            if let error = await VLANScanRunner.runPrivileged(script, prompt: VLANScanCommands.removalPrompt) {
                AppLog.shared.error("VLAN", "Restes non retirés\u{00A0}: \(error)")
            } else {
                forget()
            }
        }
    }

    // MARK: Démonstration

    private func simulate(_ request: VLANScanRequest) async {
        for (phase, delay) in [(Phase.creating, 0.6), (.waitingAddress, 0.8), (.scanning, 1.5), (.removing, 0.5)] {
            self.phase = phase
            if phase == .scanning { obtained = "10.182.\(min(request.vlan, 254)).57 · 10.182.\(min(request.vlan, 254)).0/24" }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        phase = .finished("Démonstration\u{00A0}: VLAN \(request.vlan) simulé, aucune interface créée ni scan lancé")
    }
}
