import NetScopeCore
import SwiftUI

// Onglet « Ressources » de la fiche appareil (note 21) : ce Mac par lecture locale (processeur par
// cœur, mémoire et pression, réseau par interface), tout autre appareil par SNMP v2c en lecture
// (HOST-RESOURCES-MIB et MIB des constructeurs, trafic par port IF-MIB). Courbes des 5 dernières
// minutes, intervalle réglable, export CSV.

struct DeviceResourcesTab: View {
    @EnvironmentObject private var state: AppState
    let device: Device

    var body: some View {
        if Self.isThisMac(device, state: state) {
            LocalResourcesSection()
        } else {
            SNMPResourcesSection(device: device, monitor: ResourceMonitors.snmp(device.ip.description))
        }
    }

    /// L'appareil est-il ce Mac ? Son adresse est celle d'une interface locale (lecture getifaddrs).
    static func isThisMac(_ device: Device, state: AppState) -> Bool {
        if state.activeInterface?.address == device.ip { return true }
        if Launcher.isDemo { return false }
        return LocalInterfaces.list().contains { $0.address == device.ip }
    }
}

// MARK: - Ce Mac

private struct LocalResourcesSection: View {
    @ObservedObject private var monitor = LocalResourceMonitor.shared
    @State private var selectedInterface: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tiles
            AdaptiveStack(breakpoint: 760, spacing: 14, horizontalAlignment: .top) {
                cpuPanel
                memoryPanel
            }
            interfacesPanel
        }
        .onAppear { monitor.retain() }
        .onDisappear { monitor.release() }
    }

    private var header: some View {
        ResourceHeader(symbol: "desktopcomputer", title: "Ce Mac",
                       subtitle: "Lecture locale (host_statistics, sysctl) · aucun trafic réseau",
                       updated: monitor.lastSample, interval: $monitor.interval, choices: ResourceInterval.local,
                       isPaused: monitor.isPaused, onPause: monitor.togglePause, onExport: monitor.exportCSV,
                       canExport: !monitor.timeline.samples.isEmpty, toast: monitor.toast, window: monitor.timeline.window)
    }

    private var tiles: some View {
        ResourceTileRow {
            ResourceTile(title: "Processeur", value: ResourceFormat.percent(monitor.cpu?.total),
                         detail: monitor.cpu.map { "Utilisateur \(ResourceFormat.percent($0.user)) · Système \(ResourceFormat.percent($0.system))" } ?? "Premier relevé…",
                         tone: ResourceColors.tone(monitor.cpu?.total), spark: monitor.timeline.series("cpu"))
            ResourceTile(title: "Mémoire", value: ResourceFormat.percent(monitor.memory?.usedPercent),
                         detail: memoryDetail, tone: memoryTone, percent: monitor.memory?.usedPercent)
            let main = monitor.mainInterface
            ResourceTile(title: "Réseau", value: "↓\u{00A0}" + ResourceFormat.bitsPerSecond(main?.rate?.inBitsPerSecond),
                         detail: main.map { "↑\u{00A0}\(ResourceFormat.bitsPerSecond($0.rate?.outBitsPerSecond)) · \($0.name) \($0.kind)" } ?? "Aucune interface active",
                         spark: main.map { monitor.timeline.series("\($0.name).in") } ?? [])
        }
    }

    private var memoryDetail: String {
        guard let memory = monitor.memory else { return "—" }
        var text = "\(ResourceFormat.memory(memory.usedBytes)) / \(ResourceFormat.memory(memory.totalBytes))"
        if let pressure = memory.pressure { text += " · pression \(pressure.label.lowercased())" }
        return text
    }

    private var memoryTone: Tone {
        switch monitor.memory?.pressure {
        case .critical: return .critical
        case .warning: return .warning
        case .normal: return .success
        case nil: return ResourceColors.tone(monitor.memory?.usedPercent)
        }
    }

    private var cpuPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                ResourcePanelHeader(title: "Processeur", subtitle: coresSubtitle) {
                    Text("moy. \(ResourceFormat.percent(monitor.timeline.average("cpu")))").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                ResourceChart(series: [ResourceChartSeries(label: "Processeur", color: ResourceColors.primary, values: monitor.timeline.series("cpu"))],
                              maxValue: 100, axisLabel: { ResourceFormat.percent($0) }, span: monitor.timeline.window)
                if let cores = monitor.cpu?.perCore, !cores.isEmpty {
                    SectionHeader("Charge par cœur")
                    ResourceCoreBars(loads: cores, performanceCores: monitor.coreKinds?.performance)
                }
            }
        }
    }

    private var coresSubtitle: String {
        guard let count = monitor.cpu?.perCore.count else { return "" }
        if let kinds = monitor.coreKinds { return "\(count) cœurs · \(kinds.performance)\u{00A0}P + \(kinds.efficiency)\u{00A0}E" }
        return "\(count) cœurs"
    }

    private var memoryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                ResourcePanelHeader(title: "Mémoire", subtitle: monitor.memory.map { ResourceFormat.memory($0.totalBytes) + " installés" } ?? "") {
                    if let pressure = monitor.memory?.pressure {
                        Chip(text: "Pression " + pressure.label.lowercased(), tone: memoryTone)
                    }
                }
                ResourceChart(series: [ResourceChartSeries(label: "Utilisée", color: ResourceColors.primary, values: monitor.timeline.series("mem")),
                                       ResourceChartSeries(label: "Pression", color: ResourceColors.secondary, values: monitor.timeline.series("pression"))],
                              maxValue: 100, axisLabel: { ResourceFormat.percent($0) }, span: monitor.timeline.window, filled: false)
                ResourceLegend(items: [("Mémoire utilisée", ResourceColors.primary), ("Pression mémoire", ResourceColors.secondary)])
                if let memory = monitor.memory {
                    VStack(spacing: 5) {
                        ResourceKeyValue(key: "Mémoire des apps", value: ResourceFormat.memory(memory.appBytes))
                        ResourceKeyValue(key: "Mémoire câblée", value: ResourceFormat.memory(memory.wiredBytes))
                        ResourceKeyValue(key: "Compressée", value: ResourceFormat.memory(memory.compressedBytes))
                        ResourceKeyValue(key: "Fichiers en cache", value: ResourceFormat.memory(memory.cachedBytes))
                        ResourceKeyValue(key: "Swap utilisé", value: ResourceFormat.memory(memory.swapUsedBytes))
                    }
                }
            }
        }
    }

    private var interfacesPanel: some View {
        let rows = monitor.interfaces.map(ResourceInterfaceRow.init(local:))
        let selected = rows.first { $0.id == selectedInterface } ?? rows.first
        return ResourceInterfacesPanel(title: "Réseau par interface",
                                       subtitle: "compteurs 64\u{00A0}bits du système",
                                       rows: rows, selection: Binding(get: { selected?.id }, set: { selectedInterface = $0 }),
                                       tableID: "appareil.ressources.mac", timeline: monitor.timeline,
                                       seriesKey: { $0 }, emptyText: "Aucune interface active.")
    }
}

