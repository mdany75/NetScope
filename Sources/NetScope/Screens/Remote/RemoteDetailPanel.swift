import NetScopeCore
import SwiftUI

/// Panneau de détails de la connexion choisie : identité, sécurité, actions.
struct RemoteDetailPanel: View {
    @ObservedObject var model: RemoteModel
    let connection: RemoteConnection

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                identityCard
                securityCard
                // Note 66 : hôte de rebond et tunnels (croquis : « Tunnels / redirections »).
                if connection.proto == .ssh {
                    SSHTunnelDetailSection(model: model, connection: connection)
                }
                // Note 6 : ID groupé, copies, lien d'assistance et lancements du poste.
                if connection.proto == .rustdesk {
                    RustDeskDetailSection(model: model, connection: connection)
                }
                actionsCard
            }
        }
    }

    private var reach: RemoteReachability { model.state(of: connection.id) }

    /// Note 78 : nom pris dans ~/.ssh/config quand la connexion n'en a pas.
    private var userLabel: String {
        if !connection.username.isEmpty { return connection.username }
        if connection.proto == .ssh, let user = SSHConfigCache.config.resolve(connection.host).user { return "\(user) (~/.ssh/config)" }
        return "—"
    }

    /// Note 78 : adresse réelle d'un alias de ~/.ssh/config.
    private var sshConfigHostName: String? {
        guard let hostName = SSHConfigCache.config.resolve(connection.host).hostName, hostName != connection.host else { return nil }
        return hostName
    }

    @ViewBuilder private var reachChip: some View {
        if connection.isRustDeskByID {
            Chip(text: "Par ID", tone: .neutral)
                .help("Joint par le serveur d’ID RustDesk (aucune sonde TCP)")
        } else {
            Chip(text: reach.label, tone: reach.tone)
        }
    }

    /// En-tête de la carte : icône, nom, note et pastilles (`chips`), bouton de repli à droite.
    private func header<Chips: View>(@ViewBuilder chips: () -> Chips) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteProtoIcon(proto: connection.proto, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                // Largeur idéale nulle : seules les pastilles décident si la disposition sur une
                // ligne tient (`ViewThatFits`) ; un nom ou une note longs s'abrègent ou passent à la
                // ligne comme avant, sans repousser le dossier sous l'en-tête.
                Text(connection.name).font(Theme.panelTitle).lineLimit(1)
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !connection.note.isEmpty {
                    Text(connection.note).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                chips().padding(.top, 4)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Button {
                model.detailsVisible = false
            } label: {
                Image(systemName: "sidebar.right").font(.system(size: 12))
            }
            .buttonStyle(.ghost)
            .help("Replier le panneau de détails")
            // Servi avant le texte (priorité 1) : le bouton garde sa taille et reste
            // visible même si la colonne coupe un contenu trop large.
            .fixedSize()
            .layoutPriority(2)
        }
    }

    private var identityCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                // Correctif 0.27.2 : un nom de dossier long (« St-Georges GM / St-Georges Toyota »)
                // sur la ligne de la pastille d'état élargissait le panneau au-delà de sa colonne de
                // 300 points, qui recouvrait alors la session et sortait de la fenêtre. S'il ne tient
                // pas à côté d'elle, il passe sous l'en-tête, sur toute la largeur du panneau (sous
                // le nom, la colonne du texte l'abrégeait), puis s'abrège au milieu s'il le faut.
                ViewThatFits(in: .horizontal) {
                    header {
                        HStack(spacing: 6) {
                            reachChip
                            Chip(text: connection.folderLabel, tone: .neutral)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        header { reachChip }
                        Chip(text: connection.folderLabel, tone: .neutral, truncates: true)
                            .help(connection.folderLabel)
                    }
                }
                if connection.proto.isInsecure {
                    SpeedBanner(text: "Protocole non chiffré : le mot de passe circule en clair.")
                }
                if connection.proto == .rustdesk {
                    // Note 6 : poste RustDesk (ID ou IP directe, usager).
                    VStack(spacing: 0) {
                        KeyValueRow(key: "Protocole", value: connection.proto.fullName, keyWidth: 92)
                        KeyValueRow(key: connection.isRustDeskByID ? "ID RustDesk" : "IP directe", value: connection.address, mono: true, keyWidth: 92)
                        KeyValueRow(key: "Usager", value: connection.endUser.isEmpty ? "—" : connection.endUser, keyWidth: 92)
                        KeyValueRow(key: "Dernière", value: RemoteFormat.relative(connection.lastConnected), keyWidth: 92)
                        // Note 87 : nom et note donnés à l'ID (tableau de bord du serveur).
                        if let note = RustDeskServerWatchModel.shared.note(for: connection.host) {
                            KeyValueRow(key: "Note", value: [note.name, note.note].filter { !$0.isEmpty }.joined(separator: " · "), keyWidth: 92)
                        }
                    }
                } else {
                VStack(spacing: 0) {
                    KeyValueRow(key: "Protocole", value: connection.proto.fullName, keyWidth: 92)
                    KeyValueRow(key: connection.proto == .serie ? "Périphérique" : "Hôte", value: connection.host, mono: true, keyWidth: 92)
                    KeyValueRow(key: connection.proto == .serie ? "Paramètres" : "Port",
                                value: connection.proto == .serie ? "\(connection.port) bauds · 8N1" : String(connection.port),
                                mono: true, keyWidth: 92)
                    KeyValueRow(key: "Utilisateur", value: userLabel, mono: !connection.username.isEmpty, keyWidth: 92)
                    if connection.proto == .ssh, let hostName = sshConfigHostName {
                        KeyValueRow(key: "HostName", value: hostName + " (~/.ssh/config)", mono: true, keyWidth: 92)
                    }
                    if connection.proto == .ssh, !connection.identityFile.isEmpty {
                        KeyValueRow(key: "Clé", value: connection.identityFile, mono: true, keyWidth: 92)
                    }
                    if connection.proto == .rdp || connection.proto == .vnc {
                        KeyValueRow(key: "Affichage", value: connection.display.summary(for: connection.proto), keyWidth: 92)
                    }
                    if connection.proto.isFileTransfer {
                        KeyValueRow(key: "Mode", value: connection.fileTransferModeLabel, keyWidth: 92)
                        KeyValueRow(key: "Dossier", value: connection.transfer.remoteDirectory.isEmpty ? "Accueil" : connection.transfer.remoteDirectory,
                                    mono: !connection.transfer.remoteDirectory.isEmpty, keyWidth: 92)
                    }
                    KeyValueRow(key: "Dernière", value: RemoteFormat.relative(connection.lastConnected), keyWidth: 92)
                }
                }
            }
        }
    }

    private var securityCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Authentification") {
                    Chip(text: securityChip.text, tone: securityChip.tone)
                }
                Text(authText).font(Theme.small).foregroundStyle(Theme.neutralText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(securityFootnote)
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var securityChip: (text: String, tone: Tone) {
        switch connection.proto {
        case .ssh, .sftp, .ftps, .rustdesk: return ("Chiffré", .success)
        case .telnet, .ftp, .vnc: return ("Non chiffré", .warning)
        case .serie: return ("Local", .neutral)
        default: return ("Application externe", .neutral)
        }
    }

    private var securityFootnote: String {
        if connection.proto.isFileTransfer {
            return "Mots de passe au Trousseau macOS (service com.danymenard.netscope.ftp), jamais dans le carnet."
        }
        // Note 57 : onglets de terminal intégrés.
        if connection.proto == .ssh || connection.proto == .telnet {
            return "Mot de passe au Trousseau macOS (service \(RemoteSessionStore.keychainService)), jamais dans le carnet"
                + (connection.proto == .ssh ? ", remis à ssh par SSH_ASKPASS (ni sur le disque ni dans la ligne de commande)." : ".")
        }
        if connection.proto == .vnc {
            return "Mot de passe au Trousseau macOS (service com.danymenard.netscope.vnc). VNC ne chiffre pas l’image\u{00A0}: réseau local, VPN ou tunnel SSH."
        }
        if connection.proto == .serie { return "Port ouvert seulement quand vous ouvrez la session, en accès exclusif." }
        if connection.proto == .rustdesk {
            return "Mot de passe permanent au Trousseau macOS, jamais dans le carnet ni dans une ligne de commande\u{00A0}: macOS le remet à RustDesk dans l’adresse d’ouverture."
        }
        return "Identifiants demandés par l’application externe, jamais enregistrés par NetScope."
    }

    private var authText: String {
        switch connection.proto {
        case .ssh:
            let saved = RemoteSessionStore.shared.hasPassword(connection.id)
            return "Onglet de NetScope avec ssh de macOS\u{00A0}: clés de ~/.ssh et agent SSH" + (saved ? ", puis le mot de passe du Trousseau" : "")
                + "\u{00A0}; un serveur inconnu montre son empreinte et attend votre accord (~/.ssh/known_hosts)."
        case .telnet:
            return RemoteSessionStore.shared.hasPassword(connection.id)
                ? "Identifiant et mot de passe demandés par l’appareil, en clair\u{00A0}; mot de passe du Trousseau tapé sur demande (menu de l’onglet)."
                : "Identifiant et mot de passe demandés par l’appareil, en clair."
        case .rdp: return "Identifiants demandés par Windows App à l’ouverture (NLA)."
        case .vnc:
            let saved = VNCPasswordStore.hasPassword(connection.id) ? "au Trousseau" : "demandé à la connexion"
            return connection.username.isEmpty
                ? "Mot de passe VNC \(saved) (chiffré par DES au défi du serveur)."
                : "Compte macOS « \(connection.username) » (ARD\u{00A0}: Diffie-Hellman + AES-128) ou mot de passe VNC, \(saved)."
        case .ftp, .ftps:
            let password = FileTransferStore.shared.hasPassword(connection.id) ? "mot de passe au Trousseau" : "mot de passe demandé à la connexion"
            if connection.username.isEmpty { return "Anonyme (utilisateur « anonymous »)." }
            return connection.proto == .ftp
                ? "Utilisateur et \(password), envoyés EN CLAIR sur le réseau."
                : "Utilisateur et \(password), chiffrés par TLS (\(connection.transfer.tlsMode.label.lowercased()))\u{00A0}; certificat vérifié par macOS ou par son empreinte."
        case .sftp:
            switch connection.transfer.sftpAuth {
            case .password:
                return "Mot de passe " + (FileTransferStore.shared.hasPassword(connection.id) ? "au Trousseau" : "demandé à la connexion")
                    + "\u{00A0}; clé du serveur comparée à ~/.ssh/known_hosts."
            case .key: return "Clé \(connection.transfer.keyPath)\u{00A0}; clé du serveur comparée à ~/.ssh/known_hosts."
            case .agent: return "Clés de ~/.ssh et agent SSH, comme dans Terminal\u{00A0}; clé du serveur comparée à ~/.ssh/known_hosts."
            }
        case .rustdesk:
            let relay = connection.isRustDeskByID ? "par le serveur d’ID et, au besoin, le relais" : "en accès IP direct (port \(connection.port))"
            return (RustDeskModel.shared.hasPassword(connection.id)
                    ? "Mot de passe permanent du Trousseau, remis à RustDesk à l’ouverture"
                    : "Mot de passe à usage unique donné par l’usager, demandé par RustDesk")
                + "\u{00A0}; session chiffrée de bout en bout, \(relay)."
        case .serie: return "Aucune\u{00A0}: accès physique par le port console (consoles Cisco et Fortinet\u{00A0}: 9600 8N1)."
        }
    }

    private var actionsCard: some View {
        let plan = model.plan(for: connection)
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    RemoteConnectButton(model: model, connection: connection,
                                        tint: reach == .unreachable ? Theme.textSecondary : Theme.accent,
                                        isEnabled: (try? plan.get()) != nil)
                    Button("Modifier") { model.startEditing() }.buttonStyle(RemoteSmallButtonStyle())
                    Button("Dupliquer") { model.duplicateSelected() }.buttonStyle(RemoteSmallButtonStyle())
                }
                HStack(spacing: 6) {
                    if !connection.isRustDeskByID {
                        Button {
                            model.checkReachability(only: connection.id)
                        } label: {
                            Label("Vérifier", systemImage: "dot.radiowaves.left.and.right").labelStyle(RemoteCompactLabelStyle())
                        }
                        .buttonStyle(.ghost)
                    }
                    Spacer()
                    Button {
                        model.pendingDeletion = connection
                    } label: {
                        Label("Supprimer", systemImage: "trash").labelStyle(RemoteCompactLabelStyle())
                    }
                    .buttonStyle(GhostButtonStyle(color: Theme.critical))
                }
                VStack(alignment: .leading, spacing: 6) {
                    let inTab = RemoteSessionStore.opensInTab(connection.proto)
                    SpeedFieldLabel(connection.proto.isFileTransfer ? "Ouvrir dans NetScope" : (inTab ? "Ou dans l’app externe" : "Ouvrir dans l’app externe"))
                    switch plan {
                    case .success(let plan):
                        Text(connection.proto.isFileTransfer ? "Navigateur de fichiers (Ce Mac ↔ serveur)"
                             : (inTab ? "\(plan.appName) (menu de « Connecter »)" : plan.appName))
                            .font(.system(size: 12, weight: .semibold))
                        Text(plan.preview)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.neutralText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                    case .failure(let error):
                        SpeedBanner(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                    tone: .critical, systemImage: "xmark.octagon")
                    }
                }
                .padding(.top, 10)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
    }
}

