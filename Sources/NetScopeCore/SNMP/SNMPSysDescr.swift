import Foundation

// Note 60 : modèle, version du logiciel et parfois numéro de série tirés de sysDescr, quand
// ENTITY-MIB manque (imprimantes, NAS, petits switchs). Rien ici n'accède au réseau.

/// Ce que sysDescr dit du matériel ; chaque champ est nil s'il n'y figure pas sûrement.
public struct SNMPSysDescrInfo: Hashable, Sendable {
    public var vendor: String?
    public var model: String?
    /// Version du logiciel (firmware) : « 17.9.4a », « WC.16.11.0012 », « v7.2.5 build0453 ».
    public var version: String?
    public var serial: String?

    public init(vendor: String? = nil, model: String? = nil, version: String? = nil, serial: String? = nil) {
        self.vendor = vendor
        self.model = model
        self.version = version
        self.serial = serial
    }

    public var isEmpty: Bool { model == nil && version == nil && serial == nil }
}

/// Lecture de sysDescr par familles connues (FortiGate, FortiSwitch, Cisco IOS et IOS-XE, NX-OS,
/// HPE/Aruba, Juniper, Ubiquiti, MikroTik, imprimantes HP et Brother, Synology). Une famille
/// inconnue ne donne que la version écrite après « Version » ou « Firmware ».
public enum SNMPSysDescr {
    public static func parse(_ descr: String, objectID: String? = nil) -> SNMPSysDescrInfo {
        let text = descr.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return SNMPSysDescrInfo() }
        let brand = SNMPSystemInfo(name: "", descr: text, objectID: objectID).brand
        let parsers: [(String) -> SNMPSysDescrInfo?] = [hpPrinter, brother, fortinet, cisco, aruba, juniper, mikrotik,
                                                        synology, ubiquiti]
        for parser in parsers {
            if var info = parser(text) {
                if info.vendor == nil { info.vendor = brand }
                return info
            }
        }
        return SNMPSysDescrInfo(vendor: brand, model: nil, version: genericVersion(text))
    }

    // MARK: Familles

    /// « HP ETHERNET MULTI-ENVIRONMENT,SN:VNB3R12345,FN:4T2K0AB,SVCID:31254,PID:HP LaserJet Pro M404dn »
    /// « HP ETHERNET MULTI-ENVIRONMENT,ROM none,JETDIRECT,JD153,EEPROM JSI23900012,CIDATE 06/17/2019 »
    static func hpPrinter(_ text: String) -> SNMPSysDescrInfo? {
        let upper = text.uppercased()
        guard upper.hasPrefix("HP ETHERNET") || upper.contains("JETDIRECT") else { return nil }
        var info = SNMPSysDescrInfo(vendor: "HP")
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let lower = part.lowercased()
            if lower.hasPrefix("pid:") { info.model = clean(String(part.dropFirst(4))) }
            if lower.hasPrefix("sn:") { info.serial = clean(String(part.dropFirst(3))) }
            if lower.hasPrefix("eeprom ") { info.version = clean(String(part.dropFirst(7))) }
            if lower.hasPrefix("fw:") { info.version = clean(String(part.dropFirst(3))) }
        }
        return info
    }

    /// « Brother NC-8300w, Firmware Ver.1.07  ,MID 8C5-K9F,FID 2 » : NC-… est la carte réseau, pas
    /// le modèle de l'imprimante (il n'est donc pas repris).
    static func brother(_ text: String) -> SNMPSysDescrInfo? {
        guard text.lowercased().hasPrefix("brother") else { return nil }
        let version = capture(#"(?i)firmware\s+ver\.?\s*([0-9A-Za-z.]+)"#, in: text)
        return SNMPSysDescrInfo(vendor: "Brother", model: nil, version: version)
    }

    /// « FortiGate-60F », « FortiSwitch-248E-POE v7.2.5,build0453,230920 (GA) ».
    static func fortinet(_ text: String) -> SNMPSysDescrInfo? {
        guard let model = capture(#"\b(Forti(?:Gate|WiFi|Switch|AP|Analyzer|Manager|Mail|Web)(?:-[A-Za-z0-9]+)+)"#, in: text) else {
            return nil
        }
        var version: String?
        if let number = capture(#"\bv(\d+\.\d+\.\d+)"#, in: text) {
            version = "v" + number
            if let build = capture(#"(?i)build\s*(\d{3,5})"#, in: text) { version! += " build" + build }
        }
        return SNMPSysDescrInfo(vendor: "Fortinet", model: model, version: version)
    }

    /// Plateformes Cisco (code de l'image) en clair.
    static let ciscoPlatforms: [String: String] = [
        "CAT9K": "Catalyst 9000", "CAT9K_LITE": "Catalyst 9200", "CAT3K_CAA": "Catalyst 3850/3650",
        "CAT4500E": "Catalyst 4500-E", "C2960X": "Catalyst 2960-X", "C2960L": "Catalyst 2960-L",
        "C2960": "Catalyst 2960", "C2960S": "Catalyst 2960-S", "C3560CX": "Catalyst 3560-CX",
        "C3750E": "Catalyst 3750-E", "C3750": "Catalyst 3750", "C1000": "Catalyst 1000",
        "N9000": "Nexus 9000", "N3000": "Nexus 3000", "N5000": "Nexus 5000", "N7000": "Nexus 7000",
        "X86_64_LINUX_IOSD": "ISR 4000", "C800": "ISR 800", "C1100": "ISR 1100",
    ]

    /// « Cisco IOS Software, C2960X Software (C2960X-UNIVERSALK9-M), Version 15.2(7)E2, RELEASE… »
    /// « Cisco IOS Software [Amsterdam], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.3.4, … »
    /// « Cisco NX-OS(tm) n9000, Software (n9000-dk9), Version 9.3(8), RELEASE SOFTWARE »
    static func cisco(_ text: String) -> SNMPSysDescrInfo? {
        let lower = text.lowercased()
        guard lower.contains("cisco ios") || lower.contains("ios-xe") || lower.contains("cisco nx-os") else { return nil }
        let version = capture(#"Version\s+([0-9][0-9A-Za-z.()\-]*[0-9A-Za-z)])"#, in: text)
        var model: String?
        if let image = capture(#"\(([A-Za-z0-9_]+)(?:-[A-Za-z0-9]+)*\),\s*Version"#, in: text) {
            var platform = image.uppercased()
            for suffix in ["_IOSXE", "-UNIVERSALK9", "-UNIVERSAL"] where platform.hasSuffix(suffix) {
                platform = String(platform.dropLast(suffix.count))
            }
            model = ciscoPlatforms[platform] ?? platform
        }
        return SNMPSysDescrInfo(vendor: "Cisco", model: model, version: version)
    }

    /// « Aruba JL259A 2930F-24G-4SFP Switch, revision WC.16.11.0012, ROM WC.16.01.0009 (/ws/…) »
    /// « ProCurve J9280A Switch 2510G-48, revision Y.11.16, ROM N.10.02, (/sw/code/…) »
    /// « Aruba JL658A 6300M 24SFP+ 4SFP56 Swch FL.10.08.1010 » (AOS-CX)
    static func aruba(_ text: String) -> SNMPSysDescrInfo? {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        guard let range = first.range(of: #"^(?:HP ProCurve |HPE |HP |Hewlett Packard Enterprise |Aruba |ProCurve )"#,
                                      options: .regularExpression) else { return nil }
        let head = String(first[range]).trimmingCharacters(in: .whitespaces)
        let vendor = head.lowercased().contains("aruba") ? "Aruba" : "HPE"
        let rest = String(first[range.upperBound...])
        if let revision = rest.range(of: #",\s*revision\s+"#, options: .regularExpression) {
            let model = String(rest[..<revision.lowerBound])
            let version = capture(#"^([A-Z]{1,3}\.[0-9A-Za-z.]+)"#, in: String(rest[revision.upperBound...]))
            return SNMPSysDescrInfo(vendor: vendor, model: switchModel(model), version: version)
        }
        if let cx = rest.range(of: #"\s+(?:Swch\s+)?[A-Z]{2}\.\d{2}\.\d{2}\.\d{4}\s*$"#, options: .regularExpression) {
            let version = capture(#"([A-Z]{2}\.\d{2}\.\d{2}\.\d{4})\s*$"#, in: rest)
            return SNMPSysDescrInfo(vendor: vendor, model: switchModel(String(rest[..<cx.lowerBound])), version: version)
        }
        return nil
    }

    /// « Juniper Networks, Inc. ex2300-24p Ethernet Switch, kernel JUNOS 20.4R3-S2.6, Build date: … »
    static func juniper(_ text: String) -> SNMPSysDescrInfo? {
        guard text.lowercased().hasPrefix("juniper networks") else { return nil }
        let model = capture(#"Inc\.\s+([A-Za-z0-9\-]+)"#, in: text)?.uppercased()
        let version = capture(#"JUNOS\s+([0-9][0-9A-Za-z.\-]*[0-9A-Za-z])"#, in: text)
        return SNMPSysDescrInfo(vendor: "Juniper", model: model, version: version)
    }

    /// « RouterOS CRS326-24G-2S+ » (la version est dans une MIB propre à MikroTik).
    static func mikrotik(_ text: String) -> SNMPSysDescrInfo? {
        guard text.hasPrefix("RouterOS") else { return nil }
        let tokens = text.split(separator: " ").map(String.init).dropFirst()
        let version = tokens.first { $0.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil }
        let model = tokens.first { $0 != version }
        return SNMPSysDescrInfo(vendor: "MikroTik", model: model.flatMap(clean), version: version)
    }

    /// « Linux DS920plus 4.4.180+ #42962 SMP … » : le nom de la machine est le modèle ; la version du
    /// noyau n'est pas celle de DSM (elle n'est donc pas reprise).
    static func synology(_ text: String) -> SNMPSysDescrInfo? {
        guard let token = capture(#"^Linux\s+((?:DS|RS|DVA|FS|SA|NVR|RX|HD)\d{3,4}[A-Za-z+]*)\b"#, in: text) else { return nil }
        let model = token.replacingOccurrences(of: "plus", with: "+").replacingOccurrences(of: "Plus", with: "+")
        return SNMPSysDescrInfo(vendor: "Synology", model: model, version: nil)
    }

    /// « USW-24-PoE, 6.5.59.14777, Linux 3.6.5 », « EdgeSwitch 24-Port 250W, 1.9.3.5236436, Linux 3.6.5, … »
    static func ubiquiti(_ text: String) -> SNMPSysDescrInfo? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2,
              parts[0].range(of: #"^(?:USW|US-|US8|US16|US24|US48|UAP|U6|U7|UDM|USG|UXG|UCG|EdgeSwitch|EdgeRouter|ER-|EP-)"#,
                             options: .regularExpression) != nil,
              parts[1].range(of: #"^v?\d+\.\d+\.\d+"#, options: .regularExpression) != nil else { return nil }
        return SNMPSysDescrInfo(vendor: "Ubiquiti", model: parts[0], version: parts[1])
    }

    /// Autres : « … Version 2.4.1 … », « Firmware: 3.10 », « FW 1.2.3 ».
    static func genericVersion(_ text: String) -> String? {
        capture(#"(?i)\b(?:version|firmware(?:\s+version)?|fw)\s*[:.]?\s*v?(\d+(?:\.\d+)+[0-9A-Za-z.()\-]*)"#, in: text)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,-")) }
    }

    // MARK: Outils

    /// « JL259A 2930F-24G-4SFP Switch » → « JL259A 2930F-24G-4SFP » ; « J9280A Switch 2510G-48 » → « J9280A 2510G-48 ».
    static func switchModel(_ text: String) -> String? {
        let words = text.split(separator: " ").filter { !["switch", "swch"].contains($0.lowercased()) }
        return clean(words.joined(separator: " "))
    }

    static func clean(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return clean(ns.substring(with: match.range(at: 1)))
    }
}
