import Darwin
import Foundation

// Note 78 : serveur iperf3 intégré à NetScope (« iperf3 -s » sans rien installer). Lancé seulement
// sur un clic dans l'outil iperf3, arrêté par l'utilisateur ou par l'app après un délai sans test.
// Un test à la fois (un deuxième client reçoit ACCESS_DENIED, comme avec iperf3) ; TCP seulement,
// sens normal (le client envoie) et inverse -R (ce Mac envoie) ; durée et nombre de flux bornés.

/// Réglages du serveur.
public struct IperfServerConfiguration: Sendable, Equatable {
    public var port: UInt16
    /// Adresse d'écoute (« 127.0.0.1 » pour les tests) ; nil : toutes les interfaces.
    public var bindAddress: String?
    /// Durée maximale d'un test (secondes) : au-delà, le test est interrompu.
    public var maxDuration: Int
    public var maxStreams: Int
    /// Attente des connexions de données après CREATE_STREAMS (secondes).
    public var streamWait: Double

    public init(port: UInt16 = IperfProtocol.defaultPort, bindAddress: String? = nil, maxDuration: Int = 600,
                maxStreams: Int = 32, streamWait: Double = 10) {
        self.port = port
        self.bindAddress = bindAddress
        self.maxDuration = maxDuration
        self.maxStreams = maxStreams
        self.streamWait = streamWait
    }

    /// Paramètres refusés (code d'erreur iperf3 renvoyé au client), ou nil.
    public func refusal(for parameters: IperfTestParameters) -> (code: IperfErrorCode, reason: String)? {
        if parameters.udp { return (.unimplemented, "UDP non pris en charge par le serveur intégré") }
        if parameters.bidirectional { return (.unimplemented, "mode bidirectionnel non pris en charge par le serveur intégré") }
        if parameters.parallel > maxStreams { return (.numStreams, "\(parameters.parallel) flux demandés (\(maxStreams) au plus)") }
        if parameters.time > maxDuration || parameters.time < 0 {
            return (.duration, "durée de \(parameters.time) s demandée (\(maxDuration) s au plus)")
        }
        return nil
    }
}

/// Un test reçu par le serveur.
public struct IperfServerTest: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var client: String
    public var date: Date
    /// Vrai : ce Mac envoie (-R côté client).
    public var reverse: Bool
    public var streams: Int
    public var requestedSeconds: Int
    public var seconds: Double
    /// Octets reçus (sens normal) ou envoyés (sens inverse) par ce Mac.
    public var bytes: Int64
    /// Octets annoncés par le client à la fin (envoyés en sens normal, reçus en sens inverse).
    public var clientBytes: Int64?
    public var intervals: [IperfInterval]
    public var clientVersion: String?

    public init(id: UUID = UUID(), client: String, date: Date, reverse: Bool, streams: Int, requestedSeconds: Int,
                seconds: Double = 0, bytes: Int64 = 0, clientBytes: Int64? = nil, intervals: [IperfInterval] = [],
                clientVersion: String? = nil) {
        self.id = id
        self.client = client
        self.date = date
        self.reverse = reverse
        self.streams = streams
        self.requestedSeconds = requestedSeconds
        self.seconds = seconds
        self.bytes = bytes
        self.clientBytes = clientBytes
        self.intervals = intervals
        self.clientVersion = clientVersion
    }

    public var megabitsPerSecond: Double {
        guard seconds > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    /// « Client → ce Mac » ou « Ce Mac → client ».
    public var directionLabel: String { reverse ? "Ce Mac → client" : "Client → ce Mac" }
}

/// Événements du serveur (sur un fil quelconque).
public enum IperfServerEvent: Sendable {
    case testStarted(IperfServerTest)
    case interval(UUID, IperfInterval)
    case testFinished(IperfServerTest)
    case testFailed(client: String, message: String)
    /// Connexion refusée (test déjà en cours, options non prises en charge).
    case refused(client: String, reason: String)
}

public final class IperfServer: @unchecked Sendable {
    public let configuration: IperfServerConfiguration
    private let onEvent: @Sendable (IperfServerEvent) -> Void
    private let lock = NSLock()
    private let stopFlag = IperfFlag()
    private var listenFD: Int32 = -1
    private var active: IperfServerSession?
    private let acceptDone = DispatchSemaphore(value: 0)
    private var started = false

    public init(configuration: IperfServerConfiguration = IperfServerConfiguration(),
                onEvent: @escaping @Sendable (IperfServerEvent) -> Void = { _ in }) {
        self.configuration = configuration
        self.onEvent = onEvent
    }

