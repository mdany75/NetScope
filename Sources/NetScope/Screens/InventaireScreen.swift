import AppKit
import NetScopeCore
import SwiftUI

/// Vues sauvegardées de l'inventaire.
enum InvView: String, CaseIterable, Hashable {
    case tous, nonIdentifies, disparus, favoris
    /// Note 95 : imprimantes avec un relevé des consommables, du niveau le plus bas au plus haut.
    case imprimantes
    /// Note 98 : onduleurs avec un relevé, sur batterie d'abord, puis l'autonomie la plus courte.
    case onduleurs
    /// Note 10 : appareils archivés (restaurables).
    case archives

    var label: String {
        switch self {
        case .tous: return "Tous"
        case .nonIdentifies: return "Non identifiés"
        case .disparus: return "Disparus > 30 j"
        case .favoris: return "Favoris"
        case .imprimantes: return "Imprimantes"
        case .onduleurs: return "Onduleurs"
        case .archives: return "Archivés"
        }
    }

    /// `excluded` : fiche d'une plage exclue du site (note 82), jamais « disparue ».
    func includes(_ record: InvRecord, now: Date, excluded: Bool = false) -> Bool {
        switch self {
        case .tous: return true
        case .nonIdentifies: return record.isUnidentified
        case .disparus: return record.isGone(now: now, excluded: excluded)
        case .favoris: return record.annotations.isFavorite
        case .imprimantes, .onduleurs, .archives: return true
        }
    }
}

/// Note 10 : filtres du menu « Filtrer » (étiquettes libres, garantie, origine, même MAC ailleurs).
struct InvFilter: Equatable {
    var tags: Set<String> = []
    /// Garantie bientôt échue.
    var warranty = false
    /// Ajoutés à la main.
    var manual = false
    /// Même MAC dans un autre site.
    var shared = false

    var count: Int { tags.count + (warranty ? 1 : 0) + (manual ? 1 : 0) + (shared ? 1 : 0) }
    var isActive: Bool { count > 0 }

    func matches(_ row: SiteScopedRecord, now: Date, shared sharedMACs: [MACAddress: [String]]) -> Bool {
        let record = row.record
        if !tags.isEmpty {
            let own = Set(record.annotations.tags.map { $0.lowercased() })
            guard tags.contains(where: { own.contains($0.lowercased()) }) else { return false }
        }
        if warranty, record.annotations.hardware?.warranty(now: now).isAlert != true { return false }
        if manual, !record.isManual { return false }
        if shared, record.mac.flatMap({ sharedMACs[$0] }) == nil { return false }
        return true
    }
}

/// Élément de la tuile « Alertes d'inventaire » : conflit IP, garantie bientôt échue, même MAC sur deux sites.
private struct InvAlertItem: Identifiable {
    enum Kind { case conflict, warranty, shared }
    let kind: Kind
    let site: String
    let siteName: String
    let key: String?
    let text: String
    let detail: String
    /// Même MAC sur plusieurs sites : nombre de sites (puce « 3 SITES »).
    var siteCount = 2
    var id: String { "\(kind)|" + site + "|" + (key ?? text) }
}

/// Conflit IP d'un site (tuile « Alertes d'inventaire »).
private struct InvSiteConflict: Identifiable {
    let site: String
    let siteName: String
    let ip: IPv4Address
    let key: String?
    var id: String { site + "|" + ip.description }
}

/// Doublons probables d'un site (jamais entre deux sites).
private struct InvSiteDuplicate: Identifiable {
    let site: String
    let pair: InvDuplicate
    var id: String { site + "|" + pair.id }
}

