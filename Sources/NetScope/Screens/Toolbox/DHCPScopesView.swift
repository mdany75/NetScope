import NetScopeCore
import SwiftUI

/// Outil « Étendues DHCP » (note 37, groupe Services) : occupation de chaque étendue DHCP de la
/// FortiGate du site (plages, exclusions, réservations, baux), seuils réglables, détail d'une
/// étendue avec ses baux et un lien vers la fiche de chaque appareil. Sans FortiGate lue :
/// estimation par le Test DHCP et le scan, clairement marquée.
struct DHCPScopesView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: ToolStore
    @ObservedObject private var scopes = DHCPScopeStore.shared
    @ObservedObject private var dhcp = ToolStore.shared.dhcp
    @ObservedObject private var fortigate = FortiGateStore.shared
    /// Observé pour que « Ajouter au rapport » passe tout de suite à « Dans le rapport ».
    @ObservedObject private var rapport = RapportModel.shared
    @StateObject private var table = DHCPScopeRow.makeModel()
    @StateObject private var entryTable = DHCPScopeEntryRow.makeModel()
    @State private var warningText: String?
    @State private var criticalText: String?
    @State private var soonText: String?
    @FocusState private var thresholdFocus: ThresholdField?

    private enum ThresholdField { case warning, critical }
    @State private var entrySelection: String?
    /// Petite fenêtre : tableaux à colonnes réduites.
    @State private var isCompact = false

    var body: some View {
        let overview = scopes.overview(devices: state.devices)
        VStack(alignment: .leading, spacing: 14) {
            controls(overview)
            ForEach(Array(Set(scopes.errors.values)).sorted(), id: \.self) { message in
                ToolNotice(tone: .critical, title: "Lecture des étendues impossible", message: message)
            }
            ForEach(overview.notes, id: \.self) { note in
                ToolNotice(tone: .warning, message: note)
            }
            if overview.scopes.isEmpty {
                empty
            } else {
                if overview.isEstimate { estimateNotice }
                verdict(overview)
                tiles(overview)
                scopeTable(overview)
                if let scope = selected(in: overview) { detail(scope, overview: overview) }
            }
        }
        .task { scopes.refreshIfNeeded(state: state) }
        // Petite fenêtre : tableaux réduits aux colonnes essentielles (taux et état toujours
        // visibles sans défilement horizontal) ; le détail de l'étendue garde tout le reste.
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactWidth } action: { isCompact = $0 }
    }

    static let compactWidth: CGFloat = 640

    private func selected(in overview: DHCPScopeOverview) -> DHCPScopeUsage? {
        overview.scopes.first { $0.id == scopes.selectedScopeID } ?? overview.alerting.first ?? overview.scopes.first
    }

    // MARK: Contrôles

    /// Source, seuils et boutons sur une ligne s'ils y tiennent, sinon sur deux (petite fenêtre).
    private func controls(_ overview: DHCPScopeOverview) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                sourceField(overview)
                Spacer(minLength: 4)
                thresholdFields
                buttons
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    sourceField(overview).fixedSize()
                    Spacer(minLength: 4)
                    buttons
                }
                thresholdFields
            }
            // Petite fenêtre : la source sur sa ligne, puis les boutons, puis les seuils.
            VStack(alignment: .leading, spacing: 10) {
                sourceField(overview)
                buttons
                thresholdFields
            }
        }
    }

    private func sourceField(_ overview: DHCPScopeOverview) -> some View {
        ToolLabeledField(label: "Source") {
            HStack(spacing: 6) {
                if scopes.busy { ProgressView().controlSize(.small) }
                Text(sourceText(overview))
                    .font(Theme.bodyMedium).foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minHeight: 28)
        }
        .layoutPriority(1)
    }

    private func sourceText(_ overview: DHCPScopeOverview) -> String {
        if overview.isEstimate {
            return dhcp.lastRun.map { "Estimation · Test DHCP \(ToolText.relative($0))" } ?? "Aucune lecture"
        }
        let when = scopes.lastRefresh.map { " · lue \(ToolText.relative($0))" } ?? ""
        return "FortiGate · \(scopes.sitesLabel)" + when
    }

    private var thresholdFields: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Pendant la saisie, seule une valeur cohérente avec l'autre seuil est appliquée ; l'autre
            // seuil n'est ajusté qu'à la validation (Retour ou focus perdu).
            percentField("Avertissement", text: $warningText, value: scopes.thresholds.warningPercent, field: .warning) { value in
                let t = scopes.thresholds
                guard value <= t.criticalPercent else { return }
                scopes.thresholds = DHCPScopeThresholds(warningPercent: value, criticalPercent: t.criticalPercent,
                                                        expiringMinutes: t.expiringMinutes)
            }
            percentField("Critique", text: $criticalText, value: scopes.thresholds.criticalPercent, field: .critical) { value in
                let t = scopes.thresholds
                guard value >= t.warningPercent else { return }
                scopes.thresholds = DHCPScopeThresholds(warningPercent: t.warningPercent, criticalPercent: value,
                                                        expiringMinutes: t.expiringMinutes)
            }
            ToolLabeledField(label: "Expire bientôt") {
                HStack(spacing: 4) {
                    ToolTextField(placeholder: "60", text: Binding(get: { soonText ?? String(scopes.thresholds.expiringMinutes) }, set: { text in
                        soonText = text
                        guard let v = Int(text.trimmingCharacters(in: .whitespaces)), v > 0 else { return }
                        let t = scopes.thresholds
                        scopes.thresholds = DHCPScopeThresholds(warningPercent: t.warningPercent, criticalPercent: t.criticalPercent,
                                                                expiringMinutes: min(v, 10_080))
                    }), height: 28)
                    .frame(width: 52)
                    Text("min").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                }
            }
            .fixedSize()
        }
    }

    private func percentField(_ label: String, text: Binding<String?>, value: Double, field: ThresholdField,
                              apply: @escaping (Double) -> Void) -> some View {
        ToolLabeledField(label: label) {
            HStack(spacing: 4) {
                ToolTextField(placeholder: MonFormat.number(value), text: Binding(get: { text.wrappedValue ?? MonFormat.number(value) }, set: { typed in
                    text.wrappedValue = typed
                    guard let v = Self.percent(typed) else { return }
                    apply(v)
                }), height: 28, onSubmit: { commitThreshold(field) })
                .focused($thresholdFocus, equals: field)
                .frame(width: 48)
                Text("%").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
            }
        }
        .fixedSize()
        .onChange(of: thresholdFocus) { previous, _ in
            if previous == field { commitThreshold(field) }
        }
    }

    private static func percent(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              v > 0, v <= 100 else { return nil }
        return v
    }

    /// Validation d'un seuil : la valeur saisie l'emporte, l'autre seuil est ajusté au besoin, et les
    /// deux champs réaffichent les valeurs enregistrées.
    private func commitThreshold(_ field: ThresholdField) {
        let t = scopes.thresholds
        switch field {
        case .warning:
            if let text = warningText, let v = Self.percent(text) {
                scopes.thresholds = DHCPScopeThresholds(warningPercent: v, criticalPercent: max(v, t.criticalPercent),
                                                        expiringMinutes: t.expiringMinutes)
            }
        case .critical:
            if let text = criticalText, let v = Self.percent(text) {
                scopes.thresholds = DHCPScopeThresholds(warningPercent: min(t.warningPercent, v), criticalPercent: v,
                                                        expiringMinutes: t.expiringMinutes)
            }
        }
        warningText = nil
        criticalText = nil
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                scopes.addToReport()
            } label: {
                Label(scopes.isInReport ? "Dans le rapport" : "Ajouter au rapport",
                      systemImage: scopes.isInReport ? "checkmark" : "doc.badge.plus")
            }
            .buttonStyle(.secondary)
            .disabled(scopes.isInReport)
            Button {
                scopes.refreshNow(state: state)
            } label: {
                Label("Relire la FortiGate", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.primary)
            .disabled(scopes.busy || !scopes.canRefresh(state: state))
            .help(scopes.canRefresh(state: state) ? "Relit les serveurs DHCP et les baux (lecture seule, GET)"
                  : "Aucune FortiGate prête pour ce site\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate.")
        }
        .fixedSize()
    }

    // MARK: Bilan

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolNotice(tone: .accent, title: "Aucune étendue DHCP à montrer",
                       message: fortigate.isConfigured
                       ? "Relisez la FortiGate du site pour lire ses serveurs DHCP (plages, exclusions, réservations) et leurs baux, en lecture seule. Sans FortiGate, un Test DHCP donne une estimation à partir du sous-réseau offert et des appareils vus par le scan."
                       : "Ajoutez la FortiGate du site dans Réglages › Switchs › Contrôleurs FortiGate pour lire ses étendues DHCP. Sans FortiGate, un Test DHCP donne une estimation à partir du sous-réseau offert et des appareils vus par le scan.")
            Button {
                store.selectedTool = .dhcp
            } label: {
                Label("Ouvrir le Test DHCP", systemImage: "shield.lefthalf.filled")
            }
            .buttonStyle(.secondary)
            .fixedSize()
        }
    }

    private var estimateNotice: some View {
        ToolNotice(tone: .accent, title: "Estimation sans FortiGate",
                   message: "Plage supposée = tout le sous-réseau offert par le Test DHCP\u{00A0}; adresses utilisées = appareils vus en ligne par le scan (adresses fixes comprises). Les vraies plages, exclusions et réservations ne sont connues qu’en lisant la FortiGate du site.")
    }

    @ViewBuilder private func verdict(_ overview: DHCPScopeOverview) -> some View {
        let alerting = DHCPScopeAnalysis.relevel(overview.scopes, thresholds: scopes.thresholds)
            .filter { $0.level >= .warning }.sorted { ($0.level, $0.percent) > ($1.level, $1.percent) }
        if let first = alerting.first, let text = DHCPScopeAnalysis.alertText(first) {
            let more = alerting.dropFirst().compactMap { scope in
                DHCPScopeAnalysis.alertText(scope).map { $0 + (overview.isMultiSite ? " (\(scope.site))" : "") }
            }
            ToolNotice(tone: first.level == .critical ? .critical : .warning, title: text + (overview.isMultiSite ? " (\(first.site))" : ""),
                       message: DHCPScopeAnalysis.advice(first)
                       + (more.isEmpty ? "" : "\nAussi\u{00A0}: " + more.joined(separator: "\u{00A0}; ") + ".")) {
                Button("Voir l’étendue") { scopes.selectedScopeID = first.id }
                    .buttonStyle(.secondary)
                    .fixedSize()
            }
        } else {
            ToolNotice(tone: .success, title: "Toutes les étendues ont des adresses libres",
                       message: "Aucune étendue au-delà de \(MonFormat.percent(scopes.thresholds.warningPercent)) d’occupation.")
        }
    }

    private func tiles(_ overview: DHCPScopeOverview) -> some View {
        let active = overview.activeScopes
        let pool = active.reduce(0) { $0 + $1.poolSize }
        let used = active.reduce(0) { $0 + $1.used }
        let leases = active.reduce(0) { $0 + $1.activeLeases }
        let reservations = active.reduce(0) { $0 + $1.reservationsInPool }
        let soon = active.reduce(0) { $0 + $1.expiringSoon }
        let inactive = overview.scopes.count - active.count
        let items: [(String, String, String)] = [
            ("Étendues actives", "\(active.count)", inactive > 0 ? "\(inactive) inactive\(inactive > 1 ? "s" : "")" : "sur \(overview.scopes.count)"),
            ("Adresses libres", "\(max(0, pool - used))", "sur \(pool)"),
            (overview.isEstimate ? "Vus en ligne" : "Baux actifs", "\(leases)", overview.isEstimate ? "par le scan" : "hors réservations"),
            ("Réservations", overview.isEstimate ? "—" : "\(reservations)", overview.isEstimate ? "inconnues" : "dans les plages"),
            ("Expirent bientôt", overview.isEstimate ? "—" : "\(soon)", "< \(scopes.thresholds.expiringMinutes)\u{00A0}min"),
        ]
        // Une rangée de cinq cases quand elles y tiennent, sinon une grille (petite fenêtre).
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { item in
                    ToolStatTile(label: item.0, value: item.1, detail: item.2).frame(minWidth: 124)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(items, id: \.0) { item in
                    ToolStatTile(label: item.0, value: item.1, detail: item.2)
                }
            }
        }
    }

    // MARK: Tableau des étendues

    private func scopeTable(_ overview: DHCPScopeOverview) -> some View {
        let rows = DHCPScopeAnalysis.relevel(overview.scopes, thresholds: scopes.thresholds)
            .map(DHCPScopeRow.init).sorted(using: table.sortOrder)
        let current = selected(in: overview)?.id
        let selection = Binding<String?>(get: { current }, set: { if let id = $0 { scopes.selectedScopeID = id } })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Étendues · \(rows.count)")
                Spacer(minLength: 8)
                if !isCompact { ToolColumnsMenu(model: table) }
            }
            if isCompact {
                compactScopeTable(rows, selection: selection, multiSite: overview.isMultiSite)
            } else {
                fullScopeTable(rows, selection: selection, multiSite: overview.isMultiSite)
            }
        }
    }

    /// Petite fenêtre : étendue (et son interface dessous), utilisées, taux et état.
    private func compactScopeTable(_ rows: [DHCPScopeRow], selection: Binding<String?>, multiSite: Bool) -> some View {
        ToolStandardTableFrame(rowCount: rows.count, rowHeight: ToolTableMetrics.doubleRowHeight, maxRows: 10) {
            Table(rows, selection: selection, sortOrder: $table.sortOrder) {
                TableColumn("ÉTENDUE", sortUsing: table.sort("etendue")) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.scope.alias.flatMap { $0.isEmpty ? nil : $0 } ?? row.scope.shortName)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(row.scope.interfaceLabel + (multiSite ? " · \(row.scope.site)" : ""))
                            .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.scope.rangesLabel)
                }
                .width(min: 70, ideal: 86)
                TableColumn("UTILISÉES", sortUsing: table.sort("utilisees")) { row in
                    ToolTableText(row.scope.level == .inactive ? "—" : row.scope.usedLabel, alignment: .trailing)
                }
                .width(min: 64, ideal: 72)
                TableColumn("TAUX", sortUsing: table.sort("taux")) { row in
                    DHCPScopeGauge(scope: row.scope)
                }
                .width(min: 80, ideal: 96)
                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                    Chip(text: row.scope.isEstimate && row.scope.level == .ok ? "Estimation" : row.scope.level.label,
                         tone: DHCPScopeRow.tone(row.scope.level))
                }
                .width(min: 76, ideal: 104)
            }
        }
    }

    private func fullScopeTable(_ rows: [DHCPScopeRow], selection: Binding<String?>, multiSite: Bool) -> some View {
            ToolStandardTableFrame(rowCount: rows.count, maxRows: 10) {
                Table(rows, selection: selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    Group {
                        TableColumn("ÉTENDUE", sortUsing: table.sort("etendue")) { row in
                            HStack(spacing: 5) {
                                Text(row.scope.alias.flatMap { $0.isEmpty ? nil : $0 } ?? row.scope.shortName)
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                if multiSite {
                                    Text(row.scope.site).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(row.scope.displayName)
                        }
                        .width(min: 60, ideal: 90)
                        .customizationID("etendue")
                        .disabledCustomizationBehavior(.visibility)

                        TableColumn("INTERFACE / VLAN", sortUsing: table.sort("interface")) { row in
                            ToolTableText(row.scope.interfaceLabel, color: Theme.textSecondary).help(row.scope.vlan.map { "VLAN \($0)" } ?? "")
                        }
                        .width(min: 52, ideal: 124)
                        .customizationID("interface")

                        TableColumn("PLAGE", sortUsing: table.sort("plage")) { row in
                            ToolTableText(row.scope.compactRangesLabel, size: 11).help(row.scope.rangesLabel)
                        }
                        .width(min: 96, ideal: 140)
                        .customizationID("plage")

                        TableColumn("UTILISÉES", sortUsing: table.sort("utilisees")) { row in
                            ToolTableText(row.scope.level == .inactive ? "—" : row.scope.usedLabel, alignment: .trailing)
                        }
                        .width(min: 52, ideal: 72)
                        .customizationID("utilisees")

                        TableColumn("TAUX", sortUsing: table.sort("taux")) { row in
                            DHCPScopeGauge(scope: row.scope)
                        }
                        .width(min: 80, ideal: 130)
                        .customizationID("taux")

                        TableColumn("RÉSERV.", sortUsing: table.sort("reservations")) { row in
                            ToolTableText(row.scope.isEstimate ? "—" : "\(row.scope.reservationsInPool)", alignment: .trailing)
                                .help(row.scope.reservationsOutside > 0 ? "\(row.scope.reservationsInPool) dans la plage, \(row.scope.reservationsOutside) hors plage" : "")
                        }
                        .width(min: 36, ideal: 60)
                        .customizationID("reservations")

                        TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                            Chip(text: row.scope.isEstimate && row.scope.level == .ok ? "Estimation" : row.scope.level.label,
                                 tone: DHCPScopeRow.tone(row.scope.level))
                        }
                        .width(min: 76, ideal: 100)
                        .customizationID("etat")
                    }
                    Group {
                        TableColumn("LIBRES", sortUsing: table.sort("libres")) { row in
                            ToolTableText(row.scope.level == .inactive ? "—" : "\(row.scope.free)", alignment: .trailing)
                        }
                        .width(min: 44, ideal: 54)
                        .customizationID("libres")
                        .defaultVisibility(.hidden)

                        TableColumn("BAUX", sortUsing: table.sort("baux")) { row in
                            ToolTableText("\(row.scope.activeLeases)", alignment: .trailing)
                        }
                        .width(min: 44, ideal: 54)
                        .customizationID("baux")
                        .defaultVisibility(.hidden)

                        TableColumn("EXPIRENT BIENTÔT", sortUsing: table.sort("bientot")) { row in
                            ToolTableText(row.scope.isEstimate ? "—" : "\(row.scope.expiringSoon)", alignment: .trailing)
                        }
                        .width(min: 54, ideal: 70)
                        .customizationID("bientot")
                        .defaultVisibility(.hidden)

                        TableColumn("BAIL", sortUsing: table.sort("bail")) { row in
                            ToolTableText(DHCPScopeAnalysis.leaseText(row.scope.leaseTime), mono: false)
                        }
                        .width(min: 44, ideal: 56)
                        .customizationID("bail")
                        .defaultVisibility(.hidden)

                        TableColumn("SOUS-RÉSEAU", sortUsing: table.sort("sousreseau")) { row in
                            ToolTableText(row.scope.subnet?.description ?? "—")
                        }
                        .width(min: 90, ideal: 120)
                        .customizationID("sousreseau")
                        .defaultVisibility(.hidden)

                        TableColumn("EXCLUSIONS", sortUsing: table.sort("exclusions")) { row in
                            ToolTableText(row.scope.exclusions.isEmpty ? "—" : row.scope.exclusions.map(\.description).joined(separator: ", "), size: 11)
                        }
                        .width(min: 90, ideal: 160)
                        .customizationID("exclusions")
                        .defaultVisibility(.hidden)

                        TableColumn("SITE", sortUsing: table.sort("site")) { row in
                            ToolTableText(row.scope.site, mono: false)
                        }
                        .width(min: 60, ideal: 100)
                        .customizationID("site")
                        .defaultVisibility(.hidden)
                    }
                }
            }
    }

    // MARK: Détail d'une étendue

    private func detail(_ raw: DHCPScopeUsage, overview: DHCPScopeOverview) -> some View {
        var scope = raw
        scope.level = DHCPScopeAnalysis.level(raw, thresholds: scopes.thresholds)
        var cells: [ToolCell] = [
            ToolCell(key: scope.ranges.count > 1 ? "Plages (\(scope.ranges.count))" : "Plage", value: scope.compactRangesLabel,
                     detail: scope.subnet.map { "sous-réseau \($0)" }),
            ToolCell(key: "Adresses distribuables", value: "\(scope.poolSize)",
                     detail: scope.exclusions.isEmpty ? "aucune exclusion" : "exclusions\u{00A0}: " + scope.exclusions.map(\.description).joined(separator: ", ")),
            ToolCell(key: "Utilisées", value: scope.level == .inactive ? "—" : "\(scope.used) (\(scope.percentLabel))",
                     detail: scope.isEstimate ? "appareils vus en ligne" : MonText.plural(scope.activeLeases, "bail", "baux") + " + " + MonText.plural(scope.reservationsInPool, "réservation", "réservations")),
            ToolCell(key: "Libres", value: scope.level == .inactive ? "—" : "\(scope.free)"),
        ]
        if !scope.isEstimate {
            cells.append(ToolCell(key: "Réservations", value: "\(scope.reservationsInPool) dans la plage",
                                  detail: "\(scope.reservationsInUse) avec un bail actif" + (scope.reservationsOutside > 0 ? " · \(scope.reservationsOutside) hors plage" : "")))
            cells.append(ToolCell(key: "Expirent bientôt", value: "\(scope.expiringSoon)", detail: "dans moins de \(scopes.thresholds.expiringMinutes)\u{00A0}min"))
        }
        cells.append(ToolCell(key: "Bail", value: DHCPScopeAnalysis.leaseText(scope.leaseTime),
                              detail: scope.leaseTime.map { $0 > 0 ? "\(ToolFormat.integer(UInt32(clamping: $0)))\u{00A0}s" : "sans expiration" }))
        cells.append(ToolCell(key: "Passerelle", value: scope.gateway?.description ?? "—", detail: scope.enabled ? nil : "serveur DHCP désactivé"))
        cells.append(ToolCell(key: "Interface", value: scope.interface, detail: scope.vlan.map { "VLAN \($0)" + (scope.alias.map { " · \($0)" } ?? "") } ?? scope.alias))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolFieldLabel("Détail de l’étendue · \(scope.displayName)" + (overview.isMultiSite ? " · \(scope.site)" : ""))
                Spacer(minLength: 8)
                Chip(text: scope.isEstimate && scope.level == .ok ? "Estimation" : scope.level.label, tone: DHCPScopeRow.tone(scope.level))
            }
            ToolCellGrid(cells: cells, columns: 3, valueSize: 13, minCellWidth: 140)
            // Le bilan du haut détaille déjà l'étendue la plus pleine : son conseil n'est pas répété.
            let topAlert = DHCPScopeAnalysis.relevel(overview.scopes, thresholds: scopes.thresholds)
                .filter { $0.level >= .warning }.max { ($0.level, $0.percent) < ($1.level, $1.percent) }?.id
            if scope.level >= .warning, scope.id != topAlert, let text = DHCPScopeAnalysis.alertText(scope) {
                ToolNotice(tone: scope.level == .critical ? .critical : .warning, title: text, message: DHCPScopeAnalysis.advice(scope))
            }
            ForEach(scope.notes.filter { !overview.isEstimate || !$0.hasPrefix("Estimation") }, id: \.self) { note in
                ToolNotice(tone: .neutral, message: note)
            }
            entries(scope)
        }
    }

    private func entries(_ scope: DHCPScopeUsage) -> some View {
        let devices = state.devices
        let byMAC = Dictionary(devices.compactMap { d in d.mac.map { ($0, d) } }, uniquingKeysWith: { first, _ in first })
        let byIP = Dictionary(devices.map { ($0.ip, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = scope.entries.map { entry in
            DHCPScopeEntryRow(entry: entry, device: entry.mac.flatMap { byMAC[$0] } ?? byIP[entry.ip])
        }
        .sorted(using: entryTable.sortOrder)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel((scope.isEstimate ? "Appareils vus en ligne · " : "Baux et réservations · ") + "\(rows.count)")
                Spacer(minLength: 8)
                Text("Double-clic\u{00A0}: fiche de l’appareil").font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                if !isCompact { ToolColumnsMenu(model: entryTable) }
            }
            if isCompact {
                compactEntryTable(rows)
            } else {
            ToolStandardTableFrame(rowCount: rows.count, maxRows: 12, emptyText: "Aucun bail ni réservation dans cette étendue.") {
                Table(rows, selection: $entrySelection, sortOrder: $entryTable.sortOrder, columnCustomization: $entryTable.customization) {
                    TableColumn("ADRESSE IP", sortUsing: entryTable.sort("ip")) { row in
                        ToolTableText(row.entry.ip.description, weight: .medium)
                    }
                    .width(min: 96, ideal: 110)
                    .customizationID("ip")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("NOM", sortUsing: entryTable.sort("nom")) { row in
                        ToolTableText(row.name, mono: false, color: row.name == "—" ? Theme.textTertiary : Theme.text).help(row.name)
                    }
                    .width(min: 90, ideal: 170)
                    .customizationID("nom")

                    TableColumn("MAC · FABRICANT", sortUsing: entryTable.sort("mac")) { row in
                        (Text(row.entry.mac?.formatted(.upperColon) ?? "—").font(Theme.mono(11))
                         + Text(row.vendor.map { " · \($0)" } ?? "").font(Theme.caption))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .width(min: 110, ideal: 190)
                    .customizationID("mac")

                    TableColumn("TYPE", sortUsing: entryTable.sort("type")) { row in
                        Chip(text: row.entry.kind.label, tone: DHCPScopeEntryRow.tone(row.entry.kind))
                    }
                    .width(min: 70, ideal: 120)
                    .customizationID("type")

                    TableColumn("EXPIRE", sortUsing: entryTable.sort("expire")) { row in
                        ToolTableText(DHCPScopeEntryRow.expiryText(row.entry.expires), mono: false,
                                      color: row.entry.expiringSoon ? Theme.warning : Theme.textSecondary)
                    }
                    .width(min: 60, ideal: 90)
                    .customizationID("expire")

                    TableColumn("APPAREIL", sortUsing: entryTable.sort("appareil")) { row in
                        ToolTableText(row.device?.displayName ?? "—", mono: false,
                                      color: row.device == nil ? Theme.textTertiary : Theme.accentStrong)
                            .help(row.device == nil ? "Absent du dernier scan" : "Double-clic\u{00A0}: ouvrir la fiche")
                    }
                    .width(min: 70, ideal: 140)
                    .customizationID("appareil")
                }
                // Note 34 : double-clic ou ↩︎ → fiche de l'appareil (scan, sinon inventaire) ;
                // clic droit → « Ouvrir dans › ».
                .standardRowNavigation(selection: entrySelection.map { [$0] } ?? [], object: { id in
                    rows.first { $0.id == id }.map { .device($0.navRef) }
                })
            }
            }
        }
    }

    /// Petite fenêtre : adresse, nom (et MAC dessous), type et expiration.
    private func compactEntryTable(_ rows: [DHCPScopeEntryRow]) -> some View {
        ToolStandardTableFrame(rowCount: rows.count, rowHeight: ToolTableMetrics.doubleRowHeight, maxRows: 10,
                               emptyText: "Aucun bail ni réservation dans cette étendue.") {
            Table(rows, selection: $entrySelection, sortOrder: $entryTable.sortOrder) {
                TableColumn("ADRESSE IP", sortUsing: entryTable.sort("ip")) { row in
                    ToolTableText(row.entry.ip.description, weight: .medium)
                }
                .width(min: 108, ideal: 112)
                TableColumn("NOM", sortUsing: entryTable.sort("nom")) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.device?.displayName ?? row.name).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(row.name == "—" && row.device == nil ? Theme.textTertiary : Theme.text).lineLimit(1)
                        Text(row.entry.mac?.formatted(.upperColon) ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.name)
                }
                .width(min: 80, ideal: 100)
                TableColumn("TYPE", sortUsing: entryTable.sort("type")) { row in
                    Chip(text: row.entry.kind.label, tone: DHCPScopeEntryRow.tone(row.entry.kind))
                }
                .width(min: 70, ideal: 86)
                TableColumn("EXPIRE", sortUsing: entryTable.sort("expire")) { row in
                    ToolTableText(DHCPScopeEntryRow.expiryText(row.entry.expires), mono: false,
                                  color: row.entry.expiringSoon ? Theme.warning : Theme.textSecondary)
                }
                .width(min: 56, ideal: 64)
            }
            .standardRowNavigation(selection: entrySelection.map { [$0] } ?? [], object: { id in
                rows.first { $0.id == id }.map { .device($0.navRef) }
            })
        }
    }
}

