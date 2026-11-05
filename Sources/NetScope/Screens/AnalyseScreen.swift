import NetScopeCore
import SwiftUI

/// Période d'analyse.
enum AnaPeriod: String, CaseIterable, Hashable {
    case jour, semaine, mois

    var label: String {
        switch self {
        case .jour: return "24 h"
        case .semaine: return "7 j"
        case .mois: return "30 j"
        }
    }

    var span: String {
        switch self {
        case .jour: return "dernières 24 h"
        case .semaine: return "7 derniers jours"
        case .mois: return "30 derniers jours"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .jour: return 86_400
        case .semaine: return 7 * 86_400
        case .mois: return 30 * 86_400
        }
    }
}

/// Un /24 d'un site (le même /24 sur deux sites donne deux choix distincts).
struct AnaNetwork: Hashable {
    let site: String
    let base: IPv4Address
}

/// Écran `Screen.analyse` (« Historique et adressage », note 79 ; ancien nom « Analyse ») : bilan de santé en tête s’il existe, indicateurs, occupation d'un /24, répartitions, alertes issues de l'inventaire
/// et comparaison de deux scans (croquis docs/croquis/Analyse.dc.html). Menu « Site ▾ » : un,
/// plusieurs ou tous les sites ; alertes regroupées par site ; carte d'occupation, courbe et
/// comparaison toujours d'un seul site (celui de la plage choisie).
struct AnalyseScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared
    @ObservedObject private var scope = SiteScopeStore.shared
    @ObservedObject private var sites = SiteModel.shared

    @State private var period: AnaPeriod = .jour
    /// /24 choisi ; nil : toutes les plages.
    @State private var network: AnaNetwork?
    @State private var networkChosen = false
    @State private var exportDocument: InvCSVDocument?
    @State private var exportName = "analyse.csv"
    @State private var exporting = false

    var body: some View {
        let now = Date()
        let since = now.addingTimeInterval(-period.seconds)
        let inventories = scope.inventories(for: .analyse)
        let multiple = inventories.count > 1
        let networks = inventories.flatMap { inventory in
            InvOccupancy.networks(of: Array(inventory.store.records.values)).map { AnaNetwork(site: inventory.key, base: $0) }
        }
        let wanted = networkChosen ? network : defaultNetwork(networks)
        let chosen = wanted.flatMap { networks.contains($0) ? $0 : nil }
        // Site de la carte d'occupation, de la courbe et de la comparaison : celui de la plage choisie.
        let focus = inventories.first { $0.key == chosen?.site } ?? inventories[0]
        let focusRecords = Array(focus.store.records.values)
        let records = chosen.map { network in focusRecords.filter { $0.ip.value & 0xFFFF_FF00 == network.base.value } }
            ?? inventories.flatMap { Array($0.store.records.values) }
        let alerts = SiteScope.alerts(inventories, since: since)
        let siteName = multiple ? focus.name : nil
        // Plusieurs sites : tuiles et répartitions portent sur le même périmètre, écrit en clair —
        // le /24 choisi d'un site (alertes de ce site), ou tous les sites réunis.
        let tileAlerts = multiple && chosen != nil ? alerts.filter { $0.siteKey == focus.key } : alerts
        let scopeLabel: String? = !multiple ? nil
            : chosen.map { "\(focus.name) · \(Subnet(address: $0.base, prefix: 24).description)" }
            ?? "\(inventories.count) sites réunis\u{00A0}: " + inventories.map(\.name).joined(separator: ", ")

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filters(networks: networks, chosen: chosen, inventories: inventories, now: now, since: since)
                // Note 79 : le bilan de santé (Trafic) en tête, quand il existe.
                AnaHealthBanner()
                if let scopeLabel {
                    Label("Indicateurs\u{00A0}: " + scopeLabel, systemImage: "mappin.and.ellipse")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .help("Tuiles et répartitions\u{00A0}: " + scopeLabel
                              + (chosen == nil ? "" : ". La courbe, la carte d’occupation et la comparaison portent sur ce site."))
                }
                tiles(records: records, chosen: chosen, alerts: tileAlerts.map(\.event), now: now, since: since)
                // Petite fenêtre : courbe et répartitions passent sous la carte d'occupation, qui prend
                // alors toute la largeur (pas de vide à sa droite).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        occupancy(chosen: chosen, allRecords: focusRecords, siteName: siteName, now: now)
                            .frame(width: 680)
                        charts(records: records, snapshots: focus.store.snapshots, siteName: siteName, scope: scopeLabel, since: since)
                            .frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        occupancy(chosen: chosen, allRecords: focusRecords, siteName: siteName, now: now)
                            .frame(maxWidth: .infinity)
                        charts(records: records, snapshots: focus.store.snapshots, siteName: siteName, scope: scopeLabel, since: since)
                    }
                }
                // Alertes, puis comparaison, sur toute la largeur : leurs tableaux (note 8) ne tiennent
                // pas côte à côte ; le croquis passe aussi à une colonne quand la place manque.
                AnaAlertsPanel(alerts: alerts, period: period, query: state.searchQuery(for: .analyse),
                               multiple: multiple, siteOrder: inventories.map(\.key))
                    .frame(maxWidth: .infinity)
                AnaComparePanel(snapshots: focus.store.snapshots, siteKey: focus.key, siteName: siteName) { text, name in
                    exportDocument = InvCSVDocument(text: text)
                    exportName = name
                    exporting = true
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .screenToolbar {
            Button {
                exportDocument = InvCSVDocument(text: alertsCSV(alerts, multiple: multiple))
                exportName = "analyse-\(InvFormat.day(now))-\(period.label.replacingOccurrences(of: " ", with: "")).csv"
                exporting = true
            } label: { Label("Exporter CSV", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
            Button { state.open(.rapports) } label: { Label("Rapport PDF", systemImage: "doc.richtext") }
                .buttonStyle(.primary)
        }
        .feedsInventory(state)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: exportName) { result in
            if case .success(let url) = result { model.show("CSV enregistré : \(url.lastPathComponent)") }
        }
    }

    // MARK: Occupation et graphiques

    @ViewBuilder
    private func occupancy(chosen: AnaNetwork?, allRecords: [InvRecord], siteName: String?, now: Date) -> some View {
        if let chosen {
            AnaOccupancyPanel(network: chosen.base, records: allRecords, now: now, recentWindow: max(period.seconds, 7 * 86_400),
                              siteKey: chosen.site, siteName: siteName)
        } else {
            Panel(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    InvPanelTitle("Carte d’occupation")
                    Text("Choisissez un /24 dans « Plage / VLAN » pour afficher la carte de ses 256 adresses.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func charts(records: [InvRecord], snapshots: [InvSnapshot], siteName: String?, scope: String?, since: Date) -> some View {
        VStack(spacing: 14) {
            AnaOnlineChart(snapshots: snapshots.filter { $0.date >= since }, period: period, siteName: siteName)
            AnaBreakdownPanel(records: records, scope: scope)
        }
    }

    /// Par défaut : le /24 du Mac dans le site actif, sinon la première plage.
    private func defaultNetwork(_ networks: [AnaNetwork]) -> AnaNetwork? {
        if let address = state.activeInterface?.address {
            let mine = AnaNetwork(site: sites.activeKey, base: IPv4Address(address.value & 0xFFFF_FF00))
            if networks.contains(mine) { return mine }
        }
        return networks.first
    }

    // MARK: Filtres

    private func filters(networks: [AnaNetwork], chosen: AnaNetwork?, inventories: [SiteInventory], now: Date, since: Date) -> some View {
        let scans = inventories.reduce(0) { $0 + $1.store.snapshots.filter { $0.date >= since }.count }
        let last = inventories.compactMap(\.store.lastMerge).max()
        let multiple = inventories.count > 1
        return HStack(spacing: 12) {
            SiteScopeMenu(screen: .analyse)
            InvSegmented(options: AnaPeriod.allCases.map { ($0, $0.label) }, selection: $period)
            HStack(spacing: 8) {
                Text("Plage / VLAN").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                Picker("", selection: Binding(get: { chosen }, set: { network = $0; networkChosen = true })) {
                    if multiple {
                        // Une section par site : le même /24 sur deux sites reste deux choix.
                        ForEach(inventories, id: \.key) { inventory in
                            Section(inventory.name) {
                                ForEach(networks.filter { $0.site == inventory.key }, id: \.self) { item in
                                    // Le site est dans le libellé : le bouton fermé le montre aussi.
                                    Text(inventory.name + " · " + networkLabel(item, store: inventory.store)).tag(Optional(item))
                                }
                            }
                        }
                    } else {
                        ForEach(networks, id: \.self) { item in
                            Text(networkLabel(item, store: inventories[0].store)).tag(Optional(item))
                        }
                    }
                    Text(multiple ? "Toutes les plages des \(inventories.count) sites (\(networks.count))" : "Toutes les plages (\(networks.count))")
                        .tag(AnaNetwork?.none)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 280)
            }
            // Petite fenêtre : version courte plutôt qu'une phrase coupée.
            ViewThatFits(in: .horizontal) {
                Text("\(scans) scan\(scans > 1 ? "s" : "") sur les \(period.span)" + (last.map { " · dernier scan \(InvFormat.timeOrStamp($0))" } ?? ""))
                    .fixedSize()
                Text("\(scans) scan\(scans > 1 ? "s" : "")" + (last.map { " · dernier \(InvFormat.timeOrStamp($0))" } ?? ""))
                    .fixedSize()
                Text("\(scans) scan\(scans > 1 ? "s" : "")").fixedSize()
                // Petite fenêtre avec le menu des sites : rien plutôt qu'un texte coupé (infobulle).
                Color.clear.frame(width: 0, height: 0)
            }
            .help("\(scans) scan\(scans > 1 ? "s" : "") sur les \(period.span)" + (last.map { " · dernier scan \(InvFormat.timeOrStamp($0))" } ?? ""))
            .font(Theme.small).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            if let toast = model.toast { InvToast(text: toast) }
        }
    }

    private func networkLabel(_ network: AnaNetwork, store: InventoryStore) -> String {
        let base = network.base
        let subnet = Subnet(address: base, prefix: 24)
        var label = subnet.description
        // Libellé de plage du site du /24 (le Scanner n'a que les plages du site actif).
        let ranges = network.site == sites.activeKey ? state.ranges : (sites.site(forKey: network.site)?.ranges ?? [])
        if let range = ranges.first(where: { (try? $0.parsed())?.contains(base.next ?? base) == true }) {
            label += " · " + range.label
        }
        let vlans = Set(store.records.values.filter { subnet.contains($0.ip) }.compactMap(\.vlan)).sorted()
        if !vlans.isEmpty { label += " · VLAN " + vlans.map(String.init).joined(separator: ", ") }
        return label
    }

    // MARK: Tuiles

    private func tiles(records: [InvRecord], chosen: AnaNetwork?, alerts: [InvEvent], now: Date, since: Date) -> some View {
        let added = records.filter { $0.firstSeen >= since && !$0.isImported }.count
        let lost = records.filter { !$0.isOnline && ($0.offlineSince ?? .distantPast) >= since }.count
        let online = records.filter(\.isOnline).count
        let recentOffline = records.filter { !$0.isOnline && now.timeIntervalSince($0.lastSeen) <= 7 * 86_400 }.count
        let conflicts = Set(records.filter(\.hasConflict).map(\.ip)).sorted()
        let pending = alerts.filter { $0.status == .aTraiter && $0.severity != .info }.count
        // Même fenêtre « vu récemment » que la carte d'occupation affichée dessous.
        let occupancy = chosen.map {
            InvOccupancy(network: $0.base, records: records, now: now, recentWindow: max(period.seconds, 7 * 86_400))
        }

        // Une rangée en grande fenêtre ; plusieurs lignes en petite fenêtre plutôt que des tuiles coupées.
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            InvTile(title: "Appareils", value: "\(records.count)", subtitle: "+\(added) / −\(lost) sur \(period.label)", valueSize: 26)
            InvTile(title: "En ligne", value: "\(online)", subtitle: "\(recentOffline) hors ligne vus récemment",
                    valueColor: Theme.success, valueSize: 26)
            InvTile(title: "Nouveaux", value: "\(added)", subtitle: "Première détection sur \(period.label)",
                    valueColor: Theme.accentStrong, valueSize: 26)
            InvTile(title: "Conflit IP", value: "\(conflicts.count)",
                    subtitle: conflicts.isEmpty ? "Aucun conflit actif" : "Actif · " + conflicts.map(\.description).joined(separator: ", "),
                    valueColor: conflicts.isEmpty ? Theme.text : Theme.critical,
                    tint: conflicts.isEmpty ? nil : .critical, valueSize: 26)
            InvTile(title: "Alertes à traiter", value: "\(pending)", subtitle: "Critiques et alertes sur \(period.label)",
                    valueColor: pending > 0 ? Theme.warning : Theme.text, valueSize: 26)
            InvTile(title: "Utilisation de la plage", value: "") {
                if let occupancy {
                    let percent = Int((occupancy.usage * 100).rounded())
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(percent) %").font(.system(size: 26, weight: .bold))
                                .foregroundStyle(percent >= 75 ? Theme.warning : Theme.text)
                            Text("\(occupancy.usedCount)/254").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                        }
                        ProgressBar(fraction: occupancy.usage, color: percent >= 75 ? Theme.warning : Theme.accent)
                    }
                } else {
                    Text("Choisissez un /24").font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.top, 6)
                }
            }
        }
    }

    // MARK: Export

    private func alertsCSV(_ items: [SiteScopedEvent], multiple: Bool) -> String {
        var lines = [(multiple ? "Site;" : "") + "Date;Gravité;Type;IP;Titre;Détail;Traitement"]
        for item in items {
            let alert = item.event
            let status: String
            switch alert.status {
            case .aTraiter: status = "À traiter"
            case .accepte: status = "Accepté"
            case .ignore: status = "Ignoré"
            }
            lines.append(((multiple ? [item.siteName] : []) + [InvFormat.stamp(alert.date), alert.severity.label, alert.kind.label,
                          alert.ip.description, alert.title, alert.detail, status]).map(AnaCSV.quote).joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

enum AnaCSV {
    /// Même protection que l'export d'inventaire (guillemets, sauts de ligne, formules).
    static func quote(_ field: String) -> String { InvCSV.quote(field, ";") }
}
