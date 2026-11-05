import Darwin
import Foundation

// Note 78 (Journaux) : transfert facultatif des messages Syslog reçus vers un autre serveur
// Syslog (SIEM, Graylog, serveur du client), désactivé par défaut. Les octets reçus sont relayés
// tels quels (aucune réécriture du message) : en UDP un datagramme par message, en TCP avec le
// cadrage « octet-counting » de RFC 6587. Les traps SNMP peuvent suivre, converties en Syslog
// RFC 5424. Aucun secret : seule l'adresse du serveur est retenue (préférences).

/// Réglages du transfert (préférences ; aucun secret).
public struct SyslogForwardSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Adresse IPv4 ou nom du serveur Syslog de destination.
    public var host: String
    public var port: UInt16
    public var transport: SyslogTransport
    /// Gravité minimale transférée (debug : tout).
    public var minimumSeverity: LogSeverity
    /// Transférer aussi les traps SNMP reçues (converties en Syslog RFC 5424).
    public var includeTraps: Bool

    public init(enabled: Bool = false, host: String = "", port: UInt16 = 514, transport: SyslogTransport = .udp,
                minimumSeverity: LogSeverity = .debug, includeTraps: Bool = false) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.transport = transport
        self.minimumSeverity = minimumSeverity
        self.includeTraps = includeTraps
    }

    public static let disabled = SyslogForwardSettings()

    private enum CodingKeys: String, CodingKey { case enabled, host, port, transport, minimumSeverity, includeTraps }

    /// Lecture tolérante (réglages d'une autre version).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        port = (try? c.decodeIfPresent(UInt16.self, forKey: .port)) ?? 514
        transport = (try? c.decodeIfPresent(SyslogTransport.self, forKey: .transport)) ?? .udp
        minimumSeverity = (try? c.decodeIfPresent(LogSeverity.self, forKey: .minimumSeverity)) ?? .debug
        includeTraps = (try? c.decodeIfPresent(Bool.self, forKey: .includeTraps)) ?? false
    }

    public var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// « 10.10.0.40:514 (UDP) ».
    public var destinationLabel: String { "\(trimmedHost):\(port) (\(transport.label))" }

    /// Problème de réglage, en clair ; nil si le transfert peut démarrer.
    /// `listening` : ports et transports où ce Mac écoute (pas de boucle vers soi-même).
    public func problem(listening: [(SyslogTransport, UInt16)]) -> String? {
        let host = trimmedHost
        if host.isEmpty { return "Indiquez l’adresse du serveur Syslog de destination." }
        if port == 0 { return "Indiquez le port du serveur Syslog de destination (514 en général)." }
        if host.contains(" ") || host.contains("/") { return "Adresse du serveur invalide\u{00A0}: «\u{00A0}\(host)\u{00A0}»." }
        let lowered = host.lowercased()
        let isSelf = lowered == "localhost" || lowered == "127.0.0.1" || lowered.hasPrefix("127.")
        if isSelf, listening.contains(where: { $0.0 == transport && $0.1 == port }) {
            return "Le serveur de destination est ce Mac, sur le port où NetScope écoute\u{00A0}: les messages tourneraient en boucle."
        }
        return nil
    }

    /// Le message doit-il être transféré ?
    public func accepts(_ message: LogMessage) -> Bool {
        guard enabled else { return false }
        switch message.source {
        case .syslog: break
        case .trap: guard includeTraps else { return false }
        case .fortigate: return false
        }
        return message.severity.isAtLeast(minimumSeverity)
    }

    /// Octets envoyés pour un message : les octets reçus tels quels pour un message Syslog, une
    /// ligne RFC 5424 pour une trap ; cadrés par longueur en TCP (RFC 6587).
    public func payload(for message: LogMessage, original: [UInt8]?) -> [UInt8] {
        var bytes: [UInt8]
        if message.source == .syslog, let original, !original.isEmpty {
            bytes = SyslogFrameDecoder.trimmed(original)
        } else {
            bytes = SyslogParser.encode5424(severity: message.severity, facility: message.facility ?? 16, date: message.date,
                                            hostname: message.hostname ?? message.host, app: message.app ?? "NetScope",
                                            msgID: message.eventID.map { String($0.prefix(32)).replacingOccurrences(of: " ", with: "_") } ?? "-",
                                            message: message.message)
            bytes = SyslogFrameDecoder.trimmed(bytes)
        }
        return transport == .tcp ? SyslogFrameDecoder.octetCounted(bytes) : bytes
    }
}

/// Compteurs du transfert (montrés dans le panneau des récepteurs).
public struct SyslogForwardStatus: Equatable, Sendable {
    public var sent = 0
    /// Messages perdus (serveur injoignable, file pleine).
    public var dropped = 0
    public var lastError: String?
    public var connected = false

    public init() {}
}

