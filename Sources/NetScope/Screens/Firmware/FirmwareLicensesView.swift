import NetScopeCore
import SwiftUI

/// Outil « Firmware et licences » (note 41), pleine largeur dans la Boîte à outils : par site,
/// versions FortiOS, FortiSwitch et FortiAP (version disponible, « à jour », « mise à jour
/// disponible », « inconnu »), contrats FortiGuard et FortiCare avec leur date d'expiration et les
/// jours restants (orange à 60 jours, rouge à 30) ; plusieurs ou tous les sites par le menu
/// « Site ▾ ». Lecture seule : NetScope ne lance jamais de mise à jour.
struct FirmwareLicensesView: View {
    /// Écran qui retient le choix des sites du menu « Site ▾ ».
    var scopeScreen: Screen = .outils

    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FirmwareStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @ObservedObject private var scopes = SiteScopeStore.shared
    @ObservedObject private var sites = SiteModel.shared
    /// Observé pour que « Ajouter au rapport » passe tout de suite à « Dans le rapport ».
    @ObservedObject private var rapport = RapportModel.shared
    @StateObject private var siteTable = FirmwareSiteRow.makeModel()
    @StateObject private var deviceTable = FirmwareDeviceRow.makeModel()
    @StateObject private var licenseTable = FirmwareLicenseRow.makeModel()
    @State private var siteSelection: UUID?
    @State private var licenseSelection: String?
    @State private var warningText: String?
    @State private var criticalText: String?
    /// Petite fenêtre : tableaux à colonnes réduites.
    @State private var isCompact = false

    /// Sous cette largeur, les huit colonnes des équipements ne tiennent plus : tableaux réduits.
    static let compactWidth: CGFloat = 820

