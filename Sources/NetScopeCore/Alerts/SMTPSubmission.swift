import Foundation

// Envoi d'un courriel d'alerte (soumission SMTP, RFC 5321, 6409, 4954, 3207). Dialogue complet :
// bannière, EHLO, STARTTLS puis EHLO chiffré, AUTH PLAIN ou LOGIN, MAIL FROM, RCPT TO, DATA (point
// doublé), QUIT. Le dialogue passe par un `SMTPSubmitTransport` : le vrai (Network.framework,
// SMTPSubmitNetwork.swift) ou un faux à réponses fixes pour les tests.
//
// Le diagnostic SMTP de la Boîte à outils (MailTools) reste limité à EHLO, STARTTLS et QUIT
// (`SMTPCommand`) : ces commandes d'envoi sont propres à ce fichier et ne servent qu'aux alertes,
// à la demande de l'utilisateur (alertes activées ou bouton « Envoyer un test »).

// MARK: - Erreurs

/// Échec d'un envoi, expliqué en français (sans jamais citer de secret).
public enum SMTPSubmitError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case hostNotFound(String)
    case connectionRefused(host: String, port: UInt16)
    /// Aucune réponse à la connexion : port probablement filtré.
    case portBlocked(host: String, port: UInt16)
    case timeout(String)
    case connectionClosed(String)
    case serverRefused(code: Int, text: String)
    case startTLSUnavailable
    case tlsFailed(String)
    case authUnavailable(offered: [String])
    case authRequiresEncryption
    case authFailed(code: Int, text: String)
    case authRequired(code: Int, text: String)
    case senderRejected(code: Int, text: String)
    case relayDenied(address: String, code: Int, text: String)
    case recipientRejected(address: String, code: Int, text: String)
    case messageRejected(code: Int, text: String)
    case temporaryFailure(stage: String, code: Int, text: String)
    case protocolError(String)

    public var errorDescription: String? {
        let nbsp = "\u{00A0}"
        switch self {
        case .invalidConfiguration(let text):
            return "Réglages incomplets\(nbsp): \(text)"
        case .hostNotFound(let host):
            return "Serveur introuvable\(nbsp): «\(nbsp)\(host)\(nbsp)» n’existe pas dans le DNS. Vérifiez le nom du serveur SMTP."
        case .connectionRefused(let host, let port):
            return "Connexion refusée par \(host) sur le port \(port)\(nbsp): aucun service SMTP n’y écoute. Vérifiez le port (587 pour STARTTLS, 465 pour TLS)."
        case .portBlocked(let host, let port):
            return "Aucune réponse de \(host) sur le port \(port)\(nbsp): le port est sans doute bloqué par un pare-feu ou par le fournisseur d’accès (le port 25 sortant l’est souvent). Essayez 587 ou 465."
        case .timeout(let stage):
            return "Délai dépassé (\(stage))\(nbsp): le serveur ne répond plus."
        case .connectionClosed(let stage):
            return "Connexion fermée par le serveur (\(stage))."
        case .serverRefused(let code, let text):
            return "Le serveur refuse la session (\(code) \(text)). L’adresse de ce réseau est peut-être sur une liste noire."
        case .startTLSUnavailable:
            return "Le serveur ne propose pas STARTTLS\(nbsp): NetScope n’envoie rien en clair. Essayez TLS sur le port 465, ou un autre serveur."
        case .tlsFailed(let reason):
            return "Échec du chiffrement TLS\(nbsp): \(reason)"
        case .authUnavailable(let offered):
            if offered.contains(where: { $0.uppercased().contains("XOAUTH2") || $0.uppercased() == "OAUTHBEARER" }) {
                return "Le serveur n’accepte que l’authentification moderne (OAuth, \(offered.joined(separator: ", ")))\(nbsp): activez SMTP AUTH pour ce compte, ou utilisez un mot de passe d’application."
            }
            return offered.isEmpty
                ? "Le serveur ne propose aucune authentification\(nbsp): retirez l’utilisateur s’il s’agit d’un relais qui n’en demande pas."
                : "Mécanismes d’authentification non pris en charge (\(offered.joined(separator: ", ")))\(nbsp): NetScope utilise PLAIN ou LOGIN."
        case .authRequiresEncryption:
            return "Mot de passe jamais envoyé en clair\(nbsp): activez STARTTLS ou TLS."
        case .authFailed(let code, let text):
            return "Authentification refusée (\(code) \(text)). Vérifiez l’utilisateur et le mot de passe\(nbsp); Microsoft 365 et Gmail demandent souvent un mot de passe d’application ou l’activation de SMTP AUTH."
        case .authRequired(let code, let text):
            return "Le serveur exige une authentification (\(code) \(text))\(nbsp): renseignez l’utilisateur et le mot de passe."
        case .senderRejected(let code, let text):
            return "Expéditeur refusé (\(code) \(text))\(nbsp): le compte n’a peut-être pas le droit d’envoyer avec cette adresse."
        case .relayDenied(let address, let code, let text):
            return "Relais refusé pour \(address) (\(code) \(text))\(nbsp): le serveur n’accepte pas de transmettre vers ce domaine. Authentifiez-vous, ou utilisez le serveur de votre fournisseur."
        case .recipientRejected(let address, let code, let text):
            return "Destinataire refusé\(nbsp): \(address) (\(code) \(text))."
        case .messageRejected(let code, let text):
            return "Message refusé par le serveur (\(code) \(text))."
        case .temporaryFailure(let stage, let code, let text):
            return "Refus temporaire (\(stage), \(code) \(text))\(nbsp): réessayez plus tard."
        case .protocolError(let text):
            return "Réponse SMTP inattendue\(nbsp): \(text)"
        }
    }

    /// Titre court pour le journal (« Authentification refusée »).
    public var shortLabel: String {
        switch self {
        case .invalidConfiguration: return "Réglages incomplets"
        case .hostNotFound: return "Serveur introuvable"
        case .connectionRefused: return "Connexion refusée"
        case .portBlocked: return "Port bloqué"
        case .timeout: return "Délai dépassé"
        case .connectionClosed: return "Connexion fermée"
        case .serverRefused: return "Session refusée"
        case .startTLSUnavailable: return "STARTTLS absent"
        case .tlsFailed: return "Échec TLS"
        case .authUnavailable: return "Authentification non proposée"
        case .authRequiresEncryption: return "Chiffrement exigé"
        case .authFailed: return "Authentification refusée"
        case .authRequired: return "Authentification exigée"
        case .senderRejected: return "Expéditeur refusé"
        case .relayDenied: return "Relais refusé"
        case .recipientRejected: return "Destinataire refusé"
        case .messageRejected: return "Message refusé"
        case .temporaryFailure: return "Refus temporaire"
        case .protocolError: return "Erreur de protocole"
        }
    }
}

