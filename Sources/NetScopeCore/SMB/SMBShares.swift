import Foundation

// Note 72 : partages SMB d'un hôte, lus par `smbutil view` (livré avec macOS). Ce fichier ne
// contient que des fonctions pures : modèle, analyse de la sortie de smbutil, classement des
// erreurs, adresses smb:// et UNC. Le lancement de smbutil est dans SMBShareLister.swift.

/// Type d'un partage, tel que smbutil (ou smbclient) l'annonce.
public enum SMBShareKind: String, Codable, Sendable, CaseIterable, Comparable {
    case disk, printer, ipc, device, other

    public var label: String {
        switch self {
        case .disk: return "Disque"
        case .printer: return "Imprimante"
        case .ipc: return "IPC"
        case .device: return "Périphérique"
        case .other: return "Autre"
        }
    }

    /// Mot de la colonne « Type » (anglais de smbutil et de smbclient, ou version française).
    public static func parse(_ token: String) -> SMBShareKind? {
        switch token.lowercased() {
        case "disk", "disque": return .disk
        case "printer", "print", "imprimante": return .printer
        case "pipe", "ipc", "canal", "tube": return .ipc
        case "device", "périphérique", "peripherique": return .device
        case "unknown", "inconnu": return .other
        default: return nil
        }
    }

    public static func < (lhs: SMBShareKind, rhs: SMBShareKind) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Un partage annoncé par l'hôte.
public struct SMBShare: Identifiable, Hashable, Codable, Sendable {
    public var name: String
    public var kind: SMBShareKind
    public var comment: String

    public var id: String { name.lowercased() }

    public init(name: String, kind: SMBShareKind, comment: String = "") {
        self.name = name
        self.kind = kind
        self.comment = comment
    }

    /// Partage caché (nom terminé par « $ » : C$, ADMIN$, IPC$, print$…).
    public var isHidden: Bool { name.hasSuffix("$") }

    /// Partage administratif de Windows (lecteur C$, ADMIN$, IPC$, print$).
    public var isAdministrative: Bool {
        guard isHidden else { return false }
        let upper = name.uppercased()
        if ["ADMIN$", "IPC$", "PRINT$"].contains(upper) { return true }
        // Lecteur : une lettre suivie de « $ ».
        return upper.count == 2 && upper.first.map { $0.isLetter && $0.isASCII } == true
    }

    /// Seuls les disques s'ouvrent dans le Finder (ni IPC$, ni imprimante).
    public var opensInFinder: Bool { kind == .disk }
}

/// Façon dont la liste a été obtenue.
public enum SMBAccess: Hashable, Codable, Sendable {
    case guest
    case anonymous
    case user(String)

    public var label: String {
        switch self {
        case .guest: return "Invité"
        case .anonymous: return "Anonyme"
        case .user(let name): return name
        }
    }
}

/// Résultat d'une lecture des partages.
public struct SMBShareListing: Hashable, Codable, Sendable {
    public var host: String
    public var shares: [SMBShare]
    /// Nombre annoncé par smbutil (« 6 shares listed »), s'il est lu.
    public var reportedCount: Int?
    public var access: SMBAccess
    public var date: Date

    public init(host: String, shares: [SMBShare], reportedCount: Int? = nil, access: SMBAccess, date: Date = Date()) {
        self.host = host
        self.shares = shares
        self.reportedCount = reportedCount
        self.access = access
        self.date = date
    }

    /// Partages visibles selon le choix « Afficher les partages cachés ».
    public func visible(showHidden: Bool) -> [SMBShare] {
        showHidden ? shares : shares.filter { !$0.isHidden }
    }

    public var hiddenCount: Int { shares.filter(\.isHidden).count }

    /// « 4 partages (2 cachés) ».
    public var summary: String {
        let count = shares.count
        var text = count == 0 ? "Aucun partage" : count == 1 ? "1 partage" : "\(count) partages"
        let hidden = hiddenCount
        if hidden > 0 { text += hidden == 1 ? " (1 caché)" : " (\(hidden) cachés)" }
        return text
    }
}

/// Sortie de smbutil découpée.
public struct SMBParsedOutput: Hashable, Sendable {
    public var shares: [SMBShare]
    public var reportedCount: Int?
}

// MARK: - Analyse de la sortie

public enum SMBShareParser {
    private static let headerNames: Set<String> = ["share", "sharename", "partage", "nom", "name"]

