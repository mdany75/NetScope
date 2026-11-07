import Foundation

// Note 92 : qualité VoIP. Note MOS (1 à 5) par le modèle E simplifié (ITU-T G.107, valeurs de
// codecs de G.113) à partir de la latence, de la gigue et des pertes :
//   R = 93,2 − Id − Ie,eff
//   Id = 0,024·d + 0,11·(d − 177,3)·H(d − 177,3)            (d : délai bouche-oreille, ms)
//   Ie,eff = Ie + (95 − Ie) · Ppl / (Ppl + Bpl)              (pertes aléatoires, BurstR = 1)
//   MOS = 1 + 0,035·R + R·(R − 60)·(100 − R)·7·10⁻⁶          (R borné entre 0 et 100)
// Le délai effectif compte la mémoire tampon de gigue (2 × gigue) et le délai du codec. Tout est pur :
// les appels captés (flux RTP de la capture de paquets) et le test simulé (iperf3 en UDP, lancé
// seulement sur clic) fournissent les mesures.

/// Paramètres d'un codec pour le modèle E.
public struct VoIPCodecProfile: Hashable, Sendable {
    public var name: String
    /// Facteur de dégradation de l'équipement (Ie).
    public var ie: Double
    /// Robustesse aux pertes de paquets (Bpl).
    public var bpl: Double
    /// Délai propre du codec (trame et anticipation), en millisecondes.
    public var codecDelayMs: Double
    /// Débit IP d'un flux (en-têtes IP, UDP et RTP compris, 20 ms par paquet), en kb/s.
    public var ipKbps: Double

    public init(name: String, ie: Double, bpl: Double, codecDelayMs: Double, ipKbps: Double) {
        self.name = name
        self.ie = ie
        self.bpl = bpl
        self.codecDelayMs = codecDelayMs
        self.ipKbps = ipKbps
    }

    public static let g711 = VoIPCodecProfile(name: "G.711", ie: 0, bpl: 25.1, codecDelayMs: 20, ipKbps: 80)
    public static let g722 = VoIPCodecProfile(name: "G.722", ie: 0, bpl: 25.1, codecDelayMs: 21.5, ipKbps: 80)
    public static let g729 = VoIPCodecProfile(name: "G.729", ie: 11, bpl: 19, codecDelayMs: 25, ipKbps: 24)
    public static let g723 = VoIPCodecProfile(name: "G.723.1", ie: 15, bpl: 16.1, codecDelayMs: 67.5, ipKbps: 22)
    public static let gsm = VoIPCodecProfile(name: "GSM", ie: 20, bpl: 10, codecDelayMs: 20, ipKbps: 29)
    public static let ilbc = VoIPCodecProfile(name: "iLBC", ie: 10, bpl: 32, codecDelayMs: 25, ipKbps: 31)
    public static let opus = VoIPCodecProfile(name: "Opus", ie: 0, bpl: 30, codecDelayMs: 26.5, ipKbps: 50)

    /// Codecs proposés pour le test simulé, en ordre alphabétique.
    public static let all: [VoIPCodecProfile] = [g711, g722, g723, g729, gsm, ilbc, opus]

    /// Profil d'après le nom du codec vu dans la capture (« PCMU (G.711 µ-loi) », « G729 », « opus ») ;
    /// G.711 par défaut (le plus courant en téléphonie IP d'entreprise).
    public static func matching(_ codec: String) -> VoIPCodecProfile {
        let text = codec.lowercased().replacingOccurrences(of: ".", with: "")
        if text.contains("g729") { return g729 }
        if text.contains("g722") { return g722 }
        if text.contains("g723") { return g723 }
        if text.contains("gsm") { return gsm }
        if text.contains("ilbc") { return ilbc }
        if text.contains("opus") { return opus }
        return g711
    }
}

/// Mesures d'un sens d'un appel.
public struct VoIPMeasures: Hashable, Sendable {
    /// Délai réseau dans un sens (ms) ; nil : inconnu (compté à 0, seuls la gigue et le codec comptent).
    public var oneWayDelayMs: Double?
    public var jitterMs: Double
    /// Pertes en pourcentage (0 à 100).
    public var lossPercent: Double