// MARK: - Jauge

/// Taux d'occupation : barre fine colorée selon le niveau, suivie du pourcentage.
struct DHCPScopeGauge: View {
    let scope: DHCPScopeUsage

    var body: some View {
        if scope.level == .inactive {
            ToolTableText(scope.enabled ? "plage vide" : "désactivée", mono: false, color: Theme.textTertiary)
        } else {
            HStack(spacing: 6) {
                ProgressBar(fraction: scope.percent / 100, color: DHCPScopeRow.color(scope.level), height: 6)
                    .frame(minWidth: 36)
                Text(scope.percentLabel)
                    .font(Theme.mono(11, weight: scope.level >= .warning ? .semibold : .regular))
                    .foregroundStyle(scope.level >= .warning ? DHCPScopeRow.color(scope.level) : Theme.text)
                    .lineLimit(1)
                    .fixedSize()
            }
            .help(MonText.plural(scope.used, "adresse utilisée", "adresses utilisées") + " sur \(scope.poolSize) · " + MonText.plural(scope.free, "libre", "libres"))
        }
    }
}

// MARK: - Lignes des tableaux

/// Ligne du tableau des étendues (tableau standard « outils.dhcp.etendues »).
struct DHCPScopeRow: Identifiable {
    let scope: DHCPScopeUsage
    var id: String { scope.id }

