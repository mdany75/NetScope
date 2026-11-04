import Foundation

/// Une ligne lue dans un CSV d'inventaire. Les champs vides ne modifient pas la fiche.
public struct InvCSVRow: Hashable, Sendable {
    public var ip: IPv4Address?
    public var mac: MACAddress?
    public var name: String?
    public var hostname: String?
    public var type: DeviceType?
    public var tags: [String]?
    public var location: String?
    public var wallJack: String?
    public var owner: String?
    public var assetNumber: String?
    public var notes: String?
    public var isFavorite: Bool?

    public init(ip: IPv4Address? = nil, mac: MACAddress? = nil, name: String? = nil, hostname: String? = nil,
                type: DeviceType? = nil, tags: [String]? = nil, location: String? = nil, wallJack: String? = nil,
                owner: String? = nil, assetNumber: String? = nil, notes: String? = nil, isFavorite: Bool? = nil) {
        self.ip = ip
        self.mac = mac
        self.name = name
        self.hostname = hostname
        self.type = type
        self.tags = tags
        self.location = location
        self.wallJack = wallJack
        self.owner = owner
        self.assetNumber = assetNumber
        self.notes = notes
        self.isFavorite = isFavorite
    }

    /// Champs saisis complétés par cette ligne.
    public func apply(to annotations: InvAnnotations) -> InvAnnotations {
        var result = annotations
        if let name { result.customName = name }
        if let type { result.customType = type }
        if let tags { result.tags = tags }
        if let location { result.location = location }
        if let wallJack { result.wallJack = wallJack }
        if let owner { result.owner = owner }
        if let assetNumber { result.assetNumber = assetNumber }
        if let notes { result.notes = notes }
        if let isFavorite { result.isFavorite = isFavorite }
        return result
    }
}

public enum InvCSVError: Error, Equatable, LocalizedError {
    case empty
    case missingColumns

    public var errorDescription: String? {
        switch self {
        case .empty: return "Le fichier est vide."
        case .missingColumns: return "Colonnes attendues : IP ou MAC, puis Nom, Type, Local, Prise, Responsable, N° d’actif…"
        }
    }
}

/// Lecture et écriture du CSV d'inventaire (séparateur « ; » par défaut, comme Excel en français).
public enum InvCSV {
    public static let columns = ["IP", "MAC", "Nom", "Hostname", "Type", "Fabricant", "Étiquettes", "Local",
                                 "Prise murale", "Responsable", "N° d’actif", "Notes", "Switch", "Port", "VLAN",
                                 "Première détection", "Dernière détection", "Statut", "Favori"]

    // MARK: Export

