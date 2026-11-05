import NetScopeCore
import SwiftUI

/// Couleurs et symboles des nœuds (croquis Topologie).
enum TopoStyle {
    static let wire = color(TopoPalette.wire)
    static let wifi = color(TopoPalette.wifi)
    /// Note 78 : liens vus par LLDP ou la FortiGate (ISL, uplinks, FortiLink).
    static let lldp = color(TopoPalette.lldp)

    /// Couleur de la palette commune aux exports (note 61), en clair et en sombre.
    static func color(_ value: TopoColor) -> Color { Color(light: value.light, dark: value.dark) }
    static let nodeWidth: CGFloat = 178
    static let nodeHeight: CGFloat = 54
    /// Marge du dessin (disposition et nœuds déplacés).
    static let margin: CGFloat = 22

    static func colors(kind: TopoNodeKind, type: DeviceType?) -> (fg: Color, bg: Color) {
        let pair = TopoPalette.node(kind: kind, type: type)
        return (color(pair.fg), color(pair.bg))
    }

    static func symbol(kind: TopoNodeKind, type: DeviceType?) -> String {
        switch kind {
        case .internet: return "cloud"
        case .passerelle: return "shield.lefthalf.filled"
        case .switch: return "rectangle.connected.to.line.below"
        case .pointAcces: return "wifi"
        case .groupe, .appareil: return InvStyle.symbol(type ?? .inconnu)
        }
    }

    static func statusColor(_ status: TopoStatus) -> Color {
        switch status {
        case .ok: return Theme.success
        case .horsLigne: return Color(hex: 0x9CA3AF)
        case .critique: return Theme.critical
        }
    }
}

/// Dessin de la carte : liens en équerre, étiquettes de ports, nœuds cliquables.
struct TopoCanvas: View {
    let graph: TopoGraph
    let layout: TopoGraph.Layout
    @Binding var selectedID: String?
    let showPortLabels: Bool
    /// Note 34 : objet d'un nœud (double-clic, « Ouvrir dans › ») ; nil : nœud sans suite (Internet).
    var object: (TopoNode) -> NavObject? = { _ in nil }
    var onOpen: (NavObject) -> Void = { _ in }
    /// Note 32 : résultats de la recherche (nœuds trouvés, branche du résultat courant) ; le reste
    /// de la carte est atténué.
    var search: TopoSearchHighlight?
    /// Note 78 : nœuds qui portent le VLAN filtré (nil : aucun filtre) ; les autres sont atténués.
    var carrying: Set<String>?
    /// Note 78 : nœud lâché après un glisser (position du centre, dans le dessin à 100 %) ; nil :
    /// nœuds fixes.
    var onMove: ((String, CGPoint) -> Void)?
    /// Rend un nœud déplacé à la disposition automatique.
    var onRestore: ((String) -> Void)?

    /// Nœud en cours de glisser : décalage entre le pointeur et le centre, et centre actuel.
    private struct DragState {
        var id: String
        var grab: CGSize
        var center: CGPoint
    }
    @State private var drag: DragState?
    private static let space = "carte-dessin"

