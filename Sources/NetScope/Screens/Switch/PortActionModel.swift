import Foundation
import NetScopeCore

/// Note 73 : actions sur un port (cycle PoE, redémarrage d'un port de FortiSwitch). Première
/// fonction de NetScope qui modifie un équipement : réglage « Autoriser les actions sur les
/// ports » DÉSACTIVÉ par défaut, garde-fous de `PortActionGuard`, confirmation obligatoire
/// (feuille qui nomme le switch, le port, l'appareil et son IP), trace au journal de l'app et dans
/// la chronologie de l'inventaire, puis suivi du retour de l'appareil.
///
/// Réglages : préférences (sans secret). Identifiants SNMP d'écriture : Trousseau, service
/// com.danymenard.netscope.snmp-ecriture, distincts de ceux de lecture. Jeton FortiGate : celui du
/// contrôleur (FortiGateStore), dont le profil doit permettre l'écriture.
///
/// En démonstration et pendant les captures, rien n'est jamais envoyé : l'action est simulée
/// (PortActionDemo) avec un retour réaliste.
@MainActor
final class PortActionModel: ObservableObject {
    static let shared = PortActionModel()

    nonisolated static let vault = UpdKeychain(service: "com.danymenard.netscope.snmp-ecriture")
    nonisolated static let vaultAccount = "identifiants-ecriture"
    private static let settingsKey = "NetScope.actionsPorts.reglages"

    /// Action en cours ou terminée sur un port.
    struct Run: Equatable {
        var kind: PortActionKind
        var target: PortActionTarget
        var phase: PortActionPhase
        var startedAt: Date
        var record: PortActionRecord?

        var isRunning: Bool { record == nil }
    }