    public init(oneWayDelayMs: Double? = nil, jitterMs: Double, lossPercent: Double) {
        self.oneWayDelayMs = oneWayDelayMs
        self.jitterMs = max(0, jitterMs)
        self.lossPercent = min(100, max(0, lossPercent))
    }
}

/// Appréciation d'une note MOS.
public enum VoIPGrade: Int, Comparable, Sendable, CaseIterable {
    case bad, poor, fair, good, excellent

    public static func < (lhs: VoIPGrade, rhs: VoIPGrade) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func of(mos: Double) -> VoIPGrade {
        switch mos {
        case 4.3...: return .excellent
        case 4.0..<4.3: return .good
        case 3.6..<4.0: return .fair
        case 3.1..<3.6: return .poor
        default: return .bad
        }
    }

    public var label: String {
        switch self {
        case .excellent: return "Excellente"
        case .good: return "Bonne"
        case .fair: return "Correcte"
        case .poor: return "Médiocre"
        case .bad: return "Mauvaise"
        }
    }

    /// Phrase pour le technicien.
    public var advice: String {
        switch self {
        case .excellent: return "Qualité d’un appel téléphonique classique."
        case .good: return "La plupart des utilisateurs sont satisfaits."
        case .fair: return "Acceptable, quelques utilisateurs remarquent une gêne."
        case .poor: return "Beaucoup d’utilisateurs se plaignent : vérifier la QoS et le VLAN voix."
        case .bad: return "Appels difficiles ou impossibles : pertes ou gigue trop fortes."
        }
    }
}

/// Résultat du modèle E.
public struct VoIPScore: Hashable, Sendable {
    public var rFactor: Double
    public var mos: Double
    public var effectiveDelayMs: Double
    public var codec: String

    public var grade: VoIPGrade { VoIPGrade.of(mos: mos) }
    /// « 4,41 » (virgule décimale).
    public var mosLabel: String { VoIPQuality.decimal(mos, digits: 2) }
}

public enum VoIPQuality {
    /// Facteur R de base (R0 − Is) de G.107 avec les valeurs par défaut.
    public static let baseR = 93.2

    /// Dégradation due au délai (Id), délai bouche-oreille en millisecondes.
    public static func delayImpairment(_ delayMs: Double) -> Double {
        let d = max(0, delayMs)
        return 0.024 * d + (d > 177.3 ? 0.11 * (d - 177.3) : 0)
    }

    /// Dégradation effective de l'équipement avec pertes aléatoires (Ie,eff).
    public static func equipmentImpairment(lossPercent: Double, codec: VoIPCodecProfile) -> Double {
        let ppl = min(100, max(0, lossPercent))
        return codec.ie + (95 - codec.ie) * ppl / (ppl + codec.bpl)
    }

    /// Note MOS d'un facteur R (G.107 annexe B).
    public static func mos(r: Double) -> Double {
        if r <= 0 { return 1 }
        if r >= 100 { return 4.5 }
        return min(4.5, max(1, 1 + 0.035 * r + r * (r - 60) * (100 - r) * 7e-6))
    }

    /// Score d'un sens d'appel. Délai effectif = délai réseau + 2 × gigue (mémoire tampon) + codec.
    public static func score(_ measures: VoIPMeasures, codec: VoIPCodecProfile = .g711) -> VoIPScore {
        let delay = (measures.oneWayDelayMs ?? 0) + 2 * measures.jitterMs + codec.codecDelayMs
        let r = min(100, max(0, baseR - delayImpairment(delay) - equipmentImpairment(lossPercent: measures.lossPercent, codec: codec)))
        return VoIPScore(rFactor: r, mos: mos(r: r), effectiveDelayMs: delay, codec: codec.name)
    }

    /// Score d'un flux RTP capté (perte d'après les numéros de séquence, gigue RFC 3550).
    /// Le délai dans un sens ne se voit pas depuis un seul point de capture : `oneWayDelayMs`
    /// peut le fournir (moitié du temps de réponse SIP, ping), sinon il compte pour 0.
    public static func score(stream: RTPStreamSummary, oneWayDelayMs: Double? = nil) -> VoIPScore {
        score(VoIPMeasures(oneWayDelayMs: oneWayDelayMs, jitterMs: stream.jitter, lossPercent: stream.lossRatio * 100),
              codec: .matching(stream.codec))
    }

