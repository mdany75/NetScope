import Foundation

/// Onglet SSH : /usr/bin/ssh de macOS lancé dans un pseudo-terminal (clés et agent de ~/.ssh,
/// ~/.ssh/known_hosts et ~/.ssh/config, comme dans Terminal).
///
/// - Serveur inconnu : ssh affiche l'empreinte de sa clé et demande « yes/no » dans l'onglet ;
///   NetScope montre en plus un bandeau « Accepter / Refuser » (`SSHPromptDetector`).
/// - Mot de passe enregistré au Trousseau : remis à ssh par SSH_ASKPASS. Le script ne contient
///   aucun secret ; le mot de passe ne passe que par l'environnement du processus ssh, jamais par le
///   disque ni la ligne de commande, et il n'est donné qu'une fois (puis ssh le redemande dans l'onglet).
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
    /// les questions de ssh passent par lui, et il les pose dans l'onglet), secret éventuel.
    public static func environment(base: [String: String], askpass: String, secret: String?, flag: String) -> [String: String] {
        var env = base
        for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "NETSCOPE_SSH_SECRET", "NETSCOPE_SSH_FLAG", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"] {
            env[key] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = base["LANG"] ?? "fr_CA.UTF-8"
        env["SSH_ASKPASS"] = askpass
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = base["DISPLAY"] ?? ":0"
        env["NETSCOPE_SSH_FLAG"] = flag
        if let secret, !secret.isEmpty { env["NETSCOPE_SSH_SECRET"] = secret }
        return env
    }

    /// Script SSH_ASKPASS (aucun secret dedans). Ses entrée et sortie d'erreur sont le
    /// pseudo-terminal de l'onglet : les questions de ssh s'y affichent et la réponse y est tapée.
    /// Mot de passe du Trousseau : donné à la première demande de mot de passe seulement (le
    /// fichier témoin, vide, est créé à ce moment) ; ensuite, la saisie est demandée dans l'onglet.
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
        if [ -n "$NETSCOPE_SSH_SECRET" ] && [ -n "$NETSCOPE_SSH_FLAG" ] && [ ! -e "$NETSCOPE_SSH_FLAG" ]; then
          : > "$NETSCOPE_SSH_FLAG"
          printf '%s\\n' "$NETSCOPE_SSH_SECRET"
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
