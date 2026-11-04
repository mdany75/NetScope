import NetScopeCore
import SwiftUI

/// Période d'analyse.
enum AnaPeriod: String, CaseIterable, Hashable {
    case jour, semaine, mois

    var label: String {
        switch self {
        case .jour: return "24 h"
        case .semaine: return "7 j"
        case .mois: return "30 j"
        }
    }

    var span: String {
        switch self {
        case .jour: return "dernières 24 h"
        case .semaine: return "7 derniers jours"
        case .mois: return "30 derniers jours"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .jour: return 86_400
        case .semaine: return 7 * 86_400
        case .mois: return 30 * 86_400
        }
    }
}

/// Écran `Screen.analyse` : indicateurs, occupation d'un /24, répartitions, alertes issues de l'inventaire
/// et comparaison de deux scans (croquis docs/croquis/Analyse.dc.html).
struct AnalyseScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    @State private var period: AnaPeriod = .jour
    /// /24 choisi ; nil : toutes les plages.
    @State private var network: IPv4Address?
    @State private var networkChosen = false
    @State private var exportDocument: InvCSVDocument?
    @State private var exportName = "analyse.csv"
    @State private var exporting = false

    var body: some View {
        let now = Date()
        let since = now.addingTimeInterval(-period.seconds)
        let allRecords = Array(model.store.records.values)
        let networks = InvOccupancy.networks(of: allRecords)
        let chosen = networkChosen ? network : defaultNetwork(networks)
        let records = chosen.map { base in allRecords.filter { $0.ip.value & 0xFFFF_FF00 == base.value } } ?? allRecords
        let alerts = model.alerts(since: since)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filters(networks: networks, chosen: chosen, now: now, since: since)
                tiles(records: records, chosen: chosen, alerts: alerts, now: now, since: since)
                HStack(alignment: .top, spacing: 14) {
                    if let chosen {
                        AnaOccupancyPanel(network: chosen, records: allRecords, now: now, recentWindow: max(period.seconds, 7 * 86_400))
                            .frame(width: 680)
                    } else {
                        Panel(padding: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                InvPanelTitle("Carte d’occupation")
                                Text("Choisissez un /24 dans « Plage / VLAN » pour afficher la carte de ses 256 adresses.")
                                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(width: 680)
                    }
                    VStack(spacing: 14) {
                        AnaOnlineChart(snapshots: model.store.snapshots.filter { $0.date >= since }, period: period)
                        AnaBreakdownPanel(records: records)
                    }
                    .frame(maxWidth: .infinity)
                }
                // Alertes, puis comparaison, sur toute la largeur : leurs tableaux (note 8) ne tiennent
                // pas côte à côte ; le croquis passe aussi à une colonne quand la place manque.
                AnaAlertsPanel(alerts: alerts, period: period, query: state.searchText)
                    .frame(maxWidth: .infinity)
                AnaComparePanel(snapshots: model.store.snapshots) { text, name in
                    exportDocument = InvCSVDocument(text: text)
                    exportName = name
                    exporting = true
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .screenToolbar {
            Button {
                exportDocument = InvCSVDocument(text: alertsCSV(alerts))
                exportName = "analyse-\(InvFormat.day(now))-\(period.label.replacingOccurrences(of: " ", with: "")).csv"
                exporting = true
            } label: { Label("Exporter CSV", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
            Button { state.open(.rapports) } label: { Label("Rapport PDF", systemImage: "doc.richtext") }
                .buttonStyle(.primary)
        }
        .feedsInventory(state)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: exportName) { result in
            if case .success(let url) = result { model.show("CSV enregistré : \(url.lastPathComponent)") }
        }
    }

    private func defaultNetwork(_ networks: [IPv4Address]) -> IPv4Address? {
        if let address = state.activeInterface?.address {
            let base = IPv4Address(address.value & 0xFFFF_FF00)
            if networks.contains(base) { return base }
        }
        return networks.first
    }

    // MARK: Filtres

    private func filters(networks: [IPv4Address], chosen: IPv4Address?, now: Date, since: Date) -> some View {
        let scans = model.store.snapshots.filter { $0.date >= since }.count
        let last = model.store.lastMerge
        return HStack(spacing: 12) {
            InvSegmented(options: AnaPeriod.allCases.map { ($0, $0.label) }, selection: $period, filled: true)
            HStack(spacing: 8) {
                Text("Plage / VLAN").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Picker("", selection: Binding(get: { chosen }, set: { network = $0; networkChosen = true })) {
                    ForEach(networks, id: \.self) { base in
                        Text(networkLabel(base)).tag(Optional(base))
                    }
                    Text("Toutes les plages (\(networks.count))").tag(IPv4Address?.none)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 280)
            }
            Text("\(scans) scan\(scans > 1 ? "s" : "") sur \(period.span)" + (last.map { " · dernier scan \(InvFormat.time($0))" } ?? ""))
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
            if let toast = model.toast { InvToast(text: toast) }
        }
    }

    private func networkLabel(_ base: IPv4Address) -> String {
        let subnet = Subnet(address: base, prefix: 24)
        var label = subnet.description
        if let range = state.ranges.first(where: { (try? $0.parsed())?.contains(base.next ?? base) == true }) {
            label += " · " + range.label
        }
        let vlans = Set(model.store.records.values.filter { subnet.contains($0.ip) }.compactMap(\.vlan)).sorted()
        if !vlans.isEmpty { label += " · VLAN " + vlans.map(String.init).joined(separator: ", ") }
        return label
    }

    // MARK: Tuiles

    private func tiles(records: [InvRecord], chosen: IPv4Address?, alerts: [InvEvent], now: Date, since: Date) -> some View {
        let added = records.filter { $0.firstSeen >= since && !$0.isImported }.count
        let lost = records.filter { !$0.isOnline && ($0.offlineSince ?? .distantPast) >= since }.count
        let online = records.filter(\.isOnline).count
        let recentOffline = records.filter { !$0.isOnline && now.timeIntervalSince($0.lastSeen) <= 7 * 86_400 }.count
        let conflicts = Set(records.filter(\.hasConflict).map(\.ip)).sorted()
        let pending = alerts.filter { $0.status == .aTraiter && $0.severity != .info }.count
        // Même fenêtre « vu récemment » que la carte d'occupation affichée dessous.
        let occupancy = chosen.map {
            InvOccupancy(network: $0, records: records, now: now, recentWindow: max(period.seconds, 7 * 86_400))
        }

        return HStack(alignment: .top, spacing: 12) {
            InvTile(title: "Appareils", value: "\(records.count)", subtitle: "+\(added) / −\(lost) sur \(period.label)", valueSize: 26)
            InvTile(title: "En ligne", value: "\(online)", subtitle: "\(recentOffline) hors ligne vus récemment",
                    valueColor: Theme.success, valueSize: 26)
            InvTile(title: "Nouveaux", value: "\(added)", subtitle: "Première détection sur \(period.label)",
                    valueColor: Theme.accentStrong, valueSize: 26)
            InvTile(title: "Conflit IP", value: "\(conflicts.count)",
                    subtitle: conflicts.isEmpty ? "Aucun conflit actif" : "Actif · " + conflicts.map(\.description).joined(separator: ", "),
                    valueColor: conflicts.isEmpty ? Theme.text : Theme.critical,
                    tint: conflicts.isEmpty ? nil : .critical, valueSize: 26)
            InvTile(title: "Alertes à traiter", value: "\(pending)", subtitle: "Critiques et alertes sur \(period.label)",
                    valueColor: pending > 0 ? Theme.warning : Theme.text, valueSize: 26)
            InvTile(title: "Utilisation de la plage", value: "") {
                if let occupancy {
                    let percent = Int((occupancy.usage * 100).rounded())
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(percent) %").font(.system(size: 26, weight: .bold))
                                .foregroundStyle(percent >= 75 ? Theme.warning : Theme.text)
                            Text("\(occupancy.usedCount)/254").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                        }
                        ProgressBar(fraction: occupancy.usage, color: percent >= 75 ? Theme.warning : Theme.accent)
                    }
                } else {
                    Text("Choisissez un /24").font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.top, 6)
                }
            }
        }
    }

    // MARK: Export

    private func alertsCSV(_ alerts: [InvEvent]) -> String {
        var lines = ["Date;Gravité;Type;IP;Titre;Détail;Traitement"]
        for alert in alerts {
            let status: String
            switch alert.status {
            case .aTraiter: status = "À traiter"
            case .accepte: status = "Accepté"
            case .ignore: status = "Ignoré"
            }
            lines.append([InvFormat.stamp(alert.date), alert.severity.label, alert.kind.label, alert.ip.description,
                          alert.title, alert.detail, status].map(AnaCSV.quote).joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

enum AnaCSV {
    /// Même protection que l'export d'inventaire (guillemets, sauts de ligne, formules).
    static func quote(_ field: String) -> String { InvCSV.quote(field, ";") }
}