/// Fenêtre d'import des appareils du scan (ports 22, 23, 3389 ou 5900 ouverts).
struct RemoteImportOverlay: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: RemoteModel

    var body: some View {
        let candidates = model.importCandidates(from: state.devices)
        ZStack(alignment: .top) {
            Color(hex: 0x0F172A, opacity: 0.45)
                .ignoresSafeArea()
                .onTapGesture { model.showImport = false }
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.importSource == .scan ? "Importer depuis le scan" : "Importer depuis ~/.ssh/config").font(Theme.panelTitle)
                        Text(model.importSource == .scan ? subtitle : SSHConfigImportList.subtitle)
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    // Note 78 : deuxième source, les hôtes de ~/.ssh/config (lecture seule).
                    Picker("", selection: $model.importSource) {
                        ForEach(RemoteImportSource.ordered) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Source de l’import")
                    Button {
                        model.showImport = false
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.ghost)
                    .help("Fermer l’import")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

                if model.importSource == .sshConfig {
                    SSHConfigImportList(model: model)
                } else {
                    TableHeader(columns: [
                        .init(title: "Appareil"),
                        .init(title: "IP", width: 130),
                        .init(title: "Ports détectés", width: 150),
                        .init(title: "Proposé", width: 110),
                        .init(title: "Action", width: 130, alignment: .trailing),
                    ])
                    ScrollView {
                        VStack(spacing: 0) {
                            if candidates.isEmpty {
                                EmptyState(systemImage: "dot.radiowaves.left.and.right", title: "Aucun appareil à importer",
                                           message: "Lancez un scan avec le profil « Ports courants » : les appareils avec 22, 23, 3389 ou 5900 ouverts apparaîtront ici.")
                                    .frame(height: 180)
                            }
                            ForEach(candidates) { candidate in row(candidate) }
                        }
                    }
                    .frame(height: candidates.isEmpty ? 180 : min(CGFloat(candidates.count) * 38, 420))

                    HStack(spacing: 10) {
                        let fresh = candidates.filter { !$0.alreadySaved }.count
                        Text("\(candidates.count) appareil\(candidates.count > 1 ? "s" : "") · \(fresh) nouveau\(fresh > 1 ? "x" : "")")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Ajouter toutes les nouvelles") { _ = model.addAll(candidates) }
                            .buttonStyle(.secondary)
                            .speedDisabled(fresh == 0)
                        Button("Terminé") { model.showImport = false }
                            .buttonStyle(.primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.panelMuted)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            .frame(maxWidth: 760)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            .shadow(color: Color(hex: 0x0F172A, opacity: 0.25), radius: 20, y: 16)
            .padding(.top, 60)
            .padding(.horizontal, 16)
        }
    }

    private var subtitle: String {
        let ranges = state.ranges.filter(\.isEnabled).map(\.text).joined(separator: " et ")
        let base = state.devices.isEmpty ? "Aucun appareil scanné" : "\(state.devices.count) appareils scannés"
        return "\(base)\(ranges.isEmpty ? "" : " · \(ranges)") · appareils avec 22, 23, 3389 ou 5900 ouverts"
    }

    private func row(_ candidate: RemoteImportCandidate) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(candidate.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("· \(candidate.vendor)").font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
            Text(candidate.ip).font(Theme.mono(12)).padding(.horizontal, 8).frame(width: 130, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(candidate.ports, id: \.self) { port in
                    let proto = RemoteProtocol.forPort(port) ?? .vnc
                    RemoteProtoBadge(proto: proto, text: String(port))
                }
            }
            .padding(.horizontal, 8).frame(width: 150, alignment: .leading)
            RemoteProtoBadge(proto: candidate.proto, text: "\(candidate.proto.badge) \(candidate.port)")
                .padding(.horizontal, 8).frame(width: 110, alignment: .leading)
            Group {
                if candidate.alreadySaved {
                    Text("Déjà enregistrée").font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else {
                    Button("Ajouter") { model.add(candidate) }
                        .buttonStyle(RemoteSmallButtonStyle())
                        .help("Ajouter \(candidate.name) en \(candidate.proto.label)")
                }
            }
            .padding(.horizontal, 8).frame(width: 130, alignment: .trailing)
        }
        .frame(height: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
