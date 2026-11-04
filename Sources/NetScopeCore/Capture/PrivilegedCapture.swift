import Darwin
import Foundation

/// Capture par /usr/sbin/tcpdump lancé une seule fois avec les droits d'administrateur
/// (« do shell script … with administrator privileges » : fenêtre d'autorisation de macOS).
///
/// La commande n'est faite que de valeurs fixes et validées : chemin de tcpdump, filtre choisi
/// parmi deux filtres fixes, nom d'interface `^[a-z0-9]+$`, durée entière bornée et dossier
/// temporaire de l'app (caractères sûrs seulement). tcpdump écrit la trame en hexadécimal
/// (`-xx`) dans un fichier lu au fur et à mesure ; un fichier « arreter » met fin à la capture.
public enum PrivilegedCapture {
    public enum Purpose: String, Sendable {
        /// Trames LLDP et CDP du switch voisin.
        case neighbors
        /// Réponses DHCP reçues par ce Mac (port UDP 68).
        case dhcp

        /// Filtre tcpdump fixe (jamais construit à partir d'une saisie).
        public var filter: String {
            switch self {
            case .neighbors: return "ether proto 0x88cc or ether dst 01:00:0c:cc:cc:cc"
            case .dhcp: return "udp dst port 68"
            }
        }
    }

    public static let tcpdumpPath = "/usr/sbin/tcpdump"
    public static let durationRange = 5...180
    public static let outputName = "capture.txt"
    public static let errorName = "tcpdump.txt"
    public static let stopName = "arreter"

    /// Chemin sûr pour la commande : absolu, caractères [A-Za-z0-9._-/], sans « .. ».
    public static func isSafePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains(".."), path.count < 512 else { return false }
        return path.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._-/".unicodeScalars.contains($0)
        }
    }

    /// Commande shell complète (exécutée par /bin/sh en root). Lève une erreur si une valeur est refusée.
    public static func shellCommand(interface: String, purpose: Purpose, seconds: Int, directory: String) throws -> String {
        guard CaptureInterfaceName.isValid(interface) else {
            throw ToolError.invalidInput("Nom d’interface refusé : « \(interface) ».")
        }
        guard durationRange.contains(seconds) else {
            throw ToolError.invalidInput("Durée de capture hors limites (\(durationRange.lowerBound) à \(durationRange.upperBound) s).")
        }
        let dir = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        guard isSafePath(dir) else { throw ToolError.invalidInput("Dossier de capture refusé.") }
        let output = "'\(dir)/\(outputName)'"
        let errors = "'\(dir)/\(errorName)'"
        let stop = "'\(dir)/\(stopName)'"
        return "\(tcpdumpPath) -i \(interface) -n -e -xx -l -s 1600 '\(purpose.filter)' >\(output) 2>\(errors) & p=$!; i=0; "
            + "while [ $i -lt \(seconds) ] && [ ! -e \(stop) ] && kill -0 $p 2>/dev/null; do sleep 1; i=$((i+1)); done; "
            + "kill $p 2>/dev/null; wait $p 2>/dev/null; exit 0"
    }

    /// Script AppleScript passé à osascript (en argument, sans passer par un shell).
    public static func appleScript(for command: String, prompt: String) throws -> String {
        let forbidden = CharacterSet(charactersIn: "\"\\\n\r")
        guard command.rangeOfCharacter(from: forbidden) == nil, prompt.rangeOfCharacter(from: forbidden) == nil else {
            throw ToolError.invalidInput("Commande de capture refusée.")
        }
        return "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    /// Message affiché dans la fenêtre d'autorisation de macOS.
    public static func prompt(for purpose: Purpose, interface: String) -> String {
        switch purpose {
        case .neighbors:
            return "NetScope veut écouter les trames LLDP et CDP sur \(interface) avec tcpdump (lecture seule, arrêt automatique)."
        case .dhcp:
            return "NetScope veut lire les réponses DHCP sur \(interface) avec tcpdump (lecture seule, arrêt automatique)."
        }
    }
}

