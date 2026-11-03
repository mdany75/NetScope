// make-icon.swift — dessine l'icône de « {{NOM AFFICHÉ}} ».
//
// Usage : swift Scripts/make-icon.swift <dossier de sortie>
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

/// Rectangle arrondi dont les coins du haut et du bas ont des rayons différents.
func roundedRect(_ rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    path.move(to: CGPoint(x: x0 + bottomRadius, y: y0))
    path.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y1), radius: bottomRadius)
    path.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x0, y: y1), radius: topRadius)
    path.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y0), radius: topRadius)
    path.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x1, y: y0), radius: bottomRadius)
    path.closeSubpath()
    return path
}

// MARK: - Géométrie (espace de dessin : 1024 × 1024, origine en bas à gauche)

struct Geometry {
    /// Vrai pour les petites tailles (16 et 32 px) : formes plus grosses, pas de détails fins.
    let small: Bool
    /// Vrai pour la taille de 16 px : flèche plus épaisse, pour rester lisible.
    let tiny: Bool

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tileRadius: CGFloat = 185.4

    var folderMinX: CGFloat { small ? 214 : 236 }
    var folderMaxX: CGFloat { small ? 810 : 788 }
    var folderMinY: CGFloat { small ? 268 : 288 }
    /// Haut du corps du dossier (sous l'onglet).
    var bodyMaxY: CGFloat { small ? 676 : 660 }
    /// Haut de l'onglet.
    var tabMaxY: CGFloat { small ? 752 : 724 }
    /// Haut du panneau avant.
    var frontMaxY: CGFloat { small ? 610 : 608 }
    var cornerRadius: CGFloat { small ? 56 : 48 }

    /// Dos du dossier, avec son onglet en haut à gauche.
    var folderBack: CGPath {
        let r = cornerRadius
        let tabEnd = folderMinX + (folderMaxX - folderMinX) * 0.40   // fin du plat de l'onglet
        let slope: CGFloat = small ? 70 : 64                         // largeur de la pente
        let path = CGMutablePath()
        path.move(to: CGPoint(x: folderMinX + r, y: folderMinY))
        path.addArc(tangent1End: CGPoint(x: folderMaxX, y: folderMinY),
                    tangent2End: CGPoint(x: folderMaxX, y: bodyMaxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: folderMaxX, y: bodyMaxY),
                    tangent2End: CGPoint(x: folderMinX, y: bodyMaxY), radius: r)
        path.addLine(to: CGPoint(x: tabEnd + slope, y: bodyMaxY))
        path.addCurve(to: CGPoint(x: tabEnd, y: tabMaxY),
                      control1: CGPoint(x: tabEnd + slope * 0.45, y: bodyMaxY),
                      control2: CGPoint(x: tabEnd + slope * 0.55, y: tabMaxY))
        path.addArc(tangent1End: CGPoint(x: folderMinX, y: tabMaxY),
                    tangent2End: CGPoint(x: folderMinX, y: folderMinY), radius: r)
        path.addArc(tangent1End: CGPoint(x: folderMinX, y: folderMinY),
                    tangent2End: CGPoint(x: folderMaxX, y: folderMinY), radius: r)
        path.closeSubpath()
        return path
    }

    /// Panneau avant du dossier.
    var folderFront: CGPath {
        roundedRect(CGRect(x: folderMinX, y: folderMinY,
                           width: folderMaxX - folderMinX, height: frontMaxY - folderMinY),
                    topRadius: small ? 40 : 34, bottomRadius: cornerRadius)
    }

    /// Flèche vers le bas, centrée sur le panneau avant.
    var arrow: CGPath {
        let cx: CGFloat = 512
        let centerY = (folderMinY + frontMaxY) / 2
        let height: CGFloat = tiny ? 176 : (small ? 196 : 172)   // de l'axe haut de la tige à la pointe
        let wing: CGFloat = tiny ? 96 : (small ? 92 : 82)        // demi-largeur de la tête
        let top = centerY + height / 2
        let tip = centerY - height / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: top))
        path.addLine(to: CGPoint(x: cx, y: tip))
        path.move(to: CGPoint(x: cx - wing, y: tip + wing))
        path.addLine(to: CGPoint(x: cx, y: tip))
        path.addLine(to: CGPoint(x: cx + wing, y: tip + wing))
        return path
    }

    var arrowWidth: CGFloat { tiny ? 100 : (small ? 72 : 54) }
}

