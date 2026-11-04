import Foundation
import NetScopeCore

// Tests de l'analyse d'en-têtes de courriel (note 14) : en-têtes fixes, aucun réseau.

func registerMailHeaderTests(_ suite: TestSuite) {
    suite.add("En-têtes : dépliage, mots encodés et dates") {
        let fields = MailHeaderAnalyzer.unfold(MailHeaderFixture.legitimate)
        let received = fields.filter { $0.name == "Received" }
        try expectEqual(received.count, 3, "trois Received")
        try expect(received[1].value.hasPrefix("from mail.fournisseur.ca (mail.fournisseur.ca. [198.51.100.25]) by mx.google.com with ESMTPS"),
                   "lignes repliées jointes")
        try expect(!fields.contains { $0.name == "Corps" || $0.value.contains("Corps du message") }, "le corps est ignoré")
        try expectEqual(MailHeaderAnalyzer.decodeEncodedWords("=?UTF-8?B?RmFjdHVyZSBkZSBub3ZlbWJyZSDigJMgcsOpZsOpcmVuY2UgNDIx?="),
                        "Facture de novembre – référence 421", "Base64")
        try expectEqual(MailHeaderAnalyzer.decodeEncodedWords("=?iso-8859-1?Q?R=E9sum=E9_du_mois?= =?UTF-8?Q?_d=C3=A9cembre?="),
                        "Résumé du mois décembre", "Q, deux mots encodés accolés")
        let date = MailHeaderAnalyzer.parseDate("Tue,  3 Nov 2026 14:02:09 -0500 (EST)")
        try expectEqual(date, Date(timeIntervalSince1970: 1_793_732_529), "date avec commentaire et double espace")
        try expectEqual(MailHeaderAnalyzer.parseDate("3 Nov 2026 19:02:09 GMT"), Date(timeIntervalSince1970: 1_793_732_529), "sans jour, fuseau nommé")
        let address = MailHeaderAnalyzer.parseAddress("\"Dupont, Marie\" <Marie.Dupont@Exemple.CA>")
        try expectEqual(address?.displayName, "Dupont, Marie", "nom affiché")
        try expectEqual(address?.domain, "exemple.ca", "domaine en minuscules")
        try expectEqual(MailHeaderAnalyzer.parseAddress("info@exemple.ca (Info)")?.displayName, "Info", "nom en commentaire")
    }

    suite.add("En-têtes : message légitime, trajet et authentification") {
        let report = MailHeaderAnalyzer.analyze(MailHeaderFixture.legitimate)
        try expectEqual(report.hops.count, 3, "sauts")
        try expectEqual(report.hops.map(\.by), ["mail.fournisseur.ca", "mx.google.com", "2002:a05:6a10:8d0e:b0:4f1:2c3a:1b2"], "par")
        try expectEqual(report.hops[0].with, "ESMTPSA", "envoi authentifié")
        try expect(report.hops[0].isSubmission && report.hops[1].isEncrypted, "soumission puis TLS")
        try expectEqual(report.hops[0].fromIP, "203.0.113.77", "IP vue par le serveur, pas celle de HELO")
        try expectEqual(report.hops[1].fromIP, "198.51.100.25", "IP du deuxième saut")
        try expectEqual(report.hops[1].delay, 4, "délai du deuxième saut")
        try expectEqual(report.hops[2].delay, 1, "délai du troisième saut")
        try expectEqual(report.transit, 5, "trajet total")
        try expectEqual(report.originIP, "203.0.113.77", "IP d’origine")
        try expectEqual(report.from?.displayName, "Service de facturation Fournisseur", "From décodé")
        try expectEqual(report.subject, "Facture de novembre – référence 421", "objet décodé")
        try expectEqual(report.returnPath, "factures@fournisseur.ca", "Return-Path")
        try expectEqual(report.mailer, "Apple Mail (2.3826)", "X-Mailer")
        try expectEqual(report.auth.map(\.method), ["dkim", "spf", "dmarc"], "méthodes")
        try expect(report.auth.allSatisfy(\.isPass), "tout réussi")
        try expectEqual(report.result("dkim")?.properties["header.s"], "s2026", "sélecteur DKIM")
        try expectEqual(report.dkimSignatures.first?.domain, "fournisseur.ca", "DKIM-Signature d=")
        try expectEqual(report.verdict, .ok, "aucune alerte : \(report.findings.filter { $0.level > .ok }.map(\.title))")
    }

    suite.add("En-têtes : hameçonnage (sosie, nom trompeur, DMARC en échec)") {
        let report = MailHeaderAnalyzer.analyze(MailHeaderFixture.phishing)
        let titles = report.findings.map(\.title)
        try expectEqual(report.verdict, .critical, "verdict")
        try expect(titles.contains("DMARC en échec"), "DMARC")
        try expect(titles.contains("Domaine sosie"), "sosie de paypal.com")
        try expect(titles.contains("Nom affiché trompeur"), "adresse dans le nom affiché")
        try expect(titles.contains("SPF douteux (softfail)"), "SPF")
        try expect(titles.contains("Enveloppe (Return-Path) ≠ From"), "enveloppe")
        try expect(titles.contains("Reply-To vers un autre domaine"), "Reply-To")
        try expect(titles.contains { $0.hasPrefix("Envoyé par un script") }, "PHPMailer")
        try expect(titles.contains("Message-ID d’un autre domaine"), "Message-ID")
        // L'en-tête Authentication-Results plus bas (ajouté avant la réception) n'est pas cru.
        try expectEqual(report.result("dmarc")?.result, "fail", "seul le vérificateur du destinataire compte")
        try expectEqual(report.result("dmarc")?.authority, "mx.exemple.ca", "autorité")
        try expectEqual(report.originIP, "203.0.113.200", "IP d’origine")
        try expectEqual(report.hops.first?.from, "vps-4471.hebergeur-pas-cher.net", "premier serveur")
        try expectEqual(report.findings.first?.level, .critical, "critique en tête")
    }

    suite.add("En-têtes : Authentication-Results de Microsoft (sans authserv-id) et Received-SPF") {
        let microsoft = MailHeaderAnalyzer.authenticationResults([
            MailHeaderField(name: "Authentication-Results", value: "spf=pass (sender IP is 198.51.100.7) smtp.mailfrom=exemple.ca; "
                            + "dkim=pass (signature was verified) header.d=exemple.ca;dmarc=pass action=none header.from=exemple.ca;compauth=pass reason=100"),
        ])
        try expectEqual(microsoft.map(\.method), ["spf", "dkim", "dmarc", "compauth"], "méthodes")
        try expectEqual(microsoft[2].properties["action"], "none", "action DMARC")
        try expectEqual(microsoft[0].authority, nil, "pas d’autorité")
        let receivedSPF = MailHeaderAnalyzer.authenticationResults([
            MailHeaderField(name: "Received-SPF", value: "Fail (protection.outlook.com: domain of exemple.ca does not designate 203.0.113.9 as permitted sender) receiver=protection.outlook.com; client-ip=203.0.113.9; envelope-from=x@exemple.ca"),
        ])
        try expectEqual(receivedSPF.first?.result, "fail", "Received-SPF")
        try expectEqual(receivedSPF.first?.properties["smtp.mailfrom"], "x@exemple.ca", "enveloppe")
    }

    suite.add("En-têtes : domaines sosies et domaine organisationnel") {
        try expectEqual(MailHeaderAnalyzer.imitatedBrand("paypa1-secure.com")?.official, "paypal.com", "1 au lieu de l")
        try expectEqual(MailHeaderAnalyzer.imitatedBrand("rnicrosoft.com")?.official, "microsoft.com", "rn au lieu de m")
        try expectEqual(MailHeaderAnalyzer.imitatedBrand("amazom.ca")?.official, "amazon.com", "une lettre de différence")
        try expectEqual(MailHeaderAnalyzer.imitatedBrand("desjardins-alerte.com")?.official, "desjardins.com", "marque + mot")
        try expect(MailHeaderAnalyzer.imitatedBrand("paypal.com") == nil, "domaine officiel")
        try expect(MailHeaderAnalyzer.imitatedBrand("bounce.mail.paypal.com") == nil, "sous-domaine officiel")
        try expect(MailHeaderAnalyzer.imitatedBrand("exemple.ca") == nil, "domaine ordinaire")
        try expect(MailHeaderAnalyzer.imitatedBrand("td-architectes.ca") == nil, "sigle court ignoré")
        try expect(MailHeaderAnalyzer.areLookalikes("exemple.ca", "exernple.ca"), "rn/m entre deux domaines")
        try expect(MailHeaderAnalyzer.areLookalikes("groupe-exemple.ca", "groupe-exemp1e.ca"), "1/l")
        try expect(!MailHeaderAnalyzer.areLookalikes("mail.exemple.ca", "exemple.ca"), "même domaine organisationnel")
        try expectEqual(MailHeaderAnalyzer.organizationalDomain("bounces.mail.exemple.ca"), "exemple.ca", "deux étiquettes")
        try expectEqual(MailHeaderAnalyzer.organizationalDomain("courriel.ville.montreal.qc.ca"), "montreal.qc.ca", "suffixe provincial")
        try expectEqual(MailHeaderAnalyzer.organizationalDomain("news.bbc.co.uk"), "bbc.co.uk", "suffixe britannique")
    }

    suite.add("En-têtes : texte vide ou sans Received") {
        let empty = MailHeaderAnalyzer.analyze("")
        try expect(empty.fields.isEmpty && empty.hops.isEmpty, "rien")
        try expect(empty.findings.contains { $0.title == "Aucun champ From" }, "From manquant")
        let minimal = MailHeaderAnalyzer.analyze("From: a@exemple.ca\nSubject: Test\n")
        try expect(minimal.findings.contains { $0.title == "Aucun en-tête Received" }, "Received manquant")
        try expect(minimal.findings.contains { $0.title == "Aucun Message-ID" }, "Message-ID manquant")
    }
}

