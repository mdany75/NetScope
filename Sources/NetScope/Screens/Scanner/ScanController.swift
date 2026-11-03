import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Message bref affiché après une action (copie, détection, fin de scan).
struct ScanToast: Equatable {
    enum Place { case ranges, actions }

    let text: String
    var tone: Tone = .success
    var place: Place = .ranges
    let id = UUID()

    static func == (lhs: ScanToast, rhs: ScanToast) -> Bool { lhs.id == rhs.id }
}

/// Pilote des scans : lance le moteur, fusionne les résultats dans `AppState.devices`, garde
/// l'avancement par plage, les nouveaux appareils et l'historique de latence.
/// Une seule instance, partagée (l'état survit quand on change d'écran).
@MainActor
final class ScanController: ObservableObject {
    static let shared = ScanController()

    /// État d'une plage pendant et après le scan.
    struct RangeStatus {
        var progress: ScanRangeProgress
        var startedAt: Date
        var finishedAt: Date?
    }

    @Published private(set) var isRunning = false
    @Published private(set) var phase: ScanPhase?
    /// Étapes prévues pour le scan en cours (les deux dernières seulement si la découverte SNMP est active).
    @Published private(set) var plannedPhases: [ScanPhase] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var status: [UUID: RangeStatus] = [:]
    /// Appareils apparus depuis le scan précédent (vide au tout premier scan).
    @Published private(set) var newIDs: Set<Device.ID> = []
    /// Latences mesurées, par appareil (30 dernières ; nil : sans réponse).
    @Published private(set) var latencyHistory: [Device.ID: [Double?]] = [:]
    @Published private(set) var measuring: Set<Device.ID> = []
    @Published private(set) var probing: Set<Device.ID> = []
    @Published var toast: ScanToast?
    /// Ports du profil personnalisé (« 22, 80, 8000-8010 »), conservés d'un lancement à l'autre.
    @Published var customPortsText: String {
        didSet { UserDefaults.standard.set(customPortsText, forKey: "scan.customPorts") }
    }

    private var scanTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var pingerCache: ICMPPinger?

    init() {
        customPortsText = UserDefaults.standard.string(forKey: "scan.customPorts") ?? "22, 80, 443, 3389, 8080"
    }

    /// Socket ICMP partagé, ouvert au premier besoin.
    private var pinger: ICMPPinger? {
        if pingerCache == nil { pingerCache = try? ICMPPinger() }
        return pingerCache
    }

