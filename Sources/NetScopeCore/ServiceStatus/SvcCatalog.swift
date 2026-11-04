import Foundation

/// Catalogue des grands services : liste intégrée, que l'utilisateur peut filtrer et compléter.
public enum SvcCatalog {
    /// Services proposés d'emblée (pages d'état publiques et adresses clés).
    public static let builtIn: [SvcService] = [
        SvcService(id: "microsoft365", name: "Microsoft 365", category: "Microsoft", format: .microsoft365,
                   feedURL: "https://status.cloud.microsoft/api/posts/m365Consumer",
                   pageURL: "https://status.cloud.microsoft",
                   endpoints: ["https://outlook.office365.com/", "https://login.microsoftonline.com/",
                               "https://teams.microsoft.com/", "https://www.office.com/"],
                   components: ["Outlook", "Teams", "SharePoint", "OneDrive"]),
        SvcService(id: "azure", name: "Azure", category: "Microsoft", format: .azureRSS,
                   feedURL: "https://azure.status.microsoft/en-us/status/feed/",
                   pageURL: "https://azure.status.microsoft/fr-ca/status",
                   endpoints: ["https://portal.azure.com/", "https://management.azure.com/"]),
        SvcService(id: "apple", name: "Apple (iCloud, App Store)", category: "Apple", format: .apple,
                   feedURL: "https://www.apple.com/support/systemstatus/data/system_status_fr_CA.js",
                   pageURL: "https://www.apple.com/fr-ca/support/systemstatus/",
                   endpoints: ["https://www.icloud.com/", "https://apps.apple.com/"],
                   components: ["iCloud", "App Store", "Compte Apple"]),
        SvcService(id: "aws", name: "AWS", category: "Amazon", format: .awsHealth,
                   feedURL: "https://health.aws.amazon.com/public/currentevents",
                   pageURL: "https://health.aws.amazon.com/health/status",
                   endpoints: ["https://console.aws.amazon.com/", "https://s3.amazonaws.com/"]),
        SvcService(id: "googleworkspace", name: "Google Workspace", category: "Google", format: .googleIncidents,
                   feedURL: "https://www.google.com/appsstatus/dashboard/incidents.json",
                   pageURL: "https://www.google.com/appsstatus/dashboard/",
                   endpoints: ["https://mail.google.com/", "https://meet.google.com/", "https://drive.google.com/"],
                   components: ["Gmail", "Google Meet", "Google Drive"]),
        SvcService(id: "googlecloud", name: "Google Cloud", category: "Google", format: .googleIncidents,
                   feedURL: "https://status.cloud.google.com/incidents.json",
                   pageURL: "https://status.cloud.google.com/",
                   endpoints: ["https://console.cloud.google.com/", "https://storage.googleapis.com/"]),
        SvcService(id: "cloudflare", name: "Cloudflare", category: "Réseau", format: .statuspage,
                   feedURL: "https://www.cloudflarestatus.com/api/v2/summary.json",
                   pageURL: "https://www.cloudflarestatus.com",
                   endpoints: ["https://one.one.one.one/", "https://dash.cloudflare.com/"]),
        SvcService(id: "zscaler", name: "Zscaler", category: "Réseau", format: .none, feedURL: nil,
                   pageURL: "https://trust.zscaler.com",
                   endpoints: ["https://gateway.zscaler.net/", "https://trust.zscaler.com/"]),
        SvcService(id: "okta", name: "Okta", category: "Identité", format: .none, feedURL: nil,
                   pageURL: "https://status.okta.com",
                   endpoints: ["https://login.okta.com/"]),
        SvcService(id: "github", name: "GitHub", category: "Développement", format: .statuspage,
                   feedURL: "https://www.githubstatus.com/api/v2/summary.json",
                   pageURL: "https://www.githubstatus.com",
                   endpoints: ["https://github.com/", "https://api.github.com/"]),
        SvcService(id: "atlassian", name: "Atlassian (Jira)", category: "Développement", format: .statuspage,
                   feedURL: "https://jira-software.status.atlassian.com/api/v2/summary.json",
                   pageURL: "https://jira-software.status.atlassian.com",
                   endpoints: ["https://id.atlassian.com/"]),
        SvcService(id: "zoom", name: "Zoom", category: "Collaboration", format: .statuspage,
                   feedURL: "https://status.zoom.us/api/v2/summary.json",
                   pageURL: "https://status.zoom.us",
                   endpoints: ["https://zoom.us/"]),
        SvcService(id: "slack", name: "Slack", category: "Collaboration", format: .slack,
                   feedURL: "https://slack-status.com/api/v2.0.0/current",
                   pageURL: "https://slack-status.com",
                   endpoints: ["https://slack.com/", "https://app.slack.com/"]),
        SvcService(id: "dropbox", name: "Dropbox", category: "Collaboration", format: .statuspage,
                   feedURL: "https://status.dropbox.com/api/v2/summary.json",
                   pageURL: "https://status.dropbox.com",
                   endpoints: ["https://www.dropbox.com/"]),
    ]

    /// Retrouve un service par identifiant ou par nom (sans tenir compte de la casse ni des accents).
    public static func find(_ text: String, in services: [SvcService]) -> SvcService? {
        let key = normalize(text)
        guard !key.isEmpty else { return nil }
        return services.first { normalize($0.id) == key }
            ?? services.first { normalize($0.name) == key }
            ?? services.first { normalize($0.name).hasPrefix(key) }
    }

    /// Catalogue enregistré fusionné avec la liste intégrée : un service intégré absent de
    /// l'enregistrement (ajouté par une version plus récente) est ajouté, actif.
    public static func merged(saved: [SvcService]) -> [SvcService] {
        // Services intégrés : la définition de cette version (adresses à jour), seul le choix
        // « suivi ou non » vient de la copie enregistrée.
        let current = Dictionary(builtIn.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = saved.map { service -> SvcService in
            guard !service.isCustom, var fresh = current[service.id] else { return service }
            fresh.isEnabled = service.isEnabled
            return fresh
        }
        let known = Set(saved.map(\.id))
        for service in builtIn where !known.contains(service.id) {
            result.append(service)
        }
        return result
    }

    /// Identifiant libre pour un service ajouté (« perso-intranet », « perso-intranet-2 »).
    public static func customID(for name: String, existing: [SvcService]) -> String {
        let base = "perso-" + normalize(name).replacingOccurrences(of: " ", with: "-")
        let ids = Set(existing.map(\.id))
        guard ids.contains(base) else { return base }
        var counter = 2
        while ids.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }

    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
    }

    /// Adresse clé normalisée (« outlook.office365.com » → « https://outlook.office365.com/ ») ;
    /// nil si ce n'est pas une adresse https valide.
    public static func endpoint(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), url.scheme?.lowercased() == "https", let host = url.host,
              !host.isEmpty, !host.contains(" ") else { return nil }
        return url.path.isEmpty ? candidate + "/" : candidate
    }
}
