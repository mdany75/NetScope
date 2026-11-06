import NetScopeCore
import SwiftUI

// Note 74 : historique du trafic dans Switchs et ports. Sous le détail du port, la courbe du
// port sur 1 h, 24 h, 7 j ou 30 j avec les débits max et moyen, le pourcentage de la vitesse du
// lien et les erreurs par heure ; dans la colonne principale, « Ports les plus chargés » sur la
// même période (ou en direct pour un switch SNMP). Les relevés du switch alimentent l'historique ;
// rien n'est interrogé ici.

/// Périodes choisies dans Switchs et ports, gardées d'une visite à l'autre (préférences).
@MainActor
final class SwitchHistoryState: ObservableObject {
    static let shared = SwitchHistoryState()

    /// Période de la courbe du port.
    @Published var portRange: PortHistoryRange {
        didSet { if !isDemo { UserDefaults.standard.set(portRange.rawValue, forKey: Self.portKey) } }
    }
    /// Période des ports les plus chargés ; nil : en direct (relevés du panneau Trafic du port).
    @Published var tableRange: PortHistoryRange? {
        didSet { if !isDemo { UserDefaults.standard.set(tableRange?.rawValue ?? "direct", forKey: Self.tableKey) } }
    }

    private let isDemo: Bool
    private static let portKey = "NetScope.switchs.historique.port"
    private static let tableKey = "NetScope.switchs.historique.tableau"

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if demo {
            // Captures : NETSCOPE_SWITCH_HISTORIQUE=1h, 24h, 7j ou 30j (période de la courbe et du
            // tableau) ; NETSCOPE_SWITCH_TABLEAU=direct garde le tableau en direct.
            let env = ProcessInfo.processInfo.environment
            let requested = env["NETSCOPE_SWITCH_HISTORIQUE"].flatMap(Self.range(capture:))
            portRange = requested ?? .day
            tableRange = env["NETSCOPE_SWITCH_TABLEAU"]?.lowercased() == "direct" ? nil : (requested ?? .day)
        } else {
            let defaults = UserDefaults.standard
            portRange = defaults.string(forKey: Self.portKey).flatMap(PortHistoryRange.init(rawValue:)) ?? .day
            let table = defaults.string(forKey: Self.tableKey)
            tableRange = table == "direct" ? nil : (table.flatMap(PortHistoryRange.init(rawValue:)) ?? .day)
        }
    }

    static func range(capture text: String) -> PortHistoryRange? {
        switch text.lowercased() {
        case "1h", "heure": return .hour
        case "24h", "jour": return .day
        case "7j", "semaine": return .week
        case "30j", "mois": return .month
        default: return PortHistoryRange(rawValue: text.lowercased())
        }
    }
}

/// Panneau « Historique du port » sous le détail du port sélectionné.
struct SwitchPortHistoryPanel: View {
    @ObservedObject var store: SwitchStore
    @ObservedObject private var history = PortHistoryStore.shared
    @ObservedObject private var periods = SwitchHistoryState.shared
    let snapshot: SNMPSwitchSnapshot
    let iface: SNMPInterface

    var body: some View {
        let now = history.now
        let series = history.series(host: snapshot.id, ifIndex: iface.index, siteKey: store.historySiteKey(for: snapshot.id))
        let range = periods.portRange
        let stats = series?.stats(range, now: now)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SwitchFieldLabel("Historique · \(iface.name)")
                Spacer(minLength: 4)
                PortHistoryRangePicker(range: $periods.portRange)
            }
            if let series, let stats, stats.hasData {
                PortHistoryChart(curve: series.curve(range, now: now), speedMbps: series.speedMbps ?? iface.speedMbps, height: 96)
                HStack {
                    ResourceLegend(items: [("Entrée", ResourceColors.primary), ("Sortie", ResourceColors.secondary)])
                    Spacer(minLength: 4)
                    Text(PortHistoryText.coverage(stats)).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                figures(stats)
            } else {
                Text(emptyText(range))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func emptyText(_ range: PortHistoryRange) -> String {
        if !iface.isUp { return "Port inactif\u{00A0}: aucun trafic gardé sur \(range.phrase)." }
        let source = snapshot.isViaController ? (snapshot.controllerKind.map { "chaque lecture du contrôleur \($0)" } ?? "chaque lecture de la FortiGate") : "chaque relevé du switch"
        return "Aucune mesure sur \(range.phrase). L’historique se remplit à \(source) (interrogation, fin de scan, relecture automatique) et tant que le trafic du port est affiché\u{00A0}; il est gardé 90\u{00A0}jours."
    }

    private func figures(_ stats: PortHistoryStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                direction("Entrée", symbol: "arrow.down", color: ResourceColors.primary,
                          peak: stats.inPeak, peakPercent: stats.inPeakPercent, average: stats.inAverage, averagePercent: stats.inAveragePercent)
                direction("Sortie", symbol: "arrow.up", color: ResourceColors.secondary,
                          peak: stats.outPeak, peakPercent: stats.outPeakPercent, average: stats.outAverage, averagePercent: stats.outAveragePercent)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("ERREURS").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Text(ToolFormat.integer(stats.errors)).font(Theme.mono(12))
                PortErrorRateText(rate: stats.errorsPerHour, errors: stats.errors)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(errorBackground(stats)))
                Spacer(minLength: 4)
                Text(stats.speedMbps.map { "Lien \(SNMPFormat.speed(mbps: $0))" } ?? "Vitesse du lien inconnue")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .help("Erreurs en entrée apparues sur \(stats.range.phrase) (pas le total depuis le démarrage du switch)")
        }
    }

