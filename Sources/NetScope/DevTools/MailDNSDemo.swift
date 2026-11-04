import Foundation
import NetScopeCore

/// Démonstration (`--demo`) du diagnostic SMTP, de l'analyse d'en-têtes et de la recherche DNS
/// étendue (note 14) : données fixes et réalistes, aucune requête réseau. Domaines et adresses
/// de documentation (exemple.ca, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32).
///
/// Captures : NETSCOPE_OUTIL_DEMO=dns|smtp|entetes ouvre l'outil ; pour le DNS,
/// NETSCOPE_DNS_VUE=comparer|propagation choisit la vue.
enum MailDNSDemo {
    static var now: Date { Date() }

    // MARK: DNS

    struct DNSState {
        var query: String
        var type: DNSRecordType
        var mode: DNSToolMode
        var result: DNSLookupResult?
        var comparison: DNSComparison?
        var propagation: DNSComparison?
    }

    static func dnsInitialState() -> DNSState {
        switch ProcessInfo.processInfo.environment["NETSCOPE_DNS_VUE"] {
        case "comparer", "compare":
            let servers: [(name: String, address: IPv4Address?, region: String?)] = [
                ("Résolveur du système", nil, nil), ("Cloudflare", IPv4Address(1, 1, 1, 1), nil),
                ("Google", IPv4Address(8, 8, 8, 8), nil), ("Quad9", IPv4Address(9, 9, 9, 9), nil),
            ]
            return DNSState(query: "exemple.ca", type: .a, mode: .compare,
                            comparison: comparison("exemple.ca", type: .a, servers: servers))
        case "propagation":
            return DNSState(query: "exemple.ca", type: .a, mode: .propagation, propagation: propagation("exemple.ca", type: .a))
        default:
            return DNSState(query: "exemple.ca", type: .caa, mode: .lookup, result: lookup("exemple.ca", type: .caa))
        }
    }

    /// Valeurs fixes par type (présentation de dig).
    static func values(_ type: DNSRecordType, name: String) -> [(UInt32, String)] {
        let zone = name.hasSuffix(".") ? name : name + "."
        switch type {
        case .a: return [(300, "203.0.113.40")]
        case .aaaa: return [(300, "2001:db8:40::1")]
        case .mx: return [(3600, "10 mx1.\(zone)"), (3600, "20 mx2.\(zone)")]
        case .txt: return [(3600, "\"v=spf1 mx include:_spf.fournisseur-courriel.ca -all\""),
                           (3600, "\"verification-domaine=4f2c9e01a7b3\"")]
        case .ns: return [(86_400, "ns1.hebergeur-dns.ca."), (86_400, "ns2.hebergeur-dns.ca.")]
        case .cname: return [(300, "www-exemple.hebergeur-web.ca.")]
        case .ptr: return [(3600, name.hasPrefix("10.182.122.111") || name.hasPrefix("111.") ? "BRN94DDF818157D.bureau.local." : "mx1.exemple.ca.")]
        case .soa: return [(3600, "ns1.hebergeur-dns.ca. hostmaster.\(zone) 2026110402 7200 3600 1209600 300")]
        case .srv: return [(3600, "10 60 443 sip.\(zone)"), (3600, "20 40 443 sip2.\(zone)")]
        case .caa: return [(3600, "0 issue \"letsencrypt.org\""), (3600, "0 issuewild \";\""),
                           (3600, "0 iodef \"mailto:securite@\(name)\"")]
        case .dnskey: return [
            (3600, "257 3 13 mdsswUyr3DPW132mOi8V9xESWE8jTo0dxCjjnopKl+GqJxpVXckHAeF+KkxLbxILfDLUT0rAK9iUzy1L53eKGQ=="),
            (3600, "256 3 13 oJMRESz5E4gYzS/q6XDrvU1qMPYIjCWzJaOau8XNEZeqCYKD5ar0IRd8KqXXFJkqmVfRvMGPmM1x8fGAa2XhSA=="),
        ]
        case .ds: return [(86_400, "2371 13 2 1F987CC6583E92DF0890718C42A1F2A9F1E0C2F8B5C6D4E3F2A1B0C9D8E7F6A5")]
        }
    }