    init(_ scope: DHCPScopeUsage) { self.scope = scope }

    // Clés de tri (toujours Comparable).
    var sortName: String { SearchText.fold(scope.alias ?? scope.shortName) }
    var sortInterface: String { String(format: "%05d", scope.vlan ?? 0) + scope.interface }
    var sortRange: UInt32 { scope.ranges.first?.start.value ?? .max }
    var sortUsed: Int { scope.used }
    var sortPercent: Double { scope.level == .inactive ? -1 : scope.percent }
    var sortReservations: Int { scope.reservationsInPool }
    var sortLevel: Int { scope.level.rawValue }
    var sortFree: Int { scope.free }
    var sortLeases: Int { scope.activeLeases }
    var sortSoon: Int { scope.expiringSoon }
    var sortLease: Int { scope.leaseTime ?? .max }
    var sortSubnet: UInt32 { scope.subnet?.network.value ?? .max }
    var sortExclusions: Int { scope.exclusions.count }
    var sortSite: String { scope.site }

    static func tone(_ level: DHCPScopeLevel) -> Tone {
        switch level {
        case .critical: return .critical
        case .warning: return .warning
        case .ok: return .success
        case .inactive: return .neutral
        }
    }

    static func color(_ level: DHCPScopeLevel) -> Color {
        switch level {
        case .critical: return Theme.criticalBadge
        case .warning: return Theme.warningDot
        case .ok: return Theme.successDot
        case .inactive: return Theme.neutralDot
        }
    }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "etendue", title: "Étendue", isRequired: true),
        StandardColumn(id: "interface", title: "Interface / VLAN"),
        StandardColumn(id: "plage", title: "Plage"),
        StandardColumn(id: "utilisees", title: "Utilisées / total"),
        StandardColumn(id: "taux", title: "Taux"),
        StandardColumn(id: "reservations", title: "Réservations"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "libres", title: "Adresses libres", isDefaultVisible: false),
        StandardColumn(id: "baux", title: "Baux actifs", isDefaultVisible: false),
        StandardColumn(id: "bientot", title: "Expirent bientôt", isDefaultVisible: false),
        StandardColumn(id: "bail", title: "Durée du bail", isDefaultVisible: false),
        StandardColumn(id: "sousreseau", title: "Sous-réseau", isDefaultVisible: false),
        StandardColumn(id: "exclusions", title: "Exclusions", isDefaultVisible: false),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<DHCPScopeRow>] = [
        "etendue": KeyPathComparator(\DHCPScopeRow.sortName),
        "interface": KeyPathComparator(\DHCPScopeRow.sortInterface),
        "plage": KeyPathComparator(\DHCPScopeRow.sortRange),
        "utilisees": KeyPathComparator(\DHCPScopeRow.sortUsed),
        "taux": KeyPathComparator(\DHCPScopeRow.sortPercent),
        "reservations": KeyPathComparator(\DHCPScopeRow.sortReservations),
        "etat": KeyPathComparator(\DHCPScopeRow.sortLevel),
        "libres": KeyPathComparator(\DHCPScopeRow.sortFree),
        "baux": KeyPathComparator(\DHCPScopeRow.sortLeases),
        "bientot": KeyPathComparator(\DHCPScopeRow.sortSoon),
        "bail": KeyPathComparator(\DHCPScopeRow.sortLease),
        "sousreseau": KeyPathComparator(\DHCPScopeRow.sortSubnet),
        "exclusions": KeyPathComparator(\DHCPScopeRow.sortExclusions),
        "site": KeyPathComparator(\DHCPScopeRow.sortSite),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<DHCPScopeRow> {
        StandardTableModel(id: "outils.dhcp.etendues", columns: columns, sortKeys: sortKeys, defaultSort: "interface")
    }
}

