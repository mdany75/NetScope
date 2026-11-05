import Darwin
import Foundation

// Mesure de la vitesse d'un emplacement (note 22) : écriture puis lecture séquentielles par blocs
// de 1 Mio, cache du système contourné (F_NOCACHE), fsync à la fin de l'écriture ; accès
// aléatoires de 4 Kio (IOPS, latence moyenne et p95) ; pour un dossier nuage, temps jusqu'à
// « envoyé ». Le fichier d'essai vit dans « NetScope-test » et il est supprimé à la fin, à
// l'arrêt et en cas d'erreur. Le travail se fait sur un fil à part ; les événements arrivent dans
// un AsyncStream (comme le Speedtest). Annuler la tâche qui lit le flux arrête la mesure.

/// Étape d'un test.
public enum DiskPhase: String, Codable, CaseIterable, Sendable {
    case preparation, ecriture, lecture, aleatoireLecture, aleatoireEcriture, envoi, nettoyage

    public var label: String {
        switch self {
        case .preparation: return "Préparation"
        case .ecriture: return "Écriture séquentielle"
        case .lecture: return "Lecture séquentielle"
        case .aleatoireLecture: return "Lecture aléatoire 4 Kio"
        case .aleatoireEcriture: return "Écriture aléatoire 4 Kio"
        case .envoi: return "Envoi vers le nuage"
        case .nettoyage: return "Nettoyage"
        }
    }

    public var shortLabel: String {
        switch self {
        case .preparation: return "Préparation"
        case .ecriture: return "Écriture"
        case .lecture: return "Lecture"
        case .aleatoireLecture: return "4 Kio lecture"
        case .aleatoireEcriture: return "4 Kio écriture"
        case .envoi: return "Envoi"
        case .nettoyage: return "Nettoyage"
        }
    }
}

/// Réglages d'un test.
public struct DiskBenchmarkConfig: Codable, Hashable, Sendable {
    /// Tailles proposées : 256 Mio, 1, 5 et 10 Gio.
    public static let sizeChoices: [Int64] = [256 << 20, 1 << 30, 5 << 30, 10 << 30]
    public static let passChoices = [1, 2, 3, 5]
    /// Délais maximaux d'envoi proposés pour un dossier nuage (secondes).
    public static let cloudTimeoutChoices: [Double] = [120, 300, 600, 1800]

    public var sizeBytes: Int64
    public var passes: Int
    public var random: Bool
    /// Durée de chaque série d'accès aléatoires.
    public var randomSeconds: Double
    /// Nombre maximal d'accès d'une série (borne pour les SSD très rapides).
    public var randomMaxOperations: Int
    public var cloudTimeout: Double

    public init(sizeBytes: Int64 = 1 << 30, passes: Int = 1, random: Bool = true, randomSeconds: Double = 3,
                randomMaxOperations: Int = 250_000, cloudTimeout: Double = 600) {
        self.sizeBytes = max(Int64(DiskMath.sequentialBlock), sizeBytes)
        self.passes = min(max(passes, 1), 10)
        self.random = random
        self.randomSeconds = randomSeconds
        self.randomMaxOperations = randomMaxOperations
        self.cloudTimeout = cloudTimeout
    }

    /// Réglages réellement appliqués à un emplacement : un dossier nuage ne fait qu'une passe
    /// d'écriture (chaque passe serait renvoyée au service) et pas d'accès aléatoires (ils ne
    /// toucheraient que la copie locale).
    public func effective(for kind: DiskLocationKind) -> DiskBenchmarkConfig {
        guard kind == .nuage else { return self }
        var copy = self
        copy.passes = 1
        copy.random = false
        return copy
    }
}

/// Étapes prévues et part de chacune dans la barre de progression.
public struct DiskPlan: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public var phase: DiskPhase
        public var pass: Int
        public var weight: Double
    }

    public let steps: [Step]

    public init(config: DiskBenchmarkConfig, kind: DiskLocationKind) {
        let config = config.effective(for: kind)
        var steps: [Step] = []
        if kind == .nuage {
            steps = [Step(phase: .ecriture, pass: 1, weight: 1), Step(phase: .envoi, pass: 1, weight: 1)]
        } else {
            for pass in 1...config.passes {
                steps.append(Step(phase: .ecriture, pass: pass, weight: 1))
                steps.append(Step(phase: .lecture, pass: pass, weight: 1))
            }
            if config.random {
                steps.append(Step(phase: .aleatoireLecture, pass: 1, weight: 0.5))
                steps.append(Step(phase: .aleatoireEcriture, pass: 1, weight: 0.5))
            }
        }
        self.steps = steps
    }

    /// Avancement global (0…1) quand l'étape `phase`/`pass` en est à `stepFraction`.
    public func fraction(phase: DiskPhase, pass: Int, stepFraction: Double) -> Double {
        let total = steps.map(\.weight).reduce(0, +)
        guard total > 0, let index = steps.firstIndex(where: { $0.phase == phase && $0.pass == pass }) else { return 0 }
        let done = steps[..<index].map(\.weight).reduce(0, +)
        return min(1, max(0, (done + steps[index].weight * min(max(stepFraction, 0), 1)) / total))
    }
}

