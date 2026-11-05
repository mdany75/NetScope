import Foundation

/// Élément d'un dossier distant (FTP, FTPS, SFTP) ou local.
public struct RemoteFileEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file, directory, link
    }

    public var id: String { path }
    public var name: String
    /// Chemin complet (« /pub/firmware/FGT_60F-v7.4.4.out »).
    public var path: String
    public var kind: Kind
    /// Taille en octets (inconnue pour certains dossiers).
    public var size: Int64?
    public var modified: Date?
    /// Droits Unix « rwxr-xr-x » (sans le type), ou nil si le serveur ne les donne pas.
    public var permissions: String?
    public var owner: String?
    public var group: String?
    /// Cible d'un lien symbolique.
    public var linkTarget: String?

    public init(name: String, path: String, kind: Kind, size: Int64? = nil, modified: Date? = nil,
                permissions: String? = nil, owner: String? = nil, group: String? = nil, linkTarget: String? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.linkTarget = linkTarget
    }

    /// Dossier, ou lien qu'on peut ouvrir comme un dossier (sa cible est vérifiée à l'ouverture).
    public var isDirectory: Bool { kind == .directory }

    /// Droits en octal (« 755 ») à partir de « rwxr-xr-x ».
    public var octalPermissions: String? {
        guard let permissions, permissions.count >= 9 else { return nil }
        let chars = Array(permissions.prefix(9))
        var digits = ""
        for group in 0..<3 {
            var value = 0
            if chars[group * 3] == "r" { value += 4 }
            if chars[group * 3 + 1] == "w" { value += 2 }
            // « s » et « t » : bit spécial ET exécution ; « S » et « T » : bit spécial seul.
            if "xst".contains(chars[group * 3 + 2]) { value += 1 }
            digits.append(String(value))
        }
        return digits
    }

    /// Tri du navigateur : dossiers d'abord, puis par nom (ordre du Finder).
    public static func browserOrder(_ lhs: RemoteFileEntry, _ rhs: RemoteFileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// Analyse des listes de fichiers : MLSD (RFC 3659), LIST façon Unix (« ls -l ») et façon DOS/IIS.
public enum FTPListing {
    /// Réponse MLSD : « type=file;size=1024;modify=20261104101500;perm=r; nom ».
    public static func parseMLSD(_ text: String, directory: String) -> [RemoteFileEntry] {
        FTPLineSplitter.lines(in: text).compactMap { parseMLSDLine($0, directory: directory) }
    }

    public static func parseMLSDLine(_ line: String, directory: String) -> RemoteFileEntry? {
        // Les faits se terminent par « ; » et une espace sépare le nom (qui peut contenir des « ; »).
        guard let space = line.firstIndex(of: " ") else { return nil }
        let factsText = line[..<space]
        let name = String(line[line.index(after: space)...])
        guard RemotePath.isSafeEntryName(name) else { return nil }
        var facts: [String: String] = [:]
        for fact in factsText.split(separator: ";") {
            let parts = fact.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            facts[parts[0].lowercased()] = String(parts[1])
        }
        let type = facts["type"]?.lowercased() ?? "file"
        guard type != "cdir", type != "pdir" else { return nil }
        let kind: RemoteFileEntry.Kind
        if type == "dir" { kind = .directory } else if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") { kind = .link } else { kind = .file }
        var permissions: String?
        if let mode = facts["unix.mode"], let value = Int(mode, radix: 8) {
            permissions = rwx(value)
        }
        let size = facts["size"].flatMap { Int64($0) } ?? facts["sizd"].flatMap { Int64($0) }
        return RemoteFileEntry(name: name, path: RemotePath.join(directory, name), kind: kind,
                               size: kind == .directory ? nil : size,
                               modified: facts["modify"].flatMap(mlsdDate),
                               permissions: permissions,
                               owner: facts["unix.owner"] ?? facts["unix.uid"],
                               group: facts["unix.group"] ?? facts["unix.gid"])
    }

    /// « 20261104101500 » ou « 20261104101500.123 » (UTC).
    public static func mlsdDate(_ text: String) -> Date? {
        let digits = text.split(separator: ".").first.map(String.init) ?? text
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        let chars = Array(digits)
        func number(_ from: Int, _ length: Int) -> Int { Int(String(chars[from..<from + length])) ?? 0 }
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = number(8, 2)
        components.minute = number(10, 2)
        components.second = number(12, 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    /// Réponse LIST : formats Unix et DOS mélangés ; « total 12 » et lignes illisibles ignorées.
    /// `now` : sert à deviner l'année des dates récentes (« Nov  4 10:15 », sans année).
    public static func parseLIST(_ text: String, directory: String, now: Date = Date()) -> [RemoteFileEntry] {
        FTPLineSplitter.lines(in: text).compactMap { parseLISTLine($0, directory: directory, now: now) }
    }

    public static func parseLISTLine(_ line: String, directory: String, now: Date = Date()) -> RemoteFileEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("total ") else { return nil }
        if let first = trimmed.first, first.isNumber { return parseDOSLine(trimmed, directory: directory) }
        return parseUnixLine(line, directory: directory, now: now)
    }

    /// « drwxr-xr-x    2 ftp      ftp          4096 Nov  4 10:15 firmware »
    /// « -rw-r--r--    1 1000     1000      1048576 Mar 12  2025 config backup.cfg »
    /// « lrwxrwxrwx    1 root     root            7 Jan  1  2024 latest -> v7.4.4 »
    static func parseUnixLine(_ line: String, directory: String, now: Date) -> RemoteFileEntry? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        // Découpe en mots en gardant la position de chacun (le nom peut contenir des espaces).
        var words: [(text: Substring, end: String.Index)] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, line[index] != " ", line[index] != "\t" { index = line.index(after: index) }
            words.append((line[start..<index], index))
        }
        guard words.count >= 6, let typeChar = words[0].text.first, "-dlbcps".contains(typeChar) else { return nil }
        // Repère le mois : la taille le précède, le jour et l'heure (ou l'année) le suivent.
        guard let monthIndex = words.indices.dropFirst(2).first(where: { position in
            position + 2 < words.count && months.contains(words[position].text.prefix(3).lowercased())
                && words[position].text.count <= 4 && Int(words[position + 1].text) != nil
                && Int64(words[position - 1].text) != nil
        }) else { return nil }
        let nameStart = words[monthIndex + 2].end
        var name = String(line[nameStart...])
        // Une seule espace sépare normalement la date du nom ; les espaces suivantes en font partie.
        if name.hasPrefix(" ") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        var linkTarget: String?
        let kind: RemoteFileEntry.Kind
        switch typeChar {
        case "d": kind = .directory
        case "l":
            kind = .link
            if let arrow = name.range(of: " -> ") {
                linkTarget = String(name[arrow.upperBound...])
                name = String(name[..<arrow.lowerBound])
            }
        default: kind = .file
        }
        guard RemotePath.isSafeEntryName(name) else { return nil }
        let size = Int64(words[monthIndex - 1].text)
        let month = months.firstIndex(of: words[monthIndex].text.prefix(3).lowercased())! + 1
        let day = Int(words[monthIndex + 1].text) ?? 1
        let timeOrYear = String(words[monthIndex + 2].text)
        let modified = unixDate(month: month, day: day, timeOrYear: timeOrYear, now: now)
        let permissions = String(words[0].text.dropFirst().prefix(9))
        // Propriétaire et groupe : les deux mots qui suivent le nombre de liens, s'ils sont là.
        var owner: String?
        var group: String?
        if monthIndex >= 5 {
            owner = String(words[2].text)
            group = String(words[3].text)
        } else if monthIndex == 4 {
            owner = String(words[2].text)
        }
        return RemoteFileEntry(name: name, path: RemotePath.join(directory, name), kind: kind,
                               size: kind == .directory ? nil : size, modified: modified,
                               permissions: permissions.count == 9 ? permissions : nil,
                               owner: owner, group: group, linkTarget: linkTarget)
    }

    /// Date « Nov  4 10:15 » (année devinée : la plus récente qui n'est pas dans le futur, à un jour
    /// près) ou « Nov  4  2025 ». Heure du serveur, lue comme UTC faute de mieux.
    static func unixDate(month: Int, day: Int, timeOrYear: String, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.month = month
        components.day = day
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            components.hour = parts[0]
            components.minute = parts[1]
            let year = calendar.component(.year, from: now)
            components.year = year
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                components.year = year - 1
            }
        } else {
            guard let year = Int(timeOrYear) else { return nil }
            components.year = year
        }
        return calendar.date(from: components)
    }

    /// « 11-04-26  10:15AM       <DIR>          firmware » ou « 03-12-2025  02:30PM  1048576 config.cfg ».
    static func parseDOSLine(_ line: String, directory: String) -> RemoteFileEntry? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4 else { return nil }
        let date = dosDate(String(parts[0]), String(parts[1]))
        let isDirectory = parts[2].uppercased() == "<DIR>"
        let name = String(parts[3]).trimmingCharacters(in: .whitespaces)
        guard RemotePath.isSafeEntryName(name) else { return nil }
        return RemoteFileEntry(name: name, path: RemotePath.join(directory, name),
                               kind: isDirectory ? .directory : .file,
                               size: isDirectory ? nil : Int64(parts[2]), modified: date)
    }

    static func dosDate(_ day: String, _ time: String) -> Date? {
        let d = day.split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
        guard d.count == 3 else { return nil }
        var year = d[2]
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        let upper = time.uppercased()
        let clock = upper.replacingOccurrences(of: "AM", with: "").replacingOccurrences(of: "PM", with: "")
        let t = clock.split(separator: ":").compactMap { Int($0) }
        guard t.count >= 2 else { return nil }
        var hour = t[0] % 12
        if upper.hasSuffix("PM") { hour += 12 } else if !upper.hasSuffix("AM") { hour = t[0] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: d[0], day: d[1], hour: hour, minute: t[1]))
    }

    /// 0o755 → « rwxr-xr-x ».
    public static func rwx(_ mode: Int) -> String {
        var text = ""
        for shift in [6, 3, 0] {
            let bits = (mode >> shift) & 7
            text += (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + (bits & 1 != 0 ? "x" : "-")
        }
        return text
    }
}

/// Volet « Ce Mac » du navigateur : contenu d'un dossier local, au même format que le serveur.
public enum LocalFileListing {
    /// Éléments du dossier (fichiers cachés exclus sauf `showHidden`), dossiers d'abord.
    public static func list(_ directory: URL, showHidden: Bool = false, fileManager: FileManager = .default) throws -> [RemoteFileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                       options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true && values?.isPackage != true
            let kind: RemoteFileEntry.Kind = values?.isSymbolicLink == true ? .link : (isDirectory ? .directory : .file)
            let mode = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
            return RemoteFileEntry(name: url.lastPathComponent, path: url.path, kind: kind,
                                   size: isDirectory ? nil : (values?.fileSize).map(Int64.init),
                                   modified: values?.contentModificationDate,
                                   permissions: mode.map { FTPListing.rwx($0.intValue) })
        }
        .sorted(by: RemoteFileEntry.browserOrder)
    }
}
