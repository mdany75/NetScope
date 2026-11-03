import Darwin
import Foundation

/// Agent SNMP à interroger. La communauté n'a pas de valeur par défaut : jamais « public » sans
/// que l'utilisateur l'ait saisie.
public struct SNMPTarget: Hashable, Sendable {
    public var host: IPv4Address
    public var port: UInt16
    public var community: String
    /// Délai d'attente d'une réponse, en secondes.
    public var timeout: TimeInterval
    /// Nombre de renvois après le premier envoi.
    public var retries: Int

    public init(host: IPv4Address, port: UInt16 = 161, community: String, timeout: TimeInterval = 2, retries: Int = 1) {
        self.host = host
        self.port = port
        self.community = community
        self.timeout = timeout
        self.retries = retries
    }
}

public enum SNMPError: Error, Equatable, LocalizedError {
    case emptyCommunity
    case timeout(String)
    case unreachable(String)
    case socket(String)
    case agent(status: Int, index: Int)
    case unexpectedResponse
    case v3NotSupported

    public var errorDescription: String? {
        switch self {
        case .emptyCommunity: return "Saisissez la communauté SNMP (lecture seule) avant d’interroger."
        case .timeout(let host): return "Pas de réponse SNMP de \(host) (communauté incorrecte, SNMP désactivé ou filtré ?)."
        case .unreachable(let host): return "\(host) refuse le port UDP 161 : SNMP n’est pas actif."
        case .socket(let message): return "Erreur réseau : \(message)."
        case .agent(let status, _):
            let label = SNMPErrorStatus(rawValue: status)?.label ?? "erreur \(status)"
            return "L’agent SNMP a répondu par une erreur : \(label)."
        case .unexpectedResponse: return "Réponse SNMP inattendue."
        case .v3NotSupported: return "SNMP v3 n’est pas encore pris en charge (bientôt)."
        }
    }
}

/// Client SNMP v2c minimal sur UDP (sockets BSD, une socket par requête).
public final class SNMPClient: Sendable {
    public let target: SNMPTarget

    public init(target: SNMPTarget) {
        self.target = target
    }

    // MARK: Requêtes

    public func get(_ oids: [SNMPOID]) async throws -> [SNMPVarBind] {
        try await request(SNMPPDU(type: .getRequest, requestID: Self.newRequestID(), varbinds: oids.map { SNMPVarBind(oid: $0) })).varbinds
    }

    public func getNext(_ oids: [SNMPOID]) async throws -> [SNMPVarBind] {
        try await request(SNMPPDU(type: .getNextRequest, requestID: Self.newRequestID(), varbinds: oids.map { SNMPVarBind(oid: $0) })).varbinds
    }

    public func getBulk(_ oids: [SNMPOID], nonRepeaters: Int = 0, maxRepetitions: Int = 25) async throws -> [SNMPVarBind] {
        try await request(.getBulk(requestID: Self.newRequestID(), nonRepeaters: nonRepeaters,
                                   maxRepetitions: maxRepetitions, oids: oids)).varbinds
    }

    /// Parcourt toute la sous-arborescence `root` (GetBulk, ordre lexicographique).
    /// Un objet absent donne une liste vide ; `limit` borne le nombre de lignes.
    public func walk(_ root: SNMPOID, maxRepetitions: Int = 25, limit: Int = 20_000) async throws -> [SNMPVarBind] {
        var result: [SNMPVarBind] = []
        var current = root
        var repetitions = max(1, maxRepetitions)
        while result.count < limit {
            try Task.checkCancellation()
            let response = try await request(.getBulk(requestID: Self.newRequestID(), maxRepetitions: repetitions, oids: [current]),
                                             checkStatus: false)
            if response.errorStatus == SNMPErrorStatus.tooBig.rawValue, repetitions > 1 {
                repetitions = max(1, repetitions / 2)
                continue
            }
            if response.errorStatus == SNMPErrorStatus.noSuchName.rawValue { break }
            if response.errorStatus != 0 {
                throw SNMPError.agent(status: response.errorStatus, index: response.errorIndex)
            }
            guard !response.varbinds.isEmpty else { break }
            var finished = false
            for bind in response.varbinds {
                if bind.value == .endOfMibView || !bind.oid.hasPrefix(root) || bind.oid <= current {
                    finished = true
                    break
                }
                if !bind.value.isException { result.append(bind) }
                current = bind.oid
            }
            if finished { break }
        }
        return result
    }

    /// Envoie une PDU et attend la réponse correspondante (même request-id).
    public func request(_ pdu: SNMPPDU, checkStatus: Bool = true) async throws -> SNMPPDU {
        guard !target.community.isEmpty else { throw SNMPError.emptyCommunity }
        try Task.checkCancellation()
        let message = SNMPMessage(community: target.community, pdu: pdu)
        let target = self.target
        let response: SNMPPDU = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try SNMPClient.transact(message.encoded(), requestID: pdu.requestID, target: target) })
            }
        }
        if checkStatus, response.errorStatus != 0 {
            throw SNMPError.agent(status: response.errorStatus, index: response.errorIndex)
        }
        return response
    }

    static func newRequestID() -> Int32 { Int32.random(in: 1...Int32.max) }

    // MARK: Socket UDP

    /// Envoi bloquant avec délai et renvois ; ignore les datagrammes qui ne répondent pas à `requestID`.
    static func transact(_ bytes: [UInt8], requestID: Int32, target: SNMPTarget) throws -> SNMPPDU {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SNMPError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = target.port.bigEndian
        address.sin_addr = in_addr(s_addr: target.host.value.bigEndian)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw SNMPError.socket(String(cString: strerror(errno))) }

        var buffer = [UInt8](repeating: 0, count: 65_535)
        for _ in 0...min(max(0, target.retries), 5) {
            let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if sent < 0, errno == ECONNREFUSED { throw SNMPError.unreachable(target.host.description) }
            guard sent == bytes.count else { throw SNMPError.socket(String(cString: strerror(errno))) }
            // Délai borné (0,1 à 60 s) : jamais d'attente infinie ni de dépassement d'Int32 dans poll().
            let deadline = Date().addingTimeInterval(min(max(target.timeout, 0.1), 60))
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, Int32(max(1, remaining * 1000)))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw SNMPError.socket(String(cString: strerror(errno)))
                }
                if ready == 0 { break }
                let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if count < 0 {
                    if errno == ECONNREFUSED { throw SNMPError.unreachable(target.host.description) }
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw SNMPError.socket(String(cString: strerror(errno)))
                }
                guard let message = try? SNMPMessage(decoding: Array(buffer[0..<count])),
                      message.pdu.requestID == requestID else { continue }
                guard message.pdu.type == .response else { throw SNMPError.unexpectedResponse }
                return message.pdu
            }
        }
        throw SNMPError.timeout(target.host.description)
    }
}
