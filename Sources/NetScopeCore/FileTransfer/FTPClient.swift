import Darwin
import Foundation

/// Client FTP et FTPS (RFC 959, 2228, 2428, 3659, 4217), sans dépendance externe.
///
/// - Passif : EPSV, sinon PASV ; l'adresse annoncée par PASV est ignorée au profit de celle du
///   serveur (NAT mal réglé, et pas de connexion détournée vers un autre hôte).
/// - Actif : EPRT, sinon PORT ; le Mac écoute sur l'adresse qui mène au serveur (FTP en clair seulement).
/// - FTPS explicite (AUTH TLS) ou implicite (port 990), données chiffrées (PBSZ 0, PROT P) ;
///   certificat vérifié par macOS, ou accepté par son empreinte SHA-256 (certificat autosigné).
/// - Une opération à la fois ; après une coupure ou une annulation, la session est rouverte à
///   l'opération suivante (et un transfert reprend avec REST, ou APPE pour un envoi).
public final class FTPClient: RemoteFileTransfer, @unchecked Sendable {
    public let endpoint: FileTransferEndpoint
    /// Journal des commandes et réponses (mot de passe masqué), pour le diagnostic.
    private let logHandler: (@Sendable (String) -> Void)?
    private let lock = FileTransferSerialLock()

    // État de la session (modifié seulement sous `lock`).
    private var control: FTPByteStream?
    private var evaluator: FTPTrustEvaluator?
    private var splitter = FTPLineSplitter()
    private var parser = FTPReplyParser()
    private var pendingLines: [String] = []
    private var features: [String: String] = [:]
    private var home = "/"
    private var epsvFailed = false
    private var eprtFailed = false

    private static let chunk = 64 * 1024

    public init(endpoint: FileTransferEndpoint, log: (@Sendable (String) -> Void)? = nil) {
        self.endpoint = endpoint
        self.logHandler = log
    }

    private var isSecure: Bool { endpoint.proto == .ftps }
    private var timeout: TimeInterval { endpoint.timeout }

    /// Fonctions annoncées par le serveur (FEAT), après la connexion.
    public var serverFeatures: [String: String] { features }

    // MARK: RemoteFileTransfer

    public func connect() async throws -> String {
        try await lock.run { [self] in
            try await openSession()
            return home
        }
    }

    public func list(_ path: String) async throws -> [RemoteFileEntry] {
        try await lock.run { [self] in
            try await withSession {
                let directory = try RemotePath.validate(path)
                try await expect("CWD " + directory, [250])
                let useMLSD = features["MLST"] != nil
                let data = try await receiveData(command: useMLSD ? "MLSD" : "LIST", sink: nil, progress: nil)
                let text = FTPText.decode(data)
                let entries = useMLSD ? FTPListing.parseMLSD(text, directory: directory) : FTPListing.parseLIST(text, directory: directory)
                return entries.sorted(by: RemoteFileEntry.browserOrder)
            }
        }
    }

    public func size(of path: String) async throws -> Int64? {
        try await lock.run { [self] in
            try await withSession {
                let reply = try await command("SIZE " + RemotePath.validate(path))
                return FTPResponse.size(reply)
            }
        }
    }

    public func download(_ remotePath: String, to localURL: URL, resume: Bool, progress: @escaping FileTransferProgress) async throws {
        try await lock.run { [self] in
            try await withSession {
                let path = try RemotePath.validate(remotePath)
                let manager = FileManager.default
                var offset: Int64 = 0
                if resume, let attributes = try? manager.attributesOfItem(atPath: localURL.path),
                   let existing = attributes[.size] as? NSNumber {
                    offset = existing.int64Value
                }
                if offset == 0 || !manager.fileExists(atPath: localURL.path) {
                    offset = 0
                    guard manager.createFile(atPath: localURL.path, contents: nil) else {
                        throw FileTransferError.localFile("impossible de créer \(localURL.lastPathComponent)")
                    }
                }
                let handle: FileHandle
                do {
                    handle = try FileHandle(forWritingTo: localURL)
                    try handle.seekToEnd()
                } catch {
                    throw FileTransferError.localFile(error.localizedDescription)
                }
                defer { try? handle.close() }
                if offset > 0 {
                    let reply = try await command("REST \(offset)")
                    if reply.code != 350 {
                        // Reprise refusée : on repart de zéro.
                        try handle.truncate(atOffset: 0)
                        offset = 0
                    }
                }
                progress(offset)
                _ = try await receiveData(command: "RETR " + path, sink: { data in
                    do { try handle.write(contentsOf: data) } catch { throw FileTransferError.localFile(error.localizedDescription) }
                }, progress: { received in progress(offset + received) })
            }
        }
    }

