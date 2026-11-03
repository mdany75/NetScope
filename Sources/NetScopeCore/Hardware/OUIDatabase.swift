import Foundation

/// Préfixes constructeurs (OUI) → fabricant.
///
/// `builtIn` charge, au premier usage, la base complète du registre IEEE (MA-L 24 bits, MA-M
/// 28 bits, MA-S 36 bits) depuis un fichier « HEX<TAB>Nom », dans cet ordre :
/// 1. `~/Library/Application Support/NetScope/oui.tsv` (base mise à jour depuis Réglages) ;
/// 2. `oui.tsv` dans les ressources de l'application installée ;
/// 3. en développement (`swift run`, `.build/debug`), `Resources/oui.tsv` du dépôt ;
/// 4. sinon, la petite table intégrée ci-dessous, seule.
///
/// La recherche prend le plus long préfixe connu : 36 bits, puis 28, puis 24. La petite table
/// intégrée prime sur l'IEEE pour les préfixes de 24 bits (noms courts). Les rares préfixes IEEE
/// au bit « administrée localement » sont ignorés : une adresse aléatoire reste « Adresse privée
/// (aléatoire) », sauf préfixe local connu de la petite table (QEMU).
///
/// Chargement paresseux et protégé par un verrou : utilisable depuis n'importe quel fil.
public final class OUIDatabase: @unchecked Sendable {
    /// Libellé d'une adresse aléatoire (bit « administrée localement »).
    public static let randomizedLabel = "Adresse privée (aléatoire)"
    /// Libellé d'un préfixe absent de la table.
    public static let unknownLabel = "Inconnu"

    /// Provenance de la base chargée.
    public struct Source: Sendable, Equatable, CustomStringConvertible {
        public enum Kind: Sendable, Equatable {
            /// Base mise à jour par l'utilisateur (Application Support).
            case user
            /// Ressource de l'application installée.
            case bundle
            /// `Resources/oui.tsv` du dépôt (développement).
            case repository
            /// Fichier choisi explicitement (`init(contentsOf:)`).
            case file
            /// Petite table intégrée seule.
            case builtIn
            /// Table fournie par le code (`init(entries:)`).
            case custom
        }

        public var kind: Kind
        /// Nombre de préfixes (IEEE et table intégrée réunis).
        public var count: Int
        /// Date de conversion du registre (« 2026-11-03 »), d'après l'en-tête du fichier.
        public var date: String?
        public var url: URL?

        /// « IEEE, 54 312 préfixes, 2026-11-03 » ou « Table intégrée, 230 préfixes ».
        public var description: String {
            let number = OUIDatabase.formatCount(count)
            switch kind {
            case .builtIn: return "Table intégrée, \(number) préfixes"
            case .custom: return "Table fournie, \(number) préfixes"
            default:
                if let date { return "IEEE, \(number) préfixes, \(date)" }
                return "IEEE, \(number) préfixes"
            }
        }

        /// Emplacement en clair (« base mise à jour », « base fournie avec l'application »…).
        public var place: String {
            switch kind {
            case .user: return "base mise à jour depuis l’IEEE"
            case .bundle: return "base fournie avec l’application"
            case .repository: return "base du dépôt (développement)"
            case .file: return "fichier choisi"
            case .builtIn: return "table intégrée seule"
            case .custom: return "table fournie"
            }
        }
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case empty(String)

        public var description: String {
            switch self {
            case .unreadable(let path): return "Base des fabricants illisible : \(path)"
            case .empty(let path): return "Base des fabricants vide : \(path)"
            }
        }
    }

    struct Tables {
        var t24: [UInt64: String] = [:]
        var t28: [UInt64: String] = [:]
        var t36: [UInt64: String] = [:]
        var source: Source
    }

    private let lock = NSLock()
    private var loaded: Tables?
    /// nil : table figée (`init(entries:)`, `init(contentsOf:)`) ; sinon, fichiers candidats.
    private let candidates: (@Sendable () -> [(URL, Source.Kind)])?

