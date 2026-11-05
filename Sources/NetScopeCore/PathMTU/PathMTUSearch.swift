import Foundation

// Recherche du MTU d'un chemin (notes 78 et 79) : échos ICMP de taille variable avec le bit
// « ne pas fragmenter » (DF), par dichotomie. L'algorithme est pur : la sonde est une fonction
// passée en paramètre (réelle : PathMTUProber ; tests et démonstration : sonde simulée).

/// Réponse à une sonde d'une taille donnée (taille IP totale, en-têtes compris).
public enum PathMTUOutcome: Equatable, Sendable, Codable {
    /// Écho reçu : le paquet est passé entier.
    case reply(rttMs: Double)
    /// Trop grand : refusé par l'interface de ce Mac (`local`) ou par un routeur qui renvoie
    /// « fragmentation nécessaire » (ICMP 3/4), avec le MTU du saut suivant s'il est donné.
    case tooBig(reportedMTU: Int?, from: IPv4Address?, local: Bool)
    /// Aucune réponse dans le délai (paquet jeté sans message : trou noir, ou simple perte).
    case lost
    /// Destination inaccessible (autre code ICMP) : la mesure s'arrête.
    case unreachable(code: UInt8, from: IPv4Address?)
    /// Erreur d'envoi ou d'outil.
    case failed(String)

    public var passed: Bool {
        if case .reply = self { return true }
        return false
    }

    /// Libellé court pour le tableau des étapes.
    public var label: String {
        switch self {
        case .reply: return "Passe"
        case let .tooBig(reported, from, local):
            if local { return "Trop grand pour l’interface" + (reported.map { " (\($0))" } ?? "") }
            let mtu = reported.map { " (MTU \($0))" } ?? ""
            return "Fragmentation nécessaire" + mtu + (from.map { " · \($0)" } ?? "")
        case .lost: return "Sans réponse"
        case let .unreachable(code, from):
            return "Inaccessible (code \(code))" + (from.map { " · \($0)" } ?? "")
        case let .failed(message): return message
        }
    }
}

/// Une étape de la recherche : taille essayée, réponse et bornes après l'étape.
public struct PathMTUStep: Equatable, Sendable, Codable, Identifiable {
    public var id: Int { index }
    public let index: Int
    /// Taille IP totale (en-têtes IP et ICMP compris).
    public let size: Int
    public let outcome: PathMTUOutcome
    /// Nombre d'envois pour cette taille (une perte est retentée).
    public let attempts: Int
    /// Plus grande taille connue qui passe, après l'étape.
    public let low: Int
    /// Plus petite taille connue qui ne passe pas, après l'étape (nil : aucune).
    public let high: Int?

    public init(index: Int, size: Int, outcome: PathMTUOutcome, attempts: Int, low: Int, high: Int?) {
        self.index = index
        self.size = size
        self.outcome = outcome
        self.attempts = attempts
        self.low = low
        self.high = high
    }

    /// Données ICMP correspondantes (taille − 28 octets d'en-têtes).
    public var payload: Int { max(0, size - PathMTUSearch.overhead) }
}

/// Réglages d'une recherche.
public struct PathMTUOptions: Equatable, Sendable {
    /// Plus grande taille essayée : 1500 (Ethernet) ou 9000 (trames jumbo).
    public var maxSize: Int
    /// Envois par taille quand rien ne revient (une perte isolée ne doit pas fausser le résultat).
    public var attempts: Int
    /// Délai d'attente d'une réponse.
    public var timeout: TimeInterval
    /// MTU de l'interface de sortie de ce Mac, s'il est connu (sert d'indice quand le système refuse un envoi).
    public var interfaceMTU: Int?

    public init(maxSize: Int = 1500, attempts: Int = 2, timeout: TimeInterval = 1.5, interfaceMTU: Int? = nil) {
        self.maxSize = min(max(PathMTUSearch.baseSize + 1, maxSize), 65_000)
        self.attempts = min(max(1, attempts), 5)
        self.timeout = max(0.2, timeout)
        self.interfaceMTU = interfaceMTU
    }

