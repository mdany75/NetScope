import Foundation

// Note 74 : historique du trafic de chaque port de switch, sur la durée.
//
// Chaque relevé d'un switch (SNMP ifHCInOctets/ifHCOutOctets, compteurs de la FortiGate pour un
// FortiSwitch, panneau « Trafic du port » ouvert) donne les compteurs d'octets et d'erreurs en entrée
// de chaque port. L'écart avec le relevé précédent du même port devient un « segment » : débit moyen
// entrant et sortant, nouvelles erreurs. Les segments sont gardés en trois résolutions :
//
//   - 24 dernières heures : résolution du relevé (au plus fin une minute) ;
//   - jusqu'à 7 jours : regroupés par tranches de 5 minutes ;
//   - jusqu'à 90 jours : regroupés à l'heure ; au-delà, oubliés.
//
// Un compteur 32 bits qui fait le tour est corrigé (une fois, quand ce n'est pas ambigu) ; un compteur
// qui recule (switch redémarré, compteurs remis à zéro) ou un débit impossible (au-delà du lien)
// remet simplement la base à la nouvelle valeur, sans point absurde. Une absence de plus d'une heure
// (Mac éteint, NetScope fermé) laisse un trou plutôt qu'une moyenne étalée sur la nuit.
//
// Tout est pur et testé sur des compteurs fixes : aucune lecture réseau ici.

/// Compteurs d'un port à un instant, tels que relevés.
public struct PortCounterReading: Hashable, Sendable {
    public var ifIndex: Int
    public var name: String
    public var alias: String
    /// Vitesse du lien en Mb/s ; nil : inconnue.
    public var speedMbps: UInt64?
    public var isUp: Bool
    public var inOctets: UInt64
    public var outOctets: UInt64
    public var width: CounterWidth
    /// Erreurs en entrée (ifInErrors) ; nil si l'agent ne les donne pas.
    public var inErrors: UInt64?

    public init(ifIndex: Int, name: String, alias: String = "", speedMbps: UInt64? = nil, isUp: Bool = true,
                inOctets: UInt64, outOctets: UInt64, width: CounterWidth = .bits64, inErrors: UInt64? = nil) {
        self.ifIndex = ifIndex
        self.name = name
        self.alias = alias
        self.speedMbps = speedMbps
        self.isUp = isUp
        self.inOctets = inOctets
        self.outOctets = outOctets
        self.width = width
        self.inErrors = inErrors
    }
}

/// Un point de l'historique : octets et erreurs sur une durée, débit le plus fort mesuré.
public struct PortTrafficPoint: Hashable, Sendable {
    /// Début et fin de la période couverte.
    public var start: Date
    public var end: Date
    /// Secondes réellement mesurées (moins que end − start quand deux points avec un trou entre eux
    /// ont été regroupés).
    public var covered: Double
    public var inBytes: Double
    public var outBytes: Double
    /// Débit le plus fort mesuré entre deux relevés (bits par seconde).
    public var inPeak: Double
    public var outPeak: Double
    /// Nouvelles erreurs en entrée.
    public var errors: UInt64

    public init(start: Date, end: Date, covered: Double? = nil, inBytes: Double, outBytes: Double,
                inPeak: Double? = nil, outPeak: Double? = nil, errors: UInt64 = 0) {
        self.start = start
        self.end = max(start, end)
        let span = max(0, end.timeIntervalSince(start))
        self.covered = covered.map { min(max(0, $0), span) } ?? span
        self.inBytes = max(0, inBytes)
        self.outBytes = max(0, outBytes)
        let seconds = max(self.covered, 1)
        self.inPeak = inPeak ?? self.inBytes * 8 / seconds
        self.outPeak = outPeak ?? self.outBytes * 8 / seconds
        self.errors = errors
    }

    /// Débit moyen sur la durée mesurée (bits par seconde).
    public var inAverage: Double { covered > 0 ? inBytes * 8 / covered : 0 }
    public var outAverage: Double { covered > 0 ? outBytes * 8 / covered : 0 }

    /// Regroupe deux points (dans l'ordre).
    func merged(with other: PortTrafficPoint) -> PortTrafficPoint {
        PortTrafficPoint(start: min(start, other.start), end: max(end, other.end), covered: covered + other.covered,
                         inBytes: inBytes + other.inBytes, outBytes: outBytes + other.outBytes,
                         inPeak: max(inPeak, other.inPeak), outPeak: max(outPeak, other.outPeak),
                         errors: errors &+ other.errors)
    }
}

/// Base de comparaison d'un port : son dernier relevé.
public struct PortCounterBaseline: Hashable, Sendable, Codable {
    public var at: Date
    public var inOctets: UInt64
    public var outOctets: UInt64
    public var width: CounterWidth
    public var inErrors: UInt64?

    public init(at: Date, inOctets: UInt64, outOctets: UInt64, width: CounterWidth, inErrors: UInt64?) {
        self.at = at
        self.inOctets = inOctets
        self.outOctets = outOctets
        self.width = width
        self.inErrors = inErrors
    }
}

