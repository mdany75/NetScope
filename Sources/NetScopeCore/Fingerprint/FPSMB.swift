import Foundation

/// Négociation SMB2 seule (note 68) : une requête NEGOTIATE, une réponse, aucune session, aucune
/// authentification. On n'en garde que le dialecte, la signature exigée et l'indice SPNEGO de Samba.
/// Construction et lecture pures (testées sans réseau) ; l'échange est fait par PortScanner.
public enum FPSMB {
    public static let dialects: [UInt16] = [0x0202, 0x0210, 0x0300, 0x0302, 0x0311]

    /// Ce que la réponse apprend.
    public struct Negotiation: Hashable, Sendable {
        public var dialect: UInt16?
        public var smb1Only: Bool
        public var signingRequired: Bool?
        public var sambaHint: Bool
    }

    /// « SMB 3.1.1 ».
    public static func dialectLabel(_ dialect: UInt16) -> String {
        switch dialect {
        case 0x0202: return "SMB 2.0.2"
        case 0x0210: return "SMB 2.1"
        case 0x0300: return "SMB 3.0"
        case 0x0302: return "SMB 3.0.2"
        case 0x0311: return "SMB 3.1.1"
        case 0x02FF: return "SMB 2.???"
        default: return String(format: "SMB 0x%04X", dialect)
        }
    }

    /// Requête NEGOTIATE SMB2 (en-tête de session NetBIOS compris), dialectes 2.0.2 à 3.1.1 avec
    /// les contextes exigés par 3.1.1 (intégrité avant authentification SHA-512, chiffrement).
    public static func negotiateRequest(clientGUID: [UInt8] = Array(repeating: 0x4E, count: 16),
                                        salt: [UInt8] = Array(repeating: 0x53, count: 32)) -> Data {
        var smb: [UInt8] = []
        // En-tête SMB2 (64 octets).
        smb += [0xFE, 0x53, 0x4D, 0x42]          // « \xFESMB »
        smb += le16(64)                           // StructureSize
        smb += le16(0)                            // CreditCharge
        smb += le32(0)                            // Status
        smb += le16(0)                            // Command : NEGOTIATE
        smb += le16(1)                            // CreditRequest
        smb += le32(0)                            // Flags
        smb += le32(0)                            // NextCommand
        smb += [UInt8](repeating: 0, count: 8)    // MessageId
        smb += le32(0xFEFF)                       // ProcessId
        smb += le32(0)                            // TreeId
        smb += [UInt8](repeating: 0, count: 8)    // SessionId
        smb += [UInt8](repeating: 0, count: 16)   // Signature
        // Corps NEGOTIATE.
        let fixed = 36
        let dialectsEnd = 64 + fixed + dialects.count * 2
        let contextOffset = (dialectsEnd + 7) / 8 * 8
        smb += le16(36)                           // StructureSize
        smb += le16(UInt16(dialects.count))
        smb += le16(1)                            // SecurityMode : signature activée
        smb += le16(0)
        smb += le32(0)                            // Capabilities
        smb += Array(clientGUID.prefix(16)) + [UInt8](repeating: 0, count: max(0, 16 - clientGUID.count))
        smb += le32(UInt32(contextOffset))        // NegotiateContextOffset
        smb += le16(2)                            // NegotiateContextCount
        smb += le16(0)
        for dialect in dialects { smb += le16(dialect) }
        while smb.count < contextOffset { smb.append(0) }
        // Contexte 1 : PREAUTH_INTEGRITY_CAPABILITIES (SHA-512).
        let saltBytes = Array(salt.prefix(32))
        smb += le16(0x0001) + le16(UInt16(6 + saltBytes.count)) + le32(0)
        smb += le16(1) + le16(UInt16(saltBytes.count)) + le16(0x0001) + saltBytes
        while smb.count % 8 != 0 { smb.append(0) }
        // Contexte 2 : ENCRYPTION_CAPABILITIES (AES-128-GCM, AES-128-CCM).
        smb += le16(0x0002) + le16(6) + le32(0)
        smb += le16(2) + le16(0x0002) + le16(0x0001)
        let length = smb.count
        let session: [UInt8] = [0x00, UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        return Data(session + smb)
    }

    /// Lit une réponse NEGOTIATE (avec ou sans en-tête de session NetBIOS) ; nil si illisible ou en erreur.
    public static func parseNegotiateResponse(_ data: Data) -> Negotiation? {
        var bytes = [UInt8](data)
        // En-tête de session NetBIOS (type 0x00, longueur sur 3 octets).
        if bytes.count >= 8, bytes[0] == 0x00, (bytes[4] == 0xFE || bytes[4] == 0xFF), bytes[5...7] == [0x53, 0x4D, 0x42] {
            bytes.removeFirst(4)
        }
        guard bytes.count >= 4 else { return nil }
        if bytes[0] == 0xFF, bytes[1...3] == [0x53, 0x4D, 0x42] {
            return Negotiation(dialect: nil, smb1Only: true, signingRequired: nil, sambaHint: false)
        }
        guard bytes[0] == 0xFE, bytes[1...3] == [0x53, 0x4D, 0x42], bytes.count >= 64 + 64 else { return nil }
        let status = readLE32(bytes, 8)
        let command = readLE16(bytes, 12)
        guard status == 0, command == 0 else { return nil }
        let body = 64
        guard readLE16(bytes, body) == 65 else { return nil }
        let securityMode = readLE16(bytes, body + 2)
        let dialect = readLE16(bytes, body + 4)
        let bufferOffset = Int(readLE16(bytes, body + 56))
        let bufferLength = Int(readLE16(bytes, body + 58))
        var samba = false
        if bufferLength > 0, bufferOffset + bufferLength <= bytes.count {
            let buffer = Data(bytes[bufferOffset..<(bufferOffset + bufferLength)])
            samba = buffer.range(of: Data("please_ignore".utf8)) != nil
        }
        return Negotiation(dialect: dialect, smb1Only: false, signingRequired: securityMode & 0x02 != 0, sambaHint: samba)
    }

    /// Observation d'une négociation lue sur `port`.
    public static func observation(port: UInt16, _ negotiation: Negotiation, at date: Date = Date()) -> FPServiceObservation {
        FPServiceObservation(port: port, smbDialect: negotiation.dialect, smb1Only: negotiation.smb1Only ? true : nil,
                             smbSigningRequired: negotiation.signingRequired,
                             smbSambaHint: negotiation.smb1Only ? nil : negotiation.sambaHint, observedAt: date)
    }

    // MARK: Octets

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) } }
    static func readLE16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}
