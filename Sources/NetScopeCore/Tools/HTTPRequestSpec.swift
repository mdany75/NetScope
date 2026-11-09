import Foundation

// Note 116 : Testeur HTTP ou API. Requête décrite, validée et masquée sans toucher au réseau.

public enum HTTPMethod: String, CaseIterable, Sendable {
    case get = "GET", head = "HEAD", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE", options = "OPTIONS"

    /// URLSession refuse un GET avec corps (erreur -1103) : mieux vaut le dire avant d'envoyer.
    public var allowsBody: Bool { self != .get && self != .head }
}

public struct HTTPHeader: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct HTTPRequestSpec: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: String
    public var headers: [HTTPHeader]
    public var body: String?
    public var followRedirects: Bool
    public var acceptsUntrustedCertificate: Bool
    public var timeout: TimeInterval

    public init(method: HTTPMethod = .get, url: String, headers: [HTTPHeader] = [], body: String? = nil,
                followRedirects: Bool = true, acceptsUntrustedCertificate: Bool = false, timeout: TimeInterval = 15) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.followRedirects = followRedirects
        self.acceptsUntrustedCertificate = acceptsUntrustedCertificate
        self.timeout = timeout
    }
}

public enum HTTPSpecError: Error, LocalizedError, Equatable, Sendable {
    case emptyURL, invalidURL, missingHost
    case unsupportedScheme(String)
    case invalidHeaderName(String)
    case invalidHeaderValue(String)
    case bodyNotAllowed(HTTPMethod)
    case invalidTimeout

    public var errorDescription: String? {
        switch self {
        case .emptyURL: return "Saisir une URL."
        case .invalidURL: return "URL invalide\u{00A0}: elle ne doit contenir ni espace ni saut de ligne."
        case .missingHost: return "URL sans nom d’hôte."
        case .unsupportedScheme(let scheme):
            return scheme.isEmpty ? "L’URL doit commencer par http:// ou https://."
                : "Seuls http:// et https:// sont acceptés (reçu\u{00A0}: \(scheme))."
        case .invalidHeaderName(let name):
            return name.isEmpty ? "Un en-tête a une valeur mais pas de nom." : "Nom d’en-tête invalide\u{00A0}: «\u{00A0}\(name)\u{00A0}»."
        case .invalidHeaderValue(let name): return "La valeur de l’en-tête «\u{00A0}\(name)\u{00A0}» contient un saut de ligne ou un caractère de contrôle."
        case .bodyNotAllowed(let method): return "\(method.rawValue) n’envoie pas de corps\u{00A0}: vider le corps ou choisir POST, PUT, PATCH, DELETE ou OPTIONS."
        case .invalidTimeout: return "Le délai doit être supérieur à zéro."
        }
    }
}

extension HTTPRequestSpec {
    /// Caractères permis dans un nom d'en-tête (« token » de la RFC 9110).
    private static let headerNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")

    /// Vérifie la requête sans rien envoyer et rend l'URL à utiliser.
    public func validatedURL() throws -> URL {
        let text = url.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw HTTPSpecError.emptyURL }
        // Depuis macOS 14, URL(string:) encode ces caractères au lieu de refuser l'adresse.
        guard !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parsed = URLComponents(string: text) else { throw HTTPSpecError.invalidURL }
        let scheme = parsed.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw HTTPSpecError.unsupportedScheme(scheme) }
        guard let host = parsed.host, !host.isEmpty else { throw HTTPSpecError.missingHost }
        guard let result = parsed.url else { throw HTTPSpecError.invalidURL }
        for header in headers {
            guard !header.name.isEmpty, header.name.unicodeScalars.allSatisfy(Self.headerNameCharacters.contains) else {
                throw HTTPSpecError.invalidHeaderName(header.name)
            }
            // La tabulation est permise par HTTP, pas les autres caractères de contrôle.
            guard header.value.unicodeScalars.allSatisfy({ $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }) else {
                throw HTTPSpecError.invalidHeaderValue(header.name)
            }
        }
        if !method.allowsBody, let body, !body.isEmpty { throw HTTPSpecError.bodyNotAllowed(method) }
        guard timeout > 0 else { throw HTTPSpecError.invalidTimeout }
        return result
    }
}

