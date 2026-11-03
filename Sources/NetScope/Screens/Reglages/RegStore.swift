import Foundation
import NetScopeCore
import ServiceManagement

// État propre à l'écran Réglages : section affichée, préférences (UserDefaults) et
// identifiants SNMP (Trousseau). AppState n'est pas modifié : les réglages vivent ici.

/// Sections de la colonne de gauche, dans l'ordre du croquis (docs/croquis/Reglages.dc.html).
enum RegSection: String, CaseIterable, Identifiable {
    case general, sites, profils, identifiants, interface, majs, apropos

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "Général"
        case .sites: return "Sites et plages"
        case .profils: return "Profils de scan"
        case .identifiants: return "Identifiants"
        case .interface: return "Interface réseau"
        case .majs: return "Mises à jour"
        case .apropos: return "À propos"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .sites: return "mappin.and.ellipse"
        case .profils: return "dial.medium"
        case .identifiants: return "key"
        case .interface: return "network"
        case .majs: return "arrow.triangle.2.circlepath"
        case .apropos: return "info.circle"
        }
    }

    /// Mots-clés de la recherche de réglages.
    var keywords: String {
        switch self {
        case .general: return "langue thème démarrage ouverture de session barre de menus"
        case .sites: return "cidr plage vlan site passerelle début-fin"
        case .profils: return "threads délai tentatives ports rapide complet personnalisé"
        case .identifiants: return "snmp v2c v3 communauté utilisateur authentification trousseau mot de passe"
        case .interface: return "en0 wi-fi ethernet masque passerelle getifaddrs"
        case .majs: return "version github release bêta stable signature télécharger installer jeton"
        case .apropos: return "version licence oui journaux"
        }
    }
}

/// Environnement d'exécution utile aux réglages.
enum RegEnvironment {
    /// Captures hors écran : ni Trousseau, ni réseau, ni service système.
    static var isSnapshot: Bool { CommandLine.arguments.contains("--snapshot") }
    static var isDemo: Bool { Launcher.isDemo }
    /// Mode sans effet de bord (démonstration ou capture).
    static var isSandboxed: Bool { isSnapshot || isDemo }

    /// Outil de développement : « --reglages-section majs » ouvre cette section (captures).
    static var initialSection: RegSection? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--reglages-section"), index + 1 < arguments.count else { return nil }
        return RegSection(rawValue: arguments[index + 1])
    }

    /// Numéro de build (CFBundleVersion).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }
}

// MARK: - Préférences générales et profil de scan

/// Réglages du profil Personnalisé, lus plus tard par le Scanner (`RegScanTuning.current`).
struct RegScanTuning: Equatable {
    static let defaultPorts = "21,22,23,25,53,80,135,139,443,445,554,631,3389,5900,8080,8443,9100"

    var threads = 128
    /// Délai d'attente par sonde, en millisecondes.
    var timeoutMs = 400
    var retries = 1
    /// Ports TCP du profil Personnalisé (« 22, 80, 8000-8010 »).
    var portsText = RegScanTuning.defaultPorts

    /// Ports valides du texte (entrées invalides ignorées), triés, sans doublon.
    var ports: [UInt16] {
        let tokens = RegScanTuning.tokens(portsText)
        return Array(Set(tokens.compactMap { ScanProfile.parsePorts($0) }.flatMap { $0 })).sorted()
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
    }

    /// Réglages enregistrés (valeurs par défaut sinon).
    static var current: RegScanTuning {
        let defaults = UserDefaults.standard
        var tuning = RegScanTuning()
        if defaults.object(forKey: RegPrefs.Key.threads) != nil { tuning.threads = defaults.integer(forKey: RegPrefs.Key.threads) }
        if defaults.object(forKey: RegPrefs.Key.timeout) != nil { tuning.timeoutMs = defaults.integer(forKey: RegPrefs.Key.timeout) }
        if defaults.object(forKey: RegPrefs.Key.retries) != nil { tuning.retries = defaults.integer(forKey: RegPrefs.Key.retries) }
        if let ports = defaults.string(forKey: RegPrefs.Key.ports) { tuning.portsText = ports }
        return tuning
    }
}

