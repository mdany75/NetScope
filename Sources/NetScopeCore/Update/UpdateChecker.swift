import Foundation

/// Erreurs de la mise à jour, avec un message prêt à afficher.
public enum UpdError: Error, Equatable, LocalizedError, Sendable {
    /// 404 : dépôt privé (sans jeton) ou inaccessible avec le jeton fourni.
    case privateRepository(hasToken: Bool)
    /// 401 : jeton refusé.
    case badToken
    /// 403 ou 429 : limite de requêtes atteinte.
    case rateLimited
    case http(Int)
    case invalidResponse(String)
    case network(String)
    /// La version ne contient pas l'image disque attendue.
    case missingAsset(version: String)
    /// Installation impossible dans cet environnement (lancement par swift run, droits…).
    case notInstallable(String)
    /// Signature absente, invalide ou d'une autre équipe.
    case verification(String)
    case installation(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .privateRepository(false):
            return "Dépôt privé : rendre le dépôt public ou fournir un jeton GitHub."
        case .privateRepository(true):
            return "Dépôt introuvable avec ce jeton GitHub : vérifier qu’il donne accès en lecture au dépôt mdany75/NetScope."
        case .badToken:
            return "Jeton GitHub refusé (expiré ou révoqué) : le remplacer ou le supprimer."
        case .rateLimited:
            return "Limite de requêtes de l’API GitHub atteinte : réessayer dans une heure, ou fournir un jeton."
        case .http(let code):
            return "Réponse inattendue de GitHub (HTTP \(code))."
        case .invalidResponse(let detail):
            return "Réponse de GitHub illisible : \(detail)"
        case .network(let detail):
            return "GitHub injoignable : \(detail)"
        case .missingAsset(let version):
            return "La version \(version) ne contient pas d’image « NetScope.dmg »."
        case .notInstallable(let detail), .verification(let detail), .installation(let detail):
            return detail
        case .cancelled:
            return "Opération annulée."
        }
    }
}

/// Résultat d'une vérification.
public struct UpdCheckResult: Equatable, Sendable {
    /// Version la plus récente du canal (même si elle n'est pas plus récente que l'installée).
    public var latest: UpdRelease?
    /// Version à proposer (plus récente que l'installée, avec une image disque), ou nil.
    public var update: UpdRelease?

    public init(latest: UpdRelease?, update: UpdRelease?) {
        self.latest = latest
        self.update = update
    }
}

/// Interroge les Releases GitHub du projet.
/// Canal Stable : `/releases/latest` (GitHub exclut lui-même brouillons et préversions).
/// Canal Bêta : `/releases` (liste), préversions comprises.
public struct UpdateChecker: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let defaultOwner = "mdany75"
    public static let defaultRepository = "NetScope"
    public static let assetName = "NetScope.dmg"
    public static let apiBase = URL(string: "https://api.github.com")!

    public var owner: String
    public var repository: String
    /// Jeton d'accès personnel (dépôt privé) ; nil pour un dépôt public.
    public var token: String?
    public var transport: Transport

    public init(owner: String = UpdateChecker.defaultOwner, repository: String = UpdateChecker.defaultRepository,
                token: String? = nil, transport: @escaping Transport = UpdateChecker.urlSessionTransport) {
        self.owner = owner
        self.repository = repository
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.transport = transport
    }

    /// Transport réel (URLSession, sans cache).
    public static let urlSessionTransport: Transport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    /// Page web des versions.
    public var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }

    // MARK: Requêtes

    func request(path: String) -> URLRequest {
        let url = URL(string: "repos/\(owner)/\(repository)" + path, relativeTo: UpdateChecker.apiBase)!.absoluteURL
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NetScope", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// Requête de la liste ou de la dernière version, selon le canal.
    public func releasesRequest(channel: UpdChannel) -> URLRequest {
        channel == .stable ? request(path: "/releases/latest") : request(path: "/releases?per_page=30")
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw UpdError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw UpdError.cancelled
        } catch {
            throw UpdError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UpdError.invalidResponse("pas une réponse HTTP") }
        return (data, http.statusCode)
    }

    /// Versions publiées du canal (la dernière seule pour Stable).
    public func fetchReleases(channel: UpdChannel) async throws -> [UpdRelease] {
        let (data, status) = try await send(releasesRequest(channel: channel))
        if status == 404 && channel == .stable {
            // /releases/latest répond aussi 404 quand le dépôt public n'a aucune version finale :
            // on interroge le dépôt pour distinguer les deux cas.
            let (_, repoStatus) = try await send(request(path: ""))
            if repoStatus == 200 { return [] }
            if let error = UpdateChecker.error(forStatus: repoStatus, hasToken: token != nil) { throw error }
            return []
        }
        if let error = UpdateChecker.error(forStatus: status, hasToken: token != nil) { throw error }
        return channel == .stable ? [try UpdateChecker.decodeRelease(data)] : try UpdateChecker.decodeReleases(data)
    }

    /// Vérifie s'il existe une version plus récente que `current` sur le canal.
    public func check(current: UpdVersion, channel: UpdChannel) async throws -> UpdCheckResult {
        let releases = try await fetchReleases(channel: channel)
        return UpdateChecker.evaluate(releases, current: current, channel: channel)
    }

    // MARK: Logique pure (testée sans réseau)

    /// Erreur correspondant à un code HTTP, ou nil si la réponse est exploitable (2xx).
    public static func error(forStatus status: Int, hasToken: Bool) -> UpdError? {
        switch status {
        case 200..<300: return nil
        case 401: return .badToken
        case 403, 429: return .rateLimited
        case 404: return .privateRepository(hasToken: hasToken)
        default: return .http(status)
        }
    }

    public static func decodeRelease(_ data: Data) throws -> UpdRelease {
        do {
            return try JSONDecoder.github.decode(UpdRelease.self, from: data)
        } catch {
            throw UpdError.invalidResponse(describe(error))
        }
    }

    public static func decodeReleases(_ data: Data) throws -> [UpdRelease] {
        do {
            return try JSONDecoder.github.decode([UpdRelease].self, from: data)
        } catch {
            throw UpdError.invalidResponse(describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "champ « \(key.stringValue) » manquant"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            return context.debugDescription
        default: return error.localizedDescription
        }
    }

    /// Choisit la version à proposer : la plus récente du canal (brouillons exclus, préversions
    /// seulement en Bêta), si elle est plus récente que `current` et contient l'image disque.
    public static func evaluate(_ releases: [UpdRelease], current: UpdVersion, channel: UpdChannel) -> UpdCheckResult {
        let candidates = releases
            .filter { !$0.isDraft && $0.version != nil }
            .filter { channel == .beta || (!$0.isPrerelease && !($0.version?.isPrerelease ?? false)) }
            .sorted { $0.version! > $1.version! }
        let latest = candidates.first
        let update = candidates.first { $0.version! > current && $0.diskImage != nil }
        return UpdCheckResult(latest: latest, update: update)
    }
}
