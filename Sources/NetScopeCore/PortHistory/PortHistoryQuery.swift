import Foundation

// Note 74 : lecture de l'historique d'un port pour les graphes (1 h, 24 h, 7 j, 30 j), débits
// moyen et maximal, pourcentage de la vitesse du lien, erreurs par heure, et classement des ports
// les plus chargés d'un switch ou d'un site. Pur et testé sur des points fixes.

/// Période d'un graphe d'historique.
public enum PortHistoryRange: String, CaseIterable, Codable, Sendable, Identifiable {
    case hour, day, week, month

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }

    /// « 1 h », « 24 h », « 7 j », « 30 j ».
    public var label: String {
        switch self {
        case .hour: return "1\u{00A0}h"
        case .day: return "24\u{00A0}h"
        case .week: return "7\u{00A0}j"
        case .month: return "30\u{00A0}j"
        }
    }

    /// « dernière heure », « dernières 24 h »…
    public var phrase: String {
        switch self {
        case .hour: return "la dernière heure"
        case .day: return "les dernières 24\u{00A0}h"
        case .week: return "les 7 derniers jours"
        case .month: return "les 30 derniers jours"
        }
    }

    /// Largeur d'une colonne du graphe : 60 à 180 colonnes selon la période.
    public var step: TimeInterval {
        switch self {
        case .hour: return 60
        case .day: return 600
        case .week: return 3600
        case .month: return 4 * 3600
        }
    }
}

/// Chiffres d'un port sur une période.
public struct PortHistoryStats: Hashable, Sendable {
    public var range: PortHistoryRange
    /// Secondes mesurées dans la période.
    public var covered: Double
    public var inAverage: Double
    public var outAverage: Double
    public var inPeak: Double
    public var outPeak: Double
    public var errors: UInt64
    public var speedMbps: UInt64?

    public init(range: PortHistoryRange, covered: Double = 0, inAverage: Double = 0, outAverage: Double = 0,
                inPeak: Double = 0, outPeak: Double = 0, errors: UInt64 = 0, speedMbps: UInt64? = nil) {
        self.range = range
        self.covered = covered
        self.inAverage = inAverage
        self.outAverage = outAverage
        self.inPeak = inPeak
        self.outPeak = outPeak
        self.errors = errors
        self.speedMbps = speedMbps
    }

    public var hasData: Bool { covered > 0 }

    /// Part de la période réellement mesurée (0 à 1).
    public var coverage: Double { min(1, covered / range.seconds) }

    public var inAveragePercent: Double? { ResourceMath.linkPercent(bitsPerSecond: inAverage, speedMbps: speedMbps) }
    public var outAveragePercent: Double? { ResourceMath.linkPercent(bitsPerSecond: outAverage, speedMbps: speedMbps) }
    public var inPeakPercent: Double? { ResourceMath.linkPercent(bitsPerSecond: inPeak, speedMbps: speedMbps) }
    public var outPeakPercent: Double? { ResourceMath.linkPercent(bitsPerSecond: outPeak, speedMbps: speedMbps) }

    /// Charge maximale, le plus chargé des deux sens (% du lien).
    public var peakPercent: Double? {
        let values = [inPeakPercent, outPeakPercent].compactMap { $0 }
        return values.max()
    }

    /// Charge moyenne du sens le plus chargé (% du lien).
    public var averagePercent: Double? {
        let values = [inAveragePercent, outAveragePercent].compactMap { $0 }
        return values.max()
    }

    public var peakBitsPerSecond: Double { max(inPeak, outPeak) }
    public var averageBitsPerSecond: Double { max(inAverage, outAverage) }

    /// Erreurs par heure mesurée ; nil sans mesure.
    public var errorsPerHour: Double? {
        guard covered > 0 else { return nil }
        return Double(errors) / (covered / 3600)
    }
}

/// Courbe d'un port : une valeur par colonne (nil : rien de mesuré).
public struct PortHistoryCurve: Hashable, Sendable {
    public var range: PortHistoryRange
    public var start: Date
    public var end: Date
    public var inValues: [Double?]
    public var outValues: [Double?]