    public func upload(_ localURL: URL, to remotePath: String, resume: Bool, progress: @escaping FileTransferProgress) async throws {
        try await lock.run { [self] in
            try await withSession {
                let path = try RemotePath.validate(remotePath)
                let handle: FileHandle
                do {
                    handle = try FileHandle(forReadingFrom: localURL)
                } catch {
                    throw FileTransferError.localFile(error.localizedDescription)
                }
                defer { try? handle.close() }
                var offset: Int64 = 0
                if resume, let remote = FTPResponse.size(try await command("SIZE " + path)), remote > 0 {
                    offset = remote
                    try handle.seek(toOffset: UInt64(offset))
                }
                progress(offset)
                try await sendData(command: (offset > 0 ? "APPE " : "STOR ") + path, source: handle) { sent in
                    progress(offset + sent)
                }
            }
        }
    }

    public func makeDirectory(_ path: String) async throws {
        try await lock.run { [self] in
            try await withSession { try await expect("MKD " + RemotePath.validate(path), [257, 250]) }
        }
    }

    public func rename(_ from: String, to: String) async throws {
        try await lock.run { [self] in
            try await withSession {
                try await expect("RNFR " + RemotePath.validate(from), [350])
                try await expect("RNTO " + RemotePath.validate(to), [250])
            }
        }
    }

    public func deleteFile(_ path: String) async throws {
        try await lock.run { [self] in
            try await withSession { try await expect("DELE " + RemotePath.validate(path), [250]) }
        }
    }

    public func removeDirectory(_ path: String) async throws {
        try await lock.run { [self] in
            try await withSession { try await expect("RMD " + RemotePath.validate(path), [250]) }
        }
    }

    public func close() async {
        _ = try? await lock.run { [self] in
            if control != nil {
                _ = try? await command("QUIT", timeout: 3)
            }
            dropSession()
        }
    }

    // MARK: Session

    /// Exécute `body` sur une session ouverte ; une erreur de transport ferme la session (elle sera
    /// rouverte à la prochaine opération).
    private func withSession<T>(_ body: () async throws -> T) async throws -> T {
        if control == nil { try await openSession() }
        do {
            return try await body()
        } catch let error as FileTransferError {
            switch error {
            case .server, .notFound, .permissionDenied, .invalidName, .localFile:
                break
            default:
                dropSession()
            }
            throw error
        } catch is CancellationError {
            dropSession()
            throw FileTransferError.cancelled
        } catch {
            dropSession()
            throw error
        }
    }

    private func openSession() async throws {
        dropSession()
        let evaluator = FTPTrustEvaluator(trustedSHA256: endpoint.settings.trustedCertificateSHA256)
        self.evaluator = evaluator
        let stream = FTPSessionStream(host: endpoint.host, port: endpoint.port, evaluator: evaluator)
        control = stream
        do {
            let implicit = isSecure && endpoint.settings.tlsMode == .implicit
            if implicit { try await stream.startTLS() }
            log("Connexion à \(endpoint.host):\(endpoint.port)\(implicit ? " (TLS implicite)" : "")")
            var banner = try await readReply()
            if banner.code == 120 { banner = try await readReply() }
            guard banner.code == 220 else { throw FileTransferError.server(banner.summary) }
            if isSecure, endpoint.settings.tlsMode == .explicit {
                let auth = try await command("AUTH TLS")
                guard auth.code == 234 else {
                    throw FileTransferError.tlsUnavailable("le serveur n’accepte pas AUTH TLS (\(auth.summary)). Essayez le TLS implicite (port 990) ou, à vos risques, le FTP non chiffré.")
                }
                try await stream.startTLS()
            }
            try await login()
            if isSecure {
                _ = try await command("PBSZ 0")
                let prot = try await command("PROT P")
                guard prot.isSuccess else {
                    throw FileTransferError.tlsUnavailable("le serveur refuse de chiffrer les données (\(prot.summary)).")
                }
            }
            let feat = try await command("FEAT")
            features = FTPResponse.features(feat)
            if features["UTF8"] != nil { _ = try? await command("OPTS UTF8 ON") }
            try await expect("TYPE I", [200])
            home = (try? FTPResponse.quotedPath(try await command("PWD"))) ?? "/"
            log("Session ouverte, dossier \(home)")
        } catch {
            dropSession()
            throw error
        }
    }

