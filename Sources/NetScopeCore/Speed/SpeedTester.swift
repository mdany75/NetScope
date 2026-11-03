import Foundation

// Test de débit Internet par les points d'accès publics de Cloudflare :
//   GET  https://speed.cloudflare.com/__down?bytes=N   (téléchargement, et latence avec N = 0)
//   POST https://speed.cloudflare.com/__up             (téléversement)
//   GET  https://speed.cloudflare.com/meta             (IP publique, fournisseur, nœud)
// Chaque flux a sa propre URLSession, donc sa propre connexion TCP.

/// Réglages d'un test Internet.
public struct SpeedTestConfig: Sendable, Hashable {
    public static let cloudflare = URL(string: "https://speed.cloudflare.com")!
    public static let streamChoices = [1, 4, 8]

    public var streams: Int
    public var downloadDuration: TimeInterval
    public var uploadDuration: TimeInterval
    public var latencyProbes: Int
    public var baseURL: URL
    public var downloadChunkBytes: Int
    public var uploadChunkBytes: Int
    /// Intervalle de publication de la progression.
    public var sampleInterval: TimeInterval

    public init(streams: Int = 4, downloadDuration: TimeInterval = 10, uploadDuration: TimeInterval = 10,
                latencyProbes: Int = 10, baseURL: URL = SpeedTestConfig.cloudflare,
                downloadChunkBytes: Int = 25_000_000, uploadChunkBytes: Int = 10_000_000,
                sampleInterval: TimeInterval = 0.2) {
        self.streams = max(1, min(streams, 16))
        self.downloadDuration = downloadDuration
        self.uploadDuration = uploadDuration
        self.latencyProbes = max(1, latencyProbes)
        self.baseURL = baseURL
        self.downloadChunkBytes = downloadChunkBytes
        self.uploadChunkBytes = uploadChunkBytes
        self.sampleInterval = sampleInterval
    }

    public func downloadURL(bytes: Int) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("__down"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "bytes", value: String(max(0, bytes)))]
        return components.url!
    }

    public var uploadURL: URL { baseURL.appendingPathComponent("__up") }
    public var metaURL: URL { baseURL.appendingPathComponent("meta") }

    /// Durée totale approximative (s), pour la barre de progression.
    public var estimatedDuration: TimeInterval { Double(latencyProbes) * 0.15 + downloadDuration + uploadDuration }
}

/// Phase d'un test Internet.
public enum SpeedPhase: String, Codable, CaseIterable, Sendable {
    case latency, download, upload

    public var label: String {
        switch self {
        case .latency: return "Latence"
        case .download: return "Téléchargement"
        case .upload: return "Téléversement"
        }
    }

    /// Part de la progression globale occupée par la phase.
    var fractionRange: ClosedRange<Double> {
        switch self {
        case .latency: return 0...0.1
        case .download: return 0.1...0.55
        case .upload: return 0.55...1
        }
    }
}

/// Progression publiée pendant le test.
public struct SpeedLiveUpdate: Sendable, Hashable {
    public var phase: SpeedPhase
    /// Secondes écoulées dans la phase.
    public var elapsed: Double
    /// Débit instantané (Mb/s) pendant le téléchargement et le téléversement.
    public var mbps: Double?
    /// Dernière latence mesurée (ms) pendant la phase de latence.
    public var latencyMs: Double?
    /// Progression globale 0…1.
    public var fraction: Double

    public init(phase: SpeedPhase, elapsed: Double, mbps: Double? = nil, latencyMs: Double? = nil, fraction: Double) {
        self.phase = phase
        self.elapsed = elapsed
        self.mbps = mbps
        self.latencyMs = latencyMs
        self.fraction = fraction
    }
}

/// Serveur de test et connexion vue de l'extérieur (réponse de /meta).
public struct SpeedServerInfo: Codable, Hashable, Sendable {
    public var colo: String?
    public var city: String?
    public var country: String?
    public var clientIP: String?
    public var asn: Int?
    public var asOrganization: String?

