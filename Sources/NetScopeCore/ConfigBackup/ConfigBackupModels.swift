import Foundation

// Note 40 (0.31.0) : sauvegarde des configurations. FortiGate par l'API REST (GET, jeton du
// site), switchs par SSH (commandes de lecture seulement), historique par site et équipement,
// comparaison avant/après. Ce fichier : types d'équipement, commandes permises, réglages.

/// Type d'équipement dont la configuration est sauvegardée, et la façon de la lire.
public enum ConfigDeviceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case fortigate, cisco, aruba, fortiswitch, mikrotik

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fortigate: return "FortiGate"
        case .cisco: return "Cisco IOS"
        case .aruba: return "HPE Aruba"
        case .fortiswitch: return "FortiSwitch"
        case .mikrotik: return "MikroTik"
        }
    }

    /// FortiGate : API REST ; les switchs : SSH.
    public var usesAPI: Bool { self == .fortigate }

    /// Commandes envoyées par SSH, toutes en lecture (vérifiées par `ConfigBackupCommands`).
    public var sshCommands: [String] {
        switch self {
        case .fortigate: return []
        case .cisco: return ["terminal length 0", "show running-config", "exit"]
        case .aruba: return ["show running-config"]
        case .fortiswitch: return ["show full-configuration"]
        case .mikrotik: return ["/export"]
        }
    }

    /// Cisco : plusieurs commandes, envoyées sur l'entrée d'un shell (une par ligne). Les autres :
    /// une seule commande, passée à ssh (canal « exec »).
    public var usesShellInput: Bool { sshCommands.count > 1 }

    /// Commandes affichées (« terminal length 0 » puis « show running-config »).
    public var commandSummary: String {
        usesAPI ? "GET /api/v2/monitor/system/config/backup?scope=global"
            : sshCommands.filter { $0 != "exit" }.joined(separator: "\u{00A0}» puis «\u{00A0}")
    }

    /// Type probable d'après la description SNMP (sysDescr) et le nom du switch.
    public static func detect(descr: String, name: String = "") -> ConfigDeviceKind? {
        let text = (descr + " " + name).lowercased()
        if text.contains("fortiswitch") || text.hasPrefix("fs-") { return .fortiswitch }
        if text.contains("fortigate") || text.contains("fortios") { return .fortigate }
        if text.contains("routeros") || text.contains("mikrotik") { return .mikrotik }
        if text.contains("aruba") || text.contains("procurve") || text.contains("hewlett") || text.contains("hpe ") || text.hasPrefix("hp ") || text.contains(" hp ") { return .aruba }
        if text.contains("cisco") || text.contains("ios xe") || text.contains("ios software") { return .cisco }
        return nil
    }
}

/// Liste fermée des commandes permises : rien qui modifie l'équipement, rien qui écrive un
/// fichier dessus, aucun enchaînement (« ; », « | », retour à la ligne).
public enum ConfigBackupCommands {
    static let exact: Set<String> = ["terminal length 0", "exit", "/export", "/export terse", "/export verbose"]
    static let readPrefixes = ["show running-config", "show full-configuration", "show configuration", "show startup-config"]

    public static func isReadOnly(_ command: String) -> Bool {
        let folded = command.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard !folded.isEmpty, folded.count < 80 else { return false }
        if folded.contains(where: { ";|&><`$\n\r\\".contains($0) }) { return false }
        if exact.contains(folded) { return true }
        return readPrefixes.contains { folded == $0 || folded.hasPrefix($0 + " ") }
            && !folded.contains(" file") && !folded.contains("tftp") && !folded.contains("scp")
    }

    /// Vrai si toutes les commandes du type sont permises (vérifié avant chaque connexion).
    public static func allReadOnly(_ kind: ConfigDeviceKind) -> Bool {
        kind.sshCommands.allSatisfy(isReadOnly)
    }
}

