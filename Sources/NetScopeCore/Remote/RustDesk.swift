import Foundation

// Note 6 : RustDesk (assistance à distance). Le client RustDesk fait tout le travail : NetScope
// garde le carnet des postes, ouvre RustDesk par une adresse rustdesk:// et vérifie les réglages
// du serveur auto-hébergé (hbbs + hbbr). Rien ici n'envoie quoi que ce soit sur le réseau.

// MARK: - Identifiant RustDesk

/// ID RustDesk : 9 ou 10 chiffres (« 123 456 789 » à l'affichage).
public enum RustDeskID {
    public static let lengths = 9...10

    /// Séparateurs tolérés dans un ID collé (espaces, espaces insécables, tirets).
    private static let separators: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "-", "\t"]

    /// « 123 456 789 », « 123-456-789 », « 1234567890 » → chiffres seuls ; nil sinon.
    public static func parse(_ text: String) -> String? {
        let compact = String(text.trimmingCharacters(in: .whitespacesAndNewlines).filter { !separators.contains($0) })
        guard lengths.contains(compact.count), compact.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return compact
    }

    /// Le texte ressemble à un ID (seulement des chiffres et des séparateurs), même de mauvaise longueur.
    public static func looksLikeID(_ text: String) -> Bool {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines).filter { !separators.contains($0) }
        return !compact.isEmpty && compact.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Groupes de trois chiffres depuis la droite, comme le client RustDesk : « 123 456 789 »,
    /// « 1 234 567 890 ». Séparateur insécable par défaut (l'ID ne se coupe pas en fin de ligne).
    public static func grouped(_ id: String, separator: String = "\u{00A0}") -> String {
        guard id.count > 3, id.allSatisfy({ $0.isNumber }) else { return id }
        var groups: [String] = []
        var rest = Substring(id)
        while rest.count > 3 {
            groups.insert(String(rest.suffix(3)), at: 0)
            rest = rest.dropLast(3)
        }
        groups.insert(String(rest), at: 0)
        return groups.joined(separator: separator)
    }
}

/// Destination d'une connexion RustDesk : un ID (par le serveur d'ID) ou une adresse IP ou un
/// nom (accès IP direct, port 21118 du poste, sur le réseau local ou par VPN).
public enum RustDeskTarget: Equatable, Sendable {
    case id(String)
    case direct(host: String, port: Int)

    /// Port de l'accès IP direct de RustDesk.
    public static let directPort = 21118

    /// ID (espaces acceptés) ou hôte ; une IPv6 n'est pas acceptée (RustDesk la lit mal dans une adresse rustdesk://).
    public static func parse(_ text: String, port: Int = directPort) throws -> RustDeskTarget {
        if let id = RustDeskID.parse(text) { return .id(id) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if RustDeskID.looksLikeID(trimmed) { throw RemoteValidationError.invalidRustDeskID(trimmed) }
        let host = try RemoteValidator.validateHost(trimmed)
        guard !host.contains(":") else { throw RemoteValidationError.rustDeskIPv6(host) }
        try RemoteValidator.validatePort(port)
        return .direct(host: host, port: port)
    }

    /// Valeur enregistrée dans le champ hôte de la connexion (ID compact ou hôte).
    public var hostValue: String {
        switch self {
        case .id(let id): return id
        case .direct(let host, _): return host
        }
    }

    /// Ce que RustDesk reçoit dans son champ « ID distant » : « 123456789 » ou « 10.0.0.5[:port] ».
    public var remoteID: String {
        switch self {
        case .id(let id): return id
        case .direct(let host, let port): return port == Self.directPort ? host : "\(host):\(port)"
        }
    }

    /// Affichage : « 123 456 789 » ou « 10.0.0.5 (IP directe) ».
    public var label: String {
        switch self {
        case .id(let id): return RustDeskID.grouped(id)
        case .direct: return remoteID + " (IP directe)"
        }
    }

    public var isDirect: Bool {
        if case .direct = self { return true }
        return false
    }
}

// MARK: - Adresse rustdesk://

/// Adresses rustdesk:// comprises par le client de bureau (1.2 à 1.5, vérifié sur le client
/// macOS 1.5.1) : `rustdesk://connection/new/<id>` ouvre une connexion ; `?password=` passe le
/// mot de passe permanent, `?relay` force le relais. L'adresse est remise à RustDesk par macOS
/// (événement Apple), jamais dans les arguments d'un processus visibles par `ps`.
public enum RustDeskLink {
    public static let scheme = "rustdesk"

