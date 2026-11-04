import Foundation
import NetScopeCore

/// Démonstration de Réglages › Alertes (--demo, --snapshot) : canaux fictifs (smtp.exemple.ca,
/// webhook Teams masqué…) et journal crédible. Rien n'est lu au Trousseau ni envoyé : le
/// répartiteur ne fait aucun envoi réel en démonstration, quel que soit l'interrupteur.
/// NETSCOPE_REGLAGES_SECTION=alertes ouvre directement cette section (captures).
@MainActor
enum AlertsDemo {
    struct Content {
        var settings: AlertSettings
        var journal: [AlertLogEntry]
        var maskedURLs: [UUID: String]
        var authHeaders: Set<UUID>
    }

    static let teamsID = UUID(uuidString: "5B0D3C1E-7A62-4F0B-9D3E-1C2A6E8F4B01")!
    static let slackID = UUID(uuidString: "0E7F2A9C-3B14-4C8D-A6E5-9F1B2C3D4E02")!
    static let genericID = UUID(uuidString: "C4A1B2D3-E5F6-4A7B-8C9D-0E1F2A3B4C03")!

    static func make() -> Content {
        var settings = AlertSettings()
        settings.isEnabled = true
        settings.smtp.isEnabled = true
        settings.smtp.host = "smtp.exemple.ca"
        settings.smtp.port = 587
        settings.smtp.security = .startTLS
        settings.smtp.username = "alertes@exemple.ca"
        settings.smtp.from = "alertes@exemple.ca"
        settings.smtp.fromName = "NetScope · Entrepôt"
        settings.smtp.recipients = ["dany.menard@exemple.ca", "soutien-ti@exemple.ca"]
        settings.webhooks = [
            AlertWebhook(id: teamsID, kind: .teams, name: "Exploitation TI"),
            AlertWebhook(id: slackID, kind: .slack, name: "#reseau-alertes", isEnabled: false),
            AlertWebhook(id: genericID, kind: .generic, name: "Supervision (n8n)", authHeaderName: "Authorization"),
        ]
        settings.rules.quietHours = AlertQuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        return Content(settings: settings, journal: journal(),
                       maskedURLs: [teamsID: "prod-27.westus.logic.azure.com/…k3Qa", slackID: "hooks.slack.com/…Xz9P",
                                    genericID: "n8n.exemple.ca/…erte"],
                       authHeaders: [genericID])
    }

    /// Heure de référence : 14 h 32 aujourd'hui en capture (images stables), maintenant sinon.
    private static var now: Date {
        let calendar = Calendar.current
        guard CommandLine.arguments.contains("--snapshot") else { return Date() }
        return calendar.date(bySettingHour: 14, minute: 32, second: 0, of: Date()) ?? Date()
    }

    private static func journal() -> [AlertLogEntry] {
        let now = self.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let mail = "Courriel · smtp.exemple.ca"
        let teams = "Teams · Exploitation TI"
        let json = "JSON · Supervision (n8n)"
        let slack = "Slack · #reseau-alertes"
        return [
            AlertLogEntry(date: ago(6), channelKind: "teams", channelName: teams, outcome: .sent, title: "Caméra-Quai hors ligne",
                          eventCount: 1, severity: .critical, isTest: false, detail: "HTTP 202", durationMs: 412),
            AlertLogEntry(date: ago(6), channelKind: "courriel", channelName: mail, outcome: .sent, title: "Caméra-Quai hors ligne",
                          eventCount: 1, severity: .critical, isTest: false,
                          detail: "250 2.0.0 Ok: queued as 4C1F82A0E3 · 2 destinataires · chiffré", durationMs: 1_840),
            AlertLogEntry(date: ago(6), channelKind: "generic", channelName: json, outcome: .failed, title: "Caméra-Quai hors ligne",
                          eventCount: 1, severity: .critical, isTest: false,
                          detail: "Le service est en panne ou indisponible (503). Réponse\u{00A0}: «\u{00A0}Service Unavailable\u{00A0}».", durationMs: 5_012),
            AlertLogEntry(date: ago(48), channelKind: "teams", channelName: teams, outcome: .sent, title: "3 alertes NetScope",
                          eventCount: 3, severity: .warning, isTest: false, detail: "HTTP 202", durationMs: 388),
            AlertLogEntry(date: ago(48), channelKind: "courriel", channelName: mail, outcome: .sent, title: "3 alertes NetScope",
                          eventCount: 3, severity: .warning, isTest: false,
                          detail: "250 2.0.0 Ok: queued as 9A7E21B4C0 · 2 destinataires · chiffré", durationMs: 1_652),
            AlertLogEntry(date: ago(60 * 22 + 10), channelKind: "courriel", channelName: mail, outcome: .sent,
                          title: "Message d’essai de NetScope", eventCount: 1, severity: .info, isTest: true,
                          detail: "250 2.0.0 Ok: queued as 1D0B5F7731 · 2 destinataires · chiffré", durationMs: 1_903),
            AlertLogEntry(date: ago(60 * 22 + 12), channelKind: "courriel", channelName: mail, outcome: .failed,
                          title: "Message d’essai de NetScope", eventCount: 1, severity: .info, isTest: true,
                          detail: "Authentification refusée (535 5.7.139 Authentication unsuccessful, SmtpClientAuthentication is disabled for the Tenant). Vérifiez l’utilisateur et le mot de passe\u{00A0}; Microsoft 365 et Gmail demandent souvent un mot de passe d’application ou l’activation de SMTP AUTH.",
                          durationMs: 1_210),
            AlertLogEntry(date: ago(60 * 46), channelKind: "slack", channelName: slack, outcome: .sent,
                          title: "Serveur DHCP non autorisé\u{00A0}: 10.182.122.250", eventCount: 1, severity: .critical, isTest: false,
                          detail: "HTTP 200 · ok", durationMs: 296),
        ]
    }
}
