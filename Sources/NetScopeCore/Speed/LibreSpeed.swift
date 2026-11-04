import Foundation

// LibreSpeed (logiciel libre, serveurs souvent hébergés par des fournisseurs) :
//   GET  <base>garbage.php?ckSize=N   N blocs de 1 Mio de données aléatoires (téléchargement)
//   POST <base>empty.php              corps ignoré (téléversement)
//   GET  <base>empty.php              réponse vide (latence)
//   GET  <base>getIP.php?isp=true     IP publique et fournisseur
// Liste publique des serveurs : https://librespeed.org/backend-servers/servers.php

/// Points d'accès d'un serveur LibreSpeed.
public struct LibreSpeedEndpoints: Hashable, Sendable {
    public static let defaultDownload = "garbage.php"
    public static let defaultUpload = "empty.php"
    public static let defaultPing = "empty.php"
    public static let defaultIP = "getIP.php"
    /// Taille d'un bloc de garbage.php.
    public static let chunkBytes = 1_048_576

    public var base: URL
    public var downloadPath: String
    public var uploadPath: String
    public var pingPath: String
    public var ipPath: String

    public init(base: URL, downloadPath: String = defaultDownload, uploadPath: String = defaultUpload,
                pingPath: String = defaultPing, ipPath: String = defaultIP) {
        // Une base sans « / » final perdrait son dernier segment en résolvant les chemins.
        let text = base.absoluteString
        self.base = text.hasSuffix("/") ? base : (URL(string: text + "/") ?? base)
        self.downloadPath = downloadPath
        self.uploadPath = uploadPath
        self.pingPath = pingPath
        self.ipPath = ipPath
    }

    /// Points d'accès d'un serveur de la liste ou personnalisé (nil sans URL de base valide).
    public init?(server: SpeedServer) {
        guard let text = server.baseURL, let url = URL(string: text), url.scheme != nil else { return nil }
        self.init(base: url, downloadPath: server.downloadPath ?? Self.defaultDownload,
                  uploadPath: server.uploadPath ?? Self.defaultUpload, pingPath: server.pingPath ?? Self.defaultPing,
                  ipPath: server.ipPath ?? Self.defaultIP)
    }

    func url(_ path: String, query: [URLQueryItem]) -> URL {
        let resolved = URL(string: path, relativeTo: base)?.absoluteURL ?? base.appendingPathComponent(path)
        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return resolved }
        components.queryItems = (components.queryItems ?? []) + query
        return components.url ?? resolved
    }

    /// garbage.php?ckSize=N (N blocs de 1 Mio, au moins 1) ; « r » évite les caches.
    public func downloadURL(bytes: Int, nonce: String = "0") -> URL {
        let chunks = max(1, Int((Double(bytes) / Double(Self.chunkBytes)).rounded(.up)))
        return url(downloadPath, query: [URLQueryItem(name: "r", value: nonce), URLQueryItem(name: "ckSize", value: String(chunks))])
    }

    public func uploadURL(nonce: String = "0") -> URL {
        url(uploadPath, query: [URLQueryItem(name: "r", value: nonce)])
    }

    public func pingURL(nonce: String = "0") -> URL {
        url(pingPath, query: [URLQueryItem(name: "r", value: nonce)])
    }

    public var ipURL: URL { url(ipPath, query: [URLQueryItem(name: "isp", value: "true")]) }
}

/// Lecture des réponses LibreSpeed, sans réseau (testable).
public enum LibreSpeedParser {
    public static let serverListURL = URL(string: "https://librespeed.org/backend-servers/servers.php")!

