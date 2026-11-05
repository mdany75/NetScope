import Foundation
import NetScopeCore

/// Note 73 : actions sur un port en démonstration. Rien n'est jamais envoyé : le cycle PoE et le
/// redémarrage sont simulés avec un déroulement réaliste (coupure, attente, remise, borne qui
/// revient en 38 s), noté au journal et dans la chronologie comme une vraie action.
///
/// Captures :
/// - NETSCOPE_PORT_ACTION=suivi | revenu | echec : état de l'action sur le port 1/10 de SW-ETG2-01
///   (téléphone de l'accueil), affiché sous les boutons du détail du port (NETSCOPE_SWITCH=SW-ETG2-01
///   NETSCOPE_PORT=10) et dans la fiche Appareil (NETSCOPE_DEVICE=10.182.122.121) ;
/// - NETSCOPE_PORT_FEUILLE=poe | redemarrage | uplink : feuille de confirmation dessinée dans la page
///   (poe : ce téléphone ; redemarrage : premier FortiSwitch ; uplink : port 47 de SW-CORE-01) ;
/// - NETSCOPE_ACTIONS_PORTS=0 : actions désactivées (réglage d'origine).
@MainActor
enum PortActionDemo {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var isSnapshot: Bool { CommandLine.arguments.contains("--snapshot") }

    /// Port 1/10 de SW-ETG2-01 : téléphone IP de l'accueil (Yealink SIP-T54W), PoE classe 2.
    static let phone = PortActionTarget(
        switchName: "SW-ETG2-01", switchHost: IPv4Address("10.182.122.3"), portName: "1/10", ifIndex: 10,
        deviceName: "Téléphone accueil", deviceIP: IPv4Address("10.182.122.121"), deviceMAC: MACAddress("80:5E:C0:3A:61:21"),
        macCount: 1, poe: SNMPPoEPort(group: 1, port: 10, ifIndex: 10, adminEnabled: true, detection: .deliveringPower,
                                      powerClass: 2, consumptionMW: 4_600, wattsSource: "HPE"))

    static var phoneChannel: PortActionChannel { .snmp(host: IPv4Address("10.182.122.3")!, group: 1, port: 10) }

    /// Captures : NETSCOPE_PORT=10 choisit ce port sur la façade du switch affiché (NETSCOPE_SWITCH).
    static func apply(to state: AppState) {
        guard isSnapshot, let raw = environment["NETSCOPE_PORT"], let port = Int(raw) else { return }
        SwitchStore.shared.selectedPort = port
    }

    /// État initial des captures (NETSCOPE_PORT_ACTION).
    static func initialRuns(now: Date = Date()) -> [String: PortActionModel.Run] {
        guard isSnapshot, let raw = environment["NETSCOPE_PORT_ACTION"] else { return [:] }
        let target = phone
        let key = PortActionModel.key(target)
        let started = now.addingTimeInterval(-24)
        switch raw {
        case "suivi":
            return [key: PortActionModel.Run(kind: .poeCycle, target: target, phase: .waitingReturn(elapsed: 24, linkUp: true), startedAt: started)]
        case "echec":
            let record = PortActionRecord(date: now.addingTimeInterval(-60), kind: .poeCycle, target: target, channel: phoneChannel.label,
                                          success: false, errorMessage: PortActionError.snmpWriteRefused("accès refusé").errorDescription,
                                          simulated: true)
            return [key: PortActionModel.Run(kind: .poeCycle, target: target, phase: .finished, startedAt: record.date, record: record)]
        default:
            let record = PortActionRecord(date: now.addingTimeInterval(-120), kind: .poeCycle, target: target, channel: phoneChannel.label,
                                          success: true, returned: .returned(seconds: 52), simulated: true)
            return [key: PortActionModel.Run(kind: .poeCycle, target: target, phase: .finished, startedAt: record.date, record: record)]
        }
    }