    /// `sites` (plusieurs sites affichés) : nom du site de chaque fiche, en première colonne « Site ».
    public static func export(_ records: [InvRecord], sites: [String]? = nil, separator: Character = ";", now: Date = Date()) -> String {
        let withSites = sites?.count == records.count
        var lines = [((withSites ? ["Site"] : []) + columns).map { quote($0, separator) }.joined(separator: String(separator))]
        for (index, record) in records.enumerated() {
            let a = record.annotations
            let fields = [
                record.ip.description, record.mac?.formatted(.upperColon) ?? "", a.customName ?? "",
                record.hostname ?? "", record.type.label, record.vendorLabel, a.tags.joined(separator: ", "),
                a.location, a.wallJack, a.owner, a.assetNumber, a.notes, record.switchName ?? "",
                record.switchPort ?? "", record.vlan.map(String.init) ?? "", InvFormat.stamp(record.firstSeen),
                InvFormat.stamp(record.lastSeen), record.status(now: now).label, a.isFavorite ? "oui" : "",
            ]
            let row = withSites ? [sites?[index] ?? ""] + fields : fields
            lines.append(row.map { quote($0, separator) }.joined(separator: String(separator)))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Caractères qui font lire une cellule comme une formule par Excel ou Numbers.
    static let formulaPrefixes: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// Protège un champ : guillemets si besoin, et apostrophe devant un texte qui serait pris pour une formule
    /// (un nom d'hôte annoncé sur le réseau comme « =HYPERLINK(…) » ne doit pas s'exécuter à l'ouverture).
    public static func quote(_ field: String, _ separator: Character = ";") -> String {
        var field = field
        if let first = field.first, formulaPrefixes.contains(first) { field = "'" + field }
        if field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// Retire l'apostrophe de protection ajoutée par `quote`.
    static func unprotect(_ text: String) -> String {
        guard text.hasPrefix("'"), let second = text.dropFirst().first, formulaPrefixes.contains(second) else { return text }
        return String(text.dropFirst())
    }

    // MARK: Import

    /// Découpe un texte CSV (guillemets RFC 4180) ; le séparateur est deviné sur la première ligne.
    public static func table(_ text: String) -> [[String]] {
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let candidates: [Character] = [";", ",", "\t"]
        let separator = candidates.max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ";"

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(body).makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let char = next() {
            if inQuotes {
                if char == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"" && field.isEmpty {
                inQuotes = true
            } else if char == separator {
                row.append(field)
                field = ""
            } else if char == "\n" || char == "\r\n" || char == "\r" {
                row.append(field)
                field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func normalize(_ header: String) -> String {
        header.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let headerMap: [String: String] = [
        "ip": "ip", "adresse ip": "ip", "ip actuelle": "ip",
        "mac": "mac", "adresse mac": "mac",
        "nom": "name", "nom personnalise": "name", "name": "name",
        "hostname": "hostname", "nom d'hote": "hostname",
        "type": "type",
        "etiquettes": "tags", "tags": "tags",
        "local": "location", "emplacement": "location",
        "prise": "jack", "prise murale": "jack",
        "responsable": "owner",
        "n° d'actif": "asset", "no d'actif": "asset", "numero d'actif": "asset", "actif": "asset",
        "notes": "notes",
        "favori": "favorite",
    ]

    /// Lignes d'inventaire ; lève une erreur si aucune colonne IP ni MAC n'est trouvée.
    public static func parse(_ text: String) throws -> [InvCSVRow] {
        let table = table(text)
        guard let header = table.first else { throw InvCSVError.empty }
        var index: [String: Int] = [:]
        for (position, title) in header.enumerated() {
            if let field = headerMap[normalize(title)], index[field] == nil { index[field] = position }
        }
        guard index["ip"] != nil || index["mac"] != nil else { throw InvCSVError.missingColumns }

        return table.dropFirst().compactMap { cells -> InvCSVRow? in
            func value(_ field: String) -> String? {
                guard let position = index[field], position < cells.count else { return nil }
                let text = unprotect(cells[position].trimmingCharacters(in: .whitespacesAndNewlines))
                return text.isEmpty ? nil : text
            }
            var row = InvCSVRow()
            row.ip = value("ip").flatMap(IPv4Address.init)
            row.mac = value("mac").flatMap(MACAddress.init)
            guard row.ip != nil || row.mac != nil else { return nil }
            row.name = value("name")
            row.hostname = value("hostname")
            row.type = value("type").flatMap(parseType)
            row.tags = value("tags").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            row.location = value("location")
            row.wallJack = value("jack")
            row.owner = value("owner")
            row.assetNumber = value("asset")
            row.notes = value("notes")
            row.isFavorite = value("favorite").map { ["oui", "yes", "1", "vrai", "true", "x"].contains(normalize($0)) }
            return row
        }
    }

    /// Type d'appareil à partir de son libellé (« Imprimante ») ou de son identifiant (« imprimante »).
    public static func parseType(_ text: String) -> DeviceType? {
        let wanted = normalize(text)
        if let type = DeviceType.allCases.first(where: { normalize($0.label) == wanted || normalize($0.rawValue) == wanted }) {
            return type
        }
        let synonyms: [String: DeviceType] = [
            "pare-feu": .routeur, "routeur": .routeur, "ordinateur": .poste, "ordinateur portable": .poste,
            "portable": .poste, "poste": .poste, "camera": .camera, "affichage numerique": .iot, "iot": .iot,
            "point d'acces": .pointAcces, "ap": .pointAcces, "telephone": .telephone,
        ]
        return synonyms[wanted]
    }
}
