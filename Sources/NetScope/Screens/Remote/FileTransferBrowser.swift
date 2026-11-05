import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

// Note 50 : navigateur de fichiers en deux volets (Ce Mac ↔ serveur) et file des transferts.
// Glisser-déposer : fichiers du Finder ou du volet Mac vers le serveur (envoi), éléments du serveur
// vers le volet Mac (réception) ; double-clic : ouvrir un dossier, ou transférer un fichier.

extension RemoteFileEntry {
    /// Tri « Nom » : dossiers d'abord, puis le nom sans casse.
    var browserSortName: String { (isDirectory ? "0" : "1") + name.lowercased() }
    var browserSortSize: Int64 { isDirectory ? -1 : (size ?? 0) }
    var browserSortDate: Date { modified ?? .distantPast }
    var browserSortPermissions: String { permissions ?? "" }
    var browserSortOwner: String { owner ?? "" }

    var browserSymbol: String {
        switch kind {
        case .directory: return "folder.fill"
        case .link: return "arrowshape.turn.up.right"
        case .file:
            switch (name as NSString).pathExtension.lowercased() {
            case "cfg", "conf", "txt", "log", "csv", "json", "xml", "ini": return "doc.text"
            case "bin", "out", "swi", "img", "pkg", "upd", "deb": return "cpu"
            case "gz", "zip", "tar", "tgz", "7z", "bz2": return "doc.zipper"
            case "pdf": return "doc.richtext"
            case "sh", "py", "rsc": return "terminal"
            case "pcap", "pcapng": return "waveform.path.ecg"
            default: return "doc"
            }
        }
    }
}

enum FileTransferColumns {
    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "taille", title: "Taille"),
        StandardColumn(id: "modifie", title: "Modifié"),
        StandardColumn(id: "droits", title: "Droits"),
        StandardColumn(id: "proprietaire", title: "Propriétaire", isDefaultVisible: false),
    ]

    /// Volet Mac : droits masqués par défaut (la place compte en petite fenêtre).
    static let localColumns: [StandardColumn] = columns.map { column in
        column.id == "droits" ? StandardColumn(id: column.id, title: column.title, isDefaultVisible: false) : column
    }

    static let sortKeys: [String: KeyPathComparator<RemoteFileEntry>] = [
        "nom": KeyPathComparator(\RemoteFileEntry.browserSortName),
        "taille": KeyPathComparator(\RemoteFileEntry.browserSortSize),
        "modifie": KeyPathComparator(\RemoteFileEntry.browserSortDate),
        "droits": KeyPathComparator(\RemoteFileEntry.browserSortPermissions),
        "proprietaire": KeyPathComparator(\RemoteFileEntry.browserSortOwner),
    ]

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMM HH:mm" : "d MMM yyyy"
        return formatter.string(from: date)
    }
}

