import Darwin
import Foundation

// Note 78 : protocole de contrôle d'iperf3, écrit à la main (aucune dépendance), pour le serveur
// intégré (`IperfServer`) et le client intégré (`IperfNativeClient`). Ce qui circule :
//
// - un « cookie » de 37 octets (36 caractères + NUL) envoyé par le client sur la connexion de
//   contrôle, puis sur chaque connexion de données (c'est ainsi que le serveur les reconnaît) ;
// - des états d'un octet signé (PARAM_EXCHANGE = 9, CREATE_STREAMS = 10, TEST_START = 1…) ;
// - des objets JSON précédés de leur longueur sur 4 octets (ordre réseau) : paramètres du test
//   envoyés par le client, résultats échangés à la fin.
//
// Seul le TCP est pris en charge (sens normal et inverse -R) ; l'UDP et le bidirectionnel sont
// refusés proprement (état SERVER_ERROR, comme un iperf3 qui ne connaît pas l'option).

/// États du protocole de contrôle (iperf_api.h).
public enum IperfState: Int8, Sendable, CaseIterable {
    case testStart = 1
    case testRunning = 2
    case resultRequest = 3
    case testEnd = 4
    case streamBegin = 5
    case streamRunning = 6
    case streamEnd = 7
    case allStreamsEnd = 8
    case paramExchange = 9
    case createStreams = 10
    case serverTerminate = 11
    case clientTerminate = 12
    case exchangeResults = 13
    case displayResults = 14
    case iperfStart = 15
    case iperfDone = 16
    case accessDenied = -1
    case serverError = -2

    /// Octet envoyé sur la connexion de contrôle.
    public var byte: UInt8 { UInt8(bitPattern: rawValue) }

    public init?(byte: UInt8) {
        self.init(rawValue: Int8(bitPattern: byte))
    }
}

/// Codes d'erreur d'iperf3 (`i_errno`) envoyés après SERVER_ERROR ; le client les traduit lui-même.
public enum IperfErrorCode: Int32, Sendable {
    /// « test duration valid values are 0 to … seconds ».
    case duration = 5
    /// « number of parallel streams too large ».
    case numStreams = 6
    /// « an option you are trying to set is not implemented yet » (UDP, bidirectionnel).
    case unimplemented = 13
}

/// Constantes et petites fonctions du protocole.
public enum IperfProtocol {
    public static let defaultPort: UInt16 = 5201
    public static let cookieSize = 37
    /// Taille des blocs TCP par défaut d'iperf3 (128 Kio).
    public static let defaultBlockSize = 131_072
    /// Longueur maximale d'un JSON accepté (les paramètres d'un vrai client font quelques centaines d'octets).
    public static let maxJSONLength = 1 << 20
    /// Version annoncée par le client intégré (champ « client_version »).
    public static let clientVersion = "3.17.1"

    private static let cookieAlphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    /// Cookie aléatoire : 36 caractères de l'alphabet d'iperf3, puis un NUL.
    public static func makeCookie() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<(cookieSize - 1)).map { _ in cookieAlphabet.randomElement(using: &generator)! } + [0]
    }

    /// Message JSON encadré : longueur sur 4 octets (big-endian), puis le texte UTF-8 (sans NUL).
    public static func frame(_ object: [String: Any]) throws -> [UInt8] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let length = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: length) { Array($0) } + [UInt8](data)
    }

    /// Longueur annoncée par les 4 premiers octets d'un message JSON.
    public static func frameLength(_ header: [UInt8]) throws -> Int {
        guard header.count == 4 else { throw IperfProtocolError.malformed("en-tête JSON incomplet") }
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard length > 0, length <= maxJSONLength else { throw IperfProtocolError.malformed("longueur JSON invalide (\(length))") }
        return length
    }

    /// Numéros des flux tels qu'iperf3 les attribue : 1, puis 3, 4, 5… (iperf_add_stream compte
    /// à partir de 2 et ajoute un par flux déjà présent). Les résultats échangés à la fin portent
    /// ces numéros : le serveur doit donner les mêmes que le client.
    public static func streamIDs(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return [1] + (0..<(count - 1)).map { $0 + 3 }
    }

    /// Adresse lisible d'un pair (« 10.10.0.20 », sans le préfixe IPv4 dans IPv6 « ::ffff: »).
    public static func displayAddress(_ text: String) -> String {
        text.lowercased().hasPrefix("::ffff:") && text.contains(".") ? String(text.dropFirst(7)) : text
    }
}

