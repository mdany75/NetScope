import Darwin
import Foundation

// Note 43 : récepteurs UDP de ce Mac (Syslog et traps SNMP), démarrés seulement à la demande.
//
// Ports : Syslog écoute normalement sur UDP 514 et les traps sur UDP 162. macOS (depuis 10.14)
// laisse une application ordinaire écouter sous 1024 à condition d'écouter sur toutes les
// interfaces ; certains Mac gérés (profil MDM, macOS plus ancien) le refusent encore et exigent les
// droits root. NetScope propose donc par défaut des ports au-dessus de 1024 (5514 et 1162), sans
// aucun droit particulier : il suffit de régler ce port sur l'équipement (commande montrée par l'écran).

/// Datagramme reçu.
public struct LogDatagram: Sendable {
    public var bytes: [UInt8]
    public var from: IPv4Address
    public var fromPort: UInt16
    public var date: Date

    public init(bytes: [UInt8], from: IPv4Address, fromPort: UInt16, date: Date) {
        self.bytes = bytes
        self.from = from
        self.fromPort = fromPort
        self.date = date
    }
}

/// Ouverture du port impossible, expliquée en clair.
public struct LogBindError: Error, Equatable, Sendable, LocalizedError {
    public var code: Int32
    public var port: UInt16

    public init(code: Int32, port: UInt16) {
        self.code = code
        self.port = port
    }

    public var isPermission: Bool { code == EACCES || code == EPERM }
    public var isInUse: Bool { code == EADDRINUSE }

    public var errorDescription: String? {
        if isInUse {
            return "Le port UDP \(port) est déjà utilisé (un autre serveur Syslog ou SNMP, ou une autre copie de NetScope)\u{00A0}: arrêtez-le ou choisissez un autre port."
        }
        if isPermission {
            return "macOS refuse le port UDP \(port)\u{00A0}: sous 1024, il faut les droits administrateur sur ce Mac. Choisissez un port au-dessus de 1024 (5514 pour Syslog, 1162 pour les traps) et réglez-le sur l’équipement."
        }
        return "Ouverture du port UDP \(port) impossible (\(String(cString: strerror(code))))."
    }
}

/// Récepteur UDP : un socket, un fil d'écoute ; chaque datagramme est passé à `handler`.
public final class LogUDPListener: @unchecked Sendable {
    public let requestedPort: UInt16
    /// Adresse d'écoute : nil pour toutes les interfaces (127.0.0.1 dans les tests).
    public let address: IPv4Address?
    private let handler: @Sendable (LogDatagram) -> Void
    private let stopped: @Sendable (String?) -> Void
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private var finished: DispatchSemaphore?
    public private(set) var boundPort: UInt16 = 0
    private let name: String

    public init(port: UInt16, address: IPv4Address? = nil, name: String = "Journaux",
                handler: @escaping @Sendable (LogDatagram) -> Void, stopped: @escaping @Sendable (String?) -> Void = { _ in }) {
        requestedPort = port
        self.address = address
        self.name = name
        self.handler = handler
        self.stopped = stopped
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Ouvre le port et écoute. Port 0 : port libre choisi par macOS (tests).
    public func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        lock.unlock()
        let (socketFD, port) = try Self.bind(address: address, port: requestedPort)
        let done = DispatchSemaphore(value: 0)
        lock.lock()
        fd = socketFD
        boundPort = port
        running = true
        finished = done
        lock.unlock()
        let thread = Thread { [self] in
            listen(socketFD)
            done.signal()
        }
        thread.name = "\(name) écoute \(port)"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Arrête l'écoute et attend la fermeture du socket (au plus un tour d'attente, 250 ms).
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

    /// Répond depuis le port d'écoute (accusé d'un InformRequest).
    @discardableResult
    public func reply(_ bytes: [UInt8], to address: IPv4Address, port: UInt16) -> Bool {
        lock.lock()
        let socketFD = fd
        let isOn = running
        lock.unlock()
        guard isOn, socketFD >= 0 else { return false }
        return Self.send(socketFD, bytes, to: address, port: port)
    }

    private var shouldRun: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func listen(_ socketFD: Int32) {
        defer {
            close(socketFD)
            lock.lock()
            if fd == socketFD { fd = -1 }
            lock.unlock()
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while shouldRun {
            var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 250)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                let message = String(cString: strerror(errno))
                lock.lock()
                let wasRunning = running
                running = false
                lock.unlock()
                if wasRunning { stopped("Écoute interrompue\u{00A0}: \(message)") }
                return
            }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            guard count > 0 else { continue }
            handler(LogDatagram(bytes: Array(buffer[0..<count]), from: IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr)),
                                fromPort: UInt16(bigEndian: from.sin_port), date: Date()))
        }
    }

    static func bind(address: IPv4Address?, port: UInt16) throws -> (Int32, UInt16) {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw LogBindError(code: errno, port: port) }
        var one: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Rafales de messages (un switch qui redémarre) : grand tampon de réception.
        var size: Int32 = 4 << 20
        setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: (address?.value ?? 0).bigEndian)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(socketFD)
            throw LogBindError(code: code, port: port)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        return (socketFD, UInt16(bigEndian: bound.sin_port))
    }

    static func send(_ socketFD: Int32, _ bytes: [UInt8], to address: IPv4Address, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: address.value.bigEndian)
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketFD, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent == bytes.count
    }

    /// Envoie un datagramme d'essai à ce Mac (127.0.0.1 seulement) : vérifie que le récepteur répond.
    @discardableResult
    public static func sendToSelf(_ bytes: [UInt8], port: UInt16) -> Bool {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        return send(socketFD, bytes, to: IPv4Address(127, 0, 0, 1), port: port)
    }

    /// Envoie à 127.0.0.1 et attend une réponse (inform) au plus `timeout` secondes (tests).
    public static func exchangeWithSelf(_ bytes: [UInt8], port: UInt16, timeout: TimeInterval) -> [UInt8]? {
        guard let (socketFD, _) = try? bind(address: IPv4Address(127, 0, 0, 1), port: 0) else { return nil }
        defer { close(socketFD) }
        guard send(socketFD, bytes, to: IPv4Address(127, 0, 0, 1), port: port) else { return nil }
        var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = recv(socketFD, &buffer, buffer.count, 0)
        return count > 0 ? Array(buffer[0..<count]) : nil
    }
}

