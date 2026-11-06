import NetScopeCore
import SwiftUI

/// Notes 56 et 86 : Réglages › Synchronisation, tableau de bord de la synchronisation de TOUTES
/// les données entre les Mac : état (« Synchronisé il y a… », « Synchroniser maintenant »), Mac
/// vus (nom, modèle, version, dernière synchro), catégories à cocher avec leurs compteurs, sites,
/// changements reçus récents, conflits à rétablir, suppressions venues d'un autre Mac à confirmer,
/// dossier (iCloud Drive ou un autre) et mot de passe de synchronisation (Trousseau).
struct RegSyncSection: View {
    @ObservedObject private var sync = RegSyncController.shared
    @ObservedObject private var siteModel = SiteModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            mainPanel
            if sync.enabled {
                if !sync.pendingDeletions.isEmpty { deletionPanel }
                if !sync.conflicts.isEmpty { conflictPanel }
                devicePanel
                categoryPanel
                sitePanel
                recentPanel
            }
        }
        .onAppear { sync.appear() }
        .onDisappear { sync.disappear() }
        .sheet(isPresented: $sync.passwordSheet) {
            RegSyncPasswordSheet { sync.passwordSheet = false }
        }
    }

    // MARK: État

    private var mainPanel: some View {
        RegPanel(title: "Synchronisation entre vos Mac",
                 subtitle: "Toutes les données de NetScope, par un dossier partagé (iCloud Drive par défaut, sans CloudKit). Fusion élément par élément\u{00A0}; un conflit n’est jamais écrasé sans le dire.") {
            VStack(alignment: .leading, spacing: 0) {
                RegToggleRow(title: "Synchroniser les données entre mes Mac",
                             detail: sync.isAvailable
                                 ? "Désactivée par défaut. Sites, inventaires, carnet d’Accès distant, Surveillance, réglages… et leurs secrets, chiffrés."
                                 : "iCloud Drive n’est pas activé sur ce Mac\u{00A0}: activez-le, ou choisissez un autre dossier.",
                             isOn: $sync.enabled)
                    .regDisabled(!sync.isAvailable && sync.usesICloud)
                if sync.enabled {
                    statusBox.padding(.top, 4)
                    ForEach(sync.olderDevices) { device in
                        RegNotice("«\u{00A0}\(device.name)\u{00A0}» utilise une version plus ancienne de NetScope (\(device.versionLabel))\u{00A0}: ses changements sont fusionnés sans effacer ce que sa version ne connaît pas. Mettez-le à jour pour tout synchroniser.",
                                  tone: .warning)
                            .padding(.top, 8)
                    }
                    folderBox.padding(.top, 10)
                    passwordBox.padding(.top, 10)
                }
                if let message = sync.message {
                    RegNotice(message.text, tone: message.tone).padding(.top, 10)
                }
            }
        }
    }

    private var statusText: String {
        guard let last = sync.lastSync else { return "Jamais synchronisé" }
        return "Synchronisé " + RegSyncFormat.ago(last, now: sync.now)
    }

    private var hasAttention: Bool { !sync.conflicts.isEmpty || !sync.pendingDeletions.isEmpty }

    private var statusBox: some View {
        RegSyncBox {
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
        }
    }

    private var statusInfo: some View {
        HStack(spacing: 10) {
            Image(systemName: hasAttention ? "exclamationmark.icloud" : "checkmark.icloud")
                .font(.system(size: 18)).foregroundStyle(hasAttention ? Theme.warning : Theme.success)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text("Ce Mac\u{00A0}: \(sync.deviceName)" + (sync.lastSummary.map { " · " + $0 } ?? ""))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Quelques secondes après un changement, à l’ouverture de NetScope, quand un autre Mac écrit, et toutes les 15\u{00A0}minutes\u{00A0}; jamais pendant un scan.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                .help("Quelques changements reçus ne s’appliquent qu’au lancement, après une sauvegarde de sécurité")
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

    // MARK: Dossier

    private var folderBox: some View {
        RegSyncBox {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        folderInfo
                        Spacer(minLength: 8)
                        folderButtons
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        folderInfo
                        folderButtons
                    }
                }
                if !sync.usesICloud {
                    Text("Autre dossier que iCloud Drive\u{00A0}: choisissez le même sur chacun de vos Mac. Un partage réseau doit être monté pour synchroniser, et un autre Mac n’y est vu qu’à la minuterie de 15\u{00A0}minutes. Les secrets restent chiffrés.")
                        .font(Theme.small).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var folderInfo: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sync.usesICloud ? "icloud" : "externaldrive.connected.to.line.below")
                .font(.system(size: 15)).foregroundStyle(sync.usesICloud ? Theme.accent : Theme.warning)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dossier\u{00A0}: " + sync.folderLabel).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(sync.usesICloud ? "iCloud Drive par défaut. OneDrive, un NAS monté ou un dossier partagé conviennent aussi."
                                     : "Dossier choisi à la place d’iCloud Drive.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var folderButtons: some View {
        HStack(spacing: 8) {
            Button("Autre dossier…", action: sync.chooseFolder).buttonStyle(RegSmallButtonStyle())
            if !sync.usesICloud {
                Button("Revenir à iCloud Drive", action: sync.useICloudDrive).buttonStyle(RegSmallButtonStyle())
            }
        }
        .fixedSize()
    }

    // MARK: Mot de passe

    private var passwordBox: some View {
        RegSyncBox {
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
        }
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
                     ? "Jetons FortiGate, communautés SNMP, mots de passe SSH, Telnet, VNC, FTP, SMB, RustDesk, SMTP, ntfy, Pushover… chiffrés avant de partir, remis au Trousseau de chaque Mac. Le même mot de passe sur chaque Mac."
                     : "Les secrets ne sont pas synchronisés (jamais envoyés en clair)\u{00A0}; le reste l’est.")
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

    // MARK: Mac

    private var devicePanel: some View {
        RegPanel(title: "Mac synchronisés",
                 subtitle: "Ce Mac et ceux vus dans le dossier de synchronisation, avec leur version de NetScope.") {
            RegSyncDeviceTable()
        }
    }

    // MARK: Catégories

    private var categoryPanel: some View {
        RegPanel(title: "Ce qui est synchronisé",
                 subtitle: "Tout est synchronisé par défaut\u{00A0}; décochez une catégorie pour la garder sur ce Mac seulement (ni envoyée, ni reçue).") {
            VStack(alignment: .leading, spacing: 10) {
                RegSyncCategoryTable()
                Text("Propre à chaque Mac, jamais synchronisé\u{00A0}: interface active, fenêtres, onglets et colonnes, captures, journal de l’app, base des fabricants, plages en cours, récepteurs (Syslog, TFTP, NetFlow) et historiques bruts volumineux (signal Wi-Fi seconde par seconde, trafic brut des ports, mesures des disques).")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Sites

    private var sitePanel: some View {
        let sites = siteModel.list.sortedByName
        let count = sites.filter { sync.isSynced($0.id) }.count
        return RegPanel(title: "Sites (\(count) sur \(sites.count))",
                        subtitle: "Fiche, inventaire, notes, derniers résultats, relevé Wi-Fi et FortiGate de chaque site. Un site est reconnu par son identifiant, jamais par ses plages.") {
            VStack(alignment: .leading, spacing: 12) {
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
                if !sync.remoteSites.isEmpty {
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
                                .help("Synchroniser ce site ici aussi (reçu tout de suite)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Changements reçus

    private var recentPanel: some View {
        RegPanel(title: "Changements reçus récents",
                 subtitle: "Appliqués sans redémarrer, dès leur arrivée.") {
            if sync.recent.isEmpty {
                RegNotice("Rien reçu pour l’instant.", tone: .neutral)
            } else {
                RegSyncChangeTable()
            }
        }
    }

    // MARK: Conflits

    private var conflictPanel: some View {
        RegPanel(title: "Conflits (\(sync.conflicts.count))",
                 subtitle: "Le même élément a changé sur deux Mac\u{00A0}: la version la plus récente est gardée, l’autre peut être rétablie.") {
            RegSyncRows(count: sync.conflicts.count) { index in
                let conflict = sync.conflicts[index]
                return HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.warning).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(conflict.label) · \(conflict.siteName)").font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                            .truncationMode(.middle)
                        Text("Gardée\u{00A0}: \(conflict.keptDevice), modifiée \(RegSyncFormat.ago(conflict.keptModified, now: sync.now)) · écartée\u{00A0}: \(conflict.otherDevice), modifiée \(RegSyncFormat.ago(conflict.otherModified, now: sync.now))")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if conflict.otherData != nil {
                                Button("Rétablir l’autre version") { sync.restore(conflict) }
                                    .buttonStyle(RegSmallButtonStyle())
                                    .help("Remettre la version de «\u{00A0}\(conflict.otherDevice)\u{00A0}» tout de suite, puis l’envoyer aux autres Mac")
                            }
                            Button("Garder la version actuelle") { sync.dismiss(conflict) }
                                .buttonStyle(RegSmallButtonStyle())
                                .help("Garder la version actuelle et retirer ce conflit de la liste")
                        }
                        .fixedSize()
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Suppressions

    private var deletionPanel: some View {
        RegPanel(title: "Suppressions venues d’un autre Mac (\(sync.pendingDeletions.count))",
                 subtitle: "Jamais appliquées d’office\u{00A0}: supprimez aussi sur ce Mac, ou gardez l’élément ici.") {
            RegSyncRows(count: sync.pendingDeletions.count) { index in
                let deletion = sync.pendingDeletions[index]
                return HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.critical).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(deletion.label) · \(deletion.scopeName)").font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                            .truncationMode(.middle)
                        Text("Supprimé sur «\u{00A0}\(deletion.device)\u{00A0}» \(RegSyncFormat.ago(deletion.date, now: sync.now))\u{00A0}; toujours présent sur ce Mac.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Button("Supprimer aussi ici", role: .destructive) { sync.confirmDeletion(deletion) }
                                .buttonStyle(RegSmallButtonStyle())
                            Button("Garder sur ce Mac") { sync.keepDeletion(deletion) }
                                .buttonStyle(RegSmallButtonStyle())
                                .help("Garder l’élément ici\u{00A0}; cette suppression ne sera plus signalée")
                        }
                        .fixedSize()
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Encadré atténué (état, dossier, mot de passe).
struct RegSyncBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
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
                Text("Chiffre les secrets (jetons, communautés, mots de passe) avant qu’ils aillent dans le dossier de synchronisation (AES-GCM 256\u{00A0}bits, PBKDF2). Saisissez le même sur chacun de vos Mac\u{00A0}; il est gardé dans le Trousseau de ce Mac seulement.")
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
