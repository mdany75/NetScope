import Foundation
import Network

/// Sonde de ports TCP : renvoie les ports ouverts, triés.
public protocol ScanPortProbing: Sendable {
    func openPorts(_ ip: IPv4Address, ports: [UInt16], timeout: Duration, concurrency: Int) async -> [UInt16]
}

/// Connexion TCP complète (Network.framework) sur chaque port ; ouvert si la connexion s'établit
/// avant le délai. Elle est fermée aussitôt, sans rien envoyer.
public struct PortProber: ScanPortProbing {
    public init() {}

    public func openPorts(_ ip: IPv4Address, ports: [UInt16], timeout: Duration = .milliseconds(800),
                          concurrency: Int = 32) async -> [UInt16] {
        let unique = Array(Set(ports.filter { $0 > 0 })).sorted()
        let open = await ScanConcurrency.compactMap(unique, limit: concurrency) { port -> UInt16? in
            await PortProber.isOpen(ip, port: port, timeout: timeout) ? port : nil
        }
        return open.sorted()
    }

    /// Vrai si une connexion TCP vers `ip:port` s'établit avant le délai.
    public static func isOpen(_ ip: IPv4Address, port: UInt16, timeout: Duration) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.scanSeconds.rounded(.up)))
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(ip.description), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "netscope.port")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = OnceFlag()
                let finish: (Bool) -> Void = { open in
                    guard once.claim() else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: open)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    // « waiting » : connexion refusée ou réseau injoignable ; on n'attend pas de nouvel essai.
                    case .failed, .waiting, .cancelled: finish(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(timeout.scanNanoseconds, UInt64(Int.max))))) {
                    finish(false)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Sonde de ports qui ne trouve rien (profil rapide, tests).
public struct ScanNoPorts: ScanPortProbing {
    public init() {}
    public func openPorts(_ ip: IPv4Address, ports: [UInt16], timeout: Duration, concurrency: Int) async -> [UInt16] { [] }
}
