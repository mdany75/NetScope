import CryptoKit
import Foundation

enum RADIUSCode: UInt8, Sendable {
    case accessRequest = 1
    case accept = 2
    case reject = 3
    case challenge = 11
}

/// Attribut tel qu'il circule ; `offset` est sa position dans le paquet.
struct RADIUSRawAttribute: Equatable, Sendable {
    var type: UInt8
    var value: [UInt8]
    var offset: Int
}

/// Verdict sur un datagramme reçu. `ignored` : ce n'est pas la réponse attendue (RFC 2865 : à
/// écarter en silence) ; `invalid` : c'est bien la réponse à cette demande, mais elle ne se vérifie pas.
enum RADIUSReplyCheck: Equatable, Sendable {
    case ignored
    case invalid(RADIUSInvalidReason)
    case verified(code: RADIUSCode, attributes: [RADIUSRawAttribute], signed: Bool)
}

/// Encodage et vérification RADIUS (RFC 2865, RFC 3579), sans socket : tout se teste sur des octets fixes.
enum RADIUSPacket {
    static let maxPasswordLength = 128
    static let maxAttributeValue = 253
    static let maxLength = 4096

    private static let headerLength = 20
    private static let messageAuthenticatorType: UInt8 = 80

    static func md5(_ bytes: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: bytes))
    }

    private static func hmac(_ bytes: [UInt8], secret: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.MD5>.authenticationCode(for: bytes, using: SymmetricKey(data: secret)))
    }

    /// User-Password, RFC 2865 §5.2 : c(i) = p(i) XOR MD5(secret + c(i-1)).
    static func hidePassword(_ password: [UInt8], secret: [UInt8], authenticator: [UInt8]) -> [UInt8] {
        let padding = password.isEmpty ? 16 : (16 - password.count % 16) % 16
        let padded = password + [UInt8](repeating: 0, count: padding)
        var hidden: [UInt8] = []
        var previous = authenticator
        for start in stride(from: 0, to: padded.count, by: 16) {
            let digest = md5(secret + previous)
            let block = (0..<16).map { padded[start + $0] ^ digest[$0] }
            hidden += block
            previous = block
        }
        return hidden
    }

    private static func attribute(_ type: UInt8, _ value: [UInt8]) -> [UInt8] {
        [type, UInt8(value.count + 2)] + value
    }

    /// Les valeurs ont été bornées par `RADIUSClient.validate`.
    static func accessRequest(identifier: UInt8, authenticator: [UInt8], username: [UInt8], password: [UInt8],
                              nasIdentifier: [UInt8], secret: [UInt8]) -> [UInt8] {
        // En premier attribut : un préfixe MD5 choisi (Blast-RADIUS) ne peut plus précéder la signature.
        let signature = attribute(messageAuthenticatorType, [UInt8](repeating: 0, count: 16))
        let attributes = signature
            + attribute(1, username)
            + attribute(2, hidePassword(password, secret: secret, authenticator: authenticator))
            + attribute(32, nasIdentifier)
        let length = headerLength + attributes.count
        var packet = [RADIUSCode.accessRequest.rawValue, identifier, UInt8(length >> 8), UInt8(length & 0xFF)] + authenticator + attributes
        let valueStart = headerLength + 2
        packet.replaceSubrange(valueStart..<(valueStart + 16), with: hmac(packet, secret: secret))
        return packet
    }

    private static func parseAttributes(_ packet: [UInt8]) -> [RADIUSRawAttribute]? {
        var attributes: [RADIUSRawAttribute] = []
        var position = headerLength
        while position < packet.count {
            guard position + 2 <= packet.count else { return nil }
            let size = Int(packet[position + 1])
            guard size >= 2, position + size <= packet.count else { return nil }
            attributes.append(RADIUSRawAttribute(type: packet[position], value: Array(packet[(position + 2)..<(position + size)]), offset: position))
            position += size
        }
        return attributes
    }

    /// Le Response Authenticator passe avant tout le reste : rien du paquet n'est lu avant lui.
    static func check(reply: [UInt8], request: [UInt8], secret: [UInt8]) -> RADIUSReplyCheck {
        guard reply.count >= headerLength, request.count >= headerLength, reply[1] == request[1] else { return .ignored }
        let length = Int(reply[2]) << 8 | Int(reply[3])
        guard length >= headerLength, length <= reply.count else { return .ignored }
        let packet = Array(reply[0..<length])
        let requestAuthenticator = Array(request[4..<headerLength])
        let expected = md5(Array(packet[0..<4]) + requestAuthenticator + Array(packet[headerLength...]) + secret)
        guard expected == Array(packet[4..<headerLength]) else { return .invalid(.responseAuthenticator) }
        guard let attributes = parseAttributes(packet) else { return .invalid(.malformed) }

        let signatures = attributes.filter { $0.type == messageAuthenticatorType }
        guard signatures.count <= 1 else { return .invalid(.malformed) }
        if let signature = signatures.first {
            guard signature.value.count == 16 else { return .invalid(.messageAuthenticator) }
            var signedForm = packet
            signedForm.replaceSubrange(4..<headerLength, with: requestAuthenticator)
            signedForm.replaceSubrange((signature.offset + 2)..<(signature.offset + 18), with: [UInt8](repeating: 0, count: 16))
            guard hmac(signedForm, secret: secret) == signature.value else { return .invalid(.messageAuthenticator) }
        }
        guard let code = RADIUSCode(rawValue: packet[0]), code != .accessRequest else { return .invalid(.unexpectedCode(packet[0])) }
        return .verified(code: code, attributes: attributes, signed: !signatures.isEmpty)
    }
}
