import Darwin
import Foundation

// Note 66 : tunnels SSH du carnet d'Accès distant. Redirection locale (-L), proxy SOCKS (-D) et
// saut par bastion (-J, ProxyJump), lancés par /usr/bin/ssh de macOS. Les arguments sont construits
// en tableau (jamais de chaîne passée à un shell) et chaque valeur est validée par une liste fermée
// de caractères : aucune option ne peut être glissée dans un champ (« -oProxyCommand=… » refusé).
// Le port local écoute sur 127.0.0.1 seulement ; il est choisi libre automatiquement.

/// Genre de tunnel.
public enum SSHTunnelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// -L 127.0.0.1:port:hôte:port : un service distant joint par 127.0.0.1.
    case local
    /// -D 127.0.0.1:port : proxy SOCKS5 (navigateur, tout le réseau du serveur SSH).
    case dynamic

    public var id: String { rawValue }

    /// Étiquette des listes (croquis Remote.dc.html).
    public var badge: String { self == .local ? "LOCAL" : "DYNAMIQUE" }

    public var label: String { self == .local ? "Redirection locale (-L)" : "Proxy SOCKS5 (-D)" }

    public var flag: String { self == .local ? "-L" : "-D" }
}

/// Ce qui s'ouvre à travers le tunnel (127.0.0.1:port local).
public enum SSHTunnelUse: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, rdp, vnc, http, https

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "Rien (port seulement)"
        case .rdp: return "Bureau à distance (RDP)"
        case .vnc: return "VNC (session intégrée)"
        case .http: return "Navigateur web (http)"
        case .https: return "Navigateur web (https)"
        }
    }

    /// Libellé du bouton (« Ouvrir RDP »).
    public var actionLabel: String {
        switch self {
        case .none: return "Copier l’adresse"
        case .rdp: return "Ouvrir RDP"
        case .vnc: return "Ouvrir VNC"
        case .http, .https: return "Ouvrir dans le navigateur"
        }
    }

    /// Usage proposé d'après le port distant (3389 : RDP, 5900 : VNC, 443 : https…).
    public static func suggested(forRemotePort port: Int) -> SSHTunnelUse {
        switch port {
        case 3389: return .rdp
        case 5900...5909: return .vnc
        case 80, 8000, 8080, 8008, 8888: return .http
        case 443, 4443, 5001, 8443, 9443, 10443: return .https
        default: return .none
        }
    }
}

/// Erreurs d'un tunnel, expliquées en français.
public enum SSHTunnelError: Error, Equatable, LocalizedError, Sendable {
    case invalidLocalPort(Int)
    case invalidTarget(String)
    case invalidJump(String)
    case tooManyJumps(Int)
    case invalidIdentityFile(String)
    case noFreePort
    case notSSH

    public var errorDescription: String? {
        switch self {
        case .invalidLocalPort(let port):
            return "Port local invalide\u{00A0}: \(port) (1024 à 65535, ou 0 pour un port libre choisi automatiquement)."
        case .invalidTarget(let target):
            return "Destination du tunnel invalide\u{00A0}: «\u{00A0}\(target)\u{00A0}» (hôte ou adresse IP, puis port)."
        case .invalidJump(let jump):
            return "Hôte de rebond invalide\u{00A0}: «\u{00A0}\(jump)\u{00A0}» (forme utilisateur@hôte:port, séparés par des virgules)."
        case .tooManyJumps(let count):
            return "Trop d’hôtes de rebond (\(count))\u{00A0}: \(SSHJumpChain.maxHops) au plus."
        case .invalidIdentityFile(let path):
            return "Clé privée invalide\u{00A0}: «\u{00A0}\(path)\u{00A0}»."
        case .noFreePort: return "Aucun port local libre trouvé sur 127.0.0.1."
        case .notSSH: return "Un tunnel passe par une connexion SSH."
        }
    }
}

