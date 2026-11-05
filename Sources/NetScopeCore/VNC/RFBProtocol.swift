import Foundation

// Constantes et messages du protocole RFB (RFC 6143). Tout est pur : aucun accès réseau ici.

/// Erreurs d'une session VNC, en français pour l'interface.
public enum RFBError: Error, Equatable, LocalizedError, Sendable {
    /// La connexion s'est fermée (par le serveur ou le réseau).
    case closed
    /// Réponse illisible ou contraire au protocole.
    case protocolViolation(String)
    /// Version annoncée non prise en charge (« RFB 004.000 »…).
    case unsupportedVersion(String)
    /// Aucun type de sécurité commun ; liste des types proposés par le serveur.
    case unsupportedSecurity([UInt8])
    /// Le serveur refuse la connexion (raison fournie par le serveur).
    case refused(String)
    /// Mot de passe (et, pour macOS, nom d'utilisateur) à demander.
    case passwordRequired(RFBSecurityType)
    case usernameRequired
    /// Identifiants refusés (raison du serveur, éventuellement vide).
    case authenticationFailed(String)
    /// Encodage reçu que NetScope n'a pas demandé.
    case unexpectedEncoding(Int32)
    /// Délai dépassé (connexion ou poignée de main).
    case timeout
    /// Erreur du réseau (texte du système).
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .closed: return "La connexion a été fermée par l’ordinateur distant."
        case .protocolViolation(let detail): return "Réponse VNC invalide\u{00A0}: \(detail)."
        case .unsupportedVersion(let version): return "Version du protocole non prise en charge\u{00A0}: \(version)."
        case .unsupportedSecurity(let types):
            let names = types.map { RFBSecurityType(rawValue: $0)?.label ?? "type \($0)" }
            return "Aucune méthode d’authentification commune (le serveur propose\u{00A0}: \(names.joined(separator: ", ")))."
        case .refused(let reason): return reason.isEmpty ? "Le serveur VNC a refusé la connexion." : "Connexion refusée\u{00A0}: \(reason)"
        case .passwordRequired: return "Mot de passe requis."
        case .usernameRequired: return "Ce Mac demande le nom d’utilisateur et le mot de passe d’un compte macOS."
        case .authenticationFailed(let reason):
            return reason.isEmpty ? "Identifiants refusés par le serveur VNC." : "Identifiants refusés\u{00A0}: \(reason)"
        case .unexpectedEncoding(let encoding): return "Encodage VNC inattendu (\(encoding))."
        case .timeout: return "Délai dépassé\u{00A0}: l’ordinateur distant ne répond pas."
        case .network(let message): return message
        }
    }
}

/// Types de sécurité (RFC 6143 § 7.2 ; 30 : Apple Remote Desktop).
public enum RFBSecurityType: UInt8, Sendable, CaseIterable {
    case invalid = 0
    case none = 1
    case vncAuthentication = 2
    case appleRemoteDesktop = 30

    public var label: String {
        switch self {
        case .invalid: return "invalide"
        case .none: return "aucune"
        case .vncAuthentication: return "mot de passe VNC"
        case .appleRemoteDesktop: return "compte macOS (ARD)"
        }
    }
}

/// Encodages et pseudo-encodages (RFC 6143 § 7.7 et 7.8).
public enum RFBEncoding {
    public static let raw: Int32 = 0
    public static let copyRect: Int32 = 1
    public static let rre: Int32 = 2
    public static let hextile: Int32 = 5
    public static let zrle: Int32 = 16
    public static let desktopSize: Int32 = -223
    public static let lastRect: Int32 = -224
    public static let cursor: Int32 = -239

    /// Nom court pour l'état de la session.
    public static func name(_ encoding: Int32) -> String {
        switch encoding {
        case raw: return "Raw"
        case copyRect: return "CopyRect"
        case rre: return "RRE"
        case hextile: return "Hextile"
        case zrle: return "ZRLE"
        case desktopSize: return "DesktopSize"
        case lastRect: return "LastRect"
        case cursor: return "Cursor"
        default: return "\(encoding)"
        }
    }

    /// Encodages demandés, du préféré au moins préféré : CopyRect (gratuit), ZRLE (zlib), Hextile,
    /// RRE, Raw, puis les pseudo-encodages.
    public static let preferred: [Int32] = [copyRect, zrle, hextile, rre, raw, desktopSize, cursor, lastRect]
}

/// Version négociée.
public enum RFBVersion: String, Equatable, Sendable {
    case v3_3 = "3.3"
    case v3_7 = "3.7"
    case v3_8 = "3.8"

    /// Les 12 octets envoyés par le client (« RFB 003.008\n »).
    public var handshake: [UInt8] {
        switch self {
        case .v3_3: return Array("RFB 003.003\n".utf8)
        case .v3_7: return Array("RFB 003.007\n".utf8)
        case .v3_8: return Array("RFB 003.008\n".utf8)
        }
    }