    static func lookup(_ text: String, type: DNSRecordType) -> DNSLookupResult {
        let name = DNSLookup.queryName(for: text, type: type)
        let records = values(type, name: name).map { DNSRecord(name: name.hasSuffix(".") ? name : name + ".", typeCode: type.code, ttl: $0.0, value: $0.1) }
        return DNSLookupResult(query: name, type: type, rcode: "NOERROR", records: records, answerCount: records.count,
                               isAuthoritative: false, serverLabel: "résolveur du système", durationMs: 14.2)
    }

    /// Comparaison : le résolveur du réseau garde l'ancienne adresse en cache (changement récent).
    static func comparison(_ text: String, type: DNSRecordType,
                           servers: [(name: String, address: IPv4Address?, region: String?)]) -> DNSComparison {
        let durations: [Double] = [3.4, 11.8, 18.6, 24.1, 9.7, 31.2]
        let answers = servers.enumerated().map { index, server -> DNSServerAnswer in
            var result = lookup(text, type: type)
            result.durationMs = durations[index % durations.count]
            result.serverLabel = server.address.map { "\($0)#53 (UDP)" } ?? "résolveur du système"
            if type == .a {
                let stale = server.address == nil || server.name == "Passerelle" || server.name == "DNS du réseau"
                result.records = result.records.map {
                    var record = $0
                    record.value = stale ? "198.51.100.20" : $0.value
                    record.ttl = stale ? 2_412 : UInt32(120 + index * 37)
                    return record
                }
            }
            return DNSServerAnswer(name: server.name, address: server.address, region: server.region, result: result, error: nil)
        }
        return DNSComparison(query: DNSLookup.queryName(for: text, type: type), type: type, answers: answers)
    }

    /// Propagation : huit résolveurs ont la nouvelle adresse, un garde l'ancienne, un ne répond pas.
    static func propagation(_ text: String, type: DNSRecordType) -> DNSComparison {
        let durations: [Double] = [8.1, 12.4, 15.0, 27.3, 19.8, 41.6, 88.2, 102.5, 33.9, 0]
        let answers = DNSPublicResolver.propagation.enumerated().map { index, resolver -> DNSServerAnswer in
            if resolver.name == "Control D" {
                return DNSServerAnswer(name: resolver.name, address: resolver.address, region: resolver.region, result: nil,
                                       error: "Aucune réponse après 3\u{00A0}s.")
            }
            var result = lookup(text, type: type)
            result.durationMs = durations[index]
            result.serverLabel = "\(resolver.address)#53 (UDP)"
            let stale = resolver.name == "Comodo Secure" && type == .a
            result.records = result.records.map {
                var record = $0
                if stale { record.value = "198.51.100.20" }
                record.ttl = stale ? 1_806 : UInt32(max(12, 300 - index * 29))
                return record
            }
            return DNSServerAnswer(name: resolver.name, address: resolver.address, region: resolver.region, result: result, error: nil)
        }
        return DNSComparison(query: DNSLookup.queryName(for: text, type: type), type: type, answers: answers)
    }

    // MARK: SMTP

    static let smtpTarget = "exemple.ca"

