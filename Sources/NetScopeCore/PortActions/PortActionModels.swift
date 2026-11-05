import Foundation

// Note 73 : actions sur un port de switch (cycle PoE, redémarrage du port). C'est la PREMIÈRE
// fonction de NetScope qui modifie un équipement : tout passe par `PortActionGuard`, qui refuse
// par défaut (réglage désactivé, uplink, port de ce Mac, port sans PoE…). Ce fichier ne fait que
// décrire et décider ; l'envoi est dans PortActionFortiGate.swift et PortActionSNMP.swift.

/// Action demandée sur un port.
public enum PortActionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Couper puis rallumer le PoE du port (l'appareil alimenté redémarre).
    case poeCycle
    /// Redémarrer le port (lien coupé puis rétabli) : FortiSwitch géré par une FortiGate seulement.
    case portRestart

    public var id: String { rawValue }

    /// Libellé du bouton.
    public var label: String {
        switch self {
        case .poeCycle: return "Couper et rallumer le PoE"
        case .portRestart: return "Redémarrer le port"
        }
    }

    /// Libellé court (journal, chronologie).
    public var shortLabel: String {
        switch self {
        case .poeCycle: return "Cycle PoE"
        case .portRestart: return "Redémarrage du port"
        }
    }

    /// Symbole SF du bouton.
    public var symbol: String {
        switch self {
        case .poeCycle: return "bolt.badge.clock"
        case .portRestart: return "arrow.clockwise"
        }
    }
}

/// Réglages des actions sur les ports (Réglages › Switchs). Aucun secret : les identifiants
/// d'écriture sont au Trousseau.
public struct PortActionSettings: Codable, Equatable, Sendable {
    /// « Autoriser les actions sur les ports » : DÉSACTIVÉ par défaut.
    public var enabled: Bool
    /// Permettre aussi un uplink ou le port de ce Mac (déconseillé ; désactivé par défaut). Même
    /// permis, ces ports exigent une case cochée dans la feuille de confirmation.
    public var allowRiskyPorts: Bool
    /// Durée de la coupure du PoE en SNMP, en secondes (5 par défaut).
    public var poeOffSeconds: Int
    /// Attente maximale du retour de l'appareil après l'action, en secondes.
    public var followUpSeconds: Int
    /// Durée de la coupure du lien d'un FortiSwitch (« bounce-port »), en secondes.
    public var bounceSeconds: Int

    public static let offRange = 2...60
    public static let followUpRange = 30...600
    public static let bounceRange = 1...30
    public static let defaultOffSeconds = 5

    public init(enabled: Bool = false, allowRiskyPorts: Bool = false, poeOffSeconds: Int = PortActionSettings.defaultOffSeconds,
                followUpSeconds: Int = 180, bounceSeconds: Int = 5) {
        self.enabled = enabled
        self.allowRiskyPorts = allowRiskyPorts
        self.poeOffSeconds = poeOffSeconds
        self.followUpSeconds = followUpSeconds
        self.bounceSeconds = bounceSeconds
    }

    /// Réglages d'origine : tout est refusé.
    public static let `default` = PortActionSettings()

    /// Valeurs ramenées dans leurs bornes (un fichier modifié à la main ne fait pas couper 1 h).
    public var clamped: PortActionSettings {
        var copy = self
        copy.poeOffSeconds = min(max(poeOffSeconds, Self.offRange.lowerBound), Self.offRange.upperBound)
        copy.followUpSeconds = min(max(followUpSeconds, Self.followUpRange.lowerBound), Self.followUpRange.upperBound)
        copy.bounceSeconds = min(max(bounceSeconds, Self.bounceRange.lowerBound), Self.bounceRange.upperBound)
        return copy
    }

    // Décodage tolérant : une clé absente prend sa valeur d'origine (jamais « activé » par défaut).
    private enum CodingKeys: String, CodingKey { case enabled, allowRiskyPorts, poeOffSeconds, followUpSeconds, bounceSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false,
                  allowRiskyPorts: (try? c.decodeIfPresent(Bool.self, forKey: .allowRiskyPorts)) ?? false,
                  poeOffSeconds: (try? c.decodeIfPresent(Int.self, forKey: .poeOffSeconds)) ?? Self.defaultOffSeconds,
                  followUpSeconds: (try? c.decodeIfPresent(Int.self, forKey: .followUpSeconds)) ?? 180,
                  bounceSeconds: (try? c.decodeIfPresent(Int.self, forKey: .bounceSeconds)) ?? 5)
        self = clamped
    }
}

