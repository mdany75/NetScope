import Foundation

// Calculs des ressources (note 21) : débits à partir de compteurs d'octets (IF-MIB ou interfaces
// de ce Mac), retour à zéro des compteurs 32 bits, pourcentage du lien, charge du processeur à
// partir des tics par cœur, mémoire. Tout est pur et testé sur des compteurs fixes.

/// Largeur d'un compteur : 32 bits (ifInOctets, tics du processeur) ou 64 bits (ifHCInOctets).
public enum CounterWidth: String, Codable, Sendable {
    case bits32, bits64

    /// Valeur maximale du compteur avant le retour à zéro.
    public var maximum: UInt64 { self == .bits32 ? UInt64(UInt32.max) : UInt64.max }
}

/// Compteurs d'une interface à un instant (octets, erreurs, rejets, vitesse du lien).
public struct TrafficCounters: Hashable, Codable, Sendable {
    public var inOctets: UInt64
    public var outOctets: UInt64
    public var width: CounterWidth
    public var inErrors: UInt64?
    public var outErrors: UInt64?
    public var inDiscards: UInt64?
    public var outDiscards: UInt64?
    /// Vitesse du lien en Mb/s (ifHighSpeed, ou débit nominal de l'interface) ; nil : inconnue.
    public var speedMbps: UInt64?

    public init(inOctets: UInt64, outOctets: UInt64, width: CounterWidth = .bits64, inErrors: UInt64? = nil,
                outErrors: UInt64? = nil, inDiscards: UInt64? = nil, outDiscards: UInt64? = nil, speedMbps: UInt64? = nil) {
        self.inOctets = inOctets
        self.outOctets = outOctets
        self.width = width
        self.inErrors = inErrors
        self.outErrors = outErrors
        self.inDiscards = inDiscards
        self.outDiscards = outDiscards
        self.speedMbps = speedMbps
    }

    /// Erreurs et rejets cumulés (entrée et sortie), nil si l'agent n'en donne aucun.
    public var totalErrors: UInt64? {
        let parts = [inErrors, outErrors].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, &+)
    }

    public var totalDiscards: UInt64? {
        let parts = [inDiscards, outDiscards].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, &+)
    }
}

/// Débit calculé entre deux relevés.
public struct TrafficRate: Hashable, Codable, Sendable {
    /// Bits par seconde ; nil quand le compteur a été remis à zéro (redémarrage, interface recréée).
    public var inBitsPerSecond: Double?
    public var outBitsPerSecond: Double?
    /// Pourcentage de la vitesse du lien ; nil si la vitesse est inconnue.
    public var inPercent: Double?
    public var outPercent: Double?
    /// Nouvelles erreurs et nouveaux rejets depuis le relevé précédent.
    public var newErrors: UInt64?
    public var newDiscards: UInt64?
    public var seconds: Double

    public init(inBitsPerSecond: Double?, outBitsPerSecond: Double?, inPercent: Double? = nil, outPercent: Double? = nil,
                newErrors: UInt64? = nil, newDiscards: UInt64? = nil, seconds: Double) {
        self.inBitsPerSecond = inBitsPerSecond
        self.outBitsPerSecond = outBitsPerSecond
        self.inPercent = inPercent
        self.outPercent = outPercent
        self.newErrors = newErrors
        self.newDiscards = newDiscards
        self.seconds = seconds
    }

    /// Charge la plus forte des deux sens (en % du lien).
    public var peakPercent: Double? {
        switch (inPercent, outPercent) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// Débit le plus fort des deux sens (bits/s).
    public var peakBitsPerSecond: Double {
        max(inBitsPerSecond ?? 0, outBitsPerSecond ?? 0)
    }
}

public enum ResourceMath {
    /// Différence entre deux relevés d'un compteur. Un compteur 32 bits qui est revenu à zéro est
    /// corrigé (une seule fois : au-delà, le débit est jugé trop fort par `rate`) ; un compteur
    /// 64 bits qui recule a été remis à zéro : nil.
    public static func counterDelta(previous: UInt64, current: UInt64, width: CounterWidth) -> UInt64? {
        if current >= previous { return current - previous }
        guard width == .bits32, previous <= width.maximum, current <= width.maximum else { return nil }
        return (width.maximum - previous) + current + 1
    }

    /// Débit en bits par seconde entre deux relevés d'octets.
    /// - `speedMbps` : vitesse du lien ; un débit qui dépasse nettement le lien (plus de 110 %)
    ///   trahit une remise à zéro prise pour un retour à zéro : nil plutôt qu'un pic absurde.
    public static func bitsPerSecond(previous: UInt64, current: UInt64, width: CounterWidth, seconds: Double,
                                     speedMbps: UInt64? = nil) -> Double? {
        guard seconds > 0, let delta = counterDelta(previous: previous, current: current, width: width) else { return nil }
        let rate = Double(delta) * 8 / seconds
        if current < previous, let speed = speedMbps, speed > 0, rate > Double(speed) * 1_000_000 * 1.1 {
            return nil
        }
        // Compteur 32 bits : si le lien a pu faire un tour complet de plus pendant l'intervalle
        // (1 Gb/s saturé : 2^32 octets en 34 s), la mesure est ambiguë et peut être très
        // sous-estimée. nil plutôt qu'un débit faux.
        if width == .bits32, let speed = speedMbps, speed > 0 {
            let wrapRate = (Double(delta) + Double(width.maximum) + 1) * 8 / seconds
            if wrapRate <= Double(speed) * 1_000_000 * 1.1 { return nil }
        }
        return rate
    }