    private func login() async throws {
        let userReply = try await command("USER " + RemotePath.validate(endpoint.ftpUser))
        switch userReply.code {
        case 230:
            return
        case 331, 332:
            // Anonyme sans mot de passe : une adresse de courriel fictive, comme les autres clients.
            let secret = endpoint.secret.flatMap { $0.isEmpty ? nil : $0 } ?? (endpoint.ftpUser == "anonymous" ? "netscope@" : "")
            let passReply = try await command("PASS " + RemotePath.validate(secret.isEmpty ? " " : secret), mask: true)
            guard passReply.code == 230 || passReply.code == 202 else {
                throw FileTransferError.loginFailed(passReply.summary)
            }
        default:
            throw FileTransferError.loginFailed(userReply.summary)
        }
    }

    private func dropSession() {
        control?.close()
        control = nil
        splitter = FTPLineSplitter()
        parser = FTPReplyParser()
        pendingLines = []
    }

    // MARK: Commandes

    @discardableResult
    private func command(_ text: String, mask: Bool = false, timeout: TimeInterval? = nil) async throws -> FTPReply {
        guard let control else { throw FileTransferError.connectionFailed("session fermée") }
        log("> " + (mask ? text.split(separator: " ").first.map { $0 + " ••••••" } ?? "••••••" : text))
        try await control.write(Data((text + "\r\n").utf8), timeout: timeout ?? self.timeout)
        return try await readReply(timeout: timeout)
    }

    /// Envoie la commande et vérifie le code de la réponse.
    private func expect(_ text: String, _ codes: [Int]) async throws {
        let reply = try await command(text)
        guard codes.contains(reply.code) else { throw Self.error(for: reply, path: text.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "") }
    }

    private func readReply(timeout: TimeInterval? = nil) async throws -> FTPReply {
        guard let control else { throw FileTransferError.connectionFailed("session fermée") }
        while true {
            while !pendingLines.isEmpty {
                let line = pendingLines.removeFirst()
                if let reply = try parser.feed(line) {
                    log("< " + reply.summary)
                    if reply.code == 421 { throw FileTransferError.connectionFailed("le serveur ferme la session (\(reply.summary))") }
                    return reply
                }
            }
            guard let data = try await control.read(max: 16 * 1024, timeout: timeout ?? self.timeout) else {
                throw FileTransferError.connectionFailed("le serveur a fermé la connexion")
            }
            pendingLines += splitter.append(data)
        }
    }

    // MARK: Données

    /// Ouvre la connexion de données (passif) ou prépare l'écoute (actif).
    private func prepareData() async throws -> (stream: FTPByteStream?, listener: FTPActiveListener?) {
        // FTPS : toujours passif (en actif, le Mac devrait jouer le serveur TLS de la connexion de données).
        if endpoint.settings.dataMode == .active, !isSecure {
            let local = try FTPLocalAddress.address(toward: endpoint.host)
            let listener = try FTPActiveListener(localHost: local)
            let port = try await listener.start(timeout: timeout)
            var accepted = false
            if !eprtFailed || local.contains(":") {
                let reply = try await command(FTPResponse.extendedPortCommand(host: local, port: port))
                if reply.code == 200 { accepted = true } else { eprtFailed = true }
            }
            if !accepted {
                let reply = try await command(try FTPResponse.portCommand(host: local, port: port))
                guard reply.code == 200 else { listener.cancel(); throw Self.error(for: reply, path: "") }
            }
            return (nil, listener)
        }
        var port: Int?
        if !epsvFailed {
            let reply = try await command("EPSV")
            if reply.code == 229 { port = try FTPResponse.extendedPassivePort(reply) } else { epsvFailed = true }
        }
        if port == nil {
            let reply = try await command("PASV")
            port = try FTPResponse.passiveEndpoint(reply).port
        }
        guard let port, let evaluator else { throw FileTransferError.connectionFailed("session fermée") }
        let stream = FTPSessionStream(host: endpoint.host, port: port, evaluator: evaluator)
        if isSecure { try await stream.startTLS() }
        return (stream, nil)
    }