/// Récepteur des journaux : décode chaque datagramme (Syslog ou trap) en message.
public enum LogDecoder {
    public enum Outcome: Sendable {
        case message(LogMessage, reply: [UInt8]?)
        /// Datagramme écarté (trap illisible, SNMPv3, communauté refusée), avec la raison.
        case rejected(String)
    }

    public static func syslog(_ datagram: LogDatagram) -> Outcome {
        .message(SyslogParser.parse(datagram.bytes, from: datagram.from.description, received: datagram.date), reply: nil)
    }

    /// `community` : communauté attendue (nil : toutes acceptées).
    public static func trap(_ datagram: LogDatagram, community: String?) -> Outcome {
        do {
            let trap = try SNMPTrapDecoder.decode(datagram.bytes)
            if let community, !community.isEmpty, trap.community != community {
                return .rejected("trap de \(datagram.from) écartée\u{00A0}: communauté différente de celle des Identifiants")
            }
            let message = SNMPTrapCatalog.message(for: trap, from: datagram.from.description, received: datagram.date)
            return .message(message, reply: SNMPTrapDecoder.informResponse(to: trap))
        } catch {
            let reason = (error as? SNMPDecodingError)?.message ?? error.localizedDescription
            return .rejected("trap illisible de \(datagram.from)\u{00A0}: \(reason)")
        }
    }
}

// MARK: - Coupe-feu de macOS

public extension TFTPFirewallStatus {
    /// Avertissement pour les récepteurs de journaux, ou nil si le coupe-feu ne gêne pas.
    var logWarning: String? {
        guard enabled else { return nil }
        if blockAll {
            return "Le coupe-feu de macOS bloque toutes les connexions entrantes\u{00A0}: aucun message Syslog ni aucune trap n’arrivera. Désactivez «\u{00A0}Bloquer toutes les connexions entrantes\u{00A0}» dans Réglages Système › Réseau › Coupe-feu le temps de l’enquête."
        }
        switch app {
        case .blocked:
            return "Le coupe-feu de macOS bloque les connexions entrantes vers NetScope\u{00A0}: autorisez NetScope dans Réglages Système › Réseau › Coupe-feu › Options, sinon les messages des équipements n’arriveront pas."
        case .unknown:
            return "Le coupe-feu de macOS est actif\u{00A0}: au premier démarrage, macOS demandera d’accepter les connexions entrantes pour NetScope. Répondez «\u{00A0}Autoriser\u{00A0}»."
        case .allowed:
            return nil
        }
    }
}

// MARK: - Commandes à régler sur les équipements

/// Commandes à saisir sur l'équipement pour envoyer ses journaux et ses traps à ce Mac.
public enum LogDeviceCommands {
    public struct Example: Sendable, Hashable, Identifiable {
        public var id: String { title }
        public var title: String
        public var text: String
    }

    public static func syslog(mac: String, port: UInt16) -> [Example] {
        [
            Example(title: "FortiGate (FortiOS)", text: """
            config log syslogd setting
                set status enable
                set server "\(mac)"
                set port \(port)
                set mode udp
                set format default
            end
            """),
            Example(title: "FortiSwitch", text: """
            config log syslogd setting
                set status enable
                set server "\(mac)"
                set port \(port)
            end
            """),
            Example(title: "Cisco IOS", text: "logging host \(mac) transport udp port \(port)\nlogging trap informational"),
            Example(title: "HPE Aruba (AOS-S)", text: "logging \(mac) udp \(port)\nlogging severity info"),
            Example(title: "Linux (rsyslog)", text: "*.* @\(mac):\(port)"),
        ]
    }

    public static func traps(mac: String, port: UInt16) -> [Example] {
        [
            Example(title: "FortiGate (FortiOS)", text: """
            config system snmp community
                edit 1
                    set name "<communauté>"
                    config hosts
                        edit 1
                            set ip \(mac) 255.255.255.255
                            set host-type trap
                        next
                    end
                    set trap-v2c-status enable
                    set trap-v2c-rport \(port)
                next
            end
            """),
            Example(title: "Cisco IOS", text: "snmp-server enable traps snmp linkdown linkup coldstart\nsnmp-server host \(mac) version 2c <communauté> udp-port \(port)"),
            Example(title: "HPE Aruba (AOS-S)", text: "snmp-server host \(mac) community <communauté> trap-level all"),
        ]
    }
}
