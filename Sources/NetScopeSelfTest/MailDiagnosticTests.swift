import Darwin
import Foundation
import NetScopeCore

// Tests du diagnostic SMTP et de l'analyse d'en-têtes (note 14, partie 2) : dialogues et
// en-têtes fixes ; les seules connexions vont à un faux serveur SMTP sur 127.0.0.1.

func registerMailDiagnosticTests(_ suite: TestSuite) {
    suite.add("SMTP : réponses multi-lignes coupées n’importe où") {
        var parser = SMTPReplyParser()
        let dialog = "220 mx.exemple.ca ESMTP Postfix\r\n250-mx.exemple.ca\r\n250-PIPELINING\r\n250-SIZE 36700160\r\n"
            + "250-STARTTLS\r\n250-AUTH PLAIN LOGIN\r\n250 SMTPUTF8\r\n"
        var replies: [SMTPReply] = []
        // Octet par octet : une réponse n'est rendue qu'une fois sa dernière ligne reçue.
        for byte in Array(dialog.utf8) { replies += try parser.feed([byte]) }
        try expectEqual(replies.count, 2, "deux réponses")
        try expectEqual(replies[0], SMTPReply(code: 220, lines: ["mx.exemple.ca ESMTP Postfix"]), "bannière")
        try expectEqual(replies[1].code, 250, "code EHLO")
        try expectEqual(replies[1].lines.count, 6, "six lignes EHLO")
        try expectEqual(replies[1].rawLines.last, "250 SMTPUTF8", "dernière ligne reconstruite")
        try expect(!parser.hasPartialReply, "rien en attente")

        // LF seul toléré ; « 250 » sans texte.
        var lf = SMTPReplyParser()
        try expectEqual(try lf.feed("221 2.0.0 Bye\n250\n"), [SMTPReply(code: 221, lines: ["2.0.0 Bye"]), SMTPReply(code: 250, lines: [""])],
                        "fin de ligne LF")
        // Réponse partielle conservée.
        var partial = SMTPReplyParser()
        try expectEqual(try partial.feed("250-un\r\n250-deux"), [], "réponse inachevée")
        try expect(partial.hasPartialReply, "réponse en attente")
        try expectEqual(try partial.feed("\r\n250 trois\r\n").first?.lines ?? [], ["un", "deux", "trois"], "réponse complétée")

        // Lignes illisibles ou codes mélangés.
        var bad = SMTPReplyParser()
        try expectThrows(SMTPError.malformedReply("HTTP/1.1 400 Bad Request"), "pas du SMTP") {
            _ = try bad.feed("HTTP/1.1 400 Bad Request\r\n")
        }
        var mixed = SMTPReplyParser()
        try expectThrows(SMTPError.malformedReply("251 b"), "codes différents dans une réponse") {
            _ = try mixed.feed("250-a\r\n251 b\r\n")
        }
    }

    suite.add("SMTP : extensions EHLO expliquées") {
        let reply = SMTPReply(code: 250, lines: ["mx.exemple.ca Hello [203.0.113.5]", "PIPELINING", "SIZE 36700160", "VRFY",
                                                 "ETRN", "STARTTLS", "AUTH=LOGIN PLAIN", "ENHANCEDSTATUSCODES", "8BITMIME",
                                                 "DSN", "SMTPUTF8", "CHUNKING", "XCLIENT NAME ADDR"])
        let extensions = SMTPExtension.parse(ehlo: reply)
        try expectEqual(extensions.map(\.keyword), ["PIPELINING", "SIZE", "VRFY", "ETRN", "STARTTLS", "AUTH", "ENHANCEDSTATUSCODES",
                                                    "8BITMIME", "DSN", "SMTPUTF8", "CHUNKING", "XCLIENT"], "mots-clés")
        try expectEqual(extensions.first("SIZE")?.explanation, "Taille maximale d’un message\u{00A0}: 35\u{00A0}Mo", "taille en Mo")
        try expectEqual(extensions.first("AUTH")?.parameters, ["LOGIN", "PLAIN"], "AUTH= ancienne forme")
        try expect(extensions.first("VRFY")?.isConcern == true, "VRFY à surveiller")
        try expectEqual(extensions.first("XCLIENT")?.explanation, "Extension propre au serveur", "extension X")
        try expect(SMTPExtension.parse(ehlo: SMTPReply(code: 502, lines: ["Error"])).isEmpty, "EHLO refusé : aucune extension")
        try expectEqual(SMTPBanner.hostname(in: "mx.exemple.ca ESMTP Postfix (Debian)"), "mx.exemple.ca", "nom de la bannière")
        try expectEqual(SMTPBanner.hostname(in: "ESMTP prêt"), nil, "bannière sans nom")
        try expectEqual(SMTPBanner.hostname(in: "203.0.113.5 ESMTP"), nil, "adresse au lieu du nom")
        try expectEqual(SMTPBanner.software(in: "mx.google.com ESMTP a1-20020 - gsmtp"), "Google", "logiciel reconnu")
    }

    suite.add("SMTP : seules EHLO, STARTTLS et QUIT existent") {
        try expectEqual(SMTPCommand.ehlo("[192.0.2.10]").bytes, Array("EHLO [192.0.2.10]\r\n".utf8), "EHLO")
        try expectEqual(SMTPCommand.startTLS.line, "STARTTLS", "STARTTLS")
        try expectEqual(SMTPCommand.quit.line, "QUIT", "QUIT")
        try expect(SMTPCommand.validEHLOName("[192.0.2.10]") && SMTPCommand.validEHLOName("poste.exemple.ca"), "noms valides")
        try expect(!SMTPCommand.validEHLOName("x\r\nMAIL FROM:<a@b>"), "injection refusée")
    }

    suite.add("SMTP : certificat, joker et bilan de cohérence") {
        let now = Date(timeIntervalSince1970: 1_793_750_400)   // 2026-11-04
        let certificate = SMTPCertificate(subject: "mx1.exemple.ca", issuer: "R11 · Let's Encrypt",
                                          notBefore: now.addingTimeInterval(-30 * 86_400), notAfter: now.addingTimeInterval(9 * 86_400),
                                          dnsNames: ["mx1.exemple.ca", "*.mail.exemple.ca"], isTrusted: true, isSelfSigned: false)
        try expect(certificate.covers("MX1.exemple.ca."), "nom exact, casse et point final ignorés")
        try expect(certificate.covers("in.mail.exemple.ca"), "joker sur une étiquette")
        try expect(!certificate.covers("a.b.mail.exemple.ca"), "joker limité à une étiquette")
        try expect(!certificate.covers("mail.exemple.ca"), "joker ne couvre pas le domaine lui-même")
        try expectEqual(certificate.daysLeft(now: now), 9, "jours restants")

        let banner = SMTPReply(code: 220, lines: ["mx1.exemple.ca ESMTP Postfix"])
        let findings = SMTPAssessment.findings(
            host: "mx1.exemple.ca", port: 25, banner: banner, bannerDelayMs: 120, ehloGreeting: "mx1.exemple.ca",
            extensions: [SMTPExtension(keyword: "STARTTLS"), SMTPExtension(keyword: "AUTH", parameters: ["PLAIN", "LOGIN"])],
            extensionsAfterTLS: [], tls: .succeeded, tlsVersion: "TLS 1.3", certificate: certificate,
            ptrNames: ["mx1.exemple.ca"], ptrConfirmed: true, now: now)
        let titles = findings.map(\.title)
        try expect(titles.contains("Certificat bientôt expiré"), "expiration proche")
        try expect(titles.contains("Authentification proposée avant le chiffrement"), "AUTH en clair")
        try expect(titles.contains("Bannière cohérente avec le DNS inverse"), "bannière = PTR")
        try expect(titles.contains("DNS inverse confirmé"), "FCrDNS")
        try expect(titles.contains("Le certificat couvre « mx1.exemple.ca »"), "nom couvert")
        try expect(titles.contains("Session chiffrée (TLS 1.3)"), "chiffrement")
        try expectEqual(findings.first?.level, .warning, "le plus grave d’abord")

        // Serveur mal configuré : pas de PTR, certificat d'un autre nom et auto-signé, port 587 sans STARTTLS.
        let selfSigned = SMTPCertificate(subject: "localhost", issuer: "localhost", notBefore: nil,
                                         notAfter: now.addingTimeInterval(-86_400), dnsNames: ["localhost"],
                                         isTrusted: false, isSelfSigned: true)
        let bad = SMTPAssessment.findings(host: "smtp.exemple.ca", port: 587, banner: SMTPReply(code: 220, lines: ["localhost ESMTP"]),
                                          bannerDelayMs: 7_200, ehloGreeting: "localhost", extensions: [SMTPExtension(keyword: "VRFY")],
                                          extensionsAfterTLS: [], tls: .notOffered, tlsVersion: nil, certificate: selfSigned,
                                          ptrNames: [], ptrConfirmed: nil, now: now)
        let badTitles = bad.map(\.title)
        try expect(badTitles.contains("STARTTLS absent sur le port de soumission"), "587 sans STARTTLS")
        try expect(badTitles.contains("Aucun DNS inverse (PTR) pour l’adresse du serveur"), "sans PTR")
        try expect(badTitles.contains("Certificat expiré"), "expiré")
        try expect(badTitles.contains("Le certificat ne couvre pas « smtp.exemple.ca »"), "nom non couvert")
        try expect(badTitles.contains("Certificat auto-signé"), "auto-signé")
        try expect(badTitles.contains("VRFY ou EXPN activé"), "VRFY")
        try expect(badTitles.contains { $0.hasPrefix("Bannière lente") }, "bannière lente")
        try expectEqual(bad.first?.level, .critical, "critique en tête")
        let refused = SMTPAssessment.findings(host: "mx.exemple.ca", port: 25, banner: SMTPReply(code: 554, lines: ["5.7.1 Service unavailable"]),
                                              bannerDelayMs: 50, ehloGreeting: nil, extensions: [], extensionsAfterTLS: [],
                                              tls: .notReached, tlsVersion: nil, certificate: nil, ptrNames: ["mx.exemple.ca"],
                                              ptrConfirmed: true, now: now)
        try expectEqual(refused.first?.title, "Le serveur refuse la session (code 554)", "bannière 554")
    }

    suite.add("SMTP : port 25 sortant bloqué par le fournisseur") {
        let blocked = SMTPAssessment.port25Block(port25: .timedOut, alternatives: [(587, .connected), (465, .timedOut)])
        try expectEqual(blocked?.title, "Le port 25 sortant semble bloqué par votre fournisseur", "25 muet, 587 joignable")
        try expectEqual(blocked?.level, .critical, "gravité")
        let unreachable = SMTPAssessment.port25Block(port25: .timedOut, alternatives: [(587, .timedOut), (465, .timedOut)])
        try expectEqual(unreachable?.title, "Aucune réponse sur les ports 25, 587 ni 465", "tout muet")
        try expectEqual(SMTPAssessment.port25Block(port25: .refused, alternatives: [(587, .connected)]), nil, "25 refusé : pas un blocage")
        try expectEqual(SMTPAssessment.port25Block(port25: .connected, alternatives: []), nil, "25 joignable")
    }

    suite.add("SMTP : MX triés par préférence, MX nul") {
        let records = [
            DNSRecord(name: "exemple.ca.", typeCode: 15, ttl: 300, value: "20 MX2.exemple.ca."),
            DNSRecord(name: "exemple.ca.", typeCode: 15, ttl: 300, value: "10 mx1.exemple.ca."),
            DNSRecord(name: "exemple.ca.", typeCode: 6, ttl: 300, value: "ns. admin. 1 2 3 4 5"),
        ]
        try expectEqual(SMTPDiagnostic.mailExchangers(in: records)?.map(\.host), ["mx1.exemple.ca", "mx2.exemple.ca"], "ordre")
        try expectEqual(SMTPDiagnostic.mailExchangers(in: records)?.first?.preference, 10, "préférence")
        try expectEqual(SMTPDiagnostic.mailExchangers(in: [DNSRecord(name: "x.", typeCode: 15, ttl: 1, value: "0 .")])?.count, 0, "MX nul")
        try expectEqual(SMTPDiagnostic.mailExchangers(in: []).map(\.count), nil, "aucun MX")
    }

    suite.add("SMTP : dialogue complet avec un faux serveur sur 127.0.0.1 (sans STARTTLS)") {
        let commands = ToolTestBox<[String]>([])
        let server = try LocalTCPServer { fd in
            fakeSMTP(fd, offerStartTLS: false, commands: commands)
        }
        defer { server.stop() }
        let result = await SMTPDiagnostic.run(host: "127.0.0.1", port: server.port, timeout: 3, checkPTR: false)
        try expectEqual(result.connectOutcome, .connected, "connexion")
        try expectEqual(result.banner?.code, 220, "bannière")
        try expectEqual(result.ehloGreeting, "mx.test.example Hello", "salutation")
        try expectEqual(result.extensions.map(\.keyword), ["PIPELINING", "SIZE", "AUTH", "8BITMIME"], "extensions en clair")
        try expectEqual(result.tls, .notOffered, "STARTTLS absent")
        try expect(result.findings.contains { $0.title == "STARTTLS non proposé" }, "constat STARTTLS")
        try expect(result.findings.contains { $0.title == "Authentification proposée avant le chiffrement" }, "AUTH en clair")
        try expect(result.steps.contains { $0.name == "QUIT" && $0.status == .ok }, "QUIT répondu")
        let sent = commands.value.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        try expectEqual(sent, ["EHLO", "QUIT"], "commandes envoyées")
        try expect(result.transcriptText.contains("S: 250-PIPELINING") && result.transcriptText.contains("C: QUIT"), "transcription")
    }

    suite.add("SMTP : STARTTLS refusé par le faux serveur, jamais de MAIL/RCPT/DATA") {
        let commands = ToolTestBox<[String]>([])
        let server = try LocalTCPServer { fd in
            fakeSMTP(fd, offerStartTLS: true, commands: commands)
        }
        defer { server.stop() }
        let result = await SMTPDiagnostic.run(host: "127.0.0.1", port: server.port, timeout: 3, checkPTR: false)
        try expectEqual(result.tls, .failed("STARTTLS refusé\u{00A0}: 454 4.7.0 TLS not available"), "STARTTLS refusé")
        try expect(result.findings.contains { $0.title == "Échec du chiffrement" }, "constat")
        let verbs = Set(commands.value.map { $0.split(separator: " ").first.map { String($0).uppercased() } ?? "" })
        try expect(verbs.isSubset(of: ["EHLO", "STARTTLS", "QUIT"]), "commandes permises seulement : \(verbs)")
        try expect(verbs.contains("STARTTLS"), "STARTTLS tenté")
    }

    suite.add("SMTP : connexion refusée sur 127.0.0.1") {
        let port = try LocalTCPServer.unusedPort()
        let result = await SMTPDiagnostic.run(host: "127.0.0.1", port: port, timeout: 2, checkPTR: false)
        try expectEqual(result.connectOutcome, .refused, "refusée")
        try expect(result.findings.first?.title.hasPrefix("Connexion refusée") == true, "constat de refus")
    }

    suite.add("SMTP : STARTTLS et certificat réels (serveur local fourni par NETSCOPE_SMTP_TLS_PORT)") {
        // Vérification manuelle : un faux serveur SMTP avec TLS sur 127.0.0.1 (voir l'historique du dépôt).
        guard let raw = ProcessInfo.processInfo.environment["NETSCOPE_SMTP_TLS_PORT"], let port = UInt16(raw) else {
            throw TestSkipped(reason: "NETSCOPE_SMTP_TLS_PORT non défini")
        }
        let result = await SMTPDiagnostic.run(host: "127.0.0.1", port: port, timeout: 4, checkPTR: false)
        print(result.transcriptText)
        for step in result.steps { print("  \(step.name) · \(step.durationMs.map { ToolFormat.milliseconds($0) } ?? "—") · \(step.detail)") }
        for finding in result.findings { print("  [\(finding.level)] \(finding.title) \(finding.detail)") }
        print("  Certificat : \(String(describing: result.certificate))")
        try expectEqual(result.tls, .succeeded, "chiffré")
        try expect(result.certificate?.dnsNames.contains("mx.test.example") == true, "noms du certificat")
        try expect(result.certificate?.isSelfSigned == true, "auto-signé")
        try expect(result.extensionsAfterTLS.contains("AUTH"), "AUTH après TLS")
    }

    suite.add("SMTP : TLS direct (port 465) réel (serveur local fourni par NETSCOPE_SMTP_IMPLICIT_PORT)") {
        guard let raw = ProcessInfo.processInfo.environment["NETSCOPE_SMTP_IMPLICIT_PORT"], let port = UInt16(raw) else {
            throw TestSkipped(reason: "NETSCOPE_SMTP_IMPLICIT_PORT non défini")
        }
        let result = await SMTPDiagnostic.run(host: "127.0.0.1", port: port, mode: .implicit, timeout: 4, checkPTR: false)
        print(result.transcriptText)
        for step in result.steps { print("  \(step.name) · \(step.durationMs.map { ToolFormat.milliseconds($0) } ?? "—") · \(step.detail)") }
        try expectEqual(result.tls, .succeeded, "chiffré")
        try expectEqual(result.banner?.code, 220, "bannière après TLS")
        try expect(result.extensionsAfterTLS.contains("AUTH"), "extensions")
    }
}

