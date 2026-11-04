import NetScopeCore
import SwiftUI

/// Vue autonome « WAN et VPN » (note 39) : par site, liens WAN (état, débit, latence, gigue,
/// perte, SLA), sondes SD-WAN, tunnels IPsec montés ou tombés et VPN SSL ; plusieurs ou tous les
/// sites par le menu « Site ▾ ». Montrée par l'outil « WAN et VPN » de la Boîte à outils ; l'écran
/// « Trafic » (note 54) peut l'intégrer comme onglet en passant son propre écran à `scopeScreen`.
struct WANStatusView: View {
    /// Écran qui retient le choix des sites du menu « Site ▾ ».
    var scopeScreen: Screen = .outils

    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = WANStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @ObservedObject private var scopes = SiteScopeStore.shared
    @ObservedObject private var sites = SiteModel.shared
    /// Observé pour que « Ajouter au rapport » passe tout de suite à « Dans le rapport ».
    @ObservedObject private var rapport = RapportModel.shared
    @StateObject private var siteTable = WANSiteRow.makeModel()
    @StateObject private var linkTable = WANLinkRow.makeModel()
    @StateObject private var memberTable = WANMemberRow.makeModel()
    @StateObject private var tunnelTable = WANTunnelRow.makeModel()
    @State private var linkSelection: String?
    @State private var memberSelection: String?
    @State private var siteSelection: UUID?
    @State private var latencyText: String?
    @State private var jitterText: String?
    @State private var lossText: String?
    /// Petite fenêtre : tableaux à colonnes réduites.
    @State private var isCompact = false

    static let compactWidth: CGFloat = 640

