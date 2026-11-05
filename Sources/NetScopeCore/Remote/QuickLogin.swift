import Foundation

// Note 52 : nom d'utilisateur demandé à chaque connexion rapide (SSH depuis le Scanner, la fiche
// Appareil, le scan des ports ; Telnet, RDP et VNC quand ils demandent un compte). Le nom, le port
// et la méthode sont retenus par appareil et par site, jamais un mot de passe : un secret reste au
// Trousseau (identifiant SSH des Réglages) ou est demandé par ssh dans Terminal.

/// Adresse saisie d'un bloc : « admin@10.0.0.2 », « admin@10.0.0.2:2222 », « ssh://admin@sw1 »,
/// « admin@[fe80::1]:22 » ou simplement « 10.0.0.2 ».
public struct QuickLoginAddress: Equatable, Sendable {
    public var user: String
    public var host: String
    /// Port écrit dans l'adresse (« :2222 »), sinon nil.
    public var port: Int?

    public init(user: String = "", host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }

    /// Lit et valide l'adresse (mêmes règles que les connexions enregistrées) ; l'utilisateur est
    /// séparé au DERNIER « @ » (« admin@corp@10.0.0.2 » : utilisateur « admin@corp »), comme ssh.
    public static func parse(_ text: String) throws -> QuickLoginAddress {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["ssh://", "telnet://", "vnc://", "rdp://", "sftp://", "ftps://", "ftpes://", "ftp://"] where rest.lowercased().hasPrefix(scheme) {
            rest = String(rest.dropFirst(scheme.count))
        }
        if rest.hasSuffix("/") { rest.removeLast() }
        var user = ""
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
            // « admin%40corp » d'une URL ssh://
            user = user.removingPercentEncoding ?? user
        }
        var host = rest
        var port: Int?
        if rest.hasPrefix("[") {
            // IPv6 entre crochets, port facultatif après « ]: ».
            guard let close = rest.firstIndex(of: "]") else { throw RemoteValidationError.invalidHost(rest) }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let value = Int(after.dropFirst()) else { throw RemoteValidationError.invalidHost(rest) }
                port = value
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            // Un seul deux-points : « hôte:port » (une IPv6 en a au moins deux).
            host = String(rest[..<colon])
            guard let value = Int(rest[rest.index(after: colon)...]) else { throw RemoteValidationError.invalidPort(0) }
            port = value
        }
        let validHost = try RemoteValidator.validateHost(host)
        if let port { try RemoteValidator.validatePort(port) }
        return QuickLoginAddress(user: try QuickLogin.validateUser(user), host: validHost, port: port)
    }

    /// Champ « Utilisateur » de la feuille : « admin » reste un nom, « admin@10.0.0.2 » ou
    /// « admin@10.0.0.2:2222 » (forme user@ip) donne l'utilisateur, l'hôte et le port. Ce qui suit
    /// le dernier « @ » n'est pris pour l'hôte que si c'est une adresse IP, l'hôte de l'appareil
    /// ou une adresse avec port : « admin@corp.local » reste un nom de domaine (compte AD).
    public static func splitUserField(_ text: String, defaultHost: String) -> QuickLoginAddress {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        let hasScheme = ["ssh://", "telnet://"].contains { lower.hasPrefix($0) }
        guard trimmed.contains("@") || hasScheme, let address = try? parse(trimmed) else {
            return QuickLoginAddress(user: trimmed, host: defaultHost)
        }
        let isIP = IPv4Address(address.host) != nil || address.host.contains(":")
        if hasScheme || isIP || address.port != nil || address.host.caseInsensitiveCompare(defaultHost) == .orderedSame {
            return address
        }
        return QuickLoginAddress(user: trimmed, host: defaultHost)
    }

    /// « admin@10.0.0.2 », « admin@[fe80::1]:2222 », « 10.0.0.2:2222 ».
    public func formatted(defaultPort: Int = 22) -> String {
        let bracketed = host.contains(":") && port != nil && port != defaultPort ? "[\(host)]" : host
        var text = user.isEmpty ? bracketed : "\(user)@\(bracketed)"
        if let port, port != defaultPort { text += ":\(port)" }
        return text
    }
}

