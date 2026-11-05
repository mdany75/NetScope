import Foundation

// Note 76 (0.28.0) : alertes sur téléphone par ntfy (ntfy.sh ou serveur auto-hébergé) et Pushover.
// Deux nouveaux canaux d'Alertes, désactivés par défaut, à côté du courriel et des webhooks.
//
// Ce fichier ne fait que DÉCRIRE les requêtes (adresse, en-têtes, corps) : fonctions pures,
// testées sans réseau. L'envoi passe par AlertDelivery et son client HTTP injectable.
// Les réglages ne contiennent aucun secret : le jeton ntfy, le jeton d'application et la clé
// utilisateur Pushover restent au Trousseau (AlertSecretKey).

// MARK: - Filtre propre à un canal

/// Filtre d'un canal de téléphone, appliqué APRÈS les règles communes (types, gravité minimale,
/// sondes exclues, heures de silence, anti-rafale) : on peut ne recevoir sur le téléphone que
/// le critique, ou que les sondes de certains sites.
public struct AlertChannelFilter: Codable, Equatable, Sendable {
    /// Gravité minimale envoyée sur ce canal (un rétablissement suit toujours sa panne).
    public var minimumSeverity: AlertSeverity = .info
    /// Sites retenus (vide : tous). Un événement sans site (service en ligne, test DHCP, scan)
    /// passe toujours : il ne dépend d'aucun site.
    public var siteIDs: Set<UUID> = []

    public init(minimumSeverity: AlertSeverity = .info, siteIDs: Set<UUID> = []) {
        self.minimumSeverity = minimumSeverity
        self.siteIDs = siteIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minimumSeverity = try c.decodeIfPresent(AlertSeverity.self, forKey: .minimumSeverity) ?? .info
        siteIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .siteIDs) ?? []
    }

    private enum CodingKeys: String, CodingKey { case minimumSeverity, siteIDs }

    /// Vrai si l'événement part sur ce canal.
    public func accepts(_ event: AlertEvent) -> Bool {
        if event.kind == .test { return true }
        if event.kind != .probeRecovered, event.severity < minimumSeverity { return false }
        if !siteIDs.isEmpty, let site = event.siteID, !siteIDs.contains(site) { return false }
        return true
    }

    /// Lot réduit aux événements retenus (nil : rien pour ce canal).
    public func apply(_ batch: AlertBatch) -> AlertBatch? {
        if batch.isTest { return batch }
        let kept = batch.events.filter(accepts)
        guard !kept.isEmpty else { return nil }
        if kept.count == batch.events.count { return batch }
        return AlertBatch(events: kept, suppressedCount: batch.suppressedCount, createdAt: batch.createdAt, isTest: batch.isTest)
    }

    /// « Toutes les gravités », « Alerte et critique », « Critique seulement ».
    public static func severityLabel(_ severity: AlertSeverity) -> String {
        switch severity {
        case .info: return "Toutes"
        case .warning: return "Alerte et critique"
        case .critical: return "Critique seulement"
        }
    }
}

/// Priorité choisie pour chaque gravité (valeurs propres au service).
public struct AlertPriorityMap: Codable, Equatable, Sendable {
    public var info: Int
    public var warning: Int
    public var critical: Int

    public init(info: Int, warning: Int, critical: Int) {
        self.info = info
        self.warning = warning
        self.critical = critical
    }

    public func value(for severity: AlertSeverity) -> Int {
        switch severity {
        case .info: return info
        case .warning: return warning
        case .critical: return critical
        }
    }

    public subscript(severity: AlertSeverity) -> Int {
        get { value(for: severity) }
        set {
            switch severity {
            case .info: info = newValue
            case .warning: warning = newValue
            case .critical: critical = newValue
            }
        }
    }

    /// Valeurs bornées à `range` (fichier modifié à la main ou version plus récente).
    func clamped(to range: ClosedRange<Int>) -> AlertPriorityMap {
        AlertPriorityMap(info: min(max(info, range.lowerBound), range.upperBound),
                         warning: min(max(warning, range.lowerBound), range.upperBound),
                         critical: min(max(critical, range.lowerBound), range.upperBound))
    }
}

// MARK: - ntfy

