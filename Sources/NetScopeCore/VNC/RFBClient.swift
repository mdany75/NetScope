import Foundation

/// Identifiants d'une session VNC (jamais enregistrés par le moteur : l'application les lit au
/// Trousseau et les passe ici).
public struct RFBCredentials: Sendable {
    public var username: String
    public var password: String?

    public init(username: String = "", password: String? = nil) {
        self.username = username
        self.password = password
    }
}

/// Réglages d'une session.
public struct RFBOptions: Sendable {
    /// Format demandé au serveur (32 bits par défaut).
    public var pixelFormat: RFBPixelFormat
    /// Partager le bureau avec les autres visiteurs (ClientInit, « shared-flag »).
    public var shared: Bool
    public var encodings: [Int32]

    public init(pixelFormat: RFBPixelFormat = .rgb888, shared: Bool = true, encodings: [Int32] = RFBEncoding.preferred) {
        self.pixelFormat = pixelFormat
        self.shared = shared
        self.encodings = encodings
    }
}

/// Ce que le serveur a annoncé (ServerInit).
public struct RFBServerInfo: Equatable, Sendable {
    public var serverVersion: String
    public var version: RFBVersion
    public var security: RFBSecurityType
    public var name: String
    public var width: Int
    public var height: Int
    public var serverFormat: RFBPixelFormat
}

/// Statistiques d'une mise à jour.
public struct RFBUpdateStats: Equatable, Sendable {
    /// Octets reçus pour cette mise à jour (en-têtes compris).
    public var bytes: Int
    public var rectangles: Int
    /// Encodages vus, par nom (« ZRLE », « CopyRect »…).
    public var encodings: Set<String>
    public var duration: TimeInterval
    public var dirty: RFBRect
}

/// Événements d'une session, dans l'ordre où ils se produisent.
public enum RFBEvent: Sendable {
    case connecting
    case authenticating(RFBSecurityType)
    case connected(RFBServerInfo)
    case framebuffer(RFBFramebuffer, RFBUpdateStats)
    case cursor(RFBCursor)
    case bell
    case clipboard(String)
    case pixelFormat(RFBPixelFormat)
    case closed(RFBError?)
}

/// Client RFB (RFC 6143) : poignée de main 3.3, 3.7 ou 3.8, sécurité None, mot de passe VNC (DES)
/// ou compte macOS (ARD), ServerInit, SetPixelFormat, SetEncodings, puis boucle des mises à jour
/// incrémentales. Les événements du clavier, de la souris et du presse-papiers partent par
/// `send…` depuis n'importe quel fil ; la boucle de réception tourne dans `run()`.
public final class RFBClient: @unchecked Sendable {
    private let transport: RFBTransport
    private let credentials: RFBCredentials
    private let options: RFBOptions
    private let onEvent: @Sendable (RFBEvent) -> Void
    /// Clé privée et remplissage ARD imposés (tests) ; aléatoires sinon.
    var ardPrivateKey: [UInt8]?
    var ardFiller: [UInt8]?

    private let lock = NSLock()
    private var pendingFormat: RFBPixelFormat?
    private var pendingFullRefresh = false
    private var running = false
    private var closed = false
    private var size = (width: 0, height: 0)

    public init(transport: RFBTransport, credentials: RFBCredentials, options: RFBOptions = RFBOptions(),
                onEvent: @escaping @Sendable (RFBEvent) -> Void) {
        self.transport = transport
        self.credentials = credentials
        self.options = options
        self.onEvent = onEvent
    }

    // MARK: Envois (n'importe quel fil)

    private func send(_ bytes: [UInt8]) {
        lock.lock()
        let ok = running && !closed
        lock.unlock()
        guard ok else { return }
        transport.send(bytes)
    }

    public func sendKey(_ keysym: UInt32, down: Bool) {
        send(RFBClientMessage.keyEvent(keysym: keysym, down: down))
    }

    /// Appui puis relâchement de chaque touche, relâchées dans l'ordre inverse (Ctrl-Alt-Suppr…).
    public func sendChord(_ keysyms: [UInt32]) {
        var bytes: [UInt8] = []
        for keysym in keysyms { bytes += RFBClientMessage.keyEvent(keysym: keysym, down: true) }
        for keysym in keysyms.reversed() { bytes += RFBClientMessage.keyEvent(keysym: keysym, down: false) }
        send(bytes)
    }

    public func sendPointer(x: Int, y: Int, buttons: RFBButtons) {
        lock.lock()
        let bounds = size
        lock.unlock()
        let cx = min(max(0, x), max(0, bounds.width - 1)), cy = min(max(0, y), max(0, bounds.height - 1))
        send(RFBClientMessage.pointerEvent(x: cx, y: cy, buttons: buttons.rawValue))
    }

