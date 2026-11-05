import Foundation

// TFTP (note 51) : paquets de la RFC 1350 et de ses options (RFC 2347 : OACK ; RFC 2348 : blksize ;
// RFC 2349 : timeout et tsize ; RFC 7440 : windowsize). Codage et décodage purs, sans réseau.

/// Code d'opération d'un paquet TFTP (deux octets en tête).
public enum TFTPOpcode: UInt16, Sendable {
    case rrq = 1, wrq = 2, data = 3, ack = 4, error = 5, oack = 6
}

/// Mode de transfert. « octet » (binaire) est le mode par défaut de NetScope ; « netascii » convertit
/// les fins de ligne (CR LF sur le fil) ; « mail » est obsolète et refusé.
public enum TFTPMode: String, Sendable, CaseIterable, Codable {
    case octet, netascii

    public var label: String {
        switch self {
        case .octet: return "Binaire (octet)"
        case .netascii: return "Texte (netascii)"
        }
    }
}

/// Codes d'erreur de la RFC 1350 (et 8 de la RFC 2347).
public enum TFTPErrorCode: UInt16, Sendable, Codable {
    case notDefined = 0, fileNotFound = 1, accessViolation = 2, diskFull = 3, illegalOperation = 4
    case unknownTransferID = 5, fileExists = 6, noSuchUser = 7, optionRefused = 8

    /// Explication en clair, pour le journal.
    public var label: String {
        switch self {
        case .notDefined: return "Erreur"
        case .fileNotFound: return "Fichier introuvable"
        case .accessViolation: return "Accès refusé"
        case .diskFull: return "Disque plein"
        case .illegalOperation: return "Opération TFTP illégale"
        case .unknownTransferID: return "Identifiant de transfert inconnu"
        case .fileExists: return "Le fichier existe déjà"
        case .noSuchUser: return "Utilisateur inconnu"
        case .optionRefused: return "Options refusées"
        }
    }
}

/// Une option d'une requête ou d'un OACK (nom en minuscules, valeur en texte).
public struct TFTPOption: Equatable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name.lowercased()
        self.value = value
    }
}

/// Requête de lecture (RRQ) ou d'écriture (WRQ).
public struct TFTPRequest: Equatable, Sendable {
    public enum Kind: String, Sendable, Codable {
        /// Le client lit un fichier du serveur (get).
        case read
        /// Le client écrit un fichier sur le serveur (put).
        case write
    }

    public var kind: Kind
    public var filename: String
    public var mode: TFTPMode
    public var options: [TFTPOption]

    public init(kind: Kind, filename: String, mode: TFTPMode = .octet, options: [TFTPOption] = []) {
        self.kind = kind
        self.filename = filename
        self.mode = mode
        self.options = options
    }

    /// Valeur d'une option (nom sans casse).
    public func option(_ name: String) -> String? {
        options.first { $0.name == name.lowercased() }?.value
    }
}

/// Paquet TFTP décodé.
public enum TFTPPacket: Equatable, Sendable {
    case request(TFTPRequest)
    case data(block: UInt16, payload: [UInt8])
    case ack(block: UInt16)
    case error(code: TFTPErrorCode, message: String)
    case oack([TFTPOption])

    /// Plus grand paquet accepté : en-tête de 4 octets + bloc de 65 464 octets (RFC 2348).
    public static let maxPacketSize = 4 + TFTPLimits.maxBlockSize

    // MARK: Codage