/// Réglages du canal ntfy (sans le jeton d'accès, gardé au Trousseau).
public struct AlertNtfySettings: Codable, Equatable, Sendable {
    public static let defaultServer = "https://ntfy.sh"
    /// Priorités ntfy : 1 (min) à 5 (max ou urgente).
    public static let priorityRange = 1...5
    public static let defaultPriorities = AlertPriorityMap(info: 3, warning: 4, critical: 5)

    public var isEnabled = false
    /// Adresse du serveur (ntfy.sh par défaut, ou serveur auto-hébergé en https://).
    public var server = AlertNtfySettings.defaultServer
    /// Sujet (« topic ») auquel l'application ntfy du téléphone est abonnée.
    public var topic = ""
    /// Étiquettes ajoutées au message (« siege », « reseau »).
    public var tags: [String] = []
    /// Ajoute l'émoji de gravité (🚨, ⚠️, ℹ️) devant le titre.
    public var severityEmoji = true
    public var priorities = AlertNtfySettings.defaultPriorities
    public var filter = AlertChannelFilter()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? Self.defaultServer
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        severityEmoji = try c.decodeIfPresent(Bool.self, forKey: .severityEmoji) ?? true
        priorities = (try c.decodeIfPresent(AlertPriorityMap.self, forKey: .priorities) ?? Self.defaultPriorities).clamped(to: Self.priorityRange)
        filter = try c.decodeIfPresent(AlertChannelFilter.self, forKey: .filter) ?? AlertChannelFilter()
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, server, topic, tags, severityEmoji, priorities, filter }

    /// Sujet valide pour ntfy : 1 à 64 lettres ASCII, chiffres, « - » ou « _ ».
    public static func isValidTopic(_ topic: String) -> Bool {
        topic.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    /// Étiquette acceptée : une ligne, sans virgule, 1 à 40 caractères.
    public static func isValidTag(_ tag: String) -> Bool {
        let text = tag.trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && text.count <= 40 && !text.contains(",") && AlertText.singleLine(text) == text
    }

    /// « siege, reseau ; urgent » → liste sans vide ni doublon.
    public static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Sujet difficile à deviner (sur ntfy.sh, quiconque connaît le sujet lit les messages).
    public static func randomTopic(prefix: String = "netscope") -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        let suffix = String((0..<16).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] })
        return "\(prefix)-\(suffix)"
    }

    /// Vrai pour le service public ntfy.sh (sujets lisibles par quiconque les connaît).
    public var isPublicServer: Bool {
        guard let host = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "ntfy.sh"
    }

    /// Problèmes qui empêchent l'envoi (vide : prêt). Le jeton est facultatif.
    public func problems() -> [String] {
        var list: [String] = []
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty {
            list.append("Serveur ntfy à renseigner (https://ntfy.sh ou le vôtre).")
        } else {
            do { _ = try AlertNtfyRequest.endpoint(server: address) } catch {
                list.append((error as? LocalizedError)?.errorDescription ?? "Adresse du serveur invalide.")
            }
        }
        let name = topic.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            list.append("Sujet à renseigner.")
        } else if !Self.isValidTopic(name) {
            list.append("Sujet invalide\u{00A0}: lettres sans accent, chiffres, «\u{00A0}-\u{00A0}» et «\u{00A0}_\u{00A0}» seulement (64 au plus).")
        }
        if let bad = tags.first(where: { !Self.isValidTag($0) }) {
            list.append("Étiquette invalide\u{00A0}: «\u{00A0}\(bad)\u{00A0}».")
        }
        return list
    }

    /// Libellé d'une priorité ntfy.
    public static func priorityLabel(_ value: Int) -> String {
        switch value {
        case 1: return "Minimale"
        case 2: return "Basse"
        case 3: return "Normale"
        case 4: return "Haute"
        default: return "Urgente"
        }
    }
}

/// Requête HTTP prête à partir (adresse, en-têtes, corps) : rien n'est envoyé ici.
public struct AlertHTTPRequest: Equatable, Sendable {
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// Erreur de préparation ou d'envoi d'un canal de téléphone, expliquée en français.
public enum AlertPhoneError: Error, Equatable, Sendable, LocalizedError {
    case invalidServer
    case insecureServer
    case invalidTopic
    case missingToken
    case missingUserKey
    case invalidCredential(String)
    case http(service: String, status: Int, message: String)
    case network(String)

