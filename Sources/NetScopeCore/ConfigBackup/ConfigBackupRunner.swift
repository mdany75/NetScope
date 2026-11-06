import Foundation

// Note 40 (0.31.0) : lecture de la configuration. FortiGate : un seul GET de l'API REST avec le
// jeton du site. Switchs : /usr/bin/ssh, commandes de lecture seulement, mot de passe du
// Trousseau remis par le tube à usage unique de SSH_ASKPASS (comme le serveur RustDesk).

/// Compte SSH d'un équipement (sans secret).
public struct ConfigSSHTarget: Hashable, Sendable {
    public var user: String
    public var host: String
    public var port: Int
    public var keyPath: String

    public init(user: String, host: String, port: Int = 22, keyPath: String = "") {
        self.user = user.trimmingCharacters(in: .whitespaces)
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.port = port
        self.keyPath = keyPath.trimmingCharacters(in: .whitespaces)
    }

    public init(credential: RemoteCredential, host: String) {
        self.init(user: credential.user, host: host, port: Int(credential.port),
                  keyPath: credential.sshMethod == .key ? credential.keyPath : "")
    }

    /// Hôte et utilisateur sans espace ni tiret initial (jamais lus comme une option de ssh).
    public var isValid: Bool {
        let bad = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "@/\\;'\"`$"))
        return !host.isEmpty && !host.hasPrefix("-") && host.rangeOfCharacter(from: bad) == nil
            && !user.isEmpty && !user.hasPrefix("-") && user.rangeOfCharacter(from: bad) == nil
            && (1...65_535).contains(port)
    }

    public var destination: String { user + "@" + host }
}

/// Commande ssh de la sauvegarde (pure, testée) et lancement.
public enum ConfigBackupSSH {
    public static let executable = "/usr/bin/ssh"
    public static let connectTimeout = 10
    public static let totalTimeout: TimeInterval = 90

