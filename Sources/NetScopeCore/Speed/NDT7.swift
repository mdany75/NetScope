import Foundation

// M-Lab (Measurement Lab, mesures ouvertes) par le protocole NDT7 :
//   1. GET https://locate.measurementlab.net/v2/nearest/ndt/ndt7[?site=yul04]
//      → serveurs les plus proches, avec des URL wss:// signées (jeton d'accès de courte durée) ;
//   2. téléchargement : WebSocket « net.measurementlab.ndt.v7 » sur …/ndt/v7/download, le serveur
//      envoie des messages binaires pendant ~10 s et des mesures JSON (TCPInfo, AppInfo) ;
//   3. téléversement : même WebSocket sur …/ndt/v7/upload, le client envoie des messages binaires
//      de taille croissante pendant 10 s, le serveur renvoie ses mesures.
// Un seul flux TCP par sens, comme le prévoit NDT7.

/// Un serveur M-Lab renvoyé par le service de localisation.
public struct NDT7Target: Hashable, Sendable {
    public var machine: String
    public var site: String?
    public var city: String?
    public var country: String?
    public var downloadURL: URL
    public var uploadURL: URL

    public init(machine: String, site: String?, city: String?, country: String?, downloadURL: URL, uploadURL: URL) {
        self.machine = machine
        self.site = site
        self.city = city
        self.country = country
        self.downloadURL = downloadURL
        self.uploadURL = uploadURL
    }

    /// Serveur pour la liste (sans les URL signées, qui expirent vite).
    public var server: SpeedServer {
        // Code pays (« CA ») en nom français (« Canada »), comme les autres sources.
        let countryName = country.flatMap { Locale(identifier: "fr_CA").localizedString(forRegionCode: $0) } ?? country
        return SpeedServer(id: "mlab:" + (site ?? machine), source: .mlab, name: city ?? machine, city: city, country: countryName,
                    sponsor: "Measurement Lab", host: downloadURL.host, port: downloadURL.port ?? 443, site: site)
    }
}

/// Service de localisation de M-Lab (API locate v2), sans réseau pour la lecture.
public enum MLabLocate {
    public static let nearestURL = URL(string: "https://locate.measurementlab.net/v2/nearest/ndt/ndt7")!
    public static let subprotocol = "net.measurementlab.ndt.v7"

    /// URL de localisation, limitée à un site (« yul04 ») pour un favori.
    public static func url(site: String? = nil) -> URL {
        guard let site, isValidSite(site), var components = URLComponents(url: nearestURL, resolvingAgainstBaseURL: false) else {
            return nearestURL
        }
        components.queryItems = [URLQueryItem(name: "site", value: site)]
        return components.url ?? nearestURL
    }

    /// Site M-Lab : trois lettres (code d'aéroport) et deux chiffres ou plus.
    public static func isValidSite(_ site: String) -> Bool {
        site.range(of: "^[a-z]{3}[0-9]{2,3}$", options: .regularExpression) != nil
    }

    /// « mlab1-yul04.mlab-oti.measurement-lab.org » → « yul04 ».
    public static func site(fromMachine machine: String) -> String? {
        guard let range = machine.range(of: "mlab[0-9]+-([a-z]{3}[0-9]{2,3})", options: .regularExpression) else { return nil }
        let match = machine[range]
        guard let dash = match.firstIndex(of: "-") else { return nil }
        return String(match[match.index(after: dash)...])
    }

    /// Réponse JSON {"results":[{"machine","location":{"city","country"},"urls":{"wss:///ndt/v7/download": …}}]}.
    public static func parse(_ data: Data) throws -> [NDT7Target] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpeedParseError.invalidFormat("localisation M-Lab")
        }
        guard let results = object["results"] as? [[String: Any]] else {
            if let error = object["error"] as? [String: Any], let title = error["title"] as? String {
                throw SpeedParseError.invalidFormat("M-Lab : \(title)")
            }
            throw SpeedParseError.invalidFormat("localisation M-Lab")
        }
        let targets: [NDT7Target] = results.compactMap { result in
            guard let machine = result["machine"] as? String, let urls = result["urls"] as? [String: String],
                  let down = urls["wss:///ndt/v7/download"].flatMap(URL.init(string:)),
                  let up = urls["wss:///ndt/v7/upload"].flatMap(URL.init(string:)),
                  down.scheme == "wss", up.scheme == "wss",
                  let downHost = down.host, let upHost = up.host,
                  !SpeedHostPolicy.isLocal(downHost), !SpeedHostPolicy.isLocal(upHost) else { return nil }
            let location = result["location"] as? [String: Any]
            return NDT7Target(machine: machine, site: site(fromMachine: machine), city: location?["city"] as? String,
                              country: location?["country"] as? String, downloadURL: down, uploadURL: up)
        }
        guard !targets.isEmpty else { throw SpeedParseError.empty("M-Lab") }
        return targets
    }
}

