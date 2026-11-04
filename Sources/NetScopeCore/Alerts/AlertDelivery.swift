import Foundation

// Envoi d'un lot d'alertes sur un canal et ligne du journal qui en résulte. Le réseau passe par
// des points d'injection (fabrique de transport SMTP, client HTTP) : les tests utilisent des faux,
// sans aucun envoi réel. Le journal ne contient jamais de secret (AlertRedactor).

/// Secrets lus au Trousseau par l'application, juste avant l'envoi.
public struct AlertSecrets: Sendable {
    public var smtpPassword: String?
    public var webhookURLs: [UUID: String]
    public var webhookAuth: [UUID: String]

    public init(smtpPassword: String? = nil, webhookURLs: [UUID: String] = [:], webhookAuth: [UUID: String] = [:]) {
        self.smtpPassword = smtpPassword
        self.webhookURLs = webhookURLs
        self.webhookAuth = webhookAuth
    }

    /// Toutes les valeurs secrètes (pour les retirer du journal).
    public var all: [String] {
        ([smtpPassword].compactMap { $0 } + Array(webhookURLs.values) + Array(webhookAuth.values)).filter { !$0.isEmpty }
    }
}

// MARK: - HTTP

/// Client HTTP des webhooks (URLSession, ou faux client des tests).
public protocol AlertHTTPClient: Sendable {
    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data)
}

/// Client réel : session éphémère (ni cookie, ni cache), délai court.
public struct AlertURLSessionClient: AlertHTTPClient {
    public init() {}

    public func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Échec d'un webhook, expliqué en français.
public enum AlertWebhookError: Error, Equatable, Sendable, LocalizedError {
    case missingURL
    case invalidURL
    case insecureURL
    case http(status: Int, body: String)
    case network(String)

    public var errorDescription: String? {
        let nbsp = "\u{00A0}"
        switch self {
        case .missingURL: return "Adresse du webhook absente du Trousseau\(nbsp): modifiez le webhook pour la saisir de nouveau."
        case .invalidURL: return "Adresse du webhook invalide."
        case .insecureURL: return "Adresse refusée\(nbsp): NetScope n’envoie les webhooks qu’en https://."
        case .http(let status, let body):
            let suffix = body.isEmpty ? "" : " Réponse\(nbsp): «\(nbsp)\(body)\(nbsp)»."
            switch status {
            case 400: return "Contenu refusé par le service (400).\(suffix)"
            case 401, 403: return "Accès refusé (\(status))\(nbsp): adresse révoquée, flux désactivé ou jeton d’authentification invalide.\(suffix)"
            case 404: return "Webhook introuvable (404)\(nbsp): il a été supprimé, ou l’adresse est incomplète.\(suffix)"
            case 410: return "Webhook désactivé (410)\(nbsp): canal archivé ou connecteur retiré.\(suffix)"
            case 413: return "Message trop volumineux pour le service (413)."
            case 429: return "Trop de messages (429)\(nbsp): le service limite les envois, réessayez plus tard."
            case 500...599: return "Le service est en panne ou indisponible (\(status)).\(suffix)"
            default: return "Réponse inattendue du service (\(status)).\(suffix)"
            }
        case .network(let text): return text
        }
    }

    public var shortLabel: String {
        switch self {
        case .missingURL: return "Adresse absente"
        case .invalidURL: return "Adresse invalide"
        case .insecureURL: return "Adresse non chiffrée"
        case .http(let status, _): return "HTTP \(status)"
        case .network: return "Réseau"
        }
    }

    /// Erreur URLSession → explication.
    public static func from(_ error: Error) -> AlertWebhookError {
        guard let urlError = error as? URLError else { return .network(error.localizedDescription) }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .network("Pas de connexion Internet\u{00A0}: le webhook n’a pas pu partir.")
        case .timedOut: return .network("Délai dépassé\u{00A0}: le service ne répond pas.")
        case .cannotFindHost, .dnsLookupFailed: return .network("Serveur du webhook introuvable (DNS).")
        case .cannotConnectToHost: return .network("Connexion refusée par le serveur du webhook.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
            return .network("Connexion sécurisée impossible\u{00A0}: certificat du serveur refusé (proxy ou inspection TLS\u{00A0}?).")
        default: return .network("Erreur réseau (\(urlError.code.rawValue)).")
        }
    }
}

public enum AlertWebhookAddress {
    /// Adresse acceptée : https:// avec un hôte (http:// seulement vers 127.0.0.1 et localhost).
    public static func validate(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AlertWebhookError.missingURL }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw AlertWebhookError.invalidURL
        }
        if scheme == "https" { return url }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) { return url }
        throw scheme == "http" ? AlertWebhookError.insecureURL : AlertWebhookError.invalidURL
    }

    /// Nom d'en-tête HTTP valide (lettres, chiffres, tirets).
    public static func isValidHeaderName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9!#$%&'*+.^_`|~-]+$", options: .regularExpression) != nil
    }
}

// MARK: - Envoi

/// Envoi d'un lot sur un canal.
public struct AlertDelivery: Sendable {
    public typealias SMTPFactory = @Sendable (_ host: String, _ port: UInt16, _ security: AlertSMTPSecurity) -> SMTPSubmitTransport

    public var context: AlertContext
    public var http: AlertHTTPClient
    public var smtpTransport: SMTPFactory
    public var ehloName: String
    public var timeout: TimeInterval

