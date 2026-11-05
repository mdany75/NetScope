import Foundation
import Network

/// Canal d'octets d'une session RFB : la connexion TCP réelle, ou un canal en mémoire (tests,
/// démonstration). `send` garde l'ordre des appels ; `receive` rend au moins un octet, ou lève
/// `RFBError.closed` à la fermeture.
public protocol RFBTransport: AnyObject, Sendable {
    func send(_ bytes: [UInt8])
    func receive() async throws -> [UInt8]
    func close()
}

/// Connexion TCP (Network.framework) vers le serveur VNC.
public final class RFBNetworkTransport: RFBTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "netscope.vnc.transport")
    private let lock = NSLock()
    private var failure: RFBError?

    public init(host: String, port: Int) {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 5900,
                                  using: parameters)
    }

    /// Ouvre la connexion ; lève une erreur si l'hôte ne répond pas avant `timeout` secondes.
    public func open(timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = RFBOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: RFBError.network(Self.describe(error))) }
                case .waiting(let error):
                    // Hôte injoignable ou port fermé : inutile d'attendre la fin du délai.
                    if resumed.claim() {
                        self.connection.cancel()
                        continuation.resume(throwing: RFBError.network(Self.describe(error)))
                    }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: RFBError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.claim() {
                    self.connection.cancel()
                    continuation.resume(throwing: RFBError.timeout)
                }
            }
        }
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "Connexion refusée\u{00A0}: aucun serveur VNC n’écoute sur ce port (Partage d’écran désactivé\u{00A0}?)."
        case .posix(let code) where code == .EHOSTUNREACH || code == .ENETUNREACH:
            return "Hôte injoignable."
        case .posix(let code) where code == .ETIMEDOUT:
            return "Délai dépassé\u{00A0}: l’ordinateur distant ne répond pas."
        default:
            return "Erreur réseau\u{00A0}: \(error.localizedDescription)"
        }
    }

    public func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.lock.lock()
            if self.failure == nil { self.failure = .network(Self.describe(error)) }
            self.lock.unlock()
        })
    }

    public func receive() async throws -> [UInt8] {
        if let failure = lock.withLock({ self.failure }) { throw failure }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if let error {
                    continuation.resume(throwing: RFBError.network(Self.describe(error)))
                } else if isComplete {
                    continuation.resume(throwing: RFBError.closed)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// Indicateur « une seule fois », sûr entre fils d'exécution.
final class RFBOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Canal en mémoire : le « serveur » écrit avec `feed`, lit les octets du client dans `sent`.
/// Sert aux tests (octets fixes) et à la démonstration ; aucun réseau.
public final class RFBMemoryTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8], Error>?
    private var finished = false
    private var written: [UInt8] = []
    /// Appelé à chaque envoi du client (serveur de démonstration qui répond aux demandes).
    public var onSend: (@Sendable ([UInt8]) -> Void)?

    public init(serverBytes: [UInt8] = [], closeAfter: Bool = false) {
        if !serverBytes.isEmpty { pending.append(serverBytes) }
        finished = closeAfter
    }

    /// Octets envoyés par le client jusqu'ici.
    public var sent: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    /// Ajoute des octets côté serveur.
    public func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: bytes)
            return
        }
        pending.append(bytes)
        lock.unlock()
    }

    /// Fin du flux côté serveur (après les octets en attente).
    public func finish() {
        lock.lock()
        finished = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: RFBError.closed)
    }

    public func send(_ bytes: [UInt8]) {
        lock.lock()
        written += bytes
        let handler = onSend
        lock.unlock()
        handler?(bytes)
    }

    public func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !pending.isEmpty {
                let next = pending.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            } else if finished {
                lock.unlock()
                continuation.resume(throwing: RFBError.closed)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    public func close() {
        finish()
    }
}

/// Lecture tamponnée d'un transport : n octets exactement, entiers gros-boutistes.
final class RFBReader {
    private let transport: RFBTransport
    private var buffer: [UInt8] = []
    private var position = 0
    /// Octets reçus depuis l'ouverture.
    private(set) var totalBytes = 0

    init(transport: RFBTransport) {
        self.transport = transport
    }

    private func fill(_ count: Int) async throws {
        while buffer.count - position < count {
            if position > 0, position >= buffer.count / 2 {
                buffer.removeFirst(position)
                position = 0
            }
            let chunk = try await transport.receive()
            totalBytes += chunk.count
            buffer += chunk
        }
    }

    func bytes(_ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        try await fill(count)
        let result = Array(buffer[position..<(position + count)])
        position += count
        return result
    }

    func skip(_ count: Int) async throws {
        guard count > 0 else { return }
        try await fill(count)
        position += count
    }

    func u8() async throws -> UInt8 {
        try await fill(1)
        defer { position += 1 }
        return buffer[position]
    }

    func u16() async throws -> UInt16 {
        try await fill(2)
        defer { position += 2 }
        return UInt16(buffer[position]) << 8 | UInt16(buffer[position + 1])
    }

    func u32() async throws -> UInt32 {
        try await fill(4)
        defer { position += 4 }
        return UInt32(buffer[position]) << 24 | UInt32(buffer[position + 1]) << 16
            | UInt32(buffer[position + 2]) << 8 | UInt32(buffer[position + 3])
    }

    func s32() async throws -> Int32 { Int32(bitPattern: try await u32()) }

    /// Chaîne précédée de sa longueur (u32), bornée pour ne pas allouer n'importe quoi.
    func string(limit: Int = 1 << 20) async throws -> [UInt8] {
        let length = Int(try await u32())
        guard length <= limit else { throw RFBError.protocolViolation("chaîne de \(length) octets") }
        return try await bytes(length)
    }
}

/// Lecture synchrone d'un tableau d'octets déjà reçu (tuiles ZRLE décompressées).
struct RFBByteCursor {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - position }

    mutating func need(_ count: Int) throws {
        guard remaining >= count else { throw RFBError.protocolViolation("données ZRLE tronquées") }
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { position += 1 }
        return bytes[position]
    }
}
