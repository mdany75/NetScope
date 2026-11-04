import Foundation

// Note 30 : type « Téléphone IP » (postes de bureau Yealink, Poly, Cisco, Mitel…), distinct de
// « Téléphone » (cellulaires). Fonctions pures, sans réseau : le classement d'après le fabricant,
// le nom et les ports SIP, et les indices venus d'ailleurs (LLDP / LLDP-MED / CDP, VLAN voix).

/// Indices de téléphonie IP connus hors du scan lui-même.
public struct VoIPSignals: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Capacité « téléphone » annoncée par LLDP, LLDP-MED ou CDP (voisin d'un switch relevé, ou
    /// trame entendue par la capture).
    public static let announcedPhone = VoIPSignals(rawValue: 1 << 0)
    /// L'appareil est dans un VLAN voix connu.
    public static let voiceVLAN = VoIPSignals(rawValue: 1 << 1)

    /// « LLDP / CDP : téléphone · VLAN voix » pour la fiche.
    public var labels: [String] {
        var result: [String] = []
        if contains(.announcedPhone) { result.append("Annoncé téléphone par LLDP / CDP") }
        if contains(.voiceVLAN) { result.append("Dans le VLAN voix") }
        return result
    }
}

/// Règles de classement des téléphones IP, appelées par `ScanDeviceClassifier` avant la règle des
/// cellulaires.
public enum VoIPClassifier {
    /// Fabricants qui ne font (presque) que de la téléphonie : le fabricant suffit.
    static let dedicatedVendors: Set<String> = [
        "yealink", "polycom", "poly", "mitel", "aastra", "grandstream", "fanvil", "snom", "avaya", "gigaset",
        "htek", "obihai", "audiocodes", "spectralink",
    ]
    /// Fabricants qui font aussi autre chose (switchs, routeurs, imprimantes, téléviseurs, PC) : il
    /// faut en plus un indice VoIP.
    static let conditionalVendors: Set<String> = ["cisco", "panasonic", "alcatel-lucent", "unify", "siemens", "hp"]
    /// Cellulaires et tablettes : jamais des téléphones IP, même avec un softphone SIP ouvert.
    static let smartphoneVendors: Set<String> = [
        "apple", "samsung", "xiaomi", "huawei", "oneplus", "oppo", "vivo", "motorola", "google", "honor", "realme",
    ]
    static let smartphoneHints = ["android", "iphone", "ipad", "galaxy", "pixel", "redmi", "oneplus"]
    /// Postes de travail, serveurs et machines virtuelles : un softphone ou un IPBX n'en fait pas un téléphone.
    static let computerVendors: Set<String> = ["dell", "lenovo", "intel", "microsoft", "vmware", "asustek", "micro-star", "gigabyte"]
    /// Ports d'administration d'un équipement d'infrastructure (Cisco CUBE, IPBX, routeur avec SIP).
    static let infrastructurePorts: Set<UInt16> = [22, 23, 179, 541, 830, 8291]
    /// Ports d'un ordinateur (partage Windows, bureau à distance).
    static let computerPorts: Set<UInt16> = [135, 139, 445, 3389, 5900]
    static let sipPorts: Set<UInt16> = [5060, 5061]
    /// Mots de nom d'hôte des téléphones (noms par défaut des fabricants).
    static let hostWords = ["yealink", "polycom", "spip", "ssip", "vvx", "grandstream", "fanvil", "snom", "mitel",
                            "aastra", "obihai", "htek", "avaya", "gigaset", "audiocodes", "spectralink", "ipphone", "ip-phone",
                            "sipphone", "deskphone"]
    /// Débuts de nom d'équipements réseau des mêmes fabricants (borne Grandstream, passerelle AudioCodes…).
    static let infrastructureHostPrefixes = ["sw", "gwn", "mediant", "ers", "router", "rtr", "fw", "core", "switch",
                                             "fortiap", "fortigate", "fortiswitch", "fap", "fsw", "uap", "ap-"]
    /// Fabricants d'équipements réseau : jamais téléphone IP sur le seul port SIP ou VLAN voix.
    static let networkVendors: Set<String> = ["fortinet", "aruba", "juniper", "netgear", "tp-link", "d-link", "mikrotik",
                                              "ubiquiti", "meraki", "ruckus", "extreme", "hpe", "zyxel"]

