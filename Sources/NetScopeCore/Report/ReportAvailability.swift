import Foundation

// Section facultative « Disponibilité (Surveillance) » des rapports (notes 62 et 78) : disponibilité
// de chaque sonde du site sur 30 jours (historique par jour de la Surveillance), graphe d'une case
// par jour, pannes, durée hors ligne estimée et latence moyenne. Les vérifications faites pendant
// une fenêtre de maintenance ne comptent pas. Rien n'est mesuré ici : tout vient de l'historique.

/// Disponibilité d'une sonde sur la période du rapport.
public struct ReportAvailabilityProbe: Hashable, Sendable {
    public var name: String
    public var kind: String
    public var target: String
    /// Disponibilité de chaque jour, du plus ancien au plus récent (nil : aucune vérification).
    public var days: [Double?]
    public var checks: Int
    public var failures: Int
    public var maintenanceChecks: Int
    /// Durée hors ligne estimée (vérifications en panne × intervalle), en secondes.
    public var downSeconds: Double
    /// Alertes critiques (pannes) créées pendant la période.
    public var incidents: Int
    public var latencyAverage: Double?

    public init(name: String, kind: String, target: String, days: [Double?], checks: Int, failures: Int,
                maintenanceChecks: Int = 0, downSeconds: Double = 0, incidents: Int = 0, latencyAverage: Double? = nil) {
        self.name = name
        self.kind = kind
        self.target = target
        self.days = days
        self.checks = checks
        self.failures = failures
        self.maintenanceChecks = maintenanceChecks
        self.downSeconds = downSeconds
        self.incidents = incidents
        self.latencyAverage = latencyAverage
    }

    /// Disponibilité sur la période (vérifications réussies / vérifications), ou nil.
    public var percent: Double? { checks > 0 ? Double(checks - failures) / Double(checks) * 100 : nil }
}

/// Disponibilité des sondes d'un site sur la période du rapport.
public struct ReportAvailability: Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var probes: [ReportAvailabilityProbe]
    /// Heures ouvrables du site (« lun.–ven. 7 h – 18 h »).
    public var hoursSummary: String?
    /// Fenêtres de maintenance qui ont touché le site (« Mises à jour FortiOS : chaque dimanche à 2 h 00, 3 h »).
    public var maintenance: [String]

    public init(start: Date, end: Date, probes: [ReportAvailabilityProbe], hoursSummary: String? = nil, maintenance: [String] = []) {
        self.start = start
        self.end = end
        self.probes = probes
        self.hoursSummary = hoursSummary
        self.maintenance = maintenance
    }

    public static let defaultDays = 30

    /// Disponibilité des sondes données, d'après l'historique par jour de la Surveillance.
    public static func make(probes: [MonProbe], history: MonHistory, journal: MonJournal, days: Int = defaultDays,
                            now: Date, planning: MonPlanning? = nil, site: UUID? = nil,
                            calendar: Calendar = .current) -> ReportAvailability {
        let count = max(1, days)
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: end) ?? end
        let items = probes.map { probe -> ReportAvailabilityProbe in
            let buckets = history.dayBuckets(probe: probe.id, from: start, to: now, calendar: calendar)
            let latencyCount = buckets.reduce(0) { $0 + $1.latencyCount }
            let latencySum = buckets.reduce(0) { $0 + $1.latencySum }
            let incidents = journal.alerts.filter {
                $0.probeID == probe.id && $0.severity == .critical && $0.date >= start && $0.date <= now
                    && !$0.message.hasPrefix("Test manuel")
            }.count
            return ReportAvailabilityProbe(
                name: probe.name, kind: probe.kind.shortLabel, target: probe.target,
                days: history.dailyAvailability(probe: probe.id, days: count, end: now, calendar: calendar).map(\.percent),
                checks: buckets.reduce(0) { $0 + $1.total }, failures: buckets.reduce(0) { $0 + $1.failures },
                maintenanceChecks: buckets.reduce(0) { $0 + $1.maintenance },
                downSeconds: buckets.reduce(0) { $0 + $1.downSeconds }, incidents: incidents,
                latencyAverage: latencyCount > 0 ? latencySum / Double(latencyCount) : nil)
        }
        let windows = (planning?.windows ?? []).filter { window in
            guard window.siteID == nil || window.siteID == site else { return false }
            // Fenêtre qui a eu au moins une occurrence dans la période, ou qui vise une sonde du rapport.
            let ids = Set(probes.map(\.id))
            if !window.probeIDs.isEmpty && ids.isDisjoint(with: window.probeIDs) { return false }
            return window.start <= now && (window.until.map { $0 >= start } ?? true)
        }
        return ReportAvailability(start: start, end: end, probes: items,
                                  hoursSummary: planning.map { $0.hours(for: site).summary },
                                  maintenance: windows.map { "\($0.name)\u{00A0}: " + $0.rhythmLabel(calendar: calendar).lowercasedFirst })
    }
}

