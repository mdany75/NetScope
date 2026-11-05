import Foundation

// Note 61 : ce que montre la Carte du réseau, prêt à exporter (SVG, draw.io, liste des liens du
// rapport). La scène reprend exactement le dessin de l'écran : nœuds aux positions de la
// disposition (nœuds placés à la main compris), liens tracés comme à l'écran, nœuds atténués par
// le filtre VLAN ou la recherche. Rien de plus que ce que montre la carte (aucune adresse MAC,
// aucune note, aucun secret).

/// Réglages d'un export de la carte.
public struct TopoExportOptions: Hashable, Sendable {
    /// « Carte du réseau — Siège » ; vide : pas de titre.
    public var title: String
    /// Lignes sous le titre : filtre VLAN, recherche, date (« VLAN 40 · Caméras », « 5 novembre 2026 »).
    public var details: [String]
    public var showPortLabels: Bool
    /// Nœuds atténués (filtre VLAN, recherche), comme à l'écran.
    public var dimmed: Set<String>
    /// Nœuds trouvés par la recherche (contour de couleur).
    public var highlighted: Set<String>
    /// Légende sous la carte (SVG).
    public var showLegend: Bool
    public var nodeWidth: Double
    public var nodeHeight: Double

    public init(title: String = "", details: [String] = [], showPortLabels: Bool = true, dimmed: Set<String> = [],
                highlighted: Set<String> = [], showLegend: Bool = true, nodeWidth: Double = 178, nodeHeight: Double = 54) {
        self.title = title
        self.details = details
        self.showPortLabels = showPortLabels
        self.dimmed = dimmed
        self.highlighted = highlighted
        self.showLegend = showLegend
        self.nodeWidth = nodeWidth
        self.nodeHeight = nodeHeight
    }
}

public struct TopoExportScene: Sendable {
    public struct Node: Hashable, Sendable {
        public var id: String
        public var kind: TopoNodeKind
        public var deviceType: DeviceType?
        public var title: String
        public var subtitle: String
        public var status: TopoStatus
        public var isInferred: Bool
        /// Point d'état dessiné (pas pour Internet ni pour un switch déduit sans appareil).
        public var showsStatus: Bool
        /// Centre du nœud, dans le dessin à 100 %.
        public var center: TopoGraph.Point
        public var dimmed: Bool
        public var highlighted: Bool
        /// Placé à la main.
        public var moved: Bool
    }

    /// Aspect d'un lien.
    public enum LinkStyle: String, Hashable, Sendable {
        /// Câble déduit du scan (gris).
        case wire
        /// Wi-Fi (violet, tirets).
        case wifi
        /// Vu par LLDP ou la FortiGate (vert sarcelle).
        case lldp
        /// Lien redondant vu par LLDP, hors de la hiérarchie (courbe en tirets).
        case redundant
        /// Vers un appareil en conflit IP (rouge).
        case critical

        public var color: UInt32 {
            switch self {
            case .wire: return TopoPalette.wire.light
            case .wifi: return TopoPalette.wifi.light
            case .lldp, .redundant: return TopoPalette.lldp.light
            case .critical: return TopoPalette.exportCritical
            }
        }

        public var isDashed: Bool { self == .wifi || self == .redundant }
    }

    public struct Link: Hashable, Sendable {
        public var id: String
        /// Bout du haut (parent) et bout du bas (enfant) ; pour un lien redondant, les deux bouts.
        public var from: String
        public var to: String
        public var style: LinkStyle
        /// Étiquette de ports (« Gi1/0/47 ↔ 1/25 », « 12 ports », « Wi-Fi ») ; nil : aucune.
        public var label: String?
        public var labelPoint: TopoGraph.Point?
        public var segments: [TopoPathSegment]
        public var dimmed: Bool
        /// Feuille empilée (le lien arrive sur son flanc gauche).
        public var stacked: Bool
        /// Courbe (nœud placé à la main ou lien redondant) plutôt qu'équerre.
        public var curved: Bool
        /// Lien vu par LLDP ou la FortiGate (dans la hiérarchie ou redondant).
        public var verified: Bool
    }

