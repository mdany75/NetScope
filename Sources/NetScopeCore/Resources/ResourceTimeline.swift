import Foundation

/// Série mesurée d'une courbe de ressources (« cpu », « en0.in »…).
public struct ResourceColumn: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    /// En-tête du CSV (« Processeur (%) »).
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Un relevé : la date et la valeur de chaque série (absente : trou dans la courbe).
public struct ResourceSample: Hashable, Codable, Sendable {
    public var date: Date
    public var values: [String: Double]

    public init(date: Date, values: [String: Double]) {
        self.date = date
        self.values = values
    }
}

/// Historique court, en mémoire seulement : les relevés plus vieux que `window` sont oubliés.
public struct ResourceTimeline: Sendable {
    /// Durée gardée (5 minutes par défaut : « courbes sur quelques minutes »).
    public var window: TimeInterval
    /// Plafond de relevés (sécurité si l'intervalle est très court).
    public var capacity: Int
    public private(set) var columns: [ResourceColumn] = []
    public private(set) var samples: [ResourceSample] = []

    public init(window: TimeInterval = 300, capacity: Int = 1200) {
        self.window = window
        self.capacity = max(2, capacity)
    }

    /// Ajoute un relevé ; les nouvelles séries s'ajoutent aux colonnes (ordre d'apparition).
    public mutating func append(_ sample: ResourceSample, titles: [String: String] = [:]) {
        for key in sample.values.keys.sorted() where !columns.contains(where: { $0.id == key }) {
            columns.append(ResourceColumn(id: key, title: titles[key] ?? key))
        }
        // Un relevé plus ancien que le dernier (horloge reculée) remplace la suite : l'ordre reste croissant.
        if let last = samples.last, sample.date < last.date {
            samples.removeAll { $0.date >= sample.date }
        }
        samples.append(sample)
        trim(now: sample.date)
    }

    /// Déclare les colonnes dans l'ordre voulu (avant les premiers relevés).
    public mutating func declare(_ columns: [ResourceColumn]) {
        for column in columns where !self.columns.contains(where: { $0.id == column.id }) {
            self.columns.append(column)
        }
    }

    public mutating func trim(now: Date) {
        let limit = now.addingTimeInterval(-window)
        if let first = samples.firstIndex(where: { $0.date >= limit }), first > 0 {
            samples.removeFirst(first)
        } else if samples.last.map({ $0.date < limit }) == true {
            samples.removeAll()
        }
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public mutating func removeAll() {
        samples.removeAll()
    }

    /// Valeurs d'une série dans l'ordre des relevés (nil : trou).
    public func series(_ key: String) -> [Double?] {
        samples.map { $0.values[key] }
    }

    /// Points datés d'une série.
    public func points(_ key: String) -> [(date: Date, value: Double?)] {
        samples.map { ($0.date, $0.values[key]) }
    }

    public var latest: ResourceSample? { samples.last }

    /// Somme, à chaque relevé, des séries dont la clé finit par `suffix` (« .in » : trafic entrant total).
    public func sum(suffix: String) -> [Double?] {
        samples.map { sample in
            let values = sample.values.filter { $0.key.hasSuffix(suffix) }.map(\.value)
            return values.isEmpty ? nil : values.reduce(0, +)
        }
    }

    /// Valeur maximale d'une ou plusieurs séries sur la fenêtre.
    public func maximum(_ keys: [String]) -> Double? {
        samples.flatMap { sample in keys.compactMap { sample.values[$0] } }.max()
    }

    /// Moyenne d'une série sur la fenêtre.
    public func average(_ key: String) -> Double? {
        let values = samples.compactMap { $0.values[key] }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Export CSV (séparateur « ; », décimales à la virgule, comme Excel en français).
    /// - `keys` : séries à exporter, dans l'ordre (toutes par défaut).
    public func csv(keys: [String]? = nil, timeZone: TimeZone = .current) -> String {
        let chosen = keys.map { list in list.compactMap { key in columns.first { $0.id == key } } } ?? columns
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func field(_ text: String) -> String {
            guard text.contains(";") || text.contains("\"") || text.contains("\n") else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            let text = value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%.2f", value)
            return text.replacingOccurrences(of: ".", with: ",")
        }
        var lines = [(["Date"] + chosen.map(\.title)).map(field).joined(separator: ";")]
        for sample in samples {
            lines.append(([formatter.string(from: sample.date)] + chosen.map { number(sample.values[$0.id]) }).joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Intervalles de relevé proposés (secondes).
public enum ResourceInterval {
    /// Ce Mac : lecture locale, peu coûteuse.
    public static let local: [Double] = [1, 2, 5, 10]
    /// SNMP : chaque relevé interroge l'agent ; au moins 5 s.
    public static let snmp: [Double] = [5, 10, 30, 60]

    /// « 1 s », « 30 s », « 1 min ».
    public static func label(_ seconds: Double) -> String {
        seconds >= 60 ? "\(Int(seconds / 60))\u{00A0}min" : "\(Int(seconds))\u{00A0}s"
    }
}

// MARK: - Ports les plus chargés

/// Charge d'un port entre deux relevés.
public struct PortLoad: Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var name: String
    public var alias: String
    public var isUp: Bool
    public var speedMbps: UInt64?
    public var rate: TrafficRate
    public var counters: TrafficCounters

    public init(index: Int, name: String, alias: String = "", isUp: Bool = true, speedMbps: UInt64?, rate: TrafficRate,
                counters: TrafficCounters) {
        self.index = index
        self.name = name
        self.alias = alias
        self.isUp = isUp
        self.speedMbps = speedMbps
        self.rate = rate
        self.counters = counters
    }
}

public enum TopPorts {
    /// Débits de chaque port entre deux relevés (ports présents dans les deux, mêmes index).
    public static func loads(previous: [SNMPPortCounters], current: [SNMPPortCounters], seconds: Double) -> [PortLoad] {
        let before = Dictionary(previous.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        return current.compactMap { port in
            guard let old = before[port.index] else { return nil }
            return PortLoad(index: port.index, name: port.name, alias: port.alias, isUp: port.isUp,
                            speedMbps: port.counters.speedMbps,
                            rate: ResourceMath.rate(from: old.counters, to: port.counters, seconds: seconds),
                            counters: port.counters)
        }
    }

    /// Ports les plus chargés : % du lien d'abord (le plus fort des deux sens), puis débit ; les
    /// ports inactifs ou sans trafic mesurable sont écartés.
    public static func rank(_ loads: [PortLoad], limit: Int = 5) -> [PortLoad] {
        loads.filter { $0.isUp && ($0.rate.inBitsPerSecond != nil || $0.rate.outBitsPerSecond != nil) }
            .sorted { a, b in
                let pa = a.rate.peakPercent ?? -1, pb = b.rate.peakPercent ?? -1
                if pa != pb { return pa > pb }
                if a.rate.peakBitsPerSecond != b.rate.peakBitsPerSecond { return a.rate.peakBitsPerSecond > b.rate.peakBitsPerSecond }
                return a.index < b.index
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
