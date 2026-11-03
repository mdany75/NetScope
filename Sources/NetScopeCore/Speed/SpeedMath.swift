import Foundation

/// Mesure cumulée à un instant donné d'un transfert : `time` en secondes depuis le début de la
/// phase, `totalBytes` octets transférés depuis ce début.
public struct SpeedSample: Hashable, Sendable, Codable {
    public var time: Double
    public var totalBytes: Int64

    public init(time: Double, totalBytes: Int64) {
        self.time = time
        self.totalBytes = totalBytes
    }
}

/// Calculs de débit, de latence et de gigue, sans accès réseau (testables).
public enum SpeedMath {
    /// Débit en Mb/s (mégabits décimaux) pour `bytes` octets en `seconds` secondes.
    public static func megabitsPerSecond(bytes: Int64, seconds: Double) -> Double {
        guard seconds > 0, bytes > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    /// Médiane ; nil pour une liste vide.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Gigue : moyenne des écarts absolus entre mesures consécutives (RFC 3550, sans lissage).
    public static func jitter(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        var total = 0.0
        for index in 1..<values.count { total += abs(values[index] - values[index - 1]) }
        return total / Double(values.count - 1)
    }

    /// Centile `p` (0…1) par interpolation linéaire.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = min(max(p, 0), 1) * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down))
        let high = Int(rank.rounded(.up))
        let weight = rank - Double(low)
        return sorted[low] + (sorted[high] - sorted[low]) * weight
    }

    /// Débit instantané (Mb/s) sur la fenêtre `window` qui précède le dernier échantillon.
    public static func instantRate(_ samples: [SpeedSample], window: Double = 1.0) -> Double {
        guard let last = samples.last else { return 0 }
        let start = samples.last { $0.time <= last.time - window } ?? samples.first!
        return megabitsPerSecond(bytes: last.totalBytes - start.totalBytes, seconds: last.time - start.time)
    }

    /// Débit retenu pour une phase : moyenne en régime établi, après `warmup` secondes de montée
    /// en charge (ouverture TCP, fenêtre de congestion). Si la phase est trop courte, toute la durée.
    public static func steadyRate(_ samples: [SpeedSample], warmup: Double = 2.0) -> Double {
        guard let last = samples.last, samples.count >= 2 else { return 0 }
        let first = samples.first { $0.time >= warmup } ?? samples.first!
        if last.time - first.time >= 1.0 {
            return megabitsPerSecond(bytes: last.totalBytes - first.totalBytes, seconds: last.time - first.time)
        }
        let origin = samples.first!
        return megabitsPerSecond(bytes: last.totalBytes - origin.totalBytes, seconds: last.time - origin.time)
    }

    /// Note de « bufferbloat » d'après la hausse de latence en charge (en ms).
    public static func bufferbloatGrade(idle: Double, loaded: Double) -> String {
        let increase = max(0, loaded - idle)
        switch increase {
        case ..<5: return "A+"
        case ..<30: return "A"
        case ..<60: return "B"
        case ..<200: return "C"
        default: return "D"
        }
    }

    /// Part du forfait atteinte (0,92 = 92 %) ; nil si le forfait est inconnu.
    public static func planRatio(measured: Double, plan: Double) -> Double? {
        guard plan > 0 else { return nil }
        return measured / plan
    }

    /// Seuil de conformité au forfait : 80 %.
    public static let planThreshold = 0.8

    /// Graduation maximale de la jauge (Mb/s) pour afficher `value` : 100, 500, 1000, 2500, 5000, 10000.
    public static func gaugeScale(for value: Double) -> Double {
        for scale in [100.0, 500, 1000, 2500, 5000, 10_000] where value <= scale { return scale }
        return 10_000
    }
}
