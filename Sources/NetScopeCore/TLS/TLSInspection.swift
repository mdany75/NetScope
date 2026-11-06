import Foundation

// Note 70 : vérificateur de certificat TLS. Modèle du résultat et règles d'analyse, pures et
// testables sans réseau : correspondance du nom, expiration, chaîne, versions TLS, verdict.
// La connexion elle-même est dans TLSProbe.swift.

// MARK: - Versions et suites

/// Version du protocole TLS, tentée séparément par le vérificateur.
public enum TLSVersion: String, CaseIterable, Codable, Sendable, Comparable {
    case tls10 = "TLS 1.0", tls11 = "TLS 1.1", tls12 = "TLS 1.2", tls13 = "TLS 1.3"

    public var label: String { rawValue }

    /// Code du protocole (0x0301 à 0x0304).
    public var code: UInt16 {
        switch self {
        case .tls10: return 0x0301
        case .tls11: return 0x0302
        case .tls12: return 0x0303
        case .tls13: return 0x0304
        }
    }

    /// TLS 1.0 et 1.1 : retirés (RFC 8996), à désactiver.
    public var isObsolete: Bool { self == .tls10 || self == .tls11 }

    public init?(code: UInt16) {
        guard let version = TLSVersion.allCases.first(where: { $0.code == code }) else { return nil }
        self = version
    }

    public static func < (lhs: TLSVersion, rhs: TLSVersion) -> Bool { lhs.code < rhs.code }
}

/// Résultat de la tentative d'une version.
public struct TLSVersionSupport: Hashable, Sendable, Identifiable {
    public var version: TLSVersion
    /// nil : non testée.
    public var accepted: Bool?
    /// Suite négociée avec cette version, ou raison du refus.
    public var detail: String?

    public var id: TLSVersion { version }

    public init(version: TLSVersion, accepted: Bool?, detail: String? = nil) {
        self.version = version
        self.accepted = accepted
        self.detail = detail
    }
}

/// Noms des suites de chiffrement (code IANA).
public enum TLSCipherSuite {
    public static func name(_ code: UInt16) -> String {
        switch code {
        case 0x1301: return "TLS_AES_128_GCM_SHA256"
        case 0x1302: return "TLS_AES_256_GCM_SHA384"
        case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
        case 0xC02B: return "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
        case 0xC02C: return "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
        case 0xC02F: return "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
        case 0xC030: return "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
        case 0xCCA8: return "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
        case 0xCCA9: return "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
        case 0xC009: return "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA"
        case 0xC00A: return "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA"
        case 0xC013: return "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA"
        case 0xC014: return "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA"
        case 0xC023: return "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256"
        case 0xC024: return "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384"
        case 0xC027: return "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256"
        case 0xC028: return "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384"
        case 0x009C: return "TLS_RSA_WITH_AES_128_GCM_SHA256"
        case 0x009D: return "TLS_RSA_WITH_AES_256_GCM_SHA384"
        case 0x003C: return "TLS_RSA_WITH_AES_128_CBC_SHA256"
        case 0x003D: return "TLS_RSA_WITH_AES_256_CBC_SHA256"
        case 0x002F: return "TLS_RSA_WITH_AES_128_CBC_SHA"
        case 0x0035: return "TLS_RSA_WITH_AES_256_CBC_SHA"
        case 0x000A: return "TLS_RSA_WITH_3DES_EDE_CBC_SHA"
        case 0x0005: return "TLS_RSA_WITH_RC4_128_SHA"
        default: return String(format: "0x%04X", code)
        }
    }

    /// Suite faible : RC4, 3DES, ou échange RSA sans confidentialité persistante.
    public static func isWeak(_ name: String) -> Bool {
        name.contains("RC4") || name.contains("3DES") || name.hasPrefix("TLS_RSA_")
    }
}

// MARK: - Ports et STARTTLS