// MARK: - Appareil SNMP

private struct SNMPResourcesSection: View {
    let device: Device
    @ObservedObject var monitor: SNMPResourceMonitor
    @State private var selectedPort: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ResourceHeader(symbol: device.deviceType.toolSymbol, title: "SNMP v2c · \(device.ip)", subtitle: sources,
                           updated: monitor.lastPoll, interval: $monitor.interval, choices: ResourceInterval.snmp,
                           isPaused: monitor.isPaused || !monitor.started, onPause: { monitor.started ? monitor.togglePause() : monitor.start() },
                           onExport: { monitor.exportCSV(name: "ressources-\(device.ip)") },
                           canExport: !monitor.timeline.samples.isEmpty, toast: monitor.toast, window: monitor.timeline.window, isBusy: monitor.isPolling)
            if !monitor.started {
                ToolNotice(tone: .accent, title: "Interrogation SNMP non lancée",
                           message: "\(device.displayName) n’a pas répondu en SNMP lors du dernier scan. NetScope peut tout de même l’interroger (SNMP v2c, lecture seule, communauté des Réglages › Identifiants).") {
                    Button("Interroger en SNMP") { monitor.start() }.buttonStyle(.primary).fixedSize()
                }
            }
            if let error = monitor.error {
                ToolNotice(tone: .critical, message: error)
            }
            if monitor.started || monitor.processor != nil {
                tiles
                AdaptiveStack(breakpoint: 760, spacing: 14, horizontalAlignment: .top) {
                    cpuPanel
                    memoryPanel
                }
                interfacesPanel
            }
        }
        .onAppear { monitor.retain(autoStart: device.snmpKind != nil) }
        .onDisappear { monitor.release() }
    }

    private var sources: String {
        var parts: [String] = []
        if let source = monitor.processor?.source { parts.append(source) }
        if let source = monitor.memory?.source, !parts.contains(source) { parts.append(source) }
        parts.append("IF-MIB")
        return "Lecture seule · " + parts.joined(separator: " · ")
    }

    private var totalRate: (Double, Double) {
        let up = monitor.loads.filter(\.isUp)
        return (up.compactMap(\.rate.inBitsPerSecond).reduce(0, +), up.compactMap(\.rate.outBitsPerSecond).reduce(0, +))
    }

    private var tiles: some View {
        ResourceTileRow {
            let load = monitor.processor?.load
            ResourceTile(title: "Processeur", value: ResourceFormat.percent(load?.total),
                         detail: load.map { $0.perCore.count > 1 ? "\($0.perCore.count) processeurs · moy. 1\u{00A0}min" : "Moyenne de la dernière minute" }
                            ?? (monitor.lastPoll == nil ? "Premier relevé…" : "Non fourni par l’agent"),
                         tone: ResourceColors.tone(load?.total), spark: monitor.timeline.series("cpu"))
            let memory = monitor.memory?.memory
            ResourceTile(title: "Mémoire", value: ResourceFormat.percent(memory?.usedPercent),
                         detail: memory.map { "\(ResourceFormat.memory($0.usedBytes)) / \(ResourceFormat.memory($0.totalBytes))" }
                            ?? (monitor.lastPoll == nil ? "Premier relevé…" : "Non fournie par l’agent"),
                         tone: ResourceColors.tone(memory?.usedPercent), percent: memory?.usedPercent)
            let rate = totalRate
            ResourceTile(title: "Trafic", value: "↓\u{00A0}" + ResourceFormat.bitsPerSecond(monitor.loads.isEmpty ? nil : rate.0),
                         detail: monitor.loads.isEmpty ? (monitor.lastPoll == nil ? "Premier relevé…" : "Deuxième relevé attendu pour le débit")
                            : "↑\u{00A0}\(ResourceFormat.bitsPerSecond(rate.1)) · " + MonText.plural(monitor.loads.filter(\.isUp).count, "interface active", "interfaces actives"),
                         spark: monitor.timeline.sum(suffix: ".in"))
        }
    }

    private var cpuPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                ResourcePanelHeader(title: "Processeur", subtitle: monitor.processor?.source ?? "") {
                    Text("moy. \(ResourceFormat.percent(monitor.timeline.average("cpu")))").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                ResourceChart(series: [ResourceChartSeries(label: "Processeur", color: ResourceColors.primary, values: monitor.timeline.series("cpu"))],
                              maxValue: 100, axisLabel: { ResourceFormat.percent($0) }, span: monitor.timeline.window)
                if let cores = monitor.processor?.load.perCore, cores.count > 1 {
                    SectionHeader("Charge par processeur (hrProcessorLoad)")
                    ResourceCoreBars(loads: cores)
                }
            }
        }
    }

    private var memoryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                ResourcePanelHeader(title: "Mémoire", subtitle: monitor.memory?.source ?? "")
                ResourceChart(series: [ResourceChartSeries(label: "Utilisée", color: ResourceColors.primary, values: monitor.timeline.series("mem"))],
                              maxValue: 100, axisLabel: { ResourceFormat.percent($0) }, span: monitor.timeline.window)
                if let memory = monitor.memory?.memory {
                    VStack(spacing: 5) {
                        ResourceKeyValue(key: "Utilisée", value: ResourceFormat.memory(memory.usedBytes))
                        ResourceKeyValue(key: "Totale", value: ResourceFormat.memory(memory.totalBytes))
                        if let cached = memory.cachedBytes {
                            ResourceKeyValue(key: "Cache et tampons (exclus)", value: ResourceFormat.memory(cached))
                        }
                    }
                }
            }
        }
    }

    private var interfacesPanel: some View {
        let rows: [ResourceInterfaceRow]
        if monitor.loads.isEmpty {
            rows = monitor.ports.filter { $0.isUp }.map { ResourceInterfaceRow(port: $0, load: nil) }
        } else {
            rows = monitor.loads.filter { $0.isUp }.map { ResourceInterfaceRow(port: nil, load: $0) }
        }
        let selected = rows.first { $0.id == selectedPort } ?? rows.max { ($0.peak ?? -1) < ($1.peak ?? -1) }
        return ResourceInterfacesPanel(title: "Trafic par interface",
                                       subtitle: "IF-MIB · " + MonText.plural(rows.count, "active", "actives") + (monitor.ports.first?.counters.width == .bits32 ? " · compteurs 32\u{00A0}bits" : ""),
                                       rows: rows, selection: Binding(get: { selected?.id }, set: { selectedPort = $0 }),
                                       tableID: "appareil.ressources.snmp", timeline: monitor.timeline,
                                       seriesKey: { "if\($0)" }, emptyText: monitor.lastPoll == nil ? "Premier relevé en cours…" : "Aucune interface active.")
    }
}