/// Envoi des messages vers le serveur de destination, hors du fil principal : une file bornée,
/// une connexion TCP gardée ouverte (rouverte après une pause en cas d'échec), un socket UDP.
public final class SyslogForwarder: @unchecked Sendable {
    public let settings: SyslogForwardSettings
    /// Messages en attente au plus : au-delà, les nouveaux sont perdus (comptés).
    public static let queueLimit = 5_000
    /// Pause avant une nouvelle tentative de connexion TCP.
    public static let retryDelay: TimeInterval = 10

    private let queue = DispatchQueue(label: "NetScope.SyslogForwarder", qos: .utility)
    private let lock = NSLock()
    private var status = SyslogForwardStatus()
    private var pending = 0
    private var stopped = false
    // Utilisés seulement sur `queue`.
    private var resolved: IPv4Address?
    private var udpFD: Int32 = -1
    private var tcpFD: Int32 = -1
    private var retryAfter: Date?
    private let resolver: @Sendable (String) -> IPv4Address?

    public init(settings: SyslogForwardSettings, resolver: (@Sendable (String) -> IPv4Address?)? = nil) {
        self.settings = settings
        self.resolver = resolver ?? { SyslogForwarder.resolve($0) }
    }

    deinit { closeSockets() }

    public var currentStatus: SyslogForwardStatus { lock.lock(); defer { lock.unlock() }; return status }

    /// Met en file des messages (octets déjà mis en forme par `SyslogForwardSettings.payload`).
    public func enqueue(_ payloads: [[UInt8]]) {
        guard !payloads.isEmpty else { return }
        lock.lock()
        if stopped { lock.unlock(); return }
        let room = max(0, Self.queueLimit - pending)
        let kept = Array(payloads.prefix(room))
        status.dropped += payloads.count - kept.count
        pending += kept.count
        lock.unlock()
        guard !kept.isEmpty else { return }
        queue.async { [self] in
            for payload in kept { send(payload) }
            lock.lock()
            pending -= kept.count
            lock.unlock()
        }
    }

    /// Arrête le transfert et ferme les sockets (les messages encore en file partent d'abord).
    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        queue.sync { closeSockets() }
    }

    /// Attend que la file soit vide (tests).
    public func drain(timeout: TimeInterval = 2) {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func record(sent: Bool, error: String? = nil, connected: Bool? = nil) {
        lock.lock()
        if sent { status.sent += 1 } else { status.dropped += 1 }
        if let error { status.lastError = error } else if sent { status.lastError = nil }
        if let connected { status.connected = connected }
        lock.unlock()
    }

    private func send(_ payload: [UInt8]) {
        guard let address = destination() else {
            record(sent: false, error: "Adresse «\u{00A0}\(settings.trimmedHost)\u{00A0}» introuvable.")
            return
        }
        switch settings.transport {
        case .udp:
            if udpFD < 0 {
                udpFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard udpFD >= 0 else { record(sent: false, error: "Socket UDP impossible."); return }
            }
            if LogUDPListener.send(udpFD, payload, to: address, port: settings.port) {
                record(sent: true, connected: true)
            } else {
                record(sent: false, error: "Envoi UDP vers \(settings.destinationLabel) impossible (\(String(cString: strerror(errno)))).")
            }
        case .tcp:
            if tcpFD < 0 {
                if let retryAfter, Date() < retryAfter { record(sent: false); return }
                let (fd, code) = SyslogSocket.connectTCPReporting(address, port: settings.port, timeout: 2)
                guard let fd else {
                    retryAfter = Date().addingTimeInterval(Self.retryDelay)
                    let reason = code == ECONNREFUSED ? "connexion refusée" : code == ETIMEDOUT ? "délai dépassé" : String(cString: strerror(code))
                    record(sent: false, error: "Serveur \(settings.destinationLabel) injoignable (\(reason))\u{00A0}; nouvel essai dans \(Int(Self.retryDelay))\u{00A0}s.", connected: false)
                    return
                }
                tcpFD = fd
                retryAfter = nil
            }
            if SyslogSocket.sendAll(tcpFD, payload) {
                record(sent: true, connected: true)
            } else {
                close(tcpFD)
                tcpFD = -1
                retryAfter = Date().addingTimeInterval(Self.retryDelay)
                record(sent: false, error: "Connexion TCP vers \(settings.destinationLabel) perdue\u{00A0}; nouvel essai dans \(Int(Self.retryDelay))\u{00A0}s.", connected: false)
            }
        }
    }

    private func destination() -> IPv4Address? {
        if let resolved { return resolved }
        let value = IPv4Address(settings.trimmedHost) ?? resolver(settings.trimmedHost)
        resolved = value
        return value
    }

    private func closeSockets() {
        if udpFD >= 0 { close(udpFD); udpFD = -1 }
        if tcpFD >= 0 { close(tcpFD); tcpFD = -1 }
    }

    /// Résolution d'un nom en IPv4 (getaddrinfo) ; nil si introuvable.
    public static func resolve(_ host: String) -> IPv4Address? {
        if let address = IPv4Address(host) { return address }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let sockaddrPointer = first.pointee.ai_addr else { return nil }
        return sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            IPv4Address(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
        }
    }
}
