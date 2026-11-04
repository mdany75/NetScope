import Charts
import NetScopeCore
import SwiftUI

/// Onglet Internet : jauge, étapes, courbes temps réel, résultats, et colonne de droite.
struct SpeedInternetView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: SpeedtestModel

    var body: some View {
        SidePanelSplit(sideWidth: 360, title: "Serveur, connexion et forfait") {
            mainPanel
        } side: {
            VStack(spacing: 12) {
                serverPanel
                connectionPanel
                planPanel
            }
        }
    }

    private var isWifi: Bool { state.activeInterface?.kind == .wifi }

    // MARK: Panneau principal

    private var mainPanel: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    SectionHeader("Débit Internet")
                        .fixedSize()
                    Text(runSummary).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        model.startInternet(interface: state.activeInterface)
                    } label: {
                        Label(model.runState.isRunning ? "Test en cours…" : (model.runState == .idle ? "Lancer le test" : "Relancer le test"),
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.primary)
                    .speedDisabled(model.runState.isRunning)
                    Button {
                        model.stopInternet()
                    } label: {
                        Label("Arrêter", systemImage: "stop.fill")
                    }
                    .buttonStyle(.secondary)
                    .speedDisabled(!model.runState.isRunning)
                }

                if isWifi {
                    SpeedBanner(text: "Mesure faite en Wi-Fi : le résultat peut être limité par le lien radio. Testez en filaire pour mesurer le lien Internet.")
                }
                if case .failed(let message) = model.runState {
                    SpeedBanner(text: message, tone: .critical, systemImage: "xmark.octagon")
                }

                // Jauge et courbes côte à côte ; l'une sous l'autre en petite fenêtre.
                AdaptiveStack(breakpoint: 640, spacing: 18) {
                    gaugeColumn.layoutPriority(1)
                    liveCharts
                }

                // Six tuiles sans case vide : 6 ou 3 par ligne quand la place le permet ; plus étroit,
                // 4 + 2 (débits et latences en première ligne, la latence en charge reste visible), puis 2.
                ViewThatFits(in: .horizontal) {
                    tileGrid(columns: 6, minWidth: 150)
                    tileGrid(columns: 3, minWidth: 236)
                    tileGrid(columns: 4, minWidth: 150)
                    tileGrid(columns: 2, minWidth: 150)
                }
            }
        }
    }

    private var runSummary: String {
        let planned = model.plannedServer
        switch model.runState {
        case .idle:
            let streams = planned.source.supportsStreams ? "\(model.streams) flux · " : ""
            return streams + planned.historyLabel + (model.isAutomatic ? " (auto)" : "")
        case .running(let phase):
            if model.preparingServer { return "Choix du serveur le plus proche…" }
            let server = model.server?.label ?? model.testedServer?.historyLabel ?? planned.historyLabel
            return "\(phase.label) en cours · \(server)"
        case .done:
            let server: String
            if let info = model.summary?.server, info.serverName == nil, let colo = info.colo {
                server = "Cloudflare · nœud \(colo)"
            } else {
                server = model.summary?.server?.label ?? model.testedServer?.historyLabel ?? "Cloudflare"
            }
            return "Terminé · \(model.summary?.streams ?? model.streams) flux · \(server)"
        case .stopped: return "Test arrêté"
        case .failed: return "Échec du test"
        }
    }

    /// Source du test affiché (en cours ou terminé), sinon du prochain test.
    private var currentSource: SpeedServerSource {
        (model.runState == .idle ? nil : model.testedServer?.source) ?? model.plannedServer.source
    }

    // MARK: Jauge et étapes

    private var gaugeColumn: some View {
        VStack(spacing: 8) {
            SpeedGauge(value: model.gaugeValue, scale: gaugeScale, color: gaugeColor, phase: gaugePhase,
                       valueText: gaugeText, unit: gaugeUnit)
                .frame(width: 330, height: 262)
                .animation(.easeOut(duration: 0.25), value: model.gaugeValue)
            // Les trois étapes sur une ligne ; plus étroit, chaque pastille passe sur deux lignes
            // (libellé puis valeur) plutôt que de renvoyer une pastille seule à la ligne.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(SpeedPhase.allCases, id: \.self) { phase in stepChip(phase, stacked: false) }
                }
                HStack(spacing: 6) {
                    ForEach(SpeedPhase.allCases, id: \.self) { phase in stepChip(phase, stacked: true) }
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(SpeedPhase.allCases, id: \.self) { phase in stepChip(phase, stacked: true) }
                }
            }
            VStack(spacing: 5) {
                ProgressBar(fraction: model.fraction)
                HStack {
                    Text("\((model.fraction * 100).clampedInt) %")
                    Spacer()
                    Text("\(SpeedFormat.number(model.elapsed, digits: 1)) s")
                }
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 330)
        }
        .frame(maxWidth: .infinity)
    }

    private var gaugeScale: Double {
        model.currentPhase == .latency ? 100 : model.gaugeScale
    }

    private var gaugeColor: Color {
        switch model.currentPhase {
        case .latency: return Theme.textSecondary
        case .upload: return speedUpColor
        default: return Theme.accent
        }
    }

    private var gaugePhase: String {
        switch model.runState {
        case .idle: return "Prêt"
        case .running(let phase): return phase.label
        case .done: return "Téléchargement · résultat"
        case .stopped: return "Test arrêté"
        case .failed: return "Échec"
        }
    }

    private var gaugeText: String {
        switch model.runState {
        case .running(.latency): return SpeedFormat.number(model.gaugeValue, digits: 1)
        case .running: return SpeedFormat.integer(model.gaugeValue)
        case .done: return SpeedFormat.integer(model.downMbps ?? 0)
        case .stopped, .failed: return "—"
        case .idle: return "0"
        }
    }

    private var gaugeUnit: String {
        model.currentPhase == .latency ? "ms · ping au repos" : "Mb/s"
    }

    private func stepChip(_ phase: SpeedPhase, stacked: Bool) -> some View {
        let order = SpeedPhase.allCases
        let current = model.currentPhase
        let done: Bool = {
            if model.runState == .done { return true }
            guard let current, let a = order.firstIndex(of: phase), let b = order.firstIndex(of: current) else {
                return stepValue(phase) != nil && model.runState != .idle
            }
            return a < b
        }()
        let isCurrent = current == phase
        let tone: Tone = isCurrent ? .accent : (done ? .success : .neutral)
        let label = Text(chipLabel(phase)).font(.system(size: 11, weight: .semibold))
        let value = stepValue(phase).map { Text($0).font(Theme.mono(10.5)) }
        return HStack(spacing: 5) {
            SpeedPulseDot(color: isCurrent ? Theme.accent : (done ? Theme.success : Color(light: 0xD1D5DB, dark: 0x2F343C)), pulsing: isCurrent)
            if stacked {
                VStack(alignment: .leading, spacing: 0) {
                    label
                    value
                }
            } else {
                label
                value
            }
        }
        .foregroundStyle(tone == .neutral ? Theme.textSecondary : tone.foreground)
        .padding(.horizontal, stacked ? 10 : 8)
        .frame(height: stacked && value != nil ? 34 : 26)
        .background(Capsule().fill(tone.background))
        .fixedSize()
        .help(phase.label)
    }

    /// Libellé des étapes : même vocabulaire que la jauge et les tuiles (« Téléchargement »,
    /// « Téléversement ») ; police réduite pour que les trois pastilles tiennent sur une ligne.
    private func chipLabel(_ phase: SpeedPhase) -> String {
        switch phase {
        case .latency: return phase.label
        case .download: return "Téléchargement"
        case .upload: return "Téléversement"
        }
    }

    private func stepValue(_ phase: SpeedPhase) -> String? {
        switch phase {
        case .latency: return model.idleLatency.map { "\(SpeedFormat.latency($0)) ms" }
        case .download: return model.downMbps.map { "\(SpeedFormat.rate($0)) Mb/s" }
        case .upload: return model.upMbps.map { "\(SpeedFormat.rate($0)) Mb/s" }
        }
    }

    // MARK: Courbes temps réel

    private var liveCharts: some View {
        VStack(alignment: .leading, spacing: 12) {
            liveCard(title: "Descente", systemImage: "arrow.down", color: Theme.accent, soft: speedDownSoft,
                     points: model.downSeries, current: model.currentPhase == .download ? model.gaugeValue : model.downMbps)
            liveCard(title: "Montée", systemImage: "arrow.up", color: speedUpColor, soft: speedUpSoft,
                     points: model.upSeries, current: model.currentPhase == .upload ? model.gaugeValue : model.upMbps)
            Text("Échelle 0–\(SpeedFormat.integer(model.gaugeScale)) Mb/s · \(currentSource.supportsStreams ? "\(model.streams) flux · " : "")\(currentSource.protocolLabel)")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(minWidth: 240, maxWidth: .infinity)
    }

    private func liveCard(title: String, systemImage: String, color: Color, soft: Color,
                          points: [SpeedPoint], current: Double?) -> some View {
        let peak = points.map(\.mbps).max()
        let duration = 10.0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .labelStyle(SpeedTintedLabelStyle(color: color))
                Spacer()
                Text(current.map { "\(SpeedFormat.rate($0)) Mb/s" } ?? "—")
                    .font(Theme.mono(12, weight: .semibold))
            }
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Temps", point.time), y: .value("Débit", point.mbps))
                        .foregroundStyle(soft)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Temps", point.time), y: .value("Débit", point.mbps))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Milieu", model.gaugeScale / 2))
                    .foregroundStyle(Theme.neutralSoft)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartXScale(domain: 0...duration)
            .chartYScale(domain: 0...model.gaugeScale)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot.overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
            .frame(height: 64)
            HStack {
                Text("0 s")
                Spacer()
                Text(peak.map { "pic \(SpeedFormat.rate($0)) Mb/s" } ?? "en attente")
                Spacer()
                Text("\(Int(duration)) s")
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Tuiles de résultats

    /// Grille de tuiles ; une rangée incomplète (4 + 2) étire ses tuiles sur toute la largeur.
    private func tileGrid(columns: Int, minWidth: CGFloat) -> some View {
        let all = tiles
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: all.count, by: columns)), id: \.self) { start in
                let end = min(start + columns, all.count)
                let span = columns % (end - start) == 0 ? columns / (end - start) : 1
                GridRow {
                    ForEach(start..<end, id: \.self) { index in
                        all[index].frame(minWidth: minWidth, maxHeight: .infinity, alignment: .topLeading)
                            .gridCellColumns(span)
                    }
                }
            }
        }
        // Hauteur idéale : les tuiles d'une même rangée prennent la hauteur de la plus haute.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tiles: [SpeedTile] {
        let summary = model.summary
        let planDown = model.planDown
        let planUp = model.planUp
        func planText(_ value: Double?, _ plan: Double?) -> String {
            guard let value else { return "en attente" }
            guard let plan, let ratio = SpeedMath.planRatio(measured: value, plan: plan) else { return "forfait non renseigné" }
            return "\((ratio * 100).clampedInt) % du forfait"
        }
        var grade: String?
        var loadedDetail = "mesurée pendant le débit"
        if let idle = model.idleLatency, let loaded = summary?.loadedLatencyMs {
            grade = SpeedMath.bufferbloatGrade(idle: idle, loaded: loaded)
            loadedDetail = "Bufferbloat +\(SpeedFormat.latency(max(0, loaded - idle))) ms"
        }
        let gradeTone: Tone = (grade == "A+" || grade == "A") ? .success : .warning
        return [
            SpeedTile(label: "Téléchargement", value: model.downMbps.map(SpeedFormat.rate) ?? "—", unit: "Mb/s",
                      detail: planText(model.downMbps, planDown)),
            SpeedTile(label: "Téléversement", value: model.upMbps.map(SpeedFormat.rate) ?? "—", unit: "Mb/s",
                      detail: planText(model.upMbps, planUp)),
            SpeedTile(label: "Latence au repos", value: model.idleLatency.map(SpeedFormat.latency) ?? "—", unit: "ms",
                      detail: latencyDetail),
            SpeedTile(label: "Latence en charge", value: summary?.loadedLatencyMs.map(SpeedFormat.latency) ?? "—", unit: "ms",
                      detail: loadedDetail, badge: grade, badgeTone: gradeTone),
            SpeedTile(label: "Gigue", value: model.jitter.map { SpeedFormat.number($0, digits: 1) } ?? "—", unit: "ms",
                      detail: "écart moyen entre requêtes"),
            SpeedTile(label: currentSource == .ookla ? "Paquets perdus" : "Requêtes perdues", value: summary?.lossPercent.map { SpeedFormat.number($0, digits: 0) } ?? "—",
                      unit: "%", detail: lossDetail(summary)),
        ]
    }

    private var latencyDetail: String {
        switch currentSource {
        case .mlab: return "médiane de 10 connexions TCP"
        case .ookla: return "mesurée par le CLI d’Ookla"
        default: return "médiane de 10 requêtes HTTP"
        }
    }

    private func lossDetail(_ summary: SpeedTestSummary?) -> String {
        guard let summary else { return "en attente" }
        if currentSource == .ookla { return summary.probesSent == 0 ? "non mesurés par ce serveur" : "mesurés par Ookla" }
        return "\(summary.probesLost) sur \(summary.probesSent) sondes"
    }

    // MARK: Colonne de droite

    private var serverPanel: some View {
        let favorites = Array(model.favoriteServers.prefix(4))
        let selected = model.selectedServer
        let source = model.plannedServer.source
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Serveur de test") {
                    Button {
                        model.tab = .serveurs
                    } label: {
                        Label("Tous les serveurs", systemImage: "arrow.right").labelStyle(SpeedTrailingIconLabelStyle())
                    }
                    .buttonStyle(.ghost)
                    .padding(.trailing, -8)
                }
                VStack(spacing: 4) {
                    SpeedServerRadio(title: "Automatique (le plus proche)", subtitle: automaticSubtitle,
                                     latency: model.automaticChoice.latencyMs ?? (model.isAutomatic ? model.idleLatency : nil),
                                     isOn: model.isAutomatic) {
                        model.selectServer(nil)
                    }
                    ForEach(favorites) { server in
                        SpeedServerRadio(title: server.title, subtitle: subtitle(server), latency: server.latencyMs,
                                         trailing: server.latencyMs == nil && server.source == .ookla ? "Ookla" : nil,
                                         isOn: !model.isAutomatic && selected?.id == server.id) {
                            model.selectServer(server)
                        }
                    }
                    if let selected, !favorites.contains(where: { $0.id == selected.id }) {
                        SpeedServerRadio(title: selected.title, subtitle: subtitle(selected), latency: selected.latencyMs, isOn: true) {}
                    }
                }
                .disabled(model.runState.isRunning)
                if favorites.isEmpty {
                    Text("Ajoutez des favoris (étoile) dans l’onglet Serveurs pour les retrouver ici.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SpeedFieldLabel("Flux parallèles").padding(.top, 2)
                SpeedSegmentRow(options: SpeedTestConfig.streamChoices.map { ($0, String($0)) }, selection: $model.streams, mono: true)
                    .disabled(model.runState.isRunning || !source.supportsStreams)
                    .opacity(source.supportsStreams ? 1 : 0.45)
                SpeedFieldLabel("Protocole").padding(.top, 2)
                HStack(spacing: 6) {
                    Image(systemName: source == .ookla ? "terminal" : "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accentStrong)
                    Text(source.protocolLabel).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    if !source.supportsStreams {
                        Text("1 flux imposé").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                if source == .ookla {
                    Text(OoklaLocator.licenseNote).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var automaticSubtitle: String {
        let choice = model.automaticChoice
        if choice.source == .cloudflare, let info = model.server, info.serverName == nil, let colo = info.colo {
            return "Choisit Cloudflare · nœud \(colo)\(info.city.map { " · \($0)" } ?? "")"
        }
        if model.catalogDate == nil && choice.source == .cloudflare {
            return "Mesure les serveurs au premier test"
        }
        return "Choisit \(choice.historyLabel)"
    }

    private func subtitle(_ server: SpeedServer) -> String {
        var parts = [server.source.label]
        if let sponsor = server.sponsor, server.source != .cloudflare, sponsor != server.title { parts.append(sponsor) }
        return parts.joined(separator: " · ")
    }

    private var connectionPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Votre connexion")
                let interface = state.activeInterface
                Group {
                    KeyValueRow(key: "IP publique", value: model.server?.clientIP ?? "après un test", mono: model.server?.clientIP != nil, keyWidth: 96)
                    KeyValueRow(key: "Fournisseur", value: model.server?.providerLabel ?? "après un test", keyWidth: 96)
                    KeyValueRow(key: "Interface", value: interface.map { "\($0.name) · \($0.kind.label)" } ?? "non détectée", mono: true, keyWidth: 96)
                    KeyValueRow(key: "IP locale", value: interface.map { "\($0.address) / \($0.subnet.prefix)" } ?? "—", mono: true, keyWidth: 96)
                    KeyValueRow(key: "Passerelle", value: gatewayLabel, mono: true, keyWidth: 96)
                    KeyValueRow(key: "DNS", value: state.dnsServers.isEmpty ? "—" : state.dnsServers.map(\.description).joined(separator: ", "),
                                mono: true, keyWidth: 96)
                }
                if isWifi {
                    SpeedBanner(text: "Résultat possiblement limité par le Wi-Fi : testez en filaire pour mesurer le lien Internet.")
                        .padding(.top, 2)
                }
            }
        }
    }

    private var gatewayLabel: String {
        guard let gateway = state.activeInterface?.gateway else { return "—" }
        if let device = state.device(withID: gateway.description), let name = device.hostnameLabel ?? device.customName {
            return "\(gateway) · \(name)"
        }
        return gateway.description
    }

    private var planPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Comparaison au forfait")
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Forfait descente (Mb/s)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        SpeedTextField(placeholder: "1000", text: $model.planDownText)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Forfait montée (Mb/s)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        SpeedTextField(placeholder: "500", text: $model.planUpText)
                    }
                }
                planBar("Descente", measured: model.downMbps, plan: model.planDown)
                planBar("Montée", measured: model.upMbps, plan: model.planUp)
            }
        }
    }

    private func planBar(_ label: String, measured: Double?, plan: Double?) -> some View {
        let ratio = measured.flatMap { value in plan.flatMap { SpeedMath.planRatio(measured: value, plan: $0) } }
        let ok = (ratio ?? 0) >= SpeedMath.planThreshold
        let note: String
        let noteColor: Color
        if measured == nil {
            note = "Lancez un test pour comparer."
            noteColor = Theme.textSecondary
        } else if ratio == nil {
            note = "Indiquez le débit du forfait."
            noteColor = Theme.textSecondary
        } else if ok {
            note = "Conforme au forfait (seuil 80 %)."
            noteColor = Theme.success
        } else {
            note = isWifi ? "Sous 80 % : mesure limitée par le Wi-Fi." : "Sous 80 % du forfait : à signaler au fournisseur."
            noteColor = Theme.warning
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(Theme.small)
                Spacer()
                Text(planBarText(measured: measured, plan: plan, ratio: ratio))
                    .font(Theme.mono(12, weight: .semibold))
            }
            SpeedBar(fraction: ratio ?? 0, color: ok ? Theme.success : Theme.warning)
            Text(note).font(Theme.caption).foregroundStyle(noteColor)
        }
        .padding(.top, 2)
    }

    private func planBarText(measured: Double?, plan: Double?, ratio: Double?) -> String {
        guard let measured else { return "—" }
        guard let plan, let ratio else { return "\(SpeedFormat.rate(measured)) Mb/s" }
        return "\(SpeedFormat.rate(measured)) / \(SpeedFormat.integer(plan)) · \((ratio * 100).clampedInt) %"
    }
}

/// Étiquette dont seule l'icône prend la couleur.
struct SpeedTintedLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(color).font(.system(size: 11, weight: .bold))
            configuration.title
        }
    }
}
