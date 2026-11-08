import NetScopeCore
import SwiftUI

// Réglages › Alertes, note 76 (0.28.0) : notifications sur téléphone par ntfy et Pushover.
// Deux cartes à côté du courriel et des webhooks, désactivées par défaut. Les secrets (jeton ntfy,
// jeton d'application et clé utilisateur Pushover) vont au Trousseau, jamais dans les préférences ;
// rien ne part sans canal activé par l'utilisateur, sauf un essai demandé et confirmé.

// MARK: - ntfy

struct RegAlertNtfyCard: View {
    @ObservedObject private var alerts = AlertDispatcher.shared
    @State private var token = ""
    @State private var tagsText = ""
    @State private var message: (text: String, tone: Tone)?
    @State private var loaded = false

    private var ntfy: Binding<AlertNtfySettings> { $alerts.settings.ntfy }
    private var settings: AlertNtfySettings { alerts.settings.ntfy }
    private var problems: [String] { settings.problems() }

    private var serverInvalid: Bool {
        !settings.server.isEmpty && (try? AlertNtfyRequest.endpoint(server: settings.server)) == nil
    }

    private var hostLabel: String {
        URL(string: settings.server.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "—"
    }

    var body: some View {
        RegAlertBox(symbol: "bell.badge", title: "ntfy") {
            Chip(text: hostLabel, tone: .neutral, mono: true)
            Spacer(minLength: 8)
            RegSwitch(isOn: ntfy.isEnabled)
                .help(settings.isEnabled ? "Ne plus envoyer les alertes par ntfy" : "Envoyer les alertes sur le téléphone par ntfy")
        } content: {
            Text("Application ntfy (iOS, Android ou navigateur) abonnée à un sujet, sur ntfy.sh ou sur votre propre serveur.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            RegField(label: "Serveur") {
                RegTextField(placeholder: AlertNtfySettings.defaultServer, text: ntfy.server, mono: true, invalid: serverInvalid)
            }
            RegField(label: "Sujet") {
                HStack(spacing: 6) {
                    RegTextField(placeholder: "netscope-siege-…", text: ntfy.topic, mono: true,
                                 invalid: !settings.topic.isEmpty && !AlertNtfySettings.isValidTopic(settings.topic.trimmingCharacters(in: .whitespaces)))
                    Button {
                        alerts.settings.ntfy.topic = AlertNtfySettings.randomTopic()
                    } label: { Image(systemName: "dice") }
                        .buttonStyle(.secondary)
                        .help("Générer un sujet difficile à deviner")
                }
            }
            RegField(label: "Jeton d’accès (facultatif)") {
                RegAlertSecretField(placeholder: "tk_… (serveur protégé)", isSaved: alerts.hasNtfyToken, value: $token,
                                    account: AlertSecretKey.ntfyToken, savedText: "Jeton enregistré au Trousseau.",
                                    erasedText: "Jeton effacé du Trousseau.", message: $message)
            }
            RegField(label: "Étiquettes") {
                RegTextField(placeholder: "siege, reseau", text: $tagsText, mono: true,
                             invalid: AlertNtfySettings.parseTags(tagsText).contains { !AlertNtfySettings.isValidTag($0) })
                    .onChange(of: tagsText) { _, value in alerts.settings.ntfy.tags = AlertNtfySettings.parseTags(value) }
            }
            Toggle(isOn: ntfy.severityEmoji) {
                Text("Émoji de gravité dans la notification (gyrophare, avertissement, information)")
                    .font(Theme.small).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            RegAlertPriorityGrid(priorities: ntfy.priorities, range: AlertNtfySettings.priorityRange,
                                 label: AlertNtfySettings.priorityLabel)
            RegAlertChannelFilterView(filter: ntfy.filter)
            if let message {
                RegNotice(message.text, tone: message.tone)
            }
            if settings.isPublicServer, !alerts.hasNtfyToken {
                RegNotice("Sur ntfy.sh, quiconque connaît le sujet lit les messages\u{00A0}: gardez un sujet difficile à deviner (bouton dé) ou un serveur protégé par jeton.",
                          tone: .neutral)
            }
            if settings.isEnabled || !settings.topic.isEmpty, !problems.isEmpty {
                RegNotice(problems.joined(separator: " "), tone: settings.isEnabled ? .warning : .neutral)
            }
            RegAlertPhoneFooter(channel: .ntfy, vault: alerts.hasNtfyToken ? "Jeton au Trousseau macOS" : "Jeton facultatif, gardé au Trousseau macOS",
                                vaultSaved: alerts.hasNtfyToken,
                                destination: "au sujet «\u{00A0}\(settings.topic)\u{00A0}» de \(hostLabel)")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            tagsText = settings.tags.joined(separator: ", ")
        }
    }
}

// MARK: - Pushover

struct RegAlertPushoverCard: View {
    @ObservedObject private var alerts = AlertDispatcher.shared
    @State private var token = ""
    @State private var userKey = ""
    @State private var message: (text: String, tone: Tone)?

    private var pushover: Binding<AlertPushoverSettings> { $alerts.settings.pushover }
    private var settings: AlertPushoverSettings { alerts.settings.pushover }
    private var problems: [String] { settings.problems(hasToken: alerts.hasPushoverToken, hasUserKey: alerts.hasPushoverUser) }

    var body: some View {
        RegAlertBox(symbol: "iphone.radiowaves.left.and.right", title: "Pushover") {
            Chip(text: "api.pushover.net", tone: .neutral, mono: true)
            Spacer(minLength: 8)
            RegSwitch(isOn: pushover.isEnabled)
                .help(settings.isEnabled ? "Ne plus envoyer les alertes par Pushover" : "Envoyer les alertes sur le téléphone par Pushover")
        } content: {
            Text("Créez une application sur pushover.net pour obtenir son jeton\u{00A0}; la clé utilisateur (ou de groupe) est sur la page d’accueil du compte.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            RegField(label: "Jeton d’application") {
                RegAlertSecretField(placeholder: "a1b2c3… (30 caractères)", isSaved: alerts.hasPushoverToken, value: $token,
                                    account: AlertSecretKey.pushoverToken, savedText: "Jeton d’application enregistré au Trousseau.",
                                    erasedText: "Jeton d’application effacé du Trousseau.", message: $message,
                                    validate: AlertPushoverSettings.isValidKey)
            }
            RegField(label: "Clé utilisateur") {
                RegAlertSecretField(placeholder: "u1v2w3… (30 caractères)", isSaved: alerts.hasPushoverUser, value: $userKey,
                                    account: AlertSecretKey.pushoverUser, savedText: "Clé utilisateur enregistrée au Trousseau.",
                                    erasedText: "Clé utilisateur effacée du Trousseau.", message: $message,
                                    validate: AlertPushoverSettings.isValidKey)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)], alignment: .leading, spacing: 10) {
                RegField(label: "Appareil (facultatif)") {
                    RegTextField(placeholder: "Tous les appareils", text: pushover.device, mono: true,
                                 invalid: !settings.normalizedDevice.isEmpty && !AlertPushoverSettings.isValidDevice(settings.normalizedDevice))
                }
                RegField(label: "Son") {
                    Picker("", selection: pushover.sound) {
                        ForEach(AlertPushoverSettings.sounds, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                }
            }
            RegAlertPriorityGrid(priorities: pushover.priorities, range: AlertPushoverSettings.priorityRange,
                                 label: AlertPushoverSettings.priorityLabel)
            if AlertSeverity.allCases.contains(where: { settings.priorities[$0] == 2 }) {
                Text("Urgence\u{00A0}: le téléphone sonne toutes les \(AlertPushoverSettings.emergencyRetry)\u{00A0}s jusqu’à l’accusé de réception, pendant \(AlertPushoverSettings.emergencyExpire / 3600)\u{00A0}h au plus.")
                    .font(Theme.small).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RegAlertChannelFilterView(filter: pushover.filter)
            if let message {
                RegNotice(message.text, tone: message.tone)
            }
            if settings.isEnabled || alerts.hasPushoverToken || alerts.hasPushoverUser, !problems.isEmpty {
                RegNotice(problems.joined(separator: " "), tone: settings.isEnabled ? .warning : .neutral)
            }
            RegAlertPhoneFooter(channel: .pushover,
                                vault: alerts.hasPushoverToken && alerts.hasPushoverUser ? "Jeton et clé au Trousseau macOS" : "Le jeton et la clé iront au Trousseau macOS",
                                vaultSaved: alerts.hasPushoverToken && alerts.hasPushoverUser,
                                destination: "par Pushover" + (settings.normalizedDevice.isEmpty ? " sur tous vos appareils" : " sur «\u{00A0}\(settings.normalizedDevice)\u{00A0}»"))
        }
    }
}

// MARK: - Éléments communs

/// Champ de secret gardé au Trousseau : jamais réaffiché ; « Enregistrer » quand une valeur est
/// saisie, corbeille pour l'effacer sinon.
struct RegAlertSecretField: View {
    let placeholder: String
    let isSaved: Bool
    @Binding var value: String
    let account: String
    let savedText: String
    let erasedText: String
    @Binding var message: (text: String, tone: Tone)?
    var validate: ((String) -> Bool)? = nil
    @ObservedObject private var alerts = AlertDispatcher.shared

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var invalid: Bool { !trimmed.isEmpty && !(validate?(trimmed) ?? true) }

    var body: some View {
        HStack(spacing: 6) {
            RegTextField(placeholder: isSaved ? "•••••••• (au Trousseau)" : placeholder, text: $value, mono: true, secure: true, invalid: invalid)
                .onSubmit(save)
            if !value.isEmpty {
                Button("Enregistrer", action: save).buttonStyle(.secondary).fixedSize()
                    .regDisabled(invalid)
            } else if isSaved {
                Button {
                    message = alerts.setPhoneSecret("", account: account).map { ("Trousseau\u{00A0}: \($0)", .critical) } ?? (erasedText, .neutral)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.secondary)
                    .help("Effacer du Trousseau")
            }
        }
    }

    private func save() {
        guard !trimmed.isEmpty, !invalid else { return }
        if let error = alerts.setPhoneSecret(trimmed, account: account) {
            message = ("Trousseau\u{00A0}: \(error)", .critical)
        } else {
            message = (savedText, .success)
            value = ""
        }
    }
}

/// Priorité envoyée pour chaque gravité (menus natifs).
struct RegAlertPriorityGrid: View {
    @Binding var priorities: AlertPriorityMap
    let range: ClosedRange<Int>
    let label: (Int) -> String

    var body: some View {
        RegField(label: "Priorité selon la gravité") {
            FlowLayout(spacing: 12, lineSpacing: 6) {
                ForEach(AlertSeverity.allCases.reversed()) { severity in
                    HStack(spacing: 6) {
                        RegSeverityTag(severity: severity)
                        Picker("", selection: Binding(get: { priorities[severity] }, set: { priorities[severity] = $0 })) {
                            ForEach(Array(range), id: \.self) { value in
                                Text("\(label(value)) (\(value))").tag(value)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                        .help("Priorité des messages «\u{00A0}\(severity.label)\u{00A0}»")
                    }
                }
            }
        }
    }
}

/// Filtre propre au canal : gravité minimale et sites.
struct RegAlertChannelFilterView: View {
    @Binding var filter: AlertChannelFilter
    @ObservedObject private var sites = SiteModel.shared

    private var chosenNames: [String] {
        sites.sortedSites.filter { filter.siteIDs.contains($0.id) }.map(\.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ce canal reçoit").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    severityControl
                    siteMenu
                }
                VStack(alignment: .leading, spacing: 6) {
                    severityControl
                    siteMenu
                }
            }
            Text("Après les règles d’envoi communes (types, gravité, heures de silence, anti-rafale). Les événements sans site (services en ligne, test DHCP, scan) passent toujours\u{00A0}; un rétablissement suit sa panne.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var severityControl: some View {
        RegSegmented(selection: $filter.minimumSeverity,
                     options: AlertSeverity.allCases.map { .init(value: $0, label: AlertChannelFilter.severityLabel($0)) })
    }

    private var siteMenu: some View {
        Menu {
            Button {
                filter.siteIDs = []
            } label: {
                if filter.siteIDs.isEmpty { Label("Tous les sites", systemImage: "checkmark") } else { Text("Tous les sites") }
            }
            if !sites.sortedSites.isEmpty { Divider() }
            ForEach(sites.sortedSites) { site in
                Toggle(site.displayName, isOn: Binding(get: { filter.siteIDs.contains(site.id) }, set: { on in
                    if on { filter.siteIDs.insert(site.id) } else { filter.siteIDs.remove(site.id) }
                }))
            }
        } label: {
            Label(siteLabel, systemImage: "building.2")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(filter.siteIDs.isEmpty ? "Sondes de tous les sites" : "Sondes de ces sites seulement\u{00A0}: \(chosenNames.joined(separator: ", "))")
    }

    private var siteLabel: String {
        if filter.siteIDs.isEmpty { return "Tous les sites" }
        let names = chosenNames
        if names.isEmpty { return "Sites supprimés" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names[0]) + \(names.count - 1)"
    }
}

/// Pied d'une carte de téléphone : Trousseau, bouton d'essai et résultat du dernier essai.
struct RegAlertPhoneFooter: View {
    let channel: AlertChannel
    let vault: String
    let vaultSaved: Bool
    let destination: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                vaultNote
                ActionRow { testButton }
            }
            RegAlertTestResult(channel: channel)
        }
    }

    private var vaultNote: some View {
        Label(vault, systemImage: "lock")
            .font(Theme.small)
            .foregroundStyle(vaultSaved ? Theme.success : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var testButton: some View {
        RegAlertTestButton(channel: channel, destination: destination)
    }
}
