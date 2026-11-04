import Foundation
import Network
import Security

// Transport SMTP réel de l'envoi des alertes, par Network.framework.
//
// - TLS implicite (465) : TLS dans les paramètres de la connexion, dès l'ouverture.
// - Aucune sécurité : connexion TCP simple (relais interne, sans mot de passe).
// - STARTTLS (587) : Network.framework ne sait pas ajouter TLS à une connexion déjà prête. Un
//   « framer » (SMTPSubmitFramer) se place sous la connexion et garde celle-ci « en préparation »
//   pendant la partie en clair : les commandes passent par lui (SMTPSubmitBridge). À l'ordre de
//   chiffrer, il ajoute TLS au-dessus de lui-même (prependApplicationProtocol), laisse passer les
//   octets et se déclare prêt : la poignée TLS démarre sur la même connexion TCP, puis la suite
//   de la session passe par la connexion. Même principe que le diagnostic SMTP (MailTools).
//
// Le certificat du serveur est vérifié par macOS (chaîne de confiance et nom du serveur) : un
// certificat refusé arrête l'envoi, aucun mot de passe ne part.

public final class SMTPNetworkTransport: SMTPSubmitTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let security: AlertSMTPSecurity
    public let connectTimeout: TimeInterval

    private let queue = DispatchQueue(label: "netscope.alertes.smtp")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var bridge: SMTPSubmitBridge?
    private var parser = SMTPReplyParser()
    private var pending: [SMTPReply] = []
    private var encrypted = false
    private let watcher = SMTPConnectionWatcher()
    /// Raison du refus du certificat, notée par le bloc de vérification.
    private let trustFailure = ToolBox<String?>(nil)

    public init(host: String, port: UInt16, security: AlertSMTPSecurity, connectTimeout: TimeInterval = 15) {
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.port = port
        self.security = security
        self.connectTimeout = connectTimeout
    }

    public var isEncrypted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return encrypted
    }

    private var viaBridge: SMTPSubmitBridge? {
        lock.lock()
        defer { lock.unlock() }
        return bridge
    }

    // MARK: Ouverture

    public func open() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw SMTPSubmitError.invalidConfiguration("port invalide.") }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(connectTimeout.rounded(.up))
        tcp.noDelay = true
        let parameters: NWParameters
        var framerBridge: SMTPSubmitBridge?
        switch security {
        case .implicitTLS:
            parameters = NWParameters(tls: makeTLSOptions(), tcp: tcp)
        case .none:
            parameters = NWParameters(tls: nil, tcp: tcp)
        case .startTLS:
            parameters = NWParameters(tls: nil, tcp: tcp)
            let created = SMTPSubmitBridge()
            let options = NWProtocolFramer.Options(definition: SMTPSubmitFramer.definition)
            options[SMTPSubmitFramer.bridgeKey] = created
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            framerBridge = created
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        lock.withLock {
            self.connection = connection
            self.bridge = framerBridge
        }
        watcher.attach(connection)
        connection.start(queue: queue)

        if let framerBridge {
            // STARTTLS : la connexion TCP est établie quand le framer démarre.
            let watcher = self.watcher
            do {
                try await withTimeout(connectTimeout + 2, onTimeout: SMTPSubmitError.portBlocked(host: host, port: port)) {
                    try await SMTPNetworkTransport.firstOf({ try await framerBridge.waitStarted() }, { try await watcher.waitReady() })
                }
            } catch let error as SMTPSubmitError {
                throw refine(error)
            }
        } else {
            try await waitConnectionReady(timeout: connectTimeout + 2, phase: .connect)
            if security == .implicitTLS { lock.withLock { encrypted = true } }
        }
    }

    /// Attend qu'une des deux attentes aboutisse (la première erreur ou réussite l'emporte).
    private static func firstOf(_ a: @escaping @Sendable () async throws -> Void,
                                _ b: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await a() }
            group.addTask { try await b() }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private enum Phase { case connect, tls }

    private func waitConnectionReady(timeout: TimeInterval, phase: Phase) async throws {
        let fallback: SMTPSubmitError = phase == .connect ? .portBlocked(host: host, port: port) : .timeout("poignée TLS")
        do {
            try await withTimeout(timeout, onTimeout: fallback) { try await self.watcher.waitReady() }
        } catch let error as SMTPSubmitError {
            throw refine(error)
        }
    }

    /// Erreur TLS : la raison notée par la vérification du certificat, si elle existe.
    private func refine(_ error: SMTPSubmitError) -> SMTPSubmitError {
        if case .tlsFailed = error, let reason = trustFailure.value { return .tlsFailed(reason) }
        if case .portBlocked = error, let reason = trustFailure.value { return .tlsFailed(reason) }
        switch error {
        case .connectionRefused, .portBlocked, .hostNotFound: return remap(error)
        default: return error
        }
    }

    private func remap(_ error: SMTPSubmitError) -> SMTPSubmitError {
        switch error {
        case .connectionRefused: return .connectionRefused(host: host, port: port)
        case .portBlocked: return .portBlocked(host: host, port: port)
        case .hostNotFound: return .hostNotFound(host)
        default: return error
        }
    }

    // MARK: Échange

    public func write(_ bytes: [UInt8]) async throws {
        if let bridge = viaBridge {
            try bridge.write(bytes)
            return
        }
        guard let connection = lockedConnection, watcher.isUsable else { throw SMTPSubmitError.connectionClosed("") }
        let queue = self.queue
        let timeout = connectTimeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Une connexion en échec peut ne jamais rappeler : délai de garde.
            let once = ToolOnce()
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                guard once.claim() else { return }
                if error != nil { continuation.resume(throwing: SMTPSubmitError.connectionClosed("")) }
                else { continuation.resume() }
            })
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(throwing: SMTPSubmitError.timeout("")) }
            }
        }
    }

    public func readReply(timeout: TimeInterval) async throws -> SMTPReply {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let next: SMTPReply? = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
            if let next { return next }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SMTPSubmitError.timeout("") }
            let chunk: [UInt8]
            if let bridge = viaBridge {
                chunk = try await bridge.receive(timeout: remaining)
            } else {
                chunk = try await receive(timeout: remaining)
            }
            do {
                try lock.withLock { pending += try parser.feed(chunk) }
            } catch {
                throw SMTPSubmitError.protocolError((error as? LocalizedError)?.errorDescription ?? "réponse illisible.")
            }
        }
    }

    private var lockedConnection: NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }

    private func receive(timeout: TimeInterval) async throws -> [UInt8] {
        guard let connection = lockedConnection else { throw SMTPSubmitError.connectionClosed("") }
        let queue = self.queue
        return try await withCheckedThrowingContinuation { continuation in
            let once = ToolOnce()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                guard once.claim() else { return }
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if error != nil || complete {
                    continuation.resume(throwing: SMTPSubmitError.connectionClosed(""))
                } else {
                    continuation.resume(throwing: SMTPSubmitError.protocolError("réponse vide."))
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(throwing: SMTPSubmitError.timeout("")) }
            }
        }
    }

    public func upgradeToTLS() async throws {
        guard let bridge = viaBridge else {
            throw SMTPSubmitError.tlsFailed(isEncrypted ? "la session est déjà chiffrée." : "STARTTLS impossible dans ce mode.")
        }
        try bridge.upgrade(options: makeTLSOptions())
        lock.withLock { self.bridge = nil }
        try await waitConnectionReady(timeout: connectTimeout + 5, phase: .tls)
        lock.withLock { encrypted = true }
    }

    public func close() {
        lockedConnection?.cancel()
        viaBridge?.cancel()
    }

    // MARK: TLS

    /// TLS 1.2 au moins ; certificat vérifié par macOS (chaîne et nom du serveur).
    private func makeTLSOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        let serverName = IPv4Address(host) == nil ? host : nil
        if let serverName { sec_protocol_options_set_tls_server_name(security, serverName) }
        let failure = trustFailure
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, serverName as CFString?))
            var error: CFError?
            let trusted = SecTrustEvaluateWithError(secTrust, &error)
            if !trusted {
                failure.mutate { $0 = SMTPNetworkTransport.trustMessage(error, serverName: serverName) }
            }
            complete(trusted)
        }, queue)
        return options
    }

    static func trustMessage(_ error: CFError?, serverName: String?) -> String {
        let code = error.map { CFErrorGetCode($0) } ?? 0
        switch OSStatus(code) {
        case errSecCertificateExpired: return "certificat du serveur expiré."
        case errSecHostNameMismatch:
            return "le certificat ne correspond pas au nom «\u{00A0}\(serverName ?? "?")\u{00A0}»."
        case errSecNotTrusted, errSecCreateChainFailed:
            return "certificat non approuvé par macOS (auto-signé ou autorité inconnue)."
        default:
            let text = error.map { CFErrorCopyDescription($0) as String } ?? ""
            return "certificat refusé" + (text.isEmpty ? "." : " (\(text)).")
        }
    }
}