    public var errorDescription: String? {
        let nbsp = "\u{00A0}"
        switch self {
        case .invalidServer: return "Adresse du serveur ntfy invalide."
        case .insecureServer: return "Adresse refusée\(nbsp): NetScope n’envoie qu’en https:// (http:// seulement vers ce Mac)."
        case .invalidTopic: return "Sujet ntfy invalide."
        case .missingToken: return "Jeton d’application Pushover absent du Trousseau\(nbsp): saisissez-le de nouveau."
        case .missingUserKey: return "Clé utilisateur Pushover absente du Trousseau\(nbsp): saisissez-la de nouveau."
        case .invalidCredential(let what): return "\(what) invalide\(nbsp): 30 lettres et chiffres attendus."
        case .http(let service, let status, let message):
            let suffix = message.isEmpty ? "" : " Réponse\(nbsp): «\(nbsp)\(message)\(nbsp)»."
            switch status {
            case 400: return "Message refusé par \(service) (400).\(suffix)"
            case 401, 403: return "Accès refusé par \(service) (\(status))\(nbsp): jeton, clé ou droits sur le sujet à vérifier.\(suffix)"
            case 404: return "Adresse introuvable sur \(service) (404).\(suffix)"
            case 413: return "Message trop volumineux pour \(service) (413)."
            case 429: return "Trop de messages (429)\(nbsp): \(service) limite les envois, réessayez plus tard.\(suffix)"
            case 500...599: return "\(service) est en panne ou indisponible (\(status)).\(suffix)"
            default: return "Réponse inattendue de \(service) (\(status)).\(suffix)"
            }
        case .network(let text): return text
        }
    }

    /// Erreur URLSession → explication.
    public static func from(_ error: Error, service: String) -> AlertPhoneError {
        guard let urlError = error as? URLError else { return .network(error.localizedDescription) }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .network("Pas de connexion Internet\u{00A0}: le message \(service) n’a pas pu partir.")
        case .timedOut: return .network("Délai dépassé\u{00A0}: \(service) ne répond pas.")
        case .cannotFindHost, .dnsLookupFailed: return .network("Serveur \(service) introuvable (DNS).")
        case .cannotConnectToHost: return .network("Connexion refusée par le serveur \(service).")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
            return .network("Connexion sécurisée impossible avec \(service)\u{00A0}: certificat refusé (proxy ou inspection TLS\u{00A0}?).")
        default: return .network("Erreur réseau vers \(service) (\(urlError.code.rawValue)).")
        }
    }
}

/// Construction de la requête ntfy : publication en JSON (POST à la racine du serveur), qui porte
/// titre, message, priorité et étiquettes en UTF-8 sans les limites des en-têtes HTTP (ASCII).
/// Format : https://docs.ntfy.sh/publish/#publish-as-json
public enum AlertNtfyRequest {
    /// Corps publié (clés triées : sortie stable).
    public struct Payload: Codable, Equatable, Sendable {
        public var topic: String
        public var title: String
        public var message: String
        public var priority: Int
        public var tags: [String]
    }

    /// Message limité à 4 096 octets par ntfy : on garde une marge.
    public static let maxMessageBytes = 3_800