enum MailHeaderFixture {
    static let legitimate = """
    Delivered-To: dany@exemple.ca
    Received: by 2002:a05:6a10:8d0e:b0:4f1:2c3a:1b2 with SMTP id k14csp1234567pxb;
            Tue, 3 Nov 2026 11:02:14 -0800 (PST)
    Received: from mail.fournisseur.ca (mail.fournisseur.ca. [198.51.100.25])
            by mx.google.com with ESMTPS id x12si123456qtb.45.2026.11.03.11.02.13
            for <dany@exemple.ca>
            (version=TLS1_3 cipher=TLS_AES_256_GCM_SHA384 bits=256/256);
            Tue, 03 Nov 2026 11:02:13 -0800 (PST)
    Received: from [192.168.1.40] (unknown [203.0.113.77])
    \tby mail.fournisseur.ca (Postfix) with ESMTPSA id 4F2A1C0123
    \tfor <dany@exemple.ca>; Tue,  3 Nov 2026 14:02:09 -0500 (EST)
    Authentication-Results: mx.google.com;
           dkim=pass header.i=@fournisseur.ca header.s=s2026 header.b=AbCdEf12;
           spf=pass (google.com: domain of factures@fournisseur.ca designates 198.51.100.25 as permitted sender) smtp.mailfrom=factures@fournisseur.ca;
           dmarc=pass (p=QUARANTINE sp=QUARANTINE dis=NONE) header.from=fournisseur.ca
    Return-Path: <factures@fournisseur.ca>
    DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=fournisseur.ca; s=s2026;
    \th=from:to:subject:date; bh=abc=; b=def=
    From: =?UTF-8?Q?Service_de_facturation_Fournisseur?= <factures@fournisseur.ca>
    To: Dany <dany@exemple.ca>
    Subject: =?UTF-8?B?RmFjdHVyZSBkZSBub3ZlbWJyZSDigJMgcsOpZsOpcmVuY2UgNDIx?=
    Date: Tue, 3 Nov 2026 14:02:08 -0500
    Message-ID: <20261103190208.4F2A1C0123@mail.fournisseur.ca>
    X-Mailer: Apple Mail (2.3826)
    MIME-Version: 1.0

    Corps du message.
    From: pas un en-tête
    """