/// Analyse de la sortie hexadécimale de tcpdump (`-e -xx`) :
///
///     10:21:33.123456 88:3a:30:9c:41:22 > 01:80:c2:00:00:0e, ethertype LLDP (0x88cc), length 344: LLDP, length 330
///     	0x0000:  0180 c200 000e 883a 309c 4122 88cc 0207
///     	0x0010:  0488 3a30 9c41 0004 0503 312f 3232 0602
public enum TcpdumpHexParser {
    /// Trames complètes du texte. Sans `includeLast`, la dernière trame (peut-être en cours
    /// d'écriture) est laissée de côté.
    public static func frames(from text: String, includeLast: Bool = true) -> [CapturedFrame] {
        var frames: [[UInt8]] = []
        var current: [UInt8]?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("0x"), let colon = trimmed.firstIndex(of: ":"), line.first == "\t" || line.first == " " {
                guard current != nil, let offset = Int(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colon], radix: 16),
                      offset == current!.count else {
                    // Ligne hors trame ou décalage incohérent : trame abandonnée.
                    current = nil
                    continue
                }
                var bytes: [UInt8] = []
                var valid = true
                for group in trimmed[trimmed.index(after: colon)...].split(separator: " ") {
                    guard group.count == 2 || group.count == 4, group.allSatisfy(\.isHexDigit) else {
                        // Colonne ASCII (-X) : fin des octets de la ligne.
                        if bytes.isEmpty { valid = false }
                        break
                    }
                    var index = group.startIndex
                    while index < group.endIndex {
                        let next = group.index(index, offsetBy: 2)
                        bytes.append(UInt8(group[index..<next], radix: 16)!)
                        index = next
                    }
                }
                if valid { current!.append(contentsOf: bytes) } else { current = nil }
            } else {
                // Nouvelle ligne d'en-tête : la trame précédente est complète.
                if let done = current, !done.isEmpty { frames.append(done) }
                current = []
            }
        }
        if includeLast, let done = current, !done.isEmpty { frames.append(done) }
        return frames.map { CapturedFrame(bytes: $0) }
    }

    /// tcpdump écrit « listening on en7, link-type EN10MB … » quand la capture commence.
    public static func isListening(_ errorText: String) -> Bool {
        errorText.contains("listening on")
    }

    /// Message d'erreur de tcpdump (lignes autres que « listening on » et le bilan final).
    public static func errorMessage(_ errorText: String) -> String? {
        let lines = errorText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            !line.isEmpty && !line.contains("listening on") && !line.contains("packets captured")
                && !line.contains("packets received by filter") && !line.contains("packets dropped by kernel")
                && !line.hasPrefix("tcpdump: verbose output suppressed")
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

/// Une capture privilégiée en cours : dossier temporaire, osascript, lecture de la sortie.
/// Ne lance rien tant que `start` n'est pas appelé.
public final class PrivilegedCaptureSession: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case finished
        case cancelled
        case failed(String)
    }

    public let interface: String
    public let purpose: PrivilegedCapture.Purpose
    public let seconds: Int
    public let directory: URL
    private let lock = NSLock()
    private var process: Process?

    public init(interface: String, purpose: PrivilegedCapture.Purpose, seconds: Int) throws {
        self.interface = interface
        self.purpose = purpose
        self.seconds = seconds
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directory = base.appendingPathComponent("netscope-capture-\(UUID().uuidString.lowercased())", isDirectory: true)
        // Validation complète avant de créer quoi que ce soit.
        _ = try PrivilegedCapture.shellCommand(interface: interface, purpose: purpose, seconds: seconds, directory: directory.path)
    }

    /// Lance osascript (fenêtre d'autorisation de macOS, puis tcpdump). `completion` est appelé
    /// à la fin de la capture, sur un fil quelconque.
    public func start(completion: @escaping @Sendable (Outcome) -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let command = try PrivilegedCapture.shellCommand(interface: interface, purpose: purpose, seconds: seconds, directory: directory.path)
        let script = try PrivilegedCapture.appleScript(for: command, prompt: PrivilegedCapture.prompt(for: purpose, interface: interface))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            if finished.terminationStatus == 0 {
                completion(.finished)
            } else if text.contains("-128") || text.localizedCaseInsensitiveContains("cancel") || text.localizedCaseInsensitiveContains("annul") {
                completion(.cancelled)
            } else {
                completion(.failed(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        lock.lock()
        self.process = process
        lock.unlock()
        try process.run()
    }

    /// Demande l'arrêt : le script voit le fichier « arreter » dans la seconde et arrête tcpdump.
    public func stop() {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(PrivilegedCapture.stopName).path, contents: Data())
    }

    /// Abandon pendant la fenêtre d'autorisation : osascript (processus de l'utilisateur) est
    /// arrêté et le fichier « arreter » est posé au cas où tcpdump aurait déjà démarré.
    public func cancel() {
        stop()
        lock.lock()
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    public var errorText: String {
        (try? String(contentsOf: directory.appendingPathComponent(PrivilegedCapture.errorName), encoding: .utf8)) ?? ""
    }

    public var isListening: Bool { TcpdumpHexParser.isListening(errorText) }

    /// Trames lues jusqu'ici (sans la dernière, peut-être incomplète, tant que `final` est faux).
    public func frames(final: Bool) -> [CapturedFrame] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(PrivilegedCapture.outputName), encoding: .utf8) else {
            return []
        }
        return TcpdumpHexParser.frames(from: text, includeLast: final)
    }

    /// Supprime le dossier temporaire (les fichiers de root y sont effaçables : le dossier est à nous).
    public func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
