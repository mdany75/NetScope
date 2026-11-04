import Foundation
import NetScopeCore

// Tests des outils courriel (NetScopeCore/MailDNS) : enregistrements fixes et réponses DNS
// fixes (MailDNSFixture). Aucun trafic réseau.

enum MailKeys {
    static let rsa512 = "MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAMR53qCq7/j23DA1MC5ZK31j+Rpzak3httu+cMQGNfKfcQVHAHJCtMpdPHj1C5DA3+aV01hrKNHIjbJStUA5Fn0CAwEAAQ=="
    static let rsa1024 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDr6vp2zIZL6rRy5CGDPyRdiSjOt42fln4m8wJCQCnpoEcAwNkV/4ruPV9LtC00xq1RBsyhqteIJ8jE48K6Z9oNh/Z2agAu1JWhWXvgNqluAtaoueQknD51rSy6JYm9Jx8Iq3YZQN7k9A1o9dhgxU7wXTuTtkFCLxhKHUoJ0eac5QIDAQAB"
    static let rsa2048 = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxttdQl5OmtV5KKurqGm/+jAQpruHNDAGzMRfHvEpBgA/nfgu5Jm8MtLxhh4NOFv+ZU4Mpsq0Ss4bWqF9BLGuDE4UQs4cuPXMr3gNdnUoNajWatBWk1RaosEbGsL7BetCJUZPiLOgVZ88d31IByAbmqwO7h4tU1y7uR0tCdPtxa59+Qo7RzBU9LqVj9nfo/XRhkjz8hq0HPM3DNbyHjW0jUMiQuFEqPQD1ocIY4XNN6gOySZz0qn2LL1HHoit2genzQN0XNcqJrE3Cd9kYZPAWeE5YxTw4b6YzpAiVNmfgByZEZ2AdVJJVKY1GfToO9mxMKcWvK1qkHDAV88W0G3TgwIDAQAB"
    /// Même clé de 1024 bits, au format RSAPublicKey (PKCS #1) nu.
    static let pkcs1_1024 = "MIGJAoGBAOvq+nbMhkvqtHLkIYM/JF2JKM63jZ+WfibzAkJAKemgRwDA2RX/iu49X0u0LTTGrVEGzKGq14gnyMTjwrpn2g2H9nZqAC7UlaFZe+A2qW4C1qi55CScPnWtLLolib0nHwirdhlA3uT0DWj12GDFTvBdO5O2QUIvGEodSgnR5pzlAgMBAAE="
    static let ed25519 = "rjzc3aI5rqWzsj+YQ5rnXwSMj1qjbwU0Q1Q2dGyZHFk="
}

/// Domaine « mal configuré » : SPF à 11 recherches, DMARC p=none, une clé DKIM de 1024 bits.
private func weakFixture() -> MailDNSFixture {
    MailDNSFixture(records: [
        "exemple.ca|MX": ["10 mx1.exemple.ca.", "20 mx2.exemple.ca."],
        "exemple.ca|A": ["203.0.113.10"],
        "exemple.ca|TXT": ["v=spf1 a mx include:spf.envoi-a.test include:spf.envoi-b.test include:spf.envoi-c.test include:_spf.exemple.ca ~all",
                           "google-site-verification=abc"],
        "spf.envoi-a.test|TXT": ["v=spf1 ip4:198.51.100.0/24 include:spf2.envoi-a.test -all"],
        "spf2.envoi-a.test|TXT": ["v=spf1 ip4:198.51.101.0/24 -all"],
        "spf.envoi-b.test|TXT": ["v=spf1 exists:%{i}._spf.envoi-b.test include:spf3.envoi-b.test -all"],
        "spf3.envoi-b.test|TXT": ["v=spf1 ip6:2001:db8::/32 -all"],
        "spf.envoi-c.test|TXT": ["v=spf1 ip4:192.0.2.0/24 include:spf4.envoi-c.test ~all"],
        "spf4.envoi-c.test|TXT": ["v=spf1 ip4:192.0.2.128/25 ~all"],
        "_spf.exemple.ca|TXT": ["v=spf1 ip4:203.0.113.20 a:relais.exemple.ca -all"],
        "relais.exemple.ca|A": ["203.0.113.22"],
        "mx1.exemple.ca|A": ["203.0.113.25"],
        "mx2.exemple.ca|A": ["203.0.113.26"],
        "25.113.0.203.in-addr.arpa|PTR": ["mx1.exemple.ca."],
        "26.113.0.203.in-addr.arpa|PTR": ["serveur26.hebergeur.test."],
        "serveur26.hebergeur.test|A": ["203.0.113.99"],
        "_dmarc.exemple.ca|TXT": ["v=DMARC1; p=none; rua=mailto:dmarc@exemple.ca"],
        "selector1._domainkey.exemple.ca|TXT": ["v=DKIM1; k=rsa; p=\(MailKeys.rsa1024)"],
        "20.113.0.203.zen.spamhaus.org|A": ["127.0.0.2"],
        "20.113.0.203.zen.spamhaus.org|TXT": ["https://check.spamhaus.org/sbl/query/SBL123"],
    ])
}

