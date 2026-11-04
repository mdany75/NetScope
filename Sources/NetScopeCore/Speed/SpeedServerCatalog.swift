import Foundation

/// Chargement de la liste des serveurs (accès réseau, sur demande seulement) : Cloudflare,
/// M-Lab (serveurs les plus proches), LibreSpeed (liste publique), Ookla (si son CLI est
/// installé et que l'utilisateur l'a demandé), puis mesure de la latence de chacun.
public enum SpeedServerCatalog {
    public struct Result: Sendable {
        public var servers: [SpeedServer]
        /// Sources en échec, avec la raison (« LibreSpeed : délai dépassé »).
        public var failures: [String]
        public var date: Date

        public init(servers: [SpeedServer], failures: [String] = [], date: Date = Date()) {
            self.servers = servers
            self.failures = failures
            self.date = date
        }
    }

    /// Charge les listes et mesure la latence (connexions TCP, 8 serveurs à la fois).
    /// `ooklaPath` : CLI d'Ookla vérifié, ou nil pour ne pas le lancer.
    public static func load(ooklaPath: String? = nil, extra: [SpeedServer] = [],
                            progress: (@Sendable (String) -> Void)? = nil) async -> Result {
        let session = URLSession(configuration: SpeedTester.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        var servers: [SpeedServer] = [.cloudflare]
        var failures: [String] = []

        progress?("Serveurs M-Lab les plus proches…")
        do {
            let (data, _) = try await session.data(from: MLabLocate.nearestURL)
            var seen = Set<String>()
            for target in try MLabLocate.parse(data) where seen.insert(target.server.id).inserted {
                servers.append(target.server)
            }
        } catch {
            failures.append("M-Lab : \(error.localizedDescription)")
        }
        if Task.isCancelled { return Result(servers: servers, failures: failures) }

        progress?("Liste publique LibreSpeed…")
        do {
            let (data, _) = try await session.data(from: LibreSpeedParser.serverListURL)
            servers += try LibreSpeedParser.servers(data)
        } catch {
            failures.append("LibreSpeed : \(error.localizedDescription)")
        }

        if let ooklaPath {
            progress?("Serveurs Ookla…")
            do {
                servers += try OoklaParser.servers(try await runCLI(ooklaPath, arguments: OoklaLocator.serverListArguments))
            } catch {
                failures.append("Ookla : \(error.localizedDescription)")
            }
        }
        servers += extra.filter { item in !servers.contains { $0.id == item.id } }
        if Task.isCancelled { return Result(servers: servers, failures: failures) }

        progress?("Mesure de la latence de \(servers.count) serveurs…")
        let measured = await measureLatency(servers)
        return Result(servers: measured, failures: failures)
    }

    /// Mesure la latence (TCP) de chaque serveur qui a un hôte, 8 à la fois.
    public static func measureLatency(_ servers: [SpeedServer], width: Int = 8) async -> [SpeedServer] {
        var result = servers
        await withTaskGroup(of: (Int, Double?).self) { group in
            var next = 0
            func addNext() {
                while next < servers.count {
                    let index = next
                    next += 1
                    guard let host = servers[index].host, let port = UInt16(exactly: servers[index].port ?? 443) else { continue }
                    group.addTask { (index, await SpeedLatencyProbe.median(host: host, port: port, count: 3, timeout: 1.5)) }
                    return
                }
            }
            for _ in 0..<width { addNext() }
            while let (index, latency) = await group.next() {
                result[index].latencyMs = latency
                if Task.isCancelled { group.cancelAll(); continue }
                addNext()
            }
        }
        return result
    }

    /// Lance le CLI (sans shell) et renvoie sa sortie standard.
    static func runCLI(_ path: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: data)
            }
        }
    }
}