    /// Liste JSON des serveurs : [{"id","name","server","dlURL","ulURL","pingURL","getIpURL","sponsorName"}].
    public static func servers(_ data: Data) throws -> [SpeedServer] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SpeedParseError.invalidFormat("liste LibreSpeed")
        }
        return array.compactMap(server)
    }

    static func server(_ object: [String: Any]) -> SpeedServer? {
        guard let name = text(object["name"]), let raw = text(object["server"]) else { return nil }
        // « //ams.exemple.net/backend » : sans protocole, https.
        let full = raw.hasPrefix("//") ? "https:" + raw : (raw.contains("://") ? raw : "https://" + raw)
        guard var components = URLComponents(string: full), let host = components.host,
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let base = components.url?.absoluteString else { return nil }
        let id = text(object["id"]) ?? host
        let (city, country, sponsorInName) = splitName(name)
        return SpeedServer(id: "librespeed:\(id)", source: .librespeed, name: name, city: city, country: country,
                           sponsor: text(object["sponsorName"]) ?? sponsorInName, host: host,
                           port: components.port ?? (scheme == "https" ? 443 : 80), baseURL: base,
                           downloadPath: text(object["dlURL"]) ?? LibreSpeedEndpoints.defaultDownload,
                           uploadPath: text(object["ulURL"]) ?? LibreSpeedEndpoints.defaultUpload,
                           pingPath: text(object["pingURL"]) ?? LibreSpeedEndpoints.defaultPing,
                           ipPath: text(object["getIpURL"]) ?? LibreSpeedEndpoints.defaultIP)
    }

    /// « Montréal, Canada (Fibre Laurentides) » → (Montréal, Canada, Fibre Laurentides).
    public static func splitName(_ name: String) -> (city: String?, country: String?, sponsor: String?) {
        var rest = name.trimmingCharacters(in: .whitespaces)
        var sponsor: String?
        if rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
            sponsor = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let parts = rest.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let city = parts.first.flatMap { $0.isEmpty ? nil : $0 }
        let country = parts.count > 1 ? parts[1] : nil
        return (city, country, sponsor?.isEmpty == true ? nil : sponsor)
    }

    /// Réponse de getIP.php : JSON {"processedString":"IP - Fournisseur, CA","rawIspInfo":{"org":"AS577 Bell Canada"}}
    /// ou adresse IP seule en texte.
    public static func clientInfo(_ data: Data) -> SpeedServerInfo? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let processed = text(object["processedString"]) ?? ""
            let pieces = processed.components(separatedBy: " - ")
            var ip = pieces.first?.trimmingCharacters(in: .whitespaces)
            var asn: Int?
            var org: String?
            if pieces.count > 1 {
                var isp = pieces.dropFirst().joined(separator: " - ")
                // « Bell Canada, CA (12 km) » → « Bell Canada »
                if let paren = isp.range(of: " (", options: .backwards), isp.hasSuffix(")") { isp = String(isp[..<paren.lowerBound]) }
                if let comma = isp.range(of: ", ", options: .backwards), isp[comma.upperBound...].count == 2 { isp = String(isp[..<comma.lowerBound]) }
                org = isp.isEmpty ? nil : isp
            }
            if let raw = object["rawIspInfo"] as? [String: Any] {
                if ip == nil || ip?.isEmpty == true { ip = text(raw["ip"]) }
                if let orgField = text(raw["org"]) {
                    let (number, name) = splitASN(orgField)
                    asn = number
                    if org == nil { org = name }
                }
            }
            guard let address = ip, !address.isEmpty else { return nil }
            return SpeedServerInfo(clientIP: address, asn: asn, asOrganization: org)
        }
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.count <= 45, raw.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else { return nil }
        return SpeedServerInfo(clientIP: raw)
    }

    /// « AS577 Bell Canada » → (577, « Bell Canada »).
    public static func splitASN(_ text: String) -> (Int?, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix("AS") else { return (nil, trimmed.isEmpty ? nil : trimmed) }
        let body = trimmed.dropFirst(2)
        let digits = body.prefix { $0.isNumber }
        let name = body.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        return (Int(digits), name.isEmpty ? nil : name)
    }

    static func text(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

/// Réponse illisible d'une source de serveurs.
public enum SpeedParseError: Error, Equatable, LocalizedError {
    case invalidFormat(String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let what): return "Réponse illisible (\(what))."
        case .empty(let what): return "Aucun serveur reçu (\(what))."
        }
    }
}
