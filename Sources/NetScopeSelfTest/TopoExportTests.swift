import Foundation
import NetScopeCore

// 0.28.0, note 61 : export de la Carte du réseau (scène, SVG et draw.io écrits à la main, tracés
// communs à l'écran) et section « Carte du réseau » des rapports (texte, image, liens entre
// équipements ; HTML, JSON, CSV et DOCX). Données fixes, aucun réseau.

private extension Optional {
    func mapUnwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}

/// Nombre d'occurrences d'un motif.
private func occurrences(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

/// Éléments d'un document XML (vérifie aussi qu'il est bien formé).
private final class ElementCounter: NSObject, XMLParserDelegate {
    var counts: [String: Int] = [:]
    var attributes: [[String: String]] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        counts[name, default: 0] += 1
        if name == "mxCell" { self.attributes.append(attributes) }
    }

    static func parse(_ text: String) -> ElementCounter? {
        let counter = ElementCounter()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = counter
        return parser.parse() ? counter : nil
    }
}

/// 1 × 1 pixel, PNG valide.
private let mapPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

func registerTopoExportTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)

    func device(_ ip: String, _ host: String, name: String? = nil, _ type: DeviceType, sw: String? = nil, port: String? = nil,
                vlan: Int? = nil, online: Bool = true) -> Device {
        Device(ip: IPv4Address(ip)!, mac: nil, hostname: host, customName: name, isOnline: online,
               switchName: sw, switchPort: port, vlan: vlan, firstSeen: now, lastSeen: now, deviceType: type)
    }

    func neighbor(_ index: Int, _ name: String, _ remote: String, _ caps: SNMPLLDPCapabilities = [.bridge]) -> SNMPLLDPNeighbor {
        SNMPLLDPNeighbor(localPortNum: index, ifIndex: index, sysName: name, portID: remote, capabilities: caps)
    }

    func snapshot(_ host: String, _ name: String, _ ports: [(Int, String)], _ neighbors: [SNMPLLDPNeighbor]) -> SNMPSwitchSnapshot {
        SNMPSwitchSnapshot(host: IPv4Address(host)!, system: SNMPSystemInfo(name: name, descr: ""),
                           interfaces: ports.map { SNMPInterface(index: $0.0, name: $0.1, operStatus: .up, speedMbps: 10_000) },
                           fdb: [], neighbors: neighbors, pvid: [:], polledAt: now)
    }

    // Siège : FortiGate, cœur, étage relié deux fois (lien redondant), borne, postes, imprimante au
    // nom piégé (XML et HTML), caméra hors ligne.
    func graph() -> TopoGraph {
        let devices = [
            device("10.182.122.1", "FortiGate-60F", .routeur),
            device("10.182.122.2", "SW-CORE-01", .switch),
            device("10.182.122.3", "SW-ETG2-01", .switch),
            device("10.182.122.102", "FortiAP-231F", .pointAcces, sw: "SW-CORE-01", port: "Gi1/0/12"),
            device("10.182.122.117", "WKS346", .poste, sw: "SW-CORE-01", port: "Gi1/0/22", vlan: 1),
            device("10.182.122.118", "WKS347", .poste, sw: "SW-CORE-01", port: "Gi1/0/23", vlan: 1),
            device("10.182.122.111", "brother", name: "R&D <Lab> \"A\" 'B'\u{0001}", .imprimante, sw: "SW-ETG2-01", port: "1/14", vlan: 30),
            device("10.182.122.150", "CAM-01", .camera, sw: "SW-ETG2-01", port: "1/20", vlan: 40, online: false),
        ]
        let core = snapshot("10.182.122.2", "SW-CORE-01", [(1, "Gi1/0/1"), (47, "Gi1/0/47"), (48, "Gi1/0/48")],
                            [neighbor(1, "FortiGate-60F", "internal1", [.router, .bridge]), neighbor(47, "SW-ETG2-01", "1/25"),
                             neighbor(48, "SW-ETG2-01", "1/26")])
        let etage = snapshot("10.182.122.3", "SW-ETG2-01", [(25, "1/25"), (26, "1/26")],
                             [neighbor(25, "SW-CORE-01", "Gi1/0/47"), neighbor(26, "SW-CORE-01", "Gi1/0/48")])
        return TopoGraph.build(devices: devices, gateway: IPv4Address("10.182.122.1"), switches: [core, etage])
    }

    func layout(_ graph: TopoGraph, hideEnd: Bool = false) -> TopoGraph.Layout {
        graph.layout(nodeWidth: 178, nodeHeight: 54, levelGap: 50, stackGap: 20, maxStack: 4, margin: 22,
                     hidden: { hideEnd && ($0.kind == .groupe || $0.kind == .appareil) })
    }

    suite.add("Carte (note 61) : tracés communs à l'écran et aux exports") {
        let parent = TopoGraph.Point(x: 200, y: 100), child = TopoGraph.Point(x: 400, y: 230)
        let square = TopoGeometry.treePath(parent: parent, child: child, free: false, stacked: false, nodeWidth: 178, nodeHeight: 54)
        try expectEqual(square.count, 4, "équerre : départ et trois segments")
        try expectEqual(square.first, .move(TopoGraph.Point(x: 200, y: 127)), "départ au bas du parent")
        try expectEqual(square.last?.end, TopoGraph.Point(x: 400, y: 203), "arrivée au haut de l'enfant")
        try expectEqual(square[1].end.y, 151, "palier 24 points sous le parent")
        let stacked = TopoGeometry.treePath(parent: parent, child: child, free: false, stacked: true, nodeWidth: 178, nodeHeight: 54)
        try expectEqual(stacked.last?.end, TopoGraph.Point(x: 311, y: 230), "feuille empilée : flanc gauche")
        let free = TopoGeometry.treePath(parent: parent, child: child, free: true, stacked: false, nodeWidth: 178, nodeHeight: 54)
        guard case .cubic(let end, _, _)? = free.last else { throw TestFailure(message: "courbe attendue", file: #fileID, line: #line) }
        try expectEqual(end, TopoGraph.Point(x: 400, y: 203), "courbe jusqu'au haut de l'enfant")
        let label = TopoGeometry.treeLabel(parent: parent, child: child, free: false, stacked: false, nodeWidth: 178, nodeHeight: 54)
        try expectEqual(label, TopoGraph.Point(x: 400, y: 177), "étiquette au milieu de la descente")
        // Deux switchs sur la même rangée : arc sous eux.
        let arc = TopoGeometry.redundantCurve(TopoGraph.Point(x: 100, y: 300), TopoGraph.Point(x: 400, y: 300), nodeWidth: 178, nodeHeight: 54)
        try expect(arc.control.y > 327 && arc.start.y == 327 && arc.end.y == 327, "arc sous les deux nœuds")
        try expect(TopoGeometry.redundantMidpoint(arc).y > 327, "milieu sous les nœuds")
    }

    suite.add("Carte (note 61) : scène exportée, filtre et recherche, liens entre équipements") {
        let graph = graph()
        let full = layout(graph)
        let scene = TopoExportScene.make(graph: graph, layout: full, options: TopoExportOptions(title: "Carte du réseau — Siège"))
        try expectEqual(scene.nodes.count, full.positions.count, "un nœud par position")
        try expectEqual(scene.links.count, graph.links.count + graph.redundantLinks.count, "liens de l'arbre et redondants")
        try expectEqual(scene.links.filter { $0.style == .redundant }.count, 1, "un lien redondant")
        try expect(scene.links.contains { $0.style == .lldp && $0.label == "Gi1/0/47 ↔ 1/25" }, "lien LLDP avec ses ports")
        try expect(scene.hasVerified && scene.hasRedundant, "légende LLDP et redondant")
        try expect(scene.legend.contains { $0.label == "Lien redondant" }, "légende du lien redondant")
        try expect(!scene.nodes.contains { $0.dimmed }, "rien d'atténué sans filtre")

        // Calque « Appareils finaux » décoché : seulement l'infrastructure.
        let infra = TopoExportScene.make(graph: graph, layout: layout(graph, hideEnd: true))
        try expect(!infra.nodes.contains { $0.kind == .groupe || $0.kind == .appareil }, "sans appareils finaux")
        try expect(infra.nodes.count < scene.nodes.count, "moins de nœuds")
        // Ports masqués : aucune étiquette.
        let bare = TopoExportScene.make(graph: graph, layout: full, options: TopoExportOptions(showPortLabels: false))
        try expect(bare.links.allSatisfy { $0.label == nil }, "sans étiquettes de ports")
        // Nœuds atténués (filtre VLAN, recherche) et trouvés.
        let switchID = try graph.nodes.first { $0.title == "SW-ETG2-01" }.mapUnwrap("étage").id
        let dimmed = TopoExportScene.make(graph: graph, layout: full,
                                          options: TopoExportOptions(dimmed: [switchID], highlighted: ["passerelle"]))
        try expect(dimmed.node(switchID)?.dimmed == true, "nœud atténué")
        try expect(dimmed.links.filter { $0.from == switchID || $0.to == switchID }.allSatisfy(\.dimmed), "ses liens aussi")
        try expect(dimmed.node("passerelle")?.highlighted == true, "nœud trouvé")

        // Liens entre équipements du rapport : LLDP (arbre puis redondant), puis déduits du scan.
        let rows = TopoExportScene.infraLinkRows(graph)
        try expectEqual(rows.filter(\.redundant).count, 1, "un lien redondant listé")
        try expect(rows.contains { $0.from == "SW-CORE-01" && $0.to == "SW-ETG2-01" && $0.fromPort == "Gi1/0/47" && $0.toPort == "1/25"
            && $0.source == "LLDP (SNMP)" && $0.speed == "10 Gb/s" }, "lien cœur ↔ étage")
        try expect(rows.contains { $0.to == "FortiAP-231F" && $0.source == "Scan (tables MAC)" && $0.toPort == "Gi1/0/12" }, "borne déduite du scan")
        try expect(!rows.contains { $0.to.contains("Postes") || $0.to.contains("WKS") }, "pas d'appareils finaux")
        try expectEqual(rows.last?.redundant, false, "le redondant avant les liens déduits")
    }

    suite.add("Carte (note 61) : SVG écrit à la main, XML bien formé, texte échappé") {
        let graph = graph()
        let scene = TopoExportScene.make(graph: graph, layout: layout(graph),
                                         options: TopoExportOptions(title: "Carte du réseau — Siège & annexe", details: ["VLAN 30 · Imprimantes"]))
        let svg = TopoSVG.make(scene)
        let parsed = try ElementCounter.parse(svg).mapUnwrap("SVG bien formé")
        try expectEqual(parsed.counts["svg"], 1, "un élément svg")
        try expectEqual(occurrences("<g class=\"noeud ", in: svg), scene.nodes.count, "un groupe par nœud")
        try expectEqual(occurrences("<path class=\"lien ", in: svg), scene.links.count, "un tracé par lien")
        try expectEqual(occurrences("<path class=\"lien redundant\"", in: svg), 1, "lien redondant")
        try expect(svg.contains("stroke-dasharray=\"6 4\""), "redondant en tirets")
        try expect(svg.contains("R&amp;D &lt;Lab&gt; &quot;A&quot; &apos;B&apos;"), "nom échappé")
        try expect(!svg.contains("<Lab>") && !svg.contains("\u{0001}"), "aucun texte brut ni caractère de contrôle")
        try expect(svg.contains("Carte du réseau — Siège &amp; annexe"), "titre échappé")
        try expect(svg.contains("VLAN 30 · Imprimantes"), "filtre dans l'en-tête")
        try expect(svg.contains("Gi1/0/47 ↔ 1/25"), "étiquette de ports")
        try expect(svg.contains("id=\"legende\"") && svg.contains("LLDP / FortiLink"), "légende")
        try expect(svg.contains("fill=\"#9CA3AF\""), "point gris hors ligne")
        try expect(!svg.contains(":xx:") && !svg.lowercased().contains("community"), "rien de confidentiel")
        // Sans titre ni légende : ni en-tête ni légende.
        let bare = TopoSVG.make(TopoExportScene.make(graph: graph, layout: layout(graph), options: TopoExportOptions(showLegend: false)))
        try expect(!bare.contains("id=\"entete\"") && !bare.contains("id=\"legende\""), "dessin seul")
        try expect(ElementCounter.parse(bare) != nil, "dessin seul bien formé")
        // Libellés trop longs : réduits ou coupés en deux lignes, jamais au-delà du nœud.
        let long = TopoTextFit.title("Contrôleur de domaine principal du siège social", maxWidth: 126)
        try expectEqual(long.lines.count, 2, "deux lignes")
        try expect(long.lines.allSatisfy { TopoTextFit.width($0, size: long.size, bold: true) <= 126 }, "chaque ligne tient")
        try expectEqual(TopoTextFit.title("SW-CORE-01", maxWidth: 126).lines, ["SW-CORE-01"], "nom court entier")
        try expect(TopoTextFit.truncate(String(repeating: "x", count: 80), size: 10.5, maxWidth: 100).hasSuffix("…"), "sous-titre coupé")
        let wrapped = TopoTextFit.lines("VLAN 30 · 2 en ligne · 1 conflit", size: 10.5, maxWidth: 126, maxLines: 2)
        try expectEqual(wrapped.count, 2, "sous-titre sur deux lignes")
        try expectEqual(wrapped.joined(separator: " "), "VLAN 30 · 2 en ligne · 1 conflit", "sous-titre entier")
        try expectEqual(TopoTextFit.lines("10.182.122.2", size: 10.5, maxWidth: 126, maxLines: 2), ["10.182.122.2"], "sous-titre court")
        try expectEqual(TopoXML.number(12.0), "12", "nombre entier")
        try expectEqual(TopoXML.number(12.25), "12.3", "une décimale, point")
    }

    suite.add("Carte (note 61) : draw.io (mxGraphModel) écrit à la main") {
        let graph = graph()
        let scene = TopoExportScene.make(graph: graph, layout: layout(graph), options: TopoExportOptions(title: "Carte du réseau — Siège"))
        let xml = TopoDrawio.make(scene, modified: now)
        let parsed = try ElementCounter.parse(xml).mapUnwrap("draw.io bien formé")
        try expectEqual(parsed.counts["mxfile"], 1, "mxfile")
        try expectEqual(parsed.counts["mxGraphModel"], 1, "mxGraphModel")
        let cells = parsed.attributes
        let nodes = cells.filter { $0["vertex"] == "1" && $0["parent"] == "1" && $0["id"]?.hasPrefix("n-") == true }
        let edges = cells.filter { $0["edge"] == "1" }
        try expectEqual(nodes.count, scene.nodes.count, "un rectangle par nœud")
        try expectEqual(edges.count, scene.links.count, "un lien par câble")
        let ids = Set(nodes.compactMap { $0["id"] })
        try expect(edges.allSatisfy { ids.contains($0["source"] ?? "") && ids.contains($0["target"] ?? "") }, "liens reliés à des nœuds")
        try expectEqual(Set(cells.compactMap { $0["id"] }).count, cells.count, "identifiants uniques")
        // Étiquette HTML : le nom piégé est échappé deux fois (HTML, puis XML) et relu en HTML échappé.
        try expect(nodes.contains { ($0["value"] ?? "").contains("R&amp;D &lt;Lab&gt; &quot;A&quot;") }, "HTML échappé dans la valeur")
        try expect(xml.contains("R&amp;amp;D &amp;lt;Lab&amp;gt;"), "double échappement dans le fichier")
        // Styles par type : switch bleu, point d'accès violet, caméra ambre, lien redondant en tirets.
        try expect(nodes.contains { ($0["style"] ?? "").contains("fillColor=#DBEAFE;strokeColor=#1D4ED8") }, "switch")
        try expect(nodes.contains { ($0["style"] ?? "").contains("fillColor=#EDE9FE") }, "point d'accès")
        try expect(nodes.contains { ($0["style"] ?? "").contains("fillColor=#FEF3C7") }, "caméra")
        try expect(edges.contains { ($0["style"] ?? "").contains("dashPattern=6 4") && ($0["style"] ?? "").contains("curved=1") }, "redondant")
        try expect(edges.contains { ($0["value"] ?? "") == "Gi1/0/47 ↔ 1/25" }, "étiquette de ports")
        try expect(edges.contains { ($0["style"] ?? "").contains("edgeStyle=orthogonalEdgeStyle") }, "liens en équerre")
        try expect(cells.contains { $0["id"] == "titre" }, "titre")
        try expect(parsed.counts["mxPoint"] ?? 0 > 0, "coudes de la carte gardés")
        try expect(xml.contains("name=\"Carte du réseau — Siège\""), "nom du diagramme")
    }

    suite.add("Rapports (note 61) : section Carte du réseau dans le PDF, le HTML, le JSON, le CSV et le DOCX") {
        let graph = graph()
        let image = ReportImage(png: mapPNG, width: 1200, height: 700, caption: "Carte du réseau — Siège",
                                alt: "Carte du réseau du site Siège")
        let map = ReportMap.make(graph: graph, siteName: "Siège", image: image)
        try expectEqual(map.switches, 2, "deux switchs")
        try expectEqual(map.accessPoints, 1, "une borne")
        try expectEqual(map.gateways, 1, "passerelle")
        try expectEqual(map.endDevices, 4, "quatre appareils finaux")
        var input = ReportInput(devices: [], now: now)
        input.map = map
        var config = ReportConfig(client: "Clinique", site: "Siège", technician: "Dany Ménard", date: "2026-11-05")
        try expect(!config.includes(.carte), "section facultative, pas cochée par défaut")
        config.sections = [.resume, .carte, .plan]
        let document = ReportBuilder.build(config: config, input: input)
        let section = try document.section(.carte).mapUnwrap("section")
        try expectEqual(section.heading, "2. Carte du réseau", "après le résumé")
        let images = section.blocks.compactMap { block -> ReportImage? in if case .image(let i) = block { return i }; return nil }
        try expectEqual(images.count, 1, "image de la carte")
        let tables = section.tables
        try expectEqual(tables.count, 1, "liste des liens")
        try expectEqual(tables[0].rows.count, TopoExportScene.infraLinkRows(graph).count, "un lien par ligne")
        try expect(tables[0].rows.contains { $0.cells[4].text == "ISL · redondant" }, "lien redondant signalé")
        guard case .paragraph(let text)? = section.blocks.first else { throw TestFailure(message: "paragraphe", file: #fileID, line: #line) }
        try expect(text.contains("2\u{00A0}switchs") && text.contains("1 point d’accès") && text.contains("LLDP"), "synthèse")

        // Pagination : l'image tient dans la largeur et sur une page avec son titre.
        let metrics = ReportPageMetrics()
        let size = metrics.imageSize(image)
        try expect(size.width <= metrics.contentWidth && size.height <= metrics.contentHeight - metrics.headingHeight, "image réduite")
        try expect(abs(size.width / size.height - 1200.0 / 700.0) < 0.01, "proportions gardées")
        let small = ReportImage(png: mapPNG, width: 300, height: 200, alt: "petite")
        try expectEqual(metrics.imageSize(small).width, 300, "jamais agrandie")
        let pages = ReportPaginator.paginate(document, metrics: metrics)
        try expect(pages.allSatisfy { $0.used <= metrics.contentHeight + 0.5 }, "pages sans débordement")
        try expect(pages.contains { $0.items.contains { if case .block(.image) = $0 { return true } else { return false } } }, "image paginée")

        let html = ReportExport.html(document)
        try expect(html.contains("<img src=\"data:image/png;base64,") && html.contains("<figcaption>Carte du réseau — Siège</figcaption>"), "HTML : image intégrée")
        let json = String(decoding: try ReportExport.json(document), as: UTF8.self)
        try expect(json.contains("\"images\"") && json.contains("\"largeur\" : 1200") && !json.contains("iVBOR"), "JSON : image décrite, sans pixels")
        let csv = ReportExport.csv(document)
        try expect(csv.contains("Équipement;Port;Voisin;Port;Type;Vitesse;Source"), "CSV : liste des liens")

        let docx = ReportDocx.make(document, date: now)
        let entries = try BackupZip.entries(of: docx)
        let paths = Set(entries.map(\.path))
        try expect(paths.contains("word/media/image-1.png"), "DOCX : image jointe")
        for entry in entries where entry.path.hasSuffix(".xml") || entry.path.hasSuffix(".rels") {
            try expect(ElementCounter.parse(String(decoding: entry.data, as: UTF8.self)) != nil, "XML bien formé : \(entry.path)")
        }
        func part(_ path: String) throws -> String {
            String(decoding: try entries.first { $0.path == path }.mapUnwrap(path).data, as: UTF8.self)
        }
        let relations = try part("word/_rels/document.xml.rels")
        try expect(relations.contains("Id=\"rIdImg1\"") && relations.contains("Target=\"media/image-1.png\""), "relation de l'image")
        let types = try part("[Content_Types].xml")
        try expect(types.contains("Extension=\"png\""), "type PNG déclaré")
        let body = try part("word/document.xml")
        try expect(body.contains("r:embed=\"rIdImg1\"") && body.contains("Carte du réseau du site Siège"), "image et texte de remplacement")
        try expect(!body.contains("r:embed=\"rId4\""), "pas de logo")

        // Sans carte (aucun scan) : une note, pas d'image ; sans image : la légende en mots.
        guard case .note(let empty)? = ReportBuilder.mapBlocks(nil).first else { throw TestFailure(message: "note", file: #fileID, line: #line) }
        try expect(empty.contains("lancer un scan"), "carte absente expliquée")
        let noImage = ReportBuilder.mapBlocks(ReportMap.make(graph: graph, siteName: "Siège", image: nil))
        try expect(noImage.contains { if case .note(let t) = $0 { return t.hasPrefix("Légende") } else { return false } }, "légende en mots")
        // Décodage d'un ancien réglage : la nouvelle section se relit.
        let decoded = try JSONDecoder().decode(ReportConfig.self, from: Data("{\"sections\":[\"carte\",\"resume\"]}".utf8))
        try expect(decoded.includes(.carte), "section relue")
    }
}