// MARK: - En-tête commun

private struct ResourceHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    let updated: Date?
    @Binding var interval: Double
    let choices: [Double]
    let isPaused: Bool
    let onPause: () -> Void
    let onExport: () -> Void
    let canExport: Bool
    let toast: ResourceToast?
    var window: TimeInterval = 300
    var isBusy = false

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        identity
                        Spacer(minLength: 8)
                        controls
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        identity
                        controls
                    }
                }
                if let toast {
                    ResourceToastText(toast: toast)
                }
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft)
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold)).fixedSize()
                    if isBusy { ProgressView().controlSize(.small) }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(subtitle + (updated.map { " · relevé " + ResourceHeader.ago($0, now: context.date) } ?? ""))
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ResourceIntervalMenu(interval: $interval, choices: choices)
            Button(action: onPause) {
                Label(isPaused ? "Reprendre" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.secondary)
            .help(isPaused ? "Reprendre les relevés" : "Suspendre les relevés (l’historique reste)")
            Button(action: onExport) {
                Label("Exporter CSV", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.secondary)
            .disabled(!canExport)
            .help("Enregistrer l’historique (\(ResourceTime.label(window)) au plus, CSV, séparateur «\u{00A0};\u{00A0}»)")
        }
        .fixedSize()
    }

    /// « à l'instant », « il y a 12 s », « à 14:32 ».
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 2 { return "à l’instant" }
        if seconds < 120 { return "il y a \(seconds)\u{00A0}s" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "à " + formatter.string(from: date)
    }
}