/// Méthode d'identification d'une connexion SSH rapide.
public enum QuickLoginAuth: String, Codable, CaseIterable, Sendable {
    /// Clés par défaut de ~/.ssh et agent SSH ; ssh demande le mot de passe au besoin.
    case automatic
    /// Clé privée choisie (« -i », seules les clés choisies sont essayées).
    case key
    /// Mot de passe demandé par ssh dans Terminal (clés désactivées).
    case password

    public var label: String {
        switch self {
        case .automatic: return "Automatique"
        case .key: return "Clé"
        case .password: return "Mot de passe"
        }
    }
}

/// Ce qui est demandé dans la feuille de connexion, prêt à lancer.
public struct QuickLoginChoice: Equatable, Sendable {
    public var proto: RemoteProtocol
    public var host: String
    public var user: String
    public var port: Int
    public var auth: QuickLoginAuth
    /// Clé privée (méthode Clé).
    public var keyPath: String
    /// Identifiant SSH des Réglages choisi (nom, port et clé repris de lui).
    public var credentialID: UUID?

    public init(proto: RemoteProtocol = .ssh, host: String, user: String = "", port: Int? = nil,
                auth: QuickLoginAuth = .automatic, keyPath: String = "", credentialID: UUID? = nil) {
        self.proto = proto
        self.host = host
        self.user = user
        self.port = port ?? proto.defaultPort
        self.auth = auth
        self.keyPath = keyPath
        self.credentialID = credentialID
    }

    /// Choix validé (hôte, port, utilisateur, clé) ; seule une liste fermée de caractères passe.
    public func validated() throws -> QuickLoginChoice {
        var copy = self
        copy.host = try RemoteValidator.validateHost(host)
        try RemoteValidator.validatePort(port)
        copy.user = try QuickLogin.validateUser(user, allowDomain: proto == .rdp)
        copy.keyPath = keyPath.trimmingCharacters(in: .whitespaces)
        if proto == .ssh, auth == .key {
            copy.keyPath = try QuickLogin.validateKeyPath(copy.keyPath)
        } else {
            copy.keyPath = auth == .key ? copy.keyPath : ""
        }
        return copy
    }
}

/// Erreurs propres aux connexions rapides.
public enum QuickLoginError: Error, Equatable, LocalizedError {
    case invalidKeyPath(String)
    case unsupportedProtocol(RemoteProtocol)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyPath(let path):
            return path.isEmpty ? "Choisissez la clé privée à utiliser." : "Chemin de clé invalide\u{00A0}: «\u{00A0}\(path)\u{00A0}»."
        case .unsupportedProtocol(let proto): return "Connexion rapide impossible en \(proto.label)."
        }
    }
}

/// Validation, commande et plan de lancement des connexions rapides.
public enum QuickLogin {
    /// Noms proposés quand rien n'a encore été utilisé (switchs, Linux, bornes, onduleurs).
    public static let commonUsers = ["admin", "root", "manager", "netadmin", "ubnt", "pi", "cisco"]

    /// Utilisateur : vide permis (ssh prend alors le nom de la session macOS) ; mêmes caractères que
    /// les connexions enregistrées ([A-Za-z0-9._@-], « \ » de domaine en RDP), jamais d'espace,
    /// de « $ », de « ; », d'apostrophe ni de guillemet, ni de tiret au début.
    @discardableResult
    public static func validateUser(_ text: String, allowDomain: Bool = false) throws -> String {
        try RemoteValidator.validateUser(text, allowDomain: allowDomain)
    }

    /// Clé privée : chemin absolu ou « ~/… », caractères [A-Za-z0-9._/~ -] et lettres accentuées,
    /// sans « .. » ni retour à la ligne ; le chemin est de toute façon mis entre apostrophes.
    public static func validateKeyPath(_ text: String) throws -> String {
        let path = text.trimmingCharacters(in: .whitespaces)
        let allowedPunctuation = Set("._/~- +@")
        let valid = !path.isEmpty && path.count <= 512 && (path.hasPrefix("/") || path.hasPrefix("~/"))
            && !path.contains("..")
            && path.allSatisfy { $0.isLetter || $0.isNumber || allowedPunctuation.contains($0) }
        guard valid else { throw QuickLoginError.invalidKeyPath(path) }
        return path
    }

