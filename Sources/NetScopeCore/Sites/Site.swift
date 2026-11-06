import Foundation

// Note 28 : le site devient la référence. Un site (souvent nommé d'après le client : « Clinique
// Exemple », « Groupe X · Laval ») a ses plages, ses FortiGate, ses switchs SNMP, ses indices de
// détection et son propre inventaire. Pas de niveau Client (décision de Dany). Plusieurs sites
// peuvent avoir exactement les mêmes plages : l'adresse IP seule ne choisit jamais le site.
// Aucun secret ici (ni jeton, ni communauté) : ce modèle va dans sites.json, le CSV et les sauvegardes.

// MARK: - Indices de détection

/// Ce qui reconnaît un site sur place, sans jamais se fier à la seule IP : MAC de la passerelle,
/// numéro de série et nom d'hôte de la FortiGate, SSID (facultatif, indice faible).
public struct SiteHints: Codable, Hashable, Sendable {
    public var gatewayMACs: [MACAddress]
    public var fortiGateSerials: [String]
    public var fortiGateHostnames: [String]
    public var ssid: String?

    public init(gatewayMACs: [MACAddress] = [], fortiGateSerials: [String] = [], fortiGateHostnames: [String] = [],
                ssid: String? = nil) {
        self.gatewayMACs = gatewayMACs
        self.fortiGateSerials = fortiGateSerials
        self.fortiGateHostnames = fortiGateHostnames
        self.ssid = ssid
    }

    public var isEmpty: Bool {
        gatewayMACs.isEmpty && fortiGateSerials.isEmpty && fortiGateHostnames.isEmpty && (ssid ?? "").isEmpty
    }

    /// Ajoute une MAC de passerelle (sans doublon) ; vrai si elle est nouvelle.
    @discardableResult
    public mutating func learn(gatewayMAC mac: MACAddress) -> Bool {
        guard !mac.isBroadcast, !mac.isMulticast, mac.value != 0, !gatewayMACs.contains(mac) else { return false }
        gatewayMACs.append(mac)
        return true
    }

    /// Ajoute le numéro de série et le nom d'hôte d'une FortiGate (sans doublon, casse ignorée).
    public mutating func learn(serial: String?, hostname: String?) {
        if let serial = Self.clean(serial), !fortiGateSerials.contains(where: { $0.caseInsensitiveCompare(serial) == .orderedSame }) {
            fortiGateSerials.append(serial)
        }
        if let hostname = Self.clean(hostname), !fortiGateHostnames.contains(where: { $0.caseInsensitiveCompare(hostname) == .orderedSame }) {
            fortiGateHostnames.append(hostname)
        }
    }

    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    enum CodingKeys: String, CodingKey { case gatewayMACs, fortiGateSerials, fortiGateHostnames, ssid }

    /// Lecture tolérante : une MAC illisible est ignorée sans perdre les autres.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let macs = ((try? c.decodeIfPresent([String].self, forKey: .gatewayMACs)) ?? nil) ?? []
        gatewayMACs = macs.compactMap(MACAddress.init)
        fortiGateSerials = ((try? c.decodeIfPresent([String].self, forKey: .fortiGateSerials)) ?? nil) ?? []
        fortiGateHostnames = ((try? c.decodeIfPresent([String].self, forKey: .fortiGateHostnames)) ?? nil) ?? []
        ssid = Self.clean((try? c.decodeIfPresent(String.self, forKey: .ssid)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gatewayMACs.map { $0.formatted(.upperColon) }, forKey: .gatewayMACs)
        try c.encode(fortiGateSerials, forKey: .fortiGateSerials)
        try c.encode(fortiGateHostnames, forKey: .fortiGateHostnames)
        try c.encodeIfPresent(ssid, forKey: .ssid)
    }
}

// MARK: - Site

