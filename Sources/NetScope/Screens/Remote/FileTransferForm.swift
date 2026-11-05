import NetScopeCore
import SwiftUI

// Note 50 : réglages FTP, FTPS et SFTP du formulaire de connexion (Accès distant).

enum FileTransferTexts {
    static let ftpWarning = "FTP n’est pas chiffré\u{00A0}: l’utilisateur, le mot de passe et les fichiers circulent en clair sur le réseau. Préférez SFTP ou FTPS si l’appareil le permet, et réservez FTP au réseau local."
    static let keychainNote = "Le mot de passe va au Trousseau macOS (service com.danymenard.netscope.ftp)\u{00A0}; il n’est jamais écrit dans le carnet ni dans une sauvegarde en clair."
}

/// Section « Transfert de fichiers » du formulaire : mode, TLS, identification SFTP, mot de passe, dossier.
struct FileTransferFormSection: View {
    @Binding var draft: RemoteDraft
    @ObservedObject private var files = FileTransferStore.shared

    var body: some View {
        let proto = draft.proto
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Transfert de fichiers")
            if proto == .ftp || proto == .ftps {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        label("Connexion de données")
                        RemoteSegmented(options: FTPDataMode.allCases.map { ($0, $0.label) }, selection: $draft.transfer.dataMode)
                    }
                    if proto == .ftps {
                        VStack(alignment: .leading, spacing: 4) {
                            label("Chiffrement")
                            RemoteSegmented(options: FTPSMode.allCases.map { ($0, $0.label) },
                                            selection: Binding(get: { draft.transfer.tlsMode }, set: { mode in
                                                // Le port suit le mode s'il était celui par défaut.
                                                if draft.port == String(draft.transfer.tlsMode.defaultPort) { draft.port = String(mode.defaultPort) }
                                                draft.transfer.tlsMode = mode
                                            }))
                        }
                    }
                }
                Text(dataModeHelp).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if proto == .ftps, draft.transfer.dataMode == .active {
                    SpeedBanner(text: "Le mode actif n’est pas proposé en FTPS\u{00A0}: NetScope utilisera le mode passif.", tone: .neutral, systemImage: "info.circle")
                }
            }
            if proto == .sftp {
                VStack(alignment: .leading, spacing: 4) {
                    label("Identification")
                    RemoteSegmented(options: SFTPAuth.allCases.map { ($0, $0.label) }, selection: $draft.transfer.sftpAuth)
                }
                if draft.transfer.sftpAuth == .key {
                    VStack(alignment: .leading, spacing: 4) {
                        label("Clé privée")
                        HStack(spacing: 4) {
                            RemoteInput(placeholder: "~/.ssh/id_ed25519", text: $draft.transfer.keyPath)
                            Menu {
                                ForEach(FileTransferKeys.known(), id: \.self) { path in
                                    Button(path) { draft.transfer.keyPath = path }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 26, height: 32)
                            .help("Clés de ~/.ssh et des identifiants SSH des Réglages")
                        }
                    }
                }
            }
            if !(proto == .sftp && draft.transfer.sftpAuth == .agent) {
                VStack(alignment: .leading, spacing: 4) {
                    label(proto == .sftp && draft.transfer.sftpAuth == .key ? "Phrase secrète de la clé (facultative)" : "Mot de passe")
                    RemoteSecureInput(placeholder: passwordPlaceholder,
                                      text: Binding(get: { draft.password ?? "" }, set: { draft.password = $0 }))
                    Text(FileTransferTexts.keychainNote).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                label("Dossier distant à l’ouverture")
                RemoteInput(placeholder: "Dossier d’accueil", text: $draft.transfer.remoteDirectory)
            }
            if proto == .ftp {
                SpeedBanner(text: FileTransferTexts.ftpWarning)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private var dataModeHelp: String {
        draft.transfer.dataMode == .passive
            ? "Passif\u{00A0}: le Mac ouvre la connexion de données (EPSV, sinon PASV)\u{00A0}; passe les pare-feu et le NAT."
            : "Actif\u{00A0}: le serveur se connecte au Mac (EPRT, sinon PORT)\u{00A0}; pour les vieux appareils, souvent bloqué par le pare-feu du Mac."
    }

    private var passwordPlaceholder: String {
        if let id = draft.editingID, files.hasPassword(id), draft.password == nil { return "Enregistré au Trousseau (inchangé)" }
        if draft.proto != .sftp, draft.username.trimmingCharacters(in: .whitespaces).isEmpty { return "Aucun (connexion anonyme)" }
        return "Demandé à la connexion si vide"
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
    }
}

/// Champ de mot de passe au style du formulaire (32 pt).
struct RemoteSecureInput: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
            .textFieldStyle(.plain)
            .font(Theme.body)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Clés SSH proposées : celles des identifiants SSH des Réglages et les clés privées de ~/.ssh.
@MainActor
enum FileTransferKeys {
    static func known() -> [String] {
        var keys = RegRemoteCredentialStore.shared.credentials
            .filter { $0.kind == .ssh && $0.sshMethod == .key && !$0.keyPath.isEmpty }
            .map(\.keyPath)
        if RegEnvironment.isSandboxed {
            keys += ["~/.ssh/id_ed25519", "~/.ssh/id_rsa"]
        } else {
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            keys += names.filter { $0.hasPrefix("id_") && !$0.hasSuffix(".pub") }.sorted().map { "~/.ssh/" + $0 }
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }
}

/// Rappel d'une session de fichiers ouverte pour une autre connexion (transferts en arrière-plan).
struct FileTransferBackgroundBanner: View {
    @ObservedObject var session: FileTransferSession
    @ObservedObject var model: RemoteModel

    var body: some View {
        HStack(spacing: 10) {
            RemoteProtoIcon(proto: session.connection.proto, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Session de fichiers ouverte\u{00A0}: \(session.connection.name)").font(.system(size: 12, weight: .semibold))
                Text(summary).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Revenir") {
                model.selectedID = session.connection.id
                session.isVisible = true
            }
            .buttonStyle(RemoteSmallButtonStyle())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
    }

    private var summary: String {
        let active = session.activeCount
        guard active > 0 else { return "Aucun transfert en cours." }
        return "\(active) transfert\(active > 1 ? "s" : "") en cours ou en attente · \(FileTransferFormat.rate(session.totalRate))"
    }
}
