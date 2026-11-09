import Foundation
import Network

public struct HTTPRedirectHop: Sendable, Hashable {
    public var statusCode: Int
    public var target: String

    public init(statusCode: Int, target: String) {
        self.statusCode = statusCode
        self.target = target
    }
}

/// Durées en millisecondes ; nil pour une étape qui n'a pas eu lieu (adresse IP sans DNS, http sans TLS).
public struct HTTPTimings: Sendable, Hashable {
    public var dns: Double?
    public var connect: Double?
    public var tls: Double?
    /// Depuis le début de la dernière requête, comme le « time_starttransfer » de curl.
    public var firstByte: Double?
    public var total: Double
    /// Connexion directe vers un nom : NWConnection ne sépare pas la résolution de la connexion TCP.
    public var connectIncludesDNS: Bool

    public init(dns: Double? = nil, connect: Double? = nil, tls: Double? = nil, firstByte: Double? = nil, total: Double, connectIncludesDNS: Bool = false) {
        self.dns = dns
        self.connect = connect
        self.tls = tls
        self.firstByte = firstByte
        self.total = total
        self.connectIncludesDNS = connectIncludesDNS
    }
}

public struct HTTPResponseResult: Sendable {
    public var statusCode: Int
    public var statusText: String
    public var version: String
    public var headers: [HTTPHeader]
    /// Début du corps, au plus `HTTPTester.maxPreviewBytes`.
    public var bodyPreview: Data
    public var bodySize: Int
    /// Faux si la lecture s'est arrêtée avant la fin sans que le serveur ait annoncé la taille.
    public var isSizeExact: Bool
    public var redirects: [HTTPRedirectHop]
    /// Adresse d'une redirection non suivie parce que le corps aurait quitté l'origine.
    public var unfollowedRedirect: String?
    public var timings: HTTPTimings
    public var remoteAddress: String?
    public var finalURL: URL
    public let contentType: String?
    public let bodyText: String
    public let formattedBody: String?
    public let isBinary: Bool

    public init(statusCode: Int, statusText: String? = nil, version: String, headers: [HTTPHeader], bodyPreview: Data, bodySize: Int,
                isSizeExact: Bool = true, redirects: [HTTPRedirectHop] = [], unfollowedRedirect: String? = nil, timings: HTTPTimings, remoteAddress: String? = nil, finalURL: URL) {
        self.statusCode = statusCode
        self.statusText = statusText ?? HTTPTester.reasonPhrase(statusCode)
        self.version = version
        self.headers = headers
        self.bodyPreview = bodyPreview
        self.bodySize = bodySize
        self.isSizeExact = isSizeExact
        self.redirects = redirects
        self.unfollowedRedirect = unfollowedRedirect
        self.timings = timings
        self.remoteAddress = remoteAddress
        self.finalURL = finalURL
        contentType = headers.first { $0.name.lowercased() == "content-type" }?.value
        isBinary = HTTPBodyFormat.isBinary(bodyPreview, contentType: contentType)
        bodyText = isBinary ? "" : HTTPProbe.decode(bodyPreview, contentType: contentType)
        formattedBody = isBinary ? nil : HTTPBodyFormat.prettyJSON(bodyPreview)
    }

    public var isTruncated: Bool { !isSizeExact || bodySize > bodyPreview.count }
}

/// Envoi d'une requête décrite par `HTTPRequestSpec`, sur clic seulement.
///
/// Normalement par URLSession, pour ses minutages. L'app n'a que l'exception ATS « réseau local »
/// (Info.plist) : un http:// vers un nom public est refusé par macOS, et part alors par une
/// connexion TCP directe. Rien n'est gardé entre deux envois : session éphémère, sans cookies ni cache.
public enum HTTPTester {
    public static let maxPreviewBytes = 2 * 1024 * 1024
    /// Sans taille annoncée, on continue de compter jusque-là (un flux de caméra ne finit jamais).
    static let maxCountedBytes = 64 * 1024 * 1024
    static let maxRedirects = 10

