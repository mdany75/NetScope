import Foundation

/// Client SFTP par l'outil `sftp` de macOS (/usr/bin/sftp, OpenSSH), en mode batch.
///
/// Pourquoi cette voie : le SSH est déjà livré avec macOS et tenu à jour par Apple ; réécrire SSH
/// (échange de clés, chiffrements, vérification de la clé d'hôte) dans NetScope serait long et
/// risqué, et aucune dépendance externe n'est permise. NetScope partage aussi avec Terminal les
/// clés de ~/.ssh, l'agent SSH et ~/.ssh/known_hosts (« les clés déjà connues d'Accès distant »).
///
/// - Chaque opération lance `sftp -b -` (commandes sur l'entrée standard) ; une connexion maîtresse
///   (ControlMaster) est partagée : l'identification n'a lieu qu'une fois par session.
/// - Mot de passe ou phrase secrète : remis à ssh par SSH_ASKPASS (petit script sans secret ; le
///   secret ne passe que par l'environnement du processus, jamais par le disque ni la ligne de commande).
/// - Serveur inconnu : refusé, avec son empreinte, tant que l'utilisateur ne l'a pas accepté
///   (StrictHostKeyChecking=accept-new ensuite) ; clé changée : toujours refusée.
public final class SFTPClient: RemoteFileTransfer, @unchecked Sendable {
    public let endpoint: FileTransferEndpoint
    public static let sftpPath = "/usr/bin/sftp"
    public static let sshPath = "/usr/bin/ssh"

    private let lock = FileTransferSerialLock()
    private let controlDirectory: URL
    private var connected = false
    private var home = "/"
    private let processes = SFTPProcessRegistry()
    private let logHandler: (@Sendable (String) -> Void)?

    public init(endpoint: FileTransferEndpoint, log: (@Sendable (String) -> Void)? = nil) {
        self.endpoint = endpoint
        self.logHandler = log
        // Chemin court (les sockets Unix sont limités à 104 caractères) et privé (0700).
        controlDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nssftp", isDirectory: true)
    }

    // MARK: RemoteFileTransfer