/// Erreurs du protocole (client et serveur intégrés).
public enum IperfProtocolError: Error, Equatable, LocalizedError, Sendable {
    case malformed(String)
    case unexpectedState(Int)
    case accessDenied
    case serverError(code: Int32, errno: Int32)
    case socket(String)
    case timeout(String)
    case unsupported(String)
    case cancelled
    case serverTerminated

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): return "Échange iperf3 illisible\u{00A0}: \(detail)."
        case .unexpectedState(let state): return "État iperf3 inattendu (\(state))."
        case .accessDenied: return "Le serveur iperf3 est occupé par un autre test\u{00A0}; réessayez dans un instant."
        case .serverError(let code, let errno):
            let detail: String
            switch IperfErrorCode(rawValue: code) {
            case .unimplemented: detail = "option non prise en charge par le serveur"
            case .duration: detail = "durée de test refusée par le serveur"
            case .numStreams: detail = "trop de flux pour le serveur"
            case nil: detail = "erreur \(code)"
            }
            return "Le serveur iperf3 a refusé le test (\(detail)\(errno != 0 ? ", errno \(errno)" : ""))."
        case .socket(let detail): return "Erreur réseau iperf3\u{00A0}: \(detail)."
        case .timeout(let step): return "Le serveur iperf3 ne répond pas (\(step))."
        case .unsupported(let detail): return detail
        case .cancelled: return "Test iperf3 arrêté."
        case .serverTerminated: return "Le serveur iperf3 a interrompu le test."
        }
    }
}

/// Paramètres d'un test, tels que le client les envoie (sous-ensemble utile au serveur).
public struct IperfTestParameters: Equatable, Sendable {
    public var tcp: Bool
    public var udp: Bool
    public var reverse: Bool
    public var bidirectional: Bool
    /// Durée demandée (secondes) ; 0 avec `bytes` ou `blocks` : arrêt à la quantité.
    public var time: Int
    public var bytes: Int64
    public var blocks: Int64
    public var parallel: Int
    public var blockSize: Int
    public var omit: Int
    public var clientVersion: String?

    public init(tcp: Bool = true, udp: Bool = false, reverse: Bool = false, bidirectional: Bool = false, time: Int = 10,
                bytes: Int64 = 0, blocks: Int64 = 0, parallel: Int = 1, blockSize: Int = IperfProtocol.defaultBlockSize,
                omit: Int = 0, clientVersion: String? = nil) {
        self.tcp = tcp
        self.udp = udp
        self.reverse = reverse
        self.bidirectional = bidirectional
        self.time = time
        self.bytes = bytes
        self.blocks = blocks
        self.parallel = parallel
        self.blockSize = blockSize
        self.omit = omit
        self.clientVersion = clientVersion
    }

    /// JSON envoyé par le client intégré (mêmes clés que send_parameters d'iperf3).
    public var json: [String: Any] {
        var object: [String: Any] = [
            "tcp": true, "omit": omit, "time": time, "num": bytes, "blockcount": blocks, "parallel": parallel,
            "len": blockSize, "pacing_timer": 1000, "client_version": clientVersion ?? IperfProtocol.clientVersion,
        ]
        if reverse { object["reverse"] = true }
        if bidirectional { object["bidirectional"] = true }
        if udp {
            object["tcp"] = nil
            object["udp"] = true
        }
        return object
    }

    /// Lecture du JSON d'un client (vrai iperf3 ou NetScope). Les booléens arrivent en `true` ou en 1.
    public static func parse(_ data: [UInt8]) throws -> IperfTestParameters {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any] else {
            throw IperfProtocolError.malformed("paramètres du test")
        }
        func flag(_ key: String) -> Bool {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? NSNumber { return value.intValue != 0 }
            return false
        }
        func integer(_ key: String) -> Int64 {
            if let value = object[key] as? NSNumber, value.doubleValue.isFinite { return value.int64Value }
            return 0
        }
        let udp = flag("udp")
        return IperfTestParameters(tcp: flag("tcp") || !udp, udp: udp, reverse: flag("reverse"),
                                   bidirectional: flag("bidirectional"),
                                   time: Int(clamping: integer("time")), bytes: integer("num"), blocks: integer("blockcount"),
                                   parallel: max(1, Int(clamping: integer("parallel"))),
                                   blockSize: object["len"] == nil ? IperfProtocol.defaultBlockSize : Int(clamping: integer("len")),
                                   omit: Int(clamping: integer("omit")), clientVersion: object["client_version"] as? String)
    }
}

