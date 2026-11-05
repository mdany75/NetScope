import Darwin
import Foundation

// Sondes réelles du test MTU : écho ICMP avec le bit DF sur la socket ICMP « datagramme » de
// macOS (aucun droit administrateur), et en dernier recours /sbin/ping -D -s.

public enum PathMTUError: Error, Equatable, LocalizedError {
    case dontFragmentRefused

    public var errorDescription: String? {
        switch self {
        case .dontFragmentRefused: return "Le système refuse le bit DF sur la socket ICMP."
        }
    }
}

/// Lecture des messages ICMP propres au test MTU.
public enum PathMTUICMP {
    /// MTU du saut suivant d'un « fragmentation nécessaire » (ICMP 3, code 4, RFC 1191), en-tête IP
    /// facultatif devant ; nil si ce n'est pas ce message ou si le routeur n'a pas donné de valeur.
    public static func nextHopMTU(_ bytes: [UInt8]) -> Int? {
        var offset = 0
        if bytes.count >= 20, bytes[0] >> 4 == 4 {
            offset = Int(bytes[0] & 0x0F) * 4
        }
        guard bytes.count >= offset + 8, bytes[offset] == PingICMP.destinationUnreachable, bytes[offset + 1] == 4 else { return nil }
        let value = Int(bytes[offset + 6]) << 8 | Int(bytes[offset + 7])
        return value >= 68 ? value : nil
    }
}

/// Sonde réelle : un écho ICMP de la taille demandée, bit DF activé, vers une adresse.
public final class PathMTUProber: @unchecked Sendable {
    public let destination: IPv4Address
    public let timeout: TimeInterval
    private let socket: PingSocket
    private let identifier = PingIdentifiers.next()
    private var sequence: UInt16 = 0
    private let lock = NSLock()

    public init(destination: IPv4Address, timeout: TimeInterval = 1.5) throws {
        self.destination = destination
        self.timeout = timeout
        socket = try PingSocket()
        guard socket.setDontFragment(true) else { throw PathMTUError.dontFragmentRefused }
        // Tampon d'envoi agrandi : par défaut (8 Kio), le système refuse les échos jumbo de plus de
        // 8212 octets avant même l'interface, ce qui fausserait la mesure.
        var size: Int32 = 64 * 1024
        setsockopt(socket.descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Envoie un écho de `size` octets (en-têtes IP et ICMP compris) et attend la réponse (bloquant).
    public func probe(size: Int) -> PathMTUOutcome {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        let seq = sequence
        let packet = PingICMP.echoRequestPacket(identifier: identifier, sequence: seq,
                                                payloadSize: max(0, size - PathMTUSearch.overhead))
        let start = PingClock.nowMs()
        let error = socket.send(packet, to: destination)
        if error == EMSGSIZE { return .tooBig(reportedMTU: nil, from: nil, local: true) }
        if error != 0 { return .failed("Envoi impossible (\(String(cString: strerror(error))))") }
        let deadline = start + timeout * 1000
        while PingClock.nowMs() < deadline {
            guard socket.wait(timeout: (deadline - PingClock.nowMs()) / 1000) else { continue }
            while let received = socket.receive() {
                let now = PingClock.nowMs()
                guard let (message, header) = PingICMP.parse(received.bytes),
                      message.identifier == identifier, message.sequence == seq else { continue }
                let from = header ?? received.from
                switch message {
                case .echoReply:
                    guard from == destination || received.from == destination else { continue }
                    return .reply(rttMs: max(0, now - start))
                case let .unreachable(code, _, _, _):
                    if code == 4 {
                        return .tooBig(reportedMTU: PathMTUICMP.nextHopMTU(received.bytes), from: from, local: false)
                    }
                    return .unreachable(code: code, from: from)
                case .timeExceeded:
                    return .unreachable(code: 255, from: from)
                }
            }
        }
        return .lost
    }

    public func probeAsync(size: Int) async -> PathMTUOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.probe(size: size))
            }
        }
    }
}

// MARK: - Secours : /sbin/ping -D -s

/// Sortie de `/sbin/ping -D -s <données> -c 1` (dernier recours si la socket ICMP est refusée).
public enum PathMTUPingCommand {
    public static let path = "/sbin/ping"

    /// Arguments d'une sonde : bit DF, une seule requête, délai en millisecondes.
    public static func arguments(size: Int, destination: IPv4Address, timeout: TimeInterval) -> [String] {
        ["-D", "-n", "-c", "1", "-W", "\(max(100, Int(timeout * 1000)))",
         "-s", "\(max(0, size - PathMTUSearch.overhead))", destination.description]
    }