    public init(range: PortHistoryRange, start: Date, end: Date, inValues: [Double?], outValues: [Double?]) {
        self.range = range
        self.start = start
        self.end = end
        self.inValues = inValues
        self.outValues = outValues
    }

    public var isEmpty: Bool { !inValues.contains { $0 != nil } }
}

/// Port classé parmi les plus chargés.
public struct PortHistorySummary: Hashable, Sendable, Identifiable {
    public var id: String { "\(host)|\(ifIndex)" }
    public var host: String
    public var switchName: String
    public var ifIndex: Int
    public var name: String
    public var alias: String
    public var isUp: Bool
    public var stats: PortHistoryStats

    public init(host: String, switchName: String, ifIndex: Int, name: String, alias: String, isUp: Bool, stats: PortHistoryStats) {
        self.host = host
        self.switchName = switchName
        self.ifIndex = ifIndex
        self.name = name
        self.alias = alias
        self.isUp = isUp
        self.stats = stats
    }
}

extension PortTrafficSeries {
    /// Part d'un point comprise dans [from, to] (0 à 1).
    static func overlap(_ point: PortTrafficPoint, from: Date, to: Date) -> Double {
        let span = point.end.timeIntervalSince(point.start)
        guard span > 0 else { return point.start >= from && point.start <= to ? 1 : 0 }
        let a = max(point.start, from), b = min(point.end, to)
        return max(0, b.timeIntervalSince(a)) / span
    }

    /// Chiffres du port sur la période qui finit à `now`.
    public func stats(_ range: PortHistoryRange, now: Date) -> PortHistoryStats {
        let from = now.addingTimeInterval(-range.seconds)
        var stats = PortHistoryStats(range: range, speedMbps: speedMbps)
        var inBytes = 0.0, outBytes = 0.0, errors = 0.0
        for point in points where point.end > from && point.start < now {
            let share = Self.overlap(point, from: from, to: now)
            guard share > 0 else { continue }
            stats.covered += point.covered * share
            inBytes += point.inBytes * share
            outBytes += point.outBytes * share
            errors += Double(point.errors) * share
            stats.inPeak = max(stats.inPeak, point.inPeak)
            stats.outPeak = max(stats.outPeak, point.outPeak)
        }
        if stats.covered > 0 {
            stats.inAverage = inBytes * 8 / stats.covered
            stats.outAverage = outBytes * 8 / stats.covered
        }
        stats.errors = UInt64(errors.rounded())
        return stats
    }

    /// Courbe du port sur la période (débit moyen de chaque colonne). Une colonne mesurée à moins
    /// de 10 % reste vide : un trou plutôt qu'une valeur trompeuse.
    public func curve(_ range: PortHistoryRange, now: Date) -> PortHistoryCurve {
        let step = range.step
        let count = Int((range.seconds / step).rounded())
        // Colonnes alignées sur l'horloge (minutes, dizaines de minutes, heures).
        let end = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / step) * step)
        let start = end.addingTimeInterval(-Double(count) * step)
        var covered = [Double](repeating: 0, count: count)
        var inBytes = [Double](repeating: 0, count: count)
        var outBytes = [Double](repeating: 0, count: count)
        for point in points where point.end > start && point.start < end {
            let span = point.end.timeIntervalSince(point.start)
            guard span > 0 else { continue }
            let first = max(0, Int(floor(point.start.timeIntervalSince(start) / step)))
            let last = min(count - 1, Int(floor((point.end.timeIntervalSince(start) - 0.000_1) / step)))
            guard first <= last else { continue }
            for column in first...last {
                let a = start.addingTimeInterval(Double(column) * step)
                let share = Self.overlap(point, from: a, to: a.addingTimeInterval(step))
                guard share > 0 else { continue }
                covered[column] += point.covered * share
                inBytes[column] += point.inBytes * share
                outBytes[column] += point.outBytes * share
            }
        }
        var inValues: [Double?] = []
        var outValues: [Double?] = []
        for column in 0..<count {
            if covered[column] >= step * 0.1 {
                inValues.append(inBytes[column] * 8 / covered[column])
                outValues.append(outBytes[column] * 8 / covered[column])
            } else {
                inValues.append(nil)
                outValues.append(nil)
            }
        }
        return PortHistoryCurve(range: range, start: start, end: end, inValues: inValues, outValues: outValues)
    }
}