/// Résultats d'un côté, échangés à la fin du test (send_results / get_results d'iperf3).
public struct IperfExchangedResults: Equatable, Sendable {
    public struct Stream: Equatable, Sendable {
        public var id: Int
        public var bytes: Int64
        /// -1 : inconnu (côté récepteur, ou émetteur sans compteur).
        public var retransmits: Int
        public var startTime: Double
        public var endTime: Double

        public init(id: Int, bytes: Int64, retransmits: Int = -1, startTime: Double = 0, endTime: Double) {
            self.id = id
            self.bytes = bytes
            self.retransmits = retransmits
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    public var cpuTotal: Double
    public var cpuUser: Double
    public var cpuSystem: Double
    /// 1 : l'émetteur donne ses retransmissions ; 0 : non ; -1 : ce côté n'émet pas.
    public var senderHasRetransmits: Int
    public var streams: [Stream]

    public init(cpuTotal: Double = 0, cpuUser: Double = 0, cpuSystem: Double = 0, senderHasRetransmits: Int,
                streams: [Stream]) {
        self.cpuTotal = cpuTotal
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.senderHasRetransmits = senderHasRetransmits
        self.streams = streams
    }

    public var totalBytes: Int64 { streams.reduce(0) { $0 + $1.bytes } }
    /// Durée la plus longue des flux (end_time - start_time).
    public var duration: Double { streams.map { $0.endTime - $0.startTime }.max() ?? 0 }

    /// JSON au format d'iperf3 : toutes les clés que get_results exige sont présentes.
    public var json: [String: Any] {
        [
            "cpu_util_total": cpuTotal, "cpu_util_user": cpuUser, "cpu_util_system": cpuSystem,
            "sender_has_retransmits": senderHasRetransmits,
            "streams": streams.map { stream in
                [
                    "id": stream.id, "bytes": stream.bytes, "retransmits": stream.retransmits, "jitter": 0,
                    "errors": 0, "omitted_errors": 0, "packets": 0, "omitted_packets": 0,
                    "start_time": stream.startTime, "end_time": stream.endTime,
                ] as [String: Any]
            },
        ]
    }

    public static func parse(_ data: [UInt8]) throws -> IperfExchangedResults {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]] else {
            throw IperfProtocolError.malformed("résultats du test")
        }
        func number(_ value: Any?) -> Double {
            guard let number = value as? NSNumber, number.doubleValue.isFinite else { return 0 }
            return number.doubleValue
        }
        func integer(_ value: Any?) -> Int64 {
            guard let number = value as? NSNumber, number.doubleValue.isFinite else { return 0 }
            return number.int64Value
        }
        guard object["sender_has_retransmits"] != nil else { throw IperfProtocolError.malformed("résultats sans sender_has_retransmits") }
        var parsed: [Stream] = []
        for stream in streams {
            guard stream["id"] != nil, stream["bytes"] != nil else { throw IperfProtocolError.malformed("flux sans numéro ou sans octets") }
            parsed.append(Stream(id: Int(clamping: integer(stream["id"])), bytes: max(0, integer(stream["bytes"])),
                                 retransmits: stream["retransmits"] == nil ? -1 : Int(clamping: integer(stream["retransmits"])),
                                 startTime: number(stream["start_time"]), endTime: number(stream["end_time"])))
        }
        return IperfExchangedResults(cpuTotal: number(object["cpu_util_total"]), cpuUser: number(object["cpu_util_user"]),
                                     cpuSystem: number(object["cpu_util_system"]),
                                     senderHasRetransmits: Int(clamping: integer(object["sender_has_retransmits"])),
                                     streams: parsed)
    }
}

/// Compteur d'octets d'un flux, lu par le fil de contrôle pendant que le fil du flux l'augmente.
final class IperfCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func add(_ count: Int) {
        lock.lock()
        value += Int64(count)
        lock.unlock()
    }

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Drapeau partagé entre fils (arrêt d'un flux, d'un test, du serveur).
final class IperfFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Temps processeur du processus (secondes utilisateur et système), pour cpu_util_*.
struct IperfCPUSample {
    let wall: Double
    let user: Double
    let system: Double

