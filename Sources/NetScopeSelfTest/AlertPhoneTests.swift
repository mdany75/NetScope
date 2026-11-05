import Foundation
import NetScopeCore

// Note 76 (0.28.0) : alertes sur téléphone par ntfy et Pushover. Construction des requêtes
// (adresse, en-têtes, corps JSON ou formulaire, échappement, priorité selon la gravité), filtre
// propre au canal (gravité, sites) et envoi par un faux client HTTP. AUCUNE requête réelle :
// ni ntfy.sh ni api.pushover.net ne sont contactés.

private let phoneDate = Date(timeIntervalSince1970: 1_793_818_980) // 4 nov. 2026, 19:03 UTC
private let phoneContext = AlertContext(origin: "MacBook de Dany", version: "0.28.0", timeZone: TimeZone(identifier: "UTC")!)
private let pushoverToken = "azGDORePK8gMaC0QOYAMyEEuzJnyUi"
private let pushoverUser = "uQiRzpo4DXghDmr9QzzfQu27cmVRsG"

private func phoneEvent(_ kind: AlertEventKind = .probeDown, severity: AlertSeverity? = nil, site: UUID? = nil,
                        title: String = "Caméra-Quai hors ligne") -> AlertEvent {
    AlertEvent(kind: kind, severity: severity, title: title,
               message: "Aucune réponse après 3 tentatives (réseau « entrepôt »).\nVérifiez l’alimentation PoE & le port.",
               subject: "camera", occurredAt: phoneDate,
               details: [AlertDetail("Cible", "192.168.50.21"), AlertDetail("Sonde", "Ping (ICMP)")], siteID: site)
}

private func ntfySettings() -> AlertNtfySettings {
    var ntfy = AlertNtfySettings()
    ntfy.isEnabled = true
    ntfy.topic = "netscope-siege-k7m2q9"
    ntfy.tags = ["siege", "réseau"]
    return ntfy
}

private final class PhoneFakeHTTP: AlertHTTPClient, @unchecked Sendable {
    struct Request {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private let status: Int
    private let body: String
    private let error: Error?
    private var stored: [Request] = []

    init(status: Int = 200, body: String = "", error: Error? = nil) {
        self.status = status
        self.body = body
        self.error = error
    }

    var requests: [Request] { lock.withLock { stored } }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        lock.withLock { stored.append(Request(url: url, headers: headers, body: body)) }
        if let error { throw error }
        return (status, Data(self.body.utf8))
    }
}

/// Champs d'un corps application/x-www-form-urlencoded, décodés.
private func formFields(_ data: Data) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        fields[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
    }
    return fields
}