    /// Vrai si le nom d'hôte est celui d'un téléphone IP : « SEP001B54A1B2C3 » (Cisco), « SIP-T54W »,
    /// « yealink-t46u », « VVX450 », « SPIP650 »…
    public static func hostLooksLikePhone(_ host: String) -> Bool {
        let host = host.lowercased()
        guard !host.isEmpty else { return false }
        if isCiscoPhoneName(host) { return true }
        if hostWords.contains(where: { host.contains($0) }) { return true }
        let tokens = host.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        if tokens.contains(where: isGrandstreamModel) { return true }
        // « SIP-T54W » : nom par défaut des Yealink (le modèle seul, « t46 », serait trop vague).
        return tokens.contains("sip") && tokens.contains(where: isYealinkModel)
    }

    /// « SEP » suivi des 12 chiffres hexadécimaux de la MAC : nom par défaut des téléphones Cisco.
    static func isCiscoPhoneName(_ host: String) -> Bool {
        let name = host.split(separator: ".").first.map(String.init) ?? host
        guard name.hasPrefix("sep"), name.count == 15 else { return false }
        return name.dropFirst(3).allSatisfy(\.isHexDigit)
    }

    /// « t46 », « t54w », « t33g » : modèle Yealink (T2x à T5x, deux chiffres, au plus deux lettres).
    /// Un « t480 » (ThinkPad) n'en est pas un.
    static func isYealinkModel(_ token: String) -> Bool {
        guard let first = token.dropFirst().first, "2345".contains(first) else { return false }
        return modelToken(token, prefix: "t", digits: 2...2)
    }

    /// « gxp2170 », « grp2614 », « gxv3350 » : modèles Grandstream.
    static func isGrandstreamModel(_ token: String) -> Bool {
        modelToken(token, prefix: "gxp", digits: 3...4) || modelToken(token, prefix: "grp", digits: 4...4)
            || modelToken(token, prefix: "gxv", digits: 4...4)
    }

    static func modelToken(_ token: String, prefix: String, digits range: ClosedRange<Int>) -> Bool {
        guard token.hasPrefix(prefix) else { return false }
        let rest = token.dropFirst(prefix.count)
        let digits = rest.prefix(while: \.isNumber)
        let suffix = rest.dropFirst(digits.count)
        return range.contains(digits.count) && suffix.count <= 2 && suffix.allSatisfy(\.isLetter)
    }

    /// Vrai si l'appareil est un cellulaire ou une tablette (veto absolu).
    static func isSmartphone(vendorWords: Set<String>, host: String, mac: MACAddress?, signals: VoIPSignals) -> Bool {
        if !vendorWords.isDisjoint(with: smartphoneVendors) { return true }
        if smartphoneHints.contains(where: { host.contains($0) }) { return true }
        // MAC aléatoire (adresse privée Wi-Fi) : un poste de bureau garde la MAC de son fabricant.
        if let mac, mac.isRandomized, !signals.contains(.announcedPhone) { return true }
        return false
    }

    /// Téléphone IP ? `vendorWords` : mots du fabricant en minuscules ; `host` : nom en minuscules.
    public static func isIPPhone(open: Set<UInt16>, vendorWords: Set<String>, vendor: String, host: String,
                                 mac: MACAddress?, signals: VoIPSignals) -> Bool {
        if isSmartphone(vendorWords: vendorWords, host: host, mac: mac, signals: signals) { return false }
        let infraName = infrastructureHostPrefixes.contains(where: { host.hasPrefix($0) })
        let infraPorts = !open.isDisjoint(with: infrastructurePorts)
        let computer = !vendorWords.isDisjoint(with: computerVendors) || !open.isDisjoint(with: computerPorts)
        let sip = !open.isDisjoint(with: sipPorts)
        let namedPhone = hostLooksLikePhone(host)
        // L'annonce LLDP-MED / CDP « téléphone » fait foi (les switchs et routeurs ne l'annoncent pas).
        if signals.contains(.announcedPhone) { return true }
        if infraName && !namedPhone { return false }
        if !vendorWords.isDisjoint(with: dedicatedVendors) { return !computer }
        let conditional = !vendorWords.isDisjoint(with: conditionalVendors) || vendor.contains("alcatel-lucent enterprise")
        if conditional {
            // Cisco, Panasonic, Unify… : nom de téléphone (SEP…), ou SIP / VLAN voix sans les ports
            // d'administration d'un routeur ou d'un switch.
            if namedPhone { return true }
            return (sip || signals.contains(.voiceVLAN)) && !infraPorts && !computer
        }
        if namedPhone { return !computer && (!infraPorts || isCiscoPhoneName(host)) }
        // Fabricant inconnu ou autre : SIP, ou VLAN voix, sans signe d'ordinateur ni d'équipement
        // réseau (une borne ou un switch peut avoir son adresse dans le VLAN voix).
        let network = !vendorWords.isDisjoint(with: networkVendors)
        if (sip || signals.contains(.voiceVLAN)) && !infraPorts && !computer && !network { return true }
        return false
    }
}

