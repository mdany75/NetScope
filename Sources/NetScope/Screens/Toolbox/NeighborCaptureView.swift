import NetScopeCore
import SwiftUI

/// Capture LLDP/CDP : écoute passive des annonces du switch voisin (où ce Mac est branché).
///
/// Accès aux trames brutes : /dev/bpf* s'il est déjà ouvrable (ChmodBPF de Wireshark), sinon
/// tcpdump lancé une seule fois avec les droits d'administrateur (fenêtre de macOS). Rien n'est
/// envoyé sur le réseau. Le dernier voisin est gardé dans les préférences pour Switchs et ports.
@MainActor
final class ToolNeighborModel: ObservableObject {
    enum Phase: Equatable {
        case idle, authorizing, listening, finished
    }

    enum Method {
        case bpf, privileged, demo
    }

    @Published var interfaces: [LocalInterface] = []
    @Published var interfaceName = ""
    @Published var duration = 90
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var deadline: Date?
    @Published private(set) var startedAt: Date?
    /// Voisins de la capture en cours (ou de la dernière).
    @Published private(set) var neighbors: [NetworkNeighbor] = []
    /// Dernier voisin reçu, gardé entre les lancements (encart de Switchs et ports).
    @Published private(set) var lastNeighbor: NetworkNeighbor?
    /// Réseau de la dernière capture (interface, sous-réseau, passerelle), gardé avec le voisin :
    /// l'encart de Switchs et ports se grise si ce réseau a changé.
    @Published private(set) var lastContext: NetworkContext?
    @Published private(set) var method: Method?
    @Published private(set) var bpfAvailable = false
    @Published var error: String?

    static let durations = [60, 90]
    private static let neighborKey = "NetScope.outils.voisin"
    private static let contextKey = "NetScope.outils.voisin.reseau"
    /// Interface active connue à l'ouverture de l'outil (pour la passerelle de la capture).
    private var activeHint: LocalInterface?
    private let isDemo: Bool
    private let isEphemeral: Bool
    private var task: Task<Void, Never>?
    private var session: PrivilegedCaptureSession?
    /// « Arrêter » cliqué : la fin de la capture n'est pas une erreur.
    private var stopRequested = false
    private var bpf: BPFCapture?
    private weak var store: ToolStore?

    init() {
        let arguments = CommandLine.arguments
        isDemo = arguments.contains("--demo")
        isEphemeral = isDemo || arguments.contains("--snapshot")
        if isDemo {
            loadDemo()
        } else if !isEphemeral, let data = UserDefaults.standard.data(forKey: Self.neighborKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            lastNeighbor = try? decoder.decode(NetworkNeighbor.self, from: data)
            if let context = UserDefaults.standard.data(forKey: Self.contextKey) {
                lastContext = try? JSONDecoder().decode(NetworkContext.self, from: context)
            }
        }
    }

    var isRunning: Bool { phase == .authorizing || phase == .listening }

    /// Réseau d'une interface ; la passerelle vient de l'interface active quand c'est la même.
    /// `linkStamp` : dernier changement d'état du lien (un câble débranché puis rebranché ailleurs).
    nonisolated static func context(of interface: LocalInterface, active: LocalInterface?, linkStamp: UInt64? = nil) -> NetworkContext {
        var context = NetworkContext(interface)
        if context.gateway == nil, let active, active.name == interface.name { context.gateway = active.gateway }
        context.linkStamp = linkStamp
        return context
    }

    /// Réseau actuel de l'interface de la dernière capture (lecture locale, aucun trafic) ;
    /// nil si l'interface n'est plus active.
    func currentContext(of name: String, active: LocalInterface?) async -> NetworkContext? {
        if isDemo { return currentContextNow(of: name, active: active) }
        return await Task.detached(priority: .utility) { Self.readContext(of: name, active: active) }.value
    }

    /// Même lecture, immédiate (premier affichage de l'encart : rien n'est affirmé avant elle).
    func currentContextNow(of name: String, active: LocalInterface?) -> NetworkContext? {
        if isDemo { return CaptureDemo.interfaces.first { $0.name == name }.map { Self.context(of: $0, active: active) } }
        return Self.readContext(of: name, active: active)
    }

