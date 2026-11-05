import Foundation

// Alertes envoyées hors du Mac (note 13, 0.8.0) : modèle commun aux canaux courriel (SMTP) et
// webhook (Microsoft Teams, Slack, JSON générique). Rien ici n'ouvre de connexion.
//
// Les réglages (AlertSettings) ne contiennent AUCUN secret : le mot de passe SMTP, les adresses
// des webhooks et l'en-tête d'authentification restent au Trousseau (AlertSecretKey).

// MARK: - Événements

/// Gravité d'une alerte, de la plus faible à la plus forte.
public enum AlertSeverity: String, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    case info, warning, critical

    public var id: String { rawValue }

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool { lhs.rank < rhs.rank }

    /// « Info », « Alerte », « Critique » (mêmes mots que le journal de la Surveillance).
    public var label: String {
        switch self {
        case .info: return "Info"
        case .warning: return "Alerte"
        case .critical: return "Critique"
        }
    }
}

/// Type d'événement qui peut déclencher une alerte.
public enum AlertEventKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Sonde de la Surveillance hors ligne.
    case probeDown = "sonde.panne"
    /// Sonde en alerte (latence, perte, condition non remplie).
    case probeWarning = "sonde.alerte"
    /// Sonde revenue à la normale (envoyée seulement si sa panne a été envoyée).
    case probeRecovered = "sonde.retablie"
    /// Nouvel appareil sur le réseau (scan ou sonde « Nouveaux appareils »).
    case newDevice = "appareil.nouveau"
    /// Serveur DHCP non autorisé (Test DHCP de la Boîte à outils).
    case rogueDHCP = "dhcp.non-autorise"
    /// Incident d'un grand service en ligne (outil « État des services »).
    case serviceIncident = "service.incident"
    /// Fin d'un scan du réseau.
    case scanFinished = "scan.termine"
    /// Note 78 (0.26.0) : événements dédiés des sondes, au lieu d'un « sonde en panne » générique.
    /// Licence FortiGuard ou FortiCare bientôt expirée.
    case licenseExpiring = "licence.expire"
    /// Firmware à mettre à jour.
    case firmwareOutdated = "firmware.maj"
    /// Message Syslog (ou de la FortiGate) grave.
    case syslogSevere = "syslog.grave"
    /// Lien WAN ou tunnel VPN en panne.
    case wanDown = "wan.panne"
    /// Message d'essai (bouton « Envoyer un test »).
    case test = "test"

    public var id: String { rawValue }

    /// Types réglables dans les règles (le test est toujours permis).
    public static var configurable: [AlertEventKind] { allCases.filter { $0 != .test } }

    public var label: String {
        switch self {
        case .probeDown: return "Sonde en panne"
        case .probeWarning: return "Sonde en alerte"
        case .probeRecovered: return "Sonde rétablie"
        case .newDevice: return "Nouvel appareil"
        case .rogueDHCP: return "Serveur DHCP non autorisé"
        case .serviceIncident: return "Incident d’un service en ligne"
        case .scanFinished: return "Fin de scan"
        case .licenseExpiring: return "Licence bientôt expirée"
        case .firmwareOutdated: return "Firmware à mettre à jour"
        case .syslogSevere: return "Message Syslog grave"
        case .wanDown: return "WAN en panne"
        case .test: return "Message d’essai"
        }
    }

    public var detail: String {
        switch self {
        case .probeDown: return "Après les échecs consécutifs réglés dans la sonde."
        case .probeWarning: return "Latence, perte ou condition au-delà du seuil."
        case .probeRecovered: return "Envoyée seulement si la panne a été signalée."
        case .newDevice: return "MAC jamais vue sur la plage, à la fin d’un scan."
        case .rogueDHCP: return "Offre DHCP reçue d’un serveur hors de la liste autorisée."
        case .serviceIncident: return "Nouvel incident ou service injoignable d’ici (Microsoft 365, GitHub…)."
        case .scanFinished: return "Résumé du scan\u{00A0}: appareils en ligne et nouveaux."
        case .licenseExpiring: return "Sonde «\u{00A0}Licence\u{00A0}»\u{00A0}: FortiGuard ou FortiCare à renouveler dans le délai réglé."
        case .firmwareOutdated: return "Sonde «\u{00A0}Firmware\u{00A0}»\u{00A0}: une version plus récente est publiée."
        case .syslogSevere: return "Sonde «\u{00A0}Syslog\u{00A0}»\u{00A0}: message de gravité égale ou supérieure au seuil."
        case .wanDown: return "Sondes «\u{00A0}WAN\u{00A0}» et «\u{00A0}VPN\u{00A0}»\u{00A0}: lien Internet ou tunnel tombé."
        case .test: return "Bouton «\u{00A0}Envoyer un test\u{00A0}»."
        }
    }

    /// Gravité habituelle de ce type (affichée à côté de la règle).
    public var typicalSeverity: AlertSeverity {
        switch self {
        case .probeDown, .rogueDHCP, .wanDown: return .critical
        case .probeWarning, .serviceIncident, .licenseExpiring, .firmwareOutdated, .syslogSevere: return .warning
        case .probeRecovered, .newDevice, .scanFinished, .test: return .info
        }
    }
}

