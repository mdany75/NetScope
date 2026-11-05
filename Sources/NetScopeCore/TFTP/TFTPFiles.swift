import Darwin
import Foundation

// Fichiers du serveur TFTP : chemin limité au dossier partagé (jamais de « ../ »), lecture et
// écriture par blocs, conversion netascii.

/// Nom de fichier demandé par un appareil, ramené à un chemin relatif sûr.
public enum TFTPPath {
    /// Composants du chemin relatif au dossier partagé, ou nil si le nom est refusé. Les barres
    /// obliques inverses (clients Windows) deviennent des « / » ; la barre de tête est ignorée
    /// (« /config.txt » = « config.txt », comme tftpd -s) ; « . » est ignoré ; « .. », un nom vide,
    /// un caractère de contrôle ou un nom de plus de 255 octets sont refusés.
    public static func components(of filename: String) -> [String]? {
        guard !filename.isEmpty, filename.utf8.count <= 1024 else { return nil }
        guard !filename.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let normalized = filename.replacingOccurrences(of: "\\", with: "/")
        var parts: [String] = []
        for part in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            let piece = String(part)
            if piece == "." { continue }
            if piece == ".." { return nil }
            guard piece.utf8.count <= 255 else { return nil }
            parts.append(piece)
        }
        return parts.isEmpty ? nil : parts
    }

    /// Chemin relatif lisible (« firmware/image.bin »).
    public static func display(_ filename: String) -> String {
        components(of: filename)?.joined(separator: "/") ?? filename
    }
}

/// Erreurs d'accès aux fichiers du serveur, avec leur code TFTP.
public struct TFTPFileError: Error, Equatable, Sendable, LocalizedError {
    public var code: TFTPErrorCode
    public var message: String

    public init(_ code: TFTPErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
    public var failure: TFTPFailure { .local(code, message) }
}

/// Accès aux fichiers du dossier partagé.
public struct TFTPFileAccess: Sendable {
    public let root: URL
    public var allowWrite: Bool
    public var allowOverwrite: Bool
    /// Taille maximale d'un fichier reçu (nil : pas de limite).
    public var maxWriteSize: Int64?

    public init(root: URL, allowWrite: Bool = false, allowOverwrite: Bool = false, maxWriteSize: Int64? = nil) {
        self.root = root.standardizedFileURL
        self.allowWrite = allowWrite
        self.allowOverwrite = allowOverwrite
        self.maxWriteSize = maxWriteSize
    }

    /// Dossier partagé, liens symboliques résolus.
    private var resolvedRoot: String { root.resolvingSymlinksInPath().path }

    /// Fichier demandé, toujours à l'intérieur du dossier partagé (liens symboliques compris).
    public func resolve(_ filename: String) throws -> URL {
        guard let parts = TFTPPath.components(of: filename) else {
            throw TFTPFileError(.accessViolation, "Nom de fichier refusé («\u{00A0}\(filename)\u{00A0}»)\u{00A0}: chemin hors du dossier partagé ou invalide.")
        }
        var url = root
        for part in parts { url.appendPathComponent(part) }
        let base = resolvedRoot
        // Le dossier parent, liens résolus, doit rester sous la racine ; le fichier aussi s'il existe.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == base || parent.hasPrefix(base + "/") else {
            throw TFTPFileError(.accessViolation, "Accès refusé\u{00A0}: «\u{00A0}\(parts.joined(separator: "/"))\u{00A0}» sort du dossier partagé.")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let target = url.resolvingSymlinksInPath().path
            guard target.hasPrefix(base + "/") else {
                throw TFTPFileError(.accessViolation, "Accès refusé\u{00A0}: «\u{00A0}\(parts.joined(separator: "/"))\u{00A0}» pointe hors du dossier partagé.")
            }
        }
        return url
    }

