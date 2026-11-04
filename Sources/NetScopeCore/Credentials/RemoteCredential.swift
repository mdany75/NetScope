import Foundation

/// Identifiant SSH ou WMI (Réglages › Identifiants), sans son secret : le mot de passe ou la
/// phrase secrète de la clé vit au Trousseau (service `keychainService`, compte `keychainAccount`).
/// Servira plus tard à l'Inventaire (relevé du matériel et des logiciels).
public struct RemoteCredential: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ssh, wmi

        public var label: String { self == .ssh ? "SSH" : "WMI" }
        public var defaultPort: UInt16 { self == .ssh ? 22 : 135 }
    }

    public enum SSHMethod: String, Codable, CaseIterable, Sendable {
        case password, key

        public var label: String { self == .password ? "Mot de passe" : "Clé" }
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    public var user: String
    public var port: UInt16
    public var sshMethod: SSHMethod
    /// Clé privée choisie (« ~/.ssh/id_ed25519 »), méthode Clé.
    public var keyPath: String
    /// Domaine Windows (WMI), vide pour un compte local.
    public var domain: String
    /// Portée prévue (« Plage 10.10.0.0/24 », « Serveurs »), texte libre.
    public var scope: String
    /// Dernière adresse testée.
    public var lastHost: String
    public var lastTestAt: Date?
    public var lastTestStatus: CredentialTestOutcome.Status?
    public var lastTestMessage: String

    public init(id: UUID = UUID(), kind: Kind, name: String, user: String = "", port: UInt16? = nil,
                sshMethod: SSHMethod = .key, keyPath: String = "", domain: String = "", scope: String = "",
                lastHost: String = "", lastTestAt: Date? = nil, lastTestStatus: CredentialTestOutcome.Status? = nil, lastTestMessage: String = "") {
        self.id = id
        self.kind = kind
        self.name = name
        self.user = user
        self.port = port ?? kind.defaultPort
        self.sshMethod = sshMethod
        self.keyPath = keyPath
        self.domain = domain
        self.scope = scope
        self.lastHost = lastHost
        self.lastTestAt = lastTestAt
        self.lastTestStatus = lastTestStatus
        self.lastTestMessage = lastTestMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .ssh
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? kind.defaultPort
        sshMethod = try c.decodeIfPresent(SSHMethod.self, forKey: .sshMethod) ?? .key
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        lastHost = try c.decodeIfPresent(String.self, forKey: .lastHost) ?? ""
        lastTestAt = try c.decodeIfPresent(Date.self, forKey: .lastTestAt)
        lastTestStatus = try c.decodeIfPresent(CredentialTestOutcome.Status.self, forKey: .lastTestStatus)
        lastTestMessage = try c.decodeIfPresent(String.self, forKey: .lastTestMessage) ?? ""
    }

    /// Service du Trousseau des secrets de ce type d'identifiant.
    public static func keychainService(_ kind: Kind) -> String {
        kind == .ssh ? "com.danymenard.netscope.ssh" : "com.danymenard.netscope.wmi"
    }

    public var keychainService: String { Self.keychainService(kind) }
    public var keychainAccount: String { id.uuidString }

    /// « DOMAINE\utilisateur » (WMI), « utilisateur » sinon.
    public var qualifiedUser: String {
        kind == .wmi && !domain.isEmpty ? "\(domain)\\\(user)" : user
    }

    /// Lit « DOMAINE\utilisateur » ou « utilisateur@domaine » saisi d'un bloc.
    public static func splitWindowsUser(_ text: String) -> (domain: String, user: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let slash = trimmed.firstIndex(of: "\\") {
            return (String(trimmed[..<slash]), String(trimmed[trimmed.index(after: slash)...]))
        }
        if let at = trimmed.lastIndex(of: "@"), trimmed.firstIndex(of: "@") == at {
            return (String(trimmed[trimmed.index(after: at)...]), String(trimmed[..<at]))
        }
        return ("", trimmed)
    }

    /// Description de la méthode (« Clé ~/.ssh/id_ed25519 », « Mot de passe », « DCOM 135, WinRM 5985/5986 »).
    public var methodSummary: String {
        switch kind {
        case .ssh: return sshMethod == .key ? "Clé \(keyPath.isEmpty ? "(à choisir)" : keyPath)" : "Mot de passe"
        case .wmi: return "DCOM 135 · WinRM 5985/5986"
        }
    }
}

/// Liste des identifiants SSH/WMI, enregistrée en JSON (identifiants.json), jamais avec les secrets.
public struct RemoteCredentialStore: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = RemoteCredentialStore.currentVersion
    public var credentials: [RemoteCredential]

    public init(credentials: [RemoteCredential] = []) {
        self.credentials = credentials
    }

    public static func load(from url: URL) -> RemoteCredentialStore {
        guard let data = try? Data(contentsOf: url) else { return RemoteCredentialStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RemoteCredentialStore.self, from: data)) ?? RemoteCredentialStore()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
