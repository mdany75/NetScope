import Foundation
import NetScopeCore

/// Notes 63 et 64 en démonstration (`--demo`, captures) : scans planifiés des sites fictifs, journal
/// de leurs exécutions (app et agent) et agent actif. Rien ne s'exécute ni ne s'écrit.
/// Captures : NETSCOPE_REGLAGES_SECTION=surveillance ; NETSCOPE_SCAN_PLANIF=edition ouvre l'éditeur.
@MainActor
enum AutomationDemo {
    /// Heure de la démonstration : aujourd'hui, 14 h 12 min 30 s (comme les Journaux).
    static var now: Date {
        Calendar.current.date(bySettingHour: 14, minute: 12, second: 30, of: Date()) ?? Date()
    }

    private static func at(_ daysAgo: Int, _ hour: Int, _ minute: Int, plus seconds: TimeInterval = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return (calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day).addingTimeInterval(seconds)
    }

    static var book: ScanScheduleBook {
        let siege = SitesDemo.siegeKey
        let laval = SitesDemo.lavalKey
        let quebec = SiteFiles.key(for: SitesDemo.quebecID)
        let clinique = SiteFiles.key(for: SitesDemo.cliniqueID)
        let armed = now.addingTimeInterval(-30 * 86_400)
        let schedules = [
            ScanSchedule(id: UUID(uuidString: "5CA40063-0001-4000-8000-000000000001")!, siteKey: siege, weekdays: [1, 2, 3, 4, 5, 6, 7],
                         hour: 2, minute: 0, profile: .complet, activeSince: armed, lastSlot: at(0, 2, 0), lastRun: at(0, 2, 0, plus: 184),
                         lastOutcome: .ok, lastMessage: "47 en ligne, 2 nouveaux, 3\u{00A0}min\u{00A0}4\u{00A0}s."),
            ScanSchedule(id: UUID(uuidString: "5CA40063-0002-4000-8000-000000000002")!, siteKey: laval, weekdays: [2, 3, 4, 5, 6],
                         hour: 6, minute: 30, profile: .rapide, activeSince: armed, lastSlot: at(0, 6, 30), lastRun: at(0, 6, 30, plus: 41),
                         lastOutcome: .ok, lastMessage: "Rattrapé après la veille. 18 en ligne, 0 nouveau, 41\u{00A0}s."),
            ScanSchedule(id: UUID(uuidString: "5CA40063-0003-4000-8000-000000000003")!, siteKey: quebec, weekdays: [2, 4, 6],
                         hour: 22, minute: 15, profile: .portsCourants, activeSince: armed, lastSlot: at(2, 22, 15), lastRun: at(1, 6, 0),
                         lastOutcome: .missed, lastMessage: "Échéance manquée (Mac éteint ou en veille)."),
            ScanSchedule(id: UUID(uuidString: "5CA40063-0004-4000-8000-000000000004")!, siteKey: clinique, isEnabled: false,
                         weekdays: [1, 7], hour: 12, minute: 0, profile: .rapide, activeSince: armed),
        ]
        let names = [siege: "Siège", laval: "Entrepôt Laval", quebec: "Bureau Québec"]
        func entry(_ schedule: Int, _ date: Date, _ host: ScanRunHost, _ outcome: ScanRunOutcome, _ online: Int, _ new: Int,
                   _ duration: TimeInterval, _ message: String) -> ScanRunEntry {
            let item = schedules[schedule]
            return ScanRunEntry(date: date, slot: date.addingTimeInterval(-duration), scheduleID: item.id, siteKey: item.siteKey,
                                siteName: names[item.siteKey] ?? "Site", host: host, outcome: outcome, online: online, newCount: new,
                                duration: duration, message: message)
        }
        let runs = [
            entry(1, at(0, 6, 30, plus: 41), .app, .ok, 18, 0, 41, "Rattrapé après la veille. 18 en ligne, 0 nouveau, 41\u{00A0}s."),
            entry(0, at(0, 2, 0, plus: 184), .agent, .ok, 47, 2, 184, "47 en ligne, 2 nouveaux, 3\u{00A0}min\u{00A0}4\u{00A0}s."),
            entry(2, at(1, 6, 0), .app, .missed, 0, 0, 0, "Échéance manquée (Mac éteint ou en veille)."),
            entry(1, at(1, 6, 30, plus: 38), .agent, .ok, 19, 1, 38, "19 en ligne, 1 nouveau, 38\u{00A0}s."),
            entry(0, at(1, 2, 0, plus: 179), .agent, .partial, 45, 0, 179,
                  "45 en ligne, 0 nouveau, 2\u{00A0}min\u{00A0}59\u{00A0}s. Inventaire non mis à jour."),
            entry(2, at(3, 22, 15, plus: 96), .app, .ok, 31, 0, 96, "31 en ligne, 0 nouveau, 1\u{00A0}min\u{00A0}36\u{00A0}s."),
        ]
        return ScanScheduleBook(schedules: schedules, runs: runs)
    }

    static var agentStatus: AgentStatus {
        AgentStatus(pid: 4242, version: "0.31.0", startedAt: at(3, 8, 2), heartbeat: now.addingTimeInterval(-3), mode: .standby,
                    probes: 6, syslogPort: nil, nextScan: at(-1, 2, 0))
    }

    static var agentJournal: AgentJournal {
        AgentJournal(entries: [
            AgentJournalEntry(date: at(0, 8, 41), text: "NetScope est ouvert\u{00A0}: l’agent attend."),
            AgentJournalEntry(date: at(0, 2, 3, plus: 4), text: "Scan de «\u{00A0}Siège social\u{00A0}»\u{00A0}: 47 en ligne, 2 nouveaux, 3\u{00A0}min\u{00A0}4\u{00A0}s."),
            AgentJournalEntry(date: at(0, 2, 0), text: "Scan planifié de «\u{00A0}Siège social\u{00A0}» (Complet)."),
            AgentJournalEntry(date: at(0, 1, 12), level: .warning, text: "Sonde «\u{00A0}Imprimante 2e étage\u{00A0}»\u{00A0}: aucune réponse après 3 tentatives."),
            AgentJournalEntry(date: at(1, 18, 5), text: "NetScope est fermé\u{00A0}: l’agent prend le relais (6 sondes, Syslog sur le port 5514, scans planifiés)."),
        ])
    }
}
