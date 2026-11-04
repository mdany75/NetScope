import NetScopeCore
import SwiftUI

/// Filtre de la liste des sondes.
enum MonProbeFilter: String, CaseIterable {
    case all, warning, down, paused

    var title: String {
        switch self {
        case .all: return "Toutes"
        case .warning: return "En alerte"
        case .down: return "Hors ligne"
        case .paused: return "Inactives"
        }
    }

    var dot: Color? {
        switch self {
        case .all: return nil
        case .warning: return Theme.warning
        case .down: return Theme.critical
        case .paused: return Theme.textTertiary
        }
    }
}

/// Une ligne du tableau des sondes : la sonde et ce que le moteur en sait, figés au moment de
/// l'affichage (le tri porte sur ces valeurs).
struct MonProbeLine: Identifiable {
    let probe: MonProbe
    let state: MonState?
    let value: String
    let slots: [MonSlot]
    let availability: Double?
    let latency: Double?
    let lastCheck: Date?
    let lastOutage: Date?
    /// Rang de la sonde dans la liste enregistrée (ordre du croquis, tri par défaut).
    let order: Int

    var id: UUID { probe.id }

    @MainActor
    init(probe: MonProbe, order: Int, store: MonStore, now: Date) {
        self.probe = probe
        self.order = order
        state = store.state(of: probe)
        value = store.lastValue(of: probe)
        slots = store.history.slots(probe: probe.id, now: now)
        availability = store.history.availability(probe: probe.id, now: now)
        let result = store.trackers[probe.id]?.lastResult
        latency = result?.latencyMs
        lastCheck = result?.date
        lastOutage = store.journal.alerts
            .filter { $0.probeID == probe.id && $0.severity == .critical }
            .map(\.date).max()
    }

    /// « 10.182.122.1 · FortiGate-60F », « intranet.local @ 10.182.122.1 ».
    var targetLabel: String {
        var label = probe.target.isEmpty ? "[À COMPLÉTER]" : probe.target
        if probe.kind == .dns, let server = probe.dnsServer, !server.isEmpty { label += " @ \(server)" }
        if !probe.subtitle.isEmpty { label += " · \(probe.subtitle)" }
        return label
    }

    /// « 50 ms · 5 % · 3 échecs ».
    var thresholdsLabel: String {
        let thresholds = probe.thresholds
        var parts: [String] = []
        if let latency = thresholds.latencyMs { parts.append("\(MonFormat.number(latency))\u{00A0}ms") }
        if let loss = thresholds.lossPercent { parts.append(MonFormat.percent(loss)) }
        parts.append("\(thresholds.failures)\u{00A0}\(thresholds.failures > 1 ? "échecs" : "échec")")
        return parts.joined(separator: " · ")
    }

    /// « macOS + son », « macOS », « Aucune ».
    var notifyLabel: String {
        guard probe.notify else { return "Aucune" }
        return probe.sound ? "macOS + son" : "macOS"
    }

    // MARK: Clés de tri (toujours Comparable)

    var sortActive: Int { probe.isEnabled ? 0 : 1 }
    var sortName: String { probe.name }
    var sortTarget: String { probe.target }
    var sortKind: String { probe.kind.shortLabel }
    var sortInterval: Int { probe.interval }
    /// Les pannes d'abord, puis les alertes, l'attente, les sondes OK, enfin les inactives.
    var sortState: Int {
        switch state {
        case .down: return 0
        case .warning: return 1
        case .pending: return 2
        case .ignored: return 3
        case .ok: return 4
        case nil: return 5
        }
    }
    /// Dernière valeur : par latence quand il y en a une, sinon après, par état.
    var sortValue: Double { latency ?? 1e9 + Double(sortState) }
    var sortLatency: Double { latency ?? .greatestFiniteMagnitude }
    var sortAvailability: Double { availability ?? -1 }
    var sortLastCheck: Date { lastCheck ?? .distantPast }
    var sortLastOutage: Date { lastOutage ?? .distantPast }
    var sortThresholds: Double { probe.thresholds.latencyMs ?? .greatestFiniteMagnitude }
    var sortNotify: Int { probe.notify ? (probe.sound ? 0 : 1) : 2 }
    var sortSchedule: String { probe.schedule.label }
    var sortCondition: String { probe.conditionSummary }
}

/// Panneau « Sondes » : filtres, recherche, tableau standard (note 8) et légende.
struct MonProbeTable: View {
    @ObservedObject private var store = MonStore.shared
    @State private var filter: MonProbeFilter = .all
    @State private var query = ""
    @StateObject private var table = StandardTableModel<MonProbeLine>(
        id: "surveillance.sondes", columns: MonProbeTable.columns, sortKeys: MonProbeTable.sortKeys,
        defaultSort: "ordre")

