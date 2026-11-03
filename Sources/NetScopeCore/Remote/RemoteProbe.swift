import Foundation
import Network

/// Joignabilité d'une connexion : ouverture TCP vers hôte:port, à la demande seulement.
public enum RemoteProbe {
    /// Vrai si une connexion TCP s'établit avant `timeout` secondes (elle est refermée aussitôt).
    public static func tcp(host: String, port: Int, timeout: TimeInterval = 2) async -> Bool {
        guard (try? RemoteValidator.validateHost(host)) != nil,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let once = OnceFlag()
            let queue = DispatchQueue(label: "netscope.remote.probe")
            @Sendable func finish(_ value: Bool) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Joignabilité d'une connexion enregistrée ; pour la série, présence du périphérique.
    public static func check(_ connection: RemoteConnection, timeout: TimeInterval = 2,
                             fileManager: FileManager = .default) async -> Bool {
        if connection.proto == .serie { return fileManager.fileExists(atPath: connection.host) }
        return await tcp(host: connection.host, port: connection.port, timeout: timeout)
    }
}

/// Appareil du scan proposé à l'import (ports 22, 23, 3389 ou 5900 ouverts).
public struct RemoteImportCandidate: Identifiable, Hashable, Sendable {
    public var id: String { "\(ip)-\(proto.rawValue)" }
    public var name: String
    public var vendor: String
    public var ip: String
    /// Ports d'accès distant ouverts, triés.
    public var ports: [UInt16]
    public var proto: RemoteProtocol
    public var port: Int
    /// Une connexion de même protocole existe déjà pour cette IP.
    public var alreadySaved: Bool

    public func connection(folder: String = RemoteImport.folder) -> RemoteConnection {
        RemoteConnection(name: name, proto: proto, host: ip, port: port, folder: folder,
                         note: vendor == OUIDatabase.unknownLabel ? "" : vendor)
    }
}

public enum RemoteImport {
    public static let ports: [UInt16] = [22, 23, 3389, 5900]
    public static let folder = "Importés du scan"

    /// Protocole proposé : RDP pour un poste Windows (3389), sinon SSH, VNC, puis Telnet.
    public static func proposedProtocol(for ports: [UInt16]) -> RemoteProtocol? {
        for port in [UInt16(3389), 22, 5900, 23] where ports.contains(port) { return RemoteProtocol.forPort(port) }
        return nil
    }

    public static func candidates(from devices: [Device], existing: [RemoteConnection]) -> [RemoteImportCandidate] {
        devices.compactMap { device in
            let open = device.openPorts.filter { ports.contains($0) }.sorted()
            guard let proto = proposedProtocol(for: open) else { return nil }
            let ip = device.ip.description
            let saved = existing.contains { $0.host == ip && $0.proto == proto }
            return RemoteImportCandidate(name: device.displayName, vendor: device.vendorLabel, ip: ip, ports: open,
                                         proto: proto, port: proto.defaultPort, alreadySaved: saved)
        }
        .sorted { lhs, rhs in
            let l = IPv4Address(lhs.ip), r = IPv4Address(rhs.ip)
            if let l, let r { return l < r }
            return lhs.ip < rhs.ip
        }
    }
}
