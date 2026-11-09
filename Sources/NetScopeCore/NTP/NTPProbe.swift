import Darwin
import Foundation

public struct NTPProbeOptions: Sendable {
    public static let defaultPort: UInt16 = 123

    public var port: UInt16
    /// Attente de chaque réponse, bornée à `timeoutRange`.
    public var timeout: TimeInterval
    public var samples: Int
    /// 2 s entre deux envois, comme ntpdate : les serveurs avec « restrict limited » ignorent
    /// silencieusement un client plus pressé.
    public var interval: TimeInterval

    static let timeoutRange = 0.05...5.0

    public init(port: UInt16 = NTPProbeOptions.defaultPort, timeout: TimeInterval = 1.5, samples: Int = 4, interval: TimeInterval = 2) {
        self.port = port
        self.timeout = timeout
        self.samples = samples
        self.interval = interval
    }

    var boundedTimeout: TimeInterval {
        timeout.isFinite ? min(max(timeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound) : 1.5
    }
}

/// Client SNTP (note 115) : lancé seulement sur clic, jamais pendant les tests sauf vers 127.0.0.1.
public enum NTPProbe {
    public static let maxServers = 8

    /// Serveurs d'une saisie (virgules, points-virgules ou espaces), sans doublon, `maxServers` au
    /// plus ; `ignored` compte ceux qui dépassent.
    public static func parseServers(_ text: String) -> (servers: [String], ignored: Int) {
        var seen = Set<String>()
        let unique = text.split { $0.isWhitespace || $0 == "," || $0 == ";" }
            .map(String.init)
            .filter { seen.insert($0.lowercased()).inserted }
        return (Array(unique.prefix(maxServers)), max(0, unique.count - maxServers))
    }

    /// Parmi les échantillons, celui de plus faible délai : le moins perturbé par le réseau.
    /// Un refus ne compte que s'il n'y a aucune heure exploitable.
    public static func best(_ samples: [NTPSample]) -> NTPSample? {
        samples.filter(\.hasClock).min { $0.roundTrip < $1.roundTrip } ?? samples.first
    }

    /// Interroge tous les serveurs en même temps ; résultats dans l'ordre de la saisie.
    public static func run(servers: [String], options: NTPProbeOptions = NTPProbeOptions()) async -> [NTPServerResult] {
        await withTaskGroup(of: (Int, NTPServerResult).self) { group in
            for (index, server) in servers.prefix(maxServers).enumerated() {
                group.addTask { (index, await query(server: server, options: options)) }
            }
            var results: [(Int, NTPServerResult)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public static func query(server: String, options: NTPProbeOptions = NTPProbeOptions()) async -> NTPServerResult {
        guard let address = try? await PingResolver.resolveAsync(server) else {
            return NTPServerResult(server: server, failure: "Nom introuvable ou sans adresse IPv4.")
        }
        var samples: [NTPSample] = []
        var sent = 0
        var rejected = 0
        var failure: String?
        var lastSend = Date()
        burst: for index in 0..<max(1, min(options.samples, 8)) {
            if index > 0 {
                let wait = options.interval - Date().timeIntervalSince(lastSend)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            if Task.isCancelled { break }
            lastSend = Date()
            sent += 1
            let outcome = await exchange(server: server, address: address, port: options.port, timeout: options.boundedTimeout)
            rejected += outcome.rejected
            switch outcome.result {
            case let .sample(sample):
                samples.append(sample)
                // Strate 0 : le serveur demande de cesser, ou n'a pas d'heure à donner.
                if !sample.hasClock { break burst }
            case .noReply:
                continue
            case let .failed(text):
                failure = text
                break burst
            }
        }
        return NTPServerResult(server: server, address: address, sample: best(samples), sent: sent, answered: samples.count,
                               rejected: rejected, failure: failure)
    }

    // MARK: Socket

    private enum ExchangeResult {
        case sample(NTPSample)
        case noReply
        case failed(String)
    }

    private struct Outcome {
        var result: ExchangeResult
        var rejected = 0
    }

    private static func exchange(server: String, address: IPv4Address, port: UInt16, timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: exchangeBlocking(server: server, address: address, port: port, timeout: timeout))
            }
        }
    }

    /// Une requête sur sa propre socket connectée : le noyau écarte ce qui ne vient pas du serveur
    /// et remonte les erreurs ICMP.
    private static func exchangeBlocking(server: String, address: IPv4Address, port: UInt16, timeout: TimeInterval) -> Outcome {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return Outcome(result: .failed("Socket UDP impossible (\(String(cString: strerror(errno)))).")) }
        defer { close(fd) }
        guard ToolSocket.connect(fd, to: ToolSocket.address(address, port: port)) == 0 else {
            return Outcome(result: .failed(socketFailure(errno, port: port)))
        }
        let t1 = unpredictableTimestamp(Date())
        let request = NTPPacket.request(transmit: t1).encoded()
        guard send(fd, request, request.count, 0) == request.count else {
            return Outcome(result: .failed(socketFailure(errno, port: port)))
        }
        var rejected = 0
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return Outcome(result: .noReply, rejected: rejected) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(max(1, (remaining * 1000).rounded(.up)))) > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            let received = Date()
            guard count >= 0 else {
                if errno == EINTR || errno == EAGAIN { continue }
                return Outcome(result: .failed(socketFailure(errno, port: port)), rejected: rejected)
            }
            guard let packet = try? NTPPacket.reply(Array(buffer[0..<count]), expectedOrigin: t1) else {
                rejected += 1
                continue
            }
            let sample = NTPSample(server: server, address: address, packet: packet, sentAt: t1,
                                   receivedAt: NTPTimestamp(date: received), now: received)
            return Outcome(result: .sample(sample), rejected: rejected)
        }
    }

    /// Les 12 bits de poids faible valent moins d'une microseconde, sous la résolution de `Date` :
    /// tirés au hasard, ils empêchent de deviner l'horodatage à renvoyer dans une réponse forgée.
    private static func unpredictableTimestamp(_ date: Date) -> NTPTimestamp {
        NTPTimestamp(raw: NTPTimestamp(date: date).raw & ~0xFFF | UInt64.random(in: 0...0xFFF))
    }

    private static func socketFailure(_ code: Int32, port: UInt16) -> String {
        switch code {
        case ECONNREFUSED: return "Port UDP \(port) fermé\u{00A0}: l’appareil répond, mais aucun service NTP n’y écoute."
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN: return "Hôte injoignable depuis ce Mac (\(String(cString: strerror(code))))."
        default: return "Erreur réseau\u{00A0}: \(String(cString: strerror(code)))."
        }
    }
}
