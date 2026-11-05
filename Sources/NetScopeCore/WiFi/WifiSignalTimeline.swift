import Foundation

// Note 78 (Wi-Fi de ce Mac) : historique du signal de la connexion au-delà de 2 minutes, jusqu'à
// une heure. Un relevé toutes les 2 s quand l'écran Wi-Fi est ouvert (toutes les 10 s sinon), lu
// localement par CoreWLAN ; rien n'est envoyé. Les relevés plus vieux qu'une heure sont oubliés.
// Le graphe regroupe les relevés par tranches (minimum, moyenne, maximum) ; une tranche sans
// relevé ou sans connexion coupe la courbe au lieu de relier deux points éloignés.

/// Un relevé de la connexion (rssi nil : déconnecté).
public struct WifiSignalSample: Hashable, Sendable {
    public var time: Date
    public var rssi: Int?
    public var noise: Int?
    public var channel: Int?
    public var bssid: String?

    public init(time: Date, rssi: Int?, noise: Int? = nil, channel: Int? = nil, bssid: String? = nil) {
        self.time = time
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.bssid = bssid
    }
}

/// Durée affichée par le graphe de l'historique.
public enum WifiSignalSpan: Int, CaseIterable, Identifiable, Sendable {
    case twoMinutes = 120
    case tenMinutes = 600
    case thirtyMinutes = 1800
    case oneHour = 3600

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    /// « 2 min », « 1 h ».
    public var label: String {
        rawValue >= 3600 ? "\(rawValue / 3600)\u{00A0}h" : "\(rawValue / 60)\u{00A0}min"
    }

    /// Libellés de l'axe des temps (gauche, milieu).
    public var axisLabels: (start: String, middle: String) {
        switch self {
        case .twoMinutes: return ("\u{2212}2\u{00A0}min", "\u{2212}1\u{00A0}min")
        case .tenMinutes: return ("\u{2212}10\u{00A0}min", "\u{2212}5\u{00A0}min")
        case .thirtyMinutes: return ("\u{2212}30\u{00A0}min", "\u{2212}15\u{00A0}min")
        case .oneHour: return ("\u{2212}1\u{00A0}h", "\u{2212}30\u{00A0}min")
        }
    }

    /// Nombre de tranches du graphe (une par relevé de 2 s pour 2 minutes, au plus 120).
    public var bucketCount: Int { self == .twoMinutes ? 60 : 120 }
}

/// Historique d'une heure au plus.
public struct WifiSignalTimeline: Hashable, Sendable {
    public static let maxAge: TimeInterval = 3600
    /// Au-delà de cet écart sans relevé, la courbe est coupée.
    public static let gapTolerance: TimeInterval = 25

    public private(set) var samples: [WifiSignalSample] = []

    public init(samples: [WifiSignalSample] = []) {
        self.samples = samples.sorted { $0.time < $1.time }
    }

    /// Ajoute un relevé et oublie ceux de plus d'une heure.
    public mutating func append(_ sample: WifiSignalSample) {
        if let last = samples.last, sample.time < last.time {
            let index = samples.firstIndex { $0.time > sample.time } ?? samples.endIndex
            samples.insert(sample, at: index)
        } else {
            samples.append(sample)
        }
        prune(now: samples.last?.time ?? sample.time)
    }

    public mutating func prune(now: Date) {
        let limit = now.addingTimeInterval(-Self.maxAge)
        if let first = samples.firstIndex(where: { $0.time >= limit }) {
            if first > 0 { samples.removeFirst(first) }
        } else {
            samples.removeAll()
        }
    }

    /// Relevés des `seconds` dernières secondes.
    public func window(_ seconds: TimeInterval, now: Date) -> [WifiSignalSample] {
        let limit = now.addingTimeInterval(-seconds)
        return samples.filter { $0.time >= limit && $0.time <= now }
    }