    static func now() -> IperfCPUSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return IperfCPUSample(wall: IperfClock.now(), user: seconds(usage.ru_utime), system: seconds(usage.ru_stime))
    }

    /// Pourcentages (total, utilisateur, système) depuis `start`.
    func utilization(since start: IperfCPUSample) -> (Double, Double, Double) {
        let wall = max(wall - start.wall, 0.001)
        let user = max(0, (self.user - start.user) / wall * 100)
        let system = max(0, (self.system - start.system) / wall * 100)
        return (user + system, user, system)
    }
}

/// Horloge monotone en secondes.
enum IperfClock {
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

/// Sockets BSD du client et du serveur intégrés (IPv4 et IPv6), en mode bloquant avec délais.
enum IperfSocket {
    static func errorText(_ context: String, _ code: Int32 = errno) -> String {
        "\(context) (\(String(cString: strerror(code))))"
    }

    static func configure(_ fd: Int32, timeout: Double) {
        let bounded = min(max(timeout, 0.05), 3_600)
        var tv = timeval(tv_sec: Int(bounded), tv_usec: Int32((bounded - floor(bounded)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connexion TCP (nom résolu par getaddrinfo, IPv4 d'abord) avec délai maximal.
    static func connect(host: String, port: UInt16, timeout: Double) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_family = AF_UNSPEC
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let first = list else {
            throw IperfProtocolError.socket("adresse « \(host) » introuvable (\(String(cString: gai_strerror(status))))")
        }
        defer { freeaddrinfo(list) }
        var candidates: [UnsafeMutablePointer<addrinfo>] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            candidates.append(entry)
            cursor = entry.pointee.ai_next
        }
        candidates.sort { ($0.pointee.ai_family == AF_INET ? 0 : 1) < ($1.pointee.ai_family == AF_INET ? 0 : 1) }
        var lastError = IperfProtocolError.socket("aucune adresse pour « \(host) »")
        for entry in candidates {
            let fd = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var ok = Darwin.connect(fd, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0
            if !ok && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, Int32(clamping: Int(timeout * 1000)))
                if ready > 0 {
                    var soError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                    if soError == 0 {
                        ok = true
                    } else {
                        lastError = .socket(errorText("connexion à \(host):\(port)", soError))
                    }
                } else {
                    lastError = .timeout("connexion à \(host):\(port)")
                }
            } else if !ok {
                lastError = .socket(errorText("connexion à \(host):\(port)"))
            }
            if ok {
                _ = fcntl(fd, F_SETFL, flags)
                configure(fd, timeout: timeout)
                var one: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                return fd
            }
            close(fd)
        }
        throw lastError
    }

    /// Écoute TCP : sur `bindAddress` (IPv4 ou IPv6) ou, sans adresse, sur toutes les interfaces
    /// (IPv6 double pile, IPv4 seul en repli). Renvoie le socket et le port réel.
    static func listen(port: UInt16, bindAddress: String?) throws -> (Int32, UInt16) {
        var one: Int32 = 1
        func finish(_ fd: Int32) throws -> (Int32, UInt16) {
            guard Darwin.listen(fd, 16) == 0 else {
                let text = errorText("écoute sur le port \(port)")
                close(fd)
                throw IperfProtocolError.socket(text)
            }
            return (fd, localPort(fd) ?? port)
        }
        if let bindAddress, !bindAddress.isEmpty {
            var v4 = in_addr()
            if inet_pton(AF_INET, bindAddress, &v4) == 1 {
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { throw IperfProtocolError.socket(errorText("socket")) }
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr = v4
                let bound = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard bound == 0 else {
                    let text = errorText("port \(port) indisponible")
                    close(fd)
                    throw IperfProtocolError.socket(text)
                }
                return try finish(fd)
            }
            throw IperfProtocolError.socket("adresse d’écoute invalide (\(bindAddress))")
        }
        let fd6 = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        if fd6 >= 0 {
            var zero: Int32 = 0
            setsockopt(fd6, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_any
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            if bound == 0 { return try finish(fd6) }
            let code = errno
            close(fd6)
            if code == EADDRINUSE { throw IperfProtocolError.socket(errorText("port \(port) déjà utilisé", code)) }
        }
        return try listen(port: port, bindAddress: "0.0.0.0")
    }

    static func localPort(_ fd: Int32) -> UInt16? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard ok == 0 else { return nil }
        return port(of: storage)
    }

    static func port(of storage: sockaddr_storage) -> UInt16? {
        var copy = storage
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
        case AF_INET6:
            return withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) } }
        default:
            return nil
        }
    }

    /// Adresse texte d'un pair (sockaddr_storage d'accept).
    static func address(of storage: sockaddr_storage) -> String {
        var copy = storage
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        switch Int32(storage.ss_family) {
        case AF_INET:
            withUnsafePointer(to: &copy) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    var addr = pointer.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
                }
            }
        case AF_INET6:
            withUnsafePointer(to: &copy) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    var addr = pointer.pointee.sin6_addr
                    _ = inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
                }
            }
        default:
            return "inconnu"
        }
        return IperfProtocol.displayAddress(String(cString: buffer))
    }

    /// Attend qu'un socket soit lisible (ms) ; faux au délai dépassé.
    static func waitReadable(_ fd: Int32, milliseconds: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, milliseconds) > 0
    }

    /// Lit exactement `count` octets ; `step` nomme l'étape dans le message d'erreur.
    static func readExactly(_ fd: Int32, _ count: Int, step: String) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = result.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: done), count - done, 0) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw IperfProtocolError.timeout(step) }
                throw IperfProtocolError.socket(errorText(step))
            }
            if n == 0 { throw IperfProtocolError.socket("connexion fermée (\(step))") }
            done += n
        }
        return result
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8], step: String) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw IperfProtocolError.timeout(step) }
                throw IperfProtocolError.socket(errorText(step))
            }
            offset += n
        }
    }

    static func readState(_ fd: Int32, step: String) throws -> UInt8 {
        try readExactly(fd, 1, step: step)[0]
    }

    static func writeState(_ fd: Int32, _ state: IperfState) throws {
        try writeAll(fd, [state.byte], step: "envoi de l’état \(state.rawValue)")
    }

    static func readJSON(_ fd: Int32, step: String) throws -> [UInt8] {
        let length = try IperfProtocol.frameLength(readExactly(fd, 4, step: step))
        return try readExactly(fd, length, step: step)
    }

    static func writeJSON(_ fd: Int32, _ object: [String: Any], step: String) throws {
        try writeAll(fd, IperfProtocol.frame(object), step: step)
    }
}

