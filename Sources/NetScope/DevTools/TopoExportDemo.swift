import AppKit
import Foundation
import NetScopeCore
import PDFKit

/// Outil de développement (note 61) : écrit les exports de la carte de démonstration à côté des
/// captures (`--snapshot <dossier> --demo`) : carte entière en PNG, PDF, SVG et draw.io, et SVG
/// filtré sur le VLAN 40 (caméras). Chaque fichier est relu : PNG et PDF lisibles, XML bien formé,
/// autant de nœuds et de liens que la carte. Aucun réseau, aucune fenêtre.
@MainActor
enum TopoExportCheck {
    static func write(into directory: URL, state: AppState) -> Bool {
        let key = SiteModel.shared.activeKey
        let siteName = SiteModel.shared.activeName
        let all = TopoSiteMap.mapDevices(key: key, state: state)
        guard !all.isEmpty else {
            print("Erreur\u{00A0}: export de la carte\u{00A0}: aucun appareil de démonstration")
            return false
        }
        var problems: [String] = []
        let whole = content(all, key: key, state: state, siteName: siteName, filter: .all)
        let vlan = content(TopoVLAN.filter(all, .vlan(40), gateway: TopoSiteMap.gateway(all, key: key, state: state)), key: key,
                           state: state, siteName: siteName, filter: .vlan(40))
        let files: [(name: String, content: TopoExportContent, format: TopoExportFormat)] = [
            ("carte-demo.png", whole, .png), ("carte-demo.pdf", whole, .pdf), ("carte-demo.svg", whole, .svg),
            ("carte-demo.drawio", whole, .drawio), ("carte-demo-vlan40.svg", vlan, .svg),
        ]
        for file in files {
            guard let data = TopoExporter.data(file.content, format: file.format) else {
                problems.append("\(file.name)\u{00A0}: rendu impossible")
                continue
            }
            problems += verify(data, format: file.format, scene: file.content.scene).map { "\(file.name)\u{00A0}: \($0)" }
            do {
                try data.write(to: directory.appendingPathComponent(file.name), options: .atomic)
            } catch {
                problems.append("\(file.name)\u{00A0}: \(error.localizedDescription)")
            }
        }
        for problem in problems { print("Erreur\u{00A0}: export de la carte\u{00A0}: \(problem)") }
        guard problems.isEmpty else { return false }
        let scene = whole.scene
        print("Export de la carte\u{00A0}: \(directory.path)/carte-demo.{png,pdf,svg,drawio} (\(scene.nodes.count) nœuds, \(scene.links.count) liens, vérifié)")
        return true
    }

    private static func content(_ devices: [Device], key: String, state: AppState, siteName: String,
                                filter: TopoVLANFilter) -> TopoExportContent {
        let graph = TopoSiteMap.graph(devices, key: key, state: state)
        let layout = TopoSiteMap.layout(graph, key: key, box: CGSize(width: 1400, height: 800))
        var details: [String] = []
        if case .vlan(let number) = filter { details.append("VLAN \(number)") }
        details.append("État du " + (ReportText.longDate(RapportDemo.config.date) ?? RapportDemo.config.date))
        return TopoExportContent(graph: graph, layout: layout, showPortLabels: true, highlight: nil,
                                 carrying: filter.isAll ? nil : graph.nodesCarrying(filter, devices: devices),
                                 title: "Carte du réseau — \(siteName)", details: details)
    }

    static func verify(_ data: Data, format: TopoExportFormat, scene: TopoExportScene) -> [String] {
        switch format {
        case .png:
            guard let size = ReportDocx.pngSize(data) else { return ["PNG illisible"] }
            return Double(size.width) >= scene.width * 1.9 ? [] : ["image trop petite (\(size.width) px)"]
        case .pdf:
            guard let pdf = PDFDocument(data: data), pdf.pageCount == 1 else { return ["PDF illisible"] }
            let text = pdf.page(at: 0)?.string ?? ""
            return scene.nodes.prefix(3).filter { !text.contains($0.title) }.map { "nœud «\u{00A0}\($0.title)\u{00A0}» absent du texte" }
        case .svg, .drawio:
            guard XMLParser(data: data).parse() else { return ["XML mal formé"] }
            let text = String(decoding: data, as: UTF8.self)
            let nodes = format == .svg ? text.components(separatedBy: "<g class=\"noeud ").count - 1
                : text.components(separatedBy: "<mxCell id=\"n-").count - 1 - scene.nodes.filter(\.showsStatus).count
            let links = format == .svg ? text.components(separatedBy: "<path class=\"lien ").count - 1
                : text.components(separatedBy: "edge=\"1\"").count - 1
            var problems: [String] = []
            if nodes != scene.nodes.count { problems.append("\(nodes) nœuds au lieu de \(scene.nodes.count)") }
            if links != scene.links.count { problems.append("\(links) liens au lieu de \(scene.links.count)") }
            return problems
        }
    }
}
