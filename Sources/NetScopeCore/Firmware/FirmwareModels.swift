import Foundation

// Note 41 : firmware et licences du parc Fortinet. Versions FortiOS, FortiSwitch et FortiAP de
// chaque site, versions disponibles ou recommandées, contrats FortiGuard et FortiCare avec leur
// date d'expiration. Tout est lu par l'API REST de FortiOS en lecture seule (GET) : NetScope ne
// lance jamais de mise à jour. Rien ici n'accède au réseau.

// MARK: Version

/// Version d'un logiciel Fortinet : « v7.2.8 build1639 », « S248EP-v7.2.5-build0453 »,
/// « FP231F-v7.2.8-build0436 », « 7.4 ». Comparable (majeure, mineure, correctif, build).
public struct FortiVersion: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Numéro de build, s'il est connu (sert seulement à départager deux versions égales).
    public var build: Int?

    public init(major: Int, minor: Int, patch: Int = 0, build: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.build = build
    }

    /// Lit une version dans un texte libre ; nil si aucune version « X.Y » n'y figure.
    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // « v7.2.8 » en priorité (le code du modèle « S248EP » précède parfois la version).
        let tagged = #"[vV](\d{1,3})\.(\d{1,3})(?:\.(\d{1,4}))?"#
        let plain = #"(?<![\d.])(\d{1,3})\.(\d{1,3})(?:\.(\d{1,4}))?"#
        guard let match = Self.firstMatch(tagged, in: t) ?? Self.firstMatch(plain, in: t) else { return nil }
        major = match[0]
        minor = match[1]
        patch = match.count > 2 ? match[2] : 0
        if let range = t.range(of: #"(?i)build\s*0*(\d{1,6})"#, options: .regularExpression) {
            build = Int(String(t[range].filter(\.isNumber)))
        } else {
            build = nil
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var values: [Int] = []
        for index in 1..<m.numberOfRanges {
            let r = m.range(at: index)
            guard r.location != NSNotFound, let v = Int(ns.substring(with: r)) else { continue }
            values.append(v)
        }
        return values.count >= 2 ? values : nil
    }

    /// Version tirée de champs séparés (« major », « minor », « patch », « build »).
    static func from(_ object: FortiObject) -> FortiVersion? {
        if let major = object.int("major"), let minor = object.int("minor") {
            return FortiVersion(major: major, minor: minor, patch: object.int("patch") ?? 0, build: object.int("build"))
        }
        guard let text = object.string("version", "name", "firmware", "os_version", "image") else { return nil }
        var version = FortiVersion(text)
        if version?.build == nil, let build = object.int("build") { version?.build = build }
        return version
    }

    public static func < (a: FortiVersion, b: FortiVersion) -> Bool {
        (a.major, a.minor, a.patch, a.build ?? 0) < (b.major, b.minor, b.patch, b.build ?? 0)
    }

    /// Même branche (« 7.2 ») : une mise à jour de correctif.
    public func sameBranch(_ other: FortiVersion) -> Bool { major == other.major && minor == other.minor }

    /// Mêmes majeure, mineure et correctif (le build seul ne compte pas).
    public func sameRelease(_ other: FortiVersion) -> Bool { sameBranch(other) && patch == other.patch }

    /// « v7.2.8 ».
    public var short: String { "v\(major).\(minor).\(patch)" }
    /// « 7.2 ».
    public var branch: String { "\(major).\(minor)" }
    /// « v7.2.8 build1639 ».
    public var description: String { short + (build.map { " build\(String(format: "%04d", $0))" } ?? "") }
}

// MARK: Équipements

/// Famille d'équipement du parc.
public enum FirmwareDeviceKind: String, Codable, CaseIterable, Sendable {
    case fortigate, fortiswitch, fortiap

    public var label: String {
        switch self {
        case .fortigate: return "FortiGate"
        case .fortiswitch: return "FortiSwitch"
        case .fortiap: return "FortiAP"
        }
    }