    /// « ssh -- admin@10.0.0.2 », « ssh -p 2222 -- admin@10.0.0.2 »,
    /// « ssh -i /Users/x/.ssh/id_ed25519 -o IdentitiesOnly=yes -- admin@10.0.0.2 ».
    /// Chaque mot est échappé (RemoteShell) : aucun champ n'est jamais interprété par le shell.
    /// `home` remplace « ~ » (le chemin entre apostrophes ne serait pas développé par zsh).
    public static func sshCommand(user: String, host: String, port: Int, auth: QuickLoginAuth = .automatic,
                                  keyPath: String = "", home: String = NSHomeDirectory()) -> String {
        var words = ["ssh"]
        if auth == .key, !keyPath.isEmpty {
            let expanded = keyPath.hasPrefix("~/") ? home + keyPath.dropFirst(1) : keyPath
            words += ["-i", expanded, "-o", "IdentitiesOnly=yes"]
        }
        if auth == .password {
            words += ["-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "PubkeyAuthentication=no"]
        }
        if port != 22 { words += ["-p", String(port)] }
        if user.contains("@") {
            // « admin@corp » : « -l » évite toute ambiguïté avec le « @ » de la destination.
            words += ["-l", user, "--", host]
        } else {
            words += ["--", user.isEmpty ? host : "\(user)@\(host)"]
        }
        return RemoteShell.command(words)
    }

    /// Connexion équivalente (nom affiché, protocole, hôte, port, utilisateur), pour le carnet.
    public static func connection(for choice: QuickLoginChoice, name: String, folder: String = "") -> RemoteConnection {
        let cleaned = RemoteShell.sanitizedTitle(name)
        return RemoteConnection(name: cleaned.isEmpty ? choice.host : cleaned, proto: choice.proto, host: choice.host,
                                port: choice.port, username: choice.user, folder: folder)
    }

    /// Plan de lancement : commande ssh avec clé ou méthode choisie, sinon celui du carnet.
    public static func plan(for choice: QuickLoginChoice, name: String, home: String = NSHomeDirectory(),
                            telnetPath: String? = RemoteLauncher.findTelnet()) throws -> RemoteLaunchPlan {
        let c = try choice.validated()
        switch c.proto {
        case .ssh:
            return .terminal(command: sshCommand(user: c.user, host: c.host, port: c.port, auth: c.auth, keyPath: c.keyPath, home: home))
        case .telnet, .rdp, .vnc:
            return try RemoteLauncher.plan(for: connection(for: c, name: name), telnetPath: telnetPath)
        case .serie, .ftp, .ftps, .sftp:
            throw QuickLoginError.unsupportedProtocol(c.proto)
        }
    }
}

/// Ce qui est retenu d'une connexion rapide : appareil (MAC, sinon IP dans son site), protocole,
/// nom, port, méthode et clé. Jamais de mot de passe.
public struct QuickLoginEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var proto: RemoteProtocol
    /// Adresse MAC « AA:BB:CC:DD:EE:FF » (l'appareil garde son nom s'il change d'IP).
    public var mac: String?
    public var host: String
    public var siteID: UUID?
    public var user: String
    public var port: Int
    public var auth: QuickLoginAuth
    public var keyPath: String
    public var credentialID: UUID?
    /// « Ne plus demander pour cet appareil » : la connexion part sans la feuille.
    public var skipPrompt: Bool
    public var lastUsed: Date

    public init(id: UUID = UUID(), proto: RemoteProtocol = .ssh, mac: String? = nil, host: String, siteID: UUID? = nil,
                user: String, port: Int? = nil, auth: QuickLoginAuth = .automatic, keyPath: String = "",
                credentialID: UUID? = nil, skipPrompt: Bool = false, lastUsed: Date = Date()) {
        self.id = id
        self.proto = proto
        self.mac = mac?.uppercased()
        self.host = host
        self.siteID = siteID
        self.user = user
        self.port = port ?? proto.defaultPort
        self.auth = auth
        self.keyPath = keyPath
        self.credentialID = credentialID
        self.skipPrompt = skipPrompt
        self.lastUsed = lastUsed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        proto = try c.decodeIfPresent(RemoteProtocol.self, forKey: .proto) ?? .ssh
        mac = try c.decodeIfPresent(String.self, forKey: .mac)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        siteID = (try? c.decodeIfPresent(UUID.self, forKey: .siteID)) ?? nil
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? proto.defaultPort
        auth = (try? c.decodeIfPresent(QuickLoginAuth.self, forKey: .auth)) ?? .automatic
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        credentialID = try c.decodeIfPresent(UUID.self, forKey: .credentialID)
        skipPrompt = try c.decodeIfPresent(Bool.self, forKey: .skipPrompt) ?? false
        lastUsed = (try? c.decodeIfPresent(Date.self, forKey: .lastUsed)) ?? Date(timeIntervalSince1970: 0)
    }

