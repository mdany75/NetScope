import Foundation

// Note 25 : plusieurs FortiGate, une par site, chacune avec son jeton (Trousseau, un compte par
// contrôleur) et les plages d'adresses qu'elle couvre. Le jeton n'est jamais dans ces modèles :
// ni dans le JSON des réglages, ni dans le CSV, ni dans les sauvegardes, ni dans les journaux.

// MARK: - Plage couverte

/// Portion d'adresses couverte par une FortiGate : CIDR (réseau et broadcast compris), début-fin ou
/// adresse seule. Sans la limite de taille des plages à scanner : « 10.0.0.0/8 » est permis.
public struct FortiCoveredRange: Hashable, Sendable, CustomStringConvertible {
    public let first: IPv4Address
    public let last: IPv4Address
    /// Forme normalisée (« 10.20.0.0/16 », « 10.30.0.10-10.30.0.50 », « 10.40.0.5 »).
    public let text: String

    public init(first: IPv4Address, last: IPv4Address, text: String? = nil) {
        self.first = min(first, last)
        self.last = max(first, last)
        if let text {
            self.text = text
        } else if self.first == self.last {
            self.text = self.first.description
        } else {
            self.text = "\(self.first)-\(self.last)"
        }
    }

    public init(subnet: Subnet) {
        self.init(first: subnet.network, last: subnet.broadcast, text: subnet.description)
    }

    public var description: String { text }

    /// Nombre d'adresses (de 1 à 2^32).
    public var size: UInt64 { UInt64(last.value) - UInt64(first.value) + 1 }

    /// Précision, comme un préfixe : 24 pour 256 adresses ; une portion début-fin de 50 adresses
    /// compte comme un /26 (plus précise qu'un /24, moins qu'un /27).
    public var precision: Int {
        var bits = 0
        while (UInt64(1) << UInt64(bits)) < size { bits += 1 }
        return 32 - bits
    }

    public func contains(_ address: IPv4Address) -> Bool { address >= first && address <= last }

    public func overlaps(_ other: FortiCoveredRange) -> Bool { first <= other.last && other.first <= last }

    public func overlaps(first a: IPv4Address, last b: IPv4Address) -> Bool { first <= b && a <= last }

    /// Contient entièrement l'autre portion.
    public func covers(_ other: FortiCoveredRange) -> Bool { first <= other.first && other.last <= last }

    /// Lit une ou plusieurs portions séparées par des virgules, points-virgules ou espaces.
    /// « 10.0.0.0 255.255.255.0 » (adresse puis masque, forme de FortiOS) est aussi compris.
    public static func parseList(_ text: String) throws -> [FortiCoveredRange] {
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: ",; \t\r\n")).filter { !$0.isEmpty }
        var result: [FortiCoveredRange] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            // « 10.0.0.0 255.255.255.0 » : l'adresse et son masque forment une seule portion.
            if index + 1 < tokens.count, IPv4Address(token) != nil, let mask = IPv4Address(tokens[index + 1]),
               let prefix = mask.prefixLength, prefix >= 8, let address = IPv4Address(token) {
                result.append(FortiCoveredRange(subnet: Subnet(address: address, prefix: prefix)))
                index += 2
                continue
            }
            result.append(try parse(token))
            index += 1
        }
        return result
    }

    /// Lit une portion seule.
    public static func parse(_ raw: String) throws -> FortiCoveredRange {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw FortiRangeError.empty }
        if token.contains("/") {
            guard let subnet = try? Subnet(parsing: token) else { throw FortiRangeError.invalid(token) }
            return FortiCoveredRange(subnet: subnet)
        }
        if token.contains("-") {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let start = IPv4Address(parts[0]) else { throw FortiRangeError.invalid(token) }
            let end: IPv4Address
            if let full = IPv4Address(parts[1]) {
                end = full
            } else if !parts[1].isEmpty, parts[1].count <= 3, parts[1].allSatisfy(\.isNumber), let lastOctet = UInt32(parts[1]), lastOctet <= 255 {
                end = IPv4Address(start.value & 0xFFFF_FF00 | lastOctet)
            } else {
                throw FortiRangeError.invalid(token)
            }
            guard end >= start else { throw FortiRangeError.reversed(token) }
            return FortiCoveredRange(first: start, last: end)
        }
        guard let address = IPv4Address(token) else { throw FortiRangeError.invalid(token) }
        return FortiCoveredRange(first: address, last: address)
    }

    /// Découpe un texte de plages en blocs, aux virgules, points-virgules et fins de ligne (pas aux
    /// espaces, pour garder « adresse masque » ensemble) ; chaque bloc est lu par parseList.
    public static func splitBlocks(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Lecture qui garde les portions valides et rend les autres à part.
    public static func parseLenient(_ texts: [String]) -> (ranges: [FortiCoveredRange], invalid: [String]) {
        var ranges: [FortiCoveredRange] = []
        var invalid: [String] = []
        for text in texts {
            do {
                for range in try parseList(text) where !ranges.contains(range) { ranges.append(range) }
            } catch {
                invalid.append(text)
            }
        }
        return (ranges, invalid)
    }
}

