import AppKit
import NetScopeCore
import SwiftUI

/// Réglages › Export et sauvegarde (croquis : section « EXPORT ET SAUVEGARDE ») : format d'export
/// par défaut, dossier et rotation des sauvegardes, sauvegarde automatique, liste avec restauration.
/// Note 38 : chiffrement par mot de passe, jetons et secrets en option, colonne « Chiffrée ».
struct RegBackupSection: View {
    @ObservedObject private var prefs = RegPrefs.shared
    @ObservedObject private var backups = RegBackupController.shared
    @StateObject private var table = RegBackupTable.makeModel()
    @State private var selection: BackupInfo.ID?
    @State private var restoring: BackupInfo?
    /// Sauvegarde chiffrée à restaurer : feuille du mot de passe.
    @State private var unlocking: BackupInfo?
    /// Nombre gardé choisi qui retirerait des sauvegardes : en attente de confirmation.
    @State private var pendingKeep: Int?

    var body: some View {
        RegPanel(title: "Export et sauvegarde",
                 subtitle: "Format des exports de résultats et sauvegarde des réglages, sites, profils, inventaire et historiques.") {
            VStack(alignment: .leading, spacing: 0) {
                snapshotSheet
                formatRow
                folderBox.padding(.top, 14)
                VStack(spacing: 0) {
                    RegToggleRow(title: "Sauvegarde automatique quotidienne",
                                 detail: "Réglages, sites et plages, profils de scan, inventaire, historiques de Surveillance, services en ligne et disques.",
                                 isOn: $backups.automatic)
                    RegToggleRow(title: "Copier aussi dans iCloud Drive",
                                 detail: RegBackupController.iCloudFolder == nil && !RegEnvironment.isDemo
                                     ? "iCloud Drive n’est pas activé sur ce Mac."
                                     : "Pour retrouver la configuration sur un autre Mac (dossier NetScope › Sauvegardes d’iCloud Drive).",
                                 isOn: $backups.copyToICloud)
                        .regDisabled(RegBackupController.iCloudFolder == nil && !RegEnvironment.isDemo)
                    encryptionRows
                }
                .padding(.top, 12)
                listHeader.padding(.top, 14)
                if backups.backups.isEmpty {
                    RegNotice("Aucune sauvegarde dans ce dossier pour l’instant.", tone: .neutral)
                        .padding(.top, 8)
                } else {
                    RegBackupTable(rows: backups.backups, table: table, selection: $selection, onRestore: askRestore)
                        .regTableFrame()
                        .padding(.top, 8)
                }
                if let message = backups.message {
                    RegNotice(message.text, tone: message.tone).padding(.top, 10)
                }
                footer.padding(.top, 12)
            }
        }
        .onAppear {
            backups.refresh()
            backups.takeRestoreReport()
        }
        .confirmationDialog(keepTitle, isPresented: Binding(get: { pendingKeep != nil }, set: { if !$0 { pendingKeep = nil } }),
                            titleVisibility: .visible) {
            Button("Placer dans la corbeille", role: .destructive) {
                if let value = pendingKeep { backups.applyKeep(value) }
                pendingKeep = nil
            }
            Button("Annuler", role: .cancel) { pendingKeep = nil }
        } message: {
            Text("Les sauvegardes les plus anciennes iront dans la corbeille, d’où vous pourrez les récupérer.")
        }
        .sheet(item: $backups.passwordRequest) { request in
            RegBackupPasswordSheet(request: request) { backups.passwordRequest = nil }
        }
        .sheet(item: $unlocking) { info in
            RegBackupUnlockSheet(info: info) { unlocking = nil }
        }
        .alert(item: $restoring) { info in
            Alert(title: Text("Restaurer la sauvegarde du \(RegFormat.moment(info.date))\u{00A0}?"),
                  message: Text(restoreMessage(info)),
                  primaryButton: .destructive(Text("Restaurer et redémarrer")) { backups.restore(info) },
                  secondaryButton: .cancel(Text("Annuler")))
        }
    }

    /// Restauration : feuille du mot de passe pour une sauvegarde chiffrée, confirmation sinon.
    private func askRestore(_ info: BackupInfo) {
        if info.isEncrypted { unlocking = info } else { restoring = info }
    }

    // MARK: Chiffrement (note 38)

