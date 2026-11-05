import Foundation

// Note 61 : export SVG de la Carte du réseau, écrit à la main (aucune dépendance). Nœuds (pastille
// d'icône, nom, sous-titre, point d'état), liens tracés comme à l'écran, étiquettes de ports,
// titre et légende ; couleurs du thème clair sur fond blanc. Lisible par les navigateurs,
// Illustrator, Inkscape, Visio et draw.io.

public enum TopoSVG {
    static let font = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"
    static let monoFont = "'SF Mono', Menlo, Consolas, monospace"
    static let headerHeight = 58.0
    static let legendRowHeight = 22.0
    static let minWidth = 640.0

    /// Document SVG complet (UTF-8).
    public static func make(_ scene: TopoExportScene) -> String {
        let e = TopoXML.escape, n = TopoXML.number
        // Marge de 16 points autour du dessin (comme l'image PNG).
        let width = max(scene.width, minWidth) + 32
        let top = scene.title.isEmpty && scene.details.isEmpty ? 16 : headerHeight
        let legendRows = scene.showLegend ? legendLayout(scene.legend, width: width - 32) : []
        let legendHeight = legendRows.isEmpty ? 0 : Double(legendRows.count) * legendRowHeight + 14
        let height = top + scene.height + legendHeight + 16
        // Dessin centré quand la page est plus large que la carte.
        let offsetX = (width - scene.width) / 2

        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" version=\"1.1\" width=\"\(n(width))\" height=\"\(n(height))\" "
            + "viewBox=\"0 0 \(n(width)) \(n(height))\" font-family=\"\(e(font))\">\n"
        out += "<title>\(e(scene.title.isEmpty ? "Carte du réseau" : scene.title))</title>\n"
        out += "<desc>\(e(descText(scene)))</desc>\n"
        out += icons
        out += "<rect x=\"0\" y=\"0\" width=\"\(n(width))\" height=\"\(n(height))\" fill=\"\(TopoColor.hex(0xFFFFFF))\"/>\n"
        if !(scene.title.isEmpty && scene.details.isEmpty) { out += header(scene, width: width) }

        out += "<g id=\"carte\" transform=\"translate(\(n(offsetX)) \(n(top)))\">\n"
        out += "<rect x=\"0\" y=\"0\" width=\"\(n(scene.width))\" height=\"\(n(scene.height))\" fill=\"\(TopoColor.hex(TopoPalette.exportBackground))\" rx=\"8\"/>\n"
        // Liens (redondants d'abord, sous les autres), puis étiquettes, puis nœuds.
        out += "<g id=\"liens\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
        for link in scene.links { out += path(link) }
        out += "</g>\n"
        if scene.links.contains(where: { $0.label != nil }) {
            out += "<g id=\"ports\" font-family=\"\(e(monoFont))\" font-size=\"10\" text-anchor=\"middle\">\n"
            for link in scene.links { out += portLabel(link) }
            out += "</g>\n"
        }
        out += "<g id=\"noeuds\">\n"
        for node in scene.nodes { out += self.node(node, scene: scene) }
        out += "</g>\n</g>\n"
        if !legendRows.isEmpty { out += legend(legendRows, top: top + scene.height + 10, left: 16) }
        out += "</svg>\n"
        return out
    }

    public static func data(_ scene: TopoExportScene) -> Data { Data(make(scene).utf8) }

    static func descText(_ scene: TopoExportScene) -> String {
        "Carte du réseau exportée par NetScope\u{00A0}: \(scene.nodes.count) nœud\(scene.nodes.count > 1 ? "s" : ""), \(scene.links.count) lien\(scene.links.count > 1 ? "s" : "")."
    }

    // MARK: En-tête et légende

    static func header(_ scene: TopoExportScene, width: Double) -> String {
        let e = TopoXML.escape, n = TopoXML.number
        var out = "<g id=\"entete\">\n"
        if !scene.title.isEmpty {
            out += "<text x=\"16\" y=\"26\" font-size=\"17\" font-weight=\"700\" fill=\"\(TopoColor.hex(TopoPalette.exportText))\">"
                + e(TopoTextFit.truncate(scene.title, size: 17, maxWidth: width - 32, bold: true)) + "</text>\n"
        }
        if !scene.details.isEmpty {
            let line = scene.details.joined(separator: " · ")
            out += "<text x=\"16\" y=\"\(n(scene.title.isEmpty ? 26 : 45))\" font-size=\"11.5\" fill=\"\(TopoColor.hex(TopoPalette.exportSecondary))\">"
                + e(TopoTextFit.truncate(line, size: 11.5, maxWidth: width - 32)) + "</text>\n"
        }
        return out + "</g>\n"
    }