    /// Feuille de confirmation.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        var kind: PortActionKind
        var target: PortActionTarget
        var decision: PortActionDecision
    }

    @Published var settings: PortActionSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.clamped != settings { settings = settings.clamped; return }
            persist()
            if oldValue.enabled != settings.enabled {
                AppLog.shared.info(PortActionRecord.logModule, settings.enabled ? "Actions sur les ports autorisées." : "Actions sur les ports désactivées.")
            }
        }
    }
    /// Identifiants SNMP d'écriture présents au Trousseau (lu à la première demande).
    @Published private(set) var hasWriteCredentials = false
    @Published private(set) var writeSummary: String?
    @Published var request: Request?
    @Published private(set) var runs: [String: Run] = [:]

    let isDemo: Bool
    private var credentialsChecked = false
    private var tasks: [String: Task<Void, Never>] = [:]

    init(demo: Bool = Launcher.isDemo, sandboxed: Bool = RegEnvironment.isSandboxed) {
        isDemo = demo
        if demo {
            // Démonstration : autorisées, pour montrer les boutons (NETSCOPE_ACTIONS_PORTS=0 : désactivées).
            let off = ProcessInfo.processInfo.environment["NETSCOPE_ACTIONS_PORTS"] == "0"
            settings = PortActionSettings(enabled: !off)
            hasWriteCredentials = true
            writeSummary = "SNMP v2c (communauté d’écriture)"
            credentialsChecked = true
            runs = PortActionDemo.initialRuns()
        } else if sandboxed {
            settings = PortActionSettings()
            credentialsChecked = true
        } else {
            let data = UserDefaults.standard.data(forKey: Self.settingsKey)
            settings = data.flatMap { try? JSONDecoder().decode(PortActionSettings.self, from: $0) } ?? PortActionSettings()
        }
    }

    private func persist() {
        guard !isDemo, !RegEnvironment.isSandboxed, let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    // MARK: Identifiants d'écriture (Trousseau)

    /// Lit une fois le Trousseau pour savoir si des identifiants d'écriture existent.
    func checkCredentials() async {
        guard !credentialsChecked else { return }
        credentialsChecked = true
        let saved = await Task.detached(priority: .userInitiated) { PortActionModel.loadCredentials() }.value
        hasWriteCredentials = saved != nil
        writeSummary = saved?.summary
    }

    nonisolated static func loadCredentials() -> SNMPWriteCredentials? {
        guard let json = vault.string(for: vaultAccount) else { return nil }
        return try? JSONDecoder().decode(SNMPWriteCredentials.self, from: Data(json.utf8))
    }

    func saveCredentials(_ credentials: SNMPWriteCredentials) throws {
        if !isDemo, !RegEnvironment.isSandboxed {
            let data = try JSONEncoder().encode(credentials)
            try Self.vault.set(String(decoding: data, as: UTF8.self), for: Self.vaultAccount)
        }
        hasWriteCredentials = true
        writeSummary = credentials.summary
        AppLog.shared.info(PortActionRecord.logModule, "Identifiants SNMP d’écriture enregistrés au Trousseau (\(credentials.summary)).")
    }

    func eraseCredentials() throws {
        if !isDemo, !RegEnvironment.isSandboxed { try Self.vault.delete(Self.vaultAccount) }
        hasWriteCredentials = false
        writeSummary = nil
        AppLog.shared.info(PortActionRecord.logModule, "Identifiants SNMP d’écriture effacés du Trousseau.")
    }

    // MARK: Port visé

    static func key(_ target: PortActionTarget) -> String { "\(target.switchName)|\(target.ifIndex)" }

    func run(for target: PortActionTarget) -> Run? { runs[Self.key(target)] }

    /// Port d'un relevé, avec l'appareil branché (le premier vu) ou celui donné (fiche Appareil).
    func target(snapshot: SNMPSwitchSnapshot, iface: SNMPInterface, state: AppState, device: Device? = nil) -> PortActionTarget {
        let entries = snapshot.entries(on: iface.index)
        let primary = device ?? entries.lazy.compactMap { entry in state.devices.first { $0.mac == entry.mac } }.first
        let firstMAC = device?.mac ?? primary?.mac ?? entries.first?.mac
        var name = primary?.displayName
        var ip = primary?.ip
        if primary == nil, let mac = firstMAC {
            let info = SwitchStore.shared.describe(mac, devices: state.devices)
            if info.name != "—" { name = info.name }
            ip = IPv4Address(info.ip) ?? snapshot.arp[mac]
        }
        let localIP = state.activeInterface?.address
        let localMACs = Set(state.devices.filter { $0.ip == localIP }.compactMap(\.mac))
        let thisMac = PortActionGuard.isThisMacPort(entries: entries, arp: snapshot.arp, localMACs: localMACs,
                                                    localIPs: localIP.map { [$0] } ?? [])
            || (localIP != nil && device?.ip == localIP)
        let forti = snapshot.isViaController && snapshot.controllerKind == nil
            ? FortiPortLocator.reference(switchName: snapshot.system.name, site: snapshot.controllerName, in: fortiSites())
            : nil
        return PortActionTarget(switchName: snapshot.displayName, switchHost: snapshot.isViaController ? nil : snapshot.host,
                                portName: iface.name, ifIndex: iface.index, isUplink: snapshot.locatedUplinks.contains(iface.index),
                                isThisMacPort: thisMac, deviceName: name, deviceIP: ip, deviceMAC: firstMAC,
                                macCount: entries.count, poe: snapshot.poePort(iface.index), fortiGate: forti,
                                viaFortiGate: snapshot.isViaController, readOnlyController: snapshot.controllerKind)
    }

    /// Port d'un appareil localisé (fiche Appareil) ; nil si le switch ou le port n'est pas relevé.
    func target(for device: Device, state: AppState) -> (target: PortActionTarget, snapshot: SNMPSwitchSnapshot)? {
        guard let switchName = device.switchName, let portName = device.switchPort, portName != "Wi-Fi" else { return nil }
        func key(_ value: String) -> String { value.lowercased().split(separator: ".").first.map(String.init) ?? value.lowercased() }
        guard let snapshot = SwitchStore.shared.orderedSnapshots.first(where: { key($0.displayName) == key(switchName) }),
              let iface = snapshot.interface(named: portName), iface.isPhysical else { return nil }
        return (target(snapshot: snapshot, iface: iface, state: state, device: device), snapshot)
    }

    /// Lectures des FortiGate (site actif d'abord, puis les dernières lectures des autres sites).
    private func fortiSites() -> [FortiSiteReport] {
        let store = FortiGateStore.shared
        var result = store.sites
        let known = Set(result.map(\.controllerID))
        for c in store.controllers where !known.contains(c.id) {
            if let report = store.runtime[c.id]?.report {
                result.append(FortiSiteReport(controllerID: c.id, site: c.displayName, report: report, coveredRanges: c.coveredRanges))
            }
        }
        return result
    }

    /// Raison pour laquelle la FortiGate du switch ne peut pas servir (nil : prête).
    func fortiGateProblem(_ ref: FortiPortRef?) -> String? {
        guard let ref, !isDemo else { return nil }
        let store = FortiGateStore.shared
        guard let c = store.controller(ref.controllerID) else { return "FortiGate «\u{00A0}\(ref.controllerName)\u{00A0}» absente des Réglages." }
        if !c.isEnabled { return "FortiGate «\u{00A0}\(c.displayName)\u{00A0}» désactivée dans les Réglages." }
        return store.notReadyReason(c)
    }

    /// Décision des garde-fous pour ce port.
    func decision(_ kind: PortActionKind, target: PortActionTarget) -> PortActionDecision {
        PortActionGuard.decide(kind, target: target, settings: settings, hasWriteCredentials: hasWriteCredentials,
                               fortiGateProblem: fortiGateProblem(target.fortiGate), busy: run(for: target)?.isRunning == true)
    }

    /// Actions proposées : le cycle PoE toujours, le redémarrage pour un FortiSwitch géré.
    func kinds(for target: PortActionTarget) -> [PortActionKind] {
        target.isManagedFortiSwitch ? [.poeCycle, .portRestart] : [.poeCycle]
    }

    // MARK: Demande et exécution

    /// Ouvre la feuille de confirmation (rien n'est envoyé ici).
    func ask(_ kind: PortActionKind, target: PortActionTarget) {
        let decision = decision(kind, target: target)
        guard decision.isAllowed else { return }
        request = Request(kind: kind, target: target, decision: decision)
    }

    func clearResult(_ target: PortActionTarget) {
        let key = Self.key(target)
        if runs[key]?.isRunning == false { runs[key] = nil }
    }

    /// Lance l'action confirmée. `acknowledged` : case « agir quand même » cochée (uplink, port de
    /// ce Mac, permis par le réglage). La décision est recalculée : rien ne part si elle a changé.
    func perform(_ request: Request, acknowledged: Bool, offSeconds: Int) {
        self.request = nil
        let target = request.target
        let decision = decision(request.kind, target: target)
        guard decision.isAllowed, let channel = decision.channel else {
            AppLog.shared.warning(PortActionRecord.logModule, "\(request.kind.shortLabel) refusé sur \(target.portLabel)\u{00A0}: \(decision.reason ?? "refusé")")
            return
        }
        guard decision.warnings.isEmpty || acknowledged else { return }
        var settings = self.settings
        settings.poeOffSeconds = offSeconds
        settings = settings.clamped
        let key = Self.key(target)
        runs[key] = Run(kind: request.kind, target: target, phase: .sending, startedAt: Date())
        let warnings = decision.warnings.map(\.message).joined(separator: " ")
        AppLog.shared.warning(PortActionRecord.logModule, "\(request.kind.shortLabel) demandé sur \(target.portLabel) · \(target.deviceLabel) · par \(channel.label)"
                              + (warnings.isEmpty ? "" : " · confirmé malgré\u{00A0}: \(warnings)"))
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            let record: PortActionRecord
            if self.isDemo || RegEnvironment.isSandboxed {
                record = await PortActionDemo.simulate(request.kind, target: target, channel: channel, settings: settings) { phase in
                    self.update(key, phase)
                }
            } else {
                record = await self.execute(request.kind, target: target, channel: channel, settings: settings, key: key)
            }
            self.finish(key, record: record)
        }
    }

    private func update(_ key: String, _ phase: PortActionPhase) {
        runs[key]?.phase = phase
    }

    private func finish(_ key: String, record: PortActionRecord) {
        runs[key]?.phase = .finished
        runs[key]?.record = record
        tasks[key] = nil
        if record.success, record.returned?.isProblem != true {
            AppLog.shared.info(PortActionRecord.logModule, record.logLine)
        } else {
            AppLog.shared.error(PortActionRecord.logModule, record.logLine)
        }
        // Chronologie de la fiche de l'appareil (site actif) ; rien n'est créé si elle n'existe pas.
        if let inventoryKey = record.inventoryKey {
            let inventory = InvModel.shared
            inventory.mutate(site: inventory.siteKey) { $0.recordPortAction(record.inventoryEvent(key: inventoryKey)) }
        }
        // FortiSwitch : relecture de la FortiGate pour montrer le port à jour.
        if !isDemo, !RegEnvironment.isSandboxed, record.success, let forti = runs[key]?.target.fortiGate {
            FortiGateStore.shared.readForView([forti.controllerID])
        }
    }

    // MARK: Envoi réel

    private func execute(_ kind: PortActionKind, target: PortActionTarget, channel: PortActionChannel,
                         settings: PortActionSettings, key: String) async -> PortActionRecord {
        let phase: @Sendable (PortActionPhase) async -> Void = { phase in
            await MainActor.run { PortActionModel.shared.update(key, phase) }
        }
        let sleep: @Sendable (Double) async -> Void = { seconds in
            // Attente non annulable : une remise du PoE ne doit jamais être sautée.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
            }
        }
        var start = Date()
        var linkProbe: (@Sendable () async -> Bool?)?
        // Un ou deux pings avant l'envoi : un appareil qui filtre l'ICMP n'est pas déclaré
        // « pas revenu » après une action réussie.
        let pinger = try? ICMPPinger()
        var respondedBefore: Bool?
        if let ip = target.deviceIP, let pinger {
            var answered = false
            for _ in 0..<2 where !answered {
                answered = await pinger.ping(ip, timeout: .seconds(1)) != nil
            }
            respondedBefore = answered
        }
        do {
            switch channel {
            case .fortiGate(let id, _, let switchID, let portName):
                let store = FortiGateStore.shared
                await store.loadTokens()
                guard let controller = store.controller(id) else { throw PortActionError.fortiGate("FortiGate absente des Réglages.") }
                let pick = FortiControllerSelection.Pick(controllerID: id, site: controller.displayName, reason: .activeSite)
                guard let token = await store.wifiTargets(for: FortiControllerSelection(picks: [pick])).ready.first?.1 else {
                    throw PortActionError.fortiGate(store.notReadyReason(controller) ?? "Jeton de la FortiGate absent.")
                }
                let transport = FortiURLSessionWriter(config: controller.config, token: token)
                let request = FortiPortActions.request(kind, switchID: switchID, port: portName, settings: settings, vdom: controller.config.vdom)
                await phase(.sending)
                start = Date()
                try await FortiPortActions.perform(request, transport: transport)
            case .snmp(let host, let group, let port):
                guard let credentials = await Task.detached(priority: .userInitiated, operation: { PortActionModel.loadCredentials() }).value else {
                    throw PortActionError.snmp(PortActionRefusal.noWriteCredentials.message)
                }
                let writer = SNMPPoEPortWriter(host: host, group: group, port: port, credentials: credentials)
                start = Date()
                try await PortActionRunner.snmpPoECycle(writer: writer, offSeconds: settings.poeOffSeconds, sleep: sleep, phase: phase)
                // Suivi du lien par les identifiants de lecture du switch : utilisateur v3 du site (ou de
                // tous les sites) d'abord, communauté seulement en repli (note 59).
                let ifIndex = target.ifIndex
                if let readTarget = SwitchStore.shared.snmpTarget(for: host.description, timeout: 1.5, retries: 0) {
                    linkProbe = {
                        let client = SNMPClient(target: readTarget)
                        guard let bind = try? await client.get([SNMPOIDs.ifOperStatus.appending(UInt32(ifIndex))]).first,
                              let value = bind.value.intValue else { return nil }
                        return value == 1
                    }
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return PortActionRecord(date: start, kind: kind, target: target, channel: channel.label, success: false, errorMessage: message)
        }
        // Suivi : relevé du lien (SNMP) et ping de l'appareil jusqu'à son retour.
        let returned = await PortActionRunner.followUp(
            ip: target.deviceIP, pinger: pinger, linkProbe: linkProbe, start: start, limitSeconds: settings.followUpSeconds,
            respondedBefore: respondedBefore,
            now: { Date() }, sleep: sleep,
            progress: { elapsed, link in await phase(.waitingReturn(elapsed: elapsed, linkUp: link)) })
        return PortActionRecord(date: start, kind: kind, target: target, channel: channel.label, success: true, returned: returned)
    }
}
