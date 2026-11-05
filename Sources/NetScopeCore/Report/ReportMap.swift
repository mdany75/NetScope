import Foundation

// Note 61 : section « Carte du réseau » des rapports. L'image de la carte est dessinée par
// l'application (rendu SwiftUI de la carte entière, en clair) ; le moteur en tire le texte, les
// indicateurs, la légende et la liste des liens entre équipements réseau (switchs, passerelle,
// points d'accès), d'après la même carte (TopoGraph) que l'écran. Aucun accès réseau.

/// Carte d'un site pour le rapport.
public struct ReportMap: Sendable {
    public var siteName: String
    /// Image de la carte (PNG) ; nil : aucune image (la liste des liens reste).
    public var image: ReportImage?
    public var gateways: Int
    /// Switchs vus par le scan, et ceux connus seulement par leur nom, LLDP ou la FortiGate.
    public var switches: Int
    public var inferredSwitches: Int
    public var accessPoints: Int
    /// Groupes et appareils finaux dessinés (nœuds), et appareils qu'ils représentent.
    public var endNodes: Int
    public var endDevices: Int
    public var links: [TopoExportScene.InfraLinkRow]
    public var legend: [TopoExportScene.LegendItem]

    public init(siteName: String, image: ReportImage?, gateways: Int, switches: Int, inferredSwitches: Int, accessPoints: Int,
                endNodes: Int, endDevices: Int, links: [TopoExportScene.InfraLinkRow], legend: [TopoExportScene.LegendItem]) {
        self.siteName = siteName
        self.image = image
        self.gateways = gateways
        self.switches = switches
        self.inferredSwitches = inferredSwitches
        self.accessPoints = accessPoints
        self.endNodes = endNodes
        self.endDevices = endDevices
        self.links = links
        self.legend = legend
    }

    /// Carte du rapport d'après le graphe de la carte du site.
    public static func make(graph: TopoGraph, siteName: String, image: ReportImage?) -> ReportMap {
        let switches = graph.nodes.filter { $0.kind == .switch && $0.id != "sw:?" }
        let ends = graph.nodes.filter { $0.kind == .groupe || $0.kind == .appareil }
        return ReportMap(siteName: siteName, image: image,
                         gateways: graph.node("passerelle")?.isInferred == false ? 1 : 0,
                         switches: switches.filter { !$0.isInferred }.count,
                         inferredSwitches: switches.filter(\.isInferred).count,
                         accessPoints: graph.nodes.filter { $0.kind == .pointAcces }.count,
                         endNodes: ends.count, endDevices: ends.reduce(0) { $0 + $1.deviceIDs.count },
                         links: TopoExportScene.infraLinkRows(graph),
                         legend: TopoExportScene.legend(hasVerified: !graph.infraLinks.isEmpty, hasRedundant: !graph.redundantLinks.isEmpty))
    }

    /// Légende en mots (pour le texte du rapport, le CSV et le JSON).
    public var legendText: String {
        let parts = legend.compactMap { item -> String? in
            switch item.mark {
            case .node: return nil
            case .group: return "carte empilée\u{00A0}: groupe d’appareils du même type sous un même switch"
            case .line(let style):
                switch style {
                case .wire: return "trait gris\u{00A0}: câble déduit des tables d’adresses MAC"
                case .wifi: return "tirets violets\u{00A0}: Wi-Fi"
                case .lldp: return "trait vert\u{00A0}: lien vu par LLDP ou la FortiGate (FortiLink, ISL)"
                case .redundant: return "courbe verte en tirets\u{00A0}: lien redondant (deuxième chemin, anneau)"
                case .critical: return "trait rouge\u{00A0}: vers un appareil en conflit IP"
                }
            case .dot(let color):
                return color == TopoPalette.status(.critique) ? "point rouge\u{00A0}: conflit IP"
                    : (color == TopoPalette.status(.horsLigne) ? "point gris\u{00A0}: hors ligne" : nil)
            }
        }
        return "Légende\u{00A0}: " + (["point vert\u{00A0}: en ligne"] + parts).joined(separator: "\u{00A0}; ") + "."
    }
}