    /// Score d'un test iperf3 en UDP (test simulé) : gigue et pertes mesurées par le serveur.
    /// Nil si le résultat n'est pas en UDP.
    public static func score(iperf result: IperfResult, codec: VoIPCodecProfile = .g711,
                             oneWayDelayMs: Double? = nil) -> VoIPScore? {
        guard result.isUDP, let jitter = result.jitterMs else { return nil }
        let loss = lossPercent(iperf: result)
        return score(VoIPMeasures(oneWayDelayMs: oneWayDelayMs, jitterMs: jitter, lossPercent: loss), codec: codec)
    }

    /// Pertes d'un test iperf3 en pour cent : celles du serveur, sinon paquets perdus / envoyés.
    /// La même valeur sert à la note et à l'affichage du test.
    public static func lossPercent(iperf result: IperfResult) -> Double {
        if let percent = result.lostPercent { return percent }
        guard let lost = result.lostPackets, let packets = result.packets, packets > 0 else { return 0 }
        return Double(lost) / Double(packets) * 100
    }

    /// Options iperf3 du test simulé : un flux UDP au débit d'un appel du codec (10 s).
    public static func syntheticOptions(host: String, port: Int = 5201, codec: VoIPCodecProfile = .g711,
                                        calls: Int = 1, duration: Int = 10) -> IperfOptions {
        let kbps = Int((codec.ipKbps * Double(max(1, calls))).rounded())
        return IperfOptions(host: host, port: port, duration: duration, streams: 1, transport: .udp,
                            direction: .normal, udpBandwidth: "\(kbps)K")
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }
}

/// Un appel capté : les deux sens d'une même paire d'extrémités RTP.
public struct VoIPCall: Equatable, Sendable, Identifiable {
    public var id: String
    /// « 10.0.30.21:16384 ↔ 10.0.0.5:10000 »
    public var label: String
    public var codec: String
    public var forward: RTPStreamSummary
    public var reverse: RTPStreamSummary?
    public var forwardScore: VoIPScore
    public var reverseScore: VoIPScore?

    /// Note la plus basse des deux sens (celle que l'utilisateur ressent).
    public var worst: VoIPScore {
        guard let reverseScore, reverseScore.mos < forwardScore.mos else { return forwardScore }
        return reverseScore
    }

    /// Regroupe les flux RTP par paire d'extrémités (un appel = un sens, ou deux), du plus mauvais au meilleur.
    public static func calls(from streams: [RTPStreamSummary], oneWayDelayMs: Double? = nil) -> [VoIPCall] {
        var groups: [String: [RTPStreamSummary]] = [:]
        var order: [String] = []
        for stream in streams {
            let ends = [stream.source.label, stream.destination.label].sorted()
            let key = ends.joined(separator: "|")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(stream)
        }
        let calls = order.compactMap { key -> VoIPCall? in
            guard let group = groups[key]?.sorted(by: { $0.packets > $1.packets }), let first = group.first else { return nil }
            let reverse = group.dropFirst().first { $0.source == first.destination }
            return VoIPCall(id: key, label: "\(first.source.label) ↔ \(first.destination.label)", codec: first.codec,
                            forward: first, reverse: reverse,
                            forwardScore: VoIPQuality.score(stream: first, oneWayDelayMs: oneWayDelayMs),
                            reverseScore: reverse.map { VoIPQuality.score(stream: $0, oneWayDelayMs: oneWayDelayMs) })
        }
        return calls.sorted { $0.worst.mos < $1.worst.mos }
    }
}

/// Test simulé retenu pour le rapport.
public struct VoIPSyntheticTest: Hashable, Sendable {
    public var target: String
    public var codec: String
    public var calls: Int
    public var jitterMs: Double
    public var lossPercent: Double
    public var score: VoIPScore
    public var date: Date

    public init(target: String, codec: String, calls: Int, jitterMs: Double, lossPercent: Double, score: VoIPScore, date: Date) {
        self.target = target
        self.codec = codec
        self.calls = calls
        self.jitterMs = jitterMs
        self.lossPercent = lossPercent
        self.score = score
        self.date = date
    }
}
