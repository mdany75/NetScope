import Foundation
import Network

/// Mini serveur FTP temporaire (note 50) : un dossier du Mac offert aux appareils qui viennent
/// chercher leur fichier eux-mêmes (firmware d'un switch, configuration d'une borne), et serveur
/// local des tests (127.0.0.1). Jamais lancé tout seul ; un seul compte ; tout reste dans le dossier
/// partagé (aucun « ../ », aucun lien qui en sort) ; lecture seule par défaut. FTP en clair : à
/// réserver au réseau local, le temps d'un transfert.
public final class FTPMiniServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var root: URL
        public var port: UInt16
        /// Adresse d'écoute (« 127.0.0.1 », une IP du Mac) ; nil : toutes les interfaces.
        public var bindHost: String?
        public var user: String
        public var password: String
        public var allowWrite: Bool
        /// Réponse MLSD/MLST annoncée (FEAT) ; désactivée pour tester le repli sur LIST.
        public var offerMLSD: Bool
        /// EPSV accepté ; désactivé pour tester le repli sur PASV.
        public var offerEPSV: Bool

        public init(root: URL, port: UInt16 = 2121, bindHost: String? = nil, user: String = "netscope",
                    password: String, allowWrite: Bool = false, offerMLSD: Bool = true, offerEPSV: Bool = true) {
            self.root = root
            self.port = port
            self.bindHost = bindHost
            self.user = user
            self.password = password
            self.allowWrite = allowWrite
            self.offerMLSD = offerMLSD
            self.offerEPSV = offerEPSV
        }
    }

    /// Événement du journal (qui demande quoi).
    public struct Event: Sendable, Hashable {
        public var date: Date
        public var client: String
        public var text: String

        public init(date: Date, client: String, text: String) {
            self.date = date
            self.client = client
            self.text = text
        }
    }

    public let configuration: Configuration
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "netscope.ftp.serveur")
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: FTPMiniSession] = [:]
    private let onEvent: (@Sendable (Event) -> Void)?

    public init(configuration: Configuration, onEvent: (@Sendable (Event) -> Void)? = nil) {
        self.configuration = configuration
        self.onEvent = onEvent
    }

    /// Démarre l'écoute ; renvoie le port réel (utile avec le port 0 des tests).
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        if let bindHost = configuration.bindHost {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: port)
        }
        let listener = configuration.bindHost == nil ? try NWListener(using: parameters, on: port) : try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = FTPOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() {
                        continuation.resume(throwing: FileTransferError.connectionFailed("écoute impossible sur le port \(self.configuration.port) (\(error.localizedDescription))"))
                    }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let all = sessions.values
        sessions.removeAll()
        lock.unlock()
        for session in all { session.stop() }
    }

    private func accept(_ connection: NWConnection) {
        let client: String
        if case .hostPort(let host, _) = connection.endpoint { client = "\(host)" } else { client = "inconnu" }
        let session = FTPMiniSession(connection: connection, queue: queue, configuration: configuration, client: client) { [weak self] text in
            self?.onEvent?(Event(date: Date(), client: client, text: text))
        }
        setSession(session, active: true)
        Task {
            await session.run()
            self.setSession(session, active: false)
        }
    }

    private func setSession(_ session: FTPMiniSession, active: Bool) {
        lock.lock()
        sessions[ObjectIdentifier(session)] = active ? session : nil
        lock.unlock()
    }
}

/// Une connexion de contrôle du mini serveur.
final class FTPMiniSession: @unchecked Sendable {
    private let control: FTPConnectionStream
    private let queue: DispatchQueue
    private let configuration: FTPMiniServer.Configuration
    private let client: String
    private let report: (String) -> Void
    private var splitter = FTPLineSplitter()
    private var pending: [String] = []
    private var user: String?
    private var loggedIn = false
    private var cwd = "/"
    private var restOffset: Int64 = 0
    private var renameFrom: String?
    private var passive: FTPActiveListener?
    private var activeTarget: (host: String, port: Int)?
    private let rootPath: String