/// Faux serveur SMTP minimal (127.0.0.1) : bannière, EHLO, STARTTLS refusé (454), QUIT.
private func fakeSMTP(_ fd: Int32, offerStartTLS: Bool, commands: ToolTestBox<[String]>) {
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    func write(_ text: String) {
        let bytes = Array((text + "\r\n").utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    }
    write("220 mx.test.example ESMTP Postfix")
    var buffer = [UInt8](repeating: 0, count: 1024)
    var pending = ""
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return }
        pending += String(decoding: buffer[0..<n], as: UTF8.self)
        while let range = pending.range(of: "\r\n") {
            let line = String(pending[..<range.lowerBound])
            pending.removeSubrange(..<range.upperBound)
            commands.mutate { $0.append(line) }
            let verb = line.split(separator: " ").first.map { $0.uppercased() } ?? ""
            switch verb {
            case "EHLO":
                write("250-mx.test.example Hello")
                write("250-PIPELINING")
                write("250-SIZE 10240000")
                if offerStartTLS { write("250-STARTTLS") }
                write("250-AUTH PLAIN LOGIN")
                write("250 8BITMIME")
            case "STARTTLS":
                write("454 4.7.0 TLS not available")
            case "QUIT":
                write("221 2.0.0 Bye")
                return
            default:
                write("502 5.5.2 Error: command not recognized")
            }
        }
    }
}

/// Valeur partagée entre le faux serveur et le test.
final class ToolTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