/// Le navigateur complet : en-tête, volets, file des transferts.
struct FileTransferBrowser: View {
    @ObservedObject var session: FileTransferSession
    @ObservedObject var model: RemoteModel
    /// Petite fenêtre : la liste des connexions est masquée ; bouton pour la rouvrir.
    var compact = false
    @State private var showLog = false
    var onShowConnections: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { !session.pendingDeletion.isEmpty },
                                                                set: { if !$0 { session.pendingDeletion = [] } }),
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { session.confirmDeletion() }
            Button("Annuler", role: .cancel) { session.pendingDeletion = [] }
        } message: {
            Text(deletionMessage)
        }
        .confirmationDialog(conflictTitle, isPresented: Binding(get: { session.pendingConflict != nil },
                                                                set: { if !$0 { session.pendingConflict = nil } }),
                            titleVisibility: .visible) {
            Button("Remplacer", role: .destructive) { session.resolveConflict(overwrite: true) }
            Button("Garder les deux") { session.resolveConflict(overwrite: false) }
            Button("Annuler", role: .cancel) { session.pendingConflict = nil }
        } message: {
            Text("Le dossier du serveur contient déjà\u{00A0}: \(session.pendingConflict?.names.joined(separator: ", ") ?? "").")
        }
        .alert("Renommer « \(session.renaming?.name ?? "") »", isPresented: Binding(get: { session.renaming != nil },
                                                                                  set: { if !$0 { session.renaming = nil } })) {
            TextField("Nouveau nom", text: $session.renameText)
            Button("Renommer") { session.commitRename() }
            Button("Annuler", role: .cancel) { session.renaming = nil }
        }
        .alert("Nouveau dossier sur le serveur", isPresented: $session.creatingFolder) {
            TextField("Nom du dossier", text: $session.newFolderName)
            Button("Créer") { session.makeFolder() }
            Button("Annuler", role: .cancel) { session.creatingFolder = false }
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(spacing: 8) {
            if compact {
                Button(action: onShowConnections) {
                    Image(systemName: "sidebar.left").font(.system(size: 12))
                }
                .buttonStyle(.ghost)
                .help("Afficher les connexions")
            }
            RemoteProtoIcon(proto: session.connection.proto, size: 22)
            Text(session.connection.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(session.address).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Chip(text: session.isEncrypted ? "Chiffré" : "Non chiffré", tone: session.isEncrypted ? .success : .warning)
            Spacer(minLength: 6)
            Button {
                showLog.toggle()
            } label: {
                Label("Journal", systemImage: "list.bullet.rectangle").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(.ghost)
            .help("Journal de la session (connexion, certificat, transferts, erreurs)")
            .popover(isPresented: $showLog, arrowEdge: .bottom) { FileTransferLogView(session: session) }
            Button {
                session.isVisible = false
            } label: {
                Label("Masquer", systemImage: "rectangle.portrait.and.arrow.right").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(.ghost)
            .help("Revenir à l’aperçu\u{00A0}; les transferts continuent en arrière-plan")
            Button {
                FileTransferStore.shared.close()
            } label: {
                Label("Déconnecter", systemImage: "xmark.circle").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(.ghost)
            .help(session.activeCount > 0 ? "Ferme la session et annule " + MonText.plural(session.activeCount, "transfert", "transferts") : "Ferme la session")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.neutralSoft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: Contenu

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connexion à \(session.connection.host)…").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsCredentials(let message):
            ScrollView { FileTransferCredentialsCard(session: session, message: message).padding(20) }
        case .trustCertificate(let sha, let subject):
            ScrollView {
                FileTransferTrustCard(title: "Certificat du serveur non reconnu",
                                      text: "Le serveur FTPS présente un certificat que macOS ne peut pas vérifier (autosigné, ou émis pour un autre nom)\u{00A0}: \(subject). Comparez l’empreinte SHA-256 avec celle affichée par l’appareil avant de lui faire confiance\u{00A0}; elle sera retenue pour cette connexion, et une empreinte différente sera refusée.",
                                      fingerprint: sha, action: "Faire confiance et se connecter") {
                    session.trustCertificate(sha)
                }
                .padding(20)
            }
        case .trustHostKey(let fingerprint):
            ScrollView {
                FileTransferTrustCard(title: "Serveur SSH inconnu",
                                      text: "C’est la première connexion à \(session.connection.host) depuis ce Mac. Comparez l’empreinte de sa clé avec celle de l’appareil (ssh-keygen -lf sur le serveur) avant de continuer\u{00A0}; elle sera ajoutée à ~/.ssh/known_hosts, comme dans Terminal.",
                                      fingerprint: fingerprint, action: "Faire confiance et se connecter") {
                    session.trustHostKey()
                }
                .padding(20)
            }
        case .failed(let message):
            EmptyState(systemImage: "exclamationmark.triangle", title: "Connexion impossible", message: message) {
                HStack(spacing: 8) {
                    Button("Réessayer") { session.reconnect() }.buttonStyle(.primary)
                    Button("Modifier la connexion") {
                        model.selectedID = session.connection.id
                        session.isVisible = false
                        model.startEditing()
                    }
                    .buttonStyle(.secondary)
                }
            }
        case .connected:
            connected
        }
    }

    private var connected: some View {
        VStack(spacing: 0) {
            if session.connection.proto == .ftp {
                SpeedBanner(text: FileTransferTexts.ftpWarning).padding(.horizontal, 10).padding(.top, 8)
            }
            if let message = session.message {
                FileTransferMessageBar(text: message, tone: .success) { session.message = nil }
                    .padding(.horizontal, 10).padding(.top, 8)
            }
            HStack(spacing: 0) {
                FileTransferPane(session: session, side: .local)
                transferButtons
                FileTransferPane(session: session, side: .remote)
            }
            .padding(10)
            .frame(maxHeight: .infinity)
            FileTransferQueueView(session: session)
                .frame(height: compact ? 150 : 176)
        }
    }

    private var transferButtons: some View {
        VStack(spacing: 8) {
            Spacer()
            Button {
                session.upload(session.selectedLocal.map { URL(fileURLWithPath: $0.path) })
            } label: {
                Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold)).frame(width: 18)
            }
            .buttonStyle(.secondary)
            .disabled(session.localSelection.isEmpty)
            .help("Envoyer la sélection du Mac vers le serveur")
            Button {
                session.download(session.selectedRemote)
            } label: {
                Image(systemName: "arrow.left").font(.system(size: 13, weight: .semibold)).frame(width: 18)
            }
            .buttonStyle(.secondary)
            .disabled(session.remoteSelection.isEmpty)
            .help("Recevoir la sélection du serveur sur le Mac")
            Spacer()
        }
        .frame(width: 48)
    }

    private var deletionTitle: String {
        let entries = session.pendingDeletion
        if entries.count == 1, let entry = entries.first {
            return entry.isDirectory ? "Supprimer le dossier «\u{00A0}\(entry.name)\u{00A0}» et tout son contenu\u{00A0}?" : "Supprimer «\u{00A0}\(entry.name)\u{00A0}» du serveur\u{00A0}?"
        }
        return "Supprimer \(entries.count) éléments du serveur\u{00A0}?"
    }

    private var deletionMessage: String {
        "La suppression se fait sur \(session.connection.host) et ne peut pas être annulée\u{00A0}: le serveur n’a pas de corbeille."
    }

    private var conflictTitle: String {
        let count = session.pendingConflict?.names.count ?? 0
        return count > 1 ? "\(count) éléments existent déjà sur le serveur" : "Cet élément existe déjà sur le serveur"
    }
}

/// Volet du navigateur : Ce Mac ou le serveur.
struct FileTransferPane: View {
    enum Side { case local, remote }

    @ObservedObject var session: FileTransferSession
    let side: Side
    @StateObject private var table: StandardTableModel<RemoteFileEntry>
    @State private var isTargeted = false

    init(session: FileTransferSession, side: Side) {
        self.session = session
        self.side = side
        _table = StateObject(wrappedValue: StandardTableModel(id: side == .local ? "fichiers.mac" : "fichiers.serveur",
                                                              columns: side == .local ? FileTransferColumns.localColumns : FileTransferColumns.columns,
                                                              sortKeys: FileTransferColumns.sortKeys, defaultSort: "nom"))
    }

    private var entries: [RemoteFileEntry] { side == .local ? session.localEntries : session.remoteEntries }
    private var selection: Binding<Set<String>> { side == .local ? $session.localSelection : $session.remoteSelection }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.border).frame(height: 1)
            ZStack {
                fileTable
                if let error = side == .local ? session.localError : session.remoteError {
                    VStack {
                        Spacer()
                        FileTransferMessageBar(text: error, tone: .critical) {
                            if side == .local { session.localError = nil } else { session.remoteError = nil }
                        }
                        .padding(8)
                    }
                } else if entries.isEmpty, !(side == .remote && session.remoteLoading) {
                    Text("Dossier vide").font(Theme.small).foregroundStyle(Theme.textTertiary).allowsHitTesting(false)
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
            .strokeBorder(isTargeted ? Theme.accent : Theme.border, lineWidth: isTargeted ? 2 : 1))
        .onDrop(of: side == .remote ? [UTType.fileURL] : [UTType.utf8PlainText, UTType.plainText], isTargeted: $isTargeted) { providers in
            side == .remote ? dropFiles(providers) : dropRemote(providers)
        }
    }

    // MARK: Barre

    private var toolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: side == .local ? "laptopcomputer" : "server.rack")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            // En petite fenêtre, le libellé « CE MAC » / « SERVEUR » cède sa place au nom du dossier.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    sideLabel
                    pathMenu.fixedSize()
                }
                pathMenu
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if side == .remote, session.remoteLoading {
                ProgressView().controlSize(.mini)
            }
            iconButton("chevron.up", help: "Dossier parent") { goUp() }
                .disabled(isAtRoot)
            iconButton("arrow.clockwise", help: "Relire le dossier") {
                if side == .local { session.refreshLocal() } else { session.refreshRemote() }
            }
            StandardColumnsMenu(model: table, compact: true)
            if side == .remote {
                iconButton("folder.badge.plus", help: "Nouveau dossier sur le serveur") {
                    session.newFolderName = "Nouveau dossier"
                    session.creatingFolder = true
                }
                iconButton("trash", help: "Supprimer la sélection du serveur (avec confirmation)") {
                    session.pendingDeletion = session.selectedRemote
                }
                .disabled(session.remoteSelection.isEmpty)
            } else {
                iconButton("folder", help: "Choisir un dossier du Mac") { session.chooseLocalFolder() }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Theme.panelMuted)
    }

    private var sideLabel: some View {
        Text(side == .local ? "CE MAC" : "SERVEUR")
            .font(Theme.captionSemibold).kerning(0.4).foregroundStyle(Theme.textSecondary)
            .fixedSize()
    }

    /// Dossier affiché, avec ses parents dans le menu.
    private var pathMenu: some View {
        let crumbs: [(name: String, path: String)] = side == .local
            ? localCrumbs
            : RemotePath.breadcrumbs(session.remotePath)
        return Menu {
            ForEach(Array(crumbs.reversed().enumerated()), id: \.offset) { _, crumb in
                Button(crumb.path) { open(path: crumb.path) }
            }
        } label: {
            Text(crumbs.last?.name ?? "/").font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help(side == .local ? session.localURL.path : session.remotePath)
    }

    private var localCrumbs: [(name: String, path: String)] {
        var result: [(String, String)] = []
        var url = session.localURL.standardizedFileURL
        while true {
            result.insert((url.path == "/" ? "/" : FileManager.default.displayName(atPath: url.path), url.path), at: 0)
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path || result.count > 20 { break }
            url = parent
        }
        return result
    }

    private var isAtRoot: Bool {
        side == .local ? session.localURL.path == "/" : session.remotePath == "/"
    }

    private func goUp() {
        if side == .local {
            session.navigateLocal(session.localURL.deletingLastPathComponent())
        } else {
            session.navigateRemote(RemotePath.parent(session.remotePath))
        }
    }

    private func open(path: String) {
        if side == .local { session.navigateLocal(URL(fileURLWithPath: path)) } else { session.navigateRemote(path) }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5)).frame(width: 18, height: 18)
        }
        .buttonStyle(.ghost)
        .help(help)
    }

    // MARK: Tableau

    private var fileTable: some View {
        let rows = entries.sorted(using: table.sortOrder)
        return Table(of: RemoteFileEntry.self, selection: selection, sortOrder: $table.sortOrder,
                     columnCustomization: $table.customization) {
            TableColumn("Nom", sortUsing: table.sort("nom")) { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.browserSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(entry.isDirectory ? Theme.accent : Theme.textSecondary)
                        .frame(width: 14)
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    if let target = entry.linkTarget {
                        Text("→ \(target)").font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                .help(entry.path)
            }
            .width(min: 100, ideal: 150)
            .customizationID("nom").disabledCustomizationBehavior(.visibility)
            TableColumn("Taille", sortUsing: table.sort("taille")) { entry in
                Text(entry.isDirectory ? "—" : FileTransferFormat.size(entry.size))
                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 48, ideal: 56, max: 72)
            .customizationID("taille")
            TableColumn("Modifié", sortUsing: table.sort("modifie")) { entry in
                Text(FileTransferColumns.date(entry.modified)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 70, ideal: 86, max: 112)
            .customizationID("modifie")
            TableColumn("Droits", sortUsing: table.sort("droits")) { entry in
                // « 644 » (octal, comme chmod) ; la forme rw-r--r-- en infobulle.
                Text(entry.octalPermissions ?? "—")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .help(entry.permissions.map { (entry.isDirectory ? "d" : "-") + $0 } ?? "Droits non fournis par le serveur")
            }
            .width(min: 40, ideal: 48, max: 80)
            .customizationID("droits").defaultVisibility(side == .local ? .hidden : .automatic)
            TableColumn("Propriétaire", sortUsing: table.sort("proprietaire")) { entry in
                Text([entry.owner, entry.group].compactMap { $0 }.joined(separator: ":")).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 70, ideal: 90)
            .customizationID("proprietaire").defaultVisibility(.hidden)
        } rows: {
            ForEach(rows) { entry in
                TableRow(entry)
                    .itemProvider { itemProvider(for: entry) }
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: String.self) { ids in
            menu(ids)
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first, let entry = entries.first(where: { $0.id == id }) else { return }
            if side == .local { session.openLocal(entry) } else { session.openRemote(entry) }
        }
    }

    @ViewBuilder
    private func menu(_ ids: Set<String>) -> some View {
        let chosen = entries.filter { ids.contains($0.id) }
        if side == .local {
            Button(chosen.count > 1 ? "Envoyer \(chosen.count) éléments au serveur" : "Envoyer au serveur") {
                session.upload(chosen.map { URL(fileURLWithPath: $0.path) })
            }
            .disabled(chosen.isEmpty)
            if chosen.count == 1, let entry = chosen.first, entry.isDirectory {
                Button("Ouvrir") { session.openLocal(entry) }
            }
            Divider()
            Button("Afficher dans le Finder") { session.revealLocal() }
        } else {
            Button(chosen.count > 1 ? "Recevoir \(chosen.count) éléments sur le Mac" : "Recevoir sur le Mac") { session.download(chosen) }
                .disabled(chosen.isEmpty)
            if chosen.count == 1, let entry = chosen.first {
                if entry.isDirectory { Button("Ouvrir") { session.openRemote(entry) } }
                Button("Renommer…") { session.startRename(entry) }
                Button("Copier le chemin") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.path, forType: .string)
                }
            }
            Divider()
            Button("Nouveau dossier…") {
                session.newFolderName = "Nouveau dossier"
                session.creatingFolder = true
            }
            Button(chosen.count > 1 ? "Supprimer \(chosen.count) éléments…" : "Supprimer…", role: .destructive) {
                session.pendingDeletion = chosen
            }
            .disabled(chosen.isEmpty)
        }
    }

    // MARK: Glisser-déposer

    private func itemProvider(for entry: RemoteFileEntry) -> NSItemProvider {
        if side == .local {
            return NSItemProvider(object: URL(fileURLWithPath: entry.path) as NSURL)
        }
        // Plusieurs éléments choisis : on les emporte tous.
        let paths = session.remoteSelection.contains(entry.id) ? Array(session.remoteSelection) : [entry.path]
        return NSItemProvider(object: (FileTransferSession.dragPrefix + paths.joined(separator: "\n")) as NSString)
    }

    /// Fichiers du Finder ou du volet Mac déposés sur le serveur : envoi.
    private func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let collector = FileTransferDropCollector(expected: fileProviders.count) { urls in
            session.upload(urls)
        }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in collector.add(url) }
        }
        return true
    }

    /// Éléments du serveur déposés sur le volet Mac : réception.
    private func dropRemote(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, text.hasPrefix(FileTransferSession.dragPrefix) else { return }
            let paths = Set(text.dropFirst(FileTransferSession.dragPrefix.count).split(separator: "\n").map(String.init))
            Task { @MainActor in
                session.download(session.remoteEntries.filter { paths.contains($0.path) })
            }
        }
        return true
    }

    // MARK: Pied

    private var footer: some View {
        let chosen = entries.filter { selection.wrappedValue.contains($0.id) }
        let bytes = chosen.compactMap(\.size).reduce(0, +)
        let count = entries.count
        var text = "\(count) élément\(count > 1 ? "s" : "")"
        if !chosen.isEmpty { text += " · \(chosen.count) choisi\(chosen.count > 1 ? "s" : "")" + (bytes > 0 ? " · \(FileTransferFormat.size(bytes))" : "") }
        return HStack(spacing: 6) {
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 6)
            // Rappel du glisser-déposer, seulement s'il tient en entier.
            ViewThatFits(in: .horizontal) {
                Text(side == .local ? "Glissez vers le serveur pour envoyer" : "Glissez vers le Mac pour recevoir")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Theme.panelMuted)
    }
}

