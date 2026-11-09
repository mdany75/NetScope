import CryptoKit
import Darwin
import Foundation
@testable import NetScopeCore

// Note 117 : Test RADIUS. Vecteurs de la RFC 2865 §7.1 (valeurs d'exemple publiques, FICTIF) et
// faux serveur UDP sur 127.0.0.1 seulement. La vérification côté test est écrite à part du moteur.

private let secretFictif = "secret-FICTIF"
private let passeFictif = "motdepasse-FICTIF"

private func hex(_ text: String) -> [UInt8] {
    let digits = Array(text.filter { !$0.isWhitespace })
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...($0 + 1)]), radix: 16)! }
}

private func md5(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: bytes)) }

private func hmac(_ bytes: [UInt8], _ secret: String) -> [UInt8] {
    Array(HMAC<Insecure.MD5>.authenticationCode(for: bytes, using: SymmetricKey(data: Array(secret.utf8))))
}

private func reveal(_ hidden: [UInt8], secret: [UInt8], authenticator: [UInt8]) -> [UInt8] {
    var clear: [UInt8] = []
    var previous = authenticator
    for start in stride(from: 0, to: hidden.count, by: 16) {
        let block = Array(hidden[start..<(start + 16)])
        let digest = md5(secret + previous)
        clear += (0..<16).map { block[$0] ^ digest[$0] }
        previous = block
    }
    return clear
}

private func attributes(of packet: [UInt8]) -> [(type: UInt8, value: [UInt8])] {
    var list: [(UInt8, [UInt8])] = []
    var position = 20
    while position + 2 <= packet.count {
        let size = Int(packet[position + 1])
        list.append((packet[position], Array(packet[(position + 2)..<(position + size)])))
        position += size
    }
    return list
}

/// Réponse signée comme un vrai serveur : Message-Authenticator d'abord, Response Authenticator ensuite.
private func response(code: UInt8, to request: [UInt8], secret: String, attributes extra: [UInt8] = [], signed: Bool = true) -> [UInt8] {
    let body = (signed ? [80, 18] + [UInt8](repeating: 0, count: 16) : []) + extra
    let length = 20 + body.count
    var packet = [code, request[1], UInt8(length >> 8), UInt8(length & 0xFF)] + Array(request[4..<20]) + body
    if signed { packet.replaceSubrange(22..<38, with: hmac(packet, secret)) }
    packet.replaceSubrange(4..<20, with: md5(packet + Array(secret.utf8)))
    return packet
}

private func text(_ type: UInt8, _ value: String) -> [UInt8] { [type, UInt8(value.utf8.count + 2)] + Array(value.utf8) }

private func udpLoopback() throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { throw TestSkipped(reason: "socket UDP indisponible") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { close(fd); throw TestSkipped(reason: "impossible d'écouter sur 127.0.0.1") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return (fd, UInt16(bigEndian: address.sin_port))
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[UInt8]] = []
    func add(_ packet: [UInt8]) { lock.lock(); stored.append(packet); lock.unlock() }
    var all: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Répond à la requête numéro `answerAt` (les précédentes restent sans réponse) et note tout ce qu'il reçoit.
private func serve(_ fd: Int32, answerAt: Int = 0, _ reply: @escaping @Sendable ([UInt8]) -> [UInt8]) -> Received {
    let received = Received()
    Thread.detachNewThread {
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        for index in 0...answerAt {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { return }
            let packet = Array(buffer[0..<count])
            received.add(packet)
            guard index == answerAt else { continue }
            let datagram = reply(packet)
            _ = withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, datagram, datagram.count, 0, $0, length) }
            }
        }
    }
    return received
}

private func request(_ port: UInt16) -> RADIUSRequest { RADIUSRequest(server: "127.0.0.1", port: port, username: "test.FICTIF") }

private func fast(_ timeout: TimeInterval = 0.2) -> RADIUSOptions { RADIUSOptions(attemptTimeout: timeout) }

