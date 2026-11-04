import NetScopeCore
import SwiftUI

@MainActor
final class ToolBlacklistModel: ObservableObject {
    @Published var target = ""
    /// Domaine : chercher aussi les adresses de ses serveurs MX dans les listes d'adresses.
    @Published var includeMX = true
    @Published private(set) var isRunning = false
    @Published private(set) var report: DNSBLReport?
    @Published private(set) var duration: TimeInterval = 0
    @Published var error: String?
    private var generation = 0

    var command: String {
        let (kind, value) = MailInput.classify(target)
        if kind == .ip, let ip = IPv4Address(value) { return "dig +short \(DNSBL.reversed(ip)).zen.spamhaus.org" }
        if let domain = MailTools.domain(from: target) { return "dig +short \(domain).dbl.spamhaus.org" }
        return "dig +short <ip inversée>.zen.spamhaus.org"
    }

    func run(store: ToolStore?) {
        let (kind, value) = MailInput.classify(target)
        let client = MailTools.client
        var targets: [DNSBLTarget] = []
        switch kind {
        case .ip:
            guard let ip = IPv4Address(value) else { return }
            if MailDNSText.isReserved(ip) {
                error = "\(ip) est une adresse privée ou réservée\u{00A0}: elle n’apparaît dans aucune liste publique."
                return
            }
            targets = [.ip(ip)]
        case .email, .domain, .hostname:
            guard let domain = MailTools.domain(from: target) else { return }
            targets = [.domain(MailDNSText.organizationalDomain(domain))]
        case .invalid:
            error = "Saisir une adresse IPv4 (203.0.113.25) ou un domaine (exemple.ca)."
            return
        }
        target = kind == .email ? MailInput.domain(ofEmail: value) : value
        error = nil
        isRunning = true
        generation += 1
        let run = generation
        let withMX = includeMX && kind != .ip
        let domain = target
        store?.record(command: command)
        let start = Date()
        Task {
            var all = targets
            if withMX { all += await Self.mxAddresses(domain, client: client).map(DNSBLTarget.ip) }
            let report = await DNSBL.check(all, client: client)
            guard run == self.generation else { return }
            self.report = report
            self.duration = Date().timeIntervalSince(start)
            self.isRunning = false
            let status: ToolRecent.Status = report.status == .error ? .failure : (report.status == .warning ? .warning : .ok)
            store?.record(ToolRecent(tool: .blacklist, target: domain, summary: report.summary, status: status))
        }
    }

    /// Adresses IPv4 des deux premiers MX (deux par serveur, quatre au plus).
    static func mxAddresses(_ domain: String, client: MailDNSClient) async -> [IPv4Address] {
        let mx = await client.query(domain, .mx)
        let hosts = mx.values.compactMap(MailDNSText.parseMX).sorted { $0.priority < $1.priority }.prefix(2)
        var result: [IPv4Address] = []
        for host in hosts {
            let a = await client.query(host.host, .a)
            for ip in a.values.prefix(2).compactMap(IPv4Address.init) where !result.contains(ip) && !MailDNSText.isReserved(ip) {
                result.append(ip)
            }
        }
        return Array(result.prefix(4))
    }

    func show(_ report: DNSBLReport) {
        generation += 1
        isRunning = false
        error = nil
        duration = 0
        self.report = report
    }

    func startDemo() {
        target = MailDemo.blacklistIP
        run(store: nil)
    }
}

