import NetScopeCore
import SwiftUI

// Note 38 : feuilles de la sauvegarde chiffrée (Réglages › Export et sauvegarde) — choix du mot
// de passe (avec confirmation et indicateur de force) et restauration d'une sauvegarde chiffrée
// (mot de passe, puis contenu vérifié et secrets à remettre au Trousseau). Le mot de passe ne
// vit que dans l'état de la feuille : jamais écrit, sauf au Trousseau si « Mémoriser » est coché.

/// Mot de passe d'une sauvegarde chiffrée : saisie, confirmation, force, « Mémoriser ».
struct RegBackupPasswordSheet: View {
    @ObservedObject private var backups = RegBackupController.shared
    let request: RegBackupController.PasswordRequest
    /// Dessinée dans la page (captures) plutôt que dans une feuille.
    var inline = false
    var initialPassword = ""
    let dismiss: () -> Void

    @State private var password = ""
    @State private var confirmation = ""
    @State private var remember = false

    private var strength: BackupPasswordStrength { .evaluate(password) }
    private var mismatch: Bool { !confirmation.isEmpty && confirmation != password }
    private var canSubmit: Bool { strength.isAcceptable && confirmation == password }

    private var title: String {
        switch request {
        case .backupNow: return "Chiffrer la sauvegarde"
        case .export: return "Chiffrer la sauvegarde exportée"
        case .define: return "Mot de passe des sauvegardes"
        }
    }

    private var actionLabel: String {
        switch request {
        case .backupNow: return "Chiffrer et sauvegarder"
        case .export: return "Chiffrer et exporter"
        case .define: return "Enregistrer"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            form
            Divider()
            footer
        }
        .frame(width: inline ? nil : 520)
        .frame(maxWidth: inline ? 560 : nil, alignment: .leading)
        .background(Theme.panel)
        .onAppear {
            if password.isEmpty, !initialPassword.isEmpty {
                password = initialPassword
                confirmation = initialPassword
            }
            if request == .define { remember = true }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 17)).foregroundStyle(Theme.accent)
                Text(title).font(Theme.panelTitle).foregroundStyle(Theme.text)
            }
            Text("AES-GCM 256\u{00A0}bits, clé dérivée du mot de passe par PBKDF2-HMAC-SHA256 (\(RegBackupSheetsFormat.iterations) itérations, sel aléatoire). Le mot de passe n’est jamais écrit dans l’archive.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            RegField(label: "Mot de passe") {
                RegTextField(placeholder: "Au moins \(BackupPasswordStrength.minimumLength) caractères (une phrase de passe convient bien)",
                             text: $password, secure: true)
            }
            RegBackupStrengthMeter(strength: strength)
            RegField(label: "Confirmation") {
                RegTextField(placeholder: "Le même mot de passe", text: $confirmation, secure: true, invalid: mismatch)
            }
            if mismatch {
                Text("Les deux mots de passe ne sont pas identiques.").font(Theme.small).foregroundStyle(Theme.critical)
            }
            secretsLine
            if request == .define {
                Text("Le mot de passe sera mémorisé dans le Trousseau de ce Mac, pour la sauvegarde automatique quotidienne chiffrée.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Décochée par défaut : le mot de passe n'est proposé au Trousseau que sur demande.
                Toggle(isOn: $remember) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mémoriser dans le Trousseau").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                        Text("Pour la sauvegarde automatique quotidienne chiffrée. Sinon, le mot de passe est demandé à chaque sauvegarde et n’est gardé nulle part.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }
            RegNotice("Sans ce mot de passe, la sauvegarde est perdue\u{00A0}: NetScope ne peut ni le retrouver ni le réinitialiser. Gardez-le en lieu sûr (gestionnaire de mots de passe).",
                      tone: .warning)
        }
        .padding(20)
    }

    private var secretsLine: some View {
        HStack(spacing: 8) {
            Image(systemName: backups.includeSecrets ? "key.fill" : "key.slash")
                .foregroundStyle(backups.includeSecrets ? Theme.accent : Theme.textTertiary)
            Text(backups.includeSecrets
                 ? "Jetons et secrets inclus\u{00A0}: \(backups.keychainItems.filter { $0.service != BackupPasswordKeychain.service }.count) comptes du Trousseau, dans la partie chiffrée seulement."
                 : "Jetons et secrets non inclus (option «\u{00A0}Inclure les jetons et secrets\u{00A0}»).")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button(actionLabel) {
                let chosen = password
                let keep = remember
                password = ""
                confirmation = ""
                dismiss()
                backups.submitPassword(chosen, remember: keep, for: request)
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
            .regDisabled(!canSubmit)
            .help(canSubmit ? actionLabel : "Saisissez deux fois le même mot de passe, d’au moins \(BackupPasswordStrength.minimumLength) caractères")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Indicateur de force : quatre segments, libellé et conseil.
struct RegBackupStrengthMeter: View {
    let strength: BackupPasswordStrength

    private var filled: Int {
        switch strength.level {
        case .vide: return 0
        case .tropCourt, .faible: return 1
        case .moyen: return 2
        case .bon: return 3
        case .excellent: return 4
        }
    }

    private var tone: Tone {
        switch strength.level {
        case .vide: return .neutral
        case .tropCourt, .faible: return .critical
        case .moyen: return .warning
        case .bon: return .accent
        case .excellent: return .success
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule().fill(index < filled ? tone.dot : Theme.neutralSoft).frame(height: 5)
                    }
                }
                .frame(width: 180)
                Text("Force\u{00A0}: \(strength.level.label.lowercased())").font(Theme.captionSemibold)
                    .foregroundStyle(strength.level == .vide ? Theme.textTertiary : tone.foreground)
            }
            Text(strength.hint).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Force du mot de passe\u{00A0}: \(strength.level.label)")
    }
}

enum RegBackupSheetsFormat {
    /// « 600 000 » (espace insécable fine).
    static var iterations: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: BackupCrypto.defaultIterations)) ?? "600 000"
    }
}