/// Résultat d'une série d'accès aléatoires.
public struct DiskRandomResult: Codable, Hashable, Sendable {
    public var operations: Int
    public var seconds: Double
    public var iops: Double
    public var meanMs: Double
    public var p95Ms: Double

    public init(operations: Int, seconds: Double, iops: Double, meanMs: Double, p95Ms: Double) {
        self.operations = operations
        self.seconds = seconds
        self.iops = iops
        self.meanMs = meanMs
        self.p95Ms = p95Ms
    }

    /// À partir des latences de chaque accès (ms) et de la durée totale (fsync final compris).
    public static func make(latenciesMs: [Double], totalSeconds: Double) -> DiskRandomResult? {
        guard !latenciesMs.isEmpty, let iops = DiskMath.iops(operations: latenciesMs.count, seconds: totalSeconds),
              let mean = DiskMath.mean(latenciesMs), let p95 = DiskMath.percentile(latenciesMs, 0.95) else { return nil }
        return DiskRandomResult(operations: latenciesMs.count, seconds: totalSeconds, iops: iops, meanMs: mean, p95Ms: p95)
    }
}

/// Résultat complet d'un test.
public struct DiskBenchmarkResult: Codable, Hashable, Sendable {
    public var sizeBytes: Int64
    public var passes: Int
    /// Débit de chaque passe (Mo/s).
    public var writePasses: [Double]
    public var readPasses: [Double]
    public var randomRead: DiskRandomResult?
    public var randomWrite: DiskRandomResult?
    public var cloudStatus: DiskCloudStatus?
    /// Secondes entre la fin de l'écriture et « envoyé ».
    public var uploadSeconds: Double?
    /// Dernier message d'erreur d'envoi du service nuage (domaine et code compris).
    public var cloudError: String?

    public init(sizeBytes: Int64, passes: Int, writePasses: [Double] = [], readPasses: [Double] = [],
                randomRead: DiskRandomResult? = nil, randomWrite: DiskRandomResult? = nil,
                cloudStatus: DiskCloudStatus? = nil, uploadSeconds: Double? = nil) {
        self.sizeBytes = sizeBytes
        self.passes = passes
        self.writePasses = writePasses
        self.readPasses = readPasses
        self.randomRead = randomRead
        self.randomWrite = randomWrite
        self.cloudStatus = cloudStatus
        self.uploadSeconds = uploadSeconds
    }

    /// Moyenne des passes.
    public var writeMBps: Double? { DiskMath.mean(writePasses) }
    public var readMBps: Double? { DiskMath.mean(readPasses) }
    public var uploadMbps: Double? { DiskCloudTracker.uploadMbps(bytes: sizeBytes, seconds: uploadSeconds) }
}

/// Avancement envoyé pendant une mesure.
public struct DiskProgress: Equatable, Sendable {
    public var phase: DiskPhase
    public var pass: Int
    /// Avancement global (0…1).
    public var fraction: Double
    /// Débit instantané (Mo/s) ou IOPS instantanées pendant les accès aléatoires.
    public var instant: Double?
    /// Secondes depuis le début du test.
    public var elapsed: Double

    public init(phase: DiskPhase, pass: Int, fraction: Double, instant: Double?, elapsed: Double) {
        self.phase = phase
        self.pass = pass
        self.fraction = fraction
        self.instant = instant
        self.elapsed = elapsed
    }
}

