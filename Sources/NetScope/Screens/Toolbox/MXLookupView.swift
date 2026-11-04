import NetScopeCore
import SwiftUI

@MainActor
final class ToolMXModel: ObservableObject {
    @Published var domain = ""
    @Published private(set) var isRunning = false
    @Published private(set) var report: MXReport?
    @Published var error: String?
    private var generation = 0

    var command: String { "dig +short MX \(MailTools.domain(from: domain) ?? "<domaine>")" }

    func run(store: ToolStore?) {
        guard let name = MailTools.domain(from: domain) else {
            error = "Saisir un domaine (exemple.ca) ou une adresse courriel."
            return
        }
        domain = name
        error = nil
        isRunning = true
        generation += 1
        let run = generation
        store?.record(command: command)
        Task {
            let report = await MXLookup.run(name, client: MailTools.client)
            guard run == self.generation else { return }
            self.report = report
            self.isRunning = false
            store?.record(ToolRecent(tool: .mx, target: name, summary: report.summary,
                                     status: report.status == .error ? .failure : (report.status == .warning ? .warning : .ok)))
        }
    }

    func show(_ report: MXReport) {
        generation += 1
        isRunning = false
        error = nil
        self.report = report
    }

    func startDemo() {
        domain = MailDemo.domain
        run(store: nil)
    }
}

