import Foundation

/// Manière de comparer la valeur d'un critère « préfixe:valeur » aux valeurs d'un champ.
public enum SearchMatchKind: String, Sendable, Hashable {
    /// Le champ contient la valeur (insensible à la casse et aux accents).
    case text
    /// Adresse IPv4 : préfixe d'adresse aligné sur les octets (`10.20.`, `10.20`), adresse
    /// complète (égalité) ou bloc CIDR (`10.20.0.0/16`).
    case ip
    /// Adresse MAC : séparateurs ignorés (`94dd.f818`, `94-DD-F8`, `94ddf8`).
    case mac
    /// Numéro (VLAN, port) : égalité si la valeur est numérique (`vlan:4` ne trouve pas 40) ;
    /// sinon « contient ». Pour un nom de port (« 1/14 », « port14 », « Gi1/0/14 »), on compare
    /// le dernier nombre du nom.
    case number
}

/// Champ d'un module qu'un critère « préfixe:valeur » peut viser.
public struct SearchAttribute: Hashable, Sendable, Identifiable {
    /// Clé canonique, en français, sans accent : « switch », « fab », « etat ».
    public let key: String
    /// Libellé affiché sur l'étiquette : « Switch », « Fabricant ».
    public let label: String
    /// Préfixes reconnus (la clé en premier), en français et en anglais.
    public let aliases: [String]
    public let kind: SearchMatchKind
    /// Exemple de valeur, pour le menu des préfixes : « SW-ETG2 ».
    public let example: String

    public var id: String { key }

    public init(_ key: String, label: String, aliases: [String] = [], kind: SearchMatchKind = .text, example: String) {
        self.key = key
        self.label = label
        var all = [key]
        for alias in aliases where !all.contains(alias) { all.append(alias) }
        self.aliases = all
        self.kind = kind
        self.example = example
    }

    /// Exemple complet : « switch:SW-ETG2 ».
    public var sample: String {
        "\(key):" + (example.contains(" ") ? "\"\(example)\"" : example)
    }

    /// Le même champ avec un autre libellé ou un autre exemple (un module précise le sens).
    public func with(label: String? = nil, example: String? = nil) -> SearchAttribute {
        SearchAttribute(key, label: label ?? self.label, aliases: Array(aliases.dropFirst()), kind: kind,
                    example: example ?? self.example)
    }
}

// MARK: - Champs communs

public extension SearchAttribute {
    static let ip = SearchAttribute("ip", label: "IP", aliases: ["adresse", "address", "addr"], kind: .ip, example: "10.182.122.")
    static let mac = SearchAttribute("mac", label: "MAC", aliases: ["bssid"], kind: .mac, example: "94dd.f818")
    static let name = SearchAttribute("nom", label: "Nom", aliases: ["name", "host", "hostname", "hote"], example: "brother")
    static let type = SearchAttribute("type", label: "Type", aliases: ["kind", "genre"], example: "imprimante")
    static let vendor = SearchAttribute("fab", label: "Fabricant", aliases: ["fabricant", "vendor", "marque", "brand"], example: "Brother")
    static let switchName = SearchAttribute("switch", label: "Switch", aliases: ["sw", "commutateur"], example: "SW-ETG2")
    static let port = SearchAttribute("port", label: "Port", aliases: ["interface", "if"], kind: .number, example: "14")
    static let vlan = SearchAttribute("vlan", label: "VLAN", kind: .number, example: "30")
    static let site = SearchAttribute("site", label: "Site", aliases: ["fortigate", "fgt"], example: "Montréal")
    static let ssid = SearchAttribute("ssid", label: "SSID", aliases: ["reseau", "network", "wifi"], example: "Bureau")
    static let accessPoint = SearchAttribute("borne", label: "Borne", aliases: ["ap", "fortiap"], example: "FAP-ETG2")
    static let status = SearchAttribute("etat", label: "État", aliases: ["statut", "status", "state"], example: "hors ligne")
    static let openPort = SearchAttribute("tcp", label: "Port ouvert", aliases: ["ouvert", "service", "open"], kind: .number, example: "9100")
    static let note = SearchAttribute("note", label: "Note", aliases: ["notes", "remarque"], example: "accueil")
    static let range = SearchAttribute("plage", label: "Plage", aliases: ["range"], example: "Bureau")
    static let tag = SearchAttribute("tag", label: "Étiquette", aliases: ["etiquette", "label"], example: "critique")
    static let location = SearchAttribute("local", label: "Local", aliases: ["lieu", "emplacement", "location", "salle"], example: "204")
    static let wallJack = SearchAttribute("prise", label: "Prise", aliases: ["jack"], example: "P2-14")
    static let owner = SearchAttribute("resp", label: "Responsable", aliases: ["responsable", "owner", "proprio"], example: "Dany")
    static let asset = SearchAttribute("actif", label: "N° d’actif", aliases: ["asset", "inventaire"], example: "INV-00412")
    static let severity = SearchAttribute("gravite", label: "Gravité", aliases: ["severity", "niveau", "level"], example: "critique")
    static let target = SearchAttribute("cible", label: "Cible", aliases: ["target"], example: "10.182.122.1")
    static let proto = SearchAttribute("proto", label: "Protocole", aliases: ["protocole", "protocol"], example: "ssh")
    static let user = SearchAttribute("user", label: "Utilisateur", aliases: ["utilisateur", "util", "login"], example: "admin")
    static let folder = SearchAttribute("dossier", label: "Dossier", aliases: ["folder", "groupe", "group"], example: "Serveurs")
    static let poe = SearchAttribute("poe", label: "PoE", example: "actif")
    static let speed = SearchAttribute("vitesse", label: "Vitesse", aliases: ["speed", "debit"], example: "1 Gbit/s")
    static let source = SearchAttribute("source", label: "Source", aliases: ["src"], example: "FDB")
    static let model = SearchAttribute("modele", label: "Modèle", aliases: ["model"], example: "FS-148F")
    static let message = SearchAttribute("message", label: "Message", aliases: ["msg", "titre", "title"], example: "hors ligne")
    static let city = SearchAttribute("ville", label: "Ville", aliases: ["city"], example: "Montréal")
    static let country = SearchAttribute("pays", label: "Pays", aliases: ["country"], example: "Canada")
    static let sponsor = SearchAttribute("operateur", label: "Opérateur", aliases: ["fai", "isp", "sponsor"], example: "Bell")
    static let channel = SearchAttribute("canal", label: "Canal", aliases: ["channel", "ch"], kind: .number, example: "36")
    static let band = SearchAttribute("bande", label: "Bande", aliases: ["band"], example: "5 GHz")
    static let security = SearchAttribute("securite", label: "Sécurité", aliases: ["security", "secu"], example: "WPA3")
    static let section = SearchAttribute("section", label: "Section", aliases: ["rubrique"], example: "Alertes")
}