    /// Durée réellement couverte par l'historique (du plus ancien relevé à maintenant).
    public func coveredSeconds(now: Date) -> TimeInterval {
        guard let first = samples.first else { return 0 }
        return max(0, now.timeIntervalSince(first.time))
    }

    // MARK: Résumé

    public struct Stats: Hashable, Sendable {
        public var minimum: Int
        public var maximum: Int
        public var average: Int
        /// Relevés connectés.
        public var count: Int
        /// Relevés sans connexion.
        public var disconnected: Int
        /// Changements de borne (BSSID) dans la fenêtre.
        public var roams: Int
        /// Bruit moyen, si connu.
        public var averageNoise: Int?

        /// Part des relevés sous −70 dBm, en %.
        public var weakPercent: Int
    }

    public func stats(_ seconds: TimeInterval, now: Date) -> Stats? {
        let list = window(seconds, now: now)
        let values = list.compactMap(\.rssi)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let average = Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        let noises = list.compactMap(\.noise)
        let noise = noises.isEmpty ? nil : Int((Double(noises.reduce(0, +)) / Double(noises.count)).rounded())
        let weak = values.filter { $0 < -70 }.count
        return Stats(minimum: lo, maximum: hi, average: average, count: values.count,
                     disconnected: list.count - values.count, roams: roamTimes(seconds, now: now).count,
                     averageNoise: noise, weakPercent: Int((Double(weak) / Double(values.count) * 100).rounded()))
    }

    /// Instants où la connexion a changé de borne (BSSID différent du relevé connecté précédent).
    public func roamTimes(_ seconds: TimeInterval, now: Date) -> [Date] {
        var result: [Date] = []
        var previous: String?
        for sample in window(seconds, now: now) {
            guard sample.rssi != nil, let bssid = sample.bssid else { continue }
            if let previous, previous != bssid { result.append(sample.time) }
            previous = bssid
        }
        return result
    }

    // MARK: Graphe

    /// Une tranche du graphe : nil quand aucun relevé connecté n'y tombe (courbe coupée).
    public struct Bucket: Hashable, Sendable {
        public var start: Date
        public var minimum: Int?
        public var maximum: Int?
        public var average: Double?

        public var hasData: Bool { average != nil }
    }

    /// `count` tranches égales sur les `seconds` dernières secondes, de la plus ancienne à la plus récente.
    public func buckets(_ seconds: TimeInterval, now: Date, count: Int) -> [Bucket] {
        let total = max(1, count)
        let width = seconds / Double(total)
        let start = now.addingTimeInterval(-seconds)
        var lists = Array(repeating: [Int](), count: total)
        for sample in window(seconds, now: now) {
            guard let rssi = sample.rssi else { continue }
            let index = min(total - 1, max(0, Int(sample.time.timeIntervalSince(start) / width)))
            lists[index].append(rssi)
        }
        return lists.enumerated().map { index, values in
            Bucket(start: start.addingTimeInterval(Double(index) * width), minimum: values.min(), maximum: values.max(),
                   average: values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count))
        }
    }

    /// Tranches à relier : une tranche vide isolée entre deux pleines est comblée quand l'écart réel
    /// entre les relevés reste sous `gapTolerance` (relevés toutes les 10 s en arrière-plan).
    public func drawableBuckets(_ seconds: TimeInterval, now: Date, count: Int) -> [Bucket] {
        var list = buckets(seconds, now: now, count: count)
        let width = seconds / Double(max(1, count))
        guard width < Self.gapTolerance, list.count >= 3 else { return list }
        for index in 1..<(list.count - 1) where !list[index].hasData {
            // Remplit un trou d'une ou deux tranches entouré de données.
            guard let before = list[..<index].lastIndex(where: \.hasData),
                  let after = list[(index + 1)...].firstIndex(where: \.hasData),
                  Double(after - before) * width <= Self.gapTolerance,
                  let a = list[before].average, let b = list[after].average else { continue }
            let t = Double(index - before) / Double(after - before)
            list[index].average = a + (b - a) * t
        }
        return list
    }
}