/// Équipement d'un site dont la configuration est gardée.
public struct ConfigEquipment: Identifiable, Hashable, Sendable {
    /// Nom du dossier de l'historique (« SW-CORE-01 », « FortiGate-Siege »).
    public var id: String
    public var name: String
    public var host: String
    public var kind: ConfigDeviceKind?
    /// FortiGate : contrôleur du site (jeton au Trousseau).
    public var controllerID: UUID?
    /// Switch : identifiant SSH retenu (Réglages › Identifiants), mot de passe au Trousseau.
    public var credentialID: UUID?

    public init(name: String, host: String, kind: ConfigDeviceKind?, controllerID: UUID? = nil, credentialID: UUID? = nil) {
        self.id = Self.folderName(name: name, host: host)
        self.name = name
        self.host = host
        self.kind = kind
        self.controllerID = controllerID
        self.credentialID = credentialID
    }

    /// Nom de dossier sûr : lettres sans accents, chiffres, « - », « _ », « . » (jamais « .. » ni
    /// « / ») ; l'adresse quand le nom est vide.
    public static func folderName(name: String, host: String) -> String {
        func clean(_ text: String) -> String {
            let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_CA"))
            var out = ""
            for scalar in folded.unicodeScalars {
                let c = Character(scalar)
                if scalar.isASCII, c.isLetter || c.isNumber || c == "_" || c == "." || c == "-" { out.append(c) } else { out.append("-") }
            }
            while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
            while out.contains("..") { out = out.replacingOccurrences(of: "..", with: ".") }
            out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
            return String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        let byName = clean(name)
        if !byName.isEmpty { return byName }
        let byHost = clean(host)
        return byHost.isEmpty ? "equipement" : byHost
    }
}

/// Réglages de la sauvegarde d'un site (configurations/reglages.json) : jamais de secret.
public struct ConfigBackupSettings: Codable, Equatable, Sendable {
    public struct Equipment: Codable, Equatable, Sendable {
        public var kind: ConfigDeviceKind?
        public var credentialID: UUID?
        public init(kind: ConfigDeviceKind? = nil, credentialID: UUID? = nil) {
            self.kind = kind
            self.credentialID = credentialID
        }
    }

    /// Association d'un compte à une FortiGate : l'adresse y est retenue, un changement d'adresse
    /// demande un nouveau choix (un mot de passe ne suit pas tout seul vers un autre équipement).
    public struct CLIAccount: Codable, Equatable, Sendable {
        public var credentialID: UUID
        public var host: String
        public init(credentialID: UUID, host: String) {
            self.credentialID = credentialID
            self.host = host
        }
    }

    /// Compte retenu pour cette FortiGate, seulement à cette adresse.
    public func cliCredentialID(controllerID: UUID, host: String) -> UUID? {
        guard let account = cliAccounts[controllerID.uuidString], account.host == host else { return nil }
        return account.credentialID
    }

    public static let defaultKeep = 30
    public static let keepRange = 1...500

    /// Nombre de versions gardées par équipement (les plus anciennes sont retirées).
    public var keep: Int
    /// Type et identifiant SSH choisis, par équipement (clé : nom du dossier).
    public var equipment: [String: Equipment]
    /// Note 111 : compte SSH de la CLI de chaque FortiGate (clé : identifiant du contrôleur).
    public var cliAccounts: [String: CLIAccount]
    /// Dernière vérification (même sans changement), par équipement.
    public var lastChecked: [String: Date]
    /// Changements signalés et pas encore vus : date de la version qui diffère, par équipement.
    public var pendingChanges: [String: Date]

    public init(keep: Int = ConfigBackupSettings.defaultKeep, equipment: [String: Equipment] = [:],
                lastChecked: [String: Date] = [:], pendingChanges: [String: Date] = [:], cliAccounts: [String: CLIAccount] = [:]) {
        self.keep = Self.clampedKeep(keep)
        self.equipment = equipment
        self.cliAccounts = cliAccounts
        self.lastChecked = lastChecked
        self.pendingChanges = pendingChanges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keep = Self.clampedKeep(try c.decodeIfPresent(Int.self, forKey: .keep) ?? Self.defaultKeep)
        equipment = try c.decodeIfPresent([String: Equipment].self, forKey: .equipment) ?? [:]
        cliAccounts = try c.decodeIfPresent([String: CLIAccount].self, forKey: .cliAccounts) ?? [:]
        lastChecked = try c.decodeIfPresent([String: Date].self, forKey: .lastChecked) ?? [:]
        pendingChanges = try c.decodeIfPresent([String: Date].self, forKey: .pendingChanges) ?? [:]
    }