    public init(colo: String? = nil, city: String? = nil, country: String? = nil, clientIP: String? = nil,
                asn: Int? = nil, asOrganization: String? = nil) {
        self.colo = colo
        self.city = city
        self.country = country
        self.clientIP = clientIP
        self.asn = asn
        self.asOrganization = asOrganization
    }

    /// Lit la réponse JSON de https://speed.cloudflare.com/meta.
    public init?(metaJSON data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
            return nil
        }
        self.init(colo: text("colo"), city: text("city"), country: text("country"), clientIP: text("clientIp"),
                  asn: text("asn").flatMap { Int($0) }, asOrganization: text("asOrganization"))
        if colo == nil && clientIP == nil && asn == nil { return nil }
    }

    /// Lit les en-têtes « cf-meta-* » et « cf-ray » d'une réponse de __down.
    public init?(headers: [String: String]) {
        var lower: [String: String] = [:]
        for (key, value) in headers { lower[key.lowercased()] = value }
        var colo = lower["cf-meta-colo"]
        if colo == nil, let ray = lower["cf-ray"], let dash = ray.lastIndex(of: "-") {
            colo = String(ray[ray.index(after: dash)...])
        }
        self.init(colo: colo, city: lower["cf-meta-city"], country: lower["cf-meta-country"],
                  clientIP: lower["cf-meta-ip"], asn: lower["cf-meta-asn"].flatMap { Int($0) })
        if self.colo == nil && clientIP == nil { return nil }
    }

    /// « Cloudflare · YUL · Montreal »
    public var label: String {
        var parts = ["Cloudflare"]
        if let colo { parts.append(colo) }
        if let city { parts.append(city) }
        return parts.joined(separator: " · ")
    }

    /// « AS577 · Bell Canada »
    public var providerLabel: String? {
        switch (asn, asOrganization) {
        case let (asn?, org?): return "AS\(asn) · \(org)"
        case let (asn?, nil): return "AS\(asn)"
        case let (nil, org?): return org
        default: return nil
        }
    }

    /// Durée de traitement côté serveur (ms) dans « Server-Timing: cfRequestDuration;dur=12.3 ».
    public static func serverTimingDuration(_ header: String?) -> Double? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("dur=") { return Double(trimmed.dropFirst(4)) }
        }
        return nil
    }
}

/// Résultat d'un test Internet.
public struct SpeedTestSummary: Codable, Hashable, Sendable {
    public var downMbps: Double
    public var upMbps: Double
    public var idleLatencyMs: Double
    public var loadedLatencyMs: Double?
    public var jitterMs: Double?
    public var probesSent: Int
    public var probesLost: Int
    public var streams: Int
    public var server: SpeedServerInfo?
    public var downloadBytes: Int64
    public var uploadBytes: Int64

    public init(downMbps: Double, upMbps: Double, idleLatencyMs: Double, loadedLatencyMs: Double? = nil,
                jitterMs: Double? = nil, probesSent: Int = 0, probesLost: Int = 0, streams: Int = 1,
                server: SpeedServerInfo? = nil, downloadBytes: Int64 = 0, uploadBytes: Int64 = 0) {
        self.downMbps = downMbps
        self.upMbps = upMbps
        self.idleLatencyMs = idleLatencyMs
        self.loadedLatencyMs = loadedLatencyMs
        self.jitterMs = jitterMs
        self.probesSent = probesSent
        self.probesLost = probesLost
        self.streams = streams
        self.server = server
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }

    /// Sondes de latence sans réponse, en %.
    public var lossPercent: Double? {
        guard probesSent > 0 else { return nil }
        return Double(probesLost) / Double(probesSent) * 100
    }
}