/// Domaine « modèle » : tout est en place.
private func strongFixture() -> MailDNSFixture {
    MailDNSFixture(records: [
        "parfait.ca|MX": ["10 mx.parfait.ca."],
        "parfait.ca|TXT": ["v=spf1 mx ip4:198.51.100.7 -all"],
        "mx.parfait.ca|A": ["198.51.100.7"],
        "7.100.51.198.in-addr.arpa|PTR": ["mx.parfait.ca."],
        "_dmarc.parfait.ca|TXT": ["v=DMARC1; p=reject; rua=mailto:dmarc@parfait.ca; adkim=s"],
        "s1._domainkey.parfait.ca|TXT": ["v=DKIM1; k=rsa; p=\(MailKeys.rsa2048)"],
        "s2._domainkey.parfait.ca|TXT": ["v=DKIM1; k=ed25519; p=\(MailKeys.ed25519)"],
        "_mta-sts.parfait.ca|TXT": ["v=STSv1; id=20261101T000000"],
        "_smtp._tls.parfait.ca|TXT": ["v=TLSRPTv1; rua=mailto:tlsrpt@parfait.ca"],
        "default._bimi.parfait.ca|TXT": ["v=BIMI1; l=https://parfait.ca/logo.svg; a=https://parfait.ca/vmc.pem"],
    ], signedDomains: ["parfait.ca"],
    files: ["https://mta-sts.parfait.ca/.well-known/mta-sts.txt": "version: STSv1\nmode: enforce\nmx: mx.parfait.ca\nmax_age: 604800\n"])
}

