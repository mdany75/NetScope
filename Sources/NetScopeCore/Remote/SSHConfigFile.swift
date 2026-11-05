import Darwin
import Foundation

// Note 78 (Accès distant) : lecture de ~/.ssh/config, en lecture seule. Sert à importer les hôtes
// dans le carnet (Host, HostName, User, Port, ProxyJump, IdentityFile : le chemin de la clé, jamais
// la clé elle-même) et à savoir quel « utilisateur@hôte » ssh nommera dans sa demande de mot de
// passe (mot de passe du Trousseau remis à la bonne invite même quand le nom vient du fichier).
//
// Règles d'OpenSSH reprises : la première valeur trouvée gagne (IdentityFile s'additionne) ; les
// motifs de Host acceptent « * », « ? » et la négation « ! », sensibles à la casse ; Include accepte
// des jokers et des chemins relatifs à ~/.ssh, et un Include placé dans un bloc Host n'en applique le
// contenu qu'à cet hôte. Les blocs Match ne sont pas évalués (ils peuvent lancer des commandes) :
// ignorés, avec une remarque ; « Match all » vaut « Host * ».

/// Option lue (mot-clé en minuscules et ses valeurs, guillemets retirés).
public struct SSHConfigOption: Equatable, Sendable {
    public var key: String
    public var values: [String]
    public var line: Int

    public init(key: String, values: [String], line: Int) {
        self.key = key
        self.values = values
        self.line = line
    }

    public var value: String { values.joined(separator: " ") }
}

/// Bloc Host (ou options globales, ou Match ignoré).
public struct SSHConfigBlock: Equatable, Sendable {
    /// Motifs du bloc (« * » pour les options d'avant le premier Host).
    public var patterns: [String]
    /// Motifs des blocs qui l'englobent (Include placé dans un Host) : tous doivent correspondre.
    public var scope: [[String]]
    /// Bloc Match : jamais appliqué.
    public var isMatch: Bool
    public var options: [SSHConfigOption]
    public var file: String
    public var line: Int

    public init(patterns: [String], scope: [[String]] = [], isMatch: Bool = false, options: [SSHConfigOption] = [],
                file: String, line: Int) {
        self.patterns = patterns
        self.scope = scope
        self.isMatch = isMatch
        self.options = options
        self.file = file
        self.line = line
    }

    /// Le bloc s'applique à cet hôte (tel que tapé, comme ssh).
    public func applies(to host: String) -> Bool {
        guard !isMatch else { return false }
        return SSHConfigPattern.matches(host, patterns) && scope.allSatisfy { SSHConfigPattern.matches(host, $0) }
    }
}

/// Motifs de Host.
public enum SSHConfigPattern {
    /// Liste de motifs : au moins un motif positif correspond et aucun motif « ! » ne correspond.
    public static func matches(_ host: String, _ patterns: [String]) -> Bool {
        var matched = false
        for raw in patterns {
            let negated = raw.hasPrefix("!")
            let pattern = negated ? String(raw.dropFirst()) : raw
            guard glob(host, pattern) else { continue }
            if negated { return false }
            matched = true
        }
        return matched
    }

    /// « * » (zéro ou plusieurs caractères) et « ? » (un caractère), sensible à la casse.
    public static func glob(_ text: String, _ pattern: String) -> Bool {
        let t = Array(text), p = Array(pattern)
        var ti = 0, pi = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                ti += 1
                pi += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Motif sans joker ni négation : un hôte précis, importable.
    public static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains(where: { "*?!".contains($0) })
    }
}

/// Ce que ssh retiendrait pour un hôte.
public struct SSHResolvedHost: Equatable, Sendable {
    public var alias: String
    /// HostName, « %h » remplacé par l'alias.
    public var hostName: String?
    public var user: String?
    public var port: Int?
    /// ProxyJump (nil, ou "" pour « none »).
    public var proxyJump: String?
    public var identityFiles: [String]
    public var hostKeyAlias: String?
    /// Une ProxyCommand est définie (appliquée par ssh, jamais lancée par NetScope).
    public var hasProxyCommand: Bool

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil, proxyJump: String? = nil,
                identityFiles: [String] = [], hostKeyAlias: String? = nil, hasProxyCommand: Bool = false) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.proxyJump = proxyJump
        self.identityFiles = identityFiles
        self.hostKeyAlias = hostKeyAlias
        self.hasProxyCommand = hasProxyCommand
    }
}