    /// Hauteur d'une ligne (croquis : 40) et de l'en-tête du tableau ; au-delà de `maxRows`
    /// lignes, le tableau défile.
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 36
    static let maxRows = 14

    static let columns: [StandardColumn] = [
        StandardColumn(id: "actif", title: "Actif"),
        StandardColumn(id: "sonde", title: "Sonde · cible", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "intervalle", title: "Intervalle"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "valeur", title: "Dernière valeur"),
        StandardColumn(id: "disponibilite", title: "Disponibilité 24 h"),
        StandardColumn(id: "cible", title: "Cible", isDefaultVisible: false),
        StandardColumn(id: "latence", title: "Latence", isDefaultVisible: false),
        StandardColumn(id: "dernierControle", title: "Dernier contrôle", isDefaultVisible: false),
        StandardColumn(id: "seuils", title: "Seuils", isDefaultVisible: false),
        StandardColumn(id: "notifications", title: "Notifications", isDefaultVisible: false),
        StandardColumn(id: "dernierePanne", title: "Dernière panne", isDefaultVisible: false),
        StandardColumn(id: "plage", title: "Plage horaire", isDefaultVisible: false),
        StandardColumn(id: "condition", title: "Condition", isDefaultVisible: false),
    ]

    /// « ordre » : ordre de la liste enregistrée, sans colonne (aucune flèche dans l’en-tête).
    static let sortKeys: [String: KeyPathComparator<MonProbeLine>] = [
        "ordre": KeyPathComparator(\MonProbeLine.order),
        "actif": KeyPathComparator(\MonProbeLine.sortActive),
        "sonde": KeyPathComparator(\MonProbeLine.sortName),
        "type": KeyPathComparator(\MonProbeLine.sortKind),
        "intervalle": KeyPathComparator(\MonProbeLine.sortInterval),
        "etat": KeyPathComparator(\MonProbeLine.sortState),
        "valeur": KeyPathComparator(\MonProbeLine.sortValue),
        "disponibilite": KeyPathComparator(\MonProbeLine.sortAvailability),
        "cible": KeyPathComparator(\MonProbeLine.sortTarget),
        "latence": KeyPathComparator(\MonProbeLine.sortLatency),
        "dernierControle": KeyPathComparator(\MonProbeLine.sortLastCheck),
        "seuils": KeyPathComparator(\MonProbeLine.sortThresholds),
        "notifications": KeyPathComparator(\MonProbeLine.sortNotify),
        "dernierePanne": KeyPathComparator(\MonProbeLine.sortLastOutage),
        "plage": KeyPathComparator(\MonProbeLine.sortSchedule),
        "condition": KeyPathComparator(\MonProbeLine.sortCondition),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            let probes = filtered
            if probes.isEmpty {
                Text(store.probes.isEmpty ? "Aucune sonde. Créez-en une avec «\u{00A0}Nouvelle sonde\u{00A0}»."
                                          : "Aucune sonde ne correspond aux filtres actifs.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let now = store.now
                    let rows = probes.enumerated().map { MonProbeLine(probe: $1, order: $0, store: store, now: now) }
                        .sorted(using: table.sortOrder)
                    MonProbeGrid(rows: rows, table: table)
                        .frame(height: Self.headerHeight + Self.rowHeight * CGFloat(min(rows.count, Self.maxRows)))
                        .scrollDisabled(rows.count <= Self.maxRows)
                }
            }
            footer
        }
        .monPanel()
    }

    private var filtered: [MonProbe] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.probes.filter { probe in
            switch filter {
            case .all: break
            case .warning: if store.state(of: probe) != .warning { return false }
            case .down: if store.state(of: probe) != .down { return false }
            case .paused: if probe.isEnabled { return false }
            }
            guard !q.isEmpty else { return true }
            let text = [probe.name, probe.target, probe.subtitle, probe.kind.label, probe.kind.shortLabel].joined(separator: " ")
            return text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func count(_ filter: MonProbeFilter) -> Int {
        switch filter {
        case .all: return store.probes.count
        case .warning: return store.warningCount
        case .down: return store.downCount
        case .paused: return store.pausedCount
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            MonHeading("Sondes").padding(.trailing, 6)
            ForEach(MonProbeFilter.allCases, id: \.self) { item in
                MonFilterChip(title: item.title, count: count(item), dot: item.dot, isOn: filter == item) { filter = item }
            }
            Spacer(minLength: 8)
            StandardColumnsMenu(model: table)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                TextField("", text: $query, prompt: Text("Nom, IP, type…").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.small)
            }
            .padding(.horizontal, 8)
            .frame(width: 160, height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            legend(Theme.success, "Disponible")
            legend(Theme.warning, "Seuil dépassé")
            legend(Theme.critical, "Hors ligne")
            legend(Theme.border, "Aucune donnée", stroke: true)
            Spacer(minLength: 8)
            Text("\(filtered.count) affichées sur \(MonText.plural(store.probes.count, "sonde", "sondes"))")
                .lineLimit(1)
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Theme.panelMuted)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func legend(_ color: Color, _ text: String, stroke: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color)
                .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(stroke ? Theme.borderStrong : .clear))
                .frame(width: 8, height: 10)
            Text(text).lineLimit(1).fixedSize()
        }
    }
}

