import Foundation

/// Décodage des rectangles d'une mise à jour (RFC 6143 § 7.7) : Raw, CopyRect, RRE, Hextile, ZRLE,
/// et les pseudo-encodages DesktopSize, Cursor et LastRect. Écrit dans le tampon d'image.
final class RFBDecoder {
    var format: RFBPixelFormat
    private let inflater = RFBInflater()

    init(format: RFBPixelFormat) {
        self.format = format
    }

    /// Effet d'un rectangle sur la session.
    enum Outcome: Equatable {
        case pixels
        case resized
        case cursor(RFBCursor)
        case lastRect
    }

    func decode(encoding: Int32, rect: RFBRect, reader: RFBReader, into framebuffer: inout RFBFramebuffer) async throws -> Outcome {
        switch encoding {
        case RFBEncoding.desktopSize:
            guard rect.width > 0, rect.height > 0, rect.width <= 16_384, rect.height <= 16_384 else {
                throw RFBError.protocolViolation("taille d’écran \(rect.width) × \(rect.height)")
            }
            framebuffer.resize(width: rect.width, height: rect.height)
            return .resized
        case RFBEncoding.lastRect:
            return .lastRect
        case RFBEncoding.cursor:
            return .cursor(try await cursor(rect, reader: reader))
        default:
            break
        }
        // Bornes par arithmétique : un rectangle vide (largeur ou hauteur 0, permis par la RFC) placé
        // ailleurs qu'en (0, 0) est accepté et ne dessine rien.
        guard rect.x >= 0, rect.y >= 0, rect.width >= 0, rect.height >= 0,
              rect.x + rect.width <= framebuffer.width, rect.y + rect.height <= framebuffer.height else {
            throw RFBError.protocolViolation("rectangle \(rect.x),\(rect.y) \(rect.width)×\(rect.height) hors de l’écran")
        }
        switch encoding {
        case RFBEncoding.raw: try await raw(rect, reader: reader, into: &framebuffer)
        case RFBEncoding.copyRect:
            let sourceX = Int(try await reader.u16()), sourceY = Int(try await reader.u16())
            framebuffer.copy(from: sourceX, sourceY, to: rect)
        case RFBEncoding.rre: try await rre(rect, reader: reader, into: &framebuffer)
        case RFBEncoding.hextile: try await hextile(rect, reader: reader, into: &framebuffer)
        case RFBEncoding.zrle:
            // Données compressées bornées par la taille maximale décompressée du rectangle (zlib ne
            // grossit un bloc que de quelques octets), et jamais plus de 64 Mo.
            let bound = Self.zrleMaxSize(rect, cpixel: format.compressedPixelSize)
            let data = try await reader.string(limit: min(64 << 20, bound + bound / 100 + 4_096))
            try zrle(rect, compressed: data, into: &framebuffer)
        default:
            throw RFBError.unexpectedEncoding(encoding)
        }
        return .pixels
    }

    // MARK: Pixels

    private func pixels(_ bytes: [UInt8], count: Int) -> [UInt32] {
        let size = format.bytesPerPixel
        var values = [UInt32](repeating: 0, count: count)
        let format = self.format
        bytes.withUnsafeBufferPointer { source in
            values.withUnsafeMutableBufferPointer { target in
                for i in 0..<count { target[i] = format.readPixel(source, at: i * size) }
            }
        }
        return values
    }

    private func pixel(_ reader: RFBReader) async throws -> UInt32 {
        let bytes = try await reader.bytes(format.bytesPerPixel)
        return bytes.withUnsafeBufferPointer { format.readPixel($0, at: 0) }
    }

    // MARK: Raw

    private func raw(_ rect: RFBRect, reader: RFBReader, into framebuffer: inout RFBFramebuffer) async throws {
        guard rect.area > 0 else { return }
        let bytes = try await reader.bytes(rect.area * format.bytesPerPixel)
        framebuffer.put(rect, values: pixels(bytes, count: rect.area))
    }

    // MARK: RRE

