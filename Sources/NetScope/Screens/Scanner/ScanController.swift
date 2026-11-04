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
    /// Plages du dernier scan lancé (la Carte du réseau ne montre que ses appareils).
    @Published private(set) var lastScanRanges: [IPRange] = []
    @Published private(set) var status: [UUID: RangeStatus] = [:]
    /// Appareils apparus depuis le scan précédent (vide au tout premier scan).
    @Published private(set) var newIDs: Set<Device.ID> = []
    /// Latences mesurées, par appareil (30 dernières ; nil : sans réponse).
    @Published private(set) var latencyHistory: [Device.ID: [Double?]] = [:]
    @Published private(set) var measuring: Set<Device.ID> = []
    @Published private(set) var probing: Set<Device.ID> = []
    /// Sonde de ports en cours (menu « Ports », clic droit, détail) : appareils faits sur le total.
    @Published private(set) var portProbe: PortProbeProgress?
    /// Préréglage qui a servi au dernier scan (libellé), et à la dernière sonde de chaque appareil.
    @Published private(set) var lastScanPortLabel: String?
    @Published private(set) var portLabels: [Device.ID: String] = [:]
    @Published var toast: ScanToast?
    /// Préréglage de ports du Scanner (note 19) : profil dont on prend les ports, retenu d'un
    /// lancement à l'autre (rien n'est écrit en démonstration).
    @Published var portPresetProfile: ScanProfile {
        didSet { if !Launcher.isDemo { UserDefaults.standard.set(portPresetProfile.rawValue, forKey: Self.portPresetKey) } }
    }

    private var scanTask: Task<Void, Never>?
    /// Écoute LLDP/CDP passive du scan en cours (annulée par « Arrêter » et par un nouveau scan).
    var neighborTask: Task<Void, Never>?
    private var portTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var pingerCache: ICMPPinger?

    private static let portPresetKey = "scan.prereglagePorts"
    /// Ancienne liste du profil Personnalisé propre au Scanner (0.3).
    private static let legacyCustomPortsKey = "scan.customPorts"

    /// Avancement d'une sonde de ports lancée hors d'un scan.
    struct PortProbeProgress: Equatable {
        var done: Int
        let total: Int
        let label: String
    }

    /// Scan ou sonde de ports en cours (le bouton Arrêter s'applique aux deux).
    var isBusy: Bool { isRunning || portProbe != nil }

    init() {
        let defaults = UserDefaults.standard
        let saved = Launcher.isDemo ? nil : defaults.string(forKey: Self.portPresetKey).flatMap(ScanProfile.init(rawValue:))
        portPresetProfile = saved ?? RegPrefs.shared.defaultProfile
        // Ancienne liste du profil Personnalisé propre au Scanner : reprise une fois par les Réglages,
        // désormais la seule source des ports personnalisés. Jamais en démonstration ni en capture.
        if !RegEnvironment.isSandboxed, let old = defaults.string(forKey: Self.legacyCustomPortsKey) {
            migrateLegacyCustomPorts(old, defaults: defaults)
        }
    }

    /// Reprend l'ancienne liste Personnalisé du Scanner dans les Réglages. Si les Réglages ont déjà
    /// une liste à eux (autre que celle par défaut, que la 0.3 écrivait dès qu'on touchait aux Threads,
    /// au Délai ou aux Tentatives), les deux sont fusionnées et un message l'annonce. L'ancienne clé
    /// n'est effacée qu'une fois la liste enregistrée dans les Réglages.
    private func migrateLegacyCustomPorts(_ old: String, defaults: UserDefaults) {
        let prefs = RegPrefs.shared
        var legacy = RegScanTuning()
        legacy.portsText = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = prefs.tuning
        let currentIsDefault = defaults.string(forKey: RegPrefs.Key.ports) == nil
            || current.ports == RegScanTuning().ports
        var merged = false
        if legacy.ports.isEmpty || Set(legacy.ports).isSubset(of: Set(current.ports)) {
            // Rien à reprendre : liste vide ou invalide, ou déjà contenue dans les Réglages.
        } else if currentIsDefault {
            prefs.tuning.portsText = legacy.portsText
        } else {
            prefs.tuning.portsText = current.portsText + ", " + legacy.portsText
            merged = true
        }
        // Si l'enregistrement n'a pas eu lieu, l'ancienne liste reste là pour un prochain lancement.
        if !legacy.ports.isEmpty, !Set(legacy.ports).isSubset(of: Set(RegScanTuning.current.ports)) { return }
        defaults.removeObject(forKey: Self.legacyCustomPortsKey)
        if merged {
            show("Ports personnalisés du Scanner ajoutés à ceux des Réglages\u{00A0}: \(legacy.portsText)", tone: .neutral)
        }
    }

    // MARK: Préréglages de ports (note 19)

    /// Préréglages de Réglages › Profils de scan (Personnalisé : ports saisis dans les Réglages).
    var portPresets: [PortPreset] { PortPreset.all(customPorts: RegPrefs.shared.tuning.ports) }

    /// Préréglage en vigueur.
    var portPreset: PortPreset { PortPreset(profile: portPresetProfile, customPorts: RegPrefs.shared.tuning.ports) }

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
        neighborTask?.cancel()
        neighborTask = nil
        // Un nouveau scan sonde lui-même les ports : la sonde en cours s'arrête.
        stopPortProbe()
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
            show("Plage ignorée (invalide)\u{00A0}: \(invalid.joined(separator: ", "))", tone: .warning)
        }

        var options = ScanOptions(profile: state.scanProfile, customPorts: prefs.tuning.ports)
        options.portOverride = portPreset.ports
        // Méthodes de découverte du profil (Réglages › Profils de scan).
        options.methods = prefs.methods(for: state.scanProfile)
        let plan = ScanPlan(options: options, autoDiscoverSwitches: prefs.autoDiscoverSwitches)
        guard !plan.findsNothing else {
            show("Le profil « \(state.scanProfile.label) » n’a aucune méthode de présence (ICMP, ARP, TCP ou UDP)\u{00A0}: voir Réglages › Profils de scan.", tone: .warning)
            return
        }
        lastScanPortLabel = portPreset.label
        portLabels = [:]
        // Découverte SNMP des switchs : réglage automatique (activé par défaut) ou profil Complet,
        // sauf si la méthode SNMP du profil est décochée.
        let discoversSwitches = plan.snmp
        let readGatewayARP = prefs.readGatewayARP
        let probed = Set(options.ports)
        let pinger: any ScanPinging
        if !plan.ping {
            pinger = ScanNullPinger()
        } else if let icmp = self.pinger {
            pinger = icmp
        } else {
            pinger = ScanNullPinger()
            show("Ping ICMP indisponible\u{00A0}: seuls les appareils de la table ARP seront trouvés.", tone: .warning)
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
        lastScanRanges = targets.map(\.range)
        isRunning = true
        phase = .ping
        // Lecture de la FortiGate en fin de scan : phase « Emplacements » même sans SNMP.
        var phases = plan.phases
        if FortiGateStore.shared.isEnabled, FortiGateStore.shared.isConfigured, !phases.contains(.locations) { phases.append(.locations) }
        plannedPhases = phases
        let switches = SwitchStore.shared
        // Le bilan précédent disparaît même si ce scan ne fait aucune découverte ; le nouveau sera
        // rattaché à ces plages et à ce réseau.
        switches.scanStarted(ranges: targets.map(\.range), network: state.activeInterface.map(NetworkContext.init),
                             discovers: discoversSwitches)

        let stream = ScanEngine(pinger: pinger, names: options.methods.nameResolver() ?? ScanNoNames()).scan(targets, options: options)
        if plan.lldp { listenForNeighbor(state) }
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
            // Note 24 : FortiSwitch gérés relus par la FortiGate, prioritaire sur SNMP.
            let fortigate = FortiGateStore.shared
            if !engineCancelled, !Task.isCancelled, fortigate.isEnabled, fortigate.isConfigured {
                if self.plannedPhases.contains(.locations) { self.phase = .locations }
                await fortigate.refreshAfterScan(state: state, ranges: targets.map(\.range))
            }
            switches.scanEnded(interrupted: Task.isCancelled, planned: discoversSwitches)
            self.finish(state, targets: targets, found: foundIDs, engineCancelled: engineCancelled, snmpCancelled: Task.isCancelled)
        }
    }

    /// Résultat de la découverte SNMP faite pendant le scan.
    struct SNMPSweep: Sendable {
        var found: [SNMPDiscovered] = []
        var queried: [IPv4Address] = []
        var communities = 0
    }

    /// Découverte SNMP des hôtes donnés, hors du fil principal (communautés lues au Trousseau à ce
    /// moment-là, pas au clic sur « Scanner »).
    private static func startSweep(_ hosts: [IPv4Address]) -> Task<SNMPSweep, Never> {
        Task.detached(priority: .userInitiated) {
            let communities = RegSNMPDiscoveryVault.communities()
            guard !communities.isEmpty, !hosts.isEmpty else { return SNMPSweep(queried: hosts, communities: communities.count) }
            let found = await SNMPDiscovery(communities: communities).discover(hosts)
            return SNMPSweep(found: found, queried: hosts, communities: communities.count)
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
        neighborTask?.cancel()
        neighborTask = nil
        stopPortProbe()
    }

    /// Arrête la sonde de ports en cours (les appareils déjà faits gardent leur résultat).
    func stopPortProbe() {
        portTask?.cancel()
        portTask = nil
        guard let progress = portProbe else { return }
        probing = []
        portProbe = nil
        show("Sonde des ports arrêtée\u{00A0}: \(progress.done) sur \(Self.count(progress.total)).", tone: .neutral, place: .actions)
    }

    /// Préréglage qui a servi aux ports affichés pour cet appareil (nil : inconnu).
    func portLabel(for id: Device.ID) -> String? {
        portLabels[id] ?? lastScanPortLabel
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
        lastScanRanges = []
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
        // Fin de scan : événement commun (notifié seulement si NetScope n'est pas au premier plan).
        let fresh = newIDs.count
        NetScopeEventCenter.shared.publish(NetScopeEvent(
            id: "scan-\(Int(end.timeIntervalSince1970))", kind: .scanFinished,
            severity: engineCancelled ? .warning : .info,
            title: engineCancelled ? "Scan arrêté" : "Scan terminé",
            detail: "\(online) appareil\(online > 1 ? "s" : "") en ligne en \(seconds)" + (fresh > 0 ? ", \(fresh) nouveau\(fresh > 1 ? "x" : "")." : "."),
            date: end, link: .screen(Screen.scanner.rawValue), source: "scan"))
        if !engineCancelled { AlertDispatcher.shared.emit(.scanFinished(online: online, new: newIDs.count, duration: seconds, ranges: targets.map(\.range.description).joined(separator: ", "))) }
        if !engineCancelled { AlertDispatcher.shared.emit(.newDevices(state.devices.filter { newIDs.contains($0.id) })) }
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

    /// Sonde les ports des appareils donnés avec un préréglage (menu contextuel, barre d'outils,
    /// panneau de détail). Les ports connus hors du préréglage sont gardés. Plusieurs appareils à la
    /// fois, avec avancement et arrêt possible ; confirmation au-delà d'un gros volume. En
    /// démonstration, rien ne part sur le réseau.
    func probePorts(of devices: [Device], preset: PortPreset, state: AppState) {
        let targets = devices.filter { !probing.contains($0.id) }
        guard !targets.isEmpty else { return }
        guard !Launcher.isDemo else {
            show("Démonstration\u{00A0}: aucun port n’est sondé (\(preset.label), \(Self.count(targets.count))).",
                 tone: .neutral, place: .actions)
            return
        }
        guard !isRunning, portProbe == nil else {
            show("Une sonde de ports ou un scan est déjà en cours\u{00A0}: arrêtez-le d’abord.", tone: .warning, place: .actions)
            return
        }
        guard !preset.ports.isEmpty else {
            show("Le préréglage « \(preset.profile.label) » n’a aucun port\u{00A0}: réglez-le dans Réglages › Profils de scan.",
                 tone: .warning, place: .actions)
            return
        }
        let ports = preset.ports
        if targets.count * ports.count > Self.confirmProbeVolume, !confirmProbe(targets.count, preset: preset) { return }
        for device in targets { probing.insert(device.id) }
        portProbe = PortProbeProgress(done: 0, total: targets.count, label: preset.label)
        let probed = Set(ports)
        let label = preset.label
        probeOpenTotal = 0
        portTask = Task { [weak self] in
            await ScanConcurrency.forEach(targets, limit: Self.devicesInParallel) { device in
                let open = await PortProber().openPorts(device.ip, ports: ports, timeout: .milliseconds(800), concurrency: 64)
                await MainActor.run {
                    guard let self, !Task.isCancelled, self.portProbe != nil else { return }
                    self.probing.remove(device.id)
                    self.portProbe?.done += 1
                    self.portLabels[device.id] = label
                    self.probeOpenTotal += open.count
                    if var current = state.device(withID: device.id) {
                        current.openPorts = Self.mergedPorts(open, probed: probed, known: current.openPorts)
                        current.lastSeen = Date()
                        let guessed = ScanDeviceClassifier.guess(current)
                        if guessed != .inconnu { current.deviceType = guessed }
                        state.merge([current])
                    }
                }
            }
            // Arrêtée : stopPortProbe() a déjà tout remis à zéro et prévenu.
            guard let self, !Task.isCancelled else { return }
            let total = self.probeOpenTotal
            self.probing = []
            self.portProbe = nil
            self.portTask = nil
            let subject = targets.count == 1 ? targets[0].ip.description : Self.count(targets.count)
            self.show(total == 0 ? "Aucun port ouvert sur \(subject) (\(label))."
                                 : "\(total) ports ouverts sur \(subject) (\(label)).", place: .actions)
        }
    }

    /// Appareils sondés en même temps (64 connexions chacun).
    private static let devicesInParallel = 4
    /// Au-delà de ce nombre de sondes (appareils × ports), on demande confirmation.
    private static let confirmProbeVolume = 50_000
    private var probeOpenTotal = 0

    /// Confirmation d'une longue sonde de ports (ex. préréglage Complet sur plus de 50 appareils).
    private func confirmProbe(_ devices: Int, preset: PortPreset) -> Bool {
        // Pire cas : hôtes filtrés, une vague de 64 ports par seconde et par appareil.
        let waves = (preset.ports.count + 63) / 64
        let seconds = Double(waves * ((devices + Self.devicesInParallel - 1) / Self.devicesInParallel))
        let alert = NSAlert()
        alert.messageText = "Sonder \(Self.count(devices)) avec « \(preset.label) »\u{00A0}?"
        alert.informativeText = "Cela représente \(PortPreset.count(preset.ports.count * devices)) à sonder et peut prendre jusqu’à "
            + "\(ScanFormat.seconds(seconds)) si les appareils ne répondent pas. Vous pourrez l’arrêter avec le bouton Arrêter."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sonder")
        alert.addButton(withTitle: "Annuler")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func count(_ devices: Int) -> String {
        devices > 1 ? "\(devices) appareils" : "\(devices) appareil"
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
            show("\(ScanController.exportedLabel(devices.count)) dans \(url.lastPathComponent)")
        } catch {
            show("Export impossible : \(error.localizedDescription)", tone: .critical)
        }
    }
}
