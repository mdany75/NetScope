import Darwin
import Foundation

// Note 78 (Journaux) : réception Syslog en TCP (RFC 6587) en plus de l'UDP, sur le même port
// (5514 par défaut, sans droit administrateur).
//
// RFC 6587 décrit deux cadrages sur un même flux TCP :
// - « octet-counting » (section 3.4.1) : « 123 <34>1 2026-… » : la longueur en décimal, une espace,
//   puis exactement ce nombre d'octets ; c'est le mode « reliable » de FortiOS et celui de rsyslog
//   (RFC 5425) ;
// - « non-transparent-framing » (section 3.4.2) : chaque message se termine par un saut de ligne
//   (LF, parfois CR LF ou NUL) ; c'est le cadrage de Cisco, d'AOS-S et de nombreux équipements.
// Un émetteur peut passer de l'un à l'autre entre deux messages : le cadrage est reconnu message
// par message (un chiffre non nul en tête annonce une longueur, sinon on attend la fin de ligne).

/// Découpe un flux TCP Syslog en messages (RFC 6587). Une instance par connexion.
public struct SyslogFrameDecoder: Sendable {
    /// Longueur maximale d'un message : au-delà, le message est coupé (aucun tampon sans fin).
    public static let maxMessage = 65_536
    /// Chiffres au plus dans une longueur (« 65536 » : 5) ; au-delà, ce n'est pas une longueur.
    static let maxDigits = 6

    private var buffer: [UInt8] = []
    /// Messages coupés ou longueurs incohérentes rencontrés (pour le diagnostic).
    public private(set) var problems = 0

    public init() {}

    /// Octets en attente d'un message complet.
    public var pending: Int { buffer.count }

    /// Ajoute des octets reçus ; renvoie les messages complets (sans le cadrage ni la fin de ligne).
    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        buffer += bytes
        var messages: [[UInt8]] = []
        var start = 0
        while start < buffer.count {
            // Fins de ligne et NUL entre deux messages : ignorés.
            let first = buffer[start]
            if first == 0x0A || first == 0x0D || first == 0x00 || first == 0x20 { start += 1; continue }
            if first >= 0x31, first <= 0x39 {
                // Peut-être une longueur (octet-counting) : chiffres puis une espace.
                var p = start
                var length = 0
                while p < buffer.count, p - start < Self.maxDigits, buffer[p] >= 0x30, buffer[p] <= 0x39 {
                    length = length * 10 + Int(buffer[p] - 0x30)
                    p += 1
                }
                if p == buffer.count, p - start < Self.maxDigits { break } // longueur pas encore complète
                if p < buffer.count, buffer[p] == 0x20, length > 0, length <= Self.maxMessage {
                    let bodyStart = p + 1
                    guard bodyStart + length <= buffer.count else { break } // message pas encore complet
                    messages.append(Self.trimmed(Array(buffer[bodyStart..<(bodyStart + length)])))
                    start = bodyStart + length
                    continue
                }
                if p < buffer.count, buffer[p] == 0x20, length > Self.maxMessage { problems += 1 }
                // Sinon : un message en texte qui commence par un chiffre, cadré par la fin de ligne.
            }
            // Non-transparent framing : jusqu'au prochain LF (ou NUL).
            var end = start
            while end < buffer.count, buffer[end] != 0x0A, buffer[end] != 0x00 { end += 1 }
            if end == buffer.count {
                // Pas de fin de ligne : on attend la suite, sauf si le message dépasse la limite.
                if end - start > Self.maxMessage {
                    messages.append(Self.trimmed(Array(buffer[start..<(start + Self.maxMessage)])))
                    problems += 1
                    start += Self.maxMessage
                    continue
                }
                break
            }
            let line = Self.trimmed(Array(buffer[start..<end]))
            if !line.isEmpty { messages.append(line) }
            start = end + 1
        }
        if start > 0 { buffer.removeFirst(min(start, buffer.count)) }
        return messages
    }

    /// Fin de la connexion : le reste du tampon devient un dernier message (sans fin de ligne).
    public mutating func finish() -> [[UInt8]] {
        defer { buffer = [] }
        let rest = Self.trimmed(buffer)
        return rest.isEmpty ? [] : [rest]
    }

    /// Message sans CR, LF ni NUL en fin.
    static func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        var end = bytes.count
        while end > 0, [0x0A, 0x0D, 0x00].contains(bytes[end - 1]) { end -= 1 }
        return end == bytes.count ? bytes : Array(bytes[0..<end])
    }

    /// Cadrage « octet-counting » d'un message (envoi en TCP, RFC 6587 section 3.4.1).
    public static func octetCounted(_ message: [UInt8]) -> [UInt8] {
        let body = trimmed(message)
        return Array("\(body.count) ".utf8) + body
    }
}

