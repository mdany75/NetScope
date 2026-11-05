import Charts
import NetScopeCore
import SwiftUI

/// Choix du rôle de ce Mac dans l'outil iperf3 : il mesure (client) ou il reçoit (serveur intégré).
struct IperfRolePicker: View {
    @ObservedObject var model: IperfServerModel

    var body: some View {
        Picker("Rôle de ce Mac", selection: $model.showServer) {
            Text("Client").tag(false)
            Text("Serveur de ce Mac").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Client\u{00A0}: ce Mac mesure vers un serveur. Serveur\u{00A0}: un autre appareil mesure vers ce Mac.")
    }
}

/// Note 78 : serveur iperf3 intégré (« iperf3 -s » sans rien installer) : démarrage sur un clic,
/// arrêt automatique après un délai sans test, commande à taper sur l'autre appareil, test en
/// cours et tests reçus.
struct IperfServerView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: IperfServerModel

    static let columns: [StandardColumn] = [
        StandardColumn(id: "heure", title: "Heure", isRequired: true),
        StandardColumn(id: "client", title: "Client"),
        StandardColumn(id: "sens", title: "Sens"),
        StandardColumn(id: "flux", title: "Flux"),
        StandardColumn(id: "duree", title: "Durée"),
        StandardColumn(id: "octets", title: "Transfert"),
        StandardColumn(id: "debit", title: "Débit"),
        StandardColumn(id: "version", title: "Version du client", isDefaultVisible: false),
    ]
    static let sortKeys: [String: KeyPathComparator<IperfServerTest>] = [
        "heure": KeyPathComparator(\IperfServerTest.date),
        "client": KeyPathComparator(\IperfServerTest.client),
        "sens": KeyPathComparator(\IperfServerTest.directionLabel),
        "flux": KeyPathComparator(\IperfServerTest.streams),
        "duree": KeyPathComparator(\IperfServerTest.seconds),
        "octets": KeyPathComparator(\IperfServerTest.bytes),
        "debit": KeyPathComparator(\IperfServerTest.megabitsPerSecond),
        "version": KeyPathComparator(\IperfServerTest.versionLabel),
    ]
    @StateObject private var table = StandardTableModel<IperfServerTest>(id: "iperf-serveur", columns: IperfServerView.columns,
                                                                        sortKeys: IperfServerView.sortKeys, defaultSort: "heure",
                                                                        defaultAscending: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Panel(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if case .failed(let message) = model.runState {
                        SpeedBanner(text: message, tone: .critical, systemImage: "xmark.octagon")
                    }
                    if let notice = model.notice {
                        SpeedBanner(text: notice, tone: .warning, systemImage: "info.circle")
                    }
                    optionsRow
                    console
                    HStack(alignment: .top, spacing: 14) {
                        liveChart
                        notes
                    }
                }
            }
            testsPanel
        }
    }

    // MARK: En-tête et réglages

    private var header: some View {
        HStack(spacing: 10) {
            IperfRolePicker(model: model)
            statusChip
            Text(summary).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            if model.isListening {
                Button {
                    model.stop()
                } label: {
                    Label("Arrêter le serveur", systemImage: "stop.fill")
                }
                .buttonStyle(.secondary)
                .fixedSize()
            } else {
                Button {
                    model.start()
                } label: {
                    Label("Démarrer le serveur", systemImage: "play.fill")
                }
                .buttonStyle(.primary)
                .fixedSize()
            }
        }
    }

    private var statusChip: some View {
        Group {
            if model.current != nil {
                Chip(text: "Test en cours", tone: .accent, systemImage: "waveform.path.ecg")
            } else if case .listening(let port) = model.runState {
                Chip(text: "À l’écoute · port \(port)", tone: .success)
            } else {
                Chip(text: "Arrêté", tone: .neutral)
            }
        }
    }

    private var summary: String {
        if let current = model.current { return "\(current.client) · \(current.directionLabel) · \(current.streams) flux" }
        if model.isListening { return "Un autre appareil peut mesurer son débit vers ce Mac" }
        return "Démarré seulement à la demande, arrêté seul après un délai sans test"
    }

    private var address: String? { state.activeInterface?.address.description }

    private var optionsRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SpeedFieldLabel("Port d’écoute")
                SpeedTextField(placeholder: "5201", text: $model.portText).frame(width: 90)
            }
            .disabled(model.isListening)
            VStack(alignment: .leading, spacing: 4) {
                SpeedFieldLabel("Arrêt automatique")
                Picker("Arrêt automatique", selection: $model.autoStopMinutes) {
                    ForEach(IperfServerModel.autoStopChoices, id: \.self) { Text("Après \($0)\u{00A0}min sans test").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .frame(height: 30)
                .help("Le serveur s’arrête seul après ce délai sans test (jamais pendant un test)")
            }
            VStack(alignment: .leading, spacing: 4) {
                SpeedFieldLabel("Adresse de ce Mac")
                Text(address.map { "\($0) (\(state.activeInterface?.name ?? "—"))" } ?? "interface non détectée")
                    .font(Theme.mono(13)).frame(height: 30)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var console: some View {
        let port = model.port ?? IperfProtocol.defaultPort
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if model.isListening {
                    Text("NetScope › serveur iperf3 à l’écoute, port \(String(port)) (TCP)")
                        .foregroundStyle(Theme.consoleText)
                    if let stopAt = model.stopAt {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            let minutes = max(0, Int((stopAt.timeIntervalSince(context.date) / 60).rounded(.up)))
                            Text(model.current == nil ? "Arrêt automatique dans \(minutes)\u{00A0}min sans test"
                                                      : "Arrêt automatique repoussé à la fin du test")
                                .foregroundStyle(Theme.consoleMuted)
                        }
                    }
                } else {
                    Text("NetScope › serveur iperf3 arrêté\u{00A0}: rien n’écoute sur ce Mac.").foregroundStyle(Theme.consoleMuted)
                }
            }
            .font(Theme.mono(13))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.console))
            HStack(alignment: .center, spacing: 10) {
                Text("Sur l’autre appareil").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                CopyableCommand(command: model.clientCommand(address: address))
            }
        }
    }

    // MARK: Test en cours ou dernier test

    private var shownTest: IperfServerTest? { model.current ?? model.tests.first }

    private var liveChart: some View {
        let test = shownTest
        let intervals = test?.intervals ?? []
        let top = SpeedMath.gaugeScale(for: intervals.map(\.megabitsPerSecond).max() ?? 1000)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.current != nil ? "Test en cours" : "Dernier test reçu").font(.system(size: 12, weight: .semibold))
                if let test {
                    Text("\(test.client) · \(test.directionLabel)").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(rateText(test)).font(Theme.mono(12, weight: .semibold))
            }
            if intervals.isEmpty {
                Text(model.isListening ? "En attente d’un client…" : "Aucun test reçu depuis le lancement de NetScope.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(Array(intervals.enumerated()), id: \.offset) { index, interval in
                        BarMark(x: .value("Seconde", String(index + 1)), y: .value("Débit", interval.megabitsPerSecond), width: .ratio(0.7))
                            .foregroundStyle(test?.reverse == true ? speedUpColor : Theme.accent)
                            .cornerRadius(2)
                    }
                    RuleMark(y: .value("Échelle", top))
                        .foregroundStyle(Theme.borderStrong)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text(SpeedFormat.integer(top)).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                        }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: (1...max(test?.requestedSeconds ?? intervals.count, intervals.count)).map(String.init))
                .chartYScale(domain: 0...(top * 1.1))
                .chartPlotStyle { plot in
                    plot.overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
                .frame(height: 120)
            }
        }
        .padding(10)
        .frame(minWidth: 280, maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func rateText(_ test: IperfServerTest?) -> String {
        guard let test else { return "—" }
        if model.current?.id == test.id, let last = test.intervals.last { return "\(SpeedFormat.rate(last.megabitsPerSecond)) Mb/s" }
        return "\(SpeedFormat.rate(test.megabitsPerSecond)) Mb/s"
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            noteLine("arrow.down.circle", "Sens normal\u{00A0}: l’autre appareil envoie, ce Mac reçoit.")
            noteLine("arrow.up.circle", "Avec -R, ce Mac envoie vers l’autre appareil.")
            noteLine("desktopcomputer", "Un autre Mac\u{00A0}: NetScope › iperf3, rôle Client, moteur Intégré, vers l’adresse de ce Mac.")
            noteLine("exclamationmark.shield", "TCP seulement, un test à la fois (10\u{00A0}min et 32 flux au plus). Le pare-feu de macOS peut demander d’autoriser NetScope à recevoir des connexions.")
        }
        .frame(maxWidth: 330, alignment: .leading)
    }

    private func noteLine(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 14)
            Text(text).font(Theme.small).foregroundStyle(Theme.neutralText).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Tests reçus

    private var testsPanel: some View {
        let rows = model.tests.sorted(using: table.sortOrder)
        return Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionHeader("Tests reçus", subtitle: rows.isEmpty ? nil : "\(rows.count) depuis le lancement de NetScope")
                    StandardColumnsMenu(model: table, compact: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    TableColumn("Heure", sortUsing: table.sort("heure")) { test in
                        Text(test.date, format: .dateTime.hour().minute().second()).font(Theme.mono(12))
                    }
                    .customizationID("heure").disabledCustomizationBehavior(.visibility)
                    TableColumn("Client", sortUsing: table.sort("client")) { test in Text(test.client).font(Theme.mono(12)) }
                        .customizationID("client")
                    TableColumn("Sens", sortUsing: table.sort("sens")) { test in Text(test.directionLabel) }
                        .customizationID("sens")
                    TableColumn("Flux", sortUsing: table.sort("flux")) { test in Text("\(test.streams)").font(Theme.mono(12)) }
                        .customizationID("flux")
                    TableColumn("Durée", sortUsing: table.sort("duree")) { test in
                        Text("\(SpeedFormat.number(test.seconds, digits: 1))\u{00A0}s").font(Theme.mono(12))
                    }
                    .customizationID("duree")
                    TableColumn("Transfert", sortUsing: table.sort("octets")) { test in
                        Text(SpeedFormat.bytes(test.bytes)).font(Theme.mono(12))
                    }
                    .customizationID("octets")
                    TableColumn("Débit", sortUsing: table.sort("debit")) { test in
                        Text("\(SpeedFormat.rate(test.megabitsPerSecond)) Mb/s").font(Theme.mono(12, weight: .semibold))
                    }
                    .customizationID("debit")
                    TableColumn("Version du client", sortUsing: table.sort("version")) { test in Text(test.versionLabel) }
                        .customizationID("version").defaultVisibility(.hidden)
                }
                .standardTableStyle()
                .standardTableHeight(rows: max(rows.count, 1), rowHeight: 26, maxRows: 8)
                if rows.isEmpty {
                    Text("Les tests reçus s’afficheront ici (ils ne sont pas enregistrés après la fermeture de NetScope).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .padding(14)
                }
            }
        }
    }
}

extension IperfServerTest {
    /// « iperf 3.17.1 », ou « — ».
    var versionLabel: String { clientVersion.map { "iperf \($0)" } ?? "—" }
}
