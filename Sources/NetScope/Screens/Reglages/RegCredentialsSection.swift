import NetScopeCore
import SwiftUI

/// Réglages › Identifiants : SNMP v2c (communauté) et SNMP v3 (utilisateur, authentification,
/// confidentialité), enregistrés dans le Trousseau macOS. Les secrets ne sont jamais réaffichés.
struct RegCredentialsSection: View {
    @State private var draft = RegSNMPCredentials()
    @State private var saved: RegSNMPCredentials?
    @State private var loaded = false
    @State private var message: (text: String, tone: Tone)?

    private var isDirty: Bool { draft != mergedDraft(from: saved) }

    var body: some View {
        RegPanel(title: "Identifiants (SNMP)",
                 subtitle: "Utilisés pour interroger les switchs et lire sysName, sysDescr, table MAC et voisins LLDP. Les secrets ne quittent jamais le Trousseau.",
                 accessory: {
                     HStack(spacing: 8) {
                         Button {} label: { Label("Tout tester", systemImage: "checkmark.shield") }
                             .buttonStyle(.secondary)
                             .regDisabled(true)
                             .help("Test SNMP : bientôt, avec le module Switchs")
                     }
                 }, content: {
                     vaultBanner
                     HStack(alignment: .top, spacing: 14) {
                         v2cBox
                         v3Box
                     }
                     .padding(.top, 14)
                     HStack(spacing: 8) {
                         if let message {
                             Text(message.text).font(Theme.small).foregroundStyle(message.tone.foreground)
                         } else if isDirty {
                             Text("Modifications non enregistrées").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warning)
                         }
                         Spacer()
                         Button("Effacer du Trousseau", role: .destructive, action: erase)
                             .buttonStyle(.secondary)
                             .regDisabled(saved == nil)
                         Button("Annuler", action: { draft = mergedDraft(from: saved); message = nil })
                             .buttonStyle(.secondary)
                             .regDisabled(!isDirty)
                         Button(action: save) { Label("Enregistrer dans le Trousseau", systemImage: "lock") }
                             .buttonStyle(.primary)
                             .regDisabled(!isDirty)
                     }
                     .padding(.top, 14)
                     RegNotice("SSH et WMI (identifiants par switch ou par plage, ordre d’essai) : bientôt.", tone: .neutral)
                         .padding(.top, 12)
                 })
        .onAppear(perform: load)
    }

    private var vaultBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Trousseau macOS · service com.danymenard.netscope.snmp").font(Theme.bodySemibold)
                Text(saved == nil ? "Aucun identifiant enregistré." : "\(saved?.configuredCount ?? 0) identifiant(s) enregistré(s), chiffrés par macOS.")
                    .font(Theme.small)
            }
            Spacer()
        }
        .foregroundStyle(saved == nil ? Theme.neutralText : Theme.success)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(saved == nil ? Theme.neutralSoft : Theme.successSoft))
    }

    private func box<Content: View>(_ title: String, type: String, tone: Tone, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(Theme.bodySemibold)
                Chip(text: type, tone: tone)
                Spacer()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func secretPlaceholder(_ isSet: Bool) -> String {
        isSet ? "•••••••• (enregistré)" : "Non renseigné"
    }

    private var v2cBox: some View {
        box("Communauté en lecture", type: "SNMP v2c", tone: .warning) {
            RegField(label: "Communauté") {
                RegTextField(placeholder: secretPlaceholder(!(saved?.community.isEmpty ?? true)), text: $draft.community, mono: true, secure: true)
            }
            KeyValueRow(key: "Accès", value: "Lecture seule", keyWidth: 110)
            KeyValueRow(key: "Port", value: "UDP 161", mono: true, keyWidth: 110)
            Text("v2c transmet la communauté en clair sur le réseau : préférez SNMP v3 quand le switch le permet.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var v3Box: some View {
        box("Utilisateur SNMP v3", type: "SNMP v3", tone: .success) {
            HStack(alignment: .bottom, spacing: 10) {
                RegField(label: "Utilisateur") {
                    RegTextField(placeholder: "ex. netscope-ro", text: $draft.v3User, mono: true)
                }
                RegField(label: "Niveau de sécurité") {
                    Picker("", selection: $draft.v3Level) {
                        ForEach(RegSNMPCredentials.Level.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                }
            }
            if draft.v3Level != .noAuthNoPriv {
                HStack(alignment: .bottom, spacing: 10) {
                    RegField(label: "Authentification") {
                        Picker("", selection: $draft.v3AuthProtocol) {
                            ForEach(RegSNMPCredentials.authProtocols, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                    }
                    RegField(label: "Mot de passe auth.") {
                        RegTextField(placeholder: secretPlaceholder(!(saved?.v3AuthPassword.isEmpty ?? true)), text: $draft.v3AuthPassword, mono: true, secure: true)
                    }
                }
            }
            if draft.v3Level == .authPriv {
                HStack(alignment: .bottom, spacing: 10) {
                    RegField(label: "Confidentialité") {
                        Picker("", selection: $draft.v3PrivProtocol) {
                            ForEach(RegSNMPCredentials.privProtocols, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                    }
                    RegField(label: "Mot de passe priv.") {
                        RegTextField(placeholder: secretPlaceholder(!(saved?.v3PrivPassword.isEmpty ?? true)), text: $draft.v3PrivPassword, mono: true, secure: true)
                    }
                }
            }
            RegField(label: "Contexte (facultatif)") {
                RegTextField(placeholder: "vide par défaut", text: $draft.v3Context, mono: true)
            }
        }
    }

    // MARK: Trousseau

    private func load() {
        guard !loaded else { return }
        loaded = true
        if RegEnvironment.isSandboxed {
            // Démonstration : identifiants fictifs du croquis, rien n'est lu dans le Trousseau.
            if RegEnvironment.isDemo {
                var demo = RegSNMPCredentials()
                demo.community = "demo"
                demo.v3User = "ipscan-ro"
                demo.v3AuthPassword = "demo-auth"
                demo.v3PrivPassword = "demo-priv"
                saved = demo
                draft = mergedDraft(from: demo)
            }
            return
        }
        saved = RegSNMPCredentials.load()
        draft = mergedDraft(from: saved)
    }

    /// Brouillon affiché : champs non secrets repris, secrets laissés vides (ils restent au Trousseau).
    private func mergedDraft(from credentials: RegSNMPCredentials?) -> RegSNMPCredentials {
        guard let credentials else { return RegSNMPCredentials() }
        var copy = credentials
        copy.community = ""
        copy.v3AuthPassword = ""
        copy.v3PrivPassword = ""
        return copy
    }

    private func save() {
        var result = saved ?? RegSNMPCredentials()
        result.v3User = draft.v3User.trimmingCharacters(in: .whitespaces)
        result.v3Level = draft.v3Level
        result.v3AuthProtocol = draft.v3AuthProtocol
        result.v3PrivProtocol = draft.v3PrivProtocol
        result.v3Context = draft.v3Context
        // Un secret saisi remplace l'ancien ; un champ laissé vide garde la valeur enregistrée.
        if !draft.community.isEmpty { result.community = draft.community }
        if !draft.v3AuthPassword.isEmpty { result.v3AuthPassword = draft.v3AuthPassword }
        if !draft.v3PrivPassword.isEmpty { result.v3PrivPassword = draft.v3PrivPassword }
        if !draft.v3AuthPassword.isEmpty, draft.v3AuthPassword.count < 8 {
            message = ("Mot de passe d’authentification trop court : 8 caractères au moins (RFC 3414).", .critical)
            return
        }
        do {
            try result.save()
            saved = result
            draft = mergedDraft(from: result)
            message = ("Enregistré dans le Trousseau.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }

    private func erase() {
        do {
            try RegSNMPCredentials.erase()
            saved = nil
            draft = RegSNMPCredentials()
            message = ("Identifiants effacés du Trousseau.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }
}
