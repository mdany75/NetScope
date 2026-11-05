import NetScopeCore
import SwiftUI

// Note 78 (Historique et adressage) : « Prochaine IP libre hors étendue DHCP », par sous-réseau du
// site (plages du Scanner, étendues DHCP de la FortiGate, /24 de l'inventaire). Tableau standard ;
// double-clic ou ↩︎ : la carte d'occupation montre ce sous-réseau.

/// Une ligne : un sous-réseau et ses adresses libres pour une IP fixe.
struct AnaNextFreeRow: Identifiable {
    let item: AddressPlanSubnet
    let next: IPv4Address?
    let following: [IPv4Address]
    let free: Int
    let used: Int
    let hosts: Int
    let dhcpPool: Int

    var id: String { item.id }
    var subnet: Subnet { item.subnet }
    var sortSubnet: UInt64 { UInt64(subnet.network.value) << 6 | UInt64(subnet.prefix) }
    var sortLabel: String { item.label.isEmpty ? "\u{10FFFF}" : item.label }
    var sortDHCP: String { item.dhcpName ?? "\u{10FFFF}" }
    var sortNext: UInt32 { next?.value ?? .max }
    var sortFree: Int { free }
    var usage: Double { hosts == 0 ? 0 : Double(used) / Double(hosts) }
    var sortUsage: Double { usage }

    /// Calcul d'un sous-réseau (un /25 ou plus petit se lit dans son /24).
    @MainActor
    static func make(_ item: AddressPlanSubnet, records: [InvRecord], dhcp: AddressPlanDHCP, exclusions: AddressExclusions,
                     subnets: [Subnet], now: Date, recentWindow: TimeInterval) -> AnaNextFreeRow {
        let plan = AddressPlan(block: item.subnet, records: records, dhcp: dhcp, exclusions: exclusions, subnets: subnets,
                               now: now, recentWindow: recentWindow)
        let free = plan.freeAddresses(in: item.subnet)
        var used = plan.used
        var hosts = plan.hosts
        if item.subnet.prefix > 24 {
            // Sous-réseau plus petit qu'une page : ses seules adresses.
            let states = (item.subnet.network.value...item.subnet.broadcast.value).map { plan.cell(IPv4Address($0)).state }
            used = states.filter(\.isUsed).count
            hosts = states.filter { $0 != .reseau }.count
        }
        return AnaNextFreeRow(item: item, next: free.first, following: Array(free.dropFirst().prefix(3)), free: free.count,
                              used: used, hosts: hosts, dhcpPool: item.dhcpRanges.reduce(0) { $0 + $1.count })
    }
}

