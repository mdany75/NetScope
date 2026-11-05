import Foundation

// Emplacements ajoutés à la main dans « Vitesse des disques » (note 55) : un NAS ou un partage SMB,
// NFS, AFP ou WebDAV (monté par l'app au lancement du test s'il ne l'est pas déjà), ou un dossier
// quelconque choisi dans le Finder. FTP, FTPS et SFTP sont prévus et passeront par la connexion
// FTP de la note 50. Tout ce qui est ici est pur : analyse des adresses, construction de l'URL de
// montage (jamais de mot de passe dedans), reconnaissance d'un partage déjà monté, fusion avec les
// volumes trouvés et choix du type d'après les ports ouverts d'un appareil. Le montage lui-même
// (NetFS) est fait par l'app ; le mot de passe est au Trousseau.

/// Type d'un emplacement ajouté ; l'ordre des cas est celui des choix de la feuille.
public enum DiskShareKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case smb, nfs, afp, webdav, ftp, ftps, sftp, dossier

    public var id: String { rawValue }

    /// Libellé court (choix de la feuille, puce de la carte).
    public var label: String {
        switch self {
        case .smb: return "SMB"
        case .nfs: return "NFS"
        case .afp: return "AFP"
        case .webdav: return "WebDAV"
        case .ftp: return "FTP"
        case .ftps: return "FTPS"
        case .sftp: return "SFTP"
        case .dossier: return "Autre"
        }
    }

    /// Libellé long (aide, titre).
    public var title: String {
        switch self {
        case .smb: return "NAS ou partage SMB"
        case .nfs: return "Partage NFS"
        case .afp: return "Partage AFP"
        case .webdav: return "WebDAV"
        case .ftp: return "Serveur FTP"
        case .ftps: return "Serveur FTPS"
        case .sftp: return "Serveur SFTP"
        case .dossier: return "Autre dossier (Finder)"
        }
    }

    /// Symbole SF de la carte.
    public var symbol: String {
        switch self {
        case .smb, .afp, .nfs: return "server.rack"
        case .webdav: return "globe"
        case .ftp, .ftps, .sftp: return "arrow.up.arrow.down.circle"
        case .dossier: return "folder"
        }
    }

    /// Partage monté par NetFS (SMB, NFS, AFP, WebDAV).
    public var isMountable: Bool { networkProtocol != nil }

    /// Faux pour FTP, FTPS et SFTP : le test de vitesse ne s'applique pas à ces protocoles (ils
    /// s'ouvrent dans Accès distant › Transférer des fichiers).
    public var isAvailable: Bool {
        switch self {
        case .ftp, .ftps, .sftp: return false
        default: return true
        }
    }

    /// Pourquoi le choix est grisé.
    public static let ftpPending = "FTP, FTPS et SFTP\u{00A0}: utilisez Accès distant › Transférer des fichiers (le test de vitesse ne s’applique pas à ces protocoles)."

    public var networkProtocol: DiskNetworkProtocol? {
        switch self {
        case .smb: return .smb
        case .nfs: return .nfs
        case .afp: return .afp
        case .webdav: return .webdav
        default: return nil
        }
    }

    /// Le serveur demande un compte (NFS s'appuie sur l'adresse du Mac et l'identifiant Unix).
    public var usesCredentials: Bool {
        switch self {
        case .smb, .afp, .webdav, .ftp, .ftps, .sftp: return true
        case .nfs, .dossier: return false
        }
    }

    /// Ports TCP qui répondent pour ce service (le premier est le principal).
    public func ports(secure: Bool = true) -> [UInt16] {
        switch self {
        case .smb: return [445]
        case .nfs: return [2049]
        case .afp: return [548]
        case .webdav: return secure ? [443] : [80]
        case .ftp: return [21]
        case .ftps: return [990, 21]
        case .sftp: return [22]
        case .dossier: return []
        }
    }

    /// Schémas d'adresse reconnus à la saisie.
    var schemes: [String] {
        switch self {
        case .smb: return ["smb", "cifs"]
        case .nfs: return ["nfs"]
        case .afp: return ["afp"]
        case .webdav: return ["https", "http", "webdav", "webdavs", "dav", "davs"]
        case .ftp: return ["ftp"]
        case .ftps: return ["ftps"]
        case .sftp: return ["sftp"]
        case .dossier: return ["file"]
        }
    }

    /// Exemple du champ « Partage » de la feuille.
    public var sharePlaceholder: String {
        switch self {
        case .smb, .afp: return "Projets"
        case .nfs: return "/volume1/projets"
        case .webdav: return "/remote.php/dav/files/technicien"
        case .ftp, .ftps, .sftp: return "/partage"
        case .dossier: return "/Volumes/Archives/Essais"
        }
    }

    /// Libellé du champ « Partage ».
    public var shareLabel: String {
        switch self {
        case .smb, .afp: return "Partage"
        case .nfs: return "Chemin d’export"
        case .webdav, .ftp, .ftps, .sftp: return "Chemin"
        case .dossier: return "Dossier"
        }
    }

    /// Type le plus probable d'après les ports ouverts d'un appareil (SMB, puis NFS, AFP, WebDAV).
    public static func suggested(openPorts: [UInt16]) -> (kind: DiskShareKind, secure: Bool)? {
        let open = Set(openPorts)
        if open.contains(445) || open.contains(139) { return (.smb, true) }
        if open.contains(2049) { return (.nfs, true) }
        if open.contains(548) { return (.afp, true) }
        if open.contains(443) || open.contains(5006) { return (.webdav, true) }
        if open.contains(80) || open.contains(5005) { return (.webdav, false) }
        return nil
    }
}

