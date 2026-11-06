import AppKit
import NetScopeCore
import SwiftUI

// Note 77 : Réglages › Sites et plages › Contrôleur : contrôleurs UniFi Network, TP-Link Omada et
// Cisco Meraki du site (lecture seule). Encadré de la liste, puis feuille d'ajout ou de
// modification avec « Tester ». Le secret va au Trousseau, jamais dans sites.json.

/// Contrôleur à ajouter ou modifier (feuille).
struct RegSiteControllerDraft: Identifiable {
    var controller: SiteController
    var siteID: UUID
    var isNew: Bool
    /// Résultat d'essai préparé (captures seulement).
    var outcome: SiteControllerStore.TestOutcome?

    var id: UUID { controller.id }

    /// Captures : NETSCOPE_CONTROLEUR_FEUILLE=unifi (ou omada, meraki, nouveau) dessine la feuille
    /// dans la page du site, avec le résultat d'un « Tester » de démonstration.
    @MainActor
    static func snapshotDraft(for site: Site) -> RegSiteControllerDraft? {
        guard RegEnvironment.isSnapshot, let raw = ProcessInfo.processInfo.environment["NETSCOPE_CONTROLEUR_FEUILLE"] else { return nil }
        if raw == "nouveau" {
            return RegSiteControllerDraft(controller: SiteController(kind: .unifi, host: "192.168.1.1"), siteID: site.id, isNew: true,
                                          outcome: ControllerDemo.testOutcome(for: SiteController(kind: .unifi, host: "192.168.1.1")))
        }
        guard let kind = ControllerKind(rawValue: raw), let c = site.controllers.first(where: { $0.kind == kind }) else { return nil }
        return RegSiteControllerDraft(controller: c, siteID: site.id, isNew: false, outcome: ControllerDemo.testOutcome(for: c))
    }
}

// MARK: - Encadré du site

