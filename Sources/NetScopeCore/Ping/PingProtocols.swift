import Darwin
import Foundation

// Ping continu au-delà de l'ICMP (note 65) : connexion TCP à un port (temps de la poignée de
// main SYN → SYN/ACK) et requête HTTP(S) (temps jusqu'au premier octet de la réponse, code HTTP).
// Pour les caméras, serveurs et liens qui filtrent l'ICMP.

/// Façon de sonder une cible du ping continu.
public enum PingProbeKind: Hashable, Sendable {
    case icmp
    case tcp(port: UInt16)
    case http(URL)

    /// « ICMP », « TCP 443 », « HTTPS ».
    public var label: String {
        switch self {
        case .icmp: return "ICMP"
        case let .tcp(port): return "TCP \(port)"
        case let .http(url): return url.scheme?.lowercased() == "https" ? "HTTPS" : "HTTP"
        }
    }

    public var isICMP: Bool { self == .icmp }

    /// Port TCP sondé (TCP) ou servi (HTTP), pour le traceroute TCP.
    public var tcpPort: UInt16? {
        switch self {
        case .icmp: return nil
        case let .tcp(port): return port
        case let .http(url):
            if let port = url.port, let value = UInt16(exactly: port) { return value }
            return url.scheme?.lowercased() == "https" ? 443 : 80
        }
    }
}

/// Mode choisi dans la barre du ping continu pour une cible saisie sans préfixe.
public enum PingProbeMode: String, CaseIterable, Sendable {
    case icmp, tcp, http
}

/// Cible saisie, décodée : « 10.0.0.5 », « 10.0.0.5:443 », « tcp://nas:5000 », « https://site.ca/santé ».
public struct PingTargetSpec: Equatable, Sendable {
    public let kind: PingProbeKind
    /// Nom ou adresse à résoudre.
    public let host: String
    /// Texte canonique (sert à éviter les doublons) : l'hôte en ICMP, « tcp://hôte:port », l'URL.
    public let canonical: String

    public init(kind: PingProbeKind, host: String) {
        self.kind = kind
        self.host = host
        switch kind {
        case .icmp: canonical = host
        case let .tcp(port): canonical = "tcp://\(host):\(port)"
        case let .http(url): canonical = url.absoluteString
        }
    }

    /// Libellé de la cible : adresse (ICMP), « adresse:port » (TCP), URL sans « https:// » (HTTP).
    public static func endpoint(kind: PingProbeKind, address: String) -> String {
        switch kind {
        case .icmp: return address
        case let .tcp(port): return "\(address):\(port)"
        case let .http(url):
            var text = url.absoluteString
            for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) { text.removeFirst(prefix.count) }
            return text.hasSuffix("/") && text.filter({ $0 == "/" }).count == 1 ? String(text.dropLast()) : text
        }
    }

    /// Décode une saisie. Un préfixe (tcp://, http://, https://) ou un port (« hôte:443 ») l'emporte
    /// sur le mode choisi ; sinon le mode s'applique (TCP sur `defaultPort`, HTTP en https://).
    public static func parse(_ input: String, mode: PingProbeMode = .icmp, defaultPort: UInt16 = 443) -> PingTargetSpec? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
            // Pas d'identifiants dans l'URL : ils finiraient en clair dans la session, le journal et l'export.
            guard url.user == nil, url.password == nil else { return nil }
            return PingTargetSpec(kind: .http(normalized(url)), host: host)
        }
        if lower.hasPrefix("tcp://") {
            let rest = String(text.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let (host, port) = hostAndPort(rest) else {
                return rest.isEmpty || rest.contains(":") ? nil : PingTargetSpec(kind: .tcp(port: defaultPort), host: rest)
            }
            return PingTargetSpec(kind: .tcp(port: port), host: host)
        }
        if let (host, port) = hostAndPort(text) {
            return PingTargetSpec(kind: .tcp(port: port), host: host)
        }
        guard !text.contains(":"), !text.contains("/") else { return nil }
        switch mode {
        case .icmp: return PingTargetSpec(kind: .icmp, host: text)
        case .tcp: return PingTargetSpec(kind: .tcp(port: defaultPort), host: text)
        case .http:
            let scheme = defaultPort == 80 ? "http" : "https"
            let port = defaultPort == 80 || defaultPort == 443 ? "" : ":\(defaultPort)"
            guard let url = URL(string: "\(scheme)://\(text)\(port)/") else { return nil }
            return PingTargetSpec(kind: .http(url), host: text)
        }
    }

    private static func normalized(_ url: URL) -> URL {
        guard url.path.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.path = "/"
        return components.url ?? url
    }

    /// « hôte:port » (IPv4 ou nom, port 1…65535).
    static func hostAndPort(_ text: String) -> (String, UInt16)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]), port > 0 else { return nil }
        return (String(parts[0]), port)
    }
}

