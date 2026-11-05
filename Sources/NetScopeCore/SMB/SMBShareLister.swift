import Foundation

// Note 72 : lancement de `smbutil view`, seulement sur un clic de l'utilisateur.
//
// Mot de passe : jamais dans la ligne de commande, l'environnement, un fichier (nsmb.conf) ni le
// journal. smbutil est lancé dans un pseudo-terminal dont il fait son terminal de contrôle ; il y
// demande le mot de passe (« Password: », écho coupé par smbutil) et NetScope le tape alors sur ce
// terminal, une seule fois. Une deuxième demande veut dire « refusé » : smbutil est arrêté.

/// Sortie brute d'un lancement de smbutil.
public struct SMBRunResult: Hashable, Sendable {
    public var output: String
    /// Fin normale (code 0).
    public var succeeded: Bool
    public var timedOut: Bool
    /// Nombre de demandes de mot de passe vues.
    public var passwordPrompts: Int

    public init(output: String, succeeded: Bool, timedOut: Bool = false, passwordPrompts: Int = 0) {
        self.output = output
        self.succeeded = succeeded
        self.timedOut = timedOut
        self.passwordPrompts = passwordPrompts
    }
}

/// Lance smbutil ; remplacé par une sortie fixe dans les tests (aucun réseau).
public protocol SMBCommandRunner: Sendable {
    func run(arguments: [String], password: String?, timeout: TimeInterval) async -> SMBRunResult
}

/// Lit les partages d'un hôte : invité, puis anonyme ; ou avec un utilisateur et son mot de passe.
public struct SMBShareLister: Sendable {
    public static let executable = "/usr/bin/smbutil"

    public var runner: SMBCommandRunner
    public var timeout: TimeInterval

    public init(runner: SMBCommandRunner = SMBUtilRunner(), timeout: TimeInterval = 20) {
        self.runner = runner
        self.timeout = timeout
    }

    /// `login` nil : essai en invité puis en anonyme (session nulle), sans mot de passe.
    public func list(host: String, login: SMBLogin? = nil, password: String? = nil,
                     now: @Sendable () -> Date = { Date() }) async throws -> SMBShareListing {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard SMBPaths.isValidHost(trimmed) else { throw SMBShareError.invalidHost }
        if let login {
            return try await attempt(.user(login), host: trimmed, password: password ?? "", now: now)
        }
        do {
            return try await attempt(.guest, host: trimmed, password: nil, now: now)
        } catch let error as SMBShareError {
            // Invité refusé : la session anonyme (« null session ») liste parfois les partages.
            guard case .accessDenied = error else { throw error }
            do {
                return try await attempt(.anonymous, host: trimmed, password: nil, now: now)
            } catch let second as SMBShareError {
                if case .accessDenied = second { throw SMBShareError.accessDenied(guest: true) }
                throw second
            }
        }
    }

    func attempt(_ mode: SMBAttempt, host: String, password: String?, now: @Sendable () -> Date) async throws -> SMBShareListing {
        let arguments = try SMBPaths.arguments(host: host, mode: mode)
        let result = await runner.run(arguments: arguments, password: password, timeout: timeout)
        try Task.checkCancellation()
        return try Self.interpret(result, host: host, mode: mode, date: now())
    }

    /// Résultat d'un lancement → liste ou erreur claire.
    public static func interpret(_ result: SMBRunResult, host: String, mode: SMBAttempt, date: Date = Date()) throws -> SMBShareListing {
        let guest: Bool
        if case .user = mode { guest = false } else { guest = true }
        if result.timedOut { throw SMBShareError.timeout }
        // Mot de passe demandé de nouveau (refusé), ou demandé à un essai invité ou anonyme.
        if result.passwordPrompts > 1 || (guest && result.passwordPrompts > 0 && !result.succeeded) {
            throw SMBShareError.accessDenied(guest: guest)
        }
        if result.succeeded, let parsed = SMBShareParser.parse(result.output) {
            return SMBShareListing(host: host, shares: parsed.shares, reportedCount: parsed.reportedCount,
                                   access: mode.access, date: date)
        }
        throw SMBShareParser.failure(from: result.output, guest: guest)
    }
}

