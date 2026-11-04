import Darwin
import Foundation

/// Résultat d'un test d'identifiant SSH ou WMI.
public struct CredentialTestOutcome: Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case success, partial, failure }
    public var status: Status
    public var message: String
    /// Détail (sortie de la commande, état de chaque port).
    public var details: [String]

    public init(status: Status, message: String, details: [String] = []) {
        self.status = status
        self.message = message
        self.details = details
    }
}

// MARK: - SSH

/// Test SSH par /usr/bin/ssh : connexion, authentification et commande inoffensive
/// (« uname -a »), délai court, sans jamais toucher au fichier known_hosts de l'utilisateur.
public enum SSHCredentialTest {
    public static let executable = "/usr/bin/ssh"
    public static let defaultCommand = "uname -a"

    /// Ligne de commande et environnement de ssh.
    public struct Invocation: Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
    }

    /// - Parameters:
    ///   - knownHosts: fichier known_hosts propre à NetScope (empreintes acceptées au premier test).
    ///   - askpass: script qui donne le secret à ssh (mot de passe ou phrase secrète de la clé) ;
    ///     nil : aucun secret, BatchMode=yes.
    public static func invocation(host: String, credential: RemoteCredential, knownHosts: URL, askpass: URL?,
                                  command: String = defaultCommand, connectTimeout: Int = 6) -> Invocation {
        var arguments = [
            "-o", "BatchMode=\(askpass == nil ? "yes" : "no")",
            "-o", "ConnectTimeout=\(max(1, connectTimeout))",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHosts.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-F", "/dev/null",
        ]
        switch credential.sshMethod {
        case .key:
            arguments += ["-o", "PreferredAuthentications=publickey", "-o", "IdentitiesOnly=yes", "-o", "PasswordAuthentication=no"]
            if !credential.keyPath.isEmpty {
                arguments += ["-i", (credential.keyPath as NSString).expandingTildeInPath]
            }
        case .password:
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        }
        arguments += ["-p", String(credential.port), "-l", credential.user, "-T", "-n", "--", host, command]
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "C"]
        if let askpass {
            environment["SSH_ASKPASS"] = askpass.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
        }
        return Invocation(executable: executable, arguments: arguments, environment: environment)
    }

    /// Analyse de la sortie de ssh (code 255 : erreur de ssh lui-même).
    public static func analyze(exitCode: Int32, stdout: String, stderr: String, host: String, milliseconds: Int,
                               timedOut: Bool = false) -> CredentialTestOutcome {
        let output = stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let errors = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        let lower = stderr.lowercased()
        if timedOut {
            return CredentialTestOutcome(status: .failure, message: "Échec · délai dépassé : \(host) ne répond pas sur SSH (pare-feu, adresse ou port incorrects).", details: errors)
        }
        if exitCode == 0 {
            let first = output.first ?? "(aucune sortie)"
            return CredentialTestOutcome(status: .success, message: "Réussi · \(host) · session ouverte · \(first) · \(milliseconds)\u{00A0}ms",
                                         details: output)
        }
        if exitCode != 255 {
            // Session ouverte et authentifiée, mais la commande n'existe pas (switch, routeur, Windows).
            return CredentialTestOutcome(status: .partial,
                                         message: "Réussi en partie · connexion et authentification acceptées par \(host), mais « uname » a renvoyé le code \(exitCode) (équipement sans shell Unix ?).",
                                         details: output + errors)
        }
        let reason: String
        if lower.contains("permission denied") || lower.contains("too many authentication failures") {
            reason = "authentification refusée : utilisateur, mot de passe ou clé incorrects (ou méthode non permise par le serveur)"
        } else if lower.contains("remote host identification has changed") || lower.contains("host key verification failed") {
            reason = "l’empreinte de l’hôte a changé depuis le premier test : vérifiez qu’il s’agit bien du même équipement"
        } else if lower.contains("connection refused") {
            reason = "connexion refusée : aucun serveur SSH n’écoute sur ce port"
        } else if lower.contains("timed out") {
            reason = "délai dépassé : aucune réponse (pare-feu, adresse ou port incorrects)"
        } else if lower.contains("no route to host") || lower.contains("host is down") || lower.contains("network is unreachable") {
            reason = "hôte injoignable depuis ce Mac"
        } else if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") {
            reason = "nom d’hôte introuvable dans le DNS"
        } else if lower.contains("bad permissions") || lower.contains("unprotected private key") {
            reason = "clé privée trop ouverte : faites « chmod 600 » sur le fichier de la clé"
        } else if lower.contains("no such identity") || lower.contains("no such file") {
            reason = "fichier de clé introuvable"
        } else if lower.contains("invalid format") || lower.contains("load key") || lower.contains("incorrect passphrase") {
            reason = "clé illisible : format non reconnu ou phrase secrète incorrecte"
        } else if lower.contains("no matching") || lower.contains("unable to negotiate") {
            reason = "algorithmes incompatibles (équipement ancien : chiffrement ou échange de clés non accepté par OpenSSH)"
        } else if lower.contains("connection closed") || lower.contains("connection reset") || lower.contains("kex_exchange_identification") {
            reason = "connexion fermée par \(host) avant l’authentification (limite de sessions, liste d’accès ?)"
        } else {
            reason = errors.last ?? "erreur de ssh (code 255)"
        }
        return CredentialTestOutcome(status: .failure, message: "Échec · \(reason).", details: errors)
    }

    /// Script SSH_ASKPASS : lit le secret dans la variable NETSCOPE_SSH_SECRET (jamais sur le disque).
    public static let askpassScript = "#!/bin/sh\nprintf '%s\\n' \"$NETSCOPE_SSH_SECRET\"\n"

    /// Lance le test (processus local /usr/bin/ssh), tué après `connectTimeout + 6` s au plus.
    public static func run(host: String, credential: RemoteCredential, secret: String?, knownHosts: URL,
                           command: String = defaultCommand, connectTimeout: Int = 6) async -> CredentialTestOutcome {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return CredentialTestOutcome(status: .failure, message: "Échec · /usr/bin/ssh introuvable sur ce Mac.")
        }
        guard !credential.user.isEmpty else {
            return CredentialTestOutcome(status: .failure, message: "Échec · saisissez l’utilisateur SSH.")
        }
        if credential.sshMethod == .password, (secret ?? "").isEmpty {
            return CredentialTestOutcome(status: .failure, message: "Échec · aucun mot de passe enregistré au Trousseau pour cet identifiant.")
        }
        var askpassURL: URL?
        var temporary: URL?
        if let secret, !secret.isEmpty {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-ssh-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let script = folder.appendingPathComponent("askpass.sh")
                try Data(askpassScript.utf8).write(to: script)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                askpassURL = script
                temporary = folder
            } catch {
                return CredentialTestOutcome(status: .failure, message: "Échec · préparation du test impossible : \(error.localizedDescription)")
            }
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        try? FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)

        var invocation = invocation(host: host, credential: credential, knownHosts: knownHosts, askpass: askpassURL,
                                    command: command, connectTimeout: connectTimeout)
        if let secret, askpassURL != nil { invocation.environment["NETSCOPE_SSH_SECRET"] = secret }
        let limit = TimeInterval(connectTimeout + 6)
        let start = Date()
        let result = await ProcessRunner.run(invocation.executable, invocation.arguments, environment: invocation.environment, timeout: limit)
        return analyze(exitCode: result.status, stdout: result.stdout, stderr: result.stderr, host: host,
                       milliseconds: Int(Date().timeIntervalSince(start) * 1000), timedOut: result.timedOut)
    }
}

