import Foundation

// « Ouvrir une fiche » (écran Appareil sans appareil choisi) : lecture de ce que le technicien tape
// dans le champ principal. Une adresse IPv4, une adresse MAC (toutes les écritures usuelles) ou un
// nom d'hôte ; sinon un message clair qui dit ce qui ne va pas. Aucune résolution DNS ici : un nom
// n'est résolu que sur demande (bouton « Résoudre » de l'écran).

/// Lecture de la saisie du champ « Ouvrir une fiche ».
public enum DeviceEntry: Equatable, Sendable {
    case empty
    case ip(IPv4Address)
    case mac(MACAddress)
    /// Nom d'hôte valide (RFC 1123), sans le point final.
    case hostname(String)
    /// Deux lectures possibles : douze chiffres hexadécimaux sans séparateur et sans chiffre
    /// décimal (« facefeedbead ») sont une MAC aussi bien qu'un nom d'hôte.
    case ambiguous(mac: MACAddress, hostname: String)
    /// Ni IP, ni MAC, ni nom d'hôte : la raison, en français.
    case invalid(String)

    /// Lit la saisie (espaces autour ignorés).
    public static func parse(_ text: String) -> DeviceEntry {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if let ip = IPv4Address(trimmed) { return .ip(ip) }
        let lower = trimmed.lowercased()

        // Chiffres et points seulement : une adresse IP mal écrite.
        if lower.allSatisfy({ $0 == "." || ($0.isASCII && $0.isNumber) }) {
            return .invalid(ipProblem(lower))
        }
        // Adresse avec masque ou préfixe : une adresse seule est attendue.
        if let slash = lower.firstIndex(of: "/") {
            let head = String(lower[..<slash])
            if IPv4Address(head) != nil {
                return .invalid("Une seule adresse est attendue, sans masque\u{00A0}: \(head)")
            }
        }
        if lower.contains(":") { return macWithColons(lower) }
        if let mac = groupedMAC(lower) { return .mac(mac) }
        if lower.contains("-") || lower.contains("."), let mac = MACAddress(lower) { return .mac(mac) }
        if looksLikeHyphenMAC(lower) || looksLikeCiscoMAC(lower) {
            return .invalid(macProblem(lower))
        }
        let hex = Set("0123456789abcdef")
        if lower.count == 12, lower.allSatisfy(hex.contains), let mac = MACAddress(lower) {
            // Avec au moins un chiffre décimal : une MAC (un nom d'hôte ainsi fait est improbable).
            if lower.contains(where: { $0.isNumber }) { return .mac(mac) }
            if let name = validHostname(trimmed) { return .ambiguous(mac: mac, hostname: name) }
            return .mac(mac)
        }
        if let name = validHostname(trimmed) { return .hostname(name) }
        return .invalid(hostnameProblem(trimmed))
    }

    /// Vrai pour une IP, une MAC ou un nom d'hôte (une fiche peut être ouverte ou saisie).
    public var isUsable: Bool {
        switch self {
        case .ip, .mac, .hostname: return true
        case .empty, .ambiguous, .invalid: return false
        }
    }

    /// Ce que NetScope a reconnu, ou ce qui ne va pas (nil si le champ est vide).
    public var summary: String? {
        switch self {
        case .empty: return nil
        case .ip: return "Adresse IPv4"
        case .mac(let mac): return "Adresse MAC\u{00A0}: \(mac.formatted(.upperColon))"
        case .hostname: return "Nom d’hôte"
        case .ambiguous(let mac, let name):
            return "«\u{00A0}\(name)\u{00A0}» peut être une adresse MAC (\(mac.formatted(.upperColon))) ou un nom d’hôte\u{00A0}: précisez avec des deux-points, ou choisissez."
        case .invalid(let reason): return reason
        }
    }

    // MARK: Adresses IP