    public var nodes: [Node]
    public var links: [Link]
    /// Taille du dessin (sans titre ni légende).
    public var width: Double
    public var height: Double
    public var nodeWidth: Double
    public var nodeHeight: Double
    public var title: String
    public var details: [String]
    public var showLegend: Bool

    public var hasRedundant: Bool { links.contains { $0.style == .redundant } }
    public var hasVerified: Bool { links.contains(where: \.verified) }

    /// Scène de la carte : nœuds placés par `layout` (les nœuds masqués, sans position, sont omis),
    /// liens de la hiérarchie et liens redondants entre nœuds dessinés.
    public static func make(graph: TopoGraph, layout: TopoGraph.Layout, options: TopoExportOptions = TopoExportOptions()) -> TopoExportScene {
        let w = options.nodeWidth, h = options.nodeHeight
        var nodes: [Node] = []
        for node in graph.nodes {
            guard let center = layout.positions[node.id] else { continue }
            nodes.append(Node(id: node.id, kind: node.kind, deviceType: node.deviceType, title: node.title, subtitle: node.subtitle,
                              status: node.status, isInferred: node.isInferred,
                              showsStatus: node.kind != .internet && !(node.isInferred && node.deviceIDs.isEmpty),
                              center: center, dimmed: options.dimmed.contains(node.id),
                              highlighted: options.highlighted.contains(node.id), moved: layout.moved.contains(node.id)))
        }
        var links: [Link] = []
        for redundant in graph.redundantLinks {
            guard let a = layout.positions[redundant.aID], let b = layout.positions[redundant.bID] else { continue }
            let curve = TopoGeometry.redundantCurve(a, b, nodeWidth: w, nodeHeight: h)
            links.append(Link(id: "r:" + redundant.id, from: redundant.aID, to: redundant.bID, style: .redundant,
                              label: options.showPortLabels ? redundant.portsLabel : nil,
                              labelPoint: TopoGeometry.redundantMidpoint(curve),
                              segments: [.move(curve.start), .quad(curve.end, control: curve.control)],
                              dimmed: options.dimmed.contains(redundant.aID) || options.dimmed.contains(redundant.bID),
                              stacked: false, curved: true, verified: true))
        }
        for link in graph.links {
            guard let parent = layout.positions[link.parent.id], let child = layout.positions[link.child.id] else { continue }
            let free = layout.moved.contains(link.parent.id) || layout.moved.contains(link.child.id)
            let stacked = layout.stacked.contains(link.child.id)
            let style: LinkStyle
            if link.child.status == .critique { style = .critical }
            else if link.child.uplinkKind != nil { style = .lldp }
            else if link.child.isWireless { style = .wifi }
            else { style = .wire }
            let label = options.showPortLabels ? link.child.uplinkLabel.flatMap { $0.isEmpty ? nil : $0 } : nil
            links.append(Link(id: "t:" + link.child.id, from: link.parent.id, to: link.child.id, style: style, label: label,
                              labelPoint: label == nil ? nil : TopoGeometry.treeLabel(parent: parent, child: child, free: free, stacked: stacked,
                                                                                      nodeWidth: w, nodeHeight: h),
                              segments: TopoGeometry.treePath(parent: parent, child: child, free: free, stacked: stacked,
                                                              nodeWidth: w, nodeHeight: h),
                              dimmed: options.dimmed.contains(link.child.id) || options.dimmed.contains(link.parent.id),
                              stacked: stacked, curved: free, verified: link.child.uplinkKind != nil))
        }
        // Un lien vers un nœud en conflit partage souvent la descente des liens voisins : dessiné
        // juste après les redondants, sous les autres, il ne teinte en rouge que son propre tronçon.
        let firstTree = links.firstIndex { $0.style != .redundant } ?? links.endIndex
        let tree = links[firstTree...]
        links = Array(links[..<firstTree]) + tree.filter { $0.style == .critical } + tree.filter { $0.style != .critical }
        return TopoExportScene(nodes: nodes, links: links, width: layout.width, height: layout.height, nodeWidth: w, nodeHeight: h,
                               title: options.title, details: options.details, showLegend: options.showLegend)
    }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    // MARK: Légende