    /// Deux MX : le premier correct (Postfix, TLS 1.3, Let's Encrypt), le second à corriger
    /// (certificat bientôt expiré pour un autre nom, DNS inverse non confirmé).
    static func smtpResults() -> [SMTPDiagnosticResult] {
        let day: TimeInterval = 86_400
        let reference = now
        // MX 1
        let banner1 = SMTPReply(code: 220, lines: ["mx1.exemple.ca ESMTP Postfix"])
        let ehlo1 = SMTPReply(code: 250, lines: ["mx1.exemple.ca", "PIPELINING", "SIZE 52428800", "ETRN", "STARTTLS",
                                                 "ENHANCEDSTATUSCODES", "8BITMIME", "DSN", "SMTPUTF8", "CHUNKING"])
        let ehlo1TLS = SMTPReply(code: 250, lines: ["mx1.exemple.ca", "PIPELINING", "SIZE 52428800", "ETRN",
                                                    "ENHANCEDSTATUSCODES", "8BITMIME", "DSN", "SMTPUTF8", "CHUNKING"])
        let certificate1 = SMTPCertificate(subject: "mx1.exemple.ca", issuer: "R11 · Let's Encrypt",
                                           notBefore: reference.addingTimeInterval(-28 * day), notAfter: reference.addingTimeInterval(62 * day),
                                           dnsNames: ["mx1.exemple.ca", "mx.exemple.ca"], isTrusted: true, isSelfSigned: false)
        var mx1 = SMTPDiagnosticResult(
            host: "mx1.exemple.ca", port: 25, preference: 10, address: "203.0.113.25", mode: .startTLS, connectOutcome: .connected,
            steps: [
                SMTPStep("Résolution DNS", durationMs: 12.4, status: .ok, detail: "mx1.exemple.ca → 203.0.113.25"),
                SMTPStep("Connexion TCP", durationMs: 18.7, status: .ok, detail: "203.0.113.25 port 25"),
                SMTPStep("Bannière", durationMs: 41.3, status: .ok, detail: "220 mx1.exemple.ca ESMTP Postfix"),
                SMTPStep("EHLO", durationMs: 19.2, status: .ok, detail: "9 extensions annoncées"),
                SMTPStep("STARTTLS", durationMs: 18.9, status: .ok, detail: "220 2.0.0 Ready to start TLS"),
                SMTPStep("Poignée TLS", durationMs: 46.5, status: .ok, detail: "TLS 1.3 · AES-256-GCM"),
                SMTPStep("EHLO (chiffré)", durationMs: 19.6, status: .ok, detail: "8 extensions"),
                SMTPStep("QUIT", durationMs: 18.4, status: .ok, detail: "221 2.0.0 Bye"),
                SMTPStep("DNS inverse (PTR)", durationMs: 22.0, status: .ok, detail: "203.0.113.25 → mx1.exemple.ca ⇄ confirmé"),
            ],
            transcript: transcript([
                (.note, "Connecté à 203.0.113.25:25", 31.1), (.server, banner1, 72.4), (.client, "EHLO [10.182.122.135]", 72.6),
                (.server, ehlo1, 91.8), (.client, "STARTTLS", 92.0), (.server, SMTPReply(code: 220, lines: ["2.0.0 Ready to start TLS"]), 110.9),
                (.note, "Poignée TLS…", 111.0), (.note, "Chiffré\u{00A0}: TLS 1.3, AES-256-GCM", 157.5),
                (.client, "EHLO [10.182.122.135]", 157.7), (.server, ehlo1TLS, 177.3), (.client, "QUIT", 177.5),
                (.server, SMTPReply(code: 221, lines: ["2.0.0 Bye"]), 195.9),
            ]),
            banner: banner1, ehloGreeting: "mx1.exemple.ca", extensions: SMTPExtension.parse(ehlo: ehlo1),
            extensionsAfterTLS: SMTPExtension.parse(ehlo: ehlo1TLS), tls: .succeeded, tlsVersion: "TLS 1.3", cipher: "AES-256-GCM",
            certificate: certificate1, ptrNames: ["mx1.exemple.ca"], ptrConfirmed: true, totalMs: 218.0)
        mx1.findings = SMTPAssessment.findings(host: mx1.host, port: 25, banner: banner1, bannerDelayMs: 41.3, ehloGreeting: "mx1.exemple.ca",
                                               extensions: mx1.extensions, extensionsAfterTLS: mx1.extensionsAfterTLS, tls: .succeeded,
                                               tlsVersion: "TLS 1.3", certificate: certificate1, ptrNames: mx1.ptrNames,
                                               ptrConfirmed: true, now: reference)

        // MX 2
        let banner2 = SMTPReply(code: 220, lines: ["relais-secours.hebergeur-courriel.ca Microsoft ESMTP MAIL Service ready"])
        let ehlo2 = SMTPReply(code: 250, lines: ["relais-secours.hebergeur-courriel.ca Hello [192.0.2.135]", "SIZE 36700160", "PIPELINING",
                                                 "DSN", "ENHANCEDSTATUSCODES", "STARTTLS", "AUTH NTLM LOGIN", "8BITMIME", "BINARYMIME", "CHUNKING"])
        let ehlo2TLS = SMTPReply(code: 250, lines: ["relais-secours.hebergeur-courriel.ca Hello [192.0.2.135]", "SIZE 36700160", "PIPELINING",
                                                    "DSN", "ENHANCEDSTATUSCODES", "AUTH NTLM LOGIN", "8BITMIME", "BINARYMIME", "CHUNKING"])
        let certificate2 = SMTPCertificate(subject: "relais-secours.hebergeur-courriel.ca", issuer: "Sectigo RSA Domain Validation · Sectigo Limited",
                                           notBefore: reference.addingTimeInterval(-356 * day), notAfter: reference.addingTimeInterval(9 * day),
                                           dnsNames: ["relais-secours.hebergeur-courriel.ca"], isTrusted: true, isSelfSigned: false)
        var mx2 = SMTPDiagnosticResult(
            host: "mx2.exemple.ca", port: 25, preference: 20, address: "198.51.100.40", mode: .startTLS, connectOutcome: .connected,
            steps: [
                SMTPStep("Résolution DNS", durationMs: 10.8, status: .ok, detail: "mx2.exemple.ca → 198.51.100.40"),
                SMTPStep("Connexion TCP", durationMs: 34.2, status: .ok, detail: "198.51.100.40 port 25"),
                SMTPStep("Bannière", durationMs: 112.6, status: .ok, detail: "220 relais-secours.hebergeur-courriel.ca Microsoft ESMTP MAIL Service ready"),
                SMTPStep("EHLO", durationMs: 35.1, status: .ok, detail: "9 extensions annoncées"),
                SMTPStep("STARTTLS", durationMs: 34.8, status: .ok, detail: "220 2.0.0 SMTP server ready"),
                SMTPStep("Poignée TLS", durationMs: 96.3, status: .ok, detail: "TLS 1.2 · ECDHE · AES-256-GCM"),
                SMTPStep("EHLO (chiffré)", durationMs: 36.0, status: .ok, detail: "8 extensions"),
                SMTPStep("QUIT", durationMs: 34.5, status: .ok, detail: "221 2.0.0 Service closing transmission channel"),
                SMTPStep("DNS inverse (PTR)", durationMs: 25.4, status: .warning, detail: "198.51.100.40 → serveur-40.hebergeur-courriel.ca"),
            ],
            transcript: transcript([
                (.note, "Connecté à 198.51.100.40:25", 45.0), (.server, banner2, 157.6), (.client, "EHLO [10.182.122.135]", 157.8),
                (.server, ehlo2, 192.9), (.client, "STARTTLS", 193.1), (.server, SMTPReply(code: 220, lines: ["2.0.0 SMTP server ready"]), 227.9),
                (.note, "Poignée TLS…", 228.0), (.note, "Chiffré\u{00A0}: TLS 1.2, ECDHE · AES-256-GCM", 324.3),
                (.client, "EHLO [10.182.122.135]", 324.5), (.server, ehlo2TLS, 360.5), (.client, "QUIT", 360.7),
                (.server, SMTPReply(code: 221, lines: ["2.0.0 Service closing transmission channel"]), 395.2),
            ]),
            banner: banner2, ehloGreeting: "relais-secours.hebergeur-courriel.ca Hello [192.0.2.135]", extensions: SMTPExtension.parse(ehlo: ehlo2),
            extensionsAfterTLS: SMTPExtension.parse(ehlo: ehlo2TLS), tls: .succeeded, tlsVersion: "TLS 1.2", cipher: "ECDHE · AES-256-GCM",
            certificate: certificate2, ptrNames: ["serveur-40.hebergeur-courriel.ca"], ptrConfirmed: false, totalMs: 446.0)
        mx2.findings = SMTPAssessment.findings(host: mx2.host, port: 25, banner: banner2, bannerDelayMs: 112.6, ehloGreeting: mx2.ehloGreeting,
                                               extensions: mx2.extensions, extensionsAfterTLS: mx2.extensionsAfterTLS, tls: .succeeded,
                                               tlsVersion: "TLS 1.2", certificate: certificate2, ptrNames: mx2.ptrNames,
                                               ptrConfirmed: false, now: reference)
        return [mx1, mx2]
    }

