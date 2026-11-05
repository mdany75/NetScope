import Foundation

// Note 56 : import d'une configuration, avec aperçu. Chaque élément de l'export est comparé à ce
// Mac : AJOUTÉ (absent ici), REMPLACÉ (différent ici, et pas modifié ici depuis l'export),
// IDENTIQUE, ou CONFLIT (modifié ici APRÈS la date de l'export) : un conflit n'est jamais
// appliqué sans que l'utilisateur le coche. Les sites et les FortiGate sont comparés un par un,
// par leur identifiant : jamais deux sites fusionnés, même avec les mêmes plages ou le même nom.
//
// L'import retenu devient un `ConfigApplyPlan` (opérations avec l'empreinte attendue de l'état
// actuel), appliqué au lancement suivant (comme une restauration) : si un élément a changé
// entre-temps sur ce Mac, il n'est pas écrasé et le plan le signale.

public enum ConfigChangeAction: String, Codable, Sendable, CaseIterable {
    case ajout, remplacement, identique, conflit

    public var label: String {
        switch self {
        case .ajout: return "Ajouté"
        case .remplacement: return "Remplacé"
        case .identique: return "Identique"
        case .conflit: return "Conflit"
        }
    }
}

/// Un élément de l'export et ce que l'import en ferait.
public struct ConfigChange: Identifiable, Hashable, Sendable {
    /// « fichier:sites.json », « preference:reglages.raccourcis », « secret:<service>|<compte> »,
    /// « element:sites.json#<id> ».
    public var id: String
    public var part: String
    public var kind: ConfigItemKind
    public var label: String
    public var detail: String?
    public var action: ConfigChangeAction
    public var localModified: Date?
    public var importModified: Date?

    public init(id: String, part: String, kind: ConfigItemKind, label: String, detail: String? = nil, action: ConfigChangeAction,
                localModified: Date? = nil, importModified: Date? = nil) {
        self.id = id
        self.part = part
        self.kind = kind
        self.label = label
        self.detail = detail
        self.action = action
        self.localModified = localModified
        self.importModified = importModified
    }

    /// Appliqué par défaut : ajouts et remplacements ; jamais un conflit (choix de l'utilisateur).
    public var appliedByDefault: Bool { action == .ajout || action == .remplacement }
}

/// Aperçu d'un import.
public struct ConfigImportPlan: Sendable {
    public var package: ConfigPackage
    public var changes: [ConfigChange]
    /// Parties présentes dans l'export, dans l'ordre du registre.
    public var parts: [ConfigPart]

    public func changes(in part: String) -> [ConfigChange] { changes.filter { $0.part == part } }

    public func count(_ action: ConfigChangeAction, in part: String? = nil) -> Int {
        changes.filter { $0.action == action && (part == nil || $0.part == part) }.count
    }

    /// Changements appliqués par défaut (ajouts et remplacements des parties présentes).
    public var defaultSelection: Set<String> { Set(changes.filter(\.appliedByDefault).map(\.id)) }
}

/// Opérations d'un import retenu (ou d'une synchronisation reçue), avec l'empreinte attendue de
/// l'état actuel. Codable : gardé jusqu'au lancement suivant.
public struct ConfigApplyPlan: Codable, Sendable, Equatable {
    public struct FileOp: Codable, Sendable, Equatable {
        public var path: String
        public var data: Data
        /// Empreinte du fichier actuel au moment de l'aperçu ; nil : il n'existait pas.
        public var expected: String?
        public var label: String
    }

    public struct PreferenceOp: Codable, Sendable, Equatable {
        public var key: String
        public var data: Data
        public var expected: String?
        public var label: String
    }

    public struct ElementOp: Codable, Sendable, Equatable {
        /// Clé de la liste (`ConfigCollection.key`).
        public var collection: String
        public var id: String
        public var json: Data
        public var expected: String?
        public var label: String
    }

    public var origin: String
    public var createdAt: Date
    public var files: [FileOp] = []
    public var preferences: [PreferenceOp] = []
    public var elements: [ElementOp] = []
    /// Secrets à remettre au Trousseau (jamais gardés dans le plan écrit sur le disque : voir `withoutSecrets`).
    public var secrets: [BackupSecret] = []

    public init(origin: String, createdAt: Date) {
        self.origin = origin
        self.createdAt = createdAt
    }

    public var isEmpty: Bool { files.isEmpty && preferences.isEmpty && elements.isEmpty && secrets.isEmpty }
    public var operationCount: Int { files.count + preferences.count + elements.count + secrets.count }

