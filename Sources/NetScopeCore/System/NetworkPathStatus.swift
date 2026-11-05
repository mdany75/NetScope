import Foundation
import Network

/// État de la connexion de ce Mac, lu par NWPathMonitor : lecture de l'état local, aucun trafic.
/// Sert aux tâches automatiques (base des fabricants, débit Internet planifié) qui ne doivent
/// jamais télécharger sur une connexion limitée : partage de connexion du téléphone ou données
/// mobiles (« expensive »), mode données réduites (« constrained »).
public struct NetworkPathStatus: Equatable, Sendable {
    public var isSatisfied: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool

    public init(isSatisfied: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// Connexion limitée : rien de lourd ne doit passer par elle.
    public var isLimited: Bool { isExpensive || isConstrained }

    /// Lit l'état courant (premier rappel de NWPathMonitor, ou nil après `timeout` secondes).
    public static func current(timeout: TimeInterval = 2) async -> NetworkPathStatus? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "netscope.chemin-reseau")
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: NetworkPathStatus(isSatisfied: path.status == .satisfied,
                                                                 isExpensive: path.isExpensive,
                                                                 isConstrained: path.isConstrained))
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}