    /// Arguments de ssh : options, « -- », la destination et, sauf pour Cisco (commandes sur
    /// l'entrée d'un shell), la commande de lecture. Serveur inconnu refusé tant que l'utilisateur
    /// n'a pas accepté son empreinte (`acceptNewHostKey`) ; clé changée : toujours refusée.
    public static func arguments(_ target: ConfigSSHTarget, kind: ConfigDeviceKind, acceptNewHostKey: Bool = false) -> [String] {
        var args = [
            "-T",
            "-o", "BatchMode=no",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "StrictHostKeyChecking=\(acceptNewHostKey ? "accept-new" : "ask")",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "RequestTTY=no",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            // Vieux switchs : algorithmes encore acceptés par l'équipement.
            "-o", "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1",
            "-o", "HostKeyAlgorithms=+ssh-rsa",
            "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
        ]
        if !target.keyPath.isEmpty {
            args += ["-i", (target.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        if target.port != 22 { args += ["-p", String(target.port)] }
        args += ["--", target.destination]
        if !kind.usesShellInput, let command = kind.sshCommands.first { args.append(command) }
        return args
    }

    /// Entrée standard : les commandes de Cisco, une par ligne ; rien pour les autres.
    public static func input(for kind: ConfigDeviceKind) -> Data? {
        kind.usesShellInput ? Data(kind.sshCommands.map { $0 + "\n" }.joined().utf8) : nil
    }

    /// Lit la configuration. Refuse tout type dont une commande ne serait pas en lecture seule.
    public static func run(_ target: ConfigSSHTarget, kind: ConfigDeviceKind, secret: String?,
                           acceptNewHostKey: Bool = false, timeout: TimeInterval = totalTimeout) async -> Result<String, ConfigBackupError> {
        guard !kind.usesAPI else { return .failure(ConfigBackupError(kind: .unknownKind, detail: "La FortiGate se sauvegarde par l’API.")) }
        guard ConfigBackupCommands.allReadOnly(kind) else {
            return .failure(ConfigBackupError(kind: .notReadOnly, detail: kind.sshCommands.joined(separator: " ; ")))
        }
        guard target.isValid else {
            return .failure(ConfigBackupError(kind: .account, detail: "Utilisateur ou adresse SSH invalide."))
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(ConfigBackupError(kind: .launch, detail: "/usr/bin/ssh introuvable sur ce Mac."))
        }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nscfg-" + UUID().uuidString.prefix(8), isDirectory: true)
        let askpass: URL
        let channel: SSHSecretChannel?
        do {
            askpass = try RustDeskServerSSH.writeAskpass(in: folder)
            channel = try secret.flatMap { $0.isEmpty ? nil : try SSHSecretChannel(directory: folder, secret: $0) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return .failure(ConfigBackupError(kind: .launch, detail: "Préparation impossible\u{00A0}: \(error.localizedDescription)"))
        }
        defer {
            channel?.cancel()
            try? FileManager.default.removeItem(at: folder)
        }
        let env = RustDeskServerSSH.environment(askpass: askpass, secretPipe: channel?.path,
                                                expect: SSHTerminalCommand.expectedPrompt(user: target.user, host: target.host),
                                                flag: folder.appendingPathComponent("drapeau").path)
        let result = await ProcessRunner.run(executable, arguments(target, kind: kind, acceptNewHostKey: acceptNewHostKey),
                                             environment: env, timeout: timeout, input: input(for: kind), outputLimit: 8_000_000)
        return interpret(status: result.status, stdout: result.stdout, stderr: result.stderr, timedOut: result.timedOut,
                         host: target.host, kind: kind)
    }

    /// Sortie de ssh → configuration nettoyée, ou erreur expliquée.
    public static func interpret(status: Int32, stdout: String, stderr: String, timedOut: Bool, host: String,
                                 kind: ConfigDeviceKind) -> Result<String, ConfigBackupError> {
        let lower = stderr.lowercased()
        if status == 255 || (stdout.isEmpty && !stderr.isEmpty && !timedOut) {
            if !lower.contains("remote host identification has changed"),
               lower.contains("continue connecting") || lower.contains("host key verification failed") {
                let fingerprint = SFTPOutput.fingerprint(in: stderr)
                return .failure(ConfigBackupError(kind: .unknownHostKey,
                                                  detail: "Empreinte présentée par \(host)\u{00A0}: \(fingerprint ?? "inconnue")",
                                                  fingerprint: fingerprint))
            }
            if lower.contains("remote host identification has changed") {
                return .failure(ConfigBackupError(kind: .hostKey, detail: "La clé SSH de \(host) a changé."))
            }
            if lower.contains("permission denied") || lower.contains("too many authentication failures") {
                return .failure(ConfigBackupError(kind: .authentication, detail: "Authentification refusée par \(host)."))
            }
            if lower.contains("timed out") {
                return .failure(ConfigBackupError(kind: .timeout, detail: "Aucune réponse de \(host) dans le délai."))
            }
            if status == 255 {
                let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                return .failure(ConfigBackupError(kind: .unreachable, detail: last.isEmpty ? "Connexion à \(host) impossible." : String(last.prefix(200))))
            }
        }
        let text = ConfigText.cleanOutput(stdout, kind: kind)
        if let error = ConfigText.cliError(in: text), text.split(whereSeparator: \.isNewline).count < 15 {
            return .failure(ConfigBackupError(kind: .commandRejected, detail: error))
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if timedOut { return .failure(ConfigBackupError(kind: .timeout, detail: "Aucune réponse de \(host) dans le délai.")) }
            if status < 0 { return .failure(ConfigBackupError(kind: .launch, detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines))) }
            return .failure(ConfigBackupError(kind: .emptyOutput, detail: "Aucune configuration reçue de \(host)."))
        }
        // Délai dépassé au milieu de la lecture : une configuration tronquée n'est pas gardée.
        if timedOut { return .failure(ConfigBackupError(kind: .timeout, detail: "Lecture de \(host) interrompue (délai dépassé).")) }
        return .success(text)
    }
}

/// Sauvegarde d'une FortiGate par l'API REST (GET seulement).
public enum ConfigBackupFortiGate {
    public static let path = "/api/v2/monitor/system/config/backup"
    public static let query = [URLQueryItem(name: "scope", value: "global")]

    public static func fetch(transport: FortiTransport, token: String?) async -> Result<String, ConfigBackupError> {
        do {
            let response = try await transport.get(path, query: query)
            return interpret(response, token: token)
        } catch let error as FortiGateError {
            let detail = FortiRedact.clean(error.errorDescription ?? "Lecture impossible.", token: token)
            return .failure(ConfigBackupError(kind: .api, detail: detail))
        } catch is CancellationError {
            return .failure(ConfigBackupError(kind: .api, detail: "Lecture annulée."))
        } catch {
            return .failure(ConfigBackupError(kind: .api, detail: "Lecture impossible."))
        }
    }

    /// Réponse de l'API → configuration, ou message clair (profil du jeton, version de FortiOS).
    public static func interpret(_ response: FortiHTTPResponse, token: String?) -> Result<String, ConfigBackupError> {
        let text = String(decoding: response.body, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch response.status {
        case 401, 403:
            return .failure(ConfigBackupError(kind: .forbidden, detail: "La FortiGate refuse la sauvegarde à ce jeton (HTTP \(response.status))."))
        case 404, 405:
            return .failure(ConfigBackupError(kind: .apiUnsupported, detail: "Adresse de sauvegarde absente de cette FortiGate (HTTP \(response.status))."))
        case 200:
            if trimmed.hasPrefix("{") {
                // Erreur rendue en JSON avec un code 200 (« http_status »: 403…).
                let lower = trimmed.lowercased()
                if lower.contains("\"http_status\":403") || lower.contains("\"http_status\": 403") || lower.contains("permission") {
                    return .failure(ConfigBackupError(kind: .forbidden, detail: "La FortiGate refuse la sauvegarde à ce jeton."))
                }
                if lower.contains("\"http_status\":405") || lower.contains("\"http_status\": 405") || lower.contains("\"http_status\":404") {
                    return .failure(ConfigBackupError(kind: .apiUnsupported, detail: "Sauvegarde par GET non offerte par cette version de FortiOS."))
                }
                return .failure(ConfigBackupError(kind: .api, detail: FortiRedact.clean(String(trimmed.prefix(200)), token: token)))
            }
            guard trimmed.hasPrefix("#config-version") || trimmed.contains("config system global") else {
                return .failure(trimmed.isEmpty
                    ? ConfigBackupError(kind: .emptyOutput, detail: "La FortiGate a renvoyé une configuration vide.")
                    : ConfigBackupError(kind: .api, detail: "La réponse n’est pas une configuration FortiOS."))
            }
            return .success(ConfigText.lines(text).joined(separator: "\n"))
        default:
            return .failure(ConfigBackupError(kind: .api, detail: "Réponse HTTP \(response.status) de la FortiGate."))
        }
    }
}