public extension String {
    /// « Chaque jour… » → « chaque jour… ».
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

extension ReportBuilder {
    /// Lignes par graphe : un graphe tient toujours sur une page.
    static let uptimeRowsPerChart = 14

    public static func availabilityBlocks(_ availability: ReportAvailability?, calendar: Calendar = .current) -> [ReportBlock] {
        guard let availability, !availability.probes.isEmpty else {
            return [.note("Aucune sonde de la Surveillance pour ce site\u{00A0}: ajouter des sondes (ping de la passerelle, des switchs, des serveurs) dans l’écran Surveillance\u{00A0}; leur disponibilité s’accumule jour après jour, sur 90 jours.")]
        }
        let days = availability.probes.map(\.days.count).max() ?? 0
        let period = "du \(dayLabel(availability.start, calendar: calendar)) au \(dayLabel(availability.end, calendar: calendar, year: true))"
        var text = "Disponibilité des \(plural(availability.probes.count, "sonde", "sondes")) de la Surveillance \(period) (\(days)\u{00A0}jours), "
        text += "mesurée par NetScope depuis ce Mac\u{00A0}: vérifications réussies sur vérifications faites, hors fenêtres de maintenance."
        var blocks: [ReportBlock] = [.paragraph(text)]

        let checks = availability.probes.reduce(0) { $0 + $1.checks }
        let failures = availability.probes.reduce(0) { $0 + $1.failures }
        let overall = checks > 0 ? Double(checks - failures) / Double(checks) * 100 : nil
        let incidents = availability.probes.reduce(0) { $0 + $1.incidents }
        let down = availability.probes.reduce(0) { $0 + $1.downSeconds }
        let below = availability.probes.filter { ($0.percent ?? 100) < 99 }.count
        blocks.append(.kpis([
            ReportKPI(overall.map(percentLabel) ?? "—", "disponibilité moyenne", tone: ReportUptimeRow.tone(overall) == .critical ? .critical : .normal),
            ReportKPI("\(incidents)", incidents > 1 ? "pannes déclarées" : "panne déclarée", tone: incidents > 0 ? .warning : .normal),
            ReportKPI(durationLabel(down), "hors ligne (cumul estimé)", tone: down > 0 ? .warning : .normal),
            ReportKPI("\(below)", below > 1 ? "sondes sous 99 %" : "sonde sous 99 %", tone: below > 0 ? .critical : .normal),
        ]))

        // Graphes : une case par jour, au plus 14 sondes par graphe.
        let axis = axisLabels(start: availability.start, days: days, calendar: calendar)
        let rows = availability.probes.map { probe in
            ReportUptimeRow(label: probe.name, values: probe.days, total: probe.percent.map(percentLabel) ?? "—",
                            tone: probe.percent.map { ReportUptimeRow.tone($0) == .success ? .normal : ReportUptimeRow.tone($0) } ?? .muted)
        }
        let chunks = stride(from: 0, to: rows.count, by: uptimeRowsPerChart).map { Array(rows[$0..<min(rows.count, $0 + uptimeRowsPerChart)]) }
        for (index, chunk) in chunks.enumerated() {
            let title = chunks.count > 1 ? "Disponibilité par jour (\(index + 1)/\(chunks.count))" : "Disponibilité par jour"
            blocks.append(.uptime(ReportUptimeChart(title: title, axis: axis, rows: chunk)))
        }

        let tableRows = availability.probes.map { probe -> ReportRow in
            let tone = ReportUptimeRow.tone(probe.percent)
            return ReportRow([
                ReportCell(probe.name, bold: true),
                ReportCell(probe.target),
                ReportCell(probe.percent.map(percentLabel) ?? "aucune donnée", badge: probe.percent == nil ? nil : tone,
                           tone: probe.percent == nil ? .muted : .normal),
                ReportCell("\(probe.incidents)", tone: probe.incidents > 0 ? .warning : .normal),
                ReportCell(probe.downSeconds > 0 ? durationLabel(probe.downSeconds) : "—"),
                ReportCell(probe.latencyAverage.map { ToolFormat.milliseconds($0) } ?? "—"),
            ])
        }
        blocks.append(.table(ReportTable(columns: [
            ReportColumn("Sonde", weight: 2.4), ReportColumn("Cible", weight: 1.8, mono: true, size: 9.9, shrinks: true),
            ReportColumn("Disponibilité", weight: 1.1, trailing: true), ReportColumn("Pannes", weight: 0.7, trailing: true),
            ReportColumn("Hors ligne", weight: 0.9, trailing: true), ReportColumn("Latence", weight: 0.9, trailing: true),
        ], rows: tableRows)))

        var note = "Vert à 99,9\u{00A0}% et plus, jaune à 99\u{00A0}%, orange à 95\u{00A0}%, rouge en dessous, gris sans vérification (NetScope fermé ou sonde ajoutée depuis). "
        note += "La durée hors ligne est estimée d’après l’intervalle de chaque sonde."
        if let hours = availability.hoursSummary { note += " Heures ouvrables du site\u{00A0}: \(hours)." }
        let maintenanceChecks = availability.probes.reduce(0) { $0 + $1.maintenanceChecks }
        if !availability.maintenance.isEmpty {
            note += " Fenêtres de maintenance (alertes suspendues, hors disponibilité)\u{00A0}: " + availability.maintenance.joined(separator: "\u{00A0}; ")
            note += maintenanceChecks > 0 ? " (\(maintenanceChecks) vérifications écartées)." : "."
        }
        blocks.append(.note(note))
        return blocks
    }

