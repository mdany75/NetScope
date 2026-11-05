import Foundation

// Note 50 : connexion FTP, FTPS et SFTP. API commune `RemoteFileTransfer` (FTPClient, SFTPClient),
// réutilisable ailleurs (Vitesse des disques, note 55 ; sauvegardes des configurations, note 40).

/// Mode de la connexion de données FTP.
public enum FTPDataMode: String, Codable, CaseIterable, Sendable {
    /// Le Mac se connecte au serveur (EPSV, sinon PASV) : passe les pare-feu et le NAT.
    case passive
    /// Le serveur se connecte au Mac (EPRT, sinon PORT) : vieux appareils seulement.
    case active

    public var label: String { self == .passive ? "Passif" : "Actif" }
}

/// FTPS : TLS négocié après la connexion (AUTH TLS, port 21) ou dès la connexion (port 990).
public enum FTPSMode: String, Codable, CaseIterable, Sendable {
    case explicit, implicit

    public var label: String { self == .explicit ? "TLS explicite" : "TLS implicite" }
    public var defaultPort: Int { self == .explicit ? 21 : 990 }
}

/// Identification SFTP.
public enum SFTPAuth: String, Codable, CaseIterable, Sendable {
    /// Mot de passe du Trousseau (demandé à ssh par SSH_ASKPASS, jamais écrit sur le disque).
    case password
    /// Clé privée choisie (phrase secrète éventuelle au Trousseau).
    case key
    /// Clés de ~/.ssh et agent SSH, comme « ssh » dans Terminal.
    case agent

    public var label: String {
        switch self {
        case .password: return "Mot de passe"
        case .key: return "Clé"
        case .agent: return "Clés de ~/.ssh"
        }
    }
}

/// Réglages propres aux transferts, enregistrés avec la connexion (jamais de secret).
public struct FileTransferSettings: Codable, Hashable, Sendable {
    public var dataMode: FTPDataMode
    public var tlsMode: FTPSMode
    public var sftpAuth: SFTPAuth
    /// Clé privée (« ~/.ssh/id_ed25519 »), méthode Clé.
    public var keyPath: String
    /// Dossier distant ouvert à la connexion (vide : dossier d'accueil).
    public var remoteDirectory: String
    /// Dossier du Mac du volet de gauche (vide : Téléchargements).
    public var localDirectory: String
    /// Empreinte SHA-256 du certificat FTPS accepté par l'utilisateur (certificat autosigné).
    public var trustedCertificateSHA256: String?

    public init(dataMode: FTPDataMode = .passive, tlsMode: FTPSMode = .explicit, sftpAuth: SFTPAuth = .password,
                keyPath: String = "", remoteDirectory: String = "", localDirectory: String = "",
                trustedCertificateSHA256: String? = nil) {
        self.dataMode = dataMode
        self.tlsMode = tlsMode
        self.sftpAuth = sftpAuth
        self.keyPath = keyPath
        self.remoteDirectory = remoteDirectory
        self.localDirectory = localDirectory
        self.trustedCertificateSHA256 = trustedCertificateSHA256
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dataMode = try c.decodeIfPresent(FTPDataMode.self, forKey: .dataMode) ?? .passive
        tlsMode = try c.decodeIfPresent(FTPSMode.self, forKey: .tlsMode) ?? .explicit
        sftpAuth = try c.decodeIfPresent(SFTPAuth.self, forKey: .sftpAuth) ?? .password
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        remoteDirectory = try c.decodeIfPresent(String.self, forKey: .remoteDirectory) ?? ""
        localDirectory = try c.decodeIfPresent(String.self, forKey: .localDirectory) ?? ""
        trustedCertificateSHA256 = try c.decodeIfPresent(String.self, forKey: .trustedCertificateSHA256)
    }
}

