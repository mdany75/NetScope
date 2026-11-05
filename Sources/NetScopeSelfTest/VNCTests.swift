import Foundation
@testable import NetScopeCore

// Note 57 : client VNC intégré (RFB, RFC 6143). Octets fixes seulement : les vecteurs DES, AES et
// Diffie-Hellman ont été calculés hors de NetScope (LibreSSL et Python) ; les sessions complètes
// passent par un canal en mémoire (aucun réseau).

private func hex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
        index = next
    }
    return bytes
}

private func toHex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// Octets écrits par un « serveur » de test.
private struct ServerScript {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: Int) { bytes.append(u16: UInt16(v)) }
    mutating func u32(_ v: UInt32) { bytes.append(u32: v) }
    mutating func s32(_ v: Int32) { bytes.append(u32: UInt32(bitPattern: v)) }
    mutating func text(_ s: String) { bytes += Array(s.utf8) }
    mutating func raw(_ b: [UInt8]) { bytes += b }
    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ encoding: Int32) {
        u16(x); u16(y); u16(w); u16(h); s32(encoding)
    }
    mutating func pixel(_ argb: UInt32, _ format: RFBPixelFormat = .rgb888) { bytes += format.bytes(forARGB: argb) }
    mutating func serverInit(width: Int, height: Int, name: String) {
        u16(width); u16(height)
        raw(RFBPixelFormat.rgb888.encoded())
        let utf8 = Array(name.utf8)
        u32(UInt32(utf8.count)); raw(utf8)
    }
}

/// Événements reçus, protégés pour la boucle de réception.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RFBEvent] = []
    func add(_ event: RFBEvent) { lock.withLock { items.append(event) } }
    var all: [RFBEvent] { lock.withLock { items } }

    var lastFramebuffer: RFBFramebuffer? {
        all.reversed().lazy.compactMap { if case .framebuffer(let fb, _) = $0 { return fb } else { return nil } }.first
    }
    var closeError: RFBError?? {
        for event in all { if case .closed(let error) = event { return .some(error) } }
        return nil
    }
    var info: RFBServerInfo? {
        all.lazy.compactMap { if case .connected(let info) = $0 { return info } else { return nil } }.first
    }
}

/// Session complète contre des octets fixes ; la fin du flux ferme la session.
private func runSession(_ script: ServerScript, credentials: RFBCredentials = RFBCredentials(),
                        options: RFBOptions = RFBOptions()) async -> (EventLog, [UInt8]) {
    let transport = RFBMemoryTransport(serverBytes: script.bytes, closeAfter: true)
    let log = EventLog()
    let client = RFBClient(transport: transport, credentials: credentials, options: options) { log.add($0) }
    await client.run()
    return (log, transport.sent)
}

private let red: UInt32 = 0xFFFF_0000, green: UInt32 = 0xFF00_FF00, blue: UInt32 = 0xFF00_00FF, white: UInt32 = 0xFFFF_FFFF
private let black: UInt32 = 0xFF00_0000

