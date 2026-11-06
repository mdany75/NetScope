import Foundation
import NetScopeCore
import Security

/// Alertes de l'agent : mêmes réglages que l'app (Réglages › Alertes, lus dans ses préférences), même
/// filtre (interrupteur général, types d'alerte, silence, anti-rafale), mêmes canaux. Les secrets sont
/// lus au Trousseau juste avant l'envoi, jamais écrits ailleurs. Envoi immédiat (pas de regroupement).
///
/// Limite connue : les secrets ont été créés par l'app ; l'agent est un autre binaire (signé
/// com.danymenard.netscope.agent), absent de la liste d'accès de ces éléments. macOS peut donc
/// demander l'accès au nom de « NetScopeAgent » (à chaque nouvelle signature ad hoc) ou le refuser.
/// Un secret illisible est noté au journal de l'agent ; l'alerte part sans lui (ou échoue).
struct AgentAlerts {
    private var planner = AlertPlanner()
    private let keychain = UpdKeychain(service: AlertSecretKey.service)

    /// Envoie l'alerte ; renvoie les problèmes à noter au journal de l'agent (réglages introuvables,
    /// secrets illisibles).
    mutating func submit(_ event: AlertEvent, defaults: UserDefaults?) -> [String] {
        guard let defaults else { return ["Alerte non envoyée\u{00A0}: préférences de NetScope inaccessibles."] }
        guard let data = defaults.data(forKey: "alertes.reglages") else {
            return ["Alerte non envoyée\u{00A0}: réglages d’alerte introuvables (Réglages › Alertes)."]
        }
        guard let settings = try? JSONDecoder().decode(AlertSettings.self, from: data) else {
            return ["Alerte non envoyée\u{00A0}: réglages d’alerte illisibles."]
        }
        let now = Date()
        let decision = planner.submit(event, settings: settings, hasChannel: !settings.enabledChannels.isEmpty, now: now)
        if case .skipped = decision { return [] }
        guard let batch = planner.flush(now: now, rules: settings.rules, force: true), settings.isEnabled else { return [] }
        var unreadable: [String] = []
        func secret(_ account: String) -> String? {
            let found = keychain.lookup(account)
            if found.value == nil, found.status != errSecItemNotFound {
                let reason = SecCopyErrorMessageString(found.status, nil) as String? ?? "code \(found.status)"
                unreadable.append("\(account) (\(reason))")
            }
            return found.value
        }
        var secrets = AlertSecrets(smtpPassword: secret(AlertSecretKey.smtpPassword))
        for hook in settings.webhooks {
            secrets.webhookURLs[hook.id] = secret(AlertSecretKey.webhookURL(hook.id))
            secrets.webhookAuth[hook.id] = secret(AlertSecretKey.webhookAuth(hook.id))
        }
        if settings.ntfy.isEnabled {
            secrets.ntfyToken = secret(AlertSecretKey.ntfyToken)
            if settings.ntfy.isPublicServer { secrets.ntfyTopic = settings.ntfy.topic }
        }
        if settings.pushover.isEnabled {
            secrets.pushoverToken = secret(AlertSecretKey.pushoverToken)
            secrets.pushoverUser = secret(AlertSecretKey.pushoverUser)
        }
        let origin = (Host.current().localizedName ?? "Mac") + " (agent)"
        let delivery = AlertDelivery(context: AlertContext(origin: origin, version: AgentService.version),
                                     ehloName: LocalInterfaces.primary().map { "[\($0.address)]" } ?? "[127.0.0.1]")
        for channel in settings.enabledChannels {
            guard let filtered = settings.batch(batch, for: channel) else { continue }
            let secretsCopy = secrets
            Task { _ = await delivery.deliver(filtered, on: channel, settings: settings, secrets: secretsCopy) }
        }
        guard !unreadable.isEmpty else { return [] }
        return ["Secrets d’alerte illisibles au Trousseau par l’agent\u{00A0}: " + unreadable.joined(separator: ", ")
                + ". L’alerte est partie sans eux. Ouvrez NetScope et autorisez «\u{00A0}NetScopeAgent\u{00A0}» si macOS le demande."]
    }
}
