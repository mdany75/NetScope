import Foundation
import NetScopeCore

/// Démonstration de Réglages › Alertes (--demo, --snapshot) : canaux fictifs (smtp.exemple.ca,
/// webhook Teams masqué, ntfy et Pushover de la note 76…) et journal crédible. Rien n'est lu au Trousseau ni envoyé : le
/// répartiteur ne fait aucun envoi réel en démonstration, quel que soit l'interrupteur.
/// NETSCOPE_REGLAGES_SECTION=alertes ouvre directement cette section (captures).
@MainActor
enum AlertsDemo {
    struct Content {
        var settings: AlertSettings
        var journal: [AlertLogEntry]
        var maskedURLs: [UUID: String]
        var authHeaders: Set<UUID>
        /// Note 76 : secrets fictifs « présents au Trousseau » (rien n'y est lu).
        var hasNtfyToken: Bool
        var hasPushoverKeys: Bool
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
        settings.smtp.fromName = "NetScope · Siège"
        settings.smtp.recipients = ["dany.menard@exemple.ca", "soutien-ti@exemple.ca"]
        settings.webhooks = [
            AlertWebhook(id: teamsID, kind: .teams, name: "Exploitation TI"),
            AlertWebhook(id: slackID, kind: .slack, name: "#reseau-alertes", isEnabled: false),
            AlertWebhook(id: genericID, kind: .generic, name: "Supervision (n8n)", authHeaderName: "Authorization"),
        ]
        settings.rules.quietHours = AlertQuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        // Note 76 : ntfy sur ntfy.sh (sujet difficile à deviner), alerte et critique seulement ;
        // Pushover pour le critique des sites Siège et Entrepôt Laval, sirène sur l'iPhone.
        settings.ntfy.isEnabled = true
        settings.ntfy.topic = "netscope-siege-k7m2q9xh4tr3"
        settings.ntfy.tags = ["siege", "reseau"]
        settings.ntfy.filter = AlertChannelFilter(minimumSeverity: .warning)
        settings.pushover.isEnabled = true
        settings.pushover.sound = "siren"
        settings.pushover.device = "iphone-dany"
        settings.pushover.priorities = AlertPriorityMap(info: -1, warning: 0, critical: 2)
        settings.pushover.filter = AlertChannelFilter(minimumSeverity: .critical, siteIDs: [SitesDemo.siegeID, SitesDemo.lavalID])
        return Content(settings: settings, journal: journal(),
                       maskedURLs: [teamsID: "prod-27.westus.logic.azure.com/…k3Qa", slackID: "hooks.slack.com/…Xz9P",
                                    genericID: "n8n.exemple.ca/…erte"],
                       authHeaders: [genericID], hasNtfyToken: false, hasPushoverKeys: true)
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
        let ntfy = "ntfy · netscope-siege-k7m2q9xh4tr3"
        let pushover = "Pushover"
        return [
            AlertLogEntry(date: ago(6), channelKind: "pushover", channelName: pushover, outcome: .sent, title: "Caméra-Quai hors ligne",
                          eventCount: 1, severity: .critical, isTest: false,
                          detail: "HTTP 200 · priorité 2 · demande 5042853c-402d-4a18-abcb-168734a801de", durationMs: 318),
            AlertLogEntry(date: ago(6), channelKind: "ntfy", channelName: ntfy, outcome: .sent, title: "Caméra-Quai hors ligne",
                          eventCount: 1, severity: .critical, isTest: false, detail: "HTTP 200 · message sPs71M8A2T · priorité 5",
                          durationMs: 204),
            AlertLogEntry(date: ago(6), channelKind: "teams", channelName: teams, outcome: .sent, title: "Caméra-Quai hors ligne",
                          eventCount: 1, severity: .critical, isTest: false, detail: "HTTP 202", durationMs: 412),
            AlertLogEntry(date: ago(6), channelKind: "courriel", channelName: mail, outcome: .sent, title: "Caméra-Quai hors ligne",
                          eventCount: 1, severity: .critical, isTest: false,
                          detail: "250 2.0.0 Ok: queued as 4C1F82A0E3 · 2 destinataires · chiffré", durationMs: 1_840),
            AlertLogEntry(date: ago(6), channelKind: "generic", channelName: json, outcome: .failed, title: "Caméra-Quai hors ligne",
                          eventCount: 1, severity: .critical, isTest: false,
                          detail: "Le service est en panne ou indisponible (503). Réponse\u{00A0}: «\u{00A0}Service Unavailable\u{00A0}».", durationMs: 5_012),
            // Note 78 (0.26.0) : événements dédiés (WAN, licence) au lieu de « sonde en panne ».
            AlertLogEntry(date: ago(19), channelKind: "teams", channelName: teams, outcome: .sent, title: "WAN en panne · Siège / wan2",
                          eventCount: 1, severity: .critical, isTest: false, detail: "HTTP 202", durationMs: 397),
            AlertLogEntry(date: ago(19), channelKind: "courriel", channelName: mail, outcome: .sent, title: "WAN en panne · Siège / wan2",
                          eventCount: 1, severity: .critical, isTest: false,
                          detail: "250 2.0.0 Ok: queued as 7E30A9C412 · 2 destinataires · chiffré", durationMs: 1_710),
            AlertLogEntry(date: ago(19), channelKind: "ntfy", channelName: ntfy, outcome: .failed, title: "WAN en panne · Siège / wan2",
                          eventCount: 1, severity: .critical, isTest: false,
                          detail: "Trop de messages (429)\u{00A0}: ntfy limite les envois, réessayez plus tard. Réponse\u{00A0}: «\u{00A0}limit reached: too many requests\u{00A0}».",
                          durationMs: 186),
            AlertLogEntry(date: ago(31), channelKind: "ntfy", channelName: ntfy, outcome: .sent,
                          title: "Licence à renouveler · FortiGuard IPS (FGT-SIEGE)", eventCount: 1, severity: .warning, isTest: false,
                          detail: "HTTP 200 · message Hc4fT0aZ1q · priorité 4", durationMs: 221),
            AlertLogEntry(date: ago(31), channelKind: "courriel", channelName: mail, outcome: .sent,
                          title: "Licence à renouveler · FortiGuard IPS (FGT-SIEGE)", eventCount: 1, severity: .warning, isTest: false,
                          detail: "250 2.0.0 Ok: queued as 5B82D0E6F1 · 2 destinataires · chiffré", durationMs: 1_588),
            AlertLogEntry(date: ago(48), channelKind: "teams", channelName: teams, outcome: .sent, title: "3 alertes NetScope",
                          eventCount: 3, severity: .warning, isTest: false, detail: "HTTP 202", durationMs: 388),
            AlertLogEntry(date: ago(48), channelKind: "courriel", channelName: mail, outcome: .sent, title: "3 alertes NetScope",
                          eventCount: 3, severity: .warning, isTest: false,
                          detail: "250 2.0.0 Ok: queued as 9A7E21B4C0 · 2 destinataires · chiffré", durationMs: 1_652),
            AlertLogEntry(date: ago(60 * 21), channelKind: "pushover", channelName: pushover, outcome: .sent,
                          title: "Message d’essai de NetScope", eventCount: 1, severity: .info, isTest: true,
                          detail: "HTTP 200 · priorité 0 · demande 9b1f2c7e-5d3a-4e8f-a0b1-6c2d3e4f5a6b", durationMs: 296),
            AlertLogEntry(date: ago(60 * 21 + 2), channelKind: "pushover", channelName: pushover, outcome: .failed,
                          title: "Message d’essai de NetScope", eventCount: 1, severity: .info, isTest: true,
                          detail: "Message refusé par Pushover (400). Réponse\u{00A0}: «\u{00A0}user identifier is not a valid user, group, or subscribed user key\u{00A0}».",
                          durationMs: 274),
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