/// Écran `Screen.inventaire` : base permanente des appareils, fiche éditable et chronologie
/// (croquis docs/croquis/Inventaire.dc.html). Menu « Site ▾ » : un, plusieurs ou tous les sites,
/// une ligne par fiche et par site ; sélection multiple et suppression (⌫, clic droit, barre
/// d'outils), annulable par ⌘Z.
struct InventaireScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared
    @ObservedObject private var scope = SiteScopeStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @Environment(\.undoManager) private var undoManager
    /// Lignes choisies (identifiants « site|fiche »).
    @State private var selection: Set<String> = []
    /// Première ligne choisie à l'ouverture (une seule fois).
    @State private var initialPick = false

    @State private var view: InvView = .tous
    /// Note 95 : relevés des consommables (vue « Imprimantes »).
    @ObservedObject private var printerStore = PrinterStore.shared
    /// Note 98 : relevés des onduleurs (vue « Onduleurs »).
    @ObservedObject private var upsStore = UPSStore.shared
    @StateObject private var table = InvTable.makeModel()
    @State private var mergeOpen = false
    @State private var ignoredDuplicates: Set<String> = []
    @State private var importing = false
    @State private var exportDocument: InvCSVDocument?
    @State private var exporting = false
    /// Note 78 : format du dernier export (NetScope, NetBox, GLPI, Snipe-IT).
    @State private var exportFormat = InvExportFormat.netscope
    /// Note 10 : filtres, feuille d'ajout à la main, MAC vues sur plusieurs sites (clés des sites).
    @State private var filter = InvFilter()
    @State private var manualMode: InvManualMode?
    @State private var shared: [MACAddress: [String]] = [:]
    @State private var demoApplied = false

    private var conflictChip: some View {
        Text("CONFLIT IP").font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.critical)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.criticalSoft))
            .fixedSize()
    }

    /// Adresse en conflit ; avec plusieurs sites, suivie du site (la même IP peut exister sur deux sites).
    @ViewBuilder
    private func conflictIP(_ ip: IPv4Address, site: String?, stacked: Bool = false) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 1) {
                Text(ip.description).font(Theme.mono(12)).foregroundStyle(Theme.text).fixedSize()
                if let site { Text(site).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            }
        } else {
            HStack(spacing: 4) {
                Text(ip.description).font(Theme.mono(12)).foregroundStyle(Theme.text).fixedSize()
                if let site {
                    Text("· " + site).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                }
            }
        }
    }

    var body: some View {
        let now = Date()
        let inventories = scope.inventories(for: .inventaire)
        let multiple = inventories.count > 1
        let archiveMode = view == .archives
        let all = SiteScope.records(inventories)
        let records = all.map(\.record)
        // Note 10 : vue « Archivés » : les fiches archivées des sites affichés.
        let archived = archiveMode ? inventories.flatMap { inventory in
            inventory.store.archived.map { SiteScopedRecord(siteKey: inventory.key, siteName: inventory.name, record: $0.record) }
        } : []
        let archiveDates = archiveMode ? Dictionary(inventories.flatMap { inventory in
            inventory.store.archived.map { (SiteScope.id(site: inventory.key, key: $0.record.key), $0.date) }
        }, uniquingKeysWith: { a, _ in a }) : [:]
        let sharedNames = shared.mapValues { $0.map { sites.name(forKey: $0) } }
        // Note 26 : recherche multiple, analysée une fois pour toutes les fiches (préfixe site:).
        let query = state.searchQuery(for: .inventaire)
        // Notes 31 et 33 : filtre transmis (groupe de la Carte, port de switch), ensemble exact d'appareils.
        let navFilter = state.navFilters[.inventaire]
        let filtered = InvTable.sorted((archiveMode ? archived : all).filter {
            view.includes($0.record, now: now, excluded: sites.exclusions(forKey: $0.siteKey).contains($0.record.ip)) && query.matches($0)
                && (archiveMode || (navFilter?.matches($0.record, site: $0.siteKey) ?? true))
                && filter.matches($0, now: now, shared: shared)
        }, by: table.sortOrder)
        // Note 95 : vue « Imprimantes » : fiches avec un relevé, du consommable le plus bas au plus haut.
        let printers = view == .imprimantes ? InvPrinters.rows(filtered, store: printerStore) : []
        let units = view == .onduleurs ? InvUPS.rows(filtered, store: upsStore) : []
        let rows = view == .imprimantes ? printers.map(\.row) : view == .onduleurs ? units.map(\.row) : filtered
        let duplicates = inventories.flatMap { inventory in
            inventory.store.probableDuplicates().map { InvSiteDuplicate(site: inventory.key, pair: $0) }
        }.filter { !ignoredDuplicates.contains($0.id) }
        let chosen = effectiveSelection(rows)
        let selectedRows = rows.filter { chosen.contains($0.id) }
        let excluded = inventories.flatMap { inventory in
            inventory.store.excluded.map { InvExcludedRow(site: inventory.key, siteName: inventory.name, exclusion: $0) }
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(now: now, inventories: inventories)
                tiles(records, now: now, inventories: inventories)
                if mergeOpen { mergePanel(duplicates, inventories: inventories) }
                if view == .imprimantes {
                    InvPrinterPanel(printers: printers, multipleSites: multiple) { id in selection = [id] }
                }
                if view == .onduleurs {
                    InvUPSPanel(units: units, multipleSites: multiple) { id in selection = [id] }
                }
                InvTable(rows: rows, total: archiveMode ? archived.count : records.count, selection: selectionBinding(rows), table: table, now: now,
                         inventoryEmpty: records.isEmpty, siteNames: inventories.map(\.name),
                         unreadableNames: inventories.filter { model.unreadableSites.contains($0.key) }.map(\.name), excluded: excluded,
                         actions: rowActions(rows), archiveMode: archiveMode, archiveDates: archiveDates,
                         filterActive: filter.isActive, clearFilters: { filter = InvFilter() }, sharedSites: sharedNames,
                         accessory: AnyView(tableAccessory(inventories: inventories)))
                if selectedRows.count > 1 {
                    selectionPanel(selectedRows, rows: rows, archiveMode: archiveMode)
                } else if let row = selectedRows.first {
                    if archiveMode, let entry = model.inventory(for: row.siteKey).archivedEntry(row.record.key) {
                        InvArchivePanel(entry: entry, siteName: row.siteName, now: now,
                                        onRestore: { restore([row.id]) }, onPurge: { confirmPurge([row.id], rows: rows) })
                            .id(row.id)
                    } else {
                        InvDetail(record: row.record, events: model.inventory(for: row.siteKey).events(for: row.record.key), now: now,
                                  siteKey: row.siteKey,
                                  otherSites: row.record.mac.flatMap { sharedNames[$0] }?.filter { $0 != row.siteName } ?? [],
                                  onCreated: { site, key in select(site: site, key: key) })
                            .id(row.id)
                    }
                } else if !rows.isEmpty {
                    Text("Choisissez un appareil dans le tableau pour ouvrir sa fiche.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 4)
                }
                help
            }
            .searchResults(rows.count, "fiche", "fiches")
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .standardSiteColumn(table, multiple: multiple)
        .screenToolbar {
            StandardColumnsMenu(model: table)
            addMenu(inventories: inventories)
            // Icône seule (comme la corbeille du Finder) : la barre d'outils tient en petite fenêtre.
            Button {
                if archiveMode { confirmPurge(Array(chosen), rows: rows) } else { confirmRemove(Array(chosen), rows: rows) }
            } label: { Label("Retirer", systemImage: "trash").labelStyle(.iconOnly) }
                .buttonStyle(.secondary)
                .accessibilityLabel(archiveMode ? "Supprimer définitivement" : "Retirer de l’inventaire")
                .disabled(chosen.isEmpty)
                .help(archiveMode ? "Supprimer définitivement les appareils archivés sélectionnés (⌫)"
                      : chosen.count > 1 ? "Retirer les \(chosen.count) appareils sélectionnés de l’inventaire\u{00A0}: archiver ou supprimer (⌫)"
                      : "Retirer l’appareil sélectionné de l’inventaire\u{00A0}: archiver ou supprimer (⌫)")
            Button { importing = true } label: { Label("Importer CSV", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
                .help("Importer un CSV dans l’inventaire du site actif «\u{00A0}\(sites.activeName)\u{00A0}»")
            // Note 78 : un choix de format (NetScope, NetBox, GLPI, Snipe-IT) pour les fiches affichées.
            Menu {
                ForEach(InvExportFormat.ordered) { format in
                    Button(format.label) {
                        exportFormat = format
                        let text = format == .netscope
                            ? InvCSV.export(rows.map(\.record), sites: multiple ? rows.map(\.siteName) : nil)
                            : InvExternalCSV.export(rows.map(\.record), format: format, sites: rows.map(\.siteName))
                        exportDocument = InvCSVDocument(text: text)
                        exporting = true
                    }
                    .help(format.help)
                    if format == .netscope { Divider() }
                }
            } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                .fixedSize()
                .disabled(rows.isEmpty)
                .help("Exporter les \(rows.count) fiches affichées en CSV\u{00A0}: format NetScope, ou pour NetBox, GLPI et Snipe-IT")
            Button { mergeOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Label("Fusionner les doublons", systemImage: "arrow.triangle.merge")
                    if !duplicates.isEmpty {
                        Text("\(duplicates.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accentStrong)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Theme.panel))
                    }
                }
            }
            .buttonStyle(.primary)
        }
        .feedsInventory(state)
        .onAppear {
            adoptRequestedArchives()
            adoptRequestedSelection()
            pickFirstRowIfNeeded(rows)
            refreshShared()
            applyDemoView()
        }
        .onChange(of: model.store.lastMerge) { _, _ in refreshShared() }
        .onChange(of: model.siteKey) { _, _ in refreshShared() }
        .onChange(of: view) { _, _ in selection = [] }
        .onChange(of: model.requestedArchives) { _, _ in adoptRequestedArchives() }
        .sheet(item: $manualMode) { mode in
            InvManualSheet(mode: mode, onDone: { key, site in select(site: site, key: key) }, dismiss: { manualMode = nil })
        }
        // Captures (NETSCOPE_INV_VUE=feuille) : la feuille d'ajout dessinée dans la page (une vraie
        // feuille ne se capture pas hors écran).
        .overlay(alignment: .top) {
            if InvManualDemo.view == "feuille" {
                ZStack(alignment: .top) {
                    Color(nsColor: .shadowColor).opacity(0.18).ignoresSafeArea()
                    InvManualSheet(mode: .add(site: model.siteKey), inline: true, dismiss: {})
                        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                        .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                        .padding(.top, 8)
                }
            }
        }
        .onChange(of: rows.first?.id) { _, _ in pickFirstRowIfNeeded(rows) }
        .onChange(of: model.selectedKey) { _, _ in adoptRequestedSelection() }
        // Note 34 : la fiche montrée est retenue, pour que Retour la rende.
        .onChange(of: selection) { _, ids in
            guard ids.count == 1, let id = ids.first, let parts = SiteScope.split(id) else { return }
            state.shownFocus[.inventaire] = .record(site: parts.site, key: parts.key)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            switch result {
            case .success(let url):
                do {
                    model.show(model.importCSV(try InvFiles.readText(url)))
                } catch {
                    model.show("Lecture impossible : \(error.localizedDescription)")
                }
            case .failure(let error):
                model.show("Import annulé : \(error.localizedDescription)")
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "inventaire\(exportFormat.fileSuffix)-\(InvFormat.day(Date())).csv") { result in
            if case .success(let url) = result {
                let target = exportFormat == .netscope ? "" : " pour " + exportFormat.label.replacingOccurrences(of: "CSV pour ", with: "")
                model.show("Export CSV\(target) : \(url.lastPathComponent) (\(rows.count) lignes)")
            }
        }
    }

    // MARK: En-tête

    private var viewPicker: some View {
        Picker("Vue de l’inventaire", selection: $view) {
            ForEach(InvView.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func header(now: Date, inventories: [SiteInventory]) -> some View {
        let caption = inventories.count > 1 ? "Tous les appareils jamais vus sur ces \(inventories.count) sites" : "Tous les appareils jamais vus sur ce site"
        return HStack(spacing: 12) {
            // Note 28 : l'inventaire est propre à chaque site ; le menu choisit un, plusieurs ou tous les sites.
            SiteScopeMenu(screen: .inventaire).layoutPriority(1)
            // Segments égaux, plus larges que le plus long libellé : « Disparus > 30 j » n'est pas serré ;
            // en petite fenêtre (note 95, six vues), les segments prennent la largeur de leur libellé.
            ViewThatFits(in: .horizontal) {
                viewPicker.frame(width: 680).fixedSize()
                viewPicker.fixedSize()
                viewPicker.frame(minWidth: 420)
            }
            // Petite fenêtre : seule la date de fusion reste, sinon rien (jamais une phrase coupée ;
            // la légende complète reste au survol).
            ViewThatFits(in: .horizontal) {
                Text(caption + " · " + mergeCaption(now: now, inventories: inventories)).fixedSize()
                Text(mergeCaption(now: now, inventories: inventories).prefix(1).uppercased() + mergeCaption(now: now, inventories: inventories).dropFirst()).fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            .font(Theme.small)
            .foregroundStyle(Theme.textSecondary)
            .help(caption + " · " + mergeCaption(now: now, inventories: inventories))
            Spacer(minLength: 0)
            if let toast = model.toast {
                InvToast(text: toast, undo: model.toastUndo ? { undoManager?.undo() } : nil)
            }
        }
    }

    private func mergeCaption(now: Date, inventories: [SiteInventory]) -> String {
        guard let last = inventories.compactMap(\.store.lastMerge).max() else { return "aucun scan fusionné pour l’instant" }
        let when = InvFormat.relative(last, now: now)
        return "dernier scan fusionné "
            + (when == "À l’instant" ? "à l’instant" : when.replacingOccurrences(of: "Il y a", with: "il y a"))
    }

    // MARK: Tuiles

    private func tiles(_ records: [InvRecord], now: Date, inventories: [SiteInventory]) -> some View {
        let today = Calendar.current.startOfDay(for: now)
        let seenToday = records.filter { $0.lastSeen >= today && !$0.isAwaitingScan }.count
        let manual = records.filter(\.isManual).count
        let online = records.filter(\.isOnline).count
        let unidentified = records.filter(\.isUnidentified).count
        // Note 82 : les fiches des plages exclues ne sont plus sondées, donc jamais « disparues ».
        let gone = inventories.reduce(0) { total, inventory in
            let excluded = sites.exclusions(forKey: inventory.key)
            return total + inventory.store.records.values.filter { $0.isGone(now: now, excluded: excluded.contains($0.ip)) }.count
        }
        // Conflits de chaque site (jamais une IP d'un site comparée à celle d'un autre).
        let conflicts = inventories.flatMap { inventory in inventory.store.conflictIPs.sorted().map { InvSiteConflict(site: inventory.key, siteName: inventory.name, ip: $0, key: inventory.store.record(forIP: $0)?.key) } }
        let multiple = inventories.count > 1
        // Note 10 : garanties bientôt échues et MAC vues sur plusieurs sites, après les conflits.
        let others = otherAlerts(inventories, now: now)
        let room = max(0, 3 - min(conflicts.count, 3))

        return HStack(alignment: .top, spacing: 12) {
            InvTile(title: "Appareils connus", value: "\(records.count)",
                    subtitle: manual > 0 ? "Toutes plages confondues\u{00A0}· \(manual)\u{00A0}ajouté\(manual > 1 ? "s" : "")\u{00A0}à la main" : "Toutes plages confondues") { view = .tous }
            InvTile(title: "Vus aujourd’hui", value: "\(seenToday)", // Plusieurs sites : chaque site a son propre dernier scan (pas forcément aujourd'hui).
                    subtitle: multiple ? "\(online) en ligne au dernier scan de chaque site" : "\(online) en ligne au dernier scan",
                    valueColor: Theme.success)
            InvTile(title: "Non identifiés", value: "\(unidentified)", subtitle: "MAC aléatoire ou empreinte insuffisante",
                    valueColor: Theme.warning) { view = .nonIdentifies }
            InvTile(title: "Disparus", value: "\(gone)", subtitle: "Sans réponse depuis plus de 30 jours",
                    valueColor: Theme.textSecondary) { view = .disparus }
            InvTile(title: "Alertes d’inventaire", value: "") {
                VStack(alignment: .leading, spacing: 5) {
                    if conflicts.isEmpty && others.isEmpty {
                        Text("Aucun conflit IP actif").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(conflicts.prefix(3))) { conflict in
                        let ip = conflict.ip
                        let site = multiple ? conflict.siteName : nil
                        Button {
                            if let key = conflict.key { selection = [SiteScope.id(site: conflict.site, key: key)] }
                        } label: {
                            // Petite fenêtre : l'adresse passe sous la puce plutôt que de la couper.
                            // Encore plus étroit (plusieurs sites) : le site passe sous l'adresse.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) { conflictChip; conflictIP(ip, site: site) }
                                VStack(alignment: .leading, spacing: 2) { conflictChip; conflictIP(ip, site: site) }
                                VStack(alignment: .leading, spacing: 2) { conflictChip; conflictIP(ip, site: site, stacked: true) }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(site.map { "Conflit IP \(ip.description) sur le site «\u{00A0}\($0)\u{00A0}»" } ?? "Conflit IP \(ip.description)")
                    }
                    ForEach(Array(others.prefix(room))) { item in
                        Button {
                            if let key = item.key { selection = [SiteScope.id(site: item.site, key: key)] }
                        } label: {
                            // Petite fenêtre : le texte passe sous la puce, puis sur deux lignes (jamais coupé).
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) { alertChip(item.kind, sites: item.siteCount); Text(item.text).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1) }
                                VStack(alignment: .leading, spacing: 2) { alertChip(item.kind, sites: item.siteCount); Text(item.text).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1) }
                                VStack(alignment: .leading, spacing: 2) {
                                    alertChip(item.kind, sites: item.siteCount)
                                    Text(item.text).font(Theme.small).foregroundStyle(Theme.text)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(item.detail)
                    }
                    if conflicts.count + others.count > 3 {
                        Text("+\(conflicts.count + others.count - 3) autre\(conflicts.count + others.count - 3 > 1 ? "s" : "")")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Doublons

    private func mergePanel(_ duplicates: [InvSiteDuplicate], inventories: [SiteInventory]) -> some View {
        let total = inventories.reduce(0) { $0 + $1.store.count }
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Doublons probables",
                              subtitle: duplicates.isEmpty ? "Aucun doublon restant"
                                  : "\(duplicates.count) paire\(duplicates.count > 1 ? "s" : "") détectée\(duplicates.count > 1 ? "s" : "") sur \(total) fiches") {
                    Button("Fermer") { mergeOpen = false }.buttonStyle(.secondary)
                }
                ForEach(duplicates) { item in
                    let pair = item.pair
                    let store = model.inventory(for: item.site)
                    if let keep = store.record(pair.keep), let other = store.record(pair.absorb) {
                        HStack(alignment: .top, spacing: 12) {
                            duplicateCard("Fiche conservée", keep)
                            duplicateCard("Fiche à rattacher", other)
                            VStack(alignment: .leading, spacing: 10) {
                                // Note 78 : rapprochement d'une MAC aléatoire, proposé et jamais fait d'office.
                                if let criterion = pair.randomMAC {
                                    Chip(text: criterion == .serial ? "MAC aléatoire · n° de série" : "MAC aléatoire · nom d’hôte", tone: .accent)
                                }
                                Text("Critères : " + pair.reason)
                                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button("Fusionner dans .\(keep.ip.octets.3)") {
                                        model.absorb(pair, site: item.site)
                                        model.show("Fiches fusionnées : \(other.displayName) rattaché à \(keep.ip)")
                                    }
                                    .buttonStyle(.primary)
                                    Button("Ignorer") { ignoredDuplicates.insert(item.id) }.buttonStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func duplicateCard(_ title: String, _ record: InvRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(record.displayName).font(Theme.bodySemibold)
            Text("\(record.ip.description) · \(record.mac?.formatted(.upperColon) ?? "—") · vu \(InvFormat.relative(record.lastSeen).lowercased())")
                .font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    // MARK: Sélection

    /// Lignes choisies parmi celles affichées. Jamais de cible implicite : sans sélection (tout
    /// désélectionné, après une suppression, lignes choisies masquées par la recherche), rien n'est
    /// choisi et « Supprimer » est désactivé.
    private func effectiveSelection(_ rows: [SiteScopedRecord]) -> Set<String> {
        selection.intersection(Set(rows.map(\.id)))
    }

    /// À l'ouverture de l'écran, la première ligne est choisie (et surlignée) pour montrer sa fiche.
    private func pickFirstRowIfNeeded(_ rows: [SiteScopedRecord]) {
        guard !initialPick, let first = rows.first else { return }
        initialPick = true
        if selection.isEmpty { selection = [first.id] }
    }

    private func selectionBinding(_ rows: [SiteScopedRecord]) -> Binding<Set<String>> {
        Binding(get: { effectiveSelection(rows) }, set: { selection = $0 })
    }

    /// Fiche demandée par un autre écran (Scanner, Analyse « Voir », Carte) : elle devient la
    /// ligne choisie ; son site est ajouté aux sites affichés s'il n'y était pas.
    private func adoptRequestedSelection() {
        if let key = model.selectedKey {
            let site = model.selectedSite ?? model.siteKey
            scope.include(site, in: .inventaire)
            selection = [SiteScope.id(site: site, key: key)]
            model.selectedKey = nil
            model.selectedSite = nil
        } else if selection.isEmpty,
                  let fromScanner = state.selectedDeviceID.flatMap(IPv4Address.init).flatMap({ model.store.record(forIP: $0) }) {
            selection = [SiteScope.id(site: model.siteKey, key: fromScanner.key)]
        }
    }

    /// Plusieurs lignes choisies : leur nombre, leurs sites et « Supprimer de l'inventaire ».
    private func selectionPanel(_ chosen: [SiteScopedRecord], rows: [SiteScopedRecord], archiveMode: Bool) -> some View {
        Panel(padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checklist").font(.system(size: 20)).foregroundStyle(Theme.accentStrong)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(chosen.count) appareils sélectionnés").font(Theme.bodySemibold)
                    Text((Set(chosen.map(\.siteKey)).count > 1 ? "" : "Site ") + InvDialogs.siteSummary(chosen) + " · ⌘-clic ou ⇧-clic pour changer la sélection, ⌘A pour tout choisir")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Tout désélectionner") { selection = [] }.buttonStyle(.secondary)
                if archiveMode {
                    Button { restore(chosen.map(\.id)) } label: { Label("Restaurer", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.secondary)
                    Button(role: .destructive) { confirmPurge(chosen.map(\.id), rows: rows) } label: {
                        Label("Supprimer définitivement…", systemImage: "trash")
                    }
                    .buttonStyle(.secondary)
                } else {
                    InvMoveMenu(rows: chosen) { site in move(chosen.map(\.id), to: site, rows: rows) }
                        .menuStyle(.button)
                        .fixedSize()
                    Button(role: .destructive) { confirmRemove(chosen.map(\.id), rows: rows) } label: {
                        Label("Retirer de l’inventaire…", systemImage: "trash")
                    }
                    .buttonStyle(.secondary)
                }
            }
        }
    }

    // MARK: Note 10 : ajout, filtres, alertes

    private func rowActions(_ rows: [SiteScopedRecord]) -> InvRowActions {
        InvRowActions(favorite: { model.toggleFavorite($0.record.key, site: $0.siteKey) },
                      delete: { confirmRemove($0, rows: rows) },
                      restore: { restore($0) },
                      purge: { confirmPurge($0, rows: rows) },
                      move: { ids, site in move(ids, to: site, rows: rows) },
                      edit: { manualMode = .edit(site: $0.siteKey, key: $0.record.key) },
                      duplicate: { row in
                          guard let copy = model.duplicate(row.record.key, site: row.siteKey) else { return }
                          model.show("Copie créée\u{00A0}: \(model.inventory(for: row.siteKey).record(copy)?.displayName ?? "")")
                          select(site: row.siteKey, key: copy)
                      })
    }

    /// Site visé par « Ajouter » et l'option d'ajout automatique : le site affiché s'il est seul,
    /// sinon le site actif.
    private func targetSite(_ inventories: [SiteInventory]) -> SiteInventory? {
        inventories.count == 1 ? inventories.first : inventories.first { $0.key == model.siteKey } ?? inventories.first
    }

    /// Bouton « Ajouter » : un appareil à la main (clic), ou le menu (appareils du dernier scan,
    /// ajout automatique du site).
    private func addMenu(inventories: [SiteInventory]) -> some View {
        let target = targetSite(inventories)
        let site = target?.key ?? model.siteKey
        let name = target?.name ?? sites.activeName
        let missing = model.notInInventory(state.devices)
        let auto = target?.store.autoAdd ?? true
        return Menu {
            Button("Ajouter un appareil à la main…") { manualMode = .add(site: site) }
            // Le dernier scan est celui du site actif : ses appareils vont dans l'inventaire du site actif.
            if site != model.siteKey {
                Button("Appareils du dernier scan\u{00A0}: seulement pour le site actif «\u{00A0}\(sites.activeName)\u{00A0}»") {}
                    .disabled(true)
            } else {
                Button(missing.isEmpty ? "Appareils du dernier scan\u{00A0}: tous dans l’inventaire"
                       : "Ajouter les \(missing.count) appareil\(missing.count > 1 ? "s" : "") du dernier scan hors inventaire") {
                    model.addToInventory(missing)
                }
                .disabled(missing.isEmpty)
            }
            Divider()
            Toggle("Ajouter automatiquement les appareils scannés («\u{00A0}\(name)\u{00A0}»)", isOn: Binding(get: { auto }, set: { model.setAutoAdd($0, site: site) }))
        } label: {
            Label("Ajouter", systemImage: "plus")
        } primaryAction: {
            manualMode = .add(site: site)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Ajouter un appareil à la main (absent des scans)\u{00A0}; flèche\u{00A0}: appareils du dernier scan et ajout automatique")
    }

    /// Accessoire de l'en-tête du tableau : ajout automatique désactivé, menu « Filtrer ».
    @ViewBuilder
    private func tableAccessory(inventories: [SiteInventory]) -> some View {
        let manualOff = inventories.filter { !$0.store.autoAdd }
        HStack(spacing: 8) {
            if !manualOff.isEmpty, view != .archives {
                let missing = model.notInInventory(state.devices).count
                Label(manualOff.count == 1 && inventories.count == 1 ? "Ajout manuel" + (missing > 0 && manualOff.contains { $0.key == model.siteKey } ? " · \(missing) hors inventaire" : "")
                      : "Ajout manuel\u{00A0}: \(manualOff.map(\.name).joined(separator: ", "))", systemImage: "hand.raised")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .help("Ajout automatique des appareils scannés désactivé\u{00A0}: «\u{00A0}Ajouter à l’inventaire\u{00A0}» depuis le Scanner (clic droit), ou Ajouter ▾ › appareils du dernier scan.")
            }
            filterMenu(inventories: inventories)
        }
    }

    private func filterMenu(inventories: [SiteInventory]) -> some View {
        var tags: [String] = []
        for inventory in inventories {
            for tag in inventory.store.allTags where !tags.contains(where: { $0.lowercased() == tag.lowercased() }) { tags.append(tag) }
        }
        tags.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return Menu {
            Section("Étiquettes") {
                if tags.isEmpty { Text("Aucune étiquette dans ces fiches") }
                ForEach(tags, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(get: { filter.tags.contains(tag) }, set: { on in
                        if on { filter.tags.insert(tag) } else { filter.tags.remove(tag) }
                    }))
                }
            }
            Section("Fiche") {
                Toggle("Garantie bientôt échue (\(InvHardware.warrantySoonDays)\u{00A0}j)", isOn: $filter.warranty)
                Toggle("Ajoutés à la main", isOn: $filter.manual)
                Toggle("Même MAC sur un autre site", isOn: $filter.shared)
            }
            Divider()
            Button("Retirer les filtres") { filter = InvFilter() }.disabled(!filter.isActive)
        } label: {
            Label(filter.isActive ? "Filtrer (\(filter.count))" : "Filtrer", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(Theme.small)
        }
        .menuStyle(.button)
        .buttonStyle(.ghost)
        .fixedSize()
        .help("Filtrer par étiquette, garantie bientôt échue, origine ou MAC vue sur un autre site")
    }

    private func otherAlerts(_ inventories: [SiteInventory], now: Date) -> [InvAlertItem] {
        var items: [InvAlertItem] = []
        for inventory in inventories {
            for record in inventory.store.expiringWarranties(now: now) {
                let state = record.annotations.hardware?.warranty(now: now) ?? .unknown
                items.append(InvAlertItem(kind: .warranty, site: inventory.key, siteName: inventory.name, key: record.key,
                                          text: record.displayName + " · " + InvWarrantyPill.shortLabel(state).lowercased(),
                                          detail: state.label + " · " + record.displayName + (inventories.count > 1 ? " (\(inventory.name))" : "")))
            }
        }
        for inventory in inventories {
            for record in inventory.store.sortedRecords {
                guard let mac = record.mac, let keys = shared[mac] else { continue }
                let others = keys.filter { $0 != inventory.key }.map { sites.name(forKey: $0) }
                guard !others.isEmpty else { continue }
                items.append(InvAlertItem(kind: .shared, site: inventory.key, siteName: inventory.name, key: record.key,
                                          text: record.displayName + " · aussi à " + others.joined(separator: ", "),
                                          detail: "Même MAC \(mac.formatted(.upperColon)) dans l’inventaire de «\u{00A0}\(others.joined(separator: "\u{00A0}», «\u{00A0}"))\u{00A0}»\u{00A0}: fiches distinctes, jamais fusionnées",
                                          siteCount: others.count + 1))
            }
        }
        return items
    }

    private func alertChip(_ kind: InvAlertItem.Kind, sites: Int = 2) -> some View {
        let (text, fg, bg): (String, Color, Color) = {
            switch kind {
            case .conflict: return ("CONFLIT IP", Theme.critical, Theme.criticalSoft)
            case .warranty: return ("GARANTIE", Theme.warning, Theme.warningSoft)
            case .shared: return ("\(sites)\u{00A0}SITES", Theme.warning, Theme.warningSoft)
            }
        }()
        return Text(text).font(.system(size: 10, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(bg))
            .fixedSize()
    }

    private func refreshShared() {
        shared = model.sharedMACs()
    }

    /// Choisit une fiche (après un ajout ou une copie) : vue « Tous », son site affiché.
    private func select(site: String, key: String) {
        scope.include(site, in: .inventaire)
        if view == .archives || !view.includes(model.inventory(for: site).record(key) ?? InvRecord(key: key, mac: nil, ip: IPv4Address(0), firstSeen: Date(), lastSeen: Date()), now: Date()) {
            view = .tous
        }
        DispatchQueue.main.async { selection = [SiteScope.id(site: site, key: key)] }
    }

    /// « Voir les archives » demandé ailleurs (Réglages › Inventaire du site).
    private func adoptRequestedArchives() {
        guard model.requestedArchives else { return }
        model.requestedArchives = false
        view = .archives
    }

    /// Captures (NETSCOPE_INV_VUE) : vue « Archivés », filtre des garanties, fiche ajoutée à la main.
    private func applyDemoView() {
        guard !demoApplied, let wanted = InvManualDemo.view else { return }
        demoApplied = true
        switch wanted {
        case "archives":
            view = .archives
            DispatchQueue.main.async {
                if let first = model.store.archived.first { selection = [SiteScope.id(site: model.siteKey, key: first.record.key)] }
            }
        case "garanties":
            filter.warranty = true
        case "imprimantes":
            view = .imprimantes
        case "onduleurs":
            view = .onduleurs
        case "doublons":
            // Note 78 : doublons probables, dont les MAC aléatoires rapprochées.
            mergeOpen = true
        case "materiel":
            // Note 60 : colonnes Modèle et Firmware, fiche du switch d'étage (numéro qui diffère) ou
            // de l'appareil NETSCOPE_INV_IP (ex. 10.182.122.102 : numéro à reprendre).
            for id in ["modele", "firmware", "serie"] { table.setAutomaticVisibility(true, id) }
            let ip = ProcessInfo.processInfo.environment["NETSCOPE_INV_IP"].flatMap(IPv4Address.init) ?? IPv4Address("10.182.122.3")!
            if let record = model.store.record(forIP: ip) {
                DispatchQueue.main.async { selection = [SiteScope.id(site: model.siteKey, key: record.key)] }
            }
        case "rustdesk":
            // Note 6 : fiche d'un poste avec son ID RustDesk (Poste réception, ou NETSCOPE_INV_IP).
            let ip = ProcessInfo.processInfo.environment["NETSCOPE_INV_IP"].flatMap(IPv4Address.init) ?? IPv4Address("10.182.122.146")!
            if let record = model.store.record(forIP: ip) {
                DispatchQueue.main.async { selection = [SiteScope.id(site: model.siteKey, key: record.key)] }
            }
        case "manuel":
            // Filtre « Ajoutés à la main » : la ligne choisie reste visible (jamais scannée, elle
            // serait tout en bas du tri par dernière vue, hors de la partie visible du tableau).
            filter.manual = true
            if let manual = model.store.sortedRecords.first(where: \.isManual) {
                DispatchQueue.main.async { selection = [SiteScope.id(site: model.siteKey, key: manual.key)] }
            }
        default:
            break
        }
    }

    // MARK: Retirer : archiver ou supprimer définitivement

    /// Confirmation (combien d'appareils, quels sites, archiver ou supprimer, « Ne plus réajouter »),
    /// puis retrait dans l'inventaire de chaque site concerné seulement ; ⌘Z ou « Annuler » l'annule.
    private func confirmRemove(_ ids: [String], rows: [SiteScopedRecord]) {
        let chosen = rows.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, let answer = InvDialogs.confirmRemove(chosen) else { return }
        let several = Set(chosen.map(\.siteKey)).count > 1
        remove(ids: chosen.map(\.id), exclude: answer.exclude, archive: answer.archive,
               summary: several ? "(" + InvDialogs.siteSummary(chosen) + ")" : "du site " + InvDialogs.siteSummary(chosen))
    }

    private func remove(ids: [String], exclude: Bool, archive: Bool, summary: String) {
        let removal = model.remove(ids, exclude: exclude, archive: archive)
        guard removal.count > 0 else { return }
        let trashed = archive ? [] : removal.parts.flatMap { model.discardAttachments(of: $0.removal.records, site: $0.site) }
        selection = []
        Self.registerUndo(undoManager, removal: removal, ids: ids, exclude: exclude, archive: archive, trashed: trashed, summary: summary)
        let count = removal.count
        let verb = (archive ? "archivé" : "supprimé") + (count > 1 ? "s" : "") + (archive ? "" : " définitivement")
        model.show("\(count) appareil\(count > 1 ? "s" : "") \(verb) \(summary)"
                   + (exclude ? ", plus jamais réajouté\(count > 1 ? "s" : "")" : ""), undo: true)
        model.updateBadge(state)
    }

    /// Message d'annulation : ce qui a vraiment été remis (une fiche recréée entre-temps par un
    /// scan reçoit ses notes et son historique ; un site supprimé ne reçoit rien).
    private static func restoreMessage(_ result: InvRestoreResult, expected: Int, summary: String) -> String {
        guard result.total > 0 else { return "Retrait non annulé\u{00A0}: l’inventaire du site n’est plus disponible" }
        let place = summary.hasPrefix("du site ") ? "dans le site " + summary.dropFirst("du site ".count) : summary
        var text = "Retrait annulé\u{00A0}: \(result.total) appareil\(result.total > 1 ? "s" : "") remis \(place)"
        if result.merged > 0 {
            text += " · \(result.merged) revenu\(result.merged > 1 ? "s" : "") entre-temps, notes et historique repris"
        }
        if result.total < expected { text += " · \(expected - result.total) non remis (site indisponible)" }
        return text
    }

    /// Édition › Annuler « Retirer de l'inventaire » (⌘Z), puis Rétablir (⇧⌘Z).
    private static func registerUndo(_ manager: UndoManager?, removal: InvModel.Removal, ids: [String], exclude: Bool, archive: Bool,
                                     trashed: [InvModel.TrashedFolder], summary: String) {
        guard let manager else { return }
        let model = InvModel.shared
        let name = archive ? "Archiver" : "Supprimer de l’inventaire"
        manager.registerUndo(withTarget: model) { target in
            let result = target.restore(removal)
            target.recoverAttachments(trashed)
            target.show(restoreMessage(result, expected: removal.count, summary: summary))
            guard result.total > 0 else { return }
            manager.registerUndo(withTarget: target) { again in
                let current = again.currentIDs(ids, since: removal)
                let redone = again.remove(current, exclude: exclude, archive: archive)
                let trashedAgain = archive ? [] : redone.parts.flatMap { again.discardAttachments(of: $0.removal.records, site: $0.site) }
                again.show("\(redone.count) appareil\(redone.count > 1 ? "s" : "") retiré\(redone.count > 1 ? "s" : "") de nouveau", undo: true)
                guard redone.count > 0 else { return }
                registerUndo(manager, removal: redone, ids: current, exclude: exclude, archive: archive, trashed: trashedAgain, summary: summary)
            }
            manager.setActionName(name)
        }
        manager.setActionName(name)
    }

    // MARK: Archives : restaurer, supprimer définitivement

    private func restore(_ ids: [String]) {
        let result = model.restoreArchived(ids)
        guard result.total > 0 else { return }
        selection = []
        let manager = undoManager
        manager?.registerUndo(withTarget: model) { target in
            let again = target.remove(ids, exclude: false, archive: true)
            target.show("\(again.count) appareil\(again.count > 1 ? "s" : "") de nouveau archivé\(again.count > 1 ? "s" : "")")
        }
        manager?.setActionName("Restaurer")
        model.show("\(result.total) appareil\(result.total > 1 ? "s" : "") restauré\(result.total > 1 ? "s" : "") dans l’inventaire", undo: true)
        if ids.count == 1, let parts = SiteScope.split(ids[0]) { select(site: parts.site, key: parts.key) }
    }

    private func confirmPurge(_ ids: [String], rows: [SiteScopedRecord]) {
        let chosen = rows.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, InvDialogs.confirmPurge(chosen) else { return }
        purge(chosen.map(\.id))
    }

    private func purge(_ ids: [String]) {
        let parts = model.purgeArchived(ids)
        let count = parts.reduce(0) { $0 + $1.entries.count }
        guard count > 0 else { return }
        let trashed = parts.flatMap { model.discardAttachments(of: $0.entries.map(\.record), site: $0.site) }
        selection = []
        let manager = undoManager
        manager?.registerUndo(withTarget: model) { target in
            target.putBackArchived(parts)
            target.recoverAttachments(trashed)
            target.show("Suppression annulée\u{00A0}: \(count) appareil\(count > 1 ? "s" : "") remis dans les archives")
        }
        manager?.setActionName("Supprimer définitivement")
        model.show("\(count) appareil\(count > 1 ? "s" : "") archivé\(count > 1 ? "s" : "") supprimé\(count > 1 ? "s" : "") définitivement", undo: true)
    }

    // MARK: Déplacer vers un autre site

    private func move(_ ids: [String], to destination: String, rows: [SiteScopedRecord]) {
        let chosen = rows.filter { ids.contains($0.id) && $0.siteKey != destination }
        guard !chosen.isEmpty else { return }
        let name = sites.name(forKey: destination)
        let target = model.inventory(for: destination)
        let refusals = target.transferRefusals(for: chosen.map(\.record))
        guard InvDialogs.confirmMove(chosen, to: name, refusals: refusals) else { return }
        let result = model.move(chosen.map(\.id), to: destination)
        refreshShared()
        guard result.count > 0 else {
            model.show("Rien n’a été déplacé vers «\u{00A0}\(name)\u{00A0}» (jamais de fusion entre sites)")
            return
        }
        selection = []
        Self.registerMoveUndo(undoManager, move: result, name: name)
        let left = result.refusals.count
        model.show("\(result.count) appareil\(result.count > 1 ? "s" : "") déplacé\(result.count > 1 ? "s" : "") vers «\u{00A0}\(name)\u{00A0}»"
                   + (left > 0 ? " · \(left) resté\(left > 1 ? "s" : "") (déjà là-bas)" : ""), undo: true)
    }

    private static func registerMoveUndo(_ manager: UndoManager?, move: InvModel.Move, name: String) {
        guard let manager else { return }
        manager.registerUndo(withTarget: InvModel.shared) { target in
            let back = target.undoMove(move)
            target.show("Déplacement annulé\u{00A0}: \(back) appareil\(back > 1 ? "s" : "") revenu\(back > 1 ? "s" : "") dans leur site")
            manager.registerUndo(withTarget: target) { again in
                let ids = move.moved.flatMap { part in part.keys.map { SiteScope.id(site: part.site, key: $0) } }
                let redone = again.move(ids, to: move.destination)
                again.show("\(redone.count) appareil\(redone.count > 1 ? "s" : "") déplacé\(redone.count > 1 ? "s" : "") de nouveau vers «\u{00A0}\(name)\u{00A0}»", undo: true)
                if redone.count > 0 { registerMoveUndo(manager, move: redone, name: name) }
            }
            manager.setActionName("Déplacer vers un autre site")
        }
        manager.setActionName("Déplacer vers un autre site")
    }

    // MARK: Aide

    private var help: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Theme.textSecondary)
            (Text("Identification par empreinte : ").foregroundStyle(Theme.text).fontWeight(.semibold)
             + Text("préfixe OUI de la MAC, nom d’hôte et ports ouverts relevés par le scan. Un appareil à MAC aléatoire reste « non identifié » jusqu’à ce qu’un technicien confirme sa fiche (en lui donnant un nom). Chaque site a son propre inventaire (~/Library/Application Support/NetScope/sites/<site>/inventory.json)\u{00A0}: la même IP ou la même MAC sur deux sites donne deux fiches distinctes."))
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