public enum FortiRangeError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case invalid(String)
    case reversed(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Plage vide."
        case .invalid(let token): return "Plage illisible\u{00A0}: «\u{00A0}\(token)\u{00A0}» (ex. 10.20.0.0/16, 10.20.0.1-10.20.0.50)."
        case .reversed(let token): return "Plage à l’envers\u{00A0}: «\u{00A0}\(token)\u{00A0}» (la fin précède le début)."
        }
    }
}

// MARK: - État d'un contrôleur

/// Dernier état connu d'un contrôleur (dernier test ou dernière lecture), gardé dans les réglages.
/// Le message est toujours débarrassé du jeton avant d'être enregistré.
public struct FortiControllerStatus: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ok, error, missingToken, certificate, untested
    }

    public var kind: Kind
    public var message: String
    public var date: Date?
    public var hostname: String?
    public var model: String?
    public var version: String?
    public var switchCount: Int?
    public var deviceCount: Int?

    public init(kind: Kind, message: String = "", date: Date? = nil, hostname: String? = nil, model: String? = nil,
                version: String? = nil, switchCount: Int? = nil, deviceCount: Int? = nil) {
        self.kind = kind
        self.message = message
        self.date = date
        self.hostname = hostname
        self.model = model
        self.version = version
        self.switchCount = switchCount
        self.deviceCount = deviceCount
    }

    /// État tiré d'une lecture réussie.
    public static func success(_ report: FortiGateReport, date: Date) -> FortiControllerStatus {
        FortiControllerStatus(kind: .ok, date: date, hostname: report.controllerName, model: report.system.model,
                              version: report.system.version, switchCount: report.switches.count,
                              deviceCount: report.locatedDevices.count)
    }

    enum CodingKeys: String, CodingKey {
        case kind, message, date, hostname, model, version, switchCount, deviceCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = raw.flatMap(Kind.init(rawValue:)) ?? .untested
        message = ((try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil) ?? ""
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? nil
        hostname = (try? c.decodeIfPresent(String.self, forKey: .hostname)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        switchCount = (try? c.decodeIfPresent(Int.self, forKey: .switchCount)) ?? nil
        deviceCount = (try? c.decodeIfPresent(Int.self, forKey: .deviceCount)) ?? nil
    }
}

// MARK: - Contrôleur

/// Une FortiGate d'un site : adresse, port, VDOM, plages couvertes, empreinte acceptée. Le jeton est
/// au Trousseau, sous le compte `keychainAccount` (l'identifiant du contrôleur).
public struct FortiGateController: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Nom du site (« Siège », « Entrepôt Laval »).
    public var site: String
    public var host: String
    public var port: Int
    public var vdom: String
    /// Plages couvertes, telles que saisies (« 10.20.0.0/16 », « 10.20.0.1-10.20.0.50 »).
    public var ranges: [String]
    public var pinnedFingerprint: String?
    public var isEnabled: Bool
    public var lastStatus: FortiControllerStatus?
    public var timeout: Double

    public init(id: UUID = UUID(), site: String, host: String, port: Int = 443, vdom: String = "", ranges: [String] = [],
                pinnedFingerprint: String? = nil, isEnabled: Bool = true, lastStatus: FortiControllerStatus? = nil, timeout: Double = 8) {
        self.id = id
        self.site = site
        self.host = host
        self.port = port
        self.vdom = vdom
        self.ranges = ranges
        self.pinnedFingerprint = pinnedFingerprint
        self.isEnabled = isEnabled
        self.lastStatus = lastStatus
        self.timeout = timeout
    }

    /// Compte du Trousseau qui garde le jeton de ce contrôleur.
    public var keychainAccount: String { id.uuidString }

    /// Réglages de connexion (ceux de la 0.9.0, sans jeton).
    public var config: FortiGateConfig {
        get { FortiGateConfig(host: host, port: port, vdom: vdom, pinnedFingerprint: pinnedFingerprint, timeout: timeout) }
        set {
            host = newValue.host
            port = newValue.port
            vdom = newValue.vdom
            pinnedFingerprint = newValue.pinnedFingerprint
            timeout = newValue.timeout
        }
    }

    /// Nom à afficher : le site, sinon l'adresse.
    public var displayName: String {
        let name = site.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (config.cleanHost.isEmpty ? "FortiGate" : config.cleanHost) : name
    }

    /// « 10.20.0.1 » ou « 10.20.0.1:8443 ».
    public var addressLabel: String {
        let c = config
        return c.effectivePort == 443 ? c.cleanHost : "\(c.cleanHost):\(c.effectivePort)"
    }

    /// Plages lisibles, dans l'ordre de saisie, sans doublon.
    public var coveredRanges: [FortiCoveredRange] { FortiCoveredRange.parseLenient(ranges).ranges }

    /// Plages illisibles (signalées dans les Réglages, ignorées pour le choix).
    public var invalidRanges: [String] { FortiCoveredRange.parseLenient(ranges).invalid }

    /// Même FortiGate (adresse et port), quel que soit le site.
    public func sameTarget(as other: FortiGateController) -> Bool {
        config.cleanHost.lowercased() == other.config.cleanHost.lowercased() && config.effectivePort == other.config.effectivePort
    }

    enum CodingKeys: String, CodingKey {
        case id, site, host, port, vdom, ranges, pinnedFingerprint, isEnabled, lastStatus, timeout
    }

    /// Lecture tolérante : champ absent ou mal typé → valeur par défaut ; plages en liste ou en texte.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let idText = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        id = idText.flatMap(UUID.init(uuidString:)) ?? UUID()
        site = ((try? c.decodeIfPresent(String.self, forKey: .site)) ?? nil) ?? ""
        host = ((try? c.decodeIfPresent(String.self, forKey: .host)) ?? nil) ?? ""
        if let number = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? nil {
            port = number
        } else if let text = (try? c.decodeIfPresent(String.self, forKey: .port)) ?? nil, let number = Int(text) {
            port = number
        } else {
            port = 443
        }
        vdom = ((try? c.decodeIfPresent(String.self, forKey: .vdom)) ?? nil) ?? ""
        if let list = (try? c.decodeIfPresent([String].self, forKey: .ranges)) ?? nil {
            ranges = list
        } else if let text = (try? c.decodeIfPresent(String.self, forKey: .ranges)) ?? nil {
            // Découpe aux virgules, points-virgules et lignes seulement : « 10.0.0.0 255.255.255.0 »
            // (adresse puis masque) reste une seule portion, lue par parseList.
            ranges = FortiCoveredRange.splitBlocks(text)
        } else {
            ranges = []
        }
        pinnedFingerprint = (try? c.decodeIfPresent(String.self, forKey: .pinnedFingerprint)) ?? nil
        isEnabled = ((try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? nil) ?? true
        lastStatus = (try? c.decodeIfPresent(FortiControllerStatus.self, forKey: .lastStatus)) ?? nil
        let t = ((try? c.decodeIfPresent(Double.self, forKey: .timeout)) ?? nil) ?? 8
        timeout = t.isFinite && t > 0 && t <= 120 ? t : 8
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString, forKey: .id)
        try c.encode(site, forKey: .site)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(vdom, forKey: .vdom)
        try c.encode(ranges, forKey: .ranges)
        try c.encodeIfPresent(pinnedFingerprint, forKey: .pinnedFingerprint)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(lastStatus, forKey: .lastStatus)
        try c.encode(timeout, forKey: .timeout)
    }
}