    private func rre(_ rect: RFBRect, reader: RFBReader, into framebuffer: inout RFBFramebuffer) async throws {
        let count = Int(try await reader.u32())
        guard count <= rect.area else { throw RFBError.protocolViolation("RRE : \(count) sous-rectangles") }
        framebuffer.fill(rect, color: try await pixel(reader))
        let size = format.bytesPerPixel + 8
        guard count > 0 else { return }
        let bytes = try await reader.bytes(count * size)
        let format = self.format
        bytes.withUnsafeBufferPointer { buffer in
            for index in 0..<count {
                let base = index * size
                let color = format.readPixel(buffer, at: base)
                let p = base + format.bytesPerPixel
                func u16(_ offset: Int) -> Int { Int(buffer[p + offset]) << 8 | Int(buffer[p + offset + 1]) }
                let sub = RFBRect(x: rect.x + u16(0), y: rect.y + u16(2), width: u16(4), height: u16(6))
                framebuffer.fill(sub.intersection(rect), color: color)
            }
        }
    }

    // MARK: Hextile

    private enum HextileFlag {
        static let raw: UInt8 = 1
        static let backgroundSpecified: UInt8 = 2
        static let foregroundSpecified: UInt8 = 4
        static let anySubrects: UInt8 = 8
        static let subrectsColoured: UInt8 = 16
    }

    private func hextile(_ rect: RFBRect, reader: RFBReader, into framebuffer: inout RFBFramebuffer) async throws {
        var background: UInt32 = 0xFF00_0000
        var foreground: UInt32 = 0xFFFF_FFFF
        let size = format.bytesPerPixel
        var tileY = rect.y
        while tileY < rect.y + rect.height {
            let tileHeight = min(16, rect.y + rect.height - tileY)
            var tileX = rect.x
            while tileX < rect.x + rect.width {
                let tileWidth = min(16, rect.x + rect.width - tileX)
                let tile = RFBRect(x: tileX, y: tileY, width: tileWidth, height: tileHeight)
                let flags = try await reader.u8()
                if flags & HextileFlag.raw != 0 {
                    let bytes = try await reader.bytes(tile.area * size)
                    framebuffer.put(tile, values: pixels(bytes, count: tile.area))
                } else {
                    if flags & HextileFlag.backgroundSpecified != 0 { background = try await pixel(reader) }
                    framebuffer.fill(tile, color: background)
                    if flags & HextileFlag.foregroundSpecified != 0 { foreground = try await pixel(reader) }
                    if flags & HextileFlag.anySubrects != 0 {
                        let count = Int(try await reader.u8())
                        let coloured = flags & HextileFlag.subrectsColoured != 0
                        let entry = (coloured ? size : 0) + 2
                        let bytes = try await reader.bytes(count * entry)
                        let format = self.format
                        let fg = foreground
                        bytes.withUnsafeBufferPointer { buffer in
                            for index in 0..<count {
                                var p = index * entry
                                var color = fg
                                if coloured {
                                    color = format.readPixel(buffer, at: p)
                                    p += size
                                }
                                let xy = buffer[p], wh = buffer[p + 1]
                                let sub = RFBRect(x: tileX + Int(xy >> 4), y: tileY + Int(xy & 0x0F),
                                                  width: Int(wh >> 4) + 1, height: Int(wh & 0x0F) + 1)
                                framebuffer.fill(sub.intersection(tile), color: color)
                            }
                        }
                    }
                }
                tileX += 16
            }
            tileY += 16
        }
    }

    // MARK: ZRLE

    /// Décode un rectangle ZRLE : données zlib (suite du flux de la session), tuiles de 64 × 64.
    /// Taille décompressée maximale d'un rectangle ZRLE : par tuile 64 × 64, un octet de
    /// sous-encodage et une palette de 127 couleurs au plus, puis par pixel au pire une couleur et
    /// un octet de longueur de plage (RLE simple de plages d'un pixel).
    static func zrleMaxSize(_ rect: RFBRect, cpixel: Int) -> Int {
        let tiles = ((rect.width + 63) / 64) * ((rect.height + 63) / 64)
        return rect.area * (cpixel + 1) + tiles * (1 + 127 * cpixel) + 1_024
    }