/// Résultat d'une sonde TCP ou HTTP.
public struct PingProbeResult: Equatable, Sendable {
    public var rttMs: Double?
    public var failure: PingFailure?
    public var statusCode: Int?
    public var detail: String?

    public init(rttMs: Double?, failure: PingFailure? = nil, statusCode: Int? = nil, detail: String? = nil) {
        self.rttMs = rttMs
        self.failure = failure
        self.statusCode = statusCode
        self.detail = detail
    }

    public static func lost(_ failure: PingFailure, detail: String? = nil) -> PingProbeResult {
        PingProbeResult(rttMs: nil, failure: failure, detail: detail)
    }
}

// MARK: - TCP

/// Ping TCP : temps d'établissement d'une connexion (SYN → SYN/ACK, mesuré à l'horloge monotone
/// entre `connect()` et la socket prête en écriture). La connexion est aussitôt fermée.
public enum PingTCP {
    /// Classe le résultat d'une tentative (pur, testé) : `connectErrno` = errno de connect() (0 si
    /// connectée tout de suite), `socketError` = SO_ERROR après l'attente, `timedOut` = rien dans le délai.
    public static func classify(connectErrno: Int32, socketError: Int32, timedOut: Bool,
                                startMs: Double, endMs: Double) -> PingProbeResult {
        let elapsed = max(0, endMs - startMs)
        if connectErrno != 0 && connectErrno != EINPROGRESS {
            return result(forError: connectErrno, elapsed: elapsed)
        }
        if timedOut { return .lost(.timeout) }
        if socketError != 0 { return result(forError: socketError, elapsed: elapsed) }
        return PingProbeResult(rttMs: elapsed)
    }

    private static func result(forError code: Int32, elapsed: Double) -> PingProbeResult {
        switch code {
        case ECONNREFUSED:
            // Le RST prouve que l'hôte répond : le temps est gardé dans le détail.
            return .lost(.refused, detail: "RST en \(PingFormat.decimal(elapsed))\u{00A0}ms")
        case ETIMEDOUT: return .lost(.timeout)
        case EHOSTUNREACH, EHOSTDOWN: return .lost(.unreachable(code: 1, from: nil))
        case ENETUNREACH, ENETDOWN: return .lost(.unreachable(code: 0, from: nil))
        default: return .lost(.failed(String(cString: strerror(code))))
        }
    }

