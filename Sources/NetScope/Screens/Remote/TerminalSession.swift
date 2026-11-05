import AppKit
import Foundation
import NetScopeCore
import SwiftUI

// Note 57 : une session de terminal (SSH, Telnet ou console série) dans un onglet d'Accès
// distant. L'émulateur (NetScopeCore) reçoit la sortie de la liaison ; la vue AppKit
// (TerminalTextView) le dessine et envoie la saisie. En démonstration et pendant les captures, la
// liaison est simulée (DevTools/TerminalDemo.swift) : aucun réseau, aucun port série.

/// Octets reçus sur un fil quelconque, remis en un seul lot au fil principal.
final class TerminalInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var events: [TerminalTransportEvent] = []
    private var scheduled = false

    /// Ajoute un événement ; vrai s'il faut programmer une remise au fil principal.
    func push(_ event: TerminalTransportEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .data(let data) = event {
            bytes += data
        } else {
            if !bytes.isEmpty {
                events.append(.data(bytes))
                bytes.removeAll()
            }
            events.append(event)
        }
        if scheduled { return false }
        scheduled = true
        return true
    }

    func take() -> [TerminalTransportEvent] {
        lock.lock()
        defer { lock.unlock() }
        var result = events
        if !bytes.isEmpty { result.append(.data(bytes)) }
        events.removeAll()
        bytes.removeAll()
        scheduled = false
        return result
    }
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum Kind: Equatable {
        case ssh, telnet, serial

        init?(_ proto: RemoteProtocol) {
            switch proto {
            case .ssh: self = .ssh
            case .telnet: self = .telnet
            case .serie: self = .serial
            default: return nil
            }
        }
    }

    enum Phase: Equatable {
        /// Pas encore ouverte (port série fermé).
        case idle
        case connecting
        case connected
        /// Terminée ; message expliqué, ou nil pour une fin normale.
        case ended(String?)
    }

    let id = UUID()
    let kind: Kind
    @Published private(set) var connection: RemoteConnection
    let emulator: TerminalEmulator
    @Published private(set) var phase: Phase = .idle
    /// Titre donné par le serveur (OSC), affiché dans l'onglet s'il n'est pas vide.
    @Published private(set) var remoteTitle = ""
    @Published private(set) var columns: Int
    @Published private(set) var rows: Int
    @Published private(set) var connectedAt: Date?
    @Published var encoding: TerminalEncoding = .utf8 {
        didSet { emulator.encoding = encoding }
    }
    /// Bandeau tiré de la sortie de ssh (empreinte à accepter, clé changée, refus).
    @Published private(set) var finding: SSHPromptDetector.Finding?
    @Published private(set) var logURL: URL?
    @Published var logEnabled: Bool {
        didSet { logEnabled ? openLog() : closeLog() }
    }
    // Console série
    /// Note 78 : horodatage des lignes reçues (« [10:41:07.123] »), retenu entre les sessions.
    @Published var timestamps: Bool {
        didSet {
            stamper.reset()
            if kind == .serial { TerminalPreferences.shared.serialTimestamps = timestamps }
        }
    }
    @Published var serialPath: String
    @Published var serialSettings: SerialSettings
    // Recherche (⌘F)
    @Published var searchVisible = false
    @Published var searchText = "" {
        didSet { updateSearch() }
    }
    @Published private(set) var matches: [TerminalMatch] = []
    @Published private(set) var matchIndex = 0
    /// Message bref sous la barre de l'onglet (« Sortie copiée ») ; `noticeIsError` : une erreur,
    /// affichée en avertissement et gardée jusqu'à sa fermeture.
    @Published var notice: String?
    @Published private(set) var noticeIsError = false

    /// Redessin de la vue après chaque lot de sortie (posé par la vue).
    var onOutput: (() -> Void)?
    /// Défilement vers un résultat de recherche (posé par la vue).
    var onReveal: ((TerminalMatch) -> Void)?

    private var transport: TerminalTransport?
    private var inbox = TerminalInbox()
    private var logFilter = TerminalLogFilter()
    private var detectFilter = TerminalLogFilter()
    private var recentText = ""
    private var logHandle: FileHandle?
    private var askpassFlag: URL?
    private var stamper = TerminalLineTimestamper()
    /// Horloge de l'horodatage (fixe en démonstration).
    private var clock: () -> Date = Date.init
    private var secretChannel: SSHSecretChannel?
    private let demo: Bool
    /// Liaison de démonstration (captures, --demo).
    var demoTransport: (() -> TerminalTransport)?

    init(connection: RemoteConnection, columns: Int = 100, rows: Int = 30) {
        kind = Kind(connection.proto) ?? .ssh
        self.connection = connection
        self.columns = columns
        self.rows = rows
        emulator = TerminalEmulator(columns: columns, rows: rows)
        demo = RegEnvironment.isSandboxed
        logEnabled = TerminalPreferences.shared.logSessions
        serialPath = connection.host
        serialSettings = TerminalSerialMemory.settings(for: connection)
        timestamps = kind == .serial && TerminalPreferences.shared.serialTimestamps
        if demo {
            // Démonstration : heures fixes, 0,137 s entre deux lignes (démarrage d'un switch).
            var tick = 0.0
            let base = Calendar.current.date(bySettingHour: 10, minute: 29, second: 14, of: Date()) ?? Date()
            clock = {
                defer { tick += 0.137 }
                return base.addingTimeInterval(tick)
            }
        }
    }

    // MARK: État

    var isActive: Bool { phase == .connecting || phase == .connected }

    var tabLabel: String {
        // Le badge « SÉRIE » dit déjà le type : deux consoles ouvertes gardent des noms distincts.
        connection.name
    }

    /// « netadmin@10.182.122.2:22 », « cu.usbserial-A10K ».
    var addressLabel: String {
        switch kind {
        case .serial: return SerialPortInfo(path: serialPath).name
        case .ssh, .telnet:
            let user = connection.username.isEmpty ? "" : connection.username + "@"
            let host = connection.host.contains(":") ? "[\(connection.host)]" : connection.host
            return "\(user)\(host):\(connection.port)"
        }
    }

    // MARK: Ouverture et fermeture

    func start() {
        guard !isActive else { return }
        finding = nil
        recentText = ""
        detectFilter = TerminalLogFilter()
        phase = .connecting
        if logEnabled { openLog() }
        let transport: TerminalTransport
        do {
            transport = try makeTransport()
        } catch {
            phase = .ended((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        self.transport = transport
        // Une boîte par liaison : les derniers événements d'une liaison remplacée (reconnexion,
        // port rouvert avec d'autres réglages) sont ignorés.
        let inbox = TerminalInbox()
        self.inbox = inbox
        transport.start { [weak self] event in
            guard inbox.push(event) else { return }
            DispatchQueue.main.async { self?.drainInbox(inbox) }
        }
    }

    private func makeTransport() throws -> TerminalTransport {
        if demo, let demoTransport { return demoTransport() }
        if demo { return TerminalDemoTransport(lines: []) }
        switch kind {
        case .ssh:
            guard FileManager.default.isExecutableFile(atPath: SSHTerminalCommand.sshPath) else {
                throw PTYProcess.Failure.spawn(SSHTerminalCommand.sshPath, ENOENT)
            }
            let askpass = try SSHTerminalCommand.writeAskpass()
            // Fichier témoin d'une liaison remplacée (reconnexion) : supprimé avant d'en créer un autre.
            removeFlag()
            let flag = SSHTerminalCommand.controlDirectory.appendingPathComponent("drapeau-" + UUID().uuidString)
            askpassFlag = flag
            let secret = RemoteSessionStore.shared.password(for: connection.id)
            // Secret par un tube à usage unique, jamais dans l'environnement de ssh.
            let channel = try secret.flatMap { $0.isEmpty ? nil : try SSHSecretChannel(directory: SSHTerminalCommand.controlDirectory, secret: $0) }
            secretChannel = channel
            // Note 78 (défaut corrigé) : l'invite que ssh nommera tient compte de User et HostName de
            // ~/.ssh/config ; sans cela, le mot de passe du Trousseau n'était pas remis quand le nom
            // venait du fichier.
            let expect = SSHConfigCache.config.expectedPrompt(user: connection.username, host: connection.host)
            let environment = SSHTerminalCommand.environment(base: ProcessInfo.processInfo.environment, askpass: askpass.path,
                                                              secretPipe: channel?.path, expect: expect, flag: flag.path)
            // Note 66 : saut par bastion (-J) et clé (-i) de la connexion.
            let arguments = SSHTerminalCommand.arguments(user: connection.username, host: connection.host, port: connection.port,
                                                         keyPath: connection.identityFile.isEmpty ? nil : connection.identityFile,
                                                         jump: connection.proxyJump)
            info("NetScope › " + SSHTerminalCommand.displayCommand(user: connection.username, host: connection.host, port: connection.port,
                                                                    jump: connection.proxyJump, keyPath: connection.identityFile)
                 + (secret == nil ? "" : "  (mot de passe du Trousseau)"))
            return PTYProcess(executable: SSHTerminalCommand.sshPath, arguments: arguments, environment: environment,
                              columns: columns, rows: rows)
        case .telnet:
            info("NetScope › Telnet vers \(connection.host):\(connection.port) (non chiffré)…")
            return TelnetTransport(host: connection.host, port: connection.port, columns: columns, rows: rows)
        case .serial:
            return SerialTransport(path: serialPath, settings: serialSettings)
        }
    }

    /// Ferme la liaison (l'onglet reste ouvert, « Reconnecter » la rouvre).
    func disconnect() {
        transport?.close()
    }

    func reconnect() {
        if isActive {
            transport?.close()
            transport = nil
            phase = .ended(nil)
        }
        info("")
        start()
    }

    /// Fermeture de l'onglet.
    func shutdown() {
        transport?.close()
        transport = nil
        closeLog()
        removeFlag()
        onOutput = nil
        onReveal = nil
    }

    private func drainInbox(_ source: TerminalInbox) {
        let events = source.take()
        guard source === inbox else { return }
        for event in events {
            switch event {
            case .connected:
                phase = .connected
                connectedAt = Date()
                if kind == .serial {
                    info("[Port \(serialPath) ouvert à \(serialSettings.summary), flux \(serialSettings.flowControl.shortLabel)]")
                    TerminalSerialMemory.remember(serialSettings, for: connection.id)
                }
            case .data(let bytes):
                receive(bytes)
            case .closed(let message):
                transport = nil
                removeFlag()
                phase = .ended(message)
                let text = message ?? (kind == .serial ? "Port \(serialPath) fermé." : "Session terminée.")
                let action = kind == .serial ? "« Ouvrir le port »" : "« Reconnecter »"
                info("[\(text) Entrée ou \(action) pour rouvrir.]", tone: message == nil ? .muted : .warning)
                // Session finie : une question d'empreinte restée sans réponse n'a plus d'objet.
                if kind == .ssh {
                    let found = SSHPromptDetector.scan(recentText)
                    if case .unknownHost = found { finding = nil } else { finding = found }
                }
            }
        }
        onOutput?()
    }

    private func receive(_ incoming: [UInt8]) {
        // Note 78 : horodatage des lignes de la console série (option de l'onglet).
        let bytes = kind == .serial && timestamps ? stamper.feed(incoming, now: clock) : incoming
        emulator.feed(bytes)
        let responses = emulator.takeResponses()
        if !responses.isEmpty { transport?.send(responses) }
        if emulator.title != remoteTitle { remoteTitle = emulator.title }
        if let logHandle {
            let text = logFilter.feed(bytes)
            if !text.isEmpty { logHandle.write(Data(text.utf8)) }
        }
        if kind == .ssh {
            recentText += detectFilter.feed(bytes)
            if recentText.count > 4_000 { recentText = String(recentText.suffix(3_000)) }
            let found = SSHPromptDetector.scan(recentText + detectFilter.pendingLine)
            if found != finding { finding = found }
        }
        if searchVisible, !searchText.isEmpty { scheduleSearch() }
    }

    /// Recherche relancée au plus toutes les 250 ms pendant un flux de sortie rapide.
    private var searchScheduled = false

    private func scheduleSearch() {
        guard !searchScheduled else { return }
        searchScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.searchScheduled = false
            if self.searchVisible, !self.searchText.isEmpty { self.updateSearch(keepIndex: true) }
        }
    }

    /// Ligne d'information de NetScope dans le terminal (grisée), jamais envoyée au serveur.
    enum InfoTone { case muted, warning }

    func info(_ text: String, tone: InfoTone = .muted) {
        let color = tone == .muted ? "\u{1B}[2m" : "\u{1B}[33m"
        let prefix = emulator.cursorColumn == 0 ? "" : "\r\n"
        emulator.feed(prefix + (text.isEmpty ? "" : color + text + "\u{1B}[0m") + "\r\n")
        onOutput?()
    }

    // MARK: Saisie

    /// Octets saisis au clavier (ou collés).
    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if case .ended = phase {
            // Entrée sur une session terminée : elle est rouverte.
            if bytes == [0x0D] { reconnect() }
            return
        }
        if phase == .idle, kind == .serial {
            if bytes == [0x0D] { start() }
            return
        }
        guard let transport, phase == .connected else { return }
        var out = bytes
        if kind == .serial, bytes == [0x0D] { out = serialSettings.enterBytes }
        if transport.wantsLocalEcho {
            var echo: [UInt8] = []
            for byte in bytes {
                switch byte {
                case 0x0D: echo += [0x0D, 0x0A]
                case 0x7F, 0x08: echo += [0x08, 0x20, 0x08]
                case 0x20...0x7E, 0x80...0xFF: echo.append(byte)
                default: break
                }
            }
            emulator.feed(echo)
            onOutput?()
        }
        transport.send(out)
    }

    func sendText(_ text: String) {
        send(encoding.encode(text))
    }

    func paste(_ text: String) {
        send(TerminalKeyEncoder.paste(text, bracketed: emulator.bracketedPaste, encoding: encoding))
    }

    func sendBreak() {
        transport?.sendBreak()
        info("[Break envoyé]", tone: .warning)
    }

    /// Réponse au bandeau « serveur inconnu ».
    func answerHostKey(accept: Bool) {
        finding = nil
        send(Array((accept ? "yes" : "no").utf8) + [0x0D])
    }

    /// Mot de passe du Trousseau tapé dans la session (Telnet, console série), sur demande.
    func typeSavedPassword() {
        guard let secret = RemoteSessionStore.shared.password(for: connection.id) else { return }
        send(encoding.encode(secret) + [0x0D])
    }

    func resize(columns: Int, rows: Int) {
        guard columns != self.columns || rows != self.rows, columns > 1, rows > 0 else { return }
        self.columns = columns
        self.rows = rows
        emulator.resize(columns: columns, rows: rows)
        transport?.resize(columns: columns, rows: rows)
    }

    // MARK: Commandes de l'onglet

    func clear() {
        emulator.clearScrollback()
        updateSearch()
        onOutput?()
    }

    /// Tout le texte (historique et écran) : « Copier la sortie », « Enregistrer le journal ».
    var transcript: String { emulator.allText }

    func copyOutput() {
        let text = transcript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        show("Sortie copiée dans le presse-papiers (\(lines) ligne\(lines > 1 ? "s" : "")).")
    }

    /// « Enregistrer le journal… » : texte de l'historique et de l'écran dans un fichier .log.
    func saveTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.logFileName(for: connection, date: Date())
        panel.allowedContentTypes = [.log]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (transcript + "\n").write(to: url, atomically: true, encoding: .utf8)
            show("Journal enregistré\u{00A0}: \(url.lastPathComponent).")
        } catch {
            show("Enregistrement impossible\u{00A0}: \(error.localizedDescription)", error: true)
        }
    }

    func show(_ text: String, error: Bool = false) {
        noticeIsError = error
        notice = text
    }

    // MARK: Recherche

    func updateSearch(keepIndex: Bool = false) {
        let found = searchText.isEmpty ? [] : emulator.search(searchText)
        let previous = matchIndex
        matches = found
        if found.isEmpty {
            matchIndex = 0
        } else if !keepIndex || previous >= found.count {
            matchIndex = found.count - 1
            onReveal?(found[matchIndex])
        }
        onOutput?()
    }

    func nextMatch(backwards: Bool = false) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + (backwards ? matches.count - 1 : 1)) % matches.count
        onReveal?(matches[matchIndex])
        onOutput?()
    }

    func closeSearch() {
        searchVisible = false
        searchText = ""
    }

    // MARK: Console série

    func applySerial(path: String, settings: SerialSettings) {
        serialPath = path
        serialSettings = settings
        TerminalSerialMemory.remember(settings, for: connection.id)
        if isActive {
            // Les réglages s'appliquent en rouvrant le port. L'ancien et le nouveau SerialTransport
            // passent par la même file pour ce chemin : la fermeture précède la réouverture (TIOCEXCL).
            transport?.close()
            transport = nil
            phase = .idle
            start()
        }
    }

    func toggleSerialPort() {
        if isActive {
            disconnect()
        } else {
            start()
        }
    }

    // MARK: Journal

    static var logDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/NetScope", isDirectory: true)
    }

    static func logFileName(for connection: RemoteConnection, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let base = connection.proto == .serie ? "console" : RemoteLauncher.rdpFileName(for: connection).replacingOccurrences(of: ".rdp", with: "")
        return "\(base)_\(formatter.string(from: date)).log"
    }

    private func openLog() {
        guard logHandle == nil else { return }
        let url = Self.logDirectory.appendingPathComponent(Self.logFileName(for: connection, date: connectedAt ?? Date()))
        logURL = url
        guard !demo else { return }
        do {
            try FileManager.default.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            let header = "--- NetScope · \(connection.name) · \(addressLabel) · \(Date().formatted(date: .abbreviated, time: .standard)) ---\n"
            handle.write(Data(header.utf8))
            logHandle = handle
            logFilter = TerminalLogFilter()
        } catch {
            show("Journal impossible\u{00A0}: \(error.localizedDescription)", error: true)
            logURL = nil
        }
    }

    private func closeLog() {
        if let logHandle {
            let pending = logFilter.pendingLine
            if !pending.isEmpty { logHandle.write(Data((pending + "\n").utf8)) }
            try? logHandle.close()
        }
        logHandle = nil
        if !logEnabled { logURL = nil }
    }

    /// Fichier témoin et tube du secret de la liaison SSH (fermée ou remplacée) supprimés.
    private func removeFlag() {
        if let askpassFlag { try? FileManager.default.removeItem(at: askpassFlag) }
        askpassFlag = nil
        secretChannel?.cancel()
        secretChannel = nil
    }
}

/// Réglages série retenus par connexion (débit, bits, parité, arrêt, flux), sans secret.
enum TerminalSerialMemory {
    private static let key = "acces.serie.reglages"

    static func settings(for connection: RemoteConnection) -> SerialSettings {
        var settings = SerialSettings(baudRate: connection.port)
        if !RegEnvironment.isSandboxed,
           let data = UserDefaults.standard.dictionary(forKey: key)?[connection.id.uuidString] as? Data,
           let saved = try? JSONDecoder().decode(SerialSettings.self, from: data) {
            settings = saved
            // Le débit du carnet fait foi : l'onglet l'y enregistre (mêmes débits des deux côtés).
            settings.baudRate = connection.port
        }
        return settings
    }

    static func remember(_ settings: SerialSettings, for id: UUID) {
        guard !RegEnvironment.isSandboxed, let data = try? JSONEncoder().encode(settings) else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[id.uuidString] = data
        UserDefaults.standard.set(all, forKey: key)
    }
}