    /// Pourcentage de la vitesse du lien (borné à 100 % : un relevé décalé de l'agent peut dépasser un peu).
    public static func linkPercent(bitsPerSecond: Double?, speedMbps: UInt64?) -> Double? {
        guard let bitsPerSecond, let speed = speedMbps, speed > 0 else { return nil }
        return min(100, bitsPerSecond / (Double(speed) * 1_000_000) * 100)
    }

    /// Débit et charge d'une interface entre deux relevés espacés de `seconds`.
    public static func rate(from previous: TrafficCounters, to current: TrafficCounters, seconds: Double) -> TrafficRate {
        // Le passage de 32 à 64 bits (agent qui découvre ifHCInOctets) ne se compare pas.
        guard previous.width == current.width else {
            return TrafficRate(inBitsPerSecond: nil, outBitsPerSecond: nil, seconds: seconds)
        }
        let speed = current.speedMbps ?? previous.speedMbps
        let inRate = bitsPerSecond(previous: previous.inOctets, current: current.inOctets, width: current.width,
                                   seconds: seconds, speedMbps: speed)
        let outRate = bitsPerSecond(previous: previous.outOctets, current: current.outOctets, width: current.width,
                                    seconds: seconds, speedMbps: speed)
        // Erreurs et rejets : un compteur qui recule a été remis à zéro (ils ne font jamais le tour
        // de 2^32 en quelques secondes) ; on ne compte alors rien plutôt qu'un nombre absurde.
        func delta(_ a: UInt64?, _ b: UInt64?) -> UInt64? {
            guard let a, let b, b >= a else { return nil }
            return b - a
        }
        let errors = [delta(previous.inErrors, current.inErrors), delta(previous.outErrors, current.outErrors)].compactMap { $0 }
        let discards = [delta(previous.inDiscards, current.inDiscards), delta(previous.outDiscards, current.outDiscards)].compactMap { $0 }
        return TrafficRate(inBitsPerSecond: inRate, outBitsPerSecond: outRate,
                           inPercent: linkPercent(bitsPerSecond: inRate, speedMbps: speed),
                           outPercent: linkPercent(bitsPerSecond: outRate, speedMbps: speed),
                           newErrors: errors.isEmpty ? nil : errors.reduce(0, &+),
                           newDiscards: discards.isEmpty ? nil : discards.reduce(0, &+),
                           seconds: seconds)
    }
}

// MARK: - Processeur

/// Tics cumulés d'un cœur (host_processor_info) : compteurs 32 bits qui reviennent à zéro.
public struct CPUTicks: Hashable, Codable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64 = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Charge du processeur entre deux relevés, en pourcentage.
public struct CPULoad: Hashable, Codable, Sendable {
    /// Moyenne de tous les cœurs (0 à 100).
    public var total: Double
    /// Part utilisateur et système du total.
    public var user: Double
    public var system: Double
    /// Charge de chaque cœur, dans l'ordre du système (ou de hrProcessorTable).
    public var perCore: [Double]

    public init(total: Double, user: Double = 0, system: Double = 0, perCore: [Double]) {
        self.total = total
        self.user = user
        self.system = system
        self.perCore = perCore
    }

    /// Charge donnée directement en pourcentages (hrProcessorLoad, MIB des constructeurs).
    public static func fromPercentages(_ loads: [Int]) -> CPULoad? {
        let values = loads.map { Double(min(max($0, 0), 100)) }
        guard !values.isEmpty else { return nil }
        let average = values.reduce(0, +) / Double(values.count)
        return CPULoad(total: average, perCore: values)
    }
}

public enum CPUMath {
    /// Charge entre deux relevés de tics (même nombre de cœurs, sinon nil).
    public static func load(previous: [CPUTicks], current: [CPUTicks]) -> CPULoad? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var perCore: [Double] = []
        var busyTotal = 0.0, userTotal = 0.0, systemTotal = 0.0, allTotal = 0.0
        for (a, b) in zip(previous, current) {
            func d(_ x: UInt64, _ y: UInt64) -> Double {
                Double(ResourceMath.counterDelta(previous: x, current: y, width: .bits32) ?? 0)
            }
            let user = d(a.user, b.user) + d(a.nice, b.nice)
            let system = d(a.system, b.system)
            let idle = d(a.idle, b.idle)
            let all = user + system + idle
            perCore.append(all > 0 ? (user + system) / all * 100 : 0)
            busyTotal += user + system
            userTotal += user
            systemTotal += system
            allTotal += all
        }
        guard allTotal > 0 else { return CPULoad(total: 0, perCore: perCore) }
        return CPULoad(total: busyTotal / allTotal * 100, user: userTotal / allTotal * 100,
                       system: systemTotal / allTotal * 100, perCore: perCore)
    }
}