    init(connection: NWConnection, queue: DispatchQueue, configuration: FTPMiniServer.Configuration, client: String,
         report: @escaping (String) -> Void) {
        control = FTPConnectionStream(connection: connection, queue: queue)
        self.queue = queue
        self.configuration = configuration
        self.client = client
        self.report = report
        rootPath = configuration.root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func stop() {
        passive?.cancel()
        control.close()
    }

    func run() async {
        do {
            try await control.waitReady(timeout: 10)
            try await reply(220, "NetScope, serveur FTP temporaire")
            while true {
                guard let line = try await readLine() else { break }
                let parts = line.split(separator: " ", maxSplits: 1)
                guard let verb = parts.first?.uppercased() else { continue }
                let argument = parts.count > 1 ? String(parts[1]) : ""
                if try await !handle(verb, argument) { break }
            }
        } catch {
            // Client parti ou délai dépassé : la session se ferme.
        }
        stop()
    }

    private func readLine() async throws -> String? {
        while pending.isEmpty {
            guard let data = try await control.read(max: 8_192, timeout: 300) else { return nil }
            pending += splitter.append(data)
        }
        return pending.removeFirst()
    }

    private func reply(_ code: Int, _ text: String) async throws {
        try await control.write(Data("\(code) \(text)\r\n".utf8), timeout: 30)
    }

    // MARK: Commandes

    /// Renvoie false pour fermer la session.
    private func handle(_ verb: String, _ argument: String) async throws -> Bool {
        let open: Set<String> = ["USER", "PASS", "QUIT", "FEAT", "SYST", "NOOP", "OPTS", "AUTH"]
        if !loggedIn, !open.contains(verb) {
            try await reply(530, "Identifiez-vous d’abord.")
            return true
        }
        switch verb {
        case "USER":
            user = argument
            try await reply(331, "Mot de passe ?")
        case "PASS":
            if user == configuration.user, argument == configuration.password {
                loggedIn = true
                report("Connexion de \(user ?? "")")
                try await reply(230, "Bienvenue.")
            } else {
                report("Identification refusée (\(user ?? ""))")
                try await reply(530, "Login incorrect.")
            }
        case "AUTH":
            try await reply(502, "TLS non proposé par ce serveur temporaire.")
        case "SYST":
            try await reply(215, "UNIX Type: L8")
        case "FEAT":
            var lines = ["211-Features:", " UTF8", " SIZE", " REST STREAM", " MDTM"]
            if configuration.offerEPSV { lines.append(" EPSV") }
            if configuration.offerMLSD { lines.append(" MLST type*;size*;modify*;unix.mode*;") }
            lines.append("211 End")
            try await control.write(Data((lines.joined(separator: "\r\n") + "\r\n").utf8), timeout: 30)
        case "OPTS":
            try await reply(200, "OK")
        case "NOOP":
            try await reply(200, "OK")
        case "TYPE":
            try await reply(200, "Type " + argument)
        case "PWD", "XPWD":
            try await reply(257, "\"" + cwd.replacingOccurrences(of: "\"", with: "\"\"") + "\" est le dossier courant")
        case "CWD":
            let target = RemotePath.join(cwd, argument)
            guard let url = resolve(target), isDirectory(url) else {
                try await reply(550, "No such directory.")
                return true
            }
            cwd = target
            try await reply(250, "OK")
        case "CDUP":
            cwd = RemotePath.parent(cwd)
            try await reply(250, "OK")
        case "EPSV":
            guard configuration.offerEPSV else {
                try await reply(500, "EPSV non pris en charge.")
                return true
            }
            let port = try await openPassive()
            try await reply(229, "Entering Extended Passive Mode (|||\(port)|)")
        case "PASV":
            let port = try await openPassive()
            // Adresse du Mac telle que le client la voit (celle de la connexion de contrôle).
            let local = control.localIPv4() ?? configuration.bindHost ?? "127.0.0.1"
            let host = local.replacingOccurrences(of: ".", with: ",")
            try await reply(227, "Entering Passive Mode (\(host),\(port / 256),\(port % 256)).")
        case "PORT":
            let parts = argument.split(separator: ",", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 6, numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else {
                try await reply(501, "PORT illisible.")
                return true
            }
            let host = numbers[0...3].map(String.init).joined(separator: ".")
            guard acceptsActiveTarget(host: host, port: numbers[4] * 256 + numbers[5]) else {
                try await reply(504, "PORT refusé\u{00A0}: adresse différente de celle du client, ou port réservé.")
                return true
            }
            activeTarget = (host, numbers[4] * 256 + numbers[5])
            try await reply(200, "PORT OK")
        case "EPRT":
            guard let delimiter = argument.first else { try await reply(501, "EPRT illisible."); return true }
            let fields = argument.split(separator: delimiter, omittingEmptySubsequences: false)
            guard fields.count >= 4, let port = Int(fields[3]), (1...65535).contains(port) else {
                try await reply(501, "EPRT illisible.")
                return true
            }
            guard acceptsActiveTarget(host: String(fields[2]), port: port) else {
                try await reply(504, "EPRT refusé\u{00A0}: adresse différente de celle du client, ou port réservé.")
                return true
            }
            activeTarget = (String(fields[2]), port)
            try await reply(200, "EPRT OK")
        case "LIST", "NLST", "MLSD":
            let target = argument.hasPrefix("-") || argument.isEmpty ? cwd : RemotePath.join(cwd, argument)
            guard let url = resolve(target), isDirectory(url) else {
                try await reply(550, "No such directory.")
                return true
            }
            let listing = self.listing(url, verb: verb)
            try await sendData(Data(listing.utf8), opening: "Liste du dossier")
        case "SIZE":
            guard let url = resolve(RemotePath.join(cwd, argument)), !isDirectory(url),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                try await reply(550, "No such file.")
                return true
            }
            try await reply(213, size.stringValue)
        case "MDTM":
            guard let url = resolve(RemotePath.join(cwd, argument)),
                  let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                try await reply(550, "No such file.")
                return true
            }
            try await reply(213, Self.mlsdDate(date))
        case "REST":
            restOffset = Int64(argument) ?? 0
            try await reply(350, "Reprise à \(restOffset)")
        case "RETR":
            let path = RemotePath.join(cwd, argument)
            guard let url = resolve(path), !isDirectory(url), let handle = try? FileHandle(forReadingFrom: url) else {
                try await reply(550, "No such file.")
                return true
            }
            defer { try? handle.close() }
            if restOffset > 0 { try? handle.seek(toOffset: UInt64(restOffset)) }
            restOffset = 0
            report("Envoi de \(path)")
            try await sendFile(handle)
        case "STOR", "APPE":
            guard configuration.allowWrite else { try await reply(550, "Permission denied (lecture seule)."); return true }
            let path = RemotePath.join(cwd, argument)
            guard let url = resolve(path, mustExist: false), !isDirectory(url) else {
                try await reply(553, "Permission denied.")
                return true
            }
            let append = verb == "APPE" || restOffset > 0
            if !append || !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { try await reply(553, "Permission denied."); return true }
            defer { try? handle.close() }
            if restOffset > 0 { try handle.truncate(atOffset: UInt64(restOffset)) }
            _ = try? handle.seekToEnd()
            restOffset = 0
            report("Réception de \(path)")
            try await receiveFile(handle)
        case "MKD", "XMKD":
            guard configuration.allowWrite else { try await reply(550, "Permission denied."); return true }
            let path = RemotePath.join(cwd, argument)
            guard let url = resolve(path, mustExist: false),
                  (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)) != nil else {
                try await reply(550, "Création impossible.")
                return true
            }
            try await reply(257, "\"\(path)\" créé")
        case "RMD", "XRMD", "DELE":
            guard configuration.allowWrite else { try await reply(550, "Permission denied."); return true }
            let path = RemotePath.join(cwd, argument)
            guard path != "/", let url = resolve(path) else { try await reply(550, "No such file."); return true }
            if verb == "DELE", isDirectory(url) { try await reply(550, "C’est un dossier."); return true }
            if verb != "DELE" {
                let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                guard isDirectory(url), children.isEmpty else { try await reply(550, "Dossier non vide."); return true }
            }
            guard (try? FileManager.default.removeItem(at: url)) != nil else { try await reply(550, "Permission denied."); return true }
            try await reply(250, "Supprimé")
        case "RNFR":
            guard configuration.allowWrite else { try await reply(550, "Permission denied."); return true }
            let path = RemotePath.join(cwd, argument)
            guard resolve(path) != nil else { try await reply(550, "No such file."); return true }
            renameFrom = path
            try await reply(350, "Nouveau nom ?")
        case "RNTO":
            guard let from = renameFrom, let source = resolve(from),
                  let target = resolve(RemotePath.join(cwd, argument), mustExist: false),
                  (try? FileManager.default.moveItem(at: source, to: target)) != nil else {
                renameFrom = nil
                try await reply(553, "Renommage impossible.")
                return true
            }
            renameFrom = nil
            try await reply(250, "Renommé")
        case "ABOR":
            try await reply(226, "Rien à interrompre.")
        case "QUIT":
            try await reply(221, "Au revoir.")
            return false
        default:
            try await reply(502, "Commande non prise en charge.")
        }
        return true
    }

    // MARK: Fichiers

    /// Chemin virtuel → fichier réel, seulement s'il reste sous la racine (liens résolus).
    private func resolve(_ virtualPath: String, mustExist: Bool = true) -> URL? {
        let clean = RemotePath.normalize(virtualPath)
        guard !clean.contains("\0") else { return nil }
        let relative = clean == "/" ? "" : String(clean.dropFirst())
        let candidate = URL(fileURLWithPath: rootPath).appendingPathComponent(relative)
        let check: URL
        if mustExist {
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            check = candidate.resolvingSymlinksInPath()
        } else {
            // Fichier à créer : son dossier parent doit exister et rester sous la racine.
            check = candidate.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(candidate.lastPathComponent)
        }
        let path = check.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        return check
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    private func listing(_ url: URL, verb: String) -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        var lines: [String] = []
        for name in names {
            let item = url.appendingPathComponent(name)
            let attributes = (try? FileManager.default.attributesOfItem(atPath: item.path)) ?? [:]
            let directory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let date = attributes[.modificationDate] as? Date ?? Date()
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            switch verb {
            case "NLST":
                lines.append(name)
            case "MLSD":
                lines.append("type=\(directory ? "dir" : "file");size=\(size);modify=\(Self.mlsdDate(date));unix.mode=0\(String(mode, radix: 8)); \(name)")
            default:
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "MMM dd HH:mm"
                lines.append("\(directory ? "d" : "-")\(FTPListing.rwx(mode)) 1 netscope netscope \(String(size).leftPadded(12)) \(formatter.string(from: date)) \(name)")
            }
        }
        return lines.map { $0 + "\r\n" }.joined()
    }

    static func mlsdDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    // MARK: Données

    /// Contre le « rebond FTP » : le mode actif ne joint que le client lui-même, sur un port non réservé.
    private func acceptsActiveTarget(host: String, port: Int) -> Bool {
        guard (1024...65535).contains(port), let peer = control.remoteIPv4() else { return false }
        return host == peer
    }

    private func openPassive() async throws -> Int {
        passive?.cancel()
        let listener = try FTPActiveListener(localHost: configuration.bindHost ?? "0.0.0.0")
        // Seul le client de la connexion de contrôle peut ouvrir la connexion de données.
        listener.allowedPeer = control.remoteIPv4()
        passive = listener
        activeTarget = nil
        return try await listener.start(timeout: 10)
    }

    private func dataStream() async throws -> FTPByteStream {
        if let passive {
            self.passive = nil
            return try await passive.accept(timeout: 20)
        }
        guard let target = activeTarget, let raw = UInt16(exactly: target.port), let port = NWEndpoint.Port(rawValue: raw) else {
            throw FileTransferError.protocolViolation("Aucune connexion de données préparée")
        }
        activeTarget = nil
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        let stream = FTPConnectionStream(connection: connection, queue: queue)
        try await stream.waitReady(timeout: 10)
        return stream
    }

    private func sendData(_ data: Data, opening: String) async throws {
        try await reply(150, opening)
        do {
            let stream = try await dataStream()
            if !data.isEmpty { try await stream.write(data, timeout: 30) }
            await stream.finishSending(timeout: 30)
            try await reply(226, "Terminé")
        } catch {
            try await reply(425, "Connexion de données impossible.")
        }
    }

    private func sendFile(_ handle: FileHandle) async throws {
        try await reply(150, "Ouverture de la connexion de données")
        do {
            let stream = try await dataStream()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try await stream.write(chunk, timeout: 30)
            }
            // Le client lit tout avant la fermeture (sinon les derniers octets pouvaient se perdre).
            await stream.finishSending(timeout: 30)
            try await reply(226, "Transfert terminé")
        } catch {
            try await reply(426, "Transfert interrompu.")
        }
    }

    private func receiveFile(_ handle: FileHandle) async throws {
        try await reply(150, "Prêt à recevoir")
        do {
            let stream = try await dataStream()
            while let chunk = try await stream.read(max: 64 * 1024, timeout: 60) {
                if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
            }
            stream.close()
            try await reply(226, "Fichier reçu")
        } catch {
            try await reply(426, "Transfert interrompu.")
        }
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
