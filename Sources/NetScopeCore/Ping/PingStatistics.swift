import Foundation

// Mesures et statistiques du ping continu : séries bornées, min/moy/max, jitter, perte, P95.

/// Raison d'une perte.
public enum PingFailure: Equatable, Sendable {
    /// Aucune réponse dans le délai.
    case timeout
    /// Paquet refusé par l'interface (taille supérieure au MTU avec DF).
    case messageTooLong
    /// « Destination inaccessible » reçue d'un routeur (code ICMP).
    case unreachable(code: UInt8, from: IPv4Address?)
    /// Échec d'envoi (errno).
    case sendFailed(errno: Int32)

    public var label: String {
        switch self {
        case .timeout: return "délai dépassé"
        case .messageTooLong: return "paquet trop grand (DF)"
        case let .unreachable(code, from):
            let reason: String
            switch code {
            case 0: reason = "réseau inaccessible"
            case 1: reason = "hôte inaccessible"
            case 4: reason = "fragmentation nécessaire (DF)"
            case 9, 10, 13: reason = "filtré par un pare-feu"
            default: reason = "destination inaccessible (code \(code))"
            }
            if let from { return "\(reason), signalé par \(from)" }
            return reason
        case let .sendFailed(code):
            return "envoi impossible (\(String(cString: strerror(code))))"
        }
    }
}

/// Une mesure : numéro de séquence, heure d'envoi, temps aller-retour (nil si perdu).
public struct PingSample: Equatable, Sendable {
    public let sequence: Int
    public let date: Date
    public let rttMs: Double?
    public let failure: PingFailure?

    public init(sequence: Int, date: Date, rttMs: Double?, failure: PingFailure? = nil) {
        self.sequence = sequence
        self.date = date
        self.rttMs = rttMs
        self.failure = rttMs == nil ? (failure ?? .timeout) : nil
    }

    public var isLost: Bool { rttMs == nil }
}

/// Statistiques d'une série de mesures (nil : perdu).
public struct PingStatistics: Equatable, Sendable {
    public let sent: Int
    public let received: Int
    public let min: Double?
    public let max: Double?
    public let average: Double?
    /// Écart moyen entre deux réponses consécutives (définition d'usage des outils de ping).
    public let jitter: Double?
    /// 95e centile (rang le plus proche, par défaut).
    public let p95: Double?
    /// Écart-type (population).
    public let standardDeviation: Double?

    public var lost: Int { sent - received }
    public var lossPercent: Double { sent == 0 ? 0 : Double(lost) / Double(sent) * 100 }

    public static let empty = PingStatistics(values: [])

    public init(values: [Double?]) {
        let received = values.compactMap { $0 }
        sent = values.count
        self.received = received.count
        guard !received.isEmpty else {
            min = nil; max = nil; average = nil; jitter = nil; p95 = nil; standardDeviation = nil
            return
        }
        var sum = 0.0, sumSquares = 0.0, low = Double.infinity, high = -Double.infinity, deltas = 0.0
        for (index, value) in received.enumerated() {
            sum += value
            sumSquares += value * value
            low = Swift.min(low, value)
            high = Swift.max(high, value)
            if index > 0 { deltas += abs(value - received[index - 1]) }
        }
        let mean = sum / Double(received.count)
        min = low
        max = high
        average = mean
        jitter = received.count > 1 ? deltas / Double(received.count - 1) : 0
        let sorted = received.sorted()
        p95 = sorted[Int((0.95 * Double(sorted.count - 1)).rounded(.down))]
        standardDeviation = Swift.max(0, sumSquares / Double(received.count) - mean * mean).squareRoot()
    }
}

/// Historique borné d'une cible (600 mesures par défaut) et compteurs depuis la réinitialisation.
public struct PingHistory: Sendable {
    public static let defaultCapacity = 600

    public let capacity: Int
    public private(set) var samples: [PingSample] = []
    public private(set) var totalSent = 0
    public private(set) var totalReceived = 0
    /// Pertes consécutives en cours.
    public private(set) var consecutiveLosses = 0