/// Accès aux fichiers (remplacé par des données fixes dans les tests).
public struct SSHConfigLoader: Sendable {
    /// Dossier ~/.ssh (chemins relatifs des Include).
    public var sshDirectory: String
    public var home: String
    public var read: @Sendable (String) -> String?
    /// Chemins correspondant à un motif (triés).
    public var glob: @Sendable (String) -> [String]

    public init(sshDirectory: String, home: String, read: @escaping @Sendable (String) -> String?,
                glob: @escaping @Sendable (String) -> [String]) {
        self.sshDirectory = sshDirectory
        self.home = home
        self.read = read
        self.glob = glob
    }

    /// Fichiers du Mac (lecture seule).
    public static var system: SSHConfigLoader {
        let home = NSHomeDirectory()
        return SSHConfigLoader(sshDirectory: home + "/.ssh", home: home,
                               read: { path in
                                   // Un fichier de configuration raisonnable : au plus 1 Mo.
                                   guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                                         (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576,
                                         attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
                                   return try? String(contentsOfFile: path, encoding: .utf8)
                               },
                               glob: { pattern in SSHConfigLoader.systemGlob(pattern) })
    }

    static func systemGlob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(pattern, 0, nil, &result) == 0 else { return [] }
        var paths: [String] = []
        for index in 0..<Int(result.gl_pathc) {
            if let pointer = result.gl_pathv[index] { paths.append(String(cString: pointer)) }
        }
        return paths.sorted()
    }
}

/// Fichier ~/.ssh/config lu (et ses Include).
public struct SSHConfigFile: Equatable, Sendable {
    public static let maxIncludeDepth = 8

    public private(set) var blocks: [SSHConfigBlock] = []
    /// Remarques montrées à l'import (Match ignoré, Include introuvable…).
    public private(set) var notes: [String] = []
    public private(set) var ignoredMatchBlocks = 0

    public init() {}

    /// Lit `text` (contenu de `file`) ; les Include passent par `loader`.
    public static func parse(_ text: String, file: String = "~/.ssh/config", loader: SSHConfigLoader) -> SSHConfigFile {
        var config = SSHConfigFile()
        config.blocks = [SSHConfigBlock(patterns: ["*"], file: file, line: 0)]
        config.read(text, file: file, scope: [], depth: 0, loader: loader)
        config.blocks.removeAll { $0.options.isEmpty && !$0.isMatch && $0.line == 0 }
        return config
    }

    /// ~/.ssh/config du Mac (vide s'il n'existe pas).
    public static func load(loader: SSHConfigLoader = .system) -> SSHConfigFile {
        let path = loader.sshDirectory + "/config"
        guard let text = loader.read(path) else { return SSHConfigFile() }
        return parse(text, file: "~/.ssh/config", loader: loader)
    }

    private mutating func read(_ text: String, file: String, scope: [[String]], depth: Int, loader: SSHConfigLoader) {
        // Bloc courant : celui qui englobe (Include dans un Host) jusqu'au premier Host du fichier.
        var lineNumber = 0
        for rawLine in text.components(separatedBy: .newlines) {
            lineNumber += 1
            guard let (keyword, values) = Self.tokenize(rawLine) else { continue }
            switch keyword {
            case "host":
                blocks.append(SSHConfigBlock(patterns: values, scope: scope, file: file, line: lineNumber))
            case "match":
                if values.count == 1, values[0].lowercased() == "all" {
                    blocks.append(SSHConfigBlock(patterns: ["*"], scope: scope, file: file, line: lineNumber))
                } else {
                    ignoredMatchBlocks += 1
                    notes.append("Bloc «\u{00A0}Match \(values.joined(separator: " "))\u{00A0}» ignoré (\(file), ligne \(lineNumber))\u{00A0}: ses réglages s’appliquent quand même dans ssh.")
                    blocks.append(SSHConfigBlock(patterns: [], scope: scope, isMatch: true, file: file, line: lineNumber))
                }
            case "include":
                guard depth < Self.maxIncludeDepth else {
                    notes.append("Include trop imbriqué (\(file), ligne \(lineNumber))\u{00A0}: ignoré.")
                    continue
                }
                // Un Include placé dans un bloc n'en applique le contenu qu'aux hôtes de ce bloc.
                guard let current = blocks.last else { continue }
                if current.isMatch { continue }
                let innerScope = current.line == 0 && current.scope.isEmpty ? scope : current.scope + [current.patterns]
                for pattern in values {
                    let full = expand(pattern, loader: loader)
                    let paths = loader.glob(full)
                    if paths.isEmpty, !pattern.contains(where: { "*?[".contains($0) }) {
                        notes.append("Include «\u{00A0}\(pattern)\u{00A0}» introuvable (\(file), ligne \(lineNumber)).")
                    }
                    for path in paths {
                        guard let contents = loader.read(path) else { continue }
                        let shown = path.hasPrefix(loader.home + "/") ? "~" + path.dropFirst(loader.home.count) : path
                        blocks.append(SSHConfigBlock(patterns: ["*"], scope: innerScope, file: shown, line: 0))
                        read(contents, file: shown, scope: innerScope, depth: depth + 1, loader: loader)
                    }
                }
                // Après l'Include, le bloc d'origine reprend.
                var resumed = current
                resumed.options = []
                blocks.append(resumed)
            default:
                guard !blocks.isEmpty else { continue }
                blocks[blocks.count - 1].options.append(SSHConfigOption(key: keyword, values: values, line: lineNumber))
            }
        }
    }