/// Événement transmis au répartiteur d'alertes. Type minimal, indépendant des autres modules
/// (Surveillance, services, DHCP, scan) : chaque émetteur le construit par un adaptateur
/// (`AlertEvent.probe…`, `AlertEvent.service…`, etc.).
public struct AlertEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: AlertEventKind
    public var severity: AlertSeverity
    /// Titre court (« Caméra-Quai hors ligne »).
    public var title: String
    /// Phrase d'explication (« Aucune réponse après 3 tentatives »).
    public var message: String
    /// Objet concerné, clé de l'anti-rafale (identifiant de sonde, MAC, adresse du serveur DHCP…).
    public var subject: String
    public var occurredAt: Date
    /// Précisions affichées en tableau (« Cible : 192.168.50.21 »), dans l'ordre.
    public var details: [AlertDetail]
    /// Sonde de la Surveillance à l'origine de l'événement (exclusions par sonde).
    public var probeID: UUID?
    /// Note 76 : site de l'événement (filtre par site des canaux de téléphone) ; nil : sans site.
    public var siteID: UUID?

    public init(id: UUID = UUID(), kind: AlertEventKind, severity: AlertSeverity? = nil, title: String, message: String,
                subject: String, occurredAt: Date = Date(), details: [AlertDetail] = [], probeID: UUID? = nil, siteID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.severity = severity ?? kind.typicalSeverity
        self.title = AlertText.singleLine(title)
        self.message = message
        self.subject = subject
        self.occurredAt = occurredAt
        self.details = details
        self.probeID = probeID
        self.siteID = siteID
    }

    /// Clé de l'anti-rafale : un type d'événement pour un objet.
    public var throttleKey: String { "\(kind.rawValue)|\(subject)" }
}

/// Précision d'un événement (libellé, valeur).
public struct AlertDetail: Codable, Hashable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = AlertText.singleLine(label)
        self.value = value
    }
}

// MARK: - Canaux

/// Sécurité de la connexion SMTP.
public enum AlertSMTPSecurity: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Session en clair puis STARTTLS obligatoire (port 587).
    case startTLS
    /// TLS dès la connexion (port 465).
    case implicitTLS
    /// Aucun chiffrement : relais interne seulement, sans mot de passe.
    case none

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .startTLS: return "STARTTLS"
        case .implicitTLS: return "TLS"
        case .none: return "Aucune"
        }
    }

    /// Port habituel de ce mode.
    public var defaultPort: UInt16 {
        switch self {
        case .startTLS: return 587
        case .implicitTLS: return 465
        case .none: return 25
        }
    }

    public var explanation: String {
        switch self {
        case .startTLS: return "Connexion en clair puis chiffrement obligatoire (STARTTLS), port 587 en général."
        case .implicitTLS: return "Chiffrement dès la connexion (TLS implicite), port 465 en général."
        case .none: return "Aucun chiffrement\u{00A0}: relais interne seulement, jamais de mot de passe."
        }
    }
}

/// Encodage du corps des courriels.
public enum AlertMailEncoding: String, Codable, CaseIterable, Sendable {
    case quotedPrintable, base64
}