    /// Caractères laissés tels quels dans la valeur du mot de passe (le reste est encodé en %XX).
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// `rustdesk://connection/new/123456789?password=…`
    public static func connectURL(_ target: RustDeskTarget, password: String? = nil, forceRelay: Bool = false) -> URL? {
        var text = "\(scheme)://connection/new/\(target.remoteID)"
        var query: [String] = []
        if let password, !password.isEmpty,
           let encoded = password.addingPercentEncoding(withAllowedCharacters: unreserved) {
            query.append("password=" + encoded)
        }
        if forceRelay { query.append("relay") }
        if !query.isEmpty { text += "?" + query.joined(separator: "&") }
        return URL(string: text)
    }

    /// Adresse affichée (jamais de mot de passe) : « rustdesk://connection/new/123456789 ».
    public static func displayURL(_ target: RustDeskTarget, hasPassword: Bool = false) -> String {
        "\(scheme)://connection/new/\(target.remoteID)" + (hasPassword ? "?password=•••" : "")
    }

    /// Identifiant de l'app RustDesk sur macOS et emplacement habituel.
    public static let bundleIdentifier = "com.carriez.rustdesk"
    public static let applicationPath = "/Applications/RustDesk.app"
    /// Page des versions officielles (client à installer sur le Mac du technicien).
    public static let downloadURL = URL(string: "https://github.com/rustdesk/rustdesk/releases/latest")!
}

// MARK: - Réglages du serveur

/// Serveur RustDesk auto-hébergé (hbbs : serveur d'ID ; hbbr : relais) et page d'assistance.
/// Rien de secret : la clé publique est faite pour être distribuée aux clients.
public struct RustDeskServerSettings: Codable, Equatable, Sendable {
    /// Serveur d'ID (hbbs) : « assistance.exemple.ca » ou « hôte:21116 ».
    public var idServer: String
    /// Relais (hbbr) ; vide : même hôte que le serveur d'ID, port 21117.
    public var relayServer: String
    /// Clé publique du serveur (id_ed25519.pub, 44 caractères base64).
    public var publicKey: String
    /// Serveur d'API (RustDesk Pro) ; vide avec le serveur OSS. Repris du nom du client portable.
    public var apiServer: String
    /// Page d'assistance où l'usager télécharge le client portable (https).
    public var supportPageURL: String
    /// Adresse interne du serveur (derrière la FortiGate), pour vérifier les VIP ; facultative.
    public var internalAddress: String

    public init(idServer: String = "", relayServer: String = "", publicKey: String = "", apiServer: String = "",
                supportPageURL: String = "", internalAddress: String = "") {
        self.idServer = idServer
        self.relayServer = relayServer
        self.publicKey = publicKey
        self.apiServer = apiServer
        self.supportPageURL = supportPageURL
        self.internalAddress = internalAddress
    }

    private enum CodingKeys: String, CodingKey {
        case idServer, relayServer, publicKey, apiServer, supportPageURL, internalAddress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
        self.init(idServer: text(.idServer), relayServer: text(.relayServer), publicKey: text(.publicKey),
                  apiServer: text(.apiServer), supportPageURL: text(.supportPageURL), internalAddress: text(.internalAddress))
    }

    public static let defaultIDPort = 21116
    public static let defaultRelayPort = 21117