// MARK: - Délai

/// Exécute `body` ; au-delà de `seconds`, lève `onTimeout`.
func withTimeout(_ seconds: TimeInterval, onTimeout: SMTPSubmitError,
                 _ body: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw onTimeout
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}

// MARK: - Suivi de l'état de la connexion

/// Retient l'état de la connexion et réveille ceux qui attendent « prête » (ou l'échec).
final class SMTPConnectionWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var failure: SMTPSubmitError?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Faux dès que la connexion a échoué ou a été fermée.
    var isUsable: Bool { lock.withLock { failure == nil } }

    func attach(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.resolve(nil)
            case .waiting(let error), .failed(let error): self?.resolve(SMTPConnectionWatcher.map(error))
            case .cancelled: self?.resolve(.connectionClosed(""))
            default: break
            }
        }
    }

    private func resolve(_ error: SMTPSubmitError?) {
        lock.lock()
        if let error {
            if failure == nil { failure = error }
        } else {
            ready = true
        }
        let current = waiters
        waiters = [:]
        let failure = self.failure
        let ready = self.ready
        lock.unlock()
        for continuation in current.values {
            if ready && error == nil { continuation.resume() } else { continuation.resume(throwing: failure ?? .connectionClosed("")) }
        }
    }

    func waitReady() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if ready {
                    lock.unlock()
                    continuation.resume()
                } else if let failure {
                    lock.unlock()
                    continuation.resume(throwing: failure)
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Erreur réseau → explication (l'hôte et le port sont ajoutés par le transport).
    static func map(_ error: NWError) -> SMTPSubmitError {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused(host: "", port: 0)
            case .ETIMEDOUT: return .portBlocked(host: "", port: 0)
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN: return .protocolError("hôte injoignable depuis ce réseau.")
            case .ECONNRESET, .ECONNABORTED, .EPIPE: return .connectionClosed("")
            default: return .protocolError(String(cString: strerror(code.rawValue)))
            }
        case .dns: return .hostNotFound("")
        case .tls(let status):
            return .tlsFailed("poignée TLS refusée (code \(status)).")
        default:
            return .protocolError(error.localizedDescription)
        }
    }
}