    public static let jumboSize = 9000
}

/// Résultat d'une recherche.
public struct PathMTUResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// MTU trouvé.
        case found
        /// La cible ne répond pas même aux petits paquets : impossible de mesurer.
        case unreachable(String)
        /// Mesure interrompue (erreur, annulation) : `mtu` est la meilleure borne connue.
        case interrupted(String)
    }

    public let status: Status
    /// MTU du chemin (taille IP maximale qui passe sans fragmentation).
    public let mtu: Int?
    public let options: PathMTUOptions
    public let steps: [PathMTUStep]

    public init(status: Status, mtu: Int?, options: PathMTUOptions, steps: [PathMTUStep]) {
        self.status = status
        self.mtu = mtu
        self.options = options
        self.steps = steps
    }

    /// Sondes envoyées en tout (pertes retentées comprises).
    public var probesSent: Int { steps.reduce(0) { $0 + $1.attempts } }
    /// Tailles jetées sans aucun message (filtrage ICMP : trou noir de la découverte du MTU).
    public var silentDrops: Int { steps.filter { $0.outcome == .lost && $0.size > PathMTUSearch.baseSize }.count }
    /// Messages « fragmentation nécessaire » reçus d'un routeur.
    public var fragmentationMessages: Int {
        steps.filter { if case let .tooBig(_, _, local) = $0.outcome { return !local } else { return false } }.count
    }
    /// Le système a refusé un envoi trop grand pour l'interface de ce Mac.
    public var localLimit: Bool {
        steps.contains { if case .tooBig(_, _, true) = $0.outcome { return true } else { return false } }
    }
    /// Routeur qui a signalé la limite, s'il y en a un.
    public var limitingRouter: IPv4Address? {
        for step in steps.reversed() {
            if case let .tooBig(_, from, false) = step.outcome, let from { return from }
        }
        return nil
    }
    /// Trou noir probable : des tailles jetées sans « fragmentation nécessaire ».
    public var isBlackHole: Bool {
        guard let mtu, mtu < options.maxSize else { return false }
        return silentDrops > 0 && fragmentationMessages == 0 && !localLimit
    }
    /// Temps aller-retour moyen des échos reçus.
    public var averageRTT: Double? {
        let values = steps.compactMap { step -> Double? in
            if case let .reply(rtt) = step.outcome { return rtt }
            return nil
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Diagnostic du MTU trouvé (PPPoE, tunnel, jumbo…).
    public var diagnosis: PathMTUDiagnosis? { mtu.map { PathMTUDiagnosis(mtu: $0, maxTested: options.maxSize) } }

    /// MSS TCP conseillé (MTU − 40 octets d'en-têtes IP et TCP).
    public var recommendedMSS: Int? { mtu.map { $0 - 40 } }
}

/// Algorithme de recherche.
public enum PathMTUSearch {
    /// En-têtes IP (20) et ICMP (8).
    public static let overhead = 28
    /// Taille du premier écho (ping classique de 56 octets de données) : vérifie que la cible répond.
    public static let baseSize = 84

    public typealias Probe = @Sendable (_ size: Int) async -> PathMTUOutcome

    /// Recherche par dichotomie. `progress` reçoit chaque étape dès qu'elle est connue.
    /// - La cible doit d'abord répondre à un écho de 84 octets.
    /// - La plus grande taille (1500 ou 9000) est essayée tout de suite : le cas courant se règle en deux sondes.
    /// - Un « fragmentation nécessaire » avec le MTU du saut suivant est vérifié directement.
    /// - Une taille sans réponse est retentée (`attempts`), puis comptée comme trop grande (trou noir).
    public static func run(options: PathMTUOptions, probe: Probe,
                           progress: (@Sendable (PathMTUStep) -> Void)? = nil) async -> PathMTUResult {
        var steps: [PathMTUStep] = []
        var low = baseSize
        var high: Int?

        func attempt(_ size: Int) async -> (PathMTUOutcome, Int) {
            var tries = 0
            var outcome = PathMTUOutcome.lost
            while tries < options.attempts {
                if Task.isCancelled { return (.failed("Mesure annulée"), max(1, tries)) }
                tries += 1
                outcome = await probe(size)
                if outcome != .lost { break }
            }
            return (outcome, tries)
        }

        func record(_ size: Int, _ outcome: PathMTUOutcome, _ tries: Int) {
            let step = PathMTUStep(index: steps.count + 1, size: size, outcome: outcome, attempts: tries, low: low, high: high)
            steps.append(step)
            progress?(step)
        }

        // 1. La cible répond-elle ?
        let (first, firstTries) = await attempt(baseSize)
        record(baseSize, first, firstTries)
        switch first {
        case .reply: break
        case .lost:
            return PathMTUResult(status: .unreachable("La cible ne répond pas au ping (ICMP filtré ou appareil éteint)\u{00A0}: le MTU ne peut pas être mesuré."),
                                 mtu: nil, options: options, steps: steps)
        case let .unreachable(code, from):
            return PathMTUResult(status: .unreachable("Destination inaccessible (code ICMP \(code)\(from.map { ", signalé par \($0)" } ?? ""))."),
                                 mtu: nil, options: options, steps: steps)
        case let .failed(message):
            return PathMTUResult(status: .interrupted(message), mtu: nil, options: options, steps: steps)
        case .tooBig:
            return PathMTUResult(status: .interrupted("Même un paquet de \(baseSize)\u{00A0}octets est refusé."), mtu: nil, options: options, steps: steps)
        }

        // Taille à essayer ensuite : un indice reçu (MTU du saut suivant, MTU de l'interface) s'il
        // tombe strictement entre les bornes, sinon le milieu.
        var hint: Int? = options.maxSize
        // Limite annoncée (MTU du saut suivant, MTU de l'interface) : si elle passe, c'est le MTU
        // exact (un octet de plus est refusé par l'équipement qui l'a annoncée).
        var announced: Int?
        while true {
            let ceiling = high ?? (options.maxSize + 1)
            guard ceiling - low > 1 else { break }
            let size: Int
            if let candidate = hint, candidate > low, candidate < ceiling {
                size = candidate
            } else {
                size = (low + ceiling) / 2
            }
            hint = nil
            let (outcome, tries) = await attempt(size)
            switch outcome {
            case .reply:
                low = size
                if size == announced { high = size + 1 }
            case let .tooBig(reported, _, local):
                high = size
                hint = reported ?? (local ? options.interfaceMTU : nil)
                announced = hint
            case .lost:
                high = size
            case let .unreachable(code, from):
                record(size, outcome, tries)
                return PathMTUResult(status: .interrupted("Destination inaccessible à \(size)\u{00A0}octets (code \(code)\(from.map { ", \($0)" } ?? ""))."),
                                     mtu: low, options: options, steps: steps)
            case let .failed(message):
                record(size, outcome, tries)
                return PathMTUResult(status: .interrupted(message), mtu: low, options: options, steps: steps)
            }
            record(size, outcome, tries)
        }
        return PathMTUResult(status: .found, mtu: low, options: options, steps: steps)
    }
}

// MARK: - Diagnostic

/// Ce que le MTU trouvé laisse deviner du chemin.
public struct PathMTUDiagnosis: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case jumbo, jumboPartial, standard, pppoe, ipInIP, gre, dsLite, vxlan, ipsec, wireguard, reduced, veryLow
    }

    public let kind: Kind
    public let mtu: Int
    /// Octets perdus par rapport à l'Ethernet standard (1500).
    public var overhead: Int { max(0, 1500 - mtu) }

    public init(mtu: Int, maxTested: Int = 1500) {
        self.mtu = mtu
        switch mtu {
        case 9000...: kind = .jumbo
        case 1501...: kind = .jumboPartial
        case 1500: kind = .standard
        case 1492: kind = .pppoe
        case 1480: kind = .ipInIP
        case 1476: kind = .gre
        case 1460: kind = .dsLite
        case 1450: kind = .vxlan
        case 1420: kind = .wireguard
        case 1350...1439: kind = .ipsec
        case 1280...1349, 1440...1499: kind = .reduced
        default: kind = .veryLow
        }
    }

    /// Titre court (pastille).
    public var title: String {
        switch kind {
        case .jumbo: return "Trames jumbo"
        case .jumboPartial: return "Jumbo partiel"
        case .standard: return "Ethernet standard"
        case .pppoe: return "PPPoE probable"
        case .ipInIP: return "Tunnel IP dans IP probable"
        case .gre: return "Tunnel GRE probable"
        case .dsLite: return "DS-Lite probable"
        case .vxlan: return "VXLAN probable"
        case .ipsec: return "Tunnel IPsec probable"
        case .wireguard: return "WireGuard probable"
        case .reduced: return "MTU réduit"
        case .veryLow: return "MTU anormalement bas"
        }
    }

    /// Explication pour le technicien.
    public var explanation: String {
        let nb = "\u{00A0}"
        switch kind {
        case .jumbo:
            return "Les trames jumbo (\(mtu)\(nb)octets) passent de bout en bout\(nb): switchs et cartes réseau sont configurés pour elles."
        case .jumboPartial:
            return "Le chemin accepte plus que 1500\(nb)octets mais pas 9000\(nb): un équipement a un MTU jumbo différent (\(mtu)). Alignez le MTU de tous les switchs et des deux hôtes."
        case .standard:
            return "Ethernet standard de bout en bout\(nb): aucun tunnel ni encapsulation ne réduit le chemin."
        case .pppoe:
            return "1500 − 8\(nb)octets d’en-tête PPPoE\(nb): l’accès Internet passe très probablement par PPPoE (DSL, fibre de certains fournisseurs). Réglez le MSS à 1452 sur le pare-feu si des sites figent."
        case .ipInIP:
            return "1500 − 20\(nb)octets\(nb): un tunnel IP dans IP (6in4, IPIP) ou un PPPoE avec un en-tête supplémentaire est probable sur le chemin."
        case .gre:
            return "1500 − 24\(nb)octets\(nb): un tunnel GRE est probable sur le chemin (liaison intersite, opérateur)."
        case .dsLite:
            return "1500 − 40\(nb)octets\(nb): IPv4 transporté dans IPv6 (DS-Lite, MAP-E) ou GRE avec options\(nb): fréquent chez certains fournisseurs."
        case .vxlan:
            return "1500 − 50\(nb)octets\(nb): une encapsulation VXLAN (réseau superposé, nuage) est probable."
        case .wireguard:
            return "1420\(nb)octets\(nb): valeur par défaut de WireGuard\(nb): le trafic passe probablement dans un tunnel WireGuard."
        case .ipsec:
            return "1500 − \(overhead)\(nb)octets\(nb): ordre de grandeur d’un tunnel IPsec (ESP, 50 à 100\(nb)octets selon le chiffrement et le NAT-T), ou de GRE dans IPsec. Vérifiez le MSS du tunnel sur la FortiGate (tcp-mss)."
        case .reduced:
            return "1500 − \(overhead)\(nb)octets\(nb): une encapsulation réduit le chemin (VPN SSL, VLAN Q-in-Q, MPLS ou lien opérateur). Réglez le MSS à \(mtu - 40) si des connexions figent."
        case .veryLow:
            return "\(mtu)\(nb)octets, moins que le minimum d’IPv6 (1280)\(nb): tunnels imbriqués ou équipement mal configuré. Les connexions TCP risquent de figer."
        }
    }

    /// Ton de la pastille : vert si normal, orange si le chemin est réduit, rouge si anormal.
    public var severity: Severity {
        switch kind {
        case .jumbo, .standard: return .normal
        case .jumboPartial, .veryLow: return .problem
        default: return .reduced
        }
    }

    public enum Severity: Sendable { case normal, reduced, problem }
}