public extension VoIPClassifier {
    /// Pourquoi l'appareil est vu comme un téléphone IP (fiche Appareil) : « LLDP / CDP : téléphone »,
    /// « VLAN voix 20 », « SIP 5060 », « Nom SIP-T54W », « Fabricant Yealink ». Vide si rien.
    /// `includeName` : faux quand le nom d'hôte est déjà affiché à côté.
    static func evidence(_ device: Device, includeName: Bool = true) -> [String] {
        var result: [String] = []
        let signals = device.voipSignals ?? []
        if signals.contains(.announcedPhone) { result.append("LLDP / CDP\u{00A0}: téléphone") }
        if signals.contains(.voiceVLAN) { result.append(device.vlan.map { "VLAN voix \($0)" } ?? "VLAN voix") }
        let sip = device.openPorts.filter(sipPorts.contains)
        if !sip.isEmpty { result.append("SIP " + sip.map(String.init).joined(separator: ", ")) }
        if includeName, let host = device.hostnameLabel, hostLooksLikePhone(host) { result.append("Nom \(host)") }
        let vendor = device.vendorLabel
        let words = Set(vendor.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }).map(String.init))
        if !words.isDisjoint(with: dedicatedVendors) { result.append("Fabricant \(vendor)") }
        return result
    }
}

/// Indices réunis pour un site : MAC et IP des appareils qui s'annoncent « téléphone », VLAN voix.
public struct VoIPHints: Equatable, Sendable {
    public var phoneMACs: Set<MACAddress>
    public var phoneIPs: Set<IPv4Address>
    public var voiceVLANs: Set<Int>

    public init(phoneMACs: Set<MACAddress> = [], phoneIPs: Set<IPv4Address> = [], voiceVLANs: Set<Int> = []) {
        self.phoneMACs = phoneMACs
        self.phoneIPs = phoneIPs
        self.voiceVLANs = voiceVLANs
    }

    public var isEmpty: Bool { phoneMACs.isEmpty && phoneIPs.isEmpty && voiceVLANs.isEmpty }
}

public enum VoIPDetector {
    /// Libellé de plage qui désigne un VLAN voix (« Voix », « VoIP », « Téléphonie IP »).
    static let voiceLabelWords = ["voix", "voip", "telephonie", "telephone", "phone", "voice", "sip"]

    public static func isVoiceLabel(_ label: String) -> Bool {
        let text = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let words = text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        return words.contains(where: { word in voiceLabelWords.contains(where: { word.hasPrefix($0) }) })
    }