/// Réglages du canal courriel (sans le mot de passe, gardé au Trousseau).
public struct AlertSMTPSettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var host = ""
    public var port: UInt16 = 587
    public var security: AlertSMTPSecurity = .startTLS
    public var username = ""
    /// Adresse de l'expéditeur (souvent le compte lui-même).
    public var from = ""
    public var fromName = "NetScope"
    /// Destinataires (adresses séparées par des virgules dans l'interface).
    public var recipients: [String] = []
    public var encoding: AlertMailEncoding = .quotedPrintable

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 587
        security = try c.decodeIfPresent(AlertSMTPSecurity.self, forKey: .security) ?? .startTLS
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        fromName = try c.decodeIfPresent(String.self, forKey: .fromName) ?? "NetScope"
        recipients = try c.decodeIfPresent([String].self, forKey: .recipients) ?? []
        encoding = try c.decodeIfPresent(AlertMailEncoding.self, forKey: .encoding) ?? .quotedPrintable
    }

    /// Problèmes qui empêchent l'envoi (vide : prêt). `hasPassword` : mot de passe au Trousseau.
    public func problems(hasPassword: Bool) -> [String] {
        var list: [String] = []
        let server = host.trimmingCharacters(in: .whitespaces)
        if server.isEmpty {
            list.append("Serveur SMTP à renseigner.")
        } else if !AlertText.isValidHostname(server) {
            list.append("Nom de serveur invalide\u{00A0}: «\u{00A0}\(server)\u{00A0}».")
        }
        if port == 0 { list.append("Port invalide.") }
        if !AlertAddress.isValid(from) { list.append("Adresse de l’expéditeur invalide ou manquante.") }
        let valid = recipients.filter(AlertAddress.isValid)
        if valid.isEmpty { list.append("Au moins un destinataire valide est nécessaire.") }
        if let bad = recipients.first(where: { !AlertAddress.isValid($0) }) {
            list.append("Destinataire invalide\u{00A0}: «\u{00A0}\(bad)\u{00A0}».")
        }
        let user = username.trimmingCharacters(in: .whitespaces)
        if security == .none && !user.isEmpty {
            list.append("Sans chiffrement, NetScope n’envoie jamais de mot de passe\u{00A0}: choisissez STARTTLS ou TLS.")
        }
        if !user.isEmpty && !hasPassword { list.append("Mot de passe à enregistrer au Trousseau.") }
        return list
    }
}

/// Type de webhook.
public enum AlertWebhookKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Microsoft Teams : flux Workflows (Power Automate), carte adaptative.
    case teams
    /// Slack : « incoming webhook », message en blocs.
    case slack
    /// Service quelconque : POST JSON documenté (AlertGenericPayload).
    case generic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .teams: return "Microsoft Teams"
        case .slack: return "Slack"
        case .generic: return "Webhook générique (JSON)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .teams: return "Teams"
        case .slack: return "Slack"
        case .generic: return "JSON"
        }
    }

    public var symbol: String {
        switch self {
        case .teams: return "person.3"
        case .slack: return "number"
        case .generic: return "curlybraces"
        }
    }

    public var urlPlaceholder: String {
        switch self {
        case .teams: return "https://prod-00.westus.logic.azure.com/workflows/…"
        case .slack: return "https://hooks.slack.com/services/T…/B…/…"
        case .generic: return "https://exemple.ca/netscope/alertes"
        }
    }

    public var help: String {
        switch self {
        case .teams:
            return "Dans Teams, ouvrez Workflows et choisissez «\u{00A0}Publier dans un canal quand une demande webhook est reçue\u{00A0}», puis copiez l’adresse du flux. Les anciens connecteurs Office 365 (webhook.office.com) sont en fin de vie."
        case .slack:
            return "Dans Slack, créez une app avec «\u{00A0}Incoming Webhooks\u{00A0}», ajoutez-la au canal voulu et copiez l’adresse hooks.slack.com."
        case .generic:
            return "NetScope envoie un POST JSON (schéma 1, voir la documentation du format)\u{00A0}; un en-tête d’authentification facultatif est gardé au Trousseau."
        }
    }

    /// Hôtes attendus pour ce type (avertissement seulement si l'adresse n'y correspond pas).
    public func isExpectedHost(_ host: String) -> Bool {
        let name = host.lowercased()
        switch self {
        case .teams:
            return name.hasSuffix(".logic.azure.com") || name.hasSuffix(".powerplatform.com")
                || name.hasSuffix(".webhook.office.com") || name == "webhook.office.com" || name.hasSuffix(".powerautomate.com")
        case .slack:
            return name == "hooks.slack.com"
        case .generic:
            return true
        }
    }
}

