import Darwin
import Foundation

/// Agent SNMP à interroger. La communauté n'a pas de valeur par défaut : jamais « public » sans
/// que l'utilisateur l'ait saisie.
///
/// Note 59 : avec `v3`, chaque requête part en SNMP v3 (USM). Si une communauté est aussi donnée,
/// elle sert de repli quand l'agent ne répond pas en v3 (équipement resté en v2c) ; la version
/// qui a fonctionné est retenue un moment pour cet agent (`SNMPVersionMemo`).
public struct SNMPTarget: Hashable, Sendable {
    public var host: IPv4Address
    public var port: UInt16
    public var community: String
    /// Identifiant SNMP v3 (prioritaire sur la communauté) ; nil : SNMP v2c seulement.
    public var v3: SNMPv3Credentials?
    /// Délai d'attente d'une réponse, en secondes.
    public var timeout: TimeInterval
    /// Nombre de renvois après le premier envoi.
    public var retries: Int

    public init(host: IPv4Address, port: UInt16 = 161, community: String, v3: SNMPv3Credentials? = nil,
                timeout: TimeInterval = 2, retries: Int = 1) {
        self.host = host
        self.port = port
        self.community = community
        self.v3 = v3
        self.timeout = timeout
        self.retries = retries
    }

    /// Vrai si la cible porte au moins un identifiant (communauté ou utilisateur v3).
    public var hasCredentials: Bool { !community.isEmpty || v3 != nil }

    /// Même agent avec un contexte SNMP (v3 : contextName ; v2c : « communauté@contexte », usage Cisco).
    public func withContext(vlan: Int) -> SNMPTarget {
        var copy = self
        if !copy.community.isEmpty { copy.community = "\(community)@\(vlan)" }
        copy.v3?.context = "vlan-\(vlan)"
        return copy
    }

    /// « v3 authPriv », « v2c » ou « v3 (repli v2c) » : version prévue pour cet agent.
    public var versionLabel: String {
        guard let v3 else { return "v2c" }
        if !community.isEmpty, SNMPVersionMemo.shared.prefersV2c(self) { return "v2c (repli)" }
        return "v3 \(v3.level.rawValue)"
    }
}

public enum SNMPError: Error, Equatable, LocalizedError {
    case emptyCommunity
    case timeout(String)
    case unreachable(String)
    case socket(String)
    case agent(status: Int, index: Int)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .emptyCommunity: return "Saisissez la communauté SNMP (lecture seule) ou un utilisateur SNMP v3 avant d’interroger."
        case .timeout(let host): return "Pas de réponse SNMP de \(host) (identifiants incorrects, SNMP désactivé ou filtré ?)."
        case .unreachable(let host): return "\(host) refuse le port UDP 161 : SNMP n’est pas actif."
        case .socket(let message): return "Erreur réseau : \(message)."
        case .agent(let status, _):
            let label = SNMPErrorStatus(rawValue: status)?.label ?? "erreur \(status)"
            return "L’agent SNMP a répondu par une erreur : \(label)."
        case .unexpectedResponse: return "Réponse SNMP inattendue."
        }
    }
}