    /// Commande qui renvoie des données (LIST, MLSD, RETR) : lues jusqu'à la fin, puis réponse finale.
    /// Sans `sink`, les données sont renvoyées ; sinon elles lui sont passées au fil de l'eau.
    private func receiveData(command text: String, sink: ((Data) throws -> Void)?,
                             progress: ((Int64) -> Void)?) async throws -> Data {
        let prepared = try await prepareData()
        var stream = prepared.stream
        defer {
            stream?.close()
            prepared.listener?.cancel()
        }
        let start = try await command(text)
        guard start.isPreliminary else {
            throw Self.error(for: start, path: text.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "")
        }
        if let listener = prepared.listener { stream = try await listener.accept(timeout: timeout) }
        guard let data = stream else { throw FileTransferError.connectionFailed("connexion de données absente") }
        var collected = Data()
        var received: Int64 = 0
        var lastReport = Date.distantPast
        while true {
            if Task.isCancelled { throw FileTransferError.cancelled }
            guard let chunk = try await data.read(max: Self.chunk, timeout: max(timeout, 60)) else { break }
            if chunk.isEmpty { continue }
            received += Int64(chunk.count)
            if let sink { try sink(chunk) } else { collected.append(chunk) }
            if let progress, Date().timeIntervalSince(lastReport) > 0.2 {
                progress(received)
                lastReport = Date()
            }
        }
        data.close()
        stream = nil
        progress?(received)
        let end = try await readReply(timeout: max(timeout, 60))
        guard end.isSuccess else { throw Self.error(for: end, path: "") }
        return collected
    }

    /// Commande d'envoi (STOR, APPE) : le fichier part par la connexion de données.
    private func sendData(command text: String, source: FileHandle, progress: (Int64) -> Void) async throws {
        let prepared = try await prepareData()
        var stream = prepared.stream
        defer {
            stream?.close()
            prepared.listener?.cancel()
        }
        let start = try await command(text)
        guard start.isPreliminary else {
            throw Self.error(for: start, path: text.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "")
        }
        if let listener = prepared.listener { stream = try await listener.accept(timeout: timeout) }
        guard let data = stream else { throw FileTransferError.connectionFailed("connexion de données absente") }
        var sent: Int64 = 0
        var lastReport = Date.distantPast
        while true {
            if Task.isCancelled { throw FileTransferError.cancelled }
            let chunk: Data
            do {
                chunk = try source.read(upToCount: Self.chunk) ?? Data()
            } catch {
                throw FileTransferError.localFile(error.localizedDescription)
            }
            if chunk.isEmpty { break }
            try await data.write(chunk, timeout: max(timeout, 60))
            sent += Int64(chunk.count)
            if Date().timeIntervalSince(lastReport) > 0.2 {
                progress(sent)
                lastReport = Date()
            }
        }
        // Fin de l'envoi : la fermeture de la connexion de données marque la fin du fichier.
        data.close()
        stream = nil
        progress(sent)
        let end = try await readReply(timeout: max(timeout, 60))
        guard end.isSuccess else { throw Self.error(for: end, path: "") }
    }

    // MARK: Erreurs

    static func error(for reply: FTPReply, path: String) -> FileTransferError {
        let text = reply.text.lowercased()
        if reply.code == 530 { return .loginFailed(reply.summary) }
        if reply.code == 522 || reply.code == 534 || text.contains("session reuse") {
            return .tlsUnavailable("le serveur exige la reprise de la session TLS sur la connexion de données (\(reply.summary)), ce que macOS ne garantit pas. Désactivez « require_ssl_reuse » sur le serveur ou utilisez SFTP.")
        }
        if [550, 553, 450].contains(reply.code) {
            if text.contains("denied") || text.contains("permission") || text.contains("not allowed") || text.contains("refus") {
                return .permissionDenied(path.isEmpty ? reply.summary : path)
            }
            if text.contains("no such") || text.contains("not found") || text.contains("doesn't exist") || text.contains("does not exist") || text.contains("introuvable") {
                return .notFound(path.isEmpty ? reply.summary : path)
            }
        }
        if reply.code == 425 { return .connectionFailed("connexion de données impossible (\(reply.summary)). Essayez l’autre mode (passif ou actif).") }
        return .server(reply.summary)
    }

    private func log(_ line: String) {
        logHandler?(line)
    }
}

/// Adresse locale qui mène au serveur (mode actif) : un socket UDP « connecté » ne fait que
/// choisir la route, aucun paquet ne part.
public enum FTPLocalAddress {
    public static func address(toward host: String) throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "21", &hints, &result) == 0, let info = result else {
            throw FileTransferError.connectionFailed("adresse du serveur introuvable pour le mode actif")
        }
        defer { freeaddrinfo(result) }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw FileTransferError.connectionFailed("socket local impossible") }
        defer { Darwin.close(fd) }
        guard Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            throw FileTransferError.connectionFailed("aucune route vers le serveur")
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard status == 0 else { throw FileTransferError.connectionFailed("adresse locale introuvable") }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = local.sin_addr
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