/// Mesure JSON envoyée par un serveur NDT7 (temps en microsecondes).
public struct NDT7Measurement: Hashable, Sendable {
    public var test: String?
    public var origin: String?
    public var appElapsedMicroseconds: Int64?
    public var appBytes: Int64?
    public var minRTTMicroseconds: Int64?
    public var rttMicroseconds: Int64?
    public var rttVarMicroseconds: Int64?
    public var bytesReceived: Int64?
    public var tcpElapsedMicroseconds: Int64?
    /// Adresse du client vue par le serveur (« 203.0.113.24 »).
    public var clientIP: String?

    public init(test: String? = nil, origin: String? = nil, appElapsedMicroseconds: Int64? = nil, appBytes: Int64? = nil,
                minRTTMicroseconds: Int64? = nil, rttMicroseconds: Int64? = nil, rttVarMicroseconds: Int64? = nil,
                bytesReceived: Int64? = nil, tcpElapsedMicroseconds: Int64? = nil, clientIP: String? = nil) {
        self.test = test
        self.origin = origin
        self.appElapsedMicroseconds = appElapsedMicroseconds
        self.appBytes = appBytes
        self.minRTTMicroseconds = minRTTMicroseconds
        self.rttMicroseconds = rttMicroseconds
        self.rttVarMicroseconds = rttVarMicroseconds
        self.bytesReceived = bytesReceived
        self.tcpElapsedMicroseconds = tcpElapsedMicroseconds
        self.clientIP = clientIP
    }

    public static func parse(_ text: String) -> NDT7Measurement? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        let app = object["AppInfo"] as? [String: Any]
        let tcp = object["TCPInfo"] as? [String: Any]
        let connection = object["ConnectionInfo"] as? [String: Any]
        let measurement = NDT7Measurement(
            test: object["Test"] as? String, origin: object["Origin"] as? String,
            appElapsedMicroseconds: IperfParser.int64(app?["ElapsedTime"]), appBytes: IperfParser.int64(app?["NumBytes"]),
            minRTTMicroseconds: IperfParser.int64(tcp?["MinRTT"]), rttMicroseconds: IperfParser.int64(tcp?["RTT"]),
            rttVarMicroseconds: IperfParser.int64(tcp?["RTTVar"]), bytesReceived: IperfParser.int64(tcp?["BytesReceived"]),
            tcpElapsedMicroseconds: IperfParser.int64(tcp?["ElapsedTime"]),
            clientIP: (connection?["Client"] as? String).flatMap(hostPart))
        if app == nil && tcp == nil && connection == nil { return nil }
        return measurement
    }

    /// « 203.0.113.24:54321 » → « 203.0.113.24 » ; « [2001:db8::1]:54321 » → « 2001:db8::1 ».
    static func hostPart(_ endpoint: String) -> String? {
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
        }
        guard let colon = endpoint.lastIndex(of: ":"), endpoint.filter({ $0 == ":" }).count == 1 else { return endpoint }
        return String(endpoint[..<colon])
    }

    /// Débit côté application (Mb/s), d'après AppInfo.
    public var appMegabitsPerSecond: Double? {
        guard let bytes = appBytes, let elapsed = appElapsedMicroseconds, elapsed > 0 else { return nil }
        return SpeedMath.megabitsPerSecond(bytes: bytes, seconds: Double(elapsed) / 1_000_000)
    }

    public var rttMs: Double? { rttMicroseconds.map { Double($0) / 1000 } }
    public var minRTTMs: Double? { minRTTMicroseconds.map { Double($0) / 1000 } }
}

/// Règle de NDT7 pour le téléversement : la taille des messages double dès que le total envoyé
/// atteint 16 fois la taille courante, de 8 Kio à 1 Mio.
public enum NDT7Upload {
    public static let initialMessageSize = 1 << 13
    public static let maxMessageSize = 1 << 20

    public static func nextMessageSize(current: Int, totalSent: Int64) -> Int {
        guard current < maxMessageSize, totalSent >= Int64(current) * 16 else { return current }
        return min(current * 2, maxMessageSize)
    }
}