    /// Ajoute les opérations de `other` à ce plan ; une opération de même clé (chemin, préférence
    /// ou élément d'une liste) est remplacée par celle de `other`. Sert à ajouter une restauration
    /// à des changements reçus qui attendent déjà le redémarrage, sans les perdre.
    public func merging(_ other: ConfigApplyPlan) -> ConfigApplyPlan {
        var merged = self
        for op in other.files {
            merged.files.removeAll { $0.path == op.path }
            merged.files.append(op)
        }
        for op in other.preferences {
            merged.preferences.removeAll { $0.key == op.key }
            merged.preferences.append(op)
        }
        for op in other.elements {
            merged.elements.removeAll { $0.collection == op.collection && $0.id == op.id }
            merged.elements.append(op)
        }
        for secret in other.secrets {
            merged.secrets.removeAll { $0.service == secret.service && $0.account == secret.account }
            merged.secrets.append(secret)
        }
        return merged
    }

    /// Le plan sans secret (ce qui attend le redémarrage sur le disque).
    public var withoutSecrets: ConfigApplyPlan {
        var copy = self
        copy.secrets = []
        return copy
    }
}

/// Bilan d'un plan appliqué.
public struct ConfigApplyOutcome: Sendable, Equatable {
    public var applied: [String] = []
    /// Éléments changés sur ce Mac depuis l'aperçu : laissés tels quels.
    public var skipped: [String] = []
    public var failed: [String] = []
    public var preferences: [String: Data] = [:]
}

public enum ConfigImporter {
    // MARK: Aperçu