    /// Réunit les indices : voisins LLDP des switchs relevés (SNMP ou FortiGate), voisins LLDP / CDP
    /// entendus par ce Mac, plages nommées « Voix », et appareils du scan (pour départager un port
    /// où un poste est branché derrière le téléphone).
    public static func hints(snapshots: [SNMPSwitchSnapshot], neighbors: [NetworkNeighbor] = [],
                             ranges: [ScanRangeConfig] = [], devices: [Device] = []) -> VoIPHints {
        var hints = VoIPHints()
        for range in ranges where isVoiceLabel(range.label) {
            if let vlan = range.vlan { hints.voiceVLANs.insert(vlan) }
        }
        for neighbor in neighbors {
            // Le switch voisin annonce le VLAN voix du port (LLDP-MED Network Policy, Appliance VLAN CDP).
            if let vlan = neighbor.voiceVLAN { hints.voiceVLANs.insert(vlan) }
            guard announcesPhone(neighbor.capabilities) else { continue }
            for text in [neighbor.sourceMAC, neighbor.chassisID].compactMap({ $0 }) {
                if let mac = MACAddress(text), mac.value != 0, !mac.isMulticast { hints.phoneMACs.insert(mac) }
            }
            for text in neighbor.managementAddresses {
                if let ip = IPv4Address(text) { hints.phoneIPs.insert(ip) }
            }
        }
        let byMAC = Dictionary(devices.compactMap { device in device.mac.map { ($0, device) } }, uniquingKeysWith: { first, _ in first })
        for snapshot in snapshots {
            for neighbor in snapshot.neighbors {
                guard let caps = neighbor.capabilities, caps.contains(.telephone), !caps.contains(.router) else { continue }
                let port = neighbor.ifIndex ?? neighbor.localPortNum
                let entries = snapshot.entries(on: port)
                guard let phone = phoneMAC(for: neighbor, among: entries.map(\.mac), devices: byMAC) else { continue }
                hints.phoneMACs.insert(phone)
                // VLAN où le téléphone est appris, s'il diffère du VLAN natif du port : c'est le VLAN voix.
                if let vlan = entries.first(where: { $0.mac == phone })?.vlan, vlan != snapshot.pvid[port] {
                    hints.voiceVLANs.insert(vlan)
                }
            }
        }
        return hints
    }

    /// Capacités LLDP ou CDP décodées (« Bridge », « Téléphone ») : téléphone, et pas routeur.
    static func announcesPhone(_ capabilities: [String]) -> Bool {
        let lower = capabilities.map { $0.lowercased() }
        return lower.contains { $0.hasPrefix("téléphone") || $0 == "telephone" || $0 == "phone" }
            && !lower.contains { $0 == "router" || $0 == "routeur" }
    }

    /// Quelle MAC du port est le téléphone annoncé par LLDP ? Identifiant de port ou nom « SEP… »
    /// qui contient la MAC, nom d'hôte identique, seule MAC du port, ou seule MAC d'un fabricant VoIP.
    static func phoneMAC(for neighbor: SNMPLLDPNeighbor, among macs: [MACAddress], devices: [MACAddress: Device]) -> MACAddress? {
        let unique = Array(Set(macs))
        guard !unique.isEmpty else { return nil }
        if let mac = MACAddress(neighbor.portID), unique.contains(mac) { return mac }
        let name = neighbor.sysName.lowercased()
        if VoIPClassifier.isCiscoPhoneName(name), let mac = MACAddress(String(name.prefix(15).dropFirst(3))), unique.contains(mac) {
            return mac
        }
        if !name.isEmpty, let match = unique.first(where: { devices[$0]?.hostname.map { NamesFormat.display($0).lowercased() } == name }) {
            return match
        }
        if unique.count == 1 { return unique[0] }
        let voip = unique.filter { mac in
            let vendor = (devices[mac]?.vendor ?? OUIDatabase.builtIn.vendor(for: mac) ?? "").lowercased()
            let words = Set(vendor.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }).map(String.init))
            return !words.isDisjoint(with: VoIPClassifier.dedicatedVendors)
        }
        return voip.count == 1 ? voip[0] : nil
    }

    /// Reporte les indices sur les appareils et refait leur classement quand un indice change.
    /// Un téléphone déjà reconnu garde son annonce LLDP même si le relevé suivant ne la voit pas.
    public static func apply(_ hints: VoIPHints, to devices: [Device]) -> (devices: [Device], changed: Int) {
        var changed = 0
        let result = devices.map { device -> Device in
            var signals = device.voipSignals ?? []
            if let mac = device.mac, hints.phoneMACs.contains(mac) { signals.insert(.announcedPhone) }
            if hints.phoneIPs.contains(device.ip) { signals.insert(.announcedPhone) }
            if !hints.voiceVLANs.isEmpty {
                if let vlan = device.vlan, hints.voiceVLANs.contains(vlan) { signals.insert(.voiceVLAN) } else { signals.remove(.voiceVLAN) }
            }
            let stored: VoIPSignals? = signals.isEmpty ? nil : signals
            guard stored != device.voipSignals else { return device }
            var copy = device
            copy.voipSignals = stored
            let guessed = ScanDeviceClassifier.guess(copy)
            if guessed != .inconnu { copy.deviceType = guessed }
            changed += 1
            return copy
        }
        return (result, changed)
    }
}
