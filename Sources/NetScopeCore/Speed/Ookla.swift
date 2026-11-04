import Foundation

// Ookla (Speedtest.net) : pas d'API publique libre. NetScope lance l'outil officiel « speedtest »
// (CLI d'Ookla, installé à part : brew install teamookla/speedtest/speedtest) et lit sa sortie
// JSON. L'outil a sa propre licence (usage personnel, non commercial) : NetScope la mentionne et
// ne lance l'outil que sur un clic. Le CLI Python homonyme (speedtest-cli) est écarté.

/// Recherche du CLI d'Ookla.
public enum OoklaLocator {
    public static let candidatePaths = ["/opt/homebrew/bin/speedtest", "/usr/local/bin/speedtest"]
    public static let licenseURL = URL(string: "https://www.speedtest.net/about/eula")!
    public static let downloadURL = URL(string: "https://www.speedtest.net/apps/cli")!
    public static let licenseNote = "Le CLI d’Ookla est régi par la licence d’Ookla (usage personnel, non commercial). Lancer un test Ookla accepte cette licence et sa politique de confidentialité."

    public static func find(paths: [String] = candidatePaths, fileManager: FileManager = .default) -> String? {
        paths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Vrai si la sortie de « speedtest --version » est celle d'Ookla (« Speedtest by Ookla 1.2.0 »).
    public static func isOokla(versionOutput: String) -> Bool {
        versionOutput.range(of: "Speedtest by Ookla", options: .caseInsensitive) != nil
    }

    /// Chemin du CLI d'Ookla, vérifié par « --version » (local, aucun accès réseau).
    public static func findVerified() -> String? {
        guard let path = find() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return isOokla(versionOutput: String(decoding: data, as: UTF8.self)) ? path : nil
    }

    /// Arguments d'un test : sortie JSON ligne par ligne avec progression, licence acceptée par le clic.
    public static func testArguments(serverID: Int?) -> [String] {
        var arguments = ["--format=jsonl", "--progress=yes", "--accept-license", "--accept-gdpr"]
        if let serverID, serverID > 0 { arguments.append("--server-id=\(serverID)") }
        return arguments
    }

    public static let serverListArguments = ["--servers", "--format=json", "--accept-license", "--accept-gdpr"]
}

/// Événement lu dans la sortie JSONL du CLI d'Ookla.
public enum OoklaEvent: Equatable, Sendable {
    case testStart(SpeedServerInfo)
    case ping(latencyMs: Double, jitterMs: Double?, progress: Double)
    case download(mbps: Double, progress: Double)
    case upload(mbps: Double, progress: Double)
    case result(SpeedTestSummary)
    case error(String)
}

/// Lecture de la sortie du CLI d'Ookla, sans réseau (testable).
public enum OoklaParser {
    /// Une ligne JSONL (« type » : testStart, ping, download, upload, result, log).
    public static func event(_ line: String) -> OoklaEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "testStart":
            return .testStart(serverInfo(object))
        case "ping":
            guard let ping = object["ping"] as? [String: Any], let latency = IperfParser.double(ping["latency"]) else { return nil }
            return .ping(latencyMs: latency, jitterMs: IperfParser.double(ping["jitter"]),
                         progress: IperfParser.double(ping["progress"]) ?? 0)
        case "download", "upload":
            guard let phase = object[type] as? [String: Any], let bandwidth = IperfParser.double(phase["bandwidth"]) else { return nil }
            let mbps = bandwidth * 8 / 1_000_000
            let progress = IperfParser.double(phase["progress"]) ?? 0
            return type == "download" ? .download(mbps: mbps, progress: progress) : .upload(mbps: mbps, progress: progress)
        case "result":
            return (try? result(object)).map { .result($0) }
        case "log":
            guard (object["level"] as? String)?.lowercased() == "error", let message = object["message"] as? String else { return nil }
            return .error(message)
        default:
            return nil
        }
    }

    /// Résultat final (« type » : « result »), en JSON compact ou JSONL.
    public static func result(_ data: Data) throws -> SpeedTestSummary {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpeedParseError.invalidFormat("résultat Ookla")
        }
        return try result(object)
    }

    static func result(_ object: [String: Any]) throws -> SpeedTestSummary {
        guard let ping = object["ping"] as? [String: Any], let download = object["download"] as? [String: Any],
              let upload = object["upload"] as? [String: Any],
              let latency = IperfParser.double(ping["latency"]),
              let downBandwidth = IperfParser.double(download["bandwidth"]),
              let upBandwidth = IperfParser.double(upload["bandwidth"]) else {
            throw SpeedParseError.invalidFormat("résultat Ookla")
        }
        // Latence en charge : IQM (moyenne interquartile) pendant le téléchargement, si présente.
        let loadedDown = (download["latency"] as? [String: Any]).flatMap { IperfParser.double($0["iqm"]) }
        let loadedUp = (upload["latency"] as? [String: Any]).flatMap { IperfParser.double($0["iqm"]) }
        let loaded = [loadedDown, loadedUp].compactMap { $0 }
        let loss = IperfParser.double(object["packetLoss"])
        // Perte en % : ramenée à un nombre de paquets sur 1 000 pour le modèle commun (0,1 % près).
        let lost = loss.map { Int(($0 * 10).rounded()) } ?? 0
        return SpeedTestSummary(
            downMbps: downBandwidth * 8 / 1_000_000, upMbps: upBandwidth * 8 / 1_000_000, idleLatencyMs: latency,
            loadedLatencyMs: loaded.isEmpty ? nil : loaded.max(), jitterMs: IperfParser.double(ping["jitter"]),
            probesSent: loss == nil ? 0 : 1000, probesLost: lost, streams: 1, server: serverInfo(object),
            downloadBytes: IperfParser.int64(download["bytes"]) ?? 0, uploadBytes: IperfParser.int64(upload["bytes"]) ?? 0)
    }

    /// Serveur, IP publique et fournisseur d'un objet testStart ou result.
    static func serverInfo(_ object: [String: Any]) -> SpeedServerInfo {
        let server = object["server"] as? [String: Any]
        let interface = object["interface"] as? [String: Any]
        let location = server?["location"] as? String
        let name = server?["name"] as? String
        let id = IperfParser.int64(server?["id"])
        let resultURL = (object["result"] as? [String: Any])?["url"] as? String
        let serverName = [name, location].compactMap { $0 }.joined(separator: " · ")
        return SpeedServerInfo(city: location, country: server?["country"] as? String,
                               clientIP: interface?["externalIp"] as? String, asOrganization: object["isp"] as? String,
                               source: "Ookla", serverName: serverName.isEmpty ? "serveur choisi par Ookla" : serverName,
                               serverID: id.map { "ookla:\($0)" } ?? SpeedServer.ooklaAuto.id, resultURL: resultURL)
    }

    /// Liste des serveurs (« speedtest --servers --format=json »).
    public static func servers(_ data: Data) throws -> [SpeedServer] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["servers"] as? [[String: Any]] else {
            throw SpeedParseError.invalidFormat("liste Ookla")
        }
        return list.compactMap { item in
            guard let id = IperfParser.int64(item["id"]), let name = item["name"] as? String else { return nil }
            let location = item["location"] as? String
            return SpeedServer(id: "ookla:\(id)", source: .ookla, name: [name, location].compactMap { $0 }.joined(separator: " · "),
                               city: location, country: item["country"] as? String, sponsor: name,
                               host: item["host"] as? String, port: IperfParser.int64(item["port"]).map(Int.init),
                               ooklaID: Int(id))
        }
    }
}

