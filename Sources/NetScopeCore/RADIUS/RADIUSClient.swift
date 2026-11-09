import Darwin
import Foundation
import Security

public struct RADIUSOptions: Sendable {
    public var attemptTimeout: TimeInterval
    public var retransmits: Int

    public init(attemptTimeout: TimeInterval = 3, retransmits: Int = RADIUSClient.maxRetransmits) {
        self.attemptTimeout = attemptTimeout
        self.retransmits = retransmits
    }
}

/// Essai d'authentification PAP (note 117), lancé seulement sur clic.
public enum RADIUSClient {
    public static let maxRetransmits = 2
    public static let keychainService = BackupKeychainScan.servicePrefix + ".radius"

    public static func keychainAccount(server: String) -> String {
        server.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func validate(_ request: RADIUSRequest, secret: String, password: String) throws {
        guard !request.server.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.invalidInput("Saisir l’adresse du serveur RADIUS.")
        }
        guard request.port > 0 else { throw ToolError.invalidInput("Port invalide (1 à 65\u{202F}535).") }
        guard !secret.isEmpty else { throw ToolError.invalidInput("Saisir le secret partagé du serveur.") }
        let username = request.username.utf8.count
        guard username > 0, username <= RADIUSPacket.maxAttributeValue else {
            throw ToolError.invalidInput("Saisir un compte de \(RADIUSPacket.maxAttributeValue)\u{00A0}octets au plus.")
        }
        let nas = request.nasIdentifier.utf8.count
        guard nas > 0, nas <= RADIUSPacket.maxAttributeValue else {
            throw ToolError.invalidInput("NAS-Identifier vide ou trop long.")
        }
        let length = password.utf8.count
        guard length > 0, length <= RADIUSPacket.maxPasswordLength else {
            throw ToolError.invalidInput("Saisir un mot de passe de \(RADIUSPacket.maxPasswordLength)\u{00A0}octets au plus.")
        }
    }