/// Un webhook (l'adresse et l'en-tête d'authentification sont au Trousseau).
public struct AlertWebhook: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: AlertWebhookKind
    public var name: String
    public var isEnabled: Bool
    /// Générique : nom de l'en-tête d'authentification (« Authorization ») ; sa valeur est au Trousseau.
    public var authHeaderName: String

    public init(id: UUID = UUID(), kind: AlertWebhookKind, name: String, isEnabled: Bool = true, authHeaderName: String = "") {
        self.id = id
        self.kind = kind
        self.name = name
        self.isEnabled = isEnabled
        self.authHeaderName = authHeaderName
    }
}

/// Canal d'envoi (pour le journal et les tests).
public enum AlertChannel: Hashable, Sendable, Identifiable {
    case email
    case webhook(UUID)
    /// Note 76 : notification sur téléphone par ntfy.
    case ntfy
    /// Note 76 : notification sur téléphone par Pushover.
    case pushover

    public var id: String {
        switch self {
        case .email: return "courriel"
        case .webhook(let id): return "webhook-\(id.uuidString)"
        case .ntfy: return "ntfy"
        case .pushover: return "pushover"
        }
    }
}

/// Comptes du Trousseau (service com.danymenard.netscope.alertes).
public enum AlertSecretKey {
    public static let service = "com.danymenard.netscope.alertes"
    public static let smtpPassword = "smtp.motdepasse"
    public static func webhookURL(_ id: UUID) -> String { "webhook.\(id.uuidString).adresse" }
    public static func webhookAuth(_ id: UUID) -> String { "webhook.\(id.uuidString).entete" }
    /// Note 76 : jeton d'accès ntfy (facultatif).
    public static let ntfyToken = "ntfy.jeton"
    /// Note 76 : jeton d'application et clé utilisateur Pushover.
    public static let pushoverToken = "pushover.application"
    public static let pushoverUser = "pushover.utilisateur"
}

// MARK: - Règles

/// Heures de silence (de… à…, en minutes depuis minuit ; peut passer minuit).
public struct AlertQuietHours: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var startMinute = 22 * 60
    public var endMinute = 7 * 60
    /// Les alertes critiques passent quand même (comme au croquis : « passent outre »).
    public var criticalBypass = true

    public init() {}

    public init(isEnabled: Bool, startMinute: Int, endMinute: Int, criticalBypass: Bool = true) {
        self.isEnabled = isEnabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.criticalBypass = criticalBypass
    }

    /// Vrai si `date` tombe dans la période de silence.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled, startMinute != endMinute else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// « 22:00 – 07:00 ».
    public var label: String { "\(Self.clock(startMinute)) – \(Self.clock(endMinute))" }

    public static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", (minute / 60) % 24, minute % 60)
    }
}

