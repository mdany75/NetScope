import AppKit
import Foundation
import NetScopeCore
import SwiftUI

// Note 66 : tunnels SSH (-L, -D, -J) gérés comme des sessions d'Accès distant. Chaque tunnel est un
// processus /usr/bin/ssh lancé dans un pseudo-terminal (les questions de ssh — empreinte d'un
// serveur inconnu, mot de passe — passent par le même script SSH_ASKPASS que les onglets de
// terminal, et le mot de passe du Trousseau par un tube à usage unique). Le port local est choisi
// libre sur 127.0.0.1 ; le tunnel est « ouvert » quand ssh écoute sur ce port (vérifié par un bind
// local, sans s'y connecter). En démonstration et pendant les captures, rien n'est lancé.

/// ~/.ssh/config lu une fois (relu à chaque import) ; démonstration : fichier fictif ; captures sans
/// démonstration : vide (rien du Mac qui les produit).
@MainActor
enum SSHConfigCache {
    private static var cached: SSHConfigFile?

    static var config: SSHConfigFile {
        if let cached { return cached }
        let loaded: SSHConfigFile
        if RegEnvironment.isDemo {
            loaded = SSHTunnelDemo.config
        } else if RegEnvironment.isSandboxed {
            loaded = SSHConfigFile()
        } else {
            loaded = SSHConfigFile.load()
        }
        cached = loaded
        return loaded
    }

    @discardableResult
    static func reload() -> SSHConfigFile {
        cached = nil
        return config
    }
}

