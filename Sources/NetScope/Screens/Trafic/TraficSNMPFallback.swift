import NetScopeCore
import SwiftUI

// Note 78 (Trafic) : quand FortiView n'est pas lu (aucune FortiGate prête pour les sites montrés,
// droit « FortiView » manquant, réseau sans FortiGate), l'écran Trafic se rabat sur l'historique des
// ports des switchs (note 74) : compteurs SNMP ifHCInOctets/ifHCOutOctets et compteurs des FortiSwitch
// lus par la FortiGate. Tuiles, ports les plus chargés de tous les switchs et erreurs par heure.
// Rien n'est interrogé ici : l'historique vient des relevés déjà faits.

/// Période choisie pour le secours SNMP, gardée d'une visite à l'autre.
@MainActor
final class TraficSNMPState: ObservableObject {
    static let shared = TraficSNMPState()

    @Published var range: PortHistoryRange {
        didSet { if !isDemo { UserDefaults.standard.set(range.rawValue, forKey: Self.key) } }
    }
    @Published var selection: String?
    private let isDemo: Bool
    private static let key = "NetScope.trafic.snmp.periode"

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if demo {
            range = ProcessInfo.processInfo.environment["NETSCOPE_TRAFIC_PERIODE"].flatMap(SwitchHistoryState.range(capture:)) ?? .day
        } else {
            range = UserDefaults.standard.string(forKey: Self.key).flatMap(PortHistoryRange.init(rawValue:)) ?? .day
        }
    }
}

struct TraficSNMPFallback: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var history = PortHistoryStore.shared
    @ObservedObject private var model = TraficSNMPState.shared
    /// Sites montrés par l'écran (clés `SiteFiles.key`).
    let keys: [String]
    /// Lecture FortiView en cours (le secours reste affiché en attendant).
    var isReading = false
    var analyse: () -> Void

    /// Captures : NETSCOPE_TRAFIC_VUE=snmp montre le secours même si FortiView est lu.
    static var forced: Bool { TrafficDemo.requestedView == "snmp" }

    /// Lignes de tous les switchs des sites montrés, sur la période.
    @MainActor
    static func rows(keys: [String], range: PortHistoryRange) -> [PortHistoryRow] {
        let store = PortHistoryStore.shared
        let now = store.now
        var seen = Set<String>()
        var summaries: [PortHistorySummary] = []
        for key in keys {
            for switchHistory in store.history(siteKey: key).switches.values {
                for summary in PortHistoryRanking.summaries(switchHistory, range: range, now: now) where seen.insert(summary.id).inserted {
                    summaries.append(summary)
                }
            }
        }
        return PortHistoryRanking.busiest(summaries).map(PortHistoryRow.init(summary:))
    }

    /// Vrai si un des sites montrés a un historique de ports (sur 30 jours).
    @MainActor
    static func hasData(keys: [String]) -> Bool {
        let store = PortHistoryStore.shared
        return keys.contains { !store.history(siteKey: $0).isEmpty }
    }

    var body: some View {
        let range = model.range
        let rows = Self.rows(keys: keys, range: range)
        let switches = Set(rows.map(\.host)).count
        VStack(alignment: .leading, spacing: 14) {
            ToolNotice(tone: .accent, title: "Trafic d’après les compteurs des switchs",
                       message: "FortiView n’est pas lu pour \(keys.count > 1 ? "ces sites" : "ce site")\u{00A0}: l’écran montre le trafic des ports relevé sur les switchs (SNMP ifHCInOctets / ifHCOutOctets, compteurs de la FortiGate pour les FortiSwitch). Les applications, destinations et menaces demandent FortiView.") {
                if isReading { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 12) {
                PortHistoryRangePicker(range: $model.range)
                Text("\(rows.count) port\(rows.count > 1 ? "s" : "") mesuré\(rows.count > 1 ? "s" : "") sur \(switches) switch\(switches > 1 ? "s" : "") · \(range.phrase)")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            tiles(rows, range: range)
            Panel(padding: 0) {
                if rows.isEmpty {
                    Text("Aucune mesure sur \(range.phrase). Interrogez les switchs (Switchs et ports) ou activez la relecture automatique des switchs SNMP pour tenir l’historique à jour.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    PortHistoryTable(id: "trafic.ports.snmp", rows: rows, showsSwitch: true, selection: $model.selection, maxRows: 14) { columns in
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Text("Ports les plus chargés").font(.system(size: 14, weight: .semibold)).fixedSize()
                                Text("double-clic\u{00A0}: appareil branché").font(Theme.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                Spacer(minLength: 8)
                                columns
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            Rectangle().fill(Theme.border).frame(height: 1)
                        }
                    }
                }
            }
            Button(action: analyse) {
                Label("Bilan de santé", systemImage: "stethoscope")
            }
            .buttonStyle(.secondary)
            .fixedSize()
            .help("Bilan de la santé (ports saturés ou en erreur, WAN, Wi-Fi, DHCP) et de l’inventaire")
        }
    }

    private func tiles(_ rows: [PortHistoryRow], range: PortHistoryRange) -> some View {
        let busiest = rows.first
        let loaded = rows.filter { ($0.stats.peakPercent ?? 0) >= 75 }
        let erring = rows.filter { row in
            guard let rate = row.stats.errorsPerHour else { return false }
            return rate >= PortErrorRate.adviceThreshold && row.stats.errors >= 5
        }.sorted { ($0.stats.errorsPerHour ?? 0) > ($1.stats.errorsPerHour ?? 0) }
        // Part de la période mesurée (moyenne des ports) : la fiabilité des chiffres.
        let coverage = rows.isEmpty ? 0 : rows.reduce(0.0) { $0 + $1.stats.coverage } / Double(rows.count) * 100
        let switches = Set(rows.map(\.host)).count
        let peak = busiest?.stats.peakPercent
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            InvTile(title: "Port le plus chargé", value: ResourceFormat.percent(peak),
                    subtitle: busiest.map { "\($0.switchName) · \($0.port) · max \(ResourceFormat.bitsPerSecond($0.stats.peakBitsPerSecond))" } ?? "Aucune mesure",
                    valueColor: ResourceColors.tone(peak) == .success ? Theme.text : ResourceColors.tone(peak).foreground,
                    action: busiest.map { row in { state.perform(.port(NavPortRef(host: row.host, ifIndex: row.ifIndex))) } }) {
                if let peak { ProgressBar(fraction: peak / 100, color: ResourceColors.load(peak)).padding(.top, 2) }
            }
            InvTile(title: "Ports chargés à 75\u{00A0}% ou plus", value: "\(loaded.count)",
                    subtitle: loaded.isEmpty ? "Aucun sur \(range.phrase)" : loaded.prefix(2).map { "\($0.switchName) · \($0.port)" }.joined(separator: ", ") + (loaded.count > 2 ? "…" : ""),
                    valueColor: loaded.isEmpty ? Theme.text : Theme.warning)
            InvTile(title: "Ports en erreur", value: "\(erring.count)",
                    subtitle: erring.first.map { "\($0.switchName) · \($0.port) · \(PortErrorRate.label($0.stats.errorsPerHour))" } ?? "Aucune erreur qui augmente",
                    valueColor: erring.isEmpty ? Theme.text : Theme.critical,
                    tint: erring.contains { ($0.stats.errorsPerHour ?? 0) >= PortErrorRate.warningThreshold } ? .critical : nil)
            InvTile(title: "Ports suivis", value: "\(rows.count)",
                    subtitle: "\(switches) switch\(switches > 1 ? "s" : "") · \(ResourceFormat.percent(coverage)) de la période mesurée")
        }
    }
}