/// Ligne du tableau des baux d'une étendue (tableau standard « outils.dhcp.baux »).
struct DHCPScopeEntryRow: Identifiable {
    let entry: DHCPScopeEntry
    /// Appareil du dernier scan (même MAC, sinon même adresse).
    let device: Device?
    var id: String { entry.id }

    var name: String { entry.hostname ?? device?.hostnameLabel ?? "—" }
    var vendor: String? { entry.mac.flatMap { OUIDatabase.builtIn.vendor(for: $0) } ?? device?.vendor }

    var navRef: NavDeviceRef {
        if let device { return NavDeviceRef(device) }
        return NavDeviceRef(ip: entry.ip.description, mac: entry.mac?.formatted(.upperColon), name: entry.hostname ?? "")
    }

    var sortIP: IPv4Address { entry.ip }
    var sortName: String { name == "—" ? "~" : SearchText.fold(name) }
    var sortMAC: String { entry.mac?.description ?? "~" }
    var sortKind: String { entry.kind.label }
    var sortExpiry: Date { entry.expires ?? .distantFuture }
    var sortDevice: String { device.map { SearchText.fold($0.displayName) } ?? "~" }

    static func tone(_ kind: DHCPScopeEntry.Kind) -> Tone {
        switch kind {
        case .lease, .seenOnline: return .neutral
        case .reservationInUse: return .accent
        case .reservationIdle: return .neutral
        case .reservationOutside, .outsideLease: return .warning
        }
    }

