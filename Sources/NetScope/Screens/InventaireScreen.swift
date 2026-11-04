import AppKit
import NetScopeCore
import SwiftUI

/// Vues sauvegardées de l'inventaire.
enum InvView: String, CaseIterable, Hashable {
    case tous, nonIdentifies, disparus, favoris

    var label: String {
        switch self {
        case .tous: return "Tous"
        case .nonIdentifies: return "Non identifiés"
        case .disparus: return "Disparus > 30 j"
        case .favoris: return "Favoris"
        }
    }

    func includes(_ record: InvRecord, now: Date) -> Bool {
        switch self {
        case .tous: return true
        case .nonIdentifies: return record.isUnidentified
        case .disparus: return record.isGone(now: now)
        case .favoris: return record.annotations.isFavorite
        }
    }
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
    @StateObject private var table = InvTable.makeModel()
    @State private var mergeOpen = false
    @State private var ignoredDuplicates: Set<String> = []
    @State private var importing = false
    @State private var exportDocument: InvCSVDocument?
    @State private var exporting = false

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
        let all = SiteScope.records(inventories)
        let records = all.map(\.record)
        // Note 26 : recherche multiple, analysée une fois pour toutes les fiches (préfixe site:).
        let query = state.searchQuery(for: .inventaire)
        let rows = InvTable.sorted(all.filter { view.includes($0.record, now: now) && query.matches($0) }, by: table.sortOrder)
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
                InvTable(rows: rows, total: records.count, selection: selectionBinding(rows), table: table, now: now,
                         inventoryEmpty: records.isEmpty, siteNames: inventories.map(\.name),
                         unreadableNames: inventories.filter { model.unreadableSites.contains($0.key) }.map(\.name), excluded: excluded,
                         onFavorite: { model.toggleFavorite($0.record.key, site: $0.siteKey) },
                         onDelete: { confirmDelete($0, rows: rows) })
                if selectedRows.count > 1 {
                    selectionPanel(selectedRows, rows: rows)
                } else if let row = selectedRows.first {
                    InvDetail(record: row.record, events: model.inventory(for: row.siteKey).events(for: row.record.key), now: now,
                              siteKey: row.siteKey)
                        .id(row.id)
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
            // Icône seule (comme la corbeille du Finder) : la barre d'outils tient en petite fenêtre.
            Button { confirmDelete(Array(chosen), rows: rows) } label: { Label("Supprimer", systemImage: "trash").labelStyle(.iconOnly) }
                .buttonStyle(.secondary)
                .accessibilityLabel("Supprimer de l’inventaire")
                .disabled(chosen.isEmpty)
                .help(chosen.count > 1 ? "Supprimer les \(chosen.count) appareils sélectionnés de l’inventaire (⌫)"
                      : "Supprimer l’appareil sélectionné de l’inventaire (⌫)")
            Button { importing = true } label: { Label("Importer CSV", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
                .help("Importer un CSV dans l’inventaire du site actif «\u{00A0}\(sites.activeName)\u{00A0}»")
            Button {
                exportDocument = InvCSVDocument(text: InvCSV.export(rows.map(\.record), sites: multiple ? rows.map(\.siteName) : nil))
                exporting = true
            } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
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
            adoptRequestedSelection()
            pickFirstRowIfNeeded(rows)
        }
        .onChange(of: rows.first?.id) { _, _ in pickFirstRowIfNeeded(rows) }
        .onChange(of: model.selectedKey) { _, _ in adoptRequestedSelection() }
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
                      defaultFilename: "inventaire-\(InvFormat.day(Date())).csv") { result in
            if case .success(let url) = result {
                model.show("Export CSV : \(url.lastPathComponent) (\(rows.count) lignes)")
            }
        }
    }

    // MARK: En-tête

