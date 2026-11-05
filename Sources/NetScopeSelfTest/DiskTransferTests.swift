import Foundation
import NetScopeCore

// Note 78 : Vitesse des disques en FTP, FTPS et SFTP. Réglages de connexion et liste des
// emplacements (données fixes), un faux client de transfert (confiance, dossier déjà présent,
// arrêt et nettoyage), puis un vrai test sur le mini serveur FTP de NetScope, sur 127.0.0.1.

func registerDiskTransferTests(_ suite: TestSuite) {
    suite.add("Disques en FTP/SFTP : connexion, Trousseau et carte de l’emplacement") {
        let siteKey = "siege"
        var sftp = DiskShareLocation(siteKey: siteKey, name: "NAS SFTP", kind: .sftp, server: "nas-bureau.local", share: "/volume1/essais",
                                     user: "technicien", hasPassword: true)
        let withPassword = sftp.transferEndpoint(secret: "s3cret")
        try expectEqual(withPassword?.proto, .sftp, "SFTP")
        try expectEqual(withPassword?.port, 22, "port 22 par défaut")
        try expectEqual(withPassword?.settings.sftpAuth, .password, "mot de passe du Trousseau")
        try expectEqual(withPassword?.secret, "s3cret", "secret remis en mémoire")
        let keys = sftp.transferEndpoint(secret: nil, acceptNewHostKey: true)
        try expectEqual(keys?.settings.sftpAuth, .agent, "sans mot de passe : clés de ~/.ssh")
        try expectEqual(keys?.acceptNewHostKey, true, "clé acceptée par l’utilisateur")
        sftp.port = 2222
        try expectEqual(sftp.transferEndpoint(secret: "")?.port, 2222, "port choisi")
        try expectEqual(sftp.transferEndpoint(secret: "")?.secret, nil, "mot de passe vide ignoré")

        var ftps = DiskShareLocation(siteKey: siteKey, kind: .ftps, server: "10.10.0.20", port: 990)
        ftps.trustedCertificateSHA256 = "AB:CD"
        try expectEqual(ftps.transferEndpoint(secret: nil)?.settings.tlsMode, .implicit, "990 : TLS implicite")
        try expectEqual(ftps.transferEndpoint(secret: nil)?.settings.trustedCertificateSHA256, "AB:CD", "certificat accepté")
        try expectEqual(ftps.transferEndpoint(secret: nil)?.ftpUser, "anonymous", "FTP sans compte : anonyme")
        ftps.port = nil
        try expectEqual(ftps.transferEndpoint(secret: nil)?.settings.tlsMode, .explicit, "21 : TLS explicite")
        try expectEqual(DiskShareLocation(siteKey: siteKey, kind: .smb, server: "nas").transferEndpoint(secret: nil) == nil, true,
                        "SMB : pas de client de transfert")

        // Ancien fichier d'emplacements (sans empreinte) : relu sans erreur.
        let encoded = try JSONEncoder().encode(DiskShareLocation(siteKey: siteKey, kind: .ftp, server: "nas"))
        var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        object["trustedCertificateSHA256"] = nil
        let old = try JSONDecoder().decode(DiskShareLocation.self, from: JSONSerialization.data(withJSONObject: object))
        try expectEqual(old.trustedCertificateSHA256, nil, "ancien format relu")

        let merged = DiskShareCatalog.merge(discovered: [], saved: [sftp], siteKey: siteKey, folderExists: { _ in false })
        try expectEqual(merged.count, 1, "emplacement SFTP listé")
        try expectEqual(merged[0].networkProtocol, .sftp, "protocole SFTP")
        try expect(merged[0].networkProtocol?.isFileTransfer == true, "sans montage")
        try expect(!merged[0].detail.contains("non monté"), "jamais « non monté » (\(merged[0].detail))")
        try expect(merged[0].detail.hasPrefix("SFTP · nas-bureau.local/volume1/essais"), "détail (\(merged[0].detail))")
        try expectEqual(DiskTransferBenchmark.localSpaceNeeded(for: 1_000), 2_100, "envoi + copie + 10 %")

        let report = DiskServerReport(host: "nas", address: "10.10.0.20", pingMs: 1.2,
                                      ports: [PortScanResult(port: 22, state: .open, rttMs: 0.8)])
        let assessment = report.assessment(kind: .sftp)
        try expectEqual(assessment.title, "SFTP joignable", "SFTP joignable")
        try expect(assessment.detail.contains("Le test de vitesse peut passer par SFTP"), "rien à monter (\(assessment.detail))")
        try expect(DiskServerCheck.portsToTest(kind: .sftp).contains(22), "port 22 vérifié")
    }

    suite.add("Disques en FTP/SFTP : confiance demandée, dossier déjà là, erreurs et nettoyage (faux client)") {
        let location = DiskLocation(name: "NAS", path: "sftp://nas", testParent: "", kind: .reseau, fileSystem: "SFTP",
                                    networkProtocol: .sftp, isMounted: false)
        let config = DiskBenchmarkConfig(sizeBytes: 2 << 20, passes: 1, random: true)
        let local = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: local) }

        // Serveur inconnu : aucune mesure, la confiance est demandée.
        let unknown = FakeTransfer(connectError: FileTransferError.unknownHostKey(fingerprint: "SHA256:abc"))
        var events = await collect(DiskTransferBenchmark(location: location, config: config, remoteFolder: "", localFolder: local) { unknown })
        try expect(events.contains { if case .trustRequired(.hostKey("SHA256:abc")) = $0 { return true } else { return false } },
                   "confiance demandée")
        try expect(!events.contains { if case .finished = $0 { return true } else { return false } }, "rien de mesuré")
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: local.path), [], "fichiers locaux supprimés")

        // Dossier « NetScope-test » laissé par un test interrompu : réutilisé, jamais supprimé.
        let reuse = FakeTransfer(existingFolder: true)
        events = await collect(DiskTransferBenchmark(location: location, config: config, remoteFolder: "partage", localFolder: local) { reuse })
        guard case .finished(let result)? = events.last else {
            throw TestFailure(message: "test non terminé : \(events)", file: #fileID, line: #line)
        }
        try expectEqual(result.writePasses.count, 1, "une écriture")
        try expectEqual(result.readPasses.count, 1, "une lecture")
        try expect(result.randomRead == nil && result.randomWrite == nil, "pas d’accès aléatoires")
        try expect(reuse.log.contains("mkdir /home/technicien/partage/NetScope-test"), "dossier demandé dans le partage")
        try expect(reuse.log.contains { $0.hasPrefix("rm /home/technicien/partage/NetScope-test/netscope-essai-") }, "fichier distant supprimé")
        try expect(!reuse.log.contains { $0.hasPrefix("rmdir") }, "dossier existant laissé")
        try expect(reuse.log.last == "close", "session fermée")

        // Copie incomplète : erreur expliquée, nettoyage quand même.
        let short = FakeTransfer(truncateDownload: true)
        events = await collect(DiskTransferBenchmark(location: location, config: config, remoteFolder: "", localFolder: local) { short })
        guard case .failed(let message)? = events.last else {
            throw TestFailure(message: "échec attendu : \(events)", file: #fileID, line: #line)
        }
        try expect(message.contains("incomplète"), "message (\(message))")
        try expect(short.log.contains("rmdir /home/technicien/NetScope-test"), "dossier créé puis supprimé")

        // Arrêt pendant l'envoi : le fichier et le dossier distants sont supprimés.
        let slow = FakeTransfer(slowUpload: true)
        await stopWhenWriting(DiskTransferBenchmark(location: location, config: config, remoteFolder: "", localFolder: local) { slow })
        for _ in 0..<150 where !slow.log.contains("close") {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try expect(slow.log.contains { $0.hasPrefix("rm /home/technicien/NetScope-test/netscope-essai-") }, "fichier supprimé à l’arrêt (\(slow.log))")
        try expect(slow.log.contains("rmdir /home/technicien/NetScope-test"), "dossier supprimé à l’arrêt")
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: local.path), [], "fichiers locaux supprimés à l’arrêt")
    }

    suite.add("Disques en FTP : vrai test sur le mini serveur FTP (127.0.0.1), deux passes") {
        let root = try temporaryFolder()
        let local = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: local)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("essais"), withIntermediateDirectories: true)
        let server = FTPMiniServer(configuration: .init(root: root, port: 0, bindHost: "127.0.0.1", user: "netscope",
                                                        password: "essai", allowWrite: true))
        let port = try await server.start()
        defer { server.stop() }
        let share = DiskShareLocation(siteKey: "siege", kind: .ftp, server: "127.0.0.1", share: "essais", user: "netscope",
                                      port: Int(port), hasPassword: true)
        guard let endpoint = share.transferEndpoint(secret: "essai", timeout: 5) else {
            throw TestFailure(message: "connexion FTP attendue", file: #fileID, line: #line)
        }
        let location = DiskLocation(name: "FTP local", path: share.address, testParent: "", kind: .reseau, fileSystem: "FTP",
                                    networkProtocol: .ftp, isMounted: false)
        let events = await collect(DiskTransferBenchmark(location: location, config: DiskBenchmarkConfig(sizeBytes: 2 << 20, passes: 2),
                                                         remoteFolder: share.trimmedShare, localFolder: local) {
            try FileTransferClients.make(endpoint)
        })
        guard case .finished(let result)? = events.last else {
            throw TestFailure(message: "test FTP non terminé : \(events.suffix(3))", file: #fileID, line: #line)
        }
        try expectEqual(result.writePasses.count, 2, "deux envois")
        try expectEqual(result.readPasses.count, 2, "deux réceptions")
        try expect(result.writePasses.allSatisfy { $0 > 0 } && result.readPasses.allSatisfy { $0 > 0 }, "débits mesurés")
        try expect(events.contains { if case .progress(let p) = $0 { return p.phase == .lecture } else { return false } }, "avancement")
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("essais").path), [],
                        "NetScope-test supprimé du serveur")
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: local.path), [], "fichiers locaux supprimés")
    }
}

