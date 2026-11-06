import Foundation

// Note 89 : test de câble demandé au switch (réflectométrie, TDR). Le Mac ne mesure rien : il
// envoie au switch UNE commande d'une liste fermée (par marque), sur un port validé strictement,
// puis analyse la sortie. Le test peut couper le lien quelques secondes : réglage désactivé par
// défaut, mêmes garde-fous que les actions sur les ports (note 73) et confirmation.

/// Marque de switch dont NetScope sait demander un test de câble.
public enum CableTestVendor: String, Codable, CaseIterable, Sendable {
    /// Cisco IOS / IOS-XE : « test cable-diagnostics tdr interface … » puis « show … ».
    case cisco
    /// HPE Aruba (ProCurve, AOS-S) : « virtual-cable-test ethernet … ».
    case aruba
    /// FortiSwitch en SSH : « diagnose switch physical-ports cable-diag … ».
    case fortiSwitch

    public var label: String {
        switch self {
        case .cisco: return "Cisco"
        case .aruba: return "HPE Aruba"
        case .fortiSwitch: return "FortiSwitch"
        }
    }

    /// Marque d'après le type d'équipement des sauvegardes de configuration (note 40).
    public static func from(_ kind: ConfigDeviceKind?) -> CableTestVendor? {
        switch kind {
        case .cisco?: return .cisco
        case .aruba?: return .aruba
        case .fortiswitch?: return .fortiSwitch
        // FortiGate en SSH : pas de test de câble (refus « marque non prise en charge ») ; un FortiSwitch
        // géré par une FortiGate passe par le canal REST (`target.fortiGate`), sans marque.
        default: return nil
        }
    }
}

/// État d'une paire du câble.
public enum CablePairStatus: String, Codable, Sendable, CaseIterable {
    case ok, open, short, impedance, unknown

    public var label: String {
        switch self {
        case .ok: return "correcte"
        case .open: return "ouverte"
        case .short: return "court-circuit"
        case .impedance: return "mal terminée"
        case .unknown: return "non mesurée"
        }
    }

    public var isFault: Bool { self == .open || self == .short || self == .impedance }

    /// Mot de la sortie d'un switch → état (« Normal », « Open », « OPEN », « Short », « Impedance Mismatch »…).
    public static func parse(_ word: String) -> CablePairStatus? {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if w.isEmpty { return nil }
        if w.hasPrefix("normal") || w == "ok" || w == "good" || w.hasPrefix("pass") || w == "terminated" { return .ok }
        if w.hasPrefix("open") { return .open }
        if w.hasPrefix("short") || w.contains("crosstalk") { return .short }
        if w.contains("impedance") || w.contains("mismatch") || w.hasPrefix("imp") { return .impedance }
        if w.contains("not completed") || w.contains("not supported") || w.hasPrefix("unknown") || w.hasPrefix("fail")
            || w == "n/a" || w == "-" { return .unknown }
        return nil
    }
}

/// Résultat d'une paire (1 à 4 : A à D chez Cisco et FortiSwitch ; 0 : paire non précisée).
public struct CablePairResult: Codable, Hashable, Sendable {
    public var pair: Int
    public var status: CablePairStatus
    /// Distance du défaut (paire en défaut) ou longueur mesurée (paire correcte), en mètres.
    public var meters: Int?

    public init(pair: Int, status: CablePairStatus, meters: Int? = nil) {
        self.pair = pair
        self.status = status
        self.meters = meters
    }

    /// « paire 3 coupée à 27 m », « paire 1 correcte (31 m) ».
    public var summary: String {
        let nb = "\u{00A0}"
        let distance = meters.map { "\($0)\(nb)m" }
        // AOS-S ne dit pas quelle paire est en défaut (0) : « câble coupé à 27 m ».
        let subject = pair == 0 ? "câble" : "paire \(pair)"
        switch status {
        case .open: return subject + (pair == 0 ? " coupé" : " coupée") + (distance.map { " à \($0)" } ?? "")
        case .short: return subject + " en court-circuit" + (distance.map { " à \($0)" } ?? "")
        case .impedance: return subject + (pair == 0 ? " mal terminé" : " mal terminée") + (distance.map { " à \($0)" } ?? "")
        case .ok: return subject + (pair == 0 ? " correct" : " correcte") + (distance.map { " (\($0))" } ?? "")
        case .unknown: return subject + (pair == 0 ? " non mesuré" : " non mesurée")
        }
    }
}