/// Un emplacement enregistré, par site.
public struct DiskShareLocation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Site auquel il appartient (`SiteFiles.key`).
    public var siteKey: String
    /// Nom choisi ; vide : nom tiré du partage.
    public var name: String
    public var kind: DiskShareKind
    /// Nom ou adresse IP du serveur.
    public var server: String
    /// Partage SMB ou AFP, chemin d'export NFS, chemin WebDAV ; dossier choisi pour « Autre ».
    public var share: String
    /// Compte (« technicien », « BUREAU;technicien ») ; vide : invité, ou NFS.
    public var user: String
    /// Port différent du port habituel (WebDAV surtout).
    public var port: Int?
    /// WebDAV en HTTPS (sinon HTTP).
    public var secure: Bool
    /// Appareil choisi dans le Scanner ou l'Inventaire : nom affiché, IP et nom d'hôte (pour
    /// reconnaître le partage monté sous l'un ou l'autre).
    public var deviceName: String?
    public var deviceIP: String?
    public var deviceHost: String?
    /// Un mot de passe est rangé au Trousseau pour cet emplacement.
    public var hasPassword: Bool
    public var created: Date

    public init(id: UUID = UUID(), siteKey: String, name: String = "", kind: DiskShareKind, server: String = "",
                share: String = "", user: String = "", port: Int? = nil, secure: Bool = true, deviceName: String? = nil,
                deviceIP: String? = nil, deviceHost: String? = nil, hasPassword: Bool = false, created: Date = Date()) {
        self.id = id
        self.siteKey = siteKey
        self.name = name
        self.kind = kind
        self.server = server
        self.share = share
        self.user = user
        self.port = port
        self.secure = secure
        self.deviceName = deviceName
        self.deviceIP = deviceIP
        self.deviceHost = deviceHost
        self.hasPassword = hasPassword
        self.created = created
    }

    /// Service du Trousseau des mots de passe des partages (compte : l'UUID de l'emplacement).
    public static let keychainService = "com.danymenard.netscope.partages"
    public var keychainAccount: String { id.uuidString }

    /// Clé de l'historique (`DiskLocation.id`).
    public var locationID: String { "emplacement:" + id.uuidString }

    public var trimmedServer: String { server.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedShare: String { share.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nom affiché : celui choisi, sinon le dernier élément du partage, sinon le serveur.
    public var displayName: String {
        let chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosen.isEmpty { return chosen }
        let last = trimmedShare.split(separator: "/").last.map(String.init) ?? ""
        if !last.isEmpty { return last }
        return trimmedServer.isEmpty ? kind.title : trimmedServer
    }

    /// Adresse de montage, sans mot de passe : « smb://technicien@nas.local/Projets ». Nil pour un
    /// dossier, ou si le serveur manque.
    public var mountURL: URL? {
        DiskShareAddress(kind: kind, server: trimmedServer, share: trimmedShare, user: trimmedUser, port: port,
                         secure: secure).url
    }

    /// Adresse affichée (sans le compte) : « smb://nas.local/Projets », ou le dossier.
    public var address: String {
        if kind == .dossier { return trimmedShare }
        return DiskShareAddress(kind: kind, server: trimmedServer, share: trimmedShare, user: "", port: port,
                                secure: secure).url?.absoluteString.removingPercentEncoding ?? trimmedServer
    }

    /// Ce qui manque ou ne va pas dans la saisie (vide : on peut enregistrer).
    public var problems: [String] {
        var list: [String] = []
        if kind == .dossier {
            if !trimmedShare.hasPrefix("/") { list.append("Choisissez un dossier.") }
            return list
        }
        if trimmedServer.isEmpty {
            list.append("Indiquez le serveur (nom ou adresse IP).")
        } else if !DiskShareAddress.isValidHost(trimmedServer) {
            list.append("Le nom du serveur contient des caractères non permis.")
        }
        if (kind == .smb || kind == .afp) && trimmedShare.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            list.append("Indiquez le nom du partage.")
        }
        if kind == .nfs && trimmedShare.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            list.append("Indiquez le chemin d’export NFS (ex. /volume1/projets).")
        }
        if let port, !(1...65_535).contains(port) { list.append("Le port doit être compris entre 1 et 65\u{00A0}535.") }
        return list
    }

    /// Hôtes sous lesquels le partage peut être monté (saisi, IP et nom de l'appareil choisi).
    public var hostAliases: Set<String> {
        var set: Set<String> = []
        for host in [trimmedServer, deviceIP ?? "", deviceHost ?? ""] {
            let normalized = DiskShareCatalog.normalizedHost(host)
            if !normalized.isEmpty { set.insert(normalized) }
        }
        return set
    }
}