@MainActor
final class SSHTunnelSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case stopped
        case starting
        case open
        case failed(String)
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let text: String
        let tone: Tone
    }

    /// Identifiant du tunnel (celui de la redirection du carnet).
    let id: UUID
    @Published private(set) var connection: RemoteConnection
    @Published private(set) var tunnel: SSHTunnelSpec
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var localPort: Int?
    @Published private(set) var openedAt: Date?
    @Published private(set) var log: [LogLine] = []
    /// Commande lancée (sans secret), pour l'affichage.
    @Published private(set) var commandLine = ""
    /// Serveur inconnu : empreinte à accepter.
    @Published private(set) var hostKey: (fingerprint: String, keyType: String?)?
    /// Demande de mot de passe ou de phrase secrète que le Trousseau n'a pas couverte.
    @Published private(set) var passwordPrompt: String?
    /// Avertissement non bloquant (destination injoignable vue du serveur).
    @Published private(set) var warning: SSHTunnelDiagnosis?
    /// Le port local voulu était pris : un autre a été choisi.
    @Published private(set) var portChanged = false
    @Published var passwordInput = ""

    private var process: PTYProcess?
    private var inbox = TerminalInbox()
    private var filter = TerminalLogFilter()
    private var recentText = ""
    private var poll: Task<Void, Never>?
    private var userStopped = false
    private var flag: URL?
    private var secretChannel: SSHSecretChannel?
    let demo: Bool

    init(tunnel: SSHTunnelSpec, connection: RemoteConnection, demo: Bool = RegEnvironment.isSandboxed) {
        id = tunnel.id
        self.tunnel = tunnel
        self.connection = connection
        self.demo = demo
    }

    // MARK: État

    var isActive: Bool { phase == .starting || phase == .open }

    var title: String {
        let label = tunnel.label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? (tunnel.kind == .dynamic ? "SOCKS · \(connection.name)" : "\(tunnel.remoteHost):\(tunnel.remotePort)") : label
    }

    /// « 127.0.0.1:13389 → 10.20.0.15:3389 », « 127.0.0.1:1080 (SOCKS5) ».
    var routeLabel: String {
        let local = localPort.map { SSHTunnelCommand.localAddress(port: $0) } ?? "127.0.0.1:\(tunnel.localPort > 0 ? String(tunnel.localPort) : "auto")"
        switch tunnel.kind {
        case .local:
            let host = tunnel.remoteHost.contains(":") ? "[\(tunnel.remoteHost)]" : tunnel.remoteHost
            return "\(local) → \(host):\(tunnel.remotePort)"
        case .dynamic:
            return "\(local) (SOCKS5)"
        }
    }

    /// « netadmin@10.182.122.2:22 ».
    var serverLabel: String {
        let user = connection.username.isEmpty ? "" : connection.username + "@"
        let host = connection.host.contains(":") ? "[\(connection.host)]" : connection.host
        return "\(user)\(host):\(connection.port)"
    }

    var phaseLabel: (text: String, tone: Tone) {
        switch phase {
        case .stopped: return ("Arrêté", .neutral)
        case .starting: return (passwordPrompt != nil || hostKey != nil ? "En attente" : "Ouverture…", .accent)
        case .open: return ("Ouvert", .success)
        case .failed: return ("Échec", .critical)
        }
    }

    var dot: Color {
        switch phase {
        case .open: return Theme.successDot
        case .starting: return Theme.warningDot
        case .failed: return Color(nsColor: .systemRed)
        case .stopped: return Theme.neutralDot
        }
    }

    /// Le carnet a changé (tunnel modifié, connexion renommée) : repris au prochain démarrage.
    func update(tunnel: SSHTunnelSpec, connection: RemoteConnection) {
        if tunnel != self.tunnel { self.tunnel = tunnel }
        if connection != self.connection { self.connection = connection }
    }

    // MARK: Démarrage et arrêt

    func start(reserved: Set<Int>) {
        guard !isActive else { return }
        resetState()
        do {
            let spec = try tunnel.validated()
            let target = try SSHTarget(connection: connection).validated()
            guard connection.proto == .ssh else { throw SSHTunnelError.notSSH }
            if demo {
                startDemo(spec)
                return
            }
            guard let port = LocalPortPicker.choose(preferred: spec.preferredLocalPort, reserved: reserved) else {
                throw SSHTunnelError.noFreePort
            }
            portChanged = spec.localPort > 0 && port != spec.localPort
            let arguments = try SSHTunnelCommand.arguments(target: target, tunnel: spec, localPort: port)
            guard FileManager.default.isExecutableFile(atPath: SSHTerminalCommand.sshPath) else {
                throw PTYProcess.Failure.spawn(SSHTerminalCommand.sshPath, ENOENT)
            }
            let askpass = try SSHTerminalCommand.writeAskpass()
            let flag = SSHTerminalCommand.controlDirectory.appendingPathComponent("tunnel-" + UUID().uuidString)
            self.flag = flag
            let secret = RemoteSessionStore.shared.password(for: connection.id)
            let channel = try secret.flatMap { $0.isEmpty ? nil : try SSHSecretChannel(directory: SSHTerminalCommand.controlDirectory, secret: $0) }
            secretChannel = channel
            // Note 78 : l'invite attendue tient compte de User et HostName de ~/.ssh/config.
            let expect = SSHConfigCache.config.expectedPrompt(user: connection.username, host: connection.host)
            let environment = SSHTerminalCommand.environment(base: ProcessInfo.processInfo.environment, askpass: askpass.path,
                                                              secretPipe: channel?.path, expect: expect, flag: flag.path)
            localPort = port
            commandLine = SSHTunnelCommand.displayCommand(arguments)
            phase = .starting
            append("NetScope › " + commandLine + (secret == nil ? "" : "  (mot de passe du Trousseau)"), tone: .neutral)
            if portChanged {
                append("Port \(spec.localPort) déjà pris sur ce Mac\u{00A0}: \(port) choisi.", tone: .warning)
            } else if spec.localPort == 0 {
                append("Port local \(port) libre, choisi automatiquement.", tone: .neutral)
            }
            let process = PTYProcess(executable: SSHTerminalCommand.sshPath, arguments: arguments, environment: environment,
                                     columns: 200, rows: 24)
            self.process = process
            let inbox = TerminalInbox()
            self.inbox = inbox
            process.start { [weak self] event in
                guard inbox.push(event) else { return }
                DispatchQueue.main.async { self?.drain(inbox) }
            }
            watchPort(port)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message)
            append(message, tone: .critical)
        }
    }

    func stop() {
        guard isActive else { return }
        userStopped = true
        poll?.cancel()
        poll = nil
        if demo {
            phase = .stopped
            append("Tunnel arrêté.", tone: .neutral)
            return
        }
        process?.close()
    }

    func restart(reserved: Set<Int>) {
        if isActive {
            userStopped = true
            poll?.cancel()
            process?.close()
            process = nil
            cleanup()
            phase = .stopped
        }
        start(reserved: reserved)
    }

    private func resetState() {
        userStopped = false
        hostKey = nil
        passwordPrompt = nil
        passwordInput = ""
        warning = nil
        portChanged = false
        recentText = ""
        filter = TerminalLogFilter()
        openedAt = nil
        if !demo { localPort = nil }
    }

    /// Le tunnel est ouvert quand ssh écoute sur le port local (bind refusé), sans connexion.
    private func watchPort(_ port: Int) {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .starting else { return }
                if LocalPortPicker.isListening(port) {
                    self.phase = .open
                    self.openedAt = Date()
                    self.passwordPrompt = nil
                    self.hostKey = nil
                    self.append("Tunnel ouvert\u{00A0}: \(self.routeLabel).", tone: .success)
                    return
                }
            }
        }
    }

    private func drain(_ source: TerminalInbox) {
        let events = source.take()
        guard source === inbox else { return }
        for event in events {
            switch event {
            case .connected:
                break
            case .data(let bytes):
                receive(bytes)
            case .closed(let message):
                finish(message)
            }
        }
    }

    private func receive(_ bytes: [UInt8]) {
        let text = filter.feed(bytes)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let clean = RemoteShell.sanitizedTitle(String(line), limit: 300)
            guard !clean.isEmpty else { continue }
            let diagnosis = SSHTunnelDiagnosis.scan(clean)
            append(clean, tone: diagnosis == nil ? .neutral : (diagnosis?.isFatal == true ? .critical : .warning))
            if let diagnosis, !diagnosis.isFatal { warning = diagnosis }
        }
        recentText += text
        if recentText.count > 4_000 { recentText = String(recentText.suffix(3_000)) }
        let pending = filter.pendingLine
        if case .unknownHost(let fingerprint, let keyType)? = SSHPromptDetector.scan(recentText + pending) {
            hostKey = (fingerprint, keyType)
        } else {
            hostKey = nil
        }
        passwordPrompt = hostKey == nil ? SSHTunnelDiagnosis.pendingPrompt(pending) : nil
    }

    private func finish(_ message: String?) {
        poll?.cancel()
        poll = nil
        process = nil
        cleanup()
        hostKey = nil
        passwordPrompt = nil
        let diagnosis = SSHTunnelDiagnosis.scan(recentText + filter.pendingLine)
        if userStopped {
            phase = .stopped
            append("Tunnel arrêté.", tone: .neutral)
        } else if let diagnosis, diagnosis.isFatal {
            phase = .failed(diagnosis.message)
            append(diagnosis.message, tone: .critical)
        } else {
            let text = message ?? (phase == .open ? "Tunnel fermé par le serveur." : "ssh s’est arrêté avant l’ouverture du tunnel.")
            phase = .failed(text)
            append(text, tone: .critical)
        }
    }

    private func cleanup() {
        if let flag { try? FileManager.default.removeItem(at: flag) }
        flag = nil
        secretChannel?.cancel()
        secretChannel = nil
    }

    // MARK: Réponses à ssh

    func answerHostKey(accept: Bool) {
        hostKey = nil
        process?.send(Array((accept ? "yes" : "no").utf8) + [0x0D])
        append(accept ? "Empreinte acceptée (ajoutée à ~/.ssh/known_hosts)." : "Empreinte refusée.", tone: accept ? .neutral : .warning)
    }

    func sendPassword() {
        guard passwordPrompt != nil, !passwordInput.isEmpty else { return }
        process?.send(Array(passwordInput.utf8) + [0x0D])
        passwordInput = ""
        passwordPrompt = nil
    }

    // MARK: Journal

    func append(_ text: String, tone: Tone, date: Date = Date()) {
        log.append(LogLine(date: date, text: text, tone: tone))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func copyLocalAddress() {
        guard let port = localPort else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SSHTunnelCommand.localAddress(port: port), forType: .string)
    }

    // MARK: Démonstration

    private func startDemo(_ spec: SSHTunnelSpec) {
        let port = SSHTunnelDemo.port(for: spec)
        localPort = port
        commandLine = (try? SSHTunnelCommand.displayCommand(SSHTunnelCommand.arguments(target: SSHTarget(connection: connection), tunnel: spec,
                                                                                         localPort: port, home: "/Users/dany"))) ?? ""
        let opened = SSHTunnelDemo.openedAt(for: spec)
        openedAt = opened
        phase = .open
        log = SSHTunnelDemo.log(for: spec, connection: connection, port: port, command: commandLine, openedAt: opened)
    }
}