    nonisolated private static func readContext(of name: String, active: LocalInterface?) -> NetworkContext? {
        guard let interface = LocalInterfaces.linkInterfaces().first(where: { $0.name == name }) else { return nil }
        return context(of: interface, active: active, linkStamp: LocalInterfaces.linkStamps()[name])
    }

    var selectedInterface: LocalInterface? { interfaces.first { $0.name == interfaceName } }

    /// Voisin principal : celui qui a annoncé LLDP, sinon le premier.
    var primary: NetworkNeighbor? { neighbors.first { $0.protocols.contains(.lldp) } ?? neighbors.first }

    var command: String { "lldp-listen -i \(interfaceName.isEmpty ? "en0" : interfaceName)" }

    /// Lit les interfaces (état local) et l'accès BPF ; choisit une interface Ethernet de préférence.
    func prepare(active: LocalInterface?) async {
        guard !isDemo else { return }
        activeHint = active
        // Toutes les interfaces actives, même sans adresse IPv4 : LLDP et CDP n'en ont pas besoin.
        let list = await LocalInterfaces.linkInterfacesWithKinds()
        interfaces = list
        if interfaceName.isEmpty || !list.contains(where: { $0.name == interfaceName }) {
            interfaceName = LocalInterfaces.preferredLinkInterface(in: list, preferred: active?.name)?.name ?? ""
        }
        bpfAvailable = await Task.detached { BPFCapture.readableDevice() != nil }.value
    }

    // MARK: Capture

    func start(store: ToolStore) {
        guard !isRunning else { return }
        self.store = store
        error = nil
        let name = interfaceName
        guard CaptureInterfaceName.isValid(name) else {
            error = "Choisissez une interface réseau."
            return
        }
        neighbors = []
        stopRequested = false
        store.record(command: command)
        if isDemo {
            startDemo()
        } else if bpfAvailable {
            startBPF(name)
        } else {
            startPrivileged(name)
        }
    }

    func stop() {
        switch method {
        case .privileged:
            stopRequested = true
            if phase == .authorizing { session?.cancel() } else { session?.stop() }
        case .bpf, .demo, nil:
            task?.cancel()
            finish()
        }
    }