// MARK: - Transport

/// Connexion SMTP utilisée par la session d'envoi (réseau ou faux serveur des tests).
public protocol SMTPSubmitTransport: AnyObject, Sendable {
    /// Ouvre la connexion (et la poignée TLS en mode TLS implicite).
    func open() async throws
    func write(_ bytes: [UInt8]) async throws
    func readReply(timeout: TimeInterval) async throws -> SMTPReply
    /// Démarre TLS sur la connexion ouverte (après « 220 » à STARTTLS).
    func upgradeToTLS() async throws
    var isEncrypted: Bool { get }
    func close()
}

/// Réglages d'une session d'envoi.
public struct SMTPSubmitConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var security: AlertSMTPSecurity
    public var username: String
    public var password: String?
    /// Nom annoncé par EHLO (« [192.168.1.20] » par défaut, forme prévue pour un poste sans nom public).
    public var ehloName: String
    public var timeout: TimeInterval

    public init(host: String, port: UInt16, security: AlertSMTPSecurity, username: String = "", password: String? = nil,
                ehloName: String = "[127.0.0.1]", timeout: TimeInterval = 20) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.password = password
        self.ehloName = ehloName
        self.timeout = timeout
    }
}

/// Résultat d'une session : réussite ou erreur, et l'échange (identifiants masqués).
public struct SMTPSubmitOutcome: Sendable {
    public var error: SMTPSubmitError?
    /// « C: EHLO … », « S: 250-… » ; les lignes d'authentification sont masquées.
    public var transcript: [String]
    public var encrypted: Bool
    public var authMechanism: String?
    public var acceptedRecipients: [String]
    public var rejectedRecipients: [String]
    /// Dernière ligne de la réponse à la fin de DATA (« 250 2.0.0 Ok: queued as 4F2A »).
    public var queueReply: String?
    public var durationMs: Double

