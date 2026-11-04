import Darwin
import Foundation
import NetScopeCore

// Tests des alertes par courriel et webhook (0.8.0) : construction des messages, dialogue SMTP
// avec un faux transport à réponses fixes et avec un faux serveur sur 127.0.0.1, cartes Teams,
// blocs Slack, JSON générique, anti-rafale et regroupement, journal sans secret.
// AUCUN courriel ni webhook réel n'est envoyé : tout passe par des faux.

private let fixedDate = Date(timeIntervalSince1970: 1_793_818_980) // 4 nov. 2026, 19:03 UTC
private let utc = TimeZone(identifier: "UTC")!
private let context = AlertContext(origin: "MacBook de Dany", version: "0.8.0", timeZone: utc)

private func sampleEvent(_ kind: AlertEventKind = .probeDown, subject: String = "camera", severity: AlertSeverity? = nil,
                         at date: Date = fixedDate, probe: UUID? = nil) -> AlertEvent {
    AlertEvent(kind: kind, severity: severity, title: "Caméra-Quai hors ligne", message: "Aucune réponse après 3 tentatives (réseau « entrepôt »).",
               subject: subject, occurredAt: date, details: [AlertDetail("Cible", "192.168.50.21"), AlertDetail("Sonde", "Ping (ICMP)")],
               probeID: probe)
}

private func smtpSettings(security: AlertSMTPSecurity = .startTLS, user: String = "alertes@exemple.ca") -> AlertSMTPSettings {
    var smtp = AlertSMTPSettings()
    smtp.isEnabled = true
    smtp.host = "smtp.exemple.ca"
    smtp.port = security.defaultPort
    smtp.security = security
    smtp.username = user
    smtp.from = "alertes@exemple.ca"
    smtp.fromName = "NetScope · Entrepôt"
    smtp.recipients = ["dany@exemple.ca", "tech@exemple.ca"]
    return smtp
}

