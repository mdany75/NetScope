import Darwin
import Foundation
import Network

/// Test d'une adresse clé depuis ce réseau (injectable : les tests utilisent des réponses fixes).
public protocol SvcProbing: Sendable {
    func probe(_ url: String) async -> SvcEndpointResult
}

/// Test réel : résolution DNS, connexion TLS (port 443) et réponse HTTPS, chacun avec sa latence.
public struct SvcNetworkProber: SvcProbing {
    public var timeout: TimeInterval
    /// Adresses de portails de blocage propres à ce réseau (ex. « redirect-portal » d'une FortiGate).
    public var extraBlockPortals: [String]

    public init(timeout: TimeInterval = 6, extraBlockPortals: [String] = []) {
        self.timeout = timeout
        self.extraBlockPortals = extraBlockPortals
    }

    public func probe(_ text: String) async -> SvcEndpointResult {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return SvcEndpointResult(url: text, host: text, failure: .http, detail: "adresse https invalide")
        }
        var result = SvcEndpointResult(url: text, host: host)
        // 1. DNS
        let dnsStart = Date()
        let addresses = await SvcReachability.resolve(host, timeout: timeout)
        result.dnsMs = Date().timeIntervalSince(dnsStart) * 1000
        guard let addresses, !addresses.isEmpty else {
            // Délai dépassé ou nom introuvable : dans les deux cas, c'est la résolution DNS qui échoue.
            result.failure = .dns
            result.detail = addresses == nil ? "DNS sans réponse" : "nom introuvable"
            return result
        }
        result.addresses = addresses
        // Portail de blocage DNS (FortiGuard, Umbrella, 0.0.0.0) : bloqué ici, inutile d'aller plus loin.
        if let block = SvcFilterDetector.dnsBlock(host: host, addresses: addresses, extraPortals: extraBlockPortals) {
            result.failure = .blocked
            result.block = block
            result.detail = block.evidence
            return result
        }
        // 2. Connexion TCP et poignée de main TLS (émetteur du certificat relevé au passage)
        guard let port = UInt16(exactly: url.port ?? 443), port > 0 else {
            result.failure = .http
            result.detail = "port invalide"
            return result
        }
        let (step, issuer) = await SvcReachability.tlsHandshake(host: host, port: port, timeout: timeout)
        result.certificateIssuer = issuer
        switch step {
        case .success(let ms):
            result.tlsMs = ms
        case .failure(let failure, let detail):
            result.failure = failure
            result.detail = detail
            if failure == .tls, let block = SvcFilterDetector.certificateBlock(issuer: issuer, tlsFailed: true) {
                result.failure = .blocked
                result.block = block
                result.detail = block.evidence
            }
            return result
        }
        // 3. Réponse HTTPS (premiers en-têtes et début de la page, sans suivre les redirections)
        switch await SvcReachability.httpsHead(url, timeout: timeout + 2) {
        case .success(let ms, let status, let location, let body):
            result.httpMs = ms
            result.httpStatus = status
            if status == 407 {
                result.failure = .proxy
                result.detail = "HTTP 407"
            } else if let block = SvcFilterDetector.pageBlock(status: status, location: location, body: body) {
                result.failure = .blocked
                result.block = block
                result.detail = block.evidence
            }
        case .failure(let failure, let detail):
            result.failure = failure
            result.detail = detail
        }
        return result
    }
}

/// Briques du test depuis ce réseau et classement des erreurs (purs, testés).
public enum SvcReachability {
    enum Step {
        case success(Double)
        case failure(SvcFailure, String)
    }

    enum HTTPStep {
        /// Durée, code, en-tête Location, début de la page.
        case success(Double, Int, String?, String)
        case failure(SvcFailure, String)
    }