/// Où et comment se connecter : tout ce qu'il faut à un client, secret compris (en mémoire seulement).
public struct FileTransferEndpoint: Sendable {
    public var proto: RemoteProtocol
    public var host: String
    public var port: Int
    public var user: String
    /// Mot de passe (FTP, FTPS, SFTP par mot de passe) ou phrase secrète de la clé ; lu au Trousseau
    /// juste avant la connexion, jamais enregistré ailleurs.
    public var secret: String?
    public var settings: FileTransferSettings
    /// Délai d'attente d'une réponse (secondes).
    public var timeout: TimeInterval
    /// SFTP : accepter la clé d'un serveur encore inconnu (après l'accord de l'utilisateur).
    public var acceptNewHostKey: Bool

    public init(proto: RemoteProtocol, host: String, port: Int? = nil, user: String = "", secret: String? = nil,
                settings: FileTransferSettings = FileTransferSettings(), timeout: TimeInterval = 20,
                acceptNewHostKey: Bool = false) {
        self.proto = proto
        self.host = host
        self.port = port ?? proto.defaultPort
        self.user = user
        self.secret = secret
        self.settings = settings
        self.timeout = timeout
        self.acceptNewHostKey = acceptNewHostKey
    }

    public init(connection: RemoteConnection, secret: String?, acceptNewHostKey: Bool = false) {
        self.init(proto: connection.proto, host: connection.host, port: connection.port, user: connection.username,
                  secret: secret, settings: connection.transfer, acceptNewHostKey: acceptNewHostKey)
    }

    /// Utilisateur envoyé au serveur FTP : « anonymous » si le champ est vide.
    public var ftpUser: String { user.trimmingCharacters(in: .whitespaces).isEmpty ? "anonymous" : user }
}

/// Erreurs des transferts, expliquées en français.
public enum FileTransferError: Error, Equatable, LocalizedError, Sendable {
    case notTransferProtocol
    case connectionFailed(String)
    case timeout
    case loginFailed(String)
    case tlsUnavailable(String)
    /// Certificat FTPS non reconnu : empreinte SHA-256 et résumé (sujet), à faire accepter.
    case untrustedCertificate(sha256: String, subject: String)
    /// SFTP : clé du serveur inconnue (empreinte), à faire accepter.
    case unknownHostKey(fingerprint: String)
    /// SFTP : la clé du serveur a CHANGÉ depuis la dernière fois.
    case hostKeyChanged
    case server(String)
    case notFound(String)
    case permissionDenied(String)
    case invalidName(String)
    case protocolViolation(String)
    case localFile(String)
    case cancelled
    case toolMissing(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notTransferProtocol: return "Cette connexion n’est pas une connexion FTP, FTPS ou SFTP."
        case .connectionFailed(let detail): return "Connexion impossible\u{00A0}: \(detail)"
        case .timeout: return "Le serveur ne répond pas (délai dépassé)."
        case .loginFailed(let detail): return "Identification refusée\u{00A0}: \(detail). Vérifiez l’utilisateur et le mot de passe."
        case .tlsUnavailable(let detail): return "Chiffrement TLS impossible\u{00A0}: \(detail)"
        case .untrustedCertificate(_, let subject):
            return "Le certificat du serveur n’est pas reconnu (\(subject)). Vérifiez son empreinte avant de lui faire confiance."
        case .unknownHostKey(let fingerprint):
            return "Serveur SSH inconnu\u{00A0}: empreinte \(fingerprint). Vérifiez-la avant de lui faire confiance."
        case .hostKeyChanged:
            return "La clé du serveur SSH a changé depuis la dernière connexion\u{00A0}: connexion refusée. Si l’appareil a été remplacé ou réinstallé, retirez l’ancienne clé de ~/.ssh/known_hosts (ssh-keygen -R hôte)."
        case .server(let detail): return "Le serveur a refusé\u{00A0}: \(detail)"
        case .notFound(let path): return "Introuvable sur le serveur\u{00A0}: \(path)"
        case .permissionDenied(let path): return "Accès refusé\u{00A0}: \(path)"
        case .invalidName(let name): return "Nom invalide\u{00A0}: « \(name) »"
        case .protocolViolation(let detail): return detail
        case .localFile(let detail): return "Fichier du Mac\u{00A0}: \(detail)"
        case .cancelled: return "Transfert annulé."
        case .toolMissing(let tool): return "\(tool) est introuvable sur ce Mac."
        case .unsupported(let detail): return detail
        }
    }

    /// L'erreur vient d'une coupure : le transfert peut reprendre là où il s'est arrêté.
    public var isResumable: Bool {
        switch self {
        case .connectionFailed, .timeout: return true
        case .server(let detail): return detail.hasPrefix("4")
        default: return false
        }
    }
}

