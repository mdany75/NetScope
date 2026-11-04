import NetScopeCore
import SwiftUI

/// Test DHCP : un DHCPDISCOVER en broadcast, puis toutes les offres reçues pendant quelques
/// secondes. Jamais de DHCPREQUEST : aucun bail n'est pris, la configuration du Mac ne change pas.
///
/// Réception, dans l'ordre : port UDP 68 partagé avec macOS (sans droits) ; sinon capture BPF si
/// /dev/bpf est déjà ouvrable ; sinon tcpdump lancé une fois avec les droits d'administrateur.
@MainActor
final class ToolDHCPModel: ObservableObject {
    enum Phase: Equatable {
        case idle, authorizing, listening, finished
    }

    enum Reception: Equatable {
        case sharedPort, bpf, privileged, demo

        var label: String {
            switch self {
            case .sharedPort: return "réception sur le port UDP\u{00A0}68 partagé avec macOS"
            case .bpf: return "réception par BPF (accès direct aux trames)"
            case .privileged: return "réception par tcpdump (droits d’administrateur)"
            case .demo: return "démonstration"
            }
        }
    }

    @Published var interfaces: [LocalInterface] = []
    @Published var interfaceName = ""
    @Published var wait = 5
    @Published var allowedText = "" {
        didSet { if !isEphemeral { UserDefaults.standard.set(allowedText, forKey: Self.allowedKey) } }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var deadline: Date?
    @Published private(set) var offers: [DHCPOffer] = []
    @Published var selectedServer: IPv4Address?
    @Published private(set) var reception: Reception?
    /// Le port 68 est refusé et BPF n'est pas ouvrable : il faut l'autorisation d'administrateur.
    @Published private(set) var needsPrivilege = false
    @Published private(set) var lastRun: Date?
    @Published var error: String?
    /// Emplacements connus hors inventaire (démonstration).
    private(set) var extraLocations: [MACAddress: String] = [:]

    static let waits = [5, 10]
    private static let allowedKey = "NetScope.outils.dhcp.autorises"
    private let isDemo: Bool
    private let isEphemeral: Bool
    private var session: PrivilegedCaptureSession?
    /// « Arrêter » cliqué : la fin de la capture n'est pas une erreur.
    private var stopRequested = false
    private var task: Task<Void, Never>?
    /// Heure d'envoi du DISCOVER pendant une capture tcpdump (délai de réponse des offres).
    private var privilegedSentAt: Date?

    init() {
        let arguments = CommandLine.arguments
        isDemo = arguments.contains("--demo")
        isEphemeral = isDemo || arguments.contains("--snapshot")
        if isDemo {
            interfaces = CaptureDemo.interfaces
            interfaceName = "en0"
            allowedText = "10.182.122.1"
            offers = CaptureDemo.offers()
            selectedServer = offers.last?.server
            reception = .demo
            phase = .finished
            lastRun = Date().addingTimeInterval(-240)
            extraLocations = CaptureDemo.locations
        } else if !isEphemeral {
            allowedText = UserDefaults.standard.string(forKey: Self.allowedKey) ?? ""
        }
    }

    var isRunning: Bool { phase == .authorizing || phase == .listening }
    var policy: DHCPServerPolicy { DHCPServerPolicy(text: allowedText) }
    var command: String { "dhcp-probe -i \(interfaceName.isEmpty ? "en0" : interfaceName) -t \(wait)" }
    var selectedInterface: LocalInterface? { interfaces.first { $0.name == interfaceName } }

    func prepare(active: LocalInterface?) async {
        guard !isDemo else { return }
        // Aussi les interfaces sans bail (aucune adresse, ou 169.254.x.x) : c'est le cas à tester.
        let list = await LocalInterfaces.linkInterfacesWithKinds()
        interfaces = list
        if interfaceName.isEmpty || !list.contains(where: { $0.name == interfaceName }) {
            interfaceName = LocalInterfaces.preferredLinkInterface(in: list, preferred: active?.name)?.name ?? ""
        }
    }

    // MARK: Test

    /// Lance le test. `privileged` : capture par tcpdump (après le refus du port 68).
    func run(store: ToolStore, privileged: Bool = false) {
        guard !isRunning else { return }
        error = nil
        let name = interfaceName
        guard CaptureInterfaceName.isValid(name) else {
            error = "Choisissez une interface réseau."
            return
        }
        if !policy.invalid.isEmpty {
            error = "Adresse illisible dans les serveurs autorisés\u{00A0}: " + policy.invalid.joined(separator: ", ") + "."
            return
        }
        if isDemo {
            store.record(command: command)
            runDemo(store: store)
            return
        }
        guard let mac = LinkLayer.macAddress(of: name) else {
            error = "Adresse MAC de \(name) introuvable."
            return
        }
        store.record(command: command)
        offers = []
        selectedServer = nil
        needsPrivilege = false
        stopRequested = false
        let xid = DHCPDiscover.randomXID()
        let packet = DHCPDiscover.build(xid: xid, mac: mac)
        let seconds = TimeInterval(wait)
        if privileged {
            runPrivileged(name, xid: xid, packet: packet, seconds: seconds, store: store)
            return
        }
        phase = .listening
        deadline = Date().addingTimeInterval(seconds)
        task = Task { [weak self] in
            // 1) Port 68 partagé (sans droits).
            let shared: (offers: [DHCPOffer], bound: Bool, error: String?) = await Task.detached {
                do {
                    guard let fd = try DHCPProbe.openSocket(interface: name, port: DHCPProbe.clientPort) else { return ([], false, nil) }
                    defer { close(fd) }
                    let sentAt = Date()
                    try DHCPProbe.send(packet, fd: fd)
                    return (DHCPProbe.receive(fd: fd, xid: xid, until: sentAt.addingTimeInterval(seconds), sentAt: sentAt), true, nil)
                } catch {
                    return ([], true, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }.value
            guard let self else { return }
            if shared.bound {
                self.reception = .sharedPort
                self.error = shared.error
                self.complete(shared.offers, xid: xid, store: store)
                return
            }
            // 2) Port refusé : capture BPF si elle est déjà permise.
            if await Task.detached(operation: { BPFCapture.readableDevice() != nil }).value {
                self.reception = .bpf
                self.deadline = Date().addingTimeInterval(seconds)
                let result: (offers: [DHCPOffer], error: String?) = await Task.detached {
                    do {
                        let capture = try BPFCapture(interface: name, filter: BPFFilter.dhcpClient, promiscuous: false)
                        defer { capture.stop() }
                        let sentAt = try Self.sendFromFreePort(packet, interface: name)
                        var found: [DHCPOffer] = []
                        while Date() < sentAt.addingTimeInterval(seconds) {
                            for frame in capture.read(timeout: 0.3) {
                                guard var offer = DHCPParser.parseFrame(frame.bytes), offer.xid == xid else { continue }
                                offer.delay = (frame.date ?? Date()).timeIntervalSince(sentAt)
                                found.append(offer)
                            }
                        }
                        return (found, nil)
                    } catch {
                        return ([], (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    }
                }.value
                self.error = result.error
                self.complete(result.offers, xid: xid, store: store)
                return
            }
            // 3) Il faut l'autorisation d'administrateur : on l'explique et on attend le clic.
            self.phase = .idle
            self.deadline = nil
            self.needsPrivilege = true
        }
    }

    private func runPrivileged(_ name: String, xid: UInt32, packet: [UInt8], seconds: TimeInterval, store: ToolStore) {
        let session: PrivilegedCaptureSession
        do {
            session = try PrivilegedCaptureSession(interface: name, purpose: .dhcp, seconds: min(Int(seconds) + 30, 180))
            try session.start { [weak self] outcome in
                Task { @MainActor in self?.sessionEnded(outcome, xid: xid, store: store) }
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        self.session = session
        privilegedSentAt = nil
        reception = .privileged
        phase = .authorizing
        deadline = nil
        task = Task { [weak self] in
            // Le DISCOVER ne part qu'une fois tcpdump à l'écoute.
            while !Task.isCancelled, !session.isListening {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.phase = .listening
            self.deadline = Date().addingTimeInterval(seconds)
            do {
                self.privilegedSentAt = try await Task.detached { try Self.sendFromFreePort(packet, interface: name) }.value
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            session.stop()
        }
    }

    private func sessionEnded(_ outcome: PrivilegedCaptureSession.Outcome, xid: UInt32, store: ToolStore) {
        guard let session else { return }
        task?.cancel()
        let sentAt = privilegedSentAt
        privilegedSentAt = nil
        // Délai de réponse : horodatage tcpdump de la trame moins l'heure d'envoi du DISCOVER.
        let found = session.frames(final: true).compactMap { frame -> DHCPOffer? in
            guard var offer = DHCPParser.parseFrame(frame.bytes) else { return nil }
            if let sentAt, let date = frame.date, date >= sentAt.addingTimeInterval(-1) {
                offer.delay = max(0, date.timeIntervalSince(sentAt))
            }
            return offer
        }
        switch outcome {
        case .finished:
            if !session.isListening, let message = TcpdumpHexParser.errorMessage(session.errorText) {
                error = "tcpdump n’a pas pu écouter\u{00A0}: \(message)"
            }
        case .cancelled:
            error = stopRequested ? nil : "Autorisation annulée\u{00A0}: aucune offre n’a été lue."
        case .failed(let message):
            error = stopRequested ? nil : "La capture n’a pas pu démarrer" + (message.isEmpty ? "." : "\u{00A0}: \(message)")
        }
        session.cleanup()
        self.session = nil
        if outcome == .finished {
            needsPrivilege = false
            complete(found, xid: xid, store: store)
        } else {
            phase = .idle
            deadline = nil
        }
    }

    func cancel() {
        if let session {
            stopRequested = true
            if phase == .authorizing { session.cancel() } else { session.stop() }
        }
    }

    /// Envoie le DISCOVER depuis un port libre (drapeau broadcast : la réponse va en broadcast).
    nonisolated private static func sendFromFreePort(_ packet: [UInt8], interface: String) throws -> Date {
        guard let fd = try DHCPProbe.openSocket(interface: interface, port: 0) else {
            throw ToolError.socket("aucun port UDP libre")
        }
        defer { close(fd) }
        try DHCPProbe.send(packet, fd: fd)
        return Date()
    }

    private func complete(_ received: [DHCPOffer], xid: UInt32, store: ToolStore) {
        var list = DHCPServerPolicy.uniqueServers(received, xid: xid)
        // MAC des serveurs reçus par socket : table ARP de ce Mac (lecture locale).
        if list.contains(where: { $0.sourceMAC == nil }) {
            let arp = ARPTable().read()
            for index in list.indices where list[index].sourceMAC == nil {
                if let ip = list[index].sourceAddress ?? list[index].serverIdentifier { list[index].sourceMAC = arp[ip] }
            }
        }
        offers = list
        selectedServer = list.first { policy.status(of: $0) == .unauthorized }?.server ?? list.first?.server
        phase = .finished
        deadline = nil
        lastRun = Date()
        record(store: store)
    }

    private func record(store: ToolStore) {
        let target = "\(interfaceName)" + (selectedInterface.flatMap { $0.hasIPv4 ? " · \($0.subnet)" : nil } ?? "")
        let rogue = offers.filter { policy.status(of: $0) == .unauthorized }
        if offers.isEmpty {
            store.record(ToolRecent(tool: .dhcp, target: target, summary: "Aucune offre en \(wait)\u{00A0}s", status: .warning))
        } else if !rogue.isEmpty {
            let names = rogue.compactMap { $0.server?.description }.joined(separator: ", ")
            store.record(ToolRecent(tool: .dhcp, target: target,
                                    summary: "\(offers.count) serveur\(offers.count > 1 ? "s" : ""), dont \(names) non autorisé",
                                    status: .warning))
        } else {
            store.record(ToolRecent(tool: .dhcp, target: target,
                                    summary: offers.compactMap { $0.server?.description }.joined(separator: ", ") + " · " + "\(offers.count) serveur\(offers.count > 1 ? "s" : "")",
                                    status: .ok))
        }
    }

    private func runDemo(store: ToolStore) {
        offers = []
        reception = .demo
        phase = .listening
        deadline = Date().addingTimeInterval(TimeInterval(wait))
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.wait ?? 5) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.complete(CaptureDemo.offers(), xid: CaptureDemo.xid, store: store)
        }
    }

    /// Emplacement physique du serveur (inventaire ou démonstration).
    func location(of offer: DHCPOffer, devices: [Device]) -> String? {
        guard let mac = offer.sourceMAC else { return nil }
        if let device = devices.first(where: { $0.mac == mac }), let place = device.switchLocation {
            return place + (device.vlan.map { " · VLAN \($0)" } ?? "")
        }
        return extraLocations[mac]
    }
}

// MARK: - Vue

/// Test DHCP (croquis : section « Test DHCP » de Toolbox.dc.html).
struct DHCPTestView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolDHCPModel
    @ObservedObject var store: ToolStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            if model.needsPrivilege { privilegeNotice }
            if model.isRunning { runningNotice }
            if model.phase == .finished { verdict }
            if !model.offers.isEmpty {
                table
                if let offer = model.offers.first(where: { $0.server == model.selectedServer }) ?? model.offers.first {
                    detail(offer)
                }
            }
            if model.phase == .idle && !model.needsPrivilege {
                Text("Le DHCPDISCOVER part en broadcast avec l’adresse MAC de l’interface. Les offres sont seulement lues\u{00A0}: NetScope n’envoie jamais de DHCPREQUEST, aucun bail n’est pris et la configuration du Mac ne change pas.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.prepare(active: state.activeInterface) }
    }

    // MARK: Contrôles

    /// Champs et bouton sur une ligne s'ils y tiennent, sinon le bouton passe dessous (croquis : flex-wrap).
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                fields
                sendButton
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) { fields }
                sendButton
            }
        }
    }

    @ViewBuilder private var fields: some View {
        ToolLabeledField(label: "Interface") {
            Picker("", selection: $model.interfaceName) {
                if model.interfaces.isEmpty { Text("aucune interface").tag("") }
                ForEach(model.interfaces, id: \.name) { iface in
                    Text(iface.linkSummary).tag(iface.name)
                }
            }
            .labelsHidden()
            .frame(minWidth: 140, minHeight: 34, maxHeight: 34)
        }
        .fixedSize()
        ToolLabeledField(label: "Attente des offres") {
            Picker("", selection: $model.wait) {
                ForEach(ToolDHCPModel.waits, id: \.self) { Text("\($0)\u{00A0}s").tag($0) }
            }
            .labelsHidden()
            .frame(width: 80, height: 34)
        }
        .fixedSize()
        ToolLabeledField(label: "Serveurs autorisés") {
            ToolTextField(placeholder: "10.182.122.1", text: $model.allowedText, invalid: !model.policy.invalid.isEmpty)
                .frame(minWidth: 150)
        }
    }

    private var sendButton: some View {
        Button { model.run(store: store) } label: {
            Text("Envoyer DHCPDISCOVER")
        }
        .buttonStyle(.primary)
        .fixedSize()
        .disabled(model.isRunning || model.interfaceName.isEmpty)
    }

    private var privilegeNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolNotice(tone: .warning, title: "Le port UDP\u{00A0}68 est tenu par macOS",
                       message: "macOS (configd) garde le port des réponses DHCP et ce Mac ne permet pas la lecture directe des trames (/dev/bpf). Pour lire les offres, NetScope lance tcpdump une seule fois avec votre autorisation (fenêtre de macOS), en lecture seule, filtre fixe «\u{00A0}udp dst port 68\u{00A0}», puis envoie le DHCPDISCOVER.")
            Button { model.run(store: store, privileged: true) } label: {
                Label("Capturer avec les droits administrateur", systemImage: "lock.open")
            }
            .buttonStyle(.primary)
            .fixedSize()
        }
    }

    private var runningNotice: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.phase == .authorizing ? "En attente de l’autorisation de macOS…" : "Écoute des offres DHCP sur \(model.interfaceName)…")
                        .font(Theme.bodySemibold)
                    Text(model.phase == .authorizing
                         ? "Le DHCPDISCOVER partira dès que tcpdump écoute."
                         : "DHCPDISCOVER envoyé · \(model.reception?.label ?? "")")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if let deadline = model.deadline {
                    Text("\(max(0, Int(deadline.timeIntervalSince(context.date).rounded())))\u{00A0}s")
                        .font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                if model.reception == .privileged {
                    Button("Arrêter") { model.cancel() }.buttonStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Color(hex: 0xBFDBFE)))
        }
    }

    // MARK: Bilan

    @ViewBuilder private var verdict: some View {
        let policy = model.policy
        let rogue = model.offers.filter { policy.status(of: $0) == .unauthorized }
        if model.offers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ToolNotice(tone: .warning, title: "Aucune offre DHCP en \(model.wait)\u{00A0}s",
                           message: "Aucun serveur n’a répondu sur \(model.interfaceName). Vérifiez le câble et le VLAN du port, ou relancez avec 10\u{00A0}s d’attente." + (model.reception == .sharedPort ? " Si macOS garde les réponses pour lui, la capture avec les droits d’administrateur les montrera." : ""))
                if model.reception == .sharedPort {
                    Button { model.run(store: store, privileged: true) } label: {
                        Label("Capturer avec les droits administrateur", systemImage: "lock.open")
                    }
                    .buttonStyle(.secondary)
                    .fixedSize()
                }
            }
        } else if let first = rogue.first {
            rogueAlert(first, rogueCount: rogue.count)
        } else if policy.allowed.isEmpty {
            ToolNotice(tone: .accent, title: summaryTitle(policy),
                       message: "Saisissez les serveurs autorisés pour repérer un serveur DHCP non autorisé.")
        } else {
            ToolNotice(tone: .success, title: summaryTitle(policy),
                       message: "Tous les serveurs qui répondent sont dans la liste des serveurs autorisés · \(model.reception?.label ?? "").")
        }
    }

    /// « 2 serveurs DHCP répondent : 10.182.122.1 (attendu) et 10.182.122.250 (NON AUTORISÉ) »
    private func summaryTitle(_ policy: DHCPServerPolicy) -> String {
        let parts = model.offers.map { offer -> String in
            let ip = offer.server?.description ?? "?"
            switch policy.status(of: offer) {
            case .expected: return "\(ip) (attendu)"
            case .unauthorized: return "\(ip) (NON AUTORISÉ)"
            case .unchecked: return ip
            }
        }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " et " + parts.last! : parts.joined()
        let count = model.offers.count
        return count > 1 ? "\(count) serveurs DHCP répondent\u{00A0}: \(list)" : "1 serveur DHCP répond\u{00A0}: \(list)"
    }

    private func rogueAlert(_ offer: DHCPOffer, rogueCount: Int) -> some View {
        let vendor = offer.sourceMAC.flatMap { OUIDatabase.builtIn.vendor(for: $0) }
        var message = "Le serveur non autorisé distribue \(offer.subnet?.description ?? offer.offeredAddress.description)"
        if let gateway = offer.routers.first { message += " avec la passerelle \(gateway)" }
        if isHomeRouter(offer, vendor: vendor) { message += " — probablement un routeur domestique branché à l’envers" }
        message += "."
        let location = model.location(of: offer, devices: state.devices)
        if let location { message += " Localisé sur \(location)." }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryTitle(model.policy)).font(Theme.bodySemibold).foregroundStyle(Color(hex: 0x9A3412))
                    .fixedSize(horizontal: false, vertical: true)
                Text(message).font(Theme.small).foregroundStyle(Color(hex: 0x7C2D12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    if let mac = offer.sourceMAC {
                        Button("Voir le port de switch →") {
                            SwitchStore.shared.find(mac.formatted(.upperColon), devices: state.devices)
                            state.open(.switchs)
                        }
                    }
                    Button("Créer une alerte →") { createAlert(offer, location: location) }
                    Button("Copier le rapport") { ToolActions.copy(report()) }
                        .font(Theme.body)
                }
                .buttonStyle(.plain)
                .font(Theme.bodySemibold)
                .foregroundStyle(Color(hex: 0x9A3412))
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.warningSoft))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Color(hex: 0xFDBA74)))
    }

    /// Ajoute l'alerte « Serveur DHCP non autorisé » dans Analyse (sans doublon sur 24 h) et y mène.
    private func createAlert(_ offer: DHCPOffer, location: String?) {
        let inventory = InvModel.shared
        let ip = offer.sourceAddress ?? offer.serverIdentifier ?? offer.offeredAddress
        let mac = offer.sourceMAC
        let key = mac.flatMap { m in inventory.store.records.values.first { $0.mac == m }?.key }
            ?? inventory.store.record(forIP: ip)?.key
            ?? (mac.map(InventoryStore.key(mac:)) ?? "ip:\(ip)")
        var detail = "Offre \(offer.offeredAddress)"
        if let gateway = offer.routers.first { detail += " · passerelle \(gateway)" }
        if let mac {
            detail += " · MAC \(mac.formatted(.upperColon))"
            if let vendor = OUIDatabase.builtIn.vendor(for: mac) { detail += " (\(vendor))" }
        }
        if let location { detail += " · \(location)" }
        detail += " · vu sur \(model.interfaceName) par le Test DHCP"
        let event = InvEvent(date: Date(), kind: .dhcpNonAutorise, severity: .critique, key: key, ip: ip,
                             title: "Serveur DHCP non autorisé\u{00A0}: \(ip)", detail: detail)
        inventory.addAlert(event)
        inventory.updateBadge(state)
        state.open(.analyse)
    }

    /// Fabricant grand public ou plage domestique par défaut (192.168.0.x, 192.168.1.x).
    private func isHomeRouter(_ offer: DHCPOffer, vendor: String?) -> Bool {
        let brands = ["tp-link", "netgear", "d-link", "asus", "linksys", "tenda", "belkin", "huawei", "zyxel", "xiaomi"]
        if let vendor = vendor?.lowercased(), brands.contains(where: vendor.contains) { return true }
        let text = offer.offeredAddress.description
        return text.hasPrefix("192.168.0.") || text.hasPrefix("192.168.1.")
    }

    private func report() -> String {
        let policy = model.policy
        var lines = ["Test DHCP · \(model.interfaceName) · \(model.lastRun.map { ToolText.time($0) } ?? "")", summaryTitle(policy)]
        for offer in model.offers {
            let status: String
            switch policy.status(of: offer) {
            case .expected: status = "attendu"
            case .unauthorized: status = "NON AUTORISÉ"
            case .unchecked: status = "non vérifié"
            }
            lines.append("\(offer.server?.description ?? "?") · \(offer.sourceMAC?.formatted(.upperColon) ?? "MAC inconnue") · offre \(offer.offeredAddress) · passerelle \(offer.routers.map(\.description).joined(separator: ", ")) · DNS \(offer.dnsServers.map(\.description).joined(separator: ", ")) · bail \(DHCPOffer.leaseText(offer.leaseTime)) · \(status)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Tableau et détail

    /// Sept colonnes sur une ligne, comme le croquis (MAC / fabricant prend la place qui reste) ;
    /// si la largeur manque, le tableau défile horizontalement (croquis : min-width 680 px).
    private var table: some View {
        ViewThatFits(in: .horizontal) {
            tableBody
            ScrollView(.horizontal, showsIndicators: true) { tableBody }
        }
    }

    private var tableBody: some View {
        ToolTable(columns: [
            .init(title: "Serveur", width: 120),
            .init(title: "MAC / fabricant"),
            .init(title: "IP offerte", width: 120),
            .init(title: "Passerelle", width: 108),
            .init(title: "DNS", width: 108),
            .init(title: "Bail", width: 52),
            .init(title: "Statut", width: 112),
        ]) {
            ForEach(Array(model.offers.enumerated()), id: \.offset) { _, offer in
                row(offer)
            }
        }
    }

    private func row(_ offer: DHCPOffer) -> some View {
        let status = model.policy.status(of: offer)
        let selected = offer.server == model.selectedServer
        let vendor = offer.sourceMAC.flatMap { OUIDatabase.builtIn.vendor(for: $0) }
        return ToolTableRow(height: 36, highlight: status == .unauthorized ? Color(hex: 0xFEF2F2) : (selected ? Theme.accentSoft : nil)) {
            Text(offer.server?.description ?? "?").font(Theme.mono(12, weight: .semibold)).toolCell(120)
            (Text(offer.sourceMAC?.formatted(.upperColon) ?? "inconnue").font(Theme.mono(12))
             + Text(vendor.map { " · \($0)" } ?? "").font(Theme.body).foregroundColor(Theme.textSecondary))
                .truncationMode(.tail)
                .toolCell(nil)
            Text(offer.offeredAddress.description).font(Theme.mono(12)).toolCell(120)
            Text(offer.routers.first?.description ?? "—").font(Theme.mono(12)).toolCell(108)
            Text(offer.dnsServers.first?.description ?? "—").font(Theme.mono(12)).toolCell(108)
            Text(DHCPOffer.leaseText(offer.leaseTime)).font(Theme.body).toolCell(52)
            statusChip(status).toolCell(112)
        }
        .help(offer.dnsServers.count > 1 ? "DNS\u{00A0}: " + offer.dnsServers.map(\.description).joined(separator: ", ") : "")
        .contentShape(Rectangle())
        .onTapGesture { model.selectedServer = offer.server }
    }

    @ViewBuilder private func statusChip(_ status: DHCPServerPolicy.Status) -> some View {
        switch status {
        case .expected: Chip(text: "Attendu", tone: .success)
        case .unauthorized: Chip(text: "NON AUTORISÉ", tone: .critical)
        case .unchecked: Chip(text: "Non vérifié", tone: .neutral)
        }
    }

    private func detail(_ offer: DHCPOffer) -> some View {
        var cells: [ToolCell] = [
            ToolCell(key: "Serveur (option 54)", value: offer.serverIdentifier?.description ?? "—",
                     detail: offer.sourceAddress.flatMap { $0 != offer.serverIdentifier ? "envoyé par \($0)" : nil }),
            ToolCell(key: "Adresse proposée", value: offer.offeredAddress.description, detail: offer.subnet.map { "réseau \($0)" }),
            ToolCell(key: "Masque (1)", value: offer.subnetMask?.description ?? "—", detail: offer.subnet.map { "/\($0.prefix)" }),
            ToolCell(key: "Passerelle (3)", value: offer.routers.map(\.description).joined(separator: ", ").ifEmpty("—")),
            ToolCell(key: "DNS (6)", value: offer.dnsServers.map(\.description).joined(separator: ", ").ifEmpty("—")),
            ToolCell(key: "Domaine (15)", value: offer.domainName ?? "—"),
            ToolCell(key: "Bail (51)", value: DHCPOffer.leaseText(offer.leaseTime),
                     detail: offer.leaseTime.map { "\(ToolFormat.integer($0))\u{00A0}s" }),
            ToolCell(key: "T1 · T2 (58, 59)", value: "\(DHCPOffer.leaseText(offer.renewalTime)) · \(DHCPOffer.leaseText(offer.rebindingTime))"),
            ToolCell(key: "Délai de réponse", value: offer.delay.map { ToolFormat.milliseconds($0 * 1000) } ?? "—",
                     detail: model.reception?.label),
        ]
        if let tftp = offer.tftpServer { cells.append(ToolCell(key: "TFTP (66)", value: tftp)) }
        if let file = offer.bootFile ?? offer.bootFileHeader { cells.append(ToolCell(key: "Fichier d’amorçage (67)", value: file)) }
        if let vendor = offer.vendorSpecificHex { cells.append(ToolCell(key: "Fabricant (43)", value: vendor)) }
        if let relay = offer.relayAgent { cells.append(ToolCell(key: "Relais (giaddr)", value: relay.description)) }
        if let next = offer.nextServer { cells.append(ToolCell(key: "Serveur suivant (siaddr)", value: next.description)) }
        if let ntp = offer.ntpServers.first { cells.append(ToolCell(key: "NTP (42)", value: ntp.description)) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ToolFieldLabel("Détail de l’offre · \(offer.server?.description ?? "")")
                Spacer()
                Text("options " + offer.optionCodes.map(String.init).joined(separator: ", "))
                    .font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            ToolCellGrid(cells: cells, columns: 3, valueSize: 13)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
