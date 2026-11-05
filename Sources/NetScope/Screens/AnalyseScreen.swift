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

/// Un /24, ou un bloc de /23 à /16 (note 78), d'un site (le même réseau sur deux sites donne deux
/// choix distincts).
struct AnaNetwork: Hashable {
    let site: String
    let base: IPv4Address
    var prefix: Int = 24

    var subnet: Subnet { Subnet(address: base, prefix: prefix) }

    /// Réseau du choix pour un sous-réseau connu (un /25 ou plus petit : son /24 ; plus grand qu'un /16 : son /16).
    init(site: String, subnet: Subnet) {
        let prefix = min(24, max(AddressPlan.minPrefix, subnet.prefix))
        self.site = site
        self.prefix = prefix
        base = Subnet(address: subnet.network, prefix: prefix).network
    }

    init(site: String, base: IPv4Address, prefix: Int = 24) {
        self.site = site
        self.prefix = prefix
        self.base = Subnet(address: base, prefix: prefix).network
    }
}

/// Note 78 : sous-réseaux, DHCP et plages exclues d'un site, pour le plan d'adressage.
@MainActor
struct AnaAddressing {
    let subnets: [AddressPlanSubnet]
    let dhcp: AddressPlanDHCP
    let dhcpReadAt: Date?
    let exclusions: AddressExclusions

    /// Étendues DHCP des FortiGate du site (toutes celles lues pour les plages libres).
    init(siteKey: String, records: [InvRecord], state: AppState, now: Date) {
        let sites = SiteModel.shared
        let site = sites.site(forKey: siteKey)
        let reports = DHCPScopeStore.shared.sites.filter { site == nil || site?.fortiGateIDs.contains($0.controllerID) == true }.map(\.report)
        let ranges = siteKey == sites.activeKey ? state.ranges : (site?.ranges ?? [])
        subnets = AddressPlanSubnet.list(ranges: ranges, dhcp: reports, records: records)
        dhcp = AddressPlanDHCP(reports: reports, now: now)
        dhcpReadAt = reports.map(\.readAt).max()
        exclusions = sites.exclusions(forKey: siteKey)
    }

    /// Choix du menu « Plage / VLAN » : chaque sous-réseau connu (bloc de /16 à /24).
    func networks(site: String) -> [AnaNetwork] {
        var seen = Set<AnaNetwork>()
        return subnets.map { AnaNetwork(site: site, subnet: $0.subnet) }.filter { seen.insert($0).inserted }
    }
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
    /// Note 78 : plan et « Prochaine IP libre » calculés hors de `body` (voir AnaPlanCache.swift).
    @StateObject private var planCache = AnaAsyncCache<AnaPlanIdentity, AddressPlan>()
    @StateObject private var freeCache = AnaAsyncCache<String, [AnaNextFreeRow]>()

