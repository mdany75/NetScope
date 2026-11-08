import NetScopeCore
import SwiftUI

/// Onglet Serveurs (note 16) : liste des serveurs de test (Cloudflare, M-Lab, LibreSpeed, Ookla,
/// personnalisés) avec la latence mesurée, favoris, choix du serveur et serveur personnalisé.
struct SpeedServersView: View {
    @ObservedObject var model: SpeedtestModel
    @ObservedObject private var ookla = ToolInstallMonitor.shared(.ooklaSpeedtest)
    @StateObject private var table = StandardTableModel<SpeedServerLine>(
        id: "speedtest.serveurs", columns: SpeedServersView.columns, sortKeys: SpeedServersView.sortKeys,
        defaultSort: "ordre")

    var body: some View {
        SidePanelSplit(sideWidth: 360, title: "Choix, serveur personnalisé et sources") {
            listPanel
        } side: {
            VStack(spacing: 12) {
                choicePanel
                customPanel
                sourcesPanel
            }
        }
        // CLI d'Ookla installé depuis l'encadré : le vérifier (« Speedtest by Ookla ») et l'ajouter à la liste.
        .onChange(of: ookla.presence) { _, _ in model.refreshOokla() }
    }

    // MARK: Liste

    private var listPanel: some View {
        let servers = model.visibleServers
        let rows = servers.enumerated().map { SpeedServerLine(server: $1, order: $0, favorite: model.isFavorite($1)) }
            .sorted(using: table.sortOrder)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        SectionHeader("Serveurs disponibles").fixedSize()
                        statusText
                        Spacer(minLength: 8)
                        listTools
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionHeader("Serveurs disponibles").fixedSize()
                            Spacer(minLength: 8)
                            listTools
                        }
                        statusText
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        sourcePicker
                        SearchField(text: $model.serverQuery, placeholder: "Ville, opérateur, pays…")
                            .frame(minWidth: 180)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sourcePicker
                        SearchField(text: $model.serverQuery, placeholder: "Ville, opérateur, pays…")
                    }
                }
                if !model.catalogFailures.isEmpty {
                    SpeedBanner(text: "Sources indisponibles : " + model.catalogFailures.joined(separator: " · "),
                                tone: .neutral, systemImage: "info.circle")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            if rows.isEmpty {
                Text(model.serverQuery.isEmpty ? "Aucun serveur : actualisez la liste." : "Aucun serveur ne correspond à la recherche.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(20)
            } else {
                SpeedServerTable(rows: rows, model: model, table: table)
                    .standardTableHeight(rows: rows.count, rowHeight: 30, maxRows: 14)
            }

            Text("Latence : connexion TCP vers chaque serveur, médiane de 3 essais. « Utiliser » (ou double-clic) choisit le serveur des prochains tests ; l’étoile l’ajoute aux favoris.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panelMuted)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var statusText: some View {
        HStack(spacing: 6) {
            if model.catalogLoading { ProgressView().controlSize(.small) }
            Text(statusLine).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    private var statusLine: String {
        if model.catalogLoading { return model.catalogStatus ?? "Chargement…" }
        guard let date = model.catalogDate else { return "Liste non chargée : « Actualiser » interroge M-Lab, LibreSpeed" + (model.ooklaEnabled ? " et Ookla" : "") }
        // Ookla masqué (note 79) : ses serveurs ne comptent pas.
        return "\(SpeedtestModel.catalogSummary(model.serverPrefs.allowed(model.catalog))) · mesurée à \(SpeedFormat.time.string(from: date))"
    }

    private var listTools: some View {
        HStack(spacing: 8) {
            Button {
                model.refreshCatalog()
            } label: {
                Label(model.catalogDate == nil ? "Charger la liste" : "Actualiser", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.secondary)
            .speedDisabled(model.catalogLoading || model.runState.isRunning)
            StandardColumnsMenu(model: table)
        }
    }

    private var sourcePicker: some View {
        let all = model.allServers
        return Picker("Source", selection: $model.serverSourceFilter) {
            Text("Toutes \(all.count)").tag(SpeedServerSource?.none)
            ForEach(SpeedServerSource.ordered, id: \.self) { source in
                let count = all.filter { $0.source == source }.count
                if count > 0 || (source == .ookla && model.ooklaEnabled) {
                    Text("\(source == .custom ? "Perso." : source.label) \(count)").tag(SpeedServerSource?.some(source))
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: Colonne de droite

    private var choicePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Serveur des prochains tests")
                SpeedServerRadio(title: "Automatique (le plus proche)",
                                 subtitle: "Choisit \(model.automaticChoice.historyLabel)",
                                 latency: model.automaticChoice.latencyMs, isOn: model.isAutomatic) {
                    model.selectServer(nil)
                }
                if let selected = model.selectedServer {
                    SpeedServerRadio(title: selected.title, subtitle: "\(selected.source.label) · \(selected.source.protocolLabel)",
                                     latency: selected.latencyMs, isOn: true) {}
                }
                Text("Le mode automatique prend la plus faible latence mesurée parmi Cloudflare, M-Lab et LibreSpeed. Ookla et les serveurs personnalisés se choisissent dans la liste.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var customPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Serveur personnalisé")
                Text("Serveur LibreSpeed de votre fournisseur ou de votre réseau (garbage.php, empty.php, getIP.php).")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SpeedFieldLabel("Adresse")
                SpeedTextField(placeholder: "https://vitesse.exemple.ca/", text: $model.customAddress)
                SpeedFieldLabel("Nom (facultatif)")
                SpeedTextField(placeholder: "Serveur du fournisseur", text: $model.customLabel, mono: false)
                if let error = model.customError {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    model.addCustomServer()
                } label: {
                    Label("Ajouter et utiliser", systemImage: "plus")
                }
                .buttonStyle(.secondary)
                .speedDisabled(model.customAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                ForEach(model.serverPrefs.custom) { server in
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack").foregroundStyle(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name).font(.system(size: 12, weight: .semibold))
                            Text(server.baseURL ?? "").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button {
                            model.removeCustomServer(server)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .help("Retirer ce serveur")
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var sourcesPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Sources")
                sourceLine("Cloudflare", "HTTP multi-flux, nœud anycast le plus proche.")
                sourceLine("M-Lab", "NDT7 (WebSocket, 1 flux), mesures ouvertes de Measurement Lab ; résultats publiés en données ouvertes par M-Lab.")
                sourceLine("LibreSpeed", "Serveurs libres, souvent hébergés par des fournisseurs.")
                ooklaPanel
            }
        }
    }

    /// Note 79 : Ookla masqué par défaut ; réactivable ici, avec sa licence en une ligne.
    @ViewBuilder private var ooklaPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.ooklaEnabled }, set: { model.setOoklaEnabled($0) })) {
                Text("Proposer Ookla (CLI officiel, Homebrew)").font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(model.runState.isRunning)
            Text("Licence d’Ookla\u{00A0}: usage personnel et non commercial seulement. Masqué par défaut\u{00A0}; Cloudflare, M-Lab et LibreSpeed suffisent pour un usage professionnel.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        if model.ooklaEnabled {
            if model.ooklaPath != nil {
                sourceLine("Ookla", "CLI officiel installé. " + OoklaLocator.licenseNote)
                ActionRow {
                    Link(destination: OoklaLocator.licenseURL) {
                        Label("Licence d’Ookla", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.secondary)
                }
            } else if ookla.presence.isInstalled {
                sourceLine("Ookla", "Pas d’API publique libre\u{00A0}: NetScope lance le CLI officiel d’Ookla s’il est installé.")
                // Un « speedtest » est là, mais ce n'est pas celui d'Ookla (speedtest-cli en Python).
                SpeedBanner(text: "L’outil «\u{00A0}speedtest\u{00A0}» installé n’est pas le CLI d’Ookla (speedtest-cli\u{00A0}?). Installez «\u{00A0}\(InstallableTool.ooklaSpeedtest.displayCommand)\u{00A0}».",
                            tone: .neutral, systemImage: "info.circle")
                ActionRow {
                    Link(destination: OoklaLocator.downloadURL) {
                        Label(InstallableTool.ooklaSpeedtest.officialLabel, systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.secondary)
                }
            } else {
                InstallToolPanel(tool: .ooklaSpeedtest, note: OoklaLocator.licenseNote)
            }
        }
    }

    private func sourceLine(_ name: String, _ text: String) -> some View {
        (Text(name + " : ").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
         + Text(text).font(Theme.small).foregroundColor(Theme.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Colonnes

    static let columns: [StandardColumn] = [
        StandardColumn(id: "favori", title: "Favori"),
        StandardColumn(id: "serveur", title: "Serveur", isRequired: true),
        StandardColumn(id: "ville", title: "Ville", isDefaultVisible: false),
        StandardColumn(id: "pays", title: "Pays", isDefaultVisible: false),
        StandardColumn(id: "operateur", title: "Opérateur"),
        StandardColumn(id: "source", title: "Source"),
        StandardColumn(id: "latence", title: "Latence"),
        StandardColumn(id: "action", title: "Choix"),
        StandardColumn(id: "hote", title: "Hôte", isDefaultVisible: false),
        StandardColumn(id: "protocole", title: "Protocole", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<SpeedServerLine>] = [
        "ordre": KeyPathComparator(\SpeedServerLine.order),
        "favori": KeyPathComparator(\SpeedServerLine.sortFavorite),
        "serveur": KeyPathComparator(\SpeedServerLine.sortTitle),
        "ville": KeyPathComparator(\SpeedServerLine.sortCity),
        "pays": KeyPathComparator(\SpeedServerLine.sortCountry),
        "operateur": KeyPathComparator(\SpeedServerLine.sortSponsor),
        "source": KeyPathComparator(\SpeedServerLine.sortSource),
        "latence": KeyPathComparator(\SpeedServerLine.sortLatency),
        "hote": KeyPathComparator(\SpeedServerLine.sortHost),
        "protocole": KeyPathComparator(\SpeedServerLine.sortProtocol),
    ]
}

/// Ligne de la liste des serveurs, avec ses clés de tri.
struct SpeedServerLine: Identifiable {
    let server: SpeedServer
    /// Rang dans la liste triée (favoris, puis latence) : tri par défaut.
    let order: Int
    let favorite: Bool

    var id: String { server.id }
    var sortFavorite: Int { favorite ? 0 : 1 }
    var sortTitle: String { server.title }
    var sortCity: String { server.city ?? "~" }
    var sortCountry: String { server.country ?? "~" }
    var sortSponsor: String { server.sponsor ?? "~" }
    var sortSource: String { server.source.label }
    var sortLatency: Double { server.latencyMs ?? .greatestFiniteMagnitude }
    var sortHost: String { server.host ?? "~" }
    var sortProtocol: String { server.source.protocolLabel }
}

/// Tableau standard des serveurs.
private struct SpeedServerTable: View {
    let rows: [SpeedServerLine]
    @ObservedObject var model: SpeedtestModel
    @ObservedObject var table: StandardTableModel<SpeedServerLine>
    @State private var selection: Set<String> = []

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("★"), sortUsing: table.sort("favori")) { line in
                Button {
                    model.toggleFavorite(line.server)
                } label: {
                    Image(systemName: line.favorite ? "star.fill" : "star")
                        .foregroundStyle(line.favorite ? Theme.warningDot : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(line.favorite ? "Retirer des favoris" : "Ajouter aux favoris")
            }
            .width(min: 28, ideal: 32, max: 40)
            .customizationID("favori")

            TableColumn(StandardTableHeading("SERVEUR"), sortUsing: table.sort("serveur")) { line in
                HStack(spacing: 6) {
                    Text(line.server.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if isChosen(line.server) {
                        Text(model.isAutomatic ? "Auto" : "Choisi")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accentStrong)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accentSoft))
                            .fixedSize()
                    }
                }
                .help(line.server.name)
            }
            .width(min: 120, ideal: 200)
            .customizationID("serveur")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(StandardTableHeading("VILLE"), sortUsing: table.sort("ville")) { line in
                cell(line.server.city)
            }
            .width(min: 70, ideal: 96)
            .customizationID("ville")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("PAYS"), sortUsing: table.sort("pays")) { line in
                cell(line.server.country)
            }
            .width(min: 50, ideal: 80)
            .customizationID("pays")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("OPÉRATEUR"), sortUsing: table.sort("operateur")) { line in
                cell(line.server.sponsor)
            }
            .width(min: 64, ideal: 110)
            .customizationID("operateur")

            TableColumn(StandardTableHeading("SOURCE"), sortUsing: table.sort("source")) { line in
                SpeedSourceTag(source: line.server.source)
            }
            .width(min: 70, ideal: 84)
            .customizationID("source")

            TableColumn(StandardTableHeading("LATENCE"), sortUsing: table.sort("latence")) { line in
                Text(latencyText(line.server))
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(line.server.latencyMs == nil ? Theme.textTertiary : latencyColor(line.server.latencyMs!))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
            .customizationID("latence")

            // Colonne non triable : le tri par défaut (ordre de la liste) n'affiche ainsi aucune flèche.
            TableColumn(StandardTableHeading("")) { line in
                Button(isChosen(line.server) && !model.isAutomatic ? "Choisi" : "Utiliser") {
                    model.selectServer(line.server)
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .disabled((isChosen(line.server) && !model.isAutomatic) || model.runState.isRunning)
            }
            .width(min: 70, ideal: 76, max: 90)
            .customizationID("action")

            TableColumn(StandardTableHeading("HÔTE"), sortUsing: table.sort("hote")) { line in
                Text(line.server.host.map { host in line.server.port.map { "\(host):\($0)" } ?? host } ?? "—")
                    .font(Theme.mono(11)).foregroundStyle(Theme.neutralText).lineLimit(1)
            }
            .width(min: 120, ideal: 220)
            .customizationID("hote")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("PROTOCOLE"), sortUsing: table.sort("protocole")) { line in
                cell(line.server.source.protocolLabel)
            }
            .width(min: 100, ideal: 170)
            .customizationID("protocole")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let line = rows.first(where: { $0.id == id }) {
                Button("Utiliser ce serveur") { model.selectServer(line.server) }
                    .disabled(model.runState.isRunning)
                Button(line.favorite ? "Retirer des favoris" : "Ajouter aux favoris") { model.toggleFavorite(line.server) }
            }
        } primaryAction: { ids in
            // Pendant un test, le serveur ne change pas (comme le bouton « Utiliser »).
            guard !model.runState.isRunning else { return }
            if let id = ids.first, let line = rows.first(where: { $0.id == id }) { model.selectServer(line.server) }
        }
    }

    private func isChosen(_ server: SpeedServer) -> Bool {
        model.isAutomatic ? model.automaticChoice.id == server.id : model.serverPrefs.selectedID == server.id
    }

    private func cell(_ text: String?) -> some View {
        Text(text ?? "—").font(Theme.small).foregroundStyle(text == nil ? Theme.textTertiary : Theme.neutralText).lineLimit(1)
    }

    private func latencyText(_ server: SpeedServer) -> String {
        if let latency = server.latencyMs { return "\(SpeedFormat.latency(latency)) ms" }
        switch server.source {
        case .ookla where server.ooklaID == nil: return "par Ookla"
        default: return model.catalogDate == nil ? "—" : "injoignable"
        }
    }

    private func latencyColor(_ value: Double) -> Color {
        value < 20 ? Theme.success : (value < 60 ? Theme.text : Theme.warning)
    }
}

/// Étiquette de source (Cloudflare, M-Lab…).
struct SpeedSourceTag: View {
    let source: SpeedServerSource

    var body: some View {
        Text(source.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(source == .ookla ? Theme.warning : (source == .custom ? Theme.neutralText : Theme.accentStrong))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(source == .ookla ? Theme.warningSoft : (source == .custom ? Theme.neutralSoft : speedDownSoft)))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Ligne « bouton radio » du croquis : rond, nom et détail, latence à droite.
struct SpeedServerRadio: View {
    let title: String
    let subtitle: String
    var latency: Double?
    var trailing: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(isOn ? Theme.accent : Theme.textTertiary, lineWidth: isOn ? 4 : 1.5)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(trailing ?? latency.map { "\(SpeedFormat.latency($0)) ms" } ?? "")
                    .font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
                    .fixedSize()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(isOn ? Theme.accentSoft : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(isOn ? Theme.accent : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
        }
        .buttonStyle(.plain)
    }
}