/// Avancement d'un transfert : octets déjà présents à l'arrivée + octets transférés.
public typealias FileTransferProgress = @Sendable (Int64) -> Void

/// Client de transfert de fichiers commun à FTP, FTPS et SFTP. Une instance = une session ; ses
/// opérations s'exécutent l'une après l'autre (pas de commandes entremêlées sur une connexion).
public protocol RemoteFileTransfer: AnyObject, Sendable {
    /// Ouvre la session et renvoie le dossier de départ.
    func connect() async throws -> String
    func list(_ path: String) async throws -> [RemoteFileEntry]
    /// Taille d'un fichier distant (nil si inconnue).
    func size(of path: String) async throws -> Int64?
    /// Reçoit `remotePath` dans `localURL` ; `resume` : complète un fichier local partiel.
    func download(_ remotePath: String, to localURL: URL, resume: Bool, progress: @escaping FileTransferProgress) async throws
    /// Envoie `localURL` vers `remotePath` ; `resume` : complète un fichier distant partiel.
    func upload(_ localURL: URL, to remotePath: String, resume: Bool, progress: @escaping FileTransferProgress) async throws
    func makeDirectory(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    func deleteFile(_ path: String) async throws
    /// Supprime un dossier vide.
    func removeDirectory(_ path: String) async throws
    func close() async
}

public extension RemoteFileTransfer {
    /// Supprime un dossier et tout son contenu (après confirmation de l'utilisateur) ; renvoie le
    /// nombre d'éléments supprimés. Les liens sont supprimés comme des fichiers, jamais suivis.
    @discardableResult
    func deleteRecursively(_ entry: RemoteFileEntry, depth: Int = 0) async throws -> Int {
        guard entry.kind == .directory else {
            try await deleteFile(entry.path)
            return 1
        }
        guard depth < 32 else { throw FileTransferError.unsupported("Arborescence trop profonde (plus de 32 niveaux).") }
        var count = 0
        for child in try await list(entry.path) {
            try Task.checkCancellation()
            count += try await deleteRecursively(child, depth: depth + 1)
        }
        try await removeDirectory(entry.path)
        return count + 1
    }

    /// Tous les fichiers sous un dossier distant (chemins relatifs au dossier), pour recevoir un
    /// dossier entier ; les liens ne sont pas suivis.
    func walk(_ directory: String, prefix: String = "", depth: Int = 0) async throws -> [(entry: RemoteFileEntry, relative: String)] {
        guard depth < 32 else { return [] }
        var result: [(RemoteFileEntry, String)] = []
        for child in try await list(directory).sorted(by: RemoteFileEntry.browserOrder) {
            // Le nom sert de chemin local : un nom piégé (« ../x ») n'est jamais suivi.
            guard RemotePath.isSafeEntryName(child.name) else { continue }
            let relative = prefix.isEmpty ? child.name : prefix + "/" + child.name
            switch child.kind {
            case .directory:
                result.append((child, relative))
                result += try await walk(child.path, prefix: relative, depth: depth + 1)
            case .file:
                result.append((child, relative))
            case .link:
                continue
            }
        }
        return result
    }
}

/// Crée le client qui convient à la connexion.
public enum FileTransferClients {
    public static func make(_ endpoint: FileTransferEndpoint) throws -> RemoteFileTransfer {
        switch endpoint.proto {
        case .ftp, .ftps: return FTPClient(endpoint: endpoint)
        case .sftp: return SFTPClient(endpoint: endpoint)
        default: throw FileTransferError.notTransferProtocol
        }
    }
}

/// Verrou asynchrone : une opération à la fois sur une même session.
public actor FileTransferSerialLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