public struct Site: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var notes: String
    /// Plages du site (libellé, VLAN, cochée ou non), telles que le Scanner les utilise.
    public var ranges: [ScanRangeConfig]
    /// FortiGate associées (identifiants de `FortiGateController`).
    public var fortiGateIDs: [UUID]
    /// Switchs SNMP (non Fortinet) associés, par adresse IP de gestion.
    public var switchHosts: [String]
    public var hints: SiteHints
    /// Note 82 : plages exclues, jamais sondées (même si elles sont dans une plage du site).
    public var exclusions: [ExcludedRange]
    /// Note 77 : contrôleurs UniFi, Omada ou Meraki du site (sans secret : il est au Trousseau).
    public var controllers: [SiteController]
    /// Fin du dernier scan fait dans ce site.
    public var lastScan: Date?
    /// Fiches de son inventaire, à la dernière écriture (pour la liste des sites).
    public var inventoryCount: Int?
    public var created: Date

    public init(id: UUID = UUID(), name: String, notes: String = "", ranges: [ScanRangeConfig] = [],
                fortiGateIDs: [UUID] = [], switchHosts: [String] = [], hints: SiteHints = SiteHints(),
                lastScan: Date? = nil, inventoryCount: Int? = nil, created: Date = Date(), exclusions: [ExcludedRange] = [],
                controllers: [SiteController] = []) {
        self.id = id
        self.name = name
        self.notes = notes
        self.ranges = ranges
        self.fortiGateIDs = fortiGateIDs
        self.switchHosts = switchHosts
        self.hints = hints
        self.exclusions = exclusions
        self.controllers = controllers
        self.lastScan = lastScan
        self.inventoryCount = inventoryCount
        self.created = created
    }

    /// Nom à afficher (« Site sans nom » si vide).
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Site sans nom" : trimmed
    }

    /// Plages lisibles, dans l'ordre (les illisibles sont ignorées).
    public var parsedRanges: [IPRange] { ranges.compactMap { try? $0.parsed() } }

    /// « 10.182.122.0/24, 192.168.50.0/24 ».
    public var rangesLabel: String { ranges.map(\.text).joined(separator: ", ") }

    /// Vrai si une de ses plages contient l'adresse ou chevauche la plage donnée.
    public func overlaps(_ range: IPRange) -> Bool {
        parsedRanges.contains { ScanRelevance.overlaps($0, range) }
    }

    public func contains(_ address: IPv4Address) -> Bool {
        ScanRelevance.contains(parsedRanges, address)
    }

    /// Adresses exclues du site, prêtes pour le scan (note 82).
    public var excludedAddresses: AddressExclusions { AddressExclusions(exclusions) }

    /// Vrai si l'adresse est dans une plage exclue du site.
    public func isExcluded(_ address: IPv4Address) -> Bool {
        !exclusions.isEmpty && excludedAddresses.contains(address)
    }

    /// Mêmes plages (texte, libellé, VLAN et, si `checks`, case cochée), quels que soient les
    /// identifiants. Sans `checks` : une plage décochée pour un scan n'est pas une modification à
    /// enregistrer.
    public static func sameRanges(_ a: [ScanRangeConfig], _ b: [ScanRangeConfig], checks: Bool = true) -> Bool {
        func key(_ r: ScanRangeConfig) -> String {
            [r.text.replacingOccurrences(of: " ", with: ""), r.label.trimmingCharacters(in: .whitespaces),
             r.vlan.map(String.init) ?? "", checks ? (r.isEnabled ? "1" : "0") : ""].joined(separator: "|")
        }
        return a.map(key) == b.map(key)
    }

    /// Mêmes adresses à scanner, quel que soit l'ordre ou le libellé (deux sites « identiques »).
    public static func sameAddresses(_ a: [ScanRangeConfig], _ b: [ScanRangeConfig]) -> Bool {
        let left = Set(a.compactMap { try? $0.parsed() }.flatMap(\.segments).map(\.description))
        let right = Set(b.compactMap { try? $0.parsed() }.flatMap(\.segments).map(\.description))
        return !left.isEmpty && left == right
    }

    enum CodingKeys: String, CodingKey {
        case id, name, notes, ranges, fortiGateIDs, switchHosts, hints, exclusions, controllers, lastScan, inventoryCount, created
    }

    /// Lecture tolérante : champ absent ou mal typé → valeur par défaut ; plage illisible ignorée.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let idText = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        id = idText.flatMap(UUID.init(uuidString:)) ?? UUID()
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        notes = ((try? c.decodeIfPresent(String.self, forKey: .notes)) ?? nil) ?? ""
        ranges = ((try? c.decodeIfPresent([SiteLenient<ScanRangeConfig>].self, forKey: .ranges)) ?? nil)?.compactMap(\.value) ?? []
        let fortiTexts = ((try? c.decodeIfPresent([String].self, forKey: .fortiGateIDs)) ?? nil) ?? []
        fortiGateIDs = fortiTexts.compactMap(UUID.init(uuidString:))
        switchHosts = (((try? c.decodeIfPresent([String].self, forKey: .switchHosts)) ?? nil) ?? []).compactMap { IPv4Address($0)?.description }
        hints = ((try? c.decodeIfPresent(SiteHints.self, forKey: .hints)) ?? nil) ?? SiteHints()
        exclusions = ((try? c.decodeIfPresent([SiteLenient<ExcludedRange>].self, forKey: .exclusions)) ?? nil)?.compactMap(\.value) ?? []
        // Note 77 : un contrôleur illisible (marque inconnue) est ignoré sans perdre les autres.
        controllers = ((try? c.decodeIfPresent([SiteLenient<SiteController>].self, forKey: .controllers)) ?? nil)?.compactMap(\.value) ?? []
        lastScan = (try? c.decodeIfPresent(Date.self, forKey: .lastScan)) ?? nil
        inventoryCount = (try? c.decodeIfPresent(Int.self, forKey: .inventoryCount)) ?? nil
        created = ((try? c.decodeIfPresent(Date.self, forKey: .created)) ?? nil) ?? Date(timeIntervalSince1970: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(notes, forKey: .notes)
        try c.encode(ranges, forKey: .ranges)
        try c.encode(fortiGateIDs.map(\.uuidString), forKey: .fortiGateIDs)
        try c.encode(switchHosts, forKey: .switchHosts)
        try c.encode(hints, forKey: .hints)
        // Écrite seulement si le site en a : un sites.json sans exclusion reste identique (synchronisation).
        if !exclusions.isEmpty { try c.encode(exclusions, forKey: .exclusions) }
        // Note 77 : idem pour les contrôleurs (un sites.json sans contrôleur reste identique).
        if !controllers.isEmpty { try c.encode(controllers, forKey: .controllers) }
        try c.encodeIfPresent(lastScan, forKey: .lastScan)
        try c.encodeIfPresent(inventoryCount, forKey: .inventoryCount)
        try c.encode(created, forKey: .created)
    }
}