/// Règles d'envoi : quels événements, gravité minimale, anti-rafale, regroupement, silence.
public struct AlertRules: Codable, Equatable, Sendable {
    public var kinds: Set<AlertEventKind> = AlertRules.defaultKinds
    public var minimumSeverity: AlertSeverity = .info
    /// Au plus une alerte par événement (type + objet) et par intervalle, en minutes.
    public var throttleMinutes = 15
    /// Fenêtre de regroupement, en secondes : les événements de cette fenêtre partent en un résumé.
    public var groupingSeconds = 60
    public var quietHours = AlertQuietHours()
    /// Sondes dont les alertes restent sur le Mac (notification seulement).
    public var excludedProbes: Set<UUID> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AlertRules()
        if let raw = try c.decodeIfPresent([String].self, forKey: .kinds) {
            // Type inconnu (version plus récente) ignoré ; type apparu depuis l'écriture du fichier :
            // il reprend l'état du type générique qui le portait avant (AlertEventKind.migrated).
            let saved = Set(raw.compactMap(AlertEventKind.init(rawValue:)))
            let known = try c.decodeIfPresent([String].self, forKey: .knownKinds).map { Set($0.compactMap(AlertEventKind.init(rawValue:))) }
            kinds = AlertEventKind.migrated(saved, known: known)
        } else {
            kinds = defaults.kinds
        }
        minimumSeverity = try c.decodeIfPresent(AlertSeverity.self, forKey: .minimumSeverity) ?? defaults.minimumSeverity
        throttleMinutes = try c.decodeIfPresent(Int.self, forKey: .throttleMinutes) ?? defaults.throttleMinutes
        groupingSeconds = try c.decodeIfPresent(Int.self, forKey: .groupingSeconds) ?? defaults.groupingSeconds
        quietHours = try c.decodeIfPresent(AlertQuietHours.self, forKey: .quietHours) ?? defaults.quietHours
        excludedProbes = try c.decodeIfPresent(Set<UUID>.self, forKey: .excludedProbes) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case kinds, minimumSeverity, throttleMinutes, groupingSeconds, quietHours, excludedProbes
        /// Types connus de la version qui a écrit le fichier (0.26.0) : un type plus récent prend sa valeur par défaut.
        case knownKinds
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kinds.map(\.rawValue).sorted(), forKey: .kinds)
        try c.encode(AlertEventKind.configurable.map(\.rawValue).sorted(), forKey: .knownKinds)
        try c.encode(minimumSeverity, forKey: .minimumSeverity)
        try c.encode(throttleMinutes, forKey: .throttleMinutes)
        try c.encode(groupingSeconds, forKey: .groupingSeconds)
        try c.encode(quietHours, forKey: .quietHours)
        try c.encode(excludedProbes, forKey: .excludedProbes)
    }

    /// Événements choisis au premier lancement.
    public static let defaultKinds: Set<AlertEventKind> = [.probeDown, .probeWarning, .probeRecovered, .newDevice, .rogueDHCP,
                                                           .serviceIncident, .licenseExpiring, .firmwareOutdated, .syslogSevere, .wanDown]

    public static let throttleChoices = [0, 5, 15, 30, 60, 240]
    public static let groupingChoices = [0, 30, 60, 300]

    /// « 15 min », « 1 h », « Aucun ».
    public static func minutesLabel(_ minutes: Int) -> String {
        if minutes <= 0 { return "Aucun" }
        if minutes < 60 { return "\(minutes)\u{00A0}min" }
        return "\(minutes / 60)\u{00A0}h"
    }

    /// « Immédiat », « 30 s », « 1 min ».
    public static func secondsLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return "Immédiat" }
        if seconds < 60 { return "\(seconds)\u{00A0}s" }
        return "\(seconds / 60)\u{00A0}min"
    }
}

/// Tous les réglages des alertes (UserDefaults, en JSON) : aucun secret.
public struct AlertSettings: Codable, Equatable, Sendable {
    /// Interrupteur général : désactivé par défaut, rien ne part tant qu'il ne l'est pas.
    public var isEnabled = false
    public var smtp = AlertSMTPSettings()
    public var webhooks: [AlertWebhook] = []
    /// Note 76 : notifications sur téléphone (désactivées par défaut).
    public var ntfy = AlertNtfySettings()
    public var pushover = AlertPushoverSettings()
    public var rules = AlertRules()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        smtp = try c.decodeIfPresent(AlertSMTPSettings.self, forKey: .smtp) ?? AlertSMTPSettings()
        webhooks = try c.decodeIfPresent([AlertWebhook].self, forKey: .webhooks) ?? []
        ntfy = try c.decodeIfPresent(AlertNtfySettings.self, forKey: .ntfy) ?? AlertNtfySettings()
        pushover = try c.decodeIfPresent(AlertPushoverSettings.self, forKey: .pushover) ?? AlertPushoverSettings()
        rules = try c.decodeIfPresent(AlertRules.self, forKey: .rules) ?? AlertRules()
    }

    /// Canaux activés (sans vérifier les secrets).
    public var enabledChannels: [AlertChannel] {
        (smtp.isEnabled ? [.email] : []) + webhooks.filter(\.isEnabled).map { .webhook($0.id) }
            + (ntfy.isEnabled ? [.ntfy] : []) + (pushover.isEnabled ? [.pushover] : [])
    }

    /// Filtre propre au canal (gravité, sites) : seuls ntfy et Pushover en ont un.
    public func filter(for channel: AlertChannel) -> AlertChannelFilter? {
        switch channel {
        case .ntfy: return ntfy.filter
        case .pushover: return pushover.filter
        case .email, .webhook: return nil
        }
    }

    /// Lot à envoyer sur ce canal après son filtre propre (nil : rien pour lui).
    public func batch(_ batch: AlertBatch, for channel: AlertChannel) -> AlertBatch? {
        guard let filter = filter(for: channel) else { return batch }
        return filter.apply(batch)
    }

    public func webhook(_ id: UUID) -> AlertWebhook? { webhooks.first { $0.id == id } }

    /// Nom lisible d'un canal (« Courriel », « Teams · Exploitation »).
    public func channelName(_ channel: AlertChannel) -> String {
        switch channel {
        case .email: return "Courriel"
        case .webhook(let id):
            guard let hook = webhook(id) else { return "Webhook supprimé" }
            return hook.name.isEmpty ? hook.kind.shortLabel : "\(hook.kind.shortLabel) · \(hook.name)"
        case .ntfy:
            let topic = ntfy.topic.trimmingCharacters(in: .whitespaces)
            return topic.isEmpty ? "ntfy" : "ntfy · \(topic)"
        case .pushover: return "Pushover"
        }
    }

    /// Canaux qui recevraient les alertes de cette sonde (vide : alertes désactivées, sonde exclue
    /// ou aucun canal) : indication de la Surveillance.
    /// `siteID` : site de la sonde (un canal de téléphone limité à d'autres sites ne la reçoit pas).
    public func channels(forProbe id: UUID, siteID: UUID? = nil) -> [AlertChannel] {
        guard isEnabled, !rules.excludedProbes.contains(id),
              !rules.kinds.isDisjoint(with: [.probeDown, .probeWarning, .probeRecovered, .licenseExpiring, .firmwareOutdated, .syslogSevere, .wanDown]) else { return [] }
        return enabledChannels.filter { channel in
            guard let filter = filter(for: channel), !filter.siteIDs.isEmpty, let siteID else { return true }
            return filter.siteIDs.contains(siteID)
        }
    }
}