    /// Une tentative de connexion (bloquante, au plus `timeout`).
    public static func probe(_ address: IPv4Address, port: UInt16, timeout: TimeInterval) -> PingProbeResult {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .lost(.failed("socket TCP refusée")) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Fermeture brutale (RST) : pas d'état TIME_WAIT laissé par chaque sonde sur ce Mac.
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let start = PingClock.nowMs()
        let connected = ToolSocket.connect(fd, to: ToolSocket.address(address, port: port))
        let connectErrno: Int32 = connected == 0 ? 0 : errno
        if connected == 0 {
            return classify(connectErrno: 0, socketError: 0, timedOut: false, startMs: start, endMs: PingClock.nowMs())
        }
        guard connectErrno == EINPROGRESS else {
            return classify(connectErrno: connectErrno, socketError: 0, timedOut: false, startMs: start, endMs: PingClock.nowMs())
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(clamping: Int(max(1, min(timeout, 60) * 1000)))
        let ready = poll(&pfd, 1, milliseconds)
        let end = PingClock.nowMs()
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        if ready > 0 { getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) }
        return classify(connectErrno: EINPROGRESS, socketError: socketError, timedOut: ready <= 0, startMs: start, endMs: end)
    }
}

// MARK: - HTTP(S)

/// Découpage du temps d'une requête HTTP (dates de URLSessionTaskTransactionMetrics).
public struct PingHTTPTiming: Equatable, Sendable {
    public var dnsMs: Double?
    public var tcpMs: Double?
    public var tlsMs: Double?
    /// Attente du serveur : envoi de la requête → premier octet de la réponse.
    public var waitMs: Double?
    /// Début → premier octet de la réponse (valeur du ping HTTP).
    public var totalMs: Double?

    public init(dnsMs: Double? = nil, tcpMs: Double? = nil, tlsMs: Double? = nil, waitMs: Double? = nil, totalMs: Double? = nil) {
        self.dnsMs = dnsMs
        self.tcpMs = tcpMs
        self.tlsMs = tlsMs
        self.waitMs = waitMs
        self.totalMs = totalMs
    }

    /// Calcul pur à partir des dates des métriques. Dans URLSession, la connexion (connectStart →
    /// connectEnd) inclut la négociation TLS : le TCP seul s'arrête au début du TLS.
    public static func from(fetchStart: Date?, dnsStart: Date?, dnsEnd: Date?, connectStart: Date?, connectEnd: Date?,
                            tlsStart: Date?, tlsEnd: Date?, requestStart: Date?, responseStart: Date?) -> PingHTTPTiming {
        func span(_ a: Date?, _ b: Date?) -> Double? {
            guard let a, let b, b >= a else { return nil }
            return b.timeIntervalSince(a) * 1000
        }
        return PingHTTPTiming(dnsMs: span(dnsStart, dnsEnd),
                              tcpMs: span(connectStart, tlsStart ?? connectEnd),
                              tlsMs: span(tlsStart, tlsEnd),
                              waitMs: span(requestStart, responseStart),
                              totalMs: span(fetchStart ?? dnsStart ?? connectStart ?? requestStart, responseStart))
    }

    /// « DNS 2 · TCP 11 · TLS 24 · attente 38 ms ».
    public var summary: String? {
        var parts: [String] = []
        if let dnsMs, dnsMs >= 0.5 { parts.append("DNS \(PingFormat.decimal(dnsMs))") }
        if let tcpMs { parts.append("TCP \(PingFormat.decimal(tcpMs))") }
        if let tlsMs { parts.append("TLS \(PingFormat.decimal(tlsMs))") }
        if let waitMs { parts.append("attente \(PingFormat.decimal(waitMs))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ") + "\u{00A0}ms"
    }
}

/// Ping HTTP(S) : une requête GET par sonde, sur une connexion neuve (DNS, TCP et TLS compris),
/// arrêtée dès l'arrivée de l'en-tête de la réponse. Les redirections ne sont pas suivies (le
/// code 301 ou 302 est la réponse). Certificats auto-signés acceptés (équipements réseau).
public enum PingHTTP {
    /// Code qui compte comme une perte : erreur du serveur (5xx). Un 4xx prouve que le serveur répond.
    public static func isFailure(status: Int) -> Bool { status >= 500 }

    /// Code d'une ligne d'état (« HTTP/1.1 200 OK » → 200).
    public static func statusCode(fromStatusLine line: String) -> Int? {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].uppercased().hasPrefix("HTTP/"), let code = Int(parts[1]), (100...599).contains(code) else { return nil }
        return code
    }

