import Charts
import NetScopeCore
import SwiftUI

/// Onglet Internet : jauge, étapes, courbes temps réel, résultats, et colonne de droite.
struct SpeedInternetView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: SpeedtestModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            mainPanel
            VStack(spacing: 12) {
                serverPanel
                connectionPanel
                planPanel
            }
            .frame(width: 360)
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
                        Label("Arrêter", systemImage: "stop")
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

                HStack(alignment: .center, spacing: 18) {
                    gaugeColumn
                    liveCharts
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in tile }
                }
            }
        }
    }

    private var runSummary: String {
        switch model.runState {
        case .idle: return "\(model.streams) flux · HTTP · Cloudflare"
        case .running(let phase): return "\(phase.label) en cours · \(model.streams) flux"
        case .done:
            let server = model.summary?.server?.colo.map { "nœud \($0)" } ?? "Cloudflare"
            return "Terminé · \(model.summary?.streams ?? model.streams) flux · \(server)"
        case .stopped: return "Test arrêté"
        case .failed: return "Échec du test"
        }
    }

    // MARK: Jauge et étapes

    private var gaugeColumn: some View {
        VStack(spacing: 8) {
            SpeedGauge(value: model.gaugeValue, scale: gaugeScale, color: gaugeColor, phase: gaugePhase,
                       valueText: gaugeText, unit: gaugeUnit)
                .frame(width: 330, height: 262)
                .animation(.easeOut(duration: 0.25), value: model.gaugeValue)
            HStack(spacing: 6) {
                ForEach(SpeedPhase.allCases, id: \.self) { phase in stepChip(phase) }
            }
            VStack(spacing: 5) {
                ProgressBar(fraction: model.fraction)
                HStack {
                    Text("\(Int((model.fraction * 100).rounded())) %")
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

    private func stepChip(_ phase: SpeedPhase) -> some View {
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
        return HStack(spacing: 6) {
            SpeedPulseDot(color: isCurrent ? Theme.accent : (done ? Theme.success : Color(hex: 0xD1D5DB)), pulsing: isCurrent)
            Text(phase.label).font(.system(size: 12, weight: .semibold))
            if let value = stepValue(phase) {
                Text(value).font(Theme.mono(11))
            }
        }
        .foregroundStyle(tone == .neutral ? Theme.textSecondary : tone.foreground)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(tone.background))
        .fixedSize()
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
            Text("Échelle 0–\(SpeedFormat.integer(model.gaugeScale)) Mb/s · \(model.streams) flux · HTTP multi-flux")
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

    private var tiles: [SpeedTile] {
        let summary = model.summary
        let planDown = model.planDown
        let planUp = model.planUp
        func planText(_ value: Double?, _ plan: Double?) -> String {
            guard let value else { return "en attente" }
            guard let plan, let ratio = SpeedMath.planRatio(measured: value, plan: plan) else { return "forfait non renseigné" }
            return "\(Int((ratio * 100).rounded())) % du forfait"
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
                      detail: "médiane de 10 requêtes HTTP"),
            SpeedTile(label: "Latence en charge", value: summary?.loadedLatencyMs.map(SpeedFormat.latency) ?? "—", unit: "ms",
                      detail: loadedDetail, badge: grade, badgeTone: gradeTone),
            SpeedTile(label: "Gigue", value: model.jitter.map { SpeedFormat.number($0, digits: 1) } ?? "—", unit: "ms",
                      detail: "écart moyen entre requêtes"),
            SpeedTile(label: "Requêtes perdues", value: summary?.lossPercent.map { SpeedFormat.number($0, digits: 0) } ?? "—",
                      unit: "%", detail: summary.map { "\($0.probesLost) sur \($0.probesSent) sondes" } ?? "en attente"),
        ]
    }

    // MARK: Colonne de droite

    private var serverPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Serveur de test")
                HStack(spacing: 10) {
                    Circle().strokeBorder(Theme.accent, lineWidth: 4).frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Cloudflare · automatique").font(.system(size: 12, weight: .semibold))
                        Text(model.server.map { "Nœud le plus proche : \($0.colo ?? "?")\($0.city.map { " · \($0)" } ?? "")" }
                             ?? "Nœud anycast le plus proche, choisi par Cloudflare")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Text(model.idleLatency.map { "\(SpeedFormat.latency($0)) ms" } ?? "")
                        .font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.accent))
                Text("Choix d’un autre serveur (Ookla, serveur du fournisseur) : bientôt.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)

                SpeedFieldLabel("Flux parallèles").padding(.top, 2)
                SpeedSegmentRow(options: SpeedTestConfig.streamChoices.map { ($0, String($0)) }, selection: $model.streams, mono: true)
                    .disabled(model.runState.isRunning)
                SpeedFieldLabel("Protocole").padding(.top, 2)
                SpeedSegmentRow(options: [("http", "HTTP multi-flux"), ("tcp", "TCP"), ("udp", "UDP")],
                                selection: .constant("http"), disabled: ["tcp", "udp"])
            }
        }
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
        return "\(SpeedFormat.rate(measured)) / \(SpeedFormat.integer(plan)) · \(Int((ratio * 100).rounded())) %"
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