    /// Durée du scan en cours, ou du dernier.
    func duration(at now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    // MARK: Scan

    func start(_ state: AppState) {
        guard !isRunning else { return }
        // Démonstration : les plages sont fictives mais pourraient exister sur le vrai réseau.
        guard !Launcher.isDemo else {
            show("Démonstration\u{00A0}: aucun scan réel n’est lancé, les résultats affichés sont fictifs.", tone: .neutral)
            return
        }
        let enabled = state.ranges.filter(\.isEnabled)
        var targets: [ScanTarget] = []
        var invalid: [String] = []
        for config in enabled {
            if let target = try? ScanTarget(config: config) { targets.append(target) } else { invalid.append(config.text) }
        }
        guard !targets.isEmpty else {
            show(enabled.isEmpty ? "Cochez au moins une plage à scanner." : "Aucune plage valide à scanner.", tone: .warning)
            return
        }
        let prefs = RegPrefs.shared
        let publicRanges = targets.filter(Self.hasPublicAddresses)
        if prefs.confirmPublicRanges, !publicRanges.isEmpty, !confirmPublic(publicRanges) { return }
        if !invalid.isEmpty {
            show("Plage ignorée (invalide) : \(invalid.joined(separator: ", "))", tone: .warning)
        }

        let customPorts = ScanProfile.parsePorts(customPortsText) ?? []
        let options = ScanOptions(profile: state.scanProfile, customPorts: customPorts)
        // Découverte SNMP des switchs : réglage automatique (activé par défaut) ou profil Complet.
        let discoversSwitches = prefs.autoDiscoverSwitches || state.scanProfile.alwaysDiscoversSwitches
        let readGatewayARP = prefs.readGatewayARP
        let probed = Set(options.ports)
        let pinger: any ScanPinging
        if let icmp = self.pinger {
            pinger = icmp
        } else {
            pinger = ScanNullPinger()
            show("Ping ICMP indisponible : seuls les appareils de la table ARP seront trouvés.", tone: .warning)
        }

        let baseline = Set(state.devices.map(\.id))
        let marksNew = !baseline.isEmpty
        newIDs = []
        let begin = Date()
        status = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.id, RangeStatus(progress: ScanRangeProgress(rangeID: $0.id, total: $0.range.count), startedAt: begin))
        })
        startedAt = begin
        finishedAt = nil
        isRunning = true
        phase = .ping
        plannedPhases = discoversSwitches ? ScanPhase.allCases : [.ping, .arp, .details]
        let switches = SwitchStore.shared
        switches.scanStarted(discovers: discoversSwitches)

        let stream = ScanEngine(pinger: pinger).scan(targets, options: options)
        scanTask = Task { [weak self] in
            var foundIDs = Set<Device.ID>()
            var sweep: Task<SNMPSweep, Never>?
            for await event in stream {
                guard let self else { return }
                switch event {
                case .started(let ranges):
                    for range in ranges { self.status[range.rangeID]?.progress = range }
                case .phase(let phase):
                    self.phase = phase
                    // Les hôtes en ligne sont connus après l'ARP : la découverte SNMP part tout de suite,
                    // en parallèle des noms et des ports.
                    if phase == .details, discoversSwitches, sweep == nil {
                        sweep = Self.startSweep(switches.discoveryTargets(Self.addresses(foundIDs)))
                    }
                case .deviceFound(let device, _), .deviceUpdated(let device, _):
                    if case .deviceFound = event, let latency = device.latencyMs { self.appendLatency(latency, for: device.id) }
                    foundIDs.insert(device.id)
                    self.absorb(device, into: state)
                    if marksNew, !baseline.contains(device.id) { self.newIDs.insert(device.id) }
                case .portsProbed(let ip, let open, _):
                    self.applyPorts(open, probed: probed, to: ip.description, in: state)
                case .rangeProgress(let progress):
                    self.status[progress.rangeID]?.progress = progress
                case .finished:
                    break
                }
            }
            guard let self else { return }
            // Arrêt pendant le ping, l'ARP, les noms ou les ports : seul ce cas empêche de marquer
            // hors ligne les appareils qui n'ont pas répondu.
            let engineCancelled = Task.isCancelled
            if discoversSwitches, !engineCancelled {
                self.phase = .switches
                let pending = sweep ?? Self.startSweep(switches.discoveryTargets(Self.addresses(foundIDs)))
                let swept = await withTaskCancellationHandler { await pending.value } onCancel: { pending.cancel() }
                _ = await switches.autoDiscover(state: state, discovered: swept.found, queried: swept.queried,
                                                communitiesTried: swept.communities, readGatewayARP: readGatewayARP) { phase in
                    self.phase = phase
                }
            } else {
                sweep?.cancel()
            }
            switches.scanEnded(interrupted: Task.isCancelled, planned: discoversSwitches)
            self.finish(state, targets: targets, found: foundIDs, engineCancelled: engineCancelled, snmpCancelled: Task.isCancelled)
        }
    }

    /// Résultat de la découverte SNMP faite pendant le scan.
    struct SNMPSweep: Sendable {
        var found: [SNMPDiscovered] = []
        var queried = 0
        var communities = 0
    }

    /// Découverte SNMP des hôtes donnés, hors du fil principal (communautés lues au Trousseau à ce
    /// moment-là, pas au clic sur « Scanner »).
    private static func startSweep(_ hosts: [IPv4Address]) -> Task<SNMPSweep, Never> {
        Task.detached(priority: .userInitiated) {
            let communities = RegSNMPDiscoveryVault.communities()
            guard !communities.isEmpty, !hosts.isEmpty else { return SNMPSweep(queried: hosts.count, communities: communities.count) }
            let found = await SNMPDiscovery(communities: communities).discover(hosts)
            return SNMPSweep(found: found, queried: hosts.count, communities: communities.count)
        }
    }

    private static func addresses(_ ids: Set<Device.ID>) -> [IPv4Address] {
        ids.compactMap(IPv4Address.init).sorted()
    }

    /// Vrai si une partie de la plage est faite d'adresses publiques (Internet).
    private static func hasPublicAddresses(_ target: ScanTarget) -> Bool {
        target.range.segments.contains { segment in
            let bounds = segment.bounds
            return AddressScope.of(bounds.first) == .publique || AddressScope.of(bounds.last) == .publique
        }
    }

    /// Réglages › Général › « Confirmer avant de scanner une plage publique ».
    private func confirmPublic(_ targets: [ScanTarget]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Scanner une plage publique\u{00A0}?"
        let list = targets.map { $0.range.description }.joined(separator: ", ")
        alert.informativeText = "Ces adresses sont sur Internet\u{00A0}: \(list). Ne scannez que des réseaux qui vous appartiennent ou que vous êtes autorisé à analyser. La découverte SNMP des switchs n’est jamais faite sur les adresses publiques."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Scanner quand même")
        alert.addButton(withTitle: "Annuler")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func stop() {
        scanTask?.cancel()
    }

    /// Efface les résultats (appareils, avancement, nouveautés, bilan des switchs).
    func clear(_ state: AppState) {
        stop()
        state.devices = []
        state.selectedDeviceID = nil
        status = [:]
        newIDs = []
        latencyHistory = [:]
        startedAt = nil
        finishedAt = nil
        SwitchStore.shared.clearResult()
    }

    /// Fusionne un appareil du scan avec ce qu'on savait déjà (emplacement de switch, ports, nom
    /// d'hôte) ; `firstSeen` et le nom personnalisé sont gardés par AppState. Les ports connus sont
    /// toujours gardés ici : seul `.portsProbed` les remplace.
    private func absorb(_ incoming: Device, into state: AppState) {
        var device = incoming
        if let known = state.device(withID: incoming.id) {
            device.mac = incoming.mac ?? known.mac
            device.vendor = incoming.vendor ?? known.vendor
            if incoming.hostname == nil, known.hostname != nil {
                device.hostname = known.hostname
                device.nameSource = known.nameSource
                device.nameDomain = known.nameDomain
            }
            device.snmpKind = incoming.snmpKind ?? known.snmpKind
            device.switchName = known.switchName
            device.switchPort = known.switchPort
            device.vlan = known.vlan ?? incoming.vlan
            device.rangeLabel = incoming.rangeLabel ?? known.rangeLabel
            device.openPorts = known.openPorts
            let guessed = ScanDeviceClassifier.guess(device)
            device.deviceType = guessed == .inconnu ? known.deviceType : guessed
        }
        state.merge([device])
    }

    /// Ports fraîchement sondés : ils remplacent ceux de la liste sondée ; les ports connus hors de
    /// cette liste (scan approfondi, profil plus large) sont gardés.
    private func applyPorts(_ open: [UInt16], probed: Set<UInt16>, to id: Device.ID, in state: AppState) {
        guard var device = state.device(withID: id) else { return }
        device.openPorts = Self.mergedPorts(open, probed: probed, known: device.openPorts)
        let guessed = ScanDeviceClassifier.guess(device)
        if guessed != .inconnu { device.deviceType = guessed }
        state.merge([device])
    }

    static func mergedPorts(_ open: [UInt16], probed: Set<UInt16>, known: [UInt16]) -> [UInt16] {
        Array(Set(open).union(known.filter { !probed.contains($0) })).sorted()
    }

    private func finish(_ state: AppState, targets: [ScanTarget], found: Set<Device.ID>, engineCancelled: Bool,
                        snmpCancelled: Bool) {
        let end = Date()
        // Appareils connus des plages scannées qui n'ont pas répondu : hors ligne.
        if !engineCancelled {
            let missing = state.devices.filter { device in
                device.isOnline && !found.contains(device.id) && targets.contains { $0.range.contains(device.ip) }
            }
            state.merge(missing.map { device in
                var copy = device
                copy.isOnline = false
                copy.latencyMs = nil
                return copy
            })
        }
        for id in status.keys { status[id]?.finishedAt = end }
        finishedAt = end
        isRunning = false
        phase = nil
        scanTask = nil
        let online = state.devices.filter { device in device.isOnline && targets.contains { $0.range.contains(device.ip) } }.count
        let seconds = ScanFormat.seconds(end.timeIntervalSince(startedAt ?? end))
        if engineCancelled {
            show("Scan arrêté après \(seconds) : \(online) appareils en ligne.", tone: .warning)
        } else if snmpCancelled {
            show("Scan terminé en \(seconds) : \(online) appareils en ligne, \(newIDs.count) nouveaux (étape SNMP arrêtée).", tone: .warning)
        } else {
            show("Scan terminé en \(seconds) : \(online) appareils en ligne, \(newIDs.count) nouveaux.")
        }
    }

    // MARK: Actions sur un appareil

    private func appendLatency(_ value: Double?, for id: Device.ID) {
        var history = latencyHistory[id] ?? []
        history.append(value)
        if history.count > 30 { history.removeFirst(history.count - 30) }
        latencyHistory[id] = history
    }

    /// 30 pings, un toutes les 300 ms, pour la courbe du panneau de détail.
    func measureLatency(of device: Device) {
        guard !measuring.contains(device.id) else { return }
        guard let pinger else {
            show("Ping ICMP indisponible sur ce Mac.", tone: .critical, place: .actions)
            return
        }
        measuring.insert(device.id)
        latencyHistory[device.id] = []
        let ip = device.ip
        Task { [weak self] in
            for index in 0..<30 {
                let rtt = await pinger.ping(ip, timeout: .seconds(1))
                guard let self else { return }
                self.appendLatency(rtt, for: device.id)
                if index < 29 { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
            self?.measuring.remove(device.id)
        }
    }

    /// Scan approfondi des ports d'un seul appareil (environ 1000 ports TCP, profil Complet).
    func probePorts(of device: Device, state: AppState) {
        guard !probing.contains(device.id) else { return }
        guard !Launcher.isDemo else {
            show("Démonstration\u{00A0}: aucun port n’est sondé sur cet appareil fictif.", tone: .neutral, place: .actions)
            return
        }
        probing.insert(device.id)
        let ip = device.ip
        let id = device.id
        Task { [weak self] in
            let open = await PortProber().openPorts(ip, ports: ScanProfile.extendedPorts, timeout: .milliseconds(800), concurrency: 64)
            guard let self else { return }
            self.probing.remove(id)
            if var current = state.device(withID: id) {
                current.openPorts = Self.mergedPorts(open, probed: Set(ScanProfile.extendedPorts), known: current.openPorts)
                current.lastSeen = Date()
                let guessed = ScanDeviceClassifier.guess(current)
                if guessed != .inconnu { current.deviceType = guessed }
                state.merge([current])
            }
            self.show(open.isEmpty ? "Aucun port ouvert sur \(ip) (\(ScanProfile.extendedPorts.count) ports sondés)." : "\(open.count) ports ouverts sur \(ip) (\(ScanProfile.extendedPorts.count) ports sondés).", place: .actions)
        }
    }

    /// Paquet magique Wake-on-LAN, diffusé sur le réseau de l'appareil.
    func wake(_ device: Device, state: AppState) {
        guard let mac = device.mac else {
            show("Adresse MAC inconnue : réveil impossible.", tone: .warning, place: .actions)
            return
        }
        var broadcast = IPv4Address(255, 255, 255, 255)
        if let interface = state.activeInterface, interface.subnet.contains(device.ip) {
            broadcast = interface.subnet.broadcast
        }
        do {
            try ScanWakeOnLAN.send(to: mac, broadcast: broadcast)
            show("Paquet magique envoyé à \(mac.formatted(.upperColon)) (\(broadcast)).", place: .actions)
        } catch {
            show(error.localizedDescription, tone: .critical, place: .actions)
        }
    }

    // MARK: Réseau local

    /// « Détecter mon réseau » : ajoute le réseau de l'interface active s'il n'est pas déjà listé.
    func detectNetwork(_ state: AppState) {
        Task {
            let suggestions = await ScanNetwork.suggestions()
            guard let suggestion = suggestions.first else {
                show("Aucune interface réseau active n’a été trouvée.", tone: .warning)
                return
            }
            fillLocalInfo(state, interface: suggestion.interface)
            let text = suggestion.subnet.description
            let suggested = try? IPRange(parsing: text)
            let exists = state.ranges.contains { $0.text == text || (try? $0.parsed()) == suggested }
            if exists {
                show("Réseau détecté : \(text) via \(suggestion.interface.name) (déjà dans la liste)", tone: .neutral)
            } else {
                state.ranges.append(ScanRangeConfig(text: text, label: suggestion.label))
                show("Réseau détecté : \(text) via \(suggestion.interface.name), ajouté aux plages")
            }
        }
    }

    /// Complète l'interface active (passerelle) et les serveurs DNS, lus sur la machine
    /// (table de routage, /etc/resolv.conf), hors du fil principal.
    func fillLocalInfo(_ state: AppState, interface: LocalInterface? = nil) {
        let needsGateway = state.activeInterface.map { $0.gateway == nil } ?? (interface != nil)
        let needsDNS = state.dnsServers.isEmpty
        guard needsGateway || needsDNS else { return }
        Task {
            let (gateway, servers) = await Task.detached(priority: .utility) {
                (needsGateway ? (interface?.gateway ?? ScanNetwork.defaultGateway()) : nil,
                 needsDNS ? ScanNetwork.dnsServers() : [])
            }.value
            if var active = state.activeInterface ?? interface, active.gateway == nil,
               let gateway, active.subnet.contains(gateway) {
                active.gateway = gateway
                state.activeInterface = active
            } else if state.activeInterface == nil, let interface {
                state.activeInterface = interface
            }
            if state.dnsServers.isEmpty, !servers.isEmpty { state.dnsServers = servers }
        }
    }

    // MARK: Divers

    func show(_ text: String, tone: Tone = .success, place: ScanToast.Place = .ranges) {
        let toast = ScanToast(text: text, tone: tone, place: place)
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.toast == toast else { return }
            self.toast = nil
        }
    }

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("\(label) copiée : \(text)", place: .actions)
    }

    /// Exporte les appareils en CSV (fenêtre d'enregistrement).
    func exportCSV(_ devices: [Device]) {
        let panel = NSSavePanel()
        panel.title = "Exporter les résultats du scan"
        panel.prompt = "Exporter"
        panel.allowedContentTypes = [.commaSeparatedText]
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "NetScope-scan-\(day).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ScanCSV.data(devices).write(to: url, options: .atomic)
            show("\(devices.count) appareils exportés dans \(url.lastPathComponent)")
        } catch {
            show("Export impossible : \(error.localizedDescription)", tone: .critical)
        }
    }
}
