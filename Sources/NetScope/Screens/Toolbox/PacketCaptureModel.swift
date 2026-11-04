import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Capture et inspection de paquets (note 7) : état de l'outil, conservé quand on change d'écran.
///
/// Accès aux paquets : /dev/bpf* s'il est ouvrable (ChmodBPF de Wireshark), filtre BPF posé dans le
/// noyau ; sinon tcpdump lancé une fois avec l'autorisation d'administrateur, qui écrit un fichier
/// pcap lu au fur et à mesure. Rien n'est jamais envoyé sur le réseau. En démonstration (`--demo`),
/// une capture fictive est rejouée.
@MainActor
final class ToolPacketCaptureModel: ObservableObject {
    enum Phase: Equatable { case idle, preparing, authorizing, capturing, finished }
    enum Method: Equatable { case bpf, privileged, demo, file }
    enum Pane: String, CaseIterable, Identifiable {
        case packets, flow, statistics
        var id: String { rawValue }
        var label: String {
            switch self {
            case .packets: return "Paquets"
            case .flow: return "Suivre le flux"
            case .statistics: return "Statistiques"
            }
        }
    }

    // Réglages de la capture.
    @Published var interfaces: [LocalInterface] = []
    @Published var interfaceName = ""
    @Published var captureFilter = ""
    @Published var duration = 60
    @Published var packetLimit = 10_000
    @Published var sizeLimit = 50
    @Published var promiscuous = false

    static let durations = [10, 30, 60, 300, 900, 3600]
    static let packetLimits = [1_000, 10_000, 100_000]
    static let sizeLimits = [10, 50, 200]

    // Déroulement.
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var method: Method?
    @Published private(set) var bpfAvailable = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?
    @Published private(set) var stopReason: String?
    @Published private(set) var filterSource: CompiledCaptureFilter.Source?
    /// Nom de la source affichée : interface capturée ou fichier ouvert.
    @Published private(set) var sourceName: String?
    @Published var error: String?
    @Published var notice: String?

    // Paquets et affichage.
    // Les paquets ne sont pas @Published : un ajout se fait sur place (sans copier toute la liste
    // à chaque lot), et `revision` prévient les vues.
    private(set) var log = PacketCaptureLog() { didSet { revision &+= 1 } }
    private(set) var rows: [PacketRow] = [] { didSet { revision &+= 1 } }
    @Published private(set) var revision = 0
    private var statisticsCache: (revision: Int, displayed: Bool, value: CaptureStatistics)?
    @Published var displayFilter = "" { didSet { if displayFilter != oldValue { applyDisplayFilter() } } }
    @Published private(set) var displayFilterError: String?
    @Published var selection: PacketRow.ID? { didSet { if selection != oldValue { selectionChanged() } } }
    @Published var selectedField: Int?
    @Published var expanded: Set<Int> = []
    @Published var pane: Pane = .packets
    @Published private(set) var stream: FlowStream?
    @Published var streamShowsHex = false

    private var compiledDisplayFilter: DisplayFilter?
    private let isDemo: Bool
    private var task: Task<Void, Never>?
    private var bpf: BPFCapture?
    private var session: PrivilegedCaptureSession?
    private var reader = PcapStreamReader()
    private var stopRequested = false
    private weak var store: ToolStore?

    init() {
        isDemo = CommandLine.arguments.contains("--demo")
        if isDemo { loadDemo() }
    }

    var isRunning: Bool { [.preparing, .authorizing, .capturing].contains(phase) }
    var selectedInterface: LocalInterface? { interfaces.first { $0.name == interfaceName } }
    var selectedPacket: CapturedPacket? { selection.flatMap { log.packet($0) } }

    var limits: CaptureLimits {
        CaptureLimits(seconds: duration, packets: packetLimit, bytes: sizeLimit * 1_000_000)
    }

    /// Commande équivalente (en-tête de l'outil).
    var command: String {
        var text = "tcpdump -i \(interfaceName.isEmpty ? "en0" : interfaceName) -n\(promiscuous ? "" : " -p") -c \(packetLimit) -w capture.pcap"
        let filter = CaptureFilterCompiler.normalized(captureFilter)
        if !filter.isEmpty { text += " '\(filter)'" }
        return text
    }

