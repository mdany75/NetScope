import Foundation

// Note 56 : listes à identifiants (sites de sites.json, FortiGate de la préférence
// NetScope.fortigate.controleurs) : importées et synchronisées ÉLÉMENT PAR ÉLÉMENT, chaque
// élément reconnu par son identifiant, jamais par son nom ni par ses plages IP (plusieurs sites
// peuvent avoir les mêmes plages). Deux éléments d'identifiants différents ne sont jamais fusionnés.

/// Une liste à identifiants, dans un fichier JSON ou dans une préférence (Data JSON).
public struct ConfigCollection: Sendable, Hashable {
    public var kind: ConfigItemKind
    /// Chemin relatif (fichier) ou clé de préférence.
    public var key: String
    /// Clé du tableau dans l'objet JSON (« sites ») ; nil : le JSON est le tableau lui-même.
    public var arrayKey: String?
    public var idField: String
    public var nameField: String
    /// Champs propres à chaque Mac (dernier scan, nombre de fiches, dernier état) : ni comparés,
    /// ni remplacés (la valeur de ce Mac est gardée).
    public var volatileFields: [String]
    /// « Site », « FortiGate ».
    public var elementLabel: String
    /// Noms uniques dans la liste (« Clinique (2) » pour un élément ajouté au même nom).
    public var uniqueNames: Bool
    /// Champ comparé pour signaler une ressemblance sans jamais fusionner (« ranges »).
    public var similarField: String?
    public var similarNote: String

    public init(kind: ConfigItemKind, key: String, arrayKey: String? = nil, idField: String = "id", nameField: String = "name",
                volatileFields: [String] = [], elementLabel: String, uniqueNames: Bool = false, similarField: String? = nil,
                similarNote: String = "") {
        self.kind = kind
        self.key = key
        self.arrayKey = arrayKey
        self.idField = idField
        self.nameField = nameField
        self.volatileFields = volatileFields
        self.elementLabel = elementLabel
        self.uniqueNames = uniqueNames
        self.similarField = similarField
        self.similarNote = similarNote
    }

    public static let sites = ConfigCollection(kind: .fichier, key: SiteFiles.listName, arrayKey: "sites",
                                               volatileFields: ["lastScan", "inventoryCount"], elementLabel: "Site",
                                               uniqueNames: true, similarField: "ranges",
                                               similarNote: "mêmes plages\u{00A0}: sites gardés séparés (reconnus par leur identifiant)")
    public static let fortiGates = ConfigCollection(kind: .preference, key: "NetScope.fortigate.controleurs", nameField: "site",
                                                    volatileFields: ["lastStatus"], elementLabel: "FortiGate")

    /// Listes de NetScope fusionnées élément par élément.
    public static let standard: [ConfigCollection] = [.sites, .fortiGates]

    /// Identifiant d'un changement d'élément : « element:sites.json#<id> ».
    public func itemID(_ elementID: String) -> String { "element:\(key)#\(elementID)" }

    // MARK: Lecture

    public struct Element: Sendable, Hashable {
        public var id: String
        public var name: String
        /// Élément en JSON (clés triées), champs propres au Mac compris.
        public var json: Data
        /// Élément sans les champs propres au Mac, clés triées : comparaison et empreinte.
        public var canonical: Data
        public var hash: String { ConfigHash.sha256(canonical) }
    }

    /// Éléments de la liste, dans l'ordre ; nil si les données ne sont pas cette liste.
    public func elements(of data: Data) -> [Element]? {
        guard let array = array(in: data) else { return nil }
        return array.compactMap(element)
    }

    func element(_ object: Any) -> Element? {
        guard let dictionary = object as? [String: Any], let id = dictionary[idField] as? String, !id.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) else { return nil }
        var stripped = dictionary
        for field in volatileFields { stripped.removeValue(forKey: field) }
        guard let canonical = try? JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys]) else { return nil }
        return Element(id: id, name: dictionary[nameField] as? String ?? "", json: json, canonical: canonical)
    }

    private func array(in data: Data) -> [Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arrayKey {
            return (root as? [String: Any])?[arrayKey] as? [Any]
        }
        return root as? [Any]
    }

    /// Valeur d'un champ d'un élément, en JSON trié (comparaison « mêmes plages »).
    public func field(_ name: String, of element: Element) -> Data? {
        guard let dictionary = try? JSONSerialization.jsonObject(with: element.json) as? [String: Any], let value = dictionary[name],
              JSONSerialization.isValidJSONObject([value]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
    }

    // MARK: Fusion

    /// Applique des éléments à la liste locale : chaque élément remplace celui du même
    /// identifiant (en gardant ses champs propres au Mac) ou s'ajoute à la fin ; `remove` retire
    /// des identifiants. Le reste du conteneur (version, site actif) est celui de ce Mac.
    /// Renvoie la liste en JSON (clés triées, indentée pour un fichier).
    public func merge(local: Data?, applying incoming: [Element], removing remove: Set<String> = []) -> Data? {
        var root: Any
        if let local, let parsed = try? JSONSerialization.jsonObject(with: local), array(in: local) != nil {
            root = parsed
        } else {
            root = arrayKey.map { [$0: [Any]()] as Any } ?? [Any]()
        }
        var list: [Any] = (arrayKey.flatMap { ((root as? [String: Any])?[$0] as? [Any]) } ?? (root as? [Any])) ?? []
        list.removeAll { object in
            guard let id = (object as? [String: Any])?[idField] as? String else { return false }
            return remove.contains(id)
        }
        for item in incoming {
            guard var dictionary = (try? JSONSerialization.jsonObject(with: item.json)) as? [String: Any] else { continue }
            if let index = list.firstIndex(where: { (($0 as? [String: Any])?[idField] as? String) == item.id }) {
                let current = list[index] as? [String: Any] ?? [:]
                for field in volatileFields {
                    if let value = current[field] { dictionary[field] = value } else { dictionary.removeValue(forKey: field) }
                }
                if uniqueNames, let name = dictionary[nameField] as? String {
                    dictionary[nameField] = Self.uniqueName(name, in: list, excluding: item.id, idField: idField, nameField: nameField)
                }
                list[index] = dictionary
            } else {
                // Élément nouveau sur ce Mac : sans l'état propre à l'autre Mac.
                for field in volatileFields { dictionary.removeValue(forKey: field) }
                if uniqueNames, let name = dictionary[nameField] as? String {
                    dictionary[nameField] = Self.uniqueName(name, in: list, excluding: item.id, idField: idField, nameField: nameField)
                }
                list.append(dictionary)
            }
        }
        if let arrayKey {
            var object = root as? [String: Any] ?? [:]
            object[arrayKey] = list
            root = object
        } else {
            root = list
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if kind == .fichier { options.insert(.prettyPrinted) }
        return try? JSONSerialization.data(withJSONObject: root, options: options)
    }

    /// Nom libre dans la liste : « Clinique », sinon « Clinique (2) »… (la règle de SiteList).
    static func uniqueName(_ wanted: String, in list: [Any], excluding id: String, idField: String, nameField: String) -> String {
        let taken = Set(list.compactMap { object -> String? in
            guard let dictionary = object as? [String: Any], (dictionary[idField] as? String) != id else { return nil }
            return (dictionary[nameField] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let base = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, taken.contains(base.lowercased()) else { return wanted }
        var number = 2
        while taken.contains("\(base) (\(number))".lowercased()) { number += 1 }
        return "\(base) (\(number))"
    }
}