    /// Résultat d'une réponse reçue (pur, testé).
    public static func result(status: Int, timing: PingHTTPTiming, fallbackMs: Double) -> PingProbeResult {
        let total = timing.totalMs ?? fallbackMs
        let detail = timing.summary
        if isFailure(status: status) {
            return PingProbeResult(rttMs: nil, failure: .httpStatus(status), statusCode: status, detail: detail)
        }
        return PingProbeResult(rttMs: total, statusCode: status, detail: detail)
    }

    public static func probe(_ url: URL, timeout: TimeInterval) async -> PingProbeResult {
        if url.scheme?.lowercased() == "http" {
            // HTTP en clair : requête écrite à la main (l'App Transport Security bloquerait URLSession
            // hors du réseau local), ce qui donne aussi le temps TCP exact.
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: plainProbe(url, timeout: timeout))
                }
            }
        }
        return await secureProbe(url, timeout: timeout)
    }

    // MARK: HTTPS par URLSession

    private static func secureProbe(_ url: URL, timeout: TimeInterval) async -> PingProbeResult {
        // Tâche déjà annulée : ne rien créer (une session invalidée refuse toute nouvelle tâche).
        if Task.isCancelled { return .lost(.failed("annulé")) }
        let delegate = PingHTTPDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "NetScope"]
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // La tâche est créée avant le gestionnaire d'annulation : onCancel l'annule sans invalider
        // la session, et une tâche annulée avant resume() se termine aussitôt par une erreur.
        let task = session.dataTask(with: request)
        let start = PingClock.nowMs()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.completion = { status, metrics, error in
                    let elapsed = PingClock.nowMs() - start
                    if let status {
                        let transaction = metrics?.transactionMetrics.last
                        let timing = PingHTTPTiming.from(
                            fetchStart: transaction?.fetchStartDate, dnsStart: transaction?.domainLookupStartDate,
                            dnsEnd: transaction?.domainLookupEndDate, connectStart: transaction?.connectStartDate,
                            connectEnd: transaction?.connectEndDate, tlsStart: transaction?.secureConnectionStartDate,
                            tlsEnd: transaction?.secureConnectionEndDate, requestStart: transaction?.requestStartDate,
                            responseStart: transaction?.responseStartDate)
                        continuation.resume(returning: result(status: status, timing: timing, fallbackMs: elapsed))
                    } else {
                        continuation.resume(returning: failure(error))
                    }
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func failure(_ error: Error?) -> PingProbeResult {
        guard let error = error as? URLError else { return .lost(.failed(error?.localizedDescription ?? "aucune réponse")) }
        switch error.code {
        case .timedOut: return .lost(.timeout)
        case .cannotFindHost, .dnsLookupFailed: return .lost(.failed("nom introuvable"))
        case .cannotConnectToHost: return .lost(.refused)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .lost(.failed("échec TLS"))
        case .networkConnectionLost: return .lost(.failed("connexion coupée"))
        case .notConnectedToInternet: return .lost(.failed("hors ligne"))
        default: return .lost(.failed(error.localizedDescription))
        }
    }

    // MARK: HTTP en clair

    static func plainProbe(_ url: URL, timeout: TimeInterval) -> PingProbeResult {
        guard let host = url.host, !host.contains(where: { $0.isNewline || $0 == " " }) else {
            return .lost(.failed("adresse web invalide"))
        }
        let port = UInt16(exactly: url.port ?? 80) ?? 80
        let start = PingClock.nowMs()
        let address: IPv4Address
        if let literal = IPv4Address(host) {
            address = literal
        } else {
            guard let resolved = try? PingResolver.resolve(host) else { return .lost(.failed("nom introuvable")) }
            address = resolved
        }
        let dnsEnd = PingClock.nowMs()
        let fd: Int32
        do {
            fd = try ToolSocket.connectTCP(address, port: port, timeout: timeout)
        } catch let error as ToolError {
            if case .timeout = error { return .lost(.timeout) }
            if case let .socket(text) = error, text.contains("refused") || text.contains("refus") { return .lost(.refused) }
            return .lost(.failed(error.localizedDescription))
        } catch {
            return .lost(.failed(error.localizedDescription))
        }
        defer { close(fd) }
        let connectEnd = PingClock.nowMs()
        let encodedPath = url.path(percentEncoded: true)
        let path = (encodedPath.isEmpty ? "/" : encodedPath) + (url.query(percentEncoded: true).map { "?\($0)" } ?? "")
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let request = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: NetScope\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        do {
            try ToolSocket.sendAll(fd, Array(request.utf8))
        } catch {
            return .lost(.failed("envoi de la requête impossible"))
        }
        let requestEnd = PingClock.nowMs()
        var buffer = [UInt8](repeating: 0, count: 512)
        var received: [UInt8] = []
        var firstByte: Double?
        while !received.contains(0x0A), received.count < 4096 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            if firstByte == nil { firstByte = PingClock.nowMs() }
            received.append(contentsOf: buffer[0..<count])
        }
        guard let firstByte else {
            return PingClock.nowMs() - requestEnd >= timeout * 1000 - 50 ? .lost(.timeout) : .lost(.failed("aucune réponse HTTP"))
        }
        let line = String(decoding: received.prefix { $0 != 0x0D && $0 != 0x0A }, as: UTF8.self)
        guard let status = statusCode(fromStatusLine: line) else { return .lost(.failed("réponse non HTTP")) }
        let timing = PingHTTPTiming(dnsMs: IPv4Address(host) == nil ? dnsEnd - start : nil, tcpMs: connectEnd - dnsEnd,
                                    tlsMs: nil, waitMs: firstByte - requestEnd, totalMs: firstByte - start)
        return result(status: status, timing: timing, fallbackMs: firstByte - start)
    }
}

