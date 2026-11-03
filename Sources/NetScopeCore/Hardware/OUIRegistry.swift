import Foundation

/// Conversion du registre IEEE (fichiers CSV MA-L, MA-M, MA-S) en base « HEX<TAB>Nom ».
///
/// Les règles de nettoyage des noms sont écrites deux fois, ici et dans `scripts/make-oui.py` ;
/// les deux suivent la même liste d'exemples (`scripts/oui-name-examples.tsv`), vérifiée par
/// NetScopeSelfTest et par `python3 -I scripts/make-oui.py --self-test`. Toute modification se
/// fait des deux côtés.
public enum OUIRegistry {
    /// Un fichier du registre : nom, adresse de téléchargement, nombre de chiffres du préfixe.
    public struct File: Sendable, Hashable {
        public let name: String
        public let url: URL
        public let digits: Int
        /// Nombre minimal de préfixes attendus (registre tronqué ou page d'erreur sinon).
        public let minimumRows: Int
    }

    public static let files: [File] = [
        File(name: "oui.csv", url: URL(string: "https://standards-oui.ieee.org/oui/oui.csv")!, digits: 6, minimumRows: 20_000),
        File(name: "mam.csv", url: URL(string: "https://standards-oui.ieee.org/oui28/mam.csv")!, digits: 7, minimumRows: 1_000),
        File(name: "oui36.csv", url: URL(string: "https://standards-oui.ieee.org/oui36/oui36.csv")!, digits: 9, minimumRows: 1_000),
    ]

    public static let header = ["Registry", "Assignment", "Organization Name", "Organization Address"]

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unexpectedHeader(String)
        case tooFewRows(String, Int)