/// Résultat d'un test de câble (gardé dans l'historique du port et ajouté au bilan de raccordement).
public struct CableTestResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var switchName: String
    public var switchHost: String
    public var portName: String
    public var vendor: CableTestVendor
    /// « SSH (Cisco) », « FortiGate «  Siège  » (API REST) ».
    public var channel: String
    public var pairs: [CablePairResult]
    /// Message d'échec (connexion, commande refusée, sortie illisible) ; nil si le test a abouti.
    public var error: String?

    public init(id: UUID = UUID(), date: Date, switchName: String, switchHost: String, portName: String,
                vendor: CableTestVendor, channel: String, pairs: [CablePairResult], error: String? = nil) {
        self.id = id
        self.date = date
        self.switchName = switchName
        self.switchHost = switchHost
        self.portName = portName
        self.vendor = vendor
        self.channel = channel
        self.pairs = pairs.sorted { $0.pair < $1.pair }
        self.error = error
    }

    public var faults: [CablePairResult] { pairs.filter { $0.status.isFault } }

    /// Longueur approximative du câble : la plus grande longueur des paires correctes (nil sinon).
    public var approximateLength: Int? {
        pairs.filter { $0.status == .ok }.compactMap(\.meters).filter { $0 > 0 }.max()
    }

    /// Verdict pour le bilan de raccordement.
    public var status: LinkCheckStatus {
        if error != nil || pairs.isEmpty { return .skipped }
        if !faults.isEmpty { return .failure }
        if pairs.allSatisfy({ $0.status == .ok }) { return .ok }
        return .warning
    }

    /// « Paire 3 coupée à 27 m », « Câble correct · environ 31 m », « Test impossible ».
    public var headline: String {
        let nb = "\u{00A0}"
        if let error { return "Test impossible\(nb): \(error)" }
        if pairs.isEmpty { return "Aucune paire mesurée" }
        if !faults.isEmpty {
            let text = faults.map(\.summary).joined(separator: ", ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        if pairs.allSatisfy({ $0.status == .ok }) {
            return "Câble correct" + (approximateLength.map { " · environ \($0)\(nb)m" } ?? "")
        }
        let unknown = pairs.filter { $0.status == .unknown }.map { String($0.pair) }
        return "Mesure incomplète (paire\(unknown.count > 1 ? "s" : "") \(unknown.joined(separator: ", ")))"
    }

    /// « SW-CORE-01 · Gi1/0/12 ».
    public var portLabel: String { "\(switchName) · \(portName)" }
}

/// Moyen par lequel le test est demandé.
public enum CableTestChannel: Equatable, Sendable {
    /// SSH vers le switch (identifiant de Réglages › Identifiants, mot de passe au Trousseau).
    case ssh(host: String, vendor: CableTestVendor)
    /// FortiSwitch géré : API REST de la FortiGate (lecture du diagnostic de câble).
    case fortiGate(controllerID: UUID, controllerName: String, switchID: String)

    public var label: String {
        switch self {
        case .ssh(_, let vendor): return "SSH (\(vendor.label))"
        case .fortiGate(_, let name, _): return "FortiGate «\u{00A0}\(name)\u{00A0}» (API REST)"
        }
    }
}

/// Raison de refuser un test de câble.
public enum CableTestRefusal: Equatable, Sendable {
    case disabled
    case uplink
    case thisMac
    case readOnlyController(String)
    case unsupportedVendor(String?)
    case invalidPort(String)
    case noSSHAccount
    case fortiGateNotReady(String)
    case fortiSwitchNotFound
    case busy