    public func connect() async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.sftpPath) else { throw FileTransferError.toolMissing("sftp") }
        return try await lock.run { [self] in
            let output = try await run(["pwd"])
            home = SFTPOutput.workingDirectory(output) ?? "/"
            connected = true
            return home
        }
    }

    public func list(_ path: String) async throws -> [RemoteFileEntry] {
        try await lock.run { [self] in
            let directory = try RemotePath.validate(path)
            let output = try await run(["cd " + RemotePath.sftpQuoted(directory), "ls -lan"])
            return SFTPOutput.listing(output, directory: directory).sorted(by: RemoteFileEntry.browserOrder)
        }
    }

    public func size(of path: String) async throws -> Int64? {
        try await lock.run { [self] in try await remoteSize(path) }
    }

    public func download(_ remotePath: String, to localURL: URL, resume: Bool, progress: @escaping FileTransferProgress) async throws {
        let quoted = try RemotePath.sftpQuoted(remotePath)
        let local = try SFTPCommand.localQuoted(localURL.path)
        // Sans terminal, sftp n'affiche pas d'avancement : la taille du fichier local est relevée.
        let watcher = Task {
            while !Task.isCancelled {
                if let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? NSNumber {
                    progress(size.int64Value)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { watcher.cancel() }
        let exists = FileManager.default.fileExists(atPath: localURL.path)
        try await lock.run { [self] in
            _ = try await run([(resume && exists ? "get -a " : "get ") + quoted + " " + local])
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? NSNumber {
            progress(size.int64Value)
        }
    }

    public func upload(_ localURL: URL, to remotePath: String, resume: Bool, progress: @escaping FileTransferProgress) async throws {
        let quoted = try RemotePath.sftpQuoted(remotePath)
        let local = try SFTPCommand.localQuoted(localURL.path)
        let total = ((try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? NSNumber)?.int64Value
        // Avancement : taille du fichier distant relevée toutes les 1,5 s par la connexion partagée.
        let watcher = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                if let size = try? await remoteSize(remotePath) { progress(size) }
            }
        }
        defer { watcher.cancel() }
        try await lock.run { [self] in
            _ = try await run([(resume ? "put -a " : "put ") + local + " " + quoted])
        }
        if let total { progress(total) }
    }

    public func makeDirectory(_ path: String) async throws {
        try await lock.run { [self] in _ = try await run(["mkdir " + RemotePath.sftpQuoted(path)]) }
    }

    public func rename(_ from: String, to: String) async throws {
        try await lock.run { [self] in
            _ = try await run(["rename " + RemotePath.sftpQuoted(from) + " " + RemotePath.sftpQuoted(to)])
        }
    }

    public func deleteFile(_ path: String) async throws {
        try await lock.run { [self] in _ = try await run(["rm " + RemotePath.sftpQuoted(path)]) }
    }

    public func removeDirectory(_ path: String) async throws {
        try await lock.run { [self] in _ = try await run(["rmdir " + RemotePath.sftpQuoted(path)]) }
    }

    public func close() async {
        processes.terminateAll()
        guard connected else { return }
        connected = false
        // Ferme la connexion maîtresse partagée.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = SFTPCommand.controlArguments(directory: controlDirectory.path) + ["-O", "exit", SFTPCommand.destination(endpoint)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: Exécution

    private func remoteSize(_ path: String) async throws -> Int64? {
        let parent = RemotePath.parent(path)
        let output = try await run(["cd " + RemotePath.sftpQuoted(parent), "ls -lan"])
        return SFTPOutput.listing(output, directory: parent).first { $0.name == RemotePath.name(path) }?.size
    }

    /// Lance sftp avec ces commandes ; renvoie la sortie standard, ou lève l'erreur expliquée.
    private func run(_ commands: [String]) async throws -> String {
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let askpass = try SFTPCommand.writeAskpass(in: controlDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sftpPath)
        process.arguments = SFTPCommand.arguments(endpoint, controlDirectory: controlDirectory.path)
        var environment = ProcessInfo.processInfo.environment
        environment.merge(SFTPCommand.environment(endpoint, askpass: askpass.path)) { _, new in new }
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let collector = SFTPPipeCollector(output: output, errors: errors)
        let exit = SFTPExitWaiter()
        process.terminationHandler = { exit.finish($0.terminationStatus) }
        logHandler?("sftp " + commands.joined(separator: " ; "))
        do {
            try process.run()
        } catch {
            throw FileTransferError.toolMissing("sftp")
        }
        processes.add(process)
        defer { processes.remove(process) }
        let script = commands.joined(separator: "\n") + "\nbye\n"
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let status: Int32 = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            process.terminate()
        }
        let (stdout, stderr) = await collector.finish()
        if Task.isCancelled { throw FileTransferError.cancelled }
        if status != 0 {
            throw SFTPOutput.error(stderr: stderr, status: status, host: endpoint.host)
        }
        return stdout
    }
}

/// Processus sftp en cours (annulation et fermeture).
final class SFTPProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) { lock.lock(); running[ObjectIdentifier(process)] = process; lock.unlock() }
    func remove(_ process: Process) { lock.lock(); running[ObjectIdentifier(process)] = nil; lock.unlock() }

    func terminateAll() {
        lock.lock()
        let all = Array(running.values)
        running.removeAll()
        lock.unlock()
        for process in all where process.isRunning { process.terminate() }
    }
}

/// Code de sortie d'un processus, attendu sans bloquer de fil.
final class SFTPExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ value: Int32) {
        lock.lock()
        status = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Lit stdout et stderr au fil de l'eau (un tuyau plein bloquerait sftp).
final class SFTPPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private let group = DispatchGroup()

    init(output: Pipe, errors: Pipe) {
        for (pipe, isError) in [(output, false), (errors, true)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isError { err = data } else { out = data }
                lock.unlock()
                group.leave()
            }
        }
    }

    func finish() async -> (String, String) {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }
        return collected()
    }

    private func collected() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (FTPText.decode(out), FTPText.decode(err))
    }
}

/// Construction de la ligne de commande sftp (pure, testée).
public enum SFTPCommand {
    /// « admin@10.0.0.2 » ; IPv6 entre crochets.
    public static func destination(_ endpoint: FileTransferEndpoint) -> String {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        let user = endpoint.user.trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? host : user + "@" + host
    }

    static func controlArguments(directory: String) -> [String] {
        ["-o", "ControlMaster=auto", "-o", "ControlPath=\(directory)/%C", "-o", "ControlPersist=120"]
    }

    /// Arguments : options ssh, puis « -b - », puis la destination (« -- » interdit à sftp, mais
    /// l'hôte et l'utilisateur sont validés : ils ne peuvent pas commencer par « - »).
    public static func arguments(_ endpoint: FileTransferEndpoint, controlDirectory: String) -> [String] {
        var args: [String] = [
            // Avant « -b » : la première valeur gagne, et « -b » impose BatchMode=yes (aucune
            // demande de mot de passe) ; SSH_ASKPASS répond à la place de l'utilisateur.
            "-o", "BatchMode=no",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=\(Int(endpoint.timeout))",
            "-o", "ServerAliveInterval=15",
            "-o", "StrictHostKeyChecking=\(endpoint.acceptNewHostKey ? "accept-new" : "ask")",
        ]
        args += controlArguments(directory: controlDirectory)
        switch endpoint.settings.sftpAuth {
        case .password:
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        case .key:
            let path = (endpoint.settings.keyPath as NSString).expandingTildeInPath
            if !path.isEmpty { args += ["-i", path, "-o", "IdentitiesOnly=yes"] }
        case .agent:
            break
        }
        if endpoint.port != 22 { args += ["-P", String(endpoint.port)] }
        args += ["-b", "-", destination(endpoint)]
        return args
    }