    var body: some View {
        let now = Date()
        let since = now.addingTimeInterval(-period.seconds)
        let inventories = scope.inventories(for: .analyse)
        let multiple = inventories.count > 1
        // Note 78 : sous-réseaux connus de chaque site (plages, étendues DHCP de la FortiGate, /24 des
        // fiches), son DHCP lu et ses plages exclues.
        let addressing = Dictionary(inventories.map { inventory in
            (inventory.key, AnaAddressing(siteKey: inventory.key, records: Array(inventory.store.records.values), state: state, now: now))
        }, uniquingKeysWith: { first, _ in first })
        let networks = inventories.flatMap { addressing[$0.key]?.networks(site: $0.key) ?? [] }
        let wanted = networkChosen ? network : defaultNetwork(networks)
        // Un bloc élargi ou réduit depuis la carte (« Bloc /22 ») reste choisi même s'il n'est pas un sous-réseau connu.
        let chosen = wanted.flatMap { item in inventories.contains { $0.key == item.site } ? item : nil }
        // Site de la carte d'occupation, de la courbe et de la comparaison : celui de la plage choisie.
        let focus = inventories.first { $0.key == chosen?.site } ?? inventories[0]
        let focusRecords = Array(focus.store.records.values)
        let records = chosen.map { network in focusRecords.filter { network.subnet.contains($0.ip) } }
            ?? inventories.flatMap { Array($0.store.records.values) }
        let focusAddressing = addressing[focus.key]
        let recentWindow = max(period.seconds, 7 * 86_400)
        let planInputs = focusAddressing.map { AnaPlanInputs(addressing: $0, records: focusRecords, recentWindow: recentWindow, now: now) }
        let plan = chosen.flatMap { network in
            focusAddressing.flatMap { info in
                planInputs.map { inputs in
                    planCache.value(identity: AnaPlanIdentity(site: focus.key, block: network.subnet), inputs: inputs) {
                        AddressPlan(block: network.subnet, records: focusRecords, dhcp: info.dhcp, exclusions: info.exclusions,
                                    subnets: info.subnets.map(\.subnet), now: now, recentWindow: recentWindow)
                    }
                }
            }
        }
        let alerts = SiteScope.alerts(inventories, since: since)
        let siteName = multiple ? focus.name : nil
        // Plusieurs sites : tuiles et répartitions portent sur le même périmètre, écrit en clair —
        // le /24 choisi d'un site (alertes de ce site), ou tous les sites réunis.
        let tileAlerts = multiple && chosen != nil ? alerts.filter { $0.siteKey == focus.key } : alerts
        let scopeLabel: String? = !multiple ? nil
            : chosen.map { "\(focus.name) · \($0.subnet.description)" }
            ?? "\(inventories.count) sites réunis\u{00A0}: " + inventories.map(\.name).joined(separator: ", ")

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filters(networks: networks, chosen: chosen, inventories: inventories, addressing: addressing, now: now, since: since)
                // Note 79 : le bilan de santé (Trafic) en tête, quand il existe.
                AnaHealthBanner(siteKeys: inventories.map(\.key))
                if let scopeLabel {
                    Label("Indicateurs\u{00A0}: " + scopeLabel, systemImage: "mappin.and.ellipse")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .help("Tuiles et répartitions\u{00A0}: " + scopeLabel
                              + (chosen == nil ? "" : ". La courbe, la carte d’occupation et la comparaison portent sur ce site."))
                }
                tiles(records: records, plan: plan, alerts: tileAlerts.map(\.event), now: now, since: since)
                // Petite fenêtre : courbe et répartitions passent sous la carte d'occupation, qui prend
                // alors toute la largeur (pas de vide à sa droite).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        occupancy(chosen: chosen, plan: plan, allRecords: focusRecords, siteName: siteName,
                                  dhcpReadAt: focusAddressing?.dhcpReadAt, now: now)
                            .frame(width: 680)
                        charts(records: records, snapshots: focus.store.snapshots, siteName: siteName, scope: scopeLabel, since: since)
                            .frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        occupancy(chosen: chosen, plan: plan, allRecords: focusRecords, siteName: siteName,
                                  dhcpReadAt: focusAddressing?.dhcpReadAt, now: now)
                            .frame(maxWidth: .infinity)
                        charts(records: records, snapshots: focus.store.snapshots, siteName: siteName, scope: scopeLabel, since: since)
                    }
                }
                // Note 78 : prochaine IP libre hors étendue DHCP, par sous-réseau du site.
                if let info = focusAddressing, let planInputs {
                    AnaNextFreePanel(rows: freeCache.value(identity: focus.key, inputs: planInputs) {
                        info.subnets.map {
                            AnaNextFreeRow.make($0, records: focusRecords, dhcp: info.dhcp, exclusions: info.exclusions,
                                                subnets: info.subnets.map(\.subnet), now: now, recentWindow: recentWindow)
                        }
                    }, siteName: multiple ? focus.name : nil, dhcpReadAt: info.dhcpReadAt,
                    canReadDHCP: DHCPScopeStore.shared.canRefresh(state: state),
                    onReadDHCP: { DHCPScopeStore.shared.refreshNow(state: state) },
                    onShow: { subnet in
                        network = AnaNetwork(site: focus.key, subnet: subnet)
                        networkChosen = true
                    })
                    .frame(maxWidth: .infinity)
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
    private func occupancy(chosen: AnaNetwork?, plan: AddressPlan?, allRecords: [InvRecord], siteName: String?, dhcpReadAt: Date?,
                           now: Date) -> some View {
        if let chosen, let plan {
            AnaOccupancyPanel(plan: plan, records: allRecords, now: now, siteKey: chosen.site, siteName: siteName,
                              preferredPage: macAddress(in: chosen), dhcpReadAt: dhcpReadAt) { prefix, page in
                network = AnaNetwork(site: chosen.site, base: page, prefix: prefix)
                networkChosen = true
            }
        } else {
            Panel(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    InvPanelTitle("Carte d’occupation")
                    Text("Choisissez un réseau dans « Plage / VLAN » pour afficher la carte de ses adresses (un /24, ou un bloc de /23 à /16 par pages de /24).")
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

    /// Par défaut : le réseau du Mac dans le site actif (le plus précis), sinon le premier.
    /// Captures : NETSCOPE_ANA_PLAGE=10.182.140.0/22 choisit le réseau, NETSCOPE_ANA_BLOC=16 la taille du bloc.
    private func defaultNetwork(_ networks: [AnaNetwork]) -> AnaNetwork? {
        let environment = ProcessInfo.processInfo.environment
        if Launcher.isDemo, let text = environment["NETSCOPE_ANA_PLAGE"], let subnet = try? Subnet(parsing: text) {
            return AnaNetwork(site: sites.activeKey, subnet: subnet)
        }
        var found: AnaNetwork?
        if let address = state.activeInterface?.address {
            found = networks.filter { $0.site == sites.activeKey && $0.subnet.contains(address) }.max { $0.prefix < $1.prefix }
        }
        if Launcher.isDemo, let base = found ?? networks.first, let text = environment["NETSCOPE_ANA_BLOC"],
           let prefix = Int(text), (AddressPlan.minPrefix...24).contains(prefix) {
            return AnaNetwork(site: base.site, base: base.base, prefix: prefix)
        }
        return found ?? networks.first
    }

    /// Adresse du Mac si elle est dans ce réseau (page montrée d'abord dans un bloc).
    private func macAddress(in network: AnaNetwork) -> IPv4Address? {
        guard network.site == sites.activeKey, let address = state.activeInterface?.address, network.subnet.contains(address) else { return nil }
        return address
    }

    // MARK: Filtres

    private func filters(networks known: [AnaNetwork], chosen: AnaNetwork?, inventories: [SiteInventory], addressing: [String: AnaAddressing],
                         now: Date, since: Date) -> some View {
        // Un bloc choisi depuis la carte (« Bloc /16 ») figure aussi dans le menu.
        let networks = known + (chosen.map { known.contains($0) ? [] : [$0] } ?? [])
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
                                    Text(inventory.name + " · " + networkLabel(item, store: inventory.store, addressing: addressing[inventory.key])).tag(Optional(item))
                                }
                            }
                        }
                    } else {
                        ForEach(networks, id: \.self) { item in
                            Text(networkLabel(item, store: inventories[0].store, addressing: addressing[inventories[0].key])).tag(Optional(item))
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

    private func networkLabel(_ network: AnaNetwork, store: InventoryStore, addressing: AnaAddressing?) -> String {
        let base = network.base
        let subnet = network.subnet
        var label = subnet.description
        // Libellé du sous-réseau connu (plage du site, étendue DHCP), sinon de la plage qui le contient
        // (le Scanner n'a que les plages du site actif).
        let known = addressing?.subnets.first { AnaNetwork(site: network.site, subnet: $0.subnet) == network }
        let names = known?.labels ?? []
        if !names.isEmpty {
            label += " · " + names.joined(separator: " · ")
        } else {
            let ranges = network.site == sites.activeKey ? state.ranges : (sites.site(forKey: network.site)?.ranges ?? [])
            if let range = ranges.first(where: { (try? $0.parsed())?.contains(base.next ?? base) == true }) {
                label += " · " + range.label
            } else if let dhcp = known?.dhcpName {
                label += " · " + dhcp
            }
        }
        var vlans = Set(store.records.values.filter { subnet.contains($0.ip) }.compactMap(\.vlan))
        if let vlan = known?.vlan { vlans.insert(vlan) }
        // VLAN déjà nommés par le libellé (« VLAN 60 · Invités ») : pas répétés.
        let unnamed = vlans.filter { !label.contains("VLAN \($0)") }
        if !unnamed.isEmpty { label += " · VLAN " + unnamed.sorted().map(String.init).joined(separator: ", ") }
        if network.prefix < 24 { label += " · \(1 << (24 - network.prefix)) pages" }
        return label
    }

    // MARK: Tuiles

    private func tiles(records: [InvRecord], plan: AddressPlan?, alerts: [InvEvent], now: Date, since: Date) -> some View {
        let added = records.filter { $0.firstSeen >= since && !$0.isImported }.count
        let lost = records.filter { !$0.isOnline && ($0.offlineSince ?? .distantPast) >= since }.count
        let online = records.filter(\.isOnline).count
        let recentOffline = records.filter { !$0.isOnline && now.timeIntervalSince($0.lastSeen) <= 7 * 86_400 }.count
        let conflicts = Set(records.filter(\.hasConflict).map(\.ip)).sorted()
        let pending = alerts.filter { $0.status == .aTraiter && $0.severity != .info }.count
        // Même plan que la carte d'occupation affichée dessous (fiches, baux et réservations DHCP).
        let occupancy = plan

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
                            Text("\(occupancy.used)/\(RegFormat.count(occupancy.hosts))").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        ProgressBar(fraction: occupancy.usage, color: percent >= 75 ? Theme.warning : Theme.accent)
                    }
                } else {
                    Text("Choisissez un réseau").font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.top, 6)
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