    /// Découpe la sortie de `smbutil view` (ou `smbclient -L`). Renvoie nil si aucun tableau de
    /// partages n'est reconnu (message d'erreur, sortie vide).
    public static func parse(_ output: String) -> SMBParsedOutput? {
        let lines = normalized(output).components(separatedBy: "\n")
        guard let headerIndex = lines.firstIndex(where: isHeader) else { return nil }
        let header = lines[headerIndex]
        let typeColumn = column(of: ["type"], in: header)
        let commentColumn = column(of: ["comments", "comment", "commentaires", "commentaire", "remarque"], in: header)

        var shares: [SMBShare] = []
        var reported: Int?
        var seen = Set<String>()
        for line in lines[(headerIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "-" || $0 == " " }) { continue }
            if let count = footerCount(trimmed) {
                reported = count
                break
            }
            // smbclient : fin du tableau des partages (serveurs, groupes de travail, erreurs).
            if (trimmed.hasPrefix("Server ") && trimmed.contains("Comment"))
                || (trimmed.hasPrefix("Workgroup ") && trimmed.contains("Master"))
                || trimmed.hasPrefix("Reconnecting with SMB1") || trimmed.hasPrefix("SMB1 disabled") { break }
            guard let share = parseRow(line, typeColumn: typeColumn, commentColumn: commentColumn) else { continue }
            guard seen.insert(share.id).inserted else { continue }
            shares.append(share)
        }
        return SMBParsedOutput(shares: shares, reportedCount: reported)
    }

    /// Retours chariot du pseudo-terminal, tabulations et séquences d'échappement retirés.
    static func normalized(_ output: String) -> String {
        var text = output.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Séquences CSI (ESC [ … lettre) que certains terminaux ajoutent.
        while let range = text.range(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.replacingOccurrences(of: "\t", with: "    ")
    }

    private static func isHeader(_ line: String) -> Bool {
        let words = line.split(separator: " ").map { $0.lowercased() }
        guard words.count >= 2, let first = words.first, headerNames.contains(first) else { return false }
        return words.contains("type")
    }

    /// Colonne (en caractères) du premier mot trouvé dans l'en-tête.
    private static func column(of names: [String], in header: String) -> Int? {
        let chars = Array(header.lowercased())
        for name in names {
            let target = Array(name)
            guard chars.count >= target.count else { continue }
            for start in 0...(chars.count - target.count) where Array(chars[start..<(start + target.count)]) == target {
                let before = start == 0 || chars[start - 1] == " "
                let afterIndex = start + target.count
                let after = afterIndex == chars.count || chars[afterIndex] == " "
                if before && after { return start }
            }
        }
        return nil
    }

    /// « 6 shares listed », « 1 share listed », « 6 partages listés ».
    private static func footerCount(_ line: String) -> Int? {
        let words = line.lowercased().split(separator: " ")
        guard words.count >= 3, let count = Int(words[0]) else { return nil }
        let noun = words[1]
        guard ["share", "shares", "partage", "partages"].contains(String(noun)) else { return nil }
        return count
    }

    /// Une ligne du tableau : d'abord par les colonnes de l'en-tête (un nom de partage peut
    /// contenir des espaces, « Time Machine »), sinon par le premier mot de type entouré d'espaces.
    static func parseRow(_ line: String, typeColumn: Int?, commentColumn: Int?) -> SMBShare? {
        let chars = Array(line)
        if let typeColumn, typeColumn > 0, chars.count > typeColumn {
            let name = String(chars[0..<typeColumn]).trimmingCharacters(in: .whitespaces)
            let rest = String(chars[typeColumn...])
            if !name.isEmpty, chars[typeColumn - 1] == " ",
               let (kind, comment) = splitTypeAndComment(rest) {
                return SMBShare(name: name, kind: kind, comment: comment)
            }
        }
        // Nom plus long que sa colonne, ou colonnes inconnues : premier mot de type précédé
        // d'au moins un espace et suivi d'un espace ou de la fin de ligne, après la colonne Type.
        let pattern = "\\s(Disk|Disque|Printer|Print|Imprimante|Pipe|IPC|Canal|Tube|Device|Périphérique|Peripherique|Unknown|Inconnu)(\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        let minimum = typeColumn ?? 0
        // Après la colonne Type si possible ; « 2+ espaces avant » préféré (nom « USB Disk 1 »).
        let candidates = matches.filter { ns.substring(to: $0.range(at: 1).location).count >= minimum }
        let pool = candidates.isEmpty ? matches : candidates
        let preferred = pool.first { match in
            let location = match.range(at: 1).location
            return location >= 2 && ns.substring(with: NSRange(location: location - 2, length: 2)) == "  "
        } ?? pool.first
        guard let match = preferred else { return nil }
        let typeRange = match.range(at: 1)
        let name = ns.substring(to: typeRange.location).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let kind = SMBShareKind.parse(ns.substring(with: typeRange)) else { return nil }
        let comment = ns.substring(from: typeRange.location + typeRange.length).trimmingCharacters(in: .whitespaces)
        return SMBShare(name: name, kind: kind, comment: comment)
    }

    private static func splitTypeAndComment(_ rest: String) -> (SMBShareKind, String)? {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        let token = trimmed.prefix { !$0.isWhitespace }
        guard let kind = SMBShareKind.parse(String(token)) else { return nil }
        let comment = trimmed.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
        return (kind, comment)
    }

    // MARK: Erreurs

    /// Classe l'échec d'après la sortie de smbutil (messages tirés de errno, en anglais).
    public static func failure(from output: String, guest: Bool) -> SMBShareError {
        let text = normalized(output)
        let lower = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }
        if has("smb1", "smbv1", "nt lm 0.12", "protocol not supported", "protocol family not supported",
               "protocole non pris en charge", "negotiate failed: not supported") {
            return .smb1Only
        }
        if has("authentication error", "permission denied", "access denied", "logon failure", "nt_status_logon_failure",
               "nt_status_access_denied", "account is disabled", "accès refusé", "acces refuse", "erreur d’authentification",
               "erreur d'authentification", "authentication failed", "rejected the authentication") {
            return .accessDenied(guest: guest)
        }
        if has("operation timed out", "timed out", "délai", "delai") { return .timeout }
        if has("connection refused", "connexion refusée") { return .refused }
        if has("no route to host", "host is down", "network is unreachable", "network is down", "aucune route",
               "hôte est hors service", "réseau est inaccessible") {
            return .unreachable
        }
        if has("unknown host", "nodename nor servname", "could not resolve", "no such host", "hôte inconnu",
               "can't get server address", "netbios name not found") {
            return .hostNotFound
        }
        if has("broken pipe", "connection reset", "socket is not connected", "connexion réinitialisée") {
            return .connectionReset
        }
        let last = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.lowercased().contains("password") }
        return .other(cleanMessage(last ?? ""))
    }

