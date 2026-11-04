import Darwin
import Foundation

/// Capture par /usr/sbin/tcpdump lancé une seule fois avec les droits d'administrateur
/// (« do shell script … with administrator privileges » : fenêtre d'autorisation de macOS).
///
/// La commande n'est faite que de valeurs fixes et validées : chemin de tcpdump, filtre choisi
/// parmi deux filtres fixes, nom d'interface `^[a-z0-9]+$`, durée entière bornée, numéro
/// d'utilisateur et dossiers de chemins sûrs. tcpdump écrit la trame en hexadécimal
/// (`-tt -e -xx`) dans un fichier lu au fur et à mesure ; un fichier « arreter » met fin à la capture.
///
/// Root n'écrit jamais dans un dossier de l'utilisateur (un lien symbolique posé là lui ferait
/// écraser un fichier système) : il crée lui-même un dossier neuf dans /private/tmp (`mkdir`
/// échoue si le nom existe déjà, et le bit collant de /private/tmp empêche un autre compte de
/// le renommer), y écrit, puis le donne à l'utilisateur à la fin pour qu'il puisse l'effacer.
/// Le dossier de l'utilisateur ne sert qu'au fichier « arreter », que root se contente de tester.
public enum PrivilegedCapture {
    public enum Purpose: String, Sendable {
        /// Trames LLDP et CDP du switch voisin.
        case neighbors
        /// Réponses DHCP reçues par ce Mac (port UDP 68).
        case dhcp
        /// Capture de paquets (note 7) : fichier pcap, filtre saisi et validé (`packetShellCommand`).
        case packets

        /// Filtre tcpdump fixe (jamais construit à partir d'une saisie) ; vide pour `packets`.
        public var filter: String {
            switch self {
            case .neighbors: return "ether proto 0x88cc or ether dst 01:00:0c:cc:cc:cc"
            case .dhcp: return "udp dst port 68"
            case .packets: return ""
            }
        }
    }

    public static let tcpdumpPath = "/usr/sbin/tcpdump"
    public static let durationRange = 5...180
    public static let outputName = "capture.txt"
    public static let errorName = "tcpdump.txt"
    public static let stopName = "arreter"
    /// Préfixe obligatoire du dossier créé par root.
    public static let outputPrefix = "/private/tmp/netscope-capture-"

