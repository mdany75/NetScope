import Foundation

/// Accès d'application à Microsoft Graph (santé détaillée du locataire Microsoft 365).
/// Le secret n'est jamais enregistré ici : l'application le lit au Trousseau au moment de l'appel.
public struct SvcGraphCredentials: Sendable, Equatable {
    public var tenantID: String
    public var clientID: String
    public var clientSecret: String

    public init(tenantID: String, clientID: String, clientSecret: String) {
        self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret
    }

    /// Les trois valeurs sont présentes et l'identifiant du locataire est utilisable dans une adresse.
    public var isComplete: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty && SvcGraph.isValidTenant(tenantID)
    }
}

/// Microsoft Graph Service Health : jeton par « client credentials », puis
/// /admin/serviceAnnouncement/healthOverviews et /issues (permission ServiceHealth.Read.All).
public enum SvcGraph {
    public static let healthOverviewsURL = URL(string: "https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/healthOverviews")!
    /// Problèmes non résolus seulement.
    public static let issuesURL = URL(string: "https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/issues?$filter=isResolved%20eq%20false")!
    /// Lien vers le centre d'administration (santé des services).
    public static let adminURL = "https://admin.microsoft.com/#/servicehealth"

    /// Services Graph qui correspondent aux parties suivies de Microsoft 365.
    public static let followedServices: [String: String] = [
        "Exchange Online": "Outlook",
        "Microsoft Teams": "Teams",
        "SharePoint Online": "SharePoint",
        "OneDrive for Business": "OneDrive",
        "Microsoft 365 suite": "Microsoft 365",
        "Microsoft Entra": "Connexion (Entra ID)",
    ]

    /// GUID ou nom de domaine (contoso.onmicrosoft.com) : lettres, chiffres, points et tirets.
    public static func isValidTenant(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && text.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }

    /// Requête du jeton d'application (corps encodé en x-www-form-urlencoded).
    public static func tokenRequest(_ credentials: SvcGraphCredentials) -> URLRequest? {
        guard credentials.isComplete,
              let url = URL(string: "https://login.microsoftonline.com/\(credentials.tenantID)/oauth2/v2.0/token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [("client_id", credentials.clientID), ("client_secret", credentials.clientSecret),
                      ("scope", "https://graph.microsoft.com/.default"), ("grant_type", "client_credentials")]
        request.httpBody = Data(fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Jeton d'accès de la réponse, ou l'erreur expliquée par Microsoft.
    public static func parseToken(_ data: Data) throws -> String {
        let root = try SvcFeedParser.object(data)
        if let token = root["access_token"] as? String, !token.isEmpty { return token }
        let code = (root["error"] as? String) ?? "réponse inattendue"
        let detail = (root["error_description"] as? String)?.split(whereSeparator: \.isNewline).first.map(String.init)
        throw SvcParseError.unreadable("jeton Microsoft refusé (\(code))" + (detail.map { " · \($0)" } ?? ""))
    }

    /// État de chaque service (healthOverviews).
    public static func parseHealthOverviews(_ data: Data) throws -> [SvcComponent] {
        let root = try SvcFeedParser.object(data)
        guard let values = root["value"] as? [[String: Any]] else {
            throw SvcParseError.unreadable("champ «\u{00A0}value\u{00A0}» absent (healthOverviews)")
        }
        return values.compactMap { item in
            guard let name = item["service"] as? String else { return nil }
            return SvcComponent(name: name, health: health((item["status"] as? String) ?? ""))
        }
    }

    /// Problèmes publiés (issues).
    public static func parseIssues(_ data: Data) throws -> [SvcIncident] {
        let root = try SvcFeedParser.object(data)
        guard let values = root["value"] as? [[String: Any]] else {
            throw SvcParseError.unreadable("champ «\u{00A0}value\u{00A0}» absent (issues)")
        }
        return values.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let status = (item["status"] as? String) ?? ""
            let resolved = (item["isResolved"] as? Bool) ?? false
            var impact = health(status)
            if impact == .operational, !resolved { impact = .degraded }
            let service = item["service"] as? String
            let feature = item["feature"] as? String
            let title = (item["title"] as? String) ?? (item["impactDescription"] as? String) ?? id
            return SvcIncident(
                id: id, title: SvcFeedParser.plainText(title), impact: impact,
                status: resolved ? "Résolu" : statusLabel(status),
                affected: [service.map { followedServices[$0] ?? $0 }, feature].compactMap { $0 },
                started: SvcFeedParser.date(item["startDateTime"]),
                updated: SvcFeedParser.date(item["lastModifiedDateTime"]),
                url: adminURL + "/:/alerts/" + id,
                latestUpdate: (item["impactDescription"] as? String).map(SvcFeedParser.plainText),
                isResolved: resolved)
        }
    }

    /// Bilan Microsoft 365 à partir de Graph : services suivis et problèmes en cours.
    public static func report(overviews: [SvcComponent], issues: [SvcIncident]) -> SvcFeedReport {
        let followed = overviews.filter { followedServices[$0.name] != nil }
            .map { SvcComponent(name: followedServices[$0.name] ?? $0.name, health: $0.health) }
        let active = issues.filter { !$0.isResolved }
        let health = max(followed.map(\.health).max() ?? .operational, active.map(\.impact).max() ?? .operational)
        return SvcFeedReport(health: health, description: SvcFeedParser.describe(health: health, incidents: active),
                             incidents: active, components: followed.filter { $0.health != .operational })
    }

    /// État Graph (serviceHealthStatus) → état du bilan.
    public static func health(_ status: String) -> SvcHealth {
        switch status {
        case "serviceInterruption": return .outage
        case "serviceDegradation", "extendedRecovery", "restoringService", "investigating", "verifyingService",
             "confirmed", "reported", "investigationSuspended":
            return .degraded
        case "serviceOperational", "serviceRestored", "postIncidentReviewPublished", "falsePositive", "resolved",
             "resolvedExternal", "mitigated", "mitigatedExternal":
            return .operational
        default: return .unknown
        }
    }

    /// Libellé français d'un état Graph.
    public static func statusLabel(_ status: String) -> String {
        switch status {
        case "serviceInterruption": return "Interruption"
        case "serviceDegradation": return "Dégradation"
        case "extendedRecovery": return "Rétablissement prolongé"
        case "restoringService": return "Rétablissement en cours"
        case "investigating": return "En cours d’analyse"
        case "verifyingService": return "Vérification"
        case "serviceRestored": return "Rétabli"
        case "postIncidentReviewPublished": return "Analyse publiée"
        case "falsePositive": return "Fausse alerte"
        case "serviceOperational": return "Opérationnel"
        case "": return "En cours"
        default: return status
        }
    }
}
