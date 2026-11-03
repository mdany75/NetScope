import Darwin
import Foundation

// Découverte automatique des équipements SNMP (switchs, routeurs, imprimantes) parmi les hôtes
// en ligne d'un scan : un GET v2c par hôte, en parallèle, avec un délai court. Un hôte qui ne
// répond pas ne produit rien (ni erreur, ni message).

/// Nature d'un équipement SNMP découvert.
public enum SNMPDeviceKind: String, Hashable, Sendable, Codable, CaseIterable {
    case `switch`
    case routeur
    case imprimante
    case autre

    public var label: String {
        switch self {
        case .switch: return "Switch"
        case .routeur: return "Routeur ou pare-feu"
        case .imprimante: return "Imprimante"
        case .autre: return "Autre"
        }
    }
}

/// Équipement qui a répondu à la découverte SNMP. La communauté reste en mémoire seulement :
/// ce type n'est volontairement pas `Codable`.
public struct SNMPDiscovered: Hashable, Sendable, Identifiable {
    public var id: IPv4Address { host }
    public var host: IPv4Address
    /// Première communauté de la liste qui a obtenu une réponse.
    public var community: String
    public var sysName: String
    public var sysDescr: String
    public var sysObjectID: String?
    /// dot1dBaseNumPorts.0 ; nil si l'agent n'a pas de BRIDGE-MIB.
    public var bridgePorts: Int?
    /// Printer-MIB présente.
    public var hasPrinterMIB: Bool
    public var kind: SNMPDeviceKind

    public init(host: IPv4Address, community: String, sysName: String, sysDescr: String, sysObjectID: String?,
                bridgePorts: Int?, hasPrinterMIB: Bool = false, kind: SNMPDeviceKind? = nil) {
        self.host = host
        self.community = community
        self.sysName = sysName
        self.sysDescr = sysDescr
        self.sysObjectID = sysObjectID
        self.bridgePorts = bridgePorts
        self.hasPrinterMIB = hasPrinterMIB
        self.kind = kind ?? SNMPDiscovery.classify(sysObjectID: sysObjectID, sysDescr: sysDescr, bridgePorts: bridgePorts,
                                                   hasPrinterMIB: hasPrinterMIB)
    }

    /// Informations système (pour la marque et le résumé).
    public var system: SNMPSystemInfo { SNMPSystemInfo(name: sysName, descr: sysDescr, objectID: sysObjectID) }
    public var brand: String? { system.brand }
    public var displayName: String { sysName.isEmpty ? host.description : sysName }

    /// Cible prête pour un relevé complet (SNMPSwitchPoller) avec la communauté retenue.
    public func target(port: UInt16 = 161, timeout: TimeInterval = 2, retries: Int = 1) -> SNMPTarget {
        SNMPTarget(host: host, port: port, community: community, timeout: timeout, retries: retries)
    }
}

/// Événements du flux de découverte.
public enum SNMPDiscoveryEvent: Hashable, Sendable {
    /// Un équipement a répondu.
    case found(SNMPDiscovered)
    /// `done` hôtes traités sur `total`.
    case progress(done: Int, total: Int)
}

public struct SNMPDiscovery: Sendable {
    /// Adresse et port UDP réellement interrogés pour un hôte (injectable pour les tests).
    public typealias Endpoint = @Sendable (IPv4Address) -> (host: IPv4Address, port: UInt16)

    /// Au plus 4096 hôtes par découverte.
    public static let maxHosts = 4096

    /// Communautés à essayer, dans l'ordre (vides et doublons retirés).
    public var communities: [String]
    public var port: UInt16
    /// Délai d'attente d'une réponse, en secondes.
    public var timeout: TimeInterval
    /// Renvois après le premier envoi, pour chaque communauté.
    public var retries: Int
    /// Hôtes interrogés en même temps (une socket UDP chacun).
    public var concurrency: Int
    public var endpoint: Endpoint?

    public init(communities: [String], port: UInt16 = 161, timeout: TimeInterval = 0.7, retries: Int = 1,
                concurrency: Int = 96, endpoint: Endpoint? = nil) {
        var seen: Set<String> = []
        self.communities = communities.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.port = port
        self.timeout = timeout
        self.retries = retries
        self.concurrency = concurrency
        self.endpoint = endpoint
    }

    /// OID demandés à chaque hôte, en un seul GET.
    public static let probeOIDs: [SNMPOID] = [SNMPOIDs.sysObjectID, SNMPOIDs.sysDescr, SNMPOIDs.sysName,
                                              SNMPOIDs.dot1dBaseNumPorts, SNMPOIDs.prtGeneralConfigChanges]

    // MARK: Découverte