func registerAlertTests(_ suite: TestSuite) {
    // MARK: Message

    suite.add("Alertes : courriel UTF-8 (en-têtes, sujet encodé, quoted-printable)") {
        let batch = AlertBatch(events: [sampleEvent()], createdAt: fixedDate)
        var smtp = smtpSettings()
        smtp.encoding = .quotedPrintable
        var message = AlertComposer.mail(batch, smtp: smtp, context: context, now: fixedDate)
        message.messageID = "<essai@exemple.ca>"
        let raw = message.rendered(boundary: "LIMITE", timeZone: utc)
        let lines = raw.components(separatedBy: "\r\n")
        try expect(raw.unicodeScalars.allSatisfy { $0.isASCII }, "message entièrement en 7 bits")
        try expect(!raw.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "aucun LF isolé")
        try expect(lines.allSatisfy { $0.count <= 78 }, "lignes de 78 caractères au plus : \(lines.filter { $0.count > 78 })")
        try expect(lines.contains("Date: Wed, 4 Nov 2026 19:03:00 +0000"), "Date RFC 5322")
        try expect(lines.contains("Message-ID: <essai@exemple.ca>"), "Message-ID")
        try expect(lines.contains("MIME-Version: 1.0"), "MIME-Version")
        try expect(lines.contains("Auto-Submitted: auto-generated"), "message automatique")
        try expect(lines.contains("Content-Type: multipart/alternative; boundary=\"LIMITE\""), "multipart")
        try expect(lines.filter { $0 == "Content-Transfer-Encoding: quoted-printable" }.count == 2, "deux parties en QP")
        try expect(lines.contains("--LIMITE--"), "fin du multipart")
        try expect(lines.contains("To: dany@exemple.ca, tech@exemple.ca"), "destinataires")
        // Sujet : mots encodés UTF-8 qui redonnent le texte exact.
        let subjectLines = lines.drop(while: { !$0.hasPrefix("Subject: ") }).prefix { $0.hasPrefix("Subject: ") || $0.hasPrefix(" ") }
        let words = subjectLines.joined(separator: " ").replacingOccurrences(of: "Subject: ", with: "")
            .split(separator: " ").map(String.init)
        try expect(words.allSatisfy { $0.hasPrefix("=?UTF-8?B?") && $0.hasSuffix("?=") }, "sujet en mots encodés")
        let decoded = words.map { word -> String in
            let base = String(word.dropFirst(10).dropLast(2))
            return String(decoding: Data(base64Encoded: base) ?? Data(), as: UTF8.self)
        }.joined()
        try expectEqual(decoded, "[NetScope] Critique · Caméra-Quai hors ligne", "sujet décodé")
        // Nom de l'expéditeur avec accent : encodé.
        try expect(lines.first { $0.hasPrefix("From: ") }?.hasPrefix("From: =?UTF-8?B?") == true, "nom encodé")
        try expect(lines.first { $0.hasPrefix("From: ") }?.hasSuffix(" <alertes@exemple.ca>") == true, "adresse de l’expéditeur")
        // Corps QP : accents en =C3=A9, décodage fidèle.
        try expect(raw.contains("Cam=C3=A9ra-Quai"), "accent encodé en QP")
        try expectEqual(QuotedPrintable.decode(QuotedPrintable.encode(AlertComposer.text(batch, context: context))),
                        MIMEHeader.normalizeNewlines(AlertComposer.text(batch, context: context)), "aller-retour QP")
    }

    suite.add("Alertes : quoted-printable (coupures douces, « = », espaces de fin, point initial)") {
        let long = String(repeating: "é", count: 60) + " fin"
        let encoded = QuotedPrintable.encode(long)
        try expect(encoded.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 }, "76 caractères au plus")
        try expect(encoded.contains("=\r\n"), "coupure douce")
        try expect(!encoded.components(separatedBy: "\r\n").contains { $0.hasSuffix("=C") || $0.hasSuffix("=") && $0.dropLast().hasSuffix("=") },
                   "aucun =XX coupé")
        try expectEqual(QuotedPrintable.decode(encoded), long, "aller-retour")
        try expectEqual(QuotedPrintable.encode("a=b"), "a=3Db", "signe égal")
        try expectEqual(QuotedPrintable.encode("fin \nsuite\t"), "fin=20\r\nsuite=09", "espaces de fin de ligne")
        try expectEqual(QuotedPrintable.encode(".point"), "=2Epoint", "point en début de ligne")
    }

    suite.add("Alertes : courriel en base64 et texte seul") {
        var message = AlertMailMessage(from: "a@exemple.ca", to: ["b@exemple.ca"], subject: "Essai simple",
                                       textBody: "Bonjour, ceci est un essai : déjà vu.\nDeuxième ligne", date: fixedDate,
                                       messageID: "<x@exemple.ca>", encoding: .base64)
        message.mailer = "NetScope 0.8.0"
        let raw = message.rendered(timeZone: utc)
        try expect(raw.contains("Subject: Essai simple\r\n"), "sujet ASCII tel quel")
        try expect(raw.contains("Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n"), "en-têtes base64")
        let body = raw.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        let data = Data(base64Encoded: body.replacingOccurrences(of: "\r\n", with: "")) ?? Data()
        try expectEqual(String(decoding: data, as: UTF8.self), "Bonjour, ceci est un essai : déjà vu.\r\nDeuxième ligne", "corps décodé")
        try expect(MIMEHeader.mailbox(name: "Alertes, réseau", address: "a@b.ca").hasPrefix("=?UTF-8?B?"), "nom accentué encodé")
        try expectEqual(MIMEHeader.mailbox(name: "Alertes, NetScope", address: "a@b.ca"), "\"Alertes, NetScope\" <a@b.ca>", "nom ASCII entre guillemets")
    }

    suite.add("Alertes : point doublé et fin de DATA") {
        let payload = String(decoding: SMTPDotStuffing.dataPayload("Sujet\n.cache\n..deux\nfin"), as: UTF8.self)
        try expectEqual(payload, "Sujet\r\n..cache\r\n...deux\r\nfin\r\n.\r\n", "points doublés et fin")
        let already = String(decoding: SMTPDotStuffing.dataPayload("a\r\n"), as: UTF8.self)
        try expectEqual(already, "a\r\n.\r\n", "CRLF final non dupliqué")
    }

    suite.add("Alertes : aucune injection d’en-tête par un titre ou un nom") {
        let message = AlertMailMessage(from: "a@exemple.ca", fromName: "X\r\nBcc: pirate@x.ca", to: ["b@exemple.ca"],
                                       subject: "Panne\r\nBcc: pirate@x.ca", textBody: "corps", date: fixedDate, messageID: "<m@x>")
        let raw = message.rendered(timeZone: utc)
        try expect(!raw.components(separatedBy: "\r\n").contains { $0.hasPrefix("Bcc:") }, "aucune ligne Bcc")
        try expect(!AlertAddress.isValid("a@b.ca>\r\nRCPT TO:<x@y.ca"), "adresse avec saut de ligne refusée")
        try expect(AlertAddress.isValid("alertes+netscope@exemple.ca"), "adresse avec +")
        try expect(!AlertAddress.isValid("dany@exemple"), "domaine sans point")
        try expectEqual(AlertAddress.parseList("a@x.ca, b@y.ca; A@x.ca\nc@z.ca"), ["a@x.ca", "b@y.ca", "c@z.ca"], "liste de destinataires")
    }

    // MARK: Dialogue SMTP (faux transport)

    suite.add("Alertes : dialogue SMTP complet (STARTTLS, AUTH PLAIN, deux destinataires, DATA)") {
        let transport = ScriptedSMTP(script: ScriptedSMTP.standard(auth: "AUTH PLAIN LOGIN"))
        let batch = AlertBatch(events: [sampleEvent()], createdAt: fixedDate)
        let message = AlertComposer.mail(batch, smtp: smtpSettings(), context: context, now: fixedDate)
        let config = SMTPSubmitConfig(host: "smtp.exemple.ca", port: 587, security: .startTLS, username: "alertes@exemple.ca",
                                      password: "Mot-De-Passe-Secret!", ehloName: "[10.0.0.5]", timeout: 2)
        let outcome = await SMTPSubmission.send(message, config: config, transport: transport)
        try expect(outcome.succeeded, "envoi réussi : \(outcome.error?.errorDescription ?? "") \(outcome.transcript)")
        try expect(outcome.encrypted, "session chiffrée")
        try expectEqual(outcome.authMechanism, "PLAIN", "AUTH PLAIN")
        try expectEqual(outcome.acceptedRecipients, ["dany@exemple.ca", "tech@exemple.ca"], "destinataires acceptés")
        try expectEqual(outcome.queueReply, "250 2.0.0 Ok: queued as 4F2A", "accusé de réception")
        let verbs = transport.commands.map { String($0.split(separator: " ").first ?? "") }
        try expectEqual(verbs, ["EHLO", "STARTTLS", "EHLO", "AUTH", "MAIL", "RCPT", "RCPT", "DATA", "QUIT"], "ordre des commandes")
        try expectEqual(transport.commands[0], "EHLO [10.0.0.5]", "nom EHLO")
        try expect(transport.upgradedBeforeAuth, "TLS avant l’authentification")
        let expectedToken = Data(([0] + Array("alertes@exemple.ca".utf8) + [0] + Array("Mot-De-Passe-Secret!".utf8))).base64EncodedString()
        try expectEqual(transport.commands[3], "AUTH PLAIN \(expectedToken)", "jeton PLAIN")
        try expectEqual(transport.commands[4], "MAIL FROM:<alertes@exemple.ca>", "MAIL FROM")
        try expect(transport.payload.hasSuffix("\r\n.\r\n"), "fin de DATA")
        try expect(transport.payload.contains("Subject: =?UTF-8?B?"), "en-têtes dans DATA")
        // L'échange ne contient ni le mot de passe ni le jeton.
        let transcript = outcome.transcript.joined(separator: "\n")
        try expect(!transcript.contains("Mot-De-Passe-Secret!") && !transcript.contains(expectedToken), "échange sans secret")
        try expect(transcript.contains("C: AUTH PLAIN ••••••••"), "AUTH masqué")
        try expect(transcript.contains("S: 250-STARTTLS"), "réponses multi-lignes gardées")
    }

    suite.add("Alertes : AUTH LOGIN et TLS implicite (465)") {
        let transport = ScriptedSMTP(script: ScriptedSMTP.standard(auth: "AUTH LOGIN", startTLS: false), encryptedAtOpen: true)
        let message = AlertMailMessage(from: "a@exemple.ca", to: ["b@exemple.ca"], subject: "s", textBody: "t", date: fixedDate)
        let config = SMTPSubmitConfig(host: "smtp.exemple.ca", port: 465, security: .implicitTLS, username: "compte", password: "pw-123", timeout: 2)
        let outcome = await SMTPSubmission.send(message, config: config, transport: transport)
        try expect(outcome.succeeded, "envoi réussi : \(outcome.error?.errorDescription ?? "") \(outcome.transcript)")
        try expectEqual(outcome.authMechanism, "LOGIN", "AUTH LOGIN")
        try expectEqual(Array(transport.commands.prefix(4)), ["EHLO [127.0.0.1]", "AUTH LOGIN", Data("compte".utf8).base64EncodedString(),
                                                               Data("pw-123".utf8).base64EncodedString()], "étapes LOGIN")
        try expect(!transport.commands.contains("STARTTLS"), "pas de STARTTLS en TLS implicite")
        try expect(!outcome.transcript.joined().contains(Data("pw-123".utf8).base64EncodedString()), "mot de passe base64 masqué")
    }

    suite.add("Alertes : erreurs SMTP expliquées (authentification, relais, STARTTLS, OAuth, port)") {
        let message = AlertMailMessage(from: "a@exemple.ca", to: ["b@ailleurs.ca"], subject: "s", textBody: "t", date: fixedDate)
        let auth = SMTPSubmitConfig(host: "smtp.exemple.ca", port: 587, security: .startTLS, username: "u", password: "p", timeout: 2)

        var script = ScriptedSMTP.standard(auth: "AUTH PLAIN")
        script["AUTH"] = ["535 5.7.8 Error: authentication failed"]
        let refused = await SMTPSubmission.send(message, config: auth, transport: ScriptedSMTP(script: script))
        try expectEqual(refused.error, .authFailed(code: 535, text: "5.7.8 Error: authentication failed"), "authentification refusée")
        try expect(refused.error?.errorDescription?.contains("mot de passe d’application") == true, "conseil en français")

        script = ScriptedSMTP.standard(auth: "AUTH PLAIN")
        script["RCPT"] = ["554 5.7.1 <b@ailleurs.ca>: Relay access denied"]
        let relay = await SMTPSubmission.send(message, config: auth, transport: ScriptedSMTP(script: script))
        try expectEqual(relay.error?.shortLabel, "Relais refusé", "relais refusé")
        try expect(relay.error?.errorDescription?.contains("b@ailleurs.ca") == true, "adresse citée")

        let noTLS = ScriptedSMTP(script: ScriptedSMTP.standard(auth: "AUTH PLAIN", startTLS: false))
        let plain = await SMTPSubmission.send(message, config: auth, transport: noTLS)
        try expectEqual(plain.error, .startTLSUnavailable, "STARTTLS absent")
        try expect(!noTLS.commands.contains { $0.hasPrefix("AUTH") || $0.hasPrefix("MAIL") }, "rien envoyé en clair")

        let oauth = await SMTPSubmission.send(message, config: auth, transport: ScriptedSMTP(script: ScriptedSMTP.standard(auth: "AUTH XOAUTH2")))
        try expect(oauth.error?.errorDescription?.contains("OAuth") == true, "OAuth seulement expliqué")

        let clear = SMTPSubmitConfig(host: "relais.local", port: 25, security: .none, username: "u", password: "p")
        let never = ScriptedSMTP(script: ScriptedSMTP.standard(auth: "AUTH PLAIN"))
        let refusedClear = await SMTPSubmission.send(message, config: clear, transport: never)
        try expectEqual(refusedClear.error, .authRequiresEncryption, "mot de passe jamais en clair")
        try expect(!never.opened, "aucune connexion ouverte")

        let blocked = ScriptedSMTP(script: [:], openError: .portBlocked(host: "smtp.exemple.ca", port: 25))
        let blockedOutcome = await SMTPSubmission.send(message, config: auth, transport: blocked)
        try expect(blockedOutcome.error?.errorDescription?.contains("bloqué") == true, "port bloqué expliqué")

        script = ScriptedSMTP.standard(auth: "AUTH PLAIN")
        script["MAIL"] = ["530 5.7.0 Authentication required"]
        let none = SMTPSubmitConfig(host: "smtp.exemple.ca", port: 587, security: .startTLS, timeout: 2)
        let required = await SMTPSubmission.send(message, config: none, transport: ScriptedSMTP(script: script))
        try expectEqual(required.error?.shortLabel, "Authentification exigée", "authentification exigée")
    }

    // MARK: Faux serveur sur 127.0.0.1 (transport réel)

    suite.add("Alertes : envoi réel vers un faux serveur SMTP sur 127.0.0.1 (relais sans chiffrement)") {
        let received = ToolTestBox<[String]>([])
        let server = try LocalTCPServer { fd in fakeSubmissionServer(fd, offerStartTLS: false, log: received) }
        defer { server.stop() }
        let message = AlertMailMessage(from: "alertes@exemple.ca", to: ["dany@exemple.ca"], subject: "Essai réseau local",
                                       textBody: "Première ligne\n.ligne avec point\nFin", date: fixedDate, encoding: .base64)
        let config = SMTPSubmitConfig(host: "127.0.0.1", port: server.port, security: .none, timeout: 3)
        let outcome = await SMTPSubmission.send(message, config: config,
                                                transport: SMTPNetworkTransport(host: "127.0.0.1", port: server.port, security: .none, connectTimeout: 3))
        try expect(outcome.succeeded, "envoi : \(outcome.error?.errorDescription ?? "")")
        let lines = received.value
        try expect(lines.contains("MAIL FROM:<alertes@exemple.ca>") && lines.contains("RCPT TO:<dany@exemple.ca>"), "enveloppe reçue")
        try expect(lines.contains("DATA") && lines.contains("QUIT"), "DATA et QUIT reçus")
        try expect(lines.contains { $0.hasPrefix("Subject: =?UTF-8?B?") }, "en-têtes reçus")
        try expectEqual(outcome.queueReply, "250 2.0.0 Ok: queued as LOCAL1", "accusé")
    }

    suite.add("Alertes : STARTTLS exigé mais absent du faux serveur 127.0.0.1 (partie en clair par le framer)") {
        let received = ToolTestBox<[String]>([])
        let server = try LocalTCPServer { fd in fakeSubmissionServer(fd, offerStartTLS: false, log: received) }
        defer { server.stop() }
        let message = AlertMailMessage(from: "alertes@exemple.ca", to: ["dany@exemple.ca"], subject: "s", textBody: "t", date: fixedDate)
        let config = SMTPSubmitConfig(host: "127.0.0.1", port: server.port, security: .startTLS, username: "u", password: "p", timeout: 3)
        let outcome = await SMTPSubmission.send(message, config: config,
                                                transport: SMTPNetworkTransport(host: "127.0.0.1", port: server.port, security: .startTLS, connectTimeout: 3))
        try expectEqual(outcome.error, .startTLSUnavailable, "STARTTLS absent")
        // Laisse le faux serveur lire le QUIT.
        try await Task.sleep(nanoseconds: 200_000_000)
        let verbs = received.value.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        try expectEqual(verbs, ["EHLO", "QUIT"], "EHLO puis QUIT, rien d’autre")
    }

    suite.add("Alertes : STARTTLS réel et certificat auto-signé refusé (serveur local fourni par NETSCOPE_ALERTES_TLS_PORT)") {
        // Vérification manuelle : faux serveur SMTP avec STARTTLS et certificat auto-signé sur 127.0.0.1.
        guard let raw = ProcessInfo.processInfo.environment["NETSCOPE_ALERTES_TLS_PORT"], let port = UInt16(raw) else {
            throw TestSkipped(reason: "NETSCOPE_ALERTES_TLS_PORT non défini")
        }
        let message = AlertMailMessage(from: "a@exemple.ca", to: ["b@exemple.ca"], subject: "s", textBody: "t", date: fixedDate)
        let config = SMTPSubmitConfig(host: "127.0.0.1", port: port, security: .startTLS, username: "u", password: "p", timeout: 4)
        let outcome = await SMTPSubmission.send(message, config: config,
                                                transport: SMTPNetworkTransport(host: "127.0.0.1", port: port, security: .startTLS, connectTimeout: 4))
        print(outcome.transcript.joined(separator: "\n"))
        print("  Erreur : \(outcome.error?.errorDescription ?? "aucune")")
        guard case .tlsFailed(let reason)? = outcome.error else { throw TestFailure(message: "échec TLS attendu", file: #fileID, line: #line) }
        try expect(reason.contains("non approuvé"), "certificat auto-signé refusé : \(reason)")
        try expect(!outcome.transcript.contains { $0.hasPrefix("C: AUTH") }, "aucun mot de passe envoyé")
    }

    suite.add("Alertes : connexion refusée sur 127.0.0.1") {
        let port = try LocalTCPServer.unusedPort()
        let message = AlertMailMessage(from: "a@exemple.ca", to: ["b@exemple.ca"], subject: "s", textBody: "t", date: fixedDate)
        let outcome = await SMTPSubmission.send(message, config: SMTPSubmitConfig(host: "127.0.0.1", port: port, security: .none, timeout: 2),
                                                transport: SMTPNetworkTransport(host: "127.0.0.1", port: port, security: .none, connectTimeout: 2))
        try expectEqual(outcome.error, .connectionRefused(host: "127.0.0.1", port: port), "refusée")
    }

    // MARK: Webhooks

    suite.add("Alertes : carte adaptative Microsoft Teams (Workflows)") {
        let batch = AlertBatch(events: [sampleEvent()], createdAt: fixedDate)
        let data = try AlertComposer.body(for: .teams, batch: batch, context: context, now: fixedDate)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        try expectEqual(json["type"] as? String, "message", "type message")
        let attachment = (json["attachments"] as? [[String: Any]])?.first ?? [:]
        try expectEqual(attachment["contentType"] as? String, "application/vnd.microsoft.card.adaptive", "pièce jointe adaptative")
        try expect(attachment["contentUrl"] is NSNull, "contentUrl nul")
        let card = attachment["content"] as? [String: Any] ?? [:]
        try expectEqual(card["type"] as? String, "AdaptiveCard", "carte")
        try expectEqual(card["version"] as? String, "1.4", "version 1.4")
        try expectEqual(card["$schema"] as? String, "http://adaptivecards.io/schemas/adaptive-card.json", "schéma")
        let body = card["body"] as? [[String: Any]] ?? []
        try expectEqual(body.first?["text"] as? String, "Caméra-Quai hors ligne", "titre accentué")
        try expectEqual(body.first?["color"] as? String, "Attention", "couleur critique")
        let facts = body.first { $0["type"] as? String == "FactSet" }?["facts"] as? [[String: String]]
        try expectEqual(facts?.first?["title"], "Cible", "faits")
        // Lot de plusieurs événements : un conteneur par événement.
        let many = AlertBatch(events: [sampleEvent(), sampleEvent(.newDevice, subject: "b")], suppressedCount: 2, createdAt: fixedDate)
        let card2 = ((AlertComposer.teams(many, context: context)["attachments"] as? [[String: Any]])?.first?["content"] as? [String: Any]) ?? [:]
        let body2 = card2["body"] as? [[String: Any]] ?? []
        try expectEqual(body2.filter { $0["type"] as? String == "Container" }.count, 2, "deux conteneurs")
        try expect(body2.contains { ($0["text"] as? String)?.contains("2 répétitions") == true }, "répétitions rappelées")
    }

    suite.add("Alertes : message Slack en blocs, échappement") {
        var event = sampleEvent()
        event.message = "Appareil <@here> & co"
        let payload = AlertComposer.slack(AlertBatch(events: [event], createdAt: fixedDate), context: context)
        try expectEqual(payload["text"] as? String, "[NetScope] Critique · Caméra-Quai hors ligne", "texte de repli")
        let blocks = payload["blocks"] as? [[String: Any]] ?? []
        try expectEqual(blocks.map { $0["type"] as? String ?? "" }, ["header", "section", "context"], "blocs")
        let section = (blocks[1]["text"] as? [String: Any])?["text"] as? String ?? ""
        try expect(section.contains("&lt;@here&gt; &amp; co"), "mention neutralisée")
        try expect(section.contains("`192.168.50.21`"), "détail en code")
        let data = try AlertComposer.body(for: .slack, batch: AlertBatch(events: [event], createdAt: fixedDate), context: context, now: fixedDate)
        let object = try JSONSerialization.jsonObject(with: data)
        try expect(JSONSerialization.isValidJSONObject(object), "JSON valide")
    }

    suite.add("Alertes : JSON générique documenté (schéma 1)") {
        let batch = AlertBatch(events: [sampleEvent(), sampleEvent(.rogueDHCP, subject: "10.0.0.250")], suppressedCount: 1, createdAt: fixedDate)
        let data = try AlertComposer.body(for: .generic, batch: batch, context: context, now: fixedDate)
        let payload = try JSONDecoder().decode(AlertComposer.GenericPayload.self, from: data)
        try expectEqual(payload.source, "NetScope", "source")
        try expectEqual(payload.schema, 1, "schéma")
        try expectEqual(payload.count, 2, "nombre")
        try expectEqual(payload.suppressed, 1, "répétitions")
        try expectEqual(payload.severity, "critical", "gravité la plus forte")
        try expectEqual(payload.sentAt, "2026-11-04T19:03:00Z", "date ISO")
        try expectEqual(Set(payload.events.map(\.kind)), ["sonde.panne", "dhcp.non-autorise"], "types")
        try expectEqual(payload.events.first?.details.first, AlertDetail("Cible", "192.168.50.21"), "détails")
        let text = String(decoding: data, as: UTF8.self)
        try expect(text.contains("\"title\":\"2 alertes NetScope\""), "titre du lot")
    }

    suite.add("Alertes : envoi webhook (faux client HTTP), en-tête d’authentification, erreurs, journal sans secret") {
        let hook = AlertWebhook(kind: .generic, name: "Supervision", authHeaderName: "Authorization")
        var settings = AlertSettings()
        settings.isEnabled = true
        settings.webhooks = [hook]
        let url = "https://supervision.exemple.ca/hooks/abc123-SECRET"
        let token = "Bearer jeton-tres-secret"
        let secrets = AlertSecrets(webhookURLs: [hook.id: url], webhookAuth: [hook.id: token])
        let batch = AlertBatch(events: [sampleEvent()], createdAt: fixedDate)

        let ok = FakeHTTP(status: 202, body: "")
        let entry = await AlertDelivery(context: context, http: ok).deliver(batch, on: .webhook(hook.id), settings: settings, secrets: secrets, now: fixedDate)
        try expectEqual(entry.outcome, .sent, "envoyé")
        try expectEqual(entry.detail, "HTTP 202", "détail")
        try expectEqual(ok.requests.first?.url.absoluteString, url, "adresse utilisée")
        try expectEqual(ok.requests.first?.headers["Authorization"], token, "en-tête d’authentification")
        try expectEqual(ok.requests.first?.headers["Content-Type"], "application/json; charset=utf-8", "type JSON")

        // Le service renvoie l'adresse et le jeton dans son message d'erreur : rien ne reste au journal.
        let echo = FakeHTTP(status: 403, body: "forbidden for \(url) with \(token)")
        let failed = await AlertDelivery(context: context, http: echo).deliver(batch, on: .webhook(hook.id), settings: settings, secrets: secrets, now: fixedDate)
        try expectEqual(failed.outcome, .failed, "échec")
        try expect(failed.detail.hasPrefix("Accès refusé (403)"), "erreur expliquée : \(failed.detail)")
        let journal = try String(decoding: JSONEncoder().encode(failed), as: UTF8.self)
        try expect(!journal.contains("abc123-SECRET") && !journal.contains("jeton-tres-secret"), "journal sans secret : \(journal)")

        let insecure = AlertSecrets(webhookURLs: [hook.id: "http://supervision.exemple.ca/x"])
        let refused = await AlertDelivery(context: context, http: ok).deliver(batch, on: .webhook(hook.id), settings: settings, secrets: insecure, now: fixedDate)
        try expect(refused.detail.contains("https://"), "http:// refusé")
        try expectEqual(ok.requests.count, 1, "aucune requête de plus")

        let offline = FakeHTTP(error: URLError(.notConnectedToInternet))
        let down = await AlertDelivery(context: context, http: offline).deliver(batch, on: .webhook(hook.id), settings: settings, secrets: secrets, now: fixedDate)
        try expect(down.detail.contains("Pas de connexion Internet"), "hors ligne expliqué")
        try expect(AlertRedactor.maskedWebhook(url) == "supervision.exemple.ca/…CRET", "adresse masquée")
    }

    suite.add("Alertes : envoi courriel par AlertDelivery (faux transport), journal sans mot de passe") {
        var settings = AlertSettings()
        settings.isEnabled = true
        settings.smtp = smtpSettings()
        let secrets = AlertSecrets(smtpPassword: "SuperSecret-2026")
        let transport = ScriptedSMTP(script: ScriptedSMTP.standard(auth: "AUTH PLAIN"))
        let delivery = AlertDelivery(context: context, smtpTransport: { _, _, _ in transport }, timeout: 2)
        let entry = await delivery.deliver(AlertBatch.test(now: fixedDate, origin: "MacBook de Dany"), on: .email, settings: settings,
                                           secrets: secrets, now: fixedDate)
        try expectEqual(entry.outcome, .sent, "envoyé : \(entry.detail)")
        try expect(entry.isTest, "essai")
        try expect(entry.detail.contains("250 2.0.0 Ok") && entry.detail.contains("2 destinataires") && entry.detail.contains("chiffré"), "détail : \(entry.detail)")
        // Mot de passe absent : refus avant toute connexion.
        let none = ScriptedSMTP(script: ScriptedSMTP.standard(auth: "AUTH PLAIN"))
        let missing = await AlertDelivery(context: context, smtpTransport: { _, _, _ in none }).deliver(
            AlertBatch.test(now: fixedDate, origin: "x"), on: .email, settings: settings, secrets: AlertSecrets(), now: fixedDate)
        try expectEqual(missing.outcome, .failed, "échec sans mot de passe")
        try expect(missing.detail.contains("Trousseau"), "explication")
        try expect(!none.opened, "aucune connexion")
        // Erreur du serveur qui répète le mot de passe : masqué.
        var script = ScriptedSMTP.standard(auth: "AUTH PLAIN")
        script["AUTH"] = ["535 5.7.8 bad password SuperSecret-2026"]
        let echoTransport = ScriptedSMTP(script: script)
        let echo = await AlertDelivery(context: context, smtpTransport: { _, _, _ in echoTransport }).deliver(
            AlertBatch.test(now: fixedDate, origin: "x"), on: .email, settings: settings, secrets: secrets, now: fixedDate)
        try expect(!echo.detail.contains("SuperSecret-2026"), "mot de passe retiré : \(echo.detail)")
        // Réglages : aucun secret dans le JSON enregistré.
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try expect(!json.contains("SuperSecret") && !json.lowercased().contains("password"), "réglages sans secret")
        try expectEqual(try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8)), settings, "aller-retour des réglages")
        try expectEqual(try JSONDecoder().decode(AlertSettings.self, from: Data("{}".utf8)).isEnabled, false, "désactivées par défaut")
    }

    // MARK: Règles

    suite.add("Alertes : rien n’est envoyé tant que les alertes sont désactivées") {
        var planner = AlertPlanner()
        var settings = AlertSettings()
        try expectEqual(planner.submit(sampleEvent(), settings: settings, now: fixedDate), .skipped(.alertsDisabled), "désactivées")
        settings.isEnabled = true
        try expectEqual(planner.submit(sampleEvent(), settings: settings, hasChannel: false, now: fixedDate), .skipped(.noChannel), "aucun canal")
        settings.rules.kinds.remove(.probeDown)
        try expectEqual(planner.submit(sampleEvent(), settings: settings, now: fixedDate), .skipped(.kindDisabled), "type non choisi")
        settings.rules.kinds.insert(.probeDown)
        settings.rules.minimumSeverity = .critical
        try expectEqual(planner.submit(sampleEvent(.newDevice, subject: "mac"), settings: settings, now: fixedDate), .skipped(.belowSeverity), "gravité")
        let probe = UUID()
        settings.rules.excludedProbes = [probe]
        try expectEqual(planner.submit(sampleEvent(probe: probe), settings: settings, now: fixedDate), .skipped(.probeExcluded), "sonde exclue")
        try expect(planner.pending.isEmpty, "file vide")
    }

    suite.add("Alertes : anti-rafale et regroupement en résumé") {
        var planner = AlertPlanner()
        var settings = AlertSettings()
        settings.isEnabled = true
        settings.rules.throttleMinutes = 15
        settings.rules.groupingSeconds = 60
        let t0 = fixedDate
        try expectEqual(planner.submit(sampleEvent(subject: "a", at: t0), settings: settings, now: t0), .queued, "premier")
        try expectEqual(planner.submit(sampleEvent(subject: "a", at: t0 + 5), settings: settings, now: t0 + 5), .skipped(.throttled), "répétition")
        try expectEqual(planner.submit(sampleEvent(.probeWarning, subject: "b", at: t0 + 10), settings: settings, now: t0 + 10), .queued, "autre objet")
        try expect(planner.flush(now: t0 + 30, rules: settings.rules) == nil, "fenêtre pas écoulée")
        try expectEqual(planner.nextFlush(rules: settings.rules), t0 + 60, "départ prévu")
        guard let batch = planner.flush(now: t0 + 61, rules: settings.rules) else { throw TestFailure(message: "lot attendu", file: #fileID, line: #line) }
        try expectEqual(batch.events.count, 2, "un seul résumé de deux événements")
        try expectEqual(batch.events.first?.severity, .critical, "le plus grave d’abord")
        try expectEqual(batch.suppressedCount, 1, "répétition comptée")
        try expectEqual(batch.title, "2 alertes NetScope", "titre du résumé")
        try expectEqual(batch.breakdown, "1\u{00A0}critique, 1\u{00A0}alerte", "répartition")
        try expect(planner.pending.isEmpty, "file vidée")
        // Toujours dans l'intervalle : retenu ; après 15 min : de nouveau envoyé.
        try expectEqual(planner.submit(sampleEvent(subject: "a", at: t0 + 600), settings: settings, now: t0 + 600), .skipped(.throttled), "encore retenu")
        try expectEqual(planner.submit(sampleEvent(subject: "a", at: t0 + 901), settings: settings, now: t0 + 901), .queued, "après l’intervalle")
        let next = planner.flush(now: t0 + 2000, rules: settings.rules)
        try expectEqual(next?.suppressedCount, 1, "répétition rappelée")
        // Regroupement immédiat : départ tout de suite.
        settings.rules.groupingSeconds = 0
        _ = planner.submit(sampleEvent(subject: "z", at: t0 + 3000), settings: settings, now: t0 + 3000)
        try expect(planner.flush(now: t0 + 3000, rules: settings.rules) != nil, "envoi immédiat")
    }

    suite.add("Alertes : rétablissement seulement après une panne signalée") {
        var planner = AlertPlanner()
        var settings = AlertSettings()
        settings.isEnabled = true
        settings.rules.minimumSeverity = .warning
        let recovery = sampleEvent(.probeRecovered, subject: "cam", severity: .info)
        try expectEqual(planner.submit(recovery, settings: settings, now: fixedDate), .skipped(.noOpenAlert), "pas de panne signalée")
        _ = planner.submit(sampleEvent(subject: "cam"), settings: settings, now: fixedDate)
        try expectEqual(planner.submit(recovery, settings: settings, now: fixedDate + 30), .queued, "rétablissement envoyé malgré la gravité info")
        try expectEqual(planner.submit(recovery, settings: settings, now: fixedDate + 40), .skipped(.noOpenAlert), "une seule fois")
    }

    suite.add("Alertes : un changement de règles garde la file et les pannes ouvertes") {
        var planner = AlertPlanner()
        var settings = AlertSettings()
        settings.isEnabled = true
        let probe = UUID()
        _ = planner.submit(sampleEvent(subject: "cam", at: fixedDate), settings: settings, now: fixedDate)
        _ = planner.submit(sampleEvent(subject: "nas", at: fixedDate, probe: probe), settings: settings, now: fixedDate)
        let previous = settings.rules
        settings.rules.groupingSeconds = 300
        settings.rules.excludedProbes = [probe]
        planner.applyRules(settings.rules, previous: previous)
        try expectEqual(planner.pending.map(\.subject), ["cam"], "seule la sonde exclue quitte la file")
        try expect(planner.lastQueued["sonde.panne|cam"] != nil, "anti-rafale gardé (intervalle inchangé)")
        let before = settings.rules
        settings.rules.throttleMinutes = 5
        planner.applyRules(settings.rules, previous: before)
        try expect(planner.lastQueued.isEmpty, "anti-rafale oublié quand l’intervalle change")
        _ = planner.flush(now: fixedDate + 400, rules: settings.rules)
        try expectEqual(planner.submit(sampleEvent(.probeRecovered, subject: "cam", severity: .info), settings: settings, now: fixedDate + 500),
                        .queued, "rétablissement accepté après le changement de règles")
    }

    suite.add("Alertes : heures de silence (passage de minuit, critiques permises)") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let quiet = AlertQuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: hour, minute: minute))!
        }
        try expect(quiet.contains(at(23), calendar: calendar), "23 h : silence")
        try expect(quiet.contains(at(6, 59), calendar: calendar), "6 h 59 : silence")
        try expect(!quiet.contains(at(7), calendar: calendar), "7 h : fin")
        try expect(!quiet.contains(at(12), calendar: calendar), "midi")
        try expectEqual(quiet.label, "22:00 – 07:00", "libellé")
        var planner = AlertPlanner()
        var settings = AlertSettings()
        settings.isEnabled = true
        settings.rules.quietHours = quiet
        try expectEqual(planner.submit(sampleEvent(.probeWarning, subject: "w"), settings: settings, now: at(23), calendar: calendar),
                        .skipped(.quietHours), "alerte retenue la nuit")
        try expectEqual(planner.submit(sampleEvent(subject: "c"), settings: settings, now: at(23), calendar: calendar), .queued, "critique permise")
        settings.rules.quietHours.criticalBypass = false
        try expectEqual(planner.submit(sampleEvent(subject: "d"), settings: settings, now: at(23), calendar: calendar), .skipped(.quietHours), "critique retenue aussi")
    }

    suite.add("Alertes : masquage des secrets (valeur, base64, URL) et validation des adresses") {
        let text = "Erreur: mdp=Hunter2! (SHVudGVyMiE=) via https://hooks.slack.com/services/T0/B0/xyz"
        let clean = AlertRedactor.redact(text, secrets: ["Hunter2!"])
        try expect(!clean.contains("Hunter2!") && !clean.contains("SHVudGVyMiE="), "mot de passe et base64 retirés")
        try expect(clean.contains("https://hooks.slack.com/••••") && !clean.contains("xyz"), "chemin d’URL masqué : \(clean)")
        try expect((try? AlertWebhookAddress.validate("https://hooks.slack.com/services/x")) != nil, "https accepté")
        try expect((try? AlertWebhookAddress.validate("http://127.0.0.1:8080/x")) != nil, "http local accepté")
        try expectThrows(AlertWebhookError.insecureURL, "http refusé") { _ = try AlertWebhookAddress.validate("http://exemple.ca/x") }
        try expectThrows(AlertWebhookError.invalidURL, "file refusé") { _ = try AlertWebhookAddress.validate("file:///etc/passwd") }
        try expect(AlertWebhookKind.teams.isExpectedHost("prod-27.westus.logic.azure.com"), "hôte Workflows")
        try expect(!AlertWebhookKind.slack.isExpectedHost("exemple.ca"), "hôte Slack inattendu")
        try expect(AlertSMTPSettings().problems(hasPassword: false).contains("Serveur SMTP à renseigner."), "réglages incomplets")
        try expect(smtpSettings().problems(hasPassword: true).isEmpty, "réglages complets")
        var clear = smtpSettings(security: .none)
        clear.username = "u"
        try expect(clear.problems(hasPassword: true).contains { $0.contains("jamais de mot de passe") }, "pas de mot de passe sans chiffrement")
    }

    suite.add("Alertes : adaptateurs des émetteurs (sonde, service, DHCP, scan)") {
        let probe = MonProbe(name: "Caméra-Quai", kind: .ping, target: "192.168.50.21", subtitle: "Hikvision")
        let alert = MonAlert(date: fixedDate, probeID: probe.id, probeName: probe.name, severity: .critical, message: "Aucune réponse")
        let event = AlertEvent.probe(alert, probe: probe)
        try expectEqual(event?.kind, .probeDown, "panne")
        try expectEqual(event?.title, "Caméra-Quai hors ligne", "titre")
        try expectEqual(event?.probeID, probe.id, "sonde")
        try expectEqual(AlertEvent.probeRecovery(probe: probe, value: "1,2 ms").subject, probe.id.uuidString, "même objet que la panne")
        try expect(AlertEvent.probe(MonAlert(date: fixedDate, probeID: probe.id, probeName: "x", severity: .success, message: ""), probe: probe) == nil,
                   "succès ignoré")
        let incident = SvcIncident(id: "inc1", title: "Retards Outlook", impact: .outage, status: "En cours", affected: ["Exchange Online"])
        let service = AlertEvent.serviceIncident(serviceID: "m365", serviceName: "Microsoft 365", incident: incident, at: fixedDate)
        try expectEqual(service.severity, .critical, "panne de service critique")
        try expectEqual(service.title, "Microsoft 365\u{00A0}: panne", "titre du service")
        var offer = DHCPOffer(messageType: .offer, xid: 1, flagsBroadcast: true, offeredAddress: IPv4Address("192.168.0.100")!)
        offer.serverIdentifier = IPv4Address("10.182.122.250")
        let rogue = AlertEvent.rogueDHCP(offer, interface: "en0", at: fixedDate)
        try expectEqual(rogue.subject, "10.182.122.250", "objet : le serveur")
        try expectEqual(rogue.severity, .critical, "critique")
        let scan = AlertEvent.scanFinished(online: 42, new: 2, duration: "38 s", ranges: "10.182.122.0/24", at: fixedDate)
        try expectEqual(scan.kind, .scanFinished, "fin de scan")
        try expectEqual(AlertEvent.newDevices([], at: fixedDate), nil, "aucun nouvel appareil")
    }
}

