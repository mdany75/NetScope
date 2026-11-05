import NetScopeCore
import SwiftUI

/// Correctif 0.27.3 : onglet « Assistance RustDesk » d'Accès distant (demande de Dany, 5 novembre
/// 2026 : « place assistance rustdesk dans un onglet comme celui du serveur rustdesk »). Page
/// dédiée, plus aérée que l'ancienne section de « Sessions » : ID de l'usager et « Connecter »,
/// ajout au carnet, marche à suivre, historique complet des sessions lancées (tableau standard :
/// reconnexion, ajout au carnet, copie de l'ID), liens vers le tableau de bord du serveur et
/// Réglages › RustDesk. En démonstration : RustDesk n'est jamais lancé (voir RustDeskModel.launch).
struct RustDeskAssistancePage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: RemoteModel
    @ObservedObject private var rustdesk = RustDeskModel.shared
    @ObservedObject private var server = RustDeskServerModel.shared
    @State private var text = ""
    @State private var name = ""
    @State private var endUser = ""
    @State private var saveToBook = true
    @State private var error: String?
    @State private var query = ""
    @State private var copied: String?
    @State private var confirmClear = false
    @FocusState private var idFocused: Bool
    @StateObject private var table = StandardTableModel<RustDeskAssistanceRow>(
        id: "rustdesk-assistance-historique", columns: RustDeskAssistanceColumns.columns, sortKeys: RustDeskAssistanceColumns.sortKeys,
        defaultSort: "date", defaultAscending: false)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                connectCard
                if !rustdesk.isInstalled { RustDeskDownloadBanner() }
                history
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .onAppear(perform: takePrefill)
        .onChange(of: rustdesk.assistancePrefill) { _, _ in takePrefill() }
        .confirmationDialog("Effacer l’historique des sessions RustDesk\u{00A0}?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Effacer", role: .destructive) { rustdesk.clearHistory() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text((rustdesk.history.count == 1
                  ? "Le lancement noté sur ce Mac est oublié."
                  : "Les \(rustdesk.history.count) lancements notés sur ce Mac sont oubliés.")
                 + " Le carnet des postes n’est pas touché.")
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: RemoteProtocol.rustdesk.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(RemoteProtocol.rustdesk.tint)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(RemoteProtocol.rustdesk.soft))
            VStack(alignment: .leading, spacing: 2) {
                Text("Assistance RustDesk").font(Theme.panelTitle)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // En colonne étroite : libellés courts, puis icônes seules plutôt que tronqués.
            ViewThatFits(in: .horizontal) {
                headerLinks(server: "Tableau de bord du serveur", settings: "Réglages › RustDesk")
                headerLinks(server: "Serveur", settings: "Réglages")
                headerLinks(server: nil, settings: nil)
            }
        }
    }

    private var subtitle: String {
        let settings = rustdesk.settings
        var parts: [String] = []
        if settings.isConfigured {
            parts.append("Serveur\u{00A0}\(settings.idServer.trimmingCharacters(in: .whitespaces))")
            if !settings.publicKey.isEmpty { parts.append("clé\u{00A0}\(RustDeskKey.short(settings.publicKey))") }
        } else {
            parts.append("Serveur RustDesk non réglé (serveurs publics de RustDesk)")
        }
        parts.append(rustdesk.isInstalled ? "client RustDesk installé sur ce Mac" : "client RustDesk absent de ce Mac")
        return parts.joined(separator: " · ")
    }

    /// Libellé nil : icône seule (aide au survol).
    private func headerLinks(server serverTitle: String?, settings settingsTitle: String?) -> some View {
        HStack(spacing: 6) {
            if server.isAvailable {
                Button {
                    server.open(in: state)
                } label: {
                    if let serverTitle {
                        Label(serverTitle, systemImage: "server.rack").labelStyle(RemoteCompactLabelStyle())
                    } else {
                        Image(systemName: "server.rack")
                    }
                }
                .buttonStyle(RemoteSmallButtonStyle())
                .help("Tableau de bord du serveur\u{00A0}: sessions relayées, demandes de connexion, hbbs et hbbr (lecture seule par SSH)")
            }
            Button {
                RegNavigation.shared.section = .rustdesk
                state.open(.reglages)
            } label: {
                if let settingsTitle {
                    Label(settingsTitle, systemImage: "gearshape").labelStyle(RemoteCompactLabelStyle())
                } else {
                    Image(systemName: "gearshape")
                }
            }
            .buttonStyle(RemoteSmallButtonStyle())
            .help("Réglages › RustDesk\u{00A0}: serveur d’ID, clé publique et page d’assistance de l’usager")
        }
        .fixedSize()
    }

    // MARK: Connexion par ID

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ID DE L’USAGER").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    TextField("", text: $text, prompt: Text("123 456 789").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain)
                        .font(Theme.mono(22, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .focused($idFocused)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .frame(maxWidth: 420)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(error == nil ? (idFocused ? Theme.accent : Theme.borderStrong) : Theme.critical,
                                                                                lineWidth: idFocused || error != nil ? 1.5 : 1))
                        .onSubmit(connect)
                        .onChange(of: text) { _, _ in error = nil }
                        .accessibilityLabel("ID RustDesk de l’usager")
                    Button(action: connect) {
                        Label("Connecter", systemImage: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 6)
                            .frame(height: 30)
                    }
                    .buttonStyle(RemoteSmallButtonStyle(primary: true, tint: RemoteProtocol.rustdesk.tint))
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    // Pas de .keyboardShortcut(.defaultAction) : ↩︎ dans la recherche ou le tableau
                    // lancerait l'ID saisi ; le .onSubmit du champ d'ID suffit.
                    .help("Ouvre RustDesk sur ce Mac vers ce poste\u{00A0}; RustDesk demande ensuite le mot de passe à usage unique de l’usager")
                }
                Group {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.critical)
                    } else {
                        Text("9 ou 10 chiffres, espaces acceptés\u{00A0}; une adresse IPv4 ouvre l’accès IP direct (port 21118).")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(Theme.small)
                .fixedSize(horizontal: false, vertical: true)
            }
            bookOptions
            steps
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var bookOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Ajouter au carnet des postes", isOn: $saveToBook).toggleStyle(.checkbox).font(Theme.body)
                .help("Le poste est enregistré dans le carnet d’Accès distant (un ID déjà au carnet reprend sa connexion)")
            if saveToBook {
                AdaptiveFields {
                    field("Nom du poste (facultatif)", text: $name, placeholder: "Ex.\u{00A0}: WKS-ACCUEIL-02")
                    field("Usager (facultatif)", text: $endUser, placeholder: "Ex.\u{00A0}: Julie Gagnon (réception)")
                }
                .frame(maxWidth: 620, alignment: .leading)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            RemoteInput(placeholder: placeholder, text: text, mono: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Marche à suivre en trois temps, et le lien à envoyer à l'usager.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { stepItems }.frame(maxWidth: 1100, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) { stepItems }
            }
            HStack(spacing: 8) {
                Button {
                    if let message = rustdesk.supportMessage {
                        rustdesk.copy(message)
                        flash("Lien d’assistance copié")
                    }
                } label: {
                    Label("Copier le lien pour l’usager", systemImage: "link").labelStyle(RemoteCompactLabelStyle())
                }
                .buttonStyle(RemoteSmallButtonStyle())
                .disabled(rustdesk.supportMessage == nil)
                .help(rustdesk.supportMessage == nil
                      ? "Indiquez la page d’assistance dans Réglages › RustDesk"
                      : "Copie un message prêt à envoyer\u{00A0}: lien de la page d’assistance (client portable préconfiguré) et consignes")
                if let copied {
                    Label(copied, systemImage: "checkmark").font(Theme.small).foregroundStyle(Theme.success)
                } else if rustdesk.supportMessage != nil {
                    Text(rustdesk.settings.supportPageURL).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private var stepItems: some View {
        step(1, "L’usager ouvre la page d’assistance et lance l’outil RustDesk, sans rien installer.")
        step(2, "Il vous dicte son ID et le mot de passe à usage unique affichés.")
        step(3, "«\u{00A0}Connecter\u{00A0}» ouvre RustDesk sur ce Mac\u{00A0}; tapez-y le mot de passe.")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(RemoteProtocol.rustdesk.tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(RemoteProtocol.rustdesk.soft))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text).font(Theme.small).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Historique

    private var history: some View {
        let all = rustdesk.history
        let rows = RustDeskAssistanceRow.rows(RustDeskAssistance.filter(all, query: query), connections: model.connections)
        return VStack(alignment: .leading, spacing: 8) {
            // Recalculé chaque minute : « N aujourd’hui » se remet à zéro après minuit.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                historyHeader(all, now: context.date)
            }
            if all.isEmpty {
                EmptyState(systemImage: "clock.arrow.circlepath", title: "Aucune session lancée",
                           message: "Les sessions ouvertes depuis NetScope (ID collé, carnet, fiche d’un appareil) apparaîtront ici, avec la reconnexion en un clic.")
                    .frame(height: 170)
            } else if rows.isEmpty {
                Text("Aucune session ne correspond à «\u{00A0}\(query)\u{00A0}».")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                RustDeskAssistanceTable(table: table, rows: rows, reconnect: reconnect, addToBook: addToBook, copyID: copyID, showInBook: showInBook)
            }
            Text("RustDesk ne prévient pas NetScope de la fin d’une session\u{00A0}: seule l’heure de lancement est notée. Historique gardé sur ce Mac seulement (\(RustDeskHistory.limit) lancements au plus).")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func historyHeader(_ all: [RustDeskLaunch], now: Date) -> some View {
        SectionHeader(title: "Sessions récentes", subtitle: historySubtitle(all, now: now)) {
            if !all.isEmpty {
                SearchField(text: $query, placeholder: "Poste, ID, usager…")
                    .frame(width: 210)
                Menu {
                    Button("Effacer l’historique…", role: .destructive) { confirmClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Autres actions sur l’historique")
                StandardColumnsMenu(model: table, compact: true)
            }
        }
    }

    private func historySubtitle(_ all: [RustDeskLaunch], now: Date) -> String? {
        guard !all.isEmpty else { return nil }
        let today = RustDeskAssistance.todayCount(all, now: now)
        let postes = RustDeskAssistance.distinctTargets(all)
        return "\(all.count) lancement\(all.count > 1 ? "s" : "") · \(today) aujourd’hui · \(postes) poste\(postes > 1 ? "s" : "")"
    }

    // MARK: Actions

    private func connect() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Dossier vide : la connexion choisie dans la liste n'est pas visible sur cette page.
        error = model.quickRustDesk(text, name: saveToBook ? name : "", endUser: saveToBook ? endUser : "", folder: "",
                                    saveToBook: saveToBook)
        if error == nil {
            text = ""
            name = ""
            endUser = ""
        }
    }

    private func takePrefill() {
        guard let prefill = rustdesk.assistancePrefill else { return }
        text = prefill
        rustdesk.assistancePrefill = nil
        DispatchQueue.main.async { idFocused = true }
    }

    private func bookConnection(_ row: RustDeskAssistanceRow) -> RemoteConnection? {
        let launch = row.launch
        if let id = launch.connectionID, let connection = model.connections.first(where: { $0.id == id }) { return connection }
        return model.connections.first { $0.proto == .rustdesk && $0.host.lowercased() == launch.target.lowercased() }
    }

    private func reconnect(_ row: RustDeskAssistanceRow) {
        if let connection = bookConnection(row) {
            model.connectRustDesk(connection)
        } else if let target = try? RustDeskTarget.parse(row.launch.target) {
            if let message = rustdesk.launch(target, name: row.launch.name) { model.toast = message }
        }
    }

    private func addToBook(_ row: RustDeskAssistanceRow) {
        let launch = row.launch
        if let message = model.quickRustDesk(launch.target, name: RustDeskAssistance.suggestedName(launch), endUser: launch.endUser,
                                             folder: launch.site, saveToBook: true, launch: false) {
            model.toast = message
        }
    }

    private func copyID(_ row: RustDeskAssistanceRow) {
        rustdesk.copy(row.launch.target)
        flash(row.isDirect ? "Adresse copiée" : "ID copié")
    }

    /// « Afficher dans le carnet » : la connexion choisie, sur la page « Sessions ».
    private func showInBook(_ row: RustDeskAssistanceRow) {
        guard let connection = bookConnection(row) else { return }
        model.selectedID = connection.id
        rustdesk.isAssistanceShown = false
    }

    private func flash(_ text: String) {
        copied = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copied == text { copied = nil }
        }
    }
}

/// Deux champs côte à côte, l'un sous l'autre quand la place manque.
private struct AdaptiveFields<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { content }.frame(minWidth: 460)
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

// MARK: - Tableau des sessions récentes

struct RustDeskAssistanceRow: Identifiable {
    let launch: RustDeskLaunch
    let inBook: Bool

    var id: UUID { launch.id }
    var date: Date { launch.date }
    var isDirect: Bool { RustDeskID.parse(launch.target) == nil }
    var nameSort: String { launch.name.lowercased() }
    var targetSort: String { launch.target }
    var userSort: String { launch.endUser.isEmpty ? "\u{10FFFF}" : launch.endUser.lowercased() }
    var siteSort: String { launch.site.isEmpty ? "\u{10FFFF}" : launch.site.lowercased() }
    var bookSort: Int { inBook ? 0 : 1 }

    static func rows(_ history: [RustDeskLaunch], connections: [RemoteConnection]) -> [RustDeskAssistanceRow] {
        let ids = Set(connections.map(\.id))
        let targets = RustDeskAssistance.bookTargets(connections)
        return history.map { RustDeskAssistanceRow(launch: $0, inBook: RustDeskAssistance.isInBook($0, connectionIDs: ids, targets: targets)) }
    }
}

enum RustDeskAssistanceColumns {
    static let columns: [StandardColumn] = [
        StandardColumn(id: "date", title: "Lancée", isRequired: true),
        StandardColumn(id: "poste", title: "Poste", isRequired: true),
        StandardColumn(id: "id", title: "ID ou adresse"),
        StandardColumn(id: "usager", title: "Usager"),
        StandardColumn(id: "site", title: "Dossier", isDefaultVisible: false),
        StandardColumn(id: "carnet", title: "Carnet"),
        StandardColumn(id: "actions", title: "Actions", isRequired: true),
    ]
    static let sortKeys: [String: KeyPathComparator<RustDeskAssistanceRow>] = [
        "date": KeyPathComparator(\RustDeskAssistanceRow.date),
        "poste": KeyPathComparator(\RustDeskAssistanceRow.nameSort),
        "id": KeyPathComparator(\RustDeskAssistanceRow.targetSort),
        "usager": KeyPathComparator(\RustDeskAssistanceRow.userSort),
        "site": KeyPathComparator(\RustDeskAssistanceRow.siteSort),
        "carnet": KeyPathComparator(\RustDeskAssistanceRow.bookSort),
    ]
    static let widths: [String: CGFloat] = ["date": 136, "poste": 136, "id": 110, "usager": 190, "site": 120, "carnet": 80, "actions": 96]
}

struct RustDeskAssistanceTable: View {
    @ObservedObject var table: StandardTableModel<RustDeskAssistanceRow>
    let rows: [RustDeskAssistanceRow]
    let reconnect: (RustDeskAssistanceRow) -> Void
    let addToBook: (RustDeskAssistanceRow) -> Void
    let copyID: (RustDeskAssistanceRow) -> Void
    let showInBook: (RustDeskAssistanceRow) -> Void
    @State private var selection: Set<UUID> = []

    static let rowHeight: CGFloat = 30
    static let maxRows = 14

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        StandardTableHorizontalScroll(minWidth: table.contentWidth(RustDeskAssistanceColumns.widths),
                                      height: StandardTableMetrics.height(rows: rows.count, rowHeight: Self.rowHeight, maxRows: Self.maxRows)) {
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn(StandardTableHeading("LANCÉE"), sortUsing: table.sort("date")) { row in
                    // Recalculée chaque minute (« Aujourd’hui » devient « Hier » après minuit).
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(RemoteFormat.relative(row.date, now: context.date)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .width(min: 132, ideal: RustDeskAssistanceColumns.widths["date"])
                .customizationID("date").disabledCustomizationBehavior(.visibility)
                TableColumn(StandardTableHeading("POSTE"), sortUsing: table.sort("poste")) { row in
                    Text(row.launch.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        .help(row.launch.name)
                }
                .width(min: 100, ideal: RustDeskAssistanceColumns.widths["poste"])
                .customizationID("poste").disabledCustomizationBehavior(.visibility)
                TableColumn(StandardTableHeading("ID OU ADRESSE"), sortUsing: table.sort("id")) { row in
                    Text(row.launch.targetLabel).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
                        .textSelection(.enabled)
                        .help(row.isDirect ? "Accès IP direct" : "ID RustDesk")
                }
                .width(min: 96, ideal: RustDeskAssistanceColumns.widths["id"])
                .customizationID("id")
                TableColumn(StandardTableHeading("USAGER"), sortUsing: table.sort("usager")) { row in
                    Text(row.launch.endUser.isEmpty ? "—" : row.launch.endUser).font(Theme.small)
                        .foregroundStyle(row.launch.endUser.isEmpty ? Theme.textTertiary : Theme.text).lineLimit(1)
                        .help(row.launch.endUser)
                }
                .width(min: 80, ideal: RustDeskAssistanceColumns.widths["usager"])
                .customizationID("usager")
                TableColumn(StandardTableHeading("DOSSIER"), sortUsing: table.sort("site")) { row in
                    Text(row.launch.site.isEmpty ? "—" : row.launch.site).font(Theme.small)
                        .foregroundStyle(row.launch.site.isEmpty ? Theme.textTertiary : Theme.textSecondary).lineLimit(1)
                        .help(row.launch.site)
                }
                .width(min: 70, ideal: RustDeskAssistanceColumns.widths["site"])
                .customizationID("site").defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("CARNET"), sortUsing: table.sort("carnet")) { row in
                    if row.inBook {
                        Chip(text: "Au carnet", tone: .success)
                    } else {
                        Chip(text: "Hors carnet", tone: .neutral)
                            .help(row.launch.connectionID != nil
                                  ? "Lancé depuis le carnet, puis retiré du carnet"
                                  : "Ce poste n’est pas, ou plus, dans le carnet")
                    }
                }
                .width(min: 70, ideal: RustDeskAssistanceColumns.widths["carnet"])
                .customizationID("carnet")
                TableColumn(StandardTableHeading("ACTIONS")) { row in
                    actions(row)
                }
                .width(min: 96, ideal: RustDeskAssistanceColumns.widths["actions"])
                .customizationID("actions").disabledCustomizationBehavior(.visibility)
            }
            .standardTableStyle()
            .scrollDisabled(rows.count <= Self.maxRows)
            .contextMenu(forSelectionType: UUID.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                // Double-clic ou ↩︎ : reconnexion (une seule ligne, pour ne pas ouvrir dix sessions).
                if ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }) { reconnect(row) }
            }
        }
    }

    private func actions(_ row: RustDeskAssistanceRow) -> some View {
        HStack(spacing: 2) {
            Button { reconnect(row) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22)
            }
            .help("Relancer RustDesk sur ce poste")
            .foregroundStyle(Theme.accentStrong)
            // Déjà au carnet : « Afficher dans le carnet » (la connexion choisie, page « Sessions »).
            Button { row.inBook ? showInBook(row) : addToBook(row) } label: {
                Image(systemName: row.inBook ? "list.bullet.rectangle" : "plus.rectangle.on.rectangle")
                    .font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22)
            }
            .foregroundStyle(row.inBook ? Theme.textSecondary : Theme.accentStrong)
            .help(row.inBook ? "Afficher ce poste dans le carnet" : "Ajouter ce poste au carnet")
            Button { copyID(row) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22)
            }
            .foregroundStyle(Theme.textSecondary)
            .help(row.isDirect ? "Copier l’adresse" : "Copier l’ID")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func menu(for ids: Set<UUID>) -> some View {
        if ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }) {
            Button("Reconnecter") { reconnect(row) }
            Divider()
            if row.inBook {
                Button("Afficher dans le carnet") { showInBook(row) }
            } else {
                Button("Ajouter au carnet") { addToBook(row) }
            }
            Button(row.isDirect ? "Copier l’adresse" : "Copier l’ID") { copyID(row) }
        } else if !ids.isEmpty {
            let missing = rows.filter { ids.contains($0.id) && !$0.inBook }
            Button("Ajouter \(missing.count) poste\(missing.count > 1 ? "s" : "") au carnet") { missing.forEach(addToBook) }
                .disabled(missing.isEmpty)
        }
    }
}
