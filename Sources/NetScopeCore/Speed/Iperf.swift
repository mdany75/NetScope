import Foundation

// Test de débit local avec iperf3 (installé à part : brew install iperf3), lancé avec -J
// (sortie JSON complète à la fin du test). NetScope ne contient pas iperf3.

/// Erreurs du test iperf3.
public enum IperfError: Error, Equatable, LocalizedError {
    case notInstalled
    case invalidHost(String)
    case invalidOptions(String)
    case invalidJSON
    case server(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return IperfLocator.missingMessage
        case .invalidHost(let host): return "Adresse du serveur iperf3 invalide : « \(host) »."
        case .invalidOptions(let reason): return reason
        case .invalidJSON: return "Réponse d’iperf3 illisible."
        case .server(let message): return "iperf3 : \(message)"
        case .cancelled: return "Test iperf3 arrêté."
        }
    }
}

/// Recherche de l'exécutable iperf3 (Homebrew Apple Silicon, puis Intel).
public enum IperfLocator {
    public static let candidatePaths = ["/opt/homebrew/bin/iperf3", "/usr/local/bin/iperf3"]
    public static let missingMessage = "iperf3 non installé (brew install iperf3)"

    public static func find(paths: [String] = candidatePaths, fileManager: FileManager = .default) -> URL? {
        paths.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Réglages d'un test iperf3 (client).
public struct IperfOptions: Hashable, Sendable {
    public enum Transport: String, CaseIterable, Sendable {
        case tcp, udp
        public var label: String { rawValue.uppercased() }
    }

    public enum Direction: String, CaseIterable, Sendable {
        case normal, reverse, bidir

        public var label: String {
            switch self {
            case .normal: return "Normal"
            case .reverse: return "Inverse -R"
            case .bidir: return "Bidirectionnel"
            }
        }
    }

    public static let durationChoices = [5, 10, 15]
    public static let streamChoices = [1, 4, 8]

    public var host: String
    public var port: Int
    public var duration: Int
    public var streams: Int
    public var transport: Transport
    public var direction: Direction
    /// Débit visé en UDP (« 1G »).
    public var udpBandwidth: String

    public init(host: String, port: Int = 5201, duration: Int = 10, streams: Int = 4,
                transport: Transport = .tcp, direction: Direction = .normal, udpBandwidth: String = "1G") {
        self.host = host
        self.port = port
        self.duration = duration
        self.streams = streams
        self.transport = transport
        self.direction = direction
        self.udpBandwidth = udpBandwidth
    }

    /// Arguments de la ligne de commande, après validation (aucun passage par un shell).
    public func arguments() throws -> [String] {
        let host = self.host.trimmingCharacters(in: .whitespaces)
        guard (try? RemoteValidator.validateHost(host)) != nil else { throw IperfError.invalidHost(host) }
        guard (1...65_535).contains(port) else { throw IperfError.invalidOptions("Port invalide : \(port).") }
        guard (1...3_600).contains(duration) else { throw IperfError.invalidOptions("Durée invalide : \(duration) s.") }
        guard (1...128).contains(streams) else { throw IperfError.invalidOptions("Nombre de flux invalide : \(streams).") }
        guard udpBandwidth.range(of: "^[0-9]+[KMG]?$", options: .regularExpression) != nil else {
            throw IperfError.invalidOptions("Débit UDP invalide : \(udpBandwidth).")
        }
        var arguments = ["-c", host, "-p", String(port), "-t", String(duration), "-P", String(streams)]
        if transport == .udp { arguments += ["-u", "-b", udpBandwidth] }
        switch direction {
        case .normal: break
        case .reverse: arguments.append("-R")
        case .bidir: arguments.append("--bidir")
        }
        arguments.append("-J")
        return arguments
    }

    /// Commande affichée à l'utilisateur (« iperf3 -c 10.10.0.20 -p 5201 -t 10 -P 4 -J »).
    public var commandLine: String {
        let arguments = (try? self.arguments()) ?? ["-c", host.isEmpty ? "<serveur>" : host]
        return (["iperf3"] + arguments.map(RemoteShell.quote)).joined(separator: " ")
    }
}

/// Un intervalle (une seconde, par défaut) du test.
public struct IperfInterval: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var bytes: Int64
    public var bitsPerSecond: Double
    /// TCP, côté émetteur.
    public var retransmits: Int?
    /// UDP.
    public var packets: Int?
    public var lostPackets: Int?
    /// Sens inverse d'un test bidirectionnel.
    public var reverseBytes: Int64?
    public var reverseBitsPerSecond: Double?

    public init(start: Double, end: Double, bytes: Int64, bitsPerSecond: Double, retransmits: Int? = nil,
                packets: Int? = nil, lostPackets: Int? = nil, reverseBytes: Int64? = nil,
                reverseBitsPerSecond: Double? = nil) {
        self.start = start
        self.end = end
        self.bytes = bytes
        self.bitsPerSecond = bitsPerSecond
        self.retransmits = retransmits
        self.packets = packets
        self.lostPackets = lostPackets
        self.reverseBytes = reverseBytes
        self.reverseBitsPerSecond = reverseBitsPerSecond
    }

    public var megabitsPerSecond: Double { bitsPerSecond / 1_000_000 }
    public var reverseMegabitsPerSecond: Double? { reverseBitsPerSecond.map { $0 / 1_000_000 } }
}

/// Résultat complet d'un test iperf3.
public struct IperfResult: Hashable, Sendable {
    public var version: String?
    public var protocolName: String
    public var streams: Int
    public var duration: Double
    public var localHost: String?
    public var remoteHost: String?
    public var remotePort: Int?
    public var reverse: Bool
    public var bidirectional: Bool
    public var intervals: [IperfInterval]
    public var sentBytes: Int64?
    public var sentBitsPerSecond: Double?
    public var receivedBytes: Int64?
    public var receivedBitsPerSecond: Double?
    public var retransmits: Int?
    /// UDP.
    public var jitterMs: Double?
    public var lostPackets: Int?
    public var packets: Int?
    public var lostPercent: Double?
    /// Sens inverse d'un test bidirectionnel (débit reçu par ce Mac).
    public var reverseReceivedBitsPerSecond: Double?