/// Lancement d'un outil système avec délai (sortie standard et d'erreur lues jusqu'au bout).
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false))
                    return
                }
                let timedOut = OnceFlag()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning, timedOut.claim() { process.terminate() }
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                      stdout: String(decoding: stdout.prefix(64_000), as: UTF8.self),
                                                      stderr: String(decoding: stderr.prefix(64_000), as: UTF8.self),
                                                      timedOut: timedOut.isClaimed))
            }
        }
    }
}

// MARK: - WMI

/// macOS n'a pas de client WMI (DCOM) : le test vérifie seulement que les ports de WMI et de
/// WinRM répondent, sans s'authentifier.
public enum WMIReachabilityTest {
    public struct Port: Equatable, Sendable {
        public var number: UInt16
        public var label: String
    }

    public static let ports = [Port(number: 135, label: "DCOM/RPC (WMI)"), Port(number: 5985, label: "WinRM HTTP"),
                               Port(number: 5986, label: "WinRM HTTPS")]

    public static let limitation = "macOS n’a pas de client WMI natif : NetScope ne peut pas ouvrir de session WMI ni vérifier le mot de passe. Le test dit seulement si les ports de WMI (135) et de WinRM (5985, 5986) répondent."

    /// Bilan d'après l'état de chaque port (fonction pure, testée sans réseau).
    public static func analyze(host: String, states: [(Port, TCPProbeState)]) -> CredentialTestOutcome {
        let details = states.map { "\($0.0.number) · \($0.0.label) : \($0.1.label)" }
        let open = states.filter { if case .open = $0.1 { return true }; return false }.map { $0.0 }
        if !open.isEmpty {
            let list = open.map { "\($0.number) (\($0.label))" }.joined(separator: ", ")
            return CredentialTestOutcome(status: .partial,
                                         message: "Joignable · \(host) répond sur \(list). Authentification non vérifiée (pas de client WMI sous macOS).",
                                         details: details)
        }
        if states.contains(where: { $0.1.hostAnswered }) {
            return CredentialTestOutcome(status: .failure,
                                         message: "Échec · \(host) répond, mais ports 135, 5985 et 5986 fermés : WMI et WinRM inactifs ou bloqués par le pare-feu Windows.",
                                         details: details)
        }
        return CredentialTestOutcome(status: .failure,
                                     message: "Échec · aucune réponse de \(host) sur 135, 5985 et 5986 (hôte éteint, adresse incorrecte ou pare-feu).",
                                     details: details)
    }

    public static func run(host: IPv4Address, timeout: TimeInterval = 2) async -> CredentialTestOutcome {
        var states: [(Port, TCPProbeState)] = []
        for port in ports {
            states.append((port, await ScanPresenceProber.tcp(host, port: port.number, timeout: timeout)))
        }
        return analyze(host: host.description, states: states)
    }
}