/// Listes noires DNSBL/RBL : une IP ou un domaine dans les principales listes.
struct BlacklistView: View {
    @ObservedObject var model: ToolBlacklistModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = BlacklistTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolAdaptiveRow {
                ToolLabeledField(label: "Adresse IPv4 ou domaine") {
                    ToolTextField(placeholder: "203.0.113.25 ou exemple.ca", text: $model.target) { model.run(store: store) }
                        .frame(minWidth: 180)
                }
                HStack(alignment: .center, spacing: 12) {
                    ToolCheckbox(label: "Adresses des MX (domaine)", isOn: $model.includeMX)
                        .fixedSize()
                    Button(model.isRunning ? "Vérification…" : "Vérifier") { model.run(store: store) }
                        .buttonStyle(.primary)
                        .disabled(model.isRunning)
                        .fixedSize()
                }
            }
            if let error = model.error {
                ToolNotice(tone: .warning, message: error)
            }
            if model.isRunning {
                MailProgressLine(text: "Interrogation des listes, trois requêtes à la fois…")
            } else if let report = model.report {
                tiles(report)
                HStack {
                    ToolFieldLabel("Résultats par liste")
                    Spacer()
                    ToolColumnsMenu(model: table)
                }
                BlacklistTable(rows: BlacklistRow.rows(report), table: table)
                let findings = report.findings.filter { $0.status != .ok }
                if !findings.isEmpty {
                    MailFindingList(findings: findings)
                }
                Text(footnote)
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.error == nil {
                Text("\(DNSBLCatalog.lists(for: .ip).count) listes d’adresses et \(DNSBLCatalog.lists(for: .domain).count) listes de domaines (Spamhaus, Barracuda, SpamCop, UCEPROTECT, PSBL, Mailspike, SURBL, URIBL…). Les requêtes passent par le résolveur DNS de ce Mac, trois à la fois et espacées, pour ne pas être bloqué.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footnote: String {
        let closed = DNSBLCatalog.all.filter { !$0.isActive }.map { "\($0.name) (\($0.note ?? "fermée"))" }
        return "Une inscription dans une liste «\u{00A0}mineure\u{00A0}» (blocs ou réseaux entiers) bloque rarement des messages. Spamhaus et URIBL refusent les résolveurs publics (8.8.8.8, 1.1.1.1)\u{00A0}: le résultat est alors «\u{00A0}Refusé\u{00A0}»."
            + (closed.isEmpty ? "" : " Non interrogée\u{00A0}: " + closed.joined(separator: ", ") + ".")
    }

    private func tiles(_ report: DNSBLReport) -> some View {
        let listed = report.listed.count
        let major = report.majorListings.count
        let undetermined = report.undetermined
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 8) {
            ToolStatTile(label: "Inscriptions", value: "\(listed)",
                         detail: major > 0 ? "\(major) liste\(major > 1 ? "s" : "") majeure\(major > 1 ? "s" : "")" : (listed > 0 ? "mineures seulement" : "aucune"),
                         valueColor: major > 0 ? Theme.critical : (listed > 0 ? Theme.warning : Theme.success))
            ToolStatTile(label: "Réponses obtenues", value: "\(report.checkedCount)",
                         detail: undetermined > 0 ? "\(undetermined) indéterminée\(undetermined > 1 ? "s" : "")" : "toutes les listes")
            ToolStatTile(label: "Cibles", value: "\(report.targets.count)",
                         detail: report.targets.prefix(2).joined(separator: ", ") + (report.targets.count > 2 ? "…" : ""))
            ToolStatTile(label: "Durée", value: model.duration > 0 ? ToolFormat.seconds(model.duration) : "—", detail: "3 requêtes à la fois")
        }
    }
}

// MARK: - Tableau

struct BlacklistRow: Identifiable {
    let id: Int
    let result: DNSBLResult

    var sortStatus: Int { [MailStatus.error, .warning, .info, .ok].firstIndex(of: result.status) ?? 4 }
    var sortName: String { result.list.name.lowercased() }
    var sortWeight: String { result.list.weight.rawValue }
    var sortTarget: String { result.target }
    var sortAnswer: String { answer }
    var sortExplanation: String { result.explanation }
    var sortDuration: Double { result.durationMs }

    var answer: String {
        switch result.state {
        case .listed(let codes): return codes.joined(separator: ", ")
        case .clean: return "NXDOMAIN"
        case .refused: return "refus"
        case .failed: return "—"
        case .skipped: return "—"
        }
    }

    static func rows(_ report: DNSBLReport) -> [BlacklistRow] {
        report.results.enumerated().map { BlacklistRow(id: $0.offset, result: $0.element) }
    }
}

/// Résultats par liste (tableau standard « outils.courriel.listes ») : état, liste, réponse,
/// explication, retrait ; facultatives : portée, cible, zone, nom interrogé, durée.
struct BlacklistTable: View {
    let rows: [BlacklistRow]
    @ObservedObject var table: StandardTableModel<BlacklistRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "etat", title: "État", isRequired: true),
        StandardColumn(id: "liste", title: "Liste", isRequired: true),
        StandardColumn(id: "portee", title: "Portée", isDefaultVisible: false),
        StandardColumn(id: "cible", title: "Cible", isDefaultVisible: false),
        StandardColumn(id: "reponse", title: "Réponse"),
        StandardColumn(id: "explication", title: "Explication"),
        StandardColumn(id: "retrait", title: "Retrait"),
        StandardColumn(id: "zone", title: "Zone DNS", isDefaultVisible: false),
        StandardColumn(id: "nom", title: "Nom interrogé", isDefaultVisible: false),
        StandardColumn(id: "duree", title: "Durée", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<BlacklistRow>] = [
        "etat": KeyPathComparator(\BlacklistRow.sortStatus),
        "liste": KeyPathComparator(\BlacklistRow.sortName),
        "portee": KeyPathComparator(\BlacklistRow.sortWeight),
        "cible": KeyPathComparator(\BlacklistRow.sortTarget),
        "reponse": KeyPathComparator(\BlacklistRow.sortAnswer),
        "explication": KeyPathComparator(\BlacklistRow.sortExplanation),
        "retrait": KeyPathComparator(\BlacklistRow.sortName),
        "zone": KeyPathComparator(\BlacklistRow.sortName),
        "nom": KeyPathComparator(\BlacklistRow.sortTarget),
        "duree": KeyPathComparator(\BlacklistRow.sortDuration),
    ]

