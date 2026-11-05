import Foundation

// Traceroute TCP et UDP (note 65). Une sonde TCP SYN ou UDP à TTL choisi demande une socket
// brute (droits root) : NetScope n'en a pas. Il passe donc par /usr/sbin/traceroute d'Apple,
// installé avec macOS et « setuid root », qui a ces droits : `-P TCP -p <port> -e` (SYN vers le
// port, port fixe) ou `-P UDP` (ports hauts 33434 et suivants). Le traceroute ICMP reste
// natif (PingTracer, socket ICMP non privilégiée).

/// Protocole du traceroute (MTR) du ping continu.
public enum PingTraceProtocol: Hashable, Sendable {
    case icmp
    case udp
    case tcp(port: UInt16)

    /// « ICMP », « UDP », « TCP 443 ».
    public var label: String {
        switch self {
        case .icmp: return "ICMP"
        case .udp: return "UDP"
        case let .tcp(port): return "TCP \(port)"
        }
    }

    /// Protocole proposé pour une cible : TCP vers son port si elle est sondée en TCP ou HTTP.
    public static func suggested(for kind: PingProbeKind) -> PingTraceProtocol {
        kind.tcpPort.map { .tcp(port: $0) } ?? .icmp
    }

    /// Passe par /usr/sbin/traceroute (droits root fournis par le setuid d'Apple).
    public var usesSystemTraceroute: Bool { self != .icmp }
}

/// Arguments et lecture de la sortie de /usr/sbin/traceroute.
public enum PingTracerouteOutput {
    public static let path = "/usr/sbin/traceroute"

    /// Une sonde par saut (-q 1), adresses sans DNS (-n), attente `wait` secondes par sonde.
    public static func arguments(destination: IPv4Address, protocol traceProtocol: PingTraceProtocol,
                                 maxHops: Int, wait: Int = 1) -> [String] {
        var arguments = ["-n", "-q", "1", "-w", "\(max(1, wait))", "-m", "\(min(max(1, maxHops), 64))"]
        switch traceProtocol {
        case .icmp: arguments += ["-P", "ICMP"]
        case .udp: arguments += ["-P", "UDP"]
        case let .tcp(port): arguments += ["-P", "TCP", "-p", "\(port)", "-e"]
        }
        arguments.append(destination.description)
        return arguments
    }

    /// Un saut lu dans la sortie.
    public struct Hop: Equatable, Sendable {
        public let ttl: Int
        /// Réponses du saut (une par sonde reçue) ; vide : « * ».
        public let replies: [Probe]

        public struct Probe: Equatable, Sendable {
            public let address: IPv4Address
            public let rttMs: Double
            /// Annotation (« !H », « !N », « !Z », « !F-1480 »…), nil sans annotation.
            public let annotation: String?
        }
    }

    /// Lit les lignes de sauts (« 1  10.0.0.1  1.234 ms », « 2  * », « 3  host (1.2.3.4)  5.6 ms !N ») ;
    /// les autres lignes (en-tête, avertissements) sont ignorées.
    public static func parseHops(_ text: String) -> [Hop] {
        var hops: [Int: [Hop.Probe]] = [:]
        var order: [Int] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first, let ttl = Int(first), ttl > 0, ttl <= 255 else { continue }
            if hops[ttl] == nil {
                hops[ttl] = []
                order.append(ttl)
            }
            var current: IPv4Address?
            var index = 1
            while index < tokens.count {
                let token = tokens[index]
                if let address = IPv4Address(token) {
                    current = address
                } else if token.hasPrefix("("), token.hasSuffix(")"), let address = IPv4Address(String(token.dropFirst().dropLast())) {
                    current = address
                } else if let value = Double(token), index + 1 < tokens.count, tokens[index + 1] == "ms", let address = current {
                    var annotation: String?
                    if index + 2 < tokens.count, tokens[index + 2].hasPrefix("!") {
                        annotation = tokens[index + 2]
                        index += 1
                    }
                    hops[ttl, default: []].append(Hop.Probe(address: address, rttMs: value, annotation: annotation))
                    index += 1
                }
                index += 1
            }
        }
        return order.map { Hop(ttl: $0, replies: hops[$0] ?? []) }
    }

    /// Cycle du MTR : une réponse par TTL (la première), destination reconnue à son adresse.
    public static func cycle(_ text: String, destination: IPv4Address) -> PingTraceCycle {
        let hops = parseHops(text)
        var replies: [Int: PingHopReply] = [:]
        for hop in hops {
            guard let probe = hop.replies.first else { continue }
            replies[hop.ttl] = PingHopReply(address: probe.address, rttMs: probe.rttMs,
                                            reachedDestination: probe.address == destination)
        }
        return PingTraceCycle(probed: hops.map(\.ttl).max() ?? 0, replies: replies)
    }

    /// Explication d'une annotation de traceroute (« !Z » → « interdit par l’administrateur »).
    public static func annotationLabel(_ annotation: String) -> String {
        if annotation.hasPrefix("!F") { return "fragmentation nécessaire" + (annotation.count > 3 ? " (MTU \(annotation.dropFirst(3)))" : "") }
        switch annotation {
        case "!H": return "hôte inaccessible"
        case "!N": return "réseau inaccessible"
        case "!P": return "protocole inaccessible"
        case "!S": return "routage par la source refusé"
        case "!U", "!W": return "destination inconnue"
        case "!A", "!Z", "!X": return "interdit par l’administrateur (pare-feu)"
        case "!": return "TTL de retour ≤ 1"
        default: return "inaccessible (\(annotation))"
        }
    }
}

/// Traceroute TCP ou UDP par /usr/sbin/traceroute, cycle par cycle (MTR).
public final class PingSystemTracer: @unchecked Sendable {
    public let destination: IPv4Address
    public let traceProtocol: PingTraceProtocol
    public let maxHops: Int
    private let lock = NSLock()
    /// Dernier saut qui a répondu, quand la destination ne répond pas (port filtré) : les cycles
    /// suivants s'arrêtent un peu après au lieu d'attendre 30 sauts muets.
    private var lastResponder: Int?

    public init(destination: IPv4Address, protocol traceProtocol: PingTraceProtocol, maxHops: Int = 30) {
        self.destination = destination
        self.traceProtocol = traceProtocol
        self.maxHops = min(max(1, maxHops), 64)
    }

    /// Le traceroute système est-il présent ?
    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: PingTracerouteOutput.path) }

    /// Nombre de sauts à sonder au prochain cycle.
    public func hopLimit(destinationTTL: Int?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let destinationTTL { return min(destinationTTL, maxHops) }
        if let lastResponder { return min(maxHops, lastResponder + 3) }
        return maxHops
    }

    public func runCycle(destinationTTL: Int?) async throws -> PingTraceCycle {
        let limit = hopLimit(destinationTTL: destinationTTL)
        let arguments = PingTracerouteOutput.arguments(destination: destination, protocol: traceProtocol, maxHops: limit)
        let output = try await SystemCommand.run(PingTracerouteOutput.path, arguments, timeout: Double(limit) * 1.5 + 5)
        let cycle = PingTracerouteOutput.cycle(output, destination: destination)
        if cycle.destinationTTL == nil, let highest = cycle.replies.keys.max() { remember(highest) }
        return cycle
    }

    private func remember(_ highest: Int) {
        lock.lock()
        defer { lock.unlock() }
        lastResponder = max(lastResponder ?? 0, highest)
    }
}