    /// Adresse de publication : le serveur (https://, ou http:// vers ce Mac seulement), chemin
    /// conservé pour un serveur publié sous un sous-dossier, barre finale ajoutée.
    public static func endpoint(server: String) throws -> URL {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty, parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil else {
            throw AlertPhoneError.invalidServer
        }
        if scheme == "http" {
            guard ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) else { throw AlertPhoneError.insecureServer }
        } else if scheme != "https" {
            throw AlertPhoneError.invalidServer
        }
        var components = parts
        components.scheme = scheme
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let url = components.url else { throw AlertPhoneError.invalidServer }
        return url
    }

    /// Étiquette d'émoji de la gravité (ntfy remplace les noms connus par l'émoji).
    public static func emojiTag(_ severity: AlertSeverity, isTest: Bool) -> String {
        if isTest { return "white_check_mark" }
        switch severity {
        case .critical: return "rotating_light"
        case .warning: return "warning"
        case .info: return "information_source"
        }
    }

    public static func payload(_ batch: AlertBatch, settings: AlertNtfySettings, context: AlertContext) -> Payload {
        var tags: [String] = []
        if settings.severityEmoji { tags.append(emojiTag(batch.severity, isTest: batch.isTest)) }
        for tag in settings.tags where AlertNtfySettings.isValidTag(tag) && !tags.contains(tag) { tags.append(tag) }
        let priority = batch.isTest ? 3 : settings.priorities.value(for: batch.severity)
        return Payload(topic: settings.topic.trimmingCharacters(in: .whitespaces),
                       title: AlertPhoneText.title(batch, limit: 250),
                       message: AlertPhoneText.truncate(AlertPhoneText.body(batch, context: context), maxBytes: maxMessageBytes),
                       priority: min(max(priority, AlertNtfySettings.priorityRange.lowerBound), AlertNtfySettings.priorityRange.upperBound),
                       tags: Array(tags.prefix(10)))
    }

    /// Requête complète. `token` : jeton d'accès (« tk_… ») ou valeur complète d'un en-tête
    /// Authorization (« Basic … », « Bearer … ») ; nil ou vide : aucune authentification.
    public static func make(_ batch: AlertBatch, settings: AlertNtfySettings, token: String?, context: AlertContext) throws -> AlertHTTPRequest {
        let url = try endpoint(server: settings.server)
        guard AlertNtfySettings.isValidTopic(settings.topic.trimmingCharacters(in: .whitespaces)) else { throw AlertPhoneError.invalidTopic }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(payload(batch, settings: settings, context: context))
        var headers = ["Content-Type": "application/json; charset=utf-8", "User-Agent": "NetScope/\(context.version)"]
        if let header = authorization(token) { headers["Authorization"] = header }
        return AlertHTTPRequest(url: url, headers: headers, body: body)
    }

    /// Valeur de l'en-tête Authorization : « Bearer jeton », ou la valeur telle quelle si elle
    /// commence déjà par un schéma (« Basic », « Bearer »). Une ligne, sans caractère de contrôle.
    public static func authorization(_ token: String?) -> String? {
        let value = AlertText.singleLine(token ?? "")
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("bearer ") || lower.hasPrefix("basic ") { return value }
        return "Bearer \(value)"
    }

    /// Message d'erreur de ntfy ({"code":40301,"http":403,"error":"forbidden",…}).
    public static func errorMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["error"] as? String {
            return String(AlertText.singleLine(text).prefix(160))
        }
        return String(AlertText.singleLine(String(decoding: data.prefix(300), as: UTF8.self)).prefix(120))
    }

    /// Identifiant du message publié ({"id":"sPs71M8A2T",…}).
    public static func messageID(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? String,
              id.range(of: "^[A-Za-z0-9]{1,32}$", options: .regularExpression) != nil else { return nil }
        return id
    }
}

// MARK: - Pushover

/// Réglages du canal Pushover (sans le jeton d'application ni la clé utilisateur, au Trousseau).
public struct AlertPushoverSettings: Codable, Equatable, Sendable {
    public static let endpoint = URL(string: "https://api.pushover.net/1/messages.json")!
    /// Priorités Pushover : -2 (aucune notification) à 2 (urgence, répétée jusqu'à l'accusé).
    public static let priorityRange = -2...2
    public static let defaultPriorities = AlertPriorityMap(info: -1, warning: 0, critical: 1)
    /// Urgence (priorité 2) : rappel toutes les `retry` secondes pendant `expire` secondes.
    public static let emergencyRetry = 60
    public static let emergencyExpire = 3_600

    /// Sons intégrés de Pushover (vide : son choisi dans l'application du téléphone).
    public static let sounds: [(id: String, label: String)] = [
        ("", "Réglage du téléphone"), ("pushover", "Pushover"), ("bike", "Vélo"), ("bugle", "Clairon"),
        ("cashregister", "Caisse enregistreuse"), ("classical", "Classique"), ("cosmic", "Cosmique"), ("falling", "Chute"),
        ("gamelan", "Gamelan"), ("incoming", "Arrivée"), ("intermission", "Entracte"), ("magic", "Magie"),
        ("mechanical", "Mécanique"), ("pianobar", "Piano-bar"), ("siren", "Sirène"), ("spacealarm", "Alarme spatiale"),
        ("tugboat", "Remorqueur"), ("alien", "Alarme extraterrestre (long)"), ("climb", "Montée (long)"),
        ("persistent", "Persistant (long)"), ("echo", "Écho (long)"), ("updown", "Haut-bas (long)"),
        ("vibrate", "Vibration seulement"), ("none", "Silencieux"),
    ]