/// Mode d'ouverture du chiffrement : TLS direct, ou STARTTLS après une partie en clair.
public enum TLSStartMode: String, CaseIterable, Codable, Sendable {
    case direct, smtp, imap, pop3

    public var label: String {
        switch self {
        case .direct: return "TLS direct"
        case .smtp: return "STARTTLS (SMTP)"
        case .imap: return "STARTTLS (IMAP)"
        case .pop3: return "STLS (POP3)"
        }
    }
}

/// Port proposé par l'outil, avec son service et son mode.
public struct TLSPortPreset: Hashable, Sendable, Identifiable {
    public var port: UInt16
    public var service: String
    public var mode: TLSStartMode

    public var id: UInt16 { port }

    public static let all: [TLSPortPreset] = [
        TLSPortPreset(port: 443, service: "HTTPS", mode: .direct),
        TLSPortPreset(port: 8443, service: "HTTPS (admin)", mode: .direct),
        TLSPortPreset(port: 465, service: "SMTPS", mode: .direct),
        TLSPortPreset(port: 993, service: "IMAPS", mode: .direct),
        TLSPortPreset(port: 995, service: "POP3S", mode: .direct),
        TLSPortPreset(port: 636, service: "LDAPS", mode: .direct),
        TLSPortPreset(port: 25, service: "SMTP", mode: .smtp),
        TLSPortPreset(port: 587, service: "Soumission", mode: .smtp),
        TLSPortPreset(port: 143, service: "IMAP", mode: .imap),
        TLSPortPreset(port: 110, service: "POP3", mode: .pop3),
    ]

    /// Mode habituel d'un port (STARTTLS pour 25, 587, 143 et 110 ; TLS direct ailleurs).
    public static func mode(for port: UInt16) -> TLSStartMode {
        all.first { $0.port == port }?.mode ?? .direct
    }
}

// MARK: - Correspondance du nom

public enum TLSHostname {
    /// Le nom demandé (ou l'adresse IP) est couvert : SAN d'abord ; le nom commun seulement si le
    /// certificat n'a aucun SAN (ancienne pratique, refusée par macOS et les navigateurs récents).
    public static func matches(_ host: String, certificate: X509Certificate) -> Bool {
        let host = normalized(host)
        guard !host.isEmpty else { return false }
        if IPv4Address(host) != nil || host.contains(":") {
            if certificate.ipAddresses.contains(where: { $0.lowercased() == host }) { return true }
            return certificate.subjectAltNames.isEmpty && certificate.subject.commonName.map(normalized) == host
        }
        if certificate.subjectAltNames.isEmpty, let commonName = certificate.subject.commonName {
            return matches(host, pattern: commonName)
        }
        return certificate.dnsNames.contains { matches(host, pattern: $0) }
    }

    /// Seul le nom commun (sans SAN) couvre le nom : accepté autrefois, refusé aujourd'hui.
    public static func matchesOnlyByCommonName(_ host: String, certificate: X509Certificate) -> Bool {
        certificate.subjectAltNames.isEmpty && matches(host, certificate: certificate)
    }

    /// Joker sur la première étiquette seulement : « *.exemple.ca » couvre « nas.exemple.ca »,
    /// pas « exemple.ca » ni « a.b.exemple.ca ».
    public static func matches(_ host: String, pattern: String) -> Bool {
        let host = normalized(host)
        let pattern = normalized(pattern)
        guard !host.isEmpty, !pattern.isEmpty else { return false }
        guard pattern.hasPrefix("*.") else { return host == pattern }
        let suffix = pattern.dropFirst(1) // « .exemple.ca »
        guard suffix.split(separator: ".").count >= 2, host.hasSuffix(suffix) else { return false }
        let label = host.dropLast(suffix.count)
        return !label.isEmpty && !label.contains(".")
    }

    static func normalized(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        return value
    }
}

// MARK: - Expiration

public enum TLSExpiry: Hashable, Sendable {
    case valid(days: Int)
    case soon(days: Int)
    case expired(daysAgo: Int)
    case notYetValid(inDays: Int)

