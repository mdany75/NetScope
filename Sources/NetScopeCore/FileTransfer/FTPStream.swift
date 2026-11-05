import Foundation
import Network
import Security

// Flux TCP des connexions FTP : URLSessionStreamTask, qui sait passer en TLS après coup (AUTH TLS,
// FTPS explicite) — Network.framework ne le permet pas sur une connexion déjà ouverte — et
// NWConnection pour la connexion de données que le serveur ouvre vers le Mac (mode actif).

/// Flux d'octets bidirectionnel.
protocol FTPByteStream: AnyObject, Sendable {
    /// Lit jusqu'à `max` octets ; nil à la fin du flux.
    func read(max: Int, timeout: TimeInterval) async throws -> Data?
    func write(_ data: Data, timeout: TimeInterval) async throws
    /// Passe en TLS (client), en vérifiant le certificat.
    func startTLS() async throws
    func close()
}

/// Décision sur un certificat présenté par le serveur FTPS.
final class FTPTrustEvaluator: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    /// Empreinte acceptée par l'utilisateur (certificat autosigné).
    let trustedSHA256: String?
    private let lock = NSLock()
    private var _rejected: (sha256: String, subject: String)?

    init(trustedSHA256: String?) {
        self.trustedSHA256 = trustedSHA256?.uppercased()
    }

    /// Dernier certificat refusé (pour proposer de lui faire confiance).
    var rejected: (sha256: String, subject: String)? {
        lock.lock(); defer { lock.unlock() }
        return _rejected
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Certificat valide (autorité reconnue, nom correct) : accepté.
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        // Certificat autosigné (NAS, imprimante, switch) : accepté seulement si son empreinte est
        // celle que l'utilisateur a acceptée ; une empreinte qui change est refusée.
        let (sha, subject) = Self.describe(trust)
        var label = subject
        if let sha {
            switch FortiCertificatePin.evaluate(presented: sha, pinned: trustedSHA256) {
            case .accept:
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            case .changed:
                label = subject + ", empreinte différente de celle acceptée"
            case .unknown:
                break
            }
        }
        lock.lock()
        _rejected = (sha ?? "inconnue", label)
        lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    /// Empreinte SHA-256 (hexadécimal, « AB:CD:… ») et sujet du certificat du serveur.
    static func describe(_ trust: SecTrust) -> (String?, String) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (nil, "certificat illisible")
        }
        let data = SecCertificateCopyData(leaf) as Data
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "sans nom"
        return (FortiCertificatePin.fingerprint(der: data), subject)
    }
}

/// Flux par URLSessionStreamTask.
final class FTPSessionStream: FTPByteStream, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private let evaluator: FTPTrustEvaluator

    init(host: String, port: Int, evaluator: FTPTrustEvaluator) {
        self.evaluator = evaluator
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: evaluator, delegateQueue: nil)
        task = session.streamTask(withHostName: host, port: port)
        task.resume()
    }

    func read(max: Int, timeout: TimeInterval) async throws -> Data? {
        do {
            let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: max, timeout: timeout)
            if let data, !data.isEmpty { return data }
            return eof ? nil : Data()
        } catch {
            throw map(error)
        }
    }

    func write(_ data: Data, timeout: TimeInterval) async throws {
        do {
            try await task.write(data, timeout: timeout)
        } catch {
            throw map(error)
        }
    }

    func startTLS() async throws {
        task.startSecureConnection()
    }

    func close() {
        task.closeWrite()
        task.cancel()
        session.finishTasksAndInvalidate()
    }

    private func map(_ error: Error) -> Error {
        if let rejected = evaluator.rejected {
            return FileTransferError.untrustedCertificate(sha256: rejected.sha256, subject: rejected.subject)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return FileTransferError.timeout
            case NSURLErrorCancelled: return FileTransferError.cancelled
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
                return FileTransferError.tlsUnavailable(nsError.localizedDescription)
            case NSURLErrorCannotConnectToHost: return FileTransferError.connectionFailed("le serveur refuse la connexion (port fermé ?)")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return FileTransferError.connectionFailed("nom d’hôte introuvable")
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return FileTransferError.connectionFailed("connexion perdue")
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ECONNREFUSED) {
            return FileTransferError.connectionFailed("le serveur refuse la connexion (port fermé ?)")
        }
        return FileTransferError.connectionFailed(nsError.localizedDescription)
    }
}

/// Connexion de données entrante (mode actif) : NWListener sur le Mac, une seule connexion acceptée.
final class FTPActiveListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "netscope.ftp.actif")
    private let lock = NSLock()
    private var accepted: NWConnection?
    private var waiter: CheckedContinuation<NWConnection, Error>?

    init(localHost: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localHost), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
    }

    /// Démarre l'écoute et renvoie le port choisi par le système.
    func start(timeout: TimeInterval) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = FTPOnce()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: FileTransferError.connectionFailed("écoute locale impossible (\(error.localizedDescription))")) }
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(throwing: FileTransferError.timeout) }
            }
        }
    }

    private func receive(_ connection: NWConnection) {
        lock.lock()
        guard accepted == nil else {
            lock.unlock()
            connection.cancel()
            return
        }
        accepted = connection
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        listener.cancel()
        waiter?.resume(returning: connection)
    }

    /// Attend la connexion du serveur.
    func accept(timeout: TimeInterval) async throws -> FTPByteStream {
        let connection: NWConnection = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let accepted {
                lock.unlock()
                continuation.resume(returning: accepted)
                return
            }
            waiter = continuation
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let pending = self.waiter
                self.waiter = nil
                self.lock.unlock()
                pending?.resume(throwing: FileTransferError.connectionFailed("le serveur ne s’est pas connecté au Mac (mode actif bloqué par un pare-feu ou le NAT\u{00A0}? essayez le mode passif)"))
            }
        }
        let stream = FTPConnectionStream(connection: connection, queue: queue)
        try await stream.waitReady(timeout: timeout)
        return stream
    }

    func cancel() {
        listener.cancel()
        lock.lock()
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(throwing: FileTransferError.cancelled)
    }
}

/// Flux sur une NWConnection (données du mode actif, en clair).
final class FTPConnectionStream: FTPByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Adresse IPv4 locale de la connexion (« ::ffff:10.0.0.5 » ramené à « 10.0.0.5 »).
    func localIPv4() -> String? {
        guard case .hostPort(let host, _)? = connection.currentPath?.localEndpoint else { return nil }
        var text = "\(host)"
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if text.hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy({ UInt8($0) != nil }) ? text : nil
    }

    func waitReady(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = FTPOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: FileTransferError.connectionFailed(error.localizedDescription)) }
                case .cancelled: if once.claim() { continuation.resume(throwing: FileTransferError.cancelled) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(throwing: FileTransferError.timeout) }
            }
        }
    }

    func read(max: Int, timeout: TimeInterval) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let once = FTPOnce()
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                guard once.claim() else { return }
                if let data, !data.isEmpty { continuation.resume(returning: data); return }
                if let error { continuation.resume(throwing: FileTransferError.connectionFailed(error.localizedDescription)); return }
                continuation.resume(returning: isComplete ? nil : Data())
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(throwing: FileTransferError.timeout) }
            }
        }
    }

    func write(_ data: Data, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: FileTransferError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func startTLS() async throws {
        throw FileTransferError.unsupported("Le mode actif n’est pas proposé en FTPS\u{00A0}: utilisez le mode passif.")
    }

    func close() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        connection.cancel()
    }
}

/// Drapeau « une seule fois » partagé entre fils.
final class FTPOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
