import Foundation

// Note 57 : client VNC intégré (protocole RFB, RFC 6143), sans dépendance externe.
// Format des pixels (RFC 6143 § 7.4) : NetScope demande toujours des couleurs vraies (true colour)
// et convertit chaque pixel reçu en 0xAARRGGBB (alpha à 0xFF) pour le tampon d'image.

/// Format des pixels échangé avec le serveur (16 octets sur le réseau).
public struct RFBPixelFormat: Equatable, Hashable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColor: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public init(bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool = false, trueColor: Bool = true,
                redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
                redShift: UInt8, greenShift: UInt8, blueShift: UInt8) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// 32 bits, 16,7 millions de couleurs, petit-boutiste (B, G, R, X sur le réseau) : sans perte.
    public static let rgb888 = RFBPixelFormat(bitsPerPixel: 32, depth: 24, redMax: 255, greenMax: 255, blueMax: 255,
                                              redShift: 16, greenShift: 8, blueShift: 0)
    /// 16 bits (RGB 5-6-5), 65 536 couleurs : deux fois moins de données.
    public static let rgb565 = RFBPixelFormat(bitsPerPixel: 16, depth: 16, redMax: 31, greenMax: 63, blueMax: 31,
                                              redShift: 11, greenShift: 5, blueShift: 0)
    /// 8 bits (BGR 2-3-3), 256 couleurs : liaisons très lentes.
    public static let bgr233 = RFBPixelFormat(bitsPerPixel: 8, depth: 8, redMax: 7, greenMax: 7, blueMax: 3,
                                              redShift: 0, greenShift: 3, blueShift: 6)

    public var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    /// Format pris en charge pour l'affichage : couleurs vraies, 8, 16 ou 32 bits.
    public var isSupported: Bool {
        trueColor && [8, 16, 32].contains(bitsPerPixel) && redMax > 0 && greenMax > 0 && blueMax > 0
    }

    // MARK: Réseau

    /// Les 16 octets du format (3 octets de remplissage compris).
    public func encoded() -> [UInt8] {
        [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColor ? 1 : 0,
         UInt8(redMax >> 8), UInt8(redMax & 0xFF), UInt8(greenMax >> 8), UInt8(greenMax & 0xFF),
         UInt8(blueMax >> 8), UInt8(blueMax & 0xFF), redShift, greenShift, blueShift, 0, 0, 0]
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 16 else { throw RFBError.protocolViolation("format de pixels tronqué") }
        let b = Array(bytes.prefix(16))
        self.init(bitsPerPixel: b[0], depth: b[1], bigEndian: b[2] != 0, trueColor: b[3] != 0,
                  redMax: UInt16(b[4]) << 8 | UInt16(b[5]), greenMax: UInt16(b[6]) << 8 | UInt16(b[7]),
                  blueMax: UInt16(b[8]) << 8 | UInt16(b[9]), redShift: b[10], greenShift: b[11], blueShift: b[12])
    }

    /// « 32 bits (16,7 millions de couleurs) ».
    public var label: String {
        switch bitsPerPixel {
        case 32, 24: return "32 bits"
        case 16: return "16 bits"
        default: return "\(bitsPerPixel) bits"
        }
    }

    // MARK: Conversion

    /// Valeur brute (lue dans l'ordre des octets du format) → 0xFFRRGGBB.
    @inline(__always)
    public func argb(fromRaw value: UInt32) -> UInt32 {
        if redMax == 255, greenMax == 255, blueMax == 255, redShift == 16, greenShift == 8, blueShift == 0 {
            return 0xFF00_0000 | (value & 0x00FF_FFFF)
        }
        let r = Self.scale((value >> UInt32(redShift)) & UInt32(redMax), max: UInt32(redMax))
        let g = Self.scale((value >> UInt32(greenShift)) & UInt32(greenMax), max: UInt32(greenMax))
        let b = Self.scale((value >> UInt32(blueShift)) & UInt32(blueMax), max: UInt32(blueMax))
        return 0xFF00_0000 | r << 16 | g << 8 | b
    }

    @inline(__always)
    static func scale(_ component: UInt32, max: UInt32) -> UInt32 {
        max == 255 ? component : (component * 255 + max / 2) / max
    }

    /// Couleur 0xFFRRGGBB → valeur brute du format (pour les tests et le serveur de démonstration).
    public func raw(fromARGB argb: UInt32) -> UInt32 {
        func channel(_ value: UInt32, _ max: UInt16, _ shift: UInt8) -> UInt32 {
            ((value * UInt32(max) + 127) / 255) << UInt32(shift)
        }
        return channel((argb >> 16) & 0xFF, redMax, redShift) | channel((argb >> 8) & 0xFF, greenMax, greenShift)
            | channel(argb & 0xFF, blueMax, blueShift)
    }

    /// Octets d'un pixel 0xFFRRGGBB dans ce format (ordre des octets compris).
    public func bytes(forARGB argb: UInt32) -> [UInt8] {
        let raw = raw(fromARGB: argb)
        let count = bytesPerPixel
        var result = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let shift = bigEndian ? (count - 1 - i) * 8 : i * 8
            result[i] = UInt8((raw >> UInt32(shift)) & 0xFF)
        }
        return result
    }

    /// Lit un pixel de `bytesPerPixel` octets à `offset`.
    @inline(__always)
    public func readPixel(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        let raw: UInt32
        switch bitsPerPixel {
        case 8:
            raw = UInt32(bytes[offset])
        case 16:
            let a = UInt32(bytes[offset]), b = UInt32(bytes[offset + 1])
            raw = bigEndian ? a << 8 | b : b << 8 | a
        default:
            let a = UInt32(bytes[offset]), b = UInt32(bytes[offset + 1])
            let c = UInt32(bytes[offset + 2]), d = UInt32(bytes[offset + 3])
            raw = bigEndian ? a << 24 | b << 16 | c << 8 | d : d << 24 | c << 16 | b << 8 | a
        }
        return argb(fromRaw: raw)
    }

    // MARK: ZRLE (RFC 6143 § 7.7.6)

    /// Taille d'un « CPIXEL » ZRLE : 3 octets pour un format 32 bits dont les couleurs tiennent dans
    /// les trois octets de poids faible (ou de poids fort), sinon la taille d'un pixel.
    public var compressedPixelSize: Int {
        guard compressedLayout != nil else { return bytesPerPixel }
        return 3
    }

    /// nil : CPIXEL = pixel complet ; true : les 3 octets de poids faible ; false : de poids fort.
    var compressedLayout: Bool? {
        guard trueColor, bitsPerPixel == 32, depth <= 24 else { return nil }
        func top(_ max: UInt16, _ shift: UInt8) -> Int { Int(shift) + (UInt16.bitWidth - max.leadingZeroBitCount) }
        let highest = Swift.max(top(redMax, redShift), top(greenMax, greenShift), top(blueMax, blueShift))
        let lowest = Swift.min(Int(redShift), Int(greenShift), Int(blueShift))
        if highest <= 24 { return true }
        if lowest >= 8 { return false }
        return nil
    }

    /// Lit un CPIXEL ZRLE à `offset`.
    @inline(__always)
    func readCompressedPixel(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, layout: Bool?) -> UInt32 {
        guard let low = layout else { return readPixel(bytes, at: offset) }
        let a = UInt32(bytes[offset]), b = UInt32(bytes[offset + 1]), c = UInt32(bytes[offset + 2])
        let raw: UInt32
        switch (bigEndian, low) {
        case (false, true): raw = a | b << 8 | c << 16
        case (false, false): raw = a << 8 | b << 16 | c << 24
        case (true, true): raw = a << 16 | b << 8 | c
        case (true, false): raw = a << 24 | b << 16 | c << 8
        }
        return argb(fromRaw: raw)
    }
}