    /// Chemin sûr pour la commande : absolu, caractères [A-Za-z0-9._-/], sans « .. ».
    public static func isSafePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains(".."), path.count < 512 else { return false }
        return path.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._-/".unicodeScalars.contains($0)
        }
    }

    /// Dossier de sortie accepté : `outputPrefix` suivi de lettres minuscules, chiffres et tirets.
    public static func isSafeOutputDirectory(_ path: String) -> Bool {
        guard path.hasPrefix(outputPrefix), isSafePath(path) else { return false }
        let name = path.dropFirst(outputPrefix.count)
        return !name.isEmpty && name.count <= 64
            && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Commande shell complète (exécutée par /bin/sh en root). Lève une erreur si une valeur est refusée.
    /// - Parameters:
    ///   - directory: dossier de l'utilisateur, où l'app pose le fichier « arreter ».
    ///   - outputDirectory: dossier neuf créé par root (`isSafeOutputDirectory`).
    ///   - owner: numéro de l'utilisateur, à qui le dossier de sortie est donné à la fin.
    public static func shellCommand(interface: String, purpose: Purpose, seconds: Int, directory: String,
                                    outputDirectory: String, owner: UInt32) throws -> String {
        guard purpose != .packets else { throw ToolError.invalidInput("Capture de paquets\u{00A0}: commande dédiée.") }
        guard CaptureInterfaceName.isValid(interface) else {
            throw ToolError.invalidInput("Nom d’interface refusé\u{00A0}: « \(interface) ».")
        }
        guard durationRange.contains(seconds) else {
            throw ToolError.invalidInput("Durée de capture hors limites (\(durationRange.lowerBound) à \(durationRange.upperBound) s).")
        }
        let dir = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        guard isSafePath(dir) else { throw ToolError.invalidInput("Dossier de capture refusé.") }
        guard isSafeOutputDirectory(outputDirectory) else { throw ToolError.invalidInput("Dossier de sortie refusé.") }
        guard owner != 0 else { throw ToolError.invalidInput("Utilisateur refusé.") }
        let out = "'\(outputDirectory)'"
        let stop = "'\(dir)/\(stopName)'"
        return "umask 022; /bin/mkdir -m 755 \(out) || exit 1; "
            + "\(tcpdumpPath) -i \(interface) -n -tt -e -xx -l -s 1600 '\(purpose.filter)' "
            + ">\(out)/\(outputName) 2>\(out)/\(errorName) & p=$!; i=0; "
            + "while [ $i -lt \(seconds) ] && [ ! -e \(stop) ] && kill -0 $p 2>/dev/null; do sleep 1; i=$((i+1)); done; "
            + "kill $p 2>/dev/null; wait $p 2>/dev/null; /usr/sbin/chown -R \(owner) \(out); exit 0"
    }

    // MARK: Capture de paquets (note 7)

    public static let packetOutputName = "capture.pcap"
    public static let packetDurationRange = 5...3600
    public static let packetCountRange = 1...1_000_000
    /// Octets gardés par paquet (comme Wireshark par défaut, assez pour tous les en-têtes).
    public static let packetSnapLength = 65_535

    /// Commande de la capture de paquets : tcpdump écrit un fichier pcap (`-w`, paquet par paquet
    /// avec `-U`), s'arrête après `maxPackets` (`-c`), après `seconds` ou au fichier « arreter ».
    /// Le filtre saisi est validé (`CaptureFilterCompiler.isSafe` : aucune apostrophe, guillemet,
    /// barre oblique inverse, $ ni ;) puis passé entre apostrophes : il ne peut rien injecter.
    public static func packetShellCommand(interface: String, filter: String, seconds: Int, maxPackets: Int, promiscuous: Bool,
                                          directory: String, outputDirectory: String, owner: UInt32) throws -> String {
        guard CaptureInterfaceName.isValid(interface) else {
            throw ToolError.invalidInput("Nom d’interface refusé\u{00A0}: « \(interface) ».")
        }
        guard packetDurationRange.contains(seconds) else {
            throw ToolError.invalidInput("Durée de capture hors limites (\(packetDurationRange.lowerBound) à \(packetDurationRange.upperBound) s).")
        }
        guard packetCountRange.contains(maxPackets) else { throw ToolError.invalidInput("Nombre de paquets hors limites.") }
        let clean = CaptureFilterCompiler.normalized(filter)
        guard CaptureFilterCompiler.isSafe(clean), !clean.contains("'") else { throw ToolError.invalidInput("Filtre de capture refusé.") }
        let dir = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        guard isSafePath(dir) else { throw ToolError.invalidInput("Dossier de capture refusé.") }
        guard isSafeOutputDirectory(outputDirectory) else { throw ToolError.invalidInput("Dossier de sortie refusé.") }
        guard owner != 0 else { throw ToolError.invalidInput("Utilisateur refusé.") }
        let out = "'\(outputDirectory)'"
        let stop = "'\(dir)/\(stopName)'"
        let filterArgument = clean.isEmpty ? "" : " '\(clean)'"
        return "umask 022; /bin/mkdir -m 755 \(out) || exit 1; "
            + "\(tcpdumpPath) -i \(interface) -n -U\(promiscuous ? "" : " -p") -s \(packetSnapLength) -c \(maxPackets) "
            + "-w \(out)/\(packetOutputName)\(filterArgument) "
            + "2>\(out)/\(errorName) & p=$!; i=0; "
            + "while [ $i -lt \(seconds) ] && [ ! -e \(stop) ] && kill -0 $p 2>/dev/null; do sleep 1; i=$((i+1)); done; "
            + "kill $p 2>/dev/null; wait $p 2>/dev/null; /usr/sbin/chown -R \(owner) \(out); exit 0"
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
        case .packets:
            return "NetScope veut capturer les paquets de \(interface) avec tcpdump (lecture seule, arrêt automatique)."
        }
    }
}