// MARK: - Faux transport à réponses fixes

/// Transport SMTP scripté : chaque commande (premier mot) reçoit des lignes de réponse fixes.
private final class ScriptedSMTP: SMTPSubmitTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String: [String]]
    private var queue: [[String]] = []
    private var expectingData = false
    private var encrypted: Bool
    private let openError: SMTPSubmitError?
    private(set) var commands: [String] = []
    private(set) var payload = ""
    private(set) var opened = false
    private(set) var upgradedBeforeAuth = false
    private var loginStep = 0

    init(script: [String: [String]], encryptedAtOpen: Bool = false, openError: SMTPSubmitError? = nil) {
        self.script = script
        self.encrypted = encryptedAtOpen
        self.openError = openError
    }

    /// Serveur de soumission courant : STARTTLS, AUTH, deux destinataires acceptés.
    static func standard(auth: String, startTLS: Bool = true) -> [String: [String]] {
        var ehlo = ["250-smtp.exemple.ca Hello", "250-PIPELINING", "250-SIZE 35882577"]
        if startTLS { ehlo.append("250-STARTTLS") }
        ehlo += ["250-\(auth)", "250 8BITMIME"]
        return [
            "BANNER": ["220 smtp.exemple.ca ESMTP Postfix"],
            "EHLO": ehlo,
            "STARTTLS": ["220 2.0.0 Ready to start TLS"],
            "AUTH": auth.contains("LOGIN") && !auth.contains("PLAIN") ? ["334 VXNlcm5hbWU6"] : ["235 2.7.0 Authentication successful"],
            "LOGIN-USER": ["334 UGFzc3dvcmQ6"],
            "LOGIN-PASS": ["235 2.7.0 Authentication successful"],
            "MAIL": ["250 2.1.0 Ok"],
            "RCPT": ["250 2.1.5 Ok"],
            "DATA": ["354 End data with <CR><LF>.<CR><LF>"],
            "END": ["250 2.0.0 Ok: queued as 4F2A"],
            "QUIT": ["221 2.0.0 Bye"],
        ]
    }

    var isEncrypted: Bool { lock.withLock { encrypted } }

    func open() async throws {
        if let openError { throw openError }
        lock.withLock {
            opened = true
            queue.append(script["BANNER"] ?? ["220 ok"])
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        let text = String(decoding: bytes, as: UTF8.self)
        lock.withLock {
            if expectingData {
                payload = text
                expectingData = false
                queue.append(script["END"] ?? ["250 ok"])
                return
            }
            let line = text.replacingOccurrences(of: "\r\n", with: "")
            commands.append(line)
            let verb = line.split(separator: " ").first.map { String($0).uppercased() } ?? ""
            let key: String
            if ["EHLO", "STARTTLS", "AUTH", "MAIL", "RCPT", "DATA", "QUIT"].contains(verb) {
                key = verb
            } else {
                // Réponses à AUTH LOGIN (utilisateur puis mot de passe, en base64).
                loginStep += 1
                key = loginStep == 1 ? "LOGIN-USER" : "LOGIN-PASS"
            }
            let reply = script[key] ?? ["502 5.5.2 Error: command not recognized"]
            if verb == "AUTH" { upgradedBeforeAuth = encrypted }
            if verb == "DATA", reply.first?.hasPrefix("354") == true { expectingData = true }
            queue.append(reply)
        }
    }

    func readReply(timeout: TimeInterval) async throws -> SMTPReply {
        let lines: [String]? = lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
        guard let lines else { throw SMTPSubmitError.timeout("") }
        var parser = SMTPReplyParser()
        guard let reply = try parser.feed(lines.joined(separator: "\r\n") + "\r\n").first else { throw SMTPSubmitError.protocolError("script") }
        return reply
    }

    func upgradeToTLS() async throws {
        lock.withLock { encrypted = true }
    }

    func close() {}
}

