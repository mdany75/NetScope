import Foundation

// Note 61 : export draw.io (diagrams.net) de la Carte du réseau, écrit à la main : fichier .drawio
// non compressé (mxfile → diagram → mxGraphModel). Un rectangle arrondi par nœud, à sa position sur
// la carte, coloré selon son type (passerelle, switch, point d'accès, type d'appareil), avec son
// point d'état ; un lien par câble, reliant les nœuds (ils suivent quand on les déplace dans
// draw.io), avec l'étiquette de ports. Modifiable ensuite dans draw.io, Confluence ou Visio.

public enum TopoDrawio {
    static let titleHeight = 56.0
    static let font = "Helvetica"

    /// Fichier .drawio complet (UTF-8).
    public static func make(_ scene: TopoExportScene, modified: Date = Date()) -> String {
        let e = TopoXML.escape, n = TopoXML.number
        let top = scene.title.isEmpty && scene.details.isEmpty ? 0 : titleHeight
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let name = scene.title.isEmpty ? "Carte du réseau" : scene.title
        let width = max(scene.width, 640), height = scene.height + top

        var cells = "<mxCell id=\"0\"/>\n<mxCell id=\"1\" parent=\"0\"/>\n"
        if top > 0 {
            var value = scene.title.isEmpty ? "" : "<b style=\"font-size:17px\">\(html(scene.title))</b>"
            if !scene.details.isEmpty {
                value += (value.isEmpty ? "" : "<br>") + "<span style=\"color:#4B5563;font-size:11px\">"
                    + html(scene.details.joined(separator: " · ")) + "</span>"
            }
            cells += "<mxCell id=\"titre\" value=\"\(e(value))\" style=\"text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;"
                + "fontFamily=\(font);fontColor=#111827;strokeColor=none;fillColor=none;\" vertex=\"1\" parent=\"1\">"
                + "<mxGeometry x=\"16\" y=\"8\" width=\"\(n(width - 32))\" height=\"44\" as=\"geometry\"/></mxCell>\n"
        }
        var ids: [String: String] = [:]
        for (index, node) in scene.nodes.enumerated() { ids[node.id] = "n-\(index + 1)" }
        // Nœuds avant les liens : draw.io dessine les liens par-dessus, mais les relie à leurs nœuds.
        for node in scene.nodes {
            guard let id = ids[node.id] else { continue }
            cells += self.node(node, id: id, scene: scene, top: top)
        }
        for (index, link) in scene.links.enumerated() {
            guard let source = ids[link.from], let target = ids[link.to] else { continue }
            cells += edge(link, id: "e-\(index + 1)", source: source, target: target, top: top)
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<mxfile host=\"NetScope\" agent=\"NetScope\" modified=\"\(formatter.string(from: modified))\" version=\"24.0.0\" type=\"device\">\n"
            + "<diagram id=\"carte-du-reseau\" name=\"\(e(name))\">\n"
            + "<mxGraphModel dx=\"\(n(width))\" dy=\"\(n(height))\" grid=\"1\" gridSize=\"10\" guides=\"1\" tooltips=\"1\" connect=\"1\" "
            + "arrows=\"1\" fold=\"1\" page=\"1\" pageScale=\"1\" pageWidth=\"\(n(width))\" pageHeight=\"\(n(height))\" math=\"0\" shadow=\"0\">\n"
            + "<root>\n" + cells + "</root>\n</mxGraphModel>\n</diagram>\n</mxfile>\n"
    }

    public static func data(_ scene: TopoExportScene, modified: Date = Date()) -> Data { Data(make(scene, modified: modified).utf8) }

    /// Texte sûr pour le HTML d'une étiquette draw.io (échappé une fois de plus pour l'attribut XML).
    static func html(_ text: String) -> String {
        var result = ""
        for char in text {
            switch char {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(char)
            }
        }
        return result
    }

    /// Style d'un nœud selon son type : couleurs de la pastille de la carte (fond pâle, contour
    /// foncé), tirets pour Internet et les nœuds déduits, ombre pour un groupe d'appareils.
    public static func nodeStyle(_ node: TopoExportScene.Node) -> String {
        let colors = TopoPalette.node(kind: node.kind, type: node.deviceType)
        var style = "rounded=1;arcSize=14;whiteSpace=wrap;html=1;align=left;verticalAlign=middle;spacingLeft=10;spacingRight=14;"
            + "fontFamily=\(font);fontSize=12;fontColor=#111827;fillColor=\(colors.bg.hex);strokeColor=\(colors.fg.hex);"
        if node.kind == .internet || node.isInferred { style += "dashed=1;dashPattern=4 3;" }
        if node.kind == .groupe { style += "shadow=1;" }
        if node.highlighted { style += "strokeWidth=3;strokeColor=\(TopoColor.hex(TopoPalette.exportAccent));" }
        else if node.status == .critique { style += "strokeWidth=2;strokeColor=\(TopoColor.hex(TopoPalette.exportCritical));" }
        if node.dimmed { style += "opacity=40;textOpacity=40;" }
        return style
    }

    static func node(_ node: TopoExportScene.Node, id: String, scene: TopoExportScene, top: Double) -> String {
        let e = TopoXML.escape, n = TopoXML.number
        let w = scene.nodeWidth, h = scene.nodeHeight
        let value = "<b>\(html(node.title))</b><br><span style=\"font-size:10px;color:#4B5563\">\(html(node.subtitle))</span>"
        var out = "<mxCell id=\"\(id)\" value=\"\(e(value))\" tooltip=\"\(e(node.kind.label))\" style=\"\(e(nodeStyle(node)))\" vertex=\"1\" parent=\"1\">"
            + "<mxGeometry x=\"\(n(node.center.x - w / 2))\" y=\"\(n(node.center.y - h / 2 + top))\" width=\"\(n(w))\" height=\"\(n(h))\" as=\"geometry\"/></mxCell>\n"
        if node.showsStatus {
            // Point d'état, enfant du nœud (il le suit quand on le déplace).
            let color = TopoColor.hex(TopoPalette.status(node.status))
            out += "<mxCell id=\"\(id)-etat\" value=\"\" style=\"ellipse;html=1;fillColor=\(color);strokeColor=none;movable=0;resizable=0;"
                + (node.dimmed ? "opacity=40;" : "") + "\" vertex=\"1\" parent=\"\(id)\">"
                + "<mxGeometry x=\"\(n(w - 13))\" y=\"6\" width=\"7\" height=\"7\" as=\"geometry\"/></mxCell>\n"
        }
        return out
    }

    /// Style d'un lien : couleur et tirets de la carte ; équerre (comme à l'écran) ou courbe.
    public static func edgeStyle(_ link: TopoExportScene.Link) -> String {
        var style = "endArrow=none;startArrow=none;html=1;rounded=0;fontFamily=Menlo;fontSize=10;labelBackgroundColor=#FFFFFF;"
            + "strokeColor=\(TopoColor.hex(link.style.color));strokeWidth=\(link.verified && link.style != .redundant ? "2.5" : "2");"
        switch link.style {
        case .wifi: style += "dashed=1;dashPattern=5 4;"
        case .redundant: style += "dashed=1;dashPattern=6 4;"
        default: break
        }
        if link.style == .lldp || link.style == .redundant || link.style == .wifi {
            style += "fontColor=\(TopoColor.hex(link.style.color));"
        }
        if link.curved {
            style += "curved=1;"
        } else {
            style += "edgeStyle=orthogonalEdgeStyle;"
        }
        if link.style != .redundant {
            // Du bas du parent au haut de l'enfant (au flanc gauche d'une feuille empilée).
            style += "exitX=0.5;exitY=1;exitDx=0;exitDy=0;" + (link.stacked ? "entryX=0;entryY=0.5;" : "entryX=0.5;entryY=0;") + "entryDx=0;entryDy=0;"
        }
        if link.dimmed { style += "opacity=30;textOpacity=40;" }
        return style
    }

    /// Points de passage : les coudes du tracé de la carte (ni le départ ni l'arrivée) ; pour un lien
    /// redondant, le milieu de sa courbe.
    static func waypoints(_ link: TopoExportScene.Link) -> [TopoGraph.Point] {
        if link.style == .redundant { return link.labelPoint.map { [$0] } ?? [] }
        if link.curved { return [] }
        let points = link.segments.map(\.end)
        guard points.count > 2 else { return [] }
        return Array(points.dropFirst().dropLast())
    }

    static func edge(_ link: TopoExportScene.Link, id: String, source: String, target: String, top: Double) -> String {
        let e = TopoXML.escape, n = TopoXML.number
        let points = waypoints(link)
        var geometry = "<mxGeometry relative=\"1\" as=\"geometry\">"
        if !points.isEmpty {
            geometry += "<Array as=\"points\">" + points.map { "<mxPoint x=\"\(n($0.x))\" y=\"\(n($0.y + top))\"/>" }.joined() + "</Array>"
        }
        geometry += "</mxGeometry>"
        return "<mxCell id=\"\(id)\" value=\"\(e(html(link.label ?? "")))\" style=\"\(e(edgeStyle(link)))\" edge=\"1\" parent=\"1\" "
            + "source=\"\(source)\" target=\"\(target)\">" + geometry + "</mxCell>\n"
    }
}