    public static func send(_ spec: HTTPRequestSpec) async throws -> HTTPResponseResult {
        let url = try spec.validatedURL()
        let request = PreparedRequest(spec: spec, url: url)
        do {
            return try await sendWithSession(request, spec: spec)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection && url.scheme?.lowercased() == "http" {
            // Refus dès le premier saut : rien n'est parti, pas de double envoi d'un POST.
            return try await sendRaw(request, spec: spec)
        } catch let error as URLError {
            throw toolError(error, url: url, timeout: spec.timeout)
        }
    }

    // MARK: Préparation

    struct PreparedRequest: Sendable {
        var url: URL
        var method: String
        var headers: [HTTPHeader]
        var body: Data?

        init(spec: HTTPRequestSpec, url: URL) {
            self.url = url
            method = spec.method.rawValue
            headers = spec.headers
            body = spec.body.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            func has(_ name: String) -> Bool { headers.contains { $0.name.lowercased() == name } }
            // L'identifiant de l'URL devient un en-tête : même envoi par les deux chemins, et il
            // tombe avec les autres en-têtes sensibles si une redirection change d'hôte.
            if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let user = parts.user {
                if !has("authorization") {
                    let token = Data("\(user):\(parts.password ?? "")".utf8).base64EncodedString()
                    headers.append(HTTPHeader(name: "Authorization", value: "Basic \(token)"))
                }
                parts.user = nil
                parts.password = nil
                self.url = parts.url ?? url
            }
            // URLSession mettrait sinon « application/x-www-form-urlencoded ».
            if let body, !has("content-type"), HTTPBodyFormat.prettyJSON(body) != nil {
                headers.append(HTTPHeader(name: "Content-Type", value: "application/json"))
            }
        }
    }

    // MARK: URLSession

    static func sendWithSession(_ request: PreparedRequest, spec: HTTPRequestSpec) async throws -> HTTPResponseResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = spec.timeout
        configuration.timeoutIntervalForResource = spec.timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "NetScope"]
        let delegate = HTTPSessionDelegate(request: request, spec: spec)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for header in request.headers { urlRequest.addValue(header.value, forHTTPHeaderField: header.name) }
        let task = session.dataTask(with: urlRequest)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func measured(_ metrics: URLSessionTaskMetrics?, fallbackTotal: Double) -> (timings: HTTPTimings, remote: String?, version: String) {
        let last = metrics?.transactionMetrics.last { $0.resourceFetchType == .networkLoad }
        func ms(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return max(0, end.timeIntervalSince(start)) * 1000
        }
        let timings = HTTPTimings(dns: ms(last?.domainLookupStartDate, last?.domainLookupEndDate),
                                  connect: ms(last?.connectStartDate, last?.secureConnectionStartDate ?? last?.connectEndDate),
                                  tls: ms(last?.secureConnectionStartDate, last?.secureConnectionEndDate),
                                  firstByte: ms(last?.fetchStartDate, last?.responseStartDate),
                                  total: metrics.map { $0.taskInterval.duration * 1000 } ?? fallbackTotal)
        var remote = last?.remoteAddress
        if let address = remote, let port = last?.remotePort { remote = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }
        return (timings, remote, version(last?.networkProtocolName))
    }

    static func version(_ protocolName: String?) -> String {
        switch protocolName?.lowercased() {
        case "h2": return "HTTP/2"
        case "h3": return "HTTP/3"
        case let name?: return name.uppercased()
        case nil: return "HTTP"
        }
    }

