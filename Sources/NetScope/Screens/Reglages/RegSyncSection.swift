import NetScopeCore
import SwiftUI

/// Note 56 : Réglages › Export et sauvegarde › « Synchronisation entre vos Mac » : par iCloud Drive
/// (dossier NetScope › Sync), désactivée par défaut, site par site ; état « Synchronisé il y a… »,
/// « Synchroniser maintenant », mot de passe de synchronisation (Trousseau), conflits à rétablir.
struct RegSyncSection: View {
    @ObservedObject private var sync = RegSyncController.shared
    @ObservedObject private var siteModel = SiteModel.shared

    var body: some View {
        RegPanel(title: "Synchronisation entre vos Mac",
                 subtitle: "Par iCloud Drive (dossier NetScope › Sync, sans CloudKit), site par site. Fusion par date de modification\u{00A0}; un conflit n’est jamais écrasé sans le dire.") {
            VStack(alignment: .leading, spacing: 0) {
                RegToggleRow(title: "Synchroniser par iCloud Drive",
                             detail: sync.isAvailable
                                 ? "Désactivée par défaut. Fiches des sites, inventaires, notes des appareils, FortiGate et leurs jetons (chiffrés)."
                                 : "iCloud Drive n’est pas activé sur ce Mac.",
                             isOn: $sync.enabled)
                    .regDisabled(!sync.isAvailable)
                if sync.enabled {
                    statusBox.padding(.top, 4)
                    passwordBox.padding(.top, 10)
                    siteList.padding(.top, 14)
                    if !sync.remoteSites.isEmpty { remoteList.padding(.top, 14) }
                    if !sync.conflicts.isEmpty { conflictList.padding(.top, 14) }
                }
                if let message = sync.message {
                    RegNotice(message.text, tone: message.tone).padding(.top, 10)
                }
                Text("Jamais de fusion entre sites\u{00A0}: un site est reconnu par son identifiant, jamais par ses plages (plusieurs sites peuvent avoir les mêmes). Une suppression faite sur un autre Mac est signalée, jamais appliquée d’office.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .onAppear { sync.appear() }
        .onDisappear { sync.disappear() }
        .sheet(isPresented: $sync.passwordSheet) {
            RegSyncPasswordSheet { sync.passwordSheet = false }
        }
    }

    // MARK: État

    private var statusText: String {
        guard let last = sync.lastSync else { return "Jamais synchronisé" }
        return "Synchronisé " + RegSyncFormat.ago(last, now: sync.now)
    }

    private var statusBox: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                statusInfo
                Spacer(minLength: 8)
                statusButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                statusInfo
                statusButtons
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var statusInfo: some View {
        HStack(spacing: 10) {
            Image(systemName: sync.conflicts.isEmpty ? "checkmark.icloud" : "exclamationmark.icloud")
                .font(.system(size: 18)).foregroundStyle(sync.conflicts.isEmpty ? Theme.success : Theme.warning)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text("Ce Mac\u{00A0}: \(sync.deviceName)" + (sync.lastSummary.map { " · " + $0 } ?? ""))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sync.folderLabel + " · toutes les 15\u{00A0}minutes et au lancement")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
    }

    private var statusButtons: some View {
        HStack(spacing: 8) {
            if sync.pendingCount > 0 {
                Button(action: sync.applyAndRelaunch) {
                    Label("Redémarrer et appliquer (\(sync.pendingCount))", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.secondary)
                .help("Les changements reçus sont appliqués au lancement, après une sauvegarde de sécurité")
            }
            Button(action: { sync.syncNow() }) {
                if sync.isSyncing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Synchronisation…") }
                } else {
                    Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.primary)
            .regDisabled(sync.isSyncing)
        }
        .fixedSize()
    }

    // MARK: Mot de passe

    private var passwordBox: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                passwordInfo
                Spacer(minLength: 8)
                passwordButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                passwordInfo
                passwordButtons
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var passwordInfo: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sync.hasPassword ? "lock.fill" : "lock.open")
                .font(.system(size: 15)).foregroundStyle(sync.hasPassword ? Theme.success : Theme.warning)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(sync.hasPassword ? "Mot de passe de synchronisation mémorisé dans le Trousseau" : "Aucun mot de passe de synchronisation")
                    .font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(sync.hasPassword
                     ? "Les jetons des FortiGate sont chiffrés avant d’aller dans iCloud Drive. Le même mot de passe doit être saisi sur chaque Mac."
                     : "Les jetons des FortiGate ne sont pas synchronisés (jamais envoyés en clair)\u{00A0}; le reste l’est.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var passwordButtons: some View {
        HStack(spacing: 8) {
            Button(sync.hasPassword ? "Changer…" : "Définir…") { sync.passwordSheet = true }
                .buttonStyle(RegSmallButtonStyle())
            if sync.hasPassword {
                Button("Oublier", action: sync.forgetPassword).buttonStyle(RegSmallButtonStyle())
            }
        }
        .fixedSize()
    }

    // MARK: Sites

    private var siteList: some View {
        let sites = siteModel.list.sortedByName
        let count = sites.filter { sync.isSynced($0.id) }.count
        return VStack(alignment: .leading, spacing: 8) {
            RegLabel("Sites synchronisés (\(count) sur \(sites.count))")
            if sites.isEmpty {
                RegNotice("Aucun site sur ce Mac\u{00A0}: créez-en un dans Réglages › Sites, ou ajoutez un site d’un autre Mac ci-dessous.", tone: .neutral)
            } else {
                RegSyncRows(count: sites.count) { index in
                    let site = sites[index]
                    let on = sync.isSynced(site.id)
                    return HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { on }, set: { sync.setSynced(site.id, $0) }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Text(site.displayName).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                            .layoutPriority(1)
                        Text(site.rangesLabel).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        if let conflict = sync.conflicts.first(where: { $0.siteID == site.id }) {
                            Chip(text: "Conflit", tone: .warning, systemImage: "exclamationmark.triangle.fill")
                                .help("\(conflict.label)\u{00A0}: version de «\u{00A0}\(conflict.keptDevice)\u{00A0}» gardée")
                        } else if on {
                            Chip(text: "Synchronisé", tone: .success, systemImage: "checkmark.icloud")
                        } else {
                            Text("Sur ce Mac seulement").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private var remoteList: some View {
        VStack(alignment: .leading, spacing: 8) {
            RegLabel("Sur vos autres Mac (\(sync.remoteSites.count))")
            RegSyncRows(count: sync.remoteSites.count) { index in
                let site = sync.remoteSites[index]
                return HStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(site.name).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                        Text(site.devices.joined(separator: ", ") + " · " + RegSyncFormat.ago(site.updated, now: sync.now))
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Ajouter à ce Mac") { sync.addRemoteSite(site) }
                        .buttonStyle(RegSmallButtonStyle())
                        .help("Synchroniser ce site ici aussi (appliqué au redémarrage)")
                }
            }
        }
    }

    // MARK: Conflits

    private var conflictList: some View {
        VStack(alignment: .leading, spacing: 8) {
            RegLabel("Conflits (\(sync.conflicts.count))")
            RegSyncRows(count: sync.conflicts.count) { index in
                let conflict = sync.conflicts[index]
                return HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.warning).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(conflict.label) · \(conflict.siteName)").font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                        Text("Gardée\u{00A0}: \(conflict.keptDevice), modifiée \(RegSyncFormat.ago(conflict.keptModified, now: sync.now)) · écartée\u{00A0}: \(conflict.otherDevice), modifiée \(RegSyncFormat.ago(conflict.otherModified, now: sync.now))")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        conflictButtons(conflict)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func conflictButtons(_ conflict: ConfigSyncConflict) -> some View {
                    HStack(spacing: 6) {
                        if conflict.otherData != nil {
                            Button("Rétablir l’autre version") { sync.restore(conflict) }
                                .buttonStyle(RegSmallButtonStyle())
                                .help("Remettre la version de «\u{00A0}\(conflict.otherDevice)\u{00A0}» (au redémarrage), puis l’envoyer aux autres Mac")
                        }
                        Button("Garder la version actuelle") { sync.dismiss(conflict) }
                            .buttonStyle(RegSmallButtonStyle())
                            .help("Garder la version actuelle et retirer ce conflit de la liste")
                    }
                    .fixedSize()
                    .padding(.top, 2)
    }
}

/// Lignes dans un cadre (fond atténué, séparateurs), comme la liste des secrets d'une sauvegarde.
struct RegSyncRows<Row: View>: View {
    let count: Int
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                row(index)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Mot de passe de synchronisation : saisie, confirmation, force ; gardé au Trousseau de ce Mac.
struct RegSyncPasswordSheet: View {
    @ObservedObject private var sync = RegSyncController.shared
    let dismiss: () -> Void

    @State private var password = ""
    @State private var confirmation = ""

    private var strength: BackupPasswordStrength { .evaluate(password) }
    private var mismatch: Bool { !confirmation.isEmpty && confirmation != password }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "key.icloud").font(.system(size: 17)).foregroundStyle(Theme.accent)
                    Text("Mot de passe de synchronisation").font(Theme.panelTitle).foregroundStyle(Theme.text)
                }
                Text("Chiffre les jetons des FortiGate avant qu’ils aillent dans iCloud Drive (AES-GCM 256\u{00A0}bits, PBKDF2). Saisissez le même sur chacun de vos Mac\u{00A0}; il est gardé dans le Trousseau de ce Mac seulement.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                RegField(label: "Mot de passe") {
                    RegTextField(placeholder: "Au moins \(BackupPasswordStrength.minimumLength) caractères", text: $password, secure: true)
                }
                RegBackupStrengthMeter(strength: strength)
                RegField(label: "Confirmation") {
                    RegTextField(placeholder: "Le même mot de passe", text: $confirmation, secure: true, invalid: mismatch)
                }
                if mismatch {
                    Text("Les deux mots de passe ne sont pas identiques.").font(Theme.small).foregroundStyle(Theme.critical)
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("Annuler") { password = ""; confirmation = ""; dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    let chosen = password
                    password = ""
                    confirmation = ""
                    sync.setPassword(chosen)
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .regDisabled(!(strength.isAcceptable && confirmation == password))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 500)
        .background(Theme.panel)
    }
}