    public func sendClipboard(_ text: String) {
        send(RFBClientMessage.clientCutText(text))
    }

    /// Change le format des pixels ; appliqué entre deux mises à jour (aucune demande en cours),
    /// pour ne jamais lire une mise à jour dans le mauvais format.
    public func setPixelFormat(_ format: RFBPixelFormat) {
        lock.lock()
        pendingFormat = format
        lock.unlock()
    }

    /// Redemande toute l'image à la prochaine occasion.
    public func requestFullRefresh() {
        lock.lock()
        pendingFullRefresh = true
        lock.unlock()
    }

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
        transport.close()
    }

    // MARK: Session

    /// Déroule la session jusqu'à la fermeture ; l'événement `.closed` est toujours le dernier.
    public func run() async {
        let reader = RFBReader(transport: transport)
        do {
            onEvent(.connecting)
            let info = try await handshake(reader)
            try await loop(reader, info: info)
        } catch {
            let wasClosed = lock.withLock { () -> Bool in
                let was = closed
                closed = true
                return was
            }
            transport.close()
            let failure = error as? RFBError ?? .network(error.localizedDescription)
            // Fermeture demandée par l'application : pas d'erreur à montrer.
            onEvent(.closed(wasClosed ? nil : failure))
            return
        }
        onEvent(.closed(nil))
    }

    /// Poignée de main, sécurité, ClientInit et ServerInit (§ 7.1 à 7.3).
    func handshake(_ reader: RFBReader) async throws -> RFBServerInfo {
        let (serverVersion, version) = try RFBVersion.negotiate(try await reader.bytes(12))
        transport.send(version.handshake)

        let security: RFBSecurityType
        if version == .v3_3 {
            let type = try await reader.u32()
            if type == 0 { throw RFBError.refused(RFBText.string(latin1: try await reader.string())) }
            guard type <= 255, let known = RFBSecurityType(rawValue: UInt8(type)), known != .invalid else {
                throw RFBError.unsupportedSecurity([UInt8(truncatingIfNeeded: type)])
            }
            security = known
        } else {
            let count = Int(try await reader.u8())
            if count == 0 { throw RFBError.refused(RFBText.string(latin1: try await reader.string())) }
            let offered = try await reader.bytes(count)
            security = try RFBSecurityChoice.choose(offered, hasUsername: !credentials.username.isEmpty)
            transport.send([security.rawValue])
        }

        switch security {
        case .none:
            // 3.8 envoie un résultat même sans authentification ; 3.3 et 3.7 non.
            if version == .v3_8 { try await securityResult(reader, version: version) }
        case .vncAuthentication:
            onEvent(.authenticating(security))
            // Le défi est lu avant de constater l'absence de mot de passe : la connexion est
            // alors abandonnée proprement et l'application demande le mot de passe.
            let challenge = try await reader.bytes(16)
            guard let password = credentials.password, !password.isEmpty else { throw RFBError.passwordRequired(security) }
            transport.send(try RFBAuthentication.vncResponse(challenge: challenge, password: password))
            try await securityResult(reader, version: version)
        case .appleRemoteDesktop:
            onEvent(.authenticating(security))
            let generator = try await reader.bytes(2)
            let keyLength = Int(try await reader.u16())
            guard keyLength > 0, keyLength <= 1024 else { throw RFBError.protocolViolation("clé ARD de \(keyLength) octets") }
            let prime = try await reader.bytes(keyLength)
            let serverKey = try await reader.bytes(keyLength)
            guard !credentials.username.isEmpty else { throw RFBError.usernameRequired }
            guard let password = credentials.password, !password.isEmpty else { throw RFBError.passwordRequired(security) }
            let parameters = RFBAuthentication.ARDParameters(generator: RFBBigUInt(bigEndian: generator), keyLength: keyLength,
                                                             prime: RFBBigUInt(bigEndian: prime),
                                                             serverPublicKey: RFBBigUInt(bigEndian: serverKey))
            let response = try RFBAuthentication.ardResponse(parameters, username: credentials.username, password: password,
                                                             privateKey: ardPrivateKey ?? RFBAuthentication.randomBytes(min(keyLength, 64)),
                                                             filler: ardFiller ?? RFBAuthentication.randomBytes(128))
            transport.send(response)
            try await securityResult(reader, version: version)
        case .invalid:
            throw RFBError.unsupportedSecurity([0])
        }

        transport.send([options.shared ? 1 : 0])
        let width = Int(try await reader.u16()), height = Int(try await reader.u16())
        let serverFormat = try RFBPixelFormat(bytes: try await reader.bytes(16))
        let name = try await reader.string(limit: 64 * 1024)
        guard width <= 16_384, height <= 16_384 else { throw RFBError.protocolViolation("écran de \(width) × \(height)") }
        let decodedName = String(bytes: name, encoding: .utf8) ?? RFBText.string(latin1: name)
        return RFBServerInfo(serverVersion: serverVersion, version: version, security: security, name: decodedName,
                             width: width, height: height, serverFormat: serverFormat)
    }

    private func securityResult(_ reader: RFBReader, version: RFBVersion) async throws {
        let result = try await reader.u32()
        guard result != 0 else { return }
        // La raison n'est envoyée qu'à partir de 3.8.
        let reason = version == .v3_8 ? RFBText.string(latin1: try await reader.string()) : ""
        throw RFBError.authenticationFailed(reason)
    }

    /// Format demandé, encodages, première image complète, puis boucle des messages du serveur.
    private func loop(_ reader: RFBReader, info: RFBServerInfo) async throws {
        var framebuffer = RFBFramebuffer(width: info.width, height: info.height)
        // Clavier, souris et presse-papiers acceptés à partir d'ici seulement (jamais pendant la
        // poignée de main, ce qui la corromprait).
        lock.withLock {
            size = (info.width, info.height)
            running = true
        }
        let decoder = RFBDecoder(format: options.pixelFormat)
        transport.send(RFBClientMessage.setPixelFormat(options.pixelFormat))
        transport.send(RFBClientMessage.setEncodings(options.encodings))
        transport.send(RFBClientMessage.framebufferUpdateRequest(incremental: false, framebuffer.bounds))
        onEvent(.connected(info))
        onEvent(.pixelFormat(options.pixelFormat))

        while true {
            let type = try await reader.u8()
            switch type {
            case 0:
                let start = Date()
                let before = reader.totalBytes
                try await reader.skip(1)
                var count = Int(try await reader.u16())
                var dirty = RFBRect.zero
                var encodings: Set<String> = []
                var rectangles = 0
                while count > 0 {
                    count -= 1
                    let rect = RFBRect(x: Int(try await reader.u16()), y: Int(try await reader.u16()),
                                       width: Int(try await reader.u16()), height: Int(try await reader.u16()))
                    let encoding = try await reader.s32()
                    let outcome = try await decoder.decode(encoding: encoding, rect: rect, reader: reader, into: &framebuffer)
                    rectangles += 1
                    switch outcome {
                    case .pixels:
                        encodings.insert(RFBEncoding.name(encoding))
                        dirty = dirty.union(rect)
                    case .resized:
                        dirty = framebuffer.bounds
                        let resized = (framebuffer.width, framebuffer.height)
                        lock.withLock { size = resized }
                    case .cursor(let cursor):
                        onEvent(.cursor(cursor))
                    case .lastRect:
                        count = 0
                    }
                }
                let stats = RFBUpdateStats(bytes: reader.totalBytes - before + 1, rectangles: rectangles, encodings: encodings,
                                           duration: Date().timeIntervalSince(start), dirty: dirty)
                onEvent(.framebuffer(framebuffer, stats))
                requestNext(decoder: decoder, bounds: framebuffer.bounds)
            case 1:
                // SetColourMapEntries : ignoré (couleurs vraies demandées), mais lu en entier.
                try await reader.skip(3)
                let colours = Int(try await reader.u16())
                try await reader.skip(colours * 6)
            case 2:
                onEvent(.bell)
            case 3:
                try await reader.skip(3)
                let text = try await reader.string(limit: 16 << 20)
                onEvent(.clipboard(RFBText.string(latin1: text)))
            default:
                throw RFBError.protocolViolation("message \(type) inconnu")
            }
        }
    }

    /// Demande la mise à jour suivante ; un changement de format en attente part d'abord, suivi
    /// d'une demande complète (aucune mise à jour n'est alors en route).
    private func requestNext(decoder: RFBDecoder, bounds: RFBRect) {
        lock.lock()
        let format = pendingFormat
        pendingFormat = nil
        var full = pendingFullRefresh
        pendingFullRefresh = false
        lock.unlock()
        if let format, format != decoder.format, format.isSupported {
            transport.send(RFBClientMessage.setPixelFormat(format))
            decoder.format = format
            full = true
            onEvent(.pixelFormat(format))
        }
        transport.send(RFBClientMessage.framebufferUpdateRequest(incremental: !full, bounds))
    }
}