func registerRADIUSTests(_ suite: TestSuite) {
    // RFC 2865 §7.1 : utilisateur « nemo », mot de passe « arctangent », secret « xyzzy5461 ».
    let rfcAuthenticator = hex("0f403f94 73978057 bd83d5cb 98f4227a")
    let rfcRequest = hex("""
        01 00 00 38 0f 40 3f 94 73 97 80 57 bd 83 d5 cb 98 f4 22 7a 01 06 6e 65 6d 6f 02 12 0d be 70 8d
        93 d4 13 ce 31 96 e4 3f 78 2a 0a ee 04 06 c0 a8 01 10 05 06 00 00 00 03
        """)
    let rfcAccept = hex("""
        02 00 00 26 86 fe 22 0e 76 24 ba 2a 10 05 f6 bf 9b 55 e0 b2 06 06 00 00 00 01 0f 06 00 00 00 00
        0e 06 c0 a8 01 03
        """)
    let rfcSecret = Array("xyzzy5461".utf8)

    suite.add("RADIUS : masquage du mot de passe (exemple de la RFC 2865)") {
        let hidden = RADIUSPacket.hidePassword(Array("arctangent".utf8), secret: rfcSecret, authenticator: rfcAuthenticator)
        try expectEqual(hidden, hex("0dbe708d93d413ce3196e43f782a0aee"), "User-Password de la RFC")
    }

    suite.add("RADIUS : mots de passe de plus de 16 octets, longueur bornée à 128") {
        let authenticator = [UInt8](repeating: 7, count: 16)
        let secret = Array(secretFictif.utf8)
        for (length, expected) in [(1, 16), (16, 16), (17, 32), (32, 32), (33, 48), (128, 128)] {
            let password = [UInt8](repeating: 0x61, count: length)
            let hidden = RADIUSPacket.hidePassword(password, secret: secret, authenticator: authenticator)
            try expectEqual(hidden.count, expected, "taille masquée pour \(length) octets")
            let clear = reveal(hidden, secret: secret, authenticator: authenticator)
            try expectEqual(Array(clear[0..<length]), password, "mot de passe retrouvé (\(length))")
            try expect(clear[length...].allSatisfy { $0 == 0 }, "bourrage nul (\(length))")
        }
        let accepted = request(1812)
        try RADIUSClient.validate(accepted, secret: secretFictif, password: String(repeating: "a", count: 128))
        var refused = false
        do { try RADIUSClient.validate(accepted, secret: secretFictif, password: String(repeating: "a", count: 129)) } catch { refused = true }
        try expect(refused, "129 octets refusés")
    }

    suite.add("RADIUS : Access-Request, Message-Authenticator en premier attribut") {
        let authenticator = [UInt8](0..<16)
        let packet = RADIUSPacket.accessRequest(identifier: 42, authenticator: authenticator, username: Array("test.FICTIF".utf8),
                                                password: Array(passeFictif.utf8), nasIdentifier: Array("NetScope".utf8), secret: Array(secretFictif.utf8))
        try expectEqual(packet[0], 1, "Access-Request")
        try expectEqual(Int(packet[2]) << 8 | Int(packet[3]), packet.count, "longueur annoncée")
        let list = attributes(of: packet)
        try expectEqual(list.map(\.type), [80, 1, 2, 32], "ordre des attributs")
        var zeroed = packet
        zeroed.replaceSubrange(22..<38, with: [UInt8](repeating: 0, count: 16))
        try expectEqual(list[0].value, hmac(zeroed, secretFictif), "HMAC-MD5 de la RFC 3579")
        let clear = reveal(list[2].value, secret: Array(secretFictif.utf8), authenticator: authenticator)
        try expectEqual(Array(clear[0..<passeFictif.utf8.count]), Array(passeFictif.utf8), "mot de passe récupérable avec le secret")
        let raw = String(decoding: packet, as: UTF8.self)
        try expect(!raw.contains(passeFictif) && !raw.contains(secretFictif), "ni mot de passe ni secret en clair")
    }

    suite.add("RADIUS : réponse de la RFC 2865 vérifiée, altérations rejetées") {
        guard case let .verified(code, attributes, signed) = RADIUSPacket.check(reply: rfcAccept, request: rfcRequest, secret: rfcSecret) else {
            throw TestFailure(message: "réponse de la RFC non vérifiée", file: #fileID, line: #line)
        }
        try expectEqual(code, .accept, "Access-Accept")
        try expectEqual(attributes.map(\.type), [6, 15, 14], "attributs reçus")
        try expect(!signed, "pas de Message-Authenticator dans cet exemple")

        var altered = rfcAccept
        altered[37] ^= 1
        try expectEqual(RADIUSPacket.check(reply: altered, request: rfcRequest, secret: rfcSecret), .invalid(.responseAuthenticator), "attribut modifié")
        try expectEqual(RADIUSPacket.check(reply: rfcAccept, request: rfcRequest, secret: Array("autre-FICTIF".utf8)), .invalid(.responseAuthenticator), "mauvais secret")
        var otherID = rfcAccept
        otherID[1] = 9
        try expectEqual(RADIUSPacket.check(reply: otherID, request: rfcRequest, secret: rfcSecret), .ignored, "identifiant non apparié")
        try expectEqual(RADIUSPacket.check(reply: Array(rfcAccept[0..<12]), request: rfcRequest, secret: rfcSecret), .ignored, "trop court")
        try expectEqual(RADIUSPacket.check(reply: Array(rfcAccept[0..<30]), request: rfcRequest, secret: rfcSecret), .ignored, "longueur annoncée plus grande que reçue")
    }

    suite.add("RADIUS : Message-Authenticator vérifié sur la réponse quand il est présent") {
        let packet = RADIUSPacket.accessRequest(identifier: 5, authenticator: [UInt8](0..<16), username: Array("u".utf8), password: Array("p".utf8),
                                                nasIdentifier: Array("NetScope".utf8), secret: Array(secretFictif.utf8))
        guard case let .verified(_, _, signed) = RADIUSPacket.check(reply: response(code: 2, to: packet, secret: secretFictif), request: packet, secret: Array(secretFictif.utf8)) else {
            throw TestFailure(message: "réponse signée non vérifiée", file: #fileID, line: #line)
        }
        try expect(signed, "signature constatée")

        var tampered = response(code: 2, to: packet, secret: secretFictif)
        tampered[25] ^= 0xFF
        tampered.replaceSubrange(4..<20, with: md5(Array(tampered[0..<4]) + Array(packet[4..<20]) + Array(tampered[20...]) + Array(secretFictif.utf8)))
        try expectEqual(RADIUSPacket.check(reply: tampered, request: packet, secret: Array(secretFictif.utf8)), .invalid(.messageAuthenticator), "signature fausse, authenticator juste")
    }

    suite.add("RADIUS : accepté par un faux serveur 127.0.0.1, attributs lisibles") {
        let server = try udpLoopback()
        let extra = text(11, "RESEAU-FICTIF") + [64, 6, 0, 0, 0, 13] + [26, 12, 0, 0, 0x01, 0x37, 16, 6, 1, 2, 3, 4]
        _ = serve(server.fd) { response(code: 2, to: $0, secret: secretFictif, attributes: extra) }
        let result = try await RADIUSClient.test(request(server.port), secret: secretFictif, password: passeFictif, options: fast())
        try expectEqual(result.outcome, .accepted, "accepté")
        try expectEqual(result.sent, 1, "un seul envoi")
        try expectEqual(result.responseSigned, true, "réponse signée")
        try expectEqual(result.attributes.map(\.name), ["Filter-Id", "Tunnel-Type", "Vendor-Specific"], "noms, sans le Message-Authenticator")
        try expectEqual(result.attributes[0].value, "RESEAU-FICTIF", "valeur en clair")
        try expectEqual(result.attributes[1].value, "VLAN (13)", "valeur décodée")
        try expectEqual(result.attributes[2].value, "masqué", "clé de session MS-MPPE masquée")
    }

    suite.add("RADIUS : refusé avec le message du serveur, défi reconnu") {
        let rejecting = try udpLoopback()
        _ = serve(rejecting.fd) { response(code: 3, to: $0, secret: secretFictif, attributes: text(18, "Compte FICTIF inconnu"), signed: false) }
        let rejected = try await RADIUSClient.test(request(rejecting.port), secret: secretFictif, password: passeFictif, options: fast())
        try expectEqual(rejected.outcome, .rejected(message: "Compte FICTIF inconnu"), "refusé")
        try expectEqual(rejected.responseSigned, false, "signature absente constatée")
        try expect(RADIUSFormat.explanation(rejected).contains("Compte FICTIF inconnu"), "message du serveur montré")

        let challenging = try udpLoopback()
        _ = serve(challenging.fd) { response(code: 11, to: $0, secret: secretFictif) }
        let challenged = try await RADIUSClient.test(request(challenging.port), secret: secretFictif, password: passeFictif, options: fast())
        try expectEqual(challenged.outcome, .challenge(message: nil), "défi")
        try expect(challenged.outcome.provesSecret, "le défi prouve le secret")
    }

    suite.add("RADIUS : réponse au mauvais secret jamais crue, même si elle dit Accept") {
        let server = try udpLoopback()
        _ = serve(server.fd) { response(code: 2, to: $0, secret: "autre-secret-FICTIF") }
        let result = try await RADIUSClient.test(request(server.port), secret: secretFictif, password: passeFictif, options: fast())
        try expectEqual(result.outcome, .invalidResponse(.responseAuthenticator), "invalide")
        try expect(!result.outcome.provesSecret, "ne prouve pas le secret")
        try expect(result.attributes.isEmpty, "attributs non crus")
    }

    suite.add("RADIUS : une réponse à un autre identifiant est écartée, la vraie est prise") {
        let server = try udpLoopback()
        Thread.detachNewThread {
            defer { close(server.fd) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(server.fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { return }
            let packet = Array(buffer[0..<count])
            var other = packet
            other[1] = other[1] &+ 1
            for datagram in [response(code: 2, to: other, secret: secretFictif), response(code: 3, to: packet, secret: secretFictif)] {
                _ = withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(server.fd, datagram, datagram.count, 0, $0, length) }
                }
            }
        }
        let result = try await RADIUSClient.test(request(server.port), secret: secretFictif, password: passeFictif, options: fast())
        try expectEqual(result.outcome, .rejected(message: nil), "la vraie réponse décide")
    }

    suite.add("RADIUS : silence après 3 envois identiques, le mauvais secret expliqué") {
        let server = try udpLoopback()
        let received = serve(server.fd, answerAt: 3) { $0 }
        let result = try await RADIUSClient.test(request(server.port), secret: secretFictif, password: passeFictif, options: fast(0.05))
        try expectEqual(result.outcome, .silent, "muet")
        try expectEqual(result.sent, 3, "deux renvois au plus")
        try await Task.sleep(nanoseconds: 50_000_000)
        try expectEqual(received.all.count, 3, "trois datagrammes reçus")
        try expectEqual(Set(received.all).count, 1, "copies exactes : pas de nouvelle authentification")
        try expect(RADIUSFormat.explanation(result).contains("mauvais secret"), "cause expliquée")
    }

    suite.add("RADIUS : une réponse au 2e envoi arrête les renvois") {
        let server = try udpLoopback()
        let received = serve(server.fd, answerAt: 1) { response(code: 2, to: $0, secret: secretFictif) }
        let result = try await RADIUSClient.test(request(server.port), secret: secretFictif, password: passeFictif, options: fast(0.15))
        try expectEqual(result.outcome, .accepted, "accepté")
        try expectEqual(result.sent, 2, "arrêt au 2e envoi")
        try expectEqual(received.all.count, 2, "pas de 3e envoi")
    }

    suite.add("RADIUS : port fermé en erreur réseau") {
        let closed = try udpLoopback()
        close(closed.fd)
        let result = try await RADIUSClient.test(request(closed.port), secret: secretFictif, password: passeFictif, options: fast(0.3))
        guard case let .networkError(text) = result.outcome else {
            throw TestFailure(message: "erreur réseau attendue : \(result.outcome)", file: #fileID, line: #line)
        }
        try expect(text.contains("fermé"), "port fermé expliqué")
    }

    suite.add("RADIUS : ni secret ni mot de passe dans le résultat ou le rapport") {
        let server = try udpLoopback()
        _ = serve(server.fd) { response(code: 3, to: $0, secret: secretFictif) }
        let result = try await RADIUSClient.test(request(server.port), secret: secretFictif, password: passeFictif, options: fast())
        for text in [RADIUSFormat.report(result), String(describing: result)] {
            try expect(!text.contains(secretFictif) && !text.contains(passeFictif), "aucun secret")
        }
    }

    suite.add("RADIUS : secrets mémorisés propres à ce Mac (ni sauvegarde ni synchronisation)") {
        let registry = ConfigPartRegistry.standard
        try expect(registry.part(forSecret: RADIUSClient.keychainService, account: "10.0.0.20") == nil, "hors du registre")
        try expect(ConfigSecrets.neverCopied.contains(RADIUSClient.keychainService), "jamais copié")
        try expectEqual(RADIUSClient.keychainAccount(server: "  Radius.Exemple.CA "), "radius.exemple.ca", "compte par adresse de serveur")
    }
}