    var body: some View {
        // Liens vers un nœud en conflit d'abord (sous les autres) : leur descente partagée reste grise
        // et seul leur dernier tronçon est rouge, comme dans l'export.
        let placed = graph.links.filter { layout.positions[$0.parent.id] != nil && layout.positions[$0.child.id] != nil }
        let links = placed.filter { $0.child.status == .critique } + placed.filter { $0.child.status != .critique }
        let related = search.map { $0.pathLinks(links) } ?? relatedLinks(links)
        let redundant = graph.redundantLinks.filter { layout.positions[$0.aID] != nil && layout.positions[$0.bID] != nil }

        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { selectedID = nil }
            // Liens redondants (deuxième câble, anneau) : courbes en tirets, sous les nœuds.
            ForEach(redundant) { link in
                redundantPath(link)
                    .stroke(TopoStyle.lldp, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                    .opacity(redundantOpacity(link))
            }
            ForEach(links, id: \.child.id) { link in
                let highlighted = related.contains(link.child.id)
                let verified = link.child.uplinkKind != nil
                linkPath(link)
                    .stroke(color(link, highlighted: highlighted),
                            style: StrokeStyle(lineWidth: highlighted ? 3 : (verified ? 2.5 : 2), lineCap: .round, lineJoin: .round,
                                               dash: link.child.isWireless ? [5, 4] : []))
                    .opacity(linkOpacity(link, highlighted: highlighted))
            }
            if showPortLabels {
                ForEach(links, id: \.child.id) { link in
                    if let label = link.child.uplinkLabel, let position = labelPosition(link) {
                        portLabel(label, color: link.child.isWireless ? TopoStyle.wifi : (link.child.uplinkKind != nil ? TopoStyle.lldp : Theme.text))
                            .position(position)
                            .opacity(linkOpacity(link, highlighted: related.contains(link.child.id)) < 1 ? 0.4 : 1)
                            .help(link.child.uplinkKind.map { "\($0.label) vu par LLDP ou la FortiGate" } ?? "")
                    }
                }
                ForEach(redundant) { link in
                    if let label = link.portsLabel, let position = redundantMidpoint(link) {
                        portLabel(label, color: TopoStyle.lldp)
                            .position(position)
                            .opacity(redundantOpacity(link) < 1 ? 0.4 : 1)
                            .help("Lien redondant (\(link.kind.label)) vu par \(link.sourceLabel)")
                    }
                }
            }
            ForEach(graph.nodes) { node in
                if let center = point(node.id) {
                    TopoNodeView(node: node, isSelected: node.id == selectedID, isDimmed: isDimmed(node.id, links),
                                 searchCount: search?.counts[node.id], isSearchCurrent: search?.current == node.id,
                                 isMoved: layout.moved.contains(node.id), isDragged: drag?.id == node.id)
                        .onTapGesture { selectedID = node.id }
                        // Double-clic : suite logique (groupe → Inventaire filtré, switch → ses ports…),
                        // sans retarder le simple clic qui choisit le nœud.
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            selectedID = node.id
                            if let target = object(node) { onOpen(target) }
                        })
                        .gesture(moveGesture(node.id), including: onMove == nil ? .subviews : .all)
                        .contextMenu {
                            if let target = object(node) {
                                Button("Ouvrir") { onOpen(target) }
                                OpenInMenu(object: target)
                            }
                            if layout.moved.contains(node.id), let onRestore {
                                Divider()
                                Button("Remettre à sa place") { onRestore(node.id) }
                            }
                        }
                        .position(center)
                }
            }
        }
        .coordinateSpace(name: Self.space)
    }

    private func portLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.mono(10))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
            .fixedSize()
    }

    /// Glisser un nœud : il suit le pointeur (gardé dans la marge du dessin) ; lâché, sa position
    /// est retenue pour le site. Un simple clic reste un choix du nœud (seuil de 4 points).
    private func moveGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard onMove != nil else { return }
                if drag?.id != id {
                    guard let center = layout.positions[id].map({ CGPoint(x: $0.x, y: $0.y) }) else { return }
                    drag = DragState(id: id, grab: CGSize(width: value.startLocation.x - center.x, height: value.startLocation.y - center.y),
                                     center: center)
                    selectedID = id
                }
                guard var state = drag else { return }
                state.center = CGPoint(x: max(value.location.x - state.grab.width, TopoStyle.margin + TopoStyle.nodeWidth / 2),
                                       y: max(value.location.y - state.grab.height, TopoStyle.margin + TopoStyle.nodeHeight / 2))
                drag = state
            }
            .onEnded { _ in
                if let state = drag { onMove?(state.id, state.center) }
                drag = nil
            }
    }

    /// Nœud atténué : hors de la recherche (ni trouvé, ni sur la branche du résultat, ni choisi), ou
    /// sans recherche, sans lien avec le nœud choisi ; avec un filtre VLAN, nœud qui ne le porte pas.
    private func isDimmed(_ id: String, _ links: [(parent: TopoNode, child: TopoNode)]) -> Bool {
        if let search { return id != selectedID && !search.shows(id) }
        if let carrying, !carrying.contains(id), id != selectedID { return true }
        return selectedID != nil && !isRelated(id, links)
    }

    private func linkOpacity(_ link: (parent: TopoNode, child: TopoNode), highlighted: Bool) -> Double {
        if let search { return highlighted || (search.shows(link.parent.id) && search.shows(link.child.id)) ? 1 : 0.3 }
        if let carrying, !carrying.contains(link.child.id) { return 0.3 }
        return selectedID == nil || highlighted ? 1 : 0.35
    }

    private func redundantOpacity(_ link: TopoInfraLink) -> Double {
        if let search { return search.shows(link.aID) && search.shows(link.bID) ? 1 : 0.3 }
        if let carrying, !(carrying.contains(link.aID) && carrying.contains(link.bID)) { return 0.3 }
        guard let selectedID else { return 1 }
        return link.touches(selectedID) ? 1 : 0.35
    }

    /// Centre d'un nœud : celui du glisser en cours, sinon celui de la disposition.
    private func point(_ id: String) -> CGPoint? {
        if let drag, drag.id == id { return drag.center }
        return layout.positions[id].map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// Nœud placé à la main (ou en cours de glisser) : ses liens deviennent des courbes.
    private func isFree(_ id: String) -> Bool { layout.moved.contains(id) || drag?.id == id }

    /// Lien redondant : courbe entre les centres des deux nœuds, bombée sur le côté pour ne pas se
    /// confondre avec le lien de la hiérarchie.
    private func redundantPath(_ link: TopoInfraLink) -> Path {
        Path { path in
            guard let curve = redundantCurve(link) else { return }
            path.move(to: curve.start)
            path.addQuadCurve(to: curve.end, control: curve.control)
        }
    }

    /// Courbe d'un lien redondant : arc sous deux nœuds de la même rangée, sinon courbe bombée sur le
    /// côté (tracé commun aux exports, note 61).
    private func redundantCurve(_ link: TopoInfraLink) -> (start: CGPoint, control: CGPoint, end: CGPoint)? {
        guard let a = point(link.aID), let b = point(link.bID) else { return nil }
        let curve = TopoGeometry.redundantCurve(Self.graphPoint(a), Self.graphPoint(b),
                                                nodeWidth: Double(TopoStyle.nodeWidth), nodeHeight: Double(TopoStyle.nodeHeight))
        return (Self.cgPoint(curve.start), Self.cgPoint(curve.control), Self.cgPoint(curve.end))
    }

    /// Milieu de la courbe d'un lien redondant (étiquette des ports).
    private func redundantMidpoint(_ link: TopoInfraLink) -> CGPoint? {
        guard let curve = redundantCurve(link) else { return nil }
        return Self.cgPoint(TopoGeometry.redundantMidpoint((Self.graphPoint(curve.start), Self.graphPoint(curve.control),
                                                            Self.graphPoint(curve.end))))
    }

    private static func graphPoint(_ point: CGPoint) -> TopoGraph.Point { TopoGraph.Point(x: Double(point.x), y: Double(point.y)) }
    private static func cgPoint(_ point: TopoGraph.Point) -> CGPoint { CGPoint(x: point.x, y: point.y) }

    /// Lien en équerre du bas du parent au haut de l'enfant (rail latéral pour une feuille empilée,
    /// courbe pour un nœud placé à la main) : tracé commun aux exports (note 61).
    private func linkPath(_ link: (parent: TopoNode, child: TopoNode)) -> Path {
        Path { path in
            guard let parent = point(link.parent.id), let child = point(link.child.id) else { return }
            let segments = TopoGeometry.treePath(parent: Self.graphPoint(parent), child: Self.graphPoint(child),
                                                 free: isFree(link.parent.id) || isFree(link.child.id),
                                                 stacked: layout.stacked.contains(link.child.id),
                                                 nodeWidth: Double(TopoStyle.nodeWidth), nodeHeight: Double(TopoStyle.nodeHeight))
            for segment in segments {
                switch segment {
                case .move(let end): path.move(to: Self.cgPoint(end))
                case .line(let end): path.addLine(to: Self.cgPoint(end))
                case .quad(let end, let control): path.addQuadCurve(to: Self.cgPoint(end), control: Self.cgPoint(control))
                case .cubic(let end, let c1, let c2):
                    path.addCurve(to: Self.cgPoint(end), control1: Self.cgPoint(c1), control2: Self.cgPoint(c2))
                }
            }
        }
    }

    /// Étiquette de port : sur la descente vers l'enfant, ou au-dessus d'une feuille empilée.
    private func labelPosition(_ link: (parent: TopoNode, child: TopoNode)) -> CGPoint? {
        guard let parent = point(link.parent.id), let child = point(link.child.id) else { return nil }
        return Self.cgPoint(TopoGeometry.treeLabel(parent: Self.graphPoint(parent), child: Self.graphPoint(child),
                                                   free: isFree(link.parent.id) || isFree(link.child.id),
                                                   stacked: layout.stacked.contains(link.child.id),
                                                   nodeWidth: Double(TopoStyle.nodeWidth), nodeHeight: Double(TopoStyle.nodeHeight)))
    }

    private func color(_ link: (parent: TopoNode, child: TopoNode), highlighted: Bool) -> Color {
        if link.child.status == .critique { return Theme.critical }
        if highlighted { return Theme.accent }
        if link.child.uplinkKind != nil { return TopoStyle.lldp }
        return link.child.isWireless ? TopoStyle.wifi : TopoStyle.wire
    }

    /// Liens touchant le nœud choisi (identifiés par l'enfant).
    private func relatedLinks(_ links: [(parent: TopoNode, child: TopoNode)]) -> Set<String> {
        guard let selectedID else { return [] }
        return Set(links.filter { $0.parent.id == selectedID || $0.child.id == selectedID }.map(\.child.id))
    }

    private func isRelated(_ id: String, _ links: [(parent: TopoNode, child: TopoNode)]) -> Bool {
        guard let selectedID else { return true }
        if id == selectedID { return true }
        return links.contains { ($0.parent.id == selectedID && $0.child.id == id) || ($0.child.id == selectedID && $0.parent.id == id) }
    }
}

