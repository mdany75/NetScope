import AppKit
import NetScopeCore
import SwiftUI

extension Theme {
    /// Note 94 : couleurs de la carte de chaleur, de « excellent » à « zone morte » (couleurs système).
    static let heatNSLevels: [NSColor] = [.systemGreen, .systemYellow, .systemOrange, .systemRed]
    static let heatLevels: [Color] = heatNSLevels.map { Color(nsColor: $0) }
    /// Bornes et canaux (carte par catégorie).
    static let heatNSCategories: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemPink, .systemIndigo, .systemBrown,
                                              .systemMint, .systemCyan]
    static let heatCategories: [Color] = heatNSCategories.map { Color(nsColor: $0) }

    static func heatColor(_ metric: WifiHeatMetric, value: Double) -> Color { heatLevels[metric.level(value)] }

    static func heatCategoryColor(_ label: String, in labels: [String]) -> Color {
        heatCategories[(labels.firstIndex(of: label) ?? 0) % heatCategories.count]
    }
}

/// Images des plans décodées une fois (clé : étage et taille des données).
@MainActor
enum WifiFloorImageCache {
    private static var images: [String: NSImage] = [:]

    static func image(_ floor: WifiFloor) -> NSImage? {
        let key = floor.id.uuidString + "-\(floor.image.count)"
        if let image = images[key] { return image }
        guard let image = NSImage(data: floor.image) else { return nil }
        if images.count > 12 { images.removeAll() }
        images[key] = image
        return image
    }
}

/// Note 94 : plan d'un étage avec la carte de chaleur, les mesures, les bornes placées, les zones
/// mortes, les chevauchements de canaux, la borne suggérée et l'échelle. Même dessin à l'écran,
/// dans le PDF exporté et dans le rapport.
struct WifiFloorPlanDrawing: View {
    let floor: WifiFloor
    let metric: WifiHeatMetric
    let analysis: WifiFloorAnalysis
    var scaleFirst: WifiPlanPoint? = nil
    var scalePending: (a: WifiPlanPoint, b: WifiPlanPoint)? = nil
    var columns = 96