    /// « 99,95 % », « 100 % ».
    static func percentLabel(_ value: Double) -> String {
        if value >= 100 { return "100\u{00A0}%" }
        // Jamais « 100 % » arrondi quand une vérification a échoué.
        if value >= 99.99 { return "99,99\u{00A0}%" }
        let digits = value >= 99 ? 2 : 1
        return ToolFormat.decimal(value, digits: digits) + "\u{00A0}%"
    }

    /// « 0 min », « 42 min », « 3 h 12 », « 2 j 4 h ».
    static func durationLabel(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)\u{00A0}min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)\u{00A0}h\u{00A0}" + String(format: "%02d", minutes % 60) }
        return "\(hours / 24)\u{00A0}j\u{00A0}\(hours % 24)\u{00A0}h"
    }

    static func dayLabel(_ date: Date, calendar: Calendar, year: Bool = false) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        let months = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juill.", "août", "sept.", "oct.", "nov.", "déc."]
        let day = p.day == 1 ? "1er" : "\(p.day ?? 1)"
        return "\(day) \(months[max(1, min(12, p.month ?? 1)) - 1])" + (year ? " \(p.year ?? 0)" : "")
    }

    static func axisLabels(start: Date, days: Int, calendar: Calendar) -> [String] {
        guard days > 1 else { return [dayLabel(start, calendar: calendar)] }
        let middle = calendar.date(byAdding: .day, value: (days - 1) / 2, to: start) ?? start
        let last = calendar.date(byAdding: .day, value: days - 1, to: start) ?? start
        return [dayLabel(start, calendar: calendar), dayLabel(middle, calendar: calendar), dayLabel(last, calendar: calendar)]
    }
}
