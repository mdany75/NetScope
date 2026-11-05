import Foundation

/// Sondes des journaux (note 43) : elles lisent le journal de NetScope (aucun trafic propre).
/// - « Message Syslog de gravité ≥ X » : un message Syslog ou de la FortiGate au moins aussi grave
///   que X est arrivé pendant le dernier intervalle de la sonde ;
/// - « Trap SNMP reçue » : une trap (toutes, ou celle nommée) est arrivée pendant ce même intervalle.
/// L'alerte se referme d'elle-même au passage suivant sans nouveau message.
public enum MonLogChecks {
    public static func run(_ probe: MonProbe, target: String, logs: [LogMessage]?, listening: Set<LogSource>,
                           now: Date) -> MonRunOutcome {
        let wanted: Set<LogSource> = probe.kind == .trapReceived ? [.trap] : [.syslog, .fortigate]
        guard let logs else {
            return .noData(now, "Journaux vides")
        }
        if listening.isDisjoint(with: wanted), !(probe.kind == .syslogSeverity && logs.contains { $0.source == .fortigate }) {
            return .noData(now, probe.kind == .trapReceived ? "Récepteur de traps arrêté" : "Récepteur Syslog arrêté")
        }
        // Fenêtre : l'intervalle de la sonde (et quelques secondes, pour ne rien laisser entre deux passages).
        let since = now.addingTimeInterval(-TimeInterval(probe.interval) - 5)
        var found = logs.filter { wanted.contains($0.source) && $0.arrival >= since && $0.arrival <= now.addingTimeInterval(5) }
        if !MonTrafficChecks.isAll(target) {
            let host = SearchText.fold(target.trimmingCharacters(in: .whitespaces))
            found = found.filter { SearchText.fold($0.host) == host || SearchText.fold($0.hostname ?? "") == host }
        }
        switch probe.kind {
        case .trapReceived:
            let filter = SearchText.fold(probe.trapFilter?.trimmingCharacters(in: .whitespaces) ?? "")
            if !filter.isEmpty {
                found = found.filter { m in
                    [m.eventID, m.fields["trap"], m.message].compactMap { $0 }.contains { SearchText.fold($0).contains(filter) }
                }
            }
            guard let last = found.last else {
                return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Aucune trap"))
            }
            let problem = "Trap \(last.eventID ?? "") de \(last.deviceLabel)\u{00A0}: \(last.message)"
                + (found.count > 1 ? " (et \(found.count - 1) autre\(found.count > 2 ? "s" : ""))" : "")
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: LogFormat.count(found.count, "trap", "traps"),
                                                   problem: problem))
        default:
            let minimum = probe.logSeverity ?? .error
            let severe = found.filter { $0.severity.isAtLeast(minimum) }
            guard let worst = severe.min(by: { $0.severity != $1.severity ? $0.severity < $1.severity : $0.date > $1.date }) else {
                return MonRunOutcome(result: MonResult(date: now, reachable: true,
                                                       value: "Aucun message \(minimum.atLeastLabel)"))
            }
            let problem = "\(worst.severity.label) de \(worst.deviceLabel)\u{00A0}: \(worst.message)"
                + (severe.count > 1 ? " (\(severe.count) messages \(minimum.atLeastLabel))" : "")
            return MonRunOutcome(result: MonResult(date: now, reachable: true,
                                                   value: LogFormat.count(severe.count, "message", "messages") + " " + minimum.atLeastLabel,
                                                   problem: problem))
        }
    }
}
