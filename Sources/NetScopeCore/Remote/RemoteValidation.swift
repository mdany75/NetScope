import Darwin
import Foundation

/// Erreurs de validation d'une connexion.
public enum RemoteValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case emptyHost
    case invalidHost(String)
    case invalidUser(String)
    case invalidPort(Int)
    case invalidSerialDevice(String)
    case invalidBaud(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Donnez un nom à la connexion."
        case .emptyHost: return "Indiquez l’hôte ou l’adresse IP."
        case .invalidHost(let host): return "Hôte invalide : « \(host) ». Caractères permis : lettres, chiffres, point, tiret, deux-points."
        case .invalidUser(let user): return "Nom d’utilisateur invalide : « \(user) »."
        case .invalidPort(let port): return "Port invalide : \(port) (1 à 65535)."
        case .invalidSerialDevice(let path): return "Port série invalide : « \(path) » (attendu : /dev/cu.…)."
        case .invalidBaud(let baud): return "Débit série non pris en charge : \(baud) bauds."
        }
    }
}

/// Validation stricte des champs qui finissent dans une ligne de commande, une URL ou un
/// fichier .rdp : seule une liste fermée de caractères est acceptée (aucune injection possible).
public enum RemoteValidator {
    /// Mêmes débits que l’onglet de la console série (`SerialSettings.baudRates`).
    public static let baudRates = SerialSettings.baudRates

    private static let hostCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_")
    private static let userCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@")
    private static let deviceCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Nom d'hôte, IPv4 ou IPv6 : [A-Za-z0-9._:-], 253 caractères au plus, sans tiret ni point
    /// au début (un « -oProxyCommand=… » serait pris pour une option).
    @discardableResult
    public static func validateHost(_ text: String) throws -> String {
        let host = text.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw RemoteValidationError.emptyHost }
        guard host.count <= 253, host.allSatisfy({ hostCharacters.contains($0) }),
              let first = host.first, first != "-", first != ".", !host.contains("..") else {
            throw RemoteValidationError.invalidHost(host)
        }
        // « hôte:22 » n'est pas un hôte : un deux-points n'est permis que dans une IPv6 valide.
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { throw RemoteValidationError.invalidHost(host) }
        }
        return host
    }

    /// Utilisateur : vide permis ; [A-Za-z0-9._@-], plus « \ » pour un domaine Windows en RDP
    /// (« CORP\dmenard », qui ne passe jamais par un shell).
    @discardableResult
    public static func validateUser(_ text: String, allowDomain: Bool = false) throws -> String {
        let user = text.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return "" }
        let valid = user.count <= 104 && user.first != "-" && user.first != "@"
            && user.allSatisfy { userCharacters.contains($0) || (allowDomain && $0 == "\\") }
            && user.filter({ $0 == "\\" }).count <= 1
        guard valid else { throw RemoteValidationError.invalidUser(user) }
        return user
    }

    public static func validatePort(_ port: Int) throws {
        guard (1...65_535).contains(port) else { throw RemoteValidationError.invalidPort(port) }
    }

    /// Périphérique série : /dev/cu.<nom> ou /dev/tty.<nom>.
    @discardableResult
    public static func validateSerialDevice(_ text: String) throws -> String {
        let path = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["/dev/cu.", "/dev/tty."] where path.hasPrefix(prefix) {
            let name = path.dropFirst(prefix.count)
            if !name.isEmpty, name.count <= 64, name.first != "-", name.allSatisfy({ deviceCharacters.contains($0) }) {
                return path
            }
        }
        throw RemoteValidationError.invalidSerialDevice(path)
    }
}

/// Échappement pour le shell et pour AppleScript (défense en profondeur : les champs sont déjà
/// validés, mais rien n'est jamais inséré tel quel).
public enum RemoteShell {
    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/@=,+")

    /// Mot inchangé s'il ne contient que des caractères sûrs, sinon entre apostrophes
    /// (une apostrophe devient '\'').
    public static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Titre ou nom venu du réseau (mDNS, DNS inverse, NetBIOS) : caractères de contrôle (ESC, BEL,
    /// CR, tabulation, U+2028, U+2029…) remplacés par des espaces, une seule ligne, longueur limitée.
    /// Aucune séquence d'échappement ne peut ainsi atteindre Terminal.
    public static func sanitizedTitle(_ text: String, limit: Int = 120) -> String {
        let line = AlertText.singleLine(text)
        return line.count > limit ? String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// Ligne de commande à partir de mots.
    public static func command(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    /// Chaîne AppleScript entre guillemets droits (« \ » et « " » échappés, retours à la ligne refusés).
    public static func appleScriptString(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"" + escaped + "\""
    }
}