/// Rassemble les URL d'un dépôt (chargées en arrière-plan), puis appelle `done` sur le fil principal.
final class FileTransferDropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let done: @MainActor ([URL]) -> Void

    init(expected: Int, done: @escaping @MainActor ([URL]) -> Void) {
        remaining = expected
        self.done = done
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url, url.isFileURL { urls.append(url) }
        remaining -= 1
        let finished = remaining == 0
        let all = urls
        lock.unlock()
        if finished {
            Task { @MainActor in self.done(all) }
        }
    }
}

/// Bandeau de message refermable.
/// Journal de la session : ce que le protocole et NetScope ont noté, le plus récent en bas.
struct FileTransferLogView: View {
    @ObservedObject var session: FileTransferSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Journal de la session").font(Theme.panelTitle)
                Spacer()
                Button("Copier") { ToolActions.copy(session.log.joined(separator: "\n")) }
                    .buttonStyle(.secondary).controlSize(.small)
                    .disabled(session.log.isEmpty)
            }
            if session.log.isEmpty {
                Text("Rien pour l’instant.").font(Theme.small).foregroundStyle(Theme.textTertiary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(session.log.indices, id: \.self) { index in
                                Text(session.log[index]).font(Theme.mono(11)).foregroundStyle(Theme.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(session.log.count - 1, anchor: .bottom) }
                }
            }
        }
        .padding(14)
        .frame(width: 460, height: 280, alignment: .topLeading)
    }
}