    /// Captures : NETSCOPE_SAUVEGARDE_FEUILLE=chiffrer|restaurer dessine la feuille en haut de la page.
    @ViewBuilder private var snapshotSheet: some View {
        switch ReglagesDemo.snapshotSheet {
        case "chiffrer":
            RegBackupPasswordSheet(request: .backupNow, inline: true, initialPassword: "Lune7-Fenetre-Rouge", dismiss: {})
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                .padding(.bottom, 14)
        case "restaurer":
            if let info = backups.backups.first(where: \.isEncrypted) {
                RegBackupUnlockSheet(info: info, inline: true, preset: ReglagesDemo.unlockedContents(info), dismiss: {})
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                    .padding(.bottom, 14)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var encryptionRows: some View {
        RegToggleRow(title: "Chiffrer par mot de passe",
                     detail: "Archive .netscope-backup chiffrée en AES-GCM 256\u{00A0}bits, clé dérivée du mot de passe (PBKDF2, \(RegBackupSheetsFormat.iterations) itérations). Sans ce mot de passe, la sauvegarde est perdue.",
                     isOn: $backups.encrypt)
        if backups.encrypt {
            RegToggleRow(title: "Inclure les jetons et secrets (pour un autre Mac)",
                         detail: "Jetons FortiGate, communautés SNMP, identifiants SSH et WMI, mot de passe SMTP, webhooks, secret Graph\u{00A0}: lus au Trousseau, rangés uniquement dans la partie chiffrée et remis au Trousseau à la restauration, après confirmation.",
                         isOn: $backups.includeSecrets)
            passwordBox.padding(.bottom, 4)
        }
    }

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
            Image(systemName: backups.hasStoredPassword ? "lock.fill" : "lock.open")
                .font(.system(size: 15)).foregroundStyle(backups.hasStoredPassword ? Theme.success : Theme.warning)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(backups.hasStoredPassword ? "Mot de passe mémorisé dans le Trousseau" : "Aucun mot de passe mémorisé")
                    .font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(backups.hasStoredPassword
                     ? "La sauvegarde automatique quotidienne est chiffrée\(backups.includeSecrets ? ", avec les jetons et secrets" : ""). Le mot de passe n’est écrit nulle part ailleurs."
                     : "«\u{00A0}Sauvegarder maintenant\u{00A0}» demandera le mot de passe à chaque fois\u{00A0}; la sauvegarde automatique reste non chiffrée, sans secret.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var passwordButtons: some View {
        HStack(spacing: 8) {
            Button(backups.hasStoredPassword ? "Changer…" : "Définir…") { backups.passwordRequest = .define }
                .buttonStyle(RegSmallButtonStyle())
                .help("Choisir le mot de passe des sauvegardes chiffrées et le mémoriser dans le Trousseau")
            if backups.hasStoredPassword {
                Button("Oublier", action: backups.forgetPassword)
                    .buttonStyle(RegSmallButtonStyle())
                    .help("Retirer le mot de passe du Trousseau (les sauvegardes déjà chiffrées le demanderont)")
            }
        }
        .fixedSize()
    }

    private func restoreMessage(_ info: BackupInfo) -> String {
        var text = "Contenu\u{00A0}: \(info.manifest.summary). L’état actuel sera d’abord gardé dans une sauvegarde de sécurité, puis NetScope redémarrera pour appliquer la restauration."
        if !info.manifest.keychain.isEmpty {
            text += " Les secrets du Trousseau ne sont jamais sauvegardés\u{00A0}; sur un autre Mac, ressaisissez\u{00A0}: "
                + info.manifest.keychain.map(\.usage).joined(separator: ", ") + "."
        }
        return text
    }

    // MARK: Format d'export et rotation

    private var formatRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                formatPicker
                Spacer(minLength: 8)
                retention
            }
            VStack(alignment: .leading, spacing: 12) {
                formatPicker
                retention
            }
        }
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            RegLabel("Format d’export par défaut")
            RegSegmented(selection: $prefs.exportFormat,
                         options: ExportFormat.allCases.map { .init(value: $0, label: $0.label) })
            Text(prefs.exportFormat.detail + " Utilisé par le bouton « Exporter » du Scanner.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)
        }
    }

    /// Choix du nombre gardé : confirmation s'il retirerait des sauvegardes existantes.
    private var keepBinding: Binding<Int> {
        Binding(get: { backups.keep }, set: { value in
            if backups.excessCount(keep: value) > 0 { pendingKeep = value } else { backups.keep = value }
        })
    }

    private var keepTitle: String {
        let n = pendingKeep.map { backups.excessCount(keep: $0) } ?? 0
        return "\(n)\u{00A0}sauvegarde\(n > 1 ? "s" : "") ser\(n > 1 ? "ont placées" : "a placée") dans la corbeille"
    }