/// Adresse d'un partage, lue d'un texte collé (« smb://nas/Projets », « \\nas\Projets »,
/// « nas:/volume1/projets ») ou construite depuis les champs de la feuille.
public struct DiskShareAddress: Equatable, Sendable {
    public var kind: DiskShareKind
    public var server: String
    public var share: String
    public var user: String
    public var port: Int?
    public var secure: Bool

    public init(kind: DiskShareKind, server: String, share: String, user: String = "", port: Int? = nil, secure: Bool = true) {
        self.kind = kind
        self.server = server
        self.share = share
        self.user = user
        self.port = port
        self.secure = secure
    }

    /// Nom d'hôte ou adresse IP plausible (lettres, chiffres, « . », « - », « _ », « : » d'IPv6).
    public static func isValidHost(_ host: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%"))
        return !host.isEmpty && host.unicodeScalars.allSatisfy { allowed.contains($0) } && !host.hasPrefix("-")
    }

    /// Lit une adresse collée ; nil si le texte n'en est pas une.
    public static func parse(_ raw: String) -> DiskShareAddress? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Dossier local (« /Volumes/Archives », « ~/Essais »).
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return DiskShareAddress(kind: .dossier, server: "", share: (text as NSString).expandingTildeInPath)
        }
        // Chemin UNC de Windows : \\serveur\partage\dossier.
        if text.hasPrefix("\\\\") {
            text = "smb://" + text.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        }
        if let range = text.range(of: "://") {
            let scheme = text[..<range.lowerBound].lowercased()
            guard let kind = DiskShareKind.allCases.first(where: { $0.schemes.contains(scheme) }) else { return nil }
            if kind == .dossier {
                guard let url = URL(string: text), url.isFileURL else { return nil }
                return DiskShareAddress(kind: .dossier, server: "", share: url.path)
            }
            // Espaces et accents encodés d'abord, « % » déjà présents gardés : sinon URLComponents
            // encode tout le texte une seconde fois (« %20 » devient « %2520 »).
            let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "%#[]@:;/"))
            let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
            guard let components = URLComponents(string: encoded), let host = components.host, !host.isEmpty else { return nil }
            var user = components.user?.removingPercentEncoding ?? ""
            // smb://BUREAU;technicien@nas : le domaine fait partie du compte.
            if user.isEmpty, let percentUser = components.percentEncodedUser { user = percentUser.removingPercentEncoding ?? percentUser }
            var path = components.percentEncodedPath.removingPercentEncoding ?? components.path
            switch kind {
            case .smb, .afp:
                while path.hasPrefix("/") { path.removeFirst() }
                while path.hasSuffix("/") { path.removeLast() }
            default:
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if path == "/" { path = "" }
            }
            let secure = kind == .webdav ? ["https", "webdavs", "davs"].contains(scheme) : true
            var port = components.port
            if let value = port, kind.ports(secure: secure).first.map(Int.init) == value { port = nil }
            let server = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
            return DiskShareAddress(kind: kind, server: server, share: path, user: user, port: port, secure: secure)
        }
        // NFS à la manière de mount : « serveur:/chemin ».
        if let colon = text.firstIndex(of: ":"), text[text.index(after: colon)...].hasPrefix("/") {
            let server = String(text[..<colon])
            guard isValidHost(server) else { return nil }
            return DiskShareAddress(kind: .nfs, server: server, share: String(text[text.index(after: colon)...]))
        }
        // « serveur/partage » ou « serveur » seul : SMB, le plus courant.
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let server = parts.first, isValidHost(server) else { return nil }
        let share = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
        return DiskShareAddress(kind: .smb, server: server, share: share)
    }

    /// URL de montage (sans mot de passe) ; nil pour un dossier ou sans serveur.
    public var url: URL? {
        guard kind != .dossier, !server.isEmpty, DiskShareAddress.isValidHost(server) else { return nil }
        let scheme: String
        switch kind {
        case .webdav: scheme = secure ? "https" : "http"
        default: scheme = kind.rawValue
        }
        var text = scheme + "://"
        if !user.isEmpty {
            // « ; » (domaine SMB) reste lisible ; « @ », « : » et « / » sont encodés.
            var allowed = CharacterSet.urlUserAllowed
            allowed.remove(charactersIn: "@:/")
            text += (user.addingPercentEncoding(withAllowedCharacters: allowed) ?? user) + "@"
        }
        text += server.contains(":") ? "[\(server)]" : server
        if let port { text += ":\(port)" }
        let trimmed = share.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !trimmed.isEmpty {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: ";?#")
            text += "/" + (trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed)
        }
        return URL(string: text)
    }
}

