// make-icon.swift — dessine l'icône de « NetScope ».
//
// Usage : swift scripts/make-icon.swift <dossier de sortie>
//
// Écrit dans le dossier de sortie les dix PNG attendus par `iconutil -c icns` :
//   icon_16x16.png, icon_16x16@2x.png, icon_32x32.png, icon_32x32@2x.png,
//   icon_128x128.png, icon_128x128@2x.png, icon_256x256.png, icon_256x256@2x.png,
//   icon_512x512.png, icon_512x512@2x.png (1024 px).
//
// Le dessin est vectoriel (CoreGraphics) et refait à chaque taille, en pixels exacts,
// sans dépendre de la résolution de l'écran. La grille est celle des icônes macOS :
// canevas de 1024 px, tuile arrondie de 824 px, marge de 100 px.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Outils

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: sRGB, components: [r, g, b, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB,
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("make-icon : " + message + "\n").data(using: .utf8)!)
    exit(1)
}

/// Rectangle à coins « continus » (la forme des tuiles d'icônes Apple), plus doux
/// qu'un simple arc de cercle.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.528665)
    let path = CGMutablePath()
    let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)

    // Chaque coin : point de départ sur le premier côté, trois courbes, arrivée sur le second.
    // `c` est le sommet du coin, `u` le vecteur unitaire vers le côté d'arrivée,
    // `v` le vecteur unitaire vers le côté de départ.
    func corner(_ c: CGPoint, u: CGVector, v: CGVector) {
        func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            // a : distance le long du côté de départ, b : le long du côté d'arrivée.
            CGPoint(x: c.x + v.dx * a * r + u.dx * b * r,
                    y: c.y + v.dy * a * r + u.dy * b * r)
        }
        path.addLine(to: p(1.528665, 0))
        path.addCurve(to: p(0.63149379, 0.07491139),
                      control1: p(1.08849296, 0), control2: p(0.86840694, 0))
        path.addCurve(to: p(0.07491139, 0.63149379),
                      control1: p(0.37282383, 0.16905956), control2: p(0.16905956, 0.37282383))
        path.addCurve(to: p(0, 1.52866498),
                      control1: p(0, 0.86840694), control2: p(0, 1.08849296))
    }

    path.move(to: CGPoint(x: x0 + 1.528665 * r, y: y1))
    // Haut-droite
    corner(CGPoint(x: x1, y: y1), u: CGVector(dx: 0, dy: -1), v: CGVector(dx: -1, dy: 0))
    // Bas-droite
    corner(CGPoint(x: x1, y: y0), u: CGVector(dx: -1, dy: 0), v: CGVector(dx: 0, dy: 1))
    // Bas-gauche
    corner(CGPoint(x: x0, y: y0), u: CGVector(dx: 0, dy: 1), v: CGVector(dx: 1, dy: 0))
    // Haut-gauche
    corner(CGPoint(x: x0, y: y1), u: CGVector(dx: 1, dy: 0), v: CGVector(dx: 0, dy: -1))
    path.closeSubpath()
    return path
}

// MARK: - Dessin (espace de dessin : 1024 × 1024, origine en bas à gauche)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185.4