    /// « smbutil: server connection failed: X » → « X ».
    static func cleanMessage(_ line: String) -> String {
        var text = line
        for prefix in ["smbutil: ", "smbutil:"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        return String(text.prefix(300))
    }
}

/// Échec de la lecture des partages, avec un message clair pour l'utilisateur.
public enum SMBShareError: Error, Hashable, Sendable, LocalizedError {
    case accessDenied(guest: Bool)
    case smb1Only
    case refused
    case unreachable
    case hostNotFound
    case connectionReset
    case timeout
    case invalidHost
    case invalidUser
    case unavailable(String)
    case other(String)

    /// Titre court (bandeau).
    public var title: String {
        switch self {
        case .accessDenied(let guest): return guest ? "Accès invité refusé" : "Accès refusé"
        case .smb1Only: return "SMB1 seulement"
        case .refused: return "Service SMB fermé"
        case .unreachable: return "Hôte injoignable"
        case .hostNotFound: return "Hôte introuvable"
        case .connectionReset: return "Connexion coupée"
        case .timeout: return "Délai dépassé"
        case .invalidHost: return "Adresse invalide"
        case .invalidUser: return "Utilisateur invalide"
        case .unavailable: return "smbutil indisponible"
        case .other: return "Lecture impossible"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let guest):
            return guest
                ? "L’hôte refuse les accès invité et anonyme. Saisissez un utilisateur et son mot de passe (pour un domaine\u{00A0}: DOMAINE\\utilisateur)."
                : "Utilisateur ou mot de passe refusé par l’hôte, ou compte sans droit de lister les partages."
        case .smb1Only:
            return "L’hôte ne parle que SMB1, désactivé dans macOS pour raison de sécurité. Activer SMB2 ou SMB3 sur l’appareil (vieux NAS, imprimante, Windows XP)."
        case .refused:
            return "Le port 445 refuse la connexion\u{00A0}: le partage de fichiers est désactivé sur l’hôte, ou un pare-feu le bloque."
        case .unreachable:
            return "Aucune route vers l’hôte\u{00A0}: il est éteint, sur un autre réseau, ou un pare-feu bloque le trafic."
        case .hostNotFound:
            return "Le nom de l’hôte ne se résout pas. Essayer avec son adresse IP."
        case .connectionReset:
            return "L’hôte a coupé la connexion SMB (signature exigée, version refusée ou service saturé). Réessayer, ou avec un utilisateur."
        case .timeout:
            return "Pas de réponse SMB dans le délai\u{00A0}: le port 445 est filtré par un pare-feu, ou l’hôte est éteint."
        case .invalidHost:
            return "Adresse ou nom d’hôte invalide (lettres, chiffres, «\u{00A0}.\u{00A0}» et «\u{00A0}-\u{00A0}» seulement)."
        case .invalidUser:
            return "Nom d’utilisateur invalide (pas de «\u{00A0}/\u{00A0}», de «\u{00A0}:\u{00A0}» ni de caractère de contrôle)."
        case .unavailable(let detail):
            return "smbutil n’a pas pu être lancé (\(detail))."
        case .other(let detail):
            return detail.isEmpty ? "smbutil n’a renvoyé aucun partage." : "smbutil\u{00A0}: \(detail)"
        }
    }