    public static let defaultWarningDays = 30

    public static func of(_ certificate: X509Certificate, now: Date = Date(), warningDays: Int = defaultWarningDays) -> TLSExpiry {
        if certificate.notBefore > now {
            return .notYetValid(inDays: max(0, Int((certificate.notBefore.timeIntervalSince(now) / 86_400).rounded(.up))))
        }
        if certificate.notAfter <= now {
            return .expired(daysAgo: Int((now.timeIntervalSince(certificate.notAfter) / 86_400).rounded(.down)))
        }
        let days = certificate.daysRemaining(at: now)
        return days <= warningDays ? .soon(days: days) : .valid(days: days)
    }

    /// « 213 jours restants », « expire dans 12 jours », « expiré depuis 1 041 jours ».
    public var label: String {
        switch self {
        case let .valid(days): return "\(TLSText.days(days)) restant\(days > 1 ? "s" : "")"
        case let .soon(days): return days == 0 ? "expire aujourd’hui" : "expire dans \(TLSText.days(days))"
        case let .expired(daysAgo): return daysAgo == 0 ? "expiré aujourd’hui" : "expiré depuis \(TLSText.days(daysAgo))"
        case let .notYetValid(inDays): return "valide dans \(TLSText.days(inDays))"
        }
    }

    /// Jours restants (négatif une fois expiré), pour le tri et les sondes.
    public var daysRemaining: Int {
        switch self {
        case let .valid(days), let .soon(days): return days
        case let .expired(daysAgo): return -daysAgo
        case .notYetValid: return 0
        }
    }

    public var level: SMTPFinding.Level {
        switch self {
        case .valid: return .ok
        case .soon: return .warning
        case .expired, .notYetValid: return .critical
        }
    }
}

public enum TLSText {
    /// « 1 jour », « 213 jours », « 1 041 jours » (espaces insécables).
    public static func days(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{202F}"
        let number = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(number)\u{00A0}jour\(abs(count) > 1 ? "s" : "")"
    }
}

// MARK: - Résultat d'une vérification

public struct TLSInspection: Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var host: String
    public var port: UInt16
    /// Nom envoyé par SNI (nil : aucun, pour une adresse IP).
    public var serverName: String?
    public var mode: TLSStartMode
    /// Adresse jointe, si connue.
    public var address: String?
    /// Chaîne envoyée par le serveur (feuille d'abord).
    public var chain: [X509Certificate]
    /// Verdict de confiance de macOS (SecTrust, nom compris) et sa raison.
    public var trusted: Bool
    public var trustReason: String?
    /// Chaîne reconnue par macOS, sans tenir compte du nom (distingue « nom » et « émetteur »).
    public var chainTrusted: Bool?
    public var negotiatedVersion: TLSVersion?
    public var cipherSuite: String?
    public var versions: [TLSVersionSupport]
    /// Durée de la poignée TLS principale (ms).
    public var handshakeMs: Double?
    /// Échec de la connexion ou de la poignée (aucun certificat lu).
    public var error: String?
    /// Nom affiché dans la vérification du site (« Passerelle »).
    public var label: String?

    public init(date: Date = Date(), host: String, port: UInt16, serverName: String?, mode: TLSStartMode = .direct,
                address: String? = nil, chain: [X509Certificate] = [], trusted: Bool = false, trustReason: String? = nil,
                chainTrusted: Bool? = nil, negotiatedVersion: TLSVersion? = nil, cipherSuite: String? = nil,
                versions: [TLSVersionSupport] = [], handshakeMs: Double? = nil, error: String? = nil, label: String? = nil) {
        self.date = date
        self.host = host
        self.port = port
        self.serverName = serverName
        self.mode = mode
        self.address = address
        self.chain = chain
        self.trusted = trusted
        self.trustReason = trustReason
        self.chainTrusted = chainTrusted
        self.negotiatedVersion = negotiatedVersion
        self.cipherSuite = cipherSuite
        self.versions = versions
        self.handshakeMs = handshakeMs
        self.error = error
        self.label = label
    }

    public var leaf: X509Certificate? { chain.first }

    /// Nom vérifié contre le certificat : le SNI, sinon l'hôte saisi.
    public var checkedName: String { serverName ?? host }

    /// « 10.182.122.1:443 ».
    public var endpoint: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// Verdict résumé d'une vérification (pastille, tri de la vérification du site).