struct RegSiteControllersBox: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SiteControllerStore.shared
    let site: Site
    @State private var editing: RegSiteControllerDraft?
    @State private var removing: SiteController?

    var body: some View {
        RegSiteBox(title: "Contrôleur UniFi, Omada ou Meraki") {
            if let draft = RegSiteControllerDraft.snapshotDraft(for: site) {
                // Captures : la feuille d'édition dessinée dans la page (une feuille n'est pas capturée).
                RegSiteControllerEditor(draft: draft, inline: true, dismiss: {})
                    .frame(maxWidth: 680, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                    .padding(.bottom, 6)
            }
            Text("Switchs, bornes et clients lus par l’API du contrôleur du site, en lecture seule (aucune modification envoyée)\u{00A0}: façade et ports dans Switchs et ports, emplacement switch/port des appareils filaires dans le Scanner, bornes et clients dans Wi-Fi.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            if site.controllers.isEmpty {
                Text("Aucun contrôleur pour ce site.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(site.controllers.enumerated()), id: \.element.id) { index, c in
                        if index > 0 { Divider() }
                        row(c)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            }
            HStack {
                Menu {
                    ForEach(ControllerKind.allCases) { kind in
                        Button(kind.label) {
                            editing = RegSiteControllerDraft(controller: SiteController(kind: kind, siteRef: kind == .meraki ? site.displayName : ""),
                                                             siteID: site.id, isNew: true)
                        }
                    }
                } label: {
                    Label("Ajouter un contrôleur", systemImage: "plus")
                }
                .menuStyle(.button)
                .fixedSize()
                Spacer()
            }
        }
        .task { await store.loadSecrets() }
        .sheet(item: $editing) { draft in
            RegSiteControllerEditor(draft: draft) { editing = nil }
        }
        .confirmationDialog("Retirer ce contrôleur\u{00A0}?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { c in
            Button("Retirer «\u{00A0}\(c.displayName)\u{00A0}» et son secret", role: .destructive) {
                store.remove(c.id, siteID: site.id, state: state)
            }
        } message: { _ in
            Text("Son secret est effacé du Trousseau. Ses switchs et ses bornes ne sont plus lus.")
        }
    }

    private func row(_ c: SiteController) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ControllerKindIcon(kind: c.kind, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.displayName).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                    ControllerStatusChip(store: store, controller: c)
                    if !store.hasSecret(c.id) {
                        Chip(text: "\(c.authMode.secretLabel) manquant\(c.authMode.secretLabel == "Clé d’API" ? "e" : "")", tone: .warning, systemImage: "lock.open")
                    }
                }
                Text([c.kind.label, c.kind == .meraki ? nil : c.addressLabel, c.scopeLabel, c.authMode.label].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                if let status = c.lastStatus, status.kind != .untested {
                    Text(statusLine(status)).font(Theme.caption)
                        .foregroundStyle(status.kind == .ok ? Theme.textTertiary : Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Modifier…") { editing = RegSiteControllerDraft(controller: c, siteID: site.id, isNew: false) }
                .buttonStyle(.secondary)
            Button { removing = c } label: { Image(systemName: "trash") }
                .buttonStyle(.secondary)
                .help("Retirer ce contrôleur (et son secret du Trousseau)")
        }
        .padding(10)
    }

    private func statusLine(_ status: ControllerStatus) -> String {
        let when = status.date.map { SwitchText.dateTime($0) } ?? ""
        if status.kind == .ok {
            var parts = ["Dernière lecture réussie\u{00A0}: \(when)"]
            if let name = status.name { parts.append(name) }
            if let version = status.version { parts.append("version \(version)") }
            if let s = status.switchCount { parts.append("\(s) switch\(s > 1 ? "s" : "")") }
            if let a = status.apCount { parts.append("\(a) borne\(a > 1 ? "s" : "")") }
            return parts.joined(separator: " · ")
        }
        return "Dernier essai (\(when))\u{00A0}: \(status.message)"
    }
}

// MARK: - Feuille d'édition

/// Feuille d'ajout ou de modification d'un contrôleur : marque, adresse, type, authentification,
/// site ou réseau, secret (Trousseau), empreinte du certificat et « Tester ». Rien n'est enregistré
/// avant « Ajouter » ou « Enregistrer ».
struct RegSiteControllerEditor: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SiteControllerStore.shared
    let dismiss: () -> Void
    var inline = false
    private let isNew: Bool
    private let original: SiteController
    private let siteID: UUID

    @State private var kind: ControllerKind
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var unifiOS: Bool
    @State private var authMode: ControllerAuthMode
    @State private var account: String
    @State private var siteRef: String
    @State private var orgRef: String
    @State private var isEnabled: Bool
    @State private var pinned: String?
    @State private var secret = ""
    @State private var outcome: SiteControllerStore.TestOutcome?
    @State private var testing = false
    @State private var error: String?
    @State private var copied = false
    @State private var acceptedNotice = false

    init(draft: RegSiteControllerDraft, inline: Bool = false, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        self.inline = inline
        isNew = draft.isNew
        original = draft.controller
        siteID = draft.siteID
        let c = draft.controller
        _kind = State(initialValue: c.kind)
        _name = State(initialValue: c.name)
        _host = State(initialValue: c.host)
        _port = State(initialValue: String(c.port))
        _unifiOS = State(initialValue: c.unifiOS)
        _authMode = State(initialValue: c.authMode)
        _account = State(initialValue: c.account)
        _siteRef = State(initialValue: c.siteRef)
        _orgRef = State(initialValue: c.orgRef)
        _isEnabled = State(initialValue: c.isEnabled)
        _pinned = State(initialValue: c.pinnedFingerprint)
        _outcome = State(initialValue: draft.outcome)
    }

    // MARK: Brouillon

    private var portValue: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65_535).contains($0) ? $0 : nil } }

    private var draft: SiteController {
        var c = original
        c.kind = kind
        c.name = name
        c.host = kind == .meraki ? "" : host
        c.port = portValue ?? kind.defaultPort
        c.unifiOS = unifiOS
        c.authMode = kind.authModes.contains(authMode) ? authMode : kind.authModes[0]
        c.account = c.authMode.accountLabel == nil ? "" : account.trimmingCharacters(in: .whitespaces)
        c.siteRef = siteRef.trimmingCharacters(in: .whitespaces)
        c.orgRef = orgRef.trimmingCharacters(in: .whitespaces)
        c.isEnabled = isEnabled
        c.pinnedFingerprint = kind == .meraki ? nil : pinned
        return c
    }

    private var hostInvalid: Bool { kind != .meraki && !host.isEmpty && !draft.hasValidAddress }
    private var hasStoredSecret: Bool { store.hasSecret(original.id) }
    private var accountMissing: Bool { draft.authMode.accountLabel != nil && draft.account.isEmpty }
    private var canSave: Bool {
        (kind == .meraki || (!host.isEmpty && !hostInvalid && portValue != nil)) && !accountMissing
            && (secret.isEmpty || SiteControllerStore.secretProblem(secret) == nil)
    }
    private var canTest: Bool { canSave && !testing && (!secret.isEmpty || hasStoredSecret) }

    // MARK: Vue

    var body: some View {
        if inline {
            VStack(alignment: .leading, spacing: 0) {
                form
                Divider()
                footer
            }
            .background(Theme.panel)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView { form }
                Divider()
                footer
            }
            .frame(minWidth: 580, idealWidth: 660, maxWidth: 760, minHeight: 460, idealHeight: 680)
            .background(Theme.panel)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ControllerKindIcon(kind: kind, size: 26)
                Text(isNew ? "Nouveau contrôleur \(kind.label)" : "Modifier «\u{00A0}\(original.displayName)\u{00A0}»").font(Theme.panelTitle)
                Spacer()
                Toggle("Activé", isOn: $isEnabled).toggleStyle(.switch).controlSize(.small)
            }
            if isNew {
                Picker("Marque", selection: $kind) {
                    ForEach(ControllerKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: kind) { _, value in
                    if !value.authModes.contains(authMode) { authMode = value.authModes[0] }
                    port = String(value.defaultPort)
                    outcome = nil
                }
            }
            fields
            secretBox
            if kind != .meraki { certificateBox }
            testBox
            if let error { RegNotice(error, tone: .critical) }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !isNew {
                Text("Compte du Trousseau\u{00A0}: \(original.keychainAccount.prefix(8))…").font(Theme.small).foregroundStyle(Theme.textTertiary)
                    .help("Service com.danymenard.netscope.controleurs, compte \(original.keychainAccount)")
            }
            Spacer()
            Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button(isNew ? "Ajouter" : "Enregistrer", action: save)
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .regDisabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Champs

    @ViewBuilder private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            RegField(label: "Nom (facultatif)") {
                RegTextField(placeholder: kind == .meraki ? "ex. Tableau de bord Meraki" : "ex. UDM Pro de la clinique", text: $name)
            }
            if kind != .meraki {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 10) {
                        hostField.frame(minWidth: 220)
                        portField.frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        hostField
                        portField.frame(width: 100)
                    }
                }
                if hostInvalid {
                    Text("Adresse invalide\u{00A0}: saisissez l’adresse IP ou le nom du contrôleur (ex. 192.168.1.1), sans «\u{00A0}https://\u{00A0}».")
                        .font(Theme.small).foregroundStyle(Theme.critical)
                } else if portValue == nil {
                    Text("Port invalide\u{00A0}: un nombre de 1 à 65\u{202F}535.").font(Theme.small).foregroundStyle(Theme.critical)
                }
            }
            if kind == .unifi {
                RegField(label: "Type de contrôleur") {
                    Picker("Type de contrôleur", selection: $unifiOS) {
                        Text("UniFi OS (UDM, UCG, Cloud Key Gen2+, UniFi OS Server)").tag(true)
                        Text("Contrôleur classique (logiciel UniFi Network, Cloud Key Gen1)").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            if kind.authModes.count > 1 {
                RegField(label: "Authentification") {
                    Picker("Authentification", selection: $authMode) {
                        ForEach(kind.authModes) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            if let label = draft.authMode.accountLabel {
                RegField(label: label) {
                    RegTextField(placeholder: draft.authMode == .omadaOpenAPI ? "Client ID de l’application Open API" : "compte en lecture seule (ex. netscope)",
                                 text: $account, mono: true, invalid: accountMissing && !account.isEmpty)
                }
            }
            scopeFields
            Text(guidance).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hostField: some View {
        RegField(label: "Adresse du contrôleur") {
            RegTextField(placeholder: kind == .omada ? "ex. 10.30.0.5" : "ex. 192.168.1.1", text: $host, mono: true, invalid: hostInvalid)
        }
    }

    private var portField: some View {
        RegField(label: "Port HTTPS") {
            RegTextField(placeholder: String(kind.defaultPort), text: $port, mono: true, invalid: portValue == nil)
        }
    }

    @ViewBuilder private var scopeFields: some View {
        switch kind {
        case .unifi:
            RegField(label: "Site UniFi") {
                RegTextField(placeholder: "default (ou la description du site, ex. Clinique)", text: $siteRef, mono: true)
            }
        case .omada:
            HStack(alignment: .bottom, spacing: 10) {
                RegField(label: "Site Omada") {
                    RegTextField(placeholder: "nom ou ID (vide : le premier)", text: $siteRef)
                }
                RegField(label: "ID du contrôleur (facultatif)") {
                    RegTextField(placeholder: "omadacId, lu sur /api/info si vide", text: $orgRef, mono: true)
                }
            }
        case .meraki:
            HStack(alignment: .bottom, spacing: 10) {
                RegField(label: "Organisation (facultatif)") {
                    RegTextField(placeholder: "nom ou ID (vide : la première)", text: $orgRef)
                }
                RegField(label: "Réseau") {
                    RegTextField(placeholder: "nom ou ID du réseau (vide : le premier)", text: $siteRef)
                }
            }
        }
    }

    private var guidance: String {
        switch draft.authMode {
        case .unifiAPIKey:
            return "Clé d’API créée dans UniFi Network › Paramètres › Plan de contrôle › Intégrations (UniFi OS, Network 9 ou plus). NetScope lit stat/device et stat/sta du site (switchs, bornes, clients), sans rien modifier."
        case .unifiLocalAccount:
            return "Compte local du contrôleur, de préférence avec le rôle «\u{00A0}Lecture seule\u{00A0}» (pas un compte UI.com à double authentification). La session est ouverte puis fermée à chaque lecture."
        case .omadaOpenAPI:
            return "Application Open API en mode «\u{00A0}Client\u{00A0}» (Paramètres › Plateforme › Open API), avec un rôle en lecture seule sur le site. NetScope demande un jeton d’accès à chaque lecture."
        case .omadaWebAccount:
            return "Compte du contrôleur avec un rôle en lecture (Viewer). Pour un contrôleur 5.9 ou plus, préférez l’Open API."
        case .merakiAPIKey:
            return "Clé d’API du tableau de bord (Mon profil › Clés d’API), d’un administrateur en lecture seule de l’organisation\u{00A0}; l’accès à l’API doit être activé (Organisation › Paramètres). Requêtes vers api.meraki.com, en GET seulement."
        }
    }

    // MARK: Secret

    private var secretBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(draft.authMode.secretLabel).font(Theme.bodySemibold)
                if !secret.isEmpty {
                    Chip(text: "À enregistrer", tone: .accent)
                } else if hasStoredSecret {
                    Chip(text: "Enregistré", tone: .success, systemImage: "lock.fill")
                } else {
                    Chip(text: "Manquant", tone: .warning, systemImage: "lock.open")
                }
                Spacer()
            }
            RegTextField(placeholder: hasStoredSecret ? "Enregistré au Trousseau (laisser vide pour le garder)" : "coller ou saisir le secret",
                         text: $secret, mono: true, secure: true, invalid: !secret.isEmpty && SiteControllerStore.secretProblem(secret) != nil)
            if !secret.isEmpty, let problem = SiteControllerStore.secretProblem(secret) {
                Text(problem).font(Theme.small).foregroundStyle(Theme.critical)
            }
            Text("Gardé au Trousseau macOS, un compte par contrôleur (service com.danymenard.netscope.controleurs). Il part seulement vers ce contrôleur, en HTTPS, jamais dans une adresse, un journal, sites.json, une sauvegarde ou les réponses copiées.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Certificat

    private var pending: SiteControllerStore.PendingCertificate? { outcome?.pending }

    private var certificateBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Certificat HTTPS").font(Theme.bodySemibold)
                if pending?.changed == true {
                    Chip(text: "Empreinte changée", tone: .critical)
                } else if pending != nil {
                    Chip(text: "À accepter", tone: .warning)
                } else if pinned != nil {
                    Chip(text: "Empreinte acceptée", tone: .success)
                } else {
                    Chip(text: "Inconnu", tone: .neutral)
                }
                Spacer()
            }
            if let pending {
                Text(pending.changed
                     ? "Le certificat présenté ne correspond plus à l’empreinte acceptée\u{00A0}: connexion refusée. N’acceptez la nouvelle empreinte qu’après l’avoir vérifiée (certificat renouvelé)."
                     : "Premier contact\u{00A0}: comparez cette empreinte SHA-256 avec celle du certificat du contrôleur (cadenas du navigateur sur https://\(draft.cleanHost)) avant de l’accepter.")
                    .font(Theme.small).foregroundStyle(pending.changed ? Theme.critical : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !pending.subject.isEmpty {
                    Text("Sujet\u{00A0}: \(pending.subject)").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                RegFingerprintText(fingerprint: pending.fingerprint)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Refuser") {
                        outcome?.pending = nil
                        outcome?.error = nil
                        error = "Certificat refusé\u{00A0}: aucune connexion à ce contrôleur."
                    }
                    .buttonStyle(.secondary)
                    Button("Accepter cette empreinte") { acceptPending() }.buttonStyle(.primary)
                }
            } else if let pinned {
                RegFingerprintText(fingerprint: pinned)
                HStack {
                    Text(draft.sameTarget(as: original) || original.pinnedFingerprint != pinned
                         ? "Toute connexion dont le certificat a une autre empreinte est refusée."
                         : "Adresse changée\u{00A0}: cette empreinte sera oubliée à l’enregistrement.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Oublier l’empreinte") { self.pinned = nil }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
            } else {
                Text("Un contrôleur local utilise en général un certificat autosigné. Au premier «\u{00A0}Tester\u{00A0}», son empreinte SHA-256 s’affiche ici\u{00A0}: vous l’acceptez une fois, puis toute autre empreinte est refusée.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func acceptPending() {
        guard let pending else { return }
        outcome?.pending = nil
        outcome?.error = nil
        guard pending.host.lowercased() == draft.cleanHost.lowercased(), pending.port == draft.effectivePort else {
            error = "L’adresse a changé depuis l’essai\u{00A0}: testez de nouveau pour vérifier le certificat."
            return
        }
        pinned = pending.fingerprint
        error = nil
        acceptedNotice = true
    }

    // MARK: Tester

    private var testBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    testTitle
                    Spacer(minLength: 8)
                    testButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    testTitle
                    testButtons
                }
            }
            if acceptedNotice, pinned != nil {
                RegNotice("Empreinte acceptée\u{00A0}: cliquez sur «\u{00A0}Tester\u{00A0}» pour lire le contrôleur.", tone: .neutral)
            }
            if let outcome {
                if let message = outcome.error, outcome.pending == nil || outcome.pending?.changed == true {
                    RegNotice(message, tone: .critical)
                }
                if let report = outcome.report {
                    RegTileRow {
                        RegTile("Contrôleur", report.controllerName, mono: true)
                        RegTile("Version", report.version ?? "—", mono: true)
                        RegTile(kind == .meraki ? "Réseau" : "Site", report.siteName ?? "—")
                        RegTile("Switchs", "\(report.switches.count)")
                        RegTile("Bornes", "\(report.aps.count)")
                        RegTile("Clients", "\(report.clients.count)")
                    }
                    ForEach(report.notes, id: \.self) { note in
                        Text(note).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                RegFortiCallsSummary(calls: outcome.calls)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var testTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tester la connexion").font(Theme.bodySemibold)
            Text(outcome.map { "Dernier essai\u{00A0}: \(SwitchText.dateTime($0.date))" } ?? "Lit le contrôleur, le site, les switchs, les bornes et les clients (lecture seule).")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var testButtons: some View {
        HStack(spacing: 8) {
            Button(copied ? "Copié" : "Copier les réponses brutes (diagnostic)") {
                store.copyDiagnostic(draft, calls: outcome?.calls, report: outcome?.report)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
            .buttonStyle(.secondary)
            .regDisabled((outcome?.calls ?? []).isEmpty)
            .help("Copie les réponses JSON de chaque appel du dernier essai, sans le secret, pour ajuster la lecture à votre version du contrôleur.")
            Button(action: test) {
                HStack(spacing: 6) {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testing ? "Test…" : "Tester")
                }
            }
            .buttonStyle(.primary)
            .regDisabled(!canTest)
        }
        .fixedSize()
    }

    // MARK: Actions

    private func test() {
        testing = true
        error = nil
        acceptedNotice = false
        let candidate = draft
        let typed = secret
        Task { @MainActor in
            let result = await store.test(candidate, typedSecret: typed)
            testing = false
            outcome = result
            if !isNew, candidate.sameTarget(as: original) { store.recordTest(result, for: original.id) }
        }
    }

    private func save() {
        if let problem = store.save(draft, secret: secret.isEmpty ? nil : secret, siteID: siteID, state: state) {
            error = problem
            return
        }
        dismiss()
    }
}