    /// Compare l'export à l'état de ce Mac. `parts` : parties de l'export retenues (toutes par défaut).
    public static func plan(_ package: ConfigPackage, local: ConfigSnapshot, registry: ConfigPartRegistry = .standard,
                            collections: [ConfigCollection] = ConfigCollection.standard) -> ConfigImportPlan {
        let exportDate = package.manifest.createdAt
        // La date du manifeste est à la seconde près : une modification dans la même seconde que
        // l’export n’est pas « après » lui.
        let conflictAfter = exportDate.addingTimeInterval(1)
        var changes: [ConfigChange] = []
        let collectionFiles = Set(collections.filter { $0.kind == .fichier }.map(\.key))
        let collectionPrefs = Set(collections.filter { $0.kind == .preference }.map(\.key))

        // Listes à identifiants : élément par élément.
        for collection in collections {
            let partID: String?
            switch collection.kind {
            case .fichier: partID = registry.part(forFile: collection.key)?.id
            case .preference: partID = registry.part(forPreference: collection.key)?.id
            default: partID = nil
            }
            guard let partID, let incomingData = package.snapshot.collectionData(collection),
                  let incoming = collection.elements(of: incomingData) else { continue }
            let localElements = local.collectionData(collection).flatMap(collection.elements) ?? []
            let localModified = local.collectionModified(collection)
            let importModified = package.snapshot.collectionModified(collection) ?? exportDate
            for element in incoming {
                let label = "\(collection.elementLabel) «\u{00A0}\(element.name.isEmpty ? element.id : element.name)\u{00A0}»"
                var action: ConfigChangeAction
                var detail: String?
                if let mine = localElements.first(where: { $0.id == element.id }) {
                    if mine.canonical == element.canonical {
                        action = .identique
                    } else if let localModified, localModified > conflictAfter {
                        action = .conflit
                        detail = "Modifié sur ce Mac après l’export"
                    } else {
                        action = .remplacement
                    }
                    if mine.name != element.name, !mine.name.isEmpty { detail = [detail, "«\u{00A0}\(mine.name)\u{00A0}» sur ce Mac"].compactMap { $0 }.joined(separator: " · ") }
                } else {
                    action = .ajout
                    var notes: [String] = []
                    if collection.uniqueNames, localElements.contains(where: { $0.name.lowercased() == element.name.lowercased() && !element.name.isEmpty }) {
                        let list = localElements.map { ["id": $0.id, collection.nameField: $0.name] as [String: Any] }
                        let unique = ConfigCollection.uniqueName(element.name, in: list, excluding: element.id, idField: "id", nameField: collection.nameField)
                        notes.append("même nom qu’un autre site de ce Mac\u{00A0}: ajouté sous «\u{00A0}\(unique)\u{00A0}»")
                    }
                    if let field = collection.similarField, let value = collection.field(field, of: element), value != Data("[[]]".utf8),
                       let twin = localElements.first(where: { collection.field(field, of: $0) == value }) {
                        notes.append("«\u{00A0}\(twin.name)\u{00A0}» a les \(collection.similarNote)")
                    }
                    detail = notes.isEmpty ? nil : notes.joined(separator: " · ")
                }
                changes.append(ConfigChange(id: collection.itemID(element.id), part: partID, kind: .element, label: label, detail: detail,
                                            action: action, localModified: localModified, importModified: importModified))
            }
        }

        // Fichiers (ceux d'un dossier de site portent le nom du site, de l'export ou de ce Mac).
        var siteNames: [String: String] = [:]
        for snapshot in [local, package.snapshot] {
            for element in snapshot.collectionData(.sites).flatMap(ConfigCollection.sites.elements) ?? [] where !element.name.isEmpty {
                siteNames[element.id] = element.name
            }
        }
        for file in package.files where !collectionFiles.contains(file.path) {
            guard let part = registry.part(forFile: file.path) else { continue }
            let mine = local.file(file.path)
            let action: ConfigChangeAction
            if let mine {
                if mine.data == file.data {
                    action = .identique
                } else if let modified = mine.modified, modified > conflictAfter {
                    action = .conflit
                } else {
                    action = .remplacement
                }
            } else {
                action = .ajout
            }
            changes.append(ConfigChange(id: "fichier:" + file.path, part: part.id, kind: .fichier, label: fileLabel(file.path, siteNames: siteNames),
                                        detail: action == .conflit ? "Modifié sur ce Mac après l’export" : file.path, action: action,
                                        localModified: mine?.modified, importModified: file.modified ?? exportDate))
        }

        // Préférences (sans date : jamais en conflit).
        for key in package.preferences.keys.sorted() where !collectionPrefs.contains(key) {
            guard let part = registry.part(forPreference: key), let data = package.preferences[key] else { continue }
            let action: ConfigChangeAction
            if let mine = local.preferences[key] {
                action = ConfigPlist.equal(mine, data) ? .identique : .remplacement
            } else {
                action = .ajout
            }
            changes.append(ConfigChange(id: "preference:" + key, part: part.id, kind: .preference, label: key, action: action,
                                        importModified: exportDate))
        }

        // Secrets : présents ou non sur ce Mac (les valeurs locales ne sont lues que si on les a).
        for secret in package.secrets {
            guard let part = registry.part(forSecret: secret.service, account: secret.account) else { continue }
            let exists = local.secretNames.contains { $0.service == secret.service && $0.account == secret.account }
            let localValue = local.secrets.first { $0.service == secret.service && $0.account == secret.account }?.value
            let action: ConfigChangeAction = !exists ? .ajout : (localValue == secret.value ? .identique : .remplacement)
            changes.append(ConfigChange(id: "secret:" + secret.service + "|" + secret.account, part: part.id, kind: .secret,
                                        label: secret.usage.isEmpty ? BackupKeychainScan.usage(for: secret.service) : secret.usage,
                                        detail: action == .remplacement ? "La valeur de ce Mac sera remplacée" : nil, action: action,
                                        importModified: exportDate))
        }

        let order = registry.ids
        changes.sort { a, b in
            let pa = order.firstIndex(of: a.part) ?? .max, pb = order.firstIndex(of: b.part) ?? .max
            if pa != pb { return pa < pb }
            if a.kind != b.kind { return ConfigItemKind.allCases.firstIndex(of: a.kind)! < ConfigItemKind.allCases.firstIndex(of: b.kind)! }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
        let present = Set(changes.map(\.part))
        return ConfigImportPlan(package: package, changes: changes, parts: registry.parts.filter { present.contains($0.id) })
    }

    /// « Inventaire · Entrepôt Laval » pour « sites/<id>/inventory.json », sinon le libellé de la sauvegarde.
    static func fileLabel(_ path: String, siteNames: [String: String]) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == SiteFiles.folderName else { return BackupEngine.label(for: path) }
        var label = BackupEngine.label(for: path)
        if let open = label.range(of: " (") { label = String(label[..<open.lowerBound]) }
        let name = parts[1] == SiteFiles.noSiteKey ? "plages libres" : (siteNames[parts[1]] ?? "site")
        return label.prefix(1).uppercased() + label.dropFirst() + " · " + name
    }

    // MARK: Plan retenu