public enum TLSVerdict: Hashable, Sendable {
    case ok
    case soon(days: Int)
    case expired(daysAgo: Int)
    case notYetValid
    case nameMismatch
    case selfSigned
    case untrusted
    case failed

    public var label: String {
        switch self {
        case .ok: return "Valide"
        case let .soon(days): return "Expire dans \(TLSText.days(days))"
        case .expired: return "Expiré"
        case .notYetValid: return "Pas encore valide"
        case .nameMismatch: return "Nom différent"
        case .selfSigned: return "Auto-signé"
        case .untrusted: return "Non reconnu"
        case .failed: return "Échec"
        }
    }

    public var level: SMTPFinding.Level {
        switch self {
        case .ok: return .ok
        case .soon, .selfSigned, .nameMismatch, .untrusted: return .warning
        case .expired, .notYetValid, .failed: return .critical
        }
    }

    /// Ordre de gravité pour la liste du site (les plus urgents d'abord).
    public var rank: Int {
        switch self {
        case .expired: return 0
        case .notYetValid: return 1
        case .soon: return 2
        case .nameMismatch: return 3
        case .untrusted: return 4
        case .selfSigned: return 5
        case .failed: return 6
        case .ok: return 7
        }
    }

    /// À signaler dans la vérification du site : expiré ou bientôt expiré.
    public var isExpiryProblem: Bool {
        switch self {
        case .expired, .soon, .notYetValid: return true
        default: return false
        }
    }
}

// MARK: - Analyse

public enum TLSAnalysis {
    public static func expiry(_ inspection: TLSInspection, now: Date = Date(),
                              warningDays: Int = TLSExpiry.defaultWarningDays) -> TLSExpiry? {
        inspection.leaf.map { TLSExpiry.of($0, now: now, warningDays: warningDays) }
    }

    /// Verdict principal : l'expiration d'abord (c'est ce qui casse un jour), puis le nom, puis la confiance.
    public static func verdict(_ inspection: TLSInspection, now: Date = Date(),
                               warningDays: Int = TLSExpiry.defaultWarningDays) -> TLSVerdict {
        guard let leaf = inspection.leaf else { return .failed }
        switch TLSExpiry.of(leaf, now: now, warningDays: warningDays) {
        case let .expired(daysAgo): return .expired(daysAgo: daysAgo)
        case .notYetValid: return .notYetValid
        case let .soon(days): return .soon(days: days)
        case .valid: break
        }
        if !TLSHostname.matches(inspection.checkedName, certificate: leaf) && !isBareAddressWithoutSAN(inspection) {
            return .nameMismatch
        }
        if inspection.trusted { return .ok }
        if leaf.isSelfIssued && inspection.chain.count == 1 { return .selfSigned }
        return inspection.chainTrusted == true ? .ok : .untrusted
    }

    /// Adresse IP saisie sans aucun SAN IP : on ne peut pas exiger de correspondance (appareil
    /// joint par son adresse) ; le constat le signale sans en faire le verdict principal.
    static func isBareAddressWithoutSAN(_ inspection: TLSInspection) -> Bool {
        guard IPv4Address(inspection.checkedName) != nil, let leaf = inspection.leaf else { return false }
        return leaf.ipAddresses.isEmpty
    }