    private func errorBackground(_ stats: PortHistoryStats) -> Color {
        guard let rate = stats.errorsPerHour else { return .clear }
        if rate >= PortErrorRate.warningThreshold { return Theme.criticalSoft }
        if rate >= PortErrorRate.adviceThreshold, stats.errors >= 5 { return Theme.warningSoft }
        return .clear
    }

    private func direction(_ title: String, symbol: String, color: Color, peak: Double, peakPercent: Double?,
                           average: Double, averagePercent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                Text(title.uppercased()).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            row("Max", value: peak, percent: peakPercent, strong: true)
            ResourceBar(percent: peakPercent, height: 4, color: (peakPercent ?? 0) >= 75 ? ResourceColors.load(peakPercent) : color)
            row("Moyen", value: average, percent: averagePercent, strong: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, value: Double, percent: Double?, strong: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textTertiary).frame(width: 38, alignment: .leading)
            Text(ResourceFormat.bitsPerSecond(value)).font(Theme.mono(strong ? 13 : 12, weight: strong ? .semibold : .regular))
                .lineLimit(1).minimumScaleFactor(0.8)
            if let percent {
                Text(ResourceFormat.percent(percent)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }
}

/// « Ports les plus chargés » du switch : en direct (relevés du panneau Trafic du port, switch SNMP)
/// ou sur une période de l'historique (tableau standard).
struct SwitchBusiestPorts: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    /// Relevés en direct ; nil pour un FortiSwitch lu par la FortiGate.
    var monitor: SNMPResourceMonitor?
    /// Lignes montrées sans défiler (note 83 : plus dans l'onglet Trafic, où le tableau est seul).
    var maxRows = 8
    let snapshot: SNMPSwitchSnapshot
    @ObservedObject private var history = PortHistoryStore.shared
    @ObservedObject private var periods = SwitchHistoryState.shared
    @State private var selection: String?

    var body: some View {
        if let monitor, periods.tableRange == nil {
            SwitchTopPorts(store: store, monitor: monitor, snapshot: snapshot, accessory: AnyView(picker))
        } else {
            historyPanel(periods.tableRange ?? .day)
        }
    }

    /// Sans relevés en direct (FortiSwitch), « En direct » gardé pour les autres switchs vaut 24 h :
    /// le segment 24 h est alors mis en évidence, comme le tableau.
    private var pickerSelection: Binding<PortHistoryRange?> {
        guard monitor == nil else { return $periods.tableRange }
        return Binding(get: { periods.tableRange ?? .day }, set: { periods.tableRange = $0 })
    }

    /// En direct, 1 h, 24 h, 7 j, 30 j.
    private var picker: some View {
        Picker("Période", selection: pickerSelection) {
            if monitor != nil { Text("En direct").tag(PortHistoryRange?.none) }
            ForEach(PortHistoryRange.allCases) { Text($0.label).tag(PortHistoryRange?.some($0)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("En direct\u{00A0}: débit entre les deux derniers relevés. 1\u{00A0}h à 30\u{00A0}j\u{00A0}: historique des ports.")
    }

    private func historyPanel(_ range: PortHistoryRange) -> some View {
        let now = history.now
        let physical = Set(snapshot.physicalPorts.map(\.index))
        let summaries = history.switchHistory(host: snapshot.id, siteKey: store.historySiteKey(for: snapshot.id))
            .map { PortHistoryRanking.summaries($0, range: range, now: now, physicalOnly: physical) } ?? []
        let rows = PortHistoryRanking.busiest(summaries).map(PortHistoryRow.init(summary:))
        return Panel(padding: 0) {
            if rows.isEmpty {
                VStack(spacing: 0) {
                    bar(range, count: 0, columns: nil)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    Text("Aucune mesure sur \(range.phrase)\u{00A0}: l’historique se remplit à chaque relevé du switch (la relecture automatique le tient à jour).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                PortHistoryTable(id: "switchs.ports.historique", rows: rows, showsSwitch: false, selection: $selection, maxRows: maxRows) { columns in
                    VStack(spacing: 0) {
                        bar(range, count: rows.count, columns: AnyView(columns))
                        Rectangle().fill(Theme.border).frame(height: 1)
                    }
                }
            }
        }
        .onAppear { selection = store.selectedPort.map { "\(snapshot.id)|\($0)" } }
        .onChange(of: store.selectedPort) { _, port in
            let id = port.map { "\(snapshot.id)|\($0)" }
            if selection != id { selection = id }
        }
        .onChange(of: selection) { _, id in
            guard let id, let index = id.split(separator: "|").last.flatMap({ Int($0) }), index != store.selectedPort else { return }
            store.select(host: snapshot.host.description, port: index)
        }
    }

    private func bar(_ range: PortHistoryRange, count: Int, columns: AnyView?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                heading(range, count: count)
                Spacer(minLength: 8)
                picker
                columns
            }
            VStack(alignment: .leading, spacing: 8) {
                heading(range, count: count)
                HStack(spacing: 8) {
                    picker
                    Spacer(minLength: 0)
                    columns
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func heading(_ range: PortHistoryRange, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Ports les plus chargés").font(.system(size: 14, weight: .semibold)).fixedSize()
            Text("\(count) port\(count > 1 ? "s" : "") mesuré\(count > 1 ? "s" : "") sur \(range.phrase)")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }
}