    private func startDemo() {
        method = .demo
        phase = .listening
        startedAt = Date()
        deadline = Date().addingTimeInterval(TimeInterval(duration))
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.neighbors = [CaptureDemo.neighbor(receivedAt: Date())]
            let remaining = (self.deadline ?? Date()).timeIntervalSinceNow
            try? await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.finish()
        }
    }

    private func startBPF(_ name: String) {
        method = .bpf
        let capture: BPFCapture
        do {
            capture = try BPFCapture(interface: name, filter: BPFFilter.neighbors, promiscuous: true)
        } catch {
            // Accès BPF perdu entre-temps : on passe par l'autorisation d'administrateur.
            bpfAvailable = false
            startPrivileged(name)
            return
        }
        bpf = capture
        phase = .listening
        startedAt = Date()
        let end = Date().addingTimeInterval(TimeInterval(duration))
        deadline = end
        task = Task { [weak self] in
            var frames: [CapturedFrame] = []
            while !Task.isCancelled, Date() < end {
                let batch = await Task.detached { capture.read(timeout: 0.5) }.value
                guard !batch.isEmpty else { continue }
                frames += batch
                let decoded = NeighborFrameDecoder.neighbors(in: frames, interface: name)
                self?.neighbors = decoded
            }
            capture.stop()
            if !Task.isCancelled { self?.finish() }
        }
    }

    private func startPrivileged(_ name: String) {
        method = .privileged
        let session: PrivilegedCaptureSession
        do {
            session = try PrivilegedCaptureSession(interface: name, purpose: .neighbors, seconds: duration)
            try session.start { [weak self] outcome in
                Task { @MainActor in self?.sessionEnded(outcome) }
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            method = nil
            return
        }
        self.session = session
        phase = .authorizing
        startedAt = nil
        deadline = nil
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, let current = self.session, current === session else { return }
                if self.phase == .authorizing, current.isListening {
                    self.phase = .listening
                    self.startedAt = Date()
                    self.deadline = Date().addingTimeInterval(TimeInterval(self.duration))
                }
                if self.phase == .listening {
                    let frames = await Task.detached { current.frames(final: false) }.value
                    let decoded = NeighborFrameDecoder.neighbors(in: frames, interface: name)
                    if !decoded.isEmpty { self.neighbors = decoded }
                }
            }
        }
    }

    private func sessionEnded(_ outcome: PrivilegedCaptureSession.Outcome) {
        guard let session else { return }
        task?.cancel()
        let frames = session.frames(final: true)
        let decoded = NeighborFrameDecoder.neighbors(in: frames, interface: session.interface)
        if !decoded.isEmpty { neighbors = decoded }
        switch outcome {
        case .finished:
            if let message = TcpdumpHexParser.errorMessage(session.errorText), !session.isListening {
                error = "tcpdump n’a pas pu écouter\u{00A0}: \(message)"
            }
        case .cancelled:
            error = stopRequested ? nil : "Autorisation annulée\u{00A0}: aucune capture n’a été faite."
        case .failed(let message):
            error = stopRequested ? nil : "La capture n’a pas pu démarrer" + (message.isEmpty ? "." : "\u{00A0}: \(message)")
        }
        session.cleanup()
        self.session = nil
        finish(recordResult: outcome == .finished && error == nil)
    }

    private func finish(recordResult: Bool = true) {
        guard isRunning else { return }
        phase = .finished
        bpf?.stop()
        bpf = nil
        let name = interfaceName
        if let primary {
            lastNeighbor = primary
            lastContext = Self.context(of: interfaces.first { $0.name == name } ?? LocalInterface(name: name, address: IPv4Address(0), netmask: IPv4Address(0)),
                                       active: activeHint, linkStamp: isDemo ? nil : LocalInterfaces.linkStamps()[name])
            save()
            store?.record(ToolRecent(tool: .lldp, target: name, summary: primary.headline, status: .ok))
        } else if recordResult {
            let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()).rounded())
            store?.record(ToolRecent(tool: .lldp, target: name, summary: "Aucune trame LLDP ni CDP en \(seconds)\u{00A0}s", status: .warning))
        }
    }

    private func save() {
        guard !isEphemeral, let lastNeighbor else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(lastNeighbor) { UserDefaults.standard.set(data, forKey: Self.neighborKey) }
        if let data = try? JSONEncoder().encode(lastContext) { UserDefaults.standard.set(data, forKey: Self.contextKey) }
    }

    private func loadDemo() {
        interfaces = CaptureDemo.interfaces
        interfaceName = "en7"
        bpfAvailable = false
        let received = Date().addingTimeInterval(-12)
        let neighbor = CaptureDemo.neighbor(receivedAt: received)
        neighbors = [neighbor]
        lastNeighbor = neighbor
        lastContext = Self.context(of: CaptureDemo.interfaces[1], active: CaptureDemo.interfaces[0])
        method = .demo
        phase = .listening
        startedAt = Date().addingTimeInterval(-28)
        deadline = Date().addingTimeInterval(62)
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 62_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(recordResult: false)
        }
    }
}

// MARK: - Vue