    /// « dans 42 min », « dans 5 h », « dans 3 j », « réservée », « — ».
    static func expiryText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "expiré" }
        if seconds < 3600 { return "dans \(max(1, Int((seconds / 60).rounded())))\u{00A0}min" }
        if seconds < 86_400 { return "dans \(Int(seconds / 3600))\u{00A0}h" }
        return "dans \(Int(seconds / 86_400))\u{00A0}j"
    }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ip", title: "Adresse IP", isRequired: true),
        StandardColumn(id: "nom", title: "Nom"),
        StandardColumn(id: "mac", title: "MAC · fabricant"),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "expire", title: "Expire"),
        StandardColumn(id: "appareil", title: "Appareil du scan"),
    ]

    static let sortKeys: [String: KeyPathComparator<DHCPScopeEntryRow>] = [
        "ip": KeyPathComparator(\DHCPScopeEntryRow.sortIP),
        "nom": KeyPathComparator(\DHCPScopeEntryRow.sortName),
        "mac": KeyPathComparator(\DHCPScopeEntryRow.sortMAC),
        "type": KeyPathComparator(\DHCPScopeEntryRow.sortKind),
        "expire": KeyPathComparator(\DHCPScopeEntryRow.sortExpiry),
        "appareil": KeyPathComparator(\DHCPScopeEntryRow.sortDevice),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<DHCPScopeEntryRow> {
        StandardTableModel(id: "outils.dhcp.baux", columns: columns, sortKeys: sortKeys, defaultSort: "ip")
    }
}
