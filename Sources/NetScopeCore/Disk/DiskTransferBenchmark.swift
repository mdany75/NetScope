import Darwin
import Foundation

// Note 78 : vitesse d'un serveur FTP, FTPS ou SFTP dans « Vitesse des disques », par le client de
// transfert existant (`RemoteFileTransfer`, note 50). Un fichier d'essai de données aléatoires est
// préparé sur ce Mac (hors mesure), envoyé dans « NetScope-test » sur le serveur (écriture), puis
// reçu (lecture) ; chaque passe refait les deux. Le fichier distant, le dossier « NetScope-test »
// (s'il a été créé par NetScope) et les fichiers locaux sont supprimés à la fin, à l'arrêt et en
// cas d'erreur. Pas d'accès aléatoires de 4 Kio : FTP et SFTP ne transfèrent que des fichiers entiers.

/// Confiance à accorder avant de mesurer (serveur SFTP inconnu, certificat FTPS non reconnu).
public enum DiskTransferTrust: Equatable, Sendable {
    case hostKey(fingerprint: String)
    case certificate(sha256: String, subject: String)

    /// Erreur du client de transfert qui demande l'accord de l'utilisateur, s'il y en a une.
    public init?(_ error: Error) {
        switch error as? FileTransferError {
        case .unknownHostKey(let fingerprint)?: self = .hostKey(fingerprint: fingerprint)
        case .untrustedCertificate(let sha256, let subject)?: self = .certificate(sha256: sha256, subject: subject)
        default: return nil
        }
    }

    /// Phrase de la demande (« Serveur SSH inconnu : empreinte SHA256:… »).
    public var message: String {
        switch self {
        case .hostKey(let fingerprint):
            return "Serveur SFTP inconnu\u{00A0}: empreinte \(fingerprint). Vérifiez-la avant de lui faire confiance."
        case .certificate(let sha256, let subject):
            return "Certificat FTPS non reconnu (\(subject)), empreinte SHA-256 \(sha256). Vérifiez-la avant de lui faire confiance."
        }
    }
}

/// Le test d'un serveur FTP, FTPS ou SFTP.
public struct DiskTransferBenchmark: DiskBenchmarkEngine {
    public let location: DiskLocation
    public let config: DiskBenchmarkConfig
    /// Dossier du serveur où créer « NetScope-test » (vide : dossier de départ de la session).
    public let remoteFolder: String
    /// Dossier local des fichiers d'essai (le dossier temporaire du Mac par défaut).
    public let localFolder: URL
    public let makeClient: @Sendable () throws -> RemoteFileTransfer

    public init(location: DiskLocation, config: DiskBenchmarkConfig, remoteFolder: String,
                localFolder: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                makeClient: @escaping @Sendable () throws -> RemoteFileTransfer) {
        var config = config
        // Accès aléatoires impossibles par FTP ou SFTP (fichiers entiers seulement).
        config.random = false
        self.location = location
        self.config = config
        self.remoteFolder = remoteFolder
        self.localFolder = localFolder
        self.makeClient = makeClient
    }

    public func run() -> AsyncStream<DiskEvent> {
        let worker = DiskTransferWorker(benchmark: self)
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await worker.run { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Espace local nécessaire : le fichier envoyé, la copie reçue et 10 % de marge.
    public static func localSpaceNeeded(for size: Int64) -> Int64 {
        size * 2 + size / 10
    }
}

/// Débit instantané pendant un envoi ou une réception (appelé depuis le fil du client).
final class DiskTransferMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Double
    private var lastBytes: Int64 = 0
    private var lastTime: Double = 0

    init() { start = Self.now() }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    var seconds: Double { Self.now() - start }

    /// Débit (Mo/s) depuis le dernier relevé, au plus tous les 100 ms ; nil entre deux relevés.
    func sample(_ bytes: Int64, total: Int64) -> (time: Double, rate: Double?)? {
        lock.lock()
        defer { lock.unlock() }
        let t = Self.now() - start
        guard t - lastTime >= 0.1 || bytes >= total else { return nil }
        let rate = DiskMath.instantRate(previousBytes: lastBytes, previousTime: lastTime, bytes: bytes, time: t)
        lastBytes = bytes
        lastTime = t
        return (t, rate)
    }
}

struct DiskTransferWorker: Sendable {
    let benchmark: DiskTransferBenchmark

    private var config: DiskBenchmarkConfig { benchmark.config }