/// Partages enregistrés ↔ volumes montés, et appareils proposés pour le champ « Serveur ».
public enum DiskShareCatalog {
    /// Hôte comparable : minuscules, sans point final, sans crochets ni « .local ».
    public static func normalizedHost(_ host: String) -> String {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        while text.hasSuffix(".") { text.removeLast() }
        if text.hasSuffix(".local") { text.removeLast(6) }
        return text
    }

    /// Partage comparable : minuscules, sans barres obliques autour.
    public static func normalizedShare(_ share: String) -> String {
        share.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
    }

    /// Vrai si le volume monté `location` est ce partage enregistré (même protocole, même serveur
    /// sous l'un de ses noms, même partage).
    public static func matches(_ saved: DiskShareLocation, mounted location: DiskLocation) -> Bool {
        guard let proto = saved.kind.networkProtocol, location.kind == .reseau, location.networkProtocol == proto,
              let server = location.server else { return false }
        guard saved.hostAliases.contains(normalizedHost(server)) else { return false }
        let wanted = normalizedShare(saved.share)
        let found = normalizedShare(location.share ?? "")
        // Sous-dossier d'un partage (smb://nas/Projets/Essais monté comme « Projets ») : accepté.
        return wanted == found || (!found.isEmpty && wanted.hasPrefix(found + "/"))
    }

    /// Volume qui contient `path` (le plus long point de montage préfixe), parmi les emplacements
    /// trouvés (disques et partages, pas les dossiers nuage).
    public static func containingVolume(of path: String, in locations: [DiskLocation]) -> DiskLocation? {
        let standardized = (path as NSString).standardizingPath
        return locations
            .filter { $0.kind != .nuage && $0.isMounted && $0.savedID == nil }
            .filter { volume in
                volume.path == "/" || standardized == volume.path || standardized.hasPrefix(volume.path + "/")
            }
            .max { $0.path.count < $1.path.count }
    }

    /// Liste affichée : les volumes trouvés et les emplacements enregistrés du site. Un partage
    /// enregistré déjà monté remplace la carte du volume (même chemin, son nom à lui, sa clé
    /// d'historique) ; sinon il apparaît « non monté » avec son adresse.
    public static func merge(discovered: [DiskLocation], saved: [DiskShareLocation], siteKey: String,
                             folderExists: (String) -> Bool) -> [DiskLocation] {
        var remaining = discovered
        var result: [DiskLocation] = []
        for share in saved where share.siteKey == siteKey {
            if share.kind == .dossier {
                let path = (share.trimmedShare as NSString).standardizingPath
                let exists = folderExists(path)
                let volume = containingVolume(of: path, in: discovered)
                var kind = volume?.kind ?? .externe
                if kind == .nuage { kind = .externe }
                result.append(DiskLocation(name: share.displayName, path: path, testParent: path, kind: kind,
                                           fileSystem: volume?.fileSystem ?? "Dossier", totalBytes: volume?.totalBytes,
                                           freeBytes: volume?.freeBytes, server: volume?.server, share: volume?.share,
                                           networkProtocol: volume?.networkProtocol, isReadOnly: volume?.isReadOnly ?? false,
                                           savedID: share.locationID, isMounted: exists))
                continue
            }
            if let index = remaining.firstIndex(where: { matches(share, mounted: $0) }) {
                var mounted = remaining.remove(at: index)
                mounted.name = share.displayName
                mounted.savedID = share.locationID
                result.append(mounted)
            } else {
                result.append(DiskLocation(name: share.displayName, path: share.address, testParent: "", kind: .reseau,
                                           fileSystem: share.kind.label, server: share.trimmedServer,
                                           share: share.trimmedShare.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                           networkProtocol: share.kind.networkProtocol, savedID: share.locationID,
                                           isMounted: false))
            }
        }
        return DiskLocationCatalog.sorted(remaining + result)
    }