    /// Ouvre un fichier à envoyer (RRQ).
    public func openForReading(_ filename: String, mode: TFTPMode) throws -> TFTPFileSource {
        let url = try resolve(filename)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw TFTPFileError(.fileNotFound, "Fichier introuvable dans le dossier partagé\u{00A0}: «\u{00A0}\(TFTPPath.display(filename))\u{00A0}».")
        }
        guard !isDirectory.boolValue else {
            throw TFTPFileError(.fileNotFound, "«\u{00A0}\(TFTPPath.display(filename))\u{00A0}» est un dossier, pas un fichier.")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw TFTPFileError(.accessViolation, "Lecture refusée par macOS\u{00A0}: «\u{00A0}\(TFTPPath.display(filename))\u{00A0}».")
        }
        return try TFTPFileSource(url: url, mode: mode)
    }

    /// Prépare l'écriture d'un fichier reçu (WRQ) : refus si le serveur est en lecture seule, si le
    /// dossier n'existe pas ou si le fichier existe et que l'écrasement n'est pas permis.
    public func openForWriting(_ filename: String, mode: TFTPMode, announcedSize: Int64?) throws -> TFTPFileSink {
        guard allowWrite else {
            throw TFTPFileError(.accessViolation, "Écriture refusée\u{00A0}: le serveur est en lecture seule.")
        }
        let url = try resolve(filename)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TFTPFileError(.accessViolation, "Dossier introuvable dans le partage pour «\u{00A0}\(TFTPPath.display(filename))\u{00A0}».")
        }
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw TFTPFileError(.accessViolation, "«\u{00A0}\(TFTPPath.display(filename))\u{00A0}» est un dossier.")
            }
            guard allowOverwrite else {
                throw TFTPFileError(.fileExists, "«\u{00A0}\(TFTPPath.display(filename))\u{00A0}» existe déjà\u{00A0}: écrasement non autorisé.")
            }
        }
        if let maxWriteSize, let announcedSize, announcedSize > maxWriteSize {
            throw TFTPFileError(.diskFull, "Fichier trop gros (\(TFTPFormat.bytes(announcedSize)), limite \(TFTPFormat.bytes(maxWriteSize))).")
        }
        if let announcedSize, let free = Self.freeSpace(at: url.deletingLastPathComponent()), announcedSize > free {
            throw TFTPFileError(.diskFull, "Espace disque insuffisant (\(TFTPFormat.bytes(announcedSize)) demandés, \(TFTPFormat.bytes(free)) libres).")
        }
        return try TFTPFileSink(destination: url, mode: mode, maxSize: maxWriteSize, overwrite: allowOverwrite)
    }

    /// Espace libre du volume (octets), si macOS le donne.
    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Fichiers du dossier partagé (premier niveau et sous-dossiers, 500 au plus), pour l'interface.
    public func listing(limit: Int = 500) -> [TFTPSharedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [TFTPSharedFile] = []
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
            files.append(TFTPSharedFile(path: relative, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? Date()))
            if files.count >= limit { break }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// Fichier du dossier partagé (liste de l'interface).
public struct TFTPSharedFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var size: Int64
    public var modified: Date

    public init(path: String, size: Int64, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

// MARK: - Netascii

/// Conversion netascii (RFC 764) : sur le fil, LF devient CR LF et CR seul devient CR NUL.
public enum TFTPNetascii {
    public static func encode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 16)
        for byte in bytes {
            switch byte {
            case 0x0A: out.append(0x0D); out.append(0x0A)
            case 0x0D: out.append(0x0D); out.append(0x00)
            default: out.append(byte)
            }
        }
        return out
    }

    /// Décodeur par morceaux (un CR peut finir un bloc et son LF ou NUL commencer le suivant).
    public struct Decoder: Sendable {
        private var pendingCR = false

        public init() {}

        public mutating func decode(_ bytes: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            for byte in bytes {
                if pendingCR {
                    pendingCR = false
                    switch byte {
                    case 0x0A: out.append(0x0A); continue
                    case 0x00: out.append(0x0D); continue
                    default: out.append(0x0D)
                    }
                }
                if byte == 0x0D { pendingCR = true } else { out.append(byte) }
            }
            return out
        }

        /// Fin du fichier : un CR en attente est rendu tel quel.
        public mutating func finish() -> [UInt8] {
            defer { pendingCR = false }
            return pendingCR ? [0x0D] : []
        }
    }
}

// MARK: - Source et destination

/// Fichier envoyé bloc par bloc. En netascii, le fichier converti est gardé en mémoire (fichiers
/// texte de configuration ; 64 Mio au plus).
public final class TFTPFileSource: @unchecked Sendable {
    public let url: URL
    /// Taille envoyée sur le fil (après conversion netascii).
    public let size: Int64
    private let handle: FileHandle?
    private var buffer: [UInt8]
    private var offset = 0

    public static let maxNetasciiSize: Int64 = 64 << 20