    /// Serveur d'ID et clé publique remplis.
    public var isConfigured: Bool {
        !idServer.trimmingCharacters(in: .whitespaces).isEmpty && !publicKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Serveur d'ID : hôte et port (21116 par défaut).
    public var idEndpoint: RustDeskEndpoint? { RustDeskEndpoint.parse(idServer, defaultPort: Self.defaultIDPort) }

    /// Port du test NAT (TCP), juste avant celui du serveur d'ID (21115).
    public var natTestEndpoint: RustDeskEndpoint? {
        guard let id = idEndpoint, id.port > 1 else { return nil }
        return RustDeskEndpoint(host: id.host, port: id.port - 1)
    }

    /// Relais : celui saisi, sinon l'hôte du serveur d'ID sur le port suivant (21117).
    public var relayEndpoint: RustDeskEndpoint? {
        let relay = relayServer.trimmingCharacters(in: .whitespaces)
        if !relay.isEmpty { return RustDeskEndpoint.parse(relay, defaultPort: Self.defaultRelayPort) }
        guard let id = idEndpoint, id.port < 65_535 else { return nil }
        return RustDeskEndpoint(host: id.host, port: id.port + 1)
    }

    /// Problèmes des champs, à afficher sous le formulaire (vide : tout est valide).
    public func issues() -> [String] {
        var result: [String] = []
        let id = idServer.trimmingCharacters(in: .whitespaces)
        if !id.isEmpty, idEndpoint == nil { result.append("Serveur d’ID invalide\u{00A0}: «\u{00A0}\(id)\u{00A0}» (nom ou IPv4, port facultatif).") }
        let relay = relayServer.trimmingCharacters(in: .whitespaces)
        if !relay.isEmpty, RustDeskEndpoint.parse(relay, defaultPort: Self.defaultRelayPort) == nil {
            result.append("Serveur relais invalide\u{00A0}: «\u{00A0}\(relay)\u{00A0}».")
        }
        let key = publicKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, let problem = RustDeskKey.problem(key) { result.append(problem) }
        let page = supportPageURL.trimmingCharacters(in: .whitespaces)
        if !page.isEmpty, Self.validSupportURL(page) == nil {
            result.append("Lien de la page d’assistance invalide\u{00A0}: une adresse https://… est attendue.")
        }
        let interne = internalAddress.trimmingCharacters(in: .whitespaces)
        if !interne.isEmpty, IPv4Address(interne) == nil {
            result.append("Adresse interne du serveur invalide\u{00A0}: une IPv4 est attendue (ex. 192.168.10.20).")
        }
        return result
    }

    /// Adresse https valide, sinon nil.
    public static func validSupportURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, !trimmed.contains(" ") else { return nil }
        return url
    }

    /// Nom du client portable Windows préconfiguré : « rustdesk-host=<serveur>,key=<clé>,.exe »
    /// (relais et API ajoutés s'ils sont saisis ; la virgule finale protège le nom quand Windows
    /// ajoute « (1) » à un fichier téléchargé deux fois). nil sans serveur ni clé.
    public var portableClientFileName: String? {
        guard isConfigured else { return nil }
        var parts = ["host=" + idServer.trimmingCharacters(in: .whitespaces)]
        parts.append("key=" + publicKey.trimmingCharacters(in: .whitespaces))
        let relay = relayServer.trimmingCharacters(in: .whitespaces)
        if !relay.isEmpty { parts.append("relay=" + relay) }
        let api = apiServer.trimmingCharacters(in: .whitespaces)
        if !api.isEmpty { parts.append("api=" + api) }
        return "rustdesk-" + parts.joined(separator: ",") + ",.exe"
    }

