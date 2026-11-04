import NetScopeCore
import SwiftUI

/// Couleurs et symboles des nœuds (croquis Topologie).
enum TopoStyle {
    static let wire = Color(hex: 0x94A3B8)
    static let wifi = Color(hex: 0x7C3AED)
    static let nodeWidth: CGFloat = 178
    static let nodeHeight: CGFloat = 54

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

    var body: some View {
        let links = graph.links.filter { layout.positions[$0.parent.id] != nil && layout.positions[$0.child.id] != nil }
        let related = relatedLinks(links)

        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { selectedID = nil }
            ForEach(links, id: \.child.id) { link in
                let highlighted = related.contains(link.child.id)
                linkPath(link)
                    .stroke(color(link, highlighted: highlighted),
                            style: StrokeStyle(lineWidth: highlighted ? 3 : 2, lineCap: .round, lineJoin: .round,
                                               dash: link.child.isWireless ? [5, 4] : []))
                    .opacity(selectedID == nil || highlighted ? 1 : 0.35)
            }
            if showPortLabels {
                ForEach(links, id: \.child.id) { link in
                    if let label = link.child.uplinkLabel, let position = labelPosition(link) {
                        Text(label)
                            .font(Theme.mono(10))
                            .foregroundStyle(link.child.isWireless ? TopoStyle.wifi : Theme.text)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panel))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                            .fixedSize()
                            .position(position)
                            .opacity(selectedID == nil || related.contains(link.child.id) ? 1 : 0.4)
                    }
                }
            }
            ForEach(graph.nodes) { node in
                if let center = point(node.id) {
                    TopoNodeView(node: node, isSelected: node.id == selectedID,
                                 isDimmed: selectedID != nil && !isRelated(node.id, links))
                        .position(center)
                        .onTapGesture { selectedID = node.id }
                }
            }
        }
    }

    private func point(_ id: String) -> CGPoint? {
        layout.positions[id].map { CGPoint(x: $0.x, y: $0.y) }
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
        if layout.stacked.contains(link.child.id) {
            return CGPoint(x: child.x + TopoStyle.nodeWidth / 2 - 30, y: top - 9)
        }
        return CGPoint(x: child.x, y: (busY(parent) + top) / 2)
    }

    private func color(_ link: (parent: TopoNode, child: TopoNode), highlighted: Bool) -> Color {
        if link.child.status == .critique { return Theme.critical }
        if highlighted { return Theme.accent }
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
            .shadow(color: isSelected ? Theme.accent.opacity(0.28) : Color(hex: 0x0F172A, opacity: 0.06),
                    radius: isSelected ? 3 : 1, y: isSelected ? 0 : 1)
            if node.kind != .internet && !(node.isInferred && node.deviceIDs.isEmpty) {
                Circle().fill(TopoStyle.statusColor(node.status)).frame(width: 7, height: 7).padding(6)
            }
        }
        .opacity(isDimmed ? 0.4 : 1)
        .contentShape(Rectangle())
        .help("\(node.title) · \(node.subtitle)")
    }
}
