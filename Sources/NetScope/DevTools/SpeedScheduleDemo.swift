import Foundation
import NetScopeCore

/// Note 78 : débit Internet planifié en démonstration (`--demo`) : réglages des sites fictifs et
/// 30 jours de tests planifiés inventés. Aucun test réel n'est lancé.
@MainActor
enum SpeedScheduleDemo {
    /// Réglages : Siège et Laval avec seuils, Québec sans seuil, Drummondville et la Clinique
    /// sans planification.
    static func book(now: Date = Date()) -> SpeedScheduleBook {
        func run(_ time: DayMinute) -> Date { latestRun(time, now: now) }
        let armed = now.addingTimeInterval(-45 * 86_400)
        return SpeedScheduleBook(schedules: [
            SpeedSchedule(siteID: SitesDemo.siegeID, isEnabled: true, time: DayMinute(hour: 7), minDownMbps: 500,
                          minUpMbps: 250, armedAt: armed, lastRun: run(DayMinute(hour: 7)),
                          lastStatus: .ok(downMbps: 908, upMbps: 486)),
            SpeedSchedule(siteID: SitesDemo.lavalID, isEnabled: true, time: DayMinute(hour: 6, minute: 30), minDownMbps: 300,
                          minUpMbps: 100, armedAt: armed, lastRun: run(DayMinute(hour: 6, minute: 30)),
                          lastStatus: .below(downMbps: 236, upMbps: 94)),
            SpeedSchedule(siteID: SitesDemo.quebecID, isEnabled: true, time: DayMinute(hour: 7, minute: 15),
                          armedAt: now.addingTimeInterval(-12 * 86_400), lastRun: run(DayMinute(hour: 7, minute: 15)),
                          lastStatus: .ok(downMbps: 478, upMbps: 96)),
            SpeedSchedule(siteID: SitesDemo.drummondID, isEnabled: false, time: DayMinute(hour: 22), minDownMbps: 150),
        ])
    }

    /// Dernier test planifié à l'heure donnée : aujourd'hui, ou hier si l'heure n'est pas passée.
    static func latestRun(_ time: DayMinute, now: Date, calendar: Calendar = .current) -> Date {
        let today = SpeedSchedulePlanner.slot(on: now, time: time, calendar: calendar).addingTimeInterval(95)
        if today <= now { return today }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
    }

    /// Un test planifié par jour et par site sur 30 jours (le plus récent : aujourd'hui, ou hier
    /// si l'heure n'est pas encore passée).
    static func records(now: Date = Date()) -> [SpeedTestRecord] {
        let calendar = Calendar.current
        var records: [SpeedTestRecord] = []
        func add(site: UUID, name: String, time: DayMinute, days: Int, interface: (String, String),
                 server: (String, SpeedServerSource, String), value: (Int) -> (down: Double, up: Double, latency: Double)) {
            let latest = latestRun(time, now: now)
            for back in 0..<days {
                guard let date = calendar.date(byAdding: .day, value: -back, to: latest) else { continue }
                let measure = value(back)
                records.append(SpeedTestRecord(
                    date: date, kind: .internet, origin: SpeedTestRecord.plannedOrigin, server: server.0,
                    interfaceName: interface.0, interfaceKind: interface.1, downMbps: measure.down, upMbps: measure.up,
                    latencyMs: measure.latency, loadedLatencyMs: measure.latency * 2.6, jitterMs: 1.2, streams: 8,
                    serverSource: server.1, serverID: server.2, siteID: site, siteName: name))
            }
        }
        // Siège : fibre 1 Gb/s stable, un creux le 9e jour (maintenance du fournisseur).
        add(site: SitesDemo.siegeID, name: "Siège", time: DayMinute(hour: 7), days: 30, interface: ("en7", "Ethernet"),
            server: ("Cloudflare · YUL · Montréal", .cloudflare, "cloudflare:YUL")) { back in
            let wobble = sin(Double(back) * 1.7)
            if back == 9 { return (612, 402, 11) }
            return (back == 0 ? 908 : 896 + 14 * wobble, back == 0 ? 486 : 482 + 6 * wobble, 6 + abs(wobble) * 1.5)
        }
        // Entrepôt Laval : lien 400/120 qui se dégrade les derniers jours (sous le seuil de 300/100).
        add(site: SitesDemo.lavalID, name: "Entrepôt Laval", time: DayMinute(hour: 6, minute: 30), days: 30,
            interface: ("en0", "Ethernet"), server: ("M-Lab · Montréal (yul04)", .mlab, "mlab:yul04")) { back in
            let wobble = sin(Double(back) * 2.3)
            switch back {
            case 0: return (236, 94, 21)
            case 1: return (262, 97, 19)
            case 2: return (318, 104, 14)
            case 4: return (284, 99, 17)
            default: return (372 + 18 * wobble, 116 + 3 * wobble, 9 + abs(wobble) * 2)
            }
        }
        // Bureau Québec : planifié depuis 12 jours, pas de seuil.
        add(site: SitesDemo.quebecID, name: "Bureau Québec", time: DayMinute(hour: 7, minute: 15), days: 12,
            interface: ("en7", "Ethernet"), server: ("LibreSpeed · Québec · Réseau Capitale", .librespeed, "librespeed:7")) { back in
            let wobble = sin(Double(back) * 1.1)
            return (back == 0 ? 478 : 472 + 9 * wobble, back == 0 ? 96 : 95 + 2 * wobble, 9 + abs(wobble))
        }
        return records
    }
}
