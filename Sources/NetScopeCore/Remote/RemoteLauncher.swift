import Foundation

/// Ce que « Connecter » doit faire ; l'exécution (NSWorkspace) se fait dans l'application.
public enum RemoteLaunchPlan: Equatable, Sendable {
    /// Ouvrir Terminal avec cette commande (fichier .command temporaire).
    case terminal(command: String)
    /// Ouvrir un fichier .rdp avec l'application de bureau à distance.
    case rdpFile(contents: String, fileName: String)
    /// Ouvrir une URL (vnc:// : Partage d'écran).
    case url(URL)

    /// Application qui s'ouvre.
    public var appName: String {
        switch self {
        case .terminal: return "Terminal"
        case .rdpFile: return "Windows App (Microsoft Remote Desktop)"
        case .url: return "Partage d’écran"
        }
    }

    /// Texte montré dans le panneau de détails.
    public var preview: String {
        switch self {
        case .terminal(let command): return command
        case .rdpFile(_, let fileName): return fileName
        case .url(let url): return url.absoluteString
        }
    }
}

/// Construction des commandes, fichiers et URL de connexion, à partir de champs validés.
public enum RemoteLauncher {
    /// Emplacements de telnet (retiré de macOS depuis 10.13 ; Homebrew : brew install telnet).
    public static let telnetPaths = ["/opt/homebrew/bin/telnet", "/usr/local/bin/telnet", "/usr/bin/telnet"]

    public static func findTelnet(fileManager: FileManager = .default) -> String? {
        telnetPaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Plan de lancement. `telnetPath` nil : nc sert de client Telnet minimal.
    public static func plan(for connection: RemoteConnection, telnetPath: String? = findTelnet()) throws -> RemoteLaunchPlan {
        let c = try connection.validated()
        switch c.proto {
        case .ssh:
            return .terminal(command: sshCommand(c))
        case .telnet:
            return .terminal(command: telnetCommand(c, telnetPath: telnetPath))
        case .serie:
            return .terminal(command: RemoteShell.command(["screen", c.host, String(c.port)]))
        case .rdp:
            return .rdpFile(contents: rdpFile(for: c), fileName: rdpFileName(for: c))
        case .vnc:
            return .url(try vncURL(for: c))
        }
    }

    /// « ssh -p 22 -l netadmin -- 10.182.122.2 » (« -- » : l'hôte ne peut pas être lu comme une option).
    public static func sshCommand(_ c: RemoteConnection) -> String {
        var words = ["ssh"]
        if c.port != 22 { words += ["-p", String(c.port)] }
        if !c.username.isEmpty { words += ["-l", c.username] }
        words += ["--", c.host]
        return RemoteShell.command(words)
    }

    /// « telnet -l manager 10.182.122.3 23 », ou « nc 10.182.122.3 23 » sans telnet installé.
    public static func telnetCommand(_ c: RemoteConnection, telnetPath: String?) -> String {
        guard let telnetPath else { return RemoteShell.command(["nc", c.host, String(c.port)]) }
        var words = [telnetPath == "/usr/bin/telnet" ? "telnet" : telnetPath]
        if !c.username.isEmpty { words += ["-l", c.username] }
        words += [c.host, String(c.port)]
        return RemoteShell.command(words)
    }

    /// Contenu d'un fichier .rdp (format Microsoft, lignes « clé:type:valeur » séparées par CRLF).
    /// Affichage : plein écran (« screen mode id:i:2 ») ou fenêtre (« :i:1 ») ajustée (résolution
    /// dynamique) ou de taille fixe (« desktopwidth », « desktopheight », réduite à la fenêtre au
    /// besoin par « smart sizing ») ; « use multimon:i:1 » pour tous les écrans.
    public static func rdpFile(for c: RemoteConnection) -> String {
        let address = c.host.contains(":") ? "[\(c.host)]" : c.host
        let display = c.display
        let fixedSize = display.mode == .window ? display.resolvedWindowSize : nil
        var lines = [
            "full address:s:\(address):\(c.port)",
            "prompt for credentials:i:1",
            "screen mode id:i:\(display.mode == .fullScreen ? 2 : 1)",
        ]
        if let fixedSize {
            lines += ["desktopwidth:i:\(fixedSize.width)", "desktopheight:i:\(fixedSize.height)"]
        }
        lines += [
            "use multimon:i:\(display.allMonitors ? 1 : 0)",
            "session bpp:i:32",
            "dynamic resolution:i:\(fixedSize == nil ? 1 : 0)",
            "smart sizing:i:1",
            "redirectclipboard:i:1",
            "redirectprinters:i:0",
            "drivestoredirect:s:",
            "audiomode:i:0",
            "authentication level:i:2",
            "enablecredsspsupport:i:1",
        ]
        if !c.username.isEmpty { lines.insert("username:s:\(c.username)", at: 1) }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// « SRV-FICHIERS.rdp » : nom de connexion limité à [A-Za-z0-9_-].
    public static func rdpFileName(for c: RemoteConnection) -> String {
        safeFileName(c.name, fallback: "connexion") + ".rdp"
    }

    /// vnc://utilisateur@hôte:port (Partage d'écran de macOS).
    public static func vncURL(for c: RemoteConnection) throws -> URL {
        var components = URLComponents()
        components.scheme = "vnc"
        if !c.username.isEmpty { components.user = c.username }
        components.host = c.host.contains(":") ? "[\(c.host)]" : c.host
        if c.port != 5900 { components.port = c.port }
        guard let url = components.url else { throw RemoteValidationError.invalidHost(c.host) }
        return url
    }

    /// Script .command ouvert par Terminal : il s'efface lui-même, puis lance la commande.
    public static func commandFile(command: String, title: String) -> String {
        """
        #!/bin/zsh
        rm -f -- "$0"
        printf '\\033]0;%s\\007' \(RemoteShell.quote(title))
        clear
        echo \(RemoteShell.quote("NetScope › " + command))
        \(command)
        """ + "\n"
    }

    /// Écrit un fichier temporaire (dossier NetScope du répertoire temporaire) et renvoie son URL.
    public static func writeTemporary(_ contents: String, fileName: String, executable: Bool = false,
                                      directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = directory.appendingPathComponent("NetScope-acces", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return url
    }

    static func safeFileName(_ name: String, fallback: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let folded = name.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr"))
        var result = String(folded.map { allowed.contains($0) ? $0 : "-" })
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? fallback : String(result.prefix(60))
    }
}

/// Ports série présents (/dev/cu.*), lus localement.
public enum RemoteSerialPorts {
    public static func list(directory: String = "/dev", fileManager: FileManager = .default) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("cu.") }
            .map { directory + "/" + $0 }
            .filter { (try? RemoteValidator.validateSerialDevice($0)) != nil }
            .sorted()
    }
}