/// Liste des contrôleurs, enregistrée en JSON dans les préférences (jamais de jeton).
public enum FortiControllerList {
    /// Liste lue ; une entrée illisible est ignorée sans perdre les autres. nil si les données ne
    /// sont pas une liste JSON.
    public static func decode(_ data: Data) -> [FortiGateController]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        var result: [FortiGateController] = []
        var ids = Set<UUID>()
        for item in array {
            guard JSONSerialization.isValidJSONObject(item), let itemData = try? JSONSerialization.data(withJSONObject: item),
                  var controller = try? JSONDecoder().decode(FortiGateController.self, from: itemData) else { continue }
            // Deux entrées avec le même identifiant partageraient le même jeton : la seconde en reçoit un neuf.
            if ids.contains(controller.id) { controller.id = UUID() }
            ids.insert(controller.id)
            result.append(controller)
        }
        return result
    }

    public static func encode(_ controllers: [FortiGateController]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(controllers)
    }
}

// MARK: - Secrets

/// Où vivent les jetons : le Trousseau en vrai, la mémoire dans les tests.
public protocol FortiSecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String, for account: String) throws
    func deleteSecret(_ account: String) throws
}

extension UpdKeychain: FortiSecretStore {
    public func secret(for account: String) -> String? { string(for: account) }
    public func setSecret(_ value: String, for account: String) throws { try set(value, for: account) }
    public func deleteSecret(_ account: String) throws { try delete(account) }
}