    /// Lignes de l'échange : texte (client, note) ou réponse complète du serveur.
    private static func transcript(_ items: [(SMTPTranscriptLine.Direction, Any, Double)]) -> [SMTPTranscriptLine] {
        var lines: [SMTPTranscriptLine] = []
        for (direction, content, offset) in items {
            if let reply = content as? SMTPReply {
                for raw in reply.rawLines {
                    lines.append(SMTPTranscriptLine(id: lines.count, direction: .server, text: raw, offsetMs: offset))
                }
            } else if let text = content as? String {
                lines.append(SMTPTranscriptLine(id: lines.count, direction: direction, text: text, offsetMs: offset))
            }
        }
        return lines
    }

    // MARK: En-têtes

    /// Hameçonnage fictif : nom affiché trompeur, domaine sosie, DMARC en échec, Reply-To ailleurs.
    static let phishingHeaders = """
    Received: from mx.exemple.ca (mx.exemple.ca [10.182.122.20])
    \tby boite.exemple.ca (Postfix) with ESMTPS id 7C21A4F0E2
    \tfor <dany@exemple.ca>; Wed, 4 Nov 2026 08:15:44 -0500 (EST)
    Received: from relais.hebergement-rapide.net (relais.hebergement-rapide.net [203.0.113.200])
    \tby mx.exemple.ca (Postfix) with ESMTP id 3B9F0D11A7
    \tfor <dany@exemple.ca>; Wed, 4 Nov 2026 08:15:41 -0500 (EST)
    Received: from [198.51.100.66] (helo=vps-4471)
    \tby relais.hebergement-rapide.net with esmtpa (Exim 4.96)
    \tid 1tQx3a-0007Zk-2B; Wed, 04 Nov 2026 13:14:58 +0000
    Authentication-Results: mx.exemple.ca;
    \tspf=softfail smtp.mailfrom=bounce@hebergement-rapide.net;
    \tdkim=none;
    \tdmarc=fail (p=quarantine dis=quarantine) header.from=banquehor1zon.ca
    Return-Path: <bounce@hebergement-rapide.net>
    From: "Banque Horizon <service@banquehorizon.ca>" <securite@banquehor1zon.ca>
    Reply-To: verification.compte@soutien-clients.co
    To: Dany <dany@exemple.ca>
    Subject: =?UTF-8?Q?Action_requise_=3A_votre_acc=C3=A8s_est_suspendu?=
    Date: Wed, 4 Nov 2026 13:14:57 +0000
    Message-ID: <5f2c9e01a7@vps-4471.hebergement-rapide.net>
    X-Mailer: PHPMailer 6.8.1 (https://github.com/PHPMailer/PHPMailer)
    MIME-Version: 1.0
    Content-Type: text/html; charset=UTF-8
    """
}