    /// `entries` : préfixe (« 3c:22:fb », « 3C-22-FB » ou « 3C22FB » ; 7 ou 9 chiffres pour
    /// MA-M et MA-S) → fabricant. Les préfixes illisibles sont ignorés.
    public init(entries: [String: String]) {
        var tables = Tables(source: Source(kind: .custom, count: 0))
        for (prefix, vendor) in entries {
            if let (digits, value) = OUIDatabase.parsePrefix(prefix) { tables.insert(digits: digits, value: value, name: vendor) }
        }
        tables.source.count = tables.count
        loaded = tables
        candidates = nil
    }

    /// Base lue dans un fichier TSV ; `overlayBuiltIn` : la petite table intégrée prime sur 24 bits.
    public init(contentsOf url: URL, overlayBuiltIn: Bool = true) throws {
        loaded = try OUIDatabase.load(url: url, kind: .file, overlayBuiltIn: overlayBuiltIn)
        candidates = nil
    }

    private init(candidates: @escaping @Sendable () -> [(URL, Source.Kind)]) {
        self.candidates = candidates
    }

    /// Base partagée, chargée au premier usage (voir l'ordre des sources plus haut).
    public static let builtIn = OUIDatabase(candidates: { OUIDatabase.defaultCandidates() })

    /// Nombre de préfixes connus.
    public var count: Int { tables.source.count }

    /// Provenance de la base (charge la base si ce n'est pas encore fait).
    public var source: Source { tables.source }

    /// Relit la base depuis les sources (après une mise à jour, par exemple) ; renvoie la provenance.
    @discardableResult
    public func reload() -> Source {
        guard candidates != nil else { return source }
        lock.lock()
        defer { lock.unlock() }
        let tables = resolve()
        loaded = tables
        return tables.source
    }

    /// Fabricant d'après le plus long préfixe connu, ou nil.
    public func vendor(for mac: MACAddress) -> String? {
        let tables = self.tables
        if let name = tables.t36[mac.value >> 12] { return name }
        if let name = tables.t28[mac.value >> 20] { return name }
        return tables.t24[mac.value >> 24]
    }

    /// Libellé à afficher : fabricant, « Adresse privée (aléatoire) » ou « Inconnu ».
    /// La table est consultée d'abord : certaines machines virtuelles (QEMU) ont un préfixe local connu.
    public func label(for mac: MACAddress) -> String {
        if let vendor = vendor(for: mac) { return vendor }
        if mac.isRandomized { return OUIDatabase.randomizedLabel }
        return OUIDatabase.unknownLabel
    }

    // MARK: Chargement

    private var tables: Tables {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let tables = resolve()
        loaded = tables
        return tables
    }

    /// Premier fichier lisible parmi les candidats, sinon la petite table. Appelé sous le verrou.
    private func resolve() -> Tables {
        for (url, kind) in candidates?() ?? [] {
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            if let tables = try? OUIDatabase.load(url: url, kind: kind, overlayBuiltIn: true) { return tables }
        }
        var tables = Tables(source: Source(kind: .builtIn, count: 0))
        for (value, name) in OUIDatabase.smallTable { tables.t24[value] = name }
        tables.source.count = tables.count
        return tables
    }