/// Recherche MX : serveurs par priorité, adresses, DNS inverse et cohérence.
struct MXLookupView: View {
    @ObservedObject var model: ToolMXModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = MXTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                ToolLabeledField(label: "Domaine") {
                    ToolTextField(placeholder: "exemple.ca ou nom@exemple.ca", text: $model.domain) { model.run(store: store) }
                        .frame(minWidth: 180)
                }
                Button(model.isRunning ? "Recherche…" : "Rechercher") { model.run(store: store) }
                    .buttonStyle(.primary)
                    .disabled(model.isRunning)
                    .fixedSize()
            }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            if model.isRunning {
                MailProgressLine(text: "Serveurs MX, adresses et DNS inverse…")
            } else if let report = model.report {
                HStack(spacing: 8) {
                    MailStatusChip(status: report.status)
                    Text(report.summary).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 8)
                    ToolColumnsMenu(model: table)
                }
                MXTable(rows: MXRow.rows(report), table: table)
                let findings = (report.findings + report.hosts.flatMap(\.findings)).filter { $0.status != .ok }.bySeverity
                if !findings.isEmpty {
                    ToolFieldLabel("Constats")
                    MailFindingList(findings: findings)
                }
                Text("Cohérence\u{00A0}: le nom du PTR doit revenir à la même adresse (DNS inverse confirmé). Chez les grands hébergeurs (Microsoft 365, Google…), le PTR porte un autre nom que le MX\u{00A0}: c’est normal.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.error == nil {
                Text("Liste les serveurs qui reçoivent le courriel du domaine, du plus prioritaire au moins prioritaire, avec leurs adresses et leur DNS inverse.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Tableau

/// Une ligne par adresse d'un MX (une ligne « — » si le nom ne résout pas).
struct MXRow: Identifiable {
    let id: Int
    let priority: Int
    let host: String
    let ip: String
    let ipv6: String
    let ptr: String
    let coherence: String
    let status: MailStatus

    var sortHost: String { host }
    var sortIP: IPv4Address { IPv4Address(ip) ?? IPv4Address(0) }
    var sortPTR: String { ptr }
    var sortStatus: Int { [MailStatus.error, .warning, .info, .ok].firstIndex(of: status) ?? 4 }

    static func rows(_ report: MXReport) -> [MXRow] {
        var rows: [MXRow] = []
        for host in report.hosts {
            let v6 = host.ipv6.joined(separator: ", ")
            if host.addresses.isEmpty {
                rows.append(MXRow(id: rows.count, priority: host.priority, host: host.host, ip: "—", ipv6: v6.isEmpty ? "—" : v6,
                                  ptr: "—", coherence: host.unresolved ? "Ne résout pas" : "IPv6 seulement",
                                  status: host.unresolved ? .error : .info))
            }
            for address in host.addresses {
                let coherence: String
                if address.lookupFailed { coherence = "Non vérifié" }
                else if address.ptr == nil { coherence = "Aucun PTR" }
                else if !address.forwardConfirmed { coherence = "Incohérent" }
                else { coherence = address.matchesHost ? "Identique au MX" : "Confirmé" }
                rows.append(MXRow(id: rows.count, priority: host.priority, host: host.host, ip: address.ip, ipv6: v6.isEmpty ? "—" : v6,
                                  ptr: address.ptr ?? "—", coherence: coherence, status: address.ptrStatus))
            }
        }
        for ip in report.implicitA {
            rows.append(MXRow(id: rows.count, priority: 0, host: report.domain + " (A implicite)", ip: ip, ipv6: "—", ptr: "—",
                              coherence: "Sans MX", status: .warning))
        }
        return rows
    }
}

/// Serveurs MX (tableau standard « outils.courriel.mx ») : priorité, serveur, adresse, PTR,
/// cohérence ; facultatives : IPv6.
struct MXTable: View {
    let rows: [MXRow]
    @ObservedObject var table: StandardTableModel<MXRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "priorite", title: "Priorité"),
        StandardColumn(id: "serveur", title: "Serveur MX", isRequired: true),
        StandardColumn(id: "adresse", title: "Adresse IPv4"),
        StandardColumn(id: "ptr", title: "DNS inverse (PTR)"),
        StandardColumn(id: "coherence", title: "Cohérence"),
        StandardColumn(id: "ipv6", title: "Adresses IPv6", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<MXRow>] = [
        "priorite": KeyPathComparator(\MXRow.priority),
        "serveur": KeyPathComparator(\MXRow.sortHost),
        "adresse": KeyPathComparator(\MXRow.sortIP),
        "ptr": KeyPathComparator(\MXRow.sortPTR),
        "coherence": KeyPathComparator(\MXRow.sortStatus),
        "ipv6": KeyPathComparator(\MXRow.ipv6),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<MXRow> {
        StandardTableModel(id: "outils.courriel.mx", columns: columns, sortKeys: sortKeys, defaultSort: "priorite")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, emptyText: "Aucun serveur MX.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("PRIORITÉ", sortUsing: table.sort("priorite")) { row in
                    ToolTableText("\(row.priority)", weight: .semibold, alignment: .trailing)
                }
                .width(min: 60, ideal: 64)
                .customizationID("priorite")

                TableColumn("SERVEUR MX", sortUsing: table.sort("serveur")) { row in
                    ToolTableText(row.host, weight: .medium).help(row.host)
                }
                .width(min: 100, ideal: 120)
                .customizationID("serveur")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("ADRESSE IPV4", sortUsing: table.sort("adresse")) { row in
                    ToolTableText(row.ip)
                }
                .width(min: 86, ideal: 92)
                .customizationID("adresse")

                TableColumn("DNS INVERSE (PTR)", sortUsing: table.sort("ptr")) { row in
                    ToolTableText(row.ptr, color: Theme.textSecondary).help(row.ptr)
                }
                .width(min: 70, ideal: 84)
                .customizationID("ptr")

                TableColumn("COHÉRENCE", sortUsing: table.sort("coherence")) { row in
                    MailStatusChip(status: row.status, text: row.coherence)
                }
                .width(min: 70, ideal: 80)
                .customizationID("coherence")

                TableColumn("ADRESSES IPV6", sortUsing: table.sort("ipv6")) { row in
                    ToolTableText(row.ipv6, color: Theme.textSecondary).help(row.ipv6)
                }
                .width(min: 100, ideal: 200)
                .customizationID("ipv6")
                .defaultVisibility(.hidden)
            }
        }
    }
}