    /// « ~/x », « %d/x » ou « x » (relatif à ~/.ssh).
    private func expand(_ path: String, loader: SSHConfigLoader) -> String {
        if path.hasPrefix("~/") { return loader.home + path.dropFirst(1) }
        if path.hasPrefix("%d/") { return loader.home + path.dropFirst(2) }
        if path.hasPrefix("/") { return path }
        return loader.sshDirectory + "/" + path
    }

    /// Mot-clé (en minuscules) et valeurs d'une ligne ; nil pour une ligne vide ou un commentaire.
    /// « Mot valeur », « Mot=valeur » et « Mot = valeur » ; valeurs entre guillemets permises ; un
    /// mot commençant par « # » termine la ligne.
    public static func tokenize(_ line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        var keywordDone = false
        for character in trimmed {
            if inQuotes {
                if character == "\"" { inQuotes = false } else { current.append(character) }
                continue
            }
            if character == "\"" {
                inQuotes = true
                hasToken = true
                continue
            }
            // « = » sépare le mot-clé de sa valeur (une seule fois).
            if character == "=", !keywordDone, tokens.isEmpty {
                if hasToken { tokens.append(current) }
                current = ""
                hasToken = false
                keywordDone = true
                continue
            }
            if character.isWhitespace {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            if character == "#", !hasToken, !tokens.isEmpty { break }
            current.append(character)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        guard let first = tokens.first, !first.isEmpty else { return nil }
        var values = Array(tokens.dropFirst())
        // « Mot = valeur » : le « = » isolé est retiré.
        if !keywordDone, values.first == "=" { values.removeFirst() }
        else if !keywordDone, let head = values.first, head.hasPrefix("=") {
            values[0] = String(head.dropFirst())
            if values[0].isEmpty { values.removeFirst() }
        }
        return (first.lowercased(), values)
    }

    /// Hôtes nommés (motifs sans joker ni négation), dans l'ordre du fichier.
    public var concreteAliases: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for block in blocks where !block.isMatch && block.line > 0 {
            // Un hôte hors de la portée de son Include (« Host autre » inclus depuis « Host nas »)
            // n'est jamais appliqué par ssh : écarté.
            for pattern in block.patterns where SSHConfigPattern.isConcrete(pattern) && !seen.contains(pattern)
                && block.scope.allSatisfy({ SSHConfigPattern.matches(pattern, $0) }) {
                seen.insert(pattern)
                result.append(pattern)
            }
        }
        return result
    }

    /// Réglages retenus par ssh pour `host` (première valeur gagnante ; IdentityFile cumulé).
    public func resolve(_ host: String) -> SSHResolvedHost {
        var resolved = SSHResolvedHost(alias: host)
        var seen = Set<String>()
        for block in blocks where block.applies(to: host) {
            for option in block.options {
                guard let first = option.values.first else { continue }
                if option.key == "identityfile" {
                    if !resolved.identityFiles.contains(first) { resolved.identityFiles.append(first) }
                    continue
                }
                guard !seen.contains(option.key) else { continue }
                seen.insert(option.key)
                switch option.key {
                case "hostname": resolved.hostName = Self.expandTokens(first, alias: host)
                case "user": resolved.user = first
                case "port": resolved.port = Int(first)
                case "proxyjump": resolved.proxyJump = first.lowercased() == "none" ? "" : first
                case "hostkeyalias": resolved.hostKeyAlias = first
                case "proxycommand": resolved.hasProxyCommand = first.lowercased() != "none"
                default: break
                }
            }
        }
        return resolved
    }

    /// « %h » : l'alias ; « %% » : « % ». Les autres jetons restent tels quels.
    static func expandTokens(_ text: String, alias: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "h"?: result += alias
            case "%"?: result.append("%")
            case let other?: result += "%" + String(other)
            case nil: result.append("%")
            }
        }
        return result
    }

    /// « utilisateur@hôte » que ssh nommera dans sa demande de mot de passe : utilisateur de la
    /// connexion, sinon User de ~/.ssh/config, sinon celui du Mac ; hôte : HostKeyAlias, sinon
    /// HostName, sinon l'hôte tapé, en minuscules (comme ssh).
    public func expectedPrompt(user: String, host: String, localUser: String = NSUserName()) -> String {
        let resolved = resolve(host)
        let trimmed = user.trimmingCharacters(in: .whitespaces)
        let name = !trimmed.isEmpty ? trimmed : (resolved.user.flatMap { $0.contains("%") ? nil : $0 } ?? localUser)
        let target = resolved.hostKeyAlias ?? resolved.hostName ?? host
        return name + "@" + target.lowercased()
    }
}

