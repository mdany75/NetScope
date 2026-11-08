import AppKit
import NetScopeCore
import SwiftUI

/// Analyse d'en-têtes de courriel : état conservé par la boîte à outils (ToolStore).
@MainActor
final class ToolHeaderModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var report: MailHeaderReport?

    init() {
        // Démonstration (--demo) : un hameçonnage fictif (DevTools/MailDNSDemo.swift).
        if Launcher.isDemo {
            text = MailDNSDemo.phishingHeaders
            report = MailHeaderAnalyzer.analyze(text, now: MailDNSDemo.now)
        }
    }

    func analyze(store: ToolStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            report = nil
            return
        }
        let report = MailHeaderAnalyzer.analyze(text)
        self.report = report
        let sender = report.from?.address ?? "expéditeur inconnu"
        let worst = report.findings.first { $0.level == report.verdict }?.title ?? "Rien d’anormal"
        store.record(ToolRecent(tool: .headers, target: sender, summary: "\(report.hops.count) sauts · \(worst)",
                                status: report.verdict.recentStatus))
    }

    func paste(store: ToolStore) {
        guard let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty else { return }
        text = pasted
        analyze(store: store)
    }

    func clear() {
        text = ""
        report = nil
    }
}

/// Analyse d'en-têtes collés : trajet, authentification lue dans le message, alertes
/// d'usurpation. Tout se fait sur ce Mac.
struct MailHeaderView: View {
    @ObservedObject var model: ToolHeaderModel
    @ObservedObject var store: ToolStore
    @StateObject private var hopsTable = MailHopTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                ToolFieldLabel("En-têtes bruts du message")
                TextEditor(text: $model.text)
                    .font(Theme.mono(11))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .padding(6)
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
                    .overlay(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text("Coller ici les en-têtes complets du message.\nMail\u{00A0}: Présentation › Message › Tous les en-têtes · Outlook\u{00A0}: Fichier › Propriétés › En-têtes Internet · Gmail\u{00A0}: ⋮ › Afficher l’original")
                                .font(Theme.small).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
            }
            HStack(spacing: 8) {
                Button("Analyser") { model.analyze(store: store) }
                    .buttonStyle(.primary)
                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Coller et analyser") { model.paste(store: store) }
                    .buttonStyle(.secondary)
                Button("Effacer") { model.clear() }
                    .buttonStyle(.secondary)
                    .disabled(model.text.isEmpty)
                Spacer(minLength: 8)
                // Fenêtre étroite : le cadenas seul, la phrase en infobulle.
                ViewThatFits(in: .horizontal) {
                    Label("Analyse locale, rien n’est envoyé", systemImage: "lock")
                        .lineLimit(1).fixedSize()
                    Image(systemName: "lock")
                }
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .help("Analyse locale, rien n’est envoyé")
            }
            if let report = model.report {
                result(report)
            }
        }
    }

    @ViewBuilder private func result(_ report: MailHeaderReport) -> some View {
        ToolNotice(tone: report.verdict.tone, title: verdictTitle(report), message: verdictMessage(report))
        authTiles(report)
        ToolCellGrid(cells: cells(report), columns: 3, valueSize: 13, minCellWidth: 180, truncatesLongValues: true)
        ToolSectionHeader("Alertes et vérifications")
        ToolFindingList(findings: report.findings)
        ToolSectionHeader(title: "Trajet du message") {
            if let transit = report.transit {
                Text("\(report.hops.count) sauts · \(MailHeaderAnalyzer.duration(transit)) au total")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            ToolColumnsMenu(model: hopsTable)
        }
        MailHopTable(rows: report.hops, table: hopsTable)
    }

    private func verdictTitle(_ report: MailHeaderReport) -> String {
        switch report.verdict {
        case .critical: return "Usurpation probable"
        case .warning: return "À vérifier avant de faire confiance"
        case .info, .ok: return "Rien d’anormal"
        }
    }

    private func verdictMessage(_ report: MailHeaderReport) -> String {
        let alerts = report.findings.filter { $0.level >= .warning }.map(\.title)
        if alerts.isEmpty { return "Expéditeur authentifié et trajet cohérent, d’après les en-têtes." }
        return alerts.prefix(4).joined(separator: " · ") + (alerts.count > 4 ? " · …" : "")
    }

    private func authTiles(_ report: MailHeaderReport) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(["spf", "dkim", "dmarc"], id: \.self) { method in
                let item = report.result(method)
                ToolStatTile(label: method.uppercased(), value: item?.result ?? "absent",
                             detail: item.map { $0.detail.isEmpty ? ($0.authority ?? "") : $0.detail } ?? "non vérifié par le destinataire",
                             valueColor: color(item))
            }
        }
    }

    private func color(_ item: MailAuthResult?) -> Color {
        guard let item else { return Theme.textSecondary }
        if item.isPass { return Theme.success }
        if item.isFail { return item.method == "dmarc" || item.result == "fail" ? Theme.critical : Theme.warning }
        return Theme.textSecondary
    }

    private func cells(_ report: MailHeaderReport) -> [ToolCell] {
        let envelopeDiffers = report.envelopeDomain.map {
            MailHeaderAnalyzer.organizationalDomain($0) != MailHeaderAnalyzer.organizationalDomain(report.from?.domain ?? "")
        } ?? false
        return [
            ToolCell(key: "De (From)", value: report.from?.address ?? "—", detail: report.from?.displayName),
            ToolCell(key: "Enveloppe (Return-Path)", value: report.returnPath.map { $0.isEmpty ? "<> (avis de non-remise)" : $0 } ?? "—",
                     detail: envelopeDiffers ? "domaine différent de From" : nil),
            ToolCell(key: "Répondre à (Reply-To)", value: report.replyTo?.address ?? "—", detail: report.replyTo?.displayName),
            ToolCell(key: "Objet", value: report.subject ?? "—"),
            ToolCell(key: "Date", value: report.date.map(Self.format) ?? report.dateText ?? "—"),
            ToolCell(key: "IP d’origine", value: report.originIP ?? "—", detail: report.hops.first?.from),
            ToolCell(key: "Message-ID", value: report.messageID ?? "—"),
            ToolCell(key: "Logiciel (X-Mailer)", value: report.mailer ?? "—"),
            ToolCell(key: "Signature DKIM", value: report.dkimSignatures.first.map { "\($0.domain)" + ($0.selector.isEmpty ? "" : " · \($0.selector)") } ?? "aucune"),
        ]
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Tableau des sauts

/// Sauts du message (tableau standard « outils.entetes.sauts »), du premier serveur au dernier.
struct MailHopTable: View {
    let rows: [MailHop]
    @ObservedObject var table: StandardTableModel<MailHop>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "numero", title: "N°", isRequired: true),
        StandardColumn(id: "heure", title: "Horodatage"),
        StandardColumn(id: "delai", title: "Délai"),
        StandardColumn(id: "de", title: "De"),
        StandardColumn(id: "ip", title: "IP"),
        StandardColumn(id: "par", title: "Par"),
        StandardColumn(id: "avec", title: "Avec"),
        StandardColumn(id: "brut", title: "En-tête brut", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<MailHop>] = [
        "numero": KeyPathComparator(\MailHop.id),
        "heure": KeyPathComparator(\MailHop.sortDate),
        "delai": KeyPathComparator(\MailHop.sortDelay),
        "de": KeyPathComparator(\MailHop.sortFrom),
        "ip": KeyPathComparator(\MailHop.sortIP),
        "par": KeyPathComparator(\MailHop.sortBy),
        "avec": KeyPathComparator(\MailHop.sortWith),
        "brut": KeyPathComparator(\MailHop.raw),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<MailHop> {
        StandardTableModel(id: "outils.entetes.sauts", columns: columns, sortKeys: sortKeys, defaultSort: "numero")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, emptyText: "Aucun en-tête Received.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("N°", sortUsing: table.sort("numero")) { hop in
                    ToolTableText("\(hop.id)", color: Theme.textSecondary, alignment: .trailing).help(hop.raw)
                }
                .width(min: 26, ideal: 32)
                .customizationID("numero")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("HORODATAGE", sortUsing: table.sort("heure")) { hop in
                    ToolTableText(hop.date.map(MailHeaderView.format) ?? (hop.dateText ?? "—")).help(hop.dateText ?? "")
                }
                .width(min: 120, ideal: 140)
                .customizationID("heure")

                TableColumn("DÉLAI", sortUsing: table.sort("delai")) { hop in
                    ToolTableText(hop.delay.map(MailHeaderAnalyzer.duration) ?? "—",
                                  weight: (hop.delay ?? 0) > 300 ? .semibold : .regular,
                                  color: (hop.delay ?? 0) > 300 || (hop.delay ?? 0) < -60 ? Theme.warning : Theme.textSecondary,
                                  alignment: .trailing)
                }
                .width(min: 50, ideal: 64)
                .customizationID("delai")

                TableColumn("DE", sortUsing: table.sort("de")) { hop in
                    ToolTableText(hop.from ?? "—").help(hop.from ?? "")
                }
                .width(min: 110, ideal: 190)
                .customizationID("de")

                TableColumn("IP", sortUsing: table.sort("ip")) { hop in
                    ToolTableText(hop.fromIP ?? "—", color: Theme.textSecondary)
                }
                .width(min: 80, ideal: 110)
                .customizationID("ip")

                TableColumn("PAR", sortUsing: table.sort("par")) { hop in
                    ToolTableText(hop.by ?? "—").help(hop.by ?? "")
                }
                .width(min: 110, ideal: 170)
                .customizationID("par")

                TableColumn("AVEC", sortUsing: table.sort("avec")) { hop in
                    HStack(spacing: 4) {
                        ToolTableText(hop.with ?? "—", color: Theme.textSecondary)
                        if hop.isEncrypted {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.success)
                                .help("Transport chiffré (TLS)")
                        }
                    }
                }
                .width(min: 60, ideal: 84)
                .customizationID("avec")

                TableColumn("EN-TÊTE BRUT", sortUsing: table.sort("brut")) { hop in
                    ToolTableText(hop.raw, size: 11, color: Theme.textSecondary).help(hop.raw)
                }
                .width(min: 120, ideal: 300)
                .customizationID("brut")
                .defaultVisibility(.hidden)
            }
        }
    }
}

extension MailHop {
    var sortDate: Date { date ?? .distantPast }
    var sortDelay: Double { delay ?? 0 }
    var sortFrom: String { from ?? "" }
    var sortIP: String { fromIP ?? "" }
    var sortBy: String { by ?? "" }
    var sortWith: String { with ?? "" }
}
