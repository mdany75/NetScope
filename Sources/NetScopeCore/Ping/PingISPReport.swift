import Foundation

// Note 78 (0.26.0) : rapport « pour le fournisseur Internet » du ping continu. L'historique d'une
// cible (600 mesures) ne couvre que quelques minutes ; le journal long garde, heure par heure,
// de quoi prouver un problème sur plusieurs jours : perte, latence, gigue, mesures au-dessus du
// seuil, et les périodes de panne (3 pertes consécutives ou plus). Aucun réseau ici.

/// Agrégat d'une heure de mesures pour une cible.
public struct PingHourBucket: Codable, Equatable, Sendable {
    /// Début de l'heure (minutes et secondes à zéro, fuseau du calendrier utilisé).
    public var hourStart: Date
    public var sent = 0
    public var received = 0
    public var sum = 0.0
    public var min: Double?
    public var max: Double?
    /// Somme des écarts entre deux réponses consécutives (gigue = moyenne de ces écarts).
    public var jitterSum = 0.0
    public var jitterCount = 0
    /// Réponses au-dessus du seuil de lenteur de la cible.
    public var slow = 0

    public init(hourStart: Date) {
        self.hourStart = hourStart
    }

    public var lost: Int { sent - received }
    public var lossPercent: Double { sent == 0 ? 0 : Double(lost) / Double(sent) * 100 }
    public var average: Double? { received == 0 ? nil : sum / Double(received) }
    public var jitter: Double? { jitterCount == 0 ? nil : jitterSum / Double(jitterCount) }
}

/// Période de panne : du premier paquet perdu d'une série d'au moins 3 pertes au premier paquet reçu.
public struct PingOutage: Codable, Equatable, Sendable {
    public var start: Date
    /// nil : panne en cours.
    public var end: Date?
    public var lostPackets: Int

    public init(start: Date, end: Date? = nil, lostPackets: Int) {
        self.start = start
        self.end = end
        self.lostPackets = lostPackets
    }

    public func duration(until now: Date) -> TimeInterval {
        Swift.max(0, (end ?? now).timeIntervalSince(start))
    }
}

/// Journal long d'une cible : agrégats horaires et pannes. Borné (31 jours, 500 pannes).
public struct PingLongLog: Codable, Equatable, Sendable {
    public static let maxHours = 24 * 31
    public static let maxOutages = 500

    public private(set) var buckets: [PingHourBucket] = []
    public private(set) var outages: [PingOutage] = []
    /// Pertes consécutives en cours et date de la première d'entre elles.
    private var lossRun = 0
    private var lossRunStart: Date?
    private var lastRTT: Double?

    public init() {}

    public var isEmpty: Bool { buckets.isEmpty }
    public var firstDate: Date? { buckets.first?.hourStart }

    /// Ajoute une mesure ; `thresholdMs` : seuil de lenteur de la cible au moment de la mesure.
    public mutating func record(_ sample: PingSample, thresholdMs: Double, calendar: Calendar = .current) {
        let hour = calendar.dateInterval(of: .hour, for: sample.date)?.start ?? sample.date
        // Une mesure en retard d'une heure passée retrouve son heure ; sinon une heure neuve.
        var index = buckets.lastIndex { $0.hourStart == hour }
        if index == nil {
            buckets.append(PingHourBucket(hourStart: hour))
            buckets.sort { $0.hourStart < $1.hourStart }
            if buckets.count > Self.maxHours { buckets.removeFirst(buckets.count - Self.maxHours) }
            index = buckets.lastIndex { $0.hourStart == hour }
        }
        if let index {
            var bucket = buckets[index]
            var previous = lastRTT
            Self.update(&bucket, with: sample, thresholdMs: thresholdMs, lastRTT: &previous)
            buckets[index] = bucket
            lastRTT = previous
        }
        trackOutage(sample)
    }

    private static func update(_ bucket: inout PingHourBucket, with sample: PingSample, thresholdMs: Double, lastRTT: inout Double?) {
        bucket.sent += 1
        guard let rtt = sample.rttMs else { return }
        bucket.received += 1
        bucket.sum += rtt
        bucket.min = bucket.min.map { Swift.min($0, rtt) } ?? rtt
        bucket.max = bucket.max.map { Swift.max($0, rtt) } ?? rtt
        if rtt > thresholdMs { bucket.slow += 1 }
        if let previous = lastRTT {
            bucket.jitterSum += abs(rtt - previous)
            bucket.jitterCount += 1
        }
        lastRTT = rtt
    }