    /// Un seul appel, une seule authentification : les renvois sont des copies exactes du paquet
    /// (même identifiant, même authenticator), que le serveur reconnaît comme un doublon. Ainsi,
    /// une réponse perdue ne fait pas compter un échec de plus contre le compte.
    public static func test(_ request: RADIUSRequest, secret: String, password: String,
                            options: RADIUSOptions = RADIUSOptions()) async throws -> RADIUSResult {
        try validate(request, secret: secret, password: password)
        let host = request.server.trimmingCharacters(in: .whitespaces)
        func result(_ outcome: RADIUSOutcome, address: IPv4Address? = nil) -> RADIUSResult {
            RADIUSResult(server: host, address: address, port: request.port, username: request.username, outcome: outcome)
        }
        guard let address = try? await PingResolver.resolveAsync(host) else {
            return result(.networkError("Nom introuvable ou sans adresse IPv4."))
        }
        guard let random = randomBytes(17) else {
            return result(.networkError("Générateur aléatoire du système indisponible."), address: address)
        }
        let secretBytes = Array(secret.utf8)
        let packet = RADIUSPacket.accessRequest(identifier: random[16], authenticator: Array(random[0..<16]),
                                                username: Array(request.username.utf8), password: Array(password.utf8),
                                                nasIdentifier: Array(request.nasIdentifier.utf8), secret: secretBytes)
        let retransmits = max(0, min(options.retransmits, maxRetransmits))
        let timeout = options.attemptTimeout.isFinite ? min(max(options.attemptTimeout, 0.05), 5) : 3
        let exchanged = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: exchange(packet, secret: secretBytes, address: address, port: request.port,
                                                        attempts: retransmits + 1, timeout: timeout))
            }
        }
        var final = result(exchanged.outcome, address: address)
        final.sent = exchanged.sent
        final.duration = exchanged.duration
        final.attributes = exchanged.attributes
        final.responseSigned = exchanged.signed
        return final
    }

    private static func randomBytes(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        return SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess ? bytes : nil
    }

    private struct Exchange {
        var outcome: RADIUSOutcome
        var sent = 0
        var duration: TimeInterval = 0
        var attributes: [RADIUSAttribute] = []
        var signed: Bool?
    }

    private static func exchange(_ packet: [UInt8], secret: [UInt8], address: IPv4Address, port: UInt16,
                                 attempts: Int, timeout: TimeInterval) -> Exchange {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return Exchange(outcome: .networkError("Socket UDP impossible (\(String(cString: strerror(errno))))).")) }
        defer { close(fd) }
        guard ToolSocket.connect(fd, to: ToolSocket.address(address, port: port)) == 0 else {
            return Exchange(outcome: .networkError(socketFailure(errno, port: port)))
        }
        let started = Date()
        var sent = 0
        var buffer = [UInt8](repeating: 0, count: RADIUSPacket.maxLength)
        func failure(_ code: Int32) -> Exchange {
            Exchange(outcome: .networkError(socketFailure(code, port: port)), sent: sent, duration: Date().timeIntervalSince(started))
        }
        for _ in 0..<attempts {
            guard send(fd, packet, packet.count, 0) == packet.count else { return failure(errno) }
            sent += 1
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, Int32(max(1, (remaining * 1000).rounded(.up)))) > 0 else { continue }
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count >= 0 else {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return failure(errno)
                }
                switch RADIUSPacket.check(reply: Array(buffer[0..<count]), request: packet, secret: secret) {
                case .ignored:
                    continue
                case let .invalid(reason):
                    return Exchange(outcome: .invalidResponse(reason), sent: sent, duration: Date().timeIntervalSince(started))
                case let .verified(code, attributes, signed):
                    return Exchange(outcome: outcome(code, attributes), sent: sent, duration: Date().timeIntervalSince(started),
                                    attributes: readable(attributes), signed: signed)
                }
            }
        }
        return Exchange(outcome: .silent, sent: sent, duration: Date().timeIntervalSince(started))
    }

    private static func outcome(_ code: RADIUSCode, _ attributes: [RADIUSRawAttribute]) -> RADIUSOutcome {
        let messages = attributes.filter { $0.type == 18 }.map { String(decoding: $0.value, as: UTF8.self) }
        let message = messages.isEmpty ? nil : messages.joined(separator: " ")
        switch code {
        case .accept: return .accepted
        case .reject: return .rejected(message: message)
        case .challenge: return .challenge(message: message)
        case .accessRequest: return .invalidResponse(.unexpectedCode(code.rawValue))
        }
    }

    /// Mêmes libellés que la Capture de paquets. Les clés de session MS-MPPE sont masquées, et le
    /// Message-Authenticator a sa propre case dans le résultat.
    static func readable(_ attributes: [RADIUSRawAttribute]) -> [RADIUSAttribute] {
        attributes.filter { $0.type != 80 }.enumerated().map { index, attribute in
            let decoder = PacketDecoding(attribute.value)
            let (name, text, _) = decoder.radiusAttribute(attribute.type, 0, attribute.value.count)
            return RADIUSAttribute(id: index, name: name, value: isSessionKey(attribute) ? "masqué" : text)
        }
    }

    private static func isSessionKey(_ attribute: RADIUSRawAttribute) -> Bool {
        guard attribute.type == 26, attribute.value.count >= 5 else { return false }
        let microsoft: [UInt8] = [0, 0, 0x01, 0x37]
        return Array(attribute.value[0..<4]) == microsoft && (attribute.value[4] == 16 || attribute.value[4] == 17)
    }

    private static func socketFailure(_ code: Int32, port: UInt16) -> String {
        switch code {
        case ECONNREFUSED: return "Port UDP \(port) fermé\u{00A0}: l’appareil répond, mais aucun service RADIUS n’y écoute."
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN: return "Hôte injoignable depuis ce Mac (\(String(cString: strerror(code))))."
        default: return "Erreur réseau\u{00A0}: \(String(cString: strerror(code)))."
        }
    }
}