/// Historique d'un port.
public struct PortTrafficSeries: Hashable, Sendable {
    public var ifIndex: Int
    public var name: String
    public var alias: String
    public var speedMbps: UInt64?
    public var isUp: Bool
    /// Points du plus ancien au plus récent : résolution du relevé (24 h), puis 5 min, puis l'heure.
    public var points: [PortTrafficPoint]
    public var baseline: PortCounterBaseline?

    public init(ifIndex: Int, name: String, alias: String = "", speedMbps: UInt64? = nil, isUp: Bool = true,
                points: [PortTrafficPoint] = [], baseline: PortCounterBaseline? = nil) {
        self.ifIndex = ifIndex
        self.name = name
        self.alias = alias
        self.speedMbps = speedMbps
        self.isUp = isUp
        self.points = points
        self.baseline = baseline
    }

    /// Date du point le plus récent.
    public var lastPointAt: Date? { points.last?.end }
}

/// Historique d'un switch.
public struct PortSwitchHistory: Hashable, Sendable {
    public var host: String
    public var name: String
    public var ports: [Int: PortTrafficSeries]

    public init(host: String, name: String, ports: [Int: PortTrafficSeries] = [:]) {
        self.host = host
        self.name = name
        self.ports = ports
    }

    /// Ports dans l'ordre des ifIndex.
    public var orderedPorts: [PortTrafficSeries] { ports.values.sorted { $0.ifIndex < $1.ifIndex } }
}

/// Historique du trafic des ports de tous les switchs d'un site.
public struct PortTrafficHistory: Hashable, Sendable {
    /// Plus court écart pris en compte entre deux relevés d'un port : un relevé plus rapproché est
    /// ignoré (la base reste l'ancien), pour que deux sources presque simultanées (relevé du switch et
    /// panneau « Trafic du port ») ne donnent pas un pic artificiel.
    public static let minimumSegment: TimeInterval = 15
    /// Au-delà d'une heure sans relevé, l'écart n'est pas compté : un trou plutôt qu'une moyenne.
    public static let maximumSegment: TimeInterval = 3600
    /// Résolution la plus fine gardée : un point couvre au moins une minute.
    public static let finestPoint: TimeInterval = 60
    /// Durée gardée à la résolution du relevé, puis par tranches de 5 min, puis à l'heure.
    public static let fineRetention: TimeInterval = 86_400
    public static let mediumRetention: TimeInterval = 7 * 86_400
    public static let retention: TimeInterval = 90 * 86_400
    public static let mediumStep: TimeInterval = 300
    public static let coarseStep: TimeInterval = 3600

    public private(set) var switches: [String: PortSwitchHistory]

    public init(switches: [String: PortSwitchHistory] = [:]) {
        self.switches = switches
    }

    public var isEmpty: Bool { switches.values.allSatisfy { $0.ports.values.allSatisfy(\.points.isEmpty) } }

    public func history(_ host: String) -> PortSwitchHistory? { switches[host] }

    public func series(_ host: String, ifIndex: Int) -> PortTrafficSeries? { switches[host]?.ports[ifIndex] }

    /// Nombre total de points gardés (taille du fichier).
    public var pointCount: Int { switches.values.reduce(0) { $0 + $1.ports.values.reduce(0) { $0 + $1.points.count } } }

    // MARK: Relevés

    /// Ajoute un relevé d'un switch : un segment par port qui a une base valable.
    /// Renvoie le nombre de ports dont l'historique a reçu un nouveau segment.
    @discardableResult
    public mutating func record(host: String, name: String, at date: Date, readings: [PortCounterReading]) -> Int {
        var history = switches[host] ?? PortSwitchHistory(host: host, name: name)
        if !name.isEmpty { history.name = name }
        var added = 0
        for reading in readings {
            var series = history.ports[reading.ifIndex]
                ?? PortTrafficSeries(ifIndex: reading.ifIndex, name: reading.name, alias: reading.alias,
                                     speedMbps: reading.speedMbps, isUp: reading.isUp)
            series.name = reading.name
            series.alias = reading.alias
            if let speed = reading.speedMbps, speed > 0 { series.speedMbps = speed }
            series.isUp = reading.isUp
            if Self.apply(reading, at: date, to: &series) { added += 1 }
            history.ports[reading.ifIndex] = series
        }
        switches[host] = history
        return added
    }