/// Moyen par lequel l'action est envoyée.
public enum PortActionChannel: Equatable, Sendable {
    /// API REST de la FortiGate qui gère le FortiSwitch (jeton du contrôleur, droit d'écriture).
    case fortiGate(controllerID: UUID, controllerName: String, switchID: String, portName: String)
    /// SET SNMP de pethPsePortAdminEnable.groupe.port sur le switch (identifiants d'écriture).
    case snmp(host: IPv4Address, group: Int, port: Int)

    /// « FortiGate Siège (API REST) », « SNMP en écriture (pethPsePortAdminEnable 1.12) ».
    public var label: String {
        switch self {
        case .fortiGate(_, let name, _, _): return "FortiGate «\u{00A0}\(name)\u{00A0}» (API REST)"
        case .snmp(_, let group, let port): return "SNMP en écriture (pethPsePortAdminEnable \(group).\(port))"
        }
    }
}

/// Port visé et ce qu'on sait de lui et de l'appareil branché (rien n'est lu ici sur le réseau).
public struct PortActionTarget: Equatable, Sendable {
    public var switchName: String
    /// Adresse SNMP du switch ; nil ou 0.0.0.n pour un FortiSwitch sans adresse FortiLink connue.
    public var switchHost: IPv4Address?
    public var portName: String
    public var ifIndex: Int
    /// Port d'uplink, trunk, FortiLink ou ISL (même règle que la localisation).
    public var isUplink: Bool
    /// Port où ce Mac est branché (sa MAC ou son adresse vues sur le port).
    public var isThisMacPort: Bool
    /// Appareil branché (le premier vu sur le port), s'il est connu.
    public var deviceName: String?
    public var deviceIP: IPv4Address?
    public var deviceMAC: MACAddress?
    /// Nombre d'adresses MAC apprises sur le port.
    public var macCount: Int
    /// PoE du port d'après le dernier relevé.
    public var poe: SNMPPoEPort?
    /// FortiSwitch géré : contrôleur et identifiant du switch pour l'API (mkey).
    public var fortiGate: FortiPortRef?
    /// Relevé « via FortiGate » : le switch n'a de moyen d'action que par l'API de sa FortiGate.
    public var viaFortiGate: Bool

    public init(switchName: String, switchHost: IPv4Address?, portName: String, ifIndex: Int, isUplink: Bool = false,
                isThisMacPort: Bool = false, deviceName: String? = nil, deviceIP: IPv4Address? = nil, deviceMAC: MACAddress? = nil,
                macCount: Int = 0, poe: SNMPPoEPort? = nil, fortiGate: FortiPortRef? = nil,
                viaFortiGate: Bool = false) {
        self.switchName = switchName
        self.switchHost = switchHost
        self.portName = portName
        self.ifIndex = ifIndex
        self.isUplink = isUplink
        self.isThisMacPort = isThisMacPort
        self.deviceName = deviceName
        self.deviceIP = deviceIP
        self.deviceMAC = deviceMAC
        self.macCount = macCount
        self.poe = poe
        self.fortiGate = fortiGate
        self.viaFortiGate = viaFortiGate || fortiGate != nil
    }

    /// Le switch est un FortiSwitch lu par une FortiGate.
    public var isManagedFortiSwitch: Bool { fortiGate != nil }

    /// Adresse SNMP utilisable : les adresses de remplacement 0.x.y.z ne sont jamais interrogées.
    public var usableSNMPHost: IPv4Address? {
        guard let switchHost, switchHost.octets.0 != 0 else { return nil }
        return switchHost
    }

    /// « SW-CORE-01 · Gi1/0/12 ».
    public var portLabel: String { "\(switchName) · \(portName)" }

    /// « FortiAP-231F (10.182.122.20) », « appareil inconnu ».
    public var deviceLabel: String {
        switch (deviceName, deviceIP) {
        case let (name?, ip?) where name != ip.description: return "\(name) (\(ip))"
        case let (_, ip?): return ip.description
        case let (name?, nil): return name
        default: return deviceMAC.map { "MAC \($0.formatted(.upperColon))" } ?? "appareil inconnu"
        }
    }
}