    /// Version à répondre au serveur (§ 7.1.1) : la plus haute connue qui ne dépasse pas la sienne.
    /// macOS annonce « 003.889 » : réponse 3.8. Une version 3.5 (ancienne) est traitée comme 3.3.
    public static func negotiate(_ banner: [UInt8]) throws -> (server: String, chosen: RFBVersion) {
        guard banner.count == 12, let text = String(bytes: banner, encoding: .ascii), text.hasPrefix("RFB "),
              text.hasSuffix("\n") else {
            throw RFBError.protocolViolation("ce port ne répond pas comme un serveur VNC")
        }
        let parts = text.dropFirst(4).dropLast().split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
            throw RFBError.protocolViolation("version illisible « \(text.trimmingCharacters(in: .whitespacesAndNewlines)) »")
        }
        let server = "\(major).\(minor)"
        guard major == 3 else { throw RFBError.unsupportedVersion(server) }
        switch minor {
        case ..<3: throw RFBError.unsupportedVersion(server)
        case 3..<7: return (server, .v3_3)
        case 7: return (server, .v3_7)
        default: return (server, .v3_8)
        }
    }
}

/// Choix du type de sécurité parmi ceux du serveur. Un nom d'utilisateur saisi fait préférer
/// l'authentification macOS (ARD) quand elle est offerte.
public enum RFBSecurityChoice {
    public static func choose(_ offered: [UInt8], hasUsername: Bool) throws -> RFBSecurityType {
        let ard = offered.contains(RFBSecurityType.appleRemoteDesktop.rawValue)
        let vnc = offered.contains(RFBSecurityType.vncAuthentication.rawValue)
        if offered.contains(RFBSecurityType.none.rawValue) { return .none }
        if ard, hasUsername { return .appleRemoteDesktop }
        if vnc { return .vncAuthentication }
        if ard { return .appleRemoteDesktop }
        throw RFBError.unsupportedSecurity(offered)
    }
}

/// Messages du client vers le serveur (§ 7.5).
public enum RFBClientMessage {
    public static func setPixelFormat(_ format: RFBPixelFormat) -> [UInt8] {
        [0, 0, 0, 0] + format.encoded()
    }

    public static func setEncodings(_ encodings: [Int32]) -> [UInt8] {
        var bytes: [UInt8] = [2, 0]
        bytes.append(u16: UInt16(encodings.count))
        for encoding in encodings { bytes.append(u32: UInt32(bitPattern: encoding)) }
        return bytes
    }

    public static func framebufferUpdateRequest(incremental: Bool, _ rect: RFBRect) -> [UInt8] {
        var bytes: [UInt8] = [3, incremental ? 1 : 0]
        bytes.append(u16: UInt16(clamping: rect.x))
        bytes.append(u16: UInt16(clamping: rect.y))
        bytes.append(u16: UInt16(clamping: rect.width))
        bytes.append(u16: UInt16(clamping: rect.height))
        return bytes
    }

    public static func keyEvent(keysym: UInt32, down: Bool) -> [UInt8] {
        var bytes: [UInt8] = [4, down ? 1 : 0, 0, 0]
        bytes.append(u32: keysym)
        return bytes
    }

    public static func pointerEvent(x: Int, y: Int, buttons: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [5, buttons]
        bytes.append(u16: UInt16(clamping: max(0, x)))
        bytes.append(u16: UInt16(clamping: max(0, y)))
        return bytes
    }

    /// Presse-papiers texte : ISO 8859-1 (§ 7.5.6) ; les caractères hors Latin-1 deviennent « ? »
    /// et les fins de ligne sont des LF.
    public static func clientCutText(_ text: String) -> [UInt8] {
        let latin1 = RFBText.latin1(text)
        var bytes: [UInt8] = [6, 0, 0, 0]
        bytes.append(u32: UInt32(latin1.count))
        return bytes + latin1
    }
}

/// Texte du presse-papiers en ISO 8859-1.
public enum RFBText {
    public static func latin1(_ text: String) -> [UInt8] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
    }

    public static func string(latin1 bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }
}

/// Boutons de la souris (§ 7.5.5) : bits 0 à 7 du masque.
public struct RFBButtons: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let left = RFBButtons(rawValue: 1)
    public static let middle = RFBButtons(rawValue: 2)
    public static let right = RFBButtons(rawValue: 4)
    public static let wheelUp = RFBButtons(rawValue: 8)
    public static let wheelDown = RFBButtons(rawValue: 16)
    public static let wheelLeft = RFBButtons(rawValue: 32)
    public static let wheelRight = RFBButtons(rawValue: 64)
}

extension Array where Element == UInt8 {
    mutating func append(u16 value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func append(u32 value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
