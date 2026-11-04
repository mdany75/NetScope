import Darwin
import Foundation

/// Erreurs communes des outils réseau (sockets, délais, commandes système).
public enum ToolError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case socket(String)
    case timeout(TimeInterval)
    case toolMissing(String)
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let text): return text
        case .socket(let text): return "Erreur réseau : \(text)"
        case .timeout(let seconds): return "Aucune réponse après \(ToolFormat.seconds(seconds))."
        case .toolMissing(let path): return "Outil système introuvable : \(path)."
        case .processFailed(let text): return text
        }
    }
}

/// Mise en forme des nombres à la française (virgule décimale, espace insécable).
public enum ToolFormat {
    public static func decimal(_ value: Double, digits: Int = 1) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    public static func integer<T: BinaryInteger>(_ value: T) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: Int64(clamping: value))) ?? "\(value)")
            .replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")
    }

    /// « 2,8 s », « 450 ms ».
    public static func seconds(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "—" }
        return value < 1 ? "\((value * 1000).clampedInt)\u{00A0}ms" : "\(decimal(value))\u{00A0}s"
    }

    /// « 1,8 ms », « 12 ms ».
    public static func milliseconds(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value < 10 ? "\(decimal(value))\u{00A0}ms" : "\(value.clampedInt)\u{00A0}ms"
    }
}

/// Petites fonctions autour des sockets BSD (UDP et TCP IPv4).
enum ToolSocket {
    static func address(_ ip: IPv4Address, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: ip.value.bigEndian)
        return addr
    }

    static func lastError(_ context: String) -> ToolError {
        .socket("\(context) (\(String(cString: strerror(errno))))")
    }

    static func setTimeouts(_ fd: Int32, _ timeout: TimeInterval) {
        // Délai borné (0 à un jour) : un délai NaN, infini ou démesuré ne fait plus planter Int(…) ni Int32(…).
        let bounded = timeout.isFinite ? min(max(timeout, 0), 86_400) : 3
        var tv = timeval(tv_sec: Int(bounded), tv_usec: Int32((bounded - floor(bounded)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func connect(_ fd: Int32, to addr: sockaddr_in) -> Int32 {
        var copy = addr
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Connexion TCP avec délai maximal (socket non bloquant + poll), puis retour en mode bloquant.
    static func connectTCP(_ ip: IPv4Address, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw lastError("socket TCP") }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if connect(fd, to: address(ip, port: port)) != 0 {
            guard errno == EINPROGRESS else {
                let error = lastError("connexion à \(ip):\(port)")
                close(fd)
                throw error
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(clamping: max(0, (timeout * 1000).rounded(.towardZero).clampedInt)))
            if ready <= 0 {
                close(fd)
                throw ToolError.timeout(timeout)
            }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
            if soError != 0 {
                close(fd)
                throw ToolError.socket("connexion à \(ip):\(port) (\(String(cString: strerror(soError))))")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        setTimeouts(fd, timeout)
        return fd
    }

    /// Lit exactement `count` octets (TCP).
    static func readExactly(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: max(count, 1))
        while result.count < count {
            let n = recv(fd, &buffer, count - result.count, 0)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw ToolError.socket("délai de lecture dépassé") }
                throw lastError("lecture")
            }
            if n == 0 { throw ToolError.socket("connexion fermée par le serveur") }
            result.append(contentsOf: buffer[0..<n])
        }
        return result
    }

    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { throw lastError("envoi") }
            offset += n
        }
    }
}

/// Exécute une commande système (/usr/bin/…) et renvoie sa sortie standard, avec délai maximal.
enum ToolProcess {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw ToolError.toolMissing(path) }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            process.standardInput = FileHandle.nullDevice
            let collected = ToolBox<Data>(Data())
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { collected.mutate { $0.append(chunk) } }
            }
            let once = ToolOnce()
            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                let rest = output.fileHandleForReading.readDataToEndOfFile()
                collected.mutate { $0.append(rest) }
                guard once.claim() else { return }
                let text = String(decoding: collected.value, as: UTF8.self)
                if finished.terminationStatus != 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: ToolError.processFailed("\(path) a échoué (code \(finished.terminationStatus))."))
                } else {
                    continuation.resume(returning: text)
                }
            }
            do {
                try process.run()
            } catch {
                if once.claim() { continuation.resume(throwing: ToolError.processFailed(error.localizedDescription)) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                process.terminate()
                continuation.resume(throwing: ToolError.timeout(timeout))
            }
        }
    }
}

/// Garde « une seule fois » (reprise d'une continuation depuis plusieurs rappels).
final class ToolOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Valeur protégée par un verrou.
final class ToolBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