/// Lance le CLI d'Ookla et traduit sa sortie en événements communs.
public final class OoklaTester: SpeedTestEngine, @unchecked Sendable {
    public let executable: String
    public let serverID: Int?

    public init(executable: String, serverID: Int?) {
        self.executable = executable
        self.serverID = serverID
    }

    public func run() -> AsyncStream<SpeedEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = OoklaLocator.testArguments(serverID: serverID)
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let reader = OoklaLineReader(continuation: continuation)
            let state = OoklaRunState()
            // Fin : à la fois l'EOF de stdout (lu par un seul handler, dans l'ordre) et la fin du processus.
            let group = DispatchGroup()
            group.enter()
            group.enter()
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    reader.feed(data)
                }
            }
            // stderr vidé en continu : un CLI bavard ne se bloque pas sur un tuyau plein.
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    state.appendError(data)
                }
            }
            process.terminationHandler = { _ in group.leave() }
            group.notify(queue: .global(qos: .utility)) {
                reader.flush()
                if !reader.didFinish, !state.stoppedByUser {
                    let message = state.lastErrorLine
                    if process.terminationReason == .exit {
                        continuation.yield(.failed("Ookla : " + (message ?? "test interrompu (code \(process.terminationStatus))")))
                    } else {
                        continuation.yield(.failed("Ookla : le CLI s’est arrêté (signal \(process.terminationStatus))."))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                state.markStopped()
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                continuation.yield(.failed("Ookla : lancement impossible (\(error.localizedDescription))."))
                continuation.finish()
            }
        }
    }
}