/// Tableau des sondes : la ligne choisie s'ouvre dans l'éditeur ; clic droit : tester, suspendre.
private struct MonProbeGrid: View {
    @ObservedObject private var store = MonStore.shared
    let rows: [MonProbeLine]
    @ObservedObject var table: StandardTableModel<MonProbeLine>

    /// Hauteur du contenu d'une cellule (la ligne fait 40 avec les marges du tableau).
    static let cellHeight: CGFloat = 32

    private var selection: Binding<UUID?> {
        Binding(get: { store.selectedProbe?.id },
                set: { id in
                    guard let id else { return }
                    store.selectedID = id
                    store.toast = nil
                })
    }

    var body: some View {
        Table(rows, selection: selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(SuiviTableHeading("ACTIF"), sortUsing: table.sort("actif")) { line in
                    MonSwitch(isOn: Binding(get: { line.probe.isEnabled }, set: { store.setEnabled($0, for: line.id) }),
                              label: "Sonde \(line.probe.name) active")
                        .frame(height: Self.cellHeight)
                }
                .width(min: 44, ideal: 44, max: 64)
                .customizationID("actif")

                TableColumn(SuiviTableHeading("SONDE · CIBLE"), sortUsing: table.sort("sonde")) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.probe.name)
                            .font(Theme.bodySemibold)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(line.targetLabel)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(height: Self.cellHeight)
                    .help("\(line.probe.name)\n\(line.targetLabel)")
                    .monInactive(line)
                }
                .width(min: 110, ideal: 138)
                .customizationID("sonde")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(SuiviTableHeading("TYPE"), sortUsing: table.sort("type")) { line in
                    Text(line.probe.kind.shortLabel)
                        .font(Theme.captionSemibold)
                        .foregroundStyle(Theme.neutralText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.neutralSoft))
                        .fixedSize()
                        .help(line.probe.kind.label)
                        .monInactive(line)
                }
                .width(min: 56, ideal: 64)
                .customizationID("type")

                TableColumn(SuiviTableHeading("INTERVALLE"), sortUsing: table.sort("intervalle")) { line in
                    MonCellText(MonProbe.intervalLabel(line.probe.interval), mono: true).monInactive(line)
                }
                .width(min: 60, ideal: 76)
                .customizationID("intervalle")

                TableColumn(SuiviTableHeading("ÉTAT"), sortUsing: table.sort("etat")) { line in
                    RegPill(text: MonText.label(line.state), tone: MonText.tone(line.state)).monInactive(line)
                }
                .width(min: 60, ideal: 62)
                .customizationID("etat")

                TableColumn(SuiviTableHeading("DERNIÈRE VALEUR"), sortUsing: table.sort("valeur")) { line in
                    let alert = line.state == .down || line.state == .warning
                    Text(line.value)
                        .font(Theme.mono(11, weight: alert ? .semibold : .regular))
                        .foregroundStyle(line.state == .down ? Theme.critical : line.state == .warning ? Theme.warning : Theme.text)
                        .lineLimit(2)
                        .frame(height: Self.cellHeight, alignment: .leading)
                        .help(line.value)
                        .monInactive(line)
                }
                .width(min: 90, ideal: 120)
                .customizationID("valeur")

                TableColumn(SuiviTableHeading("DISPONIBILITÉ 24 H"), sortUsing: table.sort("disponibilite")) { line in
                    MonUptimeBar(slots: line.slots, availability: line.availability,
                                 enabled: line.probe.isEnabled, name: line.probe.name)
                        .monInactive(line)
                }
                .width(min: 168, ideal: 170)
                .customizationID("disponibilite")
            }

            Group {
                TableColumn(SuiviTableHeading("CIBLE"), sortUsing: table.sort("cible")) { line in
                    MonCellText(line.probe.target.isEmpty ? "—" : line.probe.target, mono: true,
                                dimmed: line.probe.target.isEmpty)
                        .help(line.targetLabel)
                        .monInactive(line)
                }
                .width(min: 90, ideal: 130)
                .customizationID("cible")
                .defaultVisibility(.hidden)

                TableColumn(SuiviTableHeading("LATENCE"), sortUsing: table.sort("latence")) { line in
                    MonCellText(line.latency.map { ToolFormat.decimal($0) + "\u{00A0}ms" } ?? "—", mono: true,
                                dimmed: line.latency == nil)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .monInactive(line)
                }
                .width(min: 60, ideal: 72)
                .customizationID("latence")
                .defaultVisibility(.hidden)

                TableColumn(SuiviTableHeading("DERNIER CONTRÔLE"), sortUsing: table.sort("dernierControle")) { line in
                    MonCellText(line.lastCheck.map { MonJournal.timestamp($0, now: store.now) } ?? "—", mono: true,
                                dimmed: line.lastCheck == nil)
                        .monInactive(line)
                }
                .width(min: 100, ideal: 150)
                .customizationID("dernierControle")
                .defaultVisibility(.hidden)

                TableColumn(SuiviTableHeading("SEUILS"), sortUsing: table.sort("seuils")) { line in
                    MonCellText(line.thresholdsLabel, mono: true)
                        .help("Latence, perte et échecs consécutifs avant la panne")
                        .monInactive(line)
                }
                .width(min: 90, ideal: 120)
                .customizationID("seuils")
                .defaultVisibility(.hidden)

                TableColumn(SuiviTableHeading("NOTIFICATIONS"), sortUsing: table.sort("notifications")) { line in
                    MonCellText(line.notifyLabel, dimmed: !line.probe.notify).monInactive(line)
                }
                .width(min: 70, ideal: 100)
                .customizationID("notifications")
                .defaultVisibility(.hidden)

                TableColumn(SuiviTableHeading("DERNIÈRE PANNE"), sortUsing: table.sort("dernierePanne")) { line in
                    MonCellText(line.lastOutage.map { MonJournal.timestamp($0, now: store.now) } ?? "—", mono: true,
                                dimmed: line.lastOutage == nil)
                        .monInactive(line)
                }
                .width(min: 100, ideal: 150)
                .customizationID("dernierePanne")
                .defaultVisibility(.hidden)

                TableColumn(SuiviTableHeading("PLAGE HORAIRE"), sortUsing: table.sort("plage")) { line in
                    MonCellText(line.probe.schedule.label).help(line.probe.schedule.label).monInactive(line)
                }
                .width(min: 90, ideal: 160)
                .customizationID("plage")
                .defaultVisibility(.hidden)

                TableColumn(SuiviTableHeading("CONDITION"), sortUsing: table.sort("condition")) { line in
                    let condition = line.probe.conditionSummary
                    MonCellText(condition.isEmpty ? "—" : condition, dimmed: condition.isEmpty)
                        .help(condition)
                        .monInactive(line)
                }
                .width(min: 90, ideal: 180)
                .customizationID("condition")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let probe = store.probe(id) {
                Button("Tester maintenant") { store.testNow(id) }
                Button(probe.isEnabled ? "Suspendre la sonde" : "Reprendre la sonde") {
                    store.setEnabled(!probe.isEnabled, for: id)
                }
            }
        }
    }
}