    /// Éléments de la légende répartis en lignes (x de chaque élément).
    static func legendLayout(_ items: [TopoExportScene.LegendItem], width: Double) -> [[(item: TopoExportScene.LegendItem, x: Double)]] {
        let title = TopoTextFit.width("LÉGENDE", size: 10, bold: true) + 14
        var rows: [[(item: TopoExportScene.LegendItem, x: Double)]] = [[]]
        var x = title
        for item in items {
            let w = markWidth(item.mark) + 5 + TopoTextFit.width(item.label, size: 11) + 14
            if x + w > width, !(rows.last?.isEmpty ?? true) {
                rows.append([])
                x = title
            }
            rows[rows.count - 1].append((item, x))
            x += w
        }
        return rows
    }

    static func markWidth(_ mark: TopoExportScene.LegendItem.Mark) -> Double {
        switch mark {
        case .node, .group: return 16
        case .line: return 22
        case .dot: return 8
        }
    }

    static func legend(_ rows: [[(item: TopoExportScene.LegendItem, x: Double)]], top: Double, left: Double) -> String {
        let e = TopoXML.escape, n = TopoXML.number
        var out = "<g id=\"legende\" font-size=\"11\" fill=\"\(TopoColor.hex(0x374151))\">\n"
        out += "<text x=\"\(n(left))\" y=\"\(n(top + 14))\" font-size=\"10\" font-weight=\"700\" fill=\"\(TopoColor.hex(TopoPalette.exportSecondary))\">LÉGENDE</text>\n"
        for (index, row) in rows.enumerated() {
            let y = top + Double(index) * legendRowHeight + 10
            for (item, x0) in row {
                let x = left + x0
                switch item.mark {
                case .node(let kind):
                    let colors = TopoPalette.node(kind: kind, type: nil)
                    out += "<rect x=\"\(n(x))\" y=\"\(n(y - 8))\" width=\"16\" height=\"16\" rx=\"4\" fill=\"\(colors.bg.hex)\"/>"
                    out += "<use href=\"#\(iconID(kind: kind, type: nil))\" xlink:href=\"#\(iconID(kind: kind, type: nil))\" x=\"\(n(x + 2))\" y=\"\(n(y - 6))\" width=\"12\" height=\"12\" color=\"\(colors.fg.hex)\"/>\n"
                case .group:
                    out += "<rect x=\"\(n(x + 2))\" y=\"\(n(y - 4))\" width=\"14\" height=\"11\" rx=\"3\" fill=\"#FFFFFF\" stroke=\"\(TopoColor.hex(TopoPalette.exportBorder))\"/>"
                    out += "<rect x=\"\(n(x))\" y=\"\(n(y - 6))\" width=\"14\" height=\"11\" rx=\"3\" fill=\"#FFFFFF\" stroke=\"\(TopoColor.hex(TopoPalette.exportBorder))\"/>\n"
                case .line(let style):
                    let dash = style.isDashed ? " stroke-dasharray=\"4 3\"" : ""
                    if style == .redundant {
                        out += "<path d=\"M\(n(x)) \(n(y + 3)) Q\(n(x + 11)) \(n(y - 4)) \(n(x + 22)) \(n(y + 3))\" fill=\"none\" stroke=\"\(TopoColor.hex(style.color))\" stroke-width=\"2\"\(dash)/>\n"
                    } else {
                        out += "<line x1=\"\(n(x))\" y1=\"\(n(y))\" x2=\"\(n(x + 22))\" y2=\"\(n(y))\" stroke=\"\(TopoColor.hex(style.color))\" stroke-width=\"\(style.isDashed ? 2 : 3)\" stroke-linecap=\"round\"\(dash)/>\n"
                    }
                case .dot(let color):
                    out += "<circle cx=\"\(n(x + 4))\" cy=\"\(n(y))\" r=\"3.5\" fill=\"\(TopoColor.hex(color))\"/>\n"
                }
                out += "<text x=\"\(n(x + markWidth(item.mark) + 5))\" y=\"\(n(y + 4))\">\(e(item.label))</text>\n"
            }
        }
        return out + "</g>\n"
    }

    // MARK: Liens

    static func pathData(_ segments: [TopoPathSegment]) -> String {
        let n = TopoXML.number
        return segments.map { segment -> String in
            switch segment {
            case .move(let p): return "M\(n(p.x)) \(n(p.y))"
            case .line(let p): return "L\(n(p.x)) \(n(p.y))"
            case .quad(let p, let c): return "Q\(n(c.x)) \(n(c.y)) \(n(p.x)) \(n(p.y))"
            case .cubic(let p, let c1, let c2): return "C\(n(c1.x)) \(n(c1.y)) \(n(c2.x)) \(n(c2.y)) \(n(p.x)) \(n(p.y))"
            }
        }.joined(separator: " ")
    }

