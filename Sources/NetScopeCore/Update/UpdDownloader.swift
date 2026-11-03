import Foundation

/// Télécharge l'image disque d'une version dans un dossier temporaire, avec progression.
/// Une instance par téléchargement ; `cancel()` l'interrompt.
public final class UpdDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias Progress = @Sendable (_ received: Int64, _ expected: Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var savedFile: URL?
    private var moveError: Error?
    private var progress: Progress?
    private var expectedSize: Int64 = 0
    private var originalHost: String?
    private var hasToken = false
    /// Annulation demandée (éventuellement avant le démarrage de la tâche).
    private var isCancelled = false

    public override init() {}

    /// Requête de téléchargement : adresse publique, ou adresse de l'API avec le jeton (dépôt privé).
    public static func request(for asset: UpdAsset, token: String?) -> URLRequest {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, let api = asset.apiURL {
            var request = URLRequest(url: api)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            request.setValue("NetScope", forHTTPHeaderField: "User-Agent")
            return request
        }
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("NetScope", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Télécharge `asset` ; renvoie le fichier « NetScope.dmg » dans un dossier temporaire propre.
    public func download(_ asset: UpdAsset, token: String?, progress: @escaping Progress) async throws -> URL {
        let request = UpdDownloader.request(for: asset, token: token)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.lock()
                if self.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: UpdError.cancelled)
                    return
                }
                self.continuation = continuation
                self.progress = progress
                self.expectedSize = asset.size
                self.originalHost = request.url?.host
                self.hasToken = request.value(forHTTPHeaderField: "Authorization") != nil
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let progress = self.progress
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        lock.unlock()
        progress?(totalBytesWritten, expected)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Le fichier fourni est supprimé au retour de cette méthode : on le déplace tout de suite.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.lock()
            moveError = UpdateChecker.error(forStatus: http.statusCode, hasToken: hasToken) ?? UpdError.http(http.statusCode)
            lock.unlock()
            return
        }
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("NetScope-maj-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(UpdateChecker.assetName)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            savedFile = destination
            lock.unlock()
        } catch {
            lock.lock()
            moveError = UpdError.installation("Enregistrement du téléchargement impossible : \(error.localizedDescription)")
            lock.unlock()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        // GitHub redirige vers un stockage signé : le jeton ne doit pas suivre hors de GitHub.
        var next = request
        lock.lock()
        let host = originalHost
        lock.unlock()
        guard request.url?.scheme?.lowercased() == "https" else {
            // Jamais de repli en HTTP clair : la redirection est refusée.
            completionHandler(nil)
            return
        }
        if request.url?.host?.lowercased() != host?.lowercased() { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let file = savedFile
        let moveError = self.moveError
        self.session = nil
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()

        if let error = error as? URLError, error.code == .cancelled {
            continuation?.resume(throwing: UpdError.cancelled)
        } else if let error {
            continuation?.resume(throwing: UpdError.network(error.localizedDescription))
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else if let file {
            continuation?.resume(returning: file)
        } else {
            continuation?.resume(throwing: UpdError.installation("Téléchargement vide."))
        }
    }
}