/// Test M-Lab NDT7.
public final class NDT7Tester: SpeedTestEngine, @unchecked Sendable {
    /// Site imposé (favori) ; nil : le plus proche.
    public let site: String?
    public let duration: TimeInterval
    public let latencyProbes: Int
    public let sampleInterval: TimeInterval

    public init(site: String? = nil, duration: TimeInterval = 10, latencyProbes: Int = 10, sampleInterval: TimeInterval = 0.2) {
        self.site = site
        self.duration = duration
        self.latencyProbes = max(1, latencyProbes)
        self.sampleInterval = sampleInterval
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

    private func perform(_ out: AsyncStream<SpeedEvent>.Continuation) async {
        let session = URLSession(configuration: SpeedTester.sessionConfiguration())
        defer { session.invalidateAndCancel() }

        // 1. Serveur le plus proche (ou le site favori), URL signées fraîches.
        let target: NDT7Target
        do {
            let (data, response) = try await session.data(from: MLabLocate.url(site: site))
            if let http = response as? HTTPURLResponse, http.statusCode == 204 || http.statusCode >= 400 {
                out.yield(.failed("M-Lab n’a proposé aucun serveur (code \(http.statusCode)). Réessayez dans un instant."))
                return
            }
            guard let first = try MLabLocate.parse(data).first else {
                out.yield(.failed("M-Lab n’a proposé aucun serveur. Réessayez dans un instant."))
                return
            }
            target = first
        } catch {
            out.yield(.failed("Service de localisation M-Lab injoignable : \(error.localizedDescription)"))
            return
        }
        var info = SpeedServerInfo(city: target.city, country: target.country, source: "M-Lab",
                                   serverName: target.server.historyLabel.replacingOccurrences(of: "M-Lab · ", with: ""),
                                   serverID: target.server.id)
        out.yield(.server(info))
        if Task.isCancelled { return }

        // 2. Latence au repos : connexions TCP vers le serveur (le protocole NDT7 n'a pas de « ping »).
        let host = target.downloadURL.host ?? target.machine
        let port = UInt16(target.downloadURL.port ?? 443)
        let start = Date()
        _ = await SpeedLatencyProbe.tcpConnect(host: host, port: port)
        var rtts: [Double] = []
        var lost = 0
        for index in 0..<latencyProbes {
            if Task.isCancelled { return }
            let rtt = await SpeedLatencyProbe.tcpConnect(host: host, port: port)
            if let rtt { rtts.append(rtt) } else { lost += 1 }
            out.yield(.update(SpeedLiveUpdate(phase: .latency, elapsed: Date().timeIntervalSince(start), latencyMs: rtt,
                                              fraction: SpeedTester.global(.latency, Double(index + 1) / Double(latencyProbes)))))
        }
        guard let idle = SpeedMath.median(rtts) else {
            out.yield(.failed("Serveur M-Lab injoignable : vérifiez la connexion Internet."))
            return
        }
        let jitter = SpeedMath.jitter(rtts)
        out.yield(.latencyMeasured(idleMs: idle, jitterMs: jitter))

        // 3. Téléchargement puis téléversement.
        let down = await transfer(.download, url: target.downloadURL, session: session, out: out)
        if Task.isCancelled { return }
        guard down.bytes > 0 else {
            out.yield(.failed(down.error ?? "Aucune donnée reçue du serveur M-Lab."))
            return
        }
        let downMbps = SpeedMath.steadyRate(down.samples)
        out.yield(.downloadMeasured(downMbps))
        if let ip = down.measurements.compactMap(\.clientIP).first {
            info.clientIP = ip
            out.yield(.server(info))
        }

        let up = await transfer(.upload, url: target.uploadURL, session: session, out: out)
        if Task.isCancelled { return }
        guard up.bytes > 0 else {
            out.yield(.failed(up.error ?? "Aucune donnée envoyée au serveur M-Lab."))
            return
        }
        // Montée : mesure du serveur (octets réellement reçus) si elle existe, sinon côté client.
        let serverUp = up.measurements.last { $0.origin == "server" && $0.appMegabitsPerSecond != nil }?.appMegabitsPerSecond
        let upMbps = serverUp ?? SpeedMath.steadyRate(up.samples)
        out.yield(.uploadMeasured(upMbps))

        let loaded = down.measurements.compactMap(\.rttMs) + up.measurements.compactMap(\.rttMs)
        out.yield(.finished(SpeedTestSummary(
            downMbps: downMbps, upMbps: upMbps, idleLatencyMs: idle, loadedLatencyMs: SpeedMath.median(loaded),
            jitterMs: jitter, probesSent: latencyProbes, probesLost: lost, streams: 1, server: info,
            downloadBytes: down.bytes, uploadBytes: up.bytes)))
    }

    private struct Outcome {
        var samples: [SpeedSample]
        var bytes: Int64
        var measurements: [NDT7Measurement]
        var error: String?
    }

    private func transfer(_ phase: SpeedPhase, url: URL, session: URLSession,
                          out: AsyncStream<SpeedEvent>.Continuation) async -> Outcome {
        let socket = session.webSocketTask(with: url, protocols: [MLabLocate.subprotocol])
        socket.maximumMessageSize = 1 << 25
        socket.resume()
        let state = NDT7State()
        let begin = DispatchTime.now().uptimeNanoseconds

        // Lecture : données (téléchargement) et mesures JSON du serveur.
        let receiver = Task {
            while !Task.isCancelled {
                do {
                    switch try await socket.receive() {
                    case .data(let data):
                        if phase == .download { state.add(Int64(data.count)) }
                    case .string(let text):
                        if phase == .download { state.add(Int64(text.utf8.count)) }
                        if let measurement = NDT7Measurement.parse(text) { state.append(measurement) }
                    @unknown default:
                        break
                    }
                } catch {
                    state.finish(error: state.total == 0 ? error.localizedDescription : nil)
                    return
                }
            }
        }

        // Envoi (téléversement) : messages binaires de taille croissante pendant `duration`.
        let sender: Task<Void, Never>? = phase == .upload ? Task {
            var size = NDT7Upload.initialMessageSize
            var payload = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
            while !Task.isCancelled {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000_000
                if elapsed >= self.duration { break }
                do {
                    try await socket.send(.data(payload))
                } catch {
                    state.finish(error: state.total == 0 ? error.localizedDescription : nil)
                    return
                }
                state.add(Int64(size))
                let next = NDT7Upload.nextMessageSize(current: size, totalSent: state.total)
                if next != size {
                    size = next
                    payload = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
                }
            }
        } : nil

        var samples = [SpeedSample(time: 0, totalBytes: 0)]
        // Le serveur clôt le téléchargement après ~10 s ; borne de sûreté à 15 s.
        let limit = phase == .download ? duration + 5 : duration
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(sampleInterval * 1_000_000_000))
            let time = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000_000
            samples.append(SpeedSample(time: time, totalBytes: state.total))
            let rate = SpeedMath.instantRate(samples, window: 1.0)
            out.yield(.update(SpeedLiveUpdate(phase: phase, elapsed: time, mbps: rate,
                                              fraction: SpeedTester.global(phase, time / duration))))
            if time >= limit || state.isFinished { break }
        }
        sender?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        receiver.cancel()
        return Outcome(samples: samples, bytes: state.total, measurements: state.measurements, error: state.error)
    }
}

