import NetScopeCore
import SwiftUI

/// Écran `Screen.carte` : carte hiérarchique construite à partir du scan
/// (Internet → passerelle → switchs → points d'accès et groupes d'appareils), croquis docs/croquis/Topologie.dc.html.
/// Menu « Site ▾ » : un, plusieurs ou tous les sites ; un dessin par site (sélecteur « Dessin »),
/// jamais deux réseaux dans le même dessin. Les autres sites sont dessinés d'après leur dernier
/// scan enregistré (sites/<id>/resultats.json), sans changer le site actif.
struct TopologieScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared
    @ObservedObject private var scan = ScanController.shared
    @ObservedObject private var scope = SiteScopeStore.shared
    @ObservedObject private var sites = SiteModel.shared
    /// Site dessiné quand plusieurs sites sont choisis (nil : le premier, le site actif s'il en fait partie).
    @State private var drawingSite: String?

    @State private var selectedID: String?
    /// nil : la carte s'ajuste à la place disponible.
    @State private var zoom: CGFloat?
    @State private var fitScale: CGFloat = 1
    @State private var showEndDevices = true
    @State private var showPortLabels = true
    /// Faux : seulement les appareils du dernier scan (les scans précédents, d'un autre site par
    /// exemple, ne restent pas sur la carte).
    @State private var includePrevious = false
    // Note 32 : recherche de la barre d'outils sur la carte.
    /// Rang du résultat montré.
    @State private var searchIndex = 0
    /// Vrai si la recherche a zoomé la carte (rendue à l'ajustement quand la recherche est effacée).
    @State private var searchZoomed = false
    /// Demande de défilement jusqu'au résultat (change à chaque nouveau résultat montré).
    @State private var scrollRequest = 0

    // MARK: Site dessiné

    private var shownKeys: [String] { scope.keys(for: .carte) }

    /// Site du dessin : un seul à la fois.
    private var drawnKey: String {
        let keys = shownKeys
        if let drawingSite, keys.contains(drawingSite) { return drawingSite }
        return keys.first ?? sites.activeKey
    }

    private var isActiveDrawing: Bool { drawnKey == sites.activeKey }

    /// Appareils du site dessiné et ceux de son dernier scan : le Scanner pour le site actif, sinon
    /// les résultats enregistrés du site (lecture seule).
    private var siteDevices: (all: [Device], lastScan: [Device]) {
        if isActiveDrawing {
            return (state.devices, TopoScope.lastScan(state.devices, since: scan.startedAt, ranges: scan.lastScanRanges))
        }
        let results = sites.storedResults(for: drawnKey) ?? SiteResults()
        let devices = results.devices.map { device -> Device in
            var copy = device
            copy.customName = results.customNames[device.id] ?? device.customName
            return copy
        }
        return (devices, TopoScope.lastScan(devices, since: results.startedAt, ranges: results.parsedScanRanges))
    }

    /// Appareils dessinés : ceux du dernier scan, ou tous ceux que garde le site ; type choisi à la main.
    private var mapDevices: [Device] {
        let devices = siteDevices
        let shown = includePrevious ? devices.all : devices.lastScan
        return isActiveDrawing ? model.withManualTypes(shown) : model.inventory(for: drawnKey).applyingManualTypes(to: shown)
    }

    /// Appareils gardés mais absents du dernier scan.
    private var hiddenCount: Int {
        let devices = siteDevices
        return devices.all.count - devices.lastScan.count
    }

    var body: some View {
        let devices = mapDevices
        let conflicts = model.inventory(for: drawnKey).conflictIPs
        let graph = TopoGraph.build(devices: devices, gateway: drawnGateway(devices), conflictIPs: conflicts)
        let search = searchContext(graph, devices: devices)

        VStack(alignment: .leading, spacing: 14) {
            siteBar
            if devices.isEmpty {
                EmptyState(systemImage: Screen.carte.symbol,
                           title: shownKeys.count > 1 ? "Aucun appareil à placer sur la carte de «\u{00A0}\(sites.name(forKey: drawnKey))\u{00A0}»"
                               : "Aucun appareil à placer sur la carte",
                           message: "La carte se construit à partir du dernier scan : passerelle, switchs, points d’accès et groupes d’appareils par type.") {
                    Button { state.open(.scanner) } label: { Label("Ouvrir le scanner", systemImage: "magnifyingglass") }
                        .buttonStyle(.primary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tiles(graph, devices: devices, conflicts: conflicts)
                SidePanelSplit(sideWidth: 320, title: search == nil ? "Détail du nœud" : "Résultat de la recherche") {
                    mapPanel(graph, devices: devices, search: search)
                } side: {
                    TopoAside(graph: graph, selectedID: $selectedID, devices: devices, siteKey: drawnKey,
                              isActiveSite: isActiveDrawing, conflictIPs: conflicts,
                              search: search, searchActions: search == nil ? nil : searchActions)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(Theme.contentPadding)
        .preference(key: SearchResultsKey.self, value: [searchResultsLabel(search?.hits.count ?? 0)])
        .onChange(of: drawnKey) { _, _ in
            selectedID = nil
            searchIndex = 0
            focusSearch()
        }
        // Note 32 : chaque nouvelle recherche montre son premier résultat ; ↩︎ / ⇧↩︎ parcourent.
        .onChange(of: searchSignature) { _, _ in
            searchIndex = 0
            focusSearch()
        }
        .onChange(of: state.searchSubmit) { _, submit in
            guard submit.screen == .carte else { return }
            stepSearch(submit.backwards ? -1 : 1)
        }
        .onAppear { if !searchQuery.isEmpty { focusSearch() } }
        // Note 34 : nœud demandé par un autre écran (« Ouvrir dans › Carte du réseau »), et nœud
        // choisi retenu pour Retour.
        .onAppear { restoreShownFocus(); adoptPendingFocus() }
        .onChange(of: state.pendingFocus[.carte]) { _, _ in adoptPendingFocus() }
        .onChange(of: selectedID) { _, id in state.shownFocus[.carte] = id.map(NavFocus.node) }
        .onAppear {
            // Captures : NETSCOPE_CARTE_DESSIN=laval (partie du nom) choisit le dessin affiché.
            guard Launcher.isDemo, drawingSite == nil,
                  let wanted = ProcessInfo.processInfo.environment["NETSCOPE_CARTE_DESSIN"]?.lowercased() else { return }
            drawingSite = shownKeys.first { sites.name(forKey: $0).lowercased().contains(wanted) }
        }
        .screenToolbar {
            Button { state.open(.switchs) } label: { Label("Switchs et ports", systemImage: Screen.switchs.symbol) }
                .buttonStyle(.secondary)
            Button { state.open(.scanner) } label: { Label("Redécouvrir", systemImage: "arrow.clockwise") }
                .buttonStyle(.primary)
                .help("Relancer un scan depuis l’écran Scanner pour mettre la carte à jour")
        }
        .feedsInventory(state)
    }

    // MARK: Recherche (note 32)

    private var searchQuery: SearchQuery { state.searchQuery(for: .carte) }

    /// Nombre de résultats, à côté des étiquettes de la recherche.
    private func searchResultsLabel(_ count: Int) -> String {
        switch count {
        case 0: return "Aucun appareil trouvé"
        case 1: return "1 appareil trouvé"
        default: return "\(count) appareils trouvés"
        }
    }

    /// Change avec la recherche, le dessin ou le calque des scans précédents.
    private var searchSignature: String {
        "\(drawnKey)|\(includePrevious)|\(searchQuery.isEmpty ? "" : state.searchTexts[.carte] ?? "")"
    }

    /// Notes des fiches (le préfixe `note:` les cherche) : celles du Scanner pour le site actif,
    /// celles de l'inventaire du site pour un autre site.
    private func notes(_ device: Device) -> [String] {
        if isActiveDrawing {
            let note = DeviceNotesStore.shared.note(for: device)
            let record = model.record(DeviceNotesStore.key(for: device))
            return [note, record?.annotations.notes ?? ""].filter { !$0.isEmpty }
        }
        let note = model.inventory(for: drawnKey).record(forIP: device.ip)?.annotations.notes ?? ""
        return note.isEmpty ? [] : [note]
    }

    /// Résultats sur le site dessiné, autres sites où la recherche trouve aussi des appareils, et
    /// appareils trouvés parmi ceux des scans précédents (masqués). nil sans recherche.
    private func searchContext(_ graph: TopoGraph, devices: [Device]) -> TopoSearchContext? {
        let query = searchQuery
        guard !query.isEmpty else { return nil }
        let hits = TopoSearch.hits(query, graph: graph, items: TopoSearch.items(devices, graph: graph, notes: notes))
        var previous = 0
        if !includePrevious, hits.isEmpty {
            let shown = Set(devices.map(\.id))
            let hidden = siteDevices.all.filter { !shown.contains($0.id) }
            previous = TopoSearch.items(hidden, graph: nil).filter(query.matches).count
        }
        let others = TopoSearch.otherSites(query, sites: otherSiteDevices, excluding: drawnKey)
        return TopoSearchContext(text: state.searchTexts[.carte] ?? "", hits: hits,
                                 index: min(searchIndex, max(hits.count - 1, 0)), otherSites: others,
                                 previousCount: previous, siteName: sites.name(forKey: drawnKey),
                                 ipExample: devices.first.map { "\($0.ip.octets.0).\($0.ip.octets.1).\($0.ip.octets.2)." } ?? "10.0.0.")
    }

    /// Appareils gardés par chaque site (le Scanner pour le site actif, le dernier scan enregistré
    /// pour les autres), pour « Aussi sur : … ».
    private var otherSiteDevices: [TopoSiteDevices] {
        sites.sortedSites.compactMap { site in
            let key = SiteFiles.key(for: site.id)
            guard key != drawnKey else { return nil }
            let devices = key == sites.activeKey ? model.withManualTypes(state.devices) : (sites.storedResults(for: key)?.devices ?? [])
            return devices.isEmpty ? nil : TopoSiteDevices(key: key, name: site.displayName, devices: devices)
        }
    }

    private var searchActions: TopoSearchActions {
        TopoSearchActions(
            step: { stepSearch($0) },
            showSite: { key in
                // Le site est ajouté aux sites affichés (pour cette session) et dessiné.
                scope.include(key, in: .carte)
                drawingSite = key
                searchIndex = 0
                focusSearch()
            },
            showPrevious: {
                includePrevious = true
                searchIndex = 0
                focusSearch()
            },
            clear: { state.searchTexts[.carte] = nil })
    }

    private func stepSearch(_ delta: Int) {
        guard let search = currentSearch(), !search.context.hits.isEmpty else { return }
        searchIndex = TopoSearch.step(search.context.index, by: delta, count: search.context.hits.count)
        focusSearch()
    }

    private func currentSearch() -> (context: TopoSearchContext, graph: TopoGraph)? {
        let devices = mapDevices
        let graph = TopoGraph.build(devices: devices, gateway: drawnGateway(devices),
                                    conflictIPs: model.inventory(for: drawnKey).conflictIPs)
        return searchContext(graph, devices: devices).map { ($0, graph) }
    }

    /// Montre le résultat courant : son nœud (ou son groupe) choisi, les appareils finaux affichés,
    /// la carte zoomée à 100 % au moins et centrée dessus. Sans recherche : rend le zoom d'avant.
    private func focusSearch() {
        guard let search = currentSearch() else {
            if searchZoomed { zoom = nil; searchZoomed = false }
            return
        }
        guard let hit = search.context.current else { return }
        selectedID = hit.nodeID
        if let kind = search.graph.node(hit.nodeID)?.kind, kind == .groupe || kind == .appareil, !showEndDevices {
            showEndDevices = true
        }
        // Zoom et défilement : par la carte (revealResult), qui connaît le zoom d'ajustement du moment.
        scrollRequest += 1
    }

    // MARK: Sites

    /// Menu « Site ▾ » et, avec plusieurs sites, le choix du dessin : un site par dessin.
    private var siteBar: some View {
        let keys = shownKeys
        return HStack(spacing: 12) {
            SiteScopeMenu(screen: .carte)
            if keys.count > 1 {
                Text("Dessin").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                // Segments s'ils tiennent (deux ou trois sites courts), sinon menu déroulant : jamais
                // de segments coupés qui élargiraient l'écran.
                ViewThatFits(in: .horizontal) {
                    if keys.count <= 3 {
                        drawingPicker(keys).pickerStyle(.segmented).fixedSize()
                    }
                    drawingPicker(keys).pickerStyle(.menu).fixedSize()
                }
                .layoutPriority(1)
                ViewThatFits(in: .horizontal) {
                    Text("Un dessin par site\u{00A0}: jamais deux réseaux dans le même dessin").fixedSize()
                    Text("Un dessin par site").fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            if !isActiveDrawing, let finished = sites.storedResults(for: drawnKey)?.finishedAt {
                ViewThatFits(in: .horizontal) {
                    Text("Dernier scan de ce site\u{00A0}: \(InvFormat.timeOrStamp(finished))").fixedSize()
                    Text("Scan du \(InvFormat.timeOrStamp(finished))").fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .help("Dessin d’après le dernier scan enregistré de ce site (\(InvFormat.stamp(finished)))")
            }
            Spacer(minLength: 0)
        }
    }

    private func drawingPicker(_ keys: [String]) -> some View {
        Picker("Dessin", selection: Binding(get: { drawnKey }, set: { drawingSite = $0 })) {
            ForEach(keys, id: \.self) { key in Text(sites.name(forKey: key)).tag(key) }
        }
        .labelsHidden()
        .help("Site dessiné\u{00A0}: un dessin par site")
    }

    /// Passerelle du dessin : celle de l'interface pour le site actif ; pour un autre site,
    /// l'appareil de son dernier scan qui a la MAC de passerelle apprise par le site.
    private func drawnGateway(_ devices: [Device]) -> IPv4Address? {
        if isActiveDrawing { return state.activeInterface?.gateway }
        guard let macs = sites.site(forKey: drawnKey)?.hints.gatewayMACs, !macs.isEmpty else { return nil }
        return devices.first { device in device.mac.map(macs.contains) ?? false }?.ip
    }

    // MARK: Indicateurs

    private func tiles(_ graph: TopoGraph, devices: [Device], conflicts conflictIPs: Set<IPv4Address>) -> some View {
        let online = devices.filter(\.isOnline).count
        let switches = graph.nodes.filter { $0.kind == .switch && !$0.isInferred }.count
        let inferred = graph.nodes.filter { $0.kind == .switch && $0.isInferred && $0.id != "sw:?" }.count
        let aps = graph.nodes.filter { $0.kind == .pointAcces }.count
        let gatewayFound = graph.node("passerelle")?.isInferred == false
        let links = graph.links
        let wireless = links.filter { $0.child.isWireless }.count
        let placed = devices.filter { $0.switchName != nil }.count
        let conflicts = conflictIPs.filter { ip in devices.contains { $0.ip == ip } }.sorted()

        var equipment: [String] = []
        if gatewayFound { equipment.append("1 passerelle") }
        equipment.append("\(switches) switch\(switches > 1 ? "s" : "")")
        if inferred > 0 { equipment.append("\(inferred) par nom") }
        equipment.append("\(aps) AP")

        return HStack(alignment: .top, spacing: 12) {
            InvTile(title: "Appareils agrégés", value: "\(devices.count)", subtitle: "\(online) vus récemment", valueSize: 19)
            InvTile(title: "Équipements réseau", value: "\((gatewayFound ? 1 : 0) + switches + aps)",
                    // Insécables dans chaque élément et avant « · » : la coupure tombe entre deux éléments.
                    subtitle: equipment.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "\u{00A0}· "),
                    valueSize: 19)
            InvTile(title: "Liens affichés", value: "\(links.count)",
                    subtitle: "\(links.count - wireless) filaires · \(wireless) Wi-Fi", valueSize: 19)
            InvTile(title: "Ports de switch connus", value: "\(placed)/\(devices.count)",
                    subtitle: placed == devices.count ? "Tous les appareils sont placés" : "\(devices.count - placed) sans port connu",
                    valueColor: placed == devices.count ? Theme.text : Theme.warning, valueSize: 19)
            InvTile(title: "Anomalies IP", value: "\(conflicts.count)",
                    subtitle: conflicts.isEmpty ? "Aucun conflit actif" : "Conflit " + conflicts.map { ".\($0.octets.3)" }.joined(separator: ", "),
                    valueColor: conflicts.isEmpty ? Theme.text : Theme.critical, valueSize: 19)
        }
    }

    // MARK: Carte

    /// Zoom automatique : la carte entière quand elle tient à 55 % ou plus ; sinon 55 %, cadrée
    /// en haut à gauche, et la carte défile. Jamais trop gros.
    private static let minFit: CGFloat = 0.55
    private static let maxFit: CGFloat = 1.15

    /// Disposition qui remplit le mieux le cadre réel : on essaie plusieurs hauteurs de piles de feuilles
    /// (plus basses = carte plus large que haute) et on garde celle qui permet le plus grand zoom.
    /// Si aucune ne tient à `minFit`, on garde celle qui tient en largeur à ce zoom avec la plus petite
    /// hauteur (la carte ne défile alors que verticalement), sinon la plus étroite.
    private func fittedLayout(_ graph: TopoGraph, in size: CGSize) -> (layout: TopoGraph.Layout, fit: CGFloat) {
        let hideEnd = !showEndDevices
        let hidden: (TopoNode) -> Bool = { node in hideEnd && (node.kind == .groupe || node.kind == .appareil) }
        let width = max(size.width - 24, 1), height = max(size.height - 24, 1)
        let layouts = (1...6).reversed().map { stack in
            graph.layout(nodeWidth: TopoStyle.nodeWidth, nodeHeight: TopoStyle.nodeHeight,
                         levelGap: 50, stackGap: 20, maxStack: stack, margin: 22, hidden: hidden)
        }
        var best: (layout: TopoGraph.Layout, fit: CGFloat)?
        for layout in layouts {
            let fit = min(width / layout.width, height / layout.height)
            // À zoom presque égal, on garde les piles les plus hautes (carte plus compacte).
            if let current = best, fit <= current.fit + 0.01 { continue }
            best = (layout, fit)
        }
        guard let result = best else {
            return (graph.layout(nodeWidth: TopoStyle.nodeWidth, nodeHeight: TopoStyle.nodeHeight, hidden: hidden), 1)
        }
        if result.fit >= Self.minFit { return (result.layout, min(result.fit, Self.maxFit)) }
        let fitsWidth = layouts.filter { $0.width * Self.minFit <= width }
        let layout = fitsWidth.min { $0.height < $1.height } ?? layouts.min { $0.width < $1.width } ?? result.layout
        return (layout, Self.minFit)
    }

    /// Au retour sur l'écran (vue recréée), le nœud choisi avant est de nouveau sélectionné ; s'il
    /// n'est plus sur la carte, rien n'est sélectionné.
    private func restoreShownFocus() {
        guard selectedID == nil, case .node(let id)? = state.shownFocus[.carte] else { return }
        let devices = mapDevices
        let graph = TopoGraph.build(devices: devices, gateway: drawnGateway(devices))
        if graph.node(id) != nil { selectedID = id }
    }

    /// Montre le nœud demandé (celui de l'appareil, ou le groupe qui le contient).
    private func adoptPendingFocus() {
        guard let focus = state.pendingFocus[.carte] else { return }
        state.pendingFocus[.carte] = nil
        switch focus {
        case .node(let id):
            selectedID = id
        case .device(let id):
            let devices = mapDevices
            let graph = TopoGraph.build(devices: devices, gateway: drawnGateway(devices))
            selectedID = graph.nodeID(showing: id)
        default:
            break
        }
    }

    private func mapPanel(_ graph: TopoGraph, devices: [Device], search: TopoSearchContext?) -> some View {
        let scale = zoom ?? fitScale
        let highlight = search?.highlight(graph)
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("DISPOSITION").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    Text("Hiérarchique").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                }
                .fixedSize()
                HStack(spacing: 10) {
                    Text("CALQUES").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    Toggle("Appareils finaux", isOn: $showEndDevices).toggleStyle(.checkbox).font(Theme.small)
                    Toggle("Ports", isOn: $showPortLabels).toggleStyle(.checkbox).font(Theme.small)
                    if includePrevious || hiddenCount > 0 {
                        Toggle("Scans précédents", isOn: $includePrevious).toggleStyle(.checkbox).font(Theme.small)
                            .help(includePrevious ? "Tous les appareils gardés par le Scanner, scans précédents compris"
                                  : "\(hiddenCount) appareil\(hiddenCount > 1 ? "s" : "") des scans précédents (autre plage ou autre site) masqué\(hiddenCount > 1 ? "s" : "")")
                    }
                }
                .fixedSize()
                Spacer()
                HStack(spacing: 6) {
                    zoomButton("minus", "Zoom arrière") { zoom = max(0.3, scale / 1.2) }
                    Text("\(Int((scale * 100).rounded())) %").font(Theme.mono(12, weight: .semibold)).frame(width: 46)
                    zoomButton("plus", "Zoom avant") { zoom = min(2, scale * 1.2) }
                    Button { zoom = nil; searchZoomed = false } label: { Label("Ajuster", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            Rectangle().fill(Theme.border).frame(height: 1)
            if let search {
                TopoSearchBand(search: search, graph: graph, actions: searchActions)
            }

            GeometryReader { geometry in
                let fitted = fittedLayout(graph, in: geometry.size)
                let layout = fitted.layout
                let fit = fitted.fit
                let scale = zoom ?? fit
                // Carte entière visible : centrée dans le cadre. Plus grande : cadrée en haut à gauche, à sa
                // taille exacte (aucun fond à la taille du cadre qui déborderait sous une barre de défilement
                // et ferait défiler, ou couper, le bord droit de la carte).
                let fitsWhole = layout.width * scale <= geometry.size.width && layout.height * scale <= geometry.size.height
                // Note 32 : avec un résultat de recherche, la vue s'ouvre centrée sur son nœud (point
                // d'ancrage calculé), et se rouvre ainsi à chaque nouveau résultat ou changement de zoom.
                let anchor = highlight.flatMap { searchScrollAnchor($0, layout: layout, scale: scale, viewport: geometry.size) }
                ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: fitsWhole ? .center : .topLeading) {
                            if fitsWhole {
                                Color.clear.frame(width: geometry.size.width, height: geometry.size.height)
                            }
                            TopoCanvas(graph: graph, layout: layout, selectedID: $selectedID, showPortLabels: showPortLabels,
                                       object: { TopoNav.object($0, graph: graph, devices: devices, siteKey: drawnKey) },
                                       onOpen: { state.perform($0) }, search: highlight)
                                .frame(width: layout.width, height: layout.height)
                                .scaleEffect(scale, anchor: .topLeading)
                                .frame(width: layout.width * scale, height: layout.height * scale, alignment: .topLeading)
                        }
                }
                .defaultScrollAnchor(anchor ?? .topLeading)
                .id(anchor == nil ? "carte" : "carte-\(scrollRequest)-\(scale)")
                .onAppear {
                    fitScale = fit
                    if highlight != nil { zoomForResult(fit: fit) }
                }
                .onChange(of: fit) { _, value in fitScale = value }
                .onChange(of: scrollRequest) { _, _ in zoomForResult(fit: fit) }
            }
            .background(Theme.panelMuted)

            legend
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Résultat montré : la carte passe à 100 % si elle est plus petite (nœuds lisibles).
    private func zoomForResult(fit: CGFloat) {
        guard (zoom ?? fit) < 1 else { return }
        zoom = 1
        searchZoomed = true
    }

    /// Point d'ancrage du défilement qui met le nœud du résultat au centre du cadre (ramené aux
    /// bords de la carte) ; nil si la carte entière tient dans le cadre.
    private func searchScrollAnchor(_ highlight: TopoSearchHighlight, layout: TopoGraph.Layout, scale: CGFloat,
                                    viewport: CGSize) -> UnitPoint? {
        guard let id = highlight.current, let point = layout.positions[id] else { return nil }
        let content = CGSize(width: layout.width * scale, height: layout.height * scale)
        guard content.width > viewport.width || content.height > viewport.height else { return nil }
        func unit(_ position: Double, _ content: CGFloat, _ viewport: CGFloat) -> CGFloat {
            guard content > viewport else { return 0 }
            return min(max((CGFloat(position) * scale - viewport / 2) / (content - viewport), 0), 1)
        }
        return UnitPoint(x: unit(point.x, content.width, viewport.width), y: unit(point.y, content.height, viewport.height))
    }

    private func zoomButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            InvFlowLayout(spacing: 11) {
                Text("LÉGENDE").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                legendIcon(.internet, "Internet")
                legendIcon(.passerelle, "Passerelle")
                legendIcon(.switch, "Switch")
                legendIcon(.pointAcces, "Point d’accès")
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.borderStrong).frame(width: 14, height: 11)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.panel).offset(x: 2, y: 2))
                    Text("Groupe agrégé")
                }
                Rectangle().fill(Theme.border).frame(width: 1, height: 14)
                HStack(spacing: 5) { Capsule().fill(TopoStyle.wire).frame(width: 22, height: 3); Text("Filaire") }
                HStack(spacing: 5) {
                    Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 22, y: 0)) }
                        .stroke(TopoStyle.wifi, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: 22, height: 2)
                    Text("Wi-Fi")
                }
                HStack(spacing: 5) { StatusDot(tone: .critical, size: 7); Text("Conflit IP") }
                HStack(spacing: 5) { StatusDot(tone: .neutral, size: 7); Text("Hors ligne") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(Theme.small)
            .foregroundStyle(Theme.neutralText)
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text("Carte construite à partir du scan ; les liens physiques exacts nécessitent SNMP/LLDP (écran Switchs et ports).")
                    .font(Theme.small)
                Button("Ouvrir Switchs et ports") { state.open(.switchs) }.buttonStyle(.ghost)
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panelMuted)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func legendIcon(_ kind: TopoNodeKind, _ title: String) -> some View {
        let style = TopoStyle.colors(kind: kind, type: nil)
        return HStack(spacing: 5) {
            Image(systemName: TopoStyle.symbol(kind: kind, type: nil)).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(style.fg)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(style.bg))
            Text(title)
        }
    }
}
