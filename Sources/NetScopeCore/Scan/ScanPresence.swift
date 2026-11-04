import Darwin
import Foundation

/// Réponse d'une sonde TCP de joignabilité.
public enum TCPProbeState: Equatable, Sendable {
    /// Connexion établie (port ouvert).
    case open(milliseconds: Int)
    /// Connexion refusée (RST) : l'hôte est là, le port est fermé.
    case refused(milliseconds: Int)
    /// Aucune réponse avant le délai (hôte absent ou port filtré).
    case timeout
    /// Réseau ou hôte injoignable (ICMP « unreachable » ou pas de route).
    case unreachable(String)

    /// L'hôte a répondu (port ouvert ou fermé).
    public var hostAnswered: Bool {
        switch self {
        case .open, .refused: return true
        default: return false
        }
    }

    /// « ouvert (12 ms) », « fermé », « filtré (aucune réponse) »…
    public var label: String {
        switch self {
        case .open(let ms): return "ouvert (\(ms)\u{00A0}ms)"
        case .refused: return "fermé (connexion refusée)"
        case .timeout: return "filtré ou absent (aucune réponse)"
        case .unreachable(let why): return "injoignable (\(why))"
        }
    }
}

/// Réponse d'une sonde UDP.
public enum UDPProbeState: Equatable, Sendable {
    /// Données reçues du port.
    case answered(milliseconds: Int)
    /// ICMP « port injoignable » reçu : l'hôte est là, le port est fermé.
    case portUnreachable(milliseconds: Int)
    /// Rien reçu (port filtré, service muet ou hôte absent).
    case silent
    case failed(String)

    public var hostAnswered: Bool {
        switch self {
        case .answered, .portUnreachable: return true
        default: return false
        }
    }
}

/// Comment un hôte muet au ping a été trouvé.
public struct ScanPresenceHit: Equatable, Sendable {
    public enum Method: String, Sendable { case tcp, udp }
    public var method: Method
    public var port: UInt16
    public var milliseconds: Int
}

/// Sonde de présence (hôtes qui ignorent le ping) : TCP puis UDP sur des ports choisis.
public protocol ScanPresenceProbing: Sendable {
    func probe(_ ip: IPv4Address, tcpPorts: [UInt16], udpPorts: [UInt16], timeout: Duration) async -> ScanPresenceHit?
}