    /// Feuille demandée pour la capture (NETSCOPE_PORT_FEUILLE), construite d'après les relevés de démonstration.
    static func snapshotRequest(state: AppState) -> PortActionModel.Request? {
        guard isSnapshot, let raw = environment["NETSCOPE_PORT_FEUILLE"] else { return nil }
        let model = PortActionModel.shared
        let switches = SwitchStore.shared
        switch raw {
        case "redemarrage":
            guard let snapshot = switches.orderedSnapshots.first(where: { $0.isViaController }),
                  let iface = snapshot.physicalPorts.first(where: { snapshot.poePort($0.index)?.isDelivering == true }) ?? snapshot.physicalPorts.first
            else { return nil }
            let target = model.target(snapshot: snapshot, iface: iface, state: state)
            return PortActionModel.Request(kind: .portRestart, target: target, decision: model.decision(.portRestart, target: target))
        case "uplink":
            var target = phone
            target.switchName = "SW-CORE-01"
            target.switchHost = IPv4Address("10.182.122.2")
            target.portName = "Gi1/0/47"
            target.ifIndex = 47
            target.isUplink = true
            target.deviceName = "SW-ETG2-01"
            target.deviceIP = IPv4Address("10.182.122.3")
            target.macCount = 23
            target.poe = SNMPPoEPort(group: 1, port: 47, ifIndex: 47, adminEnabled: true, detection: .searching, powerClass: 0)
            var settings = model.settings
            settings.allowRiskyPorts = true
            let decision = PortActionGuard.decide(.poeCycle, target: target, settings: settings, hasWriteCredentials: true, fortiGateProblem: nil)
            return PortActionModel.Request(kind: .poeCycle, target: target, decision: decision)
        default:
            // Port relevé de démonstration (appareils vus, PoE, uplink) ; à défaut, la cible fixe.
            var target = phone
            if let snapshot = switches.orderedSnapshots.first(where: { $0.displayName == phone.switchName }),
               let iface = snapshot.interface(phone.ifIndex) {
                target = model.target(snapshot: snapshot, iface: iface, state: state)
            }
            return PortActionModel.Request(kind: .poeCycle, target: target, decision: model.decision(.poeCycle, target: target))
        }
    }

    /// Déroulement simulé (accéléré) : jamais de réseau.
    static func simulate(_ kind: PortActionKind, target: PortActionTarget, channel: PortActionChannel, settings: PortActionSettings,
                         phase: @escaping (PortActionPhase) -> Void) async -> PortActionRecord {
        let start = Date()
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        let back: Int
        switch (kind, channel) {
        case (.poeCycle, .snmp):
            phase(.poweringOff)
            await pause(0.6)
            for remaining in stride(from: settings.poeOffSeconds, to: 0, by: -1) {
                phase(.waitingOff(remaining: remaining))
                await pause(0.3)
            }
            phase(.poweringOn(attempt: 1))
            await pause(0.5)
            back = settings.poeOffSeconds + 47
        case (.poeCycle, .fortiGate):
            phase(.sending)
            await pause(0.8)
            back = 41
        case (.portRestart, _):
            phase(.sending)
            await pause(0.8)
            back = settings.bounceSeconds + 4
        }
        // Suivi : une seconde réelle ≈ huit secondes simulées ; le lien revient vers le tiers du délai.
        guard target.deviceIP != nil else {
            return PortActionRecord(date: start, kind: kind, target: target, channel: channel.label, success: true,
                                    returned: .notFollowed, simulated: true)
        }
        var isSNMPCycle = false
        if kind == .poeCycle, case .snmp = channel { isSNMPCycle = true }
        var elapsed = isSNMPCycle ? settings.poeOffSeconds + 1 : 1
        while elapsed < back {
            phase(.waitingReturn(elapsed: elapsed, linkUp: elapsed >= back / 3))
            await pause(0.25)
            elapsed += 2
        }
        return PortActionRecord(date: start, kind: kind, target: target, channel: channel.label, success: true,
                                returned: .returned(seconds: back), simulated: true)
    }
}
