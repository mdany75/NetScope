import Darwin
import Foundation

// Emplacements qu'on peut mesurer (note 22) : disque interne, disques externes, partages réseau
// montés (SMB, NFS, AFP, WebDAV) et dossiers nuage (File Provider : OneDrive, Google Drive,
// Dropbox, Box… ; iCloud Drive). Le classement se fait sur des faits simples (`DiskVolumeFacts`),
// pour pouvoir le vérifier sans aucun vrai volume.

/// Nature d'un emplacement ; l'ordre des cas est celui de la liste.
public enum DiskLocationKind: String, Codable, CaseIterable, Sendable {
    case interne, externe, reseau, nuage

    public var label: String {
        switch self {
        case .interne: return "Disque interne"
        case .externe: return "Disque externe"
        case .reseau: return "Partage réseau"
        case .nuage: return "Dossier nuage"
        }
    }

    /// Symbole SF de la liste.
    public var symbol: String {
        switch self {
        case .interne: return "internaldrive"
        case .externe: return "externaldrive"
        case .reseau: return "server.rack"
        case .nuage: return "icloud"
        }
    }

    var rank: Int {
        switch self {
        case .interne: return 0
        case .externe: return 1
        case .reseau: return 2
        case .nuage: return 3
        }
    }
}

/// Protocole d'un partage réseau monté.
public enum DiskNetworkProtocol: String, Codable, Sendable {
    case smb, nfs, afp, webdav

    public var label: String {
        switch self {
        case .smb: return "SMB"
        case .nfs: return "NFS"
        case .afp: return "AFP"
        case .webdav: return "WebDAV"
        }
    }

    /// Type de système de fichiers de statfs (« smbfs », « nfs », « afpfs », « webdav »).
    public init?(fileSystem: String) {
        switch fileSystem.lowercased() {
        case "smbfs", "cifs": self = .smb
        case "nfs": self = .nfs
        case "afpfs": self = .afp
        case "webdav": self = .webdav
        default: return nil
        }
    }
}

/// Service nuage d'un dossier File Provider ou d'iCloud Drive.
public enum DiskCloudProvider: String, Codable, Sendable {
    case icloud, onedrive, googleDrive, dropbox, box, autre

    public var label: String {
        switch self {
        case .icloud: return "iCloud Drive"
        case .onedrive: return "OneDrive"
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .box: return "Box"
        case .autre: return "Nuage"
        }
    }
}

/// Un emplacement à mesurer.
public struct DiskLocation: Codable, Hashable, Sendable, Identifiable {
    /// Clé de l'historique : l'emplacement enregistré (note 55) s'il y en a un, sinon le chemin du
    /// volume ou du dossier.
    public var id: String { savedID ?? path }
    public var name: String
    /// Point de montage ou dossier racine.
    public var path: String
    /// Dossier où « NetScope-test » est créé (le volume, ou un dossier inscriptible du volume).
    public var testParent: String
    public var kind: DiskLocationKind
    /// Système de fichiers en clair (« APFS », « exFAT », « SMB »…).
    public var fileSystem: String
    public var totalBytes: Int64?
    public var freeBytes: Int64?
    /// Serveur d'un partage réseau (« nas.bureau.local »).
    public var server: String?
    /// Nom du partage (« Projets »).
    public var share: String?
    public var networkProtocol: DiskNetworkProtocol?
    public var provider: DiskCloudProvider?
    /// Compte du dossier nuage (« Personnel », « dany@exemple.ca »).
    public var account: String?
    public var isReadOnly: Bool
    /// Emplacement ajouté par « Ajouter un emplacement… » (note 55) : « emplacement:<UUID> ».
    public var savedID: String?
    /// Faux pour un partage enregistré pas encore monté (monté au lancement du test) ou un dossier
    /// introuvable ; `path` est alors l'adresse du partage ou le chemin attendu.
    public var isMounted: Bool

    public init(name: String, path: String, testParent: String? = nil, kind: DiskLocationKind, fileSystem: String,
                totalBytes: Int64? = nil, freeBytes: Int64? = nil, server: String? = nil, share: String? = nil,
                networkProtocol: DiskNetworkProtocol? = nil, provider: DiskCloudProvider? = nil, account: String? = nil,
                isReadOnly: Bool = false, savedID: String? = nil, isMounted: Bool = true) {
        self.name = name
        self.path = path
        self.testParent = testParent ?? path
        self.kind = kind
        self.fileSystem = fileSystem
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.server = server
        self.share = share
        self.networkProtocol = networkProtocol
        self.provider = provider
        self.account = account
        self.isReadOnly = isReadOnly
        self.savedID = savedID
        self.isMounted = isMounted
    }

