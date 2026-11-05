import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

// Note 61 : export de la Carte du réseau (menu « Exporter » de la barre d'outils) en PNG et PDF
// (rendu SwiftUI de la carte entière, pas seulement la partie visible), en SVG et en draw.io
// (écrits à la main par NetScopeCore). Le site, le filtre VLAN, la recherche et les calques actifs
// s'appliquent ; rien d'autre que ce que montre la carte (ni MAC, ni notes, ni secrets). Les
// exports sont toujours en clair, sur fond blanc : ils vont chez le client ou à l'impression.

/// Ce qu'on exporte : la carte telle qu'elle est dessinée.
struct TopoExportContent {
    var graph: TopoGraph
    var layout: TopoGraph.Layout
    var showPortLabels: Bool
    /// Recherche active (nœuds trouvés et branche du résultat) ; les autres nœuds sont atténués.
    var highlight: TopoSearchHighlight?
    /// Nœuds qui portent le VLAN filtré ; les autres sont atténués.
    var carrying: Set<String>?
    /// « Carte du réseau — Siège ».
    var title: String
    /// « VLAN 40 · Caméras », « Recherche «  cam  » », « 5 novembre 2026 ».
    var details: [String]
    var showHeader = true
    var showLegend = true

    /// Nœud atténué, comme à l'écran sans nœud choisi : hors de la recherche, ou sans le VLAN filtré.
    func isDimmed(_ id: String) -> Bool {
        if let highlight { return !highlight.shows(id) }
        if let carrying { return !carrying.contains(id) }
        return false
    }

    var options: TopoExportOptions {
        let drawn = graph.nodes.map(\.id).filter { layout.positions[$0] != nil }
        return TopoExportOptions(title: showHeader ? title : "", details: showHeader ? details : [], showPortLabels: showPortLabels,
                                 dimmed: Set(drawn.filter(isDimmed)), highlighted: Set(highlight?.counts.keys.map { $0 } ?? []),
                                 showLegend: showLegend, nodeWidth: Double(TopoStyle.nodeWidth), nodeHeight: Double(TopoStyle.nodeHeight))
    }

    var scene: TopoExportScene { TopoExportScene.make(graph: graph, layout: layout, options: options) }

    /// Largeur du dessin dans l'image (au moins 640 points, la légende y tient).
    var drawingWidth: CGFloat { max(CGFloat(layout.width), 640) }
}

/// Légende de la carte (écran et exports).
struct TopoLegendItems: View {
    let hasLLDP: Bool
    let hasRedundant: Bool