/// Transport d'un message Syslog.
public enum SyslogTransport: String, Codable, CaseIterable, Sendable, Identifiable {
    case udp, tcp

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
}

/// Récepteur Syslog TCP : un socket d'écoute et ses connexions, suivis par un seul fil (poll).
/// Chaque message reçu est passé à `handler` comme un datagramme (même décodage que l'UDP).
public final class LogTCPListener: @unchecked Sendable {
    public let requestedPort: UInt16
    /// Adresse d'écoute : nil pour toutes les interfaces (127.0.0.1 dans les tests).
    public let address: IPv4Address?
    /// Connexions simultanées au plus (au-delà, les nouvelles sont refusées).
    public let maxConnections: Int
    /// Une connexion silencieuse plus longtemps est fermée (l'équipement la rouvrira).
    public let idleTimeout: TimeInterval
    private let handler: @Sendable (LogDatagram) -> Void
    private let stopped: @Sendable (String?) -> Void
    private let lock = NSLock()
    private var running = false
    private var finished: DispatchSemaphore?
    private var connectionCount = 0
    public private(set) var boundPort: UInt16 = 0
    private let name: String

    public init(port: UInt16, address: IPv4Address? = nil, name: String = "Syslog TCP", maxConnections: Int = 64,
                idleTimeout: TimeInterval = 3_600,
                handler: @escaping @Sendable (LogDatagram) -> Void, stopped: @escaping @Sendable (String?) -> Void = { _ in }) {
        requestedPort = port
        self.address = address
        self.name = name
        self.maxConnections = maxConnections
        self.idleTimeout = idleTimeout
        self.handler = handler
        self.stopped = stopped
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Connexions ouvertes en ce moment (équipements qui envoient en TCP).
    public var connections: Int { lock.lock(); defer { lock.unlock() }; return connectionCount }

    public func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        lock.unlock()
        let (socketFD, port) = try Self.bind(address: address, port: requestedPort)
        let done = DispatchSemaphore(value: 0)
        lock.lock()
        boundPort = port
        running = true
        finished = done
        lock.unlock()
        let thread = Thread { [self] in
            serve(socketFD)
            done.signal()
        }
        thread.name = "\(name) écoute \(port)"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Arrête l'écoute, ferme les connexions et attend la fin du fil (au plus une seconde).
    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let done = finished
        finished = nil
        lock.unlock()
        if wasRunning, let done { _ = done.wait(timeout: .now() + 1) }
        if wasRunning { stopped(nil) }
    }

    private var shouldRun: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private struct Client {
        var fd: Int32
        var from: IPv4Address
        var port: UInt16
        var decoder = SyslogFrameDecoder()
        var lastActivity: Date
    }