    /// Ligne sous le nom : « APFS · 412 Go libres sur 994 Go », « SMB · nas.bureau.local/Projets ».
    public var detail: String {
        var parts: [String] = []
        switch kind {
        case .reseau:
            parts.append(networkProtocol?.label ?? fileSystem)
            if let server { parts.append(server + (share.map { "/\($0)" } ?? "")) }
        case .nuage:
            parts.append(provider?.label ?? "Nuage")
            if let account, !account.isEmpty { parts.append(account) }
        case .interne, .externe:
            parts.append(fileSystem)
        }
        if let freeBytes {
            if let totalBytes, totalBytes > 0 {
                parts.append("\(DiskFormat.size(freeBytes)) libres sur \(DiskFormat.size(totalBytes))")
            } else {
                parts.append("\(DiskFormat.size(freeBytes)) libres")
            }
        }
        if isReadOnly { parts.append("lecture seule") }
        if !isMounted { parts.append(kind == .reseau ? "non monté" : "introuvable") }
        return parts.joined(separator: " · ")
    }

    /// Dossier d'essai « NetScope-test » de cet emplacement.
    public var testFolder: URL { DiskTestFolder.url(in: URL(fileURLWithPath: testParent, isDirectory: true)) }
}

/// Faits sur un volume monté, lus par `DiskLocationCatalog.mountedVolumes()` (ou fixés dans les tests).
public struct DiskVolumeFacts: Hashable, Sendable {
    public var path: String
    public var name: String
    /// Type statfs : « apfs », « exfat », « msdos », « smbfs », « nfs »…
    public var fsType: String
    /// Source du montage : « /dev/disk3s1 », « //dany@nas.local/Projets », « nas:/export/data ».
    public var mountFrom: String
    public var isInternal: Bool?
    public var isLocal: Bool?
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isReadOnly: Bool
    public var isRoot: Bool
    public var isBrowsable: Bool
    public var totalBytes: Int64?
    public var freeBytes: Int64?

    public init(path: String, name: String, fsType: String, mountFrom: String = "", isInternal: Bool? = nil,
                isLocal: Bool? = nil, isRemovable: Bool = false, isEjectable: Bool = false, isReadOnly: Bool = false,
                isRoot: Bool = false, isBrowsable: Bool = true, totalBytes: Int64? = nil, freeBytes: Int64? = nil) {
        self.path = path
        self.name = name
        self.fsType = fsType
        self.mountFrom = mountFrom
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isReadOnly = isReadOnly
        self.isRoot = isRoot
        self.isBrowsable = isBrowsable
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

public enum DiskLocationCatalog {
    /// Nom du système de fichiers en clair.
    public static func fileSystemLabel(_ fsType: String) -> String {
        switch fsType.lowercased() {
        case "apfs": return "APFS"
        case "hfs": return "Mac OS étendu"
        case "exfat": return "exFAT"
        case "msdos": return "FAT32"
        case "ntfs": return "NTFS"
        case "smbfs", "cifs": return "SMB"
        case "nfs": return "NFS"
        case "afpfs": return "AFP"
        case "webdav": return "WebDAV"
        case "": return "—"
        default: return fsType.uppercased()
        }
    }

    /// Serveur et partage d'une source de montage réseau : « //dany@nas.local/Projets » (SMB, AFP),
    /// « nas.local:/export/data » (NFS), « https://dav.exemple.ca/fichiers » (WebDAV).
    public static func serverAndShare(mountFrom: String) -> (server: String?, share: String?) {
        var text = mountFrom.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (nil, nil) }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        } else if text.hasPrefix("//") {
            text.removeFirst(2)
        } else if let colon = text.firstIndex(of: ":"), !text.hasPrefix("/") {
            // NFS : « serveur:/chemin ».
            let server = String(text[..<colon])
            var share = String(text[text.index(after: colon)...])
            while share.hasPrefix("/") { share.removeFirst() }
            return (server.isEmpty ? nil : server, share.isEmpty ? nil : share.removingPercentEncoding ?? share)
        } else {
            return (nil, nil)
        }
        // Compte avant « @ » (« dany;BUREAU@nas.local »), retiré.
        if let at = text.lastIndex(of: "@"), let slash = text.firstIndex(of: "/"), at < slash {
            text = String(text[text.index(after: at)...])
        } else if let at = text.lastIndex(of: "@"), !text.contains("/") {
            text = String(text[text.index(after: at)...])
        }
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var server = parts.first ?? ""
        // Port éventuel (« nas.local:445 ») retiré.
        if let colon = server.lastIndex(of: ":"), server.filter({ $0 == ":" }).count == 1 {
            server = String(server[..<colon])
        }
        let share = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
        return (server.isEmpty ? nil : server, share.isEmpty ? nil : (share.removingPercentEncoding ?? share))
    }