/// Fil d'un flux de données : lit (récepteur) ou écrit (émetteur) jusqu'à l'arrêt, en comptant.
final class IperfStreamWorker: @unchecked Sendable {
    let fd: Int32
    let id: Int
    let sending: Bool
    let blockSize: Int
    let counter = IperfCounter()
    let stop = IperfFlag()
    private let done = DispatchSemaphore(value: 0)
    private(set) var startTime: Double = 0
    private(set) var endTime: Double = 0

    init(fd: Int32, id: Int, sending: Bool, blockSize: Int) {
        self.fd = fd
        self.id = id
        self.sending = sending
        self.blockSize = min(max(blockSize, 1_024), 1 << 20)
        // Délai court : le fil voit l'arrêt même si l'autre bout ne lit plus ou n'écrit plus.
        IperfSocket.configure(fd, timeout: 0.25)
    }

    func start(at time: Double) {
        startTime = time
        let thread = Thread { [self] in
            run()
            endTime = IperfClock.now()
            done.signal()
        }
        thread.name = "NetScope – flux iperf3 \(id)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func run() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)
        defer { buffer.deallocate() }
        if sending {
            // Données aléatoires : un lien qui compresse ne fausse pas la mesure.
            arc4random_buf(buffer, blockSize)
            while !stop.isSet {
                let n = Darwin.send(fd, buffer, blockSize, 0)
                if n > 0 {
                    counter.add(n)
                } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        } else {
            while !stop.isSet {
                let n = recv(fd, buffer, blockSize, 0)
                if n > 0 {
                    counter.add(n)
                } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private let joinLock = NSLock()
    private var joined = false

    /// Arrête le flux et attend la fin de son fil (1 s au plus) ; sans effet la deuxième fois.
    func finish() {
        stop.set()
        joinLock.lock()
        defer { joinLock.unlock() }
        guard !joined, startTime > 0 else { return }
        joined = true
        _ = done.wait(timeout: .now() + 1)
    }

    func closeSocket() {
        close(fd)
    }
}