/// Le vrai smbutil, dans un pseudo-terminal.
public struct SMBUtilRunner: SMBCommandRunner {
    public init() {}

    public func run(arguments: [String], password: String?, timeout: TimeInterval) async -> SMBRunResult {
        guard FileManager.default.isExecutableFile(atPath: SMBShareLister.executable) else {
            return SMBRunResult(output: "smbutil: executable introuvable", succeeded: false)
        }
        let session = SMBPTYSession(arguments: arguments, password: password, timeout: timeout)
        return await withTaskCancellationHandler {
            await session.run()
        } onCancel: {
            session.cancel()
        }
    }
}

/// Une exécution de smbutil : lecture de la sortie, réponse à la demande de mot de passe, délai.
final class SMBPTYSession: @unchecked Sendable {
    private let process: PTYProcess
    private let password: String?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var output = ""
    private var prompts = 0
    /// Vrai dès que l'en-tête du tableau des partages est arrivé : après, plus aucune demande de
    /// mot de passe n'est acceptée (un commentaire de partage peut finir par « password: »).
    private var listingSeen = false
    private var timedOut = false
    private var done = false
    private var continuation: CheckedContinuation<SMBRunResult, Never>?
    /// Plafond de la sortie gardée (un hôte avec des milliers de partages reste lisible).
    private static let maxOutput = 1_000_000

    init(arguments: [String], password: String?, timeout: TimeInterval) {
        // Environnement minimal : messages de smbutil en anglais (classés par SMBShareParser).
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                           "HOME": NSHomeDirectory(), "USER": NSUserName(), "TERM": "dumb"]
        process = PTYProcess(executable: SMBShareLister.executable, arguments: arguments, environment: environment,
                             columns: 200, rows: 50)
        self.password = password
        self.timeout = timeout
    }

    func run() async -> SMBRunResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<SMBRunResult, Never>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            process.start { [self] event in handle(event) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let finished = done
                if !finished { timedOut = true }
                lock.unlock()
                if !finished { process.close() }
            }
        }
    }

    func cancel() { process.close() }

    private func handle(_ event: TerminalTransportEvent) {
        switch event {
        case .connected:
            break
        case .data(let bytes):
            let chunk = String(decoding: bytes, as: UTF8.self)
            lock.lock()
            if output.count < Self.maxOutput { output += chunk }
            if !listingSeen { listingSeen = SMBPrompt.containsListingHeader(output) }
            let askingPassword = !listingSeen && SMBPrompt.isPasswordPrompt(output)
            var reply: String?
            var stop = false
            if askingPassword {
                prompts += 1
                // La demande est retirée de la sortie (elle n'est pas un message d'erreur).
                if let range = output.range(of: "\n", options: .backwards) {
                    output = String(output[..<range.upperBound])
                } else {
                    output = ""
                }
                if prompts == 1 { reply = (password ?? "") + "\n" } else { stop = true }
            }
            lock.unlock()
            if let reply { process.send(Array(reply.utf8)) }
            if stop { process.close() }
        case .closed(let message):
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            done = true
            // Par prudence : le mot de passe envoyé ne reparaît jamais dans la sortie analysée,
            // affichée ou journalisée (écho du terminal).
            if let password, password.count >= 3 { output = output.replacingOccurrences(of: password, with: "••••") }
            let result = SMBRunResult(output: output, succeeded: message == nil && !timedOut,
                                      timedOut: timedOut, passwordPrompts: prompts)
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }
}

/// Reconnaissance de la demande de mot de passe de smbutil et du début de la liste.
public enum SMBPrompt {
    /// Vrai si la dernière ligne (pas encore terminée) est exactement une demande de mot de passe
    /// de smbutil : « Password: », « Password for serveur: » (ou en français).
    public static func isPasswordPrompt(_ output: String) -> Bool {
        let last = output.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let line = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.range(of: #"^(password|mot de passe)( (for|pour) .+)?\s*:$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Vrai si la sortie contient l'en-tête du tableau des partages (« Share  Type  Comments »).
    public static func containsListingHeader(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let words = line.lowercased().split(separator: " ")
            guard let first = words.first else { return false }
            return ["share", "sharename", "partage"].contains(String(first)) && words.contains("type")
        }
    }
}