// MARK: - Pont du framer (partie en clair de STARTTLS)

/// Échange en clair mené à travers le framer, avant que la connexion ne soit « prête ».
final class SMTPSubmitBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var framer: NWProtocolFramer.Instance?
    private var buffer: [UInt8] = []
    private var closed = false
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var readWaiter: (id: UUID, continuation: CheckedContinuation<[UInt8], Error>)?

    // Appelé par le framer (file de la connexion).

    func didStart(_ instance: NWProtocolFramer.Instance) {
        lock.lock()
        framer = instance
        started = true
        let waiter = startWaiter
        startWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func deliver(_ bytes: [UInt8]) {
        lock.lock()
        buffer += bytes
        let waiter = readWaiter
        var chunk: [UInt8] = []
        if waiter != nil {
            chunk = buffer
            buffer = []
            readWaiter = nil
        }
        lock.unlock()
        waiter?.continuation.resume(returning: chunk)
    }

    func didClose() {
        lock.lock()
        closed = true
        let waiter = readWaiter
        readWaiter = nil
        let start = startWaiter
        startWaiter = nil
        lock.unlock()
        waiter?.continuation.resume(throwing: SMTPSubmitError.connectionClosed(""))
        start?.resume(throwing: SMTPSubmitError.connectionClosed(""))
    }

    func cancel() { didClose() }

    // Appelé par le transport.

    func waitStarted() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if started {
                    lock.unlock()
                    continuation.resume()
                } else if closed {
                    lock.unlock()
                    continuation.resume(throwing: SMTPSubmitError.connectionClosed(""))
                } else {
                    startWaiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = startWaiter
            startWaiter = nil
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }

    func receive(timeout: TimeInterval) async throws -> [UInt8] {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let chunk = buffer
                buffer = []
                lock.unlock()
                continuation.resume(returning: chunk)
                return
            }
            if closed {
                lock.unlock()
                continuation.resume(throwing: SMTPSubmitError.connectionClosed(""))
                return
            }
            readWaiter = (id, continuation)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard let waiter = self.readWaiter, waiter.id == id else {
                    self.lock.unlock()
                    return
                }
                self.readWaiter = nil
                self.lock.unlock()
                waiter.continuation.resume(throwing: SMTPSubmitError.timeout(""))
            }
        }
    }

    private var instance: NWProtocolFramer.Instance? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : framer
    }

    func write(_ bytes: [UInt8]) throws {
        guard let framer = instance else { throw SMTPSubmitError.connectionClosed("") }
        let data = Data(bytes)
        framer.async { framer.writeOutput(data: data) }
    }

    /// Ajoute TLS au-dessus du framer, laisse passer les octets et déclare la connexion prête.
    func upgrade(options: NWProtocolTLS.Options) throws {
        guard let framer = instance else { throw SMTPSubmitError.connectionClosed("") }
        framer.async {
            do {
                try framer.prependApplicationProtocol(options: options)
            } catch {
                framer.markFailed(error: .posix(.ECONNABORTED))
                return
            }
            framer.passThroughInput()
            framer.passThroughOutput()
            framer.markReady()
        }
    }
}

/// Framer de la partie en clair : transmet les octets reçus au pont, écrit ce que le pont envoie.
final class SMTPSubmitFramer: NWProtocolFramerImplementation {
    static let label = "NetScope SMTP (alertes)"
    static let definition = NWProtocolFramer.Definition(implementation: SMTPSubmitFramer.self)
    static let bridgeKey = "netscope.alertes.smtp.pont"

    private var bridge: SMTPSubmitBridge?

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        bridge = framer.options[Self.bridgeKey] as? SMTPSubmitBridge
        bridge?.didStart(framer)
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        var bytes: [UInt8] = []
        var closed = false
        while true {
            var consumed = 0
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 16_384) { buffer, isComplete in
                guard let buffer, buffer.count > 0 else {
                    if isComplete { closed = true }
                    return 0
                }
                bytes += buffer
                consumed = buffer.count
                return buffer.count
            }
            if !parsed || consumed == 0 { break }
        }
        if !bytes.isEmpty { bridge?.deliver(bytes) }
        if closed { bridge?.didClose() }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool {
        bridge?.didClose()
        return true
    }

    func cleanup(framer: NWProtocolFramer.Instance) {
        bridge?.didClose()
    }
}