struct FileTransferMessageBar: View {
    let text: String
    var tone: Tone = .success
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tone == .critical ? "xmark.octagon" : "checkmark.circle").font(.system(size: 12, weight: .semibold))
            Text(text).font(Theme.small).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .help("Fermer le message")
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(tone.background))
    }
}

/// Identification demandée dans le navigateur (utilisateur, mot de passe, Trousseau).
struct FileTransferCredentialsCard: View {
    @ObservedObject var session: FileTransferSession
    let message: String?

    private var needsPassword: Bool {
        session.connection.proto != .sftp || session.connection.transfer.sftpAuth != .agent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RemoteProtoIcon(proto: session.connection.proto, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identification").font(Theme.panelTitle)
                    Text("\(session.connection.proto.label) · \(session.connection.host):\(session.connection.port)")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            if let message {
                SpeedBanner(text: message, tone: .critical, systemImage: "xmark.octagon")
            }
            if session.connection.proto == .ftp {
                SpeedBanner(text: FileTransferTexts.ftpWarning)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Utilisateur").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                RemoteInput(placeholder: session.connection.proto == .sftp ? "admin" : "anonymous si vide", text: $session.credentialUser, mono: false)
            }
            if needsPassword {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.connection.transfer.sftpAuth == .key && session.connection.proto == .sftp ? "Phrase secrète de la clé" : "Mot de passe")
                        .font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    RemoteSecureInput(placeholder: "", text: $session.credentialPassword)
                        .onSubmit { session.submitCredentials() }
                }
                Toggle("Retenir dans le Trousseau macOS", isOn: $session.rememberPassword).toggleStyle(.checkbox).font(Theme.small)
            }
            HStack(spacing: 8) {
                Button("Se connecter") { session.submitCredentials() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                Button("Annuler") { FileTransferStore.shared.close() }.buttonStyle(.ghost)
            }
            if needsPassword {
                Text(session.rememberPassword ? FileTransferTexts.keychainNote : "Mot de passe utilisé pour cette session seulement, jamais enregistré.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

/// Empreinte à accepter (certificat FTPS, clé SSH).
struct FileTransferTrustCard: View {
    let title: String
    let text: String
    let fingerprint: String
    let action: String
    let accept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield").font(.system(size: 18)).foregroundStyle(Theme.warning)
                Text(title).font(Theme.panelTitle)
            }
            Text(text).font(Theme.small).foregroundStyle(Theme.neutralText).fixedSize(horizontal: false, vertical: true)
            Text(fingerprint)
                .font(Theme.mono(11.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            HStack(spacing: 8) {
                Button(action, action: accept).buttonStyle(.primary)
                Button("Annuler") { FileTransferStore.shared.close() }.buttonStyle(.ghost)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