// MARK: - Faux client HTTP

private final class FakeHTTP: AlertHTTPClient, @unchecked Sendable {
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

    init(status: Int = 200, body: String = "ok", error: Error? = nil) {
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

// MARK: - Faux serveur de soumission (127.0.0.1)

/// Faux serveur SMTP : bannière, EHLO (sans STARTTLS), MAIL, RCPT, DATA jusqu'au point final, QUIT.
private func fakeSubmissionServer(_ fd: Int32, offerStartTLS: Bool, log: ToolTestBox<[String]>) {
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    func write(_ text: String) {
        let bytes = Array((text + "\r\n").utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    }
    write("220 mx.test.example ESMTP Postfix")
    var buffer = [UInt8](repeating: 0, count: 4096)
    var pending = ""
    var inData = false
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return }
        pending += String(decoding: buffer[0..<n], as: UTF8.self)
        while let range = pending.range(of: "\r\n") {
            let line = String(pending[..<range.lowerBound])
            pending.removeSubrange(..<range.upperBound)
            log.mutate { $0.append(line) }
            if inData {
                if line == "." {
                    inData = false
                    write("250 2.0.0 Ok: queued as LOCAL1")
                }
                continue
            }
            let verb = line.split(separator: " ").first.map { $0.uppercased() } ?? ""
            switch verb {
            case "EHLO":
                write("250-mx.test.example Hello")
                if offerStartTLS { write("250-STARTTLS") }
                write("250 8BITMIME")
            case "MAIL", "RCPT": write("250 2.1.0 Ok")
            case "DATA":
                inData = true
                write("354 End data with <CR><LF>.<CR><LF>")
            case "QUIT":
                write("221 2.0.0 Bye")
                return
            default:
                write("502 5.5.2 Error: command not recognized")
            }
        }
    }
}