    /// Logiciel de la famille (« FortiOS », « FortiSwitchOS », « FortiAP »).
    public var software: String {
        switch self {
        case .fortigate: return "FortiOS"
        case .fortiswitch: return "FortiSwitchOS"
        case .fortiap: return "FortiAP"
        }
    }
}

/// Image de firmware proposée (FortiGuard ou liste recommandée de la FortiGate).
public struct FirmwareImage: Codable, Hashable, Sendable {
    public var version: FortiVersion
    /// « Mature », « Feature », si l'API le dit.
    public var maturity: String?
    /// Marquée « recommandée » par la FortiGate.
    public var recommended: Bool

    public init(version: FortiVersion, maturity: String? = nil, recommended: Bool = false) {
        self.version = version
        self.maturity = maturity
        self.recommended = recommended
    }

    /// « Mature » ou « Feature » d'après « M », « F », « mature », « feature ».
    public static func maturityLabel(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        if t == "m" || t.hasPrefix("mature") { return "Mature" }
        if t == "f" || t.hasPrefix("feature") { return "Feature" }
        return nil
    }
}

/// Étape d'un chemin de mise à jour publié par FortiOS (« de 7.2.8 vers 7.2.10 »).
public struct FirmwareUpgradeEdge: Codable, Hashable, Sendable {
    public var from: FortiVersion
    public var to: FortiVersion

    public init(from: FortiVersion, to: FortiVersion) {
        self.from = from
        self.to = to
    }
}

/// D'où vient la version disponible d'un équipement.
public enum FirmwareSource: String, Codable, Sendable {
    /// Liste de FortiGuard lue par la FortiGate (system/firmware).
    case fortiguard
    /// Liste recommandée par la FortiGate pour ses FortiSwitch ou FortiAP.
    case recommended
    /// Aucune liste : un équipement du même modèle du parc a une version plus récente.
    case parc

    public var label: String {
        switch self {
        case .fortiguard: return "FortiGuard"
        case .recommended: return "recommandée par la FortiGate"
        case .parc: return "plus récente du parc (même modèle)"
        }
    }
}

/// État du firmware d'un équipement.
public enum FirmwareStatus: Int, Codable, Sendable, Comparable {
    case upToDate, unknown, updateAvailable

    public var label: String {
        switch self {
        case .upToDate: return "À jour"
        case .unknown: return "Inconnu"
        case .updateAvailable: return "Mise à jour disponible"
        }
    }

    /// Libellé court des puces (tableau, détail et rapport) : le même partout.
    public var chipLabel: String {
        self == .updateAvailable ? "À mettre à jour" : label
    }

    public static func < (a: FirmwareStatus, b: FirmwareStatus) -> Bool { a.rawValue < b.rawValue }
}

/// Équipement du parc et état de son firmware.
public struct FirmwareDevice: Codable, Hashable, Sendable, Identifiable {
    public var controllerID: UUID
    public var site: String
    public var kind: FirmwareDeviceKind
    public var name: String
    public var model: String
    public var serial: String
    /// Version telle que lue (« S248EP-v7.2.5-build0453,230920 (GA) »).
    public var versionText: String
    public var version: FortiVersion?
    /// Version à installer (même branche pour une FortiGate), si l'état est « mise à jour disponible ».
    public var available: FortiVersion?
    public var availableMaturity: String?
    public var source: FirmwareSource?
    /// FortiGate : version plus récente d'une autre branche (« v7.4.5 »), pour information.
    public var newerBranch: FortiVersion?
    /// Étapes publiées par FortiOS entre la version installée et la version disponible.
    public var upgradePath: [FortiVersion]
    public var status: FirmwareStatus
    /// Connecté à la FortiGate ; nil si inconnu.
    public var connected: Bool?