    func run(emit: @escaping @Sendable (DiskEvent) -> Void) async {
        let plan = DiskPlan(config: config, kind: .reseau)
        let begin = DiskTransferMeter.now()
        emit(.phase(.preparation, pass: 1))
        let work = benchmark.localFolder.appendingPathComponent("NetScope-disques-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var client: RemoteFileTransfer?
        var remoteFile: String?
        var remoteFolderCreated: String?
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let needed = DiskTransferBenchmark.localSpaceNeeded(for: config.sizeBytes)
            if let free = DiskSpace.freeBytes(at: work.path), free < needed {
                throw DiskBenchmarkError.insufficientSpace(needed: needed, free: free)
            }
            let source = work.appendingPathComponent("envoi.bin")
            let copy = work.appendingPathComponent("reception.bin")
            try Self.writeRandomFile(source, size: config.sizeBytes)
            try Task.checkCancellation()

            let session = try benchmark.makeClient()
            client = session
            let start = try await session.connect()
            let base = benchmark.remoteFolder.trimmingCharacters(in: .whitespaces).isEmpty
                ? start : RemotePath.join(start, benchmark.remoteFolder.trimmingCharacters(in: .whitespaces))
            let folder = RemotePath.join(base, DiskTestFolder.folderName)
            do {
                try await session.makeDirectory(folder)
                remoteFolderCreated = folder
            } catch {
                // Déjà là (test précédent interrompu) : on s'en sert ; sinon l'erreur est la vraie.
                let entries = (try? await session.list(base)) ?? []
                guard entries.contains(where: { $0.name == DiskTestFolder.folderName && $0.kind == .directory }) else { throw error }
            }
            try Task.checkCancellation()
            let file = RemotePath.join(folder, DiskTestFolder.fileName())
            remoteFile = file

            var result = DiskBenchmarkResult(sizeBytes: config.sizeBytes, passes: config.passes)
            let size = config.sizeBytes
            for pass in 1...config.passes {
                emit(.phase(.ecriture, pass: pass))
                let up = DiskTransferMeter()
                try await session.upload(source, to: file, resume: false) { bytes in
                    guard let sample = up.sample(bytes, total: size) else { return }
                    emit(.progress(DiskProgress(phase: .ecriture, pass: pass,
                                                fraction: plan.fraction(phase: .ecriture, pass: pass, stepFraction: Double(bytes) / Double(size)),
                                                instant: sample.rate, elapsed: DiskTransferMeter.now() - begin)))
                }
                let write = DiskMath.megabytesPerSecond(bytes: size, seconds: up.seconds) ?? 0
                result.writePasses.append(write)
                emit(.passMeasured(.ecriture, pass: pass, mbps: write))
                try Task.checkCancellation()

                emit(.phase(.lecture, pass: pass))
                try? FileManager.default.removeItem(at: copy)
                let down = DiskTransferMeter()
                try await session.download(file, to: copy, resume: false) { bytes in
                    guard let sample = down.sample(bytes, total: size) else { return }
                    emit(.progress(DiskProgress(phase: .lecture, pass: pass,
                                                fraction: plan.fraction(phase: .lecture, pass: pass, stepFraction: Double(bytes) / Double(size)),
                                                instant: sample.rate, elapsed: DiskTransferMeter.now() - begin)))
                }
                let received = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value ?? -1
                guard received == size else {
                    throw FileTransferError.protocolViolation("Copie reçue incomplète\u{00A0}: \(DiskFormat.size(max(received, 0))) sur \(DiskFormat.size(size)).")
                }
                let read = DiskMath.megabytesPerSecond(bytes: size, seconds: down.seconds) ?? 0
                result.readPasses.append(read)
                emit(.passMeasured(.lecture, pass: pass, mbps: read))
                try Task.checkCancellation()
            }
            emit(.phase(.nettoyage, pass: 1))
            await Self.cleanup(session, file: file, folder: remoteFolderCreated)
            emit(.finished(result))
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? FileTransferError) == .cancelled
            emit(.phase(.nettoyage, pass: 1))
            if let client {
                // Nettoyage hors de la tâche annulée, borné à 15 s.
                let file = remoteFile, folder = remoteFolderCreated
                await Task.detached {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await Self.cleanup(client, file: file, folder: folder) }
                        group.addTask { try? await Task.sleep(nanoseconds: 15_000_000_000) }
                        _ = await group.next()
                        group.cancelAll()
                    }
                }.value
            }
            if cancelled {
                emit(.stopped)
            } else if let trust = DiskTransferTrust(error) {
                emit(.trustRequired(trust))
            } else {
                emit(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    /// Supprime le fichier d'essai distant et le dossier créé pour lui, puis ferme la session.
    static func cleanup(_ client: RemoteFileTransfer, file: String?, folder: String?) async {
        if let file { try? await client.deleteFile(file) }
        if let folder { try? await client.removeDirectory(folder) }
        await client.close()
    }

    /// Fichier de données aléatoires (un serveur qui compresse ne fausse pas la mesure).
    static func writeRandomFile(_ url: URL, size: Int64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DiskBenchmarkError.io("Création du fichier d’essai local", errno)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var block = [UInt8](repeating: 0, count: DiskMath.sequentialBlock)
        var written: Int64 = 0
        while written < size {
            try Task.checkCancellation()
            let count = Int(min(Int64(block.count), size - written))
            block.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
            try handle.write(contentsOf: block[0..<count])
            written += Int64(count)
        }
    }
}
