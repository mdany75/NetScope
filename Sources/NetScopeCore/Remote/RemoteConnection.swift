import Foundation

/// Protocole d'accès distant.
public enum RemoteProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case ssh, telnet, rdp, vnc, serie
    /// Note 50 : transfert de fichiers (navigateur intégré à NetScope).
    case ftp, ftps, sftp

    public var id: String { rawValue }

    /// Nom court (« SSH », « Série »).
    public var label: String {
        switch self {
        case .ssh: return "SSH"
        case .telnet: return "Telnet"
        case .rdp: return "RDP"
        case .vnc: return "VNC"
        case .serie: return "Série"
        case .ftp: return "FTP"
        case .ftps: return "FTPS"
        case .sftp: return "SFTP"
        }
    }

    /// Étiquette en majuscules des listes (« TELNET », « SÉRIE »).
    public var badge: String { label.uppercased() }

    /// Nom complet du détail.
    public var fullName: String {
        switch self {
        case .ssh: return "SSH (Secure Shell)"
        case .telnet: return "Telnet (non chiffré)"
        case .rdp: return "RDP (Bureau à distance)"
        case .vnc: return "VNC (bureau à distance, RFB)"
        case .serie: return "Console série"
        case .ftp: return "FTP (non chiffré)"
        case .ftps: return "FTPS (FTP sur TLS)"
        case .sftp: return "SFTP (fichiers par SSH)"
        }
    }

    /// Port par défaut (débit en bauds pour la série).
    public var defaultPort: Int {
        switch self {
        case .ssh, .sftp: return 22
        case .telnet: return 23
        case .rdp: return 3389
        case .vnc: return 5900
        case .serie: return 9600
        case .ftp: return 21
        case .ftps: return 990
        }
    }

    /// Le mot de passe circule en clair.
    public var isInsecure: Bool { self == .telnet || self == .ftp }

    /// Transfert de fichiers (FTP, FTPS, SFTP) : ouvert dans le navigateur de NetScope.
    public var isFileTransfer: Bool { self == .ftp || self == .ftps || self == .sftp }

    /// Protocoles proposés en premier (sessions), puis les transferts de fichiers.
    public static let sessionProtocols: [RemoteProtocol] = [.ssh, .telnet, .rdp, .vnc, .serie]
    public static let transferProtocols: [RemoteProtocol] = [.ftp, .ftps, .sftp]

    /// Application externe utilisée par « Connecter ».
    public var externalApp: String {
        switch self {
        case .ssh, .telnet, .serie: return "Terminal"
        case .rdp: return "Windows App"
        case .vnc: return "Partage d’écran"
        case .ftp, .ftps, .sftp: return "NetScope"
        }
    }

    /// Protocole correspondant à un port TCP ouvert.
    public static func forPort(_ port: UInt16) -> RemoteProtocol? {
        switch port {
        case 22: return .ssh
        case 23: return .telnet
        case 3389: return .rdp
        case 5900: return .vnc
        case 21: return .ftp
        case 990: return .ftps
        default: return nil
        }
    }
}