    static let phishing = """
    Received: from mx.exemple.ca (mx.exemple.ca [192.0.2.10])
    \tby boite.exemple.ca (Postfix) with ESMTPS id 9A1B2C3D4E
    \tfor <dany@exemple.ca>; Wed, 4 Nov 2026 08:15:42 -0500 (EST)
    Received: from vps-4471.hebergeur-pas-cher.net (vps-4471.hebergeur-pas-cher.net [203.0.113.200])
    \tby mx.exemple.ca (Postfix) with ESMTP id 1F2E3D4C5B
    \tfor <dany@exemple.ca>; Wed, 4 Nov 2026 08:15:40 -0500 (EST)
    Authentication-Results: mx.exemple.ca;
    \tspf=softfail (domain of transitioning bounce@hebergeur-pas-cher.net) smtp.mailfrom=bounce@hebergeur-pas-cher.net;
    \tdkim=none;
    \tdmarc=fail (p=reject dis=none) header.from=paypa1-secure.com
    Authentication-Results: verificateur.paypa1-secure.com; dmarc=pass header.from=paypa1-secure.com
    Return-Path: <bounce@hebergeur-pas-cher.net>
    From: "PayPal Service <service@paypal.com>" <alerte@paypa1-secure.com>
    Reply-To: securite.compte@soutien-clients.co
    To: dany@exemple.ca
    Subject: Votre compte est suspendu
    Date: Wed, 4 Nov 2026 13:15:39 +0000
    Message-ID: <a1b2c3@vps-4471.hebergeur-pas-cher.net>
    X-Mailer: PHPMailer 6.8.1 (https://github.com/PHPMailer/PHPMailer)
    """
}