    /// Tri par défaut : les inscriptions d'abord.
    @MainActor
    static func makeModel() -> StandardTableModel<BlacklistRow> {
        StandardTableModel(id: "outils.courriel.listes", columns: columns, sortKeys: sortKeys, defaultSort: "etat")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 24, emptyText: "Aucune liste interrogée.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                Group {
                    TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                        MailStatusChip(status: row.result.status, text: label(row.result))
                    }
                    .width(min: 70, ideal: 74)
                    .customizationID("etat")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("LISTE", sortUsing: table.sort("liste")) { row in
                        ToolTableText(row.result.list.name, mono: false, weight: .medium).help(row.result.list.note ?? row.result.list.name)
                    }
                    .width(min: 90, ideal: 104)
                    .customizationID("liste")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("PORTÉE", sortUsing: table.sort("portee")) { row in
                        ToolTableText(row.result.list.weight.label, mono: false, color: Theme.textSecondary)
                    }
                    .width(min: 56, ideal: 70)
                    .customizationID("portee")
                    .defaultVisibility(.hidden)

                    TableColumn("CIBLE", sortUsing: table.sort("cible")) { row in
                        ToolTableText(row.result.target).help(row.result.target)
                    }
                    .width(min: 90, ideal: 110)
                    .customizationID("cible")
                    .defaultVisibility(.hidden)

                    TableColumn("RÉPONSE", sortUsing: table.sort("reponse")) { row in
                        ToolTableText(row.answer, color: row.result.isListed ? Theme.critical : Theme.textSecondary)
                    }
                    .width(min: 70, ideal: 78)
                    .customizationID("reponse")
                }
                Group {
                    TableColumn("EXPLICATION", sortUsing: table.sort("explication")) { row in
                        ToolTableText(row.result.explanation, mono: false, color: Theme.textSecondary).help(row.result.explanation)
                    }
                    .width(min: 90, ideal: 100)
                    .customizationID("explication")

                    TableColumn("RETRAIT", sortUsing: table.sort("retrait")) { row in
                        if let url = row.result.list.removalURL {
                            Button(row.result.isListed ? "Retrait" : "Vérifier") { ToolActions.open(url) }
                                .buttonStyle(.ghost)
                                .controlSize(.small)
                                .frame(height: ToolTableMetrics.cellHeight)
                                .help(url)
                        } else {
                            ToolTableText("—", color: Theme.textSecondary)
                        }
                    }
                    .width(min: 70, ideal: 84)
                    .customizationID("retrait")

                    TableColumn("ZONE DNS", sortUsing: table.sort("zone")) { row in
                        ToolTableText(row.result.list.zone, color: Theme.textSecondary)
                    }
                    .width(min: 100, ideal: 170)
                    .customizationID("zone")
                    .defaultVisibility(.hidden)

                    TableColumn("NOM INTERROGÉ", sortUsing: table.sort("nom")) { row in
                        ToolTableText(row.result.queryName, color: Theme.textSecondary).help(row.result.queryName)
                    }
                    .width(min: 120, ideal: 240)
                    .customizationID("nom")
                    .defaultVisibility(.hidden)

                    TableColumn("DURÉE", sortUsing: table.sort("duree")) { row in
                        ToolTableText(ToolFormat.milliseconds(row.result.durationMs), color: Theme.textSecondary, alignment: .trailing)
                    }
                    .width(min: 50, ideal: 64)
                    .customizationID("duree")
                    .defaultVisibility(.hidden)
                }
            }
        }
    }

    private func label(_ result: DNSBLResult) -> String {
        switch result.state {
        case .clean: return "Absent"
        case .listed: return "Listé"
        case .refused: return "Refusé"
        case .failed: return "Indéterminé"
        case .skipped: return "Ignoré"
        }
    }
}
