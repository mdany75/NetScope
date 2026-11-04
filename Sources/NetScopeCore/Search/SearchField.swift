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
public struct SearchField: Hashable, Sendable, Identifiable {
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
    public func with(label: String? = nil, example: String? = nil) -> SearchField {
        SearchField(key, label: label ?? self.label, aliases: Array(aliases.dropFirst()), kind: kind,
                    example: example ?? self.example)
    }
}

// MARK: - Champs communs

public extension SearchField {
    static let ip = SearchField("ip", label: "IP", aliases: ["adresse", "address", "addr"], kind: .ip, example: "10.182.122.")
    static let mac = SearchField("mac", label: "MAC", aliases: ["bssid"], kind: .mac, example: "94dd.f818")
    static let name = SearchField("nom", label: "Nom", aliases: ["name", "host", "hostname", "hote"], example: "brother")
    static let type = SearchField("type", label: "Type", aliases: ["kind", "genre"], example: "imprimante")
    static let vendor = SearchField("fab", label: "Fabricant", aliases: ["fabricant", "vendor", "marque", "brand"], example: "Brother")
    static let switchName = SearchField("switch", label: "Switch", aliases: ["sw", "commutateur"], example: "SW-ETG2")
    static let port = SearchField("port", label: "Port", aliases: ["interface", "if"], kind: .number, example: "14")
    static let vlan = SearchField("vlan", label: "VLAN", kind: .number, example: "30")
    static let site = SearchField("site", label: "Site", aliases: ["fortigate", "fgt"], example: "Montréal")
    static let ssid = SearchField("ssid", label: "SSID", aliases: ["reseau", "network", "wifi"], example: "Bureau")
    static let accessPoint = SearchField("borne", label: "Borne", aliases: ["ap", "fortiap"], example: "FAP-ETG2")
    static let status = SearchField("etat", label: "État", aliases: ["statut", "status", "state"], example: "hors ligne")
    static let openPort = SearchField("tcp", label: "Port ouvert", aliases: ["ouvert", "service", "open"], kind: .number, example: "9100")
    static let note = SearchField("note", label: "Note", aliases: ["notes", "remarque"], example: "accueil")
    static let range = SearchField("plage", label: "Plage", aliases: ["range"], example: "Bureau")
    static let tag = SearchField("tag", label: "Étiquette", aliases: ["etiquette", "label"], example: "critique")
    static let location = SearchField("local", label: "Local", aliases: ["lieu", "emplacement", "location", "salle"], example: "204")
    static let wallJack = SearchField("prise", label: "Prise", aliases: ["jack"], example: "P2-14")
    static let owner = SearchField("resp", label: "Responsable", aliases: ["responsable", "owner", "proprio"], example: "Dany")
    static let asset = SearchField("actif", label: "N° d’actif", aliases: ["asset", "inventaire"], example: "INV-00412")
    static let severity = SearchField("gravite", label: "Gravité", aliases: ["severity", "niveau", "level"], example: "critique")
    static let target = SearchField("cible", label: "Cible", aliases: ["target"], example: "10.182.122.1")
    static let proto = SearchField("proto", label: "Protocole", aliases: ["protocole", "protocol"], example: "ssh")
    static let user = SearchField("user", label: "Utilisateur", aliases: ["utilisateur", "util", "login"], example: "admin")
    static let folder = SearchField("dossier", label: "Dossier", aliases: ["folder", "groupe", "group"], example: "Serveurs")
    static let poe = SearchField("poe", label: "PoE", example: "actif")
    static let speed = SearchField("vitesse", label: "Vitesse", aliases: ["speed", "debit"], example: "1 Gbit/s")
    static let source = SearchField("source", label: "Source", aliases: ["src"], example: "FDB")
    static let model = SearchField("modele", label: "Modèle", aliases: ["model"], example: "FS-148F")
    static let message = SearchField("message", label: "Message", aliases: ["msg", "titre", "title"], example: "hors ligne")
    static let city = SearchField("ville", label: "Ville", aliases: ["city"], example: "Montréal")
    static let country = SearchField("pays", label: "Pays", aliases: ["country"], example: "Canada")
    static let sponsor = SearchField("operateur", label: "Opérateur", aliases: ["fai", "isp", "sponsor"], example: "Bell")
    static let channel = SearchField("canal", label: "Canal", aliases: ["channel", "ch"], kind: .number, example: "36")
    static let band = SearchField("bande", label: "Bande", aliases: ["band"], example: "5 GHz")
    static let security = SearchField("securite", label: "Sécurité", aliases: ["security", "secu"], example: "WPA3")
    static let section = SearchField("section", label: "Section", aliases: ["rubrique"], example: "Alertes")
}

/// Champs d'un module (Scanner, Inventaire…), avec la recherche de leurs préfixes.
public struct SearchSchema: Sendable {
    public let fields: [SearchField]
    /// Requête d'exemple affichée dans le menu des préfixes : « switch:SW-ETG2 type:imprimante ».
    public let example: String
    private let byAlias: [String: SearchField]

    public init(_ fields: [SearchField], example: String? = nil) {
        self.fields = fields
        self.example = example ?? fields.prefix(2).map(\.sample).joined(separator: " ")
        var map: [String: SearchField] = [:]
        for field in fields {
            for alias in field.aliases where map[SearchText.fold(alias)] == nil { map[SearchText.fold(alias)] = field }
        }
        byAlias = map
    }

    /// Champ désigné par un préfixe (« sw », « Fabricant », « état »…), nil s'il est inconnu ici.
    public func field(forPrefix prefix: String) -> SearchField? {
        byAlias[SearchText.fold(prefix)]
    }

    public func field(_ key: String) -> SearchField? {
        fields.first { $0.key == key }
    }

    /// Schéma sans champ : tout est du texte (les deux-points compris).
    public static let textOnly = SearchSchema([], example: "")
}

/// Normalisation commune des textes comparés.
public enum SearchText {
    /// Minuscules, sans accents ni largeur, apostrophe typographique ramenée à l'apostrophe droite.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
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