    /// Caractère interdit dans un nom de fichier Windows (« / » d'une clé base64, « : » d'un port).
    public var portableNameProblem: String? {
        guard let name = portableClientFileName else { return nil }
        let forbidden = Set("\\/:*?\"<>|")
        guard let bad = name.first(where: { forbidden.contains($0) }) else { return nil }
        let where_ = publicKey.contains(bad) ? "La clé publique" : "L’adresse d’un serveur"
        return "\(where_) contient «\u{00A0}\(bad)\u{00A0}», interdit dans un nom de fichier Windows\u{00A0}: le client portable ne peut pas être préconfiguré par son nom."
            + (publicKey.contains(bad) ? " Régénérez la paire de clés de hbbs, ou configurez le client à la main." : " Gardez les ports par défaut (21116, 21117) et retirez-les des adresses.")
    }

    /// Champs remplis à partir d'un nom de client portable (les autres réglages sont gardés).
    public func merging(_ portable: RustDeskPortableConfig) -> RustDeskServerSettings {
        var copy = self
        copy.idServer = portable.host
        copy.publicKey = portable.key
        copy.relayServer = portable.relay
        copy.apiServer = portable.api
        return copy
    }
}

/// Hôte et port d'un service RustDesk.
public struct RustDeskEndpoint: Equatable, Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// « hôte », « hôte:port » ; nom, IPv4 (pas d'IPv6). Un « http(s):// » collé est retiré.
    public static func parse(_ text: String, defaultPort: Int) -> RustDeskEndpoint? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where value.lowercased().hasPrefix(scheme) { value = String(value.dropFirst(scheme.count)) }
        if value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        var port = defaultPort
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        if pieces.count == 2 {
            guard let number = Int(pieces[1]), (1...65_535).contains(number) else { return nil }
            port = number
        }
        let host = String(pieces[0])
        guard (try? RemoteValidator.validateHost(host)) != nil, !host.contains("_") else { return nil }
        return RustDeskEndpoint(host: host.lowercased(), port: port)
    }

    public var label: String { "\(host):\(port)" }
}

/// Clé publique de hbbs : 32 octets en base64 standard (44 caractères, « = » final).
public enum RustDeskKey {
    public static func problem(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: trimmed), data.count == 32, trimmed.count == 44 else {
            return "Clé publique invalide\u{00A0}: 44 caractères base64 attendus (contenu de id_ed25519.pub du serveur)."
        }
        return nil
    }

    /// « OeVu…qmBw= » : début et fin, pour comparer à l'œil sans tout afficher.
    public static func short(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 12 else { return trimmed }
        return String(trimmed.prefix(6)) + "…" + String(trimmed.suffix(6))
    }
}

// MARK: - Nom du client portable

/// Réglages lus dans le nom d'un client portable RustDesk (« rustdesk-host=…,key=…,.exe »).
public struct RustDeskPortableConfig: Equatable, Sendable {
    public var host: String
    public var key: String
    public var relay: String
    public var api: String

    public init(host: String, key: String = "", relay: String = "", api: String = "") {
        self.host = host
        self.key = key
        self.relay = relay
        self.api = api
    }

    /// Même lecture que le client RustDesk (custom_server.rs) : tout ce qui suit « host= »,
    /// découpé aux virgules, dans n'importe quel ordre (host=, key=, relay=, api=). Accepte un
    /// chemin complet, « .exe » en double et le « (1) » ajouté par Windows. nil sans « host= ».
    public static func parse(_ text: String) -> RustDeskPortableConfig? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) { name = String(name[name.index(after: slash)...]) }
        while name.lowercased().hasSuffix(".exe") { name = String(name.dropLast(4)) }
        // « …,key=abc= (1) » : copie renommée par Windows.
        if let range = name.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) { name.removeSubrange(range) }
        guard let start = name.lowercased().range(of: "host=") else { return nil }
        // Même index dans le nom d'origine (les minuscules ASCII ne changent pas la longueur).
        let offset = name.lowercased().distance(from: name.lowercased().startIndex, to: start.lowerBound)
        let tail = name[name.index(name.startIndex, offsetBy: offset)...]
        var result = RustDeskPortableConfig(host: "")
        for piece in tail.split(separator: ",", omittingEmptySubsequences: true) {
            let element = piece.trimmingCharacters(in: .whitespaces)
            let lower = element.lowercased()
            if lower.hasPrefix("host=") { result.host = String(element.dropFirst(5)) }
            if lower.hasPrefix("key=") { result.key = String(element.dropFirst(4)) }
            if lower.hasPrefix("relay=") { result.relay = String(element.dropFirst(6)) }
            if lower.hasPrefix("api=") { result.api = String(element.dropFirst(4)) }
        }
        guard !result.host.isEmpty else { return nil }
        return result
    }
}

