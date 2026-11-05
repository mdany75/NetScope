import Foundation

/// Bornes des options TFTP.
public enum TFTPLimits {
    /// Taille de bloc de la RFC 1350.
    public static let defaultBlockSize = 512
    /// Bornes de blksize (RFC 2348).
    public static let minBlockSize = 8
    public static let maxBlockSize = 65_464
    /// Bloc qui tient dans une trame Ethernet de 1 500 octets (1 500 − IP 20 − UDP 8 − TFTP 4).
    public static let ethernetBlockSize = 1_468
    /// Bornes de timeout en secondes (RFC 2349).
    public static let timeoutRange = 1...255
    /// Bornes de windowsize (RFC 7440).
    public static let windowRange = 1...65_535
    /// Délai d'attente par défaut avant une retransmission (secondes).
    public static let defaultTimeout: TimeInterval = 3
    /// Nombre de retransmissions avant l'abandon.
    public static let defaultRetries = 5
}

/// Réglages d'un transfert, après la négociation des options.
public struct TFTPTransferSettings: Equatable, Sendable {
    public var blockSize: Int
    public var windowSize: Int
    /// Délai avant retransmission (secondes).
    public var timeout: TimeInterval
    public var retries: Int
    /// Taille annoncée du fichier (option tsize), si connue.
    public var transferSize: Int64?
    public var mode: TFTPMode

    public init(blockSize: Int = TFTPLimits.defaultBlockSize, windowSize: Int = 1, timeout: TimeInterval = TFTPLimits.defaultTimeout,
                retries: Int = TFTPLimits.defaultRetries, transferSize: Int64? = nil, mode: TFTPMode = .octet) {
        self.blockSize = min(max(blockSize, TFTPLimits.minBlockSize), TFTPLimits.maxBlockSize)
        self.windowSize = min(max(windowSize, TFTPLimits.windowRange.lowerBound), TFTPLimits.windowRange.upperBound)
        self.timeout = timeout.isFinite ? min(max(timeout, 0.05), 255) : TFTPLimits.defaultTimeout
        self.retries = max(0, retries)
        self.transferSize = transferSize
        self.mode = mode
    }
}

/// Limites du serveur pour les options demandées par les clients.
public struct TFTPServerPolicy: Equatable, Sendable {
    /// Taille de bloc maximale acceptée (une demande plus grande est ramenée à cette valeur).
    public var maxBlockSize: Int
    /// Fenêtre maximale acceptée (RFC 7440).
    public var maxWindowSize: Int
    /// Délai par défaut quand le client ne demande pas l'option timeout.
    public var timeout: TimeInterval
    public var retries: Int
    /// Taille maximale d'un fichier reçu (protection du disque) ; nil : pas de limite.
    public var maxWriteSize: Int64?

    public init(maxBlockSize: Int = TFTPLimits.maxBlockSize, maxWindowSize: Int = 16, timeout: TimeInterval = TFTPLimits.defaultTimeout,
                retries: Int = TFTPLimits.defaultRetries, maxWriteSize: Int64? = nil) {
        self.maxBlockSize = min(max(maxBlockSize, TFTPLimits.minBlockSize), TFTPLimits.maxBlockSize)
        self.maxWindowSize = min(max(maxWindowSize, 1), TFTPLimits.windowRange.upperBound)
        self.timeout = timeout
        self.retries = retries
        self.maxWriteSize = maxWriteSize
    }
}

/// Négociation des options (RFC 2347 à 2349, RFC 7440), côté serveur et côté client.
public enum TFTPNegotiation {
    /// Options reconnues par NetScope.
    public static let known: Set<String> = ["blksize", "tsize", "timeout", "windowsize"]

