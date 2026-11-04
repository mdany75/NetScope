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

    public init(timeout: TimeInterval = 6) {
        self.timeout = timeout
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
        // 2. Connexion TCP et poignée de main TLS
        let port = UInt16(url.port ?? 443)
        switch await SvcReachability.tlsHandshake(host: host, port: port, timeout: timeout) {
        case .success(let ms):
            result.tlsMs = ms
        case .failure(let failure, let detail):
            result.failure = failure
            result.detail = detail
            return result
        }
        // 3. Réponse HTTPS (premiers en-têtes, sans suivre les redirections)
        switch await SvcReachability.httpsHead(url, timeout: timeout + 2) {
        case .success(let ms, let status):
            result.httpMs = ms
            result.httpStatus = status
            if status == 407 {
                result.failure = .proxy
                result.detail = "HTTP 407"
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
        case success(Double, Int)
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

    /// Durée jusqu'à la connexion TLS établie (TCP compris).
    static func tlsHandshake(host: String, port: UInt16, timeout: TimeInterval) async -> Step {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failure(.connect, "port invalide") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tls)
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

    /// Premiers en-têtes HTTPS (GET sans suivre les redirections) : durée et code.
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
            let (_, response) = try await session.bytes(for: URLRequest(url: url))
            let elapsed = Date().timeIntervalSince(start) * 1000
            guard let http = response as? HTTPURLResponse else { return .failure(.http, "réponse non HTTP") }
            return .success(elapsed, http.statusCode)
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

/// Délégué qui refuse les redirections : la première réponse suffit pour mesurer.
final class SvcNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
