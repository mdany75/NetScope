import Foundation
import NetScopeCore

/// Démonstration du vérificateur de certificat TLS (note 70) : réponses fixes, aucun trafic.
/// FortiGate auto-signée, imprimante Brother expirée, NAS Synology en Let’s Encrypt dont le
/// renouvellement échoue, et le reste du parc HTTPS des données de démonstration.
enum TLSDemo {
    /// Hôte affiché à l'ouverture de l'outil.
    static let defaultHost = "nas.exemple.ca"

    private static func name(_ pairs: [(String, String)]) -> X509Name {
        X509Name(attributes: pairs.reversed().map { X509Name.Attribute(oid: oid($0.0), value: $0.1) })
    }

    private static func oid(_ short: String) -> String {
        switch short {
        case "CN": return X509OID.commonName
        case "O": return X509OID.organization
        case "OU": return X509OID.organizationalUnit
        case "C": return X509OID.country
        case "L": return "2.5.4.7"
        case "ST": return "2.5.4.8"
        default: return short
        }
    }

    private static func day(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text + "T00:00:00Z") ?? Date()
    }

    private static func cert(_ subject: [(String, String)], issuer: [(String, String)]? = nil, serial: String,
                             from: Date, to: Date, key: X509PublicKey, signature: String = X509OID.sha256WithRSA,
                             san: [X509AltName] = [], ca: Bool? = nil) -> X509Certificate {
        let subjectName = name(subject)
        let seed = subject.map { "\($0.0)=\($0.1)" }.joined() + serial
        return X509Certificate(subject: subjectName, issuer: issuer.map(name) ?? subjectName, serialNumber: serial,
                               notBefore: from, notAfter: to, publicKey: key, signatureAlgorithmOID: signature,
                               subjectAltNames: san, isCA: ca, extendedKeyUsages: ca == true ? [] : [X509OID.serverAuth],
                               sha256Fingerprint: FortiCertificatePin.fingerprint(der: Data(seed.utf8)))
    }

    private static let rsa2048 = X509PublicKey(algorithm: .rsa, bits: 2048)
    private static let p256 = X509PublicKey(algorithm: .ec, bits: 256, curve: "P-256")

    private static func versions(_ accepted: Set<TLSVersion>, suite13: String = "TLS_AES_256_GCM_SHA384",
                                 suite12: String = "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384") -> [TLSVersionSupport] {
        TLSVersion.allCases.reversed().map { version in
            accepted.contains(version)
                ? TLSVersionSupport(version: version, accepted: true, detail: version == .tls13 ? suite13 : suite12)
                : TLSVersionSupport(version: version, accepted: false, detail: "Version refusée par le serveur")
        }
    }

    /// Résultat de démonstration pour un hôte et un port (inconnu : certificat auto-signé valide).
    static func inspection(host: String, port: UInt16, serverName: String?, mode: TLSStartMode, now: Date = Date()) -> TLSInspection {
        let key = host.lowercased()
        let sni = serverName ?? (IPv4Address(key) == nil ? key : nil)
        func make(_ chain: [X509Certificate], trusted: Bool, reason: String? = nil, chainTrusted: Bool, versions accepted: Set<TLSVersion>,
                  suite: String = "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384", address: String? = nil, ms: Double = 38) -> TLSInspection {
            let negotiated = accepted.max()
            return TLSInspection(date: now, host: key, port: port, serverName: sni, mode: mode, address: address ?? (IPv4Address(key) != nil ? key : nil),
                                 chain: chain, trusted: trusted, trustReason: reason, chainTrusted: chainTrusted,
                                 negotiatedVersion: negotiated, cipherSuite: negotiated == .tls13 ? "TLS_AES_256_GCM_SHA384" : suite,
                                 versions: versions(accepted, suite12: suite), handshakeMs: ms)
        }
        switch key {
        case "nas.exemple.ca", "10.182.122.154":
            // Let’s Encrypt (90 jours), renouvellement automatique en échec depuis deux mois.
            let leaf = cert([("CN", "nas.exemple.ca")], issuer: [("C", "US"), ("O", "Let's Encrypt"), ("CN", "R11")],
                            serial: "04:A1:7F:3C:92:5E:11:0B:6D:E2:48:90:1C:33:7A:5D:02:F8", from: now.addingTimeInterval(-78 * 86_400),
                            to: now.addingTimeInterval(12 * 86_400 + 3_600), key: p256, signature: X509OID.sha256WithRSA,
                            san: [.dns("nas.exemple.ca"), .dns("photos.exemple.ca"), .dns("drive.exemple.ca")])
            let intermediate = cert([("C", "US"), ("O", "Let's Encrypt"), ("CN", "R11")],
                                    issuer: [("C", "US"), ("O", "Internet Security Research Group"), ("CN", "ISRG Root X1")],
                                    serial: "8A:7D:3E:13:D6:2F:30:EF:23:86:BD:29:07:6B:1F:8D", from: day("2024-03-13"), to: day("2027-03-12"),
                                    key: X509PublicKey(algorithm: .rsa, bits: 2048), ca: true)
            return make([leaf, intermediate], trusted: key != "10.182.122.154", reason: key == "10.182.122.154" ? "Le nom «\u{00A0}10.182.122.154\u{00A0}» ne correspond pas au certificat" : nil,
                        chainTrusted: true, versions: [.tls13, .tls12], suite: "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
                        address: "10.182.122.154", ms: 21)
        case "10.182.122.1", "fortigate", "fgt60f":
            let leaf = cert([("C", "US"), ("ST", "California"), ("L", "Sunnyvale"), ("O", "Fortinet"), ("OU", "FortiGate"), ("CN", "FGT60FTK2209A1B2")],
                            serial: "5A:3C:9E:01", from: day("2022-03-15"), to: day("2032-03-12"), key: rsa2048, ca: true)
            return make([leaf], trusted: false, reason: "«\u{00A0}FGT60FTK2209A1B2\u{00A0}» est auto-signé et n’est pas approuvé", chainTrusted: false,
                        versions: [.tls13, .tls12], ms: 12)
        case "10.182.122.111":
            let leaf = cert([("CN", "BRN94DDF818157D")], serial: "01", from: day("2020-01-01"), to: day("2023-01-01"),
                            key: rsa2048, san: [.ip("10.182.122.111")])
            return make([leaf], trusted: false, reason: "«\u{00A0}BRN94DDF818157D\u{00A0}» a expiré", chainTrusted: false,
                        versions: [.tls12, .tls11, .tls10], suite: "TLS_RSA_WITH_AES_256_CBC_SHA", ms: 64)
        case "10.182.122.102":
            let leaf = cert([("C", "US"), ("O", "Fortinet"), ("OU", "FortiAP"), ("CN", "FP231FTF23012345")],
                            issuer: [("C", "US"), ("O", "Fortinet"), ("OU", "Certificate Authority"), ("CN", "fortinet-subca2001")],
                            serial: "1F:22:9A", from: day("2023-02-10"), to: day("2038-01-19"), key: rsa2048)
            let ca = cert([("C", "US"), ("O", "Fortinet"), ("OU", "Certificate Authority"), ("CN", "fortinet-subca2001")],
                          issuer: [("C", "US"), ("O", "Fortinet"), ("CN", "fortinet-ca2")], serial: "20:01",
                          from: day("2020-01-01"), to: day("2038-01-19"), key: rsa2048, ca: true)
            return make([leaf, ca], trusted: false, reason: "Autorité «\u{00A0}fortinet-ca2\u{00A0}» inconnue de ce Mac", chainTrusted: false,
                        versions: [.tls12], ms: 18)
        case "10.10.0.31":
            let leaf = cert([("CN", "srv-backup.exemple.local")], issuer: [("DC", "local"), ("DC", "exemple"), ("CN", "EXEMPLE-CA")],
                            serial: "6D:00:00:01:4A", from: now.addingTimeInterval(-340 * 86_400), to: now.addingTimeInterval(25 * 86_400),
                            key: rsa2048, san: [.dns("srv-backup.exemple.local"), .ip("10.10.0.31")])
            let ca = cert([("DC", "local"), ("DC", "exemple"), ("CN", "EXEMPLE-CA")], serial: "1A",
                          from: day("2019-06-01"), to: day("2029-06-01"), key: X509PublicKey(algorithm: .rsa, bits: 4096), ca: true)
            return make([leaf, ca], trusted: false, reason: "Autorité «\u{00A0}EXEMPLE-CA\u{00A0}» non approuvée sur ce Mac", chainTrusted: false,
                        versions: [.tls13, .tls12], ms: 9)
        case "192.168.50.21", "192.168.50.31":
            let leaf = cert([("C", "CN"), ("O", "Hikvision"), ("CN", key)], serial: "32:30:32:31", from: day("2021-05-18"),
                            to: day("2031-05-16"), key: rsa2048, san: [.ip(key)])
            return make([leaf], trusted: false, reason: "Certificat auto-signé", chainTrusted: false, versions: [.tls12, .tls11], ms: 27)
        default:
            let leaf = cert([("CN", key)], serial: "3E:8B", from: day("2024-09-02"), to: day("2034-08-31"), key: rsa2048)
            return make([leaf], trusted: false, reason: "Certificat auto-signé", chainTrusted: false, versions: [.tls13, .tls12], ms: 15)
        }
    }

    /// Hôtes HTTPS des données de démonstration (443 ouverts), pour « Vérifier tous les HTTPS du site ».
    static let siteTargets: [TLSSweepTarget] = [
        TLSSweepTarget(host: "10.182.122.1", port: 443, name: "Passerelle"),
        TLSSweepTarget(host: "10.182.122.2", port: 443, name: "Switch cœur"),
        TLSSweepTarget(host: "10.182.122.3", port: 443, name: "Switch étage 2"),
        TLSSweepTarget(host: "10.182.122.102", port: 443, name: "Borne Wi-Fi accueil"),
        TLSSweepTarget(host: "10.182.122.111", port: 443, name: "Imprimante accueil"),
        TLSSweepTarget(host: "10.182.122.121", port: 443, name: "Téléphone accueil"),
        TLSSweepTarget(host: "10.182.122.154", port: 443, name: "NAS salle B01"),
        TLSSweepTarget(host: "192.168.50.21", port: 443, name: "Caméra quai"),
        TLSSweepTarget(host: "10.10.0.31", port: 443, name: "Serveur de sauvegarde"),
    ]

    static func siteResults(now: Date = Date()) -> [TLSInspection] {
        siteTargets.map { target in
            var inspection = inspection(host: target.host, port: target.port, serverName: nil, mode: .direct, now: now)
            inspection.label = target.name
            inspection.versions = []
            return inspection
        }
    }
}