    public init(controllerID: UUID, site: String, kind: FirmwareDeviceKind, name: String, model: String, serial: String,
                versionText: String, version: FortiVersion? = nil, available: FortiVersion? = nil, availableMaturity: String? = nil,
                source: FirmwareSource? = nil, newerBranch: FortiVersion? = nil, upgradePath: [FortiVersion] = [],
                status: FirmwareStatus = .unknown, connected: Bool? = nil) {
        self.controllerID = controllerID
        self.site = site
        self.kind = kind
        self.name = name
        self.model = model
        self.serial = serial
        self.versionText = versionText
        self.version = version ?? FortiVersion(versionText)
        self.available = available
        self.availableMaturity = availableMaturity
        self.source = source
        self.newerBranch = newerBranch
        self.upgradePath = upgradePath
        self.status = status
        self.connected = connected
    }

    public var id: String { "\(controllerID.uuidString)|\(kind.rawValue)|\(serial.isEmpty ? name : serial)" }

    /// « v7.2.8 », sinon le texte lu, sinon « — ».
    public var versionLabel: String { version?.short ?? (versionText.isEmpty ? "—" : versionText) }

    /// « v7.2.10 », « — ».
    public var availableLabel: String { available?.short ?? "—" }

    /// Codes par lesquels les listes de firmware désignent ce modèle (« S248EP », « FP231F »,
    /// « FS248EPOE »), en majuscules sans tiret.
    public var platformKeys: Set<String> {
        var keys: Set<String> = []
        func add(_ text: String) {
            let k = FirmwareDevice.platformKey(text)
            if k.count >= 3 { keys.insert(k) }
        }
        add(model)
        if let prefix = versionText.components(separatedBy: "-v").first, prefix != versionText { add(prefix) }
        if serial.count >= 6 { add(String(serial.prefix(6))) }
        return keys
    }

    /// « FS-248E-POE » → « FS248EPOE ».
    public static func platformKey(_ text: String) -> String {
        String(text.uppercased().filter { $0.isLetter || $0.isNumber })
    }
}

// MARK: Licences

/// Contrat FortiGuard ou FortiCare lu par monitor/license/status.
public struct FirmwareLicense: Codable, Hashable, Sendable {
    /// Clé de l'API (« antivirus », « ips », « web_filtering », « forticare.hardware »).
    public var key: String
    /// État brut (« licensed », « expired », « expires_soon », « no_license »…).
    public var status: String?
    /// Type (« contract », « fortiguard »…).
    public var type: String?
    /// Version de la base (signatures).
    public var version: String?
    public var expires: Date?

    public init(key: String, status: String? = nil, type: String? = nil, version: String? = nil, expires: Date? = nil) {
        self.key = key
        self.status = status
        self.type = type
        self.version = version
        self.expires = expires
    }

    /// Nom du service en français.
    public var label: String { FirmwareLicense.label(key) }

