import Foundation
import NetScopeCore

/// Alertes de l'agent : mêmes réglages que l'app (Réglages › Alertes, lus dans ses préférences), même
/// filtre (interrupteur général, types d'alerte, silence, anti-rafale), mêmes canaux. Les secrets sont
/// lus au Trousseau juste avant l'envoi, jamais écrits ailleurs. Envoi immédiat (pas de regroupement).
struct AgentAlerts {
    private var planner = AlertPlanner()
    private let keychain = UpdKeychain(service: AlertSecretKey.service)

    mutating func submit(_ event: AlertEvent, defaults: UserDefaults?) {
        guard let data = defaults?.data(forKey: "alertes.reglages"),
              let settings = try? JSONDecoder().decode(AlertSettings.self, from: data) else { return }
        let now = Date()
        let decision = planner.submit(event, settings: settings, hasChannel: !settings.enabledChannels.isEmpty, now: now)
        if case .skipped = decision { return }
        guard let batch = planner.flush(now: now, rules: settings.rules, force: true), settings.isEnabled else { return }
        var secrets = AlertSecrets(smtpPassword: keychain.string(for: AlertSecretKey.smtpPassword))
        for hook in settings.webhooks {
            secrets.webhookURLs[hook.id] = keychain.string(for: AlertSecretKey.webhookURL(hook.id))
            secrets.webhookAuth[hook.id] = keychain.string(for: AlertSecretKey.webhookAuth(hook.id))
        }
        if settings.ntfy.isEnabled {
            secrets.ntfyToken = keychain.string(for: AlertSecretKey.ntfyToken)
            if settings.ntfy.isPublicServer { secrets.ntfyTopic = settings.ntfy.topic }
        }
        if settings.pushover.isEnabled {
            secrets.pushoverToken = keychain.string(for: AlertSecretKey.pushoverToken)
            secrets.pushoverUser = keychain.string(for: AlertSecretKey.pushoverUser)
        }
        let origin = (Host.current().localizedName ?? "Mac") + " (agent)"
        let delivery = AlertDelivery(context: AlertContext(origin: origin, version: AgentService.version),
                                     ehloName: LocalInterfaces.primary().map { "[\($0.address)]" } ?? "[127.0.0.1]")
        for channel in settings.enabledChannels {
            guard let filtered = settings.batch(batch, for: channel) else { continue }
            let secretsCopy = secrets
            Task { _ = await delivery.deliver(filtered, on: channel, settings: settings, secrets: secretsCopy) }
        }
    }
}