/// Masquage de ce qui reste à l'écran ou sur disque après l'envoi : ligne de commande et historique.
public enum HTTPRedaction {
    public static let mask = "•••"

    private static let sensitiveTerms = ["auth", "cookie", "token", "jeton", "secret", "key", "pass", "pwd", "mdp", "session", "signature", "credential", "jwt"]

    /// Noms de paramètres trop courts pour être cherchés à l'intérieur d'un autre mot.
    private static let sensitiveExactNames: Set<String> = ["sig", "otp", "pin", "cle", "clé"]

    /// Après ces segments, le chemin d'un webhook est lui-même le secret.
    private static let webhookSegments: Set<String> = ["hook", "hooks", "webhook", "webhooks"]

    private static func isSensitiveName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return sensitiveExactNames.contains(lowered) || sensitiveTerms.contains { lowered.contains($0) }
    }

    public static func isSensitive(_ header: HTTPHeader) -> Bool {
        if isSensitiveName(header.name) { return true }
        let value = header.value.trimmingCharacters(in: .whitespaces).lowercased()
        return value.hasPrefix("bearer ") || value.hasPrefix("basic ") || value.hasPrefix("digest ")
    }

    public static func masked(_ header: HTTPHeader) -> HTTPHeader {
        isSensitive(header) ? HTTPHeader(name: header.name, value: mask) : header
    }

    /// Travaille sur le texte brut : la commande affichée suit une URL encore incomplète ou invalide.
    public static func maskedURL(_ text: String) -> String {
        var rest = Substring(text)
        var fragment: Substring?
        if let hash = rest.firstIndex(of: "#") {
            fragment = rest[rest.index(after: hash)...]
            rest = rest[..<hash]
        }
        var query: Substring?
        if let mark = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: mark)...]
            rest = rest[..<mark]
        }
        var result = maskedBase(rest)
        if let query { result += "?" + maskedParameters(query) }
        if let fragment { result += "#" + maskedParameters(fragment) }
        return result
    }

    /// Tout l'identifiant part : `https://JETON@hôte` n'a pas de mot de passe mais reste un secret.
    private static func maskedBase(_ base: Substring) -> String {
        let start = base.range(of: "://")?.upperBound ?? base.startIndex
        let end = base[start...].firstIndex(of: "/") ?? base.endIndex
        let at = base[start..<end].lastIndex(of: "@")
        let identity = at.map { _ in mask } ?? ""
        let host = base[(at ?? start)..<end]
        return base[..<start] + identity + host + maskedPath(base[end...], host: at == nil ? host : host.dropFirst())
    }

    private static func maskedPath(_ path: Substring, host: Substring) -> String {
        var isHidden = host.lowercased().hasPrefix("hooks.")
        return path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            defer { if webhookSegments.contains(segment.lowercased()) { isHidden = true } }
            if segment.isEmpty { return "" }
            return isHidden || looksLikeToken(segment) ? mask : maskedParameters(segment)
        }
        .joined(separator: "/")
    }

    /// Long, lettres et chiffres mêlés : un jeton plutôt qu'un nom de ressource.
    private static func looksLikeToken(_ segment: Substring) -> Bool {
        segment.count >= 20 && segment.contains(where: \.isLetter) && segment.contains(where: \.isNumber)
    }

    /// Le « ; » sépare aussi les paramètres, en requête comme dans un chemin (`;jsessionid=`).
    private static func maskedParameters(_ text: Substring) -> String {
        var result = ""
        var rest = text
        while true {
            let end = rest.firstIndex { $0 == "&" || $0 == ";" } ?? rest.endIndex
            result += maskedPair(rest[..<end])
            guard end < rest.endIndex else { return result }
            result.append(rest[end])
            rest = rest[rest.index(after: end)...]
        }
    }

    private static func maskedPair(_ pair: Substring) -> String {
        guard let equal = pair.firstIndex(of: "=") else { return String(pair) }
        let name = String(pair[..<equal])
        return isSensitiveName(name.removingPercentEncoding ?? name) ? "\(name)=\(mask)" : String(pair)
    }

    /// Ligne `curl` de l'en-tête de l'outil : le corps n'y figure jamais.
    public static func commandLine(_ spec: HTTPRequestSpec) -> String {
        var parts = ["curl"]
        switch spec.method {
        case .get: break
        case .head: parts.append("-I")
        default: parts.append("-X \(spec.method.rawValue)")
        }
        if spec.followRedirects { parts.append("-L") }
        if spec.acceptsUntrustedCertificate { parts.append("-k") }
        for header in spec.headers.map(masked) { parts.append("-H \(shellQuoted("\(header.name): \(header.value)"))") }
        if let body = spec.body, !body.isEmpty { parts.append("-d <corps>") }
        let url = spec.url.trimmingCharacters(in: .whitespaces)
        parts.append(url.isEmpty ? "<url>" : shellQuoted(maskedURL(url)))
        return parts.joined(separator: " ")
    }

    /// Entrée de l'historique : méthode et URL masquée, rien d'autre.
    public static func historyLine(_ spec: HTTPRequestSpec) -> String {
        "\(spec.method.rawValue) \(maskedURL(spec.url.trimmingCharacters(in: .whitespaces)))"
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Règles de suivi d'une redirection, communes aux deux chemins d'envoi.
public enum HTTPRedirectPolicy {
    public static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased()
            && port(first) == port(second)
    }

    /// URLSession recopie les en-têtes vers la nouvelle adresse : sans ce filtre, un 302 vers un
    /// autre hôte (ou de https vers http) y enverrait le jeton saisi. Comme curl, un Host saisi ne
    /// suit pas un changement d'hôte ; un Content-Length sans corps ferait attendre le serveur.
    public static func headers(_ headers: [HTTPHeader], from source: URL, to target: URL, keepsBody: Bool) -> [HTTPHeader] {
        let sameHost = source.host?.lowercased() == target.host?.lowercased()
        return (sameOrigin(source, target) ? headers : headers.filter { !HTTPRedaction.isSensitive($0) }).filter { header in
            switch header.name.lowercased() {
            case "host": return sameHost
            case "content-length", "transfer-encoding": return keepsBody
            default: return true
            }
        }
    }

    /// 303, et 301 ou 302 après un POST, repartent en GET sans corps, comme les navigateurs.
    public static func method(_ method: String, after status: Int) -> String {
        if status == 303 { return method == "HEAD" ? "HEAD" : "GET" }
        if status == 301 || status == 302 { return method == "POST" ? "GET" : method }
        return method
    }
}