private func temporaryFolder() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("netscope-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Lit le flux jusqu'au début de l'écriture, puis l'abandonne (comme « Arrêter »).
private func stopWhenWriting(_ engine: DiskBenchmarkEngine) async {
    for await event in engine.run() {
        if case .phase(.ecriture, _) = event { return }
    }
}

private func collect(_ engine: DiskBenchmarkEngine) async -> [DiskEvent] {
    var events: [DiskEvent] = []
    for await event in engine.run() { events.append(event) }
    return events
}

/// Faux serveur de fichiers en mémoire : journal des opérations, erreurs choisies.
private final class FakeTransfer: RemoteFileTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var files: [String: Int64] = [:]
    let connectError: Error?
    let existingFolder: Bool
    let truncateDownload: Bool
    let slowUpload: Bool

    init(connectError: Error? = nil, existingFolder: Bool = false, truncateDownload: Bool = false, slowUpload: Bool = false) {
        self.connectError = connectError
        self.existingFolder = existingFolder
        self.truncateDownload = truncateDownload
        self.slowUpload = slowUpload
    }

    var log: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    private func note(_ text: String) {
        lock.lock()
        entries.append(text)
        lock.unlock()
    }

    func connect() async throws -> String {
        note("connect")
        if let connectError { throw connectError }
        return "/home/technicien"
    }

    func list(_ path: String) async throws -> [RemoteFileEntry] {
        note("ls \(path)")
        return existingFolder ? [RemoteFileEntry(name: "NetScope-test", path: path + "/NetScope-test", kind: .directory)] : []
    }

    private func store(_ path: String, _ size: Int64) {
        lock.lock()
        files[path] = size
        lock.unlock()
    }

    private func stored(_ path: String) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return files[path]
    }

    func size(of path: String) async throws -> Int64? { stored(path) }

    func download(_ remotePath: String, to localURL: URL, resume: Bool, progress: @escaping FileTransferProgress) async throws {
        note("get \(remotePath)")
        let size = Int(stored(remotePath) ?? 0)
        let count = truncateDownload ? size / 2 : size
        try Data(count: count).write(to: localURL)
        progress(Int64(count))
    }

    func upload(_ localURL: URL, to remotePath: String, resume: Bool, progress: @escaping FileTransferProgress) async throws {
        note("put \(remotePath)")
        if slowUpload {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        store(remotePath, size)
        progress(size / 2)
        progress(size)
    }

    func makeDirectory(_ path: String) async throws {
        note("mkdir \(path)")
        if existingFolder { throw FileTransferError.server("550 Le dossier existe déjà") }
    }

    func rename(_ from: String, to: String) async throws {}

    func deleteFile(_ path: String) async throws { note("rm \(path)") }

    func removeDirectory(_ path: String) async throws { note("rmdir \(path)") }

    func close() async { note("close") }
}
