import NetScopeCore
import SwiftUI

// Réglages › Alertes : cartes des canaux (courriel SMTP, webhooks) et éditeur de webhook.

// MARK: - Courriel

/// Carte « Courriel (SMTP) » : serveur, port, sécurité, compte, mot de passe (Trousseau),
/// expéditeur, destinataires, essai.
struct RegAlertMailCard: View {
    @ObservedObject private var alerts = AlertDispatcher.shared
    @State private var portText = ""
    @State private var recipientsText = ""
    @State private var password = ""
    @State private var passwordMessage: (text: String, tone: Tone)?
    @State private var loaded = false

    private var smtp: Binding<AlertSMTPSettings> { $alerts.settings.smtp }

    private var problems: [String] { alerts.settings.smtp.problems(hasPassword: alerts.hasPassword) }

    var body: some View {
        RegAlertBox(symbol: "envelope", title: "Courriel (SMTP)") {
            Chip(text: "\(alerts.settings.smtp.security.label) · \(alerts.settings.smtp.port)", tone: .neutral, mono: true)
            Spacer(minLength: 8)
            RegSwitch(isOn: smtp.isEnabled)
                .help(alerts.settings.smtp.isEnabled ? "Ne plus envoyer les alertes par courriel" : "Envoyer les alertes par courriel")
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)], alignment: .leading, spacing: 10) {
                RegField(label: "Serveur SMTP") {
                    RegTextField(placeholder: "smtp.exemple.ca", text: smtp.host, mono: true,
                                 invalid: !alerts.settings.smtp.host.isEmpty && !AlertText.isValidHostname(alerts.settings.smtp.host))
                }
                RegField(label: "Port") {
                    RegTextField(placeholder: "587", text: $portText, mono: true, invalid: UInt16(portText) == nil && !portText.isEmpty)
                        .onChange(of: portText) { _, value in
                            if let port = UInt16(value.trimmingCharacters(in: .whitespaces)), port > 0 { alerts.settings.smtp.port = port }
                        }
                }
                RegField(label: "Utilisateur") {
                    RegTextField(placeholder: "alertes@exemple.ca (vide\u{00A0}: relais sans compte)", text: smtp.username, mono: true)
                }
                RegField(label: "Mot de passe") {
                    HStack(spacing: 6) {
                        RegTextField(placeholder: alerts.hasPassword ? "•••••••• (au Trousseau)" : "Non renseigné", text: $password, secure: true)
                            .onSubmit(savePassword)
                        if !password.isEmpty {
                            Button("Enregistrer", action: savePassword).buttonStyle(.secondary).fixedSize()
                        } else if alerts.hasPassword {
                            Button {
                                passwordMessage = alerts.setPassword("").map { ($0, .critical) } ?? ("Mot de passe effacé du Trousseau.", .neutral)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.secondary)
                                .help("Effacer le mot de passe du Trousseau")
                        }
                    }
                }
                RegField(label: "Expéditeur") {
                    RegTextField(placeholder: "alertes@exemple.ca", text: smtp.from, mono: true,
                                 invalid: !alerts.settings.smtp.from.isEmpty && !AlertAddress.isValid(alerts.settings.smtp.from))
                }
                RegField(label: "Nom affiché") {
                    RegTextField(placeholder: "NetScope", text: smtp.fromName)
                }
            }
            RegField(label: "Sécurité") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        securityPicker
                        securityNote
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        securityPicker
                        securityNote
                    }
                }
            }
            RegField(label: "Destinataires") {
                RegTextField(placeholder: "dany@exemple.ca, soutien@exemple.ca", text: $recipientsText, mono: true,
                             invalid: AlertAddress.parseList(recipientsText).contains { !AlertAddress.isValid($0) })
                    .onChange(of: recipientsText) { _, value in alerts.settings.smtp.recipients = AlertAddress.parseList(value) }
            }
            if let passwordMessage {
                RegNotice(passwordMessage.text, tone: passwordMessage.tone)
            }
            if alerts.settings.smtp.isEnabled || !alerts.settings.smtp.host.isEmpty, !problems.isEmpty {
                RegNotice(problems.joined(separator: " "), tone: alerts.settings.smtp.isEnabled ? .warning : .neutral)
            }
            VStack(alignment: .leading, spacing: 8) {
                vaultNote
                ActionRow { testButton }
            }
            RegAlertTestResult(channel: .email)
        }
        .onAppear(perform: load)
    }

    private var securityPicker: some View {
        RegSegmented(selection: Binding(get: { alerts.settings.smtp.security }, set: { setSecurity($0) }),
                     options: AlertSMTPSecurity.allCases.map { .init(value: $0, label: $0.label) })
    }

    private var securityNote: some View {
        Text(alerts.settings.smtp.security.explanation)
            .font(Theme.small).foregroundStyle(alerts.settings.smtp.security == .none ? Theme.warning : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var vaultNote: some View {
        Label(alerts.hasPassword ? "Mot de passe au Trousseau macOS" : "Le mot de passe ira au Trousseau macOS, jamais dans les préférences",
              systemImage: "lock")
            .font(Theme.small)
            .foregroundStyle(alerts.hasPassword ? Theme.success : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var testButton: some View {
        let smtp = alerts.settings.smtp
        let to = smtp.recipients.joined(separator: ", ")
        return RegAlertTestButton(channel: .email, destination: "à \(to.isEmpty ? "—" : to) par \(smtp.host) (port \(smtp.port))")
    }

    /// Port suivi du mode : 587 ↔ 465 ↔ 25 si l'utilisateur n'en avait pas choisi un autre.
    private func setSecurity(_ security: AlertSMTPSecurity) {
        let current = alerts.settings.smtp
        if AlertSMTPSecurity.allCases.map(\.defaultPort).contains(current.port) {
            alerts.settings.smtp.port = security.defaultPort
            portText = String(security.defaultPort)
        }
        alerts.settings.smtp.security = security
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        if let error = alerts.setPassword(password) {
            passwordMessage = ("Trousseau\u{00A0}: \(error)", .critical)
        } else {
            passwordMessage = ("Mot de passe enregistré au Trousseau.", .success)
            password = ""
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        portText = String(alerts.settings.smtp.port)
        recipientsText = alerts.settings.smtp.recipients.joined(separator: ", ")
    }
}

// MARK: - Webhooks

/// Carte « Webhooks » : liste (Teams, Slack, générique), ajout, modification, essai.
struct RegAlertWebhooksCard: View {
    @ObservedObject private var alerts = AlertDispatcher.shared
    @State private var editing: AlertWebhook?
    @State private var isNew = false
    @State private var removing: AlertWebhook?

    var body: some View {
        RegAlertBox(symbol: "link", title: "Webhooks") {
            Chip(text: "\(alerts.settings.webhooks.count)", tone: .neutral, mono: true)
            Spacer(minLength: 8)
            Menu {
                ForEach(AlertWebhookKind.allCases) { kind in
                    Button {
                        isNew = true
                        editing = AlertWebhook(kind: kind, name: "", authHeaderName: kind == .generic ? "Authorization" : "")
                    } label: { Label(kind.label, systemImage: kind.symbol) }
                }
            } label: {
                Label("Ajouter un webhook", systemImage: "plus")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
        } content: {
            if alerts.settings.webhooks.isEmpty {
                Text("Aucun webhook. Ajoutez un canal Microsoft Teams (Workflows), Slack (incoming webhook) ou un service qui reçoit du JSON.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(alerts.settings.webhooks) { hook in
                        row(hook)
                    }
                }
            }
            Text("Les adresses des webhooks donnent le droit de publier\u{00A0}: elles sont gardées au Trousseau macOS, comme l’en-tête d’authentification, et n’apparaissent jamais en entier.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { hook in
            RegAlertWebhookEditor(hook: hook, isNew: isNew) { editing = nil }
        }
        .confirmationDialog("Supprimer ce webhook\u{00A0}?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { hook in
            Button("Supprimer «\u{00A0}\(hook.name.isEmpty ? hook.kind.label : hook.name)\u{00A0}»", role: .destructive) { alerts.removeWebhook(hook.id) }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("L’adresse et l’en-tête d’authentification seront effacés du Trousseau.")
        }
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { alerts.settings.webhook(id)?.isEnabled ?? false },
                set: { value in
                    if let index = alerts.settings.webhooks.firstIndex(where: { $0.id == id }) { alerts.settings.webhooks[index].isEnabled = value }
                })
    }

    private func row(_ hook: AlertWebhook) -> some View {
        let masked = alerts.maskedURLs[hook.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: hook.kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hook.isEnabled ? Theme.accentStrong : Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(hook.isEnabled ? Theme.accentSoft : Theme.neutralSoft))
                VStack(alignment: .leading, spacing: 2) {
                    // Fenêtre étroite : les puces passent sous le nom au lieu de le couper.
                    FlowLayout(spacing: 6, lineSpacing: 3) {
                        Text(hook.name.isEmpty ? hook.kind.label : hook.name)
                            .font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                        Chip(text: hook.kind.shortLabel, tone: hook.kind == .teams ? .accent : .neutral)
                        if hook.kind == .generic, !hook.authHeaderName.isEmpty, alerts.hasAuthValue.contains(hook.id) {
                            Chip(text: hook.authHeaderName, tone: .success, mono: true, systemImage: "lock.fill")
                                .help("En-tête d’authentification au Trousseau")
                        }
                    }
                    Text(masked ?? "Adresse à saisir")
                        .font(Theme.mono(11))
                        .foregroundStyle(masked == nil ? Theme.warning : Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RegAlertTestButton(channel: .webhook(hook.id),
                                   destination: "dans \(hook.kind.label) «\u{00A0}\(hook.name.isEmpty ? hook.kind.shortLabel : hook.name)\u{00A0}»" + (masked.map { " (\($0))" } ?? ""),
                                   compact: true)
                Menu {
                    Button("Modifier…") { isNew = false; editing = hook }
                    Divider()
                    Button("Supprimer…", role: .destructive) { removing = hook }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .controlSize(.small)
                .fixedSize()
                .help("Modifier ou supprimer")
                RegSwitch(isOn: binding(hook.id))
            }
            RegAlertTestResult(channel: .webhook(hook.id))
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }
}

// MARK: - Éditeur de webhook

/// Feuille d'ajout ou de modification d'un webhook. L'adresse enregistrée n'est jamais réaffichée :
/// un champ vide la garde telle quelle.
struct RegAlertWebhookEditor: View {
    @State var hook: AlertWebhook
    let isNew: Bool
    let dismiss: () -> Void
    @ObservedObject private var alerts = AlertDispatcher.shared
    @State private var address = ""
    @State private var authValue = ""
    @State private var error: String?

    init(hook: AlertWebhook, isNew: Bool, dismiss: @escaping () -> Void) {
        _hook = State(initialValue: hook)
        self.isNew = isNew
        self.dismiss = dismiss
    }

    private var hasSavedURL: Bool { alerts.maskedURLs[hook.id] != nil }

    private var addressProblem: String? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return hasSavedURL ? nil : "Adresse à saisir." }
        do {
            let url = try AlertWebhookAddress.validate(text)
            if let host = url.host, !hook.kind.isExpectedHost(host) {
                return "Attention\u{00A0}: «\u{00A0}\(host)\u{00A0}» n’est pas une adresse \(hook.kind.label) habituelle."
            }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription
        }
    }

    private var canSave: Bool {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressOK = text.isEmpty ? hasSavedURL : (try? AlertWebhookAddress.validate(text)) != nil
        let headerOK = hook.kind != .generic || hook.authHeaderName.isEmpty || AlertWebhookAddress.isValidHeaderName(hook.authHeaderName)
        return addressOK && headerOK
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: hook.kind.symbol).foregroundStyle(Theme.accentStrong)
                Text(isNew ? "Nouveau webhook \(hook.kind.label)" : "Modifier le webhook").font(Theme.panelTitle)
            }
            Text(hook.kind.help).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            RegField(label: "Nom") {
                RegTextField(placeholder: hook.kind == .slack ? "#reseau-alertes" : "Exploitation TI", text: $hook.name)
            }
            RegField(label: "Adresse du webhook") {
                RegTextField(placeholder: hasSavedURL ? "Enregistrée au Trousseau (laisser vide pour la garder)" : hook.kind.urlPlaceholder,
                             text: $address, mono: true)
            }
            if let addressProblem, !address.isEmpty || !hasSavedURL {
                RegNotice(addressProblem, tone: canSave ? .warning : (address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .neutral : .critical))
            }
            if hook.kind == .generic {
                HStack(alignment: .top, spacing: 10) {
                    RegField(label: "En-tête d’authentification (facultatif)") {
                        RegTextField(placeholder: "Authorization", text: $hook.authHeaderName, mono: true,
                                     invalid: !hook.authHeaderName.isEmpty && !AlertWebhookAddress.isValidHeaderName(hook.authHeaderName))
                    }
                    RegField(label: "Valeur") {
                        RegTextField(placeholder: alerts.hasAuthValue.contains(hook.id) ? "•••••••• (au Trousseau)" : "Bearer …",
                                     text: $authValue, mono: true, secure: true)
                    }
                }
                Text("Format envoyé\u{00A0}: POST JSON (schéma 1) avec source, title, severity, count, suppressed et la liste events (kind, severity, title, message, subject, occurredAt, details).")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                RegNotice(error, tone: .critical)
            }
            HStack {
                Label("Adresse et en-tête gardés au Trousseau macOS", systemImage: "lock")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Enregistrer", action: save).buttonStyle(.primary).keyboardShortcut(.defaultAction)
                    .regDisabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved = hook
        saved.name = AlertText.singleLine(saved.name)
        saved.authHeaderName = saved.authHeaderName.trimmingCharacters(in: .whitespaces)
        let auth: String? = hook.kind == .generic ? (saved.authHeaderName.isEmpty ? "" : (authValue.isEmpty ? nil : authValue)) : nil
        if let failure = alerts.saveWebhook(saved, url: text.isEmpty ? nil : text, auth: auth) {
            error = "Trousseau\u{00A0}: \(failure)"
            return
        }
        dismiss()
    }
}
