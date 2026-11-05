import Foundation
import Network

/// Onglet Telnet : connexion TCP par Network.framework et négociation de `TelnetNegotiator`.
/// Aucun client externe (telnet n'est plus livré avec macOS).
public final class TelnetTransport: TerminalTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let timeout: TimeInterval

    private let queue = DispatchQueue(label: "netscope.telnet")
    private var connection: NWConnection?
    private var negotiator: TelnetNegotiator
    private var handler: (@Sendable (TerminalTransportEvent) -> Void)?
    private var finished = false
    private var ready = false
    private let lock = TerminalLock()

    public init(host: String, port: Int, columns: Int = 80, rows: Int = 24, timeout: TimeInterval = 15) {
        self.host = host
        self.port = UInt16(clamping: port)
        self.timeout = timeout
        negotiator = TelnetNegotiator(columns: columns, rows: rows)
    }

    /// Le serveur ne fait pas l'écho (pas de « WILL ECHO ») : saisie affichée par l'onglet.
    public var wantsLocalEcho: Bool { lock.run { !negotiator.remoteEcho } }

    public func start(_ handler: @escaping @Sendable (TerminalTransportEvent) -> Void) {
        self.handler = handler
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            handler(.closed("Port \(port) invalide."))
            return
        }
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = Int(timeout)
        options.noDelay = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: options))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout + 1) { [weak self] in
            guard let self, !self.ready else { return }
            self.finish("Délai dépassé : \(self.host) ne répond pas sur le port \(self.port).")
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            handler?(.connected)
            let opening = lock.run { negotiator.start() }
            write(opening)
            receive()
        case .waiting(let error):
            // Port fermé ou réseau absent : NWConnection attendrait indéfiniment.
            finish(Self.describe(error, host: host, port: port))
        case .failed(let error):
            finish(Self.describe(error, host: host, port: port))
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let (payload, reply) = self.lock.run { self.negotiator.receive(Array(data)) }
                if !reply.isEmpty { self.write(reply) }
                if !payload.isEmpty { self.handler?(.data(payload)) }
            }
            if let error {
                self.finish(Self.describe(error, host: self.host, port: self.port))
            } else if isComplete {
                self.finish("Connexion fermée par \(self.host).")
            } else {
                self.receive()
            }
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        connection?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    public func send(_ bytes: [UInt8]) {
        queue.async { [self] in
            let encoded = lock.run { negotiator.encodeOutgoing(bytes) }
            write(encoded)
        }
    }

    public func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            let message = lock.run { negotiator.resize(columns: columns, rows: rows) }
            write(message)
        }
    }

    public func sendBreak() {
        queue.async { [self] in write(TelnetNegotiator.breakCommand) }
    }

    public func close() {
        queue.async { [self] in
            connection?.cancel()
            finish(nil)
        }
    }

    private func finish(_ message: String?) {
        let first = lock.run { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard first else { return }
        connection?.cancel()
        handler?(.closed(message))
    }

    static func describe(_ error: NWError, host: String, port: UInt16) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "\(host) refuse la connexion sur le port \(port) (Telnet désactivé\u{00A0}?)."
            case .ETIMEDOUT: return "Délai dépassé : \(host) ne répond pas sur le port \(port)."
            case .EHOSTUNREACH, .ENETUNREACH: return "Aucune route vers \(host)."
            case .ECONNRESET: return "Connexion interrompue par \(host)."
            default: return "Connexion impossible à \(host)\u{00A0}: \(error.localizedDescription)"
            }
        case .dns: return "Nom d’hôte introuvable (\(host))."
        default: return "Connexion impossible à \(host)\u{00A0}: \(error.localizedDescription)"
        }
    }
}