        public var description: String {
            switch self {
            case .unexpectedHeader(let file):
                return "\(file) ne ressemble pas au registre IEEE (en-tête inattendu)."
            case .tooFewRows(let file, let count):
                return "\(file) ne compte que \(count) préfixes : registre incomplet."
            }
        }
    }

    // MARK: Règles des noms (identiques à scripts/make-oui.py)

    /// Noms ignorés : blocs non attribués à un fabricant.
    static let ignored: Set<String> = ["private", "ieee registration authority"]

    /// Suffixes juridiques retirés en fin de nom (clé : minuscules, sans points ni virgules).
    static let legalSuffixes: Set<String> = [
        "inc", "incorporated", "corp", "corporation", "corporate", "co", "company", "ltd", "ltda",
        "limited", "llc", "lp", "llp", "plc", "gmbh", "mbh", "ag", "kg", "sa", "sas", "sarl", "spa",
        "srl", "sl", "slu", "bv", "nv", "oy", "oyj", "ab", "as", "aps", "asa", "pte", "pty", "kk",
        "sdn", "bhd", "cv", "de", "jsc", "ooo", "zao", "sro", "sp", "z", "o", "ou", "ulc", "pvt",
    ]
    static let gluedSuffixes: Set<String> = ["coltd", "colimited", "coinc", "cokg", "a/s", "ag&co", "oo"]

    /// Après l'un de ces suffixes, « Technology » est retiré aussi (« Technology Co., Ltd »).
    static let companyWords: Set<String> = ["co", "coltd", "colimited", "company", "corp", "corporation"]

    /// Après l'un de ces suffixes, « Private » est retiré aussi (« Private Limited », Inde).
    static let limitedWords: Set<String> = ["limited", "ltd"]

    /// Mots laissés seuls en fin de nom une fois les suffixes retirés.
    static let danglingWords: Set<String> = ["and", "&", "und", "et"]

    /// Mots dont la casse est imposée quand un nom tout en majuscules est remis en casse normale.
    static let fixedWords: [String: String] = [
        "hp": "HP", "hpe": "HPE", "ibm": "IBM", "lg": "LG", "nec": "NEC", "zte": "ZTE", "avm": "AVM",
        "tcl": "TCL", "nxp": "NXP", "byd": "BYD", "asus": "ASUS", "asustek": "ASUS", "d-link": "D-Link",
        "tp-link": "TP-Link", "usa": "USA", "uk": "UK", "it": "IT", "ip": "IP", "tv": "TV", "av": "AV",
        "ai": "AI", "iot": "IoT", "led": "LED", "rf": "RF", "gps": "GPS", "lte": "LTE", "pc": "PC",
        "ii": "II", "iii": "III", "iv": "IV", "3d": "3D", "oem": "OEM", "abb": "ABB", "jvc": "JVC",
        "bmw": "BMW", "rca": "RCA", "ntt": "NTT", "kddi": "KDDI", "sk": "SK", "kt": "KT",
    ]

    /// Mots courts écrits en minuscules au milieu d'un nom remis en casse normale.
    static let smallWords: Set<String> = ["and", "of", "the", "for", "de", "du", "des", "la", "le", "et", "und", "y", "a", "an"]

    /// Noms courts des grands fabricants (clé : nom nettoyé en minuscules).
    static let aliases: [String: String] = [
        "apple": "Apple",
        "cisco systems": "Cisco", "cisco": "Cisco", "cisco-linksys": "Linksys",
        "cisco meraki": "Cisco Meraki", "meraki": "Cisco Meraki",
        "dell": "Dell", "dell technologies": "Dell",
        "lenovo": "Lenovo", "lenovo mobile communication technology": "Lenovo",
        "motorola mobility llc, a lenovo": "Motorola", "lcfc(hefei) electronics": "Lenovo",
        "hewlett packard": "HP", "hewlett-packard company": "HP", "hewlett-packard": "HP",
        "hp": "HP", "hp inc": "HP",
        "hewlett packard enterprise": "HPE", "aruba, a hewlett packard enterprise company": "HPE Aruba",
        "aruba networks": "HPE Aruba",
        "brother industries": "Brother", "fortinet": "Fortinet",
        "ubiquiti networks": "Ubiquiti", "ubiquiti": "Ubiquiti",
        "hangzhou hikvision digital": "Hikvision", "hikvision": "Hikvision",
        "zhejiang dahua": "Dahua", "zhejiang dahua technologyco": "Dahua", "zhejiang dahua technology": "Dahua",
        "dahua": "Dahua",
        "synology": "Synology", "qnap systems": "QNAP",
        "raspberry pi foundation": "Raspberry Pi", "raspberry pi trading": "Raspberry Pi",
        "raspberry pi (trading)": "Raspberry Pi",
        "samsung electronics": "Samsung", "samsung electro-mechanics(thailand)": "Samsung",
        "samsung electro mechanics": "Samsung",
        "intel corporate": "Intel", "intel": "Intel",
        "espressif": "Espressif", "espressif systems": "Espressif",
        "google": "Google", "nest labs": "Google Nest",
        "amazon technologies": "Amazon", "amazon.com services": "Amazon", "amazon": "Amazon",
        "sonos": "Sonos",
        "microsoft": "Microsoft", "microsoft mobile": "Microsoft",
        "vmware": "VMware",
        "xiaomi communications": "Xiaomi", "beijing xiaomi mobile software": "Xiaomi",
        "beijing xiaomi electronics": "Xiaomi", "xiaomi electronics": "Xiaomi",
        "huawei technologies": "Huawei", "huawei device": "Huawei", "huawei symantec": "Huawei",
        "zte": "ZTE", "tp-link technologies": "TP-Link", "tp-link": "TP-Link",
        "tp-link systems": "TP-Link", "tp-link corporation": "TP-Link",
        "asustek computer": "ASUS", "netgear": "Netgear", "mikrotikls": "MikroTik",
        "routerboard.com": "MikroTik",
        "xerox": "Xerox", "canon": "Canon", "seiko epson": "Epson",
        "yealink(xiamen) network": "Yealink", "yealink network": "Yealink",
        "polycom": "Poly", "axis communications": "Axis", "brightsign": "BrightSign",
        "parallels": "Parallels", "lg electronics": "LG", "lg electronics (mobile communications)": "LG",
        "lg innotek": "LG Innotek", "sony": "Sony", "sony interactive entertainment": "Sony",
        "nintendo": "Nintendo", "texas instruments": "Texas Instruments",
        "juniper networks": "Juniper", "extreme networks": "Extreme Networks",
        "ruckus wireless": "Ruckus", "guangdong oppo mobile telecommunications": "OPPO",
        "vivo mobile communication": "vivo", "honor device": "Honor",
        "hon hai precision ind": "Foxconn", "hon hai precision industry": "Foxconn",
        "d-link international": "D-Link", "d-link": "D-Link",
        "zyxel communications": "Zyxel", "eero": "eero", "avm audiovisuelles marketing und computersysteme": "AVM",
        "avm": "AVM", "roku": "Roku", "philips lighting bv": "Philips Hue", "signify netherlands": "Philips Hue",
        "nvidia": "NVIDIA", "realtek semiconductor": "Realtek", "liteon": "Lite-On",
        "murata manufacturing": "Murata", "azurewave": "AzureWave",
        "new h3c technologies": "H3C", "arcadyan": "Arcadyan", "sagemcom broadband": "Sagemcom",
        "ring": "Ring", "ecobee": "ecobee", "nokia": "Nokia", "nokia shanghai bell": "Nokia",
        "ricoh": "Ricoh", "kyocera": "Kyocera", "konica minolta": "Konica Minolta",
        "lexmark international": "Lexmark", "zebra technologies": "Zebra",
        "grandstream networks": "Grandstream", "mitel networks": "Mitel", "avaya": "Avaya",
        "palo alto networks": "Palo Alto Networks", "sonicwall": "SonicWall", "watchguard technologies": "WatchGuard",
        "super micro computer": "Supermicro", "american megatrends": "AMI",
    ]

    // Les règles travaillent sur les points de code Unicode, comme Python (« İ » minuscule donne
    // deux points de code, une lettre accentuée décomposée en donne deux aussi).
    private static let trailingJunk: Set<Unicode.Scalar> = [" ", ",", ".", ";", ":", "-", "&", "/"]
    private static let keyStrip: Set<Unicode.Scalar> = [",", ".", "(", ")"]
    private static let vowels: Set<Unicode.Scalar> = Set("aeiouyAEIOUY".unicodeScalars)

    /// `str.isalpha()` de Python pour un point de code (lettres : Lu, Ll, Lt, Lm, Lo).
    static func isAlpha(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// `str.isspace()` de Python pour un point de code.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    static func isLower(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isLowercase
    }

    /// Nom court lisible d'une organisation du registre, ou nil pour une ligne à ignorer
    /// (« Private », bloc de l'autorité d'enregistrement, nom vide).
    public static func cleanName(_ raw: String) -> String? {
        let text = splitWords(spaceAfterCommas(raw)).joined(separator: " ")
        if text.isEmpty || ignored.contains(text.lowercased()) { return nil }
        let original = stripTrailing(text)
        var words = text.isEmpty ? [] : text.components(separatedBy: " ")
        // Suffixes juridiques en fin de nom ; « Technology Co. » aussi.
        while words.count > 1 {
            let last = words[words.count - 1]
            if isSuffix(last) {
                let removed = key(last)
                words.removeLast()
                if companyWords.contains(removed), words.count > 1, key(words[words.count - 1]) == "technology" {
                    words.removeLast()
                } else if limitedWords.contains(removed), words.count > 1, key(words[words.count - 1]) == "private" {
                    words.removeLast()
                }
                continue
            }
            if danglingWords.contains(key(last)) {
                words.removeLast()
                continue
            }
            let stripped = stripTrailing(last)
            if stripped != last {
                if stripped.isEmpty { words.removeLast() } else { words[words.count - 1] = stripped }
                continue
            }
            break
        }
        var name = stripTrailing(words.filter { !$0.isEmpty }.joined(separator: " "))
        if name.isEmpty { name = original }
        if !name.unicodeScalars.contains(where: isLower), name.unicodeScalars.contains(where: isAlpha) {
            name = normalizeCase(name.components(separatedBy: " ")).joined(separator: " ")
        }
        return aliases[name.lowercased()] ?? name
    }

    /// `str.split()` de Python : mots séparés par des blancs, sans mot vide.
    static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                if !current.isEmpty { words.append(String(current)); current = String.UnicodeScalarView() }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// « Co.,Ltd » → « Co., Ltd » : une espace après une virgule suivie d'une lettre.
    static func spaceAfterCommas(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            out.append(scalar)
            if scalar == ",", index + 1 < scalars.count, isAlpha(scalars[index + 1]) { out.append(" ") }
        }
        return String(out)
    }

    /// Mot en minuscules sans points ni virgules (« Co.,Ltd. » → « coltd »).
    static func key(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in word.lowercased().unicodeScalars where scalar != "." && scalar != "," { out.append(scalar) }
        return String(out)
    }

    static func isSuffix(_ word: String) -> Bool {
        let key = key(word)
        if legalSuffixes.contains(key) || gluedSuffixes.contains(key) { return true }
        // Région entre parenthèses en fin de nom : « (Shenzhen) », « (Thailand) ».
        let scalars = word.unicodeScalars
        return scalars.count > 2 && scalars.first == "(" && scalars.last == ")"
    }

    static func stripTrailing(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, trailingJunk.contains(last) { scalars.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    /// Majuscule en début de mot (et après tout signe autre qu'un chiffre ou « ' »), minuscules ensuite.
    static func titleWord(_ word: String) -> String {
        var out = ""
        var previousAlnum = false
        for scalar in word.unicodeScalars {
            if isAlpha(scalar) {
                out += previousAlnum ? String(scalar).lowercased() : String(scalar).uppercased()
                previousAlnum = true
            } else {
                out.unicodeScalars.append(scalar)
                previousAlnum = ("0"..."9").contains(scalar) || scalar == "'"
            }
        }
        return out
    }

    static func normalizeCase(_ words: [String]) -> [String] {
        var result: [String] = []
        for (index, word) in words.enumerated() {
            let lowered = word.lowercased()
            var scalars = Array(lowered.unicodeScalars)
            while let first = scalars.first, keyStrip.contains(first) { scalars.removeFirst() }
            while let last = scalars.last, keyStrip.contains(last) { scalars.removeLast() }
            var keyView = String.UnicodeScalarView()
            keyView.append(contentsOf: scalars)
            let key = String(keyView)
            if let fixed = fixedWords[key] {
                if let range = lowered.range(of: key) {
                    result.append(lowered.replacingCharacters(in: range, with: fixed))
                } else {
                    result.append(lowered)
                }
            } else if index > 0, smallWords.contains(key) {
                result.append(lowered)
            } else if !scalars.isEmpty, scalars.count <= 3, scalars.allSatisfy(isAlpha), !scalars.contains(where: vowels.contains) {
                result.append(word) // sigle : « NXP », « BRK »
            } else {
                result.append(titleWord(word))
            }
        }
        return result
    }

    // MARK: CSV

    /// Lignes d'un fichier CSV (RFC 4180 : guillemets, « "" », retours à la ligne entre guillemets).
    public static func parseCSV(_ data: Data) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var index = data.startIndex
        let end = data.endIndex
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), lf = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
        func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }
        while index < end {
            let byte = data[index]
            index += 1
            if inQuotes {
                if byte == quote {
                    if index < end, data[index] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
                continue
            }
            switch byte {
            case quote where field.isEmpty:
                inQuotes = true
            case comma:
                endField()
            case cr:
                if index < end, data[index] == lf { index += 1 }
                endRow()
            case lf:
                endRow()
            default:
                field.append(byte)
            }
        }
        if !field.isEmpty || !row.isEmpty || inQuotes { endRow() }
        return rows
    }

    /// Préfixes (« HEX » en majuscules) → nom court d'un fichier du registre. Vérifie l'en-tête et,
    /// avec `minimumRows`, le nombre de préfixes.
    public static func entries(fromCSV data: Data, digits: Int, fileName: String, minimumRows: Int = 0) throws -> [(String, String)] {
        // Marque d'ordre des octets UTF-8 éventuelle (Python : « utf-8-sig »).
        let bom = Data([0xEF, 0xBB, 0xBF])
        let rows = parseCSV(data.starts(with: bom) ? data.dropFirst(3) : data)
        guard let first = rows.first,
              first.count >= 4,
              Array(first.prefix(4)).map({ $0.trimmingCharacters(in: .whitespaces) }) == header
        else { throw Failure.unexpectedHeader(fileName) }
        var result: [(String, String)] = []
        result.reserveCapacity(rows.count)
        for row in rows.dropFirst() where row.count >= 3 {
            let prefix = row[1].trimmingCharacters(in: .whitespaces).uppercased()
            guard prefix.count == digits, prefix.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { continue }
            if let name = cleanName(row[2]) { result.append((prefix, name)) }
        }
        if result.count < minimumRows { throw Failure.tooFewRows(fileName, result.count) }
        return result
    }

    /// Base TSV complète d'après les trois fichiers (`csv[file.name]`), triée, avec l'en-tête daté.
    public static func convert(_ csv: [String: Data], date: Date = Date()) throws -> (text: String, count: Int) {
        var table: [String: String] = [:]
        for file in files {
            guard let data = csv[file.name] else { throw Failure.unexpectedHeader(file.name) }
            for (prefix, name) in try entries(fromCSV: data, digits: file.digits, fileName: file.name, minimumRows: file.minimumRows) {
                table[prefix] = name
            }
        }
        var lines = ["# Registre IEEE MA-L/MA-M/MA-S, converti le \(isoDay(date))"]
        lines.reserveCapacity(table.count + 1)
        for prefix in table.keys.sorted() { lines.append("\(prefix)\t\(table[prefix]!)") }
        return (lines.joined(separator: "\n") + "\n", table.count)
    }

    static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