/// Client SNMP v2c et v3 sur UDP (sockets BSD, une socket par requête).
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

    /// Parcourt toute la sous-arborescence `root` (GetBulk, ordre lexicographique), en v2c comme en v3.
    /// Un objet absent donne une liste vide ; `limit` borne le nombre de lignes.
    public func walk(_ root: SNMPOID, maxRepetitions: Int = 25, limit: Int = 20_000) async throws -> [SNMPVarBind] {
        try await walk(root, mode: .bulk(maxRepetitions: maxRepetitions), limit: limit).binds
    }

    /// Parcours détaillé : GetBulk ou GetNext, lignes remises au fur et à mesure (`onBatch`), arrêt
    /// propre à la limite (`SNMPWalkResult.truncated`) ou par annulation de la tâche.
    public func walk(_ root: SNMPOID, mode: SNMPWalkMode, limit: Int = 20_000,
                     onBatch: (@Sendable ([SNMPVarBind]) -> Void)? = nil) async throws -> SNMPWalkResult {
        try await SNMPWalker.walk(root, mode: mode, limit: limit, onBatch: onBatch) { pdu in
            try await self.request(pdu, checkStatus: false)
        }
    }

    /// Envoie une PDU et attend la réponse correspondante (même request-id).
    public func request(_ pdu: SNMPPDU, checkStatus: Bool = true) async throws -> SNMPPDU {
        try Task.checkCancellation()
        let target = self.target
        let response: SNMPPDU
        if let v3 = target.v3 {
            response = try await Self.requestV3(pdu, credentials: v3, target: target)
        } else {
            guard !target.community.isEmpty else { throw SNMPError.emptyCommunity }
            response = try await Self.requestV2c(pdu, target: target)
        }
        if checkStatus, response.errorStatus != 0 {
            throw SNMPError.agent(status: response.errorStatus, index: response.errorIndex)
        }
        return response
    }

    /// Requête v2c bloquante, faite hors du fil appelant.
    static func requestV2c(_ pdu: SNMPPDU, target: SNMPTarget) async throws -> SNMPPDU {
        let message = SNMPMessage(community: target.community, pdu: pdu)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try SNMPClient.transact(message.encoded(), requestID: pdu.requestID, target: target) })
            }
        }
    }

    /// Requête v3 ; si l'agent ne répond pas en v3 et qu'une communauté est donnée, repli en v2c.
    static func requestV3(_ pdu: SNMPPDU, credentials: SNMPv3Credentials, target: SNMPTarget) async throws -> SNMPPDU {
        let memo = SNMPVersionMemo.shared
        let canFallBack = !target.community.isEmpty
        if canFallBack, memo.prefersV2c(target) {
            return try await requestV2c(pdu, target: target)
        }
        do {
            let response: SNMPPDU = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try SNMPv3Session.request(pdu, credentials: credentials, target: target) })
                }
            }
            memo.record(target, v2c: false)
            return response
        } catch let v3Error where canFallBack && SNMPVersionMemo.allowsFallback(after: v3Error) {
            try Task.checkCancellation()
            do {
                let response = try await requestV2c(pdu, target: target)
                memo.record(target, v2c: true)
                return response
            } catch {
                // Les deux versions échouent : l'erreur v3 explique mieux (utilisateur, mot de passe),
                // sauf si l'agent n'a rien répondu en v3.
                throw SNMPVersionMemo.isSilence(v3Error) ? error : v3Error
            }
        }
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

// MARK: - Version retenue par agent

/// Version qui a répondu pour chaque agent (adresse et port), retenue dix minutes : un switch resté
/// en v2c n'attend pas le délai v3 à chaque requête d'un relevé.
public final class SNMPVersionMemo: @unchecked Sendable {
    public static let shared = SNMPVersionMemo()
    static let lifetime: TimeInterval = 600

    private let lock = NSLock()
    private var entries: [String: (v2c: Bool, at: Date)] = [:]

    private static func key(_ target: SNMPTarget) -> String { "\(target.host):\(target.port)" }

    public func prefersV2c(_ target: SNMPTarget, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[Self.key(target)], now.timeIntervalSince(entry.at) < Self.lifetime else { return false }
        return entry.v2c
    }

    public func record(_ target: SNMPTarget, v2c: Bool, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries[Self.key(target)] = (v2c, now)
    }

    /// Oublie tout (identifiants modifiés, tests).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
    }

    /// Erreurs v3 après lesquelles la communauté est essayée : silence de l'agent (v2c seulement),
    /// utilisateur ou niveau refusé, engineID absent. Un mot de passe faux aussi : l'agent connaît
    /// l'utilisateur, mais la communauté peut encore donner les données (l'erreur v3 reste visible
    /// dans le Test des Réglages).
    static func allowsFallback(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is SNMPv3Error { return true }
        if let error = error as? SNMPError {
            switch error {
            case .timeout, .unexpectedResponse: return true
            case .unreachable, .socket, .emptyCommunity, .agent: return false
            }
        }
        return error is SNMPDecodingError
    }

    static func isSilence(_ error: Error) -> Bool {
        if case SNMPError.timeout = error { return true }
        return false
    }
}
