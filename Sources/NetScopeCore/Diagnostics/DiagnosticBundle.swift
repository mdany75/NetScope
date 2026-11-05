import Foundation

/// Contenu d'un diagnostic exporté (note 35), rassemblé par l'app puis mis en archive ici.
/// Rien n'y entre sans passer par `SecretMasker` : journal, résumé, sites, réglages et rapports
/// de plantage sont masqués au moment de l'écriture de l'archive.
public struct DiagnosticInput: Sendable {
    /// Interface réseau active, telle que le Mac la voit.
    public struct Interface: Sendable, Equatable {
        public var name: String
        public var kind: String
        public var address: String
        public var netmask: String
        public var gateway: String?

        public init(name: String, kind: String, address: String, netmask: String, gateway: String? = nil) {
            self.name = name
            self.kind = kind
            self.address = address
            self.netmask = netmask
            self.gateway = gateway
        }
    }

    /// Site, sans identifiants : nom, plages, nombre de FortiGate et de switchs.
    public struct SiteSummary: Codable, Sendable, Equatable {
        public var name: String
        public var ranges: [String]
        public var fortiGateCount: Int
        public var switchCount: Int
        public var lastScan: Date?
        public var inventoryCount: Int?
        public var isActive: Bool

        public init(name: String, ranges: [String], fortiGateCount: Int, switchCount: Int,
                    lastScan: Date? = nil, inventoryCount: Int? = nil, isActive: Bool = false) {
            self.name = name
            self.ranges = ranges
            self.fortiGateCount = fortiGateCount
            self.switchCount = switchCount
            self.lastScan = lastScan
            self.inventoryCount = inventoryCount
            self.isActive = isActive
        }
    }

    /// Rapport de plantage joint : nom du fichier et contenu brut.
    public struct CrashFile: Sendable, Equatable {
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public var generatedAt: Date
    public var appVersion: String
    public var build: String
    public var macOSVersion: String
    public var macModel: String
    public var processorCount: Int
    public var memoryBytes: UInt64
    public var uptime: TimeInterval
    public var interfaces: [Interface]
    public var sites: [SiteSummary]
    /// Préférences de NetScope (UserDefaults) ; les clés secrètes sont retirées par `DiagnosticBundle`.
    public var settings: [String: String]
    public var logEntries: [AppLogEntry]
    public var crashReports: [CrashFile]
    /// Mode démonstration : noté dans le résumé.
    public var isDemo: Bool

    public init(generatedAt: Date = Date(), appVersion: String, build: String, macOSVersion: String, macModel: String,
                processorCount: Int = 0, memoryBytes: UInt64 = 0, uptime: TimeInterval = 0,
                interfaces: [Interface] = [], sites: [SiteSummary] = [], settings: [String: String] = [:],
                logEntries: [AppLogEntry] = [], crashReports: [CrashFile] = [], isDemo: Bool = false) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.build = build
        self.macOSVersion = macOSVersion
        self.macModel = macModel
        self.processorCount = processorCount
        self.memoryBytes = memoryBytes
        self.uptime = uptime
        self.interfaces = interfaces
        self.sites = sites
        self.settings = settings
        self.logEntries = logEntries
        self.crashReports = crashReports
        self.isDemo = isDemo
    }
}

/// Archive « diagnostic » (.zip, par `BackupZip`).
public enum DiagnosticBundle {
    /// Taille maximale d'un rapport de plantage joint ; au-delà, il est tronqué.
    public static let maxCrashBytes = 2_000_000
    /// Nombre maximal de rapports joints (les plus récents).
    public static let maxCrashReports = 10
    /// Taille maximale d'une valeur de réglage exportée.
    static let maxSettingLength = 400