    /// Flux d'événements ; il se termine quand tous les hôtes ont été traités. L'abandon du flux
    /// (ou l'annulation de la tâche qui le lit) arrête la découverte.
    public func events(for hosts: [IPv4Address]) -> AsyncStream<SNMPDiscoveryEvent> {
        var unique: Set<IPv4Address> = []
        let list = Array(hosts.filter { unique.insert($0).inserted }.prefix(Self.maxHosts))
        let engine = SNMPDiscoveryEngine(hosts: list, communities: communities, timeout: timeout, retries: retries,
                                         concurrency: concurrency, endpoint: endpoint ?? { [port] in ($0, port) })
        return AsyncStream { continuation in
            continuation.onTermination = { _ in engine.cancel() }
            guard !list.isEmpty, !communities.isEmpty else {
                continuation.yield(.progress(done: list.count, total: list.count))
                continuation.finish()
                return
            }
            let thread = Thread {
                engine.run { continuation.yield($0) }
                continuation.finish()
            }
            thread.name = "NetScope.SNMPDiscovery"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Découverte complète ; résultats triés par adresse. `progress` reçoit (traités, total).
    public func discover(_ hosts: [IPv4Address], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [SNMPDiscovered] {
        var found: [SNMPDiscovered] = []
        for await event in events(for: hosts) {
            switch event {
            case .found(let item): found.append(item)
            case .progress(let done, let total): progress?(done, total)
            }
        }
        return found.sorted { $0.host < $1.host }
    }

    // MARK: Classification

    /// Nature de l'équipement d'après sysObjectID (numéro d'entreprise), sysDescr, BRIDGE-MIB et Printer-MIB.
    public static func classify(sysObjectID: String?, sysDescr: String, bridgePorts: Int?, hasPrinterMIB: Bool = false) -> SNMPDeviceKind {
        let descr = sysDescr.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { descr.contains($0) } }
        let oid = sysObjectID.flatMap(SNMPOID.init)
        let enterprise: UInt32? = oid.flatMap { $0.hasPrefix("1.3.6.1.4.1") && $0.components.count > 6 ? $0.components[6] : nil }
        func under(_ prefix: SNMPOID) -> Bool { oid?.hasPrefix(prefix) ?? false }

        let printerWords = ["printer", "imprimante", "laserjet", "officejet", "deskjet", "pagewide", "jetdirect", "designjet",
                            "lexmark", "kyocera", "ricoh", "xerox", "brother", "konica", "bizhub", "epson", "canon ir",
                            "imagerunner", "workcentre", "versalink", "ecosys", "mfp"]
        if hasPrinterMIB || under("1.3.6.1.4.1.11.2.3.9") || has(printerWords) { return .imprimante }

        let routerWords = ["router", "routeur", "firewall", "pare-feu", "fortigate", "fortios", "pfsense", "opnsense", "sonicwall",
                           "adaptive security appliance", "cisco asa", "isr software", "isr4", "edgerouter", "edgeos", "unifi security gateway",
                           "dream machine", "udm-", "routeros", "srx", "zywall", "usg flex", "watchguard", "sophos", "gateway"]
        let switchWords = ["switch", "catalyst", "nexus", "procurve", "aruba os-cx", "arubaos-cx", "aos-cx", "powerconnect",
                           "edgeswitch", "usw-", "swos", "crs1", "crs3", "crs5", "fortiswitch", " ex2", " ex3", " ex4", "qfx", "jetstream",
                           "smart managed", "prosafe", "omniswitch", "comware", "icx", "os10", "ftos", "dgs-", "des-1", "des-3", "gs1900",
                           "xgs1", "xgs2", "xs1930"]
        let apWords = ["access point", "fortiap", "unifi ap", "uap-", "instant ap", "aruba ap", "cap ac"]

        switch enterprise {
        case 12356?:  // Fortinet : FortiGate 101, FortiSwitch 106, FortiAP 120.
            if under("1.3.6.1.4.1.12356.106") || descr.contains("fortiswitch") { return .switch }
            if under("1.3.6.1.4.1.12356.120") || descr.contains("fortiap") { return .autre }
            return .routeur
        case 9?, 11?, 47196?, 14823?, 2636?, 41112?, 14988?, 11863?, 4526?, 171?, 890?, 674?, 6027?, 25506?, 1916?, 30065?:
            if has(apWords) { return .autre }
            // Les mots « switch » l'emportent : « Cisco IOS Software, Catalyst … » contient aussi « ios ».
            if has(switchWords) { return .switch }
            if has(routerWords) { return .routeur }
            if let ports = bridgePorts, ports > 0 { return .switch }
            switch enterprise {
            case 14988?: return .routeur  // MikroTik sans pont : RouterOS
            case 11?: return under("1.3.6.1.4.1.11.2.3.7") ? .switch : .autre  // HP : ProCurve seulement
            case 674?: return under("1.3.6.1.4.1.674.10895") ? .switch : .autre  // Dell : PowerConnect, pas iDRAC
            case 4526?: return descr.contains("readynas") ? .autre : .switch
            case 14823?: return .autre  // Aruba Networks : contrôleurs et AP
            default: return .switch
            }
        default:
            if let ports = bridgePorts, ports > 0 { return has(routerWords) && !has(switchWords) ? .routeur : .switch }
            if has(switchWords) { return .switch }
            if has(routerWords) { return .routeur }
            return .autre
        }
    }

    // MARK: ARP des routeurs

    /// Table ARP (IP → MAC) d'un routeur, d'un pare-feu ou d'un switch de niveau 3 : la seule façon de
    /// connaître la MAC des appareils des autres sous-réseaux et VLAN. Vide si l'hôte ne répond pas.
    public static func routerARP(host: IPv4Address, community: String, port: UInt16 = 161,
                                 timeout: TimeInterval = 2, retries: Int = 1) async -> [IPv4Address: MACAddress] {
        guard !community.isEmpty else { return [:] }
        let poller = SNMPSwitchPoller(target: SNMPTarget(host: host, port: port, community: community, timeout: timeout, retries: retries))
        return (try? await poller.arpTable()) ?? [:]
    }
}

// MARK: - Moteur (un fil, sockets UDP non bloquantes, poll)

final class SNMPDiscoveryEngine: @unchecked Sendable {
    private struct Probe {
        let hostIndex: Int
        let host: IPv4Address
        let fd: Int32
        var communityIndex: Int
        var attempt: Int
        var requestID: Int32
        var bytes: [UInt8]
        var deadline: Date
        /// request-id → index de communauté (une réponse tardive à une communauté précédente reste valable).
        var sent: [Int32: Int]
    }

    private let hosts: [IPv4Address]
    private let communities: [String]
    private let timeout: TimeInterval
    private let retries: Int
    private let concurrency: Int
    private let endpoint: SNMPDiscovery.Endpoint
    private let lock = NSLock()
    private var cancelled = false

    init(hosts: [IPv4Address], communities: [String], timeout: TimeInterval, retries: Int, concurrency: Int,
         endpoint: @escaping SNMPDiscovery.Endpoint) {
        self.hosts = hosts
        self.communities = communities
        self.timeout = min(max(timeout, 0.05), 10)
        self.retries = min(max(retries, 0), 5)
        // Une socket par hôte en vol : rester bien sous la limite de descripteurs par défaut (256).
        self.concurrency = min(max(concurrency, 1), 160)
        self.endpoint = endpoint
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func run(_ emit: (SNMPDiscoveryEvent) -> Void) {
        let total = hosts.count
        var nextHost = 0
        var done = 0
        var active: [Probe] = []
        var detail: [(host: IPv4Address, community: String)] = []
        var buffer = [UInt8](repeating: 0, count: 65_535)

        func finish(_ probe: Probe) {
            close(probe.fd)
            done += 1
            emit(.progress(done: done, total: total))
        }

        defer { for probe in active { close(probe.fd) } }

        while !isCancelled {
            while active.count < concurrency, nextHost < total {
                let index = nextHost
                nextHost += 1
                if let probe = start(hostIndex: index) { active.append(probe) } else {
                    done += 1
                    emit(.progress(done: done, total: total))
                }
            }
            if active.isEmpty { break }

            let now = Date()
            let soonest = active.map(\.deadline).min() ?? now
            let wait = Int32(min(100, max(1, soonest.timeIntervalSince(now) * 1000)))
            var pollers = active.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&pollers, nfds_t(pollers.count), wait)
            if ready < 0, errno != EINTR { break }

            var remaining: [Probe] = []
            remaining.reserveCapacity(active.count)
            for (position, original) in active.enumerated() {
                var probe = original
                var outcome: Outcome = .pending
                if ready > 0, pollers[position].revents & Int16(POLLIN | POLLERR | POLLHUP) != 0 {
                    outcome = read(probe, buffer: &buffer)
                }
                if case .pending = outcome, Date() >= probe.deadline {
                    outcome = advance(&probe)
                }
                switch outcome {
                case .pending:
                    remaining.append(probe)
                case .silent:
                    finish(probe)
                case .answered(let communityIndex, let pdu):
                    let community = communities[communityIndex]
                    if pdu.errorStatus != 0 {
                        detail.append((probe.host, community))  // agent v1 ou strict : une variable à la fois
                    } else {
                        emit(.found(Self.discovered(host: probe.host, community: community, binds: pdu.varbinds)))
                    }
                    finish(probe)
                }
            }
            active = remaining
        }

        // Agents qui refusent un GET groupé (noSuchName) : relecture variable par variable.
        for item in detail where !isCancelled {
            let ep = endpoint(item.host)
            let target = SNMPTarget(host: ep.host, port: ep.port, community: item.community, timeout: timeout, retries: retries)
            var binds: [SNMPVarBind] = []
            for oid in SNMPDiscovery.probeOIDs where !isCancelled {
                let message = SNMPMessage(community: item.community,
                                          pdu: SNMPPDU(type: .getRequest, requestID: SNMPClient.newRequestID(), varbinds: [SNMPVarBind(oid: oid)]))
                if let pdu = try? SNMPClient.transact(message.encoded(), requestID: message.pdu.requestID, target: target),
                   pdu.errorStatus == 0 {
                    binds += pdu.varbinds
                }
            }
            emit(.found(Self.discovered(host: item.host, community: item.community, binds: binds)))
        }
    }

    private enum Outcome {
        case pending
        case silent
        case answered(communityIndex: Int, pdu: SNMPPDU)
    }

    /// Ouvre la socket, la connecte (pour recevoir le refus ICMP « port fermé ») et envoie la première requête.
    private func start(hostIndex: Int) -> Probe? {
        let host = hosts[hostIndex]
        let ep = endpoint(host)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = ep.port.bigEndian
        address.sin_addr = in_addr(s_addr: ep.host.value.bigEndian)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        var probe = Probe(hostIndex: hostIndex, host: host, fd: fd, communityIndex: 0, attempt: 0, requestID: 0, bytes: [],
                          deadline: Date(), sent: [:])
        prepare(&probe, communityIndex: 0)
        guard send(probe) else {
            close(fd)
            return nil
        }
        return probe
    }

    private func prepare(_ probe: inout Probe, communityIndex: Int) {
        let requestID = SNMPClient.newRequestID()
        let pdu = SNMPPDU(type: .getRequest, requestID: requestID, varbinds: SNMPDiscovery.probeOIDs.map { SNMPVarBind(oid: $0) })
        probe.communityIndex = communityIndex
        probe.attempt = 0
        probe.requestID = requestID
        probe.bytes = SNMPMessage(community: communities[communityIndex], pdu: pdu).encoded()
        probe.sent[requestID] = communityIndex
    }

    /// Envoi ; false si l'hôte est injoignable (port fermé, pas de route).
    private func send(_ probe: Probe) -> Bool {
        let sent = probe.bytes.withUnsafeBytes { Darwin.send(probe.fd, $0.baseAddress, $0.count, 0) }
        if sent < 0 {
            switch errno {
            case ENOBUFS, EAGAIN, EINTR: return true  // passager : le délai déclenchera un renvoi
            default: return false
            }
        }
        return true
    }

    /// Délai écoulé : renvoi, communauté suivante, ou abandon silencieux.
    private func advance(_ probe: inout Probe) -> Outcome {
        if probe.attempt < retries {
            probe.attempt += 1
        } else if probe.communityIndex + 1 < communities.count {
            prepare(&probe, communityIndex: probe.communityIndex + 1)
        } else {
            return .silent
        }
        probe.deadline = Date().addingTimeInterval(timeout)
        return send(probe) ? .pending : .silent
    }

    private func read(_ probe: Probe, buffer: inout [UInt8]) -> Outcome {
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(probe.fd, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                switch errno {
                case EAGAIN, EINTR: return .pending
                default: return .silent  // ECONNREFUSED : aucun agent SNMP sur cet hôte
                }
            }
            guard count > 0, let message = try? SNMPMessage(decoding: Array(buffer[0..<count])),
                  message.pdu.type == .response, let index = probe.sent[message.pdu.requestID],
                  message.community == communities[index] else { continue }
            return .answered(communityIndex: index, pdu: message.pdu)
        }
    }

    static func discovered(host: IPv4Address, community: String, binds: [SNMPVarBind]) -> SNMPDiscovered {
        func value(_ oid: SNMPOID) -> SNMPValue? { binds.first { $0.oid == oid && !$0.value.isException }?.value }
        let ports = value(SNMPOIDs.dot1dBaseNumPorts)?.intValue.map { Int(clamping: $0) }
        return SNMPDiscovered(host: host, community: community,
                              sysName: value(SNMPOIDs.sysName)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                              sysDescr: value(SNMPOIDs.sysDescr)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                              sysObjectID: value(SNMPOIDs.sysObjectID)?.stringValue,
                              bridgePorts: ports, hasPrinterMIB: value(SNMPOIDs.prtGeneralConfigChanges) != nil)
    }
}