/// Capture LLDP/CDP (croquis : section « Écoute LLDP/CDP » de Toolbox.dc.html).
struct NeighborCaptureView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolNeighborModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = NeighborTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isRunning { statusRow } else { controls }
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            if !model.isRunning, model.selectedInterface?.kind == .wifi {
                ToolNotice(tone: .warning, title: "\(model.interfaceName) est une interface Wi-Fi",
                           message: "Les switchs n’envoient LLDP et CDP que sur leurs ports câblés\u{00A0}: la borne Wi-Fi ne relaie pas ces trames. Branchez ce Mac avec un câble Ethernet et choisissez cette interface.")
            }
            if model.phase == .authorizing {
                ToolNotice(tone: .accent, title: "Autorisation demandée par macOS",
                           message: "Saisissez le mot de passe d’un administrateur dans la fenêtre de macOS. tcpdump sera lancé une seule fois, en lecture seule, et s’arrêtera seul après \(model.duration)\u{00A0}s ou au clic sur «\u{00A0}Arrêter\u{00A0}».")
            }
            if let neighbor = model.primary ?? (model.isRunning ? nil : model.lastNeighbor) {
                summary(neighbor, isCurrent: model.primary != nil)
                fields(neighbor)
                PoEMacAnswer(power: neighbor.power, legacySummary: neighbor.poe)
                if let tip = tip(for: neighbor) {
                    Text(tip).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.neighbors.count > 1 {
                    // Plusieurs voisins (switch et téléphone IP, deux switchs…) : tous dans un tableau.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ToolFieldLabel("Voisins reçus · \(model.neighbors.count)")
                            Spacer(minLength: 8)
                            ToolColumnsMenu(model: table)
                        }
                        NeighborTable(rows: NeighborRow.rows(model.neighbors), table: table)
                    }
                }
            } else if model.phase == .listening {
                waiting
            } else if model.phase == .finished {
                ToolNotice(tone: .warning, title: "Aucune trame LLDP ni CDP reçue",
                           message: "Le port est peut-être configuré sans LLDP ni CDP, l’interface n’est pas reliée à un switch géré, ou un convertisseur USB-C filtre ces trames. Essayez une capture de 90\u{00A0}s.")
            } else {
                method
            }
        }
        .task { await model.prepare(active: state.activeInterface) }
    }

    // MARK: Contrôles

    /// Choix et bouton sur une ligne ; en petite fenêtre, le bouton passe dessous.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                pickers
                Spacer(minLength: 0)
                startButton
            }
            VStack(alignment: .leading, spacing: 10) {
                pickers
                startButton
            }
        }
    }

    private var pickers: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ToolLabeledField(label: "Interface") {
                Picker("", selection: $model.interfaceName) {
                    if model.interfaces.isEmpty { Text("aucune interface").tag("") }
                    ForEach(model.interfaces, id: \.name) { iface in
                        Text(iface.linkSummary).tag(iface.name)
                    }
                }
                .labelsHidden()
                .controlSize(.large)
                .frame(minWidth: 170)
                .fixedSize(horizontal: true, vertical: false)
            }
            ToolLabeledField(label: "Durée") {
                Picker("", selection: $model.duration) {
                    ForEach(ToolNeighborModel.durations, id: \.self) { Text("\($0)\u{00A0}s").tag($0) }
                }
                .labelsHidden()
                .controlSize(.large)
                .frame(width: 90)
            }
        }
        .fixedSize()
    }

    private var startButton: some View {
        Button { model.start(store: store) } label: {
            Label(model.bpfAvailable ? "Démarrer l’écoute" : "Capturer avec les droits administrateur",
                  systemImage: model.bpfAvailable ? "dot.radiowaves.left.and.right" : "lock.open")
        }
        .buttonStyle(.primary)
        .fixedSize()
        .disabled(model.interfaceName.isEmpty)
    }

    private var statusRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Circle().fill(model.phase == .listening ? Theme.successDot : Theme.warningDot).frame(width: 10, height: 10)
                    Text(model.phase == .listening ? "Écoute en cours sur \(interfaceLabel)" : "En attente de l’autorisation pour \(interfaceLabel)")
                        .font(Theme.bodySemibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let deadline = model.deadline {
                        Text("\(max(0, Int(deadline.timeIntervalSince(context.date).rounded())))\u{00A0}s restantes")
                            .font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                    Button("Arrêter") { model.stop() }
                        .buttonStyle(.secondary)
                }
                Text("LLDP (01:80:C2:00:00:0E) et CDP (01:00:0C:CC:CC:CC)" + methodSuffix)
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 20)
            }
        }
    }

    private var methodSuffix: String {
        switch model.method {
        case .bpf: return " · accès BPF direct"
        case .privileged: return " · tcpdump (administrateur)"
        default: return ""
        }
    }

    private var interfaceLabel: String {
        guard let iface = model.selectedInterface else { return model.interfaceName }
        return "\(iface.name) · \(iface.kind.label)"
    }

    private var method: some View {
        ToolNotice(tone: .accent, title: model.bpfAvailable ? "Accès direct aux trames (BPF)" : "Droits d’administrateur nécessaires",
                   message: model.bpfAvailable
                   ? "Ce Mac permet déjà la lecture de /dev/bpf (ChmodBPF de Wireshark)\u{00A0}: l’écoute démarre sans mot de passe. Rien n’est envoyé sur le réseau."
                   : "Lire les trames LLDP et CDP demande /dev/bpf, réservé à root. NetScope lance tcpdump une seule fois avec votre autorisation (fenêtre de macOS), en lecture seule, avec un filtre fixe et une durée bornée. Rien n’est envoyé sur le réseau.")
    }

    private var waiting: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("En attente d’une annonce du switch… LLDP passe toutes les 30\u{00A0}s, CDP toutes les 60\u{00A0}s.")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Résultat

    private func summary(_ neighbor: NetworkNeighbor, isCurrent: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.success)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isCurrent ? "CE MAC EST BRANCHÉ SUR" : "DERNIÈRE CAPTURE · CE MAC ÉTAIT BRANCHÉ SUR")
                        .font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Color(light: 0x166534, dark: 0x9AE9B8))
                    // Une ligne à 20 pt, sinon à 16 pt (petite fenêtre), sinon sur plusieurs lignes.
                    ViewThatFits(in: .horizontal) {
                        headline(neighbor, size: 20).fixedSize()
                        headline(neighbor, size: 16).fixedSize()
                        headline(neighbor, size: 16).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(receivedText(neighbor, now: context.date, isCurrent: isCurrent))
                            .font(Theme.small).foregroundStyle(Color(light: 0x166534, dark: 0x9AE9B8))
                        Spacer(minLength: 8)
                        Button { openSwitch(neighbor) } label: {
                            Text("Ouvrir le switch →").font(Theme.bodySemibold)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Sombre : fond vert profond et filet discret (le vert vif d'origine éblouissait).
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Color(light: 0xF0FDF4, dark: 0x16301F)))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Color(light: 0xBBF7D0, dark: 0x25583A)))
        }
    }

    private func headline(_ neighbor: NetworkNeighbor, size: CGFloat) -> some View {
        Text(neighbor.headline)
            .font(Theme.mono(size, weight: .semibold)).foregroundStyle(Color(light: 0x14532D, dark: 0x9CE7BA))
            .textSelection(.enabled)
    }

    private func receivedText(_ neighbor: NetworkNeighbor, now: Date, isCurrent: Bool) -> String {
        let source = neighbor.protocols.first?.rawValue ?? "LLDP"
        guard let date = neighbor.receivedAt else { return "Reçu par \(neighbor.protocolLabel)" }
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        var text = "Reçu par \(neighbor.protocolLabel)"
        if isCurrent {
            text += " il y a \(elapsed)\u{00A0}s"
            if model.phase == .listening {
                let period = source == "CDP" ? 60 : 30
                text += " · prochaine trame dans \(period - elapsed % period)\u{00A0}s"
            }
        } else {
            text += " \(ToolText.relative(date, now: now))" + (neighbor.interface.map { " sur \($0)" } ?? "")
        }
        return text
    }

    private func fields(_ neighbor: NetworkNeighbor) -> some View {
        var rows: [(String, String)] = [
            ("Nom système", neighbor.systemName ?? "—"),
            ("Port ID", neighbor.portID ?? "—"),
            ("Description du port", neighbor.portDescription ?? "—"),
            ("VLAN (PVID)", neighbor.nativeVLAN.map { "\($0) (non étiqueté)" } ?? "—"),
            ("IP de gestion", neighbor.managementAddresses.first ?? "—"),
            ("Châssis ID", neighbor.chassisID ?? "—"),
            ("Modèle", neighbor.model ?? "—"),
            ("Capacités", neighbor.capabilities.isEmpty ? "—" : neighbor.capabilities.joined(separator: ", ")),
            ("TTL", neighbor.ttl.map { "\($0)\u{00A0}s" } ?? "—"),
        ]
        if let voice = neighbor.voiceVLAN { rows.append(("VLAN voix", "\(voice)")) }
        if let link = neighbor.link ?? neighbor.duplex { rows.append(("Lien", link)) }
        if let software = neighbor.softwareVersion, neighbor.protocols.contains(.cdp) { rows.append(("Logiciel", software)) }
        if let domain = neighbor.vtpDomain { rows.append(("Domaine VTP", domain)) }
        if rows.count % 2 == 1 { rows.append(("Protocole", neighbor.protocolLabel)) }
        return NeighborFieldGrid(rows: rows)
    }

    /// Astuce du croquis : VLAN 1 natif sur une prise de poste.
    private func tip(for neighbor: NetworkNeighbor) -> String? {
        guard neighbor.nativeVLAN == 1 else { return nil }
        var counts: [Int: Int] = [:]
        for device in InvModel.shared.withManualTypes(state.devices) where device.deviceType == .poste { if let vlan = device.vlan { counts[vlan, default: 0] += 1 } }
        // VLAN le plus fréquent des postes connus (démonstration comprise, pour rester cohérent
        // avec le Scanner) ; si les postes sont eux-mêmes en VLAN 1, l'astuce n'a pas lieu d'être.
        let usual = counts.max { $0.value < $1.value }?.key
        if usual == 1 { return nil }
        let hint = usual.flatMap { $0 != 1 ? " ici (les postes sont en VLAN\u{00A0}\($0))" : nil } ?? ""
        return "Astuce\u{00A0}: le VLAN\u{00A0}1 natif sur une prise de bureau est inhabituel\(hint). À vérifier dans Switchs et ports."
    }

    private func openSwitch(_ neighbor: NetworkNeighbor) {
        SwitchStore.shared.showNeighbor(neighbor)
        state.open(.switchs)
    }
}

