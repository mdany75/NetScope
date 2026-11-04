import Charts
import NetScopeCore
import SwiftUI

/// Onglet Réseau local : test iperf3 vers un serveur du réseau.
struct SpeedLanView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: SpeedtestModel
    /// Présence d'iperf3 : le bouton « Lancer » suit l'installation faite depuis l'encadré.
    @ObservedObject private var iperf = ToolInstallMonitor.shared(.iperf3)

    var body: some View {
        SidePanelSplit(sideWidth: 360, title: "Appareil cible, comparaison et chemin") {
            mainPanel
        } side: {
            VStack(spacing: 12) {
                targetPanel
                comparisonPanel
                pathPanel
            }
        }
    }

    // MARK: Panneau principal

    private var mainPanel: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    SectionHeader("Test iperf3").fixedSize()
                    Text(lanSummary).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        model.startLan(interface: state.activeInterface)
                    } label: {
                        Label(model.lanRunning ? "Test en cours…" : "Lancer iperf3", systemImage: "play.fill")
                    }
                    .buttonStyle(.primary)
                    .speedDisabled(model.lanRunning || model.iperfPath == nil || model.lanHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        model.stopLan()
                    } label: {
                        Label("Arrêter", systemImage: "stop.fill")
                    }
                    .buttonStyle(.secondary)
                    .speedDisabled(!model.lanRunning)
                }

                InstallToolPanel(tool: .iperf3, note: "Lancez ensuite « iperf3 -s » sur l’appareil cible (colonne de droite).")
                if let error = model.lanError, model.iperfPath != nil {
                    SpeedBanner(text: error, tone: .critical, systemImage: "xmark.octagon")
                }

                optionsRow
                commandBlock

                HStack(alignment: .top, spacing: 14) {
                    intervalTable
                    rateChart
                }
            }
        }
    }

    private var lanSummary: String {
        if model.lanRunning { return "Mesure en cours vers \(model.lanHost)" }
        guard let result = model.lanResult else { return "Débit entre ce Mac et un serveur iperf3" }
        return "\(SpeedFormat.rate(result.megabitsPerSecond)) Mb/s · \(result.protocolName) · \(result.streams) flux · \(result.remoteHost ?? model.lanHost)"
    }

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    SpeedFieldLabel("Serveur iperf3 cible")
                    HStack(spacing: 6) {
                        SpeedTextField(placeholder: "10.10.0.20 ou nas.local", text: $model.lanHost)
                        Menu {
                            ForEach(targetSuggestions, id: \.id) { device in
                                Button("\(device.displayName) · \(device.ip.description)") { model.lanHost = device.ip.description }
                            }
                            if targetSuggestions.isEmpty { Text("Aucun appareil scanné") }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                        .help("Choisir un appareil du scan")
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    SpeedFieldLabel("Port")
                    SpeedTextField(placeholder: "5201", text: $model.lanPort).frame(width: 70)
                }
                VStack(alignment: .leading, spacing: 4) {
                    SpeedFieldLabel("Durée")
                    SpeedSegmentRow(options: IperfOptions.durationChoices.map { ($0, "\($0) s") }, selection: $model.lanDuration)
                        .frame(width: 150)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    SpeedFieldLabel("Flux (-P)")
                    SpeedSegmentRow(options: IperfOptions.streamChoices.map { ($0, String($0)) }, selection: $model.lanStreams, mono: true)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    SpeedFieldLabel("Transport")
                    SpeedSegmentRow(options: IperfOptions.Transport.allCases.map { ($0, $0.label) }, selection: $model.lanTransport)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    SpeedFieldLabel("Sens")
                    SpeedSegmentRow(options: IperfOptions.Direction.allCases.map { ($0, $0.label) }, selection: $model.lanDirection)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .disabled(model.lanRunning)
    }

    /// Appareils du scan : serveurs, NAS et postes en ligne d'abord.
    private var targetSuggestions: [Device] {
        state.devices.filter { $0.isOnline && $0.ip != state.activeInterface?.address }
            .sorted { lhs, rhs in
                let l = [DeviceType.serveur, .poste].contains(lhs.deviceType) ? 0 : 1
                let r = [DeviceType.serveur, .poste].contains(rhs.deviceType) ? 0 : 1
                return l != r ? l < r : lhs.ip < rhs.ip
            }
    }

    private var commandBlock: some View {
        let local = state.activeInterface.map { "local \($0.address) (\($0.name))" } ?? "interface non détectée"
        let host = model.lanHost.isEmpty ? "<serveur>" : model.lanHost
        return VStack(alignment: .leading, spacing: 2) {
            (Text("\(NSUserName())@\(speedLocalHostName) ~ % ").foregroundColor(Color(hex: 0x4ADE80))
             + Text(model.lanOptions.commandLine))
            Text("Connexion à \(host), port \(model.lanPort) · \(local)").foregroundStyle(Theme.consoleMuted)
            if model.lanRunning {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let elapsed = model.lanStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
                    Text("Mesure en cours… \(SpeedFormat.number(min(elapsed, Double(model.lanDuration)), digits: 1)) s sur \(model.lanDuration) s (résultat JSON à la fin du test)")
                        .foregroundStyle(Theme.consoleText)
                }
            }
        }
        .font(Theme.mono(13))
        .foregroundStyle(Theme.consoleText)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.console))
        .textSelection(.enabled)
    }

    // MARK: Intervalles

    private var isUDP: Bool { model.lanResult?.isUDP ?? (model.lanTransport == .udp) }

    private var intervalTable: some View {
        let result = model.lanResult
        let intervals = result?.intervals ?? []
        return VStack(spacing: 0) {
            TableHeader(columns: [
                .init(title: "Intervalle", width: 92),
                .init(title: "Transfert", alignment: .trailing),
                .init(title: isUDP ? "Débit" : "Débit", alignment: .trailing),
                .init(title: isUDP ? "Paquets" : "Retrans.", width: 90, alignment: .trailing),
            ])
            if intervals.isEmpty {
                Text(model.lanRunning ? "Les intervalles s’afficheront à la fin du test." : "Aucun résultat : lancez un test.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(16)
            }
            ForEach(Array(intervals.enumerated()), id: \.offset) { _, interval in
                intervalRow(label: "\(Int(interval.start.rounded()))–\(Int(interval.end.rounded())) s",
                            transfer: SpeedFormat.bytes(interval.bytes),
                            rate: "\(SpeedFormat.rate(interval.megabitsPerSecond)) Mb/s",
                            extra: isUDP ? (interval.packets.map(String.init) ?? "—") : (interval.retransmits.map(String.init) ?? "—"),
                            extraColor: (interval.retransmits ?? 0) > 5 ? Theme.warning : Theme.neutralText)
            }
            if let result {
                intervalRow(label: "Moyenne", transfer: SpeedFormat.bytes(result.receivedBytes ?? result.sentBytes ?? 0),
                            rate: "\(SpeedFormat.rate(result.megabitsPerSecond)) Mb/s",
                            extra: isUDP ? (result.lostPercent.map { "\(SpeedFormat.number($0, digits: 2)) % perdus" } ?? "—")
                                         : (result.retransmits.map(String.init) ?? "—"),
                            extraColor: Theme.text, footer: true)
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func intervalRow(label: String, transfer: String, rate: String, extra: String,
                             extraColor: Color, footer: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(label).font(footer ? Theme.bodySemibold : Theme.mono(12)).padding(.horizontal, 8).frame(width: 92, alignment: .leading)
            Text(transfer).font(Theme.mono(12)).foregroundStyle(Theme.neutralText)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .trailing)
            Text(rate).font(Theme.mono(12, weight: footer ? .bold : .semibold))
                .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .trailing)
            Text(extra).font(Theme.mono(12)).foregroundStyle(extraColor)
                .padding(.horizontal, 8).frame(width: 90, alignment: .trailing)
        }
        .frame(height: footer ? 32 : 28)
        .background(footer ? Theme.panelMuted : Theme.panel)
        .overlay(alignment: footer ? .top : .bottom) {
            Rectangle().fill(footer ? Theme.border : Theme.neutralSoft).frame(height: 1)
        }
    }

    // MARK: Graphe

    private var rateChart: some View {
        let intervals = model.lanResult?.intervals ?? []
        let bidir = model.lanResult?.bidirectional ?? false
        let top = SpeedMath.gaugeScale(for: intervals.map(\.megabitsPerSecond).max() ?? 1000)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Débit par seconde").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.lanResult.map { "\(SpeedFormat.rate($0.megabitsPerSecond)) Mb/s" } ?? "—")
                    .font(Theme.mono(12, weight: .semibold))
            }
            Chart {
                ForEach(Array(intervals.enumerated()), id: \.offset) { index, interval in
                    BarMark(x: .value("Seconde", String(index + 1)), y: .value("Débit", interval.megabitsPerSecond), width: .ratio(bidir ? 0.9 : 0.7))
                        .foregroundStyle(by: .value("Sens", "Envoi (TX)"))
                        .position(by: .value("Sens", "Envoi (TX)"))
                        .cornerRadius(2)
                    if bidir, let reverse = interval.reverseMegabitsPerSecond {
                        BarMark(x: .value("Seconde", String(index + 1)), y: .value("Débit", reverse), width: .ratio(0.9))
                            .foregroundStyle(by: .value("Sens", "Réception (RX)"))
                            .position(by: .value("Sens", "Réception (RX)"))
                            .cornerRadius(2)
                    }
                }
                RuleMark(y: .value("Échelle", top))
                    .foregroundStyle(Theme.borderStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(SpeedFormat.integer(top)).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                    }
            }
            .chartForegroundStyleScale(["Envoi (TX)": Theme.accent, "Réception (RX)": speedUpColor])
            .chartLegend(bidir ? .visible : .hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...(top * 1.1))
            .chartPlotStyle { plot in
                plot.overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
            .frame(height: 150)
            HStack {
                Text("0 s")
                Spacer()
                Text("\(Int(model.lanResult?.duration.rounded() ?? Double(model.lanDuration))) s")
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .frame(minWidth: 260, maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Colonne de droite

    /// Préparer l'appareil cible : la commande serveur à copier, et où trouver iperf3 ailleurs.
    private var targetPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Sur l’appareil cible")
                Text("iperf3 doit tourner en mode serveur sur l’autre appareil (port 5201) :")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                CopyableCommand(command: IperfServerHelp.serverCommand)
                VStack(alignment: .leading, spacing: 4) {
                    targetLine("Mac", "brew install iperf3")
                    targetLine("Linux", IperfServerHelp.linuxCommand)
                    HStack(spacing: 6) {
                        Text("Windows").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 58, alignment: .leading)
                        Link(destination: IperfServerHelp.windowsURL) {
                            Label("Versions officielles (ESnet)", systemImage: "arrow.up.right.square")
                        }
                        .font(Theme.small)
                    }
                }
                .padding(.top, 2)
                Text("Pare-feu : autorisez le port TCP et UDP 5201 sur la cible.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func targetLine(_ system: String, _ command: String) -> some View {
        HStack(spacing: 6) {
            Text(system).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 58, alignment: .leading)
            Text(command).font(Theme.mono(11)).foregroundStyle(Theme.neutralText).textSelection(.enabled).lineLimit(1)
        }
    }

    /// Derniers tests iperf3 en filaire et en Wi-Fi, vers la même cible si possible.
    private var comparison: (wired: SpeedTestRecord, wifi: SpeedTestRecord)? {
        let lan = model.history.filter { $0.kind == .lan }
        for wired in lan where wired.interfaceKind == "Ethernet" {
            if let wifi = lan.first(where: { $0.interfaceKind == "Wi-Fi" && $0.server == wired.server }) { return (wired, wifi) }
        }
        if let wired = lan.first(where: { $0.interfaceKind == "Ethernet" }),
           let wifi = lan.first(where: { $0.interfaceKind == "Wi-Fi" }) { return (wired, wifi) }
        return nil
    }

    private var comparisonPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Filaire vs Wi-Fi")
                if let pair = comparison {
                    Text("Cible : \(pair.wired.server) · \(pair.wired.streams) flux")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    let top = SpeedMath.gaugeScale(for: max(pair.wired.downMbps, pair.wifi.downMbps))
                    comparisonBar(pair.wired.interfaceLabel, pair.wired.downMbps, top, Theme.accent)
                    comparisonBar(pair.wifi.interfaceLabel, pair.wifi.downMbps, top, Theme.warning)
                    let ratio = pair.wifi.downMbps / max(pair.wired.downMbps, 1)
                    Text("Le Wi-Fi atteint \(Int((ratio * 100).rounded())) % du filaire. "
                         + (ratio < 0.8 ? "Le goulot est probablement le lien radio, pas le réseau." : "L’écart est faible : le lien radio n’est pas le facteur limitant."))
                        .font(Theme.small)
                        .foregroundStyle(Theme.neutralText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                } else {
                    Text("Lancez un test en filaire puis un en Wi-Fi vers le même serveur pour les comparer.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    state.open(.wifi)
                } label: {
                    Label("Analyser le Wi-Fi", systemImage: "arrow.right")
                        .labelStyle(SpeedTrailingIconLabelStyle())
                }
                .buttonStyle(.ghost)
                .padding(.leading, -8)
            }
        }
    }

    private func comparisonBar(_ label: String, _ value: Double, _ top: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(Theme.mono(12))
                Spacer()
                Text("\(SpeedFormat.rate(value)) Mb/s").font(Theme.mono(12, weight: .bold))
            }
            SpeedBar(fraction: value / top, color: color, height: 14)
        }
    }

    /// Chemin déduit du sous-réseau : direct si la cible est sur le réseau local, sinon par la passerelle.
    private var pathPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Chemin mesuré")
                let steps = pathSteps
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(Theme.mono(11, weight: .semibold))
                            .foregroundStyle(Theme.neutralText)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.neutralSoft))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.name).font(.system(size: 12, weight: .semibold))
                            Text(step.detail).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Text(pathNote).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct PathStep {
        let name: String
        let detail: String
    }

    private var targetAddress: IPv4Address? { IPv4Address(model.lanHost.trimmingCharacters(in: .whitespaces)) }

    private var isRouted: Bool {
        guard let target = targetAddress, let subnet = state.activeInterface?.subnet else { return false }
        return !subnet.contains(target)
    }

    private var pathSteps: [PathStep] {
        let interface = state.activeInterface
        var steps = [PathStep(name: speedLocalHostName,
                              detail: interface.map { "\($0.address) · \($0.name) \($0.kind.label)" } ?? "interface non détectée")]
        if let switchName = state.device(withID: interface?.address.description ?? "")?.switchName {
            steps.append(PathStep(name: switchName, detail: "switch d’accès (relevé du scan)"))
        }
        if isRouted, let gateway = interface?.gateway {
            let name = state.device(withID: gateway.description)?.hostnameLabel ?? "Passerelle"
            steps.append(PathStep(name: name, detail: "\(gateway) · routage vers un autre réseau"))
        }
        let host = model.lanHost.isEmpty ? "Serveur iperf3" : model.lanHost
        let device = targetAddress.flatMap { state.device(withID: $0.description) }
        steps.append(PathStep(name: device?.displayName ?? host, detail: "\(host) · iperf3 \(model.lanPort)"))
        return steps
    }

    private var pathNote: String {
        if targetAddress == nil { return "Chemin estimé d’après les adresses ; la trace complète (traceroute) viendra bientôt." }
        return isRouted
            ? "La cible est hors du réseau local : le trafic traverse la passerelle, dont l’inspection peut limiter le débit."
            : "La cible est sur le même réseau : aucun routeur n’intervient dans la mesure."
    }
}

/// Étiquette avec l'icône après le texte (lien « Analyser le Wi-Fi → »).
struct SpeedTrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.font(.system(size: 11, weight: .semibold))
        }
    }
}

/// Nom court de ce Mac, sans résolution DNS ; « Macmini-de-Dany » en démonstration (`--demo`).
let speedLocalHostName: String = {
    if Launcher.isDemo { return "Macmini-de-Dany" }
    var buffer = [CChar](repeating: 0, count: 256)
    let name = gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : "Ce Mac"
    return name.split(separator: ".").first.map(String.init) ?? name
}()

/// Compte de la session (invite de terminal) ; « dany » en démonstration.
let speedLocalUserName: String = Launcher.isDemo ? "dany" : NSUserName()