/// Délégué du ping HTTPS : arrête la requête à l'arrivée de l'en-tête, garde les métriques,
/// ne suit pas les redirections et accepte les certificats auto-signés.
final class PingHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var completion: ((Int?, URLSessionTaskMetrics?, Error?) -> Void)?
    private let lock = NSLock()
    private var status: Int?
    private var metrics: URLSessionTaskMetrics?
    private var finished = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        status = (response as? HTTPURLResponse)?.statusCode
        lock.unlock()
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            // Le certificat n'est pas vérifié : ne jamais remettre d'identifiants (401, certificat client).
            // Le refus laisse arriver la réponse 401, qui prouve que le serveur répond.
            completionHandler(.rejectProtectionSpace, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        self.metrics = metrics
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let status = status, metrics = metrics, completion = completion
        lock.unlock()
        // Une requête arrêtée à l'en-tête finit par « annulée » : ce n'est pas une erreur.
        completion?(status, metrics, status == nil ? error : nil)
    }
}

// MARK: - Moniteur commun

/// Ce que le contrôleur du ping continu demande à un moniteur, quel que soit le protocole.
public protocol PingSampler: AnyObject {
    func start() throws
    func stop()
    func update(_ options: PingOptions)
}

extension PingMonitor: PingSampler {}

/// Ping continu TCP ou HTTP : une sonde à chaque intervalle (plusieurs peuvent être en vol), mesures
/// rendues dans l'ordre des séquences comme le moniteur ICMP. Une sonde qui dépasse le délai est
/// comptée perdue ; sa réponse tardive est ignorée.
public final class PingProbeMonitor: PingSampler, @unchecked Sendable {
    public typealias Probe = @Sendable (_ timeout: TimeInterval) async -> PingProbeResult

    /// Sondes simultanées au plus (intervalle court et serveur lent) ; au-delà, l'envoi est sauté.
    public static let maxInFlight = 6