public enum DiskEvent: Sendable {
    case phase(DiskPhase, pass: Int)
    case progress(DiskProgress)
    case passMeasured(DiskPhase, pass: Int, mbps: Double)
    case random(DiskPhase, DiskRandomResult)
    /// Suivi de l'envoi d'un dossier nuage (état, secondes depuis la fin de l'écriture).
    case cloud(DiskCloudStatus, elapsed: Double)
    case finished(DiskBenchmarkResult)
    case failed(String)
    /// Test arrêté ; le fichier d'essai a été supprimé.
    case stopped
    /// Note 78 : serveur SFTP inconnu ou certificat FTPS non reconnu ; rien n'a été mesuré.
    case trustRequired(DiskTransferTrust)
}

public enum DiskBenchmarkError: Error, Equatable, LocalizedError {
    case missingLocation(String)
    case unsafeFolder(String)
    case readOnly
    case insufficientSpace(needed: Int64, free: Int64)
    case io(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .missingLocation(let path): return "Emplacement introuvable\u{00A0}: \(path) (volume éjecté ou dossier absent)."
        case .unsafeFolder(let path): return "«\u{00A0}\(path)\u{00A0}» existe déjà et n’est pas un dossier\u{00A0}: NetScope n’y touche pas."
        case .readOnly: return "Cet emplacement est en lecture seule\u{00A0}: impossible d’y écrire le fichier d’essai."
        case .insufficientSpace(let needed, let free):
            return "Espace insuffisant\u{00A0}: il faut \(DiskFormat.size(needed)) libres (fichier d’essai et marge de 10\u{00A0}%), "
                + "\(DiskFormat.size(free)) disponibles. Choisissez une taille plus petite."
        case .io(let operation, let code):
            return "\(operation) impossible\u{00A0}: \(String(cString: strerror(code))) (erreur \(code))."
        }
    }
}

/// Moteur d'un test (réel ou de démonstration).
public protocol DiskBenchmarkEngine: Sendable {
    func run() -> AsyncStream<DiskEvent>
}