/// Élément lu sans faire échouer la liste qui le contient.
struct SiteLenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Liste des sites

/// sites.json : les sites et le site actif (nil : aucun site, plages libres).
public struct SiteList: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version = SiteList.currentVersion
    public var sites: [Site]
    public var activeID: UUID?

    public init(sites: [Site] = [], activeID: UUID? = nil) {
        self.sites = sites
        self.activeID = activeID
    }

    public var active: Site? { activeID.flatMap(site) }

    public func site(_ id: UUID) -> Site? { sites.first { $0.id == id } }

    public func index(of id: UUID) -> Int? { sites.firstIndex { $0.id == id } }

    /// Sites triés par nom (ordre de la barre latérale et des menus).
    public var sortedByName: [Site] {
        sites.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Nom libre : « Clinique Exemple », sinon « Clinique Exemple (2) »…
    public func uniqueName(_ wanted: String, excluding id: UUID? = nil) -> String {
        let base = wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Nouveau site" : wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(sites.filter { $0.id != id }.map { $0.displayName.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) (\(number))".lowercased()) { number += 1 }
        return "\(base) (\(number))"
    }

    public mutating func add(_ site: Site) {
        var copy = site
        copy.name = uniqueName(site.name)
        sites.append(copy)
    }

    public mutating func update(_ site: Site) {
        if let index = index(of: site.id) { sites[index] = site }
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let index = index(of: id) else { return }
        sites[index].name = uniqueName(name, excluding: id)
    }

    /// Copie du site (plages, plages exclues, FortiGate, switchs, notes) sous un nouveau nom ; ni l'inventaire, ni
    /// les résultats, ni les indices de détection (une MAC de passerelle ne désigne qu'un site), ni les
    /// contrôleurs UniFi, Omada ou Meraki (note 77 : leur secret est propre à chacun, au Trousseau).
    @discardableResult
    public mutating func duplicate(_ id: UUID, newID: UUID = UUID(), now: Date = Date()) -> Site? {
        guard let source = site(id) else { return nil }
        let copy = Site(id: newID, name: uniqueName("\(source.displayName) (copie)"), notes: source.notes,
                        ranges: source.ranges.map { ScanRangeConfig(text: $0.text, label: $0.label, vlan: $0.vlan, isEnabled: $0.isEnabled) },
                        fortiGateIDs: source.fortiGateIDs, switchHosts: source.switchHosts, created: now,
                        exclusions: source.exclusions.map { ExcludedRange(text: $0.text, note: $0.note) })
        sites.append(copy)
        return copy
    }

    /// Retire un site ; s'il était actif, plus aucun site n'est actif.
    public mutating func remove(_ id: UUID) {
        sites.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }

    /// Sites associés à ce switch SNMP.
    public func sites(forSwitch host: String) -> [Site] {
        sites.filter { $0.switchHosts.contains(host) }
    }

    /// Associe un switch SNMP exactement aux sites donnés.
    public mutating func setSwitch(_ host: String, sites ids: Set<UUID>) {
        for index in sites.indices {
            let has = sites[index].switchHosts.contains(host)
            if ids.contains(sites[index].id), !has { sites[index].switchHosts.append(host) }
            if !ids.contains(sites[index].id), has { sites[index].switchHosts.removeAll { $0 == host } }
        }
    }

    /// Sites qui ont exactement les mêmes adresses à scanner (192.168.1.0/24 chez deux clients).
    public func sharingRanges(with id: UUID) -> [Site] {
        guard let site = site(id) else { return [] }
        return sites.filter { $0.id != id && Site.sameAddresses($0.ranges, site.ranges) }
    }

    /// Sites qui partagent au moins une partie de leurs adresses avec ce site (192.168.1.0/24 chez
    /// deux clients, même si leurs autres plages diffèrent).
    public func sharingAddresses(with id: UUID) -> [Site] {
        guard let site = site(id) else { return [] }
        let mine = site.parsedRanges
        guard !mine.isEmpty else { return [] }
        return sites.filter { other in
            other.id != id && other.parsedRanges.contains { theirs in mine.contains { ScanRelevance.overlaps($0, theirs) } }
        }
    }

    /// Sites dont une plage chevauche celles-ci.
    public func sitesOverlapping(_ ranges: [IPRange]) -> [Site] {
        sites.filter { site in ranges.contains { site.overlaps($0) } }
    }

    enum CodingKeys: String, CodingKey { case version, sites, activeID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? SiteList.currentVersion
        var list = ((try? c.decodeIfPresent([SiteLenient<Site>].self, forKey: .sites)) ?? nil)?.compactMap(\.value) ?? []
        // Deux sites au même identifiant partageraient le même dossier d'inventaire : le second en
        // reçoit un autre, DÉRIVÉ du sien (le même à chaque lecture : son dossier est retrouvé au
        // lancement suivant, même si la liste n'a pas été réenregistrée entre-temps).
        let original = Set(list.map(\.id))
        var seen = Set<UUID>()
        for index in list.indices {
            if seen.contains(list[index].id) {
                list[index].id = SiteList.derivedID(from: list[index].id, avoiding: original.union(seen))
            }
            seen.insert(list[index].id)
        }
        sites = list
        let active = ((try? c.decodeIfPresent(String.self, forKey: .activeID)) ?? nil).flatMap(UUID.init(uuidString:))
        activeID = active.flatMap { id in list.contains { $0.id == id } ? id : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(sites, forKey: .sites)
        try c.encodeIfPresent(activeID?.uuidString, forKey: .activeID)
    }

    /// Identifiant stable dérivé d'un autre (doublon) : derniers octets modifiés jusqu'à un libre.
    static func derivedID(from id: UUID, avoiding taken: Set<UUID>) -> UUID {
        var bytes = id.uuid
        var counter: UInt16 = 0
        repeat {
            counter &+= 1
            bytes.14 = id.uuid.14 ^ UInt8(truncatingIfNeeded: counter >> 8)
            bytes.15 = id.uuid.15 ^ UInt8(truncatingIfNeeded: counter)
        } while taken.contains(UUID(uuid: bytes)) && counter < UInt16.max
        return UUID(uuid: bytes)
    }

    public static func decode(_ data: Data) -> SiteList? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SiteList.self, from: data)
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}