// MARK: - Client de bureau de ce Mac

/// Réglages réseau du client RustDesk de bureau, lus dans
/// ~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml (section [options]).
public struct RustDeskClientConfig: Equatable, Sendable {
    public var rendezvousServer: String
    public var relayServer: String
    public var key: String
    public var apiServer: String

    public init(rendezvousServer: String = "", relayServer: String = "", key: String = "", apiServer: String = "") {
        self.rendezvousServer = rendezvousServer
        self.relayServer = relayServer
        self.key = key
        self.apiServer = apiServer
    }

    /// Fichier de configuration du client de bureau (chemin vérifié avec RustDesk 1.5.1 pour macOS).
    public static func defaultURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences/com.carriez.RustDesk/RustDesk2.toml")
    }

    /// Lecture minimale du TOML de RustDesk : lignes « clé = 'valeur' » de la section [options].
    public static func parse(_ toml: String) -> RustDeskClientConfig {
        var section = ""
        var values: [String: String] = [:]
        for raw in toml.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard section == "options", let equal = line.firstIndex(of: "=") else { continue }
            let name = line[..<equal].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[name] = unquote(line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces))
        }
        return RustDeskClientConfig(rendezvousServer: values["custom-rendezvous-server"] ?? "",
                                    relayServer: values["relay-server"] ?? "",
                                    key: values["key"] ?? "",
                                    apiServer: values["api-server"] ?? "")
    }

    /// 'texte' (littéral) ou "texte" (avec \" et \\).
    private static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), let end = value.dropFirst().firstIndex(of: "'") {
            return String(value[value.index(after: value.startIndex)..<end])
        }
        if value.count >= 2, value.hasPrefix("\"") {
            var result = ""
            var escaped = false
            for character in value.dropFirst() {
                if escaped {
                    result.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return result
                } else {
                    result.append(character)
                }
            }
            return result
        }
        return value.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? value
    }
}

/// Constat de la vérification du client de ce Mac ou du serveur.
public struct RustDeskFinding: Equatable, Identifiable, Sendable {
    public enum Level: String, Sendable { case ok, warning, error, info }

    public var id: String { title }
    public var level: Level
    public var title: String
    public var detail: String

    public init(_ level: Level, _ title: String, _ detail: String = "") {
        self.level = level
        self.title = title
        self.detail = detail
    }
}

/// Comparaison du client de bureau de ce Mac avec les réglages de NetScope.
public enum RustDeskClientCheck {
    public static let settingsPath = "RustDesk › Réglages › Réseau › Serveur ID/Relais"