    var body: some View {
        let ids = store.controllerIDs(forSiteKeys: scopes.keys(for: scopeScreen), state: state)
        let overview = store.overview(ids)
        VStack(alignment: .leading, spacing: 14) {
            controls(ids, overview: overview)
            ForEach(store.errorList(ids), id: \.site) { item in
                ToolNotice(tone: .critical, title: "\(item.site)\u{00A0}: lecture du WAN impossible", message: item.message)
            }
            ForEach(overview.notes, id: \.self) { note in
                ToolNotice(tone: .neutral, message: note)
            }
            if overview.isEmpty {
                empty(ids)
            } else {
                verdict(overview)
                tiles(overview)
                if overview.isMultiSite { siteSummary(overview) }
                linkTableView(overview)
                if !overview.members.isEmpty { memberTableView(overview) }
                tunnelTableView(overview)
                if let tunnel = selectedTunnel(overview) { tunnelDetail(tunnel, overview: overview) }
                if !overview.sslUsers.isEmpty { sslUsers(overview) }
            }
        }
        .task(id: ids) { store.readIfNeeded(ids) }
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactWidth } action: { isCompact = $0 }
    }

    private func selectedTunnel(_ overview: WANOverview) -> WANTunnelUsage? {
        overview.tunnels.first { $0.id == store.selectedTunnelID } ?? overview.alertingTunnels.first
    }

    // MARK: Contrôles

    private func controls(_ ids: [UUID], overview: WANOverview) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                siteField(ids, overview: overview)
                Spacer(minLength: 4)
                thresholdFields
                buttons(ids)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    siteField(ids, overview: overview).fixedSize()
                    Spacer(minLength: 4)
                    buttons(ids)
                }
                thresholdFields
            }
            VStack(alignment: .leading, spacing: 10) {
                siteField(ids, overview: overview)
                buttons(ids)
                thresholdFields
            }
        }
    }

    private func siteField(_ ids: [UUID], overview: WANOverview) -> some View {
        ToolLabeledField(label: "Sites") {
            HStack(spacing: 8) {
                if !sites.sites.isEmpty { SiteScopeMenu(screen: scopeScreen) }
                if store.isReading(ids) { ProgressView().controlSize(.small) }
                Text(sourceText(ids, overview: overview))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minHeight: 28)
        }
        .layoutPriority(1)
    }

    private func sourceText(_ ids: [UUID], overview: WANOverview) -> String {
        guard !overview.isEmpty else { return ids.isEmpty ? "Aucune FortiGate pour ce site" : "Aucune lecture" }
        let names = overview.sites.map(\.site)
        let label = names.count > 2 ? "\(names.count) FortiGate" : names.joined(separator: ", ")
        return "FortiGate · \(label)" + (store.readDate(ids).map { " · lue \(ToolText.relative($0))" } ?? "")
    }

    private var thresholdFields: some View {
        HStack(alignment: .bottom, spacing: 8) {
            numberField("Latence", unit: "ms", text: $latencyText, value: store.thresholds.latencyMs, range: 1...5000) { v in
                let t = store.thresholds
                store.thresholds = WANThresholds(latencyMs: v, jitterMs: t.jitterMs, lossPercent: t.lossPercent)
            }
            numberField("Gigue", unit: "ms", text: $jitterText, value: store.thresholds.jitterMs, range: 1...2000) { v in
                let t = store.thresholds
                store.thresholds = WANThresholds(latencyMs: t.latencyMs, jitterMs: v, lossPercent: t.lossPercent)
            }
            numberField("Perte", unit: "%", text: $lossText, value: store.thresholds.lossPercent, range: 0.1...100) { v in
                let t = store.thresholds
                store.thresholds = WANThresholds(latencyMs: t.latencyMs, jitterMs: t.jitterMs, lossPercent: v)
            }
        }
        .help("Seuils d’un lien dégradé (mesures des sondes SD-WAN de la FortiGate)")
    }

    private func numberField(_ label: String, unit: String, text: Binding<String?>, value: Double, range: ClosedRange<Double>,
                             apply: @escaping (Double) -> Void) -> some View {
        ToolLabeledField(label: label) {
            HStack(spacing: 4) {
                ToolTextField(placeholder: MonFormat.number(value), text: Binding(get: { text.wrappedValue ?? MonFormat.number(value) }, set: { typed in
                    text.wrappedValue = typed
                    guard let v = Double(typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
                          range.contains(v) else { return }
                    apply(v)
                }), height: 28, onSubmit: { text.wrappedValue = nil })
                .frame(width: 52)
                Text(unit).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
            }
        }
        .fixedSize()
    }

    private func buttons(_ ids: [UUID]) -> some View {
        HStack(spacing: 8) {
            Button {
                store.addToReport()
            } label: {
                Label(store.isInReport ? "Dans le rapport" : "Ajouter au rapport",
                      systemImage: store.isInReport ? "checkmark" : "doc.badge.plus")
            }
            .buttonStyle(.secondary)
            .disabled(store.isInReport)
            Button {
                store.read(ids)
            } label: {
                Label(ids.count > 1 ? "Relire les FortiGate" : "Relire la FortiGate", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.primary)
            .disabled(store.isReading(ids) || !store.canRead(ids))
            .help(store.canRead(ids) ? "Relit les liens WAN, le SD-WAN et les tunnels VPN (lecture seule, GET)"
                  : "Aucune FortiGate prête pour ces sites\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate.")
        }
        .fixedSize()
    }

    // MARK: Bilan

    private func empty(_ ids: [UUID]) -> some View {
        ToolNotice(tone: .accent, title: "Aucun WAN à montrer",
                   message: !fortigate.isConfigured
                   ? "Ajoutez la FortiGate du site dans Réglages › Switchs › Contrôleurs FortiGate pour lire ses liens WAN, son SD-WAN et ses tunnels VPN, en lecture seule."
                   : (ids.isEmpty ? "Aucune FortiGate n’est associée aux sites affichés\u{00A0}: associez-la au site dans Réglages › Sites, ou choisissez d’autres sites dans le menu «\u{00A0}Site\u{00A0}»."
                      : "Relisez la FortiGate pour lire ses liens WAN (état, débit), ses sondes SD-WAN (latence, gigue, perte, SLA) et ses tunnels VPN IPsec, en lecture seule."))
    }

    @ViewBuilder private func verdict(_ overview: WANOverview) -> some View {
        let multi = overview.isMultiSite
        let tunnels = overview.alertingTunnels
        let links = overview.alertingLinks
        let texts = tunnels.compactMap { t in WANAnalysis.alertText(t).map { $0 + (multi ? " (\(t.site))" : "") } }
            + links.compactMap { l in WANAnalysis.alertText(l).map { $0 + (multi ? " (\(l.site))" : "") } }
        if let first = texts.first {
            let critical = tunnels.contains { $0.state == .down } || links.contains { $0.state == .down }
            let advice = tunnels.first.map(WANAnalysis.advice) ?? links.first.map(WANAnalysis.advice) ?? ""
            let more = texts.dropFirst()
            ToolNotice(tone: critical ? .critical : .warning, title: first,
                       message: advice + (more.isEmpty ? "" : "\nAussi\u{00A0}: " + more.joined(separator: "\u{00A0}; ") + ".")) {
                if let t = tunnels.first {
                    Button("Voir le tunnel") { store.selectedTunnelID = t.id }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
            }
        } else {
            ToolNotice(tone: .success, title: "WAN et VPN en bon état",
                       message: "Tous les liens WAN répondent sous les seuils (\(store.thresholds.label)) et tous les tunnels IPsec sont montés.")
        }
    }

    private func tiles(_ overview: WANOverview) -> some View {
        let links = overview.links.filter { $0.state != .disabled }
        let linksUp = links.filter { $0.state == .up || $0.state == .degraded }.count
        let degraded = links.filter { $0.state == .degraded }.count
        let tunnels = overview.tunnels.filter { $0.state != .idle }
        let tunnelsUp = tunnels.filter { $0.state == .up }.count
        let rx = links.compactMap(\.interface.rxBps).reduce(0, +)
        let tx = links.compactMap(\.interface.txBps).reduce(0, +)
        let hasRate = links.contains { $0.interface.rxBps != nil || $0.interface.txBps != nil }
        let worstLatency = links.compactMap(\.latencyMs).max()
        let worstLoss = links.compactMap(\.lossPercent).max()
        let items: [(String, String, String, Color)] = [
            ("Liens WAN actifs", "\(linksUp)/\(links.count)", degraded > 0 ? "\(degraded) dégradé\(degraded > 1 ? "s" : "")" : "aucun dégradé",
             linksUp < links.count ? Theme.critical : Theme.text),
            ("Tunnels IPsec", "\(tunnelsUp)/\(tunnels.count)", tunnelsUp < tunnels.count ? "\(tunnels.count - tunnelsUp) tombé\(tunnels.count - tunnelsUp > 1 ? "s" : "") ou partiel\(tunnels.count - tunnelsUp > 1 ? "s" : "")" : "tous montés",
             tunnelsUp < tunnels.count ? Theme.critical : Theme.text),
            ("Débit ↓", hasRate ? ResourceFormat.bitsPerSecond(rx) : "—", hasRate ? "↑\u{00A0}" + ResourceFormat.bitsPerSecond(tx) : "à la prochaine lecture", Theme.text),
            ("Pire latence", WANFormat.ms(worstLatency), worstLoss.map { "perte max " + WANFormat.loss($0) } ?? "sans sonde SD-WAN",
             (worstLatency ?? 0) > store.thresholds.latencyMs ? Theme.warning : Theme.text),
            ("VPN SSL", "\(overview.sslUsers.count)", overview.sslUsers.count > 1 ? "utilisateurs connectés" : "utilisateur connecté", Theme.text),
        ]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { item in
                    ToolStatTile(label: item.0, value: item.1, detail: item.2, valueColor: item.3).frame(minWidth: 124)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(items, id: \.0) { item in
                    ToolStatTile(label: item.0, value: item.1, detail: item.2, valueColor: item.3)
                }
            }
        }
    }

    // MARK: Tous les sites

    private func siteSummary(_ overview: WANOverview) -> some View {
        let rows = overview.sites.map(WANSiteRow.init).sorted(using: siteTable.sortOrder)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Tous les sites · \(rows.count)")
                Spacer(minLength: 8)
                if !isCompact { ToolColumnsMenu(model: siteTable) }
            }
            ToolStandardTableFrame(rowCount: rows.count, maxRows: 10) {
                Table(rows, selection: $siteSelection, sortOrder: $siteTable.sortOrder, columnCustomization: $siteTable.customization) {
                    TableColumn("SITE", sortUsing: siteTable.sort("site")) { row in
                        ToolTableText(row.summary.site, mono: false, weight: .semibold)
                    }
                    .width(min: 80, ideal: 140)
                    .customizationID("site")
                    .disabledCustomizationBehavior(.visibility)
                    TableColumn("FORTIGATE", sortUsing: siteTable.sort("fortigate")) { row in
                        ToolTableText(row.summary.hostname.isEmpty ? "—" : row.summary.hostname + (row.summary.version.isEmpty ? "" : " · \(row.summary.version)"),
                                      size: 11, color: Theme.textSecondary)
                    }
                    .width(min: 80, ideal: 170)
                    .customizationID("fortigate")
                    TableColumn("LIENS WAN", sortUsing: siteTable.sort("liens")) { row in
                        ToolTableText("\(row.summary.linksUp)/\(row.summary.linksTotal) actifs",
                                      color: row.summary.linksUp < row.summary.linksTotal ? Theme.critical : Theme.text)
                    }
                    .width(min: 70, ideal: 100)
                    .customizationID("liens")
                    TableColumn("TUNNELS IPSEC", sortUsing: siteTable.sort("tunnels")) { row in
                        ToolTableText(row.summary.tunnelsTotal == 0 ? "—" : "\(row.summary.tunnelsUp)/\(row.summary.tunnelsTotal) montés",
                                      color: row.summary.tunnelsUp < row.summary.tunnelsTotal ? Theme.critical : Theme.text)
                    }
                    .width(min: 70, ideal: 110)
                    .customizationID("tunnels")
                    TableColumn("ÉTAT", sortUsing: siteTable.sort("etat")) { row in
                        Chip(text: row.summary.level.label, tone: WANTone.tone(row.summary.level))
                    }
                    .width(min: 70, ideal: 84)
                    .customizationID("etat")
                    TableColumn("LECTURE", sortUsing: siteTable.sort("lecture")) { row in
                        ToolTableText(ToolText.relative(row.summary.readAt), mono: false, color: Theme.textSecondary)
                    }
                    .width(min: 70, ideal: 100)
                    .customizationID("lecture")
                }
            }
        }
    }

    // MARK: Liens WAN

    private func linkTableView(_ overview: WANOverview) -> some View {
        let rows = overview.links.map(WANLinkRow.init).sorted(using: linkTable.sortOrder)
        let multi = overview.isMultiSite
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Liens WAN · \(rows.count)")
                Spacer(minLength: 8)
                if !isCompact { ToolColumnsMenu(model: linkTable) }
            }
            if isCompact {
                ToolStandardTableFrame(rowCount: rows.count, rowHeight: ToolTableMetrics.doubleRowHeight, maxRows: 8,
                                       emptyText: "Aucun lien WAN reconnu (rôle «\u{00A0}wan\u{00A0}» ou membre SD-WAN).") {
                    Table(rows, selection: $linkSelection, sortOrder: $linkTable.sortOrder) {
                        TableColumn("LIEN", sortUsing: linkTable.sort("lien")) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.link.interface.shortName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(row.link.interface.name + (multi ? " · \(row.link.site)" : ""))
                                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(row.link.reasons.joined(separator: "\n"))
                        }
                        .width(min: 80, ideal: 110)
                        TableColumn("LATENCE · PERTE", sortUsing: linkTable.sort("perte")) { row in
                            VStack(alignment: .trailing, spacing: 2) {
                                ToolTableText(WANFormat.ms(row.link.latencyMs), alignment: .trailing)
                                ToolTableText("perte " + WANFormat.loss(row.link.lossPercent), size: 11,
                                              color: (row.link.lossPercent ?? 0) > store.thresholds.lossPercent ? Theme.warning : Theme.textSecondary,
                                              alignment: .trailing)
                            }
                        }
                        .width(min: 80, ideal: 100)
                        TableColumn("ÉTAT", sortUsing: linkTable.sort("etat")) { row in
                            Chip(text: row.link.state.label, tone: WANTone.tone(row.link.state))
                        }
                        .width(min: 70, ideal: 86)
                    }
                }
            } else {
                ToolStandardTableFrame(rowCount: rows.count, maxRows: 10,
                                       emptyText: "Aucun lien WAN reconnu (rôle «\u{00A0}wan\u{00A0}» ou membre SD-WAN).") {
                    Table(rows, selection: $linkSelection, sortOrder: $linkTable.sortOrder, columnCustomization: $linkTable.customization) {
                        Group {
                            TableColumn("LIEN WAN", sortUsing: linkTable.sort("lien")) { row in
                                HStack(spacing: 5) {
                                    Text(row.link.interface.shortName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(multi ? "\(row.link.interface.name) · \(row.link.site)" : row.link.interface.name)
                                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(row.link.reasons.isEmpty ? row.link.interface.displayName : row.link.reasons.joined(separator: "\n"))
                            }
                            .width(min: 90, ideal: 140)
                            .customizationID("lien")
                            .disabledCustomizationBehavior(.visibility)
                            TableColumn("ADRESSE IP", sortUsing: linkTable.sort("adresse")) { row in
                                ToolTableText(row.link.interface.addressLabel, size: 11, color: Theme.textSecondary)
                                    .help(row.link.interface.mode.map { "Adressage\u{00A0}: \($0.uppercased())" } ?? "")
                            }
                            .width(min: 80, ideal: 110)
                            .customizationID("adresse")
                            TableColumn("DÉBIT ↓ / ↑", sortUsing: linkTable.sort("debit")) { row in
                                ToolTableText(WANFormat.throughput(rx: row.link.interface.rxBps, tx: row.link.interface.txBps), size: 11)
                                    .help(rateHelp(row.link.interface))
                            }
                            .width(min: 120, ideal: 186)
                            .customizationID("debit")
                            TableColumn("LATENCE", sortUsing: linkTable.sort("latence")) { row in
                                ToolTableText(WANFormat.ms(row.link.latencyMs), color: (row.link.latencyMs ?? 0) > store.thresholds.latencyMs ? Theme.warning : Theme.text, alignment: .trailing)
                            }
                            .width(min: 54, ideal: 66)
                            .customizationID("latence")
                            TableColumn("GIGUE", sortUsing: linkTable.sort("gigue")) { row in
                                ToolTableText(WANFormat.ms(row.link.jitterMs), color: (row.link.jitterMs ?? 0) > store.thresholds.jitterMs ? Theme.warning : Theme.text, alignment: .trailing)
                            }
                            .width(min: 46, ideal: 54)
                            .customizationID("gigue")
                            TableColumn("PERTE", sortUsing: linkTable.sort("perte")) { row in
                                ToolTableText(WANFormat.loss(row.link.lossPercent), weight: (row.link.lossPercent ?? 0) > store.thresholds.lossPercent ? .semibold : .regular,
                                              color: (row.link.lossPercent ?? 0) > store.thresholds.lossPercent ? Theme.warning : Theme.text, alignment: .trailing)
                            }
                            .width(min: 44, ideal: 52)
                            .customizationID("perte")
                            TableColumn("SLA", sortUsing: linkTable.sort("sla")) { row in
                                ToolTableText(row.link.slaLabel, color: (row.link.slaMet ?? 0) < (row.link.slaTotal ?? 0) ? Theme.warning : Theme.text, alignment: .trailing)
                                    .help("Objectifs SLA respectés sur les sondes SD-WAN de ce lien")
                            }
                            .width(min: 44, ideal: 110)
                            .customizationID("sla")
                            TableColumn("ÉTAT", sortUsing: linkTable.sort("etat")) { row in
                                Chip(text: row.link.state.label, tone: WANTone.tone(row.link.state))
                                    .help(row.link.reasons.joined(separator: "\n"))
                            }
                            .width(min: 70, ideal: 84)
                            .customizationID("etat")
                        }
                        Group {
                            TableColumn("VITESSE", sortUsing: linkTable.sort("vitesse")) { row in
                                ToolTableText(WANFormat.speed(row.link.interface.speedMbps), mono: false)
                            }
                            .width(min: 54, ideal: 70)
                            .customizationID("vitesse")
                            .defaultVisibility(.hidden)
                            TableColumn("ERREURS", sortUsing: linkTable.sort("erreurs")) { row in
                                ToolTableText(row.link.interface.rxErrors == nil && row.link.interface.txErrors == nil ? "—" : "\(row.sortErrors)",
                                              color: row.sortErrors > 0 ? Theme.warning : Theme.text, alignment: .trailing)
                            }
                            .width(min: 44, ideal: 60)
                            .customizationID("erreurs")
                            .defaultVisibility(.hidden)
                            TableColumn("SESSIONS", sortUsing: linkTable.sort("sessions")) { row in
                                ToolTableText(row.link.interface.sessions.map { "\($0)" } ?? "—", alignment: .trailing)
                            }
                            .width(min: 44, ideal: 60)
                            .customizationID("sessions")
                            .defaultVisibility(.hidden)
                            TableColumn("PASSERELLE", sortUsing: linkTable.sort("passerelle")) { row in
                                ToolTableText(row.link.interface.gateway?.description ?? "—", size: 11)
                            }
                            .width(min: 80, ideal: 100)
                            .customizationID("passerelle")
                            .defaultVisibility(.hidden)
                            TableColumn("SITE", sortUsing: linkTable.sort("site")) { row in
                                ToolTableText(row.link.site, mono: false)
                            }
                            .width(min: 60, ideal: 100)
                            .customizationID("site")
                            .defaultVisibility(.hidden)
                        }
                    }
                }
            }
            if let link = overview.links.first(where: { $0.id == linkSelection }), !link.reasons.isEmpty, link.state >= .degraded {
                ToolNotice(tone: link.state == .down ? .critical : .warning, title: WANAnalysis.alertText(link) ?? link.interface.displayName,
                           message: WANAnalysis.advice(link))
            }
        }
    }

    private func rateHelp(_ item: WANInterfaceStatus) -> String {
        var parts: [String] = []
        if let down = item.estimatedDownKbps, let up = item.estimatedUpKbps {
            parts.append("Abonnement estimé\u{00A0}: ↓\u{00A0}" + ResourceFormat.bitsPerSecond(Double(down) * 1000) + " · ↑\u{00A0}" + ResourceFormat.bitsPerSecond(Double(up) * 1000))
        }
        if item.rxBps == nil && item.txBps == nil { parts.append("Débit calculé à la prochaine lecture (compteurs de l’interface)") }
        return parts.joined(separator: "\n")
    }

    // MARK: Sondes SD-WAN

    private func memberTableView(_ overview: WANOverview) -> some View {
        let rows = overview.members.map(WANMemberRow.init).sorted(using: memberTable.sortOrder)
        let multi = overview.isMultiSite
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Membres SD-WAN et SLA · \(rows.count)")
                Spacer(minLength: 8)
                if !isCompact { ToolColumnsMenu(model: memberTable) }
            }
            ToolStandardTableFrame(rowCount: rows.count, maxRows: 10) {
                Table(rows, selection: $memberSelection, sortOrder: $memberTable.sortOrder, columnCustomization: $memberTable.customization) {
                    TableColumn("SONDE SD-WAN", sortUsing: memberTable.sort("sonde")) { row in
                        HStack(spacing: 5) {
                            Text(row.member.measure.checkName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            if multi { Text(row.member.site).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(row.member.servers.isEmpty ? row.member.measure.checkName : "Serveurs\u{00A0}: " + row.member.servers.joined(separator: ", "))
                    }
                    .width(min: 80, ideal: 130)
                    .customizationID("sonde")
                    .disabledCustomizationBehavior(.visibility)
                    TableColumn("MEMBRE", sortUsing: memberTable.sort("membre")) { row in
                        ToolTableText(row.member.interfaceLabel, size: 11, color: Theme.textSecondary)
                    }
                    .width(min: 60, ideal: 140)
                    .customizationID("membre")
                    TableColumn("LATENCE", sortUsing: memberTable.sort("latence")) { row in
                        ToolTableText(WANFormat.ms(row.member.measure.latencyMs), alignment: .trailing)
                    }
                    .width(min: 54, ideal: 66)
                    .customizationID("latence")
                    TableColumn("GIGUE", sortUsing: memberTable.sort("gigue")) { row in
                        ToolTableText(WANFormat.ms(row.member.measure.jitterMs), alignment: .trailing)
                    }
                    .width(min: 46, ideal: 54)
                    .customizationID("gigue")
                    TableColumn("PERTE", sortUsing: memberTable.sort("perte")) { row in
                        ToolTableText(WANFormat.loss(row.member.measure.lossPercent), color: (row.member.measure.lossPercent ?? 0) > store.thresholds.lossPercent ? Theme.warning : Theme.text, alignment: .trailing)
                    }
                    .width(min: 44, ideal: 52)
                    .customizationID("perte")
                    TableColumn("SLA", sortUsing: memberTable.sort("sla")) { row in
                        ToolTableText(row.slaText, mono: false, color: row.member.missedSLA.isEmpty ? Theme.textSecondary : Theme.warning)
                            .help(row.member.sla.map(\.label).joined(separator: "\n"))
                    }
                    .width(min: 44, ideal: 110)
                    .customizationID("sla")
                    TableColumn("ÉTAT", sortUsing: memberTable.sort("etat")) { row in
                        Chip(text: row.member.measure.isUp == nil ? "Hors sonde" : row.member.state.label, tone: WANTone.tone(row.member.state))
                    }
                    .width(min: 70, ideal: 84)
                    .customizationID("etat")
                    TableColumn("CHANGEMENT D’ÉTAT", sortUsing: memberTable.sort("depuis")) { row in
                        ToolTableText(row.member.measure.stateChanged.map { "il y a " + WANFormat.duration(since: $0) } ?? "—", mono: false,
                                      color: Theme.textSecondary)
                    }
                    .width(min: 60, ideal: 74)
                    .customizationID("depuis")
                    .defaultVisibility(.hidden)
                    TableColumn("SITE", sortUsing: memberTable.sort("site")) { row in
                        ToolTableText(row.member.site, mono: false)
                    }
                    .width(min: 60, ideal: 100)
                    .customizationID("site")
                    .defaultVisibility(.hidden)
                }
            }
        }
    }

    // MARK: Tunnels IPsec

    private func tunnelTableView(_ overview: WANOverview) -> some View {
        let rows = overview.tunnels.map(WANTunnelRow.init).sorted(using: tunnelTable.sortOrder)
        let current = selectedTunnel(overview)?.id
        let selection = Binding<String?>(get: { current }, set: { if let id = $0 { store.selectedTunnelID = id } })
        let multi = overview.isMultiSite
        let now = overview.readAt ?? Date()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Tunnels VPN IPsec · \(rows.count)")
                Spacer(minLength: 8)
                if !isCompact { ToolColumnsMenu(model: tunnelTable) }
            }
            if isCompact {
                ToolStandardTableFrame(rowCount: rows.count, rowHeight: ToolTableMetrics.doubleRowHeight, maxRows: 8,
                                       emptyText: "Aucun tunnel IPsec sur cette FortiGate.") {
                    Table(rows, selection: selection, sortOrder: $tunnelTable.sortOrder) {
                        TableColumn("TUNNEL", sortUsing: tunnelTable.sort("tunnel")) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.usage.tunnel.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(row.usage.tunnel.peerLabel + (multi ? " · \(row.usage.site)" : ""))
                                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .width(min: 90, ideal: 130)
                        TableColumn("PHASES 2", sortUsing: tunnelTable.sort("phase2")) { row in
                            ToolTableText(row.phase2Text, alignment: .trailing)
                        }
                        .width(min: 50, ideal: 60)
                        TableColumn("ÉTAT", sortUsing: tunnelTable.sort("etat")) { row in
                            Chip(text: row.usage.state.label, tone: WANTone.tone(row.usage.state))
                        }
                        .width(min: 70, ideal: 86)
                    }
                }
            } else {
                ToolStandardTableFrame(rowCount: rows.count, maxRows: 10, emptyText: "Aucun tunnel IPsec sur cette FortiGate.") {
                    Table(rows, selection: selection, sortOrder: $tunnelTable.sortOrder, columnCustomization: $tunnelTable.customization) {
                        TableColumn("TUNNEL", sortUsing: tunnelTable.sort("tunnel")) { row in
                            HStack(spacing: 5) {
                                Text(row.usage.tunnel.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                if multi { Text(row.usage.site).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .width(min: 80, ideal: 120)
                        .customizationID("tunnel")
                        .disabledCustomizationBehavior(.visibility)
                        TableColumn("VERS", sortUsing: tunnelTable.sort("vers")) { row in
                            ToolTableText(row.usage.tunnel.comments ?? "—", mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 80, ideal: 150)
                        .customizationID("vers")
                        TableColumn("PASSERELLE", sortUsing: tunnelTable.sort("passerelle")) { row in
                            ToolTableText(row.usage.tunnel.remoteGateway ?? "—", size: 11)
                        }
                        .width(min: 80, ideal: 100)
                        .customizationID("passerelle")
                        TableColumn("PHASE 2", sortUsing: tunnelTable.sort("phase2")) { row in
                            ToolTableText(row.phase2Text, alignment: .trailing)
                        }
                        .width(min: 54, ideal: 64)
                        .customizationID("phase2")
                        TableColumn("ENTRANT", sortUsing: tunnelTable.sort("entrant")) { row in
                            ToolTableText(WANFormat.bytes(row.usage.tunnel.incomingBytes), alignment: .trailing)
                        }
                        .width(min: 54, ideal: 70)
                        .customizationID("entrant")
                        TableColumn("SORTANT", sortUsing: tunnelTable.sort("sortant")) { row in
                            ToolTableText(WANFormat.bytes(row.usage.tunnel.outgoingBytes), alignment: .trailing)
                        }
                        .width(min: 54, ideal: 70)
                        .customizationID("sortant")
                        TableColumn("DEPUIS", sortUsing: tunnelTable.sort("depuis")) { row in
                            ToolTableText(row.usage.state == .up ? WANFormat.duration(since: row.usage.tunnel.upSince, now: now) : "—",
                                          mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 60, ideal: 74)
                        .customizationID("depuis")
                        TableColumn("ÉTAT", sortUsing: tunnelTable.sort("etat")) { row in
                            Chip(text: row.usage.state.label, tone: WANTone.tone(row.usage.state))
                        }
                        .width(min: 70, ideal: 84)
                        .customizationID("etat")
                        TableColumn("TYPE", sortUsing: tunnelTable.sort("type")) { row in
                            ToolTableText(WANTunnelRow.typeLabel(row.usage.tunnel.type), mono: false)
                        }
                        .width(min: 60, ideal: 90)
                        .customizationID("type")
                        .defaultVisibility(.hidden)
                        TableColumn("SITE", sortUsing: tunnelTable.sort("site")) { row in
                            ToolTableText(row.usage.site, mono: false)
                        }
                        .width(min: 60, ideal: 100)
                        .customizationID("site")
                        .defaultVisibility(.hidden)
                    }
                }
            }
        }
    }

    private func tunnelDetail(_ usage: WANTunnelUsage, overview: WANOverview) -> some View {
        let t = usage.tunnel
        let now = overview.readAt ?? Date()
        let cells: [ToolCell] = [
            ToolCell(key: "Vers", value: t.comments ?? "—", detail: t.remoteGateway.map { "passerelle \($0)" }),
            ToolCell(key: "Phases 2 montées", value: t.phase2.isEmpty ? "—" : "\(t.phase2Up) sur \(t.phase2.count)",
                     detail: WANTunnelRow.typeLabel(t.type)),
            ToolCell(key: "Monté depuis", value: usage.state == .up ? WANFormat.duration(since: t.upSince, now: now) : "—",
                     detail: usage.state == .up ? nil : "tunnel \(usage.state.label.lowercased())"),
            ToolCell(key: "Entrant", value: WANFormat.bytes(t.incomingBytes)),
            ToolCell(key: "Sortant", value: WANFormat.bytes(t.outgoingBytes)),
            ToolCell(key: "Connexions", value: t.connectionCount.map { "\($0)" } ?? "—"),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolFieldLabel("Détail du tunnel · \(t.name)" + (overview.isMultiSite ? " · \(usage.site)" : ""))
                Spacer(minLength: 8)
                Chip(text: usage.state.label, tone: WANTone.tone(usage.state))
            }
            ToolCellGrid(cells: cells, columns: 3, valueSize: 13, minCellWidth: 140)
            // Le bilan du haut détaille déjà le premier tunnel en panne : son conseil n'est pas répété.
            if usage.state >= .partial, usage.id != overview.alertingTunnels.first?.id, let text = WANAnalysis.alertText(usage) {
                ToolNotice(tone: usage.state == .down ? .critical : .warning, title: text, message: WANAnalysis.advice(usage))
            }
            if !t.phase2.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ToolFieldLabel("Phases 2 (sélecteurs) · \(t.phase2.count)")
                    ForEach(t.phase2, id: \.name) { p in
                        HStack(spacing: 8) {
                            Chip(text: p.isUp ? "Montée" : "Tombée", tone: p.isUp ? .success : .critical)
                            Text(p.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Text("\(p.source ?? "—") ⇄ \(p.destination ?? "—")").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            Spacer(minLength: 6)
                            if p.isUp {
                                Text("↓\u{00A0}\(WANFormat.bytes(p.incomingBytes)) · ↑\u{00A0}\(WANFormat.bytes(p.outgoingBytes))")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: VPN SSL

    private func sslUsers(_ overview: WANOverview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ToolFieldLabel("VPN SSL · \(overview.sslUsers.count) connecté\(overview.sslUsers.count > 1 ? "s" : "")")
            ForEach(Array(overview.sslUsers.enumerated()), id: \.offset) { _, user in
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle").foregroundStyle(Theme.textSecondary)
                    Text(user.user).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(user.remoteHost ?? "").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(user.loginAt.map { "connecté depuis " + WANFormat.duration(since: $0) } ?? "")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                }
            }
        }
    }
}