/// Compteurs partagés d'un transfert NDT7.
private final class NDT7State: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var list: [NDT7Measurement] = []
    private var finished = false
    private var failure: String?

    var total: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
    var measurements: [NDT7Measurement] { lock.lock(); defer { lock.unlock() }; return list }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }

    func add(_ count: Int64) { lock.lock(); bytes += count; lock.unlock() }
    func append(_ measurement: NDT7Measurement) { lock.lock(); list.append(measurement); lock.unlock() }
    func finish(error: String?) {
        lock.lock()
        finished = true
        if failure == nil { failure = error }
        lock.unlock()
    }
}

/// Latence par connexion TCP (poignée de main), utilisée pour classer les serveurs.
public enum SpeedLatencyProbe {
    /// Temps d'établissement d'une connexion TCP (ms), nil si l'hôte ne répond pas.
    public static func tcpConnect(host: String, port: UInt16, timeout: TimeInterval = 2) async -> Double? {
        let result = await PortScanner.probe(host: host, port: port,
                                             options: PortScanOptions(timeout: timeout, concurrency: 1, grabBanners: false))
        return result.state == .open ? result.rttMs : nil
    }

    /// Médiane de `count` connexions, après une première qui résout le nom.
    public static func median(host: String, port: UInt16, count: Int = 3, timeout: TimeInterval = 1.5) async -> Double? {
        guard await tcpConnect(host: host, port: port, timeout: timeout) != nil else { return nil }
        var values: [Double] = []
        for _ in 0..<max(1, count) {
            if Task.isCancelled { break }
            if let rtt = await tcpConnect(host: host, port: port, timeout: timeout) { values.append(rtt) }
        }
        return SpeedMath.median(values)
    }
}
