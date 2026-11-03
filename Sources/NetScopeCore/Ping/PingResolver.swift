import Darwin
import Foundation

/// Résolution des cibles (getaddrinfo), des sauts (getnameinfo) et lecture de la passerelle par défaut.
public enum PingResolver {
    /// Adresse IPv4 d'une cible : notation pointée directe (aucune requête), sinon getaddrinfo.
    public static func resolve(_ host: String) throws -> IPv4Address {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = IPv4Address(trimmed) { return address }
        guard !trimmed.isEmpty else { throw PingError.resolution(host: host, message: "nom vide") }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(trimmed, nil, &hints, &result)
        defer { if let result { freeaddrinfo(result) } }
        guard status == 0 else {
            throw PingError.resolution(host: trimmed, message: String(cString: gai_strerror(status)))
        }
        var cursor = result
        while let entry = cursor {
            if entry.pointee.ai_family == AF_INET, let raw = entry.pointee.ai_addr {
                let address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                return IPv4Address(UInt32(bigEndian: address))
            }
            cursor = entry.pointee.ai_next
        }
        throw PingError.resolution(host: trimmed, message: "aucune adresse IPv4")
    }

    /// Version asynchrone (la résolution DNS peut bloquer).
    public static func resolveAsync(_ host: String) async throws -> IPv4Address {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try resolve(host)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Nom inverse (PTR) d'une adresse ; nil s'il n'y en a pas.
    public static func reverse(_ address: IPv4Address) -> String? {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_addr = in_addr(s_addr: address.value.bigEndian)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        let name = String(cString: host)
        return name.isEmpty || name == address.description ? nil : name
    }

    public static func reverseAsync(_ address: IPv4Address) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: reverse(address)) }
        }
    }

    // MARK: Passerelle par défaut

    /// Passerelle de la route par défaut, lue par « route -n get default » (table locale, aucun trafic).
    public static func defaultGateway() -> IPv4Address? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseGateway(routeOutput: String(decoding: data, as: UTF8.self))
    }

    public static func defaultGatewayAsync() async -> IPv4Address? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: defaultGateway()) }
        }
    }

    /// Ligne « gateway: 10.182.122.1 » de la sortie de route ; nil si la route passe par un lien.
    public static func parseGateway(routeOutput: String) -> IPv4Address? {
        for line in routeOutput.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "gateway" { return IPv4Address(parts[1]) }
        }
        return nil
    }
}