    public static func clampedKeep(_ value: Int) -> Int { min(max(value, keepRange.lowerBound), keepRange.upperBound) }
}

/// Sauvegarde impossible : la cause et la marche à suivre.
public struct ConfigBackupError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case account, launch, unreachable, authentication, hostKey, unknownHostKey, timeout
        case emptyOutput, commandRejected, notReadOnly, forbidden, apiUnsupported, api, notReady, unknownKind
    }

    public var kind: Kind
    public var detail: String
    public var fingerprint: String?

    public init(kind: Kind, detail: String, fingerprint: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.fingerprint = fingerprint
    }

    public var title: String {
        switch kind {
        case .account: return "Identifiant SSH à choisir"
        case .launch: return "ssh n’a pas pu être lancé"
        case .unreachable: return "Équipement injoignable"
        case .authentication: return "Connexion SSH refusée"
        case .hostKey: return "Empreinte SSH changée"
        case .unknownHostKey: return "Équipement SSH inconnu"
        case .timeout: return "Délai dépassé"
        case .emptyOutput: return "Configuration vide"
        case .commandRejected: return "Commande refusée par l’équipement"
        case .notReadOnly: return "Commande bloquée"
        case .forbidden: return "Sauvegarde refusée au jeton"
        case .apiUnsupported: return "Sauvegarde par l’API non offerte"
        case .api: return "Réponse inattendue de la FortiGate"
        case .notReady: return "FortiGate du site non prête"
        case .unknownKind: return "Type d’équipement à choisir"
        }
    }

    public var advice: String {
        switch kind {
        case .account:
            return "Choisissez un identifiant SSH (Réglages › Identifiants) pour cet équipement\u{00A0}; son mot de passe est lu au Trousseau."
        case .launch: return "NetScope utilise /usr/bin/ssh de macOS."
        case .unreachable, .timeout:
            return "Vérifiez que l’équipement est allumé et que SSH (port 22 par défaut) est permis depuis ce Mac."
        case .authentication:
            return "Vérifiez l’utilisateur et la clé de l’identifiant, ou enregistrez son mot de passe au Trousseau (Réglages › Identifiants)."
        case .hostKey:
            return "La clé SSH de l’équipement ne correspond plus à ~/.ssh/known_hosts. Vérifiez qu’il s’agit du même équipement avant de retirer l’ancienne empreinte («\u{00A0}ssh-keygen -R hôte\u{00A0}»)."
        case .unknownHostKey:
            return "L’équipement n’est pas encore dans ~/.ssh/known_hosts. Vérifiez l’empreinte, puis acceptez-la\u{00A0}: aucun mot de passe n’a été envoyé."
        case .emptyOutput:
            return "L’équipement n’a rien renvoyé. Vérifiez le type choisi et les droits du compte (lecture de la configuration)."
        case .commandRejected:
            return "Le type choisi ne correspond peut-être pas à l’équipement, ou le compte n’a pas le niveau de privilège requis (Cisco\u{00A0}: privilège 15)."
        case .notReadOnly: return "NetScope n’envoie que des commandes de lecture."
        case .forbidden:
            return "Dans FortiOS, donnez au profil d’administrateur du jeton l’accès «\u{00A0}Système › Configuration\u{00A0}» (sysgrp). Certaines versions exigent le profil super_admin pour la sauvegarde. NetScope ne fait qu’une lecture (GET)."
        case .apiUnsupported:
            return "Cette version de FortiOS n’offre pas la sauvegarde par GET. Faites-la depuis l’interface de la FortiGate (Système › Configuration › Sauvegarde)."
        case .api, .notReady:
            return "Vérifiez la FortiGate du site dans l’onglet Switchs (adresse, jeton, empreinte du certificat)."
        case .unknownKind: return "Choisissez Cisco IOS, HPE Aruba, FortiSwitch ou MikroTik dans la colonne Type."
        }
    }
}