    /// Analyse la sortie (sortie standard et erreurs mêlées).
    public static func parse(_ text: String) -> PathMTUOutcome {
        let lower = text.lowercased()
        if lower.contains("message too long") {
            return .tooBig(reportedMTU: nil, from: nil, local: true)
        }
        if let line = text.split(whereSeparator: \.isNewline).first(where: { $0.lowercased().contains("frag needed") }) {
            // « 56 bytes from 10.0.0.1: frag needed and DF set (MTU 1480) »
            let mtu = number(after: "MTU", in: String(line))
            let from = String(line).components(separatedBy: " from ").dropFirst().first
                .flatMap { IPv4Address(String($0.prefix { $0 != ":" && $0 != " " })) }
            return .tooBig(reportedMTU: mtu.flatMap { $0 >= 68 ? $0 : nil }, from: from, local: false)
        }
        if let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("time=") }) {
            let rtt = String(line).components(separatedBy: "time=").last
                .flatMap { Double($0.prefix { $0.isNumber || $0 == "." }) }
            return .reply(rttMs: rtt ?? 0)
        }
        if lower.contains("destination host unreachable") || lower.contains("host unreachable") {
            return .unreachable(code: 1, from: nil)
        }
        if lower.contains("destination net unreachable") {
            return .unreachable(code: 0, from: nil)
        }
        if lower.contains("cannot resolve") || lower.contains("unknown host") {
            return .failed("Nom introuvable")
        }
        return .lost
    }

    private static func number(after key: String, in line: String) -> Int? {
        guard let range = line.range(of: key) else { return nil }
        return Int(line[range.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber })
    }

    /// Une sonde par /sbin/ping.
    public static func probe(size: Int, destination: IPv4Address, timeout: TimeInterval) async -> PathMTUOutcome {
        do {
            let output = try await SystemCommand.run(path, arguments(size: size, destination: destination, timeout: timeout),
                                                     timeout: timeout + 3)
            return parse(output)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - MTU de l'interface

public enum PathMTULocal {
    /// MTU d'une interface de ce Mac (« en0 »), lu avec getifaddrs : aucune requête réseau.
    public static func interfaceMTU(_ name: String) -> Int? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.pointee.ifa_name) == name, let data = entry.pointee.ifa_data else { continue }
            let mtu = Int(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
            return mtu > 0 ? mtu : nil
        }
        return nil
    }
}

// MARK: - Commandes système

/// Exécute une commande système et renvoie sa sortie standard et ses erreurs mêlées (ping et
/// traceroute écrivent une partie de leurs messages sur la sortie d'erreur), avec délai maximal.
public enum SystemCommand {
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw ToolError.toolMissing(path) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                process.standardInput = FileHandle.nullDevice
                let collected = ToolBox<Data>(Data())
                output.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty { collected.mutate { $0.append(chunk) } }
                }
                let once = ToolOnce()
                process.terminationHandler = { _ in
                    output.fileHandleForReading.readabilityHandler = nil
                    let rest = output.fileHandleForReading.readDataToEndOfFile()
                    collected.mutate { $0.append(rest) }
                    guard once.claim() else { return }
                    continuation.resume(returning: String(decoding: collected.value, as: UTF8.self))
                }
                do {
                    try process.run()
                } catch {
                    if once.claim() { continuation.resume(throwing: ToolError.processFailed(error.localizedDescription)) }
                    return
                }
                SystemCommandRegistry.shared.add(process)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard once.claim() else { return }
                    process.terminate()
                    continuation.resume(throwing: ToolError.timeout(timeout))
                }
            }
        } onCancel: {
            SystemCommandRegistry.shared.terminateAll(path: path)
        }
    }
}

/// Processus en cours, pour les arrêter quand la tâche qui les attend est annulée.
final class SystemCommandRegistry: @unchecked Sendable {
    static let shared = SystemCommandRegistry()
    private let lock = NSLock()
    private var processes: [Process] = []

    func add(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        processes.removeAll { !$0.isRunning }
        processes.append(process)
    }

    func terminateAll(path: String) {
        lock.lock()
        let running = processes.filter { $0.isRunning && $0.executableURL?.path == path }
        lock.unlock()
        running.forEach { $0.terminate() }
    }
}
