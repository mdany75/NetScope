import Foundation
import NetScopeCore

// Note 70 : vérificateur de certificat TLS. Lecteur X.509 sur des certificats recopiés,
// correspondance du nom, expiration, verdict, STARTTLS sur des échanges recopiés et vérification
// du site avec une sonde factice : aucun trafic réseau.

func registerTLSCertificateTests(_ suite: TestSuite) {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    let now = date("2026-11-05T12:00:00Z")

    suite.add("Certificat TLS : lecture X.509 d'un certificat RSA auto-signé (FortiGate)") {
        let cert = try X509Certificate(der: TLSFixtures.fortigate)
        try expectEqual(cert.version, 3, "version")
        try expectEqual(cert.serialNumber, "5A:3C:9E:01", "numéro de série")
        try expectEqual(cert.subject.commonName, "FGT60FTK2209A1B2", "CN")
        try expectEqual(cert.subject.organization, "Fortinet", "O")
        try expectEqual(cert.subject.text, "CN=FGT60FTK2209A1B2, OU=FortiGate, O=Fortinet, L=Sunnyvale, ST=California, C=US", "sujet lisible")
        try expect(cert.isSelfIssued, "sujet = émetteur")
        try expectEqual(cert.publicKey.label, "RSA 2048\u{00A0}bits", "clé")
        try expect(!cert.publicKey.isWeak, "2048 bits n'est pas faible")
        try expectEqual(cert.signatureAlgorithm, "SHA-256 avec RSA", "signature")
        try expectEqual(TLSFormat.date(cert.notBefore), "2022-03-15", "début")
        try expectEqual(TLSFormat.date(cert.notAfter), "2032-03-12", "fin")
        try expect(cert.subjectAltNames.isEmpty, "aucun SAN")
        try expectEqual(cert.sha256Fingerprint,
                        "2A:E3:9A:25:38:A4:23:CB:1B:25:81:BD:BB:7B:BB:9E:7D:1B:8B:E3:C3:F8:7F:F3:32:91:B5:F1:76:A5:5A:96",
                        "empreinte SHA-256 identique à openssl")
    }

    suite.add("Certificat TLS : SAN DNS, joker et IP, EC P-256, GeneralizedTime (NAS)") {
        let cert = try X509Certificate(der: TLSFixtures.nas)
        try expectEqual(cert.dnsNames, ["nas.exemple.ca", "*.exemple.ca"], "noms DNS")
        try expectEqual(cert.ipAddresses, ["10.182.122.154"], "adresse IP")
        try expectEqual(cert.publicKey.label, "ECDSA P-256", "clé EC")
        try expectEqual(cert.publicKey.bits, 256, "taille EC")
        try expectEqual(cert.signatureAlgorithm, "ECDSA avec SHA-256", "signature")
        try expectEqual(cert.issuer.commonName, "Exemple CA interne", "émetteur")
        try expect(!cert.isSelfIssued, "émis par une autorité")
        try expectEqual(cert.isCA, false, "pas une autorité")
        try expect(cert.allowsServerAuth, "usage serveur")
        try expectEqual(TLSFormat.date(cert.notAfter), "2051-01-01", "fin en GeneralizedTime")
        try expectEqual(cert.serialNumber, "12:34", "série courte")
        try expectEqual(cert.sha256Fingerprint,
                        "F5:2F:C5:8A:D9:FA:77:FF:03:5A:C3:56:28:88:3A:C2:05:D5:7F:23:CF:10:3D:83:F7:D3:77:57:07:70:B0:F1", "empreinte")
    }

    suite.add("Certificat TLS : autorité interne, imprimante expirée et racine ISRG X2") {
        let ca = try X509Certificate(der: TLSFixtures.internalCA)
        try expectEqual(ca.isCA, true, "CA:TRUE")
        try expectEqual(ca.signatureAlgorithm, "ECDSA avec SHA-384", "signature CA")
        let printer = try X509Certificate(der: TLSFixtures.printer)
        try expectEqual(printer.publicKey.label, "RSA 1024\u{00A0}bits", "clé RSA 1024")
        try expect(printer.publicKey.isWeak, "1024 bits est faible")
        try expect(printer.hasWeakSignature, "SHA-1 est faible")
        try expectEqual(printer.ipAddresses, ["10.182.122.111"], "SAN IP")
        let root = try X509Certificate(der: TLSFixtures.isrgRootX2)
        try expectEqual(root.subject.commonName, "ISRG Root X2", "CN racine")
        try expectEqual(root.subject.organization, "Internet Security Research Group", "O racine")
        try expectEqual(root.publicKey.label, "ECDSA P-384", "clé P-384")
        try expectEqual(root.signatureAlgorithm, "ECDSA avec SHA-384", "signature racine")
        try expectEqual(TLSFormat.date(root.notAfter), "2040-09-17", "fin racine")
        try expectEqual(root.serialNumber, "41:D2:9D:D1:72:EA:EE:A7:80:C1:2C:6C:E9:2F:87:52", "série racine")
    }

    suite.add("Certificat TLS : PEM aller-retour et DER abîmé refusé") {
        let cert = try X509Certificate(der: TLSFixtures.nas)
        let parsed = X509Certificate.parsePEM("texte avant\n" + cert.pem + (try X509Certificate(der: TLSFixtures.internalCA)).pem)
        try expectEqual(parsed.count, 2, "deux certificats PEM")
        try expectEqual(parsed.first?.der, cert.der, "DER identique")
        var damaged = TLSFixtures.fortigate
        damaged.removeLast(40)
        var refused = false
        do { _ = try X509Certificate(der: damaged) } catch { refused = true }
        try expect(refused, "DER tronqué refusé")
        var garbage = false
        do { _ = try X509Certificate(der: Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])) } catch { garbage = true }
        try expect(garbage, "longueur hors limites refusée")
    }

    suite.add("Certificat TLS : correspondance du nom (joker, IP, CN sans SAN)") {
        let nas = try X509Certificate(der: TLSFixtures.nas)
        try expect(nas.matches(host: "nas.exemple.ca"), "nom exact")
        try expect(nas.matches(host: "NAS.Exemple.CA."), "casse et point final")
        try expect(nas.matches(host: "portail.exemple.ca"), "joker")
        try expect(!nas.matches(host: "exemple.ca"), "joker ne couvre pas le domaine nu")
        try expect(!nas.matches(host: "a.b.exemple.ca"), "joker sur une seule étiquette")
        try expect(nas.matches(host: "10.182.122.154"), "SAN IP")
        try expect(!nas.matches(host: "10.182.122.155"), "autre IP")
        try expect(!TLSHostname.matches("x.ca", pattern: "*.ca"), "joker sur un domaine de premier niveau refusé")
        let fgt = try X509Certificate(der: TLSFixtures.fortigate)
        try expect(fgt.matches(host: "fgt60ftk2209a1b2"), "CN sans SAN en repli")
        try expect(TLSHostname.matchesOnlyByCommonName("FGT60FTK2209A1B2", certificate: fgt), "signalé comme CN seulement")
    }

    suite.add("Certificat TLS : expiration et seuil réglable") {
        let nas = try X509Certificate(der: TLSFixtures.nas)
        try expectEqual(TLSExpiry.of(nas, now: date("2050-12-20T00:00:00Z")), .soon(days: 12), "bientôt (seuil 30)")
        try expectEqual(TLSExpiry.of(nas, now: date("2050-12-20T00:00:00Z"), warningDays: 7), .valid(days: 12), "seuil 7 jours")
        try expectEqual(TLSExpiry.of(nas, now: date("2025-09-01T00:00:00Z")), .notYetValid(inDays: 30), "pas encore valide")
        let printer = try X509Certificate(der: TLSFixtures.printer)
        let expired = TLSExpiry.of(printer, now: now)
        try expectEqual(expired, .expired(daysAgo: 1404), "expirée depuis 1404 jours")
        try expectEqual(expired.label, "expiré depuis 1\u{202F}404\u{00A0}jours", "libellé")
        try expectEqual(expired.daysRemaining, -1404, "jours négatifs")
    }

    suite.add("Certificat TLS : verdicts et constats (auto-signé, expiré, nom, versions)") {
        let fgt = try X509Certificate(der: TLSFixtures.fortigate)
        var inspection = TLSInspection(date: now, host: "10.182.122.1", port: 443, serverName: nil, chain: [fgt],
                                       trusted: false, trustReason: "certificat auto-signé", chainTrusted: false,
                                       negotiatedVersion: .tls12, cipherSuite: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
                                       versions: [TLSVersionSupport(version: .tls13, accepted: false), TLSVersionSupport(version: .tls12, accepted: true),
                                                  TLSVersionSupport(version: .tls11, accepted: true), TLSVersionSupport(version: .tls10, accepted: false)])
        try expectEqual(TLSAnalysis.verdict(inspection, now: now), .selfSigned, "FortiGate auto-signée jointe par IP")
        let titles = TLSAnalysis.findings(inspection, now: now).map(\.title)
        try expect(titles.contains("Certificat auto-signé"), "constat auto-signé")
        try expect(titles.contains("Versions obsolètes acceptées"), "TLS 1.1 accepté signalé")
        try expect(titles.contains("Joint par son adresse IP"), "IP sans SAN : information")
        try expect(titles.contains("TLS 1.3 non pris en charge"), "TLS 1.3 absent")

        let printer = try X509Certificate(der: TLSFixtures.printer)
        inspection = TLSInspection(date: now, host: "10.182.122.111", port: 443, serverName: nil, chain: [printer])
        try expectEqual(TLSAnalysis.verdict(inspection, now: now), .expired(daysAgo: 1404), "imprimante expirée")
        let printerFindings = TLSAnalysis.findings(inspection, now: now)
        try expectEqual(printerFindings.first?.title, "Certificat expiré", "le plus grave d'abord")
        try expect(printerFindings.contains { $0.title == "Clé faible" }, "clé faible")
        try expect(printerFindings.contains { $0.title == "Signature faible" }, "SHA-1")

        let nas = try X509Certificate(der: TLSFixtures.nas)
        let ca = try X509Certificate(der: TLSFixtures.internalCA)
        inspection = TLSInspection(date: now, host: "10.182.122.154", port: 5001, serverName: "intranet.autre.ca", chain: [nas, ca],
                                   trusted: false, chainTrusted: true)
        try expectEqual(TLSAnalysis.verdict(inspection, now: now), .nameMismatch, "SNI non couvert")
        inspection.serverName = "nas.exemple.ca"
        inspection.trusted = true
        try expectEqual(TLSAnalysis.verdict(inspection, now: now), .ok, "nom couvert et chaîne reconnue")
        inspection.chain = [nas]
        try expect(TLSAnalysis.findings(inspection, now: now).contains { $0.title == "Chaîne incomplète" }, "intermédiaire manquant")
        try expect(TLSAnalysis.report(inspection, now: now).contains("SHA-256 : F5:2F:C5"), "rapport avec l'empreinte")
        inspection.chain = []
        inspection.error = "Connexion refusée (port fermé)"
        try expectEqual(TLSAnalysis.verdict(inspection, now: now), .failed, "aucun certificat")
    }

    suite.add("Certificat TLS : STARTTLS SMTP, IMAP et POP3 sur des échanges recopiés") {
        var smtp = TLSStartTLSDialogue(mode: .smtp, ehloName: "[10.0.0.5]")
        try expectEqual(smtp.feed(Array("220 mx.exemple.ca ESMTP Postfix\r\n".utf8)), [.send("EHLO [10.0.0.5]")], "EHLO après la bannière")
        try expectEqual(smtp.feed(Array("250-mx.exemple.ca\r\n250-SIZE 52428800\r\n250-STARTTLS\r\n250 SMTPUTF8\r\n".utf8)),
                        [.send("STARTTLS")], "STARTTLS annoncé")
        try expectEqual(smtp.feed(Array("220 2.0.0 Ready to start TLS\r\n".utf8)), [.startTLS], "poignée TLS")
        try expect(smtp.isFinished, "terminé")
        try expectEqual(smtp.transcript.last, "S: 220 2.0.0 Ready to start TLS", "trace")

        var noTLS = TLSStartTLSDialogue(mode: .smtp)
        _ = noTLS.feed(Array("220 vieux.exemple.ca ESMTP\r\n".utf8))
        try expectEqual(noTLS.feed(Array("250-vieux.exemple.ca\r\n250 8BITMIME\r\n".utf8)), [.fail("Le serveur ne propose pas STARTTLS")],
                        "STARTTLS absent")

        var imap = TLSStartTLSDialogue(mode: .imap)
        // Réponse en deux morceaux : la ligne n'est lue qu'une fois complète.
        try expectEqual(imap.feed(Array("* OK [CAPABILITY IMAP4rev1 STARTTLS] Dovecot ".utf8)), [], "ligne incomplète")
        try expectEqual(imap.feed(Array("ready.\r\n".utf8)), [.send("a1 STARTTLS")], "STARTTLS IMAP")
        try expectEqual(imap.feed(Array("a1 OK Begin TLS negotiation now.\r\n".utf8)), [.startTLS], "IMAP accepte")

        var imapRefused = TLSStartTLSDialogue(mode: .imap)
        _ = imapRefused.feed(Array("* OK ready\r\n".utf8))
        try expectEqual(imapRefused.feed(Array("a1 BAD STARTTLS not supported\r\n".utf8)),
                        [.fail("STARTTLS refusé\u{00A0}: a1 BAD STARTTLS not supported")], "IMAP refuse")

        var pop = TLSStartTLSDialogue(mode: .pop3)
        try expectEqual(pop.feed(Array("+OK POP3 ready\r\n".utf8)), [.send("STLS")], "STLS")
        try expectEqual(pop.feed(Array("+OK Begin TLS\r\n".utf8)), [.startTLS], "POP3 accepte")
        try expectEqual(TLSPortPreset.mode(for: 587), .smtp, "587 en STARTTLS")
        try expectEqual(TLSPortPreset.mode(for: 993), .direct, "993 en TLS direct")
        try expectEqual(TLSCipherSuite.name(0x1302), "TLS_AES_256_GCM_SHA384", "nom de suite")
        try expect(TLSCipherSuite.isWeak("TLS_RSA_WITH_AES_128_CBC_SHA"), "RSA statique faible")
    }

    suite.add("Certificat TLS : vérification du site (cibles, concurrence limitée, expirés d'abord)") {
        let devices = [
            Device(ip: IPv4Address("10.0.0.20")!, hostname: "nas", openPorts: [80, 443, 5001]),
            Device(ip: IPv4Address("10.0.0.1")!, hostname: "fgt", openPorts: [22, 443, 8443]),
            Device(ip: IPv4Address("10.0.0.30")!, hostname: "pc", openPorts: [445]),
            Device(ip: IPv4Address("10.0.0.40")!, hostname: "hors-ligne", isOnline: false, openPorts: [443]),
        ]
        let targets = TLSSiteSweep.targets(from: devices)
        try expectEqual(targets.map(\.id), ["10.0.0.1:443", "10.0.0.1:8443", "10.0.0.20:443"], "443 et 8443 des appareils en ligne")

        let fgt = try X509Certificate(der: TLSFixtures.fortigate)
        let printer = try X509Certificate(der: TLSFixtures.printer)
        let nas = try X509Certificate(der: TLSFixtures.nas)
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var running = 0
            var peak = 0
            func enter() { lock.lock(); running += 1; peak = max(peak, running); lock.unlock() }
            func leave() { lock.lock(); running -= 1; lock.unlock() }
        }
        let counter = Counter()
        let many = (1...10).map { TLSSweepTarget(host: "10.0.1.\($0)", port: 443, name: "h\($0)") }
        let results = await TLSSiteSweep.run(many, concurrency: 3) { target in
            counter.enter()
            try? await Task.sleep(nanoseconds: 5_000_000)
            counter.leave()
            let index = Int(target.host.split(separator: ".").last!)!
            let chain = index == 4 ? [printer] : index == 2 ? [fgt] : [nas]
            return TLSInspection(date: now, host: target.host, port: target.port, serverName: nil, chain: chain)
        }
        try expectEqual(results.count, 10, "toutes les cibles")
        try expect(counter.peak <= 3, "au plus 3 à la fois (vu \(counter.peak))")
        try expectEqual(results.map(\.host), many.map(\.host), "ordre des cibles gardé")
        try expectEqual(results[3].label, "h4", "nom de l'appareil repris")
        let soon = TLSSiteSweep.attention(results, now: date("2032-02-20T00:00:00Z"), warningDays: 30)
        try expectEqual(soon.map(\.host), ["10.0.1.4", "10.0.1.2"], "expiré d'abord, puis bientôt")
        try expectEqual(TLSSiteSweep.attention(results, now: now).map(\.host), ["10.0.1.4"], "seule l'imprimante en 2026")
    }
}