/// Événements publiés par `SpeedTester.run()`.
public enum SpeedEvent: Sendable {
    case update(SpeedLiveUpdate)
    case server(SpeedServerInfo)
    case latencyMeasured(idleMs: Double, jitterMs: Double?)
    case downloadMeasured(Double)
    case uploadMeasured(Double)
    case finished(SpeedTestSummary)
    case failed(String)
}

/// Test de débit Internet. `run()` publie la progression ; annuler la tâche qui lit le flux
/// (ou cesser de le lire) arrête le test et ferme toutes les connexions.
public final class SpeedTester: @unchecked Sendable {
    public let config: SpeedTestConfig

    public init(config: SpeedTestConfig = SpeedTestConfig()) {
        self.config = config
    }

    public func run() -> AsyncStream<SpeedEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.perform(continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return configuration
    }

    private func perform(_ out: AsyncStream<SpeedEvent>.Continuation) async {
        let session = URLSession(configuration: SpeedTester.sessionConfiguration())
        defer { session.invalidateAndCancel() }

        // Serveur et IP publique (facultatif).
        var server: SpeedServerInfo?
        if let (data, _) = try? await session.data(from: config.metaURL), let info = SpeedServerInfo(metaJSON: data) {
            server = info
            out.yield(.server(info))
        }
        if Task.isCancelled { return }

        // Latence au repos : médiane de N requêtes de 0 octet, après une requête d'échauffement.
        let latencyStart = Date()
        _ = try? await probe(session)
        var rtts: [Double] = []
        var lost = 0
        for index in 0..<config.latencyProbes {
            if Task.isCancelled { return }
            let rtt = try? await probe(session)
            if let rtt { rtts.append(rtt) } else { lost += 1 }
            let fraction = Double(index + 1) / Double(config.latencyProbes)
            out.yield(.update(SpeedLiveUpdate(phase: .latency, elapsed: Date().timeIntervalSince(latencyStart),
                                              latencyMs: rtt, fraction: SpeedTester.global(.latency, fraction))))
        }
        guard let idle = SpeedMath.median(rtts) else {
            out.yield(.failed("Serveur de test injoignable : vérifiez la connexion Internet."))
            return
        }
        let jitter = SpeedMath.jitter(rtts)
        out.yield(.latencyMeasured(idleMs: idle, jitterMs: jitter))

        // Téléchargement puis téléversement, avec sondes de latence en charge.
        let down = await transfer(.download, duration: config.downloadDuration, session: session, out: out)
        if Task.isCancelled { return }
        guard down.bytes > 0 else {
            out.yield(.failed("Aucune donnée reçue pendant le téléchargement."))
            return
        }
        let downMbps = SpeedMath.steadyRate(down.samples)
        out.yield(.downloadMeasured(downMbps))

        let up = await transfer(.upload, duration: config.uploadDuration, session: session, out: out)
        if Task.isCancelled { return }
        guard up.bytes > 0 else {
            out.yield(.failed("Aucune donnée envoyée pendant le téléversement."))
            return
        }
        let upMbps = SpeedMath.steadyRate(up.samples)
        out.yield(.uploadMeasured(upMbps))

        let loaded = down.loadedRTTs + up.loadedRTTs
        out.yield(.finished(SpeedTestSummary(
            downMbps: downMbps, upMbps: upMbps, idleLatencyMs: idle,
            loadedLatencyMs: SpeedMath.median(loaded), jitterMs: jitter,
            probesSent: config.latencyProbes + down.probesSent + up.probesSent,
            probesLost: lost + down.probesLost + up.probesLost,
            streams: config.streams, server: server, downloadBytes: down.bytes, uploadBytes: up.bytes)))
    }

    static func global(_ phase: SpeedPhase, _ fraction: Double) -> Double {
        let range = phase.fractionRange
        return range.lowerBound + (range.upperBound - range.lowerBound) * min(max(fraction, 0), 1)
    }