/// Connexion enregistrée.
public struct RemoteConnection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var proto: RemoteProtocol
    /// Hôte ou IP ; chemin du périphérique (/dev/cu.…) pour la série.
    public var host: String
    /// Port TCP ; débit en bauds pour la série.
    public var port: Int
    public var username: String
    /// Dossier ou site (« Siège › Réseau ») ; vide : « Non classé ».
    public var folder: String
    public var isFavorite: Bool
    /// Description libre (modèle, système).
    public var note: String
    public var lastConnected: Date?
    public var createdAt: Date
    /// Fenêtre ou plein écran, taille, échelle (RDP et VNC).
    public var display: RemoteDisplaySettings
    /// Note 50 : mode passif ou actif, TLS, identification SFTP, dossiers de départ (FTP, FTPS, SFTP).
    public var transfer: FileTransferSettings

    public init(id: UUID = UUID(), name: String, proto: RemoteProtocol, host: String, port: Int? = nil,
                username: String = "", folder: String = "", isFavorite: Bool = false, note: String = "",
                lastConnected: Date? = nil, createdAt: Date = Date(), display: RemoteDisplaySettings? = nil,
                transfer: FileTransferSettings = FileTransferSettings()) {
        self.id = id
        self.name = name
        self.proto = proto
        self.host = host
        self.port = port ?? proto.defaultPort
        self.username = username
        self.folder = folder
        self.isFavorite = isFavorite
        self.note = note
        self.lastConnected = lastConnected
        self.createdAt = createdAt
        self.display = display ?? .defaults(for: proto)
        self.transfer = transfer
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, proto, host, port, username, folder, isFavorite, note, lastConnected, createdAt, display, transfer
    }

    /// Les connexions enregistrées avant les réglages d'affichage (sans « display ») se lisent
    /// toujours, avec le comportement d'alors.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        proto = try c.decode(RemoteProtocol.self, forKey: .proto)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        folder = try c.decode(String.self, forKey: .folder)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        note = try c.decode(String.self, forKey: .note)
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        display = try c.decodeIfPresent(RemoteDisplaySettings.self, forKey: .display) ?? .defaults(for: proto)
        transfer = try c.decodeIfPresent(FileTransferSettings.self, forKey: .transfer) ?? FileTransferSettings()
    }

    /// « 10.182.122.2:22 » ou « cu.usbserial-A10K · 9600 8N1 ».
    public var address: String {
        if proto == .serie {
            let device = host.hasPrefix("/dev/") ? String(host.dropFirst(5)) : host
            return "\(device) · \(port) 8N1"
        }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Dossier affiché.
    public var folderLabel: String { folder.trimmingCharacters(in: .whitespaces).isEmpty ? "Non classé" : folder }

    /// Recherche multiple : nom, hôte, port, protocole, utilisateur, dossier, note
    /// (`proto:ssh dossier:Réseau`).
    public func matches(_ query: String) -> Bool {
        matchesSearch(query)
    }

    /// Copie à enregistrer sous un autre nom.
    public func duplicated(now: Date = Date()) -> RemoteConnection {
        var copy = self
        copy.id = UUID()
        copy.name = name + " (copie)"
        copy.isFavorite = false
        copy.lastConnected = nil
        copy.createdAt = now
        return copy
    }

    /// Vérifie les champs avant enregistrement ou lancement.
    public func validated() throws -> RemoteConnection {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty, !copy.name.contains("\n") else { throw RemoteValidationError.emptyName }
        if proto == .serie {
            copy.host = try RemoteValidator.validateSerialDevice(host)
            guard RemoteValidator.baudRates.contains(port) else { throw RemoteValidationError.invalidBaud(port) }
            copy.username = ""
        } else {
            copy.host = try RemoteValidator.validateHost(host)
            try RemoteValidator.validatePort(port)
            copy.username = try RemoteValidator.validateUser(username, allowDomain: proto == .rdp)
        }
        copy.folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.display.customWidth = RemoteDisplaySettings.clamp(display.customWidth, RemoteDisplaySettings.widthRange)
        copy.display.customHeight = RemoteDisplaySettings.clamp(display.customHeight, RemoteDisplaySettings.heightRange)
        return copy
    }
}

/// Enregistre les connexions en JSON dans ~/Library/Application Support/NetScope/connexions.json.
public struct RemoteConnectionStore: Sendable {
    private struct File: Codable {
        var version = 1
        var connections: [RemoteConnection]
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: RemoteConnectionStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return RemoteConnectionStore(url: base.appendingPathComponent("NetScope", isDirectory: true)
            .appendingPathComponent("connexions.json"))
    }

    /// nil : aucun fichier (premier lancement) ou fichier illisible.
    public func load() -> [RemoteConnection]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data))?.connections
    }

    public func save(_ connections: [RemoteConnection]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(connections: connections)).write(to: url, options: .atomic)
    }
}
