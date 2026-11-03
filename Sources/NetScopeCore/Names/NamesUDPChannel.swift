import Darwin
import Foundation

/// Destination UDP : adresse et port.
public struct NamesEndpoint: Hashable, Sendable, CustomStringConvertible {
    public var address: IPv4Address
    public var port: UInt16

    public init(_ address: IPv4Address, port: UInt16) {
        self.address = address
        self.port = port
    }

    /// Groupe multicast mDNS (224.0.0.251:5353).
    public static let mdnsMulticast = NamesEndpoint(IPv4Address(224, 0, 0, 251), port: 5353)

    public var description: String { "\(address):\(port)" }
}

/// Socket UDP partagé par de nombreuses requêtes simultanées.
///
/// Chaque requête enregistre un « filtre » ; tout datagramme reçu est proposé aux requêtes en
/// attente, et chacune dont le filtre l'accepte reprend avec ce datagramme. Une requête sans
/// réponse reprend avec `nil` après son délai (ou dès que sa tâche est annulée).
final class NamesUDPChannel: @unchecked Sendable {
    typealias Matcher = @Sendable (_ packet: [UInt8], _ source: IPv4Address) -> Bool

    /// Un envoi, éventuellement différé (repli multicast si l'unicast reste muet).
    struct Send: Sendable {
        var delay: Duration
        var bytes: [UInt8]
        var destination: NamesEndpoint
    }

    private struct Pending {
        let matcher: Matcher
        let continuation: CheckedContinuation<[UInt8]?, Never>
    }

    private let fd: Int32
    private let readQueue = DispatchQueue(label: "netscope.names.udp.read")
    private let timerQueue = DispatchQueue(label: "netscope.names.udp.timer")
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var pending: [UInt64: Pending] = [:]
    private var nextToken: UInt64 = 0
    private var nextID: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ToolSocket.lastError("socket UDP") }
        var address = ToolSocket.address(IPv4Address(0), port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let error = ToolSocket.lastError("bind UDP")
            close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        // mDNS recommande un TTL de 255 ; le groupe 224.0.0.251 ne franchit de toute façon aucun routeur.
        var ttl: UInt8 = 255
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var loop: UInt8 = 0
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        self.fd = fd
        nextID = UInt16.random(in: 1...UInt16.max)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    /// Nouvel identifiant de transaction (jamais 0).
    func makeTransactionID() -> UInt16 {
        locked {
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            return nextID
        }
    }

    /// Envoie `sends` et attend le premier datagramme accepté par `matcher`.
    func request(_ sends: [Send], timeout: Duration, matcher: @escaping Matcher) async -> [UInt8]? {
        let token: UInt64 = locked {
            nextToken += 1
            return nextToken
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
                locked { pending[token] = Pending(matcher: matcher, continuation: continuation) }
                for send in sends {
                    if send.delay <= .zero {
                        transmit(send)
                    } else {
                        timerQueue.asyncAfter(deadline: .now() + .nanoseconds(Self.nanoseconds(send.delay))) { [self] in
                            if isPending(token) { transmit(send) }
                        }
                    }
                }
                timerQueue.asyncAfter(deadline: .now() + .nanoseconds(Self.nanoseconds(timeout))) { [self] in
                    finish(token, with: nil)
                }
                if Task.isCancelled { finish(token, with: nil) }
            }
        } onCancel: {
            finish(token, with: nil)
        }
    }

    // MARK: - Interne

    private static func nanoseconds(_ duration: Duration) -> Int {
        Int(min(duration.scanNanoseconds, UInt64(Int.max)))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func isPending(_ token: UInt64) -> Bool {
        locked { pending[token] != nil }
    }

    private func finish(_ token: UInt64, with packet: [UInt8]?) {
        let entry: Pending? = locked { pending.removeValue(forKey: token) }
        entry?.continuation.resume(returning: packet)
    }

    private func transmit(_ send: Send) {
        var address = ToolSocket.address(send.destination.address, port: send.destination.port)
        // Une erreur d'envoi (hôte injoignable, pas de route multicast) revient à une absence de réponse.
        _ = send.bytes.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Lit tous les datagrammes disponibles (socket non bloquant).
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 9000)
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &length)
                    }
                }
            }
            guard count > 0 else { return }
            deliver(Array(buffer[0..<count]), from: IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr)))
        }
    }

    private func deliver(_ packet: [UInt8], from sourceAddress: IPv4Address) {
        let matched: [Pending] = locked {
            let tokens = pending.filter { $0.value.matcher(packet, sourceAddress) }.map(\.key)
            return tokens.compactMap { pending.removeValue(forKey: $0) }
        }
        for entry in matched { entry.continuation.resume(returning: packet) }
    }
}

/// Crée le socket partagé à la première requête (et réessaie plus tard s'il n'a pas pu s'ouvrir).
final class NamesChannelProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: NamesUDPChannel?

    func get() -> NamesUDPChannel? {
        lock.lock()
        defer { lock.unlock() }
        if channel == nil { channel = try? NamesUDPChannel() }
        return channel
    }
}

/// Mise en forme des noms d'hôtes trouvés.
public enum NamesFormat {
    /// Retire espaces et points finaux ; rejette un nom vide ou qui répète l'adresse.
    public static func clean(_ name: String, for ip: IPv4Address? = nil) -> String? {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") { result.removeLast() }
        if result.isEmpty { return nil }
        if let ip, result == ip.description { return nil }
        return result
    }

    /// Nom à afficher : « Macmini-de-Dany.local » → « Macmini-de-Dany » si `stripLocal`.
    public static func display(_ name: String, stripLocal: Bool = true) -> String {
        var result = name
        while result.hasSuffix(".") { result.removeLast() }
        if stripLocal, result.lowercased().hasSuffix(".local"), result.count > 6 {
            result.removeLast(6)
        }
        return result
    }
}