    /// Constats détaillés, du plus grave au plus rassurant.
    public static func findings(_ inspection: TLSInspection, now: Date = Date(),
                                warningDays: Int = TLSExpiry.defaultWarningDays) -> [SMTPFinding] {
        var findings: [SMTPFinding] = []
        guard let leaf = inspection.leaf else {
            findings.append(SMTPFinding(.critical, "Aucun certificat lu", inspection.error ?? "La poignée TLS n’a pas abouti."))
            return findings
        }
        // Expiration
        let expiry = TLSExpiry.of(leaf, now: now, warningDays: warningDays)
        let end = TLSFormat.date(leaf.notAfter)
        switch expiry {
        case let .expired(daysAgo):
            findings.append(SMTPFinding(.critical, "Certificat expiré",
                                        "Expiré le \(end) (\(daysAgo == 0 ? "aujourd’hui" : "depuis \(TLSText.days(daysAgo))")). Navigateurs et clients refusent la connexion ou affichent un avertissement."))
        case let .soon(days):
            findings.append(SMTPFinding(.warning, "Expire bientôt",
                                        "Le \(end), dans \(TLSText.days(days)) (seuil\u{00A0}: \(TLSText.days(warningDays))). Prévoir le renouvellement."))
        case .notYetValid:
            findings.append(SMTPFinding(.critical, "Certificat pas encore valide",
                                        "Valide à partir du \(TLSFormat.date(leaf.notBefore))\u{00A0}: l’horloge de l’appareil est peut-être fausse."))
        case let .valid(days):
            findings.append(SMTPFinding(.ok, "Valide encore \(TLSText.days(days))", "Jusqu’au \(end)."))
        }
        // Nom
        let name = inspection.checkedName
        if TLSHostname.matches(name, certificate: leaf) {
            if TLSHostname.matchesOnlyByCommonName(name, certificate: leaf) {
                findings.append(SMTPFinding(.warning, "Nom seulement dans le CN",
                                            "Le certificat n’a pas de SAN\u{00A0}: macOS, iOS et les navigateurs récents refusent ce nom."))
            } else {
                findings.append(SMTPFinding(.ok, "Le nom correspond", "«\u{00A0}\(name)\u{00A0}» est couvert par le certificat."))
            }
        } else if isBareAddressWithoutSAN(inspection) {
            findings.append(SMTPFinding(.info, "Joint par son adresse IP",
                                        "Le certificat ne couvre pas \(name) (noms\u{00A0}: \(coveredNames(leaf))). Normal pour un appareil joint par son adresse\u{00A0}; vérifier avec son nom DNS au besoin."))
        } else {
            findings.append(SMTPFinding(.warning, "Le nom ne correspond pas",
                                        "«\u{00A0}\(name)\u{00A0}» n’est pas couvert. Noms du certificat\u{00A0}: \(coveredNames(leaf))."))
        }
        // Confiance
        if inspection.trusted {
            findings.append(SMTPFinding(.ok, "Reconnu par macOS", "Chaîne vérifiée jusqu’à une autorité de confiance de ce Mac."))
        } else if leaf.isSelfIssued && inspection.chain.count == 1 {
            findings.append(SMTPFinding(.warning, "Certificat auto-signé",
                                        "Émis par l’appareil lui-même (fréquent sur les pare-feu, imprimantes et NAS). Les postes affichent un avertissement\u{00A0}: le remplacer par un certificat d’une autorité interne ou publique."))
        } else if inspection.chainTrusted == true {
            // Chaîne reconnue, refus dû au nom ou à la date : déjà signalé ci-dessus.
        } else {
            findings.append(SMTPFinding(.warning, "Non reconnu par macOS", inspection.trustReason ?? "La chaîne ne mène pas à une autorité de confiance de ce Mac."))
        }
        if !leaf.isSelfIssued, inspection.chain.count == 1 {
            findings.append(SMTPFinding(.warning, "Chaîne incomplète",
                                        "Le serveur n’envoie que son certificat, sans l’intermédiaire de \(leaf.issuer.summary)\u{00A0}: certains clients échoueront."))
        }
        // Clé et signature
        if leaf.publicKey.isWeak {
            findings.append(SMTPFinding(.warning, "Clé faible", "\(leaf.publicKey.label)\u{00A0}: 2048\u{00A0}bits au moins (RSA) ou P-256 attendus."))
        }
        if leaf.hasWeakSignature {
            findings.append(SMTPFinding(.warning, "Signature faible", "\(leaf.signatureAlgorithm)\u{00A0}: refusée par les clients récents."))
        }
        if !leaf.allowsServerAuth {
            findings.append(SMTPFinding(.warning, "Usage non prévu pour un serveur", "L’usage étendu n’inclut pas l’authentification de serveur TLS."))
        }
        if leaf.lifetimeDays > 398, !leaf.isSelfIssued, inspection.trusted {
            findings.append(SMTPFinding(.info, "Durée de validité longue",
                                        "\(TLSText.days(leaf.lifetimeDays))\u{00A0}: au-delà de 398\u{00A0}jours, Safari refuse un certificat public."))
        }
        // Versions
        let obsolete = inspection.versions.filter { $0.accepted == true && $0.version.isObsolete }.map(\.version.label)
        if !obsolete.isEmpty {
            findings.append(SMTPFinding(.warning, "Versions obsolètes acceptées",
                                        "\(obsolete.joined(separator: " et ")) (retirées par la RFC 8996)\u{00A0}: à désactiver sur l’appareil."))
        }
        if inspection.versions.contains(where: { $0.version == .tls13 && $0.accepted == false }),
           inspection.versions.contains(where: { $0.accepted == true }) {
            findings.append(SMTPFinding(.info, "TLS 1.3 non pris en charge", "Seules des versions plus anciennes répondent."))
        }
        if let suite = inspection.cipherSuite, TLSCipherSuite.isWeak(suite) {
            findings.append(SMTPFinding(.warning, "Suite de chiffrement faible", "\(suite)\u{00A0}: sans confidentialité persistante ou chiffrement dépassé."))
        }
        return findings.sorted { $0.level > $1.level }
    }