/// Redirection enregistrée avec une connexion SSH du carnet.
public struct SSHTunnelSpec: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SSHTunnelKind
    /// Port local voulu ; 0 : choisi libre automatiquement (suggestion d'après le port distant).
    public var localPort: Int
    /// Destination vue du serveur SSH (-L) ; vide pour un proxy SOCKS.
    public var remoteHost: String
    public var remotePort: Int
    /// Ce que « Ouvrir » lance à travers le tunnel.
    public var use: SSHTunnelUse
    /// Nom libre (« DSM du NAS », « FortiSwitch par FortiLink »).
    public var label: String

    public init(id: UUID = UUID(), kind: SSHTunnelKind = .local, localPort: Int = 0, remoteHost: String = "",
                remotePort: Int = 0, use: SSHTunnelUse? = nil, label: String = "") {
        self.id = id
        self.kind = kind
        self.localPort = localPort
        self.remoteHost = kind == .dynamic ? "" : remoteHost
        self.remotePort = kind == .dynamic ? 0 : remotePort
        self.use = use ?? (kind == .dynamic ? .none : SSHTunnelUse.suggested(forRemotePort: remotePort))
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, localPort, remoteHost, remotePort, use, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decodeIfPresent(SSHTunnelKind.self, forKey: .kind)) ?? .local
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? 0
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? ""
        remotePort = try c.decodeIfPresent(Int.self, forKey: .remotePort) ?? 0
        use = (try? c.decodeIfPresent(SSHTunnelUse.self, forKey: .use)) ?? .none
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    /// Port local proposé quand aucun n'est imposé : 1080 pour SOCKS ; le port distant s'il ne
    /// demande pas de droits (≥ 1024), sinon 10000 + port (3389 → 13389, 443 → 10443, 22 → 10022).
    public static func suggestedLocalPort(kind: SSHTunnelKind, remotePort: Int) -> Int {
        if kind == .dynamic { return 1080 }
        if remotePort >= 1024, remotePort <= 65_535 { return remotePort }
        return 10_000 + max(1, remotePort)
    }

    /// Port local essayé en premier.
    public var preferredLocalPort: Int {
        localPort > 0 ? localPort : Self.suggestedLocalPort(kind: kind, remotePort: remotePort)
    }

    /// « 8443 → 10.182.122.111:443 », « auto → 10.10.0.12:3389 », « 1080 (proxy SOCKS5) ».
    /// `activePort` : port réellement ouvert par la session.
    public func spec(activePort: Int? = nil) -> String {
        let port = activePort.map(String.init) ?? (localPort > 0 ? String(localPort) : "auto")
        switch kind {
        case .local:
            let host = remoteHost.contains(":") ? "[\(remoteHost)]" : remoteHost
            return "\(port) → \(host):\(remotePort)"
        case .dynamic:
            return "\(port) (proxy SOCKS5)"
        }
    }

    /// Nom affiché : le nom libre, sinon la redirection.
    public var title: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? spec() : trimmed
    }

    /// Vérifie la redirection : port local (0, ou 1024 à 65535), hôte et port distants.
    public func validated() throws -> SSHTunnelSpec {
        var copy = self
        guard localPort == 0 || (1_024...65_535).contains(localPort) else { throw SSHTunnelError.invalidLocalPort(localPort) }
        copy.label = RemoteShell.sanitizedTitle(label, limit: 60)
        switch kind {
        case .local:
            let host = remoteHost.trimmingCharacters(in: .whitespaces)
            guard let valid = try? RemoteValidator.validateHost(host), (1...65_535).contains(remotePort) else {
                throw SSHTunnelError.invalidTarget("\(host):\(remotePort)")
            }
            copy.remoteHost = valid
        case .dynamic:
            copy.remoteHost = ""
            copy.remotePort = 0
            if copy.use != .none { copy.use = .none }
        }
        return copy
    }
}

/// Un hôte de rebond (ProxyJump).
public struct SSHJumpHost: Equatable, Sendable {
    public var user: String
    public var host: String
    public var port: Int?

    public init(user: String = "", host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }

    /// « admin@10.182.122.1 », « admin@[fe80::1]:2222 », « bastion:2222 ».
    public var formatted: String {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        var text = user.isEmpty ? bracketed : "\(user)@\(bracketed)"
        if let port, port != 22 { text += ":\(port)" }
        return text
    }
}

