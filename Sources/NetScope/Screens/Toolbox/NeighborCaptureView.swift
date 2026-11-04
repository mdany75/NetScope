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
    @Published private(set) var method: Method?
    @Published private(set) var bpfAvailable = false
    @Published var error: String?

    static let durations = [60, 90]
    private static let neighborKey = "NetScope.outils.voisin"
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
        }
    }

    var isRunning: Bool { phase == .authorizing || phase == .listening }

    var selectedInterface: LocalInterface? { interfaces.first { $0.name == interfaceName } }

    /// Voisin principal : celui qui a annoncé LLDP, sinon le premier.
    var primary: NetworkNeighbor? { neighbors.first { $0.protocols.contains(.lldp) } ?? neighbors.first }

    var command: String { "lldp-listen -i \(interfaceName.isEmpty ? "en0" : interfaceName)" }

    /// Lit les interfaces (état local) et l'accès BPF ; choisit une interface Ethernet de préférence.
    func prepare(active: LocalInterface?) async {
        guard !isDemo else { return }
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
    }

    private func loadDemo() {
        interfaces = CaptureDemo.interfaces
        interfaceName = "en7"
        bpfAvailable = false
        let received = Date().addingTimeInterval(-12)
        let neighbor = CaptureDemo.neighbor(receivedAt: received)
        neighbors = [neighbor]
        lastNeighbor = neighbor
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
                if let tip = tip(for: neighbor) {
                    Text(tip).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.neighbors.count > 1 {
                    Text("Autres voisins reçus\u{00A0}: " + model.neighbors.dropFirst().map(\.headline).joined(separator: " · "))
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
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

    private var controls: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ToolLabeledField(label: "Interface") {
                Picker("", selection: $model.interfaceName) {
                    if model.interfaces.isEmpty { Text("aucune interface").tag("") }
                    ForEach(model.interfaces, id: \.name) { iface in
                        Text(iface.linkSummary).tag(iface.name)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 170, minHeight: 34, maxHeight: 34)
                .fixedSize(horizontal: true, vertical: false)
            }
            ToolLabeledField(label: "Durée") {
                Picker("", selection: $model.duration) {
                    ForEach(ToolNeighborModel.durations, id: \.self) { Text("\($0)\u{00A0}s").tag($0) }
                }
                .labelsHidden()
                .frame(width: 90, height: 34)
            }
            Spacer(minLength: 0)
            Button { model.start(store: store) } label: {
                Label(model.bpfAvailable ? "Démarrer l’écoute" : "Capturer avec les droits administrateur",
                      systemImage: model.bpfAvailable ? "dot.radiowaves.left.and.right" : "lock.open")
            }
            .buttonStyle(.primary)
            .fixedSize()
            .disabled(model.interfaceName.isEmpty)
        }
    }

    private var statusRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Circle().fill(model.phase == .listening ? Theme.success : Color(hex: 0xF97316)).frame(width: 10, height: 10)
                    Text(model.phase == .listening ? "Écoute en cours sur \(interfaceLabel)" : "En attente de l’autorisation pour \(interfaceLabel)")
                        .font(Theme.bodySemibold).lineLimit(1)
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
                        .font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Color(hex: 0x166534))
                    Text(neighbor.headline)
                        .font(Theme.mono(20, weight: .semibold)).foregroundStyle(Color(hex: 0x14532D))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(receivedText(neighbor, now: context.date, isCurrent: isCurrent))
                            .font(Theme.small).foregroundStyle(Color(hex: 0x166534))
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
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Color(hex: 0xF0FDF4)))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Color(hex: 0xBBF7D0)))
        }
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
            ("PoE", neighbor.poe ?? "—"),
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
        for device in state.devices where device.deviceType == .poste { if let vlan = device.vlan { counts[vlan, default: 0] += 1 } }
        // Démonstration : VLAN des postes du croquis.
        let usual = Launcher.isDemo ? CaptureDemo.workstationVLAN : counts.max { $0.value < $1.value }?.key
        let hint = usual.flatMap { $0 != 1 ? " ici (les postes sont en VLAN\u{00A0}\($0))" : nil } ?? ""
        return "Astuce\u{00A0}: le VLAN\u{00A0}1 natif sur une prise de bureau est inhabituel\(hint). À vérifier dans Switchs et ports."
    }

    private func openSwitch(_ neighbor: NetworkNeighbor) {
        SwitchStore.shared.showNeighbor(neighbor)
        state.open(.switchs)
    }
}

/// Grille clé / valeur sur deux colonnes, filets de 1 pt (croquis : lldpFields).
struct NeighborFieldGrid: View {
    let rows: [(String, String)]

    var body: some View {
        let pairs = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
        VStack(spacing: 1) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 1) {
                    ForEach(0..<2, id: \.self) { index in
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
