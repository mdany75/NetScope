import Foundation
import NetScopeCore

/// Démonstration des outils courriel (`--demo`) : réponses DNS fixes du domaine d’exemple
/// exemple.ca (Microsoft 365, SPF à 11 recherches, DMARC p=none, une clé DKIM de 1024 bits,
/// pas de MTA-STS) et d'un ancien relais inscrit dans deux listes noires. Aucun accès réseau : les
/// vrais analyseurs de NetScopeCore/MailDNS tournent sur ces réponses.
enum MailDemo {
    static let domain = "exemple.ca"
    static let superInput = "ventes@exemple.ca"
    /// Ancien relais d'envoi (Listes noires).
    static let blacklistIP = "198.51.100.30"

    static let key2048 = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxttdQl5OmtV5KKurqGm/+jAQpruHNDAGzMRfHvEpBgA/nfgu5Jm8MtLxhh4NOFv+ZU4Mpsq0Ss4bWqF9BLGuDE4UQs4cuPXMr3gNdnUoNajWatBWk1RaosEbGsL7BetCJUZPiLOgVZ88d31IByAbmqwO7h4tU1y7uR0tCdPtxa59+Qo7RzBU9LqVj9nfo/XRhkjz8hq0HPM3DNbyHjW0jUMiQuFEqPQD1ocIY4XNN6gOySZz0qn2LL1HHoit2genzQN0XNcqJrE3Cd9kYZPAWeE5YxTw4b6YzpAiVNmfgByZEZ2AdVJJVKY1GfToO9mxMKcWvK1qkHDAV88W0G3TgwIDAQAB"
    static let key1024 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDr6vp2zIZL6rRy5CGDPyRdiSjOt42fln4m8wJCQCnpoEcAwNkV/4ruPV9LtC00xq1RBsyhqteIJ8jE48K6Z9oNh/Z2agAu1JWhWXvgNqluAtaoueQknD51rSy6JYm9Jx8Iq3YZQN7k9A1o9dhgxU7wXTuTtkFCLxhKHUoJ0eac5QIDAQAB"

    static let client: MailDNSFixture = {
        var records: [String: [String]] = [
            // Domaine : site Web, Microsoft 365 en réception.
            "exemple.ca|A": ["198.51.100.10"],
            "exemple.ca|MX": ["0 exemple-ca.mail.protection.outlook.com."],
            "exemple.ca|TXT": [
                "v=spf1 a mx include:spf.protection.outlook.com include:_spf.salesforce.com include:servers.mcsv.net include:sendgrid.net include:_spf.exemple.ca ~all",
                "MS=ms48213377",
                "google-site-verification=K3q9Vt0bXy7pLr2mNcH5sJd8fQe1wZa4uIo6gT0kB2E",
            ],
            "exemple-ca.mail.protection.outlook.com|A": ["52.101.68.12", "52.101.68.6"],
            "12.68.101.52.in-addr.arpa|PTR": ["mail-yqbcan01on2112.inbound.protection.outlook.com."],
            "mail-yqbcan01on2112.inbound.protection.outlook.com|A": ["52.101.68.12"],
            "6.68.101.52.in-addr.arpa|PTR": ["mail-yqbcan01on2106.inbound.protection.outlook.com."],
            "mail-yqbcan01on2106.inbound.protection.outlook.com|A": ["52.101.68.6"],
            // SPF : chaîne d'include (11 recherches).
            "spf.protection.outlook.com|TXT": ["v=spf1 ip4:40.92.0.0/15 ip4:40.107.0.0/16 ip4:52.100.0.0/15 ip4:52.102.0.0/16 ip4:104.47.0.0/17 ip6:2a01:111:f400::/48 ip6:2a01:111:f403::/49 include:spfd.protection.outlook.com -all"],
            "spfd.protection.outlook.com|TXT": ["v=spf1 ip4:51.4.72.0/24 ip4:51.5.72.0/24 ip4:51.5.80.0/27 -all"],
            "_spf.salesforce.com|TXT": ["v=spf1 exists:%{i}._spf.mta.salesforce.com -all"],
            "servers.mcsv.net|TXT": ["v=spf1 ip4:205.201.128.0/20 ip4:198.2.128.0/18 ip4:148.105.8.0/21 -all"],
            "sendgrid.net|TXT": ["v=spf1 ip4:167.89.0.0/17 ip4:208.117.48.0/20 ip4:50.31.32.0/19 ip4:198.37.144.0/20 ip4:198.21.0.0/21 ip4:192.254.112.0/20 ip4:168.245.0.0/17 ip4:149.72.0.0/16 include:ab.sendgrid.net ~all"],
            "ab.sendgrid.net|TXT": ["v=spf1 ip4:159.183.192.0/18 ~all"],
            "_spf.exemple.ca|TXT": ["v=spf1 ip4:198.51.100.20 ip4:198.51.100.21 a:relais.exemple.ca -all"],
            "relais.exemple.ca|A": ["198.51.100.22"],
            "20.100.51.198.in-addr.arpa|PTR": ["relais1.exemple.ca."],
            "relais1.exemple.ca|A": ["198.51.100.20"],
            // DMARC en surveillance, rapports d'échec chez un service externe autorisé.
            "_dmarc.exemple.ca|TXT": ["v=DMARC1; p=none; rua=mailto:dmarc@exemple.ca; ruf=mailto:ruf@rapports.dmarcian.com; fo=1"],
            "exemple.ca._report._dmarc.rapports.dmarcian.com|TXT": ["v=DMARC1"],
            // DKIM de Microsoft 365 : selector1 en 2048 bits, selector2 resté en 1024 bits.
            "selector1._domainkey.exemple.ca|TXT": ["v=DKIM1; k=rsa; p=\(key2048)"],
            "selector2._domainkey.exemple.ca|TXT": ["v=DKIM1; k=rsa; p=\(key1024)"],
            // Ancien relais : PTR générique et deux inscriptions.
            "30.100.51.198.in-addr.arpa|PTR": ["198-51-100-30.static.fournisseur-internet.ca."],
            "198-51-100-30.static.fournisseur-internet.ca|A": ["198.51.100.30"],
            "30.100.51.198.b.barracudacentral.org|A": ["127.0.0.2"],
            "30.100.51.198.b.barracudacentral.org|TXT": ["http://www.barracudanetworks.com/reputation/?pr=1&ip=198.51.100.30"],
            "30.100.51.198.all.spamrats.com|A": ["127.0.0.37"],
            "30.100.51.198.all.spamrats.com|TXT": ["SPAMRATS IP Addresses See: http://www.spamrats.com/bl?198.51.100.30"],
        ]
        // Microsoft 365 : réseau entier dans UCEPROTECT niveau 3 (courant, sans effet réel).
        for ip in ["12.68.101.52", "6.68.101.52"] {
            records["\(ip).dnsbl-3.uceprotect.net|A"] = ["127.0.0.2"]
            records["\(ip).dnsbl-3.uceprotect.net|TXT"] = ["Your ISP Microsoft Corporation/AS8075 is UCEPROTECT-Level3 listed for hosting a total of 2310 abusers."]
        }
        return MailDNSFixture(records: records)
    }()
}
