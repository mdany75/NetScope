import Foundation
import NetScopeCore

/// Note 78 : données de démonstration de la planification de la Surveillance (heures ouvrables du
/// Siège et de l'entrepôt de Laval, fenêtres de maintenance, rappel après 30 min) et de l'historique
/// long (latence sur 24 h et 7 jours, disponibilité par jour sur 30 jours, pour le graphe de latence
/// et la section « Disponibilité » des rapports). Valeurs tirées d'un générateur déterministe :
/// les captures sont stables. Rien ne s'exécute, rien n'est enregistré.
///
/// Captures : NETSCOPE_SURV_PLANIF=heures ouvre l'éditeur des heures du Siège, =fenetre celui de
/// la fenêtre « Mises à jour FortiOS » ; NETSCOPE_SURV_LATENCE=7j affiche le graphe sur 7 jours.
@MainActor
enum MonPlanningDemo {
    private static let s = "\u{00A0}"

    /// Latence habituelle (ms) des sondes qui en mesurent une ; nil : pas de latence.
    private static func baseLatency(_ probe: MonProbe) -> Double? {
        switch probe.name {
        case "Ping passerelle": return 1.1
        case "Caméra-Quai": return 3.4
        case "Interface imprimante": return 184
        case "TCP 443 FortiGate": return 2.1
        case "Résolution intranet.local": return 4
        case "Certificat TLS": return 38
        case "Ping SW-ETG2-01": return 1.6
        case "Ping FortiAP-231F": return 2.3
        case "Microsoft 365": return 96
        default: return nil
        }
    }

    /// Disponibilité de démonstration de quelques sondes, par jour (index depuis aujourd'hui).
    private static func dayAvailability(_ name: String, daysAgo: Int) -> Double {
        switch (name, daysAgo) {
        case ("Caméra-Quai", 0): return 91.4
        case ("Caméra-Quai", 6): return 98.6
        case ("Caméra-Quai", 13): return 99.2
        case ("Caméra-Quai", 21): return 94.8
        case ("Tunnels VPN du Siège", 0): return 92.5
        case ("Tunnels VPN du Siège", 9): return 99.4
        case ("FortiAP du Siège", 0): return 96.2
        case ("Liens WAN du Siège", 3): return 99.6
        case ("Microsoft 365", 11): return 99.7
        case ("Interface imprimante", 17): return 97.9
        case ("Ping passerelle", 24): return 99.93
        default: return 100
        }
    }