    private func serve(_ listenFD: Int32) {
        var clients: [Client] = []
        defer {
            for client in clients { close(client.fd) }
            close(listenFD)
            lock.lock()
            connectionCount = 0
            lock.unlock()
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while shouldRun {
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)]
            fds += clients.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), 250)
            if ready < 0 {
                if errno == EINTR { continue }
                let message = String(cString: strerror(errno))
                lock.lock()
                let wasRunning = running
                running = false
                lock.unlock()
                if wasRunning { stopped("Écoute TCP interrompue\u{00A0}: \(message)") }
                return
            }
            let now = Date()
            var closed = Set<Int32>()
            if ready > 0 {
                // Données des connexions ouvertes.
                for index in clients.indices where fds[index + 1].revents != 0 {
                    let fd = clients[index].fd
                    let count = recv(fd, &buffer, buffer.count, 0)
                    if count > 0 {
                        clients[index].lastActivity = now
                        let messages = clients[index].decoder.feed(Array(buffer[0..<count]))
                        deliver(messages, from: clients[index], date: now)
                    } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        deliver(clients[index].decoder.finish(), from: clients[index], date: now)
                        closed.insert(fd)
                    }
                }
                // Nouvelle connexion.
                if fds[0].revents & Int16(POLLIN) != 0 {
                    var from = sockaddr_in()
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let fd = withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &length) }
                    }
                    if fd >= 0 {
                        if clients.count - closed.count >= maxConnections {
                            close(fd)
                        } else {
                            var one: Int32 = 1
                            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                            clients.append(Client(fd: fd, from: IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr)),
                                                  port: UInt16(bigEndian: from.sin_port), lastActivity: now))
                        }
                    }
                }
            }
            // Connexions muettes depuis trop longtemps.
            for client in clients where now.timeIntervalSince(client.lastActivity) > idleTimeout {
                closed.insert(client.fd)
            }
            if !closed.isEmpty {
                for fd in closed { close(fd) }
                clients.removeAll { closed.contains($0.fd) }
            }
            lock.lock()
            connectionCount = clients.count
            lock.unlock()
        }
    }

    private func deliver(_ messages: [[UInt8]], from client: Client, date: Date) {
        for message in messages where !message.isEmpty {
            handler(LogDatagram(bytes: message, from: client.from, fromPort: client.port, date: date))
        }
    }

    static func bind(address: IPv4Address?, port: UInt16) throws -> (Int32, UInt16) {
        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else { throw LogBindError(code: errno, port: port, transport: .tcp) }
        var one: Int32 = 1
        // Redémarrage rapide de la réception : le port reste réutilisable malgré TIME_WAIT.
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: (address?.value ?? 0).bigEndian)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(socketFD, 16) == 0 else {
            let code = errno
            close(socketFD)
            throw LogBindError(code: code, port: port, transport: .tcp)
        }
        _ = fcntl(socketFD, F_SETFL, fcntl(socketFD, F_GETFL) | O_NONBLOCK)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        return (socketFD, UInt16(bigEndian: bound.sin_port))
    }

    /// Ouvre une connexion TCP vers ce Mac (127.0.0.1 seulement) et envoie `bytes` (essai, tests).
    @discardableResult
    public static func sendToSelf(_ bytes: [UInt8], port: UInt16, timeout: TimeInterval = 2) -> Bool {
        guard let fd = SyslogSocket.connectTCP(IPv4Address(127, 0, 0, 1), port: port, timeout: timeout) else { return false }
        defer { close(fd) }
        return SyslogSocket.sendAll(fd, bytes)
    }
}

/// Sockets d'envoi communs (essais vers ce Mac, transfert vers un autre serveur).
enum SyslogSocket {
    /// Connexion TCP avec délai (connect non bloquant puis poll) ; nil en cas d'échec.
    static func connectTCP(_ address: IPv4Address, port: UInt16, timeout: TimeInterval) -> Int32? {
        connectTCPReporting(address, port: port, timeout: timeout).fd
    }

    /// Connexion TCP ; en cas d'échec, le code errno (ETIMEDOUT pour un délai dépassé).
    static func connectTCPReporting(_ address: IPv4Address, port: UInt16, timeout: TimeInterval) -> (fd: Int32?, error: Int32) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return (nil, errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: address.value.bigEndian)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { let code = errno; close(fd); return (nil, code) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(max(0.05, timeout) * 1000)) > 0 else { close(fd); return (nil, ETIMEDOUT) }
            var code: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length)
            guard code == 0 else { close(fd); return (nil, code) }
        }
        // Envoi bloquant ensuite, borné par un délai d'écriture.
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return (fd, 0)
    }

    /// Envoie tous les octets (TCP) ; faux si la connexion est perdue.
    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { raw in send(fd, raw.baseAddress, raw.count, 0) }
            if count <= 0 {
                if count < 0, errno == EINTR { continue }
                return false
            }
            sent += count
        }
        return true
    }
}