    static func toolError(_ error: URLError, url: URL, timeout: TimeInterval) -> Error {
        let host = url.host ?? url.absoluteString
        switch error.code {
        case .cancelled: return CancellationError()
        case .timedOut: return ToolError.timeout(timeout)
        case .cannotFindHost, .dnsLookupFailed: return ToolError.processFailed("Nom d’hôte introuvable\u{00A0}: \(host).")
        case .cannotConnectToHost: return ToolError.processFailed("Connexion refusée ou impossible vers \(host).")
        case .notConnectedToInternet: return ToolError.processFailed("Ce Mac n’a pas de connexion réseau.")
        case .networkConnectionLost: return ToolError.processFailed("Connexion coupée pendant l’échange avec \(host).")
        case .appTransportSecurityRequiresSecureConnection:
            return ToolError.processFailed("macOS refuse cette connexion (App Transport Security)\u{00A0}: \(host) impose ou propose un chiffrement jugé trop faible, ou une redirection mène vers http:// sur un nom public.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .secureConnectionFailed:
            return ToolError.processFailed("Certificat ou chiffrement refusé pour \(host). Pour un appareil au certificat auto-signé, cocher «\u{00A0}Accepter un certificat non vérifié\u{00A0}».")
        default: return ToolError.socket(error.localizedDescription)
        }
    }

    /// HEAD, 204 et 304 peuvent annoncer un Content-Length sans jamais envoyer de corps.
    static func hasBody(method: String, status: Int) -> Bool {
        method != "HEAD" && status != 204 && status != 304
    }

    public static func reasonPhrase(_ code: Int) -> String {
        let phrases = [
            100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
            301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
            400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
            408: "Request Timeout", 409: "Conflict", 410: "Gone", 411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type",
            418: "I’m a Teapot", 422: "Unprocessable Content", 429: "Too Many Requests",
            500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
        ]
        return phrases[code] ?? HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }

    // MARK: Connexion directe (http:// refusé par ATS)

    /// Mêmes règles de redirection qu'URLSession ; une redirection vers https repart par URLSession.
    static func sendRaw(_ first: PreparedRequest, spec: HTTPRequestSpec) async throws -> HTTPResponseResult {
        var request = first
        var hops: [HTTPRedirectHop] = []
        let start = Date()
        func finished(_ response: HTTPResponseResult) -> HTTPResponseResult {
            var response = response
            response.redirects = hops
            response.timings.total = Date().timeIntervalSince(start) * 1000
            return response
        }
        while true {
            var (result, location) = try await rawExchange(request, timeout: spec.timeout)
            guard spec.followRedirects, hops.count < maxRedirects, let location, let target = URL(string: location, relativeTo: request.url)?.absoluteURL,
                  let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return finished(result)
            }
            let method = HTTPRedirectPolicy.method(request.method, after: result.statusCode)
            let keepsBody = request.body != nil && method == request.method
            guard !keepsBody || HTTPRedirectPolicy.sameOrigin(request.url, target) else {
                result.unfollowedRedirect = target.absoluteString
                return finished(result)
            }
            hops.append(HTTPRedirectHop(statusCode: result.statusCode, target: target.absoluteString))
            request.headers = HTTPRedirectPolicy.headers(request.headers, from: request.url, to: target, keepsBody: keepsBody)
            if !keepsBody { request.body = nil }
            request.method = method
            request.url = target
            if scheme == "https" {
                do {
                    var final = try await sendWithSession(request, spec: spec)
                    final.redirects = hops + final.redirects
                    final.timings.total = Date().timeIntervalSince(start) * 1000
                    return final
                } catch let error as URLError {
                    throw toolError(error, url: target, timeout: spec.timeout)
                }
            }
        }
    }

