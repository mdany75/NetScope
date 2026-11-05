import Foundation

/// Rectangle du tampon d'image, en pixels.
public struct RFBRect: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = RFBRect(x: 0, y: 0, width: 0, height: 0)

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { isEmpty ? 0 : width * height }

    /// Plus petit rectangle qui contient les deux.
    public func union(_ other: RFBRect) -> RFBRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let minX = min(x, other.x), minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width), maxY = max(y + height, other.y + other.height)
        return RFBRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Partie commune (vide si aucune).
    public func intersection(_ other: RFBRect) -> RFBRect {
        let minX = max(x, other.x), minY = max(y, other.y)
        let maxX = min(x + width, other.x + other.width), maxY = min(y + height, other.y + other.height)
        guard maxX > minX, maxY > minY else { return .zero }
        return RFBRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Image du bureau distant : un pixel 0xAARRGGBB (alpha à 0xFF) par entier, ligne par ligne.
/// En mémoire (petit-boutiste), chaque pixel s'écrit B, G, R, A : prêt pour une CGImage
/// « 32 bits little + alpha first ».
public struct RFBFramebuffer: Equatable, Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var pixels: [UInt32]

    /// Fond d'un tampon neuf (gris anthracite, comme un écran qui attend sa première image).
    public static let blank: UInt32 = 0xFF1E_1F22

    public init(width: Int, height: Int, fill: UInt32 = RFBFramebuffer.blank) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [UInt32](repeating: fill, count: self.width * self.height)
    }

    /// Image fournie telle quelle (démonstration, tests) ; `pixels` doit compter width × height.
    public init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(pixels.count == width * height, "taille du tampon incohérente")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var bounds: RFBRect { RFBRect(x: 0, y: 0, width: width, height: height) }

    @inline(__always)
    public func pixel(x: Int, y: Int) -> UInt32 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[y * width + x]
    }

    /// Change la taille (DesktopSize) en gardant la partie commune de l'image.
    public mutating func resize(width newWidth: Int, height newHeight: Int) {
        let w = max(0, newWidth), h = max(0, newHeight)
        guard w != width || h != height else { return }
        var next = [UInt32](repeating: Self.blank, count: w * h)
        let copyW = min(w, width), copyH = min(h, height)
        if copyW > 0 {
            for row in 0..<copyH {
                let src = row * width, dst = row * w
                next.replaceSubrange(dst..<(dst + copyW), with: pixels[src..<(src + copyW)])
            }
        }
        width = w
        height = h
        pixels = next
    }

    /// Remplit un rectangle (rogné au tampon).
    public mutating func fill(_ rect: RFBRect, color: UInt32) {
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return }
        pixels.withUnsafeMutableBufferPointer { buffer in
            for row in r.y..<(r.y + r.height) {
                let start = row * width + r.x
                for i in start..<(start + r.width) { buffer[i] = color }
            }
        }
    }

    /// Copie `values` (rect.width × rect.height pixels, ligne par ligne) dans le rectangle.
    public mutating func put(_ rect: RFBRect, values: [UInt32]) {
        guard values.count >= rect.area else { return }
        let clipped = rect.intersection(bounds)
        guard !clipped.isEmpty else { return }
        let w = width
        pixels.withUnsafeMutableBufferPointer { buffer in
            values.withUnsafeBufferPointer { source in
                for row in clipped.y..<(clipped.y + clipped.height) {
                    let srcStart = (row - rect.y) * rect.width + (clipped.x - rect.x)
                    let dstStart = row * w + clipped.x
                    for i in 0..<clipped.width { buffer[dstStart + i] = source[srcStart + i] }
                }
            }
        }
    }

    /// CopyRect : copie une zone du tampon vers `destination` (les zones peuvent se chevaucher).
    public mutating func copy(from sourceX: Int, _ sourceY: Int, to destination: RFBRect) {
        let source = RFBRect(x: sourceX, y: sourceY, width: destination.width, height: destination.height)
        guard source.intersection(bounds) == source, destination.intersection(bounds) == destination,
              !destination.isEmpty else { return }
        let w = width
        pixels.withUnsafeMutableBufferPointer { buffer in
            // Lignes parcourues dans le sens qui ne lit jamais une ligne déjà écrite.
            let rows: [Int] = destination.y > sourceY ? Array((0..<destination.height).reversed()) : Array(0..<destination.height)
            for row in rows {
                let src = (sourceY + row) * w + sourceX
                let dst = (destination.y + row) * w + destination.x
                guard let base = buffer.baseAddress else { return }
                // memmove gère le chevauchement sur une même ligne.
                memmove(base + dst, base + src, destination.width * MemoryLayout<UInt32>.stride)
            }
        }
    }
}

/// Curseur envoyé par le serveur (pseudo-encodage Cursor) : pixels 0xAARRGGBB, alpha 0 hors du masque.
public struct RFBCursor: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var hotspotX: Int
    public var hotspotY: Int
    public var pixels: [UInt32]

    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixels: [UInt32]) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }

    /// Curseur masqué par le serveur (largeur ou hauteur nulle).
    public var isHidden: Bool { width == 0 || height == 0 }
}
