import Foundation

/// Chemins distants (toujours « / », quel que soit le serveur) et règles de sécurité des noms.
public enum RemotePath {
    /// « / » + « pub » → « /pub » ; « /pub/ » + « a b » → « /pub/a b ».
    public static func join(_ directory: String, _ name: String) -> String {
        if name.hasPrefix("/") { return normalize(name) }
        let base = directory.isEmpty ? "/" : directory
        return normalize(base.hasSuffix("/") ? base + name : base + "/" + name)
    }

    /// Dossier parent (« /pub/firmware » → « /pub », « /pub » → « / », « / » → « / »).
    public static func parent(_ path: String) -> String {
        let clean = normalize(path)
        guard clean != "/", let slash = clean.lastIndex(of: "/") else { return "/" }
        let parent = String(clean[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// Dernier élément (« /pub/a.bin » → « a.bin »).
    public static func name(_ path: String) -> String {
        let clean = normalize(path)
        guard clean != "/" else { return "/" }
        return clean.split(separator: "/").last.map(String.init) ?? clean
    }

    /// Supprime les « // », « . » et résout « .. » sans jamais remonter au-dessus de la racine.
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        let relative = !path.hasPrefix("/") && !path.isEmpty
        let joined = parts.joined(separator: "/")
        if relative { return joined.isEmpty ? "." : joined }
        return "/" + joined
    }

    /// Fil d'Ariane : « /pub/firmware » → [(« / », « / »), (« pub », « /pub »), (« firmware », « /pub/firmware »)].
    public static func breadcrumbs(_ path: String) -> [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var current = ""
        for part in normalize(path).split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    /// Chemin envoyé au serveur : jamais de retour à la ligne ni d'octet nul (une commande FTP
    /// ou sftp pourrait sinon être injectée à la suite).
    public static func validate(_ path: String) throws -> String {
        guard !path.isEmpty else { throw FileTransferError.invalidName(path) }
        // Par scalaire Unicode : « \r\n » forme un seul caractère Swift, différent de « \r » et de « \n ».
        guard !path.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw FileTransferError.invalidName(path)
        }
        return path
    }

    /// Nom d'un nouveau dossier ou d'un renommage : pas de « / », pas « . » ni « .. », rien d'invisible.
    public static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FileTransferError.invalidName(name)
        }
        return trimmed
    }

    /// Nom d'élément d'une liste distante acceptable : un seul élément de chemin (ni « / » ni « \\ »,
    /// ni « . » ni « .. », ni caractère nul). Un serveur qui renvoie « ../../x » est ignoré.
    public static func isSafeEntryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains("\0")
    }

    /// Nom local sûr pour un fichier reçu : le dernier élément seulement (jamais « ../ »).
    public static func safeLocalName(_ remoteName: String) -> String {
        let last = remoteName.split(separator: "/").last.map(String.init) ?? remoteName
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .replacingOccurrences(of: ":", with: "-")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "fichier" }
        return cleaned
    }

    /// Argument d'une commande sftp : entre guillemets, avec « \ » devant « " », « \ » et les
    /// caractères de motif (« * », « ? », « [ », « ] ») que sftp développerait sinon.
    public static func sftpQuoted(_ path: String) throws -> String {
        let valid = try validate(path)
        var result = "\""
        for character in valid {
            if "\"\\*?[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result + "\""
    }
}

/// Taille lisible : « 1,2 Mo », « 845 o » (unités françaises, puissances de 1000 comme le Finder).
public enum FileTransferFormat {
    public static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        if bytes < 1_000 { return "\(bytes)\u{00A0}o" }
        let units = ["ko", "Mo", "Go", "To"]
        var value = Double(bytes) / 1_000
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.maximumFractionDigits = value < 10 ? 1 : 0
        formatter.minimumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
        return number + "\u{00A0}" + units[unit]
    }

    /// Débit : « 11,4 Mo/s ».
    public static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "—" }
        return size(Int64(bytesPerSecond)) + "/s"
    }

    /// Temps restant : « 12 s », « 3 min 05 s », « 1 h 02 min ».
    public static func remaining(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)\u{00A0}s" }
        if total < 3_600 { return String(format: "%d\u{00A0}min %02d\u{00A0}s", total / 60, total % 60) }
        return String(format: "%d\u{00A0}h %02d\u{00A0}min", total / 3_600, (total % 3_600) / 60)
    }
}