    private static func rawExchange(_ request: PreparedRequest, timeout: TimeInterval) async throws -> (HTTPResponseResult, location: String?) {
        guard let host = request.url.host, let port = NWEndpoint.Port(rawValue: UInt16(exactly: request.url.port ?? 80) ?? 0) else {
            throw HTTPSpecError.missingHost
        }
        let endpoint = NWEndpoint.Host(host)
        let resolvesName: Bool
        if case .name = endpoint { resolvesName = true } else { resolvesName = false }
        let connection = NWConnection(host: endpoint, port: port, using: .tcp)
        let queue = DispatchQueue(label: "netscope.httptester")
        let start = Date()
        let connected = ToolBox<Double?>(nil)
        let firstByte = ToolBox<Double?>(nil)
        let received = ToolBox(Data())
        let sizeLimit = maxPreviewBytes + 64 * 1024
        let once = ToolOnce()
        return try await withTaskCancellationHandler {
            let reachedEnd: Bool = try await withCheckedThrowingContinuation { continuation in
                func finish(_ result: Result<Bool, Error>) {
                    guard once.claim() else { return }
                    connection.cancel()
                    continuation.resume(with: result)
                }
                func receive() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, complete, error in
                        if let chunk, !chunk.isEmpty {
                            if firstByte.value == nil { firstByte.mutate { $0 = Date().timeIntervalSince(start) * 1000 } }
                            received.mutate { $0.append(chunk) }
                        }
                        if complete || error != nil {
                            received.value.isEmpty ? finish(.failure(ToolError.socket("réponse vide"))) : finish(.success(complete))
                        } else if received.value.count >= sizeLimit {
                            finish(.success(false))
                        } else {
                            receive()
                        }
                    }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connected.mutate { $0 = Date().timeIntervalSince(start) * 1000 }
                        connection.send(content: rawRequest(request, host: host), completion: .contentProcessed { _ in receive() })
                    case .failed(let error), .waiting(let error):
                        finish(.failure(ToolError.socket(error.localizedDescription)))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    received.value.isEmpty ? finish(.failure(ToolError.timeout(timeout))) : finish(.success(false))
                }
            }
            let raw = try HTTPRawResponse(received.value, complete: reachedEnd)
            let hasBody = hasBody(method: request.method, status: raw.status)
            let result = HTTPResponseResult(statusCode: raw.status, statusText: raw.reason.isEmpty ? nil : raw.reason, version: raw.version, headers: raw.headers,
                                            bodyPreview: hasBody ? raw.body.prefix(maxPreviewBytes) : Data(), bodySize: hasBody ? raw.totalSize : 0,
                                            isSizeExact: !hasBody || raw.isSizeExact,
                                            timings: HTTPTimings(connect: connected.value, firstByte: firstByte.value, total: Date().timeIntervalSince(start) * 1000, connectIncludesDNS: resolvesName),
                                            remoteAddress: "\(host):\(port.rawValue)", finalURL: request.url)
            return (result, (300..<400).contains(raw.status) ? raw.headers.first { $0.name.lowercased() == "location" }?.value : nil)
        } onCancel: {
            connection.cancel()
        }
    }

    static func rawRequest(_ request: PreparedRequest, host: String) -> Data {
        // Chemin et requête tels quels : un « %0D%0A » ne doit pas devenir un saut de ligne.
        let encodedPath = request.url.path(percentEncoded: true)
        let target = (encodedPath.isEmpty ? "/" : encodedPath) + (request.url.query(percentEncoded: true).map { "?\($0)" } ?? "")
        func has(_ name: String) -> Bool { request.headers.contains { $0.name.lowercased() == name } }
        var lines = ["\(request.method) \(target) HTTP/1.1"]
        if !has("host") { lines.append("Host: \(host)" + (request.url.port.map { ":\($0)" } ?? "")) }
        if !has("user-agent") { lines.append("User-Agent: NetScope") }
        if !has("accept") { lines.append("Accept: */*") }
        // Sans corps compressé à décoder, et fermeture par le serveur pour marquer la fin.
        lines.append("Accept-Encoding: identity")
        lines.append("Connection: close")
        if let body = request.body, !has("content-length") { lines.append("Content-Length: \(body.count)") }
        lines += request.headers.filter { !["accept-encoding", "connection"].contains($0.name.lowercased()) }.map { "\($0.name): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + (request.body ?? Data())
    }
}

/// Réponse HTTP/1.x reçue en connexion directe.
struct HTTPRawResponse {
    let version: String
    let status: Int
    let reason: String
    let headers: [HTTPHeader]
    let body: Data
    let totalSize: Int
    let isSizeExact: Bool