    /// Lit les interfaces (état local) et l'accès BPF.
    func prepare(active: LocalInterface?) async {
        guard !isDemo else { return }
        let list = await LocalInterfaces.linkInterfacesWithKinds()
        interfaces = list
        if interfaceName.isEmpty || !list.contains(where: { $0.name == interfaceName }) {
            interfaceName = active.flatMap { a in list.first { $0.name == a.name } }?.name
                ?? LocalInterfaces.preferredLinkInterface(in: list, preferred: active?.name)?.name ?? ""
        }
        bpfAvailable = await Task.detached { BPFCapture.readableDevice() != nil }.value
    }

    func applyPreset(_ preset: CapturePreset, gateway: IPv4Address?) {
        captureFilter = preset.text(host: gateway?.description ?? selectedInterface?.gateway?.description ?? "10.0.0.1")
    }

    // MARK: Capture

    func start(store: ToolStore) {
        guard !isRunning else { return }
        self.store = store
        error = nil
        notice = nil
        let name = interfaceName
        guard CaptureInterfaceName.isValid(name) else {
            error = "Choisissez une interface réseau."
            return
        }
        stopRequested = false
        resetPackets()
        sourceName = name
        stopReason = nil
        endedAt = nil
        store.record(command: command)
        if isDemo {
            startDemo()
            return
        }
        phase = .preparing
        let text = captureFilter
        task = Task { [weak self] in
            let compiled = await Task.detached { CaptureFilterCompiler.compile(text) }.value
            guard let self, !Task.isCancelled else { return }
            switch compiled {
            case .failure(let failure):
                self.error = failure.errorDescription
                self.phase = .idle
            case .success(let filter):
                self.filterSource = filter.source
                if self.bpfAvailable { self.startBPF(name, filter: filter) } else { self.startPrivileged(name, filter: filter) }
            }
        }
    }

    func stop() {
        stopRequested = true
        switch method {
        case .privileged:
            if phase == .authorizing { session?.cancel() } else { session?.stop() }
        default:
            task?.cancel()
            finish(reason: "arrêtée")
        }
    }

    private func startBPF(_ name: String, filter: CompiledCaptureFilter) {
        method = .bpf
        let capture: BPFCapture
        do {
            capture = try BPFCapture(interface: name, filter: filter.program, promiscuous: promiscuous, seeSent: true, bufferSize: 1 << 20)
        } catch {
            bpfAvailable = false
            startPrivileged(name, filter: filter)
            return
        }
        bpf = capture
        phase = .capturing
        startedAt = Date()
        let limits = self.limits
        let linkType = capture.linkType
        task = Task { [weak self] in
            while !Task.isCancelled {
                let frames = await Task.detached { capture.read(timeout: 0.25) }.value
                guard let self, !Task.isCancelled else { break }
                let records = frames.map {
                    PacketRecord(timestamp: ($0.date ?? Date()).timeIntervalSince1970, data: $0.bytes,
                                 originalLength: $0.originalLength ?? $0.bytes.count, linkType: linkType)
                }
                self.append(records)
                let elapsed = Date().timeIntervalSince(self.startedAt ?? Date())
                if let reason = limits.reached(packets: self.log.count, bytes: self.log.byteCount, elapsed: elapsed) {
                    self.finish(reason: reason.label)
                    break
                }
            }
            capture.stop()
        }
    }

