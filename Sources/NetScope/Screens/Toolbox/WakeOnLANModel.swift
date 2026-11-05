import Foundation
import NetScopeCore

/// Wake-on-LAN (Boîte à outils). Note 78 (0.26.0) : plusieurs postes d'un coup (sélection du
/// tableau), broadcast dirigé vers le sous-réseau d'un poste distant (mode automatique) et suivi
/// par ping : « réveillé en N s ». En démonstration et en capture, rien n'est envoyé : les réveils
/// sont simulés (DevTools/WakeDemo.swift).
@MainActor
final class ToolWakeModel: ObservableObject {
    enum PortChoice: String, CaseIterable, Identifiable {
        case nine, seven, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nine: return "9 (discard)"
            case .seven: return "7 (echo)"
            case .both: return "9 et 7"
            }
        }
        var ports: [UInt16] {
            switch self {
            case .nine: return [9]
            case .seven: return [7]
            case .both: return [9, 7]
            }
        }
    }

    @Published var macText = ""
    @Published var broadcastText = ""
    @Published var port: PortChoice = .nine
    @Published var broadcastMode: WakeBroadcastMode = .automatic
    /// Postes choisis dans le tableau (plusieurs : réveil groupé).
    @Published var selection: Set<Device.ID> = []
    @Published var error: String?
    @Published private(set) var lastSent: String?
    /// Suivis en cours (identifiant de l'entrée de l'historique).
    @Published private(set) var following: Set<UUID> = []

    /// Délai du suivi par ping après l'envoi.
    static let verifyDuration = WakeFollowUp.defaultTimeout

    private var monitors: [UUID: PingMonitor] = [:]
    private var followUps: [UUID: WakeFollowUp] = [:]

    var command: String {
        "wol \(macText.trimmingCharacters(in: .whitespaces).uppercased()) -b \(broadcastText) -p " + port.ports.map(String.init).joined(separator: ",")
    }

    /// Postes visés : la sélection du tableau (2 et plus), sinon la MAC saisie.
    func targets(state: AppState, known: [Device]) -> [WakeTarget]? {
        let chosen = known.filter { selection.contains($0.id) }
        if chosen.count > 1 {
            return chosen.compactMap { device in
                device.mac.map { WakeTarget(mac: $0, ip: device.ip, name: device.wakeSortName) }
            }
        }
        guard let mac = MACAddress(macText) else { return nil }
        let device = state.devices.first { $0.mac == mac }
        return [WakeTarget(mac: mac, ip: device?.ip, name: device?.hostnameLabel ?? device?.displayName ?? "Manuel")]
    }

    /// Sous-réseaux connus (plages du site en CIDR), pour le broadcast dirigé.
    static func knownSubnets(_ state: AppState) -> [Subnet] {
        state.ranges.compactMap { try? Subnet(parsing: $0.text.trimmingCharacters(in: .whitespaces)) }
    }

    /// Envoie le paquet magique à chaque poste ; suit par ping ceux dont l'adresse IP est connue.
    func wake(state: AppState, store: ToolStore, known: [Device]) {
        guard let targets = targets(state: state, known: known), !targets.isEmpty else {
            error = "MAC invalide\u{00A0}: 12 caractères hexadécimaux attendus."
            return
        }
        let manual = IPv4Address(broadcastText)
        if broadcastMode == .manual, manual == nil {
            error = "Adresse de broadcast invalide (exemple\u{00A0}: 10.182.122.255)."
            return
        }
        error = nil
        let plan = WakeOnLAN.plan(targets, mode: broadcastMode, local: state.activeInterface?.subnet,
                                  knownSubnets: Self.knownSubnets(state), manual: manual)
        let ports = port.ports.map(String.init).joined(separator: ",")
        if plan.count == 1 { store.record(command: command) }
        var failures = 0
        for send in plan {
            let mac = send.target.mac.formatted(.upperColon)
            let name = send.target.name
            let destination = "\(send.label):\(ports)"
            if !store.isEphemeral {
                do {
                    try WakeOnLAN.send(to: send.target.mac, broadcast: send.broadcast, ports: port.ports)
                } catch {
                    failures += 1
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    store.addWake(ToolWakeEntry(name: name, mac: mac, detail: "\(destination) · \(message)", status: .failed))
                    store.record(ToolRecent(tool: .wol, target: "\(name) · \(mac)", summary: message, status: .failure))
                    continue
                }
            }
            guard let ip = send.target.ip else {
                store.addWake(ToolWakeEntry(name: name, mac: mac,
                                            detail: "Paquet magique envoyé (102 octets) en \(destination) · adresse IP inconnue, pas de suivi",
                                            status: .sent))
                store.record(ToolRecent(tool: .wol, target: "\(name) · \(mac)", summary: "Paquet envoyé (\(send.label))", status: .info))
                continue
            }
            let id = store.addWake(ToolWakeEntry(name: name, mac: mac,
                                                 detail: "Paquet envoyé en \(destination) · ping de \(ip) toutes les \(Int(WakeFollowUp.probeInterval))\u{00A0}s…",
                                                 status: .pending))
            follow(id, ip: ip, name: name, destination: destination, store: store)
        }
        let sent = plan.count - failures
        if sent > 0 {
            lastSent = plan.count > 1 ? "Paquet magique envoyé à \(sent) postes sur \(plan.count)."
                : "Paquet magique envoyé (102 octets) en \(plan[0].label)."
        }
        if failures > 0, plan.count == 1 { error = store.wakeLog.first?.detail }
    }

    // MARK: Suivi par ping

    private func follow(_ id: UUID, ip: IPv4Address, name: String, destination: String, store: ToolStore) {
        let start = Date()
        followUps[id] = WakeFollowUp(start: start)
        following.insert(id)
        if store.isEphemeral {
            // Démonstration : réveil simulé après quelques secondes, sans aucun paquet.
            let seconds = WakeDemo.simulatedDelay(for: ip)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(min(seconds, 30)) * 1_000_000_000)
                self?.answer(id, reply: true, at: start.addingTimeInterval(seconds), ip: ip, name: name, destination: destination, store: store)
            }
            return
        }
        // Ping ICMP toutes les 2 s. Un pare-feu (Windows) bloque souvent l'ICMP : un test TCP
        // (ports habituels) tourne en parallèle toutes les 4 s ; la première réponse l'emporte.
        let monitor = PingMonitor(address: ip, options: PingOptions(interval: WakeFollowUp.probeInterval, timeout: 1.5)) { sample in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ToolStore.shared.wol.answer(id, reply: !sample.isLost, at: sample.date.addingTimeInterval((sample.rttMs ?? 0) / 1000),
                                                ip: ip, name: name, destination: destination, store: ToolStore.shared)
                }
            }
        }
        if (try? monitor.start()) != nil { monitors[id] = monitor }
        Task { @MainActor [weak self] in
            while let self, self.followUps[id]?.isFinished == false {
                let up = await PortScanner.isHostUp(host: ip.description, timeout: 1.5)
                self.answer(id, reply: up, at: Date(), ip: ip, name: name, destination: destination, store: store)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func answer(_ id: UUID, reply: Bool, at date: Date, ip: IPv4Address, name: String, destination: String, store: ToolStore) {
        guard var followUp = followUps[id], !followUp.isFinished else { return }
        let state = followUp.record(reply: reply, at: date)
        followUps[id] = followUp
        switch state {
        case .waiting:
            return
        case .awake(let seconds):
            store.updateWake(id, status: .awake, detail: "Paquet envoyé en \(destination) · \(ip) \(followUp.label)")
            store.record(ToolRecent(tool: .wol, target: "\(name) · \(ip)", summary: "Réveillé en \(seconds)\u{00A0}s", status: .ok))
        case .noReply:
            store.updateWake(id, status: .noReply,
                             detail: "Paquet envoyé en \(destination) · \(followUp.label) (WoL désactivé dans le BIOS, ou broadcast dirigé bloqué par le routeur\u{00A0}?)")
            store.record(ToolRecent(tool: .wol, target: "\(name) · \(ip)", summary: "Aucune réponse au ping", status: .warning))
        }
        monitors.removeValue(forKey: id)?.stop()
        followUps[id] = nil
        following.remove(id)
    }
}