    /// Adresses du nom (IPv4 et IPv6) ; vide : nom introuvable ; nil : délai dépassé.
    static func resolve(_ host: String, timeout: TimeInterval) async -> [String]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            let once = ToolOnce()
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                hints.ai_family = AF_UNSPEC
                var info: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &info)
                var addresses: [String] = []
                if status == 0 {
                    var pointer = info
                    while let entry = pointer {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                                       nil, 0, NI_NUMERICHOST) == 0 {
                            let text = String(cString: buffer)
                            if !addresses.contains(text) { addresses.append(text) }
                        }
                        pointer = entry.pointee.ai_next
                    }
                    freeaddrinfo(info)
                }
                if once.claim() { continuation.resume(returning: addresses) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Durée jusqu'à la connexion TLS établie (TCP compris), et émetteur du certificat présenté.
    /// La vérification reste celle du système (SecTrust) ; le bloc de vérification sert seulement à
    /// lire l'émetteur, pour reconnaître un certificat de remplacement du pare-feu (note 53).
    static func tlsHandshake(host: String, port: UInt16, timeout: TimeInterval) async -> (Step, String?) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return (.failure(.connect, "port invalide"), nil) }
        let issuer = SvcIssuerBox()
        let verifyQueue = DispatchQueue(label: "netscope.services.tls.verification")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            issuer.set(SvcCertificate.issuer(of: trust))
            SecTrustEvaluateAsyncWithError(trust, verifyQueue) { _, trusted, _ in complete(trusted) }
        }, verifyQueue)
        let step = await handshake(host: host, port: nwPort, parameters: NWParameters(tls: tls), timeout: timeout)
        return (step, issuer.value)
    }

    private static func handshake(host: String, port nwPort: NWEndpoint.Port, parameters: NWParameters,
                                  timeout: TimeInterval) async -> Step {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "netscope.services.tls")
        let start = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Step, Never>) in
            let once = ToolOnce()
            @Sendable func finish(_ step: Step) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: step)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(Date().timeIntervalSince(start) * 1000))
                case .failed(let error), .waiting(let error): finish(classify(error))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(.timeout, "connexion TLS sans réponse")) }
        }
    }

    /// Taille lue au début de la page, pour reconnaître une page de blocage.
    static let bodySample = 16 * 1024

    /// Premiers en-têtes HTTPS (GET sans suivre les redirections) : durée, code, redirection et
    /// début de la page (texte seulement, 16 Ko au plus).
    static func httpsHead(_ url: URL, timeout: TimeInterval) async -> HTTPStep {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "NetScope"]
        let session = URLSession(configuration: configuration, delegate: SvcNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let start = Date()
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            let elapsed = Date().timeIntervalSince(start) * 1000
            guard let http = response as? HTTPURLResponse else { return .failure(.http, "réponse non HTTP") }
            let location = http.value(forHTTPHeaderField: "Location")
            var body = Data()
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !(300..<400).contains(http.statusCode), type.isEmpty || type.contains("html") || type.contains("text") {
                do {
                    for try await byte in bytes {
                        body.append(byte)
                        if body.count >= bodySample { break }
                    }
                } catch {
                    // Page coupée en cours de lecture : le début suffit.
                }
            }
            return .success(elapsed, http.statusCode, location, String(decoding: body, as: UTF8.self))
        } catch let error as URLError {
            let failure = classify(urlErrorCode: error.code.rawValue)
            return .failure(failure, error.localizedDescription)
        } catch {
            return .failure(.http, error.localizedDescription)
        }
    }

    static func classify(_ error: NWError) -> Step {
        switch error {
        case .dns: return .failure(.dns, "nom introuvable")
        case .tls(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return .failure(.tls, message ?? "erreur TLS \(status)")
        case .posix(let code):
            let (failure, detail) = classify(posix: code.rawValue)
            return .failure(failure, detail)
        default:
            return .failure(.connect, error.localizedDescription)
        }
    }

    /// Erreur POSIX d'une connexion → étape et explication.
    public static func classify(posix code: Int32) -> (SvcFailure, String) {
        switch code {
        case ECONNREFUSED: return (.connect, "connexion refusée")
        case ETIMEDOUT: return (.timeout, "connexion sans réponse")
        case ENETUNREACH, EHOSTUNREACH: return (.connect, "réseau inaccessible")
        case ECONNRESET: return (.connect, "connexion coupée par le réseau")
        case ENETDOWN: return (.connect, "aucune connexion réseau")
        default: return (.connect, String(cString: strerror(code)))
        }
    }

    /// Code d'erreur URLError (NSURLError…) → étape en échec.
    public static func classify(urlErrorCode code: Int) -> SvcFailure {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dns
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
             NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
            return .connect
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            return .tls
        case NSURLErrorUserAuthenticationRequired: return .proxy
        default: return .http
        }
    }

    // MARK: Proxy du système

    /// Proxy configuré dans Réglages Système (lecture locale), décrit en une phrase ; nil : aucun.
    public static func systemProxy() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        return describeProxy(settings)
    }

    /// Description d'un dictionnaire de réglages de proxy (clés de CFNetwork).
    public static func describeProxy(_ settings: [String: Any]) -> String? {
        func enabled(_ key: String) -> Bool { (settings[key] as? NSNumber)?.boolValue ?? false }
        if enabled("HTTPSEnable"), let host = settings["HTTPSProxy"] as? String, !host.isEmpty {
            let port = (settings["HTTPSPort"] as? NSNumber).map { ":\($0)" } ?? ""
            return "proxy HTTPS \(host)\(port)"
        }
        if enabled("ProxyAutoConfigEnable") {
            let url = (settings["ProxyAutoConfigURLString"] as? String).map { " (\($0))" } ?? ""
            return "configuration automatique du proxy" + url
        }
        if enabled("ProxyAutoDiscoveryEnable") { return "découverte automatique du proxy (WPAD)" }
        if enabled("HTTPEnable"), let host = settings["HTTPProxy"] as? String, !host.isEmpty {
            let port = (settings["HTTPPort"] as? NSNumber).map { ":\($0)" } ?? ""
            return "proxy HTTP \(host)\(port)"
        }
        return nil
    }
}

/// Émetteur du certificat relevé pendant la vérification TLS (écrit sur la file de vérification).
final class SvcIssuerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func set(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = value }
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Délégué qui refuse les redirections : la première réponse suffit pour mesurer.
final class SvcNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