/// Grille clé / valeur sur deux colonnes, filets de 1 pt (croquis : lldpFields) ; une seule
/// colonne en petite fenêtre, pour que les valeurs ne passent pas à la ligne.
struct NeighborFieldGrid: View {
    let rows: [(String, String)]
    /// Largeur sous laquelle une colonne de la grille serait trop étroite.
    var minColumnWidth: CGFloat = 250

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(columns: 2).frame(minWidth: 2 * minColumnWidth)
            grid(columns: 1)
        }
    }

    private func grid(columns: Int) -> some View {
        let pairs = stride(from: 0, to: rows.count, by: columns).map { Array(rows[$0..<min($0 + columns, rows.count)]) }
        return VStack(spacing: 1) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 1) {
                    ForEach(0..<columns, id: \.self) { index in
                        if index < pair.count {
                            cell(pair[index].0, pair[index].1)
                        } else {
                            Theme.panel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func cell(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).layoutPriority(1)
            Text(value)
                .font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.panel)
    }
}

// MARK: - Tableau des voisins

/// Ligne du tableau des voisins LLDP/CDP.
struct NeighborRow: Identifiable {
    let id: Int
    let neighbor: NetworkNeighbor

    var sortSwitch: String { neighbor.systemName?.lowercased() ?? "~" }
    var sortPort: String { neighbor.portID ?? "~" }
    var sortPortDescription: String { neighbor.portDescription?.lowercased() ?? "~" }
    var sortVLAN: Int { neighbor.nativeVLAN ?? .max }
    var sortProtocol: String { neighbor.protocolLabel }
    var sortTTL: Int { neighbor.ttl ?? .max }
    var sortCapabilities: String { neighbor.capabilities.joined(separator: ", ") }
    var sortManagement: String { neighbor.managementAddresses.first ?? "~" }
    var sortSystem: String { neighbor.systemDescription ?? "~" }
    var sortModel: String { neighbor.model ?? "~" }
    var sortChassis: String { neighbor.chassisID ?? "~" }