    var body: some View {
        let ids = store.controllerIDs(forSiteKeys: scopes.keys(for: scopeScreen), state: state)
        let overview = store.overview(ids)
        VStack(alignment: .leading, spacing: 14) {
            controls(ids, overview: overview)
            ForEach(store.errorList(ids), id: \.site) { item in
                ToolNotice(tone: .critical, title: "\(item.site)\u{00A0}: lecture du firmware et des licences impossible", message: item.message)
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
                deviceTableView(overview)
                if let device = selectedDevice(overview) { deviceDetail(device, overview: overview) }
                licenseTableView(overview)
                Text("Lecture seule (GET)\u{00A0}: NetScope montre les versions et les contrats, il ne lance jamais de mise à jour ni de renouvellement.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: ids) { store.readIfNeeded(ids) }
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactWidth } action: { isCompact = $0 }
    }

    private func selectedDevice(_ overview: FirmwareOverview) -> FirmwareDevice? {
        overview.devices.first { $0.id == store.selectedDeviceID } ?? overview.outdated.first
    }

    // MARK: Contrôles

    private func controls(_ ids: [UUID], overview: FirmwareOverview) -> some View {
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

    private func siteField(_ ids: [UUID], overview: FirmwareOverview) -> some View {
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

    private func sourceText(_ ids: [UUID], overview: FirmwareOverview) -> String {
        guard !overview.isEmpty else { return ids.isEmpty ? "Aucune FortiGate pour ce site" : "Aucune lecture" }
        let names = overview.sites.map(\.site)
        let label = names.count > 2 ? "\(names.count) FortiGate" : names.joined(separator: ", ")
        return "FortiGate · \(label)" + (store.readDate(ids).map { " · lue \(ToolText.relative($0))" } ?? "")
    }

    private var thresholdFields: some View {
        HStack(alignment: .bottom, spacing: 8) {
            dayField("Orange à", text: $warningText, value: store.thresholds.warningDays, range: 1...730) { v in
                store.thresholds = FirmwareThresholds(warningDays: v, criticalDays: min(store.thresholds.criticalDays, v))
            }
            dayField("Rouge à", text: $criticalText, value: store.thresholds.criticalDays, range: 0...365) { v in
                store.thresholds = FirmwareThresholds(warningDays: max(store.thresholds.warningDays, v), criticalDays: v)
            }
        }
        .help("Jours avant l’expiration d’une licence\u{00A0}: orange, puis rouge")
    }

    private func dayField(_ label: String, text: Binding<String?>, value: Int, range: ClosedRange<Int>, apply: @escaping (Int) -> Void) -> some View {
        ToolLabeledField(label: label) {
            HStack(spacing: 4) {
                ToolTextField(placeholder: "\(value)", text: Binding(get: { text.wrappedValue ?? "\(value)" }, set: { typed in
                    text.wrappedValue = typed
                    guard let v = Int(typed.trimmingCharacters(in: .whitespaces)), range.contains(v) else { return }
                    apply(v)
                }), height: 28, onSubmit: { text.wrappedValue = nil })
                .frame(width: 48)
                Text("jours").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
            }
        }
        .fixedSize()
    }

    private func buttons(_ ids: [UUID]) -> some View {
        HStack(spacing: 8) {
            Button {
                store.addToReport()
            } label: {
                Label(store.isInReport ? "Dans le rapport" : "Ajouter au rapport", systemImage: store.isInReport ? "checkmark" : "doc.badge.plus")
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
            .help(store.canRead(ids) ? "Relit les versions et les licences (lecture seule, GET)"
                  : "Aucune FortiGate prête pour ces sites\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate.")
        }
        .fixedSize()
    }

    // MARK: Bilan

    private func empty(_ ids: [UUID]) -> some View {
        ToolNotice(tone: .accent, title: "Aucun firmware ni licence à montrer",
                   message: !fortigate.isConfigured
                   ? "Ajoutez la FortiGate du site dans Réglages › Switchs › Contrôleurs FortiGate pour lire les versions de FortiOS, des FortiSwitch et des FortiAP et les contrats FortiGuard, en lecture seule."
                   : (ids.isEmpty ? "Aucune FortiGate n’est associée aux sites affichés\u{00A0}: associez-la au site dans Réglages › Sites, ou choisissez d’autres sites dans le menu «\u{00A0}Site\u{00A0}»."
                      : "Relisez la FortiGate pour lire les versions installées et disponibles et les dates d’expiration des licences, en lecture seule."))
    }

    @ViewBuilder private func verdict(_ overview: FirmwareOverview) -> some View {
        let multi = overview.isMultiSite
        let licenses = overview.alertingLicenses
        let outdated = overview.outdated
        let texts = licenses.compactMap { u in FirmwareAnalysis.alertText(u).map { $0 + (multi ? " (\(u.site))" : "") } }
            + outdated.compactMap { d in FirmwareAnalysis.alertText(d).map { $0 + (multi ? " (\(d.site))" : "") } }
        if let first = texts.first {
            let critical = licenses.contains { $0.level >= .critical }
            let advice = licenses.first.map(FirmwareAnalysis.advice) ?? outdated.first.map(FirmwareAnalysis.advice) ?? ""
            let more = texts.dropFirst()
            ToolNotice(tone: critical ? .critical : .warning, title: first,
                       message: advice + (more.isEmpty ? "" : "\nAussi\u{00A0}: " + more.joined(separator: "\u{00A0}; ") + ".")) {
                if let d = outdated.first, licenses.isEmpty {
                    Button("Voir l’équipement") { store.selectedDeviceID = d.id }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
            }
        } else {
            ToolNotice(tone: .success, title: "Parc à jour",
                       message: "Aucune mise à jour disponible pour les équipements lus et aucune licence n’expire dans les \(store.thresholds.warningDays)\u{00A0}prochains jours.")
        }
    }

    private func tiles(_ overview: FirmwareOverview) -> some View {
        let devices = overview.devices
        let upToDate = devices.filter { $0.status == .upToDate }.count
        let unknown = devices.filter { $0.status == .unknown }.count
        let outdated = overview.outdated
        let alerting = overview.alertingLicenses
        let expired = alerting.filter { $0.level == .expired }.count
        let nearest = overview.licenses.filter { $0.level != .notLicensed && ($0.daysLeft ?? -1) >= 0 }
            .min { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
        let gates = devices.filter { $0.kind == .fortigate }
        let versions = Set(gates.map(\.versionLabel))
        let items: [(String, String, String, Color)] = [
            ("Équipements à jour", "\(upToDate)/\(devices.count)", unknown > 0 ? "\(unknown) inconnu\(unknown > 1 ? "s" : "")" : "tous évalués", Theme.text),
            ("Mises à jour", "\(outdated.count)", outdated.isEmpty ? "aucune disponible" : kindsText(outdated),
             outdated.isEmpty ? Theme.text : Theme.warning),
            ("Licences en alerte", "\(alerting.count)", expired > 0 ? "\(expired) expirée\(expired > 1 ? "s" : "")" : "sous \(store.thresholds.warningDays)\u{00A0}jours",
             alerting.contains { $0.level >= .critical } ? Theme.critical : (alerting.isEmpty ? Theme.text : Theme.warning)),
            ("Prochaine expiration", nearest?.daysLabel ?? "—", nearest.map { $0.license.label.components(separatedBy: " (").first! + (overview.isMultiSite ? " · \($0.site)" : "") } ?? "aucune date lue",
             nearest.map { FirmwareTone.color($0.level) } ?? Theme.text),
            ("FortiOS", versions.count == 1 ? versions.first! : "\(versions.count) versions", gates.count > 1 ? "\(gates.count) FortiGate" : (gates.first?.model ?? ""), Theme.text),
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

    /// « 1 FortiGate, 1 FortiAP ».
    private func kindsText(_ devices: [FirmwareDevice]) -> String {
        FirmwareDeviceKind.allCases.compactMap { kind in
            let n = devices.filter { $0.kind == kind }.count
            return n == 0 ? nil : "\(n) \(kind.label)"
        }.joined(separator: ", ")
    }

    // MARK: Tous les sites

    private func siteSummary(_ overview: FirmwareOverview) -> some View {
        let rows = overview.sites.map(FirmwareSiteRow.init).sorted(using: siteTable.sortOrder)
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
                    .width(min: 80, ideal: 150)
                    .customizationID("fortigate")
                    TableColumn("ÉQUIPEMENTS", sortUsing: siteTable.sort("equipements")) { row in
                        ToolTableText("\(row.summary.deviceCount)", alignment: .trailing)
                    }
                    .width(min: 60, ideal: 80)
                    .customizationID("equipements")
                    TableColumn("MISES À JOUR", sortUsing: siteTable.sort("majs")) { row in
                        ToolTableText(row.summary.updates == 0 ? "aucune" : "\(row.summary.updates) disponible\(row.summary.updates > 1 ? "s" : "")",
                                      mono: false, color: row.summary.updates > 0 ? Theme.warning : Theme.text)
                    }
                    .width(min: 70, ideal: 110)
                    .customizationID("majs")
                    TableColumn("PROCHAINE EXPIRATION", sortUsing: siteTable.sort("licence")) { row in
                        ToolTableText(row.summary.nearestDays.map { d in
                            (d < 0 ? "expirée depuis \(-d)\u{00A0}j" : "\(d)\u{00A0}j") + (row.summary.nearestLicense.map { " · \($0.components(separatedBy: " (").first!)" } ?? "")
                        } ?? "—", mono: false, color: row.summary.licenseLevel.map(FirmwareTone.color) ?? Theme.text)
                    }
                    .width(min: 90, ideal: 160)
                    .customizationID("licence")
                    TableColumn("LECTURE", sortUsing: siteTable.sort("lecture")) { row in
                        ToolTableText(ToolText.relative(row.summary.readAt), mono: false, color: Theme.textSecondary)
                    }
                    .width(min: 70, ideal: 100)
                    .customizationID("lecture")
                }
            }
        }
    }

    // MARK: Équipements

    private func deviceTableView(_ overview: FirmwareOverview) -> some View {
        let rows = overview.devices.enumerated().map { FirmwareDeviceRow(device: $0.element, order: $0.offset) }.sorted(using: deviceTable.sortOrder)
        let current = selectedDevice(overview)?.id
        let selection = Binding<String?>(get: { current }, set: { if let id = $0 { store.selectedDeviceID = id } })
        let multi = overview.isMultiSite
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Équipements · \(rows.count)")
                Spacer(minLength: 8)
                if !isCompact { ToolColumnsMenu(model: deviceTable) }
            }
            if isCompact {
                ToolStandardTableFrame(rowCount: rows.count, rowHeight: ToolTableMetrics.doubleRowHeight, maxRows: 8,
                                       emptyText: "Aucun équipement lu.") {
                    Table(rows, selection: selection, sortOrder: $deviceTable.sortOrder) {
                        TableColumn("ÉQUIPEMENT", sortUsing: deviceTable.sort("nom")) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.device.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(row.device.model + (multi ? " · \(row.device.site)" : ""))
                                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .width(min: 90, ideal: 130)
                        TableColumn("VERSION", sortUsing: deviceTable.sort("version")) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                ToolTableText(row.device.versionLabel, color: row.device.status == .updateAvailable ? Theme.warning : Theme.text)
                                ToolTableText(row.device.available.map { "→ \($0.short)" } ?? "", size: 11, color: Theme.textSecondary)
                            }
                        }
                        .width(min: 70, ideal: 90)
                        TableColumn("ÉTAT", sortUsing: deviceTable.sort("etat")) { row in
                            Chip(text: row.device.status == .updateAvailable ? "À mettre à jour" : row.device.status.label,
                                 tone: FirmwareTone.tone(row.device.status))
                        }
                        .width(min: 80, ideal: 110)
                    }
                }
            } else {
                ToolStandardTableFrame(rowCount: rows.count, maxRows: 12, emptyText: "Aucun équipement lu.") {
                    Table(rows, selection: selection, sortOrder: $deviceTable.sortOrder, columnCustomization: $deviceTable.customization) {
                        TableColumn("ÉQUIPEMENT", sortUsing: deviceTable.sort("nom")) { row in
                            // Hors ligne : nom en gris (version de la dernière connexion à la FortiGate).
                            Text(row.device.name).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(row.device.connected == false ? Theme.textSecondary : Theme.text).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(row.device.connected == false ? "Hors ligne\u{00A0}: version lue à sa dernière connexion" : row.device.name)
                        }
                        .width(min: 90, ideal: 116)
                        .customizationID("nom")
                        .disabledCustomizationBehavior(.visibility)
                        TableColumn("SITE", sortUsing: deviceTable.sort("site")) { row in
                            ToolTableText(row.device.site, mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 60, ideal: 76)
                        .customizationID("site")
                        TableColumn("TYPE", sortUsing: deviceTable.sort("type")) { row in
                            ToolTableText(row.device.kind.label, mono: false)
                        }
                        .width(min: 60, ideal: 68)
                        .customizationID("type")
                        TableColumn("MODÈLE", sortUsing: deviceTable.sort("modele")) { row in
                            ToolTableText(row.device.model.isEmpty ? "—" : row.device.model, mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 70, ideal: 88)
                        .customizationID("modele")
                        TableColumn("N° DE SÉRIE", sortUsing: deviceTable.sort("serie")) { row in
                            ToolTableText(row.device.serial.isEmpty ? "—" : row.device.serial, size: 11, color: Theme.textSecondary)
                        }
                        .width(min: 80, ideal: 112)
                        .customizationID("serie")
                        TableColumn("VERSION", sortUsing: deviceTable.sort("version")) { row in
                            ToolTableText(row.device.versionLabel, weight: row.device.status == .updateAvailable ? .semibold : .regular,
                                          color: row.device.status == .updateAvailable ? Theme.warning : Theme.text)
                                .help(row.device.versionText)
                        }
                        .width(min: 56, ideal: 66)
                        .customizationID("version")
                        TableColumn("DISPONIBLE", sortUsing: deviceTable.sort("disponible")) { row in
                            ToolTableText(row.device.availableLabel)
                                .help(row.device.source.map { "Source\u{00A0}: \($0.label)" } ?? (row.device.newerBranch.map { "Branche \($0.branch) disponible (\($0.short))" } ?? ""))
                        }
                        .width(min: 60, ideal: 80)
                        .customizationID("disponible")
                        TableColumn("ÉTAT", sortUsing: deviceTable.sort("etat")) { row in
                            Chip(text: row.device.status == .updateAvailable ? "À mettre à jour" : row.device.status.label,
                                 tone: FirmwareTone.tone(row.device.status))
                                .help(row.device.status.label)
                        }
                        .width(min: 80, ideal: 104)
                        .customizationID("etat")
                        TableColumn("SOURCE", sortUsing: deviceTable.sort("source")) { row in
                            ToolTableText(row.device.source?.label ?? "—", mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 70, ideal: 140)
                        .customizationID("source")
                        .defaultVisibility(.hidden)
                    }
                }
            }
        }
    }

    private func deviceDetail(_ device: FirmwareDevice, overview: FirmwareOverview) -> some View {
        let path = device.upgradePath.count > 1 ? ([device.version].compactMap { $0 } + device.upgradePath).map(\.short).joined(separator: " → ") : nil
        let cells: [ToolCell] = [
            ToolCell(key: "Version installée", value: device.versionLabel, detail: device.version?.build.map { "build \($0)" }),
            ToolCell(key: "Version disponible", value: device.availableLabel,
                     detail: device.available == nil ? (device.status == .upToDate ? "aucune plus récente" : "liste non lue") : device.availableMaturity),
            ToolCell(key: "Source", value: device.source.map { $0 == .fortiguard ? "FortiGuard" : ($0 == .parc ? "Parc" : "FortiGate") } ?? "—",
                     detail: device.source?.label),
            ToolCell(key: "Chemin de mise à jour", value: path ?? (device.available == nil ? "—" : "direct"),
                     detail: path == nil ? nil : "publié par FortiOS"),
            ToolCell(key: "Branche plus récente", value: device.newerBranch?.short ?? "—",
                     detail: device.newerBranch.map { "\($0.branch), à planifier séparément" }),
            ToolCell(key: "Numéro de série", value: device.serial.isEmpty ? "—" : device.serial, detail: device.model),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolFieldLabel("Détail · \(device.name)" + (overview.isMultiSite ? " · \(device.site)" : ""))
                Spacer(minLength: 8)
                Chip(text: device.status.label, tone: FirmwareTone.tone(device.status))
            }
            ToolCellGrid(cells: cells, columns: 3, valueSize: 13, minCellWidth: 140)
            if device.status == .updateAvailable {
                ToolNotice(tone: .neutral, title: "À planifier (NetScope ne lance pas la mise à jour)", message: FirmwareAnalysis.advice(device))
            }
        }
    }

    // MARK: Licences

    private func licenseTableView(_ overview: FirmwareOverview) -> some View {
        let rows = overview.licenses.enumerated().map { FirmwareLicenseRow(usage: $0.element, order: $0.offset) }.sorted(using: licenseTable.sortOrder)
        let multi = overview.isMultiSite
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_CA")
        f.dateFormat = "d MMM yyyy"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel("Licences FortiGuard et FortiCare · \(rows.count)")
                Spacer(minLength: 8)
                if !isCompact { ToolColumnsMenu(model: licenseTable) }
            }
            if isCompact {
                ToolStandardTableFrame(rowCount: rows.count, rowHeight: ToolTableMetrics.doubleRowHeight, maxRows: 10,
                                       emptyText: "Aucune licence lue.") {
                    Table(rows, selection: $licenseSelection, sortOrder: $licenseTable.sortOrder) {
                        TableColumn("SERVICE", sortUsing: licenseTable.sort("service")) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.usage.license.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text((row.usage.license.expires.map { f.string(from: $0) } ?? "sans date") + (multi ? " · \(row.usage.site)" : ""))
                                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .width(min: 100, ideal: 160)
                        TableColumn("JOURS", sortUsing: licenseTable.sort("jours")) { row in
                            ToolTableText(row.usage.daysLabel, weight: row.usage.level >= .warning ? .semibold : .regular,
                                          color: FirmwareTone.color(row.usage.level), alignment: .trailing)
                        }
                        .width(min: 50, ideal: 70)
                        TableColumn("ÉTAT", sortUsing: licenseTable.sort("etat")) { row in
                            Chip(text: FirmwareTone.chip(row.usage), tone: FirmwareTone.tone(row.usage.level))
                        }
                        .width(min: 80, ideal: 110)
                    }
                }
            } else {
                ToolStandardTableFrame(rowCount: rows.count, maxRows: 14, emptyText: "Aucune licence lue.") {
                    Table(rows, selection: $licenseSelection, sortOrder: $licenseTable.sortOrder, columnCustomization: $licenseTable.customization) {
                        TableColumn("SERVICE", sortUsing: licenseTable.sort("service")) { row in
                            ToolTableText(row.usage.license.label, mono: false, weight: .semibold)
                                .help(row.usage.license.key)
                        }
                        .width(min: 120, ideal: 220)
                        .customizationID("service")
                        .disabledCustomizationBehavior(.visibility)
                        TableColumn("SITE", sortUsing: licenseTable.sort("site")) { row in
                            ToolTableText(row.usage.site, mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 60, ideal: 110)
                        .customizationID("site")
                        TableColumn("ÉTAT", sortUsing: licenseTable.sort("etat")) { row in
                            Chip(text: FirmwareTone.chip(row.usage), tone: FirmwareTone.tone(row.usage.level))
                        }
                        .width(min: 80, ideal: 120)
                        .customizationID("etat")
                        TableColumn("DATE D’EXPIRATION", sortUsing: licenseTable.sort("expiration")) { row in
                            ToolTableText(row.usage.license.expires.map { f.string(from: $0) } ?? "—", mono: false, color: Theme.textSecondary)
                        }
                        .width(min: 80, ideal: 120)
                        .customizationID("expiration")
                        TableColumn("JOURS RESTANTS", sortUsing: licenseTable.sort("jours")) { row in
                            ToolTableText(row.usage.daysLabel, weight: row.usage.level >= .warning ? .semibold : .regular,
                                          color: FirmwareTone.color(row.usage.level), alignment: .trailing)
                        }
                        .width(min: 70, ideal: 110)
                        .customizationID("jours")
                        TableColumn("ÉTAT LU", sortUsing: licenseTable.sort("brut")) { row in
                            ToolTableText(row.usage.license.status ?? "—", size: 11, color: Theme.textSecondary)
                        }
                        .width(min: 70, ideal: 110)
                        .customizationID("brut")
                        .defaultVisibility(.hidden)
                        TableColumn("VERSION DE LA BASE", sortUsing: licenseTable.sort("base")) { row in
                            ToolTableText(row.usage.license.version ?? "—", size: 11, color: Theme.textSecondary)
                        }
                        .width(min: 70, ideal: 110)
                        .customizationID("base")
                        .defaultVisibility(.hidden)
                    }
                }
            }
            if let usage = overview.licenses.first(where: { $0.id == licenseSelection }), usage.level >= .warning,
               let text = FirmwareAnalysis.alertText(usage) {
                ToolNotice(tone: usage.level >= .critical ? .critical : .warning, title: text + (multi ? " (\(usage.site))" : ""),
                           message: FirmwareAnalysis.advice(usage))
            }
        }
    }
}