    /// Volume à proposer, ou nil (volumes système, images en lecture seule, volumes masqués).
    /// `home` : dossier de l'utilisateur ; sur le volume de démarrage, l'essai se fait dans
    /// ~/Library/Caches (le volume système est scellé en lecture seule).
    public static func location(for facts: DiskVolumeFacts, home: String = NSHomeDirectory()) -> DiskLocation? {
        let path = facts.path
        if path.hasPrefix("/System/Volumes/") || path == "/private/var/vm" || path.hasPrefix("/Library/Developer/CoreSimulator") { return nil }
        if ["devfs", "autofs", "nullfs", "lifs"].contains(facts.fsType.lowercased()) { return nil }
        if !facts.isBrowsable && !facts.isRoot { return nil }
        let fileSystem = fileSystemLabel(facts.fsType)
        if facts.isRoot {
            return DiskLocation(name: facts.name.isEmpty ? "Macintosh HD" : facts.name, path: path,
                                testParent: (home as NSString).appendingPathComponent("Library/Caches"),
                                kind: .interne, fileSystem: fileSystem, totalBytes: facts.totalBytes, freeBytes: facts.freeBytes)
        }
        if let proto = DiskNetworkProtocol(fileSystem: facts.fsType) {
            let (server, share) = serverAndShare(mountFrom: facts.mountFrom)
            return DiskLocation(name: facts.name, path: path, kind: .reseau, fileSystem: fileSystem,
                                totalBytes: facts.totalBytes, freeBytes: facts.freeBytes, server: server,
                                share: share ?? facts.name, networkProtocol: proto, isReadOnly: facts.isReadOnly)
        }
        // Image disque ou volume en lecture seule (installateur) : rien à mesurer en écriture.
        if facts.isReadOnly { return nil }
        if facts.isLocal == false {
            return DiskLocation(name: facts.name, path: path, kind: .reseau, fileSystem: fileSystem,
                                totalBytes: facts.totalBytes, freeBytes: facts.freeBytes)
        }
        let external = facts.isInternal == false || facts.isRemovable || facts.isEjectable
        return DiskLocation(name: facts.name, path: path, kind: external ? .externe : .interne, fileSystem: fileSystem,
                            totalBytes: facts.totalBytes, freeBytes: facts.freeBytes)
    }

    /// Dossier de ~/Library/CloudStorage : « OneDrive-Personal », « OneDrive-GroupeCouture »,
    /// « GoogleDrive-dany@exemple.ca », « Dropbox », « Box-Box ». Google Drive écrit dans « My Drive ».
    public static func cloudLocation(folderName: String, parent: String, freeBytes: Int64? = nil,
                                     totalBytes: Int64? = nil) -> DiskLocation? {
        guard !folderName.hasPrefix("."), !folderName.isEmpty else { return nil }
        let path = (parent as NSString).appendingPathComponent(folderName)
        let lower = folderName.lowercased()
        let (provider, rest): (DiskCloudProvider, String) = {
            for (prefix, provider) in [("onedrive", DiskCloudProvider.onedrive), ("googledrive", .googleDrive),
                                       ("dropbox", .dropbox), ("box", .box)] where lower.hasPrefix(prefix) {
                var rest = String(folderName.dropFirst(prefix.count))
                while rest.hasPrefix("-") || rest.hasPrefix(" ") { rest.removeFirst() }
                return (provider, rest)
            }
            return (.autre, folderName)
        }()
        var account: String? = rest.isEmpty ? nil : rest
        if provider == .onedrive, account == "Personal" { account = "Personnel" }
        if provider == .box, account == "Box" { account = nil }
        let name: String
        switch provider {
        case .autre: name = folderName
        default: name = provider.label + (account.map { provider == .googleDrive ? "" : " – \($0)" } ?? "")
        }
        let testParent = provider == .googleDrive ? (path as NSString).appendingPathComponent("My Drive") : path
        return DiskLocation(name: name, path: path, testParent: testParent, kind: .nuage, fileSystem: "File Provider",
                            totalBytes: totalBytes, freeBytes: freeBytes, provider: provider, account: account)
    }