    /// Applique un relevé à un port. Vrai si un segment a été ajouté.
    static func apply(_ reading: PortCounterReading, at date: Date, to series: inout PortTrafficSeries) -> Bool {
        let fresh = PortCounterBaseline(at: date, inOctets: reading.inOctets, outOctets: reading.outOctets,
                                        width: reading.width, inErrors: reading.inErrors)
        guard let base = series.baseline else {
            series.baseline = fresh
            return false
        }
        let seconds = date.timeIntervalSince(base.at)
        // Relevé déjà vu, plus ancien, ou trop rapproché : la base reste l'ancienne.
        if seconds < minimumSegment { return false }
        series.baseline = fresh
        // Port inactif : rien à garder (un trou dans la courbe, le fichier reste petit).
        // Trop long : un trou. Passage de 32 à 64 bits : rien de comparable.
        guard reading.isUp, seconds <= maximumSegment, base.width == reading.width,
              let segment = segment(from: base, to: fresh, speedMbps: reading.speedMbps ?? series.speedMbps) else { return false }
        add(segment, to: &series.points)
        return true
    }

    /// Segment entre deux relevés ; nil si les compteurs ont été remis à zéro ou si le débit est
    /// impossible (plus de 110 % du lien).
    public static func segment(from base: PortCounterBaseline, to current: PortCounterBaseline, speedMbps: UInt64?) -> PortTrafficPoint? {
        let seconds = current.at.timeIntervalSince(base.at)
        guard seconds > 0, base.width == current.width,
              let inRate = ResourceMath.bitsPerSecond(previous: base.inOctets, current: current.inOctets, width: current.width,
                                                      seconds: seconds, speedMbps: speedMbps),
              let outRate = ResourceMath.bitsPerSecond(previous: base.outOctets, current: current.outOctets, width: current.width,
                                                       seconds: seconds, speedMbps: speedMbps) else { return nil }
        if let speed = speedMbps, speed > 0 {
            let limit = Double(speed) * 1_000_000 * 1.1
            if inRate > limit || outRate > limit { return nil }
        }
        // Erreurs : un compteur qui recule a été remis à zéro ; on ne compte que la hausse.
        var errors: UInt64 = 0
        if let before = base.inErrors, let after = current.inErrors, after >= before { errors = after - before }
        return PortTrafficPoint(start: base.at, end: current.at, covered: seconds,
                                inBytes: inRate * seconds / 8, outBytes: outRate * seconds / 8,
                                inPeak: inRate, outPeak: outRate, errors: errors)
    }

    /// Ajoute un segment à la fin : regroupé avec le dernier point tant que celui-ci couvre moins
    /// d'une minute et qu'il le touche.
    static func add(_ segment: PortTrafficPoint, to points: inout [PortTrafficPoint]) {
        if let last = points.last, last.covered < finestPoint, abs(segment.start.timeIntervalSince(last.end)) < 1 {
            points[points.count - 1] = last.merged(with: segment)
        } else {
            points.append(segment)
        }
    }

    // MARK: Taille bornée

    /// Regroupe les points anciens (5 min au-delà de 24 h, l'heure au-delà de 7 jours), oublie ce qui
    /// a plus de 90 jours, puis les ports et switchs sans rien de récent.
    public mutating func compact(now: Date) {
        for host in Array(switches.keys) {
            guard var history = switches[host] else { continue }
            for index in Array(history.ports.keys) {
                guard var series = history.ports[index] else { continue }
                series.points = Self.compacted(series.points, now: now)
                // Base trop vieille : inutile (le prochain écart dépasserait une heure de toute façon).
                if let base = series.baseline, now.timeIntervalSince(base.at) > Self.retention { series.baseline = nil }
                if series.points.isEmpty && series.baseline == nil {
                    history.ports[index] = nil
                } else {
                    history.ports[index] = series
                }
            }
            switches[host] = history.ports.isEmpty ? nil : history
        }
    }

    /// Oublie un switch (retiré de la liste).
    public mutating func forget(_ host: String) { switches[host] = nil }

    /// Points regroupés selon leur âge. Les points sont triés par début.
    static func compacted(_ points: [PortTrafficPoint], now: Date) -> [PortTrafficPoint] {
        let oldest = now.addingTimeInterval(-retention)
        let mediumLimit = now.addingTimeInterval(-fineRetention)
        let coarseLimit = now.addingTimeInterval(-mediumRetention)
        var result: [PortTrafficPoint] = []
        result.reserveCapacity(points.count)
        // Tranche de regroupement d'un point (nil : gardé tel quel).
        func bucket(_ point: PortTrafficPoint) -> (step: TimeInterval, start: TimeInterval)? {
            if point.end <= coarseLimit { return (coarseStep, floor(point.start.timeIntervalSince1970 / coarseStep) * coarseStep) }
            if point.end <= mediumLimit { return (mediumStep, floor(point.start.timeIntervalSince1970 / mediumStep) * mediumStep) }
            return nil
        }
        var currentBucket: (step: TimeInterval, start: TimeInterval)?
        for point in points.sorted(by: { $0.start < $1.start }) where point.end > oldest {
            let target = bucket(point)
            if let target, let currentBucket, let last = result.last,
               currentBucket.step == target.step, currentBucket.start == target.start {
                result[result.count - 1] = last.merged(with: point)
            } else {
                result.append(point)
                currentBucket = target
            }
        }
        return result
    }
}
