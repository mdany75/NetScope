import Foundation

// Note 86 : un fichier JSON global découpé pour la synchronisation. Un fichier qui contient des
// listes à identifiants (connexions, sondes, identifiants…) donne UN ÉLÉMENT PAR ENTRÉE, plus un
// « reste » (les autres clés de premier niveau, sans celles propres à ce Mac). Deux Mac qui
// changent deux connexions différentes fusionnent donc sans conflit ; le même élément changé des
// deux côtés est un conflit, comme pour les sites.
//
// À la réception, le fichier de ce Mac est relu et seulement les éléments reçus y sont remplacés,
// ajoutés ou retirés : les clés propres à ce Mac (états des sondes, historique, journal) et les
// champs propres au Mac de chaque élément restent ceux d'ici. Venue d'un Mac d'une version plus
// ancienne (`preserveUnknown`), une version ne retire jamais un champ qu'elle ne connaît pas.

/// Clés des éléments synchronisés du dossier global.
public enum ConfigSyncKey {
    /// « doc:connexions.json » : reste d'un fichier découpé.
    public static func document(_ path: String) -> String { "doc:" + path }
    /// « element:connexions.json#connections#<id> ».
    public static func element(_ path: String, list: ConfigSyncList, id: String) -> String { "element:\(path)#\(list.token)#\(id)" }
    public static func file(_ path: String) -> String { "fichier:" + path }
    public static func preference(_ key: String) -> String { "preference:" + key }
    public static func secret(service: String, account: String) -> String { "secret:" + service + "|" + account }

    public enum Parsed: Equatable, Sendable {
        case document(path: String)
        case element(path: String, arrayKey: String?, id: String)
        case file(path: String)
        case preference(key: String)
        case site
        case fortiGate(id: String)
        case other
    }

    public static func parse(_ key: String) -> Parsed {
        if key == "site" { return .site }
        if key.hasPrefix("fortigate:") { return .fortiGate(id: String(key.dropFirst("fortigate:".count))) }
        if key.hasPrefix("doc:") { return .document(path: String(key.dropFirst(4))) }
        if key.hasPrefix("fichier:") { return .file(path: String(key.dropFirst("fichier:".count))) }
        if key.hasPrefix("preference:") { return .preference(key: String(key.dropFirst("preference:".count))) }
        if key.hasPrefix("element:") {
            let body = key.dropFirst("element:".count)
            let parts = body.split(separator: "#", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty else { return .other }
            return .element(path: parts[0], arrayKey: parts[1].isEmpty ? nil : parts[1], id: parts[2])
        }
        return .other
    }
}

public enum ConfigSyncDocument {
    /// Un composant d'un fichier découpé.
    public struct Part: Sendable, Hashable {
        public var key: String
        public var label: String
        /// JSON complet (champs propres au Mac compris).
        public var json: Data
        /// JSON comparé (sans les champs propres au Mac), clés triées.
        public var canonical: Data
        public var hash: String { ConfigHash.sha256(canonical) }
    }

    static let writing: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]