    /// Requête de 0 octet ; renvoie l'aller-retour en ms, moins le temps de traitement du serveur.
    private func probe(_ session: URLSession) async throws -> Double {
        var request = URLRequest(url: config.downloadURL(bytes: 0))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        let start = DispatchTime.now().uptimeNanoseconds
        let (_, response) = try await session.data(for: request)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let serverMs = SpeedServerInfo.serverTimingDuration(http.value(forHTTPHeaderField: "Server-Timing")) ?? 0
        return max(0.1, elapsed - serverMs)
    }

    private struct TransferOutcome {
        var samples: [SpeedSample]
        var bytes: Int64
        var loadedRTTs: [Double]
        var probesSent: Int
        var probesLost: Int
    }

    private func transfer(_ phase: SpeedPhase, duration: TimeInterval, session: URLSession,
                          out: AsyncStream<SpeedEvent>.Continuation) async -> TransferOutcome {
        let engine = SpeedTransferEngine(direction: phase == .upload ? .upload : .download, config: config)
        let start = DispatchTime.now().uptimeNanoseconds
        engine.start()

        let probes = Task { () -> ([Double], Int, Int) in
            var values: [Double] = []
            var sent = 0
            var lost = 0
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while !Task.isCancelled {
                sent += 1
                if let rtt = try? await self.probe(session) { values.append(rtt) } else if !Task.isCancelled { lost += 1 }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return (values, sent, lost)
        }

        var samples = [SpeedSample(time: 0, totalBytes: 0)]
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(config.sampleInterval * 1_000_000_000))
            let time = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            samples.append(SpeedSample(time: time, totalBytes: engine.totalBytes))
            let rate = SpeedMath.instantRate(samples, window: 1.0)
            out.yield(.update(SpeedLiveUpdate(phase: phase, elapsed: time, mbps: rate,
                                              fraction: SpeedTester.global(phase, time / duration))))
            if time >= duration { break }
        }
        engine.stop()
        probes.cancel()
        let (values, sent, lost) = await probes.value
        return TransferOutcome(samples: samples, bytes: samples.last?.totalBytes ?? 0,
                               loadedRTTs: values, probesSent: sent, probesLost: lost)
    }
}

/// Flux parallèles de téléchargement ou de téléversement ; compte les octets au fil de l'eau.
final class SpeedTransferEngine: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Direction { case download, upload }

    private let direction: Direction
    private let config: SpeedTestConfig
    private let payload: Data
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var stopped = false
    private var sessions: [URLSession] = []

    init(direction: Direction, config: SpeedTestConfig) {
        self.direction = direction
        self.config = config
        self.payload = direction == .upload ? Data(count: config.uploadChunkBytes) : Data()
        super.init()
    }

    var totalBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func start() {
        // Une session par flux : chaque flux ouvre sa propre connexion TCP.
        for _ in 0..<config.streams {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: SpeedTester.sessionConfiguration(), delegate: self, delegateQueue: queue)
            sessions.append(session)
            launch(on: session)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        for session in sessions { session.invalidateAndCancel() }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func add(_ count: Int64) {
        lock.lock()
        if !stopped { bytes += count }
        lock.unlock()
    }

    private func launch(on session: URLSession) {
        // Le verrou évite de créer une tâche dans une session que stop() vient d'invalider.
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        switch direction {
        case .download:
            var request = URLRequest(url: config.downloadURL(bytes: config.downloadChunkBytes))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            session.dataTask(with: request).resume()
        case .upload:
            var request = URLRequest(url: config.uploadURL)
            request.httpMethod = "POST"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            session.uploadTask(with: request, from: payload).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if direction == .download { add(Int64(data.count)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if direction == .upload { add(bytesSent) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isStopped else { return }
        if error == nil {
            launch(on: session)
        } else {
            // Erreur passagère : on réessaie un peu plus tard, sans boucle serrée.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.launch(on: session)
            }
        }
    }
}