/// Un nœud : pastille d'icône, nom, sous-titre, point d'état ; les groupes ont une carte empilée.
struct TopoNodeView: View {
    let node: TopoNode
    let isSelected: Bool
    let isDimmed: Bool
    /// Note 32 : appareils trouvés par la recherche dans ce nœud (pastille « loupe 2 »).
    var searchCount: Int?
    /// Nœud du résultat courant de la recherche (halo autour du nœud).
    var isSearchCurrent = false
    /// Note 78 : nœud placé à la main (petite punaise) et nœud en cours de glisser (ombre portée).
    var isMoved = false
    var isDragged = false

    /// Nom du nœud : sur une ligne (12 pt, sinon 10,5 pt) quand il tient ; sinon deux lignes coupées
    /// à un espace (traits d'union insécables : jamais « Borne Wi- / Fi accueil »).
    private var title: some View {
        ViewThatFits(in: .horizontal) {
            Text(node.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            Text(node.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).fixedSize()
            Text(node.title.replacingOccurrences(of: "-", with: "\u{2011}"))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.text)
    }

    private func labels(subtitleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            title
            Text(node.subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                .lineLimit(subtitleLines).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        let colors = TopoStyle.colors(kind: node.kind, type: node.deviceType)
        let shape = RoundedRectangle(cornerRadius: 8)
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 7) {
                Image(systemName: TopoStyle.symbol(kind: node.kind, type: node.deviceType))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colors.fg)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(colors.bg))
                // Libellés sur deux lignes au besoin plutôt que tronqués (« Contrôleur de domaine »,
                // « VLAN 30 · 2 en ligne · 1 conflit ») : trois lignes au plus dans le nœud.
                ViewThatFits(in: .vertical) {
                    labels(subtitleLines: 2)
                    labels(subtitleLines: 1)
                }
                .frame(maxHeight: TopoStyle.nodeHeight - 6)
                Spacer(minLength: 0)
            }
            .padding(.leading, 7)
            .padding(.trailing, 12)
            .frame(width: TopoStyle.nodeWidth, height: TopoStyle.nodeHeight)
            .background(shape.fill(node.kind == .internet ? Color(light: 0xF8FAFC, dark: 0x20364B) : Theme.panel))
            .overlay {
                if isSelected {
                    shape.strokeBorder(Theme.accent, lineWidth: 2)
                } else if node.kind == .internet || node.isInferred {
                    shape.strokeBorder(Color(hex: 0x94A3B8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    shape.strokeBorder(Theme.borderStrong)
                }
            }
            .background {
                if node.kind == .groupe {
                    shape.fill(Theme.panel).overlay(shape.strokeBorder(Color(light: 0xCBD5E1, dark: 0x3F556E))).offset(x: 4, y: 4)
                }
            }
            .overlay {
                if isSearchCurrent {
                    RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 4).padding(-5)
                } else if searchCount != nil && !isSelected {
                    shape.strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5)
                }
            }
            .shadow(color: isDragged ? Color(hex: 0x0F172A, opacity: 0.25)
                        : (isSelected ? Theme.accent.opacity(0.28) : Color(hex: 0x0F172A, opacity: 0.06)),
                    radius: isDragged ? 8 : (isSelected ? 3 : 1), y: isDragged ? 4 : (isSelected ? 0 : 1))
            if node.kind != .internet && !(node.isInferred && node.deviceIDs.isEmpty) {
                Circle().fill(TopoStyle.statusColor(node.status)).frame(width: 7, height: 7).padding(6)
            }
            if isMoved {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.trailing, 5)
                    .padding(.top, 38)
                    .help("Placé à la main\u{00A0}; clic droit\u{00A0}: «\u{00A0}Remettre à sa place\u{00A0}»")
            }
        }
        .overlay(alignment: .topLeading) {
            if let searchCount {
                HStack(spacing: 2) {
                    Image(systemName: "magnifyingglass").font(.system(size: 7.5, weight: .bold))
                    if node.kind == .groupe { Text("\(searchCount)").font(.system(size: 9.5, weight: .bold)).monospacedDigit() }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(Capsule().fill(Theme.accent))
                .offset(x: -6, y: -7)
                .help(searchCount > 1 ? "\(searchCount) appareils trouvés dans ce groupe" : "Trouvé par la recherche")
            }
        }
        .opacity(isDimmed ? 0.4 : 1)
        .contentShape(Rectangle())
        .help("\(node.title) · \(node.subtitle)")
    }
}

/// Note 32 : ce que la recherche montre sur la carte.
struct TopoSearchHighlight {
    /// Nœud du résultat courant.
    var current: String?
    /// Appareils trouvés par nœud.
    var counts: [String: Int]
    /// Branche du résultat courant, d'Internet jusqu'à lui.
    var path: [String]

    func shows(_ id: String) -> Bool { counts[id] != nil || path.contains(id) }

    /// Liens de la branche du résultat courant (identifiés par l'enfant).
    func pathLinks(_ links: [(parent: TopoNode, child: TopoNode)]) -> Set<String> {
        let onPath = Set(path)
        return Set(links.filter { onPath.contains($0.parent.id) && onPath.contains($0.child.id) }.map(\.child.id))
    }
}
