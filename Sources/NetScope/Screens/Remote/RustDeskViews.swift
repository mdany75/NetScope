import AppKit
import NetScopeCore
import SwiftUI

// Note 6 : vues RustDesk de l'écran Accès distant (détail du poste, accueil, formulaire).

/// Bloc « RustDesk » du panneau de détails : ID groupé, copies, client de ce Mac, lancements.
struct RustDeskDetailSection: View {
    @ObservedObject var model: RemoteModel
    let connection: RemoteConnection
    @ObservedObject private var rustdesk = RustDeskModel.shared
    @State private var copied: String?

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "RustDesk") {
                    if rustdesk.isInstalled {
                        Chip(text: "Client installé", tone: .success)
                    } else {
                        Chip(text: "Client absent", tone: .warning)
                    }
                }
                if let target = connection.rustDeskTarget {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.isDirect ? "ADRESSE IP DIRECTE" : "ID RUSTDESK")
                            .font(Theme.captionSemibold).kerning(0.4).foregroundStyle(Theme.textSecondary)
                        Text(target.isDirect ? target.remoteID : RustDeskID.grouped(target.hostValue))
                            .font(Theme.mono(20, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 6) {
                        Button {
                            rustdesk.copy(target.remoteID)
                            flash(target.isDirect ? "Adresse copiée" : "ID copié")
                        } label: {
                            Label(target.isDirect ? "Copier l’adresse" : "Copier l’ID", systemImage: "doc.on.doc").labelStyle(RemoteCompactLabelStyle())
                        }
                        .buttonStyle(RemoteSmallButtonStyle())
                        Button {
                            if let message = rustdesk.supportMessage {
                                rustdesk.copy(message)
                                flash("Lien d’assistance copié")
                            } else {
                                model.toast = "Aucun lien d’assistance\u{00A0}: indiquez la page de l’usager dans Réglages › RustDesk."
                            }
                        } label: {
                            Label("Lien pour l’usager", systemImage: "link").labelStyle(RemoteCompactLabelStyle())
                        }
                        .buttonStyle(RemoteSmallButtonStyle())
                        .help("Copier le lien d’assistance pour l’usager (page du client portable préconfiguré)")
                    }
                    if let copied {
                        Label(copied, systemImage: "checkmark").font(Theme.caption).foregroundStyle(Theme.success)
                    }
                }
                if !rustdesk.isInstalled {
                    RustDeskDownloadBanner()
                }
                let launches = rustdesk.launches(of: connection.id)
                VStack(alignment: .leading, spacing: 4) {
                    SpeedFieldLabel("Lancements depuis NetScope")
                    if launches.isEmpty {
                        Text("Aucun pour l’instant.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(launches.prefix(5)) { launch in
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            Text(RemoteFormat.relative(launch.date)).font(Theme.small)
                            Spacer(minLength: 4)
                            Text("durée inconnue").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Text("RustDesk ne prévient pas NetScope de la fin d’une session\u{00A0}: seule l’heure de lancement est notée.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
    }

    private func flash(_ text: String) {
        copied = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copied == text { copied = nil }
        }
    }
}

/// Encadré « RustDesk n'est pas installé » avec le lien de téléchargement.
struct RustDeskDownloadBanner: View {
    @ObservedObject private var rustdesk = RustDeskModel.shared

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.warning)
            Text("RustDesk n’est pas installé sur ce Mac (com.carriez.rustdesk).")
                .font(Theme.small).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Télécharger RustDesk") { rustdesk.openDownloadPage() }
                .buttonStyle(RemoteSmallButtonStyle())
                .help(RustDeskLink.downloadURL.absoluteString)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.warningSoft))
    }
}

