import Foundation
import NetScopeCore

// Tests de la recherche DNS étendue (note 14) : réponses binaires fixes, aucun réseau.

func registerDNSExtendedTests(_ suite: TestSuite) {
    suite.add("DNS : décodage SRV, CAA, DNSKEY et DS sur une réponse fixe") {
        let message = try DNSMessageCodec.parse(DNSExtendedFixture.response)
        try expectEqual(message.answers.map(\.typeLabel), ["SRV", "CAA", "CAA", "DNSKEY", "DS"], "types")
        try expectEqual(message.answers[0].value, "10 60 5060 sip.example.com.", "SRV")
        try expectEqual(message.answers[1].value, "0 issue \"letsencrypt.org\"", "CAA issue")
        try expectEqual(message.answers[2].value, "128 iodef \"mailto:securite@example.com\"", "CAA iodef critique")
        try expectEqual(message.answers[3].value, "257 3 13 AQIDBAUGBwg=", "DNSKEY")
        try expectEqual(message.answers[4].value, "2371 13 2 0A1B2C3D", "DS")
        try expectEqual(DNSRecordType(code: 257), .caa, "code CAA")
        try expect(DNSRecordType.queryable.contains(.dnskey) && DNSRecordType.queryable.contains(.soa), "types proposés")
    }

    suite.add("DNS : explications en clair et numéro de clé DNSSEC") {
        func note(_ type: DNSRecordType, _ value: String) -> String? {
            DNSRecordNote.describe(DNSRecord(name: "example.com.", typeCode: type.code, ttl: 300, value: value))
        }
        try expectEqual(note(.soa, "ns.example.com. admin.example.com. 2026110301 7200 3600 1209600 300"),
                        "Maître ns.example.com. · responsable admin@example.com · série 2026110301 · rafraîchir 2\u{00A0}h · réessayer 1\u{00A0}h · expiration 14\u{00A0}j · cache négatif 5\u{00A0}min",
                        "SOA")
        try expectEqual(note(.srv, "10 60 5060 sip.example.com."), "Service sur sip.example.com. port 5060 · priorité 10, poids 60", "SRV")
        try expectEqual(note(.caa, "0 issue \"letsencrypt.org\""), "Autorise « letsencrypt.org » à émettre des certificats", "CAA")
        try expectEqual(note(.caa, "0 issuewild \";\""), "Aucun certificat générique (*) permis", "CAA issuewild vide")
        // Numéro de clé calculé sur les données (RFC 4034, annexe B).
        let rdata: [UInt8] = [0x01, 0x01, 3, 13, 1, 2, 3, 4, 5, 6, 7, 8]
        try expectEqual(DNSSEC.keyTag(rdata: rdata), DNSSEC.keyTag(presentation: "257 3 13 AQIDBAUGBwg="), "même numéro des deux formes")
        try expectEqual(DNSSEC.keyTag(rdata: rdata), 5154, "valeur attendue")
        try expectEqual(note(.dnskey, "257 3 13 AQIDBAUGBwg="), "KSK (clé de signature des clés) · ECDSA P-256/SHA-256 · clé n°\u{00A0}5154", "DNSKEY")
        try expectEqual(note(.ds, "2371 13 2 0A1B"), "Empreinte de la clé n°\u{00A0}2371 · ECDSA P-256/SHA-256 · SHA-256", "DS")
        try expectEqual(DNSRecordNote.duration(5400), "1\u{00A0}h 30\u{00A0}min", "durée composée")
    }

    suite.add("DNS : comparaison entre serveurs et propagation (réponses fixes)") {
        func result(_ values: [String], rcode: String = "NOERROR", ttl: UInt32 = 300) -> DNSLookupResult {
            DNSLookupResult(query: "exemple.ca", type: .a, rcode: rcode,
                            records: values.map { DNSRecord(name: "exemple.ca.", typeCode: 1, ttl: ttl, value: $0) },
                            answerCount: values.count, isAuthoritative: false, serverLabel: "test", durationMs: 10)
        }
        let answers = [
            DNSServerAnswer(name: "Cloudflare", address: IPv4Address(1, 1, 1, 1), result: result(["192.0.2.10", "192.0.2.11"]), error: nil),
            // Même réponse, ordre et TTL différents : pas un écart.
            DNSServerAnswer(name: "Google", address: IPv4Address(8, 8, 8, 8), result: result(["192.0.2.11", "192.0.2.10"], ttl: 120), error: nil),
            DNSServerAnswer(name: "Quad9", address: IPv4Address(9, 9, 9, 9), result: result(["198.51.100.4"]), error: nil),
            DNSServerAnswer(name: "OpenDNS", address: IPv4Address(208, 67, 222, 222), result: nil, error: "Aucune réponse après 3 s."),
        ]
        let comparison = DNSComparison(query: "exemple.ca", type: .a, answers: answers)
        try expectEqual(comparison.agreement(of: answers[0]), .agrees, "majorité")
        try expectEqual(comparison.agreement(of: answers[1]), .agrees, "TTL et ordre ignorés")
        try expectEqual(comparison.agreement(of: answers[2]), .differs, "ancienne adresse")
        try expectEqual(comparison.agreement(of: answers[3]), .failed, "sans réponse")
        try expectEqual(comparison.summary, "2 serveurs sur 4 donnent la même réponse · 1 différent · 1 sans réponse", "résumé")
        try expect(!comparison.isConsistent, "écart signalé")
        let differences = comparison.differences(of: answers[2])
        try expectEqual(differences.extra, ["A 198.51.100.4"], "valeur en trop")
        try expectEqual(differences.missing, ["A 192.0.2.10", "A 192.0.2.11"], "valeurs manquantes")
        try expectEqual(answers[1].minTTL, 120, "TTL restant")

        let nx = DNSComparison(query: "x", type: .a, answers: [
            DNSServerAnswer(name: "A", address: nil, result: result([], rcode: "NXDOMAIN"), error: nil),
            DNSServerAnswer(name: "B", address: IPv4Address(1, 1, 1, 1), result: result([], rcode: "NXDOMAIN"), error: nil),
        ])
        try expect(nx.isConsistent, "deux NXDOMAIN concordent")
        try expectEqual(nx.summary, "Les 2 serveurs donnent la même réponse", "résumé unanime")
        try expectEqual(DNSPublicResolver.propagation.count, 10, "dix résolveurs publics")
        try expectEqual(Set(DNSPublicResolver.propagation.map(\.address)).count, 10, "adresses distinctes")
    }
}