// MARK: - Tableau des interfaces et courbe de l'interface choisie

/// Ligne du tableau des interfaces (ce Mac ou agent SNMP).
struct ResourceInterfaceRow: Identifiable {
    var id: String
    /// Clé des séries de l'historique (« en0 », « 12 » pour if12).
    var seriesID: String
    var name: String
    var detail: String
    var inBps: Double?
    var outBps: Double?
    var inPercent: Double?
    var outPercent: Double?
    var speedMbps: UInt64?
    var inTotal: UInt64
    var outTotal: UInt64
    var errors: UInt64?
    var discards: UInt64?
    var newErrors: UInt64?

    var peak: Double? {
        switch (inPercent, outPercent) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    // Clés de tri
    var nameSort: String { name.lowercased() }
    var inSort: Double { inBps ?? -1 }
    var outSort: Double { outBps ?? -1 }
    var peakSort: Double { peak ?? max(inBps ?? -1, outBps ?? -1) / 1e12 }
    var speedSort: UInt64 { speedMbps ?? 0 }
    var errorsSort: UInt64 { errors ?? 0 }
    var discardsSort: UInt64 { discards ?? 0 }

    init(local: LocalInterfaceLoad) {
        id = local.name
        seriesID = local.name
        name = local.name
        detail = local.kind
        inBps = local.rate?.inBitsPerSecond
        outBps = local.rate?.outBitsPerSecond
        inPercent = local.rate?.inPercent
        outPercent = local.rate?.outPercent
        speedMbps = local.counters.speedMbps
        inTotal = local.counters.inOctets
        outTotal = local.counters.outOctets
        errors = local.counters.totalErrors
        discards = local.counters.totalDiscards
        newErrors = local.rate?.newErrors
    }

    init(port: SNMPPortCounters?, load: PortLoad?) {
        let index = load?.index ?? port?.index ?? 0
        let counters = load?.counters ?? port?.counters ?? TrafficCounters(inOctets: 0, outOctets: 0)
        id = String(index)
        seriesID = String(index)
        name = load?.name ?? port?.name ?? "if\(index)"
        detail = load?.alias ?? port?.alias ?? ""
        inBps = load?.rate.inBitsPerSecond
        outBps = load?.rate.outBitsPerSecond
        inPercent = load?.rate.inPercent
        outPercent = load?.rate.outPercent
        speedMbps = counters.speedMbps
        inTotal = counters.inOctets
        outTotal = counters.outOctets
        errors = counters.totalErrors
        discards = counters.totalDiscards
        newErrors = load?.rate.newErrors
    }
}

private struct ResourceInterfacesPanel: View {
    let title: String
    let subtitle: String
    let rows: [ResourceInterfaceRow]
    @Binding var selection: String?
    let tableID: String
    let timeline: ResourceTimeline
    /// Préfixe des séries d'une ligne (« en0 » → « en0.in »).
    let seriesKey: (String) -> String
    let emptyText: String

