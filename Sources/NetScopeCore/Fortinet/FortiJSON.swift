import Foundation

// Lecture tolérante des réponses JSON de l'API REST de FortiOS (6.4 à 7.6). Les noms des champs
// changent d'une version à l'autre (« switch-id », « switch_id », « switchId »), certaines réponses
// sont enveloppées ({ "results": … }) et d'autres non, des champs manquent : chaque lecture essaie
// plusieurs noms et accepte l'absence. Fonctions pures, sans réseau.

/// Un objet JSON (dictionnaire) lu avec des noms de champ normalisés : casse, « - », « _ » et
/// espaces ignorés.
public struct FortiObject: @unchecked Sendable {
    public let raw: [String: Any]
    private let normalized: [String: Any]

    public init(_ raw: [String: Any]) {
        self.raw = raw
        var map: [String: Any] = [:]
        for (key, value) in raw {
            let k = FortiJSON.normalize(key)
            if map[k] == nil { map[k] = value }
        }
        normalized = map
    }

    /// Première valeur non nulle parmi les noms donnés.
    public func value(_ names: [String]) -> Any? {
        for name in names {
            if let v = normalized[FortiJSON.normalize(name)], !(v is NSNull) { return v }
        }
        return nil
    }

    public func string(_ names: String...) -> String? { FortiJSON.string(value(names)) }
    public func int(_ names: String...) -> Int? { FortiJSON.int(value(names)) }
    public func double(_ names: String...) -> Double? { FortiJSON.double(value(names)) }
    public func bool(_ names: String...) -> Bool? { FortiJSON.bool(value(names)) }
    public func object(_ names: String...) -> FortiObject? {
        (value(names) as? [String: Any]).map(FortiObject.init)
    }
    public func list(_ names: String...) -> [FortiObject] { FortiJSON.objects(value(names)) }
    public func any(_ names: String...) -> Any? { value(names) }
}

public enum FortiJSON {
    /// « Switch-ID » → « switchid ».
    static func normalize(_ key: String) -> String {
        String(key.lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " })
    }

    /// Décode le corps ; nil s'il n'est pas du JSON.
    public static func parse(_ data: Data) -> Any? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Contenu utile : la valeur de « results » si la réponse est enveloppée, sinon la réponse.
    public static func results(_ json: Any?) -> Any? {
        if let dict = json as? [String: Any] {
            let object = FortiObject(dict)
            if let inner = object.value(["results", "result", "data"]) { return inner }
        }
        return json
    }

    /// Enveloppe de la réponse (champs de premier niveau : version, serial, build, vdom…).
    public static func envelope(_ json: Any?) -> FortiObject? {
        (json as? [String: Any]).map(FortiObject.init)
    }

    /// Liste d'objets : tableau d'objets, dictionnaire d'objets indexé par une clé (numéro de série,
    /// nom d'interface : la clé est ajoutée sous « _key »), ou objet seul.
    public static func objects(_ value: Any?) -> [FortiObject] {
        if let array = value as? [Any] {
            return array.compactMap { ($0 as? [String: Any]).map(FortiObject.init) }
        }
        if let dict = value as? [String: Any] {
            let children = dict.compactMapValues { $0 as? [String: Any] }
            // Dictionnaire indexé (toutes les valeurs sont des objets) ; sinon un objet seul.
            if !dict.isEmpty, children.count == dict.count {
                return children.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { key, child in
                    var copy = child
                    copy["_key"] = key
                    return FortiObject(copy)
                }
            }
            // Dictionnaire de listes (baux DHCP par interface, par exemple).
            let lists = dict.compactMapValues { $0 as? [Any] }
            if !dict.isEmpty, lists.count == dict.count {
                return lists.sorted { $0.key < $1.key }.flatMap { key, list in
                    list.compactMap { item -> FortiObject? in
                        guard var child = item as? [String: Any] else { return nil }
                        if child["_key"] == nil { child["_key"] = key }
                        return FortiObject(child)
                    }
                }
            }
            return [FortiObject(dict)]
        }
        return []
    }

    public static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case let n as NSNumber where !(value is Bool):
            return n.stringValue
        case let list as [Any]:
            // Champ « nom » sous forme de liste d'objets ([{ "name": "port1" }]) : premier nom.
            if let first = list.first as? [String: Any] {
                return FortiObject(first).string("name", "vlan-name", "interface-name")
            }
            return nil
        case let dict as [String: Any]:
            return FortiObject(dict).string("name", "value")
        default:
            return nil
        }
    }

    public static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber:
            let d = n.doubleValue
            guard d.isFinite, abs(d) < 9.0e18 else { return nil }
            return Int(d.rounded())
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            if let d = Double(t.replacingOccurrences(of: ",", with: ".")), d.isFinite, abs(d) < 9.0e18 { return Int(d.rounded()) }
            return nil
        default:
            return nil
        }
    }

    public static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            // « 4.5W », « 4,5 W » : le nombre au début.
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            let prefix = t.prefix { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(prefix).flatMap { $0.isFinite ? $0 : nil }
        default:
            return nil
        }
    }

    /// Booléen tolérant : true/false, 1/0, « enable »/« disable », « yes »/« no », « up »/« down ».
    public static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool:
            return b
        case let n as NSNumber:
            return n.intValue != 0
        case let s as String:
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "enable", "enabled", "on", "up": return true
            case "false", "0", "no", "disable", "disabled", "off", "down": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// Conversions propres aux valeurs de FortiOS.
