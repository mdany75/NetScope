import Charts
import NetScopeCore
import SwiftUI

/// Onglet « Planifié » du Speedtest (note 78) : un test de débit Internet par jour et par site, à
/// l'heure choisie, avec seuil d'alerte, courbe sur 30 jours et tableau des sites.
struct SpeedScheduleView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: SpeedtestModel
    @ObservedObject private var store = SpeedScheduleStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @StateObject private var table = StandardTableModel<SpeedScheduleLine>(
        id: "speedtest.planifie", columns: SpeedScheduleView.columns, sortKeys: SpeedScheduleView.sortKeys,
        defaultSort: "site")

    var body: some View {
        let selected = store.selected
        let schedule = store.schedule(for: selected.id)
        let points = SpeedSchedulePlanner.dailySeries(model.history, siteID: selected.id, now: Date())
        VStack(spacing: 14) {
            SpeedScheduleEditor(store: store, model: model, site: selected, schedule: schedule)
                .id(selected.key)
            chartPanel(name: selected.name, schedule: schedule, points: points)
            tablePanel
        }
    }

    // MARK: Courbe

    private func chartPanel(name: String, schedule: SpeedSchedule, points: [SpeedDailyPoint]) -> some View {
        let summary = SpeedSchedulePlanner.summary(points, schedule: schedule)
        let peak = max(points.map(\.downMbps).max() ?? 0, schedule.minDownMbps ?? 0, points.compactMap(\.upMbps).max() ?? 0)
        let top = SpeedMath.gaugeScale(for: peak)
        let today = Calendar.current.startOfDay(for: Date())
        let first = Calendar.current.date(byAdding: .day, value: -(SpeedSchedulePlanner.windowDays - 1), to: today) ?? today
        let last = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        return Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        SectionHeader("Débit planifié sur 30 jours · \(name)").fixedSize()
                        legends(schedule)
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader("Débit planifié sur 30 jours · \(name)")
                        HStack(spacing: 12) { legends(schedule) }
                    }
                }
                tiles(summary, schedule: schedule)
                if points.isEmpty {
                    Text(schedule.isEnabled ? "Aucun test planifié ces 30 derniers jours\u{00A0}: le premier aura lieu à l’heure choisie."
                                            : "Aucun test planifié pour ce site\u{00A0}: activez «\u{00A0}Tester chaque jour\u{00A0}» ci-dessus.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    chart(points, schedule: schedule, top: top, domain: first...last)
                        .frame(height: 200)
                }
            }
        }
    }

    private func legends(_ schedule: SpeedSchedule) -> some View {
        Group {
            legend("Descente", color: Theme.accent)
            legend("Montée", color: speedUpColor)
            if schedule.hasThreshold { legend("Seuil d’alerte", color: Theme.warning, dashed: true) }
        }
    }

    private func chart(_ points: [SpeedDailyPoint], schedule: SpeedSchedule, top: Double, domain: ClosedRange<Date>) -> some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Jour", point.day, unit: .day), y: .value("Mb/s", point.downMbps),
                         series: .value("Sens", "Descente"))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .interpolationMethod(.monotone)
                if let up = point.upMbps {
                    LineMark(x: .value("Jour", point.day, unit: .day), y: .value("Mb/s", up),
                             series: .value("Sens", "Montée"))
                        .foregroundStyle(speedUpColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                let verdict = SpeedSchedulePlanner.verdict(downMbps: point.downMbps, upMbps: point.upMbps, schedule: schedule)
                if verdict.downLow {
                    PointMark(x: .value("Jour", point.day, unit: .day), y: .value("Mb/s", point.downMbps))
                        .symbol { lowDot }
                }
                if verdict.upLow, let up = point.upMbps {
                    PointMark(x: .value("Jour", point.day, unit: .day), y: .value("Mb/s", up))
                        .symbol { lowDot }
                }
            }
            if let limit = schedule.minDownMbps {
                RuleMark(y: .value("Seuil descente", limit))
                    .foregroundStyle(Theme.warning)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .annotation(position: .bottom, alignment: .leading, spacing: 2) {
                        Text("Seuil descente \(SpeedFormat.integer(limit))").font(.system(size: 10)).foregroundStyle(Theme.warning)
                    }
            }
            if let limit = schedule.minUpMbps {
                RuleMark(y: .value("Seuil montée", limit))
                    .foregroundStyle(Theme.warning)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .annotation(position: .bottom, alignment: .leading, spacing: 2) {
                        Text("Seuil montée \(SpeedFormat.integer(limit))").font(.system(size: 10)).foregroundStyle(Theme.warning)
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, top / 2, top]) { value in
                AxisGridLine().foregroundStyle(Theme.neutralSoft)
                AxisValueLabel {
                    if let mbps = value.as(Double.self) {
                        Text(SpeedFormat.integer(mbps)).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { value in
                AxisGridLine().foregroundStyle(Theme.neutralSoft)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(SpeedFormat.shortDay.string(from: date)).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private var lowDot: some View {
        Circle().strokeBorder(Theme.warning, lineWidth: 2).background(Circle().fill(Theme.panel)).frame(width: 9, height: 9)
    }

    private func tiles(_ summary: SpeedSiteSummary, schedule: SpeedSchedule) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            SpeedTile(label: "Moyenne descente", value: summary.averageDown.map(SpeedFormat.rate) ?? "—", unit: "Mb/s",
                      detail: summary.count == 0 ? "Aucun test" : "\(MonText.plural(summary.count, "jour", "jours")) mesurés")
            SpeedTile(label: "Moyenne montée", value: summary.averageUp.map(SpeedFormat.rate) ?? "—", unit: "Mb/s",
                      detail: summary.averageLatency.map { "Latence moyenne \(SpeedFormat.latency($0)) ms" } ?? "—")
            SpeedTile(label: "Minimum", value: summary.minDown.map(SpeedFormat.rate) ?? "—", unit: "Mb/s",
                      detail: "Plus faible descente sur 30\u{00A0}jours")
            SpeedTile(label: "Sous le seuil", value: "\(summary.daysBelow)", unit: summary.daysBelow > 1 ? "jours" : "jour",
                      detail: schedule.hasThreshold ? thresholdText(schedule) : "Aucun seuil réglé",
                      badge: schedule.hasThreshold ? (summary.daysBelow > 0 ? "Alerte" : "OK") : nil,
                      badgeTone: summary.daysBelow > 0 ? .warning : .success)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func thresholdText(_ schedule: SpeedSchedule) -> String {
        var parts: [String] = []
        if let down = schedule.minDownMbps { parts.append("↓ \(SpeedFormat.integer(down))") }
        if let up = schedule.minUpMbps { parts.append("↑ \(SpeedFormat.integer(up))") }
        return "Seuil " + parts.joined(separator: " · ") + " Mb/s"
    }

    private func legend(_ label: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 2] : []))
            .frame(width: 14, height: 2)
            Text(label).font(Theme.small).foregroundStyle(Theme.neutralText)
        }
        .fixedSize()
    }

    // MARK: Tableau des sites

    private var lines: [SpeedScheduleLine] {
        let now = Date()
        let active = store.activeKey
        return store.sites.map { site in
            let schedule = store.schedule(for: site.id)
            let points = SpeedSchedulePlanner.dailySeries(model.history, siteID: site.id, now: now)
            return SpeedScheduleLine(key: site.key, name: site.name, isActive: site.key == active, schedule: schedule,
                                     summary: SpeedSchedulePlanner.summary(points, schedule: schedule),
                                     next: SpeedSchedulePlanner.nextRun(schedule, now: now),
                                     running: store.runningKey == site.key)
        }
    }

    private var tablePanel: some View {
        let rows = lines.sorted(using: table.sortOrder)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionHeader("Sites").fixedSize().padding(.trailing, 6)
                Text("\(rows.filter(\.schedule.isEnabled).count) sur \(MonText.plural(rows.count, "site planifié", "sites planifiés"))")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                StandardColumnsMenu(model: table)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            SpeedScheduleTable(rows: rows, table: table,
                               selection: Binding(get: { store.selected.key }, set: { store.selectedKey = $0 }))
                .standardTableHeight(rows: rows.count, rowHeight: 34, maxRows: 10)

            Text("Le test d’un site ne tourne que lorsque ce site est le site actif (choisi sous le logo NetScope). Les résultats s’ajoutent à l’historique avec l’origine «\u{00A0}planifié\u{00A0}».")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.panelMuted)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "site", title: "Site", isRequired: true),
        StandardColumn(id: "planification", title: "Heure"),
        StandardColumn(id: "seuil", title: "Seuil d’alerte"),
        StandardColumn(id: "dernier", title: "Dernier test"),
        StandardColumn(id: "moyenne", title: "Moyenne 30 j"),
        StandardColumn(id: "sousSeuil", title: "Sous le seuil"),
        StandardColumn(id: "prochain", title: "Prochain test", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<SpeedScheduleLine>] = [
        "site": KeyPathComparator(\SpeedScheduleLine.name),
        "planification": KeyPathComparator(\SpeedScheduleLine.sortPlan),
        "seuil": KeyPathComparator(\SpeedScheduleLine.sortThreshold),
        "dernier": KeyPathComparator(\SpeedScheduleLine.sortLast),
        "moyenne": KeyPathComparator(\SpeedScheduleLine.sortAverage),
        "sousSeuil": KeyPathComparator(\SpeedScheduleLine.summary.daysBelow),
        "prochain": KeyPathComparator(\SpeedScheduleLine.sortNext),
    ]
}