/// Sessions de tunnel (une par redirection du carnet), partagées par l'écran et les onglets.
@MainActor
final class SSHTunnelStore: ObservableObject {
    static let shared = SSHTunnelStore()

    @Published private(set) var sessions: [UUID: SSHTunnelSession] = [:]

    private init() {}

    func session(for tunnelID: UUID) -> SSHTunnelSession? { sessions[tunnelID] }

    /// Ports locaux tenus par les autres tunnels de NetScope.
    func reservedPorts(except id: UUID? = nil) -> Set<Int> {
        Set(sessions.values.filter { $0.id != id && $0.isActive }.compactMap(\.localPort))
    }

    var activeCount: Int { sessions.values.filter(\.isActive).count }

    func isActive(_ tunnelID: UUID) -> Bool { sessions[tunnelID]?.isActive ?? false }

    /// Session du tunnel (créée au besoin, mise à jour avec le carnet).
    func prepare(_ tunnel: SSHTunnelSpec, via connection: RemoteConnection) -> SSHTunnelSession {
        if let existing = sessions[tunnel.id] {
            existing.update(tunnel: tunnel, connection: connection)
            return existing
        }
        let session = SSHTunnelSession(tunnel: tunnel, connection: connection)
        sessions[tunnel.id] = session
        return session
    }

