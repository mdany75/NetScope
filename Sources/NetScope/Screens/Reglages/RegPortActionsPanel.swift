import NetScopeCore
import SwiftUI

/// Réglages › Switchs › Actions sur les ports (note 73) : autorisation (DÉSACTIVÉE par défaut),
/// uplinks et port de ce Mac (refusés par défaut), durées, et identifiants SNMP d'écriture
/// (communauté ou utilisateur v3 dédiés, distincts de la lecture, gardés au Trousseau).
struct RegPortActionsPanel: View {
    @ObservedObject private var model = PortActionModel.shared
    @ObservedObject private var switches = SwitchStore.shared
    @State private var draft = SNMPWriteCredentials()
    @State private var message: (text: String, tone: Tone)?
    @State private var reveal = false

    var body: some View {
        RegPanel(title: "Actions sur les ports",
                 subtitle: "Couper et rallumer le PoE d’un port (téléphone, borne ou caméra figés) et redémarrer le port d’un FortiSwitch. Ce sont les seules fonctions de NetScope qui modifient un équipement\u{00A0}: chaque action est confirmée, puis notée au journal et dans la chronologie de l’appareil.") {
            RegToggleRow(title: "Autoriser les actions sur les ports",
                         detail: "Désactivé par défaut. Une fois autorisées, les actions apparaissent dans le détail d’un port (Switchs et ports) et dans la fiche d’un appareil dont le port est connu. FortiSwitch géré\u{00A0}: API REST de la FortiGate (son jeton doit avoir «\u{00A0}WiFi & Switch Controller\u{00A0}» en lecture-écriture). Autre switch\u{00A0}: SNMP en écriture (pethPsePortAdminEnable), avec les identifiants ci-dessous.",
                         isOn: $model.settings.enabled)
            RegToggleRow(title: "Permettre aussi un uplink ou le port de ce Mac",
                         detail: "Déconseillé. Refusé par défaut\u{00A0}: couper un uplink isole tout ce qui est derrière, couper le port de ce Mac coupe NetScope. Même permis, une case à cocher est exigée dans la confirmation.",
                         isOn: $model.settings.allowRiskyPorts,
                         isEnabled: model.settings.enabled)
            durations
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
            writeBox
                .padding(.top, 6)
        }
        .task { await model.checkCredentials() }
    }

    // MARK: Durées

    private var durations: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { offStepper; followStepper; bounceStepper; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { offStepper; followStepper; bounceStepper }
        }
        .disabled(!model.settings.enabled)
        .opacity(model.settings.enabled ? 1 : 0.55)
    }

    private var offStepper: some View {
        Stepper(value: $model.settings.poeOffSeconds, in: PortActionSettings.offRange) {
            labeled("Coupure du PoE (SNMP)", PortActionFormat.seconds(model.settings.poeOffSeconds))
        }
        .fixedSize()
    }

    private var followStepper: some View {
        Stepper(value: $model.settings.followUpSeconds, in: PortActionSettings.followUpRange, step: 30) {
            labeled("Attente du retour", PortActionFormat.seconds(model.settings.followUpSeconds))
        }
        .fixedSize()
    }

    private var bounceStepper: some View {
        Stepper(value: $model.settings.bounceSeconds, in: PortActionSettings.bounceRange) {
            labeled("Lien coupé (FortiSwitch)", PortActionFormat.seconds(model.settings.bounceSeconds))
        }
        .fixedSize()
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
        }
    }

    // MARK: Identifiants d'écriture

    private var writeBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Identifiants SNMP d’écriture").font(Theme.bodySemibold)
                Chip(text: "Trousseau", tone: .neutral, systemImage: "lock")
                Spacer(minLength: 8)
                if model.hasWriteCredentials {
                    RegPill(text: model.writeSummary ?? "Enregistrés", tone: .success)
                } else {
                    RegPill(text: "Aucun", tone: .neutral)
                }
            }
            Picker("", selection: $draft.version) {
                ForEach(SNMPWriteCredentials.Version.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if draft.version == .v2c {
                RegField(label: "Communauté d’écriture (RW)") {
                    HStack(spacing: 6) {
                        RegTextField(placeholder: model.hasWriteCredentials ? "•••••••• (enregistrée)" : "communauté RW dédiée",
                                     text: $draft.community, mono: true, secure: !reveal)
                        Button(reveal ? "Masquer" : "Afficher") { reveal.toggle() }.buttonStyle(.secondary)
                    }
                }
            } else {
                v3Fields
            }
            Text("Distincts de ceux de lecture (Réglages › Identifiants)\u{00A0}: créez sur le switch une communauté RW ou un utilisateur v3 limité à POWER-ETHERNET-MIB, et n’autorisez que ce Mac à écrire. En v2c, la communauté circule en clair.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let message {
                    Text(message.text).font(Theme.small).foregroundStyle(message.tone.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Effacer") { erase() }
                    .buttonStyle(.secondary)
                    .regDisabled(!model.hasWriteCredentials)
                Button(action: save) { Label("Enregistrer dans le Trousseau", systemImage: "lock") }
                    .buttonStyle(.primary)
                    .regDisabled(draft.problem() != nil)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var v3Fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                RegField(label: "Utilisateur") { RegTextField(placeholder: "ex. netscope-rw", text: $draft.v3User, mono: true) }
                RegField(label: "Niveau") {
                    Picker("", selection: $draft.v3Level) {
                        ForEach([SNMPv3Level.authNoPriv, .authPriv], id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            GridRow {
                RegField(label: "Mot de passe auth.") {
                    RegTextField(placeholder: "8 caractères au moins", text: $draft.v3AuthPassword, mono: true, secure: true)
                }
                RegField(label: "Authentification") {
                    Picker("", selection: $draft.v3Auth) {
                        ForEach(SNMPAuthProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            if draft.v3Level == .authPriv {
                GridRow {
                    RegField(label: "Mot de passe priv.") {
                        RegTextField(placeholder: "8 caractères au moins", text: $draft.v3PrivPassword, mono: true, secure: true)
                    }
                    RegField(label: "Confidentialité") {
                        Picker("", selection: $draft.v3Priv) {
                            ForEach(SNMPPrivProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
            }
        }
    }

    // MARK: Trousseau

    private func save() {
        let read = RegSNMPCredentials.load()?.community ?? switches.community
        if let problem = draft.problem(readCommunity: read) {
            message = (problem, .critical)
            return
        }
        do {
            try model.saveCredentials(draft)
            draft = SNMPWriteCredentials(version: draft.version)
            message = ("Enregistré dans le Trousseau.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }

    private func erase() {
        do {
            try model.eraseCredentials()
            message = ("Identifiants d’écriture effacés.", .neutral)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }
}