// MARK: - Mémoire

/// Pression mémoire de macOS (kern.memorystatus_vm_pressure_level).
public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical

    public init?(level: Int) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .normal: return "Normale"
        case .warning: return "Élevée"
        case .critical: return "Critique"
        }
    }
}

/// Mémoire d'un appareil : ce Mac (comme le Moniteur d'activité) ou un agent SNMP.
public struct MemoryStats: Hashable, Codable, Sendable {
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    /// Ce Mac : mémoire des apps, câblée, compressée, fichiers en cache.
    public var appBytes: UInt64?
    public var wiredBytes: UInt64?
    public var compressedBytes: UInt64?
    public var cachedBytes: UInt64?
    public var swapUsedBytes: UInt64?
    public var pressure: MemoryPressure?
    /// Pression en pourcentage (100 − kern.memorystatus_level), comme le graphique du Moniteur d'activité.
    public var pressurePercent: Double?

    public init(totalBytes: UInt64, usedBytes: UInt64, appBytes: UInt64? = nil, wiredBytes: UInt64? = nil,
                compressedBytes: UInt64? = nil, cachedBytes: UInt64? = nil, swapUsedBytes: UInt64? = nil,
                pressure: MemoryPressure? = nil, pressurePercent: Double? = nil) {
        self.totalBytes = totalBytes
        self.usedBytes = min(usedBytes, totalBytes)
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
        self.pressurePercent = pressurePercent
    }

    public var usedPercent: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0
    }

    /// Compteurs de pages de vm_statistics64 → mémoire utilisée comme le Moniteur d'activité :
    /// apps (internes − purgeables) + câblée + compressée ; cache = fichiers + purgeables.
    public static func mac(pageSize: UInt64, totalBytes: UInt64, internalPages: UInt64, purgeablePages: UInt64,
                           externalPages: UInt64, wiredPages: UInt64, compressorPages: UInt64,
                           swapUsedBytes: UInt64? = nil, pressureLevel: Int? = nil, memorystatusLevel: Int? = nil) -> MemoryStats {
        let app = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
        let wired = wiredPages * pageSize
        let compressed = compressorPages * pageSize
        let cached = (externalPages + purgeablePages) * pageSize
        let pressurePercent = memorystatusLevel.map { Double(100 - min(max($0, 0), 100)) }
        return MemoryStats(totalBytes: totalBytes, usedBytes: app + wired + compressed, appBytes: app, wiredBytes: wired,
                           compressedBytes: compressed, cachedBytes: cached, swapUsedBytes: swapUsedBytes,
                           pressure: pressureLevel.flatMap(MemoryPressure.init(level:)), pressurePercent: pressurePercent)
    }
}

// MARK: - Mise en forme

/// Mise en forme française des ressources (espaces insécables, virgule décimale).
public enum ResourceFormat {
    private static let nbsp = "\u{00A0}"

    /// « 0 b/s », « 812 kb/s », « 12,4 Mb/s », « 1,05 Gb/s ».
    public static func bitsPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let units = ["b/s", "kb/s", "Mb/s", "Gb/s", "Tb/s"]
        var amount = max(0, value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        return number(amount, unit: unit) + nbsp + units[unit]
    }

    /// « 23 % », « 4,5 % » (une décimale sous 10 %).
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let clamped = max(0, value)
        if clamped > 0, clamped < 0.1 { return "<\u{00A0}0,1" + nbsp + "%" }
        let text = clamped < 10 && clamped > 0 && clamped.rounded() != clamped
            ? ToolFormat.decimal(clamped) : String(clamped.clampedInt)
        return text + nbsp + "%"
    }

    /// Mémoire en unités binaires, libellées comme macOS : « 16 Go », « 11,2 Go », « 512 Mo ».
    public static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let units = ["o", "Ko", "Mo", "Go", "To"]
        var amount = Double(bytes)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        let text: String
        if unit == 0 || amount >= 100 || amount.rounded() == amount { text = String(amount.clampedInt) }
        else { text = ToolFormat.decimal(amount) }
        return text + nbsp + units[unit]
    }

    /// Volume transféré en unités décimales (« 48,2 Go »), comme les compteurs des switchs.
    public static func volume(_ bytes: UInt64?) -> String {
        SNMPFormat.bytes(bytes)
    }

    private static func number(_ amount: Double, unit: Int) -> String {
        if unit == 0 || amount >= 100 { return String(amount.clampedInt) }
        if amount >= 10 { return ToolFormat.decimal(amount) }
        return ToolFormat.decimal(amount, digits: 2)
    }
}