/// Dessine l'icône dans un contexte de `pixels` × `pixels` : tuile bleu nuit, ondes de radar
/// concentriques en bleu accent, faisceau de balayage et point lumineux (un appareil détecté).
func drawIcon(in ctx: CGContext, pixels: Int) {
    let size = CGFloat(pixels)
    let small = pixels <= 32

    // Marge de la tuile, calée sur des pixels entiers pour des bords nets.
    var insetPx = (100 * size / 1024).rounded()
    if pixels == 16 { insetPx = 1 }
    let tilePx = size - 2 * insetPx
    let k = tilePx / tile.width

    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    ctx.saveGState()
    ctx.translateBy(x: insetPx, y: insetPx)
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -tile.minX, y: -tile.minY)

    let tilePath = continuousRoundedRect(tile, radius: tileRadius)

    // 1. Ombre portée de la tuile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x0F172A))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Fond bleu nuit, légèrement plus clair en haut.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0.0, rgb(0x1E293B)), (1.0, rgb(0x0B1120))]),
        start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])

    let center = CGPoint(x: 512, y: 512)

    // 3. Ondes concentriques.
    let radii: [CGFloat] = small ? [150, 290] : [110, 210, 310]
    let lineWidth: CGFloat = small ? 56 : 26
    for (index, r) in radii.enumerated() {
        let alpha = 1.0 - CGFloat(index) * (small ? 0.35 : 0.25)
        ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.setStrokeColor(rgb(0x2563EB, alpha))
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
    }

    // 4. Faisceau de balayage : secteur en dégradé, du centre vers le haut à droite.
    if !small {
        ctx.saveGState()
        let sweep = CGMutablePath()
        sweep.move(to: center)
        sweep.addArc(center: center, radius: 330, startAngle: .pi / 4, endAngle: .pi / 4 + .pi / 3.2, clockwise: false)
        sweep.closeSubpath()
        ctx.addPath(sweep)
        ctx.clip()
        ctx.drawRadialGradient(
            gradient([(0.0, rgb(0x60A5FA, 0.55)), (1.0, rgb(0x2563EB, 0.0))]),
            startCenter: center, startRadius: 0, endCenter: center, endRadius: 340, options: [])
        ctx.restoreGState()

        // Aiguille du radar.
        ctx.move(to: center)
        ctx.addLine(to: CGPoint(x: center.x + 330 * cos(.pi / 4), y: center.y + 330 * sin(.pi / 4)))
        ctx.setStrokeColor(rgb(0x93C5FD, 0.9))
        ctx.setLineWidth(14)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    // 5. Centre du radar.
    let hub: CGFloat = small ? 60 : 34
    ctx.addEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))
    ctx.setFillColor(rgb(0x60A5FA))
    ctx.fillPath()

    // 6. Point lumineux : un appareil détecté sur la deuxième onde, avec son halo.
    let blip = small ? CGPoint(x: 512 + 205, y: 512 + 205) : CGPoint(x: 512 + 148, y: 512 + 148)
    if !small {
        ctx.drawRadialGradient(
            gradient([(0.0, rgb(0xBFDBFE, 0.9)), (0.35, rgb(0x60A5FA, 0.45)), (1.0, rgb(0x2563EB, 0.0))]),
            startCenter: blip, startRadius: 0, endCenter: blip, endRadius: 120, options: [])
    }
    let dot: CGFloat = small ? 64 : 40
    ctx.addEllipse(in: CGRect(x: blip.x - dot, y: blip.y - dot, width: 2 * dot, height: 2 * dot))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()

    // Liseré clair sur le bord supérieur.
    if !small {
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.setLineWidth(8)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0.0, rgb(0xFFFFFF, 0.22)), (0.4, rgb(0xFFFFFF, 0.03)), (1.0, rgb(0x000000, 0.2))]),
            start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
        ctx.restoreGState()
    }

    ctx.restoreGState()   // découpe de la tuile
    ctx.restoreGState()   // espace de dessin
}

func renderIcon(pixels: Int) -> CGImage {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                              bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("impossible de créer le contexte graphique pour \(pixels) px")
    }
    drawIcon(in: ctx, pixels: pixels)
    guard let image = ctx.makeImage() else {
        fail("impossible de produire l'image de \(pixels) px")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL, dpi: Double) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("impossible d'écrire \(url.path)")
    }
    let properties: [CFString: Any] = [
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi,
    ]
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        fail("échec de l'écriture de \(url.path)")
    }
}

// MARK: - Programme

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("usage : swift make-icon.swift <dossier de sortie>")
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("impossible de créer \(outputDirectory.path) : \(error.localizedDescription)")
}

// (taille en points, échelle)
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

var cache: [Int: CGImage] = [:]
for (points, scale) in variants {
    let pixels = points * scale
    let image: CGImage
    if let cached = cache[pixels] {
        image = cached
    } else {
        image = renderIcon(pixels: pixels)
        cache[pixels] = image
    }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    writePNG(image, to: outputDirectory.appendingPathComponent(name), dpi: scale == 1 ? 72 : 144)
}

print("Icône : \(variants.count) images écrites dans \(outputDirectory.path)")