/// Hôte de ~/.ssh/config proposé à l'import.
public struct SSHConfigCandidate: Identifiable, Equatable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var resolved: SSHResolvedHost
    /// Connexion à ajouter, ou nil si l'hôte ne peut pas l'être (`problem`).
    public var connection: RemoteConnection?
    public var problem: String?
    /// Une connexion SSH de même hôte et même port existe déjà.
    public var alreadySaved: Bool
    /// Remarques (ProxyCommand, clé avec jetons…).
    public var remarks: [String]
}

/// Import des hôtes de ~/.ssh/config dans le carnet (lecture seule : rien n'est écrit dans ~/.ssh).
public enum SSHConfigImport {
    public static let folder = "Importés de ~/.ssh/config"

    /// Un candidat par hôte nommé. L'hôte de la connexion est l'alias : ssh applique ainsi tout le
    /// bloc du fichier (algorithmes, options) ; HostName est montré dans la description.
    public static func candidates(from config: SSHConfigFile, existing: [RemoteConnection],
                                  home: String = NSHomeDirectory()) -> [SSHConfigCandidate] {
        // « Host a b » : deux noms du même hôte ; seul le premier est proposé.
        var seen = Set<String>()
        return config.concreteAliases.compactMap { alias -> SSHConfigCandidate? in
            let resolved = config.resolve(alias)
            let key = "\(resolved.user ?? "")@\(resolved.hostName ?? alias):\(resolved.port ?? 22)|\(resolved.proxyJump ?? "")"
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            var remarks: [String] = []
            var note: [String] = []
            if let hostName = resolved.hostName, hostName != alias { note.append("HostName \(hostName)") }
            if resolved.hasProxyCommand {
                remarks.append("ProxyCommand du fichier\u{00A0}: appliquée par ssh, jamais lancée par NetScope.")
                note.append("ProxyCommand")
            }
            var identity = ""
            if let first = resolved.identityFiles.first {
                let path = first.hasPrefix("%d/") ? "~/" + first.dropFirst(3) : first
                if let valid = try? QuickLogin.validateKeyPath(path) {
                    identity = valid
                } else {
                    remarks.append("IdentityFile «\u{00A0}\(first)\u{00A0}» non repris (jetons ou chemin relatif)\u{00A0}: ssh le lit quand même.")
                }
                if resolved.identityFiles.count > 1 {
                    remarks.append("\(resolved.identityFiles.count) clés dans le fichier\u{00A0}: la première est reprise, ssh essaie les autres.")
                }
            }
            var user = resolved.user ?? ""
            if user.contains("%") {
                remarks.append("User «\u{00A0}\(user)\u{00A0}» avec jetons\u{00A0}: laissé à ssh.")
                user = ""
            }
            let connection = RemoteConnection(name: alias, proto: .ssh, host: alias, port: resolved.port ?? 22, username: user,
                                              folder: folder, note: note.isEmpty ? "~/.ssh/config" : "~/.ssh/config · " + note.joined(separator: " · "),
                                              proxyJump: resolved.proxyJump ?? "", identityFile: identity)
            let port = resolved.port ?? 22
            let hostName = resolved.hostName ?? alias
            let saved = existing.contains { saved in
                saved.proto == .ssh && saved.port == port
                    && (saved.host.caseInsensitiveCompare(alias) == .orderedSame || saved.host.caseInsensitiveCompare(hostName) == .orderedSame)
            }
            do {
                let valid = try connection.validated()
                return SSHConfigCandidate(alias: alias, resolved: resolved, connection: valid, problem: nil,
                                          alreadySaved: saved, remarks: remarks)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return SSHConfigCandidate(alias: alias, resolved: resolved, connection: nil, problem: reason,
                                          alreadySaved: saved, remarks: remarks)
            }
        }
    }
}