    public var succeeded: Bool { error == nil }
}

// MARK: - Session

public enum SMTPSubmission {
    /// Mot remplaçant les secrets dans l'échange.
    public static let mask = "••••••••"

    /// Envoie `message` par `transport`. Ne lève pas d'erreur : l'échec est dans le résultat.
    public static func send(_ message: AlertMailMessage, config: SMTPSubmitConfig, transport: SMTPSubmitTransport,
                            now: @Sendable () -> Date = { Date() }) async -> SMTPSubmitOutcome {
        let start = now()
        let log = SMTPSubmitLog()
        var outcome = SMTPSubmitOutcome(error: nil, transcript: [], encrypted: false, authMechanism: nil,
                                        acceptedRecipients: [], rejectedRecipients: [], queueReply: nil, durationMs: 0)
        do {
            try validate(message, config: config)
            let session = Session(transport: transport, log: log, timeout: config.timeout)
            try await run(message, config: config, session: session, outcome: &outcome)
        } catch let error as SMTPSubmitError {
            outcome.error = error
            log.note("Échec\u{00A0}: \(error.shortLabel)")
            // QUIT poli si la connexion tient encore (sans attendre longtemps).
            await politeQuit(transport: transport, log: log)
        } catch {
            outcome.error = .protocolError(error.localizedDescription)
            await politeQuit(transport: transport, log: log)
        }
        transport.close()
        outcome.encrypted = outcome.encrypted || transport.isEncrypted
        outcome.transcript = log.lines
        outcome.durationMs = now().timeIntervalSince(start) * 1000
        return outcome
    }

    static func validate(_ message: AlertMailMessage, config: SMTPSubmitConfig) throws {
        guard AlertText.isValidHostname(config.host) else { throw SMTPSubmitError.invalidConfiguration("serveur SMTP manquant ou invalide.") }
        guard config.port > 0 else { throw SMTPSubmitError.invalidConfiguration("port invalide.") }
        guard AlertAddress.isValid(message.from) else { throw SMTPSubmitError.invalidConfiguration("adresse de l’expéditeur invalide.") }
        guard !message.to.isEmpty, message.to.allSatisfy(AlertAddress.isValid) else {
            throw SMTPSubmitError.invalidConfiguration("destinataire manquant ou invalide.")
        }
        if !config.username.isEmpty {
            guard config.security != .none else { throw SMTPSubmitError.authRequiresEncryption }
            guard let password = config.password, !password.isEmpty else {
                throw SMTPSubmitError.invalidConfiguration("mot de passe absent du Trousseau.")
            }
        }
    }