    /// Pourquoi « chiffres et points » n'est pas une adresse IPv4.
    static func ipProblem(_ text: String) -> String {
        if !text.contains(".") {
            return "Nombre seul\u{00A0}: tapez une adresse IP complète (ex. 10.182.122.50)"
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        if parts.contains(where: \.isEmpty) {
            if parts.count <= 4, parts.last?.isEmpty == true, !parts.dropLast().contains(where: \.isEmpty) {
                return "Adresse IP incomplète\u{00A0}: \(parts.count - 1) octet\(parts.count - 1 > 1 ? "s" : "") sur 4"
            }
            return "Point en trop dans l’adresse IP"
        }
        if parts.count > 4 { return "Adresse IP trop longue\u{00A0}: \(parts.count) octets au lieu de 4" }
        for part in parts {
            if part.count > 1, part.first == "0" {
                return "«\u{00A0}\(part)\u{00A0}»\u{00A0}: zéro en tête refusé (octal ou décimal\u{00A0}?)"
            }
            if part.count > 3 || (Int(part) ?? 256) > 255 {
                return "«\u{00A0}\(part)\u{00A0}» dépasse 255"
            }
        }
        return "Adresse IP incomplète\u{00A0}: \(parts.count) octet\(parts.count > 1 ? "s" : "") sur 4"
    }

    // MARK: Adresses MAC

    /// Saisie avec deux-points : une MAC (« aa:bb:… », « aabb:ccdd:eeff »), sinon IPv6 ou erreur.
    private static func macWithColons(_ text: String) -> DeviceEntry {
        if let mac = MACAddress(text) { return .mac(mac) }
        if let mac = groupedMAC(text) { return .mac(mac) }
        let groups = text.split(separator: ":", omittingEmptySubsequences: false)
        if text.contains("::") || groups.contains(where: { $0.count > 4 }) || (groups.count > 6 && groups.count <= 8) {
            return .invalid("Adresse IPv6\u{00A0}: NetScope travaille en IPv4 seulement")
        }
        return .invalid(macProblem(text))
    }

    /// Trois groupes de quatre chiffres séparés par « . », « - » ou « : » (Cisco, HP Comware).
    private static func groupedMAC(_ text: String) -> MACAddress? {
        let hex = Set("0123456789abcdef")
        for separator: Character in [".", "-", ":"] where text.contains(separator) {
            let groups = text.split(separator: separator, omittingEmptySubsequences: false)
            guard groups.count == 3, groups.allSatisfy({ $0.count == 4 && $0.allSatisfy(hex.contains) }) else { continue }
            return MACAddress(groups.joined())
        }
        return nil
    }

    /// « aa-bb-cc-dd » : des groupes hexadécimaux de deux chiffres au plus, au moins quatre.
    private static func looksLikeHyphenMAC(_ text: String) -> Bool {
        let hex = Set("0123456789abcdef")
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        return groups.count >= 4 && groups.allSatisfy { $0.count <= 2 && $0.allSatisfy(hex.contains) }
    }

    /// « 94dd.f818.157 » : des groupes hexadécimaux de quatre chiffres environ, séparés par des points.
    private static func looksLikeCiscoMAC(_ text: String) -> Bool {
        let hex = Set("0123456789abcdef")
        let groups = text.split(separator: ".", omittingEmptySubsequences: false)
        return groups.count >= 2 && groups.allSatisfy { (3...4).contains($0.count) && $0.allSatisfy(hex.contains) }
            && groups.contains { $0.contains(where: \.isNumber) }
    }

    /// Pourquoi une saisie qui ressemble à une MAC n'en est pas une.
    static func macProblem(_ text: String) -> String {
        let hex = Set("0123456789abcdef")
        let separators = Set(":-.")
        if let bad = text.first(where: { !hex.contains($0) && !separators.contains($0) }) {
            return "Adresse MAC illisible\u{00A0}: «\u{00A0}\(bad)\u{00A0}» n’est pas un chiffre hexadécimal"
        }
        let digits = text.filter(hex.contains).count
        if digits != 12 {
            return "Adresse MAC \(digits < 12 ? "incomplète" : "trop longue")\u{00A0}: \(digits) chiffres hexadécimaux sur 12"
        }
        return "Adresse MAC illisible\u{00A0}: six octets attendus (ex. 94:DD:F8:18:15:7D)"
    }

    // MARK: Noms d'hôte

    /// Nom d'hôte valide (RFC 1123) sans le point final ; nil sinon.
    public static func validHostname(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.count),
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  label.first != "-", label.last != "-" else { return nil }
        }
        // Dernier niveau tout en chiffres : une adresse mal écrite, pas un nom.
        if labels.count > 1, labels.last!.allSatisfy(\.isNumber) { return nil }
        return name
    }

    /// Pourquoi la saisie n'est pas un nom d'hôte.
    static func hostnameProblem(_ text: String) -> String {
        var name = text
        if name.hasSuffix(".") { name.removeLast() }
        if name.contains(where: \.isWhitespace) {
            return "Ni une adresse, ni un nom d’hôte (pas d’espace dans un nom d’hôte)\u{00A0}: choisissez une suggestion"
        }
        if name.count > 253 { return "Nom d’hôte trop long (253 caractères au plus)" }
        if let bad = name.first(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".")) }) {
            return "Caractère «\u{00A0}\(bad)\u{00A0}» interdit dans un nom d’hôte"
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        if labels.contains(where: \.isEmpty) { return "Point en trop dans le nom d’hôte" }
        if labels.contains(where: { $0.count > 63 }) { return "Partie du nom trop longue (63 caractères au plus)" }
        if labels.contains(where: { $0.first == "-" || $0.last == "-" }) {
            return "Un nom d’hôte ne commence ni ne finit par un tiret"
        }
        return "Ni une adresse IP, ni une MAC, ni un nom d’hôte valide"
    }
}