/// Texte d'une cellule des tableaux de la surveillance (une ligne, tronqué).
struct MonCellText: View {
    let text: String
    var mono = false
    var dimmed = false
    var size: CGFloat = 12

    init(_ text: String, mono: Bool = false, dimmed: Bool = false, size: CGFloat = 12) {
        self.text = text
        self.mono = mono
        self.dimmed = dimmed
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(mono ? Theme.mono(size) : .system(size: size))
            .foregroundStyle(dimmed ? Theme.textTertiary : Theme.neutralText)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private extension View {
    /// Sonde inactive : contenu estompé (croquis : opacité 0,62).
    func monInactive(_ line: MonProbeLine) -> some View {
        opacity(line.probe.isEnabled ? 1 : 0.62)
    }
}

/// Barre de disponibilité 24 h : une case par heure, puis le pourcentage.
struct MonUptimeBar: View {
    let slots: [MonSlot]
    let availability: Double?
    var enabled = true
    var name = ""

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(enabled ? color(slot) : Theme.borderStrong)
                        .frame(width: 3, height: 14)
                }
            }
            Text(label)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.neutralText)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disponibilité sur 24 h de \(name) : \(label)")
    }

    private var label: String {
        guard let availability else { return "—" }
        return ToolFormat.decimal(availability) + "\u{00A0}%"
    }

    private func color(_ slot: MonSlot) -> Color {
        switch slot {
        case .ok: return Theme.success
        case .warning: return Theme.warning
        case .down: return Theme.critical
        case .none: return Theme.border
        }
    }
}

/// Petit interrupteur du croquis (30 × 18), accent quand actif.
struct MonSwitch: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Color(hex: 0x9CA3AF))
                Circle().fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "activée" : "désactivée")
    }
}