    var body: some View {
        InvFlowLayout(spacing: 11) {
            Text("LÉGENDE").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            icon(.internet, "Internet")
            icon(.passerelle, "Passerelle")
            icon(.switch, "Switch")
            icon(.pointAcces, "Point d’accès")
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
            if hasLLDP {
                HStack(spacing: 5) { Capsule().fill(TopoStyle.lldp).frame(width: 22, height: 3); Text("LLDP / FortiLink") }
                    .help("Lien vu par les voisins LLDP relus par SNMP, ou par la FortiGate (FortiLink, ISL)")
            }
            if hasRedundant {
                HStack(spacing: 5) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 3))
                        path.addQuadCurve(to: CGPoint(x: 22, y: 3), control: CGPoint(x: 11, y: -3))
                    }
                    .stroke(TopoStyle.lldp, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: 22, height: 6)
                    Text("Lien redondant")
                }
            }
            HStack(spacing: 5) { StatusDot(tone: .critical, size: 7); Text("Conflit IP") }
            HStack(spacing: 5) { StatusDot(tone: .neutral, size: 7); Text("Hors ligne") }
        }
        .font(Theme.small)
        .foregroundStyle(Theme.neutralText)
    }

    private func icon(_ kind: TopoNodeKind, _ title: String) -> some View {
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

/// Image de la carte entière : titre, dessin (le même que l'écran), légende ; en clair.
struct TopoExportView: View {
    let content: TopoExportContent

    var body: some View {
        let layout = content.layout
        VStack(alignment: .leading, spacing: 12) {
            if content.showHeader {
                VStack(alignment: .leading, spacing: 3) {
                    Text(content.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                    if !content.details.isEmpty {
                        Text(content.details.joined(separator: " · "))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            TopoCanvas(graph: content.graph, layout: layout, selectedID: .constant(nil), showPortLabels: content.showPortLabels,
                       search: content.highlight, carrying: content.highlight == nil ? content.carrying : nil)
                .frame(width: CGFloat(layout.width), height: CGFloat(layout.height))
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelMuted))
                .frame(width: content.drawingWidth)
            if content.showLegend {
                TopoLegendItems(hasLLDP: !content.graph.infraLinks.isEmpty, hasRedundant: !content.graph.redundantLinks.isEmpty)
                    .frame(width: content.drawingWidth, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

/// Formats d'export de la carte.
enum TopoExportFormat: String, CaseIterable, Identifiable {
    case png, pdf, svg, drawio

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .png: return "Image PNG…"
        case .pdf: return "Document PDF…"
        case .svg: return "Dessin SVG…"
        case .drawio: return "Diagramme draw.io…"
        }
    }

    var help: String {
        switch self {
        case .png: return "Image de la carte entière, à double résolution"
        case .pdf: return "Carte entière en PDF vectoriel (texte sélectionnable)"
        case .svg: return "Dessin vectoriel modifiable (navigateur, Illustrator, Inkscape, Visio)"
        case .drawio: return "Diagramme modifiable dans draw.io (diagrams.net), nœuds et liens reliés"
        }
    }

    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .pdf: return .pdf
        case .svg: return .svg
        case .drawio: return UTType(filenameExtension: "drawio") ?? .xml
        }
    }
}

@MainActor
enum TopoExporter {
    /// Contenu du fichier au format demandé.
    static func data(_ content: TopoExportContent, format: TopoExportFormat) -> Data? {
        switch format {
        case .png: return png(content, scale: 2)
        case .pdf: return pdf(content)
        case .svg: return TopoSVG.data(content.scene)
        case .drawio: return TopoDrawio.data(content.scene)
        }
    }

    /// « carte-siege-vlan-40-2026-11-05.png »
    static func fileName(site: String, details: [String], date: Date = Date(), format: TopoExportFormat) -> String {
        let vlan = details.first { $0.hasPrefix("VLAN") }.map { "-" + ReportText.slug($0.components(separatedBy: " · ").first ?? $0) } ?? ""
        return "carte-\(ReportText.slug(site))\(vlan)-\(ReportText.isoDay(date)).\(format.fileExtension)"
    }

    /// Rendu en clair (couleurs dynamiques résolues dans l'apparence claire).
    private static func inLightAppearance<T>(_ body: () -> T) -> T {
        guard let light = NSAppearance(named: .aqua) else { return body() }
        var result: T?
        light.performAsCurrentDrawingAppearance { result = body() }
        return result ?? body()
    }

    private static func renderer(_ content: TopoExportContent) -> ImageRenderer<TopoExportView> {
        let renderer = ImageRenderer(content: TopoExportView(content: content))
        renderer.colorMode = .nonLinear
        return renderer
    }

    /// Image PNG de la carte entière ; `scale` : pixels par point (ramené pour rester sous 12 000 px).
    static func png(_ content: TopoExportContent, scale: CGFloat) -> Data? { rendered(content, scale: scale)?.data }

    /// PNG et échelle réellement employée.
    private static func rendered(_ content: TopoExportContent, scale: CGFloat) -> (data: Data, scale: CGFloat)? {
        inLightAppearance {
            let renderer = renderer(content)
            let side = max(content.drawingWidth + 32, CGFloat(content.layout.height) + 200)
            renderer.scale = max(0.5, min(scale, 12_000 / side))
            guard let image = renderer.cgImage else { return nil }
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = NSSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
            return rep.representation(using: .png, properties: [:]).map { ($0, renderer.scale) }
        }
    }

    /// PDF vectoriel d'une page à la taille de la carte entière.
    static func pdf(_ content: TopoExportContent) -> Data? {
        inLightAppearance {
            let renderer = renderer(content)
            let data = NSMutableData()
            var made = false
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                let info: [CFString: Any] = [kCGPDFContextTitle: content.title.isEmpty ? "Carte du réseau" : content.title,
                                             kCGPDFContextCreator: "NetScope \(AppInfo.version)"]
                guard let consumer = CGDataConsumer(data: data as CFMutableData),
                      let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return }
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
                made = true
            }
            return made ? data as Data : nil
        }
    }

    /// Note 61 : image de la carte pour un rapport (sans titre : la section en a un), en PNG net à la
    /// largeur d'une page lettre.
    static func reportImage(_ content: TopoExportContent, siteName: String) -> ReportImage? {
        guard let result = rendered(content, scale: min(2, max(1.25, 1600 / (content.drawingWidth + 32)))),
              let size = ReportDocx.pngSize(result.data) else { return nil }
        let scale = Double(result.scale)
        return ReportImage(png: result.data, width: Double(size.width) / scale, height: Double(size.height) / scale,
                           caption: "Carte du réseau — \(siteName)", alt: "Carte du réseau du site \(siteName)")
    }

    /// Panneau d'enregistrement, puis écriture. Renvoie le fichier écrit, ou le message d'échec.
    static func save(_ content: TopoExportContent, format: TopoExportFormat, site: String) -> Result<URL, TopoExportError>? {
        let panel = NSSavePanel()
        panel.title = "Exporter la carte du réseau"
        panel.prompt = "Exporter"
        panel.nameFieldStringValue = fileName(site: site, details: content.details, format: format)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = data(content, format: format) else { return .failure(TopoExportError("rendu impossible")) }
        do {
            try data.write(to: url, options: .atomic)
            return .success(url)
        } catch {
            return .failure(TopoExportError(error.localizedDescription))
        }
    }
}

/// Résultat d'un export, montré sous la barre de la carte.
struct TopoExportNotice: Equatable {
    var text: String
    var url: URL?
    var failed: Bool
}

struct TopoExportError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