/// Une ligne du tableau des sites, avec ses clés de tri.
struct SpeedScheduleLine: Identifiable {
    let key: String
    let name: String
    let isActive: Bool
    let schedule: SpeedSchedule
    let summary: SpeedSiteSummary
    let next: Date?
    let running: Bool

    var id: String { key }

    var sortPlan: Int { schedule.isEnabled ? schedule.time.minutes : 10_000 }
    var sortThreshold: Double { schedule.minDownMbps ?? -1 }
    var sortLast: Date { schedule.lastRun ?? .distantPast }
    var sortAverage: Double { summary.averageDown ?? -1 }
    var sortNext: Date { next ?? .distantFuture }
}

/// Tableau des sites : un clic choisit le site de la courbe et de l'éditeur.
private struct SpeedScheduleTable: View {
    let rows: [SpeedScheduleLine]
    @ObservedObject var table: StandardTableModel<SpeedScheduleLine>
    @Binding var selection: String?

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn(StandardTableHeading("SITE"), sortUsing: table.sort("site")) { line in
                HStack(spacing: 6) {
                    Text(line.name).font(Theme.bodyMedium).foregroundStyle(Theme.text).lineLimit(1)
                    if line.isActive { Chip(text: "Actif", tone: .accent) }
                }
                .frame(height: 26)
            }
            .width(min: 120, ideal: 150)
            .customizationID("site")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(StandardTableHeading("HEURE"), sortUsing: table.sort("planification")) { line in
                if line.schedule.isEnabled {
                    Text(line.schedule.time.text).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
                        .help("Chaque jour à \(line.schedule.time.text)")
                } else {
                    Chip(text: "Désactivée", tone: .neutral)
                }
            }
            .width(min: 64, ideal: 74)
            .customizationID("planification")

