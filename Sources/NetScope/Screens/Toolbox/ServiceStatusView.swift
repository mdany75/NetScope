import NetScopeCore
import SwiftUI

/// Outil « État des services » (note 15) : bilan des grands services en ligne d'un coup d'œil.
/// Tableau standard des services, détail du service choisi (page d'état et test depuis ce réseau),
/// incidents en cours et historique.
struct ServiceStatusView: View {
    @ObservedObject var store: ToolStore
    @ObservedObject private var svc = SvcStore.shared
    /// Site actif : les services suivis en dépendent (note 53).
    @ObservedObject private var sites = SiteModel.shared
    @StateObject private var table = SvcServiceTable.makeModel()
    @State private var showCatalog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if Self.snapshotCatalog {
                // Captures : NETSCOPE_SERVICES_FEUILLE=1 dessine la feuille « Modifier la liste… » dans la page.
                ServiceCatalogSheet()
                    .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            }
            controls
            tiles
            notices
            HStack {
                ToolFieldLabel("Services suivis (\(svc.enabledServices.count))")
                Spacer()
                ToolColumnsMenu(model: table)
            }
            categoryBar
            SvcServiceTable(table: table)
            if let service = svc.service(svc.selectedServiceID) ?? svc.problemServices.first ?? svc.enabledServices.first {
                SvcServiceDetail(service: service)
            }
            SvcIncidentList()
            SvcHistoryList()
        }
        .onAppear {
            svc.activate()
            if svc.selectedServiceID == nil { svc.selectedServiceID = svc.problemServices.first?.id }
        }
        .onChange(of: sites.activeID) { _, _ in svc.siteChanged() }
        .sheet(isPresented: $showCatalog) {
            ServiceCatalogSheet()
        }
    }

    static var snapshotCatalog: Bool {
        CommandLine.arguments.contains("--snapshot") && ProcessInfo.processInfo.environment["NETSCOPE_SERVICES_FEUILLE"] == "1"
    }

    // MARK: Commandes

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                status
                Spacer(minLength: 8)
                buttons
            }
            // Petite fenêtre : les commandes passent sous le texte et à la ligne au besoin.
            VStack(alignment: .leading, spacing: 10) {
                status
                ToolFlowLayout(spacing: 8, lineSpacing: 8) {
                    intervalPicker
                    notifyToggle
                    catalogButton
                    refreshButton
                }
            }
        }
    }

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(svc.isChecking ? "Vérification en cours…" : lastLine(at: svc.demoNow ?? context.date))
                    .font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text("Pages d’état officielles et test depuis ce réseau (DNS, TLS, HTTPS).")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func lastLine(at date: Date) -> String {
        guard let last = svc.lastRefresh else { return "Pas encore vérifié" }
        return "Vérifié " + ToolText.relative(last, now: date) + " · " + MonProbe.intervalMenuLabel(svc.refreshMinutes * 60).lowercased()
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            intervalPicker
            notifyToggle
            catalogButton
            refreshButton
        }
    }

    private var intervalPicker: some View {
        Picker(selection: $svc.refreshMinutes) {
            ForEach(SvcStore.intervals, id: \.self) { minutes in
                Text(MonProbe.intervalMenuLabel(minutes * 60)).tag(minutes)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Rafraîchissement automatique")
}

private var notifyToggle: some View {
        Toggle(isOn: $svc.notifyIncidents) {
            Text("Notifier").font(Theme.small)
        }
        .toggleStyle(.checkbox)
        .fixedSize()
        .help("Notification macOS à chaque nouvel incident ou service injoignable d’ici")
}

private var catalogButton: some View {
        Button("Modifier la liste…") { showCatalog = true }
            .buttonStyle(.secondary)
            .fixedSize()
}

private var refreshButton: some View {
        Button {
            svc.refresh(manual: true)
        } label: {
            if svc.isChecking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Vérification")
                }
            } else {
                Label("Actualiser", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.primary)
        .disabled(svc.isChecking || svc.enabledServices.isEmpty)
        .fixedSize()
    }

    // MARK: Bilan

    private var tiles: some View {
        // Quatre tuiles sur une ligne quand elles ont la place, sinon deux par ligne.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { tileContent }.frame(minWidth: 4 * 118 + 24)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) { tileContent }
        }
    }

    @ViewBuilder private var tileContent: some View {
        ToolStatTile(label: "OK", value: "\(svc.count(.operational))", detail: "sur \(svc.enabledServices.count) suivis",
                     valueColor: Theme.success)
        ToolStatTile(label: "Dégradés", value: "\(svc.count(.degraded) + svc.count(.maintenance))",
                     detail: svc.count(.maintenance) > 0 ? "dont \(svc.count(.maintenance)) en maintenance" : "lenteurs, incidents",
                     valueColor: svc.count(.degraded) > 0 ? Theme.warning : Theme.text)
        ToolStatTile(label: "Panne chez eux", value: "\(svc.count(.outage))", detail: "page d’état en panne",
                     valueColor: svc.count(.outage) > 0 ? Theme.critical : Theme.text)
        let blocked = svc.count(.blocked)
        ToolStatTile(label: "Chez nous", value: "\(svc.count(.unreachable) + blocked)",
                     detail: blocked > 0 ? "dont \(blocked) bloqué\(blocked > 1 ? "s" : "") ici" : "injoignables d’ici",
                     valueColor: svc.count(.unreachable) > 0 ? Theme.critical : blocked > 0 ? Theme.warning : Theme.text)
    }

    @ViewBuilder private var notices: some View {
        if let global = svc.globalProblem {
            ToolNotice(tone: .critical, title: "Problème de notre côté", message: global + proxyNote)
        } else {
            let ours = svc.enabledServices.filter {
                svc.snapshot($0.id)?.verdict.side == .ours && svc.snapshot($0.id)?.verdict.health != .blocked
            }
            if !ours.isEmpty {
                ToolNotice(tone: .warning, title: "Probablement un problème chez nous",
                           message: ours.map { service in
                               let verdict = svc.snapshot(service.id)?.verdict
                               // « Dropbox — injoignable d’ici… » : pas de deux « : » à la suite.
                               let headline = verdict?.headline ?? ""
                               let lowered = headline.prefix(1).lowercased() + headline.dropFirst()
                               return "\(service.name) — " + lowered + (verdict?.detail.map { ". \($0)" } ?? "")
                           }.joined(separator: "\n") + proxyNote) {
                    Button("Voir") { svc.selectedServiceID = ours.first?.id }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        blockedNotice
        if svc.enabledServices.isEmpty {
            ToolNotice(tone: .accent, message: svc.catalogEnabledServices.isEmpty
                       ? "Aucun service suivi. «\u{00A0}Modifier la liste…\u{00A0}» en ajoute."
                       : "Tous les services sont masqués pour le site «\u{00A0}\(svc.siteName)\u{00A0}». Cocher une catégorie ci-dessous pour en suivre.")
        }
    }

    /// Note 53 : services bloqués par le filtrage de ce site, distingués d'une panne.
    @ViewBuilder private var blockedNotice: some View {
        let blocked = svc.blockedServices
        if !blocked.isEmpty {
            ToolNotice(tone: .warning, title: "Bloqué par le filtrage au site «\u{00A0}\(svc.siteName)\u{00A0}», pas une panne",
                       message: blocked.map { service in
                           let snapshot = svc.snapshot(service.id)
                           let block = snapshot?.endpoints.compactMap(\.block).first
                           return "\(service.name) — " + (block.map { "\($0.summary) (\($0.evidence))" } ?? (snapshot?.verdict.headline ?? ""))
                       }.joined(separator: "\n") + "\nSi c’est voulu, masquer ces services pour ce site\u{00A0}; sinon, vérifier le filtrage web de la FortiGate.") {
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Voir") { svc.selectedServiceID = blocked.first?.id }
                        .buttonStyle(.secondary)
                        .fixedSize()
                    Button("Masquer ici") {
                        for service in blocked { svc.setVisibleHere(false, for: service.id) }
                    }
                    .buttonStyle(.secondary)
                    .fixedSize()
                    .help("Ne plus suivre ces services au site «\u{00A0}\(svc.siteName)\u{00A0}» (ils restent suivis ailleurs)")
                }
            }
        }
    }

    // MARK: Catégories du site (note 53)

    private var categoryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Catégories suivies au site «\u{00A0}\(svc.siteName)\u{00A0}»")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
            ToolFlowLayout(spacing: 12, lineSpacing: 6) {
                ForEach(svc.categories, id: \.self) { category in
                    let state = svc.categoryState(category)
                    let members = svc.services.filter { $0.category == category && $0.isEnabled }
                    let shown = members.filter { svc.isVisibleHere($0) }.count
                    Toggle(isOn: Binding(get: { state != .hidden },
                                         set: { svc.setCategory(category, visible: $0) })) {
                        Text(state == .partial ? "\(category) (\(shown)/\(members.count))" : category)
                            .font(Theme.small)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(members.isEmpty)
                    .help(state == .hidden ? "Masquée pour ce site\u{00A0}: cliquer pour la suivre ici"
                                           : "Suivie pour ce site\u{00A0}: cliquer pour la masquer ici (elle reste suivie sur les autres sites)")
                }
            }
        }
    }

    private var proxyNote: String {
        svc.systemProxy.map { "\nCe Mac passe par un proxy\u{00A0}: \($0)." } ?? ""
    }
}

// MARK: - Tableau des services

/// Ligne du tableau des services (clés de tri toujours Comparable).
struct SvcRow: Identifiable {
    let service: SvcService
    let snapshot: SvcSnapshot?
    let isChecking: Bool

    var id: String { service.id }
    var name: String { service.name }
    var category: String { service.category }
    var health: SvcHealth? { snapshot?.verdict.health }
    /// Les plus graves en premier dans l'ordre décroissant ; jamais vérifié tout en bas.
    var healthRank: Int { health?.rank ?? -1 }
    var latency: Double { snapshot?.latencyMs ?? .infinity }
    var incidentCount: Int { snapshot?.activeIncidents.count ?? 0 }
    var headline: String { snapshot?.verdict.headline ?? (isChecking ? "Vérification…" : "En attente") }
    var checkedAt: Date { snapshot?.date ?? .distantPast }

    /// « 3/3 joignables », ou la première adresse en échec.
    var network: String {
        guard let endpoints = snapshot?.endpoints, !endpoints.isEmpty else { return "—" }
        if let failed = endpoints.first(where: { $0.block != nil }) ?? endpoints.first(where: { !$0.isReachable }) {
            // Colonne étroite : la cause seulement ; l'adresse en échec est dans l'aide de la cellule.
            return failed.failure?.shortLabel ?? "Échec"
        }
        return "\(endpoints.count)/\(endpoints.count) OK"
    }

    var feedText: String {
        if let feed = snapshot?.feed { return feed.description }
        if let error = snapshot?.feedError { return error }
        return service.format == .none ? "Aucune page lisible" : "—"
    }
}

enum SvcTone {
    static func tone(_ health: SvcHealth?) -> Tone {
        switch health {
        case .operational: return .success
        case .maintenance: return .accent
        case .degraded, .blocked: return .warning
        case .outage, .unreachable: return .critical
        default: return .neutral
        }
    }

    static func label(_ health: SvcHealth?, checking: Bool = false) -> String {
        health?.label ?? (checking ? "Vérification" : "En attente")
    }
}

struct SvcServiceTable: View {
    @ObservedObject var table: StandardTableModel<SvcRow>
    @ObservedObject private var svc = SvcStore.shared

    static let columns: [StandardColumn] = [
        StandardColumn(id: "service", title: "Service", isRequired: true),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "bilan", title: "Bilan"),
        StandardColumn(id: "reseau", title: "Depuis ce réseau"),
        StandardColumn(id: "latence", title: "Latence"),
        StandardColumn(id: "incidents", title: "Incidents", isDefaultVisible: false),
        StandardColumn(id: "categorie", title: "Catégorie", isDefaultVisible: false),
        StandardColumn(id: "page", title: "Page d’état", isDefaultVisible: false),
        StandardColumn(id: "verifie", title: "Vérifié à", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<SvcRow>] = [
        "service": KeyPathComparator(\SvcRow.name),
        "etat": KeyPathComparator(\SvcRow.healthRank, order: .reverse),
        "bilan": KeyPathComparator(\SvcRow.headline),
        "reseau": KeyPathComparator(\SvcRow.network),
        "latence": KeyPathComparator(\SvcRow.latency),
        "incidents": KeyPathComparator(\SvcRow.incidentCount, order: .reverse),
        "categorie": KeyPathComparator(\SvcRow.category),
        "page": KeyPathComparator(\SvcRow.feedText),
        "verifie": KeyPathComparator(\SvcRow.checkedAt),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<SvcRow> {
        StandardTableModel(id: "outils.services", columns: columns, sortKeys: sortKeys, defaultSort: "etat")
    }

    var body: some View {
        let rows = svc.enabledServices
            .map { SvcRow(service: $0, snapshot: svc.snapshot($0.id), isChecking: svc.checking.contains($0.id)) }
            .sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: rows.count, maxRows: 16, emptyText: "Aucun service suivi.") {
            Table(rows, selection: $svc.selectedServiceID, sortOrder: $table.sortOrder,
                  columnCustomization: $table.customization) {
                TableColumn("SERVICE", sortUsing: table.sort("service")) { row in
                    ToolTableText(row.name, size: 13, mono: false, weight: .semibold)
                        .help(row.service.category)
                }
                .width(min: 100, ideal: 125)
                .customizationID("service")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                    Chip(text: SvcTone.label(row.health, checking: row.isChecking), tone: SvcTone.tone(row.health))
                }
                .width(min: 64, ideal: 96)
                .customizationID("etat")

                TableColumn("BILAN", sortUsing: table.sort("bilan")) { row in
                    ToolTableText(row.headline, mono: false,
                                  color: row.health?.isProblem == true ? Theme.text : Theme.textSecondary)
                        .help([row.headline, row.snapshot?.verdict.detail].compactMap { $0 }.joined(separator: "\n"))
                }
                .width(min: 80, ideal: 120)
                .customizationID("bilan")

                // En-tête court (« depuis ce réseau ») : le détail des adresses testées est dans l'aide.
                TableColumn("D’ICI", sortUsing: table.sort("reseau")) { row in
                    let failed = row.snapshot?.endpoints.contains { !$0.isReachable } == true
                    let blocked = row.health == .blocked
                    ToolTableText(row.network, color: blocked ? Theme.warning : failed ? Theme.critical : Theme.textSecondary)
                        .help(row.snapshot?.endpoints.map { "\($0.host)\u{00A0}: \($0.summary)" }.joined(separator: "\n") ?? "")
                }
                .width(min: 52, ideal: 70)
                .customizationID("reseau")

                TableColumn("LATENCE", sortUsing: table.sort("latence")) { row in
                    ToolTableText(row.snapshot?.latencyMs.map(ToolFormat.milliseconds) ?? "—", alignment: .trailing)
                }
                .width(min: 62, ideal: 68)
                .customizationID("latence")

                TableColumn("INCIDENTS", sortUsing: table.sort("incidents")) { row in
                    ToolTableText(row.incidentCount == 0 ? "—" : "\(row.incidentCount)", weight: row.incidentCount > 0 ? .semibold : .regular,
                                  color: row.incidentCount > 0 ? Theme.warning : Theme.textTertiary, alignment: .trailing)
                }
                .width(min: 50, ideal: 66)
                .customizationID("incidents")
                .defaultVisibility(.hidden)

                TableColumn("CATÉGORIE", sortUsing: table.sort("categorie")) { row in
                    ToolTableText(row.category, mono: false, color: Theme.textSecondary)
                }
                .width(min: 64, ideal: 86)
                .customizationID("categorie")
                .defaultVisibility(.hidden)

                TableColumn("PAGE D’ÉTAT", sortUsing: table.sort("page")) { row in
                    ToolTableText(row.feedText, mono: false, color: Theme.textSecondary).help(row.feedText)
                }
                .width(min: 90, ideal: 160)
                .customizationID("page")
                .defaultVisibility(.hidden)

                TableColumn("VÉRIFIÉ À", sortUsing: table.sort("verifie")) { row in
                    ToolTableText(row.snapshot.map { ToolText.time($0.date, now: svc.now) } ?? "—", color: Theme.textSecondary)
                }
                .width(min: 60, ideal: 80)
                .customizationID("verifie")
                .defaultVisibility(.hidden)
            }
        }
    }
}