    public init(version: String? = nil, protocolName: String = "TCP", streams: Int = 1, duration: Double = 0,
                localHost: String? = nil, remoteHost: String? = nil, remotePort: Int? = nil,
                reverse: Bool = false, bidirectional: Bool = false, intervals: [IperfInterval] = [],
                sentBytes: Int64? = nil, sentBitsPerSecond: Double? = nil, receivedBytes: Int64? = nil,
                receivedBitsPerSecond: Double? = nil, retransmits: Int? = nil, jitterMs: Double? = nil,
                lostPackets: Int? = nil, packets: Int? = nil, lostPercent: Double? = nil,
                reverseReceivedBitsPerSecond: Double? = nil) {
        self.version = version
        self.protocolName = protocolName
        self.streams = streams
        self.duration = duration
        self.localHost = localHost
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.reverse = reverse
        self.bidirectional = bidirectional
        self.intervals = intervals
        self.sentBytes = sentBytes
        self.sentBitsPerSecond = sentBitsPerSecond
        self.receivedBytes = receivedBytes
        self.receivedBitsPerSecond = receivedBitsPerSecond
        self.retransmits = retransmits
        self.jitterMs = jitterMs
        self.lostPackets = lostPackets
        self.packets = packets
        self.lostPercent = lostPercent
        self.reverseReceivedBitsPerSecond = reverseReceivedBitsPerSecond
    }

    /// Débit retenu (Mb/s) : celui reçu par l'autre bout, ou envoyé à défaut.
    public var megabitsPerSecond: Double {
        (receivedBitsPerSecond ?? sentBitsPerSecond ?? 0) / 1_000_000
    }

    public var reverseMegabitsPerSecond: Double? { reverseReceivedBitsPerSecond.map { $0 / 1_000_000 } }