/// Accueil : « Nouvelle connexion RustDesk » en collant un ID, et les derniers lancements.
struct RustDeskQuickBox: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: RemoteModel
    @ObservedObject private var rustdesk = RustDeskModel.shared
    @State private var text = ""
    @State private var saveToBook = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Assistance RustDesk") {
                Button {
                    RegNavigation.shared.section = .rustdesk
                    state.open(.reglages)
                } label: {
                    Label("Réglages du serveur", systemImage: "gearshape").labelStyle(RemoteCompactLabelStyle())
                }
                .buttonStyle(.ghost)
                .help("Serveur d’ID, clé publique et page d’assistance de l’usager")
            }
            HStack(spacing: 6) {
                Image(systemName: RemoteProtocol.rustdesk.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RemoteProtocol.rustdesk.tint)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(RemoteProtocol.rustdesk.soft))
                TextField("", text: $text, prompt: Text("ID donné par l’usager · 123 456 789").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(error == nil ? Theme.border : Theme.critical))
                    .onSubmit(connect)
                    .onChange(of: text) { _, _ in error = nil }
                Button(action: connect) {
                    Label("Connecter", systemImage: "play.fill").labelStyle(RemoteCompactLabelStyle())
                }
                .buttonStyle(RemoteSmallButtonStyle(primary: true))
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 10) {
                Toggle("Ajouter au carnet", isOn: $saveToBook).toggleStyle(.checkbox).font(Theme.small)
                if let error {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.critical).lineLimit(2)
                } else {
                    Text("Espaces acceptés\u{00A0}; une IPv4 ouvre l’accès IP direct (21118).")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            if !rustdesk.history.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rustdesk.history.prefix(4)) { launch in
                        historyRow(launch)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
            }
        }
    }

    private func connect() {
        error = model.quickRustDesk(text, saveToBook: saveToBook)
        if error == nil { text = "" }
    }

    private func historyRow(_ launch: RustDeskLaunch) -> some View {
        HStack(spacing: 8) {
            Text(RemoteFormat.relative(launch.date)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                .frame(width: 118, alignment: .leading)
            Text(launch.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(launch.targetLabel).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            if !launch.endUser.isEmpty {
                Text("· \(launch.endUser)").font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                if let id = launch.connectionID, let connection = model.connections.first(where: { $0.id == id }) {
                    model.connectRustDesk(connection)
                } else if let target = try? RustDeskTarget.parse(launch.target) {
                    model.toast = rustdesk.launch(target, name: launch.name)
                }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.ghost)
            .help("Relancer RustDesk sur ce poste")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// Mot de passe permanent RustDesk (facultatif, au Trousseau seulement).
struct RustDeskPasswordField: View {
    @Binding var draft: RemoteDraft
    @ObservedObject private var rustdesk = RustDeskModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mot de passe permanent (facultatif)").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            RemoteSecureInput(placeholder: placeholder, text: Binding(get: { draft.password ?? "" }, set: { draft.password = $0 }))
            Text("Au Trousseau macOS seulement, remis à RustDesk à l’ouverture. Vide\u{00A0}: RustDesk demande le mot de passe à usage unique de l’usager.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var placeholder: String {
        if let id = draft.editingID, rustdesk.hasPassword(id), draft.password == nil { return "Enregistré au Trousseau (inchangé)" }
        return "Aucun"
    }
}

extension View {
    /// Note 6 : « RustDesk n'est pas installé » au moment de « Connecter ».
    func rustDeskInstallAlert() -> some View {
        modifier(RustDeskInstallAlert())
    }
}

private struct RustDeskInstallAlert: ViewModifier {
    @ObservedObject private var rustdesk = RustDeskModel.shared

    func body(content: Content) -> some View {
        content.alert("RustDesk n’est pas installé sur ce Mac", isPresented: $rustdesk.needsInstall) {
            Button("Télécharger RustDesk") { rustdesk.openDownloadPage() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("NetScope ouvre les connexions RustDesk dans le client de bureau. Installez RustDesk pour macOS (fichier .dmg de la dernière version), puis réglez son serveur d’ID et sa clé (Réglages › RustDesk de NetScope montre les valeurs).")
        }
    }
}