    public var message: String {
        let nb = "\u{00A0}"
        switch self {
        case .disabled:
            return "Test de câble désactivé\(nb): activez «\(nb)Autoriser le test de câble (TDR)\(nb)» dans Réglages › Switchs."
        case .uplink:
            return "Ce port est un uplink\(nb): le test couperait le lien de tous les appareils situés derrière."
        case .thisMac:
            return "Ce Mac passe par ce port\(nb): NetScope perdrait sa connexion pendant le test."
        case .readOnlyController(let brand):
            return "Switch géré par \(brand)\(nb): lecture seule, aucun test de câble. Lancez-le depuis la console \(brand)."
        case .unsupportedVendor(let name):
            return "Marque non prise en charge" + (name.map { " (\($0))" } ?? "")
                + "\(nb): NetScope sait demander le test aux switchs Cisco, HPE Aruba et FortiSwitch. Choisissez le type de l’équipement dans Switchs et ports › Configurations."
        case .invalidPort(let name):
            return "Nom de port «\(nb)\(name)\(nb)» refusé pour cette marque\(nb): aucune commande n’est envoyée."
        case .noSSHAccount:
            return "Aucun identifiant SSH pour ce switch\(nb): ajoutez-en un dans Réglages › Identifiants."
        case .fortiGateNotReady(let reason):
            return "FortiGate non prête\(nb): \(reason)"
        case .fortiSwitchNotFound:
            return "FortiSwitch introuvable dans la dernière lecture de la FortiGate de son site."
        case .busy:
            return "Un test est déjà en cours sur ce port."
        }
    }

    public var isRiskyPort: Bool { self == .uplink || self == .thisMac }
}

/// Décision pour un test de câble.
public struct CableTestDecision: Equatable, Sendable {
    public var refusals: [CableTestRefusal]
    public var warnings: [CableTestRefusal]
    public var channel: CableTestChannel?

    public var isAllowed: Bool { refusals.isEmpty && channel != nil }
    public var reason: String? { refusals.first?.message }
}

/// Garde-fous du test de câble : rien n'est envoyé sans une décision permise.
public enum CableTestGuard {
    /// `vendor` : marque du switch (nil : inconnue) ; `hasSSHAccount` : un identifiant SSH existe
    /// pour ce switch ; `fortiGateProblem` : raison pour laquelle sa FortiGate ne peut servir.
    public static func decide(target: PortActionTarget, settings: PortActionSettings, vendor: CableTestVendor?,
                              vendorName: String? = nil, hasSSHAccount: Bool, fortiGateProblem: String?,
                              busy: Bool = false) -> CableTestDecision {
        var refusals: [CableTestRefusal] = []
        var warnings: [CableTestRefusal] = []
        if !settings.cableTestEnabled { refusals.append(.disabled) }
        if busy { refusals.append(.busy) }
        for risky in [CableTestRefusal.uplink, .thisMac] {
            let applies = risky == .uplink ? target.isUplink : target.isThisMacPort
            guard applies else { continue }
            if settings.allowRiskyPorts { warnings.append(risky) } else { refusals.append(risky) }
        }
        if let brand = target.readOnlyController {
            refusals.append(.readOnlyController(brand))
            return CableTestDecision(refusals: refusals, warnings: warnings, channel: nil)
        }
        var channel: CableTestChannel?
        if let forti = target.fortiGate {
            if !CableTestCommands.isValidPort(target.portName, vendor: .fortiSwitch) { refusals.append(.invalidPort(target.portName)) }
            if let fortiGateProblem { refusals.append(.fortiGateNotReady(fortiGateProblem)) }
            else { channel = .fortiGate(controllerID: forti.controllerID, controllerName: forti.controllerName, switchID: forti.mkey) }
        } else if target.viaFortiGate {
            refusals.append(.fortiSwitchNotFound)
        } else if let vendor {
            if !CableTestCommands.isValidPort(target.portName, vendor: vendor) { refusals.append(.invalidPort(target.portName)) }
            if let host = target.usableSNMPHost {
                if hasSSHAccount { channel = .ssh(host: host.description, vendor: vendor) } else { refusals.append(.noSSHAccount) }
            } else {
                refusals.append(.noSSHAccount)
            }
        } else {
            refusals.append(.unsupportedVendor(vendorName))
        }
        return CableTestDecision(refusals: refusals, warnings: warnings, channel: refusals.isEmpty ? channel : nil)
    }
}