    public static func label(_ key: String) -> String {
        let parts = key.split(separator: ".").map(String.init)
        let base = parts.first ?? key
        let names: [String: String] = [
            "antivirus": "Antivirus", "ips": "IPS (prévention d’intrusion)", "web_filtering": "Filtrage web",
            "webfiltering": "Filtrage web", "appctrl": "Contrôle des applications", "application_control": "Contrôle des applications",
            "antispam": "Antispam", "industrial_db": "Base industrielle (OT)", "mobile_malware": "Logiciels malveillants mobiles",
            "botnet_ip": "Botnet (adresses IP)", "botnet_domain": "Botnet (domaines)", "forticare": "FortiCare",
            "forticloud": "FortiCloud", "fortisandbox": "FortiSandbox Cloud", "fortiguard": "FortiGuard",
            "outbreak_prevention": "Prévention des éclosions", "sdwan_network_monitor": "Surveillance SD-WAN",
            "internet_service_db": "Base des services Internet", "device_os_id": "Identification des appareils",
            "fortiems_cloud": "FortiClient EMS Cloud", "fortiipam": "FortiIPAM", "fortianalyzer_cloud": "FortiAnalyzer Cloud",
            "firmware_updates": "Mises à jour du firmware", "fortitoken_cloud": "FortiToken Cloud", "dlp": "Prévention des fuites (DLP)",
            "ai_malware_detection": "Détection IA des logiciels malveillants", "security_rating": "Évaluation de la sécurité",
            "iot_detection": "Détection IoT", "forticonverter": "FortiConverter", "fortindr_cloud": "FortiNDR Cloud",
            "inline_casb": "CASB en ligne", "sms": "SMS", "fortitoken": "FortiToken", "vdom": "VDOM",
        ]
        let supports: [String: String] = ["hardware": "matériel", "firmware": "firmware", "enhanced": "assistance améliorée",
                                          "comprehensive": "assistance complète", "support": "assistance", "advanced": "assistance avancée"]
        var text = names[base.lowercased()] ?? humanized(base)
        if parts.count > 1 {
            let sub = parts.dropFirst().joined(separator: " ")
            text += " · " + (supports[sub.lowercased()] ?? humanized(sub).lowercased())
        }
        return text
    }