    public var isUDP: Bool { protocolName.uppercased() == "UDP" }
}

/// Lecture de la sortie JSON d'iperf3 -J.
public enum IperfParser {
    public static func parse(_ data: Data) throws -> IperfResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IperfError.invalidJSON
        }
        if let error = root["error"] as? String, !error.isEmpty {
            throw IperfError.server(error)
        }
        let start = root["start"] as? [String: Any] ?? [:]
        let testStart = start["test_start"] as? [String: Any] ?? [:]
        let connected = (start["connected"] as? [[String: Any]])?.first ?? [:]
        let end = root["end"] as? [String: Any] ?? [:]

        let protocolName = (testStart["protocol"] as? String) ?? "TCP"
        var result = IperfResult(
            version: start["version"] as? String,
            protocolName: protocolName,
            streams: int(testStart["num_streams"]) ?? 1,
            duration: double(testStart["duration"]) ?? 0,
            localHost: connected["local_host"] as? String,
            remoteHost: connected["remote_host"] as? String,
            remotePort: int(connected["remote_port"]),
            reverse: (int(testStart["reverse"]) ?? 0) != 0,
            bidirectional: (int(testStart["bidir"]) ?? 0) != 0,
            intervals: [])

        for interval in root["intervals"] as? [[String: Any]] ?? [] {
            guard let sum = interval["sum"] as? [String: Any] else { continue }
            if (sum["omitted"] as? Bool) == true { continue }
            let reverse = interval["sum_bidir_reverse"] as? [String: Any]
            result.intervals.append(IperfInterval(
                start: double(sum["start"]) ?? 0,
                end: double(sum["end"]) ?? 0,
                bytes: int64(sum["bytes"]) ?? 0,
                bitsPerSecond: double(sum["bits_per_second"]) ?? 0,
                retransmits: int(sum["retransmits"]),
                packets: int(sum["packets"]),
                lostPackets: int(sum["lost_packets"]),
                reverseBytes: reverse.flatMap { int64($0["bytes"]) },
                reverseBitsPerSecond: reverse.flatMap { double($0["bits_per_second"]) }))
        }

        let sent = end["sum_sent"] as? [String: Any]
        let received = end["sum_received"] as? [String: Any]
        let udpSum = end["sum"] as? [String: Any]
        result.sentBytes = sent.flatMap { int64($0["bytes"]) } ?? udpSum.flatMap { int64($0["bytes"]) }
        result.sentBitsPerSecond = sent.flatMap { double($0["bits_per_second"]) } ?? udpSum.flatMap { double($0["bits_per_second"]) }
        result.receivedBytes = received.flatMap { int64($0["bytes"]) }
        result.receivedBitsPerSecond = received.flatMap { double($0["bits_per_second"]) }
        result.retransmits = sent.flatMap { int($0["retransmits"]) }
        if result.isUDP, let udpSum {
            result.jitterMs = double(udpSum["jitter_ms"])
            result.lostPackets = int(udpSum["lost_packets"])
            result.packets = int(udpSum["packets"])
            result.lostPercent = double(udpSum["lost_percent"])
            // En UDP, le débit reçu est celui de « sum » (celui de sum_received est parfois absent).
            if result.receivedBitsPerSecond == nil { result.receivedBitsPerSecond = double(udpSum["bits_per_second"]) }
        }
        if let reverse = end["sum_received_bidir_reverse"] as? [String: Any] {
            result.reverseReceivedBitsPerSecond = double(reverse["bits_per_second"])
        }
        if result.duration == 0, let last = result.intervals.last { result.duration = last.end }
        return result
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

/// Lance iperf3 en client et lit son résultat JSON. L'annulation de la tâche arrête le processus.
public enum IperfRunner {
    public static func run(_ options: IperfOptions, executable: URL? = IperfLocator.find()) async throws -> IperfResult {
        guard let executable else { throw IperfError.notInstalled }
        let arguments = try options.arguments()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Lecture sur un fil à part : la sortie JSON peut dépasser la mémoire tampon du tube.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: IperfError.server(error.localizedDescription))
                        return
                    }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: data)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        if Task.isCancelled { throw IperfError.cancelled }
        return try IperfParser.parse(data)
    }
}