extension ReportBuilder {
    /// Section « Carte du réseau » : synthèse, indicateurs, image, légende et liens entre équipements.
    public static func mapBlocks(_ map: ReportMap?) -> [ReportBlock] {
        guard let map, map.endDevices + map.switches + map.accessPoints + map.gateways > 0 else {
            return [.note("Aucune carte du réseau pour ce site\u{00A0}: lancer un scan (écran Scanner)\u{00A0}; la carte se construit à partir du dernier scan, des relevés des switchs (SNMP, LLDP) et de la FortiGate.")]
        }
        var equipment: [String] = []
        if map.gateways > 0 { equipment.append("1\u{00A0}passerelle") }
        let switchTotal = map.switches + map.inferredSwitches
        equipment.append(plural(switchTotal, "switch", "switchs").replacingOccurrences(of: " ", with: "\u{00A0}")
                         + (map.inferredSwitches > 0 ? " (dont \(map.inferredSwitches) hors scan)" : ""))
        equipment.append(plural(map.accessPoints, "point d’accès", "points d’accès"))
        var text = "Carte du réseau de «\u{00A0}\(map.siteName)\u{00A0}» d’après le dernier scan\u{00A0}: "
        text += equipment.dropLast().joined(separator: ", ") + " et " + (equipment.last ?? "")
        text += ", qui desservent \(plural(map.endDevices, "appareil", "appareils")) regroupés par type."
        let verified = map.links.filter { $0.source != "Scan (tables MAC)" }.count
        text += verified > 0
            ? " Les liens entre équipements viennent des voisins LLDP relus par SNMP et de la FortiGate\u{00A0}; les autres rattachements sont déduits des tables d’adresses MAC."
            : " Les rattachements sont déduits des tables d’adresses MAC\u{00A0}; les liens physiques exacts demandent SNMP et LLDP sur les switchs (écran Switchs et ports)."
        var blocks: [ReportBlock] = [.paragraph(text)]
        let redundant = map.links.filter(\.redundant).count
        blocks.append(.kpis([
            ReportKPI("\(map.gateways + switchTotal + map.accessPoints)", "équipements réseau"),
            ReportKPI("\(map.endDevices)", map.endDevices > 1 ? "appareils sur la carte" : "appareil sur la carte"),
            ReportKPI("\(verified)", verified > 1 ? "liens LLDP ou FortiGate" : "lien LLDP ou FortiGate"),
            ReportKPI("\(redundant)", redundant > 1 ? "liens redondants" : "lien redondant"),
        ]))
        // L'image porte sa légende dessinée ; sans image, la légende en mots.
        if let image = map.image { blocks.append(.image(image)) } else { blocks.append(.note(map.legendText)) }
        guard !map.links.isEmpty else {
            blocks.append(.note("Aucun lien entre équipements réseau n’est connu pour ce site."))
            return blocks
        }
        // Vitesse et source insécables (« 10 Gb/s », « LLDP (SNMP) ») : jamais coupées en deux lignes.
        func whole(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "\u{00A0}") }
        let rows = map.links.map { link in
            ReportRow([
                ReportCell(link.from, bold: true),
                ReportCell(link.fromPort ?? "—", tone: link.fromPort == nil ? .muted : .normal),
                ReportCell(link.to, bold: true),
                ReportCell(link.toPort ?? "—", tone: link.toPort == nil ? .muted : .normal),
                ReportCell(link.redundant ? link.kind + " · redondant" : link.kind, badge: link.redundant ? .caution : nil),
                ReportCell(whole(link.speed ?? "—"), tone: link.speed == nil ? .muted : .normal),
                ReportCell(whole(link.source), tone: link.source == "Scan (tables MAC)" ? .muted : .normal),
            ])
        }
        blocks.append(.table(ReportTable(columns: [
            ReportColumn("Équipement", weight: 1.6), ReportColumn("Port", weight: 1, mono: true, shrinks: true),
            ReportColumn("Voisin", weight: 1.6), ReportColumn("Port", weight: 1, mono: true, shrinks: true),
            ReportColumn("Type", weight: 1.1), ReportColumn("Vitesse", weight: 0.8, trailing: true),
            ReportColumn("Source", weight: 1.2),
        ], rows: rows, wraps: true)))
        return blocks
    }
}