    private static func run(_ message: AlertMailMessage, config: SMTPSubmitConfig, session: Session,
                            outcome: inout SMTPSubmitOutcome) async throws {
        let transport = session.transport
        try await transport.open()
        session.log.isOpen = true
        session.log.note("Connecté à \(config.host):\(config.port)" + (transport.isEncrypted ? " (TLS)" : ""))

        // Bannière
        let banner = try await session.read("bannière")
        guard banner.code == 220 else {
            if banner.isTransientFailure { throw SMTPSubmitError.temporaryFailure(stage: "bannière", code: banner.code, text: banner.firstLine) }
            throw SMTPSubmitError.serverRefused(code: banner.code, text: banner.firstLine)
        }

        // EHLO
        var extensions = try await ehlo(session, name: config.ehloName)

        // STARTTLS
        if config.security == .startTLS {
            guard extensions.contains("STARTTLS") else { throw SMTPSubmitError.startTLSUnavailable }
            let reply = try await session.command("STARTTLS", stage: "STARTTLS")
            guard reply.code == 220 else {
                throw SMTPSubmitError.tlsFailed("STARTTLS refusé (\(reply.code) \(reply.firstLine)).")
            }
            session.log.note("Poignée TLS…")
            try await transport.upgradeToTLS()
            session.log.note("Chiffré")
            extensions = try await ehlo(session, name: config.ehloName)
        }
        if config.security != .none && !transport.isEncrypted {
            throw SMTPSubmitError.tlsFailed("la session n’est pas chiffrée.")
        }
        outcome.encrypted = transport.isEncrypted

        // Authentification
        let user = config.username.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty, let password = config.password {
            outcome.authMechanism = try await authenticate(session, extensions: extensions, user: user, password: password)
        }

        // Enveloppe
        let mail = try await session.command("MAIL FROM:<\(message.from)>", stage: "MAIL FROM")
        guard mail.code == 250 else {
            if mail.code == 530 || (mail.code == 550 && mail.text.contains("5.7.0") && user.isEmpty) {
                throw SMTPSubmitError.authRequired(code: mail.code, text: mail.firstLine)
            }
            if mail.isTransientFailure { throw SMTPSubmitError.temporaryFailure(stage: "MAIL FROM", code: mail.code, text: mail.firstLine) }
            throw SMTPSubmitError.senderRejected(code: mail.code, text: mail.firstLine)
        }
        var firstRejection: SMTPSubmitError?
        for address in message.to {
            let reply = try await session.command("RCPT TO:<\(address)>", stage: "RCPT TO")
            if reply.code == 250 || reply.code == 251 {
                outcome.acceptedRecipients.append(address)
                continue
            }
            outcome.rejectedRecipients.append(address)
            if firstRejection == nil { firstRejection = classifyRecipient(address: address, reply: reply, authenticated: outcome.authMechanism != nil) }
        }
        guard !outcome.acceptedRecipients.isEmpty else {
            throw firstRejection ?? SMTPSubmitError.protocolError("aucun destinataire accepté.")
        }

        // Message
        let data = try await session.command("DATA", stage: "DATA")
        guard data.code == 354 else {
            if data.isTransientFailure { throw SMTPSubmitError.temporaryFailure(stage: "DATA", code: data.code, text: data.firstLine) }
            throw SMTPSubmitError.messageRejected(code: data.code, text: data.firstLine)
        }
        let payload = SMTPDotStuffing.dataPayload(message.rendered())
        session.log.client("(message de \(payload.count) octets)")
        try await transport.write(payload)
        let queued = try await session.read("fin du message")
        guard queued.code == 250 else {
            if queued.isTransientFailure { throw SMTPSubmitError.temporaryFailure(stage: "fin du message", code: queued.code, text: queued.firstLine) }
            throw SMTPSubmitError.messageRejected(code: queued.code, text: queued.firstLine)
        }
        outcome.queueReply = "\(queued.code) \(queued.firstLine)"

        // Fin
        _ = try? await session.command("QUIT", stage: "QUIT", timeout: 5)
        // Un destinataire refusé sur plusieurs : envoi réussi, mais signalé.
        if let firstRejection, !outcome.rejectedRecipients.isEmpty {
            session.log.note("Refusé\u{00A0}: " + outcome.rejectedRecipients.joined(separator: ", ") + " (" + (firstRejection.shortLabel) + ")")
        }
    }

    private static func ehlo(_ session: Session, name: String) async throws -> [SMTPExtension] {
        let reply = try await session.command("EHLO \(name)", stage: "EHLO")
        guard reply.code == 250 else {
            if reply.isTransientFailure { throw SMTPSubmitError.temporaryFailure(stage: "EHLO", code: reply.code, text: reply.firstLine) }
            throw SMTPSubmitError.protocolError("EHLO refusé (\(reply.code) \(reply.firstLine)).")
        }
        return SMTPExtension.parse(ehlo: reply)
    }

    /// AUTH PLAIN (préféré) ou LOGIN ; renvoie le mécanisme utilisé.
    private static func authenticate(_ session: Session, extensions: [SMTPExtension], user: String,
                                     password: String) async throws -> String {
        guard session.transport.isEncrypted else { throw SMTPSubmitError.authRequiresEncryption }
        let offered = (extensions.first("AUTH")?.parameters ?? []).map { $0.uppercased() }
        func check(_ reply: SMTPReply) throws {
            guard reply.code == 235 else {
                if reply.isTransientFailure && reply.code != 454 {
                    throw SMTPSubmitError.temporaryFailure(stage: "AUTH", code: reply.code, text: reply.firstLine)
                }
                throw SMTPSubmitError.authFailed(code: reply.code, text: reply.firstLine)
            }
        }
        if offered.contains("PLAIN") {
            let token = Data(([0] + Array(user.utf8) + [0] + Array(password.utf8))).base64EncodedString()
            let reply = try await session.command("AUTH PLAIN \(token)", stage: "AUTH", masked: "AUTH PLAIN \(mask)")
            try check(reply)
            return "PLAIN"
        }
        if offered.contains("LOGIN") {
            let first = try await session.command("AUTH LOGIN", stage: "AUTH")
            guard first.code == 334 else { try check(first); return "LOGIN" }
            let second = try await session.command(Data(user.utf8).base64EncodedString(), stage: "AUTH", masked: mask)
            guard second.code == 334 else { try check(second); return "LOGIN" }
            let third = try await session.command(Data(password.utf8).base64EncodedString(), stage: "AUTH", masked: mask)
            try check(third)
            return "LOGIN"
        }
        throw SMTPSubmitError.authUnavailable(offered: offered)
    }