    /// Ouvre l'écoute et renvoie le port réel (0 demandé dans les tests : port libre choisi).
    @discardableResult
    public func start() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return IperfSocket.localPort(listenFD) ?? configuration.port }
        let (fd, port) = try IperfSocket.listen(port: configuration.port, bindAddress: configuration.bindAddress)
        listenFD = fd
        started = true
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "NetScope – serveur iperf3"
        thread.qualityOfService = .userInitiated
        thread.start()
        return port
    }

    /// Arrête l'écoute et le test en cours (le client reçoit SERVER_TERMINATE).
    public func stop() {
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()
        guard wasStarted else { return }
        stopFlag.set()
        _ = acceptDone.wait(timeout: .now() + 1)
    }

    /// Un test est en cours.
    public var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil
    }

    private func acceptLoop(_ fd: Int32) {
        defer {
            close(fd)
            acceptDone.signal()
        }
        while !stopFlag.isSet {
            guard IperfSocket.waitReadable(fd, milliseconds: 200) else { continue }
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            guard client >= 0 else { continue }
            let address = IperfSocket.address(of: storage)
            let thread = Thread { [self] in handleIncoming(client, address: address) }
            thread.name = "NetScope – connexion iperf3"
            thread.start()
        }
    }

    /// Lit le cookie d'une nouvelle connexion : flux d'un test en cours, nouveau test, ou refus.
    private func handleIncoming(_ fd: Int32, address: String) {
        IperfSocket.configure(fd, timeout: 5)
        guard let cookie = try? IperfSocket.readExactly(fd, IperfProtocol.cookieSize, step: "cookie") else {
            close(fd)
            return
        }
        lock.lock()
        if let session = active {
            lock.unlock()
            if session.cookie == cookie, session.offerStream(fd) { return }
            // Autre client pendant un test : refus, comme iperf3 (« the server is busy »).
            try? IperfSocket.writeState(fd, .accessDenied)
            close(fd)
            onEvent(.refused(client: address, reason: "un test est déjà en cours"))
            return
        }
        if stopFlag.isSet {
            lock.unlock()
            close(fd)
            return
        }
        let session = IperfServerSession(control: fd, cookie: cookie, client: address, configuration: configuration,
                                         serverStop: stopFlag, onEvent: onEvent)
        active = session
        lock.unlock()
        session.run()
        lock.lock()
        if active === session { active = nil }
        lock.unlock()
    }
}

/// Un test, du cookie de contrôle à IPERF_DONE.
final class IperfServerSession: @unchecked Sendable {
    let control: Int32
    let cookie: [UInt8]
    let client: String
    let configuration: IperfServerConfiguration
    let serverStop: IperfFlag
    let onEvent: @Sendable (IperfServerEvent) -> Void
    private let condition = NSCondition()
    private var acceptingStreams = false
    private var expectedStreams = 0
    private var streamFDs: [Int32] = []

    init(control: Int32, cookie: [UInt8], client: String, configuration: IperfServerConfiguration, serverStop: IperfFlag,
         onEvent: @escaping @Sendable (IperfServerEvent) -> Void) {
        self.control = control
        self.cookie = cookie
        self.client = client
        self.configuration = configuration
        self.serverStop = serverStop
        self.onEvent = onEvent
    }