    static func humanized(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// Seuils des licences (jours avant l'expiration) : orange à 60 jours, rouge à 30.
public struct FirmwareThresholds: Codable, Hashable, Sendable {
    public var warningDays: Int
    public var criticalDays: Int

    public init(warningDays: Int = 60, criticalDays: Int = 30) {
        self.warningDays = max(1, warningDays)
        self.criticalDays = max(0, min(criticalDays, self.warningDays))
    }

    public static let standard = FirmwareThresholds()
}

/// Niveau d'une licence d'après sa date d'expiration et son état.
public enum LicenseLevel: Int, Codable, Sendable, Comparable {
    case notLicensed, unknown, ok, warning, critical, expired

    public var label: String {
        switch self {
        case .notLicensed: return "Sans licence"
        case .unknown: return "Inconnu"
        case .ok: return "Valide"
        case .warning: return "Expire bientôt"
        case .critical: return "Expire très bientôt"
        case .expired: return "Expirée"
        }
    }

    public static func < (a: LicenseLevel, b: LicenseLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Licence d'une FortiGate, avec son site, ses jours restants et son niveau.
public struct FirmwareLicenseUsage: Codable, Hashable, Sendable, Identifiable {
    public var controllerID: UUID
    public var site: String
    public var license: FirmwareLicense
    /// Jours restants (négatif : expirée depuis) ; nil sans date.
    public var daysLeft: Int?
    public var level: LicenseLevel

    public init(controllerID: UUID, site: String, license: FirmwareLicense, daysLeft: Int?, level: LicenseLevel) {
        self.controllerID = controllerID
        self.site = site
        self.license = license
        self.daysLeft = daysLeft
        self.level = level
    }

    public var id: String { "\(controllerID.uuidString)|\(license.key)" }

    /// « 21 j », « expirée depuis 4 j », « — ».
    public var daysLabel: String {
        guard let daysLeft else { return "—" }
        if daysLeft < 0 { return "expirée depuis \(-daysLeft)\u{00A0}j" }
        return "\(daysLeft)\u{00A0}j"
    }
}

// MARK: Lecture

/// Lecture du firmware et des licences d'une FortiGate.
public struct FirmwareReadReport: Codable, Hashable, Sendable {
    public var system: FortiGateSystem?
    /// Version installée selon system/firmware (sinon celle de system/status).
    public var currentFortiOS: FortiVersion?
    /// Images FortiOS disponibles ; nil : liste non lue (FortiGuard injoignable, 403, 404).
    public var availableFortiOS: [FirmwareImage]?
    public var upgradeEdges: [FirmwareUpgradeEdge]
    public var switches: [FortiManagedSwitch]
    public var accessPoints: [FortiManagedAP]
    /// Versions recommandées des FortiSwitch, par code de plateforme ; nil : non lues.
    public var switchCatalog: [String: [FirmwareImage]]?
    /// Versions recommandées des FortiAP, par code de plateforme ; nil : non lues.
    public var apCatalog: [String: [FirmwareImage]]?
    /// Contrats ; nil : non lus.
    public var licenses: [FirmwareLicense]?
    public var notes: [String]
    public var calls: [FortiCallRecord]
    public var readAt: Date

    public init(system: FortiGateSystem? = nil, currentFortiOS: FortiVersion? = nil, availableFortiOS: [FirmwareImage]? = nil,
                upgradeEdges: [FirmwareUpgradeEdge] = [], switches: [FortiManagedSwitch] = [], accessPoints: [FortiManagedAP] = [],
                switchCatalog: [String: [FirmwareImage]]? = nil, apCatalog: [String: [FirmwareImage]]? = nil,
                licenses: [FirmwareLicense]? = nil, notes: [String] = [], calls: [FortiCallRecord] = [], readAt: Date = Date()) {
        self.system = system
        self.currentFortiOS = currentFortiOS
        self.availableFortiOS = availableFortiOS
        self.upgradeEdges = upgradeEdges
        self.switches = switches
        self.accessPoints = accessPoints
        self.switchCatalog = switchCatalog
        self.apCatalog = apCatalog
        self.licenses = licenses
        self.notes = notes
        self.calls = calls
        self.readAt = readAt
    }
}

/// Lecture d'une FortiGate, rattachée à son site.
public struct FirmwareSiteReport: Codable, Hashable, Sendable {
    public var controllerID: UUID
    public var site: String
    public var report: FirmwareReadReport

    public init(controllerID: UUID, site: String, report: FirmwareReadReport) {
        self.controllerID = controllerID
        self.site = site
        self.report = report
    }
}

/// Résumé d'un site (tableau « Tous les sites »).
public struct FirmwareSiteSummary: Codable, Hashable, Sendable, Identifiable {
    public var controllerID: UUID
    public var site: String
    public var hostname: String
    public var model: String
    public var version: String
    public var deviceCount: Int
    public var updates: Int
    public var unknown: Int
    /// Jours restants de la licence la plus proche de l'expiration (hors « sans licence »).
    public var nearestDays: Int?
    public var nearestLicense: String?
    public var licenseLevel: LicenseLevel?
    public var readAt: Date

    public var id: UUID { controllerID }
}

/// Vue d'une ou plusieurs FortiGate (un site ou « Tous les sites »).
public struct FirmwareOverview: Codable, Hashable, Sendable {
    public var sites: [FirmwareSiteSummary]
    public var devices: [FirmwareDevice]
    public var licenses: [FirmwareLicenseUsage]
    public var notes: [String]
    public var readAt: Date?
    public var thresholds: FirmwareThresholds

    public init(sites: [FirmwareSiteSummary] = [], devices: [FirmwareDevice] = [], licenses: [FirmwareLicenseUsage] = [],
                notes: [String] = [], readAt: Date? = nil, thresholds: FirmwareThresholds = .standard) {
        self.sites = sites
        self.devices = devices
        self.licenses = licenses
        self.notes = notes
        self.readAt = readAt
        self.thresholds = thresholds
    }

    public var isEmpty: Bool { sites.isEmpty }
    public var isMultiSite: Bool { sites.count > 1 }

    public var outdated: [FirmwareDevice] { devices.filter { $0.status == .updateAvailable } }

    /// Licences expirées ou sous le seuil d'alerte, la plus urgente d'abord.
    public var alertingLicenses: [FirmwareLicenseUsage] {
        licenses.filter { $0.level >= .warning }.sorted { ($0.daysLeft ?? Int.min, $0.site) < ($1.daysLeft ?? Int.min, $1.site) }
    }
}