    public init(url: URL, mode: TFTPMode) throws {
        self.url = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        switch mode {
        case .octet:
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw TFTPFileError(.accessViolation, "Lecture refusée\u{00A0}: \(error.localizedDescription)")
            }
            buffer = []
            size = fileSize
        case .netascii:
            guard fileSize <= Self.maxNetasciiSize else {
                throw TFTPFileError(.accessViolation, "Fichier trop gros pour le mode texte (netascii)\u{00A0}: utilisez le mode binaire.")
            }
            guard let data = try? Data(contentsOf: url) else {
                throw TFTPFileError(.accessViolation, "Lecture refusée par macOS.")
            }
            handle = nil
            buffer = TFTPNetascii.encode([UInt8](data))
            size = Int64(buffer.count)
        }
    }

    public func read(_ count: Int) throws -> [UInt8] {
        if let handle {
            do {
                return [UInt8](try handle.read(upToCount: count) ?? Data())
            } catch {
                throw TFTPFileError(.accessViolation, "Lecture interrompue\u{00A0}: \(error.localizedDescription)")
            }
        }
        let end = min(offset + count, buffer.count)
        defer { offset = end }
        return Array(buffer[offset..<end])
    }

    public func close() {
        try? handle?.close()
    }

    deinit { try? handle?.close() }
}

/// Fichier reçu : écrit dans un fichier temporaire caché du même dossier, puis mis à sa place à
/// la fin (un transfert interrompu ne laisse jamais un fichier tronqué à la place de l'ancien).
public final class TFTPFileSink: @unchecked Sendable {
    public let destination: URL
    private let temporary: URL
    private let handle: FileHandle
    private var decoder: TFTPNetascii.Decoder?
    private let maxSize: Int64?
    private let overwrite: Bool
    public private(set) var written: Int64 = 0
    private var closed = false

    public init(destination: URL, mode: TFTPMode, maxSize: Int64? = nil, overwrite: Bool = true) throws {
        self.destination = destination
        self.maxSize = maxSize
        self.overwrite = overwrite
        temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).tftp-partiel")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o644]),
              let handle = try? FileHandle(forWritingTo: temporary) else {
            throw TFTPFileError(.accessViolation, "Écriture refusée par macOS dans «\u{00A0}\(destination.deletingLastPathComponent().lastPathComponent)\u{00A0}».")
        }
        self.handle = handle
        decoder = mode == .netascii ? TFTPNetascii.Decoder() : nil
    }

    public func write(_ bytes: [UInt8]) throws {
        var data = bytes
        if decoder != nil { data = decoder!.decode(bytes) }
        if let maxSize, written + Int64(data.count) > maxSize {
            throw TFTPFileError(.diskFull, "Fichier trop gros (limite \(TFTPFormat.bytes(maxSize))).")
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw TFTPFileError(.diskFull, "Écriture impossible\u{00A0}: \(error.localizedDescription)")
        }
        written += Int64(data.count)
    }

    /// Fin du transfert : le fichier reçu prend sa place.
    public func commit() throws {
        if var decoder {
            let rest = decoder.finish()
            self.decoder = decoder
            if !rest.isEmpty { try write(rest) }
        }
        try? handle.close()
        closed = true
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) {
                guard overwrite else {
                    try? manager.removeItem(at: temporary)
                    throw TFTPFileError(.fileExists, "«\u{00A0}\(destination.lastPathComponent)\u{00A0}» est apparu pendant le transfert.")
                }
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
        } catch let error as TFTPFileError {
            throw error
        } catch {
            try? manager.removeItem(at: temporary)
            throw TFTPFileError(.accessViolation, "Enregistrement impossible\u{00A0}: \(error.localizedDescription)")
        }
    }

    /// Transfert interrompu : le fichier partiel est supprimé.
    public func discard() {
        if !closed { try? handle.close() }
        closed = true
        try? FileManager.default.removeItem(at: temporary)
    }
}

// MARK: - Mise en forme

public enum TFTPFormat {
    /// « 512 o », « 18,4 Kio », « 32,1 Mio ».
    public static func bytes(_ value: Int64) -> String {
        let units = ["o", "Kio", "Mio", "Gio", "Tio"]
        var amount = Double(max(value, 0))
        var unit = 0
        while amount >= 1024 && unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(amount))\u{00A0}o" }
        return "\(ToolFormat.decimal(amount, digits: amount < 10 ? 1 : (amount < 100 ? 1 : 0)))\u{00A0}\(units[unit])"
    }

    /// « 1,2 Mio/s », « 840 Kio/s » ; « — » sans durée.
    public static func rate(bytes: Int64, seconds: TimeInterval) -> String {
        guard seconds > 0.0005, seconds.isFinite else { return "—" }
        let perSecond = Double(bytes) / seconds
        return TFTPFormat.bytes(Int64(perSecond.isFinite ? min(perSecond, 9e15) : 0)) + "/s"
    }

    /// Pourcentage entier « 42 % » (espace insécable).
    public static func percent(_ done: Int64, of total: Int64?) -> String? {
        guard let total, total > 0 else { return nil }
        let value = min(100, max(0, Int((Double(done) / Double(total) * 100).rounded(.down))))
        return "\(value)\u{00A0}%"
    }
}
