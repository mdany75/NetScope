import Foundation

/// Onglet SSH : /usr/bin/ssh de macOS lancé dans un pseudo-terminal (clés et agent de ~/.ssh,
/// ~/.ssh/known_hosts et ~/.ssh/config, comme dans Terminal).
///
/// - Serveur inconnu : ssh affiche l'empreinte de sa clé et demande « yes/no » dans l'onglet ;
///   NetScope montre en plus un bandeau « Accepter / Refuser » (`SSHPromptDetector`).
/// - Mot de passe enregistré au Trousseau : remis à ssh par SSH_ASKPASS. Le script ne contient
///   aucun secret ; le mot de passe passe par un tube nommé à usage unique (`SSHSecretChannel`,
///   0600 dans un dossier 0700), jamais par l'environnement, le disque ni la ligne de commande. Il
///   n'est donné qu'une fois, et seulement à une invite qui nomme « utilisateur@hôte » de la
///   connexion (jamais au serveur de rebond d'un ProxyJump) ; ensuite, ssh le demande dans l'onglet.
public enum SSHTerminalCommand {
    public static let sshPath = "/usr/bin/ssh"

    /// Arguments de ssh : options, puis « -- » et la destination (jamais lue comme une option).
    public static func arguments(user: String, host: String, port: Int, keyPath: String? = nil,
                                 serverAliveInterval: Int = 30) -> [String] {
        var args = [
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=\(serverAliveInterval)",
            "-o", "ServerAliveCountMax=4",
            "-o", "StrictHostKeyChecking=ask",
        ]
        if let keyPath, !keyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-i", (keyPath as NSString).expandingTildeInPath]
        }
        if port != 22 { args += ["-p", String(port)] }
        let user = user.trimmingCharacters(in: .whitespaces)
        args += ["--", user.isEmpty ? host : user + "@" + host]
        return args
    }

    /// Environnement du processus ssh : terminal xterm-256color, script SSH_ASKPASS forcé (toutes
    /// les questions de ssh passent par lui, et il les pose dans l'onglet), chemin du tube du secret
    /// (`secretPipe`, jamais le secret lui-même) et invite attendue (`expect` : « utilisateur@hôte »).
    public static func environment(base: [String: String], askpass: String, secretPipe: String?, expect: String,
                                   flag: String) -> [String: String] {
        var env = base
        for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "NETSCOPE_SSH_SECRET", "NETSCOPE_SSH_FIFO", "NETSCOPE_SSH_EXPECT",
                    "NETSCOPE_SSH_FLAG", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"] {
            env[key] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = base["LANG"] ?? "fr_CA.UTF-8"
        env["SSH_ASKPASS"] = askpass
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = base["DISPLAY"] ?? ":0"
        env["NETSCOPE_SSH_FLAG"] = flag
        if let secretPipe, !secretPipe.isEmpty, !expect.isEmpty {
            env["NETSCOPE_SSH_FIFO"] = secretPipe
            env["NETSCOPE_SSH_EXPECT"] = expect
        }
        return env
    }

    /// « utilisateur@hôte » que l'invite de mot de passe de ssh doit nommer (« admin@10.0.0.2's
    /// password: », « (admin@10.0.0.2) Password: ») ; sans utilisateur, celui du Mac.
    public static func expectedPrompt(user: String, host: String, localUser: String = NSUserName()) -> String {
        let user = user.trimmingCharacters(in: .whitespaces)
        return (user.isEmpty ? localUser : user) + "@" + host
    }

    /// Script SSH_ASKPASS (aucun secret dedans). Ses entrée et sortie d'erreur sont le
    /// pseudo-terminal de l'onglet : les questions de ssh s'y affichent et la réponse y est tapée.
    /// Mot de passe du Trousseau : donné à la première demande de mot de passe qui nomme
    /// « utilisateur@hôte » de la connexion seulement (le fichier témoin, vide, est créé à ce moment),
    /// lu dans le tube à usage unique ; ensuite, la saisie est demandée dans l'onglet.
    public static let askpassScript = """
    #!/bin/sh
    # NetScope : réponses aux questions de ssh dans l'onglet de terminal. Aucun secret ici.
    case "$1" in
      *"continue connecting"*|*"(yes/no"*)
        printf '%s ' "$1" >&2
        IFS= read -r answer
        printf '%s\\n' "$answer"
        ;;
      *assword*|*ASSWORD*)
        expected=0
        if [ -n "$NETSCOPE_SSH_EXPECT" ]; then
          case "$1" in *"$NETSCOPE_SSH_EXPECT"*) expected=1 ;; esac
        fi
        if [ "$expected" = 1 ] && [ -n "$NETSCOPE_SSH_FIFO" ] && [ -p "$NETSCOPE_SSH_FIFO" ] \\
           && [ -n "$NETSCOPE_SSH_FLAG" ] && [ ! -e "$NETSCOPE_SSH_FLAG" ]; then
          : > "$NETSCOPE_SSH_FLAG"
          IFS= read -r secret < "$NETSCOPE_SSH_FIFO"
          printf '%s\\n' "$secret"
        else
          printf '%s' "$1" >&2
          stty -echo 2>/dev/null
          IFS= read -r answer
          stty echo 2>/dev/null
          printf '\\n' >&2
          printf '%s\\n' "$answer"
        fi
        ;;
      *)
        printf '%s' "$1" >&2
        stty -echo 2>/dev/null
        IFS= read -r answer
        stty echo 2>/dev/null
        printf '\\n' >&2
        printf '%s\\n' "$answer"
        ;;
    esac
    """ + "\n"

    /// Dossier privé (0700) du script et des fichiers témoins.
    public static var controlDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nsterm", isDirectory: true)
    }

    /// Écrit le script (0700) s'il manque ou a changé ; renvoie son chemin.
    public static func writeAskpass(in directory: URL = controlDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("askpass.sh")
        if (try? String(contentsOf: url, encoding: .utf8)) != askpassScript {
            try askpassScript.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Ligne de commande affichée (jamais de secret) : « ssh -p 2222 -- admin@10.0.0.2 ».
    public static func displayCommand(user: String, host: String, port: Int) -> String {
        var words = ["ssh"]
        if port != 22 { words += ["-p", String(port)] }
        words += ["--", user.isEmpty ? host : user + "@" + host]
        return words.joined(separator: " ")
    }
}

/// Tube nommé à usage unique (0600, dossier 0700) par lequel le script SSH_ASKPASS lit le mot de
/// passe : écrit une seule fois quand le script l'ouvre, puis supprimé. Rien dans l'environnement
/// de ssh ni de ses sous-processus (ProxyCommand, LocalCommand…), rien sur le disque.
public final class SSHSecretChannel: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()
    private var secret: String?

    public init(directory: URL, secret: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("secret-" + UUID().uuidString).path
        guard mkfifo(path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.secret = secret
        let path = self.path
        // Attend un lecteur (le script) sans bloquer : ENXIO tant que personne n'a ouvert le tube ;
        // au plus dix minutes (question d'empreinte laissée sans réponse), puis le secret est oublié.
        let deadline = Date().addingTimeInterval(600)
        DispatchQueue.global(qos: .utility).async { [self] in
            while Date() < deadline, let value = lock.withLock({ self.secret }) {
                let fd = open(path, O_WRONLY | O_NONBLOCK)
                if fd < 0 {
                    if errno == ENXIO {
                        usleep(100_000)
                        continue
                    }
                    break
                }
                _ = fcntl(fd, F_SETFL, 0)
                let bytes = Array((value + "\n").utf8)
                _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                close(fd)
                break
            }
            cancel()
        }
    }

    deinit { cancel() }

    /// Oublie le secret et supprime le tube (session fermée, remplacée ou secret déjà lu).
    public func cancel() {
        let had = lock.withLock { () -> Bool in
            defer { secret = nil }
            return secret != nil
        }
        if had || FileManager.default.fileExists(atPath: path) { unlink(path) }
    }
}

/// Lecture de la sortie de ssh pour les bandeaux de l'onglet (texte brut, sans séquences).
public enum SSHPromptDetector {
    public enum Finding: Equatable, Sendable {
        /// Serveur inconnu : ssh demande s'il faut l'accepter.
        case unknownHost(fingerprint: String, keyType: String?)
        /// Clé du serveur changée : connexion refusée par ssh (possible interception).
        case hostKeyChanged
        case authenticationFailed
        case connectionRefused
        case timeout
        case hostNotFound
    }

    /// Ce que la fin de la sortie montre (les 4 derniers kilo-octets suffisent).
    public static func scan(_ text: String) -> Finding? {
        let lower = text.lowercased()
        if lower.contains("remote host identification has changed") { return .hostKeyChanged }
        if let range = text.range(of: "are you sure you want to continue connecting", options: [.caseInsensitive, .backwards]) {
            // Seule une question encore sans réponse compte (rien d'autre n'a suivi).
            if !text[range.upperBound...].contains("\n") {
                return .unknownHost(fingerprint: SFTPOutput.fingerprint(in: text) ?? "inconnue", keyType: keyType(in: text))
            }
        }
        if lower.contains("permission denied (") || lower.contains("too many authentication failures") { return .authenticationFailed }
        if lower.contains("connection refused") { return .connectionRefused }
        if lower.contains("operation timed out") || lower.contains("connection timed out") { return .timeout }
        if lower.contains("could not resolve hostname") { return .hostNotFound }
        return nil
    }

    /// « ED25519 key fingerprint is … » → « ED25519 ».
    static func keyType(in text: String) -> String? {
        guard let range = text.range(of: " key fingerprint is", options: .backwards) else { return nil }
        let before = text[..<range.lowerBound]
        let word = before.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init)
        return word?.isEmpty == false ? word : nil
    }
}
