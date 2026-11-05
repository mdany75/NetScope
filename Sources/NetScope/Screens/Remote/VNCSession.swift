import AppKit
import Foundation
import NetScopeCore
import SwiftUI

// Note 57 : session VNC intégrée (moteur RFB de NetScopeCore/VNC). Une session par connexion,
// gardée par `VNCSessionStore` tant qu'elle n'est pas fermée. Mot de passe VNC (ou du compte macOS)
// au Trousseau seulement (service com.danymenard.netscope.vnc, un compte par connexion), jamais
// affiché ni écrit ailleurs. En démonstration et pendant les captures : bureau dessiné
// (DevTools/VNCDemo.swift), aucun réseau, aucun Trousseau.
//
// Point d'entrée pour les onglets de session : `VNCSessionView(connection:)` affiche (et ouvre au
// besoin) la session de cette connexion ; `VNCSessionStore.shared.open(_:)` l'ouvre sans l'afficher,
// `close(_:)` la ferme. `RemoteSessionKind.vnc` désigne ce type de session.

/// Types de sessions intégrées d'Accès distant (le terminal arrive avec les onglets de session).
enum RemoteSessionKind: String {
    /// Client VNC intégré : `VNCSessionView(connection:)`.
    case vnc
}

/// Mise à l'échelle de l'image (croquis : « Ajuster » ou « 100 % »).
enum VNCScaleMode: String, CaseIterable, Identifiable {
    case fit, actual

    var id: String { rawValue }

    var label: String { self == .fit ? "Ajuster" : "100\u{00A0}%" }

    var footer: String { self == .fit ? "Mis à l’échelle pour la fenêtre" : "Taille réelle · défilement aux bords" }

    init(_ scale: RemoteVNCScale) {
        self = scale == .actual ? .actual : .fit
    }
}

/// Mots de passe VNC au Trousseau.
@MainActor
enum VNCPasswordStore {
    nonisolated static let keychain = UpdKeychain(service: "com.danymenard.netscope.vnc")

    static func password(for id: UUID) -> String? {
        guard !RegEnvironment.isSandboxed else { return nil }
        return keychain.string(for: id.uuidString)
    }

    static func hasPassword(_ id: UUID) -> Bool {
        if RegEnvironment.isSandboxed { return VNCDemo.savedPassword }
        return password(for: id) != nil
    }

    static func setPassword(_ value: String?, for id: UUID) throws {
        guard !RegEnvironment.isSandboxed else { return }
        try keychain.set(value, for: id.uuidString)
    }
}

/// Image et statistiques reçues par la boucle de réception, reprises par le fil principal
/// (une seule reprise en attente : les images intermédiaires sont sautées si l'affichage traîne).
final class VNCFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private var size = (width: 0, height: 0)
    private var stats: [RFBUpdateStats] = []
    private var scheduled = false

    /// Dépose une image ; renvoie true s'il faut programmer une reprise.
    func post(_ image: CGImage?, width: Int, height: Int, stats: RFBUpdateStats) -> Bool {
        lock.withLock {
            self.image = image
            size = (width, height)
            self.stats.append(stats)
            if scheduled { return false }
            scheduled = true
            return true
        }
    }

    func take() -> (CGImage?, Int, Int, [RFBUpdateStats]) {
        lock.withLock {
            defer {
                image = nil
                stats = []
                scheduled = false
            }
            return (image, size.width, size.height, stats)
        }
    }
}