/// Analyse de la sortie hexadécimale de tcpdump (`-tt -e -xx`). L'horodatage de la ligne
/// d'en-tête (secondes epoch avec `-tt`, ou « HH:MM:SS.ffffff » sans) devient la date de la trame :
///
///     1762183293.123456 88:3a:30:9c:41:22 > 01:80:c2:00:00:0e, ethertype LLDP (0x88cc), length 344: LLDP, length 330
///     	0x0000:  0180 c200 000e 883a 309c 4122 88cc 0207
///     	0x0010:  0488 3a30 9c41 0004 0503 312f 3232 0602
public enum TcpdumpHexParser {
    /// Trames complètes du texte. Sans `includeLast`, la dernière trame (peut-être en cours
    /// d'écriture) est laissée de côté.
    public static func frames(from text: String, includeLast: Bool = true, now: Date = Date()) -> [CapturedFrame] {
        var frames: [CapturedFrame] = []
        var current: [UInt8]?
        var currentDate: Date?
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
                if let done = current, !done.isEmpty { frames.append(CapturedFrame(bytes: done, date: currentDate)) }
                current = []
                currentDate = timestamp(of: trimmed, now: now)
            }
        }
        if includeLast, let done = current, !done.isEmpty { frames.append(CapturedFrame(bytes: done, date: currentDate)) }
        return frames
    }

    /// Horodatage en tête de ligne : « 1762183293.123456 » (`-tt`) ou « 10:21:33.123456 » (heure
    /// locale du jour de `now`, ou de la veille si cette heure est plus d'une heure dans le futur).
    public static func timestamp(of header: String, now: Date = Date()) -> Date? {
        guard let token = header.split(separator: " ", maxSplits: 1).first else { return nil }
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 {
            guard token.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), token.first != ".",
                  let seconds = Double(token), seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard parts.count == 3, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              parts[2].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let seconds = Double(parts[2]),
              (0..<24).contains(hours), (0..<60).contains(minutes), seconds >= 0, seconds < 61 else { return nil }
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        var date = midnight.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60) + seconds)
        if date.timeIntervalSince(now) > 3600, let previous = calendar.date(byAdding: .day, value: -1, to: date) { date = previous }
        return date
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
    /// Dossier de l'utilisateur (fichier « arreter »).
    public let directory: URL
    /// Dossier créé par root pour la sortie de tcpdump.
    public let outputDirectory: URL
    private let lock = NSLock()
    private var process: Process?
    private var startDate: Date?
    /// Vrai quand osascript a été arrêté par `cancel()` : le /bin/sh root qu'il a lancé n'est pas
    /// tué avec lui et peut encore tourner (jusqu'à `seconds`) en attendant le fichier « arreter ».
    private var runnerKilled = false

    /// Réglages de la capture de paquets (`purpose == .packets`).
    public struct PacketOptions: Sendable, Equatable {
        public var filter: String
        public var maxPackets: Int
        public var promiscuous: Bool

        public init(filter: String, maxPackets: Int, promiscuous: Bool) {
            self.filter = filter
            self.maxPackets = maxPackets
            self.promiscuous = promiscuous
        }
    }

    public let packetOptions: PacketOptions?

    /// Capture de paquets : tcpdump écrit un fichier pcap lu au fur et à mesure (`pcapBytes`).
    public convenience init(interface: String, packets options: PacketOptions, seconds: Int) throws {
        try self.init(interface: interface, purpose: .packets, seconds: seconds, options: options)
    }

    public convenience init(interface: String, purpose: PrivilegedCapture.Purpose, seconds: Int) throws {
        try self.init(interface: interface, purpose: purpose, seconds: seconds, options: nil)
    }

    private init(interface: String, purpose: PrivilegedCapture.Purpose, seconds: Int, options: PacketOptions?) throws {
        self.interface = interface
        self.purpose = purpose
        self.seconds = seconds
        packetOptions = options
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let id = UUID().uuidString.lowercased()
        directory = base.appendingPathComponent("netscope-capture-\(id)", isDirectory: true)
        outputDirectory = URL(fileURLWithPath: PrivilegedCapture.outputPrefix + id, isDirectory: true)
        // Validation complète avant de créer quoi que ce soit.
        _ = try command()
    }

    private func command() throws -> String {
        if let packetOptions {
            return try PrivilegedCapture.packetShellCommand(interface: interface, filter: packetOptions.filter, seconds: seconds,
                                                            maxPackets: packetOptions.maxPackets, promiscuous: packetOptions.promiscuous,
                                                            directory: directory.path, outputDirectory: outputDirectory.path, owner: getuid())
        }
        return try PrivilegedCapture.shellCommand(interface: interface, purpose: purpose, seconds: seconds, directory: directory.path,
                                                  outputDirectory: outputDirectory.path, owner: getuid())
    }

    /// Lance osascript (fenêtre d'autorisation de macOS, puis tcpdump). `completion` est appelé
    /// à la fin de la capture, sur un fil quelconque.
    public func start(completion: @escaping @Sendable (Outcome) -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let shell = try command()
        let script = try PrivilegedCapture.appleScript(for: shell, prompt: PrivilegedCapture.prompt(for: purpose, interface: interface))
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
        startDate = Date()
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
        if let running, running.isRunning { runnerKilled = true }
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    public var errorText: String {
        (try? String(contentsOf: outputDirectory.appendingPathComponent(PrivilegedCapture.errorName), encoding: .utf8)) ?? ""
    }

    public var isListening: Bool { TcpdumpHexParser.isListening(errorText) }

    /// Trames lues jusqu'ici (sans la dernière, peut-être incomplète, tant que `final` est faux).
    public func frames(final: Bool) -> [CapturedFrame] {
        guard let text = try? String(contentsOf: outputDirectory.appendingPathComponent(PrivilegedCapture.outputName), encoding: .utf8) else {
            return []
        }
        return TcpdumpHexParser.frames(from: text, includeLast: final)
    }

    /// Octets du fichier pcap écrits par tcpdump à partir de `offset` (lecture de la suite).
    public func pcapBytes(from offset: Int) -> [UInt8] {
        let url = outputDirectory.appendingPathComponent(PrivilegedCapture.packetOutputName)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return [UInt8](try handle.readToEnd() ?? Data())
        } catch {
            return []
        }
    }

    /// Supprime les dossiers temporaires (celui de root a été donné à l'utilisateur à la fin du script).
    ///
    /// Si osascript a été arrêté par `cancel()`, le script root peut encore tourner : le fichier
    /// « arreter » doit rester visible jusqu'à sa fin, et son dossier de sortie n'appartient à
    /// l'utilisateur qu'après le `chown` final. La suppression est alors repoussée au-delà de la
    /// durée maximale du script (`seconds` après le lancement, plus une marge).
    public func cleanup() {
        lock.lock()
        let killed = runnerKilled
        let started = startDate ?? Date()
        lock.unlock()
        let directory = directory
        let outputDirectory = outputDirectory
        let remove: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        guard killed else { remove(); return }
        let deadline = started.addingTimeInterval(TimeInterval(seconds) + Self.cleanupMargin)
        let delay = max(Self.cleanupMargin, deadline.timeIntervalSinceNow)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: remove)
    }

    /// Marge après la durée maximale du script root avant d'effacer ses fichiers (secondes).
    static let cleanupMargin: TimeInterval = 10
}
