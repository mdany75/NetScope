import Darwin
import Foundation

// Accès au DNS (et au fichier de politique MTA-STS) des outils courriel. Les analyseurs ne parlent
// qu'à `MailDNSClient` : le client réel passe par le résolveur de NetScopeCore/Tools/DNSLookup.swift,
// les tests et la démonstration par `MailDNSFixture` (réponses fixes, aucun trafic réseau).

/// Réponse DNS réduite à ce dont les outils courriel ont besoin.
public struct MailDNSAnswer: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// Réponse obtenue (éventuellement vide : NOERROR sans enregistrement de ce type).
        case answer
        /// Le nom n'existe pas.
        case nxdomain
        /// Échec : délai dépassé, SERVFAIL, REFUSED, réseau…
        case failure(String)
    }

    public var outcome: Outcome
    /// Valeurs du type demandé, dans l'ordre de la réponse (TXT déjà recollés, sans guillemets).
    public var values: [String]

    public init(outcome: Outcome, values: [String] = []) {
        self.outcome = outcome
        self.values = values
    }

    public static let nxdomain = MailDNSAnswer(outcome: .nxdomain)
    public static func failure(_ text: String) -> MailDNSAnswer { MailDNSAnswer(outcome: .failure(text)) }

    public var isFailure: Bool { if case .failure = outcome { return true } else { return false } }
    public var failureText: String? { if case .failure(let text) = outcome { return text } else { return nil } }
    /// Aucune valeur sans échec (NXDOMAIN ou réponse vide) : « recherche vide » au sens de SPF.
    public var isEmpty: Bool { values.isEmpty && !isFailure }
}

/// État DNSSEC d'un domaine, d'après la présence d'un enregistrement DS dans la zone parente.
public enum MailDNSSECState: String, Codable, Hashable, Sendable {
    case signed, unsigned, unknown
}

/// Source des réponses : DNS réel, ou réponses fixes (tests, démonstration).
public protocol MailDNSClient: Sendable {
    func query(_ name: String, _ type: DNSRecordType) async -> MailDNSAnswer
    /// Délégation signée (DS présent chez le parent) ; `.unknown` si la question n'a pas abouti.
    func dnssec(_ domain: String) async -> MailDNSSECState
    /// Contenu d'un fichier texte en HTTPS (politique MTA-STS), sans suivre de redirection.
    func fetchText(_ url: URL) async throws -> String
    /// Délai entre deux départs de requêtes en rafale (listes noires, sélecteurs DKIM), en secondes.
    var pacing: TimeInterval { get }
}

extension MailDNSClient {
    public var pacing: TimeInterval { 0.05 }
}

public enum MailDNSError: Error, LocalizedError, Equatable, Sendable {
    case http(Int)
    case tooLarge
    case notText
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "Le serveur a répondu HTTP \(code)."
        case .tooLarge: return "Fichier trop volumineux (plus de 64 Ko)."
        case .notText: return "Le fichier n’est pas du texte."
        case .unavailable(let text): return text
        }
    }
}

// MARK: - Mise en forme commune