// MARK: - Dessin

/// Dessine l'icône dans un contexte de `pixels` × `pixels`.
func drawIcon(in ctx: CGContext, pixels: Int) {
    let size = CGFloat(pixels)
    let small = pixels <= 32
    let g = Geometry(small: small, tiny: pixels <= 16)

    // Marge de la tuile, calée sur des pixels entiers pour des bords nets.
    var insetPx = (100 * size / 1024).rounded()
    if pixels == 16 { insetPx = 1 }
    let tilePx = size - 2 * insetPx
    let k = tilePx / g.tile.width            // pixels par unité de dessin

    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Passage à l'espace de dessin : la tuile (100…924) tombe sur la grille de pixels.
    ctx.saveGState()
    ctx.translateBy(x: insetPx, y: insetPx)
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -g.tile.minX, y: -g.tile.minY)

    let tilePath = continuousRoundedRect(g.tile, radius: g.tileRadius)

    // 1. Ombre portée de la tuile (les ombres s'expriment en pixels, pas en unités de dessin).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: rgb(0x001B4D, 0.38))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x1473E6))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Fond de la tuile : dégradé bleu, clair en haut, profond en bas.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0.0, rgb(0x5CBBFF)), (0.45, rgb(0x2189F7)), (1.0, rgb(0x0A55D1))]),
        start: CGPoint(x: 512, y: g.tile.maxY), end: CGPoint(x: 512, y: g.tile.minY), options: [])

    if !small {
        // Lueur douce en haut, pour donner du volume.
        ctx.drawRadialGradient(
            gradient([(0.0, rgb(0xFFFFFF, 0.22)), (1.0, rgb(0xFFFFFF, 0.0))]),
            startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
            endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
        // Liseré clair sur le bord supérieur, estompé vers le bas.
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.setLineWidth(8)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0.0, rgb(0xFFFFFF, 0.34)), (0.35, rgb(0xFFFFFF, 0.05)), (1.0, rgb(0x00205C, 0.16))]),
            start: CGPoint(x: 512, y: g.tile.maxY), end: CGPoint(x: 512, y: g.tile.minY), options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // 3. Dos du dossier (avec l'onglet), et son ombre sur la tuile.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    ctx.saveGState()
    if !small {
        ctx.setShadow(offset: CGSize(width: 0, height: -18 * k), blur: 44 * k, color: rgb(0x002A78, 0.42))
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState()
    ctx.addPath(g.folderBack)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0.0, rgb(0xD9ECFF)), (1.0, rgb(0x9CCBFF))]),
        start: CGPoint(x: 512, y: g.tabMaxY), end: CGPoint(x: 512, y: g.frontMaxY - 40), options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // 4. Panneau avant, avec une ombre légère sur le dos.
    ctx.saveGState()
    ctx.addPath(g.folderBack)
    ctx.clip()
    if !small {
        ctx.setShadow(offset: CGSize(width: 0, height: 8 * k), blur: 22 * k, color: rgb(0x003A94, 0.40))
    }
    ctx.addPath(g.folderFront)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(g.folderFront)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0.0, rgb(0xFFFFFF)), (1.0, rgb(0xDDEBFF))]),
        start: CGPoint(x: 512, y: g.frontMaxY), end: CGPoint(x: 512, y: g.folderMinY), options: [])
    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // 5. Flèche vers le bas, en dégradé bleu, sur le panneau avant.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(g.arrow)
    ctx.setLineWidth(g.arrowWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(0x1473E6))
    ctx.strokePath()
    ctx.setBlendMode(.sourceIn)
    ctx.drawLinearGradient(
        gradient([(0.0, rgb(0x3A9DFF)), (1.0, rgb(0x0B4FC4))]),
        start: CGPoint(x: 512, y: g.frontMaxY), end: CGPoint(x: 512, y: g.folderMinY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()

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