    private func startPrivileged(_ name: String, filter: CompiledCaptureFilter) {
        method = .privileged
        let session: PrivilegedCaptureSession
        do {
            session = try PrivilegedCaptureSession(interface: name, packets: .init(filter: filter.text, maxPackets: packetLimit, promiscuous: promiscuous),
                                                   seconds: duration)
            try session.start { [weak self] outcome in
                Task { @MainActor in self?.sessionEnded(outcome) }
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            method = nil
            phase = .idle
            return
        }
        self.session = session
        reader = PcapStreamReader()
        phase = .authorizing
        let sizeLimit = self.sizeLimit * 1_000_000
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let current = self.session, current === session else { return }
                if self.phase == .authorizing, current.isListening {
                    self.phase = .capturing
                    self.startedAt = Date()
                }
                if self.phase == .capturing { self.readPcap(from: current) }
                if self.log.byteCount >= sizeLimit, !self.stopRequested {
                    self.stopReason = CaptureLimits.Reason.size.label
                    self.stopRequested = true
                    current.stop()
                }
            }
        }
    }

    private func readPcap(from session: PrivilegedCaptureSession) {
        let bytes = session.pcapBytes(from: reader.consumed)
        guard !bytes.isEmpty else { return }
        do {
            append(try reader.feed(bytes))
        } catch {
            self.error = "Lecture de la capture impossible\u{00A0}: \(error.localizedDescription)"
        }
    }

    private func sessionEnded(_ outcome: PrivilegedCaptureSession.Outcome) {
        guard let session else { return }
        task?.cancel()
        readPcap(from: session)
        switch outcome {
        case .finished:
            if let message = TcpdumpHexParser.errorMessage(session.errorText), !session.isListening {
                error = "tcpdump n’a pas pu capturer\u{00A0}: \(message)"
            }
        case .cancelled:
            if !stopRequested { error = "Autorisation annulée\u{00A0}: aucune capture n’a été faite." }
        case .failed(let message):
            if !stopRequested { error = "La capture n’a pas pu démarrer" + (message.isEmpty ? "." : "\u{00A0}: \(message)") }
        }
        session.cleanup()
        self.session = nil
        let reason: String
        if let stopReason { reason = stopReason } else if stopRequested { reason = "arrêtée" } else if log.count >= packetLimit {
            reason = CaptureLimits.Reason.packets.label
        } else { reason = CaptureLimits.Reason.duration.label }
        finish(reason: reason)
    }

    private func finish(reason: String) {
        guard isRunning else { return }
        bpf?.stop()
        bpf = nil
        phase = .finished
        endedAt = Date()
        stopReason = reason
        guard method != .demo || !CommandLine.arguments.contains("--snapshot") else { return }
        let stats = log.statistics()
        let problems = stats.count(.retransmission) + stats.count(.reset)
        var summary = "\(PacketText.number(log.count)) paquets en \(Int(log.duration.rounded()))\u{00A0}s"
        if problems > 0 { summary += " · \(stats.count(.retransmission)) retransmission\(stats.count(.retransmission) > 1 ? "s" : ""), \(stats.count(.reset)) RST" }
        if error == nil || log.count > 0 {
            store?.record(ToolRecent(tool: .capture, target: interfaceName, summary: summary, status: log.isEmpty ? .warning : problems > 0 ? .warning : .ok))
        }
    }

    // MARK: Paquets

    private func resetPackets() {
        log = PacketCaptureLog()
        rows = []
        selection = nil
        selectedField = nil
        expanded = []
        stream = nil
        if pane == .flow { pane = .packets }
    }

    /// Ajoute des paquets (dans les limites de paquets et de taille).
    private func append(_ records: [PacketRecord]) {
        guard !records.isEmpty else { return }
        let kept = limits.admissible(records, alreadyPackets: log.count, alreadyBytes: log.byteCount)
        guard !kept.isEmpty else { return }
        let added = log.append(kept)
        let shown = added.filter { compiledDisplayFilter?.matches($0) ?? true }
        rows.append(contentsOf: shown.map(PacketRow.init))
    }

    func applyDisplayFilter() {
        switch DisplayFilter.compile(displayFilter) {
        case .success(let filter):
            compiledDisplayFilter = filter
            displayFilterError = nil
            rows = log.packets.filter { filter?.matches($0) ?? true }.map(PacketRow.init)
        case .failure(let failure):
            displayFilterError = failure.message
        }
    }

    /// Statistiques de toute la capture ou des paquets affichés (gardées tant que rien ne change).
    func statistics(displayedOnly: Bool) -> CaptureStatistics {
        if let cache = statisticsCache, cache.revision == revision, cache.displayed == displayedOnly { return cache.value }
        let value = displayedOnly ? log.statistics(of: displayedPackets) : log.statistics()
        statisticsCache = (revision, displayedOnly, value)
        return value
    }

    var displayedPackets: [CapturedPacket] {
        rows.compactMap { log.packet($0.id) }
    }

    private func selectionChanged() {
        selectedField = nil
        guard let packet = selectedPacket else { expanded = []; return }
        // La couche la plus haute est dépliée, comme le dernier protocole intéressant.
        expanded = Set(packet.decoded.layers.last.map { [$0.node.id] } ?? [])
    }

    /// Choisit un champ (arborescence ou clic dans l'hexadécimal) et déplie ses parents.
    func selectField(_ id: Int?) {
        selectedField = id
        guard let id, let packet = selectedPacket else { return }
        expanded.formUnion(Self.ancestors(of: id, in: packet.decoded))
    }

    func selectByte(_ offset: Int) {
        guard let packet = selectedPacket, let field = packet.decoded.deepestField(containing: offset) else { return }
        selectField(field.id)
    }

    static func ancestors(of id: Int, in packet: DecodedPacket) -> [Int] {
        func path(_ field: PacketField) -> [Int]? {
            if field.id == id { return [] }
            for child in field.children { if let found = path(child) { return [field.id] + found } }
            return nil
        }
        for layer in packet.layers { if let found = path(layer.node) { return found } }
        return []
    }

    func toggle(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Suivre le flux

    var canFollow: Bool {
        guard let kind = selectedPacket?.conversation?.kind else { return false }
        return kind == .tcp || kind == .udp
    }

    /// Reconstitue le flux du paquet choisi et filtre la liste sur cette conversation.
    func followSelected() {
        guard let packet = selectedPacket, let flow = log.follow(packet) else { return }
        stream = flow
        let key = flow.key
        let transport = key.kind == .tcp ? "tcp" : "udp"
        var filter = "ip.addr == \(key.a.address) && ip.addr == \(key.b.address)"
        if let a = key.a.port, let b = key.b.port { filter += " && \(transport).port == \(a) && \(transport).port == \(b)" }
        displayFilter = filter
        pane = .flow
    }

    func clearFollow() {
        stream = nil
        displayFilter = ""
        pane = .packets
    }

    // MARK: Fichiers

    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Ouvrir une capture"
        panel.allowedContentTypes = ["pcap", "pcapng", "cap", "dmp"].compactMap { UTType(filenameExtension: $0) } + [.data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        guard !isRunning else { return }
        error = nil
        notice = nil
        Task { [weak self] in
            let result: Result<[PacketRecord], Error> = await Task.detached {
                do { return .success(try PcapFile.read([UInt8](try Data(contentsOf: url)))) } catch { return .failure(error) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let records):
                self.resetPackets()
                self.log = PacketCaptureLog(records: records)
                self.method = .file
                self.phase = .finished
                self.sourceName = url.lastPathComponent
                self.stopReason = nil
                self.startedAt = records.first.map { Date(timeIntervalSince1970: $0.timestamp) }
                self.endedAt = records.last.map { Date(timeIntervalSince1970: $0.timestamp) }
                self.applyDisplayFilter()
                if records.isEmpty { self.notice = "Ce fichier ne contient aucun paquet." }
                self.store?.record(command: "tcpdump -r \(url.lastPathComponent)")
            case .failure(let failure):
                self.error = "Ouverture impossible\u{00A0}: \((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)"
            }
        }
    }

    /// Enregistre tous les paquets, ou seulement ceux qu'affiche le filtre, en pcap classique.
    func save(displayedOnly: Bool) {
        let records = displayedOnly ? displayedPackets.map(\.record) : log.records
        guard !records.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = displayedOnly ? "Enregistrer les paquets affichés" : "Enregistrer la capture"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let base = (sourceName ?? interfaceName).replacingOccurrences(of: ".pcapng", with: "").replacingOccurrences(of: ".pcap", with: "")
        panel.nameFieldStringValue = "capture-\(base)-\(formatter.string(from: Date())).pcap"
        panel.allowedContentTypes = [UTType(filenameExtension: "pcap") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(try PcapFile.write(records)).write(to: url, options: .atomic)
            notice = "\(PacketText.number(records.count)) paquets enregistrés dans « \(url.lastPathComponent) » (pcap, ouvrable dans Wireshark)."
            error = nil
        } catch {
            self.error = "Enregistrement impossible\u{00A0}: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: Démonstration

    private func loadDemo() {
        interfaces = CaptureDemo.interfaces
        interfaceName = PacketCaptureDemo.interface
        bpfAvailable = false
        method = .demo
        phase = .finished
        sourceName = PacketCaptureDemo.interface
        stopReason = "arrêtée"
        let records = PacketCaptureDemo.records()
        log = PacketCaptureLog(records: records)
        startedAt = records.first.map { Date(timeIntervalSince1970: $0.timestamp) }
        endedAt = records.last.map { Date(timeIntervalSince1970: $0.timestamp) }
        filterSource = .unfiltered
        rows = log.packets.map(PacketRow.init)
        // Paquet choisi : le Client Hello TLS, champ SNI surligné dans l'hexadécimal.
        if let hello = log.packets.first(where: { $0.decoded.tlsHandshake == "Client Hello" }) {
            selection = hello.id
            if let sni = hello.decoded.firstField(named: "Nom du serveur (SNI)") { selectField(sni.id) }
        }
        switch ProcessInfo.processInfo.environment["NETSCOPE_CAPTURE_VUE"] {
        case "flux":
            // Flux en clair (HTTP vers l'imprimante) : plus parlant qu'un flux TLS chiffré.
            if let http = log.packets.first(where: { $0.decoded.httpRequest != nil }) { selection = http.id }
            followSelected()
        case "stats":
            pane = .statistics
        case "filtre":
            displayFilter = "tcp.analysis.flags || dns"
        default:
            break
        }
    }

    /// Capture fictive rejouée en quelques secondes (aucun accès réseau).
    private func startDemo() {
        method = .demo
        phase = .capturing
        startedAt = Date()
        let records = PacketCaptureDemo.records()
        let first = records.first?.timestamp ?? 0
        let now = Date().timeIntervalSince1970
        task = Task { [weak self] in
            for batch in stride(from: 0, to: records.count, by: 4) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                let slice = records[batch..<min(batch + 4, records.count)].map { record -> PacketRecord in
                    var copy = record
                    copy.timestamp = now + (record.timestamp - first)
                    return copy
                }
                self.append(Array(slice))
            }
            self?.finish(reason: "fin de la démonstration")
        }
    }
}

/// Ligne de la liste des paquets.
struct PacketRow: Identifiable, Equatable {
    let id: Int
    let time: Double
    let delta: Double
    let date: Date
    let source: String
    let destination: String
    let kind: PacketProtocol
    let protocolLabel: String
    let length: Int
    let summary: String
    let sourcePort: Int
    let destinationPort: Int
    let vlan: Int
    let ethSource: String
    let ethDestination: String
    let ttl: Int
    let isReset: Bool
    let isWarning: Bool

    init(_ packet: CapturedPacket) {
        id = packet.id
        time = packet.relativeTime
        delta = packet.delta
        date = packet.date
        source = packet.decoded.source
        destination = packet.decoded.destination
        kind = packet.decoded.topProtocol
        protocolLabel = packet.decoded.topProtocol.label
        length = packet.length
        summary = packet.summary
        sourcePort = packet.decoded.transport.map { Int($0.sourcePort) } ?? -1
        destinationPort = packet.decoded.transport.map { Int($0.destinationPort) } ?? -1
        vlan = packet.decoded.vlanIDs.last ?? -1
        ethSource = packet.decoded.ethSource?.formatted() ?? "—"
        ethDestination = packet.decoded.ethDestination?.formatted() ?? "—"
        ttl = packet.decoded.ttl ?? -1
        isReset = packet.analysis.contains(.reset)
        isWarning = packet.analysis.contains { $0.isProblem && $0 != .reset } || (!packet.decoded.problems.isEmpty && packet.decoded.transport == nil)
    }
}