public enum FortiParse {
    /// Vitesse d'un port, en Mb/s : 1000, « 1000 », « 1000full », « 1000auto », « 10G », « 100M »,
    /// « 2.5G » ; nil pour « auto » ou un port sans lien.
    public static func speedMbps(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber, !(value is Bool) {
            let d = n.doubleValue
            guard d > 0, d.isFinite else { return nil }
            // Valeur en b/s (certaines versions) : 1 000 000 000 → 1000.
            return plausibleSpeed(d >= 1_000_000 ? d / 1_000_000 : d)
        }
        guard let text = (value as? String)?.lowercased().trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let number = text.prefix { $0.isNumber || $0 == "." }
        guard let amount = Double(number), amount > 0 else { return nil }
        let rest = text.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("g") { return plausibleSpeed(amount * 1000) }
        return plausibleSpeed(amount)
    }

    /// Vitesse la plus haute acceptée (1 Tb/s) : au-delà, la valeur est aberrante.
    static let maxSpeedMbps: Double = 1_000_000

    /// Mb/s arrondis, nil pour une valeur aberrante (jamais de conversion qui s'arrête net).
    static func plausibleSpeed(_ value: Double) -> UInt64? {
        let rounded = value.rounded()
        guard rounded.isFinite, rounded > 0, rounded <= maxSpeedMbps else { return nil }
        return UInt64(exactly: rounded)
    }

    /// Duplex tiré de la vitesse (« 1000full ») ou d'un champ séparé.
    public static func duplex(_ speed: Any?, _ duplex: Any?) -> String? {
        if let d = FortiJSON.string(duplex)?.lowercased() {
            if d.contains("full") { return "full" }
            if d.contains("half") { return "half" }
        }
        if let s = (speed as? String)?.lowercased() {
            if s.contains("full") { return "full" }
            if s.contains("half") { return "half" }
        }
        return nil
    }

    /// Numéro du port : « port12 » → 12 ; « port1/12 » → 12 ; nil sans chiffre.
    /// Nom d'un port physique de FortiSwitch : « port7 », « port1.2 » (port éclaté) ; pas un trunk
    /// (« __FoRtI1LiNk0__ », « 8EF3X1234567890 »).
    public static func isPhysicalPortName(_ name: String) -> Bool {
        name.range(of: #"^port\d+(\.\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func portNumber(_ name: String) -> Int? {
        name.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
    }

    /// Identifiant de VLAN déduit d'un nom d'interface VLAN de FortiOS : « vlan40 » → 40,
    /// « _default » → 1, « quarantine » → 4093, « rspan » → 4092, « onboarding » → 4094 ;
    /// nil pour un nom libre (« voix-siege »).
    public static func vlanID(fromName name: String?) -> Int? {
        guard let raw = name?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let n = Int(raw), (1...4094).contains(n) { return n }
        let lower = raw.lowercased()
        let base = lower.split(separator: ".").first.map(String.init) ?? lower
        switch base {
        case "_default", "default": return 1
        case "quarantine": return 4093
        case "rspan": return 4092
        case "onboarding": return 4094
        default: break
        }
        for prefix in ["vlan", "vl", "v"] where base.hasPrefix(prefix) {
            if let n = Int(base.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))), (1...4094).contains(n) {
                return n
            }
        }
        return nil
    }

    /// Date de dernière vue : horodatage Unix (secondes ou millisecondes), ou nombre de secondes
    /// écoulées (petite valeur), ou texte ISO 8601.
    public static func lastSeen(_ value: Any?, now: Date) -> Date? {
        var number: Double?
        if let n = value as? NSNumber, !(value is Bool) { number = n.doubleValue }
        if let s = value as? String {
            if let d = Double(s.trimmingCharacters(in: .whitespaces)) {
                number = d
            } else {
                return ISO8601DateFormatter().date(from: s)
            }
        }
        guard let d = number, d.isFinite, d >= 0 else { return nil }
        if d > 1_000_000_000_000 { return Date(timeIntervalSince1970: d / 1000) }
        if d > 1_000_000_000 { return Date(timeIntervalSince1970: d) }
        return now.addingTimeInterval(-d)
    }

    /// Adresse MAC, quel que soit le format.
    public static func mac(_ value: Any?) -> MACAddress? {
        guard let text = FortiJSON.string(value), let mac = MACAddress(text), mac.value != 0, !mac.isBroadcast else { return nil }
        return mac
    }

    /// Adresse IPv4 (« 10.255.1.2 », « 10.255.1.2/24 »).
    public static func ipv4(_ value: Any?) -> IPv4Address? {
        guard let text = FortiJSON.string(value) else { return nil }
        let head = text.split(whereSeparator: { $0 == "/" || $0 == " " }).first.map(String.init) ?? text
        guard let ip = IPv4Address(head), ip.value != 0 else { return nil }
        return ip
    }

    /// Modèle lisible tiré du numéro de série d'un FortiSwitch : « S248EPTF18000001 » → « FS-248E-POE »,
    /// « S124FPTF… » → « FS-124F-POE », « S108FFTV… » → « FS-108F ». nil si le préfixe est illisible.
    public static func fortiSwitchModel(serial: String) -> String? {
        let chars = Array(serial.uppercased())
        guard chars.count >= 5, chars[0] == "S" else { return nil }
        let digits = String(chars[1...3])
        guard digits.allSatisfy(\.isNumber), chars[4].isLetter else { return nil }
        var model = "FS-\(digits)\(chars[4])"
        if chars.count > 5 {
            switch chars[5] {
            case "P": model += "-POE"
            case "F" where chars.count > 6 && chars[6] == "P": model += "-FPOE"
            default: break
            }
        }
        return model
    }
}