struct AnaNextFreePanel: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var table = StandardTableModel<AnaNextFreeRow>(id: "analyse.ipLibres", columns: AnaNextFreePanel.columns,
                                                                       sortKeys: AnaNextFreePanel.sortKeys, defaultSort: "sousReseau")
    @State private var selection = Set<String>()

    let rows: [AnaNextFreeRow]
    var siteName: String?
    /// Lecture DHCP de la FortiGate du site (nil : aucune étendue lue).
    var dhcpReadAt: Date?
    var canReadDHCP: Bool
    var onReadDHCP: () -> Void
    /// Montre ce sous-réseau dans la carte d'occupation.
    var onShow: (Subnet) -> Void

    static let columns: [StandardColumn] = [
        StandardColumn(id: "sousReseau", title: "Sous-réseau", isRequired: true),
        StandardColumn(id: "plage", title: "Plage / VLAN"),
        StandardColumn(id: "dhcp", title: "Étendue DHCP"),
        StandardColumn(id: "prochaine", title: "Prochaine IP libre", isRequired: true),
        StandardColumn(id: "libres", title: "Libres hors DHCP"),
        StandardColumn(id: "occupation", title: "Occupation"),
        StandardColumn(id: "suivantes", title: "Suivantes", isDefaultVisible: false),
    ]
    static let sortKeys: [String: KeyPathComparator<AnaNextFreeRow>] = [
        "sousReseau": KeyPathComparator(\AnaNextFreeRow.sortSubnet),
        "plage": KeyPathComparator(\AnaNextFreeRow.sortLabel),
        "dhcp": KeyPathComparator(\AnaNextFreeRow.sortDHCP),
        "prochaine": KeyPathComparator(\AnaNextFreeRow.sortNext),
        "libres": KeyPathComparator(\AnaNextFreeRow.sortFree),
        "occupation": KeyPathComparator(\AnaNextFreeRow.sortUsage),
        "suivantes": KeyPathComparator(\AnaNextFreeRow.sortNext),
    ]
    private static let rowHeight: CGFloat = 38
    /// Largeurs idéales des colonnes (défilement horizontal en petite fenêtre).
    private static let widths: [String: CGFloat] = ["sousReseau": 150, "plage": 170, "dhcp": 200, "prochaine": 190,
                                                    "libres": 110, "occupation": 170, "suivantes": 260]
    private static let maxVisibleRows = 8

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Prochaine IP libre hors étendue DHCP").font(.system(size: 14, weight: .semibold)).fixedSize()
                    ViewThatFits(in: .horizontal) {
                        Text(subtitle).fixedSize()
                        Text(shortSubtitle).fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .help(subtitle)
                    Spacer(minLength: 8)
                    if dhcpReadAt == nil, canReadDHCP {
                        Button { onReadDHCP() } label: { Label("Lire le DHCP de la FortiGate", systemImage: "arrow.clockwise") }
                            .buttonStyle(.secondary)
                    }
                    StandardColumnsMenu(model: table)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Rectangle().fill(Theme.border).frame(height: 1)
                if sorted.isEmpty {
                    Text("Aucun sous-réseau connu pour ce site\u{00A0}: ajoutez une plage dans Réglages › Sites et plages, ou lancez un scan.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                } else {
                    // Petite fenêtre : le tableau défile à gauche et à droite plutôt que de couper ses colonnes.
                    StandardTableHorizontalScroll(
                        minWidth: table.contentWidth(Self.widths),
                        height: AnaTableMetrics.height(rows: sorted.count, rowHeight: Self.rowHeight, maxRows: Self.maxVisibleRows)) {
                        tableView(sorted)
                            .scrollIndicators(sorted.count > Self.maxVisibleRows ? .automatic : .never, axes: .vertical)
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let source = dhcpReadAt.map { "fiches du scan, étendues, baux et réservations DHCP lus \(InvFormat.timeOrStamp($0).lowercased()), plages exclues" }
            ?? "fiches du scan et plages exclues (aucune étendue DHCP lue sur une FortiGate)"
        return (siteName.map { $0 + " · " } ?? "") + source + " · jamais .0 ni .255"
    }

    private var shortSubtitle: String {
        (siteName.map { $0 + " · " } ?? "") + (dhcpReadAt == nil ? "sans DHCP lu" : "avec le DHCP de la FortiGate")
    }

    private func tableView(_ rows: [AnaNextFreeRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn("SOUS-RÉSEAU", sortUsing: table.sort("sousReseau")) { (row: AnaNextFreeRow) in
                    ScanCellText(row.subnet.description, mono: true)
                }
                .width(min: 120, ideal: 150)
                .customizationID("sousReseau").disabledCustomizationBehavior(.visibility)
                TableColumn("PLAGE / VLAN", sortUsing: table.sort("plage")) { (row: AnaNextFreeRow) in
                    ScanCellText(row.item.label.isEmpty ? "—" : row.item.label, secondary: row.item.label.isEmpty)
                }
                .width(min: 100, ideal: 170)
                .customizationID("plage")
                TableColumn("ÉTENDUE DHCP", sortUsing: table.sort("dhcp")) { (row: AnaNextFreeRow) in
                    dhcpCell(row)
                }
                .width(min: 120, ideal: 200)
                .customizationID("dhcp")
                TableColumn("PROCHAINE IP LIBRE", sortUsing: table.sort("prochaine")) { (row: AnaNextFreeRow) in
                    nextCell(row)
                }
                .width(min: 150, ideal: 190)
                .customizationID("prochaine").disabledCustomizationBehavior(.visibility)
            }
            Group {
                TableColumn("LIBRES HORS DHCP", sortUsing: table.sort("libres")) { (row: AnaNextFreeRow) in
                    ScanCellText(RegFormat.count(row.free), mono: true)
                }
                .width(min: 80, ideal: 110)
                .customizationID("libres")
                TableColumn("OCCUPATION", sortUsing: table.sort("occupation")) { (row: AnaNextFreeRow) in
                    usageCell(row)
                }
                .width(min: 130, ideal: 170)
                .customizationID("occupation")
                TableColumn("SUIVANTES", sortUsing: table.sort("suivantes")) { (row: AnaNextFreeRow) in
                    ScanCellText(Self.following(row), mono: true, secondary: true)
                }
                .width(min: 120, ideal: 260)
                .customizationID("suivantes").defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        // Double-clic ou ↩︎ : le sous-réseau dans la carte ; clic droit : copier, vérifier par ping.
        .standardRowActions(selection: rows.map(\.id).filter(selection.contains), object: { id in
            rows.first { $0.id == id }.map { .range(text: $0.subnet.description, label: $0.item.labels.first) }
        }, primary: { ids in
            guard let row = rows.first(where: { ids.contains($0.id) }) else { return false }
            onShow(row.subnet)
            return true
        }) { ids in
            rowMenu(rows.first { ids.contains($0.id) })
        }
    }

    private static func following(_ row: AnaNextFreeRow) -> String {
        row.following.isEmpty ? "—" : row.following.map(\.description).joined(separator: ", ")
    }

    @ViewBuilder
    private func rowMenu(_ row: AnaNextFreeRow?) -> some View {
        if let row {
            Button("Afficher dans la carte d’occupation") { onShow(row.subnet) }
            if let next = row.next {
                Button("Copier " + next.description) { AnaTableMetrics.copy(next.description, label: "Adresse") }
                Button("Vérifier " + next.description + " par ping continu") { state.sendToPing(next.description) }
            }
        }
    }

    @ViewBuilder
    private func dhcpCell(_ row: AnaNextFreeRow) -> some View {
        if let name = row.item.dhcpName {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.small).lineLimit(1)
                Text(row.item.dhcpRangesLabel).font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .help(name + "\u{00A0}: " + row.item.dhcpRangesLabel + " (\(row.dhcpPool) adresses distribuées)")
        } else {
            ScanCellText(dhcpReadAt == nil ? "Non lue" : "Aucune", secondary: true)
        }
    }

    @ViewBuilder
    private func nextCell(_ row: AnaNextFreeRow) -> some View {
        if let next = row.next {
            HStack(spacing: 6) {
                Text(next.description).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.success).lineLimit(1)
                Button("Copier") { AnaTableMetrics.copy(next.description, label: "Adresse") }.buttonStyle(.bordered).controlSize(.small)
            }
        } else {
            ScanCellText("Aucune", secondary: true)
        }
    }

    private func usageCell(_ row: AnaNextFreeRow) -> some View {
        let percent = Int((row.usage * 100).rounded())
        return HStack(spacing: 6) {
            ProgressBar(fraction: row.usage, color: percent >= 75 ? Theme.warning : Theme.accent).frame(width: 60)
            Text("\(percent)\u{00A0}% · \(row.used)/\(row.hosts)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }
}