    static func serialize(_ object: Any, pretty: Bool = false) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        var options = writing
        if pretty { options.insert(.prettyPrinted) }
        return try? JSONSerialization.data(withJSONObject: object, options: options)
    }

    /// Composants d'un fichier selon sa règle ; nil si le fichier n'a pas la forme attendue (il
    /// se synchronise alors en entier).
    public static func split(_ data: Data, path: String, rule: ConfigSyncFileRule) -> [Part]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var parts: [Part] = []
        if let object = root as? [String: Any] {
            var rest = object
            for key in rule.preservedKeys { rest.removeValue(forKey: key) }
            if let json = serialize(rest) {
                parts.append(Part(key: ConfigSyncKey.document(path), label: rule.label, json: json, canonical: json))
            }
            for list in rule.lists {
                guard let arrayKey = list.arrayKey else { continue }
                guard let array = object[arrayKey] else { continue }
                guard let elements = array as? [Any] else { return nil }
                parts += self.elements(elements, path: path, list: list)
            }
        } else if let array = root as? [Any], let list = rule.lists.first(where: { $0.arrayKey == nil }) {
            parts += elements(array, path: path, list: list)
        } else {
            return nil
        }
        return parts
    }

    private static func elements(_ array: [Any], path: String, list: ConfigSyncList) -> [Part] {
        var parts: [Part] = []
        var seen: Set<String> = []
        for case let dictionary as [String: Any] in array {
            guard let id = identifier(dictionary[list.idField]), !id.isEmpty, seen.insert(id).inserted,
                  let json = serialize(dictionary) else { continue }
            var stripped = dictionary
            for field in list.volatileFields { stripped.removeValue(forKey: field) }
            guard let canonical = serialize(stripped) else { continue }
            let name = list.nameFields.lazy.compactMap { dictionary[$0] as? String }.first { !$0.isEmpty } ?? id
            parts.append(Part(key: ConfigSyncKey.element(path, list: list, id: id),
                              label: "\(list.elementLabel) «\u{00A0}\(name)\u{00A0}»", json: json, canonical: canonical))
        }
        return parts
    }

    static func identifier(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: Composition

    /// Applique des opérations reçues au fichier de ce Mac (absent : nil) et renvoie le nouveau
    /// fichier ; nil : rien à écrire (fichier supprimé par l'opération, ou JSON illisible ici).
    /// `deleteFile` est vrai si une opération supprime le fichier entier.
    public static func apply(_ ops: [ConfigApplyPlan.DocumentOp], to local: Data?, rule: ConfigSyncFileRule?)
        -> (data: Data?, deleteFile: Bool) {
        if ops.contains(where: { $0.id == nil && $0.json == nil }) { return (nil, true) }
        var root: Any
        if let local {
            guard let parsed = try? JSONSerialization.jsonObject(with: local) else { return (nil, false) }
            root = parsed
        } else {
            root = (rule?.lists.contains { $0.arrayKey == nil } ?? false) ? [Any]() as Any : [String: Any]() as Any
        }
        for op in ops {
            if op.id == nil, let json = op.json {
                // Reste du fichier : remplacé, sauf les listes et les clés propres à ce Mac.
                guard var object = root as? [String: Any],
                      let incoming = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { continue }
                let preserved = Set(op.preserve)
                if !(op.preserveUnknown ?? false) {
                    for key in object.keys where !preserved.contains(key) && incoming[key] == nil { object.removeValue(forKey: key) }
                }
                for (key, value) in incoming where !preserved.contains(key) { object[key] = value }
                root = object
            } else if let id = op.id {
                root = upsert(op, id: id, in: root, rule: rule)
            }
        }
        return (serialize(root, pretty: true), false)
    }

    private static func upsert(_ op: ConfigApplyPlan.DocumentOp, id: String, in root: Any, rule: ConfigSyncFileRule?) -> Any {
        let list = rule?.lists.first { $0.arrayKey == op.arrayKey }
        let idField = list?.idField ?? op.idField ?? "id"
        var container = root
        var array: [Any]
        if let arrayKey = op.arrayKey {
            guard let object = root as? [String: Any] else { return root }
            array = object[arrayKey] as? [Any] ?? []
            container = object
        } else {
            guard let existing = root as? [Any] else { return root }
            array = existing
        }
        let index = array.firstIndex { identifier(($0 as? [String: Any])?[idField]) == id }
        if let json = op.json {
            guard var incoming = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return root }
            let current = index.flatMap { array[$0] as? [String: Any] } ?? [:]
            if op.preserveUnknown ?? false {
                for (key, value) in current where incoming[key] == nil { incoming[key] = value }
            }
            for field in list?.volatileFields ?? [] {
                if let value = current[field] { incoming[field] = value } else if index != nil { incoming.removeValue(forKey: field) }
            }
            if let index { array[index] = incoming } else { array.append(incoming) }
        } else if let index {
            array.remove(at: index)
        }
        if let arrayKey = op.arrayKey, var object = container as? [String: Any] {
            object[arrayKey] = array
            return object
        }
        return array
    }

    /// Empreinte de la partie qu'une opération écrit (pour reconnaître une partie déjà à jour).
    public static func hash(of op: ConfigApplyPlan.DocumentOp, rule: ConfigSyncFileRule?) -> String? {
        guard let json = op.json else { return nil }
        guard op.id != nil else { return ConfigHash.sha256(json) }
        guard var dictionary = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        for field in rule?.lists.first(where: { $0.arrayKey == op.arrayKey })?.volatileFields ?? [] { dictionary.removeValue(forKey: field) }
        return serialize(dictionary).map(ConfigHash.sha256)
    }

    /// Superpose les champs d'un élément reçu d'un Mac plus ancien à ceux d'ici : un champ que
    /// l'autre version ne connaît pas n'est jamais retiré.
    public static func overlay(_ incoming: Data, on local: Data?) -> Data {
        guard let local, var base = (try? JSONSerialization.jsonObject(with: local)) as? [String: Any],
              let received = (try? JSONSerialization.jsonObject(with: incoming)) as? [String: Any] else { return incoming }
        for (key, value) in received { base[key] = value }
        return serialize(base) ?? incoming
    }
}