/// Drapeau d'arrêt partagé entre le flux et le fil de mesure.
final class DiskCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Espace libre d'un dossier (volume qui le contient).
public enum DiskSpace {
    public static func freeBytes(at path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

/// Le vrai test, sur le disque.
public struct DiskBenchmark: DiskBenchmarkEngine {
    public let location: DiskLocation
    public let config: DiskBenchmarkConfig
    public let pending: DiskPendingCleanup?

    public init(location: DiskLocation, config: DiskBenchmarkConfig, pending: DiskPendingCleanup? = nil) {
        self.location = location
        self.config = config.effective(for: location.kind)
        self.pending = pending
    }

    public func run() -> AsyncStream<DiskEvent> {
        let location = self.location, config = self.config, pending = self.pending
        return AsyncStream { continuation in
            let flag = DiskCancelFlag()
            continuation.onTermination = { _ in flag.set() }
            let thread = Thread {
                let worker = DiskWorker(location: location, config: config, pending: pending, flag: flag) { continuation.yield($0) }
                worker.run()
                continuation.finish()
            }
            thread.name = "NetScope – vitesse des disques"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}

/// Travail sur le fil de mesure.
final class DiskWorker {
    let location: DiskLocation
    let config: DiskBenchmarkConfig
    let pending: DiskPendingCleanup?
    let flag: DiskCancelFlag
    let emit: (DiskEvent) -> Void
    let plan: DiskPlan
    private let start = DispatchTime.now().uptimeNanoseconds
    private var buffer: UnsafeMutableRawPointer?

    struct Stopped: Error {}

    init(location: DiskLocation, config: DiskBenchmarkConfig, pending: DiskPendingCleanup?, flag: DiskCancelFlag,
         emit: @escaping (DiskEvent) -> Void) {
        self.location = location
        self.config = config
        self.pending = pending
        self.flag = flag
        self.emit = emit
        plan = DiskPlan(config: config, kind: location.kind)
    }

    deinit { free(buffer) }

    private var elapsed: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func run() {
        emit(.phase(.preparation, pass: 1))
        let parent = URL(fileURLWithPath: location.testParent, isDirectory: true)
        do {
            if location.isReadOnly { throw DiskBenchmarkError.readOnly }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DiskBenchmarkError.missingLocation(parent.path)
            }
            if let free = DiskSpace.freeBytes(at: parent.path), !DiskMath.hasRoom(freeBytes: free, testSize: config.sizeBytes) {
                throw DiskBenchmarkError.insufficientSpace(needed: DiskMath.requiredFreeSpace(forTestSize: config.sizeBytes), free: free)
            }
        } catch {
            emit(.failed(error.localizedDescription))
            return
        }
        pending?.begin(parent.path)
        // Fichier propre à ce test : un fil arrêté qui finit tard ne supprime que le sien, pas celui
        // d'un test relancé aussitôt au même endroit.
        let fileName = DiskTestFolder.fileName()
        defer {
            DiskTestFolder.cleanup(in: parent, onlyFile: fileName)
            pending?.end(parent.path)
        }
        do {
            let folder = try DiskTestFolder.prepare(in: parent)
            let file = folder.appendingPathComponent(fileName)
            var raw: UnsafeMutableRawPointer?
            guard posix_memalign(&raw, 4096, DiskMath.sequentialBlock) == 0, let raw else {
                throw DiskBenchmarkError.io("Allocation de la mémoire tampon", ENOMEM)
            }
            buffer = raw
            // Données aléatoires : un système de fichiers qui compresse ou déduplique ne triche pas.
            arc4random_buf(raw, DiskMath.sequentialBlock)

            var result = DiskBenchmarkResult(sizeBytes: config.sizeBytes, passes: config.passes)
            for pass in 1...config.passes {
                let write = try sequentialWrite(file, pass: pass)
                result.writePasses.append(write)
                emit(.passMeasured(.ecriture, pass: pass, mbps: write))
                if location.kind == .nuage { break }
                let read = try sequentialRead(file, pass: pass)
                result.readPasses.append(read)
                emit(.passMeasured(.lecture, pass: pass, mbps: read))
            }
            if location.kind == .nuage {
                let (status, seconds, error) = try followUpload(file)
                result.cloudStatus = status
                result.uploadSeconds = seconds
                result.cloudError = error
            } else if config.random {
                result.randomRead = try randomAccess(file, write: false)
                if let value = result.randomRead { emit(.random(.aleatoireLecture, value)) }
                result.randomWrite = try randomAccess(file, write: true)
                if let value = result.randomWrite { emit(.random(.aleatoireEcriture, value)) }
            }
            emit(.phase(.nettoyage, pass: 1))
            emit(.finished(result))
        } catch is Stopped {
            emit(.phase(.nettoyage, pass: 1))
            emit(.stopped)
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }

    private func checkStop() throws {
        if flag.isSet { throw Stopped() }
    }

    private func progress(_ phase: DiskPhase, pass: Int, stepFraction: Double, instant: Double?) {
        emit(.progress(DiskProgress(phase: phase, pass: pass,
                                    fraction: plan.fraction(phase: phase, pass: pass, stepFraction: stepFraction),
                                    instant: instant, elapsed: elapsed)))
    }

    private func open(_ url: URL, flags: Int32, operation: String) throws -> Int32 {
        let fd = Darwin.open(url.path, flags | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DiskBenchmarkError.io(operation, errno) }
        // Cache du système contourné : les lectures et écritures vont au disque.
        _ = fcntl(fd, F_NOCACHE, 1)
        return fd
    }

    /// Écriture séquentielle ; renvoie le débit (Mo/s), fsync compris.
    private func sequentialWrite(_ url: URL, pass: Int) throws -> Double {
        emit(.phase(.ecriture, pass: pass))
        let fd = try open(url, flags: O_CREAT | O_WRONLY | O_TRUNC, operation: "Création du fichier d’essai")
        defer { close(fd) }
        let total = config.sizeBytes
        let begin = Self.now()
        var done: Int64 = 0
        var lastBytes: Int64 = 0
        var lastTime = 0.0
        while done < total {
            try checkStop()
            let chunk = Int(min(Int64(DiskMath.sequentialBlock), total - done))
            var offset = 0
            while offset < chunk {
                let written = Darwin.write(fd, buffer!.advanced(by: offset), chunk - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw DiskBenchmarkError.io("Écriture", errno)
                }
                offset += written
            }
            done += Int64(chunk)
            let t = Double(Self.now() - begin) / 1e9
            if t - lastTime >= 0.1 || done == total {
                let instant = DiskMath.instantRate(previousBytes: lastBytes, previousTime: lastTime, bytes: done, time: t)
                progress(.ecriture, pass: pass, stepFraction: Double(done) / Double(total), instant: instant)
                lastBytes = done
                lastTime = t
            }
        }
        guard fsync(fd) == 0 else { throw DiskBenchmarkError.io("Synchronisation (fsync)", errno) }
        let seconds = Double(Self.now() - begin) / 1e9
        return DiskMath.megabytesPerSecond(bytes: total, seconds: seconds) ?? 0
    }

    /// Lecture séquentielle ; renvoie le débit (Mo/s).
    private func sequentialRead(_ url: URL, pass: Int) throws -> Double {
        emit(.phase(.lecture, pass: pass))
        let fd = try open(url, flags: O_RDONLY, operation: "Ouverture du fichier d’essai")
        defer { close(fd) }
        let total = config.sizeBytes
        let begin = Self.now()
        var done: Int64 = 0
        var lastBytes: Int64 = 0
        var lastTime = 0.0
        while done < total {
            try checkStop()
            let count = Darwin.read(fd, buffer!, DiskMath.sequentialBlock)
            if count < 0 {
                if errno == EINTR { continue }
                throw DiskBenchmarkError.io("Lecture", errno)
            }
            if count == 0 { break }
            done += Int64(count)
            let t = Double(Self.now() - begin) / 1e9
            if t - lastTime >= 0.1 || done >= total {
                let instant = DiskMath.instantRate(previousBytes: lastBytes, previousTime: lastTime, bytes: done, time: t)
                progress(.lecture, pass: pass, stepFraction: Double(done) / Double(total), instant: instant)
                lastBytes = done
                lastTime = t
            }
        }
        let seconds = Double(Self.now() - begin) / 1e9
        return DiskMath.megabytesPerSecond(bytes: done, seconds: seconds) ?? 0
    }

    /// Accès aléatoires de 4 Kio à des positions alignées du fichier d'essai.
    private func randomAccess(_ url: URL, write: Bool) throws -> DiskRandomResult? {
        let phase: DiskPhase = write ? .aleatoireEcriture : .aleatoireLecture
        emit(.phase(phase, pass: 1))
        let fd = try open(url, flags: write ? O_WRONLY : O_RDONLY, operation: "Ouverture du fichier d’essai")
        defer { close(fd) }
        let blocks = max(1, Int(config.sizeBytes / Int64(DiskMath.randomBlock)))
        var latencies: [Double] = []
        latencies.reserveCapacity(min(config.randomMaxOperations, 100_000))
        var generator = SystemRandomNumberGenerator()
        let begin = Self.now()
        let limit = UInt64(config.randomSeconds * 1e9)
        var lastCount = 0
        var lastTime = 0.0
        while latencies.count < config.randomMaxOperations {
            if latencies.count % 64 == 0 { try checkStop() }
            let offset = off_t(Int.random(in: 0..<blocks, using: &generator) * DiskMath.randomBlock)
            let t0 = Self.now()
            let count = write ? pwrite(fd, buffer!, DiskMath.randomBlock, offset) : pread(fd, buffer!, DiskMath.randomBlock, offset)
            let t1 = Self.now()
            if count < 0 {
                if errno == EINTR { continue }
                throw DiskBenchmarkError.io(write ? "Écriture aléatoire" : "Lecture aléatoire", errno)
            }
            latencies.append(Double(t1 - t0) / 1e6)
            let spent = t1 - begin
            let t = Double(spent) / 1e9
            if t - lastTime >= 0.1 {
                let instant = DiskMath.iops(operations: latencies.count - lastCount, seconds: t - lastTime)
                progress(phase, pass: 1, stepFraction: Double(spent) / Double(limit), instant: instant)
                lastCount = latencies.count
                lastTime = t
            }
            if spent >= limit { break }
        }
        if write, fsync(fd) != 0 { throw DiskBenchmarkError.io("Synchronisation (fsync)", errno) }
        let seconds = Double(Self.now() - begin) / 1e9
        return DiskRandomResult.make(latenciesMs: latencies, totalSeconds: seconds)
    }

    /// Suit l'envoi du fichier d'essai vers le nuage jusqu'à « envoyé », au délai maximal ou à l'arrêt.
    private func followUpload(_ url: URL) throws -> (DiskCloudStatus, Double?, String?) {
        emit(.phase(.envoi, pass: 1))
        var tracker = DiskCloudTracker(timeout: config.cloudTimeout)
        let begin = Self.now()
        while true {
            if flag.isSet {
                tracker.stop()
                throw Stopped()
            }
            let t = Double(Self.now() - begin) / 1e9
            let status = tracker.add(DiskCloudReader.sample(url, time: t))
            emit(.cloud(status, elapsed: t))
            progress(.envoi, pass: 1, stepFraction: status.isFinal ? 1 : t / config.cloudTimeout, instant: nil)
            if status.isFinal { return (status, tracker.uploadedAfter, tracker.error) }
            usleep(500_000)
        }
    }
}