    private var retention: some View {
        HStack(alignment: .top, spacing: 14) {
            RegField(label: "Conserver") {
                Picker("", selection: keepBinding) {
                    ForEach(RegBackupController.keepChoices, id: \.self) { count in
                        Text(count == 0 ? "Toutes les sauvegardes" : "\(count) dernières").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            RegField(label: "Forme") {
                Picker("", selection: $backups.format) {
                    ForEach(BackupFormat.selectable, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                .regDisabled(backups.encrypt)
                .help(backups.encrypt ? "Une sauvegarde chiffrée est toujours une archive .netscope-backup" : "Archive .zip ou dossier daté")
            }
        }
        .fixedSize()
    }

    // MARK: Dossier

    private var lastText: String {
        guard let last = backups.lastBackup else { return "Dernière sauvegarde\u{00A0}: jamais" }
        return "Dernière sauvegarde\u{00A0}: \(RegFormat.moment(last))"
    }

    private var folderBox: some View {
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
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var folderInfo: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 17)).foregroundStyle(Theme.neutralText)
            VStack(alignment: .leading, spacing: 2) {
                Text(backups.folderLabel).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(lastText + (backups.automatic ? " · automatique chaque jour" : " · automatique désactivée"))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .fixedSize()
        }
    }

    private var folderButtons: some View {
        HStack(spacing: 8) {
            Button("Choisir…", action: backups.chooseFolder).buttonStyle(.secondary)
                .help("Choisir le dossier des sauvegardes")
            Button(action: backups.backupNow) {
                if backups.isWorking {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sauvegarde…") }
                } else {
                    Label("Sauvegarder maintenant", systemImage: "tray.and.arrow.down")
                }
            }
            .buttonStyle(.primary)
            .regDisabled(backups.isWorking)
        }
        .fixedSize()
    }

    // MARK: Liste

    private var selected: BackupInfo? { backups.backups.first { $0.id == selection } }

    private var listHeader: some View {
        HStack(spacing: 8) {
            RegLabel("Sauvegardes (\(backups.backups.count))")
            Spacer()
            StandardColumnsMenu(model: table, compact: true)
            Button("Afficher dans le Finder") { backups.revealInFinder(selected) }
                .buttonStyle(RegSmallButtonStyle())
            Button {
                if let selected { askRestore(selected) }
            } label: { Label("Restaurer…", systemImage: "clock.arrow.circlepath") }
                .buttonStyle(RegSmallButtonStyle())
                .regDisabled(selected == nil)
                .help(selected == nil ? "Choisissez une sauvegarde dans la liste" : "Restaurer la sauvegarde choisie")
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            footerButtons
            secretsNote.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var footerButtons: some View {
        HStack(spacing: 8) {
            Button(action: backups.exportAs) { Label("Exporter une sauvegarde…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
            Button {
                if let info = backups.pickArchiveToRestore() { askRestore(info) }
            } label: { Label("Restaurer depuis un fichier…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
        }
        .fixedSize()
    }

    private var secretsNote: some View {
        let count = backups.keychainItems.count
        let text = backups.encrypt && backups.includeSecrets
            ? "Secrets du Trousseau (\(count) compte\(count > 1 ? "s" : ""))\u{00A0}: dans la partie chiffrée des sauvegardes chiffrées seulement, jamais dans une sauvegarde non chiffrée."
            : "Les secrets du Trousseau ne sont jamais copiés\u{00A0}: le manifeste nomme seulement \(count) compte\(count > 1 ? "s" : "") à ressaisir."
        return Text(text)
            .font(Theme.small).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(backups.keychainItems.map { "\($0.usage) (\($0.account))" }.joined(separator: "\n"))
    }
}

// MARK: - Tableau des sauvegardes (tableau standard « reglages.sauvegardes »)

struct RegBackupTable: View {
    let rows: [BackupInfo]
    @ObservedObject var table: StandardTableModel<BackupInfo>
    @Binding var selection: BackupInfo.ID?
    let onRestore: (BackupInfo) -> Void

    static let columns: [StandardColumn] = [
        StandardColumn(id: "date", title: "Date", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "taille", title: "Taille"),
        StandardColumn(id: "contenu", title: "Contenu"),
        StandardColumn(id: "forme", title: "Forme"),
        StandardColumn(id: "chiffree", title: "Chiffrée"),
        StandardColumn(id: "version", title: "Version de NetScope", isDefaultVisible: false),
        StandardColumn(id: "fichier", title: "Fichier", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<BackupInfo>] = [
        "date": KeyPathComparator(\BackupInfo.date),
        "type": KeyPathComparator(\BackupInfo.kindLabel),
        "taille": KeyPathComparator(\BackupInfo.bytes),
        "contenu": KeyPathComparator(\BackupInfo.fileCount),
        "forme": KeyPathComparator(\BackupInfo.formatLabel),
        "chiffree": KeyPathComparator(\BackupInfo.encryptionRank),
        "version": KeyPathComparator(\BackupInfo.versionLabel),
        "fichier": KeyPathComparator(\BackupInfo.fileName),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<BackupInfo> {
        StandardTableModel(id: "reglages.sauvegardes", columns: columns, sortKeys: sortKeys, defaultSort: "date", defaultAscending: false)
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("DATE", sortUsing: table.sort("date")) { row in
                Text(RegFormat.moment(row.date)).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(height: RegSwitchTableMetrics.rowHeight - 8)
            }
            .width(min: 120, ideal: 150)
            .customizationID("date")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                Chip(text: row.kindLabel, tone: row.manifest.kind == .securite ? .warning : (row.manifest.kind == .manuelle ? .accent : .neutral))
                    .help(row.manifest.kind == .securite ? "Faite juste avant une restauration (état d’avant)" : row.kindLabel)
            }
            .width(min: 80, ideal: 100)
            .customizationID("type")

            TableColumn("TAILLE", sortUsing: table.sort("taille")) { row in
                Text(RegBackupTable.size(row.bytes)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
            .width(min: 60, ideal: 80)
            .customizationID("taille")

            TableColumn("CONTENU", sortUsing: table.sort("contenu")) { row in
                Text(row.contentSummary).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                    .help(row.isEncrypted ? "Contenu chiffré\u{00A0}: le détail s’affiche après le mot de passe" : row.manifest.contentLabel)
            }
            .width(min: 120, ideal: 170)
            .customizationID("contenu")

            TableColumn("FORME", sortUsing: table.sort("forme")) { row in
                Text(row.formatLabel).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
            .customizationID("forme")

            TableColumn("CHIFFRÉE", sortUsing: table.sort("chiffree")) { row in
                if row.isEncrypted {
                    Chip(text: row.includesSecrets ? "Oui · \(row.secretCount)\u{00A0}secret\(row.secretCount > 1 ? "s" : "")" : "Oui", tone: .success, systemImage: "lock.fill")
                        .help(row.includesSecrets ? "Chiffrée par mot de passe, avec les jetons et secrets du Trousseau" : "Chiffrée par mot de passe, sans secret")
                } else {
                    Text("Non").font(Theme.small).foregroundStyle(Theme.textTertiary)
                        .help("Non chiffrée\u{00A0}: aucun secret du Trousseau")
                }
            }
            .width(min: 70, ideal: 100)
            .customizationID("chiffree")

            TableColumn("VERSION", sortUsing: table.sort("version")) { row in
                Text(row.versionLabel).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
            .width(min: 60, ideal: 80)
            .customizationID("version")
            .defaultVisibility(.hidden)

            TableColumn("FICHIER", sortUsing: table.sort("fichier")) { row in
                Text(row.fileName).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 120, ideal: 260)
            .customizationID("fichier")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: BackupInfo.ID.self) { ids in
            if let info = rows.first(where: { ids.contains($0.id) }) {
                Button(info.isEncrypted ? "Restaurer (mot de passe)…" : "Restaurer…") { onRestore(info) }
                Button("Afficher dans le Finder") { RegBackupController.shared.revealInFinder(info) }
                Divider()
                Button("Placer dans la corbeille", role: .destructive) { RegBackupController.shared.delete(info) }
            }
        } primaryAction: { ids in
            if let info = rows.first(where: { ids.contains($0.id) }) { onRestore(info) }
        }
        .frame(height: RegSwitchTableMetrics.height(rows: min(rows.count, 8)))
    }

    /// « 245 ko », « 1,2 Mo ».
    static func size(_ bytes: Int64) -> String {
        if bytes < 1_000_000 { return "\(max(1, Int((Double(bytes) / 1000).rounded())))\u{00A0}ko" }
        return RegFormat.megabytes(bytes)
    }
}

extension BackupInfo {
    var kindLabel: String { manifest.kind.label }
    var fileCount: Int { manifest.files.count }
    var formatLabel: String {
        switch format {
        case .zip: return "Archive .zip"
        case .dossier: return "Dossier"
        case .chiffree: return "Archive chiffrée"
        }
    }
    /// Tri de la colonne « Chiffrée » : non chiffrée, chiffrée, chiffrée avec secrets.
    var encryptionRank: Int { isEncrypted ? (includesSecrets ? 2 : 1) : 0 }
    var secretCount: Int { encryption?.secretCount ?? 0 }
    /// Contenu sans les secrets (comptés dans la colonne « Chiffrée »).
    var contentSummary: String {
        guard let encryption else { return manifest.summary }
        let files = encryption.fileCount, prefs = encryption.preferenceCount
        return "\(files) fichier\(files > 1 ? "s" : "") · \(prefs) préférence\(prefs > 1 ? "s" : "")"
    }
    var versionLabel: String { manifest.appVersion }
    var fileName: String { url.lastPathComponent }
}