    static func apply(to store: MonStore, probes: [MonProbe], history base: MonHistory, now: Date) {
        let calendar = Calendar.current
        var history = base
        var random = DemoRandom(seed: 78)
        let today = calendar.startOfDay(for: now)
        let currentHour = MonHistory.hourStart(now, calendar: calendar)
        let switchProbe = probes.first { $0.name == "Ping SW-ETG2-01" }
        let maintenanceStart = calendar.date(byAdding: .hour, value: 14, to: today) ?? now

        for probe in probes {
            let key = probe.id.uuidString
            let latency = baseLatency(probe)
            let isSwitch = probe.id == switchProbe?.id
            // Heures des 24 dernières heures (barre) : on garde leur couleur et on ajoute la latence.
            var hours: [Date: MonHourBucket] = [:]
            for bucket in history.buckets[key] ?? [] { hours[bucket.hour] = bucket }
            var hourly: [MonHourBucket] = []
            for offset in stride(from: MonHistory.hourlyRetention - 1, through: 0, by: -1) {
                guard let hour = calendar.date(byAdding: .hour, value: -offset, to: currentHour) else { continue }
                var bucket = hours[hour] ?? MonHourBucket(hour: hour, total: max(1, 3_600 / probe.interval))
                if bucket.total <= 1 { bucket.total = max(1, 3_600 / probe.interval) }
                if bucket.failures > 0 { bucket.failures = bucket.total }
                if bucket.downs > 0 { bucket.downs = bucket.total }
                if isSwitch, hour >= maintenanceStart {
                    bucket.maintenance = bucket.total
                    bucket.total = 0
                }
                if let latency, bucket.failures < bucket.total || bucket.total == 0 {
                    let hourOfDay = calendar.component(.hour, from: hour)
                    let busy = (8...17).contains(hourOfDay) ? 1.35 : 1
                    let factor = bucket.warnings > 0 ? 2.6 : 1
                    let average = latency * busy * factor * random.between(0.85, 1.2)
                    let count = max(1, bucket.total + (bucket.maintenance ?? 0))
                    bucket.latencySum = average * Double(count)
                    bucket.latencyCount = count
                    bucket.latencyMin = average * random.between(0.55, 0.8)
                    bucket.latencyMax = average * random.between(1.4, 2.6)
                }
                hourly.append(bucket)
            }
            history.buckets[key] = hourly

            // Tranches de 10 minutes des 24 dernières heures (graphe de latence).
            var fine: [MonFineBucket] = []
            let lastSlot = MonHistory.fineStart(now)
            for index in 0..<MonLatencyRange.day.count {
                let start = lastSlot.addingTimeInterval(-Double(MonLatencyRange.day.count - 1 - index) * MonFineBucket.span)
                let hour = hourly.first { $0.hour == MonHistory.hourStart(start, calendar: calendar) }
                let checks = max(1, 600 / probe.interval)
                var piece = MonFineBucket(start: start, total: checks)
                let down = (hour?.downs ?? 0) > 0
                // Caméra-Quai : hors ligne depuis 2 h 04 (12 h 28), comme son état.
                let cameraDown = probe.name == "Caméra-Quai" && start >= now.addingTimeInterval(-(2 * 3_600 + 4 * 60 + 600))
                if down || cameraDown {
                    piece.failures = checks
                } else if let latency {
                    let hourOfDay = calendar.component(.hour, from: start)
                    let busy = (8...17).contains(hourOfDay) ? 1.35 : 1
                    let spike = (hour?.warnings ?? 0) > 0 ? random.between(2, 3.4) : (random.chance(0.04) ? random.between(2, 4) : 1)
                    let average = latency * busy * spike * random.between(0.82, 1.18)
                    piece.latencySum = average * Double(checks)
                    piece.latencyCount = checks
                    piece.latencyMin = average * random.between(0.6, 0.85)
                    piece.latencyMax = average * random.between(1.2, 1.9)
                }
                if isSwitch, start >= maintenanceStart {
                    piece.maintenance = checks
                    // Pendant le remplacement : coupure de 20 minutes, puis le nouveau switch répond.
                    if start < maintenanceStart.addingTimeInterval(1_200) {
                        piece.failures = checks
                        piece.latencyCount = 0
                        piece.latencySum = 0
                        piece.latencyMin = nil
                        piece.latencyMax = nil
                    }
                }
                fine.append(piece)
            }
            history.fine[key] = fine

            // Jours des 30 derniers jours (rapport de disponibilité).
            var days: [MonDayBucket] = []
            for daysAgo in stride(from: 29, through: 0, by: -1) {
                guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
                let elapsed = daysAgo == 0 ? now.timeIntervalSince(today) : 86_400
                let total = max(1, Int(elapsed) / probe.interval)
                let percent = dayAvailability(probe.name, daysAgo: daysAgo)
                let failures = Int((Double(total) * (100 - percent) / 100).rounded())
                var bucket = MonDayBucket(day: day, total: total, failures: failures, downs: failures,
                                          downSeconds: Double(failures * probe.interval))
                if let latency {
                    bucket.latencyCount = total - failures
                    bucket.latencySum = latency * 1.15 * random.between(0.9, 1.1) * Double(total - failures)
                }
                // Mises à jour FortiOS du dimanche : 3 h écartées de la disponibilité.
                if calendar.component(.weekday, from: day) == 1 {
                    bucket.maintenance = 10_800 / probe.interval
                    bucket.total = max(1, bucket.total - bucket.maintenance)
                }
                days.append(bucket)
            }
            history.days[key] = days
        }

        store.loadDemoPlanning(planning(probes: probes, now: now, calendar: calendar), history: history)
    }