    public var isEnabled = false
    /// Son (identifiant Pushover ; vide : celui du téléphone).
    public var sound = ""
    /// Appareils visés (noms Pushover séparés par des virgules ; vide : tous).
    public var device = ""
    public var priorities = AlertPushoverSettings.defaultPriorities
    public var filter = AlertChannelFilter()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? ""
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
        priorities = (try c.decodeIfPresent(AlertPriorityMap.self, forKey: .priorities) ?? Self.defaultPriorities).clamped(to: Self.priorityRange)
        filter = try c.decodeIfPresent(AlertChannelFilter.self, forKey: .filter) ?? AlertChannelFilter()
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, sound, device, priorities, filter }

    /// Jeton d'application ou clé utilisateur (ou de groupe) : 30 lettres et chiffres.
    public static func isValidKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z0-9]{30}$", options: .regularExpression) != nil
    }

    /// Noms d'appareils : lettres, chiffres, « _ » et « - » (25 au plus), séparés par des virgules.
    public static func isValidDevice(_ text: String) -> Bool {
        let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return !names.isEmpty && names.allSatisfy { $0.range(of: "^[A-Za-z0-9_-]{1,25}$", options: .regularExpression) != nil }
    }

    /// Appareils normalisés (« iphone-dany,ipad »).
    public var normalizedDevice: String {
        device.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
    }

    public static func isKnownSound(_ sound: String) -> Bool { sounds.contains { $0.id == sound } }

    /// Problèmes qui empêchent l'envoi (vide : prêt).
    public func problems(hasToken: Bool, hasUserKey: Bool) -> [String] {
        var list: [String] = []
        if !hasToken { list.append("Jeton d’application à enregistrer au Trousseau.") }
        if !hasUserKey { list.append("Clé utilisateur à enregistrer au Trousseau.") }
        if !normalizedDevice.isEmpty, !Self.isValidDevice(normalizedDevice) {
            list.append("Appareil invalide\u{00A0}: lettres, chiffres, «\u{00A0}-\u{00A0}» et «\u{00A0}_\u{00A0}» (25 au plus), séparés par des virgules.")
        }
        if !Self.isKnownSound(sound) { list.append("Son inconnu\u{00A0}: «\u{00A0}\(sound)\u{00A0}».") }
        return list
    }

    /// Libellé d'une priorité Pushover.
    public static func priorityLabel(_ value: Int) -> String {
        switch value {
        case ...(-2): return "Sans notification"
        case -1: return "Discrète"
        case 0: return "Normale"
        case 1: return "Haute"
        default: return "Urgence (répétée)"
        }
    }
}

/// Construction de la requête Pushover : POST https://api.pushover.net/1/messages.json en
/// application/x-www-form-urlencoded (UTF-8). https://pushover.net/api
public enum AlertPushoverRequest {
    /// Limites de l'API : titre 250 caractères, message 1 024.
    public static let maxTitle = 250
    public static let maxMessage = 1_024

    /// Champs envoyés, dans l'ordre (le jeton et la clé en premier).
    public static func fields(_ batch: AlertBatch, settings: AlertPushoverSettings, token: String, userKey: String,
                              context: AlertContext) -> [(String, String)] {
        let priority = batch.isTest ? 0 : min(max(settings.priorities.value(for: batch.severity), AlertPushoverSettings.priorityRange.lowerBound),
                                              AlertPushoverSettings.priorityRange.upperBound)
        var fields: [(String, String)] = [
            ("token", token), ("user", userKey),
            ("title", AlertPhoneText.title(batch, limit: maxTitle)),
            ("message", AlertPhoneText.truncate(AlertPhoneText.body(batch, context: context), maxCharacters: maxMessage)),
            ("priority", String(priority)),
            ("timestamp", String(Int(batch.createdAt.timeIntervalSince1970))),
        ]
        if priority == 2 {
            fields.append(("retry", String(AlertPushoverSettings.emergencyRetry)))
            fields.append(("expire", String(AlertPushoverSettings.emergencyExpire)))
        }
        if !settings.sound.isEmpty, AlertPushoverSettings.isKnownSound(settings.sound) { fields.append(("sound", settings.sound)) }
        let device = settings.normalizedDevice
        if !device.isEmpty, AlertPushoverSettings.isValidDevice(device) { fields.append(("device", device)) }
        return fields
    }