    public let kind: PingProbeKind
    private let probe: Probe
    private let handler: PingMonitor.Handler
    private let queue: DispatchQueue
    private var options: PingOptions
    private var timer: DispatchSourceTimer?
    private var running = false
    private var nextSequence = 1
    private var nextToEmit = 1
    private var pending: [Int: Date] = [:]
    private var resolved: [Int: PingSample] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]

    public init(kind: PingProbeKind, options: PingOptions, probe: @escaping Probe, handler: @escaping PingMonitor.Handler) {
        self.kind = kind
        self.options = options
        self.probe = probe
        self.handler = handler
        queue = DispatchQueue(label: "netscope.ping.\(kind.label)", qos: .userInitiated)
    }

    deinit { timer?.cancel() }

    /// Moniteur TCP vers une adresse et un port.
    public static func tcp(address: IPv4Address, port: UInt16, options: PingOptions,
                           handler: @escaping PingMonitor.Handler) -> PingProbeMonitor {
        PingProbeMonitor(kind: .tcp(port: port), options: options, probe: { timeout in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: PingTCP.probe(address, port: port, timeout: timeout))
                }
            }
        }, handler: handler)
    }

    /// Moniteur HTTP(S) d'une URL.
    public static func http(url: URL, options: PingOptions, handler: @escaping PingMonitor.Handler) -> PingProbeMonitor {
        PingProbeMonitor(kind: .http(url), options: options, probe: { timeout in
            await PingHTTP.probe(url, timeout: timeout)
        }, handler: handler)
    }

    /// Délai d'une sonde : celui du ping ICMP, au moins 3 s en HTTP (DNS, TCP et TLS à chaque fois).
    public static func timeout(for kind: PingProbeKind, options: PingOptions) -> TimeInterval {
        if case .http = kind { return max(options.effectiveTimeout, 3) }
        return options.effectiveTimeout
    }

    public func start() throws {
        queue.sync {
            guard !running else { return }
            running = true
            scheduleTimer()
        }
    }

    public func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            pending.removeAll()
            resolved.removeAll()
            nextToEmit = nextSequence
        }
    }

    public func update(_ newOptions: PingOptions) {
        queue.async { [self] in
            let changed = newOptions.interval != options.interval
            options = newOptions
            if changed, timer != nil { scheduleTimer() }
        }
    }

    public var isRunning: Bool { queue.sync { running } }

    private func scheduleTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: options.interval, leeway: .milliseconds(max(1, Int(options.interval * 50))))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        expire()
        guard running, pending.count < Self.maxInFlight else { return }
        let sequence = nextSequence
        nextSequence += 1
        pending[sequence] = Date()
        let timeout = Self.timeout(for: kind, options: options)
        let probe = self.probe
        tasks[sequence] = Task { [weak self] in
            let result = await probe(timeout)
            self?.queue.async { self?.finish(sequence, result) }
        }
        queue.asyncAfter(deadline: .now() + timeout + 0.25) { [weak self] in
            guard let self, self.running else { return }
            self.expire()
            self.flush()
        }
    }

    private func finish(_ sequence: Int, _ result: PingProbeResult) {
        tasks[sequence] = nil
        guard let date = pending.removeValue(forKey: sequence) else { return }
        resolved[sequence] = PingSample(sequence: sequence, date: date, rttMs: result.rttMs, failure: result.failure,
                                        statusCode: result.statusCode, detail: result.detail)
        flush()
    }

    private func expire() {
        let limit = Self.timeout(for: kind, options: options) + 0.2
        let now = Date()
        for (sequence, date) in pending where now.timeIntervalSince(date) > limit {
            pending[sequence] = nil
            tasks.removeValue(forKey: sequence)?.cancel()
            resolved[sequence] = PingSample(sequence: sequence, date: date, rttMs: nil, failure: .timeout)
        }
    }

    private func flush() {
        while let sample = resolved.removeValue(forKey: nextToEmit) {
            nextToEmit += 1
            handler(sample)
        }
    }
}