    private func header(now: Date, inventories: [SiteInventory]) -> some View {
        let caption = inventories.count > 1 ? "Tous les appareils jamais vus sur ces \(inventories.count) sites" : "Tous les appareils jamais vus sur ce site"
        return HStack(spacing: 12) {
            // Note 28 : l'inventaire est propre à chaque site ; le menu choisit un, plusieurs ou tous les sites.
            SiteScopeMenu(screen: .inventaire).layoutPriority(1)
            // Segments égaux, plus larges que le plus long libellé : « Disparus > 30 j » n'est pas serré.
            Picker("Vue de l’inventaire", selection: $view) {
                ForEach(InvView.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 452)
            .fixedSize()
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
            if let toast = model.toast { InvToast(text: toast) }
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
        let seenToday = records.filter { $0.lastSeen >= today }.count
        let online = records.filter(\.isOnline).count
        let unidentified = records.filter(\.isUnidentified).count
        let gone = records.filter { $0.isGone(now: now) }.count
        // Conflits de chaque site (jamais une IP d'un site comparée à celle d'un autre).
        let conflicts = inventories.flatMap { inventory in inventory.store.conflictIPs.sorted().map { InvSiteConflict(site: inventory.key, siteName: inventory.name, ip: $0, key: inventory.store.record(forIP: $0)?.key) } }
        let multiple = inventories.count > 1

        return HStack(alignment: .top, spacing: 12) {
            InvTile(title: "Appareils connus", value: "\(records.count)", subtitle: "Toutes plages confondues") { view = .tous }
            InvTile(title: "Vus aujourd’hui", value: "\(seenToday)", // Plusieurs sites : chaque site a son propre dernier scan (pas forcément aujourd'hui).
                    subtitle: multiple ? "\(online) en ligne au dernier scan de chaque site" : "\(online) en ligne au dernier scan",
                    valueColor: Theme.success)
            InvTile(title: "Non identifiés", value: "\(unidentified)", subtitle: "MAC aléatoire ou empreinte insuffisante",
                    valueColor: Theme.warning) { view = .nonIdentifies }
            InvTile(title: "Disparus", value: "\(gone)", subtitle: "Sans réponse depuis plus de 30 jours",
                    valueColor: Theme.textSecondary) { view = .disparus }
            InvTile(title: "Alertes d’inventaire", value: "") {
                VStack(alignment: .leading, spacing: 5) {
                    if conflicts.isEmpty {
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
    private func selectionPanel(_ chosen: [SiteScopedRecord], rows: [SiteScopedRecord]) -> some View {
        Panel(padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checklist").font(.system(size: 20)).foregroundStyle(Theme.accentStrong)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(chosen.count) appareils sélectionnés").font(Theme.bodySemibold)
                    Text((Set(chosen.map(\.siteKey)).count > 1 ? "" : "Site ") + Self.siteSummary(chosen) + " · ⌘-clic ou ⇧-clic pour changer la sélection, ⌘A pour tout choisir")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Tout désélectionner") { selection = [] }.buttonStyle(.secondary)
                Button(role: .destructive) { confirmDelete(chosen.map(\.id), rows: rows) } label: {
                    Label("Supprimer de l’inventaire…", systemImage: "trash")
                }
                .buttonStyle(.secondary)
            }
        }
    }

    /// « « Siège » », ou « Siège (2), Entrepôt Laval (1) »
    private static func siteSummary(_ rows: [SiteScopedRecord]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for row in rows {
            if counts[row.siteName] == nil { order.append(row.siteName) }
            counts[row.siteName, default: 0] += 1
        }
        if order.count == 1 { return "«\u{00A0}\(order[0])\u{00A0}»" }
        return order.map { "\($0) (\(counts[$0] ?? 0))" }.joined(separator: ", ")
    }

    // MARK: Suppression

    /// Confirmation (combien d'appareils, quels sites, « Ne plus suivre ces appareils »), puis
    /// suppression dans l'inventaire de chaque site concerné seulement ; ⌘Z l'annule.
    private func confirmDelete(_ ids: [String], rows: [SiteScopedRecord]) {
        let chosen = rows.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let count = chosen.count
        let names = chosen.prefix(3).map(\.record.displayName).joined(separator: ", ") + (count > 3 ? "…" : "")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count > 1 ? "Supprimer \(count) appareils de l’inventaire\u{00A0}?" : "Supprimer «\u{00A0}\(names)\u{00A0}» de l’inventaire\u{00A0}?"
        alert.informativeText = (count > 1 ? names + "\n\n" : "")
            + (Set(chosen.map(\.siteKey)).count > 1 ? "Sites touchés\u{00A0}: " : "Site touché\u{00A0}: ") + Self.siteSummary(chosen)
            + " (les autres sites ne changent pas).\n\n"
            + "La fiche, ses notes et son historique d’événements sont retirés. Sans «\u{00A0}Ne plus suivre\u{00A0}», "
            + (count > 1 ? "ces appareils reviendront si un prochain scan de leur site les revoit"
               : "l’appareil reviendra si un prochain scan de son site le revoit") + ".\n\n"
            + "Vous pourrez annuler juste après (⌘Z ou Édition › Annuler)."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = count > 1 ? "Ne plus suivre ces appareils (un scan ne les remettra pas)"
            : "Ne plus suivre cet appareil (un scan ne le remettra pas)"
        alert.suppressionButton?.state = .off
        let deleteButton = alert.addButton(withTitle: "Supprimer")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let exclude = alert.suppressionButton?.state == .on
        let several = Set(chosen.map(\.siteKey)).count > 1
        delete(ids: chosen.map(\.id), exclude: exclude,
               summary: several ? "(" + Self.siteSummary(chosen) + ")" : "du site " + Self.siteSummary(chosen))
    }

    private func delete(ids: [String], exclude: Bool, summary: String) {
        let removal = model.remove(ids, exclude: exclude)
        guard removal.count > 0 else { return }
        selection = []
        Self.registerUndo(undoManager, removal: removal, ids: ids, exclude: exclude, summary: summary)
        let count = removal.count
        model.show("\(count) appareil\(count > 1 ? "s" : "") supprimé\(count > 1 ? "s" : "") \(summary)"
                   + (exclude ? ", plus suivi\(count > 1 ? "s" : "")" : "") + " · ⌘Z pour annuler")
        model.updateBadge(state)
    }

    /// Message d'annulation : ce qui a vraiment été remis (une fiche recréée entre-temps par un
    /// scan reçoit ses notes et son historique ; un site supprimé ne reçoit rien).
    private static func restoreMessage(_ result: InvRestoreResult, expected: Int, summary: String) -> String {
        guard result.total > 0 else { return "Suppression non annulée\u{00A0}: l’inventaire du site n’est plus disponible" }
        let place = summary.hasPrefix("du site ") ? "dans le site " + summary.dropFirst("du site ".count) : summary
        var text = "Suppression annulée\u{00A0}: \(result.total) appareil\(result.total > 1 ? "s" : "") remis \(place)"
        if result.merged > 0 {
            text += " · \(result.merged) revenu\(result.merged > 1 ? "s" : "") entre-temps, notes et historique repris"
        }
        if result.total < expected { text += " · \(expected - result.total) non remis (site indisponible)" }
        return text
    }

    /// Édition › Annuler « Supprimer de l'inventaire » (⌘Z), puis Rétablir (⇧⌘Z).
    private static func registerUndo(_ manager: UndoManager?, removal: InvModel.Removal, ids: [String], exclude: Bool, summary: String) {
        guard let manager else { return }
        let model = InvModel.shared
        manager.registerUndo(withTarget: model) { target in
            let result = target.restore(removal)
            target.show(restoreMessage(result, expected: removal.count, summary: summary))
            guard result.total > 0 else { return }
            manager.registerUndo(withTarget: target) { again in
                let current = again.currentIDs(ids, since: removal)
                let redone = again.remove(current, exclude: exclude)
                again.show("\(redone.count) appareil\(redone.count > 1 ? "s" : "") supprimé\(redone.count > 1 ? "s" : "") de nouveau")
                guard redone.count > 0 else { return }
                registerUndo(manager, removal: redone, ids: current, exclude: exclude, summary: summary)
            }
            manager.setActionName("Supprimer de l’inventaire")
        }
        manager.setActionName("Supprimer de l’inventaire")
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