            TableColumn(StandardTableHeading("SEUIL D’ALERTE"), sortUsing: table.sort("seuil")) { line in
                Text(SpeedScheduleText.threshold(line.schedule)).font(Theme.mono(12)).foregroundStyle(Theme.neutralText).lineLimit(1)
            }
            .width(min: 90, ideal: 100)
            .customizationID("seuil")

            TableColumn(StandardTableHeading("DERNIER TEST"), sortUsing: table.sort("dernier")) { line in
                SpeedScheduleStatusCell(schedule: line.schedule, running: line.running)
            }
            .width(min: 160, ideal: 200)
            .customizationID("dernier")

            TableColumn(StandardTableHeading("MOYENNE 30 J"), sortUsing: table.sort("moyenne")) { line in
                Text(line.summary.averageDown.map { avg in
                    "\(SpeedFormat.rate(avg)) / " + (line.summary.averageUp.map(SpeedFormat.rate) ?? "—") + " Mb/s"
                } ?? "—")
                .font(Theme.mono(12)).foregroundStyle(line.summary.averageDown == nil ? Theme.textTertiary : Theme.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 100, ideal: 110)
            .customizationID("moyenne")

            TableColumn(StandardTableHeading("SOUS LE SEUIL"), sortUsing: table.sort("sousSeuil")) { line in
                let below = line.summary.daysBelow
                Group {
                    if !line.schedule.hasThreshold || line.summary.count == 0 {
                        Text("—").font(Theme.mono(12)).foregroundStyle(Theme.textTertiary)
                    } else if below == 0 {
                        Chip(text: "Aucun jour", tone: .success)
                    } else {
                        Chip(text: MonText.plural(below, "jour", "jours"), tone: .warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 90)
            .customizationID("sousSeuil")

            TableColumn(StandardTableHeading("PROCHAIN TEST"), sortUsing: table.sort("prochain")) { line in
                Text(SpeedScheduleText.next(line.next, running: line.running))
                    .font(Theme.small).foregroundStyle(line.next == nil ? Theme.textTertiary : Theme.neutralText).lineLimit(1)
            }
            .width(min: 100, ideal: 130)
            .customizationID("prochain")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
    }
}

/// État du dernier test (« Aujourd’hui 07:01 · 908 / 486 Mb/s »), coloré selon le résultat.
struct SpeedScheduleStatusCell: View {
    let schedule: SpeedSchedule
    var running = false

    var body: some View {
        let (text, tone) = SpeedScheduleText.status(schedule, running: running)
        HStack(spacing: 6) {
            Circle().fill(tone.dot).frame(width: 7, height: 7)
            Text(text).font(Theme.small).foregroundStyle(tone == .neutral ? Theme.neutralText : tone.foreground).lineLimit(1)
                .help(text)
        }
    }
}

/// Textes communs de la planification.
enum SpeedScheduleText {
    static func threshold(_ schedule: SpeedSchedule) -> String {
        guard schedule.hasThreshold else { return "—" }
        let down = schedule.minDownMbps.map { "↓\(SpeedFormat.integer($0))" }
        let up = schedule.minUpMbps.map { "↑\(SpeedFormat.integer($0))" }
        return [down, up].compactMap { $0 }.joined(separator: " ") + " Mb/s"
    }

    /// « aujourd’hui 07:01 », « hier 06:31 », « 3 nov. 07:00 ».
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = SpeedFormat.time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd’hui \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "hier \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "demain \(time)"
        }
        return SpeedFormat.shortDay.string(from: date) + " \(time)"
    }

    static func next(_ date: Date?, running: Bool) -> String {
        if running { return "En cours…" }
        guard let date else { return "—" }
        if date <= Date().addingTimeInterval(1) { return "Dès que possible" }
        let text = when(date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func status(_ schedule: SpeedSchedule, running: Bool) -> (String, Tone) {
        if running { return ("Test en cours…", .accent) }
        let prefix = schedule.lastRun.map { when($0).prefix(1).uppercased() + when($0).dropFirst() + " · " } ?? ""
        switch schedule.lastStatus {
        case .ok(let down, let up)?:
            return (prefix + "\(SpeedFormat.rate(down)) / " + (up.map(SpeedFormat.rate) ?? "—") + " Mb/s", .success)
        case .below(let down, let up)?:
            return (prefix + "\(SpeedFormat.rate(down)) / " + (up.map(SpeedFormat.rate) ?? "—") + " Mb/s, sous le seuil", .warning)
        case .failed(let message)?:
            return (prefix + "échec\u{00A0}: \(message)", .critical)
        case .postponed(let reason)?:
            return ("Reporté\u{00A0}: \(reason)", .neutral)
        case nil:
            return ("Jamais", .neutral)
        }
    }
}

/// Réglage du site choisi : activation, heure, seuils, « Lancer maintenant ».
private struct SpeedScheduleEditor: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SpeedScheduleStore
    @ObservedObject var model: SpeedtestModel
    let site: (key: String, id: UUID?, name: String)
    let schedule: SpeedSchedule

    @State private var downText = ""
    @State private var upText = ""

    private var isActiveSite: Bool { site.key == store.activeKey }

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SectionHeader("Test planifié · \(site.name)").fixedSize()
                    if isActiveSite { Chip(text: "Site actif", tone: .accent) }
                    Spacer(minLength: 8)
                    statusPill
                }
                FlowLayout(spacing: 18, lineSpacing: 10) {
                    HStack(spacing: 8) {
                        Toggle("Tester chaque jour", isOn: Binding(
                            get: { schedule.isEnabled },
                            set: { value in store.update(site.id) { $0.isEnabled = value } }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(Theme.bodySemibold)
                        Text("à").font(Theme.body).foregroundStyle(Theme.textSecondary)
                        DatePicker("Heure du test", selection: timeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .environment(\.locale, Locale(identifier: "fr_CA"))
                            .fixedSize()
                    }
                    HStack(spacing: 8) {
                        SpeedFieldLabel("Alerte sous")
                        thresholdField("Descente", text: $downText) { value in store.update(site.id) { $0.minDownMbps = value } }
                        Text("Mb/s ↓").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        thresholdField("Montée", text: $upText) { value in store.update(site.id) { $0.minUpMbps = value } }
                        Text("Mb/s ↑").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                    Button {
                        store.run(siteID: site.id, interface: state.activeInterface)
                        model.tab = .internet
                    } label: {
                        Label("Lancer maintenant", systemImage: "play.fill").fixedSize()
                    }
                    .buttonStyle(.secondary)
                    .speedDisabled(!canRunNow)
                    .help(runHelp)
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    infoItem("Prochain test", SpeedScheduleText.next(SpeedSchedulePlanner.nextRun(schedule, now: Date()),
                                                                     running: store.runningKey == site.key))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Dernier test").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        SpeedScheduleStatusCell(schedule: schedule, running: store.runningKey == site.key)
                    }
                    Spacer(minLength: 0)
                }
                Text("Serveur\u{00A0}: celui choisi dans l’onglet Serveurs (automatique\u{00A0}: le plus proche). Le test est reporté pendant un scan, pendant un autre test et sur une connexion limitée (partage de connexion du téléphone, données réduites), puis rattrapé dans la journée. Sous le seuil, une notification «\u{00A0}Débit Internet sous le seuil\u{00A0}» est envoyée.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = store.message {
                    Text(message.text).font(Theme.small).foregroundStyle(message.tone.foreground)
                }
            }
        }
        .onAppear {
            downText = schedule.minDownMbps.map(SpeedFormat.integer) ?? ""
            upText = schedule.minUpMbps.map(SpeedFormat.integer) ?? ""
        }
    }

    private var canRunNow: Bool {
        isActiveSite && !store.isEphemeral && store.runningKey == nil && !model.runState.isRunning && !model.lanRunning
    }

    private var runHelp: String {
        if store.isEphemeral { return "Démonstration\u{00A0}: aucun test réel n’est lancé." }
        if !isActiveSite { return "Seulement pour le site actif\u{00A0}: ce Mac doit être sur place." }
        return "Lance tout de suite le test planifié de ce site (compté comme le test du jour)."
    }

    private var statusPill: some View {
        let running = store.runningKey == site.key
        let text = running ? "Test planifié en cours" : (schedule.isEnabled ? "Chaque jour à \(schedule.time.text)" : "Désactivé")
        return SpeedStatusPill(text: text, tone: running ? .accent : (schedule.isEnabled ? .success : .neutral), pulsing: running)
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { SpeedSchedulePlanner.slot(on: Date(), time: schedule.time) },
            set: { date in store.update(site.id) { $0.time = DayMinute.of(date) } })
    }

    private func thresholdField(_ placeholder: String, text: Binding<String>, commit: @escaping (Double?) -> Void) -> some View {
        SpeedTextField(placeholder: placeholder, text: Binding(
            get: { text.wrappedValue },
            set: { value in
                text.wrappedValue = value
                commit(SpeedFormat.parse(value))
            }))
            .frame(width: 84)
            .help("Laisser vide\u{00A0}: pas d’alerte dans ce sens.")
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.small.weight(.semibold)).foregroundStyle(Theme.text)
        }
    }
}