/// Sondes TCP et UDP par sockets BSD, sur une file à part (au plus 64 à la fois) : l'attente
/// (poll) est bornée par le délai, sans jamais occuper les fils GCD partagés.
public struct ScanPresenceProber: ScanPresenceProbing {
    public init() {}

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "netscope.presence"
        queue.maxConcurrentOperationCount = 64
        queue.qualityOfService = .utility
        return queue
    }()

    public func probe(_ ip: IPv4Address, tcpPorts: [UInt16], udpPorts: [UInt16], timeout: Duration) async -> ScanPresenceHit? {
        let seconds = max(0.05, timeout.scanSeconds)
        for port in tcpPorts where !Task.isCancelled {
            switch await Self.tcp(ip, port: port, timeout: seconds) {
            case .open(let ms), .refused(let ms): return ScanPresenceHit(method: .tcp, port: port, milliseconds: ms)
            default: continue
            }
        }
        for port in udpPorts where !Task.isCancelled {
            switch await Self.udp(ip, port: port, timeout: seconds) {
            case .answered(let ms), .portUnreachable(let ms): return ScanPresenceHit(method: .udp, port: port, milliseconds: ms)
            default: continue
            }
        }
        return nil
    }

    /// Connexion TCP (sans rien envoyer) : ouverte, refusée, sans réponse ou injoignable.
    public static func tcp(_ ip: IPv4Address, port: UInt16, timeout: TimeInterval) async -> TCPProbeState {
        await run { tcpBlocking(ip, port: port, timeout: timeout) }
    }

    /// Datagramme UDP vers `port` (charge utile propre au service quand on la connaît).
    public static func udp(_ ip: IPv4Address, port: UInt16, timeout: TimeInterval) async -> UDPProbeState {
        await run { udpBlocking(ip, port: port, payload: payload(for: port), timeout: timeout) }
    }

    private static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: work()) }
        }
    }

    /// Petite requête qui fait répondre le service : NTP (mode client), DNS (requête de la racine),
    /// NetBIOS (statut de nœud). Les autres ports reçoivent un octet nul : seul compte le « port
    /// injoignable » qu'un hôte présent renvoie souvent.
    static func payload(for port: UInt16) -> [UInt8] {
        switch port {
        case 123: return [0x1B] + [UInt8](repeating: 0, count: 47)
        case 53: return [0x4E, 0x53, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]
        case 137:
            var name: [UInt8] = [0x20, 0x43, 0x4B]
            name += [UInt8](repeating: 0x41, count: 30)
            return [0x4E, 0x53, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] + name + [0x00, 0x00, 0x21, 0x00, 0x01]
        default: return [0x00]
        }
    }

    static func elapsed(_ start: Date) -> Int { max(0, Int((Date().timeIntervalSince(start) * 1000).rounded())) }

    static func tcpBlocking(_ ip: IPv4Address, port: UInt16, timeout: TimeInterval) -> TCPProbeState {
        let start = Date()
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .unreachable(String(cString: strerror(errno))) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var address = ToolSocket.address(ip, port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return .open(milliseconds: elapsed(start)) }
        if errno == ECONNREFUSED { return .refused(milliseconds: elapsed(start)) }
        guard errno == EINPROGRESS else { return classify(errno) }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let deadline = start.addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timeout }
            let ready = poll(&poller, 1, Int32(max(1, remaining * 1000)))
            if ready < 0, errno == EINTR { continue }
            if ready <= 0 { return .timeout }
            break
        }
        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
        if soError == 0 { return .open(milliseconds: elapsed(start)) }
        if soError == ECONNREFUSED { return .refused(milliseconds: elapsed(start)) }
        return classify(soError)
    }

    private static func classify(_ code: Int32) -> TCPProbeState {
        switch code {
        case ETIMEDOUT: return .timeout
        case EHOSTUNREACH, EHOSTDOWN: return .unreachable("hôte injoignable")
        case ENETUNREACH, ENETDOWN: return .unreachable("réseau injoignable")
        default: return .unreachable(String(cString: strerror(code)))
        }
    }

    static func udpBlocking(_ ip: IPv4Address, port: UInt16, payload: [UInt8], timeout: TimeInterval) -> UDPProbeState {
        let start = Date()
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failed(String(cString: strerror(errno))) }
        defer { close(fd) }
        // Socket « connecté » : l'ICMP « port injoignable » revient sous forme d'ECONNREFUSED.
        var address = ToolSocket.address(ip, port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return .failed(String(cString: strerror(errno))) }
        let sent = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        if sent < 0 {
            if errno == ECONNREFUSED { return .portUnreachable(milliseconds: elapsed(start)) }
            return .failed(String(cString: strerror(errno)))
        }
        var buffer = [UInt8](repeating: 0, count: 1500)
        let deadline = start.addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .silent }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(max(1, remaining * 1000)))
            if ready < 0, errno == EINTR { continue }
            if ready <= 0 { return .silent }
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count >= 0 { return .answered(milliseconds: elapsed(start)) }
            if errno == ECONNREFUSED { return .portUnreachable(milliseconds: elapsed(start)) }
            if errno == EINTR || errno == EAGAIN { continue }
            return .failed(String(cString: strerror(errno)))
        }
    }
}

/// Sonde de présence qui ne trouve rien (méthodes TCP et UDP coupées, tests).
public struct ScanNoPresence: ScanPresenceProbing {
    public init() {}
    public func probe(_ ip: IPv4Address, tcpPorts: [UInt16], udpPorts: [UInt16], timeout: Duration) async -> ScanPresenceHit? { nil }
}