    /// Opérations des changements choisis (identifiants de `ConfigChange`), dans les parties cochées.
    public static func resolve(_ plan: ConfigImportPlan, selected: Set<String>, parts: Set<String>, local: ConfigSnapshot,
                               collections: [ConfigCollection] = ConfigCollection.standard, origin: String = "import",
                               now: Date = Date()) -> ConfigApplyPlan {
        var result = ConfigApplyPlan(origin: origin, createdAt: now)
        let chosen = plan.changes.filter { selected.contains($0.id) && parts.contains($0.part) && $0.action != .identique }
        let package = plan.package.snapshot
        for change in chosen {
            switch change.kind {
            case .fichier:
                let path = String(change.id.dropFirst("fichier:".count))
                guard let file = package.file(path) else { continue }
                result.files.append(.init(path: path, data: file.data, expected: local.file(path).map { ConfigHash.sha256($0.data) },
                                          label: change.label))
            case .preference:
                let key = String(change.id.dropFirst("preference:".count))
                guard let data = package.preferences[key] else { continue }
                result.preferences.append(.init(key: key, data: data, expected: local.preferences[key].map(ConfigPlist.hash), label: change.label))
            case .secret:
                let name = String(change.id.dropFirst("secret:".count))
                if let secret = package.secrets.first(where: { $0.service + "|" + $0.account == name }) { result.secrets.append(secret) }
            case .element:
                for collection in collections where change.id.hasPrefix("element:\(collection.key)#") {
                    let id = String(change.id.dropFirst("element:\(collection.key)#".count))
                    guard let element = package.collectionData(collection).flatMap(collection.elements)?.first(where: { $0.id == id }) else { continue }
                    let mine = local.collectionData(collection).flatMap(collection.elements)?.first { $0.id == id }
                    result.elements.append(.init(collection: collection.key, id: id, json: element.json, expected: mine?.hash, label: change.label))
                }
            }
        }
        return result
    }

    // MARK: Application

    /// Applique le plan au dossier de données et renvoie les préférences à écrire (l'appelant les
    /// pose dans UserDefaults). Un élément changé depuis l'aperçu n'est pas écrasé (`skipped`).
    /// Les secrets ne sont pas traités ici (`BackupEngine.restoreSecrets`).
    public static func apply(_ plan: ConfigApplyPlan, to directory: URL, preferences current: [String: Any],
                             collections: [ConfigCollection] = ConfigCollection.standard) -> ConfigApplyOutcome {
        var outcome = ConfigApplyOutcome()
        let manager = FileManager.default
        let snapshot = ConfigSnapshot.read(dataDirectory: directory, preferences: current)

        func write(_ data: Data, to path: String) throws {
            guard BackupEngine.isSafeRelativePath(path) else { throw ConfigError.corrupted("chemin «\u{00A0}\(path)\u{00A0}» refusé") }
            let url = directory.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }

        for op in plan.files {
            let now = snapshot.file(op.path).map { ConfigHash.sha256($0.data) }
            guard now == op.expected || now == ConfigHash.sha256(op.data) else {
                outcome.skipped.append(op.label)
                continue
            }
            do {
                try write(op.data, to: op.path)
                outcome.applied.append(op.label)
            } catch {
                outcome.failed.append(op.label)
            }
        }
        for op in plan.preferences {
            let now = snapshot.preferences[op.key].map(ConfigPlist.hash)
            guard now == op.expected || now == ConfigPlist.hash(op.data) else {
                outcome.skipped.append(op.label)
                continue
            }
            outcome.preferences[op.key] = op.data
            outcome.applied.append(op.label)
        }
        // Éléments : chaque liste relue, fusionnée élément par élément, réécrite une fois.
        var preferenceOverrides = snapshot.preferences
        for (key, data) in outcome.preferences { preferenceOverrides[key] = data }
        for collection in collections {
            let ops = plan.elements.filter { $0.collection == collection.key }
            guard !ops.isEmpty else { continue }
            let view = ConfigSnapshot(files: snapshot.files, preferences: preferenceOverrides)
            let localData = view.collectionData(collection)
            let localElements = localData.flatMap(collection.elements) ?? []
            var incoming: [ConfigCollection.Element] = []
            for op in ops {
                let now = localElements.first { $0.id == op.id }
                guard let element = (try? JSONSerialization.jsonObject(with: op.json)).flatMap(collection.element) else {
                    outcome.failed.append(op.label)
                    continue
                }
                guard now?.hash == op.expected || now?.hash == element.hash else {
                    outcome.skipped.append(op.label)
                    continue
                }
                incoming.append(element)
            }
            guard !incoming.isEmpty, let merged = collection.merge(local: localData, applying: incoming) else { continue }
            switch collection.kind {
            case .fichier:
                do {
                    try write(merged, to: collection.key)
                    outcome.applied += incoming.compactMap { element in ops.first { $0.id == element.id }?.label }
                } catch {
                    outcome.failed += incoming.compactMap { element in ops.first { $0.id == element.id }?.label }
                }
            case .preference:
                if let encoded = ConfigPlist.encode(merged) {
                    outcome.preferences[collection.key] = encoded
                    preferenceOverrides[collection.key] = encoded
                    outcome.applied += incoming.compactMap { element in ops.first { $0.id == element.id }?.label }
                }
            default:
                break
            }
        }
        return outcome
    }
}