    /// RCPT refusé : relais refusé (5.7.1, « relay ») ou destinataire inconnu.
    static func classifyRecipient(address: String, reply: SMTPReply, authenticated: Bool) -> SMTPSubmitError {
        let text = reply.lines.joined(separator: " ")
        let lowered = text.lowercased()
        if reply.code == 530 { return .authRequired(code: reply.code, text: reply.firstLine) }
        if reply.isTransientFailure {
            return .temporaryFailure(stage: "RCPT TO", code: reply.code, text: reply.firstLine)
        }
        if lowered.contains("relay") || lowered.contains("relais") || text.contains("5.7.1") || text.contains("5.7.54")
            || (reply.code == 554 && !authenticated) {
            return .relayDenied(address: address, code: reply.code, text: reply.firstLine)
        }
        return .recipientRejected(address: address, code: reply.code, text: reply.firstLine)
    }

    private static func politeQuit(transport: SMTPSubmitTransport, log: SMTPSubmitLog) async {
        guard log.isOpen else { return }
        do {
            try await transport.write(Array("QUIT\r\n".utf8))
            log.client("QUIT")
            if let reply = try? await transport.readReply(timeout: 2) { log.server(reply) }
        } catch {}
    }

    /// Une session : commandes et lectures avec délai, tout passe par l'échange masqué.
    final class Session: @unchecked Sendable {
        let transport: SMTPSubmitTransport
        let log: SMTPSubmitLog
        let timeout: TimeInterval

        init(transport: SMTPSubmitTransport, log: SMTPSubmitLog, timeout: TimeInterval) {
            self.transport = transport
            self.log = log
            self.timeout = timeout
        }

        func read(_ stage: String, timeout: TimeInterval? = nil) async throws -> SMTPReply {
            do {
                let reply = try await transport.readReply(timeout: timeout ?? self.timeout)
                log.server(reply)
                return reply
            } catch let error as SMTPSubmitError {
                if case .connectionClosed = error { log.isOpen = false }
                throw Self.staged(error, stage)
            }
        }

        func command(_ line: String, stage: String, masked: String? = nil, timeout: TimeInterval? = nil) async throws -> SMTPReply {
            // Aucune commande ne peut contenir de saut de ligne (injection de commandes).
            guard !line.contains("\r"), !line.contains("\n") else { throw SMTPSubmitError.protocolError("commande invalide.") }
            log.client(masked ?? line)
            try await transport.write(Array((line + "\r\n").utf8))
            return try await read(stage, timeout: timeout)
        }

        static func staged(_ error: SMTPSubmitError, _ stage: String) -> SMTPSubmitError {
            switch error {
            case .timeout(let text) where text.isEmpty: return .timeout(stage)
            case .connectionClosed(let text) where text.isEmpty: return .connectionClosed(stage)
            default: return error
            }
        }
    }
}

/// Échange de la session (identifiants déjà masqués à l'écriture).
final class SMTPSubmitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private var open = false

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var isOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return open }
        set { lock.lock(); open = newValue; lock.unlock() }
    }

    private func append(_ line: String) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }

    func client(_ text: String) { append("C: " + text) }
    func server(_ reply: SMTPReply) { for line in reply.rawLines { append("S: " + line) } }
    func note(_ text: String) { append("-- " + text) }
}

extension SMTPReply {
    /// Toutes les lignes réunies (recherche de codes détaillés « 5.7.1 »).
    var text: String { lines.joined(separator: " ") }
}
