import Foundation
import Network
import Security

/// Certificat présenté par un serveur HTTPS.
public struct HTTPCertificateInfo: Sendable, Hashable {
    public var subject: String
    /// Vrai si le trousseau de macOS approuve la chaîne.
    public var isTrusted: Bool
    public var isSelfSigned: Bool
    public var trustError: String?
    public var validUntil: Date?
}

/// Résultat d'une sonde HTTP(S).
public struct HTTPProbeResult: Sendable {
    public var url: URL
    public var finalURL: URL
    public var statusCode: Int
    public var server: String?
    public var title: String?
    public var contentType: String?
    /// Redirections suivies (« 301 → https://… »).
    public var redirects: [String]
    public var durationMs: Double
    public var certificate: HTTPCertificateInfo?
    public var bodyBytes: Int

    public var statusText: String {
        "\(statusCode) " + HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }
}

/// Sonde HTTP(S) d'un appareil : code, serveur, titre de page, certificat. Les certificats
/// auto-signés sont acceptés (appareils réseau) mais signalés dans le résultat.
public enum HTTPProbe {
    /// Taille maximale lue (les caméras peuvent diffuser un flux sans fin).
    public static let maxBodyBytes = 128 * 1024

    public static func probe(_ url: URL, timeout: TimeInterval = 8) async throws -> HTTPProbeResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ToolError.invalidInput("Adresse web invalide : \(url.absoluteString)")
        }
        do {
            return try await probeWithURLSession(url, timeout: timeout)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection && scheme == "http" {
            // Hors paquet .app (pas d'exception ATS) : requête HTTP brute.
            return try await probeRaw(url, timeout: timeout)
        }
    }

    static func probeWithURLSession(_ url: URL, timeout: TimeInterval) async throws -> HTTPProbeResult {
        let start = Date()
        let delegate = HTTPProbeDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "NetScope"]
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request)
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= maxBodyBytes { break }
        }
        guard let http = response as? HTTPURLResponse else { throw ToolError.processFailed("Réponse non HTTP.") }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        return HTTPProbeResult(url: url, finalURL: http.url ?? url, statusCode: http.statusCode,
                               server: http.value(forHTTPHeaderField: "Server"),
                               title: extractTitle(from: decode(body, contentType: contentType)),
                               contentType: contentType, redirects: delegate.redirects.value,
                               durationMs: Date().timeIntervalSince(start) * 1000,
                               certificate: delegate.certificate.value, bodyBytes: body.count)
    }

    /// Requête HTTP/1.0 brute par NWConnection (sans redirection).
    static func probeRaw(_ url: URL, timeout: TimeInterval) async throws -> HTTPProbeResult {
        guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw ToolError.invalidInput("Adresse web invalide : \(url.absoluteString)")
        }
        let start = Date()
        let path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")
        let request = "GET \(path) HTTP/1.0\r\nHost: \(host)\r\nUser-Agent: NetScope\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "netscope.httpprobe")
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once = ToolOnce()
            let buffer = ToolBox(Data())
            func finish(_ result: Result<Data, Error>) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(with: result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, complete, error in
                    if let chunk { buffer.mutate { $0.append(chunk) } }
                    if complete || error != nil || buffer.value.count >= maxBodyBytes {
                        buffer.value.isEmpty ? finish(.failure(error ?? ToolError.socket("réponse vide"))) : finish(.success(buffer.value))
                    } else {
                        receive()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in receive() })
                case .failed(let error):
                    finish(.failure(ToolError.socket(error.localizedDescription)))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                buffer.value.isEmpty ? finish(.failure(ToolError.timeout(timeout))) : finish(.success(buffer.value))
            }
        }
        let parsed = try parseRawResponse(data)
        return HTTPProbeResult(url: url, finalURL: url, statusCode: parsed.status, server: parsed.headers["server"],
                               title: extractTitle(from: decode(parsed.body, contentType: parsed.headers["content-type"])),
                               contentType: parsed.headers["content-type"],
                               redirects: parsed.headers["location"].map { ["\(parsed.status) → \($0)"] } ?? [],
                               durationMs: Date().timeIntervalSince(start) * 1000, certificate: nil,
                               bodyBytes: parsed.body.count)
    }

    /// Ligne d'état, en-têtes (clés en minuscules) et corps d'une réponse HTTP brute.
    public static func parseRawResponse(_ data: Data) throws -> (status: Int, headers: [String: String], body: Data) {
        let separator = Data("\r\n\r\n".utf8)
        let headerEnd = data.range(of: separator)
        let headerData = headerEnd.map { data[data.startIndex..<$0.lowerBound] } ?? data[...]
        let body = headerEnd.map { Data(data[$0.upperBound...]) } ?? Data()
        let lines = String(decoding: headerData, as: UTF8.self).components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/") else {
            throw ToolError.processFailed("Réponse non HTTP.")
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw ToolError.processFailed("Ligne d’état HTTP illisible.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if headers[key] == nil { headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        }
        return (status, headers, body)
    }

    static func decode(_ body: Data, contentType: String?) -> String {
        if let type = contentType?.lowercased(), type.contains("charset=iso-8859-1") || type.contains("charset=windows-1252") {
            return String(data: body, encoding: .isoLatin1) ?? ""
        }
        return String(decoding: body, as: UTF8.self)
    }

    /// Contenu de <title>, espaces réduits et entités courantes décodées.
    public static func extractTitle(from html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let close = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let end = html.range(of: "</title", options: .caseInsensitive, range: close.upperBound..<html.endIndex) else {
            return nil
        }
        var title = String(html[close.upperBound..<end.lowerBound])
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "’", "&apos;": "’",
                        "&nbsp;": " ", "&eacute;": "é", "&egrave;": "è", "&agrave;": "à", "&ccedil;": "ç"]
        for (entity, character) in entities { title = title.replacingOccurrences(of: entity, with: character) }
        title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return title.isEmpty ? nil : String(title.prefix(200))
    }
}

/// Délégué : accepte les certificats non approuvés (en les signalant) et note les redirections.
final class HTTPProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let certificate = ToolBox<HTTPCertificateInfo?>(nil)
    let redirects = ToolBox<[String]>([])

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        var info = HTTPCertificateInfo(subject: "", isTrusted: trusted, isSelfSigned: false,
                                       trustError: error.map { CFErrorCopyDescription($0) as String }, validUntil: nil)
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            info.subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
            if let subject = SecCertificateCopyNormalizedSubjectSequence(leaf),
               let issuer = SecCertificateCopyNormalizedIssuerSequence(leaf) {
                info.isSelfSigned = (subject as Data) == (issuer as Data)
            }
            if #available(macOS 15.0, *) {
                info.validUntil = SecCertificateCopyNotValidAfterDate(leaf) as Date?
            }
        }
        certificate.mutate { $0 = info }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects.mutate { $0.append("\(response.statusCode) → \(request.url?.absoluteString ?? "?")") }
        completionHandler(redirects.value.count > 5 ? nil : request)
    }
}