/// FortiSwitch géré : FortiGate (contrôleur) et identifiant du switch dans FortiOS.
public struct FortiPortRef: Equatable, Sendable {
    public var controllerID: UUID
    public var controllerName: String
    /// switch-id de FortiOS (le numéro de série par défaut, « S124FFTF21001234 ») : le « mkey » de l'API.
    public var switchID: String
    public var serial: String

    public init(controllerID: UUID, controllerName: String, switchID: String, serial: String) {
        self.controllerID = controllerID
        self.controllerName = controllerName
        self.switchID = switchID
        self.serial = serial
    }

    /// mkey de l'API : le switch-id, sinon le numéro de série.
    public var mkey: String { switchID.isEmpty ? serial : switchID }
}

/// Raison de refuser (ou de mettre en garde contre) une action.
public enum PortActionRefusal: Equatable, Sendable {
    /// « Autoriser les actions sur les ports » est désactivé.
    case disabled
    case uplink
    case thisMac
    /// Le port ne figure pas parmi les ports PoE du switch.
    case noPoE
    /// PoE désactivé par l'administrateur : un cycle le rallumerait.
    case poeAdminDisabled
    /// Port PoE non rattaché à pethPsePortTable (groupe.port inconnu).
    case poeIndexUnknown
    /// Redémarrage du port : seulement par l'API d'une FortiGate.
    case restartNeedsFortiGate
    /// FortiSwitch : FortiGate absente, désactivée ou sans jeton.
    case fortiGateNotReady(String)
    /// SNMP : pas d'adresse du switch utilisable.
    case noSwitchAddress
    /// SNMP : aucun identifiant d'écriture au Trousseau.
    case noWriteCredentials
    /// Relevé « via FortiGate » dont le FortiSwitch n'est pas retrouvé (sans ambiguïté) dans la
    /// lecture de la FortiGate de son site.
    case fortiSwitchNotFound
    /// Action déjà en cours sur ce port.
    case busy

    /// Explication en français, affichée dans l'aide du bouton et dans la feuille.
    public var message: String {
        switch self {
        case .disabled:
            return "Actions sur les ports désactivées\u{00A0}: activez «\u{00A0}Autoriser les actions sur les ports\u{00A0}» dans Réglages › Switchs."
        case .uplink:
            return "Ce port est un uplink (trunk, FortiLink ou ISL)\u{00A0}: le couper isolerait tous les appareils situés derrière."
        case .thisMac:
            return "Ce Mac passe par ce port (sa MAC y est apprise, directement ou par une borne Wi-Fi)\u{00A0}: NetScope perdrait sa propre connexion pendant l’action."
        case .noPoE:
            return "Ce port ne fournit pas de PoE d’après le dernier relevé du switch."
        case .poeAdminDisabled:
            return "Le PoE est désactivé par l’administrateur sur ce port\u{00A0}: un cycle le rallumerait, NetScope refuse."
        case .poeIndexUnknown:
            return "Port PoE non rattaché à POWER-ETHERNET-MIB (groupe et numéro inconnus)\u{00A0}: impossible de viser le bon port."
        case .restartNeedsFortiGate:
            return "Le redémarrage d’un port n’est proposé que pour un FortiSwitch géré par une FortiGate (API REST)."
        case .fortiGateNotReady(let reason):
            return "FortiGate non prête\u{00A0}: \(reason)"
        case .noSwitchAddress:
            return "Adresse SNMP du switch inconnue."
        case .noWriteCredentials:
            return "Aucun identifiant SNMP d’écriture\u{00A0}: enregistrez une communauté d’écriture ou un utilisateur v3 dédié dans Réglages › Switchs."
        case .fortiSwitchNotFound:
            return "FortiSwitch introuvable dans la dernière lecture de la FortiGate de son site (ou nom porté par plusieurs switchs)\u{00A0}: relisez la FortiGate dans Réglages › Switchs."
        case .busy:
            return "Une action est déjà en cours sur ce port."
        }
    }

    /// Uplink et port de ce Mac : refusés par défaut, permis seulement par le réglage et une case cochée.
    public var isRiskyPort: Bool { self == .uplink || self == .thisMac }
}