    /// Encodage application/x-www-form-urlencoded (RFC 3986 non réservés seulement, UTF-8).
    public static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    public static func make(_ batch: AlertBatch, settings: AlertPushoverSettings, token: String?, userKey: String?,
                            context: AlertContext) throws -> AlertHTTPRequest {
        let token = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let user = (userKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AlertPhoneError.missingToken }
        guard !user.isEmpty else { throw AlertPhoneError.missingUserKey }
        guard AlertPushoverSettings.isValidKey(token) else { throw AlertPhoneError.invalidCredential("Jeton d’application") }
        guard AlertPushoverSettings.isValidKey(user) else { throw AlertPhoneError.invalidCredential("Clé utilisateur") }
        let body = formEncode(fields(batch, settings: settings, token: token, userKey: user, context: context))
        return AlertHTTPRequest(url: AlertPushoverSettings.endpoint,
                                headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                                          "User-Agent": "NetScope/\(context.version)"],
                                body: Data(body.utf8))
    }

    /// Réponse de Pushover : {"status":1,"request":"…"} ; erreur : {"status":0,"errors":["…"]}.
    public static func parse(_ data: Data) -> (ok: Bool, request: String?, errors: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, nil, []) }
        let status = (object["status"] as? Int) ?? (object["status"] as? NSNumber)?.intValue ?? 0
        let request = (object["request"] as? String).map { String(AlertText.singleLine($0).prefix(64)) }
        let errors = (object["errors"] as? [Any] ?? []).compactMap { $0 as? String }.map { String(AlertText.singleLine($0).prefix(160)) }
        return (status == 1, request, errors)
    }
}

// MARK: - Texte court pour le téléphone

public enum AlertPhoneText {
    /// Titre de la notification (« Caméra-Quai hors ligne », « 3 alertes NetScope »).
    public static func title(_ batch: AlertBatch, limit: Int) -> String {
        String(AlertText.singleLine(batch.title).prefix(limit))
    }

    /// Corps lisible sur un écran de téléphone : message, précisions utiles, gravité et origine.
    public static func body(_ batch: AlertBatch, context: AlertContext) -> String {
        var lines: [String] = []
        if batch.events.count == 1 {
            let event = batch.events[0]
            lines.append(event.message)
            for detail in event.details.prefix(4) { lines.append("\(detail.label)\u{00A0}: \(detail.value)") }
            lines.append("\(event.severity.label) · \(context.stamp(event.occurredAt)) · \(context.origin)")
        } else {
            lines.append("\(batch.breakdown) · \(context.stamp(batch.createdAt)) · \(context.origin)")
            for event in batch.events.prefix(AlertComposer.maxListed) {
                lines.append("• [\(event.severity.label)] \(event.title) — \(context.clock(event.occurredAt))")
            }
            if batch.events.count > AlertComposer.maxListed {
                lines.append("… et \(batch.events.count - AlertComposer.maxListed) autre(s) événement(s).")
            }
        }
        if batch.suppressedCount > 0 { lines.append(AlertComposer.suppressedLine(batch.suppressedCount)) }
        return lines.joined(separator: "\n")
    }

    /// Coupe à `maxCharacters` caractères (points de suspension compris).
    public static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters, maxCharacters > 1 else { return text }
        return String(text.prefix(maxCharacters - 1)) + "…"
    }

    /// Coupe à `maxBytes` octets UTF-8 sans couper un caractère (points de suspension compris).
    public static func truncate(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        let ellipsis = "…".utf8.count
        for character in text {
            let size = String(character).utf8.count
            if used + size + ellipsis > maxBytes { break }
            result.append(character)
            used += size
        }
        return result + "…"
    }
}