    /// `client` nil : fichier absent (RustDesk jamais lancé, ou pas installé).
    public static func compare(_ settings: RustDeskServerSettings, client: RustDeskClientConfig?) -> [RustDeskFinding] {
        guard settings.isConfigured, let ours = settings.idEndpoint else {
            return [RustDeskFinding(.info, "Réglages du serveur incomplets", "Remplissez le serveur d’ID et la clé publique (ou importez le nom du client portable) avant la vérification.")]
        }
        guard let client else {
            return [RustDeskFinding(.warning, "Configuration du client introuvable",
                                    "Aucun fichier RustDesk2.toml\u{00A0}: lancez RustDesk une fois sur ce Mac, puis réglez \(settingsPath)\u{00A0}: serveur d’ID «\u{00A0}\(settings.idServer)\u{00A0}» et la clé publique.")]
        }
        var findings: [RustDeskFinding] = []
        let theirs = RustDeskEndpoint.parse(client.rendezvousServer, defaultPort: RustDeskServerSettings.defaultIDPort)
        if client.rendezvousServer.trimmingCharacters(in: .whitespaces).isEmpty {
            findings.append(RustDeskFinding(.error, "Le client utilise les serveurs publics de RustDesk",
                                            "Dans \(settingsPath), serveur d’ID\u{00A0}: «\u{00A0}\(settings.idServer)\u{00A0}». Sans cela, les postes de vos usagers sont introuvables."))
        } else if theirs != ours {
            findings.append(RustDeskFinding(.error, "Autre serveur d’ID\u{00A0}: «\u{00A0}\(client.rendezvousServer)\u{00A0}»",
                                            "Dans \(settingsPath), remplacez-le par «\u{00A0}\(settings.idServer)\u{00A0}»."))
        } else {
            findings.append(RustDeskFinding(.ok, "Même serveur d’ID (\(ours.label))"))
        }
        let key = settings.publicKey.trimmingCharacters(in: .whitespaces)
        let clientKey = client.key.trimmingCharacters(in: .whitespaces)
        if clientKey.isEmpty {
            findings.append(RustDeskFinding(.error, "Aucune clé dans le client",
                                            "Le serveur exige la clé (hbbs -k _)\u{00A0}: collez «\u{00A0}\(RustDeskKey.short(key))\u{00A0}» en entier dans le champ «\u{00A0}Key\u{00A0}» de \(settingsPath)."))
        } else if clientKey != key {
            findings.append(RustDeskFinding(.error, "Clé différente (\(RustDeskKey.short(clientKey)))",
                                            "La clé attendue est «\u{00A0}\(RustDeskKey.short(key))\u{00A0}»\u{00A0}: recopiez-la depuis Réglages › RustDesk de NetScope dans \(settingsPath)."))
        } else {
            findings.append(RustDeskFinding(.ok, "Même clé publique (\(RustDeskKey.short(key)))"))
        }
        let relay = client.relayServer.trimmingCharacters(in: .whitespaces)
        if !relay.isEmpty {
            let clientRelay = RustDeskEndpoint.parse(relay, defaultPort: RustDeskServerSettings.defaultRelayPort)
            if clientRelay != settings.relayEndpoint {
                findings.append(RustDeskFinding(.warning, "Autre relais\u{00A0}: «\u{00A0}\(relay)\u{00A0}»",
                                                "Attendu\u{00A0}: «\u{00A0}\(settings.relayEndpoint?.label ?? settings.idServer)\u{00A0}», ou le champ vide (même hôte que le serveur d’ID)."))
            } else {
                findings.append(RustDeskFinding(.ok, "Même relais (\(clientRelay?.label ?? relay))"))
            }
        } else {
            findings.append(RustDeskFinding(.ok, "Relais déduit du serveur d’ID (\(settings.relayEndpoint?.label ?? "—"))"))
        }
        return findings
    }
}

extension RemoteConnection {
    /// Note 6 : poste RustDesk désigné par son ID (joint par le serveur d'ID, jamais sondé en TCP).
    public var isRustDeskByID: Bool {
        guard case .id? = rustDeskTarget else { return false }
        return true
    }

    /// Note 6 : nouvelle connexion RustDesk à partir d'un ID collé (« 123 456 789 ») ou d'une IP.
    public static func rustDesk(_ text: String, name: String = "", folder: String = "", endUser: String = "") throws -> RemoteConnection {
        let target = try RustDeskTarget.parse(text)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = target.isDirect ? target.hostValue : "Poste " + RustDeskID.grouped(target.hostValue)
        var port = RustDeskTarget.directPort
        if case .direct(_, let p) = target { port = p }
        return try RemoteConnection(name: trimmed.isEmpty ? fallback : trimmed, proto: .rustdesk, host: target.hostValue,
                                    port: port, folder: folder, endUser: endUser).validated()
    }
}