    func zrle(_ rect: RFBRect, compressed: [UInt8], into framebuffer: inout RFBFramebuffer) throws {
        // Bombe zlib : la décompression s'arrête au-delà de ce qu'un rectangle légitime produit.
        let data = try inflater.inflate(compressed, maxOutput: Self.zrleMaxSize(rect, cpixel: format.compressedPixelSize))
        var cursor = RFBByteCursor(data)
        let format = self.format
        let layout = format.compressedLayout
        let cpixel = format.compressedPixelSize
        try data.withUnsafeBufferPointer { buffer in
            func readCPixel() throws -> UInt32 {
                try cursor.need(cpixel)
                defer { cursor.position += cpixel }
                return format.readCompressedPixel(buffer, at: cursor.position, layout: layout)
            }
            func runLength() throws -> Int {
                var length = 1
                while true {
                    let byte = try cursor.u8()
                    length += Int(byte)
                    if byte != 255 { break }
                    guard length <= 64 * 64 + 255 else { throw RFBError.protocolViolation("ZRLE : plage trop longue") }
                }
                return length
            }
            var tileY = rect.y
            while tileY < rect.y + rect.height {
                let tileHeight = min(64, rect.y + rect.height - tileY)
                var tileX = rect.x
                while tileX < rect.x + rect.width {
                    let tileWidth = min(64, rect.x + rect.width - tileX)
                    let tile = RFBRect(x: tileX, y: tileY, width: tileWidth, height: tileHeight)
                    let area = tile.area
                    let subencoding = try cursor.u8()
                    switch subencoding {
                    case 0:
                        var values = [UInt32](repeating: 0, count: area)
                        for i in 0..<area { values[i] = try readCPixel() }
                        framebuffer.put(tile, values: values)
                    case 1:
                        framebuffer.fill(tile, color: try readCPixel())
                    case 2...16:
                        let palette = try (0..<Int(subencoding)).map { _ in try readCPixel() }
                        let bits = subencoding == 2 ? 1 : (subencoding <= 4 ? 2 : 4)
                        let mask = UInt8((1 << bits) - 1)
                        var values = [UInt32](repeating: 0, count: area)
                        for row in 0..<tileHeight {
                            var byte: UInt8 = 0
                            var available = 0
                            for column in 0..<tileWidth {
                                if available == 0 {
                                    byte = try cursor.u8()
                                    available = 8
                                }
                                available -= bits
                                let index = Int((byte >> UInt8(available)) & mask)
                                guard index < palette.count else { throw RFBError.protocolViolation("ZRLE : index de palette \(index)") }
                                values[row * tileWidth + column] = palette[index]
                            }
                        }
                        framebuffer.put(tile, values: values)
                    case 128:
                        var values = [UInt32](repeating: 0, count: area)
                        var filled = 0
                        while filled < area {
                            let color = try readCPixel()
                            let length = try runLength()
                            guard filled + length <= area else { throw RFBError.protocolViolation("ZRLE : plage hors de la tuile") }
                            for i in filled..<(filled + length) { values[i] = color }
                            filled += length
                        }
                        framebuffer.put(tile, values: values)
                    case 130...255:
                        let palette = try (0..<Int(subencoding - 128)).map { _ in try readCPixel() }
                        var values = [UInt32](repeating: 0, count: area)
                        var filled = 0
                        while filled < area {
                            let byte = try cursor.u8()
                            let index = Int(byte & 0x7F)
                            guard index < palette.count else { throw RFBError.protocolViolation("ZRLE : index de palette \(index)") }
                            let length = byte & 0x80 != 0 ? try runLength() : 1
                            guard filled + length <= area else { throw RFBError.protocolViolation("ZRLE : plage hors de la tuile") }
                            for i in filled..<(filled + length) { values[i] = palette[index] }
                            filled += length
                        }
                        framebuffer.put(tile, values: values)
                    default:
                        throw RFBError.protocolViolation("ZRLE : sous-encodage \(subencoding)")
                    }
                    tileX += 64
                }
                tileY += 64
            }
        }
    }

    // MARK: Curseur

    private func cursor(_ rect: RFBRect, reader: RFBReader) async throws -> RFBCursor {
        guard rect.width <= 256, rect.height <= 256 else { throw RFBError.protocolViolation("curseur \(rect.width) × \(rect.height)") }
        guard rect.area > 0 else { return RFBCursor(width: 0, height: 0, hotspotX: 0, hotspotY: 0, pixels: []) }
        let colors = pixels(try await reader.bytes(rect.area * format.bytesPerPixel), count: rect.area)
        let rowBytes = (rect.width + 7) / 8
        let mask = try await reader.bytes(rowBytes * rect.height)
        var values = colors
        for row in 0..<rect.height {
            for column in 0..<rect.width {
                let bit = mask[row * rowBytes + column / 8] >> UInt8(7 - column % 8) & 1
                if bit == 0 { values[row * rect.width + column] = 0 }
            }
        }
        // Pour le pseudo-encodage Cursor, x et y désignent le point chaud.
        return RFBCursor(width: rect.width, height: rect.height, hotspotX: min(rect.x, rect.width - 1),
                         hotspotY: min(rect.y, rect.height - 1), pixels: values)
    }
}