    @StateObject private var table: StandardTableModel<ResourceInterfaceRow>

    init(title: String, subtitle: String, rows: [ResourceInterfaceRow], selection: Binding<String?>, tableID: String,
         timeline: ResourceTimeline, seriesKey: @escaping (String) -> String, emptyText: String) {
        self.title = title
        self.subtitle = subtitle
        self.rows = rows
        _selection = selection
        self.tableID = tableID
        self.timeline = timeline
        self.seriesKey = seriesKey
        self.emptyText = emptyText
        _table = StateObject(wrappedValue: StandardTableModel(id: tableID, columns: Self.columns, sortKeys: Self.sortKeys,
                                                              defaultSort: "charge", defaultAscending: false))
    }

    static let rowHeight: CGFloat = 28
    static let maxRows = 10

    static let columns: [StandardColumn] = [
        StandardColumn(id: "interface", title: "Interface", isRequired: true),
        StandardColumn(id: "entree", title: "Entrée"),
        StandardColumn(id: "sortie", title: "Sortie"),
        StandardColumn(id: "charge", title: "Charge du lien"),
        StandardColumn(id: "vitesse", title: "Vitesse"),
        StandardColumn(id: "erreurs", title: "Erreurs"),
        StandardColumn(id: "rejets", title: "Rejets", isDefaultVisible: false),
        StandardColumn(id: "recu", title: "Total reçu", isDefaultVisible: false),
        StandardColumn(id: "envoye", title: "Total envoyé", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<ResourceInterfaceRow>] = [
        "interface": KeyPathComparator(\ResourceInterfaceRow.nameSort),
        "entree": KeyPathComparator(\ResourceInterfaceRow.inSort),
        "sortie": KeyPathComparator(\ResourceInterfaceRow.outSort),
        "charge": KeyPathComparator(\ResourceInterfaceRow.peakSort),
        "vitesse": KeyPathComparator(\ResourceInterfaceRow.speedSort),
        "erreurs": KeyPathComparator(\ResourceInterfaceRow.errorsSort),
        "rejets": KeyPathComparator(\ResourceInterfaceRow.discardsSort),
        "recu": KeyPathComparator(\ResourceInterfaceRow.inTotal),
        "envoye": KeyPathComparator(\ResourceInterfaceRow.outTotal),
    ]

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder + [KeyPathComparator(\ResourceInterfaceRow.nameSort)])
        let current = rows.first { $0.id == selection }
        VStack(alignment: .leading, spacing: 0) {
            ResourcePanelHeader(title: title, subtitle: subtitle) {
                StandardColumnsMenu(model: table, compact: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                Text(emptyText).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                tableView(sorted)
                    .standardTableHeight(rows: sorted.count, rowHeight: Self.rowHeight, maxRows: Self.maxRows)
                if let current {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    chart(current).padding(16)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }

    private func tableView(_ rows: [ResourceInterfaceRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("INTERFACE"), sortUsing: table.sort("interface")) { row in
                HStack(spacing: 6) {
                    Text(row.name).font(Theme.mono(12, weight: .semibold)).lineLimit(1).fixedSize()
                    if !row.detail.isEmpty {
                        Text(row.detail).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                .help(row.detail)
            }
            .width(min: 110, ideal: 150)
            .customizationID("interface")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(StandardTableHeading("ENTRÉE"), sortUsing: table.sort("entree")) { row in
                Text("↓\u{00A0}" + ResourceFormat.bitsPerSecond(row.inBps)).font(Theme.mono(12)).lineLimit(1)
            }
            .width(min: 84, ideal: 96)
            .customizationID("entree")

            TableColumn(StandardTableHeading("SORTIE"), sortUsing: table.sort("sortie")) { row in
                Text("↑\u{00A0}" + ResourceFormat.bitsPerSecond(row.outBps)).font(Theme.mono(12)).lineLimit(1)
            }
            .width(min: 84, ideal: 96)
            .customizationID("sortie")

            TableColumn(StandardTableHeading("CHARGE DU LIEN"), sortUsing: table.sort("charge")) { row in
                HStack(spacing: 6) {
                    ResourceBar(percent: row.peak, height: 5).frame(minWidth: 40)
                    Text(ResourceFormat.percent(row.peak)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).frame(width: 56, alignment: .trailing)
                }
                .help("Entrée \(ResourceFormat.percent(row.inPercent)) · sortie \(ResourceFormat.percent(row.outPercent))")
            }
            .width(min: 116, ideal: 130)
            .customizationID("charge")

            TableColumn(StandardTableHeading("VITESSE"), sortUsing: table.sort("vitesse")) { row in
                Text(SNMPFormat.speed(mbps: row.speedMbps)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 64, ideal: 70)
            .customizationID("vitesse")

            TableColumn(StandardTableHeading("ERREURS"), sortUsing: table.sort("erreurs")) { row in
                let fresh = (row.newErrors ?? 0) > 0
                Text(row.errors.map { ToolFormat.integer($0) } ?? "—")
                    .font(Theme.mono(12, weight: fresh ? .semibold : .regular))
                    .foregroundStyle(fresh ? Theme.critical : Theme.textSecondary)
                    .help(fresh ? "\(row.newErrors ?? 0) nouvelle(s) depuis le relevé précédent" : "Erreurs cumulées (entrée et sortie)")
            }
            .width(min: 54, ideal: 60)
            .customizationID("erreurs")

            TableColumn(StandardTableHeading("REJETS"), sortUsing: table.sort("rejets")) { row in
                Text(row.discards.map { ToolFormat.integer($0) } ?? "—").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
            .width(min: 50, ideal: 56)
            .customizationID("rejets")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("TOTAL REÇU"), sortUsing: table.sort("recu")) { row in
                Text(SNMPFormat.bytes(row.inTotal)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
            .width(min: 70, ideal: 84)
            .customizationID("recu")
            .defaultVisibility(.hidden)

            TableColumn(StandardTableHeading("TOTAL ENVOYÉ"), sortUsing: table.sort("envoye")) { row in
                Text(SNMPFormat.bytes(row.outTotal)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
            .width(min: 70, ideal: 84)
            .customizationID("envoye")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
    }

    private func chart(_ row: ResourceInterfaceRow) -> some View {
        let key = seriesKey(row.seriesID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.name).font(Theme.mono(12, weight: .semibold))
                Text("Historique de \(ResourceTime.label(timeline.window))" + (row.speedMbps.map { " · lien \(SNMPFormat.speed(mbps: $0))" } ?? ""))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 6)
                ResourceLegend(items: [("Entrée", ResourceColors.primary), ("Sortie", ResourceColors.secondary)])
            }
            ResourceChart(series: [ResourceChartSeries(label: "Entrée", color: ResourceColors.primary, values: timeline.series("\(key).in")),
                                   ResourceChartSeries(label: "Sortie", color: ResourceColors.secondary, values: timeline.series("\(key).out"))],
                          axisLabel: { ResourceFormat.bitsPerSecond($0) }, span: timeline.window, height: 110, filled: false)
        }
    }
}