    static func rows(_ neighbors: [NetworkNeighbor]) -> [NeighborRow] {
        neighbors.enumerated().map { NeighborRow(id: $0.offset, neighbor: $0.element) }
    }
}

/// Voisins reçus (tableau standard « outils.voisins », note 8) : switch, port, description du
/// port, VLAN (PVID), protocole, TTL ; facultatives : capacités, adresse de gestion, description du
/// système, modèle, châssis.
struct NeighborTable: View {
    let rows: [NeighborRow]
    @ObservedObject var table: StandardTableModel<NeighborRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "switch", title: "Switch", isRequired: true),
        StandardColumn(id: "port", title: "Port"),
        StandardColumn(id: "descriptionPort", title: "Description du port"),
        StandardColumn(id: "vlan", title: "VLAN (PVID)"),
        StandardColumn(id: "protocole", title: "Protocole"),
        StandardColumn(id: "ttl", title: "TTL"),
        StandardColumn(id: "capacites", title: "Capacités", isDefaultVisible: false),
        StandardColumn(id: "gestion", title: "Adresse de gestion", isDefaultVisible: false),
        StandardColumn(id: "systeme", title: "Description du système", isDefaultVisible: false),
        StandardColumn(id: "modele", title: "Modèle", isDefaultVisible: false),
        StandardColumn(id: "chassis", title: "Châssis ID", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<NeighborRow>] = [
        "switch": KeyPathComparator(\NeighborRow.sortSwitch),
        "port": KeyPathComparator(\NeighborRow.sortPort),
        "descriptionPort": KeyPathComparator(\NeighborRow.sortPortDescription),
        "vlan": KeyPathComparator(\NeighborRow.sortVLAN),
        "protocole": KeyPathComparator(\NeighborRow.sortProtocol),
        "ttl": KeyPathComparator(\NeighborRow.sortTTL),
        "capacites": KeyPathComparator(\NeighborRow.sortCapabilities),
        "gestion": KeyPathComparator(\NeighborRow.sortManagement),
        "systeme": KeyPathComparator(\NeighborRow.sortSystem),
        "modele": KeyPathComparator(\NeighborRow.sortModel),
        "chassis": KeyPathComparator(\NeighborRow.sortChassis),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<NeighborRow> {
        StandardTableModel(id: "outils.voisins", columns: columns, sortKeys: sortKeys, defaultSort: "switch")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 6) {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                Group {
                    TableColumn("SWITCH", sortUsing: table.sort("switch")) { row in
                        ToolTableText(row.neighbor.systemName ?? "—", weight: .semibold)
                    }
                    .width(min: 80, ideal: 100)
                    .customizationID("switch")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("PORT", sortUsing: table.sort("port")) { row in
                        ToolTableText(row.neighbor.portID ?? "—")
                    }
                    .width(min: 40, ideal: 48)
                    .customizationID("port")

                    TableColumn("DESCRIPTION", sortUsing: table.sort("descriptionPort")) { row in
                        ToolTableText(row.neighbor.portDescription ?? "—", mono: false).help(row.neighbor.portDescription ?? "")
                    }
                    .width(min: 70, ideal: 96)
                    .customizationID("descriptionPort")

                    TableColumn("VLAN (PVID)", sortUsing: table.sort("vlan")) { row in
                        ToolTableText(row.neighbor.nativeVLAN.map(String.init) ?? "—")
                    }
                    .width(min: 60, ideal: 82)
                    .customizationID("vlan")

                    TableColumn("PROTOCOLE", sortUsing: table.sort("protocole")) { row in
                        ToolTableText(row.neighbor.protocolLabel, mono: false)
                    }
                    .width(min: 60, ideal: 86)
                    .customizationID("protocole")

                    TableColumn("TTL", sortUsing: table.sort("ttl")) { row in
                        ToolTableText(row.neighbor.ttl.map { "\($0)\u{00A0}s" } ?? "—", alignment: .trailing)
                    }
                    .width(min: 36, ideal: 44)
                    .customizationID("ttl")
                }
                Group {
                    TableColumn("CAPACITÉS", sortUsing: table.sort("capacites")) { row in
                        ToolTableText(row.neighbor.capabilities.isEmpty ? "—" : row.sortCapabilities, mono: false)
                    }
                    .width(min: 70, ideal: 120)
                    .customizationID("capacites")
                    .defaultVisibility(.hidden)

                    TableColumn("ADRESSE DE GESTION", sortUsing: table.sort("gestion")) { row in
                        ToolTableText(row.neighbor.managementAddresses.first ?? "—")
                            .help(row.neighbor.managementAddresses.joined(separator: ", "))
                    }
                    .width(min: 90, ideal: 116)
                    .customizationID("gestion")
                    .defaultVisibility(.hidden)

                    TableColumn("DESCRIPTION DU SYSTÈME", sortUsing: table.sort("systeme")) { row in
                        ToolTableText(row.neighbor.systemDescription ?? "—", mono: false)
                            .help(row.neighbor.systemDescription ?? "")
                    }
                    .width(min: 100, ideal: 220)
                    .customizationID("systeme")
                    .defaultVisibility(.hidden)

                    TableColumn("MODÈLE", sortUsing: table.sort("modele")) { row in
                        ToolTableText(row.neighbor.model ?? "—", mono: false)
                    }
                    .width(min: 70, ideal: 120)
                    .customizationID("modele")
                    .defaultVisibility(.hidden)

                    TableColumn("CHÂSSIS ID", sortUsing: table.sort("chassis")) { row in
                        ToolTableText(row.neighbor.chassisID ?? "—")
                    }
                    .width(min: 90, ideal: 136)
                    .customizationID("chassis")
                    .defaultVisibility(.hidden)
                }
            }
        }
    }
}