    /// Emplacement enregistré d'une carte, s'il y en a un.
    public static func saved(for location: DiskLocation, in saved: [DiskShareLocation]) -> DiskShareLocation? {
        guard let id = location.savedID else { return nil }
        return saved.first { $0.locationID == id }
    }

    /// Emplacements d'un site, par nom.
    public static func forSite(_ saved: [DiskShareLocation], siteKey: String) -> [DiskShareLocation] {
        saved.filter { $0.siteKey == siteKey }
            .sorted { ($0.displayName.localizedLowercase, $0.created) < ($1.displayName.localizedLowercase, $1.created) }
    }
}

/// Appareil proposé pour le champ « Serveur » (Scanner et Inventaire du site).
public struct DiskShareCandidate: Hashable, Sendable, Identifiable {
    public var id: String { ip }
    public var name: String
    public var ip: String
    public var host: String?
    public var openPorts: [UInt16]
    public var type: DeviceType
    public var isOnline: Bool

    public init(name: String, ip: String, host: String? = nil, openPorts: [UInt16] = [], type: DeviceType = .inconnu,
                isOnline: Bool = true) {
        self.name = name
        self.ip = ip
        self.host = host
        self.openPorts = openPorts
        self.type = type
        self.isOnline = isOnline
    }

    /// Ports de partage ouverts (« SMB · NFS »).
    public var shareServices: [String] {
        let open = Set(openPorts)
        var list: [String] = []
        if open.contains(445) || open.contains(139) { list.append("SMB") }
        if open.contains(2049) { list.append("NFS") }
        if open.contains(548) { list.append("AFP") }
        if open.contains(443) || open.contains(80) || open.contains(5005) || open.contains(5006) { list.append("Web") }
        return list
    }

    var hasFileSharing: Bool { !Set(openPorts).isDisjoint(with: [445, 139, 2049, 548]) }

    /// Appareils du Scanner puis de l'Inventaire (une fois chacun, par IP), les serveurs de
    /// fichiers d'abord : ports de partage ouverts, puis serveurs, puis en ligne ; enfin par IP.
    public static func list(devices: [Device], records: [InvRecord], excluding localIP: String? = nil) -> [DiskShareCandidate] {
        var byIP: [String: DiskShareCandidate] = [:]
        for record in records {
            let ip = record.ip.description
            byIP[ip] = DiskShareCandidate(name: record.displayName, ip: ip, host: record.hostname, openPorts: record.openPorts,
                                          type: record.type, isOnline: record.isOnline)
        }
        for device in devices {
            let ip = device.ip.description
            var candidate = DiskShareCandidate(name: device.displayName, ip: ip, host: device.hostname,
                                               openPorts: device.openPorts, type: device.deviceType, isOnline: device.isOnline)
            if let known = byIP[ip] {
                candidate.openPorts = Array(Set(candidate.openPorts).union(known.openPorts)).sorted()
                if candidate.host == nil { candidate.host = known.host }
            }
            byIP[ip] = candidate
        }
        if let localIP { byIP[localIP] = nil }
        return byIP.values.sorted { lhs, rhs in
            func rank(_ c: DiskShareCandidate) -> Int {
                (c.hasFileSharing ? 0 : 4) + (c.type == .serveur ? 0 : 2) + (c.isOnline ? 0 : 1)
            }
            let l = rank(lhs), r = rank(rhs)
            if l != r { return l < r }
            let li = IPv4Address(lhs.ip), ri = IPv4Address(rhs.ip)
            if let li, let ri { return li < ri }
            return lhs.ip < rhs.ip
        }
    }
}