/// Une session VNC ouverte.
@MainActor
final class VNCSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting
        case authenticating(String)
        case connected
        /// Identifiants à saisir : message, nom d'utilisateur nécessaire (compte macOS).
        case needsCredentials(String, needsUsername: Bool)
        case failed(String)
        case closed
    }

    nonisolated let id: UUID
    @Published private(set) var connection: RemoteConnection
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var image: CGImage?
    @Published private(set) var framebufferWidth = 0
    @Published private(set) var framebufferHeight = 0
    @Published private(set) var desktopName = ""
    @Published private(set) var serverVersion = ""
    @Published private(set) var security: RFBSecurityType?
    @Published private(set) var pixelFormat: RFBPixelFormat = .rgb888
    @Published private(set) var encodings: [String] = []
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var cursor: NSCursor?
    @Published var scale: VNCScaleMode
    @Published var viewOnly = false
    @Published var shareClipboard = true
    @Published var toast: String?
    /// Affichée dans Accès distant (sinon la session continue en arrière-plan).
    @Published var isVisible = true {
        didSet { if isVisible != oldValue { VNCSessionStore.shared.objectWillChange.send() } }
    }
    @Published private(set) var isFullScreen = false
    @Published var quality: RFBQuality {
        didSet {
            guard quality != oldValue else { return }
            if let format = governor.setQuality(quality) { client?.setPixelFormat(format) }
        }
    }

    let isDemo: Bool
    private var client: RFBClient?
    private var task: Task<Void, Never>?
    private let mailbox = VNCFrameMailbox()
    private var governor: RFBQualityGovernor
    /// Identifiants saisis pour cette session seulement (sans « Mémoriser ») ; en mémoire.
    private var sessionPassword: String?
    private var sessionUsername: String?
    private var frameTimes: [Date] = []
    private var byteSamples: [(Date, Int)] = []
    private var lastPasteboardChange = NSPasteboard.general.changeCount
    private var generation = 0

    init(connection: RemoteConnection, demo: Bool = RegEnvironment.isSandboxed) {
        id = connection.id
        self.connection = connection
        isDemo = demo
        scale = VNCScaleMode(connection.display.vncScale)
        quality = .adaptive
        governor = RFBQualityGovernor(quality: .adaptive)
    }

    // MARK: Textes

    var address: String {
        let user = sessionUsername ?? connection.username
        return (user.isEmpty ? "" : "\(user) @ ") + "\(connection.host):\(connection.port)"
    }

    /// « Connecté », « Connexion… », « Échec »… pour la puce d'état.
    var phaseLabel: (text: String, tone: Tone) {
        switch phase {
        case .connecting: return ("Connexion…", .neutral)
        case .authenticating: return ("Authentification…", .neutral)
        case .connected: return ("Connecté", .success)
        case .needsCredentials: return ("Identifiants requis", .warning)
        case .failed: return ("Échec", .critical)
        case .closed: return ("Déconnecté", .neutral)
        }
    }

    /// Ligne d'état du bas (croquis : « RFB 3.8 · haute qualité (sans perte) · 2560×1440 · 30 i/s »).
    var statusLine: String {
        guard phase == .connected else {
            switch phase {
            case .authenticating(let method): return "Authentification\u{00A0}: \(method)…"
            case .connecting: return "Connexion à \(connection.host):\(connection.port)…"
            default: return "Aucune image"
            }
        }
        var parts = ["RFB \(serverVersion)"]
        // Encodage principal de la dernière image (CopyRect accompagne presque toujours l'autre).
        let encoding = encodings.first { $0 != "CopyRect" } ?? encodings.first
        let detail = ([encoding].compactMap { $0 } + [pixelFormat.label]).joined(separator: ", ")
        switch quality {
        case .high: parts.append("haute qualité (sans perte, \(detail))")
        case .adaptive: parts.append("qualité adaptative (\(detail)\(pixelFormat.bitsPerPixel < 32 ? ", lien lent" : ""))")
        }
        parts.append("\(framebufferWidth)\u{00A0}×\u{00A0}\(framebufferHeight)")
        parts.append(String(format: "%.0f\u{00A0}i/s", framesPerSecond))
        if bytesPerSecond > 0 { parts.append(Self.rate(bytesPerSecond)) }
        return parts.joined(separator: " · ")
    }

    static func rate(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1f\u{00A0}Mo/s", value / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        return String(format: "%.0f\u{00A0}ko/s", value / 1_000)
    }

    var securityChip: (text: String, tone: Tone, help: String) {
        let help = "VNC ne chiffre ni l’image ni le clavier\u{00A0}: réservez-le au réseau local, à un VPN ou à un tunnel SSH."
        switch security {
        case .appleRemoteDesktop?: return ("Identifiants chiffrés (ARD) · image en clair", .warning, help)
        default: return ("Non chiffré", .warning, help)
        }
    }

    // MARK: Cycle de vie

    func start() {
        task?.cancel()
        client?.close()
        client = nil
        generation += 1
        let generation = self.generation
        phase = .connecting
        if isDemo {
            startDemo()
            return
        }
        let credentials = RFBCredentials(username: sessionUsername ?? connection.username,
                                         password: sessionPassword ?? VNCPasswordStore.password(for: connection.id))
        let host = connection.host, port = connection.port
        let options = RFBOptions(pixelFormat: governor.format)
        let mailbox = self.mailbox
        task = Task { [weak self] in
            let transport = RFBNetworkTransport(host: host, port: port)
            do {
                try await transport.open()
            } catch {
                self?.finish(error as? RFBError ?? .network(error.localizedDescription), generation: generation)
                return
            }
            let client = RFBClient(transport: transport, credentials: credentials, options: options) { event in
                if case .framebuffer(let framebuffer, let stats) = event {
                    let image = VNCSession.makeImage(framebuffer)
                    if mailbox.post(image, width: framebuffer.width, height: framebuffer.height, stats: stats) {
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.drainFrames(generation: generation) } }
                    }
                    return
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, generation: generation) } }
            }
            guard let self, !Task.isCancelled, self.generation == generation else {
                transport.close()
                return
            }
            self.client = client
            await client.run()
        }
    }

    /// Ferme la session (bouton « Déconnecter »).
    func disconnect() {
        generation += 1
        task?.cancel()
        client?.close()
        client = nil
        phase = .closed
        cursor = nil
        framesPerSecond = 0
        bytesPerSecond = 0
    }

    func reconnect() {
        start()
    }

    /// Identifiants saisis dans la session ; `remember` : mot de passe au Trousseau.
    func submitCredentials(username: String?, password: String, remember: Bool) {
        if let username, !username.trimmingCharacters(in: .whitespaces).isEmpty {
            sessionUsername = username.trimmingCharacters(in: .whitespaces)
            if remember { RemoteModel.shared.setTransferUsername(sessionUsername ?? "", for: connection.id) }
        }
        sessionPassword = password
        if remember {
            do {
                try VNCPasswordStore.setPassword(password, for: connection.id)
            } catch {
                toast = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        if isDemo { VNCDemo.savedPassword = true }
        start()
    }

    /// Oublie le mot de passe enregistré pour cette connexion.
    func forgetPassword() {
        sessionPassword = nil
        try? VNCPasswordStore.setPassword(nil, for: connection.id)
        if isDemo { VNCDemo.savedPassword = false }
        toast = "Mot de passe retiré du Trousseau."
        objectWillChange.send()
    }

    var hasSavedPassword: Bool { VNCPasswordStore.hasPassword(connection.id) }

    // MARK: Événements du moteur

    private func handle(_ event: RFBEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .connecting:
            phase = .connecting
        case .authenticating(let type):
            phase = .authenticating(type.label)
        case .connected(let info):
            phase = .connected
            desktopName = info.name
            serverVersion = info.version.rawValue
            security = info.security
            framebufferWidth = info.width
            framebufferHeight = info.height
            // Un mot de passe accepté reste en mémoire pour les reconnexions de cette session.
        case .framebuffer:
            break
        case .cursor(let remote):
            cursor = Self.makeCursor(remote)
        case .bell:
            NSSound.beep()
        case .clipboard(let text):
            guard shareClipboard, !viewOnly else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lastPasteboardChange = pasteboard.changeCount
        case .pixelFormat(let format):
            pixelFormat = format
        case .closed(let error):
            finish(error, generation: generation)
        }
    }

    private func finish(_ error: RFBError?, generation: Int) {
        guard generation == self.generation else { return }
        client = nil
        cursor = nil
        framesPerSecond = 0
        bytesPerSecond = 0
        guard let error else {
            phase = .closed
            return
        }
        switch error {
        case .passwordRequired(let type):
            phase = .needsCredentials(type == .appleRemoteDesktop ? "Ce Mac demande le mot de passe du compte « \(sessionUsername ?? connection.username) »."
                                                                   : "Le serveur VNC demande un mot de passe.",
                                      needsUsername: false)
        case .usernameRequired:
            phase = .needsCredentials(error.errorDescription ?? "", needsUsername: true)
        case .authenticationFailed:
            sessionPassword = nil
            phase = .needsCredentials(error.errorDescription ?? "", needsUsername: security == .appleRemoteDesktop)
        default:
            phase = .failed(error.errorDescription ?? "Erreur VNC.")
        }
    }

    private func drainFrames(generation: Int) {
        let (image, width, height, stats) = mailbox.take()
        guard generation == self.generation else { return }
        if let image { self.image = image }
        framebufferWidth = width
        framebufferHeight = height
        let now = Date()
        for stat in stats {
            frameTimes.append(now)
            byteSamples.append((now, stat.bytes))
            if let format = governor.record(bytes: stat.bytes, duration: stat.duration, now: now) {
                client?.setPixelFormat(format)
            }
        }
        if let last = stats.last, !last.encodings.isEmpty {
            encodings = RFBEncoding.preferred.map(RFBEncoding.name).filter { last.encodings.contains($0) }
        }
        frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
        byteSamples.removeAll { now.timeIntervalSince($0.0) > 2 }
        framesPerSecond = Double(frameTimes.count) / 2
        bytesPerSecond = Double(byteSamples.reduce(0) { $0 + $1.1 }) / 2
    }

    // MARK: Entrées

    private var acceptsInput: Bool { phase == .connected && !viewOnly }

    func key(_ keysym: UInt32, down: Bool) {
        guard acceptsInput else { return }
        client?.sendKey(keysym, down: down)
    }

    func pointer(x: Int, y: Int, buttons: RFBButtons) {
        guard acceptsInput else { return }
        client?.sendPointer(x: x, y: y, buttons: buttons)
    }

    func sendCtrlAltDelete() {
        guard acceptsInput else { return }
        client?.sendChord(RFBKeysym.ctrlAltDelete)
        if isDemo { toast = "Ctrl-Alt-Suppr envoyé à \(connection.name)." }
    }

    /// Envoie le texte du presse-papiers du Mac (bouton du croquis).
    func sendClipboard() {
        guard acceptsInput else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            toast = "Le presse-papiers du Mac ne contient pas de texte."
            return
        }
        client?.sendClipboard(text)
        lastPasteboardChange = NSPasteboard.general.changeCount
        toast = "Presse-papiers envoyé à \(connection.name)."
    }

    /// Presse-papiers partagé : le texte copié sur le Mac part au premier clic dans la session.
    func syncClipboardIfChanged() {
        guard shareClipboard, acceptsInput else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pasteboard.changeCount
        if let text = pasteboard.string(forType: .string), !text.isEmpty { client?.sendClipboard(text) }
    }

    func refresh() {
        client?.requestFullRefresh()
    }

    func setFullScreen(_ value: Bool) {
        isFullScreen = value
    }

    // MARK: Démonstration

    /// Captures : la session attend le mot de passe (aucune image).
    func showDemoCredentialsPrompt() {
        guard isDemo else { return }
        image = nil
        phase = .needsCredentials("Le serveur VNC demande un mot de passe.", needsUsername: false)
    }

    private func startDemo() {
        let desktop = VNCDemo.desktop(for: connection)
        image = Self.makeImage(desktop.framebuffer)
        framebufferWidth = desktop.framebuffer.width
        framebufferHeight = desktop.framebuffer.height
        desktopName = desktop.name
        serverVersion = "3.8"
        security = desktop.security
        pixelFormat = .rgb888
        encodings = ["CopyRect", "ZRLE"]
        framesPerSecond = 30
        bytesPerSecond = 1_240_000
        phase = .connected
    }

    // MARK: Images

    /// Tampon 0xAARRGGBB → CGImage (32 bits, petit-boutiste, alpha en premier).
    nonisolated static func makeImage(_ framebuffer: RFBFramebuffer) -> CGImage? {
        guard framebuffer.width > 0, framebuffer.height > 0 else { return nil }
        let data = framebuffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: framebuffer.width, height: framebuffer.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: framebuffer.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func makeCursor(_ cursor: RFBCursor) -> NSCursor? {
        guard !cursor.isHidden else { return Self.hiddenCursor }
        // Pixels hors du masque à alpha 0 : prémultipliés, ils deviennent transparents.
        let premultiplied = cursor.pixels.map { $0 >> 24 == 0 ? 0 : $0 }
        guard let image = makeImage(RFBFramebuffer(width: cursor.width, height: cursor.height, pixels: premultiplied)) else { return nil }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: cursor.width, height: cursor.height))
        return NSCursor(image: nsImage, hotSpot: NSPoint(x: cursor.hotspotX, y: cursor.hotspotY))
    }

    static let hiddenCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()
}

/// Sessions VNC ouvertes, une par connexion.
@MainActor
final class VNCSessionStore: ObservableObject {
    static let shared = VNCSessionStore()

    @Published private(set) var sessions: [UUID: VNCSession] = [:]

    private init() {}

    func session(for id: UUID?) -> VNCSession? {
        id.flatMap { sessions[$0] }
    }

    /// Session de la connexion choisie, si elle est affichée.
    func displayed(for id: UUID?) -> VNCSession? {
        guard let session = session(for: id), session.isVisible else { return nil }
        return session
    }

    /// Ouvre la session (ou y revient) ; la relance si elle avait échoué ou été fermée.
    @discardableResult
    func open(_ connection: RemoteConnection) -> VNCSession {
        if let existing = sessions[connection.id] {
            existing.isVisible = true
            switch existing.phase {
            case .failed, .closed: existing.start()
            default: break
            }
            return existing
        }
        let session = VNCSession(connection: connection)
        sessions[connection.id] = session
        session.start()
        return session
    }

    func close(_ id: UUID) {
        sessions[id]?.disconnect()
        sessions[id] = nil
    }
}
