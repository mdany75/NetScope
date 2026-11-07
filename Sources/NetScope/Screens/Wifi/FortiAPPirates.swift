import NetScopeCore
import SwiftUI

/// Note 97 : onglet « Pirates » du Wi-Fi FortiAP. Bornes entendues par les FortiAP et par le dernier
/// balayage de ce Mac, rangées en pirates (sosie d'un SSID du site, borne branchée sur le réseau,
/// non autorisée dans FortiOS), voisines et connues ; une voisine peut être acceptée.
struct FortiAPPirateRow: Identifiable {
    let finding: RogueAPFinding
    var id: String { finding.id }
    var ssid: String { finding.displaySSID.lowercased() }
    var classRank: Int { RogueAPClass.allCases.firstIndex(of: finding.classification) ?? 0 }
    var bssid: UInt64 { finding.bssid?.value ?? UInt64.max }
    var channel: Int { finding.channel ?? Int.max }
    var rssi: Int { finding.rssi ?? Int.min }
    var reason: String { finding.reasonLabel }
    var source: String { finding.sources.map(\.label).joined(separator: ", ") }
}

struct FortiAPPirateTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    @ObservedObject private var pirates = PirateStore.shared
    @StateObject private var table = StandardTableModel<FortiAPPirateRow>(id: "wifi.fortiap.pirates", columns: Self.columns,
                                                                          sortKeys: Self.sortKeys, defaultSort: "classe")
    @State private var search = ""
    @State private var selection: FortiAPPirateRow.ID?
    /// Sosie dont l'acceptation attend confirmation.
    @State private var pendingTwin: RogueAPFinding?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ssid", title: "SSID", isRequired: true),
        StandardColumn(id: "classe", title: "Classe"),
        StandardColumn(id: "raison", title: "Raison"),
        StandardColumn(id: "bssid", title: "BSSID"),
        StandardColumn(id: "canal", title: "Canal"),
        StandardColumn(id: "signal", title: "Signal"),
        StandardColumn(id: "source", title: "Vu par"),
        StandardColumn(id: "action", title: "Action", isRequired: true),
    ]

    static let sortKeys: [String: KeyPathComparator<FortiAPPirateRow>] = [
        "ssid": KeyPathComparator(\FortiAPPirateRow.ssid), "classe": KeyPathComparator(\FortiAPPirateRow.classRank),
        "raison": KeyPathComparator(\FortiAPPirateRow.reason), "bssid": KeyPathComparator(\FortiAPPirateRow.bssid),
        "canal": KeyPathComparator(\FortiAPPirateRow.channel), "signal": KeyPathComparator(\FortiAPPirateRow.rssi, order: .reverse),
        "source": KeyPathComparator(\FortiAPPirateRow.source),
    ]

    var body: some View {
        let all = pirates.rogueAPs(devices: state.devices)
        let counts = Dictionary(grouping: all, by: \.classification).mapValues(\.count)
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = all.filter { f in
            (pirates.apFilter == nil || f.classification == pirates.apFilter)
                && (needle.isEmpty || [f.displaySSID, f.bssid?.formatted(.upperColon) ?? "", f.vendor ?? "", f.reasonLabel, f.wiredPlace ?? ""]
                    .contains { $0.lowercased().contains(needle) })
        }
        .map(FortiAPPirateRow.init)
        .sorted(using: table.sortOrder + [KeyPathComparator(\FortiAPPirateRow.rssi, order: .reverse)])
        VStack(alignment: .leading, spacing: 12) {
            if let banner = banner(all) { banner }
            FortiAPTableFrame {
                FortiAPTableHeader(title: "Bornes pirates, voisines et connues", summary: summary(all),
                                   search: $search, prompt: "SSID, BSSID, raison…", model: table) {
                    Picker("Bornes affichées", selection: $pirates.apFilter) {
                        Text("Toutes (\(all.count))").tag(RogueAPClass?.none)
                        ForEach(RogueAPClass.allCases, id: \.self) { kind in
                            Text("\(kind.label) (\(counts[kind] ?? 0))").tag(RogueAPClass?.some(kind))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Button {
                        pirates.scanFromThisMac()
                    } label: {
                        Label("Balayer depuis ce Mac", systemImage: "wifi")
                    }
                    .help("Ajoute les bornes entendues par ce Mac (balayage Wi-Fi sur clic, autorisation de localisation requise)")
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                if rows.isEmpty {
                    fortiEmptyLine(all.isEmpty
                                   ? "Aucune borne lue\u{00A0}: lisez la FortiGate (AP voisins) ou balayez depuis ce Mac."
                                   : "Aucune borne ne correspond à ce filtre.")
                } else {
                    tableView(rows)
                        .standardTableHeight(rows: rows.count, rowHeight: 28, maxRows: 12)
                }
            }
        }
    }

    private func summary(_ all: [RogueAPFinding]) -> String {
        var text = "\(all.count) borne\(all.count > 1 ? "s" : "") entendue\(all.count > 1 ? "s" : "")"
        if let date = pirates.localScanDate {
            text += " · balayage de ce Mac " + date.formatted(date: .omitted, time: .shortened)
        }
        return text
    }

    /// Bandeau d'alerte quand des pirates sont présentes (sosie et borne branchée en premier).
    private func banner(_ all: [RogueAPFinding]) -> AnyView? {
        let found = all.filter { $0.classification == .pirate }
        guard !found.isEmpty else { return nil }
        let twins = found.filter { $0.reasons.contains(.sosie) }.count
        let wired = found.filter { $0.reasons.contains(.filaire) }.count
        var parts: [String] = []
        if twins > 0 { parts.append("\(twins) sosie\(twins > 1 ? "s" : "") d’un SSID du site") }
        if wired > 0 { parts.append("\(wired) branchée\(wired > 1 ? "s" : "") sur le réseau filaire") }
        let title = "\(found.count) borne\(found.count > 1 ? "s" : "") pirate\(found.count > 1 ? "s" : "")"
            + (parts.isEmpty ? "" : "\u{00A0}: " + parts.joined(separator: ", "))
        let places = found.compactMap { f in f.wiredPlace.map { "\(f.displaySSID) sur \($0)" } }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let detail = places.isEmpty
            ? "Un sosie imite le réseau du site pour capter les identifiants des clients\u{00A0}; localisez-le par le signal et retirez-le."
            : "Localisée\u{00A0}: " + places.joined(separator: "\u{00A0}; ") + ". Désactivez le port ou retirez la borne."
        return AnyView(HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.critical)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.criticalSoft)))
    }

    private func tableView(_ rows: [FortiAPPirateRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("SSID"), sortUsing: table.sort("ssid")) { row in
                Text(row.finding.displaySSID)
                    .font(row.finding.ssid == nil ? Theme.small.italic() : .system(size: 12, weight: .semibold))
                    .foregroundStyle(row.finding.ssid == nil ? Theme.textSecondary : Theme.text).lineLimit(1)
            }
            .width(min: 100, ideal: 140)
            .customizationID("ssid")
            .disabledCustomizationBehavior(.visibility)
            TableColumn(StandardTableHeading("CLASSE"), sortUsing: table.sort("classe")) { row in classPill(row.finding) }
                .width(min: 70, ideal: 90)
                .customizationID("classe")
            TableColumn(StandardTableHeading("RAISON"), sortUsing: table.sort("raison")) { row in
                WifiCell(row.reason + (row.finding.wiredPlace.map { " · \($0)" } ?? ""))
                    .help(row.reason + (row.finding.wiredPlace.map { " (\($0))" } ?? ""))
            }
            .width(min: 120, ideal: 220)
            .customizationID("raison")
            TableColumn(StandardTableHeading("BSSID"), sortUsing: table.sort("bssid")) { row in
                WifiCell(row.finding.bssid?.formatted(.upperColon) ?? "—", mono: 11, dimmed: row.finding.bssid == nil)
                    .help(row.finding.vendor ?? "Fabricant inconnu")
            }
            .width(min: 110, ideal: 122)
            .customizationID("bssid")
            TableColumn(StandardTableHeading("CANAL"), sortUsing: table.sort("canal")) { row in
                WifiCell(row.finding.channel.map(String.init) ?? "—", mono: 12, dimmed: row.finding.channel == nil)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 48)
            .customizationID("canal")
            TableColumn(StandardTableHeading("SIGNAL"), sortUsing: table.sort("signal")) { row in
                HStack(spacing: 6) {
                    if let rssi = row.finding.rssi {
                        WifiSignalBar(rssi: rssi, width: 28)
                        Text(WifiQuality.dbm(rssi)).font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(WifiText.qualityColor(rssi).foreground).lineLimit(1)
                    } else {
                        WifiCell("—", dimmed: true)
                    }
                }
                .frame(height: 20)
            }
            .width(min: 80, ideal: 92)
            .customizationID("signal")
            TableColumn(StandardTableHeading("VU PAR"), sortUsing: table.sort("source")) { row in
                WifiCell(row.source).help(row.finding.seenBy.joined(separator: ", "))
            }
            .width(min: 60, ideal: 100)
            .customizationID("source")
            TableColumn(StandardTableHeading("ACTION")) { row in actionButton(row.finding) }
                .width(min: 80, ideal: 110)
                .customizationID("action")
                .disabledCustomizationBehavior(.visibility)
        }
        .standardTableStyle()
        .confirmationDialog("Accepter ce sosie\u{00A0}?", isPresented: Binding(get: { pendingTwin != nil }, set: { if !$0 { pendingTwin = nil } }),
                            presenting: pendingTwin) { twin in
            Button("Accepter le sosie") { pirates.setAccepted(twin, true) }
            Button("Annuler", role: .cancel) {}
        } message: { twin in
            Text("«\u{00A0}\(twin.displaySSID)\u{00A0}» (\(twin.bssid?.formatted(.upperColon) ?? "sans BSSID")) diffuse un SSID du site. "
                 + "Acceptez-le seulement si vous savez d’où il vient (SSID générique d’un voisin, borne d’un autre site de l’entreprise)\u{00A0}: "
                 + "un vrai sosie sert à capter les identifiants des clients.")
        }
    }

    @ViewBuilder private func actionButton(_ f: RogueAPFinding) -> some View {
        if f.classification == .connue {
            WifiCell("—", dimmed: true)
        } else if pirates.isAccepted(f) {
            Button("Retirer") { pirates.setAccepted(f, false) }
                .buttonStyle(.link).font(Theme.small)
                .help("Ne plus traiter cette borne comme une voisine acceptée")
        } else if f.reasons.contains(.sosie) {
            if f.bssid == nil {
                WifiCell("—", dimmed: true).help("Un sosie sans BSSID ne peut pas être accepté")
            } else {
                Button("Accepter…") { pendingTwin = f }
                    .buttonStyle(.link).font(Theme.small)
                    .help("Accepter ce sosie pour ce site et ce BSSID seulement, après confirmation")
            }
        } else {
            Button("Accepter") { pirates.setAccepted(f, true) }
                .buttonStyle(.link).font(Theme.small)
                .help("Marquer comme voisine acceptée (site et BSSID)")
        }
    }

    private func classPill(_ f: RogueAPFinding) -> WifiPill {
        switch f.classification {
        case .pirate: return WifiPill(text: "Pirate", foreground: Theme.critical, background: Theme.criticalSoft)
        case .connue: return WifiPill(text: "Connue", foreground: Theme.success, background: Theme.successSoft)
        case .voisine:
            return f.reasons.contains(.acceptee) || f.reasons.contains(.sosieAcceptee)
                ? WifiPill(text: "Acceptée", foreground: Theme.accentStrong, background: Theme.neutralSoft)
                : WifiPill(text: "Voisine")
        }
    }
}