/// Chaîne d'hôtes de rebond (valeur de -J, comme ProxyJump de ~/.ssh/config).
public enum SSHJumpChain {
    public static let maxHops = 5

    /// Lit « admin@10.0.0.1:2222,bastion » ; vide ou « none » : aucun saut. Chaque hôte est validé
    /// (aucun espace, guillemet, tiret initial ni option « -o… »).
    public static func parse(_ text: String) throws -> [SSHJumpHost] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "none" { return [] }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count <= maxHops else { throw SSHTunnelError.tooManyJumps(parts.count) }
        return try parts.map { part in
            guard !part.isEmpty, !part.hasPrefix("-"), !part.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else {
                throw SSHTunnelError.invalidJump(part)
            }
            guard let address = try? QuickLoginAddress.parse(part) else { throw SSHTunnelError.invalidJump(part) }
            return SSHJumpHost(user: address.user, host: address.host, port: address.port)
        }
    }

    /// Valeur normalisée de -J (« admin@10.0.0.1:2222,bastion »), ou "" sans saut.
    public static func normalized(_ text: String) throws -> String {
        try parse(text).map(\.formatted).joined(separator: ",")
    }
}

/// Serveur SSH visé (connexion du carnet) : utilisateur, hôte, port, rebond et clé.
public struct SSHTarget: Equatable, Sendable {
    public var user: String
    public var host: String
    public var port: Int
    /// ProxyJump (valeur de -J), vide sans saut.
    public var jump: String
    /// Clé privée (« -i »), vide : clés par défaut et agent.
    public var identityFile: String

    public init(user: String = "", host: String, port: Int = 22, jump: String = "", identityFile: String = "") {
        self.user = user
        self.host = host
        self.port = port
        self.jump = jump
        self.identityFile = identityFile
    }

    public init(connection: RemoteConnection) {
        self.init(user: connection.username, host: connection.host, port: connection.port,
                  jump: connection.proxyJump, identityFile: connection.identityFile)
    }

    /// Valeurs validées (mêmes règles que le carnet) ; le rebond est normalisé.
    public func validated() throws -> SSHTarget {
        var copy = self
        copy.host = try RemoteValidator.validateHost(host)
        try RemoteValidator.validatePort(port)
        copy.user = try RemoteValidator.validateUser(user)
        copy.jump = try SSHJumpChain.normalized(jump)
        let key = identityFile.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            guard let valid = try? QuickLogin.validateKeyPath(key) else { throw SSHTunnelError.invalidIdentityFile(key) }
            copy.identityFile = valid
        } else {
            copy.identityFile = ""
        }
        return copy
    }

    /// Options de rebond, de clé et de port, puis « -- » et la destination (jamais lue comme une
    /// option). « admin@corp » passe par « -l ». `home` remplace « ~ » de la clé.
    public func trailingArguments(home: String = NSHomeDirectory()) -> [String] {
        var args: [String] = []
        if !jump.isEmpty { args += ["-J", jump] }
        if !identityFile.isEmpty {
            let path = identityFile.hasPrefix("~/") ? home + identityFile.dropFirst(1) : identityFile
            args += ["-i", path]
        }
        if port != 22 { args += ["-p", String(port)] }
        if user.contains("@") {
            args += ["-l", user, "--", host]
        } else {
            args += ["--", user.isEmpty ? host : user + "@" + host]
        }
        return args
    }
}

/// Arguments de /usr/bin/ssh pour un tunnel.
public enum SSHTunnelCommand {
    /// Options fixes : pas de commande distante (-N), pas de terminal (-T), échec si le port ne
    /// s'ouvre pas, pas de multiplexage (une session = un processus), ni commande locale.
    public static let baseOptions: [String] = [
        "-N", "-T",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=ask",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        "-o", "PermitLocalCommand=no",
        "-o", "GatewayPorts=no",
    ]

