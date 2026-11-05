import NetScopeCore
import SwiftUI

/// Conditions des sondes de journaux (note 43) : gravité minimale d'un message Syslog, ou trap
/// attendue. Les sondes lisent le journal de l'écran Journaux (récepteurs de ce Mac et journaux lus
/// sur la FortiGate) : aucun trafic propre.
struct MonLogConditionFields: View {
    @Binding var probe: MonProbe
    @ObservedObject private var logs = LogStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if probe.kind == .syslogSeverity {
                HStack(spacing: 6) {
                    Text("Alerte à chaque message").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                    MonMenuField(title: (probe.logSeverity ?? .error).atLeastLabel) {
                        ForEach(LogSeverity.allCases.filter { $0 != .debug }) { severity in
                            Button(severity.atLeastLabel + " (\(severity.keyword))") { probe.logSeverity = severity }
                        }
                    }
                    .frame(width: 170)
                }
                Text("Messages Syslog reçus par ce Mac et journaux lus sur la FortiGate, pendant le dernier intervalle de la sonde. L’alerte se referme d’elle-même quand plus rien n’arrive.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    Text("Trap attendue").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                    MonInput(placeholder: "toutes, ou linkDown, coldStart, fgTrapVpnTunDown…",
                             text: Binding(get: { probe.trapFilter ?? "" },
                                           set: { probe.trapFilter = $0.isEmpty ? nil : $0 }), mono: true)
                }
                Text("Nom de la trap (linkDown, authenticationFailure…), partie de son OID, ou mot de son message. Les traps reçues pendant le dernier intervalle de la sonde déclenchent l’alerte.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(statusLine)
                .font(Theme.caption).foregroundStyle(listening ? Theme.textTertiary : Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var listening: Bool {
        probe.kind == .trapReceived ? logs.isListening(.trap) : (logs.isListening(.syslog) || logs.hasFortiGateLogs)
    }

    private var statusLine: String {
        if listening {
            return probe.kind == .trapReceived ? "Récepteur de traps en écoute (UDP \(logs.trapPort))."
                : "Récepteur Syslog en écoute (UDP \(logs.syslogPort)) ou journaux de la FortiGate lus."
        }
        return "Récepteur arrêté\u{00A0}: démarrez-le dans Journaux (la sonde reste «\u{00A0}sans donnée\u{00A0}» d’ici là)."
    }
}