    var body: some View {
        let grid = WifiHeatmap.grid(floor, metric: metric, columns: columns)
        let labels = WifiHeatmap.categories(grid)
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.white
                if let image = WifiFloorImageCache.image(floor) {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                }
                // Une case par pixel, agrandie avec lissage : dégradé continu entre les cases.
                if let heat = Self.heatImage(grid, metric: metric, labels: labels) {
                    Image(decorative: heat, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height * grid.cellHeight * Double(grid.rows), alignment: .top)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .opacity(0.55)
                        .clipped()
                }
                Canvas { context, size in
                    draw(in: &context, size: size, labels: labels)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .aspectRatio(floor.imageWidth / floor.imageHeight, contentMode: .fit)
    }

    /// Image de la grille (une case par pixel, transparente hors de portée des mesures).
    static func heatImage(_ grid: WifiHeatGrid, metric: WifiHeatMetric, labels: [String]) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: grid.columns * grid.rows * 4)
        let levels = Theme.heatNSLevels.map { $0.usingColorSpace(.sRGB) }
        let categories = Theme.heatNSCategories.map { $0.usingColorSpace(.sRGB) }
        for i in 0..<(grid.columns * grid.rows) {
            let color: NSColor??
            if metric.isCategorical {
                color = grid.categories[i].map { categories[(labels.firstIndex(of: $0) ?? 0) % categories.count] }
            } else {
                color = grid.values[i].map { levels[metric.level($0)] }
            }
            guard let resolved = color ?? nil else { continue }
            bytes[i * 4] = UInt8(max(0, min(255, resolved.redComponent * 255)))
            bytes[i * 4 + 1] = UInt8(max(0, min(255, resolved.greenComponent * 255)))
            bytes[i * 4 + 2] = UInt8(max(0, min(255, resolved.blueComponent * 255)))
            bytes[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: grid.columns, height: grid.rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: grid.columns * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func at(_ p: WifiPlanPoint, _ size: CGSize) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }

    /// Étiquette sur fond blanc arrondi, centrée sur `point`.
    private func label(_ text: String, at point: CGPoint, color: Color, in context: inout GraphicsContext, size: CGSize, bold: Bool = true) {
        let resolved = context.resolve(Text(text).font(.system(size: max(9, min(12, size.width / 80)), weight: bold ? .semibold : .regular))
            .foregroundColor(color))
        let measured = resolved.measure(in: size)
        let box = CGRect(x: point.x - measured.width / 2 - 5, y: point.y - measured.height / 2 - 2,
                         width: measured.width + 10, height: measured.height + 4)
        context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.white.opacity(0.92)))
        context.stroke(Path(roundedRect: box, cornerRadius: 4), with: .color(color.opacity(0.5)), lineWidth: 0.8)
        context.draw(resolved, at: point)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, labels: [String]) {
        let ink = Color(white: 0.15)
        // Échelle enregistrée.
        if let scale = floor.scale {
            let a = at(scale.a, size), b = at(scale.b, size)
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            context.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for end in [a, b] { context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(ink)) }
            label("\(WifiRoomSurvey.number(scale.metres))\u{00A0}m", at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 14),
                  color: ink, in: &context, size: size, bold: false)
        }
        // Zones mortes (les trois plus grandes).
        for zone in analysis.deadZones.prefix(3) where metric == .signal || metric == .snr || metric == .debit {
            label("Zone morte", at: at(zone.center, size), color: Theme.critical, in: &context, size: size)
        }
        // Mesures.
        for measure in floor.measures {
            let p = at(measure.point, size)
            let color: Color
            if metric.isCategorical {
                color = metric.category(measure).map { Theme.heatCategoryColor($0, in: labels) } ?? .gray
            } else {
                color = metric.value(measure).map { Theme.heatColor(metric, value: $0) } ?? .gray
            }
            let r: CGFloat = 5
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(color))
            context.stroke(dot, with: .color(.white), lineWidth: 1.5)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - r - 1, y: p.y - r - 1, width: 2 * r + 2, height: 2 * r + 2)),
                           with: .color(ink.opacity(0.35)), lineWidth: 0.5)
        }
        // Chevauchements de canaux.
        for overlap in analysis.overlaps {
            let p = at(overlap.point, size)
            var triangle = Path()
            triangle.move(to: CGPoint(x: p.x + 9, y: p.y - 15))
            triangle.addLine(to: CGPoint(x: p.x + 17, y: p.y - 2))
            triangle.addLine(to: CGPoint(x: p.x + 1, y: p.y - 2))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(Color(nsColor: .systemOrange)))
            context.stroke(triangle, with: .color(.white), lineWidth: 1)
        }
        // Borne suggérée : losange pointillé et rayon couvert.
        if let suggestion = analysis.suggestion {
            let p = at(suggestion, size)
            let radius = WifiHeatmap.suggestionRadiusMetres / floor.effectiveMetresPerPixel / floor.imageWidth * size.width
            context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)),
                           with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            var diamond = Path()
            diamond.move(to: CGPoint(x: p.x, y: p.y - 10))
            diamond.addLine(to: CGPoint(x: p.x + 10, y: p.y))
            diamond.addLine(to: CGPoint(x: p.x, y: p.y + 10))
            diamond.addLine(to: CGPoint(x: p.x - 10, y: p.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(.white))
            context.stroke(diamond, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            label("Borne suggérée", at: CGPoint(x: p.x, y: p.y + 22), color: Theme.accentStrong, in: &context, size: size)
        }
        // Bornes placées.
        for ap in floor.aps {
            let p = at(ap.point, size)
            let box = CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)
            context.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Theme.accent))
            context.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(.white), lineWidth: 1.5)
            let icon = context.resolve(Image(systemName: "wifi"))
            var iconContext = context
            iconContext.addFilter(.colorMultiply(.white))
            iconContext.draw(icon, in: box.insetBy(dx: 5, dy: 6))
            label(ap.name, at: CGPoint(x: p.x, y: p.y + 24), color: ink, in: &context, size: size)
        }
        // Échelle en cours de saisie.
        let pending = scalePending.map { [$0.a, $0.b] } ?? scaleFirst.map { [$0] } ?? []
        if !pending.isEmpty {
            let points = pending.map { at($0, size) }
            if points.count == 2 {
                var line = Path()
                line.move(to: points[0])
                line.addLine(to: points[1])
                context.stroke(line, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            for p in points {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(Theme.accent))
            }
        }
    }
}

