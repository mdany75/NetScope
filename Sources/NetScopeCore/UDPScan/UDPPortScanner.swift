import Darwin
import Foundation

/// Scan UDP ciblé (note 69) : une sonde propre à chaque protocole, sur une socket UDP connectée.
///
/// - Une réponse : ouvert (lue par UDPProbeReader).
/// - ICMP « port injoignable » : la socket connectée reçoit ECONNREFUSED, donc fermé.
/// - ICMP « hôte injoignable » ou « interdit » : EHOSTUNREACH ou ENETUNREACH, donc filtré.
/// - Rien après tous les essais : ouvert|filtré (UDP ne permet pas de mieux dire).
///
/// TFTP et SSDP répondent souvent d'un autre port : une seconde socket non connectée, liée au même
/// port local (SO_REUSEPORT), reçoit ces réponses, filtrées sur l'adresse de la cible ; la socket
/// connectée garde les erreurs ICMP.
///
/// Lancé seulement sur clic (fiche Appareil, Scanner, Boîte à outils) ; jamais pendant les tests
/// automatiques, sauf vers 127.0.0.1.
public enum UDPPortScanner {
    /// Scanne les services choisis. `ports` remplace le port standard d'un service (tests sur
    /// 127.0.0.1). `progress` reçoit (faits, total, dernier résultat).
    public static func scan(host: IPv4Address, services: [UDPService], options: UDPProbeOptions = UDPProbeOptions(),
                            ports: [UDPService: UInt16] = [:],
                            progress: (@Sendable (Int, Int, UDPProbeResult) -> Void)? = nil) async -> UDPScanSummary {
        let start = Date()
        var unique: [UDPService] = []
        for service in services where !unique.contains(service) { unique.append(service) }
        let width = max(1, min(options.concurrency, 9))
        var results: [UDPProbeResult] = []
        await withTaskGroup(of: UDPProbeResult.self) { group in
            var iterator = unique.makeIterator()
            for _ in 0..<width {
                guard let service = iterator.next() else { break }
                group.addTask { await probe(host: host, service: service, port: ports[service] ?? service.port, options: options) }
            }
            var done = 0
            while let result = await group.next() {
                done += 1
                results.append(result)
                progress?(done, unique.count, result)
                if Task.isCancelled { group.cancelAll(); continue }
                if let service = iterator.next() {
                    group.addTask { await probe(host: host, service: service, port: ports[service] ?? service.port, options: options) }
                }
            }
        }
        return UDPScanSummary(host: host.description, results: results, duration: Date().timeIntervalSince(start),
                              wasCancelled: Task.isCancelled, date: Date())
    }