// MARK: - Journal des envois

/// Une ligne du journal des envois. Jamais de secret : le détail passe par `AlertRedactor`.
public struct AlertLogEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case sent, failed, simulated

        public var label: String {
            switch self {
            case .sent: return "Envoyée"
            case .failed: return "Échec"
            case .simulated: return "Simulée"
            }
        }
    }

    public var id: UUID
    public var date: Date
    /// « courriel », « teams », « slack », « generic », « ntfy », « pushover ».
    public var channelKind: String
    public var channelName: String
    public var outcome: Outcome
    public var title: String
    public var eventCount: Int
    public var severity: AlertSeverity
    public var isTest: Bool
    /// Détail sans secret (« 250 2.0.0 Ok: queued », « Authentification refusée… »).
    public var detail: String
    public var durationMs: Double?

    public init(id: UUID = UUID(), date: Date, channelKind: String, channelName: String, outcome: Outcome, title: String,
                eventCount: Int, severity: AlertSeverity, isTest: Bool, detail: String, durationMs: Double? = nil) {
        self.id = id
        self.date = date
        self.channelKind = channelKind
        self.channelName = channelName
        self.outcome = outcome
        self.title = title
        self.eventCount = eventCount
        self.severity = severity
        self.isTest = isTest
        self.detail = detail
        self.durationMs = durationMs
    }

    /// Journal gardé : 300 lignes au plus, les plus récentes en premier.
    public static let limit = 300
}

// MARK: - Texte

public enum AlertText {
    /// Une seule ligne : retours à la ligne et caractères de contrôle remplacés par des espaces
    /// (aucune injection d'en-tête possible dans un sujet ou un nom).
    public static func singleLine(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{2028}" || scalar == "\u{2029}" ? " " : Character(scalar)
        }
        return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Nom d'hôte (ou adresse IPv4) acceptable pour un serveur.
    public static func isValidHostname(_ name: String) -> Bool {
        let text = name.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 253, !text.hasPrefix("-"), !text.hasPrefix(".") else { return false }
        return text.range(of: "^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*\\.?$",
                          options: .regularExpression) != nil
    }
}

/// Adresses courriel (forme simple, ASCII : NetScope n'annonce pas SMTPUTF8).
public enum AlertAddress {
    public static func isValid(_ address: String) -> Bool {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard text.count <= 254, text.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        return text.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$",
                          options: .regularExpression) != nil
    }

    /// « a@x.ca, b@y.ca ; c@z.ca » → liste sans vide ni doublon.
    public static func parseList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Domaine d'une adresse (« exemple.ca »).
    public static func domain(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...]
        return domain.isEmpty ? nil : String(domain).lowercased()
    }
}
