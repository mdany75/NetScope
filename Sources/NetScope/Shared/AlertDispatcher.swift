import Foundation
import NetScopeCore

/// Répartiteur des alertes envoyées hors du Mac (courriel, webhooks, ntfy et Pushover). Les émetteurs (Surveillance,
/// État des services, Test DHCP, Scanner) l'appellent d'une ligne : `AlertDispatcher.shared.emit(…)`.
///
/// - RIEN ne part tant que l'interrupteur général des alertes est coupé (désactivé par défaut) ;
/// - en démonstration et pendant les captures, rien n'est lu au Trousseau ni envoyé : les canaux
///   et le journal sont fictifs (DevTools/AlertsDemo.swift) ;
/// - les secrets (mot de passe SMTP, adresses des webhooks, en-tête d'authentification) sont lus
///   au Trousseau juste avant l'envoi, jamais gardés dans les réglages ni écrits au journal.
@MainActor
final class AlertDispatcher: ObservableObject {
    static let shared = AlertDispatcher()

    private enum Key {
        static let settings = "alertes.reglages"
        static let journal = "alertes.journal"
    }

    @Published var settings: AlertSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            if settings.isEnabled != oldValue.isEnabled {
                planner.reset()
                scheduleFlush()
            } else if settings.rules != oldValue.rules {
                planner.applyRules(settings.rules, previous: oldValue.rules)
                scheduleFlush()
            }
        }
    }
    @Published private(set) var journal: [AlertLogEntry] = []
    /// Canaux en cours d'envoi d'un test (bouton « Envoyer un test »).
    @Published private(set) var testing: Set<AlertChannel> = []
    /// Dernier résultat de test par canal (affiché sous le bouton).
    @Published private(set) var lastTest: [AlertChannel: AlertLogEntry] = [:]
    /// Secrets présents au Trousseau (sans leur valeur) : mot de passe, adresses masquées.
    @Published private(set) var hasPassword = false
    @Published private(set) var maskedURLs: [UUID: String] = [:]
    @Published private(set) var hasAuthValue: Set<UUID> = []
    /// Note 76 : jeton ntfy, jeton d'application et clé utilisateur Pushover présents au Trousseau.
    @Published private(set) var hasNtfyToken = false
    @Published private(set) var hasPushoverToken = false
    @Published private(set) var hasPushoverUser = false
    /// Événements retenus par les règles depuis le lancement (anti-rafale, silence…).
    @Published private(set) var skippedCount = 0
    @Published private(set) var lastSkipReason: AlertSkipReason?

    private var planner = AlertPlanner()
    private var flushTask: Task<Void, Never>?
    private let keychain = UpdKeychain(service: AlertSecretKey.service)
    private let defaults: UserDefaults?

    /// Démonstration ou capture : aucun envoi, aucun Trousseau.
    var isSandboxed: Bool { RegEnvironment.isSandboxed }

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        if RegEnvironment.isSandboxed {
            let demo = AlertsDemo.make()
            settings = demo.settings
            journal = demo.journal
            hasPassword = true
            maskedURLs = demo.maskedURLs
            hasAuthValue = demo.authHeaders
            hasNtfyToken = demo.hasNtfyToken
            hasPushoverToken = demo.hasPushoverKeys
            hasPushoverUser = demo.hasPushoverKeys
            return
        }
        if let data = defaults?.data(forKey: Key.settings), let saved = try? JSONDecoder().decode(AlertSettings.self, from: data) {
            settings = saved
        } else {
            settings = AlertSettings()
        }
        if let data = defaults?.data(forKey: Key.journal), let saved = try? JSONDecoder().decode([AlertLogEntry].self, from: data) {
            journal = saved
        }
        // Le Trousseau n'est lu qu'à l'ouverture de Réglages › Alertes et juste avant un envoi.
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Key.settings)
    }

    private func saveJournal() {
        guard let defaults, let data = try? JSONEncoder().encode(journal) else { return }
        defaults.set(data, forKey: Key.journal)
    }

    // MARK: Émission

    /// Événement d'un émetteur (nil : rien à signaler). Ne fait rien si les alertes sont coupées.
    func emit(_ event: AlertEvent?) {
        guard var event, !isSandboxed else { return }
        // Note 76 : site de la sonde, pour le filtre par site des canaux de téléphone.
        if event.siteID == nil, let probeID = event.probeID, let probe = MonStore.shared.probes.first(where: { $0.id == probeID }) {
            event.siteID = MonStore.shared.site(of: probe)
        }
        let decision = planner.submit(event, settings: settings, hasChannel: !settings.enabledChannels.isEmpty, now: Date())
        if case .skipped(let reason) = decision {
            if reason != .alertsDisabled && reason != .kindDisabled {
                skippedCount += 1
                lastSkipReason = reason
            }
            return
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        guard let due = planner.nextFlush(rules: settings.rules) else { return }
        let delay = max(0, due.timeIntervalSinceNow)
        flushTask = Task { [weak self] in
            // Borne d'un an : un regroupement relu démesuré ne fait plus déborder UInt64.
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(min(delay, 365 * 86_400) * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        guard let batch = planner.flush(now: Date(), rules: settings.rules, force: true) else { return }
        // L'interrupteur a pu être coupé pendant le regroupement : rien ne part.
        guard settings.isEnabled else { return }
        for channel in settings.enabledChannels {
            // ntfy et Pushover : filtre propre (gravité, sites) après les règles communes.
            guard let filtered = settings.batch(batch, for: channel) else { continue }
            send(filtered, on: channel, isTest: false)
        }
    }

    // MARK: Envoi

    private func delivery() -> AlertDelivery {
        let origin = Host.current().localizedName ?? "Mac"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let ehlo = LocalInterfaces.primary().map { "[\($0.address)]" } ?? "[127.0.0.1]"
        return AlertDelivery(context: AlertContext(origin: origin, version: version), ehloName: ehlo)
    }

    private func readSecrets() -> AlertSecrets {
        var secrets = AlertSecrets(smtpPassword: keychain.string(for: AlertSecretKey.smtpPassword))
        for hook in settings.webhooks {
            secrets.webhookURLs[hook.id] = keychain.string(for: AlertSecretKey.webhookURL(hook.id))
            secrets.webhookAuth[hook.id] = keychain.string(for: AlertSecretKey.webhookAuth(hook.id))
        }
        // Le Trousseau n'est lu que pour les canaux de téléphone activés ou essayés.
        if settings.ntfy.isEnabled || testing.contains(.ntfy) {
            secrets.ntfyToken = keychain.string(for: AlertSecretKey.ntfyToken)
            if settings.ntfy.isPublicServer { secrets.ntfyTopic = settings.ntfy.topic }
        }
        if settings.pushover.isEnabled || testing.contains(.pushover) {
            secrets.pushoverToken = keychain.string(for: AlertSecretKey.pushoverToken)
            secrets.pushoverUser = keychain.string(for: AlertSecretKey.pushoverUser)
        }
        return secrets
    }

    private func send(_ batch: AlertBatch, on channel: AlertChannel, isTest: Bool) {
        let delivery = delivery()
        let settings = self.settings
        if isTest { testing.insert(channel) }
        let secrets = readSecrets()
        Task {
            let entry = await delivery.deliver(batch, on: channel, settings: settings, secrets: secrets)
            AlertDispatcher.shared.record(entry, channel: channel, isTest: isTest)
        }
    }

    private func record(_ entry: AlertLogEntry, channel: AlertChannel, isTest: Bool) {
        // Note 35 : un envoi en échec (SMTP refusé, webhook en erreur) va aussi au journal de l'app.
        if entry.outcome == .failed {
            AppLog.shared.error("Alertes", "\(entry.channelName)\(isTest ? " (essai)" : "")\u{00A0}: \(entry.detail)")
        }
        journal.insert(entry, at: 0)
        if journal.count > AlertLogEntry.limit { journal.removeLast(journal.count - AlertLogEntry.limit) }
        saveJournal()
        if isTest {
            testing.remove(channel)
            lastTest[channel] = entry
        }
    }

    /// Message d'essai sur un canal (après confirmation de l'utilisateur). Permis même alertes
    /// coupées : c'est une action explicite, et le seul envoi possible dans ce cas.
    func sendTest(_ channel: AlertChannel) {
        guard !testing.contains(channel) else { return }
        let origin = isSandboxed ? "MacBook de démonstration" : (Host.current().localizedName ?? "Mac")
        let batch = AlertBatch.test(now: Date(), origin: origin)
        if isSandboxed {
            // Démonstration : rien ne part, une ligne « Simulée » montre ce qui se passerait.
            let entry = AlertLogEntry(date: Date(), channelKind: kind(of: channel), channelName: settings.channelName(channel),
                                      outcome: .simulated, title: batch.title, eventCount: 1, severity: .info, isTest: true,
                                      detail: "Démonstration\u{00A0}: aucun envoi réel.", durationMs: nil)
            record(entry, channel: channel, isTest: true)
            return
        }
        send(batch, on: channel, isTest: true)
    }

    // MARK: Rapports planifiés (note 78)

    /// Serveur SMTP des Alertes, pour l'éditeur des rapports planifiés (« smtp.exemple.ca:587 »).
    var reportServerLabel: String? {
        let host = settings.smtp.host.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : "\(host):\(settings.smtp.port)"
    }

    /// Problèmes qui empêchent l'envoi d'un rapport planifié pour ce site (vide : prêt). Le Trousseau
    /// n'est pas relu ici : `refreshSecrets()` à l'ouverture de l'éditeur.
    func reportProblems(_ schedule: ReportSchedule, siteKey: String, siteName: String) -> [String] {
        let password = isSandboxed ? true : hasPassword
        return ReportMail.problems(smtp: settings.smtp, hasPassword: password, schedule: schedule, siteKey: siteKey, siteName: siteName)
    }

    /// Envoie un rapport planifié par le serveur SMTP des Alertes (même réglages, mot de passe lu au
    /// Trousseau juste avant). Jamais en démonstration ni pendant les captures. L'envoi est inscrit
    /// au journal des Alertes, sans secret. Renvoie la réussite et le détail à afficher.
    func sendReport(_ message: AlertMailMessage, title: String, isTest: Bool) async -> (ok: Bool, detail: String) {
        guard !isSandboxed else { return (false, "Démonstration\u{00A0}: aucun courriel n’est envoyé.") }
        let smtp = settings.smtp
        let secrets = readSecrets()
        let host = smtp.host.trimmingCharacters(in: .whitespaces)
        let ehlo = LocalInterfaces.primary().map { "[\($0.address)]" } ?? "[127.0.0.1]"
        let config = SMTPSubmitConfig(host: host, port: smtp.port, security: smtp.security,
                                      username: smtp.username.trimmingCharacters(in: .whitespaces),
                                      password: secrets.smtpPassword, ehloName: ehlo, timeout: 60)
        let transport = SMTPNetworkTransport(host: host, port: smtp.port, security: smtp.security)
        let outcome = await SMTPSubmission.send(message, config: config, transport: transport)
        let detail: String
        if let error = outcome.error {
            detail = error.errorDescription ?? error.shortLabel
        } else {
            detail = ReportMail.sentSummary(accepted: outcome.acceptedRecipients.count, rejected: outcome.rejectedRecipients)
                + (outcome.encrypted ? " · chiffré" : "")
        }
        let safe = AlertRedactor.redact(detail, secrets: secrets.all)
        let entry = AlertLogEntry(date: Date(), channelKind: "courriel", channelName: "Courriel · \(host)",
                                  outcome: outcome.error == nil ? .sent : .failed, title: title, eventCount: 1, severity: .info,
                                  isTest: isTest, detail: safe, durationMs: outcome.durationMs)
        record(entry, channel: .email, isTest: false)
        return (outcome.error == nil, safe)
    }

    func kind(of channel: AlertChannel) -> String {
        switch channel {
        case .email: return "courriel"
        case .webhook(let id): return settings.webhook(id)?.kind.rawValue ?? "webhook"
        case .ntfy: return "ntfy"
        case .pushover: return "pushover"
        }
    }

    func clearJournal() {
        journal = []
        saveJournal()
    }

    // MARK: Secrets (Trousseau)

    func refreshSecrets() {
        guard !isSandboxed else { return }
        hasPassword = !(keychain.string(for: AlertSecretKey.smtpPassword) ?? "").isEmpty
        var masked: [UUID: String] = [:]
        var auth: Set<UUID> = []
        for hook in settings.webhooks {
            if let url = keychain.string(for: AlertSecretKey.webhookURL(hook.id)), !url.isEmpty {
                masked[hook.id] = AlertRedactor.maskedWebhook(url)
            }
            if !(keychain.string(for: AlertSecretKey.webhookAuth(hook.id)) ?? "").isEmpty { auth.insert(hook.id) }
        }
        maskedURLs = masked
        hasAuthValue = auth
        hasNtfyToken = !(keychain.string(for: AlertSecretKey.ntfyToken) ?? "").isEmpty
        hasPushoverToken = !(keychain.string(for: AlertSecretKey.pushoverToken) ?? "").isEmpty
        hasPushoverUser = !(keychain.string(for: AlertSecretKey.pushoverUser) ?? "").isEmpty
    }

    /// Note 76 : enregistre un secret de ntfy ou de Pushover (vide : l'efface). Renvoie un
    /// message d'erreur éventuel. En démonstration, rien n'est écrit au Trousseau.
    @discardableResult
    func setPhoneSecret(_ value: String, account: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSandboxed else {
            switch account {
            case AlertSecretKey.ntfyToken: hasNtfyToken = !trimmed.isEmpty
            case AlertSecretKey.pushoverToken: hasPushoverToken = !trimmed.isEmpty
            case AlertSecretKey.pushoverUser: hasPushoverUser = !trimmed.isEmpty
            default: break
            }
            return nil
        }
        do {
            if trimmed.isEmpty { try keychain.delete(account) } else { try keychain.set(trimmed, for: account) }
            refreshSecrets()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Enregistre le mot de passe SMTP (vide : l'efface). Renvoie un message d'erreur éventuel.
    @discardableResult
    func setPassword(_ value: String) -> String? {
        guard !isSandboxed else { return nil }
        do {
            try keychain.set(value, for: AlertSecretKey.smtpPassword)
            refreshSecrets()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Ajoute ou modifie un webhook ; `url` et `auth` nil : inchangés, vides : effacés.
    @discardableResult
    func saveWebhook(_ hook: AlertWebhook, url: String?, auth: String?) -> String? {
        if let index = settings.webhooks.firstIndex(where: { $0.id == hook.id }) {
            settings.webhooks[index] = hook
        } else {
            settings.webhooks.append(hook)
        }
        guard !isSandboxed else {
            if let url, !url.isEmpty { maskedURLs[hook.id] = AlertRedactor.maskedWebhook(url) }
            return nil
        }
        do {
            if let url { try keychain.set(url.trimmingCharacters(in: .whitespacesAndNewlines), for: AlertSecretKey.webhookURL(hook.id)) }
            if let auth { try keychain.set(auth, for: AlertSecretKey.webhookAuth(hook.id)) }
            refreshSecrets()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func removeWebhook(_ id: UUID) {
        settings.webhooks.removeAll { $0.id == id }
        maskedURLs[id] = nil
        hasAuthValue.remove(id)
        lastTest[.webhook(id)] = nil
        guard !isSandboxed else { return }
        try? keychain.delete(AlertSecretKey.webhookURL(id))
        try? keychain.delete(AlertSecretKey.webhookAuth(id))
    }

    // MARK: État

    /// Canal prêt à envoyer (réglages complets, secret présent).
    func isReady(_ channel: AlertChannel) -> Bool {
        switch channel {
        case .email: return settings.smtp.problems(hasPassword: hasPassword).isEmpty
        case .webhook(let id): return maskedURLs[id] != nil
        case .ntfy: return settings.ntfy.problems().isEmpty
        case .pushover: return settings.pushover.problems(hasToken: hasPushoverToken, hasUserKey: hasPushoverUser).isEmpty
        }
    }

    /// Indication de la Surveillance : où partent les alertes de cette sonde.
    func channelSummary(forProbe id: UUID) -> (text: String, active: Bool) {
        guard settings.isEnabled else { return ("Alertes hors du Mac désactivées", false) }
        if settings.rules.excludedProbes.contains(id) { return ("Sonde exclue des alertes", false) }
        let site = MonStore.shared.probes.first { $0.id == id }.flatMap { MonStore.shared.site(of: $0) }
        let channels = settings.channels(forProbe: id, siteID: site)
        guard !channels.isEmpty else { return ("Aucun canal activé", false) }
        let names = channels.map { channel -> String in
            switch channel {
            case .email: return "Courriel"
            case .webhook(let hookID): return settings.webhook(hookID)?.kind.shortLabel ?? "Webhook"
            case .ntfy: return "ntfy"
            case .pushover: return "Pushover"
            }
        }
        var seen = Set<String>()
        return (names.filter { seen.insert($0).inserted }.joined(separator: " · "), true)
    }

    func setExcluded(_ excluded: Bool, probe id: UUID) {
        if excluded { settings.rules.excludedProbes.insert(id) } else { settings.rules.excludedProbes.remove(id) }
    }
}