    init(_ data: Data, complete: Bool) throws {
        let bytes = Data(data)
        guard let headEnd = bytes.range(of: Data("\r\n\r\n".utf8)) else { throw ToolError.processFailed("Réponse non HTTP.") }
        let lines = String(decoding: bytes[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw ToolError.processFailed("Ligne d’état HTTP illisible.")
        }
        version = statusParts[0]
        self.status = status
        reason = statusParts.count > 2 ? statusParts[2] : ""
        let fields: [HTTPHeader] = lines.dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return HTTPHeader(name: String(line[..<colon]), value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        headers = fields
        func header(_ name: String) -> String? { fields.first { $0.name.lowercased() == name }?.value }
        let rawBody = Data(bytes[headEnd.upperBound...])
        let isChunked = header("transfer-encoding")?.lowercased().contains("chunked") == true
        let decoded = isChunked ? Self.decodeChunked(rawBody) : (body: rawBody, complete: complete)
        body = decoded.body
        let announced = header("content-length").flatMap(Int.init)
        totalSize = max(announced ?? 0, decoded.body.count)
        isSizeExact = decoded.complete || announced != nil
    }

    /// Une réponse coupée en plein bloc garde ce qui a été reçu.
    static func decodeChunked(_ data: Data) -> (body: Data, complete: Bool) {
        let bytes = Data(data)
        let lineEnd = Data("\r\n".utf8)
        var body = Data()
        var position = bytes.startIndex
        while let end = bytes.range(of: lineEnd, in: position..<bytes.endIndex) {
            let sizeText = String(decoding: bytes[position..<end.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { return (body, false) }
            if size == 0 { return (body, true) }
            let chunkEnd = bytes.index(end.upperBound, offsetBy: size, limitedBy: bytes.endIndex) ?? bytes.endIndex
            body.append(bytes[end.upperBound..<chunkEnd])
            guard chunkEnd - end.upperBound == size, let next = bytes.index(chunkEnd, offsetBy: 2, limitedBy: bytes.endIndex) else { return (body, false) }
            position = next
        }
        return (body, false)
    }
}

/// Tous les rappels arrivent sur la file série de la session : pas de verrou.
private final class HTTPSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: HTTPTester.PreparedRequest
    private let spec: HTTPRequestSpec
    private let start = Date()
    var continuation: CheckedContinuation<HTTPResponseResult, Error>?
    private var response: HTTPURLResponse?
    private var preview = Data()
    private var received = 0
    private var hops: [HTTPRedirectHop] = []
    private var unfollowedRedirect: String?
    private var metrics: URLSessionTaskMetrics?
    private var stoppedEarly = false

    init(request: HTTPTester.PreparedRequest, spec: HTTPRequestSpec) {
        self.request = request
        self.spec = spec
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        if preview.count < HTTPTester.maxPreviewBytes { preview.append(data.prefix(HTTPTester.maxPreviewBytes - preview.count)) }
        let announced = (response?.expectedContentLength ?? -1) > 0
        if received >= HTTPTester.maxCountedBytes || (announced && received >= HTTPTester.maxPreviewBytes) {
            stoppedEarly = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if spec.acceptsUntrustedCertificate, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard spec.followRedirects, hops.count < HTTPTester.maxRedirects, let target = newRequest.url, let source = response.url else {
            completionHandler(nil)
            return
        }
        var next = newRequest
        let keepsBody = request.body != nil && next.httpMethod == request.method
        guard !keepsBody || HTTPRedirectPolicy.sameOrigin(source, target) else {
            unfollowedRedirect = target.absoluteString
            completionHandler(nil)
            return
        }
        hops.append(HTTPRedirectHop(statusCode: response.statusCode, target: target.absoluteString))
        let headers = (next.allHTTPHeaderFields ?? [:]).map { HTTPHeader(name: $0.key, value: $0.value) }
        let kept = Set(HTTPRedirectPolicy.headers(headers, from: source, to: target, keepsBody: keepsBody))
        for header in headers where !kept.contains(header) { next.setValue(nil, forHTTPHeaderField: header.name) }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        let urlError = error as? URLError
        // Corps coupé après une réponse complète (délai, connexion perdue) : le début reste utile.
        let interrupted = urlError != nil && urlError?.code != .cancelled && response != nil
        if let error, !stoppedEarly, !interrupted {
            if let urlError, urlError.code == .appTransportSecurityRequiresSecureConnection, !hops.isEmpty {
                continuation.resume(throwing: HTTPTester.toolError(urlError, url: request.url, timeout: spec.timeout))
            } else {
                continuation.resume(throwing: error)
            }
            return
        }
        guard let response else {
            continuation.resume(throwing: ToolError.processFailed("Réponse non HTTP."))
            return
        }
        let measured = HTTPTester.measured(metrics, fallbackTotal: Date().timeIntervalSince(start) * 1000)
        let headers = response.allHeaderFields.compactMap { key, value -> HTTPHeader? in
            (key as? String).map { HTTPHeader(name: $0, value: "\(value)") }
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
        let announced = HTTPTester.hasBody(method: task.currentRequest?.httpMethod ?? request.method, status: response.statusCode)
            ? Int(max(response.expectedContentLength, 0)) : 0
        continuation.resume(returning: HTTPResponseResult(statusCode: response.statusCode, version: measured.version, headers: headers,
                                                          bodyPreview: preview, bodySize: max(received, announced),
                                                          isSizeExact: !interrupted && (!stoppedEarly || announced > 0), redirects: hops, unfollowedRedirect: unfollowedRedirect,
                                                          timings: measured.timings, remoteAddress: measured.remote, finalURL: response.url ?? request.url))
    }
}