    /// Variables d'environnement : script SSH_ASKPASS forcé, secret, accord pour un serveur inconnu.
    public static func environment(_ endpoint: FileTransferEndpoint, askpass: String) -> [String: String] {
        var env = ["SSH_ASKPASS": askpass, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]
        env["NETSCOPE_SFTP_SECRET"] = endpoint.secret ?? ""
        return env
    }

    /// Script SSH_ASKPASS (sans aucun secret) : répond « no » à « Are you sure you want to continue
    /// connecting » (le serveur inconnu est alors présenté à l'utilisateur), le secret sinon.
    public static let askpassScript = """
    #!/bin/sh
    case "$1" in
      *"continue connecting"*|*"(yes/no"*) printf '%s\\n' "$1" >&2; echo no ;;
      *) printf '%s\\n' "$NETSCOPE_SFTP_SECRET" ;;
    esac
    """ + "\n"

    static func writeAskpass(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("askpass.sh")
        if (try? String(contentsOf: url, encoding: .utf8)) != askpassScript {
            try askpassScript.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Chemin local entre guillemets (mêmes règles que les chemins distants).
    public static func localQuoted(_ path: String) throws -> String {
        try RemotePath.sftpQuoted(path)
    }
}

/// Lecture de la sortie de sftp (pure, testée).
public enum SFTPOutput {
    /// « Remote working directory: /home/admin » → /home/admin.
    public static func workingDirectory(_ output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            if let range = line.range(of: "Remote working directory: ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Lignes « ls -lan » (format Unix) ; l'écho des commandes (« sftp> … ») est ignoré.
    public static func listing(_ output: String, directory: String, now: Date = Date()) -> [RemoteFileEntry] {
        output.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("sftp>") }
            .compactMap { FTPListing.parseLISTLine($0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")), directory: directory, now: now) }
    }

    /// Erreur expliquée à partir de la sortie d'erreur de sftp et ssh.
    public static func error(stderr: String, status: Int32, host: String) -> FileTransferError {
        let lower = stderr.lowercased()
        if lower.contains("remote host identification has changed") || lower.contains("host key for") && lower.contains("has changed") {
            return .hostKeyChanged
        }
        if lower.contains("host key verification failed") || lower.contains("continue connecting") {
            return .unknownHostKey(fingerprint: fingerprint(in: stderr) ?? "inconnue")
        }
        if lower.contains("permission denied (") || lower.contains("too many authentication failures") {
            return .loginFailed("le serveur SSH refuse l’identification")
        }
        if lower.contains("could not resolve hostname") { return .connectionFailed("nom d’hôte introuvable (\(host))") }
        if lower.contains("connection refused") { return .connectionFailed("le serveur refuse la connexion (port fermé ?)") }
        if lower.contains("operation timed out") || lower.contains("connection timed out") { return .timeout }
        if lower.contains("no route to host") || lower.contains("network is unreachable") { return .connectionFailed("aucune route vers \(host)") }
        if lower.contains("connection closed") || lower.contains("broken pipe") || lower.contains("connection reset") {
            return .connectionFailed("connexion perdue")
        }
        if lower.contains("subsystem request failed") { return .unsupported("Le serveur SSH n’offre pas SFTP (sous-système désactivé).") }
        let detail = lastMeaningfulLine(stderr)
        if lower.contains("no such file") || lower.contains("not found") { return .notFound(path(in: detail) ?? detail) }
        if lower.contains("permission denied") { return .permissionDenied(path(in: detail) ?? detail) }
        return .server(detail.isEmpty ? "sftp a échoué (code \(status))" : detail)
    }

    /// « ED25519 key fingerprint is SHA256:abc… » → « SHA256:abc… ».
    public static func fingerprint(in text: String) -> String? {
        guard let range = text.range(of: "SHA256:") else { return nil }
        let tail = text[range.lowerBound...]
        return String(tail.prefix { !$0.isWhitespace && $0 != "." })
    }

    static func lastMeaningfulLine(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("sftp>") && !$0.lowercased().hasPrefix("warning: permanently added") }
            .last ?? ""
    }

    /// « remote open("/x/y"): Permission denied » → /x/y ; « File "/x" not found. » → /x.
    static func path(in line: String) -> String? {
        guard let open = line.firstIndex(of: "\""), let close = line[line.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(line[line.index(after: open)..<close])
    }
}