    private mutating func trackOutage(_ sample: PingSample) {
        if sample.isLost {
            if lossRun == 0 { lossRunStart = sample.date }
            lossRun += 1
            if lossRun == PingTargetStatus.offlineThreshold, let start = lossRunStart {
                outages.append(PingOutage(start: start, lostPackets: lossRun))
                if outages.count > Self.maxOutages { outages.removeFirst(outages.count - Self.maxOutages) }
            } else if lossRun > PingTargetStatus.offlineThreshold, var open = outages.last, open.end == nil {
                open.lostPackets = lossRun
                outages[outages.count - 1] = open
            }
        } else {
            if lossRun >= PingTargetStatus.offlineThreshold, var open = outages.last, open.end == nil {
                open.end = sample.date
                open.lostPackets = lossRun
                outages[outages.count - 1] = open
            }
            lossRun = 0
            lossRunStart = nil
        }
    }

    /// Oublie tout (réinitialisation des statistiques).
    public mutating func reset() {
        self = PingLongLog()
    }
}

// MARK: - Rapport

/// Rapport « pour le fournisseur Internet » : par cible, perte, latence et gigue par heure, et
/// périodes de panne, avec des constats en phrases simples.
public struct PingISPReport: Equatable, Sendable {
    public struct Input: Sendable {
        public var name: String
        public var address: String
        public var role: String
        public var thresholdMs: Double
        public var log: PingLongLog

        public init(name: String, address: String, role: String, thresholdMs: Double, log: PingLongLog) {
            self.name = name
            self.address = address
            self.role = role
            self.thresholdMs = thresholdMs
            self.log = log
        }
    }

    public struct HourRow: Equatable, Sendable {
        public var hourStart: Date
        public var sent: Int
        public var lossPercent: Double
        public var average: Double?
        public var max: Double?
        public var jitter: Double?
        public var slow: Int
    }

    public struct Target: Equatable, Sendable {
        public var name: String
        public var address: String
        public var role: String
        public var thresholdMs: Double
        public var sent: Int
        public var received: Int
        public var lossPercent: Double
        public var average: Double?
        public var min: Double?
        public var max: Double?
        public var jitter: Double?
        public var slow: Int
        public var hours: [HourRow]
        public var outages: [PingOutage]
        /// Somme des durées des pannes (bornées à la période du rapport).
        public var downtime: TimeInterval
        /// Disponibilité sur la période couverte par les mesures, en %.
        public var availability: Double
        /// Constats en phrases (« 3 pannes, 14 min au total »).
        public var findings: [String]
    }

    public var generatedAt: Date
    public var periodStart: Date
    public var periodEnd: Date
    public var targets: [Target]

    /// Seuils des constats : perte jugée anormale, gigue gênante pour la voix.
    public static let lossNotice = 1.0
    public static let jitterNotice = 30.0

    public static func make(_ inputs: [Input], generatedAt: Date, calendar: Calendar = .current) -> PingISPReport {
        let starts = inputs.compactMap { $0.log.firstDate }
        let periodStart = starts.min() ?? generatedAt
        let targets = inputs.filter { !$0.log.isEmpty }.map { summarize($0, now: generatedAt, calendar: calendar) }
        return PingISPReport(generatedAt: generatedAt, periodStart: periodStart, periodEnd: generatedAt, targets: targets)
    }

    static func summarize(_ input: Input, now: Date, calendar: Calendar) -> Target {
        let buckets = input.log.buckets
        let sent = buckets.reduce(0) { $0 + $1.sent }
        let received = buckets.reduce(0) { $0 + $1.received }
        let sum = buckets.reduce(0) { $0 + $1.sum }
        let jitterSum = buckets.reduce(0) { $0 + $1.jitterSum }
        let jitterCount = buckets.reduce(0) { $0 + $1.jitterCount }
        let slow = buckets.reduce(0) { $0 + $1.slow }
        let hours = buckets.map {
            HourRow(hourStart: $0.hourStart, sent: $0.sent, lossPercent: $0.lossPercent, average: $0.average, max: $0.max,
                    jitter: $0.jitter, slow: $0.slow)
        }
        let start = buckets.first?.hourStart ?? now
        let downtime = input.log.outages.reduce(0) { $0 + $1.duration(until: now) }
        let span = Swift.max(1, now.timeIntervalSince(start))
        let loss = sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100
        var target = Target(name: input.name, address: input.address, role: input.role, thresholdMs: input.thresholdMs,
                            sent: sent, received: received, lossPercent: loss,
                            average: received == 0 ? nil : sum / Double(received),
                            min: buckets.compactMap(\.min).min(), max: buckets.compactMap(\.max).max(),
                            jitter: jitterCount == 0 ? nil : jitterSum / Double(jitterCount), slow: slow,
                            hours: hours, outages: input.log.outages, downtime: downtime,
                            availability: Swift.max(0, Swift.min(100, (1 - downtime / span) * 100)), findings: [])
        target.findings = findings(for: target, now: now, calendar: calendar)
        return target
    }