    /// Base mise à jour par l'utilisateur : `~/Library/Application Support/NetScope/oui.tsv`.
    public static var userFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("oui.tsv")
    }

    /// `Resources/oui.tsv` du dépôt, d'après l'emplacement de ce fichier source.
    public static var repositoryFileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Hardware
            .deletingLastPathComponent() // NetScopeCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // dépôt
            .appendingPathComponent("Resources/oui.tsv")
    }

    static func defaultCandidates() -> [(URL, Source.Kind)] {
        var list: [(URL, Source.Kind)] = [(userFileURL, .user)]
        if let bundled = Bundle.main.url(forResource: "oui", withExtension: "tsv") { list.append((bundled, .bundle)) }
        list.append((repositoryFileURL, .repository))
        return list
    }

    /// Lit un fichier « HEX<TAB>Nom » (lignes « # » : commentaires ; la date vient de l'en-tête).
    static func load(url: URL, kind: Source.Kind, overlayBuiltIn: Bool) throws -> Tables {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw LoadError.unreadable(url.path) }
        var tables = try parse(data, kind: kind, path: url.path)
        tables.source.url = url
        if overlayBuiltIn {
            for (value, name) in smallTable { tables.t24[value] = name }
            tables.source.count = tables.count
        }
        return tables
    }

    /// Analyse rapide, octet par octet (~54 000 lignes).
    static func parse(_ data: Data, kind: Source.Kind, path: String) throws -> Tables {
        var tables = Tables(source: Source(kind: kind, count: 0))
        tables.t24.reserveCapacity(40_000)
        tables.t28.reserveCapacity(8_000)
        tables.t36.reserveCapacity(8_000)
        var names: [String: String] = [:]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var index = 0
            while index < count {
                var lineEnd = index
                while lineEnd < count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
                var end = lineEnd
                if end > index, bytes[end - 1] == 0x0D { end -= 1 }
                defer { index = lineEnd + 1 }
                guard end > index else { continue }
                if bytes[index] == 0x23 { // « # »
                    if tables.source.date == nil, end - index >= 10 {
                        let tail = String(decoding: UnsafeBufferPointer(rebasing: bytes[(end - 10)..<end]), as: UTF8.self)
                        if OUIDatabase.isISODay(tail) { tables.source.date = tail }
                    }
                    continue
                }
                var value: UInt64 = 0
                var digits = 0
                var cursor = index
                var valid = true
                while cursor < end, bytes[cursor] != 0x09 {
                    let byte = bytes[cursor]
                    let nibble: UInt64
                    switch byte {
                    case 0x30...0x39: nibble = UInt64(byte - 0x30)
                    case 0x41...0x46: nibble = UInt64(byte - 0x41 + 10)
                    case 0x61...0x66: nibble = UInt64(byte - 0x61 + 10)
                    default: nibble = 0; valid = false
                    }
                    value = value << 4 | nibble
                    digits += 1
                    cursor += 1
                }
                guard valid, cursor < end, cursor + 1 < end, [6, 7, 9].contains(digits) else { continue }
                // Quelques très vieux préfixes IEEE ont le bit « administrée localement » : ignorés,
                // pour qu'une adresse aléatoire reste « Adresse privée (aléatoire) ».
                if (value >> UInt64(4 * digits - 8)) & 0x02 != 0 { continue }
                let nameBytes = UnsafeBufferPointer(rebasing: bytes[(cursor + 1)..<end])
                let decoded = String(decoding: nameBytes, as: UTF8.self)
                // Un même nom (« Apple », « Huawei ») est partagé par des centaines de préfixes.
                let name: String
                if let known = names[decoded] { name = known } else { names[decoded] = decoded; name = decoded }
                tables.insert(digits: digits, value: value, name: name)
            }
        }
        tables.source.count = tables.count
        guard tables.count > 0 else { throw LoadError.empty(path) }
        return tables
    }

    static func isISODay(_ text: String) -> Bool {
        let chars = Array(text.utf8)
        guard chars.count == 10, chars[4] == 0x2D, chars[7] == 0x2D else { return false }
        return chars.enumerated().allSatisfy { $0.offset == 4 || $0.offset == 7 || (0x30...0x39).contains($0.element) }
    }

    /// « 54 312 » (espace fine insécable entre les milliers).
    static func formatCount(_ count: Int) -> String {
        var digits = Array(String(count))
        var index = digits.count - 3
        while index > 0 {
            digits.insert("\u{202F}", at: index)
            index -= 3
        }
        return String(digits)
    }

    /// Préfixe de 6, 7 ou 9 chiffres hexadécimaux (séparateurs ignorés) → (chiffres, valeur).
    static func parsePrefix(_ text: String) -> (Int, UInt64)? {
        let digits = text.lowercased().filter { $0.isHexDigit && $0.isASCII }
        guard [6, 7, 9].contains(digits.count), let value = UInt64(digits, radix: 16) else { return nil }
        return (digits.count, value)
    }

    /// Petite table intégrée, sur 24 bits.
    static let smallTable: [UInt64: String] = {
        var table: [UInt64: String] = [:]
        for (prefix, vendor) in builtInEntries {
            if let (digits, value) = parsePrefix(prefix), digits == 6 { table[value] = vendor }
        }
        return table
    }()

    /// Préfixes courants, regroupés par fabricant.
    static let builtInGroups: [(String, [String])] = [
        ("Apple", ["00:03:93", "00:0a:95", "00:1b:63", "00:1e:c2", "00:25:00", "3c:22:fb", "a4:83:e7",
                   "f0:18:98", "ac:bc:32", "8c:85:90", "d0:81:7a", "14:7d:da", "bc:d0:74", "f4:5c:89",
                   "78:7b:8a", "88:66:5a", "3c:06:30", "60:f8:1d", "98:01:a7", "a8:5c:2c"]),
        ("Dell", ["00:14:22", "00:1e:c9", "18:03:73", "b0:83:fe", "f8:b1:56", "d4:be:d9", "14:18:77",
                  "54:bf:64", "98:90:96", "b8:ca:3a", "18:66:da", "f4:8e:38", "b0:7b:25", "a4:bb:6d", "8c:ec:4b"]),
        ("Lenovo", ["8c:16:45", "54:ee:75", "98:fa:9b", "28:d2:44", "50:7b:9d", "e8:6a:64", "c8:5b:76"]),
        ("HP", ["00:1b:78", "00:21:5a", "3c:d9:2b", "10:60:4b", "9c:8e:99", "a0:d3:c1", "70:5a:0f",
                "fc:15:b4", "30:e1:71", "94:57:a5", "ec:b1:d7", "64:51:06"]),
        ("Brother", ["00:1b:a9", "00:80:77", "30:05:5c", "3c:2a:f4", "94:dd:f8"]),
        ("Fortinet", ["00:09:0f", "04:d5:90", "70:4c:a5", "90:6c:ac", "e8:1c:ba", "08:5b:0e"]),
        ("Cisco", ["00:00:0c", "00:1b:54", "00:26:0b", "70:0f:6a", "58:ac:78", "f8:72:ea", "00:1a:a1", "2c:31:24"]),
        ("Cisco Meraki", ["00:18:0a", "e0:55:3d", "0c:8d:db", "ac:17:c8"]),
        ("HPE Aruba", ["00:0b:86", "24:de:c6", "94:b4:0f", "88:3a:30", "20:4c:03", "d8:c7:c8", "6c:f3:7f",
                       "94:18:82", "98:f2:b3", "1c:98:ec"]),
        ("Ubiquiti", ["00:15:6d", "00:27:22", "04:18:d6", "24:a4:3c", "44:d9:e7", "68:72:51", "78:8a:20",
                      "80:2a:a8", "b4:fb:e4", "dc:9f:db", "f0:9f:c2", "fc:ec:da", "74:83:c2", "e0:63:da", "18:e8:29"]),
        ("TP-Link", ["50:c7:bf", "14:cc:20", "30:b5:c2", "98:da:c4", "c0:4a:00", "ec:08:6b", "60:e3:27",
                     "a4:2b:b0", "f4:f2:6d", "b0:4e:26"]),
        ("Hikvision", ["44:19:b6", "bc:ad:28", "c0:56:e3", "4c:bd:8f", "28:57:be", "54:c4:15", "a4:14:37"]),
        ("Dahua", ["3c:ef:8c", "90:02:a9", "e0:50:8b", "4c:11:bf", "38:af:29", "14:a7:8b"]),
        ("Axis", ["00:40:8c", "ac:cc:8e", "b8:a4:4f"]),
        ("Synology", ["00:11:32", "90:09:d0"]),
        ("QNAP", ["00:08:9b", "24:5e:be"]),
        ("Raspberry Pi", ["b8:27:eb", "dc:a6:32", "e4:5f:01", "28:cd:c1", "d8:3a:dd", "2c:cf:67"]),
        ("Samsung", ["00:16:32", "00:1e:e2", "5c:0a:5b", "8c:77:12", "f0:25:b7", "34:23:ba", "94:35:0a",
                     "a0:82:1f", "c8:ba:94", "78:bd:bc"]),
        ("Intel", ["00:1b:21", "00:1e:67", "3c:a9:f4", "7c:7a:91", "a0:36:9f", "8c:8d:28", "f8:94:c2",
                   "48:51:b7", "00:15:17", "34:13:e8"]),
        ("Espressif", ["24:0a:c4", "30:ae:a4", "84:cc:a8", "a4:cf:12", "bc:dd:c2", "cc:50:e3", "ec:fa:bc",
                       "24:6f:28", "7c:9e:bd", "3c:61:05"]),
        ("Google", ["3c:5a:b4", "54:60:09", "f4:f5:d8", "f4:f5:e8", "1c:f2:9a", "48:d6:d5", "d8:6c:63", "20:df:b9"]),
        ("Amazon", ["0c:47:c9", "44:65:0d", "68:37:e9", "74:c2:46", "fc:65:de", "84:d6:d0", "a0:02:dc",
                    "34:d2:70", "40:b4:cd"]),
        ("Sonos", ["00:0e:58", "5c:aa:fd", "94:9f:3e", "b8:e9:37", "48:a6:b8", "34:7e:5c"]),
        ("BrightSign", ["90:ac:3f"]),
        ("Microsoft", ["00:03:ff", "28:18:78", "7c:1e:52", "60:45:bd", "98:5f:d3"]),
        ("Microsoft Hyper-V", ["00:15:5d"]),
        ("VMware", ["00:05:69", "00:0c:29", "00:1c:14", "00:50:56"]),
        ("Parallels", ["00:1c:42"]),
        ("VirtualBox", ["08:00:27"]),
        ("QEMU / KVM", ["52:54:00"]),
        ("MikroTik", ["4c:5e:0c", "64:d1:54", "b8:69:f4", "cc:2d:e0", "18:fd:74", "2c:c8:1b", "d4:ca:6d",
                      "48:8f:5a", "74:4d:28", "dc:2c:6e"]),
        ("Netgear", ["00:14:6c", "00:1e:2a", "20:4e:7f", "a0:40:a0", "c0:3f:0e", "9c:3d:cf"]),
        ("Xerox", ["00:00:aa", "9c:93:4e"]),
        ("Canon", ["00:1e:8f", "18:0c:ac"]),
        ("Epson", ["00:26:ab", "64:eb:8c"]),
        ("Yealink", ["80:5e:c0", "00:15:65"]),
        ("Poly", ["64:16:7f", "00:04:f2"]),
    ]

    static var builtInEntries: [String: String] {
        var entries: [String: String] = [:]
        for (vendor, prefixes) in builtInGroups {
            for prefix in prefixes { entries[prefix] = vendor }
        }
        return entries
    }
}

extension OUIDatabase.Tables {
    var count: Int { t24.count + t28.count + t36.count }

    mutating func insert(digits: Int, value: UInt64, name: String) {
        switch digits {
        case 6: t24[value] = name
        case 7: t28[value] = name
        case 9: t36[value] = name
        default: break
        }
    }
}
