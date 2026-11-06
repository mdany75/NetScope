import Foundation

// Note 70 : sonde de Surveillance « Certificat TLS » : jours restants du certificat d'un service
// (HTTPS, LDAPS, courriel avec STARTTLS…). Alerte sous le seuil (30 jours par défaut), panne
// quand il est expiré ou que la poignée échoue. L'évaluation est pure (testée sans réseau).

public enum MonTLSChecks {
    public static let defaultDays = TLSExpiry.defaultWarningDays

    /// Hôte et port d'une cible « hôte:port » ; 443 sans port.
    public static func target(_ text: String) -> (host: String, port: UInt16)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withoutScheme = trimmed.components(separatedBy: "://").last ?? trimmed
        let hostPart = withoutScheme.split(separator: "/", maxSplits: 1).first.map(String.init) ?? withoutScheme
        if hostPart.filter({ $0 == ":" }).count == 1 || hostPart.hasPrefix("[") {
            if let parsed = MonProbe.hostAndPort(hostPart) { return parsed }
            return nil
        }
        return (hostPart, 443)
    }

    static func run(_ probe: MonProbe, target text: String, now: Date) async -> MonResult {
        guard let (host, port) = target(text) else { return .failure(now, error: "Cible attendue\u{00A0}: hôte:port") }
        let inspection = await TLSProbe.inspect(host: host, port: port, mode: TLSPortPreset.mode(for: port), timeout: 8, testVersions: false)
        return evaluate(inspection, days: Int(probe.resourceLimit ?? Double(defaultDays)), now: now)
    }

    /// Résultat de la sonde pour une vérification : valeur « 213 j · Let's Encrypt », alerte
    /// sous le seuil, panne si expiré, pas encore valide ou sans certificat.
    public static func evaluate(_ inspection: TLSInspection, days: Int, now: Date) -> MonResult {
        guard let leaf = inspection.leaf else {
            return .failure(now, error: inspection.error ?? "Aucun certificat lu")
        }
        let issuer = leaf.isSelfIssued ? "auto-signé" : (leaf.issuer.commonName ?? leaf.issuer.summary)
        let expiry = TLSExpiry.of(leaf, now: now, warningDays: days)
        switch expiry {
        case let .valid(remaining):
            return MonResult(date: now, reachable: true, value: "\(remaining)\u{00A0}j · \(issuer)")
        case let .soon(remaining):
            return MonResult(date: now, reachable: true, value: "\(remaining)\u{00A0}j · \(issuer)",
                             problem: "Certificat de \(inspection.endpoint) \(expiry.label) (le \(TLSFormat.date(leaf.notAfter)), seuil \(days)\u{00A0}j)")
        case .expired:
            return MonResult(date: now, reachable: false, value: "Expiré · \(issuer)",
                             error: "Certificat de \(inspection.endpoint) \(expiry.label) (le \(TLSFormat.date(leaf.notAfter)))")
        case .notYetValid:
            return MonResult(date: now, reachable: false, value: "Pas encore valide",
                             error: "Certificat de \(inspection.endpoint) valide à partir du \(TLSFormat.date(leaf.notBefore))")
        }
    }
}