/// Champs d'un module (Scanner, Inventaire…), avec la recherche de leurs préfixes.
public struct SearchSchema: Sendable {
    public let fields: [SearchAttribute]
    /// Requête d'exemple affichée dans le menu des préfixes : « switch:SW-ETG2 type:imprimante ».
    public let example: String
    private let byAlias: [String: SearchAttribute]

    public init(_ fields: [SearchAttribute], example: String? = nil) {
        self.fields = fields
        self.example = example ?? fields.prefix(2).map(\.sample).joined(separator: " ")
        var map: [String: SearchAttribute] = [:]
        for field in fields {
            for alias in field.aliases where map[SearchText.fold(alias)] == nil { map[SearchText.fold(alias)] = field }
        }
        byAlias = map
    }

    /// Champ désigné par un préfixe (« sw », « Fabricant », « état »…), nil s'il est inconnu ici.
    public func field(forPrefix prefix: String) -> SearchAttribute? {
        byAlias[SearchText.fold(prefix)]
    }

    /// Champs de plusieurs listes d'un même écran (le premier champ d'une clé l'emporte).
    public init(merging schemas: [SearchSchema], example: String) {
        var fields: [SearchAttribute] = []
        for schema in schemas {
            for field in schema.fields where !fields.contains(where: { $0.key == field.key }) { fields.append(field) }
        }
        self.init(fields, example: example)
    }

    public func field(_ key: String) -> SearchAttribute? {
        fields.first { $0.key == key }
    }

    /// Schéma sans champ : tout est du texte (les deux-points compris).
    public static let textOnly = SearchSchema([], example: "")
}

/// Normalisation commune des textes comparés.
public enum SearchText {
    /// Minuscules, sans accents ni largeur, apostrophe typographique ramenée à l'apostrophe droite.
    public static func fold(_ text: String) -> String {
        // Chemin rapide (note 36) : un texte tout en ASCII n'a ni accent, ni pleine chasse, ni
        // apostrophe typographique, ni espace insécable ; plier revient à passer en minuscules.
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return text.utf8.contains(where: { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }) ? text.lowercased() : text
        }
        // Les textes accentués se répètent beaucoup (types « Caméra IP », noms de sites) : pliés
        // une fois, puis relus dans une petite mémoire.
        if let known = FoldMemo.shared.value(for: text) { return known }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        FoldMemo.shared.store(folded, for: text)
        return folded
    }

    /// Textes pliés réunis par U+0001 (voir `SearchableRecord.searchFoldedText`).
    public static func foldedJoined(_ texts: [String]) -> String {
        texts.map(fold).joined(separator: "\u{1}")
    }

    /// Chiffres hexadécimaux seulement (comparaison des adresses MAC).
    static func hexDigits(_ text: String) -> String {
        String(fold(text).unicodeScalars.filter { ("0"..."9").contains($0) || ("a"..."f").contains($0) }.map(Character.init))
    }

    /// Dernier nombre d'un nom de port ou de VLAN : « 1/14 » → 14, « port14 » → 14, « 30 » → 30.
    static func lastNumber(_ text: String) -> Int? {
        var digits = ""
        var found: String?
        for ch in text {
            if ch.isASCII && ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                found = digits
                digits = ""
            }
        }
        if !digits.isEmpty { found = digits }
        return found.flatMap { Int($0.prefix(9)) }
    }
}

/// Mémoire des textes non ASCII déjà pliés (bornée : vidée quand elle est pleine).
private final class FoldMemo: @unchecked Sendable {
    static let shared = FoldMemo()
    private static let limit = 8_192
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for text: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[text]
    }

    func store(_ folded: String, for text: String) {
        // Les longs textes (notes) ne se répètent pas : inutile de les garder.
        guard text.utf8.count <= 64 else { return }
        lock.lock()
        defer { lock.unlock() }
        if values.count >= Self.limit { values.removeAll(keepingCapacity: true) }
        values[text] = folded
    }
}