    /// Connexion de données de ce test ; faux si le test n'en attend plus.
    func offerStream(_ fd: Int32) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard acceptingStreams, streamFDs.count < expectedStreams else { return false }
        streamFDs.append(fd)
        condition.broadcast()
        return true
    }

    func run() {
        var workers: [IperfStreamWorker] = []
        defer {
            for worker in workers { worker.finish() }
            for worker in workers { worker.closeSocket() }
            condition.lock()
            acceptingStreams = false
            let extra = streamFDs.filter { fd in !workers.contains { $0.fd == fd } }
            condition.unlock()
            for fd in extra { close(fd) }
            close(control)
        }
        do {
            IperfSocket.configure(control, timeout: 10)
            try IperfSocket.writeState(control, .paramExchange)
            let parameters = try IperfTestParameters.parse(IperfSocket.readJSON(control, step: "paramètres du test"))
            if let refusal = configuration.refusal(for: parameters) {
                var code = refusal.code.rawValue.bigEndian
                var zero = Int32(0).bigEndian
                let bytes = [IperfState.serverError.byte] + withUnsafeBytes(of: &code) { Array($0) } + withUnsafeBytes(of: &zero) { Array($0) }
                try? IperfSocket.writeAll(control, bytes, step: "refus")
                onEvent(.refused(client: client, reason: refusal.reason))
                return
            }

            // Connexions de données : autant que de flux demandés, reconnues à leur cookie.
            condition.lock()
            expectedStreams = parameters.parallel
            acceptingStreams = true
            condition.unlock()
            try IperfSocket.writeState(control, .createStreams)
            let deadline = Date().addingTimeInterval(configuration.streamWait)
            condition.lock()
            while streamFDs.count < parameters.parallel, !serverStop.isSet, Date() < deadline {
                _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.2)))
            }
            acceptingStreams = false
            let fds = streamFDs
            condition.unlock()
            guard fds.count == parameters.parallel else {
                throw IperfProtocolError.timeout("\(fds.count) connexion(s) de données sur \(parameters.parallel)")
            }

            let ids = IperfProtocol.streamIDs(count: fds.count)
            workers = zip(fds, ids).map { IperfStreamWorker(fd: $0, id: $1, sending: parameters.reverse, blockSize: parameters.blockSize) }
            let cpuStart = IperfCPUSample.now()
            try IperfSocket.writeState(control, .testStart)
            try IperfSocket.writeState(control, .testRunning)
            let t0 = IperfClock.now()
            for worker in workers { worker.start(at: t0) }

            var test = IperfServerTest(client: client, date: Date(), reverse: parameters.reverse, streams: workers.count,
                                       requestedSeconds: parameters.time, clientVersion: parameters.clientVersion)
            onEvent(.testStarted(test))

            // Attente de TEST_END, en relevant un intervalle par seconde.
            let limit = Double(parameters.time > 0 ? parameters.time + parameters.omit : configuration.maxDuration) + 10
            var lastTime = t0
            var lastBytes: Int64 = 0
            func total() -> Int64 { workers.reduce(0) { $0 + $1.counter.total } }
            func addInterval(until now: Double) {
                let bytes = total()
                let seconds = now - lastTime
                guard seconds > 0.05 else { return }
                let interval = IperfInterval(start: lastTime - t0, end: now - t0, bytes: bytes - lastBytes,
                                             bitsPerSecond: Double(bytes - lastBytes) * 8 / seconds)
                test.intervals.append(interval)
                onEvent(.interval(test.id, interval))
                lastTime = now
                lastBytes = bytes
            }
            var ended = false
            while !ended {
                if serverStop.isSet {
                    try? IperfSocket.writeState(control, .serverTerminate)
                    throw IperfProtocolError.serverTerminated
                }
                if IperfSocket.waitReadable(control, milliseconds: 100) {
                    let byte = try IperfSocket.readState(control, step: "fin du test")
                    switch IperfState(byte: byte) {
                    case .testEnd: ended = true
                    case .clientTerminate: throw IperfProtocolError.cancelled
                    default: break
                    }
                }
                let now = IperfClock.now()
                if now - lastTime >= 1 { addInterval(until: now) }
                if now - t0 > limit {
                    try? IperfSocket.writeState(control, .serverTerminate)
                    throw IperfProtocolError.timeout("durée maximale du test dépassée")
                }
            }
            let t1 = IperfClock.now()
            for worker in workers { worker.finish() }
            addInterval(until: t1)
            let elapsed = t1 - t0
            let (cpuTotal, cpuUser, cpuSystem) = IperfCPUSample.now().utilization(since: cpuStart)

            // Résultats : le client envoie les siens, le serveur répond avec les siens.
            try IperfSocket.writeState(control, .exchangeResults)
            let theirs = try IperfExchangedResults.parse(IperfSocket.readJSON(control, step: "résultats du client"))
            let ours = IperfExchangedResults(
                cpuTotal: cpuTotal, cpuUser: cpuUser, cpuSystem: cpuSystem,
                senderHasRetransmits: parameters.reverse ? 0 : -1,
                streams: workers.map { IperfExchangedResults.Stream(id: $0.id, bytes: $0.counter.total, retransmits: -1,
                                                                     startTime: 0, endTime: elapsed) })
            try IperfSocket.writeJSON(control, ours.json, step: "résultats du serveur")
            try IperfSocket.writeState(control, .displayResults)
            // IPERF_DONE : facultatif (le client ferme parfois aussitôt).
            if IperfSocket.waitReadable(control, milliseconds: 3_000) { _ = try? IperfSocket.readState(control, step: "IPERF_DONE") }

            test.seconds = elapsed
            test.bytes = ours.totalBytes
            test.clientBytes = theirs.totalBytes
            onEvent(.testFinished(test))
        } catch let error as IperfProtocolError {
            onEvent(.testFailed(client: client, message: error.errorDescription ?? "\(error)"))
        } catch {
            onEvent(.testFailed(client: client, message: error.localizedDescription))
        }
    }
}
