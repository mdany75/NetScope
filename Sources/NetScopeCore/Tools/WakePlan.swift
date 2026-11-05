import Foundation

// Note 78 (0.26.0) : Wake-on-LAN vers plusieurs postes, broadcast dirigé vers un autre
// sous-réseau et suivi par ping (« réveillé en N s »). Décisions pures, sans réseau : l'envoi
// reste `WakeOnLAN.send`, le suivi est fait par l'application.

/// Un poste à réveiller.
public struct WakeTarget: Equatable, Sendable {
    public var mac: MACAddress
    public var ip: IPv4Address?
    public var name: String

    public init(mac: MACAddress, ip: IPv4Address? = nil, name: String) {
        self.mac = mac
        self.ip = ip
        self.name = name
    }
}

/// Façon de choisir l'adresse de diffusion.
public enum WakeBroadcastMode: String, CaseIterable, Sendable, Identifiable {
    /// Broadcast du réseau local si le poste y est, sinon broadcast dirigé vers son sous-réseau.
    case automatic
    /// Adresse saisie, pour tous les postes.
    case manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "Automatique"
        case .manual: return "Adresse saisie"
        }
    }
}

/// Un envoi prévu : poste, adresse de diffusion et sa nature.
public struct WakeSend: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Broadcast du réseau de l'interface active.
        case local
        /// Broadcast dirigé vers un autre sous-réseau (le routeur doit le laisser passer).
        case directed
        /// Adresse saisie à la main.
        case manual
    }

    public var target: WakeTarget
    public var broadcast: IPv4Address
    public var kind: Kind
    /// Sous-réseau visé par un broadcast dirigé (« 10.20.0.0/24 »).
    public var subnet: Subnet?

    /// « broadcast local 10.182.122.255 », « broadcast dirigé 10.20.0.255 (10.20.0.0/24) ».
    public var label: String {
        switch kind {
        case .local: return "broadcast local \(broadcast)"
        case .directed: return "broadcast dirigé \(broadcast)" + (subnet.map { " (\($0))" } ?? "")
        case .manual: return "adresse saisie \(broadcast)"
        }
    }
}

extension WakeOnLAN {
    /// Préfixe supposé d'un sous-réseau distant inconnu.
    public static let defaultRemotePrefix = 24

    /// Broadcast dirigé du sous-réseau qui contient `ip` (préfixe 8 à 30).
    public static func directedBroadcast(for ip: IPv4Address, prefix: Int = defaultRemotePrefix) -> IPv4Address {
        Subnet(address: ip, prefix: Swift.min(30, Swift.max(8, prefix))).broadcast
    }

    /// Prévoit l'envoi pour chaque poste (doublons de MAC retirés, ordre gardé).
    /// - `local` : sous-réseau de l'interface active (nil : inconnu).
    /// - `knownSubnets` : plages connues (sites, plages scannées), pour deviner le préfixe d'un poste distant.
    /// - `manual` : adresse saisie, utilisée en mode `.manual`.
    public static func plan(_ targets: [WakeTarget], mode: WakeBroadcastMode, local: Subnet?, knownSubnets: [Subnet] = [],
                            manual: IPv4Address? = nil) -> [WakeSend] {
        var seen = Set<MACAddress>()
        return targets.compactMap { target in
            guard seen.insert(target.mac).inserted else { return nil }
            if mode == .manual, let manual {
                return WakeSend(target: target, broadcast: manual, kind: .manual, subnet: nil)
            }
            if let local, let ip = target.ip, !local.contains(ip) {
                // Le plus précis des sous-réseaux connus qui contient le poste, sinon un /24.
                let subnet = knownSubnets.filter { $0.contains(ip) && $0.prefix >= 8 && $0.prefix <= 30 }
                    .max { $0.prefix < $1.prefix } ?? Subnet(address: ip, prefix: defaultRemotePrefix)
                return WakeSend(target: target, broadcast: subnet.broadcast, kind: .directed, subnet: subnet)
            }
            let broadcast = local?.broadcast ?? manual ?? IPv4Address(255, 255, 255, 255)
            return WakeSend(target: target, broadcast: broadcast, kind: .local, subnet: local)
        }
    }
}

/// Suivi d'un réveil : un ping toutes les quelques secondes jusqu'à la première réponse, ou
/// jusqu'au délai. Valeur pure : l'application lui passe les réponses et l'heure.
public struct WakeFollowUp: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case waiting
        /// Premier écho reçu après `seconds` secondes.
        case awake(seconds: Int)
        case noReply
    }

    public static let defaultTimeout: TimeInterval = 120
    public static let probeInterval: TimeInterval = 2

    public let start: Date
    public let timeout: TimeInterval
    public private(set) var state: State = .waiting
    public private(set) var probes = 0

    public init(start: Date, timeout: TimeInterval = WakeFollowUp.defaultTimeout) {
        self.start = start
        self.timeout = timeout
    }

    public var isFinished: Bool { state != .waiting }

    /// Résultat d'un ping envoyé à `date` (réponse ou non) ; renvoie l'état.
    @discardableResult
    public mutating func record(reply: Bool, at date: Date) -> State {
        guard state == .waiting else { return state }
        probes += 1
        let elapsed = date.timeIntervalSince(start)
        if reply {
            state = .awake(seconds: Swift.max(0, Int(elapsed.rounded())))
        } else if elapsed >= timeout {
            state = .noReply
        }
        return state
    }

    /// Délai écoulé sans réponse (aucun ping n'a pu partir, par exemple).
    @discardableResult
    public mutating func expire(at date: Date) -> State {
        if state == .waiting, date.timeIntervalSince(start) >= timeout { state = .noReply }
        return state
    }

    /// « réveillé en 18 s », « aucune réponse au ping après 2 min », « attente du premier écho… ».
    public var label: String {
        switch state {
        case .waiting: return "attente du premier écho…"
        case .awake(let seconds): return "réveillé en \(seconds)\u{00A0}s"
        case .noReply: return "aucune réponse au ping après \(PingFormat.duration(timeout))"
        }
    }
}