/// Décision pour une action sur un port.
public struct PortActionDecision: Equatable, Sendable {
    public var kind: PortActionKind
    /// Raisons bloquantes (vide : action permise).
    public var refusals: [PortActionRefusal]
    /// Mises en garde à confirmer par une case cochée (uplink ou port de ce Mac permis par le réglage).
    public var warnings: [PortActionRefusal]
    /// Moyen d'envoi retenu (nil si refusée faute de moyen).
    public var channel: PortActionChannel?

    public var isAllowed: Bool { refusals.isEmpty && channel != nil }
    /// Explication du premier refus (aide du bouton).
    public var reason: String? { refusals.first?.message }
}

/// Garde-fous : rien n'est envoyé sans une décision permise.
public enum PortActionGuard {
    /// Décide si l'action est permise et par quel moyen. `fortiGateProblem` : raison pour laquelle
    /// la FortiGate du switch ne peut pas être utilisée (nil : prête) ; `hasWriteCredentials` :
    /// identifiants SNMP d'écriture au Trousseau.
    public static func decide(_ kind: PortActionKind, target: PortActionTarget, settings: PortActionSettings,
                              hasWriteCredentials: Bool, fortiGateProblem: String?, busy: Bool = false) -> PortActionDecision {
        var refusals: [PortActionRefusal] = []
        var warnings: [PortActionRefusal] = []
        if !settings.enabled { refusals.append(.disabled) }
        if busy { refusals.append(.busy) }
        for risky in [PortActionRefusal.uplink, .thisMac] {
            let applies = risky == .uplink ? target.isUplink : target.isThisMacPort
            guard applies else { continue }
            if settings.allowRiskyPorts { warnings.append(risky) } else { refusals.append(risky) }
        }
        var channel: PortActionChannel?
        if target.viaFortiGate && target.fortiGate == nil {
            // Jamais de repli SNMP ni de FortiGate d'un autre site : le switch n'est pas identifié.
            if kind == .poeCycle && target.poe == nil { refusals.append(.noPoE) }
            refusals.append(.fortiSwitchNotFound)
            return PortActionDecision(kind: kind, refusals: refusals, warnings: warnings, channel: nil)
        }
        switch kind {
        case .poeCycle:
            if let poe = target.poe {
                if poe.adminEnabled == false || poe.detection == .disabled { refusals.append(.poeAdminDisabled) }
            } else {
                refusals.append(.noPoE)
            }
            if let forti = target.fortiGate {
                if let fortiGateProblem { refusals.append(.fortiGateNotReady(fortiGateProblem)) }
                else { channel = .fortiGate(controllerID: forti.controllerID, controllerName: forti.controllerName, switchID: forti.mkey, portName: target.portName) }
            } else if let poe = target.poe {
                if target.usableSNMPHost == nil { refusals.append(.noSwitchAddress) }
                else if !hasWriteCredentials { refusals.append(.noWriteCredentials) }
                else if poe.group < 1 || poe.port < 1 { refusals.append(.poeIndexUnknown) }
                else if let host = target.usableSNMPHost { channel = .snmp(host: host, group: poe.group, port: poe.port) }
            }
        case .portRestart:
            if let forti = target.fortiGate {
                if let fortiGateProblem { refusals.append(.fortiGateNotReady(fortiGateProblem)) }
                else { channel = .fortiGate(controllerID: forti.controllerID, controllerName: forti.controllerName, switchID: forti.mkey, portName: target.portName) }
            } else {
                refusals.append(.restartNeedsFortiGate)
            }
        }
        // Raison principale en tête : le réglage d'abord, puis le port, puis le moyen.
        return PortActionDecision(kind: kind, refusals: refusals, warnings: warnings, channel: refusals.isEmpty ? channel : nil)
    }

    /// Le port est-il celui de ce Mac ? Une des MAC (ou adresses) de ce Mac apprise sur le port.
    public static func isThisMacPort(entries: [SNMPFDBEntry], arp: [MACAddress: IPv4Address],
                                     localMACs: Set<MACAddress>, localIPs: Set<IPv4Address>) -> Bool {
        entries.contains { entry in
            localMACs.contains(entry.mac) || arp[entry.mac].map(localIPs.contains) == true
        }
    }
}