/// État partagé d'un test Ookla : arrêt demandé, fin de stderr (4 Kio au plus).
private final class OoklaRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var errorTail = Data()

    func markStopped() { lock.lock(); stopped = true; lock.unlock() }

    var stoppedByUser: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func appendError(_ data: Data) {
        lock.lock()
        errorTail.append(data)
        if errorTail.count > 4096 { errorTail = errorTail.suffix(4096) }
        lock.unlock()
    }

    /// Dernière ligne non vide de stderr.
    var lastErrorLine: String? {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: errorTail, as: UTF8.self)
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}

/// Découpe la sortie en lignes et publie les événements (progression de 0 à 1 par phase).
private final class OoklaLineReader: @unchecked Sendable {
    private let continuation: AsyncStream<SpeedEvent>.Continuation
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var started = Date()
    private var phaseStart: [SpeedPhase: Date] = [:]
    private var pings: [Double] = []

    init(continuation: AsyncStream<SpeedEvent>.Continuation) {
        self.continuation = continuation
    }

    var didFinish: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty {
            handle(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
    }

    private func elapsed(_ phase: SpeedPhase) -> Double {
        let start = phaseStart[phase] ?? Date()
        if phaseStart[phase] == nil { phaseStart[phase] = start }
        return Date().timeIntervalSince(start)
    }

    private func handle(_ line: String) {
        guard let event = OoklaParser.event(line) else { return }
        switch event {
        case .testStart(let info):
            started = Date()
            continuation.yield(.server(info))
        case .ping(let latency, let jitter, let progress):
            pings.append(latency)
            continuation.yield(.update(SpeedLiveUpdate(phase: .latency, elapsed: elapsed(.latency), latencyMs: latency,
                                                       fraction: SpeedTester.global(.latency, progress))))
            if progress >= 1 { continuation.yield(.latencyMeasured(idleMs: latency, jitterMs: jitter)) }
        case .download(let mbps, let progress):
            continuation.yield(.update(SpeedLiveUpdate(phase: .download, elapsed: elapsed(.download), mbps: mbps,
                                                       fraction: SpeedTester.global(.download, progress))))
            if progress >= 1 { continuation.yield(.downloadMeasured(mbps)) }
        case .upload(let mbps, let progress):
            continuation.yield(.update(SpeedLiveUpdate(phase: .upload, elapsed: elapsed(.upload), mbps: mbps,
                                                       fraction: SpeedTester.global(.upload, progress))))
            if progress >= 1 { continuation.yield(.uploadMeasured(mbps)) }
        case .result(let summary):
            finished = true
            continuation.yield(.finished(summary))
        case .error(let message):
            finished = true
            continuation.yield(.failed("Ookla : \(message)"))
        }
    }
}