    static func path(_ link: TopoExportScene.Link) -> String {
        let width = link.style == .redundant || link.style == .wifi ? 2 : (link.verified ? 2.5 : 2)
        var attributes = "stroke=\"\(TopoColor.hex(link.style.color))\" stroke-width=\"\(TopoXML.number(width))\""
        if link.style == .redundant { attributes += " stroke-dasharray=\"6 4\"" }
        else if link.style == .wifi { attributes += " stroke-dasharray=\"5 4\"" }
        if link.dimmed { attributes += " opacity=\"0.3\"" }
        return "<path class=\"lien \(link.style.rawValue)\" d=\"\(pathData(link.segments))\" \(attributes)/>\n"
    }

    static func portLabel(_ link: TopoExportScene.Link) -> String {
        guard let label = link.label, let point = link.labelPoint else { return "" }
        let e = TopoXML.escape, n = TopoXML.number
        let w = TopoTextFit.width(label, size: 10, mono: true) + 10
        let color: UInt32
        switch link.style {
        case .wifi: color = TopoPalette.wifi.light
        case .lldp, .redundant: color = TopoPalette.lldp.light
        default: color = TopoPalette.exportText
        }
        return "<g class=\"port\"\(link.dimmed ? " opacity=\"0.4\"" : "")>"
            + "<rect x=\"\(n(point.x - w / 2))\" y=\"\(n(point.y - 8))\" width=\"\(n(w))\" height=\"16\" rx=\"4\" fill=\"#FFFFFF\" stroke=\"\(TopoColor.hex(0xE3E4E8))\"/>"
            + "<text x=\"\(n(point.x))\" y=\"\(n(point.y + 3.5))\" fill=\"\(TopoColor.hex(color))\">\(e(label))</text></g>\n"
    }

    // MARK: Nœuds

    static func node(_ node: TopoExportScene.Node, scene: TopoExportScene) -> String {
        let e = TopoXML.escape, n = TopoXML.number
        let w = scene.nodeWidth, h = scene.nodeHeight
        let x = node.center.x - w / 2, y = node.center.y - h / 2
        let colors = TopoPalette.node(kind: node.kind, type: node.deviceType)
        var out = "<g class=\"noeud \(node.kind.rawValue)\" id=\"\(e(svgID(node.id)))\"\(node.dimmed ? " opacity=\"0.4\"" : "")>"
        out += "<title>\(e(node.title + " · " + node.subtitle))</title>"
        if node.kind == .groupe {
            out += "<rect x=\"\(n(x + 4))\" y=\"\(n(y + 4))\" width=\"\(n(w))\" height=\"\(n(h))\" rx=\"8\" fill=\"#FFFFFF\" stroke=\"\(TopoPalette.groupBack.hex)\"/>"
        }
        let fill = node.kind == .internet ? TopoPalette.internetFill.hex : TopoColor.hex(TopoPalette.exportPanel)
        var stroke = "stroke=\"\(TopoColor.hex(TopoPalette.exportBorder))\""
        if node.highlighted { stroke = "stroke=\"\(TopoColor.hex(TopoPalette.exportAccent))\" stroke-width=\"2\"" }
        else if node.kind == .internet || node.isInferred { stroke = "stroke=\"\(TopoPalette.inferredBorder.hex)\" stroke-dasharray=\"4 3\"" }
        out += "<rect x=\"\(n(x + 0.5))\" y=\"\(n(y + 0.5))\" width=\"\(n(w - 1))\" height=\"\(n(h - 1))\" rx=\"8\" fill=\"\(fill)\" \(stroke)/>"
        // Pastille d'icône.
        let pill = (x: x + 7, y: node.center.y - 13)
        out += "<rect x=\"\(n(pill.x))\" y=\"\(n(pill.y))\" width=\"26\" height=\"26\" rx=\"6\" fill=\"\(colors.bg.hex)\"/>"
        out += "<use href=\"#\(iconID(kind: node.kind, type: node.deviceType))\" xlink:href=\"#\(iconID(kind: node.kind, type: node.deviceType))\" x=\"\(n(pill.x + 6))\" y=\"\(n(pill.y + 6))\" width=\"14\" height=\"14\" color=\"\(colors.fg.hex)\"/>"
        // Nom et sous-titre.
        let textX = pill.x + 26 + 7
        let available = x + w - 12 - textX
        let title = TopoTextFit.title(node.title, maxWidth: available)
        // Trois lignes au plus dans le nœud, comme à l'écran : un nom sur une ligne laisse deux
        // lignes au sous-titre (« VLAN 30 · 2 en ligne · 1 conflit »).
        let subtitle = TopoTextFit.lines(node.subtitle, size: 10.5, maxWidth: available, maxLines: title.lines.count == 1 ? 2 : 1)
        let lineHeight = title.size + 2.5
        let blockHeight = Double(title.lines.count) * lineHeight + Double(subtitle.count) * 13
        var baseline = node.center.y - blockHeight / 2 + title.size
        for line in title.lines {
            out += "<text x=\"\(n(textX))\" y=\"\(n(baseline))\" font-size=\"\(n(title.size))\" font-weight=\"600\" fill=\"\(TopoColor.hex(TopoPalette.exportText))\">\(e(line))</text>"
            baseline += lineHeight
        }
        for line in subtitle {
            out += "<text x=\"\(n(textX))\" y=\"\(n(baseline + 0.5))\" font-size=\"10.5\" fill=\"\(TopoColor.hex(TopoPalette.exportSecondary))\">\(e(line))</text>"
            baseline += 13
        }
        if node.showsStatus {
            out += "<circle cx=\"\(n(x + w - 9.5))\" cy=\"\(n(y + 9.5))\" r=\"3.5\" fill=\"\(TopoColor.hex(TopoPalette.status(node.status)))\"/>"
        }
        return out + "</g>\n"
    }

    /// Identifiant d'élément SVG sûr (« sw:fsw-quai » → « n-sw-fsw-quai »).
    static func svgID(_ id: String) -> String {
        "n-" + String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
    }

    // MARK: Icônes

    static func iconID(kind: TopoNodeKind, type: DeviceType?) -> String {
        switch kind {
        case .internet: return "ic-internet"
        case .passerelle: return "ic-passerelle"
        case .switch: return "ic-switch"
        case .pointAcces: return "ic-ap"
        case .groupe, .appareil:
            switch type ?? .inconnu {
            case .poste: return "ic-poste"
            case .serveur: return "ic-serveur"
            case .imprimante: return "ic-imprimante"
            case .camera: return "ic-camera"
            case .telephone, .telephoneIP: return "ic-telephone"
            case .pointAcces: return "ic-ap"
            case .switch: return "ic-switch"
            case .routeur: return "ic-passerelle"
            default: return "ic-appareil"
            }
        }
    }

    /// Icônes simples (trait de 2 sur une grille de 24), dessinées en `currentColor`.
    static let icons: String = {
        func symbol(_ id: String, _ body: String) -> String {
            "<symbol id=\"\(id)\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\(body)</symbol>\n"
        }
        return "<defs>\n"
            + symbol("ic-internet", "<path d=\"M7 18h10a4 4 0 0 0 .6-7.95A6 6 0 0 0 6.2 9.2 4.4 4.4 0 0 0 7 18z\"/>")
            + symbol("ic-passerelle", "<path d=\"M12 3l7 3v5c0 4.6-3 8.3-7 10-4-1.7-7-5.4-7-10V6z\"/><path d=\"M12 3v18\"/>")
            + symbol("ic-switch", "<rect x=\"3\" y=\"6\" width=\"18\" height=\"8\" rx=\"2\"/><path d=\"M7 10h.01M10.5 10h.01M14 10h.01M17 10h.01M12 14v4M7 20h10\"/>")
            + symbol("ic-ap", "<path d=\"M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.6 16a5 5 0 0 1 6.8 0\"/><circle cx=\"12\" cy=\"19.5\" r=\"1\" fill=\"currentColor\"/>")
            + symbol("ic-poste", "<rect x=\"3\" y=\"4\" width=\"18\" height=\"12\" rx=\"2\"/><path d=\"M8 20h8M12 16v4\"/>")
            + symbol("ic-serveur", "<rect x=\"4\" y=\"3\" width=\"16\" height=\"7\" rx=\"1.5\"/><rect x=\"4\" y=\"14\" width=\"16\" height=\"7\" rx=\"1.5\"/><path d=\"M8 6.5h.01M8 17.5h.01\"/>")
            + symbol("ic-imprimante", "<path d=\"M6 9V3h12v6\"/><rect x=\"3\" y=\"9\" width=\"18\" height=\"8\" rx=\"2\"/><rect x=\"7\" y=\"14\" width=\"10\" height=\"7\"/>")
            + symbol("ic-camera", "<rect x=\"2\" y=\"7\" width=\"14\" height=\"10\" rx=\"2\"/><path d=\"M16 10.5l6-3.5v10l-6-3.5z\"/>")
            + symbol("ic-telephone", "<rect x=\"7\" y=\"2\" width=\"10\" height=\"20\" rx=\"2\"/><path d=\"M11 18h2\"/>")
            + symbol("ic-appareil", "<rect x=\"3\" y=\"3\" width=\"18\" height=\"18\" rx=\"4\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/>")
            + "</defs>\n"
    }()
}