    /// Arguments complets ; lève une erreur si une valeur est invalide.
    public static func arguments(target: SSHTarget, tunnel: SSHTunnelSpec, localPort: Int,
                                 home: String = NSHomeDirectory()) throws -> [String] {
        let server = try target.validated()
        let spec = try tunnel.validated()
        guard (1_024...65_535).contains(localPort) else { throw SSHTunnelError.invalidLocalPort(localPort) }
        var args = baseOptions
        switch spec.kind {
        case .local:
            let host = spec.remoteHost.contains(":") ? "[\(spec.remoteHost)]" : spec.remoteHost
            args += ["-L", "127.0.0.1:\(localPort):\(host):\(spec.remotePort)"]
        case .dynamic:
            args += ["-D", "127.0.0.1:\(localPort)"]
        }
        return args + server.trailingArguments(home: home)
    }

    /// Commande affichée (sans les options fixes « -o ») : « ssh -N -L 127.0.0.1:13389:10.10.0.12:3389
    /// -J admin@10.182.122.1 -- netadmin@10.182.122.2 ». Jamais de secret.
    public static func displayCommand(_ arguments: [String]) -> String {
        var words = ["ssh"]
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-o" {
                index += 2
                continue
            }
            if arguments[index] != "-T" { words.append(arguments[index]) }
            index += 1
        }
        return RemoteShell.command(words)
    }

    /// Adresse locale ouverte par le tunnel : « 127.0.0.1:13389 ».
    public static func localAddress(port: Int) -> String { "127.0.0.1:\(port)" }

    /// URL ouverte dans le navigateur à travers le tunnel.
    public static func webURL(use: SSHTunnelUse, port: Int) -> URL? {
        switch use {
        case .http: return URL(string: "http://127.0.0.1:\(port)/")
        case .https: return URL(string: "https://127.0.0.1:\(port)/")
        default: return nil
        }
    }

    /// Connexion RDP ou VNC passée par le tunnel : même nom, utilisateur et affichage que
    /// `base` (connexion du carnet de même destination, s'il y en a une), hôte 127.0.0.1.
    public static func throughTunnel(_ use: SSHTunnelUse, port: Int, name: String,
                                     base: RemoteConnection? = nil) -> RemoteConnection? {
        let proto: RemoteProtocol
        switch use {
        case .rdp: proto = .rdp
        case .vnc: proto = .vnc
        default: return nil
        }
        var connection = RemoteConnection(name: name, proto: proto, host: "127.0.0.1", port: port)
        if let base, base.proto == proto {
            connection.username = base.username
            connection.display = base.display
            connection.note = base.note
        }
        return connection
    }
}

/// Choix d'un port local libre (127.0.0.1).
public enum LocalPortPicker {
    /// Plage de repli, sous les ports éphémères de macOS (49152 et plus).
    public static let fallbackRange = 20_000...48_999

    /// Premier port libre : le port voulu, puis les suivants (jusqu'à `attempts`), puis la plage de
    /// repli ; les ports `reserved` (déjà pris par un autre tunnel de NetScope) sont sautés.
    public static func choose(preferred: Int, reserved: Set<Int> = [], attempts: Int = 50,
                              isFree: (Int) -> Bool = LocalPortPicker.isFree) -> Int? {
        var tried = Set<Int>()
        func ok(_ port: Int) -> Bool {
            guard (1_024...65_535).contains(port), !reserved.contains(port), !tried.contains(port) else { return false }
            tried.insert(port)
            return isFree(port)
        }
        if preferred >= 1_024 {
            for port in preferred..<min(preferred + attempts, 65_536) where ok(port) { return port }
        }
        for port in fallbackRange where ok(port) { return port }
        return nil
    }

    /// Port libre sur 127.0.0.1 (TCP) : un bind sans SO_REUSEADDR réussit. Rien n'est envoyé.
    public static func isFree(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    /// Le tunnel écoute : son port local n'est plus libre (vérifié sans s'y connecter, donc sans
    /// ouvrir de canal vers la destination).
    public static func isListening(_ port: Int) -> Bool {
        !isFree(port)
    }
}
