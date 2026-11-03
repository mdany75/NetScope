import Foundation

/// Table des préfixes constructeurs (OUI, 24 bits) → fabricant.
///
/// La table intégrée est courte (préfixes courants en entreprise et à la maison) ; une base
/// complète pourra être chargée plus tard avec `init(entries:)`.
public struct OUIDatabase: Sendable {
    /// Libellé d'une adresse aléatoire (bit « administrée localement »).
    public static let randomizedLabel = "Adresse privée (aléatoire)"
    /// Libellé d'un préfixe absent de la table.
    public static let unknownLabel = "Inconnu"

    private let table: [UInt32: String]

    /// `entries` : préfixe (« 3c:22:fb », « 3C-22-FB » ou « 3C22FB ») → fabricant. Les préfixes illisibles sont ignorés.
    public init(entries: [String: String]) {
        var table: [UInt32: String] = [:]
        for (prefix, vendor) in entries {
            if let value = OUIDatabase.parsePrefix(prefix) { table[value] = vendor }
        }
        self.table = table
    }

    public static let builtIn = OUIDatabase(entries: OUIDatabase.builtInEntries)

    public var count: Int { table.count }

    /// Fabricant d'après le préfixe, ou nil.
    public func vendor(for mac: MACAddress) -> String? {
        table[mac.ouiValue]
    }

    /// Libellé à afficher : fabricant, « Adresse privée (aléatoire) » ou « Inconnu ».
    /// La table est consultée d'abord : certaines machines virtuelles (QEMU) ont un préfixe local connu.
    public func label(for mac: MACAddress) -> String {
        if let vendor = vendor(for: mac) { return vendor }
        if mac.isRandomized { return OUIDatabase.randomizedLabel }
        return OUIDatabase.unknownLabel
    }

    static func parsePrefix(_ text: String) -> UInt32? {
        let digits = text.lowercased().filter { $0.isHexDigit }
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }

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