// MARK: - Restauration d'une sauvegarde chiffrée

/// Restauration d'une sauvegarde chiffrée : mot de passe (SecureField), vérification, contenu,
/// secrets à remettre au Trousseau après confirmation, puis « Restaurer et redémarrer ».
struct RegBackupUnlockSheet: View {
    @ObservedObject private var backups = RegBackupController.shared
    let info: BackupInfo
    var inline = false
    /// Captures : contenu déjà déverrouillé.
    var preset: BackupContents?
    let dismiss: () -> Void

    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var contents: BackupContents?
    @State private var restoreSecrets = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            form
            Divider()
            footer
        }
        .frame(width: inline ? nil : 540)
        .frame(maxWidth: inline ? 580 : nil, alignment: .leading)
        .background(Theme.panel)
        .onAppear { if contents == nil, let preset { contents = preset } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.open.rotation").font(.system(size: 17)).foregroundStyle(Theme.accent)
                Text("Restaurer une sauvegarde chiffrée").font(Theme.panelTitle).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RegTileRow {
                RegTile("Date", RegFormat.moment(info.date))
                RegTile("Type", info.manifest.kind.label)
                RegTile("Contenu", info.summary)
                RegTile("Version de NetScope", info.manifest.appVersion, mono: true)
            }
            if let contents {
                unlocked(contents)
            } else {
                passwordBox
            }
            if let error {
                RegNotice(error, tone: .critical)
            }
        }
        .padding(20)
    }

    private var passwordBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            RegField(label: "Mot de passe de la sauvegarde") {
                HStack(spacing: 8) {
                    SecureField("", text: $password, prompt: Text("Mot de passe choisi à la création").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(unlock)
                    Button(action: unlock) {
                        if working {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Vérification…") }
                        } else {
                            Label("Déverrouiller", systemImage: "key")
                        }
                    }
                    .buttonStyle(.secondary)
                    .regDisabled(password.isEmpty || working)
                }
            }
            Text("Rien n’est restauré tant que le mot de passe et l’intégrité de toute l’archive ne sont pas vérifiés.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func unlocked(_ contents: BackupContents) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RegNotice("Mot de passe correct, intégrité vérifiée\u{00A0}: \(contents.files.count) fichier\(contents.files.count > 1 ? "s" : "") prêts à restaurer.",
                      tone: .success)
            if !contents.secrets.isEmpty {
                Toggle(isOn: $restoreSecrets) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remettre les \(contents.secrets.count) secrets au Trousseau de ce Mac").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                        Text("Les valeurs actuelles des mêmes comptes sont remplacées. Décochez pour garder les secrets de ce Mac.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                if inline || contents.secrets.count <= 6 {
                    secretList(contents.secrets)
                } else {
                    ScrollView { secretList(contents.secrets) }.frame(maxHeight: 190)
                }
            } else {
                Text("Cette sauvegarde ne contient aucun secret du Trousseau\u{00A0}: ressaisissez-les au besoin après la restauration.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("L’état actuel sera d’abord gardé dans une sauvegarde de sécurité, puis NetScope redémarrera pour appliquer la restauration.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func secretList(_ secrets: [BackupSecret]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(secrets.enumerated()), id: \.offset) { index, secret in
                HStack(spacing: 8) {
                    Image(systemName: "key").font(.system(size: 11)).foregroundStyle(restoreSecrets ? Theme.accent : Theme.textTertiary)
                    Text(secret.usage).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(secret.service.replacingOccurrences(of: BackupKeychainScan.servicePrefix + ".", with: ""))
                        .font(Theme.mono(11)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .opacity(restoreSecrets ? 1 : 0.6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            Text(info.url.lastPathComponent).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Annuler", action: close).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button("Restaurer et redémarrer") {
                guard let contents else { return }
                let secrets = restoreSecrets
                close()
                backups.restoreEncrypted(info, contents: contents, restoreSecrets: secrets)
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
            .regDisabled(contents == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func unlock() {
        guard !password.isEmpty, !working else { return }
        working = true
        error = nil
        let typed = password
        Task {
            let result = await backups.unlock(info, password: typed)
            working = false
            switch result {
            case .success(let opened):
                password = ""
                contents = opened
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    private func close() {
        password = ""
        contents = nil
        dismiss()
    }
}