    public var choice: QuickLoginChoice {
        QuickLoginChoice(proto: proto, host: host, user: user, port: port, auth: auth, keyPath: keyPath, credentialID: credentialID)
    }
}

/// Appareil visé par une connexion rapide.
public struct QuickLoginDevice: Equatable, Sendable {
    public var host: String
    public var mac: String?
    public var siteID: UUID?

    public init(host: String, mac: String? = nil, siteID: UUID? = nil) {
        self.host = host
        self.mac = mac?.uppercased()
        self.siteID = siteID
    }
}

/// Préremplissage de la feuille et d'où il vient.
public struct QuickLoginSuggestion: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Dernier nom utilisé pour cet appareil.
        case device
        /// Dernier nom utilisé sur ce site.
        case site
        /// Identifiant SSH des Réglages (dernière adresse testée, sinon le premier).
        case credential(String)
        case none
    }

    public var choice: QuickLoginChoice
    public var source: Source
    public var skipPrompt: Bool
}

/// Mémoire des connexions rapides (ssh-utilisateurs.json), sans aucun secret.
public struct QuickLoginMemory: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "ssh-utilisateurs.json"
    /// Noms récents gardés pour la liste de la feuille.
    public static let recentLimit = 12

    public var version = QuickLoginMemory.currentVersion
    public var entries: [QuickLoginEntry]
    /// Noms déjà utilisés, du plus récent au plus ancien.
    public var recentUsers: [String]

    public init(entries: [QuickLoginEntry] = [], recentUsers: [String] = []) {
        self.entries = entries
        self.recentUsers = recentUsers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        // Entrées lues une à une : une entrée illisible (protocole d'une future version, fichier
        // édité à la main) est écartée seule, les autres restent.
        entries = ((try? c.decodeIfPresent([FailableEntry].self, forKey: .entries)) ?? []).compactMap(\.entry)
        recentUsers = (try? c.decodeIfPresent([String].self, forKey: .recentUsers)) ?? []
    }

    /// Entrée de l'appareil : même MAC d'abord, sinon même adresse dans le même site.
    public func entry(for device: QuickLoginDevice, proto: RemoteProtocol = .ssh) -> QuickLoginEntry? {
        let candidates = entries.filter { $0.proto == proto }
        if let mac = device.mac, let byMac = candidates.first(where: { $0.mac == mac && ($0.siteID == nil || $0.siteID == device.siteID) }) {
            return byMac
        }
        return candidates.first { $0.host == device.host && $0.siteID == device.siteID && (device.mac == nil || $0.mac == nil || $0.mac == device.mac) }
    }

    /// Préremplissage : appareil, puis dernier nom du site, puis identifiant SSH des Réglages
    /// (celui testé sur cette adresse, sinon le premier), sinon vide.
    public func suggestion(for device: QuickLoginDevice, proto: RemoteProtocol = .ssh,
                           credentials: [RemoteCredential] = []) -> QuickLoginSuggestion {
        if let entry = entry(for: device, proto: proto) {
            var choice = entry.choice
            choice.host = device.host
            return QuickLoginSuggestion(choice: choice, source: .device, skipPrompt: entry.skipPrompt)
        }
        // Note 78 : SFTP reprend le compte SSH retenu pour l'appareil (même serveur sshd).
        if proto == .sftp, let ssh = entry(for: device, proto: .ssh), !ssh.user.isEmpty {
            let choice = QuickLoginChoice(proto: .sftp, host: device.host, user: ssh.user, port: ssh.port)
            return QuickLoginSuggestion(choice: choice, source: .device, skipPrompt: false)
        }
        if let siteID = device.siteID,
           let recent = entries.filter({ $0.siteID == siteID && $0.proto == proto && !$0.user.isEmpty }).max(by: { $0.lastUsed < $1.lastUsed }) {
            // Même nom et même méthode que sur le site ; port par défaut (propre à chaque appareil).
            let choice = QuickLoginChoice(proto: proto, host: device.host, user: recent.user, auth: recent.auth,
                                          keyPath: recent.keyPath, credentialID: recent.credentialID)
            return QuickLoginSuggestion(choice: choice, source: .site, skipPrompt: false)
        }
        let ssh = credentials.filter { $0.kind == .ssh && !$0.user.isEmpty }
        if proto == .ssh || proto == .sftp, let credential = ssh.first(where: { $0.lastHost == device.host }) ?? ssh.first {
            var choice = Self.choice(from: credential, host: device.host)
            if proto == .sftp {
                choice = QuickLoginChoice(proto: .sftp, host: device.host, user: credential.user, port: choice.port)
            }
            return QuickLoginSuggestion(choice: choice, source: .credential(credential.name), skipPrompt: false)
        }
        return QuickLoginSuggestion(choice: QuickLoginChoice(proto: proto, host: device.host), source: .none, skipPrompt: false)
    }

    /// Choix repris d'un identifiant SSH des Réglages (nom, port, clé ou mot de passe).
    public static func choice(from credential: RemoteCredential, host: String) -> QuickLoginChoice {
        QuickLoginChoice(proto: .ssh, host: host, user: credential.user, port: Int(credential.port),
                         auth: credential.sshMethod == .key ? (credential.keyPath.isEmpty ? .automatic : .key) : .password,
                         keyPath: credential.sshMethod == .key ? credential.keyPath : "", credentialID: credential.id)
    }

    /// Retient le choix pour cet appareil (remplace l'entrée précédente) et le nom dans la liste.
    public mutating func remember(_ choice: QuickLoginChoice, for device: QuickLoginDevice, skipPrompt: Bool, now: Date = Date()) {
        let previous = entry(for: device, proto: choice.proto)
        entries.removeAll { $0.id == previous?.id }
        entries.append(QuickLoginEntry(id: previous?.id ?? UUID(), proto: choice.proto, mac: device.mac, host: device.host,
                                       siteID: device.siteID, user: choice.user, port: choice.port, auth: choice.auth,
                                       keyPath: choice.keyPath, credentialID: choice.credentialID,
                                       skipPrompt: skipPrompt, lastUsed: now))
        noteUser(choice.user)
    }

    /// Ajoute un nom en tête des noms récents (sans doublon, en tenant compte de la casse).
    public mutating func noteUser(_ user: String) {
        let trimmed = user.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        recentUsers.removeAll { $0 == trimmed }
        recentUsers.insert(trimmed, at: 0)
        if recentUsers.count > Self.recentLimit { recentUsers.removeLast(recentUsers.count - Self.recentLimit) }
    }

    /// Oublie l'appareil (la feuille sera de nouveau montrée, sans préremplissage propre).
    public mutating func forget(_ device: QuickLoginDevice, proto: RemoteProtocol = .ssh) {
        guard let entry = entry(for: device, proto: proto) else { return }
        entries.removeAll { $0.id == entry.id }
    }

    /// Noms de la liste : récents, puis ceux des identifiants SSH, puis les noms courants.
    public func knownUsers(credentials: [RemoteCredential] = []) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for user in recentUsers + credentials.filter({ $0.kind == .ssh }).map(\.user) + QuickLogin.commonUsers
        where !user.isEmpty && !seen.contains(user) {
            seen.insert(user)
            result.append(user)
        }
        return result
    }

    /// Lit le fichier ; s'il existe mais ne se lit pas, il est mis de côté
    /// (« ssh-utilisateurs.json.illisible ») avant que la prochaine écriture ne l'écrase.
    public static func load(from url: URL) -> QuickLoginMemory {
        guard let data = try? Data(contentsOf: url) else { return QuickLoginMemory() }
        if let memory = decode(data) { return memory }
        let aside = url.appendingPathExtension("illisible")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return QuickLoginMemory()
    }

    /// Décodage du contenu du fichier, nil s'il est illisible.
    public static func decode(_ data: Data) -> QuickLoginMemory? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QuickLoginMemory.self, from: data)
    }

    /// Enveloppe d'une entrée : nil si elle ne se lit pas, sans faire échouer la liste.
    private struct FailableEntry: Decodable {
        let entry: QuickLoginEntry?
        init(from decoder: Decoder) throws {
            entry = try? QuickLoginEntry(from: decoder)
        }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
