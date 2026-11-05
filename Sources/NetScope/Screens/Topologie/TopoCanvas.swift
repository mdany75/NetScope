import NetScopeCore
import SwiftUI

/// Couleurs et symboles des nœuds (croquis Topologie).
enum TopoStyle {
    static let wire = Color(hex: 0x94A3B8)
    static let wifi = Color(hex: 0x7C3AED)
    /// Note 78 : liens vus par LLDP ou la FortiGate (ISL, uplinks, FortiLink).
    static let lldp = Color(light: 0x0F766E, dark: 0x4FC3B5)
    static let nodeWidth: CGFloat = 178
    static let nodeHeight: CGFloat = 54
    /// Marge du dessin (disposition et nœuds déplacés).
    static let margin: CGFloat = 22

    static func colors(kind: TopoNodeKind, type: DeviceType?) -> (fg: Color, bg: Color) {
        switch kind {
        case .internet: return (Color(light: 0x475569, dark: 0xB6C0CE), Color(light: 0xF1F5F9, dark: 0x20364B))
        case .passerelle: return (Color(light: 0x4338CA, dark: 0xA49EE5), Color(light: 0xE0E7FF, dark: 0x1B2750))
        case .switch: return (Color(light: 0x1D4ED8, dark: 0x93ACF1), Color(light: 0xDBEAFE, dark: 0x1B3250))
        case .pointAcces: return (Color(light: 0x6D28D9, dark: 0xB897ED), Color(light: 0xEDE9FE, dark: 0x251B50))
        case .groupe, .appareil:
            switch type {
            case .imprimante: return (Color(light: 0x0E7490, dark: 0x8FDEF4), Color(light: 0xCFFAFE, dark: 0x1B4C50))
            case .camera: return (Color(light: 0x92400E, dark: 0xF4B68F), Color(light: 0xFEF3C7, dark: 0x50461B))
            case .serveur: return (Color(light: 0x1E3A8A, dark: 0x9AAFE9), Color(light: 0xE0E7FF, dark: 0x1B2750))
            case .telephone: return (Color(light: 0x6D28D9, dark: 0xB897ED), Color(light: 0xF5F3FF, dark: 0x241B50))
            case .telephoneIP: return (Color(light: 0xBE185D, dark: 0xF29BC4), Color(light: 0xFCE7F3, dark: 0x50203A))
            default: return (Color(light: 0x374151, dark: 0xB6BFCE), Color(light: 0xF3F4F6, dark: 0x2E333D))
            }
        }
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
        let links = graph.links.filter { layout.positions[$0.parent.id] != nil && layout.positions[$0.child.id] != nil }
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

    /// Courbe d'un lien redondant. Deux nœuds sur la même rangée (switchs voisins d'un anneau) :
    /// arc sous eux, du bas de l'un au bas de l'autre, au-dessus du palier de leurs enfants (les
    /// étiquettes des liens vers le parent restent seules au-dessus). Sinon : courbe entre les
    /// centres, bombée sur le côté.
    private func redundantCurve(_ link: TopoInfraLink) -> (start: CGPoint, control: CGPoint, end: CGPoint)? {
        guard let a = point(link.aID), let b = point(link.bID) else { return nil }
        if abs(a.y - b.y) < TopoStyle.nodeHeight {
            let (left, right) = a.x <= b.x ? (a, b) : (b, a)
            let bottom = max(left.y, right.y) + TopoStyle.nodeHeight / 2
            let inset = TopoStyle.nodeWidth / 4
            let start = CGPoint(x: left.x + inset, y: left.y + TopoStyle.nodeHeight / 2)
            let end = CGPoint(x: right.x - inset, y: right.y + TopoStyle.nodeHeight / 2)
            return (start, CGPoint(x: (start.x + end.x) / 2, y: bottom + 30), end)
        }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(sqrt(dx * dx + dy * dy), 1)
        let bulge = min(90, max(50, length * 0.3))
        return (a, CGPoint(x: mid.x - dy / length * bulge, y: mid.y + dx / length * bulge), b)
    }

    /// Milieu de la courbe d'un lien redondant (étiquette des ports).
    private func redundantMidpoint(_ link: TopoInfraLink) -> CGPoint? {
        guard let curve = redundantCurve(link) else { return nil }
        return CGPoint(x: 0.25 * curve.start.x + 0.5 * curve.control.x + 0.25 * curve.end.x,
                       y: 0.25 * curve.start.y + 0.5 * curve.control.y + 0.25 * curve.end.y)
    }

    /// Ordonnée du palier horizontal entre un parent et ses enfants.
    private func busY(_ parent: CGPoint) -> CGFloat {
        parent.y + TopoStyle.nodeHeight / 2 + 24
    }

    /// Lien en équerre : du bas du parent jusqu'au haut de l'enfant ; pour une feuille empilée,
    /// par un rail à gauche de sa colonne jusqu'à son flanc gauche.
    private func linkPath(_ link: (parent: TopoNode, child: TopoNode)) -> Path {
        Path { path in
            guard let parent = point(link.parent.id), let child = point(link.child.id) else { return }
            let start = CGPoint(x: parent.x, y: parent.y + TopoStyle.nodeHeight / 2)
            if isFree(link.parent.id) || isFree(link.child.id) {
                // Nœud placé à la main : courbe du bas du parent au haut de l'enfant.
                let end = CGPoint(x: child.x, y: child.y - TopoStyle.nodeHeight / 2)
                let bend = max(abs(end.y - start.y) / 2, 40)
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + bend), control2: CGPoint(x: end.x, y: end.y - bend))
                return
            }
            let bus = busY(parent)
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x, y: bus))
            if layout.stacked.contains(link.child.id) {
                let rail = child.x - TopoStyle.nodeWidth / 2 - 12
                path.addLine(to: CGPoint(x: rail, y: bus))
                path.addLine(to: CGPoint(x: rail, y: child.y))
                path.addLine(to: CGPoint(x: child.x - TopoStyle.nodeWidth / 2, y: child.y))
            } else {
                let end = CGPoint(x: child.x, y: child.y - TopoStyle.nodeHeight / 2)
                path.addLine(to: CGPoint(x: end.x, y: bus))
                path.addLine(to: end)
            }
        }
    }

    /// Étiquette de port : sur la descente vers l'enfant, ou au-dessus d'une feuille empilée.
    private func labelPosition(_ link: (parent: TopoNode, child: TopoNode)) -> CGPoint? {
        guard let parent = point(link.parent.id), let child = point(link.child.id) else { return nil }
        let top = child.y - TopoStyle.nodeHeight / 2
        if isFree(link.parent.id) || isFree(link.child.id) {
            // Sur la fin de la courbe, juste au-dessus de l'enfant (elle y arrive à la verticale) :
            // les étiquettes de deux enfants voisins ne se chevauchent pas.
            let gap = top - (parent.y + TopoStyle.nodeHeight / 2)
            return CGPoint(x: child.x, y: top - min(max(gap / 2, 11), 16))
        }
        if layout.stacked.contains(link.child.id) {
            return CGPoint(x: child.x + TopoStyle.nodeWidth / 2 - 30, y: top - 9)
        }
        return CGPoint(x: child.x, y: (busY(parent) + top) / 2)
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
