import NetScopeCore
import SwiftUI

/// Ligne du tableau du relevé par pièce.
struct WifiRoomRow: Identifiable {
    let measure: WifiRoomMeasure
    var id: UUID { measure.id }
    var room: String { measure.room.lowercased() }
    var time: Date { measure.time }
    var rssi: Int { measure.rssi }
    var noise: Int { measure.noise ?? Int.min }
    var snr: Int { measure.snr ?? Int.min }
    var link: Double { measure.linkRateMbps ?? -1 }
    var latency: Double { measure.latencyMs ?? .greatestFiniteMagnitude }
    var jitter: Double { measure.jitterMs ?? .greatestFiniteMagnitude }
    var loss: Double { measure.lossPercent ?? -1 }
    var download: Double { measure.downloadMbps ?? -1 }
    var verdict: Int { measure.verdict == .faible ? 2 : (measure.verdict == .moyen ? 1 : 0) }
    var bssid: String { measure.bssid ?? "\u{10FFFF}" }
    var channel: Int { measure.channel ?? Int.max }
    var ssid: String { measure.ssid ?? "\u{10FFFF}" }
}

/// Note 78 : relevé Wi-Fi par pièce, enregistré par site. Mode relevé (bouton « Relevé ») : on nomme
/// la pièce et on lance la mesure (signal, bruit, débit du lien, latence de la passerelle, débit
/// réel facultatif). Tableau standard, suppression, export CSV.
struct WifiRoomSurveyPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var wifi: WifiStore
    @ObservedObject private var store = WifiSurveyStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @StateObject private var table = StandardTableModel<WifiRoomRow>(id: "wifi.releve", columns: Self.columns,
                                                                     sortKeys: Self.sortKeys, defaultSort: "heure", defaultAscending: false)
    @State private var room = ""
    @State private var selection = Set<UUID>()

    private static let rowHeight: CGFloat = 28
    /// Largeur minimale lisible de chaque colonne (défilement horizontal en dessous).
    static let minWidths: [String: CGFloat] = [
        "piece": 110, "heure": 62, "signal": 92, "snr": 40, "lien": 66, "latence": 56, "debit": 72, "qualite": 54,
        "constats": 110, "bruit": 60, "pertes": 46, "gigue": 46, "borne": 110, "canal": 70, "ssid": 80,
    ]

    static let columns: [StandardColumn] = [
        StandardColumn(id: "piece", title: "Pièce", isRequired: true),
        StandardColumn(id: "heure", title: "Heure"),
        StandardColumn(id: "signal", title: "Signal"),
        StandardColumn(id: "snr", title: "SNR"),
        StandardColumn(id: "lien", title: "Débit du lien"),
        StandardColumn(id: "latence", title: "Latence"),
        StandardColumn(id: "debit", title: "Débit mesuré"),
        StandardColumn(id: "qualite", title: "Qualité"),
        StandardColumn(id: "constats", title: "Constats"),
        StandardColumn(id: "bruit", title: "Bruit", isDefaultVisible: false),
        StandardColumn(id: "pertes", title: "Pertes", isDefaultVisible: false),
        StandardColumn(id: "gigue", title: "Gigue", isDefaultVisible: false),
        StandardColumn(id: "borne", title: "Borne (BSSID)", isDefaultVisible: false),
        StandardColumn(id: "canal", title: "Canal", isDefaultVisible: false),
        StandardColumn(id: "ssid", title: "SSID", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<WifiRoomRow>] = [
        "piece": KeyPathComparator(\WifiRoomRow.room), "heure": KeyPathComparator(\WifiRoomRow.time),
        "signal": KeyPathComparator(\WifiRoomRow.rssi), "snr": KeyPathComparator(\WifiRoomRow.snr),
        "lien": KeyPathComparator(\WifiRoomRow.link), "latence": KeyPathComparator(\WifiRoomRow.latency),
        "debit": KeyPathComparator(\WifiRoomRow.download), "qualite": KeyPathComparator(\WifiRoomRow.verdict),
        "constats": KeyPathComparator(\WifiRoomRow.verdict), "bruit": KeyPathComparator(\WifiRoomRow.noise),
        "pertes": KeyPathComparator(\WifiRoomRow.loss), "gigue": KeyPathComparator(\WifiRoomRow.jitter),
        "borne": KeyPathComparator(\WifiRoomRow.bssid), "canal": KeyPathComparator(\WifiRoomRow.channel),
        "ssid": KeyPathComparator(\WifiRoomRow.ssid),
    ]

    var body: some View {
        let rows = store.survey.measures.map(WifiRoomRow.init)
            .sorted(using: table.sortOrder + [KeyPathComparator(\WifiRoomRow.time, order: .reverse)])
        VStack(spacing: 0) {
            header
            if wifi.surveyActive {
                Rectangle().fill(Theme.border).frame(height: 1)
                form.padding(12)
            }
            if let message = store.message {
                Rectangle().fill(Theme.border).frame(height: 1)
                messageLine(message)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                Text(wifi.surveyActive
                     ? "Nommez la pièce où vous êtes, puis «\u{00A0}Mesurer ici\u{00A0}». Recommencez à chaque arrêt."
                     : "Aucune pièce mesurée pour ce site. Cliquez sur «\u{00A0}Relevé\u{00A0}», puis mesurez chaque pièce en vous déplaçant.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .padding(.horizontal, 12)
            } else {
                // Petite fenêtre : le tableau défile de côté au lieu de couper ses dernières colonnes.
                StandardTableHorizontalScroll(minWidth: table.contentWidth(Self.minWidths),
                                              height: StandardTableMetrics.height(rows: rows.count, rowHeight: Self.rowHeight, maxRows: 10)) {
                    tableView(rows)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .onAppear {
            store.load(siteKey: sites.activeKey)
            if WifiSurveyDemo.opensSurvey { wifi.surveyActive = true }
        }
        .onChange(of: sites.activeKey) { _, key in store.load(siteKey: key) }
    }

    // MARK: En-tête

    private var header: some View {
        let survey = store.survey
        let title = HStack(spacing: 8) {
            WifiHeading("Relevé par pièce").fixedSize()
            WifiPill(text: sites.activeName, size: 10).help("Le relevé est enregistré avec le site actif.")
        }
        let actions = HStack(spacing: 8) {
            Button { wifi.surveyActive.toggle() } label: {
                Label(wifi.surveyActive ? "Terminer" : "Mesurer une pièce", systemImage: "figure.walk")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button { store.exportCSV(siteName: sites.activeName) } label: { Label("Exporter CSV", systemImage: "square.and.arrow.down") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(survey.isEmpty)
            StandardColumnsMenu(model: table, compact: true)
        }
        let summary = Text(survey.isEmpty ? "Aucune mesure" : "\(survey.summary) · \(survey.measures.count) mesure\(survey.measures.count > 1 ? "s" : "")")
            .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                summary.fixedSize()
                Spacer(minLength: 8)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    actions.fixedSize()
                }
                summary
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Mesure

    private var form: some View {
        let network = wifi.connection?.network
        return VStack(alignment: .leading, spacing: 8) {
            if let network {
                (Text("Ici, maintenant\u{00A0}: ")
                 + Text(WifiQuality.dbm(network.rssi)).font(Theme.mono(12, weight: .bold)).foregroundStyle(WifiText.qualityColor(network.rssi).foreground)
                 + Text(" · bruit \(network.noise.map(WifiQuality.dbm) ?? "—") · lien \(FortiAPText.rate(wifi.connection?.transmitRate)) · \(network.band.label) canal \(network.channel)"))
                    .font(Theme.small)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Ce Mac n’est connecté à aucun réseau Wi-Fi\u{00A0}: rien à mesurer.", systemImage: "wifi.slash")
                    .font(Theme.small).foregroundStyle(Theme.warning)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    roomField
                    throughputToggle.fixedSize()
                    measureButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        roomField
                        measureButton.fixedSize()
                    }
                    throughputToggle
                }
            }
            if let phase = store.phase {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(phase).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Button("Annuler") { store.cancel() }.buttonStyle(.secondary).controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var roomField: some View {
        TextField("Pièce", text: $room, prompt: Text("Pièce (ex. Salle 210)"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(Theme.small)
            .frame(minWidth: 160, maxWidth: 280)
            .onSubmit(measure)
    }

    private var throughputToggle: some View {
        Toggle(isOn: $store.measureThroughput) {
            Text("Mesurer aussi le débit (≈\u{00A0}6\u{00A0}s, Internet)").font(Theme.small)
        }
        .toggleStyle(.checkbox)
        .help("Court téléchargement depuis Cloudflare\u{00A0}: le débit réel à cet endroit (limité aussi par l’accès Internet). La latence est toujours mesurée par un ping de la passerelle pendant 3\u{00A0}s.")
    }

    private var measureButton: some View {
        Button(action: measure) {
            Label(store.isMeasuring ? "Mesure…" : "Mesurer ici", systemImage: "scope")
        }
        .buttonStyle(.primary)
        .disabled(store.isMeasuring || wifi.connection?.network == nil)
        .help("Note le signal, le bruit et le débit du lien, puis mesure la latence (et le débit si coché) à cet endroit.")
    }

    private func measure() {
        guard !store.isMeasuring else { return }
        store.measure(room: room, wifi: wifi, state: state)
        room = ""
    }

    private func messageLine(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accentStrong)
            Text(message).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { store.message = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Fermer le message")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    // MARK: Tableau

    private func tableView(_ rows: [WifiRoomRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(StandardTableHeading("PIÈCE"), sortUsing: table.sort("piece")) { row in
                    Text(row.measure.room).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        .help(row.measure.note ?? row.measure.room)
                }
                .width(min: 80, ideal: 110)
                .customizationID("piece")
                .disabledCustomizationBehavior(.visibility)
                TableColumn(StandardTableHeading("HEURE"), sortUsing: table.sort("heure")) { row in
                    WifiCell(Self.timeLabel(row.measure.time), mono: 11)
                }
                .width(min: 62, ideal: 66)
                .customizationID("heure")
                TableColumn(StandardTableHeading("SIGNAL"), sortUsing: table.sort("signal")) { row in
                    HStack(spacing: 6) {
                        WifiSignalBar(rssi: row.rssi, width: 34)
                        Text(WifiQuality.dbm(row.rssi)).font(Theme.mono(11.5, weight: .semibold))
                            .foregroundStyle(WifiText.qualityColor(row.rssi).foreground).lineLimit(1)
                    }
                }
                .width(min: 86, ideal: 92)
                .customizationID("signal")
                TableColumn(StandardTableHeading("SNR"), sortUsing: table.sort("snr")) { row in
                    WifiCell(row.measure.snr.map { "\($0)\u{00A0}dB" } ?? "—", mono: 11, dimmed: row.measure.snr == nil)
                }
                .width(min: 38, ideal: 46)
                .customizationID("snr")
                TableColumn(StandardTableHeading("LIEN"), sortUsing: table.sort("lien")) { row in
                    WifiCell(FortiAPText.rate(row.measure.linkRateMbps), mono: 11, dimmed: row.measure.linkRateMbps == nil)
                }
                .width(min: 56, ideal: 66)
                .customizationID("lien")
                TableColumn(StandardTableHeading("LATENCE"), sortUsing: table.sort("latence")) { row in
                    let high = (row.measure.latencyMs ?? 0) > WifiRoomSurvey.highLatency
                    Text(row.measure.latencyMs.map { WifiRoomSurvey.number($0) + "\u{00A0}ms" } ?? "—")
                        .font(Theme.mono(11, weight: high ? .semibold : .regular))
                        .foregroundStyle(high ? Theme.warning : (row.measure.latencyMs == nil ? Theme.textTertiary : Theme.text))
                        .lineLimit(1)
                        .help(row.measure.latencyTarget.map { "Ping de la \($0)" } ?? "Latence non mesurée")
                }
                .width(min: 50, ideal: 60)
                .customizationID("latence")
                TableColumn(StandardTableHeading("DÉBIT"), sortUsing: table.sort("debit")) { row in
                    let low = (row.measure.downloadMbps ?? .greatestFiniteMagnitude) < WifiRoomSurvey.lowThroughput
                    Text(FortiAPText.rate(row.measure.downloadMbps))
                        .font(Theme.mono(11, weight: low ? .semibold : .regular))
                        .foregroundStyle(low ? Theme.warning : (row.measure.downloadMbps == nil ? Theme.textTertiary : Theme.text))
                        .lineLimit(1)
                        .help(row.measure.downloadMbps == nil ? (row.measure.note ?? "Débit non demandé") : "Téléchargement depuis Cloudflare")
                }
                .width(min: 60, ideal: 72)
                .customizationID("debit")
                TableColumn(StandardTableHeading("QUALITÉ"), sortUsing: table.sort("qualite")) { row in
                    Self.verdictPill(row.measure.verdict)
                }
                .width(min: 50, ideal: 58)
                .customizationID("qualite")
                TableColumn(StandardTableHeading("CONSTATS"), sortUsing: table.sort("constats")) { row in
                    let issues = row.measure.issues
                    WifiCell(issues.isEmpty ? "—" : issues.joined(separator: ", "), dimmed: issues.isEmpty)
                        .help(issues.joined(separator: "\n"))
                }
                .width(min: 70, ideal: 110)
                .customizationID("constats")
            }
            Group {
                TableColumn(StandardTableHeading("BRUIT"), sortUsing: table.sort("bruit")) { row in
                    WifiCell(row.measure.noise.map(WifiQuality.dbm) ?? "—", mono: 11, dimmed: row.measure.noise == nil)
                }
                .width(min: 60, ideal: 72)
                .customizationID("bruit")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("PERTES"), sortUsing: table.sort("pertes")) { row in
                    WifiCell(row.measure.lossPercent.map { WifiRoomSurvey.number($0) + "\u{00A0}%" } ?? "—", mono: 11,
                             dimmed: row.measure.lossPercent == nil)
                }
                .width(min: 46, ideal: 56)
                .customizationID("pertes")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("GIGUE"), sortUsing: table.sort("gigue")) { row in
                    WifiCell(row.measure.jitterMs.map { WifiRoomSurvey.number($0) + "\u{00A0}ms" } ?? "—", mono: 11,
                             dimmed: row.measure.jitterMs == nil)
                }
                .width(min: 46, ideal: 60)
                .customizationID("gigue")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("BORNE"), sortUsing: table.sort("borne")) { row in
                    WifiCell(row.measure.bssid ?? "—", mono: 11, dimmed: row.measure.bssid == nil)
                }
                .width(min: 90, ideal: 130)
                .customizationID("borne")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("CANAL"), sortUsing: table.sort("canal")) { row in
                    WifiCell(row.measure.channel.map { "\($0)" + (row.measure.band.map { " · \($0.label)" } ?? "") } ?? "—", mono: 11,
                             dimmed: row.measure.channel == nil)
                }
                .width(min: 60, ideal: 86)
                .customizationID("canal")
                .defaultVisibility(.hidden)
                TableColumn(StandardTableHeading("SSID"), sortUsing: table.sort("ssid")) { row in
                    WifiCell(row.measure.ssid ?? "—", dimmed: row.measure.ssid == nil)
                }
                .width(min: 60, ideal: 100)
                .customizationID("ssid")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button(ids.count > 1 ? "Retirer ces \(ids.count) mesures" : "Retirer cette mesure", role: .destructive) {
                    store.remove(ids)
                    selection.subtract(ids)
                }
            }
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            store.remove(selection)
            selection = []
        }
    }

    static func verdictPill(_ verdict: WifiRoomVerdict) -> WifiPill {
        switch verdict {
        case .bon: return WifiPill(text: verdict.label, foreground: Theme.success, background: Theme.successSoft, size: 10.5)
        case .moyen: return WifiPill(text: verdict.label, foreground: Theme.warning, background: Theme.warningSoft, size: 10.5)
        case .faible: return WifiPill(text: verdict.label, foreground: Theme.critical, background: Theme.criticalSoft, size: 10.5)
        }
    }

    /// « 14:32 » aujourd'hui, « 3 nov. 14:32 » sinon.
    static func timeLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return WifiText.time(date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }
}