    /// Noms couverts, abrégés (« nas.exemple.ca, *.exemple.ca, +2 »).
    static func coveredNames(_ leaf: X509Certificate) -> String {
        var names = leaf.subjectAltNames.map(\.text)
        if names.isEmpty, let commonName = leaf.subject.commonName { names = ["CN=\(commonName)"] }
        guard !names.isEmpty else { return "aucun" }
        return names.count > 4 ? names.prefix(4).joined(separator: ", ") + ", +\(names.count - 4)" : names.joined(separator: ", ")
    }

    /// Texte du rapport (copie) : verdict, certificat, chaîne, versions.
    public static func report(_ inspection: TLSInspection, now: Date = Date(), warningDays: Int = TLSExpiry.defaultWarningDays) -> String {
        var lines = ["Certificat TLS — \(inspection.endpoint) (\(inspection.mode.label))"]
        if let serverName = inspection.serverName { lines.append("SNI\u{00A0}: \(serverName)") }
        lines.append("Verdict\u{00A0}: \(verdict(inspection, now: now, warningDays: warningDays).label)")
        if let error = inspection.error { lines.append("Erreur\u{00A0}: \(error)") }
        for (index, certificate) in inspection.chain.enumerated() {
            lines.append("")
            lines.append("[\(index)] \(certificate.subject.text)")
            lines.append("    Émetteur\u{00A0}: \(certificate.issuer.text)")
            if !certificate.subjectAltNames.isEmpty {
                lines.append("    SAN\u{00A0}: " + certificate.subjectAltNames.map { "\($0.kind):\($0.text)" }.joined(separator: ", "))
            }
            lines.append("    Validité\u{00A0}: \(TLSFormat.date(certificate.notBefore)) → \(TLSFormat.date(certificate.notAfter)) (\(TLSExpiry.of(certificate, now: now, warningDays: warningDays).label))")
            lines.append("    Clé\u{00A0}: \(certificate.publicKey.label) · Signature\u{00A0}: \(certificate.signatureAlgorithm)")
            lines.append("    SHA-256\u{00A0}: \(certificate.sha256Fingerprint)")
        }
        if !inspection.versions.isEmpty {
            lines.append("")
            lines.append("Versions\u{00A0}: " + inspection.versions.map { "\($0.version.label) \($0.accepted == true ? "oui" : $0.accepted == false ? "non" : "?")" }
                .joined(separator: " · "))
        }
        if let version = inspection.negotiatedVersion {
            lines.append("Négocié\u{00A0}: \(version.label)" + (inspection.cipherSuite.map { " · \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

public enum TLSFormat {
    /// « 2032-03-12 » (UTC).
    public static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Empreinte abrégée « C6:8E:D7:13…83:41:AC ».
    public static func shortFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 24 else { return fingerprint }
        return String(fingerprint.prefix(11)) + "…" + String(fingerprint.suffix(8))
    }
}

// MARK: - Vérification de tout le site

/// Hôte HTTPS à vérifier dans la vérification du site.
public struct TLSSweepTarget: Hashable, Sendable, Identifiable {
    public var host: String
    public var port: UInt16
    public var name: String

    public var id: String { "\(host):\(port)" }

    public init(host: String, port: UInt16, name: String) {
        self.host = host
        self.port = port
        self.name = name
    }
}

public enum TLSSiteSweep {
    /// Ports HTTPS recherchés dans le dernier scan.
    public static let ports: [UInt16] = [443, 8443]
    /// Vérifications simultanées au plus.
    public static let defaultConcurrency = 6

    /// Appareils en ligne du dernier scan ayant 443 ou 8443 ouvert, triés par adresse.
    public static func targets(from devices: [Device], ports: [UInt16] = ports) -> [TLSSweepTarget] {
        devices.filter(\.isOnline).sorted { $0.ip < $1.ip }.flatMap { device in
            ports.filter(device.openPorts.contains).map { TLSSweepTarget(host: device.ip.description, port: $0, name: device.displayName) }
        }
    }

    /// Passe sur chaque cible avec au plus `concurrency` vérifications à la fois ; l'ordre des
    /// résultats suit celui des cibles. `progress` reçoit (terminées, total).
    public static func run(_ targets: [TLSSweepTarget], concurrency: Int = defaultConcurrency,
                           probe: @escaping @Sendable (TLSSweepTarget) async -> TLSInspection,
                           progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [TLSInspection] {
        guard !targets.isEmpty else { return [] }
        let limit = max(1, concurrency)
        var results = [TLSInspection?](repeating: nil, count: targets.count)
        await withTaskGroup(of: (Int, TLSInspection).self) { group in
            var next = 0
            var done = 0
            while next < min(limit, targets.count) {
                let index = next
                group.addTask { (index, await probe(targets[index])) }
                next += 1
            }
            while let (index, inspection) = await group.next() {
                var labelled = inspection
                labelled.label = targets[index].name
                results[index] = labelled
                done += 1
                progress(done, targets.count)
                if Task.isCancelled { group.cancelAll() }
                if next < targets.count, !Task.isCancelled {
                    let index = next
                    group.addTask { (index, await probe(targets[index])) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }

    /// Résultats à signaler : expirés, pas encore valides ou bientôt expirés, les plus urgents d'abord.
    public static func attention(_ results: [TLSInspection], now: Date = Date(),
                                 warningDays: Int = TLSExpiry.defaultWarningDays) -> [TLSInspection] {
        results.filter { TLSAnalysis.verdict($0, now: now, warningDays: warningDays).isExpiryProblem }
            .sorted { (TLSAnalysis.expiry($0, now: now, warningDays: warningDays)?.daysRemaining ?? 0)
                < (TLSAnalysis.expiry($1, now: now, warningDays: warningDays)?.daysRemaining ?? 0) }
    }
}
