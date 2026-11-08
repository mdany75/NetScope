import AppKit
import NetScopeCore
import SwiftUI

// Note 72 : panneau « Partages SMB » (fiche Appareil, onglet Ports et services) et feuille du
// menu du Scanner « Partages SMB… ». Tableau standard : nom, type, commentaire, chemin.

struct SMBSharesPanel: View {
    @ObservedObject private var model = SMBSharesModel.shared
    let host: String
    let name: String
    /// Dans la feuille du Scanner (sans cadre, tableau plus haut).
    var inSheet = false

    @StateObject private var table = StandardTableModel<SMBShare>(id: "partagesSMB", columns: SMBSharesPanel.columns,
                                                                 sortKeys: SMBSharesPanel.sortKeys, defaultSort: "type")
    @State private var selection = Set<SMBShare.ID>()
    /// Choix de l'utilisateur (ouvrir ou fermer les champs) ; nil : selon l'erreur.
    @State private var loginChoice: Bool?
    @State private var user = ""
    @State private var password = ""
    @State private var remember = true
    @State private var loaded = false

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "commentaire", title: "Commentaire"),
        StandardColumn(id: "chemin", title: "Chemin", isDefaultVisible: false),
        StandardColumn(id: "action", title: "Action"),
    ]

    static let sortKeys: [String: KeyPathComparator<SMBShare>] = [
        "nom": KeyPathComparator(\SMBShare.smbSortName),
        "type": KeyPathComparator(\SMBShare.smbSortKind),
        "commentaire": KeyPathComparator(\SMBShare.comment),
        "chemin": KeyPathComparator(\SMBShare.smbSortName),
    ]

    private var hostState: SMBHostState { model.state(for: host) }

    /// Champs de l'utilisateur : ouverts au clic, ou d'office quand l'hôte refuse l'invité.
    private var loginVisible: Bool { loginChoice ?? (hostState.error?.suggestsCredentials == true) }

    private var rows: [SMBShare] {
        (hostState.listing?.visible(showHidden: model.showHidden) ?? []).sorted(using: table.sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heading.fixedSize()
                    Spacer(minLength: 8)
                    controls
                }
                VStack(alignment: .leading, spacing: 10) {
                    heading
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        controls
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if hostState.isRunning {
                IndeterminateLine().padding(.horizontal, 16).padding(.bottom, 10)
            }
            if let error = hostState.error {
                ToolNotice(tone: error.suggestsCredentials ? .warning : .critical, title: error.title,
                           message: error.errorDescription ?? "")
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            if loginVisible { loginRow.padding(.horizontal, 16).padding(.bottom, 12) }
            if hostState.listing != nil || hostState.error == nil {
                shareTable.padding(.horizontal, 16)
            }
            footer.padding(16)
        }
        .background {
            if !inSheet { RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel) }
        }
        .overlay {
            if !inSheet { RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border) }
        }
        .onAppear(perform: load)
    }

    // MARK: En-tête

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Feuille : son titre dit déjà « Partages SMB de … ».
            if !inSheet { Text("Partages SMB").font(.system(size: 14, weight: .semibold)).fixedSize() }
            Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        if hostState.isRunning {
            return hostState.user.isEmpty ? "Lecture en invité…" : "Lecture avec \(hostState.user)…"
        }
        guard let listing = hostState.listing else {
            if let error = hostState.error { return "Dernier essai\u{00A0}: \(error.title.lowercasedFirst)" }
            return inSheet ? "Lancé seulement sur clic" : "smbutil view, lancé seulement sur clic"
        }
        return "\(listing.summary) · accès\u{00A0}: \(listing.access.label) · lu à \(ToolText.time(listing.date))"
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Toggle("Partages cachés ($)", isOn: $model.showHidden)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Affiche C$, ADMIN$, IPC$, print$ et les autres partages dont le nom finit par «\u{00A0}$\u{00A0}»")
            ToolColumnsMenu(model: table)
            Button("Copier CSV") { model.copyList(host: host, shares: rows) }
                .buttonStyle(.secondary)
                .disabled(rows.isEmpty)
            Button { loginChoice = !loginVisible } label: {
                Label("Utilisateur", systemImage: "person.badge.key")
            }
            .buttonStyle(.secondary)
            .help("Lister avec un utilisateur et son mot de passe (gardé au Trousseau)")
            if hostState.isRunning {
                Button("Arrêter") { model.cancel(host: host) }.buttonStyle(.secondary)
            } else {
                Button(hostState.listing != nil ? "Relire" : hostState.error != nil ? "Réessayer" : "Lister les partages") { listAgain() }
                    .buttonStyle(.primary)
                    .help(hostState.user.isEmpty ? "smbutil view en invité, puis en anonyme" : "smbutil view avec \(hostState.user)")
            }
        }
        .fixedSize()
    }

    // MARK: Utilisateur

    private var loginRow: some View {
        let remembered = model.memo[host]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                RegField(label: "Utilisateur") {
                    RegTextField(placeholder: "ex. BUREAU\\marc", text: $user, mono: true)
                        .onSubmit(listWithUser)
                }
                .frame(minWidth: 160, maxWidth: 240)
                RegField(label: "Mot de passe") {
                    RegTextField(placeholder: remembered?.passwordSaved == true && remembered?.user == user ? "enregistré au Trousseau" : "",
                                 text: $password, secure: true)
                        .onSubmit(listWithUser)
                }
                .frame(minWidth: 140, maxWidth: 220)
                Toggle("Retenir au Trousseau", isOn: $remember).toggleStyle(.checkbox).font(.system(size: 12))
                    .padding(.bottom, 5)
            }
            Text("Le mot de passe est tapé dans smbutil par NetScope\u{00A0}: jamais dans la commande, un fichier ou le journal.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ActionRow {
                Button("Lister avec cet utilisateur", action: listWithUser)
                    .buttonStyle(.primary)
                    .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || hostState.isRunning)
                if remembered != nil {
                    Button("Oublier cet utilisateur") {
                        model.forgetLogin(host: host)
                        user = ""
                        password = ""
                    }
                    .buttonStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Tableau

    private var shareTable: some View {
        let rows = rows
        return ToolStandardTableFrame(rowCount: rows.count, maxRows: inSheet ? 9 : ToolTableMetrics.maxRows, emptyText: emptyText) {
            Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("NOM", sortUsing: table.sort("nom")) { share in
                    HStack(spacing: 6) {
                        Image(systemName: share.smbSymbol)
                            .font(.system(size: 11))
                            .foregroundStyle(share.isHidden ? Theme.textTertiary : Theme.accent)
                            .frame(width: 14)
                        ToolTableText(share.name, weight: .semibold, color: share.isHidden ? Theme.textSecondary : Theme.text)
                    }
                    .help(share.isAdministrative ? "Partage administratif de Windows (caché)" : share.isHidden ? "Partage caché (nom terminé par «\u{00A0}$\u{00A0}»)" : share.name)
                }
                .width(min: 120, ideal: 190)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("TYPE", sortUsing: table.sort("type")) { share in
                    Chip(text: share.kind.label, tone: share.kind == .disk ? .accent : share.kind == .printer ? .success : .neutral)
                }
                .width(min: 70, ideal: 90)
                .customizationID("type")

                TableColumn("COMMENTAIRE", sortUsing: table.sort("commentaire")) { share in
                    ToolTableText(share.comment.isEmpty ? "—" : share.comment, mono: false,
                                  color: share.comment.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                        .help(share.comment)
                }
                .width(min: 120, ideal: 260)
                .customizationID("commentaire")

                TableColumn("CHEMIN", sortUsing: table.sort("chemin")) { share in
                    ToolTableText(SMBPaths.readable(host: host, share: share.name), color: Theme.textSecondary)
                }
                .width(min: 120, ideal: 220)
                .customizationID("chemin")
                .defaultVisibility(.hidden)

                TableColumn("ACTION") { share in
                    Group {
                        if share.opensInFinder {
                            Button("Ouvrir") { model.openInFinder(host: host, share: share) }
                                .buttonStyle(.ghost)
                                .help("Ouvre \(SMBPaths.readable(host: host, share: share.name)) dans le Finder")
                        } else {
                            Text("—").font(Theme.small).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: ToolTableMetrics.cellHeight, alignment: .trailing)
                }
                .width(min: 56, ideal: 66)
                .customizationID("action")
            }
            .contextMenu(forSelectionType: SMBShare.ID.self) { ids in
                if let share = rows.first(where: { ids.contains($0.id) }) {
                    Button("Ouvrir dans le Finder") { model.openInFinder(host: host, share: share) }
                        .disabled(!share.opensInFinder)
                    Divider()
                    Button("Copier le chemin") { model.copyPath(host: host, share: share) }
                    Button("Copier le chemin Windows") { model.copyPath(host: host, share: share, windows: true) }
                }
            } primaryAction: { ids in
                if let share = rows.first(where: { ids.contains($0.id) }) { model.openInFinder(host: host, share: share) }
            }
        }
    }

    private var emptyText: String {
        if hostState.isRunning { return "Lecture des partages…" }
        guard let listing = hostState.listing else {
            return "Cliquer sur «\u{00A0}Lister les partages\u{00A0}» pour interroger \(host)."
        }
        if !listing.shares.isEmpty, !model.showHidden {
            return "Seulement des partages cachés\u{00A0}: cocher «\u{00A0}Partages cachés ($)\u{00A0}»."
        }
        return "Aucun partage visible pour cet accès."
    }

    @ViewBuilder private var footer: some View {
        if let toast = model.toast {
            Label(toast, systemImage: "checkmark.circle").font(Theme.small).foregroundStyle(Theme.success)
        } else if hostState.listing == nil {
            Text("Lecture par smbutil view (livré avec macOS)\u{00A0}: en invité, puis en anonyme\u{00A0}; ou avec l’utilisateur saisi.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Double-clic sur un disque ou «\u{00A0}Ouvrir\u{00A0}»\u{00A0}: le Finder monte le partage et demande lui-même l’identifiant. Clic droit\u{00A0}: copier le chemin smb:// ou Windows.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let remembered = model.memo[host] {
            user = remembered.user
            remember = remembered.passwordSaved
        }
        // Utilisateur de la dernière lecture : le champ est ouvert pour relire avec lui.
        if !hostState.user.isEmpty { user = hostState.user }
    }

    private func listAgain() {
        // « Relire » garde l'accès de la dernière lecture réussie (utilisateur retenu au Trousseau).
        if case .user(let display)? = hostState.listing?.access, model.memo[host]?.user == display {
            guard model.memo[host]?.passwordSaved == true else {
                // Mot de passe non retenu : smbutil le demanderait et recevrait une chaîne vide.
                // Le champ s'ouvre pour le saisir à nouveau.
                user = display
                loginChoice = true
                return
            }
            model.list(host: host, login: SMBLogin(field: display))
        } else {
            model.list(host: host)
        }
    }

    private func listWithUser() {
        let login = SMBLogin(field: user)
        guard !login.user.isEmpty else { return }
        model.list(host: host, login: login, password: password, remember: remember)
        password = ""
    }
}

/// Ligne de progression sans fin connue (lecture en cours).
private struct IndeterminateLine: View {
    var body: some View {
        ProgressView().progressViewStyle(.linear).controlSize(.small)
    }
}

extension SMBShare {
    var smbSortName: String { name.lowercased() }
    /// Disques d'abord, puis imprimantes et IPC ; cachés après les visibles.
    var smbSortKind: String { "\(kind < .ipc ? 0 : 1)\(isHidden ? 1 : 0)\(SMBShareKind.allCases.firstIndex(of: kind) ?? 9)\(name.lowercased())" }

    var smbSymbol: String {
        switch kind {
        case .disk: return isHidden ? "externaldrive.badge.minus" : "externaldrive"
        case .printer: return "printer"
        case .ipc: return "arrow.left.arrow.right"
        case .device: return "cpu"
        case .other: return "questionmark.folder"
        }
    }
}

// MARK: - Feuille du Scanner

extension View {
    /// Feuille « Partages SMB » du menu du Scanner, une seule pour toute la fenêtre.
    func smbSharesPrompt() -> some View {
        modifier(SMBSharesPresenter())
    }
}

private struct SMBSharesPresenter: ViewModifier {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = SMBSharesModel.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { snapshotSheet }
            .sheet(item: $model.target) { target in
                SMBSharesSheet(target: target, dismiss: { model.target = nil })
            }
    }

    /// Captures (NETSCOPE_SMB_FEUILLE) : la feuille dessinée par-dessus la fiche Appareil.
    @ViewBuilder private var snapshotSheet: some View {
        if SMBSharesDemo.showsSheet, state.screen == .appareil, let device = state.selectedDevice {
            ZStack(alignment: .top) {
                Color(nsColor: .shadowColor).opacity(0.18).ignoresSafeArea()
                SMBSharesSheet(target: SMBSharesTarget(device: device), dismiss: {})
                    .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                    .padding(.top, 8)
            }
        }
    }
}

struct SMBSharesSheet: View {
    let target: SMBSharesTarget
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft)
                    Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Partages SMB de \(target.name)").font(Theme.panelTitle).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(target.host).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            SMBSharesPanel(host: target.host, name: target.name, inSheet: true)
                .padding(.horizontal, 4)
            Divider()
            HStack {
                Spacer()
                Button("Fermer", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 760)
        .background(Theme.panel)
    }
}