    /// Côté serveur : options acceptées et réglages du transfert. `fileSize` est la taille du fichier
    /// lu (RRQ) ; pour une écriture (WRQ), tsize est la taille annoncée par le client, renvoyée telle
    /// quelle. Les options inconnues ou invalides sont ignorées (absentes de l'OACK). Un OACK vide
    /// n'est pas envoyé : le transfert suit alors la RFC 1350.
    public static func server(_ request: TFTPRequest, policy: TFTPServerPolicy,
                              fileSize: Int64?) -> (settings: TFTPTransferSettings, oack: [TFTPOption]) {
        var settings = TFTPTransferSettings(timeout: policy.timeout, retries: policy.retries, mode: request.mode)
        var oack: [TFTPOption] = []
        for option in request.options {
            switch option.name {
            case "blksize":
                guard let value = Int(option.value), value >= TFTPLimits.minBlockSize else { continue }
                let accepted = min(value, policy.maxBlockSize, TFTPLimits.maxBlockSize)
                settings.blockSize = accepted
                oack.append(TFTPOption("blksize", String(accepted)))
            case "timeout":
                guard let value = Int(option.value), TFTPLimits.timeoutRange.contains(value) else { continue }
                settings.timeout = TimeInterval(value)
                oack.append(TFTPOption("timeout", String(value)))
            case "tsize":
                guard let value = Int64(option.value), value >= 0 else { continue }
                switch request.kind {
                case .read:
                    guard let fileSize else { continue }
                    settings.transferSize = fileSize
                    oack.append(TFTPOption("tsize", String(fileSize)))
                case .write:
                    settings.transferSize = value
                    oack.append(TFTPOption("tsize", String(value)))
                }
            case "windowsize":
                guard let value = Int(option.value), TFTPLimits.windowRange.contains(value) else { continue }
                let accepted = min(value, policy.maxWindowSize)
                settings.windowSize = accepted
                oack.append(TFTPOption("windowsize", String(accepted)))
            default:
                continue
            }
        }
        return (settings, oack)
    }

    /// Côté client : options à demander.
    public static func clientOptions(blockSize: Int, windowSize: Int, timeout: Int?, transferSize: Int64?) -> [TFTPOption] {
        var options: [TFTPOption] = []
        if blockSize != TFTPLimits.defaultBlockSize {
            options.append(TFTPOption("blksize", String(min(max(blockSize, TFTPLimits.minBlockSize), TFTPLimits.maxBlockSize))))
        }
        if let timeout, TFTPLimits.timeoutRange.contains(timeout) { options.append(TFTPOption("timeout", String(timeout))) }
        // tsize : 0 pour une lecture (le serveur répond la taille), la taille du fichier pour une écriture.
        options.append(TFTPOption("tsize", String(max(transferSize ?? 0, 0))))
        if windowSize > 1 { options.append(TFTPOption("windowsize", String(min(windowSize, TFTPLimits.windowRange.upperBound)))) }
        return options
    }

    /// Côté client : réglages tirés de l'OACK du serveur. Une option non demandée, ou une valeur
    /// plus grande que celle demandée, est une erreur (le client répond alors ERROR 8).
    public static func client(oack: [TFTPOption], requested: [TFTPOption], base: TFTPTransferSettings) -> Result<TFTPTransferSettings, TFTPFailure> {
        var settings = base
        settings.blockSize = TFTPLimits.defaultBlockSize
        settings.windowSize = 1
        for option in oack {
            guard let asked = requested.first(where: { $0.name == option.name }) else {
                return .failure(.protocolError("option «\u{00A0}\(option.name)\u{00A0}» non demandée dans l’OACK"))
            }
            switch option.name {
            case "blksize":
                guard let value = Int(option.value), let max = Int(asked.value),
                      value >= TFTPLimits.minBlockSize, value <= max else {
                    return .failure(.protocolError("blksize invalide dans l’OACK («\u{00A0}\(option.value)\u{00A0}»)"))
                }
                settings.blockSize = value
            case "timeout":
                guard let value = Int(option.value), TFTPLimits.timeoutRange.contains(value) else {
                    return .failure(.protocolError("timeout invalide dans l’OACK («\u{00A0}\(option.value)\u{00A0}»)"))
                }
                settings.timeout = TimeInterval(value)
            case "tsize":
                guard let value = Int64(option.value), value >= 0 else {
                    return .failure(.protocolError("tsize invalide dans l’OACK («\u{00A0}\(option.value)\u{00A0}»)"))
                }
                settings.transferSize = value
            case "windowsize":
                guard let value = Int(option.value), let max = Int(asked.value), value >= 1, value <= max else {
                    return .failure(.protocolError("windowsize invalide dans l’OACK («\u{00A0}\(option.value)\u{00A0}»)"))
                }
                settings.windowSize = value
            default:
                return .failure(.protocolError("option «\u{00A0}\(option.name)\u{00A0}» inconnue dans l’OACK"))
            }
        }
        return .success(settings)
    }
}