    /// Sonde un port (bloquant, hors du fil appelant).
    public static func probe(host: IPv4Address, service: UDPService, port: UInt16? = nil,
                             options: UDPProbeOptions = UDPProbeOptions()) async -> UDPProbeResult {
        let target = port ?? service.port
        guard !Task.isCancelled else { return UDPProbeResult(service: service, port: target, state: .openFiltered) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probeBlocking(host: host, service: service, port: target, options: options))
            }
        }
    }

    // MARK: Socket

    /// Ce que la socket a vu pendant l'échange.
    struct Exchange {
        var datagrams: [[UInt8]] = []
        var refused = false
        var unreachable = false
        var firstReply: Date?
        var sentAt: Date?
        var error: String?
    }

    static func probeBlocking(host: IPv4Address, service: UDPService, port: UInt16, options: UDPProbeOptions) -> UDPProbeResult {
        let exchange = run(host: host, service: service, port: port, options: options)
        let state = UDPPortState.classify(replies: exchange.datagrams.count, refused: exchange.refused, unreachable: exchange.unreachable)
        var result = UDPProbeResult(service: service, port: port, state: state)
        if let reply = exchange.firstReply, let sent = exchange.sentAt {
            result.rttMs = max(0, reply.timeIntervalSince(sent) * 1000)
        }
        result.responseBytes = exchange.datagrams.reduce(0) { $0 + $1.count }
        if let reading = UDPProbeReader.read(service, datagrams: exchange.datagrams, community: options.snmpCommunity) {
            result.summary = reading.summary
            result.details = reading.details
            result.findings = reading.findings
        } else if let error = exchange.error {
            result.summary = error
        }
        return result
    }

    static func run(host: IPv4Address, service: UDPService, port: UInt16, options: UDPProbeOptions) -> Exchange {
        var exchange = Exchange()
        let connected = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard connected >= 0 else {
            exchange.error = "Socket UDP impossible (\(String(cString: strerror(errno))))"
            return exchange
        }
        defer { close(connected) }
        var listener: Int32 = -1
        defer { if listener >= 0 { close(listener) } }

        if service.repliesFromOtherPort {
            listener = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            if listener >= 0 {
                reuse(listener)
                reuse(connected)
                var any = ToolSocket.address(IPv4Address(0), port: 0)
                if bind(listener, &any), let local = localAddress(listener) {
                    var same = ToolSocket.address(IPv4Address(0), port: local.port)
                    if !bind(connected, &same) {
                        close(listener)
                        listener = -1
                    }
                } else {
                    close(listener)
                    listener = -1
                }
            }
        }
        guard ToolSocket.connect(connected, to: ToolSocket.address(host, port: port)) == 0 else {
            exchange.error = "Connexion UDP impossible (\(String(cString: strerror(errno))))"
            if errno == EHOSTUNREACH || errno == ENETUNREACH { exchange.unreachable = true }
            return exchange
        }
        for fd in [connected, listener] where fd >= 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        }
        let local = localAddress(connected)
        let context = UDPProbePayload.Context(target: host, localAddress: local?.address, localPort: local?.port ?? 0,
                                              transactionID: UInt16.random(in: 0x1000...0xEFFF),
                                              snmpCommunity: options.snmpCommunity, ntpControlChecks: options.ntpControlChecks,
                                              nonce: String(UInt32.random(in: 0x1000_0000...0xFFFF_FFFF), radix: 16))
        let packets = UDPProbePayload.packets(for: service, context: context).filter { !$0.isEmpty }
        let timeout = options.timeout.isFinite ? min(max(options.timeout, 0.2), 10) : 1.5
        let grace = 0.35

        attempts: for _ in 0..<max(1, min(options.attempts, 4)) {
            let sentAt = Date()
            for packet in packets {
                if Darwin.send(connected, packet, packet.count, 0) < 0 {
                    if note(errno, into: &exchange) { break attempts }
                }
            }
            if exchange.sentAt == nil || exchange.datagrams.isEmpty { exchange.sentAt = sentAt }
            var deadline = sentAt.addingTimeInterval(timeout)
            while Date() < deadline {
                if Task.isCancelled { break attempts }
                var fds = [pollfd(fd: connected, events: Int16(POLLIN), revents: 0)]
                if listener >= 0 { fds.append(pollfd(fd: listener, events: Int16(POLLIN), revents: 0)) }
                let wait = Int32(max(1, min(250, deadline.timeIntervalSinceNow * 1000)))
                let ready = poll(&fds, nfds_t(fds.count), wait)
                guard ready > 0 else { continue }
                if fds[0].revents != 0 {
                    var buffer = [UInt8](repeating: 0, count: 9000)
                    let n = recv(connected, &buffer, buffer.count, 0)
                    if n > 0 {
                        received(Array(buffer[0..<n]), into: &exchange, deadline: &deadline, grace: grace)
                    } else if n < 0, errno != EAGAIN, note(errno, into: &exchange) {
                        break attempts
                    }
                }
                if fds.count > 1, fds[1].revents != 0 {
                    var buffer = [UInt8](repeating: 0, count: 9000)
                    var from = sockaddr_in()
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(listener, &buffer, buffer.count, 0, $0, &length) }
                    }
                    if n > 0, UInt32(bigEndian: from.sin_addr.s_addr) == host.value {
                        let bytes = Array(buffer[0..<n])
                        received(bytes, into: &exchange, deadline: &deadline, grace: grace)
                        // Fichier servi par hasard : on arrête le transfert proprement.
                        if service == .tftp, bytes.count >= 2, bytes[0] == 0, bytes[1] == 3 {
                            let abort = UDPProbePayload.tftpAbort
                            _ = withUnsafePointer(to: &from) {
                                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(listener, abort, abort.count, 0, $0, length) }
                            }
                        }
                    }
                }
            }
            if !exchange.datagrams.isEmpty { break }
        }
        return exchange
    }

    /// Datagramme reçu : on attend encore un court instant les réponses suivantes (NTP modes 6
    /// et 7, DNS deuxième requête), pas tout le délai.
    private static func received(_ bytes: [UInt8], into exchange: inout Exchange, deadline: inout Date, grace: TimeInterval) {
        guard exchange.datagrams.count < 32 else { return }
        if exchange.firstReply == nil {
            exchange.firstReply = Date()
            deadline = min(deadline, Date().addingTimeInterval(grace))
        }
        exchange.datagrams.append(bytes)
    }

    /// Erreur de socket : vrai si elle met fin à l'échange.
    private static func note(_ code: Int32, into exchange: inout Exchange) -> Bool {
        switch code {
        case ECONNREFUSED:
            exchange.refused = true
            return exchange.datagrams.isEmpty
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN:
            exchange.unreachable = true
            return exchange.datagrams.isEmpty
        case EAGAIN, EINTR:
            return false
        default:
            exchange.error = "Erreur UDP (\(String(cString: strerror(code))))"
            return false
        }
    }

    private static func reuse(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func bind(_ fd: Int32, _ address: inout sockaddr_in) -> Bool {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    private static func localAddress(_ fd: Int32) -> (address: IPv4Address, port: UInt16)? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard status == 0 else { return nil }
        return (IPv4Address(UInt32(bigEndian: address.sin_addr.s_addr)), UInt16(bigEndian: address.sin_port))
    }
}