/// Légende de la mesure affichée.
struct WifiFloorLegend: View {
    let metric: WifiHeatMetric
    let floor: WifiFloor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if metric.isCategorical {
                let grid = WifiHeatmap.grid(floor, metric: metric, columns: 32)
                let labels = WifiHeatmap.categories(grid)
                if labels.isEmpty { Text("Aucune mesure.").font(Theme.small).foregroundStyle(Theme.textSecondary) }
                ForEach(labels, id: \.self) { item in
                    row(Theme.heatCategoryColor(item, in: labels), item)
                }
            } else {
                ForEach(Array(metric.levelLabels.enumerated()), id: \.offset) { index, text in
                    row(Theme.heatLevels[index], text)
                }
            }
        }
    }

    private func row(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.75)).frame(width: 18, height: 10)
            Text(text).font(Theme.small).foregroundStyle(Theme.text)
        }
    }
}

/// Export de l'étage : PDF (une page) et image du rapport, toujours en clair.
@MainActor
enum WifiFloorExport {
    struct Page: View {
        let floor: WifiFloor
        let metric: WifiHeatMetric
        let siteName: String
        let width: CGFloat

        var body: some View {
            let analysis = WifiHeatmap.analysis(floor)
            VStack(alignment: .leading, spacing: 12) {
                Text("Relevé Wi-Fi — \(siteName) — \(floor.name)").font(.system(size: 18, weight: .bold))
                Text("\(metric.label) · " + WifiHeatmap.summary(analysis)).font(.system(size: 12)).foregroundStyle(Color(white: 0.3))
                WifiFloorPlanDrawing(floor: floor, metric: metric, analysis: analysis)
                    .frame(width: width, height: width * floor.imageHeight / floor.imageWidth)
                    .overlay(Rectangle().stroke(Color(white: 0.8)))
                WifiFloorLegend(metric: metric, floor: floor)
            }
            .padding(24)
            .frame(width: width + 48, alignment: .leading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        }
    }

    private static func inLight<T>(_ body: () -> T) -> T {
        guard let light = NSAppearance(named: .aqua) else { return body() }
        var result: T?
        light.performAsCurrentDrawingAppearance { result = body() }
        return result ?? body()
    }

    static func pdf(_ floor: WifiFloor, metric: WifiHeatMetric, siteName: String) -> Data? {
        inLight {
            let renderer = ImageRenderer(content: Page(floor: floor, metric: metric, siteName: siteName, width: 900))
            let data = NSMutableData()
            var made = false
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: data), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
                pdf.closePDF()
                made = true
            }
            return made ? data as Data : nil
        }
    }

    /// Image du plan (carte du signal) pour la section du rapport.
    static func reportImage(_ floor: WifiFloor) -> ReportImage? {
        inLight {
            let width: CGFloat = 1000
            let height = width * floor.imageHeight / floor.imageWidth
            let view = WifiFloorPlanDrawing(floor: floor, metric: .signal, analysis: WifiHeatmap.analysis(floor))
                .frame(width: width, height: height)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1.5
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
            return ReportImage(png: png, width: Double(width), height: Double(height),
                               caption: "Signal — \(floor.name) (vert\u{00A0}: ≥ −60\u{00A0}dBm, jaune\u{00A0}: −67, orange\u{00A0}: −75, rouge\u{00A0}: zone morte)",
                               alt: "Carte de chaleur du signal Wi-Fi, \(floor.name)")
        }
    }
}