    public init(capacity: Int = PingHistory.defaultCapacity) {
        self.capacity = Swift.max(1, capacity)
    }

    public var last: PingSample? { samples.last }
    public var isEmpty: Bool { samples.isEmpty }

    public mutating func append(_ sample: PingSample) {
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        totalSent += 1
        if sample.isLost {
            consecutiveLosses += 1
        } else {
            totalReceived += 1
            consecutiveLosses = 0
        }
    }

    public mutating func reset() {
        samples.removeAll()
        totalSent = 0
        totalReceived = 0
        consecutiveLosses = 0
    }

    /// Les `count` dernières valeurs (toutes si nil).
    public func values(last count: Int? = nil) -> [Double?] {
        let slice = count.map { samples.suffix($0) } ?? samples[...]
        return slice.map(\.rttMs)
    }

    public func statistics(last count: Int? = nil) -> PingStatistics {
        PingStatistics(values: values(last: count))
    }
}

/// État d'une cible, d'après ses dernières mesures.
public enum PingTargetStatus: String, Sendable {
    case attente, enLigne, perte, horsLigne

    /// Pertes consécutives à partir desquelles la cible est « hors ligne ».
    public static let offlineThreshold = 3

    public var label: String {
        switch self {
        case .attente: return "En attente"
        case .enLigne: return "En ligne"
        case .perte: return "Perte"
        case .horsLigne: return "Hors ligne"
        }
    }

    /// Hors ligne après 3 pertes consécutives ; « Perte » s'il manque une réponse parmi les 10 dernières.
    public static func of(_ history: PingHistory) -> PingTargetStatus {
        if history.isEmpty { return .attente }
        if history.consecutiveLosses >= offlineThreshold { return .horsLigne }
        if history.samples.suffix(10).contains(where: \.isLost) { return .perte }
        return .enLigne
    }
}

/// Statistiques cumulées d'un saut MTR.
public struct PingHopStats: Equatable, Sendable {
    public private(set) var sent = 0
    public private(set) var lost = 0
    public private(set) var last: Double?
    public private(set) var best: Double?
    public private(set) var worst: Double?
    private var sum = 0.0
    private var sumSquares = 0.0

    public init() {}

    public mutating func record(_ rttMs: Double?) {
        sent += 1
        guard let value = rttMs else {
            lost += 1
            last = nil
            return
        }
        last = value
        sum += value
        sumSquares += value * value
        best = best.map { Swift.min($0, value) } ?? value
        worst = worst.map { Swift.max($0, value) } ?? value
    }

    public var received: Int { sent - lost }
    public var lossPercent: Double { sent == 0 ? 0 : Double(lost) / Double(sent) * 100 }
    public var average: Double? { received == 0 ? nil : sum / Double(received) }
    public var standardDeviation: Double? {
        guard received > 1, let mean = average else { return nil }
        return Swift.max(0, sumSquares / Double(received) - mean * mean).squareRoot()
    }
}

// MARK: - Mise en forme

/// Nombres à la française (« 17,4 », « 0,8 % »).
public enum PingFormat {
    /// Une décimale, virgule ; « — » si absent.
    public static func decimal(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// « 17,4 ms ».
    public static func ms(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return decimal(value) + " ms"
    }

    /// « 0,8 % ».
    public static func percent(_ value: Double) -> String {
        decimal(value) + " %"
    }

    /// Durée courte : « 0,2 s », « 12 s », « 2 min », « 1,5 min ».
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            let minutes = seconds / 60
            let rounded = minutes.rounded()
            return (abs(minutes - rounded) < 0.05 ? String(Int(rounded)) : decimal(minutes)) + " min"
        }
        if seconds >= 10 { return "\(Int(seconds.rounded())) s" }
        let text = decimal(seconds)
        return (text.hasSuffix(",0") ? String(text.dropLast(2)) : text) + " s"
    }
}
