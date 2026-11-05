import Foundation

/// Événement d'une liaison de terminal (SSH, Telnet, série, démonstration).
public enum TerminalTransportEvent: Sendable {
    /// Liaison établie (connexion TCP ouverte, port série ouvert, processus lancé).
    case connected
    case data([UInt8])
    /// Liaison terminée ; message expliqué, ou nil pour une fin normale.
    case closed(String?)
}

/// Liaison d'un onglet de terminal. Les événements arrivent sur un fil quelconque.
public protocol TerminalTransport: AnyObject {
    func start(_ handler: @escaping @Sendable (TerminalTransportEvent) -> Void)
    func send(_ bytes: [UInt8])
    func resize(columns: Int, rows: Int)
    func close()
    /// Le serveur ne renvoie pas la saisie (Telnet sans écho) : l'onglet l'affiche lui-même.
    var wantsLocalEcho: Bool { get }
    /// Signal « break » (console série : interruption du démarrage d'un switch, ROMMON).
    func sendBreak()
}

extension TerminalTransport {
    public var wantsLocalEcho: Bool { false }
    public func sendBreak() {}
}

/// Verrou simple pour l'état partagé des liaisons.
final class TerminalLock: @unchecked Sendable {
    private let lock = NSLock()

    func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