/// Préférences de l'écran Réglages, enregistrées dans UserDefaults à chaque modification.
@MainActor
final class RegPrefs: ObservableObject {
    static let shared = RegPrefs()

    enum Key {
        static let threads = "reglages.scan.threads"
        static let timeout = "reglages.scan.delaiMs"
        static let retries = "reglages.scan.tentatives"
        static let ports = "reglages.scan.ports"
        static let defaultProfile = "reglages.scan.profilParDefaut"
        static let confirmPublic = "reglages.general.confirmerPlagePublique"
    }

    private let defaults: UserDefaults?

    @Published var tuning: RegScanTuning { didSet { saveTuning() } }
    @Published var defaultProfile: ScanProfile { didSet { defaults?.set(defaultProfile.rawValue, forKey: Key.defaultProfile) } }
    @Published var confirmPublicRanges: Bool { didSet { defaults?.set(confirmPublicRanges, forKey: Key.confirmPublic) } }

    /// Ouverture de session (SMAppService) : état lu au système, erreur éventuelle.
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginMessage: String?

    private init() {
        // En capture ou démonstration, rien n'est lu ni écrit.
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        tuning = RegEnvironment.isSandboxed ? RegScanTuning() : RegScanTuning.current
        defaultProfile = defaults?.string(forKey: Key.defaultProfile).flatMap(ScanProfile.init(rawValue:)) ?? .rapide
        confirmPublicRanges = defaults?.object(forKey: Key.confirmPublic) as? Bool ?? true
        refreshLaunchAtLogin()
    }

    private func saveTuning() {
        guard let defaults else { return }
        defaults.set(tuning.threads, forKey: Key.threads)
        defaults.set(tuning.timeoutMs, forKey: Key.timeout)
        defaults.set(tuning.retries, forKey: Key.retries)
        defaults.set(tuning.portsText, forKey: Key.ports)
    }

    func refreshLaunchAtLogin() {
        if RegEnvironment.isSandboxed {
            launchAtLogin = false
            return
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginMessage = "À autoriser dans Réglages Système › Général › Ouverture."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !RegEnvironment.isSandboxed else { return }
        guard UpdInstaller.runningBundle() != nil else {
            launchAtLoginMessage = "Disponible seulement pour l’application installée (.app), pas avec swift run."
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginMessage = nil
        } catch {
            launchAtLoginMessage = "Modification refusée par macOS : \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }
}

// MARK: - Identifiants SNMP (Trousseau)

/// Identifiants SNMP, enregistrés ensemble (JSON) dans le Trousseau : service
/// com.danymenard.netscope.snmp, compte « identifiants ».
struct RegSNMPCredentials: Codable, Equatable {
    enum Level: String, Codable, CaseIterable, Identifiable {
        case noAuthNoPriv, authNoPriv, authPriv
        var id: String { rawValue }
    }

    var community = ""
    var v3User = ""
    var v3Level = Level.authPriv
    var v3AuthProtocol = "SHA-256"
    var v3AuthPassword = ""
    var v3PrivProtocol = "AES-128"
    var v3PrivPassword = ""
    var v3Context = ""

    static let authProtocols = ["MD5", "SHA-1", "SHA-224", "SHA-256", "SHA-384", "SHA-512"]
    static let privProtocols = ["DES", "AES-128", "AES-192", "AES-256"]

    static let keychain = UpdKeychain(service: "com.danymenard.netscope.snmp")
    static let account = "identifiants"

    static func load() -> RegSNMPCredentials? {
        guard !RegEnvironment.isSandboxed, let json = keychain.string(for: account) else { return nil }
        return try? JSONDecoder().decode(RegSNMPCredentials.self, from: Data(json.utf8))
    }

    func save() throws {
        guard !RegEnvironment.isSandboxed else { return }
        let data = try JSONEncoder().encode(self)
        try RegSNMPCredentials.keychain.set(String(decoding: data, as: UTF8.self), for: RegSNMPCredentials.account)
    }

    static func erase() throws {
        guard !RegEnvironment.isSandboxed else { return }
        try keychain.delete(account)
    }

    /// Nombre d'identifiants renseignés (v2c, v3).
    var configuredCount: Int {
        (community.isEmpty ? 0 : 1) + (v3User.isEmpty ? 0 : 1)
    }
}