    /// Constats simples, du plus grave au moins grave.
    static func findings(for target: Target, now: Date, calendar: Calendar) -> [String] {
        var list: [String] = []
        let outages = target.outages.count
        if outages > 0 {
            let longest = target.outages.map { $0.duration(until: now) }.max() ?? 0
            list.append("\(outages) \(outages > 1 ? "pannes" : "panne") (3 paquets perdus de suite ou plus), \(PingFormat.duration(target.downtime)) au total, la plus longue de \(PingFormat.duration(longest)).")
        }
        if target.lossPercent >= lossNotice {
            list.append("Perte moyenne de \(PingFormat.percent(target.lossPercent)), au-delà du seuil habituel de 1\u{00A0}%.")
        }
        if let worst = target.hours.filter({ $0.sent > 0 }).max(by: { $0.lossPercent < $1.lossPercent }), worst.lossPercent >= lossNotice {
            list.append("Heure la plus touchée\u{00A0}: \(hourLabel(worst.hourStart, calendar: calendar)), \(PingFormat.percent(worst.lossPercent)) de perte.")
        }
        if let jitter = target.jitter, jitter >= jitterNotice {
            list.append("Gigue moyenne de \(PingFormat.ms(jitter))\u{00A0}: gênante pour la voix et la vidéo (au-delà de 30\u{00A0}ms).")
        }
        if let peak = target.hours.filter({ $0.average != nil }).max(by: { ($0.average ?? 0) < ($1.average ?? 0) }),
           let average = target.average, let peakAverage = peak.average, peakAverage > average * 1.5, peakAverage > target.thresholdMs {
            list.append("Latence la plus haute\u{00A0}: \(PingFormat.ms(peakAverage)) en moyenne à \(hourLabel(peak.hourStart, calendar: calendar)) (moyenne générale \(PingFormat.ms(average))).")
        }
        if target.received > 0, target.slow > 0 {
            let share = Double(target.slow) / Double(target.received) * 100
            if share >= 5 {
                list.append("\(PingFormat.percent(share)) des réponses au-dessus du seuil de \(PingThreshold.label(target.thresholdMs)).")
            }
        }
        if list.isEmpty { list.append("Aucune anomalie\u{00A0}: perte et latence normales sur la période.") }
        return list
    }

    /// « 2026-11-05 19 h ».
    public static func hourLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02d %d\u{00A0}h", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0)
    }

    /// « 2026-11-05 19:42:07 ».
    public static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
    }

    // MARK: Pages du PDF

    /// Page du PDF : résumé de quelques cibles, ou détail horaire d'une cible.
    public enum Page: Equatable, Sendable {
        case summary(targets: Range<Int>)
        case hours(target: Int, rows: Range<Int>)
    }

    /// Découpage en pages : `targetsPerSummary` cibles par page de résumé, puis le détail horaire
    /// de chaque cible, `rowsPerPage` heures par page. Au moins une page (rapport vide).
    public func pages(targetsPerSummary: Int = 2, rowsPerPage: Int = 30) -> [Page] {
        let perSummary = Swift.max(1, targetsPerSummary)
        let perPage = Swift.max(1, rowsPerPage)
        var pages: [Page] = []
        var start = 0
        repeat {
            let end = Swift.min(targets.count, start + perSummary)
            pages.append(.summary(targets: start..<end))
            start = end
        } while start < targets.count
        for (index, target) in targets.enumerated() {
            var row = 0
            while row < target.hours.count {
                let end = Swift.min(target.hours.count, row + perPage)
                pages.append(.hours(target: index, rows: row..<end))
                row = end
            }
        }
        return pages
    }

    /// Pannes montrées dans le résumé d'une cible (les plus récentes d'abord) et le nombre de cachées.
    public static func listedOutages(_ target: Target, limit: Int = 6) -> (shown: [PingOutage], hidden: Int) {
        let sorted = target.outages.sorted { $0.start > $1.start }
        return (Array(sorted.prefix(limit)), Swift.max(0, sorted.count - limit))
    }

    /// Version texte (presse-papiers, courriel au fournisseur, tests).
    public func text(calendar: Calendar = .current) -> String {
        var lines = ["Rapport de connectivité pour le fournisseur Internet",
                     "Période\u{00A0}: \(Self.stamp(periodStart, calendar: calendar)) au \(Self.stamp(periodEnd, calendar: calendar))", ""]
        for target in targets {
            lines.append("\(target.name) · \(target.address)" + (target.role.isEmpty ? "" : " · \(target.role)"))
            lines.append("  Envoyés \(target.sent), reçus \(target.received), perte \(PingFormat.percent(target.lossPercent)), latence moyenne \(PingFormat.ms(target.average)), gigue \(PingFormat.ms(target.jitter)), disponibilité \(PingFormat.decimal(target.availability, digits: 2))\u{00A0}%")
            for finding in target.findings { lines.append("  - \(finding)") }
            for outage in target.outages {
                let end = outage.end.map { Self.stamp($0, calendar: calendar) } ?? "en cours"
                lines.append("  Panne\u{00A0}: \(Self.stamp(outage.start, calendar: calendar)) → \(end) (\(PingFormat.duration(outage.duration(until: periodEnd))), \(outage.lostPackets) paquets perdus)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