    public func encoded() -> [UInt8] {
        var bytes: [UInt8] = []
        func u16(_ value: UInt16) { bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 0xFF)) }
        func text(_ value: String) { bytes.append(contentsOf: Array(value.utf8)); bytes.append(0) }
        switch self {
        case .request(let request):
            u16(request.kind == .read ? TFTPOpcode.rrq.rawValue : TFTPOpcode.wrq.rawValue)
            text(request.filename)
            text(request.mode.rawValue)
            for option in request.options {
                text(option.name)
                text(option.value)
            }
        case .data(let block, let payload):
            u16(TFTPOpcode.data.rawValue)
            u16(block)
            bytes.append(contentsOf: payload)
        case .ack(let block):
            u16(TFTPOpcode.ack.rawValue)
            u16(block)
        case .error(let code, let message):
            u16(TFTPOpcode.error.rawValue)
            u16(code.rawValue)
            text(message)
        case .oack(let options):
            u16(TFTPOpcode.oack.rawValue)
            for option in options {
                text(option.name)
                text(option.value)
            }
        }
        return bytes
    }

    // MARK: Décodage

    public static func decode(_ bytes: [UInt8]) throws -> TFTPPacket {
        guard bytes.count >= 2 else { throw TFTPDecodeError.tooShort }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard let opcode = TFTPOpcode(rawValue: raw) else { throw TFTPDecodeError.unknownOpcode(raw) }
        switch opcode {
        case .rrq, .wrq:
            let fields = try strings(bytes, from: 2)
            guard fields.count >= 2 else { throw TFTPDecodeError.malformed("nom de fichier ou mode manquant") }
            let filename = fields[0]
            guard !filename.isEmpty else { throw TFTPDecodeError.malformed("nom de fichier vide") }
            guard let mode = TFTPMode(rawValue: fields[1].lowercased()) else {
                throw TFTPDecodeError.unsupportedMode(fields[1])
            }
            let rest = Array(fields.dropFirst(2))
            // Une option sans valeur (nombre impair de champs) est ignorée, comme le font les serveurs courants.
            var options: [TFTPOption] = []
            var index = 0
            while index + 1 < rest.count {
                let option = TFTPOption(rest[index], rest[index + 1])
                if !options.contains(where: { $0.name == option.name }) { options.append(option) }
                index += 2
            }
            return .request(TFTPRequest(kind: opcode == .rrq ? .read : .write, filename: filename, mode: mode, options: options))
        case .data:
            guard bytes.count >= 4 else { throw TFTPDecodeError.tooShort }
            guard bytes.count <= maxPacketSize else { throw TFTPDecodeError.malformed("bloc trop grand") }
            return .data(block: UInt16(bytes[2]) << 8 | UInt16(bytes[3]), payload: Array(bytes[4...]))
        case .ack:
            guard bytes.count >= 4 else { throw TFTPDecodeError.tooShort }
            return .ack(block: UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        case .error:
            guard bytes.count >= 4 else { throw TFTPDecodeError.tooShort }
            let code = TFTPErrorCode(rawValue: UInt16(bytes[2]) << 8 | UInt16(bytes[3])) ?? .notDefined
            // Message facultatif (certains appareils oublient le zéro final).
            let tail = Array(bytes[4...])
            let end = tail.firstIndex(of: 0) ?? tail.count
            return .error(code: code, message: String(decoding: tail[..<end], as: UTF8.self))
        case .oack:
            let fields = try strings(bytes, from: 2)
            var options: [TFTPOption] = []
            var index = 0
            while index + 1 < fields.count {
                options.append(TFTPOption(fields[index], fields[index + 1]))
                index += 2
            }
            return .oack(options)
        }
    }

    /// Chaînes terminées par un zéro à partir de `start`.
    private static func strings(_ bytes: [UInt8], from start: Int) throws -> [String] {
        var result: [String] = []
        var current = start
        while current < bytes.count {
            guard let end = bytes[current...].firstIndex(of: 0) else {
                throw TFTPDecodeError.malformed("chaîne sans zéro final")
            }
            result.append(String(decoding: bytes[current..<end], as: UTF8.self))
            current = end + 1
        }
        return result
    }

    /// Résumé lisible (journal de débogage, tests).
    public var summary: String {
        switch self {
        case .request(let request):
            let options = request.options.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
            return "\(request.kind == .read ? "RRQ" : "WRQ") \(request.filename) \(request.mode.rawValue)" + (options.isEmpty ? "" : " " + options)
        case .data(let block, let payload): return "DATA \(block) (\(payload.count) octets)"
        case .ack(let block): return "ACK \(block)"
        case .error(let code, let message): return "ERROR \(code.rawValue) \(message)"
        case .oack(let options): return "OACK " + options.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
        }
    }
}

public enum TFTPDecodeError: Error, Equatable, Sendable, LocalizedError {
    case tooShort
    case unknownOpcode(UInt16)
    case unsupportedMode(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "Paquet TFTP trop court."
        case .unknownOpcode(let code): return "Code d’opération TFTP inconnu (\(code))."
        case .unsupportedMode(let mode): return "Mode de transfert non pris en charge («\u{00A0}\(mode)\u{00A0}»)."
        case .malformed(let detail): return "Paquet TFTP mal formé (\(detail))."
        }
    }
}