    /// Démarre le tunnel (s'il ne tourne pas déjà) et renvoie sa session.
    @discardableResult
    func start(_ tunnel: SSHTunnelSpec, via connection: RemoteConnection) -> SSHTunnelSession {
        let session = prepare(tunnel, via: connection)
        if !session.isActive { session.start(reserved: reservedPorts(except: tunnel.id)) }
        return session
    }

    func stop(_ tunnelID: UUID) {
        sessions[tunnelID]?.stop()
    }

    /// Tunnel retiré du carnet (ou onglet fermé) : arrêté et oublié.
    func discard(_ tunnelID: UUID) {
        sessions[tunnelID]?.stop()
        sessions[tunnelID] = nil
    }

    /// Connexion supprimée : tous ses tunnels sont arrêtés.
    func discardAll(for connectionID: UUID) {
        for session in sessions.values where session.connection.id == connectionID { discard(session.id) }
    }
}

/// Formulaire d'un tunnel (texte des champs).
struct SSHTunnelDraft: Equatable {
    var connectionID: UUID
    var editingID: UUID?
    var kind: SSHTunnelKind = .local
    var label = ""
    /// Vide : port libre choisi automatiquement.
    var localPort = ""
    var remoteHost = ""
    var remotePort = ""
    var use: SSHTunnelUse = .none
    /// « Ouvrir avec » choisi à la main : le port distant ne le change plus.
    var useEdited = false

    init(connectionID: UUID) {
        self.connectionID = connectionID
    }

    init(_ tunnel: SSHTunnelSpec, connectionID: UUID) {
        self.connectionID = connectionID
        editingID = tunnel.id
        kind = tunnel.kind
        label = tunnel.label
        localPort = tunnel.localPort > 0 ? String(tunnel.localPort) : ""
        remoteHost = tunnel.remoteHost
        remotePort = tunnel.remotePort > 0 ? String(tunnel.remotePort) : ""
        use = tunnel.use
        useEdited = true
    }

    /// Port local proposé (texte du champ vide).
    var suggestedLocalPort: Int {
        SSHTunnelSpec.suggestedLocalPort(kind: kind, remotePort: Int(remotePort.trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    /// Redirection lue dans les champs (validée ensuite).
    func tunnel() throws -> SSHTunnelSpec {
        let localText = localPort.trimmingCharacters(in: .whitespaces)
        let local: Int
        if localText.isEmpty || localText.lowercased() == "auto" {
            local = 0
        } else {
            guard let value = Int(localText) else { throw SSHTunnelError.invalidLocalPort(0) }
            local = value
        }
        var remote = 0
        if kind == .local {
            let text = remotePort.trimmingCharacters(in: .whitespaces)
            guard let value = Int(text) else { throw SSHTunnelError.invalidTarget("\(remoteHost):\(text)") }
            remote = value
        }
        return SSHTunnelSpec(id: editingID ?? UUID(), kind: kind, localPort: local, remoteHost: remoteHost.trimmingCharacters(in: .whitespaces),
                             remotePort: remote, use: kind == .dynamic ? SSHTunnelUse.none : use, label: label)
    }
}

/// Source de l'import d'Accès distant.
enum RemoteImportSource: String, CaseIterable, Identifiable {
    case scan, sshConfig

    var id: String { rawValue }

    var label: String { self == .scan ? "Appareils du scan" : "~/.ssh/config" }
}