public enum PortHistoryRanking {
    /// Ports d'un switch avec leurs chiffres sur la période (ports sans mesure écartés).
    public static func summaries(_ history: PortSwitchHistory, range: PortHistoryRange, now: Date,
                                 physicalOnly: Set<Int>? = nil) -> [PortHistorySummary] {
        history.orderedPorts.compactMap { series in
            if let physicalOnly, !physicalOnly.contains(series.ifIndex) { return nil }
            let stats = series.stats(range, now: now)
            guard stats.hasData else { return nil }
            return PortHistorySummary(host: history.host, switchName: history.name, ifIndex: series.ifIndex, name: series.name,
                                      alias: series.alias, isUp: series.isUp, stats: stats)
        }
    }

    /// Ports les plus chargés : charge maximale (% du lien) d'abord, puis débit moyen.
    public static func busiest(_ list: [PortHistorySummary], limit: Int? = nil) -> [PortHistorySummary] {
        let sorted = list.sorted { a, b in
            let pa = a.stats.peakPercent ?? -1, pb = b.stats.peakPercent ?? -1
            if pa != pb { return pa > pb }
            if a.stats.averageBitsPerSecond != b.stats.averageBitsPerSecond { return a.stats.averageBitsPerSecond > b.stats.averageBitsPerSecond }
            return (a.switchName, a.ifIndex) < (b.switchName, b.ifIndex)
        }
        guard let limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Erreurs en entrée par heure de chaque port d'un switch, sur les dernières 24 h (au moins
    /// 15 minutes mesurées, sinon le port n'a pas encore de mesure fiable).
    public static func errorRates(_ history: PortSwitchHistory, now: Date,
                                  minimumCoverage: TimeInterval = 900) -> [Int: PortErrorRate] {
        var result: [Int: PortErrorRate] = [:]
        for series in history.ports.values {
            let stats = series.stats(.day, now: now)
            guard stats.covered >= minimumCoverage else { continue }
            result[series.ifIndex] = PortErrorRate(errors: stats.errors, seconds: stats.covered)
        }
        return result
    }
}

/// Erreurs d'un port mesurées sur une durée.
public struct PortErrorRate: Hashable, Sendable {
    public var errors: UInt64
    public var seconds: TimeInterval

    public init(errors: UInt64, seconds: TimeInterval) {
        self.errors = errors
        self.seconds = seconds
    }

    public var perHour: Double { seconds > 0 ? Double(errors) / (seconds / 3600) : 0 }

    /// Seuils (erreurs par heure) : conseil, puis alerte.
    public static let adviceThreshold: Double = 20
    public static let warningThreshold: Double = 200

    /// Gravité : 0 rien, 1 à surveiller, 2 alerte.
    public var level: Int {
        if perHour >= Self.warningThreshold { return 2 }
        if perHour >= Self.adviceThreshold, errors >= 5 { return 1 }
        return 0
    }

    /// « 45 min », « 3 h 20 », « 24 h ».
    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return PortErrorTracker.durationLabel(seconds) }
        if minutes % 60 == 0 { return "\(minutes / 60)\u{00A0}h" }
        return PortErrorTracker.durationLabel(seconds)
    }

    /// « 37/h », « 0,4/h », « 0/h ».
    public static func label(_ perHour: Double?) -> String {
        guard let perHour else { return "—" }
        if perHour == 0 { return "0/h" }
        let text: String
        if perHour < 10 {
            text = String(format: "%.1f", perHour).replacingOccurrences(of: ".", with: ",")
        } else {
            text = ToolFormat.integer(UInt64(perHour.rounded()))
        }
        return "\(text)/h"
    }
}

extension PortErrorRate {
    /// Erreurs récentes du suivi en mémoire (30 min, `PortErrorTracker`) quand l'historique n'a pas
    /// encore assez de mesures.
    public init(_ delta: PortErrorDelta) {
        self.init(errors: delta.newErrors, seconds: delta.seconds)
    }
}