func registerMailDNSTests(_ suite: TestSuite) {
    suite.add("Courriel : TXT recollés, noms, MX, domaine organisationnel, adresses réservées") {
        try expectEqual(MailDNSText.joinTXT("\"v=spf1 include:a.test \" \"~all\""), "v=spf1 include:a.test ~all", "chaînes recollées")
        try expectEqual(MailDNSText.joinTXT("\"a\\\"b\""), "a\"b", "guillemet échappé")
        try expectEqual(MailDNSText.joinTXT("v=DMARC1; p=none"), "v=DMARC1; p=none", "sans guillemets")
        try expectEqual(MailDNSText.normalize("MX1.Exemple.CA."), "mx1.exemple.ca", "nom normalisé")
        let mx = MailDNSText.parseMX("10 mx1.exemple.ca.")
        try expect(mx?.priority == 10 && mx?.host == "mx1.exemple.ca", "MX lu")
        try expectEqual(MailDNSText.organizationalDomain("mail.ventes.exemple.ca"), "exemple.ca", "domaine organisationnel")
        try expectEqual(MailDNSText.organizationalDomain("www.exemple.co.uk"), "exemple.co.uk", "suffixe à deux niveaux")
        try expect(MailDNSText.isReserved(IPv4Address("10.1.2.3")!) && MailDNSText.isReserved(IPv4Address("100.64.0.1")!)
                   && MailDNSText.isReserved(IPv4Address("192.168.1.1")!) && !MailDNSText.isReserved(IPv4Address("8.8.8.8")!), "adresses réservées")
        try expect(MailDNSText.isDomainName("_dmarc.exemple.ca") && !MailDNSText.isDomainName("exa mple.ca") && !MailDNSText.isDomainName("-a.ca"), "noms DNS")
    }

    suite.add("SPF : lecture des mécanismes, qualificatifs et fautes de syntaxe") {
        let record = SPFRecord.parse("v=spf1 ip4:192.0.2.0/24 ip6:2001:db8::/32 a mx:mail.exemple.ca/24 include:_spf.google.com ~all")!
        try expectEqual(record.terms.map(\.kind), [.ip4, .ip6, .a, .mx, .include, .all], "mécanismes")
        try expectEqual(record.all?.qualifier, "~", "qualificatif de all")
        try expectEqual(record.ownLookups, 3, "a, mx et include coûtent une recherche")
        try expectEqual(record.terms[3].targetDomain, "mail.exemple.ca", "domaine de mx sans le préfixe")
        try expect(record.errors.isEmpty && record.warnings.isEmpty, "aucune faute")
        try expect(SPFRecord.parse("v=spf10 -all") == nil, "v=spf10 n’est pas SPF")
        try expect(SPFRecord.parse("v=DMARC1; p=none") == nil, "DMARC n’est pas SPF")

        let bad = SPFRecord.parse("v=spf1 ip4:300.1.1.1 inclde:a.test include: -all ip4:192.0.2.1 redirect=a.test")!
        try expect(bad.errors.contains { $0.contains("300.1.1.1") }, "IPv4 invalide")
        try expect(bad.errors.contains { $0.contains("inclde") }, "mécanisme inconnu")
        try expect(bad.errors.contains { $0.contains("include:") && $0.contains("manquant") }, "include sans domaine")
        try expect(bad.warnings.contains { $0.contains("après « all »") }, "terme après all")
        try expect(bad.warnings.contains { $0.contains("redirect") }, "redirect ignoré avec all")
        try expectEqual(SPFRecord.parse("v=spf1 ptr -all")!.warnings.count, 1, "ptr déconseillé")
        let twice = SPFRecord.parse("v=spf1 redirect=a.test redirect=b.test")!
        try expect(twice.errors.contains { $0.contains("plusieurs fois") }, "redirect en double")
    }

    suite.add("SPF : décompte récursif (11 recherches > 10), recherches vides, ~all") {
        let report = await SPFAnalyzer.analyze("exemple.ca", client: weakFixture())
        try expectEqual(report.totalLookups, 11, "a + mx + 4 include + 3 include imbriqués + exists + a:")
        try expect(report.isPermError, "plus de 10 recherches = permerror")
        try expect(report.findings.contains { $0.status == .error && $0.title.hasPrefix("11 recherches DNS") }, "constat de dépassement")
        try expectEqual(report.allQualifier, "~", "règle finale ~all")
        try expectEqual(report.nodes.count, 8, "racine + 7 enregistrements inclus")
        try expectEqual(report.nodes[0].subtreeLookups, 11, "total à la racine")
        try expectEqual(report.nodes.first { $0.domain == "spf.envoi-a.test" }?.subtreeLookups, 1, "son include (le sien compte à la racine)")
        try expectEqual(report.recordCount, 1, "un seul v=spf1 malgré deux TXT")
        try expectEqual(report.summary, "11 recherches DNS · ~all", "résumé")
    }

    suite.add("SPF : boucle d’include, include sans SPF, +all, redirect et recherches vides") {
        let loop = MailDNSFixture(records: [
            "a.test|TXT": ["v=spf1 include:b.test -all"],
            "b.test|TXT": ["v=spf1 include:a.test -all"],
        ])
        let looped = await SPFAnalyzer.analyze("a.test", client: loop)
        try expect(looped.findings.contains { $0.title == "Boucle d’include" }, "boucle détectée")
        try expect(looped.nodes.contains { $0.problem == "boucle" }, "nœud marqué")

        let missing = MailDNSFixture(records: ["c.test|TXT": ["v=spf1 include:inexistant.test +all"]])
        let broken = await SPFAnalyzer.analyze("c.test", client: missing)
        try expect(broken.findings.contains { $0.status == .error && $0.title.contains("inexistant.test sans SPF") }, "include sans SPF")
        try expect(broken.findings.contains { $0.title.contains("+all") && $0.status == .error }, "+all en erreur")
        try expectEqual(broken.voidLookups, 1, "include vers un nom inexistant = recherche vide")

        let redirect = MailDNSFixture(records: [
            "d.test|TXT": ["v=spf1 redirect=_spf.d.test"],
            "_spf.d.test|TXT": ["v=spf1 ip4:192.0.2.1 -all"],
        ])
        let redirected = await SPFAnalyzer.analyze("d.test", client: redirect)
        try expectEqual(redirected.allQualifier, "-", "règle finale du domaine visé par redirect")
        try expectEqual(redirected.totalLookups, 1, "redirect coûte une recherche")
        try expect(redirected.status == .ok, "SPF valide")

        let voids = MailDNSFixture(records: ["e.test|TXT": ["v=spf1 a:x1.e.test a:x2.e.test mx:x3.e.test ?all"]])
        let voided = await SPFAnalyzer.analyze("e.test", client: voids)
        try expectEqual(voided.voidLookups, 3, "trois noms sans réponse")
        try expect(voided.findings.contains { $0.title.contains("recherches vides") }, "limite de 2 recherches vides")
        try expect(voided.findings.contains { $0.title.contains("?all") && $0.status == .warning }, "?all neutre")

        let none = await SPFAnalyzer.analyze("rien.test", client: MailDNSFixture())
        try expect(none.record == nil && none.status == .error, "aucun SPF = erreur")

        let two = MailDNSFixture(records: ["f.test|TXT": ["v=spf1 -all", "v=spf1 mx -all"]])
        let doubled = await SPFAnalyzer.analyze("f.test", client: two)
        try expect(doubled.findings.contains { $0.title == "2 enregistrements SPF" }, "deux SPF = permerror")

        let failing = MailDNSFixture(failures: ["g.test|TXT": "délai dépassé"])
        let failed = await SPFAnalyzer.analyze("g.test", client: failing)
        try expect(failed.queryFailed && failed.status == .warning, "échec de requête : avertissement, pas erreur")
    }

    suite.add("DMARC : politique, pourcentage, rua/ruf, alignements et fautes de syntaxe") {
        let ok = DMARCRecord.parse("v=DMARC1; p=quarantine; sp=reject; pct=50; rua=mailto:a@exemple.ca,mailto:b@rapports.test!10m; ruf=mailto:c@exemple.ca; adkim=s; aspf=r; fo=1:d; ri=3600")
        try expect(ok.errors.isEmpty, "aucune faute\u{00A0}: \(ok.errors)")
        try expectEqual(ok.policy, "quarantine", "p")
        try expectEqual(ok.subdomainPolicy, "reject", "sp")
        try expectEqual(ok.percent, 50, "pct")
        try expectEqual(ok.rua, ["a@exemple.ca", "b@rapports.test"], "rua sans la taille !10m")
        try expectEqual(ok.adkim, "s", "adkim")
        try expect(!ok.isEnforced, "pct=50 n’est pas une application complète")

        let bad = DMARCRecord.parse("p=reject; v=DMARC1; pct=150; rua=dmarc@exemple.ca; adkim=x; p=none; zz=1")
        try expect(bad.errors.contains { $0.contains("commencer par « v=DMARC1 »") }, "v= en premier")
        try expect(bad.errors.contains { $0.contains("pct=150") }, "pct hors bornes")
        try expect(bad.errors.contains { $0.contains("dmarc@exemple.ca") }, "rua sans mailto:")
        try expect(bad.errors.contains { $0.contains("adkim=x") }, "adkim invalide")
        try expect(bad.errors.contains { $0.contains("deux fois") }, "clé en double")
        try expect(bad.warnings.contains { $0.contains("zz=") }, "étiquette inconnue")
        try expect(DMARCRecord.parse("v=DMARC1; rua=mailto:a@b.ca").errors.contains { $0.contains("obligatoire") }, "p= obligatoire")
        try expect(DMARCRecord.parse("v=dmarc1; p=none").errors.contains { $0.contains("majuscules") }, "DMARC1 en majuscules")
    }

    suite.add("DMARC : p=none, héritage du domaine organisationnel, autorisation des rapports externes") {
        let weak = await DMARCAnalyzer.analyze("exemple.ca", client: weakFixture())
        try expectEqual(weak.status, .warning, "p=none = avertissement")
        try expect(weak.findings.contains { $0.title.contains("none") }, "constat p=none")
        try expectEqual(weak.summary, "p=none · rua 1", "résumé")

        let fixture = MailDNSFixture(records: [
            "_dmarc.exemple.ca|TXT": ["v=DMARC1; p=reject; sp=quarantine; rua=mailto:dmarc@exemple.ca,mailto:x@analyse.test,mailto:y@refus.test"],
            "exemple.ca._report._dmarc.analyse.test|TXT": ["v=DMARC1"],
            "refus.test|TXT": ["autre"],
        ])
        let inherited = await DMARCAnalyzer.analyze("ventes.exemple.ca", client: fixture)
        try expect(inherited.inherited, "hérité de exemple.ca")
        try expectEqual(inherited.location, "_dmarc.exemple.ca", "emplacement")
        try expect(inherited.findings.contains { $0.title == "Politique « quarantine »" }, "sp=quarantine appliqué au sous-domaine")
        try expect(inherited.findings.contains { $0.title.contains("analyse.test autorisés") }, "rapports externes autorisés")
        try expect(inherited.findings.contains { $0.title.contains("refus.test non autorisés") }, "rapports externes non autorisés")

        let none = await DMARCAnalyzer.analyze("rien.test", client: MailDNSFixture())
        try expect(none.record == nil && none.status == .error, "aucun DMARC = erreur")
    }

    suite.add("DKIM : taille de clé (DER), Ed25519, clé révoquée, mode test") {
        try expectEqual(DKIMKey.parse("v=DKIM1; k=rsa; p=\(MailKeys.rsa512)").bits, 512, "RSA 512")
        try expectEqual(DKIMKey.parse("v=DKIM1; p=\(MailKeys.rsa1024)").bits, 1024, "RSA 1024 (k=rsa par défaut)")
        try expectEqual(DKIMKey.parse("v=DKIM1; k=rsa; p=\(MailKeys.rsa2048)").bits, 2048, "RSA 2048")
        try expectEqual(DKIMKey.parse("p=\(MailKeys.pkcs1_1024)").bits, 1024, "RSAPublicKey nu (PKCS #1)")
        try expectEqual(DKIMKey.parse("v=DKIM1; k=ed25519; p=\(MailKeys.ed25519)").bits, 256, "Ed25519")
        let split = DKIMKey.parse("v=DKIM1; k=rsa; p=\(MailKeys.rsa2048.prefix(100)) \(MailKeys.rsa2048.dropFirst(100))")
        try expectEqual(split.bits, 2048, "clé coupée par une espace (TXT en plusieurs chaînes)")
        let revoked = DKIMKey.parse("v=DKIM1; k=rsa; p=")
        try expect(revoked.revoked && revoked.errors.isEmpty, "p= vide = révoquée")
        let testing = DKIMKey.parse("v=DKIM1; t=y; p=\(MailKeys.rsa2048)")
        try expect(testing.testing, "t=y")
        try expect(!DKIMKey.parse("v=DKIM1; k=dsa; p=AAAA").errors.isEmpty, "type inconnu")
        try expect(!DKIMKey.parse("v=DKIM1; p=@@@").errors.isEmpty, "base64 invalide")
        try expect(!DKIMKey.parse("v=DKIM1; k=rsa").errors.isEmpty, "p= obligatoire")
        try expectEqual(DKIMAnalyzer.findings(for: DKIMKey.parse("p=\(MailKeys.rsa512)"), selector: "x").first?.status, .error, "512 bits = erreur")
        try expectEqual(DKIMAnalyzer.findings(for: DKIMKey.parse("p=\(MailKeys.rsa1024)"), selector: "x").first?.status, .warning, "1024 bits = avertissement")
        try expectEqual(DKIMAnalyzer.findings(for: DKIMKey.parse("p=\(MailKeys.rsa2048)"), selector: "x").first?.status, .ok, "2048 bits = OK")
        try expect(DKIMAnalyzer.commonSelectors.contains("selector1") && DKIMAnalyzer.commonSelectors.contains("google")
                   && DKIMAnalyzer.commonSelectors.contains("k1"), "sélecteurs courants")
    }

    suite.add("DKIM : essai des sélecteurs courants (requêtes réparties)") {
        let fixture = strongFixture()
        let report = await DKIMAnalyzer.scan("parfait.ca", client: fixture)
        try expectEqual(report.found.map(\.selector).sorted(), ["s1", "s2"], "deux sélecteurs trouvés")
        try expectEqual(report.tried, DKIMAnalyzer.commonSelectors.count, "tous les sélecteurs essayés")
        try expectEqual(report.status, .ok, "clés valides")
        let queried = fixture.log.all.filter { $0.contains("._domainkey.") }
        try expectEqual(Set(queried).count, DKIMAnalyzer.commonSelectors.count, "une requête par sélecteur")
        let none = await DKIMAnalyzer.scan("rien.test", selectors: ["a", "b"], client: MailDNSFixture())
        try expect(none.found.isEmpty && none.status == .warning, "aucun sélecteur = avertissement")
        let custom = await DKIMAnalyzer.scan("exemple.ca", selectors: ["SELECTOR1", "selector1", "mauvais nom"], client: weakFixture())
        try expectEqual(custom.tried, 1, "sélecteurs dédoublonnés, nom invalide écarté")
    }

    suite.add("BIMI, MTA-STS et TLS-RPT : lecture et constats") {
        let bimi = BIMIRecord.parse("v=BIMI1; l=http://exemple.ca/logo.png;")
        try expectEqual(bimi.errors.count, 2, "logo en HTTP et pas en SVG")
        try expect(BIMIRecord.parse("v=BIMI1; l=https://exemple.ca/l.svg; a=https://exemple.ca/vmc.pem").errors.isEmpty, "BIMI valide")

        let policy = MTASTSPolicy.parse("version: STSv1\r\nmode: enforce\r\nmx: mx1.exemple.ca\r\nmx: *.mail.protection.outlook.com\r\nmax_age: 604800\r\n")
        try expect(policy.errors.isEmpty, "politique valide")
        try expectEqual(policy.mx.count, 2, "deux lignes mx")
        try expect(policy.covers("exemple-ca.mail.protection.outlook.com"), "motif * sur une étiquette")
        try expect(!policy.covers("a.b.mail.protection.outlook.com"), "motif * sur une seule étiquette")
        try expect(policy.covers("MX1.exemple.ca."), "nom exact, casse et point final ignorés")
        try expect(!policy.covers("mx2.exemple.ca"), "nom non couvert")
        let badPolicy = MTASTSPolicy.parse("version: STSv2\nmode: strict\n")
        try expectEqual(badPolicy.errors.count, 4, "version, mode, max_age et mx")

        let tls = TLSRPTRecord.parse("v=TLSRPTv1; rua=mailto:tls@exemple.ca,https://rapports.exemple.ca/tls")
        try expect(tls.errors.isEmpty && tls.rua.count == 2, "TLS-RPT valide")
        try expect(!TLSRPTRecord.parse("v=TLSRPTv1; rua=ftp://x").errors.isEmpty, "rua invalide")

        let strong = strongFixture()
        let mta = await MailPolicyAnalyzer.mtaSTS("parfait.ca", mxHosts: ["mx.parfait.ca", "autre.parfait.ca"], client: strong)
        try expect(mta.policy?.mode == "enforce", "politique lue par HTTPS (fixe)")
        try expect(mta.findings.contains { $0.title == "MX autre.parfait.ca hors politique" }, "MX non couvert")
        let missingFile = await MailPolicyAnalyzer.mtaSTS("exemple.ca", mxHosts: [],
                                                          client: MailDNSFixture(records: ["_mta-sts.exemple.ca|TXT": ["v=STSv1; id=1"]]))
        try expect(missingFile.findings.contains { $0.title == "Fichier de politique inaccessible" }, "fichier absent")
        let absent = await MailPolicyAnalyzer.mtaSTS("exemple.ca", mxHosts: [], client: weakFixture())
        try expectEqual(absent.status, .warning, "MTA-STS absent = avertissement")
        let bimiReport = await MailPolicyAnalyzer.bimi("parfait.ca", dmarc: DMARCRecord.parse("v=DMARC1; p=none"), client: strong)
        try expect(bimiReport.findings.contains { $0.title.contains("pas assez strict") }, "BIMI exige DMARC appliqué")
    }

    suite.add("MX : priorités, adresses, PTR confirmé ou incohérent, MX nul, A implicite") {
        let report = await MXLookup.run("exemple.ca", client: weakFixture())
        try expectEqual(report.hosts.map(\.host), ["mx1.exemple.ca", "mx2.exemple.ca"], "tri par priorité")
        try expectEqual(report.hosts.map(\.priority), [10, 20], "priorités")
        let first = report.hosts[0].addresses[0]
        try expect(first.ptr == "mx1.exemple.ca" && first.forwardConfirmed && first.matchesHost, "PTR identique au MX")
        let second = report.hosts[1].addresses[0]
        try expect(second.ptr == "serveur26.hebergeur.test" && !second.forwardConfirmed, "PTR qui ne revient pas à l’adresse")
        try expectEqual(report.hosts[1].status, .warning, "incohérence = avertissement")
        try expectEqual(report.allIPv4, ["203.0.113.25", "203.0.113.26"], "adresses dans l’ordre")

        let null = await MXLookup.run("rien.test", client: MailDNSFixture(records: ["rien.test|MX": ["0 ."]]))
        try expect(null.nullMX && null.status == .info, "MX nul")
        let implicit = await MXLookup.run("web.test", client: MailDNSFixture(records: ["web.test|A": ["192.0.2.80"]]))
        try expect(implicit.hosts.isEmpty && implicit.implicitA == ["192.0.2.80"] && implicit.status == .warning, "A implicite")
        let missing = await MXLookup.run("absent.test", client: MailDNSFixture())
        try expect(missing.status == .error && missing.findings.first?.title == "Domaine inexistant", "NXDOMAIN")
    }

    suite.add("Listes noires : adresse inversée, noms interrogés, codes de retour expliqués") {
        let ip = IPv4Address("203.0.113.25")!
        try expectEqual(DNSBL.reversed(ip), "25.113.0.203", "adresse inversée")
        let zen = DNSBLCatalog.all.first { $0.zone == "zen.spamhaus.org" }!
        let dbl = DNSBLCatalog.all.first { $0.zone == "dbl.spamhaus.org" }!
        try expectEqual(DNSBL.queryName(.ip(ip), list: zen), "25.113.0.203.zen.spamhaus.org", "nom pour une IP")
        try expectEqual(DNSBL.queryName(.domain("Exemple.CA."), list: dbl), "exemple.ca.dbl.spamhaus.org", "nom pour un domaine")
        try expect(DNSBL.explain(code: "127.0.0.2", list: zen).meaning.hasPrefix("SBL"), "127.0.0.2 = SBL")
        try expect(DNSBL.explain(code: "127.0.0.11", list: zen).meaning.contains("PBL"), "127.0.0.11 = PBL")
        try expect(DNSBL.explain(code: "127.255.255.254", list: zen).isRefusal, "résolveur public refusé")
        try expect(DNSBL.explain(code: "127.0.1.255", list: dbl).isRefusal, "DBL interrogée avec une IP")
        try expect(DNSBL.explain(code: "93.184.216.34", list: zen).isRefusal, "réponse hors 127/8 = joker DNS")
        try expectEqual(DNSBL.classify(.nxdomain, list: zen), .clean, "NXDOMAIN = absent")
        try expectEqual(DNSBL.classify(MailDNSAnswer(outcome: .answer, values: ["127.0.0.4", "127.0.0.10"]), list: zen),
                        .listed(["127.0.0.10", "127.0.0.4"]), "plusieurs codes")
        if case .refused = DNSBL.classify(MailDNSAnswer(outcome: .answer, values: ["127.255.255.254"]), list: zen) {} else {
            throw TestFailure(message: "code de refus non reconnu", file: #fileID, line: #line)
        }
        if case .failed = DNSBL.classify(.failure("délai"), list: zen) {} else {
            throw TestFailure(message: "échec non reconnu", file: #fileID, line: #line)
        }
        try expect(DNSBLCatalog.all.count >= 20, "au moins 20 listes")
        try expect(DNSBLCatalog.lists(for: .domain).count >= 4 && DNSBLCatalog.lists(for: .ip).count >= 14, "listes IP et domaine")
        try expect(!DNSBLCatalog.active.contains { $0.zone == "dnsbl.sorbs.net" }, "SORBS fermée, pas interrogée")
        try expect(DNSBLCatalog.active.allSatisfy { $0.removalURL?.hasPrefix("https://") ?? false }, "lien de retrait en HTTPS")
    }

    suite.add("Listes noires : vérification limitée, adresse privée non interrogée, raison TXT") {
        let fixture = weakFixture()
        let report = await DNSBL.check([.ip(IPv4Address("203.0.113.20")!), .ip(IPv4Address("192.168.1.10")!), .domain("exemple.ca")],
                                       client: fixture, concurrency: 3, spacing: 0)
        let ipLists = DNSBLCatalog.lists(for: .ip).count
        let domainLists = DNSBLCatalog.lists(for: .domain).count
        try expectEqual(report.results.count, ipLists * 2 + domainLists, "une ligne par liste et par cible")
        try expectEqual(report.listed.count, 1, "une inscription")
        try expectEqual(report.listed.first?.reason, "https://check.spamhaus.org/sbl/query/SBL123", "raison lue en TXT")
        try expectEqual(report.status, .error, "liste majeure = erreur")
        let skipped = report.results.filter { if case .skipped = $0.state { return true }; return false }
        try expectEqual(skipped.count, ipLists, "adresse privée non interrogée")
        try expect(!fixture.log.all.contains { $0.contains("10.1.168.192") }, "aucune requête pour 192.168.1.10")
        try expect(report.findings.first?.fix?.contains("check.spamhaus.org") == true, "lien de retrait")
    }

    suite.add("Santé courriel : note du domaine mal configuré et du domaine modèle") {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let weak = await MailHealth.run("exemple.ca", client: weakFixture(), date: date)
        let checks = Dictionary(uniqueKeysWithValues: weak.summary.checks.map { ($0.category, $0) })
        try expectEqual(checks[.spf]?.points, 0, "SPF à 11 recherches = 0")
        try expectEqual(checks[.dmarc]?.points, 8, "p=none avec rua = 8")
        try expectEqual(checks[.dkim]?.points, 10, "clé de 1024 bits = 10")
        try expectEqual(checks[.mx]?.points, 10, "PTR incohérent = 10")
        try expectEqual(checks[.blacklist]?.points, 0, "inscrit chez Spamhaus = 0")
        try expectEqual(checks[.mtasts]?.points, 0, "MTA-STS absent")
        try expectEqual(checks[.dnssec]?.points, 0, "zone non signée")
        try expectEqual(weak.summary.score, 28, "28/100 = (10 + 0 + 8 + 10 + 0 + 0 + 0 + 0) / 100")
        try expectEqual(weak.summary.grade, .poor, "à corriger")
        try expect(weak.summary.recommendations.first?.status == .error, "recommandations du plus grave au moins grave")
        try expect(weak.summary.recommendations.contains { $0.title.hasPrefix("11 recherches DNS") }, "recommandation SPF")
        try expectEqual(weak.summary.date, date, "date du bilan")

        let strong = await MailHealth.run("parfait.ca", client: strongFixture())
        try expectEqual(strong.summary.score, 100, "domaine modèle = 100")
        try expectEqual(strong.summary.grade, .good, "bon")
        try expectEqual(strong.dnssec, .signed, "DNSSEC")
        try expect(strong.summary.checks.first { $0.category == .bimi }?.status == .ok, "BIMI publié")
        let targets = MailHealth.blacklistTargets("parfait.ca", mx: strong.mx, spf: strong.spf)
        try expectEqual(targets, [.domain("parfait.ca"), .ip(IPv4Address("198.51.100.7")!)], "domaine et adresse du MX, sans doublon")
    }

    suite.add("Santé courriel : une requête qui échoue ne pénalise pas la note") {
        var fixture = strongFixture()
        fixture.failures = ["parfait.ca|MX": "SERVFAIL"]
        let report = await MailHealth.run("parfait.ca", client: fixture)
        let mx = report.summary.checks.first { $0.category == .mx }
        try expect(mx?.points == nil && mx?.status == .info, "MX non vérifié : hors note")
        try expectEqual(report.summary.score, 100, "note ramenée aux catégories vérifiées")
    }

    suite.add("Super outil : reconnaissance de la saisie") {
        try expectEqual(MailInput.classify("  Ventes <ventes@Exemple.CA> ").kind, .email, "adresse entre chevrons")
        try expectEqual(MailInput.classify("ventes@Exemple.CA").value, "ventes@exemple.ca", "domaine en minuscules")
        try expectEqual(MailInput.classify("mailto:a@b.ca").kind, .email, "mailto:")
        try expectEqual(MailInput.classify("203.0.113.5").kind, .ip, "adresse IP")
        let url = MailInput.classify("https://www.exemple.ca:8443/contact?x=1")
        try expect(url.kind == .domain && url.value == "www.exemple.ca", "adresse Web réduite au nom")
        try expectEqual(MailInput.classify("exemple.ca.").value, "exemple.ca", "point final retiré")
        try expectEqual(MailInput.classify("pas un domaine").kind, .invalid, "espaces")
        try expectEqual(MailInput.classify("a@@b.ca").kind, .invalid, "deux @")
        try expectEqual(MailInput.classify("localhost").kind, .invalid, "nom sans point")
        try expectEqual(MailInput.classify("1.2.3").kind, .invalid, "IP incomplète")
    }

    suite.add("Super outil : adresse courriel, domaine, nom d’hôte et IP") {
        let fixture = weakFixture()
        let email = await MailSuperTool.run("info@exemple.ca", client: fixture)
        try expectEqual(email.kind, .email, "adresse courriel")
        try expectEqual(email.target, "exemple.ca", "domaine vérifié")
        try expect(email.health != nil && email.checks.first?.category == .address, "bilan du domaine après l’adresse")
        try expect(email.count(.error) >= 2, "SPF et listes noires en erreur")

        var hostFixture = fixture
        hostFixture.add("smtp.exemple.ca", .a, ["203.0.113.25"])
        let host = await MailSuperTool.run("smtp.exemple.ca", client: hostFixture)
        try expectEqual(host.kind, .hostname, "ni MX ni SPF, mais une adresse = nom d’hôte")
        try expect(host.checks.contains { $0.category == .ptr && $0.status == .info }, "PTR confirmé mais autre nom")
        try expect(host.health == nil && host.blacklists != nil, "listes noires sans bilan de domaine")

        let ip = await MailSuperTool.run("203.0.113.20", client: fixture)
        try expectEqual(ip.kind, .ip, "IP")
        try expect(ip.checks.contains { $0.category == .ptr && $0.status == .warning }, "IP sans PTR")
        try expectEqual(ip.checks.first { $0.category == .blacklist }?.status, .error, "IP listée")

        let missing = await MailSuperTool.run("inconnu.test", client: fixture)
        try expectEqual(missing.status, .error, "nom introuvable")
        let invalid = await MailSuperTool.run("??", client: fixture)
        try expectEqual(invalid.kind, .invalid, "saisie invalide")
        let privateIP = await MailSuperTool.run("10.0.0.5", client: fixture)
        try expect(privateIP.blacklists == nil && privateIP.checks.first?.result == "Privée ou réservée", "IP privée")
    }

    suite.add("Courriel : explication des étiquettes") {
        let spf = MailExplain.spf(SPFRecord.parse("v=spf1 include:_spf.google.com -ip4:192.0.2.1 +all")!)
        try expectEqual(spf.count, 4, "v + 3 termes")
        try expect(spf[1].meaning.contains("_spf.google.com") && spf[2].meaning.hasPrefix("Refuse"), "include et qualificatif -")
        try expectEqual(spf[3].status, .error, "+all en erreur")
        let dmarc = MailExplain.tags(.dmarc, text: "v=DMARC1; p=none; pct=40; adkim=s")
        try expectEqual(dmarc.map(\.status), [.ok, .warning, .warning, .ok], "états des étiquettes DMARC")
        let dkim = MailExplain.tags(.dkim, text: "v=DKIM1; k=rsa; p=\(MailKeys.rsa1024)")
        try expect(dkim[2].meaning.contains("1024 bits") && dkim[2].status == .warning, "taille de clé expliquée")
        let policy = MailExplain.mtaSTSPolicy("version: STSv1\nmode: testing\nmax_age: 3600\n")
        try expectEqual(policy.map(\.status), [.ok, .warning, .warning], "politique MTA-STS")
        try expectEqual(MailRecordKind.dkim.recordName(domain: "exemple.ca", selector: "s1"), "s1._domainkey.exemple.ca", "nom DKIM")
    }

    suite.add("Rapport : section facultative « Santé courriel » (PDF, CSV, JSON, HTML)") {
        let health = await MailHealth.run("exemple.ca", client: weakFixture(), date: Date(timeIntervalSince1970: 1_793_000_000))
        try expect(!ReportTemplate.allCases.contains { $0.defaultSections.contains(.courriel) }, "aucun modèle ne la coche")
        var config = ReportConfig(template: .audit, site: "Siège", technician: "Test", date: "2026-11-04")
        config.sections = [.resume, .courriel]
        var input = ReportInput(devices: [])
        input.mailHealth = [health.summary]
        let document = ReportBuilder.build(config: config, input: input)
        let section = document.section(.courriel)
        try expectEqual(section?.heading, "2. Santé courriel", "titre numéroté")
        try expectEqual(section?.tables.count, 2, "vérifications et recommandations")
        try expectEqual(section?.tables.first?.rows.count, health.summary.checks.count, "une ligne par vérification")
        let csv = ReportExport.csv(document)
        try expect(csv.contains("Santé courriel") && csv.contains("SPF"), "CSV")
        let json = String(decoding: try ReportExport.json(document), as: UTF8.self)
        try expect(json.contains("courriel"), "JSON")
        let html = ReportExport.html(document, logoDataURL: nil)
        try expect(html.contains("28/100"), "HTML avec la note")
        let pages = ReportPaginator.paginate(document)
        try expect(pages.count >= 2, "pagination")

        input.mailHealth = []
        let empty = ReportBuilder.build(config: config, input: input)
        if case .note(let text) = empty.section(.courriel)?.blocks.first {
            try expect(text.contains("Santé courriel"), "note sans bilan")
        } else {
            throw TestFailure(message: "note attendue sans bilan", file: #fileID, line: #line)
        }
        let decoded = try JSONDecoder().decode(ReportConfig.self, from: try JSONEncoder().encode(config))
        try expect(decoded.sections.contains(.courriel), "section enregistrée dans un modèle")
    }
}
