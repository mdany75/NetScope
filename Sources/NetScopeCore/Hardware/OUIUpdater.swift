import Foundation

/// Mise à jour de la base des fabricants depuis le registre IEEE : téléchargement des trois
/// fichiers CSV, vérification, conversion, écriture atomique de `OUIDatabase.userFileURL`,
/// rechargement de `OUIDatabase.builtIn`. Lancée à la demande (Réglages › Base des fabricants)
/// ou automatiquement (note 81), au plus une fois par mois et seulement quand
/// `OUIAutoUpdatePolicy` le permet (base de plus de 30 jours, ni scan en cours, ni connexion
/// limitée, jamais en démonstration). Si quelque chose échoue, l'ancienne base reste en place.
public struct OUIUpdater: Sendable {
    /// Avancement : fichier en cours et fraction globale (0…1).
    public struct Progress: Sendable, Equatable {
        public var fileName: String
        public var fraction: Double
        public var step: String
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case http(String, Int)
        case network(String, String)
        case registry(String)
        case write(String)

        public var description: String {
            switch self {
            case .http(let file, let status):
                return "Téléchargement de \(file) refusé par le serveur de l’IEEE (HTTP \(status))."
            case .network(let file, let detail):
                return "Téléchargement de \(file) impossible : \(detail)"
            case .registry(let detail):
                return detail
            case .write(let detail):
                return "Écriture de la base impossible : \(detail)"
            }
        }
    }

    /// Taille maximale acceptée par fichier (le plus gros, oui.csv, fait environ 4 Mo).
    static let maximumFileSize = 64 * 1_048_576

    public var destination: URL
    public var timeout: TimeInterval

    public init(destination: URL = OUIDatabase.userFileURL, timeout: TimeInterval = 60) {
        self.destination = destination
        self.timeout = timeout
    }

    /// Télécharge, vérifie, convertit, écrit, puis recharge `database`. Renvoie la nouvelle provenance.
    public func update(database: OUIDatabase = .builtIn,
                       progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> OUIDatabase.Source {
        let downloaded = try await download(progress: progress)
        try Task.checkCancellation()
        progress(Progress(fileName: "", fraction: 1, step: "Conversion du registre…"))
        let source = try install(csv: downloaded)
        database.reload()
        return source
    }

    /// Télécharge les trois fichiers du registre, sans rien écrire (la conversion et l'écriture
    /// passent par `install(csv:)`).
    public func download(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> [String: Data] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 5
        configuration.httpAdditionalHeaders = ["User-Agent": "NetScope"]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var downloaded: [String: Data] = [:]
        let files = OUIRegistry.files
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let base = Double(index) / Double(files.count)
            progress(Progress(fileName: file.name, fraction: base, step: "Téléchargement de \(file.name)…"))
            downloaded[file.name] = try await download(file, session: session) { part in
                progress(Progress(fileName: file.name, fraction: base + part / Double(files.count),
                                  step: "Téléchargement de \(file.name)…"))
            }
        }
        return downloaded
    }

    /// Vérifie et convertit les trois fichiers, puis écrit la base de façon atomique.
    @discardableResult
    public func install(csv: [String: Data], date: Date = Date()) throws -> OUIDatabase.Source {
        let converted: (text: String, count: Int)
        do {
            converted = try OUIRegistry.convert(csv, date: date)
        } catch let failure as OUIRegistry.Failure {
            throw Failure.registry(failure.description)
        }
        let data = Data(converted.text.utf8)
        // Relecture de contrôle avant d'écrire : la base doit se charger.
        let tables: OUIDatabase.Tables
        do {
            tables = try OUIDatabase.parse(data, kind: .user, path: destination.path)
        } catch {
            throw Failure.registry("La base convertie est illisible.")
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        var source = tables.source
        source.url = destination
        return source
    }

    /// Supprime la base mise à jour et recharge : retour à la base fournie avec l'application.
    @discardableResult
    public func revert(database: OUIDatabase = .builtIn) throws -> OUIDatabase.Source {
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                throw Failure.write(error.localizedDescription)
            }
        }
        return database.reload()
    }

    private func download(_ file: OUIRegistry.File, session: URLSession,
                          part: @escaping @Sendable (Double) -> Void) async throws -> Data {
        var request = URLRequest(url: file.url, timeoutInterval: timeout)
        request.setValue("NetScope", forHTTPHeaderField: "User-Agent")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.network(file.name, error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(file.name, http.statusCode)
        }
        let expected = max(response.expectedContentLength, 0)
        if expected > OUIUpdater.maximumFileSize { throw Failure.registry("\(file.name) est anormalement volumineux : téléchargement refusé.") }
        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 4_000_000)
        var buffer: [UInt8] = []
        buffer.reserveCapacity(65_536)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 65_536 {
                    data.append(contentsOf: buffer)
                    if data.count > OUIUpdater.maximumFileSize {
                        throw Failure.registry("\(file.name) est anormalement volumineux : téléchargement refusé.")
                    }
                    buffer.removeAll(keepingCapacity: true)
                    if expected > 0 { part(min(Double(data.count) / Double(expected), 1)) }
                    try Task.checkCancellation()
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network(file.name, error.localizedDescription)
        }
        data.append(contentsOf: buffer)
        part(1)
        return data
    }
}
