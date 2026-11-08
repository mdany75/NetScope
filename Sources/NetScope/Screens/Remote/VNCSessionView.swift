import AppKit
import NetScopeCore
import SwiftUI

/// Contenu d'un onglet de session VNC intégrée (croquis docs/croquis/Remote.dc.html, bloc « VNC ») :
/// barre de réglages (qualité, mise à l'échelle, observation seule, presse-papiers, plein écran),
/// titre de la session, bureau distant, puis ligne d'état. L'onglet « Sessions » de la barre ramène
/// l'accueil ; la session continue pendant ce temps.
struct VNCSessionView: View {
    @ObservedObject var session: VNCSession

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            titleRow
            canvas
                .padding(.horizontal, 12)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: En-tête (même forme que les onglets de terminal)

    private var header: some View {
        HStack(spacing: 8) {
            RemoteProtoIcon(proto: .vnc, size: 22)
            Text("VNC intégré").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Chip(text: session.phaseLabel.text, tone: session.phaseLabel.tone)
            Spacer(minLength: 6)
            Button {
                session.sendCtrlAltDelete()
            } label: {
                Label("Ctrl-Alt-Suppr", systemImage: "command").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .speedDisabled(session.phase != .connected || session.viewOnly)
            .help("Envoie Ctrl-Alt-Suppr à l’ordinateur distant (ouverture de session Windows)")
            Button {
                VNCFullScreenController.shared.present(session)
            } label: {
                Label("Plein écran", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .speedDisabled(session.phase != .connected)
            .help("Ouvre la session en plein écran (sortie\u{00A0}: Ctrl-Commande-F ou le bouton du haut)")
            Menu {
                Button("Actualiser l’image") { session.refresh() }
                    .disabled(session.phase != .connected)
                Button("Oublier le mot de passe enregistré") { session.forgetPassword() }
                    .disabled(!session.hasSavedPassword)
                Divider()
                Button("Ouvrir dans Partage d’écran") { RemoteModel.shared.connect(session.connection, external: true) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Autres actions de la session")
            if session.phase == .connected || session.phase == .connecting {
                Button {
                    session.disconnect()
                } label: {
                    Label("Déconnecter", systemImage: "xmark.circle").labelStyle(RemoteCompactLabelStyle())
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
            } else {
                Button {
                    session.reconnect()
                } label: {
                    Label("Reconnecter", systemImage: "arrow.triangle.2.circlepath").labelStyle(RemoteCompactLabelStyle())
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: Réglages (croquis)

    private var controls: some View {
        FlowLayout(spacing: 12, lineSpacing: 8) {
            HStack(spacing: 6) {
                Text("Qualité").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Picker("Qualité", selection: $session.quality) {
                    ForEach(RFBQuality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Adaptative : 16 bits quand le lien ralentit, 32 bits sinon. Haute : toujours 32 bits, sans perte.")
            }
            HStack(spacing: 6) {
                Text("Mise à l’échelle").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Picker("Mise à l’échelle", selection: $session.scale) {
                    ForEach(VNCScaleMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Toggle("Observation seule", isOn: $session.viewOnly)
                .toggleStyle(.checkbox)
                .font(Theme.small)
                .help("Regarder sans toucher : clavier et souris ne sont pas envoyés")
            Button("Envoyer le presse-papiers") { session.sendClipboard() }
                .buttonStyle(RemoteSmallButtonStyle())
                .speedDisabled(session.phase != .connected || session.viewOnly)
                .help("Envoie le texte du presse-papiers du Mac à l’ordinateur distant")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var titleRow: some View {
        let chip = session.securityChip
        return HStack(alignment: .center, spacing: 10) {
            FlowLayout(spacing: 8, lineSpacing: 6) {
                Text(session.desktopName.isEmpty ? session.connection.name : session.desktopName)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(session.address).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .textSelection(.enabled)
                Chip(text: chip.text, tone: chip.tone).help(chip.help)
                if session.viewOnly {
                    Chip(text: "Observation seule\u{00A0}: clavier et souris désactivés", tone: .warning)
                }
                if let toast = session.toast {
                    HStack(spacing: 4) {
                        Image(systemName: session.toastIsError ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text(toast).font(Theme.caption)
                        Button {
                            session.toast = nil
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Fermer le message")
                    }
                    .foregroundStyle(session.toastIsError ? Theme.warning : Theme.success)
                }
            }
            Spacer(minLength: 0)
            Toggle("Presse-papiers partagé", isOn: $session.shareClipboard)
                .toggleStyle(.checkbox)
                .font(Theme.small)
                .fixedSize()
                .help("Le texte copié à distance arrive dans le presse-papiers du Mac ; le texte copié sur le Mac part au premier clic dans la session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Bureau distant

    private var canvas: some View {
        ZStack {
            VNCFramebufferView(session: session)
            switch session.phase {
            case .connected:
                EmptyView()
            case .connecting, .authenticating:
                VNCStatusCard(systemImage: "network", title: "Connexion à \(session.connection.name)…",
                              message: session.statusLine, progress: true)
            case .needsCredentials(let message, let needsUsername):
                VNCCredentialsCard(session: session, message: message, needsUsername: needsUsername)
            case .failed(let message):
                VNCStatusCard(systemImage: "exclamationmark.triangle", title: "Session VNC impossible", message: message) {
                    HStack(spacing: 8) {
                        Button("Réessayer") { session.reconnect() }.buttonStyle(.primary)
                        Button("Ouvrir dans Partage d’écran") { RemoteModel.shared.connect(session.connection, external: true) }
                            .buttonStyle(.secondary)
                    }
                }
            case .closed:
                VNCStatusCard(systemImage: "display", title: "Session fermée",
                              message: "La session VNC de \(session.connection.name) est terminée.") {
                    Button("Reconnecter") { session.reconnect() }.buttonStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.console)
        .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius + 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius + 2).strokeBorder(Theme.borderStrong))
    }

    private var footer: some View {
        // Petite fenêtre : la ligne d'état garde la place, l'échelle est alors omise.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                Text(session.statusLine).font(Theme.mono(11.5)).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                Text(session.scale.footer).font(Theme.small).lineLimit(1).fixedSize()
            }
            HStack {
                Text(session.statusLine).font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Theme.panelMuted)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .padding(.top, 10)
    }
}

// MARK: - Cartes d'état

/// Carte posée sur le fond sombre du bureau distant (connexion, échec, fin).
private struct VNCStatusCard<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    var progress = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            if progress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage).font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .padding(16)
    }
}

extension VNCStatusCard where Actions == EmptyView {
    init(systemImage: String, title: String, message: String, progress: Bool = false) {
        self.init(systemImage: systemImage, title: title, message: message, progress: progress) { EmptyView() }
    }
}

/// Saisie du mot de passe (et du compte macOS au besoin) ; jamais affiché en clair.
private struct VNCCredentialsCard: View {
    @ObservedObject var session: VNCSession
    let message: String
    let needsUsername: Bool
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Text("Identifiants pour \(session.connection.name)").font(.system(size: 14, weight: .semibold))
            }
            Text(message).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if needsUsername {
                TextField("Nom du compte macOS", text: $username)
                    .textFieldStyle(.roundedBorder)
            }
            SecureField("Mot de passe", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Toggle("Mémoriser au Trousseau macOS", isOn: $remember).toggleStyle(.checkbox).font(Theme.small)
            ActionRow {
                Button("Ouvrir dans Partage d’écran") { RemoteModel.shared.connect(session.connection, external: true) }
                    .buttonStyle(.secondary)
                Button("Connecter", action: submit)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .speedDisabled(password.isEmpty || (needsUsername && username.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .onAppear { username = session.connection.username }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let secret = password
        password = ""
        session.submitCredentials(username: needsUsername ? username : nil, password: secret, remember: remember)
    }
}

// MARK: - Plein écran

/// Fenêtre plein écran d'une session (la session reste la même : l'onglet continue de l'afficher).
@MainActor
final class VNCFullScreenController: NSObject, NSWindowDelegate {
    static let shared = VNCFullScreenController()
    private var windows: [UUID: NSWindow] = [:]

    func present(_ session: VNCSession) {
        if let window = windows[session.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "\(session.connection.name) — VNC"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: VNCFullScreenContent(session: session) { [weak window] in
            window?.toggleFullScreen(nil)
        })
        window.delegate = self
        windows[session.id] = window
        session.setFullScreen(true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    /// Ferme la fenêtre plein écran de la session (session fermée, connexion supprimée).
    func close(_ id: UUID) {
        windows[id]?.close()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        (notification.object as? NSWindow)?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        VNCSessionStore.shared.session(for: id)?.setFullScreen(false)
    }
}

/// Contenu de la fenêtre plein écran : le bureau seul, avec une petite barre en haut.
private struct VNCFullScreenContent: View {
    @ObservedObject var session: VNCSession
    let exit: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .top) {
            VNCFramebufferView(session: session, focusOnAppear: true)
            HStack(spacing: 10) {
                Text(session.connection.name).font(.system(size: 12, weight: .semibold))
                Button("Ctrl-Alt-Suppr") { session.sendCtrlAltDelete() }
                    .buttonStyle(RemoteSmallButtonStyle())
                    .disabled(session.phase != .connected || session.viewOnly)
                Picker("Mise à l’échelle", selection: $session.scale) {
                    ForEach(VNCScaleMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(session.phase != .connected)
                Button("Quitter le plein écran", action: exit)
                    .buttonStyle(RemoteSmallButtonStyle(primary: true))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .opacity(hovering ? 1 : 0.25)
            .onHover { hovering = $0 }
            .padding(.top, 8)
        }
        .background(Theme.console)
        .ignoresSafeArea()
    }
}