    /// Ordre de la liste : interne, externes, partages, nuage ; puis par nom.
    public static func sorted(_ locations: [DiskLocation]) -> [DiskLocation] {
        locations.sorted {
            ($0.kind.rank, $0.name.localizedLowercase, $0.path) < ($1.kind.rank, $1.name.localizedLowercase, $1.path)
        }
    }

    /// Emplacement proposé par défaut : le dernier mesuré s'il est encore là, sinon le premier
    /// disque externe (c'est souvent lui qu'on vient tester), sinon le premier de la liste.
    public static func preferred(in locations: [DiskLocation], lastUsed: String?) -> DiskLocation? {
        if let lastUsed, let match = locations.first(where: { $0.id == lastUsed }) { return match }
        return locations.first { $0.kind == .externe && !$0.isReadOnly } ?? locations.first
    }

    // MARK: Lecture du Mac (aucun accès réseau : seulement les volumes déjà montés)

    /// Volumes montés et dossiers nuage de ce Mac, triés.
    public static func discover(home: String = NSHomeDirectory()) -> [DiskLocation] {
        var result = mountedVolumes().compactMap { location(for: $0, home: home) }
        let homeVolume = result.first { $0.kind == .interne && $0.path == "/" }
        result += cloudFolders(home: home, freeBytes: homeVolume?.freeBytes, totalBytes: homeVolume?.totalBytes)
        var seen: Set<String> = []
        result = result.filter { seen.insert($0.path).inserted }
        return sorted(result)
    }

    /// Faits de chaque volume monté (FileManager et statfs).
    public static func mountedVolumes() -> [DiskVolumeFacts] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
                                      .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey,
                                      .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            var info = statfs()
            let (fsType, mountFrom): (String, String) = url.path.withCString { pointer in
                guard statfs(pointer, &info) == 0 else { return ("", "") }
                let type = withUnsafeBytes(of: info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                let from = withUnsafeBytes(of: info.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                return (type, from)
            }
            let important = values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
            let free = important ?? values.volumeAvailableCapacity.map(Int64.init)
            return DiskVolumeFacts(path: url.path, name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
                                   fsType: fsType, mountFrom: mountFrom, isInternal: values.volumeIsInternal,
                                   isLocal: values.volumeIsLocal, isRemovable: values.volumeIsRemovable ?? false,
                                   isEjectable: values.volumeIsEjectable ?? false, isReadOnly: values.volumeIsReadOnly ?? false,
                                   isRoot: values.volumeIsRootFileSystem ?? (url.path == "/"),
                                   isBrowsable: values.volumeIsBrowsable ?? true,
                                   totalBytes: values.volumeTotalCapacity.map(Int64.init), freeBytes: free)
        }
    }

    /// Dossiers nuage : ~/Library/CloudStorage/* (File Provider) et iCloud Drive. Seuls les noms
    /// des dossiers sont lus ici (rien n'est ouvert à l'intérieur).
    public static func cloudFolders(home: String, freeBytes: Int64?, totalBytes: Int64?) -> [DiskLocation] {
        var result: [DiskLocation] = []
        let storage = (home as NSString).appendingPathComponent("Library/CloudStorage")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: storage) {
            for name in names.sorted() {
                var isDirectory: ObjCBool = false
                let path = (storage as NSString).appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if let location = cloudLocation(folderName: name, parent: storage, freeBytes: freeBytes, totalBytes: totalBytes) {
                    result.append(location)
                }
            }
        }
        let icloud = (home as NSString).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: icloud) {
            result.append(DiskLocation(name: "iCloud Drive", path: icloud, kind: .nuage, fileSystem: "iCloud",
                                       totalBytes: totalBytes, freeBytes: freeBytes, provider: .icloud))
        }
        return result
    }
}