public enum HTTPBodyFormat {
    /// JSON réindenté (2 espaces) ; nil si le corps n'est pas un objet ou un tableau JSON valide.
    /// Réécrit le texte au lieu de passer par JSONSerialization, qui mélangerait l'ordre des clés
    /// et arrondirait les grands nombres.
    public static func prettyJSON(_ data: Data) -> String? {
        guard let first = data.first(where: { !isJSONSpace($0) }), first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        var output = [UInt8]()
        output.reserveCapacity(data.count * 2)
        var depth = 0
        var inString = false
        var escaped = false
        var justOpened = false

        func newline() {
            output.append(UInt8(ascii: "\n"))
            output.append(contentsOf: repeatElement(UInt8(ascii: " "), count: depth * 2))
        }

        for byte in data {
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            if isJSONSpace(byte) { continue }
            let closes = byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
            if closes { depth -= 1 }
            // « {} » et « [] » restent sur une ligne.
            if justOpened, !closes { newline() } else if closes, !justOpened { newline() }
            justOpened = false
            output.append(byte)
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                justOpened = true
            case UInt8(ascii: ","): newline()
            case UInt8(ascii: ":"): output.append(UInt8(ascii: " "))
            default: break
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isJSONSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static let binaryTypes = ["image/", "audio/", "video/", "application/octet-stream", "application/zip", "application/gzip", "application/pdf"]

    static func isBinary(_ data: Data, contentType: String?) -> Bool {
        if let type = contentType?.lowercased(), binaryTypes.contains(where: type.hasPrefix) { return true }
        return data.prefix(4096).contains(0)
    }
}