    /// Élément de la légende (commun au SVG, à l'image et au rapport).
    public struct LegendItem: Hashable, Sendable {
        public enum Mark: Hashable, Sendable {
            case node(TopoNodeKind)
            case group
            case line(LinkStyle)
            case dot(UInt32)
        }
        public var mark: Mark
        public var label: String
    }

    /// Légende : types de nœuds, puis aspects des liens (LLDP et redondants seulement s'il y en a).
    public var legend: [LegendItem] {
        Self.legend(hasVerified: hasVerified, hasRedundant: hasRedundant)
    }

    public static func legend(hasVerified: Bool, hasRedundant: Bool) -> [LegendItem] {
        var items: [LegendItem] = [
            LegendItem(mark: .node(.internet), label: "Internet"),
            LegendItem(mark: .node(.passerelle), label: "Passerelle"),
            LegendItem(mark: .node(.switch), label: "Switch"),
            LegendItem(mark: .node(.pointAcces), label: "Point d’accès"),
            LegendItem(mark: .group, label: "Groupe agrégé"),
            LegendItem(mark: .line(.wire), label: "Filaire"),
            LegendItem(mark: .line(.wifi), label: "Wi-Fi"),
        ]
        if hasVerified { items.append(LegendItem(mark: .line(.lldp), label: "LLDP / FortiLink")) }
        if hasRedundant { items.append(LegendItem(mark: .line(.redundant), label: "Lien redondant")) }
        items.append(LegendItem(mark: .dot(TopoPalette.status(.critique)), label: "Conflit IP"))
        items.append(LegendItem(mark: .dot(TopoPalette.status(.horsLigne)), label: "Hors ligne"))
        return items
    }

    // MARK: Liens entre équipements

    /// Lien entre équipements réseau (passerelle, switchs, points d'accès), pour la liste du rapport.
    public struct InfraLinkRow: Hashable, Sendable {
        public var from: String
        public var fromPort: String?
        public var to: String
        public var toPort: String?
        /// « ISL », « FortiLink », « Uplink », « AP », « Wi-Fi », « Déduit ».
        public var kind: String
        public var speed: String?
        /// « LLDP (SNMP) », « FortiGate », « Scan (tables MAC) ».
        public var source: String
        public var redundant: Bool
    }

    /// Liens entre équipements réseau de la carte : ceux vus par LLDP ou la FortiGate (hiérarchie et
    /// redondants), puis ceux de la hiérarchie déduits du scan (champ « switch » des appareils).
    /// Les groupes et appareils finaux n'y sont pas. Ordre : hiérarchie d'abord, du haut vers le bas.
    public static func infraLinkRows(_ graph: TopoGraph) -> [InfraLinkRow] {
        let infra: Set<TopoNodeKind> = [.passerelle, .switch, .pointAcces]
        func name(_ id: String) -> String { graph.node(id)?.title ?? id }
        var rows: [InfraLinkRow] = []
        var seen: Set<String> = []
        func order(_ id: String) -> Int { graph.nodes.firstIndex { $0.id == id } ?? Int.max }
        let verified = graph.infraLinks.sorted { lhs, rhs in
            if lhs.isTree != rhs.isTree { return lhs.isTree }
            return (order(lhs.bID), order(lhs.aID)) < (order(rhs.bID), order(rhs.aID))
        }
        for link in verified {
            guard graph.node(link.aID) != nil, graph.node(link.bID) != nil else { continue }
            seen.insert(link.isTree ? link.bID : "r:" + link.id)
            rows.append(InfraLinkRow(from: name(link.aID), fromPort: link.aPort, to: name(link.bID), toPort: link.bPort,
                                     kind: link.kind.shortLabel, speed: link.speedLabel, source: link.sourceLabel,
                                     redundant: !link.isTree))
        }
        for link in graph.links where infra.contains(link.parent.kind) && infra.contains(link.child.kind) && !seen.contains(link.child.id) {
            // Nœud « Switchs » des ports inconnus : regroupement, pas un vrai lien.
            if link.child.id == "sw:?" { continue }
            let wireless = link.child.isWireless
            rows.append(InfraLinkRow(from: link.parent.title, fromPort: nil, to: link.child.title,
                                     toPort: link.child.uplinkLabel.flatMap { $0.isEmpty || wireless ? nil : $0 },
                                     kind: wireless ? "Wi-Fi" : (link.child.kind == .pointAcces ? "AP" : "Déduit"), speed: nil,
                                     source: "Scan (tables MAC)", redundant: false))
        }
        return rows
    }
}