/// Secrets en mémoire (tests, démonstration).
public final class FortiMemorySecretStore: FortiSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public var all: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    public func secret(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    public func setSecret(_ value: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = value
    }

    public func deleteSecret(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = nil
    }
}

// MARK: - Migration depuis la 0.9.0

/// La FortiGate unique de la 0.9.0 (réglages « NetScope.fortigate.reglages », jeton au compte
/// « jeton ») devient la première entrée de la liste, avec son empreinte, sans ressaisie.
public enum FortiControllerMigration {
    /// Compte du jeton dans la 0.9.0.
    public static let legacyTokenAccount = "jeton"
    /// Nom donné au site migré (modifiable ensuite).
    public static let legacySiteName = "Site principal"

    public struct Result: Equatable, Sendable {
        public var controllers: [FortiGateController]
        /// Contrôleur créé depuis la 0.9.0 (son jeton reste à déplacer), nil sinon.
        public var migratedID: UUID?
    }

    /// Réglages : la liste enregistrée si elle existe, sinon l'ancienne FortiGate (si son adresse
    /// est valide), sinon une liste vide.
    public static func migrateSettings(existing: Data?, legacy: Data?, newID: UUID = UUID()) -> Result {
        if let existing, let list = FortiControllerList.decode(existing) {
            return Result(controllers: list, migratedID: nil)
        }
        guard let legacy, let config = try? JSONDecoder().decode(FortiGateConfig.self, from: legacy), config.isValid else {
            return Result(controllers: [], migratedID: nil)
        }
        let controller = FortiGateController(id: newID, site: legacySiteName, host: config.host, port: config.port, vdom: config.vdom,
                                             ranges: [], pinnedFingerprint: config.pinnedFingerprint, isEnabled: true,
                                             timeout: config.timeout)
        return Result(controllers: [controller], migratedID: newID)
    }

    /// Déplace le jeton de la 0.9.0 vers le compte du contrôleur migré. L'ancien compte n'est effacé
    /// qu'une fois la copie réussie ; un jeton déjà présent sous le nouveau compte n'est pas écrasé.
    /// Renvoie vrai si le nouveau compte a un jeton à la fin.
    @discardableResult
    public static func migrateToken(to id: UUID, store: FortiSecretStore) -> Bool {
        let account = id.uuidString
        if let current = store.secret(for: account), !current.isEmpty {
            try? store.deleteSecret(legacyTokenAccount)
            return true
        }
        guard let old = store.secret(for: legacyTokenAccount), !old.isEmpty else { return false }
        do {
            try store.setSecret(old, for: account)
        } catch {
            return false
        }
        guard store.secret(for: account) == old else { return false }
        try? store.deleteSecret(legacyTokenAccount)
        return true
    }
}

// MARK: - Comptes à ressaisir (sauvegardes)

public extension BackupKeychainScan {
    /// Comptes du Trousseau, avec le site de chaque jeton FortiGate (« Jeton de l’API REST de la
    /// FortiGate · Siège ») : la liste à ressaisir après une restauration. Les secrets ne sont
    /// jamais lus.
    static func describe(_ items: [BackupKeychainItem], fortiGates: [FortiGateController]) -> [BackupKeychainItem] {
        let sites = Dictionary(fortiGates.map { ($0.keychainAccount, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        return items.map { item in
            guard item.service == servicePrefix + ".fortigate" else { return item }
            var copy = item
            if let site = sites[item.account] {
                copy.usage = "Jeton de l’API REST de la FortiGate · \(site)"
            } else if item.account == FortiControllerMigration.legacyTokenAccount {
                copy.usage = "Jeton de l’API REST de la FortiGate (0.9.0)"
            }
            return copy
        }
    }
}
