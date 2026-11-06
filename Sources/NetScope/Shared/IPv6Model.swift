import Foundation
import NetScopeCore

/// IPv6 (0.31.0) : état IPv6 de ce Mac, voisins de la table NDP (lue sans paquet) rattachés aux
/// appareils par la MAC, sollicitation ff02::1 sur un clic, ping et traceroute IPv6 de l'outil.
@MainActor
final class IPv6Model: ObservableObject {
    static let shared = IPv6Model()

    @Published private(set) var status = IPv6HostStatus(interface: nil, addresses: [])
    @Published private(set) var neighbors: [IPv6Neighbor] = []
    @Published private(set) var lastRead: Date?
    /// Adresses qui ont répondu à la dernière sollicitation ff02::1 (nil : jamais lancée).
    @Published private(set) var solicited: [IPv6Address]?
    @Published private(set) var isSoliciting = false

    // Outil : ping et traceroute IPv6.
    @Published var target = IPv6Demo.pingTarget
    @Published private(set) var pingResults: [PingProbeResult] = []
    @Published private(set) var isPinging = false
    @Published private(set) var trace: [IPv6TraceHop]?
    @Published private(set) var traceTarget: String?
    @Published private(set) var isTracing = false
    @Published private(set) var message: String?

    let isDemo: Bool

    private init() {
        isDemo = Launcher.isDemo
        if isDemo {
            status = IPv6Demo.status
            neighbors = IPv6Demo.neighbors
            lastRead = Date()
            solicited = IPv6Demo.solicited
            pingResults = [12.9, 12.7, 13.0, 12.8].map { PingProbeResult(rttMs: $0) }
            trace = IPv6Demo.trace
            traceTarget = IPv6Demo.pingTarget
        }
    }

    /// Relit l'état local (getifaddrs) et la table NDP (sysctl) : aucun paquet envoyé.
    func refresh(interface: String?, state: AppState? = nil) {
        guard !isDemo else { return }
        Task.detached(priority: .utility) {
            let status = LocalIPv6.status(interface: interface)
            let neighbors = NDPTable().read()
            await MainActor.run {
                let model = IPv6Model.shared
                if model.status != status { model.status = status }
                model.neighbors = neighbors
                model.lastRead = Date()
                if let state { model.attach(to: state) }
            }
        }
    }

    /// Rattache les voisins lus aux appareils (par la MAC).
    func attach(to state: AppState) {
        guard !neighbors.isEmpty else { return }
        var devices = state.devices
        if IPv6Attachment.attach(neighbors, to: &devices) > 0 { state.devices = devices }
    }

    /// Ping ICMPv6 de tous les nœuds du lien (ff02::1) sur l'interface active, puis relecture de la
    /// table NDP. Seulement sur un clic.
    func solicit(state: AppState) {
        guard !isSoliciting else { return }
        let interface = state.activeInterface?.name ?? status.interface ?? "en0"
        isSoliciting = true
        if isDemo {
            solicited = IPv6Demo.solicited
            isSoliciting = false
            return
        }
        Task.detached(priority: .userInitiated) {
            let found = PingICMPv6.solicitAllNodes(interface: interface)
            await MainActor.run {
                let model = IPv6Model.shared
                model.solicited = found
                model.isSoliciting = false
                model.refresh(interface: interface, state: state)
            }
        }
    }

    /// Voisins dont la MAC n'est pas dans les résultats du scan (appareils IPv6 seulement).
    func unmatched(in state: AppState) -> [IPv6Neighbor] {
        IPv6Attachment.unmatched(neighbors, devices: state.devices)
    }

    // MARK: Outil

    var parsedTarget: (address: IPv6Address, zone: String?)? { IPv6Address.parseZoned(target) }

    func ping(count: Int = 4) {
        guard let parsed = parsedTarget, !isPinging else {
            message = "Adresse IPv6 illisible (zone permise pour le lien local\u{00A0}: fe80::1%en0)."
            return
        }
        message = nil
        pingResults = []
        isPinging = true
        Task {
            for sequence in 1...count {
                let result = await Task.detached(priority: .userInitiated) {
                    PingICMPv6.probe(parsed.address, zone: parsed.zone, timeout: 2, sequence: UInt16(sequence))
                }.value
                pingResults.append(result)
            }
            isPinging = false
        }
    }

    func runTrace() {
        guard let parsed = parsedTarget, !isTracing else {
            message = "Adresse IPv6 illisible (zone permise pour le lien local\u{00A0}: fe80::1%en0)."
            return
        }
        message = nil
        isTracing = true
        trace = nil
        traceTarget = target
        Task {
            let hops = await IPv6Trace.run(destination: parsed.address, zone: parsed.zone)
            if hops == nil { message = "traceroute6 est introuvable sur ce Mac." }
            trace = hops
            isTracing = false
        }
    }

    /// Traceroute d'une cible du ping continu (même tableau que l'outil).
    func trace(to host: String) {
        target = host
        runTrace()
    }
}