// MARK: - Texte

/// Mesure estimée d'un texte (police système), pour couper les libellés trop longs du SVG.
public enum TopoTextFit {
    public static func width(_ text: String, size: Double, bold: Bool = false, mono: Bool = false) -> Double {
        if mono { return Double(text.count) * size * 0.61 }
        var em = 0.0
        for char in text {
            if char == " " { em += 0.28 }
            else if char == "W" || char == "M" || char == "m" || char == "w" { em += 0.82 }
            else if char.isUppercase { em += 0.66 }
            else if char.isNumber { em += 0.58 }
            else if "ilj.,:;·'’()|!I".contains(char) { em += 0.28 }
            else if "-–_/".contains(char) { em += 0.4 }
            else { em += 0.54 }
        }
        return em * size * (bold ? 1.06 : 1)
    }

    /// Texte coupé avec « … » pour tenir dans `maxWidth`.
    public static func truncate(_ text: String, size: Double, maxWidth: Double, bold: Bool = false, mono: Bool = false) -> String {
        guard width(text, size: size, bold: bold, mono: mono) > maxWidth else { return text }
        var chars = Array(text)
        while !chars.isEmpty, width(String(chars) + "…", size: size, bold: bold, mono: mono) > maxWidth { chars.removeLast() }
        return String(chars).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Texte réparti mot par mot sur `maxLines` lignes au plus (la dernière terminée par « … »).
    public static func lines(_ text: String, size: Double, maxWidth: Double, maxLines: Int, bold: Bool = false) -> [String] {
        var result: [String] = []
        var words = text.split(separator: " ").map(String.init)
        while !words.isEmpty, result.count < maxLines - 1 {
            var line = ""
            while let word = words.first {
                let candidate = line.isEmpty ? word : line + " " + word
                if !line.isEmpty, width(candidate, size: size, bold: bold) > maxWidth { break }
                line = candidate
                words.removeFirst()
            }
            result.append(truncate(line, size: size, maxWidth: maxWidth, bold: bold))
        }
        if !words.isEmpty { result.append(truncate(words.joined(separator: " "), size: size, maxWidth: maxWidth, bold: bold)) }
        return result.isEmpty ? [""] : result
    }

    /// Libellé d'un nœud : une ligne à 12 pt, sinon à 10,5 pt, sinon deux lignes coupées à un espace
    /// (la seconde terminée par « … » au besoin). Renvoie les lignes et la taille.
    public static func title(_ text: String, maxWidth: Double) -> (lines: [String], size: Double) {
        if width(text, size: 12, bold: true) <= maxWidth { return ([text], 12) }
        if width(text, size: 10.5, bold: true) <= maxWidth { return ([text], 10.5) }
        let words = text.split(separator: " ").map(String.init)
        if words.count > 1 {
            var first = ""
            var index = 0
            while index < words.count {
                let candidate = first.isEmpty ? words[index] : first + " " + words[index]
                if width(candidate, size: 10.5, bold: true) > maxWidth { break }
                first = candidate
                index += 1
            }
            if !first.isEmpty, index < words.count {
                let rest = words[index...].joined(separator: " ")
                return ([first, truncate(rest, size: 10.5, maxWidth: maxWidth, bold: true)], 10.5)
            }
        }
        return ([truncate(text, size: 10.5, maxWidth: maxWidth, bold: true)], 10.5)
    }
}

// MARK: - XML

public enum TopoXML {
    /// Texte sûr pour XML (contenu et attributs) : caractères spéciaux échappés, sauts de ligne
    /// gardés en entité (dans un attribut), caractères de contrôle interdits retirés.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n": result += "&#xa;"
            case "\r": continue
            case "\t": result += " "
            default:
                if scalar.value < 0x20 { continue }
                if scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Nombre écrit sans décimales inutiles (« 120 », « 120.5 »), point décimal (SVG et draw.io).
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}
