import Charts
import NetScopeCore
import SwiftUI

/// Outil « Vitesse des disques » (note 22) : choix de l'emplacement (disque interne, externe,
/// partage réseau, dossier nuage), réglages, jauges écriture et lecture, courbe en direct, accès
/// aléatoires 4 Kio, bilan en clair et historique par emplacement.
struct DiskSpeedView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: DiskSpeedModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = DiskHistoryTable.makeModel()

    private var location: DiskLocation? { model.selected }
    /// Emplacement des mesures affichées (test en cours ou terminé), sinon l'emplacement choisi.
    private var shown: DiskLocation? { model.testedLocation ?? model.selected }
    private var isCloud: Bool { shown?.kind == .nuage }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            locationPicker
            settings
            notices
            measures
            if let verdict = model.verdict, !model.isRunning {
                ToolNotice(tone: tone(verdict.tone), title: verdict.title, message: verdict.detail) {
                    Button(model.isInReport ? "Dans le rapport" : "Ajouter au rapport") { model.addToReport() }
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                        .disabled(model.isInReport)
                        .fixedSize()
                }
            }
            history
        }
        .onAppear { model.refreshLocations() }
        .alert(cloudAlertTitle, isPresented: $model.confirmingCloud) {
            Button("Écrire \(DiskFormat.testSize(model.sizeBytes))") { model.start(state: state, store: store) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le fichier d’essai sera envoyé au service\u{00A0}: il compte dans le quota du compte et dans le forfait Internet (données montantes), puis il est supprimé. Choisissez 256\u{00A0}Mio ou 1\u{00A0}Gio pour un test plus léger.")
        }
    }

    private var cloudAlertTitle: String {
        "Écrire \(DiskFormat.testSize(model.sizeBytes)) dans \(location?.name ?? "le nuage")\u{00A0}?"
    }

    // MARK: Emplacement

    private var locationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolFieldLabel("Emplacement")
                if model.loadingLocations { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                Button {
                    model.refreshLocations()
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .disabled(model.isRunning || model.isDemo)
                .help("Relire les volumes montés et les dossiers nuage")
            }
            if model.locations.isEmpty && !model.loadingLocations {
                Text("Aucun emplacement trouvé.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                ForEach(model.locations) { item in locationCard(item) }
            }
        }
    }

    private func locationCard(_ item: DiskLocation) -> some View {
        let isOn = model.selectedID == item.id
        return Button {
            model.selectedID = item.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(for: item))
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isOn ? Theme.accentStrong : Theme.textSecondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Chip(text: Self.kindChip(item), tone: isOn ? .accent : .neutral)
                    }
                    Text(item.detail).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(isOn ? Theme.accentSoft : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(isOn ? Theme.accent : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
        .help("\(item.name)\n\(item.detail)\n\(item.path)")
        .accessibilityLabel("\(item.name), \(item.kind.label)")
    }

    static func symbol(for location: DiskLocation) -> String {
        switch location.kind {
        case .nuage: return location.provider == .icloud ? "icloud" : "cloud"
        case .reseau: return "server.rack"
        case .externe: return "externaldrive"
        case .interne: return "internaldrive"
        }
    }

    static func kindChip(_ location: DiskLocation) -> String {
        switch location.kind {
        case .interne: return "Interne"
        case .externe: return "Externe"
        case .reseau: return location.networkProtocol?.label ?? "Réseau"
        case .nuage: return "Nuage"
        }
    }

    // MARK: Réglages

    private var settings: some View {
        let cloud = location?.kind == .nuage
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 14) {
                    sizePicker
                    passesPicker(cloud: cloud)
                    if cloud { timeoutPicker } else { randomToggle }
                    Spacer(minLength: 0)
                    launchButtons
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .bottom, spacing: 14) {
                        sizePicker
                        passesPicker(cloud: cloud)
                    }
                    HStack(alignment: .center, spacing: 14) {
                        if cloud { timeoutPicker } else { randomToggle }
                        Spacer(minLength: 0)
                        launchButtons
                    }
                }
            }
        }
    }

    private var sizePicker: some View {
        ToolLabeledField(label: "Taille du fichier") {
            Picker("Taille du fichier", selection: $model.sizeBytes) {
                ForEach(DiskBenchmarkConfig.sizeChoices, id: \.self) { size in
                    Text(DiskFormat.testSize(size)).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.isRunning)
        }
    }

    private func passesPicker(cloud: Bool) -> some View {
        ToolLabeledField(label: "Passes") {
            Picker("Passes", selection: $model.passes) {
                ForEach(DiskBenchmarkConfig.passChoices, id: \.self) { count in Text("\(count)").tag(count) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(cloud || model.isRunning)
            .help(cloud ? "Une seule passe dans un dossier nuage (chaque passe serait renvoyée au service)" : "Moyenne de plusieurs passes")
        }
    }

    private var timeoutPicker: some View {
        ToolLabeledField(label: "Attente de «\u{00A0}envoyé\u{00A0}»") {
            Picker("Attente de «\u{00A0}envoyé\u{00A0}»", selection: $model.cloudTimeout) {
                ForEach(DiskBenchmarkConfig.cloudTimeoutChoices, id: \.self) { seconds in
                    Text("\(Int(seconds / 60))\u{00A0}min au plus").tag(seconds)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.isRunning)
        }
    }

    private var randomToggle: some View {
        ToolCheckbox(label: "Accès aléatoires 4\u{00A0}Kio (IOPS)", isOn: $model.random)
            .fixedSize()
            .disabled(model.isRunning)
            .frame(height: 28)
    }

    private var launchButtons: some View {
        HStack(spacing: 8) {
            if model.isRunning {
                Button {
                    model.stop()
                } label: {
                    Label("Arrêter", systemImage: "stop.fill")
                }
                .buttonStyle(.secondary)
            } else {
                Button {
                    model.requestStart(state: state, store: store)
                } label: {
                    Label(model.result == nil ? "Lancer le test" : "Relancer le test", systemImage: "play.fill")
                }
                .buttonStyle(.primary)
                .disabled(model.blockingProblem != nil)
            }
        }
        .fixedSize()
    }

    // MARK: Messages

    @ViewBuilder private var notices: some View {
        if let problem = model.blockingProblem, location != nil, !model.isRunning {
            ToolNotice(tone: .warning, message: problem)
        }
        if let location, location.kind == .nuage, !model.isRunning, model.result == nil || model.testedLocation?.id != location.id {
            ToolNotice(tone: .accent, title: "Dossier nuage",
                       message: "La copie locale s’écrit vite, l’envoi réel se fait ensuite. NetScope mesure l’écriture dans le dossier, puis le temps jusqu’à «\u{00A0}envoyé\u{00A0}» quand le service le signale. Au-delà de 1\u{00A0}Gio, une confirmation est demandée (quota, forfait).")
        }
        if let error = model.error {
            ToolNotice(tone: .critical, message: error)
        }
        if let notice = model.notice {
            ToolNotice(tone: model.stopped ? .warning : .success, message: notice)
        }
    }

    // MARK: Mesures

    private var measures: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdaptiveStack(breakpoint: 820, spacing: 12, horizontalAlignment: .top) {
                HStack(alignment: .top, spacing: 10) {
                    DiskGauge(label: "Écriture", value: model.displayedWrite, scale: model.gaugeScale, color: Theme.accent,
                              active: model.isRunning && model.phase == .ecriture,
                              caption: passCaption(model.writePasses))
                    if isCloud {
                        DiskUploadCard(status: model.cloudStatus, elapsed: model.cloudElapsed, result: model.result,
                                       timeout: model.testedConfig?.cloudTimeout ?? model.cloudTimeout)
                    } else {
                        DiskGauge(label: "Lecture", value: model.displayedRead, scale: model.gaugeScale, color: speedUpColor,
                                  active: model.isRunning && model.phase == .lecture,
                                  caption: passCaption(model.readPasses))
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                liveChart
            }
            progressLine
            tiles
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func passCaption(_ passes: [Double]) -> String {
        guard !passes.isEmpty else { return model.isRunning ? "en cours" : "en attente" }
        if passes.count == 1 { return "1 passe" }
        let low = passes.min() ?? 0, high = passes.max() ?? 0
        return "\(passes.count) passes · \(DiskFormat.rate(low))–\(DiskFormat.rate(high))"
    }

    private var liveChart: some View {
        let points = model.points
        let peak = points.map(\.value).max()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Débit en direct").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                legend("Écriture", Theme.accent)
                if !isCloud { legend("Lecture", speedUpColor) }
                Spacer(minLength: 4)
                Text(peak.map { "pic \(DiskFormat.rateWithUnit($0))" } ?? "en attente")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            Chart(points) { point in
                AreaMark(x: .value("Temps", point.time), y: .value("Mo/s", point.value),
                         series: .value("Phase", seriesKey(point)))
                    .foregroundStyle(point.phase == .ecriture ? speedDownSoft : speedUpSoft)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Temps", point.time), y: .value("Mo/s", point.value),
                         series: .value("Phase", seriesKey(point)))
                    .foregroundStyle(point.phase == .ecriture ? Theme.accent : speedUpColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...model.gaugeScale)
            .chartXScale(domain: 0...max(10, (points.last?.time ?? 0) + 0.5))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) { Text("\(seconds.clampedInt)\u{00A0}s").font(Theme.caption) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let rate = value.as(Double.self) { Text(DiskFormat.grouped(rate.clampedInt)).font(Theme.caption) }
                    }
                }
            }
            .frame(minHeight: 150, maxHeight: 170)
            .overlay {
                if points.isEmpty {
                    Text(model.isRunning ? "Préparation…" : "La courbe s’affiche pendant le test.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            Text("Mo/s · blocs de 1\u{00A0}Mio · cache du système contourné (F_NOCACHE)")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .frame(minWidth: 240, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    /// Une série par phase et par passe : la courbe ne relie pas la fin d'une écriture au début d'une lecture.
    private func seriesKey(_ point: DiskPoint) -> String { "\(point.phase.rawValue)-\(point.segment)" }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 3)
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var progressLine: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(statusText).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 8)
                Text("\((model.fraction * 100).clampedInt)\u{00A0}% · \(DiskFormat.number(model.elapsed, digits: 1))\u{00A0}s")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            ProgressBar(fraction: model.fraction, color: model.isRunning ? Theme.accent : (model.result != nil ? Theme.success : Theme.accent))
        }
    }

    private var statusText: String {
        let config = model.testedConfig ?? model.config
        if model.isRunning, let phase = model.phase {
            var text = phase.label
            if (phase == .ecriture || phase == .lecture) && config.passes > 1 { text += " · passe \(model.pass)/\(config.passes)" }
            if phase == .aleatoireLecture || phase == .aleatoireEcriture, let iops = model.instant {
                text += " · \(DiskFormat.iops(iops)) IOPS"
            }
            if phase == .envoi { text += " · " + (model.cloudStatus?.label ?? "En attente du service") }
            return text + " · \(shown?.name ?? "")"
        }
        if model.stopped { return "Test arrêté" }
        if model.result != nil, let tested = model.testedLocation {
            return "Terminé · \(tested.name) · \(DiskFormat.testSize(config.sizeBytes)) · \(config.passes) passe\(config.passes > 1 ? "s" : "")"
        }
        return "Prêt · fichier d’essai de \(DiskFormat.testSize(model.sizeBytes)) dans «\u{00A0}NetScope-test\u{00A0}», supprimé à la fin"
    }

    // MARK: Tuiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
            if isCloud {
                ToolStatTile(label: "Écriture locale", value: model.displayedWrite.map(DiskFormat.rateWithUnit) ?? "—",
                             detail: "copie dans le dossier")
                ToolStatTile(label: "Jusqu’à «\u{00A0}envoyé\u{00A0}»", value: model.result?.uploadSeconds.map(DiskFormat.duration) ?? "—",
                             detail: model.cloudStatus?.label ?? "après l’écriture")
                ToolStatTile(label: "Débit d’envoi", value: model.result?.uploadMbps.map(DiskFormat.bits) ?? "—",
                             detail: "au moins, depuis la fin de l’écriture")
                ToolStatTile(label: "Montée Internet", value: model.network?.internetUpMbps.map(DiskFormat.bits) ?? "—",
                             detail: model.network?.internetUpMbps == nil ? "lancez un Speedtest" : "dernier Speedtest")
            } else {
                ToolStatTile(label: "IOPS 4\u{00A0}Kio lecture", value: model.randomRead.map { DiskFormat.iops($0.iops) } ?? "—",
                             detail: model.randomRead.map { "\(DiskFormat.grouped($0.operations)) accès" } ?? randomPending)
                ToolStatTile(label: "IOPS 4\u{00A0}Kio écriture", value: model.randomWrite.map { DiskFormat.iops($0.iops) } ?? "—",
                             detail: model.randomWrite.map { "\(DiskFormat.grouped($0.operations)) accès" } ?? randomPending)
                ToolStatTile(label: "Latence moy. 4\u{00A0}Kio", value: model.randomRead.map { DiskFormat.latency($0.meanMs) } ?? "—",
                             detail: model.randomWrite.map { "écriture \(DiskFormat.latency($0.meanMs))" } ?? "lecture")
                ToolStatTile(label: "Latence p95 4\u{00A0}Kio", value: model.randomRead.map { DiskFormat.latency($0.p95Ms) } ?? "—",
                             detail: model.randomWrite.map { "écriture \(DiskFormat.latency($0.p95Ms))" } ?? "95\u{00A0}% des accès en dessous")
                if shown?.kind == .reseau {
                    ToolStatTile(label: "Lien actif", value: model.network?.linkMbps.map(DiskFormat.bits) ?? "—",
                                 detail: [model.network?.linkKind, model.network?.interfaceName].compactMap { $0 }.joined(separator: " · "))
                    ToolStatTile(label: "Latence serveur", value: model.network?.serverLatencyMs.map(DiskFormat.latency) ?? "—",
                                 detail: model.network?.serverLatencyMs == nil
                                     ? (model.isRunning ? "ping en cours" : "ne répond pas au ping")
                                     : "ping, moyenne de 5")
                }
            }
        }
    }

    private var randomPending: String {
        (model.testedConfig ?? model.config).random ? "en attente" : "non mesuré"
    }

    // MARK: Historique

    private var history: some View {
        let rows = model.visibleHistory.sorted(using: table.sortOrder)
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    historyTitle
                    Spacer(minLength: 8)
                    historyControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    historyTitle
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        historyControls
                    }
                }
            }
            DiskHistoryTable(rows: rows, table: table, allLocations: model.showAllHistory || model.selectedID == nil)
        }
    }

    private var historyTitle: some View {
        HStack(spacing: 6) {
            ToolFieldLabel("Historique")
            Text(model.showAllHistory ? "tous les emplacements" : (location?.name ?? ""))
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    private var historyControls: some View {
        HStack(spacing: 10) {
            ToolCheckbox(label: "Tous les emplacements", isOn: $model.showAllHistory).fixedSize()
            ToolColumnsMenu(model: table)
            Button {
                model.exportCSV()
            } label: {
                Label("Exporter CSV", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .disabled(model.visibleHistory.isEmpty)
            .fixedSize()
        }
    }

    private func tone(_ tone: DiskVerdict.Tone) -> Tone {
        switch tone {
        case .success: return .success
        case .accent: return .accent
        case .warning: return .warning
        case .critical: return .critical
        case .neutral: return .neutral
        }
    }
}

// MARK: - Jauge

/// Jauge compacte (arc de 240°) : intitulé, valeur au centre, échelle aux deux bouts.
struct DiskGauge: View {
    let label: String
    let value: Double?
    let scale: Double
    let color: Color
    var active = false
    var caption: String

    private static let size = CGSize(width: 176, height: 150)

    var body: some View {
        VStack(spacing: 2) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: 78)
                let radius: CGFloat = 64
                let fraction = min(max((value ?? 0) / max(scale, 1), 0), 1)
                context.stroke(Self.arc(center: center, radius: radius, from: 0, to: 1), with: .color(Theme.border),
                               style: StrokeStyle(lineWidth: 11, lineCap: .round))
                if fraction > 0.003 {
                    context.stroke(Self.arc(center: center, radius: radius, from: 0, to: fraction), with: .color(color),
                                   style: StrokeStyle(lineWidth: 11, lineCap: .round))
                }
                context.draw(Text(label.uppercased()).font(Theme.captionSemibold).kerning(0.5).foregroundColor(Theme.textSecondary),
                             at: CGPoint(x: center.x, y: center.y - 22))
                context.draw(Text(value.map(DiskFormat.rate) ?? "—").font(Theme.mono(24, weight: .semibold)).foregroundColor(Theme.text),
                             at: CGPoint(x: center.x, y: center.y + 4))
                context.draw(Text("Mo/s").font(Theme.small).foregroundColor(Theme.textSecondary),
                             at: CGPoint(x: center.x, y: center.y + 28))
                let start = Self.point(center: center, radius: radius, fraction: 0)
                let end = Self.point(center: center, radius: radius, fraction: 1)
                context.draw(Text("0").font(Theme.mono(10)).foregroundColor(Theme.textTertiary),
                             at: CGPoint(x: start.x + 4, y: start.y + 16))
                context.draw(Text(DiskFormat.rate(scale)).font(Theme.mono(10)).foregroundColor(Theme.textTertiary),
                             at: CGPoint(x: end.x - 6, y: end.y + 16))
            }
            .frame(width: Self.size.width, height: 140)
            HStack(spacing: 5) {
                if active { SpeedPulseDot(color: color, pulsing: true) }
                Text(caption).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(height: 14)
        }
        .padding(.vertical, 6)
        .frame(minWidth: Self.size.width + 12, maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .animation(.easeOut(duration: 0.2), value: value)
        .accessibilityElement()
        .accessibilityLabel("\(label)\u{00A0}: \(value.map(DiskFormat.rateWithUnit) ?? "aucune mesure")")
    }

    /// Angle (radians) d'une part de l'arc : de 150° à 390° (sens horaire à l'écran).
    private static func angle(_ fraction: Double) -> Double { (150 + 240 * fraction) * .pi / 180 }

    private static func point(center: CGPoint, radius: CGFloat, fraction: Double) -> CGPoint {
        let a = angle(fraction)
        return CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a)))
    }

    private static func arc(center: CGPoint, radius: CGFloat, from start: Double, to end: Double) -> Path {
        var path = Path()
        let steps = max(2, min(10_000, ((end - start) * 100).clampedInt))
        for step in 0...steps {
            let p = point(center: center, radius: radius, fraction: start + (end - start) * Double(step) / Double(steps))
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// Carte « Envoi » d'un dossier nuage, à la place de la jauge de lecture.
struct DiskUploadCard: View {
    let status: DiskCloudStatus?
    let elapsed: Double
    let result: DiskBenchmarkResult?
    let timeout: Double

    var body: some View {
        VStack(spacing: 6) {
            Text("ENVOI").font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
            Image(systemName: icon).font(.system(size: 26, weight: .regular)).foregroundStyle(tone.foreground)
                .frame(height: 34)
            Text(headline).font(Theme.mono(20, weight: .semibold)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(status?.label ?? "Après l’écriture").font(Theme.small).foregroundStyle(tone == .neutral ? Theme.textSecondary : tone.foreground)
            Spacer(minLength: 0)
            Text("délai maximal \(Int(timeout / 60))\u{00A0}min").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .frame(height: 14)
        }
        .padding(.vertical, 6)
        .frame(minWidth: 188, maxWidth: .infinity, minHeight: 168, maxHeight: 168)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private var headline: String {
        if status == .envoye, let seconds = result?.uploadSeconds ?? (elapsed > 0 ? elapsed : nil) { return DiskFormat.duration(seconds) }
        if status == .envoi || status == .attente { return DiskFormat.duration(elapsed) }
        return "—"
    }

    private var icon: String {
        switch status {
        case .envoye: return "checkmark.icloud"
        case .envoi, .attente: return "icloud.and.arrow.up"
        case .nonFourni: return "questionmark.circle"
        case .delaiDepasse: return "clock.badge.exclamationmark"
        case .erreur: return "exclamationmark.icloud"
        case .arrete: return "stop.circle"
        case nil: return "icloud.and.arrow.up"
        }
    }

    private var tone: Tone {
        switch status {
        case .envoye: return .success
        case .envoi, .attente: return .accent
        case .delaiDepasse, .arrete: return .warning
        case .erreur: return .critical
        default: return .neutral
        }
    }
}

// MARK: - Historique

/// Historique des tests (tableau standard « outils.disques.historique »).
struct DiskHistoryTable: View {
    let rows: [DiskTestRecord]
    @ObservedObject var table: StandardTableModel<DiskTestRecord>
    /// Historique de tous les emplacements (texte du tableau vide).
    var allLocations: Bool

    static let columns: [StandardColumn] = [
        StandardColumn(id: "date", title: "Date", isRequired: true),
        StandardColumn(id: "emplacement", title: "Emplacement"),
        StandardColumn(id: "type", title: "Type", isDefaultVisible: false),
        StandardColumn(id: "taille", title: "Taille"),
        StandardColumn(id: "passes", title: "Passes", isDefaultVisible: false),
        StandardColumn(id: "ecriture", title: "Écriture (Mo/s)"),
        StandardColumn(id: "lecture", title: "Lecture (Mo/s) ou envoi"),
        StandardColumn(id: "iops", title: "IOPS 4\u{00A0}Kio", isDefaultVisible: false),
        StandardColumn(id: "p95", title: "Latence p95", isDefaultVisible: false),
        StandardColumn(id: "lien", title: "Lien", isDefaultVisible: false),
        StandardColumn(id: "serveur", title: "Latence serveur", isDefaultVisible: false),
        StandardColumn(id: "limite", title: "Limite"),
        StandardColumn(id: "bilan", title: "Bilan", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<DiskTestRecord>] = [
        "date": KeyPathComparator(\DiskTestRecord.date),
        "emplacement": KeyPathComparator(\DiskTestRecord.locationName),
        "type": KeyPathComparator(\DiskTestRecord.sortKind),
        "taille": KeyPathComparator(\DiskTestRecord.sizeBytes),
        "passes": KeyPathComparator(\DiskTestRecord.passes),
        "ecriture": KeyPathComparator(\DiskTestRecord.sortWrite),
        "lecture": KeyPathComparator(\DiskTestRecord.sortRead),
        "iops": KeyPathComparator(\DiskTestRecord.sortIOPS),
        "p95": KeyPathComparator(\DiskTestRecord.sortP95),
        "lien": KeyPathComparator(\DiskTestRecord.sortLink),
        "serveur": KeyPathComparator(\DiskTestRecord.sortServer),
        "limite": KeyPathComparator(\DiskTestRecord.sortLimit),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<DiskTestRecord> {
        StandardTableModel(id: "outils.disques.historique", columns: columns, sortKeys: sortKeys, defaultSort: "date",
                           defaultAscending: false)
    }

    var body: some View {
        ToolStandardTableFrame(rowCount: rows.count, maxRows: 10, emptyText: allLocations ? "Aucun test enregistré." : "Aucun test pour cet emplacement.") {
            Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                Group {
                    TableColumn("DATE", sortUsing: table.sort("date")) { row in
                        ToolTableText(Self.day(row.date), mono: false)
                    }
                    .width(min: 72, ideal: 82)
                    .customizationID("date")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("EMPLACEMENT", sortUsing: table.sort("emplacement")) { row in
                        HStack(spacing: 5) {
                            Image(systemName: row.kind.symbol).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                            ToolTableText(row.locationName, mono: false, weight: .medium)
                        }
                        .help(row.locationID)
                    }
                    .width(min: 64, ideal: 92)
                    .customizationID("emplacement")

                    TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                        ToolTableText(row.kind.label + (row.detail.isEmpty ? "" : " · " + row.detail), mono: false, color: Theme.textSecondary)
                    }
                    .width(min: 90, ideal: 160)
                    .customizationID("type")
                    .defaultVisibility(.hidden)

                    TableColumn("TAILLE", sortUsing: table.sort("taille")) { row in
                        ToolTableText(DiskFormat.testSize(row.sizeBytes), alignment: .trailing)
                    }
                    .width(min: 52, ideal: 58)
                    .customizationID("taille")

                    TableColumn("PASSES", sortUsing: table.sort("passes")) { row in
                        ToolTableText("\(row.passes)", alignment: .trailing)
                    }
                    .width(min: 44, ideal: 52)
                    .customizationID("passes")
                    .defaultVisibility(.hidden)

                    TableColumn("ÉCRITURE", sortUsing: table.sort("ecriture")) { row in
                        ToolTableText(row.writeMBps.map(DiskFormat.rate) ?? "—", alignment: .trailing)
                    }
                    .width(min: 64, ideal: 76)
                    .customizationID("ecriture")
                }
                Group {
                    TableColumn("LECTURE", sortUsing: table.sort("lecture")) { row in
                        ToolTableText(Self.readText(row), alignment: .trailing)
                            .help(row.kind == .nuage ? "Temps jusqu’à «\u{00A0}envoyé\u{00A0}» après l’écriture" : "Lecture séquentielle")
                    }
                    .width(min: 64, ideal: 76)
                    .customizationID("lecture")

                    TableColumn("IOPS", sortUsing: table.sort("iops")) { row in
                        ToolTableText(row.randomReadIOPS.map { DiskFormat.iops($0) } ?? "—", alignment: .trailing)
                    }
                    .width(min: 44, ideal: 50)
                    .customizationID("iops")
                    .defaultVisibility(.hidden)

                    TableColumn("P95", sortUsing: table.sort("p95")) { row in
                        ToolTableText(row.randomReadP95Ms.map(DiskFormat.latency) ?? "—", alignment: .trailing)
                    }
                    .width(min: 54, ideal: 70)
                    .customizationID("p95")
                    .defaultVisibility(.hidden)

                    TableColumn("LIEN", sortUsing: table.sort("lien")) { row in
                        ToolTableText(row.network?.linkMbps.map { DiskFormat.bits($0) + (row.network?.linkKind.map { " · \($0)" } ?? "") } ?? "—")
                    }
                    .width(min: 70, ideal: 120)
                    .customizationID("lien")
                    .defaultVisibility(.hidden)

                    TableColumn("LATENCE SERVEUR", sortUsing: table.sort("serveur")) { row in
                        ToolTableText(row.network?.serverLatencyMs.map(DiskFormat.latency) ?? "—", alignment: .trailing)
                    }
                    .width(min: 60, ideal: 90)
                    .customizationID("serveur")
                    .defaultVisibility(.hidden)

                    TableColumn("LIMITE", sortUsing: table.sort("limite")) { row in
                        Chip(text: row.limit.label, tone: Self.tone(row.limit))
                            .help(row.verdict)
                    }
                    .width(min: 80, ideal: 100)
                    .customizationID("limite")

                    TableColumn("BILAN") { row in
                        ToolTableText(row.verdict, mono: false, color: Theme.textSecondary).help(row.verdict)
                    }
                    .width(min: 120, ideal: 260)
                    .customizationID("bilan")
                    .defaultVisibility(.hidden)
                }
            }
        }
    }

    /// « Auj. 09:42 », « Hier 14:07 », « 2 nov. 10:20 ».
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) || calendar.isDateInYesterday(date) { return ToolText.day(date, now: now) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

    static func readText(_ row: DiskTestRecord) -> String {
        if row.kind == .nuage {
            return row.uploadSeconds.map { "↑\u{00A0}" + ($0 < 1000 ? "\($0.clampedInt)\u{00A0}s" : DiskFormat.duration($0)) } ?? (row.cloudStatus?.label ?? "—")
        }
        return row.readMBps.map(DiskFormat.rate) ?? "—"
    }

    static func tone(_ limit: DiskLimit) -> Tone {
        switch limit {
        case .disque: return .neutral
        case .reseau, .latence: return .warning
        case .serveur, .internet: return .accent
        case .service: return .warning
        case .inconnu: return .neutral
        }
    }
}

/// Clés de tri de l'historique (toujours Comparable ; une valeur absente va en fin de liste).
extension DiskTestRecord {
    var sortKind: Int { DiskLocationKind.allCases.firstIndex(of: kind) ?? 0 }
    var sortWrite: Double { writeMBps ?? -1 }
    var sortRead: Double { kind == .nuage ? -(uploadSeconds ?? .infinity) : (readMBps ?? -1) }
    var sortIOPS: Double { randomReadIOPS ?? -1 }
    var sortP95: Double { randomReadP95Ms ?? .infinity }
    var sortLink: Double { network?.linkMbps ?? -1 }
    var sortServer: Double { network?.serverLatencyMs ?? .infinity }
    var sortLimit: String { limit.label }
}