func registerVNCTests(_ suite: TestSuite) {
    suite.add("VNC : négociation de version (3.3, 3.7, 3.8, macOS 3.889)") {
        func chosen(_ banner: String) throws -> RFBVersion { try RFBVersion.negotiate(Array(banner.utf8)).chosen }
        try expectEqual(try chosen("RFB 003.003\n"), .v3_3, "3.3")
        try expectEqual(try chosen("RFB 003.005\n"), .v3_3, "3.5 traité comme 3.3")
        try expectEqual(try chosen("RFB 003.007\n"), .v3_7, "3.7")
        try expectEqual(try chosen("RFB 003.008\n"), .v3_8, "3.8")
        try expectEqual(try chosen("RFB 003.889\n"), .v3_8, "macOS répond 3.889 : 3.8")
        try expectEqual(RFBVersion.v3_8.handshake, Array("RFB 003.008\n".utf8), "réponse du client")
        try expectThrows(RFBError.unsupportedVersion("4.0"), "version 4") { _ = try chosen("RFB 004.000\n") }
        do {
            _ = try chosen("SSH-2.0-Open")
            throw TestFailure(message: "bannière SSH acceptée", file: #fileID, line: #line)
        } catch RFBError.protocolViolation {}
    }

    suite.add("VNC : choix de l'authentification") {
        try expectEqual(try RFBSecurityChoice.choose([2, 1], hasUsername: false), .none, "aucune si offerte")
        try expectEqual(try RFBSecurityChoice.choose([30, 2], hasUsername: false), .vncAuthentication, "VNC sans utilisateur")
        try expectEqual(try RFBSecurityChoice.choose([30, 2], hasUsername: true), .appleRemoteDesktop, "macOS avec utilisateur")
        try expectEqual(try RFBSecurityChoice.choose([30, 35], hasUsername: false), .appleRemoteDesktop, "macOS seul")
        try expectThrows(RFBError.unsupportedSecurity([16, 19]), "Tight et VeNCrypt seuls") {
            _ = try RFBSecurityChoice.choose([16, 19], hasUsername: true)
        }
    }

    suite.add("VNC : DES (vecteur FIPS) et clé du mot de passe à bits inversés") {
        let des = try RFBAuthentication.desECB(key: hex("133457799bbcdff1"), data: hex("0123456789abcdef"), encrypt: true)
        try expectEqual(toHex(des), "85e813540f0ab405", "DES FIPS 81")
        try expectEqual(RFBAuthentication.reverseBits(0x01), 0x80, "bit 0 → bit 7")
        try expectEqual(RFBAuthentication.reverseBits(0x70), 0x0E, "« p »")
        try expectEqual(toHex(RFBAuthentication.vncKey(password: "netscope")), "76a62ecec6f60ea6", "clé de « netscope »")
        try expectEqual(toHex(RFBAuthentication.vncKey(password: "")), "0000000000000000", "mot de passe vide")
        try expectEqual(RFBAuthentication.vncKey(password: "netscope-trop-long"), RFBAuthentication.vncKey(password: "netscope"),
                        "8 caractères au plus")
    }

    suite.add("VNC : réponse au défi (octets fixes)") {
        let response = try RFBAuthentication.vncResponse(challenge: Array(0..<16), password: "netscope")
        try expectEqual(toHex(response), "ce542897008dae39cb0822d5dfe6ee95", "défi 00…0f")
        let second = try RFBAuthentication.vncResponse(challenge: hex("8f1e2d3c4b5a69788796a5b4c3d2e1f0"), password: "secret")
        try expectEqual(toHex(second), "0752d790574ff236382168d796233e2b", "mot de passe court complété par des zéros")
        // Le serveur retrouve le défi avec la même clé.
        let back = try RFBAuthentication.desECB(key: RFBAuthentication.vncKey(password: "secret"), data: second, encrypt: false)
        try expectEqual(toHex(back), "8f1e2d3c4b5a69788796a5b4c3d2e1f0", "déchiffrement")
    }

    suite.add("VNC : exponentiation modulaire (Montgomery)") {
        let result = RFBBigUInt.modPow(RFBBigUInt(bigEndian: hex("1234567890abcdef1234")), RFBBigUInt(bigEndian: hex("0fedcba987654321")),
                                       RFBBigUInt(bigEndian: hex("ffffffffffffffffffffffffffffff61")))
        try expectEqual(result.description, "be1b474cd293b48cde19b98cfc01f7fc", "valeur calculée par Python")
        try expectEqual(RFBBigUInt.modPow(RFBBigUInt(7), RFBBigUInt(0), RFBBigUInt(13)), RFBBigUInt(1), "exposant nul")
        try expectEqual(RFBBigUInt.modPow(RFBBigUInt(20), RFBBigUInt(1), RFBBigUInt(13)), RFBBigUInt(7), "base réduite")
        try expectEqual(RFBBigUInt(bigEndian: hex("00000102")).bigEndianBytes(length: 3), [0, 1, 2], "octets complétés")
    }

    suite.add("VNC : authentification macOS (ARD, Diffie-Hellman + AES-128)") {
        let prime = hex("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF")
        let serverPublic = hex("8065965f1c09adfc268d67e2b222cecda01f1aa41675f4bb7a2866bfffc9258f4d6096ee21ea5656f649ab2ad73211d2d221791c3a7a238faaa2bfd4203c3dab1701524032a5d898ef5aea45152c50b8db04ea55745cd198fdbb03d00daf5b480812abe6fb7fd59473ac99386807c6c54b64cb37eead8830832dea60ddf47522")
        let privateKey = hex("0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186abd0f51a3f6489aed3f81d42678cb1d6fb20456a8fb4d9fe23486d92b7dc0126")
        let filler = (0..<128).map { UInt8(($0 * 7 + 3) & 0xFF) }
        let parameters = RFBAuthentication.ARDParameters(generator: RFBBigUInt(2), keyLength: 128, prime: RFBBigUInt(bigEndian: prime),
                                                         serverPublicKey: RFBBigUInt(bigEndian: serverPublic))
        let response = try RFBAuthentication.ardResponse(parameters, username: "dany", password: "motdepasse",
                                                         privateKey: privateKey, filler: filler)
        let expected = "ed97fad798c3680436a9f23292f71217a97a7b7581a12d092af2fee937282dd5a0bcc1073791fde6b143ed22b57a59ccb6e334b96cf4547e73a1558602780bfa0e0531b01deddab20b11fb5900e8029882a6f12c1e229e864d51d9673fc2440506419c5e1d203d9e3260f20e5d5d5e8b3e90a9fd0cbadddef05e9a490e835083"
            + "9420ca72d19970f4c5343f06b4dbeeff59a9a79460c79be32510ab1fe64f106f6574ec4a42f346396477218cb6e4286b433475ccc966d0b5da3895a9483fc3045b6c5f97a0ab487be28687c6ea0088584ce0defdc594d5c0b79dfd1b5b366b69b912e78b8015f4e51d9644e4c1f2418f23397d77b544aa0ed3cb7aa30007265c"
        try expectEqual(toHex(response), expected, "identifiants chiffrés + clé publique du client")
        try expectThrows(RFBError.authenticationFailed("mot de passe trop long (63 octets au plus)"), "64 octets refusés") {
            _ = try RFBAuthentication.ardCredentialBlock(username: "dany", password: String(repeating: "x", count: 64), filler: filler)
        }
    }

    suite.add("VNC : format des pixels et CPIXEL ZRLE") {
        let format = RFBPixelFormat.rgb888
        try expectEqual(format.encoded(), [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0], "16 octets")
        try expectEqual(try RFBPixelFormat(bytes: format.encoded()), format, "aller-retour")
        try expectEqual(format.compressedPixelSize, 3, "32 bits / profondeur 24 : CPIXEL de 3 octets")
        try expectEqual(RFBPixelFormat.rgb565.compressedPixelSize, 2, "16 bits : pixel complet")
        let wide = RFBPixelFormat(bitsPerPixel: 32, depth: 24, redMax: 255, greenMax: 255, blueMax: 255, redShift: 24, greenShift: 16, blueShift: 8)
        try expectEqual(wide.compressedLayout, false, "couleurs dans les octets de poids fort")
        try expectEqual(format.bytes(forARGB: 0xFF12_3456), [0x56, 0x34, 0x12, 0x00], "B, G, R, X")
        let check: [UInt8] = RFBPixelFormat.rgb565.bytes(forARGB: red)
        try expectEqual(check, [0x00, 0xF8], "rouge en 5-6-5 petit-boutiste")
        try expectEqual(check.withUnsafeBufferPointer { RFBPixelFormat.rgb565.readPixel($0, at: 0) }, red, "rouge relu")
        let big = RFBPixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: true, redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
        try expectEqual([UInt8]([0x07, 0xE0]).withUnsafeBufferPointer { big.readPixel($0, at: 0) }, green, "vert gros-boutiste")
        try expectEqual([UInt8]([0xC0]).withUnsafeBufferPointer { RFBPixelFormat.bgr233.readPixel($0, at: 0) }, blue, "bleu 2-3-3")
    }

    suite.add("VNC : messages du client (octets fixes)") {
        try expectEqual(RFBClientMessage.setEncodings([16, 5, -239]), [2, 0, 0, 3, 0, 0, 0, 16, 0, 0, 0, 5, 0xFF, 0xFF, 0xFF, 0x11], "SetEncodings")
        try expectEqual(RFBClientMessage.framebufferUpdateRequest(incremental: true, RFBRect(x: 1, y: 2, width: 1920, height: 1080)),
                        [3, 1, 0, 1, 0, 2, 0x07, 0x80, 0x04, 0x38], "FramebufferUpdateRequest")
        try expectEqual(RFBClientMessage.keyEvent(keysym: RFBKeysym.delete, down: true), [4, 1, 0, 0, 0, 0, 0xFF, 0xFF], "KeyEvent")
        try expectEqual(RFBClientMessage.pointerEvent(x: 300, y: 2, buttons: RFBButtons([.left, .wheelDown]).rawValue),
                        [5, 17, 0x01, 0x2C, 0, 2], "PointerEvent")
        try expectEqual(RFBClientMessage.clientCutText("é\r\n€"), [6, 0, 0, 0, 0, 0, 0, 3, 0xE9, 0x0A, 0x3F], "Latin-1, LF, « ? » hors Latin-1")
        try expectEqual(RFBText.string(latin1: [0x43, 0x61, 0x66, 0xE9]), "Café", "Latin-1 relu")
    }

    suite.add("VNC : keysyms du clavier du Mac") {
        try expectEqual(RFBKeysym.forMacKey(keyCode: 0x24, characters: "\r"), RFBKeysym.returnKey, "Retour")
        try expectEqual(RFBKeysym.forMacKey(keyCode: 0x75, characters: nil), RFBKeysym.delete, "Suppr")
        try expectEqual(RFBKeysym.forMacKey(keyCode: 0x7A, characters: nil), 0xFFBE, "F1")
        try expectEqual(RFBKeysym.forMacKey(keyCode: 0x00, characters: "A"), 0x41, "A majuscule")
        try expectEqual(RFBKeysym.forMacKey(keyCode: 0x00, characters: "é"), 0xE9, "é (Latin-1)")
        try expectEqual(RFBKeysym.forMacKey(keyCode: 0x00, characters: "€"), 0x0100_20AC, "€ (Unicode)")
        try expectEqual(RFBKeysym.macModifierKeyCodes[0x37], RFBKeysym.superLeft, "Commande → Super")
        try expectEqual(RFBKeysym.ctrlAltDelete, [0xFFE3, 0xFFE9, 0xFFFF], "Ctrl-Alt-Suppr")
    }

    suite.add("VNC : tampon d'image (remplissage, copie qui se chevauche, taille)") {
        var fb = RFBFramebuffer(width: 4, height: 3, fill: black)
        fb.fill(RFBRect(x: 1, y: 1, width: 10, height: 10), color: red)
        try expectEqual(fb.pixel(x: 3, y: 2), red, "rogné au tampon")
        try expectEqual(fb.pixel(x: 0, y: 1), black, "hors du rectangle")
        fb.put(RFBRect(x: 0, y: 0, width: 2, height: 1), values: [green, blue])
        fb.copy(from: 0, 0, to: RFBRect(x: 1, y: 0, width: 2, height: 1))
        try expectEqual([fb.pixel(x: 0, y: 0), fb.pixel(x: 1, y: 0), fb.pixel(x: 2, y: 0)], [green, green, blue], "chevauchement")
        fb.resize(width: 2, height: 2)
        try expectEqual(fb.pixels, [green, green, black, red], "partie commune gardée")
    }

    suite.add("VNC : décodage ZRLE (flux zlib persistant, octets fixes)") {
        let decoder = RFBDecoder(format: .rgb888)
        var fb = RFBFramebuffer(width: 8, height: 8, fill: black)
        // Palette de 2 couleurs, index sur 1 bit.
        try decoder.zrle(RFBRect(x: 0, y: 0, width: 4, height: 2), compressed: hex("789c626260f8ff9f81614102000000ffff"), into: &fb)
        try expectEqual(Array(fb.pixels[0..<4]) + Array(fb.pixels[8..<12]), [blue, red, blue, red, red, blue, blue, red], "palette 1 bit")
        // RLE simple (même flux zlib).
        try decoder.zrle(RFBRect(x: 0, y: 2, width: 3, height: 2), compressed: hex("6af8ffff3f33c37f064600000000ffff"), into: &fb)
        try expectEqual(Array(fb.pixels[16..<19]) + Array(fb.pixels[24..<27]), [white, white, white, white, green, green], "RLE")
        // RLE à palette.
        try decoder.zrle(RFBRect(x: 0, y: 4, width: 5, height: 1), compressed: hex("6a028a006103132303000000ffff"), into: &fb)
        try expectEqual(Array(fb.pixels[32..<37]), [red, red, red, green, red], "RLE à palette")
        // Brut.
        try decoder.zrle(RFBRect(x: 6, y: 0, width: 2, height: 2), compressed: hex("628030ff83d4fc07000000ffff"), into: &fb)
        try expectEqual([fb.pixel(x: 6, y: 0), fb.pixel(x: 7, y: 0), fb.pixel(x: 6, y: 1), fb.pixel(x: 7, y: 1)], [red, green, blue, white], "brut")
        // Couleur unie.
        try decoder.zrle(RFBRect(x: 2, y: 5, width: 6, height: 3), compressed: hex("62045200000000ffff"), into: &fb)
        try expectEqual(fb.pixel(x: 7, y: 7), blue, "uni")
        try expectEqual(fb.pixel(x: 1, y: 5), black, "uni : hors du rectangle")
        // Palette de 3 couleurs, index sur 2 bits.
        try decoder.zrle(RFBRect(x: 5, y: 2, width: 3, height: 3), compressed: hex("62860b482c7001000000ffff"), into: &fb)
        let block = (2..<5).flatMap { y in (5..<8).map { x in fb.pixel(x: x, y: y) } }
        try expectEqual(block, [red, green, blue, blue, blue, red, green, red, green], "palette 2 bits")
    }

    suite.add("VNC : ZRLE en grandes tuiles (64 × 64, rectangle partiel) contre l'image attendue") {
        // Image 70 × 66 (4 tuiles, dont trois partielles), compressée par la zlib du système.
        let width = 70, height = 66
        let expected = (0..<(width * height)).map { i -> UInt32 in 0xFF00_0000 | UInt32((i * 2_654_435_761) & 0x00FF_FFFF) }
        var payload: [UInt8] = []
        for ty in stride(from: 0, to: height, by: 64) {
            for tx in stride(from: 0, to: width, by: 64) {
                payload.append(0)
                for y in ty..<min(ty + 64, height) {
                    for x in tx..<min(tx + 64, width) { payload += Array(RFBPixelFormat.rgb888.bytes(forARGB: expected[y * width + x]).prefix(3)) }
                }
            }
        }
        let deflater = RFBDeflater()
        var fb = RFBFramebuffer(width: width, height: height)
        try RFBDecoder(format: .rgb888).zrle(RFBRect(x: 0, y: 0, width: width, height: height), compressed: deflater.deflate(payload), into: &fb)
        try expectEqual(fb.pixels, expected, "image identique")
    }

    suite.add("VNC : session 3.8 complète (mot de passe, Raw, RRE, Hextile, CopyRect, presse-papiers)") {
        var s = ServerScript()
        s.text("RFB 003.008\n")
        s.u8(2); s.raw([30, 2])                 // macOS et VNC proposés
        s.raw(Array(0..<16))                    // défi
        s.u32(0)                                 // authentification acceptée
        s.serverInit(width: 32, height: 16, name: "WKS352 — Poste")
        // Mise à jour : 5 rectangles.
        s.u8(0); s.u8(0); s.u16(5)
        s.rect(0, 0, 2, 2, RFBEncoding.raw)
        for color in [red, green, blue, white] { s.pixel(color) }
        s.rect(16, 0, 8, 4, RFBEncoding.rre)
        s.u32(1); s.pixel(blue); s.pixel(red); s.u16(2); s.u16(1); s.u16(3); s.u16(2)
        s.rect(1, 2, 2, 2, RFBEncoding.cursor)
        for color in [white, black, black, white] { s.pixel(color) }
        s.raw([0b1000_0000, 0b0100_0000])
        // Hextile : 32 × 16 en deux tuiles. Tuile 1 : fond vert + 2 sous-rectangles du premier plan
        // rouge ; tuile 2 : brute (rouge uni).
        s.rect(0, 4, 32, 12, RFBEncoding.hextile)
        s.u8(2 | 4 | 8); s.pixel(green); s.pixel(red); s.u8(2)
        s.u8(0x00); s.u8(0x11)                  // (0,0) 2 × 2
        s.u8(0x5A); s.u8(0x00)                  // (5,10) 1 × 1
        s.u8(1); for _ in 0..<(16 * 12) { s.pixel(red) }
        s.rect(4, 0, 2, 2, RFBEncoding.copyRect); s.u16(0); s.u16(0)
        // Presse-papiers puis sonnerie.
        s.u8(3); s.raw([0, 0, 0]); s.u32(6); s.raw(Array("Bonjo".utf8) + [0xE9])
        s.u8(2)

        let (log, sent) = await runSession(s, credentials: RFBCredentials(password: "netscope"))
        // Octets du client : version, type 2, réponse DES, partage, SetPixelFormat, SetEncodings,
        // demande complète, puis demande incrémentale après la mise à jour.
        var expected: [UInt8] = Array("RFB 003.008\n".utf8) + [2] + hex("ce542897008dae39cb0822d5dfe6ee95") + [1]
        expected += RFBClientMessage.setPixelFormat(.rgb888) + RFBClientMessage.setEncodings(RFBEncoding.preferred)
        expected += RFBClientMessage.framebufferUpdateRequest(incremental: false, RFBRect(x: 0, y: 0, width: 32, height: 16))
        expected += RFBClientMessage.framebufferUpdateRequest(incremental: true, RFBRect(x: 0, y: 0, width: 32, height: 16))
        try expectEqual(toHex(sent), toHex(expected), "octets envoyés par le client")

        guard let info = log.info else { throw TestFailure(message: "pas de ServerInit", file: #fileID, line: #line) }
        try expectEqual(info.name, "WKS352 — Poste", "nom (UTF-8)")
        try expectEqual(info.security, .vncAuthentication, "mot de passe VNC")
        try expectEqual(info.version, .v3_8, "version")
        guard let fb = log.lastFramebuffer else { throw TestFailure(message: "aucune image", file: #fileID, line: #line) }
        try expectEqual([fb.pixel(x: 0, y: 0), fb.pixel(x: 1, y: 0), fb.pixel(x: 0, y: 1), fb.pixel(x: 1, y: 1)], [red, green, blue, white], "Raw")
        try expectEqual([fb.pixel(x: 4, y: 0), fb.pixel(x: 5, y: 1)], [red, white], "CopyRect (copie du Raw)")
        try expectEqual([fb.pixel(x: 16, y: 0), fb.pixel(x: 18, y: 1), fb.pixel(x: 20, y: 2), fb.pixel(x: 21, y: 3)], [blue, red, red, blue], "RRE")
        try expectEqual([fb.pixel(x: 0, y: 4), fb.pixel(x: 1, y: 5), fb.pixel(x: 2, y: 4), fb.pixel(x: 5, y: 14), fb.pixel(x: 6, y: 14)],
                        [red, red, green, red, green], "Hextile : fond et sous-rectangles")
        try expectEqual([fb.pixel(x: 16, y: 4), fb.pixel(x: 31, y: 15)], [red, red], "Hextile : tuile brute")
        let cursor = log.all.lazy.compactMap { if case .cursor(let c) = $0 { return c } else { return nil } }.first
        try expectEqual(cursor?.pixels, [white, 0, 0, white], "curseur masqué hors du masque")
        try expectEqual(cursor?.hotspotX, 1, "point chaud")
        let clipboard = log.all.lazy.compactMap { if case .clipboard(let t) = $0 { return t } else { return nil } }.first
        try expectEqual(clipboard, "Bonjoé", "presse-papiers Latin-1")
        try expect(log.all.contains { if case .bell = $0 { return true } else { return false } }, "sonnerie")
        let stats = log.all.lazy.compactMap { if case .framebuffer(_, let st) = $0 { return st } else { return nil } }.first
        try expectEqual(stats?.encodings, ["Raw", "RRE", "Hextile", "CopyRect"], "encodages vus")
        try expectEqual(stats?.rectangles, 5, "rectangles (curseur compris)")
        // Fin du flux : session close avec « fermée par l'ordinateur distant ».
        try expectEqual(log.closeError, .some(.closed), "fermeture signalée")
    }

    suite.add("VNC : 3.3 sans authentification, DesktopSize et LastRect") {
        var s = ServerScript()
        s.text("RFB 003.003\n")
        s.u32(1)                                   // None, sans résultat en 3.3
        s.serverInit(width: 4, height: 4, name: "x11")
        s.u8(0); s.u8(0); s.u16(0xFFFF)          // nombre inconnu : LastRect termine
        s.rect(0, 0, 8, 2, RFBEncoding.desktopSize)
        s.rect(6, 0, 2, 1, RFBEncoding.raw); s.pixel(red); s.pixel(green)
        s.rect(0, 0, 0, 0, RFBEncoding.lastRect)
        let (log, sent) = await runSession(s)
        try expectEqual(Array(sent.prefix(13)), Array("RFB 003.003\n".utf8) + [1], "version 3.3 puis partage (aucun choix de sécurité)")
        let fb = log.lastFramebuffer
        try expectEqual(fb?.width, 8, "nouvelle largeur")
        try expectEqual(fb?.pixel(x: 7, y: 0), green, "pixel après redimensionnement")
        try expect(toHex(sent).hasSuffix(toHex(RFBClientMessage.framebufferUpdateRequest(incremental: true, RFBRect(x: 0, y: 0, width: 8, height: 2)))),
                   "demande à la nouvelle taille")
    }

    suite.add("VNC : 3.7 sans résultat pour None, 3.8 avec résultat") {
        var s37 = ServerScript()
        s37.text("RFB 003.007\n"); s37.u8(1); s37.u8(1)
        s37.serverInit(width: 2, height: 2, name: "a")
        let (log37, _) = await runSession(s37)
        try expectEqual(log37.info?.version, .v3_7, "3.7 : ServerInit lu directement")
        var s38 = ServerScript()
        s38.text("RFB 003.008\n"); s38.u8(1); s38.u8(1); s38.u32(0)
        s38.serverInit(width: 2, height: 2, name: "b")
        let (log38, _) = await runSession(s38)
        try expectEqual(log38.info?.name, "b", "3.8 : résultat de sécurité lu")
    }

    suite.add("VNC : refus, mot de passe manquant ou faux") {
        var refused = ServerScript()
        refused.text("RFB 003.008\n"); refused.u8(0); refused.u32(14); refused.text("Trop de essais")
        try expectEqual(await runSession(refused).0.closeError, .some(.refused("Trop de essais")), "refus avec raison")

        var missing = ServerScript()
        missing.text("RFB 003.008\n"); missing.u8(1); missing.u8(2); missing.raw(Array(0..<16))
        try expectEqual(await runSession(missing).0.closeError, .some(.passwordRequired(.vncAuthentication)), "mot de passe demandé")

        var wrong = ServerScript()
        wrong.text("RFB 003.008\n"); wrong.u8(1); wrong.u8(2); wrong.raw(Array(0..<16)); wrong.u32(1); wrong.u32(17); wrong.text("Mot de passe faux")
        try expectEqual(await runSession(wrong, credentials: RFBCredentials(password: "x")).0.closeError,
                        .some(.authenticationFailed("Mot de passe faux")), "raison du serveur")

        var ard = ServerScript()
        ard.text("RFB 003.889\n"); ard.u8(1); ard.u8(30); ard.u16(2); ard.u16(1); ard.u8(23); ard.u8(5)
        try expectEqual(await runSession(ard, credentials: RFBCredentials(password: "x")).0.closeError,
                        .some(.usernameRequired), "macOS : utilisateur demandé")

        var garbage = ServerScript()
        garbage.text("RFB 003.008\n"); garbage.u8(1); garbage.u8(1); garbage.u32(0); garbage.serverInit(width: 2, height: 2, name: "c")
        garbage.u8(0); garbage.u8(0); garbage.u16(1); garbage.rect(0, 0, 4, 4, RFBEncoding.raw)
        if case .some(.some(.protocolViolation)) = await runSession(garbage).0.closeError {} else {
            throw TestFailure(message: "rectangle hors de l'écran accepté", file: #fileID, line: #line)
        }
    }

    suite.add("VNC : changement de format entre deux mises à jour (qualité adaptative)") {
        var governor = RFBQualityGovernor(quality: .adaptive)
        let start = Date(timeIntervalSince1970: 0)
        try expect(governor.record(bytes: 1_000, duration: 1, now: start) == nil, "petite mise à jour ignorée")
        try expectEqual(governor.record(bytes: 1_000_000, duration: 1, now: start), .rgb565, "1 Mo/s : 16 bits")
        try expect(governor.record(bytes: 20_000_000, duration: 1, now: start.addingTimeInterval(1)) == nil, "attente minimale")
        try expectEqual(governor.record(bytes: 20_000_000, duration: 1, now: start.addingTimeInterval(10)), .rgb888, "lien rapide : 32 bits")
        try expectEqual(governor.setQuality(.high), nil, "déjà en 32 bits")

        // Session : le nouveau format part juste après la mise à jour, suivi d'une demande complète.
        let transport = RFBMemoryTransport()
        let log = EventLog()
        let client = RFBClient(transport: transport, credentials: RFBCredentials()) { log.add($0) }
        var s = ServerScript()
        s.text("RFB 003.008\n"); s.u8(1); s.u8(1); s.u32(0); s.serverInit(width: 2, height: 1, name: "q")
        transport.feed(s.bytes)
        let task = Task { await client.run() }
        while log.info == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        client.setPixelFormat(.rgb565)
        var update = ServerScript()
        update.u8(0); update.u8(0); update.u16(1); update.rect(0, 0, 2, 1, RFBEncoding.raw); update.pixel(red); update.pixel(red)
        transport.feed(update.bytes)
        // Mise à jour suivante en 16 bits.
        var update16 = ServerScript()
        update16.u8(0); update16.u8(0); update16.u16(1); update16.rect(0, 0, 2, 1, RFBEncoding.raw)
        update16.pixel(green, .rgb565); update16.pixel(blue, .rgb565)
        transport.feed(update16.bytes)
        transport.finish()
        await task.value
        try expectEqual(log.lastFramebuffer?.pixels, [green, blue], "pixels 16 bits décodés")
        let tail = RFBClientMessage.setPixelFormat(.rgb565) + RFBClientMessage.framebufferUpdateRequest(incremental: false, RFBRect(x: 0, y: 0, width: 2, height: 1))
        try expect(toHex(transport.sent).contains(toHex(tail)), "SetPixelFormat puis demande complète")
    }

    suite.add("VNC : clavier et souris refusés pendant la poignée de main") {
        let transport = RFBMemoryTransport()
        let client = RFBClient(transport: transport, credentials: RFBCredentials()) { _ in }
        client.sendKey(0x61, down: true)
        client.sendPointer(x: 1, y: 1, buttons: .left)
        try expect(transport.sent.isEmpty, "rien n'est envoyé avant ServerInit")
    }

    suite.add("VNC : serveur RFB minimal sur 127.0.0.1 (connexion TCP réelle en boucle locale)") {
        let server = try LoopbackRFBServer()
        defer { server.stop() }
        let port = try await server.start()
        let transport = RFBNetworkTransport(host: "127.0.0.1", port: port)
        try await transport.open(timeout: 5)
        let log = EventLog()
        let client = RFBClient(transport: transport, credentials: RFBCredentials(password: "netscope")) { log.add($0) }
        let task = Task { await client.run() }
        let deadline = Date().addingTimeInterval(5)
        while log.lastFramebuffer == nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        client.close()
        await task.value
        try expectEqual(log.info?.name, "127.0.0.1 — test", "ServerInit reçu par TCP")
        try expectEqual(log.lastFramebuffer?.pixels, [red, green, blue, white], "image reçue par TCP")
        try expectEqual(log.closeError, .some(nil), "fermeture demandée : aucune erreur")
    }
}

// MARK: - Serveur de test sur 127.0.0.1

import Network

/// Serveur RFB 3.8 minimal (mot de passe VNC « netscope », écran 2 × 2) qui n'écoute que sur
/// 127.0.0.1 : vérifie le transport TCP sans jamais sortir de la machine.
private final class LoopbackRFBServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "netscope.test.rfb")
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> Int {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = RFBOnce()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: Int(self?.listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }

    private func serve(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        var script = ServerScript()
        script.text("RFB 003.008\n")
        connection.send(content: Data(script.bytes), completion: .idempotent)
        // Version (12) : types proposés ; type choisi (1) : défi.
        receive(connection, 12) {
            connection.send(content: Data([1, 2]), completion: .idempotent)
            self.receive(connection, 1) {
                connection.send(content: Data(Array(0..<16)), completion: .idempotent)
                // Réponse (16) : succès, puis partage (1) : ServerInit et une image.
                self.receive(connection, 16) {
                    var reply = ServerScript()
                    reply.u32(0)
                    connection.send(content: Data(reply.bytes), completion: .idempotent)
                    self.receive(connection, 1) {
                        var s = ServerScript()
                        s.serverInit(width: 2, height: 2, name: "127.0.0.1 — test")
                        s.u8(0); s.u8(0); s.u16(1); s.rect(0, 0, 2, 2, RFBEncoding.raw)
                        for color in [red, green, blue, white] { s.pixel(color) }
                        connection.send(content: Data(s.bytes), completion: .idempotent)
                    }
                }
            }
        }
    }

    private func receive(_ connection: NWConnection, _ count: Int, then: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { _, _, _, error in
            if error == nil { then() }
        }
    }
}