public enum MailDNSText {
    /// « "v=spf1 include:a " "~all" » → « v=spf1 include:a ~all » : les chaînes d'un même TXT
    /// sont recollées sans séparateur (RFC 7208 §3.3).
    public static func joinTXT(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\"") else { return trimmed }
        var parts: [String] = []
        var current = ""
        var inside = false
        var escaped = false
        for char in trimmed {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" && inside {
                escaped = true
            } else if char == "\"" {
                if inside { parts.append(current); current = "" }
                inside.toggle()
            } else if inside {
                current.append(char)
            }
        }
        if inside { parts.append(current) }
        return parts.joined()
    }

    /// Nom sans point final, en minuscules : « MX1.Exemple.CA. » → « mx1.exemple.ca ».
    public static func normalize(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces).lowercased()
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// « 10 mx1.exemple.ca. » → (10, « mx1.exemple.ca »).
    public static func parseMX(_ value: String) -> (priority: Int, host: String)? {
        let fields = value.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let priority = Int(fields[0]) else { return nil }
        return (priority, normalize(String(fields[1])))
    }

    /// Nom DNS plausible : étiquettes de 1 à 63 caractères, lettres, chiffres, tirets, soulignés.
    public static func isDomainName(_ text: String) -> Bool {
        let name = normalize(text)
        guard !name.isEmpty, name.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            (1...63).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Suffixes à deux niveaux les plus courants (liste volontairement courte, sans la liste
    /// complète des suffixes publics).
    static let twoLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "com.au", "net.au", "org.au", "co.nz", "com.br", "co.jp",
        "qc.ca", "on.ca", "bc.ca", "ab.ca", "gc.ca", "gouv.fr", "com.fr", "co.za", "com.mx", "com.cn",
    ]

    /// Domaine organisationnel approché : « mail.ventes.exemple.ca » → « exemple.ca »,
    /// « www.exemple.co.uk » → « exemple.co.uk ».
    public static func organizationalDomain(_ domain: String) -> String {
        let labels = normalize(domain).split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let keep = twoLevelSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Adresse réservée (privée, boucle locale, lien local, CGNAT, multidiffusion…) : inutile de
    /// la chercher dans une liste noire publique. Les plages de documentation (192.0.2.0/24…)
    /// ne sont pas exclues : les tests s'en servent comme d'adresses publiques.
    public static func isReserved(_ ip: IPv4Address) -> Bool {
        let o = ip.octets
        switch o.0 {
        case 0, 10, 127: return true
        case 100: return (64...127).contains(o.1)
        case 169: return o.1 == 254
        case 172: return (16...31).contains(o.1)
        case 192: return o.1 == 168 || (o.1 == 0 && o.2 == 0)
        case 198: return o.1 == 18 || o.1 == 19
        default: return o.0 >= 224
        }
    }
}

// MARK: - Client réel

/// Client réel : résolveur de DNSLookup (résolveur du système, ou serveur choisi), politique MTA-STS
/// par HTTPS. Une requête qui échoue ne lève pas d'erreur : elle revient en `.failure`.
public struct LiveMailDNSClient: MailDNSClient {
    public var server: IPv4Address?
    public var timeout: TimeInterval

    public init(server: IPv4Address? = nil, timeout: TimeInterval = 3) {
        self.server = server
        self.timeout = timeout
    }

    public func query(_ name: String, _ type: DNSRecordType) async -> MailDNSAnswer {
        do {
            let result = try await DNSLookup.resolve(name, type: type, server: server, timeout: timeout)
            switch result.rcode {
            case "NOERROR", "—":
                let records = result.answerCount > 0 || result.rcode == "—" ? result.records.filter { $0.typeCode == type.code } : []
                return MailDNSAnswer(outcome: .answer, values: records.map { type == .txt ? MailDNSText.joinTXT($0.value) : $0.value })
            case "NXDOMAIN":
                return .nxdomain
            default:
                return .failure(result.rcode)
            }
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func dnssec(_ domain: String) async -> MailDNSSECState {
        let server = self.server
        let timeout = self.timeout
        return await Task.detached(priority: .userInitiated) {
            Self.queryDS(domain, server: server, timeout: timeout)
        }.value
    }

    /// Requête DS (type 43) envoyée directement au serveur choisi ou au premier serveur configuré.
    static func queryDS(_ domain: String, server: IPv4Address?, timeout: TimeInterval) -> MailDNSSECState {
        guard let target = server ?? SystemResolver.configuredServers().first else { return .unknown }
        let id = UInt16.random(in: 1...UInt16.max)
        guard let name = try? DNSMessageCodec.encodeName(MailDNSText.normalize(domain)) else { return .unknown }
        var query = DNSMessageCodec.be16(id) + DNSMessageCodec.be16(0x0100)
        query += DNSMessageCodec.be16(1) + DNSMessageCodec.be16(0) + DNSMessageCodec.be16(0) + DNSMessageCodec.be16(0)
        query += name + DNSMessageCodec.be16(43) + DNSMessageCodec.be16(1)
        guard let bytes = try? DNSLookup.exchangeUDP(query, server: target, port: 53, timeout: timeout),
              let message = try? DNSMessageCodec.parse(bytes), message.id == id else { return .unknown }
        guard message.rcode == 0 || message.rcode == 3 else { return .unknown }
        return message.answers.contains { $0.typeCode == 43 } ? .signed : .unsigned
    }

    public func fetchText(_ url: URL) async throws -> String {
        guard url.scheme?.lowercased() == "https" else { throw MailDNSError.unavailable("Adresse HTTPS attendue.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("NetScope", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw MailDNSError.http(http.statusCode) }
        guard data.count <= 64 * 1024 else { throw MailDNSError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw MailDNSError.notText }
        return text
    }

    /// RFC 8461 §3.3 : la politique ne doit pas être obtenue par une redirection.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

// MARK: - Réponses fixes

/// Réponses fixes (tests et démonstration) : aucun trafic réseau. Clés « nom|TYPE » ; un nom
/// absent répond NXDOMAIN, un nom présent pour un autre type répond « vide ».
public struct MailDNSFixture: MailDNSClient {
    public var records: [String: [String]]
    public var failures: [String: String]
    public var signedDomains: Set<String>
    public var files: [String: String]
    /// Réponses fixes : aucune raison d'espacer les requêtes.
    public var pacing: TimeInterval { 0 }
    /// Requêtes reçues (comptées par les tests) : tableau partagé protégé par un verrou.
    public let log = MailDNSFixtureLog()

    public init(records: [String: [String]] = [:], failures: [String: String] = [:], signedDomains: Set<String> = [],
                files: [String: String] = [:]) {
        self.records = [:]
        for (key, values) in records { self.records[Self.key(key)] = values }
        self.failures = [:]
        for (key, value) in failures { self.failures[Self.key(key)] = value }
        self.signedDomains = Set(signedDomains.map(MailDNSText.normalize))
        self.files = files
    }

    /// « Exemple.CA.|txt » → « exemple.ca|TXT ».
    static func key(_ raw: String) -> String {
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return MailDNSText.normalize(raw) }
        return MailDNSText.normalize(parts[0]) + "|" + parts[1].uppercased()
    }

    public mutating func add(_ name: String, _ type: DNSRecordType, _ values: [String]) {
        records[Self.key("\(name)|\(type.rawValue)"), default: []] += values
    }

    public func query(_ name: String, _ type: DNSRecordType) async -> MailDNSAnswer {
        var normalized = MailDNSText.normalize(name)
        if type == .ptr, let ip = IPv4Address(normalized) { normalized = DNSLookup.reverseName(for: ip) }
        log.append("\(normalized)|\(type.rawValue)")
        let key = "\(normalized)|\(type.rawValue)"
        if let failure = failures[key] { return .failure(failure) }
        if let values = records[key] { return MailDNSAnswer(outcome: .answer, values: values) }
        let exists = records.keys.contains { $0.hasPrefix(normalized + "|") }
        return exists ? MailDNSAnswer(outcome: .answer) : .nxdomain
    }

    public func dnssec(_ domain: String) async -> MailDNSSECState {
        signedDomains.contains(MailDNSText.normalize(domain)) ? .signed : .unsigned
    }

    public func fetchText(_ url: URL) async throws -> String {
        guard let text = files[url.absoluteString] else { throw MailDNSError.http(404) }
        return text
    }
}

/// Journal des requêtes d'un `MailDNSFixture`.
public final class MailDNSFixtureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    public init() {}

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    public var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