    /// Nom de fichier proposé : « NetScope-diagnostic-2026-11-05-1402.zip ».
    public static func suggestedFileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "NetScope-diagnostic-\(formatter.string(from: date)).zip"
    }

    /// Fichiers de l'archive, déjà masqués.
    public static func entries(_ input: DiagnosticInput) -> [BackupZip.Entry] {
        var files: [(String, String)] = [
            ("LISEZMOI.txt", readme(input)),
            ("systeme.txt", systemSummary(input)),
            ("journal.txt", AppLog(capacity: 1).exportText(input.logEntries)),
            ("sites.json", sitesJSON(input.sites)),
            ("reglages.json", settingsJSON(input.settings)),
        ]
        for crash in input.crashReports.prefix(maxCrashReports) {
            var data = crash.data
            var suffix = ""
            if data.count > maxCrashBytes {
                data = data.prefix(maxCrashBytes)
                suffix = "\n[… rapport tronqué à \(maxCrashBytes) octets]\n"
            }
            let safeName = crash.name.replacingOccurrences(of: "/", with: "_")
            files.append(("plantages/\(safeName)", String(decoding: data, as: UTF8.self) + suffix))
        }
        // Dernière barrière : tout le texte repasse par le masqueur.
        return files.map { BackupZip.Entry(path: $0.0, data: Data(SecretMasker.mask($0.1).utf8)) }
    }

    /// Archive .zip complète.
    public static func archive(_ input: DiagnosticInput) -> Data {
        BackupZip.archive(entries(input), date: input.generatedAt)
    }

    // MARK: Parties

    static func readme(_ input: DiagnosticInput) -> String {
        """
        Diagnostic de NetScope \(input.appVersion) (build \(input.build)), produit le \(frenchDate(input.generatedAt)).

        Contenu :
        - systeme.txt : version de NetScope et de macOS, modèle du Mac, interfaces actives
          (adresses publiques abrégées) ;
        - journal.txt : journal de l’app (\(input.logEntries.count) entrée\(input.logEntries.count > 1 ? "s" : "")), secrets masqués ;
        - sites.json : sites et plages, sans identifiants ni notes ;
        - reglages.json : réglages non secrets ;
        - plantages/ : rapports de plantage de NetScope des 30 derniers jours (\(input.crashReports.prefix(maxCrashReports).count)).

        Aucun mot de passe, jeton, communauté SNMP ni clé d’API n’y figure : ils restent dans le
        Trousseau macOS, et tout le texte de cette archive a été passé au masqueur de secrets.
        """ + "\n"
    }

    static func systemSummary(_ input: DiagnosticInput) -> String {
        var lines = [
            "NetScope : \(input.appVersion) (build \(input.build))\(input.isDemo ? " — mode démonstration" : "")",
            "macOS : \(input.macOSVersion)",
            "Modèle du Mac : \(input.macModel)",
        ]
        if input.processorCount > 0 { lines.append("Processeurs : \(input.processorCount)") }
        if input.memoryBytes > 0 { lines.append("Mémoire : \(input.memoryBytes / 1_073_741_824) Go") }
        if input.uptime > 0 { lines.append("Allumé depuis : \(duration(input.uptime))") }
        lines.append("Produit le : \(frenchDate(input.generatedAt))")
        lines.append("")
        lines.append("Interfaces actives :")
        if input.interfaces.isEmpty { lines.append("  (aucune)") }
        for interface in input.interfaces {
            var line = "  \(interface.name) (\(interface.kind)) : \(interface.address) / \(interface.netmask)"
            if let gateway = interface.gateway { line += ", passerelle \(gateway)" }
            lines.append(line)
        }
        lines.append("")
        lines.append("Sites : \(input.sites.count)")
        lines.append("Rapports de plantage joints : \(input.crashReports.prefix(maxCrashReports).count)")
        let errors = input.logEntries.filter { $0.level == .error }.count
        let warnings = input.logEntries.filter { $0.level == .warning }.count
        lines.append("Journal : \(input.logEntries.count) entrées, \(errors) erreur\(errors > 1 ? "s" : ""), \(warnings) avertissement\(warnings > 1 ? "s" : "")")
        // Adresses publiques abrégées dans le résumé (le reste de l'archive garde les adresses
        // privées, utiles au diagnostic).
        return SecretMasker.maskPublicIPv4(lines.joined(separator: "\n")) + "\n"
    }

    static func sitesJSON(_ sites: [DiagnosticInput.SiteSummary]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sites) else { return "[]\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Réglages sans les clés secrètes (mot de passe, jeton, communauté…) ; valeurs longues abrégées.
    static func settingsJSON(_ settings: [String: String]) -> String {
        var kept: [String: String] = [:]
        for (key, value) in settings where !SecretMasker.isSecretKey(key) {
            kept[key] = value.count > maxSettingLength ? String(value.prefix(maxSettingLength)) + "…" : value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(kept) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func frenchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMMM yyyy 'à' HH:mm:ss (ZZZZZ)"
        return formatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) j \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }
}
