import Foundation

/// Fichier joint à une version GitHub (« NetScope.dmg »).
public struct UpdAsset: Codable, Hashable, Sendable {
    public var name: String
    /// Taille en octets.
    public var size: Int64
    /// Adresse publique de téléchargement (dépôt public).
    public var browserDownloadURL: URL
    /// Adresse de l'API (« …/releases/assets/123 ») : téléchargement avec un jeton (dépôt privé).
    public var apiURL: URL?
    public var contentType: String?

    public init(name: String, size: Int64, browserDownloadURL: URL, apiURL: URL? = nil, contentType: String? = nil) {
        self.name = name
        self.size = size
        self.browserDownloadURL = browserDownloadURL
        self.apiURL = apiURL
        self.contentType = contentType
    }

    enum CodingKeys: String, CodingKey {
        case name, size
        case browserDownloadURL = "browser_download_url"
        case apiURL = "url"
        case contentType = "content_type"
    }
}

/// Version publiée dans les Releases GitHub.
public struct UpdRelease: Codable, Hashable, Sendable, Identifiable {
    public var tagName: String
    public var name: String?
    /// Notes de version (Markdown).
    public var body: String?
    public var publishedAt: Date?
    public var isPrerelease: Bool
    public var isDraft: Bool
    public var htmlURL: URL?
    public var assets: [UpdAsset]

    public var id: String { tagName }

    public init(tagName: String, name: String? = nil, body: String? = nil, publishedAt: Date? = nil,
                isPrerelease: Bool = false, isDraft: Bool = false, htmlURL: URL? = nil, assets: [UpdAsset] = []) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.isDraft = isDraft
        self.htmlURL = htmlURL
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case publishedAt = "published_at"
        case isPrerelease = "prerelease"
        case isDraft = "draft"
        case htmlURL = "html_url"
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL)
        assets = try container.decodeIfPresent([UpdAsset].self, forKey: .assets) ?? []
    }

    /// Version lue dans l'étiquette (« v1.1.0 »), ou à défaut dans le titre.
    public var version: UpdVersion? {
        UpdVersion(tagName) ?? name.flatMap { UpdVersion($0.replacingOccurrences(of: "NetScope ", with: "")) }
    }

    /// Image disque d'installation (« NetScope.dmg », casse indifférente).
    public var diskImage: UpdAsset? {
        assets.first { $0.name.caseInsensitiveCompare(UpdateChecker.assetName) == .orderedSame }
    }

    /// Notes en lignes simples : puces Markdown retirées, lignes vides et titres « ## » ignorés.
    public var noteLines: [String] {
        guard let body else { return [] }
        return body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                for prefix in ["- ", "* ", "+ ", "• "] where text.hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count))
                    break
                }
                return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

extension JSONDecoder {
    /// Décodeur des réponses GitHub (dates ISO 8601 « 2026-10-28T14:03:00Z »).
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date illisible : \(text)")
        }
        return decoder
    }
}