    /// Vrai si saisir un utilisateur peut résoudre l'échec.
    public var suggestsCredentials: Bool {
        switch self {
        case .accessDenied, .connectionReset: return true
        default: return false
        }
    }
}

// MARK: - Adresses

/// Identifiants saisis (le mot de passe n'est jamais rangé ici : il passe par le pseudo-terminal).
public struct SMBLogin: Hashable, Sendable {
    public var user: String
    public var domain: String

    public init(user: String, domain: String = "") {
        self.user = user
        self.domain = domain
    }

    /// « DOMAINE\utilisateur », « utilisateur@domaine.local » ou « utilisateur ».
    public init(field: String) {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        if let slash = trimmed.firstIndex(of: "\\") {
            self.init(user: String(trimmed[trimmed.index(after: slash)...]), domain: String(trimmed[..<slash]))
        } else {
            self.init(user: trimmed)
        }
    }

    /// Forme affichée et retenue (« BUREAU\marc »).
    public var display: String { domain.isEmpty ? user : "\(domain)\\\(user)" }
}

public enum SMBPaths {
    /// Adresse IPv4, nom d'hôte ou nom NetBIOS (aucun « / », « @ », « ; », « : » ni espace).
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"), !host.hasPrefix(".") else { return false }
        return host.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "." || scalar == "-" || scalar == "_"
        }
    }

    /// Caractères d'un utilisateur ou d'un domaine laissés tels quels dans l'URL de smbutil.
    private static let userAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Cible de `smbutil view` : « //hôte », ou « //DOMAINE;utilisateur@hôte » (sans mot de passe :
    /// smbutil le demande sur le pseudo-terminal). Utilisateur et domaine encodés en %XX.
    public static func viewTarget(host: String, login: SMBLogin?) throws -> String {
        guard isValidHost(host) else { throw SMBShareError.invalidHost }
        guard let login else { return "//\(host)" }
        let user = login.user.trimmingCharacters(in: .whitespaces)
        let domain = login.domain.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, user.count <= 256, domain.count <= 256,
              !(user + domain).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !(user + domain).contains("/"), !(user + domain).contains(":") else { throw SMBShareError.invalidUser }
        guard let encodedUser = user.addingPercentEncoding(withAllowedCharacters: userAllowed),
              let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: userAllowed) else {
            throw SMBShareError.invalidUser
        }
        return "//" + (domain.isEmpty ? "" : encodedDomain + ";") + encodedUser + "@" + host
    }

    /// Arguments de `smbutil` pour un essai.
    public static func arguments(host: String, mode: SMBAttempt) throws -> [String] {
        switch mode {
        case .guest: return ["view", "-g", try viewTarget(host: host, login: nil)]
        case .anonymous: return ["view", "-a", try viewTarget(host: host, login: nil)]
        case .user(let login): return ["view", try viewTarget(host: host, login: login)]
        }
    }

    /// « smb://10.0.0.5/Partage%20commun » (ouvert par le Finder, qui gère l'authentification).
    public static func url(host: String, share: String) -> URL? {
        guard isValidHost(host), !share.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        guard let encoded = share.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "smb://\(host)/\(encoded)")
    }

    /// « smb://10.0.0.5/Partage commun » (lisible, à coller dans « Se connecter au serveur »).
    public static func readable(host: String, share: String) -> String { "smb://\(host)/\(share)" }

    /// « \\10.0.0.5\Partage commun » (Windows).
    public static func unc(host: String, share: String) -> String { "\\\\\(host)\\\(share)" }
}

/// Un essai de lecture : invité, anonyme ou avec un utilisateur.
public enum SMBAttempt: Hashable, Sendable {
    case guest
    case anonymous
    case user(SMBLogin)

    public var access: SMBAccess {
        switch self {
        case .guest: return .guest
        case .anonymous: return .anonymous
        case .user(let login): return .user(login.display)
        }
    }
}

/// Appareil pour lequel la section « Partages SMB » de la fiche est utile : port 445 ou 139
/// ouvert, ou fabricant de NAS.
public enum SMBRelevance {
    public static let nasVendors = ["synology", "qnap", "asustor", "western digital", "buffalo", "netgear readynas",
                                    "terramaster", "drobo", "seagate", "truenas", "ixsystems"]

    public static func isRelevant(openPorts: [UInt16], vendor: String?) -> Bool {
        if openPorts.contains(445) || openPorts.contains(139) { return true }
        let lower = vendor?.lowercased() ?? ""
        return nasVendors.contains { lower.contains($0) }
    }
}