    /// Heures ouvrables, fenêtres de maintenance et rappel de la démonstration.
    static func planning(probes: [MonProbe], now: Date, calendar: Calendar) -> MonPlanning {
        let today = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: today) ?? today
        }
        // Siège : lun.–ven. 7 h – 18 h, sam. 8 h – 12 h. Entrepôt Laval : lun.–sam. 6 h – 22 h.
        var siege = MonBusinessHours.standard
        siege.days[6] = MonDayHours(isOpen: true, start: 8 * 60, end: 12 * 60)
        let laval = MonBusinessHours(days: (0..<7).map { $0 == 0 ? .closed : MonDayHours(isOpen: true, start: 6 * 60, end: 22 * 60) })
        // Dimanche dernier à 2 h : première occurrence des mises à jour hebdomadaires.
        let weekday = calendar.component(.weekday, from: today)
        let lastSunday = at(-((weekday - 1 + 7) % 7) - 7, 2)
        let switchID = probes.first { $0.name == "Ping SW-ETG2-01" }?.id
        let windows = [
            MonMaintenanceWindow(name: "Remplacement de SW-ETG2-01", start: at(0, 14), durationMinutes: 180,
                                 siteID: SitesDemo.siegeID, probeIDs: switchID.map { [$0] } ?? [],
                                 note: "Nouveau switch Aruba 6100, recâblage de l’étage 2."),
            MonMaintenanceWindow(name: "Mises à jour FortiOS", start: lastSunday, durationMinutes: 180, repeats: .weekly,
                                 siteID: SitesDemo.siegeID, note: "FortiGate, FortiSwitch et FortiAP, redémarrages prévus."),
            MonMaintenanceWindow(name: "Sauvegarde du NAS", start: at(-20, 1), durationMinutes: 60, repeats: .daily,
                                 siteID: SitesDemo.lavalID),
            MonMaintenanceWindow(name: "Inventaire de fin de mois", start: at(-36, 18), durationMinutes: 240, repeats: .monthly,
                                 siteID: SitesDemo.lavalID, note: "Lecteurs de codes-barres débranchés."),
        ]
        return MonPlanning(defaultHours: .standard,
                           siteHours: [SitesDemo.siegeID.uuidString: siege, SitesDemo.lavalID.uuidString: laval],
                           windows: windows, reminderMinutes: 30, reminderLimit: 3)
    }

    /// Note du journal : l'alerte du switch remplacé, suspendue par la maintenance.
    static func maintenanceNote(probes: [MonProbe], now: Date) -> MonAlert? {
        guard let probe = probes.first(where: { $0.name == "Ping SW-ETG2-01" }) else { return nil }
        let today = Calendar.current.startOfDay(for: now)
        let date = Calendar.current.date(byAdding: DateComponents(hour: 14, minute: 6, second: 12), to: today) ?? now
        guard date <= now else { return nil }
        return MonAlert(date: date, probeID: probe.id, probeName: probe.name, severity: .info,
                        message: "Maintenance «\(s)Remplacement de SW-ETG2-01\(s)» en cours, alerte suspendue\(s): 10.182.122.3 ne répond plus depuis 3 tentatives (aucune réponse ICMP).",
                        acknowledgedAt: date)
    }

    /// Sélections des captures.
    static var editorMode: String? {
        CommandLine.arguments.contains("--snapshot") ? ProcessInfo.processInfo.environment["NETSCOPE_SURV_PLANIF"] : nil
    }

    static var latencyRange: MonLatencyRange {
        CommandLine.arguments.contains("--snapshot") && ProcessInfo.processInfo.environment["NETSCOPE_SURV_LATENCE"] == "7j" ? .week : .day
    }
}

/// Générateur pseudo-aléatoire déterministe (captures stables).
struct DemoRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func between(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
    mutating func chance(_ probability: Double) -> Bool { next() < probability }
}