enum DNSExtendedFixture {
    /// Réponse fixe pour « example.com » : SRV, deux CAA, DNSKEY, DS (pointeurs de compression).
    static let response: [UInt8] = {
        var b: [UInt8] = [0xAB, 0xCD, 0x81, 0x80, 0, 1, 0, 5, 0, 0, 0, 0]
        b += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 33, 0, 1]
        func record(_ type: UInt16, _ rdata: [UInt8]) -> [UInt8] {
            [0xC0, 12, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1, 0, 0, 0x0E, 0x10, UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)] + rdata
        }
        // SRV 10 60 5060 sip.example.com (« sip » + pointeur vers example.com)
        b += record(33, [0, 10, 0, 60, 0x13, 0xC4, 3] + Array("sip".utf8) + [0xC0, 12])
        // CAA 0 issue "letsencrypt.org"
        b += record(257, [0, 5] + Array("issue".utf8) + Array("letsencrypt.org".utf8))
        // CAA 128 iodef "mailto:securite@example.com"
        b += record(257, [128, 5] + Array("iodef".utf8) + Array("mailto:securite@example.com".utf8))
        // DNSKEY 257 3 13 + clé 01…08
        b += record(48, [0x01, 0x01, 3, 13, 1, 2, 3, 4, 5, 6, 7, 8])
        // DS 2371 13 2 0A1B2C3D
        b += record(43, [0x09, 0x43, 13, 2, 0x0A, 0x1B, 0x2C, 0x3D])
        return b
    }()
}