    public init(context: AlertContext, http: AlertHTTPClient = AlertURLSessionClient(),
                smtpTransport: @escaping SMTPFactory = { SMTPNetworkTransport(host: $0, port: $1, security: $2) },
                ehloName: String = "[127.0.0.1]", timeout: TimeInterval = 20) {
        self.context = context
        self.http = http
        self.smtpTransport = smtpTransport
        self.ehloName = ehloName
        self.timeout = timeout
    }

    /// Envoie et renvoie la ligne du journal (sans secret).
    public func deliver(_ batch: AlertBatch, on channel: AlertChannel, settings: AlertSettings, secrets: AlertSecrets,
                        now: Date = Date()) async -> AlertLogEntry {
        switch channel {
        case .email:
            return await deliverMail(batch, settings: settings, secrets: secrets, now: now)
        case .webhook(let id):
            guard let hook = settings.webhook(id) else {
                return entry(batch, kind: "webhook", name: "Webhook supprimé", outcome: .failed, detail: "Webhook introuvable dans les réglages.", now: now)
            }
            return await deliverWebhook(batch, hook: hook, settings: settings, secrets: secrets, now: now)
        }
    }

    private func entry(_ batch: AlertBatch, kind: String, name: String, outcome: AlertLogEntry.Outcome, detail: String,
                       duration: Double? = nil, now: Date, secrets: AlertSecrets = AlertSecrets()) -> AlertLogEntry {
        AlertLogEntry(date: now, channelKind: kind, channelName: name, outcome: outcome, title: batch.title,
                      eventCount: batch.events.count, severity: batch.severity, isTest: batch.isTest,
                      detail: AlertRedactor.redact(detail, secrets: secrets.all), durationMs: duration)
    }

    func deliverMail(_ batch: AlertBatch, settings: AlertSettings, secrets: AlertSecrets, now: Date) async -> AlertLogEntry {
        let smtp = settings.smtp
        let name = "Courriel · \(smtp.host.isEmpty ? "—" : smtp.host)"
        let problems = smtp.problems(hasPassword: !(secrets.smtpPassword ?? "").isEmpty)
        guard problems.isEmpty else {
            return entry(batch, kind: "courriel", name: name, outcome: .failed, detail: problems.joined(separator: " "), now: now, secrets: secrets)
        }
        let message = AlertComposer.mail(batch, smtp: smtp, context: context, now: now)
        let config = SMTPSubmitConfig(host: smtp.host.trimmingCharacters(in: .whitespaces), port: smtp.port, security: smtp.security,
                                      username: smtp.username.trimmingCharacters(in: .whitespaces),
                                      password: secrets.smtpPassword, ehloName: ehloName, timeout: timeout)
        let transport = smtpTransport(config.host, config.port, config.security)
        let outcome = await SMTPSubmission.send(message, config: config, transport: transport)
        if let error = outcome.error {
            return entry(batch, kind: "courriel", name: name, outcome: .failed, detail: error.errorDescription ?? error.shortLabel,
                         duration: outcome.durationMs, now: now, secrets: secrets)
        }
        var detail = outcome.queueReply ?? "Accepté par le serveur"
        detail += " · \(outcome.acceptedRecipients.count) destinataire\(outcome.acceptedRecipients.count > 1 ? "s" : "")"
        if !outcome.rejectedRecipients.isEmpty { detail += " · refusé\u{00A0}: " + outcome.rejectedRecipients.joined(separator: ", ") }
        if outcome.encrypted { detail += " · chiffré" }
        return entry(batch, kind: "courriel", name: name, outcome: .sent, detail: detail, duration: outcome.durationMs, now: now, secrets: secrets)
    }

    func deliverWebhook(_ batch: AlertBatch, hook: AlertWebhook, settings: AlertSettings, secrets: AlertSecrets,
                        now: Date) async -> AlertLogEntry {
        let name = settings.channelName(.webhook(hook.id))
        let kind = hook.kind.rawValue
        let started = Date()
        do {
            let url = try AlertWebhookAddress.validate(secrets.webhookURLs[hook.id] ?? "")
            let body = try AlertComposer.body(for: hook.kind, batch: batch, context: context, now: now)
            var headers = ["Content-Type": "application/json; charset=utf-8", "User-Agent": "NetScope/\(context.version)"]
            if hook.kind == .generic {
                let header = hook.authHeaderName.trimmingCharacters(in: .whitespaces)
                if !header.isEmpty, AlertWebhookAddress.isValidHeaderName(header), let value = secrets.webhookAuth[hook.id], !value.isEmpty {
                    headers[header] = value
                }
            }
            let response: (status: Int, body: Data)
            do {
                response = try await http.post(url: url, headers: headers, body: body, timeout: timeout)
            } catch {
                throw AlertWebhookError.from(error)
            }
            let duration = Date().timeIntervalSince(started) * 1000
            let text = String(decoding: response.body.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (200..<300).contains(response.status) else {
                throw AlertWebhookError.http(status: response.status, body: String(AlertText.singleLine(text).prefix(120)))
            }
            // Slack répond « ok » ; Teams (Workflows) 202 Accepted sans corps.
            let detail = "HTTP \(response.status)" + (text.isEmpty || text.count > 40 ? "" : " · \(AlertText.singleLine(text))")
            return entry(batch, kind: kind, name: name, outcome: .sent, detail: detail, duration: duration, now: now, secrets: secrets)
        } catch let error as AlertWebhookError {
            return entry(batch, kind: kind, name: name, outcome: .failed, detail: error.errorDescription ?? error.shortLabel,
                         duration: Date().timeIntervalSince(started) * 1000, now: now, secrets: secrets)
        } catch {
            return entry(batch, kind: kind, name: name, outcome: .failed, detail: error.localizedDescription, now: now, secrets: secrets)
        }
    }
}