func registerAlertPhoneTests(_ suite: TestSuite) {
    suite.add("Téléphone : canaux ntfy et Pushover désactivés par défaut, anciens réglages relus") {
        let settings = AlertSettings()
        try expect(!settings.ntfy.isEnabled && !settings.pushover.isEnabled, "désactivés par défaut")
        try expectEqual(settings.ntfy.server, "https://ntfy.sh", "ntfy.sh par défaut")
        try expect(!settings.enabledChannels.contains(.ntfy) && !settings.enabledChannels.contains(.pushover), "aucun canal")
        // Réglages écrits par la 0.27 (sans ntfy ni Pushover) : relus sans perte, canaux coupés.
        let old = #"{"isEnabled":true,"smtp":{"isEnabled":true,"host":"smtp.exemple.ca"},"webhooks":[]}"#
        let decoded = try JSONDecoder().decode(AlertSettings.self, from: Data(old.utf8))
        try expect(decoded.isEnabled && decoded.smtp.isEnabled, "anciens réglages gardés")
        try expect(!decoded.ntfy.isEnabled && !decoded.pushover.isEnabled, "nouveaux canaux coupés")
        // Aller-retour et priorités hors bornes ramenées dans l'intervalle du service.
        var full = AlertSettings()
        full.ntfy = ntfySettings()
        full.pushover.isEnabled = true
        full.pushover.sound = "siren"
        full.pushover.filter = AlertChannelFilter(minimumSeverity: .critical, siteIDs: [UUID()])
        let back = try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(full))
        try expectEqual(back, full, "aller-retour JSON")
        let wild = #"{"ntfy":{"priorities":{"info":0,"warning":9,"critical":5}},"pushover":{"priorities":{"info":-7,"warning":0,"critical":3}}}"#
        let clamped = try JSONDecoder().decode(AlertSettings.self, from: Data(wild.utf8))
        try expectEqual(clamped.ntfy.priorities, AlertPriorityMap(info: 1, warning: 5, critical: 5), "priorités ntfy bornées")
        try expectEqual(clamped.pushover.priorities, AlertPriorityMap(info: -2, warning: 0, critical: 2), "priorités Pushover bornées")
        // Aucun secret dans les réglages enregistrés.
        let json = String(decoding: try JSONEncoder().encode(full), as: UTF8.self)
        try expect(!json.contains("token") && !json.contains("jeton"), "aucun secret dans les réglages : \(json)")
    }

    suite.add("Téléphone : requête ntfy en JSON (UTF-8, échappement, priorité, étiquettes, jeton)") {
        let batch = AlertBatch(events: [phoneEvent()], createdAt: phoneDate)
        let request = try AlertNtfyRequest.make(batch, settings: ntfySettings(), token: "tk_AgQdq7mVBoFD37zQVN29RhuMzNIz2", context: phoneContext)
        try expectEqual(request.url.absoluteString, "https://ntfy.sh/", "publication à la racine du serveur")
        try expectEqual(request.headers["Content-Type"], "application/json; charset=utf-8", "type JSON")
        try expectEqual(request.headers["Authorization"], "Bearer tk_AgQdq7mVBoFD37zQVN29RhuMzNIz2", "jeton en Bearer")
        try expectEqual(request.headers["User-Agent"], "NetScope/0.28.0", "agent")
        try expect(request.headers.values.allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) }, "en-têtes en ASCII")
        let payload = try JSONDecoder().decode(AlertNtfyRequest.Payload.self, from: request.body)
        try expectEqual(payload.topic, "netscope-siege-k7m2q9", "sujet")
        try expectEqual(payload.title, "Caméra-Quai hors ligne", "titre UTF-8 exact")
        try expectEqual(payload.priority, 5, "critique → 5")
        try expectEqual(payload.tags, ["rotating_light", "siege", "réseau"], "émoji de gravité puis étiquettes")
        try expect(payload.message.hasPrefix("Aucune réponse après 3 tentatives (réseau « entrepôt »).\nVérifiez"), "message : \(payload.message)")
        try expect(payload.message.contains("Cible\u{00A0}: 192.168.50.21"), "précisions")
        try expect(payload.message.contains("Critique · 4 nov. 2026 à 19:03 · MacBook de Dany"), "gravité, date et origine")
        let raw = String(decoding: request.body, as: UTF8.self)
        try expect(raw.contains("Caméra") && !raw.contains("\\u00e9"), "accents en UTF-8, non échappés")
        try expect(raw.contains("\\n") && !raw.contains("\n"), "retour à la ligne échappé dans le JSON")
        try expect(raw.hasPrefix("{\"message\":"), "clés triées (sortie stable)")

        // Priorités selon la gravité, et essai toujours en priorité normale.
        var settings = ntfySettings()
        settings.severityEmoji = false
        settings.tags = ["ok", "mauvaise,étiquette", ""]
        for (severity, expected) in [(AlertSeverity.info, 3), (.warning, 4), (.critical, 5)] {
            let one = AlertBatch(events: [phoneEvent(severity: severity)], createdAt: phoneDate)
            let p = AlertNtfyRequest.payload(one, settings: settings, context: phoneContext)
            try expectEqual(p.priority, expected, "priorité \(severity)")
            try expectEqual(p.tags, ["ok"], "étiquette invalide ignorée, sans émoji")
        }
        settings.priorities = AlertPriorityMap(info: 1, warning: 2, critical: 4)
        try expectEqual(AlertNtfyRequest.payload(batch, settings: settings, context: phoneContext).priority, 4, "priorité réglée")
        let test = AlertBatch.test(now: phoneDate, origin: "MacBook de Dany")
        let testPayload = AlertNtfyRequest.payload(test, settings: ntfySettings(), context: phoneContext)
        try expectEqual(testPayload.priority, 3, "essai en priorité normale")
        try expectEqual(testPayload.tags.first, "white_check_mark", "émoji d'essai")

        // Authentification : sans jeton, Basic gardé tel quel, retour à la ligne neutralisé.
        let anonymous = try AlertNtfyRequest.make(batch, settings: ntfySettings(), token: nil, context: phoneContext)
        try expect(anonymous.headers["Authorization"] == nil, "sans jeton : aucun en-tête")
        try expectEqual(AlertNtfyRequest.authorization("Basic ZGFueTpzZWNyZXQ="), "Basic ZGFueTpzZWNyZXQ=", "Basic tel quel")
        try expectEqual(AlertNtfyRequest.authorization("tk_abc\r\nX-Injecte: 1"), "Bearer tk_abc X-Injecte: 1", "aucune injection d'en-tête")
        try expect(AlertNtfyRequest.authorization("   ") == nil, "jeton vide")

        // Lot de plusieurs événements : titre et liste.
        let many = AlertBatch(events: [phoneEvent(), phoneEvent(.probeWarning, severity: .warning, title: "Latence élevée")],
                              suppressedCount: 2, createdAt: phoneDate)
        let manyPayload = AlertNtfyRequest.payload(many, settings: ntfySettings(), context: phoneContext)
        try expectEqual(manyPayload.title, "2 alertes NetScope", "titre du lot")
        try expect(manyPayload.message.contains("• [Alerte] Latence élevée — 19:03:00"), "liste : \(manyPayload.message)")
        try expect(manyPayload.message.contains("2 répétitions regroupées"), "anti-rafale rappelé")
    }

    suite.add("Téléphone : serveur et sujet ntfy validés (https, auto-hébergé, sous-dossier)") {
        try expectEqual(try AlertNtfyRequest.endpoint(server: "https://ntfy.exemple.ca").absoluteString, "https://ntfy.exemple.ca/", "auto-hébergé")
        try expectEqual(try AlertNtfyRequest.endpoint(server: " https://exemple.ca/ntfy ").absoluteString, "https://exemple.ca/ntfy/", "sous-dossier")
        try expectEqual(try AlertNtfyRequest.endpoint(server: "HTTPS://ntfy.sh/").absoluteString, "https://ntfy.sh/", "schéma en minuscules")
        try expectEqual(try AlertNtfyRequest.endpoint(server: "http://127.0.0.1:8080").absoluteString, "http://127.0.0.1:8080/", "http vers ce Mac")
        try expectThrows(AlertPhoneError.insecureServer, "http refusé hors de ce Mac") { _ = try AlertNtfyRequest.endpoint(server: "http://192.168.1.10") }
        try expectThrows(AlertPhoneError.invalidServer, "requête refusée") { _ = try AlertNtfyRequest.endpoint(server: "https://ntfy.sh/?x=1") }
        try expectThrows(AlertPhoneError.invalidServer, "identifiants dans l'adresse refusés") { _ = try AlertNtfyRequest.endpoint(server: "https://a:b@ntfy.sh") }
        try expectThrows(AlertPhoneError.invalidServer, "ftp refusé") { _ = try AlertNtfyRequest.endpoint(server: "ftp://ntfy.sh") }
        try expect(AlertNtfySettings.isValidTopic("netscope_Siege-01"), "sujet valide")
        try expect(!AlertNtfySettings.isValidTopic("sujet accentué") && !AlertNtfySettings.isValidTopic("a/b")
                   && !AlertNtfySettings.isValidTopic(String(repeating: "a", count: 65)), "sujets invalides")
        let random = AlertNtfySettings.randomTopic()
        try expect(random.hasPrefix("netscope-") && random.count == 25 && AlertNtfySettings.isValidTopic(random), "sujet généré : \(random)")
        try expect(random != AlertNtfySettings.randomTopic(), "sujets différents")
        var settings = ntfySettings()
        try expect(settings.problems().isEmpty, "prêt")
        try expect(settings.isPublicServer, "ntfy.sh est public")
        settings.topic = "é"
        try expect(settings.problems().contains { $0.hasPrefix("Sujet invalide") }, "sujet invalide signalé")
        try expectThrows(AlertPhoneError.invalidTopic, "sujet invalide refusé à l'envoi") {
            _ = try AlertNtfyRequest.make(AlertBatch(events: [phoneEvent()], createdAt: phoneDate), settings: settings, token: nil, context: phoneContext)
        }
        try expectEqual(AlertNtfySettings.parseTags("siege, réseau ; Siege,,urgent"), ["siege", "réseau", "urgent"], "étiquettes sans doublon")
    }

    suite.add("Téléphone : requête Pushover (formulaire UTF-8, échappement, priorité, urgence, son, appareil)") {
        var settings = AlertPushoverSettings()
        settings.isEnabled = true
        settings.sound = "siren"
        settings.device = " iphone-dany , ipad "
        let batch = AlertBatch(events: [phoneEvent(title: "Q&A = 100 % + test")], createdAt: phoneDate)
        let request = try AlertPushoverRequest.make(batch, settings: settings, token: pushoverToken, userKey: pushoverUser, context: phoneContext)
        try expectEqual(request.url.absoluteString, "https://api.pushover.net/1/messages.json", "adresse de l'API")
        try expectEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded; charset=utf-8", "formulaire")
        let raw = String(decoding: request.body, as: UTF8.self)
        try expect(raw.hasPrefix("token=\(pushoverToken)&user=\(pushoverUser)&title="), "jeton et clé en premier : \(raw.prefix(80))")
        try expect(raw.unicodeScalars.allSatisfy { $0.isASCII }, "corps encodé en ASCII")
        try expect(raw.contains("title=Q%26A%20%3D%20100%20%25%20%2B%20test"), "& = % + et espace échappés")
        try expect(!raw.contains("\n") && raw.contains("%0A"), "retour à la ligne échappé")
        let fields = formFields(request.body)
        try expectEqual(fields["title"], "Q&A = 100 % + test", "titre relu à l'identique")
        try expect(fields["message"]?.hasPrefix("Aucune réponse après 3 tentatives (réseau « entrepôt »).\nVérifiez l’alimentation PoE & le port.") == true,
                   "message UTF-8 relu : \(fields["message"] ?? "")")
        try expectEqual(fields["priority"], "1", "critique → 1 (haute)")
        try expectEqual(fields["sound"], "siren", "son")
        try expectEqual(fields["device"], "iphone-dany,ipad", "appareils normalisés")
        try expectEqual(fields["timestamp"], "1793818980", "horodatage de l'événement")
        try expect(fields["retry"] == nil && fields["expire"] == nil, "pas d'urgence")

        for (severity, expected) in [(AlertSeverity.info, "-1"), (.warning, "0"), (.critical, "1")] {
            let one = AlertBatch(events: [phoneEvent(severity: severity)], createdAt: phoneDate)
            let f = Dictionary(AlertPushoverRequest.fields(one, settings: settings, token: "t", userKey: "u", context: phoneContext),
                               uniquingKeysWith: { a, _ in a })
            try expectEqual(f["priority"], expected, "priorité \(severity)")
        }
        // Urgence : retry et expire obligatoires pour l'API.
        settings.priorities.critical = 2
        let emergency = formFields(try AlertPushoverRequest.make(batch, settings: settings, token: pushoverToken, userKey: pushoverUser,
                                                                 context: phoneContext).body)
        try expectEqual(emergency["priority"], "2", "urgence")
        try expectEqual(emergency["retry"], "60", "rappel toutes les 60 s")
        try expectEqual(emergency["expire"], "3600", "pendant une heure")
        // Essai : priorité normale, jamais d'urgence.
        let test = formFields(try AlertPushoverRequest.make(.test(now: phoneDate, origin: "Mac"), settings: settings, token: pushoverToken,
                                                            userKey: pushoverUser, context: phoneContext).body)
        try expectEqual(test["priority"], "0", "essai en priorité normale")
        // Son et appareil invalides ignorés ; clés manquantes ou malformées refusées avant tout envoi.
        settings.sound = "inconnu"
        settings.device = "mauvais appareil!"
        let ignored = formFields(try AlertPushoverRequest.make(batch, settings: settings, token: pushoverToken, userKey: pushoverUser,
                                                               context: phoneContext).body)
        try expect(ignored["sound"] == nil && ignored["device"] == nil, "son et appareil invalides ignorés")
        try expect(settings.problems(hasToken: true, hasUserKey: true).count == 2, "problèmes signalés")
        try expectThrows(AlertPhoneError.missingToken, "jeton manquant") {
            _ = try AlertPushoverRequest.make(batch, settings: settings, token: nil, userKey: pushoverUser, context: phoneContext)
        }
        try expectThrows(AlertPhoneError.missingUserKey, "clé manquante") {
            _ = try AlertPushoverRequest.make(batch, settings: settings, token: pushoverToken, userKey: " ", context: phoneContext)
        }
        try expectThrows(AlertPhoneError.invalidCredential("Clé utilisateur"), "clé malformée") {
            _ = try AlertPushoverRequest.make(batch, settings: settings, token: pushoverToken, userKey: "court", context: phoneContext)
        }
        // Limites de l'API : titre 250, message 1 024 caractères.
        let long = AlertEvent(kind: .probeDown, title: String(repeating: "T", count: 400), message: String(repeating: "é", count: 3_000),
                              subject: "x", occurredAt: phoneDate)
        let cut = formFields(try AlertPushoverRequest.make(AlertBatch(events: [long], createdAt: phoneDate), settings: AlertPushoverSettings(),
                                                           token: pushoverToken, userKey: pushoverUser, context: phoneContext).body)
        try expectEqual(cut["title"]?.count, 250, "titre coupé")
        try expectEqual(cut["message"]?.count, 1_024, "message coupé")
        try expect(cut["message"]?.hasSuffix("…") == true, "points de suspension")
        let ntfyCut = AlertPhoneText.truncate(String(repeating: "é", count: 3_000), maxBytes: AlertNtfyRequest.maxMessageBytes)
        try expect(ntfyCut.utf8.count <= AlertNtfyRequest.maxMessageBytes && ntfyCut.hasSuffix("…"), "ntfy coupé en octets sans casser un caractère")
    }

    suite.add("Téléphone : filtre propre au canal (gravité minimale, sites, rétablissement, essai)") {
        let siege = UUID()
        let laval = UUID()
        let filter = AlertChannelFilter(minimumSeverity: .critical, siteIDs: [siege])
        try expect(filter.accepts(phoneEvent(severity: .critical, site: siege)), "critique du Siège")
        try expect(!filter.accepts(phoneEvent(.probeWarning, severity: .warning, site: siege)), "alerte sous le seuil")
        try expect(!filter.accepts(phoneEvent(severity: .critical, site: laval)), "autre site")
        try expect(filter.accepts(phoneEvent(.serviceIncident, severity: .critical, site: nil)), "sans site : passe")
        try expect(filter.accepts(phoneEvent(.probeRecovered, severity: .info, site: siege)), "rétablissement suit sa panne")
        try expect(filter.accepts(AlertBatch.test(now: phoneDate, origin: "Mac").events[0]), "essai toujours permis")

        let batch = AlertBatch(events: [phoneEvent(severity: .critical, site: siege), phoneEvent(.probeWarning, severity: .warning, site: siege),
                                        phoneEvent(severity: .critical, site: laval)], suppressedCount: 1, createdAt: phoneDate)
        let kept = try filter.apply(batch).unwrapPhone("lot filtré")
        try expectEqual(kept.events.count, 1, "un seul événement retenu")
        try expectEqual(kept.suppressedCount, 1, "répétitions gardées")
        try expect(AlertChannelFilter(minimumSeverity: .critical).apply(AlertBatch(events: [phoneEvent(.newDevice)], createdAt: phoneDate)) == nil,
                   "rien pour ce canal")

        var settings = AlertSettings()
        settings.isEnabled = true
        settings.smtp.isEnabled = true
        settings.ntfy = ntfySettings()
        settings.pushover.isEnabled = true
        settings.pushover.filter = filter
        try expectEqual(settings.enabledChannels, [.email, .ntfy, .pushover], "canaux activés")
        try expectEqual(settings.batch(batch, for: .email), batch, "courriel : lot entier")
        try expectEqual(settings.batch(batch, for: .pushover)?.events.count, 1, "Pushover : lot filtré")
        try expectEqual(settings.channelName(.ntfy), "ntfy · netscope-siege-k7m2q9", "nom du canal ntfy")
        let probe = UUID()
        try expectEqual(settings.channels(forProbe: probe, siteID: laval), [.email, .ntfy], "sonde de Laval : pas de Pushover")
        try expectEqual(settings.channels(forProbe: probe, siteID: siege), [.email, .ntfy, .pushover], "sonde du Siège")
        try expectEqual(settings.channels(forProbe: probe), [.email, .ntfy, .pushover], "site inconnu : tous")
    }

    suite.add("Téléphone : envoi ntfy et Pushover par un faux client, erreurs expliquées, journal sans secret") {
        var settings = AlertSettings()
        settings.isEnabled = true
        settings.ntfy = ntfySettings()
        settings.pushover.isEnabled = true
        let ntfyToken = "tk_jetonntfytressecret42"
        let secrets = AlertSecrets(ntfyToken: ntfyToken, pushoverToken: pushoverToken, pushoverUser: pushoverUser)
        let batch = AlertBatch(events: [phoneEvent()], createdAt: phoneDate)

        // ntfy : réussite, identifiant du message relu.
        let ok = PhoneFakeHTTP(status: 200, body: #"{"id":"sPs71M8A2T","time":1793818980,"event":"message","topic":"netscope-siege-k7m2q9"}"#)
        let sent = await AlertDelivery(context: phoneContext, http: ok).deliver(batch, on: .ntfy, settings: settings, secrets: secrets, now: phoneDate)
        try expectEqual(sent.outcome, .sent, "ntfy envoyé")
        try expectEqual(sent.detail, "HTTP 200 · message sPs71M8A2T · priorité 5", "détail ntfy")
        try expectEqual(sent.channelKind, "ntfy", "type de canal")
        try expectEqual(ok.requests.count, 1, "une requête")
        try expectEqual(ok.requests.first?.url.absoluteString, "https://ntfy.sh/", "adresse")

        // ntfy : refus 403, le service renvoie le jeton dans son message → masqué au journal.
        let denied = PhoneFakeHTTP(status: 403, body: #"{"code":40301,"http":403,"error":"forbidden for \#(ntfyToken)"}"#)
        let refused = await AlertDelivery(context: phoneContext, http: denied).deliver(batch, on: .ntfy, settings: settings, secrets: secrets, now: phoneDate)
        try expectEqual(refused.outcome, .failed, "ntfy refusé")
        try expect(refused.detail.hasPrefix("Accès refusé par ntfy (403)"), "erreur expliquée : \(refused.detail)")
        try expect(!refused.detail.contains(ntfyToken) && refused.detail.contains(AlertRedactor.mask), "jeton masqué : \(refused.detail)")

        let limited = PhoneFakeHTTP(status: 429, body: #"{"code":42901,"http":429,"error":"limit reached: too many requests"}"#)
        let slow = await AlertDelivery(context: phoneContext, http: limited).deliver(batch, on: .ntfy, settings: settings, secrets: secrets, now: phoneDate)
        try expect(slow.detail.contains("Trop de messages (429)") && slow.detail.contains("too many requests"), "429 expliqué : \(slow.detail)")

        // Réglages incomplets : rien n'est envoyé.
        var incomplete = settings
        incomplete.ntfy.topic = ""
        let none = PhoneFakeHTTP()
        let blocked = await AlertDelivery(context: phoneContext, http: none).deliver(batch, on: .ntfy, settings: incomplete, secrets: secrets, now: phoneDate)
        try expectEqual(blocked.outcome, .failed, "incomplet")
        try expect(blocked.detail.contains("Sujet à renseigner"), "raison : \(blocked.detail)")
        try expectEqual(none.requests.count, 0, "aucune requête")

        // Pushover : réussite.
        let pOK = PhoneFakeHTTP(status: 200, body: #"{"status":1,"request":"5042853c-402d-4a18-abcb-168734a801de"}"#)
        let pSent = await AlertDelivery(context: phoneContext, http: pOK).deliver(batch, on: .pushover, settings: settings, secrets: secrets, now: phoneDate)
        try expectEqual(pSent.outcome, .sent, "Pushover envoyé")
        try expectEqual(pSent.detail, "HTTP 200 · priorité 1 · demande 5042853c-402d-4a18-abcb-168734a801de", "détail Pushover")
        try expectEqual(pOK.requests.first?.url.host, "api.pushover.net", "hôte de l'API")

        // Pushover : clé refusée, renvoyée par l'API → masquée ; tout le journal encodé est propre.
        let pBad = PhoneFakeHTTP(status: 400, body: #"{"user":"\#(pushoverUser)","errors":["user identifier is not a valid user, group, or subscribed user key"],"status":0,"request":"abc"}"#)
        let pFailed = await AlertDelivery(context: phoneContext, http: pBad).deliver(batch, on: .pushover, settings: settings, secrets: secrets, now: phoneDate)
        try expectEqual(pFailed.outcome, .failed, "Pushover refusé")
        try expect(pFailed.detail.hasPrefix("Message refusé par Pushover (400)") && pFailed.detail.contains("not a valid user"), "erreur : \(pFailed.detail)")
        let journal = String(decoding: try JSONEncoder().encode([sent, refused, pSent, pFailed]), as: UTF8.self)
        try expect(!journal.contains(ntfyToken) && !journal.contains(pushoverToken) && !journal.contains(pushoverUser), "journal sans secret : \(journal)")

        // Statut 200 mais status 0 : échec quand même.
        let pZero = PhoneFakeHTTP(status: 200, body: #"{"status":0,"errors":["application token is invalid"]}"#)
        let zero = await AlertDelivery(context: phoneContext, http: pZero).deliver(batch, on: .pushover, settings: settings, secrets: secrets, now: phoneDate)
        try expect(zero.outcome == .failed && zero.detail.contains("application token is invalid"), "status 0 : \(zero.detail)")

        // Hors ligne, et clé absente du Trousseau (aucune requête).
        let offline = PhoneFakeHTTP(error: URLError(.notConnectedToInternet))
        let down = await AlertDelivery(context: phoneContext, http: offline).deliver(batch, on: .pushover, settings: settings, secrets: secrets, now: phoneDate)
        try expect(down.detail.contains("Pas de connexion Internet") && down.detail.contains("Pushover"), "hors ligne : \(down.detail)")
        let empty = PhoneFakeHTTP()
        let missing = await AlertDelivery(context: phoneContext, http: empty).deliver(batch, on: .pushover, settings: settings,
                                                                                         secrets: AlertSecrets(pushoverToken: pushoverToken), now: phoneDate)
        try expect(missing.outcome == .failed && missing.detail.contains("Clé utilisateur"), "clé absente : \(missing.detail)")
        try expectEqual(empty.requests.count, 0, "aucune requête sans clé")
    }
}

private extension Optional {
    func unwrapPhone(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}
